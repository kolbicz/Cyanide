//
//  SceneDelegate.m
//  Cyanide
//
//  Created by seo on 3/24/26.
//

#import "SceneDelegate.h"
#import "AppDelegate.h"            // round 31: cyanide_launch_trace
#import "SettingsViewController.h"
#import "tweaks/location_services.h"
#import "installer/InstallProgressViewController.h"
#import "UpdateChecker.h"
#import "TaskRop/Exception.h"   // round 30: excport lifecycle gate (early close)

@interface SceneDelegate ()
@property (nonatomic, assign) BOOL didSelectInitialTab;
// A shortcut URL waiting for the scene to become active: kernel access is
// gated off until then (excport gate), so actions can't run any earlier.
@property (nonatomic, strong) NSURL *pendingActionURL;
// Identifies the current shortcut run: a delayed return-to-Home from an
// earlier run must not act on a later one.
@property (nonatomic, assign) NSUInteger actionGeneration;
@property (nonatomic, assign) BOOL actionInProgress;
// Quiet shortcut progress screen. Owned by one accepted run at a time
// (quietRun); every delayed UI callback checks it. Main thread only.
@property (nonatomic, strong) UIView *quietCover;
@property (nonatomic, strong) UIImageView *quietIcon;
@property (nonatomic, strong) UILabel *quietTitle;
@property (nonatomic, strong) UILabel *quietStatus;
@property (nonatomic, strong) UIProgressView *quietProgress;
@property (nonatomic, assign) int quietTarget;                // 1 on, 0 off, -1 unknown
@property (nonatomic, assign) NSUInteger quietRun;            // UI generation
@property (nonatomic, assign) BOOL quietFinished;             // result shown; later phases ignored
@property (nonatomic, assign) uint64_t quietPhaseShownNs;     // when the current phase appeared
@property (nonatomic, strong) NSDictionary *quietPendingPhase; // newest phase waiting to be shown
@end

@implementation SceneDelegate


- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    cyanide_launch_trace("scene willConnect: entry");
    UITabBarController *tab = (UITabBarController *)self.window.rootViewController;
    if ([tab isKindOfClass:UITabBarController.class] && tab.viewControllers.count > 1) {
        // iOS 26+: collapse the floating tab bar into a pill while the user
        // scrolls down, expand it back on scroll up. Falls through silently
        // on older OSes since the selector won't be present.
        SEL minSel = NSSelectorFromString(@"setTabBarMinimizeBehavior:");
        if ([tab respondsToSelector:minSel]) {
            NSMethodSignature *sig = [tab methodSignatureForSelector:minSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = tab;
            inv.selector = minSel;
            NSInteger onScrollDown = 1; // UITabBarMinimizeBehavior.onScrollDown
            [inv setArgument:&onScrollDown atIndex:2];
            [inv invoke];
        }
    }
    // Cold launch from a shortcut URL; handled once the scene is active.
    self.pendingActionURL = connectionOptions.URLContexts.anyObject.URL;
    [self coverEarlyForURL:self.pendingActionURL];
    cyanide_launch_trace("scene willConnect: exit");
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    NSURL *url = URLContexts.anyObject.URL;
    if (!url) return;
    if (scene.activationState == UISceneActivationStateForegroundActive) {
        [self handleActionURL:url];
    } else {
        self.pendingActionURL = url;   // sceneDidBecomeActive runs it
        [self coverEarlyForURL:url];
    }
}

// Strictly parses cyanide://location-services/<toggle|on|off>
// [?keepInSwitcher=<1|0>][&log=<1|0>] (also under the com.zeroxjf.ios-cyanide1
// scheme). Anything else — another scheme, extra path parts, an unknown
// action or option, or an unclear value — is rejected, never treated as a
// toggle. Returns NO with *error set.
static BOOL scene_parse_bool(NSString *value, BOOL *out)
{
    NSString *v = value.lowercaseString ?: @"";
    if ([v isEqualToString:@"1"] || [v isEqualToString:@"true"] || [v isEqualToString:@"yes"]) { *out = YES; return YES; }
    if ([v isEqualToString:@"0"] || [v isEqualToString:@"false"] || [v isEqualToString:@"no"]) { *out = NO; return YES; }
    return NO;
}

