//
//  PackageQueue.m
//  Cyanide
//

#import "PackageQueue.h"
#import "PackageCatalog.h"
#import "../SettingsViewController.h"
#import "../LogTextView.h"
#import "../tweaks/QuickLoader.h"
#import "../tweaks/RepoTweaks.h"

NSString * const PackageQueueDidChangeNotification = @"PackageQueueDidChangeNotification";
NSString * const PackageQueueDidEnqueueNotification = @"PackageQueueDidEnqueueNotification";

@interface PackageQueue ()
@property (nonatomic, strong) NSMutableArray<Package *> *installs;
@property (nonatomic, strong) NSMutableArray<Package *> *uninstalls;
// YES from commit until its own apply work and (when it starts one) the
// resulting run are done. A second commit meanwhile is refused.
@property (nonatomic, assign) BOOL isCommitting;
// A commit that handed off to settings_run_pending_actions keeps isCommitting
// YES until that run posts its completion (or the handoff timeout expires), so
// isCommitting really means "until its run finishes".
@property (nonatomic, assign) BOOL awaitingRunCompletion;
// Set by -commitOnlyQueuedPackages for the run it hands off to.
@property (nonatomic, copy, nullable) NSSet<NSString *> *runOnlyKeys;
@end

static BOOL PackageIsThemer(Package *package)
{
    return [package.identifier isEqualToString:@"com.darksword.themer"];
}

static BOOL PackageIsSnowBoardLite(Package *package)
{
    return [package.identifier isEqualToString:@"com.darksword.snowboardlite"];
}

static NSString *PackageMissingThemeReason(Package *package)
{
    if (PackageIsThemer(package) && !settings_themer_has_selected_theme()) {
        return @"Icon Theme Engine needs a selected theme before it can be activated. Open its settings and choose a theme first.";
    }
    if (PackageIsSnowBoardLite(package) && !settings_snowboardlite_has_selected_theme()) {
        return @"SnowBoard Lite needs a selected theme before it can be activated. Open SnowBoard Lite settings and choose iOS 6 Theme or import a SnowBoard/IconBundles theme first.";
    }
    return nil;
}

static BOOL PackageCanQueueInstall(Package *package)
{
    if (package.kind == PackageInstallKindDirectTool) return NO;
    if (package.installDisabledReason.length > 0) return NO;
    return PackageMissingThemeReason(package).length == 0;
}

static BOOL PackageEnabledKeyIsRepoDriven(NSString *enabledKey)
{
    if (enabledKey.length == 0) return NO;
    if ([enabledKey isEqualToString:kSettingsQuickLoaderEnabled]) {
        return quickloader_is_driven_by_repo_tweak();
    }

    NSString *repoTweakID = nil;
    if ([enabledKey isEqualToString:kSettingsSBCEnabled]) {
        repoTweakID = @"lightsaber.sbcustomizer";
    } else if ([enabledKey isEqualToString:kSettingsStatBarEnabled]) {
        repoTweakID = @"lightsaber.statbar";
    } else if ([enabledKey isEqualToString:kSettingsPowercuffEnabled]) {
        repoTweakID = @"lightsaber.powercuff";
    }
    if (repoTweakID.length == 0) return NO;

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    id rawURLs = [d objectForKey:@"RepoTweaksURLs"];
    if (![rawURLs isKindOfClass:NSArray.class]) return NO;
    for (id value in (NSArray *)rawURLs) {
        if (![value isKindOfClass:NSString.class]) continue;
        // Present at all = installed (an installed tweak may have an empty version).
        if ([d objectForKey:repotweaks_installed_version_key((NSString *)value, repoTweakID)] != nil) {
            return YES;
        }
    }
    return NO;
}

static BOOL PackageShouldAutoQueueForApply(Package *package)
{
    // Repo tweak updates are intentionally user-driven: refresh should only
    // show update badges. The user must tap Update/Install before anything
    // enters the pending queue.
    if (package.kind == PackageInstallKindRepoTweak) return NO;
    if (package.kind == PackageInstallKindToggle &&
        PackageEnabledKeyIsRepoDriven(package.enabledKey)) {
        return NO;
    }
    return package.isQueuedForApply;
}

