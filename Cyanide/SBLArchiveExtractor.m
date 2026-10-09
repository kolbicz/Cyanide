//
//  SBLArchiveExtractor.m
//  Cyanide
//  Adapted from https://github.com/d1y/cyanide-ios (AGPL-3.0).
//

#import "SBLArchiveExtractor.h"

#import <dlfcn.h>
#import <zlib.h>

static NSString * const SBLArchiveErrorDomain = @"SnowBoardLiteArchive";

typedef int (*sbl_inflateInit2_)(z_streamp strm, int windowBits, const char *version, int stream_size);
typedef int (*sbl_inflate)(z_streamp strm, int flush);
typedef int (*sbl_inflateEnd)(z_streamp strm);

typedef enum {
    SBL_LZMA_OK = 0,
    SBL_LZMA_STREAM_END = 1,
    SBL_LZMA_FINISH = 3,
} sbl_lzma_ret;

typedef struct {
    const uint8_t *next_in;
    size_t avail_in;
    uint64_t total_in;
    uint8_t *next_out;
    size_t avail_out;
    uint64_t total_out;
    void *allocator;
    void *internal;
    void *reserved_ptr1;
    void *reserved_ptr2;
    void *reserved_ptr3;
    void *reserved_ptr4;
    uint64_t reserved_int1;
    uint64_t reserved_int2;
    size_t reserved_int3;
    size_t reserved_int4;
    int reserved_enum1;
    int reserved_enum2;
} sbl_lzma_stream;

typedef sbl_lzma_ret (*sbl_lzma_stream_decoder)(sbl_lzma_stream *strm,
                                                uint64_t memlimit,
                                                uint32_t flags);
typedef sbl_lzma_ret (*sbl_lzma_code)(sbl_lzma_stream *strm, int action);
typedef void (*sbl_lzma_end)(sbl_lzma_stream *strm);

static void sbl_set_error(NSError **error, NSInteger code, NSString *message)
{
    if (!error) return;
    *error = [NSError errorWithDomain:SBLArchiveErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: message ?: @"Archive extraction failed."}];
}

static uint16_t sbl_le16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t sbl_le32(const uint8_t *p)
{
    return (uint32_t)p[0] |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static NSString *sbl_safe_output_path(NSString *root, NSString *entryName)
{
    if (entryName.length == 0) return nil;
    if ([entryName hasPrefix:@"/"]) return nil;
    NSArray<NSString *> *parts = [entryName componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length == 0 || [part isEqualToString:@"."]) continue;
        if ([part isEqualToString:@".."]) return nil;
        [clean addObject:part];
    }
    if (clean.count == 0) return nil;
    NSString *rel = [NSString pathWithComponents:clean];
    return [root stringByAppendingPathComponent:rel];
}

static NSData *sbl_inflate_data(NSData *input, NSUInteger outputSize, int windowBits, NSError **error)
{
    if (outputSize == 0) return [NSData data];

    void *libz = dlopen("/usr/lib/libz.1.dylib", RTLD_LAZY);
    if (!libz) {
        sbl_set_error(error, 10, @"libz is not available on this device.");
        return nil;
    }

    sbl_inflateInit2_ pInit = (sbl_inflateInit2_)dlsym(libz, "inflateInit2_");
    sbl_inflate pInflate = (sbl_inflate)dlsym(libz, "inflate");
    sbl_inflateEnd pEnd = (sbl_inflateEnd)dlsym(libz, "inflateEnd");
    if (!pInit || !pInflate || !pEnd) {
        dlclose(libz);
        sbl_set_error(error, 11, @"Could not load zlib inflate symbols.");
        return nil;
    }

    NSMutableData *out = [NSMutableData dataWithLength:outputSize];
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)input.bytes;
    stream.avail_in = (uInt)MIN(input.length, UINT32_MAX);
    stream.next_out = out.mutableBytes;
    stream.avail_out = (uInt)MIN(outputSize, UINT32_MAX);

    int rc = pInit(&stream, windowBits, ZLIB_VERSION, (int)sizeof(stream));
    if (rc != Z_OK) {
        dlclose(libz);
        sbl_set_error(error, 12, @"Could not initialize zlib.");
        return nil;
    }
    rc = pInflate(&stream, Z_FINISH);
    pEnd(&stream);
    dlclose(libz);

    if (rc != Z_STREAM_END || stream.total_out != outputSize) {
        sbl_set_error(error, 13, @"Compressed archive data could not be inflated.");
        return nil;
    }
    return out;
}

