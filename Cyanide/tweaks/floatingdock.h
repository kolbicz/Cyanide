//
//  floatingdock.h
//  Cyanide
//
//  iPad Dock: SpringBoard's own iPad-style ("floating") Dock with the App
//  Library button, on iPhone. Ported from hxhlb/cyanide (by Banana,
//  AGPL-3.0). In memory for the current SpringBoard session; Clean Up or a
//  respring brings the stock Dock back.
//

#ifndef floatingdock_h
#define floatingdock_h

#import <stdbool.h>

bool floatingdock_apply_in_session(void);
// Something to restore: set up in this launch, or a saved session.
bool floatingdock_has_state(void);
bool floatingdock_stop_in_session(void);
// Sizes and lays out the iPad Dock for its current icons again: SBCustomizer
// changes the Dock's icons (count, apps moved in) after the iPad Dock exists,
// and the iPad Dock keeps the slots it was built with.
bool floatingdock_relayout_in_session(void);
void floatingdock_forget_remote_state(void);

#endif /* floatingdock_h */
