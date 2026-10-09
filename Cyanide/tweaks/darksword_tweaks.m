//
//  darksword_tweaks.m
//

#import "darksword_tweaks.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import <Foundation/Foundation.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import "../LogTextView.h"

static int ds_ios_major_version(void)
{
    return (int)[[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
}

static uint64_t ds_try_msg0(uint64_t obj, const char *selName)
{
    if (!r_is_objc_ptr(obj) || !r_responds(obj, selName)) return 0;
    return r_msg2(obj, selName, 0, 0, 0, 0);
}

static uint64_t ds_object_class(uint64_t obj)
{
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t cls = r_dlsym_call(R_TIMEOUT, "object_getClass", obj, 0, 0, 0, 0, 0, 0, 0);
    if (r_is_objc_ptr(cls)) return cls;
    return ds_try_msg0(obj, "class");
}

// Diagnostics only. Knowing which concrete classes SpringBoard hands back is
// the difference between fixing the iOS 17 path and guessing at it.
static void ds_read_class_name(uint64_t obj, char *out, size_t outLen)
{
    if (!out || outLen == 0) return;
    snprintf(out, outLen, "%s", "<none>");
    if (!r_is_objc_ptr(obj)) return;
    uint64_t cls = r_dlsym_call(R_TIMEOUT, "object_getClass", obj, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(cls)) return;
    uint64_t name = r_dlsym_call(R_TIMEOUT, "class_getName", cls, 0, 0, 0, 0, 0, 0, 0);
    if (!name) return;
    uint64_t heap = r_dlsym_call(R_TIMEOUT, "strdup", name, 0, 0, 0, 0, 0, 0, 0);
    if (!heap) return;
    if (remote_read(heap, out, outLen - 1)) out[outLen - 1] = '\0';
    r_free(heap);
}

static void ds_log_target(const char *label, uint64_t obj)
{
    char cls[96];
    ds_read_class_name(obj, cls, sizeof(cls));
    printf("[DST:APPLIB]   %-24s obj=0x%llx class=%s\n", label, obj, cls);
}

static uint64_t ds_resolve_ivar_target(uint64_t obj, uint64_t cls, const char *name)
{
    if (!r_is_objc_ptr(obj) || !r_is_objc_ptr(cls) || !name) return 0;

    uint64_t nameMem = r_alloc_str(name);
    if (!nameMem) return 0;
    uint64_t ivar = r_dlsym_call(100, "class_getInstanceVariable",
                                 cls, nameMem, 0, 0, 0, 0, 0, 0);
    r_free(nameMem);
    if (!ivar) {
        printf("[DST]   %s: ivar not found\n", name);
        return 0;
    }

    uint64_t offset = r_dlsym_call(100, "ivar_getOffset",
                                   ivar, 0, 0, 0, 0, 0, 0, 0);
    if (!offset) {
        printf("[DST]   %s: offset=0\n", name);
        return 0;
    }
    return obj + offset;
}

// No settle sleep after these pokes or the main-thread setters below: an ivar
// write is a plain memory write, and r_msg2_main waits for the setter to
// finish. The fixed 50 ms that used to follow each one was most of the time
// Disable Icon Fly-In, Zero Wake Animation and Zero Backlight Fade took.
static bool ds_poke_pointer_ivar(uint64_t obj, uint64_t cls, const char *name, uint64_t value)
{
    uint64_t target = ds_resolve_ivar_target(obj, cls, name);
    if (!target) return false;
    if (!remote_write(target, &value, sizeof(value))) return false;
    uint64_t readback = remote_read64(target);
    printf("[DST]   %-40s @ 0x%llx -> 0x%llx\n", name, target, readback);
    return readback == value;
}

static bool ds_poke_bool_ivar(uint64_t obj, uint64_t cls, const char *name, bool value)
{
    if (!r_is_objc_ptr(obj) || !r_is_objc_ptr(cls) || !name) return false;

    uint64_t nameMem = r_alloc_str(name);
    uint64_t ivar = nameMem
        ? r_dlsym_call(100, "class_getInstanceVariable",
                       cls, nameMem, 0, 0, 0, 0, 0, 0)
        : 0;
    r_free(nameMem);
    if (!ivar) return false;

    // Only write actual Objective-C BOOL/bool ivars. This avoids treating a
    // similarly named object or integer field as a one-byte flag.
    uint64_t types = r_dlsym_call(100, "ivar_getTypeEncoding",
                                  ivar, 0, 0, 0, 0, 0, 0, 0);
    uint64_t typesCopy = types
        ? r_dlsym_call(100, "strdup", types, 0, 0, 0, 0, 0, 0, 0)
        : 0;
    char encoding[8] = {0};
    bool encodingOK = typesCopy &&
        remote_read(typesCopy, encoding, sizeof(encoding) - 1);
    r_free(typesCopy);
    if (!encodingOK ||
        (encoding[0] != 'B' && encoding[0] != 'c' && encoding[0] != 'C')) {
        return false;
    }

    uint64_t offset = r_dlsym_call(100, "ivar_getOffset",
                                   ivar, 0, 0, 0, 0, 0, 0, 0);
    if (!offset) return false;
    uint8_t byte = value ? 1 : 0;
    uint64_t target = obj + offset;
    if (!remote_write(target, &byte, sizeof(byte))) return false;
    uint8_t readback = 0xff;
    if (!remote_read(target, &readback, sizeof(readback))) return false;
    printf("[DST:APPLIB]   %s @ 0x%llx -> %u\n",
           name, target, (unsigned)readback);
    return readback == byte;
}

static bool ds_disable_app_library_flags_on_target(uint64_t obj, const char *tag)
{
    if (!r_is_objc_ptr(obj)) return false;

    struct {
        const char *setter;
        const char *getter;
    } properties[] = {
        { "setAppLibraryAllowed:", "isAppLibraryAllowed" },
        { "setAllowsAppLibrary:", "allowsAppLibrary" },
        { "setAppLibraryEnabled:", "isAppLibraryEnabled" },
        { "setLibraryEnabled:", "isLibraryEnabled" },
        { "setShowsAppLibrary:", "showsAppLibrary" },
    };

    bool changed = false;
    for (size_t i = 0; i < sizeof(properties) / sizeof(properties[0]); i++) {
        if (!r_responds(obj, properties[i].setter)) {
            printf("[DST:APPLIB] %s %s absent\n", tag, properties[i].setter);
            continue;
        }
        r_msg2_main(obj, properties[i].setter, 0, 0, 0, 0);
        bool verified = !r_responds(obj, properties[i].getter) ||
                        r_msg2_main(obj, properties[i].getter, 0, 0, 0, 0) == 0;
        printf("[DST:APPLIB] %s via %s verified=%d\n",
               tag, properties[i].setter, verified);
        changed |= verified;
    }

    uint64_t cls = ds_object_class(obj);
    const char *ivars[] = {
        "_canPresentOverscrollLibraryForPageTransition",
        "_appLibraryAllowed",
        "_allowsAppLibrary",
        "_appLibraryEnabled",
        "_libraryEnabled",
        "_showsAppLibrary",
        NULL,
    };
    for (int i = 0; ivars[i]; i++) {
        if (!ds_poke_bool_ivar(obj, cls, ivars[i], false)) {
            printf("[DST:APPLIB] %s ivar %s unresolved\n", tag, ivars[i]);
        } else {
            changed = true;
        }
    }
    return changed;
}

static bool ds_set_trailing_controllers(uint64_t obj, uint64_t value, const char *tag)
{
    if (!r_is_objc_ptr(obj)) return false;

    const char *setters[] = {
        "setTrailingCustomViewControllers:",
        "_setTrailingCustomViewControllers:",
    };
    for (size_t i = 0; i < sizeof(setters) / sizeof(setters[0]); i++) {
        if (!r_responds(obj, setters[i])) continue;
        r_msg2_main(obj, setters[i], value, 0, 0, 0);
        printf("[DST:APPLIB] %s via %s\n", tag, setters[i]);
        return true;
    }

    uint64_t cls = ds_object_class(obj);
    return ds_poke_pointer_ivar(obj, cls, "_trailingCustomViewControllers", value);
}

static bool ds_set_trailing_controller(uint64_t obj, uint64_t value, const char *tag)
{
    if (!r_is_objc_ptr(obj)) return false;

    const char *setters[] = {
        "setTrailingCustomViewController:",
        "_setTrailingCustomViewController:",
    };
    for (size_t i = 0; i < sizeof(setters) / sizeof(setters[0]); i++) {
        if (!r_responds(obj, setters[i])) continue;
        r_msg2_main(obj, setters[i], value, 0, 0, 0);
        printf("[DST:APPLIB] %s via %s\n", tag, setters[i]);
        return true;
    }

    // No ivar fallback. Writing _trailingCustomViewController directly skips the
    // setter's teardown, so it cannot remove a page that has already been built
    // -- proven on iOS 17, where the poke "succeeded" on both the root folder
    // controller and its view while the App Library stayed on screen -- and it
    // overwrites a strong reference without releasing it. The manager's real
    // setter above is what does the work; the gate hooks handle iOS 17.
    printf("[DST:APPLIB] %s has no trailing-controller setter; skipped\n", tag);
    return false;
}

static bool ds_clear_overlay_library_controller(uint64_t mgr)
{
    if (!r_is_objc_ptr(mgr)) return false;

    if (r_responds(mgr, "setOverlayLibraryViewController:")) {
        r_msg2_main(mgr, "setOverlayLibraryViewController:", 0, 0, 0, 0);
        printf("[DST:APPLIB] iconManager via setOverlayLibraryViewController:\n");
        return true;
    }

    uint64_t cls = ds_object_class(mgr);
    bool ok = ds_poke_pointer_ivar(mgr, cls, "_overlayLibraryViewController", 0);
    if (ok) printf("[DST:APPLIB] iconManager via _overlayLibraryViewController\n");
    return ok;
}

static bool ds_force_object_method_nil(uint64_t obj,
                                       const char *className,
                                       const char *selectorName,
                                       uint64_t argument)
{
    uint64_t cls = r_class(className);
    uint64_t selector = r_sel(selectorName);
    uint64_t NSObject = r_class("NSObject");
    uint64_t falseSelector = r_sel("isProxy");
    if (!r_is_objc_ptr(obj) || !r_is_objc_ptr(cls) || !selector ||
        !r_is_objc_ptr(NSObject) || !falseSelector) return false;

    uint64_t method = r_dlsym_call(
        R_TIMEOUT, "class_getInstanceMethod",
        cls, selector, 0, 0, 0, 0, 0, 0);
    uint64_t falseMethod = r_dlsym_call(
        R_TIMEOUT, "class_getInstanceMethod",
        NSObject, falseSelector, 0, 0, 0, 0, 0, 0);
    uint64_t falseIMP = falseMethod
        ? r_dlsym_call(R_TIMEOUT, "method_getImplementation",
                       falseMethod, 0, 0, 0, 0, 0, 0, 0)
        : 0;
    if (!method || !falseIMP) {
        printf("[DST:APPLIB] hook %s.%s unavailable (method=0x%llx falseIMP=0x%llx)\n",
               className, selectorName, method, falseIMP);
        return false;
    }

    uint64_t oldIMP = r_dlsym_call(
        R_TIMEOUT, "method_setImplementation",
        method, falseIMP, 0, 0, 0, 0, 0, 0);
    uint64_t value = r_msg2_main(obj, selectorName, argument, 0, 0, 0);
    printf("[DST:APPLIB] hooked %s.%s oldIMP=0x%llx value=0x%llx\n",
           className, selectorName, oldIMP, value);
    return oldIMP != 0 && value == 0;
}

// Replace a zero-argument method with -[NSObject isProxy], which returns NO.
// For BOOL getters that reads as NO; for an integer count it reads as 0. Used on
// iOS 17, where the App Library page is not controlled by any writable property
// -- the class dump showed getters with no matching setters -- so the only way
// to switch it off is to change what the getters answer.
static bool ds_force_method_zero(const char *className, const char *selectorName)
{
    uint64_t cls = r_class(className);
    uint64_t selector = r_sel(selectorName);
    uint64_t NSObject = r_class("NSObject");
    uint64_t falseSelector = r_sel("isProxy");
    if (!r_is_objc_ptr(cls) || !selector || !r_is_objc_ptr(NSObject) || !falseSelector) {
        printf("[DST:APPLIB] hook %s.%s: class/selector unavailable\n",
               className, selectorName);
        return false;
    }
    uint64_t method = r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod",
                                   cls, selector, 0, 0, 0, 0, 0, 0);
    uint64_t falseMethod = r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod",
                                        NSObject, falseSelector, 0, 0, 0, 0, 0, 0);
    uint64_t falseIMP = falseMethod
        ? r_dlsym_call(R_TIMEOUT, "method_getImplementation",
                       falseMethod, 0, 0, 0, 0, 0, 0, 0)
        : 0;
    if (!method || !falseIMP) {
        printf("[DST:APPLIB] hook %s.%s unavailable (method=0x%llx falseIMP=0x%llx)\n",
               className, selectorName, method, falseIMP);
        return false;
    }
    uint64_t oldIMP = r_dlsym_call(R_TIMEOUT, "method_setImplementation",
                                   method, falseIMP, 0, 0, 0, 0, 0, 0);
    printf("[DST:APPLIB] hooked %s.%s oldIMP=0x%llx\n", className, selectorName, oldIMP);
    return oldIMP != 0;
}

