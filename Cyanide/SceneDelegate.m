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
// YES when that request cold-launched Cyanide (no scene, often no process,
// existed before it). Only such a run may have its switcher card removed
// afterwards — a request that found Cyanide already open must never take
// the app (and whatever the user had open in it) down with the card.
@property (nonatomic, assign) BOOL pendingActionCold;
// A cyanide://location-services link arrived while links are off; told once active.
@property (nonatomic, assign) BOOL blockedLinkNotice;
// Who asked for pendingActionURL, if it was the Control Center toggle.
@property (nonatomic, copy) CYLocationRequestCompletion pendingActionCompletion;
// A successful quiet run that couldn't go Home because Cyanide was inactive
// at that moment: done on the next activation.
@property (nonatomic, assign) BOOL homeOnNextActivation;
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

// Control Center request that arrived before any scene connected.
static NSURL *g_scene_intent_url = nil;
static CYLocationRequestCompletion g_scene_intent_completion = nil;

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
    // Cold launch from a shortcut URL (or a Control Center toggle that ran
    // before this scene existed); handled once the scene is active. Both
    // paths cold-launched Cyanide — no scene existed before the request —
    // so a successful quiet run may remove the switcher card afterwards.
    NSURL *linkURL = connectionOptions.URLContexts.anyObject.URL;
    if (linkURL && ![self acceptLinkURL:linkURL]) linkURL = nil;
    if (linkURL) {
        [self setPendingURL:linkURL completion:nil coldLaunched:YES];
        if (g_scene_intent_completion) g_scene_intent_completion(NO, @"Another Location Services request came first.");
    } else {
        [self setPendingURL:g_scene_intent_url completion:g_scene_intent_completion coldLaunched:YES];
    }
    g_scene_intent_url = nil;
    g_scene_intent_completion = nil;
    [self coverEarlyForURL:self.pendingActionURL];
    cyanide_launch_trace("scene willConnect: exit");
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    NSURL *url = URLContexts.anyObject.URL;
    if (!url || ![self acceptLinkURL:url]) {
        if (scene.activationState == UISceneActivationStateForegroundActive) [self showBlockedLinkNoticeIfNeeded];
        return;
    }
    // A URL delivered to an already-connected scene: Cyanide was open.
    [self receiveActionURL:url scene:scene completion:nil coldLaunched:NO];
}

// cyanide:// links can be opened by ANY app, without a prompt (only Safari
// asks), and a Location Services link changes a system-wide setting (and
// Find My). So links are off unless the user turns on Settings → Launch
// Options → "Location Services links". Control Center and the Shortcuts
// action are not links: they come in through +cy_runLocationURL:completion:,
// which iOS only calls for the user's own controls and shortcuts.
- (BOOL)acceptLinkURL:(NSURL *)url {
    if (![url.host.lowercaseString isEqualToString:@"location-services"]) return YES;   // other links: unchanged
    if ([NSUserDefaults.standardUserDefaults boolForKey:kSettingsLocationServicesLinksEnabled]) return YES;
    printf("[LOCSVC] link ignored (Location Services links are off): %s\n", url.absoluteString.UTF8String);
    self.blockedLinkNotice = YES;
    return NO;
}

- (void)showBlockedLinkNoticeIfNeeded {
    if (!self.blockedLinkNotice) return;
    self.blockedLinkNotice = NO;
    [self showAlertTitle:@"Location Services Link"
                 message:@"A link asked Cyanide to change Location Services. Links are off, so nothing was changed. "
                         @"Use the Control Center toggle or the Shortcuts action instead, or turn on "
                         @"Settings → Launch Options → Location Services links."];
}

// A request waiting for activation. A newer one replaces it; the replaced
// one's requester is told it didn't run. `cold` is whether that request
// cold-launched Cyanide (see pendingActionCold).
- (void)setPendingURL:(NSURL *)url completion:(CYLocationRequestCompletion)completion coldLaunched:(BOOL)cold {
    CYLocationRequestCompletion replaced = self.pendingActionCompletion;
    self.pendingActionURL = url;
    self.pendingActionCompletion = completion;
    self.pendingActionCold = cold;
    if (replaced && replaced != completion) replaced(NO, @"A newer Location Services request replaced this one.");
}

