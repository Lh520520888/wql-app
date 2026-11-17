#import "WQLPathLeak.h"
#import "WQLLog.h"
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <limits.h>

typedef long (*wql_fsgetpath_t)(char *buf, size_t buflen, fsid_t *fsid, uint64_t objid);

static wql_fsgetpath_t gFSGetPath = NULL;

typedef struct {
    char prefix[PATH_MAX];
    size_t len;
    __unsafe_unretained NSString *key;
} wql_prefix_t;

static NSString *WQLLeakCheckpointPath(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                        NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
    [[NSFileManager defaultManager] createDirectoryAtPath:base
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [base stringByAppendingPathComponent:@"wql_leak_progress.plist"];
}

static const uint64_t kCheckpointInterval = 20;   // 秒：检查点写盘节流

@interface WQLPathLeak ()
+ (NSString *)trimmedPath:(NSString *)p;
@end

@implementation WQLPathLeak

+ (BOOL)hasCheckpoint {
    return [[NSFileManager defaultManager] fileExistsAtPath:WQLLeakCheckpointPath()];
}

+ (void)clearCheckpoint {
    [[NSFileManager defaultManager] removeItemAtPath:WQLLeakCheckpointPath() error:nil];
}

+ (NSString *)checkpointSummary {
    NSDictionary *cp = [NSDictionary dictionaryWithContentsOfFile:WQLLeakCheckpointPath()];
    if (![cp isKindOfClass:[NSDictionary class]] || ![cp[@"v"] intValue]) {
        return @"断点：无";
    }

    double age = [[NSDate date] timeIntervalSince1970] - [cp[@"ts"] doubleValue];
    NSMutableString *s = [NSMutableString stringWithFormat:
                          @"断点：%.1f 分钟前保存，maxInode=%llu",
                          age / 60.0,
                          [cp[@"maxInode"] unsignedLongLongValue]];
    NSDictionary *vols = cp[@"volumes"];
    if ([vols isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in [[vols allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            [s appendFormat:@"\n    · 卷 %@ → 从 inode %llu 继续",
             k, [vols[k] unsignedLongLongValue]];
        }
    }
    NSDictionary *buckets = cp[@"buckets"];
    if ([buckets isKindOfClass:[NSDictionary class]]) {
        NSUInteger n = 0;
        for (NSString *k in buckets) n += [buckets[k] count];
        [s appendFormat:@"\n    · 已找到 %lu 条路径", (unsigned long)n];
    }
    return s;
}

+ (BOOL)prepareWithError:(NSString **)error {
    if (gFSGetPath) return YES;
    void *h = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_NOW | RTLD_LOCAL);
    gFSGetPath = (wql_fsgetpath_t)dlsym(h ? h : RTLD_DEFAULT, "fsgetpath");
    if (!gFSGetPath && h) {
        gFSGetPath = (wql_fsgetpath_t)dlsym(RTLD_DEFAULT, "fsgetpath");
    }
    if (!gFSGetPath) {
        if (error) *error = @"fsgetpath 符号不可用（系统不支持）";
        return NO;
    }
    return YES;
}

+ (uint64_t)baselineInodeWithError:(NSString **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat:@".wql_base_%@", NSUUID.UUID.UUIDString]];
    if (![@"wql" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        if (error) *error = @"无法创建基线文件（tmp 不可写）";
        return 0;
    }
    struct stat st;
    uint64_t ino = 0;
    if (stat(p.fileSystemRepresentation, &st) == 0) ino = (uint64_t)st.st_ino;
    [fm removeItemAtPath:p error:nil];
    if (ino == 0 && error) *error = @"stat 基线文件失败";
    return ino;
}

+ (NSDictionary<NSString *, NSArray<NSString *> *> *)childrenOfDirectories:(NSArray<NSString *> *)directories
                                                                 maxInode:(uint64_t)maxInode
                                                                   onPath:(void (^)(NSString *, NSString *))onPath
                                                                 progress:(void (^)(uint64_t, uint64_t))progress
                                                                   cancel:(BOOL (^)(void))cancel
                                                                completed:(BOOL *)completed
                                                                    error:(NSString **)error {
    BOOL wasCancelled = NO;
    if (completed) *completed = NO;

    NSMutableDictionary *buckets = [NSMutableDictionary dictionary];
    if (!directories.count) {
        if (error) *error = @"没有目标目录";
        return buckets;
    }
    if (![self prepareWithError:error]) return buckets;

    // 断点 v3：每个卷记两个水位（lo/hi）。v2 的单水位按「正向进度」兼容。
    NSMutableDictionary<NSString *, NSDictionary *> *resumeCursors = [NSMutableDictionary dictionary];
    NSMutableDictionary *resumeBuckets = nil;
    NSDictionary *cp = [NSDictionary dictionaryWithContentsOfFile:WQLLeakCheckpointPath()];
    int cpVersion = [cp isKindOfClass:[NSDictionary class]] ? [cp[@"v"] intValue] : 0;
    if ((cpVersion == 2 || cpVersion == 3) &&
        [cp[@"roots"] isEqual:directories] &&
        [cp[@"maxInode"] isKindOfClass:[NSNumber class]]) {
        double ts = [cp[@"ts"] doubleValue];
        if ([[NSDate date] timeIntervalSince1970] - ts < 72 * 3600) {
            maxInode = [cp[@"maxInode"] unsignedLongLongValue];
            NSDictionary *pv = cp[@"volumes"];
            if ([pv isKindOfClass:[NSDictionary class]]) {
                for (NSString *k in pv) {
                    id v = pv[k];
                    if ([v isKindOfClass:[NSDictionary class]]) {
                        resumeCursors[k] = v;
                    } else if ([v isKindOfClass:[NSNumber class]]) {
                        // v2：只有正向水位，反向从头开始
                        resumeCursors[k] = @{ @"lo": v, @"hi": @(maxInode + 1) };
                    }
                }
            }
            NSDictionary *pb = cp[@"buckets"];
            if ([pb isKindOfClass:[NSDictionary class]]) resumeBuckets = [pb mutableCopy];
            WQLLogLine(@"【续扫】断点里有 %lu 个卷的进度，按双向水位继续",
                       (unsigned long)resumeCursors.count);
        }
    }

    if (maxInode == 0) {
        maxInode = [self baselineInodeWithError:error];
        if (maxInode == 0) return buckets;
    }

    NSMutableDictionary *byVolume = [NSMutableDictionary dictionary];
    for (NSString *dir in directories) {
        NSString *trimmed = [self trimmedPath:dir];
        struct statfs sfs;
        if (statfs(trimmed.fileSystemRepresentation, &sfs) != 0) continue;
        NSString *vol = [NSString stringWithFormat:@"%d:%d", sfs.f_fsid.val[0], sfs.f_fsid.val[1]];
        if (!byVolume[vol]) byVolume[vol] = [NSMutableArray array];
        [byVolume[vol] addObject:trimmed];
        buckets[trimmed] = [NSMutableArray array];
    }

    for (NSString *k in resumeBuckets) {
        NSMutableArray *arr = buckets[k];
        if (![arr isKindOfClass:[NSMutableArray class]]) continue;
        for (NSString *p in resumeBuckets[k]) {
            if ([p isKindOfClass:[NSString class]] && ![arr containsObject:p]) [arr addObject:p];
        }
    }

    // 断点 v3：每个卷记两个水位（lo=正向已扫到哪，hi=反向待扫的最高位+1）。
    // 先正向扫到 prefixEnd（拿低位容器，比如备忘录），再从 maxInode 反向扫回 prefixEnd。
    static const uint64_t kPrefixEnd = 1000000ULL;
    uint64_t prefixEnd = MIN(maxInode, MAX((uint64_t)1, kPrefixEnd));

    NSMutableDictionary<NSString *, NSDictionary *> *volCursor = [NSMutableDictionary dictionary];
    uint64_t grandTotal = 0;
    for (NSString *vol in byVolume) {
        NSArray<NSString *> *dirs = byVolume[vol];
        NSString *first = dirs.firstObject;
        struct statfs t;
        if (!first || statfs(first.fileSystemRepresentation, &t) != 0) continue;

        uint64_t lo = 1, hi = maxInode + 1;
        NSDictionary *saved = resumeCursors[vol];
        if ([saved isKindOfClass:[NSDictionary class]]) {
            lo = [saved[@"lo"] unsignedLongLongValue];
            hi = [saved[@"hi"] unsignedLongLongValue];
            if (lo < 1) lo = 1;
            if (hi > maxInode + 1) hi = maxInode + 1;
            if (hi < 1) hi = 1;
        }
        volCursor[vol] = @{ @"lo": @(lo), @"hi": @(hi) };
        grandTotal += maxInode;
    }

    uint64_t totalDone = 0;
    for (NSString *vol in byVolume) {
        NSArray<NSString *> *dirs = byVolume[vol];
        NSDictionary *cursor = volCursor[vol];
        if (!cursor) continue;

        struct statfs sfs;
        if (statfs(dirs.firstObject.fileSystemRepresentation, &sfs) != 0) continue;
        fsid_t volume = sfs.f_fsid;

        wql_prefix_t *prefixes = calloc(dirs.count, sizeof(wql_prefix_t));
        if (!prefixes) continue;
        size_t pc = 0;
        for (NSString *dir in dirs) {
            if (![dir getFileSystemRepresentation:prefixes[pc].prefix maxLength:PATH_MAX]) continue;
            prefixes[pc].len = strlen(prefixes[pc].prefix);
            if (prefixes[pc].len == 1 && prefixes[pc].prefix[0] == '/') prefixes[pc].len = 0;
            prefixes[pc].key = dir;
            pc++;
        }

        __block uint64_t lo = [cursor[@"lo"] unsignedLongLongValue];
        __block uint64_t hi = [cursor[@"hi"] unsignedLongLongValue];
        __block BOOL stopAll = NO;
        __block uint64_t doneHere = 0;
        __block NSTimeInterval lastSave = [NSDate date].timeIntervalSince1970;
        char b[PATH_MAX];

        // 单次 inode 处理：命中就写 bucket 并回调
        void (^handleInode)(uint64_t) = ^(uint64_t ino) {
            char buf[PATH_MAX];
            fsid_t v = volume;
            long n = gFSGetPath(buf, sizeof(buf), &v, ino);
            if (n <= 0) return;

            for (size_t i = 0; i < pc; i++) {
                size_t plen = prefixes[i].len;
                if (strncmp(buf, prefixes[i].prefix, plen) != 0) continue;
                if (buf[plen] != '/') continue;
                if (strchr(buf + plen + 1, '/')) continue;

                NSString *s = [[NSFileManager defaultManager]
                               stringWithFileSystemRepresentation:buf length:strlen(buf)];
                if (s) {
                    NSMutableArray *bucket = buckets[prefixes[i].key];
                    BOOL isNew = (bucket && ![bucket containsObject:s]);
                    if (isNew) [bucket addObject:s];
                    if (isNew && onPath) {
                        @autoreleasepool { onPath(prefixes[i].key, s); }
                    }
                }
                break;
            }
        };

        void (^saveCheckpoint)(void) = ^ {
            NSDictionary *ck = @{
                @"v": @(3),
                @"roots": directories,
                @"maxInode": @(maxInode),
                @"ts": @([[NSDate date] timeIntervalSince1970]),
                @"buckets": buckets,
                @"volumes": volCursor,
            };
            [ck writeToFile:WQLLeakCheckpointPath() atomically:YES];
        };

        // 阶段 1：正向 1 → prefixEnd（拿低位容器，备忘录在这里）
        for (uint64_t ino = lo; ino <= prefixEnd; ino++) {
            if ((ino & 127) == 0 && cancel && cancel()) { stopAll = YES; break; }
            handleInode(ino);
            lo = ino + 1;
            doneHere++;

            if ((ino % 32768) == 0) {
                volCursor[vol] = @{ @"lo": @(lo), @"hi": @(hi) };
                NSTimeInterval now = [NSDate date].timeIntervalSince1970;
                if (now - lastSave >= (NSTimeInterval)kCheckpointInterval) {
                    lastSave = now;
                    saveCheckpoint();
                }
                if (progress) progress(totalDone + doneHere, grandTotal);
            }
        }

        // 阶段 2：反向 maxInode → prefixEnd+1（拿高位容器，钱包在这里）
        if (!stopAll) {
            for (uint64_t ino = hi - 1; ino > prefixEnd; ino--) {
                if ((ino & 127) == 0 && cancel && cancel()) { stopAll = YES; break; }
                handleInode(ino);
                hi = ino;
                doneHere++;

                if ((ino % 32768) == 0) {
                    volCursor[vol] = @{ @"lo": @(lo), @"hi": @(hi) };
                    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
                    if (now - lastSave >= (NSTimeInterval)kCheckpointInterval) {
                        lastSave = now;
                        saveCheckpoint();
                    }
                    if (progress) progress(totalDone + doneHere, grandTotal);
                }
            }
        }

        if (stopAll) {
            wasCancelled = YES;
            volCursor[vol] = @{ @"lo": @(lo), @"hi": @(hi) };
            saveCheckpoint();
        }

        free(prefixes);
        totalDone += maxInode;
    }

    if (progress && grandTotal && !wasCancelled) progress(grandTotal, grandTotal);
    if (completed) *completed = !wasCancelled;
    if (!wasCancelled) [self clearCheckpoint];

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *k in buckets) out[k] = [buckets[k] copy];
    return out;
}

