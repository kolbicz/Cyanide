//
//  locked_previews.m
//  Cyanide
//
//  See locked_previews.h. Found in iOS 18.0.1's BulletinBoard:
//  -[BBServer protectionStateChangedForBundleIdentifiers:] sets a locked
//  app's section contentPreviewSetting to 3 and, once the app is no longer
//  locked, a 3 back to 0 (default), saving the section either way. Its only
//  question is -[BBAppProtectionMonitor isApplicationLocked:]; publishing
//  asks isApplicationHidden: instead, so hidden apps stay hidden.
//

#import "locked_previews.h"
#import "remote_objc.h"
#import "../LogTextView.h"
#import "../TaskRop/RemoteCall.h"

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <sys/sysctl.h>
#import <sys/time.h>

#define LP_LOCKED_PREVIEW_SETTING 3

static uint64_t gLPMethod = 0;
static uint64_t gLPOriginalImp = 0;
static bool gLPApplied = false;

// isApplicationLocked:'s own IMP, kept across Cyanide launches so a later
// session can still put it back. Shared-cache addresses hold for the boot.
static NSString *const kLPOriginalImpKey = @"CyanideLockedPreviewsOriginalImp";
static NSString *const kLPOriginalImpBootKey = @"CyanideLockedPreviewsOriginalImpBootTime";
static NSString *const kLPRelockPendingKey = @"CyanideLockedPreviewsRelockPending";

static uint64_t lp_boot_time(void)
{
    struct timeval bootTime = {0};
    size_t size = sizeof(bootTime);
    if (sysctlbyname("kern.boottime", &bootTime, &size, NULL, 0) != 0) return 0;
    return (uint64_t)bootTime.tv_sec;
}

static void lp_save_original_imp(uint64_t imp)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:@(imp) forKey:kLPOriginalImpKey];
    [d setObject:@(lp_boot_time()) forKey:kLPOriginalImpBootKey];
}

static uint64_t lp_saved_original_imp(void)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([[d objectForKey:kLPOriginalImpBootKey] unsignedLongLongValue] != lp_boot_time()) return 0;
    return [[d objectForKey:kLPOriginalImpKey] unsignedLongLongValue];
}

static void lp_clear_saved_original_imp(void)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d removeObjectForKey:kLPOriginalImpKey];
    [d removeObjectForKey:kLPOriginalImpBootKey];
}

static uint64_t lp_locked_method(void)
{
    uint64_t cls = r_class("BBAppProtectionMonitor");
    uint64_t sel = r_sel("isApplicationLocked:");
    if (!r_is_objc_ptr(cls) || !sel) return 0;
    return r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod", cls, sel, 0, 0, 0, 0, 0, 0);
}

// -[NSObject isProxy] returns NO and ignores the argument.
static uint64_t lp_false_imp(void)
{
    uint64_t NSObject = r_class("NSObject");
    uint64_t sel = r_sel("isProxy");
    if (!r_is_objc_ptr(NSObject) || !sel) return 0;
    uint64_t method = r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod", NSObject, sel, 0, 0, 0, 0, 0, 0);
    return method ? r_dlsym_call(R_TIMEOUT, "method_getImplementation", method, 0, 0, 0, 0, 0, 0, 0) : 0;
}

// The BBServer instance is a BulletinBoard static next to the exported
// __BBServerQueue (0x128 before it on 18.0.1). Nearby words are accepted
// only when their isa is BBServer's class, read from memory, so nothing is
// ever messaged that isn't the server.
static uint64_t lp_find_server(void)
{
    uint64_t serverCls = r_class("BBServer");
    uint64_t name = r_alloc_str("__BBServerQueue");
    uint64_t queueSym = name ? r_dlsym_call(R_TIMEOUT, "dlsym", (uint64_t)-2, name, 0, 0, 0, 0, 0, 0) : 0;
    if (name) r_free(name);
    if (!r_is_objc_ptr(serverCls) || !queueSym) {
        printf("[LOCKPREV] BBServer class 0x%llx or __BBServerQueue 0x%llx missing\n", serverCls, queueSym);
        return 0;
    }

    enum { kWords = 0x100 };
    uint64_t base = queueSym - (kWords / 2) * 8;
    uint64_t words[kWords] = {0};
    if (!remote_read(base, words, sizeof(words))) {
        printf("[LOCKPREV] reading around __BBServerQueue failed\n");
        return 0;
    }
    for (int i = 0; i < kWords; i++) {
        uint64_t candidate = words[i];
        if (!r_is_objc_ptr(candidate) || (candidate & 7)) continue;
        uint64_t isa = 0;
        if (!remote_read(candidate, &isa, sizeof(isa))) continue;
        if (isa == serverCls ||
            (isa & 0x0000000ffffffff8ULL) == serverCls ||
            (isa & 0x007ffffffffffff8ULL) == serverCls) {
            printf("[LOCKPREV] BBServer 0x%llx at __BBServerQueue%+lld\n",
                   candidate, (long long)(base + i * 8) - (long long)queueSym);
            return candidate;
        }
    }
    printf("[LOCKPREV] no BBServer near __BBServerQueue 0x%llx\n", queueSym);
    return 0;
}

