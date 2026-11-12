#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 后台保活：静音音频 + 定时重激活，配合 UIBackgroundModes=audio
@interface WQLKeepAlive : NSObject

+ (instancetype)shared;

/// 开始保活。返回 NO 表示没起来
- (BOOL)start;

/// 已在跑就重激活会话，没在跑就启动。生命周期回调里无脑调它即可。
- (void)ensureRunning;

- (void)stop;

@property (nonatomic, readonly) BOOL running;

@end

NS_ASSUME_NONNULL_END
