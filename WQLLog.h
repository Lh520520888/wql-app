#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 统一日志：同时输出到 NSLog（设备 syslog）和 Documents/wql.log（可直接取出发给我）
void WQLLogLine(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// 日志文件路径
NSString *WQLLogFilePath(void);

/// 清空日志（调试时可手动调用）
void WQLLogReset(void);

NS_ASSUME_NONNULL_END