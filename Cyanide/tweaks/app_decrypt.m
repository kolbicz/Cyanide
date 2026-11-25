//
//  app_decrypt.m
//  Cyanide
//
//  Decrypted IPAs of installed App Store apps. Idea from lara by rooootdev
//  (kexploit/decrypt.m); implemented differently: lara launches the app and
//  walks its vm_map with kernel reads, and leaves app extensions encrypted.
//  Here every Mach-O in the bundle is decrypted by mapping it into Cyanide and
//  asking the kernel's FairPlay pager to decrypt that mapping
//  (mremap_encrypted, as flexdecrypt does): no app launch, no RemoteCall into
//  the app, no kernel memory walking -- and extensions work the same way.
//

#import "app_decrypt.h"
#import "../FBAppContainers.h"
#import "../LogTextView.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../TaskRop/VM.h"
#import "../kexploit/kutils.h"
#import "../kexploit/kexploit_opa334.h"
#import "../utils/process.h"
#import <UIKit/UIKit.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

#pragma mark - App list

NSArray<NSDictionary *> *app_decrypt_store_apps(void)
{
    NSString *root = @"/var/containers/Bundle/Application";
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *apps = [NSMutableArray array];
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *container = [root stringByAppendingPathComponent:uuid];
        for (NSString *item in [fm contentsOfDirectoryAtPath:container error:nil]) {
            if (![item.pathExtension isEqualToString:@"app"]) continue;
            NSString *appPath = [container stringByAppendingPathComponent:item];
            // App Store installs carry FairPlay info; sideloaded ones a profile.
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:[appPath stringByAppendingPathComponent:@"SC_Info"] isDirectory:&isDir] || !isDir) continue;
            if ([fm fileExistsAtPath:[appPath stringByAppendingPathComponent:@"embedded.mobileprovision"]]) continue;
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bid = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? info[@"CFBundleIdentifier"] : @"";
            NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : @"";
            FBAppContainer *c = fb_container_for_path(container, NO);
            NSString *name = c.displayName.length ? c.displayName
                           : ([info[@"CFBundleDisplayName"] isKindOfClass:NSString.class] ? info[@"CFBundleDisplayName"]
                           : item.stringByDeletingPathExtension);
            NSMutableDictionary *app = [@{ @"name": name, @"bundleID": bid, @"version": version, @"path": appPath } mutableCopy];
            if (c.icon) app[@"icon"] = c.icon;
            [apps addObject:app];
        }
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return apps;
}

NSString *app_decrypt_output_dir(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"Decrypted"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

#pragma mark - Mach-O

typedef struct {
    uint64_t sliceOffset;
    uint32_t cputype, cpusubtype;
    uint32_t cryptoff, cryptsize, cryptid;
    uint64_t cryptidFileOffset;   // where to write cryptid = 0
    BOOL hasCodesign;             // LC_CODE_SIGNATURE present
    uint8_t uuid[16];             // LC_UUID: finds the image in a running process
    BOOL hasUUID;
} ADEncryptedSlice;

static BOOL ad_pread_all(int fd, void *buf, size_t len, off_t off)
{
    uint8_t *p = buf;
    while (len) {
        ssize_t n = pread(fd, p, len, off);
        if (n <= 0) return NO;
        p += n; len -= (size_t)n; off += n;
    }
    return YES;
}

static BOOL ad_pwrite_all(int fd, const void *buf, size_t len, off_t off)
{
    const uint8_t *p = buf;
    while (len) {
        ssize_t n = pwrite(fd, p, len, off);
        if (n <= 0) return NO;
        p += n; len -= (size_t)n; off += n;
    }
    return YES;
}

// The encrypted 64-bit slice at `off`, if any (cryptid != 0).
static BOOL ad_parse_slice(int fd, uint64_t off, uint64_t fileSize, ADEncryptedSlice *out)
{
    struct mach_header_64 mh;
    if (off + sizeof(mh) > fileSize || !ad_pread_all(fd, &mh, sizeof(mh), (off_t)off)) return NO;
    if (mh.magic != MH_MAGIC_64 || mh.sizeofcmds > 16 * 1024 * 1024) return NO;
    NSMutableData *cmds = [NSMutableData dataWithLength:mh.sizeofcmds];
    uint64_t cmdsOff = off + sizeof(mh);
    if (cmdsOff + mh.sizeofcmds > fileSize || !ad_pread_all(fd, cmds.mutableBytes, mh.sizeofcmds, (off_t)cmdsOff)) return NO;
    const uint8_t *p = cmds.bytes, *end = p + cmds.length;
    BOOL hasCodesign = NO, foundEncryption = NO, hasUUID = NO;
    uint8_t uuid[16] = {0};
    for (uint32_t i = 0; i < mh.ncmds && p + sizeof(struct load_command) <= end; i++) {
        const struct load_command *lc = (const void *)p;
        if (lc->cmdsize < sizeof(struct load_command) || p + lc->cmdsize > end) return NO;
        if (lc->cmd == LC_CODE_SIGNATURE) hasCodesign = YES;
        if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command)) {
            memcpy(uuid, ((const struct uuid_command *)(const void *)p)->uuid, 16);
            hasUUID = YES;
        }
        if (lc->cmd == LC_ENCRYPTION_INFO_64 && lc->cmdsize >= sizeof(struct encryption_info_command_64)) {
            const struct encryption_info_command_64 *e = (const void *)p;
            if (e->cryptid == 0) return NO;
            out->sliceOffset = off;
            out->hasCodesign = NO;
            out->cputype = (uint32_t)mh.cputype;
            out->cpusubtype = (uint32_t)mh.cpusubtype;
            out->cryptoff = e->cryptoff;
            out->cryptsize = e->cryptsize;
            out->cryptid = e->cryptid;
            out->cryptidFileOffset = cmdsOff + (uint64_t)(p - (const uint8_t *)cmds.bytes)
                                   + offsetof(struct encryption_info_command_64, cryptid);
            foundEncryption = YES;
        }
        p += lc->cmdsize;
    }
    if (foundEncryption) {
        out->hasCodesign = hasCodesign;
        out->hasUUID = hasUUID;
        memcpy(out->uuid, uuid, 16);
        return YES;
    }
    return NO;
}

// Every encrypted slice of the file (thin or fat). NO when it isn't a Mach-O.
static BOOL ad_encrypted_slices(int fd, uint64_t fileSize, NSMutableArray<NSValue *> *slices)
{
    uint32_t magic = 0;
    if (fileSize < 4 || !ad_pread_all(fd, &magic, 4, 0)) return NO;
    ADEncryptedSlice s;
    if (magic == MH_MAGIC_64) {
        if (ad_parse_slice(fd, 0, fileSize, &s)) [slices addObject:[NSValue valueWithBytes:&s objCType:@encode(ADEncryptedSlice)]];
        return YES;
    }
    if (magic == FAT_CIGAM || magic == FAT_CIGAM_64) {
        BOOL is64 = magic == FAT_CIGAM_64;
        struct fat_header fh;
        if (!ad_pread_all(fd, &fh, sizeof(fh), 0)) return NO;
        uint32_t n = OSSwapBigToHostInt32(fh.nfat_arch);
        if (n > 32) return NO;
        uint64_t at = sizeof(fh);
        for (uint32_t i = 0; i < n; i++) {
            uint64_t sliceOff;
            if (is64) {
                struct fat_arch_64 fa;
                if (!ad_pread_all(fd, &fa, sizeof(fa), (off_t)at)) return NO;
                sliceOff = OSSwapBigToHostInt64(fa.offset);
                at += sizeof(fa);
            } else {
                struct fat_arch fa;
                if (!ad_pread_all(fd, &fa, sizeof(fa), (off_t)at)) return NO;
                sliceOff = OSSwapBigToHostInt32(fa.offset);
                at += sizeof(fa);
            }
            if (ad_parse_slice(fd, sliceOff, fileSize, &s))
                [slices addObject:[NSValue valueWithBytes:&s objCType:@encode(ADEncryptedSlice)]];
        }
        return YES;
    }
    return magic == MH_MAGIC || magic == FAT_MAGIC;   // 32-bit / other-endian: a Mach-O, never encrypted here
}

