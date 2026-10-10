//
//  axonlite.m
//  RemoteCall-only Axon-style notification grouping.
//

#import "axonlite.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import <signal.h>
#import <execinfo.h>

static volatile sig_atomic_t gAxonInCrashHandler = 0;
static char gAxonLastCallTag[256] = "<none>";

static void axn_crash_handler(int sig, siginfo_t *info, void *uap)
{
    (void)uap;
    if (gAxonInCrashHandler) {
        _exit(128 + sig);
    }
    gAxonInCrashHandler = 1;

    char header[128];
    int hdr = snprintf(header, sizeof(header),
                       "\n[AXONLITE/CRASH] sig=%d code=%d addr=%p lastCall=%s\n",
                       sig, info ? info->si_code : 0,
                       info ? info->si_addr : NULL,
                       gAxonLastCallTag);
    if (hdr > 0) (void)!write(STDERR_FILENO, header, (size_t)hdr);

    void *frames[64];
    int n = backtrace(frames, 64);
    backtrace_symbols_fd(frames, n, STDERR_FILENO);

    signal(sig, SIG_DFL);
    raise(sig);
}

static void axn_install_crash_handler_once(void)
{
    static bool installed = false;
    if (installed) return;
    installed = true;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = axn_crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &sa, NULL);
    }
    printf("[AXONLITE] crash handler installed\n");
}

#define AXN_TAG(fmt, ...) do { \
    snprintf(gAxonLastCallTag, sizeof(gAxonLastCallTag), fmt, ##__VA_ARGS__); \
} while (0)

typedef struct {
    double x;
    double y;
    double width;
    double height;
} AXNRect64;

typedef struct {
    char bundle[128];
    char title[64];
    int count;
} AXNBundle;

typedef struct {
    uint64_t request;
    uint64_t cell;
    uint64_t hiddenCell;
    char identifier[192];
    char bundle[128];
    char title[64];
    bool retained;
    bool hiddenByAxon;
    uint64_t lastSeenTick;
} AXNRequestEntry;

typedef struct {
    char bundle[128];
    uint64_t image;
} AXNIconCacheEntry;

static const int kAxonMaxRequests = 160;
static const int kAxonMaxBundles = 8;
static const int kAxonMaxSegments = kAxonMaxBundles + 1;
static const int kAxonMaxIconCache = 32;
static const int kAxonOverlayContainerTag = 0xA0A015;
static const int kAxonOverlayTag = 0xA0A016;
static const int kAxonOverlayBadgeTag = 0xA0A017;
static const double kAxonOverlayHeight = 56.0;
static const double kAxonOverlayMargin = 12.0;
static const double kAxonOverlayTopInsetFraction = 0.32;
static const double kAxonOverlayTopInsetMin = 230.0;
// Extra vertical breathing room we add to the notification list view's
// contentInset.top so the "Notification Center" header sits below our strip
// instead of underneath it.
// Vertical offset applied via setTransform: to the "Notification Center"
// section header view so it sits below our strip. Path on iOS 18.5:
// gAxonCLVC.listModel._historySectionList.headerView (NCNotificationListSectionHeaderView).
// CGAffineTransform survives layout; setFrame: would be re-asserted by
// NCNotificationListView _layoutHeaderViewIfNecessaryAtLayoutOffset:.
static const double kAxonNCHeaderTranslateY = 80.0;
static const int kAxonTargetedVisitedLimit = 40;
static const int kAxonScanChildLimit = 4;
static const int kAxonScanWindowLimit = 10;
static const int kAxonCacheDepthLimit = 7;
static const int kAxonRootItemLimit = 48;
static const uint32_t kAxonRemoteSettleUS = 5000;

static AXNRequestEntry gAxonRequests[kAxonMaxRequests];
static AXNIconCacheEntry gAxonIconCache[kAxonMaxIconCache];
static AXNBundle gAxonBundleRoster[kAxonMaxBundles];
static int gAxonIconCacheCount = 0;
static int gAxonRequestCount = 0;
static int gAxonBundleRosterCount = 0;
static uint64_t gAxonTick = 0;
static uint64_t gAxonCLVC = 0;
static uint64_t gAxonCombined = 0;
static uint64_t gAxonCoverSheetWindow = 0;
static uint64_t gAxonWindow = 0;
static uint64_t gAxonHostView = 0;
static uint64_t gAxonControl = 0;
static uint64_t gAxonBadgeView = 0;
static uint64_t gAxonSpinner = 0;
static int gAxonSpinnerHoldTicks = 0;
static uint64_t gAxonModelOwnerCLVC = 0;
static uint64_t gAxonListModel = 0;
static uint64_t gAxonListCache = 0;
static uint64_t gAxonCellsForRequests = 0;
static bool gAxonControlCanSelect = false;
static char gAxonSelectedBundle[128] = "";
static char gAxonDisplayedBundles[kAxonMaxSegments][128];
static int gAxonDisplayedCount = 0;
static char gAxonSegmentSignature[1024] = "";
static char gAxonBadgeSignature[1024] = "";
static bool gAxonLoggedControllerMiss = false;
static uint64_t gAxonScanCursor = 0;
static uint64_t gAxonStructuredClass = 0;
static uint64_t gAxonCombinedClass = 0;
static uint64_t gAxonCSCombinedClass = 0;
static uint64_t gAxonCSCoverSheetClass = 0;
static uint64_t gAxonCSMainPageClass = 0;
static uint64_t gAxonBadgedIconViewClass = 0;
static bool gAxonStructuredClassTried = false;
static bool gAxonCombinedClassTried = false;
static bool gAxonCSCombinedClassTried = false;
static bool gAxonCSCoverSheetClassTried = false;
static bool gAxonCSMainPageClassTried = false;
static bool gAxonBadgedIconViewClassTried = false;
static int gAxonIconHydrateLogBudget = 16;
static int gAxonShapeLogBudget = 0;
static int gAxonRequestFailLogBudget = 8;
static int gAxonRootLogBudget = 40;
static int gAxonModelFallbackLogBudget = 6;
static int gAxonItemLogBudget = 16;
static int gAxonListCacheLogBudget = 8;
static int gAxonListViewLogBudget = 16;
static int gAxonListCacheEntryLogBudget = 4;
static int gAxonRequestCacheLogBudget = 16;
static bool gAxonLegacyWindowCleaned = false;

typedef enum {
    AXNIvarListModel = 0,
    AXNIvarNotificationListCache,
    AXNIvarCellsForRequests,
    AXNIvarSectionIdentifier,
    AXNIvarParentSectionIdentifier,
    AXNIvarContent,
    AXNIvarIcon,
    AXNIvarNotificationIdentifier,
    AXNIvarHeader,
    AXNIvarTitle,
    AXNIvarCustomHeader,
    AXNIvarDefaultHeader,
    AXNIvarBulletin,
    AXNIvarSectionID,
    AXNIvarSectionDisplayName,
    AXNIvarCellContentViewController,
    AXNIvarLookView,
    AXNIvarNotificationContentView,
    AXNIvarBadgedIconView,
    AXNIvarMax
} AXNIvarSlot;

typedef struct {
    uint64_t cls;
    int64_t offset;
    bool tried;
} AXNIvarCacheEntry;

static AXNIvarCacheEntry gAxonIvars[AXNIvarMax];

typedef enum {
    AXNSelRespondsToSelector = 0,
    AXNSelIsKindOfClass,
    AXNSelSharedApplication,
    AXNSelWindows,
    AXNSelRootViewController,
    AXNSelPresentedViewController,
    AXNSelChildViewControllers,
    AXNSelViewControllers,
    AXNSelCount,
    AXNSelObjectAtIndex,
    AXNSelAllKeys,
    AXNSelObjectForKey,
    AXNSelMainPageContentViewController,
    AXNSelCombinedListViewController,
    AXNSelStructuredListViewController,
    AXNSelNotificationListViewController,
    AXNSelRevealNotificationHistory,
    AXNSelAllNotificationRequests,
    AXNSelRemoveNotificationRequestCoalesced,
    AXNSelRemoveNotificationRequest,
    AXNSelMax
} AXNSelSlot;

static uint64_t gAxonSels[AXNSelMax];

static uint64_t axn_sel_cached(AXNSelSlot slot, const char *name)
{
    if (slot < 0 || slot >= AXNSelMax) return 0;
    if (!gAxonSels[slot]) gAxonSels[slot] = r_sel(name);
    return gAxonSels[slot];
}

static uint64_t axn_class_cached(uint64_t *slot, bool *tried, const char *name)
{
    if (!slot || !tried || !name) return 0;
    if (!*tried) {
        *slot = r_class(name);
        *tried = true;
    }
    return *slot;
}

static uint64_t axn_ivar_value_cached(uint64_t obj, AXNIvarSlot slot, const char *name)
{
    if (!r_is_objc_ptr(obj) || slot < 0 || slot >= AXNIvarMax || !name) return 0;

    uint64_t cls = r_dlsym_call(R_TIMEOUT, "object_getClass", obj, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(cls)) return 0;

    AXNIvarCacheEntry *entry = &gAxonIvars[slot];
    if (!entry->tried || entry->cls != cls) {
        entry->cls = cls;
        entry->offset = -1;
        entry->tried = true;

        uint64_t nameBuf = r_alloc_str(name);
        if (!nameBuf) return 0;
        uint64_t ivar = r_dlsym_call(R_TIMEOUT, "class_getInstanceVariable",
                                     cls, nameBuf, 0, 0, 0, 0, 0, 0);
        r_free(nameBuf);
        if (ivar) {
            entry->offset = (int64_t)r_dlsym_call(R_TIMEOUT, "ivar_getOffset",
                                                  ivar, 0, 0, 0, 0, 0, 0, 0);
        }
    }

    if (entry->offset < 0) return 0;
    return remote_read64(obj + (uint64_t)entry->offset);
}

static bool axn_responds_sel_main(uint64_t obj, AXNSelSlot slot, const char *name)
{
    if (!r_is_objc_ptr(obj)) return false;
    uint64_t sel = axn_sel_cached(slot, name);
    uint64_t respondsSel = axn_sel_cached(AXNSelRespondsToSelector, "respondsToSelector:");
    if (!sel || !respondsSel) return false;
    uint64_t result = r_msg_main(obj, respondsSel, sel, 0, 0, 0);
    return (result & 0xff) != 0;
}

static uint64_t axn_msg0_main_cached(uint64_t obj, AXNSelSlot slot, const char *name)
{
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t sel = axn_sel_cached(slot, name);
    if (!sel) return 0;
    return r_msg_main(obj, sel, 0, 0, 0, 0);
}

static uint64_t axn_msg0_cached(uint64_t obj, AXNSelSlot slot, const char *name)
{
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t sel = axn_sel_cached(slot, name);
    if (!sel) return 0;
    return r_msg(obj, sel, 0, 0, 0, 0);
}

static uint64_t axn_msg1_main_cached(uint64_t obj, AXNSelSlot slot, const char *name, uint64_t arg)
{
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t sel = axn_sel_cached(slot, name);
    if (!sel) return 0;
    return r_msg_main(obj, sel, arg, 0, 0, 0);
}

static uint64_t axn_msg1_cached(uint64_t obj, AXNSelSlot slot, const char *name, uint64_t arg)
{
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t sel = axn_sel_cached(slot, name);
    if (!sel) return 0;
    return r_msg(obj, sel, arg, 0, 0, 0);
}

static bool axn_object_class_name(uint64_t obj, char *out, size_t outLen)
{
    if (!r_is_objc_ptr(obj) || !out || outLen == 0) return false;
    out[0] = '\0';

    uint64_t cls = r_dlsym_call(R_TIMEOUT, "object_getClass", obj, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(cls)) return false;
    uint64_t name = r_dlsym_call(R_TIMEOUT, "class_getName", cls, 0, 0, 0, 0, 0, 0, 0);
    if (!name) return false;

    uint64_t heapName = r_dlsym_call(R_TIMEOUT, "strdup", name, 0, 0, 0, 0, 0, 0, 0);
    if (!heapName) return false;
    bool ok = remote_read(heapName, out, outLen - 1);
    r_free(heapName);
    if (ok) out[outLen - 1] = '\0';
    return ok && out[0] != '\0';
}

static bool axn_object_class_contains(uint64_t obj, const char *needle)
{
    if (!needle || !needle[0]) return false;
    char cls[128];
    if (!axn_object_class_name(obj, cls, sizeof(cls))) return false;
    return strstr(cls, needle) != NULL;
}

static bool axn_is_supplementary_object(uint64_t obj)
{
    return axn_object_class_contains(obj, "SupplementaryViews");
}

static bool axn_object_looks_like_request(uint64_t obj)
{
    if (!r_is_objc_ptr(obj)) return false;

    char cls[128];
    if (axn_object_class_name(obj, cls, sizeof(cls)) &&
        strstr(cls, "NCNotificationRequest") &&
        !strstr(cls, "Provider")) {
        return true;
    }

    bool hasIdentifier = r_responds(obj, "notificationIdentifier");
    bool hasPayload = r_responds(obj, "content") || r_responds(obj, "bulletin");
    return hasIdentifier && hasPayload;
}

static void axn_log_object_shape(const char *label, uint64_t obj)
{
    if (!label) return;
    if (!r_is_objc_ptr(obj)) {
        printf("[AXONLITE] shape %s=0x%llx class=nil count=0\n", label, obj);
        return;
    }

    char cls[96];
    if (!axn_object_class_name(obj, cls, sizeof(cls))) snprintf(cls, sizeof(cls), "?");
    uint64_t count = r_responds(obj, "count") ? r_msg2(obj, "count", 0, 0, 0, 0) : 0;
    printf("[AXONLITE] shape %s=0x%llx class=%s count=%llu\n",
           label, obj, cls, (unsigned long long)count);
}

static void axn_release_remote_obj(uint64_t obj)
{
    if (r_is_objc_ptr(obj)) r_msg2(obj, "release", 0, 0, 0, 0);
}

static uint64_t axn_try_msg0(uint64_t obj, const char *selName)
{
    if (!r_is_objc_ptr(obj) || !r_responds(obj, selName)) return 0;
    return r_msg2(obj, selName, 0, 0, 0, 0);
}

static uint64_t axn_try_msg0_or_ivar(uint64_t obj, const char *selName, const char *ivarName)
{
    uint64_t value = axn_try_msg0(obj, selName);
    if (!r_is_objc_ptr(value) && ivarName) value = r_ivar_value(obj, ivarName);
    return r_is_objc_ptr(value) ? value : 0;
}

static uint64_t axn_try_msg0_main(uint64_t obj, const char *selName)
{
    if (!r_is_objc_ptr(obj) || !r_responds_main(obj, selName)) return 0;
    return r_msg2_main(obj, selName, 0, 0, 0, 0);
}

static bool axn_is_kind_of_named_class(uint64_t obj, const char *className)
{
    if (!r_is_objc_ptr(obj) || !className || !className[0]) return false;
    uint64_t cls = 0;
    if (strcmp(className, "NCNotificationStructuredListViewController") == 0) {
        cls = axn_class_cached(&gAxonStructuredClass, &gAxonStructuredClassTried, className);
    } else if (strcmp(className, "NCNotificationCombinedListViewController") == 0) {
        cls = axn_class_cached(&gAxonCombinedClass, &gAxonCombinedClassTried, className);
    } else if (strcmp(className, "CSCombinedListViewController") == 0) {
        cls = axn_class_cached(&gAxonCSCombinedClass, &gAxonCSCombinedClassTried, className);
    } else if (strcmp(className, "CSCoverSheetViewController") == 0) {
        cls = axn_class_cached(&gAxonCSCoverSheetClass, &gAxonCSCoverSheetClassTried, className);
    } else if (strcmp(className, "CSMainPageContentViewController") == 0) {
        cls = axn_class_cached(&gAxonCSMainPageClass, &gAxonCSMainPageClassTried, className);
    } else {
        cls = r_class(className);
    }
    if (!r_is_objc_ptr(cls)) return false;
    uint64_t isKindSel = axn_sel_cached(AXNSelIsKindOfClass, "isKindOfClass:");
    if (!isKindSel) return false;
    uint64_t result = r_msg_main(obj, isKindSel, cls, 0, 0, 0);
    return (result & 0xff) != 0;
}

static bool gAxonControllerProbedOnce = false;
static bool gAxonClvcCanRemove = false;
static bool gAxonClvcCanInsert = false;
static bool gAxonClvcCanToggleFilter = false;
static bool gAxonClvcCanReveal = false;
static bool gAxonClvcCanListView = false;
static bool gAxonModelProbed = false;
static uint64_t gAxonModelProbedPtr = 0;
static bool gAxonModelCanToggleFilter = false;
static bool gAxonModelCanPrivateInsert = false;
static bool gAxonModelCanNotifyContentChange = false;
static bool gAxonCombinedProbedOnce = false;
static bool gAxonCombinedCanForceReveal = false;
static bool gAxonCombinedCanOverrideStyle = false;
static uint64_t gAxonDisplayStyleAssertion = 0;
static bool gAxonListInsetApplied = false;

static void axn_probe_list_model(uint64_t model)
{
    if (!r_is_objc_ptr(model)) {
        gAxonModelProbed = false;
        gAxonModelProbedPtr = 0;
        gAxonModelCanToggleFilter = false;
        gAxonModelCanPrivateInsert = false;
        gAxonModelCanNotifyContentChange = false;
        return;
    }
    if (gAxonModelProbed && gAxonModelProbedPtr == model) return;

    gAxonModelProbed = true;
    gAxonModelProbedPtr = model;
    gAxonModelCanToggleFilter = r_responds_main(model,
        "toggleFilteringForSectionIdentifier:shouldFilter:");
    gAxonModelCanPrivateInsert = r_responds_main(model, "_insertNotificationRequest:");
    gAxonModelCanNotifyContentChange = r_responds_main(model, "_notificationListDidChangeContent");

    char cls[96];
    axn_object_class_name(model, cls, sizeof(cls));
    printf("[AXONLITE] probe listModel=0x%llx class=%s toggleFilter=%d privateInsert=%d notifyChange=%d\n",
           (unsigned long long)model, cls,
           gAxonModelCanToggleFilter,
           gAxonModelCanPrivateInsert,
           gAxonModelCanNotifyContentChange);
}

