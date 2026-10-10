//
//  location_services.h
//  Cyanide
//
//  System-wide Location Services on/off, the same switch as Settings ->
//  Privacy & Security -> Location Services. Sent as
//  +[CLLocationManager setLocationServicesEnabled:] from a process locationd
//  accepts it from: SpringBoard first, Preferences as the fallback.
//

#ifndef location_services_h
#define location_services_h

#include <stdbool.h>

// Current state as seen by this app (no entitlement needed to read it):
// 1 = on, 0 = off.
int locationservices_enabled_local(void);

// What became of a setter request. NotSent: nothing reached the target
// (class/selector missing, session unusable) — the state can't change.
// Sent: the call completed. Uncertain: the call may or may not have run
// (transport lost its result) — verify by reading the state, never resend.
typedef enum {
    LSCallNotSent = 0,
    LSCallSent,
    LSCallUncertain,
} LSCallResult;

// Waits until the local state reads `enabled`, up to timeoutMS measured on a
// monotonic clock (query time included). Stops early, returning false, when
// the app starts leaving the foreground.
bool locationservices_wait_for_state(bool enabled, int timeoutMS);

// Sends the request through the already-open SpringBoard RemoteCall session.
LSCallResult locationservices_set_enabled_in_session(bool enabled);

// Fallback: sends the request from Preferences, but only if Preferences is
// already running (it is never launched: a foreground launch would push
// Cyanide into the background mid-operation). Opens and closes its own
// RemoteCall session; the caller must have closed any SpringBoard session.
LSCallResult locationservices_set_enabled_via_running_preferences(bool enabled);

#endif /* location_services_h */
