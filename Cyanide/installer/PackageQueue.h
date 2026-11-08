//
//  PackageQueue.h
//  Cyanide
//
//  Sileo-style install/uninstall queue. User taps Install/Uninstall in a
//  package detail page; nothing applies until commit() is called from the
//  Queue review screen.
//

#import <Foundation/Foundation.h>
#import "Package.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const PackageQueueDidChangeNotification;
// Posted after a package was added to the queue: the Installer may apply it
// right away instead (see -rightAwayKeys).
extern NSString * const PackageQueueDidEnqueueNotification;

// Intent stored per package once enqueued.
typedef NS_ENUM(NSInteger, PackageQueueIntent) {
    PackageQueueIntentNone = 0,
    PackageQueueIntentInstall,
    PackageQueueIntentUninstall,
};

@interface PackageQueue : NSObject

+ (instancetype)sharedQueue;

@property (nonatomic, readonly) NSArray<Package *> *queuedInstalls;
@property (nonatomic, readonly) NSArray<Package *> *queuedUninstalls;
@property (nonatomic, readonly) NSInteger pendingCount;

- (PackageQueueIntent)intentForPackage:(Package *)package;
- (BOOL)canQueueIntent:(PackageQueueIntent)intent
            forPackage:(Package *)package
                reason:(NSString * _Nullable * _Nullable)reason;

// Sileo-style "tap toggles queue":
//   not installed + not queued  → queue install
//   not installed + queued      → cancel queue
//   installed     + not queued  → queue uninstall
//   installed     + queued      → cancel queue
- (void)toggleForPackage:(Package *)package;

- (void)queueIntent:(PackageQueueIntent)intent forPackage:(Package *)package;
- (void)removePackage:(Package *)package;
- (void)clear;

// YES from -commit until the run it hands off to finishes (bounded by a
// 10-minute handoff timeout in case that run never reports completion).
@property (nonatomic, readonly) BOOL isCommitting;

// Writes the persisted state for every queued package, then triggers
// settings_run_actions() once. Clears the queue afterwards. Returns NO
// (and does nothing) when a commit is already running.
- (BOOL)commit;

// Same as -commit, but the run it starts applies only the committed
// packages, not every enabled tweak that isn't marked applied yet.
- (BOOL)commitOnlyQueuedPackages;

// Enabling keys of the queued packages when every one of them is a plain
// toggle tweak (what "Apply Installer changes right away" handles); nil
// otherwise or when nothing is queued.
- (nullable NSSet<NSString *> *)rightAwayKeys;

@end

NS_ASSUME_NONNULL_END