static bool ds_disable_app_library_singular_path(uint64_t mgr,
                                                 uint64_t rootFC,
                                                 uint64_t rootView)
{
    bool trailingOK = false;

    uint64_t iconController = ds_try_msg0(mgr, "iconController");
    uint64_t iconModel = ds_try_msg0(mgr, "iconModel");
    uint64_t managerConfig = ds_try_msg0(mgr, "configuration");
    bool flagsOK = false;

    // Exact writable iOS 17 property from SBHIconManager.h. Keep this
    // explicit instead of relying on the speculative cross-version list so
    // the log always records its before/after state.
    if (r_responds(mgr, "setCanPresentOverscrollLibraryForPageTransition:") &&
        r_responds(mgr, "canPresentOverscrollLibraryForPageTransition")) {
        uint64_t before = r_msg2_main(
            mgr, "canPresentOverscrollLibraryForPageTransition", 0, 0, 0, 0);
        r_msg2_main(mgr, "setCanPresentOverscrollLibraryForPageTransition:",
                    0, 0, 0, 0);
        uint64_t after = r_msg2_main(
            mgr, "canPresentOverscrollLibraryForPageTransition", 0, 0, 0, 0);
        printf("[DST:APPLIB] iconManager canPresentOverscrollLibrary %llu -> %llu\n",
               before, after);
        flagsOK |= after == 0;
    } else {
        printf("[DST:APPLIB] iconManager overscroll-library property unavailable\n");
    }

    // On iOS 17 none of these five setters exists on any class, and the only
    // ivar that resolves is the manager's _canPresentOverscrollLibraryForPage-
    // Transition, already handled above. Sweeping the other five targets costs
    // ~60 remote round trips to learn nothing, so restrict it to the manager
    // there. Later versions keep the full sweep.
    bool ios17 = ds_ios_major_version() == 17;
    flagsOK |= ds_disable_app_library_flags_on_target(mgr, "iconManager");
    if (!ios17) {
        flagsOK |= ds_disable_app_library_flags_on_target(iconController, "iconController");
        flagsOK |= ds_disable_app_library_flags_on_target(iconModel, "iconModel");
        flagsOK |= ds_disable_app_library_flags_on_target(managerConfig, "iconManager.configuration");
        flagsOK |= ds_disable_app_library_flags_on_target(rootFC, "rootFolderController");
        flagsOK |= ds_disable_app_library_flags_on_target(rootView, "rootFolderView");
    }

    // Exact iOS 17 SBHIconManager state from the 17.5 SpringBoardHome
    // headers. Clear an in-flight/visible library before detaching the
    // trailing controller, then force its overscroll presenter to reconcile.
    if (r_responds(mgr, "setMainDisplayLibraryViewVisible:libraryViewTransitioning:")) {
        r_msg2_main(mgr, "setMainDisplayLibraryViewVisible:libraryViewTransitioning:",
                    0, 0, 0, 0);
        printf("[DST:APPLIB] iconManager main library visible=0 transitioning=0\n");
    } else {
        if (r_responds(mgr, "setMainDisplayLibraryViewVisible:")) {
            r_msg2_main(mgr, "setMainDisplayLibraryViewVisible:", 0, 0, 0, 0);
        }
        if (r_responds(mgr, "setMainDisplayLibraryViewVisibilityTransitioning:")) {
            r_msg2_main(mgr, "setMainDisplayLibraryViewVisibilityTransitioning:",
                        0, 0, 0, 0);
        }
    }

    trailingOK |= ds_set_trailing_controller(mgr, 0, "iconManager");
    (void)ds_clear_overlay_library_controller(mgr);
    trailingOK |= ds_set_trailing_controller(rootFC, 0, "rootFolderController");

    if (r_is_objc_ptr(rootView)) {
        trailingOK |= ds_set_trailing_controller(rootView, 0, "rootFolderView");
    }

    if (r_responds(mgr, "_updateOverscrollModalLibraryForScrollToPresented:")) {
        r_msg2_main(mgr, "_updateOverscrollModalLibraryForScrollToPresented:",
                    0, 0, 0, 0);
        printf("[DST:APPLIB] iconManager reconciled overscroll presenter hidden\n");
    }

    // SBRootFolderController caches its page topology. Clearing the manager's
    // trailing controller alone does not necessarily remove the already
    // constructed trailing page until SBHIconManager performs a forced
    // relayout (both selectors are present in the iOS 17.5 headers).
    if (r_responds(mgr, "setNeedsRelayout:")) {
        r_msg2_main(mgr, "setNeedsRelayout:", 1, 0, 0, 0);
    }
    if (r_responds(mgr, "layoutIconListsWithAnimationType:forceRelayout:")) {
        r_msg2_main(mgr, "layoutIconListsWithAnimationType:forceRelayout:",
                    0, 1, 0, 0);
        printf("[DST:APPLIB] iconManager forced root-page relayout\n");
    } else if (r_responds(mgr, "relayout")) {
        r_msg2_main(mgr, "relayout", 0, 0, 0, 0);
        printf("[DST:APPLIB] iconManager relayout fallback\n");
    }

    printf("[DST:APPLIB] singular flags=%d trailing=%d\n",
           flagsOK, trailingOK);
    return flagsOK && trailingOK;
}

