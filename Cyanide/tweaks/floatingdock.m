//
//  floatingdock.m
//  Cyanide
//
//  See floatingdock.h. Ported from hxhlb/cyanide (Banana). Changed here: the
//  App Library preference this turns on in SpringBoard is turned off again
//  when the tweak is switched off (the original left it on for good).
//

#import "floatingdock.h"
#import "remote_objc.h"
#import "../LogTextView.h"

#import <stdio.h>
#import <stdlib.h>
#import <sys/sysctl.h>
#import <sys/time.h>

static uint64_t gFloatingDockSupportMethod = 0;
static uint64_t gFloatingDockSupportOriginalImp = 0;
static uint64_t gFloatingDockUtilitiesMethod = 0;
static uint64_t gFloatingDockUtilitiesOriginalImp = 0;
static uint64_t gFloatingDockSceneContext = 0;
static uint64_t gFloatingDockPreviousController = 0;
static uint64_t gFloatingDockStockContainer = 0;
static bool gFloatingDockStockContainerWasHidden = false;
static bool gFloatingDockCapturedPreviousController = false;
static uint64_t gFloatingDockDefaults = 0;
static bool gFloatingDockDefaultsCaptured = false;
static bool gFloatingDockDefaultsChanged = false;
static bool gFloatingDockApplied = false;
static uint64_t gFloatingDockControllerHint = 0;

static NSString *const kFloatingDockControllerPointerKey = @"CyanideFloatingDockControllerPointer";
static NSString *const kFloatingDockControllerPIDKey = @"CyanideFloatingDockControllerSpringBoardPID";
static NSString *const kFloatingDockControllerBootTimeKey = @"CyanideFloatingDockControllerBootTime";
// Set while SpringBoard's SBAppLibraryInDockEnabled is on because of us (it
// outlives a respring, so this does too).
static NSString *const kFloatingDockLibraryPrefSetKey = @"CyanideFloatingDockLibraryPrefSet";

static uint64_t floatingdock_boot_time(void)
{
    struct timeval bootTime = {0};
    size_t size = sizeof(bootTime);
    if (sysctlbyname("kern.boottime", &bootTime, &size, NULL, 0) != 0 || bootTime.tv_sec <= 0) {
        return 0;
    }
    return (uint64_t)bootTime.tv_sec;
}

static void floatingdock_clear_persisted_controller(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kFloatingDockControllerPointerKey];
    [defaults removeObjectForKey:kFloatingDockControllerPIDKey];
    [defaults removeObjectForKey:kFloatingDockControllerBootTimeKey];
    [defaults synchronize];
}

static uint64_t floatingdock_load_persisted_controller(bool *recordMatchesSpringBoard)
{
    if (recordMatchesSpringBoard) *recordMatchesSpringBoard = false;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSNumber *pointerValue = [defaults objectForKey:kFloatingDockControllerPointerKey];
    NSInteger storedPID = [defaults integerForKey:kFloatingDockControllerPIDKey];
    unsigned long long storedBootTime = (unsigned long long)[defaults integerForKey:kFloatingDockControllerBootTimeKey];
    if (![pointerValue isKindOfClass:[NSNumber class]] || storedPID <= 0 || storedBootTime == 0) {
        return 0;
    }

    int currentPID = remote_call_current_pid();
    uint64_t currentBootTime = floatingdock_boot_time();
    if (currentPID <= 0 || currentBootTime == 0 || storedPID != currentPID || storedBootTime != currentBootTime) {
        floatingdock_clear_persisted_controller();
        return 0;
    }

    if (recordMatchesSpringBoard) *recordMatchesSpringBoard = true;
    return [pointerValue unsignedLongLongValue];
}

static bool floatingdock_persist_controller(uint64_t controller)
{
    int currentPID = remote_call_current_pid();
    uint64_t currentBootTime = floatingdock_boot_time();
    if (!r_is_objc_ptr(controller) || currentPID <= 0 || currentBootTime == 0) return false;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSNumber *storedPointer = [defaults objectForKey:kFloatingDockControllerPointerKey];
    NSInteger storedPID = [defaults integerForKey:kFloatingDockControllerPIDKey];
    unsigned long long storedBootTime = (unsigned long long)[defaults integerForKey:kFloatingDockControllerBootTimeKey];
    if ([storedPointer isKindOfClass:[NSNumber class]] &&
        [storedPointer unsignedLongLongValue] == controller &&
        storedPID == currentPID && storedBootTime == currentBootTime) {
        return true;
    }

    uint64_t retained = r_msg2_main(controller, "retain", 0, 0, 0, 0);
    if (retained != controller) return false;

    [defaults setObject:@(controller) forKey:kFloatingDockControllerPointerKey];
    [defaults setInteger:currentPID forKey:kFloatingDockControllerPIDKey];
    [defaults setInteger:(NSInteger)currentBootTime forKey:kFloatingDockControllerBootTimeKey];
    [defaults synchronize];
    return true;
}

// What a later Cyanide launch needs to put the stock Dock back while the same
// SpringBoard runs: the controller the scene had before, whether the stock
// Dock was hidden, and the two gate methods with their own IMPs. Hex strings
// (signed IMPs don't fit a plist integer). The scene context and the stock
// Dock container are looked up again; they live as long as SpringBoard.
static NSString *const kFloatingDockSessionKey = @"CyanideFloatingDockSession";

static NSString *floatingdock_hex(uint64_t value) { return [NSString stringWithFormat:@"%llx", value]; }
static uint64_t floatingdock_unhex(id value)
{
    return [value isKindOfClass:NSString.class] ? strtoull([value UTF8String], NULL, 16) : 0;
}

