//
//  FileBrowserViewController.m
//  Cyanide
//

#import "FileBrowserViewController.h"
#import "SettingsViewController.h"
#import "PlistEditorViewController.h"
#import "FBAppContainers.h"
#import "installer/MainTabBarController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#import <fcntl.h>
#import <dirent.h>
#import <grp.h>
#import <pwd.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <sys/clonefile.h>
#import <stdatomic.h>

// The pending-changes popup bar is hosted by the tab bar controller above
// pushed content; hide it while a browser screen is on top (as the Process
// Viewer does). Each screen re-asserts it on appear, so pushes between browser
// screens keep it hidden.
static void fb_suppress_popup_bar(UIViewController *vc, BOOL suppressed)
{
    UITabBarController *tbc = vc.tabBarController;
    if ([tbc isKindOfClass:MainTabBarController.class])
        [(MainTabBarController *)tbc setPopupBarSuppressed:suppressed];
}

// Write mode: off by default and for this app launch only (never persisted),
// so a later session can't delete anything by accident. Changes are made as
// user mobile, so Unix permissions still apply.
static _Atomic(bool) g_fb_write_enabled = false;

BOOL filebrowser_write_enabled(void)
{
    return atomic_load_explicit(&g_fb_write_enabled, memory_order_acquire);
}

// Bumped whenever a listing option changes, so folders further down the
// navigation stack reload when they reappear.
static NSUInteger g_fb_options_generation = 0;
// Bumped after every accepted change (save, import, rename, delete, …), so
// folders further down the stack refresh their size/date when they reappear.
static NSUInteger g_fb_fs_generation = 0;
// Main-thread state: workers hop over.
void filebrowser_note_filesystem_changed(void)
{
    if (NSThread.isMainThread) g_fb_fs_generation++;
    else dispatch_async(dispatch_get_main_queue(), ^{ g_fb_fs_generation++; });
}

// Plists open in the structured editor: by extension, or by the binary
// plist magic for extensionless files.
// Opens `path` for reading only if it is (or links to) a regular file.
// A path that isn't one is rejected by stat BEFORE opening (opening a device
// node can itself have side effects); O_NONBLOCK keeps a FIFO swapped in
// meanwhile from blocking the open, and fstat then checks the object
// actually opened.  The pre-stat/fstat identity comparison rejects a pathname
// swap to a different regular object.  This is still not an atomic
// open-if-regular operation: without a trusted parent descriptor and a
// no-follow/openat-style primitive, an external writer can race the pathname
// lookup.  Callers must keep treating the result as a best-effort read guard.
static int fb_open_regular_classified(NSString *path, int *errorOut, BOOL *notRegularOut)
{
    if (errorOut) *errorOut = 0;
    if (notRegularOut) *notRegularOut = NO;
    const char *fsPath = path.fileSystemRepresentation;
    if (!fsPath || !path.length) {
        if (errorOut) *errorOut = EINVAL;
        return -1;
    }
    struct stat pre;
    if (stat(fsPath, &pre) != 0) {
        if (errorOut) *errorOut = errno;
        return -1;
    }
    if (!S_ISREG(pre.st_mode)) {
        if (notRegularOut) *notRegularOut = YES;
        return -1;
    }
    int fd = open(fsPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        if (errorOut) *errorOut = errno;
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int saved = errno;
        close(fd);
        if (errorOut) *errorOut = saved;
        return -1;
    }
    if (!S_ISREG(st.st_mode)) {
        if (notRegularOut) *notRegularOut = YES;
        close(fd);
        return -1;
    }
    if (st.st_dev != pre.st_dev || st.st_ino != pre.st_ino ||
        (st.st_mode & S_IFMT) != (pre.st_mode & S_IFMT)) {
        close(fd);
        if (errorOut) *errorOut = EAGAIN;
        return -1;
    }
    // Regular file: back to blocking reads.  If this fails, do not return a
    // descriptor that could retain nonblocking FIFO semantics after a race.
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) < 0) {
        int saved = errno;
        close(fd);
        if (errorOut) *errorOut = saved;
        return -1;
    }
    return fd;
}

int filebrowser_open_regular(NSString *path)
{
    return fb_open_regular_classified(path, NULL, NULL);
}

// Reads `fd` from the start to EOF, at most maxBytes. EINTR is retried; any
// read error returns nil (errno in *errOut) — an errored read is never
// passed off as complete contents. *truncated: more than maxBytes exist.
NSData *filebrowser_read_fd(int fd, NSUInteger maxBytes, BOOL *truncated, int *errOut)
{
    if (truncated) *truncated = NO;
    if (errOut) *errOut = 0;
    NSMutableData *data = [NSMutableData dataWithLength:maxBytes + 1];
    size_t got = 0;
    while (got < data.length) {
        ssize_t n = pread(fd, (uint8_t *)data.mutableBytes + got, data.length - got, (off_t)got);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errOut) *errOut = errno;
            return nil;
        }
        if (n == 0) break;
        got += (size_t)n;
    }
    if (got > maxBytes) {
        if (truncated) *truncated = YES;
        got = maxBytes;
    }
    data.length = got;
    return data;
}

// Plists open in the structured editor: by extension, or by the binary
// plist magic for extensionless files. Regular files only.
static BOOL fb_looks_like_plist(NSString *path)
{
    int fd = filebrowser_open_regular(path);
    if (fd < 0) return NO;
    NSString *ext = path.pathExtension.lowercaseString;
    BOOL yes = [ext isEqualToString:@"plist"] || [ext isEqualToString:@"strings"];
    if (!yes) {
        char magic[8] = {0};
        yes = pread(fd, magic, sizeof(magic), 0) == (ssize_t)sizeof(magic) && memcmp(magic, "bplist00", 8) == 0;
    }
    close(fd);
    return yes;
}

FBFileIdentity filebrowser_identity_fd(int fd)
{
    FBFileIdentity ident = {0};
    struct stat st;
    if (fd >= 0 && fstat(fd, &st) == 0) {
        ident.valid = YES;
        ident.dev = st.st_dev;
        ident.ino = st.st_ino;
        ident.size = st.st_size;
        ident.mtime = st.st_mtimespec;
    }
    return ident;
}

static BOOL fb_same_object(FBFileIdentity a, FBFileIdentity b)
{
    return a.valid && b.valid && a.dev == b.dev && a.ino == b.ino;
}

static FBFileIdentity fb_identity_path(NSString *path)
{
    FBFileIdentity ident = {0};
    struct stat st;
    // Save validation follows the path like open() does. Destructive entry
    // validation separately uses lstat so a symlink itself remains the object
    // being protected there; save validation must compare the opened target,
    // otherwise every editable symlink would fail its own pre-commit check.
    if (stat(path.fileSystemRepresentation, &st) == 0) {
        ident.valid = YES;
        ident.dev = st.st_dev;
        ident.ino = st.st_ino;
        ident.size = st.st_size;
        ident.mtime = st.st_mtimespec;
    }
    return ident;
}

static BOOL fb_pwrite_all(int fd, NSData *data)
{
    const uint8_t *p = data.bytes;
    size_t done = 0;
    while (done < data.length) {
        ssize_t n = pwrite(fd, p + done, data.length - done, (off_t)done);
        if (n < 0) { if (errno == EINTR) continue; return NO; }
        if (n == 0) return NO;
        done += (size_t)n;
    }
    return ftruncate(fd, (off_t)data.length) == 0 && fsync(fd) == 0;
}

// Saves `data` over the file that was opened as `expected` with contents
// `loaded`. The whole transaction runs on ONE descriptor, so the object that
// was checked is the object written (no path re-resolution between check and
// write; inode, owner and mode are kept).
//  - Without `force`: a different object at the path, or contents that differ
//    from `loaded` (even with size and mtime unchanged), is a conflict.
//  - With `force`: the CURRENT contents — not the stale loaded version — are
//    what gets backed up and restored.
//  - Before writing, the current contents are copied to Cyanide's temp
//    folder. A failed write is undone from them; if that fails too, the
//    message names the surviving backup.
static const NSUInteger kFBMaxBackupBytes = 64 * 1024 * 1024;
static NSString *fb_backup_dir(void);
static BOOL fb_fsync_directory(NSString *path);
static BOOL fb_write_durable_file(NSString *path, NSData *data, mode_t mode);

FBSaveResult filebrowser_save(NSString *path, NSData *data, FBFileIdentity expected, NSData *loaded,
                              BOOL force, FBFileIdentity *newIdentity, NSString **message)
{
    NSString *msg = nil;
    FBSaveResult result = FBSaveFailed;
    // Checked again here, at execution time: a save can wait in the file
    // queue behind other work while Changes get locked.
    if (!filebrowser_write_enabled()) {
        if (message) *message = @"Changes are locked. Unlock them in the File Browser first.";
        return FBSaveFailed;
    }
    if (data.length > kFBMaxBackupBytes) {
        if (message) *message = @"The new file is too large for a durable recovery preimage.";
        return FBSaveFailed;
    }
    // Classify BEFORE opening (opening a device node can itself have side
    // effects), like fb_open_regular_classified.  Symlinks are followed on
    // purpose: editing a file through a symlink is supported (see
    // fb_identity_path), so no O_NOFOLLOW.  O_NONBLOCK keeps a FIFO swapped
    // in meanwhile from blocking the open; fstat then checks the object
    // actually opened against the pre-stat identity.
    const char *fsPath = path.fileSystemRepresentation;
    struct stat pre;
    if (!fsPath || stat(fsPath, &pre) != 0) {
        int serr = fsPath ? errno : EINVAL;
        if (message) *message = [NSString stringWithFormat:@"The file can't be opened for writing: %s.", strerror(serr)];
        return FBSaveFailed;
    }
    if (!S_ISREG(pre.st_mode)) {
        if (message) *message = @"Not a regular file.";
        return FBSaveFailed;
    }
    int fd = open(fsPath, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        if (message) *message = [NSString stringWithFormat:@"The file can't be opened for writing: %s.", strerror(errno)];
        return FBSaveFailed;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        if (message) *message = @"Not a regular file.";
        return FBSaveFailed;
    }
    if (st.st_dev != pre.st_dev || st.st_ino != pre.st_ino) {
        close(fd);
        if (message) *message = @"The file was replaced while it was being opened. Nothing was changed; reload and try again.";
        return FBSaveFailed;
    }
    int oflags = fcntl(fd, F_GETFL);
    if (oflags < 0 || fcntl(fd, F_SETFL, oflags & ~O_NONBLOCK) < 0) {
        int ferr = errno;
        close(fd);
        if (message) *message = [NSString stringWithFormat:@"The file can't be opened for writing: %s.", strerror(ferr)];
        return FBSaveFailed;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int lockError = errno;
        close(fd);
        if (message) *message = [NSString stringWithFormat:@"The file is busy or could not be locked: %s. Nothing was changed.",
                                  strerror(lockError)];
        return FBSaveFailed;
    }
    FBFileIdentity current = filebrowser_identity_fd(fd);
    BOOL tooBig = NO;
    int rerr = 0;
    NSData *currentData = filebrowser_read_fd(fd, kFBMaxBackupBytes, &tooBig, &rerr);
    if (!currentData) {
        msg = [NSString stringWithFormat:@"The current file couldn't be read for a backup (%s). Nothing was written.", strerror(rerr)];
    } else if (tooBig) {
        msg = @"The current file is too large to back up first. Nothing was written.";
    } else if (!force && (!fb_same_object(expected, current) || !loaded || ![currentData isEqualToData:loaded])) {
        result = FBSaveConflict;
    } else {
        NSString *dir = fb_backup_dir();
        NSError *dirError = nil;
        BOOL dirReady = dir.length && [NSFileManager.defaultManager createDirectoryAtPath:dir
                                                               withIntermediateDirectories:YES
                                                                                attributes:nil
                                                                                     error:&dirError] &&
                        fb_fsync_directory(dir);
        // "<name>.<UUID>.bak" must fit the 255-byte name limit: the UUID and
        // suffix take 41 bytes, so a name over ~214 bytes made every save of
        // that file fail with "backup couldn't be written". Keep at most 120
        // bytes of the name, cut at a whole character (UTF-8 safe).
        NSString *base = path.lastPathComponent;
        while ([base lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 120 && base.length > 0) {
            NSRange last = [base rangeOfComposedCharacterSequenceAtIndex:base.length - 1];
            base = [base substringToIndex:last.location];
        }
        NSString *backup = [dir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"%@.%@.bak", base, NSUUID.UUID.UUIDString]];
        // Sidecar with the original path, so a backup left behind by a crash
        // mid-save can be traced to the file it belongs to (see
        // fb_leftover_backups / the notice on the next File Browser open).
        NSString *backupPath = [backup stringByAppendingString:@".path"];
        if (!dirReady) {
            msg = [NSString stringWithFormat:@"A durable recovery folder couldn't be prepared%@. Nothing was changed.",
                   dirError.localizedDescription.length ? [NSString stringWithFormat:@" (%@)", dirError.localizedDescription] : @""];
        } else if (!fb_write_durable_file(backup, currentData, 0600) ||
                   !fb_write_durable_file(backupPath, [path dataUsingEncoding:NSUTF8StringEncoding], 0600)) {
            // Nothing was changed: remove whatever got (partly) written, or
            // the leftover would raise a false "Unfinished Saves" notice.
            [NSFileManager.defaultManager removeItemAtPath:backup error:nil];
            [NSFileManager.defaultManager removeItemAtPath:backupPath error:nil];
            msg = @"A backup of the current file couldn't be written. Nothing was changed.";
        } else {
            // Recheck after the durable preimage was made.  This catches a
            // cooperative writer that ignores flock and a pathname replaced
            // while the backup was being prepared, before touching the inode.
            FBFileIdentity beforeCommit = filebrowser_identity_fd(fd);
            FBFileIdentity visibleBefore = fb_identity_path(path);
            BOOL stableTooBig = NO;
            int stableError = 0;
            NSData *stableData = filebrowser_read_fd(fd, kFBMaxBackupBytes, &stableTooBig, &stableError);
            if (!fb_same_object(current, beforeCommit) || !fb_same_object(current, visibleBefore) ||
                stableTooBig || !stableData || ![stableData isEqualToData:currentData]) {
                result = FBSaveConflict;
                msg = @"The file changed while it was being prepared. Nothing was written; reload and try again.";
                [NSFileManager.defaultManager removeItemAtPath:backup error:nil];
                [NSFileManager.defaultManager removeItemAtPath:backupPath error:nil];
            } else if (fb_pwrite_all(fd, data)) {
                FBFileIdentity afterWrite = filebrowser_identity_fd(fd);
                FBFileIdentity visibleAfter = fb_identity_path(path);
                BOOL postTooBig = NO;
                int postError = 0;
                NSData *postData = filebrowser_read_fd(fd, kFBMaxBackupBytes, &postTooBig, &postError);
                BOOL postcondition = fb_same_object(afterWrite, visibleAfter) &&
                                     !postTooBig && postData && [postData isEqualToData:data];
                // Positive evidence that another writer won: the path now
                // names a different object, or our descriptor reads back
                // contents that are not ours.  A failed fstat/stat/read is
                // NOT evidence of anything -- the disk state is unknown.
                BOOL replaced = !postcondition &&
                                ((afterWrite.valid && visibleAfter.valid && !fb_same_object(afterWrite, visibleAfter)) ||
                                 postTooBig || (postData && ![postData isEqualToData:data]));
                filebrowser_note_filesystem_changed();
                if (postcondition) {
                    [NSFileManager.defaultManager removeItemAtPath:backup error:nil];
                    [NSFileManager.defaultManager removeItemAtPath:backupPath error:nil];
                    if (newIdentity) *newIdentity = afterWrite;
                    result = FBSaveOK;
                } else if (!replaced) {
                    // The write itself succeeded, but the result could not be
                    // checked. Keep the backup (and its sidecar): it is the
                    // only copy of the previous contents if the file is now
                    // new, partial or unknown.
                    result = FBSaveUncertain;
                    msg = [NSString stringWithFormat:@"Your edit was written, but the result couldn't be verified (%s). "
                                                     @"Reload the file to check it. A backup of its previous contents was kept at:\n%@",
                                                     postError ? strerror(postError) : "the file could not be re-checked", backup];
                } else {
                    // Someone else wrote to (or replaced) the file during our
                    // write. Writing our old contents back would overwrite
                    // THEIR change, so write nothing more: report a conflict
                    // and drop our backup -- it holds the pre-save contents,
                    // not what is in the file now, and a leftover would raise
                    // a false "Unfinished Saves" notice.
                    [NSFileManager.defaultManager removeItemAtPath:backup error:nil];
                    [NSFileManager.defaultManager removeItemAtPath:backupPath error:nil];
                    result = FBSaveConflict;
                    msg = @"Another program changed the file while it was being saved, so what is in it now may not be your edit. Reload to see the current contents before trying again.";
                }
            } else {
            int werr = errno;
            filebrowser_note_filesystem_changed();   // the file may have changed
            if (fb_pwrite_all(fd, currentData)) {
                [NSFileManager.defaultManager removeItemAtPath:backup error:nil];
                [NSFileManager.defaultManager removeItemAtPath:backupPath error:nil];
                if (newIdentity) *newIdentity = filebrowser_identity_fd(fd);
                msg = [NSString stringWithFormat:@"Writing failed (%s). The file's previous contents were written back.", strerror(werr)];
            } else {
                msg = [NSString stringWithFormat:@"Writing failed (%s), and restoring the previous contents failed too. "
                                                 @"The file may be damaged. A backup of its previous contents is at:\n%@",
                                                 strerror(werr), backup];
            }
            }
        }
    }
    flock(fd, LOCK_UN);
    close(fd);
    if (message) *message = msg;
    return result;
}

