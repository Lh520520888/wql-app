#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 极简 ZIP 写入器（仅 store，不压缩）。
/// 服务端按 zip 内的 _manifest.json 归类钱包包，所以必须打成 zip 而不是散文件。
@interface WQLZip : NSObject

/// 把目录下所有文件打包成 zip。maxBytes 为 0 表示不限制。
+ (BOOL)zipDirectory:(NSString *)dir
              toFile:(NSString *)zipPath
            maxBytes:(uint64_t)maxBytes
               error:(NSString *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END