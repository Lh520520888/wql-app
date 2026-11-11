#import "WQLZip.h"

static uint32_t gCRCTable[256];
static BOOL gCRCReady = NO;

static void wql_crc_init(void) {
    if (gCRCReady) return;
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) {
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        }
        gCRCTable[i] = c;
    }
    gCRCReady = YES;
}

static uint32_t wql_crc32(NSData *data) {
    wql_crc_init();
    const uint8_t *p = data.bytes;
    uint32_t c = 0xFFFFFFFFu;
    for (NSUInteger i = 0; i < data.length; i++) {
        c = gCRCTable[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFFu;
}

static void wql_put16(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF) };
    [d appendBytes:b length:2];
}

static void wql_put32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF),
                     (uint8_t)((v >> 16) & 0xFF), (uint8_t)((v >> 24) & 0xFF) };
    [d appendBytes:b length:4];
}

@implementation WQLZip

+ (BOOL)zipDirectory:(NSString *)dir
              toFile:(NSString *)zipPath
            maxBytes:(uint64_t)maxBytes
               error:(NSString **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:dir];
    for (NSString *rel in e) {
        NSString *full = [dir stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir) {
            NSData *data = [NSData dataWithContentsOfFile:full
                                                  options:NSDataReadingMappedIfSafe
                                                    error:nil];
            if (data) [entries addObject:@{ @"name": rel, @"data": data }];
        }
    }
    if (!entries.count) {
        if (error) *error = @"没有可打包的文件";
        return NO;
    }

    uint64_t total = 0;
    for (NSDictionary *en in entries) total += [(NSData *)en[@"data"] length];
    if (maxBytes > 0 && total > maxBytes) {
        if (error) *error = [NSString stringWithFormat:@"打包体积 %llu 超过上限 %llu",
                             (unsigned long long)total, (unsigned long long)maxBytes];
        return NO;
    }

    [fm removeItemAtPath:zipPath error:nil];
    if (![fm createFileAtPath:zipPath contents:nil attributes:nil]) {
        if (error) *error = @"创建 zip 文件失败";
        return NO;
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:zipPath];
    if (!fh) {
        if (error) *error = @"打开 zip 文件失败";
        return NO;
    }

    uint64_t offset = 0;
    NSMutableData *central = [NSMutableData data];

    for (NSDictionary *en in entries) {
        NSString *name = en[@"name"];
        NSData *data = en[@"data"];
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t crc = wql_crc32(data);
        uint32_t size = (uint32_t)data.length;

        NSMutableData *lh = [NSMutableData data];
        wql_put32(lh, 0x04034b50);          // local header signature
        wql_put16(lh, 20);                  // version needed
        wql_put16(lh, 0x0800);              // UTF-8 flag
        wql_put16(lh, 0);                   // store
        wql_put16(lh, 0);                   // mod time
        wql_put16(lh, 0);                   // mod date
        wql_put32(lh, crc);
        wql_put32(lh, size);
        wql_put32(lh, size);
        wql_put16(lh, (uint16_t)nameData.length);
        wql_put16(lh, 0);                   // extra len
        [lh appendData:nameData];

        [fh writeData:lh];
        [fh writeData:data];

        wql_put32(central, 0x02014b50);     // central header signature
        wql_put16(central, 20);             // version made by
        wql_put16(central, 20);             // version needed
        wql_put16(central, 0x0800);
        wql_put16(central, 0);
        wql_put16(central, 0);
        wql_put16(central, 0);
        wql_put32(central, crc);
        wql_put32(central, size);
        wql_put32(central, size);
        wql_put16(central, (uint16_t)nameData.length);
        wql_put16(central, 0);
        wql_put16(central, 0);
        wql_put16(central, 0);
        wql_put16(central, 0);
        wql_put32(central, 0);
        wql_put32(central, (uint32_t)offset);
        [central appendData:nameData];

        offset += lh.length + data.length;
    }

    uint64_t centralOffset = offset;
    [fh writeData:central];

    NSMutableData *eocd = [NSMutableData data];
    wql_put32(eocd, 0x06054b50);            // EOCD signature
    wql_put16(eocd, 0);
    wql_put16(eocd, 0);
    wql_put16(eocd, (uint16_t)entries.count);
    wql_put16(eocd, (uint16_t)entries.count);
    wql_put32(eocd, (uint32_t)central.length);
    wql_put32(eocd, (uint32_t)centralOffset);
    wql_put16(eocd, 0);                     // comment len
    [fh writeData:eocd];

    [fh closeFile];
    return YES;
}

@end