static BOOL scene_parse_location_url(NSURL *url, int *desiredOut, BOOL *keepCardOut, BOOL *showLogOut,
                                     NSString **error)
{
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *scheme = c.scheme.lowercaseString;
    if (!c || !([scheme isEqualToString:@"cyanide"] || [scheme isEqualToString:@"com.zeroxjf.ios-cyanide1"])) {
        *error = @"Unsupported link.";
        return NO;
    }
    NSString *path = c.path ?: @"";
    if ([path hasSuffix:@"/"] && path.length > 1) path = [path substringToIndex:path.length - 1];
    NSDictionary<NSString *, NSNumber *> *actions = @{ @"/toggle": @-1, @"/on": @1, @"/off": @0 };
    NSNumber *action = actions[path.lowercaseString];
    if (action == nil) {
        *error = [NSString stringWithFormat:@"Unknown action \"%@\". Use /toggle, /on or /off.", path];
        return NO;
    }
    BOOL keep = NO, showLog = NO;
    for (NSURLQueryItem *item in c.queryItems) {
        BOOL value;
        if (!scene_parse_bool(item.value, &value)) {
            *error = [NSString stringWithFormat:@"%@ must be 1 or 0, not \"%@\".", item.name, item.value ?: @""];
            return NO;
        }
        if ([item.name isEqualToString:@"keepInSwitcher"]) keep = value;
        else if ([item.name isEqualToString:@"log"]) showLog = value;
        else {
            *error = [NSString stringWithFormat:@"Unknown option \"%@\".", item.name];
            return NO;
        }
    }
    *desiredOut = action.intValue;
    *keepCardOut = keep;
    *showLogOut = showLog;
    return YES;
}

// What a request will most likely set: explicit on/off, or for a toggle the
// opposite of the current state (the worker decides finally, under its lock).
static int scene_expected_target(int desired)
{
    if (desired >= 0) return desired;
    return locationservices_enabled_local() == 1 ? 0 : 1;
}

// Private but long-stable: what the Home gesture does.
static void scene_suspend_to_home(void)
{
    SEL suspend = NSSelectorFromString(@"suspend");
    if ([UIApplication.sharedApplication respondsToSelector:suspend]) {
        ((void (*)(id, SEL))[UIApplication.sharedApplication methodForSelector:suspend])(
            UIApplication.sharedApplication, suspend);
    }
}

- (UIViewController *)topViewController {
    UIViewController *top = self.window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

- (void)showAlertTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self topViewController] presentViewController:ac animated:YES completion:nil];
}

// A small progress screen for quiet shortcut runs instead of Cyanide's UI:
// icon, title, a short status line and a progress bar.
static UIImageSymbolConfiguration *scene_quiet_symbol_config(void)
{
    return [UIImageSymbolConfiguration configurationWithPointSize:56 weight:UIImageSymbolWeightRegular];
}

static void scene_announce(NSString *text)
{
    if (text.length) UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, text);
}

// Title/icon for what the run is doing: "Turning Off Location Services"
// with a crossed-out location while working, "Location Services Off" (green
// checkmark) once the state is confirmed.
- (void)applyQuietTarget:(int)target done:(BOOL)done {
    self.quietTarget = target;
    if (target < 0) { self.quietTitle.text = @"Location Services"; return; }
    NSString *state = target ? @"On" : @"Off";
    self.quietTitle.text = done ? [NSString stringWithFormat:@"Location Services %@", state]
                                : [NSString stringWithFormat:@"Turning %@ Location Services", state];
    if (done) {
        if (@available(iOS 17.0, *)) [self.quietIcon removeAllSymbolEffects];
        self.quietIcon.image = [UIImage systemImageNamed:@"checkmark.circle.fill" withConfiguration:scene_quiet_symbol_config()];
        self.quietIcon.tintColor = UIColor.systemGreenColor;
    } else {
        self.quietIcon.image = [UIImage systemImageNamed:target ? @"location.fill" : @"location.slash.fill"
                                       withConfiguration:scene_quiet_symbol_config()];
        self.quietIcon.tintColor = UIColor.systemBlueColor;
    }
}