typedef int (*ADMremapEncrypted)(void *addr, size_t len, uint32_t cryptid, uint32_t cputype, uint32_t cpusubtype);

// errno inside SpringBoard after a failed call.
static int ad_sb_errno(void)
{
    uint64_t p = r_dlsym_call(R_TIMEOUT, "__error", 0, 0, 0, 0, 0, 0, 0, 0);
    int e = 0;
    if (p && !remote_read(p, &e, sizeof(e))) e = 0;
    return e;
}

// The same decryption done by SpringBoard (unsandboxed; a crash there is only
// a respring): it maps `src`, has the kernel decrypt the range and writes the
// plaintext into `dst` (Cyanide's working copy) at the same offset. Needs an
// open SpringBoard session.
static BOOL ad_decrypt_range_in_springboard(NSString *src, NSString *dst, uint64_t aligned, size_t mapLen,
                                            size_t delta, uint64_t start, const void *slicePtr, NSString **why)
{
    const ADEncryptedSlice *s = slicePtr;
    uint64_t rsrc = r_alloc_str(src.fileSystemRepresentation), rdst = r_alloc_str(dst.fileSystemRepresentation);
    int fdIn = -1, fdOut = -1;
    BOOL ok = NO;
    do {
        if (!rsrc || !rdst) { *why = @"SpringBoard: no memory for the paths"; break; }
        fdIn = (int)r_dlsym_call(R_TIMEOUT, "open", rsrc, O_RDONLY | O_CLOEXEC, 0, 0, 0, 0, 0, 0);
        if (fdIn < 0) { *why = [NSString stringWithFormat:@"SpringBoard: open failed (%s)", strerror(ad_sb_errno())]; break; }
        fdOut = (int)r_dlsym_call(R_TIMEOUT, "open", rdst, O_WRONLY | O_CLOEXEC, 0, 0, 0, 0, 0, 0);
        if (fdOut < 0) { *why = [NSString stringWithFormat:@"SpringBoard: can't write the copy (%s)", strerror(ad_sb_errno())]; break; }
        struct { const char *name; size_t mapOff, addrOff, len, readOff; } variants[] = {
            { "page-range",        aligned, 0,     mapLen, delta },
            { "crypt-range",       aligned, delta, mapLen > delta ? mapLen - delta : 0, delta },
            { "crypt-exact",       aligned, delta, s->cryptsize, delta },
            { "page-exact",        aligned, 0,     s->cryptsize, delta },
            { "crypt-page",        aligned, delta, mapLen > delta + getpagesize() ? getpagesize() : 0, delta },
            { "prefix-page-range", 0,       aligned, mapLen, start },
            { "prefix-crypt-range", 0,      start, mapLen > delta ? mapLen - delta : 0, start },
            { "prefix-crypt-exact", 0,      start, s->cryptsize, start },
        };
        uint32_t subtypes[2] = { s->cpusubtype, s->cpusubtype & ~(uint32_t)CPU_SUBTYPE_MASK };
        for (size_t i = 0; i < sizeof(variants) / sizeof(variants[0]) && !ok; i++) {
            size_t mapSize = variants[i].mapOff + mapLen;
            if (variants[i].addrOff + variants[i].len > mapSize)
                mapSize = variants[i].addrOff + variants[i].len;
            if (variants[i].readOff + s->cryptsize > mapSize)
                mapSize = variants[i].readOff + s->cryptsize;
            mapSize = (mapSize + getpagesize() - 1) & ~(size_t)(getpagesize() - 1);
            if (!variants[i].len) continue;
            uint64_t map = r_dlsym_call(R_TIMEOUT, "mmap", 0, mapSize, PROT_READ, MAP_PRIVATE,
                                        (uint64_t)fdIn, variants[i].mapOff, 0, 0);
            if (!map || map == (uint64_t)-1) {
                *why = [NSString stringWithFormat:@"SpringBoard: mmap failed (%s)", strerror(ad_sb_errno())];
                break;
            }
            uint64_t addr = map + variants[i].addrOff;
            int r = -1, e = 0;
            for (int v = 0; v < 2 && r != 0; v++) {
                if (v == 1 && subtypes[1] == subtypes[0]) break;
                r = (int)r_dlsym_call(R_TIMEOUT, "mremap_encrypted", addr, variants[i].len,
                                      s->cryptid, s->cputype, subtypes[v], 0, 0, 0);
                if (r != 0) e = ad_sb_errno();
            }
            printf("[DECRYPT]   springboard %s map+0x%zx addr+0x%zx len=0x%zx: %s\n",
                   variants[i].name, variants[i].mapOff, variants[i].addrOff, variants[i].len,
                   r == 0 ? "ok" : strerror(e));
            if (r == 0) {
                uint64_t done = 0;
                BOOL wrote = YES;
                while (done < s->cryptsize) {
                    uint64_t chunk = MIN((uint64_t)s->cryptsize - done, 8ULL * 1024 * 1024);
                    int64_t n = (int64_t)r_dlsym_call(R_TIMEOUT, "pwrite", (uint64_t)fdOut,
                                                      map + variants[i].readOff + done, chunk, start + done, 0, 0, 0, 0);
                    if (n <= 0 || !r_last_call_ok()) { wrote = NO; break; }
                    done += (uint64_t)n;
                }
                if (wrote) {
                    uint8_t a[64], b[64];
                    int fsrc = open(src.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
                    int fdst = open(dst.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
                    BOOL differs = NO;
                    if (fsrc >= 0 && fdst >= 0 && pread(fsrc, a, sizeof(a), (off_t)start) == (ssize_t)sizeof(a) &&
                        pread(fdst, b, sizeof(b), (off_t)start) == (ssize_t)sizeof(b))
                        differs = memcmp(a, b, sizeof(a)) != 0;
                    if (fsrc >= 0) close(fsrc);
                    if (fdst >= 0) close(fdst);
                    if (differs) ok = YES;
                }
            }
            r_dlsym_call(R_TIMEOUT, "munmap", map, mapSize, 0, 0, 0, 0, 0, 0);
        }
        if (!ok) *why = @"SpringBoard: no accepted mremap variant";
    } while (0);
    if (fdIn >= 0) r_dlsym_call(R_TIMEOUT, "close", (uint64_t)fdIn, 0, 0, 0, 0, 0, 0, 0);
    if (fdOut >= 0) r_dlsym_call(R_TIMEOUT, "close", (uint64_t)fdOut, 0, 0, 0, 0, 0, 0, 0);
    if (rsrc) r_free(rsrc);
    if (rdst) r_free(rdst);
    return ok;
}

// mremap_encrypted has no cryptoff parameter: it decrypts the pages at the
// address it is given. For a 4 KB encrypted range inside a 16 KB file page,
// try the plausible address/length pairs. All mappings start at the 16 KB
// file boundary; the address is moved by `delta` for the crypt-range variants.
static BOOL ad_try_mremap_variants(int fd, int out, uint64_t start, size_t page,
                                   uint64_t aligned, size_t delta, size_t mapLen,
                                   const ADEncryptedSlice *s, ADMremapEncrypted fn,
                                   NSString **why)
{
    // mapOff is where the mmap starts in the file; addrOff is the address
    // passed to mremap; readOff is where the plaintext must be read from.
    struct { const char *name; size_t mapOff, addrOff, len, readOff; } variants[] = {
        { "page-range",         aligned, 0,     mapLen, delta },
        { "crypt-range",        aligned, delta, mapLen > delta ? mapLen - delta : 0, delta },
        { "crypt-exact",        aligned, delta, s->cryptsize, delta },
        { "page-exact",         aligned, 0,     s->cryptsize, delta },
        { "crypt-page",         aligned, delta, mapLen > delta + page ? page : 0, delta },
        { "prefix-page-range",  0,       aligned, mapLen, start },
        { "prefix-crypt-range", 0,       start, mapLen > delta ? mapLen - delta : 0, start },
        { "prefix-crypt-exact", 0,       start, s->cryptsize, start },
    };
    uint32_t subtypes[2] = { s->cpusubtype, s->cpusubtype & ~(uint32_t)CPU_SUBTYPE_MASK };
    for (size_t i = 0; i < sizeof(variants) / sizeof(variants[0]); i++) {
        size_t mapSize = variants[i].mapOff + mapLen;
        if (variants[i].addrOff + variants[i].len > mapSize)
            mapSize = variants[i].addrOff + variants[i].len;
        if (variants[i].readOff + s->cryptsize > mapSize)
            mapSize = variants[i].readOff + s->cryptsize;
        mapSize = (mapSize + page - 1) & ~(page - 1);
        if (!variants[i].len) continue;
        void *map = mmap(NULL, mapSize, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, (off_t)variants[i].mapOff);
        if (map == MAP_FAILED) map = mmap(NULL, mapSize, PROT_READ, MAP_PRIVATE, fd, (off_t)variants[i].mapOff);
        if (map == MAP_FAILED) {
            if (why) *why = [NSString stringWithFormat:@"mmap: %s", strerror(errno)];
            return NO;
        }
        uint64_t addr = (uint64_t)map + variants[i].addrOff;
        int r = -1, e = 0;
        for (int v = 0; v < 2 && r != 0; v++) {
            if (v == 1 && subtypes[1] == subtypes[0]) break;
            r = fn((void *)(uintptr_t)addr, variants[i].len, s->cryptid, s->cputype, subtypes[v]);
            if (r != 0) e = errno;
        }
        printf("[DECRYPT]   variant %s map+0x%zx addr+0x%zx len=0x%zx: %s\n",
               variants[i].name, variants[i].mapOff, variants[i].addrOff, variants[i].len,
               r == 0 ? "ok" : strerror(e));
        if (r == 0) {
            // Only accept bytes that actually differ from the encrypted file.
            uint8_t enc[64], dec[64];
            size_t probe = MIN(sizeof(enc), (size_t)s->cryptsize);
            if (!ad_pread_all(fd, enc, probe, (off_t)start)) {
                munmap(map, mapSize);
                if (why) *why = @"reading the encrypted probe failed";
                return NO;
            }
            memcpy(dec, (const uint8_t *)map + variants[i].readOff, probe);
            if (memcmp(enc, dec, probe) != 0) {
                BOOL wrote = ad_pwrite_all(out, (const uint8_t *)map + variants[i].readOff,
                                           s->cryptsize, (off_t)start);
                munmap(map, mapSize);
                if (!wrote) { if (why) *why = @"writing the copy failed"; return NO; }
                return YES;
            }
        }
        munmap(map, mapSize);
    }
    if (why) *why = @"mremap_encrypted: no accepted mapping variant";
    return NO;
}

// Writes a copy of `src` with every encrypted slice decrypted and its cryptid
// cleared to `dst`. *decrypted is NO when the file had nothing encrypted.
#pragma mark - Reading the decrypted code from the running app

// FairPlay decrypts an app's code for its own process: the encrypted range of
// each image is backed by an "apple protect" pager object that hands out
// plaintext pages. Cyanide finds those objects in the app's VM map and maps
// them into itself (vm_map_object_range); touching a page has the kernel
// decrypt it, so pages the app never ran come out decrypted too (lara copied
// only resident pages and left the rest encrypted).

@interface ADProcess : NSObject
@property (nonatomic) int pid;
@property (nonatomic) uint64_t vmMap;
@property (nonatomic, strong) NSMutableData *entries;                    // struct VMEntryInfo[], user space
@property (nonatomic, strong) NSMutableDictionary<NSData *, NSNumber *> *bases;   // LC_UUID -> load address of the slice
@property (nonatomic, copy) void (^copyProgress)(double fraction);      // within the slice being copied
@end
@implementation ADProcess
@end

static int ad_pid_for_bundle(uint64_t bundleStr)
{
    uint64_t clsPred = r_class("RBSProcessPredicate"), clsHandle = r_class("RBSProcessHandle");
    if (!r_is_objc_ptr(clsPred) || !r_is_objc_ptr(clsHandle)) return 0;
    uint64_t pred = r_msg2(clsPred, "predicateMatchingBundleIdentifier:", bundleStr, 0, 0, 0);
    uint64_t handle = r_is_objc_ptr(pred) ? r_msg2(clsHandle, "handleForPredicate:error:", pred, 0, 0, 0) : 0;
    return r_is_objc_ptr(handle) ? (int)(r_msg2(handle, "rbs_pid", 0, 0, 0, 0) & 0xffffffffULL) : 0;
}

static NSData *ad_uuid_key(const uint8_t uuid[16]) { return [NSData dataWithBytes:uuid length:16]; }

// LC_UUID of the Mach-O header at the start of `buf` (`len` mapped bytes).
// Large apps have more load commands than fit in one page: when LC_UUID
// wasn't reached, *need is how many bytes the header takes.
static BOOL ad_header_uuid(const uint8_t *buf, size_t len, uint8_t uuid[16], size_t *need)
{
    *need = 0;
    if (len < sizeof(struct mach_header_64)) return NO;
    const struct mach_header_64 *mh = (const void *)buf;
    if (mh->magic != MH_MAGIC_64) return NO;
    const uint8_t *p = buf + sizeof(*mh), *end = p + mh->sizeofcmds, *limit = buf + len;
    for (uint32_t i = 0; i < mh->ncmds && p + sizeof(struct load_command) <= end; i++) {
        const struct load_command *lc = (const void *)p;
        if (p + sizeof(*lc) > limit) break;
        if (lc->cmdsize < sizeof(*lc) || p + lc->cmdsize > end) return NO;
        if (p + lc->cmdsize > limit) break;
        if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command)) {
            memcpy(uuid, ((const struct uuid_command *)(const void *)p)->uuid, 16);
            return YES;
        }
        p += lc->cmdsize;
    }
    if (end > limit) *need = sizeof(*mh) + mh->sizeofcmds;
    return NO;
}

