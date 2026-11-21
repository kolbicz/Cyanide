//
//  stagestrip.m
//

#import "stagestrip.h"
#import "../remote_objc.h"
#import "../../TaskRop/RemoteCall.h"
#import "../../LogTextView.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ctype.h>
#import <dlfcn.h>
#import <math.h>
#import <stdio.h>
#import <string.h>
#import <sys/time.h>
#import <unistd.h>

#import <notify.h>

// ---------------------------------------------------------------------------
// Master flag. When false, the visible left-edge sidebar UI is skipped; only
// the multitasking primitive (fetch FBScene per app -> force foreground ->
// alloc _UISceneLayerHostContainerView, log outcome) runs. Flip back on once
// the underlying scene-compositing mechanism is proven on iOS 26.
// ---------------------------------------------------------------------------
static const bool kStripShowSidebar = false;

// ---------------------------------------------------------------------------
// Layout constants. Tuned for a 6.1" iPhone; the strip auto-clamps to the
// screen's available height so smaller / larger devices still render.
// ---------------------------------------------------------------------------

static const uint64_t kStripWindowTag    = 99431;
static const double   kStripWindowLevel  = 999990.0;
static const double   kStripWidth        = 112.0;
static const double   kStripLeftMargin   = 6.0;
static const double   kStripTopInset     = 100.0; // clear of dynamic island
static const double   kStripBottomInset  = 100.0; // clear of home indicator
static const double   kStripSlotW        = 100.0;
static const double   kStripSlotH        = 178.0; // portrait tile aspect
static const double   kStripSlotSpacing  = 14.0;
static const double   kStripCornerRadius = 16.0;
static const double   kStripBorderInset  = 12.0;
static const double   kStripTransitionShieldAlpha = 0.24;
static const double   kStripTransitionShieldFade  = 0.22;
static const double   kStripTransitionShieldApplyHold = 0.62;
static const double   kStripTransitionShieldCloseHold = 0.28;
static const double   kStripResizeSwapRevealDelay = 0.07;
static const double   kStripResizeSwapRetireDelay = 0.18;
static const double   kStripSlotCornerR  = 14.0;
static const int      kStripMaxSlotsHard = 4;
static const int      kStripRecentProbeLimit = 4;
static const int      kStripPickerInitialMaxBids = 16;
static const uint64_t kStripPickerEnumHardBudgetMS = 8000;
static const uint64_t kStripPickerLibraryBuildDelayMS = 4000;
static const uint64_t kStripPickerLibraryTileIntervalMS = 1200;
static const useconds_t kStripSettleUS   = 1000;
static const uint32_t kStripApplySettleUS = 1000;
static const double   kStripStageW       = 220.0;
static const double   kStripStageH       = 380.0;
static const double   kStripStackGap     = 10.0;
static const bool     kStripDebugDumpScenes = false;
static const bool     kStripMakeFloatWindowKey = false;
static const bool     kStripUseInteractiveFloatWindow = false;
static const bool     kStripAlwaysRecreateFloatWindow = false;
static const bool     kStripUsePassthroughContainers = false;
static const bool     kStripDirectReportedForeground = true;
static const bool     kStripUpdateForegroundAttribution = true;
static const bool     kStripMutateSceneSettingsLive = false;
static const bool     kStripUseSceneSettingsUpdater = true;
static const bool     kStripActivateInactiveScenesViaUpdater = true;
static const bool     kStripKeepSceneForegroundTimer = true;
// Per StageDuo RE: the iOS >= 15 hosting primitive is
// -[_UISceneLayerHostContainerView initWithScene:debugDescription:]. On
// iOS 26.0.1 the init alone leaves _presentationContext nil and the host
// renders transparent (see stagestrip_make_scene_layer_host_view — we now
// install a default UIScenePresentationContext after init). With that fix
// the StageDuo path works again; Medusa stays as a last-resort fallback.
static const bool     kStripPreferRawSceneLayerHost = true;
static const int      kStripMaxMedusaTiles = 0;
static const bool     kStripUseAlwaysLiveOverlay = false;
static const bool     kStripNotifyReportedForeground = false;
static const bool     kStripRunSceneManagerStateUpdate = false;
static const bool     kStripReportedForegroundTimer = false;

typedef struct {
    double width;
    double height;
} StripSize;

// ---------------------------------------------------------------------------
// Static state. Mirrors statbar.m's "remember the SpringBoard-side objects so
// successive applies just refresh instead of rebuilding" pattern.
// ---------------------------------------------------------------------------

static uint64_t gStripWindow         = 0;
static uint64_t gStripContainer      = 0;
static uint64_t gStripLaunchAddr     = 0;   // SBSLaunchApplicationWithIdentifier
static uint64_t gStripLiveScene      = 0;   // last FBScene we asserted live-rendering for
static uint64_t gStripLiveScenes[kStripMaxSlotsHard] = {0};
static int      gStripLiveSceneCount = 0;
static bool     gStripOpenMethodAdded = false;
static int      gStripApplyTick      = 0;
// Each "slot" is one app's floating UIWindow plus its own move/resize pan
// handles. Two slots = top app + bottom app, independently movable. The
// `defines below keep legacy single-window code paths compiling — they all
// alias to slot 0, which is the historical primary window.
// Per-corner resize handles. cornerHandles[0..3] / cornerPans[0..3] are
// indexed by StripCorner enum (TL/TR/BL/BR). resizeHandle / resizePan retain
// their old meaning (= BR, i.e. cornerHandles[3] / cornerPans[3]) so the
// pre-existing legacy code paths still compile while the control loop polls
// all four.
typedef enum {
    kStripCornerTL = 0,
    kStripCornerTR = 1,
    kStripCornerBL = 2,
    kStripCornerBR = 3,
    kStripCornerCount = 4,
} StripCorner;

typedef struct {
    uint64_t window;
    uint64_t hostView;
    uint64_t moveHandle;
    uint64_t resizeHandle;
    uint64_t movePan;
    uint64_t resizePan;
    uint64_t referenceView;
    uint64_t closeButton;
    uint64_t pickerSwipe;
    uint64_t pickerSwipePanel;
    uint64_t cornerHandles[kStripCornerCount];
    uint64_t cornerPans[kStripCornerCount];
    uint64_t cornerArcs[kStripCornerCount];   // CAShapeLayer for each corner's arc glyph
    bool     cornerArcsVisible;               // tracked so we only flip when state changes
} StripFloatSlot;

#define kStripMaxFloatSlots 2
static StripFloatSlot gStripFloatSlots[kStripMaxFloatSlots] = {{0}};

#define gStripFloatWindow    (gStripFloatSlots[0].window)
#define gStripFloatHostView  (gStripFloatSlots[0].hostView)
#define gStripMoveHandle     (gStripFloatSlots[0].moveHandle)
#define gStripResizeHandle   (gStripFloatSlots[0].resizeHandle)
#define gStripMovePan        (gStripFloatSlots[0].movePan)
#define gStripResizePan      (gStripFloatSlots[0].resizePan)
#define gStripReferenceView  (gStripFloatSlots[0].referenceView)
static uint64_t gStripControlDrawer  = 0;
static uint64_t gStripPickerOverlayWin = 0;     // Full-screen overlay UIWindow for the picker.
static uint64_t gStripTransitionShieldWin = 0;  // Brief dimmer below floats to mask app transitions.
static uint64_t gStripPickerPanel    = 0;       // Picker panel view. -tag carries the command code.
static uint64_t gStripPickerTopLabel = 0;       // Hidden label storing chosen top bundle id.
static uint64_t gStripPickerBottomLabel = 0;    // Hidden label storing chosen bottom bundle id.
static uint64_t gStripPickerTopChip  = 0;       // Visible chip label (top slot).
static uint64_t gStripPickerBottomChip = 0;     // Visible chip label (bottom slot).
static uint64_t gStripPickerTopIcon  = 0;       // Top slot UIImageView (icon).
static uint64_t gStripPickerBottomIcon = 0;     // Bottom slot UIImageView (icon).
static uint64_t gStripPickerTopChipCard = 0;    // The wrapping card around the top chip (for highlight tinting).
static uint64_t gStripPickerBottomChipCard = 0; // Same for bottom.
static uint64_t gStripPickerPendingBidLabel = 0;// Hidden label set by each tile tap; Cyanide reads on poll.
static volatile int gStripPickerNextSlot = 0;   // 0 = next tap fills top, 1 = next tap fills bottom.
static uint64_t gStripRows[2]        = {0};
static uint64_t gStripLives[2]       = {0};
static char     gStripPickerTopBid[128] = {0};
static char     gStripPickerBottomBid[128] = {0};
static volatile int gStripControlLoopRunning = 0;
static volatile int gStripControlLoopStop = 0;
static int gStripLockNotifyToken = NOTIFY_TOKEN_INVALID;
static int gStripBlankedNotifyToken = NOTIFY_TOKEN_INVALID;
static int gStripDisplayStatusNotifyToken = NOTIFY_TOKEN_INVALID;
static volatile int gStripPickerApplyBusy = 0;
static volatile uint64_t gStripPickerCooldownUntilMS = 0;

// Picker command codes carried in -[gStripPickerPanel tag]. Cyanide polls the
// tag every few ticks; non-zero triggers a dispatch and is then cleared back
// to 0 by the poller.
enum {
    kStripPickerCmdNone     = 0,
    kStripPickerCmdApply    = 1,
    kStripPickerCmdSwap     = 2,
    kStripPickerCmdSplit    = 3,
    kStripPickerCmdStrip    = 4,
    kStripPickerCmdClose    = 5,
    kStripPickerCmdIconTap  = 6,    // User tapped a tile; pending bid label has the bid.
    kStripPickerCmdSelectTop= 7,    // User tapped the top chip card → make top the next slot.
    kStripPickerCmdSelectBot= 8,    // User tapped the bottom chip card → make bottom the next slot.
    kStripPickerCmdRespring = 9,    // Gear icon → respring SpringBoard.
    kStripPickerCmdShow     = 10,   // Stage/hot-corner swipe -> reveal picker.
};

typedef struct {
    double x;
    double y;
    double width;
    double height;
} StripRect;

static bool stagestrip_set_scene_settings_live(uint64_t scene, const char *bid);
static bool stagestrip_set_scene_foreground_via_updater(uint64_t scene,
                                                        int index,
                                                        const char *bid);
static void stagestrip_handle_bundle_id(uint64_t handle, char *out, size_t outLen);
static uint64_t stagestrip_install_picker_overlay(uint64_t app,
                                                  uint64_t windowScene,
                                                  double sw,
                                                  double sh);
static int  stagestrip_poll_picker_command(void);
static bool stagestrip_apply_picker_selection(const char *top, const char *bottom);
static bool stagestrip_bid_short_name(const char *bid, char *out, size_t outLen);
static void stagestrip_set_frame_fast(uint64_t obj, StripRect rect);

static bool stagestrip_read_notify_state(const char *name, int *token, uint64_t *stateOut)
{
    if (!name || !token || !stateOut) return false;
    if (*token == NOTIFY_TOKEN_INVALID) {
        notify_register_check(name, token);
    }
    if (*token == NOTIFY_TOKEN_INVALID) return false;
    uint64_t state = 0;
    if (notify_get_state(*token, &state) != NOTIFY_STATUS_OK) return false;
    *stateOut = state;
    return true;
}

static bool stagestrip_screen_inactive(void)
{
    uint64_t state = 0;
    if (stagestrip_read_notify_state("com.apple.springboard.lockstate",
                                     &gStripLockNotifyToken,
                                     &state) &&
        state != 0) {
        return true;
    }
    if (stagestrip_read_notify_state("com.apple.springboard.hasBlankedScreen",
                                     &gStripBlankedNotifyToken,
                                     &state) &&
        state != 0) {
        return true;
    }
    if (stagestrip_read_notify_state("com.apple.iokit.hid.displayStatus",
                                     &gStripDisplayStatusNotifyToken,
                                     &state) &&
        state == 0) {
        return true;
    }
    return false;
}
static void stagestrip_resize_host_view_frame(uint64_t view, double w, double h);
static void stagestrip_raise_pan_handles_slot(StripFloatSlot *S);
static bool stagestrip_send_double(uint64_t obj, const char *sel, double v);
static uint64_t stagestrip_make_invocation(uint64_t target,
                                           const char *selName,
                                           const void *arg,
                                           size_t argSize);
static uint64_t stagestrip_make_bool_invocation(uint64_t target,
                                                const char *selName,
                                                bool value);
static uint64_t stagestrip_make_double_invocation(uint64_t target,
                                                  const char *selName,
                                                  double value);
static void stagestrip_schedule_invocation(uint64_t owner, uint64_t inv, double delay);
static void stagestrip_show_transition_shield(double alpha);
static void stagestrip_hide_transition_shield_after(double delay);
static uint64_t stagestrip_make_text_label(const char *text,
                                           double x, double y, double w, double h);
static void stagestrip_set_background_white(uint64_t view, double white, double alpha);

static bool stagestrip_should_log_tick(void)
{
    return gStripApplyTick == 1;
}

static uint64_t stagestrip_now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000ULL + (uint64_t)tv.tv_usec / 1000ULL;
}

// ---------------------------------------------------------------------------
// Resolve SBSLaunchApplicationWithIdentifier inside SpringBoard via dlsym on
// the remote side. Cached for the rest of the session.
// ---------------------------------------------------------------------------

static uint64_t stagestrip_resolve_launch_addr(void)
{
    if (gStripLaunchAddr) return gStripLaunchAddr;

    uint64_t nameBuf = r_alloc_str("SBSLaunchApplicationWithIdentifier");
    if (!nameBuf) return 0;
    // RTLD_DEFAULT on darwin is (void *)-2. The remote dlsym call returns the
    // function's loaded address in SpringBoard's address space.
    uint64_t addr = r_dlsym_call(R_TIMEOUT, "dlsym",
                                 (uint64_t)-2, nameBuf, 0, 0, 0, 0, 0, 0);
    r_free(nameBuf);
    if (!addr) {
        printf("[STAGE] resolve: SBSLaunchApplicationWithIdentifier not found\n");
        return 0;
    }
    gStripLaunchAddr = addr;
    printf("[STAGE] resolve: SBSLaunchApplicationWithIdentifier=0x%llx\n", addr);
    return addr;
}

// ---------------------------------------------------------------------------
// Install the "cyanideStageStripOpen:" method on NSString. Its IMP points at
// SBSLaunchApplicationWithIdentifier, so when UIKit dispatches the gesture's
// action via objc_msgSend(bundleIdString, cyanideStageStripOpen:, sender) the
// arm64 calling convention lands the bundle id in x0 and a (non-zero) SEL
// pointer in x1 — which the C function reads as `suspended=YES`. This is the
// trick that avoids needing to inject any new code into SpringBoard.
// ---------------------------------------------------------------------------

static bool stagestrip_ensure_open_method(void)
{
    if (gStripOpenMethodAdded) return true;

    uint64_t launchAddr = stagestrip_resolve_launch_addr();
    if (!launchAddr) return false;

    uint64_t NSString = r_class("NSString");
    if (!r_is_objc_ptr(NSString)) {
        printf("[STAGE] open: NSString class missing\n");
        return false;
    }

    uint64_t sel = r_sel("cyanideStageStripOpen:");
    if (!sel) {
        printf("[STAGE] open: sel registration failed\n");
        return false;
    }

    uint64_t typesBuf = r_alloc_str("i@:@");
    if (!typesBuf) return false;

    uint64_t added = r_dlsym_call(R_TIMEOUT, "class_addMethod",
                                  NSString, sel, launchAddr, typesBuf,
                                  0, 0, 0, 0);
    r_free(typesBuf);
    // class_addMethod returns NO if the class already has that selector — fine
    // on a respring where state survived. We treat both outcomes as success.
    gStripOpenMethodAdded = true;
    printf("[STAGE] open: cyanideStageStripOpen: installed on NSString added=%llu\n",
           added & 0xff);
    return true;
}

static bool stagestrip_launch_suspended(const char *bid)
{
    if (!bid || !*bid) return false;

    uint64_t bidStr = r_nsstr_retained(bid);
    if (!r_is_objc_ptr(bidStr)) return false;

    uint64_t ok = r_dlsym_call(R_TIMEOUT, "SBSLaunchApplicationWithIdentifier",
                               bidStr, 1, 0, 0, 0, 0, 0, 0);
    r_msg2_main(bidStr, "release", 0, 0, 0, 0);
    printf("[STAGE] launch: suspended bid=%s result=%llu\n", bid, ok);
    return (ok & 0xff) != 0;
}

// Same as stagestrip_launch_suspended but passes suspended=NO, so the target
// app comes up in the foreground (used by the picker cog to open Cyanide's
// own settings app).
static bool stagestrip_launch_foreground(const char *bid)
{
    if (!bid || !*bid) return false;

    uint64_t bidStr = r_nsstr_retained(bid);
    if (!r_is_objc_ptr(bidStr)) return false;

    uint64_t ok = r_dlsym_call(R_TIMEOUT, "SBSLaunchApplicationWithIdentifier",
                               bidStr, 0, 0, 0, 0, 0, 0, 0);
    r_msg2_main(bidStr, "release", 0, 0, 0, 0);
    printf("[STAGE] launch: foreground bid=%s result=%llu\n", bid, ok);
    return (ok & 0xff) != 0;
}

// ---------------------------------------------------------------------------
// Read a remote NSString's UTF-8 contents into a local buffer.
// ---------------------------------------------------------------------------

static bool stagestrip_read_remote_cstr(uint64_t addr, char *buf, size_t maxLen)
{
    if (!addr || !buf || maxLen == 0) return false;
    size_t i = 0;
    while (i + 8 <= maxLen) {
        uint64_t word = remote_read64(addr + i);
        memcpy(buf + i, &word, 8);
        for (size_t k = 0; k < 8; k++) {
            if (buf[i + k] == '\0') return true;
        }
        i += 8;
    }
    buf[maxLen - 1] = '\0';
    return true;
}

// Mirrors killallapps' filter — drop SpringBoard, lockscreen, widget renderers,
// XPC services, and other things that are technically "running" but never
// appear as switcher cards.
static bool stagestrip_bid_is_user_app(const char *bid)
{
    if (!bid || !*bid) return false;

    static const char *deny_exact[] = {
        "com.zeroxjf.ios-cyanide1",
        "com.apple.springboard",
        "com.apple.PineBoard",
        "com.apple.InCallService",
        "com.apple.AccessibilityUIServer",
        "com.apple.CarPlayTemplateUIHost",
        "com.apple.CarPlayTemplateUIHost.legacy",
        "com.apple.siri.IntelligentLight",
        "com.apple.mobilesms.compose",
        "com.apple.Passcode",
        "com.apple.PineBoard.tvOSPushScreen",
        NULL,
    };
    for (int i = 0; deny_exact[i]; i++) {
        if (strcmp(bid, deny_exact[i]) == 0) return false;
    }

    static const char *deny_sub[] = {
        "WidgetRenderer", "PickerService", "ExtensionService",
        "ViewService", "UIService", "UIHost",
        ".XPCService", ".extension", ".Extension",
        NULL,
    };
    for (int i = 0; deny_sub[i]; i++) {
        if (strstr(bid, deny_sub[i])) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Enumerate currently-running apps and copy their bundle ids into outBids.
// Returns the count actually written.
// ---------------------------------------------------------------------------

typedef struct {
    char bid[128];
    uint64_t appPtr; // remote SBApplication pointer (used for icon fetch)
} StripAppEntry;

static int stagestrip_collect_apps(StripAppEntry *out, int maxOut)
{
    if (!out || maxOut <= 0) return 0;

    uint64_t SBAC = r_class("SBApplicationController");
    if (!r_is_objc_ptr(SBAC)) { printf("[STAGE] collect: SBApplicationController missing\n"); return 0; }

    uint64_t inst = r_msg2_main(SBAC, "sharedInstance", 0, 0, 0, 0);
    if (!r_is_objc_ptr(inst)) { printf("[STAGE] collect: sharedInstance nil\n"); return 0; }

    uint64_t apps = r_msg2_main(inst, "runningApplications", 0, 0, 0, 0);
    if (!r_is_objc_ptr(apps)) { printf("[STAGE] collect: runningApplications nil\n"); return 0; }

    uint64_t count = r_msg2_main(apps, "count", 0, 0, 0, 0);
    if (count == 0 || count > 256) {
        printf("[STAGE] collect: implausible count=%llu\n", count);
        return 0;
    }

    int written = 0;
    for (uint64_t i = 0; i < count && written < maxOut; i++) {
        uint64_t app = r_msg2_main(apps, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(app)) continue;

        uint64_t bidObj = r_msg2_main(app, "bundleIdentifier", 0, 0, 0, 0);
        if (!r_is_objc_ptr(bidObj)) continue;
        uint64_t cstr = r_msg2_main(bidObj, "UTF8String", 0, 0, 0, 0);
        if (!cstr) continue;

        char buf[128] = {0};
        if (!stagestrip_read_remote_cstr(cstr, buf, sizeof(buf))) continue;
        if (!stagestrip_bid_is_user_app(buf)) continue;

        memset(&out[written], 0, sizeof(out[written]));
        strncpy(out[written].bid, buf, sizeof(out[written].bid) - 1);
        out[written].appPtr = app;
        written++;
    }

    printf("[STAGE] collect: %d eligible apps (of %llu running)\n", written, count);
    return written;
}

// ---------------------------------------------------------------------------
// Fetch the icon image for a bundle id. On iOS 26 the private UIImage helper
// `_applicationIconImageForBundleIdentifier:format:scale:` works for every
// installed bundle id (and is one round-trip), so try it first. The legacy
// SBIconController path only knows about home-screen icons and adds ~8
// RemoteCalls per app for nothing in iOS 26 — kept only as a fallback for
// older builds where the private UIImage selector isn't present.
// ---------------------------------------------------------------------------

// Cached at picker-build time so we don't re-resolve the class/responds combo
// for every one of the ~200 tiles we install. stagestrip_picker_build_cache_reset
// is called at the start of each picker install; *_release is called at the
// end so any retained NSString stash is freed once.
static uint64_t gStripIconCacheUIImage   = 0;
static int      gStripIconCacheRespPriv  = -1; // -1 = unknown, 0 = no, 1 = yes
static int      gStripIconCacheTriedSBIC = 0;
static uint64_t gStripIconCacheModel     = 0;
static uint64_t gStripPickerBuildUIButton    = 0;
static uint64_t gStripPickerBuildUIImageView = 0;
static uint64_t gStripPickerBuildContinuous  = 0; // retained "continuous"
static int      gStripPickerBuildRespCurve   = -1; // CALayer setCornerCurve:

static void stagestrip_picker_build_cache_reset(void)
{
    gStripIconCacheUIImage       = 0;
    gStripIconCacheRespPriv      = -1;
    gStripIconCacheTriedSBIC     = 0;
    gStripIconCacheModel         = 0;
    gStripPickerBuildUIButton    = 0;
    gStripPickerBuildUIImageView = 0;
    gStripPickerBuildContinuous  = 0;
    gStripPickerBuildRespCurve   = -1;
}

static void stagestrip_picker_build_cache_release(void)
{
    if (r_is_objc_ptr(gStripPickerBuildContinuous)) {
        r_msg2_main(gStripPickerBuildContinuous, "release", 0, 0, 0, 0);
    }
    gStripPickerBuildContinuous = 0;
}

// Apply the "continuous" cornerCurve to a CALayer using a shared retained
// NSString. The first caller per picker build pays one r_nsstr_retained;
// every subsequent caller pays nothing for the string.
static void stagestrip_picker_apply_continuous_curve(uint64_t layer)
{
    if (!r_is_objc_ptr(layer)) return;
    if (gStripPickerBuildRespCurve < 0) {
        gStripPickerBuildRespCurve = r_responds(layer, "setCornerCurve:") ? 1 : 0;
    }
    if (gStripPickerBuildRespCurve != 1) return;
    if (!r_is_objc_ptr(gStripPickerBuildContinuous)) {
        gStripPickerBuildContinuous = r_nsstr_retained("continuous");
    }
    if (r_is_objc_ptr(gStripPickerBuildContinuous)) {
        r_msg2_main(layer, "setCornerCurve:", gStripPickerBuildContinuous, 0, 0, 0);
    }
}

static uint64_t stagestrip_fetch_icon_image(const char *bid)
{
    if (!bid || !*bid) return 0;

    uint64_t bidStr = r_cfstr(bid);
    if (!bidStr) return 0;

    uint64_t img = 0;

    // Path 1 (preferred on iOS 26): private UIImage class helper. Resolve
    // class + responds:_applicationIconImageForBundleIdentifier:format:scale:
    // exactly once per picker build.
    if (!gStripIconCacheUIImage)
        gStripIconCacheUIImage = r_class("UIImage");
    if (r_is_objc_ptr(gStripIconCacheUIImage) && gStripIconCacheRespPriv < 0) {
        gStripIconCacheRespPriv = r_responds(
            gStripIconCacheUIImage,
            "_applicationIconImageForBundleIdentifier:format:scale:") ? 1 : 0;
    }
    if (r_is_objc_ptr(gStripIconCacheUIImage) && gStripIconCacheRespPriv == 1) {
        int64_t format = 2;        // SBIconImageFormatHomeScreen / 60pt
        double scale = 2.0;
        img = r_msg2_main_raw(gStripIconCacheUIImage,
            "_applicationIconImageForBundleIdentifier:format:scale:",
            &bidStr, sizeof(bidStr),
            &format, sizeof(format),
            &scale,  sizeof(scale),
            NULL, 0);
    }

    // Path 2 (legacy fallback): SBIconController → iconModel → SBApplicationIcon
    // → image. Only walked once per picker build; iconModel handle cached.
    if (!r_is_objc_ptr(img)) {
        if (!gStripIconCacheTriedSBIC) {
            gStripIconCacheTriedSBIC = 1;
            uint64_t SBIC = r_class("SBIconController");
            uint64_t ic = r_is_objc_ptr(SBIC)
                ? r_msg2_main(SBIC, "sharedInstance", 0, 0, 0, 0) : 0;
            uint64_t mgr = r_is_objc_ptr(ic) && r_responds(ic, "iconManager")
                ? r_msg2_main(ic, "iconManager", 0, 0, 0, 0) : 0;
            gStripIconCacheModel = r_is_objc_ptr(mgr) && r_responds(mgr, "iconModel")
                ? r_msg2_main(mgr, "iconModel", 0, 0, 0, 0) : 0;
        }
        uint64_t model = gStripIconCacheModel;
        if (r_is_objc_ptr(model)) {
            uint64_t icon = 0;
            if (r_responds(model, "applicationIconForBundleIdentifier:")) {
                icon = r_msg2_main(model, "applicationIconForBundleIdentifier:", bidStr, 0, 0, 0);
            }
            if (!r_is_objc_ptr(icon) && r_responds(model, "expectedIconForDisplayIdentifier:")) {
                icon = r_msg2_main(model, "expectedIconForDisplayIdentifier:", bidStr, 0, 0, 0);
            }
            if (r_is_objc_ptr(icon)) {
                if (r_responds(icon, "iconImage")) {
                    img = r_msg2_main(icon, "iconImage", 0, 0, 0, 0);
                }
                if (!r_is_objc_ptr(img) && r_responds(icon, "getIconImage:")) {
                    img = r_msg2_main(icon, "getIconImage:", 2, 0, 0, 0);
                }
                if (!r_is_objc_ptr(img) && r_responds(icon, "generateIconImage:")) {
                    img = r_msg2_main(icon, "generateIconImage:", 2, 0, 0, 0);
                }
            }
        }
    }

    return img;
}

// Build a small colored placeholder view with the bid's leading letter.
// Used when stagestrip_fetch_icon_image returns nil — so every tile is
// visually identifiable even when the icon-fetch APIs fail (e.g., team-ID
// suffixed bids that the icon model doesn't recognise).
static uint64_t stagestrip_make_letter_placeholder(const char *bid, double side)
{
    if (!bid || !*bid) return 0;

    char letter[2] = { '\0', '\0' };
    char shortName[64] = {0};
    stagestrip_bid_short_name(bid, shortName, sizeof(shortName));
    const char *src = shortName[0] ? shortName : bid;
    while (*src && (*src == '.' || *src == '_')) src++;
    letter[0] = *src ? (char)toupper((unsigned char)*src) : '?';

    // Deterministic color from bid hash.
    uint32_t h = 5381;
    for (const char *p = bid; *p; p++) h = (h * 33u) ^ (unsigned char)*p;
    double hue = (double)(h % 360u) / 360.0;
    double r, g, b;
    {
        double s = 0.5, v = 0.78;
        double c = v * s;
        double hp = hue * 6.0;
        double x = c * (1.0 - fabs(fmod(hp, 2.0) - 1.0));
        double m = v - c;
        if      (hp < 1.0) { r = c; g = x; b = 0; }
        else if (hp < 2.0) { r = x; g = c; b = 0; }
        else if (hp < 3.0) { r = 0; g = c; b = x; }
        else if (hp < 4.0) { r = 0; g = x; b = c; }
        else if (hp < 5.0) { r = x; g = 0; b = c; }
        else               { r = c; g = 0; b = x; }
        r += m; g += m; b += m;
    }

    uint64_t UIView = r_class("UIView");
    uint64_t alloc = r_msg2_main(UIView, "alloc", 0, 0, 0, 0);
    uint64_t bg = r_is_objc_ptr(alloc) ? r_msg2_main(alloc, "init", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(bg)) return 0;
    stagestrip_set_frame_fast(bg, (StripRect){ 0, 0, side, side });
    r_msg2_main(bg, "setUserInteractionEnabled:", 0, 0, 0, 0);

    uint64_t UIColor = r_class("UIColor");
    if (r_is_objc_ptr(UIColor) &&
        r_responds(UIColor, "colorWithRed:green:blue:alpha:")) {
        double a = 1.0;
        uint64_t color = r_msg2_main_raw(UIColor, "colorWithRed:green:blue:alpha:",
                                         &r, sizeof(r),
                                         &g, sizeof(g),
                                         &b, sizeof(b),
                                         &a, sizeof(a));
        if (r_is_objc_ptr(color))
            r_msg2_main(bg, "setBackgroundColor:", color, 0, 0, 0);
    }
    uint64_t layer = r_msg2_main(bg, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        stagestrip_send_double(layer, "setCornerRadius:", side * 0.22);
        if (r_responds(layer, "setCornerCurve:")) {
            uint64_t cont = r_nsstr_retained("continuous");
            if (r_is_objc_ptr(cont)) {
                r_msg2_main(layer, "setCornerCurve:", cont, 0, 0, 0);
                r_msg2_main(cont, "release", 0, 0, 0, 0);
            }
        }
        r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
    }

    uint64_t letterLabel = stagestrip_make_text_label(letter, 0, 0, side, side);
    if (r_is_objc_ptr(letterLabel)) {
        stagestrip_set_background_white(letterLabel, 0.0, 0.0);
        if (r_responds(letterLabel, "setTextAlignment:"))
            r_msg2_main(letterLabel, "setTextAlignment:", 1 /* center */, 0, 0, 0);
        r_msg2_main(bg, "addSubview:", letterLabel, 0, 0, 0);
    }
    return bg;
}

// ---------------------------------------------------------------------------
// Build (or rebuild) the strip overlay. Returns true on success.
// ---------------------------------------------------------------------------

typedef struct {
    double x;
    double y;
} StripPoint;

typedef struct {
    uint64_t handle;
    uint64_t scene;
    char bid[128];
} StripScenePick;

static bool stagestrip_send_rect(uint64_t obj, const char *sel,
                                 double x, double y, double w, double h)
{
    if (!r_is_objc_ptr(obj)) return false;
    StripRect rect = { x, y, w, h };
    r_msg2_main_raw(obj, sel,
                    &rect, sizeof(rect),
                    NULL, 0, NULL, 0, NULL, 0);
    return true;
}

static bool stagestrip_send_double(uint64_t obj, const char *sel, double v)
{
    if (!r_is_objc_ptr(obj)) return false;
    r_msg2_main_raw(obj, sel,
                    &v, sizeof(v),
                    NULL, 0, NULL, 0, NULL, 0);
    return true;
}

static void stagestrip_set_transform_thread(uint64_t obj, CGAffineTransform t)
{
    if (!r_is_objc_ptr(obj)) return;
    r_msg2_main_raw(obj, "setTransform:",
                    &t, sizeof(t),
                    NULL, 0, NULL, 0, NULL, 0);
}

static bool stagestrip_view_is_hidden(uint64_t obj)
{
    if (!r_is_objc_ptr(obj) || !r_responds(obj, "isHidden")) return false;
    return (r_msg2_main(obj, "isHidden", 0, 0, 0, 0) & 0xff) != 0;
}

static void stagestrip_animation_begin(double duration)
{
    uint64_t UIView = r_class("UIView");
    if (!r_is_objc_ptr(UIView)) return;
    r_msg2_main(UIView, "beginAnimations:context:", 0, 0, 0, 0);
    r_msg2_main(UIView, "setAnimationBeginsFromCurrentState:", 1, 0, 0, 0);
    r_msg2_main(UIView, "setAnimationCurve:", 0 /* easeInOut */, 0, 0, 0);
    r_msg2_main_raw(UIView, "setAnimationDuration:",
                    &duration, sizeof(duration),
                    NULL, 0, NULL, 0, NULL, 0);
}

static void stagestrip_animation_commit(void)
{
    uint64_t UIView = r_class("UIView");
    if (r_is_objc_ptr(UIView))
        r_msg2_main(UIView, "commitAnimations", 0, 0, 0, 0);
}

static StripSize stagestrip_stage_size_for_request(int maxSlots)
{
    // Default to "take most of the screen on the horizontal axis" — the
    // user explicitly asked for nearly full-width tiles, mirroring StageDuo's
    // split-view layout where each app gets its own near-full-width panel.
    CGRect b = UIScreen.mainScreen.bounds;
    double sw = isfinite(b.size.width)  && b.size.width  >= 200.0 ? b.size.width  : 390.0;
    double sh = isfinite(b.size.height) && b.size.height >= 200.0 ? b.size.height : 844.0;
    double w  = sw - 16.0;          // ~full screen width with a small inset
    double h  = sh * 0.40;          // ~40% screen height per slot (two slots stack to 80%)
    if (h < 280.0) h = 280.0;
    if (maxSlots <= 1) return (StripSize){ w, h * 1.7 };
    if (maxSlots == 2) return (StripSize){ w, h };
    if (maxSlots == 3) return (StripSize){ w, h * 1.2 };
    return (StripSize){ w, h * 1.5 };
}

static void stagestrip_enable_interaction_tree(uint64_t view, int depth)
{
    if (!r_is_objc_ptr(view) || depth < 0) return;
    if (r_responds(view, "setUserInteractionEnabled:"))
        r_msg2_main(view, "setUserInteractionEnabled:", 1, 0, 0, 0);
    if (r_responds(view, "setMultipleTouchEnabled:"))
        r_msg2_main(view, "setMultipleTouchEnabled:", 1, 0, 0, 0);
    if (r_responds(view, "setExclusiveTouch:"))
        r_msg2_main(view, "setExclusiveTouch:", 0, 0, 0, 0);

    uint64_t subs = r_responds(view, "subviews")
        ? r_msg2_main(view, "subviews", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(subs)) return;
    uint64_t count = r_msg2_main(subs, "count", 0, 0, 0, 0);
    if (count == 0 || count > 32) return;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t child = r_msg2_main(subs, "objectAtIndex:", i, 0, 0, 0);
        stagestrip_enable_interaction_tree(child, depth - 1);
    }
}

static uint64_t stagestrip_window_for_app(uint64_t app)
{
    uint64_t keyWin = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    if (r_is_objc_ptr(keyWin)) return keyWin;

    uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
    if (!r_is_objc_ptr(windows)) return 0;
    uint64_t count = r_msg2_main(windows, "count", 0, 0, 0, 0);
    if (count == 0 || count > 64) return 0;
    return r_msg2_main(windows, "objectAtIndex:", 0, 0, 0, 0);
}

static void stagestrip_drop_subviews(uint64_t parent)
{
    if (!r_is_objc_ptr(parent)) return;
    uint64_t subs = r_msg2_main(parent, "subviews", 0, 0, 0, 0);
    if (!r_is_objc_ptr(subs)) return;
    uint64_t count = r_msg2_main(subs, "count", 0, 0, 0, 0);
    if (count == 0 || count > 64) return;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t v = r_msg2_main(subs, "objectAtIndex:", i, 0, 0, 0);
        if (r_is_objc_ptr(v)) r_msg2_main(v, "removeFromSuperview", 0, 0, 0, 0);
    }
}

