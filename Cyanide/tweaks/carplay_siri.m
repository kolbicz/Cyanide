//
//  carplay_siri.m
//  Cyanide
//
//  See carplay_siri.h. From iOS 18.0.1's DashBoard.framework:
//   - -[DBSiriMonitor _updateSiriEnabled] stores
//     AFPreferences.assistantIsEnabled && assistantIsSupportedForLanguageCode:
//     through -setSiriEnabled:, which tells its observers only when the value
//     changes. It runs at init and on AFPreferencesDidChangeNotification.
//   - -[DBLockOutController updateLockOutModeAnimated:takeScreen:] picks
//     lock-out mode 3 (LOCKOUT_SIRI_MESSAGE) when -siriEnabled is NO; it
//     re-checks when the monitor reports a change, among other events.
//
//  So: -siriEnabled is swapped to an IMP that answers YES (any later check
//  passes), and -[AFPreferences assistantIsEnabled] answers YES for a moment
//  while a preferences-changed notification is posted, so the monitor flips
//  to YES and tells the lock-out controller. assistantIsEnabled is put back
//  afterwards. Everything stays inside the CarPlay process, which exits when
//  the car disconnects.
//

#import "carplay_siri.h"
#import "remote_objc.h"
#import "../LogTextView.h"
#import "../TaskRop/RemoteCall.h"
#import "../kexploit/kutils.h"

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <unistd.h>

static const char *const kCPSProcess = "CarPlay";

static uint64_t cps_method(const char *className, const char *selName)
{
    uint64_t cls = r_class(className);
    uint64_t sel = r_sel(selName);
    if (!r_is_objc_ptr(cls) || !sel) return 0;
    return r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod", cls, sel, 0, 0, 0, 0, 0, 0);
}

static uint64_t cps_imp(uint64_t method)
{
    return method ? r_dlsym_call(R_TIMEOUT, "method_getImplementation", method, 0, 0, 0, 0, 0, 0, 0) : 0;
}

// -[NSObject allowsWeakReference] answers YES for any live object and has no
// side effects: used as "return YES".
static uint64_t cps_true_imp(void)
{
    return cps_imp(cps_method("NSObject", "allowsWeakReference"));
}

// The NSString behind an exported notification-name constant.
static uint64_t cps_string_constant(const char *symbol)
{
    uint64_t name = r_alloc_str(symbol);
    uint64_t addr = name ? r_dlsym_call(R_TIMEOUT, "dlsym", (uint64_t)-2, name, 0, 0, 0, 0, 0, 0) : 0;
    if (name) r_free(name);
    if (!addr) return 0;
    uint64_t str = 0;
    if (!remote_read(addr, &str, sizeof(str))) return 0;
    return r_is_objc_ptr(str) ? str : 0;
}

static CarPlaySiriResult cps_apply_in_session(void)
{
    uint64_t monitorGetter = cps_method("DBSiriMonitor", "siriEnabled");
    uint64_t assistantEnabled = cps_method("AFPreferences", "assistantIsEnabled");
    uint64_t trueImp = cps_true_imp();
    uint64_t notificationName = cps_string_constant("AFPreferencesDidChangeNotification");
    printf("[CARPLAY] siriEnabled=0x%llx assistantIsEnabled=0x%llx yes=0x%llx note=0x%llx\n",
           monitorGetter, assistantEnabled, trueImp, notificationName);
    if (!monitorGetter || !assistantEnabled || !trueImp || !notificationName) {
        log_user("[CARPLAY] This iOS version has no CarPlay Siri check Cyanide knows. Nothing changed.\n");
        return CarPlaySiriUnsupported;
    }

    // 1. The monitor's answer: YES from now on, for this CarPlay process.
    if (cps_imp(monitorGetter) != trueImp) {
        uint64_t old = r_dlsym_call(R_TIMEOUT, "method_setImplementation", monitorGetter, trueImp, 0, 0, 0, 0, 0, 0);
        if (!old || cps_imp(monitorGetter) != trueImp) {
            printf("[CARPLAY] swapping -[DBSiriMonitor siriEnabled] failed\n");
            return CarPlaySiriFailed;
        }
    } else {
        printf("[CARPLAY] -[DBSiriMonitor siriEnabled] already patched\n");
    }

    // 2. Make the monitor re-check and report the change: assistantIsEnabled
    // answers YES while the preferences notification is handled.
    uint64_t originalAssistant = r_dlsym_call(R_TIMEOUT, "method_setImplementation",
                                              assistantEnabled, trueImp, 0, 0, 0, 0, 0, 0);
    if (!originalAssistant) {
        printf("[CARPLAY] swapping -[AFPreferences assistantIsEnabled] failed\n");
        return CarPlaySiriFailed;
    }
    uint64_t center = r_msg2(r_class("NSNotificationCenter"), "defaultCenter", 0, 0, 0, 0);
    bool posted = false;
    if (r_is_objc_ptr(center)) {
        r_msg2_main(center, "postNotificationName:object:", notificationName, 0, 0, 0);
        posted = r_last_main_ok();
    }
    // The monitor and the lock-out controller may finish on the main queue.
    usleep(1500000);
    if (originalAssistant != trueImp) {
        r_dlsym_call(R_TIMEOUT, "method_setImplementation", assistantEnabled, originalAssistant, 0, 0, 0, 0, 0, 0);
    }
    printf("[CARPLAY] notification posted=%d, assistantIsEnabled restored\n", posted);
    if (!posted) {
        log_user("[CARPLAY] CarPlay was patched, but it didn't re-check Siri. Apply again.\n");
        return CarPlaySiriFailed;
    }
    return CarPlaySiriApplied;
}

bool carplaysiri_connected(void)
{
    return proc_find_by_name(kCPSProcess) != 0;
}

CarPlaySiriResult carplaysiri_apply(void)
{
    if (init_remote_call(kCPSProcess, false) != 0) {
        if (remote_call_last_init_failure() == RemoteCallInitFailureProcessMissing) {
            log_user("[CARPLAY] CarPlay isn't connected right now. Apply again while the car shows "
                     "\"CarPlay Not Available\".\n");
            return CarPlaySiriNotConnected;
        }
        log_user("[CARPLAY] Couldn't attach to CarPlay (%s).\n",
                 remote_call_init_failure_description(remote_call_last_init_failure()));
        return CarPlaySiriFailed;
    }
    CarPlaySiriResult result = CarPlaySiriFailed;
    @try {
        result = cps_apply_in_session();
    } @catch (NSException *e) {
        printf("[CARPLAY] exception: %s\n", e.reason.UTF8String);
    } @finally {
        destroy_remote_call();
    }
    if (result == CarPlaySiriApplied) {
        log_user("[CARPLAY] CarPlay works without Siri until the car disconnects.\n");
    }
    return result;
}
