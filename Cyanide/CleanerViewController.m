//
//  CleanerViewController.m
//  Cyanide
//

#import "CleanerCustomTargets.h"
#import "CleanerViewController.h"
#import "FBAppContainers.h"
#import "SettingsViewController.h"
#import "FileBrowserViewController.h"
#import "installer/MainTabBarController.h"
#import <sys/stat.h>
#import <errno.h>
#import <unistd.h>
#import <fcntl.h>
#import <dirent.h>
#import <string.h>
#import <time.h>

static NSString * const kCleanerAppDataPrefix =
    @"/private/var/mobile/Containers/Data/Application/";
static const NSUInteger kCleanerMaxScanEntries = 250000;
static const NSUInteger kCleanerMaxTraversalDepth = 64;
static const double kCleanerMaxScanSeconds = 15;
static const double kCleanerMaxCleanSeconds = 60;

static BOOL cleaner_scan_should_restart(BOOL stale, BOOL loading, BOOL cleaning,
                                        BOOL visible, BOOL foreground, BOOL accessReady)
{
    return stale && !loading && !cleaning && visible && foreground && accessReady;
}

static void cleaner_suppress_popup_bar(UIViewController *vc, BOOL suppressed)
{
    UITabBarController *tbc = vc.tabBarController;
    if ([tbc isKindOfClass:MainTabBarController.class])
        [(MainTabBarController *)tbc setPopupBarSuppressed:suppressed];
}

