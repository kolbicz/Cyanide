//
//  darksword_ota.m
//

#import "darksword_ota.h"
#import "../LogTextView.h"
#import "../TaskRop/RemoteCall.h"
#import "../kexploit/kexploit_opa334.h"
#import "../kexploit/persistence.h"
#import "../kexploit/krw.h"
#import "../kexploit/offsets.h"
#import "../kexploit/vnode.h"
#import "../utils/sandbox.h"
#import "daemon_catalog.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <notify.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>

static const char *kOTAPlistDirPath = "/private/var/db/com.apple.xpc.launchd";
static const char *kOTAPlistFileName = "disabled.plist";
static const char *kOTAPlistTempFileName = "disabled.plist.cyanide.tmp";
static const char *kOTAOriginalPlistPath = "/var/db/com.apple.xpc.launchd/disabled.plist";
static NSString * const kOTAMobileGestaltPath =
    @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
static const uint64_t kOTABufferSize = 65536;

typedef struct {
    NSString *localDir;
    uint64_t localVnode;
    uint64_t originalVData;
    bool active;
} OTADirRedirect;

static NSArray<NSString *> *ota_daemon_labels(void)
{
    return @[
        @"com.apple.mobile.softwareupdated",
        @"com.apple.OTATaskingAgent",
        @"com.apple.softwareupdateservicesd",
        @"com.apple.mobile.NRDUpdated",
    ];
}

static NSArray<NSString *> *ota_customer_catalog_preference_paths(void)
{
    return @[
        @"/var/mobile/Library/Preferences/com.apple.softwareupdateservicesd.plist",
        @"/var/mobile/Library/Preferences/com.apple.MobileSoftwareUpdate.plist",
    ];
}

static uint64_t ota_vnode_for_absolute_path(const char *path)
{
    if (!path || path[0] != '/') return 0;

    uint64_t vnode = get_rootvnode();
    if (!vnode || vnode == (uint64_t)-1) return 0;

    char copy[PATH_MAX] = {0};
    strlcpy(copy, path, sizeof(copy));
    char *save = NULL;
    for (char *part = strtok_r(copy, "/", &save);
         part;
         part = strtok_r(NULL, "/", &save)) {
        uint64_t child = vnode_get_child_vnode(vnode, part, 0);
        if (!child || child == (uint64_t)-1) {
            printf("[OTA] vnode lookup failed path=%s part=%s parent=0x%llx\n",
                   path, part, vnode);
            return 0;
        }
        vnode = child;
    }
    return vnode;
}

static bool ota_begin_launchd_dir_redirect(OTADirRedirect *redir)
{
    if (!redir) return false;
    memset(redir, 0, sizeof(*redir));

    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/ota_launchd_redirect"];
    NSError *mkdirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&mkdirError];
    if (mkdirError) {
        printf("[OTA] create redirect dir failed: %s\n", mkdirError.description.UTF8String);
        return false;
    }

    uint64_t localVnode = get_vnode_for_path_by_chdir(dir.UTF8String);
    if (!localVnode || localVnode == (uint64_t)-1) {
        printf("[OTA] local redirect dir vnode lookup failed: %s\n", dir.UTF8String);
        return false;
    }

    uint64_t targetVnode = ota_vnode_for_absolute_path(kOTAPlistDirPath);
    if (!targetVnode) {
        printf("[OTA] launchd plist dir vnode lookup failed: %s\n", kOTAPlistDirPath);
        return false;
    }

    uint64_t originalVData = kread64(localVnode + off_vnode_v_data);
    uint64_t targetVData = kread64(targetVnode + off_vnode_v_data);
    if (!originalVData || !targetVData) {
        printf("[OTA] redirect v_data invalid local=0x%llx target=0x%llx\n",
               originalVData, targetVData);
        return false;
    }

    // kwrite64 has no result: read back, and never treat app-directory I/O
    // as a launchd edit unless the redirect is really in place.
    kwrite64(localVnode + off_vnode_v_data, targetVData);
    uint64_t readBack = kread64(localVnode + off_vnode_v_data);
    if (readBack != targetVData) {
        printf("[OTA] redirect write not verified want=0x%llx got=0x%llx\n",
               targetVData, readBack);
        if (readBack != originalVData) {
            kwrite64(localVnode + off_vnode_v_data, originalVData);
            uint64_t restored = kread64(localVnode + off_vnode_v_data);
            if (restored != originalVData) {
                printf("[OTA] !!! redirect dir v_data NOT restored want=0x%llx got=0x%llx\n",
                       originalVData, restored);
            }
        }
        return false;
    }
    redir->localDir = dir;
    redir->localVnode = localVnode;
    redir->originalVData = originalVData;
    redir->active = true;
    printf("[OTA] redirected %s -> %s\n", dir.UTF8String, kOTAPlistDirPath);
    return true;
}

