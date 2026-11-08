//
//  SceneDelegate.m
//  Cyanide
//
//  Created by seo on 3/24/26.
//

#import "SceneDelegate.h"
#import <objc/message.h>
#import "LogTextView.h"
#import "AppDelegate.h"            // round 31: cyanide_launch_trace
#import "SettingsViewController.h"
#import "tweaks/location_services.h"
#import "installer/InstallProgressViewController.h"
#import "UpdateChecker.h"
#import "FileBrowserViewController.h"
#import "TaskRop/Exception.h"   // round 30: excport lifecycle gate (early close)

// Did this request launch Cyanide? "A scene already exists" is not the test:
// a Control Center toggle or Shortcuts action (openAppWhenRun) launches the
// app first, its scene connects, and only then does the request arrive -- so
// a run that started Cyanide from nothing (card swiped away before) looked
// like "Cyanide was already open" and kept the card. Instead: the first
// request since this process started, arriving within a few seconds of the
// start, launched it. Cyanide that was already running is older than that,
// or has handled a request before, or was opened by the user (touched, or
// kept in front a few seconds: g_scene_user_opened).
static uint64_t g_scene_process_start_ns = 0;
__attribute__((constructor)) static void scene_note_process_start(void)
{
    g_scene_process_start_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}
static BOOL g_scene_any_request = NO;   // main thread only

// A fresh PROCESS doesn't mean a fresh card: iOS often ends a backgrounded
// Cyanide while its switcher card stays, and the next toggle starts a new
// process. The card is backed by the scene session, which survives until the
// user swipes the card away; a relaunch with the card still there reconnects
// the SAME session, a launch after a swipe-away gets a new one. So the card
// existed before this launch exactly when the session is one we saw before.
static NSString * const kSceneLastSessionIDKey = @"SceneLastSessionID";
static BOOL g_scene_session_restored = NO;

static void scene_note_session(UISceneSession *session)
{
    NSString *sid = session.persistentIdentifier;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *last = [d stringForKey:kSceneLastSessionIDKey];
    g_scene_session_restored = sid.length > 0 && [sid isEqualToString:last];
    if (sid.length) [d setObject:sid forKey:kSceneLastSessionIDKey];
    log_user("[URL] scene session %s — %s\n", sid.UTF8String ?: "?",
             g_scene_session_restored ? "restored: the switcher card existed before this launch"
                                      : "new: no earlier switcher card");
}

// The user opened Cyanide in this process: touched its UI, or kept it in
// front for kSceneUserStaySeconds, with no request waiting. Timing alone can't
// tell: a Control Center launch sometimes shows Cyanide for 1-2 s, sends it to
// the background and delivers the request 2-3 s later -- exactly what "open
// Cyanide, go Home, use the toggle" looks like. A touch or a longer stay is
// something only the user does.
static BOOL g_scene_user_opened = NO;               // main thread only
// The same signals per foreground visit: the user touched Cyanide or kept it
// in front kSceneUserStaySeconds since it last came to the foreground. A
// request arriving during such a visit was run from inside Cyanide (Control
// Center or Siri over it) and stays there; any other request brought Cyanide
// up and sends the user back afterwards. Reset when the scene connects or
// enters the foreground.
static BOOL g_scene_visit_user_owned = NO;          // main thread only
static uint64_t g_scene_idle_active_since_ns = 0;   // active with no request; 0 = not
static const double kSceneUserStaySeconds = 4.0;

static void scene_note_idle_active_end(void)
{
    if (!g_scene_idle_active_since_ns) return;
    double stayed = (double)(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - g_scene_idle_active_since_ns) / 1e9;
    g_scene_idle_active_since_ns = 0;
    if (stayed >= kSceneUserStaySeconds) g_scene_visit_user_owned = YES;
    if (stayed >= kSceneUserStaySeconds && !g_scene_user_opened) {
        g_scene_user_opened = YES;
        log_user("[URL] app was in front %.1fs: opened by the user\n", stayed);
    }
}

static void scene_note_user_touch(void)
{
    g_scene_visit_user_owned = YES;
    if (g_scene_user_opened) return;
    g_scene_user_opened = YES;
    log_user("[URL] app touched: opened by the user\n");
}

