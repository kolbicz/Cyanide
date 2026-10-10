//
//  SceneDelegate.h
//  Cyanide
//
//  Created by seo on 3/24/26.
//

#import <UIKit/UIKit.h>

// Outcome of a Location Services request (main thread, called once).
typedef void (^CYLocationRequestCompletion)(BOOL ok, NSString *message);

// The switcher card is gone (swiped away, or removed by Cyanide): the next
// launch must not take the remembered scene session for a surviving card.
// iOS reconnects a swiped-away card's session ID when Cyanide is relaunched
// within seconds, so the ID alone can't tell.
// sessionID: only forget that session (nil = whichever is remembered).
void scene_forget_switcher_card(NSString *sessionID, const char *why);

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (strong, nonatomic) UIWindow * window;

// Runs a cyanide://location-services URL for the Control Center toggle.
+ (void)cy_runLocationURL:(NSURL *)url completion:(CYLocationRequestCompletion)completion;

@end

