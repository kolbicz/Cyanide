//
//  SBLArchiveExtractor.m
//  Cyanide
//  Adapted from https://github.com/d1y/cyanide-ios (AGPL-3.0).
//

#import "SBLArchiveExtractor.h"

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <ImageIO/ImageIO.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

static NSString * const SBLArchiveErrorDomain = @"SnowBoardLiteArchive";

// Decompression-bomb bounds. A theme file is at most a few MiB; anything past
// these is refused instead of being allocated / written.
static const uint64_t kSBLMaxEntryBytes = 64ull * 1024 * 1024;    // per extracted file
static const uint64_t kSBLMaxTotalBytes = 256ull * 1024 * 1024;   // whole archive / decompressed tar
// Directories normally carry no data. A small allowance preserves ZIP writers
// that encode an empty directory as a tiny raw-deflate stream, while refusing
// compressed zero-output payloads before they are copied or inflated.
static const uint64_t kSBLMaxDirectoryCompressedBytes = 64ull * 1024;
// liblzma decoder memory limit (dictionary etc., not output). xz -9 needs ~65 MiB.
static const uint64_t kSBLXZMemLimit    = 128ull * 1024 * 1024;
// inflate() runs in slices of this size (input and output) so a cancel is seen
// between calls instead of only after a whole entry.
static const NSUInteger kSBLInflateChunk = 1024 * 1024;

const uint64_t SBLMaxArchiveInputBytes = kSBLMaxTotalBytes;
const uint64_t SBLMaxImportTotalBytes  = kSBLMaxTotalBytes;
const NSUInteger SBLMaxImportFileCount = UINT16_MAX - 1;          // a non-ZIP64 archive's entry cap
const uint64_t SBLMaxImageFileBytes    = 8ull * 1024 * 1024;
const NSUInteger SBLMaxImagePixelSide  = 4096;

static BOOL sbl_image_source_within_pixel_cap(CGImageSourceRef source)
{
    if (!source) return NO;
    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    if (!props) return NO;
    NSDictionary *p = (__bridge_transfer NSDictionary *)props;
    NSNumber *w = p[(__bridge NSString *)kCGImagePropertyPixelWidth];
    NSNumber *h = p[(__bridge NSString *)kCGImagePropertyPixelHeight];
    if (![w isKindOfClass:NSNumber.class] || ![h isKindOfClass:NSNumber.class]) return NO;
    return w.unsignedLongLongValue > 0 && h.unsignedLongLongValue > 0 &&
           w.unsignedLongLongValue <= SBLMaxImagePixelSide &&
           h.unsignedLongLongValue <= SBLMaxImagePixelSide;
}

BOOL SBLImageFilePassesPreflight(NSString *path, uint64_t maxBytes, uint64_t *sizeOut)
{
    if (sizeOut) *sizeOut = 0;
    if (path.length == 0 || maxBytes == 0) return NO;
    // Open once, no-follow, and take everything (size and dimensions) from
    // that descriptor. lstat + CGImageSourceCreateWithURL reopens the path and
    // follows a symlink swapped in between, so the checked object and the one
    // later read could be different files.
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return NO;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 ||
        (uint64_t)st.st_size > maxBytes) {
        close(fd);
        return NO;
    }

    NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)st.st_size];
    uint8_t chunk[64 * 1024];
    uint64_t total = 0;
    BOOL tooLarge = NO, readFailed = NO;
    for (;;) {
        ssize_t got = read(fd, chunk, sizeof(chunk));
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) { readFailed = YES; break; }
        if (got == 0) break;
        if (total + (uint64_t)got > maxBytes) { tooLarge = YES; break; }
        [data appendBytes:chunk length:(NSUInteger)got];
        total += (uint64_t)got;
    }
    struct stat after = {0};
    BOOL unchanged = fstat(fd, &after) == 0 && after.st_ino == st.st_ino &&
                     after.st_dev == st.st_dev && after.st_size == st.st_size &&
                     total == (uint64_t)st.st_size;
    close(fd);
    if (readFailed || tooLarge || !unchanged || data.length == 0) return NO;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    BOOL ok = sbl_image_source_within_pixel_cap(source);
    if (source) CFRelease(source);
    if (ok && sizeOut) *sizeOut = (uint64_t)data.length;
    return ok;
}