void scene_forget_switcher_card(NSString *sessionID, const char *why)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *last = [d stringForKey:kSceneLastSessionIDKey];
    if (!last || (sessionID && ![sessionID isEqualToString:last])) return;
    [d removeObjectForKey:kSceneLastSessionIDKey];
    [d synchronize];   // the process is about to end
    log_user("[URL] switcher card gone (%s): the next launch starts without one\n", why ?: "?");
}

static BOOL scene_request_launched_app(void)
{
    BOOL first = !g_scene_any_request;
    g_scene_any_request = YES;
    scene_note_idle_active_end();
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    double age = (double)(now - g_scene_process_start_ns) / 1e9;
    BOOL launched = first && !g_scene_user_opened && !g_scene_session_restored && age < 8.0;
    log_user("[URL] request judged %s (first=%d userOpened=%d restored=%d age=%.1fs)\n",
             launched ? "a cold launch: card may be removed" : "not a cold launch: card kept",
             first, g_scene_user_opened, g_scene_session_restored, age);
    return launched;
}

// Sees every touch in the window without taking part in gesture handling.
@interface CYTouchWatcher : UIGestureRecognizer
@property (nonatomic, copy) void (^onTouch)(void);
@end
@implementation CYTouchWatcher
- (instancetype)init {
    if ((self = [super initWithTarget:nil action:nil])) {
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.onTouch) self.onTouch();
    self.state = UIGestureRecognizerStateFailed;
}
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
@end

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
// The blocked link was a respring/reboot one (different notice).
@property (nonatomic, assign) BOOL blockedLinkWasPower;
// Who asked for pendingActionURL, if it was the Control Center toggle.
@property (nonatomic, copy) CYLocationRequestCompletion pendingActionCompletion;
// A successful quiet run that couldn't go Home because Cyanide was inactive
// at that moment: done on the next activation.
@property (nonatomic, assign) BOOL homeOnNextActivation;
// With homeOnNextActivation: the app to go back to instead of Home (nil = Home).
@property (nonatomic, copy) NSString *returnAppOnNextActivation;
// Generation that owns the deferred return. A newer action supersedes it.
@property (nonatomic, assign) NSUInteger deferredReturnGeneration;
// Whether the waiting request (pendingActionURL) brought Cyanide to the
// front, judged when it arrived (g_scene_visit_user_owned).
@property (nonatomic, assign) BOOL pendingActionBroughtToFront;
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
    scene_note_session(session);   // before any request is judged (scene_request_launched_app)
    g_scene_visit_user_owned = NO;
    cyanide_launch_trace("scene willConnect: entry");
    {
        // Diagnostics: what iOS says about why this scene connected.
        NSMutableArray *acts = [NSMutableArray array];
        for (NSUserActivity *a in connectionOptions.userActivities) [acts addObject:a.activityType ?: @"?"];
        UIOpenURLContext *ctx = connectionOptions.URLContexts.anyObject;
        log_user("[URL] connect: urls=%lu src=%s activities=[%s] handoff=%s shortcut=%s\n",
                 (unsigned long)connectionOptions.URLContexts.count,
                 ctx.options.sourceApplication.UTF8String ?: "-",
                 [acts componentsJoinedByString:@","].UTF8String,
                 connectionOptions.handoffUserActivityType.UTF8String ?: "-",
                 connectionOptions.shortcutItem.type.UTF8String ?: "-");
    }
    if (self.window) {
        __weak typeof(self) weakSelf = self;
        CYTouchWatcher *watcher = [CYTouchWatcher new];
        watcher.onTouch = ^{
            typeof(self) me = weakSelf;
            // Touches on the toggle's own progress screen don't count.
            if (me && !me.actionInProgress && !me.pendingActionURL && !me.quietCover) scene_note_user_touch();
        };
        [self.window addGestureRecognizer:watcher];
    }
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
        [self setPendingURL:linkURL completion:nil coldLaunched:scene_request_launched_app()];
        if (g_scene_intent_completion) g_scene_intent_completion(NO, @"Another Location Services request came first.");
    } else {
        // (No request yet when g_scene_intent_url is nil: don't count one.)
        BOOL launched = g_scene_intent_url ? scene_request_launched_app() : NO;
        [self setPendingURL:g_scene_intent_url completion:g_scene_intent_completion coldLaunched:launched];
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
    [self receiveActionURL:url scene:scene completion:nil coldLaunched:scene_request_launched_app()];
}

