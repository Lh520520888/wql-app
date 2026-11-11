#import "WQLLog.h"
#import <stdarg.h>
#import <stdio.h>
#import <time.h>

static NSString *gLogPath = nil;
static NSLock *gLogLock = nil;

static void WQLLogSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES).firstObject;
        if (!docs.length) docs = NSTemporaryDirectory();
        gLogPath = [docs stringByAppendingPathComponent:@"wql.log"];
        gLogLock = [NSLock new];
    });
}

NSString *WQLLogFilePath(void) {
    WQLLogSetup();
    return gLogPath;
}

void WQLLogReset(void) {
    WQLLogSetup();
    [gLogLock lock];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:gLogPath error:nil];
    [fm removeItemAtPath:[gLogPath stringByAppendingString:@".1"] error:nil];
    [gLogLock unlock];
}

void WQLLogLine(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[WQL] %@", msg);

    WQLLogSetup();

    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char ts[32];
    strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", &tmv);

    // 同步写 + fflush：进程被系统杀掉或崩溃时，已打印的行不会丢
    [gLogLock lock];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attr = [fm attributesOfItemAtPath:gLogPath error:nil];
    if ([attr[NSFileSize] unsignedLongLongValue] > 2ULL * 1024 * 1024) {
        NSString *old = [gLogPath stringByAppendingString:@".1"];
        [fm removeItemAtPath:old error:nil];
        [fm moveItemAtPath:gLogPath toPath:old error:nil];
    }

    FILE *fp = fopen(gLogPath.fileSystemRepresentation, "a");
    if (fp) {
        fprintf(fp, "[%s] %s\n", ts, msg.UTF8String);
        fflush(fp);
        fclose(fp);
    }

    [gLogLock unlock];
}

#pragma mark - 崩溃兜底

static void WQLLogHandleException(NSException *e) {
    WQLLogLine(@"!!! 未捕获异常 name=%@ reason=%@", e.name, e.reason);
    for (NSString *line in e.callStackSymbols) {
        WQLLogLine(@"    %@", line);
    }
}

void WQLLogInstallCrashHandler(void) {
    NSSetUncaughtExceptionHandler(&WQLLogHandleException);
    WQLLogLine(@"崩溃兜底已安装（覆盖 ObjC 异常，不覆盖 SIGSEGV）");
}