// Collects the app's map entries and finds where each wanted image (by
// UUID) starts. Kernel reads only on the app's own map entries.
static void ad_process_scan_once(ADProcess *proc, NSSet<NSData *> *wanted, BOOL verbose, NSUInteger *execCount)
{
    NSMutableData *entries = [NSMutableData data];
    vm_map_iterate_entries(proc.vmMap, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (start >= 0x7000000000ULL) return;               // user space only
        struct VMEntryInfo info;
        if (!vm_map_entry_info(entry, &info) || info.isSubmap || !info.object) return;
        [entries appendBytes:&info length:sizeof(info)];
    });
    proc.entries = entries;
    proc.bases = [NSMutableDictionary dictionary];
    const struct VMEntryInfo *e = entries.bytes;
    NSUInteger n = entries.length / sizeof(*e), logged = 0;
    size_t page = (size_t)getpagesize();
    *execCount = 0;
    for (NSUInteger i = 0; i < n; i++) {
        BOOL exec = (e[i].protection & VM_PROT_EXECUTE) != 0;
        if (exec) (*execCount)++;
        if (proc.bases.count >= wanted.count) continue;
        // A header starts code, or the read-only part right in front of it.
        BOOL beforeExec = i + 1 < n && e[i + 1].start == e[i].end && (e[i + 1].protection & VM_PROT_EXECUTE);
        if ((!exec && !beforeExec) || e[i].offset % page) continue;
        uint64_t size = e[i].end - e[i].start;
        size_t len = page, need = 0;
        uint8_t uuid[16];
        BOOL isImage = NO, mapped = NO;
        for (int pass = 0; pass < 2 && !isImage; pass++) {
            struct VMShmem m = vm_map_object_range(e[i].object, e[i].offset, len);
            if (!m.used) break;
            mapped = YES;
            isImage = ad_header_uuid((const uint8_t *)m.localAddress, len, uuid, &need);
            vm_shmem_release(&m, len);
            if (isImage || need <= len || need > size || need > (1u << 20)) break;
            len = (need + page - 1) & ~(page - 1);   // the whole header, then look again
        }
        BOOL hit = isImage && [wanted containsObject:ad_uuid_key(uuid)];
        if (verbose && logged < 60) {
            logged++;
            printf("[DECRYPT]   entry 0x%llx-0x%llx prot=%x off=0x%llx %s\n", e[i].start, e[i].end, e[i].protection,
                   e[i].offset, !mapped ? "unreadable" : hit ? "wanted image" : isImage ? "other image" :
                   need ? "header too large" : "no header");
        }
        // The header sits at the entry's start: that's the slice's offset 0.
        NSData *key = isImage ? ad_uuid_key(uuid) : nil;
        if (hit && !proc.bases[key]) proc.bases[key] = @(e[i].start);
    }
}

