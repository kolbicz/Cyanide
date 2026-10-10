//
//  PlistEditorViewController.h
//  Cyanide
//
//  Structured plist viewer/editor for the File Browser. Read-only unless the
//  File Browser's write mode is on; saves in place in the file's original
//  format (binary stays binary).
//

#import <UIKit/UIKit.h>

@interface PlistEditorViewController : UITableViewController
// Loading is separate from presentation so it can run off-main. Both return
// nil if the data isn't a dictionary/array plist or is larger than 10 MB.
+ (id)documentForFileAtPath:(NSString *)path;                        // any thread
+ (id)readOnlyDocumentForData:(NSData *)data path:(NSString *)path;  // any thread, e.g. read as root
+ (instancetype)editorWithDocument:(id)document;                     // main thread
@end