static NSString *cleaner_bytes(unsigned long long bytes)
{
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

static BOOL cleaner_path_is_app_data(NSString *path)
{
    NSString *canonical = fb_canonical_path(path);
    return canonical.length > kCleanerAppDataPrefix.length &&
           [canonical hasPrefix:kCleanerAppDataPrefix];
}

// Admit only a UUID container's two exact disposable roots, not any nested
// directory whose last component happens to be tmp or Library/Caches.
static BOOL cleaner_is_disposable_root(NSString *path)
{
    if (!cleaner_path_is_app_data(path)) return NO;
    NSString *relative = [fb_canonical_path(path) substringFromIndex:kCleanerAppDataPrefix.length];
    NSArray<NSString *> *parts = relative.pathComponents;
    if (parts.count < 2 || ![[NSUUID alloc] initWithUUIDString:parts[0]]) return NO;
    return (parts.count == 2 && [parts[1] isEqualToString:@"tmp"]) ||
           (parts.count == 3 && [parts[1] isEqualToString:@"Library"] &&
            [parts[2] isEqualToString:@"Caches"]);
}

static BOOL cleaner_is_app_container(NSString *path)
{
    if (!cleaner_path_is_app_data(path)) return NO;
    NSString *relative = [fb_canonical_path(path) substringFromIndex:kCleanerAppDataPrefix.length];
    NSArray<NSString *> *parts = relative.pathComponents;
    return parts.count == 1 && [[NSUUID alloc] initWithUUIDString:parts[0]] != nil;
}

// Crash reports are the only non-app roots Cleaner may touch. Keep this list
// exact: no broad Library/Logs walk and no caller-supplied path.
static NSArray<NSString *> *cleaner_crash_log_roots(void)
{
    return @[
        @"/private/var/mobile/Library/Logs/CrashReporter",
        @"/private/var/logs/CrashReporter",
        @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics/Library/Logs/CrashReporter",
    ];
}

static BOOL cleaner_is_crash_log_root(NSString *path)
{
    NSString *canonical = fb_canonical_path(path);
    for (NSString *root in cleaner_crash_log_roots())
        if ([canonical isEqualToString:root]) return YES;
    return NO;
}

static BOOL cleaner_device_matches(dev_t actual, dev_t trusted)
{
    return actual == trusted;
}

static BOOL cleaner_container_identity_matches(const struct stat *st,
                                               dev_t device, ino_t inode)
{
    return st && cleaner_device_matches(st->st_dev, device) && st->st_ino == inode;
}

// O_NOFOLLOW on a pathname open protects only its final component. Anchor at
// / and open EVERY component relative to the descriptor already validated.
// Scan and delete both consume this descriptor; neither reopens the pathname.
static int cleaner_open_path(NSString *path)
{
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    NSArray<NSString *> *parts = fb_canonical_path(path).pathComponents;
    for (NSUInteger i = 1; i < parts.count; i++) {
        int next = openat(fd, parts[i].fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int savedError = errno;
        close(fd);
        if (next < 0) { errno = savedError; return -1; }
        fd = next;
    }
    return fd;
}

static int cleaner_open_root(NSString *path)
{
    if (!cleaner_is_disposable_root(path) && !cleaner_is_crash_log_root(path)) {
        errno = EINVAL;
        return -1;
    }
    return cleaner_open_path(path);
}

static int cleaner_open_container(NSString *path)
{
    if (!cleaner_is_app_container(path)) {
        errno = EINVAL;
        return -1;
    }
    return cleaner_open_path(path);
}

static int cleaner_open_relative_directory(int parentFD, NSArray<NSString *> *parts)
{
    int fd = dup(parentFD);
    if (fd < 0) return -1;
    for (NSString *part in parts) {
        int next = openat(fd, part.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int savedError = errno;
        close(fd);
        if (next < 0) { errno = savedError; return -1; }
        fd = next;
    }
    return fd;
}

static int cleaner_open_app_root_at(int containerFD, NSString *relativeRoot)
{
    NSArray<NSString *> *parts = relativeRoot.pathComponents;
    if (!((parts.count == 1 && [parts[0] isEqualToString:@"tmp"]) ||
          (parts.count == 2 && [parts[0] isEqualToString:@"Library"] &&
           [parts[1] isEqualToString:@"Caches"]))) {
        errno = EINVAL;
        return -1;
    }
    return cleaner_open_relative_directory(containerFD, parts);
}

// CrashReporter has no trusted app container, so its fixed parent directory
// supplies the baseline. A filesystem mounted directly at the report root is
// rejected before any traversal or deletion.
static int cleaner_open_trusted_root(NSString *path, dev_t *deviceOut)
{
    if (cleaner_is_disposable_root(path)) {
        int fd = cleaner_open_root(path);
        if (fd < 0) return -1;
        struct stat st = {0};
        if (fstat(fd, &st) != 0) { int savedError = errno; close(fd); errno = savedError; return -1; }
        if (deviceOut) *deviceOut = st.st_dev;
        return fd;
    }
    if (!cleaner_is_crash_log_root(path)) { errno = EINVAL; return -1; }
    NSString *parentPath = path.stringByDeletingLastPathComponent;
    int parentFD = cleaner_open_path(parentPath);
    if (parentFD < 0) return -1;
    struct stat parentStat = {0};
    if (fstat(parentFD, &parentStat) != 0) {
        int savedError = errno; close(parentFD); errno = savedError; return -1;
    }
    int rootFD = cleaner_open_path(path);
    int savedError = errno;
    close(parentFD);
    if (rootFD < 0) { errno = savedError; return -1; }
    struct stat rootStat = {0};
    if (fstat(rootFD, &rootStat) != 0 || !cleaner_device_matches(rootStat.st_dev, parentStat.st_dev)) {
        close(rootFD);
        errno = EXDEV;
        return -1;
    }
    if (deviceOut) *deviceOut = parentStat.st_dev;
    return rootFD;
}

// procmgr names are truncated to 31 characters. An app whose executable is
// longer must still be recognized as active or Cleaner could delete its cache
// while it is live.
static BOOL cleaner_process_is_active(NSString *executable, NSSet<NSString *> *activeNames)
{
    if (executable.length == 0 || activeNames.count == 0) return NO;
    if ([activeNames containsObject:executable]) return YES;
    for (NSString *name in activeNames) {
        // p_name truncates bytes, not NSString characters. A short unrelated
        // process (Foo) must not cause FooBar to be falsely marked active.
        // 28-31 bytes: a cut through a multi-byte character loses up to 3.
        NSUInteger bytes = [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (bytes >= 28 && bytes <= 31 &&
            [executable lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 31 &&
            [executable hasPrefix:name]) return YES;
    }
    return NO;
}

// All entry kinds consume the budget, including empty directories and links.
// A cancellation pointer belongs to the enclosing operation and uses atomic
// accesses because background expiration is delivered on the main thread.
typedef struct {
    NSUInteger entries;
    NSUInteger files;
    double deadline;
    int *cancelled;
    BOOL stopped;
} CYCleanerTraversal;

static double cleaner_monotonic_seconds(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return -1;
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static CYCleanerTraversal cleaner_traversal(double seconds, int *cancelled)
{
    double now = cleaner_monotonic_seconds();
    return (CYCleanerTraversal){ .deadline = now + seconds,
                                 .cancelled = cancelled, .stopped = (now < 0) };
}

static BOOL cleaner_traversal_should_stop(CYCleanerTraversal *walk, NSUInteger depth)
{
    double now = cleaner_monotonic_seconds();
    // Depth is not a reason to stop the whole walk: one over-deep folder
    // would end the pass for every later app. Callers skip that subtree.
    (void)depth;
    if (walk->stopped || now < 0 ||
        now >= walk->deadline ||
        (walk->cancelled && __atomic_load_n(walk->cancelled, __ATOMIC_RELAXED))) {
        walk->stopped = YES;
        return YES;
    }
    return NO;
}

static BOOL cleaner_visit_entry(CYCleanerTraversal *walk, NSUInteger depth)
{
    if (cleaner_traversal_should_stop(walk, depth)) return NO;
    if (walk->entries >= kCleanerMaxScanEntries) { walk->stopped = YES; return NO; }
    walk->entries++;
    return YES;
}

// Takes ownership of fd. Open descriptors, never ancestor pathnames, anchor
// the walk. Bounded depth also bounds the number of descriptors on the stack.
static unsigned long long cleaner_scan_directory_fd(int fd, dev_t device,
                                                     NSUInteger depth,
                                                     CYCleanerTraversal *walk,
                                                     BOOL *complete)
{
    DIR *dir = fdopendir(fd);
    if (!dir) { close(fd); *complete = NO; return 0; }
    unsigned long long total = 0;
    while (!cleaner_traversal_should_stop(walk, depth)) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) *complete = NO; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (!cleaner_visit_entry(walk, depth + 1)) break;
        struct stat st = {0};
        if (fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
            if (errno != ENOENT) *complete = NO;
            continue;
        }
        if (!cleaner_device_matches(st.st_dev, device)) { *complete = NO; continue; }
        if (S_ISREG(st.st_mode)) {
            total += (unsigned long long)st.st_size;
            walk->files++;
        } else if (S_ISDIR(st.st_mode)) {
            // Too deep: leave this subtree out (size incomplete), keep going.
            if (depth + 1 > kCleanerMaxTraversalDepth) { *complete = NO; continue; }
            int child = openat(fd, entry->d_name,
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            struct stat opened = {0};
            if (child < 0) { *complete = NO; continue; }
            if (fstat(child, &opened) != 0 || !cleaner_device_matches(opened.st_dev, device) ||
                opened.st_ino != st.st_ino) {
                close(child); *complete = NO; continue;
            }
            total += cleaner_scan_directory_fd(child, device, depth + 1, walk, complete);
        }
    }
    if (walk->stopped) *complete = NO;
    closedir(dir);
    return total;
}

// Core byte walk. The scan phase wraps it with a fresh traversal per root;
// the post-clean rescan passes the clean pass's own traversal so the whole
// pass — deletions and rescans — lives under one shared deadline.
static unsigned long long cleaner_tree_bytes_walk(NSString *root,
                                                  BOOL *complete,
                                                  CYCleanerTraversal *walk)
{
    if (cleaner_traversal_should_stop(walk, 0)) {
        if (complete) *complete = NO;
        return 0;
    }
    dev_t device = 0;
    int fd = cleaner_open_trusted_root(root, &device);
    if (fd < 0) { if (complete) *complete = (errno == ENOENT); return 0; }
    BOOL finished = YES;
    unsigned long long total = cleaner_scan_directory_fd(fd, device, 0, walk, &finished);
    if (complete) *complete = finished;
    return total;
}

static unsigned long long cleaner_tree_bytes_at(int containerFD, NSString *relativeRoot,
                                                dev_t device, BOOL *complete,
                                                CYCleanerTraversal *walk)
{
    if (cleaner_traversal_should_stop(walk, 0)) {
        if (complete) *complete = NO;
        return 0;
    }
    int fd = cleaner_open_app_root_at(containerFD, relativeRoot);
    if (fd < 0) { if (complete) *complete = (errno == ENOENT); return 0; }
    struct stat st = {0};
    if (fstat(fd, &st) != 0 || !cleaner_device_matches(st.st_dev, device)) {
        close(fd); if (complete) *complete = NO; return 0;
    }
    BOOL finished = YES;
    unsigned long long total = cleaner_scan_directory_fd(fd, device, 0, walk, &finished);
    if (complete) *complete = finished;
    return total;
}

static unsigned long long cleaner_tree_bytes_cancellable(NSString *root,
                                                          NSUInteger *fileCount,
                                                          BOOL *complete,
                                                          int *cancelled)
{
    if (fileCount) *fileCount = 0;
    CYCleanerTraversal walk = cleaner_traversal(kCleanerMaxScanSeconds, cancelled);
    unsigned long long total = cleaner_tree_bytes_walk(root, complete, &walk);
    if (fileCount) *fileCount = walk.files;
    return total;
}

// Removal is always relative to an open, no-follow descriptor. Mounts and
// swapped directory identities are rejected. Successfully removed child bytes
// remain reportable even if an enclosing directory is left behind.
static unsigned long long cleaner_remove_tree_at(int parentFD, const char *name,
                                                 NSUInteger depth, dev_t device,
                                                 CYCleanerTraversal *walk,
                                                 NSUInteger *removed,
                                                 NSUInteger *failed)
{
    // Too deep: this subtree stays (counted as a failure); the rest goes on.
    if (depth > kCleanerMaxTraversalDepth) { if (failed) (*failed)++; return 0; }
    if (!cleaner_visit_entry(walk, depth)) return 0;
    struct stat st = {0};
    if (fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno != ENOENT && failed) (*failed)++;
        return 0;
    }
    if (!cleaner_device_matches(st.st_dev, device)) { if (failed) (*failed)++; return 0; }
    if (!S_ISDIR(st.st_mode)) {
        if (cleaner_traversal_should_stop(walk, depth)) return 0;
        if (unlinkat(parentFD, name, 0) == 0) {
            if (removed) (*removed)++;
            return S_ISREG(st.st_mode) ? (unsigned long long)st.st_size : 0;
        }
        if (failed) (*failed)++;
        return 0;
    }

    int fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { if (failed) (*failed)++; return 0; }
    struct stat opened = {0};
    if (fstat(fd, &opened) != 0 || !cleaner_device_matches(opened.st_dev, device) || opened.st_ino != st.st_ino) {
        close(fd); if (failed) (*failed)++; return 0;
    }
    DIR *dir = fdopendir(fd);
    if (!dir) { close(fd); if (failed) (*failed)++; return 0; }
    unsigned long long bytes = 0;
    while (!cleaner_traversal_should_stop(walk, depth)) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno && failed) (*failed)++; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        bytes += cleaner_remove_tree_at(fd, entry->d_name, depth + 1, device, walk, removed, failed);
    }
    closedir(dir);
    if (!cleaner_traversal_should_stop(walk, depth)) {
        struct stat current = {0};
        if (fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) != 0 ||
            !cleaner_device_matches(current.st_dev, st.st_dev) || current.st_ino != st.st_ino ||
            unlinkat(parentFD, name, AT_REMOVEDIR) != 0) {
            if (failed) (*failed)++;
        }
    }
    return bytes;
}

// Counters accumulate across roots; initialize them once per app. A supplied
// traversal shares the whole clean pass's budget/cancellation. NULL creates a
// standalone bounded root operation (also useful to deterministic tests).
static unsigned long long cleaner_clear_directory_fd(int fd, dev_t device,
                                                     NSUInteger *removed,
                                                     NSUInteger *failed,
                                                     CYCleanerTraversal *walk)
{
    if (cleaner_traversal_should_stop(walk, 0)) return 0;
    struct stat st = {0};
    if (fstat(fd, &st) != 0 || !cleaner_device_matches(st.st_dev, device)) {
        close(fd); if (failed) (*failed)++; return 0;
    }
    DIR *root = fdopendir(fd);
    if (!root) { close(fd); if (failed) (*failed)++; return 0; }
    unsigned long long bytes = 0;
    while (!cleaner_traversal_should_stop(walk, 0)) {
        errno = 0;
        struct dirent *entry = readdir(root);
        if (!entry) { if (errno && failed) (*failed)++; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        bytes += cleaner_remove_tree_at(fd, entry->d_name, 1, st.st_dev, walk, removed, failed);
    }
    closedir(root);
    return bytes;
}

static unsigned long long cleaner_clear_directory(NSString *dir,
                                                  NSUInteger *removed,
                                                  NSUInteger *failed,
                                                  CYCleanerTraversal *operation)
{
    CYCleanerTraversal local = cleaner_traversal(kCleanerMaxCleanSeconds, NULL);
    CYCleanerTraversal *walk = operation ?: &local;
    if (cleaner_traversal_should_stop(walk, 0)) return 0;
    dev_t device = 0;
    int fd = cleaner_open_trusted_root(dir, &device);
    if (fd < 0) {
        if (errno != ENOENT && failed) (*failed)++;
        return 0;
    }
    return cleaner_clear_directory_fd(fd, device, removed, failed, walk);
}

static unsigned long long cleaner_clear_directory_at(int containerFD, NSString *relativeRoot,
                                                     dev_t device, NSUInteger *removed,
                                                     NSUInteger *failed, CYCleanerTraversal *walk)
{
    if (cleaner_traversal_should_stop(walk, 0)) return 0;
    int fd = cleaner_open_app_root_at(containerFD, relativeRoot);
    if (fd < 0) {
        if (errno != ENOENT && failed) (*failed)++;
        return 0;
    }
    return cleaner_clear_directory_fd(fd, device, removed, failed, walk);
}

// Custom targets (#18): a folder or file the user added, inside one app's
// data container. Opened component by component from the verified container
// descriptor like the fixed roots; the relative path is checked again here.
static int cleaner_open_custom_dir_at(int containerFD, NSString *relative)
{
    if (!cleaner_custom_target_valid_relative(relative)) { errno = EINVAL; return -1; }
    return cleaner_open_relative_directory(containerFD, relative.pathComponents);
}

// Its size: a folder's files, or the file itself (regular files only).
static unsigned long long cleaner_custom_bytes_at(int containerFD, NSString *relative, BOOL isFile,
                                                  dev_t device, BOOL *complete, CYCleanerTraversal *walk)
{
    if (complete) *complete = NO;
    if (cleaner_traversal_should_stop(walk, 0)) return 0;
    if (isFile) {
        if (!cleaner_custom_target_valid_relative(relative)) return 0;
        NSArray<NSString *> *parts = relative.pathComponents;
        int parent = cleaner_open_relative_directory(containerFD, [parts subarrayWithRange:NSMakeRange(0, parts.count - 1)]);
        if (parent < 0) { if (complete) *complete = (errno == ENOENT); return 0; }
        struct stat st = {0};
        BOOL found = fstatat(parent, parts.lastObject.fileSystemRepresentation, &st, AT_SYMLINK_NOFOLLOW) == 0;
        int err = errno;
        close(parent);
        if (!found) { if (complete) *complete = (err == ENOENT); return 0; }
        if (!S_ISREG(st.st_mode) || !cleaner_device_matches(st.st_dev, device)) return 0;
        if (complete) *complete = YES;
        return (unsigned long long)st.st_size;
    }
    int fd = cleaner_open_custom_dir_at(containerFD, relative);
    if (fd < 0) { if (complete) *complete = (errno == ENOENT); return 0; }
    struct stat st = {0};
    if (fstat(fd, &st) != 0 || !cleaner_device_matches(st.st_dev, device)) { close(fd); return 0; }
    BOOL finished = YES;
    unsigned long long total = cleaner_scan_directory_fd(fd, device, 0, walk, &finished);
    if (complete) *complete = finished;
    return total;
}

// Empties a custom folder (it stays) or deletes a custom file.
static unsigned long long cleaner_custom_clean_at(int containerFD, NSString *relative, BOOL isFile, dev_t device,
                                                  NSUInteger *removed, NSUInteger *failed, CYCleanerTraversal *walk)
{
    if (cleaner_traversal_should_stop(walk, 0)) return 0;
    if (isFile) {
        if (!cleaner_custom_target_valid_relative(relative)) { if (failed) (*failed)++; return 0; }
        NSArray<NSString *> *parts = relative.pathComponents;
        int parent = cleaner_open_relative_directory(containerFD, [parts subarrayWithRange:NSMakeRange(0, parts.count - 1)]);
        if (parent < 0) { if (errno != ENOENT && failed) (*failed)++; return 0; }
        const char *name = parts.lastObject.fileSystemRepresentation;
        struct stat st = {0};
        unsigned long long bytes = 0;
        if (fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
            if (S_ISREG(st.st_mode) && cleaner_device_matches(st.st_dev, device) && unlinkat(parent, name, 0) == 0) {
                bytes = (unsigned long long)st.st_size;
                if (removed) (*removed)++;
            } else if (failed) (*failed)++;
        } else if (errno != ENOENT && failed) (*failed)++;
        close(parent);
        return bytes;
    }
    int fd = cleaner_open_custom_dir_at(containerFD, relative);
    if (fd < 0) { if (errno != ENOENT && failed) (*failed)++; return 0; }
    return cleaner_clear_directory_fd(fd, device, removed, failed, walk);
}

@interface CYCleanerItem : NSObject <NSCopying>
@property (nonatomic, strong) FBAppContainer *container;
@property (nonatomic) dev_t containerDevice;
@property (nonatomic) ino_t containerInode;
@property (nonatomic) BOOL hasContainerIdentity;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned long long cacheBytes;
@property (nonatomic) unsigned long long tempBytes;
@property (nonatomic) BOOL active;
@property (nonatomic) BOOL systemApp;
@property (nonatomic) BOOL selected;
@property (nonatomic) BOOL incomplete;
// Non-nil only for the synthetic Crash Logs row. The roots are already
// validated by cleaner_is_crash_log_root() before deletion.
@property (nonatomic, copy) NSArray<NSString *> *logRoots;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *logRootBytes;
@property (nonatomic) NSUInteger fileCount;
// Non-nil only for a custom target (#18): its path in the container.
@property (nonatomic, copy) NSString *customRelative;
@property (nonatomic) BOOL customIsFile;
@end

@implementation CYCleanerItem
- (unsigned long long)totalBytes
{
    return self.cacheBytes + self.tempBytes;
}

- (BOOL)isCrashLogs
{
    return self.logRoots != nil;
}

- (NSString *)key
{
    if (self.logRoots) return @"__cyanide_crash_logs__";
    if (self.customRelative) return [NSString stringWithFormat:@"%@#%@", self.container.path ?: self.name, self.customRelative];
    return self.container.path ?: self.name ?: @"";
}

- (id)copyWithZone:(NSZone *)zone
{
    CYCleanerItem *copy = [[[self class] allocWithZone:zone] init];
    copy.container = self.container;
    copy.containerDevice = self.containerDevice;
    copy.containerInode = self.containerInode;
    copy.hasContainerIdentity = self.hasContainerIdentity;
    copy.icon = self.icon;
    copy.name = self.name;
    copy.cacheBytes = self.cacheBytes;
    copy.tempBytes = self.tempBytes;
    copy.active = self.active;
    copy.systemApp = self.systemApp;
    copy.selected = self.selected;
    copy.incomplete = self.incomplete;
    copy.logRoots = self.logRoots;
    copy.logRootBytes = self.logRootBytes;
    copy.fileCount = self.fileCount;
    copy.customRelative = self.customRelative;
    copy.customIsFile = self.customIsFile;
    return copy;
}
@end

// A nil result means Crash Logs was not part of this clean pass. Keep the
// displayed row in that case; a submitted row may disappear only when its
// complete rescan proves that no bytes remain.
static CYCleanerItem *cleaner_published_crash_logs(CYCleanerItem *existing,
                                                   CYCleanerItem *result)
{
    if (!result) return existing;
    return (result.totalBytes > 0 || result.incomplete) ? result : nil;
}

@interface CYCleanerFoldersViewController : UITableViewController
@property (nonatomic, copy) NSArray<CYCleanerItem *> *items;
@end

#pragma mark - Cells

// App row: selection circle, icon, name, "cache · temp" below, and the size
// right-aligned in a fixed column (same look as System Info's app list).
@interface CYCleanerAppCell : UITableViewCell
@property (nonatomic, strong) UIImageView *checkView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *sizeLabel;
@end

@implementation CYCleanerAppCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _checkView = [UIImageView new];
        _checkView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView = [UIImageView new];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 8;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.clipsToBounds = YES;
        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _detailLabel = [UILabel new];
        _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _detailLabel.textColor = UIColor.secondaryLabelColor;
        _sizeLabel = [UILabel new];
        _sizeLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
        _sizeLabel.textAlignment = NSTextAlignmentRight;
        for (UIView *v in @[ _checkView, _iconView, _nameLabel, _detailLabel, _sizeLabel ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:v];
        }
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [_sizeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                    forAxis:UILayoutConstraintAxisHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [_checkView.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [_checkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_checkView.widthAnchor constraintEqualToConstant:24],
            [_checkView.heightAnchor constraintEqualToConstant:24],
            [_iconView.leadingAnchor constraintEqualToAnchor:_checkView.trailingAnchor constant:12],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:36],
            [_iconView.heightAnchor constraintEqualToConstant:36],
            [_sizeLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [_sizeLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_sizeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:76],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
            [_detailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11],
        ]];
    }
    return self;
}

