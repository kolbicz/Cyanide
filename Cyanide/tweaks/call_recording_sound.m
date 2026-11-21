//
//  call_recording_sound.m
//  Cyanide
//

#import "call_recording_sound.h"
#import "../LogTextView.h"
#import "../kexploit/kexploit_opa334.h"
#import "../kexploit/persistence.h"
#import "../kexploit/vnode.h"
#import "../utils/sandbox.h"

#import <Foundation/Foundation.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString * const kCRTargetDir =
    @"/var/mobile/Library/CallServices/Greetings/default";
static NSString * const kCRBackupDirName = @"CallRecordingSoundBackups";

typedef struct {
    __unsafe_unretained NSString *fileName;
    __unsafe_unretained NSString *resourceBase;
    __unsafe_unretained NSString *resourceExt;
} CRSoundPayload;

static const CRSoundPayload kCRPayloads[] = {
    { @"StartDisclosureWithTone.m4a", @"StartDisclosureWithTone", @"m4a" },
    { @"StopDisclosure.caf",          @"StopDisclosure",          @"caf" },
};

static bool cr_write_all(int fd, const uint8_t *bytes, NSUInteger length)
{
    NSUInteger total = 0;
    while (total < length) {
        ssize_t written = write(fd, bytes + total, length - total);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            printf("[CALLREC] write failed at %lu/%lu errno=%d\n",
                   (unsigned long)total, (unsigned long)length, errno);
            return false;
        }
        total += (NSUInteger)written;
    }
    return true;
}

static bool cr_prepare_sandbox(void)
{
    if (check_sandbox_var_rw() == 0) {
        printf("[CALLREC] app sandbox already allows /private/var read/write\n");
        return true;
    }

    if (krw_persistence_consume_launchd_root_file_token() &&
        check_sandbox_var_rw() == 0) {
        printf("[CALLREC] sandbox ok via launchd root file token\n");
        return true;
    }

    if (patch_sandbox_ext() == 0 && check_sandbox_var_rw() == 0) {
        printf("[CALLREC] sandbox ok via patch_sandbox_ext\n");
        return true;
    }

    static const char *donors[] = {
        "cfprefsd",
        "callservicesd",
        "mobilephone",
        "sysdiagnosed",
        "mobile_installation_proxy",
        "installd",
        NULL,
    };

    for (int i = 0; donors[i]; i++) {
        if (borrow_sandbox_ext(donors[i]) == 0 && check_sandbox_var_rw() == 0) {
            printf("[CALLREC] sandbox ok via borrow_sandbox_ext(%s)\n", donors[i]);
            return true;
        }
    }

    printf("[CALLREC] could not unlock /private/var rw access\n");
    log_user("[CALLREC] Failed: /private/var read/write sandbox access is still denied.\n");
    return false;
}

static NSString *cr_backup_dir(void)
{
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                                    NSUserDomainMask,
                                                                    YES);
    NSString *root = dirs.firstObject ?: NSHomeDirectory();
    return [root stringByAppendingPathComponent:kCRBackupDirName];
}

static NSString *cr_backup_path(NSString *fileName)
{
    return [cr_backup_dir() stringByAppendingPathComponent:
            [fileName stringByAppendingString:@".orig"]];
}

static NSString *cr_target_path(NSString *fileName)
{
    return [kCRTargetDir stringByAppendingPathComponent:fileName];
}

static NSData *cr_payload_data(const CRSoundPayload *payload)
{
    NSString *path = [[NSBundle mainBundle] pathForResource:payload->resourceBase
                                                     ofType:payload->resourceExt];
    if (!path.length) {
        path = [[NSBundle mainBundle] pathForResource:payload->resourceBase
                                               ofType:payload->resourceExt
                                          inDirectory:@"tweaks"];
    }
    if (!path.length) {
        log_user("[CALLREC] Missing bundled payload: %s.%s\n",
                 payload->resourceBase.UTF8String,
                 payload->resourceExt.UTF8String);
        return nil;
    }

    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
    if (data.length == 0) {
        log_user("[CALLREC] Could not read bundled payload %s: %s\n",
                 path.UTF8String,
                 error.localizedDescription.UTF8String ?: "empty file");
        return nil;
    }
    return data;
}

static bool cr_ensure_backup_dir(void)
{
    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:cr_backup_dir()
                                        withIntermediateDirectories:YES
                                                         attributes:nil
                                                              error:&error];
    if (!ok) {
        log_user("[CALLREC] Could not create backup dir: %s\n",
                 error.localizedDescription.UTF8String ?: "unknown");
        return false;
    }
    return true;
}

