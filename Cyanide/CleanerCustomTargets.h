//
//  CleanerCustomTargets.h
//  Cyanide
//
//  Folders and files the user added to the Cache Cleaner from the File
//  Browser (#18: e.g. Instagram's leftover video uploads). Each one lies
//  inside one app's data container and is stored as that app's bundle ID plus
//  the path relative to the container, so it survives the container moving
//  (reinstall, restore). Folders are emptied, files deleted, only when the
//  user selects them in the Cache Cleaner; they are never pre-selected.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CYCleanerCustomTarget : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *relativePath;   // e.g. Library/Application Support/Instagram/VideoUpload
@property (nonatomic) BOOL isFile;
@property (nonatomic, copy) NSString *appName;        // for display when the app isn't installed
@end

// Whether `relative` may be a custom target: at least two path components,
// no "." / ".." / empty parts, under Library, Documents or tmp, and not one of
// the folders that hold the app's settings (Library/Preferences …).
BOOL cleaner_custom_target_valid_relative(NSString *relative);

NSArray<CYCleanerCustomTarget *> *cleaner_custom_targets(void);
BOOL cleaner_custom_target_contains(NSString *bundleID, NSString *relative);
// NO with *error when `relative` isn't allowed.
BOOL cleaner_custom_target_add(NSString *bundleID, NSString *appName, NSString *relative, BOOL isFile,
                               NSString *_Nullable *_Nullable error);
void cleaner_custom_target_remove(NSString *bundleID, NSString *relative);

NS_ASSUME_NONNULL_END