static bool ds_poke_double_ivar(uint64_t obj, uint64_t cls, const char *name, double value)
{
    uint64_t target = ds_resolve_ivar_target(obj, cls, name);
    if (!target) return false;

    union { double d; uint64_t u; } out = { .d = value };
    if (!remote_write(target, &out.u, sizeof(out.u))) return false;

    union { uint64_t u; double d; } readback = { .u = remote_read64(target) };
    printf("[DST]   %-40s @ 0x%llx -> %f\n", name, target, readback.d);
    return true;
}

static void ds_main_set_needs_layout(uint64_t view, const char *tag)
{
    if (!r_is_objc_ptr(view)) return;

    if (r_responds(view, "setNeedsLayout")) {
        uint64_t sel = r_sel("setNeedsLayout");
        r_perform_main(view, sel, 0, false);
        printf("[DST]   %s setNeedsLayout\n", tag);
    }
}

static void ds_refresh_root_folder_after_app_library_change(uint64_t rootFC, uint64_t rootView)
{
    printf("[DST:APPLIB] marking root folder views dirty\n");

    if (r_is_objc_ptr(rootFC) &&
        r_responds(rootFC, "currentIconListView")) {
        uint64_t currentList = r_msg2(rootFC, "currentIconListView", 0, 0, 0, 0);
        ds_main_set_needs_layout(currentList, "currentIconListView");
    }

    ds_main_set_needs_layout(rootView, "rootFolderView");

    uint64_t fcView = ds_try_msg0(rootFC, "view");
    if (fcView != rootView) {
        ds_main_set_needs_layout(fcView, "rootFolderController.view");
    }
}