- (void)buildQuietCover {
    UIView *cover = [[UIView alloc] initWithFrame:self.window.bounds];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.backgroundColor = UIColor.systemBackgroundColor;
    cover.accessibilityViewIsModal = YES;   // VoiceOver stays on this screen

    UIImageView *icon = [UIImageView new];
    icon.contentMode = UIViewContentModeCenter;
    icon.isAccessibilityElement = NO;       // decorative; the title says it

    UILabel *title = [UILabel new];
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.font = [UIFontMetrics.defaultMetrics scaledFontForFont:
                  [UIFont systemFontOfSize:title.font.pointSize weight:UIFontWeightSemibold]];
    title.adjustsFontForContentSizeCategory = YES;
    title.textColor = UIColor.labelColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;

    UILabel *status = [UILabel new];
    status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    status.adjustsFontForContentSizeCategory = YES;
    status.textColor = UIColor.secondaryLabelColor;
    status.textAlignment = NSTextAlignmentCenter;
    status.numberOfLines = 0;

    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.isAccessibilityElement = NO;        // estimates; the status line carries the meaning
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *barWidth = [bar.widthAnchor constraintEqualToConstant:220];
    barWidth.priority = UILayoutPriorityDefaultHigh;
    barWidth.active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, title, status, bar ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    [stack setCustomSpacing:20 afterView:icon];
    [stack setCustomSpacing:18 afterView:status];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cover addSubview:stack];
    UILayoutGuide *safe = cover.safeAreaLayoutGuide;
    NSLayoutConstraint *centerY = [stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor constant:-30];
    centerY.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        centerY,
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor constant:16],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-16],
        [title.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor],
        [status.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor],
        [bar.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor],
    ]];
    [self.window addSubview:cover];
    self.quietCover = cover;
    self.quietIcon = icon;
    self.quietTitle = title;
    self.quietStatus = status;
    self.quietProgress = bar;
}

// Starts (or restarts) the progress screen for a new run: everything from a
// previous run is reset, and all its delayed callbacks become stale.
- (void)beginQuietRunForTarget:(int)target {
    if (!self.quietCover) [self buildQuietCover];
    self.quietRun++;
    self.quietFinished = NO;
    self.quietPendingPhase = nil;
    self.quietPhaseShownNs = 0;
    [self.quietProgress.layer removeAllAnimations];
    [self.quietProgress setProgress:0.05f animated:NO];
    self.quietStatus.text = @"Starting…";
    if (@available(iOS 17.0, *)) [self.quietIcon removeAllSymbolEffects];
    [self applyQuietTarget:target done:NO];
    // A gentle pulse while it works (not with Reduce Motion).
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        if (@available(iOS 17.0, *)) [self.quietIcon addSymbolEffect:[NSSymbolPulseEffect effect]];
    }
    scene_announce(self.quietTitle.text);
}

- (void)hideQuietCover {
    [self.quietCover removeFromSuperview];
    self.quietCover = nil;
    self.quietIcon = nil;
    self.quietTitle = nil;
    self.quietStatus = nil;
    self.quietProgress = nil;
    self.quietPendingPhase = nil;
    self.quietFinished = NO;
    self.quietRun++;   // stale callbacks of the old run do nothing
}

static const double kQuietMinPhase = 0.35;   // a phase stays readable at least this long

// A phase reported by the action. Only the newest one is ever shown: a phase
// that arrives while the current one is still within kQuietMinPhase replaces
// any phase already waiting (no replay of history). The result (fraction 1)
// is shown immediately and ends the progress; nothing after it is shown.
- (void)quietPhase:(float)fraction step:(NSString *)step over:(NSTimeInterval)over target:(int)target {
    if (!self.quietCover || self.quietFinished) return;
    if (target >= 0 && target != self.quietTarget) [self applyQuietTarget:target done:NO];
    NSDictionary *phase = @{ @"f": @(fraction), @"t": step ?: @"", @"o": @(over),
                             @"at": @(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) };
    double shownFor = self.quietPhaseShownNs
        ? (double)(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - self.quietPhaseShownNs) / 1e9 : kQuietMinPhase;
    if (fraction >= 1.0f || shownFor >= kQuietMinPhase) {
        self.quietPendingPhase = nil;
        [self showQuietPhase:phase];
        return;
    }
    BOOL timerRunning = self.quietPendingPhase != nil;
    self.quietPendingPhase = phase;   // newest wins
    if (timerRunning) return;
    NSUInteger run = self.quietRun;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kQuietMinPhase - shownFor) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) me = weakSelf;
        if (!me || me.quietRun != run || !me.quietPendingPhase || me.quietFinished) return;
        NSDictionary *next = me.quietPendingPhase;
        me.quietPendingPhase = nil;
        [me showQuietPhase:next];
    });
}