@implementation PackageQueue

+ (instancetype)sharedQueue
{
    static PackageQueue *q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = [[PackageQueue alloc] init]; });
    return q;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _installs   = [NSMutableArray array];
        _uninstalls = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(actionsDidComplete:)
                                                     name:kSettingsActionsDidCompleteNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// The run handed off by -commit finished (or a refusal/auto-retry chain did).
// Only then may another commit start.
- (void)actionsDidComplete:(NSNotification *)note
{
    (void)note;
    if (!self.awaitingRunCompletion) return;
    // A completion from an unrelated action while our run is still applying
    // must not unlock the queue. The run's own completion is posted after it
    // releases the actions lock, so it sees no run in flight.
    if (settings_run_in_flight()) return;
    self.awaitingRunCompletion = NO;
    self.isCommitting = NO;
    printf("[INSTALLER] commit-run handoff complete; queue unlocked\n");
}

- (NSArray<Package *> *)queuedInstalls
{
    NSMutableArray<Package *> *out = [self.installs mutableCopy];
    if ([self hasExplicitHideHomeBarQueued]) {
        NSMutableArray<Package *> *onlyHomeBar = [NSMutableArray array];
        for (Package *p in out) {
            if (p.kind == PackageInstallKindHideHomeBar) [onlyHomeBar addObject:p];
        }
        return onlyHomeBar;
    }

    for (Package *p in [PackageCatalog allPackages]) {
        if (p.isInstallDisabled) continue;
        if (!PackageCanQueueInstall(p)) continue;
        if (!PackageShouldAutoQueueForApply(p)) continue;
        if ([self packageInArray:out matching:p]) continue;
        if ([self packageInArray:self.uninstalls matching:p]) continue;
        [out addObject:p];
    }

    BOOL hasRepoTweakUsingQL = NO;
    for (Package *p in out) {
        if (p.kind == PackageInstallKindRepoTweak && p.repoTweakUsesQuickLoader) {
            hasRepoTweakUsingQL = YES;
            break;
        }
    }
    if (hasRepoTweakUsingQL) {
        NSMutableArray<Package *> *filtered = [NSMutableArray arrayWithCapacity:out.count];
        for (Package *p in out) {
            if ([p.enabledKey isEqualToString:kSettingsQuickLoaderEnabled]) continue;
            [filtered addObject:p];
        }
        return filtered;
    }
    return out;
}

- (NSArray<Package *> *)queuedUninstalls
{
    if (![self hasExplicitHideHomeBarQueued]) return [self.uninstalls copy];

    NSMutableArray<Package *> *onlyHomeBar = [NSMutableArray array];
    for (Package *p in self.uninstalls) {
        if (p.kind == PackageInstallKindHideHomeBar) [onlyHomeBar addObject:p];
    }
    return onlyHomeBar;
}
- (NSInteger)pendingCount                { return (NSInteger)(self.queuedInstalls.count + self.queuedUninstalls.count); }

- (PackageQueueIntent)intentForPackage:(Package *)package
{
    if (package.kind == PackageInstallKindDirectTool) return PackageQueueIntentNone;
    BOOL hideHomeBarQueued = [self hasExplicitHideHomeBarQueued];
    BOOL isHideHomeBar = package.kind == PackageInstallKindHideHomeBar;
    if (hideHomeBarQueued && !isHideHomeBar) return PackageQueueIntentNone;
    if (!package.isInstalled && !PackageCanQueueInstall(package)) return PackageQueueIntentNone;
    if ([self packageInArray:self.installs matching:package])   return PackageQueueIntentInstall;
    if ([self packageInArray:self.uninstalls matching:package]) return PackageQueueIntentUninstall;
    if (package.isInstallDisabled) return PackageQueueIntentNone;
    if (PackageShouldAutoQueueForApply(package)) return PackageQueueIntentInstall;
    return PackageQueueIntentNone;
}

- (Package *)packageInArray:(NSArray<Package *> *)array matching:(Package *)package
{
    for (Package *p in array) {
        if ([p.identifier isEqualToString:package.identifier]) return p;
    }
    return nil;
}

