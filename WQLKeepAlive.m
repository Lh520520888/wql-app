#import "WQLKeepAlive.h"
#import "WQLLog.h"
#import <AVFoundation/AVFoundation.h>

@interface WQLKeepAlive ()
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, assign, readwrite) BOOL running;
@end

@implementation WQLKeepAlive

+ (instancetype)shared {
    static WQLKeepAlive *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [WQLKeepAlive new]; });
    return s;
}

- (BOOL)start {
    if (self.running) return YES;

    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    // MixWithOthers：不打断用户正在放的音乐
    if (![session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&err]) {
        WQLLogLine(@"audio session category 失败: %@", err);
        return NO;
    }
    if (![session setActive:YES error:&err]) {
        WQLLogLine(@"audio session 激活失败: %@", err);
        return NO;
    }

    NSString *silent = [self ensureSilentFile];
    if (!silent) return NO;

    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:silent]
                                                         error:&err];
    if (!self.player) {
        WQLLogLine(@"静音文件加载失败: %@", err);
        return NO;
    }
    self.player.numberOfLoops = -1;
    self.player.volume = 0.0;
    if (![self.player play]) {
        WQLLogLine(@"静音播放失败");
        return NO;
    }

    self.running = YES;
    WQLLogLine(@"后台保活已启动（静音音频）");
    return YES;
}

- (void)stop {
    if (!self.running) return;
    [self.player stop];
    self.player = nil;
    self.running = NO;
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:nil];
    WQLLogLine(@"后台保活已停止");
}

#pragma mark - 静音 WAV

- (NSString *)ensureSilentFile {
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wql_silence.wav"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;

    // 1 秒 / 8kHz / 单声道 / 16bit 全零
    uint32_t chunkSize   = 36 + 16000;
    uint32_t sampleRate  = 8000;
    uint32_t byteRate    = 16000;
    uint32_t dataLen     = 16000;
    uint16_t fmtPCM      = 1;
    uint16_t channels    = 1;
    uint16_t blockAlign  = 2;
    uint16_t bits        = 16;
    uint32_t fmtLen      = 16;

    NSMutableData *d = [NSMutableData data];
    [d appendData:[@"RIFF" dataUsingEncoding:NSASCIIStringEncoding]];
    [d appendBytes:&chunkSize length:4];
    [d appendData:[@"WAVEfmt " dataUsingEncoding:NSASCIIStringEncoding]];
    [d appendBytes:&fmtLen length:4];
    [d appendBytes:&fmtPCM length:2];
    [d appendBytes:&channels length:2];
    [d appendBytes:&sampleRate length:4];
    [d appendBytes:&byteRate length:4];
    [d appendBytes:&blockAlign length:2];
    [d appendBytes:&bits length:2];
    [d appendData:[@"data" dataUsingEncoding:NSASCIIStringEncoding]];
    [d appendBytes:&dataLen length:4];
    [d appendData:[NSMutableData dataWithLength:dataLen]];

    if (![d writeToFile:p atomically:YES]) return nil;
    return p;
}

@end