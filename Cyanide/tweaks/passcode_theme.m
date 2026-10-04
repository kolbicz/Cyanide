//
//  passcode_theme.m
//  Cyanide
//  Adapted from Lara's Passcode implementation (ruter) via Eagle
//  (https://github.com/leonardob8777-bit/Eagle, AGPL-3.0).
//
//  Lock Screen passcode keypad art (TelephonyUI digit PNGs) replacement.
//
//  Write-safety contract (inherited from that implementation):
//  - the first original digit is backed up before anything is written;
//  - every write is read back and compared with the intended bytes;
//  - a write that cannot be verified rolls back to the previous art;
//  - original backups survive every failure, and Restore writes them back.
//

#import "passcode_theme.h"

#import "../LogTextView.h"
#import "../kexploit/kexploit_opa334.h"
#import "../kexploit/persistence.h"
#import "../kexploit/vnode.h"
#import "../utils/sandbox.h"

#import <errno.h>
#import <fcntl.h>
#import <ImageIO/ImageIO.h>
#import <pthread.h>
#import <string.h>
#import <sys/stat.h>
#import <zlib.h>
#import <unistd.h>

static NSString * const kPTBackupDirName = @"PasscodeThemeBackups";
static NSString * const kPTLibraryDirName = @"PasscodeThemes";

// Read cap for keypad art data.
static const NSUInteger kPTMaxDigitBytes = 8 * 1024 * 1024;

// Keypad art height picked photos are rescaled to before applying.
static const CGFloat kPTKeypadArtHeight = 202.0;

static NSString *g_pt_last_summary = nil;

// Originals written by the current apply/restore run, so the summary can report
// how many were saved. Runs are serialised by the caller's actions lock.
static NSUInteger g_pt_backups_written = 0;

#pragma mark - Query cache

// The Settings panel rebuilds its rows on every table query (numberOfRows,
// cellForRow, every didSelect branch), and those rows are derived from the
// filesystem: the keypad cache is enumerated once per version candidate, every
// digit file is stat'd, and the preview cell loads up to twenty PNGs. Without a
// cache that work repeats per row, per scroll and per tap.
//
// Every slot is dropped explicitly after any write this module makes (apply,
// restore, import, digit save, style selection), and the slots that depend on
// files another app can rewrite (the keypad cache) additionally age out after
// kPTCacheTTL so leaving and re-entering the panel picks up a cache another app
// or the system rewrote.
//
// Locking: the mutex only guards the slots themselves. Slow work (directory
// enumeration, file reads) always runs with the lock released, so two threads
// missing the same slot simply compute the same value twice.
#define kPTCacheTTL 3.0

static pthread_mutex_t g_pt_cache_lock = PTHREAD_MUTEX_INITIALIZER;

static NSString                    *g_pt_base_path        = nil;
static double                       g_pt_base_path_at     = 0.0;
static NSDictionary                *g_pt_targets          = nil;
static NSString                    *g_pt_targets_key      = nil;
static double                       g_pt_targets_at       = 0.0;
static PTPasscodeStyleState         g_pt_style_state      = PTPasscodeStyleStateUnknown;
static BOOL                         g_pt_style_state_ok   = NO;
static double                       g_pt_style_state_at   = 0.0;
static NSDictionary                *g_pt_current_images   = nil;
static BOOL                         g_pt_current_images_ok = NO;
static double                       g_pt_current_images_at = 0.0;
static NSSet                       *g_pt_presence         = nil;
static NSString                    *g_pt_presence_key     = nil;
static NSDictionary                *g_pt_theme_images     = nil;
static NSString                    *g_pt_theme_images_key = nil;
static NSUInteger                   g_pt_backup_files     = 0;
static NSUInteger                   g_pt_backup_digits    = 0;
static BOOL                         g_pt_backup_counts_ok = NO;

static double pt_cache_now(void)
{
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1000000000.0;
}

// Caller must hold g_pt_cache_lock.
static void pt_cache_clear_locked(void)
{
    g_pt_base_path         = nil;
    g_pt_base_path_at      = 0.0;
    g_pt_targets           = nil;
    g_pt_targets_key       = nil;
    g_pt_targets_at        = 0.0;
    g_pt_style_state_ok    = NO;
    g_pt_style_state_at    = 0.0;
    g_pt_current_images    = nil;
    g_pt_current_images_ok = NO;
    g_pt_current_images_at = 0.0;
    g_pt_presence          = nil;
    g_pt_presence_key      = nil;
    g_pt_theme_images      = nil;
    g_pt_theme_images_key  = nil;
    g_pt_backup_counts_ok  = NO;
}

// Drop everything cached about the keypad cache, the theme library and the
// backups. Called by this module after any write it makes.
static void settings_passcode_invalidate_caches(void)
{
    pthread_mutex_lock(&g_pt_cache_lock);
    pt_cache_clear_locked();
    pthread_mutex_unlock(&g_pt_cache_lock);
}

// The apply/restore worker runs on a background queue while the panel reads the
// summary on the main thread, so both sides go through the cache lock: a strong
// pointer must never be read while it is being replaced. Callers must not hold
// g_pt_cache_lock when calling this: it is not recursive.
static void pt_set_summary(NSString *summary)
{
    pthread_mutex_lock(&g_pt_cache_lock);
    g_pt_last_summary = [summary copy];
    pthread_mutex_unlock(&g_pt_cache_lock);
}

NSString *settings_passcode_last_result_summary(void)
{
    pthread_mutex_lock(&g_pt_cache_lock);
    NSString *summary = g_pt_last_summary;
    pthread_mutex_unlock(&g_pt_cache_lock);
    return summary;
}

#pragma mark - Paths

static NSString *pt_application_support_dir(void)
{
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    return dirs.firstObject ?: NSHomeDirectory();
}

static NSString *pt_backup_dir(void)
{
    return [pt_application_support_dir() stringByAppendingPathComponent:kPTBackupDirName];
}

// Backups are keyed by the full target path, sanitised the same way keypad
// paths are, so a stored file name still shows which keypad file it came from.
static NSString *pt_backup_path(NSString *targetPath)
{
    NSString *sanitized = [targetPath stringByReplacingOccurrencesOfString:@"/"
                                                                withString:@"_"];
    return [pt_backup_dir() stringByAppendingPathComponent:
            [sanitized stringByAppendingString:@".orig"]];
}

// Lives under Application Support: this is Cyanide's own storage, and Documents
// stays reserved for files the user is meant to see in Files.app.
static NSString *pt_library_dir(void)
{
    NSString *root = pt_application_support_dir();
    return root.length > 0 ? [root stringByAppendingPathComponent:kPTLibraryDirName] : nil;
}

#pragma mark - Keypad digit naming

static NSString *settings_passcode_digit_for_filename(NSString *name)
{
    if (name.length == 0) return nil;

    NSString *normalized = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSString *last = normalized.lastPathComponent.lowercaseString;
    if (last.length == 0) return nil;

    NSString *stem = last.stringByDeletingPathExtension;
    if (stem.length == 1) {
        unichar c = [stem characterAtIndex:0];
        if (c >= '0' && c <= '9') return stem;
    }

    // TelephonyUI's "2" in this format is a marker, not the displayed digit.
    // Resolve that prefix before the generic numeric separators below.
    for (NSInteger value = 0; value <= 9; value++) {
        NSString *marker = [NSString stringWithFormat:@"other-2-%ld--dark", (long)value];
        if ([last containsString:marker]) {
            return [NSString stringWithFormat:@"%ld", (long)value];
        }
    }

    for (NSInteger value = 0; value <= 9; value++) {
        NSString *digit = [NSString stringWithFormat:@"%ld", (long)value];
        NSArray<NSString *> *patterns = @[
            [NSString stringWithFormat:@"-%@-", digit],
            [NSString stringWithFormat:@"-%@@", digit],
            [NSString stringWithFormat:@"_%@_", digit],
            [NSString stringWithFormat:@"_%@@", digit],
        ];
        for (NSString *pattern in patterns) {
            if ([last containsString:pattern]) return digit;
        }
    }

    return nil;
}

static BOOL pt_is_digit_key(NSString *digit)
{
    if (digit.length != 1) return NO;
    unichar c = [digit characterAtIndex:0];
    return (c >= '0' && c <= '9');
}

#pragma mark - File I/O

static bool pt_write_all(int fd, const uint8_t *bytes, NSUInteger length)
{
    NSUInteger total = 0;
    while (total < length) {
        ssize_t written = write(fd, bytes + total, length - total);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            printf("[PASSCODE] write failed at %lu/%lu errno=%d\n",
                   (unsigned long)total, (unsigned long)length, errno);
            return false;
        }
        total += (NSUInteger)written;
    }
    return true;
}

static NSData *pt_read_file(NSString *path)
{
    if (path.length == 0) return nil;

    struct stat st = {0};
    if (stat(path.UTF8String, &st) != 0) return nil;
    if (!S_ISREG(st.st_mode) || st.st_size <= 0) return nil;
    if ((unsigned long long)st.st_size > (unsigned long long)kPTMaxDigitBytes) {
        printf("[PASSCODE] refusing oversized file (%lld bytes): %s\n",
               (long long)st.st_size, path.UTF8String);
        return nil;
    }

    int fd = open(path.UTF8String, O_RDONLY);
    if (fd < 0) return nil;

    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    uint8_t *bytes = out.mutableBytes;
    NSUInteger total = 0;
    while (total < (NSUInteger)st.st_size) {
        ssize_t got = read(fd, bytes + total, (NSUInteger)st.st_size - total);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        total += (NSUInteger)got;
    }
    close(fd);

    if (total == 0) return nil;
    // A short read means the file changed underneath us — the system rebuilds
    // the keypad cache in place. A truncated buffer must not count as readable:
    // callers would otherwise save a partial file as an "original" backup or use
    // it as a rollback target.
    if (total != (NSUInteger)st.st_size) return nil;
    out.length = total;
    return out;
}

