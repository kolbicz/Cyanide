//
//  CleanerCustomTargets.m
//  Cyanide
//

#import "CleanerCustomTargets.h"

static NSString * const kCleanerCustomTargetsKey = @"CleanerCustomTargets";

@implementation CYCleanerCustomTarget
@end

BOOL cleaner_custom_target_valid_relative(NSString *relative)
{
    if (![relative isKindOfClass:NSString.class] || !relative.length || [relative hasPrefix:@"/"]) return NO;
    NSArray<NSString *> *parts = [relative componentsSeparatedByString:@"/"];
    if (parts.count < 2) return NO;   // never Library, Documents or tmp as a whole
    for (NSString *part in parts)
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."] ||
            [part rangeOfString:@"\0"].location != NSNotFound) return NO;
    if (![@[ @"Library", @"Documents", @"tmp" ] containsObject:parts[0]]) return NO;
    // The app's settings and the container's own bookkeeping stay out.
    if ([parts[0] isEqualToString:@"Library"] &&
        [@[ @"Preferences", @"SyncedPreferences", @"Cookies", @"Saved Application State" ] containsObject:parts[1]]) return NO;
    return YES;
}

NSArray<CYCleanerCustomTarget *> *cleaner_custom_targets(void)
{
    NSMutableArray<CYCleanerCustomTarget *> *out = [NSMutableArray array];
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:kCleanerCustomTargetsKey];
    if (![stored isKindOfClass:NSArray.class]) return out;
    for (id entry in stored) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *bundle = entry[@"bundle"], *path = entry[@"path"], *app = entry[@"app"];
        if (![bundle isKindOfClass:NSString.class] || !bundle.length || !cleaner_custom_target_valid_relative(path)) continue;
        CYCleanerCustomTarget *t = [CYCleanerCustomTarget new];
        t.bundleID = bundle;
        t.relativePath = path;
        t.isFile = [entry[@"file"] isKindOfClass:NSNumber.class] && [entry[@"file"] boolValue];
        t.appName = [app isKindOfClass:NSString.class] && [(NSString *)app length] ? app : bundle;
        [out addObject:t];
    }
    return out;
}

BOOL cleaner_custom_target_contains(NSString *bundleID, NSString *relative)
{
    for (CYCleanerCustomTarget *t in cleaner_custom_targets())
        if ([t.bundleID isEqualToString:bundleID] && [t.relativePath isEqualToString:relative]) return YES;
    return NO;
}

static void cleaner_custom_targets_store(NSArray<CYCleanerCustomTarget *> *targets)
{
    NSMutableArray *plain = [NSMutableArray array];
    for (CYCleanerCustomTarget *t in targets)
        [plain addObject:@{ @"bundle": t.bundleID, @"path": t.relativePath, @"file": @(t.isFile), @"app": t.appName ?: t.bundleID }];
    [NSUserDefaults.standardUserDefaults setObject:plain forKey:kCleanerCustomTargetsKey];
}

BOOL cleaner_custom_target_add(NSString *bundleID, NSString *appName, NSString *relative, BOOL isFile, NSString **error)
{
    if (!bundleID.length || !cleaner_custom_target_valid_relative(relative)) {
        if (error) *error = @"Only folders and files inside an app's Library, Documents or tmp can be added, "
                            @"not those folders themselves and not the app's settings.";
        return NO;
    }
    if (cleaner_custom_target_contains(bundleID, relative)) return YES;
    NSMutableArray *targets = [cleaner_custom_targets() mutableCopy];
    CYCleanerCustomTarget *t = [CYCleanerCustomTarget new];
    t.bundleID = bundleID;
    t.relativePath = relative;
    t.isFile = isFile;
    t.appName = appName.length ? appName : bundleID;
    [targets addObject:t];
    cleaner_custom_targets_store(targets);
    return YES;
}

void cleaner_custom_target_remove(NSString *bundleID, NSString *relative)
{
    NSMutableArray *targets = [NSMutableArray array];
    for (CYCleanerCustomTarget *t in cleaner_custom_targets())
        if (!([t.bundleID isEqualToString:bundleID] && [t.relativePath isEqualToString:relative])) [targets addObject:t];
    cleaner_custom_targets_store(targets);
}