// cyanide:// links can be opened by ANY app, without a prompt (only Safari
// asks), and a Location Services link changes a system-wide setting (and
// Find My). So links are off unless the user turns on Settings → Launch
// Options → "Location Services links". Control Center and the Shortcuts
// action are not links: they come in through +cy_runLocationURL:completion:,
// which iOS only calls for the user's own controls and shortcuts.
static BOOL scene_is_power_url(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    return [host isEqualToString:@"respring"] || [host isEqualToString:@"reboot"];
}

- (BOOL)acceptLinkURL:(NSURL *)url {
    if (scene_is_power_url(url)) {
        // Same reasoning as Location Services: any app could restart the
        // device, so these links are off unless the user turns them on.
        if ([NSUserDefaults.standardUserDefaults boolForKey:kSettingsPowerLinksEnabled]) return YES;
        printf("[URL] link ignored (respring and reboot links are off): %s\n", url.absoluteString.UTF8String);
        self.blockedLinkNotice = YES;
        self.blockedLinkWasPower = YES;
        return NO;
    }
    if (![url.host.lowercaseString isEqualToString:@"location-services"]) return YES;   // other links: unchanged
    if ([NSUserDefaults.standardUserDefaults boolForKey:kSettingsLocationServicesLinksEnabled]) return YES;
    printf("[LOCSVC] link ignored (Location Services links are off): %s\n", url.absoluteString.UTF8String);
    self.blockedLinkNotice = YES;
    return NO;
}

- (void)showBlockedLinkNoticeIfNeeded {
    if (!self.blockedLinkNotice) return;
    self.blockedLinkNotice = NO;
    if (self.blockedLinkWasPower) {
        self.blockedLinkWasPower = NO;
        [self showAlertTitle:@"Respring / Reboot Link"
                     message:@"A link asked Cyanide to respring or reboot. These links are off, so nothing happened. "
                             @"Use the Control Center buttons or the Shortcuts actions instead, or turn on "
                             @"Settings → Launch Options → Respring and reboot links."];
        return;
    }
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
    self.pendingActionBroughtToFront = cold || !g_scene_visit_user_owned;
    if (replaced && replaced != completion) replaced(NO, @"A newer Location Services request replaced this one.");
}