// Backups left behind: a successful save (or a successful write-back) removes
// its backup, so any *.bak still here means a save was interrupted -- the app
// or device died mid-write -- or failed and could not restore. Returns the
// original paths (from the .path sidecars; a backup without one is listed by
// its own name), oldest first.
static NSString *fb_backup_dir(void)
{
    NSArray<NSString *> *roots = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                                       NSUserDomainMask, YES);
    NSString *root = roots.firstObject;
    return root.length ? [root stringByAppendingPathComponent:@"FileBrowserRecovery"] : nil;
}

// Keep pre-1.7.2/legacy temporary backups visible after moving new recovery
// artifacts to persistent application support.
static NSString *fb_legacy_backup_dir(void)
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"FileBrowserBackups"];
}

static BOOL fb_fsync_directory(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return NO;
    int rc = fsync(fd);
    close(fd);
    return rc == 0;
}

// NSData writeToFile:atomically: does not establish a durable preimage.  Use
// a descriptor, fsync the bytes, then fsync the containing directory before
// the original file is touched.
static BOOL fb_write_durable_file(NSString *path, NSData *data, mode_t mode)
{
    // Recovery names are UUID-derived. Never turn an accidental collision
    // into truncation of an older preimage; failing closed keeps the original
    // untouched and leaves the existing recovery artifact available.
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode);
    if (fd < 0) return NO;
    const uint8_t *p = data.bytes;
    size_t done = 0;
    BOOL ok = YES;
    while (done < data.length) {
        ssize_t n = write(fd, p + done, data.length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = NO; break; }
        done += (size_t)n;
    }
    if (ok && fsync(fd) != 0) ok = NO;
    if (close(fd) != 0) ok = NO;
    if (ok && !fb_fsync_directory([path stringByDeletingLastPathComponent])) ok = NO;
    return ok;
}

static NSArray<NSString *> *fb_leftover_backups(void)
{
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *dir in @[ fb_backup_dir() ?: @"", fb_legacy_backup_dir() ]) {
        if (!dir.length) continue;
        NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
            if (![name hasSuffix:@".bak"]) continue;
            NSString *bak = [dir stringByAppendingPathComponent:name];
            NSString *orig = [NSString stringWithContentsOfFile:[bak stringByAppendingString:@".path"]
                                                       encoding:NSUTF8StringEncoding error:nil];
            [out addObject:orig.length ? orig : [NSString stringWithFormat:@"%@ (%@)", name, dir]];
        }
    }
    return out;
}

// File operations (delete/rename/duplicate/create/import) run one at a
// time: two duplicates/imports can't pick the same free name concurrently.
static dispatch_queue_t fb_file_queue(void)
{
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("cyanide.filebrowser.ops", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// Saves run on the same queue, one at a time, after any pending operation.
dispatch_queue_t filebrowser_file_queue(void) { return fb_file_queue(); }

// Decodes an image for display, downsampled to a pixel budget: a small
// compressed file can otherwise decode to hundreds of MB.
static UIImage *fb_display_image(NSData *data)
{
    if (!data.length) return nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return nil;
    UIImage *image = nil;
    if (CGImageSourceGetCount(src) > 0) {
        NSDictionary *opts = @{ (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                                (id)kCGImageSourceShouldCacheImmediately: @YES,
                                (id)kCGImageSourceThumbnailMaxPixelSize: @2048 };
        CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
        if (cg) { image = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
    }
    CFRelease(src);
    return image;
}

// Whether `data` is an image ImageIO can read, without decoding pixels.
static BOOL fb_is_image(NSData *data)
{
    if (!data.length) return NO;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return NO;
    BOOL ok = CGImageSourceGetType(src) != NULL && CGImageSourceGetCount(src) > 0;
    CFRelease(src);
    return ok;
}

static NSError *fb_locked_error(void)
{
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM
                           userInfo:@{ NSLocalizedDescriptionKey: @"Changes were locked before this could run." }];
}

static void fb_alert(UIViewController *vc, NSString *title, NSString *message)
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                message:message
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:ac animated:YES completion:nil];
}

// "name", "name 2", "name 3"… (before the extension) — first one not taken.
static NSString *fb_unique_path(NSString *dir, NSString *name)
{
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSString *base = name.stringByDeletingPathExtension;
    NSString *ext = name.pathExtension;
    // lstat, not fileExists/access: those follow links, so a dangling
    // symlink's name would look free.
    struct stat st;
    for (int i = 2; lstat(path.fileSystemRepresentation, &st) == 0 && i < 10000; i++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ %d", base, i];
        if (ext.length) candidate = [candidate stringByAppendingPathExtension:ext];
        path = [dir stringByAppendingPathComponent:candidate];
    }
    return path;
}

static const NSUInteger kFBMaxImportItems = 20000;
static const unsigned long long kFBMaxImportBytes = 512ULL * 1024ULL * 1024ULL;
static const unsigned long long kFBMaxImportItemBytes = 128ULL * 1024ULL * 1024ULL;

static BOOL fb_import_add_item(NSUInteger *items, NSString **failure)
{
    if (*items >= kFBMaxImportItems) {
        if (failure) *failure = [NSString stringWithFormat:@"Import exceeds the %lu-item limit.",
                                  (unsigned long)kFBMaxImportItems];
        return NO;
    }
    (*items)++;
    return YES;
}

static BOOL fb_import_copy_regular(NSString *source, NSString *target, const struct stat *sourceStat,
                                   unsigned long long *totalBytes, NSString **failure)
{
    // The source was classified with lstat as a regular file (symlinks are
    // copied as links, never followed), so open it no-follow: a symlink
    // swapped in since then fails here instead of importing its target.
    int in = open(source.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (in < 0) {
        if (failure) *failure = [NSString stringWithFormat:@"Couldn't open %@: %s", source.lastPathComponent, strerror(errno)];
        return NO;
    }
    struct stat opened;
    if (fstat(in, &opened) != 0 || !S_ISREG(opened.st_mode)) {
        close(in);
        if (failure) *failure = [NSString stringWithFormat:@"%@ is no longer a regular file.", source.lastPathComponent];
        return NO;
    }
    // Must still be the object that was inspected, not a different regular
    // file renamed into place meanwhile.
    if (opened.st_dev != sourceStat->st_dev || opened.st_ino != sourceStat->st_ino) {
        close(in);
        if (failure) *failure = [NSString stringWithFormat:@"%@ was replaced while it was being imported.", source.lastPathComponent];
        return NO;
    }
    int out = open(target.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                   sourceStat->st_mode & 0777);
    if (out < 0) {
        close(in);
        if (failure) *failure = [NSString stringWithFormat:@"Couldn't create %@: %s", target.lastPathComponent, strerror(errno)];
        return NO;
    }
    BOOL ok = YES;
    unsigned long long copied = 0;
    char buf[64 * 1024];
    while (ok) {
        if (!filebrowser_write_enabled()) {
            if (failure) *failure = @"Changes were locked while the import was running.";
            ok = NO;
            break;
        }
        unsigned long long remaining = MIN(kFBMaxImportItemBytes - MIN(copied, kFBMaxImportItemBytes),
                                           kFBMaxImportBytes - MIN(*totalBytes, kFBMaxImportBytes));
        if (!remaining) {
            ssize_t probe = read(in, buf, 1);
            if (probe > 0 && failure) *failure = @"Import exceeds the 128 MB per-file or 512 MB aggregate limit.";
            else if (probe < 0 && errno != EINTR && failure) *failure = @"The source could not be read.";
            ok = probe == 0;
            break;
        }
        size_t want = (size_t)MIN((unsigned long long)sizeof(buf), remaining);
        ssize_t n = read(in, buf, want);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) {
            if (failure) *failure = [NSString stringWithFormat:@"Couldn't read %@: %s", source.lastPathComponent, strerror(errno)];
            ok = NO;
            break;
        }
        if (n == 0) break;
        size_t done = 0;
        while (done < (size_t)n) {
            ssize_t w = write(out, buf + done, (size_t)n - done);
            if (w < 0 && errno == EINTR) continue;
            if (w <= 0) {
                if (failure) *failure = [NSString stringWithFormat:@"Couldn't write %@: %s", target.lastPathComponent, strerror(errno)];
                ok = NO;
                break;
            }
            done += (size_t)w;
        }
        copied += (unsigned long long)n;
        *totalBytes += (unsigned long long)n;
    }
    if (close(in) != 0) ok = NO;
    if (close(out) != 0) ok = NO;
    if (!ok) [NSFileManager.defaultManager removeItemAtPath:target error:nil];
    return ok;
}

static BOOL fb_import_copy_path(NSString *source, NSString *target, NSUInteger *items,
                                unsigned long long *totalBytes, NSString **failure)
{
    struct stat st;
    if (lstat(source.fileSystemRepresentation, &st) != 0) {
        if (failure) *failure = [NSString stringWithFormat:@"Couldn't inspect %@: %s", source.lastPathComponent, strerror(errno)];
        return NO;
    }
    if (!fb_import_add_item(items, failure)) return NO;
    if (S_ISREG(st.st_mode)) return fb_import_copy_regular(source, target, &st, totalBytes, failure);
    if (S_ISLNK(st.st_mode)) {
        char link[PATH_MAX];
        ssize_t n = readlink(source.fileSystemRepresentation, link, sizeof(link) - 1);
        if (n >= 0 && n < (ssize_t)sizeof(link) - 1) link[n] = 0;   // readlink doesn't terminate
        if (n < 0 || n >= (ssize_t)sizeof(link) - 1 || symlink(link, target.fileSystemRepresentation) != 0) {
            if (failure) *failure = [NSString stringWithFormat:@"Couldn't copy link %@.", source.lastPathComponent];
            return NO;
        }
        return YES;
    }
    if (!S_ISDIR(st.st_mode)) {
        if (failure) *failure = [NSString stringWithFormat:@"%@ is a special file and cannot be imported.", source.lastPathComponent];
        return NO;
    }
    if (mkdir(target.fileSystemRepresentation, st.st_mode & 0777) != 0) {
        if (failure) *failure = [NSString stringWithFormat:@"Couldn't create %@: %s", target.lastPathComponent, strerror(errno)];
        return NO;
    }
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:source];
    for (NSString *relative in enumerator) {
        if (!filebrowser_write_enabled()) {
            if (failure) *failure = @"Changes were locked while the import was running.";
            return NO;
        }
        NSString *child = [source stringByAppendingPathComponent:relative];
        NSString *destination = [target stringByAppendingPathComponent:relative];
        struct stat childStat;
        if (lstat(child.fileSystemRepresentation, &childStat) != 0) {
            if (failure) *failure = [NSString stringWithFormat:@"Couldn't inspect %@: %s", relative, strerror(errno)];
            return NO;
        }
        if (!fb_import_add_item(items, failure)) return NO;
        if (S_ISDIR(childStat.st_mode)) {
            if (mkdir(destination.fileSystemRepresentation, childStat.st_mode & 0777) != 0) {
                if (failure) *failure = [NSString stringWithFormat:@"Couldn't create %@: %s", relative, strerror(errno)];
                return NO;
            }
        } else if (S_ISREG(childStat.st_mode)) {
            // The item was counted above; the regular helper only streams it.
            if (!fb_import_copy_regular(child, destination, &childStat, totalBytes, failure)) return NO;
        } else if (S_ISLNK(childStat.st_mode)) {
            char link[PATH_MAX];
            ssize_t n = readlink(child.fileSystemRepresentation, link, sizeof(link) - 1);
            if (n >= 0 && n < (ssize_t)sizeof(link) - 1) link[n] = 0;   // readlink doesn't terminate
            if (n < 0 || n >= (ssize_t)sizeof(link) - 1 || symlink(link, destination.fileSystemRepresentation) != 0) {
                if (failure) *failure = [NSString stringWithFormat:@"Couldn't copy link %@.", relative];
                return NO;
            }
        } else {
            if (failure) *failure = [NSString stringWithFormat:@"%@ contains a special file and cannot be imported.", relative];
            return NO;
        }
    }
    return YES;
}

static const NSUInteger kFBMaxOrdinaryEntries = 4000;

// contentsOfDirectoryAtPath: materializes every name before the UI can show
// anything.  Keep only a bounded immediate-directory window and tell the UI
// when another entry exists; the caller still builds metadata only for this
// bounded result.
static NSArray<NSString *> *fb_bounded_directory_names(NSString *path, BOOL *incomplete, NSError **error)
{
    if (incomplete) *incomplete = NO;
    DIR *dir = opendir(path.fileSystemRepresentation);
    if (!dir) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                                            userInfo:@{ NSLocalizedDescriptionKey:
                                                            [NSString stringWithUTF8String:strerror(errno)] ?: @"directory open failed" }];
        return nil;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:kFBMaxOrdinaryEntries];
    BOOL failed = NO;
    int enumerationError = 0;
    while (names.count < kFBMaxOrdinaryEntries) {
        errno = 0;
        struct dirent *ent = readdir(dir);
        if (!ent) {
            if (errno != 0) { enumerationError = errno; failed = YES; }
            break;
        }
        if (!strcmp(ent->d_name, ".") || !strcmp(ent->d_name, "..")) continue;
        NSString *name = [[NSString alloc] initWithBytes:ent->d_name length:strlen(ent->d_name)
                                                 encoding:NSUTF8StringEncoding];
        if (name) [names addObject:name];
    }
    if (!failed && names.count == kFBMaxOrdinaryEntries) {
        for (;;) {
            errno = 0;
            struct dirent *more = readdir(dir);
            if (!more) {
                if (errno != 0) { enumerationError = errno; failed = YES; }
                break;
            }
            if (!strcmp(more->d_name, ".") || !strcmp(more->d_name, "..")) continue;
            if (incomplete) *incomplete = YES;
            break;
        }
    }
    int closeError = closedir(dir);
    if (failed || closeError != 0) {
        int code = enumerationError ?: (closeError != 0 ? errno : EIO);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                                            userInfo:@{ NSLocalizedDescriptionKey:
                                                            [NSString stringWithUTF8String:strerror(code)] ?: @"directory enumeration failed" }];
        return nil;
    }
    return names;
}

#pragma mark - Entries

