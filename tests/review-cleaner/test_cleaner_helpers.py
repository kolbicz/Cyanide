#!/usr/bin/env python3
"""Compile actual cleaner helpers with Foundation; never touch real app data.

Only the allowed app-data prefix is redirected to a temporary fake filesystem.
Requires macOS + Xcode command line tools. All fixtures belong to this test.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Cyanide/CleanerViewController.m"
FB_SOURCE = ROOT / "Cyanide/FBAppContainers.m"

PREAMBLE = r'''
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <errno.h>
#import <unistd.h>
#import <fcntl.h>
#import <dirent.h>
#import <string.h>
#import <time.h>
NSString *fb_canonical_path(NSString *path) {
    NSString *p = path.stringByStandardizingPath;
    if ([p isEqualToString:@"/var"] || [p hasPrefix:@"/var/"])
        p = [@"/private" stringByAppendingString:p];
    return p;
}
'''
FIXTURES = r'''
static void check(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static void mkdirp(NSString *path) {
    check([NSFileManager.defaultManager createDirectoryAtPath:path
        withIntermediateDirectories:YES attributes:nil error:nil], "create fixture");
}
static void put(NSString *path, NSUInteger bytes) {
    mkdirp(path.stringByDeletingLastPathComponent);
    check([[NSMutableData dataWithLength:bytes] writeToFile:path atomically:NO], "write fixture");
}
static NSString *app(void) {
    NSString *path = [kCleanerAppDataPrefix stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    mkdirp(path);
    return path;
}
static BOOL exists(NSString *path) { return [NSFileManager.defaultManager fileExistsAtPath:path]; }
static unsigned long long scan_path(NSString *path, BOOL *complete) {
    CYCleanerTraversal walk = cleaner_traversal(kCleanerMaxScanSeconds, NULL);
    return cleaner_tree_bytes_walk(path, complete, &walk);
}
'''
SCENARIOS = r'''
// Custom targets (#18): which paths may be added at all.
check(cleaner_custom_target_valid_relative(@"Library/Application Support/Instagram/VideoUpload"), "custom: app folder allowed");
check(cleaner_custom_target_valid_relative(@"Documents/drafts.db"), "custom: Documents file allowed");
check(!cleaner_custom_target_valid_relative(@"Library"), "custom: Library itself refused");
check(!cleaner_custom_target_valid_relative(@"Documents"), "custom: Documents itself refused");
check(!cleaner_custom_target_valid_relative(@"Library/Preferences"), "custom: Preferences refused");
check(!cleaner_custom_target_valid_relative(@"Library/Preferences/x.plist"), "custom: settings files refused");
check(!cleaner_custom_target_valid_relative(@"Library/../tmp/x"), "custom: dot-dot refused");
check(!cleaner_custom_target_valid_relative(@"/Library/Caches"), "custom: absolute refused");
check(!cleaner_custom_target_valid_relative(@"SystemData/x"), "custom: other top folders refused");
{
    NSString *c = app();
    put([c stringByAppendingPathComponent:@"Library/Application Support/IG/VideoUpload/a.mp4"], 1000);
    put([c stringByAppendingPathComponent:@"Library/Application Support/IG/VideoUpload/sub/b.mp4"], 500);
    put([c stringByAppendingPathComponent:@"Library/Application Support/IG/keep.db"], 10);
    put([c stringByAppendingPathComponent:@"Documents/drafts.db"], 77);
    int cfd = cleaner_open_container(c);
    struct stat cst; check(cfd >= 0 && fstat(cfd, &cst) == 0, "custom: open container");
    BOOL complete = NO;
    CYCleanerTraversal w = cleaner_traversal(kCleanerMaxScanSeconds, NULL);
    check(cleaner_custom_bytes_at(cfd, @"Library/Application Support/IG/VideoUpload", NO, cst.st_dev, &complete, &w) == 1500 && complete,
          "custom: folder measured");
    w = cleaner_traversal(kCleanerMaxScanSeconds, NULL);
    check(cleaner_custom_bytes_at(cfd, @"Documents/drafts.db", YES, cst.st_dev, &complete, &w) == 77 && complete, "custom: file measured");
    NSUInteger removed = 0, failed = 0;
    w = cleaner_traversal(kCleanerMaxCleanSeconds, NULL);
    cleaner_custom_clean_at(cfd, @"Library/Application Support/IG/VideoUpload", NO, cst.st_dev, &removed, &failed, &w);
    check(failed == 0 && exists([c stringByAppendingPathComponent:@"Library/Application Support/IG/VideoUpload"]) &&
          !exists([c stringByAppendingPathComponent:@"Library/Application Support/IG/VideoUpload/a.mp4"]) &&
          !exists([c stringByAppendingPathComponent:@"Library/Application Support/IG/VideoUpload/sub"]) &&
          exists([c stringByAppendingPathComponent:@"Library/Application Support/IG/keep.db"]), "custom: folder emptied, siblings kept");
    w = cleaner_traversal(kCleanerMaxCleanSeconds, NULL);
    check(cleaner_custom_clean_at(cfd, @"Documents/drafts.db", YES, cst.st_dev, &removed, &failed, &w) == 77 &&
          !exists([c stringByAppendingPathComponent:@"Documents/drafts.db"]), "custom: file deleted");
    // A link anywhere on the way is refused, for folders and files.
    put([c stringByAppendingPathComponent:@"Documents/real/secret.txt"], 5);
    check(symlink("real", [c stringByAppendingPathComponent:@"Documents/alias"].fileSystemRepresentation) == 0, "custom: alias link");
    failed = 0;
    w = cleaner_traversal(kCleanerMaxCleanSeconds, NULL);
    cleaner_custom_clean_at(cfd, @"Documents/alias", NO, cst.st_dev, &removed, &failed, &w);
    w = cleaner_traversal(kCleanerMaxCleanSeconds, NULL);
    cleaner_custom_clean_at(cfd, @"Documents/alias/secret.txt", YES, cst.st_dev, &removed, &failed, &w);
    check(failed == 2 && exists([c stringByAppendingPathComponent:@"Documents/real/secret.txt"]), "custom: links refused");
    w = cleaner_traversal(kCleanerMaxCleanSeconds, NULL);
    check(cleaner_custom_clean_at(cfd, @"Library/Preferences", NO, cst.st_dev, &removed, &failed, &w) == 0, "custom: invalid path refused at clean");
    close(cfd);
}
// An intermediate Library symlink must be refused by scan AND clear.
NSString *a = app();
NSString *document = [a stringByAppendingPathComponent:@"Documents/Caches/valuable.txt"];
put(document, 4096);
check(symlink("Documents", [a stringByAppendingPathComponent:@"Library"].fileSystemRepresentation) == 0, "library link");
NSString *cache = [a stringByAppendingPathComponent:@"Library/Caches"];
BOOL complete = YES;
NSUInteger removed = 0, failed = 0;
check(scan_path(cache, &complete) == 0 && !complete, "ancestor scan refused");
check(cleaner_clear_directory(cache, &removed, &failed, NULL) == 0 && failed > 0, "ancestor clear refused");
check(exists(document), "document survives Library symlink");

// An otherwise valid UUID container may itself be a symlink.
NSString *outside = [kCleanerAppDataPrefix.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"outside"];
put([outside stringByAppendingPathComponent:@"tmp/keep.txt"], 512);
NSString *linkedContainer = [kCleanerAppDataPrefix stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
check(symlink(outside.fileSystemRepresentation, linkedContainer.fileSystemRepresentation) == 0, "container link");
check(cleaner_clear_directory([linkedContainer stringByAppendingPathComponent:@"tmp"], &removed, &failed, NULL) == 0 && failed > 0, "container link refused");
check(exists([outside stringByAppendingPathComponent:@"tmp/keep.txt"]), "external target survives");

// Even within a valid container, arbitrary nested tmp/Caches roots are forbidden.
NSString *nested = [a stringByAppendingPathComponent:@"Documents/tmp"];
put([nested stringByAppendingPathComponent:@"keep.txt"], 256);
check(!cleaner_is_disposable_root(nested), "nested root guard");
cleaner_clear_directory(nested, &removed, &failed, NULL);
check(exists([nested stringByAppendingPathComponent:@"keep.txt"]), "nested document survives");

// A link INSIDE the disposable root is unlinked; its target is never followed.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
mkdirp(cache); document = [a stringByAppendingPathComponent:@"Documents/keep.txt"]; put(document, 128);
NSString *link = [cache stringByAppendingPathComponent:@"link"];
check(symlink(document.fileSystemRepresentation, link.fileSystemRepresentation) == 0, "child link");
cleaner_clear_directory(cache, &removed, &failed, NULL);
struct stat st;
check(lstat(link.fileSystemRepresentation, &st) != 0 && exists(document), "child link removed without target deletion");
check(exists(cache), "cache root preserved");

// Normal nested files remain cleanable using the descriptor walk.
put([cache stringByAppendingPathComponent:@"nested/file.bin"], 1024);
check(scan_path(cache, &complete) == 1024 && complete, "normal scan");
removed = failed = 0;
check(cleaner_clear_directory(cache, &removed, &failed, NULL) == 1024 && removed == 1 && failed == 0, "normal clear");
check(exists(cache) && !exists([cache stringByAppendingPathComponent:@"nested"]), "only root contents removed");

// tmp must not erase results from an earlier cache operation.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
NSString *tmp = [a stringByAppendingPathComponent:@"tmp"]; mkdirp(tmp);
put([cache stringByAppendingPathComponent:@"cache.bin"], 2048);
removed = failed = 0;
unsigned long long bytes = cleaner_clear_directory(cache, &removed, &failed, NULL);
bytes += cleaner_clear_directory(tmp, &removed, &failed, NULL);
check(bytes == 2048 && removed == 1 && failed == 0, "cache-only counters survive empty tmp");

// Errors from either root must likewise survive the next call.
check([NSFileManager.defaultManager removeItemAtPath:cache error:nil], "remove empty cache fixture");
check(symlink("../tmp", cache.fileSystemRepresentation) == 0, "rejected cache root fixture");
removed = failed = 0;
cleaner_clear_directory(cache, &removed, &failed, NULL);
NSUInteger cacheFailures = failed;
cleaner_clear_directory(tmp, &removed, &failed, NULL);
check(cacheFailures > 0 && failed == cacheFailures, "cache error survives empty tmp");

// One failed child must not discard bytes already deleted from its parent.
if (geteuid() != 0) {
    a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
    NSString *blocked = [cache stringByAppendingPathComponent:@"sub/blocked"];
    NSString *deletable = [cache stringByAppendingPathComponent:@"sub/delete.bin"];
    mkdirp(blocked); put(deletable, 1024);
    check(chmod(blocked.fileSystemRepresentation, 0000) == 0, "make blocked fixture");
    removed = failed = 0;
    bytes = cleaner_clear_directory(cache, &removed, &failed, NULL);
    // Restore permissions BEFORE asserting so temporary-directory cleanup is safe.
    chmod(blocked.fileSystemRepresentation, 0700);
    check(bytes == 1024 && removed == 1 && failed > 0 && !exists(deletable), "partial child bytes preserved");
}

// A removed cache link is logical data removed, not guaranteed storage freed.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"]; mkdirp(cache);
document = [a stringByAppendingPathComponent:@"Documents/original.bin"]; put(document, 8192);
check(linkat(AT_FDCWD, document.fileSystemRepresentation, AT_FDCWD,
    [cache stringByAppendingPathComponent:@"alias.bin"].fileSystemRepresentation, 0) == 0, "hard-link fixture");
struct stat before, after;
check(lstat(document.fileSystemRepresentation, &before) == 0, "stat original");
removed = failed = 0;
bytes = cleaner_clear_directory(cache, &removed, &failed, NULL);
check(lstat(document.fileSystemRepresentation, &after) == 0, "original survives cache unlink");
check(bytes == 8192 && before.st_blocks == after.st_blocks && after.st_nlink == 1, "logical bytes differ from recovered space");

// Empty directories count toward the entry cap, not just regular files.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
mkdirp([cache stringByAppendingPathComponent:@"one"]);
mkdirp([cache stringByAppendingPathComponent:@"two"]);
CYCleanerTraversal walk = cleaner_traversal(10, NULL);
walk.entries = kCleanerMaxScanEntries - 1;
int scanFD = cleaner_open_root(cache); struct stat rootStat;
check(scanFD >= 0 && fstat(scanFD, &rootStat) == 0, "open bounded scan");
complete = YES;
cleaner_scan_directory_fd(scanFD, rootStat.st_dev, 0, &walk, &complete);
check(walk.stopped && !complete && walk.entries == kCleanerMaxScanEntries, "directory-only scan cap");
walk = cleaner_traversal(10, NULL); walk.entries = kCleanerMaxScanEntries - 1;
cleaner_clear_directory(cache, &removed, &failed, &walk);
check(walk.stopped && (exists([cache stringByAppendingPathComponent:@"one"]) ||
    exists([cache stringByAppendingPathComponent:@"two"])), "directory-only removal cap");

// An over-deep subtree is skipped, not allowed to stop the whole pass.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
NSString *deep = cache;
for (NSUInteger i = 0; i < kCleanerMaxTraversalDepth + 2; i++) deep = [deep stringByAppendingPathComponent:@"d"];
NSString *deepFile = [deep stringByAppendingPathComponent:@"keep.bin"]; put(deepFile, 32);
put([cache stringByAppendingPathComponent:@"sibling.bin"], 16);
complete = YES; scan_path(cache, &complete);
check(!complete, "depth-limited scan");
walk = cleaner_traversal(10, NULL); removed = failed = 0;
cleaner_clear_directory(cache, &removed, &failed, &walk);
check(!walk.stopped && exists(deepFile), "depth-limited removal leaves deep subtree");
check(!exists([cache stringByAppendingPathComponent:@"sibling.bin"]), "depth-limited removal continues with siblings");
check(failed > 0, "depth-limited removal reports the skipped subtree");

// Expiration/cancellation gates both deletes and post-clean scans.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
NSString *cancelFile = [cache stringByAppendingPathComponent:@"keep.bin"]; put(cancelFile, 64);
int cancelled = 1;
walk = cleaner_traversal(10, &cancelled); removed = failed = 0;
cleaner_clear_directory(cache, &removed, &failed, &walk);
check(walk.stopped && removed == 0 && exists(cancelFile), "cancelled clean leaves data intact");
complete = YES;
cleaner_tree_bytes_cancellable(cache, NULL, &complete, &cancelled);
check(!complete && exists(cancelFile), "cancelled rescan is incomplete");
walk = cleaner_traversal(10, NULL); walk.deadline = 0;
cleaner_clear_directory(cache, &removed, &failed, &walk);
check(walk.stopped && exists(cancelFile), "expired deadline leaves data intact");

// A current Info.plist must match the container identifier and provide an
// executable before the active-app decision can proceed.
NSString *currentExecutable = nil;
check(fb_current_bundle_metadata_matches(@"com.example.app",
    @{ @"CFBundleIdentifier": @"com.example.app", @"CFBundleExecutable": @"NewExec" },
    &currentExecutable) && [currentExecutable isEqualToString:@"NewExec"], "current metadata accepted");
check(!fb_current_bundle_metadata_matches(@"com.example.app",
    @{ @"CFBundleIdentifier": @"com.other.app", @"CFBundleExecutable": @"NewExec" },
    &currentExecutable), "mismatched bundle rejected");
check(!fb_current_bundle_metadata_matches(@"com.example.app",
    @{ @"CFBundleIdentifier": @"com.example.app" }, &currentExecutable), "missing executable rejected");

// Pin the scanned container descriptor: replacing its pathname must not make
// the cleaner operate on the replacement directory.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
put([cache stringByAppendingPathComponent:@"original.bin"], 32);
int trustedFD = cleaner_open_container(a); struct stat pinned = {0};
check(trustedFD >= 0 && fstat(trustedFD, &pinned) == 0, "pin container identity");
NSString *originalPath = [a.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"original-container"];
check(rename(a.fileSystemRepresentation, originalPath.fileSystemRepresentation) == 0, "replace container path");
mkdirp(cache); put([cache stringByAppendingPathComponent:@"replacement.bin"], 64);
int replacementFD = cleaner_open_container(a); struct stat replacement = {0};
check(replacementFD >= 0 && fstat(replacementFD, &replacement) == 0, "open replacement identity");
check(!cleaner_container_identity_matches(&replacement, pinned.st_dev, pinned.st_ino),
    "replacement identity rejected");
close(replacementFD);
removed = failed = 0;
CYCleanerTraversal pinnedWalk = cleaner_traversal(10, NULL);
check(cleaner_clear_directory_at(trustedFD, @"Library/Caches", pinned.st_dev, &removed, &failed, &pinnedWalk) == 32 &&
      removed == 1 && failed == 0, "descriptor cleans original container");
close(trustedFD);
check(exists([cache stringByAppendingPathComponent:@"replacement.bin"]), "replacement survives");
check(!exists([originalPath stringByAppendingPathComponent:@"Library/Caches/original.bin"]),
    "original contents were cleaned through the pin");

// Root-level device admission is an explicit trusted-baseline comparison;
// nested traversal keeps the same check for every child.
check(cleaner_device_matches((dev_t)7, (dev_t)7), "trusted device accepted");
check(!cleaner_device_matches((dev_t)7, (dev_t)8), "replacement device rejected");

check(cleaner_process_is_active(@"ExampleApp", [NSSet setWithObject:@"ExampleApp"]), "current executable active");
check(!cleaner_process_is_active(@"", [NSSet setWithObject:@"ExampleApp"]), "missing executable fails closed");

check(cleaner_process_is_active(@"Foo", [NSSet setWithObject:@"Foo"]), "exact process name");
check(!cleaner_process_is_active(@"FooBar", [NSSet setWithObject:@"Foo"]), "short prefix is not truncation");
NSString *prefix31 = [@"x" stringByPaddingToLength:31 withString:@"x" startingAtIndex:0];
check(cleaner_process_is_active([prefix31 stringByAppendingString:@"Tail"], [NSSet setWithObject:prefix31]), "31-byte ASCII truncation");
NSString *unicode31 = [[@"é" stringByPaddingToLength:15 withString:@"é" startingAtIndex:0] stringByAppendingString:@"A"];
check(cleaner_process_is_active([unicode31 stringByAppendingString:@"Tail"], [NSSet setWithObject:unicode31]), "31-byte Unicode truncation");
NSString *characters31 = [@"é" stringByPaddingToLength:31 withString:@"é" startingAtIndex:0];
check(!cleaner_process_is_active([characters31 stringByAppendingString:@"Tail"], [NSSet setWithObject:characters31]), "31 characters is not 31 bytes");
'''

class CleanerHelperTests(unittest.TestCase):
    def test_storage_labels(self):
        source = SOURCE.read_text()
        self.assertIn('@"Reclaimable"', source)
        self.assertIn("Logical file sizes, not guaranteed recovered storage.", source)
        self.assertNotIn('@"Freed %@', source)

    def test_background_expiration_contract(self):
        source = SOURCE.read_text()
        body = source[source.index("- (void)performClean"):source.index("#pragma mark Table")]
        expiration = body[body.index("expirationHandler:^{"):body.index("if (bgTask == UIBackgroundTaskInvalid)")]
        self.assertIn("__atomic_store_n(&cancelled, 1", expiration)
        self.assertIn("endBackgroundTask:bgTask", expiration)
        self.assertNotIn("expirationHandler:^{}", body)
        self.assertIn("results are partial", body)
        self.assertIn("cleaner_tree_bytes_at", body)

    def test_fresh_process_check_contract(self):
        source = SOURCE.read_text()
        body = source[source.index("- (void)performClean"):source.index("#pragma mark Table")]
        roots = body[body.index("for (NSString *relativeRoot"):body.index("freed += appFreed")]
        self.assertIn("fb_current_container_for_path", body)
        self.assertIn("cleaner_container_identity_matches", body)
        self.assertIn("settings_active_process_names()", body)
        self.assertLess(body.index("settings_active_process_names()"), body.index("cleaner_clear_directory_at"))
        self.assertNotIn("cleaner_should_skip_now", body)
        self.assertIn("processUnavailable = YES", body)
        self.assertIn("Detection is best-effort", source)

    def test_cache_generation_contract(self):
        source = FB_SOURCE.read_text()
        self.assertIn("static NSUInteger g_cacheGeneration", source)
        self.assertIn("generation != g_cacheGeneration", source)
        self.assertIn("g_cacheGeneration++", source)
        self.assertNotIn("fb_data_container_for_id_locked", source)

    def test_native_helpers(self):
        source = SOURCE.read_text()
        with tempfile.TemporaryDirectory(prefix="cyanide-cleaner-test-") as temporary:
            base = Path(temporary).resolve()
            prefix = str(base / "Containers/Data/Application") + "/"
            constants = source[source.index("static NSString * const kCleanerAppDataPrefix"):source.index("static void cleaner_suppress_popup_bar")]
            constants = constants.replace("/private/var/mobile/Containers/Data/Application/", prefix)
            helpers = source[source.index("static BOOL cleaner_path_is_app_data"):source.index("@interface CYCleanerItem")]
            fb_source = FB_SOURCE.read_text()
            metadata = fb_source[fb_source.index("static BOOL fb_current_bundle_metadata_matches"):
                                 fb_source.index("static NSString *fb_app_in_container")]
            custom = (ROOT / "Cyanide/CleanerCustomTargets.m").read_text().replace('#import "CleanerCustomTargets.h"', '')
            custom_header = (ROOT / "Cyanide/CleanerCustomTargets.h").read_text()
            code = PREAMBLE + custom_header + custom + constants + helpers + metadata + FIXTURES
            code += 'int main(void) { @autoreleasepool { mkdirp(kCleanerAppDataPrefix);\n' + SCENARIOS
            code += '\nputs("cleaner helper regressions: PASS"); } return 0; }\n'
            harness = base / "harness.m"
            harness.write_text(code)
            executable = base / "harness"
            subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation", str(harness), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

if __name__ == "__main__":
    unittest.main()