@end

// Summary card: the reclaimable total, a bar for the selected share, and the
// scan progress or the last result.
@interface CYCleanerSummaryCell : UITableViewCell
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *totalLabel;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation CYCleanerSummaryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _captionLabel = [UILabel new];
        _captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _captionLabel.textColor = UIColor.secondaryLabelColor;
        _totalLabel = [UILabel new];
        UIFont *big = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
        _totalLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle] scaledFontForFont:big];
        _totalLabel.adjustsFontForContentSizeCategory = YES;
        _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _bar.progressTintColor = UIColor.systemBlueColor;
        _statusLabel = [UILabel new];
        _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _statusLabel.textColor = UIColor.secondaryLabelColor;
        _statusLabel.numberOfLines = 0;
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.hidesWhenStopped = YES;
        UIStackView *captionRow = [[UIStackView alloc] initWithArrangedSubviews:@[ _captionLabel, _spinner ]];
        captionRow.axis = UILayoutConstraintAxisHorizontal;
        captionRow.spacing = 8;
        captionRow.alignment = UIStackViewAlignmentCenter;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ captionRow, _totalLabel, _bar, _statusLabel ]];
        stack.alignment = UIStackViewAlignmentFill;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 6;
        [stack setCustomSpacing:10 afterView:_totalLabel];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
            [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14],
        ]];
    }
    return self;
}

@end

#pragma mark - Cleaner

typedef NS_ENUM(NSInteger, CYCleanerSection) {
    CYCleanerSectionSummary,
    CYCleanerSectionApps,
    CYCleanerSectionCustom,    // folders/files added from the File Browser
    CYCleanerSectionSystem,
    CYCleanerSectionLogs,
    CYCleanerSectionSkipped,
    CYCleanerSectionCount,
};

typedef NS_ENUM(NSInteger, CYCleanerSort) { CYCleanerSortSize, CYCleanerSortName };

// What a loading screen is busy with, so the card can say so.
typedef NS_ENUM(NSInteger, CYCleanerPhase) {
    CYCleanerPhaseAccess,      // lifting the sandbox (may need SpringBoard / kernel access)
    CYCleanerPhaseFinding,     // reading every app container's metadata and icon
    CYCleanerPhaseProcesses,   // reading the running-process list
    CYCleanerPhaseScanning,    // measuring each app's caches
    CYCleanerPhaseLogs,        // measuring CrashReporter folders
};
static NSString * const kCleanerSortKey = @"CleanerSort";
// "Select Large Caches": the size worth clearing (small caches refill at once).
static const unsigned long long kCleanerLargeCacheBytes = 50ULL * 1024 * 1024;
// The explanation version the user acknowledged; bump to show it again.
static NSString * const kCleanerIntroAcceptedKey = @"CleanerIntroAcceptedVersion";
static const NSInteger kCleanerIntroVersion = 3;

static BOOL cleaner_intro_accepted(void)
{
    return [NSUserDefaults.standardUserDefaults integerForKey:kCleanerIntroAcceptedKey] >= kCleanerIntroVersion;
}

@interface CleanerViewController () <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<CYCleanerItem *> *items;
@property (nonatomic, strong) CYCleanerItem *crashLogs;
@property (nonatomic) BOOL processListAvailable;
@property (nonatomic) BOOL accessReady;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL cleaning;
@property (nonatomic) NSUInteger scanDone;
@property (nonatomic) NSUInteger scanTotal;
@property (nonatomic, copy) NSString *scanName;
@property (nonatomic) CYCleanerPhase phase;
@property (nonatomic) NSUInteger foundDone;    // containers looked at while finding apps
@property (nonatomic) NSUInteger foundTotal;
@property (nonatomic, copy) NSString *resultText;     // last clean's result, shown on the card
@property (nonatomic, copy) NSString *accessMessage;  // why there's no list
@property (nonatomic) BOOL skippedExpanded;
@property (nonatomic) CYCleanerSort sort;
@property (nonatomic, copy) NSString *filter;
@property (nonatomic, strong) UISearchController *searchCtrl;
@property (nonatomic, strong) UIButton *cleanButton;
@property (nonatomic, strong) UIProgressView *cleanProgress;
// Round 53: scan cancellation. reloadData installs a fresh block per pass
// (same __block-int pattern as performClean); viewWillDisappear and
// backgrounding pull it. scanStale marks that a pass was cancelled or
// invalidated, so the next appearance/foreground rescans instead of
// showing the stale one.
@property (nonatomic, copy) void (^scanCancel)(void);
@property (nonatomic) BOOL scanStale;
@property (nonatomic) NSUInteger scanGeneration;
@property (nonatomic) BOOL cleanerVisible;
// Round 53: section-array cache. itemsInSection: filters + sorts on every
// call, and the table asks per row/count/header. Membership depends only on
// items, filter, sort and processListAvailable — all mutated on the main
// queue — so the arrays are rebuilt lazily and invalidated at those points.
@property (nonatomic, copy) NSArray<CYCleanerItem *> *cachedApps;
@property (nonatomic, copy) NSArray<CYCleanerItem *> *cachedCustom;
@property (nonatomic, copy) NSArray<CYCleanerItem *> *cachedSystem;
@property (nonatomic, copy) NSArray<CYCleanerItem *> *cachedLogs;
@property (nonatomic, copy) NSArray<CYCleanerItem *> *cachedSkipped;
@property (nonatomic) BOOL sectionCacheValid;
// Round 53: toolbar width follows the actual view, not a frozen
// UIScreen.mainScreen snapshot taken before any rotation/split-view.
@property (nonatomic, strong) NSLayoutConstraint *cleanButtonWidth;
@end

// A larger touch target for the toolbar's Clean button: the holder accepts
// touches up to 10 pt outside itself and hands them all to the button.
@interface CYCleanerButtonHolder : UIView
@property (nonatomic, weak) UIButton *button;
@end

@implementation CYCleanerButtonHolder

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    return CGRectContainsPoint(CGRectInset(self.bounds, -10, -10), point);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled) return nil;
    if (![self pointInside:point withEvent:event]) return nil;
    return self.button.enabled ? self.button : [super hitTest:point withEvent:event];
}

@end

@implementation CleanerViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"Cache Cleaner";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.tableView.estimatedRowHeight = 64.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.sort = (CYCleanerSort)[NSUserDefaults.standardUserDefaults integerForKey:kCleanerSortKey];
    self.filter = @"";

    self.searchCtrl = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchCtrl.searchResultsUpdater = self;
    self.searchCtrl.obscuresBackgroundDuringPresentation = NO;
    self.searchCtrl.searchBar.placeholder = @"Filter apps";
    self.navigationItem.searchController = self.searchCtrl;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(refreshPulled:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    [self buildBottomBar];
    [self updateControls];

    // Round 53: scan invalidation across background/foreground (the VC's own
    // viewWillDisappear does not fire when the app merely backgrounds).
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(cleaner_didEnterBackground)
               name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(cleaner_willEnterForeground)
               name:UIApplicationWillEnterForegroundNotification object:nil];
    [nc addObserver:self selector:@selector(cleaner_didBecomeActive)
               name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    // Start right away, not after the push animation: the card shows what's
    // happening from the first frame. On first open the explanation comes
    // first; nothing is read until it is accepted.
    if (cleaner_intro_accepted() && !self.accessReady && !self.loading) [self ensureAccessAllowingFullExploit:NO];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    self.cleanerVisible = YES;
    cleaner_suppress_popup_bar(self, YES);
    [self cleaner_scheduleStaleScanIfNeeded];
    if (cleaner_intro_accepted() && !self.accessReady && !self.loading) [self ensureAccessAllowingFullExploit:NO];
    [self showIntroIfNeeded];
}

