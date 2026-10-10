//
//  darksword_layout.m
//  Verbatim port of kolbicz/DarkSword-Tweaks dock_and_home_spacing.m and
//  dock_and_homescreen_scaling.m, retargeted to our remote_objc / RemoteCall
//  helpers. The session is assumed already open (we're called under
//  settings_rc_lock with g_springboard_rc_ready=1), so init/destroy bookends
//  from the original sources are dropped.
//

#import "darksword_layout.h"
#import "remote_objc.h"
#import "sb_walk.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

// Two SpringBoard shapes ship in this binary:
//   iOS 18  — the upstream kolbicz path: SBIconController.iconManager
//             (an SBIconManager), .listLayoutProvider, .relayout +
//             layoutIconListsWithAnimationType:forceRelayout: as the apply
//             trigger.
//   iOS 26+ — Apple moved the home-screen object graph into the
//             SpringBoardHome framework. The icon manager class is now
//             SBHIconManager and its _listLayoutProvider ivar is nil-by-
//             default; layoutIconListsWithAnimationType:forceRelayout:
//             still exists but invoking it from RemoteCall crashes
//             SpringBoard (likely an internal state precondition that's
//             only true mid-run-loop). The iOS 26 path instead pulls the
//             provider from -[SBIconController listLayoutProvider] (which
//             redirects to ambientListLayoutProvider) and trusts the
//             setNeedsRelayout: + next CADisplayLink tick to pick up the
//             new layoutConfiguration values.
static int ds_layout_ios_major(void)
{
    static int cached = 0;
    if (cached) return cached;
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    cached = (int)v.majorVersion;
    return cached;
}

// Two ports now live in this file:
//   < iOS 26 — upstream kolbicz config-mutation path
//   ≥ iOS 26 — bypass the (now-immutable) layout configuration entirely.
//     Walk live SBIconListView instances and adjust them directly: setFrame:
//     for spacing, setIconImageInfo: on each SBIconView for scaling.
//     setIconImageInfo: still exists on iOS 26's SBIconView, and
//     SBIconListView.setFrame: is a regular UIView setter.
static bool darksword_layout_supported_on_current_ios(void)
{
    (void)0;
    return true; // both branches now handled
}

typedef struct {
    double top;
    double left;
    double bottom;
    double right;
} RC_UIEdgeInsets;

typedef struct {
    double x;
    double y;
    double width;
    double height;
} RC_CGRect;

static void r_send_rect_main_local(uint64_t obj, const char *selName,
                                   double x, double y, double w, double h)
{
    if (!r_is_objc_ptr(obj)) return;
    RC_CGRect rect = { x, y, w, h };
    r_msg2_main_raw(obj, selName,
                    &rect, sizeof(rect),
                    NULL, 0, NULL, 0, NULL, 0);
}

typedef struct {
    double width;
    double height;
    double scale;
    double cornerRadius;
} RC_SBIconImageInfo;

static uint64_t rc_safe_msg(uint64_t obj, const char *selname,
                            uint64_t a, uint64_t b, uint64_t c, uint64_t d)
{
    if (!obj) return 0;
    uint64_t sel = r_sel(selname);
    uint64_t rs  = r_sel("respondsToSelector:");
    if (!sel || !rs) return 0;
    if (!r_msg(obj, rs, sel, 0, 0, 0)) return 0;
    return r_msg(obj, sel, a, b, c, d);
}

static void rc_force_manager_relayout(uint64_t mgr, uint64_t clsInv)
{
    if (!mgr || !clsInv) return;

    uint64_t selSig     = r_sel("methodSignatureForSelector:");
    uint64_t selWithSig = r_sel("invocationWithMethodSignature:");
    uint64_t selSetTgt  = r_sel("setTarget:");
    uint64_t selSetSel  = r_sel("setSelector:");
    uint64_t selSetArg  = r_sel("setArgument:atIndex:");
    uint64_t selInvoke  = r_sel("invoke");
    uint64_t selPerform = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
    uint64_t selResponds = r_sel("respondsToSelector:");

    // setNeedsRelayout:YES — safe on both iOS 18 (SBIconManager) and iOS 26+
    // (SBHIconManager). Just an ivar setter on both.
    {
        uint64_t selSNR = r_sel("setNeedsRelayout:");
        uint64_t sig = r_msg(mgr, selSig, selSNR, 0, 0, 0);
        if (sig) {
            uint64_t inv = r_msg(clsInv, selWithSig, sig, 0, 0, 0);
            if (inv) {
                r_msg(inv, selSetTgt, mgr, 0, 0, 0);
                r_msg(inv, selSetSel, selSNR, 0, 0, 0);
                uint64_t one = do_remote_call_stable(R_TIMEOUT, "calloc", 1, 8, 0, 0, 0, 0, 0, 0);
                if (one) {
                    uint8_t yes = 1;
                    remote_write(one, &yes, 1);
                    r_msg(inv, selSetArg, one, 2, 0, 0);
                    r_msg(inv, selPerform, selInvoke, 0, 1, 0);
                    r_free(one);
                }
            }
        }
    }

    // -relayout: only iOS 18's SBIconManager exposes this. iOS 26's
    // SBHIconManager doesn't.
    if (ds_layout_ios_major() < 26) {
        uint64_t selR = r_sel("relayout");
        if (r_msg(mgr, selResponds, selR, 0, 0, 0)) {
            r_msg(mgr, selPerform, selR, 0, 1, 0);
        }
    }

    // -layoutIconListsWithAnimationType:forceRelayout: — iOS 18 only.
    // On iOS 26+ the selector still exists but invoking it from RemoteCall
    // tore down SpringBoard in testing (likely an internal precondition
    // around UIUpdateScheduler). Skip; setNeedsRelayout:YES above plus the
    // next natural display refresh picks up the new layoutConfiguration.
    if (ds_layout_ios_major() < 26) {
        uint64_t selLI = r_sel("layoutIconListsWithAnimationType:forceRelayout:");
        if (r_msg(mgr, selResponds, selLI, 0, 0, 0)) {
            uint64_t sig = r_msg(mgr, selSig, selLI, 0, 0, 0);
            if (sig) {
                uint64_t inv = r_msg(clsInv, selWithSig, sig, 0, 0, 0);
                if (inv) {
                    r_msg(inv, selSetTgt, mgr, 0, 0, 0);
                    r_msg(inv, selSetSel, selLI, 0, 0, 0);
                    uint64_t typeMem  = do_remote_call_stable(R_TIMEOUT, "calloc", 1, 8, 0, 0, 0, 0, 0, 0);
                    uint64_t forceMem = do_remote_call_stable(R_TIMEOUT, "calloc", 1, 8, 0, 0, 0, 0, 0, 0);
                    if (forceMem) {
                        uint8_t yes = 1;
                        remote_write(forceMem, &yes, 1);
                    }
                    if (typeMem)  r_msg(inv, selSetArg, typeMem,  2, 0, 0);
                    if (forceMem) r_msg(inv, selSetArg, forceMem, 3, 0, 0);
                    r_msg(inv, selPerform, selInvoke, 0, 1, 0);
                    if (typeMem)  r_free(typeMem);
                    if (forceMem) r_free(forceMem);
                }
            }
        }
    }
}