// Fetch the primary FBScene for an SBApplication. Probes the modern
// (-mainScene) and legacy (-scenes[0]) accessors. Returns 0 when neither
// exists or the scene has been torn down.
static uint64_t stagestrip_fetch_scene_for_app(uint64_t sbApp)
{
    if (!r_is_objc_ptr(sbApp)) return 0;

    static const char *const sceneSels[] = {
        "mainScene",                 // iOS 14-17 SBApplication
        "defaultScene",              // some intermediate variants
        "defaultUIScene",            // iOS 13 path
        NULL,
    };
    for (int i = 0; sceneSels[i]; i++) {
        if (!r_responds(sbApp, sceneSels[i])) continue;
        uint64_t s = r_msg2_main(sbApp, sceneSels[i], 0, 0, 0, 0);
        if (r_is_objc_ptr(s)) return s;
    }

    if (r_responds(sbApp, "scenes")) {
        uint64_t arr = r_msg2_main(sbApp, "scenes", 0, 0, 0, 0);
        if (r_is_objc_ptr(arr)) {
            uint64_t cnt = r_msg2_main(arr, "count", 0, 0, 0, 0);
            if (cnt > 0 && cnt < 16) {
                uint64_t s = r_msg2_main(arr, "objectAtIndex:", 0, 0, 0, 0);
                if (r_is_objc_ptr(s)) return s;
            }
        }
    }
    return 0;
}

// Try to build a live preview view that hosts the scene's CoreAnimation
// layer tree (the StageDuo trick: _UISceneLayerHostContainerView). The
// iOS 26 no-dylib path must not poke FBSSettings foreground/background
// bits directly; the StageDuo report shows those writes only on card sleep.
// Returns 0 if any step fails (caller falls back to icon).
static uint64_t stagestrip_make_live_preview(uint64_t scene, double w, double h)
{
    if (!r_is_objc_ptr(scene)) return 0;

    if (kStripMutateSceneSettingsLive)
        stagestrip_set_scene_settings_live(scene, "sidebar-preview");

    uint64_t hostCls = r_class("_UISceneLayerHostContainerView");
    if (!r_is_objc_ptr(hostCls)) {
        printf("[STAGE] live: _UISceneLayerHostContainerView class missing\n");
        return 0;
    }
    uint64_t alloc = r_msg2_main(hostCls, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(alloc)) return 0;

    // Probe init signatures in order of preference. iOS 26 / modern UIKit
    // exposes -initWithScene:; older variants take a layer.
    uint64_t host = 0;
    if (r_responds(alloc, "initWithScene:")) {
        host = r_msg2_main(alloc, "initWithScene:", scene, 0, 0, 0);
        if (r_is_objc_ptr(host)) printf("[STAGE] live: host via initWithScene:\n");
    }
    if (!r_is_objc_ptr(host) && r_responds(alloc, "initWithSceneLayer:")) {
        uint64_t layer = 0;
        if (r_responds(scene, "clientLayer"))
            layer = r_msg2_main(scene, "clientLayer", 0, 0, 0, 0);
        if (!r_is_objc_ptr(layer) && r_responds(scene, "layer"))
            layer = r_msg2_main(scene, "layer", 0, 0, 0, 0);
        if (r_is_objc_ptr(layer)) {
            host = r_msg2_main(alloc, "initWithSceneLayer:", layer, 0, 0, 0);
            if (r_is_objc_ptr(host)) printf("[STAGE] live: host via initWithSceneLayer:\n");
        }
    }
    if (!r_is_objc_ptr(host)) {
        printf("[STAGE] live: host init failed\n");
        return 0;
    }

    stagestrip_send_rect(host, "setFrame:", 0.0, 0.0, w, h);
    r_msg2_main(host, "setClipsToBounds:", 1, 0, 0, 0);
    r_msg2_main(host, "setUserInteractionEnabled:", 0, 0, 0, 0); // taps go to slot
    return host;
}

static uint64_t stagestrip_make_slot(uint64_t sbApp, uint64_t fallbackIcon, const char *bid,
                                     double slotY)
{
    uint64_t UIView = r_class("UIView");
    if (!r_is_objc_ptr(UIView)) return 0;
    uint64_t alloc = r_msg2_main(UIView, "alloc", 0, 0, 0, 0);
    uint64_t slot = r_is_objc_ptr(alloc) ? r_msg2_main(alloc, "init", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(slot)) return 0;

    double slotX = (kStripWidth - kStripSlotW) / 2.0;
    stagestrip_send_rect(slot, "setFrame:", slotX, slotY, kStripSlotW, kStripSlotH);
    r_msg2_main(slot, "setUserInteractionEnabled:", 1, 0, 0, 0);
    r_msg2_main(slot, "setClipsToBounds:", 1, 0, 0, 0);

    uint64_t layer = r_msg2_main(slot, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        stagestrip_send_double(layer, "setCornerRadius:", kStripSlotCornerR);
        r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
    }

    // First try the StageDuo-style live preview (scene-layer host view).
    uint64_t scene = stagestrip_fetch_scene_for_app(sbApp);
    uint64_t live = stagestrip_make_live_preview(scene, kStripSlotW, kStripSlotH);
    if (r_is_objc_ptr(live)) {
        r_msg2_main(slot, "addSubview:", live, 0, 0, 0);
    } else {
        // Fallback: centred icon image over a dark tile.
        uint64_t UIColor = r_class("UIColor");
        if (r_is_objc_ptr(UIColor) && r_responds(UIColor, "colorWithWhite:alpha:")) {
            double white = 0.12;
            double alpha = 0.95;
            uint64_t bg = r_msg2_main_raw(UIColor, "colorWithWhite:alpha:",
                                          &white, sizeof(white),
                                          &alpha, sizeof(alpha),
                                          NULL, 0, NULL, 0);
            if (r_is_objc_ptr(bg)) r_msg2_main(slot, "setBackgroundColor:", bg, 0, 0, 0);
        }
        if (r_is_objc_ptr(fallbackIcon)) {
            uint64_t UIImageView = r_class("UIImageView");
            uint64_t ivAlloc = r_is_objc_ptr(UIImageView)
                ? r_msg2_main(UIImageView, "alloc", 0, 0, 0, 0) : 0;
            uint64_t iv = r_is_objc_ptr(ivAlloc)
                ? r_msg2_main(ivAlloc, "init", 0, 0, 0, 0) : 0;
            if (r_is_objc_ptr(iv)) {
                double iconSide = 56.0;
                double iconX = (kStripSlotW - iconSide) / 2.0;
                double iconY = (kStripSlotH - iconSide) / 2.0;
                stagestrip_send_rect(iv, "setFrame:", iconX, iconY, iconSide, iconSide);
                r_msg2_main(iv, "setContentMode:", 1 /* scaleAspectFit */, 0, 0, 0);
                r_msg2_main(iv, "setImage:", fallbackIcon, 0, 0, 0);
                r_msg2_main(iv, "setUserInteractionEnabled:", 0, 0, 0, 0);
                r_msg2_main(slot, "addSubview:", iv, 0, 0, 0);
            }
        }
    }

    // Attach the bundle-id NSString to the slot. We need this NSString to
    // outlive the gesture install (the gesture's target reference is weak),
    // so we associate it on the slot with RETAIN semantics.
    uint64_t bidStr = r_nsstr_retained(bid);
    if (!r_is_objc_ptr(bidStr)) {
        printf("[STAGE] slot: bid NSString alloc failed for %s\n", bid);
        return slot;
    }

    uint64_t bidKey = r_sel("cyanideStageStripBundleId");
    if (bidKey) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     slot, bidKey, bidStr, 1 /* RETAIN_NONATOMIC */, 0, 0, 0, 0);
    }

    uint64_t tapSel = r_sel("cyanideStageStripOpen:");
    if (!tapSel) return slot;

    uint64_t UITap = r_class("UITapGestureRecognizer");
    if (!r_is_objc_ptr(UITap)) return slot;

    uint64_t grAlloc = r_msg2_main(UITap, "alloc", 0, 0, 0, 0);
    uint64_t gr = r_is_objc_ptr(grAlloc)
        ? r_msg2_main(grAlloc, "initWithTarget:action:", bidStr, tapSel, 0, 0)
        : 0;
    if (!r_is_objc_ptr(gr)) {
        printf("[STAGE] slot: UITapGestureRecognizer init failed\n");
        return slot;
    }
    r_msg2_main(gr, "setNumberOfTapsRequired:", 1, 0, 0, 0);
    if (r_responds(gr, "setCancelsTouchesInView:"))
        r_msg2_main(gr, "setCancelsTouchesInView:", 1, 0, 0, 0);

    r_msg2_main(slot, "addGestureRecognizer:", gr, 0, 0, 0);

    return slot;
}

// Probe whether a bundle id is Cyanide itself (we never want to host our
// own scene in our own floating window — confirmed cause of the previous
// black-tile run).
static bool stagestrip_bid_is_self(const char *bid)
{
    return bid && strcmp(bid, "com.zeroxjf.ios-cyanide1") == 0;
}

// Get the main display SBSceneManager via SBSceneManagerCoordinator. Used to
// resolve a persistence identifier into a live SBApplicationSceneHandle.
static uint64_t stagestrip_main_scene_manager(void)
{
    uint64_t cls = r_class("SBSceneManagerCoordinator");
    if (!r_is_objc_ptr(cls)) {
        printf("[STAGE] mgr: SBSceneManagerCoordinator class missing\n");
        return 0;
    }
    uint64_t mgr = r_msg2_main(cls, "mainDisplaySceneManager", 0, 0, 0, 0);
    if (!r_is_objc_ptr(mgr)) {
        printf("[STAGE] mgr: mainDisplaySceneManager nil\n");
        return 0;
    }
    return mgr;
}

// iOS 26 SpringBoard has a first-party "always live rendering" path used by
// switcher/live overlays. It maps to BacklightServices attributes:
// requestLiveUpdatingForFBSScene: + requestUnrestrictedFramerateForFBSScene:.
// The returned proxy auto-invalidates after 10s, so keep it retained and
// tickle the underlying BLSAssertion timeout while our floating host is up.
static bool stagestrip_assert_live_rendering_for_scene(uint64_t scene, const char *bid)
{
    if (!r_is_objc_ptr(scene)) return false;

    uint64_t providerCls = r_class("SBFAlwaysOnLiveRenderingAssertionProvider");
    if (!r_is_objc_ptr(providerCls) || !r_responds(providerCls, "sharedInstance")) {
        printf("[STAGE] live-render: assertion provider missing\n");
        return false;
    }
    uint64_t provider = r_msg2_main(providerCls, "sharedInstance", 0, 0, 0, 0);
    if (!r_is_objc_ptr(provider) ||
        !r_responds(provider, "acquireLiveRenderingAssertionForFBSScene:reason:")) {
        printf("[STAGE] live-render: provider cannot assert FBSScene\n");
        return false;
    }

    char reason[192] = {0};
    snprintf(reason, sizeof(reason), "Cyanide StageStrip live render%s%s",
             (bid && *bid) ? " " : "", (bid && *bid) ? bid : "");
    uint64_t reasonStr = r_nsstr_retained(reason);
    if (!r_is_objc_ptr(reasonStr)) return false;

    uint64_t proxy = r_msg2_main(provider, "acquireLiveRenderingAssertionForFBSScene:reason:",
                                 scene, reasonStr, 0, 0);
    r_msg2_main(reasonStr, "release", 0, 0, 0, 0);
    if (!r_is_objc_ptr(proxy)) {
        printf("[STAGE] live-render: acquire returned nil scene=0x%llx bid=%s\n",
               scene, bid ? bid : "?");
        return false;
    }

    uint64_t proxyKey = r_sel("cyanideStageStripLiveRenderingProxy");
    if (proxyKey) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     scene, proxyKey, proxy, 1 /* RETAIN_NONATOMIC */, 0, 0, 0, 0);
    }

    uint64_t manager = 0;
    if (r_responds(provider, "_assertionManagerForScene:"))
        manager = r_msg2_main(provider, "_assertionManagerForScene:", scene, 0, 0, 0);

    uint64_t bls = 0;
    if (r_is_objc_ptr(manager)) {
        if (r_responds(manager, "liveRenderingAssertion"))
            bls = r_msg2_main(manager, "liveRenderingAssertion", 0, 0, 0, 0);
        if (!r_is_objc_ptr(bls))
            bls = r_ivar_value(manager, "_liveRenderingAssertion");
    }

    if (!r_is_objc_ptr(bls) && r_is_objc_ptr(manager)) {
        uint64_t attributesProvider = r_ivar_value(manager, "_attributesProvider");
        uint64_t assertionProvider = r_responds(provider, "assertionProvider")
            ? r_msg2_main(provider, "assertionProvider", 0, 0, 0, 0)
            : r_ivar_value(provider, "_assertionProvider");
        uint64_t attrs = r_is_objc_ptr(attributesProvider) &&
                         r_responds(attributesProvider, "assertionAttributes")
            ? r_msg2_main(attributesProvider, "assertionAttributes", 0, 0, 0, 0)
            : 0;
        if (r_is_objc_ptr(assertionProvider) && r_is_objc_ptr(attrs) &&
            r_responds(assertionProvider, "acquireWithExplanation:attributes:")) {
            uint64_t manualReason = r_nsstr_retained("Cyanide StageStrip direct BLS live render");
            if (r_is_objc_ptr(manualReason)) {
                bls = r_msg2_main(assertionProvider, "acquireWithExplanation:attributes:",
                                  manualReason, attrs, 0, 0);
                r_msg2_main(manualReason, "release", 0, 0, 0, 0);
                if (r_is_objc_ptr(bls)) {
                    uint64_t blsKey = r_sel("cyanideStageStripBLSLiveRenderingAssertion");
                    if (blsKey) {
                        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                                     scene, blsKey, bls, 1 /* RETAIN_NONATOMIC */,
                                     0, 0, 0, 0);
                    }
                    printf("[STAGE] live-render: direct BLS assertion=0x%llx attrs=0x%llx\n",
                           bls, attrs);
                } else {
                    printf("[STAGE] live-render: direct BLS acquire returned nil attrs=0x%llx\n",
                           attrs);
                }
            }
        } else {
            printf("[STAGE] live-render: direct BLS unavailable provider=0x%llx attrs=0x%llx\n",
                   assertionProvider, attrs);
        }
    }

    uint64_t timer = 0;
    if (r_is_objc_ptr(bls) && r_responds(bls, "restartTimeoutTimer")) {
        r_msg2_main(bls, "restartTimeoutTimer", 0, 0, 0, 0);

        uint64_t timerKey = r_sel("cyanideStageStripLiveRenderingTimer");
        if (timerKey) {
            uint64_t oldTimer = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                             scene, timerKey, 0, 0, 0, 0, 0, 0);
            bool needTimer = true;
            if (r_is_objc_ptr(oldTimer) && r_responds(oldTimer, "isValid")) {
                needTimer = (r_msg2_main(oldTimer, "isValid", 0, 0, 0, 0) & 0xff) == 0;
            }
            if (needTimer) {
                uint64_t NSTimer = r_class("NSTimer");
                uint64_t restartSel = r_sel("restartTimeoutTimer");
                uint64_t sig = restartSel
                    ? r_msg2_main(bls, "methodSignatureForSelector:", restartSel, 0, 0, 0)
                    : 0;
                uint64_t NSInvocation = r_class("NSInvocation");
                uint64_t inv = (r_is_objc_ptr(NSInvocation) && r_is_objc_ptr(sig))
                    ? r_msg2_main(NSInvocation, "invocationWithMethodSignature:", sig, 0, 0, 0)
                    : 0;
                if (r_is_objc_ptr(inv)) {
                    r_msg2_main(inv, "setTarget:", bls, 0, 0, 0);
                    r_msg2_main(inv, "setSelector:", restartSel, 0, 0, 0);
                    r_msg2_main(inv, "retainArguments", 0, 0, 0, 0);
                }
                if (r_is_objc_ptr(NSTimer) && r_is_objc_ptr(inv) &&
                    r_responds(NSTimer, "scheduledTimerWithTimeInterval:invocation:repeats:")) {
                    double interval = 5.0;
                    uint8_t repeats = 1;
                    timer = r_msg2_main_raw(NSTimer,
                        "scheduledTimerWithTimeInterval:invocation:repeats:",
                        &interval, sizeof(interval),
                        &inv,      sizeof(inv),
                        &repeats,  sizeof(repeats),
                        NULL, 0);
                    if (r_is_objc_ptr(timer)) {
                        double tolerance = 1.0;
                        r_msg2_main_raw(timer, "setTolerance:",
                                        &tolerance, sizeof(tolerance),
                                        NULL, 0, NULL, 0, NULL, 0);
                        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                                     scene, timerKey, timer, 1 /* RETAIN_NONATOMIC */,
                                     0, 0, 0, 0);
                    }
                }
            } else {
                timer = oldTimer;
            }
        }
    }

    gStripLiveScene = scene;
    bool remembered = false;
    for (int i = 0; i < gStripLiveSceneCount; i++) {
        if (gStripLiveScenes[i] == scene) {
            remembered = true;
            break;
        }
    }
    if (!remembered && gStripLiveSceneCount < kStripMaxSlotsHard) {
        gStripLiveScenes[gStripLiveSceneCount++] = scene;
    }
    printf("[STAGE] live-render: scene=0x%llx proxy=0x%llx manager=0x%llx bls=0x%llx timer=0x%llx bid=%s\n",
           scene, proxy, manager, bls, timer, bid ? bid : "?");
    return true;
}

static bool stagestrip_set_scene_settings_live(uint64_t scene, const char *bid)
{
    if (!r_is_objc_ptr(scene)) return false;

    if (!kStripMutateSceneSettingsLive) {
        uint64_t active = r_responds(scene, "isActive")
            ? r_msg2_main(scene, "isActive", 0, 0, 0, 0) : 0;
        uint64_t settings = r_responds(scene, "settings")
            ? r_msg2_main(scene, "settings", 0, 0, 0, 0) : 0;
        uint64_t foreground = r_is_objc_ptr(settings) && r_responds(settings, "isForeground")
            ? r_msg2_main(settings, "isForeground", 0, 0, 0, 0) : 0;
        printf("[STAGE] interact: live settings mutation disabled bid=%s scene=0x%llx active=%llu fg=%llu\n",
               bid ? bid : "?", scene, active & 0xff, foreground & 0xff);
        return false;
    }

    const char *getters[] = { "settings", "clientSettings", NULL };
    bool touched = false;
    bool committed = false;

    for (int i = 0; getters[i]; i++) {
        if (!r_responds(scene, getters[i])) continue;
        uint64_t settings = r_msg2_main(scene, getters[i], 0, 0, 0, 0);
        if (!r_is_objc_ptr(settings)) continue;

        touched = true;
        if (r_responds(settings, "setForeground:"))
            r_msg2_main(settings, "setForeground:", 1, 0, 0, 0);
        if (r_responds(settings, "setBackgrounded:"))
            r_msg2_main(settings, "setBackgrounded:", 0, 0, 0, 0);
        if (r_responds(settings, "setOccluded:"))
            r_msg2_main(settings, "setOccluded:", 0, 0, 0, 0);
        if (r_responds(settings, "setLevel:")) {
            double level = 1.0;
            r_msg2_main_raw(settings, "setLevel:",
                            &level, sizeof(level),
                            NULL, 0, NULL, 0, NULL, 0);
        }

        if (strcmp(getters[i], "clientSettings") == 0) {
            if (r_responds(scene, "updateClientSettings:withTransitionContext:")) {
                r_msg2_main(scene, "updateClientSettings:withTransitionContext:", settings, 0, 0, 0);
                committed = true;
            } else if (r_responds(scene, "_applyClientSettings:")) {
                r_msg2_main(scene, "_applyClientSettings:", settings, 0, 0, 0);
                committed = true;
            } else if (r_responds(scene, "setClientSettings:")) {
                r_msg2_main(scene, "setClientSettings:", settings, 0, 0, 0);
                committed = true;
            }
        } else if (r_responds(scene, "updateSettings:withTransitionContext:")) {
            r_msg2_main(scene, "updateSettings:withTransitionContext:", settings, 0, 0, 0);
            committed = true;
        } else if (r_responds(scene, "_applySettings:")) {
            r_msg2_main(scene, "_applySettings:", settings, 0, 0, 0);
            committed = true;
        } else if (r_responds(scene, "setSettings:")) {
            r_msg2_main(scene, "setSettings:", settings, 0, 0, 0);
            committed = true;
        }
    }

    uint64_t active = r_responds(scene, "isActive")
        ? r_msg2_main(scene, "isActive", 0, 0, 0, 0) : 0;
    uint64_t settings = r_responds(scene, "settings")
        ? r_msg2_main(scene, "settings", 0, 0, 0, 0) : 0;
    uint64_t foreground = r_is_objc_ptr(settings) && r_responds(settings, "isForeground")
        ? r_msg2_main(settings, "isForeground", 0, 0, 0, 0) : 0;
    printf("[STAGE] interact: live settings bid=%s scene=0x%llx touched=%d committed=%d active=%llu fg=%llu\n",
           bid ? bid : "?", scene, touched ? 1 : 0, committed ? 1 : 0,
           active & 0xff, foreground & 0xff);
    return touched;
}

static uint64_t stagestrip_new_uuid_string(void)
{
    uint64_t NSUUID = r_class("NSUUID");
    uint64_t uuid = r_is_objc_ptr(NSUUID) && r_responds(NSUUID, "UUID")
        ? r_msg2_main(NSUUID, "UUID", 0, 0, 0, 0)
        : 0;
    uint64_t string = r_is_objc_ptr(uuid) && r_responds(uuid, "UUIDString")
        ? r_msg2_main(uuid, "UUIDString", 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(string))
        return string;
    return r_nsstr_retained("CyanideStageStripScene");
}

static uint64_t stagestrip_scene_settings_updater_for_scene(uint64_t scene,
                                                            int index,
                                                            const char *bid)
{
    if (!r_is_objc_ptr(scene)) return 0;

    uint64_t updaterKey = r_sel("cyanideStageStripSceneSettingsUpdater");
    uint64_t updater = updaterKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                       scene, updaterKey, 0, 0, 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(updater)) return updater;

    uint64_t cls = r_class("SBSceneSettingsUpdater");
    uint64_t alloc = r_is_objc_ptr(cls)
        ? r_msg2_main(cls, "alloc", 0, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(alloc) ||
        !r_responds(alloc, "initWithScene:persistentIdentifier:level:updatesGeometry:")) {
        printf("[STAGE] updater: class/init unavailable bid=%s scene=0x%llx\n",
               bid ? bid : "?", scene);
        return 0;
    }

    uint64_t persistent = stagestrip_new_uuid_string();
    double level = 1.0;
    uint8_t updatesGeometry = 1;
    updater = r_msg2_main_raw(alloc,
        "initWithScene:persistentIdentifier:level:updatesGeometry:",
        &scene,           sizeof(scene),
        &persistent,      sizeof(persistent),
        &level,           sizeof(level),
        &updatesGeometry, sizeof(updatesGeometry));

    if (r_is_objc_ptr(updater) && updaterKey) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     scene, updaterKey, updater, 1 /* RETAIN_NONATOMIC */,
                     0, 0, 0, 0);
    }

    printf("[STAGE] updater: created updater=0x%llx bid=%s scene=0x%llx role=%d\n",
           updater, bid ? bid : "?", scene, index == 0 ? 1 : 2);
    return updater;
}

static uint64_t stagestrip_schedule_foreground_keepalive(uint64_t scene,
                                                         uint64_t updater,
                                                         const char *bid)
{
    if (!kStripKeepSceneForegroundTimer ||
        !r_is_objc_ptr(scene) ||
        !r_is_objc_ptr(updater) ||
        !r_responds(updater, "setForeground:")) {
        return 0;
    }

    uint64_t timerKey = r_sel("cyanideStageStripForegroundKeepaliveTimer");
    uint64_t timer = timerKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                       scene, timerKey, 0, 0, 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(timer) && r_responds(timer, "isValid") &&
        (r_msg2_main(timer, "isValid", 0, 0, 0, 0) & 0xff)) {
        return timer;
    }

    uint64_t sel = r_sel("setForeground:");
    uint64_t sig = sel ? r_msg2_main(updater, "methodSignatureForSelector:", sel, 0, 0, 0) : 0;
    uint64_t NSInvocation = r_class("NSInvocation");
    uint64_t inv = r_is_objc_ptr(NSInvocation) && r_is_objc_ptr(sig)
        ? r_msg2_main(NSInvocation, "invocationWithMethodSignature:", sig, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(inv)) {
        printf("[STAGE] keepalive: invocation unavailable bid=%s updater=0x%llx\n",
               bid ? bid : "?", updater);
        return 0;
    }

    r_msg2_main(inv, "setTarget:", updater, 0, 0, 0);
    r_msg2_main(inv, "setSelector:", sel, 0, 0, 0);
    uint64_t argBuf = r_dlsym_call(R_TIMEOUT, "malloc", 1, 0, 0, 0, 0, 0, 0, 0);
    if (argBuf) {
        uint8_t yes = 1;
        remote_write(argBuf, &yes, sizeof(yes));
        r_msg2_main(inv, "setArgument:atIndex:", argBuf, 2, 0, 0);
        r_free(argBuf);
    }
    r_msg2_main(inv, "retainArguments", 0, 0, 0, 0);

    uint64_t NSTimer = r_class("NSTimer");
    if (r_is_objc_ptr(NSTimer) &&
        r_responds(NSTimer, "scheduledTimerWithTimeInterval:invocation:repeats:")) {
        double interval = 0.5;
        uint8_t repeats = 1;
        timer = r_msg2_main_raw(NSTimer,
            "scheduledTimerWithTimeInterval:invocation:repeats:",
            &interval, sizeof(interval),
            &inv,      sizeof(inv),
            &repeats,  sizeof(repeats),
            NULL, 0);
    }
    if (!r_is_objc_ptr(timer)) {
        printf("[STAGE] keepalive: timer unavailable bid=%s updater=0x%llx\n",
               bid ? bid : "?", updater);
        return 0;
    }

    if (r_responds(timer, "setTolerance:")) {
        double tolerance = 0.1;
        r_msg2_main_raw(timer, "setTolerance:",
                        &tolerance, sizeof(tolerance),
                        NULL, 0, NULL, 0, NULL, 0);
    }
    uint64_t NSRunLoop = r_class("NSRunLoop");
    uint64_t loop = r_is_objc_ptr(NSRunLoop) && r_responds(NSRunLoop, "mainRunLoop")
        ? r_msg2_main(NSRunLoop, "mainRunLoop", 0, 0, 0, 0)
        : 0;
    uint64_t commonMode = r_nsstr_retained("kCFRunLoopCommonModes");
    if (r_is_objc_ptr(loop) &&
        r_is_objc_ptr(commonMode) &&
        r_responds(loop, "addTimer:forMode:")) {
        r_msg2_main(loop, "addTimer:forMode:", timer, commonMode, 0, 0);
    }
    if (r_is_objc_ptr(commonMode))
        r_msg2_main(commonMode, "release", 0, 0, 0, 0);

    if (timerKey) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     scene, timerKey, timer, 1 /* RETAIN_NONATOMIC */,
                     0, 0, 0, 0);
    }
    printf("[STAGE] keepalive: foreground timer=0x%llx updater=0x%llx bid=%s\n",
           timer, updater, bid ? bid : "?");
    return timer;
}

static bool stagestrip_set_scene_foreground_via_updater(uint64_t scene,
                                                        int index,
                                                        const char *bid)
{
    if (!kStripUseSceneSettingsUpdater || !r_is_objc_ptr(scene)) return false;

    uint64_t settingsBefore = r_responds(scene, "settings")
        ? r_msg2_main(scene, "settings", 0, 0, 0, 0) : 0;
    uint64_t fgBefore = r_is_objc_ptr(settingsBefore) &&
        r_responds(settingsBefore, "isForeground")
        ? r_msg2_main(settingsBefore, "isForeground", 0, 0, 0, 0)
        : 0;
    uint64_t activeBefore = r_responds(scene, "isActive")
        ? r_msg2_main(scene, "isActive", 0, 0, 0, 0)
        : 0;

    uint64_t updater = stagestrip_scene_settings_updater_for_scene(scene, index, bid);
    if (!r_is_objc_ptr(updater)) return false;

    if (r_responds(updater, "setEnhancedWindowingModeEnabled:"))
        r_msg2_main(updater, "setEnhancedWindowingModeEnabled:", 1, 0, 0, 0);
    if (r_responds(updater, "setLevel:")) {
        double level = 1.0;
        r_msg2_main_raw(updater, "setLevel:",
                        &level, sizeof(level),
                        NULL, 0, NULL, 0, NULL, 0);
    }
    if (kStripActivateInactiveScenesViaUpdater &&
        (activeBefore & 0xff) == 0 &&
        r_responds(updater, "setActive:withTransitionContext:")) {
        r_msg2_main(updater, "setActive:withTransitionContext:", 1, 0, 0, 0);
    }
    if (r_responds(updater, "setForeground:"))
        r_msg2_main(updater, "setForeground:", 1, 0, 0, 0);
    uint64_t keepaliveTimer = stagestrip_schedule_foreground_keepalive(scene, updater, bid);

    uint64_t settingsAfter = r_responds(scene, "settings")
        ? r_msg2_main(scene, "settings", 0, 0, 0, 0) : 0;
    uint64_t fgAfter = r_is_objc_ptr(settingsAfter) &&
        r_responds(settingsAfter, "isForeground")
        ? r_msg2_main(settingsAfter, "isForeground", 0, 0, 0, 0)
        : 0;
    uint64_t activeAfter = r_responds(scene, "isActive")
        ? r_msg2_main(scene, "isActive", 0, 0, 0, 0)
        : 0;

    printf("[STAGE] updater: bid=%s scene=0x%llx updater=0x%llx active=%llu->%llu fg=%llu->%llu keepalive=0x%llx\n",
           bid ? bid : "?", scene, updater,
           activeBefore & 0xff, activeAfter & 0xff,
           fgBefore & 0xff, fgAfter & 0xff, keepaliveTimer);
    return (fgAfter & 0xff) != 0;
}

static void stagestrip_force_external_foreground_scene(uint64_t scene,
                                                       uint64_t handle,
                                                       const char *bid)
{
    if (!r_is_objc_ptr(scene) || !r_is_objc_ptr(handle)) return;

    uint64_t mgr = stagestrip_main_scene_manager();
    if (!r_is_objc_ptr(mgr)) return;

    printf("[STAGE] foreground: begin bid=%s scene=0x%llx handle=0x%llx mgr=0x%llx\n",
           bid ? bid : "?", scene, handle, mgr);

    uint64_t externalSet = r_ivar_value(mgr, "_externalApplicationSceneHandles");
    uint64_t externalForegroundSet = r_ivar_value(mgr, "_externalForegroundApplicationSceneHandles");
    uint64_t reportedSet = r_ivar_value(mgr, "_reportedExternalForegroundApplicationSceneHandles");
    uint64_t assertedBackgroundScenes = r_ivar_value(mgr, "_assertedBackgroundScenes");
    printf("[STAGE] foreground: sets ext=0x%llx fg=0x%llx reported=0x%llx assertedBg=0x%llx\n",
           externalSet, externalForegroundSet, reportedSet, assertedBackgroundScenes);

    if (r_is_objc_ptr(assertedBackgroundScenes) &&
        r_responds(assertedBackgroundScenes, "removeObject:")) {
        printf("[STAGE] foreground: remove asserted-background scene\n");
        r_msg2_main(assertedBackgroundScenes, "removeObject:", scene, 0, 0, 0);
    }
    if (kStripMutateSceneSettingsLive)
        stagestrip_set_scene_settings_live(scene, bid);

    if (r_is_objc_ptr(externalSet) && r_responds(externalSet, "addObject:")) {
        printf("[STAGE] foreground: add external handle\n");
        r_msg2_main(externalSet, "addObject:", handle, 0, 0, 0);
    }
    if (r_is_objc_ptr(externalForegroundSet) && r_responds(externalForegroundSet, "addObject:")) {
        printf("[STAGE] foreground: add external foreground handle\n");
        r_msg2_main(externalForegroundSet, "addObject:", handle, 0, 0, 0);
    }
    if (kStripDirectReportedForeground &&
        r_is_objc_ptr(reportedSet) && r_responds(reportedSet, "addObject:")) {
        printf("[STAGE] foreground: add reported foreground handle\n");
        r_msg2_main(reportedSet, "addObject:", handle, 0, 0, 0);
    }
    if (kStripNotifyReportedForeground &&
        r_responds(mgr, "_addReportedForegroundExternalApplicationSceneHandle:")) {
        printf("[STAGE] foreground: notify reported foreground\n");
        r_msg2_main(mgr, "_addReportedForegroundExternalApplicationSceneHandle:", handle, 0, 0, 0);
    }

    uint64_t settings = 0;
    if (kStripRunSceneManagerStateUpdate) {
        if (r_responds(scene, "clientSettings"))
            settings = r_msg2_main(scene, "clientSettings", 0, 0, 0, 0);
        if (!r_is_objc_ptr(settings) && r_responds(scene, "settings"))
            settings = r_msg2_main(scene, "settings", 0, 0, 0, 0);
    }
    if (kStripRunSceneManagerStateUpdate && r_is_objc_ptr(settings) &&
        r_responds(mgr, "_updateStateForScene:withSettings:")) {
        printf("[STAGE] foreground: update manager state\n");
        r_msg2_main(mgr, "_updateStateForScene:withSettings:", scene, settings, 0, 0);
    }

    uint64_t timerKey = r_sel("cyanideStageStripExternalForegroundTimer");
    uint64_t timer = 0;
    if (kStripReportedForegroundTimer && timerKey &&
        r_responds(mgr, "_addReportedForegroundExternalApplicationSceneHandle:")) {
        uint64_t oldTimer = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                         scene, timerKey, 0, 0, 0, 0, 0, 0);
        bool needTimer = true;
        if (r_is_objc_ptr(oldTimer) && r_responds(oldTimer, "isValid"))
            needTimer = (r_msg2_main(oldTimer, "isValid", 0, 0, 0, 0) & 0xff) == 0;
        if (needTimer) {
            uint64_t sel = r_sel("_addReportedForegroundExternalApplicationSceneHandle:");
            uint64_t sig = sel ? r_msg2_main(mgr, "methodSignatureForSelector:", sel, 0, 0, 0) : 0;
            uint64_t NSInvocation = r_class("NSInvocation");
            uint64_t inv = (r_is_objc_ptr(NSInvocation) && r_is_objc_ptr(sig))
                ? r_msg2_main(NSInvocation, "invocationWithMethodSignature:", sig, 0, 0, 0)
                : 0;
            if (r_is_objc_ptr(inv)) {
                r_msg2_main(inv, "setTarget:", mgr, 0, 0, 0);
                r_msg2_main(inv, "setSelector:", sel, 0, 0, 0);
                uint64_t argBuf = r_dlsym_call(R_TIMEOUT, "malloc", 8, 0, 0, 0, 0, 0, 0, 0);
                if (argBuf) {
                    remote_write64(argBuf, handle);
                    r_msg2_main(inv, "setArgument:atIndex:", argBuf, 2, 0, 0);
                    r_free(argBuf);
                }
                r_msg2_main(inv, "retainArguments", 0, 0, 0, 0);
            }

            uint64_t NSTimer = r_class("NSTimer");
            if (r_is_objc_ptr(NSTimer) && r_is_objc_ptr(inv) &&
                r_responds(NSTimer, "scheduledTimerWithTimeInterval:invocation:repeats:")) {
                double interval = 1.0;
                uint8_t repeats = 1;
                timer = r_msg2_main_raw(NSTimer,
                    "scheduledTimerWithTimeInterval:invocation:repeats:",
                    &interval, sizeof(interval),
                    &inv,      sizeof(inv),
                    &repeats,  sizeof(repeats),
                    NULL, 0);
                if (r_is_objc_ptr(timer)) {
                    r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                                 scene, timerKey, timer, 1 /* RETAIN_NONATOMIC */,
                                 0, 0, 0, 0);
                }
            }
        } else {
            timer = oldTimer;
        }
    }

    uint64_t isInExternalForeground = r_is_objc_ptr(externalForegroundSet)
        ? r_msg2_main(externalForegroundSet, "containsObject:", handle, 0, 0, 0) : 0;
    uint64_t isReported = r_is_objc_ptr(reportedSet)
        ? r_msg2_main(reportedSet, "containsObject:", handle, 0, 0, 0) : 0;
    printf("[STAGE] foreground: bid=%s handle=0x%llx extSet=0x%llx fgSet=0x%llx reported=0x%llx inFG=%llu reportedHas=%llu timer=0x%llx\n",
           bid ? bid : "?", handle, externalSet, externalForegroundSet, reportedSet,
           isInExternalForeground & 0xff, isReported & 0xff, timer);
}

