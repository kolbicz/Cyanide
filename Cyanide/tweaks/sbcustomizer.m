//
//  sbcustomizer.m
//

#import <Foundation/Foundation.h>
#import "sbcustomizer.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import "../LogTextView.h"

static int clamp(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static uint64_t try_msg0(uint64_t obj, const char *selName)
{
    if (!r_is_objc_ptr(obj) || !r_responds(obj, selName)) return 0;
    return r_msg2(obj, selName, 0, 0, 0, 0);
}

static uint64_t retain_remote_object(uint64_t obj)
{
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t retained = r_dlsym_call(
        R_TIMEOUT, "CFRetain", obj, 0, 0, 0, 0, 0, 0, 0);
    return r_is_objc_ptr(retained) ? retained : 0;
}

static void release_remote_object(uint64_t obj)
{
    if (!r_is_objc_ptr(obj)) return;
    r_dlsym_call(R_TIMEOUT, "CFRelease", obj, 0, 0, 0, 0, 0, 0, 0);
}

static void disable_list_autofit(uint64_t listView, const char *tag)
{
    if (!r_is_objc_ptr(listView) || !r_responds(listView, "setAutomaticallyAdjustsLayoutMetricsToFit:")) return;
    r_msg2(listView, "setAutomaticallyAdjustsLayoutMetricsToFit:", 0, 0, 0, 0);
    printf("[SBC] v3: %s autoFit=NO\n", tag);
}

static uint64_t list_view_model(uint64_t listView)
{
    uint64_t model = try_msg0(listView, "model");
    if (!model) model = try_msg0(listView, "iconListModel");
    if (!model) model = try_msg0(listView, "displayedModel");
    return model;
}

static bool patch_list_model_grid(uint64_t listView, const char *tag, int cols, int rows)
{
    if (!r_is_objc_ptr(listView)) return false;

    uint64_t model = list_view_model(listView);
    if (!r_is_objc_ptr(model) || !r_responds(model, "gridSize")) {
        printf("[SBC] v3: %s missing grid model\n", tag);
        return false;
    }

    uint64_t newGrid = (((uint64_t)rows & 0xffffULL) << 16) | ((uint64_t)cols & 0xffffULL);
    uint64_t oldGrid = r_msg2(model, "gridSize", 0, 0, 0, 0) & 0xffffffffULL;

    if (r_responds(model, "setGridSize:")) {
        r_msg2(model, "setGridSize:", newGrid, 0, 0, 0);
    } else if (r_responds(model, "changeGridSize:options:")) {
        r_msg2(model, "changeGridSize:options:", newGrid, 0, 0, 0);
    } else {
        printf("[SBC] v3: %s model lacks grid setter\n", tag);
        return false;
    }

    uint64_t afterGrid = r_msg2(model, "gridSize", 0, 0, 0, 0) & 0xffffffffULL;
    printf("[SBC] v3: %s model gridSize 0x%llx -> 0x%llx\n", tag, oldGrid, afterGrid);
    return afterGrid == newGrid;
}

static void patch_dock(uint64_t iconCtrl, int dockIcons)
{
    uint64_t mgr = try_msg0(iconCtrl, "iconManager");
    if (!mgr) { printf("[SBC] dock: nil iconManager\n"); return; }

    uint64_t dock = try_msg0(mgr, "dockListView");
    if (!dock) dock = try_msg0(iconCtrl, "dockListView");
    if (!dock) { printf("[SBC] dock: nil dockListView\n"); return; }
    disable_list_autofit(dock, "dockListView");

    uint64_t model = try_msg0(dock, "model");
    if (!model) model = try_msg0(dock, "iconListModel");
    if (!model) model = try_msg0(dock, "displayedModel");
    if (model && r_responds(model, "gridSize") && r_responds(model, "setGridSize:")) {
        uint64_t oldGrid = r_msg2(model, "gridSize", 0, 0, 0, 0) & 0xffffffffULL;
        uint64_t newGrid = (oldGrid & 0xffff0000ULL) | (uint64_t)dockIcons;
        r_msg2(model, "setGridSize:", newGrid, 0, 0, 0);
        printf("[SBC] dock: gridSize 0x%llx -> 0x%llx\n", oldGrid, newGrid);
    }

    uint64_t layout = try_msg0(dock, "layout");
    if (layout) {
        uint64_t cfg = try_msg0(layout, "layoutConfiguration");
        if (cfg && r_responds(cfg, "setNumberOfPortraitColumns:")) {
            r_msg2(cfg, "setNumberOfPortraitColumns:", (uint64_t)dockIcons, 0, 0, 0);
            printf("[SBC] dock: portraitColumns -> %d\n", dockIcons);
        }
    }

    if (r_responds(dock, "setNeedsLayout")) {
        uint64_t selSetNeedsLayout = r_sel("setNeedsLayout");
        r_perform_main(dock, selSetNeedsLayout, 0, false);
    }
}

// Icon arrays are transient: changing a grid or moving an icon can replace
// them between two RemoteCall messages. Return an explicitly retained array
// so a following count/objectAtIndex: cannot target a deallocated instance.
static uint64_t model_icons_retained(uint64_t model)
{
    uint64_t stableModel = retain_remote_object(model);
    if (!stableModel) return 0;
    uint64_t icons = try_msg0(stableModel, "icons");
    if (!icons) icons = try_msg0(stableModel, "allIcons");
    if (!icons) icons = try_msg0(stableModel, "visibleIcons");
    if (!icons) icons = try_msg0(stableModel, "displayedIcons");
    uint64_t retainedIcons = retain_remote_object(icons);
    release_remote_object(stableModel);
    return retainedIcons;
}

static bool icon_matches_bundle(uint64_t icon, const char *bundleID)
{
    if (!r_is_objc_ptr(icon) || !bundleID || !bundleID[0]) return false;

    // Only use the known-safe SBApplication bundle path. Some legacy icon
    // identifier getters advertise Objective-C-looking return values but
    // actually return private payloads; probing those with
    // respondsToSelector: can terminate SpringBoard with a PAC exception.
    if (!r_responds(icon, "application")) return false;
    uint64_t app = r_msg2(icon, "application", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app) || !r_responds(app, "bundleIdentifier")) return false;
    uint64_t value = r_msg2(app, "bundleIdentifier", 0, 0, 0, 0);
    char actual[192] = {0};
    return r_is_objc_ptr(value) &&
           r_read_nsstring(value, actual, sizeof(actual)) &&
           strcmp(actual, bundleID) == 0;
}

static uint64_t find_icon_in_array_by_bundle(uint64_t icons, uint64_t listView,
                                             const char *bundleID,
                                             uint64_t *indexOut)
{
    if (!r_is_objc_ptr(icons) || !r_responds(icons, "count") ||
        !r_responds(icons, "objectAtIndex:")) return 0;
    uint64_t count = r_msg2_main(icons, "count", 0, 0, 0, 0);
    uint64_t limit = count < 256 ? count : 256;
    for (uint64_t i = 0; i < limit; i++) {
        uint64_t candidate = r_msg2_main(icons, "objectAtIndex:", i, 0, 0, 0);
        bool matched = icon_matches_bundle(candidate, bundleID);
        if (!matched && r_is_objc_ptr(listView)) {
            const char *viewSels[] = {
                "displayedIconViewForIcon:",
                "iconViewForIcon:",
                "_iconViewForIcon:",
                NULL,
            };
            for (int s = 0; viewSels[s] && !matched; s++) {
                if (!r_responds_main(listView, viewSels[s])) continue;
                uint64_t iconView = r_msg2_main(
                    listView, viewSels[s], candidate, 0, 0, 0);
                uint64_t displayedIcon = try_msg0(iconView, "icon");
                matched = icon_matches_bundle(displayedIcon, bundleID);
            }
        }
        if (!matched) continue;
        if (indexOut) *indexOut = i;
        return candidate;
    }
    return 0;
}

// SBIconListModel exposes the same mutation selectors on every page model, so
// re-probing them per icon move (r_responds is a remote round trip) re-learns a
// class-wide fact ~5 times per move. Cache the resolved selector for the
// duration of an arrange. gIconCapsCached gates the cache to the arrange path,
// which touches a single model class; the dock path -- which mixes page and dock
// models -- leaves it off and keeps probing per call, so a cached selector is
// never sent to a model of a different class that may not implement it.
static bool gIconCapsCached = false;
static int gRemoveSel = -1;   // 0 removeIcon:, 1 removeIconAtIndex:, 2 unsupported
static int gInsertSel = -1;   // 0 insertIcon:atIndex:, 1 addIcon:, 2 unsupported