static uint64_t rc_list_layout_provider(uint64_t ctrl, uint64_t mgr)
{
    // iOS 26+: SBIconController vends an "ambient" provider directly. The
    // SBHIconManager's _listLayoutProvider ivar is nil-by-default.
    // iOS 18: the provider lives on the icon manager (upstream path).
    if (ds_layout_ios_major() >= 26) {
        if (ctrl) {
            uint64_t prov = r_msg(ctrl, r_sel("listLayoutProvider"), 0, 0, 0, 0);
            if (prov) return prov;
        }
    }
    if (!mgr) return 0;
    return r_msg(mgr, r_sel("listLayoutProvider"), 0, 0, 0, 0);
}

static uint64_t rc_root_layout_config(uint64_t ctrl, uint64_t mgr)
{
    uint64_t prov = rc_list_layout_provider(ctrl, mgr);
    if (!prov) return 0;
    uint64_t cfstr = r_cfstr("SBIconLocationRoot");
    if (!cfstr) return 0;
    uint64_t layout = r_msg(prov, r_sel("layoutForIconLocation:"), cfstr, 0, 0, 0);
    if (!layout) return 0;
    return r_msg(layout, r_sel("layoutConfiguration"), 0, 0, 0, 0);
}

static bool rc_set_insets_on(uint64_t cfg, uint64_t clsInv,
                             const RC_UIEdgeInsets *insets)
{
    if (!cfg || !clsInv) return false;
    uint64_t selSetInsets = r_sel("setPortraitLayoutInsets:");
    uint64_t selSig       = r_sel("methodSignatureForSelector:");
    uint64_t selWithSig   = r_sel("invocationWithMethodSignature:");
    uint64_t selSetTgt    = r_sel("setTarget:");
    uint64_t selSetSel    = r_sel("setSelector:");
    uint64_t selSetArg    = r_sel("setArgument:atIndex:");
    uint64_t selInvoke    = r_sel("invoke");
    uint64_t selPerform   = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");

    uint64_t sig = r_msg(cfg, selSig, selSetInsets, 0, 0, 0);
    if (!sig) return false;
    uint64_t inv = r_msg(clsInv, selWithSig, sig, 0, 0, 0);
    if (!inv) return false;
    r_msg(inv, selSetTgt, cfg, 0, 0, 0);
    if (!r_last_call_ok()) return false;
    r_msg(inv, selSetSel, selSetInsets, 0, 0, 0);
    if (!r_last_call_ok()) return false;

    uint64_t mem = do_remote_call_stable(R_TIMEOUT, "calloc", 1, 32, 0, 0, 0, 0, 0, 0);
    if (!mem) return false;
    if (!remote_write(mem, insets, sizeof(*insets))) { r_free(mem); return false; }
    r_msg(inv, selSetArg, mem, 2, 0, 0);
    if (!r_last_call_ok()) { r_free(mem); return false; }
    r_msg(inv, selPerform, selInvoke, 0, 1, 0);
    // false = the dispatch didn't complete; the setter may or may not have run.
    bool ok = r_last_call_ok();
    r_free(mem);
    return ok;
}

