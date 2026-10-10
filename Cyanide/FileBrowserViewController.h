//
//  FileBrowserViewController.h
//  Cyanide
//
//  Filesystem browser, read-only until changes are enabled with its lock
//  button. Works outside the app container once the sandbox is lifted
//  (settings_unlock_filesystem_async); still bound by Unix permissions, since
//  the app runs as mobile.
//

#import <UIKit/UIKit.h>
#include <sys/stat.h>

// Whether the user has enabled changes (lock button) for this app launch.
BOOL filebrowser_write_enabled(void);
// Call after any accepted change on disk, so open folders refresh.
void filebrowser_note_filesystem_changed(void);

// File identity at open time, to detect changes or a replaced/retargeted file
// before saving over it.
typedef struct {
    BOOL valid;
    dev_t dev;
    ino_t ino;
    off_t size;
    struct timespec mtime;
} FBFileIdentity;
FBFileIdentity filebrowser_identity(NSString *path);
BOOL filebrowser_identity_equal(FBFileIdentity a, FBFileIdentity b);

// In-place write that writes `original` back if it fails. nil = saved.
NSString *filebrowser_write_in_place(NSString *path, NSData *data, NSData *original);

// Opens a regular file (never a FIFO/device/socket) for reading; -1 otherwise.
int filebrowser_open_regular(NSString *path);

@interface FileBrowserViewController : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@end