@interface FBEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) FBFileIdentity identity; // lstat identity of the listed pathname
@property (nonatomic, copy) NSString *linkTarget;   // symlinks only
@property (nonatomic, assign) BOOL isDirectory;     // after following a symlink
@property (nonatomic, assign) BOOL isSymlink;
@property (nonatomic, assign) BOOL readable;
@property (nonatomic, assign) BOOL statFailed;
@property (nonatomic, assign) mode_t mode;
@property (nonatomic, assign) uid_t uid;
@property (nonatomic, assign) gid_t gid;
@property (nonatomic, assign) off_t size;
@property (nonatomic, strong) NSDate *modified;
@property (nonatomic, assign) BOOL viaRoot;   // listed/readable only through launchd root
@property (nonatomic, assign) BOOL rootUnlocked;   // not readable as mobile, opened through root
@property (nonatomic, strong) FBAppContainer *container;   // app container folders: whose it is
@property (nonatomic, copy) NSString *searchLocation;      // subfolder search: folder it was found in
@end

@implementation FBEntry
@end

// Builds an entry from a settings_root_list_directory dictionary.
static FBEntry *fb_entry_from_root_dict(NSString *dir, NSDictionary *info)
{
    FBEntry *e = [FBEntry new];
    e.name = info[@"name"];
    e.path = [dir stringByAppendingPathComponent:e.name];
    e.viaRoot = YES;
    e.readable = YES;   // reachable as root
    if (info[@"statFailed"]) { e.statFailed = YES; return e; }
    e.mode = (mode_t)[info[@"mode"] unsignedIntValue];
    e.uid = (uid_t)[info[@"uid"] unsignedIntValue];
    e.gid = (gid_t)[info[@"gid"] unsignedIntValue];
    e.size = (off_t)[info[@"size"] longLongValue];
    e.modified = [NSDate dateWithTimeIntervalSince1970:[info[@"mtime"] doubleValue]];
    e.isDirectory = [info[@"isDirectory"] boolValue];
    e.linkTarget = info[@"linkTarget"];
    e.isSymlink = (e.linkTarget != nil) || S_ISLNK(e.mode);
    return e;
}

static NSString *fb_user_name(uid_t uid)
{
    struct passwd *pw = getpwuid(uid);
    return pw && pw->pw_name ? @(pw->pw_name) : [NSString stringWithFormat:@"%u", uid];
}

static NSString *fb_group_name(gid_t gid)
{
    struct group *gr = getgrgid(gid);
    return gr && gr->gr_name ? @(gr->gr_name) : [NSString stringWithFormat:@"%u", gid];
}

static NSString *fb_mode_string(mode_t mode, BOOL isSymlink)
{
    char s[11];
    s[0] = isSymlink ? 'l' : S_ISDIR(mode) ? 'd' : '-';
    const char *rwx = "rwxrwxrwx";
    for (int i = 0; i < 9; i++) s[i + 1] = (mode & (1 << (8 - i))) ? rwx[i] : '-';
    s[10] = 0;
    return @(s);
}

static NSString *fb_size_string(off_t size)
{
    return [NSByteCountFormatter stringFromByteCount:size countStyle:NSByteCountFormatterCountStyleFile];
}


#pragma mark - Folder size

// Folder Size: walks a folder without following symlinks or leaving its
// volume, counting hard-linked files once. Folders mobile can't open are
// listed through launchd when root access is on (their on-disk size is then
// estimated from the file sizes, as root listings carry no block counts).
// Read-only; runs off the main thread and stops when the job is cancelled.
@interface FBSizeJob : NSObject {
@public
    atomic_bool cancelled;
}
@property (nonatomic, assign) unsigned long long logical;     // file sizes
@property (nonatomic, assign) unsigned long long allocated;   // blocks on disk
@property (nonatomic, assign) unsigned long long files;
@property (nonatomic, assign) unsigned long long folders;
@property (nonatomic, assign) unsigned long long unreadable;  // folders that couldn't be listed
@property (nonatomic, assign) unsigned long long viaRoot;     // folders listed as root
@property (nonatomic, assign) BOOL incomplete;                // a listing was cut short
@end

@implementation FBSizeJob
@end

static const unsigned long long kFBSizeMaxItems = 5000000ULL;

static void fb_measure_folder(NSString *rootPath, BOOL rootOn, FBSizeJob *job,
                              void (^progress)(unsigned long long items))
{
    struct stat rootSt;
    if (lstat(rootPath.fileSystemRepresentation, &rootSt) != 0 || !S_ISDIR(rootSt.st_mode)) {
        // A folder only root can stat: measure it entirely through launchd.
        if (!rootOn) { job.unreadable++; return; }
        rootSt.st_dev = 0;
    }
    dev_t rootDev = rootSt.st_dev;
    NSMutableSet<NSNumber *> *seenLinks = [NSMutableSet set];
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:rootPath];
    NSMutableArray<NSString *> *rootStack = [NSMutableArray array];
    unsigned long long items = 0, lastReport = 0;

    while ((stack.count || rootStack.count) && !atomic_load(&job->cancelled) && items < kFBSizeMaxItems) {
        if (stack.count) {
            NSString *dirPath = stack.lastObject;
            [stack removeLastObject];
            int dfd = open(dirPath.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            DIR *dir = dfd >= 0 ? fdopendir(dfd) : NULL;
            if (!dir) {
                if (dfd >= 0) close(dfd);
                if (rootOn && (errno == EACCES || errno == EPERM)) [rootStack addObject:dirPath];
                else job.unreadable++;
                continue;
            }
            job.folders++;
            struct dirent *ent;
            while ((ent = readdir(dir)) && !atomic_load(&job->cancelled)) {
                if (!strcmp(ent->d_name, ".") || !strcmp(ent->d_name, "..")) continue;
                struct stat st;
                if (fstatat(dirfd(dir), ent->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) continue;
                items++;
                if (S_ISDIR(st.st_mode)) {
                    if (rootDev && st.st_dev != rootDev) continue;   // another volume mounted here
                    NSString *child = [dirPath stringByAppendingPathComponent:
                                       [[NSString alloc] initWithBytes:ent->d_name length:strlen(ent->d_name)
                                                              encoding:NSUTF8StringEncoding] ?: @""];
                    if (child.length > dirPath.length + 1) [stack addObject:child];
                    continue;
                }
                if (st.st_nlink > 1 && S_ISREG(st.st_mode)) {
                    NSNumber *key = @(((unsigned long long)st.st_dev << 40) ^ (unsigned long long)st.st_ino);
                    if ([seenLinks containsObject:key]) continue;
                    [seenLinks addObject:key];
                }
                job.files++;
                job.logical += (unsigned long long)MAX(st.st_size, 0);
                job.allocated += (unsigned long long)st.st_blocks * 512ULL;
            }
            closedir(dir);
        } else {
            NSString *dirPath = rootStack.lastObject;
            [rootStack removeLastObject];
            BOOL incomplete = NO;
            NSString *err = nil;
            NSArray<NSDictionary *> *entries = settings_root_list_directory(dirPath, &incomplete, &err);
            if (!entries) { job.unreadable++; continue; }
            if (incomplete) job.incomplete = YES;
            job.folders++;
            job.viaRoot++;
            for (NSDictionary *info in entries) {
                if (atomic_load(&job->cancelled)) break;
                if (info[@"statFailed"]) continue;
                items++;
                NSString *name = info[@"name"];
                if (!name.length) continue;
                if ([info[@"isDirectory"] boolValue] && !info[@"linkTarget"]) {
                    [rootStack addObject:[dirPath stringByAppendingPathComponent:name]];
                    continue;
                }
                if (info[@"linkTarget"]) continue;
                unsigned long long size = (unsigned long long)MAX([info[@"size"] longLongValue], 0LL);
                job.files++;
                job.logical += size;
                job.allocated += (size + 4095ULL) & ~4095ULL;
            }
        }
        if (progress && items - lastReport >= 2000) { lastReport = items; progress(items); }
    }
    if (items >= kFBSizeMaxItems) job.incomplete = YES;
}

static NSString *fb_date_string(NSDate *date)
{
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateStyle = NSDateFormatterShortStyle;
        fmt.timeStyle = NSDateFormatterShortStyle;
    });
    return date ? [fmt stringFromDate:date] : @"";
}

static FBEntry *fb_entry_at(NSString *dir, NSString *name)
{
    FBEntry *e = [FBEntry new];
    e.name = name;
    e.path = [dir stringByAppendingPathComponent:name];
    struct stat ls;
    if (lstat(e.path.fileSystemRepresentation, &ls) != 0) {
        e.statFailed = YES;
        return e;
    }
    e.mode = ls.st_mode;
    // Build the struct locally: a field of a struct property can't be
    // assigned through the property.
    FBFileIdentity ident = {0};
    ident.valid = YES;
    ident.dev = ls.st_dev;
    ident.ino = ls.st_ino;
    ident.size = ls.st_size;
    ident.mtime = ls.st_mtimespec;
    e.identity = ident;
    e.uid = ls.st_uid;
    e.gid = ls.st_gid;
    e.size = ls.st_size;
    e.modified = [NSDate dateWithTimeIntervalSince1970:ls.st_mtimespec.tv_sec];
    e.isDirectory = S_ISDIR(ls.st_mode);
    if (S_ISLNK(ls.st_mode)) {
        e.isSymlink = YES;
        char buf[PATH_MAX];
        ssize_t n = readlink(e.path.fileSystemRepresentation, buf, sizeof(buf) - 1);
        if (n > 0) { buf[n] = 0; e.linkTarget = @(buf); }
        struct stat st;
        if (stat(e.path.fileSystemRepresentation, &st) == 0) e.isDirectory = S_ISDIR(st.st_mode);
    }
    e.readable = access(e.path.fileSystemRepresentation, e.isDirectory ? (R_OK | X_OK) : R_OK) == 0;
    return e;
}

// Destructive actions retain an entry while a confirmation/menu is open.  The
// pathname is not an identity: re-lstat it immediately before the queued
// operation and reject a missing, replaced, or type-changed object.  Darwin
// has no atomic unlink-if-inode primitive for arbitrary external writers, so
// this closes the stale-prompt/queued-target window without claiming to stop
// a non-cooperating writer racing the final syscall.
static BOOL fb_entry_still_matches(FBEntry *entry, NSError **error)
{
    struct stat st;
    if (!entry.identity.valid || lstat(entry.path.fileSystemRepresentation, &st) != 0 ||
        st.st_dev != entry.identity.dev || st.st_ino != entry.identity.ino ||
        (st.st_mode & S_IFMT) != (entry.mode & S_IFMT)) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EBUSY
                                            userInfo:@{ NSLocalizedDescriptionKey:
                                                            @"The file changed or was replaced. Reload the folder and try again." }];
        return NO;
    }
    return YES;
}

#pragma mark - File viewer

typedef NS_ENUM(NSInteger, FBViewMode) { FBViewText, FBViewImage, FBViewHex, FBViewInfo };

@interface FBFileViewController : UIViewController
- (instancetype)initWithEntry:(FBEntry *)entry;
@end

@interface FBFileViewController (Share)
- (void)shareCopy:(UIBarButtonItem *)sender;
@end

@interface FBFileViewController ()
@property (nonatomic, strong) FBEntry *entry;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) NSData *data;            // head of the file
@property (nonatomic, assign) BOOL truncated;
@property (nonatomic, assign) NSInteger plistFormat;   // NSPropertyListFormat, or -1
// plistText for `plistTextFor` (parsed once per loaded data, not per call).
@property (nonatomic, strong) NSData *plistTextFor;
@property (nonatomic, copy) NSString *plistTextCached;
@property (nonatomic, assign) NSInteger plistFormatCached;
@property (nonatomic, assign) BOOL editingText;
@property (nonatomic, assign) FBFileIdentity identity;   // file as it was when loaded
@property (nonatomic, assign) BOOL notRegular;           // FIFO/device/socket: Info only
@property (nonatomic, assign) BOOL sharing;
@property (nonatomic, assign) BOOL saving;
@property (nonatomic, assign) int readError;              // errno of a failed read
@property (nonatomic, copy) NSString *readFailure;        // explicit root/transport classification
@property (nonatomic, assign) NSUInteger hexBytesPerLine;   // layout of the current hex dump
@end

static const NSUInteger kFBMaxTextBytes = 2 * 1024 * 1024;
static const NSUInteger kFBMaxHexBytes = 64 * 1024;

@implementation FBFileViewController

- (instancetype)initWithEntry:(FBEntry *)entry
{
    if ((self = [super init])) { _entry = entry; _plistFormat = -1; }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.entry.name;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[ @"Text", @"Image", @"Hex", @"Info" ]];
    [self.modeControl addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.modeControl;

    self.textView = [UITextView new];
    self.textView.editable = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.textView.alwaysBounceVertical = YES;
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.textView];

    self.imageView = [UIImageView new];
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.imageView.hidden = YES;
    [self.view addSubview:self.imageView];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    for (UIView *v in @[ self.textView, self.imageView ]) {
        [NSLayoutConstraint activateConstraints:@[
            [v.topAnchor constraintEqualToAnchor:g.topAnchor],
            [v.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
            [v.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
            [v.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        ]];
    }

    self.textView.text = @"Loading…";
    NSString *path = self.entry.path;
    BOOL viaRoot = self.entry.viaRoot;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *data = nil;
        BOOL truncated = NO, notRegular = NO;
        int readError = 0;
        NSString *readFailure = nil;
        FBFileIdentity ident = {0};
        if (viaRoot) {
            data = settings_root_read_file(path, kFBMaxTextBytes, &truncated, &readFailure);
        } else {
            // Regular files only: a FIFO/device would block or have side
            // effects. Identity comes from the descriptor actually read, and a
            // read error leaves no data (never an "empty, editable" file).
            int openError = 0;
            int fd = fb_open_regular_classified(path, &openError, &notRegular);
            if (fd < 0) {
                readError = openError;
            } else {
                ident = filebrowser_identity_fd(fd);
                int rerr = 0;
                data = filebrowser_read_fd(fd, kFBMaxTextBytes, &truncated, &rerr);
                if (!data) readError = rerr;
                close(fd);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.truncated = truncated;
            self.notRegular = notRegular;
            self.readError = readError;
            self.readFailure = readFailure;
            self.identity = ident;
            self.data = data;
            self.modeControl.selectedSegmentIndex = [self bestMode];
            [self modeChanged];
            [self updateBarButtons];
        });
    });
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    fb_suppress_popup_bar(self, YES);
    [self updateBarButtons];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    fb_suppress_popup_bar(self, NO);
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    filebrowser_cancel_shares_for_presenter(self);
}

// Text and plists can be edited when the whole file was loaded.
- (BOOL)canEdit
{
    // Root access is read-only (edits would need a root write path we don't have).
    return filebrowser_write_enabled() && !self.entry.viaRoot && self.data && !self.truncated &&
           self.identity.valid && ([self plistText] || [self utf8Text]);
}

- (void)updateBarButtons
{
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                           target:self
                                                                           action:@selector(shareCopy:)];
    if (self.editingText) {
        self.navigationItem.rightBarButtonItems = @[
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                          target:self action:@selector(saveEdit)],
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                          target:self action:@selector(cancelEdit)],
        ];
    } else if ([self canEdit]) {
        self.navigationItem.rightBarButtonItems = @[
            share,
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemEdit
                                                          target:self action:@selector(beginEdit)],
        ];
    } else {
        self.navigationItem.rightBarButtonItems = @[ share ];
    }
    self.navigationItem.hidesBackButton = self.editingText || self.saving;
    for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems) item.enabled = !self.saving;
}

- (void)beginEdit
{
    self.modeControl.selectedSegmentIndex = FBViewText;
    [self modeChanged];
    self.editingText = YES;
    self.modeControl.enabled = NO;
    self.textView.editable = YES;
    [self.textView becomeFirstResponder];
    [self updateBarButtons];
}

