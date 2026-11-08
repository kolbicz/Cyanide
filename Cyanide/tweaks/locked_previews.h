//
//  locked_previews.h
//  Cyanide
//
//  Locked App Previews: notification previews for apps locked with
//  "Require Face ID" (iOS 18 App Protection). When an app is locked, the
//  bulletin server (BulletinBoard, in SpringBoard) sets that app's preview
//  setting to 3, which hides the content whatever Settings says. This makes
//  -[BBAppProtectionMonitor isApplicationLocked:] answer NO and has the
//  server re-evaluate the locked apps, which turns 3 back into the default,
//  so the normal preview settings apply again. Opening the app still asks
//  for Face ID.
//
//  The preview settings are saved by the server, so they stay after a
//  respring; turning the tweak off locks them again.
//

#ifndef locked_previews_h
#define locked_previews_h

#import <stdbool.h>

bool lockedpreviews_apply_in_session(void);
bool lockedpreviews_stop_in_session(void);
void lockedpreviews_forget_remote_state(void);
// True after a successful apply until a stop has locked the previews again
// (survives Cyanide and SpringBoard restarts, like the saved settings).
bool lockedpreviews_relock_pending(void);

#endif /* locked_previews_h */
