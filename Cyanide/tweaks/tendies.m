//
//  tendies.m
//  Cyanide
//
//  .tendies wallpaper files into PosterBoard's gallery. A .tendies file is a
//  zip of PosterBoard "descriptors": one folder per wallpaper, which PosterBoard
//  lists in the Lock Screen's wallpaper gallery. Installing one means copying
//  each descriptor folder into
//    <PosterBoard data container>/Library/Application Support/
//      PRBPosterExtensionDataStore/<version>/Extensions/<extension>/descriptors/<UUID>
//  with a fresh wallpaper id, then restarting PosterBoard so it rescans.
//  Layout and id handling follow Nugget by leminlimez and mond by rooootdev.
//

#import "tendies.h"
#import "darksword_ota.h"
#import "../LogTextView.h"
#import "../SBLArchiveExtractor.h"
#import "../utils/process.h"
#import <signal.h>

static NSString * const kTDPosterBoardID   = @"com.apple.PosterBoard";
static NSString * const kTDCollectionsExt  = @"com.apple.WallpaperKit.CollectionsPoster";
static NSString * const kTDPhotosExt       = @"com.apple.PhotosUIPrivate.PhotosPosterProvider";
static NSString * const kTDMercuryExt      = @"com.apple.MercuryPoster";
static NSString * const kTDIdentifierFile  = @"com.apple.posterkit.provider.descriptor.identifier";
static NSString * const kTDUserInfoFile    = @"com.apple.posterkit.provider.contents.userInfo";
static NSString * const kTDAddedKey        = @"TendiesAddedDescriptors";
// Nugget refuses more than 10 descriptors per apply; PosterBoard gets slow
// and unstable with many custom ones.
static const NSUInteger kTDMaxPerInstall   = 10;

#pragma mark - Bookkeeping

NSArray<NSDictionary *> *tendies_added(void)
{
    NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:kTDAddedKey];
    NSMutableArray *out = [NSMutableArray array];
    for (id item in list) {
        if ([item isKindOfClass:NSDictionary.class] && [item[@"path"] isKindOfClass:NSString.class]) [out addObject:item];
    }
    return out;
}

static void td_set_added(NSArray<NSDictionary *> *list)
{
    [NSUserDefaults.standardUserDefaults setObject:list forKey:kTDAddedKey];
}

#pragma mark - PosterBoard's container

static NSString *td_posterboard_container(void)
{
    static NSString *cached;
    if (cached && [NSFileManager.defaultManager fileExistsAtPath:cached]) return cached;
    NSString *root = @"/private/var/mobile/Containers/Data/Application";
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    for (NSString *name in names) {
        NSString *dir = [root stringByAppendingPathComponent:name];
        NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([plist[@"MCMMetadataIdentifier"] isEqual:kTDPosterBoardID]) {
            cached = dir;
            return dir;
        }
    }
    return nil;
}

// .../PRBPosterExtensionDataStore/<version>/Extensions. The version is 61 on
// iOS 17 and 18; take the highest one PosterBoard actually has.
static NSString *td_extensions_root(NSString *container)
{
    NSString *store = [container stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore"];
    NSInteger best = -1;
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:store error:nil]) {
        NSInteger v = name.integerValue;
        if (v <= 0 || ![name isEqualToString:@(v).stringValue]) continue;
        BOOL isDir = NO;
        NSString *ext = [[store stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Extensions"];
        if ([NSFileManager.defaultManager fileExistsAtPath:ext isDirectory:&isDir] && isDir && v > best) best = v;
    }
    if (best < 0) best = 61;
    return [[store stringByAppendingPathComponent:@(best).stringValue] stringByAppendingPathComponent:@"Extensions"];
}

#pragma mark - Reading a .tendies

static BOOL td_is_dir(NSString *path)
{
    BOOL isDir = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] && isDir;
}

static NSArray<NSString *> *td_visible_children(NSString *dir)
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]
                               sortedArrayUsingSelector:@selector(compare:)]) {
        if ([name hasPrefix:@"."] || [name isEqualToString:@"__MACOSX"]) continue;
        [out addObject:[dir stringByAppendingPathComponent:name]];
    }
    return out;
}