static void axn_probe_controller_methods(uint64_t clvc, uint64_t combined)
{
    char cls[96];
    if (!gAxonControllerProbedOnce && r_is_objc_ptr(clvc)) {
        gAxonControllerProbedOnce = true;

        gAxonClvcCanRemove        = r_responds_main(clvc, "removeNotificationRequest:");
        gAxonClvcCanInsert        = r_responds_main(clvc, "insertNotificationRequest:");
        gAxonClvcCanToggleFilter  = r_responds_main(clvc, "toggleFilteringForSectionIdentifier:shouldFilter:");
        gAxonClvcCanReveal        = r_responds_main(clvc, "revealNotificationHistory:animated:");
        gAxonClvcCanListView      = r_responds_main(clvc, "listView");

        axn_object_class_name(clvc, cls, sizeof(cls));
        printf("[AXONLITE] probe clvc=0x%llx class=%s remove=%d insert=%d toggleFilter=%d reveal=%d listView=%d\n",
               (unsigned long long)clvc, cls,
               gAxonClvcCanRemove, gAxonClvcCanInsert,
               gAxonClvcCanToggleFilter, gAxonClvcCanReveal,
               gAxonClvcCanListView);
    }

    if (!gAxonCombinedProbedOnce && r_is_objc_ptr(combined)) {
        gAxonCombinedProbedOnce = true;
        gAxonCombinedCanForceReveal = r_responds_main(combined, "forceNotificationHistoryRevealed:animated:");
        gAxonCombinedCanOverrideStyle = r_responds_main(combined,
            "acquireOverrideNotificationListDisplayStyleAssertionWithStyle:hideNotificationCount:reason:");
        axn_object_class_name(combined, cls, sizeof(cls));
        printf("[AXONLITE] probe combined=0x%llx class=%s forceReveal=%d overrideStyle=%d\n",
               (unsigned long long)combined, cls,
               gAxonCombinedCanForceReveal, gAxonCombinedCanOverrideStyle);
    }
}

static bool axn_vc_looks_like_notification_list(uint64_t vc)
{
    if (!r_is_objc_ptr(vc)) return false;

    if (!axn_responds_sel_main(vc, AXNSelAllNotificationRequests, "allNotificationRequests")) {
        return false;
    }

    if (axn_is_kind_of_named_class(vc, "NCNotificationStructuredListViewController") ||
        axn_is_kind_of_named_class(vc, "NCNotificationCombinedListViewController")) {
        return true;
    }

    return axn_responds_sel_main(vc, AXNSelRemoveNotificationRequestCoalesced, "removeNotificationRequest:forCoalescedNotification:") ||
           axn_responds_sel_main(vc, AXNSelRemoveNotificationRequest, "removeNotificationRequest:");
}

static uint64_t axn_accept_list_controller(uint64_t vc, const char *via)
{
    if (!axn_vc_looks_like_notification_list(vc)) return 0;
    printf("[AXONLITE] list controller=0x%llx via %s\n", vc, via ? via : "?");
    return vc;
}

static uint64_t axn_structured_from_combined(uint64_t combined)
{
    if (!r_is_objc_ptr(combined)) return 0;

    uint64_t hit = axn_accept_list_controller(combined, "combined.self");
    if (hit) { gAxonCombined = combined; return hit; }

    uint64_t list = 0;
    if (axn_responds_sel_main(combined, AXNSelNotificationListViewController, "notificationListViewController")) {
        list = axn_msg0_main_cached(combined, AXNSelNotificationListViewController, "notificationListViewController");
        hit = axn_accept_list_controller(list, "combined.notificationListViewController");
        if (hit) { gAxonCombined = combined; return hit; }
    }

    list = r_ivar_value(combined, "_structuredListViewController");
    hit = axn_accept_list_controller(list, "combined._structuredListViewController");
    if (hit) { gAxonCombined = combined; return hit; }

    list = r_ivar_value(combined, "_notificationListViewController");
    hit = axn_accept_list_controller(list, "combined._notificationListViewController");
    if (hit) { gAxonCombined = combined; return hit; }

    return 0;
}

static uint64_t axn_combined_from_main_page(uint64_t mainPage)
{
    if (!r_is_objc_ptr(mainPage)) return 0;

    uint64_t combined = 0;
    if (axn_responds_sel_main(mainPage, AXNSelCombinedListViewController, "combinedListViewController")) {
        combined = axn_msg0_main_cached(mainPage, AXNSelCombinedListViewController, "combinedListViewController");
        if (r_is_objc_ptr(combined)) return combined;
    }

    combined = r_ivar_value(mainPage, "_combinedListViewController");
    return r_is_objc_ptr(combined) ? combined : 0;
}

static uint64_t axn_main_page_from_cover_sheet(uint64_t coverSheet)
{
    if (!r_is_objc_ptr(coverSheet)) return 0;

    uint64_t mainPage = 0;
    if (axn_responds_sel_main(coverSheet, AXNSelMainPageContentViewController, "mainPageContentViewController")) {
        mainPage = axn_msg0_main_cached(coverSheet, AXNSelMainPageContentViewController, "mainPageContentViewController");
        if (r_is_objc_ptr(mainPage)) return mainPage;
    }

    mainPage = r_ivar_value(coverSheet, "_mainPageContentViewController");
    return r_is_objc_ptr(mainPage) ? mainPage : 0;
}

static uint64_t axn_targeted_controller_from_vc(uint64_t vc, const char *source, int *visited)
{
    if (!r_is_objc_ptr(vc) || !visited || *visited >= kAxonTargetedVisitedLimit) return 0;
    (*visited)++;

    uint64_t hit = axn_accept_list_controller(vc, source);
    if (hit) return hit;

    if (axn_is_kind_of_named_class(vc, "CSCombinedListViewController") ||
        axn_responds_sel_main(vc, AXNSelNotificationListViewController, "notificationListViewController")) {
        hit = axn_structured_from_combined(vc);
        if (hit) return hit;
    }

    if (axn_is_kind_of_named_class(vc, "CSMainPageContentViewController") ||
        axn_responds_sel_main(vc, AXNSelCombinedListViewController, "combinedListViewController")) {
        uint64_t combined = axn_combined_from_main_page(vc);
        hit = axn_structured_from_combined(combined);
        if (hit) return hit;
    }

    if (axn_is_kind_of_named_class(vc, "CSCoverSheetViewController") ||
        axn_responds_sel_main(vc, AXNSelMainPageContentViewController, "mainPageContentViewController")) {
        uint64_t mainPage = axn_main_page_from_cover_sheet(vc);
        uint64_t combined = axn_combined_from_main_page(mainPage);
        hit = axn_structured_from_combined(combined);
        if (hit) return hit;
    }

    if (axn_responds_sel_main(vc, AXNSelStructuredListViewController, "structuredListViewController") ||
        axn_responds_sel_main(vc, AXNSelRevealNotificationHistory, "revealNotificationHistory:animated:")) {
        uint64_t structured = 0;
        if (axn_responds_sel_main(vc, AXNSelStructuredListViewController, "structuredListViewController")) {
            structured = axn_msg0_main_cached(vc, AXNSelStructuredListViewController, "structuredListViewController");
        }
        if (!r_is_objc_ptr(structured)) structured = r_ivar_value(vc, "_structuredListViewController");
        hit = axn_accept_list_controller(structured, "wrapper.structuredListViewController");
        if (hit) return hit;
    }

    return 0;
}

static bool axn_scan_class_interesting(const char *cls)
{
    if (!cls || !cls[0]) return false;
    return strstr(cls, "CoverSheet") ||
           strstr(cls, "NCNotification") ||
           strstr(cls, "CSMainPage") ||
           strstr(cls, "CSCombined") ||
           strstr(cls, "CSCoverSheet");
}

static void axn_log_candidate_controller(const char *label, uint64_t obj, uint64_t windowIndex)
{
    if (gAxonRootLogBudget <= 0) return;

    char cls[96];
    if (!axn_object_class_name(obj, cls, sizeof(cls))) snprintf(cls, sizeof(cls), "nil");
    printf("[AXONLITE] %s window=%llu vc=0x%llx class=%s\n",
           label ? label : "vc",
           (unsigned long long)windowIndex,
           (unsigned long long)obj,
           cls);
    gAxonRootLogBudget--;
}

static void axn_log_candidate_controller_class(const char *label, uint64_t obj,
                                               uint64_t windowIndex, const char *cls)
{
    if (gAxonRootLogBudget <= 0) return;
    printf("[AXONLITE] %s window=%llu vc=0x%llx class=%s\n",
           label ? label : "vc",
           (unsigned long long)windowIndex,
           (unsigned long long)obj,
           cls && cls[0] ? cls : "nil");
    gAxonRootLogBudget--;
}

static bool axn_candidate_class_name(uint64_t obj, char *cls, size_t clsLen)
{
    if (!cls || clsLen == 0) return false;
    if (!axn_object_class_name(obj, cls, clsLen)) snprintf(cls, clsLen, "nil");
    return axn_scan_class_interesting(cls);
}

static uint64_t axn_scan_controller_array(uint64_t controllers, const char *source, int *visited)
{
    if (!r_is_objc_ptr(controllers) || !visited || *visited >= kAxonTargetedVisitedLimit) return 0;

    uint64_t count = axn_msg0_main_cached(controllers, AXNSelCount, "count");
    if (count > kAxonScanChildLimit) count = kAxonScanChildLimit;
    for (uint64_t n = 0; n < count && *visited < kAxonTargetedVisitedLimit; n++) {
        uint64_t i = (count - 1) - n;
        uint64_t child = axn_msg1_main_cached(controllers, AXNSelObjectAtIndex, "objectAtIndex:", i);
        char cls[96];
        if (!axn_candidate_class_name(child, cls, sizeof(cls))) continue;
        uint64_t hit = axn_targeted_controller_from_vc(child, source, visited);
        if (hit) return hit;
    }
    return 0;
}

static uint64_t axn_scan_shallow_children(uint64_t vc, int *visited)
{
    if (!r_is_objc_ptr(vc) || !visited || *visited >= kAxonTargetedVisitedLimit) return 0;

    uint64_t children = axn_msg0_main_cached(vc, AXNSelChildViewControllers, "childViewControllers");
    uint64_t hit = axn_scan_controller_array(children, "childViewControllers", visited);
    if (hit) return hit;

    uint64_t viewControllers = axn_msg0_main_cached(vc, AXNSelViewControllers, "viewControllers");
    hit = axn_scan_controller_array(viewControllers, "viewControllers", visited);
    if (hit) return hit;
    return 0;
}

static int gAxonWarmupLogBudget = 24;

// Try every reachable entry from `root` (typically SBCoverSheetPrim…) to a
// CSCoverSheetViewController. iOS 18 doesn't add the cover-sheet child until
// presentation; we have to ask for it via known accessors instead.
static uint64_t axn_warmup_cover_sheet_from_root(uint64_t root, const char *rootCls)
{
    if (!r_is_objc_ptr(root)) return 0;

    // 1. Direct selector — present on SBCoverSheetPrimarySlidingViewController
    //    when the cover sheet is its managed child view controller.
    if (r_responds_main(root, "coverSheetViewController")) {
        uint64_t cs = r_msg2_main(root, "coverSheetViewController", 0, 0, 0, 0);
        if (r_is_objc_ptr(cs)) {
            if (gAxonWarmupLogBudget > 0) {
                printf("[AXONLITE] warmup: root=%s cs via selector=0x%llx\n", rootCls, cs);
                gAxonWarmupLogBudget--;
            }
            return cs;
        }
    }

    // 2. Direct ivar — works even when the lazy accessor hasn't materialized.
    uint64_t cs = r_ivar_value(root, "_coverSheetViewController");
    if (r_is_objc_ptr(cs)) {
        if (gAxonWarmupLogBudget > 0) {
            printf("[AXONLITE] warmup: root=%s cs via _coverSheetViewController ivar=0x%llx\n", rootCls, cs);
            gAxonWarmupLogBudget--;
        }
        return cs;
    }

    // 3. childViewControllers — works once the cover sheet has been added.
    uint64_t children = axn_msg0_main_cached(root, AXNSelChildViewControllers, "childViewControllers");
    uint64_t childCount = r_is_objc_ptr(children) ?
        axn_msg0_main_cached(children, AXNSelCount, "count") : 0;
    if (childCount > 32) childCount = 32;
    for (uint64_t c = 0; c < childCount; c++) {
        uint64_t child = axn_msg1_main_cached(children, AXNSelObjectAtIndex, "objectAtIndex:", c);
        if (!r_is_objc_ptr(child)) continue;
        char childCls[96];
        if (!axn_object_class_name(child, childCls, sizeof(childCls))) continue;
        if (strstr(childCls, "CSCoverSheet")) {
            if (gAxonWarmupLogBudget > 0) {
                printf("[AXONLITE] warmup: root=%s cs via childViewControllers[%llu]=0x%llx (%s)\n",
                       rootCls, c, child, childCls);
                gAxonWarmupLogBudget--;
            }
            return child;
        }
    }

    // 4. viewControllers — UIPageViewController-style containers may keep
    //    children here regardless of childViewControllers state.
    uint64_t vcs = axn_msg0_main_cached(root, AXNSelViewControllers, "viewControllers");
    uint64_t vcCount = r_is_objc_ptr(vcs) ?
        axn_msg0_main_cached(vcs, AXNSelCount, "count") : 0;
    if (vcCount > 32) vcCount = 32;
    for (uint64_t c = 0; c < vcCount; c++) {
        uint64_t child = axn_msg1_main_cached(vcs, AXNSelObjectAtIndex, "objectAtIndex:", c);
        if (!r_is_objc_ptr(child)) continue;
        char childCls[96];
        if (!axn_object_class_name(child, childCls, sizeof(childCls))) continue;
        if (strstr(childCls, "CSCoverSheet")) {
            if (gAxonWarmupLogBudget > 0) {
                printf("[AXONLITE] warmup: root=%s cs via viewControllers[%llu]=0x%llx (%s)\n",
                       rootCls, c, child, childCls);
                gAxonWarmupLogBudget--;
            }
            return child;
        }
    }

    return 0;
}

// Walk windows to find the cover-sheet sliding root, then force-load every
// VC on the chain that owns the CLVC. On iOS 18.5 each VC's `view` (and the
// child controllers it constructs in viewDidLoad) is lazy — so until the
// user actually presents the lock screen once, CSCombined hasn't built its
// notificationListViewController and our model.notificationListCache is
// unpopulated. Calling -loadViewIfNeeded at each rung materializes the
// chain without ever revealing the cover sheet UI.
static uint64_t axn_force_chain_construction(void)
{
    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) return 0;
    uint64_t app = axn_msg0_main_cached(UIApplication, AXNSelSharedApplication, "sharedApplication");
    if (!r_is_objc_ptr(app)) return 0;
    uint64_t windows = axn_msg0_main_cached(app, AXNSelWindows, "windows");
    if (!r_is_objc_ptr(windows)) return 0;
    uint64_t winCount = axn_msg0_main_cached(windows, AXNSelCount, "count");
    if (winCount > 80) winCount = 80;

    int candidates = 0;
    for (uint64_t i = 0; i < winCount; i++) {
        uint64_t win = axn_msg1_main_cached(windows, AXNSelObjectAtIndex, "objectAtIndex:", i);
        uint64_t root = axn_msg0_main_cached(win, AXNSelRootViewController, "rootViewController");
        if (!r_is_objc_ptr(root)) continue;
        char rootCls[96];
        if (!axn_object_class_name(root, rootCls, sizeof(rootCls))) continue;
        if (!strstr(rootCls, "CoverSheet")) continue;
        candidates++;

        r_msg2_main(root, "loadViewIfNeeded", 0, 0, 0, 0);

        uint64_t coverSheet = axn_warmup_cover_sheet_from_root(root, rootCls);
        if (!r_is_objc_ptr(coverSheet)) {
            if (gAxonWarmupLogBudget > 0) {
                printf("[AXONLITE] warmup: root=%s (win=%llu) has no cover-sheet via selector/ivar/children/viewControllers\n",
                       rootCls, i);
                gAxonWarmupLogBudget--;
            }
            continue;
        }
        r_msg2_main(coverSheet, "loadViewIfNeeded", 0, 0, 0, 0);

        uint64_t mainPage = axn_main_page_from_cover_sheet(coverSheet);
        if (!r_is_objc_ptr(mainPage)) {
            if (gAxonWarmupLogBudget > 0) {
                printf("[AXONLITE] warmup: cs=0x%llx has no mainPage\n", coverSheet);
                gAxonWarmupLogBudget--;
            }
            continue;
        }
        r_msg2_main(mainPage, "loadViewIfNeeded", 0, 0, 0, 0);

        uint64_t combined = axn_combined_from_main_page(mainPage);
        if (!r_is_objc_ptr(combined)) {
            if (gAxonWarmupLogBudget > 0) {
                printf("[AXONLITE] warmup: mainPage=0x%llx has no combined\n", mainPage);
                gAxonWarmupLogBudget--;
            }
            continue;
        }
        r_msg2_main(combined, "loadViewIfNeeded", 0, 0, 0, 0);

        if (!axn_responds_sel_main(combined, AXNSelNotificationListViewController,
                                   "notificationListViewController")) {
            if (gAxonWarmupLogBudget > 0) {
                printf("[AXONLITE] warmup: combined=0x%llx does not respond to notificationListViewController\n", combined);
                gAxonWarmupLogBudget--;
            }
            continue;
        }
        uint64_t clvc = axn_msg0_main_cached(combined, AXNSelNotificationListViewController,
                                              "notificationListViewController");
        if (!r_is_objc_ptr(clvc)) {
            if (gAxonWarmupLogBudget > 0) {
                printf("[AXONLITE] warmup: notificationListViewController returned nil\n");
                gAxonWarmupLogBudget--;
            }
            continue;
        }
        r_msg2_main(clvc, "loadViewIfNeeded", 0, 0, 0, 0);

        gAxonCombined = combined;
        printf("[AXONLITE] warmup: clvc=0x%llx materialized via cover-sheet chain (no lockscreen needed)\n",
               (unsigned long long)clvc);
        return clvc;
    }

    if (gAxonWarmupLogBudget > 0 && candidates == 0) {
        printf("[AXONLITE] warmup: no cover-sheet-root window in [app windows] (winCount=%llu)\n",
               (unsigned long long)winCount);
        gAxonWarmupLogBudget--;
    }
    return 0;
}