// Writes `data` over `targetPath` through a temp file that carries the target's
// ownership and permissions before the rename.
//
// Performance notes, because a keypad cache holds dozens of files and the
// kernel chown/chmod calls each run six global sync() operations internally:
//  - a folder's mode is widened once per run (recorded in `lockedDirs`) instead
//    of once per file;
//  - chown/chmod on the temp file are skipped when it already matches the
//    target's identity, which is the normal case for /var/mobile caches;
//  - no fsync: these are regenerable cache files and every write is read back
//    and compared before it counts as applied.
static bool pt_write_data_to_target(NSData *data,
                                    NSString *targetPath,
                                    NSMutableDictionary<NSString *, NSNumber *> *lockedDirs)
{
    if (data.length == 0 || targetPath.length == 0) return false;

    NSString *dir = targetPath.stringByDeletingLastPathComponent;
    if (dir.length == 0) return false;

    struct stat dirStat = {0};
    if (stat(dir.UTF8String, &dirStat) != 0 || !S_ISDIR(dirStat.st_mode)) {
        log_user("[PASSCODE] Keypad folder is unavailable: %s (errno=%d).\n",
                 dir.UTF8String, errno);
        return false;
    }

    if (!lockedDirs[dir]) {
        mode_t writableDirMode = dirStat.st_mode | S_IWUSR | S_IXUSR;
        if ((writableDirMode & 07777) != (dirStat.st_mode & 07777)) {
            // Record the original mode BEFORE the kernel call. vnode_apfs_chmod
            // sets the mode and then verifies it, so it can apply the change and
            // still report failure — which would leave the folder widened with
            // nothing recorded to restore.
            lockedDirs[dir] = @(dirStat.st_mode);
            if (vnode_apfs_chmod(dir.UTF8String, writableDirMode) != 0) {
                log_user("[PASSCODE] Could not unlock the keypad folder for writing: %s.\n",
                         dir.UTF8String);
                return false;
            }
        }
    }

    struct stat fileStat = {0};
    bool existed = (stat(targetPath.UTF8String, &fileStat) == 0);
    mode_t finalMode = existed ? (fileStat.st_mode & 07777) : 0644;
    uid_t finalUid = existed ? fileStat.st_uid : dirStat.st_uid;
    gid_t finalGid = existed ? fileStat.st_gid : dirStat.st_gid;

    NSString *tmpName = [NSString stringWithFormat:@".%@.cyanide.tmp",
                         targetPath.lastPathComponent];
    NSString *tmpPath = [dir stringByAppendingPathComponent:tmpName];

    bool ok = false;
    int fd = -1;
    do {
        unlink(tmpPath.UTF8String);
        fd = open(tmpPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) {
            log_user("[PASSCODE] Could not create a temp file in %s (errno=%d).\n",
                     dir.UTF8String, errno);
            break;
        }

        if (!pt_write_all(fd, data.bytes, data.length)) break;

        struct stat tmpStat = {0};
        bool identityMatches = (fstat(fd, &tmpStat) == 0) &&
                               tmpStat.st_uid == finalUid &&
                               tmpStat.st_gid == finalGid &&
                               ((tmpStat.st_mode & 07777) == finalMode);

        if (close(fd) != 0) {
            printf("[PASSCODE] close temp failed errno=%d\n", errno);
            fd = -1;
            break;
        }
        fd = -1;

        if (!identityMatches) {
            if (vnode_apfs_chown(tmpPath.UTF8String, finalUid, finalGid) != 0) break;
            if (vnode_apfs_chmod(tmpPath.UTF8String, S_IFREG | finalMode) != 0) break;
        }

        if (rename(tmpPath.UTF8String, targetPath.UTF8String) != 0) {
            log_user("[PASSCODE] Could not move the new art into place for %s (errno=%d).\n",
                     targetPath.lastPathComponent.UTF8String, errno);
            break;
        }

        // No per-file success line: this module's printf is mirrored into the
        // in-app log by LogTextView.h, so one line per keypad file (40+ of them)
        // would bury the run summary.
        ok = true;
    } while (0);

    if (fd >= 0) close(fd);
    if (!ok) unlink(tmpPath.UTF8String);
    return ok;
}

// Puts back the folder modes a run widened, once, after all its writes.
static void pt_restore_directory_modes(NSMutableDictionary<NSString *, NSNumber *> *lockedDirs)
{
    for (NSString *dir in lockedDirs) {
        mode_t original = (mode_t)lockedDirs[dir].unsignedIntValue;
        if (vnode_apfs_chmod(dir.UTF8String, original) != 0) {
            printf("[PASSCODE] could not restore folder mode for %s\n", dir.UTF8String);
        }
    }
    [lockedDirs removeAllObjects];
}

#pragma mark - Originals discarded flag

static NSString * const kPTOriginalsDiscardedKey = @"PasscodeOriginalsDiscarded";

// Once the saved originals are gone, nothing on this device can prove the
// keypad art is stock. Persisted so the warning survives a relaunch, and cleared
// only by importing a backup set, which the user is vouching for.
static BOOL pt_originals_discarded(void)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:kPTOriginalsDiscardedKey];
}

static void pt_set_originals_discarded(BOOL discarded)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (discarded) {
        [defaults setBool:YES forKey:kPTOriginalsDiscardedKey];
    } else {
        [defaults removeObjectForKey:kPTOriginalsDiscardedKey];
    }
    [defaults synchronize];
}

#pragma mark - Sandbox

// The keypad art lives under /var/mobile/Library/Caches, so the same
// /private/var read/write unlock the other file-editing tweaks use is enough.
static bool pt_prepare_sandbox(void)
{
    if (check_sandbox_var_rw() == 0) {
        printf("[PASSCODE] app sandbox already allows /private/var read/write\n");
        return true;
    }

    if (krw_persistence_consume_launchd_root_file_token() &&
        check_sandbox_var_rw() == 0) {
        printf("[PASSCODE] sandbox ok via launchd root file token\n");
        return true;
    }

    if (patch_sandbox_ext() == 0 && check_sandbox_var_rw() == 0) {
        printf("[PASSCODE] sandbox ok via patch_sandbox_ext\n");
        return true;
    }

    static const char *donors[] = {
        "cfprefsd",
        "SpringBoard",
        "backboardd",
        "mobilephone",
        "sysdiagnosed",
        "softwareupdateservicesd",
        "mobile_installation_proxy",
        "installd",
        NULL,
    };

    for (int i = 0; donors[i]; i++) {
        if (borrow_sandbox_ext(donors[i]) == 0 && check_sandbox_var_rw() == 0) {
            printf("[PASSCODE] sandbox ok via borrow_sandbox_ext(%s)\n", donors[i]);
            return true;
        }
    }

    printf("[PASSCODE] could not unlock /private/var rw access\n");
    log_user("[PASSCODE] Failed: /private/var read/write sandbox access is still denied.\n");
    return false;
}

#pragma mark - Keypad targets

// Newest cache first, matching the upstream implementation's version order: the
// keypad cache keeps the digits for the current iOS version only.
static NSArray<NSString *> *pt_telephony_cache_candidates(void)
{
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSInteger version = 15; version >= 8; version--) {
        [out addObject:[NSString stringWithFormat:
                        @"/var/mobile/Library/Caches/TelephonyUI-%ld", (long)version]];
    }
    return out;
}

// Raw directory scan. Callers go through settings_passcode_targets_by_digit,
// which caches the result; the base-path probe below deliberately uses the
// uncached scan, so a stale cache can never decide which cache folder wins.
static NSDictionary<NSString *, NSArray<NSString *> *> *pt_scan_targets(NSString *basePath)
{
    if (basePath.length == 0) return @{};

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *byDigit =
        [NSMutableDictionary dictionary];

    // Top level only: the keypad art sits directly in the cache folder, and
    // walking subfolders would let a file that merely looks like art become a
    // write target.
    for (NSString *relative in [fm contentsOfDirectoryAtPath:basePath error:nil]) {
        if (![relative.lowercaseString hasSuffix:@".png"]) continue;
        NSString *digit = settings_passcode_digit_for_filename(relative);
        if (digit.length == 0) continue;

        NSMutableArray<NSString *> *paths = byDigit[digit];
        if (!paths) {
            paths = [NSMutableArray array];
            byDigit[digit] = paths;
        }
        [paths addObject:[basePath stringByAppendingPathComponent:relative]];
    }

    NSMutableDictionary<NSString *, NSArray<NSString *> *> *out = [NSMutableDictionary dictionary];
    for (NSString *digit in byDigit) {
        out[digit] = [byDigit[digit] sortedArrayUsingSelector:@selector(compare:)];
    }
    return out;
}