BOOL SBLImageDataPassesPixelPreflight(NSData *data)
{
    if (data.length == 0) return NO;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    BOOL ok = sbl_image_source_within_pixel_cap(source);
    if (source) CFRelease(source);
    return ok;
}

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

    if (outputSize == NSUIntegerMax) { dlclose(libz); return nil; }
    // One scratch byte lets inflate consume end markers when declared output
    // is zero or exactly fills the buffer; any use of it rejects the stream.
    NSMutableData *out = [NSMutableData dataWithLength:outputSize + 1];
    const Bytef *inBase = input.bytes;
    Bytef *outBase = out.mutableBytes;
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)inBase;
    stream.next_out = outBase;

    int rc = pInit(&stream, windowBits, ZLIB_VERSION, (int)sizeof(stream));
    if (rc != Z_OK) {
        dlclose(libz);
        sbl_set_error(error, 12, @"Could not initialize zlib.");
        return nil;
    }
    // Bounded slices, cancellation checked between them. Every Z_OK made
    // progress on a finite input/output, so the loop ends; Z_BUF_ERROR (no
    // progress possible: truncated input or more output than declared) and any
    // other code fail exactly as the old one-shot Z_FINISH call did.
    for (;;) {
        if (sbl_cancelled(progress, error)) {
            pEnd(&stream);
            dlclose(libz);
            return nil;
        }
        NSUInteger consumed = (NSUInteger)(stream.next_in - inBase);
        NSUInteger produced = (NSUInteger)(stream.next_out - outBase);
        if (consumed > input.length || produced > outputSize) { rc = Z_DATA_ERROR; break; }
        stream.avail_in = (uInt)MIN(input.length - consumed, kSBLInflateChunk);
        stream.avail_out = (uInt)MIN(outputSize + 1 - produced, kSBLInflateChunk);
        rc = pInflate(&stream, Z_NO_FLUSH);
        if (stream.total_out > outputSize) { rc = Z_DATA_ERROR; break; }
        if (rc != Z_OK) break;
    }
    pEnd(&stream);
    dlclose(libz);

    if (rc != Z_STREAM_END || stream.total_out != outputSize ||
        stream.total_in != input.length) {
        sbl_set_error(error, 13, @"Compressed archive data could not be inflated.");
        return nil;
    }
    [out setLength:outputSize];
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

static BOOL sbl_create_directory_entry(NSString *path,
                                        NSMutableSet<NSString *> *explicitDirectories,
                                        NSError **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *parent = path.stringByDeletingLastPathComponent;
    if (![fm createDirectoryAtPath:parent
       withIntermediateDirectories:YES
                        attributes:nil
                             error:error]) {
        return NO;
    }
    if (mkdir(path.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) {
        sbl_set_error(error, 55, @"Could not create an archive directory entry.");
        return NO;
    }
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) {
        sbl_set_error(error, 26, @"ZIP contains file/directory output aliases.");
        return NO;
    }
    NSString *identity = [NSString stringWithFormat:@"%llu:%llu",
                          (unsigned long long)st.st_dev,
                          (unsigned long long)st.st_ino];
    if ([explicitDirectories containsObject:identity]) {
        sbl_set_error(error, 26, @"ZIP contains duplicate output directories.");
        return NO;
    }
    [explicitDirectories addObject:identity];
    return YES;
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
    int fd = open(path.fileSystemRepresentation,
                  O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) {
        sbl_set_error(error, errno == EEXIST ? 26 : 55,
                      errno == EEXIST ? @"Archive entries resolve to duplicate output paths."
                                      : @"Could not create an extracted archive file.");
        return NO;
    }
    const uint8_t *bytes = data.bytes;
    size_t length = (size_t)data.length;
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(fd, bytes + offset, length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            close(fd);
            sbl_set_error(error, 55, @"Could not write an extracted archive file.");
            return NO;
        }
        offset += (size_t)written;
    }
    if (close(fd) != 0) {
        sbl_set_error(error, 55, @"Could not close an extracted archive file.");
        return NO;
    }
    return YES;
}