// Section IDs from the server's saved section infos: with onlyLocked, the
// ones whose preview setting is the locked value 3; otherwise all of them.
static uint64_t lp_section_ids(bool onlyLocked, uint64_t *countOut)
{
    *countOut = 0;
    uint64_t serverCls = r_class("BBServer");
    uint64_t saved = r_msg2(serverCls, "savedSectionInfo", 0, 0, 0, 0);
    if (!r_is_objc_ptr(saved)) {
        printf("[LOCKPREV] savedSectionInfo unavailable\n");
        return 0;
    }
    uint64_t ids = 0;
    if (onlyLocked) {
        uint64_t values = r_msg2(saved, "allValues", 0, 0, 0, 0);
        uint64_t format = r_nsstr_retained("contentPreviewSetting == 3");
        uint64_t predicate = format ? r_msg2(r_class("NSPredicate"), "predicateWithFormat:", format, 0, 0, 0) : 0;
        uint64_t locked = (r_is_objc_ptr(values) && r_is_objc_ptr(predicate))
            ? r_msg2(values, "filteredArrayUsingPredicate:", predicate, 0, 0, 0) : 0;
        uint64_t key = r_nsstr_retained("sectionID");
        ids = (r_is_objc_ptr(locked) && key) ? r_msg2(locked, "valueForKey:", key, 0, 0, 0) : 0;
        if (key) r_release(key);
        if (format) r_release(format);
    } else {
        ids = r_msg2(saved, "allKeys", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(ids)) return 0;
    *countOut = r_msg2(ids, "count", 0, 0, 0, 0);
    return r_msg2(r_class("NSSet"), "setWithArray:", ids, 0, 0, 0);
}

// Async on the server's own queue; the server saves and broadcasts the result.
static bool lp_reevaluate(uint64_t server, uint64_t ids)
{
    if (!r_is_objc_ptr(server) || !r_is_objc_ptr(ids)) return false;
    r_msg2(server, "protectionStateChangedForBundleIdentifiers:", ids, 0, 0, 0);
    return r_last_call_ok();
}

bool lockedpreviews_apply_in_session(void)
{
    uint64_t method = lp_locked_method();
    uint64_t falseImp = lp_false_imp();
    if (!method || !falseImp) {
        log_user("[LOCKPREV] This iOS version has no App Protection notification check (needs iOS 18). Nothing changed.\n");
        return false;
    }
    uint64_t server = lp_find_server();
    if (!server) {
        log_user("[LOCKPREV] The notification server could not be found on this iOS build. Nothing changed.\n");
        return false;
    }

    uint64_t current = r_dlsym_call(R_TIMEOUT, "method_getImplementation", method, 0, 0, 0, 0, 0, 0, 0);
    if (current != falseImp) {
        uint64_t old = r_dlsym_call(R_TIMEOUT, "method_setImplementation", method, falseImp, 0, 0, 0, 0, 0, 0);
        if (!old) {
            printf("[LOCKPREV] method_setImplementation failed\n");
            return false;
        }
        gLPOriginalImp = old;
        lp_save_original_imp(old);
    } else {
        gLPOriginalImp = lp_saved_original_imp();
    }
    gLPMethod = method;
    gLPApplied = true;

    uint64_t count = 0;
    uint64_t ids = lp_section_ids(true, &count);
    printf("[LOCKPREV] isApplicationLocked: patched; %llu locked section(s)\n", count);
    if (count > 0 && !lp_reevaluate(server, ids)) {
        printf("[LOCKPREV] re-evaluation call failed\n");
        return false;
    }
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kLPRelockPendingKey];
    log_user("[LOCKPREV] Previews restored for %llu Face ID-locked app(s).\n", count);
    return true;
}

bool lockedpreviews_stop_in_session(void)
{
    uint64_t method = gLPMethod ?: lp_locked_method();
    uint64_t falseImp = lp_false_imp();
    if (!method || !falseImp) return false;

    uint64_t current = r_dlsym_call(R_TIMEOUT, "method_getImplementation", method, 0, 0, 0, 0, 0, 0, 0);
    if (current == falseImp) {
        uint64_t original = gLPOriginalImp ?: lp_saved_original_imp();
        if (!original) {
            log_user("[LOCKPREV] The original check isn't known any more; respring to lock the previews again.\n");
            return false;
        }
        r_dlsym_call(R_TIMEOUT, "method_setImplementation", method, original, 0, 0, 0, 0, 0, 0);
    }
    lp_clear_saved_original_imp();
    gLPApplied = false;

    // With the real check back, the server sets locked apps to 3 again.
    uint64_t server = lp_find_server();
    uint64_t count = 0;
    uint64_t ids = server ? lp_section_ids(false, &count) : 0;
    bool ok = count == 0 || lp_reevaluate(server, ids);
    printf("[LOCKPREV] stopped; re-evaluated %llu section(s) ok=%d\n", count, ok);
    if (ok) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kLPRelockPendingKey];
        log_user("[LOCKPREV] Previews of Face ID-locked apps are hidden again.\n");
    }
    return ok;
}

bool lockedpreviews_relock_pending(void)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:kLPRelockPendingKey];
}

void lockedpreviews_forget_remote_state(void)
{
    gLPMethod = 0;
    gLPOriginalImp = 0;
    gLPApplied = false;
}
