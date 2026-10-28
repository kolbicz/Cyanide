//
//  supervision.m
//

#import "supervision.h"
#import "darksword_ota.h"
#import "../LogTextView.h"
#import "../kexploit/vnode.h"
#import <Foundation/Foundation.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString * const kSupDir =
    @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles";
static NSString * const kSupFileName = @"CloudConfigurationDetails.plist";
static NSString * const kSupTempName = @"CloudConfigurationDetails.plist.cyanide.tmp";
static NSString * const kSupIsSupervisedKey = @"IsSupervised";
static NSString * const kSupOrganizationKey = @"OrganizationName";

// The values Activate replaced (NSNull = key was absent), for Deactivate.
static NSString * const kSupOriginalDefaultsKey = @"SupervisionOriginalValues";
// Folder mode to put back if a write that widened it was interrupted.
static NSString * const kSupDirRestoreDefaultsKey = @"SupervisionDirModeRestore";

static NSString *sup_plist_path(void)
{
    return [kSupDir stringByAppendingPathComponent:kSupFileName];
}

static bool sup_mode_is(const char *path, mode_t mode)
{
    struct stat st = {0};
    return stat(path, &st) == 0 && (st.st_mode & 07777) == (mode & 07777);
}

static bool sup_restore_dir_mode(mode_t mode)
{
    const char *dir = kSupDir.fileSystemRepresentation;
    (void)vnode_apfs_chmod(dir, mode);
    if (!sup_mode_is(dir, mode)) {
        printf("[SUPERVISION] restoring folder mode %o failed; retried next time\n", mode & 07777);
        return false;
    }
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kSupDirRestoreDefaultsKey];
    return true;
}

static bool sup_retry_pending_dir_restore(void)
{
    NSNumber *pending = [NSUserDefaults.standardUserDefaults objectForKey:kSupDirRestoreDefaultsKey];
    if (![pending isKindOfClass:NSNumber.class]) return true;
    printf("[SUPERVISION] restoring folder mode left by an interrupted write\n");
    return sup_restore_dir_mode((mode_t)pending.unsignedIntValue);
}

// nil = exists but can't be read (never overwritten then); a missing file
// starts empty. *format gets the file's own plist format.
static NSMutableDictionary *sup_read_plist(NSPropertyListFormat *format)
{
    *format = NSPropertyListBinaryFormat_v1_0;
    NSString *path = sup_plist_path();
    if (access(path.fileSystemRepresentation, F_OK) != 0) {
        if (errno == ENOENT && access(kSupDir.fileSystemRepresentation, R_OK | X_OK) == 0) {
            printf("[SUPERVISION] %s missing; starting empty\n", kSupFileName.UTF8String);
            return [NSMutableDictionary dictionary];
        }
        printf("[SUPERVISION] cannot access %s errno=%d\n", path.UTF8String, errno);
        return nil;
    }
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
    if (!data) {
        printf("[SUPERVISION] read failed: %s\n", error.description.UTF8String);
        return nil;
    }
    if (data.length == 0) return [NSMutableDictionary dictionary];
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListMutableContainersAndLeaves
                                                          format:format
                                                           error:&error];
    if (![plist isKindOfClass:NSMutableDictionary.class]) {
        printf("[SUPERVISION] parse failed: %s\n", error ? error.description.UTF8String : "not a dictionary");
        return nil;
    }
    return plist;
}

static bool sup_write_all(int fd, NSData *data)
{
    const uint8_t *bytes = data.bytes;
    NSUInteger total = 0;
    while (total < data.length) {
        ssize_t n = write(fd, bytes + total, data.length - total);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        total += (NSUInteger)n;
    }
    return true;
}

// Temp file + rename, with the original owner and mode. The folder is
// widened only if this app can't write it, and narrowed again afterwards
// (recorded first, so an interrupted write is undone next time).
static bool sup_write_plist(NSDictionary *plist, NSPropertyListFormat format)
{
    if (!sup_retry_pending_dir_restore()) return false;

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:format options:0 error:nil];
    if (data.length == 0) {
        printf("[SUPERVISION] serialization failed\n");
        return false;
    }

    const char *dir = kSupDir.fileSystemRepresentation;
    NSString *path = sup_plist_path();
    NSString *temp = [kSupDir stringByAppendingPathComponent:kSupTempName];

    struct stat dirStat = {0};
    if (stat(dir, &dirStat) != 0) {
        printf("[SUPERVISION] stat folder failed errno=%d\n", errno);
        return false;
    }
    struct stat fileStat = {0};
    bool existed = stat(path.fileSystemRepresentation, &fileStat) == 0;
    mode_t finalMode = existed ? (fileStat.st_mode & 07777) : 0644;
    uid_t finalUid = existed ? fileStat.st_uid : dirStat.st_uid;
    gid_t finalGid = existed ? fileStat.st_gid : dirStat.st_gid;
    printf("[SUPERVISION] folder uid=%u gid=%u mode=%o; file existed=%d uid=%u gid=%u mode=%o\n",
           dirStat.st_uid, dirStat.st_gid, dirStat.st_mode & 07777,
           existed, finalUid, finalGid, finalMode);

    bool widened = false;
    if (access(dir, W_OK | X_OK) != 0) {
        mode_t writable = (dirStat.st_mode | S_IWOTH | S_IXOTH) & 07777;
        [NSUserDefaults.standardUserDefaults setObject:@(dirStat.st_mode & 07777) forKey:kSupDirRestoreDefaultsKey];
        (void)vnode_apfs_chmod(dir, writable);
        if (!sup_mode_is(dir, writable)) {
            printf("[SUPERVISION] widening the folder failed\n");
            (void)sup_restore_dir_mode(dirStat.st_mode);
            return false;
        }
        widened = true;
    }

    bool ok = false;
    int fd = -1;
    do {
        unlink(temp.fileSystemRepresentation);
        fd = open(temp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) { printf("[SUPERVISION] open temp failed errno=%d\n", errno); break; }
        if (!sup_write_all(fd, data)) { printf("[SUPERVISION] write failed errno=%d\n", errno); break; }
        if (fsync(fd) != 0) { printf("[SUPERVISION] fsync failed errno=%d\n", errno); break; }
        int closeRC = close(fd);
        fd = -1;
        if (closeRC != 0) { printf("[SUPERVISION] close failed errno=%d\n", errno); break; }
        struct stat tempStat = {0};
        if (stat(temp.fileSystemRepresentation, &tempStat) != 0) break;
        if ((tempStat.st_uid != finalUid || tempStat.st_gid != finalGid) &&
            vnode_apfs_chown(temp.fileSystemRepresentation, finalUid, finalGid) != 0) {
            printf("[SUPERVISION] chown temp failed\n");
            break;
        }
        if (vnode_apfs_chmod(temp.fileSystemRepresentation, finalMode) != 0 &&
            !sup_mode_is(temp.fileSystemRepresentation, finalMode)) {
            printf("[SUPERVISION] chmod temp failed\n");
            break;
        }
        if (rename(temp.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
            printf("[SUPERVISION] rename failed errno=%d\n", errno);
            break;
        }
        printf("[SUPERVISION] wrote %s (%lu bytes)\n", kSupFileName.UTF8String, (unsigned long)data.length);
        ok = true;
    } while (0);

    if (fd >= 0) close(fd);
    if (!ok) unlink(temp.fileSystemRepresentation);
    // A folder left world-writable is a failure even if the rename landed.
    if (widened && !sup_restore_dir_mode(dirStat.st_mode)) ok = false;
    return ok;
}