static BOOL ad_process_scan(ADProcess *proc, NSSet<NSData *> *wanted, NSString **why)
{
    if (!kexploit_krw_ready()) { *why = @"kernel access isn't active"; return NO; }
    char comm[64] = {0};
    uint64_t kproc = 0;
    if (procmgr_identity_for_pid(proc.pid, comm, sizeof(comm), &kproc) != 0 || !kproc) {
        *why = [NSString stringWithFormat:@"process %d not found", proc.pid];
        return NO;
    }
    uint64_t task = proc_task(kproc);
    proc.vmMap = task ? task_get_vm_map(task) : 0;
    if (!proc.vmMap) { *why = @"the app's memory map wasn't found"; return NO; }

    NSUInteger execCount = 0;
    for (int attempt = 0; attempt < 3; attempt++) {
        // Still starting up: give dyld a moment, then look again (with the
        // entries in the log on the last try).
        if (attempt) usleep(1500000);
        ad_process_scan_once(proc, wanted, attempt == 2, &execCount);
        if (proc.bases.count >= wanted.count) break;
    }
    printf("[DECRYPT] process %d (%s): %lu executable entries, %lu of %lu images found\n", proc.pid, comm,
           (unsigned long)execCount, (unsigned long)proc.bases.count, (unsigned long)wanted.count);
    if (!proc.bases.count) { *why = @"the app's code wasn't found in its memory"; return NO; }
    return YES;
}

// Copies the plaintext of [fileOff, fileOff+len) of the image with `uuid`
// into `out` at the same file offset.
static BOOL ad_process_copy(ADProcess *proc, const ADEncryptedSlice *s, int out, NSString **why)
{
    NSNumber *baseNum = s->hasUUID ? proc.bases[ad_uuid_key(s->uuid)] : nil;
    if (!baseNum) { *why = @"not loaded in the running app"; return NO; }
    uint64_t base = baseNum.unsignedLongLongValue;   // address of the slice's file offset 0
    size_t page = (size_t)getpagesize();
    const struct VMEntryInfo *e = proc.entries.bytes;
    NSUInteger n = proc.entries.length / sizeof(*e);
    uint64_t fileStart = s->cryptoff, fileEnd = (uint64_t)s->cryptoff + s->cryptsize;   // within the slice
    uint64_t pos = fileStart;
    while (pos < fileEnd) {
        uint64_t addr = base + pos;
        uint64_t pageAddr = addr & ~((uint64_t)page - 1);
        const struct VMEntryInfo *hit = NULL;
        for (NSUInteger i = 0; i < n; i++) if (pageAddr >= e[i].start && pageAddr < e[i].end) { hit = &e[i]; break; }
        if (!hit) { *why = [NSString stringWithFormat:@"address 0x%llx isn't mapped in the app", addr]; return NO; }
        uint64_t chunk = MIN(hit->end - pageAddr, 1ULL << 20);
        uint64_t want = fileEnd - pos + (addr - pageAddr);
        chunk = MIN(chunk, (want + page - 1) & ~((uint64_t)page - 1));
        struct VMShmem m = vm_map_object_range(hit->object, hit->offset + (pageAddr - hit->start), chunk);
        if (!m.used) { *why = [NSString stringWithFormat:@"mapping 0x%llx failed", pageAddr]; return NO; }
        uint64_t avail = chunk - (addr - pageAddr);
        uint64_t take = MIN(avail, fileEnd - pos);
        BOOL wrote = ad_pwrite_all(out, (const uint8_t *)m.localAddress + (addr - pageAddr), (size_t)take,
                                   (off_t)(s->sliceOffset + pos));
        vm_shmem_release(&m, chunk);
        if (!wrote) { *why = @"writing the copy failed"; return NO; }
        pos += take;
        if (proc.copyProgress) proc.copyProgress((double)(pos - fileStart) / (double)(fileEnd - fileStart));
    }
    return YES;
}

// Starts the app in the background (FrontBoard's "activate suspended"), so
// Cyanide stays in front and keeps its kernel access; falls back to opening
// it and having SpringBoard bring Cyanide back. Returns the pid, 0 on failure.
static int ad_launch_for_decrypt(NSString *bundleID, NSString **why)
{
    uint64_t bid = r_cfstr(bundleID.UTF8String);
    if (!bid) { *why = @"SpringBoard: no memory"; return 0; }
    int pid = ad_pid_for_bundle(bid);
    if (pid > 0) return pid;
    uint64_t svc = r_class("FBSSystemService");
    svc = r_is_objc_ptr(svc) ? r_msg2(svc, "sharedService", 0, 0, 0, 0) : 0;
    uint64_t yes = r_msg2(r_class("NSNumber"), "numberWithBool:", 1, 0, 0, 0);
    uint64_t opts = r_msg2(r_class("NSDictionary"), "dictionaryWithObject:forKey:", yes, r_cfstr("__ActivateSuspended"), 0, 0);
    if (r_is_objc_ptr(svc) && r_is_objc_ptr(opts)) {
        r_msg2_main(svc, "openApplication:options:withResult:", bid, opts, 0, 0);
        for (int i = 0; i < 30 && pid <= 0; i++) { usleep(200000); pid = ad_pid_for_bundle(bid); }
        if (pid > 0) {
            printf("[DECRYPT] %s started in the background (pid %d)\n", bundleID.UTF8String, pid);
            usleep(1500000);   // let dyld map the frameworks
            return pid;
        }
    }
    printf("[DECRYPT] background launch of %s failed; opening it\n", bundleID.UTF8String);
    *why = @"the app didn't start in the background";
    return 0;
}