// Returns false if the original v_data can't be verified back in place;
// callers must then report failure (the app dir may still alias launchd's).
static bool ota_end_launchd_dir_redirect(OTADirRedirect *redir)
{
    if (!redir || !redir->active) return true;
    kwrite64(redir->localVnode + off_vnode_v_data, redir->originalVData);
    uint64_t readBack = kread64(redir->localVnode + off_vnode_v_data);
    if (readBack != redir->originalVData) {
        printf("[OTA] !!! redirect dir %s NOT restored want=0x%llx got=0x%llx\n",
               redir->localDir.UTF8String, redir->originalVData, readBack);
        return false;
    }
    redir->active = false;
    printf("[OTA] restored redirect dir %s\n", redir->localDir.UTF8String);
    return true;
}

// A plist that exists and can't be read or parsed is an error (nil), never
// an empty dictionary -- writing that back would drop every other entry, and
// reporting it would show corrupt state as "enabled".
static NSMutableDictionary *ota_read_disabled_plist_strict(NSString *plistPath)
{
    if (access(plistPath.fileSystemRepresentation, F_OK) != 0 && errno == ENOENT)
        return [NSMutableDictionary dictionary];
    NSData *data = [NSData dataWithContentsOfFile:plistPath];
    if (!data) {
        printf("[DAEMONS] disabled.plist exists but can't be read\n");
        return nil;
    }
    if (data.length == 0) return [NSMutableDictionary dictionary];
    if (data.length > kOTABufferSize) {
        printf("[DAEMONS] disabled.plist too large len=%lu\n", (unsigned long)data.length);
        return nil;
    }
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListMutableContainersAndLeaves
                                                          format:nil
                                                           error:nil];
    if (![plist isKindOfClass:NSMutableDictionary.class]) {
        printf("[DAEMONS] disabled.plist is not a dictionary\n");
        return nil;
    }
    return plist;
}

static bool ota_write_all(int fd, const uint8_t *bytes, NSUInteger length)
{
    NSUInteger total = 0;
    while (total < length) {
        ssize_t written = write(fd, bytes + total, length - total);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            printf("[OTA] write failed at %lu/%lu errno=%d\n",
                   (unsigned long)total, (unsigned long)length, errno);
            return false;
        }
        total += (NSUInteger)written;
    }
    return true;
}

static bool ota_vnode_chmod(const char *path, mode_t mode, const char *label)
{
    int ret = vnode_apfs_chmod(path, mode);
    if (ret != 0) {
        printf("[OTA] vnode chmod failed for %s path=%s mode=%o ret=%d\n",
               label, path, mode, ret);
        return false;
    }
    return true;
}

static bool ota_vnode_chown(const char *path, uid_t uid, gid_t gid, const char *label)
{
    int ret = vnode_apfs_chown(path, uid, gid);
    if (ret != 0) {
        printf("[OTA] vnode chown failed for %s path=%s uid=%u gid=%u ret=%d\n",
               label, path, uid, gid, ret);
        return false;
    }
    return true;
}

// The launchd plist folder is widened (o+wx) for the write and narrowed again
// afterwards. vnode_apfs_chmod can apply a mode yet report failure, so the
// folder's mode is always checked with stat, and a restore that can't be
// proven leaves a record (the mode to put back) that is retried before the
// next write and whenever kernel access comes back -- the folder must never
// stay world-writable silently.
//
// The record always means the launchd folder itself, never the path it was
// reached through: on the redirect route that path is an app folder that
// aliases launchd's only while the redirect is active, so a later chmod
// through it would change the app folder and leave launchd's widened.
static NSString * const kOTADirRestorePendingKey = @"OTADirModeRestorePending";
static NSString * const kOTADirRestoreModeKey = @"OTADirModeRestoreMode";
static NSString * const kOTADirRestoreLegacyPathKey = @"OTADirModeRestorePath";   // 1.9.0 builds before this fix

static bool ota_dir_mode_is(const char *path, mode_t mode)
{
    struct stat st = {0};
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode) && (st.st_mode & 07777) == (mode & 07777);
}

static void ota_set_dir_restore_record(bool pending, mode_t mode)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d removeObjectForKey:kOTADirRestoreLegacyPathKey];
    if (pending) {
        [d setBool:YES forKey:kOTADirRestorePendingKey];
        [d setInteger:(NSInteger)mode forKey:kOTADirRestoreModeKey];
    } else {
        [d removeObjectForKey:kOTADirRestorePendingKey];
        [d removeObjectForKey:kOTADirRestoreModeKey];
    }
    [d synchronize];
}

