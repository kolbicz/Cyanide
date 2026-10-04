//
//  AppDelegate.h
//  Cyanide
//
//  Created by seo on 3/24/26.
//

#import <UIKit/UIKit.h>

// Round 31: pre-header launch trace. Appends ONE line straight to
// Documents/live.log with raw open/write/fsync — no log mutex, no log_user,
// no app machinery — so the line lands even when the process wedges before
// the first log call (the black-screen-with-zero-new-headers failure: after
// the 19:33:01 clean park, relaunches produced NO new session headers, which
// means either no fresh process ever spawned or it died before
// didFinishLaunching's first log; these markers, starting at main() entry,
// discriminate the two on the next repro). Safe to call from main().
void cyanide_launch_trace(const char *point);

@interface AppDelegate : UIResponder <UIApplicationDelegate>


@end