static const uint16_t kSBLZipDataDescriptorFlag = 1u << 3;
static const uint16_t kSBLZipUTF8Flag = 1u << 11;
static const uint16_t kSBLZipSupportedFlags = kSBLZipDataDescriptorFlag | kSBLZipUTF8Flag;

static BOOL sbl_zip_flags_are_supported(uint16_t flags, uint16_t method, NSError **error)
{
    if (flags & 1u) {
        sbl_set_error(error, 27, @"Encrypted ZIP entries are not supported.");
        return NO;
    }
    // Bits 1/2 describe ordinary deflate compression levels, not encryption.
    uint16_t supported = kSBLZipSupportedFlags | (method == 8 ? 6u : 0u);
    if (flags & (uint16_t)~supported) {
        sbl_set_error(error, 27, @"ZIP entry uses unsupported flags.");
        return NO;
    }
    return YES;
}

static BOOL sbl_zip_crc_matches(NSData *data, uint32_t expected)
{
    // Keep the extractor's existing dynamic-zlib contract: the app target does
    // not link libz directly. Test fixture generation may link it independently.
    void *libz = dlopen("/usr/lib/libz.1.dylib", RTLD_LAZY);
    if (!libz) return NO;
    uLong (*pCRC)(uLong, const Bytef *, uInt) = (void *)dlsym(libz, "crc32");
    uLong actual = pCRC ? pCRC(pCRC(0L, Z_NULL, 0), data.bytes, (uInt)data.length) : 0;
    BOOL matches = pCRC && (uint32_t)actual == expected;
    dlclose(libz);
    return matches;
}