- (BOOL)hasExplicitHideHomeBarQueued
{
    for (Package *p in self.installs) {
        if (p.kind == PackageInstallKindHideHomeBar) return YES;
    }
    for (Package *p in self.uninstalls) {
        if (p.kind == PackageInstallKindHideHomeBar) return YES;
    }
    return NO;
}

- (NSInteger)pendingCountExcludingPackage:(Package *)package
{
    NSInteger count = 0;
    for (Package *p in self.queuedInstalls) {
        if (package && [p.identifier isEqualToString:package.identifier]) continue;
        count++;
    }
    for (Package *p in self.queuedUninstalls) {
        if (package && [p.identifier isEqualToString:package.identifier]) continue;
        count++;
    }
    return count;
}

- (BOOL)hasQueuedHideHomeBarIntentExcludingPackage:(Package *)package
{
    for (Package *p in self.installs) {
        if (package && [p.identifier isEqualToString:package.identifier]) continue;
        if (p.kind == PackageInstallKindHideHomeBar) return YES;
    }
    for (Package *p in self.uninstalls) {
        if (package && [p.identifier isEqualToString:package.identifier]) continue;
        if (p.kind == PackageInstallKindHideHomeBar) return YES;
    }
    return NO;
}

- (BOOL)hasQueuedRepoTweakInstallExcludingPackage:(Package *)package
{
    for (Package *p in self.queuedInstalls) {
        if (package && [p.identifier isEqualToString:package.identifier]) continue;
        if (p.kind == PackageInstallKindRepoTweak && p.repoTweakUsesQuickLoader) return YES;
    }
    return NO;
}

- (BOOL)canQueueIntent:(PackageQueueIntent)intent
            forPackage:(Package *)package
                reason:(NSString * _Nullable * _Nullable)reason
{
    if (reason) *reason = nil;
    if (!package) return NO;
    if (intent == PackageQueueIntentNone) return YES;

    if (intent == PackageQueueIntentInstall) {
        // Compatibility/availability gates only block new installs or updates.
        // If the user already has a now-unsupported repo tweak installed,
        // keep PackageQueueIntentUninstall available so they can remove it.
        if (package.isInstallDisabled) {
            if (reason) {
                *reason = package.installDisabledReason.length
                    ? package.installDisabledReason
                    : @"This package is not available on this iOS version.";
            }
            return NO;
        }
        NSString *themeReason = PackageMissingThemeReason(package);
        if (themeReason.length > 0) {
            if (reason) *reason = themeReason;
            return NO;
        }
    }

    BOOL isHideHomeBar = package.kind == PackageInstallKindHideHomeBar;
    if (isHideHomeBar && [self pendingCountExcludingPackage:package] > 0) {
        if (reason) {
            *reason = @"Hide Home Bar changes the system home-indicator asset and needs a respring right after. Clear the current queue, run Hide Home Bar by itself, respring, then queue your other tweaks.";
        }
        return NO;
    }

    if (!isHideHomeBar && [self hasQueuedHideHomeBarIntentExcludingPackage:package]) {
        if (reason) {
            *reason = @"Hide Home Bar is already waiting in the queue and must run by itself. Apply or remove Hide Home Bar first, then queue other tweaks after the respring.";
        }
        return NO;
    }

    if (intent == PackageQueueIntentInstall &&
        package.kind == PackageInstallKindRepoTweak &&
        package.repoTweakUsesQuickLoader &&
        [self hasQueuedRepoTweakInstallExcludingPackage:package]) {
        if (reason) {
            *reason = @"QuickLoader installs one repo tweak at a time. Apply or remove the currently queued repo tweak first.";
        }
        return NO;
    }

    return YES;
}

- (void)toggleForPackage:(Package *)package
{
    PackageQueueIntent current = [self intentForPackage:package];
    if (current != PackageQueueIntentNone) {
        [self removePackage:package];
        return;
    }
    if (package.isInstallDisabled && !package.isInstalled) return;
    if (!package.isInstalled && !PackageCanQueueInstall(package)) return;
    PackageQueueIntent nextIntent = package.isInstalled ? PackageQueueIntentUninstall : PackageQueueIntentInstall;
    if (![self canQueueIntent:nextIntent forPackage:package reason:nil]) return;

    if (package.isInstalled) {
        [self.uninstalls addObject:package];
    } else {
        [self.installs addObject:package];
    }
    [self notifyChange];
    [self notifyEnqueue];
}