static void floatingdock_save_session(void)
{
    int pid = remote_call_current_pid();
    if (pid <= 0) return;
    [NSUserDefaults.standardUserDefaults setObject:@{
        @"pid": @(pid),
        @"boot": @(floatingdock_boot_time()),
        @"previous": floatingdock_hex(gFloatingDockPreviousController),
        @"stockWasHidden": @(gFloatingDockStockContainerWasHidden),
        @"supportMethod": floatingdock_hex(gFloatingDockSupportMethod),
        @"supportImp": floatingdock_hex(gFloatingDockSupportOriginalImp),
        @"utilitiesMethod": floatingdock_hex(gFloatingDockUtilitiesMethod),
        @"utilitiesImp": floatingdock_hex(gFloatingDockUtilitiesOriginalImp),
    } forKey:kFloatingDockSessionKey];
}

static void floatingdock_clear_session(void)
{
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kFloatingDockSessionKey];
}

static uint64_t floatingdock_instance_method(uint64_t cls, uint64_t sel)
{
    if (!r_is_objc_ptr(cls) || sel == 0) return 0;
    return r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod",
                        cls, sel, 0, 0, 0, 0, 0, 0);
}

static uint64_t floatingdock_class_method(uint64_t cls, uint64_t sel)
{
    if (!r_is_objc_ptr(cls) || sel == 0) return 0;
    return r_dlsym_call(R_TIMEOUT, "class_getClassMethod",
                        cls, sel, 0, 0, 0, 0, 0, 0);
}

static void floatingdock_restore_gates(void)
{
    if (gFloatingDockUtilitiesMethod && gFloatingDockUtilitiesOriginalImp) {
        r_dlsym_call(R_TIMEOUT, "method_setImplementation",
                     gFloatingDockUtilitiesMethod, gFloatingDockUtilitiesOriginalImp,
                     0, 0, 0, 0, 0, 0);
    }
    if (gFloatingDockSupportMethod && gFloatingDockSupportOriginalImp) {
        r_dlsym_call(R_TIMEOUT, "method_setImplementation",
                     gFloatingDockSupportMethod, gFloatingDockSupportOriginalImp,
                     0, 0, 0, 0, 0, 0);
    }
}

static bool floatingdock_patch_gate(uint64_t controllerCls,
                                    const char *selector,
                                    uint64_t donorImp,
                                    uint64_t *methodOut,
                                    uint64_t *originalImpOut)
{
    uint64_t sel = r_sel(selector);
    uint64_t method = floatingdock_class_method(controllerCls, sel);
    if (!sel || !method) {
        printf("[FLOATING-DOCK] missing class method %s\n", selector);
        return false;
    }

    uint64_t before = r_msg(controllerCls, sel, 0, 0, 0, 0);
    if (before != 0) {
        printf("[FLOATING-DOCK] %s already enabled (%llu)\n", selector, before);
        return true;
    }

    uint64_t originalImp = r_dlsym_call(R_TIMEOUT, "method_getImplementation",
                                        method, 0, 0, 0, 0, 0, 0, 0);
    if (!originalImp) return false;

    uint64_t oldImp = r_dlsym_call(R_TIMEOUT, "method_setImplementation",
                                   method, donorImp, 0, 0, 0, 0, 0, 0);
    uint64_t after = r_msg(controllerCls, sel, 0, 0, 0, 0);
    if (!oldImp || after == 0) {
        if (oldImp) {
            r_dlsym_call(R_TIMEOUT, "method_setImplementation",
                         method, originalImp, 0, 0, 0, 0, 0, 0);
        }
        printf("[FLOATING-DOCK] %s patch verification failed\n", selector);
        return false;
    }

    *methodOut = method;
    *originalImpOut = originalImp;
    printf("[FLOATING-DOCK] %s %llu -> %llu\n", selector, before, after);
    return true;
}

static uint64_t floatingdock_create_controller(uint64_t iconController, uint64_t scene)
{
    if (r_responds(iconController, "createFloatingDockControllerForWindowScene:")) {
        return r_msg2_main(iconController, "createFloatingDockControllerForWindowScene:", scene, 0, 0, 0);
    }

    if (!r_responds(scene, "homeScreenController")) return 0;
    uint64_t homeScreenController = r_msg2(scene, "homeScreenController", 0, 0, 0, 0);
    if (!r_is_objc_ptr(homeScreenController) ||
        !r_responds(homeScreenController, "createFloatingDockControllerForWindowScene:")) {
        return 0;
    }
    return r_msg2_main(homeScreenController, "createFloatingDockControllerForWindowScene:", scene, 0, 0, 0);
}

