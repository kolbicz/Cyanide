//
//  app_switcher.h
//  Cyanide
//

#ifndef app_switcher_h
#define app_switcher_h

#include <stdbool.h>

// Asks SpringBoard to delete every App Switcher card of `bundleID` after
// `delaySeconds`, as if the user had swiped it away (which also ends the app).
// The deletion is scheduled on SpringBoard's own main run loop, so it runs
// after this RemoteCall session is gone. Needs an open SpringBoard session;
// reports whether a removal timer may now exist in SpringBoard.
typedef enum {
    ASRemovalNotScheduled = 0,   // definitely no timer (unsupported, selector missing, …)
    ASRemovalScheduled,          // the scheduling call completed
    ASRemovalUnknown,            // the call was sent but its result was lost: treat as scheduled
} ASRemovalResult;
ASRemovalResult appswitcher_schedule_remove_in_session(const char *bundleID, double delaySeconds);

#endif /* app_switcher_h */
