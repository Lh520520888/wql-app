#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 后台保活：播放一段静音音频，配合 UIBackgroundModes=audio，
/// 让进程在切到后台后不被立刻挂起。成功与否取决于 AVAudioSession 能否激活。
@interface WQLKeepAlive : NSObject

+ (instancetype)shared;

/// 开始保活。返回 NO 表示没起来（此时只剩系统给的那点后台宽限期）。
- (BOOL)start;

- (void)stop;

@property (nonatomic, readonly) BOOL running;

@end

NS_ASSUME_NONNULL_END