// Nugget's naming: "video-descriptor(s)" / "photos..." go to the Photos
// poster, "mercury..." to Mercury, every other descriptor folder to Collections.
static NSString *td_extension_for_folder_name(NSString *name)
{
    NSString *n = name.lowercaseString;
    if ([n containsString:@"video"] || [n containsString:@"photos"]) return kTDPhotosExt;
    if ([n containsString:@"mercury"]) return kTDMercuryExt;
    return kTDCollectionsExt;
}

static BOOL td_is_descriptor_group(NSString *name)
{
    NSString *n = name.lowercaseString;
    return [n hasSuffix:@"descriptor"] || [n hasSuffix:@"descriptors"];
}

static void td_add(NSMutableArray *found, NSString *ext, NSString *dir)
{
    if (td_is_dir(dir)) [found addObject:@[ext, dir]];
}

// Returns [extension, descriptor folder] pairs.
static NSArray<NSArray<NSString *> *> *td_find_descriptors(NSString *root)
{
    NSMutableArray *found = [NSMutableArray array];
    NSArray *top = td_visible_children(root);
    // Some zips wrap everything in one folder.
    if (top.count == 1 && td_is_dir(top[0]) && !td_is_descriptor_group([top[0] lastPathComponent]) &&
        ![[top[0] lastPathComponent].lowercaseString isEqualToString:@"container"]) {
        root = top[0];
        top = td_visible_children(root);
    }

    // 1. A full container layout: container/Library/.../Extensions/<ext>/descriptors/*
    for (NSString *dir in top) {
        if (![dir.lastPathComponent.lowercaseString isEqualToString:@"container"]) continue;
        NSString *store = [dir stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore"];
        for (NSString *version in td_visible_children(store)) {
            for (NSString *ext in td_visible_children([version stringByAppendingPathComponent:@"Extensions"])) {
                for (NSString *d in td_visible_children([ext stringByAppendingPathComponent:@"descriptors"]))
                    td_add(found, ext.lastPathComponent, d);
            }
        }
        if (found.count) return found;
    }

    // 2. Nugget's usual layout: descriptors/<UUID>, video-descriptors/<UUID> ...
    for (NSString *dir in top) {
        if (!td_is_dir(dir) || !td_is_descriptor_group(dir.lastPathComponent)) continue;
        NSString *ext = td_extension_for_folder_name(dir.lastPathComponent);
        for (NSString *d in td_visible_children(dir)) td_add(found, ext, d);
    }
    if (found.count) return found;

    // 3. Anything else: folders holding the descriptor identifier file.
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:root];
    for (NSString *rel in e) {
        NSString *path = [root stringByAppendingPathComponent:rel];
        if ([rel.lastPathComponent hasPrefix:@"."] || [rel.lastPathComponent isEqualToString:@"__MACOSX"]) {
            [e skipDescendants];
            continue;
        }
        if (!td_is_dir(path)) continue;
        if ([NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:kTDIdentifierFile]]) {
            NSString *parent = path.stringByDeletingLastPathComponent.lastPathComponent;
            td_add(found, td_extension_for_folder_name(parent), path);
            [e skipDescendants];
        }
    }
    return found;
}

#pragma mark - Wallpaper ids

static void td_set_plist_value(NSString *file, NSString *key, id value)
{
    NSData *data = [NSData dataWithContentsOfFile:file];
    if (!data) return;
    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers
                                                          format:&format error:nil];
    if (![plist isKindOfClass:NSMutableDictionary.class]) return;
    ((NSMutableDictionary *)plist)[key] = value;
    NSData *out = [NSPropertyListSerialization dataWithPropertyList:plist format:format options:0 error:nil];
    [out writeToFile:file atomically:YES];
}