static BOOL sbl_zip_descriptor_matches(const uint8_t *b, NSUInteger offset,
                                       NSUInteger limit, uint32_t crc,
                                       uint32_t compSize, uint32_t uncompSize)
{
    if (offset > limit) return NO;
    NSUInteger available = limit - offset;
    if (available >= 16 && sbl_le32(b + offset) == 0x08074b50 &&
        sbl_le32(b + offset + 4) == crc &&
        sbl_le32(b + offset + 8) == compSize &&
        sbl_le32(b + offset + 12) == uncompSize) {
        return YES;
    }
    // The optional data-descriptor signature is omitted by many ordinary ZIP
    // writers. Try the unsigned form even when the first CRC happens to equal
    // the signature value.
    return available >= 12 &&
           sbl_le32(b + offset) == crc &&
           sbl_le32(b + offset + 4) == compSize &&
           sbl_le32(b + offset + 8) == uncompSize;
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
    NSMutableSet<NSString *> *explicitDirectories = [NSMutableSet set];

    for (uint16_t i = 0; i < count; i++) {
        if (sbl_cancelled(progress, error)) return NO;
        if (len < 46 || p > len - 46 || sbl_le32(b + p) != 0x02014b50) {
            sbl_set_error(error, 23, @"ZIP central directory is malformed.");
            return NO;
        }
        uint16_t flags = sbl_le16(b + p + 8);
        uint16_t method = sbl_le16(b + p + 10);
        uint32_t expectedCRC = sbl_le32(b + p + 16);
        uint32_t compSize = sbl_le32(b + p + 20);
        uint32_t uncompSize = sbl_le32(b + p + 24);
        uint16_t nameLen = sbl_le16(b + p + 28);
        uint16_t extraLen = sbl_le16(b + p + 30);
        uint16_t commentLen = sbl_le16(b + p + 32);
        uint32_t localOff = sbl_le32(b + p + 42);
        if (!sbl_zip_flags_are_supported(flags, method, error)) return NO;
        if (nameLen > len - (p + 46) || extraLen > len - (p + 46 + nameLen) ||
            commentLen > len - (p + 46 + nameLen + extraLen)) {
            sbl_set_error(error, 23, @"ZIP central directory is malformed.");
            return NO;
        }

        const uint8_t *centralName = b + p + 46;
        NSString *name = [[NSString alloc] initWithBytes:centralName length:nameLen
                                               encoding:NSUTF8StringEncoding];
        if (!name && !(flags & kSBLZipUTF8Flag))
            name = [[NSString alloc] initWithBytes:centralName length:nameLen
                                         encoding:NSISOLatin1StringEncoding];
        p += 46 + nameLen + extraLen + commentLen;
        if (!name) {
            sbl_set_error(error, 23, @"ZIP entry name is not valid text.");
            return NO;
        }
        BOOL isDirectory = [name hasSuffix:@"/"];

        // Bounds in NSUInteger, subtraction form: localOff is a uint32_t read
        // from the archive, and `localOff + 30` in 32-bit arithmetic wraps
        // (0xfffffff0 + 30 == 14), passing the check before an out-of-bounds
        // read. len >= 22 here, so len - 30 needs its own guard.
        NSUInteger lo = localOff;
        if (lo >= (NSUInteger)cdOffset || lo > len - 30 || sbl_le32(b + lo) != 0x04034b50) {
            sbl_set_error(error, 23, @"ZIP local file header is malformed.");
            return NO;
        }
        uint16_t localFlags = sbl_le16(b + lo + 6);
        uint16_t localNameLen = sbl_le16(b + lo + 26);
        uint16_t localExtraLen = sbl_le16(b + lo + 28);
        uint16_t localMethod = sbl_le16(b + lo + 8);
        uint32_t localCRC = sbl_le32(b + lo + 14);
        uint32_t localCompSize = sbl_le32(b + lo + 18);
        uint32_t localUncompSize = sbl_le32(b + lo + 22);
        if (!sbl_zip_flags_are_supported(localFlags, localMethod, error)) return NO;
        if (localFlags != flags || localMethod != method) {
            sbl_set_error(error, 23, @"ZIP local and central headers disagree.");
            return NO;
        }
        if (localNameLen > len - (lo + 30) || localExtraLen > len - (lo + 30 + localNameLen)) {
            sbl_set_error(error, 23, @"ZIP local file header is malformed.");
            return NO;
        }
        if (localNameLen != nameLen ||
            memcmp(b + lo + 30, centralName, nameLen) != 0) {
            sbl_set_error(error, 23, @"ZIP local and central filenames disagree.");
            return NO;
        }
        BOOL hasDescriptor = (flags & kSBLZipDataDescriptorFlag) != 0;
        if (!hasDescriptor &&
            (localCRC != expectedCRC || localCompSize != compSize || localUncompSize != uncompSize)) {
            sbl_set_error(error, 23, @"ZIP local and central metadata disagree.");
            return NO;
        }
        if (hasDescriptor &&
            ((localCRC != 0 && localCRC != expectedCRC) ||
             (localCompSize != 0 && localCompSize != compSize) ||
             (localUncompSize != 0 && localUncompSize != uncompSize))) {
            sbl_set_error(error, 23, @"ZIP local data-descriptor metadata disagrees.");
            return NO;
        }
        NSUInteger dataOff = lo + 30 + localNameLen + localExtraLen;
        if (dataOff > (NSUInteger)cdOffset || compSize > (NSUInteger)cdOffset - dataOff) {
            sbl_set_error(error, 23, @"ZIP entry data is outside the archive.");
            return NO;
        }
        NSUInteger descriptorOff = dataOff + compSize;
        if (hasDescriptor &&
            !sbl_zip_descriptor_matches(b, descriptorOff, (NSUInteger)cdOffset,
                                        expectedCRC, compSize, uncompSize)) {
            sbl_set_error(error, 23, @"ZIP data descriptor is malformed or disagrees with the central directory.");
            return NO;
        }

        NSString *outPath = sbl_safe_output_path(destination, name);
        if (!outPath) {
            sbl_set_error(error, 25,
                          isDirectory ? @"ZIP contains an unsafe directory name."
                                      : @"ZIP contains an unsafe entry path.");
            return NO;
        }
        if ([outputPaths containsObject:outPath]) {
            sbl_set_error(error, 26, @"ZIP contains duplicate output paths.");
            return NO;
        }
        [outputPaths addObject:outPath];

        if (method != 0 && method != 8) {
            sbl_set_error(error, 27, @"ZIP uses an unsupported compression method.");
            return NO;
        }
        uint64_t entryBytes = (method == 0) ? compSize : uncompSize;
        BOOL invalidDirectoryPayload = isDirectory &&
            (uncompSize != 0 ||
             (method == 0 && compSize != 0) ||
             (method == 8 && (uint64_t)compSize > kSBLMaxDirectoryCompressedBytes));
        if (invalidDirectoryPayload || (!isDirectory && entryBytes > kSBLMaxEntryBytes)) {
            sbl_set_error(error, 24, @"ZIP directory payload or entry size is invalid.");
            return NO;
        }
        if (!isDirectory) {
            if (entryBytes > kSBLMaxEntryBytes || totalBytes > kSBLMaxTotalBytes - MIN(entryBytes, kSBLMaxTotalBytes)) {
                sbl_set_error(error, 24, @"ZIP contains a file larger than 64 MB or more than 256 MB in total.");
                return NO;
            }
            totalBytes += entryBytes;
        }

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
        if (!sbl_zip_crc_matches(fileData, expectedCRC)) {
            sbl_set_error(error, 28, @"ZIP entry CRC32 does not match its central directory.");
            return NO;
        }
        // A cancel that arrived during inflate must not still write this entry.
        if (sbl_cancelled(progress, error)) return NO;
        if (!isDirectory) {
            if (!sbl_write_file(fileData, outPath, error)) return NO;
            extracted++;
        } else if (!sbl_create_directory_entry(outPath, explicitDirectories, error)) {
            return NO;
        }
    }

    if (p != (NSUInteger)eocd) {
        sbl_set_error(error, 23, @"ZIP central directory has trailing or missing entries.");
        return NO;
    }

    if (extracted == 0) {
        sbl_set_error(error, 22, @"ZIP did not contain extractable files.");
        return NO;
    }
    return YES;
}