// Once, on first open: what cleaning removes and what it can cause.
- (void)showIntroIfNeeded
{
    if (cleaner_intro_accepted() || self.presentedViewController) return;
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Before You Clean"
                         message:@"Cache Cleaner removes the contents of each app's Library/Caches and tmp folders, plus optional CrashReporter logs. "
                                 @"Documents, settings, logins and other app data are not touched. Active apps are checked again before each folder. "
                                 @"Detection is best-effort; close apps before cleaning.\n\n"
                                 @"What can happen:\n"
                                 @"• Apps load slower at first and use data to rebuild their caches.\n"
                                 @"• Some apps keep offline content (music, podcasts, maps, game data) in their cache. "
                                 @"It has to be downloaded again — check large caches before cleaning.\n"
                                 @"• Rarely, an app asks you to sign in again or loses an unsent draft.\n"
                                 @"• An app waiting in the background may crash once when you return to it.\n\n"
                                 @"Reported sizes are logical file sizes; actual recovered storage can differ. "
                                 @"Apps refill their caches as you use them."
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [weakSelf.navigationController popViewControllerAnimated:YES];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Got It" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [NSUserDefaults.standardUserDefaults setInteger:kCleanerIntroVersion forKey:kCleanerIntroAcceptedKey];
        [weakSelf updateControls];
        if (!weakSelf.accessReady && !weakSelf.loading) [weakSelf ensureAccessAllowingFullExploit:NO];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    // Round 53: popping or covering the VC cancels an in-flight scan
    // promptly instead of letting it burn CPU on results no one sees.
    self.cleanerVisible = NO;
    if (self.scanCancel) { self.scanCancel(); self.scanStale = YES; }
    [self.navigationController setToolbarHidden:YES animated:animated];
    cleaner_suppress_popup_bar(self, NO);
}

// Round 53: backgrounding invalidates an in-flight scan — its active-app
// snapshot and sizes predate the suspension, so it must not publish on
// resume. Foregrounding rescans when the viewer is on screen.
- (void)cleaner_didEnterBackground
{
    if (self.scanCancel) { self.scanCancel(); self.scanStale = YES; }
}

- (void)cleaner_willEnterForeground
{
    [self cleaner_scheduleStaleScanIfNeeded];
}

- (void)cleaner_didBecomeActive
{
    [self cleaner_scheduleStaleScanIfNeeded];
}

- (void)cleaner_scheduleStaleScanIfNeeded
{
    BOOL foreground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    if (!cleaner_scan_should_restart(self.scanStale, self.loading, self.cleaning,
                                     self.cleanerVisible, foreground, self.accessReady)) return;
    if (!settings_filesystem_access_available()) {
        [self reloadData];
        return;
    }
    // Clear the marker before starting. If access has to be reacquired,
    // reloadData now has access and will own the replacement transition;
    // retaining this marker here would make every callback launch another pass.
    self.scanStale = NO;
    [self reloadData];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat width = MIN(self.view.bounds.size.width - 40, 520);
    if (self.cleanButtonWidth && self.cleanButtonWidth.constant != width)
        self.cleanButtonWidth.constant = width;
}

// The clean button lives in the toolbar so it stays put while the list scrolls.
// Its holder forwards every touch in and around it to the button: on small
// phones (iPhone mini) a tap near the toolbar's edge or the home indicator
// otherwise missed the button itself.
- (void)buildBottomBar
{
    UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
    cfg.baseBackgroundColor = UIColor.systemBlueColor;
    cfg.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 16, 10, 16);
    self.cleanButton = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    [self.cleanButton addTarget:self action:@selector(cleanSelected:) forControlEvents:UIControlEventTouchUpInside];
    self.cleanProgress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.cleanProgress.progressTintColor = UIColor.whiteColor;
    self.cleanProgress.trackTintColor = [UIColor.whiteColor colorWithAlphaComponent:0.3];
    self.cleanProgress.hidden = YES;
    self.cleanProgress.translatesAutoresizingMaskIntoConstraints = NO;
    self.cleanProgress.userInteractionEnabled = NO;
    [self.cleanButton addSubview:self.cleanProgress];
    [NSLayoutConstraint activateConstraints:@[
        [self.cleanProgress.leadingAnchor constraintEqualToAnchor:self.cleanButton.leadingAnchor constant:16],
        [self.cleanProgress.trailingAnchor constraintEqualToAnchor:self.cleanButton.trailingAnchor constant:-16],
        [self.cleanProgress.bottomAnchor constraintEqualToAnchor:self.cleanButton.bottomAnchor constant:-6],
    ]];
    self.cleanButton.translatesAutoresizingMaskIntoConstraints = NO;
    CYCleanerButtonHolder *holder = [CYCleanerButtonHolder new];
    holder.button = self.cleanButton;
    [holder addSubview:self.cleanButton];
    holder.translatesAutoresizingMaskIntoConstraints = NO;
    self.cleanButtonWidth = [holder.widthAnchor constraintEqualToConstant:320];
    [NSLayoutConstraint activateConstraints:@[
        [self.cleanButton.leadingAnchor constraintEqualToAnchor:holder.leadingAnchor],
        [self.cleanButton.trailingAnchor constraintEqualToAnchor:holder.trailingAnchor],
        [self.cleanButton.topAnchor constraintEqualToAnchor:holder.topAnchor],
        [self.cleanButton.bottomAnchor constraintEqualToAnchor:holder.bottomAnchor],
        self.cleanButtonWidth,
    ]];
    // The real width is applied in viewDidLayoutSubviews from the view's
    // bounds, so rotation and split-view resize the bar instead of leaving
    // it at whatever UIScreen.mainScreen reported at load time.
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                          target:nil action:nil];
    self.toolbarItems = @[ flex, [[UIBarButtonItem alloc] initWithCustomView:holder], flex ];
}

#pragma mark Data views

- (BOOL)matchesFilter:(CYCleanerItem *)item
{
    if (!self.filter.length) return YES;
    return [item.name rangeOfString:self.filter options:NSCaseInsensitiveSearch].location != NSNotFound ||
           (item.container.identifier &&
            [item.container.identifier rangeOfString:self.filter options:NSCaseInsensitiveSearch].location != NSNotFound);
}

- (void)setItems:(NSArray<CYCleanerItem *> *)items
{
    _items = [items copy];
    self.sectionCacheValid = NO;
}

- (void)setCrashLogs:(CYCleanerItem *)crashLogs
{
    _crashLogs = crashLogs;
    self.sectionCacheValid = NO;
}

- (NSArray<CYCleanerItem *> *)itemsInSection:(NSInteger)section
{
    if (!self.sectionCacheValid) {
        NSMutableArray<CYCleanerItem *> *apps = [NSMutableArray array];
        NSMutableArray<CYCleanerItem *> *custom = [NSMutableArray array];
        NSMutableArray<CYCleanerItem *> *system = [NSMutableArray array];
        NSMutableArray<CYCleanerItem *> *logs = [NSMutableArray array];
        NSMutableArray<CYCleanerItem *> *skipped = [NSMutableArray array];
        if (self.crashLogs && [self matchesFilter:self.crashLogs])
            [logs addObject:self.crashLogs];
        for (CYCleanerItem *item in self.items) {
            if (![self matchesFilter:item]) continue;
            if (item.active || !self.processListAvailable) [skipped addObject:item];
            else if (item.customRelative) [custom addObject:item];
            else if (item.systemApp) [system addObject:item];
            else [apps addObject:item];
        }
        CYCleanerSort sort = self.sort;
        NSComparator cmp = ^NSComparisonResult(CYCleanerItem *a, CYCleanerItem *b) {
            if (sort == CYCleanerSortSize && a.totalBytes != b.totalBytes)
                return a.totalBytes > b.totalBytes ? NSOrderedAscending : NSOrderedDescending;
            return [a.name localizedCaseInsensitiveCompare:b.name];
        };
        [apps sortUsingComparator:cmp];
        [custom sortUsingComparator:cmp];
        [system sortUsingComparator:cmp];
        [skipped sortUsingComparator:cmp];
        self.cachedApps = apps;
        self.cachedCustom = custom;
        self.cachedSystem = system;
        self.cachedLogs = logs;
        self.cachedSkipped = skipped;
        self.sectionCacheValid = YES;
    }
    switch (section) {
        case CYCleanerSectionSkipped: return self.cachedSkipped;
        case CYCleanerSectionLogs:    return self.cachedLogs;
        case CYCleanerSectionSystem:  return self.cachedSystem;
        case CYCleanerSectionApps:    return self.cachedApps;
        case CYCleanerSectionCustom:  return self.cachedCustom;
        default:                      return @[];
    }
}

- (BOOL)itemSelectable:(CYCleanerItem *)item
{
    if (self.loading || self.cleaning) return NO;
    if (item.selected) return YES;   // a selection can always be undone
    if (item.totalBytes == 0) return NO;
    if (item.isCrashLogs) return YES;
    return !item.active && self.processListAvailable;
}

- (NSUInteger)selectedCount
{
    NSUInteger count = 0;
    for (CYCleanerItem *item in self.items) if (item.selected) count++;
    if (self.crashLogs.selected) count++;
    return count;
}

- (unsigned long long)selectedBytes
{
    unsigned long long bytes = 0;
    for (CYCleanerItem *item in self.items) if (item.selected) bytes += item.totalBytes;
    if (self.crashLogs.selected) bytes += self.crashLogs.totalBytes;
    return bytes;
}

- (unsigned long long)totalBytes
{
    unsigned long long bytes = 0;
    for (CYCleanerItem *item in self.items) bytes += item.totalBytes;
    if (self.crashLogs) bytes += self.crashLogs.totalBytes;
    return bytes;
}

- (NSUInteger)selectedAppCount
{
    NSUInteger count = 0;
    for (CYCleanerItem *item in self.items) if (item.selected) count++;
    return count;
}

#pragma mark Controls

