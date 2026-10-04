//
//  SceneDelegate.m
//  Cyanide
//
//  Created by seo on 3/24/26.
//

#import "SceneDelegate.h"
#import "AppDelegate.h"            // round 31: cyanide_launch_trace
#import "SettingsViewController.h"
#import "UpdateChecker.h"
#import "TaskRop/Exception.h"   // round 30: excport lifecycle gate (early close)

@interface SceneDelegate ()
@property (nonatomic, assign) BOOL didSelectInitialTab;

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
    cyanide_launch_trace("scene willConnect: exit");
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
    // Runs every foreground; UpdateChecker enforces a per-process + 24-hour
    // persisted throttle so the API isn't hammered.
    [self runUpdateCheck];
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
    settings_application_will_enter_foreground();
}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    cyanide_launch_trace("sceneDidEnterBackground: entry");
    settings_application_did_enter_background();
    cyanide_launch_trace("sceneDidEnterBackground: exit");
}


@end
