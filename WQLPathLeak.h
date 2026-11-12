#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// fsgetpath 暴力枚举：逐个 inode 反查路径，只保留指定目录的直接子项。
///
/// 关键设计：
///   - 边扫边回调：每发现一个子项立刻交给 onPath，调用方可以马上采集/上传，
///     不必等整轮扫完（这是 10 分钟等待的主要解法）
///   - 断点续扫：进度写 Application Support（不是 tmp，避免被系统清理），
///     进程被杀后下次从上次 inode 继续
@interface WQLPathLeak : NSObject

+ (BOOL)prepareWithError:(NSString *_Nullable *_Nullable)error;

+ (uint64_t)baselineInodeWithError:(NSString *_Nullable *_Nullable)error;

/// 上一次扫描是否留下了断点
+ (BOOL)hasCheckpoint;

/// 清掉断点（下次从头扫）
+ (void)clearCheckpoint;

/// 一次遍历，返回 dir -> 直接子项数组（同时通过 onPath 逐个回调）。
/// @param maxInode  0 = 自动取基线，并从断点续扫
/// @param onPath    每发现一个直接子项回调一次（在扫描线程上同步执行）
+ (NSDictionary<NSString *, NSArray<NSString *> *> *)childrenOfDirectories:(NSArray<NSString *> *)directories
                                                                 maxInode:(uint64_t)maxInode
                                                                   onPath:(void (^_Nullable)(NSString *root, NSString *path))onPath
                                                                 progress:(void (^_Nullable)(uint64_t done, uint64_t total))progress
                                                                   cancel:(BOOL (^_Nullable)(void))cancel
                                                                completed:(BOOL *_Nullable)completed
                                                                    error:(NSString *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