bool darksword_tweak_disable_app_library_in_session(void)
{
    printf("[DST:APPLIB] disabling app library\n");

    uint64_t clsIC = r_class("SBIconController");
    uint64_t ctrl = r_is_objc_ptr(clsIC) ? r_msg2(clsIC, "sharedInstance", 0, 0, 0, 0) : 0;
    uint64_t mgr = ds_try_msg0(ctrl, "iconManager");
    uint64_t rootFC = ds_try_msg0(mgr, "rootFolderController");
    if (!r_is_objc_ptr(rootFC)) {
        printf("[DST:APPLIB] rootFolderController nil\n");
        return false;
    }

    uint64_t rootView = ds_try_msg0(rootFC, "rootFolderView");
    if (!r_is_objc_ptr(rootView)) {
        printf("[DST:APPLIB] rootFolderView nil\n");
    }

    bool ok = false;
    if (ds_ios_major_version() == 17) {
        printf("[DST:APPLIB] using iOS 17 singular controller path\n");
        ds_log_target("SBIconController", ctrl);
        ds_log_target("iconManager", mgr);
        ds_log_target("iconManager.iconController", ds_try_msg0(mgr, "iconController"));
        ds_log_target("iconManager.iconModel", ds_try_msg0(mgr, "iconModel"));
        ds_log_target("iconManager.configuration", ds_try_msg0(mgr, "configuration"));
        ds_log_target("rootFolderController", rootFC);
        ds_log_target("rootFolderView", rootView);

        // SBIconController is SBHIconManager's delegate on iOS 17. Stop the
        // manager from sourcing library controllers.
        bool librarySourceHookOK = ds_force_object_method_nil(
            ctrl, "SBIconController", "libraryViewControllersForIconManager:", mgr);

        // A class dump of this device's SpringBoard (iOS 17.3.1) settled what
        // the previous approach got wrong. None of setAppLibraryAllowed:,
        // setAllowsAppLibrary:, setAppLibraryEnabled:, setLibraryEnabled: or
        // setShowsAppLibrary: exists anywhere on iOS 17, and neither
        // SBRootFolderController nor SBRootFolderView has a
        // setTrailingCustomViewController: -- the old code fell back to writing
        // the ivar directly, which cannot tear down a page already built.
        //
        // What does exist are getters with no setters, so the way to switch the
        // page off is to change the answers:
        //   SBIconController -isAppLibrarySupported     the master gate
        //   SBIconController -isAppLibraryAllowed       (on the controller, NOT
        //                                                the manager, which is
        //                                                where it was looked for)
        //   SBRootFolderView -_trailingCustomPageCount  the page itself
        //   SBRootFolderView -_trailingCustomViewShouldBeIndicatedInPageControl
        //                                               the page-control dot
        int gateHooks = 0;
        gateHooks += ds_force_method_zero("SBIconController", "isAppLibrarySupported");
        gateHooks += ds_force_method_zero("SBIconController", "isAppLibraryAllowed");
        gateHooks += ds_force_method_zero("SBRootFolderView", "_trailingCustomPageCount");
        gateHooks += ds_force_method_zero("SBRootFolderView",
                                          "_trailingCustomViewShouldBeIndicatedInPageControl");
        printf("[DST:APPLIB] iOS 17 gate hooks installed=%d/4\n", gateHooks);

        ok = ds_disable_app_library_singular_path(mgr, rootFC, rootView);
        ok = ok || gateHooks > 0;

        // The hook is deliberately NOT folded into the result. It is one of
        // three independent things this path attempts, and ANDing it in meant a
        // path that had actually worked still reported failure. Log it instead.
        if (ok || librarySourceHookOK) {
            ds_refresh_root_folder_after_app_library_change(rootFC, rootView);
        }
        printf("[DST:APPLIB] iOS 17 library source hook=%d gates=%d singular=%d\n",
               librarySourceHookOK, gateHooks, ok);
        ok = ok || librarySourceHookOK;
        printf("[DST:APPLIB] result=%d\n", ok);
        return ok;
    }

    uint64_t NSArray = r_class("NSArray");
    uint64_t emptyArr = r_is_objc_ptr(NSArray) ? r_msg2(NSArray, "new", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(emptyArr)) {
        emptyArr = r_is_objc_ptr(NSArray) ? r_msg2(NSArray, "array", 0, 0, 0, 0) : 0;
    }
    if (!r_is_objc_ptr(emptyArr)) {
        printf("[DST:APPLIB] empty NSArray failed\n");
        return false;
    }

    ok = false;
    ok |= ds_set_trailing_controllers(rootFC, emptyArr, "rootFolderController");

    if (r_is_objc_ptr(rootView)) {
        ok |= ds_set_trailing_controllers(rootView, emptyArr, "rootFolderView");
    }

    if (!ok && ds_ios_major_version() != 17) {
        printf("[DST:APPLIB] plural path failed; trying singular controller fallback\n");
        ok = ds_disable_app_library_singular_path(mgr, rootFC, rootView);
    }

    if (ok) ds_refresh_root_folder_after_app_library_change(rootFC, rootView);

    printf("[DST:APPLIB] result=%d\n", ok);
    return ok;
}

bool darksword_tweak_disable_icon_fly_in_in_session(void)
{
    printf("[DST:FLYIN] disabling icon fly-in animation\n");

    uint64_t cls = r_class("SBCoverSheetPresentationManager");
    uint64_t mgr = r_is_objc_ptr(cls) ? r_msg2(cls, "sharedInstance", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(mgr)) {
        printf("[DST:FLYIN] presentation manager missing\n");
        return false;
    }

    uint64_t mgrCls = ds_object_class(mgr);
    bool ok = true;
    ok &= ds_poke_double_ivar(mgr, mgrCls, "_iconFlyInTension", 1.0e6);
    ok &= ds_poke_double_ivar(mgr, mgrCls, "_iconFlyInFriction", 1.0e6);
    ok &= ds_poke_double_ivar(mgr, mgrCls, "_iconFlyInInteractiveResponseMin", 0.0001);
    ok &= ds_poke_double_ivar(mgr, mgrCls, "_iconFlyInInteractiveResponseMax", 0.0001);
    ok &= ds_poke_double_ivar(mgr, mgrCls, "_iconFlyInInteractiveDampingRatioMin", 1.0);
    ok &= ds_poke_double_ivar(mgr, mgrCls, "_iconFlyInInteractiveDampingRatioMax", 1.0);
    printf("[DST:FLYIN] result=%d\n", ok);
    return ok;
}