static uint64_t axn_find_notification_list_controller(void)
{
    if (r_is_objc_ptr(gAxonCLVC) &&
        axn_responds_sel_main(gAxonCLVC, AXNSelAllNotificationRequests, "allNotificationRequests")) {
        return gAxonCLVC;
    }
    gAxonCLVC = 0;
    gAxonCombined = 0;
    gAxonCoverSheetWindow = 0;

    uint64_t UIApplication = r_class("UIApplication");
    uint64_t app = r_is_objc_ptr(UIApplication) ? axn_msg0_main_cached(UIApplication, AXNSelSharedApplication, "sharedApplication") : 0;
    uint64_t windows = r_is_objc_ptr(app) ? axn_msg0_main_cached(app, AXNSelWindows, "windows") : 0;
    uint64_t count = r_is_objc_ptr(windows) ? axn_msg0_main_cached(windows, AXNSelCount, "count") : 0;
    if (count > 80) count = 80;

    uint64_t scanLimit = count > kAxonScanWindowLimit ? kAxonScanWindowLimit : count;
    uint64_t cursor = count ? (gAxonScanCursor % count) : 0;
    int visited = 0;
    bool logScan = !gAxonLoggedControllerMiss || gAxonTick <= 3 || (gAxonTick % 10) == 0;
    if (logScan) printf("[AXONLITE] targeted scan windows=%llu limit=%llu cursor=%llu\n",
                        (unsigned long long)count,
                        (unsigned long long)scanLimit,
                        (unsigned long long)cursor);

    for (uint64_t n = 0; n < scanLimit && visited < kAxonTargetedVisitedLimit; n++) {
        uint64_t offset = count ? ((cursor + n) % count) : 0;
        uint64_t i = (count - 1) - offset;
        uint64_t win = axn_msg1_main_cached(windows, AXNSelObjectAtIndex, "objectAtIndex:", i);
        uint64_t root = axn_msg0_main_cached(win, AXNSelRootViewController, "rootViewController");
        char rootCls[96];
        bool scanRoot = axn_candidate_class_name(root, rootCls, sizeof(rootCls));
        if (logScan) axn_log_candidate_controller_class("root", root, i, rootCls);
        if (!scanRoot) continue;

        uint64_t hit = axn_targeted_controller_from_vc(root, "root", &visited);
        if (!hit) {
            uint64_t presented = axn_msg0_main_cached(root, AXNSelPresentedViewController, "presentedViewController");
            char presentedCls[96];
            bool scanPresented = axn_candidate_class_name(presented, presentedCls, sizeof(presentedCls));
            if (logScan && r_is_objc_ptr(presented)) {
                axn_log_candidate_controller_class("presented", presented, i, presentedCls);
            }
            if (scanPresented) {
                hit = axn_targeted_controller_from_vc(presented, "presented", &visited);
                if (!hit) hit = axn_scan_shallow_children(presented, &visited);
            }
        }
        if (!hit) hit = axn_scan_shallow_children(root, &visited);

        if (hit) {
            if (gAxonCLVC != hit) {
                gAxonModelOwnerCLVC = 0;
                gAxonListModel = 0;
                gAxonListCache = 0;
                gAxonCellsForRequests = 0;
            }
            gAxonCLVC = hit;
            gAxonCoverSheetWindow = win;
            printf("[AXONLITE] targeted hit clvc=0x%llx visited=%d window=%llu winPtr=0x%llx\n",
                   hit, visited, (unsigned long long)i,
                   (unsigned long long)win);
            return hit;
        }
    }
    if (count) gAxonScanCursor = (cursor + scanLimit) % count;

    // Fallback: the class-filtered scan misses when the cover sheet hasn't
    // been presented yet (no CSCoverSheet child VC under the sliding root).
    // Force the chain to materialize so bucketing can happen during Run
    // instead of waiting for the user to open the lock screen. Runs on
    // every miss until CLVC is acquired; cost is bounded by the log budget
    // and the warmup short-circuits once it finds a non-zero CLVC.
    {
        uint64_t forced = axn_force_chain_construction();
        if (r_is_objc_ptr(forced) && axn_vc_looks_like_notification_list(forced)) {
            if (gAxonCLVC != forced) {
                gAxonModelOwnerCLVC = 0;
                gAxonListModel = 0;
                gAxonListCache = 0;
                gAxonCellsForRequests = 0;
            }
            gAxonCLVC = forced;
            return forced;
        }
    }

    if (logScan) {
        printf("[AXONLITE] notification list controller not visible yet windows=%llu visited=%d\n",
               (unsigned long long)count, visited);
    }
    gAxonLoggedControllerMiss = true;
    return 0;
}

static void axn_reset_model_cache_for_clvc(uint64_t clvc)
{
    if (gAxonModelOwnerCLVC == clvc) return;
    gAxonModelOwnerCLVC = clvc;
    gAxonListModel = 0;
    gAxonListCache = 0;
    gAxonCellsForRequests = 0;
    gAxonModelProbed = false;
    gAxonModelProbedPtr = 0;
    gAxonModelCanToggleFilter = false;
    gAxonModelCanPrivateInsert = false;
    gAxonModelCanNotifyContentChange = false;
}

static uint64_t axn_list_model_for_clvc(uint64_t clvc)
{
    if (!r_is_objc_ptr(clvc)) return 0;
    axn_reset_model_cache_for_clvc(clvc);
    if (r_is_objc_ptr(gAxonListModel)) return gAxonListModel;

    uint64_t collection = r_ivar_value(clvc, "_allNotificationRequests");
    if (!r_is_objc_ptr(collection) && r_responds_main(clvc, "allNotificationRequests")) {
        collection = r_msg2_main(clvc, "allNotificationRequests", 0, 0, 0, 0);
    }
    if (r_is_objc_ptr(collection)) return collection;

    uint64_t model = axn_ivar_value_cached(clvc, AXNIvarListModel, "_listModel");
    if (!r_is_objc_ptr(model)) model = axn_try_msg0_main(clvc, "listModel");
    if (r_is_objc_ptr(model) && gAxonModelFallbackLogBudget > 0) {
        char cls[96];
        if (!axn_object_class_name(model, cls, sizeof(cls))) snprintf(cls, sizeof(cls), "?");
        printf("[AXONLITE] using listModel fallback=0x%llx class=%s\n", model, cls);
        gAxonModelFallbackLogBudget--;
    }
    gAxonListModel = r_is_objc_ptr(model) ? model : 0;
    axn_probe_list_model(gAxonListModel);
    return gAxonListModel;
}

static uint64_t axn_list_cache_for_model(uint64_t model)
{
    if (!r_is_objc_ptr(model)) return 0;

    uint64_t cache = axn_ivar_value_cached(model, AXNIvarNotificationListCache, "_notificationListCache");
    if (!r_is_objc_ptr(cache)) cache = axn_try_msg0_main(model, "notificationListCache");
    if (r_is_objc_ptr(cache)) gAxonListCache = cache;
    return r_is_objc_ptr(cache) ? cache : gAxonListCache;
}

static uint64_t axn_cells_for_requests_from_model(uint64_t model)
{
    uint64_t cache = axn_list_cache_for_model(model);
    if (!r_is_objc_ptr(cache)) return 0;

    uint64_t cells = axn_ivar_value_cached(cache, AXNIvarCellsForRequests, "_notificationListCellsForRequests");
    if (!r_is_objc_ptr(cells)) cells = axn_try_msg0_main(cache, "notificationListCellsForRequests");
    if (r_is_objc_ptr(cells)) gAxonCellsForRequests = cells;
    return r_is_objc_ptr(cells) ? cells : gAxonCellsForRequests;
}

static uint64_t axn_requests_collection(uint64_t clvc)
{
    return axn_list_model_for_clvc(clvc);
}

static bool axn_request_bundle_and_title(uint64_t req, char *bundle, size_t bundleLen,
                                         char *title, size_t titleLen)
{
    if (!r_is_objc_ptr(req)) return false;
    if (bundle && bundleLen) bundle[0] = '\0';
    if (title && titleLen) title[0] = '\0';

    uint64_t section = axn_ivar_value_cached(req, AXNIvarSectionIdentifier, "_sectionIdentifier");
    if (!r_is_objc_ptr(section)) section = axn_try_msg0(req, "sectionIdentifier");
    // topLevelSectionIdentifier can throw NSRangeException on transient requests.
    if (!r_is_objc_ptr(section)) section = axn_ivar_value_cached(req, AXNIvarParentSectionIdentifier, "_parentSectionIdentifier");
    if (!r_is_objc_ptr(section)) {
        uint64_t bulletin = axn_ivar_value_cached(req, AXNIvarBulletin, "_bulletin");
        if (!r_is_objc_ptr(bulletin)) bulletin = axn_try_msg0(req, "bulletin");
        section = axn_ivar_value_cached(bulletin, AXNIvarSectionID, "_sectionID");
        if (!r_is_objc_ptr(section)) section = axn_try_msg0(bulletin, "sectionID");
    }
    if (!r_read_nsstring(section, bundle, bundleLen) || bundle[0] == '\0') return false;

    uint64_t content = axn_ivar_value_cached(req, AXNIvarContent, "_content");
    if (!r_is_objc_ptr(content)) content = axn_try_msg0(req, "content");
    uint64_t header = axn_ivar_value_cached(content, AXNIvarHeader, "_header");
    if (!r_is_objc_ptr(header)) header = axn_ivar_value_cached(content, AXNIvarTitle, "_title");
    if (!r_is_objc_ptr(header)) header = axn_ivar_value_cached(content, AXNIvarCustomHeader, "_customHeader");
    if (!r_is_objc_ptr(header)) header = axn_ivar_value_cached(content, AXNIvarDefaultHeader, "_defaultHeader");
    if (!r_is_objc_ptr(header)) header = axn_try_msg0(content, "header");
    if (!r_is_objc_ptr(header)) header = axn_try_msg0(content, "title");
    if (!r_is_objc_ptr(header)) header = axn_try_msg0(content, "customHeader");
    if (!r_is_objc_ptr(header)) header = axn_try_msg0(content, "defaultHeader");
    if (!r_read_nsstring(header, title, titleLen) || title[0] == '\0') {
        uint64_t bulletin = axn_ivar_value_cached(req, AXNIvarBulletin, "_bulletin");
        if (!r_is_objc_ptr(bulletin)) bulletin = axn_try_msg0(req, "bulletin");
        uint64_t displayName = axn_ivar_value_cached(bulletin, AXNIvarSectionDisplayName, "_sectionDisplayName");
        if (!r_is_objc_ptr(displayName)) displayName = axn_try_msg0(bulletin, "sectionDisplayName");
        (void)r_read_nsstring(displayName, title, titleLen);
    }
    if ((!title || title[0] == '\0') && bundle && title && titleLen) {
        const char *last = strrchr(bundle, '.');
        snprintf(title, titleLen, "%s", last && last[1] ? last + 1 : bundle);
    }

    return true;
}

static bool axn_request_identifier(uint64_t req, char *identifier, size_t identifierLen)
{
    if (!r_is_objc_ptr(req) || !identifier || identifierLen == 0) return false;
    identifier[0] = '\0';
    uint64_t value = axn_ivar_value_cached(req, AXNIvarNotificationIdentifier, "_notificationIdentifier");
    if (!r_is_objc_ptr(value)) value = axn_try_msg0(req, "notificationIdentifier");
    return r_read_nsstring(value, identifier, identifierLen);
}

static uint64_t axn_lookup_cached_icon(const char *bundle)
{
    if (!bundle || !bundle[0]) return 0;
    for (int i = 0; i < gAxonIconCacheCount; i++) {
        if (strcmp(gAxonIconCache[i].bundle, bundle) == 0) {
            return gAxonIconCache[i].image;
        }
    }
    return 0;
}

static void axn_cache_icon_for_bundle(const char *bundle, uint64_t image)
{
    if (!bundle || !bundle[0] || !r_is_objc_ptr(image)) return;

    uint64_t retained = r_msg2(image, "retain", 0, 0, 0, 0);
    uint64_t stored = r_is_objc_ptr(retained) ? retained : image;

    for (int i = 0; i < gAxonIconCacheCount; i++) {
        if (strcmp(gAxonIconCache[i].bundle, bundle) == 0) {
            if (r_is_objc_ptr(gAxonIconCache[i].image) && gAxonIconCache[i].image != stored) {
                axn_release_remote_obj(gAxonIconCache[i].image);
            }
            gAxonIconCache[i].image = stored;
            return;
        }
    }

    if (gAxonIconCacheCount >= kAxonMaxIconCache) {
        if (stored != image) axn_release_remote_obj(stored);
        return;
    }
    AXNIconCacheEntry *entry = &gAxonIconCache[gAxonIconCacheCount++];
    snprintf(entry->bundle, sizeof(entry->bundle), "%s", bundle);
    entry->image = stored;
}

static int axn_find_cached_request(const char *identifier, uint64_t req)
{
    for (int i = 0; i < gAxonRequestCount; i++) {
        if (identifier && identifier[0] && strcmp(gAxonRequests[i].identifier, identifier) == 0) return i;
        if (req && gAxonRequests[i].request == req) return i;
    }
    return -1;
}

static void axn_cache_request(uint64_t req, uint64_t cell, const char *bundle, const char *title,
                              const char *identifier, uint64_t tick)
{
    if (!r_is_objc_ptr(req) || !bundle || !bundle[0]) return;

    int idx = axn_find_cached_request(identifier, req);
    if (idx < 0) {
        if (gAxonRequestCount >= kAxonMaxRequests) return;
        idx = gAxonRequestCount++;
        memset(&gAxonRequests[idx], 0, sizeof(gAxonRequests[idx]));
        uint64_t retained = r_msg2(req, "retain", 0, 0, 0, 0);
        gAxonRequests[idx].request = r_is_objc_ptr(retained) ? retained : req;
        gAxonRequests[idx].retained = r_is_objc_ptr(retained);
        gAxonRequests[idx].hiddenByAxon = false;
    } else if (gAxonRequests[idx].request != req && r_is_objc_ptr(req)) {
        uint64_t retained = r_msg2(req, "retain", 0, 0, 0, 0);
        if (gAxonRequests[idx].retained) axn_release_remote_obj(gAxonRequests[idx].request);
        gAxonRequests[idx].request = r_is_objc_ptr(retained) ? retained : req;
        gAxonRequests[idx].retained = r_is_objc_ptr(retained);
        gAxonRequests[idx].hiddenByAxon = false;
    }

    snprintf(gAxonRequests[idx].bundle, sizeof(gAxonRequests[idx].bundle), "%s", bundle);
    snprintf(gAxonRequests[idx].title, sizeof(gAxonRequests[idx].title), "%s", title && title[0] ? title : bundle);
    if (identifier && identifier[0]) {
        snprintf(gAxonRequests[idx].identifier, sizeof(gAxonRequests[idx].identifier), "%s", identifier);
    }
    if (r_is_objc_ptr(cell)) gAxonRequests[idx].cell = cell;
    gAxonRequests[idx].lastSeenTick = tick;
}

static bool axn_cache_request_object(uint64_t req, uint64_t tick)
{
    if (!axn_object_looks_like_request(req)) return false;

    char bundle[128];
    char title[64];
    char identifier[192] = {0};
    if (!axn_request_bundle_and_title(req, bundle, sizeof(bundle), title, sizeof(title))) {
        if (gAxonRequestFailLogBudget > 0) {
            char cls[96];
            if (!axn_object_class_name(req, cls, sizeof(cls))) snprintf(cls, sizeof(cls), "?");
            printf("[AXONLITE] request skip object=0x%llx class=%s\n", req, cls);
            gAxonRequestFailLogBudget--;
        }
        return false;
    }
    (void)axn_request_identifier(req, identifier, sizeof(identifier));
    axn_cache_request(req, 0, bundle, title, identifier, tick);
    if (gAxonRequestCacheLogBudget > 0) {
        printf("[AXONLITE] request cached object=0x%llx bundle=%s title=%s identifier=%s\n",
               (unsigned long long)req,
               bundle,
               title[0] ? title : "?",
               identifier[0] ? identifier : "?");
        gAxonRequestCacheLogBudget--;
    }
    return true;
}

static bool axn_cache_request_object_fast(uint64_t req, uint64_t cell, uint64_t tick)
{
    if (!r_is_objc_ptr(req)) return false;

    char bundle[128];
    char title[64];
    char identifier[192] = {0};
    if (!axn_request_bundle_and_title(req, bundle, sizeof(bundle), title, sizeof(title))) {
        return false;
    }

    (void)axn_request_identifier(req, identifier, sizeof(identifier));
    axn_cache_request(req, cell, bundle, title, identifier, tick);
    if (gAxonRequestCacheLogBudget > 0) {
        printf("[AXONLITE] request cached object=0x%llx cell=0x%llx bundle=%s title=%s identifier=%s\n",
               (unsigned long long)req,
               (unsigned long long)cell,
               bundle,
               title[0] ? title : "?",
               identifier[0] ? identifier : "?");
        gAxonRequestCacheLogBudget--;
    }
    return true;
}

static bool axn_cache_related_collection(uint64_t collection, const char *selName,
                                         uint64_t tick, int depth, int *remaining);
static void axn_cache_collection(uint64_t collection, uint64_t tick, int depth, int *remaining);
static bool axn_cache_indexed_components(uint64_t collection, const char *selName,
                                         const char *label, uint64_t tick,
                                         int depth, int *remaining);

static bool axn_cache_request_from_view_or_controller(uint64_t obj, uint64_t tick,
                                                      int depth, int *remaining)
{
    if (!r_is_objc_ptr(obj) || !remaining || *remaining <= 0 ||
        depth > kAxonCacheDepthLimit) {
        return false;
    }

    int before = *remaining;
    if (axn_cache_request_object(obj, tick)) {
        (*remaining)--;
        return true;
    }

    uint64_t req = axn_try_msg0_main(obj, "notificationRequest");
    if (!r_is_objc_ptr(req)) req = r_ivar_value(obj, "_notificationRequest");
    if (r_is_objc_ptr(req) && req != obj) {
        axn_cache_collection(req, tick, depth + 1, remaining);
        if (*remaining < before) return true;
    }

    static const char *controllerSelectors[] = {
        "notificationViewController",
        "contentViewController",
    };
    for (size_t i = 0; i < sizeof(controllerSelectors) / sizeof(controllerSelectors[0]); i++) {
        if (*remaining <= 0) return *remaining < before;
        uint64_t child = axn_try_msg0_main(obj, controllerSelectors[i]);
        if (!r_is_objc_ptr(child) || child == obj) continue;
        if (axn_cache_request_from_view_or_controller(child, tick, depth + 1, remaining)) {
            return true;
        }
    }

    static const char *controllerIvars[] = {
        "_contentViewController",
        "_notificationViewController",
    };
    for (size_t i = 0; i < sizeof(controllerIvars) / sizeof(controllerIvars[0]); i++) {
        if (*remaining <= 0) return *remaining < before;
        uint64_t child = r_ivar_value(obj, controllerIvars[i]);
        if (!r_is_objc_ptr(child) || child == obj) continue;
        if (axn_cache_request_from_view_or_controller(child, tick, depth + 1, remaining)) {
            return true;
        }
    }

    return *remaining < before;
}

static uint64_t axn_root_list_view(uint64_t model)
{
    uint64_t listView = axn_try_msg0_main(model, "rootListView");
    if (!r_is_objc_ptr(listView)) listView = axn_try_msg0_main(model, "listView");
    if (!r_is_objc_ptr(listView)) listView = r_ivar_value(model, "_rootListView");
    if (!r_is_objc_ptr(listView)) listView = r_ivar_value(model, "_listView");
    return r_is_objc_ptr(listView) ? listView : 0;
}