- (void)receiveActionURL:(NSURL *)url scene:(UIScene *)scene completion:(CYLocationRequestCompletion)completion coldLaunched:(BOOL)cold {
    if (scene.activationState == UISceneActivationStateForegroundActive) {
        [self handleActionURL:url completion:completion coldLaunched:cold
               broughtToFront:cold || !g_scene_visit_user_owned];
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
            // The scene may exist only because iOS just launched Cyanide for
            // this request (openAppWhenRun): decide by the request, not the scene.
            [(SceneDelegate *)scene.delegate receiveActionURL:url scene:scene completion:once
                                                coldLaunched:scene_request_launched_app()];
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
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSURLQueryItem *item in c.queryItems) {
        // An option given twice has no clear meaning: refuse it.
        if ([seen containsObject:item.name]) {
            *error = [NSString stringWithFormat:@"Option \"%@\" is given more than once.", item.name];
            return NO;
        }
        [seen addObject:item.name ?: @""];
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

static const double kSceneReturnAppTimeout = 1.5;

// Brings another app to the front, as a launch from its icon would.
// NO when iOS refused (or the API is missing): the caller goes Home instead.
static BOOL scene_open_app(NSString *bundleID)
{
    if (bundleID.length == 0) return NO;
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (![workspaceClass respondsToSelector:defaultSel]) return NO;
    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSel);
    if (![workspace respondsToSelector:openSel]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSel, bundleID);
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
//  - Default (quiet): a progress screen instead of Cyanide's UI; on success,
//    as soon as its SpringBoard work is finished, Cyanide goes back to where
//    the request was made: the app that was open, or the Home Screen (also
//    when that can't be read). Run while Cyanide itself was in front, it
//    stays. Only a run that COLD-LAUNCHED Cyanide then has SpringBoard
//    remove the switcher card (unless keepInSwitcher=1) — the card was
//    created for that run. A request that found Cyanide already open never
//    removes the card: it would close the app in front of the user, and a
//    quick second toggle would be cut off by the first run's timer.
//  - log=1: the activity log is shown, with a short pause on the result.
// While one request runs, another is rejected without touching its screen.
- (void)handleActionURL:(NSURL *)url {
    [self handleActionURL:url completion:nil coldLaunched:NO];
}

// cyanide://respring and cyanide://reboot (links, the Shortcuts actions and
// the Control Center buttons). Nothing to return to afterwards: SpringBoard
// or the whole device restarts.
- (void)handlePowerURL:(NSURL *)url completion:(CYLocationRequestCompletion)requester {
    BOOL reboot = [url.host.lowercaseString isEqualToString:@"reboot"];
    NSString *title = reboot ? @"Reboot" : @"Respring";
    if (self.actionInProgress) {
        NSString *busy = @"Another Cyanide request is in progress.";
        scene_announce(busy);
        if (requester) requester(NO, busy);
        return;
    }
    self.actionInProgress = YES;
    __weak typeof(self) weakSelf = self;
    settings_power_action_async(reboot, [self topViewController], ^(BOOL ok, NSString *message) {
        typeof(self) me = weakSelf;
        me.actionInProgress = NO;
        if (requester) requester(ok, message ?: @"");
        if (!ok) [me showAlertTitle:title message:message];
    });
}

- (void)handleActionURL:(NSURL *)url completion:(CYLocationRequestCompletion)requester coldLaunched:(BOOL)cold {
    [self handleActionURL:url completion:requester coldLaunched:cold
           broughtToFront:cold || !g_scene_visit_user_owned];
}

// Back to where the request was made: the app that was open, else Home.
// If iOS doesn't bring the app up, Home as before -- never left sitting on
// the result. Cyanide stops being active as soon as the switch to the app
// starts, so only a request that never started shows as "still active";
// the window leaves room for a slow (cold) relaunch of that app.
- (void)leaveToApp:(NSString *)bundleID {
    // Live tweaks keep calling into SpringBoard while Cyanide is in front; one
    // cut off by the background gate kills SpringBoard. Let them finish first.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        settings_quiesce_remote_calls_before_leaving("Location Services return");
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf leaveToAppNow:bundleID];
        });
    });
}

- (void)leaveToAppNow:(NSString *)bundleID {
    if (bundleID.length == 0 || !scene_open_app(bundleID)) {
        if (bundleID.length) NSLog(@"[URL] could not reopen the previous app; going Home");
        scene_suspend_to_home();
        return;
    }
    NSUInteger generation = self.actionGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSceneReturnAppTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) me = weakSelf;
        if (!me || generation != me.actionGeneration || me.actionInProgress) return;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        NSLog(@"[URL] previous app did not come up; going Home");
        scene_suspend_to_home();
    });
}