- (void)updateControls
{
    NSUInteger count = [self selectedCount];
    BOOL selectedAppsNeedProcessList = [self selectedAppCount] > 0 && !self.processListAvailable;
    BOOL enabled = !self.loading && !self.cleaning && self.accessReady && count > 0 &&
                   !selectedAppsNeedProcessList;
    UIButtonConfiguration *cfg = self.cleanButton.configuration;
    if (self.cleaning) cfg.title = @"Cleaning…";
    else if (count > 0)
        cfg.title = [NSString stringWithFormat:@"Clean Selected · %@", cleaner_bytes([self selectedBytes])];
    else cfg.title = @"Select Items to Clean";
    self.cleanButton.configuration = cfg;
    self.cleanButton.enabled = enabled;
    self.cleanProgress.hidden = !self.cleaning;

    // ⋯ menu: sorting, select all, folder review.
    __weak typeof(self) weakSelf = self;
    UIAction *(^sortAction)(NSString *, CYCleanerSort) = ^UIAction *(NSString *title, CYCleanerSort s) {
        UIAction *a = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *x) {
            weakSelf.sort = s;
            [NSUserDefaults.standardUserDefaults setInteger:s forKey:kCleanerSortKey];
            weakSelf.sectionCacheValid = NO;
            [weakSelf.tableView reloadData];
            [weakSelf updateControls];
        }];
        a.state = self.sort == s ? UIMenuElementStateOn : UIMenuElementStateOff;
        return a;
    };
    BOOL busy = self.loading || self.cleaning;
    NSUInteger selectable = 0, selected = 0;
    for (CYCleanerItem *item in self.items) {
        if (item.active || item.systemApp || item.totalBytes == 0) continue;
        selectable++;
        if (item.selected) selected++;
    }
    BOOL allSelected = selectable > 0 && selected == selectable;
    UIAction *selectAll = [UIAction actionWithTitle:allSelected ? @"Deselect All" : @"Select All Apps"
                                              image:[UIImage systemImageNamed:allSelected ? @"circle" : @"checkmark.circle"]
                                         identifier:nil handler:^(UIAction *x) { [weakSelf toggleSelectAll:nil]; }];
    if (busy || !self.processListAvailable || selectable == 0) selectAll.attributes = UIMenuElementAttributesDisabled;
    NSUInteger large = 0;
    for (CYCleanerItem *item in self.items)
        if (!item.active && !item.systemApp && item.totalBytes >= kCleanerLargeCacheBytes) large++;
    UIAction *selectLarge = [UIAction actionWithTitle:@"Select Large Caches (50 MB+)"
                                                image:[UIImage systemImageNamed:@"externaldrive.badge.checkmark"]
                                           identifier:nil handler:^(UIAction *x) { [weakSelf selectLargeCaches:nil]; }];
    selectLarge.subtitle = large ? [NSString stringWithFormat:@"%lu app%@", (unsigned long)large, large == 1 ? @"" : @"s"]
                                 : @"None this large";
    if (busy || !self.processListAvailable || large == 0) selectLarge.attributes = UIMenuElementAttributesDisabled;
    UIAction *folders = [UIAction actionWithTitle:@"Review Folders" image:[UIImage systemImageNamed:@"folder"]
                                       identifier:nil handler:^(UIAction *x) { [weakSelf showSelectedFolders:nil]; }];
    if (busy || count == 0) folders.attributes = UIMenuElementAttributesDisabled;
    UIMenu *menu = [UIMenu menuWithChildren:@[
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ selectAll, selectLarge, folders ]],
        [UIMenu menuWithTitle:@"Sort By" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
            sortAction(@"Size", CYCleanerSortSize), sortAction(@"Name", CYCleanerSortName),
        ]],
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:menu];
}

- (void)reloadSummary
{
    NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:CYCleanerSectionSummary];
    CYCleanerSummaryCell *cell = (CYCleanerSummaryCell *)[self.tableView cellForRowAtIndexPath:ip];
    if ([cell isKindOfClass:CYCleanerSummaryCell.class]) [self configureSummary:cell];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    self.filter = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";
    self.sectionCacheValid = NO;
    [self.tableView reloadData];
}

#pragma mark Access and scanning

// Like System Info: live or parked kernel access is used directly; a full
// exploit run only after asking (it can reboot A18/M4 devices).
- (void)ensureAccessAllowingFullExploit:(BOOL)allowFullExploit
{
    if (self.loading) return;
    if (settings_filesystem_access_available()) {
        self.accessReady = YES;
        [self reloadData];
        return;
    }
    self.loading = YES;
    self.phase = CYCleanerPhaseAccess;
    self.accessMessage = nil;
    self.scanName = nil;
    [self.tableView reloadData];
    [self updateControls];
    __weak typeof(self) weakSelf = self;
    settings_unlock_filesystem_async(allowFullExploit, ^(BOOL ok, NSString *message) {
        typeof(self) self = weakSelf;
        if (!self) return;
        self.loading = NO;
        if (ok) {
            self.accessReady = YES;
            [self reloadData];
            return;
        }
        BOOL needsFullRun = [message isEqualToString:kSettingsFullExploitRequiredMessage];
        self.accessMessage = needsFullRun
            ? kSettingsNoKernelAccessHint
            : (message ?: @"Filesystem access is not available.");
        [self.tableView reloadData];
        [self updateControls];
        if (needsFullRun) {
            settings_tool_needs_exploit(self, self.tableView, @"Cache Cleaner", ^{
                [weakSelf ensureAccessAllowingFullExploit:NO];
            });
        }
    });
}

- (void)refreshPulled:(UIRefreshControl *)sender
{
    (void)sender;
    if (self.loading || self.cleaning) {
        [self.refreshControl endRefreshing];
        return;
    }
    [self.refreshControl endRefreshing];
    self.resultText = nil;
    [self reloadData];
}

- (void)reloadData
{
    if (self.loading || self.cleaning) return;
    if (!self.accessReady || !settings_filesystem_access_available()) {
        [self ensureAccessAllowingFullExploit:NO];
        return;
    }

    self.scanStale = NO;
    NSUInteger scanGeneration = ++self.scanGeneration;
    self.loading = YES;
    self.phase = CYCleanerPhaseFinding;
    self.foundDone = 0;
    self.foundTotal = 0;
    self.scanDone = 0;
    self.scanTotal = 0;
    self.scanName = nil;
    self.accessMessage = nil;
    self.crashLogs = nil;
    [self.tableView reloadData];
    [self updateControls];
    __weak typeof(self) weakSelf = self;
    // Round 53: one cancel flag per pass, pulled by viewWillDisappear and
    // the backgrounding observer (same __block-int pattern as performClean).
    // Cleared when the pass ends so a late pull is a no-op.
    __block int scanCancelled = 0;
    self.scanCancel = ^{
        __atomic_store_n(&scanCancelled, 1, __ATOMIC_RELAXED);
    };
    void (^setPhase)(CYCleanerPhase, NSUInteger, NSUInteger) = ^(CYCleanerPhase phase, NSUInteger done, NSUInteger total) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.scanGeneration != scanGeneration || !self.loading) return;
            self.phase = phase;
            if (phase == CYCleanerPhaseFinding) { self.foundDone = done; self.foundTotal = total; }
            [self reloadSummary];
        });
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            // Round 53: no fb_containers_reset() here anymore. Container
            // builds now happen outside fb_containers_lock, so the reset's
            // locking concern is gone; and wiping the shared cache forced
            // the File Browser to re-read every app's metadata and re-decode
            // every icon after each Cleaner scan. The residual staleness is
            // cosmetic and bounded: the UUID list itself is re-enumerated
            // every scan (new/uninstalled apps are exact), and a cached
            // display name/icon/executable only goes stale when an app is
            // updated mid-session — the same staleness the File Browser
            // already lives with. Sizes and active-state are always fresh
            // (re-walked/re-read per scan).
            // Same set as fb_app_data_containers(), looked up one by one so the
            // card can count up (reading metadata and icons takes a while).
            NSString *dataParent = [kCleanerAppDataPrefix substringToIndex:kCleanerAppDataPrefix.length - 1];
            NSArray<NSString *> *uuids = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dataParent error:nil];
            NSMutableArray<FBAppContainer *> *containers = [NSMutableArray array];
            NSUInteger looked = 0;
            BOOL scanAborted = NO;
            setPhase(CYCleanerPhaseFinding, 0, uuids.count);
            for (NSString *uuid in uuids) {
                if (__atomic_load_n(&scanCancelled, __ATOMIC_RELAXED)) { scanAborted = YES; break; }
                NSString *containerPath = [dataParent stringByAppendingPathComponent:uuid];
                FBAppContainer *c = fb_container_for_path(containerPath, NO);
                // A container cached before its app was indexed (installed
                // while Cyanide ran) has no executable yet: look it up fresh.
                if (c.kind == FBContainerKindData && !c.executableName)
                    c = fb_current_container_for_path(containerPath, NO);
                if (c.kind == FBContainerKindData && c.executableName) [containers addObject:c];
                looked++;
                if (looked % 4 == 0 || looked == uuids.count) setPhase(CYCleanerPhaseFinding, looked, uuids.count);
            }
            NSUInteger total = containers.count;
            setPhase(CYCleanerPhaseProcesses, 0, 0);
            NSSet<NSString *> *active = nil;
            BOOL processListAvailable = NO;
            // Do not enter the process-list reader after cancellation. This
            // pass is already stale and the kernel round trip only delays its
            // completion while the screen is hidden/backgrounded.
            if (!__atomic_load_n(&scanCancelled, __ATOMIC_RELAXED)) {
                active = settings_active_process_names();
                processListAvailable = (active != nil);
            } else {
                scanAborted = YES;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (!self || self.scanGeneration != scanGeneration || !self.loading) return;
                self.scanTotal = total;
                self.phase = CYCleanerPhaseScanning;
                [self reloadSummary];
            });
            if (!active) active = [NSSet set];

            NSMutableArray<CYCleanerItem *> *items = [NSMutableArray array];
            NSUInteger scanned = 0;
            for (FBAppContainer *container in containers) {
                if (__atomic_load_n(&scanCancelled, __ATOMIC_RELAXED)) { scanAborted = YES; break; }
                if (![container isKindOfClass:FBAppContainer.class]) continue;
                if (!cleaner_path_is_app_data(container.path)) continue;

                // The ordinary container object supplies the cached icon and
                // display affordances. Safety metadata is reread without icon
                // work and must retain the same bundle association.
                FBAppContainer *current = fb_current_container_for_path(container.path, NO);
                BOOL metadataValid = current && current.kind == FBContainerKindData &&
                                     current.executableName.length > 0;
                FBAppContainer *safetyContainer = metadataValid ? current : container;

                CYCleanerItem *item = [[CYCleanerItem alloc] init];
                item.container = safetyContainer;
                item.name = safetyContainer.displayName.length ? safetyContainer.displayName : safetyContainer.identifier;
                item.systemApp = safetyContainer.systemApp;
                item.active = !metadataValid || cleaner_process_is_active(safetyContainer.executableName, active);
                item.icon = container.icon;   // loaded by the ordinary cache, never by the refresh

                if (!metadataValid) {
                    // Preserve an informational row if possible, but never
                    // make an item with stale executable/container metadata
                    // selectable or cleanable.
                    item.incomplete = YES;
                } else {
                    int containerFD = cleaner_open_container(safetyContainer.path);
                    struct stat containerStat = {0};
                    if (containerFD < 0 || fstat(containerFD, &containerStat) != 0) {
                        if (containerFD >= 0) close(containerFD);
                        item.incomplete = YES;
                        item.active = YES;
                    } else {
                        item.containerDevice = containerStat.st_dev;
                        item.containerInode = containerStat.st_ino;
                        item.hasContainerIdentity = YES;
                        BOOL complete = NO;
                        CYCleanerTraversal cacheWalk = cleaner_traversal(kCleanerMaxScanSeconds, &scanCancelled);
                        item.cacheBytes = cleaner_tree_bytes_at(containerFD, @"Library/Caches",
                                                                containerStat.st_dev, &complete, &cacheWalk);
                        item.incomplete = !complete;
                        complete = NO;
                        CYCleanerTraversal tempWalk = cleaner_traversal(kCleanerMaxScanSeconds, &scanCancelled);
                        item.tempBytes = cleaner_tree_bytes_at(containerFD, @"tmp",
                                                               containerStat.st_dev, &complete, &tempWalk);
                        item.incomplete = item.incomplete || !complete;
                        close(containerFD);
                    }
                }
                scanned++;
                NSString *name = item.name;
                NSUInteger done = scanned;
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) self = weakSelf;
                    if (!self || self.scanGeneration != scanGeneration || !self.loading) return;
                    self.scanDone = done;
                    self.scanName = name;
                    [self reloadSummary];
                });
                // Apps with nothing reclaimable are noise in this screen.
                if (item.totalBytes == 0 && !item.incomplete) continue;
                item.selected = item.totalBytes > 0 && processListAvailable && !item.active && !item.systemApp;
                [items addObject:item];
            }

            // Custom targets (#18), in their app's current container. Never
            // pre-selected; an app that isn't installed has nothing to show.
            NSMutableDictionary<NSString *, FBAppContainer *> *byBundle = [NSMutableDictionary dictionary];
            for (FBAppContainer *c in containers) if (c.identifier.length) byBundle[c.identifier] = c;
            for (CYCleanerCustomTarget *target in cleaner_custom_targets()) {
                if (__atomic_load_n(&scanCancelled, __ATOMIC_RELAXED)) { scanAborted = YES; break; }
                FBAppContainer *container = byBundle[target.bundleID];
                if (!container || !cleaner_path_is_app_data(container.path)) continue;
                FBAppContainer *current = fb_current_container_for_path(container.path, NO);
                BOOL metadataValid = current && current.kind == FBContainerKindData && current.executableName.length > 0 &&
                                     [current.identifier isEqualToString:target.bundleID];
                CYCleanerItem *item = [[CYCleanerItem alloc] init];
                item.container = metadataValid ? current : container;
                item.name = container.displayName.length ? container.displayName : target.appName;
                item.icon = container.icon;
                item.systemApp = container.systemApp;
                item.customRelative = target.relativePath;
                item.customIsFile = target.isFile;
                item.active = !metadataValid || cleaner_process_is_active(item.container.executableName, active);
                if (!metadataValid) {
                    item.incomplete = YES;
                } else {
                    int containerFD = cleaner_open_container(current.path);
                    struct stat containerStat = {0};
                    if (containerFD < 0 || fstat(containerFD, &containerStat) != 0) {
                        if (containerFD >= 0) close(containerFD);
                        item.incomplete = YES;
                        item.active = YES;
                    } else {
                        item.containerDevice = containerStat.st_dev;
                        item.containerInode = containerStat.st_ino;
                        item.hasContainerIdentity = YES;
                        BOOL complete = NO;
                        CYCleanerTraversal walk = cleaner_traversal(kCleanerMaxScanSeconds, &scanCancelled);
                        item.cacheBytes = cleaner_custom_bytes_at(containerFD, target.relativePath, target.isFile,
                                                                  containerStat.st_dev, &complete, &walk);
                        item.incomplete = !complete;
                        close(containerFD);
                    }
                }
                item.selected = NO;
                [items addObject:item];
            }

            CYCleanerItem *crashLogs = nil;
            if (!scanAborted) {
                setPhase(CYCleanerPhaseLogs, 0, 0);
                unsigned long long logBytes = 0;
                NSUInteger logFiles = 0;
                NSMutableArray<NSString *> *logRoots = [NSMutableArray array];
                NSMutableDictionary<NSString *, NSNumber *> *logRootBytes = [NSMutableDictionary dictionary];
                BOOL logsComplete = YES;
                for (NSString *root in cleaner_crash_log_roots()) {
                    if (__atomic_load_n(&scanCancelled, __ATOMIC_RELAXED)) { scanAborted = YES; break; }
                    BOOL complete = YES;
                    NSUInteger files = 0;
                    unsigned long long bytes = cleaner_tree_bytes_cancellable(root, &files, &complete, &scanCancelled);
                    if (bytes > 0) {
                        logBytes += bytes;
                        logFiles += files;
                        [logRoots addObject:root];
                        logRootBytes[root] = @(bytes);
                    }
                    if (!complete) logsComplete = NO;
                }
                if (logBytes > 0) {
                    crashLogs = [[CYCleanerItem alloc] init];
                    crashLogs.name = @"Crash Logs";
                    crashLogs.cacheBytes = logBytes;
                    crashLogs.fileCount = logFiles;
                    crashLogs.logRoots = logRoots;
                    crashLogs.logRootBytes = logRootBytes;
                    crashLogs.incomplete = !logsComplete;
                    crashLogs.selected = NO;
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (!self) return;
                if (self.scanGeneration != scanGeneration) return;
                self.scanCancel = nil;   // late pulls are no-ops once the pass ends
                if (scanAborted || __atomic_load_n(&scanCancelled, __ATOMIC_RELAXED)) {
                    // Never publish a cancelled pass. Once loading clears,
                    // schedule exactly one replacement when the same VC is
                    // visible and active; otherwise the next appearance/
                    // foreground callback owns the replacement.
                    self.loading = NO;
                    self.scanStale = YES;
                    [self.tableView reloadData];
                    [self updateControls];
                    [self cleaner_scheduleStaleScanIfNeeded];
                    return;
                }
                self.items = items;
                self.crashLogs = crashLogs;
                self.processListAvailable = processListAvailable;
                self.sectionCacheValid = NO;  // availability also drives membership
                self.loading = NO;
                [self.tableView reloadData];
                [self updateControls];
            });
        }
    });
}