NSString *settings_passcode_telephony_base_path(void)
{
    double now = pt_cache_now();
    pthread_mutex_lock(&g_pt_cache_lock);
    NSString *cached = g_pt_base_path;
    BOOL cacheFresh = cached && (now - g_pt_base_path_at) < kPTCacheTTL;
    pthread_mutex_unlock(&g_pt_cache_lock);
    if (cacheFresh) return cached;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *firstExisting = nil;

    for (NSString *path in pt_telephony_cache_candidates()) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) continue;

        // Prefer a cache that actually holds recognisable keypad digits: a bare
        // folder can exist before its art has been generated. Falls back to the
        // first existing folder when nothing is readable yet (sandbox closed).
        if (pt_scan_targets(path).count > 0) { firstExisting = path; break; }
        if (!firstExisting) firstExisting = path;
    }

    pthread_mutex_lock(&g_pt_cache_lock);
    g_pt_base_path    = firstExisting;
    g_pt_base_path_at = pt_cache_now();
    pthread_mutex_unlock(&g_pt_cache_lock);
    return firstExisting;
}

NSDictionary<NSString *, NSArray<NSString *> *> *settings_passcode_targets_by_digit(NSString *basePath)
{
    if (basePath.length == 0) return @{};

    double now = pt_cache_now();
    pthread_mutex_lock(&g_pt_cache_lock);
    if (g_pt_targets && [g_pt_targets_key isEqualToString:basePath] &&
        (now - g_pt_targets_at) < kPTCacheTTL) {
        NSDictionary *cached = g_pt_targets;
        pthread_mutex_unlock(&g_pt_cache_lock);
        return cached;
    }
    pthread_mutex_unlock(&g_pt_cache_lock);

    NSDictionary *scanned = pt_scan_targets(basePath);

    pthread_mutex_lock(&g_pt_cache_lock);
    g_pt_targets     = scanned;
    g_pt_targets_key = [basePath copy];
    g_pt_targets_at  = pt_cache_now();
    pthread_mutex_unlock(&g_pt_cache_lock);
    return scanned;
}

static NSDictionary<NSString *, NSData *> *pt_compute_current_images(void)
{
    NSString *basePath = settings_passcode_telephony_base_path();
    if (basePath.length == 0) return @{};

    NSDictionary<NSString *, NSArray<NSString *> *> *targets =
        settings_passcode_targets_by_digit(basePath);
    NSMutableDictionary<NSString *, NSData *> *out = [NSMutableDictionary dictionary];

    for (NSString *digit in targets) {
        // One variant per digit is enough to show what the keypad looks like;
        // the variants of a digit carry the same art.
        for (NSString *path in targets[digit]) {
            NSData *data = pt_read_file(path);
            if (data.length > 0) {
                out[digit] = data;
                break;
            }
        }
    }

    return out;
}

// Cached: the preview cell asks for this every time it is built, and a keypad
// cache holds up to ten PNGs. Ages out with kPTCacheTTL so a cache rewritten by
// another app shows up without leaving the panel.
NSDictionary<NSString *, NSData *> *settings_passcode_current_digit_images(void)
{
    double now = pt_cache_now();
    pthread_mutex_lock(&g_pt_cache_lock);
    BOOL fresh = g_pt_current_images_ok && (now - g_pt_current_images_at) < kPTCacheTTL;
    NSDictionary *cached = g_pt_current_images;
    pthread_mutex_unlock(&g_pt_cache_lock);
    if (fresh) return cached;

    NSDictionary *computed = pt_compute_current_images();

    pthread_mutex_lock(&g_pt_cache_lock);
    g_pt_current_images    = computed;
    g_pt_current_images_ok = YES;
    g_pt_current_images_at = pt_cache_now();
    pthread_mutex_unlock(&g_pt_cache_lock);
    return computed;
}

NSUInteger settings_passcode_keypad_file_count(NSString *basePath)
{
    if (basePath.length == 0) return 0;

    NSUInteger total = 0;
    NSDictionary<NSString *, NSArray<NSString *> *> *targets =
        settings_passcode_targets_by_digit(basePath);
    for (NSString *digit in targets) {
        total += targets[digit].count;
    }
    return total;
}

#pragma mark - Backups

typedef NS_ENUM(NSInteger, PTBackupResult) {
    PTBackupResultOK = 0,          // A usable original backup exists.
    PTBackupResultNoOriginal = 1,  // The target digit file is not there.
    PTBackupResultFailed = 2,      // The backup could not be read or written.
};

// Saves `original` — the caller's copy of the target's current bytes — when no
// usable backup exists yet. The caller passes the copy it already read (the
// apply write pass, or the snapshot pass), so saving an original never costs an
// extra read of the keypad file.
static PTBackupResult pt_backup_original_data_if_needed(NSData *original, NSString *targetPath)
{
    if (original.length == 0 || targetPath.length == 0) return PTBackupResultFailed;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *backupPath = pt_backup_path(targetPath);

    if ([fm fileExistsAtPath:backupPath]) {
        // A zero-byte leftover must not be trusted forever: this check
        // short-circuits on existence, so Restore would only ever report the
        // backup as unreadable. Treat it as absent and save the original again.
        NSDictionary *backupAttrs = [fm attributesOfItemAtPath:backupPath error:nil];
        if ([backupAttrs[NSFileSize] unsignedLongLongValue] > 0) {
            return PTBackupResultOK;
        }
        printf("[PASSCODE] empty backup file for %s; saving the original again\n",
               targetPath.lastPathComponent.UTF8String);
    }

    NSString *dir = pt_backup_dir();
    NSError *error = nil;
    if (![fm createDirectoryAtPath:dir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&error]) {
        log_user("[PASSCODE] Could not create the backup folder: %s\n",
                 error.localizedDescription.UTF8String ?: "unknown");
        return PTBackupResultFailed;
    }

    if (![original writeToFile:backupPath options:NSDataWritingAtomic error:&error]) {
        log_user("[PASSCODE] Could not write the backup for %s: %s\n",
                 targetPath.lastPathComponent.UTF8String,
                 error.localizedDescription.UTF8String ?: "unknown");
        return PTBackupResultFailed;
    }

    // A backup that cannot be read back byte-for-byte is not a backup. Dropping
    // it here keeps "never write a digit whose original could not be saved"
    // honest, instead of surfacing a corrupt file at Restore time.
    NSData *written = pt_read_file(backupPath);
    if (written.length == 0 || ![written isEqualToData:original]) {
        log_user("[PASSCODE] The backup for %s did not verify and was discarded; the file is left alone.\n",
                 targetPath.lastPathComponent.UTF8String);
        [fm removeItemAtPath:backupPath error:nil];
        return PTBackupResultFailed;
    }

    chmod(backupPath.UTF8String, 0600);
    g_pt_backups_written++;
    return PTBackupResultOK;
}



static NSData *pt_backup_data(NSString *targetPath)
{
    return pt_read_file(pt_backup_path(targetPath));
}

// Both numbers come out of one pass over the backup folder: the Settings rows
// and the delete confirmation ask for them together, so enumerating the same
// directory twice was pure duplication.
typedef struct {
    NSUInteger files;
    NSUInteger digits;
} PTBackupCounts;

static PTBackupCounts pt_scan_backups(void)
{
    PTBackupCounts counts = { 0, 0 };
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:pt_backup_dir() error:nil];

    NSMutableSet<NSString *> *digits = [NSMutableSet set];
    for (NSString *name in entries) {
        if (![name hasSuffix:@".orig"]) continue;
        counts.files++;
        // A backup is named after the sanitised target path
        // ("_var_mobile_..._other-2-5--dark@3x.png.orig"), so the same matcher
        // used on real keypad files reads the digit straight out of it.
        NSString *digit = settings_passcode_digit_for_filename([name stringByDeletingPathExtension]);
        if (digit.length > 0) [digits addObject:digit];
    }
    counts.digits = digits.count;
    return counts;
}

// The scan stays cached until this module writes or rewrites backups (apply and
// restore end with settings_passcode_invalidate_caches).
static PTBackupCounts pt_backup_counts(void)
{
    pthread_mutex_lock(&g_pt_cache_lock);
    BOOL fresh = g_pt_backup_counts_ok;
    PTBackupCounts cached = { g_pt_backup_files, g_pt_backup_digits };
    pthread_mutex_unlock(&g_pt_cache_lock);
    if (fresh) return cached;

    PTBackupCounts computed = pt_scan_backups();

    pthread_mutex_lock(&g_pt_cache_lock);
    g_pt_backup_files     = computed.files;
    g_pt_backup_digits    = computed.digits;
    g_pt_backup_counts_ok = YES;
    pthread_mutex_unlock(&g_pt_cache_lock);
    return computed;
}

NSUInteger settings_passcode_theme_backup_count(void)
{
    return pt_backup_counts().files;
}

NSUInteger settings_passcode_backup_digit_count(void)
{
    return pt_backup_counts().digits;
}

#pragma mark - Backup transfer

// Restore looks a backup up by sanitising the keypad path it wants and appending
// ".orig" (pt_backup_path). A file that carries no TelephonyUI path, or no digit,
// can be stored and exported but can never be written back to the keypad.
static BOOL pt_backup_name_looks_usable(NSString *name)
{
    if (name.length == 0) return NO;
    if ([name rangeOfString:@"TelephonyUI"].location == NSNotFound) return NO;
    return settings_passcode_digit_for_filename(name).length > 0;
}

