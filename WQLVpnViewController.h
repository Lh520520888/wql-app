#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 注册成功后的主界面：北极星 VPN。
/// 连接、线路、流量、时长均为本地模拟演示，不发起任何真实网络连接；
/// 与采集链路完全隔离（采集在 WQLViewController 里继续后台跑）。
@interface WQLVpnViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