bool darksword_tweak_zero_backlight_fade_in_session(void)
{
    printf("[DST:BLF] zeroing backlight fade durations\n");

    uint64_t cls = r_class("SBScreenWakeAnimationController");
    uint64_t ctrl = r_is_objc_ptr(cls) ? r_msg2(cls, "sharedInstance", 0, 0, 0, 0) : 0;
    uint64_t selFetch = r_sel("_animationSettingsForBacklightChangeSource:isWake:");
    if (!r_is_objc_ptr(ctrl) || !selFetch) {
        printf("[DST:BLF] wake animation controller missing\n");
        return false;
    }

    uint64_t seen[16] = {0};
    int seenCount = 0;
    uint64_t settingsCls = 0;
    uint64_t ivarOffset = 0;
    int poked = 0;

    for (int src = 0; src <= 3; src++) {
        for (int isWake = 0; isWake <= 1; isWake++) {
            uint64_t settings = r_msg(ctrl, selFetch, (uint64_t)src, (uint64_t)isWake, 0, 0);
            if (!r_is_objc_ptr(settings)) continue;

            bool dup = false;
            for (int i = 0; i < seenCount; i++) {
                if (seen[i] == settings) { dup = true; break; }
            }
            if (dup) continue;
            if (seenCount < 16) seen[seenCount++] = settings;

            if (!ivarOffset) {
                settingsCls = ds_object_class(settings);
                uint64_t nameMem = r_alloc_str("_backlightFadeDuration");
                uint64_t ivar = nameMem ? r_dlsym_call(100, "class_getInstanceVariable",
                                                       settingsCls, nameMem, 0, 0, 0, 0, 0, 0) : 0;
                r_free(nameMem);
                if (!ivar) {
                    printf("[DST:BLF] _backlightFadeDuration ivar missing\n");
                    return false;
                }
                ivarOffset = r_dlsym_call(100, "ivar_getOffset", ivar, 0, 0, 0, 0, 0, 0, 0);
                if (!ivarOffset) return false;
                printf("[DST:BLF] _backlightFadeDuration offset=0x%llx\n", ivarOffset);
            }

            union { double d; uint64_t u; } zero = { .d = 0.0 };
            uint64_t target = settings + ivarOffset;
            if (remote_write(target, &zero.u, sizeof(zero.u))) {
                printf("[DST:BLF]   settings=0x%llx -> 0\n", settings);
                poked++;
            }
        }
    }

    printf("[DST:BLF] poked=%d seen=%d\n", poked, seenCount);
    return poked > 0;
}

bool darksword_tweak_zero_wake_animation_in_session(void)
{
    printf("[DST:WAKE] zeroing wake animation\n");

    uint64_t cls = r_class("SBScreenWakeAnimationController");
    uint64_t ctrl = r_is_objc_ptr(cls) ? r_msg2(cls, "sharedInstance", 0, 0, 0, 0) : 0;
    uint64_t selFetch = r_sel("_animationSettingsForBacklightChangeSource:isWake:");
    if (!r_is_objc_ptr(ctrl) || !selFetch) {
        printf("[DST:WAKE] wake animation controller missing\n");
        return false;
    }

    uint64_t outer = r_msg(ctrl, selFetch, 0, 1, 0, 0);
    if (!r_is_objc_ptr(outer)) {
        printf("[DST:WAKE] outer settings nil\n");
        return false;
    }

    uint64_t outerCls = ds_object_class(outer);
    bool ok = true;
    ok &= ds_poke_double_ivar(outer, outerCls, "_backlightFadeDuration", 0.0);
    ok &= ds_poke_double_ivar(outer, outerCls, "_speedMultiplierForWake", 1000.0);
    ok &= ds_poke_double_ivar(outer, outerCls, "_speedMultiplierForLiftToWake", 1000.0);

    uint64_t target = ds_resolve_ivar_target(outer, outerCls, "_contentWakeSettings");
    uint64_t content = target ? remote_read64(target) : 0;
    if (!r_is_objc_ptr(content)) {
        printf("[DST:WAKE] _contentWakeSettings nil\n");
        return ok;
    }

    uint64_t contentCls = ds_object_class(content);
    ok &= ds_poke_double_ivar(content, contentCls, "_duration", 0.0);
    ok &= ds_poke_double_ivar(content, contentCls, "_speed", 1000.0);
    ok &= ds_poke_double_ivar(content, contentCls, "_delay", 0.0);
    printf("[DST:WAKE] result=%d\n", ok);
    return ok;
}

// outcome codes returned by ds_install_double_tap_on_view so callers can
// summarise per-iteration results without each call printing its own line.
typedef enum { DTLockOutcomeFailed = 0, DTLockOutcomeInstalled, DTLockOutcomeAlreadyInstalled } DTLockOutcome;

typedef struct {
    double x;
    double y;
    double width;
    double height;
} DSTCGRect;

static bool ds_object_class_name(uint64_t obj, char *out, size_t outLen)
{
    if (!r_is_objc_ptr(obj) || !out || outLen < 2) return false;
    out[0] = '\0';

    uint64_t remoteName = r_dlsym_call(R_TIMEOUT, "object_getClassName",
                                       obj, 0, 0, 0, 0, 0, 0, 0);
    if (!remoteName) return false;
    uint64_t copy = r_dlsym_call(R_TIMEOUT, "strdup",
                                 remoteName, 0, 0, 0, 0, 0, 0, 0);
    if (!copy) return false;
    bool readOK = remote_read(copy, out, outLen - 1);
    out[outLen - 1] = '\0';
    r_free(copy);
    return readOK && out[0] != '\0';
}

static bool ds_set_view_frame_to_bounds(uint64_t view, uint64_t parent)
{
    DSTCGRect bounds = {0};
    if (!r_msg2_main_struct_ret(parent, "bounds", &bounds, sizeof(bounds),
                                NULL, 0, NULL, 0, NULL, 0, NULL, 0)) {
        return false;
    }
    r_msg2_main_raw(view, "setFrame:",
                    &bounds, sizeof(bounds),
                    NULL, 0, NULL, 0, NULL, 0);
    return true; // UIView's -setFrame: has a void return value.
}