static bool axn_cache_root_list_items(uint64_t model, uint64_t tick, int depth, int *remaining)
{
    if (!r_is_objc_ptr(model) || !remaining || *remaining <= 0 ||
        depth >= kAxonCacheDepthLimit ||
        !r_responds_main(model, "notificationListView:viewForItemAtIndex:") ||
        !r_responds_main(model, "count")) {
        return false;
    }

    uint64_t count = r_msg2_main(model, "count", 0, 0, 0, 0);
    if (count == 0) return false;
    if (count > kAxonRootItemLimit) count = kAxonRootItemLimit;

    uint64_t listView = axn_root_list_view(model);
    int before = *remaining;
    if (gAxonListCacheLogBudget > 0) {
        printf("[AXONLITE] modern list items count=%llu listView=0x%llx\n",
               (unsigned long long)count, (unsigned long long)listView);
        gAxonListCacheLogBudget--;
    }

    for (uint64_t i = 0; i < count && *remaining > 0; i++) {
        uint64_t view = r_msg2_main(model, "notificationListView:viewForItemAtIndex:",
                                    listView, i, 0, 0);
        if (!r_is_objc_ptr(view)) continue;

        uint64_t viewDataSource = axn_try_msg0_main(view, "dataSource");
        if (!r_is_objc_ptr(viewDataSource)) viewDataSource = r_ivar_value(view, "_dataSource");
        if (r_is_objc_ptr(viewDataSource) && axn_is_supplementary_object(viewDataSource)) {
            if (gAxonItemLogBudget > 0) {
                char cls[96];
                if (!axn_object_class_name(viewDataSource, cls, sizeof(cls))) snprintf(cls, sizeof(cls), "?");
                printf("[AXONLITE] modern item skip supplementary index=%llu dataSource=0x%llx class=%s\n",
                       (unsigned long long)i, (unsigned long long)viewDataSource, cls);
                gAxonItemLogBudget--;
            }
            continue;
        }

        if (gAxonItemLogBudget > 0) {
            char cls[96];
            if (!axn_object_class_name(view, cls, sizeof(cls))) snprintf(cls, sizeof(cls), "?");
            printf("[AXONLITE] modern item index=%llu view=0x%llx class=%s\n",
                   (unsigned long long)i, (unsigned long long)view, cls);
            gAxonItemLogBudget--;
        }

        int itemBefore = *remaining;
        if (!axn_cache_request_from_view_or_controller(view, tick, depth + 1, remaining)) {
            axn_cache_collection(view, tick, depth + 1, remaining);
        }
        if (*remaining == itemBefore && gAxonItemLogBudget > 0) {
            char cls[96];
            if (!axn_object_class_name(view, cls, sizeof(cls))) snprintf(cls, sizeof(cls), "?");
            printf("[AXONLITE] modern item no request index=%llu class=%s\n",
                   (unsigned long long)i, cls);
            gAxonItemLogBudget--;
        }
    }

    return *remaining < before;
}

static bool axn_cache_list_cache_requests(uint64_t model, uint64_t tick, int depth, int *remaining)
{
    if (!r_is_objc_ptr(model) || !remaining || *remaining <= 0 ||
        depth >= kAxonCacheDepthLimit) {
        return false;
    }

    uint64_t cells = axn_cells_for_requests_from_model(model);
    if (!r_is_objc_ptr(cells)) return false;

    if (gAxonListCacheLogBudget > 0) {
        axn_log_object_shape("listCache.cellsForRequests", cells);
        gAxonListCacheLogBudget--;
    }

    int before = *remaining;
    uint64_t keys = axn_msg0_cached(cells, AXNSelAllKeys, "allKeys");
    uint64_t count = axn_msg0_cached(keys, AXNSelCount, "count");
    if (count > kAxonMaxRequests) count = kAxonMaxRequests;

    for (uint64_t i = 0; i < count && *remaining > 0; i++) {
        uint64_t key = axn_msg1_cached(keys, AXNSelObjectAtIndex, "objectAtIndex:", i);
        if (!r_is_objc_ptr(key)) continue;

        uint64_t value = axn_msg1_cached(cells, AXNSelObjectForKey, "objectForKey:", key);

        if (gAxonListCacheEntryLogBudget > 0) {
            char keyCls[96];
            char valueCls[96];
            if (!axn_object_class_name(key, keyCls, sizeof(keyCls))) snprintf(keyCls, sizeof(keyCls), "?");
            if (!axn_object_class_name(value, valueCls, sizeof(valueCls))) snprintf(valueCls, sizeof(valueCls), "nil");
            printf("[AXONLITE] listCache entry index=%llu key=0x%llx class=%s value=0x%llx class=%s\n",
                   (unsigned long long)i,
                   (unsigned long long)key,
                   keyCls,
                   (unsigned long long)value,
                   valueCls);
            gAxonListCacheEntryLogBudget--;
        }

        if (axn_cache_request_object_fast(key, value, tick)) {
            (*remaining)--;
            continue;
        }

        if (r_is_objc_ptr(value)) {
            (void)axn_cache_request_from_view_or_controller(value, tick, depth + 1, remaining);
        }
    }

    return true;
}

static bool axn_cache_known_model_sources(uint64_t collection, uint64_t tick,
                                          int depth, int *remaining)
{
    static const char *modelSelectors[] = {
        "allNotificationRequests",
        "orderedRequests",
        "_orderedRequests",
        "leadingNotificationRequest",
        "_leadingNotificationRequest",
        "notificationGroups",
        "_notificationGroups",
        "_notificationGroupsForInsertion",
        "allNotificationGroups",
        "allNotificationGroupsIncludingHidden",
        "orderedNotificationListComponents",
        "_allSectionLists",
        "sectionLists",
        "_sectionLists",
        "chronologicalSectionLists",
        "_chronologicalSectionLists",
        "notificationListSections",
        "_notificationListSections",
        "_notificationSectionListsForEnumeration",
        "_sectionsForStateDump",
        "_sectionListsForPersistentState",
        "_sectionListsThatSuppressDigest",
        "_sectionListsThatSuppressLargeFormatContent",
        "notificationSections",
        "_notificationSections",
        "incomingSectionList",
        "_incomingSectionList",
        "prominentIncomingSectionList",
        "_prominentIncomingSectionList",
        "persistentSectionList",
        "_persistentSectionList",
        "highlightedSectionList",
        "_highlightedSectionList",
        "criticalSectionList",
        "_criticalSectionList",
        "historySectionList",
        "_historySectionList",
        "currentDigestSectionList",
        "_currentDigestSectionList",
        "upcomingDigestSectionList",
        "_upcomingDigestSectionList",
        "upcomingMissedSectionList",
        "_upcomingMissedSectionList",
        "_visibleNotificationRequests",
        "notificationListCache",
        "notificationListCellsForRequests",
        "supplementaryViewsSections",
        "_supplementaryViewsSections",
        "notificationRequestsPendingMigration",
        "notificationRequest",
        "notificationViewController",
        "contentViewController",
        "listView",
        "_listView",
        "rootListView",
        "_rootListView",
    };

    bool harvestedKnownSource = false;
    for (size_t i = 0; i < sizeof(modelSelectors) / sizeof(modelSelectors[0]); i++) {
        if (*remaining <= 0) return harvestedKnownSource;
        harvestedKnownSource |= axn_cache_related_collection(collection, modelSelectors[i],
                                                             tick, depth, remaining);
    }
    return harvestedKnownSource;
}

static bool axn_cache_indexed_components(uint64_t collection, const char *selName,
                                         const char *label, uint64_t tick,
                                         int depth, int *remaining)
{
    if (!r_is_objc_ptr(collection) || !selName || !remaining || *remaining <= 0 ||
        depth >= kAxonCacheDepthLimit || !r_responds_main(collection, selName)) {
        return false;
    }

    uint64_t count = r_responds_main(collection, "count") ?
                     r_msg2_main(collection, "count", 0, 0, 0, 0) : 0;
    if (count == 0) return false;
    if (count > kAxonRootItemLimit) count = kAxonRootItemLimit;

    int before = *remaining;
    for (uint64_t i = 0; i < count && *remaining > 0; i++) {
        uint64_t component = r_msg2_main(collection, selName, i, 0, 0, 0);
        if (!r_is_objc_ptr(component) || component == collection) continue;

        if (gAxonListViewLogBudget > 0) {
            char cls[96];
            if (!axn_object_class_name(component, cls, sizeof(cls))) snprintf(cls, sizeof(cls), "?");
            printf("[AXONLITE] %s index=%llu component=0x%llx class=%s\n",
                   label ? label : selName,
                   (unsigned long long)i,
                   (unsigned long long)component,
                   cls);
            gAxonListViewLogBudget--;
        }
        axn_cache_collection(component, tick, depth + 1, remaining);
    }

    return *remaining < before;
}

static bool axn_cache_view_item(uint64_t owner, uint64_t item, const char *label,
                                uint64_t index, uint64_t tick, int depth, int *remaining)
{
    if (!r_is_objc_ptr(item) || !remaining || *remaining <= 0) return false;

    if (gAxonListViewLogBudget > 0) {
        char cls[96];
        if (!axn_object_class_name(item, cls, sizeof(cls))) snprintf(cls, sizeof(cls), "?");
        printf("[AXONLITE] %s index=%llu owner=0x%llx item=0x%llx class=%s\n",
               label ? label : "view item",
               (unsigned long long)index,
               (unsigned long long)owner,
               (unsigned long long)item,
               cls);
        gAxonListViewLogBudget--;
    }

    int before = *remaining;
    if (!axn_cache_request_from_view_or_controller(item, tick, depth + 1, remaining)) {
        axn_cache_collection(item, tick, depth + 1, remaining);
    }
    return *remaining < before;
}

static bool axn_cache_notification_list_view(uint64_t view, uint64_t tick, int depth, int *remaining)
{
    if (!r_is_objc_ptr(view) || !remaining || *remaining <= 0 ||
        depth >= kAxonCacheDepthLimit) {
        return false;
    }

    bool hasListViewShape = r_responds_main(view, "visibleViewAtIndex:") ||
                            r_responds_main(view, "_viewForItemAtIndex:") ||
                            r_responds_main(view, "visibleViews");
    if (!hasListViewShape) return false;

    int before = *remaining;

    uint64_t dataSource = axn_try_msg0_main(view, "dataSource");
    if (!r_is_objc_ptr(dataSource)) dataSource = r_ivar_value(view, "_dataSource");
    if (r_is_objc_ptr(dataSource) && dataSource != view) {
        if (gAxonListViewLogBudget > 0) {
            char cls[96];
            if (!axn_object_class_name(dataSource, cls, sizeof(cls))) snprintf(cls, sizeof(cls), "?");
            uint64_t dsCount = r_responds_main(dataSource, "count") ?
                               r_msg2_main(dataSource, "count", 0, 0, 0, 0) : 0;
            printf("[AXONLITE] listView dataSource=0x%llx class=%s count=%llu\n",
                   (unsigned long long)dataSource, cls, (unsigned long long)dsCount);
            gAxonListViewLogBudget--;
        }

        if (axn_is_supplementary_object(dataSource)) {
            return false;
        }

        axn_cache_collection(dataSource, tick, depth + 1, remaining);
        if (*remaining < before) return true;

        uint64_t itemCount = r_responds_main(dataSource, "notificationListViewNumberOfItems:") ?
                             r_msg2_main(dataSource, "notificationListViewNumberOfItems:", view, 0, 0, 0) : 0;
        if (itemCount == 0) {
            itemCount = r_responds_main(view, "count") ?
                        r_msg2_main(view, "count", 0, 0, 0, 0) : 0;
        }
        if (itemCount > kAxonRootItemLimit) itemCount = kAxonRootItemLimit;

        if (r_responds_main(dataSource, "notificationListView:viewForItemAtIndex:")) {
            for (uint64_t i = 0; i < itemCount && *remaining > 0; i++) {
                uint64_t item = r_msg2_main(dataSource, "notificationListView:viewForItemAtIndex:",
                                            view, i, 0, 0);
                if (r_is_objc_ptr(item) && item != view &&
                    axn_cache_view_item(dataSource, item, "dataSource viewForItem", i,
                                        tick, depth, remaining)) {
                    return true;
                }
            }
        }
    }

    uint64_t visibleViews = axn_try_msg0_main(view, "visibleViews");
    if (r_is_objc_ptr(visibleViews) && visibleViews != view) {
        if (gAxonListViewLogBudget > 0) {
            axn_log_object_shape("listView.visibleViews", visibleViews);
            gAxonListViewLogBudget--;
        }
        axn_cache_collection(visibleViews, tick, depth + 1, remaining);
        if (*remaining < before) return true;
    }

    uint64_t count = r_responds_main(view, "count") ?
                     r_msg2_main(view, "count", 0, 0, 0, 0) : 0;
    if (count > kAxonRootItemLimit) count = kAxonRootItemLimit;

    for (uint64_t i = 0; i < count && *remaining > 0; i++) {
        uint64_t item = r_responds_main(view, "visibleViewAtIndex:") ?
                        r_msg2_main(view, "visibleViewAtIndex:", i, 0, 0, 0) : 0;
        if (r_is_objc_ptr(item) && item != view &&
            axn_cache_view_item(view, item, "visibleView", i, tick, depth, remaining)) {
            return true;
        }

        item = r_responds_main(view, "_viewForItemAtIndex:") ?
               r_msg2_main(view, "_viewForItemAtIndex:", i, 0, 0, 0) : 0;
        if (r_is_objc_ptr(item) && item != view &&
            axn_cache_view_item(view, item, "_viewForItem", i, tick, depth, remaining)) {
            return true;
        }
    }

    uint64_t subviews = axn_try_msg0_main(view, "subviews");
    if (r_is_objc_ptr(subviews) && subviews != view) {
        if (gAxonListViewLogBudget > 0) {
            axn_log_object_shape("listView.subviews", subviews);
            gAxonListViewLogBudget--;
        }
        axn_cache_collection(subviews, tick, depth + 1, remaining);
    }

    return *remaining < before;
}

static void axn_cache_collection(uint64_t collection, uint64_t tick, int depth, int *remaining)
{
    if (!r_is_objc_ptr(collection) || !remaining || *remaining <= 0 ||
        depth > kAxonCacheDepthLimit) {
        return;
    }
    if (axn_cache_request_object(collection, tick)) {
        (*remaining)--;
        return;
    }

    if (gAxonShapeLogBudget > 0) {
        axn_log_object_shape("walk", collection);
        gAxonShapeLogBudget--;
    }

    if (axn_cache_list_cache_requests(collection, tick, depth, remaining)) {
        return;
    }
    if (axn_cache_indexed_components(collection, "sectionListAtIndex:",
                                     "sectionList", tick, depth, remaining)) {
        return;
    }
    if (axn_cache_notification_list_view(collection, tick, depth, remaining)) {
        return;
    }
    if (axn_cache_root_list_items(collection, tick, depth, remaining)) {
        return;
    }

    if (!axn_is_supplementary_object(collection) &&
        axn_cache_known_model_sources(collection, tick, depth, remaining)) {
        return;
    }

    if (axn_cache_request_from_view_or_controller(collection, tick, depth, remaining)) {
        return;
    }
    int before = *remaining;

    if (r_responds(collection, "coalescedNotificationRequests")) {
        uint64_t requests = r_msg2(collection, "coalescedNotificationRequests", 0, 0, 0, 0);
        if (r_is_objc_ptr(requests) && requests != collection) {
            axn_cache_collection(requests, tick, depth + 1, remaining);
            if (*remaining < before) return;
        }
    }
    before = *remaining;

    if (r_responds(collection, "allKeys")) {
        uint64_t keys = r_msg2(collection, "allKeys", 0, 0, 0, 0);
        if (r_is_objc_ptr(keys) && keys != collection) {
            axn_cache_collection(keys, tick, depth + 1, remaining);
            if (*remaining < before) return;
        }
    }
    before = *remaining;

    if (r_responds(collection, "allValues")) {
        uint64_t values = r_msg2(collection, "allValues", 0, 0, 0, 0);
        if (r_is_objc_ptr(values) && values != collection) {
            axn_cache_collection(values, tick, depth + 1, remaining);
            if (*remaining < before) return;
        }
    }
    before = *remaining;

    if (r_responds(collection, "allObjects")) {
        uint64_t objects = r_msg2(collection, "allObjects", 0, 0, 0, 0);
        if (r_is_objc_ptr(objects) && objects != collection) {
            axn_cache_collection(objects, tick, depth + 1, remaining);
            if (*remaining < before) return;
        }
    }
    before = *remaining;

    if (r_responds(collection, "keyEnumerator")) {
        uint64_t enumerator = r_msg2(collection, "keyEnumerator", 0, 0, 0, 0);
        for (int i = 0; r_is_objc_ptr(enumerator) && i < kAxonMaxRequests && *remaining > 0; i++) {
            uint64_t obj = r_msg2(enumerator, "nextObject", 0, 0, 0, 0);
            if (!r_is_objc_ptr(obj)) break;
            axn_cache_collection(obj, tick, depth + 1, remaining);
        }
        if (*remaining < before) return;
    }
    before = *remaining;

    if (r_responds(collection, "objectEnumerator")) {
        uint64_t enumerator = r_msg2(collection, "objectEnumerator", 0, 0, 0, 0);
        for (int i = 0; r_is_objc_ptr(enumerator) && i < kAxonMaxRequests && *remaining > 0; i++) {
            uint64_t obj = r_msg2(enumerator, "nextObject", 0, 0, 0, 0);
            if (!r_is_objc_ptr(obj)) break;
            axn_cache_collection(obj, tick, depth + 1, remaining);
        }
        if (*remaining < before) return;
    }

    if (!r_responds(collection, "objectAtIndex:")) return;
    uint64_t count = r_responds(collection, "count") ? r_msg2(collection, "count", 0, 0, 0, 0) : 0;
    if (count > kAxonMaxRequests) count = kAxonMaxRequests;
    for (uint64_t i = 0; i < count && *remaining > 0; i++) {
        uint64_t obj = r_msg2(collection, "objectAtIndex:", i, 0, 0, 0);
        axn_cache_collection(obj, tick, depth + 1, remaining);
    }
}

static bool axn_cache_related_collection(uint64_t collection, const char *selName,
                                         uint64_t tick, int depth, int *remaining)
{
    if (!r_is_objc_ptr(collection) || !selName || !remaining || *remaining <= 0 ||
        depth >= kAxonCacheDepthLimit) {
        return false;
    }

    uint64_t related = 0;
    if (r_responds_main(collection, selName)) {
        related = r_msg2_main(collection, selName, 0, 0, 0, 0);
    } else if (selName[0] == '_') {
        related = r_ivar_value(collection, selName);
    }
    if (!r_is_objc_ptr(related) || related == collection) return false;

    int before = *remaining;
    if (gAxonShapeLogBudget > 0) {
        axn_log_object_shape(selName, related);
        gAxonShapeLogBudget--;
    }
    axn_cache_collection(related, tick, depth + 1, remaining);
    return *remaining < before;
}

static void axn_cache_visible_requests(uint64_t clvc, uint64_t tick)
{
    uint64_t requests = axn_requests_collection(clvc);
    int before = gAxonRequestCount;
    int remaining = kAxonMaxRequests;
    bool fastPath = axn_cache_list_cache_requests(requests, tick, 0, &remaining);
    if (!fastPath) {
        if (tick <= 3 || (tick % 10) == 0) {
            gAxonShapeLogBudget = 24;
            axn_log_object_shape("requests", requests);
        }
        axn_cache_collection(requests, tick, 0, &remaining);
    }
    int walked = kAxonMaxRequests - remaining;
    int delta = gAxonRequestCount - before;
    if (tick <= 2 || delta != 0 || (tick % 60) == 0) {
        printf("[AXONLITE] cache tick=%llu source=%s walked=%d cached=%d new=%d\n",
               (unsigned long long)tick,
               fastPath ? "listCache" : "walk",
               walked,
               gAxonRequestCount,
               delta);
    }
}

