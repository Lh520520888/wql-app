#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 采集结果上传：打包成 zip 后 multipart/form-data POST 到端点。
/// 设计要点：
///   - 整个输出目录打成 zip 上传，避免逐文件拖慢
///   - 失败重试 3 次（1s/2s/3s 退避）
///   - 单文件上限可配（默认 64MB，zip 放宽到 600MB）
@interface WQLUploader : NSObject

+ (instancetype)shared;

/// 完整上传地址，如 https://example.com/api/upload
@property (nonatomic, copy, nullable) NSString *endpoint;

/// 单文件上传上限，默认 64MB
@property (nonatomic, assign) uint64_t maxFileBytes;

/// 日志回调（内部同时会调用 WQLLogLine 落盘）
@property (nonatomic, copy, nullable) void (^logBlock)(NSString *line);

/// 递归上传目录下所有文件。completion 回到主线程。
- (void)uploadDirectory:(NSString *)dir
             completion:(void (^_Nullable)(NSUInteger ok, NSUInteger failed))completion;

/// 中止当前上传
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
