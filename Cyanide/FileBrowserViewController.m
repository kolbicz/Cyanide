//
//  FileBrowserViewController.m
//  Cyanide
//

#import "FileBrowserViewController.h"
#import "SettingsViewController.h"
#import "PlistEditorViewController.h"
#import "installer/MainTabBarController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#import <fcntl.h>
#import <grp.h>
#import <pwd.h>
#import <sys/stat.h>

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
static BOOL g_fb_write_enabled = NO;

BOOL filebrowser_write_enabled(void) { return g_fb_write_enabled; }

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
// actually opened. Returns -1 for anything else.
int filebrowser_open_regular(NSString *path)
{
    struct stat pre;
    if (stat(path.fileSystemRepresentation, &pre) != 0 || !S_ISREG(pre.st_mode)) return -1;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) { close(fd); return -1; }
    // Regular file: back to blocking reads.
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
    return fd;
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

FBSaveResult filebrowser_save(NSString *path, NSData *data, FBFileIdentity expected, NSData *loaded,
                              BOOL force, FBFileIdentity *newIdentity, NSString **message)
{
    NSString *msg = nil;
    FBSaveResult result = FBSaveFailed;
    // Checked again here, at execution time: a save can wait in the file
    // queue behind other work while Changes get locked.
    if (!g_fb_write_enabled) {
        if (message) *message = @"Changes are locked. Unlock them in the File Browser first.";
        return FBSaveFailed;
    }
    int fd = open(path.fileSystemRepresentation, O_RDWR | O_NONBLOCK | O_CLOEXEC);
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
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
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
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"FileBrowserBackups"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *backup = [dir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"%@.%@.bak", path.lastPathComponent, NSUUID.UUID.UUIDString]];
        if (![currentData writeToFile:backup atomically:YES]) {
            msg = @"A backup of the current file couldn't be written. Nothing was changed.";
        } else if (fb_pwrite_all(fd, data)) {
            [NSFileManager.defaultManager removeItemAtPath:backup error:nil];
            if (newIdentity) *newIdentity = filebrowser_identity_fd(fd);
            filebrowser_note_filesystem_changed();
            result = FBSaveOK;
        } else {
            int werr = errno;
            filebrowser_note_filesystem_changed();   // the file may have changed
            if (fb_pwrite_all(fd, currentData)) {
                [NSFileManager.defaultManager removeItemAtPath:backup error:nil];
                if (newIdentity) *newIdentity = filebrowser_identity_fd(fd);
                msg = [NSString stringWithFormat:@"Writing failed (%s). The file's previous contents were written back.", strerror(werr)];
            } else {
                msg = [NSString stringWithFormat:@"Writing failed (%s), and restoring the previous contents failed too. "
                                                 @"The file may be damaged. A backup of its previous contents is at:\n%@",
                                                 strerror(werr), backup];
            }
        }
    }
    close(fd);
    if (message) *message = msg;
    return result;
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

#pragma mark - Entries

@interface FBEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
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

#pragma mark - File viewer

typedef NS_ENUM(NSInteger, FBViewMode) { FBViewText, FBViewImage, FBViewHex, FBViewInfo };

