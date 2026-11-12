#import "WQLKeepAlive.h"
#import "WQLLog.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

@interface WQLKeepAlive () <AVAudioPlayerDelegate>
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSTimer *renewTimer;    // 10s：重激活会话、确认在播
@property (nonatomic, strong) NSTimer *watchdog;      // 3s：掉了就自愈重建
@property (nonatomic, assign, readwrite) BOOL running;
@property (nonatomic, assign) BOOL interrupted;
@property (nonatomic, assign) NSUInteger recoveries;
- (NSString *)ensureSilentFile;
- (BOOL)buildPlayer;
- (void)installObservers;
- (void)rearmWithReason:(NSString *)reason;
- (void)renewTick;
- (void)watchdogTick;
- (void)onInterruption:(NSNotification *)n;
- (void)onMediaReset:(NSNotification *)n;
- (void)onRouteChange:(NSNotification *)n;
- (void)onAppActive;
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

    [self installObservers];

    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
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

    if (![self buildPlayer]) return NO;

    self.renewTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                      target:self
                                                    selector:@selector(renewTick)
                                                    userInfo:nil
                                                     repeats:YES];
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                     target:self
                                                   selector:@selector(watchdogTick)
                                                   userInfo:nil
                                                    repeats:YES];

    self.running = YES;
    WQLLogLine(@"后台保活已启动（静音音频 + 10s 重激活 + 3s 自愈）");
    return YES;
}

/// 兜底：保活应该一直在跑，任何入口都可以调这个把状态拉回来。
- (void)ensureRunning {
    if (!self.running) {
        [self start];
        return;
    }
    [self rearmWithReason:@"ensure"];
}

- (BOOL)buildPlayer {
    NSString *silent = [self ensureSilentFile];
    if (!silent) return NO;

    NSError *err = nil;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:silent]
                                                         error:&err];
    if (!self.player) {
        WQLLogLine(@"静音文件加载失败: %@", err);
        return NO;
    }
    self.player.numberOfLoops = -1;
    self.player.volume = 0.01;     // 文件本身是全零，音量只是为了避免被系统判成空音轨
    self.player.delegate = self;
    [self.player prepareToPlay];
    if (![self.player play]) {
        WQLLogLine(@"静音播放失败");
        return NO;
    }
    return YES;
}

- (void)renewTick {
    [self rearmWithReason:@"renew"];
}

- (void)watchdogTick {
    if (!self.running) return;
    if (self.player.isPlaying) return;

    // 播放器停了就重建；会话顺手重激活（setActive 是幂等的）
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [s setActive:YES error:&err];
    if (![self buildPlayer]) {
        WQLLogLine(@"保活自愈失败（重建播放器失败：%@）", err.localizedDescription ?: @"unknown");
        return;
    }
    self.recoveries++;
    WQLLogLine(@"保活自愈 #%lu：播放器已重建", (unsigned long)self.recoveries);
}

- (void)rearm {
    [self rearmWithReason:@"timer"];
}

- (void)rearmWithReason:(NSString *)reason {
    if (!self.running) return;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setActive:YES error:nil];
    if (!self.player.isPlaying) {
        if (![self.player play]) [self buildPlayer];
    }
    if (![reason isEqualToString:@"renew"] && ![reason isEqualToString:@"timer"]) {
        WQLLogLine(@"保活已恢复（%@）", reason);
    }
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)flag {
    if (self.running) [p play];
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)p error:(NSError *)error {
    WQLLogLine(@"保活解码错误：%@，重建播放器", error.localizedDescription);
    if (self.running) [self buildPlayer];
}

#pragma mark - 系统事件

- (void)installObservers {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

        [nc addObserver:self selector:@selector(onInterruption:)
                   name:AVAudioSessionInterruptionNotification object:nil];
        [nc addObserver:self selector:@selector(onMediaReset:)
                   name:AVAudioSessionMediaServicesWereResetNotification object:nil];
        [nc addObserver:self selector:@selector(onRouteChange:)
                   name:AVAudioSessionRouteChangeNotification object:nil];
        [nc addObserver:self selector:@selector(onAppActive)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
    });
}

- (void)onInterruption:(NSNotification *)n {
    NSNumber *type = n.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
        self.interrupted = YES;
        WQLLogLine(@"保活：音频被打断（来电 / Siri / 其它播放器）");
        return;
    }

    NSNumber *opt = n.userInfo[AVAudioSessionInterruptionOptionKey];
    BOOL shouldResume =
        (opt.unsignedIntegerValue & AVAudioSessionInterruptionOptionShouldResume) != 0;
    self.interrupted = NO;
    WQLLogLine(@"保活：打断结束%@", shouldResume ? @"，立即恢复" : @"");
    [self rearmWithReason:@"interruption-ended"];
}

- (void)onMediaReset:(NSNotification *)n {
    WQLLogLine(@"保活：音频服务被系统重置，重建播放器");
    self.player = nil;
    [self rearmWithReason:@"media-reset"];
}

- (void)onRouteChange:(NSNotification *)n {
    NSNumber *reason = n.userInfo[AVAudioSessionRouteChangeReasonKey];
    if (reason.unsignedIntegerValue != AVAudioSessionRouteChangeReasonOldDeviceUnavailable) return;
    WQLLogLine(@"保活：输出设备被拔掉（拔耳机等），恢复会话");
    [self rearmWithReason:@"route-change"];
}

- (void)onAppActive {
    [self rearmWithReason:@"foreground"];
}

#pragma mark - 停止

- (void)stop {
    if (!self.running) return;
    [self.renewTimer invalidate];
    self.renewTimer = nil;
    [self.watchdog invalidate];
    self.watchdog = nil;
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
