#import "WQLAppDelegate.h"
#import "WQLViewController.h"
#import "WQLLog.h"

@implementation WQLAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    WQLLogInstallCrashHandler();

    UIDevice *dev = [UIDevice currentDevice];
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    WQLLogLine(@"===== 启动 v%@ | %@ | %@ %@ =====",
               ver ?: @"?",
               dev.model,
               dev.systemName, dev.systemVersion);

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [WQLViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end