// When async is true the invocation is fired onto SpringBoard's main thread
// WITHOUT waiting for it to finish. Setting the icon size makes SpringBoard
// regenerate every icon image, which takes several seconds; with waitUntilDone
// that stall lands on our worker thread and freezes the whole apply run. Firing
// it async lets SpringBoard do that work on its own thread in the background
// while the run continues. We retainArguments first so the invocation owns its
// target and the copied struct even after this function returns and the local
// buffer is freed.
static bool rc_set_icon_info_on(uint64_t cfg, uint64_t clsInv,
                                const RC_SBIconImageInfo *info, bool async)
{
    if (!cfg || !clsInv) return false;
    uint64_t selSetIconInfo = r_sel("setIconImageInfo:");
    uint64_t selSig         = r_sel("methodSignatureForSelector:");
    uint64_t selWithSig     = r_sel("invocationWithMethodSignature:");
    uint64_t selSetTgt      = r_sel("setTarget:");
    uint64_t selSetSel      = r_sel("setSelector:");
    uint64_t selSetArg      = r_sel("setArgument:atIndex:");
    uint64_t selInvoke      = r_sel("invoke");
    uint64_t selPerform     = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");

    uint64_t sig = r_msg(cfg, selSig, selSetIconInfo, 0, 0, 0);
    if (!sig) return false;
    uint64_t inv = r_msg(clsInv, selWithSig, sig, 0, 0, 0);
    if (!inv) return false;
    r_msg(inv, selSetTgt, cfg, 0, 0, 0);
    if (!r_last_call_ok()) return false;
    r_msg(inv, selSetSel, selSetIconInfo, 0, 0, 0);
    if (!r_last_call_ok()) return false;

    uint64_t mem = do_remote_call_stable(R_TIMEOUT, "calloc", 1, 32, 0, 0, 0, 0, 0, 0);
    if (!mem) return false;
    if (!remote_write(mem, info, sizeof(*info))) { r_free(mem); return false; }
    r_msg(inv, selSetArg, mem, 2, 0, 0);
    if (!r_last_call_ok()) { r_free(mem); return false; }
    if (async) {
        r_msg(inv, r_sel("retainArguments"), 0, 0, 0, 0);
        if (!r_last_call_ok()) { r_free(mem); return false; }
    }
    r_msg(inv, selPerform, selInvoke, 0, async ? 0 : 1, 0);
    // false = the dispatch didn't complete; the setter may or may not have run.
    bool ok = r_last_call_ok();
    r_free(mem);
    return ok;
}

// True for the icon classes we resize: real app icons, PLUS the special dynamic
// app icons for Clock and Calendar (SBHClockApplicationIcon /
// SBHCalendarApplicationIcon on iOS 18's SpringBoardHome), which are NOT
// SBApplicationIcon subclasses and so were silently skipped — they stayed full
// size until the page was next laid out. Deliberately an allow-list: it excludes
// widgets (SBWidgetIcon), App Library pods (SBHLibraryPodCategoryIcon) and
// folders, which we must not touch (forcing a 60x60 image info on those asserts /
// is unwanted).
static bool rc_icon_is_resizable(uint64_t icon)
{
    if (!icon) return false;
    static const char *kClasses[] = {
        "SBApplicationIcon",
        "SBHClockApplicationIcon",
        "SBHCalendarApplicationIcon",
        NULL,
    };
    uint64_t selKind = r_sel("isKindOfClass:");
    for (int i = 0; kClasses[i]; i++) {
        uint64_t cls = r_class(kClasses[i]);
        if (cls && r_msg(icon, selKind, cls, 0, 0, 0)) return true;
    }
    return false;
}

// Eager resize of the live SBIconViews. setIconImageInfo: on the layout
// configuration alone is LAZY — a view only adopts the new size on its next
// natural relayout (a page swipe, or a touch on the dock). Setting it on the view
// itself plus -_updateAfterManualIconImageInfoChangeInvalidatingLayout: forces
// the change to show now. Done synchronously (waitUntilDone:YES) so the resize is
// applied before the run reports done. Only the app-icon classes above — never
// widgets/pods/folders.
//
// Cost is what makes this slow: every remote message is a RemoteCall round
// trip. Building a fresh NSInvocation per call costs ~9, so the two
// invocations are built once per run with their argument already set, and each
// icon only swaps the target and performs (4 round trips instead of ~18). The
// resizable-class check is cached per class.
typedef struct {
    uint64_t clsInv;
    RC_SBIconImageInfo info;
    uint64_t invInfo;     // retained, -setIconImageInfo: with info set
    uint64_t invUpdate;   // retained, -_updateAfterManual...: with YES set
    bool built;
    uint64_t selIcon, selSetTgt, selPerform, selInvoke;
    struct { uint64_t cls; bool resizable; } classCache[16];
    int nClassCache;
} RCResizeCtx;

static void rc_resize_ctx_init(RCResizeCtx *ctx, uint64_t clsInv, const RC_SBIconImageInfo *info)
{
    memset(ctx, 0, sizeof(*ctx));
    ctx->clsInv     = clsInv;
    ctx->info       = *info;
    ctx->selIcon    = r_sel("icon");
    ctx->selSetTgt  = r_sel("setTarget:");
    ctx->selPerform = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
    ctx->selInvoke  = r_sel("invoke");
}

static void rc_resize_ctx_destroy(RCResizeCtx *ctx)
{
    uint64_t selRel = r_sel("release");
    if (ctx->invInfo)   r_msg(ctx->invInfo,   selRel, 0, 0, 0, 0);
    if (ctx->invUpdate) r_msg(ctx->invUpdate, selRel, 0, 0, 0, 0);
    ctx->invInfo = ctx->invUpdate = 0;
}

