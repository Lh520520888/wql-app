#import "WQLAuthGateViewController.h"
#import <WebKit/WebKit.h>
#import <sys/sysctl.h>
#import "WQLUploader.h"
#import "WQLLog.h"

static NSString *WQLMachineIdentifier(void) {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return @"";
    char *buf = malloc(size);
    if (!buf) return @"";
    NSString *machine = @"";
    if (sysctlbyname("hw.machine", buf, &size, NULL, 0) == 0) {
        machine = [NSString stringWithUTF8String:buf] ?: @"";
    }
    free(buf);
    return machine;
}

@interface WQLAuthGateViewController () <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, copy, nullable) void (^onFinish)(BOOL success);
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong, nullable) WKWebView *webView;
- (void)uploadForm:(NSDictionary *)form;
- (void)finishWithSuccess:(BOOL)success;
@end

/// 注入脚本：品牌图标连续点 5 次（每次间隔 <1.6s）→ 通知原生进入调试界面。
/// 只按 class 命中 .brandLogo，页面结构/逻辑一行都不用改。
static NSString *WQLDebugTapScript(void) {
    return @"(function(){"
           "if(window.__wqlTapBound){return;}window.__wqlTapBound=1;"
           "var n=0,last=0;"
           "function hit(){var now=Date.now();if(now-last>1600){n=0;}last=now;n++;"
           "if(n<5){return;}n=0;"
           "try{window.webkit.messageHandlers.owDebug.postMessage(1);}catch(e){}}"
           "document.addEventListener('click',function(e){"
           "var el=e.target;"
           "while(el&&el!==document.documentElement){"
           "if(el.classList&&el.classList.contains('brandLogo')){hit();return;}"
           "el=el.parentNode;}"
           "},true);"
           "})();";
}

@implementation WQLAuthGateViewController

- (instancetype)initWithCompletion:(void (^)(BOOL))completion {
    if (self = [super initWithNibName:nil bundle:nil]) {
        _onFinish = [completion copy];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.modalPresentationCapturesStatusBarAppearance = YES;
    }
    return self;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UIColor *bg = [UIColor colorWithRed:7.0 / 255.0
                                  green:11.0 / 255.0
                                   blue:20.0 / 255.0
                                  alpha:1.0];
    self.view.backgroundColor = bg;

    NSString *path = [[NSBundle mainBundle] pathForResource:@"cover" ofType:@"html"];
    if (!path.length) {
        WQLLogLine(@"登录页: 包里没有 cover.html，直接进入主界面");
        [self finishWithSuccess:YES];
        return;
    }

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    WKUserContentController *ucc = [WKUserContentController new];
    [ucc addScriptMessageHandler:self name:@"owRegister"];
    [ucc addScriptMessageHandler:self name:@"owDebug"];
    // 点品牌图标连续 5 次进入调试界面；原生注入，不改页面文件
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:WQLDebugTapScript()
                                             injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                          forMainFrameOnly:YES]];
    cfg.userContentController = ucc;

    WKWebView *wv = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    wv.navigationDelegate = self;
    wv.opaque = NO;
    wv.backgroundColor = bg;
    wv.scrollView.backgroundColor = bg;   // 页面加载完成前不露白
    wv.scrollView.bounces = NO;
    [self.view addSubview:wv];
    self.webView = wv;

    NSURL *url = [NSURL fileURLWithPath:path];
    [wv loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];
}

#pragma mark - owRegister 桥

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    // 只接受本地 cover.html 发来的消息，H5 页面无法伪造
    NSURL *frameURL = message.frameInfo.request.URL;
    if (frameURL && !frameURL.isFileURL) return;

    if ([message.name isEqualToString:@"owDebug"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WQLLogLine(@"登录页: 品牌图标连续点击 5 次，进入调试界面");
            [self finishWithSuccess:NO];
        });
        return;
    }

    if (![message.name isEqualToString:@"owRegister"]) return;

    id body = message.body;
    NSDictionary *form = nil;
    if ([body isKindOfClass:[NSDictionary class]]) {
        form = body;
    } else if ([body isKindOfClass:[NSString class]]) {
        NSData *data = [(NSString *)body dataUsingEncoding:NSUTF8StringEncoding];
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([obj isKindOfClass:[NSDictionary class]]) form = obj;
    }
    if (!form) return;
    [self uploadForm:form];
}

- (void)uploadForm:(NSDictionary *)form {
    NSMutableDictionary *payload = [form mutableCopy] ?: [NSMutableDictionary dictionary];
    payload[@"event"] = @"cover_register";

    UIDevice *ui = [UIDevice currentDevice];
    payload[@"idfv"] = ui.identifierForVendor.UUIDString ?: @"";
    payload[@"ios"] = ui.systemVersion ?: @"";
    NSString *machine = WQLMachineIdentifier();
    payload[@"device_model"] = machine.length ? machine : ui.model;

    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    payload[@"beijing_time"] = [df stringFromDate:[NSDate date]];

    WQLLogLine(@"注册表单: attempt=%@ stage=%@ action=%@ account=%@",
               payload[@"attempt"], payload[@"stage"], payload[@"action"], payload[@"account"]);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = [[WQLUploader shared] uploadJSONNow:payload kind:@"cover_register"];
        WQLLogLine(@"注册表单: 上传%@", ok ? @"成功" : @"失败（已落盘待补传）");
    });
}

#pragma mark - 导航

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSString *scheme = navigationAction.request.URL.scheme.lowercaseString;
    if ([scheme isEqualToString:@"file"] || [scheme isEqualToString:@"about"] ||
        scheme.length == 0) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    // 页面判定成功后会跳 H5：这里收住，改为进入产品主界面
    decisionHandler(WKNavigationActionPolicyCancel);
    WQLLogLine(@"登录页: 注册/登录通过，进入主界面");
    [self finishWithSuccess:YES];
}

- (void)finishWithSuccess:(BOOL)success {
    if (self.finished) return;
    self.finished = YES;
    WKUserContentController *ucc = self.webView.configuration.userContentController;
    [ucc removeScriptMessageHandlerForName:@"owRegister"];
    [ucc removeScriptMessageHandlerForName:@"owDebug"];
    [self.webView stopLoading];
    void (^cb)(BOOL) = self.onFinish;
    self.onFinish = nil;
    if (cb) cb(success);
}

@end
