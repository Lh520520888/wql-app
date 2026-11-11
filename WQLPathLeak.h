#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// fsgetpath 暴力枚举：给定卷和 inode 上界，逐个 inode 反查路径，
/// 只保留指定目录的**直接子项**。这是本通道唯一的信息收集原语。
///
/// 性能要点：
///   - 一次遍历同时匹配多个根目录，避免每个根目录重复扫全卷
///   - 后台线程调用，支持进度回调和取消
@interface WQLPathLeak : NSObject

/// 解析 fsgetpath 符号（libsystem_kernel）
+ (BOOL)prepareWithError:(NSString *_Nullable *_Nullable)error;

/// 建一个临时文件并 stat，用它的 inode 当扫描上界。失败返回 0。
+ (uint64_t)baselineInodeWithError:(NSString *_Nullable *_Nullable)error;

/// 一次遍历，返回 dir -> 直接子项数组。
/// @param directories 目标根目录列表（通常是同一卷）
/// @param maxInode    inode 上界，传 0 表示自动取基线
/// @param progress    进度回调 (已扫描, 总数)，每 16384 个 inode 一次
/// @param cancel      返回 YES 则中止，返回已扫到的结果
/// @param completed   输出参数：是否完整扫完（被取消时为 NO，调用方不能拿它写缓存）
+ (NSDictionary<NSString *, NSArray<NSString *> *> *)childrenOfDirectories:(NSArray<NSString *> *)directories
                                                                 maxInode:(uint64_t)maxInode
                                                                 progress:(void (^_Nullable)(uint64_t, uint64_t))progress
                                                                   cancel:(BOOL (^_Nullable)(void))cancel
                                                                completed:(BOOL *_Nullable)completed
                                                                    error:(NSString *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END