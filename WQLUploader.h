#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 采集结果上传：打包成 zip 后 multipart/form-data POST 到端点
@interface WQLUploader : NSObject

+ (instancetype)shared;

/// 完整上传地址
@property (nonatomic, copy, nullable) NSString *endpoint;

/// 单文件上传上限，默认 64MB（整包 zip 单独放宽到 600MB）
@property (nonatomic, assign) uint64_t maxFileBytes;

/// 日志回调（内部同时会调用 WQLLogLine 落盘）
@property (nonatomic, copy, nullable) void (^logBlock)(NSString *line);

/// 打包并上传整个目录。completion 回到主线程。
- (void)uploadDirectory:(NSString *)dir
             completion:(void (^_Nullable)(NSUInteger ok, NSUInteger failed))completion;

/// 单独上传一份日志文件（文件名带 wql_log_ 前缀）
- (void)uploadLogFile:(NSString *)path completion:(void (^_Nullable)(BOOL ok))completion;

/// 中止当前上传
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
