//
//  font_overwrite.m
//  Cyanide
//
//  See font_overwrite.h. The write test (a byte flipped and restored on a
//  CoreAddition font) passed on A18: a page written through the second
//  mapping is what every new reader of the file gets.
//

#import "font_overwrite.h"
#import "font_patcher.h"
#import "remote_objc.h"
#import <signal.h>
#import "../LogTextView.h"
#import "../TaskRop/RemoteCall.h"
#import "../TaskRop/VM.h"
#import "../kexploit/kutils.h"
#import "../kexploit/kexploit_opa334.h"
#import "../utils/process.h"
#import <fcntl.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>

#pragma mark - Targets and files

NSString *fontow_target_title(FontOWTarget target)
{
    switch (target) {
        case FontOWTargetSystem: return @"System Font";
        case FontOWTargetItalic: return @"Italic";
        case FontOWTargetMono:   return @"Monospaced";
        case FontOWTargetClock:  return @"Lock Screen Clock";
        default:                 return @"?";
    }
}

NSString *fontow_target_path(FontOWTarget target)
{
    switch (target) {
        case FontOWTargetSystem: return @"/System/Library/Fonts/Core/SFUI.ttf";
        case FontOWTargetItalic: return @"/System/Library/Fonts/Core/SFUIItalic.ttf";
        case FontOWTargetMono:   return @"/System/Library/Fonts/Core/SFUIMono.ttf";
        // Every clock style's font (".SF Soft Numeric" for the default one,
        // Rounded, Stencil, Rail, New York, ...): one collection.
        case FontOWTargetClock:  return @"/System/Library/Fonts/Core/ADTNumeric.ttc";
        default:                 return nil;
    }
}

unsigned long long fontow_target_size(FontOWTarget target)
{
    struct stat st;
    NSString *path = fontow_target_path(target);
    return path && stat(path.fileSystemRepresentation, &st) == 0 ? (unsigned long long)st.st_size : 0;
}

static NSString *fontow_dir(NSString *sub)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:sub];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *fontow_backup_path(FontOWTarget target)
{
    return [fontow_dir(@"Fonts/Originals") stringByAppendingPathComponent:fontow_target_path(target).lastPathComponent];
}

NSArray<NSString *> *fontow_imported_fonts(void)
{
    NSString *dir = fontow_dir(@"Fonts");
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        NSString *ext = name.pathExtension.lowercaseString;
        if ([@[ @"ttf", @"otf", @"ttc" ] containsObject:ext]) [out addObject:[dir stringByAppendingPathComponent:name]];
    }
    [out sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = [NSFileManager.defaultManager attributesOfItemAtPath:a error:nil].fileModificationDate;
        NSDate *db = [NSFileManager.defaultManager attributesOfItemAtPath:b error:nil].fileModificationDate;
        return [db compare:da];
    }];
    return out;
}

NSString *fontow_import(NSURL *url, NSString **errorOut)
{
    NSString *ext = url.pathExtension.lowercaseString;
    if (![@[ @"ttf", @"otf", @"ttc" ] containsObject:ext]) {
        if (errorOut) *errorOut = @"Pick a .ttf, .otf or .ttc font.";
        return nil;
    }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *dest = [fontow_dir(@"Fonts") stringByAppendingPathComponent:url.lastPathComponent];
    [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
    NSError *err = nil;
    BOOL ok = [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:&err];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!ok && errorOut) *errorOut = err.localizedDescription ?: @"The font couldn't be copied.";
    return ok ? dest : nil;
}

#pragma mark - Replaced since boot

static long long fontow_boot_epoch(void)
{
    struct timeval bt = {0};
    size_t len = sizeof(bt);
    return sysctlbyname("kern.boottime", &bt, &len, NULL, 0) == 0 ? (long long)bt.tv_sec : 0;
}

static NSString *fontow_marker_key(FontOWTarget target)
{
    return [@"FontOverwriteReplacedBoot_" stringByAppendingString:fontow_target_path(target).lastPathComponent];
}

bool fontow_is_replaced(FontOWTarget target)
{
    long long boot = fontow_boot_epoch();
    return boot && [NSUserDefaults.standardUserDefaults integerForKey:fontow_marker_key(target)] == boot;
}

static void fontow_set_replaced(FontOWTarget target, bool replaced)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (replaced) [d setInteger:(NSInteger)fontow_boot_epoch() forKey:fontow_marker_key(target)];
    else [d removeObjectForKey:fontow_marker_key(target)];
}

#pragma mark - Writing into the file cache