static bool rc_icon_is_resizable_cached(RCResizeCtx *ctx, uint64_t icon)
{
    if (!icon) return false;
    uint64_t cls = r_dlsym_call(R_TIMEOUT, "object_getClass", icon, 0, 0, 0, 0, 0, 0, 0);
    if (!cls) return false;
    for (int i = 0; i < ctx->nClassCache; i++) {
        if (ctx->classCache[i].cls == cls) return ctx->classCache[i].resizable;
    }
    bool resizable = rc_icon_is_resizable(icon);
    if (ctx->nClassCache < (int)(sizeof(ctx->classCache) / sizeof(ctx->classCache[0]))) {
        ctx->classCache[ctx->nClassCache].cls = cls;
        ctx->classCache[ctx->nClassCache].resizable = resizable;
        ctx->nClassCache++;
    }
    return resizable;
}

// Returns true when the view was resized (a resizable app icon).
static bool rc_resize_icon_view(RCResizeCtx *ctx, uint64_t iconView)
{
    if (!iconView) return false;
    uint64_t icon = r_msg(iconView, ctx->selIcon, 0, 0, 0, 0);
    if (!rc_icon_is_resizable_cached(ctx, icon)) return false;

    if (!ctx->built) {
        ctx->built = true;
        uint8_t yes = 1;
        ctx->invInfo   = r_invocation_retained(iconView, "setIconImageInfo:",
                                               &ctx->info, sizeof(ctx->info));
        ctx->invUpdate = r_invocation_retained(iconView,
                                               "_updateAfterManualIconImageInfoChangeInvalidatingLayout:",
                                               &yes, sizeof(yes));
    }
    if (ctx->invInfo) {
        r_msg(ctx->invInfo, ctx->selSetTgt, iconView, 0, 0, 0);
        r_msg(ctx->invInfo, ctx->selPerform, ctx->selInvoke, 0, 1, 0);
    }
    if (ctx->invUpdate) {
        r_msg(ctx->invUpdate, ctx->selSetTgt, iconView, 0, 0, 0);
        r_msg(ctx->invUpdate, ctx->selPerform, ctx->selInvoke, 0, 1, 0);
    }
    return ctx->invInfo != 0;
}

// The SBIconViews of one SBIconListView. The subviews snapshot is fetched and
// retained on main (calling -subviews off-main races the live view tree:
// EXC_ARM_PAC_FAIL), then read on the worker thread; the caller releases
// *retainedSubs once done with the views.
static int rc_list_view_icon_views(uint64_t listView, uint64_t *out, int cap,
                                   uint64_t *retainedSubs)
{
    *retainedSubs = 0;
    uint64_t clsIconView = r_class("SBIconView");
    if (!listView || !clsIconView) return 0;
    uint64_t subs = r_msg2_main_retained(listView, "subviews");
    if (!subs) return 0;
    *retainedSubs = subs;
    return r_array_items_of_class(subs, clsIconView, out, cap);
}

// Resize every icon view of one list view. Returns how many were resized.
static int rc_refresh_list_view(RCResizeCtx *ctx, uint64_t listView, int *outTotal)
{
    enum { ICON_CAP = 256 };
    uint64_t views[ICON_CAP];
    uint64_t subs = 0;
    int n = rc_list_view_icon_views(listView, views, ICON_CAP, &subs);
    if (outTotal) *outTotal += n;
    int resized = 0;
    for (int i = 0; i < n; i++) {
        if (rc_resize_icon_view(ctx, views[i])) resized++;
    }
    if (subs) r_msg(subs, r_sel("release"), 0, 0, 0, 0);
    return resized;
}

static DSLayoutProgressHandler g_ds_layout_progress;

void darksword_layout_set_progress_handler(DSLayoutProgressHandler handler)
{
    g_ds_layout_progress = [handler copy];
}

static void rc_report_progress(int pagesDone, int pagesTotal, int iconsDone, int iconsTotal)
{
    DSLayoutProgressHandler handler = g_ds_layout_progress;
    if (handler) handler(pagesDone, pagesTotal, iconsDone, iconsTotal);
}

static uint64_t rc_icon_controller(void)
{
    uint64_t cls = r_class("SBIconController");
    if (!cls) return 0;
    return r_msg(cls, r_sel("sharedInstance"), 0, 0, 0, 0);
}

static uint64_t rc_icon_manager_for(uint64_t ctrl)
{
    return ctrl ? r_msg(ctrl, r_sel("iconManager"), 0, 0, 0, 0) : 0;
}

static uint64_t rc_dock_list_view(uint64_t ctrl, uint64_t mgr)
{
    if (mgr) {
        uint64_t dock = rc_safe_msg(mgr, "dockListView", 0, 0, 0, 0);
        if (dock) return dock;
    }
    return ctrl ? rc_safe_msg(ctrl, "dockListView", 0, 0, 0, 0) : 0;
}