- (void)endEdit
{
    self.editingText = NO;
    self.modeControl.enabled = YES;
    self.textView.editable = NO;
    [self.textView resignFirstResponder];
    [self updateBarButtons];
}

- (void)cancelEdit
{
    [self endEdit];
    [self modeChanged];   // back to the file's contents
}

// Writes in place (not atomically) so the file keeps its inode, owner and
// mode; a failed write puts the original bytes back. A plist must still parse
// and is saved back in its original format (OpenStep, which Foundation can't
// write, as XML — same as the structured editor).
- (void)saveEdit
{
    [self saveEditOverwriting:NO];
}

- (void)saveEditOverwriting:(BOOL)force
{
    if (self.saving) return;
    if (!filebrowser_write_enabled() || self.entry.viaRoot) {
        fb_alert(self, @"Not Saved", @"Changes are locked. Unlock them in the File Browser first.");
        return;
    }
    NSString *text = self.textView.text ?: @"";
    NSData *out = nil;
    if (self.plistFormat >= 0) {
        NSError *err = nil;
        id plist = [NSPropertyListSerialization propertyListWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:NSPropertyListMutableContainersAndLeaves
                                                              format:NULL
                                                               error:&err];
        if (plist) {
            NSPropertyListFormat fmt = (NSPropertyListFormat)self.plistFormat;
            if (fmt == NSPropertyListOpenStepFormat) fmt = NSPropertyListXMLFormat_v1_0;
            out = [NSPropertyListSerialization dataWithPropertyList:plist format:fmt options:0 error:&err];
        }
        if (!out) {
            fb_alert(self, @"Not Saved", [NSString stringWithFormat:@"The plist is not valid: %@",
                                          err.localizedDescription ?: @"parse error"]);
            return;
        }
    } else {
        out = [text dataUsingEncoding:NSUTF8StringEncoding];
    }
    // The file I/O (backup, conflict check, write, restore) runs off-main;
    // the editor stays frozen until it's done.
    self.saving = YES;
    self.textView.editable = NO;
    [self updateBarButtons];
    NSString *path = self.entry.path;
    FBFileIdentity expected = self.identity;
    NSData *loaded = self.data;
    dispatch_async(fb_file_queue(), ^{
        FBFileIdentity newIdent = {0};
        NSString *message = nil;
        FBSaveResult r = filebrowser_save(path, out, expected, loaded, force, &newIdent, &message);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.saving = NO;
            self.textView.editable = self.editingText;
            [self updateBarButtons];
            if (r == FBSaveConflict) {
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"File Changed"
                                                                            message:@"The file was changed or replaced since you opened it. Overwrite it with your version?"
                                                                     preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [ac addAction:[UIAlertAction actionWithTitle:@"Overwrite" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
                    [self saveEditOverwriting:YES];
                }]];
                [self presentViewController:ac animated:YES completion:nil];
                return;
            }
            if (r == FBSaveFailed) {
                if (newIdent.valid) self.identity = newIdent;   // restored: matches disk again
                fb_alert(self, @"Not Saved", message ?: @"The file could not be written.");
                return;
            }
            if (r == FBSaveUncertain) {
                // Written but unverified: keep the edit open and the old
                // identity, so a later plain save reports a conflict instead
                // of silently trusting an unknown file.
                fb_alert(self, @"Save Not Verified", message ?: @"The file was written, but the result couldn't be verified.");
                return;
            }
            self.identity = newIdent;
            self.data = out;
            self.entry.size = (off_t)out.length;
            self.entry.modified = [NSDate date];
            [self endEdit];
            [self modeChanged];
        });
    });
}

- (FBViewMode)bestMode
{
    if (!self.data) return FBViewInfo;
    if ([self plistText] || [self utf8Text]) return FBViewText;
    if (!self.truncated && fb_is_image(self.data)) return FBViewImage;
    return FBViewHex;
}

- (NSString *)utf8Text
{
    if (!self.data.length) return self.data ? @"" : nil;
    NSString *s = [[NSString alloc] initWithData:self.data encoding:NSUTF8StringEncoding];
    if (!s && self.truncated) {
        // The cut may have split a multi-byte character.
        for (NSUInteger trim = 1; trim <= 3 && !s; trim++) {
            s = [[NSString alloc] initWithData:[self.data subdataWithRange:NSMakeRange(0, self.data.length - trim)]
                                      encoding:NSUTF8StringEncoding];
        }
    }
    if (s && [s rangeOfString:@"\0"].location != NSNotFound) return nil;   // binary
    return s;
}

// Binary and XML plists, rendered as XML.
- (NSString *)plistText
{
    if (self.truncated || self.data.length < 8) return nil;
    if (self.plistTextFor == self.data) {
        if (self.plistTextCached) self.plistFormat = self.plistFormatCached;
        return self.plistTextCached;
    }
    NSString *text = [self parsePlistText];
    self.plistTextFor = self.data;
    self.plistTextCached = text;
    self.plistFormatCached = self.plistFormat;
    return text;
}

- (NSString *)parsePlistText
{
    NSPropertyListFormat format = 0;
    id plist = [NSPropertyListSerialization propertyListWithData:self.data options:0 format:&format error:nil];
    if (!plist) return nil;
    self.plistFormat = format;
    if (format == NSPropertyListXMLFormat_v1_0) return [self utf8Text];
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:plist
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0
                                                              error:nil];
    return xml ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding] : nil;
}

// Classic hex dump sized to the screen: as many bytes per line as fit at
// 12 pt (up to 16), then the font grows a little (up to 15 pt) to use the
// rest of the width. The offset column is only as wide as the range needs.
// "0000  62 70 6c 69 73 74 30 30 d6 01 02 03  bplist00...."
static const CGFloat kFBHexBaseFont = 12.0, kFBHexMaxFont = 15.0;

static NSUInteger fb_hex_line_chars(NSUInteger digits, NSUInteger per)
{
    // offset + 2 spaces + "xx " per byte (+1 group gap at 16) + 1 space + ASCII
    return digits + 2 + per * 3 + (per == 16 ? 1 : 0) + 1 + per;
}

- (CGFloat)hexAvailableWidth
{
    return self.textView.bounds.size.width
         - self.textView.textContainerInset.left - self.textView.textContainerInset.right
         - 2 * self.textView.textContainer.lineFragmentPadding;
}

- (NSUInteger)hexBytesPerLineForOffsetDigits:(NSUInteger)digits
{
    UIFont *base = [UIFont monospacedSystemFontOfSize:kFBHexBaseFont weight:UIFontWeightRegular];
    CGFloat charW = [@"0" sizeWithAttributes:@{ NSFontAttributeName: base }].width;
    NSUInteger cols = charW > 0 ? (NSUInteger)floor(self.hexAvailableWidth / charW) : 0;
    for (NSUInteger per = 16; per > 4; per--)
        if (fb_hex_line_chars(digits, per) <= cols) return per;
    return 4;
}

// The largest monospace size (12…15 pt) at which a line still fits.
- (UIFont *)hexFontForLineChars:(NSUInteger)chars
{
    UIFont *base = [UIFont monospacedSystemFontOfSize:kFBHexBaseFont weight:UIFontWeightRegular];
    CGFloat charW = [@"0" sizeWithAttributes:@{ NSFontAttributeName: base }].width;
    CGFloat size = kFBHexBaseFont;
    if (charW > 0 && chars > 0)
        size = MIN(kFBHexMaxFont, MAX(kFBHexBaseFont, floor(kFBHexBaseFont * self.hexAvailableWidth / (chars * charW) * 10) / 10));
    return [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightRegular];
}

- (NSString *)hexText
{
    NSUInteger n = MIN(self.data.length, kFBMaxHexBytes);
    const uint8_t *b = self.data.bytes;
    NSUInteger digits = 4;
    while (digits < 8 && (n > 0 ? n - 1 : 0) >> (digits * 4)) digits++;
    NSUInteger per = [self hexBytesPerLineForOffsetDigits:digits];
    self.hexBytesPerLine = per;
    self.textView.font = [self hexFontForLineChars:fb_hex_line_chars(digits, per)];
    NSMutableString *out = [NSMutableString stringWithCapacity:n * 4 + 64];
    for (NSUInteger off = 0; off < n; off += per) {
        [out appendFormat:@"%0*lx  ", (int)digits, (unsigned long)off];
        for (NSUInteger i = 0; i < per; i++) {
            if (off + i < n) [out appendFormat:@"%02x ", b[off + i]];
            else [out appendString:@"   "];
            if (per == 16 && i == 7) [out appendString:@" "];
        }
        [out appendString:@" "];
        for (NSUInteger i = 0; i < per && off + i < n; i++) {
            uint8_t c = b[off + i];
            [out appendFormat:@"%c", (c >= 0x20 && c < 0x7f) ? c : '.'];
        }
        [out appendString:@"\n"];
    }
    if (self.entry.size > (off_t)n)
        [out appendFormat:@"\n… first %@ of %@ shown\n", fb_size_string((off_t)n), fb_size_string(self.entry.size)];
    return out;
}

// Re-flow the hex dump when the width changes (rotation, split view).
- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (self.modeControl.selectedSegmentIndex == FBViewHex && self.data && !self.editingText) {
        NSUInteger n = MIN(self.data.length, kFBMaxHexBytes);
        NSUInteger digits = 4;
        while (digits < 8 && (n > 0 ? n - 1 : 0) >> (digits * 4)) digits++;
        if ([self hexBytesPerLineForOffsetDigits:digits] != self.hexBytesPerLine) {
            CGPoint offset = self.textView.contentOffset;
            self.textView.text = [self hexText];
            self.textView.contentOffset = offset;
        }
    }
}

- (NSString *)infoText
{
    FBEntry *e = self.entry;
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"Path\n%@\n\n", e.path];
    if (e.linkTarget) [s appendFormat:@"Link target\n%@\n\n", e.linkTarget];
    [s appendFormat:@"Size\n%@ (%lld bytes)\n\n", fb_size_string(e.size), (long long)e.size];
    [s appendFormat:@"Modified\n%@\n\n", fb_date_string(e.modified)];
    [s appendFormat:@"Permissions\n%@  %@:%@\n\n", fb_mode_string(e.mode, e.isSymlink),
                    fb_user_name(e.uid), fb_group_name(e.gid)];
    if (self.notRegular)
        [s appendString:@"This is a special file (FIFO, device or socket). Its contents are not read, "
                        @"because opening it could block or have side effects.\n"];
    else if (self.readFailure.length)
        [s appendFormat:@"Reading the contents failed: %@\n", self.readFailure];
    else if (!self.data && self.readError)
        [s appendFormat:@"Reading the contents failed: %s.\n", strerror(self.readError)];
    else if (!self.data)
        [s appendString:@"The contents could not be read (permission denied or data protection).\n"];
    return s;
}

- (void)modeChanged
{
    FBViewMode mode = (FBViewMode)self.modeControl.selectedSegmentIndex;
    UIImage *image = (mode == FBViewImage && self.data && !self.truncated) ? fb_display_image(self.data) : nil;
    self.imageView.hidden = (image == nil);
    self.textView.hidden = (image != nil);
    if (image) { self.imageView.image = image; return; }

    NSString *text = nil;
    if (!self.data) {
        text = [self infoText];
    }
    // Hex sizes its own font to the width; everything else uses 12 pt.
    self.textView.font = [UIFont monospacedSystemFontOfSize:kFBHexBaseFont weight:UIFontWeightRegular];
    switch (mode) {
        case FBViewText:
            if (self.data) text = [self plistText] ?: [self utf8Text] ?: @"Not a text file. Try Hex.";
            if (self.truncated) text = [text stringByAppendingFormat:@"\n\n… first %@ shown", fb_size_string(kFBMaxTextBytes)];
            break;
        case FBViewImage: if (self.data) text = @"Not an image (or too large to show)."; break;
        case FBViewHex:   if (self.data) text = [self hexText]; break;
        case FBViewInfo:  text = [self infoText]; break;
    }
    self.textView.text = text;
    [self.textView setContentOffset:CGPointZero animated:NO];
}

@end

// Hands a copy (from the app's temp folder) to the share sheet, so the
// receiving app never needs access to the original location.
// Shares the file's CONTENTS (a symlink's target, never the link itself) as a
// regular file in a per-share temp folder, so the receiving app never needs
// access to the original location. Runs off-main: a root read can wait for
// the launchd warm-up and transfer up to 64 MB (root reads go through
// memory; files Cyanide can read itself have no limit).
static const NSUInteger kFBMaxShareBytes = 64 * 1024 * 1024;

// A marker is held open and flocked for the whole operation, including while
// the activity sheet owns the staged file.  A sweep can therefore distinguish
// a crashed operation (no lock) from a live one without touching RemoteCall or
// any other shared resource.
@interface FBShareOperation : NSObject {
    _Atomic(bool) _cancelled;
    _Atomic(bool) _stagingReady;
}
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, weak) id source;
@property (nonatomic, copy) NSString *dir;
@property (nonatomic, copy) NSString *stagedPath;
@property (nonatomic, copy) void (^finished)(void);
@property (nonatomic, assign) int markerFD;
@end

@implementation FBShareOperation
- (instancetype)init
{
    if ((self = [super init])) {
        atomic_init(&_cancelled, false);
        atomic_init(&_stagingReady, false);
        _markerFD = -1;
    }
    return self;
}
- (void)cancelBeforePresentation
{
    if (!atomic_load_explicit(&_stagingReady, memory_order_acquire))
        atomic_store_explicit(&_cancelled, true, memory_order_release);
}
- (BOOL)isCancelled
{
    return atomic_load_explicit(&_cancelled, memory_order_acquire);
}
- (void)markStagingReady
{
    atomic_store_explicit(&_stagingReady, true, memory_order_release);
}
- (BOOL)isStagingReady
{
    return atomic_load_explicit(&_stagingReady, memory_order_acquire);
}
@end

static NSMutableSet<FBShareOperation *> *fb_share_operations(void)
{
    static NSMutableSet<FBShareOperation *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static NSString *fb_share_root(void)
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"FileBrowserShare"];
}

static void fb_share_cleanup(FBShareOperation *op)
{
    if (op.dir.length) [NSFileManager.defaultManager removeItemAtPath:op.dir error:nil];
    if (op.markerFD >= 0) {
        close(op.markerFD);
        op.markerFD = -1;
    }
    [fb_share_operations() removeObject:op];
}

// Called on the main thread before the worker is queued.  This closes the
// small window in which a foreground sweep could see a new directory without
// its active marker.
static BOOL fb_share_prepare(FBShareOperation *op, NSString **failure)
{
    NSString *root = fb_share_root();
    struct stat rootSt;
    BOOL rootExists = lstat(root.fileSystemRepresentation, &rootSt) == 0;
    if (rootExists) {
        if (!S_ISDIR(rootSt.st_mode)) {
            if (failure) *failure = @"The share staging folder is not a directory.";
            return NO;
        }
    } else if (errno != ENOENT) {
        if (failure) *failure = @"The share staging folder could not be inspected.";
        return NO;
    }
    NSError *error = nil;
    if (!rootExists &&
        ![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES
                                                    attributes:nil error:&error]) {
        if (failure) *failure = error.localizedDescription ?: @"The share staging folder could not be created.";
        return NO;
    }
    if (lstat(root.fileSystemRepresentation, &rootSt) != 0 || !S_ISDIR(rootSt.st_mode)) {
        if (failure) *failure = @"The share staging folder is not a safe directory.";
        return NO;
    }

    NSString *dir = [root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:NO
                                                    attributes:nil error:&error]) {
        if (failure) *failure = error.localizedDescription ?: @"The share staging folder could not be created.";
        return NO;
    }
    NSString *marker = [dir stringByAppendingPathComponent:@".active"];
    int fd = open(marker.fileSystemRepresentation,
                  O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if (fd >= 0) close(fd);
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        if (failure) *failure = @"The share staging operation could not be reserved.";
        return NO;
    }
    const char markerText[] = "cyanide-share-active\n";
    if (write(fd, markerText, sizeof(markerText) - 1) != (ssize_t)(sizeof(markerText) - 1)) {
        close(fd);
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        if (failure) *failure = @"The share staging marker could not be written.";
        return NO;
    }
    op.dir = dir;
    NSString *name = op.stagedPath.lastPathComponent ?: @"shared-file";
    if ([name isEqualToString:@".active"]) name = @"active";   // the marker's name
    op.stagedPath = [dir stringByAppendingPathComponent:name];
    op.markerFD = fd;
    return YES;
}