static uint64_t fontow_own_vm_map(void)
{
    char comm[64] = {0};
    uint64_t kproc = 0;
    if (procmgr_identity_for_pid(getpid(), comm, sizeof(comm), &kproc) != 0 || !kproc) return 0;
    uint64_t task = proc_task(kproc);
    return task ? task_get_vm_map(task) : 0;
}

static bool fontow_entry_for(uint64_t map, uint64_t address, struct VMEntryInfo *out)
{
    __block bool found = false;
    vm_map_iterate_entries(map, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (address < start || address >= end) return;
        found = vm_map_entry_info(entry, out);
        *stop = YES;
    });
    return found;
}

// Replaces the contents of `path` in the file cache with `data` (zero-filled
// to the file's size). The file is mapped read-only (which also faults its
// pages in) and its VM object mapped a second time, writable, chunk by chunk.
// *stoppedAt: on a failure, the offset of the first byte not written.
static bool fontow_write_file_cache(NSString *path, NSData *data, NSString **why, size_t *stoppedAt)
{
    size_t stoppedDummy = 0;
    if (!stoppedAt) stoppedAt = &stoppedDummy;
    *stoppedAt = 0;
    const char *cpath = path.fileSystemRepresentation;
    int fd = open(cpath, O_RDONLY | O_CLOEXEC);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0 || st.st_size < 1) {
        if (fd >= 0) close(fd);
        *why = [NSString stringWithFormat:@"%@ can't be read.", path.lastPathComponent];
        return false;
    }
    size_t size = (size_t)st.st_size;
    if (data.length > size) {
        close(fd);
        *why = [NSString stringWithFormat:@"The font is %@, larger than the system's %@: it has to fit.",
                [NSByteCountFormatter stringFromByteCount:(long long)data.length countStyle:NSByteCountFormatterCountStyleFile],
                [NSByteCountFormatter stringFromByteCount:(long long)size countStyle:NSByteCountFormatterCountStyleFile]];
        return false;
    }
    uint8_t *map = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) { *why = @"The system font couldn't be mapped."; return false; }
    size_t page = (size_t)getpagesize();
    volatile uint8_t sink = 0;
    for (size_t off = 0; off < size; off += page) sink ^= map[off];   // fault every page in
    (void)sink;

    uint64_t vmMap = fontow_own_vm_map();
    struct VMEntryInfo e;
    bool ok = vmMap && fontow_entry_for(vmMap, (uint64_t)(uintptr_t)map, &e) && e.object &&
              e.end - e.start >= ((size + page - 1) & ~(page - 1));
    if (!ok) *why = @"The font file's object wasn't found in Cyanide's memory map.";
    else printf("[FONTOW] %s: %zu bytes, entry 0x%llx-0x%llx object=0x%llx offset=0x%llx\n",
                cpath, size, e.start, e.end, e.object, e.offset);
    const uint8_t *src = data.bytes;
    const size_t chunk = 1u << 20;
    for (size_t off = 0; ok && off < size; off += chunk) {
        size_t len = MIN(chunk, ((size - off) + page - 1) & ~(page - 1));
        uint64_t addr = (uint64_t)(uintptr_t)(map + off);
        size_t valid = MIN(len, size - off);                       // bytes of the file in this chunk
        size_t fromData = off < data.length ? MIN(valid, data.length - off) : 0;
        struct VMShmem w = vm_map_file_object_range(e.object, e.offset + (addr - e.start), len);
        if (w.used) {
            uint8_t *dst = (uint8_t *)(uintptr_t)w.localAddress;
            if (fromData) memcpy(dst, src + off, fromData);
            if (valid > fromData) memset(dst + fromData, 0, valid - fromData);
            vm_shmem_release(&w, len);
            continue;
        }
        // A whole chunk wouldn't map (the object can report a smaller size
        // than the file): page by page, as the write test did.
        printf("[FONTOW] chunk at 0x%zx (0x%zx bytes) didn't map; page by page\n", off, len);
        for (size_t p = 0; p < valid; p += page) {
            struct VMShmem pw = vm_map_file_object_range(e.object, e.offset + (addr - e.start) + p, page);
            if (!pw.used) {
                printf("[FONTOW] page at 0x%zx didn't map either\n", off + p);
                *stoppedAt = off + p;
                *why = @"A page of the font couldn't be mapped writable.";
                ok = false;
                break;
            }
            uint8_t *dst = (uint8_t *)(uintptr_t)pw.localAddress;
            size_t n = MIN(page, valid - p);
            size_t fromHere = p < fromData ? MIN(n, fromData - p) : 0;
            if (fromHere) memcpy(dst, src + off + p, fromHere);
            if (n > fromHere) memset(dst + fromHere, 0, n - fromHere);
            vm_shmem_release(&pw, page);
        }
    }
    munmap(map, size);
    if (!ok) return false;

    // What a new reader of the file gets now: the start and the last bytes.
    fd = open(cpath, O_RDONLY | O_CLOEXEC);
    uint8_t head[256] = {0}, tail = 0xAA;
    size_t headLen = MIN(sizeof(head), size);
    bool readOK = fd >= 0 && pread(fd, head, headLen, 0) == (ssize_t)headLen && pread(fd, &tail, 1, (off_t)size - 1) == 1;
    if (fd >= 0) close(fd);
    uint8_t expectTail = size <= data.length ? src[size - 1] : 0;
    bool headOK = readOK && memcmp(head, src, MIN(headLen, data.length)) == 0;
    printf("[FONTOW] %s: wrote %zu of %zu bytes, read back head=%d tail=%d\n", cpath, data.length, size, headOK,
           readOK && tail == expectTail);
    if (!headOK || tail != expectTail) {
        *why = @"The font was written, but a new reader doesn't see it. Restart the device to be safe.";
        return false;
    }
    return true;
}

