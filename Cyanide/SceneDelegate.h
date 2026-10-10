//
//  SceneDelegate.h
//  Cyanide
//
//  Created by seo on 3/24/26.
//

#import <UIKit/UIKit.h>

// Outcome of a Location Services request (main thread, called once).
typedef void (^CYLocationRequestCompletion)(BOOL ok, NSString *message);

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (strong, nonatomic) UIWindow * window;

// Runs a cyanide://location-services URL for the Control Center toggle.
+ (void)cy_runLocationURL:(NSURL *)url completion:(CYLocationRequestCompletion)completion;

@end