static BOOL ad_decrypt_file(NSString *src, NSString *dst, BOOL useSpringBoard, ADProcess *proc,
                            BOOL *decrypted, NSString **errorOut)
{
    static dispatch_once_t adBuildOnce;
    dispatch_once(&adBuildOnce, ^{
        printf("[DECRYPT] no-launch mremap variants active (compiled %s %s)\n", __DATE__, __TIME__);
    });
    *decrypted = NO;
    static ADMremapEncrypted mremapEncrypted;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mremapEncrypted = (ADMremapEncrypted)dlsym(RTLD_DEFAULT, "mremap_encrypted"); });

    int fd = open(src.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { *errorOut = [NSString stringWithFormat:@"%@: can't be read (%s)", src.lastPathComponent, strerror(errno)]; return NO; }
    struct stat st;
    fstat(fd, &st);
    NSMutableArray<NSValue *> *slices = [NSMutableArray array];
    ad_encrypted_slices(fd, (uint64_t)st.st_size, slices);
    if (!slices.count) { close(fd); return YES; }
    if (!mremapEncrypted && !useSpringBoard) { close(fd); *errorOut = @"This iOS version has no mremap_encrypted."; return NO; }

    NSError *err = nil;
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    if (![NSFileManager.defaultManager copyItemAtPath:src toPath:dst error:&err]) {
        close(fd);
        *errorOut = [NSString stringWithFormat:@"%@: copy failed (%@)", src.lastPathComponent, err.localizedDescription];
        return NO;
    }
    int out = open(dst.fileSystemRepresentation, O_RDWR | O_CLOEXEC);
    if (out < 0) { close(fd); *errorOut = @"The working copy can't be written."; return NO; }

    size_t page = (size_t)getpagesize();
    BOOL ok = YES;
    for (NSValue *v in slices) {
        ADEncryptedSlice s;
        [v getValue:&s];
        uint64_t start = s.sliceOffset + s.cryptoff;
        // mmap needs a page-aligned offset, and pages are 16 KB on arm64
        // while encrypted ranges are only 4 KB aligned (extensions often):
        // map from the page boundary below and skip `delta` bytes. The pager
        // decrypts by absolute file offset, so the range itself comes out right.
        uint64_t aligned = start & ~((uint64_t)page - 1);
        size_t delta = (size_t)(start - aligned);
        // Whole pages: on a 16 KB system the kernel rejects a partial last
        // page (a 4 KB range in an app extension failed with ENOMEM).
        size_t mapLen = ((delta + s.cryptsize) + page - 1) & ~(page - 1);
        // 1) Here, in Cyanide. Trying address/length pairs matters for a
        // 4 KB encrypted range inside a 16 KB page: mremap has no cryptoff.
        printf("[DECRYPT] %s: cpu=0x%x/0x%x cryptid=%u slice=0x%llx cryptoff=0x%x (16K-aligned=%d) codesign=%d map=0x%llx+0x%zx\n",
               src.lastPathComponent.UTF8String, s.cputype, s.cpusubtype, s.cryptid, s.sliceOffset, s.cryptoff,
               (int)((start % page) == 0), (int)s.hasCodesign, aligned, mapLen);
        // 0) From the running app, once it's been started for this.
        if (proc) {
            NSString *procWhy = nil;
            BOOL procOK = ad_process_copy(proc, &s, out, &procWhy);
            printf("[DECRYPT] %s: from process %d: %s\n", src.lastPathComponent.UTF8String, proc.pid,
                   procOK ? "ok" : procWhy.UTF8String);
            if (!procOK) {
                *errorOut = [NSString stringWithFormat:@"%@: %@", src.lastPathComponent, procWhy];
                ok = NO; break;
            }
        } else {
        NSString *localWhy = nil;
        BOOL localOK = mremapEncrypted &&
            ad_try_mremap_variants(fd, out, start, page, aligned, delta, mapLen,
                                   &s, mremapEncrypted, &localWhy);
        if (!localOK && !localWhy) localWhy = @"no mremap_encrypted";
        printf("[DECRYPT] %s: off=0x%llx size=0x%x delta=0x%zx local=%s\n", src.lastPathComponent.UTF8String,
               start, s.cryptsize, delta, localOK ? "ok" : localWhy.UTF8String);
        // 2) In SpringBoard, when Cyanide may not decrypt itself.
        if (!localOK) {
            NSString *sbWhy = nil;
            BOOL sbOK = useSpringBoard &&
                ad_decrypt_range_in_springboard(src, dst, aligned, mapLen, delta, start, &s, &sbWhy);
            printf("[DECRYPT] %s: springboard=%s\n", src.lastPathComponent.UTF8String,
                   !useSpringBoard ? "not available" : sbOK ? "ok" : sbWhy.UTF8String);
            if (!sbOK) {
                *errorOut = [NSString stringWithFormat:@"%@: iOS refused to decrypt it (Cyanide: %@%@)", src.lastPathComponent,
                             localWhy, useSpringBoard ? [@"; " stringByAppendingString:sbWhy ?: @"SpringBoard failed"] : @""];
                ok = NO; break;
            }
        }
        }
        // Proof it really decrypted: the copy must differ from the original here.
        uint8_t enc[64], dec[64];
        size_t probe = MIN(sizeof(enc), (size_t)s.cryptsize);
        if (ad_pread_all(fd, enc, probe, (off_t)start) && pread(out, dec, probe, (off_t)start) == (ssize_t)probe &&
            memcmp(enc, dec, probe) == 0) {
            *errorOut = [NSString stringWithFormat:@"%@: the kernel returned still-encrypted data", src.lastPathComponent];
            ok = NO; break;
        }
        uint32_t zero = 0;
        ok = ad_pwrite_all(out, &zero, sizeof(zero), (off_t)s.cryptidFileOffset);
        if (!ok) { *errorOut = @"Writing the decrypted copy failed."; break; }
        printf("[DECRYPT] %s: slice cpu=0x%x off=0x%llx size=0x%x decrypted\n",
               src.lastPathComponent.UTF8String, s.cputype, start, s.cryptsize);
    }
    close(out);
    close(fd);
    if (!ok) [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    *decrypted = ok;
    return ok;
}

#pragma mark - ZIP (stored, ZIP64 when needed)

@interface ADZipWriter : NSObject
@property (nonatomic) int fd;
@property (nonatomic) uint64_t offset;
@property (nonatomic, strong) NSMutableData *central;
@property (nonatomic) uint64_t entries;
@end

@implementation ADZipWriter

static void ad_put16(NSMutableData *d, uint16_t v) { [d appendBytes:&v length:2]; }
static void ad_put32(NSMutableData *d, uint32_t v) { [d appendBytes:&v length:4]; }
static void ad_put64(NSMutableData *d, uint64_t v) { [d appendBytes:&v length:8]; }

static void ad_dos_time(time_t t, uint16_t *dosTime, uint16_t *dosDate)
{
    struct tm tm;
    localtime_r(&t, &tm);
    if (tm.tm_year < 80) { *dosTime = 0; *dosDate = (1 << 5) | 1; return; }
    *dosTime = (uint16_t)((tm.tm_hour << 11) | (tm.tm_min << 5) | (tm.tm_sec / 2));
    *dosDate = (uint16_t)(((tm.tm_year - 80) << 9) | ((tm.tm_mon + 1) << 5) | tm.tm_mday);
}

- (BOOL)writeData:(NSData *)d
{
    const uint8_t *p = d.bytes;
    size_t left = d.length;
    while (left) {
        ssize_t n = write(self.fd, p, left);
        if (n <= 0) return NO;
        p += n; left -= (size_t)n;
    }
    self.offset += d.length;
    return YES;
}

- (BOOL)addEntry:(NSString *)name mode:(mode_t)mode mtime:(time_t)mtime
            size:(uint64_t)size crc:(uint32_t)crc body:(BOOL (^)(void))body
{
    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
    BOOL zip64 = size >= 0xFFFFFFFFULL || self.offset >= 0xFFFFFFFFULL;
    uint16_t t, dt;
    ad_dos_time(mtime, &t, &dt);
    uint64_t localOffset = self.offset;

    NSMutableData *h = [NSMutableData data];
    ad_put32(h, 0x04034b50);
    ad_put16(h, zip64 ? 45 : 20);
    ad_put16(h, 0x0800);                 // UTF-8 names
    ad_put16(h, 0);                      // stored
    ad_put16(h, t); ad_put16(h, dt);
    ad_put32(h, crc);
    ad_put32(h, zip64 ? 0xFFFFFFFF : (uint32_t)size);
    ad_put32(h, zip64 ? 0xFFFFFFFF : (uint32_t)size);
    ad_put16(h, (uint16_t)nameData.length);
    ad_put16(h, zip64 ? 20 : 0);
    [h appendData:nameData];
    if (zip64) { ad_put16(h, 0x0001); ad_put16(h, 16); ad_put64(h, size); ad_put64(h, size); }
    if (![self writeData:h]) return NO;
    if (body && !body()) return NO;

    NSMutableData *c = self.central;
    ad_put32(c, 0x02014b50);
    ad_put16(c, (3 << 8) | 45);         // made by Unix
    ad_put16(c, zip64 ? 45 : 20);
    ad_put16(c, 0x0800);
    ad_put16(c, 0);
    ad_put16(c, t); ad_put16(c, dt);
    ad_put32(c, crc);
    ad_put32(c, zip64 ? 0xFFFFFFFF : (uint32_t)size);
    ad_put32(c, zip64 ? 0xFFFFFFFF : (uint32_t)size);
    ad_put16(c, (uint16_t)nameData.length);
    ad_put16(c, zip64 ? 28 : 0);
    ad_put16(c, 0); ad_put16(c, 0); ad_put16(c, 0);
    ad_put32(c, ((uint32_t)mode << 16) | (S_ISDIR(mode) ? 0x10 : 0));
    ad_put32(c, zip64 ? 0xFFFFFFFF : (uint32_t)localOffset);
    [c appendData:nameData];
    if (zip64) { ad_put16(c, 0x0001); ad_put16(c, 24); ad_put64(c, size); ad_put64(c, size); ad_put64(c, localOffset); }
    self.entries++;
    return YES;
}

- (BOOL)finish
{
    uint64_t cdOffset = self.offset, cdSize = self.central.length;
    if (![self writeData:self.central]) return NO;
    BOOL zip64 = self.entries >= 0xFFFF || cdOffset >= 0xFFFFFFFFULL || cdSize >= 0xFFFFFFFFULL;
    NSMutableData *e = [NSMutableData data];
    if (zip64) {
        uint64_t z64Offset = self.offset;
        ad_put32(e, 0x06064b50); ad_put64(e, 44);
        ad_put16(e, (3 << 8) | 45); ad_put16(e, 45);
        ad_put32(e, 0); ad_put32(e, 0);
        ad_put64(e, self.entries); ad_put64(e, self.entries);
        ad_put64(e, cdSize); ad_put64(e, cdOffset);
        ad_put32(e, 0x07064b50); ad_put32(e, 0); ad_put64(e, z64Offset); ad_put32(e, 1);
    }
    ad_put32(e, 0x06054b50);
    ad_put16(e, 0); ad_put16(e, 0);
    ad_put16(e, zip64 ? 0xFFFF : (uint16_t)self.entries);
    ad_put16(e, zip64 ? 0xFFFF : (uint16_t)self.entries);
    ad_put32(e, zip64 ? 0xFFFFFFFF : (uint32_t)cdSize);
    ad_put32(e, zip64 ? 0xFFFFFFFF : (uint32_t)cdOffset);
    ad_put16(e, 0);
    return [self writeData:e];
}

@end

static BOOL ad_crc_file(NSString *path, uint32_t *crcOut)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    uLong crc = crc32(0, NULL, 0);
    static const size_t kBuf = 1 << 20;
    uint8_t *buf = malloc(kBuf);
    ssize_t n;
    while ((n = read(fd, buf, kBuf)) > 0) crc = crc32(crc, buf, (uInt)n);
    free(buf);
    close(fd);
    if (n < 0) return NO;
    *crcOut = (uint32_t)crc;
    return YES;
}