- (void)queueIntent:(PackageQueueIntent)intent forPackage:(Package *)package
{
    if (![self canQueueIntent:intent forPackage:package reason:nil]) return;
    [self removePackage:package];
    if (intent == PackageQueueIntentInstall) {
        if (!PackageCanQueueInstall(package)) return;
        [self.installs addObject:package];
    } else if (intent == PackageQueueIntentUninstall) {
        [self.uninstalls addObject:package];
    }
    [self notifyChange];
    if (intent != PackageQueueIntentNone) [self notifyEnqueue];
}

- (void)removePackage:(Package *)package
{
    BOOL hadExplicitIntent = NO;
    Package *match = [self packageInArray:self.installs matching:package];
    if (match) {
        hadExplicitIntent = YES;
        [self.installs removeObject:match];
    }
    match = [self packageInArray:self.uninstalls matching:package];
    if (match) {
        hadExplicitIntent = YES;
        [self.uninstalls removeObject:match];
    }
    if (!hadExplicitIntent && PackageShouldAutoQueueForApply(package)) {
        [package applyCommittedState:NO];
    }
    [self notifyChange];
}

- (void)clear
{
    // Always fire notifyChange — observers like QueuePopupBar drive their
    // visibility off pendingCount and need a kick to re-evaluate when the
    // queue empties (e.g. after Reset All Packages drained the isQueuedForApply
    // packages via applyCommittedState:NO before clear() got a chance to act).
    NSArray<Package *> *queuedForApply = self.queuedInstalls;
    for (Package *pkg in queuedForApply) {
        if (![self packageInArray:self.installs matching:pkg] && PackageShouldAutoQueueForApply(pkg)) {
            [pkg applyCommittedState:NO];
        }
    }
    [self.installs removeAllObjects];
    [self.uninstalls removeAllObjects];
    [self notifyChange];
}

- (nullable NSSet<NSString *> *)rightAwayKeys
{
    if (self.installs.count + self.uninstalls.count == 0) return nil;
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (NSArray<Package *> *list in @[self.installs, self.uninstalls]) {
        for (Package *pkg in list) {
            if (pkg.kind != PackageInstallKindToggle || pkg.enabledKey.length == 0) return nil;
            [keys addObject:pkg.enabledKey];
        }
    }
    return keys;
}

- (BOOL)commitOnlyQueuedPackages
{
    NSSet<NSString *> *keys = [self rightAwayKeys];
    if (!keys) return NO;
    self.runOnlyKeys = keys;
    BOOL started = [self commit];
    if (!started) self.runOnlyKeys = nil;
    return started;
}

- (BOOL)commit
{
    if (self.isCommitting || settings_run_in_flight()) {
        log_user("[INSTALLER] A queue commit or its run is already active; ignoring this one.\n");
        return NO;
    }
    self.isCommitting = YES;
    self.awaitingRunCompletion = NO;

    NSArray<Package *> *toInstall   = self.queuedInstalls;
    NSArray<Package *> *toUninstall = self.queuedUninstalls;

    // Split packages into "stateful" (toggle: just flips an NSUserDefaults
    // BOOL — fast, safe to call on main) and "heavy" (OTA / NanoRegistry /
    // repo tweaks — repo installs force-refresh scripts without URL caches —
    // run kexploit + plist write, blocking). Apply stateful inline so
    // settings_run_actions sees the right flags; dispatch heavy to a
    // background queue so the InstallProgressViewController's log can
    // actually scroll while it runs.
    NSMutableArray<Package *> *heavyInstalls   = [NSMutableArray array];
    NSMutableArray<Package *> *heavyUninstalls = [NSMutableArray array];
    BOOL needsRunActions = NO;
    __block BOOL allApplied = YES;

    for (Package *pkg in toInstall) {
        if (pkg.kind == PackageInstallKindToggle) {
            needsRunActions = YES;
            allApplied = [pkg applyCommittedState:YES] && allApplied;
        } else if (pkg.kind == PackageInstallKindRepoTweak) {
            needsRunActions = YES;
            [heavyInstalls addObject:pkg];
        } else {
            [heavyInstalls addObject:pkg];
        }
    }
    for (Package *pkg in toUninstall) {
        if (pkg.kind == PackageInstallKindToggle) {
            needsRunActions = YES;
            allApplied = [pkg applyCommittedState:NO] && allApplied;
        } else if (pkg.kind == PackageInstallKindRepoTweak) {
            needsRunActions = YES;
            [heavyUninstalls addObject:pkg];
        } else {
            [heavyUninstalls addObject:pkg];
        }
    }

    [self.installs removeAllObjects];
    [self.uninstalls removeAllObjects];
    [self notifyChange];

    BOOL hasHeavy = (heavyInstalls.count + heavyUninstalls.count) > 0;

    if (!hasHeavy) {
        [self finishCommitRunningActions:needsRunActions allApplied:allApplied];
        return YES;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (Package *pkg in heavyInstalls)   allApplied = [pkg applyCommittedState:YES] && allApplied;
        for (Package *pkg in heavyUninstalls) allApplied = [pkg applyCommittedState:NO] && allApplied;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishCommitRunningActions:needsRunActions allApplied:allApplied];
        });
    });
    return YES;
}

