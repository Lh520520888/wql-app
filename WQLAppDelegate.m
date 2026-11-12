#import "WQLAppDelegate.h"
#import "WQLViewController.h"
#import "WQLKeepAlive.h"
#import "WQLLog.h"

@interface WQLAppDelegate ()
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@end

@implementation WQLAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    WQLLogInstallCrashHandler();
    _bgTask = UIBackgroundTaskInvalid;

    UIDevice *dev = [UIDevice currentDevice];
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *idfv = dev.identifierForVendor.UUIDString ?: @"-";
    WQLLogLine(@"===== 启动 v%@ | %@ | %@ %@ | idfv=%@ =====",
               ver ?: @"?",
               dev.model,
               dev.systemName, dev.systemVersion,
               idfv);

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [WQLViewController new];
    [self.window makeKeyAndVisible];

    // 启动即拉起保活：这样即使还没开始扫描，切后台/锁屏也不会被挂起
    [[WQLKeepAlive shared] start];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    WQLLogLine(@"进入后台：保活接管");
    [[WQLKeepAlive shared] ensureRunning];

    if (self.bgTask != UIBackgroundTaskInvalid) return;
    __weak typeof(self) weakSelf = self;
    self.bgTask = [application beginBackgroundTaskWithName:@"wql.keepalive"
                                         expirationHandler:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        WQLLogLine(@"后台任务到期，再拉一次保活");
        [self endBgTask];
        [[WQLKeepAlive shared] ensureRunning];
    }];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    WQLLogLine(@"回到前台");
    [self endBgTask];
    [[WQLKeepAlive shared] ensureRunning];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [[WQLKeepAlive shared] ensureRunning];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    WQLLogLine(@"进程即将结束（系统主动杀）");
    [self endBgTask];
}

- (void)endBgTask {
    if (self.bgTask == UIBackgroundTaskInvalid) return;
    [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
    self.bgTask = UIBackgroundTaskInvalid;
}

@end
