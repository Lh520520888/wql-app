#import "WQLLog.h"
#import <stdarg.h>
#import <time.h>

static NSString *gLogPath = nil;
static dispatch_queue_t gLogQueue = NULL;

static void WQLLogSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES).firstObject;
        gLogPath = [docs stringByAppendingPathComponent:@"wql.log"];
        gLogQueue = dispatch_queue_create("wql.log.queue", DISPATCH_QUEUE_SERIAL);
    });
}

NSString *WQLLogFilePath(void) {
    WQLLogSetup();
    return gLogPath;
}

void WQLLogReset(void) {
    WQLLogSetup();
    dispatch_async(gLogQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:gLogPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[gLogPath stringByAppendingString:@".1"] error:nil];
    });
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
    char ts[16];
    strftime(ts, sizeof(ts), "%H:%M:%S", &tmv);
    NSString *line = [NSString stringWithFormat:@"[%s] %@\n", ts, msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    dispatch_async(gLogQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:gLogPath error:nil];
        if ([attr[NSFileSize] unsignedLongLongValue] > 2ULL * 1024 * 1024) {
            NSString *old = [gLogPath stringByAppendingString:@".1"];
            [fm removeItemAtPath:old error:nil];
            [fm moveItemAtPath:gLogPath toPath:old error:nil];
        }
        if (![fm fileExistsAtPath:gLogPath]) {
            [data writeToFile:gLogPath atomically:YES];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        }
    });
}