#import "WQLAppDelegate.h"
#import "WQLViewController.h"

@implementation WQLAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [WQLViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end