- (void)handleActionURL:(NSURL *)url completion:(CYLocationRequestCompletion)requester coldLaunched:(BOOL)cold
         broughtToFront:(BOOL)broughtToFront {
    if (scene_is_power_url(url)) {
        [self handlePowerURL:url completion:requester];
        return;
    }
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
        // actionInProgress was rejected above, so any remaining quiet cover is
        // an early/stale cover owned by no running request. Remove only that
        // unowned cover; a live request's UI is never reached here.
        [self hideQuietCover];
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
    int desired = -1;
    BOOL keepCard = NO, showLog = NO;
    NSString *parseError = nil;
    if (!scene_parse_location_url(url, &desired, &keepCard, &showLog, &parseError)) {
        [self hideQuietCover];   // an early cover for this link must not stay
        [self showAlertTitle:@"Location Services Link" message:parseError];
        if (requester) requester(NO, parseError);
        return;
    }
    // The initial no-kernel result is not terminal on A18/M4: the user may
    // confirm a manual exploit and the same request will then be retried.
    // Keep the caller's completion at the transaction boundary so it cannot
    // observe that intermediate failure or be lost on the retry.
    __block BOOL completionDelivered = NO;
    CYLocationRequestCompletion finish = ^(BOOL ok, NSString *message) {
        if (completionDelivered) return;
        completionDelivered = YES;
        if (requester) requester(ok, message ?: @"");
    };
    // A newly accepted action supersedes a deferred return owned by an older
    // run. Invalid or rejected requests leave the completed run's intent alone.
    self.homeOnNextActivation = NO;
    self.returnAppOnNextActivation = nil;
    self.deferredReturnGeneration = 0;
    // Only a run that cold-launched Cyanide removes the switcher card (and
    // keepInSwitcher=1 opts even that out). A run that found Cyanide open
    // keeps the card — the app was the user's before the request.
    BOOL removeCard = cold && !keepCard && scene_can_suspend_to_home();
    // Leave only if this request brought Cyanide to the front; one run while
    // the user had Cyanide open (Siri or Control Center over it) stays.
    log_user("[URL] request %s\n", broughtToFront ? "brought Cyanide to the front: will go back afterwards"
                                                  : "came while Cyanide was open: staying");
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
    __block BOOL operationCallbackHandled = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_block_t run = ^{
        SettingsProgressBlock progress = showLog ? nil : ^(float fraction, NSString *step, NSTimeInterval over, int target) {
            typeof(self) me = weakSelf;
            if (me && generation == me.actionGeneration)
                [me quietPhase:fraction step:step over:over target:target];
        };
        // Live or parked kernel access; a fresh exploit run only where it
        // can't reboot the device. On A18/M4 the user starts it below, with
        // the log shown.
        // removeCard: only a run that cold-launched Cyanide (and did not ask
        // to keep the card) may have the switcher card removed afterwards.
        settings_location_services_set_async(desired, NO, removeCard, broughtToFront,
                                             showLog ? kLogResultPause : 0, progress,
                                             ^(BOOL ok, NSString *rawMessage, NSTimeInterval resultAge) {
            if (operationCallbackHandled) return;
            operationCallbackHandled = YES;
            NSString *message = [rawMessage isEqualToString:kSettingsFullExploitRequiredMessage]
                ? @"Cyanide has no saved kernel access (for example after a restart). Open Cyanide and run it once, then try again."
                : rawMessage;
            if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
            typeof(self) me = weakSelf;
            if (!me || generation != me.actionGeneration) {
                finish(NO, @"The Location Services request was superseded before it finished.");
                return;
            }
            if (!ok && [rawMessage isEqualToString:kSettingsFullExploitRequiredMessage]) {
                // A18/M4 without saved kernel access (other devices run the
                // exploit by themselves): offer Run Exploit with its log, then
                // repeat this request.
                [me hideQuietCover];
                settings_run_exploit_with_log([me topViewController], ^(BOOL ready) {
                    typeof(self) retryOwner = weakSelf;
                    if (!retryOwner || generation != retryOwner.actionGeneration ||
                        !retryOwner.actionInProgress) {
                        finish(NO, @"The Location Services retry was superseded before it finished.");
                        return;
                    }
                    if (!ready) {
                        retryOwner.actionInProgress = NO;
                        NSString *retryMessage =
                            @"Location Services request cancelled: kernel access was not acquired.";
                        finish(NO, retryMessage);
                        if (!showLog) {
                            UIViewController *top = [retryOwner topViewController];
                            if (![top isKindOfClass:UIAlertController.class]) {
                                [retryOwner showAlertTitle:@"Location Services" message:retryMessage];
                            }
                        } else {
                            scene_announce(retryMessage);
                        }
                        return;
                    }
                    // Re-enter the normal action path with the same completion;
                    // this is one user transaction, not a new request.
                    retryOwner.actionInProgress = NO;
                    [retryOwner handleActionURL:url completion:finish coldLaunched:cold
                                  broughtToFront:broughtToFront];
                });
                return;
            }
            // The requester hears the terminal outcome first, before Cyanide
            // leaves or exposes a failure alert.
            finish(ok, message);
            me.actionInProgress = NO;
            if (!ok) {
                if (!showLog) {
                    [me hideQuietCover];
                    [me showAlertTitle:@"Location Services" message:message];
                }
                return;   // the log (log=1) already shows the failure
            }
            // Where to go: the app the user was in, Home if they were on the
            // Home Screen or it couldn't be read (as before), or nowhere if
            // Cyanide was already in front.
            NSString *returnApp = nil;
            NSInteger origin = broughtToFront ? settings_location_services_take_origin(&returnApp) : 0;
            if (!broughtToFront) {
                if (!showLog) [me hideQuietCover];
                return;
            }
            if (origin != 2) returnApp = nil;
            if ([returnApp isEqualToString:NSBundle.mainBundle.bundleIdentifier]) {
                // Never "back" to Cyanide itself: there was nothing to leave.
                if (!showLog) [me hideQuietCover];
                return;
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
                    // Briefly inactive (Control Center, a call banner): leave
                    // when it is back, instead of staying on the result.
                    me2.homeOnNextActivation = YES;
                    me2.returnAppOnNextActivation = returnApp;
                    me2.deferredReturnGeneration = generation;
                    return;
                }
                [me2 leaveToApp:returnApp];
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
    g_scene_idle_active_since_ns = (!self.pendingActionURL && !self.actionInProgress)
        ? clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) : 0;
    if (self.pendingActionURL) {
        NSURL *url = self.pendingActionURL;
        CYLocationRequestCompletion completion = self.pendingActionCompletion;
        BOOL cold = self.pendingActionCold;
        BOOL broughtToFront = self.pendingActionBroughtToFront;
        self.pendingActionURL = nil;
        self.pendingActionCompletion = nil;
        self.pendingActionCold = NO;
        self.pendingActionBroughtToFront = NO;
        [self handleActionURL:url completion:completion coldLaunched:cold broughtToFront:broughtToFront];
    } else if (self.homeOnNextActivation && !self.actionInProgress) {
        BOOL ownedByCurrentAction = self.deferredReturnGeneration == self.actionGeneration;
        NSString *app = ownedByCurrentAction ? self.returnAppOnNextActivation : nil;
        self.homeOnNextActivation = NO;
        self.returnAppOnNextActivation = nil;
        self.deferredReturnGeneration = 0;
        if (ownedByCurrentAction) {
            [self leaveToApp:app];
            return; // Do not present an update prompt over this action's return.
        }
    }
    // Runs every foreground; UpdateChecker enforces a per-process + 24-hour
    // persisted throttle so the API isn't hammered.
    // A shortcut run owns the screen: no update prompt over its log.
    if (!self.actionInProgress && !self.pendingActionURL) [self runUpdateCheck];
}


- (void)sceneWillResignActive:(UIScene *)scene {
    cyanide_launch_trace("sceneWillResignActive");
    scene_note_idle_active_end();
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
    filebrowser_sweep_stale_share_staging();
    g_scene_visit_user_owned = NO;
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
    // Foreground entry does not establish a new user-owned visit: an interrupted
    // shortcut can pass through real background before its deferred return is
    // consumed. Preserve that action's intent. Normal reopens after a completed
    // return have no pending intent; a newer accepted action supersedes it.
    BOOL preserveDeferredReturn = self.homeOnNextActivation &&
        self.deferredReturnGeneration != 0 &&
        self.deferredReturnGeneration == self.actionGeneration;
    if (!preserveDeferredReturn) {
        self.homeOnNextActivation = NO;
        self.returnAppOnNextActivation = nil;
        self.deferredReturnGeneration = 0;
    }
    settings_application_will_enter_foreground();
}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    cyanide_launch_trace("sceneDidEnterBackground: entry");
    // The App Switcher snapshot is taken after this returns: a finished quiet
    // run's progress screen would become the card's picture. Show Cyanide's
    // own UI there instead (a card that is being removed doesn't matter).
    if (!self.actionInProgress && self.quietCover) {
        [self hideQuietCover];
        [self.window layoutIfNeeded];
    }
    settings_application_did_enter_background();
    cyanide_launch_trace("sceneDidEnterBackground: exit");
}


@end
