//
//  location_services.m
//  Cyanide
//

#import "location_services.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../TaskRop/Exception.h"   // excport_gate_blocked: leaving the foreground
#import "../LogTextView.h"   // mirror printf into the chain log

#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>
#import <unistd.h>

int locationservices_enabled_local(void)
{
    return [CLLocationManager locationServicesEnabled] ? 1 : 0;
}

bool locationservices_wait_for_state(bool enabled, int timeoutMS)
{
    uint64_t deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + (uint64_t)timeoutMS * 1000000ULL;
    for (;;) {
        if (locationservices_enabled_local() == (enabled ? 1 : 0)) return true;
        if (excport_gate_blocked()) return false;   // leaving the foreground
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        if (now >= deadline) return false;
        uint64_t left = deadline - now;
        usleep((useconds_t)MIN(left / 1000ULL, 100000ULL));
    }
}

// +[CLLocationManager setLocationServicesEnabled:] in whatever process the
// current RemoteCall session targets. locationd checks the caller's
// entitlements; SpringBoard and Preferences both hold the locationd ones the
// Settings switch needs.
static LSCallResult locationservices_call_in_current(bool enabled, const char *host)
{
    uint64_t cls = r_class("CLLocationManager");
    if (!r_is_objc_ptr(cls)) {
        uint64_t path = r_alloc_str("/System/Library/Frameworks/CoreLocation.framework/CoreLocation");
        if (path) {
            r_dlsym_call(R_TIMEOUT, "dlopen", path, RTLD_LAZY | RTLD_GLOBAL, 0, 0, 0, 0, 0, 0);
            r_free(path);
        }
        cls = r_class("CLLocationManager");
    }
    if (!r_is_objc_ptr(cls)) {
        printf("[LOCSVC] CLLocationManager unavailable in %s\n", host);
        return LSCallNotSent;
    }
    // Class object: respondsToSelector: answers for class methods.
    if (!r_responds(cls, "setLocationServicesEnabled:")) {
        printf("[LOCSVC] +setLocationServicesEnabled: missing in %s\n", host);
        return LSCallNotSent;
    }
    r_msg2(cls, "setLocationServicesEnabled:", enabled ? 1 : 0, 0, 0, 0);
    LSCallResult r = r_last_call_ok() ? LSCallSent : LSCallUncertain;
    printf("[LOCSVC] %s: setLocationServicesEnabled:%d %s\n", host, enabled,
           r == LSCallSent ? "sent" : "UNCERTAIN (result lost)");
    return r;
}

LSCallResult locationservices_set_enabled_in_session(bool enabled)
{
    return locationservices_call_in_current(enabled, "SpringBoard");
}

static bool locationservices_ios_below_18(void)
{
    NSInteger major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    return major > 0 && major < 18;
}

LSCallResult locationservices_set_enabled_via_running_preferences(bool enabled)
{
    // Short first-exception budget: a running Preferences traps quickly; a
    // missing one fails at once, a suspended one would never trap.
    const int kFirstTrapMS = 3000;
    int rc = locationservices_ios_below_18()
        ? init_remote_call_original_thread_only_with_first_exception_timeout("Preferences", false, kFirstTrapMS)
        : init_remote_call_with_first_exception_timeout("Preferences", false, kFirstTrapMS);
    if (rc != 0) {
        printf("[LOCSVC] Preferences not usable (%s pid=%u) — not launching it\n",
               remote_call_init_failure_description(remote_call_last_init_failure()),
               remote_call_last_init_failure_pid());
        return LSCallNotSent;
    }
    LSCallResult r = locationservices_call_in_current(enabled, "Preferences");
    destroy_remote_call();
    return r;
}