static BOOL fb_share_write_data(FBShareOperation *op, NSData *data, NSString **failure)
{
    int fd = open(op.stagedPath.fileSystemRepresentation,
                  O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
    if (fd < 0) {
        if (failure) *failure = @"The copy could not be created.";
        return NO;
    }
    const uint8_t *bytes = data.bytes;
    size_t offset = 0;
    BOOL ok = YES;
    while (offset < data.length) {
        if ([op isCancelled]) { if (failure) *failure = @"Sharing was cancelled."; ok = NO; break; }
        size_t want = MIN((size_t)64 * 1024, data.length - offset);
        ssize_t n = write(fd, bytes + offset, want);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (failure) *failure = @"The copy could not be written."; ok = NO; break; }
        offset += (size_t)n;
    }
    if (close(fd) != 0) ok = NO;
    if (!ok) [NSFileManager.defaultManager removeItemAtPath:op.stagedPath error:nil];
    return ok;
}

static BOOL fb_share_copy_regular(FBShareOperation *op, NSString *path, NSString **failure)
{
    if ([op isCancelled]) { if (failure) *failure = @"Sharing was cancelled."; return NO; }
    int in = filebrowser_open_regular(path);
    if (in < 0) { *failure = @"Only regular files can be shared."; return NO; }
    // An APFS clone: instant and takes no space, whatever the size (a
    // decrypted IPA is easily hundreds of MB). Cloned from the open fd, so
    // it's the file that was checked, never a swapped-in link.
    if (fclonefileat(in, AT_FDCWD, op.stagedPath.fileSystemRepresentation, 0) == 0) {
        close(in);
        return YES;
    }
    // Otherwise a streamed copy (no size limit: nothing is held in memory),
    // when there is room for it.
    struct stat inSt;
    NSDictionary *fsAttrs = [NSFileManager.defaultManager attributesOfFileSystemForPath:op.stagedPath.stringByDeletingLastPathComponent error:nil];
    unsigned long long freeBytes = [fsAttrs[NSFileSystemFreeSize] unsignedLongLongValue];
    int out = -1;
    if (fstat(in, &inSt) == 0 && freeBytes && (unsigned long long)inSt.st_size + 50ULL * 1024 * 1024 > freeBytes) {
        *failure = @"There isn't enough free space to share a copy of this file.";
    } else {
        out = open(op.stagedPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
        if (out < 0) *failure = @"The copy could not be created.";
    }
    if (out >= 0) {
        char buf[64 * 1024];
        ssize_t n;
        while (!*failure) {
            if ([op isCancelled]) { *failure = @"Sharing was cancelled."; break; }
            n = read(in, buf, sizeof(buf));
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) { *failure = @"The file could not be read."; break; }
            if (n == 0) break;
            size_t done = 0;
            while (done < (size_t)n) {
                if ([op isCancelled]) { *failure = @"Sharing was cancelled."; break; }
                ssize_t w = write(out, buf + done, (size_t)n - done);
                if (w < 0 && errno == EINTR) continue;
                if (w <= 0) { *failure = @"The copy could not be written."; break; }
                done += (size_t)w;
            }
        }
    }
    close(in);
    if (out >= 0) close(out);
    if (*failure) [NSFileManager.defaultManager removeItemAtPath:op.stagedPath error:nil];
    return !*failure;
}

static void fb_share_complete(FBShareOperation *op, NSString *failure)
{
    if (!NSThread.isMainThread) return;
    void (^end)(void) = op.finished;
    op.finished = nil;
    if (end) end();
    UIViewController *presenter = op.presenter;
    if (failure.length || !presenter.view.window) {
        fb_share_cleanup(op);
        if (!failure.length || !presenter.view.window) return;
        fb_alert(presenter, @"Couldn't Share", failure);
        return;
    }
    UIActivityViewController *avc =
        [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:op.stagedPath] ]
                                          applicationActivities:nil];
    avc.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *err) {
        fb_share_cleanup(op);
    };
    // Present on top of whatever is up (e.g. an active search controller),
    // never over a controller that is going away.
    UIViewController *host = presenter;
    while (host.presentedViewController && !host.presentedViewController.isBeingDismissed)
        host = host.presentedViewController;
    UIPopoverPresentationController *pop = avc.popoverPresentationController;
    id source = op.source;
    // A bar item replaced while the copy was prepared (bar buttons rebuilt
    // after a load) has no view any more: anchor to the screen instead.
    BOOL itemLive = [source isKindOfClass:UIBarButtonItem.class] && host == presenter &&
                    ([presenter.navigationItem.rightBarButtonItems containsObject:source] ||
                     [presenter.navigationItem.leftBarButtonItems containsObject:source]);
    if (itemLive) pop.barButtonItem = source;
    else if ([source isKindOfClass:UIView.class] && ((UIView *)source).window == presenter.view.window &&
             ((UIView *)source).superview != nil) {
        pop.sourceView = source;
        pop.sourceRect = [(UIView *)source bounds];
    } else {
        pop.sourceView = host.view;
        pop.sourceRect = CGRectMake(CGRectGetMidX(host.view.bounds), CGRectGetMidY(host.view.bounds), 1, 1);
    }
    __weak UIActivityViewController *weakAvc = avc;
    __block BOOL presented = NO;
    [host presentViewController:avc animated:YES completion:^{
        presented = YES;
    }];
    // If UIKit refused the presentation, neither the present completion nor
    // the sheet's handler ever runs: release the staged copy then. Do not
    // mistake an in-flight presentation for a refusal (that would delete the
    // file while the sheet is appearing); retry once after it has settled.
    void (^cleanupIfRefused)(void) = ^{
        if (presented || weakAvc.presentingViewController || weakAvc.isBeingPresented) return;
        fb_share_cleanup(op);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)), dispatch_get_main_queue(), cleanupIfRefused);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), cleanupIfRefused);
}

void filebrowser_cancel_shares_for_presenter(UIViewController *presenter)
{
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ filebrowser_cancel_shares_for_presenter(presenter); });
        return;
    }
    for (FBShareOperation *op in [fb_share_operations() allObjects])
        if (op.presenter == presenter) [op cancelBeforePresentation];
}

void filebrowser_share_file(UIViewController *presenter, NSString *path, BOOL viaRoot, NSData *preloaded,
                            id source, void (^finished)(void))
{
    if (!NSThread.isMainThread) {
        NSData *snapshot = [preloaded copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            filebrowser_share_file(presenter, path, viaRoot, snapshot, source, finished);
        });
        return;
    }
    FBShareOperation *op = [FBShareOperation new];
    op.presenter = presenter;
    op.source = source;
    op.stagedPath = path.lastPathComponent;
    op.finished = [finished copy];
    NSString *prepareFailure = nil;
    if (!fb_share_prepare(op, &prepareFailure)) {
        void (^end)(void) = op.finished;
        op.finished = nil;
        if (end) end();
        if (presenter.view.window) fb_alert(presenter, @"Couldn't Share", prepareFailure ?: @"The copy could not be prepared.");
        return;
    }
    [fb_share_operations() addObject:op];
    NSString *sourcePath = [path copy];
    NSData *snapshot = [preloaded copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *failure = nil;
        if ([op isCancelled]) {
            failure = @"Sharing was cancelled.";
        } else if (snapshot) {
            if (snapshot.length > kFBMaxShareBytes)
                failure = @"The file is larger than 64 MB. Sharing files that large is not supported.";
            else
                fb_share_write_data(op, snapshot, &failure);
        } else if (viaRoot) {
            // Do not tear down or otherwise mutate the shared RemoteCall
            // session here.  The root reader owns that session; cancellation
            // is checked before and immediately after its bounded read.
            if ([op isCancelled]) {
                failure = @"Sharing was cancelled.";
            } else {
                NSString *rootErr = nil;
                BOOL truncated = NO;
                NSData *full = settings_root_read_file(sourcePath, kFBMaxShareBytes, &truncated, &rootErr);
                if ([op isCancelled]) failure = @"Sharing was cancelled.";
                else if (!full) failure = rootErr ?: @"The file could not be read as root.";
                else if (truncated) failure = @"The file is larger than 64 MB. Sharing only part of it is not supported.";
                else fb_share_write_data(op, full, &failure);
            }
        } else {
            fb_share_copy_regular(op, sourcePath, &failure);
        }
        if (!failure && [op isCancelled]) failure = @"Sharing was cancelled.";
        if (!failure) [op markStagingReady];
        dispatch_async(dispatch_get_main_queue(), ^{ fb_share_complete(op, failure); });
    });
}

static const NSTimeInterval kFBShareStaleAge = 24.0 * 60.0 * 60.0;

static BOOL fb_share_is_uuid_directory_name(NSString *name)
{
    if (name.length != 36) return NO;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:name];
    return uuid && [uuid.UUIDString caseInsensitiveCompare:name] == NSOrderedSame;
}

static void fb_share_sweep_now(void)
{
    NSString *root = fb_share_root();
    int rootFD = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (rootFD < 0) return;
    struct stat rootSt;
    if (fstat(rootFD, &rootSt) != 0 || !S_ISDIR(rootSt.st_mode)) {
        close(rootFD);
        return;
    }
    DIR *rootDir = fdopendir(rootFD);
    if (!rootDir) { close(rootFD); return; }
    time_t now = time(NULL);
    struct dirent *item;
    while ((item = readdir(rootDir)) != NULL) {
        NSString *name = [[NSString alloc] initWithUTF8String:item->d_name];
        if (!fb_share_is_uuid_directory_name(name)) continue;
        NSString *dir = [root stringByAppendingPathComponent:name];
        struct stat dirSt;
        if (lstat(dir.fileSystemRepresentation, &dirSt) != 0 || !S_ISDIR(dirSt.st_mode)) continue;
        if (dirSt.st_mtimespec.tv_sec > now || now - dirSt.st_mtimespec.tv_sec < kFBShareStaleAge) continue;

        // A live worker or activity sheet holds this marker lock.  Never
        // remove it even when the directory itself is old.
        NSString *marker = [dir stringByAppendingPathComponent:@".active"];
        int markerFD = open(marker.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (markerFD >= 0) {
            struct stat markerSt;
            BOOL regular = fstat(markerFD, &markerSt) == 0 && S_ISREG(markerSt.st_mode);
            if (!regular || flock(markerFD, LOCK_EX | LOCK_NB) != 0) {
                close(markerFD);
                continue;
            }
        } else if (errno != ENOENT) {
            // A marker symlink or other unexpected object is not ours to
            // interpret; leave the directory for a later safe inspection.
            continue;
        }

        struct stat verify;
        struct stat currentRoot;
        BOOL sameDir = lstat(dir.fileSystemRepresentation, &verify) == 0 &&
                       S_ISDIR(verify.st_mode) && verify.st_dev == dirSt.st_dev && verify.st_ino == dirSt.st_ino;
        BOOL sameRoot = lstat(root.fileSystemRepresentation, &currentRoot) == 0 &&
                        S_ISDIR(currentRoot.st_mode) && currentRoot.st_dev == rootSt.st_dev && currentRoot.st_ino == rootSt.st_ino;
        if (sameDir && sameRoot) [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        if (markerFD >= 0) close(markerFD);
    }
    closedir(rootDir);
}

void filebrowser_sweep_stale_share_staging(void)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        fb_share_sweep_now();
    });
}

@implementation FBFileViewController (Share)

- (void)shareCopy:(UIBarButtonItem *)sender
{
    if (self.sharing) return;
    self.sharing = YES;
    sender.enabled = NO;
    __weak typeof(self) weakSelf = self;
    filebrowser_share_file(self, self.entry.path, self.entry.viaRoot, nil, sender, ^{
        weakSelf.sharing = NO;
        sender.enabled = YES;
    });
}

@end

#pragma mark - Image viewer

static BOOL fb_is_image_path(NSString *path)
{
    static NSSet *exts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = [NSSet setWithArray:@[ @"png", @"jpg", @"jpeg", @"gif", @"heic", @"heif", @"webp",
                                      @"tif", @"tiff", @"bmp", @"ico" ]];
    });
    return [exts containsObject:path.pathExtension.lowercaseString];
}

static const NSUInteger kFBMaxImageBytes = 64 * 1024 * 1024;

// A zoomable image with a share button. Loads off-main (through launchd for
// root-only files); anything UIImage can't decode falls back to the
// Text / Hex / Info viewer.
@interface FBImageViewController : UIViewController <UIScrollViewDelegate>
- (instancetype)initWithPath:(NSString *)path image:(UIImage *)image viaRoot:(BOOL)viaRoot;
@end

@implementation FBImageViewController {
    NSString *_path;
    UIImage *_image;
    BOOL _viaRoot;
    UIScrollView *_scroll;
    UIImageView *_imageView;
}

- (instancetype)initWithPath:(NSString *)path image:(UIImage *)image viaRoot:(BOOL)viaRoot
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) { _path = [path copy]; _image = image; _viaRoot = viaRoot; }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _path.lastPathComponent;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.delegate = self;
    _scroll.maximumZoomScale = 8;
    [self.view addSubview:_scroll];
    _imageView = [[UIImageView alloc] initWithImage:_image];
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    [_scroll addSubview:_imageView];
    __weak typeof(self) weakSelf = self;
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction primaryAction:nil];
    __weak UIBarButtonItem *weakShare = share;
    share.primaryAction = [UIAction actionWithHandler:^(UIAction *a) {
        typeof(self) me = weakSelf;
        if (!me) return;
        weakShare.enabled = NO;
        filebrowser_share_file(me, me->_path, me->_viaRoot, nil, weakShare, ^{ weakShare.enabled = YES; });
    }];
    self.navigationItem.rightBarButtonItem = share;
    NSString *dims = [NSString stringWithFormat:@"%.0f × %.0f px", _image.size.width * _image.scale, _image.size.height * _image.scale];
    self.navigationItem.prompt = dims;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (_scroll.zoomScale != 1) return;
    _imageView.frame = _scroll.bounds;
    _scroll.contentSize = _scroll.bounds.size;
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView { return _imageView; }

@end

#pragma mark - Clipboard

// One item at a time, shared by every File Browser screen. Cut moves on
// paste and is then cleared; Copy can be pasted repeatedly.
static NSString *g_fb_clip_path;
static BOOL g_fb_clip_cut;

#pragma mark - Subfolder search

static const NSUInteger kFBSearchMaxResults = 300;
static const NSUInteger kFBSearchMaxVisited = 50000;
static const double kFBSearchMaxSeconds = 8.0;

