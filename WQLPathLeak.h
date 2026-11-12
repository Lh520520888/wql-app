#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// fsgetpath 暴力枚举：给定卷和 inode 上界，逐个 inode 反查路径，
/// 只保留指定目录的**直接子项**。这是本通道唯一的信息收集原语。
///
/// 性能：一次遍历同时匹配多个根目录；支持断点续扫（进程被杀后不重头跑）。
@interface WQLPathLeak : NSObject

+ (BOOL)prepareWithError:(NSString *_Nullable *_Nullable)error;

+ (uint64_t)baselineInodeWithError:(NSString *_Nullable *_Nullable)error;

/// 一次遍历，返回 dir -> 直接子项数组。
/// @param maxInode  0 表示自动取基线，并从上次断点续扫
+ (NSDictionary<NSString *, NSArray<NSString *> *> *)childrenOfDirectories:(NSArray<NSString *> *)directories
                                                                 maxInode:(uint64_t)maxInode
                                                                 progress:(void (^_Nullable)(uint64_t, uint64_t))progress
                                                                   cancel:(BOOL (^_Nullable)(void))cancel
                                                                completed:(BOOL *_Nullable)completed
                                                                    error:(NSString *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