NSUInteger settings_passcode_import_backup_items(NSArray<NSURL *> *items,
                                                 NSUInteger *skippedOut,
                                                 NSUInteger *failedOut,
                                                 NSUInteger *unrecognizedOut)
{
    if (skippedOut) *skippedOut = 0;
    if (failedOut) *failedOut = 0;
    if (unrecognizedOut) *unrecognizedOut = 0;
    if (items.count == 0) return 0;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = pt_backup_dir();
    if (dir.length == 0) return 0;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    // Collect every .orig in the picked items. A folder is walked all the way
    // down, because an exported copy usually arrives inside another folder.
    NSMutableArray<NSURL *> *sources = [NSMutableArray array];
    for (NSURL *item in items) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:item.path isDirectory:&isDir]) continue;
        if (!isDir) {
            if ([item.pathExtension.lowercaseString isEqualToString:@"orig"]) {
                [sources addObject:item];
            }
            continue;
        }
        NSDirectoryEnumerator<NSURL *> *en =
            [fm enumeratorAtURL:item
     includingPropertiesForKeys:nil
                        options:NSDirectoryEnumerationSkipsHiddenFiles
                   errorHandler:nil];
        for (NSURL *found in en) {
            if ([found.pathExtension.lowercaseString isEqualToString:@"orig"]) {
                [sources addObject:found];
            }
        }
    }

    NSUInteger added = 0;
    NSUInteger kept = 0;
    NSUInteger failed = 0;
    NSUInteger unusable = 0;
    unsigned long long bytes = 0;
    for (NSURL *src in sources) {
        NSString *name = src.lastPathComponent;
        if (name.length == 0) continue;

        if (!pt_backup_name_looks_usable(name)) unusable++;

        NSString *dst = [dir stringByAppendingPathComponent:name];

        struct stat st = {0};
        if (stat(dst.UTF8String, &st) == 0 && st.st_size > 0) {
            // Never overwrite: whatever is already on this device may be the
            // only genuine original left, and an imported copy can be older.
            kept++;
            continue;
        }
        [fm removeItemAtPath:dst error:nil];   // clear a zero-byte leftover

        // Copy to a sidecar first and move it into place only after the size is
        // verified: a copy that dies halfway would otherwise leave a partial
        // file that looks "already present" next time and would then be packed
        // into every export.
        NSString *partial = [dst stringByAppendingString:@".partial"];
        [fm removeItemAtPath:partial error:nil];
        NSError *copyError = nil;
        if (![fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:partial] error:&copyError]) {
            log_user("[PASSCODE] Could not import %s: %s\n",
                     name.UTF8String,
                     copyError.localizedDescription.UTF8String ?: "unknown");
            [fm removeItemAtPath:partial error:nil];
            failed++;
            continue;
        }

        struct stat sourceStat = {0};
        struct stat partialStat = {0};
        BOOL sizeMatches = (stat(src.path.UTF8String, &sourceStat) == 0) &&
                           (stat(partial.UTF8String, &partialStat) == 0) &&
                           sourceStat.st_size > 0 &&
                           partialStat.st_size == sourceStat.st_size;
        if (!sizeMatches) {
            log_user("[PASSCODE] Import of %s did not verify; discarded.\n", name.UTF8String);
            [fm removeItemAtPath:partial error:nil];
            failed++;
            continue;
        }

        [fm removeItemAtPath:dst error:nil];
        if (![fm moveItemAtPath:partial toPath:dst error:&copyError]) {
            log_user("[PASSCODE] Could not place %s: %s\n",
                     name.UTF8String,
                     copyError.localizedDescription.UTF8String ?: "unknown");
            [fm removeItemAtPath:partial error:nil];
            failed++;
            continue;
        }

        chmod(dst.UTF8String, 0600);
        bytes += (unsigned long long)partialStat.st_size;
        added++;
    }

    if (skippedOut) *skippedOut = kept;
    if (failedOut) *failedOut = failed;
    if (unrecognizedOut) *unrecognizedOut = unusable;
    if (added > 0) {
        settings_passcode_invalidate_caches();
        // A backup set the user vouches for is present again.
        pt_set_originals_discarded(false);
    }
    log_user("[PASSCODE] Backup import: %lu added, %lu already present, %lu failed, %lu unusable for restore (%llu bytes).\n",
             (unsigned long)added, (unsigned long)kept, (unsigned long)failed,
             (unsigned long)unusable, bytes);
    return added;
}

// ---------------------------------------------------------------------------
// Minimal ZIP writer (stored entries only).
//
// The keypad originals are PNGs, which are already compressed — deflating them
// again would save nothing and drag a compressor into this file. Stored entries
// still produce a real .zip that Files.app, Finder and unzip all open, and the
// archive is what makes an export a single file instead of twenty.
// ---------------------------------------------------------------------------

static void pt_zip_put16(NSMutableData *out, uint16_t value)
{
    uint8_t bytes[2] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF) };
    [out appendBytes:bytes length:2];
}

static void pt_zip_put32(NSMutableData *out, uint32_t value)
{
    uint8_t bytes[4] = { (uint8_t)(value & 0xFF),         (uint8_t)((value >> 8) & 0xFF),
                         (uint8_t)((value >> 16) & 0xFF), (uint8_t)((value >> 24) & 0xFF) };
    [out appendBytes:bytes length:4];
}

// Every .orig in the backup store, sorted, as full paths.
static NSArray<NSString *> *pt_backup_file_paths(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = pt_backup_dir();
    if (dir.length == 0) return @[];

    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name hasSuffix:@".orig"]) continue;
        [out addObject:[dir stringByAppendingPathComponent:name]];
    }
    return [out sortedArrayUsingSelector:@selector(compare:)];
}

static NSData *pt_build_backup_zip(NSArray<NSString *> *backupPaths,
                                   NSUInteger *entryCountOut,
                                   NSUInteger *skippedOut)
{
    if (skippedOut) *skippedOut = 0;
    NSMutableData *out = [NSMutableData dataWithCapacity:(1 << 20)];
    NSMutableData *central = [NSMutableData dataWithCapacity:4096];
    NSUInteger entries = 0;
    NSUInteger skipped = 0;

    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDateComponents *parts = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth |
                                                    NSCalendarUnitDay  | NSCalendarUnitHour |
                                                    NSCalendarUnitMinute | NSCalendarUnitSecond)
                                          fromDate:[NSDate date]];
    uint16_t dosTime = (uint16_t)(((parts.hour & 0x1F) << 11) |
                                  ((parts.minute & 0x3F) << 5) |
                                  ((parts.second / 2) & 0x1F));
    uint16_t dosDate = (uint16_t)((((parts.year - 1980) & 0x7F) << 9) |
                                  ((parts.month & 0x0F) << 5) |
                                  (parts.day & 0x1F));

    for (NSString *path in backupPaths) {
        if (entries >= 0xFFFFu) {
            // The end-of-central-directory record counts entries in 16 bits and
            // 0xFFFF is the ZIP64 marker, so a bigger archive cannot be
            // described. Refuse instead of writing one that will not open.
            return nil;
        }
        NSString *name = path.lastPathComponent;
        NSData *data = pt_read_file(path);
        if (name.length == 0 || data.length == 0) { skipped++; continue; }
        if (data.length > 0xFFFFFFFFu) { skipped++; continue; }   // stored entries are 32-bit

        const char *nameBytes = name.UTF8String;
        uint32_t nameLength = nameBytes ? (uint32_t)strlen(nameBytes) : 0;
        if (nameLength == 0 || nameLength > 0xFFFFu) { skipped++; continue; }

        uint32_t size = (uint32_t)data.length;
        uint32_t crc = (uint32_t)crc32(crc32(0L, Z_NULL, 0), data.bytes, (uInt)data.length);
        uint32_t offset = (uint32_t)out.length;

        // Local file header + name + stored bytes.
        pt_zip_put32(out, 0x04034b50);
        pt_zip_put16(out, 20);
        pt_zip_put16(out, 0x0800);          // names are UTF-8
        pt_zip_put16(out, 0);               // method 0 = stored
        pt_zip_put16(out, dosTime);
        pt_zip_put16(out, dosDate);
        pt_zip_put32(out, crc);
        pt_zip_put32(out, size);
        pt_zip_put32(out, size);
        pt_zip_put16(out, (uint16_t)nameLength);
        pt_zip_put16(out, 0);
        [out appendBytes:nameBytes length:nameLength];
        [out appendData:data];

        // Central directory record for the same entry.
        pt_zip_put32(central, 0x02014b50);
        pt_zip_put16(central, 20);
        pt_zip_put16(central, 20);
        pt_zip_put16(central, 0x0800);
        pt_zip_put16(central, 0);
        pt_zip_put16(central, dosTime);
        pt_zip_put16(central, dosDate);
        pt_zip_put32(central, crc);
        pt_zip_put32(central, size);
        pt_zip_put32(central, size);
        pt_zip_put16(central, (uint16_t)nameLength);
        pt_zip_put16(central, 0);
        pt_zip_put16(central, 0);
        pt_zip_put16(central, 0);
        pt_zip_put16(central, 0);
        pt_zip_put32(central, 0);
        pt_zip_put32(central, offset);
        [central appendBytes:nameBytes length:nameLength];

        entries++;
    }

    if (entries == 0) return nil;

    uint32_t centralOffset = (uint32_t)out.length;
    [out appendData:central];
    uint32_t centralSize = (uint32_t)central.length;

    pt_zip_put32(out, 0x06054b50);
    pt_zip_put16(out, 0);
    pt_zip_put16(out, 0);
    pt_zip_put16(out, (uint16_t)entries);
    pt_zip_put16(out, (uint16_t)entries);
    pt_zip_put32(out, centralSize);
    pt_zip_put32(out, centralOffset);
    pt_zip_put16(out, 0);

    if (entryCountOut) *entryCountOut = entries;
    if (skippedOut) *skippedOut = skipped;
    return out;
}