@interface FBFileViewController : UIViewController
- (instancetype)initWithEntry:(FBEntry *)entry;
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
        FBFileIdentity ident = {0};
        if (viaRoot) {
            data = settings_root_read_file(path, kFBMaxTextBytes, &truncated, NULL);
        } else {
            // Regular files only: a FIFO/device would block or have side
            // effects. Identity comes from the descriptor actually read, and a
            // read error leaves no data (never an "empty, editable" file).
            int fd = filebrowser_open_regular(path);
            if (fd < 0) {
                struct stat st;
                notRegular = stat(path.fileSystemRepresentation, &st) == 0 && !S_ISREG(st.st_mode);
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

// Text and plists can be edited when the whole file was loaded.
- (BOOL)canEdit
{
    // Root access is read-only (edits would need a root write path we don't have).
    return g_fb_write_enabled && !self.entry.viaRoot && self.data && !self.truncated &&
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
    // Hex sizes its own font to the width; everything else uses 12 pt.
    self.textView.font = [UIFont monospacedSystemFontOfSize:kFBHexBaseFont weight:UIFontWeightRegular];
    switch (mode) {
        case FBViewText:
            text = [self plistText] ?: [self utf8Text] ?: @"Not a text file. Try Hex.";
            if (self.truncated) text = [text stringByAppendingFormat:@"\n\n… first %@ shown", fb_size_string(kFBMaxTextBytes)];
            break;
        case FBViewImage: text = @"Not an image (or too large to show)."; break;
        case FBViewHex:   text = self.data ? [self hexText] : [self infoText]; break;
        case FBViewInfo:  text = [self infoText]; break;
    }
    self.textView.text = text;
    [self.textView setContentOffset:CGPointZero animated:NO];
}

// Hands a copy (from the app's temp folder) to the share sheet, so the
// receiving app never needs access to the original location.
// Shares the file's CONTENTS (a symlink's target, never the link itself) as
// a regular file in a per-share temp folder, so the receiving app never needs
// access to the original location. Runs off-main: a root read can wait for
// the launchd warm-up and transfer up to 64 MB.
static const NSUInteger kFBMaxShareBytes = 64 * 1024 * 1024;

- (void)shareCopy:(UIBarButtonItem *)sender
{
    if (self.sharing) return;
    self.sharing = YES;
    sender.enabled = NO;
    NSString *dir = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"FileBrowserShare"]
                     stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *copy = [dir stringByAppendingPathComponent:self.entry.name];
    NSString *path = self.entry.path;
    BOOL viaRoot = self.entry.viaRoot;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *failure = nil;
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (viaRoot) {
            NSString *rootErr = nil;
            BOOL truncated = NO;
            NSData *full = settings_root_read_file(path, kFBMaxShareBytes, &truncated, &rootErr);
            if (!full) failure = rootErr ?: @"The file could not be read as root.";
            else if (truncated) failure = @"The file is larger than 64 MB. Sharing only part of it is not supported.";
            else if (![full writeToFile:copy atomically:YES]) failure = @"The copy could not be written.";
        } else {
            int in = filebrowser_open_regular(path);
            int out = in < 0 ? -1 : open(copy.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
            if (in < 0) {
                failure = @"Only regular files can be shared.";
            } else if (out < 0) {
                failure = @"The copy could not be created.";
            } else {
                char buf[64 * 1024];
                ssize_t n;
                while ((n = read(in, buf, sizeof(buf))) > 0) {
                    if (write(out, buf, (size_t)n) != n) { failure = @"The copy could not be written."; break; }
                }
                if (n < 0) failure = @"The file could not be read.";
            }
            if (in >= 0) close(in);
            if (out >= 0) close(out);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.sharing = NO;
            sender.enabled = YES;
            if (!self.view.window) {   // left the screen meanwhile
                [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
                return;
            }
            if (failure) {
                [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
                fb_alert(self, @"Couldn't Share", failure);
                return;
            }
            UIActivityViewController *avc =
                [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:copy] ]
                                                  applicationActivities:nil];
            avc.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *err) {
                [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
            };
            avc.popoverPresentationController.barButtonItem = sender;
            [self presentViewController:avc animated:YES completion:nil];
        });
    });
}

@end

#pragma mark - Directory list

