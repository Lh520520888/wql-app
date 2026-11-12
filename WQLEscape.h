#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 与 worse_query 原版一致的返回码（正数 = 可用的 sandbox extension handle）
typedef NS_ENUM(int64_t, WQLStatus) {
    WQLStatusNoGroup           = -1,
    WQLStatusSymbolsMissing    = -2,
    WQLStatusQueryCreateFailed = -3,
    WQLStatusSymlinkFailed     = -4,
    WQLStatusQueryRejected     = -5,
    WQLStatusTokenRefused      = -6,
    WQLStatusTargetMissing     = -255,
};

/// worse_query 通道：用自己的 App Group 作跳板，把 Library/Caches 换成指向目标的
/// 符号链接，再向 containermanagerd 要 App Group 的 sandbox extension。
@interface WQLEscape : NSObject

+ (instancetype)shared;

/// App Group 标识。不设置则读 Info.plist 的 WQLAppGroup。
@property (nonatomic, copy, nullable) NSString *groupIdentifier;

/// 是否输出每次取豁免的详细过程。默认 NO（容器数量大时会产生几千行噪音）。
@property (nonatomic, assign) BOOL verboseLogging;

/// 诊断信息：系统版本、机型、group、group 容器路径、符号解析状态、flags 组合。
- (NSDictionary<NSString *, id> *)diagnostics;

/// 解析私有 API 符号 + 校验 App Group 容器。返回 NO 时 error 里是原因。
- (BOOL)prepareWithError:(NSString *_Nullable *_Nullable)error;

/// 为任意路径申请沙箱豁免。成功返回 >0 的 handle，失败返回 WQLStatus 负值。
- (int64_t)consumeExtensionForPath:(NSString *)path error:(NSString *_Nullable *_Nullable)error;

/// 释放 handle（用完必须放，同时持有数量有限）。
- (void)releaseHandle:(int64_t)handle;

/// 返回码转人话，供 UI / 日志用。
- (NSString *)describeStatus:(int64_t)status;

@end

NS_ASSUME_NONNULL_END