static void reset_icon_mutation_caps(void) { gRemoveSel = -1; gInsertSel = -1; }

static int remove_sel_for(uint64_t model)
{
    if (gIconCapsCached && gRemoveSel >= 0) return gRemoveSel;
    int sel = r_responds(model, "removeIcon:") ? 0
            : r_responds(model, "removeIconAtIndex:") ? 1 : 2;
    if (gIconCapsCached) gRemoveSel = sel;
    return sel;
}

static int insert_sel_for(uint64_t model)
{
    if (gIconCapsCached && gInsertSel >= 0) return gInsertSel;
    int sel = r_responds(model, "insertIcon:atIndex:") ? 0
            : r_responds(model, "addIcon:") ? 1 : 2;
    if (gIconCapsCached) gInsertSel = sel;
    return sel;
}

static bool model_can_remove(uint64_t model)
{
    return remove_sel_for(model) != 2;
}

static bool model_can_insert(uint64_t model)
{
    return insert_sel_for(model) != 2;
}

static bool remove_icon_from_model(uint64_t model, uint64_t index, uint64_t icon)
{
    int sel = remove_sel_for(model);
    if (sel == 2) return false;
    if (sel == 0) {
        r_msg2_main(model, "removeIcon:", icon, 0, 0, 0);
    } else {
        r_msg2_main(model, "removeIconAtIndex:", index, 0, 0, 0);
    }
    return true;
}

static bool insert_icon_into_model(uint64_t model, uint64_t index, uint64_t icon)
{
    int sel = insert_sel_for(model);
    if (sel == 2) return false;
    if (sel == 0) {
        r_msg2_main(model, "insertIcon:atIndex:", icon, index, 0, 0);
    } else {
        r_msg2_main(model, "addIcon:", icon, 0, 0, 0);
    }
    return true;
}

static uint64_t icon_array_count(uint64_t model);

static bool auto_add_app_to_dock(uint64_t iconCtrl, int dockIcons, const char *bundleID)
{
    if (!bundleID || !bundleID[0]) {
        printf("[SBC:DOCKAPP] no bundle identifier selected\n");
        return false;
    }

    uint64_t mgr = try_msg0(iconCtrl, "iconManager");
    uint64_t dockView = try_msg0(mgr, "dockListView");
    if (!dockView) dockView = try_msg0(iconCtrl, "dockListView");
    uint64_t dockModel = list_view_model(dockView);
    if (!r_is_objc_ptr(dockModel)) {
        printf("[SBC:DOCKAPP] dock model unavailable\n");
        return false;
    }

    uint64_t iconModel = try_msg0(mgr, "iconModel");
    if (!iconModel) iconModel = try_msg0(iconCtrl, "model");
    if (!iconModel) iconModel = try_msg0(iconCtrl, "iconModel");
    if (!r_is_objc_ptr(iconModel) ||
        !r_responds(iconModel, "applicationIconForBundleIdentifier:")) {
        printf("[SBC:DOCKAPP] application icon lookup unavailable\n");
        return false;
    }

    uint64_t bundle = r_nsstr_retained(bundleID);
    uint64_t icon = bundle
        ? r_msg2_main(iconModel, "applicationIconForBundleIdentifier:", bundle, 0, 0, 0)
        : 0;
    release_remote_object(bundle);
    if (!r_is_objc_ptr(icon)) {
        // The configured dock app simply isn't installed on this device. That is
        // not a failure of the home-screen customization — there's just nothing to
        // move. Returning false here marked the whole SBCustomizer apply as failed
        // (ok = arrangeOK && dockAppOK), which showed a spurious "pending change"
        // on devices without that app (e.g. iOS 17 test devices without Watusi).
        printf("[SBC:DOCKAPP] app not installed bundle=%s — skipping (not a failure)\n", bundleID);
        return true;
    }

    uint64_t dockIconsArray = model_icons_retained(dockModel);
    uint64_t dockMatchIndex = 0;
    uint64_t dockMatch = find_icon_in_array_by_bundle(
        dockIconsArray, dockView, bundleID, &dockMatchIndex);
    if (r_is_objc_ptr(dockMatch)) {
        release_remote_object(dockIconsArray);
        printf("[SBC:DOCKAPP] already in dock bundle=%s\n", bundleID);
        return true;
    }
    uint64_t dockCount = r_is_objc_ptr(dockIconsArray)
        ? r_msg2_main(dockIconsArray, "count", 0, 0, 0, 0) : 0;
    release_remote_object(dockIconsArray);
    if (dockCount >= (uint64_t)dockIcons) {
        printf("[SBC:DOCKAPP] dock full count=%llu capacity=%d bundle=%s\n",
               dockCount, dockIcons, bundleID);
        return false;
    }

    uint64_t rootFolder = try_msg0(mgr, "rootFolderController");
    uint64_t sourceModel = 0;
    uint64_t sourceIndex = 0;
    uint64_t sourcePage = UINT64_MAX;
    if (r_is_objc_ptr(rootFolder) &&
        r_responds(rootFolder, "iconListViewCount") &&
        r_responds(rootFolder, "iconListViewAtIndex:")) {
        uint64_t pages = r_msg2_main(rootFolder, "iconListViewCount", 0, 0, 0, 0);
        uint64_t limit = pages < 64 ? pages : 64;
        for (uint64_t i = 0; i < limit; i++) {
            uint64_t listView = r_msg2_main(rootFolder, "iconListViewAtIndex:", i, 0, 0, 0);
            uint64_t candidate = list_view_model(listView);
            uint64_t icons = model_icons_retained(candidate);
            uint64_t matched = find_icon_in_array_by_bundle(
                icons, listView, bundleID, &sourceIndex);
            if (!r_is_objc_ptr(matched)) {
                release_remote_object(icons);
                continue;
            }
            uint64_t retainedIcon = retain_remote_object(matched);
            uint64_t retainedModel = retain_remote_object(candidate);
            release_remote_object(icons);
            if (!retainedIcon || !retainedModel) {
                release_remote_object(retainedIcon);
                release_remote_object(retainedModel);
                continue;
            }
            icon = retainedIcon;
            sourceModel = retainedModel;
            sourcePage = i;
            break;
        }
    }
    if (!r_is_objc_ptr(sourceModel)) {
        printf("[SBC:DOCKAPP] top-level source not found; refusing duplicate insertion bundle=%s\n",
               bundleID);
        return false;
    }

    bool canRemove = model_can_remove(sourceModel);
    bool canInsert = model_can_insert(dockModel);
    if (!canRemove || !canInsert) {
        printf("[SBC:DOCKAPP] mutation selectors unavailable remove=%d insert=%d\n",
               canRemove, canInsert);
        release_remote_object(sourceModel);
        release_remote_object(icon);
        return false;
    }

    uint64_t sourceCountBefore = icon_array_count(sourceModel);
    if (!remove_icon_from_model(sourceModel, sourceIndex, icon)) {
        printf("[SBC:DOCKAPP] source removal selector unavailable\n");
        release_remote_object(sourceModel);
        release_remote_object(icon);
        return false;
    }
    release_remote_object(sourceModel);

    // Removing an icon can rebuild every list model. Reacquire the Dock
    // model before inserting instead of messaging the pre-removal pointer.
    mgr = try_msg0(iconCtrl, "iconManager");
    rootFolder = try_msg0(mgr, "rootFolderController");
    uint64_t sourceCountAfter = UINT64_MAX;
    for (int attempt = 0; attempt < 5; attempt++) {
        uint64_t sourceView = r_msg2_main(
            rootFolder, "iconListViewAtIndex:", sourcePage, 0, 0, 0);
        sourceCountAfter = icon_array_count(list_view_model(sourceView));
        if (sourceCountBefore != UINT64_MAX &&
            sourceCountAfter + 1 == sourceCountBefore) break;
        usleep(5000);
        mgr = try_msg0(iconCtrl, "iconManager");
        rootFolder = try_msg0(mgr, "rootFolderController");
    }
    if (sourceCountBefore == UINT64_MAX ||
        sourceCountAfter + 1 != sourceCountBefore) {
        printf("[SBC:DOCKAPP] page[%llu] removal count mismatch %llu -> %llu; aborting Dock insert\n",
               sourcePage, sourceCountBefore, sourceCountAfter);
        release_remote_object(icon);
        return false;
    }

    dockView = try_msg0(mgr, "dockListView");
    if (!dockView) dockView = try_msg0(iconCtrl, "dockListView");
    dockModel = list_view_model(dockView);
    bool inserted = insert_icon_into_model(dockModel, dockCount, icon);
    mgr = try_msg0(iconCtrl, "iconManager");
    dockView = try_msg0(mgr, "dockListView");
    dockModel = list_view_model(dockView);
    uint64_t verifyIcons = model_icons_retained(dockModel);
    inserted = inserted && r_is_objc_ptr(find_icon_in_array_by_bundle(
        verifyIcons, dockView, bundleID, NULL)) &&
        icon_array_count(dockModel) == dockCount + 1;
    release_remote_object(verifyIcons);
    if (!inserted) {
        printf("[SBC:DOCKAPP] insertion failed; restoring page[%llu]\n", sourcePage);
        rootFolder = try_msg0(mgr, "rootFolderController");
        uint64_t restoreView = r_msg2_main(
            rootFolder, "iconListViewAtIndex:", sourcePage, 0, 0, 0);
        insert_icon_into_model(list_view_model(restoreView), sourceIndex, icon);
        release_remote_object(icon);
        return false;
    }

    if (r_responds(dockView, "setNeedsLayout")) {
        r_perform_main(dockView, r_sel("setNeedsLayout"), 0, false);
    }
    release_remote_object(icon);
    printf("[SBC:DOCKAPP] moved bundle=%s to dock index=%llu\n", bundleID, dockCount);
    return true;
}