- (void)receiveActionURL:(NSURL *)url scene:(UIScene *)scene completion:(CYLocationRequestCompletion)completion coldLaunched:(BOOL)cold {
    if (scene.activationState == UISceneActivationStateForegroundActive) {
        [self handleActionURL:url completion:completion coldLaunched:cold];
    } else {
        [self setPendingURL:url completion:completion coldLaunched:cold];   // sceneDidBecomeActive runs it
        [self coverEarlyForURL:url];
    }
}

// A request from the Control Center toggle (SetLocationServicesIntent, run
// in this process via openAppWhenRun). Handled exactly like the matching
// cyanide://location-services URL. Before any scene exists (cold launch)
// it waits for the first one to connect (g_scene_intent_url). `completion`
// runs once on the main thread: when the state is confirmed (or the request
// failed or was rejected), before Cyanide goes Home.
+ (void)cy_runLocationURL:(NSURL *)url completion:(CYLocationRequestCompletion)completion {
    __block BOOL called = NO;
    CYLocationRequestCompletion once = ^(BOOL ok, NSString *message) {
        if (called || !completion) return;
        called = YES;
        completion(ok, message ?: @"");
    };
    if (![url isKindOfClass:NSURL.class]) { once(NO, @"Invalid request."); return; }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene.delegate isKindOfClass:SceneDelegate.class]) {
            // A live scene means Cyanide was already open (in front or
            // suspended with a switcher card): not a cold launch.
            [(SceneDelegate *)scene.delegate receiveActionURL:url scene:scene completion:once coldLaunched:NO];
            return;
        }
    }
    if (g_scene_intent_completion) g_scene_intent_completion(NO, @"A newer Location Services request replaced this one.");
    g_scene_intent_url = url;
    g_scene_intent_completion = once;
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
// Whether Cyanide can send itself to the Home Screen at all (UIKit's private
// -suspend). Without it the run stays in front, so it must not arm the
// switcher-card removal: the removal would then close the app in front of
// the user.
static BOOL scene_can_suspend_to_home(void)
{
    return [UIApplication.sharedApplication respondsToSelector:NSSelectorFromString(@"suspend")];
}

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
//    finished. Only a run that COLD-LAUNCHED Cyanide then has SpringBoard
//    remove the switcher card (unless keepInSwitcher=1) — the card was
//    created for that run. A request that found Cyanide already open never
//    removes the card: it would close the app in front of the user, and a
//    quick second toggle would be cut off by the first run's timer.
//  - log=1: the activity log is shown, with a short pause on the result.
// While one request runs, another is rejected without touching its screen.
- (void)handleActionURL:(NSURL *)url {
    [self handleActionURL:url completion:nil coldLaunched:NO];
}