static int axn_bundle_index(AXNBundle *bundles, int count, const char *bundle)
{
    if (!bundle || !bundle[0]) return -1;
    for (int i = 0; i < count; i++) {
        if (strcmp(bundles[i].bundle, bundle) == 0) return i;
    }
    return -1;
}

static int axn_build_bundles(AXNBundle *bundles, int maxBundles)
{
    if (!bundles || maxBundles <= 0) return 0;
    memset(bundles, 0, sizeof(AXNBundle) * (size_t)maxBundles);

    int count = 0;
    for (int i = 0; i < gAxonRequestCount; i++) {
        if (!r_is_objc_ptr(gAxonRequests[i].request) || !gAxonRequests[i].bundle[0]) continue;
        int idx = axn_bundle_index(bundles, count, gAxonRequests[i].bundle);
        if (idx < 0) {
            if (count >= maxBundles) continue;
            idx = count++;
            snprintf(bundles[idx].bundle, sizeof(bundles[idx].bundle), "%s", gAxonRequests[i].bundle);
            snprintf(bundles[idx].title, sizeof(bundles[idx].title), "%s",
                     gAxonRequests[i].title[0] ? gAxonRequests[i].title : gAxonRequests[i].bundle);
        }
        bundles[idx].count++;
    }
    return count;
}

static void axn_roster_note_bundles(AXNBundle *bundles, int bundleCount, uint64_t tick)
{
    (void)tick;
    if (!bundles || bundleCount <= 0) return;
    int added = 0;
    for (int i = 0; i < bundleCount; i++) {
        if (!bundles[i].bundle[0]) continue;
        int idx = axn_bundle_index(gAxonBundleRoster, gAxonBundleRosterCount, bundles[i].bundle);
        if (idx < 0) {
            if (gAxonBundleRosterCount >= kAxonMaxBundles) continue;
            idx = gAxonBundleRosterCount++;
            memset(&gAxonBundleRoster[idx], 0, sizeof(gAxonBundleRoster[idx]));
            snprintf(gAxonBundleRoster[idx].bundle, sizeof(gAxonBundleRoster[idx].bundle),
                     "%s", bundles[i].bundle);
            added++;
        }
        snprintf(gAxonBundleRoster[idx].title, sizeof(gAxonBundleRoster[idx].title),
                 "%s", bundles[i].title[0] ? bundles[i].title : bundles[i].bundle);
        if (bundles[i].count > 0) gAxonBundleRoster[idx].count = bundles[i].count;
    }
    if (added > 0) {
        printf("[AXONLITE] bundle roster learned %d app(s), total=%d\n",
               added, gAxonBundleRosterCount);
    }
}

static int axn_build_display_bundles(AXNBundle *bundles, int maxBundles, uint64_t tick)
{
    if (!bundles || maxBundles <= 0) return 0;

    AXNBundle live[kAxonMaxBundles];
    int liveCount = axn_build_bundles(live, kAxonMaxBundles);
    axn_roster_note_bundles(live, liveCount, tick);

    memset(bundles, 0, sizeof(AXNBundle) * (size_t)maxBundles);
    int count = 0;
    for (int i = 0; i < gAxonBundleRosterCount && count < maxBundles; i++) {
        if (!gAxonBundleRoster[i].bundle[0]) continue;
        AXNBundle merged = gAxonBundleRoster[i];
        int liveIdx = axn_bundle_index(live, liveCount, merged.bundle);
        if (liveIdx >= 0) {
            merged.count = live[liveIdx].count;
            if (live[liveIdx].title[0]) {
                snprintf(merged.title, sizeof(merged.title), "%s", live[liveIdx].title);
            }
            gAxonBundleRoster[i] = merged;
        }
        bundles[count++] = merged;
    }

    for (int i = 0; i < liveCount && count < maxBundles; i++) {
        if (axn_bundle_index(bundles, count, live[i].bundle) >= 0) continue;
        bundles[count++] = live[i];
    }

    if (liveCount > 0 && count > liveCount && (tick <= 3 || (tick % 60) == 0)) {
        printf("[AXONLITE] display bundles live=%d roster=%d\n", liveCount, count);
    }
    return count;
}

static void axn_trim_title(const char *in, char *out, size_t outLen)
{
    if (!out || outLen == 0) return;
    if (!in) in = "";
    size_t n = strlen(in);
    if (n < outLen) {
        snprintf(out, outLen, "%s", in);
        return;
    }
    if (outLen <= 2) {
        out[0] = '\0';
        return;
    }
    snprintf(out, outLen, "%.*s.", (int)outLen - 2, in);
}

static void axn_update_selected_from_control(void)
{
    if (!r_is_objc_ptr(gAxonControl) || gAxonDisplayedCount <= 0) return;
    if (!gAxonControlCanSelect) return;

    int64_t selected = (int64_t)r_msg2_main(gAxonControl, "selectedSegmentIndex", 0, 0, 0, 0);
    if (selected < 0 || selected >= gAxonDisplayedCount) return;

    const char *newBundle = gAxonDisplayedBundles[selected];
    if (strcmp(gAxonSelectedBundle, newBundle) != 0) {
        snprintf(gAxonSelectedBundle, sizeof(gAxonSelectedBundle), "%s", newBundle);
        printf("[AXONLITE] selected %s\n", gAxonSelectedBundle[0] ? gAxonSelectedBundle : "All");
    }
}

static int axn_selected_index_for_bundles(AXNBundle *bundles, int bundleCount)
{
    if (!gAxonSelectedBundle[0]) return 0;
    for (int i = 0; i < bundleCount; i++) {
        if (strcmp(bundles[i].bundle, gAxonSelectedBundle) == 0) return i + 1;
    }
    gAxonSelectedBundle[0] = '\0';
    return 0;
}

static bool axn_send_rect_main(uint64_t obj, const char *selName,
                               double x, double y, double width, double height)
{
    if (!r_is_objc_ptr(obj)) return false;
    AXNRect64 rect = { x, y, width, height };
    r_msg2_main_raw(obj, selName,
                    &rect, sizeof(rect),
                    NULL, 0,
                    NULL, 0,
                    NULL, 0);
    return true;
}

static bool axn_send_double_main(uint64_t obj, const char *selName, double value)
{
    if (!r_is_objc_ptr(obj)) return false;
    r_msg2_main_raw(obj, selName,
                    &value, sizeof(value),
                    NULL, 0,
                    NULL, 0,
                    NULL, 0);
    return true;
}

static double axn_overlay_width_for_count(int bundleCount);

static uint64_t axn_color_white_alpha(double white, double alpha)
{
    uint64_t UIColor = r_class("UIColor");
    if (!r_is_objc_ptr(UIColor)) return 0;
    return r_msg2_main_raw(UIColor, "colorWithWhite:alpha:",
                           &white, sizeof(white),
                           &alpha, sizeof(alpha),
                           NULL, 0,
                           NULL, 0);
}

static uint64_t axn_font_bold(double size)
{
    uint64_t UIFont = r_class("UIFont");
    if (!r_is_objc_ptr(UIFont)) return 0;
    return r_msg2_main_raw(UIFont, "boldSystemFontOfSize:",
                           &size, sizeof(size),
                           NULL, 0,
                           NULL, 0,
                           NULL, 0);
}

static uint64_t axn_alloc_init_view(const char *className, double x, double y, double width, double height)
{
    uint64_t cls = r_class(className);
    uint64_t alloc = r_is_objc_ptr(cls) ? r_msg2_main(cls, "alloc", 0, 0, 0, 0) : 0;
    uint64_t view = r_is_objc_ptr(alloc) ? r_msg2_main(alloc, "init", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(view)) axn_send_rect_main(view, "setFrame:", x, y, width, height);
    return view;
}

static uint64_t axn_app_icon_image(const char *bundle)
{
    if (!bundle || !bundle[0]) return 0;

    uint64_t nsBundle = r_nsstr_retained(bundle);
    uint64_t UIImage = r_class("UIImage");
    if (!r_is_objc_ptr(nsBundle) || !r_is_objc_ptr(UIImage)) {
        axn_release_remote_obj(nsBundle);
        return 0;
    }

    double scale = 3.0;
    int format = 0;
    uint64_t image = r_msg2_main_raw(UIImage, "_applicationIconImageForBundleIdentifier:format:scale:",
                                     &nsBundle, sizeof(nsBundle),
                                     &format, sizeof(format),
                                     &scale, sizeof(scale),
                                     NULL, 0);
    axn_release_remote_obj(nsBundle);

    if (r_is_objc_ptr(image) && r_responds_main(image, "imageWithRenderingMode:")) {
        image = r_msg2_main(image, "imageWithRenderingMode:", 1, 0, 0, 0);
    }
    return r_is_objc_ptr(image) ? image : 0;
}

static uint64_t axn_cached_app_icon_image(const char *bundle)
{
    return axn_lookup_cached_icon(bundle);
}

static bool axn_is_kind_of_cached_class(uint64_t obj, uint64_t cls)
{
    if (!r_is_objc_ptr(obj) || !r_is_objc_ptr(cls)) return false;
    uint64_t isKindSel = axn_sel_cached(AXNSelIsKindOfClass, "isKindOfClass:");
    if (!isKindSel) return false;
    // Main thread: this runs on live notification views from the 500ms live
    // loop; touching UIKit off the RemoteCall worker thread races SpringBoard's
    // layout and crashes it (EXC_ARM_PAC_FAIL).
    uint64_t result = r_msg_main(obj, isKindSel, cls, 0, 0, 0);
    return (result & 0xff) != 0;
}

static uint64_t axn_find_badged_icon_view(uint64_t root, int depth, int *budget)
{
    if (!r_is_objc_ptr(root) || depth > 6 || !budget || *budget <= 0) return 0;
    (*budget)--;

    uint64_t badgedCls = axn_class_cached(&gAxonBadgedIconViewClass,
                                          &gAxonBadgedIconViewClassTried,
                                          "NCBadgedIconView");
    if (r_is_objc_ptr(badgedCls) && axn_is_kind_of_cached_class(root, badgedCls)) {
        return root;
    }

    // Walk the live view hierarchy on SpringBoard's main thread (see above), and
    // retain the subviews snapshot across the marshaled hops so it can't drain.
    uint64_t subviews = r_msg2_main(root, "subviews", 0, 0, 0, 0);
    if (!r_is_objc_ptr(subviews)) return 0;
    r_msg2_main(subviews, "retain", 0, 0, 0, 0);

    uint64_t count = r_msg2_main(subviews, "count", 0, 0, 0, 0);
    if (count > 16) count = 16;

    uint64_t hit = 0;
    for (uint64_t i = 0; i < count && *budget > 0; i++) {
        uint64_t child = r_msg2_main(subviews, "objectAtIndex:", i, 0, 0, 0);
        hit = axn_find_badged_icon_view(child, depth + 1, budget);
        if (r_is_objc_ptr(hit)) break;
    }
    r_msg2_main(subviews, "release", 0, 0, 0, 0);
    return r_is_objc_ptr(hit) ? hit : 0;
}

static uint64_t axn_image_from_badged_icon_view(uint64_t iconHostView)
{
    if (!r_is_objc_ptr(iconHostView)) return 0;
    uint64_t prominent = r_msg2(iconHostView, "_prominentImageView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(prominent)) return 0;
    uint64_t image = r_msg2(prominent, "image", 0, 0, 0, 0);
    return r_is_objc_ptr(image) ? image : 0;
}

static uint64_t axn_extract_icon_from_cell(uint64_t cell, char *sourceOut, size_t sourceLen)
{
    if (sourceOut && sourceLen) sourceOut[0] = '\0';
    if (!r_is_objc_ptr(cell)) return 0;

    uint64_t contentVC = axn_ivar_value_cached(cell, AXNIvarCellContentViewController,
                                               "_contentViewController");
    if (!r_is_objc_ptr(contentVC)) contentVC = r_msg2(cell, "contentViewController", 0, 0, 0, 0);

    uint64_t lookView = 0;
    if (r_is_objc_ptr(contentVC)) {
        lookView = axn_ivar_value_cached(contentVC, AXNIvarLookView, "_lookView");
        if (!r_is_objc_ptr(lookView)) lookView = r_msg2(contentVC, "_lookView", 0, 0, 0, 0);
    }

    uint64_t contentView = 0;
    if (r_is_objc_ptr(lookView)) {
        contentView = axn_ivar_value_cached(lookView, AXNIvarNotificationContentView,
                                            "_notificationContentView");
        if (!r_is_objc_ptr(contentView)) {
            contentView = r_msg2(lookView, "_notificationContentView", 0, 0, 0, 0);
        }
    }

    uint64_t badgedIconView = 0;
    if (r_is_objc_ptr(contentView)) {
        badgedIconView = axn_ivar_value_cached(contentView, AXNIvarBadgedIconView,
                                               "_badgedIconView");
    }

    if (r_is_objc_ptr(badgedIconView)) {
        uint64_t image = axn_image_from_badged_icon_view(badgedIconView);
        if (r_is_objc_ptr(image)) {
            if (sourceOut && sourceLen) snprintf(sourceOut, sourceLen, "cell-ivar");
            return image;
        }
    }

    int budget = 96;
    uint64_t scanRoot = r_is_objc_ptr(contentView) ? contentView : cell;
    badgedIconView = axn_find_badged_icon_view(scanRoot, 0, &budget);
    if (r_is_objc_ptr(badgedIconView)) {
        uint64_t image = axn_image_from_badged_icon_view(badgedIconView);
        if (r_is_objc_ptr(image)) {
            if (sourceOut && sourceLen) snprintf(sourceOut, sourceLen, "cell-scan");
            return image;
        }
    }

    return 0;
}

static int axn_find_request_with_cell_for_bundle(const char *bundle)
{
    if (!bundle || !bundle[0]) return -1;
    for (int i = 0; i < gAxonRequestCount; i++) {
        if (!r_is_objc_ptr(gAxonRequests[i].cell)) continue;
        if (strcmp(gAxonRequests[i].bundle, bundle) == 0) return i;
    }
    return -1;
}

static bool axn_hydrate_pending_icons(AXNBundle *bundles, int bundleCount, uint64_t tick)
{
    if (bundleCount <= 0) return false;

    int before = gAxonIconCacheCount;
    int attempted = 0;
    int resolved = 0;

    for (int i = 0; i < bundleCount; i++) {
        const char *bundle = bundles[i].bundle;
        if (!bundle[0] || axn_lookup_cached_icon(bundle)) continue;

        char source[24] = "";
        uint64_t image = 0;
        attempted++;

        // Prefer the authoritative app-resolver path. cell-ivar extraction
        // pulls _prominentImageView.image off a recycled NCNotificationListCell;
        // when SB has just reused a cell for a different bundle but the icon
        // hasn't async-loaded yet, the cell still holds the PREVIOUS bundle's
        // icon — which is why you see (e.g.) the ESPN icon appearing for WaPo.
        // The app-resolver gives the canonical icon for the bundle.
        int reqIdx = -1;
        image = axn_app_icon_image(bundle);
        if (r_is_objc_ptr(image)) {
            snprintf(source, sizeof(source), "app-resolver");
        } else {
            reqIdx = axn_find_request_with_cell_for_bundle(bundle);
            if (reqIdx >= 0) {
                image = axn_extract_icon_from_cell(gAxonRequests[reqIdx].cell, source, sizeof(source));
            }
        }

        if (r_is_objc_ptr(image)) {
            axn_cache_icon_for_bundle(bundle, image);
            resolved++;
            if (gAxonIconHydrateLogBudget > 0) {
                printf("[AXONLITE] icon cache bundle=%s source=%s image=0x%llx tick=%llu\n",
                       bundle, source[0] ? source : "?",
                       (unsigned long long)image, (unsigned long long)tick);
                gAxonIconHydrateLogBudget--;
            }
        } else if (gAxonIconHydrateLogBudget > 0) {
            char cellCls[96] = "nil";
            if (reqIdx >= 0) {
                axn_object_class_name(gAxonRequests[reqIdx].cell, cellCls, sizeof(cellCls));
            }
            printf("[AXONLITE] icon miss bundle=%s cellClass=%s tick=%llu\n",
                   bundle, cellCls, (unsigned long long)tick);
            gAxonIconHydrateLogBudget--;
        }
    }

    if (resolved || (attempted && (tick <= 2 || (tick % 60) == 0))) {
        printf("[AXONLITE] icon hydration tick=%llu attempted=%d resolved=%d cached=%d\n",
               (unsigned long long)tick, attempted, resolved, gAxonIconCacheCount);
    }
    return gAxonIconCacheCount != before;
}

static uint64_t axn_make_icon_strip(AXNBundle *bundles, int bundleCount)
{
    if (bundleCount < 0) bundleCount = 0;
    double width = axn_overlay_width_for_count(bundleCount);

    uint64_t NSMutableArray = r_class("NSMutableArray");
    uint64_t items = r_is_objc_ptr(NSMutableArray) ?
                     r_msg2_main(NSMutableArray, "array", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(items)) return 0;

    // First segment is the "no selection" / empty state, matching upstream
    // Axon's showByDefault=0 behavior. Label as "—" since selecting it shows
    // no notifs (not "all of them").
    uint64_t noneText = r_nsstr_retained("—");
    if (r_is_objc_ptr(noneText)) {
        r_msg2_main(items, "addObject:", noneText, 0, 0, 0);
        axn_release_remote_obj(noneText);
    }

    for (int i = 0; i < bundleCount; i++) {
        uint64_t icon = axn_cached_app_icon_image(bundles[i].bundle);
        if (r_is_objc_ptr(icon)) {
            if (r_responds_main(icon, "imageWithRenderingMode:")) {
                uint64_t fresh = r_msg2_main(icon, "imageWithRenderingMode:", 1, 0, 0, 0);
                if (r_is_objc_ptr(fresh)) icon = fresh;
            }
            r_msg2_main(items, "addObject:", icon, 0, 0, 0);
        } else {
            char fallback[24];
            axn_trim_title(bundles[i].title, fallback, sizeof(fallback));
            uint64_t text = r_nsstr_retained(fallback);
            if (r_is_objc_ptr(text)) {
                r_msg2_main(items, "addObject:", text, 0, 0, 0);
                axn_release_remote_obj(text);
            }
        }
    }

    uint64_t UISegmentedControl = r_class("UISegmentedControl");
    uint64_t allocated = r_is_objc_ptr(UISegmentedControl) ?
                         r_msg2_main(UISegmentedControl, "alloc", 0, 0, 0, 0) : 0;
    uint64_t control = r_is_objc_ptr(allocated) ?
                       r_msg2_main(allocated, "initWithItems:", items, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(control)) return 0;

    axn_send_rect_main(control, "setFrame:", 0.0, 0.0, width, kAxonOverlayHeight);
    r_msg2_main(control, "setTag:", kAxonOverlayTag, 0, 0, 0);
    r_msg2_main(control, "setUserInteractionEnabled:", 1, 0, 0, 0);

    int selectedIdx = axn_selected_index_for_bundles(bundles, bundleCount);
    r_msg2_main(control, "setSelectedSegmentIndex:", (uint64_t)selectedIdx, 0, 0, 0);

    uint64_t bgColor = axn_color_white_alpha(0.0, 0.55);
    if (r_is_objc_ptr(bgColor) && r_responds_main(control, "setBackgroundColor:")) {
        r_msg2_main(control, "setBackgroundColor:", bgColor, 0, 0, 0);
    }
    uint64_t selectedTint = axn_color_white_alpha(1.0, 0.28);
    if (r_is_objc_ptr(selectedTint) && r_responds_main(control, "setSelectedSegmentTintColor:")) {
        r_msg2_main(control, "setSelectedSegmentTintColor:", selectedTint, 0, 0, 0);
    }

    return control;
}

static void axn_clear_badges(void)
{
    if (r_is_objc_ptr(gAxonBadgeView)) {
        r_msg2_main(gAxonBadgeView, "removeFromSuperview", 0, 0, 0, 0);
        gAxonBadgeView = 0;
    }
}

static double axn_screen_width(void)
{
    CGRect bounds = UIScreen.mainScreen.bounds;
    double screenWidth = bounds.size.width;
    if (!isfinite(screenWidth) || screenWidth < 100.0 || screenWidth > 2000.0) screenWidth = 390.0;
    return screenWidth;
}

static double axn_screen_height(void)
{
    CGRect bounds = UIScreen.mainScreen.bounds;
    double screenHeight = bounds.size.height;
    if (!isfinite(screenHeight) || screenHeight < 100.0 || screenHeight > 3000.0) screenHeight = 844.0;
    return screenHeight;
}

static double axn_overlay_width_for_count(int bundleCount)
{
    double maxWidth = fmax(1.0, axn_screen_width() - (kAxonOverlayMargin * 2.0));
    int segmentCount = bundleCount + 1;
    if (segmentCount < 1) segmentCount = 1;
    double contentWidth = 56.0 * (double)segmentCount;
    if (contentWidth < 116.0) contentWidth = 116.0;
    return fmin(maxWidth, contentWidth);
}

static void axn_rebuild_badges(AXNBundle *bundles, int bundleCount)
{
    axn_clear_badges();
    if (!r_is_objc_ptr(gAxonWindow) || bundleCount <= 0) return;

    double width = axn_overlay_width_for_count(bundleCount);
    double segmentWidth = width / (double)(bundleCount + 1);
    if (!isfinite(segmentWidth) || segmentWidth < 1.0) return;

    uint64_t container = axn_alloc_init_view("UIView", 0.0, 0.0, width, kAxonOverlayHeight);
    if (!r_is_objc_ptr(container)) return;
    r_msg2_main(container, "setTag:", kAxonOverlayBadgeTag, 0, 0, 0);
    r_msg2_main(container, "setUserInteractionEnabled:", 0, 0, 0, 0);

    uint64_t UIColor = r_class("UIColor");
    uint64_t white = r_is_objc_ptr(UIColor) ? r_msg2_main(UIColor, "whiteColor", 0, 0, 0, 0) : 0;
    uint64_t badgeColor = r_is_objc_ptr(UIColor) ? r_msg2_main(UIColor, "systemRedColor", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(badgeColor)) badgeColor = axn_color_white_alpha(0.0, 0.82);
    uint64_t font = axn_font_bold(11.0);

    for (int i = 0; i < bundleCount; i++) {
        char countText[8];
        if (bundles[i].count > 99) snprintf(countText, sizeof(countText), "99+");
        else snprintf(countText, sizeof(countText), "%d", bundles[i].count);

        double badgeWidth = bundles[i].count > 99 ? 30.0 : 22.0;
        double x = (segmentWidth * (double)(i + 2)) - badgeWidth - 3.0;
        if (x < segmentWidth * (double)(i + 1)) x = (segmentWidth * (double)(i + 1)) + 2.0;
        if (x + badgeWidth > width) x = width - badgeWidth;

        uint64_t label = axn_alloc_init_view("UILabel", x, 4.0, badgeWidth, 18.0);
        if (!r_is_objc_ptr(label)) continue;

        uint64_t text = r_nsstr_retained(countText);
        if (r_is_objc_ptr(text)) {
            r_msg2_main(label, "setText:", text, 0, 0, 0);
            axn_release_remote_obj(text);
        }
        if (r_is_objc_ptr(font)) r_msg2_main(label, "setFont:", font, 0, 0, 0);
        if (r_is_objc_ptr(white)) r_msg2_main(label, "setTextColor:", white, 0, 0, 0);
        if (r_is_objc_ptr(badgeColor)) r_msg2_main(label, "setBackgroundColor:", badgeColor, 0, 0, 0);
        r_msg2_main(label, "setTextAlignment:", 1, 0, 0, 0);
        uint64_t layer = axn_try_msg0_main(label, "layer");
        if (r_is_objc_ptr(layer)) {
            axn_send_double_main(layer, "setCornerRadius:", 9.0);
            r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
        }
        r_msg2_main(container, "addSubview:", label, 0, 0, 0);
        axn_release_remote_obj(label);
    }

    r_msg2_main(gAxonWindow, "addSubview:", container, 0, 0, 0);
    gAxonBadgeView = container;
    axn_release_remote_obj(container);
}

static void axn_cleanup_legacy_window(void)
{
    if (gAxonLegacyWindowCleaned) return;
    gAxonLegacyWindowCleaned = true;

    uint64_t UIApplication = r_class("UIApplication");
    uint64_t app = r_is_objc_ptr(UIApplication) ? r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(app)) return;

    uint64_t assocKey = r_sel("darkswordAxonLiteWindow");
    uint64_t cached = assocKey ? r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                              app, assocKey, 0, 0, 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(cached)) {
        r_msg2_main(cached, "setUserInteractionEnabled:", 0, 0, 0, 0);
        r_msg2_main(cached, "setHidden:", 1, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject", app, assocKey, 0, 1, 0, 0, 0, 0);
        printf("[AXONLITE] disabled legacy overlay window=0x%llx\n", cached);
    }
}