static DTLockOutcome ds_install_double_tap_on_view(uint64_t view, uint64_t sb, uint64_t selLock, uint64_t assocKey, const char *tag, bool verbose)
{
    if (!r_is_objc_ptr(view) || !r_is_objc_ptr(sb) || !selLock || !assocKey) return DTLockOutcomeFailed;

    uint64_t existing = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                     view, assocKey, 0, 0, 0, 0, 0, 0);
    if (r_is_objc_ptr(existing)) {
        if (verbose) printf("[DST:LOCK] %s already installed\n", tag);
        return DTLockOutcomeAlreadyInstalled;
    }

    uint64_t clsGR = r_class("UITapGestureRecognizer");
    uint64_t gr = r_is_objc_ptr(clsGR) ? r_msg2(clsGR, "alloc", 0, 0, 0, 0) : 0;
    gr = r_is_objc_ptr(gr) ? r_msg2(gr, "initWithTarget:action:", sb, selLock, 0, 0) : 0;
    if (!r_is_objc_ptr(gr)) {
        printf("[DST:LOCK] %s recognizer allocation failed\n", tag);
        return DTLockOutcomeFailed;
    }

    r_msg2(gr, "setNumberOfTapsRequired:", 2, 0, 0, 0);
    if (r_responds(gr, "setCancelsTouchesInView:"))
        r_msg2(gr, "setCancelsTouchesInView:", 0, 0, 0, 0);
    if (r_responds(gr, "setDelaysTouchesBegan:"))
        r_msg2(gr, "setDelaysTouchesBegan:", 0, 0, 0, 0);

    r_msg2_main(view, "addGestureRecognizer:", gr, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                 view, assocKey, gr, 1, 0, 0, 0, 0);
    if (verbose) printf("[DST:LOCK] installed on %s view=0x%llx\n", tag, view);
    return DTLockOutcomeInstalled;
}

// Install a transparent, backmost hit target. Interactive children remain
// above it, so icon and dock controls do not deliver their touches through
// this recognizer.
static DTLockOutcome ds_install_double_tap_catcher(uint64_t parent,
                                                   uint64_t sb,
                                                   uint64_t selLock,
                                                   uint64_t catcherAssocKey,
                                                   uint64_t gestureAssocKey,
                                                   const char *tag,
                                                   bool verbose)
{
    if (!r_is_objc_ptr(parent) || !catcherAssocKey) return DTLockOutcomeFailed;

    uint64_t existing = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                     parent, catcherAssocKey, 0, 0, 0, 0, 0, 0);
    if (r_is_objc_ptr(existing)) {
        uint64_t superview = r_msg2_main(existing, "superview", 0, 0, 0, 0);
        if (superview != parent) {
            ds_set_view_frame_to_bounds(existing, parent);
            r_msg2_main(parent, "insertSubview:atIndex:", existing, 0, 0, 0);
            if (verbose) printf("[DST:LOCK] %s catcher reattached\n", tag);
            return DTLockOutcomeInstalled;
        }
        if (verbose) printf("[DST:LOCK] %s catcher already installed\n", tag);
        return DTLockOutcomeAlreadyInstalled;
    }

    uint64_t UIView = r_class("UIView");
    uint64_t catcher = r_is_objc_ptr(UIView) ? r_msg2_main(UIView, "alloc", 0, 0, 0, 0) : 0;
    catcher = r_is_objc_ptr(catcher) ? r_msg2_main(catcher, "init", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(catcher) || !ds_set_view_frame_to_bounds(catcher, parent)) {
        printf("[DST:LOCK] %s catcher allocation/frame failed\n", tag);
        return DTLockOutcomeFailed;
    }

    r_msg2_main(catcher, "setAutoresizingMask:", (1u << 1) | (1u << 4), 0, 0, 0);
    r_msg2_main(catcher, "setUserInteractionEnabled:", 1, 0, 0, 0);
    r_msg2_main(parent, "insertSubview:atIndex:", catcher, 0, 0, 0);

    DTLockOutcome outcome = ds_install_double_tap_on_view(catcher, sb, selLock,
                                                          gestureAssocKey, tag, verbose);
    if (outcome == DTLockOutcomeFailed) {
        r_msg2_main(catcher, "removeFromSuperview", 0, 0, 0, 0);
        return outcome;
    }

    r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                 parent, catcherAssocKey, catcher, 1, 0, 0, 0, 0);
    return outcome;
}

static bool ds_install_home_page_catcher(uint64_t list,
                                         uint64_t sb,
                                         uint64_t selLock,
                                         uint64_t catcherAssocKey,
                                         uint64_t gestureAssocKey)
{
    if (!r_is_objc_ptr(list)) return false;
    char cls[96] = {0};
    ds_object_class_name(list, cls, sizeof(cls));
    if (!strstr(cls, "IconListView") || strstr(cls, "Dock")) return false;
    if (r_responds(list, "isDock") &&
        r_msg2(list, "isDock", 0, 0, 0, 0)) return false;

    return ds_install_double_tap_catcher(
        list, sb, selLock, catcherAssocKey, gestureAssocKey,
        cls[0] ? cls : "home page", true) != DTLockOutcomeFailed;
}

static int ds_install_home_page_catchers(uint64_t rootFC,
                                         uint64_t sb,
                                         uint64_t selLock,
                                         uint64_t catcherAssocKey,
                                         uint64_t gestureAssocKey)
{
    if (!r_is_objc_ptr(rootFC)) return 0;
    int installed = 0;

    // Prefer the indexed accessor: visibleIconListViews may contain only the
    // currently displayed page, which would leave every other Home Screen
    // page without an empty-area catcher.
    if (r_responds(rootFC, "iconListViewCount") &&
        r_responds(rootFC, "iconListViewAtIndex:")) {
        uint64_t count = r_msg2_main(rootFC, "iconListViewCount", 0, 0, 0, 0);
        if (count > 32) count = 32;
        for (uint64_t i = 0; i < count; i++) {
            uint64_t list = r_msg2_main(rootFC, "iconListViewAtIndex:", i, 0, 0, 0);
            if (ds_install_home_page_catcher(list, sb, selLock,
                                             catcherAssocKey, gestureAssocKey)) {
                installed++;
            }
        }
        if (installed > 0) return installed;
    }

    const char *arraySelectors[] = { "visibleIconListViews", "iconListViews", NULL };
    for (int s = 0; arraySelectors[s]; s++) {
        if (!r_responds(rootFC, arraySelectors[s])) continue;
        uint64_t lists = r_msg2_main(rootFC, arraySelectors[s], 0, 0, 0, 0);
        uint64_t count = r_is_objc_ptr(lists) ?
            r_msg2_main(lists, "count", 0, 0, 0, 0) : 0;
        if (count > 32) count = 32;
        for (uint64_t i = 0; i < count; i++) {
            uint64_t list = r_msg2_main(lists, "objectAtIndex:", i, 0, 0, 0);
            if (ds_install_home_page_catcher(list, sb, selLock,
                                             catcherAssocKey, gestureAssocKey)) {
                installed++;
            }
        }
        if (installed > 0) return installed;
    }

    const char *currentSelectors[] = {
        "currentIconListView",
        "currentRootIconListView",
        "currentIconList",
        "currentRootIconList",
        NULL,
    };
    for (int s = 0; currentSelectors[s]; s++) {
        if (!r_responds(rootFC, currentSelectors[s])) continue;
        uint64_t list = r_msg2_main(rootFC, currentSelectors[s], 0, 0, 0, 0);
        if (ds_install_home_page_catcher(list, sb, selLock,
                                         catcherAssocKey, gestureAssocKey)) {
            installed++;
            break;
        }
    }
    return installed;
}