static void stagestrip_update_foreground_attribution(StripScenePick *picks, int count)
{
    if (!kStripUpdateForegroundAttribution || !picks || count <= 0) return;

    uint64_t mgr = stagestrip_main_scene_manager();
    uint64_t NSMutableSet = r_class("NSMutableSet");
    uint64_t set = r_is_objc_ptr(NSMutableSet)
        ? r_msg2_main(NSMutableSet, "setWithCapacity:", (uint64_t)count, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(set)) return;

    int added = 0;
    for (int i = 0; i < count; i++) {
        if (!r_is_objc_ptr(picks[i].handle)) continue;
        r_msg2_main(set, "addObject:", picks[i].handle, 0, 0, 0);
        added++;
        if (r_is_objc_ptr(mgr) && r_responds(picks[i].handle, "_setIdleTimerCoordinator:"))
            r_msg2_main(picks[i].handle, "_setIdleTimerCoordinator:", mgr, 0, 0, 0);
    }
    if (added <= 0) return;

    uint64_t Attribution = r_class("SBBackgroundActivityAttributionManager");
    uint64_t attribution = r_is_objc_ptr(Attribution) && r_responds(Attribution, "sharedInstance")
        ? r_msg2_main(Attribution, "sharedInstance", 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(attribution) &&
        r_responds(attribution, "updateForegroundApplicationSceneHandles:withOptions:completion:")) {
        printf("[STAGE] attribution: foreground handles=%d set=0x%llx mgr=0x%llx\n",
               added, set, mgr);
        r_msg2_main(attribution,
                    "updateForegroundApplicationSceneHandles:withOptions:completion:",
                    set, (uint64_t)-1, 0, 0);
    } else {
        printf("[STAGE] attribution: manager unavailable handles=%d set=0x%llx\n",
               added, set);
    }
}

static void stagestrip_prepare_handle_for_stage(uint64_t handle,
                                                int index,
                                                const char *bid)
{
    if (!r_is_objc_ptr(handle)) return;

    uint64_t oldRole = r_responds(handle, "layoutRole")
        ? r_msg2_main(handle, "layoutRole", 0, 0, 0, 0) : 0;
    uint64_t newRole = (index == 0) ? 1 : 2; // SBLayoutRolePrimary / SBLayoutRoleSide
    if (r_responds(handle, "setLayoutRole:"))
        r_msg2_main(handle, "setLayoutRole:", newRole, 0, 0, 0);
    if (r_responds(handle, "setWantsEnhancedWindowingEnabled:"))
        r_msg2_main(handle, "setWantsEnhancedWindowingEnabled:", 1, 0, 0, 0);
    if (r_responds(handle, "setOccluded:"))
        r_msg2_main(handle, "setOccluded:", 0, 0, 0, 0);
    if (r_responds(handle, "setSceneFullyOccluded:"))
        r_msg2_main(handle, "setSceneFullyOccluded:", 0, 0, 0, 0);

    uint64_t assertionKey = r_sel("cyanideStageStripRelevancyAssertions");
    uint64_t assertions = assertionKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                       handle, assertionKey, 0, 0, 0, 0, 0, 0)
        : 0;
    bool acquired = false;
    if (!r_is_objc_ptr(assertions) && assertionKey) {
        uint64_t NSMutableArray = r_class("NSMutableArray");
        assertions = r_is_objc_ptr(NSMutableArray)
            ? r_msg2_main(NSMutableArray, "arrayWithCapacity:", 2, 0, 0, 0)
            : 0;

        uint64_t reason = r_nsstr_retained("Cyanide StageStrip live window");
        if (r_is_objc_ptr(assertions) && r_is_objc_ptr(reason)) {
            if (r_responds(handle, "acquireSceneActivityModeAssertionWithReason:activityMode:")) {
                uint64_t activity = r_msg2_main(handle,
                    "acquireSceneActivityModeAssertionWithReason:activityMode:",
                    reason, 10, 0, 0);
                if (r_is_objc_ptr(activity)) {
                    r_msg2_main(assertions, "addObject:", activity, 0, 0, 0);
                    acquired = true;
                }
            }
            if (r_responds(handle, "acquireSceneJetsamModeAssertionWithReason:jetsamMode:")) {
                uint64_t jetsam = r_msg2_main(handle,
                    "acquireSceneJetsamModeAssertionWithReason:jetsamMode:",
                    reason, 10, 0, 0);
                if (r_is_objc_ptr(jetsam)) {
                    r_msg2_main(assertions, "addObject:", jetsam, 0, 0, 0);
                    acquired = true;
                }
            }
        }
        if (r_is_objc_ptr(reason))
            r_msg2_main(reason, "release", 0, 0, 0, 0);
        if (r_is_objc_ptr(assertions)) {
            r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                         handle, assertionKey, assertions, 1 /* RETAIN_NONATOMIC */,
                         0, 0, 0, 0);
        }
    }

    uint64_t wantsEnhanced = r_responds(handle, "wantsEnhancedWindowingEnabled")
        ? r_msg2_main(handle, "wantsEnhancedWindowingEnabled", 0, 0, 0, 0) : 0;
    uint64_t activityMode = r_responds(handle, "activityMode")
        ? r_msg2_main(handle, "activityMode", 0, 0, 0, 0) : 0;
    uint64_t jetsamPriority = r_responds(handle, "jetsamPriority")
        ? r_msg2_main(handle, "jetsamPriority", 0, 0, 0, 0) : 0;
    printf("[STAGE] handle: bid=%s handle=0x%llx role=%llu->%llu enhanced=%llu assertions=0x%llx acquired=%d activity=%lld jetsamPriority=%llu\n",
           bid ? bid : "?", handle, oldRole, newRole, wantsEnhanced & 0xff,
           assertions, acquired ? 1 : 0, (int64_t)(int8_t)(activityMode & 0xff),
           jetsamPriority);
}

static void stagestrip_invalidate_live_rendering_for_scene(uint64_t scene)
{
    if (!r_is_objc_ptr(scene)) return;

    uint64_t foregroundTimerKey = r_sel("cyanideStageStripForegroundKeepaliveTimer");
    if (foregroundTimerKey) {
        uint64_t timer = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                      scene, foregroundTimerKey, 0, 0, 0, 0, 0, 0);
        if (r_is_objc_ptr(timer) && r_responds(timer, "invalidate"))
            r_msg2_main(timer, "invalidate", 0, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     scene, foregroundTimerKey, 0, 1, 0, 0, 0, 0);
    }

    uint64_t externalTimerKey = r_sel("cyanideStageStripExternalForegroundTimer");
    if (externalTimerKey) {
        uint64_t timer = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                      scene, externalTimerKey, 0, 0, 0, 0, 0, 0);
        if (r_is_objc_ptr(timer) && r_responds(timer, "invalidate"))
            r_msg2_main(timer, "invalidate", 0, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     scene, externalTimerKey, 0, 1, 0, 0, 0, 0);
    }

    uint64_t timerKey = r_sel("cyanideStageStripLiveRenderingTimer");
    if (timerKey) {
        uint64_t timer = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                      scene, timerKey, 0, 0, 0, 0, 0, 0);
        if (r_is_objc_ptr(timer) && r_responds(timer, "invalidate"))
            r_msg2_main(timer, "invalidate", 0, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     scene, timerKey, 0, 1, 0, 0, 0, 0);
    }

    uint64_t proxyKey = r_sel("cyanideStageStripLiveRenderingProxy");
    if (proxyKey) {
        uint64_t proxy = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                      scene, proxyKey, 0, 0, 0, 0, 0, 0);
        if (r_is_objc_ptr(proxy) && r_responds(proxy, "invalidate"))
            r_msg2_main(proxy, "invalidate", 0, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     scene, proxyKey, 0, 1, 0, 0, 0, 0);
    }

    uint64_t blsKey = r_sel("cyanideStageStripBLSLiveRenderingAssertion");
    if (blsKey) {
        uint64_t bls = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                    scene, blsKey, 0, 0, 0, 0, 0, 0);
        if (r_is_objc_ptr(bls) && r_responds(bls, "invalidate"))
            r_msg2_main(bls, "invalidate", 0, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     scene, blsKey, 0, 1, 0, 0, 0, 0);
    }
}

static void stagestrip_clear_live_rendering_state(void)
{
    for (int i = 0; i < gStripLiveSceneCount; i++)
        stagestrip_invalidate_live_rendering_for_scene(gStripLiveScenes[i]);
    if (r_is_objc_ptr(gStripLiveScene))
        stagestrip_invalidate_live_rendering_for_scene(gStripLiveScene);
    memset(gStripLiveScenes, 0, sizeof(gStripLiveScenes));
    gStripLiveSceneCount = 0;
    gStripLiveScene = 0;
}

static bool stagestrip_bid_short_name(const char *bid, char *out, size_t outLen)
{
    if (!out || outLen == 0) return false;
    out[0] = '\0';
    if (!bid || !*bid) return false;

    const char *p = strrchr(bid, '.');
    p = p ? p + 1 : bid;
    if (!*p) p = bid;
    snprintf(out, outLen, "%s", p);
    return true;
}

static bool stagestrip_scene_id_bid_hint(const char *sceneID, char *out, size_t outLen)
{
    if (!out || outLen == 0) return false;
    out[0] = '\0';
    if (!sceneID || strncmp(sceneID, "sceneID:", 8) != 0) return false;

    const char *bidStart = sceneID + 8;
    const char *dash = strchr(bidStart, '-');
    if (!dash) return false;

    size_t bidLen = (size_t)(dash - bidStart);
    if (bidLen == 0 || bidLen >= outLen) return false;
    memcpy(out, bidStart, bidLen);
    out[bidLen] = '\0';
    return true;
}

static bool stagestrip_find_live_pick_for_bid(const char *wantedBid, StripScenePick *out)
{
    if (!wantedBid || !*wantedBid || !out) return false;
    memset(out, 0, sizeof(*out));

    uint64_t mgr = stagestrip_main_scene_manager();
    if (!r_is_objc_ptr(mgr) || !r_responds(mgr, "allScenes") ||
        !r_responds(mgr, "existingSceneHandleForScene:")) {
        return false;
    }
    uint64_t scenesSet = r_msg2_main(mgr, "allScenes", 0, 0, 0, 0);
    uint64_t arr = r_is_objc_ptr(scenesSet)
        ? r_msg2_main(scenesSet, "allObjects", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(arr)) return false;

    uint64_t cnt = r_msg2_main(arr, "count", 0, 0, 0, 0);
    if (cnt == 0 || cnt > 96) return false;

    for (uint64_t i = 0; i < cnt; i++) {
        uint64_t scene = r_msg2_main(arr, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(scene) || !r_responds(scene, "identifier")) continue;

        uint64_t idObj = r_msg2_main(scene, "identifier", 0, 0, 0, 0);
        uint64_t cstr = r_is_objc_ptr(idObj)
            ? r_msg2_main(idObj, "UTF8String", 0, 0, 0, 0) : 0;
        if (!cstr) continue;

        char idBuf[160] = {0};
        if (!stagestrip_read_remote_cstr(cstr, idBuf, sizeof(idBuf))) continue;
        if (strncmp(idBuf, "sceneID:", 8) != 0) continue;

        uint64_t handle = r_msg2_main(mgr, "existingSceneHandleForScene:", scene, 0, 0, 0);
        if (!r_is_objc_ptr(handle)) continue;

        char bidBuf[128] = {0};
        stagestrip_handle_bundle_id(handle, bidBuf, sizeof(bidBuf));
        if (!bidBuf[0])
            stagestrip_scene_id_bid_hint(idBuf, bidBuf, sizeof(bidBuf));
        if (strcmp(bidBuf, wantedBid) != 0) continue;

        out->handle = handle;
        out->scene = scene;
        strncpy(out->bid, bidBuf, sizeof(out->bid) - 1);
        printf("[STAGE] picker: resolved bid=%s scene=0x%llx handle=0x%llx\n",
               bidBuf, scene, handle);
        return true;
    }

    return false;
}

static bool stagestrip_get_pick_for_bid(const char *bid, StripScenePick *out)
{
    if (stagestrip_find_live_pick_for_bid(bid, out)) return true;

    printf("[STAGE] picker: launch selected bid=%s\n", bid ? bid : "(null)");
    stagestrip_launch_suspended(bid);
    for (int attempt = 0; attempt < 6; attempt++) {
        usleep(120000);
        if (stagestrip_find_live_pick_for_bid(bid, out)) return true;
    }
    printf("[STAGE] picker: failed to resolve selected bid=%s\n", bid ? bid : "(null)");
    return false;
}

// Dump every scene the main display scene manager knows about. Helps us
// see whether SpringBoard's _persistentMap / _transientMap actually holds
// live FBScene entries for backgrounded apps on iOS 26, or whether scenes
// get reaped as soon as the app process dies (in which case we'd have to
// LAUNCH the target app before we can host its view).
static void stagestrip_dump_all_scenes(void)
{
    uint64_t mgr = stagestrip_main_scene_manager();
    if (!r_is_objc_ptr(mgr)) return;
    if (!r_responds(mgr, "allScenes")) {
        printf("[STAGE] dump: -allScenes missing\n");
        return;
    }
    uint64_t scenesSet = r_msg2_main(mgr, "allScenes", 0, 0, 0, 0);
    if (!r_is_objc_ptr(scenesSet)) {
        printf("[STAGE] dump: allScenes nil\n");
        return;
    }
    uint64_t arr = r_msg2_main(scenesSet, "allObjects", 0, 0, 0, 0);
    if (!r_is_objc_ptr(arr)) return;
    uint64_t cnt = r_msg2_main(arr, "count", 0, 0, 0, 0);
    printf("[STAGE] dump: allScenes count=%llu\n", cnt);
    if (cnt == 0 || cnt > 64) return;
    for (uint64_t i = 0; i < cnt; i++) {
        uint64_t s = r_msg2_main(arr, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(s)) continue;

        char idBuf[128] = {0};
        if (r_responds(s, "identifier")) {
            uint64_t idObj = r_msg2_main(s, "identifier", 0, 0, 0, 0);
            if (r_is_objc_ptr(idObj)) {
                uint64_t cstr = r_msg2_main(idObj, "UTF8String", 0, 0, 0, 0);
                if (cstr) stagestrip_read_remote_cstr(cstr, idBuf, sizeof(idBuf));
            }
        }
        char roleBuf[64] = {0};
        if (r_responds(s, "_clientProcess")) {
            uint64_t proc = r_msg2_main(s, "_clientProcess", 0, 0, 0, 0);
            if (r_is_objc_ptr(proc) && r_responds(proc, "bundleIdentifier")) {
                uint64_t bidObj = r_msg2_main(proc, "bundleIdentifier", 0, 0, 0, 0);
                if (r_is_objc_ptr(bidObj)) {
                    uint64_t pcstr = r_msg2_main(bidObj, "UTF8String", 0, 0, 0, 0);
                    if (pcstr) stagestrip_read_remote_cstr(pcstr, roleBuf, sizeof(roleBuf));
                }
            }
        }
        printf("[STAGE] dump[%llu]: scene=0x%llx id=%s proc.bid=%s\n",
               i, s, idBuf[0] ? idBuf : "?", roleBuf[0] ? roleBuf : "?");
    }
}

static int stagestrip_collect_recent_bids(char out[][128], int maxOut)
{
    if (!out || maxOut <= 0) return 0;
    for (int i = 0; i < maxOut; i++) out[i][0] = '\0';

    uint64_t cls = r_class("SBMainSwitcherControllerCoordinator");
    uint64_t coord = r_is_objc_ptr(cls)
        ? r_msg2_main(cls, "sharedInstance", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(coord) || !r_responds(coord, "recentAppLayouts")) return 0;

    uint64_t layoutsArr = r_msg2_main(coord, "recentAppLayouts", 0, 0, 0, 0);
    if (!r_is_objc_ptr(layoutsArr)) return 0;
    uint64_t layoutsCount = r_msg2_main(layoutsArr, "count", 0, 0, 0, 0);
    if (layoutsCount == 0 || layoutsCount > 128) return 0;

    int written = 0;
    for (uint64_t i = 0; i < layoutsCount && written < maxOut; i++) {
        uint64_t layout = r_msg2_main(layoutsArr, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(layout) || !r_responds(layout, "allItems")) continue;

        uint64_t items = r_msg2_main(layout, "allItems", 0, 0, 0, 0);
        if (!r_is_objc_ptr(items)) continue;
        uint64_t itemCount = r_msg2_main(items, "count", 0, 0, 0, 0);
        if (itemCount == 0 || itemCount > 32) continue;

        for (uint64_t j = 0; j < itemCount && written < maxOut; j++) {
            uint64_t item = r_msg2_main(items, "objectAtIndex:", j, 0, 0, 0);
            uint64_t bidObj = r_is_objc_ptr(item) && r_responds(item, "bundleIdentifier")
                ? r_msg2_main(item, "bundleIdentifier", 0, 0, 0, 0) : 0;
            uint64_t cstr = r_is_objc_ptr(bidObj)
                ? r_msg2_main(bidObj, "UTF8String", 0, 0, 0, 0) : 0;
            if (!cstr) continue;

            char bidBuf[128] = {0};
            if (!stagestrip_read_remote_cstr(cstr, bidBuf, sizeof(bidBuf))) continue;
            if (stagestrip_bid_is_self(bidBuf) || !stagestrip_bid_is_user_app(bidBuf))
                continue;

            bool duplicate = false;
            for (int k = 0; k < written; k++) {
                if (strcmp(out[k], bidBuf) == 0) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;

            strncpy(out[written], bidBuf, 127);
            out[written][127] = '\0';
            printf("[STAGE] recents-bid[%d]: %s\n", written, out[written]);
            written++;
        }
    }
    return written;
}

// Read a scene handle's app bundle id into a local buffer (best-effort).
static void stagestrip_handle_bundle_id(uint64_t handle, char *out, size_t outLen)
{
    if (!out || outLen == 0) return;
    out[0] = '\0';
    if (!r_is_objc_ptr(handle) || !r_responds(handle, "application")) return;
    uint64_t sbApp = r_msg2_main(handle, "application", 0, 0, 0, 0);
    if (!r_is_objc_ptr(sbApp)) return;
    uint64_t bidObj = r_msg2_main(sbApp, "bundleIdentifier", 0, 0, 0, 0);
    if (!r_is_objc_ptr(bidObj)) return;
    uint64_t cstr = r_msg2_main(bidObj, "UTF8String", 0, 0, 0, 0);
    if (!cstr) return;
    stagestrip_read_remote_cstr(cstr, out, outLen);
}

static uint64_t stagestrip_make_scene_layer_host_view(uint64_t scene,
                                                      const char *bid,
                                                      double w,
                                                      double h)
{
    if (!r_is_objc_ptr(scene)) return 0;

    // Cache: a previous apply for this scene already built the host container.
    // Reuse it — the layer-host view persists the live render unless its scene
    // is invalidated.
    uint64_t hostKey = r_sel("cyanideStageStripSceneLayerHost");
    uint64_t cachedHost = hostKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                       scene, hostKey, 0, 0, 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(cachedHost)) {
        r_msg2_main(cachedHost, "removeFromSuperview", 0, 0, 0, 0);
        stagestrip_send_rect(cachedHost, "setFrame:", 0.0, 0.0, w, h);
        r_msg2_main(cachedHost, "setClipsToBounds:", 1, 0, 0, 0);
        r_msg2_main(cachedHost, "setUserInteractionEnabled:", 1, 0, 0, 0);
        printf("[STAGE] scene-host: reuse cached host=0x%llx scene=0x%llx bid=%s\n",
               cachedHost, scene, bid ? bid : "?");
        return cachedHost;
    }

    uint64_t cls = r_class("_UISceneLayerHostContainerView");
    if (!r_is_objc_ptr(cls)) {
        printf("[STAGE] scene-host: _UISceneLayerHostContainerView missing for %s\n",
               bid ? bid : "?");
        return 0;
    }

    uint64_t host = 0;
    uint64_t desc = r_nsstr_retained("Cyanide StageStrip scene host");

    uint64_t alloc = r_msg2_main(cls, "alloc", 0, 0, 0, 0);
    if (r_is_objc_ptr(alloc) &&
        r_responds(alloc, "initWithScene:debugDescription:") &&
        r_is_objc_ptr(desc)) {
        host = r_msg2_main(alloc, "initWithScene:debugDescription:",
                           scene, desc, 0, 0);
        if (r_is_objc_ptr(host))
            printf("[STAGE] scene-host: initWithScene:debugDescription: host=0x%llx bid=%s\n",
                   host, bid ? bid : "?");
    }

    if (!r_is_objc_ptr(host)) {
        alloc = r_msg2_main(cls, "alloc", 0, 0, 0, 0);
        if (r_is_objc_ptr(alloc) && r_responds(alloc, "initWithScene:")) {
            host = r_msg2_main(alloc, "initWithScene:", scene, 0, 0, 0);
            if (r_is_objc_ptr(host))
                printf("[STAGE] scene-host: initWithScene: host=0x%llx bid=%s\n",
                       host, bid ? bid : "?");
        }
    }

    if (!r_is_objc_ptr(host)) {
        uint64_t layer = 0;
        if (r_responds(scene, "layerManager")) {
            uint64_t layerManager = r_msg2_main(scene, "layerManager", 0, 0, 0, 0);
            uint64_t layers = r_is_objc_ptr(layerManager) && r_responds(layerManager, "layers")
                ? r_msg2_main(layerManager, "layers", 0, 0, 0, 0)
                : 0;
            if (r_is_objc_ptr(layers) && r_responds(layers, "firstObject"))
                layer = r_msg2_main(layers, "firstObject", 0, 0, 0, 0);
        }
        if (!r_is_objc_ptr(layer) && r_responds(scene, "clientLayer"))
            layer = r_msg2_main(scene, "clientLayer", 0, 0, 0, 0);
        if (!r_is_objc_ptr(layer) && r_responds(scene, "layer"))
            layer = r_msg2_main(scene, "layer", 0, 0, 0, 0);

        alloc = r_msg2_main(cls, "alloc", 0, 0, 0, 0);
        if (r_is_objc_ptr(layer) && r_is_objc_ptr(alloc) &&
            r_responds(alloc, "initWithSceneLayer:")) {
            host = r_msg2_main(alloc, "initWithSceneLayer:", layer, 0, 0, 0);
            if (r_is_objc_ptr(host))
                printf("[STAGE] scene-host: initWithSceneLayer: host=0x%llx layer=0x%llx bid=%s\n",
                       host, layer, bid ? bid : "?");
        }
    }

    if (r_is_objc_ptr(desc))
        r_msg2_main(desc, "release", 0, 0, 0, 0);

    if (!r_is_objc_ptr(host)) {
        printf("[STAGE] scene-host: init failed scene=0x%llx bid=%s\n",
               scene, bid ? bid : "?");
        return 0;
    }

    // iOS 26 fix: -initWithScene:debugDescription: leaves _presentationContext
    // nil, which makes -[_filteredLayersToPresent] drop every layer (the type
    // bitmask check against presentationContext.presentedLayerTypes fails for
    // a nil context). Result: transparent host. UIKit normally sets the
    // context via -[_setDataSource:] -> -[_refreshDataSource] when the host
    // is owned by a UIScenePresenterOwner; we have no presenter, so install a
    // default UIScenePresentationContext directly. The default sets
    // presentedLayerTypes=26 which covers app+system layers — exactly what we
    // need to mirror StageDuo's iOS<26 working behavior.
    if (r_responds(host, "_setPresentationContext:")) {
        uint64_t ctxCls = r_class("UIScenePresentationContext");
        uint64_t ctxAlloc = r_is_objc_ptr(ctxCls)
            ? r_msg2_main(ctxCls, "alloc", 0, 0, 0, 0) : 0;
        uint64_t ctx = 0;
        if (r_is_objc_ptr(ctxAlloc) && r_responds(ctxAlloc, "_initWithDefaultValues")) {
            ctx = r_msg2_main(ctxAlloc, "_initWithDefaultValues", 0, 0, 0, 0);
        }
        if (r_is_objc_ptr(ctx)) {
            r_msg2_main(host, "_setPresentationContext:", ctx, 0, 0, 0);
            printf("[STAGE] scene-host: presentationContext=0x%llx installed scene=0x%llx\n",
                   ctx, scene);
        } else {
            printf("[STAGE] scene-host: failed to alloc presentationContext for scene=0x%llx\n",
                   scene);
        }
    } else {
        printf("[STAGE] scene-host: host=0x%llx lacks _setPresentationContext: (older UIKit?)\n",
               host);
    }

    uint64_t sceneKey = r_sel("cyanideStageStripHostedScene");
    if (sceneKey) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     host, sceneKey, scene, 1 /* RETAIN_NONATOMIC */,
                     0, 0, 0, 0);
    }
    // Cache the host on the scene so a future apply reuses it instead of
    // allocating another _UISceneLayerHostContainerView from scratch.
    if (hostKey) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     scene, hostKey, host, 1 /* RETAIN_NONATOMIC */,
                     0, 0, 0, 0);
    }
    stagestrip_send_rect(host, "setFrame:", 0.0, 0.0, w, h);
    r_msg2_main(host, "setClipsToBounds:", 1, 0, 0, 0);
    r_msg2_main(host, "setUserInteractionEnabled:", 1, 0, 0, 0);
    if (r_responds(host, "setAllowsHitTesting:"))
        r_msg2_main(host, "setAllowsHitTesting:", 1, 0, 0, 0);
    if (r_responds(host, "setPassesTouchesThrough:"))
        r_msg2_main(host, "setPassesTouchesThrough:", 0, 0, 0, 0);
    stagestrip_enable_interaction_tree(host, 4);
    return host;
}

static uint64_t stagestrip_make_medusa_scene_view(uint64_t handle,
                                                  int index,
                                                  double w,
                                                  double h)
{
    if (!r_is_objc_ptr(handle)) return 0;

    // VC cache: if we already created a Medusa VC for this handle on a prior
    // apply, reuse it. Skips ~80 remote calls per repeated app.
    uint64_t vcKey = r_sel("cyanideStageStripMedusaViewController");
    uint64_t cachedVC = vcKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                       handle, vcKey, 0, 0, 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(cachedVC)) {
        uint64_t cachedView = r_responds(cachedVC, "view")
            ? r_msg2_main(cachedVC, "view", 0, 0, 0, 0) : 0;
        if (r_is_objc_ptr(cachedView)) {
            // Detach from any previous parent so the new row can take it.
            r_msg2_main(cachedView, "removeFromSuperview", 0, 0, 0, 0);
            if (r_responds(cachedVC, "setContentReferenceSize:withContentOrientation:andContainerOrientation:")) {
                struct { double w; double h; } refSize = { w, h };
                int64_t orient = 1;
                r_msg2_main_raw(cachedVC,
                    "setContentReferenceSize:withContentOrientation:andContainerOrientation:",
                    &refSize, sizeof(refSize),
                    &orient,  sizeof(orient),
                    &orient,  sizeof(orient),
                    NULL, 0);
            }
            stagestrip_send_rect(cachedView, "setFrame:", 0.0, 0.0, w, h);
            r_msg2_main(cachedView, "setClipsToBounds:", 1, 0, 0, 0);
            r_msg2_main(cachedView, "setUserInteractionEnabled:", 1, 0, 0, 0);
            printf("[STAGE] medusa[%d]: reuse cached vc=0x%llx view=0x%llx size=%.0fx%.0f\n",
                   index, cachedVC, cachedView, w, h);
            return cachedView;
        }
        printf("[STAGE] medusa[%d]: cached vc=0x%llx had nil view, rebuilding\n",
               index, cachedVC);
    }

    uint64_t cls = r_class("SBMedusaDecoratedDeviceApplicationSceneViewController");
    if (!r_is_objc_ptr(cls)) {
        printf("[STAGE] medusa: class missing\n");
        return 0;
    }

    uint64_t alloc = r_msg2_main(cls, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(alloc) ||
        !r_responds(alloc, "initWithDeviceApplicationSceneHandle:layoutRole:")) {
        printf("[STAGE] medusa: init selector missing alloc=0x%llx\n", alloc);
        return 0;
    }

    uint64_t role = (index == 0) ? 1 : 2; // SBLayoutRolePrimary / SBLayoutRoleSide
    printf("[STAGE] medusa[%d]: begin handle=0x%llx role=%llu size=%.0fx%.0f\n",
           index, handle, role, w, h);
    uint64_t vc = r_msg2_main(alloc,
                              "initWithDeviceApplicationSceneHandle:layoutRole:",
                              handle, role, 0, 0);
    if (!r_is_objc_ptr(vc)) {
        printf("[STAGE] medusa: init returned nil handle=0x%llx role=%llu\n",
               handle, role);
        return 0;
    }
    printf("[STAGE] medusa[%d]: init vc=0x%llx\n", index, vc);

    if (r_responds(vc, "setSceneResizesHostedContext:"))
        r_msg2_main(vc, "setSceneResizesHostedContext:", 1, 0, 0, 0);
    if (r_responds(vc, "setSceneRendersAsynchronously:"))
        r_msg2_main(vc, "setSceneRendersAsynchronously:", 1, 0, 0, 0);
    if (r_responds(vc, "setSceneFullyOccluded:"))
        r_msg2_main(vc, "setSceneFullyOccluded:", 0, 0, 0, 0);
    if (r_responds(vc, "setDisplayMode:animationFactory:completion:"))
        r_msg2_main(vc, "setDisplayMode:animationFactory:completion:", 4, 0, 0, 0);
    if (r_responds(vc, "setDarkenViewAlpha:")) {
        double alpha = 0.0;
        r_msg2_main_raw(vc, "setDarkenViewAlpha:",
                        &alpha, sizeof(alpha),
                        NULL, 0, NULL, 0, NULL, 0);
    }

    if (r_responds(vc, "setContentReferenceSize:withContentOrientation:andContainerOrientation:")) {
        printf("[STAGE] medusa[%d]: set reference size\n", index);
        struct { double w; double h; } refSize = { w, h };
        int64_t contentOrient = 1;
        int64_t containerOrient = 1;
        r_msg2_main_raw(vc,
            "setContentReferenceSize:withContentOrientation:andContainerOrientation:",
            &refSize,         sizeof(refSize),
            &contentOrient,   sizeof(contentOrient),
            &containerOrient, sizeof(containerOrient),
            NULL, 0);
    }

    printf("[STAGE] medusa[%d]: request view\n", index);
    uint64_t view = r_msg2_main(vc, "view", 0, 0, 0, 0);
    if (!r_is_objc_ptr(view)) {
        printf("[STAGE] medusa: view nil vc=0x%llx\n", vc);
        return 0;
    }

    // Cache the VC on the *handle* so a future apply for the same app
    // reuses this VC instead of rebuilding it from scratch (~80 calls saved).
    if (vcKey) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     handle, vcKey, vc, 1 /* RETAIN_NONATOMIC */,
                     0, 0, 0, 0);
    }

    stagestrip_send_rect(view, "setFrame:", 0.0, 0.0, w, h);
    r_msg2_main(view, "setClipsToBounds:", 1, 0, 0, 0);
    r_msg2_main(view, "setUserInteractionEnabled:", 1, 0, 0, 0);
    stagestrip_enable_interaction_tree(view, 6);

    uint64_t sceneContent = r_responds(vc, "sceneContentView")
        ? r_msg2_main(vc, "sceneContentView", 0, 0, 0, 0)
        : 0;
    stagestrip_enable_interaction_tree(sceneContent, 4);
    if (r_responds(view, "setNeedsLayout")) r_msg2_main(view, "setNeedsLayout", 0, 0, 0, 0);
    if (r_responds(view, "layoutIfNeeded")) r_msg2_main(view, "layoutIfNeeded", 0, 0, 0, 0);

    uint64_t activeAppearance = r_responds(vc, "activeAppearance")
        ? r_msg2_main(vc, "activeAppearance", 0, 0, 0, 0)
        : 0;
    uint64_t resizes = r_responds(vc, "sceneResizesHostedContext")
        ? r_msg2_main(vc, "sceneResizesHostedContext", 0, 0, 0, 0)
        : 0;
    uint64_t occluded = r_responds(vc, "sceneFullyOccluded")
        ? r_msg2_main(vc, "sceneFullyOccluded", 0, 0, 0, 0)
        : 0;
    printf("[STAGE] medusa: vc=0x%llx view=0x%llx sceneContent=0x%llx role=%llu activeAppearance=%llu resizes=%llu occluded=%llu size=%.0fx%.0f\n",
           vc, view, sceneContent, role, activeAppearance, resizes & 0xff,
           occluded & 0xff, w, h);
    return view;
}

static uint64_t stagestrip_make_direct_scene_view(uint64_t handle, double w, double h)
{
    if (!r_is_objc_ptr(handle)) return 0;
    if (!r_responds(handle, "newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:")) {
        printf("[STAGE] direct: handle lacks newSceneViewWithReferenceSize:...\n");
        return 0;
    }

    struct { double w; double h; } refSize = { w, h };
    int64_t contentOrient = 1;
    int64_t containerOrient = 1;
    uint64_t hostRequester = 0;
    uint64_t view = r_msg2_main_raw(handle,
        "newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:",
        &refSize,         sizeof(refSize),
        &contentOrient,   sizeof(contentOrient),
        &containerOrient, sizeof(containerOrient),
        &hostRequester,   sizeof(hostRequester));
    if (!r_is_objc_ptr(view)) {
        printf("[STAGE] direct: newSceneView returned nil handle=0x%llx\n", handle);
        return 0;
    }

    stagestrip_send_rect(view, "setFrame:", 0.0, 0.0, w, h);
    r_msg2_main(view, "setClipsToBounds:", 1, 0, 0, 0);
    if (r_responds(view, "setActive:"))
        r_msg2_main(view, "setActive:", 1, 0, 0, 0);
    if (r_responds(view, "setVisible:"))
        r_msg2_main(view, "setVisible:", 1, 0, 0, 0);
    if (r_responds(view, "setOcclusionState:inSteadyState:"))
        r_msg2_main(view, "setOcclusionState:inSteadyState:", 0, 1, 0, 0);
    if (r_responds(view, "setDisplayMode:animationFactory:completion:"))
        r_msg2_main(view, "setDisplayMode:animationFactory:completion:", 4, 0, 0, 0);
    if (r_responds(view, "_refresh"))
        r_msg2_main(view, "_refresh", 0, 0, 0, 0);
    stagestrip_enable_interaction_tree(view, 6);

    printf("[STAGE] direct: sceneView=0x%llx size=%.0fx%.0f active=%d visible=%d\n",
           view, w, h,
           r_responds(view, "setActive:") ? 1 : 0,
           r_responds(view, "setVisible:") ? 1 : 0);
    return view;
}

// Probe a scene handle: alloc an SBApplicationSceneViewController, set its
// contentReferenceSize+orientations BEFORE -view fires viewDidLoad, then
// return -view.
//
// Why the size dance matters: -[SBSceneViewController viewDidLoad] calls
// -[SBApplicationSceneHandle newSceneViewWithReferenceSize:...] using its
// own _contentReferenceSize ivar (default 0,0). A zero referenceSize makes
// the scene render at 0x0 → black tile. Setting the size before -view
// access populates the ivars in time for viewDidLoad to forward them.
//
// NSInvocation-backed r_msg_main_raw handles HFA dispatch (CGSize -> d0/d1)
// natively via NSMethodSignature, so we can pass the 16-byte CGSize as a
// single raw slot.
static uint64_t stagestrip_handle_make_view(uint64_t handle, double w, double h)
{
    if (!r_is_objc_ptr(handle)) return 0;

    // VC cache: same trick as the Medusa path. -newSceneViewController is a
    // +1 retained factory call inside SpringBoard, so calling it repeatedly
    // is expensive AND leaks scene view controllers. Reuse via association
    // on the handle.
    uint64_t handleVCKey = r_sel("cyanideStageStripHandleViewController");
    uint64_t cachedHandleVC = handleVCKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                       handle, handleVCKey, 0, 0, 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(cachedHandleVC) && r_responds(cachedHandleVC, "view")) {
        uint64_t cachedView = r_msg2_main(cachedHandleVC, "view", 0, 0, 0, 0);
        if (r_is_objc_ptr(cachedView)) {
            r_msg2_main(cachedView, "removeFromSuperview", 0, 0, 0, 0);
            if (r_responds(cachedHandleVC,
                           "setContentReferenceSize:withContentOrientation:andContainerOrientation:")) {
                struct { double w; double h; } refSize = { w, h };
                int64_t orient = 1;
                r_msg2_main_raw(cachedHandleVC,
                    "setContentReferenceSize:withContentOrientation:andContainerOrientation:",
                    &refSize, sizeof(refSize),
                    &orient,  sizeof(orient),
                    &orient,  sizeof(orient),
                    NULL, 0);
            }
            printf("[STAGE]   reuse cached handle vc=0x%llx view=0x%llx size=%.0fx%.0f\n",
                   cachedHandleVC, cachedView, w, h);
            return cachedView;
        }
    }

    if (!r_responds(handle, "newSceneViewController")) {
        printf("[STAGE]   no -newSceneViewController on handle 0x%llx\n", handle);
        return 0;
    }
    uint64_t vc = r_msg2_main(handle, "newSceneViewController", 0, 0, 0, 0);
    if (!r_is_objc_ptr(vc)) {
        printf("[STAGE]   newSceneViewController returned nil for 0x%llx\n", handle);
        return 0;
    }
    if (handleVCKey) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     handle, handleVCKey, vc, 1 /* RETAIN_NONATOMIC */,
                     0, 0, 0, 0);
    }

    // Seed the VC's reference size so viewDidLoad builds a properly-sized
    // SBSceneView. UIInterfaceOrientationPortrait = 1.
    if (r_responds(vc, "setContentReferenceSize:withContentOrientation:andContainerOrientation:")) {
        struct { double w; double h; } refSize = { w, h };
        int64_t contentOrient = 1;
        int64_t containerOrient = 1;
        r_msg2_main_raw(vc,
            "setContentReferenceSize:withContentOrientation:andContainerOrientation:",
            &refSize,        sizeof(refSize),
            &contentOrient,  sizeof(contentOrient),
            &containerOrient, sizeof(containerOrient),
            NULL, 0);
        printf("[STAGE]   vc=0x%llx referenceSize=%.0fx%.0f\n", vc, w, h);
    } else {
        printf("[STAGE]   vc=0x%llx lacks setContentReferenceSize:withContentOrientation:andContainerOrientation:\n", vc);
    }

    if (!r_responds(vc, "view")) return 0;
    uint64_t view = r_msg2_main(vc, "view", 0, 0, 0, 0);
    if (r_is_objc_ptr(view)) {
        printf("[STAGE]   vc=0x%llx view=0x%llx\n", vc, view);
    } else {
        printf("[STAGE]   vc=0x%llx view=nil\n", vc);
        return 0;
    }

    // Belt-and-suspenders: viewDidLoad has fired by now, so the inner
    // SBSceneView exists. Poke -_updateReferenceSize:andOrientation: on it
    // directly in case the early -setContentReferenceSize:withContent... call
    // didn't bind (selector probe is permissive; if NSInvocation refused to
    // dispatch the CGSize, the inner scene view stays at 0x0).
    if (r_responds(vc, "_sceneView")) {
        uint64_t sceneView = r_msg2_main(vc, "_sceneView", 0, 0, 0, 0);
        if (r_is_objc_ptr(sceneView) &&
            r_responds(sceneView, "_updateReferenceSize:andOrientation:")) {
            struct { double w; double h; } refSize = { w, h };
            int64_t orient = 1;
            r_msg2_main_raw(sceneView, "_updateReferenceSize:andOrientation:",
                            &refSize, sizeof(refSize),
                            &orient,  sizeof(orient),
                            NULL, 0, NULL, 0);
            printf("[STAGE]   inner sceneView=0x%llx updated referenceSize=%.0fx%.0f\n",
                   sceneView, w, h);
        }
    }
    return view;
}