@interface FileBrowserViewController () <UISearchResultsUpdating, UIDocumentPickerDelegate>
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
@end

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
    self.navigationItem.searchController = self.searchCtrl;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [self reload];
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
    UIMenu *optionsMenu = [UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:@"Go to Folder…" image:[UIImage systemImageNamed:@"arrow.right.circle"]
                       identifier:nil handler:^(UIAction *x) { [weakOptions goToPath]; }],
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
        initWithImage:[UIImage systemImageNamed:g_fb_write_enabled ? @"lock.open.fill" : @"lock.fill"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(toggleWriteMode)];
    lock.tintColor = g_fb_write_enabled ? UIColor.systemRedColor : nil;
    lock.accessibilityLabel = g_fb_write_enabled ? @"Disable changes" : @"Enable changes";
    NSMutableArray *items = [NSMutableArray arrayWithObjects:go, lock, nil];
    if (g_fb_write_enabled && !self.loadedViaRoot) {   // root access is read-only
        __weak typeof(self) weakSelf = self;
        UIMenu *menu = [UIMenu menuWithChildren:@[
            [UIAction actionWithTitle:@"New Folder" image:[UIImage systemImageNamed:@"folder.badge.plus"]
                           identifier:nil handler:^(UIAction *a) { [weakSelf promptNewItem:YES]; }],
            [UIAction actionWithTitle:@"New File" image:[UIImage systemImageNamed:@"doc.badge.plus"]
                           identifier:nil handler:^(UIAction *a) { [weakSelf promptNewItem:NO]; }],
            [UIAction actionWithTitle:@"Import from Files…" image:[UIImage systemImageNamed:@"square.and.arrow.down"]
                           identifier:nil handler:^(UIAction *a) { [weakSelf importFromFiles]; }],
        ]];
        [items addObject:[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"] menu:menu]];
    }
    self.navigationItem.rightBarButtonItems = items;
}

- (void)toggleWriteMode
{
    if (g_fb_write_enabled) {
        g_fb_write_enabled = NO;
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
        g_fb_write_enabled = YES;
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
    if (!g_fb_write_enabled || self.loadedViaRoot) {
        fb_alert(self, title, @"Changes are locked.");
        return;
    }
    dispatch_async(fb_file_queue(), ^{
        NSError *err = nil;
        // Re-check when the job actually starts: locking while it was queued
        // cancels it. (A job that has started is left to finish.)
        BOOL ok = NO;
        if (g_fb_write_enabled) ok = op(&err);
        else err = fb_locked_error();
        NSString *message = err.localizedDescription;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) filebrowser_note_filesystem_changed();
            else fb_alert(self, title, message ?: @"The operation failed.");
            [self reload];
        });
    });
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
        [self perform:^BOOL(NSError **err) {
            return [NSFileManager.defaultManager moveItemAtPath:e.path toPath:target error:err];
        } failureTitle:@"Couldn't Rename"];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)duplicate:(FBEntry *)e
{
    NSString *dir = self.path;
    [self perform:^BOOL(NSError **err) {
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
        [self perform:^BOOL(NSError **err) {
            // A symlink is removed itself, never what it points to.
            return [NSFileManager.defaultManager removeItemAtPath:e.path error:err];
        } failureTitle:@"Couldn't Delete"];
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
    if (!g_fb_write_enabled || self.loadedViaRoot) {
        fb_alert(self, @"Not Imported", @"Changes are locked.");
        return;
    }
    NSString *dir = self.path;
    dispatch_async(fb_file_queue(), ^{
        NSMutableArray<NSString *> *failed = [NSMutableArray array];
        for (NSURL *url in urls) {
            if (!g_fb_write_enabled) {   // locked mid-import: stop before the next item
                [failed addObject:[NSString stringWithFormat:@"%@: changes were locked", url.lastPathComponent]];
                continue;
            }
            NSString *target = fb_unique_path(dir, url.lastPathComponent);
            NSError *err = nil;
            if (![NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:target] error:&err])
                [failed addObject:[NSString stringWithFormat:@"%@: %@", url.lastPathComponent, err.localizedDescription]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (failed.count < urls.count) filebrowser_note_filesystem_changed();
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
        NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:&err];
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
        if (!names && !status) {
            NSError *posix = err.userInfo[NSUnderlyingErrorKey];
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
        publish(entries, status, NO, NO);
    });
}

- (void)unlockThenReload
{
    [self.refreshControl endRefreshing];
    if (self.unlocking) return;
    self.unlocking = YES;
    self.status = @"Lifting the filesystem sandbox through SpringBoard… (one time per app launch)";
    [self applyFilter];
    __weak typeof(self) weakSelf = self;
    settings_unlock_filesystem_async(^(BOOL ok, NSString *message) {
        typeof(self) s = weakSelf;
        if (!s) return;
        s.unlocking = NO;
        if (ok) {
            [s reload];
        } else {
            s.status = message ?: @"Filesystem access is not available.";
            [s applyFilter];
        }
    });
}

- (void)applyFilter
{
    NSString *q = [self.filter stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!q.length) {
        self.shown = self.entries;
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(FBEntry *e, NSDictionary *b) {
            return [e.name rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        self.shown = [self.entries filteredArrayUsingPredicate:p];
    }
    // A cut-short root listing is a prefix of the folder, not all of it.
    if (self.listingIncomplete && self.entries.count) {
        UILabel *note = [UILabel new];
        note.text = [NSString stringWithFormat:@"Listing incomplete: only %lu entries could be read as root.",
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
    [self applyFilter];
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
        cell.textLabel.text = self.status ?: (self.filter.length ? @"No matches." : @"Loading…");
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
    if (e.statFailed) {
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
        dispatch_async(dispatch_get_main_queue(), ^{
            tableView.userInteractionEnabled = YES;
            // The user may have navigated away (Back/tab) meanwhile.
            if (!self.view.window || self.navigationController.topViewController != self) return;
            UIViewController *vc = doc ? [PlistEditorViewController editorWithDocument:doc] : nil;
            if (!vc) vc = [[FBFileViewController alloc] initWithEntry:e];
            [self.navigationController pushViewController:vc animated:YES];
        });
    });
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!g_fb_write_enabled || self.loadedViaRoot || !self.shown.count) return nil;
    FBEntry *e = self.shown[indexPath.row];
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
        if (!e.isDirectory) [items addObject:info];
        if (g_fb_write_enabled && !self.loadedViaRoot) {
            UIAction *ren = [UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"]
                                           identifier:nil handler:^(UIAction *a) { [self promptRename:e]; }];
            UIAction *dup = [UIAction actionWithTitle:@"Duplicate" image:[UIImage systemImageNamed:@"plus.square.on.square"]
                                           identifier:nil handler:^(UIAction *a) { [self duplicate:e]; }];
            UIAction *del = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"]
                                           identifier:nil handler:^(UIAction *a) { [self confirmDelete:e]; }];
            del.attributes = UIMenuElementAttributesDestructive;
            [items addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil
                                           options:UIMenuOptionsDisplayInline children:@[ ren, dup, del ]]];
        }
        return [UIMenu menuWithTitle:e.path children:items];
    }];
}

@end
