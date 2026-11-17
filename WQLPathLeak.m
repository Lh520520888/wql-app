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

    // 断点必须「按卷」记录：多个卷共用一个 nextInode，会让后一个卷跳过前半段
    NSMutableDictionary<NSString *, NSNumber *> *resumeVolumes = [NSMutableDictionary dictionary];
    NSMutableDictionary *resumeBuckets = nil;
    NSDictionary *cp = [NSDictionary dictionaryWithContentsOfFile:WQLLeakCheckpointPath()];
    if ([cp isKindOfClass:[NSDictionary class]] &&
        [cp[@"v"] intValue] == 2 &&
        [cp[@"roots"] isEqual:directories] &&
        [cp[@"maxInode"] isKindOfClass:[NSNumber class]]) {
        double ts = [cp[@"ts"] doubleValue];
        if ([[NSDate date] timeIntervalSince1970] - ts < 72 * 3600) {
            maxInode = [cp[@"maxInode"] unsignedLongLongValue];
            NSDictionary *pv = cp[@"volumes"];
            if ([pv isKindOfClass:[NSDictionary class]]) {
                for (NSString *k in pv) {
                    if ([pv[k] isKindOfClass:[NSNumber class]]) resumeVolumes[k] = pv[k];
                }
            }
            NSDictionary *pb = cp[@"buckets"];
            if ([pb isKindOfClass:[NSDictionary class]]) resumeBuckets = [pb mutableCopy];
            WQLLogLine(@"【续扫】断点里有 %lu 个卷的进度，按卷继续",
                       (unsigned long)resumeVolumes.count);
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

    // 每个卷从自己的断点开始；分母是各卷剩余跨度之和，进度不会超过 100%
    NSMutableDictionary<NSString *, NSNumber *> *volStart = [NSMutableDictionary dictionary];
    uint64_t grandTotal = 0;
    for (NSString *vol in byVolume) {
        NSArray<NSString *> *dirs = byVolume[vol];
        NSString *first = dirs.firstObject;
        struct statfs t;
        if (!first || statfs(first.fileSystemRepresentation, &t) != 0) continue;

        uint64_t s = 1;
        NSNumber *sv = resumeVolumes[vol];
        if (sv) s = MAX((uint64_t)1, sv.unsignedLongLongValue);
        volStart[vol] = @(s);
        if (s <= maxInode) grandTotal += (maxInode - s + 1);
    }

    NSMutableDictionary<NSString *, NSNumber *> *volNext = [volStart mutableCopy];
    uint64_t totalDone = 0;
    for (NSString *vol in byVolume) {
        NSArray<NSString *> *dirs = byVolume[vol];
        NSNumber *startNum = volStart[vol];
        if (!startNum) continue;
        uint64_t from = startNum.unsignedLongLongValue;
        uint64_t span = (maxInode >= from) ? (maxInode - from + 1) : 0;
        if (span == 0) continue;

        struct statfs sfs;
        if (statfs(dirs.firstObject.fileSystemRepresentation, &sfs) != 0) continue;
        fsid_t fsid = sfs.f_fsid;

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

        // 分块并行扫：32768 个 inode 一块，4 个 worker 抢块。
        // 命中先落共享 bucket（加锁），再在串行队列里回调，保证采集侧不并发。
        static const int64_t kChunk = 32768;
        int64_t chunks = (int64_t)((span + (uint64_t)kChunk - 1) / (uint64_t)kChunk);

        dispatch_queue_t callbacks = dispatch_queue_create("com.wql.pathcallbacks",
                                                            DISPATCH_QUEUE_SERIAL);
        NSLock *lock = [NSLock new];
        NSMutableIndexSet *finished = [NSMutableIndexSet indexSet];
        __block int64_t nextChunk = 0;
        __block uint64_t doneHere = 0;
        __block NSUInteger frontier = 0;
        __block BOOL stopAll = NO;
        __block NSTimeInterval lastSave = [NSDate date].timeIntervalSince1970;

        // 实测 26.4.2 上 4 线程更慢（fsgetpath 被内核串行化），默认回到单线程；
        // 需要对比时可用 WQLScanWorkers 覆盖。
        NSInteger workers = [[NSUserDefaults standardUserDefaults] integerForKey:@"WQLScanWorkers"];
        if (workers < 1 || workers > 8) workers = 1;
        WQLLogLine(@"扫描线程：%ld", (long)workers);

        dispatch_apply((size_t)workers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t worker) {
            char b[PATH_MAX];
            fsid_t volume = fsid;   // block 里 fsid 是 const 副本，取地址要非 const

            for (;;) {
                if (stopAll) return;

                [lock lock];
                int64_t c = nextChunk++;
                [lock unlock];
                if (c >= chunks) return;

                uint64_t first = from + (uint64_t)c * (uint64_t)kChunk;
                uint64_t last = MIN(first + (uint64_t)kChunk - 1, maxInode);

                for (uint64_t ino = first; ino <= last; ino++) {
                    if ((ino & 127) == 0 && cancel && cancel()) {
                        stopAll = YES;
                        return;
                    }

                    long n = gFSGetPath(b, sizeof(b), &volume, ino);
                    if (n <= 0) continue;

                    for (size_t i = 0; i < pc; i++) {
                        size_t plen = prefixes[i].len;
                        if (strncmp(b, prefixes[i].prefix, plen) != 0) continue;
                        if (b[plen] != '/') continue;
                        if (strchr(b + plen + 1, '/')) continue;

                        NSString *s = [[NSFileManager defaultManager]
                                       stringWithFileSystemRepresentation:b length:strlen(b)];
                        if (s) {
                            BOOL isNew = NO;
                            [lock lock];
                            NSMutableArray *bucket = buckets[prefixes[i].key];
                            if (bucket && ![bucket containsObject:s]) {
                                [bucket addObject:s];
                                isNew = YES;
                            }
                            [lock unlock];

                            if (isNew && onPath) {
                                NSString *key = prefixes[i].key;
                                dispatch_sync(callbacks, ^{
                                    @autoreleasepool { onPath(key, s); }
                                });
                            }
                        }
                        break;
                    }
                }

                [lock lock];
                doneHere += (last - first + 1);
                [finished addIndexesInRange:NSMakeRange((NSUInteger)c, 1)];
                while ([finished containsIndex:frontier]) frontier++;
                if (frontier > 0) [finished removeIndexesInRange:NSMakeRange(0, frontier)];
                volNext[vol] = @(from + (uint64_t)frontier * (uint64_t)kChunk);

                NSTimeInterval now = [NSDate date].timeIntervalSince1970;
                if (now - lastSave >= (NSTimeInterval)kCheckpointInterval) {
                    lastSave = now;
                    NSDictionary *ck = @{
                        @"v": @(2),
                        @"roots": directories,
                        @"maxInode": @(maxInode),
                        @"ts": @(now),
                        @"buckets": buckets,
                        @"volumes": volNext,
                    };
                    [ck writeToFile:WQLLeakCheckpointPath() atomically:YES];
                }
                if (progress) progress(totalDone + doneHere, grandTotal);
                [lock unlock];
            }
        });

        if (stopAll) {
            wasCancelled = YES;
            // 取消时立刻落一次断点，别丢掉最后 20 秒的发现
            NSDictionary *ck = @{
                @"v": @(2),
                @"roots": directories,
                @"maxInode": @(maxInode),
                @"ts": @([[NSDate date] timeIntervalSince1970]),
                @"buckets": buckets,
                @"volumes": volNext,
            };
            [ck writeToFile:WQLLeakCheckpointPath() atomically:YES];
        }

        free(prefixes);
        totalDone += span;
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