static void stagestrip_set_background_white(uint64_t view, double white, double alpha)
{
    if (!r_is_objc_ptr(view)) return;
    uint64_t UIColor = r_class("UIColor");
    if (!r_is_objc_ptr(UIColor) || !r_responds(UIColor, "colorWithWhite:alpha:")) return;
    uint64_t color = r_msg2_main_raw(UIColor, "colorWithWhite:alpha:",
                                     &white, sizeof(white),
                                     &alpha, sizeof(alpha),
                                     NULL, 0, NULL, 0);
    if (r_is_objc_ptr(color))
        r_msg2_main(view, "setBackgroundColor:", color, 0, 0, 0);
}

static void stagestrip_set_layer_border_white(uint64_t view,
                                              double white,
                                              double alpha,
                                              double width)
{
    if (!r_is_objc_ptr(view)) return;
    uint64_t layer = r_msg2_main(view, "layer", 0, 0, 0, 0);
    uint64_t UIColor = r_class("UIColor");
    if (!r_is_objc_ptr(layer) || !r_is_objc_ptr(UIColor) ||
        !r_responds(UIColor, "colorWithWhite:alpha:")) {
        return;
    }

    uint64_t color = r_msg2_main_raw(UIColor, "colorWithWhite:alpha:",
                                     &white, sizeof(white),
                                     &alpha, sizeof(alpha),
                                     NULL, 0, NULL, 0);
    uint64_t cgColor = r_is_objc_ptr(color) && r_responds(color, "CGColor")
        ? r_msg2_main(color, "CGColor", 0, 0, 0, 0)
        : 0;
    if (cgColor) r_msg2_main(layer, "setBorderColor:", cgColor, 0, 0, 0);
    stagestrip_send_double(layer, "setBorderWidth:", width);
}

static void stagestrip_cleanup_host_view_depth(uint64_t view, int depth)
{
    if (!r_is_objc_ptr(view)) return;
    if (depth < 6) {
        uint64_t subs = r_msg2_main(view, "subviews", 0, 0, 0, 0);
        if (r_is_objc_ptr(subs)) {
            uint64_t cnt = r_msg2_main(subs, "count", 0, 0, 0, 0);
            for (uint64_t i = 0; i < cnt && i < 64; i++) {
                uint64_t child = r_msg2_main(subs, "objectAtIndex:", i, 0, 0, 0);
                stagestrip_cleanup_host_view_depth(child, depth + 1);
            }
        }
    }

    const char *keys[] = {
        "cyanideStageStripMedusaViewController",
        "cyanideStageStripLiveContentOverlay",
        NULL,
    };
    for (int i = 0; keys[i]; i++) {
        uint64_t key = r_sel(keys[i]);
        if (!key) continue;
        uint64_t obj = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                    view, key, 0, 0, 0, 0, 0, 0);
        if (r_is_objc_ptr(obj) && r_responds(obj, "invalidate"))
            r_msg2_main(obj, "invalidate", 0, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     view, key, 0, 1 /* RETAIN_NONATOMIC */,
                     0, 0, 0, 0);
    }

    if (r_responds(view, "invalidate"))
        r_msg2_main(view, "invalidate", 0, 0, 0, 0);
}

static void stagestrip_cleanup_host_view(uint64_t view)
{
    stagestrip_cleanup_host_view_depth(view, 0);
}

static void stagestrip_set_frame_fast(uint64_t obj, StripRect rect)
{
    if (!r_is_objc_ptr(obj)) return;
    r_msg2_main_raw(obj, "setFrame:",
                    &rect, sizeof(rect),
                    NULL, 0, NULL, 0, NULL, 0);
}

static void stagestrip_set_frame_thread(uint64_t obj, StripRect rect)
{
    if (!r_is_objc_ptr(obj)) return;
    r_msg2_main_raw(obj, "setFrame:",
                    &rect, sizeof(rect),
                    NULL, 0, NULL, 0, NULL, 0);
}

static void stagestrip_set_bounds_thread(uint64_t obj, StripRect rect)
{
    if (!r_is_objc_ptr(obj)) return;
    r_msg2_main_raw(obj, "setBounds:",
                    &rect, sizeof(rect),
                    NULL, 0, NULL, 0, NULL, 0);
}

static void stagestrip_set_point_thread(uint64_t obj, const char *sel, StripPoint point)
{
    if (!r_is_objc_ptr(obj) || !sel) return;
    r_msg2_main_raw(obj, sel,
                    &point, sizeof(point),
                    NULL, 0, NULL, 0, NULL, 0);
}

static double stagestrip_screen_scale(void)
{
    double scale = UIScreen.mainScreen.scale;
    return isfinite(scale) && scale > 0.0 ? scale : 3.0;
}

static void stagestrip_sync_layer_geometry(uint64_t layer,
                                           double w,
                                           double h,
                                           int depth,
                                           bool recenter)
{
    if (!r_is_objc_ptr(layer) || w <= 0.0 || h <= 0.0) return;

    StripRect bounds = { 0.0, 0.0, w, h };
    if (recenter) {
        stagestrip_set_frame_thread(layer, bounds);
        stagestrip_set_point_thread(layer, "setPosition:", (StripPoint){ w * 0.5, h * 0.5 });
    } else {
        stagestrip_set_bounds_thread(layer, bounds);
    }
    stagestrip_send_double(layer, "setContentsScale:", stagestrip_screen_scale());

    if (r_responds(layer, "setContentsRect:")) {
        StripRect unitRect = { 0.0, 0.0, 1.0, 1.0 };
        r_msg2_main_raw(layer, "setContentsRect:",
                        &unitRect, sizeof(unitRect),
                        NULL, 0, NULL, 0, NULL, 0);
    }
    if (r_responds(layer, "setNeedsLayout"))
        r_msg2_main(layer, "setNeedsLayout", 0, 0, 0, 0);
    if (r_responds(layer, "layoutIfNeeded"))
        r_msg2_main(layer, "layoutIfNeeded", 0, 0, 0, 0);
    if (r_responds(layer, "setNeedsDisplay"))
        r_msg2_main(layer, "setNeedsDisplay", 0, 0, 0, 0);

    if (depth <= 0) return;
    uint64_t sublayers = r_responds(layer, "sublayers")
        ? r_msg2_main(layer, "sublayers", 0, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(sublayers)) return;
    uint64_t count = r_msg2_main(sublayers, "count", 0, 0, 0, 0);
    for (uint64_t i = 0; i < count && i < 16; i++) {
        uint64_t sublayer = r_msg2_main(sublayers, "objectAtIndex:", i, 0, 0, 0);
        stagestrip_sync_layer_geometry(sublayer, w, h, depth - 1, true);
    }
}

static void stagestrip_refresh_host_view_geometry(uint64_t view, double w, double h)
{
    if (!r_is_objc_ptr(view) || w <= 0.0 || h <= 0.0) return;

    StripRect bounds = { 0.0, 0.0, w, h };
    stagestrip_set_bounds_thread(view, bounds);
    if (r_responds(view, "setContentScaleFactor:"))
        stagestrip_send_double(view, "setContentScaleFactor:", stagestrip_screen_scale());

    struct { double w; double h; } refSize = { w, h };
    int64_t orient = 1; // UIInterfaceOrientationPortrait
    if (r_responds(view, "_setReferenceSize:")) {
        r_msg2_main_raw(view, "_setReferenceSize:",
                        &refSize, sizeof(refSize),
                        NULL, 0, NULL, 0, NULL, 0);
    }
    if (r_responds(view, "setReferenceSize:")) {
        r_msg2_main_raw(view, "setReferenceSize:",
                        &refSize, sizeof(refSize),
                        NULL, 0, NULL, 0, NULL, 0);
    }
    if (r_responds(view, "_updateReferenceSize:andOrientation:")) {
        r_msg2_main_raw(view, "_updateReferenceSize:andOrientation:",
                        &refSize, sizeof(refSize),
                        &orient,  sizeof(orient),
                        NULL, 0, NULL, 0);
    }

    uint64_t layer = r_msg2_main(view, "layer", 0, 0, 0, 0);
    stagestrip_sync_layer_geometry(layer, w, h, 2, false);

    if (r_responds(view, "setNeedsLayout"))
        r_msg2_main(view, "setNeedsLayout", 0, 0, 0, 0);
    if (r_responds(view, "layoutIfNeeded"))
        r_msg2_main(view, "layoutIfNeeded", 0, 0, 0, 0);
}

// Capability flags for the host view class. Set on first call; -1 = unknown.
static int8_t gHostViewHasAutoResizeMask  = -1;
static int8_t gHostViewHasUpdateRefSize   = -1;
static int8_t gHostViewHasNeedsLayout     = -1;
static int8_t gHostViewHasLayoutIfNeeded  = -1;

static void stagestrip_resize_host_view_frame(uint64_t view, double w, double h)
{
    if (!r_is_objc_ptr(view)) return;
    double bi = kStripBorderInset;
    double iw = w - 2.0 * bi;
    double ih = h - 2.0 * bi;
    if (iw < 80.0) iw = 80.0;
    if (ih < 80.0) ih = 80.0;
    stagestrip_set_frame_thread(view, (StripRect){ bi, bi, iw, ih });
    stagestrip_set_bounds_thread(view, (StripRect){ 0.0, 0.0, iw, ih });
}

static uint64_t stagestrip_resize_host_view_commit_for_slot(int slot,
                                                            uint64_t view,
                                                            double w,
                                                            double h)
{
    stagestrip_resize_host_view_frame(view, w, h);
    if (!r_is_objc_ptr(view)) return view;

    double bi = kStripBorderInset;
    double iw = w - 2.0 * bi;
    double ih = h - 2.0 * bi;
    if (iw < 80.0) iw = 80.0;
    if (ih < 80.0) ih = 80.0;
    stagestrip_refresh_host_view_geometry(view, iw, ih);

    uint64_t sceneKey = r_sel("cyanideStageStripHostedScene");
    uint64_t scene = sceneKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                       view, sceneKey, 0, 0, 0, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(scene)) return view;

    uint64_t superview = r_responds(view, "superview")
        ? r_msg2_main(view, "superview", 0, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(superview)) return view;

    uint64_t hostKey = r_sel("cyanideStageStripSceneLayerHost");
    if (hostKey) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     scene, hostKey, 0, 1 /* RETAIN_NONATOMIC */,
                     0, 0, 0, 0);
    }

    uint64_t fresh = stagestrip_make_scene_layer_host_view(scene, "resize", iw, ih);
    if (!r_is_objc_ptr(fresh) || fresh == view) return view;

    stagestrip_set_frame_thread(fresh, (StripRect){ bi, bi, iw, ih });
    stagestrip_set_bounds_thread(fresh, (StripRect){ 0.0, 0.0, iw, ih });
    r_msg2_main(fresh, "setAutoresizingMask:", 2 | 16, 0, 0, 0);
    r_msg2_main(fresh, "setClipsToBounds:", 1, 0, 0, 0);
    r_msg2_main(fresh, "setUserInteractionEnabled:", 1, 0, 0, 0);
    uint64_t freshLayer = r_msg2_main(fresh, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(freshLayer))
        stagestrip_send_double(freshLayer, "setCornerRadius:", kStripCornerRadius - bi);
    stagestrip_refresh_host_view_geometry(fresh, iw, ih);

    stagestrip_send_double(fresh, "setAlpha:", 0.0);
    r_msg2_main(superview, "addSubview:", fresh, 0, 0, 0);
    stagestrip_schedule_invocation(superview,
        stagestrip_make_double_invocation(fresh, "setAlpha:", 1.0),
        kStripResizeSwapRevealDelay);
    stagestrip_schedule_invocation(superview,
        stagestrip_make_double_invocation(view, "setAlpha:", 0.0),
        kStripResizeSwapRetireDelay);
    stagestrip_schedule_invocation(superview,
        stagestrip_make_bool_invocation(view, "setHidden:", true),
        kStripResizeSwapRetireDelay + 0.03);
    stagestrip_schedule_invocation(superview,
        stagestrip_make_invocation(view, "removeFromSuperview", NULL, 0),
        kStripResizeSwapRetireDelay + 0.05);

    if (slot >= 0 && slot < kStripMaxFloatSlots) {
        StripFloatSlot *S = &gStripFloatSlots[slot];
        if (S->hostView == view) S->hostView = fresh;
        if (slot < 2 && gStripLives[slot] == view) gStripLives[slot] = fresh;
        stagestrip_raise_pan_handles_slot(S);
    }

    printf("[STAGE] resize[%d]: staged scene host swap old=0x%llx fresh=0x%llx scene=0x%llx size=%.0fx%.0f\n",
           slot, view, fresh, scene, iw, ih);
    return fresh;
}

static void stagestrip_set_center_thread(uint64_t obj, StripPoint center)
{
    if (!r_is_objc_ptr(obj)) return;
    r_msg2_main_raw(obj, "setCenter:",
                    &center, sizeof(center),
                    NULL, 0, NULL, 0, NULL, 0);
}

static uint64_t stagestrip_make_invocation(uint64_t target,
                                           const char *selName,
                                           const void *arg,
                                           size_t argSize)
{
    if (!r_is_objc_ptr(target) || !selName) return 0;
    uint64_t sel = r_sel(selName);
    uint64_t sig = sel
        ? r_msg2_main(target, "methodSignatureForSelector:", sel, 0, 0, 0)
        : 0;
    uint64_t NSInvocation = r_class("NSInvocation");
    uint64_t inv = r_is_objc_ptr(NSInvocation) && r_is_objc_ptr(sig)
        ? r_msg2_main(NSInvocation, "invocationWithMethodSignature:", sig, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(inv)) return 0;

    r_msg2_main(inv, "setTarget:", target, 0, 0, 0);
    r_msg2_main(inv, "setSelector:", sel, 0, 0, 0);
    if (arg && argSize > 0) {
        uint64_t argBuf = r_dlsym_call(R_TIMEOUT, "malloc", argSize,
                                       0, 0, 0, 0, 0, 0, 0);
        if (argBuf) {
            remote_write(argBuf, arg, argSize);
            r_msg2_main(inv, "setArgument:atIndex:", argBuf, 2, 0, 0);
            r_free(argBuf);
        }
    }
    r_msg2_main(inv, "retainArguments", 0, 0, 0, 0);
    return inv;
}

static uint64_t stagestrip_make_bool_invocation(uint64_t target,
                                                const char *selName,
                                                bool value)
{
    uint8_t b = value ? 1 : 0;
    return stagestrip_make_invocation(target, selName, &b, sizeof(b));
}

static uint64_t stagestrip_make_object_invocation(uint64_t target,
                                                  const char *selName,
                                                  uint64_t object)
{
    return stagestrip_make_invocation(target, selName, &object, sizeof(object));
}

static uint64_t stagestrip_make_int_invocation(uint64_t target,
                                               const char *selName,
                                               int64_t value)
{
    return stagestrip_make_invocation(target, selName, &value, sizeof(value));
}

static uint64_t stagestrip_make_double_invocation(uint64_t target,
                                                  const char *selName,
                                                  double value)
{
    return stagestrip_make_invocation(target, selName, &value, sizeof(value));
}

static void stagestrip_retain_action_target(uint64_t owner, uint64_t target)
{
    if (!r_is_objc_ptr(owner) || !r_is_objc_ptr(target)) return;
    uint64_t key = r_sel("cyanideStageStripActionTargets");
    if (!key) return;

    uint64_t arr = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                owner, key, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(arr)) {
        uint64_t NSMutableArray = r_class("NSMutableArray");
        arr = r_is_objc_ptr(NSMutableArray)
            ? r_msg2_main(NSMutableArray, "array", 0, 0, 0, 0)
            : 0;
        if (!r_is_objc_ptr(arr)) return;
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     owner, key, arr, 1 /* RETAIN_NONATOMIC */, 0, 0, 0, 0);
    }
    r_msg2_main(arr, "addObject:", target, 0, 0, 0);
}

static void stagestrip_add_control_action(uint64_t control, uint64_t target, uint64_t actionSel)
{
    if (!r_is_objc_ptr(control) || !r_is_objc_ptr(target) || !actionSel) return;
    r_msg2_main(control, "addTarget:action:forControlEvents:",
                target, actionSel, 64 /* UIControlEventTouchUpInside */, 0);
    stagestrip_retain_action_target(control, target);
}

static void stagestrip_add_invocation_action(uint64_t control, uint64_t inv)
{
    uint64_t invokeSel = r_sel("invoke");
    stagestrip_add_control_action(control, inv, invokeSel);
}

static void stagestrip_schedule_invocation(uint64_t owner, uint64_t inv, double delay)
{
    if (!r_is_objc_ptr(inv)) return;
    uint64_t invokeSel = r_sel("invoke");
    if (!invokeSel) return;
    uint64_t nilObj = 0;
    r_msg2_main_raw(inv, "performSelector:withObject:afterDelay:",
                    &invokeSel, sizeof(invokeSel),
                    &nilObj, sizeof(nilObj),
                    &delay, sizeof(delay),
                    NULL, 0);
    if (r_is_objc_ptr(owner))
        stagestrip_retain_action_target(owner, inv);
}

static uint64_t stagestrip_current_window_scene(void)
{
    uint64_t UIApplication = r_class("UIApplication");
    uint64_t app = r_is_objc_ptr(UIApplication)
        ? r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(app)) return 0;

    uint64_t keyWin = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    if (!r_is_objc_ptr(keyWin)) {
        uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
        if (r_is_objc_ptr(windows)) {
            uint64_t count = r_msg2_main(windows, "count", 0, 0, 0, 0);
            for (uint64_t i = 0; i < count && i < 32; i++) {
                uint64_t win = r_msg2_main(windows, "objectAtIndex:", i, 0, 0, 0);
                if (r_is_objc_ptr(win) && r_responds(win, "windowScene")) {
                    keyWin = win;
                    break;
                }
            }
        }
    }
    if (r_is_objc_ptr(keyWin) && r_responds(keyWin, "windowScene")) {
        uint64_t scene = r_msg2_main(keyWin, "windowScene", 0, 0, 0, 0);
        if (r_is_objc_ptr(scene)) return scene;
    }
    if (r_is_objc_ptr(gStripPickerOverlayWin) && r_responds(gStripPickerOverlayWin, "windowScene")) {
        uint64_t scene = r_msg2_main(gStripPickerOverlayWin, "windowScene", 0, 0, 0, 0);
        if (r_is_objc_ptr(scene)) return scene;
    }
    return 0;
}

static uint64_t stagestrip_transition_shield_window(void)
{
    if (r_is_objc_ptr(gStripTransitionShieldWin))
        return gStripTransitionShieldWin;

    uint64_t UIApplication = r_class("UIApplication");
    uint64_t app = r_is_objc_ptr(UIApplication)
        ? r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0)
        : 0;
    uint64_t scene = stagestrip_current_window_scene();
    if (!r_is_objc_ptr(app) || !r_is_objc_ptr(scene)) return 0;

    uint64_t assocKey = r_sel("cyanideStageStripTransitionShieldWindow");
    uint64_t cached = assocKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                       app, assocKey, 0, 0, 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(cached)) {
        gStripTransitionShieldWin = cached;
    } else {
        uint64_t UIWindow = r_class("UIWindow");
        uint64_t alloc = r_is_objc_ptr(UIWindow)
            ? r_msg2_main(UIWindow, "alloc", 0, 0, 0, 0)
            : 0;
        gStripTransitionShieldWin = r_is_objc_ptr(alloc)
            ? r_msg2_main(alloc, "initWithWindowScene:", scene, 0, 0, 0)
            : 0;
        if (!r_is_objc_ptr(gStripTransitionShieldWin)) return 0;
        if (assocKey) {
            r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                         app, assocKey, gStripTransitionShieldWin,
                         1 /* RETAIN_NONATOMIC */, 0, 0, 0, 0);
        }
    }

    CGRect b = UIScreen.mainScreen.bounds;
    double sw = isfinite(b.size.width)  && b.size.width  >= 200.0 ? b.size.width  : 390.0;
    double sh = isfinite(b.size.height) && b.size.height >= 200.0 ? b.size.height : 844.0;
    stagestrip_set_frame_fast(gStripTransitionShieldWin, (StripRect){ 0.0, 0.0, sw, sh });
    stagestrip_send_double(gStripTransitionShieldWin, "setWindowLevel:", kStripWindowLevel - 1.0);
    stagestrip_set_background_white(gStripTransitionShieldWin, 0.0, 1.0);
    if (r_responds(gStripTransitionShieldWin, "setOpaque:"))
        r_msg2_main(gStripTransitionShieldWin, "setOpaque:", 0, 0, 0, 0);
    r_msg2_main(gStripTransitionShieldWin, "setUserInteractionEnabled:", 0, 0, 0, 0);
    return gStripTransitionShieldWin;
}

static void stagestrip_show_transition_shield(double alpha)
{
    uint64_t shield = stagestrip_transition_shield_window();
    if (!r_is_objc_ptr(shield)) return;
    if (alpha <= 0.0) alpha = kStripTransitionShieldAlpha;
    stagestrip_send_double(shield, "setAlpha:", alpha);
    r_msg2_main(shield, "setHidden:", 0, 0, 0, 0);
}

static void stagestrip_hide_transition_shield_animated(void)
{
    uint64_t shield = gStripTransitionShieldWin;
    if (!r_is_objc_ptr(shield)) return;

    stagestrip_animation_begin(kStripTransitionShieldFade);
    stagestrip_send_double(shield, "setAlpha:", 0.0);
    stagestrip_animation_commit();
    stagestrip_schedule_invocation(shield,
        stagestrip_make_bool_invocation(shield, "setHidden:", true),
        kStripTransitionShieldFade + 0.03);
}

static void stagestrip_hide_transition_shield_after(double delay)
{
    uint64_t shield = gStripTransitionShieldWin;
    if (!r_is_objc_ptr(shield)) return;
    if (delay <= 0.0) {
        stagestrip_hide_transition_shield_animated();
        return;
    }

    stagestrip_schedule_invocation(shield,
        stagestrip_make_double_invocation(shield, "setAlpha:", 0.0),
        delay);
    stagestrip_schedule_invocation(shield,
        stagestrip_make_bool_invocation(shield, "setHidden:", true),
        delay + kStripTransitionShieldFade + 0.03);
}

static void stagestrip_show_picker_overlay_animated(void)
{
    uint64_t overlay = gStripPickerOverlayWin;
    if (!r_is_objc_ptr(overlay)) return;
    uint64_t panel = gStripPickerPanel;
    bool wasHidden = stagestrip_view_is_hidden(overlay);

    if (r_responds(overlay, "setUserInteractionEnabled:"))
        r_msg2_main(overlay, "setUserInteractionEnabled:", 1, 0, 0, 0);
    if (wasHidden) {
        stagestrip_send_double(overlay, "setAlpha:", 0.0);
        if (r_is_objc_ptr(panel)) {
            stagestrip_send_double(panel, "setAlpha:", 0.0);
            stagestrip_set_transform_thread(panel, CGAffineTransformMakeTranslation(0.0, 42.0));
        }
    }
    r_msg2_main(overlay, "setHidden:", 0, 0, 0, 0);

    stagestrip_animation_begin(0.22);
    stagestrip_send_double(overlay, "setAlpha:", 1.0);
    if (r_is_objc_ptr(panel)) {
        stagestrip_send_double(panel, "setAlpha:", 1.0);
        stagestrip_set_transform_thread(panel, CGAffineTransformIdentity);
    }
    stagestrip_animation_commit();
    printf("[STAGE] picker: shown animated overlay=0x%llx panel=0x%llx\n",
           overlay, panel);
}

static void stagestrip_hide_picker_overlay_animated(void)
{
    uint64_t overlay = gStripPickerOverlayWin;
    if (!r_is_objc_ptr(overlay)) return;
    uint64_t panel = gStripPickerPanel;

    if (r_responds(overlay, "setUserInteractionEnabled:"))
        r_msg2_main(overlay, "setUserInteractionEnabled:", 0, 0, 0, 0);
    stagestrip_animation_begin(0.18);
    stagestrip_send_double(overlay, "setAlpha:", 0.0);
    if (r_is_objc_ptr(panel)) {
        stagestrip_send_double(panel, "setAlpha:", 0.0);
        stagestrip_set_transform_thread(panel, CGAffineTransformMakeTranslation(0.0, 42.0));
    }
    stagestrip_animation_commit();
    stagestrip_schedule_invocation(overlay,
        stagestrip_make_bool_invocation(overlay, "setHidden:", true),
        0.21);
    printf("[STAGE] picker: hiding animated overlay=0x%llx panel=0x%llx\n",
           overlay, panel);
}

static uint64_t stagestrip_make_control_button(const char *title,
                                               double x,
                                               double y,
                                               double w,
                                               double h)
{
    uint64_t UIButton = r_class("UIButton");
    uint64_t button = r_is_objc_ptr(UIButton)
        ? r_msg2_main(UIButton, "buttonWithType:", 1, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(button)) return 0;

    stagestrip_set_frame_fast(button, (StripRect){ x, y, w, h });
    r_msg2_main(button, "setClipsToBounds:", 1, 0, 0, 0);
    r_msg2_main(button, "setAutoresizingMask:", 1 | 8 /* stick bottom-right by default */, 0, 0, 0);
    stagestrip_set_background_white(button, 0.0, 0.58);

    uint64_t layer = r_msg2_main(button, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        stagestrip_send_double(layer, "setCornerRadius:", 8.0);
        r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
    }

    uint64_t titleStr = r_nsstr_retained(title ? title : "");
    if (r_is_objc_ptr(titleStr)) {
        r_msg2_main(button, "setTitle:forState:", titleStr, 0, 0, 0);
        r_msg2_main(titleStr, "release", 0, 0, 0, 0);
    }
    uint64_t UIColor = r_class("UIColor");
    uint64_t white = r_is_objc_ptr(UIColor) && r_responds(UIColor, "whiteColor")
        ? r_msg2_main(UIColor, "whiteColor", 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(white))
        r_msg2_main(button, "setTitleColor:forState:", white, 0, 0, 0);
    return button;
}

static uint64_t stagestrip_make_text_label(const char *text,
                                           double x,
                                           double y,
                                           double w,
                                           double h)
{
    uint64_t UILabel = r_class("UILabel");
    uint64_t alloc = r_is_objc_ptr(UILabel)
        ? r_msg2_main(UILabel, "alloc", 0, 0, 0, 0)
        : 0;
    uint64_t label = r_is_objc_ptr(alloc)
        ? r_msg2_main(alloc, "init", 0, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(label)) return 0;

    stagestrip_set_frame_fast(label, (StripRect){ x, y, w, h });
    r_msg2_main(label, "setUserInteractionEnabled:", 0, 0, 0, 0);
    r_msg2_main(label, "setClipsToBounds:", 1, 0, 0, 0);
    stagestrip_set_background_white(label, 0.0, 0.42);

    uint64_t layer = r_msg2_main(label, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        stagestrip_send_double(layer, "setCornerRadius:", 6.0);
        r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
    }

    uint64_t str = r_nsstr_retained(text ? text : "");
    if (r_is_objc_ptr(str)) {
        r_msg2_main(label, "setText:", str, 0, 0, 0);
        r_msg2_main(str, "release", 0, 0, 0, 0);
    }
    uint64_t UIColor = r_class("UIColor");
    uint64_t white = r_is_objc_ptr(UIColor) && r_responds(UIColor, "whiteColor")
        ? r_msg2_main(UIColor, "whiteColor", 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(white))
        r_msg2_main(label, "setTextColor:", white, 0, 0, 0);
    if (r_responds(label, "setAdjustsFontSizeToFitWidth:"))
        r_msg2_main(label, "setAdjustsFontSizeToFitWidth:", 1, 0, 0, 0);
    if (r_responds(label, "setMinimumScaleFactor:")) {
        double scale = 0.45;
        r_msg2_main_raw(label, "setMinimumScaleFactor:",
                        &scale, sizeof(scale),
                        NULL, 0, NULL, 0, NULL, 0);
    }
    return label;
}

static StripRect stagestrip_clamped_rect(double x,
                                         double y,
                                         double w,
                                         double h,
                                         double sw,
                                         double sh)
{
    if (w > sw - 16.0) w = sw - 16.0;
    if (h > sh - 72.0) h = sh - 72.0;
    if (w < 180.0) w = 180.0;
    if (h < 260.0) h = 260.0;
    if (x < 8.0) x = 8.0;
    if (y < 54.0) y = 54.0;
    if (x + w > sw - 8.0) x = sw - w - 8.0;
    if (y + h > sh - 34.0) y = sh - h - 34.0;
    return (StripRect){ x, y, w, h };
}

static bool stagestrip_get_frame_thread(uint64_t obj, StripRect *out)
{
    if (!out) return false;
    memset(out, 0, sizeof(*out));
    return r_msg2_main_struct_ret(obj, "frame",
                                  out, sizeof(*out),
                                  NULL, 0, NULL, 0, NULL, 0, NULL, 0);
}

static bool stagestrip_get_translation_thread(uint64_t pan, uint64_t view, StripPoint *out)
{
    if (!out) return false;
    memset(out, 0, sizeof(*out));
    return r_msg2_main_struct_ret(pan, "translationInView:",
                                  out, sizeof(*out),
                                  &view, sizeof(view),
                                  NULL, 0, NULL, 0, NULL, 0);
}

static void stagestrip_relayout_stage_host_thread(uint64_t hostView, double w, double h)
{
    if (!r_is_objc_ptr(hostView)) return;

    stagestrip_set_frame_thread(hostView, (StripRect){ 0.0, 0.0, w, h });

    uint64_t row0 = gStripRows[0];
    uint64_t row1 = gStripRows[1];
    uint64_t live0 = gStripLives[0];
    uint64_t live1 = gStripLives[1];
    if (!r_is_objc_ptr(row0)) {
        uint64_t row0Key = r_sel("cyanideStageStripRow0");
        uint64_t live0Key = r_sel("cyanideStageStripLive0");
        row0 = row0Key ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                      hostView, row0Key, 0, 0, 0, 0, 0, 0) : 0;
        live0 = live0Key ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                        hostView, live0Key, 0, 0, 0, 0, 0, 0) : 0;
    }
    if (!r_is_objc_ptr(row1)) {
        uint64_t row1Key = r_sel("cyanideStageStripRow1");
        uint64_t live1Key = r_sel("cyanideStageStripLive1");
        row1 = row1Key ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                      hostView, row1Key, 0, 0, 0, 0, 0, 0) : 0;
        live1 = live1Key ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                        hostView, live1Key, 0, 0, 0, 0, 0, 0) : 0;
    }
    int count = r_is_objc_ptr(row1) ? 2 : 1;
    double gap = count > 1 ? kStripStackGap : 0.0;
    double rowH = (h - gap * (count - 1)) / count;
    if (rowH < 80.0) rowH = h / count;

    if (r_is_objc_ptr(row0)) {
        stagestrip_set_frame_thread(row0, (StripRect){ 0.0, 0.0, w, rowH });
        if (r_is_objc_ptr(live0))
            stagestrip_set_frame_thread(live0, (StripRect){ 0.0, (rowH - h) / 2.0, w, h });
    }
    if (r_is_objc_ptr(row1)) {
        double y = rowH + gap;
        stagestrip_set_frame_thread(row1, (StripRect){ 0.0, y, w, rowH });
        if (r_is_objc_ptr(live1))
            stagestrip_set_frame_thread(live1, (StripRect){ 0.0, (rowH - h) / 2.0, w, h });
    }
}

static uint64_t stagestrip_make_pan_handle(uint64_t win,
                                           const char *role,
                                           StripRect frame,
                                           uint64_t autoresizing,
                                           double alpha)
{
    uint64_t UIView = r_class("UIView");
    uint64_t alloc = r_is_objc_ptr(UIView)
        ? r_msg2_main(UIView, "alloc", 0, 0, 0, 0)
        : 0;
    uint64_t handle = r_is_objc_ptr(alloc)
        ? r_msg2_main(alloc, "init", 0, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(handle)) return 0;

    stagestrip_set_frame_fast(handle, frame);
    r_msg2_main(handle, "setAutoresizingMask:", autoresizing, 0, 0, 0);
    r_msg2_main(handle, "setUserInteractionEnabled:", 1, 0, 0, 0);
    r_msg2_main(handle, "setMultipleTouchEnabled:", 0, 0, 0, 0);
    stagestrip_set_background_white(handle, 1.0, alpha);

    uint64_t layer = r_msg2_main(handle, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        stagestrip_send_double(layer, "setCornerRadius:", role && strcmp(role, "resize") == 0 ? 11.0 : 6.0);
        r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
    }

    bool moveRole = role && strcmp(role, "move") == 0;
    if (moveRole) {
        uint64_t visualAlloc = r_msg2_main(UIView, "alloc", 0, 0, 0, 0);
        uint64_t visual = r_is_objc_ptr(visualAlloc)
            ? r_msg2_main(visualAlloc, "init", 0, 0, 0, 0)
            : 0;
        if (r_is_objc_ptr(visual)) {
            StripRect vr = { (frame.width - 116.0) / 2.0, 14.0, 116.0, 7.0 };
            if (vr.x < 8.0) vr.x = 8.0;
            if (vr.width > frame.width - 16.0) vr.width = frame.width - 16.0;
            stagestrip_set_frame_fast(visual, vr);
            r_msg2_main(visual, "setUserInteractionEnabled:", 0, 0, 0, 0);
            r_msg2_main(visual, "setAutoresizingMask:", 1 | 4, 0, 0, 0);
            stagestrip_set_background_white(visual, 1.0, 0.36);
            uint64_t visualLayer = r_msg2_main(visual, "layer", 0, 0, 0, 0);
            if (r_is_objc_ptr(visualLayer)) {
                stagestrip_send_double(visualLayer, "setCornerRadius:", 3.5);
                r_msg2_main(visualLayer, "setMasksToBounds:", 1, 0, 0, 0);
            }
            r_msg2_main(handle, "addSubview:", visual, 0, 0, 0);
        }
    }

    uint64_t UIPan = r_class("UIPanGestureRecognizer");
    uint64_t noopInv = stagestrip_make_invocation(handle, "setNeedsLayout", NULL, 0);
    uint64_t invokeSel = r_sel("invoke");
    uint64_t panAlloc = r_is_objc_ptr(UIPan)
        ? r_msg2_main(UIPan, "alloc", 0, 0, 0, 0)
        : 0;
    uint64_t pan = r_is_objc_ptr(panAlloc) && r_is_objc_ptr(noopInv) && invokeSel
        ? r_msg2_main(panAlloc, "initWithTarget:action:", noopInv, invokeSel, 0, 0)
        : 0;
    if (r_is_objc_ptr(pan)) {
        if (r_responds(pan, "setMinimumNumberOfTouches:"))
            r_msg2_main(pan, "setMinimumNumberOfTouches:", 1, 0, 0, 0);
        if (r_responds(pan, "setMaximumNumberOfTouches:"))
            r_msg2_main(pan, "setMaximumNumberOfTouches:", 1, 0, 0, 0);
        if (r_responds(pan, "setCancelsTouchesInView:"))
            r_msg2_main(pan, "setCancelsTouchesInView:", 1, 0, 0, 0);
        if (r_responds(pan, "setDelaysTouchesBegan:"))
            r_msg2_main(pan, "setDelaysTouchesBegan:", 0, 0, 0, 0);
        r_msg2_main(handle, "addGestureRecognizer:", pan, 0, 0, 0);
        stagestrip_retain_action_target(handle, noopInv);
    }

    r_msg2_main(win, "addSubview:", handle, 0, 0, 0);
    printf("[STAGE] pan: %s handle=0x%llx recognizer=0x%llx\n",
           role ? role : "unknown", handle, pan);
    return handle;
}

