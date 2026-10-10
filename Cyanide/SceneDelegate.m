//
//  SceneDelegate.m
//  Cyanide
//
//  Created by seo on 3/24/26.
//

#import "SceneDelegate.h"
#import "AppDelegate.h"            // round 31: cyanide_launch_trace
#import "SettingsViewController.h"
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
@property (nonatomic, strong) UIView *quietCover;   // shown during a quiet shortcut run
@property (nonatomic, strong) UIImageView *quietIcon;
@property (nonatomic, strong) UILabel *quietStatus;
@property (nonatomic, strong) UIProgressView *quietProgress;

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
- (void)showQuietCover {
    if (self.quietCover) return;
    UIView *cover = [[UIView alloc] initWithFrame:self.window.bounds];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.backgroundColor = UIColor.systemBackgroundColor;

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:56 weight:UIImageSymbolWeightRegular];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"location.fill" withConfiguration:cfg]];
    icon.tintColor = UIColor.systemBlueColor;
    icon.contentMode = UIViewContentModeCenter;

    UILabel *title = [UILabel new];
    title.text = @"Location Services";
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    title.textColor = UIColor.labelColor;

    UILabel *status = [UILabel new];
    status.text = @"Getting ready…";
    status.font = [UIFont systemFontOfSize:15];
    status.textColor = UIColor.secondaryLabelColor;

    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.progress = 0.05f;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [bar.widthAnchor constraintEqualToConstant:220].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, title, status, bar ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    [stack setCustomSpacing:20 afterView:icon];
    [stack setCustomSpacing:18 afterView:status];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cover addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor constant:-30],
    ]];
    [self.window addSubview:cover];
    // A gentle pulse while it works.
    if (@available(iOS 17.0, *)) [icon addSymbolEffect:[NSSymbolPulseEffect effect]];

    self.quietCover = cover;
    self.quietIcon = icon;
    self.quietStatus = status;
    self.quietProgress = bar;
}

// Progress from the running action: move the bar to `fraction` (animated
// over `over` seconds, e.g. the remaining activation window) and show `step`.
- (void)updateQuietProgress:(float)fraction step:(NSString *)step over:(NSTimeInterval)over {
    if (!self.quietCover) return;
    BOOL done = fraction >= 1.0f;
    self.quietStatus.text = done ? step : [step stringByAppendingString:@"…"];
    UIProgressView *bar = self.quietProgress;
    if (fraction > bar.progress) {
        [bar layoutIfNeeded];
        [UIView animateWithDuration:MAX(over, 0.15) delay:0
                            options:UIViewAnimationOptionCurveLinear | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            [bar setProgress:fraction animated:NO];
            [bar layoutIfNeeded];
        } completion:nil];
    }
    if (done) {
        if (@available(iOS 17.0, *)) [self.quietIcon removeAllSymbolEffects];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:56 weight:UIImageSymbolWeightRegular];
        self.quietIcon.image = [UIImage systemImageNamed:@"checkmark.circle.fill" withConfiguration:cfg];
        self.quietIcon.tintColor = UIColor.systemGreenColor;
    }
}

- (void)hideQuietCover {
    [self.quietCover removeFromSuperview];
    self.quietCover = nil;
    self.quietIcon = nil;
    self.quietStatus = nil;
    self.quietProgress = nil;
}

// A quiet shortcut link arriving before the scene is active: cover the
// window right away, so Cyanide's normal UI doesn't flash first.
- (void)coverEarlyForURL:(NSURL *)url {
    if (!url || ![url.host.lowercaseString isEqualToString:@"location-services"]) return;
    int desired; BOOL keep, showLog; NSString *err = nil;
    if (scene_parse_location_url(url, &desired, &keep, &showLog, &err) && !showLog) [self showQuietCover];
}

// cyanide://location-services/toggle | /on | /off. Runs only that action.
//  - Default (quiet): a plain cover instead of any UI; on success Cyanide
//    returns to the Home Screen as soon as its SpringBoard work is finished
//    (and SpringBoard then removes the switcher card unless keepInSwitcher=1).
//    On failure the cover goes away and an alert explains why.
//  - log=1: the activity log is shown, with a short pause on the result.
- (void)handleActionURL:(NSURL *)url {
    if (![url.host.lowercaseString isEqualToString:@"location-services"]) {
        NSLog(@"[URL] unhandled %@", url);
        return;
    }
    int desired = -1;
    BOOL keepCard = NO, showLog = NO;
    NSString *parseError = nil;
    if (!scene_parse_location_url(url, &desired, &keepCard, &showLog, &parseError)) {
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
        observer = [NSNotificationCenter.defaultCenter
            addObserverForName:kSettingsActionsDidCompleteNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            if (!resultShownNs) resultShownNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        }];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_block_t run = ^{
        SettingsProgressBlock progress = showLog ? nil : ^(float fraction, NSString *step, NSTimeInterval over) {
            typeof(self) me = weakSelf;
            if (me && generation == me.actionGeneration) [me updateQuietProgress:fraction step:step over:over];
        };
        settings_location_services_set_async(desired, !keepCard, progress, ^(BOOL ok, NSString *message,
                                                                    NSTimeInterval resultAge) {
            if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
            typeof(self) me = weakSelf;
            if (!me || generation != me.actionGeneration) return;   // a newer run owns the screen
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
    if (showLog) {
        [self presentActivityLogThen:run];
    } else {
        [self showQuietCover];
        run();
    }
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