// Puts the launchd folder back to `mode` and proves it. accessPath is how the
// folder is reached right now: kOTAPlistDirPath itself, or an active
// redirect's local folder. Keeps (or clears) the record.
static bool ota_restore_dir_mode(const char *accessPath, mode_t mode, const char *label)
{
    if (!ota_dir_mode_is(accessPath, mode)) {
        (void)ota_vnode_chmod(accessPath, mode, label);   // the stat below decides, not the return
    }
    if (ota_dir_mode_is(accessPath, mode)) {
        ota_set_dir_restore_record(false, 0);
        return true;
    }
    ota_set_dir_restore_record(true, mode);
    printf("[OTA] !!! launchd plist folder mode NOT restored (want %o); will retry\n", mode);
    return false;
}

// The pending mode, or 0 when nothing is pending (or the record is malformed:
// a mode without the folder type would retype it, so it is dropped).
static mode_t ota_pending_dir_restore_mode(void)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL pending = [d boolForKey:kOTADirRestorePendingKey] ||
                   [d stringForKey:kOTADirRestoreLegacyPathKey].length > 0;
    if (!pending) return 0;
    mode_t mode = (mode_t)[d integerForKey:kOTADirRestoreModeKey];
    if (!S_ISDIR(mode)) {
        printf("[OTA] dropping malformed folder-restore record (mode %o)\n", mode);
        ota_set_dir_restore_record(false, 0);
        return 0;
    }
    return mode;
}

// Retry through a path the caller already has access through (a write in
// progress: direct, or inside its own redirect).
static bool ota_retry_pending_dir_restore_via(NSString *accessPath)
{
    mode_t mode = ota_pending_dir_restore_mode();
    if (!mode) return true;
    printf("[OTA] retrying the pending launchd folder-mode restore\n");
    return ota_restore_dir_mode(accessPath.fileSystemRepresentation, mode, "pending dir restore");
}

static bool ota_begin_launchd_dir_redirect(OTADirRedirect *redir);
static bool ota_end_launchd_dir_redirect(OTADirRedirect *redir);

// Public hook for the first moment kernel access is available again: a crash
// between widening the launchd folder and restoring it must not leave it o+wx
// until someone happens to perform another OTA write. Uses the folder's own
// path when it is reachable, else a short-lived redirect, as a write would.
void darksword_ota_retry_pending_dir_restore(void)
{
    if (!ota_pending_dir_restore_mode() || !kexploit_krw_ready()) return;
    struct stat st = {0};
    if (stat(kOTAPlistDirPath, &st) == 0) {
        (void)ota_retry_pending_dir_restore_via(@(kOTAPlistDirPath));
        return;
    }
    OTADirRedirect redir = {0};
    if (!ota_begin_launchd_dir_redirect(&redir)) {
        printf("[OTA] pending folder restore: no access to the launchd folder yet\n");
        return;
    }
    (void)ota_retry_pending_dir_restore_via(redir.localDir);
    if (!ota_end_launchd_dir_redirect(&redir))
        printf("[OTA] !!! pending folder restore: redirect not undone\n");
}

static bool ota_write_disabled_plist(NSDictionary *plist, NSString *plistPath, NSString *tempPath, NSString *dirPath)
{
    // dirPath is the launchd folder or this write's active redirect of it.
    if (!ota_retry_pending_dir_restore_via(dirPath)) {
        printf("[OTA] refusing to write while an earlier folder restore is still pending\n");
        return false;
    }

    NSData *outData = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                 format:NSPropertyListXMLFormat_v1_0
                                                                options:0
                                                                  error:nil];
    if (!outData || outData.length == 0 || outData.length > kOTABufferSize) {
        printf("[OTA] plist serialization failed/too large len=%lu\n", (unsigned long)outData.length);
        return false;
    }

    struct stat dirStat = {0};
    if (stat(dirPath.UTF8String, &dirStat) != 0) {
        printf("[OTA] stat disabled.plist dir failed errno=%d\n", errno);
        return false;
    }

    struct stat fileStat = {0};
    bool existed = (stat(plistPath.UTF8String, &fileStat) == 0);
    mode_t finalMode = existed ? fileStat.st_mode : (S_IFREG | 0644);
    uid_t finalUid = existed ? fileStat.st_uid : 0;
    gid_t finalGid = existed ? fileStat.st_gid : 0;

    mode_t writableDirMode = dirStat.st_mode | S_IWOTH | S_IXOTH;
    bool dirModeChanged = (writableDirMode != dirStat.st_mode);
    if (dirModeChanged) {
        // Recorded before widening: a crash from here on is still undone.
        ota_set_dir_restore_record(true, dirStat.st_mode);
        (void)ota_vnode_chmod(dirPath.UTF8String, writableDirMode, "disabled.plist dir writable");
        if (!ota_dir_mode_is(dirPath.UTF8String, writableDirMode)) {
            // Failed -- possibly after applying part or all of it: put the
            // original back (and prove it) before giving up.
            printf("[OTA] widening the disabled.plist folder failed; restoring its mode\n");
            (void)ota_restore_dir_mode(dirPath.UTF8String, dirStat.st_mode, "disabled.plist dir restore");
            return false;
        }
    }

    bool ok = false;
    int fd = -1;
    do {
        unlink(tempPath.UTF8String);
        fd = open(tempPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) {
            printf("[OTA] open temp disabled.plist failed errno=%d\n", errno);
            break;
        }

        printf("[OTA] locally writing %lu bytes to temp disabled.plist\n",
               (unsigned long)outData.length);
        if (!ota_write_all(fd, outData.bytes, outData.length)) break;
        if (fsync(fd) != 0) {
            printf("[OTA] fsync temp disabled.plist failed errno=%d\n", errno);
            break;
        }
        if (close(fd) != 0) {
            printf("[OTA] close temp disabled.plist failed errno=%d\n", errno);
            fd = -1;
            break;
        }
        fd = -1;

        if (!ota_vnode_chown(tempPath.UTF8String, finalUid, finalGid, "temp disabled.plist")) break;
        if (!ota_vnode_chmod(tempPath.UTF8String, finalMode, "temp disabled.plist")) break;

        if (rename(tempPath.UTF8String, plistPath.UTF8String) != 0) {
            printf("[OTA] rename temp disabled.plist failed errno=%d\n", errno);
            break;
        }

        printf("[OTA] disabled.plist local rename ok bytes=%lu existed=%d\n",
               (unsigned long)outData.length, existed);
        ok = true;
    } while (0);

    if (fd >= 0) {
        close(fd);
    }
    if (!ok) {
        unlink(tempPath.UTF8String);
    }
    // A launchd dir left world-writable is a failure even if the rename landed.
    if (dirModeChanged &&
        !ota_restore_dir_mode(dirPath.UTF8String, dirStat.st_mode, "disabled.plist dir restore")) {
        ok = false;
    }
    return ok;
}