// Hide the app-name labels on iOS 17. The layout configs expose no label toggle
// there (issue #7: the provider-level setShowsLabels: works on iOS 18 but is a
// no-op on 17); the lever is per icon view — SBIconView responds to
// -setLabelHidden:. Called after the grid/arrange so moved or rebuilt views are
// covered, and from the Hide Labels live loop.
//
// Same fast path as the HSSCALE icon resize: only -subviews is fetched on the
// main thread (a worker-thread view walk PAC-crashes SpringBoard); the retained
// snapshot is read on the worker thread, and the mutation is one prebuilt
// -setLabelHidden: invocation retargeted per view plus a direct
// performSelectorOnMainThread: of -_updateLabel. ~5 round trips per icon
// instead of ~5 main-thread hops (~115).
static int set_icon_views_label_hidden(uint64_t listView, uint64_t wantHidden,
                                       uint64_t *invHidden, int *changed)
{
    uint64_t clsIconView = r_class("SBIconView");
    uint64_t selIsHidden = r_sel("isLabelHidden");
    uint64_t selUpdate   = r_sel("_updateLabel");
    if (!r_is_objc_ptr(listView) || !clsIconView) return 0;

    uint64_t subs = r_msg2_main_retained(listView, "subviews");
    if (!subs) return 0;
    uint64_t views[512];
    int n = r_array_items_of_class(subs, clsIconView, views, 512);
    for (int i = 0; i < n; i++) {
        uint64_t v = views[i];
        // BOOL return: only the low byte is defined.
        if ((r_msg(v, selIsHidden, 0, 0, 0, 0) & 0xff) == wantHidden) continue;   // already right
        if (!*invHidden) {
            uint8_t arg = wantHidden ? 1 : 0;
            *invHidden = r_invocation_retained(v, "setLabelHidden:", &arg, sizeof(arg));
            if (!*invHidden) break;
        }
        r_invocation_invoke_main(*invHidden, v);
        r_perform_main(v, selUpdate, 0, true);
        (*changed)++;
    }
    r_release(subs);
    return n;
}

static int hide_home_icon_labels(uint64_t iconCtrl)
{
    uint64_t mgr = try_msg0(iconCtrl, "iconManager");
    uint64_t rootFolder = try_msg0(mgr, "rootFolderController");
    if (!r_is_objc_ptr(rootFolder) ||
        !r_responds(rootFolder, "iconListViewCount") ||
        !r_responds(rootFolder, "iconListViewAtIndex:")) {
        printf("[SBC] labels: no list-view accessors\n");
        return 0;
    }
    if (!r_class("SBIconView") || !r_sel("setLabelHidden:")) {
        printf("[SBC] labels: SBIconView/setLabelHidden: missing\n");
        return 0;
    }

    uint64_t pages = r_msg2_main(rootFolder, "iconListViewCount", 0, 0, 0, 0);
    if (pages > 64) pages = 64;
    int hidden = 0;
    uint64_t invHidden = 0;
    for (uint64_t p = 0; p < pages; p++) {
        uint64_t lv = r_msg2_main(rootFolder, "iconListViewAtIndex:", p, 0, 0, 0);
        set_icon_views_label_hidden(lv, 1, &invHidden, &hidden);
    }
    r_release(invHidden);
    if (hidden) printf("[SBC] labels: hid %d icon view(s)\n", hidden);
    return hidden;
}

// Public entry point: resolve the icon controller and hide labels. Called as the
// LAST home-screen step (after HSSCALE's relayout) so our own relayout can't undo
// it. Returns the number of icon views hidden.
int sbcustomizer_hide_home_labels_in_session(void)
{
    uint64_t cls = r_class("SBIconController");
    uint64_t iconCtrl = cls ? r_msg2(cls, "sharedInstance", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(iconCtrl)) { printf("[SBC] labels: no SBIconController\n"); return 0; }
    return hide_home_icon_labels(iconCtrl);
}

// Durable iOS 17 Hide Labels: instead of chasing per-view setLabelHidden: with a
// live loop, repoint -[SBIconView _shouldShowLabel] at -[NSObject isProxy] (which
// returns NO) via a remote method_setImplementation. Every icon view then computes
// "no label" at build time — including off-screen pages when they are lazily
// rebuilt on a swipe — so labels stay hidden across swipes and lock/unlock with no
// polling and no keep-alive. method_setImplementation runs inside SpringBoard so it
// signs the new IMP (PAC) itself, and isProxy is a real in-image function, so there
// is no gadget to hunt or pointer to forge. The original IMP is saved so the toggle
// can restore it (a respring also clears it). Same technique as the iOS 17 App
// Library disable (ds_force_method_zero in darksword_tweaks.m).
// The genuine original -[SBIconView _shouldShowLabel] IMP, captured when WE install
// the hook, so an explicit toggle-off can put it back. Only valid within the same
// SpringBoard session that installed it; a respring makes it stale, so it is dropped
// as soon as we observe the hook is no longer live (see the hook-active check).
static uint64_t g_labels_shouldshow_old_imp = 0;

// The mirror of the hide hook, for Dock Labels on iOS 17.
//
// -[NSObject isProxy] returns NO and -[NSProxy isProxy] returns YES: a
// documented pair of real in-image functions with the same signature, so the
// same method_setImplementation trick points _shouldShowLabel at either answer
// with no gadget to hunt and no pointer to forge. SpringBoard signs the IMP
// (PAC) itself, as it does for the NO direction above.
//
// Both directions write the SAME method, so Hide Labels and Dock Labels cannot
// both hold it on iOS 17. The caller checks that; this just resolves.
static int labels_resolve_show_hook(uint64_t *methodOut, uint64_t *trueIMPOut)
{
    uint64_t clsIconView   = r_class("SBIconView");
    uint64_t selShouldShow = r_sel("_shouldShowLabel");
    uint64_t NSProxy       = r_class("NSProxy");
    uint64_t selTrue       = r_sel("isProxy");   // -[NSProxy isProxy] => YES
    if (!r_is_objc_ptr(clsIconView) || !selShouldShow ||
        !r_is_objc_ptr(NSProxy) || !selTrue) return 0;
    uint64_t method = r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod",
                                   clsIconView, selShouldShow, 0, 0, 0, 0, 0, 0);
    uint64_t trueMethod = r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod",
                                       NSProxy, selTrue, 0, 0, 0, 0, 0, 0);
    uint64_t trueIMP = trueMethod
        ? r_dlsym_call(R_TIMEOUT, "method_getImplementation",
                       trueMethod, 0, 0, 0, 0, 0, 0, 0)
        : 0;
    if (!method || !trueIMP) return 0;

    // Sanity: NSProxy's isProxy must be a DIFFERENT function from NSObject's,
    // or we would be installing the NO answer while believing it is YES.
    uint64_t NSObject = r_class("NSObject");
    uint64_t falseMethod = NSObject
        ? r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod",
                       NSObject, selTrue, 0, 0, 0, 0, 0, 0)
        : 0;
    uint64_t falseIMP = falseMethod
        ? r_dlsym_call(R_TIMEOUT, "method_getImplementation",
                       falseMethod, 0, 0, 0, 0, 0, 0, 0)
        : 0;
    if (falseIMP && falseIMP == trueIMP) {
        printf("[SBC] dock labels: NSProxy/NSObject isProxy share an IMP; refusing to hook\n");
        return 0;
    }

    if (methodOut)  *methodOut = method;
    if (trueIMPOut) *trueIMPOut = trueIMP;
    return 1;
}