// The home-screen pages straight from the root folder view
// (rootFolderController -> folderView -> iconListViews): a handful of round
// trips. The fallback below walks every view of every SpringBoard window with
// main-thread hops (~20 round trips each, thousands of views), which was most
// of the resize time. Returns 0 when the direct path isn't available.
static int rc_root_page_list_views(uint64_t mgr, uint64_t *out, int cap)
{
    uint64_t clsListView = r_class("SBIconListView");
    if (!mgr || !clsListView) return 0;
    uint64_t rootFC = rc_safe_msg(mgr, "rootFolderController", 0, 0, 0, 0);
    if (!rootFC) rootFC = rc_safe_msg(mgr, "_rootFolderController", 0, 0, 0, 0);
    if (!rootFC) return 0;

    uint64_t selResponds = r_sel("respondsToSelector:");
    uint64_t folderView = 0;
    static const char *kFolderViewSels[] = { "folderView", "rootFolderView", "contentView", NULL };
    for (int i = 0; kFolderViewSels[i] && !folderView; i++) {
        uint64_t sel = r_sel(kFolderViewSels[i]);
        if (sel && r_msg(rootFC, selResponds, sel, 0, 0, 0))
            folderView = r_msg_main(rootFC, sel, 0, 0, 0, 0);
    }
    uint64_t selLists = r_sel("iconListViews");
    if (!folderView || !selLists || !r_msg(folderView, selResponds, selLists, 0, 0, 0)) return 0;

    uint64_t lists = r_msg2_main_retained(folderView, "iconListViews");
    if (!lists) return 0;
    int n = r_array_items_of_class(lists, clsListView, out, cap);
    r_release(lists);
    return n;
}

// Home pages (and possibly the dock and other list views, on the fallback
// path) for the resize and the iOS 26 transform.
static int rc_collect_home_list_views(uint64_t mgr, uint64_t *out, int cap, const char *tag)
{
    int n = rc_root_page_list_views(mgr, out, cap);
    if (n > 0) {
        printf("[%s] %d page list view(s) via root folder view\n", tag, n);
        return n;
    }
    uint64_t clsListView = r_class("SBIconListView");
    n = sb_collect_views_in_windows_main(clsListView, out, cap);
    if (n == 0 && mgr) {
        uint64_t rootFC = rc_safe_msg(mgr, "rootFolderController", 0, 0, 0, 0);
        if (!rootFC) rootFC = rc_safe_msg(mgr, "_rootFolderController", 0, 0, 0, 0);
        if (rootFC) {
            uint64_t rv = rc_safe_msg(rootFC, "view", 0, 0, 0, 0);
            if (rv) n = sb_collect_views_main(rv, clsListView, out, cap);
        }
    }
    printf("[%s] %d list view(s) via window walk (fallback)\n", tag, n);
    return n;
}

// The spacing setters below take relayout=false when called from
// darksword_layout_apply_in_session, which forces one relayout after both:
// each forced relayout is a synchronous full grid relayout on SpringBoard's
// main thread, and the home and dock insets don't need one each.
static bool rc_home_spacing(double exL, double exR, double exT, double exB, bool relayout);
static bool rc_dock_spacing(double extraLeft, double extraRight, bool relayout);

bool darksword_layout_home_spacing_in_session(double exL, double exR, double exT, double exB)
{
    return rc_home_spacing(exL, exR, exT, exB, true);
}

bool darksword_layout_dock_spacing_in_session(double extraLeft, double extraRight)
{
    return rc_dock_spacing(extraLeft, extraRight, true);
}

static bool rc_home_spacing(double exL, double exR, double exT, double exB, bool relayout)
{
    printf("[HSSPACE] ios=%d left=%.2f right=%.2f top=%.2f bottom=%.2f\n",
           ds_layout_ios_major(), exL, exR, exT, exB);
    uint64_t ctrl = rc_icon_controller();
    if (!ctrl) { printf("[HSSPACE] SBIconController nil\n"); return false; }
    uint64_t mgr = rc_icon_manager_for(ctrl);
    uint64_t cfg = rc_root_layout_config(ctrl, mgr);
    if (!cfg) { printf("[HSSPACE] root layoutConfiguration nil\n"); return false; }
    uint64_t clsInv = r_class("NSInvocation");
    if (!clsInv) return false;

    RC_UIEdgeInsets ins = {
        .top    = 60.0  + exT,
        .left   = 27.0  + exL,
        .bottom = 100.0 + exB,
        .right  = 27.0  + exR,
    };
    bool ok = rc_set_insets_on(cfg, clsInv, &ins);
    if (ok && relayout) rc_force_manager_relayout(mgr, clsInv);
    return ok;
}

static bool rc_dock_spacing(double extraLeft, double extraRight, bool relayout)
{
    printf("[DOCKSPACE] ios=%d extraL=%.2f extraR=%.2f\n",
           ds_layout_ios_major(), extraLeft, extraRight);
    uint64_t ctrl = rc_icon_controller();
    if (!ctrl) return false;
    uint64_t mgr = rc_icon_manager_for(ctrl);
    uint64_t dock = rc_dock_list_view(ctrl, mgr);
    if (!dock) { printf("[DOCKSPACE] dockListView nil\n"); return false; }
    uint64_t dockLayout = rc_safe_msg(dock, "layout", 0, 0, 0, 0);
    uint64_t dockCfg = dockLayout ? rc_safe_msg(dockLayout, "layoutConfiguration", 0, 0, 0, 0) : 0;
    if (!dockCfg) { printf("[DOCKSPACE] dock layoutConfiguration nil\n"); return false; }
    uint64_t clsInv = r_class("NSInvocation");
    if (!clsInv) return false;

    RC_UIEdgeInsets ins = {
        .top    = 0.0,
        .left   = 16.0 + extraLeft,
        .bottom = 0.0,
        .right  = 16.0 + extraRight,
    };
    bool ok = rc_set_insets_on(dockCfg, clsInv, &ins);
    if (ok && relayout) rc_force_manager_relayout(mgr, clsInv);
    return ok;
}