// A ustar header holds 100 bytes of name (plus a 155-byte prefix). Longer
// paths travel in a record placed before the entry: GNU tar's 'L' record (the
// name itself) or a pax 'x' record ("<len> path=<name>\n" among other keys).
// dpkg-built themes reach 100 bytes easily
// (Library/Themes/<name>.theme/IconBundles/<bundle-id>-large.png), and with
// these records skipped the file was written under its cut-off name: the
// import "succeeded" with icons missing, or failed when two cut names collided.
static const NSUInteger kSBLMaxTarPathRecordBytes = 16 * 1024;

static NSString *sbl_tar_gnu_long_name(const uint8_t *bytes, NSUInteger size)
{
    NSUInteger n = 0;
    while (n < size && bytes[n] != 0) n++;
    return n ? [[NSString alloc] initWithBytes:bytes length:n encoding:NSUTF8StringEncoding] : nil;
}

// The "path" value of a pax extended header, or nil when it has none.
static NSString *sbl_tar_pax_path(const uint8_t *bytes, NSUInteger size)
{
    NSString *path = nil;
    NSUInteger pos = 0;
    while (pos < size) {
        // "<decimal length> <key>=<value>\n"; the length covers the whole record.
        NSUInteger recordLength = 0, digits = 0;
        while (pos + digits < size && bytes[pos + digits] >= '0' && bytes[pos + digits] <= '9' && digits < 10) {
            recordLength = recordLength * 10 + (NSUInteger)(bytes[pos + digits] - '0');
            digits++;
        }
        if (digits == 0 || pos + digits >= size || bytes[pos + digits] != ' ') break;
        if (recordLength <= digits + 1 || recordLength > size - pos) break;
        const uint8_t *body = bytes + pos + digits + 1;
        NSUInteger bodyLength = recordLength - digits - 1;
        if (bodyLength > 0 && body[bodyLength - 1] == '\n') bodyLength--;
        if (bodyLength > 5 && memcmp(body, "path=", 5) == 0) {
            path = [[NSString alloc] initWithBytes:body + 5 length:bodyLength - 5 encoding:NSUTF8StringEncoding];
        }
        pos += recordLength;
    }
    return path.length ? path : nil;
}