static bool ds_class_name_contains(uint64_t obj, const char *needle)
{
    char cls[96] = {0};
    return ds_object_class_name(obj, cls, sizeof(cls)) &&
           strstr(cls, needle) != NULL;
}

static uint64_t ds_cover_sheet_from_controller_array(uint64_t controllers)
{
    uint64_t count = r_is_objc_ptr(controllers) ?
        r_msg2_main(controllers, "count", 0, 0, 0, 0) : 0;
    if (count > 32) count = 32;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t child = r_msg2_main(controllers, "objectAtIndex:", i, 0, 0, 0);
        if (r_is_objc_ptr(child) &&
            ds_class_name_contains(child, "CSCoverSheetViewController")) {
            return child;
        }
    }
    return 0;
}

static uint64_t ds_resolve_cover_sheet_controller(uint64_t root)
{
    uint64_t coverSheet = r_responds(root, "coverSheetViewController") ?
        r_msg2_main(root, "coverSheetViewController", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(coverSheet)) return coverSheet;

    coverSheet = r_ivar_value(root, "_coverSheetViewController");
    if (r_is_objc_ptr(coverSheet)) return coverSheet;

    const char *arraySelectors[] = { "childViewControllers", "viewControllers", NULL };
    for (int s = 0; arraySelectors[s]; s++) {
        if (!r_responds(root, arraySelectors[s])) continue;
        uint64_t controllers = r_msg2_main(root, arraySelectors[s], 0, 0, 0, 0);
        coverSheet = ds_cover_sheet_from_controller_array(controllers);
        if (r_is_objc_ptr(coverSheet)) return coverSheet;
    }
    return 0;
}

static uint64_t ds_cover_sheet_main_page_view(uint64_t window)
{
    uint64_t root = r_is_objc_ptr(window) ?
        r_msg2_main(window, "rootViewController", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(root)) return 0;
    char cls[96] = {0};
    ds_object_class_name(root, cls, sizeof(cls));
    printf("[DST:LOCK] cover sheet root=%s 0x%llx\n",
           cls[0] ? cls : "unknown", root);
    if (r_responds(root, "loadViewIfNeeded")) {
        r_msg2_main(root, "loadViewIfNeeded", 0, 0, 0, 0);
    }

    uint64_t coverSheet = ds_resolve_cover_sheet_controller(root);
    // Some releases expose CSCoverSheetViewController directly as the root.
    if (!r_is_objc_ptr(coverSheet) && strstr(cls, "CSCoverSheet")) {
        coverSheet = root;
    }
    if (!r_is_objc_ptr(coverSheet)) return 0;
    if (r_responds(coverSheet, "loadViewIfNeeded")) {
        r_msg2_main(coverSheet, "loadViewIfNeeded", 0, 0, 0, 0);
    }

    uint64_t mainPage = r_responds(coverSheet, "mainPageContentViewController") ?
        r_msg2_main(coverSheet, "mainPageContentViewController", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(mainPage)) {
        mainPage = r_ivar_value(coverSheet, "_mainPageContentViewController");
    }
    if (!r_is_objc_ptr(mainPage)) return 0;
    if (r_responds(mainPage, "loadViewIfNeeded")) {
        r_msg2_main(mainPage, "loadViewIfNeeded", 0, 0, 0, 0);
    }

    char mainCls[96] = {0};
    ds_object_class_name(mainPage, mainCls, sizeof(mainCls));
    printf("[DST:LOCK] lock target=%s 0x%llx\n",
           mainCls[0] ? mainCls : "main page", mainPage);
    return r_msg2_main(mainPage, "view", 0, 0, 0, 0);
}

static bool ds_remove_double_tap_from_view(uint64_t view, uint64_t assocKey, const char *tag)
{
    if (!r_is_objc_ptr(view) || !assocKey) return false;

    uint64_t existing = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                     view, assocKey, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(existing)) return false;

    r_msg2_main(view, "removeGestureRecognizer:", existing, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                 view, assocKey, 0, 0, 0, 0, 0, 0);
    printf("[DST:LOCK] removed window-level recognizer from %s view=0x%llx\n",
           tag ? tag : "view", view);
    return true;
}

bool darksword_tweak_double_tap_to_lock_in_session(void)
{
    printf("[DST:LOCK] installing double-tap to lock\n");

    uint64_t clsSB = r_class("SpringBoard");
    uint64_t sb = r_is_objc_ptr(clsSB) ? r_msg2(clsSB, "sharedApplication", 0, 0, 0, 0) : 0;
    uint64_t selLock = r_sel("_simulateLockButtonPress");
    uint64_t assocKey = r_sel("darkswordDoubleTapLockGesture");
    uint64_t catcherAssocKey = r_sel("darkswordDoubleTapLockCatcher");
    if (!r_is_objc_ptr(sb) || !selLock || !assocKey || !catcherAssocKey) {
        printf("[DST:LOCK] SpringBoard target missing\n");
        return false;
    }

    bool ok = false;
    uint64_t clsIC = r_class("SBIconController");
    uint64_t ctrl = r_is_objc_ptr(clsIC) ? r_msg2(clsIC, "sharedInstance", 0, 0, 0, 0) : 0;
    uint64_t mgr = ds_try_msg0(ctrl, "iconManager");
    uint64_t rootFC = ds_try_msg0(mgr, "rootFolderController");
    uint64_t homeView = ds_try_msg0(rootFC, "view");
    if (r_is_objc_ptr(homeView)) {
        // Remove the legacy recognizer attached to the entire root view. It
        // receives taps that bubble up from icons, so an accidental second
        // tap after launching an app could lock the device.
        (void)ds_remove_double_tap_from_view(
            homeView, assocKey, "legacy homescreen root");
    }
    int homeCatchers = ds_install_home_page_catchers(
        rootFC, sb, selLock, catcherAssocKey, assocKey);
    ok |= homeCatchers > 0;
    printf("[DST:LOCK] homescreen empty-area catchers=%d\n", homeCatchers);

    // Older builds installed the recognizer on every SpringBoard window.
    // That also covered the passcode window, so a double tap while entering a
    // passcode invoked the lock action again. Remove those broad recognizers
    // before installing on the two intended surfaces only. The same pass finds
    // the cover sheet window. Only -windows itself is read on the main thread;
    // the retained snapshot is walked on the worker thread (1-2 round trips per
    // window instead of two ~23-round-trip main hops).
    uint64_t UIApplication = r_class("UIApplication");
    uint64_t app = r_is_objc_ptr(UIApplication) ?
        r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0) : 0;
    uint64_t windows = r_is_objc_ptr(app) ? r_msg2_main_retained(app, "windows") : 0;
    uint64_t windowList[80];
    int windowCount = r_array_items_of_class(windows, 0, windowList, 80);
    uint64_t coverWindowClass = r_class("SBCoverSheetWindow");
    uint64_t selKind = r_sel("isKindOfClass:");
    uint64_t coverWindow = 0;
    int removed = 0;
    for (int i = 0; i < windowCount; i++) {
        uint64_t window = windowList[i];
        if (ds_remove_double_tap_from_view(window, assocKey, "legacy window")) {
            removed++;
        }
        if (!coverWindow && r_is_objc_ptr(coverWindowClass) &&
            r_msg(window, selKind, coverWindowClass, 0, 0, 0)) {
            coverWindow = window;
            printf("[DST:LOCK] cover sheet window[%d]=0x%llx\n", i, window);
        }
    }

    uint64_t lockView = ds_cover_sheet_main_page_view(coverWindow);
    bool lockScreenInstalled = r_is_objc_ptr(lockView) &&
        ds_install_double_tap_on_view(
            lockView, sb, selLock, assocKey,
            "lockscreen main page", true) != DTLockOutcomeFailed;
    ok |= lockScreenInstalled;
    r_release(windows);
    printf("[DST:LOCK] legacyRemoved=%d lockscreen=%d passcodeExcluded=1\n",
           removed, lockScreenInstalled);

    printf("[DST:LOCK] result=%d\n", ok);
    return ok;
}