bool darksword_layout_home_scale_in_session(double scale)
{
    if (scale <= 0.0 || scale > 2.0) return false;
    printf("[HSSCALE] ios=%d scale=%.2f\n", ds_layout_ios_major(), scale);
    uint64_t ctrl = rc_icon_controller();
    if (!ctrl) return false;
    uint64_t mgr = rc_icon_manager_for(ctrl);
    uint64_t cfg = rc_root_layout_config(ctrl, mgr);
    if (!cfg) return false;
    uint64_t clsInv = r_class("NSInvocation");
    if (!clsInv) return false;

    RC_SBIconImageInfo info = {
        .width        = 60.0 * scale,
        .height       = 60.0 * scale,
        .scale        = 2.0,
        .cornerRadius = 13.5 * scale,
    };

    // Set the size on the root layout config (async, for persistence + future
    // relayouts), then eagerly resize the live icon views so the change shows
    // during the run. Right after the SBCustomizer arrange, the first
    // main-thread hop below waits for SpringBoard to finish its grid relayout
    // and the icon re-render this triggers.
    rc_set_icon_info_on(cfg, clsInv, &info, /*async=*/true);

    enum { LV_CAP = 64, ICON_CAP = 1024 };
    uint64_t lvs[LV_CAP];
    int nlv = rc_collect_home_list_views(mgr, lvs, LV_CAP, "HSSCALE");

    // Pass 1: gather every page's icon views, so progress can be shown as
    // "N of total" rather than as elapsed time.
    uint64_t subsHeld[LV_CAP];
    int pageFirst[LV_CAP + 1];
    static uint64_t views[ICON_CAP];
    int npages = 0, nviews = 0;
    for (int i = 0; i < nlv && npages < LV_CAP; i++) {
        if (rc_safe_msg(lvs[i], "isDock", 0, 0, 0, 0)) continue;
        uint64_t subs = 0;
        int got = rc_list_view_icon_views(lvs[i], views + nviews, ICON_CAP - nviews, &subs);
        if (!subs) continue;
        subsHeld[npages] = subs;
        pageFirst[npages] = nviews;
        nviews += got;
        npages++;
    }
    pageFirst[npages] = nviews;
    rc_report_progress(0, npages, 0, nviews);

    // Pass 2: resize, reporting after each page.
    RCResizeCtx ctx;
    rc_resize_ctx_init(&ctx, clsInv, &info);
    int resized = 0;
    for (int p = 0; p < npages; p++) {
        for (int i = pageFirst[p]; i < pageFirst[p + 1]; i++) {
            if (rc_resize_icon_view(&ctx, views[i])) resized++;
        }
        rc_report_progress(p + 1, npages, pageFirst[p + 1], nviews);
    }
    rc_resize_ctx_destroy(&ctx);
    uint64_t selRel = r_sel("release");
    for (int p = 0; p < npages; p++) r_msg(subsHeld[p], selRel, 0, 0, 0, 0);

    printf("[HSSCALE] resized %d of %d live icon view(s) on %d page(s)\n", resized, nviews, npages);
    return resized > 0 || nviews == 0;
}

bool darksword_layout_dock_scale_in_session(double scale)
{
    if (scale <= 0.0 || scale > 2.0) return false;
    printf("[DOCKSCALE] ios=%d scale=%.2f\n", ds_layout_ios_major(), scale);
    uint64_t ctrl = rc_icon_controller();
    if (!ctrl) return false;
    uint64_t mgr = rc_icon_manager_for(ctrl);
    uint64_t dock = rc_dock_list_view(ctrl, mgr);
    if (!dock) return false;
    uint64_t dockLayout = rc_safe_msg(dock, "layout", 0, 0, 0, 0);
    uint64_t dockCfg = dockLayout ? rc_safe_msg(dockLayout, "layoutConfiguration", 0, 0, 0, 0) : 0;
    uint64_t clsInv = r_class("NSInvocation");
    if (!clsInv) return false;

    RC_SBIconImageInfo info = {
        .width        = 60.0 * scale,
        .height       = 60.0 * scale,
        .scale        = 2.0,
        .cornerRadius = 13.5 * scale,
    };

    // Set the dock's icon size on its layout config (async), then eagerly resize
    // the live dock icon views so it shows during the run.
    if (dockCfg) rc_set_icon_info_on(dockCfg, clsInv, &info, /*async=*/true);

    RCResizeCtx ctx;
    rc_resize_ctx_init(&ctx, clsInv, &info);
    int total = 0;
    int touched = rc_refresh_list_view(&ctx, dock, &total);
    if (touched == 0) {
        uint64_t clsListView = r_class("SBIconListView");
        enum { LV_CAP = 64 };
        uint64_t lvs[LV_CAP];
        int nlv = sb_collect_views_in_windows_main(clsListView, lvs, LV_CAP);
        for (int i = 0; i < nlv; i++) {
            if (rc_safe_msg(lvs[i], "isDock", 0, 0, 0, 0))
                touched += rc_refresh_list_view(&ctx, lvs[i], &total);
        }
    }
    rc_resize_ctx_destroy(&ctx);
    printf("[DOCKSCALE] resized %d of %d live dock icon view(s)\n", touched, total);
    return touched > 0 || total == 0;
}