static NSMutableDictionary *ota_read_local_preference(NSString *path)
{
    // Only a missing file starts empty; one that exists but can't be read
    // is skipped (nil) so its other settings are never overwritten.
    if (access(path.fileSystemRepresentation, F_OK) != 0 && errno == ENOENT)
        return [NSMutableDictionary dictionary];
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!data) {
        NSString *errorDesc = readError ? readError.description : @"none";
        printf("[OTA] customer catalog pref exists but can't be read: %s error=%s\n",
               path.UTF8String, errorDesc.UTF8String);
        return nil;
    }
    if (data.length == 0) return [NSMutableDictionary dictionary];

    NSError *plistError = nil;
    NSMutableDictionary *plist = [[NSPropertyListSerialization
        propertyListWithData:data
                     options:NSPropertyListMutableContainersAndLeaves
                      format:nil
                       error:&plistError] mutableCopy];
    if (![plist isKindOfClass:NSMutableDictionary.class]) {
        NSString *errorDesc = plistError ? plistError.description : @"not a dictionary";
        printf("[OTA] customer catalog pref parse failed: %s error=%s\n",
               path.UTF8String, errorDesc.UTF8String);
        return nil;
    }
    return plist;
}

static bool ota_write_local_preference(NSString *path, NSDictionary *plist)
{
    NSData *outData = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                 format:NSPropertyListXMLFormat_v1_0
                                                                options:0
                                                                  error:nil];
    if (outData.length == 0) {
        printf("[OTA] customer catalog pref serialization failed: %s\n", path.UTF8String);
        return false;
    }

    BOOL ok = [outData writeToFile:path atomically:YES];
    if (ok) chmod(path.UTF8String, 0644);
    printf("[OTA] customer catalog pref write %s: %s bytes=%lu\n",
           ok ? "ok" : "failed", path.UTF8String, (unsigned long)outData.length);
    return ok;
}

static bool ota_ensure_customer_catalog_preferences(void)
{
    bool ok = true;
    bool changed = false;

    printf("[OTA] ensuring customer catalog preferences\n");
    for (NSString *path in ota_customer_catalog_preference_paths()) {
        NSMutableDictionary *plist = ota_read_local_preference(path);
        if (!plist) {
            ok = false;
            continue;
        }

        if ([plist[@"SUQueryCustomerBuilds"] isEqual:@YES]) continue;

        plist[@"SUQueryCustomerBuilds"] = @YES;
        if (!ota_write_local_preference(path, plist)) {
            ok = false;
        } else {
            changed = true;
        }
    }

    if (changed) {
        int notifyRet = notify_post("SUPreferencesChangedNotification");
        printf("[OTA] posted SUPreferencesChangedNotification ret=%d\n", notifyRet);
    }
    return ok;
}