- (void)handleActionURL:(NSURL *)url completion:(CYLocationRequestCompletion)requester coldLaunched:(BOOL)cold {
    if (![url.host.lowercaseString isEqualToString:@"location-services"]) {
        NSLog(@"[URL] unhandled %@", url);
        if (requester) requester(NO, @"Unsupported link.");
        return;
    }
    if (self.actionInProgress) {
        // The running request owns the screen: no alert over its progress
        // or log, just tell the requester and VoiceOver.
        NSLog(@"[URL] rejected while a change is in progress: %@", url);
        scene_announce(@"A Location Services change is already in progress.");
        if (requester) requester(NO, @"A Location Services change is already in progress.");
        return;
    }
    if (settings_switcher_removal_pending()) {
        // An earlier cold run's card removal is still armed and will end
        // Cyanide within its window. It cannot be cancelled safely (a
        // pre-fire SpringBoard hijack is the activation ABBA deadlock the
        // settle window prevents), and any kernel work started now would be
        // killed mid-flight — so fail fast instead of letting the caller
        // watch a progress screen that is about to disappear.
        NSLog(@"[URL] rejected: an App Switcher card removal is still pending: %@", url);
        NSString *busy = @"Cyanide is closing from the previous run. Try again in a few seconds.";
        scene_announce(busy);
        if (requester) requester(NO, busy);
        else [self showAlertTitle:@"Location Services" message:busy];
        return;
    }
    self.homeOnNextActivation = NO;
    int desired = -1;
    BOOL keepCard = NO, showLog = NO;
    NSString *parseError = nil;
    if (!scene_parse_location_url(url, &desired, &keepCard, &showLog, &parseError)) {
        [self hideQuietCover];   // an early cover for this link must not stay
        [self showAlertTitle:@"Location Services Link" message:parseError];
        if (requester) requester(NO, parseError);
        return;
    }
    // Only a run that cold-launched Cyanide removes the switcher card (and
    // keepInSwitcher=1 opts even that out). A run that found Cyanide open
    // keeps the card — the app was the user's before the request.
    BOOL removeCard = cold && !keepCard && scene_can_suspend_to_home();
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
    } else {
        // Adopting the early cover: it may have been put up for an earlier
        // link that this one replaced.
        int expected = scene_expected_target(desired);
        if (expected != self.quietTarget) [self applyQuietTarget:expected done:NO];
    }
    // log=1: the result stays readable for a moment before Home.
    static const double kLogResultPause = 0.75;
    __weak typeof(self) weakSelf = self;
    dispatch_block_t run = ^{
        SettingsProgressBlock progress = showLog ? nil : ^(float fraction, NSString *step, NSTimeInterval over, int target) {
            typeof(self) me = weakSelf;
            if (me && generation == me.actionGeneration)
                [me quietPhase:fraction step:step over:over target:target];
        };
        // Never a fresh exploit run from outside the app (Control Center,
        // Shortcuts, links): it can reboot A18/M4 devices, and nobody tapped
        // "Run Full Exploit". Live or parked kernel access only.
        // removeCard: only a run that cold-launched Cyanide (and did not ask
        // to keep the card) may have the switcher card removed afterwards.
        settings_location_services_set_async(desired, NO, removeCard, showLog ? kLogResultPause : 0, progress,
                                             ^(BOOL ok, NSString *rawMessage, NSTimeInterval resultAge) {
            NSString *message = [rawMessage isEqualToString:kSettingsFullExploitRequiredMessage]
                ? @"Cyanide has no saved kernel access (for example after a restart). Open Cyanide and run it once, then try again."
                : rawMessage;
            if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
            // The requester hears the outcome first, before Cyanide leaves.
            if (requester) requester(ok, message);
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
                wait = MAX(0.0, kLogResultPause - shownFor);
            }
            // Quiet: leave at once — the result has been on screen during the
            // cleanup, and no presentation delay may outlast the card-removal
            // timer.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                typeof(self) me2 = weakSelf;
                // Only for this run, and only while still in front.
                if (!me2 || generation != me2.actionGeneration) return;
                if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
                    // Briefly inactive (Control Center, a call banner): go
                    // Home when it is back, instead of staying on the result.
                    me2.homeOnNextActivation = YES;
                    return;
                }
                scene_suspend_to_home();
                // Diagnostic: if this run armed the card removal and Cyanide is
                // still in front shortly after, the removal will close it in
                // front of the user (it can't be cancelled; see
                // settings_switcher_removal_pending). Log it so the case shows.
                if (removeCard) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
                            NSLog(@"[URL] WARNING: still in front 0.5 s after going Home, with the "
                                  @"switcher-card removal armed");
                    });
                }
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
    [self showBlockedLinkNoticeIfNeeded];
    if (self.pendingActionURL) {
        NSURL *url = self.pendingActionURL;
        CYLocationRequestCompletion completion = self.pendingActionCompletion;
        BOOL cold = self.pendingActionCold;
        self.pendingActionURL = nil;
        self.pendingActionCompletion = nil;
        self.pendingActionCold = NO;
        [self handleActionURL:url completion:completion coldLaunched:cold];
    } else if (self.homeOnNextActivation && !self.actionInProgress) {
        self.homeOnNextActivation = NO;
        scene_suspend_to_home();
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
    // But keep it when a location request is already waiting for activation:
    // coverEarlyForURL just put it up for that request (on a cold launch,
    // from the very first frame), and tearing it down here only to rebuild it
    // in sceneDidBecomeActive flashed the normal UI in between.
    BOOL pendingQuiet = NO;
    NSURL *pending = self.pendingActionURL;
    if ([pending.host.lowercaseString isEqualToString:@"location-services"]) {
        int desired; BOOL keep, showLog; NSString *err = nil;
        pendingQuiet = scene_parse_location_url(pending, &desired, &keep, &showLog, &err) && !showLog;
    }
    if (!self.actionInProgress && !pendingQuiet) [self hideQuietCover];
    self.homeOnNextActivation = NO;   // a real reopen: the user wants the app
    settings_application_will_enter_foreground();
}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    cyanide_launch_trace("sceneDidEnterBackground: entry");
    settings_application_did_enter_background();
    cyanide_launch_trace("sceneDidEnterBackground: exit");
}


@end
