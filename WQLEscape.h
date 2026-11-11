#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 与 worse_query 原版一致的返回码（正数 = 可用的 sandbox extension handle）
typedef NS_ENUM(int64_t, WQLStatus) {
    WQLStatusNoGroup           = -1,   // App Group 不存在或取不到容器
    WQLStatusSymbolsMissing    = -2,   // 私有 API 符号解析失败（系统不支持）
    WQLStatusQueryCreateFailed = -3,
    WQLStatusSymlinkFailed     = -4,
    WQLStatusQueryRejected     = -5,   // containermanagerd 拒绝了查询
    WQLStatusTokenRefused      = -6,   // 内核拒绝签发 extension
    WQLStatusTargetMissing     = -255, // 目标路径不存在
};

/// worse_query 通道：用自己的 App Group 作跳板，把 Library/Caches 换成指向目标的
/// 符号链接，再向 containermanagerd 要 App Group 的 sandbox extension。
/// daemon 跟随符号链接解析路径，签出来的 token 实际授权的是链接指向的目录。
@interface WQLEscape : NSObject

+ (instancetype)shared;

/// App Group 标识。不设置则读 Info.plist 的 WQLAppGroup。
@property (nonatomic, copy, nullable) NSString *groupIdentifier;

/// 诊断信息：系统版本、group、group 容器路径、符号解析状态、flags 组合。
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