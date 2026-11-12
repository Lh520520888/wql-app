#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 路径缓存：容器 UUID 不变，第一次扫出来的路径直接存盘，
/// 之后每次启动先用 stat 校验，命中就跳过整个 inode 扫描。
@interface WQLPathCache : NSObject

+ (instancetype)shared;

/// root -> 仍然存在的路径数组（已过滤掉被删除的容器）。
/// 返回空数组表示这个 root 没有可用缓存，需要重新扫。
- (NSArray<NSString *> *)validPathsForRoot:(NSString *)root;

/// 缓存里有路径已经失效（App 卸载/重装导致 UUID 变了）→ 需要重扫
- (BOOL)needsRescanForRoot:(NSString *)root;

/// 记录某个 root 最近一次「完整扫完」的时间。扫出 0 个也算扫过，
/// 这样空根目录不会每次启动都逼出一次全量暴破。
- (void)markRootScanned:(NSString *)root;

/// 距上次扫完的秒数；从没扫过返回 DBL_MAX
- (NSTimeInterval)secondsSinceScanForRoot:(NSString *)root;

/// 把新扫到的结果并进缓存并落盘
- (void)mergeScanned:(NSDictionary<NSString *, NSArray<NSString *> *> *)scanned;

/// 清空缓存
- (void)invalidate;

/// 缓存文件路径（调试用）
@property (nonatomic, readonly) NSString *filePath;

@end

NS_ASSUME_NONNULL_END