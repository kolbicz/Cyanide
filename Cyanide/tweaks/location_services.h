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

// Waits up to timeoutMS for the local state to read `enabled`.
bool locationservices_wait_for_state(bool enabled, int timeoutMS);

// Sends the request through the already-open SpringBoard RemoteCall session.
// Returns whether the call reached SpringBoard; check the state afterwards.
bool locationservices_set_enabled_in_session(bool enabled);

// Fallback: launches Preferences, opens its own RemoteCall session, sends the
// request there and closes the session. The caller must have closed any
// SpringBoard session first (this briefly opens its own to launch the app).
bool locationservices_set_enabled_via_preferences(bool enabled);

#endif /* location_services_h */