// Build a Stage Manager–style quarter-arc glyph as a CAShapeLayer added to
// `host`. `corner` tells us which corner of the host this glyph decorates:
//   TL → arc opens to the bottom-right (sweep top→right at host's TL)
//   TR → arc opens to the bottom-left
//   BL → arc opens to the top-right
//   BR → arc opens to the top-left
// `side` is the size of the parent handle (e.g. 50). The arc lives at the
// outer corner with radius ~10pt, traced via UIBezierPath quad-curves so we
// can drive it through r_msg2_main_raw (which caps at 4 by-value args).
static uint64_t stagestrip_install_corner_arc_glyph(uint64_t host,
                                                    StripCorner corner,
                                                    double side)
{
    if (!r_is_objc_ptr(host)) return 0;

    uint64_t UIBezierPath = r_class("UIBezierPath");
    uint64_t path = r_is_objc_ptr(UIBezierPath)
        ? r_msg2_main(UIBezierPath, "bezierPath", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(path)) return 0;

    double r = 12.0;     // arc radius
    double pad = 4.0;    // distance from absolute corner
    double inner = pad + r;
    // For each corner, we walk from one straight segment, around the arc,
    // to another straight segment — like a curved bracket "(" or ")".
    CGPoint p0 = {0}, p1 = {0}, p2 = {0}, ctrl = {0}, p3 = {0};
    switch (corner) {
    case kStripCornerBR:
        // bottom-right: arc opens up-left. Straight from (side-pad, inner)
        // curves to (inner, side-pad), control at (side-pad, side-pad).
        p0 = (CGPoint){ side - pad,    inner };
        p1 = (CGPoint){ side - pad,    side - pad };
        p2 = (CGPoint){ inner,         side - pad };
        ctrl = (CGPoint){ side - pad,  side - pad };
        p3 = (CGPoint){ inner - 6.0,   side - pad };
        break;
    case kStripCornerBL:
        // bottom-left: arc opens up-right.
        p0 = (CGPoint){ pad,           inner };
        p1 = (CGPoint){ pad,           side - pad };
        p2 = (CGPoint){ side - inner,  side - pad };
        ctrl = (CGPoint){ pad,         side - pad };
        p3 = (CGPoint){ side - inner + 6.0, side - pad };
        break;
    case kStripCornerTL:
        // top-left: arc opens down-right.
        p0 = (CGPoint){ pad,           side - inner };
        p1 = (CGPoint){ pad,           pad };
        p2 = (CGPoint){ side - inner,  pad };
        ctrl = (CGPoint){ pad,         pad };
        p3 = (CGPoint){ side - inner + 6.0, pad };
        break;
    case kStripCornerTR:
        // top-right: arc opens down-left.
        p0 = (CGPoint){ side - pad,    side - inner };
        p1 = (CGPoint){ side - pad,    pad };
        p2 = (CGPoint){ inner,         pad };
        ctrl = (CGPoint){ side - pad,  pad };
        p3 = (CGPoint){ inner - 6.0,   pad };
        break;
    default:
        return 0;
    }

    r_msg2_main_raw(path, "moveToPoint:",
                    &p0, sizeof(p0), NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main_raw(path, "addQuadCurveToPoint:controlPoint:",
                    &p2, sizeof(p2), &ctrl, sizeof(ctrl), NULL, 0, NULL, 0);
    r_msg2_main_raw(path, "addLineToPoint:",
                    &p3, sizeof(p3), NULL, 0, NULL, 0, NULL, 0);

    uint64_t cgPath = 0;
    if (r_responds(path, "CGPath"))
        cgPath = r_msg2_main(path, "CGPath", 0, 0, 0, 0);
    if (!cgPath) return 0;

    uint64_t CAShapeLayer = r_class("CAShapeLayer");
    uint64_t shapeAlloc = r_is_objc_ptr(CAShapeLayer)
        ? r_msg2_main(CAShapeLayer, "alloc", 0, 0, 0, 0) : 0;
    uint64_t shape = r_is_objc_ptr(shapeAlloc)
        ? r_msg2_main(shapeAlloc, "init", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(shape)) return 0;

    // Bright, chunky stroke so the resize affordance reads clearly over
    // arbitrary hosted app content.
    uint64_t UIColor = r_class("UIColor");
    uint64_t strokeColor = r_is_objc_ptr(UIColor) &&
                           r_responds(UIColor, "whiteColor")
        ? r_msg2_main(UIColor, "whiteColor", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(strokeColor) && r_responds(strokeColor, "colorWithAlphaComponent:")) {
        double a = 0.92;
        strokeColor = r_msg2_main_raw(strokeColor, "colorWithAlphaComponent:",
                                      &a, sizeof(a), NULL, 0, NULL, 0, NULL, 0);
    }
    uint64_t cgColor = 0;
    if (r_is_objc_ptr(strokeColor) && r_responds(strokeColor, "CGColor"))
        cgColor = r_msg2_main(strokeColor, "CGColor", 0, 0, 0, 0);

    r_msg2_main(shape, "setPath:", cgPath, 0, 0, 0);
    if (cgColor) r_msg2_main(shape, "setStrokeColor:", cgColor, 0, 0, 0);
    // Transparent fill (we want only the stroke).
    if (r_responds(shape, "setFillColor:"))
        r_msg2_main(shape, "setFillColor:", 0, 0, 0, 0);
    stagestrip_send_double(shape, "setLineWidth:", 4.0);

    // Round the stroke ends so the arc looks soft.
    uint64_t roundCap = r_nsstr_retained("round");
    if (r_is_objc_ptr(roundCap)) {
        if (r_responds(shape, "setLineCap:"))
            r_msg2_main(shape, "setLineCap:", roundCap, 0, 0, 0);
        r_msg2_main(roundCap, "release", 0, 0, 0, 0);
    }

    // Set the shape layer's frame to cover the whole handle.
    struct { double x, y, w, h; } f = { 0.0, 0.0, side, side };
    if (r_responds(shape, "setFrame:")) {
        r_msg2_main_raw(shape, "setFrame:", &f, sizeof(f), NULL, 0, NULL, 0, NULL, 0);
    }

    // Initial opacity: 0.92 (visible but not opaque). Keep the glyphs
    // visible after a resize so the next grab target remains discoverable.
    stagestrip_send_double(shape, "setOpacity:", 0.92);

    uint64_t hostLayer = r_msg2_main(host, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(hostLayer))
        r_msg2_main(hostLayer, "addSublayer:", shape, 0, 0, 0);
    return shape;
}

// Build one corner handle for a slot. Returns the handle UIView; caller
// extracts the pan recognizer from gestureRecognizers[0]. `outArc` (optional)
// receives the CAShapeLayer for the arc glyph so the control loop can toggle
// its opacity on/off as the user resizes.
static uint64_t stagestrip_make_corner_handle(uint64_t win,
                                              StripCorner corner,
                                              double w,
                                              double h,
                                              uint64_t *outArc)
{
    if (outArc) *outArc = 0;
    // Large finger-sized hit target; the move handle stays narrow so normal
    // app interaction is not swallowed across the whole top edge.
    double side = 72.0;
    double x = 0.0, y = 0.0;
    uint64_t autoresizing = 0;
    const char *roleName = "tl";
    switch (corner) {
    case kStripCornerTL:
        x = 0.0;           y = 0.0;
        autoresizing = 2 | 4 /* FlexibleRightMargin | FlexibleBottomMargin */;
        roleName = "tl";
        break;
    case kStripCornerTR:
        x = w - side;      y = 0.0;
        autoresizing = 1 | 4 /* FlexibleLeftMargin  | FlexibleBottomMargin */;
        roleName = "tr";
        break;
    case kStripCornerBL:
        x = 0.0;           y = h - side;
        autoresizing = 2 | 8 /* FlexibleRightMargin | FlexibleTopMargin */;
        roleName = "bl";
        break;
    case kStripCornerBR:
        x = w - side;      y = h - side;
        autoresizing = 1 | 8 /* FlexibleLeftMargin  | FlexibleTopMargin */;
        roleName = "br";
        break;
    default:
        return 0;
    }
    uint64_t handle = stagestrip_make_pan_handle(win,
                                                 roleName,
                                                 (StripRect){ x, y, side, side },
                                                 autoresizing,
                                                 0.0 /* fully transparent — only the arc is visible */);
    if (!r_is_objc_ptr(handle)) return 0;
    uint64_t arc = stagestrip_install_corner_arc_glyph(handle, corner, side);
    if (outArc) *outArc = arc;
    return handle;
}

static void stagestrip_install_pan_handles_slot(int slot,
                                                uint64_t win,
                                                uint64_t hostView,
                                                uint64_t referenceView,
                                                double w,
                                                double h)
{
    if (slot < 0 || slot >= kStripMaxFloatSlots) return;
    if (!r_is_objc_ptr(win) || !r_is_objc_ptr(hostView)) return;

    StripFloatSlot *S = &gStripFloatSlots[slot];

    double moveW = w - 96.0;
    if (moveW > 132.0) moveW = 132.0;
    if (moveW < 84.0) moveW = 84.0;
    double moveX = (w - moveW) / 2.0;
    uint64_t move = stagestrip_make_pan_handle(win,
                                               "move",
                                               (StripRect){ moveX, 0.0, moveW, 32.0 },
                                               1 | 2 | 4,
                                               0.05);
    uint64_t movePan = 0;
    if (r_is_objc_ptr(move)) {
        uint64_t grs = r_msg2_main(move, "gestureRecognizers", 0, 0, 0, 0);
        if (r_is_objc_ptr(grs) && r_msg2_main(grs, "count", 0, 0, 0, 0) > 0)
            movePan = r_msg2_main(grs, "objectAtIndex:", 0, 0, 0, 0);
    }

    // Install one resize handle per corner with a Stage Manager-style arc glyph.
    for (int c = 0; c < kStripCornerCount; c++) {
        uint64_t arc = 0;
        uint64_t cornerHandle = stagestrip_make_corner_handle(win, (StripCorner)c, w, h, &arc);
        S->cornerHandles[c] = cornerHandle;
        S->cornerArcs[c]    = arc;
        uint64_t cornerPan = 0;
        if (r_is_objc_ptr(cornerHandle)) {
            uint64_t grs = r_msg2_main(cornerHandle, "gestureRecognizers", 0, 0, 0, 0);
            if (r_is_objc_ptr(grs) && r_msg2_main(grs, "count", 0, 0, 0, 0) > 0)
                cornerPan = r_msg2_main(grs, "objectAtIndex:", 0, 0, 0, 0);
        }
        S->cornerPans[c] = cornerPan;
    }
    S->cornerArcsVisible = true; // initial state matches the 0.92 opacity above

    // Legacy single-handle pointers alias to BR so older code paths still see
    // a valid resize handle.
    S->resizeHandle = S->cornerHandles[kStripCornerBR];
    S->resizePan    = S->cornerPans[kStripCornerBR];

    S->window = win;
    S->hostView = hostView;
    S->moveHandle = move;
    S->movePan = movePan;
    S->referenceView = r_is_objc_ptr(referenceView) ? referenceView : win;
    printf("[STAGE] pan[%d]: installed win=0x%llx host=0x%llx ref=0x%llx movePan=0x%llx tl=0x%llx tr=0x%llx bl=0x%llx br=0x%llx\n",
           slot, win, hostView, S->referenceView, movePan,
           S->cornerPans[0], S->cornerPans[1], S->cornerPans[2], S->cornerPans[3]);
}

static void stagestrip_raise_pan_handles_slot(StripFloatSlot *S)
{
    if (!S || !r_is_objc_ptr(S->window)) return;
    for (int c = 0; c < kStripCornerCount; c++) {
        if (r_is_objc_ptr(S->cornerHandles[c]))
            r_msg2_main(S->window, "bringSubviewToFront:", S->cornerHandles[c], 0, 0, 0);
    }
    if (r_is_objc_ptr(S->moveHandle))
        r_msg2_main(S->window, "bringSubviewToFront:", S->moveHandle, 0, 0, 0);
    if (r_is_objc_ptr(S->closeButton))
        r_msg2_main(S->window, "bringSubviewToFront:", S->closeButton, 0, 0, 0);
}

// Install an X close button at the top-left corner of a slot's window. When
// tapped, hides both the host view and the window — the next control-loop
// tick observes the hidden state and tears down the slot.
static void stagestrip_install_slot_close_button(int slot,
                                                  uint64_t win,
                                                  uint64_t hostView,
                                                  double w)
{
    if (slot < 0 || slot >= kStripMaxFloatSlots) return;
    if (!r_is_objc_ptr(win)) return;
    (void)w; // top-left is anchored, not derived from width
    StripFloatSlot *S = &gStripFloatSlots[slot];
    if (r_is_objc_ptr(S->closeButton)) return; // already installed

    double btnSize = 46.0;
    double margin  = 3.0;
    double btnX    = margin;     // top-LEFT (was top-right)
    double btnY    = margin;
    uint64_t btn = stagestrip_make_control_button("", btnX, btnY, btnSize, btnSize);
    if (!r_is_objc_ptr(btn)) return;

    // No background — let the SF Symbol speak for itself.
    stagestrip_set_background_white(btn, 0.0, 0.0);
    // Stick to top-LEFT when the window resizes (FlexibleRightMargin | FlexibleBottomMargin).
    r_msg2_main(btn, "setAutoresizingMask:", 2 | 4, 0, 0, 0);

    // Glyph: try SF Symbol "xmark.circle.fill", fall back to unicode ✕.
    uint64_t UIImage = r_class("UIImage");
    uint64_t xName = r_nsstr_retained("xmark.circle.fill");
    uint64_t xImg = (r_is_objc_ptr(UIImage) && r_is_objc_ptr(xName) &&
                     r_responds(UIImage, "systemImageNamed:"))
        ? r_msg2_main(UIImage, "systemImageNamed:", xName, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(xName)) r_msg2_main(xName, "release", 0, 0, 0, 0);
    if (r_is_objc_ptr(xImg)) {
        r_msg2_main(btn, "setImage:forState:", xImg, 0, 0, 0);
    } else {
        uint64_t fallback = r_nsstr_retained("✕"); // ✕
        if (r_is_objc_ptr(fallback)) {
            r_msg2_main(btn, "setTitle:forState:", fallback, 0, 0, 0);
            r_msg2_main(fallback, "release", 0, 0, 0, 0);
        }
    }

    // Tap chain: dim the content behind the floating window first, then hide
    // the slot. The control loop tears it down and fades the shield out.
    uint64_t shield = stagestrip_transition_shield_window();
    if (r_is_objc_ptr(shield)) {
        stagestrip_add_invocation_action(btn,
            stagestrip_make_bool_invocation(shield, "setHidden:", false));
        stagestrip_add_invocation_action(btn,
            stagestrip_make_double_invocation(shield, "setAlpha:", kStripTransitionShieldAlpha));
    }
    if (r_is_objc_ptr(hostView)) {
        stagestrip_add_invocation_action(btn,
            stagestrip_make_int_invocation(hostView, "setHidden:", 1));
    }
    stagestrip_add_invocation_action(btn,
        stagestrip_make_int_invocation(win, "setHidden:", 1));

    r_msg2_main(win, "addSubview:", btn, 0, 0, 0);
    r_msg2_main(win, "bringSubviewToFront:", btn, 0, 0, 0);
    S->closeButton = btn;
    printf("[STAGE] close[%d]: installed btn=0x%llx at (%.0f,%.0f %.0fx%.0f)\n",
           slot, btn, btnX, btnY, btnSize, btnSize);
}

// Tear down a closed slot. Called from the control loop when a slot's window
// is observed in the hidden state.
static void stagestrip_teardown_slot(int slot)
{
    if (slot < 0 || slot >= kStripMaxFloatSlots) return;
    StripFloatSlot *S = &gStripFloatSlots[slot];
    if (!r_is_objc_ptr(S->window) && !r_is_objc_ptr(S->hostView)) return;
    printf("[STAGE] teardown[%d]: closing slot win=0x%llx host=0x%llx\n",
           slot, S->window, S->hostView);
    stagestrip_show_transition_shield(kStripTransitionShieldAlpha);
    if (r_is_objc_ptr(S->hostView)) {
        r_msg2_main(S->hostView, "setHidden:", 1, 0, 0, 0);
        r_msg2_main(S->hostView, "removeFromSuperview", 0, 0, 0, 0);
    }
    if (r_is_objc_ptr(S->window)) {
        r_msg2_main(S->window, "setHidden:", 1, 0, 0, 0);
    }
    S->window = 0;
    S->hostView = 0;
    S->moveHandle = 0;
    S->resizeHandle = 0;
    S->movePan = 0;
    S->resizePan = 0;
    S->referenceView = 0;
    S->closeButton = 0;
    S->pickerSwipe = 0;
    S->pickerSwipePanel = 0;
    for (int c = 0; c < kStripCornerCount; c++) {
        S->cornerHandles[c] = 0;
        S->cornerPans[c] = 0;
        S->cornerArcs[c] = 0;
    }
    S->cornerArcsVisible = false;
    stagestrip_hide_transition_shield_after(kStripTransitionShieldCloseHold);
}

// Build one row in the picker's app list. The row binds two NSInvocations to
// each "Top" / "Bottom" button: one updates the hidden bid label (read by
// Cyanide on Apply), one updates the visible chip text+icon so the user can
// see their pick. The buttons never reach into Cyanide directly — Apply does.
// One horizontal app tile (icon left, name right) — matches the StageDuo
// picker layout from the iDB article. Whole tile is a tappable UIButton
// (Custom type so subview layout isn't overridden by system-button styling).
// Single tap stores the bid in the pending hidden label and sets the panel
// tag to kStripPickerCmdIconTap; Cyanide reads both on poll.
static void stagestrip_install_picker_app_tile(uint64_t container,
                                               uint64_t commandPanel,
                                               const char *bid,
                                               const char *displayNameOpt,
                                               double tileX,
                                               double tileY,
                                               double tileW,
                                               double tileH,
                                               double iconSize,
                                               uint64_t pendingBidLabel)
{
    if (!r_is_objc_ptr(container) || !bid || !*bid) return;
    if (!r_is_objc_ptr(commandPanel)) commandPanel = container;

    char shortName[64] = {0};
    const char *display = NULL;
    if (displayNameOpt && *displayNameOpt) {
        display = displayNameOpt;
    } else {
        stagestrip_bid_short_name(bid, shortName, sizeof(shortName));
        display = shortName[0] ? shortName : bid;
    }

    // Custom UIButton so subviews aren't tinted/template-masked by
    // UIButtonTypeSystem. Falls back gracefully if class missing.
    if (!gStripPickerBuildUIButton)
        gStripPickerBuildUIButton = r_class("UIButton");
    uint64_t tile = r_is_objc_ptr(gStripPickerBuildUIButton)
        ? r_msg2_main(gStripPickerBuildUIButton, "buttonWithType:", 0 /* Custom */, 0, 0, 0)
        : 0;
    if (!r_is_objc_ptr(tile)) return;

    stagestrip_set_frame_fast(tile, (StripRect){ tileX, tileY, tileW, tileH });
    stagestrip_set_background_white(tile, 1.0, 0.08);
    r_msg2_main(tile, "setClipsToBounds:", 1, 0, 0, 0);

    uint64_t btnLayer = r_msg2_main(tile, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(btnLayer)) {
        stagestrip_send_double(btnLayer, "setCornerRadius:", 12.0);
        stagestrip_picker_apply_continuous_curve(btnLayer);
        r_msg2_main(btnLayer, "setMasksToBounds:", 1, 0, 0, 0);
    }

    // Icon — on the LEFT (StageDuo-style horizontal tile).
    double iconX = 10.0;
    double iconY = (tileH - iconSize) / 2.0;
    uint64_t iconImage = stagestrip_fetch_icon_image(bid);
    if (r_is_objc_ptr(iconImage)) {
        if (!gStripPickerBuildUIImageView)
            gStripPickerBuildUIImageView = r_class("UIImageView");
        uint64_t ivAlloc = r_is_objc_ptr(gStripPickerBuildUIImageView)
            ? r_msg2_main(gStripPickerBuildUIImageView, "alloc", 0, 0, 0, 0) : 0;
        uint64_t iv = r_is_objc_ptr(ivAlloc)
            ? r_msg2_main(ivAlloc, "init", 0, 0, 0, 0) : 0;
        if (r_is_objc_ptr(iv)) {
            stagestrip_set_frame_fast(iv, (StripRect){ iconX, iconY, iconSize, iconSize });
            r_msg2_main(iv, "setContentMode:", 1, 0, 0, 0);
            r_msg2_main(iv, "setImage:", iconImage, 0, 0, 0);
            r_msg2_main(iv, "setUserInteractionEnabled:", 0, 0, 0, 0);
            uint64_t layer = r_msg2_main(iv, "layer", 0, 0, 0, 0);
            if (r_is_objc_ptr(layer)) {
                stagestrip_send_double(layer, "setCornerRadius:", iconSize * 0.22);
                stagestrip_picker_apply_continuous_curve(layer);
                r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
            }
            r_msg2_main(tile, "addSubview:", iv, 0, 0, 0);
        }
    } else {
        // Icon fetch failed → render a coloured letter placeholder so the
        // user still has a visual cue for which app this tile represents.
        uint64_t placeholder = stagestrip_make_letter_placeholder(bid, iconSize);
        if (r_is_objc_ptr(placeholder)) {
            stagestrip_set_frame_fast(placeholder,
                                      (StripRect){ iconX, iconY, iconSize, iconSize });
            r_msg2_main(tile, "addSubview:", placeholder, 0, 0, 0);
        }
    }

    // Name label on the RIGHT, vertically centered.
    double labelX = iconX + iconSize + 12.0;
    double labelW = tileW - labelX - 8.0;
    if (labelW < 40.0) labelW = 40.0;
    uint64_t name = stagestrip_make_text_label(display,
                                                labelX,
                                                (tileH - 22.0) / 2.0,
                                                labelW,
                                                22.0);
    if (r_is_objc_ptr(name)) {
        stagestrip_set_background_white(name, 0.0, 0.0);
        r_msg2_main(name, "setUserInteractionEnabled:", 0, 0, 0, 0);
        r_msg2_main(tile, "addSubview:", name, 0, 0, 0);
    }

    // Tap → pending bid then tag. Cyanide's poll consumes both.
    uint64_t bidStr = r_nsstr_retained(bid);
    if (r_is_objc_ptr(bidStr)) {
        if (r_is_objc_ptr(pendingBidLabel))
            stagestrip_add_invocation_action(tile,
                stagestrip_make_object_invocation(pendingBidLabel, "setText:", bidStr));
        stagestrip_add_invocation_action(tile,
            stagestrip_make_int_invocation(commandPanel, "setTag:", kStripPickerCmdIconTap));
        r_msg2_main(bidStr, "release", 0, 0, 0, 0);
    }

    r_msg2_main(container, "addSubview:", tile, 0, 0, 0);
}

// Build a single retained NSArray of "deny" appTag strings inside SpringBoard.
// Returned array is retained — caller releases. Returns 0 on failure.
static uint64_t stagestrip_build_deny_app_tags(void)
{
    static const char *deny[] = {
        "hidden",
        "SBInternalAppTag",
        "system-app-with-no-launch-effect",
        "default-system-app-with-no-launch-effect",
        "no-home-screen",
        "no-home-screen-no-recents",
        NULL,
    };
    uint64_t NSMutableArray = r_class("NSMutableArray");
    if (!r_is_objc_ptr(NSMutableArray)) return 0;
    uint64_t arr = r_msg2_main(NSMutableArray, "array", 0, 0, 0, 0);
    if (!r_is_objc_ptr(arr)) return 0;
    r_msg2_main(arr, "retain", 0, 0, 0, 0);
    for (int i = 0; deny[i]; i++) {
        uint64_t s = r_nsstr_retained(deny[i]);
        if (!r_is_objc_ptr(s)) continue;
        r_msg2_main(arr, "addObject:", s, 0, 0, 0);
        r_msg2_main(s, "release", 0, 0, 0, 0);
    }
    return arr;
}

// Enumerate every home-screen-visible installed app via LSApplicationWorkspace,
// capturing the bundle id AND localized display name in parallel arrays. Apps
// flagged with any deny appTag (hidden / SBInternalAppTag / no-home-screen /
// system-app-with-no-launch-effect / etc.) or with launchProhibited=YES are
// dropped — this filters out the system service angels (BacklinkIndicator,
// AccountAuthenticationDialog, etc.) that LSApplicationWorkspace returns
// alongside actual home-screen apps. Output is written into `bidOut`/`nameOut`
// at index `start` and beyond, deduped against entries already in `bidOut`.
// Returns the number of new rows written.
static int stagestrip_collect_all_installed_apps(char bidOut[][128],
                                                 char nameOut[][96],
                                                 int start,
                                                 int maxOut)
{
    if (!bidOut || !nameOut || start >= maxOut) return 0;

    uint64_t LSCls = r_class("LSApplicationWorkspace");
    if (!r_is_objc_ptr(LSCls) || !r_responds(LSCls, "defaultWorkspace")) {
        printf("[STAGE] picker: LSApplicationWorkspace unavailable\n");
        return 0;
    }
    uint64_t ws = r_msg2_main(LSCls, "defaultWorkspace", 0, 0, 0, 0);
    if (!r_is_objc_ptr(ws) || !r_responds(ws, "allApplications")) {
        printf("[STAGE] picker: LSApplicationWorkspace.allApplications missing\n");
        return 0;
    }
    uint64_t apps = r_msg2_main(ws, "allApplications", 0, 0, 0, 0);
    if (!r_is_objc_ptr(apps)) return 0;
    uint64_t count = r_msg2_main(apps, "count", 0, 0, 0, 0);
    if (count == 0 || count > 2048) {
        printf("[STAGE] picker: implausible installed-apps count=%llu\n", count);
        return 0;
    }

    uint64_t enumT0 = stagestrip_now_ms();
    uint64_t denyTags = stagestrip_build_deny_app_tags();

    // r_responds returns class-level info that's constant for every LSApplicationProxy.
    // Resolve it ONCE against the first proxy then reuse — saves 6 r_responds calls per
    // iteration (over 270+ apps that's ~1600 round-trips, ~50s at 30ms each).
    bool respAppType = false, respLaunchProhibited = false, respAppTags = false;
    bool respBundleId = false, respLocalizedName = false, respLocalizedShortName = false;
    {
        uint64_t firstProxy = (count > 0)
            ? r_msg2_main(apps, "objectAtIndex:", 0, 0, 0, 0) : 0;
        if (r_is_objc_ptr(firstProxy)) {
            respAppType            = r_responds(firstProxy, "applicationType");
            respLaunchProhibited   = r_responds(firstProxy, "launchProhibited");
            respAppTags            = r_responds(firstProxy, "appTags");
            respBundleId           = r_responds(firstProxy, "bundleIdentifier");
            respLocalizedName      = r_responds(firstProxy, "localizedName");
            respLocalizedShortName = r_responds(firstProxy, "localizedShortName");
        }
    }
    printf("[STAGE] enum: deny-tag array built in %llums; walking %llu proxies (responds cached: appType=%d launch=%d tags=%d bid=%d locName=%d locShort=%d)\n",
           stagestrip_now_ms() - enumT0, count,
           respAppType, respLaunchProhibited, respAppTags,
           respBundleId, respLocalizedName, respLocalizedShortName);

    int written = 0;
    int taggedOut = 0;
    int prohibitedOut = 0;
    int typeFilteredOut = 0;
    for (uint64_t i = 0; i < count && (start + written) < maxOut; i++) {
        if (i > 0 && (i % 10) == 0) {
            uint64_t elapsed = stagestrip_now_ms() - enumT0;
            if (elapsed > kStripPickerEnumHardBudgetMS) {
                printf("[STAGE] enum: budget stop %llu/%llu kept=%d tagged=%d prohibited=%d typeFiltered=%d (+%llums)\n",
                       i, count, written, taggedOut, prohibitedOut, typeFilteredOut, elapsed);
                break;
            }
        }
        if (i > 0 && (i % 50) == 0) {
            printf("[STAGE] enum: progress %llu/%llu kept=%d tagged=%d prohibited=%d typeFiltered=%d (+%llums)\n",
                   i, count, written, taggedOut, prohibitedOut, typeFilteredOut,
                   stagestrip_now_ms() - enumT0);
        }
        uint64_t proxy = r_msg2_main(apps, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(proxy)) continue;

        // Filter 1: applicationType must be User or System.
        if (respAppType) {
            uint64_t typeObj = r_msg2_main(proxy, "applicationType", 0, 0, 0, 0);
            char typeBuf[32] = {0};
            if (r_is_objc_ptr(typeObj)) {
                uint64_t cstr = r_msg2_main(typeObj, "UTF8String", 0, 0, 0, 0);
                if (cstr) stagestrip_read_remote_cstr(cstr, typeBuf, sizeof(typeBuf));
            }
            if (typeBuf[0] && strcmp(typeBuf, "User") != 0 && strcmp(typeBuf, "System") != 0) {
                typeFilteredOut++;
                continue;
            }
        }

        // Filter 2: launchProhibited == YES → system-only app, not home-screen.
        if (respLaunchProhibited) {
            uint64_t prohibited = r_msg2_main(proxy, "launchProhibited", 0, 0, 0, 0);
            if (prohibited) { prohibitedOut++; continue; }
        }

        // Filter 3: any deny appTag → daemon / helper / internal service.
        if (r_is_objc_ptr(denyTags) && respAppTags) {
            uint64_t tags = r_msg2_main(proxy, "appTags", 0, 0, 0, 0);
            if (r_is_objc_ptr(tags)) {
                uint64_t hit = r_msg2_main(tags, "firstObjectCommonWithArray:",
                                           denyTags, 0, 0, 0);
                if (r_is_objc_ptr(hit)) { taggedOut++; continue; }
            }
        }

        uint64_t bidObj = respBundleId
            ? r_msg2_main(proxy, "bundleIdentifier", 0, 0, 0, 0) : 0;
        if (!r_is_objc_ptr(bidObj)) continue;
        uint64_t cstr = r_msg2_main(bidObj, "UTF8String", 0, 0, 0, 0);
        if (!cstr) continue;

        char bid[128] = {0};
        if (!stagestrip_read_remote_cstr(cstr, bid, sizeof(bid))) continue;
        if (!stagestrip_bid_is_user_app(bid)) continue;

        bool dup = false;
        for (int k = 0; k < start + written; k++) {
            if (strcmp(bidOut[k], bid) == 0) { dup = true; break; }
        }
        if (dup) continue;

        // Pull the proper localized display name. Falls back to localizedShortName
        // (CarPlay/Springboard alternate), then to the bid short-name if both miss.
        char name[96] = {0};
        uint64_t nameObj = 0;
        if (respLocalizedName)
            nameObj = r_msg2_main(proxy, "localizedName", 0, 0, 0, 0);
        if (!r_is_objc_ptr(nameObj) && respLocalizedShortName)
            nameObj = r_msg2_main(proxy, "localizedShortName", 0, 0, 0, 0);
        if (r_is_objc_ptr(nameObj)) {
            uint64_t nameCstr = r_msg2_main(nameObj, "UTF8String", 0, 0, 0, 0);
            if (nameCstr) stagestrip_read_remote_cstr(nameCstr, name, sizeof(name));
        }
        if (!name[0]) {
            // Fall back to bid-derived short name.
            stagestrip_bid_short_name(bid, name, sizeof(name));
        }

        strncpy(bidOut[start + written], bid, 127);
        bidOut[start + written][127] = '\0';
        strncpy(nameOut[start + written], name, sizeof(nameOut[start + written]) - 1);
        nameOut[start + written][sizeof(nameOut[start + written]) - 1] = '\0';
        written++;
    }

    if (r_is_objc_ptr(denyTags)) r_msg2_main(denyTags, "release", 0, 0, 0, 0);

    printf("[STAGE] enum: done kept=%d / %llu (tagged=%d prohibited=%d typeFiltered=%d) in %llums\n",
           written, count, taggedOut, prohibitedOut, typeFilteredOut,
           stagestrip_now_ms() - enumT0);
    return written;
}

// Look up a single bundle id's localized display name via LSApplicationProxy.
// Writes into `out` (truncated to outLen-1). Returns true on success.
static bool stagestrip_lookup_app_localized_name(const char *bid,
                                                  char *out,
                                                  size_t outLen)
{
    if (!bid || !*bid || !out || outLen < 2) return false;
    out[0] = '\0';

    uint64_t LSCls = r_class("LSApplicationProxy");
    if (!r_is_objc_ptr(LSCls)) return false;
    uint64_t bidStr = r_cfstr(bid);
    if (!bidStr) return false;
    uint64_t proxy = 0;
    if (r_responds(LSCls, "applicationProxyForIdentifier:")) {
        proxy = r_msg2_main(LSCls, "applicationProxyForIdentifier:", bidStr, 0, 0, 0);
    }
    if (!r_is_objc_ptr(proxy)) return false;
    uint64_t nameObj = 0;
    if (r_responds(proxy, "localizedName"))
        nameObj = r_msg2_main(proxy, "localizedName", 0, 0, 0, 0);
    if (!r_is_objc_ptr(nameObj) && r_responds(proxy, "localizedShortName"))
        nameObj = r_msg2_main(proxy, "localizedShortName", 0, 0, 0, 0);
    if (!r_is_objc_ptr(nameObj)) return false;
    uint64_t cstr = r_msg2_main(nameObj, "UTF8String", 0, 0, 0, 0);
    if (!cstr) return false;
    return stagestrip_read_remote_cstr(cstr, out, outLen);
}

// Process-local cache of the App Library section. The enumerator is the slow
// part (~272 LSApplicationProxy walks per build); the list rarely changes
// within a single Cyanide session, so we cache it after the first build and
// reuse it on every subsequent picker construction. Recents are still
// re-fetched every time so the top section stays current.
#define kStripPickerCacheMax 256
static char gStripPickerCacheLibBids[kStripPickerCacheMax][128];
static char gStripPickerCacheLibNames[kStripPickerCacheMax][96];
static int gStripPickerCacheLibCount = 0;
static uint64_t gStripPickerCacheLibBuiltAtMs = 0;

void stagestrip_invalidate_picker_cache(void)
{
    gStripPickerCacheLibCount = 0;
    gStripPickerCacheLibBuiltAtMs = 0;
}

static int stagestrip_collect_picker_bids(char bidOut[][128],
                                          char nameOut[][96],
                                          int maxOut)
{
    if (!bidOut || !nameOut || maxOut <= 0) return 0;
    int written = 0;
    uint64_t collectT0 = stagestrip_now_ms();

    // Section 1: recents (most-recent first; these go in the prominent grid).
    char recents[8][128];
    int rc = stagestrip_collect_recent_bids(recents, 8);
    printf("[STAGE] collect: recents-bids=%d (+%llums)\n",
           rc, stagestrip_now_ms() - collectT0);
    uint64_t recentsNameT0 = stagestrip_now_ms();
    for (int i = 0; i < rc && written < maxOut; i++) {
        bool dup = false;
        for (int k = 0; k < written; k++)
            if (strcmp(bidOut[k], recents[i]) == 0) { dup = true; break; }
        if (dup) continue;
        strncpy(bidOut[written], recents[i], 127);
        bidOut[written][127] = '\0';
        // Look up the proper localized name for each recent bid.
        char recentName[96] = {0};
        bool ok = stagestrip_lookup_app_localized_name(recents[i], recentName, sizeof(recentName));
        if (!ok || !recentName[0]) {
            stagestrip_bid_short_name(recents[i], recentName, sizeof(recentName));
            printf("[STAGE] recents-name[%d]: %s -> %s (fallback short-name)\n",
                   written, recents[i], recentName);
        } else {
            printf("[STAGE] recents-name[%d]: %s -> %s\n",
                   written, recents[i], recentName);
        }
        strncpy(nameOut[written], recentName, sizeof(nameOut[written]) - 1);
        nameOut[written][sizeof(nameOut[written]) - 1] = '\0';
        written++;
    }
    printf("[STAGE] collect: recents-names done in %llums\n",
           stagestrip_now_ms() - recentsNameT0);

    int recentsCount = written;

    // Section 2: every home-screen-visible installed app. If the App Library
    // cache is populated, hydrate from it (filtered against the recents we
    // already wrote so we don't double-add). Otherwise walk LSApplicationWorkspace
    // and stash the result.
    int addedFromInstalled = 0;
    if (gStripPickerCacheLibCount > 0) {
        uint64_t hydT0 = stagestrip_now_ms();
        for (int i = 0; i < gStripPickerCacheLibCount && written < maxOut; i++) {
            const char *cb = gStripPickerCacheLibBids[i];
            bool dup = false;
            for (int k = 0; k < written; k++)
                if (strcmp(bidOut[k], cb) == 0) { dup = true; break; }
            if (dup) continue;
            strncpy(bidOut[written], cb, 127);
            bidOut[written][127] = '\0';
            strncpy(nameOut[written], gStripPickerCacheLibNames[i],
                    sizeof(nameOut[written]) - 1);
            nameOut[written][sizeof(nameOut[written]) - 1] = '\0';
            written++;
            addedFromInstalled++;
        }
        printf("[STAGE] collect: cache HIT lib=%d age=%llums hydrated in %llums\n",
               gStripPickerCacheLibCount,
               stagestrip_now_ms() - gStripPickerCacheLibBuiltAtMs,
               stagestrip_now_ms() - hydT0);
    } else {
        uint64_t enumT0 = stagestrip_now_ms();
        printf("[STAGE] collect: cache MISS — running enumerator (+%llums)\n",
               enumT0 - collectT0);
        addedFromInstalled = stagestrip_collect_all_installed_apps(bidOut, nameOut,
                                                                   written, maxOut);
        printf("[STAGE] collect: enumerator done +%d in %llums\n",
               addedFromInstalled, stagestrip_now_ms() - enumT0);

        // Stash the enumerator results into the cache — only the lib slice,
        // not recents (those change every session).
        int cacheN = addedFromInstalled;
        if (cacheN > kStripPickerCacheMax) cacheN = kStripPickerCacheMax;
        for (int i = 0; i < cacheN; i++) {
            strncpy(gStripPickerCacheLibBids[i], bidOut[written + i], 127);
            gStripPickerCacheLibBids[i][127] = '\0';
            strncpy(gStripPickerCacheLibNames[i], nameOut[written + i],
                    sizeof(gStripPickerCacheLibNames[i]) - 1);
            gStripPickerCacheLibNames[i][sizeof(gStripPickerCacheLibNames[i]) - 1] = '\0';
        }
        gStripPickerCacheLibCount = cacheN;
        gStripPickerCacheLibBuiltAtMs = stagestrip_now_ms();
        printf("[STAGE] collect: cache stored lib=%d\n", cacheN);
        written += addedFromInstalled;
    }

    // Fallback: if the workspace path failed, drop in running apps so we still
    // have something to show.
    if (addedFromInstalled == 0 && written < maxOut) {
        StripAppEntry running[20];
        int n = stagestrip_collect_apps(running, 20);
        for (int i = 0; i < n && written < maxOut; i++) {
            bool dup = false;
            for (int k = 0; k < written; k++)
                if (strcmp(bidOut[k], running[i].bid) == 0) { dup = true; break; }
            if (dup) continue;
            strncpy(bidOut[written], running[i].bid, 127);
            bidOut[written][127] = '\0';
            char runName[96] = {0};
            if (!stagestrip_lookup_app_localized_name(running[i].bid, runName, sizeof(runName))
                || !runName[0]) {
                stagestrip_bid_short_name(running[i].bid, runName, sizeof(runName));
            }
            strncpy(nameOut[written], runName, sizeof(nameOut[written]) - 1);
            nameOut[written][sizeof(nameOut[written]) - 1] = '\0';
            written++;
        }
    }

    // Sort the App Library section (entries [recentsCount..written)) by display
    // name so the user sees alphabetised tiles below the recents.
    uint64_t sortT0 = stagestrip_now_ms();
    if (written > recentsCount + 1) {
        int libStart = recentsCount;
        int libEnd = written;
        for (int i = libStart; i < libEnd - 1; i++) {
            for (int j = libStart; j < libEnd - 1 - (i - libStart); j++) {
                if (strcasecmp(nameOut[j], nameOut[j + 1]) > 0) {
                    char tmpBid[128];
                    char tmpName[96];
                    memcpy(tmpBid, bidOut[j], sizeof(tmpBid));
                    memcpy(tmpName, nameOut[j], sizeof(tmpName));
                    memcpy(bidOut[j], bidOut[j + 1], sizeof(tmpBid));
                    memcpy(nameOut[j], nameOut[j + 1], sizeof(tmpName));
                    memcpy(bidOut[j + 1], tmpBid, sizeof(tmpBid));
                    memcpy(nameOut[j + 1], tmpName, sizeof(tmpName));
                }
            }
        }
    }
    printf("[STAGE] collect: sort done (lib=%d) in %llums; total collect=%llums\n",
           written - recentsCount,
           stagestrip_now_ms() - sortT0,
           stagestrip_now_ms() - collectT0);
    return written;
}

// Deferred App Library tile build. We cannot use dispatch_async to a fresh
// worker thread — RemoteCall's shmem mapping is per-thread (it's set up the
// first time a thread invokes the framework, and a brand-new worker that
// has never made a RemoteCall doesn't have the mapping). The previous attempt
// crashed with `vm_map_remote_page: Failed to get VM object`.
//
// Instead, we stash the build context here and let the control loop's
// background thread pick it up one tile per tick. The control loop already
// holds the RemoteCall context for its dispatch_async lifetime, so the calls
// succeed. The trade-off: while the library is filling in, each control-loop
// tick blocks for ~1.5s installing one tile, which means gesture polling is
// slower during the build. Acceptable for first install / cache-cold case.
typedef struct {
    uint64_t scrollView;
    char     bids[256][128];
    char     names[256][96];
    int      count;
    int      index;            // next tile to install
    double   sideMargin;
    double   tileW;
    double   tileH;
    double   iconSize;
    double   rowGap;
    uint64_t pickerT0;
    uint64_t pendingBidLabel;
    uint64_t startedAtMs;      // 0 = not started yet
    uint64_t notBeforeMs;
    uint64_t lastTileAtMs;
} StripLibraryBuildCtx;

static StripLibraryBuildCtx gStripLibraryBuild;
static volatile int gStripLibraryBuildPending = 0;  // 1 = control loop should install more tiles
static volatile int gStripDeferredLibraryBuildEnabled = 1;

void stagestrip_set_deferred_library_build_enabled(bool enabled)
{
    gStripDeferredLibraryBuildEnabled = enabled ? 1 : 0;
    if (!enabled) {
        gStripLibraryBuildPending = 0;
    }
    printf("[STAGE] picker: deferred library build %s\n",
           enabled ? "enabled" : "disabled");
}

static void stagestrip_schedule_library_tile_build(uint64_t scrollView,
                                                    char (*libBids)[128],
                                                    char (*libNames)[96],
                                                    int libCount,
                                                    double sideMargin,
                                                    double tileW,
                                                    double tileH,
                                                    double iconSize,
                                                    double rowGap,
                                                    uint64_t pickerT0)
{
    if (!gStripDeferredLibraryBuildEnabled) {
        gStripLibraryBuildPending = 0;
        printf("[STAGE] picker: deferred library build skipped count=%d (compat mode)\n",
               libCount);
        return;
    }

    StripLibraryBuildCtx *ctx = &gStripLibraryBuild;
    ctx->scrollView = scrollView;
    int n = libCount < 256 ? libCount : 256;
    for (int i = 0; i < n; i++) {
        strncpy(ctx->bids[i],  libBids[i],  127); ctx->bids[i][127]  = '\0';
        strncpy(ctx->names[i], libNames[i], 95);  ctx->names[i][95]  = '\0';
    }
    ctx->count           = n;
    ctx->index           = 0;
    ctx->sideMargin      = sideMargin;
    ctx->tileW           = tileW;
    ctx->tileH           = tileH;
    ctx->iconSize        = iconSize;
    ctx->rowGap          = rowGap;
    ctx->pickerT0        = pickerT0;
    ctx->pendingBidLabel = gStripPickerPendingBidLabel;
    ctx->startedAtMs     = 0;
    ctx->notBeforeMs     = stagestrip_now_ms() + kStripPickerLibraryBuildDelayMS;
    ctx->lastTileAtMs    = 0;
    __sync_synchronize();
    gStripLibraryBuildPending = 1;
    printf("[STAGE] picker: library build pending count=%d (control loop will install after %llums)\n",
           n, kStripPickerLibraryBuildDelayMS);
}

// Called by the control loop each tick. Installs one tile per call, so the
// gesture poll stays responsive between tiles. Returns true if it did work.
static bool stagestrip_control_loop_progress_library_build(void)
{
    if (!gStripLibraryBuildPending) return false;
    StripLibraryBuildCtx *c = &gStripLibraryBuild;
    uint64_t now = stagestrip_now_ms();
    if (now < c->notBeforeMs) return false;
    if (c->lastTileAtMs && now - c->lastTileAtMs < kStripPickerLibraryTileIntervalMS) return false;
    if (c->index >= c->count || !r_is_objc_ptr(c->scrollView)) {
        if (gStripLibraryBuildPending) {
            printf("[STAGE] picker: deferred library build done in %llums (installed=%d)\n",
                   c->startedAtMs ? (stagestrip_now_ms() - c->startedAtMs) : 0,
                   c->index);
            gStripLibraryBuildPending = 0;
        }
        return false;
    }
    if (c->startedAtMs == 0) {
        c->startedAtMs = now;
        printf("[STAGE] picker: control-loop library build start count=%d (deferred by %llums)\n",
               c->count, c->startedAtMs - c->pickerT0);
    }
    int i = c->index;
    stagestrip_install_picker_app_tile(c->scrollView,
                                        gStripPickerPanel,
                                        c->bids[i],
                                        c->names[i],
                                        c->sideMargin,
                                        (double)i * (c->tileH + c->rowGap),
                                        c->tileW,
                                        c->tileH,
                                        c->iconSize,
                                        c->pendingBidLabel);
    c->index++;
    c->lastTileAtMs = stagestrip_now_ms();
    if ((c->index % 10) == 0 || c->index == c->count) {
        printf("[STAGE] picker: control-loop library-tiles %d/%d (+%llums)\n",
               c->index, c->count, stagestrip_now_ms() - c->startedAtMs);
    }
    return true;
}

// Build the picker UI as its own UIWindow above the float window. The picker
// is hidden until the hot-corner gesture summons it. All user picks happen
// inside SpringBoard via NSInvocations; Cyanide only ever reads
// -[panel tag] (one remote call) and, when non-zero, the two hidden bid
// labels (5 remote calls each, only on Apply).
static uint64_t stagestrip_install_picker_overlay(uint64_t app,
                                                  uint64_t windowScene,
                                                  double sw,
                                                  double sh)
{
    if (!r_is_objc_ptr(app) || !r_is_objc_ptr(windowScene)) return 0;
    uint64_t pickerT0 = stagestrip_now_ms();
    printf("[STAGE] picker: install begin sw=%.0f sh=%.0f t0=%llums\n", sw, sh, pickerT0);
    stagestrip_picker_build_cache_reset();

    // Pull a previously-cached overlay window forward — if a respring left one
    // around, we don't want to stack a second one on top.
    uint64_t cacheKey = r_sel("cyanideStageStripPickerWindow");
    uint64_t cached = cacheKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                       app, cacheKey, 0, 0, 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(cached)) {
        r_msg2_main(cached, "setHidden:", 1, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     app, cacheKey, 0, 1 /* RETAIN_NONATOMIC */, 0, 0, 0, 0);
        printf("[STAGE] picker: discarded cached window=0x%llx\n", cached);
    }

    uint64_t UIWindow = r_class("UIWindow");
    uint64_t winAlloc = r_is_objc_ptr(UIWindow)
        ? r_msg2_main(UIWindow, "alloc", 0, 0, 0, 0) : 0;
    uint64_t overlayWin = r_is_objc_ptr(winAlloc)
        ? r_msg2_main(winAlloc, "initWithWindowScene:", windowScene, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(overlayWin)) {
        printf("[STAGE] picker: UIWindow init failed\n");
        return 0;
    }
    stagestrip_set_frame_fast(overlayWin, (StripRect){ 0.0, 0.0, sw, sh });
    stagestrip_send_double(overlayWin, "setWindowLevel:", kStripWindowLevel + 2.0);
    stagestrip_set_background_white(overlayWin, 0.0, 0.55);
    if (r_responds(overlayWin, "setOpaque:"))
        r_msg2_main(overlayWin, "setOpaque:", 0, 0, 0, 0);
    r_msg2_main(overlayWin, "setHidden:", 1, 0, 0, 0);
    r_msg2_main(overlayWin, "setUserInteractionEnabled:", 1, 0, 0, 0);

    // Panel — bottom-anchored tray (like StageDuo's pull-up sheet). Full-ish
    // width, sits flush above the bottom edge. -tag carries the command
    // sentinel. (Was previously a centered card.)
    double panelW = sw - 24.0;
    if (panelW > 460.0) panelW = 460.0;
    double panelH = sh * 0.62;
    if (panelH < 460.0) panelH = 460.0;
    if (panelH > sh - 96.0) panelH = sh - 96.0;
    double panelX = (sw - panelW) / 2.0;
    double panelY = sh - panelH - 24.0;
    if (panelY < 48.0) panelY = 48.0;

    uint64_t UIView = r_class("UIView");
    uint64_t panelAlloc = r_is_objc_ptr(UIView)
        ? r_msg2_main(UIView, "alloc", 0, 0, 0, 0) : 0;
    uint64_t panel = r_is_objc_ptr(panelAlloc)
        ? r_msg2_main(panelAlloc, "init", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(panel)) {
        printf("[STAGE] picker: panel init failed\n");
        r_msg2_main(overlayWin, "setHidden:", 1, 0, 0, 0);
        return 0;
    }
    stagestrip_set_frame_fast(panel, (StripRect){ panelX, panelY, panelW, panelH });
    r_msg2_main(panel, "setUserInteractionEnabled:", 1, 0, 0, 0);
    r_msg2_main(panel, "setClipsToBounds:", 1, 0, 0, 0);
    stagestrip_set_background_white(panel, 0.07, 0.96);
    stagestrip_set_layer_border_white(panel, 1.0, 0.16, 1.0);
    uint64_t panelLayer = r_msg2_main(panel, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(panelLayer)) {
        stagestrip_send_double(panelLayer, "setCornerRadius:", 18.0);
        if (r_responds(panelLayer, "setCornerCurve:")) {
            uint64_t cont = r_nsstr_retained("continuous");
            if (r_is_objc_ptr(cont)) {
                r_msg2_main(panelLayer, "setCornerCurve:", cont, 0, 0, 0);
                r_msg2_main(cont, "release", 0, 0, 0, 0);
            }
        }
        r_msg2_main(panelLayer, "setMasksToBounds:", 1, 0, 0, 0);
    }
    r_msg2_main(panel, "setTag:", 0, 0, 0, 0);
    r_msg2_main(overlayWin, "addSubview:", panel, 0, 0, 0);
    gStripPickerPanel = panel;

    // --- Title row. Title on the left, gear + close on the right.
    uint64_t title = stagestrip_make_text_label("Dynamic Stage Lite", 14.0, 12.0, panelW - 96.0, 28.0);
    if (r_is_objc_ptr(title)) {
        stagestrip_set_background_white(title, 0.0, 0.0);
        r_msg2_main(panel, "addSubview:", title, 0, 0, 0);
    }

    // Settings gear — taps trigger a SpringBoard respring (mirrors the
    // settings-app Respring button via FBSystemService).
    uint64_t cog = stagestrip_make_control_button("", panelW - 80.0, 12.0, 30.0, 28.0);
    if (r_is_objc_ptr(cog)) {
        // Drop the system button's faint background so it reads as an icon-only.
        stagestrip_set_background_white(cog, 0.0, 0.0);

        uint64_t UIImage = r_class("UIImage");
        uint64_t gearName = r_nsstr_retained("gearshape");
        uint64_t gearImg = (r_is_objc_ptr(UIImage) &&
                            r_responds(UIImage, "systemImageNamed:") &&
                            r_is_objc_ptr(gearName))
            ? r_msg2_main(UIImage, "systemImageNamed:", gearName, 0, 0, 0)
            : 0;
        if (r_is_objc_ptr(gearName)) r_msg2_main(gearName, "release", 0, 0, 0, 0);
        if (r_is_objc_ptr(gearImg))
            r_msg2_main(cog, "setImage:forState:", gearImg, 0, 0, 0);
        else {
            // SF Symbol not available; fall back to unicode gear glyph.
            uint64_t fallback = r_nsstr_retained("⚙");
            if (r_is_objc_ptr(fallback)) {
                r_msg2_main(cog, "setTitle:forState:", fallback, 0, 0, 0);
                r_msg2_main(fallback, "release", 0, 0, 0, 0);
            }
        }

        stagestrip_add_invocation_action(cog,
            stagestrip_make_int_invocation(panel, "setTag:", kStripPickerCmdRespring));
        r_msg2_main(panel, "addSubview:", cog, 0, 0, 0);
    }

    uint64_t close = stagestrip_make_control_button("x", panelW - 42.0, 12.0, 28.0, 28.0);
    if (r_is_objc_ptr(close)) {
        stagestrip_add_invocation_action(close,
            stagestrip_make_int_invocation(panel, "setTag:", kStripPickerCmdClose));
        r_msg2_main(panel, "addSubview:", close, 0, 0, 0);
    }

    // --- Slot cards (Top + Bottom). Each card is tappable: tapping it sets
    //     the "next slot" pointer in Cyanide so the user can control which
    //     half they're filling without per-row T/B buttons.
    double slotY = 52.0;
    double slotH = 56.0;
    double slotW = panelW - 28.0;
    double iconSide = 38.0;
    int cardCmds[2] = { kStripPickerCmdSelectTop, kStripPickerCmdSelectBot };
    const char *slotPrefix[2] = { "Top", "Bottom" };
    for (int slot = 0; slot < 2; slot++) {
        double y = slotY + (double)slot * (slotH + 8.0);
        uint64_t cardAlloc = r_msg2_main(UIView, "alloc", 0, 0, 0, 0);
        uint64_t card = r_is_objc_ptr(cardAlloc)
            ? r_msg2_main(cardAlloc, "init", 0, 0, 0, 0) : 0;
        if (!r_is_objc_ptr(card)) continue;
        stagestrip_set_frame_fast(card, (StripRect){ 14.0, y, slotW, slotH });
        r_msg2_main(card, "setUserInteractionEnabled:", 1, 0, 0, 0);
        // Slot 0 starts highlighted (it's the default next slot).
        stagestrip_set_background_white(card, 1.0, slot == 0 ? 0.14 : 0.06);
        uint64_t cardLayer = r_msg2_main(card, "layer", 0, 0, 0, 0);
        if (r_is_objc_ptr(cardLayer)) {
            stagestrip_send_double(cardLayer, "setCornerRadius:", 12.0);
            if (r_responds(cardLayer, "setCornerCurve:")) {
                uint64_t cont = r_nsstr_retained("continuous");
                if (r_is_objc_ptr(cont)) {
                    r_msg2_main(cardLayer, "setCornerCurve:", cont, 0, 0, 0);
                    r_msg2_main(cont, "release", 0, 0, 0, 0);
                }
            }
            r_msg2_main(cardLayer, "setMasksToBounds:", 1, 0, 0, 0);
        }

        // Tap gesture on the card → set the "next slot" pointer in Cyanide.
        uint64_t selectInv = stagestrip_make_int_invocation(panel, "setTag:", cardCmds[slot]);
        uint64_t invokeSel = r_sel("invoke");
        uint64_t UITap = r_class("UITapGestureRecognizer");
        uint64_t tapAlloc = r_is_objc_ptr(UITap)
            ? r_msg2_main(UITap, "alloc", 0, 0, 0, 0) : 0;
        uint64_t tap = r_is_objc_ptr(tapAlloc) && r_is_objc_ptr(selectInv) && invokeSel
            ? r_msg2_main(tapAlloc, "initWithTarget:action:", selectInv, invokeSel, 0, 0)
            : 0;
        if (r_is_objc_ptr(tap)) {
            r_msg2_main(card, "addGestureRecognizer:", tap, 0, 0, 0);
            stagestrip_retain_action_target(card, selectInv);
        }

        // Icon UIImageView (tile taps -setImage: into this via Cyanide).
        uint64_t UIImageView = r_class("UIImageView");
        uint64_t iconViewAlloc = r_is_objc_ptr(UIImageView)
            ? r_msg2_main(UIImageView, "alloc", 0, 0, 0, 0) : 0;
        uint64_t iconBox = r_is_objc_ptr(iconViewAlloc)
            ? r_msg2_main(iconViewAlloc, "init", 0, 0, 0, 0) : 0;
        if (r_is_objc_ptr(iconBox)) {
            stagestrip_set_frame_fast(iconBox, (StripRect){ 10.0, (slotH - iconSide) / 2.0, iconSide, iconSide });
            stagestrip_set_background_white(iconBox, 1.0, 0.06);
            uint64_t iboxLayer = r_msg2_main(iconBox, "layer", 0, 0, 0, 0);
            if (r_is_objc_ptr(iboxLayer)) {
                stagestrip_send_double(iboxLayer, "setCornerRadius:", 9.0);
                if (r_responds(iboxLayer, "setCornerCurve:")) {
                    uint64_t cont = r_nsstr_retained("continuous");
                    if (r_is_objc_ptr(cont)) {
                        r_msg2_main(iboxLayer, "setCornerCurve:", cont, 0, 0, 0);
                        r_msg2_main(cont, "release", 0, 0, 0, 0);
                    }
                }
                r_msg2_main(iboxLayer, "setMasksToBounds:", 1, 0, 0, 0);
            }
            r_msg2_main(iconBox, "setUserInteractionEnabled:", 0, 0, 0, 0);
            r_msg2_main(iconBox, "setContentMode:", 1 /* aspectFit */, 0, 0, 0);
            r_msg2_main(card, "addSubview:", iconBox, 0, 0, 0);

            const char *initialBid = (slot == 0) ? gStripPickerTopBid : gStripPickerBottomBid;
            if (initialBid[0]) {
                uint64_t img = stagestrip_fetch_icon_image(initialBid);
                if (r_is_objc_ptr(img))
                    r_msg2_main(iconBox, "setImage:", img, 0, 0, 0);
            }
        }

        // Visible chip label: "Top: <name>" / "Bottom: <name>".
        char chipText[96] = {0};
        const char *initialBidForLabel = (slot == 0) ? gStripPickerTopBid : gStripPickerBottomBid;
        if (initialBidForLabel[0]) {
            char dispName[96] = {0};
            if (!stagestrip_lookup_app_localized_name(initialBidForLabel, dispName, sizeof(dispName))
                || !dispName[0])
                stagestrip_bid_short_name(initialBidForLabel, dispName, sizeof(dispName));
            snprintf(chipText, sizeof(chipText), "%s: %s",
                     slotPrefix[slot],
                     dispName[0] ? dispName : initialBidForLabel);
        } else {
            snprintf(chipText, sizeof(chipText), "%s — tap an app below", slotPrefix[slot]);
        }
        uint64_t chip = stagestrip_make_text_label(chipText,
                                                   iconSide + 24.0,
                                                   (slotH - 28.0) / 2.0,
                                                   slotW - iconSide - 36.0,
                                                   28.0);
        if (r_is_objc_ptr(chip)) {
            stagestrip_set_background_white(chip, 0.0, 0.0);
            // Chip label shouldn't intercept the card's tap gesture.
            r_msg2_main(chip, "setUserInteractionEnabled:", 0, 0, 0, 0);
            r_msg2_main(card, "addSubview:", chip, 0, 0, 0);
        }

        r_msg2_main(panel, "addSubview:", card, 0, 0, 0);

        if (slot == 0) {
            gStripPickerTopChip = chip;
            gStripPickerTopIcon = iconBox;
            gStripPickerTopChipCard = card;
        } else {
            gStripPickerBottomChip = chip;
            gStripPickerBottomIcon = iconBox;
            gStripPickerBottomChipCard = card;
        }
    }
    // Default the "next slot" pointer to top on a fresh install.
    gStripPickerNextSlot = 0;

    // Hidden bid labels — bid storage for Apply.
    uint64_t topHidden = stagestrip_make_text_label(gStripPickerTopBid[0] ? gStripPickerTopBid : "",
                                                    0.0, 0.0, 1.0, 1.0);
    uint64_t botHidden = stagestrip_make_text_label(gStripPickerBottomBid[0] ? gStripPickerBottomBid : "",
                                                    2.0, 0.0, 1.0, 1.0);
    uint64_t pendingHidden = stagestrip_make_text_label("",
                                                        4.0, 0.0, 1.0, 1.0);
    if (r_is_objc_ptr(topHidden)) {
        r_msg2_main(topHidden, "setHidden:", 1, 0, 0, 0);
        r_msg2_main(panel, "addSubview:", topHidden, 0, 0, 0);
        gStripPickerTopLabel = topHidden;
    }
    if (r_is_objc_ptr(botHidden)) {
        r_msg2_main(botHidden, "setHidden:", 1, 0, 0, 0);
        r_msg2_main(panel, "addSubview:", botHidden, 0, 0, 0);
        gStripPickerBottomLabel = botHidden;
    }
    if (r_is_objc_ptr(pendingHidden)) {
        r_msg2_main(pendingHidden, "setHidden:", 1, 0, 0, 0);
        r_msg2_main(panel, "addSubview:", pendingHidden, 0, 0, 0);
        gStripPickerPendingBidLabel = pendingHidden;
    }

    // --- Swap button.
    double swapY = slotY + slotH * 2.0 + 14.0;
    uint64_t swap = stagestrip_make_control_button("Swap top / bottom",
                                                   14.0, swapY,
                                                   panelW - 28.0, 30.0);
    if (r_is_objc_ptr(swap)) {
        stagestrip_add_invocation_action(swap,
            stagestrip_make_int_invocation(panel, "setTag:", kStripPickerCmdSwap));
        r_msg2_main(panel, "addSubview:", swap, 0, 0, 0);
    }

    // Collect candidate apps. Recents are pinned at the top; every other
    // installed app (via LSApplicationWorkspace.allApplications, sorted
    // alphabetically) goes into the scrollable "App Library" section.
    char bids[256][128];
    char names[256][96];
    uint64_t collectT0 = stagestrip_now_ms();
    printf("[STAGE] picker: phase=collect-bids start (+%llums)\n", collectT0 - pickerT0);
    int totalBids = stagestrip_collect_picker_bids(bids, names, kStripPickerInitialMaxBids);
    printf("[STAGE] picker: phase=collect-bids done count=%d in %llums (+%llums)\n",
           totalBids,
           stagestrip_now_ms() - collectT0,
           stagestrip_now_ms() - pickerT0);

    double sideMargin = 14.0;
    double colGap = 8.0;
    double rowGap = 8.0;

    // --- "Recently Opened" — 2-column grid of horizontal tiles.
    double recentsStartY = swapY + 42.0;
    uint64_t recentsHeader = stagestrip_make_text_label("Recently Opened",
                                                        16.0, recentsStartY,
                                                        panelW - 32.0, 20.0);
    if (r_is_objc_ptr(recentsHeader)) {
        stagestrip_set_background_white(recentsHeader, 0.0, 0.0);
        r_msg2_main(panel, "addSubview:", recentsHeader, 0, 0, 0);
    }

    double recentsY = recentsStartY + 24.0;
    int recentsCols = 2;
    int recentsRowsMax = 2;
    int recentsCount = (totalBids < recentsCols * recentsRowsMax)
        ? totalBids
        : recentsCols * recentsRowsMax;

    double recentTileW = (panelW - sideMargin * 2.0 - colGap * (recentsCols - 1)) / (double)recentsCols;
    double recentTileH = 56.0;
    double recentIconSize = 40.0;
    uint64_t recentTilesT0 = stagestrip_now_ms();
    printf("[STAGE] picker: phase=recents-tiles start count=%d (+%llums)\n",
           recentsCount, recentTilesT0 - pickerT0);
    for (int i = 0; i < recentsCount; i++) {
        int row = i / recentsCols;
        int col = i % recentsCols;
        double x = sideMargin + col * (recentTileW + colGap);
        double y = recentsY + row * (recentTileH + rowGap);
        stagestrip_install_picker_app_tile(panel,
                                           panel,
                                           bids[i],
                                           names[i],
                                           x, y,
                                           recentTileW, recentTileH,
                                           recentIconSize,
                                           gStripPickerPendingBidLabel);
    }
    printf("[STAGE] picker: phase=recents-tiles done in %llums (+%llums)\n",
           stagestrip_now_ms() - recentTilesT0,
           stagestrip_now_ms() - pickerT0);

    double recentsBottom = recentsY +
        (recentsCount > 0
         ? (((recentsCount - 1) / recentsCols) + 1) * (recentTileH + rowGap)
         : 0);

    // --- "App Library" — scrollable 1-column list of horizontal tiles.
    double libraryStartY = recentsBottom + 8.0;
    uint64_t libHeader = stagestrip_make_text_label("App Library",
                                                    16.0, libraryStartY,
                                                    panelW - 32.0, 20.0);
    if (r_is_objc_ptr(libHeader)) {
        stagestrip_set_background_white(libHeader, 0.0, 0.0);
        r_msg2_main(panel, "addSubview:", libHeader, 0, 0, 0);
    }

    double libraryY = libraryStartY + 24.0;
    double libTileW = panelW - sideMargin * 2.0;
    double libTileH = 52.0;
    double libIconSize = 36.0;
    double libAvailable = panelH - libraryY - 16.0;
    if (libAvailable < 0) libAvailable = 0;
    int libCount = totalBids - recentsCount;
    if (libCount < 0) libCount = 0;

    // Embed library tiles in a UIScrollView so all installed apps are
    // reachable even when there are dozens.
    uint64_t UIScrollView = r_class("UIScrollView");
    uint64_t scrollAlloc = r_is_objc_ptr(UIScrollView)
        ? r_msg2_main(UIScrollView, "alloc", 0, 0, 0, 0) : 0;
    uint64_t scrollView = r_is_objc_ptr(scrollAlloc)
        ? r_msg2_main(scrollAlloc, "init", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(scrollView)) {
        stagestrip_set_frame_fast(scrollView,
                                  (StripRect){ 0.0, libraryY, panelW, libAvailable });
        stagestrip_set_background_white(scrollView, 0.0, 0.0);
        r_msg2_main(scrollView, "setShowsVerticalScrollIndicator:", 1, 0, 0, 0);
        r_msg2_main(scrollView, "setShowsHorizontalScrollIndicator:", 0, 0, 0, 0);
        r_msg2_main(scrollView, "setClipsToBounds:", 1, 0, 0, 0);
        r_msg2_main(scrollView, "setAlwaysBounceVertical:", 1, 0, 0, 0);

        // Reserve scroll-view content size up-front so the user can scroll
        // even while tiles are still being inserted.
        struct { double w; double h; } cs = {
            panelW,
            (double)libCount * (libTileH + rowGap) + 16.0
        };
        if (r_responds(scrollView, "setContentSize:")) {
            r_msg2_main_raw(scrollView, "setContentSize:",
                            &cs, sizeof(cs),
                            NULL, 0, NULL, 0, NULL, 0);
        }
        r_msg2_main(panel, "addSubview:", scrollView, 0, 0, 0);

        // Schedule the library-tile build to run on a background queue AFTER
        // this function returns. Each tile install is ~50 cross-process calls
        // × ~30ms each, so 79 tiles synchronously blocks for ~140s — moving
        // them off the install path means the user gets a working picker (with
        // recents) immediately and the library section fills in over the next
        // couple of minutes.
        printf("[STAGE] picker: deferring %d library tiles to background queue\n",
               libCount);
        stagestrip_schedule_library_tile_build(scrollView,
                                                bids + recentsCount,
                                                names + recentsCount,
                                                libCount,
                                                sideMargin,
                                                libTileW, libTileH,
                                                libIconSize,
                                                rowGap,
                                                pickerT0);
    } else {
        // Fallback (no scroll): inline up to ~10 tiles.
        int libMaxRows = (int)(libAvailable / (libTileH + rowGap));
        if (libMaxRows > 10) libMaxRows = 10;
        if (libMaxRows < 0) libMaxRows = 0;
        if (libCount > libMaxRows) libCount = libMaxRows;
        for (int i = 0; i < libCount; i++) {
            const char *libBid = bids[recentsCount + i];
            const char *libName = names[recentsCount + i];
            stagestrip_install_picker_app_tile(panel,
                                               panel,
                                               libBid,
                                               libName,
                                               sideMargin,
                                               libraryY + i * (libTileH + rowGap),
                                               libTileW, libTileH,
                                               libIconSize,
                                               gStripPickerPendingBidLabel);
        }
    }
    int picker_count = recentsCount + libCount;

    // (No backdrop tap-to-dismiss. An earlier version installed a UITap on
    //  the overlay window with setCancelsTouchesInView:NO, intending it to
    //  fire only on out-of-panel taps. UIKit fires it on *every* tap inside
    //  the window, in addition to the button's own actions — so every button
    //  press ended up with the panel's -tag being overwritten with
    //  kStripPickerCmdClose before Cyanide could poll. Users dismiss via the
    //  explicit "x" button.)

    // Stash overlay window on UIApplication so respring or re-applies reuse it.
    r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                 app, cacheKey, overlayWin, 1 /* RETAIN_NONATOMIC */,
                 0, 0, 0, 0);
    gStripPickerOverlayWin = overlayWin;
    gStripControlDrawer = overlayWin; // back-compat: validity check still works
    stagestrip_picker_build_cache_release();
    printf("[STAGE] picker: install done overlay=0x%llx panel=0x%llx rows=%d total=%llums\n",
           overlayWin, panel, picker_count,
           stagestrip_now_ms() - pickerT0);
    return overlayWin;
}