#pragma mark - Processes holding the old font

// The Lock Screen isn't SpringBoard: PosterBoard draws the clock, chronod
// manages the widgets and each widget is drawn by its own extension process
// (e.g. the clock widget's). A respring leaves them all running with the font
// they already loaded. Ended from inside SpringBoard (Cyanide may not signal
// them; it runs in a SpringBoard session here), launchd and chronod start them
// again and they load the font as it is now.
static void fontow_restart_font_users(void)
{
    static procmgr_entry_t entries[2048];
    int n = procmgr_list(entries, 2048);
    for (int i = 0; i < n; i++) {
        bool lockScreen = strcmp(entries[i].name, "PosterBoard") == 0 || strcmp(entries[i].name, "chronod") == 0 ||
                          strstr(entries[i].name, "Widget") != NULL;
        if (!lockScreen) continue;
        uint64_t rc = r_dlsym_call(R_TIMEOUT, "kill", (uint64_t)entries[i].pid, SIGKILL, 0, 0, 0, 0, 0, 0);
        printf("[FONTOW] restarted %s (pid %d): %s\n", entries[i].name, entries[i].pid,
               r_last_call_ok() && rc == 0 ? "ok" : "not allowed or failed");
    }
}

#pragma mark - Apply and restore

// Apple's system fonts: the SF families (".SF UI", "SF Pro", ...) and the
// clock's (".SF Numeric", ".ADT Slab Numeric", ".New York Numeric") -- and
// not adapted by Cyanide, which keeps a collection's names.
static bool fontow_is_apple_font(NSData *font, NSString *family)
{
    NSString *f = [family stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@". "]];
    bool apple = [f hasPrefix:@"SF"] || [f hasPrefix:@"San Francisco"] || [f hasPrefix:@"ADT"] || [f hasPrefix:@"New York"];
    return apple && !fontpatch_is_adapted(font);
}

