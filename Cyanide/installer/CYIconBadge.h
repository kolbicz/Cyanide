//
//  CYIconBadge.h
//  Cyanide
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

UIImage *CYIconBadgeImage(NSString *sfSymbol, UIColor *color, CGFloat size);
// Badge bitmaps are drawn for table cells, so the same few images were rendered
// again for every cell on every reload. This returns the cached image for
// (style, symbol, colour as resolved for the current appearance, size, scale)
// and calls `render` only on a miss. Main thread, like the drawing itself.
UIImage *CYIconBadgeCached(NSString *style, NSString *_Nullable sfSymbol, UIColor *color, CGFloat size,
                           UIImage * (NS_NOESCAPE ^render)(void));
UIColor *CYSpectrumColor(NSUInteger index);
UIView *CYSectionHeaderView(NSString *title);

// Navigation bar that widens the content inset on root (tab) screens so the
// large title and the integrated search bar line up with the app's inset-grouped
// cards, consistently across every tab. It uses ONLY the public
// directionalLayoutMargins API (not the earlier private-view title hack), and
// leaves pushed screens — the ones with a back button — at the standard inset.
@interface CYNavigationBar : UINavigationBar
@end

NS_ASSUME_NONNULL_END