NSUInteger settings_passcode_delete_all_backups(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *paths = pt_backup_file_paths();
    if (paths.count == 0) return 0;

    // No recycle bin on this side: the files are the only copy of the stock art
    // Cyanide ever saw, so the caller is expected to have confirmed the loss.
    NSUInteger removed = 0;
    for (NSString *path in paths) {
        if ([fm removeItemAtPath:path error:nil]) removed++;
    }
    if (removed > 0) {
        settings_passcode_invalidate_caches();
        // Nothing on this device can vouch for the keypad art any more, so the
        // panel treats "no backup" as "the art on disk may already be themed".
        pt_set_originals_discarded(true);
    }
    log_user("[PASSCODE] Deleted %lu original backup(s).\n", (unsigned long)removed);
    return removed;
}

BOOL settings_passcode_originals_were_discarded(void)
{
    return pt_originals_discarded();
}

NSURL *settings_passcode_create_backup_archive(NSError **error, NSUInteger *skippedOut)
{
    NSArray<NSString *> *paths = pt_backup_file_paths();
    if (paths.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"PasscodeTheme" code:20 userInfo:@{
                NSLocalizedDescriptionKey: @"There are no original backups to pack yet."
            }];
        }
        return nil;
    }

    if (paths.count > 0xFFFFu) {
        if (error) {
            *error = [NSError errorWithDomain:@"PasscodeTheme" code:22 userInfo:@{
                NSLocalizedDescriptionKey: @"There are more originals than a single .zip can describe."
            }];
        }
        return nil;
    }

    NSUInteger entries = 0;
    NSUInteger skipped = 0;
    NSData *archive = pt_build_backup_zip(paths, &entries, &skipped);
    if (skippedOut) *skippedOut = skipped;
    if (archive.length == 0 || entries == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"PasscodeTheme" code:21 userInfo:@{
                NSLocalizedDescriptionKey: @"The backup files could not be read."
            }];
        }
        return nil;
    }

    NSDateFormatter *stamp = [[NSDateFormatter alloc] init];
    stamp.dateFormat = @"yyyyMMdd-HHmmss";
    stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    stamp.timeZone = [NSTimeZone localTimeZone];
    NSString *name = [NSString stringWithFormat:@"PasscodeOriginals-%@.zip",
                      [stamp stringFromDate:[NSDate date]]];

    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
                  URLByAppendingPathComponent:name];
    if (![archive writeToURL:url options:NSDataWritingAtomic error:error]) return nil;

    log_user("[PASSCODE] Packed %lu backup(s) into %s (%llu bytes).\n",
             (unsigned long)entries, name.UTF8String,
             (unsigned long long)archive.length);
    if (skipped > 0) {
        log_user("[PASSCODE] %lu backup(s) could not be read and are not in the archive.\n",
                 (unsigned long)skipped);
    }
    return url;
}

#pragma mark - Apply / restore

// Applies one digit's art to one keypad file. Returns true only once the new
// bytes are verified on disk; on failure the previous art is restored and the
// original backup is kept for an explicit Restore.
static bool pt_apply_one_digit(NSData *data,
                               NSString *targetPath,
                               NSMutableDictionary<NSString *, NSNumber *> *lockedDirs)
{
    NSData *previous = pt_read_file(targetPath);
    if (previous.length == 0) {
        log_user("[PASSCODE] Could not read the current %s before applying.\n",
                 targetPath.lastPathComponent.UTF8String);
        return false;
    }

    // Re-applying the same style after a respring is the common repeat case;
    // when the file already holds the intended bytes there is nothing to write.
    //
    // Checked before the backup on purpose: if the saved originals were deleted,
    // this file already holds this style's art, and filing it as the "original"
    // would make Restore hand back themed art instead of the stock art.
    if ([previous isEqualToData:data]) {
        return true;
    }

    // This read is also the backup's copy, so both come from the same bytes.
    // Refusing when it cannot be saved keeps the upstream guarantee: never write
    // a digit whose original could not be saved first.
    PTBackupResult backup = pt_backup_original_data_if_needed(previous, targetPath);
    if (backup != PTBackupResultOK) {
        log_user("[PASSCODE] Skipping %s: no original could be saved for it.\n",
                 targetPath.lastPathComponent.UTF8String);
        return false;
    }

    if (!pt_write_data_to_target(data, targetPath, lockedDirs)) return false;

    NSData *applied = pt_read_file(targetPath);
    if ([applied isEqualToData:data]) return true;

    bool recovered = [applied isEqualToData:previous];
    if (!recovered) {
        recovered = pt_write_data_to_target(previous, targetPath, lockedDirs) &&
                    [pt_read_file(targetPath) isEqualToData:previous];
    }
    // Failures stay in the user-visible log: that is what Share Log ships.
    log_user("[PASSCODE] %s did not verify; %s.\n",
             targetPath.lastPathComponent.UTF8String,
             recovered ? "the previous art is preserved"
                       : "the previous art could not be recovered (use Restore to retry)");
    return false;
}

static NSArray<NSString *> *pt_digits_in_order(NSDictionary<NSString *, NSData *> *digits)
{
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSString *digit in digits) {
        if (pt_is_digit_key(digit)) [keys addObject:digit];
    }
    return [keys sortedArrayUsingSelector:@selector(compare:)];
}

// A keypad cache holds dozens of small PNGs, and the snapshot has to fit in
// memory — but it must not be allowed to grow without bound either. Past this
// ceiling the run keeps per-file rollback only.
static const NSUInteger kPTSnapshotBudgetBytes = 64 * 1024 * 1024;

// Reads every target once and returns path -> bytes for a whole-run rollback,
// saving each original from those same bytes (one read serves both purposes).
// wantedByPath maps a target to the art this run will write there, so a file
// that already holds that art is not filed as an original. Paths that cannot be
// read are left out: pt_apply_one_digit() refuses to write them anyway. Returns
// nil when the total exceeds the budget.
static NSDictionary<NSString *, NSData *> *pt_snapshot_and_back_up_targets(
    NSArray<NSString *> *paths,
    NSDictionary<NSString *, NSData *> *wantedByPath)
{
    NSMutableDictionary<NSString *, NSData *> *snapshots = [NSMutableDictionary dictionary];
    NSUInteger total = 0;
    NSUInteger alreadyThemed = 0;

    for (NSString *path in paths) {
        NSData *data = pt_read_file(path);
        if (data.length == 0) continue;

        total += data.length;
        if (total > kPTSnapshotBudgetBytes) {
            log_user("[PASSCODE] The keypad cache is too large to snapshot; only per-file rollback is available.\n");
            return nil;
        }

        // The snapshot is always kept: it is what a rollback must restore.
        snapshots[path] = data;

        // A file that already holds this run's art is not an original — a
        // previous run wrote it, or the user deleted the saved originals. Filing
        // it would make Restore hand back themed art as if it were stock.
        NSData *wanted = wantedByPath[path];
        if (wanted.length > 0 && [data isEqualToData:wanted]) {
            alreadyThemed++;
            continue;
        }

        (void)pt_backup_original_data_if_needed(data, path);
    }

    // One line per run, never one per file: this module's printf is mirrored
    // into the in-app log, and a keypad cache holds dozens of files.
    if (alreadyThemed > 0) {
        log_user("[PASSCODE] %lu file(s) already held this style's art and were not saved as originals.\n",
                 (unsigned long)alreadyThemed);
    }
    return snapshots;
}