#pragma mark Actions

- (void)toggleSelectAll:(id)sender
{
    (void)sender;
    if (self.loading || self.cleaning || !self.processListAvailable) return;
    NSArray<CYCleanerItem *> *selectable = [self.items filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(CYCleanerItem *item, NSDictionary *bindings) {
            (void)bindings;
            return !item.active && !item.systemApp && !item.customRelative && item.totalBytes > 0;
        }]];
    BOOL allSelected = selectable.count > 0;
    for (CYCleanerItem *item in selectable) {
        if (!item.selected) { allSelected = NO; break; }
    }
    for (CYCleanerItem *item in selectable) item.selected = !allSelected;
    [self.tableView reloadData];
    [self updateControls];
}

// Only the big caches (the ones worth clearing): selects every selectable
// app at or above kCleanerLargeCacheBytes and deselects the rest.
- (void)selectLargeCaches:(id)sender
{
    (void)sender;
    if (self.loading || self.cleaning || !self.processListAvailable) return;
    for (CYCleanerItem *item in self.items) {
        if (item.active || item.systemApp || item.customRelative || item.totalBytes == 0) continue;
        item.selected = item.totalBytes >= kCleanerLargeCacheBytes;
    }
    [self.tableView reloadData];
    [self updateControls];
}

- (void)showSelectedFolders:(id)sender
{
    (void)sender;
    NSMutableArray<CYCleanerItem *> *selected = [NSMutableArray array];
    for (CYCleanerItem *item in self.items) if (item.selected) [selected addObject:item];
    if (self.crashLogs.selected) [selected addObject:self.crashLogs];
    if (selected.count == 0) return;
    CYCleanerFoldersViewController *vc = [[CYCleanerFoldersViewController alloc] init];
    vc.items = selected;
    [self.navigationController pushViewController:vc animated:YES];
}

// Takes a custom target off the list (nothing is deleted).
- (void)removeCustomItem:(CYCleanerItem *)item
{
    if (self.cleaning || !item.customRelative) return;
    cleaner_custom_target_remove(item.container.identifier ?: @"", item.customRelative);
    NSMutableArray<CYCleanerItem *> *kept = [NSMutableArray array];
    for (CYCleanerItem *other in self.items) if (![other.key isEqualToString:item.key]) [kept addObject:other];
    self.items = kept;
    [self.tableView reloadData];
    [self updateControls];
}