// Overlay is now a direct subview of the cover sheet's UIWindow. Earlier
// architectures: subview of CLVC.view ate taps (scroll view's pan
// recognizer); standalone UIWindow at level 1900 worked for taps but
// stayed on top everywhere. The cover sheet window already comes forward
// when the cover sheet is presented (lockscreen + notification center)
// and recedes when dismissed, so our overlay's visibility tracks that
// naturally. Adding above CLVC.view (not inside it) avoids the scroll-
// view pan-gesture conflict.
static bool axn_ensure_window(uint64_t clvc)
{
    axn_cleanup_legacy_window();

    uint64_t host = axn_try_msg0_main(clvc, "view");
    if (!r_is_objc_ptr(host)) {
        printf("[AXONLITE] notification host view unavailable\n");
        return false;
    }

    uint64_t hostWindow = axn_try_msg0_main(host, "window");
    if (!r_is_objc_ptr(hostWindow) && r_is_objc_ptr(gAxonCoverSheetWindow)) {
        // CLVC view isn't mounted in a window yet (cover sheet hasn't been
        // presented this session). The cover sheet's UIWindow itself still
        // exists — we cached it during the targeted scan. Use it directly so
        // we can attach the overlay before the user pulls down the cover sheet.
        hostWindow = gAxonCoverSheetWindow;
    }
    if (!r_is_objc_ptr(hostWindow)) {
        printf("[AXONLITE] host=0x%llx has no parent window\n", host);
        return false;
    }

    // Attach into the cover sheet's rootViewController.view rather than the
    // window itself: that view slides via transform when the cover sheet
    // dismisses, so our overlay naturally tracks the lock-screen <-> home-
    // screen transition. Window-level attachment kept the overlay onscreen
    // after dismiss because UIWindow doesn't move during the cover sheet
    // slide animation.
    uint64_t coverSheetVC = axn_try_msg0_main(hostWindow, "rootViewController");
    uint64_t parentView = r_is_objc_ptr(coverSheetVC) ?
                          axn_try_msg0_main(coverSheetVC, "view") : 0;
    if (!r_is_objc_ptr(parentView)) {
        printf("[AXONLITE] cover sheet rootViewController view unavailable\n");
        return false;
    }

    if (r_is_objc_ptr(gAxonWindow) && gAxonHostView == parentView) {
        r_msg2_main(gAxonWindow, "setHidden:", 0, 0, 0, 0);
        r_msg2_main(parentView, "bringSubviewToFront:", gAxonWindow, 0, 0, 0);
        return true;
    }

    if (r_is_objc_ptr(gAxonWindow)) {
        r_msg2_main(gAxonWindow, "setHidden:", 1, 0, 0, 0);
        r_msg2_main(gAxonWindow, "removeFromSuperview", 0, 0, 0, 0);
        axn_release_remote_obj(gAxonWindow);
        gAxonWindow = 0;
        gAxonControl = 0;
        gAxonControlCanSelect = false;
        gAxonBadgeView = 0;
        gAxonSpinner = 0;
        gAxonSpinnerHoldTicks = 0;
        gAxonSegmentSignature[0] = '\0';
        gAxonBadgeSignature[0] = '\0';
    }

    // Defensive: if our app-side gAxonWindow pointer was reset (e.g. via
    // axonlite_forget_remote_state during a session reconnect) but a
    // previous container is STILL attached to the cover-sheet rootView,
    // adding a new container would visually duplicate the icon strip.
    // Sweep any orphaned containers by tag before allocating fresh.
    int orphans = 0;
    while (1) {
        uint64_t stale = r_msg2_main(parentView, "viewWithTag:",
                                     kAxonOverlayContainerTag, 0, 0, 0);
        if (!r_is_objc_ptr(stale)) break;
        r_msg2_main(stale, "setHidden:", 1, 0, 0, 0);
        r_msg2_main(stale, "removeFromSuperview", 0, 0, 0, 0);
        orphans++;
        if (orphans >= 8) break;  // sanity cap
    }
    if (orphans > 0) {
        printf("[AXONLITE] cleared %d orphaned overlay container(s) from parentView\n", orphans);
    }

    // Position at the final cover-sheet spot immediately so the strip
    // doesn't flash in at (0,0) before axn_layout_window catches up.
    // Bundle count isn't known yet — use the cap (8) to size for max width;
    // axn_layout_window adjusts down when the real count arrives.
    double initialWidth = axn_overlay_width_for_count(kAxonMaxBundles);
    double initialScreenWidth = axn_screen_width();
    double initialScreenHeight = axn_screen_height();
    double initialX = fmax(kAxonOverlayMargin, (initialScreenWidth - initialWidth) / 2.0);
    double initialY = fmax(kAxonOverlayTopInsetMin, initialScreenHeight * kAxonOverlayTopInsetFraction);

    uint64_t container = axn_alloc_init_view("UIView", initialX, initialY, initialWidth, kAxonOverlayHeight);
    if (!r_is_objc_ptr(container)) {
        printf("[AXONLITE] overlay view allocation failed\n");
        return false;
    }
    r_msg2_main(container, "setTag:", kAxonOverlayContainerTag, 0, 0, 0);
    r_msg2_main(container, "setUserInteractionEnabled:", 1, 0, 0, 0);
    r_msg2_main(container, "setClipsToBounds:", 0, 0, 0, 0);

    uint64_t UIColor = r_class("UIColor");
    uint64_t clear = r_is_objc_ptr(UIColor) ? r_msg2_main(UIColor, "clearColor", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(clear)) r_msg2_main(container, "setBackgroundColor:", clear, 0, 0, 0);

    // Retain explicitly so we own a +1 reference; addSubview takes its own
    // retain. We hold gAxonWindow as our reference for the entire lifetime.
    r_msg2_main(container, "retain", 0, 0, 0, 0);
    r_msg2_main(parentView, "addSubview:", container, 0, 0, 0);
    r_msg2_main(parentView, "bringSubviewToFront:", container, 0, 0, 0);
    // Drop the +1 from alloc/init now that parentView has its own.
    axn_release_remote_obj(container);

    gAxonWindow = container;
    gAxonHostView = parentView;
    gAxonControl = 0;
    gAxonBadgeView = 0;
    gAxonSpinner = 0;
    gAxonSpinnerHoldTicks = 0;

    printf("[AXONLITE] overlay container=0x%llx parentView=0x%llx hostWindow=0x%llx (subview of cover sheet rootView)\n",
           (unsigned long long)container,
           (unsigned long long)parentView,
           (unsigned long long)hostWindow);
    return true;
}

static void axn_layout_window(int bundleCount)
{
    if (!r_is_objc_ptr(gAxonWindow)) return;

    double width = axn_overlay_width_for_count(bundleCount);
    double screenWidth = axn_screen_width();
    double screenHeight = axn_screen_height();
    double x = fmax(kAxonOverlayMargin, (screenWidth - width) / 2.0);
    double y = fmax(kAxonOverlayTopInsetMin, screenHeight * kAxonOverlayTopInsetFraction);

    axn_send_rect_main(gAxonWindow, "setFrame:",
                       x, y, width, kAxonOverlayHeight);
    if (r_is_objc_ptr(gAxonControl)) {
        axn_send_rect_main(gAxonControl, "setFrame:", 0.0, 0.0, width, kAxonOverlayHeight);
    }
    if (r_is_objc_ptr(gAxonBadgeView)) {
        axn_send_rect_main(gAxonBadgeView, "setFrame:", 0.0, 0.0, width, kAxonOverlayHeight);
    }
    if (r_is_objc_ptr(gAxonSpinner)) {
        // Hover over the first segment ("All"). Slightly smaller than the
        // segment so the All title/icon remains readable when the spinner
        // is hidden (hidesWhenStopped=YES). userInteractionEnabled=NO on the
        // spinner means the segment under it stays tappable.
        const double size = 28.0;
        double segmentWidth = width / (double)(bundleCount + 1);
        if (!isfinite(segmentWidth) || segmentWidth < 1.0) segmentWidth = width;
        axn_send_rect_main(gAxonSpinner, "setFrame:",
                           (segmentWidth - size) / 2.0,
                           (kAxonOverlayHeight - size) / 2.0,
                           size, size);
    }
}

static void axn_ensure_spinner(void)
{
    if (!r_is_objc_ptr(gAxonWindow)) return;
    if (r_is_objc_ptr(gAxonSpinner)) return;

    uint64_t cls = r_class("UIActivityIndicatorView");
    if (!r_is_objc_ptr(cls)) return;
    uint64_t alloc = r_msg2_main(cls, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(alloc)) return;
    // UIActivityIndicatorViewStyleLarge = 101 (37x37 intrinsic; small enough
    // to fit in a ~45px-wide segment over the "All" button).
    uint64_t spin = r_msg2_main(alloc, "initWithActivityIndicatorStyle:", 101, 0, 0, 0);
    if (!r_is_objc_ptr(spin)) return;

    r_msg2_main(spin, "setHidesWhenStopped:", 1, 0, 0, 0);
    r_msg2_main(spin, "setUserInteractionEnabled:", 0, 0, 0, 0);
    uint64_t UIColor = r_class("UIColor");
    uint64_t white = r_is_objc_ptr(UIColor) ?
                     r_msg2_main(UIColor, "whiteColor", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(white)) r_msg2_main(spin, "setColor:", white, 0, 0, 0);

    r_msg2_main(gAxonWindow, "addSubview:", spin, 0, 0, 0);
    r_msg2_main(gAxonWindow, "bringSubviewToFront:", spin, 0, 0, 0);
    gAxonSpinner = spin;

    // Start spinning the moment the overlay is created so the user sees
    // activity during initial cache build. Stops via the standard hold-
    // counter decrement after ~3 ticks (~2 s) once setup has settled.
    r_msg2_main(spin, "startAnimating", 0, 0, 0, 0);
    gAxonSpinnerHoldTicks = 3;
}

static void axn_show_spinner(bool show)
{
    if (!r_is_objc_ptr(gAxonSpinner)) return;
    if (show) {
        r_msg2_main(gAxonWindow, "bringSubviewToFront:", gAxonSpinner, 0, 0, 0);
        r_msg2_main(gAxonSpinner, "startAnimating", 0, 0, 0, 0);
    } else {
        r_msg2_main(gAxonSpinner, "stopAnimating", 0, 0, 0, 0);
    }
}

static bool axn_segment_signature(AXNBundle *bundles, int bundleCount, char *out, size_t outLen)
{
    if (!out || outLen == 0) return false;
    out[0] = '\0';
    strlcat(out, "—", outLen);
    for (int i = 0; i < bundleCount; i++) {
        char part[300];
        int hasIcon = r_is_objc_ptr(axn_lookup_cached_icon(bundles[i].bundle)) ? 1 : 0;
        snprintf(part, sizeof(part), "|%s:%s:i%d",
                 bundles[i].bundle, bundles[i].title, hasIcon);
        strlcat(out, part, outLen);
    }
    return true;
}

static bool axn_badge_signature(AXNBundle *bundles, int bundleCount, char *out, size_t outLen)
{
    if (!out || outLen == 0) return false;
    out[0] = '\0';
    for (int i = 0; i < bundleCount; i++) {
        char part[180];
        snprintf(part, sizeof(part), "|%s:%d", bundles[i].bundle, bundles[i].count);
        strlcat(out, part, outLen);
    }
    return true;
}