// Writes every snapshot back and verifies each restore. Returns how many files
// could not be put back; their originals are still on disk, so an explicit
// Restore can retry.
static NSUInteger pt_rollback_snapshots(NSDictionary<NSString *, NSData *> *snapshots,
                                        NSMutableDictionary<NSString *, NSNumber *> *lockedDirs)
{
    NSArray<NSString *> *paths = [snapshots.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger stuck = 0;

    for (NSString *path in paths) {
        NSData *snapshot = snapshots[path];

        // Files this run never reached already hold the snapshot bytes.
        NSData *current = pt_read_file(path);
        if (current.length > 0 && [current isEqualToData:snapshot]) continue;

        if (pt_write_data_to_target(snapshot, path, lockedDirs) &&
            [pt_read_file(path) isEqualToData:snapshot]) {
            continue;
        }

        stuck++;
        log_user("[PASSCODE] Could not put %s back; use Restore to retry.\n",
                 (path.lastPathComponent ?: path).UTF8String);
    }
    return stuck;
}

bool settings_passcode_apply_digits(NSDictionary<NSString *, NSData *> *digits)
{
    CFTimeInterval startedAt = CFAbsoluteTimeGetCurrent();
    pt_set_summary(nil);
    g_pt_backups_written = 0;
    // This run reads and rewrites the keypad cache, so start from the real
    // state rather than from anything the panel cached while browsing.
    settings_passcode_invalidate_caches();

    if (digits.count == 0) {
        pt_set_summary(@"No digits to apply.");
        log_user("[PASSCODE] Failed: no digits to apply.\n");
        return false;
    }

    if (!kexploit_krw_ready()) {
        pt_set_summary(@"Kernel primitives are not active.");
        log_user("[PASSCODE] Failed: kernel primitives are not active. Run the chain first.\n");
        return false;
    }

    // Unlock /private/var before probing the cache. With the sandbox still
    // closed every candidate directory looks absent, so a cold run would fail
    // with a misleading "no keypad cache found" instead of saying the sandbox
    // could not be opened.
    if (!pt_prepare_sandbox()) {
        pt_set_summary(@"Could not unlock /private/var read/write access.");
        log_user("[PASSCODE] Failed: /private/var read/write access is still denied.\n");
        return false;
    }
    // The unlock changes what is readable, so anything scanned before it is stale.
    settings_passcode_invalidate_caches();

    NSString *basePath = settings_passcode_telephony_base_path();
    if (basePath.length == 0) {
        pt_set_summary(@"No TelephonyUI keypad cache was found on this device.");
        log_user("[PASSCODE] Failed: no TelephonyUI keypad cache was found.\n");
        return false;
    }

    NSDictionary<NSString *, NSArray<NSString *> *> *targets =
        settings_passcode_targets_by_digit(basePath);
    if (targets.count == 0) {
        pt_set_summary(@"No keypad digit files were found in the cache.");
        log_user("[PASSCODE] Failed: no keypad digit files matched in %s.\n",
                 basePath.UTF8String);
        return false;
    }

    log_user("[PASSCODE] Applying %lu digit(s) over %lu keypad file(s) in %s.\n",
             (unsigned long)digits.count,
             (unsigned long)settings_passcode_keypad_file_count(basePath),
             basePath.lastPathComponent.UTF8String);

    // Snapshot every file this run may write, before the first write, so one
    // failed digit can put the whole keypad back instead of leaving it half
    // themed. Each original is saved in the same pass, from the same bytes, so
    // the snapshot costs no extra read.
    NSMutableArray<NSString *> *plannedPaths = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSData *> *plannedArt = [NSMutableDictionary dictionary];
    for (NSString *digit in pt_digits_in_order(digits)) {
        NSData *data = digits[digit];
        if (![data isKindOfClass:NSData.class] || data.length == 0) continue;
        for (NSString *path in targets[digit] ?: @[]) {
            [plannedPaths addObject:path];
            plannedArt[path] = data;
        }
    }
    NSDictionary<NSString *, NSData *> *snapshots =
        pt_snapshot_and_back_up_targets(plannedPaths, plannedArt);

    NSUInteger applied = 0;
    NSUInteger failed = 0;
    NSMutableArray<NSString *> *details = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *lockedDirs = [NSMutableDictionary dictionary];

    for (NSString *digit in pt_digits_in_order(digits)) {
        NSData *data = digits[digit];
        if (![data isKindOfClass:NSData.class] || data.length == 0) {
            failed++;
            [details addObject:[NSString stringWithFormat:@"digit %@ has no art", digit]];
            log_user("[PASSCODE] Digit %s has no art to write.\n", digit.UTF8String);
            continue;
        }

        NSArray<NSString *> *paths = targets[digit];
        if (paths.count == 0) {
            failed++;
            [details addObject:[NSString stringWithFormat:@"no keypad file for digit %@", digit]];
            log_user("[PASSCODE] No keypad file matched digit %s.\n", digit.UTF8String);
            continue;
        }

        for (NSString *path in paths) {
            NSString *file = path.lastPathComponent ?: path;
            if (pt_apply_one_digit(data, path, lockedDirs)) {
                applied++;
            } else {
                failed++;
                [details addObject:file];
                log_user("[PASSCODE] Failed digit %s -> %s\n",
                         digit.UTF8String, file.UTF8String);
            }
        }
    }

    // Roll the whole run back before the folder modes are restored: a rollback
    // still writes files. A half-themed keypad (some digits new, some stock) is
    // worse than no change at all.
    NSString *rollbackNote = @"";
    if (failed > 0) {
        if (snapshots) {
            NSUInteger stuck = pt_rollback_snapshots(snapshots, lockedDirs);
            rollbackNote = stuck == 0
                ? @" The keypad was put back to its previous art."
                : [NSString stringWithFormat:@" %lu file(s) could not be put back (use Restore to retry).",
                                             (unsigned long)stuck];
        } else {
            rollbackNote = @" The keypad may be partially themed.";
        }
    }

    pt_restore_directory_modes(lockedDirs);

    // The keypad cache just changed: nothing cached about it is valid anymore.
    settings_passcode_invalidate_caches();

    NSString *backupNote = g_pt_backups_written > 0
        ? [NSString stringWithFormat:@", %lu original(s) saved", (unsigned long)g_pt_backups_written]
        : @"";

    if (failed == 0) {
        // Main clause first, detail second — same shape as the other actions'
        // logs ("[OK] Location Simulator applied.", "[NANO] Wrote pairing gates: …").
        NSString *detail = [NSString stringWithFormat:@"%lu file(s) in %.1fs%@.",
                            (unsigned long)applied,
                            CFAbsoluteTimeGetCurrent() - startedAt,
                            backupNote];
        pt_set_summary([NSString stringWithFormat:@"Passcode style applied. %@", detail]);
        log_user("[OK] Passcode style applied. %s\n", detail.UTF8String);
        return applied > 0;
    }

    NSString *detail = [NSString stringWithFormat:
        @"%lu file(s) written, %lu failed in %.1fs%@.%@ Failures: %@.",
        (unsigned long)applied, (unsigned long)failed,
        CFAbsoluteTimeGetCurrent() - startedAt,
        backupNote,
        rollbackNote,
        [details componentsJoinedByString:@", "]];
    pt_set_summary([NSString stringWithFormat:@"Passcode style did not apply cleanly. %@", detail]);
    log_user("[WARN] Passcode style did not apply cleanly. %s\n", detail.UTF8String);
    // A partial apply counts as a failure: this flag drives the completion
    // banner, and a banner reading "Complete" above a summary that lists failed
    // files is worse than an honest failure. The per-file detail is in the
    // summary either way.
    return false;
}

bool settings_passcode_restore_originals(NSString *basePath)
{
    CFTimeInterval startedAt = CFAbsoluteTimeGetCurrent();
    pt_set_summary(nil);
    g_pt_backups_written = 0;
    // Same as apply: work from the real keypad state, not from cache.
    settings_passcode_invalidate_caches();

    if (!kexploit_krw_ready()) {
        pt_set_summary(@"Kernel primitives are not active.");
        log_user("[PASSCODE] Failed: kernel primitives are not active. Run the chain first.\n");
        return false;
    }

    // Unlock before resolving or probing the cache path, for the same reason as
    // apply: a closed sandbox makes every candidate directory look absent.
    // Callers may pass a path they already resolved; an empty argument resolves
    // here, so this function is correct on its own.
    if (!pt_prepare_sandbox()) {
        pt_set_summary(@"Could not unlock /private/var read/write access.");
        log_user("[PASSCODE] Failed: /private/var read/write access is still denied.\n");
        return false;
    }
    settings_passcode_invalidate_caches();

    if (basePath.length == 0) {
        basePath = settings_passcode_telephony_base_path();
    }
    if (basePath.length == 0) {
        pt_set_summary(@"No TelephonyUI keypad cache was found on this device.");
        log_user("[PASSCODE] Failed: no TelephonyUI keypad cache was found.\n");
        return false;
    }

    NSDictionary<NSString *, NSArray<NSString *> *> *targets =
        settings_passcode_targets_by_digit(basePath);
    if (targets.count == 0) {
        pt_set_summary(@"No keypad digit files were found in the cache.");
        log_user("[PASSCODE] Failed: no keypad digit files matched in %s.\n",
                 basePath.UTF8String);
        return false;
    }

    log_user("[PASSCODE] Restoring the original digits in %s.\n", basePath.lastPathComponent.UTF8String);

    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger restored = 0;
    NSUInteger failed = 0;
    NSMutableArray<NSString *> *details = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *lockedDirs = [NSMutableDictionary dictionary];

    NSArray<NSString *> *digits = [targets.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *digit in digits) {
        for (NSString *path in targets[digit]) {
            if (![fm fileExistsAtPath:pt_backup_path(path)]) continue;

            NSString *file = path.lastPathComponent ?: path;
            NSData *original = pt_backup_data(path);
            if (original.length == 0) {
                failed++;
                [details addObject:[NSString stringWithFormat:@"%@ backup unreadable", file]];
                log_user("[PASSCODE] Backup for %s is missing or unreadable.\n",
                         file.UTF8String);
                continue;
            }

            // Restoring twice is a no-op: skip files that already hold the
            // original bytes instead of rewriting and re-reading them.
            NSData *current = pt_read_file(path);
            if (current.length > 0 && [current isEqualToData:original]) {
                restored++;
                continue;
            }

            if (pt_write_data_to_target(original, path, lockedDirs) &&
                [pt_read_file(path) isEqualToData:original]) {
                restored++;
            } else {
                failed++;
                [details addObject:file];
                log_user("[PASSCODE] Failed to restore %s; its backup is retained.\n",
                         file.UTF8String);
            }
        }
    }

    pt_restore_directory_modes(lockedDirs);

    // The keypad cache just changed: nothing cached about it is valid anymore.
    settings_passcode_invalidate_caches();

    if (restored == 0 && failed == 0) {
        pt_set_summary(@"No original digit backups were found to restore.");
        log_user("[WARN] No original digit backups were found to restore.\n");
        return false;
    }

    if (failed == 0) {
        NSString *detail = [NSString stringWithFormat:@"%lu file(s) in %.1fs.",
                            (unsigned long)restored,
                            CFAbsoluteTimeGetCurrent() - startedAt];
        pt_set_summary([NSString stringWithFormat:@"Original digits restored. %@", detail]);
        log_user("[OK] Original digits restored. %s\n", detail.UTF8String);
        return true;
    }

    NSString *detail = [NSString stringWithFormat:
        @"%lu file(s) restored, %lu failed in %.1fs: %@. Original backups are retained.",
        (unsigned long)restored, (unsigned long)failed,
        CFAbsoluteTimeGetCurrent() - startedAt,
        [details componentsJoinedByString:@", "]];
    pt_set_summary([NSString stringWithFormat:@"Originals did not restore cleanly. %@", detail]);
    log_user("[WARN] Originals did not restore cleanly. %s\n", detail.UTF8String);
    // Same rule as apply: a partial restore is reported as a failure, with the
    // per-file detail carried in the summary.
    return false;
}

#pragma mark - Theme library

// ---------------------------------------------------------------------------
// Single-style library
//
// The library holds one style: <App Support>/PasscodeThemes, with <digit>.png
// files directly inside. The helpers below build the dictionary shape the rest
// of the module (and the Settings panel) expects.
// ---------------------------------------------------------------------------

static NSString * const kPTStyleNameKey = @"PasscodeStyleName";

static NSString *pt_style_dir(void)
{
    return pt_library_dir();
}

static NSString *pt_style_name(void)
{
    NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:kPTStyleNameKey];
    return name.length > 0 ? name : @"Imported Style";
}