// iOS 26: the (now-immutable) AMUIInfographIconListLayout doesn't have a
// layoutConfiguration we can mutate, so we bypass it entirely and just
// adjust the live SBIconListViews and their child SBIconViews directly.
// Effects are one-shot at Run; iOS 26's auto-layout will re-fit on a
// subsequent layout pass (orientation change, page swipe, etc.).
// On iOS 26 the icon GRID is positioned inside each page by the immutable
// AMUIInfographIconListLayout, using static qword tables in AmbientUI's
// __const segment. The SBIconListView itself (the "page" view) is laid
// out by auto-layout to fill the screen, so setFrame: on it has no
// visible effect — the page-internal grid re-centers within whatever
// bounds we set. The reliable iOS 26 lever is per-icon image size via
// -[SBIconView setIconImageInfo:], which DOES still exist and which
// auto-layout respects on the next pass.
//
// To keep the same Settings UI working, we apply a CATransform3D /
// `transform` SCALE to each non-dock list view that incorporates the
// user-set "extra padding" as a scale-down ratio. Effective padding:
// w/h_new = w/h - (left+right) / -(top+bottom). The whole grid shrinks
// inside its bounds, creating visible empty space at the edges. The
// dock gets its own transform driven by dockExL/dockExR.
static bool darksword_layout_apply_in_session_ios26(double exL, double exR, double exT, double exB,
                                                    double dockExL, double dockExR,
                                                    double homeScale, double dockScale)
{
    printf("[LAYOUT26] home=+L%.1f/R%.1f/T%.1f/B%.1f dock=+L%.1f/R%.1f homeScale=%.2f dockScale=%.2f\n",
           exL, exR, exT, exB, dockExL, dockExR, homeScale, dockScale);

    uint64_t clsListView = r_class("SBIconListView");
    if (!clsListView) { printf("[LAYOUT26] SBIconListView class missing\n"); return false; }
    uint64_t clsInv = r_class("NSInvocation");

    // Resolve dock list view up front so we can identify it by pointer
    // instead of relying on -[SBIconListView isDock] (which returns NO
    // for everything we tried on iOS 26.0.1).
    uint64_t ctrl = rc_icon_controller();
    uint64_t mgr  = rc_icon_manager_for(ctrl);
    uint64_t dockLV = rc_dock_list_view(ctrl, mgr);
    if (dockLV) printf("[LAYOUT26] dockListView=0x%llx\n", dockLV);

    enum { LV_CAP = 64 };
    uint64_t lvs[LV_CAP];
    int nlv = rc_collect_home_list_views(mgr, lvs, LV_CAP - 1, "LAYOUT26");
    // The direct path returns only the pages; the dock is transformed too.
    bool haveDock = false;
    for (int i = 0; i < nlv; i++) if (lvs[i] == dockLV) haveDock = true;
    if (dockLV && !haveDock) lvs[nlv++] = dockLV;
    printf("[LAYOUT26] discovered %d SBIconListView(s)\n", nlv);
    if (nlv == 0) return false;

    bool anyOk = false;

    // Establish the "canonical" home page size — the most common (w,h) among
    // the collected SBIconListViews. Everything that matches this size is
    // treated as a home page; everything else (App Library, Today view,
    // nested grids) is skipped so we don't fight their auto-layout and make
    // icons "disappear".
    int sizeCounts[LV_CAP] = {0};
    double sizeW[LV_CAP] = {0}, sizeH[LV_CAP] = {0};
    int distinctSizes = 0;
    double frameCache[LV_CAP][4];
    bool haveFrameCache[LV_CAP];
    for (int i = 0; i < nlv; i++) {
        haveFrameCache[i] = false;
        if (!lvs[i]) continue;
        haveFrameCache[i] = r_msg2_main_struct_ret(lvs[i], "frame",
                                                    frameCache[i], sizeof(frameCache[i]),
                                                    NULL, 0, NULL, 0, NULL, 0, NULL, 0);
        if (!haveFrameCache[i]) continue;
        double w = frameCache[i][2], h = frameCache[i][3];
        if (lvs[i] == dockLV) continue;     // dock is its own thing
        int found = -1;
        for (int j = 0; j < distinctSizes; j++) {
            if (sizeW[j] == w && sizeH[j] == h) { found = j; break; }
        }
        if (found >= 0) sizeCounts[found]++;
        else if (distinctSizes < LV_CAP) {
            sizeW[distinctSizes] = w;
            sizeH[distinctSizes] = h;
            sizeCounts[distinctSizes] = 1;
            distinctSizes++;
        }
    }
    int bestIdx = -1;
    for (int j = 0; j < distinctSizes; j++) {
        if (bestIdx < 0 || sizeCounts[j] > sizeCounts[bestIdx]) bestIdx = j;
    }
    double homeW = (bestIdx >= 0) ? sizeW[bestIdx] : 0.0;
    double homeH = (bestIdx >= 0) ? sizeH[bestIdx] : 0.0;
    if (bestIdx >= 0) {
        printf("[LAYOUT26] home page size: %.1fx%.1f (matches %d list view(s))\n",
               homeW, homeH, sizeCounts[bestIdx]);
    }

    for (int i = 0; i < nlv; i++) {
        uint64_t lv = lvs[i];
        if (!lv) continue;
        bool isDock = (dockLV != 0 && lv == dockLV);
        if (!isDock) {
            isDock = rc_safe_msg(lv, "isDock", 0, 0, 0, 0) != 0;
        }

        // Skip list views that aren't either the dock or a canonical home
        // page — those are the App Library / Today / nested containers, and
        // transforming them is what was making icons "disappear" earlier.
        if (!isDock && haveFrameCache[i] && bestIdx >= 0) {
            double w = frameCache[i][2], h = frameCache[i][3];
            if (w != homeW || h != homeH) {
                printf("[LAYOUT26]   skip non-page list view {%.1fx%.1f}\n", w, h);
                continue;
            }
        }

        // ---- Page-internal grid scale (visible "spacing" + "scale") ----
        // On iOS 26 we drive BOTH the spacing sliders and the scale sliders
        // through one CGAffineTransform per list view. Why not also call
        // -[SBIconView setIconImageInfo:] like the iOS 18 path? Because on
        // iOS 26 that invalidates the icon's cached image and the dock
        // never gets a follow-up layout pass to refetch it, so dock icons
        // stay blank until next respring. Pure transform avoids the cache
        // invalidation entirely — icons just get drawn smaller.
        double frame[4] = { 0, 0, 0, 0 };
        bool haveFrame = haveFrameCache[i];
        if (haveFrame) memcpy(frame, frameCache[i], sizeof(frame));
        else haveFrame = r_msg2_main_struct_ret(lv, "frame", frame, sizeof(frame),
                                                NULL, 0, NULL, 0, NULL, 0, NULL, 0);
        if (haveFrame) {
            double w = frame[2], h = frame[3];
            double scaleX = 1.0, scaleY = 1.0;
            double tx = 0.0;
            if (isDock) {
                double totH = dockExL + dockExR;
                if (totH != 0.0 && w > 0.0) {
                    double avail = w - totH;
                    if (avail > 0.0) scaleX = avail / w;
                    scaleY = scaleX;
                    // Center-scaling removes totH/2 from each side; shift by
                    // (L-R)/2 so the left gap ends up dockExL and the right
                    // gap dockExR (a pure scale can only pad symmetrically).
                    tx = (dockExL - dockExR) / 2.0;
                }
                if (dockScale > 0.0 && dockScale != 1.0) {
                    scaleX *= dockScale;
                    scaleY *= dockScale;
                }
            } else {
                if (exL + exR != 0.0 && w > 0.0) {
                    double availW = w - (exL + exR);
                    if (availW > 0.0) scaleX = availW / w;
                }
                if (exT + exB != 0.0 && h > 0.0) {
                    double availH = h - (exT + exB);
                    if (availH > 0.0) scaleY = availH / h;
                }
                if (homeScale > 0.0 && homeScale != 1.0) {
                    scaleX *= homeScale;
                    scaleY *= homeScale;
                }
            }
            if (scaleX != 1.0 || scaleY != 1.0 || tx != 0.0) {
                // CGAffineTransform: { a, b, c, d, tx, ty } — 6 doubles, 48 bytes.
                // Scale (+ optional horizontal shift for asymmetric dock pad).
                double xf[6] = { scaleX, 0.0, 0.0, scaleY, tx, 0.0 };
                r_msg2_main_raw(lv, "setTransform:",
                                xf, sizeof(xf),
                                NULL, 0, NULL, 0, NULL, 0);
                bool setOk = r_last_main_ok();
                printf("[LAYOUT26]   %s transform scale=(%.3f,%.3f) tx=%.1f frameWxH=%.1fx%.1f%s\n",
                       isDock ? "dock" : "home", scaleX, scaleY, tx, w, h,
                       setOk ? "" : " (setTransform: failed)");
                if (setOk) anyOk = true;
            } else {
                // Reset to identity in case a prior Run left a transform.
                double identity[6] = { 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 };
                r_msg2_main_raw(lv, "setTransform:",
                                identity, sizeof(identity),
                                NULL, 0, NULL, 0, NULL, 0);
                if (r_last_main_ok()) anyOk = true;
            }
        }
    }
    return anyOk;
}

bool darksword_layout_apply_in_session(double exL, double exR, double exT, double exB,
                                       double dockExL, double dockExR,
                                       double homeScale, double dockScale)
{
    if (ds_layout_ios_major() >= 26) {
        return darksword_layout_apply_in_session_ios26(exL, exR, exT, exB,
                                                        dockExL, dockExR, homeScale, dockScale);
    }
    bool homeOK = rc_home_spacing(exL, exR, exT, exB, false);
    bool dockOK = rc_dock_spacing(dockExL, dockExR, false);
    if (homeOK || dockOK) {
        uint64_t mgr = rc_icon_manager_for(rc_icon_controller());
        rc_force_manager_relayout(mgr, r_class("NSInvocation"));
    }
    bool ok = homeOK && dockOK;
    if (homeScale > 0.0) ok &= darksword_layout_home_scale_in_session(homeScale);
    if (dockScale > 0.0) ok &= darksword_layout_dock_scale_in_session(dockScale);
    return ok;
}