- (void)showQuietPhase:(NSDictionary *)phase {
    float fraction = [phase[@"f"] floatValue];
    NSString *text = phase[@"t"];
    // `over` was measured when the phase was reported; subtract any wait.
    double waited = (double)(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - [phase[@"at"] unsignedLongLongValue]) / 1e9;
    double over = MAX(0.0, [phase[@"o"] doubleValue] - waited);
    BOOL done = fraction >= 1.0f;
    self.quietPhaseShownNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    UIProgressView *bar = self.quietProgress;
    if (fraction > bar.progress) {
        if (UIAccessibilityIsReduceMotionEnabled()) {
            [bar setProgress:fraction animated:NO];
        } else {
            [bar layoutIfNeeded];
            [UIView animateWithDuration:MAX(over, 0.2) delay:0
                                options:UIViewAnimationOptionCurveLinear | UIViewAnimationOptionBeginFromCurrentState
                             animations:^{
                [bar setProgress:fraction animated:NO];
                [bar layoutIfNeeded];
            } completion:nil];
        }
    }
    if (done) {
        self.quietFinished = YES;
        // The state is confirmed; Cyanide still finishes its SpringBoard
        // cleanup before it leaves.
        [self applyQuietTarget:self.quietTarget done:YES];
        BOOL noChange = [text hasPrefix:@"Already"];
        self.quietStatus.text = noChange ? @"No change needed" : @"Finishing up…";
        scene_announce(self.quietTitle.text);
    } else {
        self.quietStatus.text = [text stringByAppendingString:@"…"];
        scene_announce(self.quietStatus.text);
    }
}

// A quiet shortcut link arriving before the scene is active: put up the
// progress screen right away, so Cyanide's normal UI doesn't flash first.
- (void)coverEarlyForURL:(NSURL *)url {
    if (self.actionInProgress) return;   // the running request owns the screen
    if (!url || ![url.host.lowercaseString isEqualToString:@"location-services"]) return;
    int desired; BOOL keep, showLog; NSString *err = nil;
    if (scene_parse_location_url(url, &desired, &keep, &showLog, &err) && !showLog)
        [self beginQuietRunForTarget:scene_expected_target(desired)];
}

// cyanide://location-services/toggle | /on | /off. Runs only that action.
//  - Default (quiet): a progress screen instead of Cyanide's UI; on success
//    Cyanide returns to the Home Screen as soon as its SpringBoard work is
//    finished (and SpringBoard then removes the switcher card unless
//    keepInSwitcher=1). On failure an alert explains why.
//  - log=1: the activity log is shown, with a short pause on the result.
// While one request runs, another is rejected without touching its screen.
- (void)handleActionURL:(NSURL *)url {
    if (![url.host.lowercaseString isEqualToString:@"location-services"]) {
        NSLog(@"[URL] unhandled %@", url);
        return;
    }
    if (self.actionInProgress) {
        [self showAlertTitle:@"Location Services" message:@"A change is already in progress."];
        return;
    }
    int desired = -1;
    BOOL keepCard = NO, showLog = NO;
    NSString *parseError = nil;
    if (!scene_parse_location_url(url, &desired, &keepCard, &showLog, &parseError)) {
        [self hideQuietCover];   // an early cover for this link must not stay
        [self showAlertTitle:@"Location Services Link" message:parseError];
        return;
    }
    NSUInteger generation = ++self.actionGeneration;
    self.actionInProgress = YES;
    // When the result actually appears on screen (main thread), for the
    // log=1 readability pause.
    __block uint64_t resultShownNs = 0;
    __block id observer = nil;
    if (showLog) {
        [self hideQuietCover];
        observer = [NSNotificationCenter.defaultCenter
            addObserverForName:kSettingsActionsDidCompleteNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            if (!resultShownNs) resultShownNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        }];
    } else if (!self.quietCover || self.quietFinished) {
        [self beginQuietRunForTarget:scene_expected_target(desired)];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_block_t run = ^{
        SettingsProgressBlock progress = showLog ? nil : ^(float fraction, NSString *step, NSTimeInterval over, int target) {
            typeof(self) me = weakSelf;
            if (me && generation == me.actionGeneration)
                [me quietPhase:fraction step:step over:over target:target];
        };
        settings_location_services_set_async(desired, !keepCard, progress, ^(BOOL ok, NSString *message,
                                                                              NSTimeInterval resultAge) {
            if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
            typeof(self) me = weakSelf;
            if (!me || generation != me.actionGeneration) return;
            me.actionInProgress = NO;
            if (!ok) {
                if (!showLog) {
                    [me hideQuietCover];
                    [me showAlertTitle:@"Location Services" message:message];
                }
                return;   // the log (log=1) already shows the failure
            }
            double wait = 0;
            if (showLog) {
                double shownFor = resultShownNs
                    ? (double)(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - resultShownNs) / 1e9 : 0;
                wait = MAX(0.0, 0.75 - shownFor);
            }
            // Quiet: leave at once — the result has been on screen during the
            // cleanup, and no presentation delay may outlast the card-removal
            // timer.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                typeof(self) me2 = weakSelf;
                // Only for this run, and only while still in front.
                if (!me2 || generation != me2.actionGeneration) return;
                if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
                scene_suspend_to_home();
            });
        });
    };
    if (showLog) [self presentActivityLogThen:run];
    else run();
}