static long ota_find_mobilegestalt_cachedata_offset(const char *mgKey)
{
    const char *mgName = "/usr/lib/libMobileGestalt.dylib";
    const struct mach_header_64 *header = NULL;

    dlopen(mgName, RTLD_LAZY | RTLD_GLOBAL);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (imageName && strncmp(mgName, imageName, strlen(mgName)) == 0) {
            header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            break;
        }
    }
    if (!header) {
        printf("[OTA][MG] libMobileGestalt image not loaded for key %s\n", mgKey);
        return -1;
    }

    unsigned long cstringSize = 0;
    const char *cstringSection = (const char *)getsectiondata(header, "__TEXT", "__cstring", &cstringSize);
    if (!cstringSection) {
        printf("[OTA][MG] no __TEXT,__cstring for key %s\n", mgKey);
        return -1;
    }

    const char *keyPtr = NULL;
    for (unsigned long off = 0; off < cstringSize; ) {
        const char *s = cstringSection + off;
        size_t len = strnlen(s, cstringSize - off);
        if (strcmp(s, mgKey) == 0) {
            keyPtr = s;
            break;
        }
        off += len + 1;
        if (len == 0 && off >= cstringSize) break;
    }
    if (!keyPtr) {
        printf("[OTA][MG] obfuscated key not found in libMobileGestalt: %s\n", mgKey);
        return -1;
    }

    unsigned long constSize = 0;
    const uintptr_t *constSection = (const uintptr_t *)getsectiondata(header, "__AUTH_CONST", "__const", &constSize);
    if (!constSection) {
        constSection = (const uintptr_t *)getsectiondata(header, "__DATA_CONST", "__const", &constSize);
    }
    if (!constSection) {
        printf("[OTA][MG] no const section for key %s\n", mgKey);
        return -1;
    }

    for (unsigned long i = 0; i < constSize / sizeof(uintptr_t); i++) {
        if (constSection[i] == (uintptr_t)keyPtr) {
            const uint16_t *entry = (const uint16_t *)&constSection[i];
            return ((long)entry[0x9a / 2]) << 3;
        }
    }

    printf("[OTA][MG] cachedata descriptor not found for key %s\n", mgKey);
    return -1;
}

// 1 = zeroed, 0 = already zero, -1 = slot couldn't be located.
static int ota_zero_mobilegestalt_cachedata_key(NSMutableData *cacheData, const char *key)
{
    long offset = ota_find_mobilegestalt_cachedata_offset(key);
    if (offset < 0) return -1;
    if ((NSUInteger)offset + sizeof(uint64_t) > cacheData.length) {
        printf("[OTA][MG] CacheData offset out of range key=%s offset=%ld len=%lu\n",
               key, offset, (unsigned long)cacheData.length);
        return -1;
    }

    uint64_t oldValue = 0;
    memcpy(&oldValue, (const uint8_t *)cacheData.bytes + offset, sizeof(oldValue));
    if (oldValue == 0) return 0;

    uint64_t zero = 0;
    memcpy((uint8_t *)cacheData.mutableBytes + offset, &zero, sizeof(zero));
    printf("[OTA][MG] zeroed CacheData key=%s offset=%ld old=0x%llx\n",
           key, offset, (unsigned long long)oldValue);
    return 1;
}

static bool ota_clear_internal_mobilegestalt_flags(void)
{
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:kOTAMobileGestaltPath options:0 error:&readError];
    if (data.length == 0) {
        NSString *errorDesc = readError ? readError.description : @"none";
        printf("[OTA][MG] unable to read %s error=%s\n",
               kOTAMobileGestaltPath.UTF8String, errorDesc.UTF8String);
        return false;
    }

    NSError *plistError = nil;
    NSMutableDictionary *mg = [[NSPropertyListSerialization
        propertyListWithData:data
                     options:NSPropertyListMutableContainersAndLeaves
                      format:nil
                       error:&plistError] mutableCopy];
    if (![mg isKindOfClass:NSMutableDictionary.class]) {
        NSString *errorDesc = plistError ? plistError.description : @"not a dictionary";
        printf("[OTA][MG] parse failed for %s error=%s\n",
               kOTAMobileGestaltPath.UTF8String, errorDesc.UTF8String);
        return false;
    }

    NSMutableDictionary *cacheExtra = mg[@"CacheExtra"];
    NSMutableData *cacheData = mg[@"CacheData"];
    if (![cacheExtra isKindOfClass:NSMutableDictionary.class] ||
        ![cacheData isKindOfClass:NSMutableData.class]) {
        printf("[OTA][MG] missing CacheExtra/CacheData dictionaries\n");
        return false;
    }

    bool changed = false;
    NSArray<NSString *> *internalKeys = @[
        @"LBJfwOEzExRxzlAnSuI7eg",
        @"EqrsVvjcYDdxHBiQmGhAWw",
        @"Oji6HRoPi7rH7HPdWVakuw",
    ];

    bool allCleared = true;
    for (NSString *key in internalKeys) {
        // CacheData first: only drop the CacheExtra copy once its CacheData
        // slot is known clear, so a failure never leaves a half-cleared key.
        int zeroed = ota_zero_mobilegestalt_cachedata_key(cacheData, key.UTF8String);
        if (zeroed > 0) changed = true;

        if (cacheExtra[key]) {
            if (zeroed < 0) {
                printf("[OTA][MG] keeping CacheExtra key=%s: CacheData slot not cleared\n",
                       key.UTF8String);
                allCleared = false;
                continue;
            }
            [cacheExtra removeObjectForKey:key];
            changed = true;
        }
    }

    if (!changed) {
        printf("[OTA][MG] internal flags %s\n",
               allCleared ? "already clear" : "not cleared");
        return allCleared;
    }

    NSError *writeError = nil;
    NSData *outData = [NSPropertyListSerialization dataWithPropertyList:mg
                                                                 format:NSPropertyListBinaryFormat_v1_0
                                                                options:0
                                                                  error:&writeError];
    if (outData.length == 0) {
        NSString *errorDesc = writeError ? writeError.description : @"none";
        printf("[OTA][MG] serialization failed error=%s\n", errorDesc.UTF8String);
        return false;
    }

    BOOL ok = [outData writeToFile:kOTAMobileGestaltPath atomically:YES];
    if (ok) chmod(kOTAMobileGestaltPath.UTF8String, 0644);
    printf("[OTA][MG] internal flag cleanup %s bytes=%lu%s\n",
           ok ? "ok" : "failed", (unsigned long)outData.length,
           allCleared ? "" : " (incomplete)");
    return ok && allCleared;
}