static BOOL sbl_extract_tar(NSData *tar, NSString *destination, NSProgress *progress, NSError **error)
{
    const uint8_t *b = tar.bytes;
    NSUInteger len = tar.length;
    NSUInteger p = 0;
    NSUInteger extracted = 0;
    NSUInteger entries = 0;
    uint64_t totalBytes = 0;
    BOOL ended = NO;
    NSMutableSet<NSString *> *explicitDirectories = [NSMutableSet set];
    NSString *pendingLongName = nil;   // from an 'L' or pax record, for the next entry

    while (p + 512 <= len) {
        if (sbl_cancelled(progress, error)) return NO;
        const uint8_t *h = b + p;
        BOOL empty = YES;
        for (NSUInteger i = 0; i < 512; i++) {
            if (h[i] != 0) { empty = NO; break; }
        }
        if (empty) { ended = YES; break; }
        // Same entry budget as the ZIP path: zero-byte entries never grow
        // totalBytes, so the byte cap alone does not bound the file count.
        if (++entries > SBLMaxImportFileCount) {
            sbl_set_error(error, 34, @"TAR contains too many entries.");
            return NO;
        }

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

        if (type == 'L' || type == 'x') {
            if (size > kSBLMaxTarPathRecordBytes) {
                sbl_set_error(error, 33, @"TAR contains an over-long path record.");
                return NO;
            }
            NSString *longName = type == 'L' ? sbl_tar_gnu_long_name(b + dataOff, size)
                                             : sbl_tar_pax_path(b + dataOff, size);
            if (type == 'L' && !longName) {
                sbl_set_error(error, 33, @"TAR contains an unreadable long file name.");
                return NO;
            }
            if (longName) pendingLongName = longName;
            p = next;
            continue;
        }
        if (type != 'K' && type != 'g' && pendingLongName) {
            // The real path of this entry. It goes through the same
            // sbl_safe_output_path check below as a header name does.
            name = pendingLongName;
            pendingLongName = nil;
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
            if (sbl_cancelled(progress, error)) return NO;
            if (!sbl_write_file(data, outPath, error)) return NO;
            extracted++;
        } else if (type == '5') {
            // The archive's own root ("./" -- the first entry of a standard
            // .deb data archive, and of any `tar -C dir .`) is not a path to
            // create: skip it. Any other directory must still be safe.
            NSString *bare = name ?: @"";
            while ([bare hasPrefix:@"./"]) bare = [bare substringFromIndex:2];
            while ([bare hasSuffix:@"/"]) bare = [bare substringToIndex:bare.length - 1];
            if (bare.length && ![bare isEqualToString:@"."]) {
                NSString *outPath = sbl_safe_output_path(destination, name);
                if (!outPath) {
                    sbl_set_error(error, 33, @"TAR contains an unsafe directory path.");
                    return NO;
                }
                if (!sbl_create_directory_entry(outPath, explicitDirectories, error)) return NO;
            }
        }
        // Everything else -- symlinks ('2'), hard links ('1'), global pax
        // ('g') and GNU long-link ('K') headers, device nodes -- is skipped,
        // as before: nothing is created for it. Failing on these made normal
        // .deb theme and passcode imports fail. Long names ('L') and pax path
        // records ('x') are applied to the entry they describe, above.
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

static NSString *sbl_create_staging_directory(NSString *parent, NSString *destination,
                                              NSError **error)
{
    NSString *leaf = destination.lastPathComponent.length > 0
        ? destination.lastPathComponent : @"archive";
    for (NSUInteger attempt = 0; attempt < 32; attempt++) {
        NSString *name = [NSString stringWithFormat:@".%@.extract-%@",
                          leaf, NSUUID.UUID.UUIDString];
        NSString *path = parent.length > 0
            ? [parent stringByAppendingPathComponent:name] : name;
        if (mkdir(path.fileSystemRepresentation, 0700) == 0) return path;
        if (errno != EEXIST) break;
    }
    sbl_set_error(error, 53, @"The archive staging directory could not be created exclusively.");
    return nil;
}

BOOL SBLExtractArchiveToDirectoryWithProgress(NSURL *url, NSString *destination,
                                              NSProgress *progress, NSError **error)
{
    if (sbl_cancelled(progress, error)) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    // The destination is committed only on success, so it must be new
    // or an empty directory: never clear a real folder (review F-35).
    if (destination.length == 0) {
        sbl_set_error(error, 53, @"No extraction destination was given.");
        return NO;
    }
    struct stat destStat;
    if (lstat(destination.fileSystemRepresentation, &destStat) == 0) {
        NSArray *contents = S_ISDIR(destStat.st_mode)
            ? [fm contentsOfDirectoryAtPath:destination error:nil] : nil;
        if (!contents || contents.count > 0) {
            sbl_set_error(error, 53, @"The extraction destination already exists and is not empty.");
            return NO;
        }
    }
    // Read the input through a descriptor with the cap enforced while
    // reading: the decompressed and entry bounds below only apply once the
    // archive is in memory, so its own size must never exceed the cap there.
    if (!url.isFileURL) {
        sbl_set_error(error, 54, @"Only local archive files can be imported.");
        return NO;
    }
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) {
        sbl_set_error(error, 51, @"The selected item is not a readable archive file.");
        return NO;
    }
    struct stat inStat;
    if (fstat(fd, &inStat) != 0 || !S_ISREG(inStat.st_mode)) {
        close(fd);
        sbl_set_error(error, 51, @"The selected item is not a regular archive file.");
        return NO;
    }
    if ((unsigned long long)inStat.st_size > SBLMaxArchiveInputBytes) {
        close(fd);
        sbl_set_error(error, 52, @"The archive is larger than 256 MB.");
        return NO;
    }
    NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)inStat.st_size];
    uint8_t chunk[1 << 16];
    BOOL tooLarge = NO, readFailed = NO;
    for (;;) {
        ssize_t got = read(fd, chunk, sizeof(chunk));
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) { readFailed = YES; break; }
        if (got == 0) break;
        if (data.length + (NSUInteger)got > SBLMaxArchiveInputBytes) { tooLarge = YES; break; }   // it grew
        [data appendBytes:chunk length:(NSUInteger)got];
    }
    close(fd);
    if (tooLarge) {
        sbl_set_error(error, 52, @"The archive is larger than 256 MB.");
        return NO;
    }
    if (readFailed || data.length == 0) {
        sbl_set_error(error, 51, @"The archive could not be read.");
        return NO;
    }

    NSString *ext = url.pathExtension.lowercaseString;
    const uint8_t *bytes = data.bytes;
    BOOL looksZip = data.length >= 4 && sbl_le32(bytes) == 0x04034b50;
    BOOL looksDeb = data.length >= 8 && memcmp(bytes, "!<arch>\n", 8) == 0;
    BOOL isZip = [ext isEqualToString:@"zip"] || looksZip;
    BOOL isDeb = [ext isEqualToString:@"deb"] || looksDeb;
    if (!isZip && !isDeb) {
        sbl_set_error(error, 50, @"Unsupported archive type. Choose a folder, .zip, or .deb.");
        return NO;
    }

    // Extract into a private same-parent directory. The destination is not
    // touched until every entry (including CRC and metadata checks) succeeds;
    // this keeps failed imports from exposing a partial tree. A final rmdir is
    // deliberately non-recursive, so a concurrent writer is never cleared.
    NSString *parent = destination.stringByDeletingLastPathComponent;
    if (parent.length > 0 &&
        ![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    NSString *staging = sbl_create_staging_directory(parent, destination, error);
    if (!staging) return NO;

    BOOL ok = NO;
    if (isZip) {
        ok = sbl_extract_zip(data, staging, progress, error);
    } else if (isDeb) {
        ok = sbl_extract_deb(data, staging, progress, error);
    }
    if (!ok) {
        [fm removeItemAtPath:staging error:nil];
        return NO;
    }
    if (sbl_cancelled(progress, error)) {
        [fm removeItemAtPath:staging error:nil];
        return NO;
    }
    if (rmdir(destination.fileSystemRepresentation) != 0 && errno != ENOENT) {
        [fm removeItemAtPath:staging error:nil];
        sbl_set_error(error, 53, @"The extraction destination is no longer empty; refusing to clear it.");
        return NO;
    }
    if (sbl_cancelled(progress, error)) {
        [fm removeItemAtPath:staging error:nil];
        return NO;
    }
    if (renamex_np(staging.fileSystemRepresentation, destination.fileSystemRepresentation, RENAME_EXCL) != 0) {
        [fm removeItemAtPath:staging error:nil];
        sbl_set_error(error, 53, @"The extracted archive could not be committed.");
        return NO;
    }
    return YES;
}

BOOL SBLExtractArchiveToDirectory(NSURL *url, NSString *destination, NSError **error)
{
    return SBLExtractArchiveToDirectoryWithProgress(url, destination, nil, error);
}