static bool axn_update_overlay(uint64_t clvc, AXNBundle *bundles, int bundleCount)
{
    if (!axn_ensure_window(clvc)) return false;
    axn_ensure_spinner();

    if (bundleCount > kAxonMaxBundles) bundleCount = kAxonMaxBundles;
    if (bundleCount <= 0 &&
        r_is_objc_ptr(gAxonControl) &&
        gAxonDisplayedCount > 1 &&
        gAxonSegmentSignature[0] != '\0') {
        if (gAxonTick <= 3 || (gAxonTick % 60) == 0) {
            printf("[AXONLITE] preserving icon strip while visible request cache is empty displayed=%d\n",
                   gAxonDisplayedCount - 1);
        }
        axn_layout_window(gAxonDisplayedCount - 1);
        return true;
    }

    char signature[sizeof(gAxonSegmentSignature)];
    axn_segment_signature(bundles, bundleCount, signature, sizeof(signature));
    char badgeSignature[sizeof(gAxonBadgeSignature)];
    axn_badge_signature(bundles, bundleCount, badgeSignature, sizeof(badgeSignature));

    if (gAxonSelectedBundle[0]) {
        bool found = false;
        for (int i = 0; i < bundleCount; i++) {
            if (strcmp(gAxonSelectedBundle, bundles[i].bundle) == 0) { found = true; break; }
        }
        if (!found) gAxonSelectedBundle[0] = '\0';
    }

    if (!r_is_objc_ptr(gAxonControl) || strcmp(signature, gAxonSegmentSignature) != 0) {
        if (r_is_objc_ptr(gAxonControl)) {
            r_msg2_main(gAxonControl, "removeFromSuperview", 0, 0, 0, 0);
            gAxonControl = 0;
        }
        // Defensive sweep: if gAxonControl was cleared without a matching
        // removeFromSuperview (state-forget path), an orphaned segmented
        // control may still be in gAxonWindow. Find by tag and remove.
        int stripOrphans = 0;
        while (1) {
            uint64_t stale = r_msg2_main(gAxonWindow, "viewWithTag:",
                                         kAxonOverlayTag, 0, 0, 0);
            if (!r_is_objc_ptr(stale)) break;
            r_msg2_main(stale, "removeFromSuperview", 0, 0, 0, 0);
            stripOrphans++;
            if (stripOrphans >= 4) break;
        }
        if (stripOrphans > 0) {
            printf("[AXONLITE] cleared %d orphaned strip(s) before rebuild\n", stripOrphans);
        }
        axn_clear_badges();

        printf("[AXONLITE] rebuilding icon strip bundles=%d cachedIcons=%d\n",
               bundleCount, gAxonIconCacheCount);
        uint64_t strip = axn_make_icon_strip(bundles, bundleCount);
        if (!r_is_objc_ptr(strip)) {
            printf("[AXONLITE] icon strip allocation failed\n");
            return false;
        }

        r_msg2_main(gAxonWindow, "addSubview:", strip, 0, 0, 0);
        gAxonControl = strip;
        gAxonControlCanSelect = true;
        axn_release_remote_obj(strip);
        axn_rebuild_badges(bundles, bundleCount);
        snprintf(gAxonSegmentSignature, sizeof(gAxonSegmentSignature), "%s", signature);
        snprintf(gAxonBadgeSignature, sizeof(gAxonBadgeSignature), "%s", badgeSignature);

        memset(gAxonDisplayedBundles, 0, sizeof(gAxonDisplayedBundles));
        gAxonDisplayedCount = bundleCount + 1;
        for (int i = 0; i < bundleCount; i++) {
            snprintf(gAxonDisplayedBundles[i + 1], sizeof(gAxonDisplayedBundles[i + 1]),
                     "%s", bundles[i].bundle);
        }

        printf("[AXONLITE] icon strip rebuilt bundles=%d\n", bundleCount);
        for (int i = 0; i < bundleCount; i++) {
            uint64_t icon = axn_lookup_cached_icon(bundles[i].bundle);
            printf("[AXONLITE] strip[%d] bundle=%s count=%d icon=0x%llx\n",
                   i + 1, bundles[i].bundle, bundles[i].count,
                   (unsigned long long)icon);
        }
        // Strip was just added, so it's now the topmost subview. Put the
        // spinner back on top so it's visible while it's animating.
        if (r_is_objc_ptr(gAxonSpinner)) {
            r_msg2_main(gAxonWindow, "bringSubviewToFront:", gAxonSpinner, 0, 0, 0);
        }
    } else if (strcmp(badgeSignature, gAxonBadgeSignature) != 0) {
        axn_rebuild_badges(bundles, bundleCount);
        snprintf(gAxonBadgeSignature, sizeof(gAxonBadgeSignature), "%s", badgeSignature);
        if (gAxonTick <= 3 || (gAxonTick % 60) == 0) {
            printf("[AXONLITE] badge counts refreshed bundles=%d\n", bundleCount);
        }
    }

    axn_layout_window(bundleCount);
    return true;
}

static void axn_cell_set_alpha(uint64_t cell, double alpha)
{
    if (!r_is_objc_ptr(cell)) return;
    r_msg2_main_raw(cell, "setCompositeAlpha:",
                    &alpha, sizeof(alpha), NULL, 0, NULL, 0, NULL, 0);
}

static void axn_cell_set_hidden_main(uint64_t cell, bool hidden)
{
    if (!r_is_objc_ptr(cell)) return;
    r_msg2_main(cell, "setHidden:", hidden ? 1 : 0, 0, 0, 0);
}

static uint64_t gAxonSetHiddenSel = 0;

static void axn_cells_set_hidden_batch(const uint64_t *cells, int count, bool hidden)
{
    if (count <= 0 || !cells) return;

    AXN_TAG("batch hide=%d count=%d ensure-sel", hidden, count);
    if (!gAxonSetHiddenSel) gAxonSetHiddenSel = r_sel("setHidden:");
    if (!gAxonSetHiddenSel) return;

    AXN_TAG("batch hide=%d count=%d malloc remote buf", hidden, count);
    size_t bufSize = (size_t)count * sizeof(uint64_t);
    uint64_t remoteBuf = do_remote_call_stable(R_TIMEOUT, "malloc",
                                               bufSize, 0, 0, 0, 0, 0, 0, 0);
    if (!remoteBuf) return;

    AXN_TAG("batch hide=%d count=%d remote_write buf=0x%llx",
            hidden, count, (unsigned long long)remoteBuf);
    if (!remote_write(remoteBuf, cells, bufSize)) {
        r_free(remoteBuf);
        return;
    }

    AXN_TAG("batch hide=%d count=%d arrayWithObjects:count:", hidden, count);
    uint64_t NSArray = r_class("NSArray");
    uint64_t arr = r_is_objc_ptr(NSArray)
        ? r_msg2(NSArray, "arrayWithObjects:count:", remoteBuf, (uint64_t)count, 0, 0)
        : 0;
    r_free(remoteBuf);
    if (!r_is_objc_ptr(arr)) return;

    AXN_TAG("batch hide=%d count=%d makeObjectsPerformSelector:setHidden: arr=0x%llx",
            hidden, count, (unsigned long long)arr);
    r_msg2_main(arr, "makeObjectsPerformSelector:withObject:",
                gAxonSetHiddenSel, hidden ? 1 : 0, 0, 0);
}

static void axn_show_request(uint64_t clvc, AXNRequestEntry *entry)
{
    (void)clvc;
    if (!entry || !r_is_objc_ptr(entry->request)) return;
    if (r_is_objc_ptr(entry->cell)) {
        r_msg2_main(entry->cell, "setHidden:", 0, 0, 0, 0);
        axn_cell_set_alpha(entry->cell, 1.0);
    }
    entry->hiddenByAxon = false;
}

static void axn_hide_request(uint64_t clvc, AXNRequestEntry *entry)
{
    if (!entry || !r_is_objc_ptr(entry->request)) return;
    if (r_is_objc_ptr(entry->cell)) {
        r_msg2_main(entry->cell, "setHidden:", 1, 0, 0, 0);
        axn_cell_set_alpha(entry->cell, 0.0);
        if (gAxonClvcCanRemove && r_is_objc_ptr(clvc)) {
            r_msg2_main(clvc, "removeNotificationRequest:", entry->request, 0, 0, 0);
        }
    }
    entry->hiddenByAxon = true;
}

static char gAxonLastAppliedFilter[128] = "";
static bool gAxonFilterLoggedOnce = false;
static char gAxonFilteredBundles[kAxonMaxRequests][128];
static int gAxonFilteredCount = 0;
static bool gAxonHistoryRevealedOnce = false;
static int gAxonModelCanGetSections = -1;

#define kAxonMaxToggledGroups 256
static uint64_t gAxonToggledGroups[kAxonMaxToggledGroups];
static int gAxonToggledGroupCount = 0;
#define kAxonMaxDynGroupingSections 32
static uint64_t gAxonDynGroupingDisabled[kAxonMaxDynGroupingSections];
static int gAxonDynGroupingDisabledCount = 0;

static bool axn_group_already_toggled(uint64_t group)
{
    for (int i = 0; i < gAxonToggledGroupCount; i++) {
        if (gAxonToggledGroups[i] == group) return true;
    }
    return false;
}

static void axn_group_mark_toggled(uint64_t group)
{
    if (gAxonToggledGroupCount >= kAxonMaxToggledGroups) return;
    gAxonToggledGroups[gAxonToggledGroupCount++] = group;
}

static bool axn_section_grouping_disabled(uint64_t section)
{
    for (int i = 0; i < gAxonDynGroupingDisabledCount; i++) {
        if (gAxonDynGroupingDisabled[i] == section) return true;
    }
    return false;
}

static void axn_section_grouping_mark_disabled(uint64_t section)
{
    if (gAxonDynGroupingDisabledCount >= kAxonMaxDynGroupingSections) return;
    gAxonDynGroupingDisabled[gAxonDynGroupingDisabledCount++] = section;
}

static uint64_t gAxonNCHeader = 0;
static bool gAxonNCHeaderTransformed = false;

static void axn_push_nc_header_down(uint64_t listModel)
{
    if (!r_is_objc_ptr(listModel)) return;
    if (!r_is_objc_ptr(gAxonNCHeader)) {
        uint64_t hist = r_ivar_value(listModel, "_historySectionList");
        if (!r_is_objc_ptr(hist)) return;
        if (!r_responds_main(hist, "headerView")) return;
        uint64_t header = r_msg2_main(hist, "headerView", 0, 0, 0, 0);
        if (!r_is_objc_ptr(header)) return;
        char cls[96] = "?";
        axn_object_class_name(header, cls, sizeof(cls));
        printf("[AXONLITE] NC header located header=0x%llx class=%s\n",
               (unsigned long long)header, cls);
        r_msg2_main(header, "retain", 0, 0, 0, 0);
        gAxonNCHeader = header;
    }
    if (gAxonNCHeaderTransformed) return;
    if (!r_responds_main(gAxonNCHeader, "setTransform:")) return;
    // CGAffineTransform = { a, b, c, d, tx, ty } = 6 doubles. Identity + ty.
    double t[6] = { 1.0, 0.0, 0.0, 1.0, 0.0, kAxonNCHeaderTranslateY };
    AXN_TAG("setTransform translate(0,%g) on NC header=0x%llx",
            kAxonNCHeaderTranslateY, (unsigned long long)gAxonNCHeader);
    r_msg2_main_raw(gAxonNCHeader, "setTransform:",
                    t, sizeof(t), NULL, 0, NULL, 0, NULL, 0);
    printf("[AXONLITE] NC header translated down by %g\n", kAxonNCHeaderTranslateY);
    gAxonNCHeaderTransformed = true;
}

static void axn_expand_coalesced_groups(uint64_t listModel)
{
    if (!r_is_objc_ptr(listModel)) return;
    if (gAxonModelCanGetSections < 0) {
        gAxonModelCanGetSections = r_responds_main(listModel, "notificationSections") ? 1 : 0;
        printf("[AXONLITE] probe listModel notificationSections=%d\n", gAxonModelCanGetSections);
    }
    if (!gAxonModelCanGetSections) return;

    uint32_t oldSettle = r_settle_us(1000);

    AXN_TAG("listModel=0x%llx notificationSections", (unsigned long long)listModel);
    uint64_t sections = r_msg2_main(listModel, "notificationSections", 0, 0, 0, 0);
    if (!r_is_objc_ptr(sections)) { r_settle_us(oldSettle); return; }
    AXN_TAG("sections=0x%llx count", (unsigned long long)sections);
    uint64_t nSec = r_msg2_main(sections, "count", 0, 0, 0, 0);

    int expanded = 0;
    int sectionsDisabled = 0;
    for (uint64_t si = 0; si < nSec; si++) {
        AXN_TAG("sections[%llu] objectAtIndex:", (unsigned long long)si);
        uint64_t section = r_msg2_main(sections, "objectAtIndex:", si, 0, 0, 0);
        if (!r_is_objc_ptr(section)) continue;

        // Note: previously called setSupportsDynamicGrouping:NO here.
        // It crashed SpringBoard asynchronously during layout — iOS structured
        // section lists assert if dynamic grouping is yanked at runtime.
        (void)sectionsDisabled;

        AXN_TAG("section[%llu] respondsTo:notificationGroups", (unsigned long long)si);
        if (!r_responds_main(section, "notificationGroups")) continue;
        AXN_TAG("section[%llu] notificationGroups", (unsigned long long)si);
        uint64_t groups = r_msg2_main(section, "notificationGroups", 0, 0, 0, 0);
        if (!r_is_objc_ptr(groups)) continue;
        AXN_TAG("section[%llu] groups=0x%llx count",
                (unsigned long long)si, (unsigned long long)groups);
        uint64_t nGrp = r_msg2_main(groups, "count", 0, 0, 0, 0);

        for (uint64_t gi = 0; gi < nGrp; gi++) {
            AXN_TAG("section[%llu].group[%llu] objectAtIndex:",
                    (unsigned long long)si, (unsigned long long)gi);
            uint64_t group = r_msg2_main(groups, "objectAtIndex:", gi, 0, 0, 0);
            if (!r_is_objc_ptr(group)) continue;
            if (axn_group_already_toggled(group)) continue;

            AXN_TAG("group=0x%llx isGrouped", (unsigned long long)group);
            uint64_t isGrouped = r_msg2_main(group, "isGrouped", 0, 0, 0, 0);
            if (!isGrouped) { axn_group_mark_toggled(group); continue; }
            AXN_TAG("group=0x%llx count", (unsigned long long)group);
            uint64_t cellCount = r_msg2_main(group, "count", 0, 0, 0, 0);
            if (cellCount <= 1) { axn_group_mark_toggled(group); continue; }
            AXN_TAG("group=0x%llx setGrouped:0 animated:0", (unsigned long long)group);
            r_msg2_main(group, "setGrouped:animated:", 0, 0, 0, 0);
            axn_group_mark_toggled(group);
            expanded++;
        }
    }
    if (expanded > 0) {
        printf("[AXONLITE] expand walk: groups=%d (total_toggled=%d)\n",
               expanded, gAxonToggledGroupCount);
    }

    r_settle_us(oldSettle);
}

typedef struct { char bundle[128]; uint64_t nsstr; } AXNSectionIdCache;
static AXNSectionIdCache gAxonSectionIdCache[kAxonMaxRequests];
static int gAxonSectionIdCount = 0;

static uint64_t axn_section_id_for_bundle(const char *bundle)
{
    if (!bundle || !bundle[0]) return 0;
    for (int i = 0; i < gAxonSectionIdCount; i++) {
        if (strcmp(gAxonSectionIdCache[i].bundle, bundle) == 0) {
            return gAxonSectionIdCache[i].nsstr;
        }
    }
    if (gAxonSectionIdCount >= kAxonMaxRequests) return 0;
    uint64_t ns = r_nsstr_retained(bundle);
    if (!r_is_objc_ptr(ns)) return 0;
    AXNSectionIdCache *e = &gAxonSectionIdCache[gAxonSectionIdCount++];
    snprintf(e->bundle, sizeof(e->bundle), "%s", bundle);
    e->nsstr = ns;
    return ns;
}

static void axn_section_id_cache_clear(void)
{
    for (int i = 0; i < gAxonSectionIdCount; i++) {
        if (r_is_objc_ptr(gAxonSectionIdCache[i].nsstr)) {
            axn_release_remote_obj(gAxonSectionIdCache[i].nsstr);
        }
    }
    memset(gAxonSectionIdCache, 0, sizeof(gAxonSectionIdCache));
    gAxonSectionIdCount = 0;
}

static int axn_filtered_index(const char *bundle)
{
    for (int i = 0; i < gAxonFilteredCount; i++) {
        if (strcmp(gAxonFilteredBundles[i], bundle) == 0) return i;
    }
    return -1;
}

static void axn_filtered_add(const char *bundle)
{
    if (!bundle || !bundle[0]) return;
    if (axn_filtered_index(bundle) >= 0) return;
    if (gAxonFilteredCount >= kAxonMaxRequests) return;
    snprintf(gAxonFilteredBundles[gAxonFilteredCount++], 128, "%s", bundle);
}

static void axn_filtered_remove(const char *bundle)
{
    int idx = axn_filtered_index(bundle);
    if (idx < 0) return;
    for (int j = idx; j < gAxonFilteredCount - 1; j++) {
        memcpy(gAxonFilteredBundles[j], gAxonFilteredBundles[j + 1], 128);
    }
    gAxonFilteredCount--;
    memset(gAxonFilteredBundles[gAxonFilteredCount], 0, 128);
}

