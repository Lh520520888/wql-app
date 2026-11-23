#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 注册/登录页：直接加载打包进 App 的 cover.html（与源码版主分支完全一致）。
/// 表单通过 owRegister 桥回传原生，由原生补 idfv/ios/机型/时间后上传；
/// 页面判定后跳 H5 的动作会被拦下：
///   success = YES → 注册/登录成功，由调用方进入产品主界面；
///   success = NO  → 从调试入口跳过，回到原生界面。
@interface WQLAuthGateViewController : UIViewController

- (instancetype)initWithCompletion:(void (^_Nullable)(BOOL success))completion;

@end

NS_ASSUME_NONNULL_END
