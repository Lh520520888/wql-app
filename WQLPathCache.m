#import "WQLPathCache.h"
#import <dispatch/dispatch.h>
#import <float.h>

@interface WQLPathCache ()
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, copy) NSString *metaPath;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray<NSString *> *> *map;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *scannedAt;
@end

@implementation WQLPathCache

+ (instancetype)shared {
    static WQLPathCache *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [WQLPathCache new];
        [s setup];
    });
    return s;
}

- (void)setup {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                        NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
    [[NSFileManager defaultManager] createDirectoryAtPath:base
                              withIntermediateDirectories:YES attributes:nil error:nil];
    _filePath = [base stringByAppendingPathComponent:@"wql_paths.plist"];
    _metaPath = [base stringByAppendingPathComponent:@"wql_paths_meta.plist"];
    _map = [NSMutableDictionary dictionary];
    _scannedAt = [NSMutableDictionary dictionary];

    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:_filePath];
    for (NSString *k in saved) {
        id v = saved[k];
        if ([v isKindOfClass:[NSArray class]]) _map[k] = v;
    }

    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:_metaPath];
    for (NSString *k in meta) {
        if ([meta[k] isKindOfClass:[NSNumber class]]) _scannedAt[k] = meta[k];
    }
}

- (void)markRootScanned:(NSString *)root {
    if (!root.length) return;
    self.scannedAt[root] = @([[NSDate date] timeIntervalSince1970]);
    [self.scannedAt writeToFile:self.metaPath atomically:YES];
}

- (NSTimeInterval)secondsSinceScanForRoot:(NSString *)root {
    NSNumber *ts = self.scannedAt[root];
    if (!ts) return DBL_MAX;
    return [[NSDate date] timeIntervalSince1970] - ts.doubleValue;
}

- (NSArray<NSString *> *)validPathsForRoot:(NSString *)root {
    NSArray *cached = self.map[root];
    if (!cached.count) return @[];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *alive = [NSMutableArray array];
    for (NSString *p in cached) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) [alive addObject:p];
    }
    return alive;
}

- (BOOL)needsRescanForRoot:(NSString *)root {
    NSArray *cached = self.map[root];
    if (!cached.count) return YES;
    return [self validPathsForRoot:root].count != cached.count;
}

- (void)mergeScanned:(NSDictionary<NSString *, NSArray<NSString *> *> *)scanned {
    if (!scanned.count) return;

    // 重扫的结果直接替换该 root 的旧缓存，顺手把失效路径清掉
    for (NSString *root in scanned) {
        self.map[root] = scanned[root] ?: @[];
    }
    [self save];
}

- (void)invalidate {
    [self.map removeAllObjects];
    [self.scannedAt removeAllObjects];
    [[NSFileManager defaultManager] removeItemAtPath:self.filePath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:self.metaPath error:nil];
}

- (void)save {
    [self.map writeToFile:self.filePath atomically:YES];
}

@end