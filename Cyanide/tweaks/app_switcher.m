//
//  app_switcher.m
//  Cyanide
//

#import "app_switcher.h"
#import "remote_objc.h"
#import "../LogTextView.h"   // mirror printf into the chain log

#import <Foundation/Foundation.h>
#import <stdio.h>

// The switcher's owner and its delete-by-bundle selector, newest first:
// iOS 16+ moved the switcher model into SBMainSwitcherControllerCoordinator;
// earlier releases kept it on SBMainSwitcherViewController.
static const char *const kSwitcherClasses[] = {
    "SBMainSwitcherControllerCoordinator",
    "SBMainSwitcherViewController",
};
static const char *const kDeleteSelectors[] = {
    "_deleteAppLayoutsMatchingBundleIdentifier:",
    "deleteAppLayoutsMatchingBundleIdentifier:",
};

bool appswitcher_schedule_remove_in_session(const char *bundleID, double delaySeconds)
{
    if (!bundleID || !bundleID[0]) return false;
    // +sharedInstance blocked on heavy init on iOS 26 (see killallapps.m).
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26) {
        printf("[SWITCHER] card removal not supported on iOS 26+\n");
        return false;
    }

    uint64_t owner = 0;
    const char *deleteSel = NULL;
    for (size_t c = 0; c < sizeof(kSwitcherClasses) / sizeof(kSwitcherClasses[0]) && !deleteSel; c++) {
        uint64_t cls = r_class(kSwitcherClasses[c]);
        if (!r_is_objc_ptr(cls) || !r_responds(cls, "sharedInstance")) continue;
        uint64_t inst = r_msg2_main(cls, "sharedInstance", 0, 0, 0, 0);
        if (!r_is_objc_ptr(inst)) continue;
        for (size_t s = 0; s < sizeof(kDeleteSelectors) / sizeof(kDeleteSelectors[0]); s++) {
            if (r_responds(inst, kDeleteSelectors[s])) {
                owner = inst;
                deleteSel = kDeleteSelectors[s];
                printf("[SWITCHER] using -[%s %s]\n", kSwitcherClasses[c], deleteSel);
                break;
            }
        }
    }
    if (!deleteSel) {
        printf("[SWITCHER] no delete-by-bundle selector found; card left in place\n");
        return false;
    }

    uint64_t bid = r_nsstr_retained(bundleID);
    uint64_t sel = r_sel(deleteSel);
    if (!r_is_objc_ptr(bid) || !sel) {
        if (r_is_objc_ptr(bid)) r_release(bid);
        return false;
    }
    // Must be sent on SpringBoard's main thread: afterDelay: schedules on the
    // calling thread's run loop, and our synthetic call thread has none.
    // performSelector:withObject:afterDelay: retains owner and argument until
    // it fires, so our reference can go right away.
    double delay = delaySeconds;
    r_msg2_main_raw(owner, "performSelector:withObject:afterDelay:",
                    &sel, sizeof(sel), &bid, sizeof(bid), &delay, sizeof(delay), NULL, 0);
    bool ok = r_last_main_ok();
    r_release(bid);
    printf("[SWITCHER] card removal for %s %s (in %.1fs)\n",
           bundleID, ok ? "scheduled" : "could not be scheduled", delaySeconds);
    return ok;
}