// Names containing `query` below `root` (never following symlinked folders).
// Stops at the limits above or when `stillWanted` says the search is stale.
static NSArray<FBEntry *> *fb_search_tree(NSString *root, NSString *query, BOOL showHidden,
                                          BOOL (^stillWanted)(void), BOOL *truncated)
{
    *truncated = NO;
    NSURL *rootURL = [NSURL fileURLWithPath:root isDirectory:YES];
    NSDirectoryEnumerationOptions opts = showHidden ? 0 : NSDirectoryEnumerationSkipsHiddenFiles;
    NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtURL:rootURL includingPropertiesForKeys:nil
                                                                      options:opts
                                                                 errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
    NSMutableArray<FBEntry *> *found = [NSMutableArray array];
    NSUInteger visited = 0;
    double deadline = CFAbsoluteTimeGetCurrent() + kFBSearchMaxSeconds;
    NSString *base = [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
    for (NSURL *url in en) {
        if (++visited % 256 == 0 && (!stillWanted() || CFAbsoluteTimeGetCurrent() > deadline)) { *truncated = YES; break; }
        if (visited > kFBSearchMaxVisited) { *truncated = YES; break; }
        NSString *name = url.lastPathComponent;
        if ([name rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        NSString *dir = url.path.stringByDeletingLastPathComponent;
        FBEntry *e = fb_entry_at(dir, name);
        NSString *rel = [dir hasPrefix:base] ? [dir substringFromIndex:base.length] : @"";
        e.searchLocation = rel.length ? rel : @".";
        [found addObject:e];
        if (found.count >= kFBSearchMaxResults) { *truncated = YES; break; }
    }
    return found;
}

#pragma mark - Directory list

@interface FileBrowserViewController () <UISearchResultsUpdating, UISearchBarDelegate, UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSArray<FBEntry *> *entries;
@property (nonatomic, strong) NSArray<FBEntry *> *shown;
@property (nonatomic, copy) NSString *filter;
@property (nonatomic, copy) NSString *status;         // shown instead of rows when set
@property (nonatomic, assign) BOOL unlocking;
@property (nonatomic, strong) UISearchController *searchCtrl;
@property (nonatomic, assign) NSUInteger loadedOptionsGeneration;
@property (nonatomic, assign) BOOL loadedViaRoot;   // listed through launchd root (read-only)
@property (nonatomic, assign) NSUInteger reloadRequest;      // newest reload; older results are dropped
@property (nonatomic, assign) NSUInteger loadedFsGeneration;
@property (nonatomic, assign) BOOL listingIncomplete;        // root listing was cut short
@property (nonatomic, strong) FBAppContainer *container;     // the app container this folder is in
@property (nonatomic, strong) FBAppContainer *relatedContainer;   // its bundle <-> data counterpart
@property (nonatomic, strong) NSArray<FBEntry *> *searchResults;   // subfolder search (nil: none)
@property (nonatomic, assign) NSUInteger searchRequest;            // newest subfolder search
@property (nonatomic, assign) BOOL searchTruncated;
@property (nonatomic, assign) BOOL searching;
@end

static NSString * const kFBSortKey = @"FileBrowserSort";   // 0 name, 1 date, 2 size

// In the folders holding app containers: name each UUID folder after its app
// and sort by that name. Off the main thread (reads metadata).
static void fb_annotate_containers(NSString *dir, NSMutableArray<FBEntry *> *entries, BOOL viaRoot)
{
    if (!fb_is_container_parent(dir)) return;
    for (FBEntry *e in entries)
        if (e.isDirectory && !e.isSymlink) e.container = fb_container_for_path(e.path, viaRoot || e.viaRoot);
    [entries sortUsingComparator:^NSComparisonResult(FBEntry *a, FBEntry *b) {
        if ((a.container != nil) != (b.container != nil)) return a.container ? NSOrderedAscending : NSOrderedDescending;
        NSString *na = a.container.displayName ?: a.name, *nb = b.container.displayName ?: b.name;
        return [na localizedStandardCompare:nb];
    }];
}

static NSString *fb_related_title(FBAppContainer *c)
{
    switch (c.kind) {
        case FBContainerKindBundle: return @"Open Data Container";
        case FBContainerKindData:   return @"Open App Bundle";
        case FBContainerKindPlugin: return @"Open App's Data Container";
        default:                    return nil;
    }
}

@implementation FileBrowserViewController

- (instancetype)initWithPath:(NSString *)path
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _path = path.length ? path.copy : @"/";
        _entries = @[];
        _shown = @[];
        _filter = @"";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = [self.path isEqualToString:@"/"] ? @"File Browser" : self.path.lastPathComponent;
    self.navigationItem.prompt = self.path;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;

    self.searchCtrl = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchCtrl.searchResultsUpdater = self;
    self.searchCtrl.obscuresBackgroundDuringPresentation = NO;
    self.searchCtrl.searchBar.placeholder = @"Filter this folder";
    self.searchCtrl.searchBar.scopeButtonTitles = @[ @"This Folder", @"Subfolders" ];
    self.searchCtrl.searchBar.delegate = (id<UISearchBarDelegate>)self;
    self.navigationItem.searchController = self.searchCtrl;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(pullToRefresh) forControlEvents:UIControlEventValueChanged];
    [self reload];
    [self lookUpContainer];
}

- (void)pullToRefresh
{
    if (fb_is_container_parent(self.path)) fb_containers_reset();   // apps may have changed
    [self reload];
}

// Inside an app container: show the app's name and offer its other container.
- (void)lookUpContainer
{
    NSString *path = self.path;
    BOOL viaRoot = [NSUserDefaults.standardUserDefaults boolForKey:kSettingsFileBrowserRootAccess];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FBAppContainer *c = fb_container_for_path(path, viaRoot);
        FBAppContainer *related = c ? fb_related_container(c) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) me = weakSelf;
            if (!me || !c) return;
            me.container = c;
            me.relatedContainer = related;
            if ([fb_canonical_path(path) isEqualToString:c.path]) me.title = c.displayName;
            [me updateBarButtons];
        });
    });
}

- (void)openContainer:(FBAppContainer *)c
{
    if (!c) return;
    FileBrowserViewController *vc = [[FileBrowserViewController alloc] initWithPath:c.path];
    [self.navigationController pushViewController:vc animated:YES];
}

// The other container of entry e's app, looked up off the main thread.
- (void)openRelatedOf:(FBAppContainer *)c
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FBAppContainer *related = fb_related_container(c);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) me = weakSelf;
            if (!me) return;
            if (related) { [me openContainer:related]; return; }
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:c.displayName
                message:@"No matching container was found for this app." preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [me presentViewController:ac animated:YES completion:nil];
        });
    });
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self notifyLeftoverBackupsIfNeeded];
}

// Once per app launch: if a save was interrupted (crash mid-write), say which
// file may be incomplete and where its previous contents are.
- (void)notifyLeftoverBackupsIfNeeded
{
    static BOOL checked = NO;
    if (checked || self.presentedViewController) return;
    checked = YES;
    NSArray<NSString *> *left = fb_leftover_backups();
    if (!left.count) return;
    NSMutableString *list = [NSMutableString string];
    for (NSUInteger i = 0; i < left.count && i < 3; i++) [list appendFormat:@"\n• %@", left[i]];
    if (left.count > 3) [list appendFormat:@"\n…and %lu more", (unsigned long)(left.count - 3)];
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Unfinished Saves"
                         message:[NSString stringWithFormat:@"A save didn't finish (for example because the app or the device stopped mid-write), so these files may be incomplete:%@\n\nTheir previous contents were backed up.", list]
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Show Backups" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        [weakSelf.navigationController pushViewController:
            [[FileBrowserViewController alloc] initWithPath:fb_backup_dir()] animated:YES];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Delete Backups" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) {
        // Both locations: the notice also lists backups in the old temp folder.
        [NSFileManager.defaultManager removeItemAtPath:fb_backup_dir() error:nil];
        [NSFileManager.defaultManager removeItemAtPath:fb_legacy_backup_dir() error:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    fb_suppress_popup_bar(self, YES);
    [self updateBarButtons];   // write mode may have changed on another screen
    if (self.loadedOptionsGeneration != g_fb_options_generation ||
        self.loadedFsGeneration != g_fb_fs_generation) [self reload];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    fb_suppress_popup_bar(self, NO);
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    filebrowser_cancel_shares_for_presenter(self);
}

#pragma mark Write mode

- (void)updateBarButtons
{
    // Options menu: Go to Folder, plus the listing options (both off by
    // default), applied immediately.
    __weak typeof(self) weakOptions = self;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    UIAction *(^option)(NSString *, NSString *) = ^UIAction *(NSString *title, NSString *key) {
        UIAction *a = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *x) {
            [d setBool:![d boolForKey:key] forKey:key];
            g_fb_options_generation++;
            [weakOptions updateBarButtons];
            [weakOptions reload];
        }];
        a.state = [d boolForKey:key] ? UIMenuElementStateOn : UIMenuElementStateOff;
        return a;
    };
    NSMutableArray<UIMenuElement *> *appItems = [NSMutableArray array];
    if (self.container && ![fb_canonical_path(self.path) isEqualToString:self.container.path])
        [appItems addObject:[UIAction actionWithTitle:@"Go to Container Top"
                                                image:[UIImage systemImageNamed:@"arrow.up.to.line"] identifier:nil
                                              handler:^(UIAction *x) { [weakOptions openContainer:weakOptions.container]; }]];
    if (self.relatedContainer && fb_related_title(self.container))
        [appItems addObject:[UIAction actionWithTitle:fb_related_title(self.container)
                                                image:[UIImage systemImageNamed:@"arrow.triangle.swap"] identifier:nil
                                              handler:^(UIAction *x) { [weakOptions openContainer:weakOptions.relatedContainer]; }]];
    UIMenu *optionsMenu = [UIMenu menuWithChildren:@[
        [UIMenu menuWithTitle:self.container.displayName ?: @"" image:nil identifier:nil
                      options:UIMenuOptionsDisplayInline children:appItems],
        [UIAction actionWithTitle:@"Go to Folder…" image:[UIImage systemImageNamed:@"arrow.right.circle"]
                       identifier:nil handler:^(UIAction *x) { [weakOptions goToPath]; }],
        [UIAction actionWithTitle:@"Size of This Folder" image:[UIImage systemImageNamed:@"chart.pie"]
                       identifier:nil handler:^(UIAction *x) { [weakOptions showFolderSize:weakOptions.path]; }],
        [UIMenu menuWithTitle:@"Sort By" image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil options:0 children:({
            NSMutableArray *sorts = [NSMutableArray array];
            NSArray *titles = @[ @"Name", @"Date Modified", @"Size" ];
            NSInteger current = [d integerForKey:kFBSortKey];
            for (NSInteger i = 0; i < 3; i++) {
                UIAction *a = [UIAction actionWithTitle:titles[i] image:nil identifier:nil handler:^(UIAction *x) {
                    [d setInteger:i forKey:kFBSortKey];
                    [weakOptions updateBarButtons];
                    [weakOptions applyFilter];
                }];
                a.state = current == i ? UIMenuElementStateOn : UIMenuElementStateOff;
                [sorts addObject:a];
            }
            sorts;
        })],
        [UIMenu menuWithTitle:@"Show" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
            option(@"Hidden Files", kSettingsFileBrowserShowHidden),
            option(@"Inaccessible Items", kSettingsFileBrowserShowInaccessible),
        ]],
        [UIMenu menuWithTitle:@"Access" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
            option(@"Root Access (read-only)", kSettingsFileBrowserRootAccess),
        ]],
    ]];
    UIBarButtonItem *go = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                            menu:optionsMenu];
    UIBarButtonItem *lock = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:filebrowser_write_enabled() ? @"lock.open.fill" : @"lock.fill"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(toggleWriteMode)];
    lock.tintColor = filebrowser_write_enabled() ? UIColor.systemRedColor : nil;
    lock.accessibilityLabel = filebrowser_write_enabled() ? @"Disable changes" : @"Enable changes";
    NSMutableArray *items = [NSMutableArray arrayWithObjects:go, lock, nil];
    if (filebrowser_write_enabled() && !self.loadedViaRoot) {   // root access is read-only
        __weak typeof(self) weakSelf = self;
        UIMenu *menu = [UIMenu menuWithChildren:@[
            [UIAction actionWithTitle:@"New Folder" image:[UIImage systemImageNamed:@"folder.badge.plus"]
                           identifier:nil handler:^(UIAction *a) { [weakSelf promptNewItem:YES]; }],
            [UIAction actionWithTitle:@"New File" image:[UIImage systemImageNamed:@"doc.badge.plus"]
                           identifier:nil handler:^(UIAction *a) { [weakSelf promptNewItem:NO]; }],
            [UIAction actionWithTitle:@"Import from Files…" image:[UIImage systemImageNamed:@"square.and.arrow.down"]
                           identifier:nil handler:^(UIAction *a) { [weakSelf importFromFiles]; }],
        ]];
        if (g_fb_clip_path.length) {
            NSString *title = [NSString stringWithFormat:@"%@ \"%@\" Here", g_fb_clip_cut ? @"Move" : @"Paste",
                               g_fb_clip_path.lastPathComponent];
            UIAction *paste = [UIAction actionWithTitle:title image:[UIImage systemImageNamed:@"doc.on.clipboard"]
                                             identifier:nil handler:^(UIAction *a) { [weakSelf paste]; }];
            menu = [UIMenu menuWithChildren:[@[ [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                                              options:UIMenuOptionsDisplayInline children:@[ paste ]] ]
                                             arrayByAddingObjectsFromArray:menu.children]];
        }
        [items addObject:[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"] menu:menu]];
    }
    self.navigationItem.rightBarButtonItems = items;
}

- (void)toggleWriteMode
{
    if (filebrowser_write_enabled()) {
        atomic_store_explicit(&g_fb_write_enabled, false, memory_order_release);
        [self updateBarButtons];
        return;
    }
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Enable Changes?"
                         message:@"Delete, rename, create, import and edit will write directly to the file system as user mobile. "
                                 @"Removing or editing the wrong file can break apps or settings, and there is no undo.\n\n"
                                 @"Stays on until you lock it again or Cyanide restarts."
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Enable" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        atomic_store_explicit(&g_fb_write_enabled, true, memory_order_release);
        [self updateBarButtons];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// Runs a file operation; reports a failure, reloads either way.
// Runs a file operation off-main (a recursive delete/copy can take a while);
// reports a failure, then reloads. Write mode is checked again here, at
// execution: a prompt opened before the lock was closed must not still act.
- (void)perform:(BOOL (^)(NSError **err))op failureTitle:(NSString *)title
{
    if (!filebrowser_write_enabled() || self.loadedViaRoot) {
        fb_alert(self, title, @"Changes are locked.");
        return;
    }
    dispatch_async(fb_file_queue(), ^{
        NSError *err = nil;
        // Re-check when the job actually starts: locking while it was queued
        // cancels it. (A job that has started is left to finish.)
        BOOL ok = NO;
        if (filebrowser_write_enabled()) ok = op(&err);
        else err = fb_locked_error();
        NSString *message = err.localizedDescription;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) filebrowser_note_filesystem_changed();
            else fb_alert(self, title, message ?: @"The operation failed.");
            [self reload];
        });
    });
}

- (void)performForEntry:(FBEntry *)entry operation:(BOOL (^)(NSError **err))op
           failureTitle:(NSString *)title
{
    // An entry readable only through launchd root is view-only, even in a
    // folder mobile can list: root access is read-only.
    if (entry.viaRoot) {
        fb_alert(self, title, @"This item is only readable as root, and root access is read-only.");
        return;
    }
    [self perform:^BOOL(NSError **err) {
        if (entry.viaRoot) {   // re-checked in the worker
            if (err) *err = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM
                                   userInfo:@{ NSLocalizedDescriptionKey: @"This item is only readable as root, and root access is read-only." }];
            return NO;
        }
        if (!fb_entry_still_matches(entry, err)) return NO;
        return op(err);
    } failureTitle:title];
}