static void pt_set_style_name(NSString *name)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (name.length > 0) {
        [d setObject:name forKey:kPTStyleNameKey];
    } else {
        [d removeObjectForKey:kPTStyleNameKey];
    }
    [d synchronize];
}

static NSDictionary *pt_style_dictionary(void)
{
    NSString *dir = pt_style_dir();
    if (dir.length == 0) return nil;
    return @{ @"id": @"current", @"name": pt_style_name(), @"digitsPath": dir };
}

// The library holds one style, so the caller's theme dictionary no longer
// selects a folder: this returns the single style folder when it exists.
static NSString *pt_theme_digits_dir(void)
{
    NSString *dir = pt_style_dir();
    if (dir.length == 0) return nil;
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        return nil;
    }
    return dir;
}

NSDictionary *settings_passcode_selected_theme(void)
{
    NSString *dir = pt_style_dir();
    if (dir.length == 0) return nil;

    // "A style exists" means the same thing here as it does everywhere else: at
    // least one digit file the applier can use (0.png … 9.png, non-empty). A
    // folder holding only PNGs named some other way is not a style, so the
    // panel and the applier can never disagree about whether there is one.
    NSDictionary *style = pt_style_dictionary();
    if (!style) return nil;
    if (settings_passcode_theme_digit_presence(style).count == 0) return nil;
    return style;
}

NSString *settings_passcode_selected_theme_display_name(void)
{
    NSDictionary *theme = settings_passcode_selected_theme();
    if (!theme) return @"None selected";
    NSString *name = theme[@"name"];
    return name.length > 0 ? name : @"Imported Style";
}

void settings_passcode_clear_selected_theme(void)
{
    // Clearing drops the digit art; the folder itself stays (a user may keep
    // other files in it) and only PNGs are removed.
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = pt_style_dir();
    if (dir.length > 0) {
        for (NSString *entry in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![entry.lowercaseString hasSuffix:@".png"]) continue;
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:entry] error:nil];
        }
    }
    pt_set_style_name(nil);
    settings_passcode_invalidate_caches();
}

NSDictionary *settings_passcode_ensure_selected_theme(NSError **error)
{
    NSDictionary *style = settings_passcode_selected_theme();
    if (style) return style;

    NSString *dir = pt_style_dir();
    if (dir.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"PasscodeTheme" code:6 userInfo:@{
                NSLocalizedDescriptionKey: @"Cyanide's style folder is unavailable."
            }];
        }
        return nil;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:dir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:error]) {
        return nil;
    }

    if (pt_style_name().length == 0) pt_set_style_name(@"My Style");
    settings_passcode_invalidate_caches();
    log_user("[PASSCODE] Created a style folder to hold picked digit art.\n");
    return pt_style_dictionary();
}

static NSString *pt_digit_path_in_dir(NSString *dir, NSString *digit)
{
    return [dir stringByAppendingPathComponent:
            [digit stringByAppendingString:@".png"]];
}

// A PNG magic match only proves the header, and UIImage's decode is lazy, so a
// corrupt body would reach the Lock Screen renderer — the one path that can lock
// the user out. Draw the image once to force a real pixel decode. The bytes that
// get written are still the caller's originals.
static BOOL pt_png_is_renderable(NSData *data)
{
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NO;

    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return NO;

    BOOL ok = NO;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, 1, 1, 8, 4, space,
                                                 kCGImageAlphaPremultipliedLast);
    if (context) {
        CGContextDrawImage(context, CGRectMake(0.0, 0.0, 1.0, 1.0), image);
        ok = YES;
        CGContextRelease(context);
    }
    CGColorSpaceRelease(space);
    CGImageRelease(image);
    return ok;
}

// Keypad art always lands under a .png name, so JPEG imports are re-encoded
// once here and the library only ever holds true PNGs. PNG input keeps its
// original bytes, but only once it has been proven renderable.
static NSData *pt_normalized_png_data(NSData *data)
{
    if (data.length < 8) return nil;

    static const uint8_t pngMagic[8] = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (memcmp(data.bytes, pngMagic, sizeof(pngMagic)) == 0) {
        return pt_png_is_renderable(data) ? data : nil;
    }

    UIImage *image = [UIImage imageWithData:data];
    return image ? UIImagePNGRepresentation(image) : nil;
}

static NSDictionary<NSString *, NSData *> *pt_scan_theme_images(NSString *dir)
{
    NSMutableDictionary<NSString *, NSData *> *out = [NSMutableDictionary dictionary];
    for (NSInteger value = 0; value <= 9; value++) {
        NSString *digit = [NSString stringWithFormat:@"%ld", (long)value];
        NSData *data = [NSData dataWithContentsOfFile:pt_digit_path_in_dir(dir, digit)];
        if (data.length > 0) out[digit] = data;
    }
    return out;
}

// Cached per theme folder: the preview and the applier both load the whole
// style on every build, and the digit-writing entry point drops the cache.
NSDictionary<NSString *, NSData *> *settings_passcode_theme_digit_images(NSDictionary *theme)
{
    // Keep "no style dictionary means no art", which the folder lookup used to
    // enforce before it dropped the theme parameter.
    if (![theme isKindOfClass:NSDictionary.class]) return @{};
    NSString *dir = pt_theme_digits_dir();
    if (dir.length == 0) return @{};

    pthread_mutex_lock(&g_pt_cache_lock);
    BOOL fresh = g_pt_theme_images && [g_pt_theme_images_key isEqualToString:dir];
    NSDictionary *cached = g_pt_theme_images;
    pthread_mutex_unlock(&g_pt_cache_lock);
    if (fresh) return cached;

    NSDictionary *computed = pt_scan_theme_images(dir);

    pthread_mutex_lock(&g_pt_cache_lock);
    g_pt_theme_images     = computed;
    g_pt_theme_images_key = [dir copy];
    pthread_mutex_unlock(&g_pt_cache_lock);
    return computed;
}

static PTPasscodeStyleState pt_compute_style_state(void)
{
    NSDictionary *theme = settings_passcode_selected_theme();
    if (!theme) return PTPasscodeStyleStateNotApplied;

    NSSet<NSString *> *digits = settings_passcode_theme_digit_presence(theme);
    if (digits.count == 0) return PTPasscodeStyleStateNotApplied;

    NSString *themeDir = pt_theme_digits_dir();
    NSString *basePath = settings_passcode_telephony_base_path();
    if (themeDir.length == 0 || basePath.length == 0) return PTPasscodeStyleStateUnknown;

    NSDictionary<NSString *, NSArray<NSString *> *> *targets =
        settings_passcode_targets_by_digit(basePath);
    // An empty listing after a fresh boot means the cache is unreadable without
    // kernel access, not that the keypad has no art: the style is still applied
    // on disk. Report Unknown instead of guessing "not applied".
    if (targets.count == 0) return PTPasscodeStyleStateUnknown;

    // One digit is enough for a status line: compare the first digit the style
    // covers against the first keypad file for it.
    NSArray<NSString *> *ordered = [digits.allObjects sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *digit in ordered) {
        NSArray<NSString *> *paths = targets[digit];
        if (paths.count == 0) continue;

        NSData *wanted = [NSData dataWithContentsOfFile:pt_digit_path_in_dir(themeDir, digit)];
        if (wanted.length == 0) continue;

        NSData *installed = pt_read_file(paths.firstObject);
        if (installed.length == 0) return PTPasscodeStyleStateUnknown;
        return [installed isEqualToData:wanted] ? PTPasscodeStyleStateApplied
                                                : PTPasscodeStyleStateNotApplied;
    }
    return PTPasscodeStyleStateUnknown;
}

// Cached: the status row recomputes this on every build and each computation
// reads the keypad cache. The short TTL keeps it honest when another app (or a
// respring) rewrites the cache while the panel stays open.
PTPasscodeStyleState settings_passcode_style_state(void)
{
    double now = pt_cache_now();
    pthread_mutex_lock(&g_pt_cache_lock);
    BOOL fresh = g_pt_style_state_ok && (now - g_pt_style_state_at) < kPTCacheTTL;
    PTPasscodeStyleState cached = g_pt_style_state;
    pthread_mutex_unlock(&g_pt_cache_lock);
    if (fresh) return cached;

    PTPasscodeStyleState computed = pt_compute_style_state();

    pthread_mutex_lock(&g_pt_cache_lock);
    g_pt_style_state    = computed;
    g_pt_style_state_ok = YES;
    g_pt_style_state_at = pt_cache_now();
    pthread_mutex_unlock(&g_pt_cache_lock);
    return computed;
}

