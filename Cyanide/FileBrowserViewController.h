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

// Identity of an opened file (fstat on the descriptor that was read).
typedef struct {
    BOOL valid;
    dev_t dev;
    ino_t ino;
    off_t size;
    struct timespec mtime;
} FBFileIdentity;
FBFileIdentity filebrowser_identity_fd(int fd);

// Reads fd to EOF (max maxBytes). nil on any read error — never a partial
// read passed off as the whole file.
NSData *filebrowser_read_fd(int fd, NSUInteger maxBytes, BOOL *truncated, int *errOut);

// Conflict-checked save over the file opened as `expected` with contents
// `loaded`; backs up the current contents first and restores them if the
// write fails. Runs file I/O: call off the main thread.
typedef NS_ENUM(NSInteger, FBSaveResult) { FBSaveOK, FBSaveConflict, FBSaveFailed };
FBSaveResult filebrowser_save(NSString *path, NSData *data, FBFileIdentity expected, NSData *loaded,
                              BOOL force, FBFileIdentity *newIdentity, NSString **message);

// Opens a regular file (never a FIFO/device/socket) for reading; -1 otherwise.
int filebrowser_open_regular(NSString *path);

@interface FileBrowserViewController : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@end