static bool ota_run_enable_cleanup(void)
{
    printf("[OTA] running enable cleanup for customer/internal catalog state\n");
    bool ok = ota_ensure_customer_catalog_preferences();
    ok = ota_clear_internal_mobilegestalt_flags() && ok;
    return ok;
}

// A successful enable may still fail its ancillary cleanup (customer catalog /
// MobileGestalt flags). The plist edit is the primary switch; do not report it
// as failed because the cleanup needs an access that is unavailable, but keep a
// record so the next OTA action retries it once /private/var is writable.
static NSString * const kOTACleanupPendingKey = @"OTACleanupPending";
static bool ota_prepare_local_root_rw(void);

static bool ota_enable_cleanup_best_effort(void)
{
    if (!ota_prepare_local_root_rw()) {
        printf("[OTA] cleanup: local /private/var rw unavailable; trying the "
               "preference writes anyway\n");
    }
    bool ok = ota_run_enable_cleanup();
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (ok) {
        if ([d boolForKey:kOTACleanupPendingKey]) [d removeObjectForKey:kOTACleanupPendingKey];
    } else {
        [d setBool:YES forKey:kOTACleanupPendingKey];
        log_user("[OTA] Update daemons are enabled, but OTA cleanup did not finish. "
                 "It will be retried on the next OTA change.\n");
    }
    [d synchronize];
    return ok;
}

static bool ota_prepare_local_root_rw(void)
{
    if (check_sandbox_var_rw() == 0) {
        printf("[OTA] app sandbox already allows /private/var read/write\n");
        return true;
    }

    if (krw_persistence_consume_launchd_root_file_token() &&
        check_sandbox_var_rw() == 0) {
        printf("[OTA] launchd root file token allows /private/var read/write\n");
        return true;
    }

    if (patch_sandbox_ext() == 0 && check_sandbox_var_rw() == 0) {
        printf("[OTA] sandbox root rw patch ok\n");
        return true;
    }
    printf("[OTA] sandbox root rw patch failed; trying extension donors\n");

    const char *donors[] = {
        "sysdiagnosed",
        "softwareupdateservicesd",
        "mobile_installation_proxy",
        "installd",
        "cfprefsd",
        NULL,
    };

    for (int i = 0; donors[i]; i++) {
        if (borrow_sandbox_ext(donors[i]) != 0) {
            continue;
        }
        if (check_sandbox_var_rw() == 0) {
            printf("[OTA] borrowed sandbox extensions from %s\n", donors[i]);
            return true;
        }
        printf("[OTA] borrowed %s extensions but /private/var rw is still denied\n",
               donors[i]);
    }

    return false;
}

bool darksword_prepare_var_rw(void)
{
    return ota_prepare_local_root_rw();
}

static int ota_apply_labels(NSMutableDictionary *plist, bool disabled)
{
    int changed = 0;
    for (NSString *label in ota_daemon_labels()) {
        if (disabled) {
            if (![plist[label] boolValue]) {
                plist[label] = @YES;
                changed++;
                printf("[OTA] disabling %s\n", label.UTF8String);
            } else {
                printf("[OTA] already disabled %s\n", label.UTF8String);
            }
        } else {
            if (plist[label]) {
                [plist removeObjectForKey:label];
                changed++;
                printf("[OTA] enabling %s\n", label.UTF8String);
            } else {
                printf("[OTA] already enabled %s\n", label.UTF8String);
            }
        }
    }
    return changed;
}