static BOOL ad_copy_into(int out, NSString *path, uint64_t *written)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    static const size_t kBuf = 1 << 20;
    uint8_t *buf = malloc(kBuf);
    ssize_t n;
    BOOL ok = YES;
    while (ok && (n = read(fd, buf, kBuf)) > 0) {
        uint8_t *p = buf;
        while (n > 0) {
            ssize_t w = write(out, p, (size_t)n);
            if (w <= 0) { ok = NO; break; }
            p += w; n -= w; *written += (uint64_t)w;
        }
    }
    if (n < 0) ok = NO;
    free(buf);
    close(fd);
    return ok;
}

#pragma mark - IPA

static NSString *ad_rewritten_bundle_id(NSString *original, NSString *newID, NSString *candidate)
{
    if (![candidate isKindOfClass:NSString.class] || !candidate.length ||
        ![original isKindOfClass:NSString.class] || !original.length) return candidate;
    if ([candidate isEqualToString:original]) return newID;
    NSString *prefix = [original stringByAppendingString:@"."];
    if ([candidate hasPrefix:prefix]) {
        return [newID stringByAppendingString:[candidate substringFromIndex:original.length]];
    }
    return candidate;
}

// Rewrites CFBundleIdentifier (and the Watch/extension companion keys) in
// every Info.plist in `files`, writing the modified plist into `work` and
// registering it in `replaced` so the zip writer picks it up. Returns YES if
// at least the main Info.plist was changed.
static BOOL ad_rewrite_bundle_ids(NSString *appPath,
                                  NSArray<NSString *> *files,
                                  NSString *work,
                                  NSString *originalID,
                                  NSString *newID,
                                  NSMutableDictionary<NSString *, NSString *> *replaced,
                                  NSString **errorOut)
{
    __block NSUInteger changed = 0;
    __block NSUInteger index = 0;
    for (NSString *rel in files) {
        if (![rel.lastPathComponent isEqualToString:@"Info.plist"]) continue;
        NSString *src = [appPath stringByAppendingPathComponent:rel];
        NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:src];
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *plist = [raw mutableCopy];
        BOOL touched = NO;
        NSString *bid = plist[@"CFBundleIdentifier"];
        if ([bid isKindOfClass:NSString.class] && bid.length) {
            NSString *newBid = ad_rewritten_bundle_id(originalID, newID, bid);
            if (newBid && ![newBid isEqualToString:bid]) {
                plist[@"CFBundleIdentifier"] = newBid;
                touched = YES;
            }
        }
        for (NSString *key in @[ @"WKCompanionAppBundleIdentifier", @"WKAppBundleIdentifier" ]) {
            NSString *value = plist[key];
            if (![value isKindOfClass:NSString.class] || !value.length) continue;
            NSString *rewritten = ad_rewritten_bundle_id(originalID, newID, value);
            if (rewritten && ![rewritten isEqualToString:value]) {
                plist[key] = rewritten;
                touched = YES;
            }
        }
        if (!touched) continue;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0
                                                                   error:nil];
        if (!data) {
            if (errorOut) *errorOut = [NSString stringWithFormat:@"Could not rewrite %@.", rel];
            return NO;
        }
        NSString *dst = [work stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"plist-%lu.bin", (unsigned long)index++]];
        if (![data writeToFile:dst atomically:YES]) {
            if (errorOut) *errorOut = [NSString stringWithFormat:@"Could not write %@.", rel];
            return NO;
        }
        replaced[rel] = dst;
        changed++;
    }
    if (changed == 0) {
        if (errorOut) *errorOut = @"The app's Info.plist could not be rewritten.";
        return NO;
    }
    return YES;
}