// Drive section-level filtering via
// toggleFilteringForSectionIdentifier:shouldFilter:. This is the only
// reversible primitive stock SB exposes on
// NCNotificationStructuredListViewController — removeNotificationRequest:
// works one-way but insertNotificationRequest: no-ops on a previously-
// removed request, so the old remove/insert path could hide but never
// restore. Section identifier is taken to be the bundle ID
// (axn_section_id_for_bundle wraps it as an NSString).
// Per-request hide/restore. Hide uses removeNotificationRequest: on the
// controller — empirically the only primitive that visually removes cells
// on iOS 18's NCNotificationRootModernList listView. Restore tries
// _insertNotificationRequest: directly on the listModel (the underscore
// method is the ObjC workhorse that the Swift insert(_:) wraps with a
// strict update-tracking check that rejects previously-removed requests).
// If the private insert isn't available, restore degrades to no-op until
// the user re-runs the chain.
static void axn_apply_filter(uint64_t clvc, uint64_t tick)
{
    if (!r_is_objc_ptr(clvc)) return;
    if (!gAxonClvcCanRemove) return;

    uint32_t axonOldSettle = r_settle_us(1000);

    // Re-poll segmented control RIGHT NOW: if the user tapped during this
    // tick (after the start-of-tick poll), this catches it and lets the
    // filter fire in the same tick instead of waiting for the next one.
    axn_update_selected_from_control();

    bool filterEnabled = gAxonSelectedBundle[0] != '\0';
    bool selectionChanged = strcmp(gAxonSelectedBundle, gAxonLastAppliedFilter) != 0;
    uint64_t model = r_is_objc_ptr(gAxonListModel) ? gAxonListModel : 0;
    bool canRestore = r_is_objc_ptr(model) && gAxonModelCanPrivateInsert;

    if (selectionChanged) {
        printf("[AXONLITE] filter begin tick=%llu desired=%s prev=%s tracked=%d restoreVia=%s\n",
               (unsigned long long)tick,
               gAxonSelectedBundle[0] ? gAxonSelectedBundle : "All",
               gAxonLastAppliedFilter[0] ? gAxonLastAppliedFilter : "All",
               gAxonRequestCount,
               canRestore ? "model._insert" : "none");
        axn_show_spinner(true);
        gAxonSpinnerHoldTicks = 2;
    }

    // Chunked async: fire kAxonAsyncBatchSize ops, then sync-flush via
    // _notificationListDidChangeContent to drain. Historical comment:
    // 76-op bursts panicked the kernel, so 20 per batch leaves headroom.
    // Async is ~3x faster than sync per call (no settle wait), and the
    // periodic flush keeps SB's view layer caught up with the data model.
    const int kAxonAsyncBatchSize = 20;
    int removed = 0;
    int inserted = 0;
    int restoreSkipped = 0;
    int batchSinceFlush = 0;
    int flushes = 0;

    for (int i = 0; i < gAxonRequestCount; i++) {
        AXNRequestEntry *e = &gAxonRequests[i];
        if (!r_is_objc_ptr(e->request) || !e->bundle[0]) continue;

        bool wantsVisible = !filterEnabled || strcmp(e->bundle, gAxonSelectedBundle) == 0;
        bool fired = false;

        if (!wantsVisible && !e->hiddenByAxon) {
            // Only record the hide once the dispatch succeeded; a failed
            // async call leaves the entry as-is for the next pass.
            if (r_msg2_main_async(clvc, "removeNotificationRequest:", e->request, 0, 0, 0)) {
                e->hiddenByAxon = true;
                e->hiddenCell = 0;
                removed++;
                fired = true;
            }
        } else if (wantsVisible && e->hiddenByAxon) {
            if (!canRestore) {
                restoreSkipped++;
                continue;
            }
            if (r_msg2_main_async(model, "_insertNotificationRequest:", e->request, 0, 0, 0)) {
                e->hiddenByAxon = false;
                inserted++;
                fired = true;
            }
        }

        if (fired && ++batchSinceFlush >= kAxonAsyncBatchSize) {
            if (gAxonModelCanNotifyContentChange && r_is_objc_ptr(model)) {
                r_msg2_main(model, "_notificationListDidChangeContent", 0, 0, 0, 0);
                flushes++;
            }
            batchSinceFlush = 0;
        }
    }

    // Final drain so any partial batch is flushed.
    if ((removed > 0 || inserted > 0) && gAxonModelCanNotifyContentChange &&
        r_is_objc_ptr(model) && batchSinceFlush > 0) {
        r_msg2_main(model, "_notificationListDidChangeContent", 0, 0, 0, 0);
        flushes++;
    }

    if (selectionChanged) {
        snprintf(gAxonLastAppliedFilter, sizeof(gAxonLastAppliedFilter), "%s", gAxonSelectedBundle);
    }

    if (selectionChanged || removed || inserted || restoreSkipped) {
        printf("[AXONLITE] filter selected=%s removed=%d inserted=%d skipped=%d flushes=%d tracked=%d\n",
               gAxonSelectedBundle[0] ? gAxonSelectedBundle : "All",
               removed, inserted, restoreSkipped, flushes, gAxonRequestCount);
        gAxonFilterLoggedOnce = true;
    }

    if (gAxonSpinnerHoldTicks > 0) {
        gAxonSpinnerHoldTicks--;
        if (gAxonSpinnerHoldTicks == 0) axn_show_spinner(false);
    }

    // Visual ground-truth probe: after the filter pass, read back what SB
    // actually has in its visible-cell cache and the segmented control's
    // selected index. listCache.count drops when removeNotificationRequest:
    // actually tore down cells; it rises when _insertNotificationRequest:
    // restored them. segIdx is the raw value SB sees on the strip (caught
    // here even if our polling missed the change).
    int64_t cellsCount = -1;
    uint64_t cells = r_is_objc_ptr(model) ? axn_cells_for_requests_from_model(model) : 0;
    if (r_is_objc_ptr(cells)) {
        cellsCount = (int64_t)axn_msg0_cached(cells, AXNSelCount, "count");
    }
    int64_t segIdx = -1;
    if (r_is_objc_ptr(gAxonControl) && gAxonControlCanSelect) {
        segIdx = (int64_t)r_msg2_main(gAxonControl, "selectedSegmentIndex", 0, 0, 0, 0);
    }
    int hiddenByAxonCount = 0;
    for (int i = 0; i < gAxonRequestCount; i++) {
        if (gAxonRequests[i].hiddenByAxon) hiddenByAxonCount++;
    }
    printf("[AXONLITE] visual tick=%llu listCache=%lld segIdx=%lld selectedBundle=%s hiddenByAxon=%d tracked=%d\n",
           (unsigned long long)tick,
           (long long)cellsCount,
           (long long)segIdx,
           gAxonSelectedBundle[0] ? gAxonSelectedBundle : "All",
           hiddenByAxonCount,
           gAxonRequestCount);

    r_settle_us(axonOldSettle);
}

bool axonlite_apply_in_session(void)
{
    axn_install_crash_handler_once();
    uint32_t oldSettleUS = r_settle_us(kAxonRemoteSettleUS);
    gAxonTick++;
    axn_update_selected_from_control();

    for (int i = 0; i < gAxonRequestCount; i++) gAxonRequests[i].cell = 0;

    AXN_TAG("apply tick=%llu find_clvc", (unsigned long long)gAxonTick);
    uint64_t clvc = axn_find_notification_list_controller();
    if (r_is_objc_ptr(clvc)) {
        AXN_TAG("apply tick=%llu probe_methods", (unsigned long long)gAxonTick);
        axn_probe_controller_methods(clvc, gAxonCombined);

        if (!gAxonHistoryRevealedOnce) {
            if (gAxonCombinedCanForceReveal && r_is_objc_ptr(gAxonCombined)) {
                r_msg2_main(gAxonCombined, "forceNotificationHistoryRevealed:animated:", 1, 0, 0, 0);
                printf("[AXONLITE] forced history reveal once (combined)\n");
                gAxonHistoryRevealedOnce = true;
            } else if (gAxonClvcCanReveal) {
                r_msg2_main(clvc, "revealNotificationHistory:animated:", 1, 0, 0, 0);
                printf("[AXONLITE] forced history reveal once (clvc)\n");
                gAxonHistoryRevealedOnce = true;
            }
        }

        if (!gAxonDisplayStyleAssertion &&
            gAxonCombinedCanOverrideStyle &&
            r_is_objc_ptr(gAxonCombined)) {
            uint64_t reason = r_nsstr_retained("NCNotificationListDisplayStyleReasonInteractiveTransition");
            uint64_t assertion = r_msg2_main(gAxonCombined,
                "acquireOverrideNotificationListDisplayStyleAssertionWithStyle:hideNotificationCount:reason:",
                0,
                0,
                reason,
                0);
            if (r_is_objc_ptr(assertion)) {
                r_msg2_main(assertion, "retain", 0, 0, 0, 0);
                gAxonDisplayStyleAssertion = assertion;
                printf("[AXONLITE] acquired display-style assertion=0x%llx style=STANDARD\n",
                       (unsigned long long)assertion);
            } else {
                printf("[AXONLITE] acquire display-style assertion FAILED\n");
            }
            if (r_is_objc_ptr(reason)) axn_release_remote_obj(reason);
        }

        // Notification-Center header push-down is now handled by
        // axn_push_nc_header_down (targets _historySectionList.headerView
        // via setTransform:). The earlier contentInset approach on
        // [clvc listView] was wrong — that listView is the outer scroll
        // container holding the clock, so its inset moved the clock instead.

        AXN_TAG("apply tick=%llu cache_visible_requests", (unsigned long long)gAxonTick);
        axn_cache_visible_requests(clvc, gAxonTick);
        bool structuralTick = gAxonTick <= 2 || (gAxonTick % 12) == 0;
        if (structuralTick) {
            AXN_TAG("apply tick=%llu expand_coalesced_groups", (unsigned long long)gAxonTick);
            axn_expand_coalesced_groups(gAxonListModel);
        }
        if (!gAxonNCHeaderTransformed || structuralTick) {
            AXN_TAG("apply tick=%llu push_nc_header_down", (unsigned long long)gAxonTick);
            axn_push_nc_header_down(gAxonListModel);
        }
    }

    AXN_TAG("apply tick=%llu build_bundles", (unsigned long long)gAxonTick);
    AXNBundle bundles[kAxonMaxBundles];
    int bundleCount = axn_build_display_bundles(bundles, kAxonMaxBundles, gAxonTick);
    AXN_TAG("apply tick=%llu hydrate_pending_icons n=%d", (unsigned long long)gAxonTick, bundleCount);
    axn_hydrate_pending_icons(bundles, bundleCount, gAxonTick);
    AXN_TAG("apply tick=%llu update_overlay", (unsigned long long)gAxonTick);
    bool overlayOK = r_is_objc_ptr(clvc) ? axn_update_overlay(clvc, bundles, bundleCount) : false;

    AXN_TAG("apply tick=%llu apply_filter", (unsigned long long)gAxonTick);
    if (r_is_objc_ptr(clvc)) axn_apply_filter(clvc, gAxonTick);
    AXN_TAG("apply tick=%llu DONE", (unsigned long long)gAxonTick);

    if (gAxonTick <= 2 || (gAxonTick % 120) == 0) {
        printf("[AXONLITE] tick=%llu bundles=%d selected=%s overlay=%d clvc=0x%llx\n",
               (unsigned long long)gAxonTick,
               bundleCount,
               gAxonSelectedBundle[0] ? gAxonSelectedBundle : "All",
               overlayOK,
               clvc);
    }
    r_settle_us(oldSettleUS);
    return overlayOK;
}

bool axonlite_reset_selection_in_session(void)
{
    gAxonSelectedBundle[0] = '\0';
    if (r_is_objc_ptr(gAxonControl) && gAxonControlCanSelect) {
        r_msg2_main(gAxonControl, "setSelectedSegmentIndex:", 0, 0, 0, 0);
    }
    return true;
}

bool axonlite_stop_in_session(void)
{
    // Cleanup mode used to return almost instantly; the regression was that
    // we now retain ~100 NCNotificationRequest pointers plus do a few
    // main-thread bounces (display-style assertion, NC-header transform,
    // window hidden). At the default 50ms settle, each release call costs
    // ~55ms and each main-thread bounce ~750ms, so total stop time exceeded
    // 5s. Drop the settle to 1ms for the cleanup pass.
    uint32_t oldSettleUS = r_settle_us(1000);

    uint64_t clvc = r_is_objc_ptr(gAxonCLVC) ? gAxonCLVC : 0;
    if (!r_is_objc_ptr(clvc) && r_is_objc_ptr(gAxonCombined)) {
        uint64_t cached = axn_try_msg0_main(gAxonCombined, "notificationListViewController");
        if (r_is_objc_ptr(cached)) clvc = cached;
    }

    int restored = 0;
    int restoreSkipped = 0;
    gAxonSelectedBundle[0] = '\0';

    uint64_t model = r_is_objc_ptr(gAxonListModel) ? gAxonListModel : 0;
    bool canRestore = r_is_objc_ptr(model) && gAxonModelCanPrivateInsert;
    for (int i = 0; i < gAxonRequestCount; i++) {
        AXNRequestEntry *entry = &gAxonRequests[i];
        if (!entry->hiddenByAxon) continue;
        if (!canRestore || !r_is_objc_ptr(entry->request)) {
            restoreSkipped++;
            continue;
        }
        r_msg2_main(model, "_insertNotificationRequest:", entry->request, 0, 0, 0);
        entry->hiddenByAxon = false;
        restored++;
    }
    if (restored > 0 && gAxonModelCanNotifyContentChange) {
        r_msg2_main(model, "_notificationListDidChangeContent", 0, 0, 0, 0);
    }

    if (r_is_objc_ptr(gAxonDisplayStyleAssertion)) {
        r_msg2_main(gAxonDisplayStyleAssertion, "invalidate", 0, 0, 0, 0);
        axn_release_remote_obj(gAxonDisplayStyleAssertion);
        gAxonDisplayStyleAssertion = 0;
    }

    if (r_is_objc_ptr(gAxonWindow)) {
        r_msg2_main(gAxonWindow, "setHidden:", 1, 0, 0, 0);
        r_msg2_main(gAxonWindow, "removeFromSuperview", 0, 0, 0, 0);
        axn_release_remote_obj(gAxonWindow);
        gAxonWindow = 0;
    }
    for (int i = 0; i < gAxonRequestCount; i++) {
        if (gAxonRequests[i].retained) axn_release_remote_obj(gAxonRequests[i].request);
    }
    for (int i = 0; i < gAxonIconCacheCount; i++) {
        if (r_is_objc_ptr(gAxonIconCache[i].image)) {
            axn_release_remote_obj(gAxonIconCache[i].image);
        }
    }

    memset(gAxonRequests, 0, sizeof(gAxonRequests));
    memset(gAxonIconCache, 0, sizeof(gAxonIconCache));
    gAxonRequestCount = 0;
    gAxonIconCacheCount = 0;
    gAxonLastAppliedFilter[0] = '\0';
    gAxonFilterLoggedOnce = false;
    memset(gAxonFilteredBundles, 0, sizeof(gAxonFilteredBundles));
    gAxonFilteredCount = 0;
    gAxonHistoryRevealedOnce = false;
    if (gAxonNCHeaderTransformed && r_is_objc_ptr(gAxonNCHeader)) {
        double identity[6] = { 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 };
        r_msg2_main_raw(gAxonNCHeader, "setTransform:",
                        identity, sizeof(identity),
                        NULL, 0, NULL, 0, NULL, 0);
    }
    axn_release_remote_obj(gAxonNCHeader);
    gAxonNCHeader = 0;
    gAxonNCHeaderTransformed = false;
    gAxonListInsetApplied = false;
    gAxonModelCanGetSections = -1;
    memset(gAxonToggledGroups, 0, sizeof(gAxonToggledGroups));
    gAxonToggledGroupCount = 0;
    memset(gAxonDynGroupingDisabled, 0, sizeof(gAxonDynGroupingDisabled));
    gAxonDynGroupingDisabledCount = 0;
    gAxonSetHiddenSel = 0;
    axn_section_id_cache_clear();
    gAxonCLVC = 0;
    gAxonCombined = 0;
    gAxonCoverSheetWindow = 0;
    gAxonControllerProbedOnce = false;
    gAxonClvcCanRemove = false;
    gAxonClvcCanInsert = false;
    gAxonClvcCanToggleFilter = false;
    gAxonClvcCanReveal = false;
    gAxonClvcCanListView = false;
    gAxonModelProbed = false;
    gAxonModelProbedPtr = 0;
    gAxonModelCanToggleFilter = false;
    gAxonModelCanPrivateInsert = false;
    gAxonModelCanNotifyContentChange = false;
    gAxonCombinedCanForceReveal = false;
    gAxonCombinedCanOverrideStyle = false;
    gAxonCombinedProbedOnce = false;
    gAxonControl = 0;
    gAxonControlCanSelect = false;
    gAxonWindow = 0;
    gAxonHostView = 0;
    gAxonBadgeView = 0;
    gAxonSpinner = 0;
    gAxonSpinnerHoldTicks = 0;
    gAxonDisplayedCount = 0;
    gAxonSegmentSignature[0] = '\0';
    gAxonBadgeSignature[0] = '\0';
    gAxonLoggedControllerMiss = false;
    printf("[AXONLITE] stopped clvc=0x%llx restored=%d skipped=%d\n",
           clvc, restored, restoreSkipped);
    r_settle_us(oldSettleUS);
    return true;
}

bool axonlite_stop_in_session_fast(void)
{
    // Fast path used when SpringBoard is about to die (respring, OTA toggle).
    // Skip the per-request _insertNotificationRequest: restore and per-object
    // release loops — both are wasted work since SB will reload everything
    // from the bulletin service and discard refcounts on death.
    int hidden = 0;
    for (int i = 0; i < gAxonRequestCount; i++) {
        if (gAxonRequests[i].hiddenByAxon) hidden++;
    }
    int retained = 0;
    for (int i = 0; i < gAxonRequestCount; i++) {
        if (gAxonRequests[i].retained) retained++;
    }
    printf("[AXONLITE] stopped (fast) hiddenSkipped=%d releasesSkipped=%d iconsSkipped=%d\n",
           hidden, retained, gAxonIconCacheCount);
    axonlite_forget_remote_state();
    return true;
}

void axonlite_forget_remote_state(void)
{
    memset(gAxonRequests, 0, sizeof(gAxonRequests));
    memset(gAxonIconCache, 0, sizeof(gAxonIconCache));
    memset(gAxonDisplayedBundles, 0, sizeof(gAxonDisplayedBundles));
    memset(gAxonFilteredBundles, 0, sizeof(gAxonFilteredBundles));
    memset(gAxonSectionIdCache, 0, sizeof(gAxonSectionIdCache));
    // Cached class/selector/ivar pointers are baked from a *specific* SB
    // address space. After a SB respawn (ASLR re-rolls), every one of these
    // is a stale pointer; calling through them is the PAC fault path.
    memset(gAxonSels, 0, sizeof(gAxonSels));
    memset(gAxonIvars, 0, sizeof(gAxonIvars));
    memset(gAxonToggledGroups, 0, sizeof(gAxonToggledGroups));

    gAxonRequestCount = 0;
    gAxonIconCacheCount = 0;
    gAxonCLVC = 0;
    gAxonCombined = 0;
    gAxonCoverSheetWindow = 0;
    gAxonWindow = 0;
    gAxonHostView = 0;
    gAxonControl = 0;
    gAxonBadgeView = 0;
    gAxonSpinner = 0;
    gAxonSpinnerHoldTicks = 0;
    gAxonModelOwnerCLVC = 0;
    gAxonListModel = 0;
    gAxonListCache = 0;
    gAxonCellsForRequests = 0;
    gAxonControlCanSelect = false;
    gAxonDisplayedCount = 0;
    gAxonSelectedBundle[0] = '\0';
    gAxonSegmentSignature[0] = '\0';
    gAxonBadgeSignature[0] = '\0';
    gAxonLoggedControllerMiss = false;
    gAxonControllerProbedOnce = false;
    gAxonClvcCanRemove = false;
    gAxonClvcCanInsert = false;
    gAxonClvcCanToggleFilter = false;
    gAxonClvcCanReveal = false;
    gAxonClvcCanListView = false;
    gAxonModelProbed = false;
    gAxonModelProbedPtr = 0;
    gAxonModelCanToggleFilter = false;
    gAxonModelCanPrivateInsert = false;
    gAxonModelCanNotifyContentChange = false;
    gAxonCombinedCanForceReveal = false;
    gAxonCombinedCanOverrideStyle = false;
    gAxonCombinedProbedOnce = false;
    gAxonDisplayStyleAssertion = 0;
    gAxonLastAppliedFilter[0] = '\0';
    gAxonFilterLoggedOnce = false;
    gAxonFilteredCount = 0;
    gAxonHistoryRevealedOnce = false;
    gAxonSectionIdCount = 0;
    gAxonNCHeader = 0;
    gAxonNCHeaderTransformed = false;
    gAxonListInsetApplied = false;
    gAxonModelCanGetSections = -1;
    gAxonToggledGroupCount = 0;
    gAxonDynGroupingDisabledCount = 0;
    gAxonSetHiddenSel = 0;
    gAxonScanCursor = 0;
    gAxonLegacyWindowCleaned = false;
    gAxonStructuredClass = 0;
    gAxonCombinedClass = 0;
    gAxonCSCombinedClass = 0;
    gAxonCSCoverSheetClass = 0;
    gAxonCSMainPageClass = 0;
    gAxonBadgedIconViewClass = 0;
    gAxonStructuredClassTried = false;
    gAxonCombinedClassTried = false;
    gAxonCSCombinedClassTried = false;
    gAxonCSCoverSheetClassTried = false;
    gAxonCSMainPageClassTried = false;
    gAxonBadgedIconViewClassTried = false;
    gAxonWarmupLogBudget = 24;
    gAxonTick = 0;

    printf("[AXONLITE] forgot remote overlay/filter state\n");
}

bool axonlite_initial_cache_ready(void)
{
    return gAxonTick >= 2;
}