// *noRootAccess (optional) is set when /private/var rw couldn't be prepared,
// i.e. nothing was attempted and the redirect route is still worth trying.
static bool ota_set_local_with_launchd_krw(bool disabled, bool *noRootAccess)
{
    if (noRootAccess) *noRootAccess = false;
    printf("[OTA] live KRW active; %s OTA without launchd RemoteCall\n",
           disabled ? "disabling" : "enabling");

    if (!ota_prepare_local_root_rw()) {
        printf("[OTA] unable to get local /private/var rw access\n");
        if (noRootAccess) *noRootAccess = true;
        return false;
    }

    NSString *dirPath = @(kOTAPlistDirPath);
    NSString *plistPath = [dirPath stringByAppendingPathComponent:@(kOTAPlistFileName)];
    NSString *tempPath = [dirPath stringByAppendingPathComponent:@(kOTAPlistTempFileName)];
    NSMutableDictionary *plist = ota_read_disabled_plist_strict(plistPath);
    if (!plist) return false;   // never rewrite a plist we couldn't read

    int changed = ota_apply_labels(plist, disabled);

    if (changed == 0) {
        printf("[OTA] no plist changes needed\n");
        return true;
    }

    return ota_write_disabled_plist(plist, plistPath, tempPath, dirPath);
}

int darksword_ota_read_disabled(void)
{
    if (!kexploit_krw_ready()) {
        printf("[OTA] refusing status read: KRW is not active/recovered\n");
        return -1;
    }
    if (!ota_prepare_local_root_rw()) {
        printf("[OTA] status read: no /private/var read access\n");
        return -1;
    }

    // Strict: unreadable/corrupt is unknown (-1), never "enabled (stock)".
    NSMutableDictionary *plist = ota_read_disabled_plist_strict(@(kOTAOriginalPlistPath));
    if (!plist) {
        printf("[OTA] status read: disabled.plist unreadable/corrupt\n");
        return -1;
    }
    int total = 0, blocked = 0;
    for (NSString *label in ota_daemon_labels()) {
        total++;
        if ([plist[label] boolValue]) blocked++;
    }
    printf("[OTA] status read: %d/%d update daemons blocked\n", blocked, total);
    if (blocked == 0) return 0;
    if (blocked == total) return 1;
    return 2;
}

NSDictionary<NSString *, id> *launchd_disabled_read(void)
{
    if (!kexploit_krw_ready()) {
        printf("[DAEMONS] refusing read: KRW is not active/recovered\n");
        return nil;
    }
    if (!ota_prepare_local_root_rw()) {
        printf("[DAEMONS] read: no /private/var read access\n");
        return nil;
    }
    return ota_read_disabled_plist_strict(@(kOTAOriginalPlistPath));
}

// Same write paths as the OTA switch: a local edit when /private/var is
// writable, otherwise through the launchd directory redirect.
bool launchd_disabled_apply(NSDictionary<NSString *, NSNumber *> *changes)
{
    if (!kexploit_krw_ready()) {
        printf("[DAEMONS] refusing plist edit: KRW is not active/recovered\n");
        return false;
    }
    BOOL enablesOTA = NO;
    for (NSString *label in changes) {
        NSNumber *value = changes[label];
        if (![value isKindOfClass:NSNumber.class] ||
            !daemon_catalog_change_is_allowed(label, value.boolValue)) {
            printf("[DAEMONS] refusing plist edit: %s is not an allowed catalog change\n", label.description.UTF8String);
            return false;
        }
        if (!value.boolValue && [ota_daemon_labels() containsObject:label]) enablesOTA = YES;
    }
    int (^mutate)(NSMutableDictionary *) = ^int(NSMutableDictionary *plist) {
        int changed = 0;
        for (NSString *label in changes) {
            BOOL disable = changes[label].boolValue;
            if (disable && ![plist[label] boolValue]) {
                plist[label] = @YES;
                changed++;
                printf("[DAEMONS] disabling %s\n", label.UTF8String);
            } else if (!disable && plist[label]) {
                [plist removeObjectForKey:label];
                changed++;
                printf("[DAEMONS] enabling %s\n", label.UTF8String);
            }
        }
        return changed;
    };

    if (ota_prepare_local_root_rw()) {
        NSString *dirPath = @(kOTAPlistDirPath);
        NSString *plistPath = [dirPath stringByAppendingPathComponent:@(kOTAPlistFileName)];
        NSString *tempPath = [dirPath stringByAppendingPathComponent:@(kOTAPlistTempFileName)];
        NSMutableDictionary *plist = ota_read_disabled_plist_strict(plistPath);
        if (!plist) return false;
        if (mutate(plist) == 0) {
            if (enablesOTA) (void)ota_enable_cleanup_best_effort();
            return true;
        }
        bool ok = ota_write_disabled_plist(plist, plistPath, tempPath, dirPath);
        printf("[DAEMONS] local disabled.plist write result=%d\n", ok);
        if (ok && enablesOTA) (void)ota_enable_cleanup_best_effort();
        return ok;
    }

    OTADirRedirect redir = {0};
    if (!ota_begin_launchd_dir_redirect(&redir)) {
        printf("[DAEMONS] launchd plist dir redirect failed\n");
        return false;
    }
    NSString *plistPath = [redir.localDir stringByAppendingPathComponent:@(kOTAPlistFileName)];
    NSString *tempPath = [redir.localDir stringByAppendingPathComponent:@(kOTAPlistTempFileName)];
    NSMutableDictionary *plist = ota_read_disabled_plist_strict(plistPath);
    bool ok = plist && (mutate(plist) == 0 ||
                        ota_write_disabled_plist(plist, plistPath, tempPath, redir.localDir));
    if (!ota_end_launchd_dir_redirect(&redir)) ok = false;
    printf("[DAEMONS] redirected disabled.plist write result=%d\n", ok);
    if (ok && enablesOTA) (void)ota_enable_cleanup_best_effort();
    return ok;
}