static uint64_t floatingdock_view_controller(uint64_t controller)
{
    if (!r_is_objc_ptr(controller)) return 0;

    uint64_t viewController = 0;
    if (r_responds(controller, "floatingDockViewController")) {
        viewController = r_msg2_main(controller, "floatingDockViewController", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(viewController) && r_responds(controller, "viewController")) {
        viewController = r_msg2_main(controller, "viewController", 0, 0, 0, 0);
    }
    return viewController;
}

static bool floatingdock_controller_is_reusable(uint64_t controller)
{
    if (!r_is_objc_ptr(controller)) return false;
    uint64_t controllerCls = r_class("SBFloatingDockController");
    if (!r_is_objc_ptr(controllerCls) ||
        r_msg2_main(controller, "isKindOfClass:", controllerCls, 0, 0, 0) == 0) {
        return false;
    }
    if (!r_responds(controller, "floatingDockWindow") &&
        !r_responds(controller, "registerForWindowScene:") &&
        !r_responds(controller, "presentFloatingDockIfDismissedAnimated:completionHandler:")) {
        return false;
    }

    return r_is_objc_ptr(floatingdock_view_controller(controller));
}

static uint64_t floatingdock_find_existing_controller(bool *foundFloatingDockWindow)
{
    if (foundFloatingDockWindow) *foundFloatingDockWindow = false;
    uint64_t floatingDockWindowCls = r_class("SBFloatingDockWindow");
    if (!r_is_objc_ptr(floatingDockWindowCls)) {
        printf("[FLOATING-DOCK] SBFloatingDockWindow is unavailable; skipped UI controller recovery\n");
        return 0;
    }

    uint64_t applicationCls = r_class("UIApplication");
    uint64_t application = r_is_objc_ptr(applicationCls) && r_responds(applicationCls, "sharedApplication")
        ? r_msg2_main(applicationCls, "sharedApplication", 0, 0, 0, 0) : 0;
    uint64_t windows = r_is_objc_ptr(application) && r_responds(application, "windows")
        ? r_msg2_main(application, "windows", 0, 0, 0, 0) : 0;
    uint64_t windowCount = r_is_objc_ptr(windows) && r_responds(windows, "count")
        ? r_msg2_main(windows, "count", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(windows) || windowCount == 0 || windowCount > 128) return 0;

    printf("[FLOATING-DOCK] scanning %llu SpringBoard window(s) for a reusable controller\n",
           windowCount);

    for (uint64_t index = windowCount; index > 0; index--) {
        uint64_t window = r_msg2_main(windows, "objectAtIndex:", index - 1, 0, 0, 0);
        if (!r_is_objc_ptr(window) ||
            r_msg2_main(window, "isKindOfClass:", floatingDockWindowCls, 0, 0, 0) == 0) {
            continue;
        }

        printf("[FLOATING-DOCK] found SBFloatingDockWindow at index %llu\n", index - 1);
        if (foundFloatingDockWindow) *foundFloatingDockWindow = true;
        if (!r_responds(window, "rootViewController")) return 0;

        uint64_t rootViewController = r_msg2_main(window, "rootViewController", 0, 0, 0, 0);
        if (!r_is_objc_ptr(rootViewController)) return 0;

        uint64_t delegate = r_responds(rootViewController, "delegate")
            ? r_msg2_main(rootViewController, "delegate", 0, 0, 0, 0) : 0;
        if (floatingdock_controller_is_reusable(delegate)) {
            printf("[FLOATING-DOCK] recovered reusable controller from SBFloatingDockWindow root delegate\n");
            return delegate;
        }
        printf("[FLOATING-DOCK] SBFloatingDockWindow root delegate is not a reusable controller\n");
        return 0;
    }
    return 0;
}

static uint64_t floatingdock_stock_container(uint64_t iconController)
{
    uint64_t iconManager = r_responds(iconController, "iconManager")
        ? r_msg2(iconController, "iconManager", 0, 0, 0, 0) : 0;
    uint64_t rootFolderController = r_is_objc_ptr(iconManager) && r_responds(iconManager, "rootFolderController")
        ? r_msg2(iconManager, "rootFolderController", 0, 0, 0, 0) : 0;
    uint64_t dockListView = r_is_objc_ptr(rootFolderController) && r_responds(rootFolderController, "dockListView")
        ? r_msg2_main(rootFolderController, "dockListView", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(dockListView) && r_is_objc_ptr(iconManager) && r_responds(iconManager, "dockListView")) {
        dockListView = r_msg2_main(iconManager, "dockListView", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(dockListView) && r_responds(iconController, "dockListView")) {
        dockListView = r_msg2_main(iconController, "dockListView", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(dockListView) || !r_responds(dockListView, "superview")) return 0;
    return r_msg2_main(dockListView, "superview", 0, 0, 0, 0);
}

static bool floatingdock_enable_library_pref(void)
{
    uint64_t defaultsCls = r_class("NSUserDefaults");
    if (!r_is_objc_ptr(defaultsCls) || !r_responds(defaultsCls, "standardUserDefaults")) return false;
    uint64_t defaults = r_msg2_main(defaultsCls, "standardUserDefaults", 0, 0, 0, 0);
    if (!r_is_objc_ptr(defaults) || !r_responds(defaults, "boolForKey:") ||
        !r_responds(defaults, "setBool:forKey:") || !r_responds(defaults, "synchronize")) return false;

    uint64_t key = r_nsstr_retained("SBAppLibraryInDockEnabled");
    if (!r_is_objc_ptr(key)) return false;
    bool current = r_msg2_main(defaults, "boolForKey:", key, 0, 0, 0) != 0;
    if (!gFloatingDockDefaultsCaptured) {
        gFloatingDockDefaults = defaults;
        gFloatingDockDefaultsCaptured = true;
    }
    if (!current) {
        r_msg2_main(defaults, "setBool:forKey:", 1, key, 0, 0);
        (void)r_msg2_main(defaults, "synchronize", 0, 0, 0, 0);
        current = r_msg2_main(defaults, "boolForKey:", key, 0, 0, 0) != 0;
        gFloatingDockDefaultsChanged = current;
        if (current) [NSUserDefaults.standardUserDefaults setBool:YES forKey:kFloatingDockLibraryPrefSetKey];
    }
    r_msg2(key, "release", 0, 0, 0, 0);
    if (current) printf("[FLOATING-DOCK] SBAppLibraryInDockEnabled enabled for this session\n");
    return current;
}

// Kept on across a respring (SpringBoard reads it while starting, which the
// App Library button needs when the tweak is applied again), turned off when
// the tweak is switched off. Only when it was us who turned it on.
static bool floatingdock_restore_library_pref(void)
{
    if (![NSUserDefaults.standardUserDefaults boolForKey:kFloatingDockLibraryPrefSetKey]) return true;
    uint64_t defaultsCls = r_class("NSUserDefaults");
    uint64_t defaults = r_is_objc_ptr(defaultsCls) ? r_msg2_main(defaultsCls, "standardUserDefaults", 0, 0, 0, 0) : 0;
    uint64_t key = r_is_objc_ptr(defaults) ? r_nsstr_retained("SBAppLibraryInDockEnabled") : 0;
    if (!r_is_objc_ptr(key)) return false;
    r_msg2_main(defaults, "setBool:forKey:", 0, key, 0, 0);
    (void)r_msg2_main(defaults, "synchronize", 0, 0, 0, 0);
    bool off = r_msg2_main(defaults, "boolForKey:", key, 0, 0, 0) == 0;
    r_msg2(key, "release", 0, 0, 0, 0);
    if (off) [NSUserDefaults.standardUserDefaults removeObjectForKey:kFloatingDockLibraryPrefSetKey];
    printf("[FLOATING-DOCK] SBAppLibraryInDockEnabled turned off again: %s\n", off ? "yes" : "no");
    return off;
}

static bool floatingdock_enable_library_defaults_for_controller(uint64_t controller)
{
    uint64_t dockViewController = floatingdock_view_controller(controller);
    uint64_t suggestionsViewController = r_is_objc_ptr(dockViewController) &&
        r_responds(dockViewController, "suggestionsViewController")
        ? r_msg2_main(dockViewController, "suggestionsViewController", 0, 0, 0, 0) : 0;
    uint64_t suggestionsModel = r_is_objc_ptr(suggestionsViewController) &&
        r_responds(suggestionsViewController, "suggestionsModel")
        ? r_msg2_main(suggestionsViewController, "suggestionsModel", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(suggestionsModel) && r_is_objc_ptr(dockViewController) &&
        r_responds(dockViewController, "suggestionsModel")) {
        suggestionsModel = r_msg2_main(dockViewController, "suggestionsModel", 0, 0, 0, 0);
    }

    uint64_t floatingDockDefaults = r_is_objc_ptr(suggestionsModel) &&
        r_responds(suggestionsModel, "floatingDockDefaults")
        ? r_msg2_main(suggestionsModel, "floatingDockDefaults", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(floatingDockDefaults) ||
        !r_responds(floatingDockDefaults, "appLibraryEnabled") ||
        !r_responds(floatingDockDefaults, "setAppLibraryEnabled:")) {
        printf("[FLOATING-DOCK] SBFloatingDockDefaults.appLibraryEnabled is unavailable; using preference-key fallback\n");
        return false;
    }

    bool before = r_msg2_main(floatingDockDefaults, "appLibraryEnabled", 0, 0, 0, 0) != 0;
    if (!before) {
        r_msg2_main(floatingDockDefaults, "setAppLibraryEnabled:", 1, 0, 0, 0);
    }
    bool after = r_msg2_main(floatingDockDefaults, "appLibraryEnabled", 0, 0, 0, 0) != 0;
    printf("[FLOATING-DOCK] SBFloatingDockDefaults.appLibraryEnabled %d -> %d\n",
           before ? 1 : 0, after ? 1 : 0);
    return after;
}

static uint64_t floatingdock_ensure_modal_library_controller(uint64_t iconController,
                                                             uint64_t scene,
                                                             uint64_t sceneContext,
                                                             uint64_t floatingController)
{
    uint64_t modalController = r_is_objc_ptr(sceneContext) &&
        r_responds(sceneContext, "modalLibraryController")
        ? r_msg2_main(sceneContext, "modalLibraryController", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(modalController) && r_is_objc_ptr(scene) &&
        r_responds(scene, "modalLibraryController")) {
        modalController = r_msg2_main(scene, "modalLibraryController", 0, 0, 0, 0);
    }

    if (!r_is_objc_ptr(modalController)) {
        uint64_t sceneFloatingController = r_is_objc_ptr(scene) &&
            r_responds(scene, "floatingDockController")
            ? r_msg2_main(scene, "floatingDockController", 0, 0, 0, 0) : 0;
        if (sceneFloatingController != floatingController) {
            printf("[FLOATING-DOCK] active scene has no matching Floating Dock controller; skipped modal Library creation\n");
            return 0;
        }
        if (!r_is_objc_ptr(iconController) || !r_is_objc_ptr(scene) ||
            !r_is_objc_ptr(sceneContext) ||
            !r_responds(sceneContext, "setModalLibraryController:")) {
            printf("[FLOATING-DOCK] Modal App Library creation path is unavailable\n");
            return 0;
        }

        // The popup needs its own App Library: SBHModalLibraryPresenter hides
        // the view of the one it is given when it dismisses and adds its own
        // pan gesture to it, so sharing the page's left the page broken (only
        // recents). SpringBoard's creators build one (iOS 17: passing nil;
        // iOS 18: scene only), but a second SBLibraryViewController asks for
        // the same Home gesture again and SBSystemGestureManager aborts ("we
        // already have one"). That registration is made a no-op for the
        // duration of the one call; the page keeps its gesture.
        uint64_t creator = 0;
        bool withLibraryArg = false;
        uint64_t homeScreenController = r_responds(scene, "homeScreenController")
            ? r_msg2(scene, "homeScreenController", 0, 0, 0, 0) : 0;
        if (r_responds(iconController, "createModalLibraryControllerForWindowScene:withLibraryViewController:")) {
            creator = iconController;
            withLibraryArg = true;
        } else if (r_responds(iconController, "createModalLibraryControllerForWindowScene:")) {
            creator = iconController;
        } else if (r_is_objc_ptr(homeScreenController) &&
                   r_responds(homeScreenController, "createModalLibraryControllerForWindowScene:")) {
            creator = homeScreenController;
        }
        if (!creator) {
            printf("[FLOATING-DOCK] Modal App Library creation path is unavailable\n");
            return 0;
        }

        uint64_t gestureMethod = floatingdock_instance_method(r_class("SBSystemGestureManager"),
                                                              r_sel("addGestureRecognizer:withType:"));
        uint64_t noopMethod = floatingdock_instance_method(r_class("NSObject"), r_sel("self"));
        uint64_t noopImp = noopMethod
            ? r_dlsym_call(R_TIMEOUT, "method_getImplementation", noopMethod, 0, 0, 0, 0, 0, 0, 0) : 0;
        if (!gestureMethod || !noopImp) {
            printf("[FLOATING-DOCK] gesture registration can't be paused (method=0x%llx noop=0x%llx); skipped modal Library\n",
                   gestureMethod, noopImp);
            return 0;
        }
        uint64_t gestureImp = r_dlsym_call(R_TIMEOUT, "method_setImplementation",
                                           gestureMethod, noopImp, 0, 0, 0, 0, 0, 0);
        if (!gestureImp) {
            printf("[FLOATING-DOCK] gesture registration couldn't be paused; skipped modal Library\n");
            return 0;
        }
        modalController = withLibraryArg
            ? r_msg2_main(creator, "createModalLibraryControllerForWindowScene:withLibraryViewController:", scene, 0, 0, 0)
            : r_msg2_main(creator, "createModalLibraryControllerForWindowScene:", scene, 0, 0, 0);
        uint64_t restored = r_dlsym_call(R_TIMEOUT, "method_setImplementation",
                                         gestureMethod, gestureImp, 0, 0, 0, 0, 0, 0);
        printf("[FLOATING-DOCK] gesture registration restored: %s\n", restored == noopImp ? "yes" : "NOT CONFIRMED");
        if (!r_is_objc_ptr(modalController)) {
            // iOS 17's Disable App Library answers SpringBoard's "App Library
            // supported" checks with NO, which can stop this too.
            log_user("[WARN] iPad Dock: SpringBoard did not create the Dock's App Library. If Disable App Library is on, turn it off and respring.\n");
            return 0;
        }
        r_msg2_main(sceneContext, "setModalLibraryController:", modalController, 0, 0, 0);
        uint64_t ownLibrary = r_responds(modalController, "libraryViewController")
            ? r_msg2_main(modalController, "libraryViewController", 0, 0, 0, 0) : 0;
        uint64_t pageLibrary = r_responds(iconController, "overlayLibraryViewController")
            ? r_msg2_main(iconController, "overlayLibraryViewController", 0, 0, 0, 0) : 0;
        printf("[FLOATING-DOCK] created modal Library controller=0x%llx with its own libraryVC=0x%llx (page's: 0x%llx)\n",
               modalController, ownLibrary, pageLibrary);
    } else {
        printf("[FLOATING-DOCK] reused modal Library controller=0x%llx\n", modalController);
    }

    uint64_t dockViewController = floatingdock_view_controller(floatingController);
    uint64_t libraryViewController = r_responds(modalController, "libraryViewController")
        ? r_msg2_main(modalController, "libraryViewController", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(dockViewController) && r_is_objc_ptr(libraryViewController) &&
        r_responds(dockViewController, "configureForPresentingLibraryViewController:")) {
        r_msg2_main(dockViewController, "configureForPresentingLibraryViewController:",
                    libraryViewController, 0, 0, 0);
    }
    uint64_t presenter = r_is_objc_ptr(dockViewController) &&
        r_responds(dockViewController, "libraryPresenter")
        ? r_msg2_main(dockViewController, "libraryPresenter", 0, 0, 0, 0) : 0;
    printf("[FLOATING-DOCK] modal Library wiring libraryVC=0x%llx presenter=0x%llx\n",
           libraryViewController, presenter);
    return r_is_objc_ptr(libraryViewController) && r_is_objc_ptr(presenter)
        ? modalController : 0;
}

static void floatingdock_refresh_library_pod(uint64_t controller)
{
    uint64_t dockViewController = floatingdock_view_controller(controller);
    if (!r_is_objc_ptr(dockViewController)) return;

    if (r_responds(dockViewController, "setLibraryPodIconEnabled:")) {
        r_msg2_main(dockViewController, "setLibraryPodIconEnabled:", 1, 0, 0, 0);
    }
    if (r_responds(dockViewController, "_rebuildLibraryPodIcon")) {
        r_msg2_main(dockViewController, "_rebuildLibraryPodIcon", 0, 0, 0, 0);
    }
    if (r_responds(dockViewController, "setLibraryPodIconVisible:")) {
        r_msg2_main(dockViewController, "setLibraryPodIconVisible:", 1, 0, 0, 0);
    }
    r_settle_us(50000);

    uint64_t podIconView = r_responds(dockViewController, "libraryPodIconView")
        ? r_msg2_main(dockViewController, "libraryPodIconView", 0, 0, 0, 0) : 0;
    uint64_t libraryIconViewController = r_is_objc_ptr(podIconView) &&
        r_responds(dockViewController, "customImageViewControllerForIconView:")
        ? r_msg2_main(dockViewController, "customImageViewControllerForIconView:", podIconView, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(libraryIconViewController)) {
        printf("[FLOATING-DOCK] Library pod view controller is unavailable after rebuild\n");
        return;
    }

    uint64_t dataSource = r_responds(libraryIconViewController, "libraryDataSource")
        ? r_msg2_main(libraryIconViewController, "libraryDataSource", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(dataSource) && r_responds(dataSource, "reloadData")) {
        r_msg2_main(dataSource, "reloadData", 0, 0, 0, 0);
    }
    if (r_responds(libraryIconViewController, "_reloadCategoryViewsForDataSourceChangeAnimated:")) {
        r_msg2_main(libraryIconViewController,
                    "_reloadCategoryViewsForDataSourceChangeAnimated:", 0, 0, 0, 0);
    }
    r_settle_us(50000);

    uint64_t categoryCount = r_is_objc_ptr(dataSource) &&
        r_responds(dataSource, "categoryIdentifiersCount")
        ? r_msg2_main(dataSource, "categoryIdentifiersCount", 0, 0, 0, 0) : 0;
    uint64_t stackView = r_responds(libraryIconViewController, "categoryStackView")
        ? r_msg2_main(libraryIconViewController, "categoryStackView", 0, 0, 0, 0) : 0;
    uint64_t innerIcons = r_is_objc_ptr(stackView) && r_responds(stackView, "innerIcons")
        ? r_msg2_main(stackView, "innerIcons", 0, 0, 0, 0) : 0;
    uint64_t innerIconCount = r_is_objc_ptr(innerIcons) && r_responds(innerIcons, "count")
        ? r_msg2_main(innerIcons, "count", 0, 0, 0, 0) : 0;
    printf("[FLOATING-DOCK] Library pod reload categoryIdentifiers=%llu innerIcons=%llu\n",
           categoryCount, innerIconCount);
}

static bool floatingdock_recover_session(void);

bool floatingdock_apply_in_session(void)
{
    if (gFloatingDockApplied) return true;
    // Still set up in this SpringBoard by an earlier Cyanide launch: keep it
    // (and its saved "before" state) rather than capturing the iPad Dock
    // itself as the controller to go back to.
    if (floatingdock_recover_session()) {
        log_user("[FLOATING-DOCK] The iPad Dock is still active in SpringBoard.\n");
        return true;
    }

    uint64_t controllerCls = r_class("SBFloatingDockController");
    uint64_t coverSheetCls = r_class("SBCoverSheetPrimarySlidingViewController");
    uint64_t workspaceCls = r_class("SBMainWorkspace");
    uint64_t iconControllerCls = r_class("SBIconController");
    uint64_t donorMethod = floatingdock_instance_method(coverSheetCls, r_sel("_canShowWhileLocked"));
    uint64_t donorImp = donorMethod
        ? r_dlsym_call(R_TIMEOUT, "method_getImplementation", donorMethod, 0, 0, 0, 0, 0, 0, 0)
        : 0;

    if (!r_is_objc_ptr(controllerCls) || !r_is_objc_ptr(workspaceCls) ||
        !r_is_objc_ptr(iconControllerCls) || !donorImp) {
        log_user("[FLOATING-DOCK] Unsupported SpringBoard build: required Floating Dock classes or BOOL donor are missing. No changes were made.\n");
        return false;
    }

    uint64_t workspace = r_msg2(workspaceCls, "sharedInstance", 0, 0, 0, 0);
    uint64_t scene = r_is_objc_ptr(workspace) && r_responds(workspace, "mainWindowScene")
        ? r_msg2(workspace, "mainWindowScene", 0, 0, 0, 0) : 0;
    uint64_t iconController = r_msg2(iconControllerCls, "sharedInstance", 0, 0, 0, 0);
    uint64_t sceneDelegate = r_is_objc_ptr(scene) && r_responds(scene, "delegate")
        ? r_msg2(scene, "delegate", 0, 0, 0, 0) : 0;
    uint64_t sceneContext = r_is_objc_ptr(sceneDelegate) && r_responds(sceneDelegate, "_sbWindowSceneContext")
        ? r_msg2(sceneDelegate, "_sbWindowSceneContext", 0, 0, 0, 0) : 0;

    if (!r_is_objc_ptr(workspace) || !r_is_objc_ptr(scene) || !r_is_objc_ptr(iconController) ||
        !r_is_objc_ptr(sceneContext) || !r_responds(sceneContext, "setFloatingDockController:")) {
        log_user("[FLOATING-DOCK] Unsupported SpringBoard build: the active scene cannot host a Floating Dock controller. No changes were made.\n");
        return false;
    }

    uint64_t stockContainer = floatingdock_stock_container(iconController);
    if (!r_is_objc_ptr(stockContainer) || !r_responds(stockContainer, "setHidden:")) {
        log_user("[FLOATING-DOCK] Could not locate the stock Dock container. No changes were made.\n");
        return false;
    }

    if (!floatingdock_patch_gate(controllerCls, "isFloatingDockSupported", donorImp,
                                 &gFloatingDockSupportMethod, &gFloatingDockSupportOriginalImp)) {
        floatingdock_restore_gates();
        floatingdock_forget_remote_state();
        log_user("[FLOATING-DOCK] Could not enable the primary Floating Dock capability gate. No changes were made.\n");
        return false;
    }

    uint64_t utilitiesSel = r_sel("isFloatingDockUtilitiesSupported");
    if (utilitiesSel && floatingdock_class_method(controllerCls, utilitiesSel)) {
        if (!floatingdock_patch_gate(controllerCls, "isFloatingDockUtilitiesSupported", donorImp,
                                     &gFloatingDockUtilitiesMethod, &gFloatingDockUtilitiesOriginalImp)) {
            floatingdock_restore_gates();
            floatingdock_forget_remote_state();
            log_user("[FLOATING-DOCK] Could not enable the optional Floating Dock utilities gate. No changes were made.\n");
            return false;
        }
    } else {
        printf("[FLOATING-DOCK] optional gate isFloatingDockUtilitiesSupported is unavailable; continuing.\n");
    }

    if (!floatingdock_enable_library_pref()) {
        floatingdock_restore_gates();
        floatingdock_forget_remote_state();
        log_user("[FLOATING-DOCK] Could not enable App Library for the current Floating Dock session. No changes were made.\n");
        return false;
    }

    uint64_t existingController = r_responds(sceneContext, "floatingDockController")
        ? r_msg2_main(sceneContext, "floatingDockController", 0, 0, 0, 0) : 0;

    uint64_t reusableController = 0;
    bool foundFloatingDockWindow = false;
    bool persistedRecordMatchesSpringBoard = false;
    uint64_t persistedController = floatingdock_load_persisted_controller(&persistedRecordMatchesSpringBoard);
    if (floatingdock_controller_is_reusable(gFloatingDockControllerHint)) {
        reusableController = gFloatingDockControllerHint;
        printf("[FLOATING-DOCK] validated in-memory reusable controller hint\n");
    } else {
        gFloatingDockControllerHint = 0;
        if (persistedRecordMatchesSpringBoard) {
            if (floatingdock_controller_is_reusable(persistedController)) {
                reusableController = persistedController;
                printf("[FLOATING-DOCK] validated persisted controller for SpringBoard pid=%d\n",
                       remote_call_current_pid());
            } else {
                (void)floatingdock_restore_library_pref();
                floatingdock_restore_gates();
                floatingdock_forget_remote_state();
                log_user("[FLOATING-DOCK] The saved controller belongs to the current SpringBoard process but failed validation. Skipped duplicate creation.\n");
                return false;
            }
        } else if (floatingdock_controller_is_reusable(existingController)) {
            reusableController = existingController;
            printf("[FLOATING-DOCK] found reusable controller in the active scene context\n");
        } else {
            reusableController = floatingdock_find_existing_controller(&foundFloatingDockWindow);
        }
    }

    if (!r_is_objc_ptr(reusableController) && foundFloatingDockWindow) {
        (void)floatingdock_restore_library_pref();
        floatingdock_restore_gates();
        floatingdock_forget_remote_state();
        log_user("[FLOATING-DOCK] An existing Floating Dock window was found, but its controller could not be safely recovered. Skipped duplicate creation.\n");
        return false;
    }

    if (!gFloatingDockCapturedPreviousController) {
        gFloatingDockPreviousController = existingController;
        gFloatingDockCapturedPreviousController = true;
        gFloatingDockSceneContext = sceneContext;
        gFloatingDockStockContainer = stockContainer;
        gFloatingDockStockContainerWasHidden = r_msg2_main(stockContainer, "isHidden", 0, 0, 0, 0) != 0;
    }

    if (r_is_objc_ptr(reusableController)) {
        bool libraryDefaultsReady = floatingdock_enable_library_defaults_for_controller(reusableController);
        r_msg2_main(sceneContext, "setFloatingDockController:", reusableController, 0, 0, 0);
        r_settle_us(100000);
        if (!libraryDefaultsReady) {
            (void)floatingdock_enable_library_defaults_for_controller(reusableController);
        }
        (void)floatingdock_ensure_modal_library_controller(iconController, scene,
                                                           sceneContext, reusableController);
        r_msg2_main(stockContainer, "setHidden:", 1, 0, 0, 0);
        r_msg2_main(stockContainer, "setNeedsLayout", 0, 0, 0, 0);
        floatingdock_refresh_library_pod(reusableController);
        gFloatingDockApplied = true;
        gFloatingDockControllerHint = reusableController;
        floatingdock_save_session();

        printf("[FLOATING-DOCK] reused controller=0x%llx sceneContext=0x%llx stockContainer=0x%llx\n",
               reusableController, sceneContext, stockContainer);
        log_user("[FLOATING-DOCK] Reused the existing iPad Dock controller; skipped duplicate creation.\n");
        return true;
    }

    uint64_t floatingController = floatingdock_create_controller(iconController, scene);
    if (!r_is_objc_ptr(floatingController)) {
        if (r_is_objc_ptr(existingController)) {
            r_msg2_main(sceneContext, "setFloatingDockController:", existingController, 0, 0, 0);
        }
        (void)floatingdock_restore_library_pref();
        floatingdock_restore_gates();
        floatingdock_forget_remote_state();
        log_user("[FLOATING-DOCK] SpringBoard did not create a Floating Dock controller; restored the previous controller and capability gates.\n");
        return false;
    }

    if (!floatingdock_persist_controller(floatingController)) {
        log_user("[FLOATING-DOCK] Warning: the new controller could not be retained and saved; do not reapply after restarting Cyanide without respringing.\n");
    }

    bool libraryDefaultsReady = floatingdock_enable_library_defaults_for_controller(floatingController);
    r_msg2_main(sceneContext, "setFloatingDockController:", floatingController, 0, 0, 0);
    r_settle_us(100000);
    if (!libraryDefaultsReady) {
        (void)floatingdock_enable_library_defaults_for_controller(floatingController);
    }
    (void)floatingdock_ensure_modal_library_controller(iconController, scene,
                                                       sceneContext, floatingController);
    r_msg2_main(stockContainer, "setHidden:", 1, 0, 0, 0);
    r_msg2_main(stockContainer, "setNeedsLayout", 0, 0, 0, 0);
    floatingdock_refresh_library_pod(floatingController);
    gFloatingDockApplied = true;
    gFloatingDockControllerHint = floatingController;
    floatingdock_save_session();

    printf("[FLOATING-DOCK] created controller=0x%llx sceneContext=0x%llx stockContainer=0x%llx\n",
           floatingController, sceneContext, stockContainer);
    log_user("[FLOATING-DOCK] iPad Dock created in the active scene. Clean Up restores the stock Dock for this session.\n");
    return true;
}

bool floatingdock_relayout_in_session(void)
{
    if (!gFloatingDockApplied || !r_is_objc_ptr(gFloatingDockControllerHint)) return false;
    uint64_t dockViewController = floatingdock_view_controller(gFloatingDockControllerHint);
    if (!r_is_objc_ptr(dockViewController)) return false;
    uint64_t userList = r_responds(dockViewController, "userIconListView")
        ? r_msg2_main(dockViewController, "userIconListView", 0, 0, 0, 0) : 0;
    uint64_t model = r_is_objc_ptr(userList) && r_responds(userList, "model")
        ? r_msg2_main(userList, "model", 0, 0, 0, 0) : 0;
    uint64_t icons = r_is_objc_ptr(model) && r_responds(model, "icons")
        ? r_msg2_main(model, "icons", 0, 0, 0, 0) : 0;
    uint64_t count = r_is_objc_ptr(icons) ? r_msg2_main(icons, "count", 0, 0, 0, 0) : 0;
    bool resized = false, laidOut = false;
    if (r_responds(dockViewController, "_resizeDockForChangedNumberOfIconsAnimated:")) {
        r_msg2_main(dockViewController, "_resizeDockForChangedNumberOfIconsAnimated:", 0, 0, 0, 0);
        resized = true;
    }
    if (r_responds(dockViewController, "layoutUserControlledIconListsWithAnimationType:forceRelayout:")) {
        r_msg2_main(dockViewController, "layoutUserControlledIconListsWithAnimationType:forceRelayout:", 0, 1, 0, 0);
        laidOut = true;
    }
    uint64_t dockView = r_responds(dockViewController, "view")
        ? r_msg2_main(dockViewController, "view", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(dockView)) {
        r_msg2_main(dockView, "setNeedsLayout", 0, 0, 0, 0);
        r_msg2_main(dockView, "layoutIfNeeded", 0, 0, 0, 0);
    }
    printf("[FLOATING-DOCK] relayout for %llu Dock icon(s): resize=%d layout=%d\n", count, resized, laidOut);
    return resized || laidOut;
}

// Applied by an earlier Cyanide launch: take the saved record when it belongs
// to this SpringBoard and look the scene context and stock Dock up again.
static bool floatingdock_recover_session(void)
{
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kFloatingDockSessionKey];
    int pid = remote_call_current_pid();
    if (!saved || pid <= 0 || [saved[@"pid"] intValue] != pid ||
        [saved[@"boot"] unsignedLongLongValue] != floatingdock_boot_time()) {
        if (saved && pid > 0) floatingdock_clear_session();   // an earlier SpringBoard's
        return false;
    }

    uint64_t workspaceCls = r_class("SBMainWorkspace");
    uint64_t iconControllerCls = r_class("SBIconController");
    uint64_t workspace = r_is_objc_ptr(workspaceCls) ? r_msg2(workspaceCls, "sharedInstance", 0, 0, 0, 0) : 0;
    uint64_t scene = r_is_objc_ptr(workspace) && r_responds(workspace, "mainWindowScene")
        ? r_msg2(workspace, "mainWindowScene", 0, 0, 0, 0) : 0;
    uint64_t sceneDelegate = r_is_objc_ptr(scene) && r_responds(scene, "delegate")
        ? r_msg2(scene, "delegate", 0, 0, 0, 0) : 0;
    uint64_t sceneContext = r_is_objc_ptr(sceneDelegate) && r_responds(sceneDelegate, "_sbWindowSceneContext")
        ? r_msg2(sceneDelegate, "_sbWindowSceneContext", 0, 0, 0, 0) : 0;
    uint64_t iconController = r_is_objc_ptr(iconControllerCls)
        ? r_msg2(iconControllerCls, "sharedInstance", 0, 0, 0, 0) : 0;
    uint64_t stockContainer = r_is_objc_ptr(iconController) ? floatingdock_stock_container(iconController) : 0;
    if (!r_is_objc_ptr(sceneContext) || !r_is_objc_ptr(stockContainer)) {
        printf("[FLOATING-DOCK] recover: scene context 0x%llx / stock Dock 0x%llx not found\n",
               sceneContext, stockContainer);
        return false;
    }

    // The previous controller is used only if its memory still holds a
    // Floating Dock controller (it may have been released since): read, never
    // messaged, before that check.
    uint64_t previous = floatingdock_unhex(saved[@"previous"]);
    if (previous) {
        uint64_t cls = r_class("SBFloatingDockController");
        uint64_t isa = 0;
        bool alive = r_is_objc_ptr(previous) && remote_read(previous, &isa, sizeof(isa)) &&
                     (isa == cls || (isa & 0x0000000ffffffff8ULL) == cls || (isa & 0x007ffffffffffff8ULL) == cls);
        if (!alive) previous = 0;
    }

    gFloatingDockSceneContext = sceneContext;
    gFloatingDockStockContainer = stockContainer;
    gFloatingDockStockContainerWasHidden = [saved[@"stockWasHidden"] boolValue];
    gFloatingDockPreviousController = previous;
    gFloatingDockCapturedPreviousController = true;
    gFloatingDockSupportMethod = floatingdock_unhex(saved[@"supportMethod"]);
    gFloatingDockSupportOriginalImp = floatingdock_unhex(saved[@"supportImp"]);
    gFloatingDockUtilitiesMethod = floatingdock_unhex(saved[@"utilitiesMethod"]);
    gFloatingDockUtilitiesOriginalImp = floatingdock_unhex(saved[@"utilitiesImp"]);
    gFloatingDockControllerHint = r_responds(sceneContext, "floatingDockController")
        ? r_msg2_main(sceneContext, "floatingDockController", 0, 0, 0, 0) : 0;
    gFloatingDockApplied = true;
    printf("[FLOATING-DOCK] recovered the session saved for SpringBoard pid=%d\n", pid);
    return true;
}

bool floatingdock_stop_in_session(void)
{
    if (!gFloatingDockApplied && !floatingdock_recover_session()) {
        log_user("[FLOATING-DOCK] The iPad Dock was set up by an earlier SpringBoard session or build; respring to bring back the stock Dock.\n");
        return false;
    }

    uint64_t reusableControllerHint = gFloatingDockControllerHint;
    bool contextRestored = false;
    if (r_is_objc_ptr(gFloatingDockSceneContext) &&
        r_responds(gFloatingDockSceneContext, "setFloatingDockController:")) {
        r_msg2_main(gFloatingDockSceneContext, "setFloatingDockController:",
                    gFloatingDockPreviousController, 0, 0, 0);
        r_settle_us(100000);
        contextRestored = true;
    }

    bool stockRestored = false;
    if (r_is_objc_ptr(gFloatingDockStockContainer) &&
        r_responds(gFloatingDockStockContainer, "setHidden:")) {
        r_msg2_main(gFloatingDockStockContainer, "setHidden:",
                    gFloatingDockStockContainerWasHidden ? 1 : 0, 0, 0, 0);
        r_msg2_main(gFloatingDockStockContainer, "setNeedsLayout", 0, 0, 0, 0);
        stockRestored = true;
    }

    bool defaultsRestored = floatingdock_restore_library_pref();
    floatingdock_restore_gates();
    bool ok = contextRestored && stockRestored && defaultsRestored;
    if (ok) {
        floatingdock_clear_session();
        log_user("[FLOATING-DOCK] Restored the stock Dock; retained the existing Floating Dock controller for safe reuse.\n");
    } else {
        log_user("[FLOATING-DOCK] Partial cleanup; respring restores the stock Dock.\n");
    }
    floatingdock_forget_remote_state();
    if (r_is_objc_ptr(reusableControllerHint)) {
        gFloatingDockControllerHint = reusableControllerHint;
    }
    return ok;
}

void floatingdock_forget_remote_state(void)
{
    gFloatingDockSupportMethod = 0;
    gFloatingDockSupportOriginalImp = 0;
    gFloatingDockUtilitiesMethod = 0;
    gFloatingDockUtilitiesOriginalImp = 0;
    gFloatingDockSceneContext = 0;
    gFloatingDockPreviousController = 0;
    gFloatingDockStockContainer = 0;
    gFloatingDockStockContainerWasHidden = false;
    gFloatingDockCapturedPreviousController = false;
    gFloatingDockDefaults = 0;
    gFloatingDockDefaultsCaptured = false;
    gFloatingDockDefaultsChanged = false;
    gFloatingDockApplied = false;
    gFloatingDockControllerHint = 0;
}