static bool cr_backup_original_if_needed(NSString *targetPath, NSString *fileName, NSData *silentPayload)
{
    if (!cr_ensure_backup_dir()) return false;

    NSString *backupPath = cr_backup_path(fileName);
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:backupPath]) {
        printf("[CALLREC] backup already exists for %s\n", fileName.UTF8String);
        return true;
    }

    if (![fm fileExistsAtPath:targetPath]) {
        log_user("[CALLREC] No existing %s to back up; install will create it.\n",
                 fileName.UTF8String);
        return true;
    }

    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:targetPath options:0 error:&error];
    if (data.length == 0) {
        log_user("[CALLREC] Could not read original %s for backup: %s\n",
                 fileName.UTF8String,
                 error.localizedDescription.UTF8String ?: "empty file");
        return false;
    }

    // The backup lives in the app's own folder and is gone after a reinstall,
    // while the silenced file stays. Backing that up as "the original" made a
    // later Restore write the silent file back and report success. If the
    // target already is Cyanide's silent payload there is no original here to
    // save: leave no backup, so Restore says so instead.
    if (silentPayload.length > 0 && [data isEqualToData:silentPayload]) {
        log_user("[CALLREC] %s is already the silent file and its original backup is gone; "
                 "Restore cannot bring the original back.\n", fileName.UTF8String);
        return true;
    }

    if (![data writeToFile:backupPath options:NSDataWritingAtomic error:&error]) {
        log_user("[CALLREC] Could not write backup for %s: %s\n",
                 fileName.UTF8String,
                 error.localizedDescription.UTF8String ?: "unknown");
        return false;
    }
    chmod(backupPath.UTF8String, 0600);
    log_user("[CALLREC] Backed up original %s (%lu bytes).\n",
             fileName.UTF8String, (unsigned long)data.length);
    return true;
}

static bool cr_vnode_chmod(const char *path, mode_t mode, const char *label)
{
    int ret = vnode_apfs_chmod(path, mode);
    if (ret != 0) {
        printf("[CALLREC] vnode chmod failed for %s path=%s mode=%o ret=%d\n",
               label, path, mode, ret);
        return false;
    }
    return true;
}

static bool cr_vnode_chown(const char *path, uid_t uid, gid_t gid, const char *label)
{
    int ret = vnode_apfs_chown(path, uid, gid);
    if (ret != 0) {
        printf("[CALLREC] vnode chown failed for %s path=%s uid=%u gid=%u ret=%d\n",
               label, path, uid, gid, ret);
        return false;
    }
    return true;
}

static bool cr_write_data_to_target(NSData *data, NSString *targetPath)
{
    if (data.length == 0) return false;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *mkdirError = nil;
    if (![fm createDirectoryAtPath:kCRTargetDir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&mkdirError]) {
        log_user("[CALLREC] Could not create target dir: %s\n",
                 mkdirError.localizedDescription.UTF8String ?: "unknown");
        return false;
    }

    struct stat dirStat = {0};
    if (stat(kCRTargetDir.UTF8String, &dirStat) != 0) {
        log_user("[CALLREC] stat target dir failed errno=%d.\n", errno);
        return false;
    }

    struct stat fileStat = {0};
    bool existed = (stat(targetPath.UTF8String, &fileStat) == 0);
    mode_t finalMode = existed ? (fileStat.st_mode & 07777) : 0644;
    uid_t finalUid = existed ? fileStat.st_uid : dirStat.st_uid;
    gid_t finalGid = existed ? fileStat.st_gid : dirStat.st_gid;

    mode_t writableDirMode = dirStat.st_mode | S_IWUSR | S_IXUSR;
    bool dirModeChanged = ((writableDirMode & 07777) != (dirStat.st_mode & 07777));
    if (dirModeChanged &&
        !cr_vnode_chmod(kCRTargetDir.UTF8String, writableDirMode, "CallServices dir writable")) {
        return false;
    }

    NSString *tmpName = [NSString stringWithFormat:@".%@.cyanide.tmp",
                         targetPath.lastPathComponent];
    NSString *tmpPath = [kCRTargetDir stringByAppendingPathComponent:tmpName];

    bool ok = false;
    int fd = -1;
    do {
        unlink(tmpPath.UTF8String);
        fd = open(tmpPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) {
            log_user("[CALLREC] open temp failed for %s errno=%d.\n",
                     targetPath.lastPathComponent.UTF8String, errno);
            break;
        }

        if (!cr_write_all(fd, data.bytes, data.length)) break;
        if (fsync(fd) != 0) {
            printf("[CALLREC] fsync temp failed errno=%d\n", errno);
            break;
        }
        if (close(fd) != 0) {
            printf("[CALLREC] close temp failed errno=%d\n", errno);
            fd = -1;
            break;
        }
        fd = -1;

        if (!cr_vnode_chown(tmpPath.UTF8String, finalUid, finalGid, "payload temp")) break;
        if (!cr_vnode_chmod(tmpPath.UTF8String, S_IFREG | finalMode, "payload temp")) break;

        if (rename(tmpPath.UTF8String, targetPath.UTF8String) != 0) {
            log_user("[CALLREC] rename into place failed for %s errno=%d.\n",
                     targetPath.lastPathComponent.UTF8String, errno);
            break;
        }

        printf("[CALLREC] wrote %lu bytes to %s existed=%d uid=%u gid=%u mode=%o\n",
               (unsigned long)data.length,
               targetPath.UTF8String,
               existed,
               finalUid,
               finalGid,
               finalMode);
        ok = true;
    } while (0);

    if (fd >= 0) close(fd);
    if (!ok) unlink(tmpPath.UTF8String);
    if (dirModeChanged) {
        cr_vnode_chmod(kCRTargetDir.UTF8String, dirStat.st_mode, "CallServices dir restore");
    }
    return ok;
}