// Main queue. Clears isCommitting, then either hands off to the actions run
// (which posts its own completion) or posts completion directly — with
// success = NO when any package failed to apply, since the progress screen
// treats a missing success key as success.
- (void)finishCommitRunningActions:(BOOL)needsRunActions allApplied:(BOOL)allApplied
{
    if (needsRunActions) {
        if (!allApplied) {
            log_user("[INSTALLER] Some queued packages failed to apply (see above); applying the rest.\n");
            // The run's completion reports the run's own outcome; without
            // this, a package whose apply failed (e.g. a repo tweak whose
            // script download failed) would show as installed successfully
            // whenever the rest of the run succeeds.
            settings_note_run_preflight_failure(@"Some packages failed to apply — check the log above.");
        }
        // Keep the queue locked until the run we start reports completion.
        // Clearing it here let a second commit begin while this run was still
        // applying packages, and that commit's no-run completion could consume
        // this run's preflight note or finish its progress screen.
        self.awaitingRunCompletion = YES;
        self.isCommitting = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.awaitingRunCompletion) return;
            printf("[INSTALLER] commit-run handoff timed out after 10 min; unlocking the queue\n");
            log_user("[INSTALLER] The last run did not report completion; the install queue is unlocked.\n");
            strongSelf.awaitingRunCompletion = NO;
            strongSelf.isCommitting = NO;
        });
        NSSet<NSString *> *onlyKeys = self.runOnlyKeys;
        self.runOnlyKeys = nil;
        if (onlyKeys) settings_run_pending_actions_for_keys(onlyKeys);
        else settings_run_pending_actions();
        return;
    }
    self.runOnlyKeys = nil;
    self.isCommitting = NO;
    self.awaitingRunCompletion = NO;
    // A NanoRegistry/heavy package can fail its ancillary step without
    // starting a run. Consume the preflight note here so it cannot surface in
    // an unrelated later run (review R-06).
    NSString *preflight = settings_take_run_preflight_failure();
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (!allApplied) {
        info[kSettingsActionsDidCompleteSuccessKey] = @NO;
        info[kSettingsActionsDidCompleteMessageKey] =
            @"Some packages failed to apply — check the log above.";
    } else if (preflight.length > 0) {
        info[kSettingsActionsDidCompleteSuccessKey] = @YES;
        info[kSettingsActionsDidCompletePartialKey] = @YES;
        info[kSettingsActionsDidCompleteMessageKey] = preflight;
    }
    NSDictionary *userInfo = info.count ? [info copy] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:kSettingsActionsDidCompleteNotification
                          object:nil
                        userInfo:userInfo];
    });
}

// Async, so the caller (a swipe action, an alert handler) finishes first.
- (void)notifyEnqueue
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:PackageQueueDidEnqueueNotification
                                                            object:self];
    });
}

- (void)notifyChange
{
    [[NSNotificationCenter defaultCenter] postNotificationName:PackageQueueDidChangeNotification
                                                        object:self];
}

@end
