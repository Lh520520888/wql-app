#import "WQLAppDelegate.h"
#import "WQLViewController.h"
#import "WQLLog.h"

@implementation WQLAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    WQLLogInstallCrashHandler();

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
    return YES;
}

@end