- (void)promptNewItem:(BOOL)folder
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:folder ? @"New Folder" : @"New File"
                                                                message:self.path
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = folder ? @"Folder name" : @"File name";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!name.length || [name containsString:@"/"]) return;
        NSString *path = [self.path stringByAppendingPathComponent:name];
        [self perform:^BOOL(NSError **err) {
            if (access(path.fileSystemRepresentation, F_OK) == 0) {
                if (err) *err = [NSError errorWithDomain:NSPOSIXErrorDomain code:EEXIST
                                       userInfo:@{ NSLocalizedDescriptionKey: @"An item with that name already exists." }];
                return NO;
            }
            if (folder)
                return [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO
                                                                attributes:nil error:err];
            if ([NSData.data writeToFile:path options:NSDataWritingWithoutOverwriting error:err]) return YES;
            return NO;
        } failureTitle:folder ? @"Couldn't Create Folder" : @"Couldn't Create File"];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)promptRename:(FBEntry *)e
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Rename"
                                                                message:e.path
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = e.name;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!name.length || [name containsString:@"/"] || [name isEqualToString:e.name]) return;
        NSString *target = [self.path stringByAppendingPathComponent:name];
        [self performForEntry:e operation:^BOOL(NSError **err) {
            return [NSFileManager.defaultManager moveItemAtPath:e.path toPath:target error:err];
        } failureTitle:@"Couldn't Rename"];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)duplicate:(FBEntry *)e
{
    NSString *dir = self.path;
    [self performForEntry:e operation:^BOOL(NSError **err) {
        // Picked on the file queue, so two quick duplicates get two names.
        NSString *target = fb_unique_path(dir, e.name);
        return [NSFileManager.defaultManager copyItemAtPath:e.path toPath:target error:err];
    } failureTitle:@"Couldn't Duplicate"];
}

- (void)confirmDelete:(FBEntry *)e
{
    NSString *what = e.isDirectory && !e.isSymlink
        ? [NSString stringWithFormat:@"The folder \"%@\" and everything in it will be deleted.", e.name]
        : [NSString stringWithFormat:@"\"%@\" will be deleted.", e.name];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Delete?"
                                                                message:[what stringByAppendingString:@" This can't be undone."]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self performForEntry:e operation:^BOOL(NSError **err) {
            // A symlink is removed itself, never what it points to.
            return [NSFileManager.defaultManager removeItemAtPath:e.path error:err];
        } failureTitle:@"Couldn't Delete"];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)setClipboard:(FBEntry *)e cut:(BOOL)cut
{
    g_fb_clip_path = [e.path copy];
    g_fb_clip_cut = cut;
    [self updateBarButtons];
}

// Pastes the clipboard item into this folder: a copy, or for Cut a move
// (then the clipboard is cleared). Never into itself or below itself.
- (void)paste
{
    NSString *src = g_fb_clip_path;
    BOOL cut = g_fb_clip_cut;
    if (!src.length) return;
    NSString *dir = self.path;
    NSString *srcSlash = [fb_canonical_path(src) stringByAppendingString:@"/"];
    if ([[fb_canonical_path(dir) stringByAppendingString:@"/"] hasPrefix:srcSlash]) {
        fb_alert(self, @"Can't Paste", @"A folder can't be pasted into itself.");
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self perform:^BOOL(NSError **err) {
        struct stat st;
        if (lstat(src.fileSystemRepresentation, &st) != 0) {
            if (err) *err = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT
                                   userInfo:@{ NSLocalizedDescriptionKey: @"The copied item no longer exists." }];
            return NO;
        }
        // Moving within the same folder would only rename it to "name 2".
        if (cut && [fb_canonical_path(src.stringByDeletingLastPathComponent) isEqualToString:fb_canonical_path(dir)]) return YES;
        NSString *target = fb_unique_path(dir, src.lastPathComponent);
        NSFileManager *fm = NSFileManager.defaultManager;
        BOOL ok = cut ? [fm moveItemAtPath:src toPath:target error:err] : [fm copyItemAtPath:src toPath:target error:err];
        if (ok && cut) dispatch_async(dispatch_get_main_queue(), ^{
            if ([g_fb_clip_path isEqualToString:src]) g_fb_clip_path = nil;
            [weakSelf updateBarButtons];
        });
        return ok;
    } failureTitle:cut ? @"Couldn't Move" : @"Couldn't Paste"];
}

// chmod for items mobile owns (mobile can't change anyone else's).
- (void)promptPermissions:(FBEntry *)e
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Permissions"
        message:[NSString stringWithFormat:@"%@\nCurrent: %@ (%03o). Enter the new mode in octal, e.g. 644 or 755.",
                 e.name, fb_mode_string(e.mode, e.isSymlink), e.mode & 07777]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [NSString stringWithFormat:@"%03o", e.mode & 07777];
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = ac.textFields.firstObject.text;
        unsigned long long value = 0;
        BOOL octal = text.length >= 3 && text.length <= 4 &&
                     [text rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"01234567"] invertedSet]].location == NSNotFound;
        if (!octal) { fb_alert(self, @"Invalid Mode", @"Enter 3 or 4 octal digits, e.g. 644."); return; }
        for (NSUInteger i = 0; i < text.length; i++) value = value * 8 + (unsigned)([text characterAtIndex:i] - '0');
        mode_t mode = (mode_t)(value & 07777);
        [self performForEntry:e operation:^BOOL(NSError **err) {
            if (chmod(e.path.fileSystemRepresentation, mode) == 0) return YES;
            if (err) *err = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return NO;
        } failureTitle:@"Couldn't Change Permissions"];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)importFromFiles
{
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem, UTTypeFolder ] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    // The lock may have been closed while the picker was open.
    if (!filebrowser_write_enabled() || self.loadedViaRoot) {
        fb_alert(self, @"Not Imported", @"Changes are locked.");
        return;
    }
    NSString *dir = self.path;
    dispatch_async(fb_file_queue(), ^{
        NSMutableArray<NSString *> *failed = [NSMutableArray array];
        NSUInteger importedItems = 0;
        unsigned long long importedBytes = 0;
        BOOL changed = NO;
        for (NSURL *url in urls) {
            if (!filebrowser_write_enabled()) {   // locked mid-import: stop before the next item
                [failed addObject:[NSString stringWithFormat:@"%@: changes were locked", url.lastPathComponent]];
                continue;
            }
            NSString *target = fb_unique_path(dir, url.lastPathComponent);
            NSString *failure = nil;
            if (fb_import_copy_path(url.path, target, &importedItems, &importedBytes, &failure)) {
                changed = YES;
            } else {
                // Foundation/provider copies can leave a destination behind
                // after an error.  The bounded helper may have created part
                // of a tree; always remove it before reporting incomplete.
                struct stat partial;
                if (lstat(target.fileSystemRepresentation, &partial) == 0) {
                    changed = YES;
                    NSError *cleanupError = nil;
                    [NSFileManager.defaultManager removeItemAtPath:target error:&cleanupError];
                    if (lstat(target.fileSystemRepresentation, &partial) == 0)
                        failure = [NSString stringWithFormat:@"%@ Cleanup failed: %@", failure ?: @"Import failed.", cleanupError.localizedDescription ?: @"the partial item remains"];
                }
                [failed addObject:[NSString stringWithFormat:@"%@: %@", url.lastPathComponent,
                                   failure ?: @"Import failed."]];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (changed) filebrowser_note_filesystem_changed();
            if (failed.count) fb_alert(self, @"Import Incomplete", [failed componentsJoinedByString:@"\n"]);
            [self reload];
        });
    });
}

// Each reload is a request: options are captured on main, and only the
// newest request may publish. An older listing that finishes late (e.g. a
// slow root listing after Root Access was turned off, or a pre-delete
// listing) is dropped instead of overwriting the current state.
- (void)reload
{
    // The generations are marked loaded only when this request's result is
    // accepted (below), not when it starts.
    NSUInteger optionsGen = g_fb_options_generation;
    NSUInteger fsGen = g_fb_fs_generation;
    NSUInteger request = ++self.reloadRequest;
    if (!settings_filesystem_access_available()) {
        [self unlockThenReload];
        return;
    }
    NSString *path = self.path;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL showHidden = [d boolForKey:kSettingsFileBrowserShowHidden];
    BOOL showInaccessible = [d boolForKey:kSettingsFileBrowserShowInaccessible];
    BOOL rootOn = [d boolForKey:kSettingsFileBrowserRootAccess];
    __weak typeof(self) weakSelf = self;
    void (^publish)(NSArray<FBEntry *> *, NSString *, BOOL, BOOL) =
        ^(NSArray<FBEntry *> *entries, NSString *status, BOOL viaRoot, BOOL incomplete) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) me = weakSelf;
            if (!me || request != me.reloadRequest) return;   // superseded
            // Options (e.g. Root Access) changed while this ran — possibly on
            // another screen, without a new request here: drop the result;
            // reload now if visible, otherwise on the next appearance.
            if (optionsGen != g_fb_options_generation) {
                if (me.view.window) [me reload];
                return;
            }
            if (fsGen != g_fb_fs_generation) {
                // A filesystem operation completed while this result was
                // being enumerated.  Do not mark the old rows current; a
                // visible controller immediately requests a fresh listing.
                if (me.view.window) [me reload];
                return;
            }
            me.loadedOptionsGeneration = optionsGen;
            me.loadedFsGeneration = fsGen;
            me.loadedViaRoot = viaRoot;
            me.navigationItem.prompt = viaRoot ? [me.path stringByAppendingString:@" · read as root"] : me.path;
            me.entries = entries;
            me.status = status;
            me.listingIncomplete = incomplete;
            [me applyFilter];
            [me updateBarButtons];
            [me.refreshControl endRefreshing];
        });
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSComparisonResult (^order)(FBEntry *, FBEntry *) = ^NSComparisonResult(FBEntry *a, FBEntry *b) {
            if (a.isDirectory != b.isDirectory) return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
            return [a.name localizedStandardCompare:b.name];
        };
        NSError *err = nil;
        BOOL ordinaryIncomplete = NO;
        NSArray<NSString *> *names = fb_bounded_directory_names(path, &ordinaryIncomplete, &err);
        NSString *status = nil;

        // Not readable as mobile and root access is on: list it through launchd.
        if (!names && rootOn) {
            NSString *rootErr = nil;
            BOOL incomplete = NO;
            NSArray<NSDictionary *> *rootEntries = settings_root_list_directory(path, &incomplete, &rootErr);
            if (rootEntries) {
                NSUInteger filteredOut = 0;
                NSMutableArray<FBEntry *> *entries = [NSMutableArray arrayWithCapacity:rootEntries.count];
                for (NSDictionary *info in rootEntries) {
                    NSString *name = info[@"name"];
                    if (!showHidden && [name hasPrefix:@"."]) { filteredOut++; continue; }
                    [entries addObject:fb_entry_from_root_dict(path, info)];
                }
                [entries sortUsingComparator:order];
                fb_annotate_containers(path, entries, YES);
                NSString *rstatus = nil;
                if (!rootEntries.count) rstatus = incomplete ? @"The folder could not be read completely." : @"Empty folder.";
                else if (!entries.count) rstatus = [NSString stringWithFormat:@"%lu hidden item%@ (root). The ⋯ menu can show them.",
                                                    (unsigned long)filteredOut, filteredOut == 1 ? @"" : @"s"];
                publish(entries, rstatus, YES, incomplete);
                return;
            }
            status = rootErr ?: @"This folder is not readable, even as root.";
        }

        // Hidden (dot) and unreadable items are left out unless enabled in
        // the options (⋯) menu.
        NSUInteger filteredOut = 0;
        NSMutableArray<FBEntry *> *entries = [NSMutableArray arrayWithCapacity:names.count];
        for (NSString *name in names) {
            if (!showHidden && [name hasPrefix:@"."]) { filteredOut++; continue; }
            FBEntry *e = fb_entry_at(path, name);
            // With root access on, an item mobile can't read is exactly what
            // root can open: keep it, and route it through launchd.
            if (rootOn && !e.readable && !e.statFailed) {
                e.readable = YES;
                e.viaRoot = YES;
                e.rootUnlocked = YES;
            }
            if (!showInaccessible && (!e.readable || e.statFailed)) { filteredOut++; continue; }
            [entries addObject:e];
        }
        [entries sortUsingComparator:order];
        fb_annotate_containers(path, entries, NO);
        if (!names && !status) {
            // The bounded readdir listing returns a POSIX error directly;
            // NSFileManager wrapped it as the underlying error. Accept both.
            NSError *posix = [err.domain isEqualToString:NSPOSIXErrorDomain] ? err
                                                                              : err.userInfo[NSUnderlyingErrorKey];
            NSInteger code = [posix.domain isEqualToString:NSPOSIXErrorDomain] ? posix.code : 0;
            if (code == ENOENT || err.code == NSFileReadNoSuchFileError)
                status = @"This folder does not exist.";
            else if (code == ENOTDIR)
                status = @"Not a folder.";
            else if (code == EACCES || code == EPERM || err.code == NSFileReadNoPermissionError)
                status = @"Permission denied. Turn on Root Access (read-only) in the ⋯ menu to read it as root.";
            else
                status = err.localizedDescription ?: @"Couldn't read this folder.";
        } else if (!names) {
            // status already set by the root fallback above
        } else if (!names.count) {
            status = @"Empty folder.";
        } else if (!entries.count) {
            status = [NSString stringWithFormat:@"%lu hidden or inaccessible item%@. The ⋯ menu can show them.",
                      (unsigned long)filteredOut, filteredOut == 1 ? @"" : @"s"];
        }
        if (ordinaryIncomplete) {
            status = [NSString stringWithFormat:@"Listing incomplete: the first %lu entries are shown.",
                      (unsigned long)kFBMaxOrdinaryEntries];
        }
        publish(entries, status, NO, ordinaryIncomplete);
    });
}

- (void)unlockThenReload
{
    [self unlockThenReloadAllowingFullExploit:NO];
}

// Live or parked kernel access, or (except on A18/M4) a fresh run. When only
// a run the user starts would do, the shared Run Exploit popup and banner.
- (void)unlockThenReloadAllowingFullExploit:(BOOL)allowFullExploit
{
    (void)allowFullExploit;
    [self.refreshControl endRefreshing];
    if (self.unlocking) return;
    self.unlocking = YES;
    self.status = @"Lifting the filesystem sandbox through SpringBoard… (one time per app launch)";
    [self applyFilter];
    __weak typeof(self) weakSelf = self;
    settings_unlock_filesystem_async(NO, ^(BOOL ok, NSString *message) {
        typeof(self) s = weakSelf;
        if (!s) return;
        s.unlocking = NO;
        if (ok) {
            [s reload];
            return;
        }
        BOOL needsRun = [message isEqualToString:kSettingsFullExploitRequiredMessage];
        s.status = needsRun ? kSettingsNoKernelAccessHint : (message ?: @"Filesystem access is not available.");
        [s applyFilter];
        if (needsRun) {
            settings_tool_needs_exploit(s, s.tableView, @"The File Browser", ^{
                [weakSelf unlockThenReloadAllowingFullExploit:NO];
            });
        }
    });
}