// Every wallpaper needs its own id, or PosterBoard treats copies of the same
// file (or a wallpaper already on the device) as one and drops it.
// Also drops macOS litter (.DS_Store, AppleDouble "._*" files). Other dot
// files are real PosterKit files (.com.apple.posterkit...configurableOptions)
// and stay. Paths are collected first: changing the tree while enumerating it
// ends the enumeration early.
static void td_randomize_id(NSString *descriptor)
{
    NSNumber *wallpaperID = @(9999 + arc4random_uniform(90000));
    NSArray<NSString *> *all = [NSFileManager.defaultManager enumeratorAtPath:descriptor].allObjects;
    for (NSString *rel in all) {
        NSString *name = rel.lastPathComponent;
        NSString *path = [descriptor stringByAppendingPathComponent:rel];
        if ([name isEqualToString:@".DS_Store"] || [name hasPrefix:@"._"]) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        } else if ([name isEqualToString:kTDIdentifierFile]) {
            [[wallpaperID.stringValue dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
        } else if ([name isEqualToString:kTDUserInfoFile]) {
            td_set_plist_value(path, @"wallpaperRepresentingIdentifier", wallpaperID);
        } else if ([name hasSuffix:@"Wallpaper.plist"]) {
            td_set_plist_value(path, @"identifier", wallpaperID);
        }
    }
}

#pragma mark - PosterBoard restart

// PosterBoard only rescans its descriptors when it starts. launchd starts it
// again right away. Same kill as the Process Viewer (KRW identity checks).
static BOOL td_restart_posterboard(void)
{
    static procmgr_entry_t entries[2048];
    int n = procmgr_list(entries, 2048);
    if (n < 0) return NO;
    BOOL found = NO, killed = NO;
    for (int i = 0; i < n; i++) {
        if (strcmp(entries[i].name, "PosterBoard") != 0) continue;
        found = YES;
        int rc = procmgr_kill(entries[i].pid, entries[i].name, entries[i].kproc);
        printf("[TENDIES] restart PosterBoard pid %d: rc=%d\n", entries[i].pid, rc);
        if (rc == 0) killed = YES;
    }
    // Not running is fine too: it reads the new descriptors when it starts.
    return killed || !found;
}

#pragma mark - Install / remove

static NSString *td_display_name(NSURL *file)
{
    NSString *name = file.lastPathComponent.stringByDeletingPathExtension;
    return name.length ? name : @"Wallpaper";
}

BOOL tendies_install(NSArray<NSURL *> *files, NSUInteger *added, NSString **message)
{
    __autoreleasing NSString *dummy = nil;
    if (!message) message = &dummy;
    if (added) *added = 0;
    if (!darksword_prepare_var_rw()) {
        *message = @"No access to /private/var (the sandbox could not be lifted).";
        return NO;
    }
    NSString *container = td_posterboard_container();
    if (!container) {
        *message = @"PosterBoard's data folder wasn't found.";
        return NO;
    }
    NSString *extensions = td_extensions_root(container);
    printf("[TENDIES] PosterBoard extensions: %s\n", extensions.UTF8String);

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *list = [tendies_added() mutableCopy];
    NSUInteger total = 0;
    NSMutableArray<NSString *> *problems = [NSMutableArray array];

    for (NSURL *file in files) {
        NSString *name = td_display_name(file);
        NSString *staging = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [@"tendies-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSError *error = nil;
        if (!SBLExtractArchiveToDirectory(file, staging, &error)) {
            [problems addObject:[NSString stringWithFormat:@"%@: not a valid .tendies file (%@)", name,
                                 error.localizedDescription ?: @"unreadable"]];
            continue;
        }
        NSArray *descriptors = td_find_descriptors(staging);
        if (descriptors.count == 0) {
            [problems addObject:[NSString stringWithFormat:@"%@: no wallpapers inside", name]];
            [fm removeItemAtPath:staging error:nil];
            continue;
        }
        if (total + descriptors.count > kTDMaxPerInstall) {
            [problems addObject:[NSString stringWithFormat:@"%@: skipped, at most %lu wallpapers per install",
                                 name, (unsigned long)kTDMaxPerInstall]];
            [fm removeItemAtPath:staging error:nil];
            continue;
        }

        NSMutableArray<NSString *> *written = [NSMutableArray array];
        BOOL fileOK = YES;
        for (NSArray<NSString *> *pair in descriptors) {
            NSString *destDir = [[extensions stringByAppendingPathComponent:pair[0]] stringByAppendingPathComponent:@"descriptors"];
            if (![fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:&error]) {
                printf("[TENDIES] mkdir %s failed: %s\n", destDir.UTF8String, error.localizedDescription.UTF8String);
                fileOK = NO;
                break;
            }
            td_randomize_id(pair[1]);
            NSString *dest = [destDir stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
            if (![fm copyItemAtPath:pair[1] toPath:dest error:&error]) {
                printf("[TENDIES] copy to %s failed: %s\n", dest.UTF8String, error.localizedDescription.UTF8String);
                [fm removeItemAtPath:dest error:nil];
                fileOK = NO;
                break;
            }
            printf("[TENDIES] %s → %s\n", name.UTF8String, dest.UTF8String);
            [written addObject:dest];
        }
        [fm removeItemAtPath:staging error:nil];
        if (!fileOK) {
            for (NSString *path in written) [fm removeItemAtPath:path error:nil];
            [problems addObject:[NSString stringWithFormat:@"%@: copying into PosterBoard failed (%@)", name,
                                 error.localizedDescription ?: @"see the log"]];
            continue;
        }
        for (NSString *path in written) {
            NSString *title = written.count > 1
                ? [NSString stringWithFormat:@"%@ (%lu)", name, (unsigned long)([written indexOfObject:path] + 1)]
                : name;
            [list addObject:@{ @"name": title, @"path": path, @"date": NSDate.date }];
        }
        total += written.count;
    }
    td_set_added(list);
    if (added) *added = total;

    if (total > 0 && !td_restart_posterboard()) {
        [problems addObject:@"PosterBoard couldn't be restarted; restart the device to see the new wallpapers"];
    }
    for (NSString *p in problems) log_user("[TENDIES] %s\n", p.UTF8String);
    if (total == 0) {
        *message = problems.count ? [problems componentsJoinedByString:@"\n"] : @"Nothing was installed.";
        return NO;
    }
    *message = problems.count ? [problems componentsJoinedByString:@"\n"] : nil;
    log_user("[OK] Tendies: installed %lu wallpaper%s\n", (unsigned long)total, total == 1 ? "" : "s");
    return YES;
}

BOOL tendies_remove(NSArray<NSString *> *paths, NSString **message)
{
    __autoreleasing NSString *dummy = nil;
    if (!message) message = &dummy;
    if (!darksword_prepare_var_rw()) {
        *message = @"No access to /private/var (the sandbox could not be lifted).";
        return NO;
    }
    NSString *container = td_posterboard_container();
    NSString *extensions = container ? td_extensions_root(container) : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *keep = [NSMutableArray array];
    NSUInteger removed = 0, failed = 0;
    for (NSDictionary *item in tendies_added()) {
        NSString *path = item[@"path"];
        if (paths && ![paths containsObject:path]) { [keep addObject:item]; continue; }
        // Only ever delete a folder of our own inside a descriptors folder of
        // PosterBoard's extension store.
        NSString *standard = path.stringByStandardizingPath;
        BOOL inside = extensions.length && [standard hasPrefix:[extensions stringByAppendingString:@"/"]] &&
                      [standard.stringByDeletingLastPathComponent.lastPathComponent isEqualToString:@"descriptors"];
        if (!inside) {
            printf("[TENDIES] not removing unexpected path %s\n", path.UTF8String);
            failed++;
            continue;
        }
        NSError *error = nil;
        if (![fm fileExistsAtPath:standard] || [fm removeItemAtPath:standard error:&error]) {
            removed++;
        } else {
            printf("[TENDIES] remove %s failed: %s\n", standard.UTF8String, error.localizedDescription.UTF8String);
            [keep addObject:item];
            failed++;
        }
    }
    td_set_added(keep);
    if (removed > 0) (void)td_restart_posterboard();
    log_user("[%s] Tendies: removed %lu wallpaper%s%s\n", failed ? "WARN" : "OK", (unsigned long)removed,
             removed == 1 ? "" : "s", failed ? ", some failed (see log)" : "");
    if (failed) *message = @"Some wallpapers couldn't be removed. See the [TENDIES] lines in the log.";
    return failed == 0;
}