bool darksword_ota_set_disabled(bool disabled)
{
    if (!kexploit_krw_ready()) {
        printf("[OTA] refusing plist edit: KRW is not active/recovered\n");
        log_user("[OTA] Failed: kernel recovery is not active. Run the chain first.\n");
        return false;
    }

    // A previous enable left its ancillary cleanup pending: retry now that
    // kernel access is available again. Failure keeps the record for later.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (!disabled && [defaults boolForKey:kOTACleanupPendingKey] && ota_prepare_local_root_rw()) {
        if (ota_run_enable_cleanup()) {
            [defaults removeObjectForKey:kOTACleanupPendingKey];
            [defaults synchronize];
            printf("[OTA] pending enable cleanup completed\n");
        }
    }

    if (disabled || !krw_persistence_launchd_holds_krw()) {
        // Live KRW: try direct /private/var access first for both directions.
        bool noRootAccess = false;
        bool plistOK = ota_set_local_with_launchd_krw(disabled, &noRootAccess);
        // Ancillary cleanup only once the primary plist edit is known good,
        // and never folded into its result: a cleanup failure must not claim
        // the daemons were not re-enabled (they were).
        if (!disabled && plistOK) {
            (void)ota_enable_cleanup_best_effort();
        }
        if (plistOK || !noRootAccess) {
            printf("[OTA] === %s OTA result=%d reboot/userspace restart required ===\n",
                   disabled ? "DISABLE" : "ENABLE", plistOK);
            return plistOK;
        }
        // Direct root access unavailable: fall back to the redirect route below.
        printf("[OTA] direct root access unavailable; trying launchd dir redirect\n");
    } else {
        bool plistOK = ota_set_local_with_launchd_krw(disabled, NULL);
        if (!disabled && plistOK) {
            (void)ota_enable_cleanup_best_effort();
        }
        printf("[OTA] === %s OTA result=%d reboot/userspace restart required ===\n",
               disabled ? "DISABLE" : "ENABLE", plistOK);
        return plistOK;
    }

    printf("[OTA] === %s OTA ===\n", disabled ? "DISABLING" : "ENABLING");

    OTADirRedirect redir = {0};
    if (!ota_begin_launchd_dir_redirect(&redir)) {
        printf("[OTA] launchd plist dir redirect failed\n");
        return false;
    }

    NSString *plistPath = [redir.localDir stringByAppendingPathComponent:@(kOTAPlistFileName)];
    NSString *tempPath = [redir.localDir stringByAppendingPathComponent:@(kOTAPlistTempFileName)];

    bool plistOK = false;

    do {
        NSMutableDictionary *plist = ota_read_disabled_plist_strict(plistPath);
        if (!plist) break;   // never rewrite a plist we couldn't read
        int changed = ota_apply_labels(plist, disabled);

        if (changed == 0) {
            printf("[OTA] no plist changes needed\n");
            plistOK = true;
            break;
        }

        plistOK = ota_write_disabled_plist(plist, plistPath, tempPath, redir.localDir);
    } while (0);

    if (!ota_end_launchd_dir_redirect(&redir)) {
        printf("[OTA] launchd plist dir redirect restore failed\n");
        plistOK = false;
    }

    // The redirect path exists precisely because /private/var was not writable
    // locally; the cleanup may still fail, but its result is now separate from
    // the plist edit (and is retried on the next OTA action).
    if (!disabled && plistOK) {
        (void)ota_enable_cleanup_best_effort();
    }

    printf("[OTA] === %s OTA result=%d reboot/userspace restart required ===\n",
           disabled ? "DISABLE" : "ENABLE", plistOK);
    return plistOK;
}
