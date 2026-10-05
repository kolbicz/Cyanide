//
//  MainTabBarController.h
//  Cyanide
//
//  Hosts the QueuePopupBar above the system tab bar and routes the tap to
//  push the queue-review screen onto the active tab's nav stack.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MainTabBarController : UITabBarController
- (void)showRefreshBanner;
// Suppresses/restores the queue popup bar (used by pushed full-screen views
// such as the Process Viewer so the banner doesn't float above them).
- (void)setPopupBarSuppressed:(BOOL)suppressed;
@end

NS_ASSUME_NONNULL_END
