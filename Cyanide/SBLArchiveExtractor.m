//
//  SBLArchiveExtractor.m
//  Cyanide
//  Adapted from https://github.com/d1y/cyanide-ios (AGPL-3.0).
//

#import "SBLArchiveExtractor.h"

#import <dlfcn.h>
#import <zlib.h>

static NSString * const SBLArchiveErrorDomain = @"SnowBoardLiteArchive";

// Decompression-bomb bounds. A theme file is at most a few MiB; anything past
// these is refused instead of being allocated / written.
static const uint64_t kSBLMaxEntryBytes = 64ull * 1024 * 1024;    // per extracted file
static const uint64_t kSBLMaxTotalBytes = 256ull * 1024 * 1024;   // whole archive / decompressed tar
// liblzma decoder memory limit (dictionary etc., not output). xz -9 needs ~65 MiB.
static const uint64_t kSBLXZMemLimit    = 128ull * 1024 * 1024;

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

static BOOL sbl_cancelled(NSProgress *progress, NSError **error)
{
    if (!progress || !progress.isCancelled) return NO;
    sbl_set_error(error, 19, @"Archive extraction was cancelled.");
    return YES;
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
    if ([entryName hasPrefix:@"/"] || [entryName containsString:@"\\"] ||
        [entryName rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
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

static NSData *sbl_inflate_data(NSData *input, NSUInteger outputSize, int windowBits,
                                NSProgress *progress, NSError **error)
{
    if (sbl_cancelled(progress, error)) return nil;
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

static NSData *sbl_decode_xz_data(NSData *input, NSProgress *progress, NSError **error)
{
    if (sbl_cancelled(progress, error)) return nil;
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

    sbl_lzma_ret rc = pDecoder(&stream, kSBLXZMemLimit, 0);
    if (rc != SBL_LZMA_OK) {
        dlclose(lib);
        sbl_set_error(error, 16, @"Could not initialize xz decoder.");
        return nil;
    }

    NSMutableData *out = [NSMutableData data];
    uint8_t buffer[256 * 1024];
    do {
        if (sbl_cancelled(progress, error)) {
            pEnd(&stream);
            dlclose(lib);
            return nil;
        }
        stream.next_out = buffer;
        stream.avail_out = sizeof(buffer);
        rc = pCode(&stream, SBL_LZMA_FINISH);
        NSUInteger produced = sizeof(buffer) - stream.avail_out;
        if (produced > 0) {
            if (out.length + produced > kSBLMaxTotalBytes) {
                pEnd(&stream);
                dlclose(lib);
                sbl_set_error(error, 18, @"data.tar.xz decompresses to more than 256 MB.");
                return nil;
            }
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

static BOOL sbl_extract_zip(NSData *zip, NSString *destination, NSProgress *progress, NSError **error)
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

    uint16_t diskNumber = sbl_le16(b + eocd + 4);
    uint16_t centralDisk = sbl_le16(b + eocd + 6);
    uint16_t diskCount = sbl_le16(b + eocd + 8);
    uint16_t count = sbl_le16(b + eocd + 10);
    uint32_t cdSize = sbl_le32(b + eocd + 12);
    uint32_t cdOffset = sbl_le32(b + eocd + 16);
    if (diskNumber != 0 || centralDisk != 0 || diskCount != count ||
        count == UINT16_MAX || cdOffset == UINT32_MAX || cdSize == UINT32_MAX ||
        (NSUInteger)cdOffset > (NSUInteger)eocd ||
        (NSUInteger)cdSize > (NSUInteger)eocd - (NSUInteger)cdOffset ||
        (NSUInteger)cdOffset + (NSUInteger)cdSize != (NSUInteger)eocd) {
        sbl_set_error(error, 23, @"ZIP64 archives are not supported or the central directory is outside the archive.");
        return NO;
    }
    NSUInteger p = cdOffset;
    NSUInteger extracted = 0;
    uint64_t totalBytes = 0;
    NSMutableSet<NSString *> *outputPaths = [NSMutableSet set];

    for (uint16_t i = 0; i < count; i++) {
        if (sbl_cancelled(progress, error)) return NO;
        if (len < 46 || p > len - 46 || sbl_le32(b + p) != 0x02014b50) {
            sbl_set_error(error, 23, @"ZIP central directory is malformed.");
            return NO;
        }
        uint16_t method = sbl_le16(b + p + 10);
        uint32_t compSize = sbl_le32(b + p + 20);
        uint32_t uncompSize = sbl_le32(b + p + 24);
        uint16_t nameLen = sbl_le16(b + p + 28);
        uint16_t extraLen = sbl_le16(b + p + 30);
        uint16_t commentLen = sbl_le16(b + p + 32);
        uint32_t localOff = sbl_le32(b + p + 42);
        if (nameLen > len - (p + 46) || extraLen > len - (p + 46 + nameLen) ||
            commentLen > len - (p + 46 + nameLen + extraLen)) {
            sbl_set_error(error, 23, @"ZIP central directory is malformed.");
            return NO;
        }

        NSString *name = [[NSString alloc] initWithBytes:b + p + 46
                                                  length:nameLen
                                                encoding:NSUTF8StringEncoding];
        if (name.length == 0) {
            name = [[NSString alloc] initWithBytes:b + p + 46
                                            length:nameLen
                                          encoding:NSISOLatin1StringEncoding];
        }
        p += 46 + nameLen + extraLen + commentLen;
        if (!name) {
            sbl_set_error(error, 23, @"ZIP entry name is not valid text.");
            return NO;
        }
        if ([name hasSuffix:@"/"]) {
            if (!sbl_safe_output_path(destination, [name substringToIndex:name.length - 1])) {
                sbl_set_error(error, 25, @"ZIP contains an unsafe directory name.");
                return NO;
            }
            continue;
        }

        // Bounds in NSUInteger, subtraction form: localOff is a uint32_t read
        // from the archive, and `localOff + 30` in 32-bit arithmetic wraps
        // (0xfffffff0 + 30 == 14), passing the check before an out-of-bounds
        // read. len >= 22 here, so len - 30 needs its own guard.
        NSUInteger lo = localOff;
        if (lo > len - 30 || sbl_le32(b + lo) != 0x04034b50) {
            sbl_set_error(error, 23, @"ZIP local file header is malformed.");
            return NO;
        }
        uint16_t localNameLen = sbl_le16(b + lo + 26);
        uint16_t localExtraLen = sbl_le16(b + lo + 28);
        uint16_t localMethod = sbl_le16(b + lo + 8);
        if (localMethod != method) {
            sbl_set_error(error, 23, @"ZIP local and central headers disagree.");
            return NO;
        }
        if (localNameLen > len - (lo + 30) || localExtraLen > len - (lo + 30 + localNameLen)) {
            sbl_set_error(error, 23, @"ZIP local file header is malformed.");
            return NO;
        }
        NSUInteger dataOff = lo + 30 + localNameLen + localExtraLen;
        if (compSize > len - dataOff) {
            sbl_set_error(error, 23, @"ZIP entry data is outside the archive.");
            return NO;
        }

        NSString *outPath = sbl_safe_output_path(destination, name);
        if (!outPath) {
            sbl_set_error(error, 25, @"ZIP contains an unsafe entry path.");
            return NO;
        }
        if ([outputPaths containsObject:outPath]) {
            sbl_set_error(error, 26, @"ZIP contains duplicate output paths.");
            return NO;
        }
        [outputPaths addObject:outPath];

        uint64_t entryBytes = (method == 0) ? compSize : uncompSize;
        if (method != 0 && method != 8) {
            sbl_set_error(error, 27, @"ZIP uses an unsupported compression method.");
            return NO;
        }
        if (entryBytes > kSBLMaxEntryBytes || totalBytes > kSBLMaxTotalBytes - MIN(entryBytes, kSBLMaxTotalBytes)) {
            sbl_set_error(error, 24, @"ZIP contains a file larger than 64 MB or more than 256 MB in total.");
            return NO;
        }
        totalBytes += entryBytes;

        NSData *payload = [NSData dataWithBytes:b + dataOff length:compSize];
        NSData *fileData = nil;
        if (method == 0) {
            if (compSize != uncompSize) {
                sbl_set_error(error, 23, @"ZIP stored entry has inconsistent sizes.");
                return NO;
            }
            fileData = payload;
        } else if (method == 8) {
            fileData = sbl_inflate_data(payload, uncompSize, -MAX_WBITS, progress, error);
            if (!fileData) return NO;
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

static BOOL sbl_extract_tar(NSData *tar, NSString *destination, NSProgress *progress, NSError **error)
{
    const uint8_t *b = tar.bytes;
    NSUInteger len = tar.length;
    NSUInteger p = 0;
    NSUInteger extracted = 0;
    uint64_t totalBytes = 0;
    BOOL ended = NO;

    while (p + 512 <= len) {
        if (sbl_cancelled(progress, error)) return NO;
        const uint8_t *h = b + p;
        BOOL empty = YES;
        for (NSUInteger i = 0; i < 512; i++) {
            if (h[i] != 0) { empty = NO; break; }
        }
        if (empty) { ended = YES; break; }

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
        // size <= len checked first so the round-up below cannot wrap.
        if (size > len - dataOff) {
            sbl_set_error(error, 31, @"TAR entry runs past the end of the archive.");
            return NO;
        }
        NSUInteger next = dataOff + ((size + 511) & ~((NSUInteger)511));
        if (next > len) {
            sbl_set_error(error, 31, @"TAR entry runs past the end of the archive.");
            return NO;
        }

        if (type == '0' || type == '\0') {
            if (size > kSBLMaxEntryBytes || totalBytes > kSBLMaxTotalBytes - size) {
                sbl_set_error(error, 32, @"TAR contains a file larger than 64 MB or more than 256 MB in total.");
                return NO;
            }
            totalBytes += size;
            NSString *outPath = sbl_safe_output_path(destination, name);
            if (!outPath) {
                sbl_set_error(error, 33, @"TAR contains an unsafe entry path.");
                return NO;
            }
            NSData *data = [NSData dataWithBytes:b + dataOff length:size];
            if (!sbl_write_file(data, outPath, error)) return NO;
            extracted++;
        } else if (type == '5') {
            // The archive's own root ("./" -- the first entry of a standard
            // .deb data archive, and of any `tar -C dir .`) is not a path to
            // create: skip it. Any other directory must still be safe.
            NSString *bare = name ?: @"";
            while ([bare hasPrefix:@"./"]) bare = [bare substringFromIndex:2];
            while ([bare hasSuffix:@"/"]) bare = [bare substringToIndex:bare.length - 1];
            if (bare.length && ![bare isEqualToString:@"."] &&
                !sbl_safe_output_path(destination, name)) {
                sbl_set_error(error, 33, @"TAR contains an unsafe directory path.");
                return NO;
            }
        }
        // Everything else -- symlinks ('2'), hard links ('1'), pax ('x', 'g')
        // and GNU long-name ('L', 'K') headers, device nodes -- is skipped,
        // as before: nothing is created for it. Failing on these made normal
        // .deb theme and passcode imports fail.
        p = next;
    }

    if (!ended) {
        sbl_set_error(error, 31, @"TAR is truncated.");
        return NO;
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

static BOOL sbl_extract_deb(NSData *deb, NSString *destination, NSProgress *progress, NSError **error)
{
    NSData *dataTar = sbl_data_for_ar_member(deb, @"data.tar");
    if (dataTar) return sbl_extract_tar(dataTar, destination, progress, error);

    NSData *dataTarGz = sbl_data_for_ar_member(deb, @"data.tar.gz");
    if (dataTarGz) {
        if (dataTarGz.length < 4) {
            sbl_set_error(error, 40, @"Invalid gzip payload in deb.");
            return NO;
        }
        const uint8_t *b = dataTarGz.bytes;
        uint32_t outSize = sbl_le32(b + dataTarGz.length - 4);
        // ISIZE sizes the output buffer up front, so bound it before allocating.
        if (outSize > kSBLMaxTotalBytes) {
            sbl_set_error(error, 42, @"data.tar.gz decompresses to more than 256 MB.");
            return NO;
        }
        NSData *tar = sbl_inflate_data(dataTarGz, outSize, MAX_WBITS + 16, progress, error);
        return tar ? sbl_extract_tar(tar, destination, progress, error) : NO;
    }

    NSData *dataTarXz = sbl_data_for_ar_member(deb, @"data.tar.xz");
    if (dataTarXz) {
        NSData *tar = sbl_decode_xz_data(dataTarXz, progress, error);
        return tar ? sbl_extract_tar(tar, destination, progress, error) : NO;
    }

    sbl_set_error(error, 41, @"This deb does not contain data.tar, data.tar.gz, or data.tar.xz. data.tar.zst is not supported yet.");
    return NO;
}

BOOL SBLExtractArchiveToDirectoryWithProgress(NSURL *url, NSString *destination,
                                              NSProgress *progress, NSError **error)
{
    if (sbl_cancelled(progress, error)) return NO;
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

    BOOL ok = NO;
    if ([ext isEqualToString:@"zip"] || looksZip) {
        ok = sbl_extract_zip(data, destination, progress, error);
    } else if ([ext isEqualToString:@"deb"] || looksDeb) {
        ok = sbl_extract_deb(data, destination, progress, error);
    } else {
        sbl_set_error(error, 50, @"Unsupported archive type. Choose a folder, .zip, or .deb.");
    }
    if (!ok) {
        [fm removeItemAtPath:destination error:nil];
    }
    return ok;
}

BOOL SBLExtractArchiveToDirectory(NSURL *url, NSString *destination, NSError **error)
{
    return SBLExtractArchiveToDirectoryWithProgress(url, destination, nil, error);
}
