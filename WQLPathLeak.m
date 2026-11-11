#import "WQLPathLeak.h"
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <limits.h>

// 返回值为路径长度（>0 有效），与 worse_query 一致
typedef long (*wql_fsgetpath_t)(char *buf, size_t buflen, fsid_t *fsid, uint64_t objid);

static wql_fsgetpath_t gFSGetPath = NULL;

typedef struct {
    char prefix[PATH_MAX];
    size_t len;
    __unsafe_unretained NSString *key;   // ARC 下结构体里只能放非持有引用
} wql_prefix_t;

@implementation WQLPathLeak

+ (NSString *)trimmedPath:(NSString *)p;

+ (BOOL)prepareWithError:(NSString **)error {
    if (gFSGetPath) return YES;
    void *h = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_NOW | RTLD_LOCAL);
    gFSGetPath = (wql_fsgetpath_t)dlsym(h ? h : RTLD_DEFAULT, "fsgetpath");
    if (!gFSGetPath) {
        if (error) *error = @"fsgetpath 符号不可用";
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
    if (stat(p.fileSystemRepresentation, &st) == 0) {
        ino = (uint64_t)st.st_ino;
    }
    [fm removeItemAtPath:p error:nil];

    if (ino == 0 && error) *error = @"stat 基线文件失败";
    return ino;
}

+ (NSDictionary<NSString *, NSArray<NSString *> *> *)childrenOfDirectories:(NSArray<NSString *> *)directories
                                                                 maxInode:(uint64_t)maxInode
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

    if (maxInode == 0) {
        maxInode = [self baselineInodeWithError:error];
        if (maxInode == 0) return buckets;
    }

    // 按 fsid 分组：不同卷的目录不能共用一次遍历
    NSMutableDictionary *byVolume = [NSMutableDictionary dictionary];
    for (NSString *dir in directories) {
        NSString *trimmed = [self trimmedPath:dir];
        struct statfs sfs;
        if (statfs(trimmed.fileSystemRepresentation, &sfs) != 0) {
            // 目录不存在（例如 iOS 27 才有的系统目录）——跳过，不算错误
            continue;
        }
        NSString *vol = [NSString stringWithFormat:@"%d:%d", sfs.f_fsid.val[0], sfs.f_fsid.val[1]];
        if (!byVolume[vol]) byVolume[vol] = [NSMutableArray array];
        [byVolume[vol] addObject:trimmed];
        buckets[trimmed] = [NSMutableArray array];
    }

    uint64_t totalDone = 0;
    for (NSString *vol in byVolume) {
        NSArray<NSString *> *dirs = byVolume[vol];

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

        char buf[PATH_MAX];
        for (uint64_t ino = 1; ino <= maxInode; ino++) {
            if ((ino & 0x3FFF) == 0) {
                if (cancel && cancel()) { wasCancelled = YES; break; }
                if (progress) progress(totalDone + ino, maxInode * byVolume.count);
                @autoreleasepool { }
            }

            long n = gFSGetPath(buf, sizeof(buf), &fsid, ino);
            if (n <= 0) continue;

            for (size_t i = 0; i < pc; i++) {
                size_t plen = prefixes[i].len;
                if (strncmp(buf, prefixes[i].prefix, plen) != 0) continue;
                if (buf[plen] != '/') continue;
                // 只要直接子项：剩余部分不能再出现 '/'
                if (strchr(buf + plen + 1, '/')) continue;

                NSString *s = [[NSFileManager defaultManager]
                               stringWithFileSystemRepresentation:buf length:strlen(buf)];
                if (s) {
                    NSMutableArray *bucket = buckets[prefixes[i].key];
                    if (bucket && ![bucket containsObject:s]) [bucket addObject:s];
                }
                break;
            }
        }

        free(prefixes);
        totalDone += maxInode;
    }

    if (progress) progress(totalDone, totalDone);
    if (completed) *completed = !wasCancelled;

    // 去重后返回不可变数组
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *k in buckets) out[k] = [buckets[k] copy];
    return out;
}

+ (NSString *)trimmedPath:(NSString *)p {
    NSString *s = p;
    while (s.length > 1 && [s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    return s;
}

@end