static NSString *ad_safe_name(NSString *s)
{
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?*\"<>|"];
    return [[s componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
}

NSString *app_decrypt_make_ipa(NSDictionary *app, BOOL useSpringBoard,
                               NSString *customBundleID,
                               void (^progress)(NSString *, double), NSString **errorOut)
{
    NSString *appPath = app[@"path"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *errorText = nil;
    if (!appPath.length || ![fm fileExistsAtPath:appPath]) { if (errorOut) *errorOut = @"The app is no longer installed."; return nil; }
    void (^report)(NSString *, double) = ^(NSString *step, double f) { if (progress) progress(step, f); };

    // 1. Everything in the bundle (no symlinked folders followed), minus the
    //    FairPlay keys, which have no place in a decrypted copy.
    NSMutableArray<NSString *> *files = [NSMutableArray array];   // relative paths
    uint64_t totalBytes = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:appPath];
    for (NSString *rel in en) {
        if ([rel isEqualToString:@"SC_Info"] || [rel hasPrefix:@"SC_Info/"]) { [en skipDescendants]; continue; }
        [files addObject:rel];
        struct stat st;
        if (lstat([appPath stringByAppendingPathComponent:rel].fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode))
            totalBytes += (uint64_t)st.st_size;
    }

    NSString *outDir = app_decrypt_output_dir();
    NSDictionary *attrs = [fm attributesOfFileSystemForPath:outDir error:nil];
    uint64_t freeBytes = [attrs[NSFileSystemFreeSize] unsignedLongLongValue];
    if (freeBytes && freeBytes < totalBytes + totalBytes / 5 + 50ULL * 1024 * 1024) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"Not enough free space: the IPA needs about %@.",
                                   [NSByteCountFormatter stringFromByteCount:(long long)totalBytes countStyle:NSByteCountFormatterCountStyleFile]];
        return nil;
    }

    // 2. Decrypt every encrypted Mach-O into a work folder.
    NSString *work = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [@"Decrypt-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary<NSString *, NSString *> *replaced = [NSMutableDictionary dictionary];
    // The app's own executable first (if that can't be decrypted, nothing
    // else matters), then frameworks, then extensions -- an extension that
    // can't be decrypted is left out of the IPA instead of failing it.
    NSString *mainExec = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleExecutable"];
    NSArray<NSString *> *ordered = [files sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger (^rank)(NSString *) = ^NSInteger(NSString *r) {
            if ([mainExec isKindOfClass:NSString.class] && [r isEqualToString:mainExec]) return 0;
            if ([r containsString:@".appex/"] || [r hasPrefix:@"Watch/"]) return 2;
            return 1;
        };
        return [@(rank(a)) compare:@(rank(b))];
    }];
    NSMutableSet<NSString *> *droppedBundles = [NSMutableSet set];   // extension bundles left out
    // Progress: 5-45 % decrypting (by file size: the big executables take
    // the time), 45-100 % packing.
    __block uint64_t doneBytes = 0;
    __block uint64_t fileBytes = 0;
    __block NSString *fileName = nil;
    void (^fileProgress)(double) = ^(double f) {
        report([@"Decrypting " stringByAppendingString:fileName ?: @""],
               0.05 + 0.4 * ((double)doneBytes + f * (double)fileBytes) / (double)MAX(totalBytes, 1ULL));
    };
    // Once mremap_encrypted is refused (iOS 18 refuses it outright), the app
    // is started in the background and every image is read from it instead.
    __block ADProcess *proc = nil;
    __block BOOL procTried = NO;
    __block NSString *procWhy = nil;
    BOOL (^startProcess)(void) = ^BOOL{
        if (procTried) return proc != nil;
        procTried = YES;
        NSMutableSet<NSData *> *wanted = [NSMutableSet set];
        for (NSString *rel in ordered) {
            if ([rel containsString:@".appex/"] || [rel hasPrefix:@"Watch/"]) continue;   // other processes
            int fd = open([appPath stringByAppendingPathComponent:rel].fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
            if (fd < 0) continue;
            struct stat fst;
            NSMutableArray<NSValue *> *slices = [NSMutableArray array];
            if (fstat(fd, &fst) == 0 && S_ISREG(fst.st_mode) && fst.st_size >= 4096) ad_encrypted_slices(fd, (uint64_t)fst.st_size, slices);
            close(fd);
            for (NSValue *v in slices) {
                ADEncryptedSlice es;
                [v getValue:&es];
                if (es.hasUUID) [wanted addObject:ad_uuid_key(es.uuid)];
            }
        }
        NSString *why = nil;
        report(@"Starting the app in the background", 0.05);
        int pid = [app[@"bundleID"] length] ? ad_launch_for_decrypt(app[@"bundleID"], &why) : 0;
        if (pid > 0) {
            ADProcess *p = [ADProcess new];
            p.pid = pid;
            p.copyProgress = fileProgress;
            if (ad_process_scan(p, wanted, &why)) proc = p;
        }
        procWhy = why;
        return proc != nil;
    };
    NSUInteger index = 0;
    for (NSString *rel in ordered) {
        index++;
        NSString *src = [appPath stringByAppendingPathComponent:rel];
        struct stat st;
        if (lstat(src.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        BOOL inDropped = NO;   // the rest of a bundle already left out
        for (NSString *bundle in droppedBundles)
            if ([rel hasPrefix:[bundle stringByAppendingString:@"/"]]) { inDropped = YES; break; }
        doneBytes += fileBytes;
        fileBytes = (uint64_t)st.st_size;
        if (inDropped) continue;
        fileName = rel.lastPathComponent;
        if (st.st_size < 4096) continue;
        NSString *dst = [work stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.bin", (unsigned long)index]];
        BOOL decrypted = NO;
        NSString *err = nil;
        fileProgress(0);
        BOOL fileOK = ad_decrypt_file(src, dst, useSpringBoard, proc, &decrypted, &err);
        BOOL inExtension = [rel containsString:@".appex/"] || [rel hasPrefix:@"Watch/"];
        if (!fileOK && !proc && !inExtension && useSpringBoard && startProcess()) {
            err = nil;
            fileOK = ad_decrypt_file(src, dst, useSpringBoard, proc, &decrypted, &err);
        } else if (!fileOK && procWhy && !inExtension) {
            err = [NSString stringWithFormat:@"%@ (reading it from the running app: %@)", err, procWhy];
        }
        if (!fileOK) {
            // Inside the Watch app or an .appex: drop that whole bundle (the
            // Watch folder, the extension), keep going.
            NSRange appex = [rel rangeOfString:@".appex/"];
            NSString *bundle = [rel hasPrefix:@"Watch/"] ? @"Watch"
                             : appex.location != NSNotFound ? [rel substringToIndex:appex.location + 6]   // ".../Name.appex"
                             : nil;
            if (bundle) {
                [droppedBundles addObject:bundle];
                log_user("[DECRYPT] Leaving out %s: %s\n", bundle.UTF8String, err.UTF8String);
                continue;
            }
            errorText = err;
            break;
        }
        if (decrypted) replaced[rel] = dst;
    }
    if (!errorText && replaced.count == 0) errorText = @"Nothing in this app is encrypted, or it couldn't be read.";
    if (errorText) {
        [fm removeItemAtPath:work error:nil];
        log_user("[DECRYPT] Failed: %s\n", errorText.UTF8String);
        if (errorOut) *errorOut = errorText;
        return nil;
    }

    // 2b. Optional custom bundle ID: rewrite the main bundle and every nested
    // extension/Watch bundle ID that is derived from it. The caller still has
    // to sign the IPA with a profile that covers the new ID.
    if (!errorText && customBundleID.length) {
        report(@"Rewriting bundle identifiers", 0.44);
        NSString *rewriteError = nil;
        if (!ad_rewrite_bundle_ids(appPath, files, work,
                                   app[@"bundleID"], customBundleID,
                                   replaced, &rewriteError)) {
            errorText = rewriteError ?: @"The bundle identifiers could not be rewritten.";
        } else {
            log_user("[DECRYPT] Bundle identifiers rewritten to %s\n", customBundleID.UTF8String);
        }
    }
    if (errorText) {
        [fm removeItemAtPath:work error:nil];
        log_user("[DECRYPT] Failed: %s\n", errorText.UTF8String);
        if (errorOut) *errorOut = errorText;
        return nil;
    }

    // 3. Pack Payload/<App>.app into the IPA (stored; IPAs don't need deflate).
    NSString *version = [app[@"version"] length] ? app[@"version"] : @"0";
    NSString *suffix = customBundleID.length ? @"_custom" : @"";
    NSString *ipa = [outDir stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@_%@_decrypted%@.ipa", ad_safe_name(app[@"name"] ?: @"App"), ad_safe_name(version), suffix]];
    NSString *partial = [ipa stringByAppendingString:@".part"];
    int fd = open(partial.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) { [fm removeItemAtPath:work error:nil]; if (errorOut) *errorOut = @"The IPA can't be created."; return nil; }
    ADZipWriter *zip = [ADZipWriter new];
    zip.fd = fd;
    zip.central = [NSMutableData data];
    NSString *prefix = [@"Payload/" stringByAppendingString:appPath.lastPathComponent];
    __block uint64_t packed = 0;
    BOOL ok = [zip addEntry:@"Payload/" mode:S_IFDIR | 0755 mtime:time(NULL) size:0 crc:0 body:nil] &&
              [zip addEntry:[prefix stringByAppendingString:@"/"] mode:S_IFDIR | 0755 mtime:time(NULL) size:0 crc:0 body:nil];
    for (NSString *rel in files) {
        if (!ok) break;
        BOOL dropped = NO;
        for (NSString *bundle in droppedBundles)
            if ([rel isEqualToString:bundle] || [rel hasPrefix:[bundle stringByAppendingString:@"/"]]) { dropped = YES; break; }
        if (dropped) continue;
        NSString *src = [appPath stringByAppendingPathComponent:rel];
        NSString *name = [prefix stringByAppendingPathComponent:rel];
        struct stat st;
        if (lstat(src.fileSystemRepresentation, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            ok = [zip addEntry:[name stringByAppendingString:@"/"] mode:st.st_mode mtime:st.st_mtime size:0 crc:0 body:nil];
        } else if (S_ISLNK(st.st_mode)) {
            char target[PATH_MAX];
            ssize_t n = readlink(src.fileSystemRepresentation, target, sizeof(target));
            if (n <= 0) continue;
            NSData *d = [NSData dataWithBytes:target length:(NSUInteger)n];
            uint32_t crc = (uint32_t)crc32(crc32(0, NULL, 0), d.bytes, (uInt)d.length);
            ok = [zip addEntry:name mode:st.st_mode mtime:st.st_mtime size:d.length crc:crc body:^BOOL{ return [zip writeData:d]; }];
        } else if (S_ISREG(st.st_mode)) {
            NSString *from = replaced[rel] ?: src;
            struct stat fs;
            uint32_t crc = 0;
            if (stat(from.fileSystemRepresentation, &fs) != 0 || !ad_crc_file(from, &crc)) {
                errorText = [NSString stringWithFormat:@"%@ can't be read.", rel];
                ok = NO; break;
            }
            report([@"Packing " stringByAppendingString:rel.lastPathComponent],
                   0.45 + 0.55 * (double)packed / (double)MAX(totalBytes, 1ULL));
            ok = [zip addEntry:name mode:st.st_mode mtime:st.st_mtime size:(uint64_t)fs.st_size crc:crc body:^BOOL{
                uint64_t written = 0;
                BOOL copied = ad_copy_into(zip.fd, from, &written) && written == (uint64_t)fs.st_size;
                zip.offset += written;
                packed += written;
                return copied;
            }];
        }
    }
    if (ok) ok = [zip finish];
    if (fsync(fd) != 0) ok = NO;
    close(fd);
    [fm removeItemAtPath:work error:nil];
    if (!ok) {
        [fm removeItemAtPath:partial error:nil];
        if (errorOut) *errorOut = errorText ?: @"Writing the IPA failed (disk full?).";
        return nil;
    }
    [fm removeItemAtPath:ipa error:nil];
    if (![fm moveItemAtPath:partial toPath:ipa error:nil]) {
        if (errorOut) *errorOut = @"The finished IPA couldn't be saved.";
        return nil;
    }
    report(@"Done", 1.0);
    if (droppedBundles.count && errorOut) {   // not an error: tells the caller what was left out
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *bundle in droppedBundles)
            [names addObject:[bundle isEqualToString:@"Watch"] ? @"the Watch app" : bundle.lastPathComponent];
        *errorOut = [NSString stringWithFormat:@"Left out (couldn't be decrypted): %@", [names componentsJoinedByString:@", "]];
    }
    log_user("[DECRYPT] %s: %lu binar%s decrypted -> %s\n", [app[@"name"] UTF8String],
             (unsigned long)replaced.count, replaced.count == 1 ? "y" : "ies", ipa.lastPathComponent.UTF8String);
    return ipa;
}