- (void)openInFileBrowser:(NSString *)path
{
    FileBrowserViewController *vc = [[FileBrowserViewController alloc] initWithPath:path];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)cleanSelected:(id)sender
{
    (void)sender;
    if (self.loading || self.cleaning || !self.accessReady) return;
    if (!cleaner_intro_accepted()) { [self showIntroIfNeeded]; return; }
    NSUInteger appCount = [self selectedAppCount];
    BOOL logsSelected = self.crashLogs.selected;
    if (appCount > 0 && !self.processListAvailable) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Kernel Access Needed"
                             message:@"Cache Cleaner cannot tell which apps are active without kernel access. Run the chain once, then try again."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSUInteger count = [self selectedCount];
    if (count == 0) return;

    BOOL anyCustom = NO;
    for (CYCleanerItem *item in self.items) if (item.selected && item.customRelative) anyCustom = YES;
    NSMutableString *message = [NSMutableString stringWithFormat:
        anyCustom ? @"Remove the selected data (%@ in logical file sizes)? Apart from the items you added, documents, settings and app data are not touched."
                  : @"Remove the selected disposable data (%@ in logical file sizes)? Documents, settings and app data are not touched.",
        cleaner_bytes([self selectedBytes])];
    NSUInteger customCount = 0;
    for (CYCleanerItem *item in self.items) if (item.selected && item.customRelative) customCount++;
    if (appCount > customCount)
        [message appendFormat:@" %lu app cache/temp folder%@.", (unsigned long)(appCount - customCount), appCount - customCount == 1 ? @"" : @"s"];
    if (customCount > 0)
        [message appendFormat:@" %lu item%@ you added (folders are emptied, files deleted; anything the app keeps there, like drafts, is lost).",
         (unsigned long)customCount, customCount == 1 ? @"" : @"s"];
    if (logsSelected) [message appendString:@" CrashReporter logs."];
    [message appendString:@" Apps may need to redownload content."];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Clean Caches?"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Clean" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        [weakSelf performClean];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)performClean
{
    if (self.cleaning) return;
    self.cleaning = YES;
    self.resultText = nil;
    self.cleanProgress.progress = 0;
    [self updateControls];
    [self.tableView reloadData];

    // Detached worker-owned copies: section membership and sort keys of the
    // live table must not change until results are published on the main queue.
    NSMutableArray<CYCleanerItem *> *work = [NSMutableArray array];
    for (CYCleanerItem *item in self.items) if (item.selected) [work addObject:[item copy]];
    if (self.crashLogs.selected) [work addObject:[self.crashLogs copy]];

    __block int cancelled = 0;
    __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
    bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"cyanide.cleaner" expirationHandler:^{
        __atomic_store_n(&cancelled, 1, __ATOMIC_RELAXED);
        // UIKit invokes expiration on the main thread. End the lease now,
        // not after an unbounded worker or rescan eventually finishes.
        if (bgTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }
    }];
    if (bgTask == UIBackgroundTaskInvalid) __atomic_store_n(&cancelled, 1, __ATOMIC_RELAXED);

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            CYCleanerTraversal traversal = cleaner_traversal(kCleanerMaxCleanSeconds, &cancelled);
            BOOL processUnavailable = NO;
            NSUInteger cleanedApps = 0, skippedActive = 0, skippedChanged = 0, failedItems = 0, done = 0;
            BOOL cleanedLogs = NO;
            unsigned long long freed = 0;

            for (CYCleanerItem *item in work) {
                if (processUnavailable || cleaner_traversal_should_stop(&traversal, 0)) break;
                BOOL isLogs = item.isCrashLogs;
                if (!isLogs && !cleaner_path_is_app_data(item.container.path)) {
                    failedItems++;
                    continue;
                }

                // Refresh the active check once per app, before touching any
                // of its roots: each process-list read is a kernel round
                // trip, and checking between roots could leave an app
                // half-cleaned before noticing it had become active. Fail
                // closed: no list or no executable name means no deletion.
                BOOL skipApp = NO;
                int trustedContainerFD = -1;
                dev_t trustedContainerDevice = 0;
                if (!isLogs) {
                    // Round 54: a container that can no longer be re-verified
                    // (uninstalled or replaced since the scan) skips THIS app
                    // only. The pass continues; processUnavailable stays
                    // reserved for a genuine process-list outage, which is the
                    // only fail-closed stop that justifies aborting everything.
                    FBAppContainer *current = fb_current_container_for_path(item.container.path, NO);
                    if (!current || current.kind != FBContainerKindData || current.executableName.length == 0 ||
                        !item.hasContainerIdentity) {
                        item.incomplete = YES;
                        skippedChanged++;
                        skipApp = YES;
                    } else {
                        // Open and verify the path once, then keep this
                        // descriptor as the trusted parent for both roots.
                        trustedContainerFD = cleaner_open_container(current.path);
                        struct stat currentStat = {0};
                        if (trustedContainerFD < 0 || fstat(trustedContainerFD, &currentStat) != 0 ||
                            !cleaner_container_identity_matches(&currentStat, item.containerDevice,
                                                                item.containerInode)) {
                            if (trustedContainerFD >= 0) close(trustedContainerFD);
                            trustedContainerFD = -1;
                            item.incomplete = YES;
                            skippedChanged++;
                            skipApp = YES;
                        } else {
                            item.container = current;
                            trustedContainerDevice = currentStat.st_dev;
                        }
                    }
                    // The kernel round trip is only worthwhile while the app
                    // is still a deletion candidate; an app already skipped
                    // (identity changed) never needs the active check.
                    if (!skipApp) {
                        NSSet<NSString *> *activeNames = settings_active_process_names();
                        if (!activeNames || item.container.executableName.length == 0) {
                            processUnavailable = YES;
                        } else if (cleaner_process_is_active(item.container.executableName, activeNames)) {
                            item.active = YES;
                            skippedActive++;
                            skipApp = YES;
                        }
                    }
                }

                NSUInteger removed = 0, failed = 0;
                unsigned long long appFreed = 0;
                if (!processUnavailable && !skipApp) {
                    if (isLogs) {
                        for (NSString *root in item.logRoots) {
                            if (cleaner_traversal_should_stop(&traversal, 0)) break;
                            appFreed += cleaner_clear_directory(root, &removed, &failed, &traversal);
                        }
                    } else if (item.customRelative) {
                        appFreed += cleaner_custom_clean_at(trustedContainerFD, item.customRelative, item.customIsFile,
                                                            trustedContainerDevice, &removed, &failed, &traversal);
                    } else {
                        for (NSString *relativeRoot in @[ @"Library/Caches", @"tmp" ]) {
                            if (cleaner_traversal_should_stop(&traversal, 0)) break;
                            appFreed += cleaner_clear_directory_at(trustedContainerFD, relativeRoot,
                                                                   trustedContainerDevice, &removed, &failed,
                                                                   &traversal);
                        }
                    }
                }
                freed += appFreed;

                if (processUnavailable || cleaner_traversal_should_stop(&traversal, 0)) {
                    // Retain the last known sizes rather than pretending an
                    // interrupted/unreadable rescan proved the roots empty --
                    // minus what this pass verifiably removed, so "≥ size"
                    // stays a true lower bound.
                    item.incomplete = YES;
                    unsigned long long left = appFreed;
                    unsigned long long fromCache = MIN(left, item.cacheBytes);
                    item.cacheBytes -= fromCache;
                    left -= fromCache;
                    item.tempBytes -= MIN(left, item.tempBytes);
                } else if (isLogs) {
                    unsigned long long remaining = 0;
                    BOOL complete = YES;
                    for (NSString *root in item.logRoots) {
                        BOOL rootComplete = YES;
                        remaining += cleaner_tree_bytes_walk(root, &rootComplete, &traversal);
                        complete = complete && rootComplete;
                    }
                    item.cacheBytes = remaining;
                    item.incomplete = !complete;
                } else if (trustedContainerFD >= 0 && item.customRelative) {
                    BOOL complete = NO;
                    item.cacheBytes = cleaner_custom_bytes_at(trustedContainerFD, item.customRelative, item.customIsFile,
                                                              trustedContainerDevice, &complete, &traversal);
                    item.tempBytes = 0;
                    item.incomplete = !complete;
                } else if (trustedContainerFD >= 0) {
                    // Shared traversal: rescans draw from the same 60 s budget
                    // as the deletions instead of starting fresh 15 s clocks.
                    BOOL complete = NO;
                    item.cacheBytes = cleaner_tree_bytes_at(trustedContainerFD, @"Library/Caches",
                                                            trustedContainerDevice, &complete, &traversal);
                    item.incomplete = !complete;
                    complete = NO;
                    item.tempBytes = cleaner_tree_bytes_at(trustedContainerFD, @"tmp",
                                                           trustedContainerDevice, &complete, &traversal);
                    item.incomplete = item.incomplete || !complete;
                } else {
                    // Identity could not be re-verified (app changed since the
                    // scan): keep the last known sizes — the row must not
                    // resurface looking empty or cleaned.
                    item.incomplete = YES;
                }
                if (trustedContainerFD >= 0) close(trustedContainerFD);
                item.selected = NO;
                if (failed > 0) failedItems++;
                if (removed > 0) {
                    if (isLogs) cleanedLogs = YES;
                    else cleanedApps++;
                }
                // Progress reflects finished items, not started ones: the bar
                // only reaches 100% when the pass has actually ended.
                done++;
                float fraction = (float)done / (float)MAX(work.count, (NSUInteger)1);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.cleanProgress setProgress:fraction animated:YES];
                });
            }

            BOOL interrupted = cleaner_traversal_should_stop(&traversal, 0);
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (bgTask != UIBackgroundTaskInvalid) {
                    [UIApplication.sharedApplication endBackgroundTask:bgTask];
                    bgTask = UIBackgroundTaskInvalid;
                }
                if (!self) return;
                self.cleaning = NO;
                if (processUnavailable) {
                    self.processListAvailable = NO;
                    self.sectionCacheValid = NO;  // everything moves to Not Checked
                }
                NSMutableString *result = [NSMutableString stringWithFormat:
                    @"Removed %@ (logical size).", cleaner_bytes(freed)];
                if (cleanedApps > 0)
                    [result appendFormat:@" %lu app%@ cleaned.", (unsigned long)cleanedApps,
                     cleanedApps == 1 ? @"" : @"s"];
                if (cleanedLogs) [result appendString:@" Crash logs removed."];
                if (skippedActive > 0)
                    [result appendFormat:@" Skipped %lu active app%@.", (unsigned long)skippedActive,
                     skippedActive == 1 ? @"" : @"s"];
                if (skippedChanged > 0)
                    [result appendFormat:@" Skipped %lu app%@ that changed since the scan; rescan to clean.",
                     (unsigned long)skippedChanged, skippedChanged == 1 ? @"" : @"s"];
                if (failedItems > 0)
                    [result appendFormat:@" Some files in %lu item%@ could not be removed.",
                     (unsigned long)failedItems, failedItems == 1 ? @"" : @"s"];
                if (interrupted)
                    [result appendString:@" Cleaning stopped at a safety limit or background expiration; results are partial."];
                if (processUnavailable)
                    [result appendString:@" Stopped: active-app detection was unavailable; remaining roots were not cleaned."];
                // Users read a refill minutes later as "it didn't work".
                if (freed > 0)
                    [result appendString:@" Apps rebuild their caches as you use them, so some of this space will be used again."];
                self.resultText = result;
                NSMutableDictionary<NSString *, CYCleanerItem *> *results = [NSMutableDictionary dictionary];
                CYCleanerItem *logsResult = nil;
                for (CYCleanerItem *item in work) {
                    if (item.isCrashLogs) logsResult = item;
                    else if (item.key.length) results[item.key] = item;
                }
                NSMutableArray<CYCleanerItem *> *published = [NSMutableArray array];
                for (CYCleanerItem *oldItem in self.items) {
                    CYCleanerItem *item = results[oldItem.key] ?: oldItem;
                    // Without the process list the apps can't be deselected
                    // (Not Checked); a leftover selection would block Clean.
                    if (processUnavailable) item.selected = NO;
                    if (item.totalBytes > 0 || item.incomplete || item.customRelative) [published addObject:item];
                }
                // Replace the model and reload together. Offscreen folder-review
                // controllers keep their original stable item snapshots.
                self.items = published;
                self.crashLogs = cleaner_published_crash_logs(self.crashLogs, logsResult);
                [self.tableView reloadData];
                [self updateControls];
                UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.resultText);
            });
        }
    });
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return CYCleanerSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == CYCleanerSectionSummary) return 1;
    NSInteger count = (NSInteger)[self itemsInSection:section].count;
    if (section == CYCleanerSectionSkipped && !self.skippedExpanded) return 0;
    return count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    NSUInteger count = section == CYCleanerSectionSummary ? 0 : [self itemsInSection:section].count;
    if (!count) return nil;
    switch ((CYCleanerSection)section) {
        case CYCleanerSectionApps:   return [NSString stringWithFormat:@"Apps (%lu)", (unsigned long)count];
        case CYCleanerSectionCustom: return [NSString stringWithFormat:@"Added by You (%lu)", (unsigned long)count];
        case CYCleanerSectionSystem: return [NSString stringWithFormat:@"Built-in Apps (%lu)", (unsigned long)count];
        case CYCleanerSectionLogs:   return [NSString stringWithFormat:@"Crash Logs (%lu)", (unsigned long)count];
        default: return nil;
    }
}

// "Skipped (in use)" folds open and closed on tap.
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (section != CYCleanerSectionSkipped) return nil;
    NSUInteger count = [self itemsInSection:section].count;
    if (!count) return nil;
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.title = [NSString stringWithFormat:@"%@ (%lu)", self.processListAvailable ? @"Skipped — In Use" : @"Not Checked",
                 (unsigned long)count];
    cfg.image = [UIImage systemImageNamed:self.skippedExpanded ? @"chevron.down" : @"chevron.right"];
    cfg.imagePlacement = NSDirectionalRectEdgeTrailing;
    cfg.imagePadding = 6;
    cfg.baseForegroundColor = UIColor.secondaryLabelColor;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(8, 20, 4, 20);
    __weak typeof(self) weakSelf = self;
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
        weakSelf.skippedExpanded = !weakSelf.skippedExpanded;
        [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:CYCleanerSectionSkipped]
                          withRowAnimation:UITableViewRowAnimationAutomatic];
    }]];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    return b;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if (section == CYCleanerSectionSkipped)
        return [self itemsInSection:section].count ? 40 : CGFLOAT_MIN;
    return UITableViewAutomaticDimension;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    // Right under the card, where it's seen: how the list works.
    if (section == CYCleanerSectionSummary)
        return !self.loading && self.items.count
            ? @"Tap an app or Crash Logs to select or deselect it. Touch and hold an app to open its cache folders in the File Browser."
            : nil;
    if (section == CYCleanerSectionCustom && [self itemsInSection:section].count)
        return @"Folders and files you added from the File Browser (touch and hold one there → Add to Cache Cleaner). "
               @"A folder is emptied, a file deleted. They are never selected by default; touch and hold one here to remove it from this list.";
    if (section != CYCleanerSectionSkipped) return nil;
    return @"Only Library/Caches and tmp contents, plus the optional CrashReporter folders, are removed. "
           @"Documents, settings and app data are not touched. Active-app checks are best-effort; built-in apps and Crash Logs are not selected by default.";
}

