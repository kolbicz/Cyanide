//
//  tendies.h
//  Cyanide
//
//  Settings → Lara → Tendies Wallpapers: installs .tendies wallpaper files
//  (zipped PosterBoard descriptors, the format Nugget by leminlimez made) into
//  PosterBoard's wallpaper gallery. The approach follows Nugget and mond by
//  rooootdev. Blocking calls that need /private/var access and, to restart
//  PosterBoard, kernel access: run them from settings_kernel_file_tool_async.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Wallpapers Cyanide added: dictionaries with @"name" (the file's name),
// @"path" (the descriptor folder) and @"date". Newest last.
NSArray<NSDictionary *> *tendies_added(void);

// Copies every wallpaper in `files` into PosterBoard's gallery and restarts
// PosterBoard. *added receives the number of wallpapers installed. On failure
// nothing from the failing file stays behind; files before it are kept.
BOOL tendies_install(NSArray<NSURL *> *files, NSUInteger *added, NSString * _Nullable * _Nullable message);

// Removes the wallpapers Cyanide added (all of them when `paths` is nil) and
// restarts PosterBoard. Apple's and other tools' wallpapers are not touched.
BOOL tendies_remove(NSArray<NSString *> * _Nullable paths, NSString * _Nullable * _Nullable message);

NS_ASSUME_NONNULL_END
