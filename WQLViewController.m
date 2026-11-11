#import "WQLViewController.h"
#import "WQLEscape.h"
#import "WQLScanner.h"
#import "WQLPathLeak.h"
#import "WQLKeepAlive.h"
#import "WQLLog.h"

@interface WQLViewController ()

@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *stopButton;

@property (nonatomic, strong) WQLScanner *scanner;
@property (nonatomic, assign) BOOL scanning;
@property (nonatomic, assign) BOOL stopRequested;
@property (nonatomic, assign) NSUInteger logLines;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;

@end

@implementation WQLViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"WQL";
    _bgTask = UIBackgroundTaskInvalid;

    [self buildUI];
    [self logText:@"WQL 通道就绪（仅用户态，无内核）"];
    [self refreshStatus];
}

#pragma mark - UI

- (void)buildUI {
    self.statusLabel = [UILabel new];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *diagButton = [self buttonWithTitle:@"自检" action:@selector(onDiagnostics)];
    self.scanButton = [self buttonWithTitle:@"开始扫描" action:@selector(onScan)];
    self.stopButton = [self buttonWithTitle:@"停止" action:@selector(onStop)];
    self.stopButton.enabled = NO;
    UIButton *shareButton = [self buttonWithTitle:@"分享日志" action:@selector(onShare)];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:
                            @[diagButton, self.scanButton, self.stopButton, shareButton]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 8;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    self.logView = [UITextView new];
    self.logView.editable = NO;
    self.logView.selectable = YES;
    self.logView.alwaysBounceVertical = YES;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 8;
    self.logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:self.statusLabel];
    [self.view addSubview:buttons];
    [self.view addSubview:self.logView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [buttons.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:12],
        [buttons.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [buttons.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [buttons.heightAnchor constraintEqualToConstant:40],

        [self.logView.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:12],
        [self.logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor secondarySystemBackgroundColor];
    b.layer.cornerRadius = 8;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)refreshStatus {
    NSDictionary *d = [[WQLEscape shared] diagnostics];
    self.statusLabel.text = [NSString stringWithFormat:
                             @"iOS %@  %@   group: %@\n容器: %@\n符号: %@   flags: %@",
                             d[@"os"], d[@"device"], d[@"group"], d[@"groupPath"],
                             [d[@"symbolsOK"] boolValue] ? @"OK" : @"缺失",
                             d[@"flagsFirst"]];
}

#pragma mark - 日志

- (void)appendLog:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                         dateStyle:NSDateFormatterNoStyle
                                                         timeStyle:NSDateFormatterMediumStyle];
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", stamp, line];
        self.logView.text = [self.logView.text stringByAppendingString:entry];
        self.logLines++;

        if (self.logLines > 2000) {
            NSArray *lines = [self.logView.text componentsSeparatedByString:@"\n"];
            if (lines.count > 1200) {
                self.logView.text = [[lines subarrayWithRange:NSMakeRange(lines.count - 1200, 1200)]
                                     componentsJoinedByString:@"\n"];
                self.logLines = 1200;
            }
        }
        NSRange bottom = NSMakeRange(self.logView.text.length, 0);
        [self.logView scrollRangeToVisible:bottom];
    });
}

/// 界面 + 文件双写。scanner 自己的日志已经写过文件，走 appendLog 即可，避免重复。
- (void)logText:(NSString *)text {
    WQLLogLine(@"%@", text);
    [self appendLog:text];
}

#pragma mark - 动作

- (void)onDiagnostics {
    [self refreshStatus];
    NSDictionary *d = [[WQLEscape shared] diagnostics];
    for (NSString *k in @[@"os", @"device", @"group", @"groupPath", @"symbolsError"]) {
        NSString *v = d[k];
        if (v.length) [self logText:[NSString stringWithFormat:@"%@ = %@", k, v]];
    }

    NSString *err = nil;
    if (![[WQLEscape shared] prepareWithError:&err]) {
        [self logText:[NSString stringWithFormat:@"符号解析失败: %@", err]];
        return;
    }

    // 用自己 App Group 容器做一个最小闭环验证
    NSURL *groupRoot = [[NSFileManager defaultManager]
                        containerURLForSecurityApplicationGroupIdentifier:
                        [[WQLEscape shared] groupIdentifier]];
    if (!groupRoot) {
        [self logText:@"group 容器为 nil：描述文件里没有这个 App Group，通道不可用"];
        return;
    }

    int64_t handle = [[WQLEscape shared] consumeExtensionForPath:groupRoot.path error:&err];
    if (handle > 0) {
        [self logText:[NSString stringWithFormat:@"自检通过，handle=%lld", (long long)handle]];
        [[WQLEscape shared] releaseHandle:handle];
    } else {
        [self logText:[NSString stringWithFormat:@"自检失败: %@", err ?: @"unknown"]];
    }
}

- (void)onScan {
    if (self.scanning) return;

    self.scanning = YES;
    self.stopRequested = NO;
    self.scanButton.enabled = NO;
    self.stopButton.enabled = YES;

    // 后台保活：静音音频让进程不被挂起，外加系统给的 30 秒宽限期兜底
    BOOL alive = [[WQLKeepAlive shared] start];
    [self logText:alive ? @"后台保活已开启：划到后台 / 锁屏仍会继续扫描"
                          : @"后台保活未开启：切到后台约 30 秒后会被系统挂起"];

    __weak typeof(self) weakVC = self;
    self.bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"wql.scan"
                                                              expirationHandler:^{
        __strong typeof(weakVC) vc = weakVC;
        if (!vc) return;
        if (vc.bgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:vc.bgTask];
            vc.bgTask = UIBackgroundTaskInvalid;
        }
    }];

    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterShortStyle
                                                     timeStyle:NSDateFormatterShortStyle];
    stamp = [stamp stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    stamp = [stamp stringByReplacingOccurrencesOfString:@":" withString:@"-"];

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *outDir = [docs stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"wql_out/%@", stamp]];

    WQLScanner *scanner = [WQLScanner new];
    scanner.maxContainerBytes = 800ULL * 1024 * 1024;
    self.scanner = scanner;

    __weak typeof(self) weakSelf = self;
    scanner.logBlock = ^(NSString *line) {
        [weakSelf appendLog:line];
    };
    scanner.cancelBlock = ^BOOL{
        __strong typeof(weakSelf) self = weakSelf;
        return self ? self.stopRequested : YES;
    };

    [self logText:[NSString stringWithFormat:@"输出目录: %@", outDir]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [scanner scanWithOutputDirectory:outDir];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            self.scanButton.enabled = YES;
            self.stopButton.enabled = NO;
            [[WQLKeepAlive shared] stop];
            if (self.bgTask != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
                self.bgTask = UIBackgroundTaskInvalid;
            }
            [self logText:@"扫描结束"];
        });
    });
}

- (void)onStop {
    self.stopRequested = YES;
    [self logText:@"已请求停止，等待当前步骤结束"];
}

- (void)onShare {
    NSString *path = WQLLogFilePath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self logText:@"日志文件还不存在，先跑一次自检"];
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *vc = [[UIActivityViewController alloc]
                                    initWithActivityItems:@[url] applicationActivities:nil];
    if (vc.popoverPresentationController) {
        vc.popoverPresentationController.sourceView = self.view;
        vc.popoverPresentationController.sourceRect =
            CGRectMake(self.view.bounds.size.width / 2, 100, 1, 1);
    }
    [self presentViewController:vc animated:YES completion:nil];
}

@end