// Install the YES answer. Only called once the probe has shown that this dock
// icon's _shouldShowLabel really does answer NO -- that is the condition where
// this is the right lever, and the only one where it is worth rewriting a
// method table inside SpringBoard.
int sbcustomizer_swizzle_labels_shown(void)
{
    uint64_t method = 0, trueIMP = 0;
    if (!labels_resolve_show_hook(&method, &trueIMP)) {
        printf("[SBC] dock labels: show hook unavailable (no session or selector missing)\n");
        return 0;
    }
    // Same idempotence rule as the hide hook: never rewrite a live method table
    // that already holds our IMP. Re-writing it (and flushing the cache) while
    // SpringBoard animates icons can branch through a half-updated IMP.
    uint64_t curIMP = r_dlsym_call(R_TIMEOUT, "method_getImplementation",
                                   method, 0, 0, 0, 0, 0, 0, 0);
    if (curIMP == trueIMP) {
        printf("[SBC] dock labels: _shouldShowLabel already forced YES; leaving as-is\n");
        return 1;
    }
    uint64_t oldIMP = r_dlsym_call(R_TIMEOUT, "method_setImplementation",
                                   method, trueIMP, 0, 0, 0, 0, 0, 0);
    if (oldIMP && oldIMP != trueIMP) g_labels_shouldshow_old_imp = oldIMP;
    printf("[SBC] dock labels: swizzled SBIconView._shouldShowLabel -> YES oldIMP=0x%llx\n",
           oldIMP);
    return oldIMP != 0;
}

// Resolve the pieces once. Returns 0 (and leaves outs untouched) if unavailable
// (e.g. no live SpringBoard session yet).
static int labels_resolve_hook(uint64_t *methodOut, uint64_t *falseIMPOut)
{
    uint64_t clsIconView  = r_class("SBIconView");
    uint64_t selShouldShow = r_sel("_shouldShowLabel");
    uint64_t NSObject     = r_class("NSObject");
    uint64_t selFalse     = r_sel("isProxy");   // -(BOOL)isProxy => NO
    if (!r_is_objc_ptr(clsIconView) || !selShouldShow ||
        !r_is_objc_ptr(NSObject) || !selFalse) return 0;
    uint64_t method = r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod",
                                   clsIconView, selShouldShow, 0, 0, 0, 0, 0, 0);
    uint64_t falseMethod = r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod",
                                        NSObject, selFalse, 0, 0, 0, 0, 0, 0);
    uint64_t falseIMP = falseMethod
        ? r_dlsym_call(R_TIMEOUT, "method_getImplementation",
                       falseMethod, 0, 0, 0, 0, 0, 0, 0)
        : 0;
    if (!method || !falseIMP) return 0;
    if (methodOut)   *methodOut = method;
    if (falseIMPOut) *falseIMPOut = falseIMP;
    return 1;
}

// Authoritative: read SpringBoard's LIVE _shouldShowLabel IMP and compare it to
// isProxy's. This is the truth (the hook lives in SpringBoard's method table, not in
// our process), so it correctly reports "gone" after a respring even though our
// process is still running. Needs a live session; returns 0 if it can't check.
int sbcustomizer_home_labels_hook_active(void)
{
    uint64_t method = 0, falseIMP = 0;
    if (!labels_resolve_hook(&method, &falseIMP)) return 0;
    uint64_t curIMP = r_dlsym_call(R_TIMEOUT, "method_getImplementation",
                                   method, 0, 0, 0, 0, 0, 0, 0);
    int active = (curIMP && curIMP == falseIMP) ? 1 : 0;
    // If the hook is gone (respring), any saved "original" is from a dead session
    // and must not be used to restore — drop it.
    if (!active) g_labels_shouldshow_old_imp = 0;
    return active;
}

// Drop our saved-original record WITHOUT touching SpringBoard. Used when the session
// died; the hook (if any) stays in SpringBoard and is re-detected authoritatively.
void sbcustomizer_forget_home_labels_hook_state(void)
{
    g_labels_shouldshow_old_imp = 0;
}

int sbcustomizer_swizzle_home_labels_hidden(void)
{
    uint64_t method = 0, falseIMP = 0;
    if (!labels_resolve_hook(&method, &falseIMP)) {
        printf("[SBC] labels: hook unavailable (no session or selector missing)\n");
        return 0;
    }
    // Idempotent against the LIVE method table: if _shouldShowLabel already points at
    // our NO-IMP, do NOT rewrite it. Re-writing the table (with its cache flush) while
    // SpringBoard animates icons races with concurrent objc_msgSend on its worker
    // threads and can branch through a half-updated IMP -> crash. So we only ever
    // write when the hook is genuinely absent (first apply, or after a respring).
    uint64_t curIMP = r_dlsym_call(R_TIMEOUT, "method_getImplementation",
                                   method, 0, 0, 0, 0, 0, 0, 0);
    if (curIMP == falseIMP) {
        printf("[SBC] labels: _shouldShowLabel already hooked; leaving as-is\n");
        return 1;
    }
    uint64_t oldIMP = r_dlsym_call(R_TIMEOUT, "method_setImplementation",
                                   method, falseIMP, 0, 0, 0, 0, 0, 0);
    if (oldIMP && oldIMP != falseIMP) g_labels_shouldshow_old_imp = oldIMP;
    printf("[SBC] labels: swizzled SBIconView._shouldShowLabel -> NO oldIMP=0x%llx\n",
           oldIMP);
    return oldIMP != 0;
}

int sbcustomizer_restore_home_labels(void)
{
    if (!g_labels_shouldshow_old_imp) return 0;   // nothing we can safely restore
    uint64_t method = 0, falseIMP = 0;
    if (!labels_resolve_hook(&method, &falseIMP)) return 0;
    // Only restore if OUR hook is still the current IMP; otherwise a respring already
    // cleared it and the saved pointer is stale. Either direction counts: Hide Labels
    // installs the NO answer and Dock Labels the YES one, both over this same method.
    uint64_t trueIMP = 0, showMethod = 0;
    (void)labels_resolve_show_hook(&showMethod, &trueIMP);
    uint64_t curIMP = r_dlsym_call(R_TIMEOUT, "method_getImplementation",
                                   method, 0, 0, 0, 0, 0, 0, 0);
    if (curIMP != falseIMP && !(trueIMP && curIMP == trueIMP)) {
        g_labels_shouldshow_old_imp = 0;
        return 0;
    }
    r_dlsym_call(R_TIMEOUT, "method_setImplementation",
                 method, g_labels_shouldshow_old_imp, 0, 0, 0, 0, 0, 0);
    printf("[SBC] labels: restored SBIconView._shouldShowLabel\n");
    g_labels_shouldshow_old_imp = 0;
    return 1;
}

// Cheap identity of the currently-shown home-screen page (its SBIconListView
// pointer). The live loop polls this every tick and only does the full label
// walk when it changes (a swipe), so it can poll fast without hammering.
uint64_t sbcustomizer_current_page_token(void)
{
    uint64_t cls = r_class("SBIconController");
    uint64_t iconCtrl = cls ? r_msg2(cls, "sharedInstance", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(iconCtrl)) return 0;
    uint64_t mgr = try_msg0(iconCtrl, "iconManager");
    uint64_t rootFolder = try_msg0(mgr, "rootFolderController");
    if (!r_is_objc_ptr(rootFolder) || !r_responds_main(rootFolder, "currentIconListView"))
        return 0;
    return r_msg2_main(rootFolder, "currentIconListView", 0, 0, 0, 0);
}

