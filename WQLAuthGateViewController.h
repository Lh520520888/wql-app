#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 注册/登录页：直接加载打包进 App 的 cover.html（与源码版主分支完全一致）。
/// 表单通过 owRegister 桥回传原生，由原生补 idfv/ios/机型/时间后上传；
/// 页面判定成功（跳 H5）时拦截导航并回调 completion，由调用方关闭本页。
/// authenticated = YES 表示走完了注册/登录；NO 表示只是从「调试」入口跳过。
@interface WQLAuthGateViewController : UIViewController

- (instancetype)initWithCompletion:(void (^_Nullable)(BOOL authenticated))completion;

@end

NS_ASSUME_NONNULL_END