- (void)configureSummary:(CYCleanerSummaryCell *)cell
{
    unsigned long long total = [self totalBytes], selected = [self selectedBytes];
    if (self.loading) {
        [cell.spinner startAnimating];
        cell.bar.progressTintColor = UIColor.systemBlueColor;
        switch (self.phase) {
            case CYCleanerPhaseAccess:
                cell.captionLabel.text = @"Getting File Access";
                cell.totalLabel.text = @"Preparing…";
                cell.bar.progress = 0;
                cell.statusLabel.text = @"Cyanide opens SpringBoard to reach other apps' folders. This takes a few "
                                        @"seconds the first time after Cyanide starts.";
                break;
            case CYCleanerPhaseFinding:
                cell.captionLabel.text = @"Finding Apps";
                cell.totalLabel.text = self.foundTotal ? [NSString stringWithFormat:@"%lu / %lu",
                                                          (unsigned long)self.foundDone, (unsigned long)self.foundTotal] : @"…";
                cell.bar.progress = self.foundTotal ? (float)self.foundDone / (float)self.foundTotal : 0;
                cell.statusLabel.text = @"Reading each app's name and icon.";
                break;
            case CYCleanerPhaseProcesses:
                cell.captionLabel.text = @"Checking Running Apps";
                cell.totalLabel.text = @"…";
                cell.bar.progress = 1;
                cell.statusLabel.text = @"Apps in use are left alone.";
                break;
            case CYCleanerPhaseLogs:
                cell.captionLabel.text = @"Checking Crash Logs";
                cell.totalLabel.text = @"…";
                cell.bar.progress = 1;
                cell.statusLabel.text = @"Reading CrashReporter folders.";
                break;
            case CYCleanerPhaseScanning:
                cell.captionLabel.text = @"Measuring Caches";
                cell.totalLabel.text = self.scanTotal ? [NSString stringWithFormat:@"%lu / %lu",
                                                         (unsigned long)self.scanDone, (unsigned long)self.scanTotal] : @"…";
                cell.bar.progress = self.scanTotal ? (float)self.scanDone / (float)self.scanTotal : 0;
                cell.statusLabel.text = self.scanName.length ? [NSString stringWithFormat:@"Checking %@…", self.scanName]
                                                             : @"Starting…";
                break;
        }
        return;
    }
    [cell.spinner stopAnimating];
    cell.bar.progressTintColor = UIColor.systemBlueColor;
    if (!self.accessReady) {
        cell.captionLabel.text = @"Cache Cleaner";
        cell.totalLabel.text = @"—";
        cell.bar.progress = 0;
        cell.statusLabel.text = self.accessMessage ?: (cleaner_intro_accepted() ? @"Filesystem access is not available."
                                                                                : @"Read the note first; nothing is scanned until then.");
        return;
    }
    cell.captionLabel.text = @"Reclaimable";
    cell.totalLabel.text = cleaner_bytes(total);
    cell.bar.progress = total ? (float)((double)selected / (double)total) : 0;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (self.resultText) [lines addObject:self.resultText];
    [lines addObject:[NSString stringWithFormat:@"%@ selected in %lu item%@", cleaner_bytes(selected),
                      (unsigned long)[self selectedCount], [self selectedCount] == 1 ? @"" : @"s"]];
    [lines addObject:@"Logical file sizes, not guaranteed recovered storage."];
    if (!self.processListAvailable)
        [lines addObject:@"Kernel access is unavailable, so apps in use can't be detected and nothing can be cleaned."];
    cell.statusLabel.text = [lines componentsJoinedByString:@"\n"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == CYCleanerSectionSummary) {
        CYCleanerSummaryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cleaner-summary"];
        if (!cell) cell = [[CYCleanerSummaryCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                      reuseIdentifier:@"cleaner-summary"];
        [self configureSummary:cell];
        return cell;
    }
    CYCleanerItem *item = [self itemsInSection:indexPath.section][(NSUInteger)indexPath.row];
    CYCleanerAppCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cleaner-app"];
    if (!cell) cell = [[CYCleanerAppCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cleaner-app"];
    BOOL selectable = [self itemSelectable:item];
    cell.nameLabel.text = item.name;
    cell.nameLabel.textColor = selectable ? UIColor.labelColor : UIColor.secondaryLabelColor;
    cell.iconView.image = item.icon ?: [UIImage systemImageNamed:@"app.dashed"];
    cell.iconView.tintColor = UIColor.tertiaryLabelColor;
    if (item.isCrashLogs) {
        cell.iconView.image = [UIImage systemImageNamed:@"doc.text.magnifyingglass"];
        cell.iconView.tintColor = UIColor.systemOrangeColor;
        cell.detailLabel.text = [NSString stringWithFormat:@"%lu crash log file%@ · CrashReporter",
                                 (unsigned long)item.fileCount, item.fileCount == 1 ? @"" : @"s"];
        if (item.incomplete) cell.detailLabel.text = [cell.detailLabel.text stringByAppendingString:@" · incomplete scan"];
    } else if (item.customRelative) {
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:item.customRelative];
        if (item.active) [parts addObject:@"in use"];
        else if (item.incomplete) [parts addObject:@"incomplete scan"];
        cell.detailLabel.text = [parts componentsJoinedByString:@" · "];
    } else {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (item.cacheBytes > 0) [parts addObject:[NSString stringWithFormat:@"%@ cache", cleaner_bytes(item.cacheBytes)]];
        if (item.tempBytes > 0) [parts addObject:[NSString stringWithFormat:@"%@ temp", cleaner_bytes(item.tempBytes)]];
        if (item.active) [parts addObject:@"in use"];
        else if (item.incomplete) [parts addObject:@"incomplete scan"];
        cell.detailLabel.text = [parts componentsJoinedByString:@" · "];
    }
    cell.sizeLabel.text = item.incomplete ? [@"≥ " stringByAppendingString:cleaner_bytes(item.totalBytes)]
                                          : cleaner_bytes(item.totalBytes);
    cell.checkView.image = [UIImage systemImageNamed:item.active ? @"minus.circle"
                                                    : item.selected ? @"checkmark.circle.fill" : @"circle"];
    cell.checkView.tintColor = item.selected ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
    cell.selectionStyle = selectable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessibilityTraits = item.selected ? UIAccessibilityTraitSelected : UIAccessibilityTraitNone;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == CYCleanerSectionSummary)
        return !self.accessReady && !self.loading && !cleaner_intro_accepted() ? YES
             : !self.accessReady && !self.loading && self.accessMessage != nil &&
               ![self.accessMessage isEqualToString:kSettingsNoKernelAccessHint];
    return [self itemSelectable:[self itemsInSection:indexPath.section][(NSUInteger)indexPath.row]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == CYCleanerSectionSummary) {
        if (!cleaner_intro_accepted()) { [self showIntroIfNeeded]; return; }
        if (!self.accessReady && !self.loading) {
            if (![self.accessMessage isEqualToString:kSettingsNoKernelAccessHint])
                [self ensureAccessAllowingFullExploit:NO];
        }
        return;
    }
    CYCleanerItem *item = [self itemsInSection:indexPath.section][(NSUInteger)indexPath.row];
    if (![self itemSelectable:item]) return;
    item.selected = !item.selected;
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self reloadSummary];
    [self updateControls];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (indexPath.section == CYCleanerSectionSummary) return nil;
    // No folder browsing mid-clean: the pushed File Browser would show a
    // tree that is actively being deleted underneath it.
    if (self.cleaning) return nil;
    CYCleanerItem *item = [self itemsInSection:indexPath.section][(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *s) {
        NSMutableArray *actions = [NSMutableArray array];
        if (item.isCrashLogs) {
            for (NSString *root in item.logRoots) {
                NSString *name = root.lastPathComponent.length ? root.lastPathComponent : root;
                [actions addObject:[UIAction actionWithTitle:[NSString stringWithFormat:@"Show %@ in File Browser", name]
                                                       image:[UIImage systemImageNamed:@"folder"]
                                                  identifier:nil
                                                     handler:^(UIAction *a) { [weakSelf openInFileBrowser:root]; }]];
            }
        } else if (item.customRelative) {
            NSString *full = [item.container.path stringByAppendingPathComponent:item.customRelative];
            NSString *folder = item.customIsFile ? full.stringByDeletingLastPathComponent : full;
            [actions addObject:[UIAction actionWithTitle:@"Show in File Browser" image:[UIImage systemImageNamed:@"folder"]
                                              identifier:nil handler:^(UIAction *a) { [weakSelf openInFileBrowser:folder]; }]];
            UIAction *remove = [UIAction actionWithTitle:@"Remove from Cache Cleaner" image:[UIImage systemImageNamed:@"minus.circle"]
                                              identifier:nil handler:^(UIAction *a) { [weakSelf removeCustomItem:item]; }];
            remove.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:remove];
        } else {
            NSString *caches = [item.container.path stringByAppendingPathComponent:@"Library/Caches"];
            NSString *tmp = [item.container.path stringByAppendingPathComponent:@"tmp"];
            [actions addObject:[UIAction actionWithTitle:@"Show Caches in File Browser" image:[UIImage systemImageNamed:@"folder"]
                                               identifier:nil handler:^(UIAction *a) { [weakSelf openInFileBrowser:caches]; }]];
            if (item.tempBytes > 0)
                [actions addObject:[UIAction actionWithTitle:@"Show tmp in File Browser" image:[UIImage systemImageNamed:@"folder"]
                                                  identifier:nil handler:^(UIAction *a) { [weakSelf openInFileBrowser:tmp]; }]];
        }
        return [UIMenu menuWithTitle:item.name children:actions];
    }];
}

@end


@implementation CYCleanerFoldersViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"Folders to Clean";
    return self;
}

- (NSArray<NSDictionary<NSString *, id> *> *)foldersForItem:(CYCleanerItem *)item
{
    NSMutableArray *out = [NSMutableArray array];
    if (item.isCrashLogs) {
        for (NSString *root in item.logRoots) {
            NSNumber *bytes = item.logRootBytes[root] ?: @(item.cacheBytes);
            [out addObject:@{ @"title": @"CrashReporter",
                              @"path": root,
                              @"bytes": bytes }];
        }
        return out;
    }
    if (item.cacheBytes > 0) {
        [out addObject:@{ @"title": @"Library/Caches",
                          @"path": [item.container.path stringByAppendingPathComponent:@"Library/Caches"],
                          @"bytes": @(item.cacheBytes) }];
    }
    if (item.tempBytes > 0) {
        [out addObject:@{ @"title": @"tmp",
                          @"path": [item.container.path stringByAppendingPathComponent:@"tmp"],
                          @"bytes": @(item.tempBytes) }];
    }
    return out;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return self.items.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return [self foldersForItem:self.items[section]].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return self.items[section].name;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *folder = [self foldersForItem:self.items[indexPath.section]][indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cleaner-folder"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                             reuseIdentifier:@"cleaner-folder"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = folder[@"path"];
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 3;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
        folder[@"title"], cleaner_bytes([(NSNumber *)folder[@"bytes"] unsignedLongLongValue])];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

@end
