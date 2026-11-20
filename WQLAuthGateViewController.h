#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 注册/登录页：直接加载打包进 App 的 cover.html（与源码版主分支完全一致）。
/// 表单通过 owRegister 桥回传原生，由原生补 idfv/ios/机型/时间后上传；
/// 页面判定成功后真的跳 H5（与源码版一致），本页继续停留在 H5 上。
/// completion 只在点右上角「调试」跳过时回调，由调用方关闭本页。
@interface WQLAuthGateViewController : UIViewController

- (instancetype)initWithCompletion:(void (^_Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
