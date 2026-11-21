//
//  killallapps.m
//

#import "killallapps.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../TaskRop/PAC.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <string.h>

// SpringBoard's `_SBWorkspaceKillApplication` is a `(local|regular)` symbol —
// it appears in nlist for debug, but isn't in the export trie. dlsym can't
// find it. Workaround: compute SpringBoard's runtime slide from a known
// SBApplicationController IMP (which IS exported via the ObjC runtime), then
// add the IDA static address of the C function and invoke by address with
// do_remote_call_stable_addr.
//
// Static addresses below come from
//   /System/Library/CoreServices/SpringBoard.app/SpringBoard
// in iPhone17,2 iOS 26.0.1 dyld_shared_cache_arm64e.
static const uint64_t kStaticAllApplicationsIMP = 0x21d58dbb4ULL;  // -[SBApplicationController allApplications]
static const uint64_t kStaticKillApplication    = 0x21d651064ULL;  // _SBWorkspaceKillApplication

static uint64_t gSBKillAppAddr = 0;

static uint64_t resolve_sb_workspace_kill_addr(void)
{
    if (gSBKillAppAddr) return gSBKillAppAddr;

    uint64_t cls = r_class("SBApplicationController");
    if (!r_is_objc_ptr(cls)) {
        printf("[KILLALL] resolve: SBApplicationController class missing\n");
        return 0;
    }
    uint64_t sel = r_sel("allApplications");
    if (!sel) {
        printf("[KILLALL] resolve: allApplications sel missing\n");
        return 0;
    }
    uint64_t impSigned = r_dlsym_call(R_TIMEOUT, "class_getMethodImplementation",
                                       cls, sel, 0, 0, 0, 0, 0, 0);
    if (!impSigned) {
        printf("[KILLALL] resolve: class_getMethodImplementation returned 0\n");
        return 0;
    }
    uint64_t imp = native_strip(impSigned);
    if (imp < kStaticAllApplicationsIMP) {
        printf("[KILLALL] resolve: IMP 0x%llx below static base 0x%llx; cache shape changed?\n",
               imp, kStaticAllApplicationsIMP);
        return 0;
    }
    uint64_t slide = imp - kStaticAllApplicationsIMP;
    gSBKillAppAddr = kStaticKillApplication + slide;
    printf("[KILLALL] resolved SBWorkspaceKillApplication imp=0x%llx slide=0x%llx -> addr=0x%llx\n",
           imp, slide, gSBKillAppAddr);
    return gSBKillAppAddr;
}

void killallapps_forget_remote_state(void)
{
    gSBKillAppAddr = 0;
}

// Best-effort: read up to maxLen bytes of a C string from a remote address
// using 64-bit remote reads. Used only for diagnostic logging — the kill
// itself doesn't need the bundle id in our address space.
static bool remote_read_cstr(uint64_t addr, char *buf, size_t maxLen)
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

// Bundle-id-based heuristic that distinguishes App-Switcher-visible apps
// from background extensions, widget renderers, and system UI services.
// `runningApplications` is too broad — it includes things like
// com.apple.chrono.WidgetRenderer-Default and com.apple.StickerKit.*, which
// aren't cards in the switcher.
//
// We tried filtering by SBMainSwitcherControllerCoordinator.recentAppLayouts
// instead — definitively correct, but on iOS 26 the +sharedInstance path
// blocked on heavy init and never returned for us. This is the pragmatic
// fallback: substring + exact denylist. False positives (skipping a real
// app) just mean it stays alive; false negatives (killing a non-switcher
// app) are the bug we're fixing.
static bool bid_is_skippable(const char *bid)
{
    if (!bid || !*bid) return true;

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
        if (strcmp(bid, deny_exact[i]) == 0) return true;
    }

    static const char *deny_sub[] = {
        "WidgetRenderer",
        "PickerService",
        "ExtensionService",
        "ViewService",
        "UIService",
        "UIHost",
        ".XPCService",
        ".extension",
        ".Extension",
        NULL,
    };
    for (int i = 0; deny_sub[i]; i++) {
        if (strstr(bid, deny_sub[i])) return true;
    }
    return false;
}

bool killallapps_apply_in_session(int *outKilled)
{
    if (outKilled) *outKilled = 0;

    uint64_t killFn = resolve_sb_workspace_kill_addr();
    if (!killFn) {
        printf("[KILLALL] could not resolve SBWorkspaceKillApplication\n");
        return false;
    }

    uint64_t SBAC = r_class("SBApplicationController");
    if (!r_is_objc_ptr(SBAC)) {
        printf("[KILLALL] SBApplicationController class missing\n");
        return false;
    }
    uint64_t inst = r_msg2_main(SBAC, "sharedInstance", 0, 0, 0, 0);
    if (!r_is_objc_ptr(inst)) {
        printf("[KILLALL] sharedInstance nil\n");
        return false;
    }
    // A fresh array: fetched and retained in one checked step, so it stays
    // alive while we walk it (and isn't released after an unknown retain).
    uint64_t apps = r_msg2_main_retained(inst, "runningApplications");
    if (!apps) {
        printf("[KILLALL] runningApplications unavailable\n");
        return false;
    }
    uint64_t count = r_msg2_main(apps, "count", 0, 0, 0, 0);
    printf("[KILLALL] running apps=%llu\n", count);
    if (count == 0) { r_release(apps); return true; }
    // Sanity cap to bail on a garbled return value rather than spinning forever.
    if (count > 256) {
        printf("[KILLALL] absurd count=%llu, aborting\n", count);
        r_release(apps);
        return false;
    }

    int killed = 0;
    int skipped = 0;
    bool unknown = false;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t app = r_msg2_main(apps, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(app)) continue;
        uint64_t bid = r_msg2_main(app, "bundleIdentifier", 0, 0, 0, 0);
        if (!r_is_objc_ptr(bid)) continue;

        char bidBuf[128] = {0};
        uint64_t cstr = r_msg2_main(bid, "UTF8String", 0, 0, 0, 0);
        if (!cstr) continue;
        if (!remote_read_cstr(cstr, bidBuf, sizeof(bidBuf))) continue;
        if (!bidBuf[0]) continue;

        if (bid_is_skippable(bidBuf)) {
            skipped++;
            printf("[KILLALL] skip bid='%s' (denylist)\n", bidBuf);
            continue;
        }

        // Soft kill — matches App Switcher swipe semantics (BKS exit reason 5,
        // no crash report). force=1 would map to reason 1 and is harsher than
        // we want here. The function is non-exported in SpringBoard's mach-o,
        // so we invoke by computed runtime address.
        do_remote_call_stable_addr(R_TIMEOUT, killFn, "SBWorkspaceKillApplication",
                                   app, 0, 0, 0, 0, 0, 0, 0);
        if (!remote_call_last_call_ok()) {
            // May or may not have run, and the session is now suspect: stop
            // instead of sending more kills through it.
            unknown = true;
            printf("[KILLALL] kill of bid='%s' result unknown (reply lost); stopping\n", bidBuf);
            break;
        }
        killed++;
        printf("[KILLALL] killed bid='%s' app=0x%llx\n", bidBuf, app);
    }
    r_release(apps);

    // Only confirmed kills are counted.
    if (outKilled) *outKilled = killed;
    printf("[KILLALL] done killed=%d skipped=%d%s\n", killed, skipped, unknown ? " (incomplete)" : "");
    return !unknown;
}