// Shows a fresh activity log on top of whatever is up (its completion state
// is per instance, so an old one from an earlier action is replaced).
- (void)presentActivityLogThen:(dispatch_block_t)then {
    UIViewController *root = self.window.rootViewController;
    InstallProgressViewController *vc = [[InstallProgressViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationAutomatic;
    void (^present)(void) = ^{
        UIViewController *top = root;
        while (top.presentedViewController) top = top.presentedViewController;
        [top presentViewController:nav animated:YES completion:then];
    };
    UINavigationController *shown = (UINavigationController *)root.presentedViewController;
    if ([shown isKindOfClass:UINavigationController.class] &&
        [shown.viewControllers.firstObject isKindOfClass:InstallProgressViewController.class]) {
        [root dismissViewControllerAnimated:NO completion:present];
    } else if (!root) {
        if (then) then();
    } else {
        present();
    }
}

- (void)selectInitialTabIfNeeded {
    if (self.didSelectInitialTab) return;
    UITabBarController *tab = (UITabBarController *)self.window.rootViewController;
    if (![tab isKindOfClass:UITabBarController.class] || tab.viewControllers.count == 0) return;
    self.didSelectInitialTab = YES;
    tab.selectedIndex = 0; // Packages tab
}


- (void)sceneDidDisconnect:(UIScene *)scene {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
}


- (void)runUpdateCheck {
    UITabBarController *tab = (UITabBarController *)self.window.rootViewController;
    if (![tab isKindOfClass:UITabBarController.class]) return;
    // UpdateChecker walks `presentedViewController` to find the topmost VC and
    // presents from there, so the update prompt surfaces above whatever is up.
    [[UpdateChecker shared] checkForUpdatesIfNeededFrom:tab];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    cyanide_launch_trace("sceneDidBecomeActive: entry");
    [self selectInitialTabIfNeeded];
    settings_application_did_become_active();
    if (self.pendingActionURL) {
        NSURL *url = self.pendingActionURL;
        self.pendingActionURL = nil;
        [self handleActionURL:url];
    }
    // Runs every foreground; UpdateChecker enforces a per-process + 24-hour
    // persisted throttle so the API isn't hammered.
    // A shortcut run owns the screen: no update prompt over its log.
    if (!self.actionInProgress && !self.pendingActionURL) [self runUpdateCheck];
}


- (void)sceneWillResignActive:(UIScene *)scene {
    cyanide_launch_trace("sceneWillResignActive");
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
    //
    // Round 30 (panic-full-2026-10-03-184716): close the exception-port gate
    // HERE, at the START of the resignation sequence — not at didEnterBackground.
    // runningboardd policy-sets this task around the backgrounding transition;
    // closing the gate now gives any in-flight arm/sign trap the whole
    // resign->background interval (typically hundreds of ms) to clear before
    // rbd touches our task locks. 184716: the user backgrounded 14 ms into the
    // pre-warm arm loop; the gate was still open (didEnterBackground had not
    // fired), a trap entered the kernel, and rbd deadlocked against it ->
    // watchdog panic 180 s later. Re-opened by didBecomeActive /
    // willEnterForeground, so transient interruptions (control center, call
    // banner) only cost a few refused ops.
    excport_gate_set_backgrounded(true);
}


- (void)sceneWillEnterForeground:(UIScene *)scene {
    cyanide_launch_trace("sceneWillEnterForeground");
    // A quiet shortcut run that sent Cyanide home leaves its cover behind;
    // a normal reopen must show the app (a new shortcut run puts it back).
    if (!self.actionInProgress) [self hideQuietCover];
    settings_application_will_enter_foreground();
}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    cyanide_launch_trace("sceneDidEnterBackground: entry");
    settings_application_did_enter_background();
    cyanide_launch_trace("sceneDidEnterBackground: exit");
}


@end
