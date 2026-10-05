//
//  MainTabBarController.h
//  Cyanide
//
//  Hosts the QueuePopupBar above the system tab bar and routes the tap to
//  push the queue-review screen onto the active tab's nav stack.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Round 47: tab-root nav controller that forwards the home-indicator
// auto-hide query to its top view controller. The leaf override
// (ProcessManagerViewController's prefersHomeIndicatorAutoHidden) sits
// inside nav inside tab; without explicit forwarding on BOTH containers
// iOS may never consult the leaf.
@interface CYNavigationController : UINavigationController
@end

@interface MainTabBarController : UITabBarController
- (void)showRefreshBanner;
// Suppresses/restores the queue popup bar (used by pushed full-screen views
// such as the Process Viewer so the banner doesn't float above them).
- (void)setPopupBarSuppressed:(BOOL)suppressed;
@end

NS_ASSUME_NONNULL_END