static int patch_homescreen_list_models_v3(uint64_t mgr, int cols, int rows)
{
    uint64_t rootFolder = try_msg0(mgr, "rootFolderController");
    if (!r_is_objc_ptr(rootFolder)) {
        printf("[SBC] v3: nil rootFolderController\n");
        return 0;
    }

    int touched = 0;
    if (r_responds(rootFolder, "iconListViewCount") &&
        r_responds(rootFolder, "iconListViewAtIndex:")) {
        uint64_t count = r_msg2(rootFolder, "iconListViewCount", 0, 0, 0, 0);
        uint64_t limit = count < 64 ? count : 64;
        printf("[SBC] v3: iconListViewCount=%llu\n", count);
        for (uint64_t i = 0; i < limit; i++) {
            uint64_t listView = r_msg2(rootFolder, "iconListViewAtIndex:", i, 0, 0, 0);
            if (!r_is_objc_ptr(listView)) continue;

            char tag[32];
            snprintf(tag, sizeof(tag), "page[%llu]", i);
            disable_list_autofit(listView, tag);
            if (patch_list_model_grid(listView, tag, cols, rows)) touched++;
        }
    } else if (r_responds(rootFolder, "currentIconListView")) {
        uint64_t current = r_msg2(rootFolder, "currentIconListView", 0, 0, 0, 0);
        disable_list_autofit(current, "currentIconListView");
        if (patch_list_model_grid(current, "currentIconListView", cols, rows)) touched++;
    } else {
        printf("[SBC] v3: no list-view accessor path\n");
    }

    uint64_t dockListView = try_msg0(mgr, "dockListView");
    if (r_is_objc_ptr(dockListView)) {
        disable_list_autofit(dockListView, "dockListView");
    }

    printf("[SBC] v3: patched home list models=%d\n", touched);
    return touched;
}

// iOS 18: force the icon-label switch off for a given icon location via the list
// layout provider. The home screen (SBIconLocationRoot) is handled inline in
// patch_homescreen_grid; each OTHER location (notably folders) has its own layout
// configuration, so the root setShowsLabels: does not reach it — that is why Hide
// Labels left folder icons labelled. Safe no-op if the location, config, or
// selector is absent (and on iOS 17, where setShowsLabels: is a no-op — the
// process-wide _shouldShowLabel swizzle already covers folder icons there).
static bool set_shows_labels_for_location(uint64_t provider, const char *locName, bool shows)
{
    if (!provider || !locName) return false;
    uint64_t loc = r_cfstr(locName);
    if (!loc || !r_responds(provider, "layoutForIconLocation:")) return false;
    uint64_t layout = r_msg2(provider, "layoutForIconLocation:", loc, 0, 0, 0);
    if (!layout) { printf("[SBC] labels: no layout for %s\n", locName); return false; }
    uint64_t cfg = try_msg0(layout, "layoutConfiguration");
    if (!r_is_objc_ptr(cfg) || !r_responds(cfg, "setShowsLabels:")) {
        printf("[SBC] labels: %s cfg lacks setShowsLabels:\n", locName);
        return false;
    }
    r_msg2(cfg, "setShowsLabels:", shows ? 1 : 0, 0, 0, 0);
    printf("[SBC] labels: showsLabels=%s for %s\n", shows ? "YES" : "NO", locName);
    return true;
}

// Dock labels. Stock iOS draws the dock without app names; the same two levers
// Hide Labels uses can put them back, pointed the other way.
//
//  * iOS 18: the dock is its own icon location with its own layout
//    configuration, so setShowsLabels: on it survives relayouts. This is also
//    why Dock Labels and Hide Labels do not fight on 18 -- Hide Labels only
//    touches SBIconLocationRoot and SBIconLocationFolder.
//  * iOS 17: setShowsLabels: is a no-op there (issue #7), so clear
//    setLabelHidden: on each of the dock's own SBIconViews instead. The walk
//    runs on the main thread; a worker-thread view walk PAC-crashes
//    SpringBoard, same as the home-screen one above.
//
// The per-view pass runs on both versions: on 18 it makes the change visible
// immediately instead of waiting for the next relayout.
//
// Caveat on iOS 17: Hide Labels installs a process-wide _shouldShowLabel hook
// that answers NO for every SBIconView, the dock included. While that hook is
// up a rebuilt dock icon comes back unlabelled no matter what is set here.
static int set_dock_icon_labels(uint64_t iconCtrl, bool show, bool mayForceShowLabels)
{
    uint64_t mgr = try_msg0(iconCtrl, "iconManager");
    if (!mgr) { printf("[SBC] dock labels: nil iconManager\n"); return 0; }

    // Durable lever first, so a later relayout keeps the setting.
    uint64_t provider = try_msg0(mgr, "listLayoutProvider");
    if (provider) {
        set_shows_labels_for_location(provider, "SBIconLocationDock", show);
    }

    uint64_t dock = try_msg0(mgr, "dockListView");
    if (!dock) dock = try_msg0(iconCtrl, "dockListView");
    if (!r_is_objc_ptr(dock)) { printf("[SBC] dock labels: nil dockListView\n"); return 0; }

    uint64_t clsIconView = r_class("SBIconView");
    uint64_t selIsHidden = r_sel("isLabelHidden");
    if (!clsIconView || !r_sel("setLabelHidden:")) {
        printf("[SBC] dock labels: SBIconView/setLabelHidden: missing\n");
        return 0;
    }

    // Report what the first dock icon actually exposes. Clearing labelHidden
    // on four real icon views changed nothing on iOS 17 (chain log
    // 20261004-113402), and the guess that fits both that and Hide Labels
    // working is that _updateLabel computes "_shouldShowLabel && !labelHidden"
    // -- NO for a dock icon either way. Print the pieces rather than keep
    // inferring them. Runs before the relabel pass below, so a forced YES
    // gives that pass something to build.
    uint64_t subs = r_msg2_main_retained(dock, "subviews");
    uint64_t first = 0;
    if (subs) r_array_items_of_class(subs, clsIconView, &first, 1);
    r_release(subs);
    if (first) {
        uint64_t v = first;
        uint64_t selShouldShow = r_sel("_shouldShowLabel");
        int responds = selShouldShow ? r_responds(v, "_shouldShowLabel") : 0;
        uint64_t shouldShow = responds ? r_msg_main(v, selShouldShow, 0, 0, 0, 0) : 2;
        printf("[SBC] dock labels: probe labelHidden=%llu _shouldShowLabel=%s"
               " labelView=%d _labelView=%d iconLabelView=%d alpha=%d\n",
               (unsigned long long)r_msg_main(v, selIsHidden, 0, 0, 0, 0),
               responds ? (shouldShow ? "YES" : "NO") : "absent",
               r_responds(v, "labelView"),
               r_responds(v, "_labelView"),
               r_responds(v, "iconLabelView"),
               r_responds(v, "setIconLabelAlpha:"));

        // Clearing labelHidden is not enough when the icon itself answers
        // "no label here": _updateLabel takes both into account. Force the
        // answer to YES, but only on the evidence of this probe -- never
        // speculatively, because this rewrites a method table inside a live
        // SpringBoard.
        if (show && responds && !shouldShow) {
            if (!mayForceShowLabels) {
                // Caller withheld permission (Hide icon labels holds this same
                // method). Today the caller also passes show=false in that case,
                // so this is belt and braces rather than a path you should see.
                printf("[SBC] dock labels: _shouldShowLabel=NO and forcing not allowed; "
                       "dock follows the home screen\n");
            } else if (sbcustomizer_swizzle_labels_shown()) {
                printf("[SBC] dock labels: forced _shouldShowLabel=YES for this session\n");
            }
        }
    }

    int changed = 0;
    uint64_t invHidden = 0;
    set_icon_views_label_hidden(dock, show ? 0 : 1, &invHidden, &changed);
    r_release(invHidden);

    printf("[SBC] dock labels: %s on %d icon view(s)\n", show ? "shown" : "hidden", changed);
    return changed;
}

// Public entry point. Called as a late home-screen step, after the dock has been
// resized and any auto-dock move has run, so every icon view that will exist is
// there to be relabelled. Session must be open.
int sbcustomizer_set_dock_labels_in_session(bool show, bool mayForceShowLabels)
{
    uint64_t cls = r_class("SBIconController");
    uint64_t iconCtrl = cls ? r_msg2(cls, "sharedInstance", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(iconCtrl)) { printf("[SBC] dock labels: no SBIconController\n"); return 0; }
    return set_dock_icon_labels(iconCtrl, show, mayForceShowLabels);
}