static void *sbl_dlopen_liblzma(void)
{
    const char *paths[] = {
        "/usr/lib/liblzma.5.dylib",
        "/usr/lib/liblzma.dylib",
        "liblzma.5.dylib",
        "liblzma.dylib",
    };
    for (NSUInteger i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        void *lib = dlopen(paths[i], RTLD_LAZY);
        if (lib) return lib;
    }
    return NULL;
}

static NSData *sbl_decode_xz_data(NSData *input, NSError **error)
{
    if (input.length == 0) return [NSData data];

    void *lib = sbl_dlopen_liblzma();
    if (!lib) {
        sbl_set_error(error, 14, @"liblzma is not available on this device, so data.tar.xz cannot be imported.");
        return nil;
    }

    sbl_lzma_stream_decoder pDecoder =
        (sbl_lzma_stream_decoder)dlsym(lib, "lzma_stream_decoder");
    sbl_lzma_code pCode = (sbl_lzma_code)dlsym(lib, "lzma_code");
    sbl_lzma_end pEnd = (sbl_lzma_end)dlsym(lib, "lzma_end");
    if (!pDecoder || !pCode || !pEnd) {
        dlclose(lib);
        sbl_set_error(error, 15, @"Could not load liblzma decoder symbols.");
        return nil;
    }

    sbl_lzma_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.next_in = input.bytes;
    stream.avail_in = input.length;

    sbl_lzma_ret rc = pDecoder(&stream, UINT64_MAX, 0);
    if (rc != SBL_LZMA_OK) {
        dlclose(lib);
        sbl_set_error(error, 16, @"Could not initialize xz decoder.");
        return nil;
    }

    NSMutableData *out = [NSMutableData data];
    uint8_t buffer[256 * 1024];
    do {
        stream.next_out = buffer;
        stream.avail_out = sizeof(buffer);
        rc = pCode(&stream, SBL_LZMA_FINISH);
        NSUInteger produced = sizeof(buffer) - stream.avail_out;
        if (produced > 0) {
            [out appendBytes:buffer length:produced];
        }
    } while (rc == SBL_LZMA_OK);

    pEnd(&stream);
    dlclose(lib);

    if (rc != SBL_LZMA_STREAM_END) {
        sbl_set_error(error, 17, @"data.tar.xz could not be decompressed.");
        return nil;
    }
    return out;
}

static BOOL sbl_write_file(NSData *data, NSString *path, NSError **error)
{
    NSString *parent = path.stringByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager createDirectoryAtPath:parent
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:error]) {
        return NO;
    }
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