static bool cr_disable_payloads(void)
{
    bool ok = true;
    size_t count = sizeof(kCRPayloads) / sizeof(kCRPayloads[0]);
    for (size_t i = 0; i < count; i++) {
        const CRSoundPayload *payload = &kCRPayloads[i];
        NSString *targetPath = cr_target_path(payload->fileName);
        NSData *data = cr_payload_data(payload);
        if (data.length == 0) {
            ok = false;
            continue;
        }
        if (!cr_backup_original_if_needed(targetPath, payload->fileName, data)) {
            ok = false;
            continue;
        }
        if (!cr_write_data_to_target(data, targetPath)) {
            ok = false;
            continue;
        }
        log_user("[CALLREC] Silenced %s (%lu bytes).\n",
                 payload->fileName.UTF8String, (unsigned long)data.length);
    }
    return ok;
}

static bool cr_restore_payloads(void)
{
    bool ok = true;
    size_t count = sizeof(kCRPayloads) / sizeof(kCRPayloads[0]);
    for (size_t i = 0; i < count; i++) {
        const CRSoundPayload *payload = &kCRPayloads[i];
        NSString *backupPath = cr_backup_path(payload->fileName);
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:backupPath options:0 error:&error];
        if (data.length == 0) {
            log_user("[CALLREC] No usable backup for %s; leaving current file unchanged.\n",
                     payload->fileName.UTF8String);
            ok = false;
            continue;
        }
        if (!cr_write_data_to_target(data, cr_target_path(payload->fileName))) {
            ok = false;
            continue;
        }
        log_user("[CALLREC] Restored original %s (%lu bytes).\n",
                 payload->fileName.UTF8String, (unsigned long)data.length);
    }
    return ok;
}

bool call_recording_sound_set_disabled(bool disabled)
{
    if (!kexploit_krw_ready()) {
        printf("[CALLREC] refusing file edit: KRW is not active/recovered\n");
        log_user("[CALLREC] Failed: kernel recovery is not active. Run the chain first.\n");
        return false;
    }

    if (!cr_prepare_sandbox()) return false;

    if (disabled) {
        log_user("[CALLREC] WARNING: this modifies CallServices system files under /var/mobile/Library/CallServices/Greetings/default.\n");
        log_user("[CALLREC] Legal note: disclosure sounds may be required by consent, notification, or privacy laws where you live. You are responsible for your use.\n");
    }
    log_user("[CALLREC] %s call-recording disclosure sounds.\n",
             disabled ? "Silencing" : "Restoring");
    bool ok = disabled ? cr_disable_payloads() : cr_restore_payloads();
    log_user("%s Call recording disclosure sound %s.\n",
             ok ? "[OK]" : "[WARN]",
             disabled ? (ok ? "silenced" : "silence incomplete")
                      : (ok ? "restored" : "restore incomplete"));
    return ok;
}