// Extend Lock Screen Duration.
//
// The lock screen's dim-then-sleep floor is the SpringBoard preference
// `SBMinimumLockscreenIdleTime` (domain com.apple.springboard), read by
// SBIdleTimerGlobalStateMonitor; -[SBIdleTimerDescriptorFactory
// sanitizeDescriptorForLockscreenDefaults:] then floors every lock-screen
// interval with max(interval, minimumLockscreenIdleTime). Setting this
// preference gives an EXACT seconds value (not the coarse idleTimerDuration
// enum buckets) and PERSISTS across respring and reboot.
//
// Because this runs inside SpringBoard via RemoteCall, writing SpringBoard's own
// defaults domain is permitted, so NSUserDefaults here IS com.apple.springboard.
// The monitor reads the preference when it initializes, so this takes effect on
// the next respring (confirmed on device: 30 -> exactly 30s). We do NOT poke the
// monitor ivar (its getter is a block; overwriting it crashes SpringBoard).
bool darksword_tweak_extend_lockscreen_duration_in_session(long long seconds)
{
    if (seconds < 1) seconds = 1;
    printf("[DST:LSD] setting SBMinimumLockscreenIdleTime=%llds in com.apple.springboard\n",
           seconds);

    uint64_t NSUserDefaults = r_class("NSUserDefaults");
    uint64_t ud = r_is_objc_ptr(NSUserDefaults)
        ? r_msg2_main(NSUserDefaults, "standardUserDefaults", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(ud)) {
        printf("[DST:LSD] standardUserDefaults unavailable\n");
        return false;
    }

    uint64_t key = r_cfstr("SBMinimumLockscreenIdleTime");
    if (!key) {
        printf("[DST:LSD] key string alloc failed\n");
        return false;
    }

    // -[NSUserDefaults setDouble:forKey:] — signature v@:d@, so the double is a
    // real fp argument; marshal it via the raw (NSInvocation-backed) call.
    double val = (double)seconds;
    r_msg2_main_raw(ud, "setDouble:forKey:", &val, sizeof(val),
                    &key, sizeof(key), NULL, 0, NULL, 0);
    r_msg2_main(ud, "synchronize", 0, 0, 0, 0);

    // Read back for the log (integerValue returns in x0, easy to print).
    uint64_t num = r_msg2_main(ud, "objectForKey:", key, 0, 0, 0);
    long long got = r_is_objc_ptr(num)
        ? (long long)r_msg2_main(num, "integerValue", 0, 0, 0, 0) : -1;
    printf("[DST:LSD] wrote pref; readback=%lld (respring to apply; persists)\n", got);
    return got == seconds;
}

// Read the currently-configured lock-screen floor. Because this runs inside
// SpringBoard, NSUserDefaults here IS com.apple.springboard, so we read back
// exactly what the write side stored. Returns the seconds value, 0 when the key
// is unset (stock timing), or -1 on failure.
long long darksword_tweak_read_lockscreen_duration_in_session(void)
{
    uint64_t NSUserDefaults = r_class("NSUserDefaults");
    uint64_t ud = r_is_objc_ptr(NSUserDefaults)
        ? r_msg2_main(NSUserDefaults, "standardUserDefaults", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(ud)) {
        printf("[DST:LSD] standardUserDefaults unavailable\n");
        return -1;
    }

    uint64_t key = r_cfstr("SBMinimumLockscreenIdleTime");
    if (!key) {
        printf("[DST:LSD] key string alloc failed\n");
        return -1;
    }

    uint64_t num = r_msg2_main(ud, "objectForKey:", key, 0, 0, 0);
    if (!r_is_objc_ptr(num)) {
        printf("[DST:LSD] SBMinimumLockscreenIdleTime not set (stock)\n");
        return 0;
    }

    long long got = (long long)r_msg2_main(num, "integerValue", 0, 0, 0, 0);
    printf("[DST:LSD] current SBMinimumLockscreenIdleTime=%lld\n", got);
    return got;
}

bool darksword_tweaks_apply_in_session(bool disableAppLibrary,
                                       bool disableIconFlyIn,
                                       bool zeroWakeAnimation,
                                       bool zeroBacklightFade,
                                       bool doubleTapToLock)
{
    printf("[DST] apply appLib=%d flyIn=%d wake=%d backlight=%d dblTap=%d\n",
           disableAppLibrary, disableIconFlyIn, zeroWakeAnimation,
           zeroBacklightFade, doubleTapToLock);

    bool any = false;
    bool ok = true;
    if (disableAppLibrary) {
        any = true;
        ok &= darksword_tweak_disable_app_library_in_session();
    }
    if (disableIconFlyIn) {
        any = true;
        ok &= darksword_tweak_disable_icon_fly_in_in_session();
    }
    if (zeroWakeAnimation) {
        any = true;
        ok &= darksword_tweak_zero_wake_animation_in_session();
    }
    if (zeroBacklightFade) {
        any = true;
        ok &= darksword_tweak_zero_backlight_fade_in_session();
    }
    if (doubleTapToLock) {
        any = true;
        ok &= darksword_tweak_double_tap_to_lock_in_session();
    }

    return any ? ok : true;
}