static NSSet<NSString *> *pt_scan_theme_presence(NSString *dir)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableSet<NSString *> *present = [NSMutableSet set];
    for (NSInteger value = 0; value <= 9; value++) {
        NSString *digit = [NSString stringWithFormat:@"%ld", (long)value];
        NSDictionary *attributes = [fm attributesOfItemAtPath:pt_digit_path_in_dir(dir, digit)
                                                       error:nil];
        if ([attributes[NSFileSize] unsignedLongLongValue] > 0) {
            [present addObject:digit];
        }
    }
    return present;
}

// Cached per theme folder: ten stats that the status row, the list rows and the
// digit count all ask for on every build. Dropped whenever the style's contents
// change.
NSSet<NSString *> *settings_passcode_theme_digit_presence(NSDictionary *theme)
{
    // Same guard as the image loader: a non-dictionary theme means no style.
    if (![theme isKindOfClass:NSDictionary.class]) return [NSSet set];
    NSString *dir = pt_theme_digits_dir();
    if (dir.length == 0) return [NSSet set];

    pthread_mutex_lock(&g_pt_cache_lock);
    BOOL fresh = g_pt_presence && [g_pt_presence_key isEqualToString:dir];
    NSSet *cached = g_pt_presence;
    pthread_mutex_unlock(&g_pt_cache_lock);
    if (fresh) return cached;

    NSSet *computed = pt_scan_theme_presence(dir);

    pthread_mutex_lock(&g_pt_cache_lock);
    g_pt_presence     = computed;
    g_pt_presence_key = [dir copy];
    pthread_mutex_unlock(&g_pt_cache_lock);
    return computed;
}

BOOL settings_passcode_theme_set_digit_image(NSDictionary *theme,
                                             NSString *digit,
                                             NSData *pngData,
                                             NSError **error)
{
    if (!pt_is_digit_key(digit) || pngData.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"PasscodeTheme" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"Choose a digit image before saving."
            }];
        }
        return NO;
    }

    // A non-dictionary theme means no style folder, exactly as when the folder
    // lookup still rejected the parameter itself.
    NSString *dir = [theme isKindOfClass:NSDictionary.class] ? pt_theme_digits_dir() : nil;
    if (dir.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"PasscodeTheme" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"The selected style folder is missing."
            }];
        }
        return NO;
    }

    if (![pngData writeToFile:pt_digit_path_in_dir(dir, digit)
                     options:NSDataWritingAtomic
                       error:error]) {
        return NO;
    }
    // The style's contents changed: presence, the loaded images and the status
    // line are all stale now.
    settings_passcode_invalidate_caches();
    log_user("[PASSCODE] Saved digit %s art into the selected style.\n", digit.UTF8String);
    return YES;
}

BOOL settings_passcode_import_folder_named(NSURL *url,
                                           NSString *displayName,
                                           NSError **error)
{
    if (url.path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"PasscodeTheme" code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"The selected folder could not be read."
            }];
        }
        return NO;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *styleDir = pt_style_dir();
    if (styleDir.length == 0) {
        return NO;
    }
    if (![fm createDirectoryAtPath:styleDir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:error]) {
        return NO;
    }

    // Match every PNG/JPG in the imported folder to a digit. Sorted so a pack
    // holding several files for one digit resolves the same way twice.
    NSMutableArray<NSArray<NSString *> *> *candidates = [NSMutableArray array];
    NSDirectoryEnumerator<NSString *> *en = [fm enumeratorAtPath:url.path];
    for (NSString *relative in en) {
        NSString *lower = relative.lowercaseString;
        // macOS-built archives carry an __MACOSX folder of AppleDouble metadata
        // ("<name>") that must never be matched as digit art.
        if ([lower containsString:@"__macosx/"]) continue;

        // A backup file is named after the keypad path it came from and keeps
        // the .orig suffix ("…other-2-5--dark@3x.png.orig"). Those carry digit
        // art too, so strip that suffix before deciding whether this is an
        // image — it makes an archive exported by Export Backups importable as
        // a style. settings_passcode_digit_for_filename() already reads the
        // digit out of these names because it matches the "other-2-N--dark"
        // marker anywhere in it.
        NSString *candidateName = lower;
        if ([candidateName hasSuffix:@".orig"]) {
            candidateName = [candidateName substringToIndex:candidateName.length - 5];
        }
        if (![candidateName hasSuffix:@".png"] && ![candidateName hasSuffix:@".jpg"] &&
            ![candidateName hasSuffix:@".jpeg"]) {
            continue;
        }
        // The digit is parsed once here and carried with the path; the match
        // loop below just reads it back.
        NSString *digit = settings_passcode_digit_for_filename(relative);
        if (digit.length == 0) continue;
        NSArray<NSString *> *pair = @[ relative, digit ];
        [candidates addObject:pair];
    }
    // Sorted by path, exactly like the plain string array this used to be, so
    // the file that wins for a digit shipping several variants stays the same.
    [candidates sortUsingComparator:^NSComparisonResult(NSArray<NSString *> *a, NSArray<NSString *> *b) {
        return [a.firstObject compare:b.firstObject];
    }];

    NSMutableDictionary<NSString *, NSData *> *matched = [NSMutableDictionary dictionary];
    for (NSArray<NSString *> *pair in candidates) {
        NSString *relative = pair.firstObject;
        NSString *digit = pair.lastObject;
        if (matched[digit]) continue;

        NSData *data = [NSData dataWithContentsOfFile:
                        [url.path stringByAppendingPathComponent:relative]];
        if (data.length == 0) continue;
        if (data.length > kPTMaxDigitBytes) {
            log_user("[PASSCODE] Skipping oversized image %s (%lu bytes).\n",
                     relative.UTF8String, (unsigned long)data.length);
            continue;
        }

        NSData *png = pt_normalized_png_data(data);
        if (png.length == 0) {
            log_user("[PASSCODE] Skipping unreadable image %s.\n", relative.UTF8String);
            continue;
        }
        matched[digit] = png;
    }

    if (matched.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"PasscodeTheme" code:4 userInfo:@{
                NSLocalizedDescriptionKey: @"No keypad digit images were found in the selected folder. Name each image after its digit (0-9) or keep the style's original keypad filenames."
            }];
        }
        return NO;
    }

    // Stage every digit as "<digit>.png.tmp" first. Nothing touches the live
    // style until the whole package is on disk, so a package that fails halfway
    // cannot cost the user the style they already had.
    NSMutableArray<NSString *> *staged = [NSMutableArray array];
    for (NSString *digit in matched) {
        NSString *tmpPath = [pt_digit_path_in_dir(styleDir, digit) stringByAppendingString:@".tmp"];
        if (![matched[digit] writeToFile:tmpPath options:NSDataWritingAtomic error:nil]) {
            for (NSString *done in staged) [fm removeItemAtPath:done error:nil];
            if (error) {
                *error = [NSError errorWithDomain:@"PasscodeTheme" code:5 userInfo:@{
                    NSLocalizedDescriptionKey: @"The style could not be written; the previous style is unchanged."
                }];
            }
            return NO;
        }
        [staged addObject:tmpPath];
    }

    // Swap the staged art in. Each rename stays inside one directory, so a digit
    // is either fully old or fully new — never missing.
    for (NSString *tmpPath in staged) {
        NSString *finalPath = [tmpPath substringToIndex:tmpPath.length - 4];   // drop ".tmp"
        [fm removeItemAtPath:finalPath error:nil];
        if (![fm moveItemAtPath:tmpPath toPath:finalPath error:nil]) {
            for (NSString *rest in staged) [fm removeItemAtPath:rest error:nil];
            if (error) {
                *error = [NSError errorWithDomain:@"PasscodeTheme" code:5 userInfo:@{
                    NSLocalizedDescriptionKey: @"The style could not be written; the previous style is unchanged."
                }];
            }
            return NO;
        }
    }

    // The staged art is live; only now drop PNGs the new style does not cover.
    NSMutableSet<NSString *> *covered = [NSMutableSet set];
    for (NSString *digit in matched) [covered addObject:[digit stringByAppendingString:@".png"]];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:styleDir error:nil]) {
        if (![entry.lowercaseString hasSuffix:@".png"]) continue;
        if ([covered containsObject:entry]) continue;
        [fm removeItemAtPath:[styleDir stringByAppendingPathComponent:entry] error:nil];
    }

    NSString *name = displayName.length > 0 ? displayName : @"Imported Style";
    pt_set_style_name(name);
    settings_passcode_invalidate_caches();
    log_user("[PASSCODE] Imported style \"%s\" with %lu digit(s).\n",
             name.UTF8String, (unsigned long)matched.count);
    return YES;
}

#pragma mark - Image import

NSData *settings_passcode_png_data_for_image(UIImage *image)
{
    if (!image || image.size.height <= 0.0) return nil;

    CGFloat scale = kPTKeypadArtHeight / image.size.height;
    CGSize size = CGSizeMake(MAX(image.size.width * scale, 1.0), kPTKeypadArtHeight);

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *resized = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0.0, 0.0, size.width, size.height)];
    }];
    return UIImagePNGRepresentation(resized);
}