static void patch_homescreen_grid(uint64_t iconCtrl, int cols, int rows, bool hideLabels)
{
    uint64_t mgr = try_msg0(iconCtrl, "iconManager");
    if (!mgr) { printf("[SBC] hs: nil iconManager\n"); return; }

    uint64_t provider = try_msg0(mgr, "listLayoutProvider");
    if (provider) {

        uint64_t loc = r_cfstr("SBIconLocationRoot");
        if (!loc) {
            printf("[SBC] hs: cfstr failed\n");
        } else if (!r_responds(provider, "layoutForIconLocation:")) {
            printf("[SBC] hs: provider lacks layoutForIconLocation:\n");
        } else {
            uint64_t layout = r_msg2(provider, "layoutForIconLocation:", loc, 0, 0, 0);
            if (!layout) {
                printf("[SBC] hs: nil layout for root\n");
            } else {
                uint64_t cfg = try_msg0(layout, "layoutConfiguration");
                if (!cfg) {
                    printf("[SBC] hs: nil layoutConfiguration\n");
                } else if (!r_responds(cfg, "setNumberOfPortraitColumns:")) {
                    printf("[SBC] hs: cfg lacks setNumberOfPortraitColumns:\n");
                } else {
                    r_msg2(cfg, "setNumberOfPortraitColumns:", (uint64_t)cols, 0, 0, 0);
                    if (r_responds(cfg, "setNumberOfPortraitRows:"))
                        r_msg2(cfg, "setNumberOfPortraitRows:", (uint64_t)rows, 0, 0, 0);
                    if (r_responds(cfg, "setNumberOfLandscapeColumns:"))
                        r_msg2(cfg, "setNumberOfLandscapeColumns:", (uint64_t)rows, 0, 0, 0);
                    if (r_responds(cfg, "setNumberOfLandscapeRows:"))
                        r_msg2(cfg, "setNumberOfLandscapeRows:", (uint64_t)cols, 0, 0, 0);
                    printf("[SBC] hs: provider cols=%d rows=%d\n", cols, rows);

                    if (hideLabels && r_responds(cfg, "setShowsLabels:")) {
                        r_msg2(cfg, "setShowsLabels:", 0, 0, 0, 0);
                        printf("[SBC] hs: showsLabels=NO\n");
                    }
                }
            }
        }

        // Root (home screen) is done above. Folders have their own layout
        // configuration, so extend the label switch to the folder location too.
        if (hideLabels) {
            set_shows_labels_for_location(provider, "SBIconLocationFolder", false);
        }
    } else {
        printf("[SBC] hs: nil listLayoutProvider\n");
    }

    patch_homescreen_list_models_v3(mgr, cols, rows);
}

static bool set_page_icon_capacity(uint64_t listView, int desired, int preferredCols,
                                   const char *tag)
{
    uint64_t model = list_view_model(listView);
    if (!r_is_objc_ptr(model)) return false;

    const char *capacitySetters[] = {
        "setMaximumIconCount:",
        "setMaxIconCount:",
        "setMaximumNumberOfIcons:",
        NULL,
    };
    for (int i = 0; capacitySetters[i]; i++) {
        if (!r_responds(model, capacitySetters[i])) continue;
        r_msg2(model, capacitySetters[i], (uint64_t)desired, 0, 0, 0);
        printf("[SBC:ARRANGE] %s %s -> %d\n", tag, capacitySetters[i], desired);
        return true;
    }

    int bestCols = 0;
    int bestRows = 0;
    int bestDistance = 999;
    for (int cols = 3; cols <= 7; cols++) {
        if (desired % cols != 0) continue;
        int rows = desired / cols;
        if (rows < 4 || rows > 8) continue;
        int distance = cols > preferredCols ? cols - preferredCols : preferredCols - cols;
        if (distance < bestDistance) {
            bestCols = cols;
            bestRows = rows;
            bestDistance = distance;
        }
    }
    if (!bestCols) {
        printf("[SBC:ARRANGE] %s cannot express exact capacity=%d as supported grid\n",
               tag, desired);
        return false;
    }
    return patch_list_model_grid(listView, tag, bestCols, bestRows);
}

static uint64_t icon_array_count(uint64_t model)
{
    uint64_t icons = model_icons_retained(model);
    if (!r_is_objc_ptr(icons)) return UINT64_MAX;
    uint64_t count = r_msg2_main(icons, "count", 0, 0, 0, 0);
    release_remote_object(icons);
    return count;
}

// Do not use CFRetain while redistributing pages. SBIconListModel and its
// icons array can be replaced as a consequence of the preceding grid change.
// Retaining a pointer returned by an earlier RemoteCall is therefore itself
// unsafe: on arm64e CFRetain PAC-crashes when that transient pointer has gone
// stale. Each accessor below is instead completed synchronously on the main
// thread and the result is consumed immediately.
static uint64_t icon_array_count_transient(uint64_t model)
{
    if (!r_is_objc_ptr(model)) return UINT64_MAX;
    uint64_t icons = r_msg2_main(model, "icons", 0, 0, 0, 0);
    if (!r_is_objc_ptr(icons)) return UINT64_MAX;
    return r_msg2_main(icons, "count", 0, 0, 0, 0);
}

// Per-arrange cache of page list views. iconListViewAtIndex: returns the SAME
// list view across icon mutations -- only listView.model is rebuilt -- so once
// we know the view for a page we can skip re-resolving it and re-fetch only the
// model. page_model_at is called ~5x per icon move and dominated the arrange
// cost (~35-40%). Keyed on rootFolder so a different controller can't reuse a
// stale entry; a nil model triggers a one-shot re-resolve in case a view really
// did get torn down. reset_page_view_cache() clears it at each arrange entry.
#define SBC_PAGE_VIEW_CACHE_MAX 64
static uint64_t gPageViewCache[SBC_PAGE_VIEW_CACHE_MAX];
static uint64_t gPageViewCacheRoot;

static void reset_page_view_cache(uint64_t rootFolder)
{
    memset(gPageViewCache, 0, sizeof(gPageViewCache));
    gPageViewCacheRoot = rootFolder;
}

static uint64_t page_model_at(uint64_t rootFolder, uint64_t page)
{
    bool cacheable = (rootFolder == gPageViewCacheRoot &&
                      page < SBC_PAGE_VIEW_CACHE_MAX);
    uint64_t listView = cacheable ? gPageViewCache[page] : 0;
    if (!r_is_objc_ptr(listView)) {
        listView = r_msg2_main(rootFolder, "iconListViewAtIndex:", page, 0, 0, 0);
        if (cacheable) gPageViewCache[page] = listView;
    }
    if (!r_is_objc_ptr(listView)) return 0;
    uint64_t model = r_msg2_main(listView, "model", 0, 0, 0, 0);
    if (!r_is_objc_ptr(model) && cacheable) {
        // Cached view no longer yields a model -- re-resolve once and retry.
        gPageViewCache[page] = 0;
        listView = r_msg2_main(rootFolder, "iconListViewAtIndex:", page, 0, 0, 0);
        if (!r_is_objc_ptr(listView)) return 0;
        gPageViewCache[page] = listView;
        model = r_msg2_main(listView, "model", 0, 0, 0, 0);
    }
    return model;
}

static uint64_t icon_at_index_transient(uint64_t model, uint64_t index)
{
    if (!r_is_objc_ptr(model)) return 0;
    uint64_t icons = r_msg2_main(model, "icons", 0, 0, 0, 0);
    if (!r_is_objc_ptr(icons)) return 0;
    uint64_t count = r_msg2_main(icons, "count", 0, 0, 0, 0);
    if (index >= count) return 0;
    return r_msg2_main(icons, "objectAtIndex:", index, 0, 0, 0);
}

static uint64_t wait_for_page_count(uint64_t rootFolder, uint64_t page,
                                    uint64_t expected)
{
    uint64_t count = UINT64_MAX;
    for (int attempt = 0; attempt < 5; attempt++) {
        count = icon_array_count_transient(page_model_at(rootFolder, page));
        if (count == expected) break;
        usleep(5000);
    }
    return count;
}

static bool move_icon_between_pages(uint64_t rootFolder,
                                    uint64_t sourcePage, uint64_t sourceIndex,
                                    uint64_t destinationPage, uint64_t destinationIndex,
                                    uint64_t sourceCountBefore,
                                    uint64_t destinationCountBefore,
                                    uint64_t icon, const char *tag)
{
    uint64_t sourceModel = page_model_at(rootFolder, sourcePage);
    uint64_t destinationModel = page_model_at(rootFolder, destinationPage);
    if (!r_is_objc_ptr(sourceModel) || !r_is_objc_ptr(destinationModel) ||
        !r_is_objc_ptr(icon)) {
        printf("[SBC:MOVE] %s unsupported page mutation\n", tag);
        return false;
    }
    if (sourceCountBefore == UINT64_MAX || destinationCountBefore == UINT64_MAX ||
        sourceIndex >= sourceCountBefore || destinationIndex > destinationCountBefore) {
        printf("[SBC:MOVE] %s invalid counts source=%llu index=%llu destination=%llu index=%llu\n",
               tag, sourceCountBefore, sourceIndex,
               destinationCountBefore, destinationIndex);
        return false;
    }
    if (!remove_icon_from_model(sourceModel, sourceIndex, icon)) return false;
    uint64_t sourceCountAfter = wait_for_page_count(
        rootFolder, sourcePage, sourceCountBefore - 1);
    if (sourceCountAfter != sourceCountBefore - 1) {
        printf("[SBC:MOVE] %s source count mismatch %llu -> %llu\n",
               tag, sourceCountBefore, sourceCountAfter);
        return false;
    }

    // Removal can rebuild the destination page model as well.
    destinationModel = page_model_at(rootFolder, destinationPage);
    if (insert_icon_into_model(destinationModel, destinationIndex, icon)) {
        uint64_t destinationCountAfter = wait_for_page_count(
            rootFolder, destinationPage, destinationCountBefore + 1);
        if (destinationCountAfter == destinationCountBefore + 1) return true;
        printf("[SBC:MOVE] %s destination count mismatch %llu -> %llu\n",
               tag, destinationCountBefore, destinationCountAfter);
    }

    printf("[SBC:MOVE] %s insertion failed; restoring source page\n", tag);
    sourceModel = page_model_at(rootFolder, sourcePage);
    insert_icon_into_model(sourceModel, sourceIndex, icon);
    return false;
}