// Small bottom-right summon handle. Swipe-up or tap reveals the picker
// overlay window. Replaces the older fat 92x118 hot-corner panel.
static void stagestrip_install_hot_corner_window(uint64_t app,
                                                 uint64_t scene,
                                                 uint64_t pickerOverlayWin,
                                                 double sw,
                                                 double sh)
{
    if (!r_is_objc_ptr(app) || !r_is_objc_ptr(scene) || !r_is_objc_ptr(pickerOverlayWin)) return;

    uint64_t assocKey = r_sel("cyanideStageStripHotCornerWindow");
    if (!assocKey) return;

    uint64_t old = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                app, assocKey, 0, 0, 0, 0, 0, 0);
    if (r_is_objc_ptr(old)) {
        r_msg2_main(old, "setHidden:", 1, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     app, assocKey, 0, 1 /* RETAIN_NONATOMIC */, 0, 0, 0, 0);
    }

    uint64_t UIWindow = r_class("UIWindow");
    uint64_t alloc = r_is_objc_ptr(UIWindow)
        ? r_msg2_main(UIWindow, "alloc", 0, 0, 0, 0) : 0;
    uint64_t hotWin = r_is_objc_ptr(alloc)
        ? r_msg2_main(alloc, "initWithWindowScene:", scene, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(hotWin)) {
        printf("[STAGE] hotcorner: window init failed\n");
        return;
    }

    double hotW = 56.0;
    double hotH = 56.0;
    stagestrip_set_frame_fast(hotWin, (StripRect){ sw - hotW - 6.0, sh - hotH - 8.0, hotW, hotH });
    stagestrip_send_double(hotWin, "setWindowLevel:", kStripWindowLevel + 1.0);
    stagestrip_set_background_white(hotWin, 0.0, 0.0);
    if (r_responds(hotWin, "setOpaque:"))
        r_msg2_main(hotWin, "setOpaque:", 0, 0, 0, 0);
    r_msg2_main(hotWin, "setUserInteractionEnabled:", 1, 0, 0, 0);

    uint64_t UIView = r_class("UIView");
    uint64_t hotAlloc = r_is_objc_ptr(UIView)
        ? r_msg2_main(UIView, "alloc", 0, 0, 0, 0) : 0;
    uint64_t hot = r_is_objc_ptr(hotAlloc)
        ? r_msg2_main(hotAlloc, "init", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(hot)) {
        stagestrip_set_frame_fast(hot, (StripRect){ 0.0, 0.0, hotW, hotH });
        r_msg2_main(hot, "setAutoresizingMask:", 2 | 16, 0, 0, 0);
        r_msg2_main(hot, "setUserInteractionEnabled:", 1, 0, 0, 0);
        stagestrip_set_background_white(hot, 0.0, 0.0);
        r_msg2_main(hotWin, "addSubview:", hot, 0, 0, 0);

        // Visible pill — small, low-alpha dot at the centre. Less intrusive
        // than the previous 30x4 pill at the bottom of a fat panel.
        // Hot-corner indicator — needs to be discoverable now that install
        // doesn't show a float window. Small but visible: 20pt dot on a
        // softly-tinted backing, with a tiny "chevron" hint above.
        double dotSide = 20.0;
        uint64_t dotAlloc = r_msg2_main(UIView, "alloc", 0, 0, 0, 0);
        uint64_t dot = r_is_objc_ptr(dotAlloc)
            ? r_msg2_main(dotAlloc, "init", 0, 0, 0, 0) : 0;
        if (r_is_objc_ptr(dot)) {
            stagestrip_set_frame_fast(dot, (StripRect){ (hotW - dotSide) / 2.0,
                                                        (hotH - dotSide) / 2.0,
                                                        dotSide, dotSide });
            r_msg2_main(dot, "setUserInteractionEnabled:", 0, 0, 0, 0);
            stagestrip_set_background_white(dot, 1.0, 0.42);
            uint64_t layer = r_msg2_main(dot, "layer", 0, 0, 0, 0);
            if (r_is_objc_ptr(layer)) {
                stagestrip_send_double(layer, "setCornerRadius:", dotSide / 2.0);
                r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
            }
            r_msg2_main(hot, "addSubview:", dot, 0, 0, 0);
        }

        // Ask the control loop to show the picker, so tap/swipe uses the same
        // animated path as the stage-window swipe.
        uint64_t showInv = r_is_objc_ptr(gStripPickerPanel)
            ? stagestrip_make_int_invocation(gStripPickerPanel, "setTag:", kStripPickerCmdShow)
            : stagestrip_make_bool_invocation(pickerOverlayWin, "setHidden:", false);
        uint64_t invokeSel = r_sel("invoke");

        uint64_t UISwipe = r_class("UISwipeGestureRecognizer");
        uint64_t swipeAlloc = r_is_objc_ptr(UISwipe)
            ? r_msg2_main(UISwipe, "alloc", 0, 0, 0, 0) : 0;
        uint64_t swipeGR = r_is_objc_ptr(swipeAlloc) && r_is_objc_ptr(showInv) && invokeSel
            ? r_msg2_main(swipeAlloc, "initWithTarget:action:", showInv, invokeSel, 0, 0) : 0;
        if (r_is_objc_ptr(swipeGR)) {
            r_msg2_main(swipeGR, "setDirection:", 4 /* swipe up */, 0, 0, 0);
            if (r_responds(swipeGR, "setCancelsTouchesInView:"))
                r_msg2_main(swipeGR, "setCancelsTouchesInView:", 1, 0, 0, 0);
            r_msg2_main(hot, "addGestureRecognizer:", swipeGR, 0, 0, 0);
        }

        uint64_t UITap = r_class("UITapGestureRecognizer");
        uint64_t tapAlloc = r_is_objc_ptr(UITap)
            ? r_msg2_main(UITap, "alloc", 0, 0, 0, 0) : 0;
        uint64_t tapGR = r_is_objc_ptr(tapAlloc) && r_is_objc_ptr(showInv) && invokeSel
            ? r_msg2_main(tapAlloc, "initWithTarget:action:", showInv, invokeSel, 0, 0) : 0;
        if (r_is_objc_ptr(tapGR)) {
            r_msg2_main(tapGR, "setNumberOfTapsRequired:", 1, 0, 0, 0);
            if (r_responds(tapGR, "setCancelsTouchesInView:"))
                r_msg2_main(tapGR, "setCancelsTouchesInView:", 1, 0, 0, 0);
            r_msg2_main(hot, "addGestureRecognizer:", tapGR, 0, 0, 0);
        }

        if (r_is_objc_ptr(showInv))
            stagestrip_retain_action_target(hot, showInv);
    }

    r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                 app, assocKey, hotWin, 1 /* RETAIN_NONATOMIC */, 0, 0, 0, 0);
    r_msg2_main(hotWin, "setHidden:", 0, 0, 0, 0);
    printf("[STAGE] hotcorner: window=0x%llx pickerOverlay=0x%llx (slim)\n",
           hotWin, pickerOverlayWin);
}