static BOOL sbl_extract_zip(NSData *zip, NSString *destination, NSError **error)
{
    const uint8_t *b = zip.bytes;
    NSUInteger len = zip.length;
    if (len < 22) {
        sbl_set_error(error, 20, @"ZIP file is too small.");
        return NO;
    }

    NSInteger eocd = -1;
    NSUInteger min = (len > 0x10000 + 22) ? len - (0x10000 + 22) : 0;
    for (NSInteger i = (NSInteger)len - 22; i >= (NSInteger)min; i--) {
        if (sbl_le32(b + i) == 0x06054b50) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        sbl_set_error(error, 21, @"ZIP central directory was not found.");
        return NO;
    }

    uint16_t count = sbl_le16(b + eocd + 10);
    uint32_t cdOffset = sbl_le32(b + eocd + 16);
    NSUInteger p = cdOffset;
    NSUInteger extracted = 0;

    for (uint16_t i = 0; i < count; i++) {
        if (p + 46 > len || sbl_le32(b + p) != 0x02014b50) break;
        uint16_t method = sbl_le16(b + p + 10);
        uint32_t compSize = sbl_le32(b + p + 20);
        uint32_t uncompSize = sbl_le32(b + p + 24);
        uint16_t nameLen = sbl_le16(b + p + 28);
        uint16_t extraLen = sbl_le16(b + p + 30);
        uint16_t commentLen = sbl_le16(b + p + 32);
        uint32_t localOff = sbl_le32(b + p + 42);
        if (p + 46 + nameLen + extraLen + commentLen > len) break;

        NSString *name = [[NSString alloc] initWithBytes:b + p + 46
                                                  length:nameLen
                                                encoding:NSUTF8StringEncoding];
        if (name.length == 0) {
            name = [[NSString alloc] initWithBytes:b + p + 46
                                            length:nameLen
                                          encoding:NSISOLatin1StringEncoding];
        }
        p += 46 + nameLen + extraLen + commentLen;
        if ([name hasSuffix:@"/"]) continue;

        // Bounds in NSUInteger, subtraction form: localOff is a uint32_t read
        // from the archive, and `localOff + 30` in 32-bit arithmetic wraps
        // (0xfffffff0 + 30 == 14), passing the check before an out-of-bounds
        // read. len >= 22 here, so len - 30 needs its own guard.
        NSUInteger lo = localOff;
        if (len < 30 || lo > len - 30 || sbl_le32(b + lo) != 0x04034b50) continue;
        uint16_t localNameLen = sbl_le16(b + lo + 26);
        uint16_t localExtraLen = sbl_le16(b + lo + 28);
        NSUInteger dataOff = lo + 30 + localNameLen + localExtraLen;   // < 2^33, no wrap
        if (dataOff > len || compSize > len - dataOff) continue;

        NSString *outPath = sbl_safe_output_path(destination, name);
        if (!outPath) continue;

        NSData *payload = [NSData dataWithBytes:b + dataOff length:compSize];
        NSData *fileData = nil;
        if (method == 0) {
            fileData = payload;
        } else if (method == 8) {
            fileData = sbl_inflate_data(payload, uncompSize, -MAX_WBITS, error);
            if (!fileData) return NO;
        } else {
            continue;
        }
        if (!sbl_write_file(fileData, outPath, error)) return NO;
        extracted++;
    }

    if (extracted == 0) {
        sbl_set_error(error, 22, @"ZIP did not contain extractable files.");
        return NO;
    }
    return YES;
}

static BOOL sbl_extract_tar(NSData *tar, NSString *destination, NSError **error)
{
    const uint8_t *b = tar.bytes;
    NSUInteger len = tar.length;
    NSUInteger p = 0;
    NSUInteger extracted = 0;

    while (p + 512 <= len) {
        const uint8_t *h = b + p;
        BOOL empty = YES;
        for (NSUInteger i = 0; i < 512; i++) {
            if (h[i] != 0) { empty = NO; break; }
        }
        if (empty) break;

        NSString *name = [[NSString alloc] initWithBytes:h length:100 encoding:NSUTF8StringEncoding];
        name = [[name componentsSeparatedByString:@"\0"] firstObject];
        NSString *prefix = [[NSString alloc] initWithBytes:h + 345 length:155 encoding:NSUTF8StringEncoding];
        prefix = [[prefix componentsSeparatedByString:@"\0"] firstObject];
        if (prefix.length > 0) name = [prefix stringByAppendingPathComponent:name ?: @""];

        char sizeBuf[13] = {0};
        memcpy(sizeBuf, h + 124, 12);
        NSUInteger size = (NSUInteger)strtoull(sizeBuf, NULL, 8);
        char type = h[156];
        NSUInteger dataOff = p + 512;
        NSUInteger next = dataOff + ((size + 511) & ~((NSUInteger)511));
        if (next > len) break;

        if (type == '0' || type == '\0') {
            NSString *outPath = sbl_safe_output_path(destination, name);
            if (outPath) {
                NSData *data = [NSData dataWithBytes:b + dataOff length:size];
                if (!sbl_write_file(data, outPath, error)) return NO;
                extracted++;
            }
        }
        p = next;
    }

    if (extracted == 0) {
        sbl_set_error(error, 30, @"TAR did not contain extractable files.");
        return NO;
    }
    return YES;
}

