//
//  location_services.m
//  Cyanide
//

#import "location_services.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
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
    for (int waited = 0; ; waited += 100) {
        if (locationservices_enabled_local() == (enabled ? 1 : 0)) return true;
        if (waited >= timeoutMS) return false;
        usleep(100000);
    }
}

// +[CLLocationManager setLocationServicesEnabled:] in whatever process the
// current RemoteCall session targets. locationd checks the caller's
// entitlements; SpringBoard and Preferences both hold the locationd ones the
// Settings switch needs.
static bool locationservices_call_in_current(bool enabled, const char *host)
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
        return false;
    }
    // Class object: respondsToSelector: answers for class methods.
    if (!r_responds(cls, "setLocationServicesEnabled:")) {
        printf("[LOCSVC] +setLocationServicesEnabled: missing in %s\n", host);
        return false;
    }
    r_msg2(cls, "setLocationServicesEnabled:", enabled ? 1 : 0, 0, 0, 0);
    bool ok = r_last_call_ok();
    printf("[LOCSVC] %s: setLocationServicesEnabled:%d sent=%d\n", host, enabled, ok);
    return ok;
}

bool locationservices_set_enabled_in_session(bool enabled)
{
    return locationservices_call_in_current(enabled, "SpringBoard");
}

static bool locationservices_ios_below_18(void)
{
    NSInteger major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    return major > 0 && major < 18;
}

// Same launch path as the Location Simulator uses for Maps: a short-lived
// SpringBoard session calls SBSLaunchApplicationWithIdentifier.
static bool locationservices_launch_preferences(void)
{
    if (init_remote_call("SpringBoard", false) != 0) {
        printf("[LOCSVC] init_remote_call(SpringBoard) failed while launching Preferences\n");
        return false;
    }
    bool ok = false;
    uint64_t bid = r_nsstr_retained("com.apple.Preferences");
    if (r_is_objc_ptr(bid)) {
        r_dlsym_call(R_TIMEOUT, "SBSLaunchApplicationWithIdentifier", bid, 0, 0, 0, 0, 0, 0, 0);
        ok = r_last_call_ok();
        r_release(bid);
    }
    destroy_remote_call();
    usleep(locationservices_ios_below_18() ? 3000000 : 1500000);
    return ok;
}

bool locationservices_set_enabled_via_preferences(bool enabled)
{
    if (!locationservices_launch_preferences())
        printf("[LOCSVC] Preferences launch did not report success; trying it anyway\n");

    // iOS 17 apps need the original-thread path (as Maps does for the
    // Location Simulator).
    int rc = locationservices_ios_below_18()
        ? init_remote_call_original_thread_only_with_first_exception_timeout("Preferences", false, 120000)
        : init_remote_call("Preferences", false);
    if (rc != 0) {
        printf("[LOCSVC] init_remote_call(Preferences) failed (%s pid=%u)\n",
               remote_call_init_failure_description(remote_call_last_init_failure()),
               remote_call_last_init_failure_pid());
        return false;
    }
    bool ok = locationservices_call_in_current(enabled, "Preferences");
    destroy_remote_call();
    return ok;
}