// Fast move: remove + re-resolve destination + insert, WITHOUT the two
// wait_for_page_count settles move_icon_between_pages does per move. Those
// settles are ~6 remote round trips each move, re-reading a count the caller
// already tracks; the arrange verifies each page's final count once instead (see
// rebalance_impl) and falls back to the settling path if that check ever fails.
// The destination re-resolve is kept -- removal can rebuild the destination page
// model -- and a failed insert still restores the icon to the source page.
static bool move_icon_fast(uint64_t rootFolder,
                           uint64_t sourcePage, uint64_t sourceIndex,
                           uint64_t destinationPage, uint64_t destinationIndex,
                           uint64_t icon, const char *tag)
{
    uint64_t sourceModel = page_model_at(rootFolder, sourcePage);
    if (!r_is_objc_ptr(sourceModel) || !r_is_objc_ptr(icon)) {
        printf("[SBC:MOVE] %s unsupported page mutation\n", tag);
        return false;
    }
    if (!remove_icon_from_model(sourceModel, sourceIndex, icon)) return false;
    uint64_t destinationModel = page_model_at(rootFolder, destinationPage);
    if (!r_is_objc_ptr(destinationModel) ||
        !insert_icon_into_model(destinationModel, destinationIndex, icon)) {
        printf("[SBC:MOVE] %s insertion failed; restoring source page\n", tag);
        sourceModel = page_model_at(rootFolder, sourcePage);
        insert_icon_into_model(sourceModel, sourceIndex, icon);
        return false;
    }
    return true;
}

// fast=true drops the per-move settles and verifies each page's final count once.
// If that single check ever disagrees with the tracked count, the whole arrange
// is re-run with fast=false -- move_icon_between_pages settling every move --
// which re-reads live counts and self-corrects. So a surprise costs a slow
// re-run, never a wrong arrangement.
static int rebalance_impl(uint64_t rootFolder, uint64_t count,
                          int firstPageIcons, int otherPageIcons, bool fast)
{
    int moved = 0;
    bool failed = false;
    reset_page_view_cache(rootFolder);
    // Donor cursor, carried across pages -- see the fill loop below.
    uint64_t donorPage = 0;
    uint64_t donorCount = UINT64_MAX;
    for (uint64_t page = 0; page + 1 < count; page++) {
        uint64_t model = page_model_at(rootFolder, page);
        if (!r_is_objc_ptr(model)) continue;
        uint64_t desired = (uint64_t)(page == 0 ? firstPageIcons : otherPageIcons);
        uint64_t current = icon_array_count_transient(model);
        if (current == UINT64_MAX) {
            printf("[SBC:ARRANGE] page[%llu] icon array unavailable\n", page);
            failed = true;
            continue;
        }
        uint64_t before = current;

        // Push overflow forward. Taking the last icon and inserting it at
        // index zero preserves the original order of the overflow block.
        //
        // destinationCount is carried across iterations: every successful move
        // inserts exactly one icon into page+1, so re-reading it costs four
        // remote round trips to learn a number we already know.
        uint64_t destinationCount = UINT64_MAX;
        while (current > desired) {
            model = page_model_at(rootFolder, page);
            uint64_t iconIndex = current - 1;
            uint64_t icon = icon_at_index_transient(model, iconIndex);
            bool didMove;
            if (fast) {
                didMove = r_is_objc_ptr(icon) &&
                    move_icon_fast(rootFolder, page, iconIndex, page + 1, 0,
                                   icon, "page overflow");
            } else {
                if (destinationCount == UINT64_MAX) {
                    destinationCount = icon_array_count_transient(
                        page_model_at(rootFolder, page + 1));
                }
                didMove = r_is_objc_ptr(icon) &&
                    move_icon_between_pages(rootFolder, page, iconIndex,
                                            page + 1, 0, current, destinationCount,
                                            icon, "page overflow");
                destinationCount++;
            }
            if (!didMove) {
                return -1;
            }
            moved++;
            current--;
        }

        // Fill a short page from the first non-empty later page. This also
        // closes gaps when SpringBoard has left an empty intermediate page.
        //
        // donorPage/donorCount persist across both this loop and the outer page
        // loop. The scan used to restart at page+1 for every single icon, so
        // filling a 25-icon page whose donor sat four pages away re-walked those
        // four pages 25 times over -- and each step of that walk is four remote
        // round trips. Nothing in this function ever puts icons back into a page
        // between `page` and `donorPage`, so once the scan has passed a page it
        // cannot become non-empty again and rescanning it can only confirm what
        // is already known.
        while (current < desired) {
            if (donorPage <= page) {
                donorPage = page + 1;
                donorCount = UINT64_MAX;
            }
            while (donorPage < count) {
                if (donorCount == UINT64_MAX) {
                    donorCount = icon_array_count_transient(
                        page_model_at(rootFolder, donorPage));
                }
                if (donorCount != UINT64_MAX && donorCount > 0) break;
                donorPage++;
                donorCount = UINT64_MAX;
            }
            if (donorPage >= count) break;
            uint64_t donorModel = page_model_at(rootFolder, donorPage);
            uint64_t icon = icon_at_index_transient(donorModel, 0);
            bool didMove;
            if (fast) {
                didMove = r_is_objc_ptr(icon) &&
                    move_icon_fast(rootFolder, donorPage, 0, page, current,
                                   icon, "page fill");
            } else {
                didMove = r_is_objc_ptr(icon) &&
                    move_icon_between_pages(rootFolder, donorPage, 0,
                                            page, current, donorCount, current,
                                            icon, "page fill");
            }
            if (!didMove) {
                return -1;
            }
            moved++;
            current++;
            donorCount--;
        }

        // Batch verify: one settle per page replaces the two-per-move settles.
        // On this path counts update synchronously, so a mismatch means a
        // mutation silently missed -- re-run the whole arrange with per-move
        // verification, which re-reads live counts and self-corrects.
        if (fast) {
            uint64_t verifyCount = wait_for_page_count(rootFolder, page, current);
            if (verifyCount != current) {
                printf("[SBC:ARRANGE] page[%llu] batch verify mismatch "
                       "(expected %llu got %llu); re-running with per-move "
                       "verification\n", page, current, verifyCount);
                return rebalance_impl(rootFolder, count, firstPageIcons,
                                      otherPageIcons, false);
            }
        }

        printf("[SBC:ARRANGE] page[%llu] icons %llu -> %llu target=%llu\n",
               page, before, current == UINT64_MAX ? 0 : current, desired);
    }

    // The drain loop above pushes overflow onto page+1 but never processes the
    // final page -- there is no page+1 to receive its overflow, and no API here
    // to append a home-screen page. When a grid shrink leaves total capacity
    // smaller than the icon count, the surplus piles onto the last page beyond
    // what its grid can display; those icons land off-grid and disappear. That
    // is the intermittent "missing app icon" bug -- a manual re-run only fixed
    // it because SpringBoard's own relayout happened to redistribute them.
    // Guarantee visibility instead: if the last page holds more icons than its
    // grid shows, grow that page's grid (same columns, more rows) to fit them.
    if (!failed && count > 0) {
        uint64_t lastPage  = count - 1;
        uint64_t lastModel = page_model_at(rootFolder, lastPage);
        uint64_t lastCount = icon_array_count_transient(lastModel);
        uint64_t lastCap   = (uint64_t)(lastPage == 0 ? firstPageIcons : otherPageIcons);
        if (r_is_objc_ptr(lastModel) && lastCount != UINT64_MAX && lastCount > lastCap &&
            r_responds(lastModel, "gridSize") && r_responds(lastModel, "setGridSize:")) {
            uint64_t grid = r_msg2(lastModel, "gridSize", 0, 0, 0, 0) & 0xffffffffULL;
            uint64_t cols = grid & 0xffffULL;
            if (cols == 0) cols = 4;
            uint64_t rowsNeeded = (lastCount + cols - 1) / cols;
            uint64_t newGrid = ((rowsNeeded & 0xffffULL) << 16) | (cols & 0xffffULL);
            r_msg2(lastModel, "setGridSize:", newGrid, 0, 0, 0);
            printf("[SBC:ARRANGE] last page[%llu] overflow %llu > cap %llu; grid grown to "
                   "%llux%llu so no icon is left off-grid\n",
                   lastPage, lastCount, lastCap, cols, rowsNeeded);
        }
    }
    return failed ? -1 : moved;
}