bool fontow_apply(FontOWTarget target, NSString *fontPath, NSString **result)
{
    __autoreleasing NSString *dummy = nil;
    if (!result) result = &dummy;
    if (!kexploit_krw_ready()) { *result = @"Kernel access isn't active."; return false; }
    NSString *path = fontow_target_path(target);
    NSData *font = [NSData dataWithContentsOfFile:fontPath options:NSDataReadingMappedIfSafe error:nil];
    if (!path || !font.length) { *result = @"The font couldn't be read."; return false; }

    // Back the original up while it still is the original -- and only if it
    // looks like Apple's: a replaced font must never become
    // the "original" Restore writes back.
    NSString *backup = fontow_backup_path(target);
    if (!fontow_is_replaced(target)) {
        NSData *current = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        NSString *family = fontpatch_family_name(current);
        printf("[FONTOW] %s is now '%s'\n", path.UTF8String, (family ?: @"?").UTF8String);
        if (!fontow_is_apple_font(current, family)) {
            *result = [NSString stringWithFormat:@"%@ is '%@'%@ right now, not Apple's font, so it isn't backed up as the original. Restart the device, then try again.",
                       path.lastPathComponent, family ?: @"unknown", fontpatch_is_adapted(current) ? @" from Cyanide" : @""];
            log_user("[FONTOW] %s\n", (*result).UTF8String);
            return false;
        }
        [NSFileManager.defaultManager removeItemAtPath:backup error:nil];
        NSError *err = nil;
        if (![NSFileManager.defaultManager copyItemAtPath:path toPath:backup error:&err]) {
            *result = [NSString stringWithFormat:@"The original couldn't be backed up (%@); nothing was changed.",
                       err.localizedDescription];
            return false;
        }
    } else if (![NSFileManager.defaultManager fileExistsAtPath:backup]) {
        *result = @"The original's backup is missing; restart the device before replacing it again.";
        return false;
    }

    // A plain font in place of a variable system font: iOS wouldn't find the
    // weights it asks for and fall back to another font; in place of a
    // collection, it wouldn't find the other faces. Adapt it first,
    // against the original (the file itself may hold a replaced font now).
    NSString *note = nil;
    NSData *originalForPatch = [NSData dataWithContentsOfFile:backup options:NSDataReadingMappedIfSafe error:nil];
    NSString *sourceError = nil;
    if (originalForPatch && !fontpatch_source_usable(originalForPatch, font, &sourceError)) {
        *result = [NSString stringWithFormat:@"%@ can't be used as the %@: %@", fontPath.lastPathComponent,
                   fontow_target_title(target).lowercaseString, sourceError];
        log_user("[FONTOW] %s\n", (*result).UTF8String);
        return false;
    }
    if (originalForPatch && fontpatch_needed(originalForPatch, font)) {
        NSString *patchError = nil;
        NSData *adapted = fontpatch_adapt(originalForPatch, font, &patchError, &note);
        if (!adapted) {
            *result = [NSString stringWithFormat:@"%@ can't be used as the %@: %@", fontPath.lastPathComponent,
                       fontow_target_title(target).lowercaseString, patchError];
            log_user("[FONTOW] %s\n", (*result).UTF8String);
            return false;
        }
        font = adapted;
    }

    NSString *why = nil;
    size_t stopped = 0;
    bool ok = fontow_write_file_cache(path, font, &why, &stopped);
    if (ok) {
        fontow_set_replaced(target, true);
        fontow_restart_font_users();
    } else if (!fontow_is_replaced(target)) {
        // A failure part-way leaves the new font in the pages before it: put
        // the original back. The failed page and everything after it were
        // never touched, so stopping at the same page again still means the
        // whole file is the original.
        NSData *original = [NSData dataWithContentsOfFile:backup options:NSDataReadingMappedIfSafe error:nil];
        NSString *ignored = nil;
        size_t undoStopped = 0;
        bool undone = stopped == 0 ||   // nothing was written
                      (original.length && (fontow_write_file_cache(path, original, &ignored, &undoStopped) ||
                                           (undoStopped && undoStopped >= stopped)));
        printf("[FONTOW] after the failure, original written back: %s\n", undone ? "yes" : "partly");
        why = [why stringByAppendingString:undone ? @" Nothing was changed."
                                                  : @" Restart the device before respringing, to be safe."];
    }
    *result = ok ? [NSString stringWithFormat:@"%@ replaced with %@%@. Respring to see it; restart or Restore to undo.",
                    fontow_target_title(target), fontPath.lastPathComponent,
                    note ? [NSString stringWithFormat:@" (%@)", note] : @""]
                 : why;
    log_user("[FONTOW] %s\n", (*result).UTF8String);
    return ok;
}

bool fontow_restore(FontOWTarget target, NSString **result)
{
    __autoreleasing NSString *dummy = nil;
    if (!result) result = &dummy;
    if (!fontow_is_replaced(target)) { *result = @"It's the original already."; return true; }
    if (!kexploit_krw_ready()) { *result = @"Kernel access isn't active."; return false; }
    NSData *original = [NSData dataWithContentsOfFile:fontow_backup_path(target) options:NSDataReadingMappedIfSafe error:nil];
    NSString *backupFamily = fontpatch_family_name(original);
    NSString *currentFamily = fontpatch_family_name([NSData dataWithContentsOfFile:fontow_target_path(target)
                                                                          options:NSDataReadingMappedIfSafe error:nil]);
    printf("[FONTOW] restore %s: file is '%s', backup is '%s'\n", fontow_target_path(target).UTF8String,
           (currentFamily ?: @"?").UTF8String, (backupFamily ?: @"?").UTF8String);
    if (!fontow_is_apple_font(original, backupFamily)) {
        *result = [NSString stringWithFormat:@"The backup isn't Apple's font ('%@'). Restart the device: that always brings the original back.",
                   backupFamily ?: @"unknown"];
        return false;
    }
    if (original.length != fontow_target_size(target)) {
        *result = @"The backup doesn't match the system's font; restart the device to restore it.";
        return false;
    }
    NSString *why = nil;
    bool ok = fontow_write_file_cache(fontow_target_path(target), original, &why, NULL);
    if (ok) {
        fontow_set_replaced(target, false);
        fontow_restart_font_users();
    }
    *result = ok ? [NSString stringWithFormat:@"%@ restored. Respring to see it.", fontow_target_title(target)] : why;
    log_user("[FONTOW] %s\n", (*result).UTF8String);
    return ok;
}