- (BOOL)searchingSubfolders
{
    return self.searchCtrl.searchBar.selectedScopeButtonIndex == 1 &&
           [self.filter stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length > 0;
}

// Folders first, then by the chosen order (name keeps the listing's order,
// which in app-container folders is by app name).
- (NSArray<FBEntry *> *)sorted:(NSArray<FBEntry *> *)entries
{
    NSInteger sort = [NSUserDefaults.standardUserDefaults integerForKey:kFBSortKey];
    if (sort == 0) return entries;
    return [entries sortedArrayUsingComparator:^NSComparisonResult(FBEntry *a, FBEntry *b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        if (sort == 1) {
            NSComparisonResult r = [b.modified ?: NSDate.distantPast compare:a.modified ?: NSDate.distantPast];
            if (r != NSOrderedSame) return r;
        } else if (a.size != b.size) {
            return a.size > b.size ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.name localizedStandardCompare:b.name];
    }];
}

- (void)applyFilter
{
    NSString *q = [self.filter stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([self searchingSubfolders]) {
        self.shown = [self sorted:self.searchResults ?: @[]];
        UILabel *note = nil;
        if (self.searchTruncated && self.shown.count) {
            note = [UILabel new];
            note.text = [NSString stringWithFormat:@"Showing the first %lu matches (search stops at %lu results, %lu entries or %.0f s). Narrow the search or start deeper.",
                         (unsigned long)self.shown.count, (unsigned long)kFBSearchMaxResults,
                         (unsigned long)kFBSearchMaxVisited, kFBSearchMaxSeconds];
            note.font = [UIFont systemFontOfSize:13];
            note.textColor = UIColor.secondaryLabelColor;
            note.numberOfLines = 0;
            note.textAlignment = NSTextAlignmentCenter;
            note.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 64);
        }
        self.tableView.tableFooterView = note;
        [self.tableView reloadData];
        return;
    }
    if (!q.length) {
        self.shown = [self sorted:self.entries];
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(FBEntry *e, NSDictionary *b) {
            if ([e.name rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
            // Messaging nil gives location 0, which would match everything.
            if (!e.container) return NO;
            return [e.container.displayName rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [e.container.identifier rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        self.shown = [self sorted:[self.entries filteredArrayUsingPredicate:p]];
    }
    // A cut-short listing is a prefix of the folder, not all of it.
    if (self.listingIncomplete && self.entries.count) {
        UILabel *note = [UILabel new];
        note.text = [NSString stringWithFormat:@"Listing incomplete: only %lu entries are shown; reload or narrow the folder.",
                     (unsigned long)self.entries.count];
        note.font = [UIFont systemFontOfSize:13];
        note.textColor = UIColor.systemOrangeColor;
        note.numberOfLines = 0;
        note.textAlignment = NSTextAlignmentCenter;
        note.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 52);
        self.tableView.tableFooterView = note;
    } else {
        self.tableView.tableFooterView = nil;
    }
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    self.filter = searchController.searchBar.text ?: @"";
    if ([self searchingSubfolders]) [self startSubfolderSearch];
    else { self.searchResults = nil; self.searching = NO; }
    [self applyFilter];
}

- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope
{
    searchBar.placeholder = selectedScope == 1 ? @"Search this folder and below" : @"Filter this folder";
    [self updateSearchResultsForSearchController:self.searchCtrl];
}

// Debounced, off-main; only the newest search may publish.
- (void)startSubfolderSearch
{
    NSString *q = [self.filter stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSUInteger request = ++self.searchRequest;
    self.searching = YES;
    self.searchResults = nil;
    if (self.loadedViaRoot) {   // the walk runs as mobile; a root-only folder can't be searched
        self.searching = NO;
        self.searchResults = @[];   // shown as "No matches"; the walk can't read root-only folders
        return;
    }
    NSString *root = self.path;
    BOOL showHidden = [NSUserDefaults.standardUserDefaults boolForKey:kSettingsFileBrowserShowHidden];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.searchRequest != request) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL truncated = NO;
            NSArray *found = fb_search_tree(root, q, showHidden, ^BOOL{ return weakSelf.searchRequest == request; }, &truncated);
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) me = weakSelf;
                if (!me || me.searchRequest != request) return;
                me.searching = NO;
                me.searchResults = found;
                me.searchTruncated = truncated;
                [me applyFilter];
            });
        });
    });
}

- (void)goToPath
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Go to Folder"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = self.path;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Go" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *target = [ac.textFields.firstObject.text stringByStandardizingPath];
        if (!target.length) return;
        FileBrowserViewController *vc = [[FileBrowserViewController alloc] initWithPath:target];
        [self.navigationController pushViewController:vc animated:YES];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.shown.count ? (NSInteger)self.shown.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"fb"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"fb"];
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.textLabel.textColor = UIColor.labelColor;

    if (!self.shown.count) {
        cell.textLabel.text = [self searchingSubfolders]
            ? (self.searching ? @"Searching…" : @"No matches in this folder or below.")
            : (self.status ?: (self.filter.length ? @"No matches." : @"Loading…"));
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.text = nil;
        cell.imageView.image = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    FBEntry *e = self.shown[indexPath.row];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.text = e.isSymlink && e.linkTarget
        ? [NSString stringWithFormat:@"%@ → %@", e.name, e.linkTarget] : e.name;
    if (e.container) {
        // An app container: its app's name and icon, identifier and UUID below.
        cell.textLabel.text = e.container.displayName;
        cell.detailTextLabel.text = [e.container.displayName isEqualToString:e.container.identifier]
            ? e.name : [NSString stringWithFormat:@"%@ · %@", e.container.identifier, e.name];
        cell.imageView.image = e.container.icon ?: [UIImage systemImageNamed:@"folder.fill"];
        cell.imageView.tintColor = UIColor.systemBlueColor;
        cell.textLabel.textColor = UIColor.labelColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if (e.searchLocation) {
        cell.detailTextLabel.text = [@"in " stringByAppendingString:e.searchLocation];
    } else if (e.statFailed) {
        cell.detailTextLabel.text = @"(no information)";
    } else {
        NSString *size = e.isDirectory ? @"" : [fb_size_string(e.size) stringByAppendingString:@"  "];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@  %@ %@",
                                     size, fb_date_string(e.modified),
                                     fb_mode_string(e.mode, e.isSymlink), fb_user_name(e.uid)];
    }
    NSString *icon = !e.readable ? @"lock.fill"
                   : e.rootUnlocked ? @"lock.open.fill"
                   : e.isDirectory ? (e.isSymlink ? @"folder.badge.questionmark" : @"folder.fill")
                   : e.isSymlink ? @"link" : @"doc";
    cell.imageView.image = [UIImage systemImageNamed:icon];
    cell.imageView.tintColor = !e.readable ? UIColor.systemGrayColor
                             : e.rootUnlocked ? UIColor.systemOrangeColor
                             : e.isDirectory ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
    cell.textLabel.textColor = e.readable ? UIColor.labelColor : UIColor.secondaryLabelColor;
    cell.accessoryType = e.isDirectory ? UITableViewCellAccessoryDisclosureIndicator
                                       : UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.shown.count) {
        if (!settings_filesystem_access_available()) [self unlockThenReload];
        return;
    }
    FBEntry *e = self.shown[indexPath.row];
    if (e.isDirectory) {
        [self.navigationController pushViewController:[[FileBrowserViewController alloc] initWithPath:e.path]
                                             animated:YES];
        return;
    }
    // Probing and parsing a plist happens off-main (a FIFO or a huge file
    // must never stall the UI); the screen is pushed when that's done.
    NSString *path = e.path;
    BOOL viaRoot = e.viaRoot;
    NSString *ext = path.pathExtension.lowercaseString;
    BOOL plistExt = [ext isEqualToString:@"plist"] || [ext isEqualToString:@"strings"];
    tableView.userInteractionEnabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id doc = nil;
        if (viaRoot) {
            // Root-only plist: read it through launchd, view it read-only.
            // Without a plist extension, a binary plist is recognized by
            // its first 8 bytes.
            BOOL maybePlist = plistExt;
            if (!maybePlist) {
                NSData *head = settings_root_read_file(path, 8, NULL, NULL);
                maybePlist = head.length == 8 && memcmp(head.bytes, "bplist00", 8) == 0;
            }
            if (maybePlist) {
                BOOL truncated = NO;
                NSData *data = settings_root_read_file(path, 10 * 1024 * 1024 + 1, &truncated, NULL);
                if (data && !truncated) doc = [PlistEditorViewController readOnlyDocumentForData:data path:path];
            }
        } else if (e.readable && fb_looks_like_plist(path)) {
            doc = [PlistEditorViewController documentForFileAtPath:path];
        }
        UIImage *image = nil;
        if (!doc && fb_is_image_path(path) && (e.readable || viaRoot) && e.size <= (off_t)kFBMaxImageBytes) {
            NSData *data = viaRoot ? settings_root_read_file(path, kFBMaxImageBytes, NULL, NULL)
                                   : [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
            image = data ? [UIImage imageWithData:data] : nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            tableView.userInteractionEnabled = YES;
            // The user may have navigated away (Back/tab) meanwhile.
            if (!self.view.window || self.navigationController.topViewController != self) return;
            UIViewController *vc = doc ? [PlistEditorViewController editorWithDocument:doc] : nil;
            if (!vc && image) vc = [[FBImageViewController alloc] initWithPath:path image:image viaRoot:viaRoot];
            if (!vc) vc = [[FBFileViewController alloc] initWithEntry:e];
            [self.navigationController pushViewController:vc animated:YES];
        });
    });
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!filebrowser_write_enabled() || self.loadedViaRoot || !self.shown.count) return nil;
    FBEntry *e = self.shown[indexPath.row];
    if (e.viaRoot) return nil;   // root-only item: view-only
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"Delete"
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self confirmDelete:e];
        done(YES);
    }];
    UIContextualAction *ren = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                      title:@"Rename"
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self promptRename:e];
        done(YES);
    }];
    ren.backgroundColor = UIColor.systemBlueColor;
    UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:@[ del, ren ]];
    cfg.performsFirstActionWithFullSwipe = NO;   // a full swipe must not delete
    return cfg;
}

// Folder Size: a progress alert with Cancel, then the totals.
- (void)showFolderSize:(NSString *)path
{
    BOOL rootOn = [NSUserDefaults.standardUserDefaults boolForKey:kSettingsFileBrowserRootAccess];
    FBSizeJob *job = [FBSizeJob new];
    atomic_init(&job->cancelled, false);
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:path.lastPathComponent.length ? path.lastPathComponent : path
                                                                  message:@"Counting…"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [wait addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        atomic_store(&job->cancelled, true);
    }]];
    [self presentViewController:wait animated:YES completion:nil];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakWait = wait;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        fb_measure_folder(path, rootOn, job, ^(unsigned long long items) {
            NSString *text = [NSString stringWithFormat:@"Counting… %@ items, %@ so far",
                              [NSNumberFormatter localizedStringFromNumber:@(items) numberStyle:NSNumberFormatterDecimalStyle],
                              fb_size_string((off_t)job.allocated)];
            dispatch_async(dispatch_get_main_queue(), ^{ weakWait.message = text; });
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            if (atomic_load(&job->cancelled)) return;
            typeof(self) me = weakSelf;
            UIAlertController *shown = weakWait;
            void (^showResult)(void) = ^{
                if (!me) return;
                NSString *(^count)(unsigned long long) = ^NSString *(unsigned long long n) {
                    return [NSNumberFormatter localizedStringFromNumber:@(n) numberStyle:NSNumberFormatterDecimalStyle];
                };
                NSMutableString *msg = [NSMutableString stringWithFormat:@"%@ on disk\n%@ of data\n%@ files in %@ folders",
                    fb_size_string((off_t)job.allocated), fb_size_string((off_t)job.logical),
                    count(job.files), count(job.folders)];
                if (job.unreadable)
                    [msg appendFormat:@"\n\n%@ folder%@ could not be read%@.", count(job.unreadable), job.unreadable == 1 ? @"" : @"s",
                     rootOn ? @"" : @" (turn on Root Access in ⋯ to include them)"];
                if (job.viaRoot)
                    [msg appendFormat:@"\n\n%@ folder%@ read as root; their on-disk size is estimated.", count(job.viaRoot),
                     job.viaRoot == 1 ? @"" : @"s"];
                if (job.incomplete) [msg appendString:@"\n\nSome folders could not be listed completely; the real size is larger."];
                UIAlertController *done = [UIAlertController alertControllerWithTitle:path.lastPathComponent.length ? path.lastPathComponent : path
                                                                              message:msg
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                    UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"%@\n%@", path, msg];
                }]];
                [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
                [me presentViewController:done animated:YES completion:nil];
            };
            if (shown.presentingViewController) [shown dismissViewControllerAnimated:YES completion:showResult];
            else showResult();
        });
    });
}

// Long-press: copy the full path (and the write actions when enabled).
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                        point:(CGPoint)point
{
    if (!self.shown.count) return nil;
    FBEntry *e = self.shown[indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *copy = [UIAction actionWithTitle:@"Copy Path"
                                             image:[UIImage systemImageNamed:@"doc.on.doc"]
                                        identifier:nil
                                           handler:^(UIAction *a) { UIPasteboard.generalPasteboard.string = e.path; }];
        UIAction *info = [UIAction actionWithTitle:@"Open as Text / Hex / Info"
                                             image:[UIImage systemImageNamed:@"info.circle"]
                                        identifier:nil
                                           handler:^(UIAction *a) {
            FBFileViewController *vc = [[FBFileViewController alloc] initWithEntry:e];
            [self.navigationController pushViewController:vc animated:YES];
        }];
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray arrayWithObject:copy];
        if (e.isDirectory && !e.isSymlink && !e.statFailed)
            [items addObject:[UIAction actionWithTitle:@"Folder Size" image:[UIImage systemImageNamed:@"chart.pie"]
                                            identifier:nil handler:^(UIAction *a) { [self showFolderSize:e.path]; }]];
        if (!e.isDirectory) {
            [items addObject:info];
            // AirDrop, Mail, Save to Files … a copy, never the original.
            [items addObject:[UIAction actionWithTitle:@"Share…" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                            identifier:nil handler:^(UIAction *a) {
                UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
                filebrowser_share_file(self, e.path, e.viaRoot, nil, cell, nil);
            }]];
        }
        FBAppContainer *c = e.container;
        if (c) {
            NSString *relatedTitle = fb_related_title(c);
            if (relatedTitle)
                [items insertObject:[UIAction actionWithTitle:relatedTitle image:[UIImage systemImageNamed:@"arrow.triangle.swap"]
                                                   identifier:nil handler:^(UIAction *a) { [self openRelatedOf:c]; }]
                            atIndex:0];
            [items addObject:[UIAction actionWithTitle:@"Copy Identifier" image:[UIImage systemImageNamed:@"number"]
                                            identifier:nil handler:^(UIAction *a) {
                UIPasteboard.generalPasteboard.string = c.identifier;
            }]];
        }
        if (e.searchLocation) {
            NSString *folder = e.path.stringByDeletingLastPathComponent;
            [items insertObject:[UIAction actionWithTitle:@"Show in Folder" image:[UIImage systemImageNamed:@"folder"]
                                               identifier:nil handler:^(UIAction *a) {
                [self.navigationController pushViewController:[[FileBrowserViewController alloc] initWithPath:folder]
                                                     animated:YES];
            }] atIndex:0];
        }
        // Copy works without write mode (pasting needs it); a root-only item
        // can't be copied as mobile.
        NSMutableArray<UIMenuElement *> *clip = [NSMutableArray array];
        if (!e.viaRoot && e.readable && !self.loadedViaRoot)
            [clip addObject:[UIAction actionWithTitle:@"Copy" image:[UIImage systemImageNamed:@"doc.on.doc.fill"]
                                           identifier:nil handler:^(UIAction *a) { [self setClipboard:e cut:NO]; }]];
        if (filebrowser_write_enabled() && !self.loadedViaRoot && !e.viaRoot) {
            [clip addObject:[UIAction actionWithTitle:@"Cut" image:[UIImage systemImageNamed:@"scissors"]
                                           identifier:nil handler:^(UIAction *a) { [self setClipboard:e cut:YES]; }]];
        }
        if (clip.count)
            [items addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:clip]];
        if (filebrowser_write_enabled() && !self.loadedViaRoot && !e.viaRoot) {
            UIAction *ren = [UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"]
                                           identifier:nil handler:^(UIAction *a) { [self promptRename:e]; }];
            UIAction *dup = [UIAction actionWithTitle:@"Duplicate" image:[UIImage systemImageNamed:@"plus.square.on.square"]
                                           identifier:nil handler:^(UIAction *a) { [self duplicate:e]; }];
            NSMutableArray *edit = [NSMutableArray arrayWithObjects:ren, dup, nil];
            if (!e.statFailed && e.uid == getuid() && !e.isSymlink)
                [edit addObject:[UIAction actionWithTitle:@"Permissions…" image:[UIImage systemImageNamed:@"lock.shield"]
                                               identifier:nil handler:^(UIAction *a) { [self promptPermissions:e]; }]];
            UIAction *del = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"]
                                           identifier:nil handler:^(UIAction *a) { [self confirmDelete:e]; }];
            del.attributes = UIMenuElementAttributesDestructive;
            [edit addObject:del];
            [items addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil
                                           options:UIMenuOptionsDisplayInline children:edit]];
        }
        return [UIMenu menuWithTitle:c ? [NSString stringWithFormat:@"%@\n%@", c.displayName, e.path] : e.path
                            children:items];
    }];
}

@end