static NSData *sbl_data_for_ar_member(NSData *ar, NSString *wantedName)
{
    const uint8_t *b = ar.bytes;
    NSUInteger len = ar.length;
    if (len < 8 || memcmp(b, "!<arch>\n", 8) != 0) return nil;
    NSUInteger p = 8;
    while (p + 60 <= len) {
        char nameBuf[17] = {0};
        memcpy(nameBuf, b + p, 16);
        NSString *name = [[[NSString stringWithUTF8String:nameBuf]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        char sizeBuf[11] = {0};
        memcpy(sizeBuf, b + p + 48, 10);
        NSUInteger size = (NSUInteger)strtoull(sizeBuf, NULL, 10);
        NSUInteger dataOff = p + 60;
        if (dataOff + size > len) return nil;
        if ([name isEqualToString:wantedName]) {
            return [NSData dataWithBytes:b + dataOff length:size];
        }
        p = dataOff + size + (size & 1);
    }
    return nil;
}

static BOOL sbl_extract_deb(NSData *deb, NSString *destination, NSError **error)
{
    NSData *dataTar = sbl_data_for_ar_member(deb, @"data.tar");
    if (dataTar) return sbl_extract_tar(dataTar, destination, error);

    NSData *dataTarGz = sbl_data_for_ar_member(deb, @"data.tar.gz");
    if (dataTarGz) {
        if (dataTarGz.length < 4) {
            sbl_set_error(error, 40, @"Invalid gzip payload in deb.");
            return NO;
        }
        const uint8_t *b = dataTarGz.bytes;
        uint32_t outSize = sbl_le32(b + dataTarGz.length - 4);
        NSData *tar = sbl_inflate_data(dataTarGz, outSize, MAX_WBITS + 16, error);
        return tar ? sbl_extract_tar(tar, destination, error) : NO;
    }

    NSData *dataTarXz = sbl_data_for_ar_member(deb, @"data.tar.xz");
    if (dataTarXz) {
        NSData *tar = sbl_decode_xz_data(dataTarXz, error);
        return tar ? sbl_extract_tar(tar, destination, error) : NO;
    }

    sbl_set_error(error, 41, @"This deb does not contain data.tar, data.tar.gz, or data.tar.xz. data.tar.zst is not supported yet.");
    return NO;
}

BOOL SBLExtractArchiveToDirectory(NSURL *url, NSString *destination, NSError **error)
{
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) return NO;

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:destination error:nil];
    if (![fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    NSString *ext = url.pathExtension.lowercaseString;
    const uint8_t *bytes = data.bytes;
    BOOL looksZip = data.length >= 4 && sbl_le32(bytes) == 0x04034b50;
    BOOL looksDeb = data.length >= 8 && memcmp(bytes, "!<arch>\n", 8) == 0;

    if ([ext isEqualToString:@"zip"] || looksZip) {
        return sbl_extract_zip(data, destination, error);
    }
    if ([ext isEqualToString:@"deb"] || looksDeb) {
        return sbl_extract_deb(data, destination, error);
    }

    sbl_set_error(error, 50, @"Unsupported archive type. Choose a folder, .zip, or .deb.");
    return NO;
}