static int rebalance_page_models(uint64_t rootFolder, uint64_t count,
                                 int firstPageIcons, int otherPageIcons)
{
    return rebalance_impl(rootFolder, count, firstPageIcons, otherPageIcons, true);
}

static bool arrange_homescreen_pages(uint64_t iconCtrl, int preferredCols,
                                     int firstPageIcons, int otherPageIcons)
{
    uint64_t mgr = try_msg0(iconCtrl, "iconManager");
    uint64_t rootFolder = try_msg0(mgr, "rootFolderController");
    if (!r_is_objc_ptr(rootFolder) ||
        !r_responds(rootFolder, "iconListViewCount") ||
        !r_responds(rootFolder, "iconListViewAtIndex:")) {
        printf("[SBC:ARRANGE] page list accessors unavailable\n");
        return false;
    }

    uint64_t count = r_msg2(rootFolder, "iconListViewCount", 0, 0, 0, 0);
    uint64_t limit = count < 64 ? count : 64;
    int changed = 0;
    for (uint64_t i = 0; i < limit; i++) {
        uint64_t listView = r_msg2(rootFolder, "iconListViewAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(listView)) continue;
        char tag[32];
        snprintf(tag, sizeof(tag), "page[%llu]", i);
        int desired = i == 0 ? firstPageIcons : otherPageIcons;
        if (set_page_icon_capacity(listView, desired, preferredCols, tag)) changed++;
    }

    // Grid changes can rebuild SBIconListView and its model. Never reuse the
    // raw pointers captured before setGridSize:/setNeedsLayout.
    usleep(100000);
    mgr = try_msg0(iconCtrl, "iconManager");
    rootFolder = try_msg0(mgr, "rootFolderController");
    if (!r_is_objc_ptr(rootFolder)) {
        printf("[SBC:ARRANGE] root folder disappeared after capacity update\n");
        return false;
    }
    count = r_msg2_main(rootFolder, "iconListViewCount", 0, 0, 0, 0);
    limit = count < 64 ? count : 64;
    // The rebalance is by far the most expensive part of an SBC apply -- each
    // icon move is a sequence of synchronous main-thread RemoteCalls. Report the
    // real cost rather than leaving it to be guessed at.
    r_perf_reset();
    // Cache the icon-list mutation selectors for the arrange: every page model is
    // the same class, so probing removeIcon:/insertIcon:atIndex: support once and
    // reusing it saves ~5 remote round trips per icon move. Scoped to the arrange
    // via gIconCapsCached so the dock path keeps probing per call.
    reset_icon_mutation_caps();
    gIconCapsCached = true;
    int moved = rebalance_page_models(rootFolder, limit,
                                      firstPageIcons, otherPageIcons);
    gIconCapsCached = false;
    r_perf_report("SBC arrange rebalance");

    // Trigger visual refresh only after all reads and mutations are finished.
    // Running this inside the capacity loop can asynchronously replace the
    // page models and icon arrays while the arranger is still using them.
    mgr = try_msg0(iconCtrl, "iconManager");
    rootFolder = try_msg0(mgr, "rootFolderController");
    if (r_is_objc_ptr(rootFolder)) {
        uint64_t refreshedCount = r_msg2_main(
            rootFolder, "iconListViewCount", 0, 0, 0, 0);
        uint64_t refreshedLimit = refreshedCount < 64 ? refreshedCount : 64;
        for (uint64_t i = 0; i < refreshedLimit; i++) {
            uint64_t listView = r_msg2_main(
                rootFolder, "iconListViewAtIndex:", i, 0, 0, 0);
            // Fire-and-forget, as in patch_dock: one round trip instead of
            // an NSInvocation build per page.
            if (r_is_objc_ptr(listView) && r_responds(listView, "setNeedsLayout")) {
                r_perform_main(listView, r_sel("setNeedsLayout"), 0, false);
            }
        }
    }
    printf("[SBC:ARRANGE] pages=%llu capacities=%d moved=%d first=%d others=%d\n",
           limit, changed, moved, firstPageIcons, otherPageIcons);
    return changed > 0 && moved >= 0;
}

bool sbcustomizer_apply_in_session(int dockIcons, int hsCols, int hsRows, bool hideLabels,
                                   bool arrangePages, int firstPageIcons, int otherPageIcons,
                                   bool autoDockApp, const char *dockAppBundleID)
{
    // The shared Objective-C helper normally leaves 50 ms after every
    // message. Page redistribution can issue hundreds of synchronous
    // main-thread messages, turning that safety delay into a long pause.
    // These calls already wait for main-thread completion. Avoid adding a
    // settle delay to every selector lookup and message in a redistribution;
    // mutation verification below provides the required synchronization.
    // (The fixed 50 ms sleeps that used to sit between the property gets/sets
    // in patch_dock / patch_homescreen_grid were the same delay hard-coded;
    // those calls are synchronous too, so they are gone.)
    uint32_t oldSettleUS = r_settle_us(0);
    dockIcons = clamp(dockIcons, 4, 7);
    hsCols    = clamp(hsCols,    3, 7);
    hsRows    = clamp(hsRows,    4, 8);
    firstPageIcons = clamp(firstPageIcons, 12, 49);
    otherPageIcons = clamp(otherPageIcons, 12, 49);
    printf("[SBC] === entry === dock=%d hs=%dx%d hideLabels=%d arrange=%d first=%d others=%d autoDock=%d bundle=%s\n",
           dockIcons, hsCols, hsRows, hideLabels,
           arrangePages, firstPageIcons, otherPageIcons, autoDockApp,
           dockAppBundleID ?: "");

    bool ok = false;
    do {
        usleep(100000);
        uint64_t cls = r_class("SBIconController");
        if (!cls) { printf("[SBC] SBIconController missing\n"); break; }

        uint64_t iconCtrl = r_msg2(cls, "sharedInstance", 0, 0, 0, 0);
        if (!iconCtrl) { printf("[SBC] +sharedInstance nil\n"); break; }
        printf("[SBC] iconCtrl=0x%llx\n", iconCtrl);

        patch_dock(iconCtrl, dockIcons);
        bool dockAppOK = true;
        if (autoDockApp && dockIcons > 4) {
            dockAppOK = auto_add_app_to_dock(iconCtrl, dockIcons, dockAppBundleID);
        } else if (autoDockApp) {
            printf("[SBC:DOCKAPP] deferred until Dock capacity is above four\n");
        }
        patch_homescreen_grid(iconCtrl, hsCols, hsRows, hideLabels);
        bool arrangeOK = true;
        if (arrangePages) {
            arrangeOK = arrange_homescreen_pages(
                iconCtrl, hsCols, firstPageIcons, otherPageIcons);
        }
        // NOTE: label hiding for iOS 17 is applied as the LAST home-screen step
        // (after RUN 5 / HSSCALE) via sbcustomizer_hide_home_labels_in_session(),
        // so our own relayout can't undo it. The provider-config setShowsLabels:
        // in patch_homescreen_grid still runs (the working lever on iOS 18).
        ok = arrangeOK && dockAppOK;
    } while (0);

    r_settle_us(oldSettleUS);
    return ok;
}

bool sbcustomizer_apply(int dockIcons, int hsCols, int hsRows, bool hideLabels,
                        bool arrangePages, int firstPageIcons, int otherPageIcons,
                        bool autoDockApp, const char *dockAppBundleID)
{
    if (init_remote_call("SpringBoard", false) != 0) {
        printf("[SBC] init_remote_call(SpringBoard) failed\n");
        return false;
    }

    bool ok = sbcustomizer_apply_in_session(dockIcons, hsCols, hsRows, hideLabels,
                                            arrangePages, firstPageIcons, otherPageIcons,
                                            autoDockApp, dockAppBundleID);
    destroy_remote_call();
    return ok;
}
