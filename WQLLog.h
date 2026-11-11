#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 统一日志：同时输出到 NSLog（设备 syslog）和 Documents/wql.log（可直接取出发给我）
/// 同步写入 + fflush，进程被杀/崩溃时已打印的内容不会丢。
void WQLLogLine(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// 日志文件路径
NSString *WQLLogFilePath(void);

/// 清空日志
void WQLLogReset(void);

/// 安装未捕获异常兜底（启动时调一次）
void WQLLogInstallCrashHandler(void);

NS_ASSUME_NONNULL_END