// Build (or reuse) a floating UIWindow at the bottom-right corner and parent
// `hostView` inside it. Caches the window on UIApplication via
// objc_setAssociatedObject so successive probes update the existing window
// rather than stacking new ones.
// Slot-aware presenter. Each slot owns its own UIWindow + pan handles, so
// the two apps can be moved/resized independently across the screen.
static bool stagestrip_present_floating_host_for_slot(int slot,
                                                     uint64_t hostView,
                                                     double w, double h,
                                                     double defaultX,
                                                     double defaultY)
{
    if (slot < 0 || slot >= kStripMaxFloatSlots) return false;
    if (!r_is_objc_ptr(hostView)) return false;

    StripFloatSlot *S = &gStripFloatSlots[slot];

    uint64_t UIApplication = r_class("UIApplication");
    uint64_t app = r_is_objc_ptr(UIApplication)
        ? r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(app)) return false;

    char keyName[64];
    snprintf(keyName, sizeof(keyName), "cyanideStageStripFloatWindow%d", slot);
    uint64_t assocKey = r_sel(keyName);
    if (!assocKey) return false;

    uint64_t win = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                app, assocKey, 0, 0, 0, 0, 0, 0);
    if (r_is_objc_ptr(win)) {
        if (kStripAlwaysRecreateFloatWindow) {
            printf("[STAGE] float: discarding previous window=0x%llx\n", win);
            r_msg2_main(win, "setHidden:", 1, 0, 0, 0);
            r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                         app, assocKey, 0, 1 /* RETAIN_NONATOMIC */,
                         0, 0, 0, 0);
            win = 0;
        }
    }
    if (r_is_objc_ptr(win) && kStripUseInteractiveFloatWindow) {
        uint64_t usesWindowServerHitTesting = r_responds(win, "_usesWindowServerHitTesting")
            ? r_msg2_main(win, "_usesWindowServerHitTesting", 0, 0, 0, 0)
            : 0;
        if ((usesWindowServerHitTesting & 0xff) == 0) {
            printf("[STAGE] float: replacing old non-window-server-hit-test window=0x%llx\n", win);
            r_msg2_main(win, "setHidden:", 1, 0, 0, 0);
            r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                         app, assocKey, 0, 1 /* RETAIN_NONATOMIC */,
                         0, 0, 0, 0);
            win = 0;
        }
    }
    bool reusedWindow = r_is_objc_ptr(win);

    // Pick the host window's UIWindowScene so the floating window can attach
    // to the same display.
    uint64_t keyWin = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    if (!r_is_objc_ptr(keyWin)) {
        uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
        if (r_is_objc_ptr(windows)) {
            uint64_t cnt = r_msg2_main(windows, "count", 0, 0, 0, 0);
            if (cnt > 0 && cnt < 64) keyWin = r_msg2_main(windows, "objectAtIndex:", 0, 0, 0, 0);
        }
    }
    if (!r_is_objc_ptr(keyWin)) { printf("[STAGE] float: no keyWindow\n"); return false; }
    uint64_t scene = r_msg2_main(keyWin, "windowScene", 0, 0, 0, 0);
    if (!r_is_objc_ptr(scene)) { printf("[STAGE] float: no windowScene\n"); return false; }

    if (!r_is_objc_ptr(win)) {
        uint64_t WindowClass = kStripUseInteractiveFloatWindow
            ? r_class("SBInteractiveScreenshotGestureRootWindow")
            : 0;
        const char *windowClassName = kStripUseInteractiveFloatWindow
            ? "SBInteractiveScreenshotGestureRootWindow"
            : "UIWindow";
        if (!r_is_objc_ptr(WindowClass)) {
            WindowClass = r_class("UIWindow");
            windowClassName = "UIWindow";
        }
        uint64_t winAlloc = r_msg2_main(WindowClass, "alloc", 0, 0, 0, 0);
        win = r_is_objc_ptr(winAlloc)
            ? r_msg2_main(winAlloc, "initWithWindowScene:", scene, 0, 0, 0) : 0;
        if (!r_is_objc_ptr(win) && strcmp(windowClassName, "UIWindow") != 0) {
            uint64_t UIWindow = r_class("UIWindow");
            winAlloc = r_msg2_main(UIWindow, "alloc", 0, 0, 0, 0);
            win = r_is_objc_ptr(winAlloc)
                ? r_msg2_main(winAlloc, "initWithWindowScene:", scene, 0, 0, 0) : 0;
            windowClassName = "UIWindow";
        }
        if (!r_is_objc_ptr(win)) { printf("[STAGE] float: UIWindow init failed\n"); return false; }

        stagestrip_set_background_white(win, 0.0, 0.04);
        if (r_responds(win, "setOpaque:"))
            r_msg2_main(win, "setOpaque:", 0, 0, 0, 0);
        stagestrip_send_double(win, "setWindowLevel:", kStripWindowLevel);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     app, assocKey, win, 1 /* RETAIN_NONATOMIC */, 0, 0, 0, 0);
        uint64_t usesWindowServerHitTesting = r_responds(win, "_usesWindowServerHitTesting")
            ? r_msg2_main(win, "_usesWindowServerHitTesting", 0, 0, 0, 0)
            : 0;
        printf("[STAGE] float: new %s=0x%llx scene=0x%llx wsHit=%llu\n",
               windowClassName, win, scene, usesWindowServerHitTesting & 0xff);
    } else {
        bool controlsValid = r_is_objc_ptr(S->movePan) &&
                             r_is_objc_ptr(S->resizePan);
        printf("[STAGE] float[%d]: reuse begin win=0x%llx oldHost=0x%llx controls=%d\n",
               slot, win, S->hostView, controlsValid ? 1 : 0);
        if (!r_is_objc_ptr(S->hostView) && !controlsValid) {
            uint64_t subs = r_msg2_main(win, "subviews", 0, 0, 0, 0);
            if (r_is_objc_ptr(subs)) {
                uint64_t cnt = r_msg2_main(subs, "count", 0, 0, 0, 0);
                for (uint64_t i = 0; i < cnt && i < 32; i++) {
                    uint64_t v = r_msg2_main(subs, "objectAtIndex:", i, 0, 0, 0);
                    if (r_is_objc_ptr(v)) {
                        r_msg2_main(v, "setHidden:", 1, 0, 0, 0);
                        r_msg2_main(v, "removeFromSuperview", 0, 0, 0, 0);
                    }
                }
            }
        }
        printf("[STAGE] float[%d]: reusing window=0x%llx\n", slot, win);
    }
    stagestrip_set_background_white(win, 0.0, 0.04);
    if (r_responds(win, "setOpaque:"))
        r_msg2_main(win, "setOpaque:", 0, 0, 0, 0);

    CGRect b = UIScreen.mainScreen.bounds;
    double sw = isfinite(b.size.width)  && b.size.width  >= 200.0 ? b.size.width  : 390.0;
    double sh = isfinite(b.size.height) && b.size.height >= 200.0 ? b.size.height : 844.0;
    StripRect frame = { defaultX, defaultY, w, h };
    if (reusedWindow) {
        StripRect current = {0};
        if (stagestrip_get_frame_thread(win, &current) &&
            current.width >= 100.0 && current.height >= 100.0) {
            frame = current;
        }
    }
    stagestrip_send_rect(win, "setFrame:", frame.x, frame.y, frame.width, frame.height);

    uint64_t oldHostView = reusedWindow ? S->hostView : 0;

    // Host view sits inset from the window edges so the transparent border
    // zone acts as an easy-to-grab resize/move target.
    double bi = kStripBorderInset;
    stagestrip_send_rect(hostView, "setFrame:", bi, bi,
                         frame.width - 2.0 * bi, frame.height - 2.0 * bi);
    r_msg2_main(hostView, "setAutoresizingMask:", 2 | 16, 0, 0, 0);
    r_msg2_main(hostView, "setClipsToBounds:", 1, 0, 0, 0);
    r_msg2_main(hostView, "setUserInteractionEnabled:", 1, 0, 0, 0);
    uint64_t hostLayer = r_msg2_main(hostView, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(hostLayer))
        stagestrip_send_double(hostLayer, "setCornerRadius:", kStripCornerRadius - bi);
    printf("[STAGE] float[%d]: attach host=0x%llx oldHost=0x%llx frame=(%.0f,%.0f %.0fx%.0f)\n",
           slot, hostView, oldHostView, frame.x, frame.y, frame.width, frame.height);
    r_msg2_main(win, "addSubview:", hostView, 0, 0, 0);
    S->window = win;
    S->hostView = hostView;
    S->referenceView = r_is_objc_ptr(keyWin) ? keyWin : win;

    // Picker overlay + hot corner are shared across both slots; install once.
    if (!r_is_objc_ptr(gStripPickerOverlayWin)) {
        uint64_t overlay = stagestrip_install_picker_overlay(app, scene, sw, sh);
        stagestrip_install_hot_corner_window(app, scene, overlay, sw, sh);
    }
    // Per-slot pan handles — each window gets its own move + resize gestures.
    if (!r_is_objc_ptr(S->movePan) || !r_is_objc_ptr(S->resizePan)) {
        stagestrip_install_pan_handles_slot(slot, win, hostView, keyWin, frame.width, frame.height);
    } else {
        stagestrip_raise_pan_handles_slot(S);
    }
    // Per-slot X close button (top-left of the window). The tap chain raises a
    // temporary shield, then hides the window; the control loop tears it down.
    stagestrip_install_slot_close_button(slot, win, hostView, frame.width);
    if (r_is_objc_ptr(oldHostView) && oldHostView != hostView) {
        printf("[STAGE] float: retire oldHost=0x%llx\n", oldHostView);
        r_msg2_main(oldHostView, "setHidden:", 1, 0, 0, 0);
        r_msg2_main(oldHostView, "removeFromSuperview", 0, 0, 0, 0);
    }

    uint64_t layer = r_msg2_main(win, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        stagestrip_send_double(layer, "setCornerRadius:", kStripCornerRadius);
        if (r_responds(layer, "setCornerCurve:")) {
            uint64_t cont = r_nsstr_retained("continuous");
            if (r_is_objc_ptr(cont)) {
                r_msg2_main(layer, "setCornerCurve:", cont, 0, 0, 0);
                r_msg2_main(cont, "release", 0, 0, 0, 0);
            }
        }
        r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
        stagestrip_set_layer_border_white(win, 1.0, 0.15, 1.0);
    }
    r_msg2_main(win, "setUserInteractionEnabled:", 1, 0, 0, 0);
    if (r_responds(win, "setMultipleTouchEnabled:"))
        r_msg2_main(win, "setMultipleTouchEnabled:", 1, 0, 0, 0);
    stagestrip_send_double(win, "setAlpha:", 1.0);
    r_msg2_main(win, "setHidden:", 0, 0, 0, 0);
    if (r_responds(win, "setNeedsLayout")) r_msg2_main(win, "setNeedsLayout", 0, 0, 0, 0);
    if (r_responds(win, "layoutIfNeeded")) r_msg2_main(win, "layoutIfNeeded", 0, 0, 0, 0);
    if (kStripMakeFloatWindowKey && r_responds(win, "makeKeyAndVisible"))
        r_msg2_main(win, "makeKeyAndVisible", 0, 0, 0, 0);

    printf("[STAGE] float[%d]: presented host=0x%llx in win=0x%llx at (%.0f,%.0f %.0fx%.0f) reuse=%d\n",
           slot, hostView, win, frame.x, frame.y, frame.width, frame.height, reusedWindow ? 1 : 0);
    return true;
}

static bool stagestrip_dismiss_floating_host(void)
{
    uint64_t UIApplication = r_class("UIApplication");
    uint64_t app = r_is_objc_ptr(UIApplication)
        ? r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(app)) return false;

    // Tear down both slot windows. Each has its own assoc key
    // (cyanideStageStripFloatWindowN).
    for (int s = 0; s < kStripMaxFloatSlots; s++) {
        char keyName[64];
        snprintf(keyName, sizeof(keyName), "cyanideStageStripFloatWindow%d", s);
        uint64_t slotKey = r_sel(keyName);
        if (!slotKey) continue;
        uint64_t win = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                    app, slotKey, 0, 0, 0, 0, 0, 0);
        if (r_is_objc_ptr(win)) {
            uint64_t subs = r_msg2_main(win, "subviews", 0, 0, 0, 0);
            if (r_is_objc_ptr(subs)) {
                uint64_t cnt = r_msg2_main(subs, "count", 0, 0, 0, 0);
                for (uint64_t i = 0; i < cnt && i < 32; i++) {
                    uint64_t v = r_msg2_main(subs, "objectAtIndex:", i, 0, 0, 0);
                    if (r_is_objc_ptr(v)) {
                        stagestrip_cleanup_host_view(v);
                        r_msg2_main(v, "removeFromSuperview", 0, 0, 0, 0);
                    }
                }
            }
            r_msg2_main(win, "setHidden:", 1, 0, 0, 0);
            r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject", app, slotKey, 0, 1, 0, 0, 0, 0);
        }
        memset(&gStripFloatSlots[s], 0, sizeof(gStripFloatSlots[s]));
    }
    // Legacy single-window key kept so older respring caches are also cleared.
    uint64_t legacyKey = r_sel("cyanideStageStripFloatWindow");
    uint64_t legacyWin = legacyKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject", app, legacyKey, 0, 0, 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(legacyWin)) {
        r_msg2_main(legacyWin, "setHidden:", 1, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject", app, legacyKey, 0, 1, 0, 0, 0, 0);
    }
    uint64_t hotKey = r_sel("cyanideStageStripHotCornerWindow");
    uint64_t hotWin = hotKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                       app, hotKey, 0, 0, 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(hotWin)) {
        r_msg2_main(hotWin, "setHidden:", 1, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     app, hotKey, 0, 1 /* RETAIN_NONATOMIC */, 0, 0, 0, 0);
    }
    uint64_t pickerKey = r_sel("cyanideStageStripPickerWindow");
    uint64_t pickerWin = pickerKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                       app, pickerKey, 0, 0, 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(pickerWin)) {
        r_msg2_main(pickerWin, "setHidden:", 1, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     app, pickerKey, 0, 1 /* RETAIN_NONATOMIC */, 0, 0, 0, 0);
    }
    uint64_t shieldKey = r_sel("cyanideStageStripTransitionShieldWindow");
    uint64_t shieldWin = shieldKey
        ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                       app, shieldKey, 0, 0, 0, 0, 0, 0)
        : 0;
    if (r_is_objc_ptr(shieldWin)) {
        r_msg2_main(shieldWin, "setHidden:", 1, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     app, shieldKey, 0, 1 /* RETAIN_NONATOMIC */, 0, 0, 0, 0);
    }
    // gStripFloatSlots already memset to zero above; just clear the rest.
    gStripControlDrawer = 0;
    gStripPickerOverlayWin = 0;
    gStripTransitionShieldWin = 0;
    gStripPickerPanel = 0;
    gStripPickerTopLabel = 0;
    gStripPickerBottomLabel = 0;
    gStripPickerTopChip = 0;
    gStripPickerBottomChip = 0;
    gStripPickerTopIcon = 0;
    gStripPickerBottomIcon = 0;
    gStripPickerTopChipCard = 0;
    gStripPickerBottomChipCard = 0;
    gStripPickerPendingBidLabel = 0;
    gStripPickerNextSlot = 0;
    memset(gStripRows, 0, sizeof(gStripRows));
    memset(gStripLives, 0, sizeof(gStripLives));
    return true;
}

static bool stagestrip_host_stage_picks(StripScenePick *picks,
                                        int pickedCount,
                                        StripSize stageSize,
                                        const char *source)
{
    if (!picks || pickedCount <= 0) {
        printf("[STAGE] %s: no usable scene handles\n", source ? source : "stack");
        stagestrip_dismiss_floating_host();
        return false;
    }
    if (pickedCount > 2) pickedCount = 2;

    for (int i = 0; i < pickedCount; i++) {
        printf("[STAGE] %s: hosting[%d] handle=0x%llx scene=0x%llx bid=%s\n",
               source ? source : "stack",
               i, picks[i].handle, picks[i].scene, picks[i].bid);

        // "Already prepared" early-out: if a prior apply for this scene
        // already left a valid -[keepalive timer] associated, the foreground
        // attribution is being maintained on a 0.5s tick. Re-doing it costs
        // ~80 remote calls per pick and changes nothing.
        bool alreadyPrepared = false;
        if (r_is_objc_ptr(picks[i].scene)) {
            uint64_t timerKey = r_sel("cyanideStageStripForegroundKeepaliveTimer");
            uint64_t timer = timerKey
                ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                               picks[i].scene, timerKey, 0, 0, 0, 0, 0, 0)
                : 0;
            if (r_is_objc_ptr(timer) && r_responds(timer, "isValid")) {
                alreadyPrepared = (r_msg2_main(timer, "isValid", 0, 0, 0, 0) & 0xff) != 0;
            }
        }

        if (!alreadyPrepared) {
            stagestrip_prepare_handle_for_stage(picks[i].handle, i, picks[i].bid);
            if (r_is_objc_ptr(picks[i].scene)) {
                stagestrip_set_scene_settings_live(picks[i].scene, picks[i].bid);
                stagestrip_force_external_foreground_scene(picks[i].scene, picks[i].handle, picks[i].bid);
                stagestrip_set_scene_foreground_via_updater(picks[i].scene, i, picks[i].bid);
            }
        } else {
            printf("[STAGE] %s: scene=0x%llx bid=%s already prepared, skipping foreground prep\n",
                   source ? source : "stack", picks[i].scene, picks[i].bid);
        }

        // Live-rendering assertion auto-invalidates after ~10s, so always
        // refresh it. The function itself internally skips work when its
        // timer is still valid.
        if (r_is_objc_ptr(picks[i].scene))
            stagestrip_assert_live_rendering_for_scene(picks[i].scene, picks[i].bid);
    }
    stagestrip_update_foreground_attribution(picks, pickedCount);

    // Two-window mode: each pick gets its OWN floating UIWindow + move/resize
    // pan handles, so they're independently draggable across the screen.
    // Build a scene-layer-host view per pick (falling back through the same
    // chain make_stacked_stage_host used to use) and hand it to the
    // slot-aware presenter.
    CGRect b = UIScreen.mainScreen.bounds;
    double sw = isfinite(b.size.width)  && b.size.width  >= 200.0 ? b.size.width  : 390.0;
    double sh = isfinite(b.size.height) && b.size.height >= 200.0 ? b.size.height : 844.0;

    double tileW = stageSize.width;
    double tileH = stageSize.height;
    if (tileW > sw - 16.0) tileW = sw - 16.0;
    if (tileH > (sh - 100.0) / 2.0) tileH = (sh - 100.0) / 2.0;

    int presented = 0;
    for (int i = 0; i < pickedCount && i < kStripMaxFloatSlots; i++) {
        uint64_t view = 0;
        if (kStripPreferRawSceneLayerHost) {
            view = stagestrip_make_scene_layer_host_view(picks[i].scene, picks[i].bid, tileW, tileH);
        }
        if (!r_is_objc_ptr(view) && i < kStripMaxMedusaTiles)
            view = stagestrip_make_medusa_scene_view(picks[i].handle, i, tileW, tileH);
        if (!r_is_objc_ptr(view))
            view = stagestrip_make_direct_scene_view(picks[i].handle, tileW, tileH);
        if (!r_is_objc_ptr(view))
            view = stagestrip_handle_make_view(picks[i].handle, tileW, tileH);
        if (!r_is_objc_ptr(view) && !kStripPreferRawSceneLayerHost)
            view = stagestrip_make_scene_layer_host_view(picks[i].scene, picks[i].bid, tileW, tileH);
        if (!r_is_objc_ptr(view)) {
            printf("[STAGE] %s: no view for slot %d bid=%s\n",
                   source ? source : "stack", i, picks[i].bid);
            continue;
        }

        // Default positions: slot 0 takes the top half, slot 1 takes the
        // bottom half. Reused windows keep their last user-set frame.
        double defaultX = (sw - tileW) / 2.0;
        double topInset = sh * 0.08;
        double defaultY = (i == 0)
            ? topInset
            : topInset + tileH + 12.0;

        if (stagestrip_present_floating_host_for_slot(i, view, tileW, tileH,
                                                      defaultX, defaultY)) {
            presented++;
            if (i < 2) {
                gStripLives[i] = view;
            }
        }
    }
    if (presented == 0) {
        stagestrip_dismiss_floating_host();
        return false;
    }
    return true;
}

static bool stagestrip_rebuild_selected_bids(const char *topBid, const char *bottomBid)
{
    if (!topBid || !*topBid || !bottomBid || !*bottomBid) return false;
    if (strcmp(topBid, bottomBid) == 0) {
        printf("[STAGE] picker: ignoring duplicate selection %s\n", topBid);
        return false;
    }

    StripScenePick picks[2];
    memset(picks, 0, sizeof(picks));
    if (!stagestrip_get_pick_for_bid(topBid, &picks[0])) {
        printf("[STAGE] picker: top selection unavailable bid=%s\n", topBid);
        return false;
    }
    if (!stagestrip_get_pick_for_bid(bottomBid, &picks[1])) {
        printf("[STAGE] picker: bottom selection unavailable bid=%s\n", bottomBid);
        return false;
    }

    stagestrip_clear_live_rendering_state();
    StripSize stageSize = stagestrip_stage_size_for_request(4);
    return stagestrip_host_stage_picks(picks, 2, stageSize, "picker");
}

// Multitasking-only probe (sidebar UI disabled). Tries first to pull a
// non-Cyanide handle from the App-Switcher recents (which survive even
// when Cyanide is foregrounded), and falls back to layoutStateApplicationSceneHandles
// only if recents come back empty. Materialises the picked handle's view
// via -newSceneViewController and parents it into a floating UIWindow at
// the bottom-right corner.
// Tray-only install — matches StageDuo's startup behavior. The original
// dylib's applicationDidFinishLaunching: hook just installs a transparent
// host UIWindow above SpringBoard's UI and waits for a chevron-pull gesture
// to summon the picker. Nothing visible appears until the user gestures.
//
// We can't hijack SpringBoard's chevron without a dylib, so we install a
// small bottom-right hot-corner indicator with a swipe-up/tap gesture. On
// gesture, the picker tray slides in. Only when the user picks two apps
// and taps Apply does the floating host window get built and populated.
static bool stagestrip_install_tray_only(int maxSlots)
{
    if (maxSlots <= 0) maxSlots = 4;
    if (maxSlots > kStripMaxSlotsHard) maxSlots = kStripMaxSlotsHard;
    if (!stagestrip_ensure_open_method()) return false;

    if (kStripDebugDumpScenes)
        stagestrip_dump_all_scenes();

    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) {
        printf("[STAGE] tray: UIApplication class missing\n");
        return false;
    }
    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) {
        printf("[STAGE] tray: sharedApplication nil\n");
        return false;
    }

    uint64_t keyWin = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    if (!r_is_objc_ptr(keyWin)) {
        uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
        if (r_is_objc_ptr(windows)) {
            uint64_t cnt = r_msg2_main(windows, "count", 0, 0, 0, 0);
            if (cnt > 0 && cnt < 64)
                keyWin = r_msg2_main(windows, "objectAtIndex:", 0, 0, 0, 0);
        }
    }
    if (!r_is_objc_ptr(keyWin)) {
        printf("[STAGE] tray: no key window\n");
        return false;
    }
    uint64_t scene = r_msg2_main(keyWin, "windowScene", 0, 0, 0, 0);
    if (!r_is_objc_ptr(scene)) {
        printf("[STAGE] tray: no windowScene on keyWin=0x%llx\n", keyWin);
        return false;
    }

    CGRect b = UIScreen.mainScreen.bounds;
    double sw = isfinite(b.size.width)  && b.size.width  >= 200.0 ? b.size.width  : 390.0;
    double sh = isfinite(b.size.height) && b.size.height >= 200.0 ? b.size.height : 844.0;

    // Install picker overlay (hidden); reuses cached one if a respring left
    // it around.
    uint64_t overlay = stagestrip_install_picker_overlay(app, scene, sw, sh);
    if (!r_is_objc_ptr(overlay)) {
        printf("[STAGE] tray: picker overlay install failed\n");
        return false;
    }

    // Hot-corner indicator at the bottom-right. Tap or swipe-up summons the
    // overlay. This is our stand-in for StageDuo's chevron-pull hijack.
    stagestrip_install_hot_corner_window(app, scene, overlay, sw, sh);

    printf("[STAGE] tray: install complete overlay=0x%llx (no float window until Apply)\n",
           overlay);
    return true;
}

static bool stagestrip_probe_multitasking_only(int maxSlots)
{
    // Old "show two apps immediately" behavior is gone. The tray-only install
    // is the only mode now: the user has to summon the picker and choose
    // apps before any float window appears.
    return stagestrip_install_tray_only(maxSlots);
}

static bool stagestrip_install_or_refresh(int maxSlots)
{
    if (!kStripShowSidebar) {
        return stagestrip_probe_multitasking_only(maxSlots);
    }

    if (maxSlots <= 0) maxSlots = 4;
    if (maxSlots > kStripMaxSlotsHard) maxSlots = kStripMaxSlotsHard;

    if (!stagestrip_ensure_open_method()) return false;

    // -- Locate UIApplication + reuse-cached window (if respring kept it).

    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) { printf("[STAGE] install: UIApplication missing\n"); return false; }
    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) { printf("[STAGE] install: sharedApplication nil\n"); return false; }

    uint64_t assocKey = r_sel("cyanideStageStripOverlayWindow");
    if (!assocKey) return false;

    if (!r_is_objc_ptr(gStripWindow)) {
        uint64_t cached = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                       app, assocKey, 0, 0, 0, 0, 0, 0);
        if (r_is_objc_ptr(cached)) {
            gStripWindow = cached;
            uint64_t container = r_msg2_main(cached, "viewWithTag:", kStripWindowTag, 0, 0, 0);
            if (r_is_objc_ptr(container)) gStripContainer = container;
        }
    }

    // -- Build window + container fresh if we don't have them.

    if (!r_is_objc_ptr(gStripWindow) || !r_is_objc_ptr(gStripContainer)) {
        uint64_t hostWin = stagestrip_window_for_app(app);
        if (!r_is_objc_ptr(hostWin)) { printf("[STAGE] install: no host window\n"); return false; }

        uint64_t scene = r_msg2_main(hostWin, "windowScene", 0, 0, 0, 0);
        if (!r_is_objc_ptr(scene)) { printf("[STAGE] install: nil windowScene\n"); return false; }

        uint64_t UIWindow = r_class("UIWindow");
        uint64_t winAlloc = r_msg2_main(UIWindow, "alloc", 0, 0, 0, 0);
        uint64_t win = r_is_objc_ptr(winAlloc)
            ? r_msg2_main(winAlloc, "initWithWindowScene:", scene, 0, 0, 0)
            : 0;
        if (!r_is_objc_ptr(win)) { printf("[STAGE] install: UIWindow init failed\n"); return false; }

        uint64_t UIColor = r_class("UIColor");
        if (r_is_objc_ptr(UIColor)) {
            uint64_t clear = r_msg2_main(UIColor, "clearColor", 0, 0, 0, 0);
            if (r_is_objc_ptr(clear)) r_msg2_main(win, "setBackgroundColor:", clear, 0, 0, 0);
        }
        stagestrip_send_double(win, "setWindowLevel:", kStripWindowLevel);

        uint64_t UIView = r_class("UIView");
        uint64_t cAlloc = r_msg2_main(UIView, "alloc", 0, 0, 0, 0);
        uint64_t container = r_is_objc_ptr(cAlloc) ? r_msg2_main(cAlloc, "init", 0, 0, 0, 0) : 0;
        if (!r_is_objc_ptr(container)) { printf("[STAGE] install: container init failed\n"); return false; }
        r_msg2_main(container, "setTag:", kStripWindowTag, 0, 0, 0);

        // Translucent dark pill behind the slots.
        uint64_t bgLayer = r_msg2_main(container, "layer", 0, 0, 0, 0);
        if (r_is_objc_ptr(bgLayer)) {
            stagestrip_send_double(bgLayer, "setCornerRadius:", kStripCornerRadius);
            r_msg2_main(bgLayer, "setMasksToBounds:", 1, 0, 0, 0);
        }
        if (r_is_objc_ptr(UIColor) && r_responds(UIColor, "colorWithWhite:alpha:")) {
            double white = 0.0;
            double alpha = 0.35;
            uint64_t bg = r_msg2_main_raw(UIColor, "colorWithWhite:alpha:",
                                          &white, sizeof(white),
                                          &alpha, sizeof(alpha),
                                          NULL, 0, NULL, 0);
            if (r_is_objc_ptr(bg)) r_msg2_main(container, "setBackgroundColor:", bg, 0, 0, 0);
        }

        r_msg2_main(win, "addSubview:", container, 0, 0, 0);
        r_msg2_main(win, "setHidden:", 0, 0, 0, 0);

        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     app, assocKey, win, 1 /* RETAIN_NONATOMIC */, 0, 0, 0, 0);
        gStripWindow = win;
        gStripContainer = container;
        if (stagestrip_should_log_tick())
            printf("[STAGE] install: window=0x%llx container=0x%llx\n", win, container);
    }

    // -- Frame the window/container against current screen bounds.

    CGRect bounds = UIScreen.mainScreen.bounds;
    double screenW = bounds.size.width;
    double screenH = bounds.size.height;
    if (!isfinite(screenW) || screenW < 200.0) screenW = 390.0;
    if (!isfinite(screenH) || screenH < 200.0) screenH = 844.0;

    double stripHeight = screenH - kStripTopInset - kStripBottomInset;
    if (stripHeight < kStripSlotH) stripHeight = kStripSlotH;

    stagestrip_send_rect(gStripWindow, "setFrame:",
                         kStripLeftMargin, kStripTopInset,
                         kStripWidth, stripHeight);
    stagestrip_send_rect(gStripContainer, "setFrame:",
                         0.0, 0.0, kStripWidth, stripHeight);

    // -- Rebuild slots from current running apps.

    stagestrip_drop_subviews(gStripContainer);

    StripAppEntry entries[kStripMaxSlotsHard];
    int n = stagestrip_collect_apps(entries, maxSlots);
    if (n == 0) {
        printf("[STAGE] install: no eligible apps; strip empty\n");
        return true;
    }

    double totalSlotsHeight = n * kStripSlotH + (n - 1) * kStripSlotSpacing;
    double startY = (stripHeight - totalSlotsHeight) / 2.0;
    if (startY < 8.0) startY = 8.0;

    int added = 0;
    for (int i = 0; i < n; i++) {
        double y = startY + i * (kStripSlotH + kStripSlotSpacing);
        uint64_t img = stagestrip_fetch_icon_image(entries[i].bid);
        uint64_t slot = stagestrip_make_slot(entries[i].appPtr, img, entries[i].bid, y);
        if (r_is_objc_ptr(slot)) {
            r_msg2_main(gStripContainer, "addSubview:", slot, 0, 0, 0);
            added++;
            printf("[STAGE] slot[%d]: bid=%s app=0x%llx img=0x%llx\n",
                   i, entries[i].bid, entries[i].appPtr, img);
        }
    }

    r_msg2_main(gStripWindow, "setHidden:", 0, 0, 0, 0);
    printf("[STAGE] install: %d slot(s) rendered\n", added);
    return added > 0;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

static bool stagestrip_pan_state_is_active(uint64_t state)
{
    return state == 1 /* began */ || state == 2 /* changed */;
}

static bool stagestrip_read_picker_label(uint64_t label, char *out, size_t outLen)
{
    if (!out || outLen == 0) return false;
    out[0] = '\0';
    if (!r_is_objc_ptr(label)) return false;

    uint64_t text = r_msg2_main(label, "text", 0, 0, 0, 0);
    return r_read_nsstring(text, out, outLen);
}

static bool stagestrip_apply_picker_selection(const char *top, const char *bottom)
{
    if (!top || !*top || !bottom || !*bottom) return false;
    if (strcmp(top, bottom) == 0) {
        printf("[STAGE] picker: duplicate selection %s, skipping\n", top);
        return false;
    }
    if (strcmp(top, gStripPickerTopBid) == 0 &&
        strcmp(bottom, gStripPickerBottomBid) == 0) {
        printf("[STAGE] picker: same as current top=%s bottom=%s, skipping\n", top, bottom);
        return false;
    }
    if (!__sync_bool_compare_and_swap(&gStripPickerApplyBusy, 0, 1)) {
        printf("[STAGE] picker: apply already busy\n");
        return false;
    }

    strncpy(gStripPickerTopBid, top, sizeof(gStripPickerTopBid) - 1);
    gStripPickerTopBid[sizeof(gStripPickerTopBid) - 1] = '\0';
    strncpy(gStripPickerBottomBid, bottom, sizeof(gStripPickerBottomBid) - 1);
    gStripPickerBottomBid[sizeof(gStripPickerBottomBid) - 1] = '\0';

    printf("[STAGE] picker: apply top=%s bottom=%s\n", top, bottom);
    stagestrip_show_transition_shield(kStripTransitionShieldAlpha);
    bool ok = stagestrip_rebuild_selected_bids(top, bottom);
    printf("[STAGE] picker: apply done ok=%d top=%s bottom=%s\n",
           ok ? 1 : 0, top, bottom);
    stagestrip_hide_transition_shield_after(kStripTransitionShieldApplyHold);
    __sync_lock_release(&gStripPickerApplyBusy);
    return ok;
}