+ (NSArray<NSString *> *)childrenOfDirectory:(NSString *)dir upToInode:(uint64_t)limit {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (![self prepareWithError:NULL]) return out;

    NSString *trimmed = [self trimmedPath:dir];
    struct statfs sfs;
    if (statfs(trimmed.fileSystemRepresentation, &sfs) != 0) return out;
    fsid_t volume = sfs.f_fsid;

    char prefix[PATH_MAX];
    if (![trimmed getFileSystemRepresentation:prefix maxLength:PATH_MAX]) return out;
    size_t plen = strlen(prefix);

    char buf[PATH_MAX];
    for (uint64_t ino = 1; ino <= limit; ino++) {
        if ((ino & 0x3FFF) == 0) @autoreleasepool { }
        if (gFSGetPath(buf, sizeof(buf), &volume, ino) <= 0) continue;
        if (strncmp(buf, prefix, plen) != 0) continue;
        if (buf[plen] != '/') continue;
        if (strchr(buf + plen + 1, '/')) continue;

        NSString *s = [[NSFileManager defaultManager]
                       stringWithFileSystemRepresentation:buf length:strlen(buf)];
        if (s && ![out containsObject:s]) [out addObject:s];
    }
    return out;
}

+ (NSString *)trimmedPath:(NSString *)p {    NSString *s = p;
    while (s.length > 1 && [s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    return s;
}

@end