static SupervisionState sup_state_of(NSDictionary *plist)
{
    if (![plist[kSupIsSupervisedKey] boolValue]) return SupervisionStateOff;
    NSString *org = plist[kSupOrganizationKey];
    return [org isEqual:@SUPERVISION_ORGANIZATION_NAME] ? SupervisionStateCyanide : SupervisionStateOther;
}

SupervisionState supervision_read_state(void)
{
    if (!darksword_prepare_var_rw()) {
        printf("[SUPERVISION] no /private/var access\n");
        return SupervisionStateUnknown;
    }
    NSPropertyListFormat format;
    NSMutableDictionary *plist = sup_read_plist(&format);
    if (!plist) return SupervisionStateUnknown;
    NSString *org = plist[kSupOrganizationKey];
    printf("[SUPERVISION] IsSupervised=%d OrganizationName=%s\n",
           [plist[kSupIsSupervisedKey] boolValue],
           [org isKindOfClass:NSString.class] ? org.UTF8String : "(none)");
    return sup_state_of(plist);
}

static void sup_put(NSMutableDictionary *plist, NSString *key, id value)
{
    if (!value || value == NSNull.null) [plist removeObjectForKey:key];
    else plist[key] = value;
}

bool supervision_set(bool supervised)
{
    if (!darksword_prepare_var_rw()) {
        log_user("[SUPERVISION] No /private/var access (sandbox could not be lifted).\n");
        return false;
    }
    NSPropertyListFormat format;
    NSMutableDictionary *plist = sup_read_plist(&format);
    if (!plist) {
        log_user("[SUPERVISION] %s could not be read; nothing changed.\n", kSupFileName.UTF8String);
        return false;
    }

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    SupervisionState state = sup_state_of(plist);
    NSDictionary *original = [d dictionaryForKey:kSupOriginalDefaultsKey];

    if (supervised) {
        if (state == SupervisionStateOther) {
            log_user("[SUPERVISION] Already supervised by \"%s\"; left as it is.\n",
                     [plist[kSupOrganizationKey] description].UTF8String ?: "?");
            return true;
        }
        if (state == SupervisionStateCyanide) {
            log_user("[SUPERVISION] Already supervised by Cyanide.\n");
            return true;
        }
        if (!original) {
            [d setObject:@{ kSupIsSupervisedKey: plist[kSupIsSupervisedKey] ?: NSNull.null,
                            kSupOrganizationKey: plist[kSupOrganizationKey] ?: NSNull.null }
                  forKey:kSupOriginalDefaultsKey];
        }
        plist[kSupIsSupervisedKey] = @YES;
        plist[kSupOrganizationKey] = @SUPERVISION_ORGANIZATION_NAME;
    } else {
        if (state == SupervisionStateOff) {
            log_user("[SUPERVISION] Not supervised; nothing to change.\n");
            [d removeObjectForKey:kSupOriginalDefaultsKey];
            return true;
        }
        if (state == SupervisionStateOther) {
            log_user("[SUPERVISION] Supervised by \"%s\", not by Cyanide; left as it is.\n",
                     [plist[kSupOrganizationKey] description].UTF8String ?: "?");
            return false;
        }
        if (original) {
            sup_put(plist, kSupIsSupervisedKey, original[kSupIsSupervisedKey]);
            sup_put(plist, kSupOrganizationKey, original[kSupOrganizationKey]);
        } else {
            [plist removeObjectForKey:kSupIsSupervisedKey];
            [plist removeObjectForKey:kSupOrganizationKey];
        }
    }

    if (!sup_write_plist(plist, format)) {
        log_user("[SUPERVISION] Writing %s failed; see the [SUPERVISION] lines.\n", kSupFileName.UTF8String);
        return false;
    }
    if (!supervised) [d removeObjectForKey:kSupOriginalDefaultsKey];
    return true;
}