// Read the panel's -tag as a command code. One remote call when idle. When
// non-zero, the poller resets the tag, reads any bid labels it needs, and
// dispatches the command. Returns the command code consumed (0 if none).
static int stagestrip_poll_picker_command(void)
{
    uint64_t panel = gStripPickerPanel;
    if (!r_is_objc_ptr(panel)) return 0;

    // Cache sels across calls. -tag and -setTag: just hit an NSInteger ivar;
    // calling off-main via r_msg saves the ~25-call NSInvocation roundtrip
    // and is safe enough here — the worst race is a missed tag we'll see on
    // the next 400ms poll.
    static uint64_t selTag = 0;
    static uint64_t selSetTag = 0;
    static bool loggedFirstPoll = false;
    if (!selTag)    selTag    = r_sel("tag");
    if (!selSetTag) selSetTag = r_sel("setTag:");
    if (!selTag || !selSetTag) {
        printf("[STAGE] picker: sel cache failed tag=0x%llx setTag=0x%llx\n",
               selTag, selSetTag);
        return 0;
    }
    if (!loggedFirstPoll) {
        printf("[STAGE] picker: poll active panel=0x%llx selTag=0x%llx selSetTag=0x%llx\n",
               panel, selTag, selSetTag);
        loggedFirstPoll = true;
    }

    uint64_t tag = r_msg(panel, selTag, 0, 0, 0, 0);
    if (tag == 0) return 0;

    // Clear before dispatch so a slow callback doesn't fire twice.
    r_msg(panel, selSetTag, 0, 0, 0, 0);

    int cmd = (int)tag;
    printf("[STAGE] picker: cmd=%d\n", cmd);

    char top[128] = {0};
    char bottom[128] = {0};
    if (r_is_objc_ptr(gStripPickerTopLabel))
        stagestrip_read_picker_label(gStripPickerTopLabel, top, sizeof(top));
    if (r_is_objc_ptr(gStripPickerBottomLabel))
        stagestrip_read_picker_label(gStripPickerBottomLabel, bottom, sizeof(bottom));

    switch (cmd) {
        case kStripPickerCmdApply: {
            if (!top[0] || !bottom[0]) {
                printf("[STAGE] picker: apply needs both top + bottom (have top=%s bottom=%s)\n",
                       top[0] ? top : "—", bottom[0] ? bottom : "—");
            } else {
                stagestrip_apply_picker_selection(top, bottom);
            }
            if (r_is_objc_ptr(gStripPickerOverlayWin))
                stagestrip_hide_picker_overlay_animated();
            return cmd;
        }

        case kStripPickerCmdSwap: {
            uint64_t newTopStr    = r_nsstr_retained(bottom);
            uint64_t newBottomStr = r_nsstr_retained(top);
            if (r_is_objc_ptr(gStripPickerTopLabel) && r_is_objc_ptr(newTopStr))
                r_msg2_main(gStripPickerTopLabel, "setText:", newTopStr, 0, 0, 0);
            if (r_is_objc_ptr(gStripPickerBottomLabel) && r_is_objc_ptr(newBottomStr))
                r_msg2_main(gStripPickerBottomLabel, "setText:", newBottomStr, 0, 0, 0);

            char dispTop[96] = {0};
            char dispBottom[96] = {0};
            if (!stagestrip_lookup_app_localized_name(bottom, dispTop, sizeof(dispTop))
                || !dispTop[0])
                stagestrip_bid_short_name(bottom, dispTop, sizeof(dispTop));
            if (!stagestrip_lookup_app_localized_name(top, dispBottom, sizeof(dispBottom))
                || !dispBottom[0])
                stagestrip_bid_short_name(top, dispBottom, sizeof(dispBottom));
            uint64_t topChipStr = r_nsstr_retained(dispTop[0] ? dispTop : "—");
            uint64_t botChipStr = r_nsstr_retained(dispBottom[0] ? dispBottom : "—");
            if (r_is_objc_ptr(gStripPickerTopChip) && r_is_objc_ptr(topChipStr))
                r_msg2_main(gStripPickerTopChip, "setText:", topChipStr, 0, 0, 0);
            if (r_is_objc_ptr(gStripPickerBottomChip) && r_is_objc_ptr(botChipStr))
                r_msg2_main(gStripPickerBottomChip, "setText:", botChipStr, 0, 0, 0);

            if (bottom[0]) {
                uint64_t topIcon = stagestrip_fetch_icon_image(bottom);
                if (r_is_objc_ptr(gStripPickerTopIcon) && r_is_objc_ptr(topIcon))
                    r_msg2_main(gStripPickerTopIcon, "setImage:", topIcon, 0, 0, 0);
            }
            if (top[0]) {
                uint64_t botIcon = stagestrip_fetch_icon_image(top);
                if (r_is_objc_ptr(gStripPickerBottomIcon) && r_is_objc_ptr(botIcon))
                    r_msg2_main(gStripPickerBottomIcon, "setImage:", botIcon, 0, 0, 0);
            }

            if (r_is_objc_ptr(newTopStr))    r_msg2_main(newTopStr,    "release", 0, 0, 0, 0);
            if (r_is_objc_ptr(newBottomStr)) r_msg2_main(newBottomStr, "release", 0, 0, 0, 0);
            if (r_is_objc_ptr(topChipStr))   r_msg2_main(topChipStr,   "release", 0, 0, 0, 0);
            if (r_is_objc_ptr(botChipStr))   r_msg2_main(botChipStr,   "release", 0, 0, 0, 0);
            printf("[STAGE] picker: swapped (top<->bottom)\n");
            return cmd;
        }

        case kStripPickerCmdSplit:
        case kStripPickerCmdStrip: {
            uint64_t win = gStripFloatWindow;
            uint64_t hostView = gStripFloatHostView;
            if (!r_is_objc_ptr(win) || !r_is_objc_ptr(hostView)) return cmd;
            CGRect b = UIScreen.mainScreen.bounds;
            double sw = isfinite(b.size.width)  && b.size.width  >= 200.0 ? b.size.width  : 390.0;
            double sh = isfinite(b.size.height) && b.size.height >= 200.0 ? b.size.height : 844.0;
            StripRect target = (cmd == kStripPickerCmdSplit)
                ? stagestrip_clamped_rect(8.0, 56.0, sw - 16.0, sh - 104.0, sw, sh)
                : stagestrip_clamped_rect(sw - 240.0 - 14.0, sh - 420.0 - 38.0,
                                          240.0, 420.0, sw, sh);
            stagestrip_animation_begin(0.20);
            stagestrip_set_frame_thread(win, target);
            uint64_t committedHost =
                stagestrip_resize_host_view_commit_for_slot(0, hostView, target.width, target.height);
            uint64_t sceneKey = r_sel("cyanideStageStripHostedScene");
            uint64_t hostedScene = (sceneKey && r_is_objc_ptr(committedHost))
                ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                               committedHost, sceneKey, 0, 0, 0, 0, 0, 0)
                : 0;
            if (!r_is_objc_ptr(hostedScene))
                stagestrip_relayout_stage_host_thread(committedHost, target.width, target.height);
            stagestrip_animation_commit();
            printf("[STAGE] picker: %s frame=(%.0f,%.0f %.0fx%.0f)\n",
                   cmd == kStripPickerCmdSplit ? "split" : "strip",
                   target.x, target.y, target.width, target.height);
            return cmd;
        }

        case kStripPickerCmdClose:
            if (r_is_objc_ptr(gStripPickerOverlayWin))
                stagestrip_hide_picker_overlay_animated();
            printf("[STAGE] picker: closed\n");
            return cmd;

        case kStripPickerCmdRespring: {
            // Gear icon on the picker → open the Cyanide settings app. (We
            // used to call FBSystemService -exitAndRelaunch:YES here to
            // respring SpringBoard, but that path is unreliable on iOS 26:
            // it either crashes the caller or tears down the RemoteCall
            // connection mid-call. Cyanide's settings UI has its own
            // respring button that uses the WebKit payload — the user can
            // hit that one after we foreground the app.)
            printf("[STAGE] picker: cog tapped — launching Cyanide app\n");
            stagestrip_hide_picker_overlay_animated();
            stagestrip_launch_foreground("com.zeroxjf.ios-cyanide1");
            return cmd;
        }

        case kStripPickerCmdShow:
            stagestrip_show_picker_overlay_animated();
            return cmd;

        case kStripPickerCmdSelectTop:
        case kStripPickerCmdSelectBot: {
            int newSlot = (cmd == kStripPickerCmdSelectTop) ? 0 : 1;
            gStripPickerNextSlot = newSlot;
            // Update chip card backgrounds: highlight the active one.
            uint64_t UIColor = r_class("UIColor");
            if (r_is_objc_ptr(UIColor) && r_responds(UIColor, "colorWithWhite:alpha:")) {
                double activeWhite = 1.0, activeAlpha = 0.14;
                double inactiveWhite = 1.0, inactiveAlpha = 0.06;
                uint64_t activeColor = r_msg2_main_raw(UIColor, "colorWithWhite:alpha:",
                                                       &activeWhite, sizeof(activeWhite),
                                                       &activeAlpha, sizeof(activeAlpha),
                                                       NULL, 0, NULL, 0);
                uint64_t inactiveColor = r_msg2_main_raw(UIColor, "colorWithWhite:alpha:",
                                                         &inactiveWhite, sizeof(inactiveWhite),
                                                         &inactiveAlpha, sizeof(inactiveAlpha),
                                                         NULL, 0, NULL, 0);
                uint64_t topCard = gStripPickerTopChipCard;
                uint64_t botCard = gStripPickerBottomChipCard;
                if (r_is_objc_ptr(topCard))
                    r_msg2_main(topCard, "setBackgroundColor:",
                                newSlot == 0 ? activeColor : inactiveColor, 0, 0, 0);
                if (r_is_objc_ptr(botCard))
                    r_msg2_main(botCard, "setBackgroundColor:",
                                newSlot == 1 ? activeColor : inactiveColor, 0, 0, 0);
            }
            printf("[STAGE] picker: next slot = %s\n", newSlot == 0 ? "top" : "bottom");
            return cmd;
        }

        case kStripPickerCmdIconTap: {
            // User tapped a tile. Pending bid label has the chosen bundle id.
            char pendingBid[128] = {0};
            if (r_is_objc_ptr(gStripPickerPendingBidLabel))
                stagestrip_read_picker_label(gStripPickerPendingBidLabel,
                                             pendingBid, sizeof(pendingBid));
            if (!pendingBid[0]) {
                printf("[STAGE] picker: icon-tap with empty pending bid\n");
                return cmd;
            }

            int slot = gStripPickerNextSlot;
            printf("[STAGE] picker: icon-tap bid=%s -> slot=%s\n",
                   pendingBid, slot == 0 ? "top" : "bottom");

            // Assign the chosen bid to the target slot: hidden bid label,
            // visible chip text, and chip icon.
            char dispName[96] = {0};
            if (!stagestrip_lookup_app_localized_name(pendingBid, dispName, sizeof(dispName))
                || !dispName[0])
                stagestrip_bid_short_name(pendingBid, dispName, sizeof(dispName));
            char chipText[96] = {0};
            snprintf(chipText, sizeof(chipText), "%s: %s",
                     slot == 0 ? "Top" : "Bottom",
                     dispName[0] ? dispName : pendingBid);

            uint64_t bidStr = r_nsstr_retained(pendingBid);
            uint64_t chipStr = r_nsstr_retained(chipText);

            uint64_t hiddenLabel = (slot == 0) ? gStripPickerTopLabel : gStripPickerBottomLabel;
            uint64_t chipLabel   = (slot == 0) ? gStripPickerTopChip  : gStripPickerBottomChip;
            uint64_t iconView    = (slot == 0) ? gStripPickerTopIcon  : gStripPickerBottomIcon;

            if (r_is_objc_ptr(hiddenLabel) && r_is_objc_ptr(bidStr))
                r_msg2_main(hiddenLabel, "setText:", bidStr, 0, 0, 0);
            if (r_is_objc_ptr(chipLabel) && r_is_objc_ptr(chipStr))
                r_msg2_main(chipLabel, "setText:", chipStr, 0, 0, 0);

            uint64_t iconImage = stagestrip_fetch_icon_image(pendingBid);
            if (r_is_objc_ptr(iconView) && r_is_objc_ptr(iconImage))
                r_msg2_main(iconView, "setImage:", iconImage, 0, 0, 0);

            if (r_is_objc_ptr(bidStr))  r_msg2_main(bidStr,  "release", 0, 0, 0, 0);
            if (r_is_objc_ptr(chipStr)) r_msg2_main(chipStr, "release", 0, 0, 0, 0);

            // Clear the pending label so subsequent reads can't replay it.
            uint64_t empty = r_nsstr_retained("");
            if (r_is_objc_ptr(empty)) {
                r_msg2_main(gStripPickerPendingBidLabel, "setText:", empty, 0, 0, 0);
                r_msg2_main(empty, "release", 0, 0, 0, 0);
            }

            // Auto-advance: if we just filled top, next tap fills bottom and
            // vice-versa. Update card highlight too.
            int nextSlot = 1 - slot;
            gStripPickerNextSlot = nextSlot;
            uint64_t UIColor = r_class("UIColor");
            if (r_is_objc_ptr(UIColor) && r_responds(UIColor, "colorWithWhite:alpha:")) {
                double activeWhite = 1.0, activeAlpha = 0.14;
                double inactiveWhite = 1.0, inactiveAlpha = 0.06;
                uint64_t activeColor = r_msg2_main_raw(UIColor, "colorWithWhite:alpha:",
                                                       &activeWhite, sizeof(activeWhite),
                                                       &activeAlpha, sizeof(activeAlpha),
                                                       NULL, 0, NULL, 0);
                uint64_t inactiveColor = r_msg2_main_raw(UIColor, "colorWithWhite:alpha:",
                                                         &inactiveWhite, sizeof(inactiveWhite),
                                                         &inactiveAlpha, sizeof(inactiveAlpha),
                                                         NULL, 0, NULL, 0);
                if (r_is_objc_ptr(gStripPickerTopChipCard))
                    r_msg2_main(gStripPickerTopChipCard, "setBackgroundColor:",
                                nextSlot == 0 ? activeColor : inactiveColor, 0, 0, 0);
                if (r_is_objc_ptr(gStripPickerBottomChipCard))
                    r_msg2_main(gStripPickerBottomChipCard, "setBackgroundColor:",
                                nextSlot == 1 ? activeColor : inactiveColor, 0, 0, 0);
            }

            // Auto-apply: if both slots are populated with distinct bids,
            // immediately commit the pair. Mirrors StageDuo's "tap and the
            // app appears" UX — no explicit Apply button needed.
            // Use local vars: slot was just written with pendingBid; the other
            // slot still holds the value read from SpringBoard at poll entry.
            char topAfter[128] = {0};
            char botAfter[128] = {0};
            strncpy(slot == 0 ? topAfter : botAfter, pendingBid, 127);
            strncpy(slot == 1 ? topAfter : botAfter, slot == 0 ? bottom : top, 127);
            if (topAfter[0] && botAfter[0] && strcmp(topAfter, botAfter) != 0) {
                if (strcmp(topAfter, gStripPickerTopBid) != 0 ||
                    strcmp(botAfter, gStripPickerBottomBid) != 0) {
                    printf("[STAGE] picker: auto-apply top=%s bottom=%s\n", topAfter, botAfter);
                    if (r_is_objc_ptr(gStripPickerOverlayWin))
                        stagestrip_hide_picker_overlay_animated();
                    stagestrip_apply_picker_selection(topAfter, botAfter);
                }
            }
            return cmd;
        }

        default:
            printf("[STAGE] picker: unknown cmd=%d\n", cmd);
            return cmd;
    }
}

void stagestrip_start_control_loop(void)
{
    if (!__sync_bool_compare_and_swap(&gStripControlLoopRunning, 0, 1))
        return;

    gStripControlLoopStop = 0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint32_t oldSettle = r_settle_us(0);
        // Per-slot gesture state. `activeCorner` tracks which of the 4 resize
        // corners is currently driving the resize (-1 = none).
        bool moveActive[kStripMaxFloatSlots] = {false};
        bool resizeActive[kStripMaxFloatSlots] = {false};
        int  activeCorner[kStripMaxFloatSlots] = {-1, -1};
        StripRect moveStart[kStripMaxFloatSlots] = {{0}};
        StripRect resizeStart[kStripMaxFloatSlots] = {{0}};
        StripRect lastResize[kStripMaxFloatSlots] = {{0}};
        uint64_t resizeCover[kStripMaxFloatSlots] = {0};
        int resizeRelayoutTick[kStripMaxFloatSlots] = {0};

        bool loggedReady = false;
        int pickerPollTick = 0;
        uint64_t pickerBlockedUntilMS = 0;

        uint64_t selState    = r_sel("state");
        uint64_t selIsHidden = r_sel("isHidden");

        printf("[STAGE] control: loop started selState=0x%llx\n", selState);
        while (!gStripControlLoopStop) {
            bool havePicker = r_is_objc_ptr(gStripPickerPanel);
            bool anyFloatAlive = false;
            for (int s = 0; s < kStripMaxFloatSlots; s++) {
                StripFloatSlot *S = &gStripFloatSlots[s];
                if (r_is_objc_ptr(S->window) && r_is_objc_ptr(S->hostView) &&
                    r_is_objc_ptr(S->movePan) && r_is_objc_ptr(S->resizePan)) {
                    anyFloatAlive = true;
                    break;
                }
            }

            if (!anyFloatAlive && !havePicker) {
                usleep(50000);
                continue;
            }

            bool screenInactive = stagestrip_screen_inactive();
            static bool wasScreenInactiveHidden = false;
            if (screenInactive && !wasScreenInactiveHidden) {
                for (int s = 0; s < kStripMaxFloatSlots; s++) {
                    if (r_is_objc_ptr(gStripFloatSlots[s].window))
                        r_msg2_main(gStripFloatSlots[s].window, "setHidden:", 1, 0, 0, 0);
                }
                if (r_is_objc_ptr(gStripPickerOverlayWin))
                    r_msg2_main(gStripPickerOverlayWin, "setHidden:", 1, 0, 0, 0);
                wasScreenInactiveHidden = true;
                printf("[STAGE] control: hid stage windows for lock/sleep\n");
            }
            if (!screenInactive && wasScreenInactiveHidden) {
                for (int s = 0; s < kStripMaxFloatSlots; s++) {
                    StripFloatSlot *S = &gStripFloatSlots[s];
                    if (r_is_objc_ptr(S->window) && r_is_objc_ptr(S->hostView))
                        r_msg2_main(S->window, "setHidden:", 0, 0, 0, 0);
                }
                wasScreenInactiveHidden = false;
                printf("[STAGE] control: restored stage windows after unlock/wake\n");
            }
            if (screenInactive) {
                usleep(200000);
                continue;
            }

            if (!loggedReady) {
                printf("[STAGE] control: ready havePicker=%d slot0=0x%llx slot1=0x%llx\n",
                       havePicker ? 1 : 0,
                       gStripFloatSlots[0].window, gStripFloatSlots[1].window);
                loggedReady = true;
            }

            CGRect b = UIScreen.mainScreen.bounds;
            double sw = isfinite(b.size.width) && b.size.width >= 200.0 ? b.size.width : 390.0;
            double sh = isfinite(b.size.height) && b.size.height >= 200.0 ? b.size.height : 844.0;

            bool anyActive = false;
            bool anyGestureBusy = false;

            // Iterate over each slot, polling its gesture state independently.
            for (int s = 0; s < kStripMaxFloatSlots; s++) {
                StripFloatSlot *S = &gStripFloatSlots[s];
                uint64_t win = S->window;
                uint64_t hostView = S->hostView;
                uint64_t movePan = S->movePan;
                uint64_t resizePan = S->resizePan;
                uint64_t translationView = r_is_objc_ptr(S->referenceView)
                    ? S->referenceView
                    : win;

                bool haveFloat = r_is_objc_ptr(win) && r_is_objc_ptr(hostView) &&
                                 r_is_objc_ptr(movePan) && r_is_objc_ptr(resizePan);
                if (!haveFloat) {
                    if (r_is_objc_ptr(resizeCover[s])) {
                        r_msg2_main(resizeCover[s], "removeFromSuperview", 0, 0, 0, 0);
                        resizeCover[s] = 0;
                    }
                    moveActive[s] = false;
                    resizeActive[s] = false;
                    continue;
                }

                // Was this slot closed (X-button tap, auto-close, etc.)?
                // The window/host gets setHidden:YES on close; the control loop
                // sees the hidden state here and finishes teardown.
                uint64_t winHidden = r_msg(win, selIsHidden, 0, 0, 0, 0);
                if (winHidden) {
                    if (stagestrip_screen_inactive()) {
                        moveActive[s] = false;
                        resizeActive[s] = false;
                        continue;
                    }
                    if (r_is_objc_ptr(resizeCover[s])) {
                        r_msg2_main(resizeCover[s], "removeFromSuperview", 0, 0, 0, 0);
                        resizeCover[s] = 0;
                    }
                    moveActive[s] = false;
                    resizeActive[s] = false;
                    stagestrip_teardown_slot(s);
                    continue;
                }

                uint64_t moveState = (moveActive[s] || !resizeActive[s])
                    ? r_msg(movePan, selState, 0, 0, 0, 0) : 0;

                // Poll each corner's pan recognizer. We treat the FIRST corner
                // we find in began/changed as the active one; the others get
                // skipped this tick.
                uint64_t cornerStates[kStripCornerCount] = {0};
                int detectedCorner = -1;
                for (int c = 0; c < kStripCornerCount; c++) {
                    uint64_t pan = S->cornerPans[c];
                    if (!r_is_objc_ptr(pan)) continue;
                    uint64_t st = (resizeActive[s] && activeCorner[s] != c)
                        ? 0   // ignore inactive corners while another corner is dragging
                        : r_msg(pan, selState, 0, 0, 0, 0);
                    cornerStates[c] = st;
                    if (detectedCorner < 0 && (st == 1 || st == 2)) detectedCorner = c;
                }
                uint64_t resizeState = (activeCorner[s] >= 0)
                    ? cornerStates[activeCorner[s]]
                    : (detectedCorner >= 0 ? cornerStates[detectedCorner] : 0);

                if ((moveState == 1 || (!moveActive[s] && moveState == 2)) &&
                    stagestrip_get_frame_thread(win, &moveStart[s])) {
                    moveActive[s] = true;
                    printf("[STAGE] control[%d]: move begin frame=(%.0f,%.0f %.0fx%.0f)\n",
                           s, moveStart[s].x, moveStart[s].y, moveStart[s].width, moveStart[s].height);
                }
                if (moveActive[s] && stagestrip_pan_state_is_active(moveState)) {
                    StripPoint t = {0};
                    if (stagestrip_get_translation_thread(movePan, translationView, &t)) {
                        StripRect next = stagestrip_clamped_rect(moveStart[s].x + t.x,
                                                                moveStart[s].y + t.y,
                                                                moveStart[s].width,
                                                                moveStart[s].height,
                                                                sw, sh);
                        stagestrip_set_center_thread(win, (StripPoint){
                            next.x + next.width / 2.0,
                            next.y + next.height / 2.0
                        });
                        anyActive = true;
                    }
                }
                if (moveActive[s] && !stagestrip_pan_state_is_active(moveState)) {
                    moveActive[s] = false;
                    printf("[STAGE] control[%d]: move end state=%llu\n", s, moveState);
                }

                // Resize-begin: pick the corner that just fired. Bring arcs
                // back to translucent-visible state if they were hidden.
                if (!resizeActive[s] && detectedCorner >= 0 &&
                    stagestrip_get_frame_thread(win, &resizeStart[s])) {
                    resizeActive[s] = true;
                    activeCorner[s] = detectedCorner;
                    lastResize[s] = resizeStart[s];
                    resizeRelayoutTick[s] = 0;
                    if (r_is_objc_ptr(resizeCover[s])) {
                        r_msg2_main(resizeCover[s], "removeFromSuperview", 0, 0, 0, 0);
                        resizeCover[s] = 0;
                    }
                    uint64_t hostSuperview = r_responds(hostView, "superview")
                        ? r_msg2_main(hostView, "superview", 0, 0, 0, 0)
                        : 0;
                    if (r_is_objc_ptr(hostSuperview) &&
                        r_responds(hostView, "snapshotViewAfterScreenUpdates:")) {
                        uint64_t cover = r_msg2_main(hostView,
                                                     "snapshotViewAfterScreenUpdates:",
                                                     0, 0, 0, 0);
                        if (r_is_objc_ptr(cover)) {
                            double bi = kStripBorderInset;
                            double iw = resizeStart[s].width - 2.0 * bi;
                            double ih = resizeStart[s].height - 2.0 * bi;
                            if (iw < 80.0) iw = 80.0;
                            if (ih < 80.0) ih = 80.0;
                            stagestrip_set_frame_thread(cover, (StripRect){ bi, bi, iw, ih });
                            r_msg2_main(cover, "setUserInteractionEnabled:", 0, 0, 0, 0);
                            r_msg2_main(cover, "setClipsToBounds:", 1, 0, 0, 0);
                            uint64_t coverLayer = r_msg2_main(cover, "layer", 0, 0, 0, 0);
                            if (r_is_objc_ptr(coverLayer))
                                stagestrip_send_double(coverLayer, "setCornerRadius:", kStripCornerRadius - bi);
                            r_msg2_main(hostSuperview, "addSubview:", cover, 0, 0, 0);
                            resizeCover[s] = cover;
                            stagestrip_raise_pan_handles_slot(S);
                        }
                    }
                    if (!S->cornerArcsVisible) {
                        for (int c = 0; c < kStripCornerCount; c++) {
                            if (r_is_objc_ptr(S->cornerArcs[c]))
                                stagestrip_send_double(S->cornerArcs[c], "setOpacity:", 0.92);
                        }
                        S->cornerArcsVisible = true;
                    }
                    static const char *cornerNames[] = {"TL","TR","BL","BR"};
                    printf("[STAGE] control[%d]: resize begin corner=%s frame=(%.0f,%.0f %.0fx%.0f)\n",
                           s, cornerNames[detectedCorner],
                           resizeStart[s].x, resizeStart[s].y,
                           resizeStart[s].width, resizeStart[s].height);
                }

                // Resize-changed: apply corner-specific frame math.
                if (resizeActive[s] && activeCorner[s] >= 0 &&
                    stagestrip_pan_state_is_active(resizeState)) {
                    uint64_t pan = S->cornerPans[activeCorner[s]];
                    StripPoint t = {0};
                    if (r_is_objc_ptr(pan) &&
                        stagestrip_get_translation_thread(pan, translationView, &t)) {
                        double nx = resizeStart[s].x;
                        double ny = resizeStart[s].y;
                        double nw = resizeStart[s].width;
                        double nh = resizeStart[s].height;
                        switch (activeCorner[s]) {
                        case kStripCornerTL: nx += t.x; ny += t.y; nw -= t.x; nh -= t.y; break;
                        case kStripCornerTR:           ny += t.y; nw += t.x; nh -= t.y; break;
                        case kStripCornerBL: nx += t.x;            nw -= t.x; nh += t.y; break;
                        case kStripCornerBR:                       nw += t.x; nh += t.y; break;
                        default: break;
                        }
                        StripRect next = stagestrip_clamped_rect(nx, ny, nw, nh, sw, sh);
                        bool changed = fabs(next.width  - lastResize[s].width)  >= 2.0 ||
                                       fabs(next.height - lastResize[s].height) >= 2.0 ||
                                       fabs(next.x      - lastResize[s].x)      >= 2.0 ||
                                       fabs(next.y      - lastResize[s].y)      >= 2.0;
                        if (changed) {
                            stagestrip_set_frame_thread(win, next);
                            stagestrip_resize_host_view_frame(hostView, next.width, next.height);
                            if (r_is_objc_ptr(resizeCover[s])) {
                                double bi = kStripBorderInset;
                                double iw = next.width - 2.0 * bi;
                                double ih = next.height - 2.0 * bi;
                                if (iw < 80.0) iw = 80.0;
                                if (ih < 80.0) ih = 80.0;
                                stagestrip_set_frame_thread(resizeCover[s],
                                                           (StripRect){ bi, bi, iw, ih });
                            }
                            resizeRelayoutTick[s]++;
                            lastResize[s] = next;
                        }
                        anyActive = true;
                    }
                }

                // Resize-end: clear active corner and leave the resize affordances
                // visible. Hiding them makes later grabs feel dead, especially
                // with the smaller touch boxes.
                if (resizeActive[s] && !stagestrip_pan_state_is_active(resizeState)) {
                    static const char *cornerNames[] = {"TL","TR","BL","BR"};
                    printf("[STAGE] control[%d]: resize end corner=%s state=%llu\n",
                           s,
                           (activeCorner[s] >= 0 && activeCorner[s] < kStripCornerCount)
                               ? cornerNames[activeCorner[s]] : "?",
                           resizeState);
                    StripRect commitFrame = lastResize[s];
                    if (commitFrame.width < 100.0 || commitFrame.height < 100.0)
                        stagestrip_get_frame_thread(win, &commitFrame);
                    uint64_t committedHost =
                        stagestrip_resize_host_view_commit_for_slot(s, hostView,
                                                                    commitFrame.width,
                                                                    commitFrame.height);
                    if (r_is_objc_ptr(committedHost))
                        hostView = committedHost;
                    if (r_is_objc_ptr(resizeCover[s])) {
                        double bi = kStripBorderInset;
                        double iw = commitFrame.width - 2.0 * bi;
                        double ih = commitFrame.height - 2.0 * bi;
                        if (iw < 80.0) iw = 80.0;
                        if (ih < 80.0) ih = 80.0;
                        stagestrip_set_frame_thread(resizeCover[s],
                                                   (StripRect){ bi, bi, iw, ih });
                        r_msg2_main(win, "bringSubviewToFront:", resizeCover[s], 0, 0, 0);
                        stagestrip_schedule_invocation(win,
                            stagestrip_make_double_invocation(resizeCover[s], "setAlpha:", 0.0),
                            kStripResizeSwapRetireDelay);
                        stagestrip_schedule_invocation(win,
                            stagestrip_make_bool_invocation(resizeCover[s], "setHidden:", true),
                            kStripResizeSwapRetireDelay + 0.03);
                        stagestrip_schedule_invocation(win,
                            stagestrip_make_invocation(resizeCover[s], "removeFromSuperview", NULL, 0),
                            kStripResizeSwapRetireDelay + 0.05);
                        resizeCover[s] = 0;
                        stagestrip_raise_pan_handles_slot(S);
                    }
                    resizeActive[s] = false;
                    activeCorner[s] = -1;
                    for (int c = 0; c < kStripCornerCount; c++) {
                        if (r_is_objc_ptr(S->cornerArcs[c]))
                            stagestrip_send_double(S->cornerArcs[c], "setOpacity:", 0.92);
                    }
                    S->cornerArcsVisible = true;
                }

                if (moveActive[s] || resizeActive[s] ||
                    stagestrip_pan_state_is_active(moveState) ||
                    stagestrip_pan_state_is_active(resizeState)) {
                    anyGestureBusy = true;
                }
            }
            bool gestureBusy = anyActive || anyGestureBusy;
            uint64_t nowMS = stagestrip_now_ms();

            if (gestureBusy) {
                pickerBlockedUntilMS = nowMS + 500;
            } else if (gStripPickerCooldownUntilMS > pickerBlockedUntilMS) {
                pickerBlockedUntilMS = gStripPickerCooldownUntilMS;
            }

            if (!gestureBusy &&
                !gStripPickerApplyBusy &&
                nowMS >= pickerBlockedUntilMS &&
                (++pickerPollTick % 2) == 0) {
                if (stagestrip_poll_picker_command())
                    gStripPickerCooldownUntilMS = stagestrip_now_ms() + 1000;
            }

            // Process one deferred library tile per tick when idle. Skipped
            // whenever the user is mid-gesture so resize/move stays responsive.
            if (!gestureBusy && !gStripPickerApplyBusy) {
                stagestrip_control_loop_progress_library_build();
            }

            usleep(anyActive ? 16000 : 50000);
        }

        r_settle_us(oldSettle);
        gStripControlLoopStop = 0;
        __sync_lock_release(&gStripControlLoopRunning);
        printf("[STAGE] control: loop stopped settleRestored=%uus\n", oldSettle);
    });
}

// Asks the control loop to stop and waits up to 1.5 s (the registry's quick
// stop request). Returns whether it has exited.
bool stagestrip_stop_control_loop(void)
{
    gStripControlLoopStop = 1;
    for (int i = 0; i < 75 && gStripControlLoopRunning; i++)
        usleep(20000);
    return !gStripControlLoopRunning;
}

bool stagestrip_control_loop_running(void)
{
    return gStripControlLoopRunning != 0;
}

bool stagestrip_stop_in_session(void)
{
    // The teardown below clears state the loop reads and writes (live scenes,
    // float slots) and removes the SpringBoard objects it messages, so it may
    // only run once the loop has really exited. One of its remote calls can
    // take up to R_TIMEOUT to give up: wait past that before refusing.
    bool exited = stagestrip_stop_control_loop();
    for (int i = 0; !exited && i < (R_TIMEOUT * 1000 + 1500) / 20; i++) {
        usleep(20000);
        exited = !gStripControlLoopRunning;
    }
    if (!exited) {
        printf("[STAGE] stop: control loop still running after %ds; leaving its state alone\n", R_TIMEOUT + 3);
        return false;
    }
    stagestrip_clear_live_rendering_state();

    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) return false;
    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return false;

    uint64_t assocKey = r_sel("cyanideStageStripOverlayWindow");
    uint64_t win = assocKey ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                           app, assocKey, 0, 0, 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(win)) {
        r_msg2_main(win, "setHidden:", 1, 0, 0, 0);
        if (assocKey) {
            r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                         app, assocKey, 0, 1, 0, 0, 0, 0);
        }
    }
    // Also tear down the multitasking probe's floating host window.
    stagestrip_dismiss_floating_host();

    gStripWindow = 0;
    gStripContainer = 0;
    printf("[STAGE] stop: overlay torn down\n");
    return true;
}

void stagestrip_forget_remote_state(void)
{
    stagestrip_stop_control_loop();
    gStripLibraryBuildPending = 0;
    gStripWindow = 0;
    // The shield window is cached like the others but was only cleared by the
    // dismiss path: after a SpringBoard restart the next pick messaged an
    // address from the old process.
    gStripTransitionShieldWin = 0;
    gStripContainer = 0;
    gStripLaunchAddr = 0;
    gStripLiveScene = 0;
    memset(gStripLiveScenes, 0, sizeof(gStripLiveScenes));
    gStripLiveSceneCount = 0;
    gStripOpenMethodAdded = false;
    gStripApplyTick = 0;
    memset(gStripFloatSlots, 0, sizeof(gStripFloatSlots));
    gStripControlDrawer = 0;
    gStripPickerOverlayWin = 0;
    gStripPickerPanel = 0;
    gStripPickerTopLabel = 0;
    gStripPickerBottomLabel = 0;
    gStripPickerTopChip = 0;
    gStripPickerBottomChip = 0;
    gStripPickerTopIcon = 0;
    gStripPickerBottomIcon = 0;
    gStripPickerTopChipCard = 0;
    gStripPickerBottomChipCard = 0;
    gStripPickerPendingBidLabel = 0;
    gStripPickerNextSlot = 0;
    gStripPickerTopBid[0] = '\0';
    gStripPickerBottomBid[0] = '\0';
    gStripPickerApplyBusy = 0;
    gStripPickerCooldownUntilMS = 0;
    memset(gStripRows, 0, sizeof(gStripRows));
    memset(gStripLives, 0, sizeof(gStripLives));
    gHostViewHasAutoResizeMask = -1;
    gHostViewHasUpdateRefSize  = -1;
    gHostViewHasNeedsLayout    = -1;
    gHostViewHasLayoutIfNeeded = -1;
    printf("[STAGE] forgot remote state\n");
}

bool stagestrip_apply_in_session(int maxSlots)
{
    gStripApplyTick++;
    uint64_t startMS = stagestrip_now_ms();
    uint32_t oldSettleUS = r_settle_us(kStripApplySettleUS);
    if (stagestrip_should_log_tick()) {
        printf("[STAGE] === entry === maxSlots=%d tick=%d settle=%uus\n",
               maxSlots, gStripApplyTick, kStripApplySettleUS);
    }
    bool ok = stagestrip_install_or_refresh(maxSlots);
    r_settle_us(oldSettleUS);
    printf("[STAGE] === exit === ok=%d elapsed=%llums settleRestored=%uus\n",
           ok ? 1 : 0,
           (unsigned long long)(stagestrip_now_ms() - startMS),
           oldSettleUS);
    return ok;
}

bool stagestrip_apply(int maxSlots)
{
    if (init_remote_call("SpringBoard", false) != 0) {
        printf("[STAGE] init_remote_call(SpringBoard) failed\n");
        return false;
    }
    bool ok = stagestrip_apply_in_session(maxSlots);
    destroy_remote_call();
    return ok;
}
