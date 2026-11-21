//
//  CYIconBadge.m
//  Cyanide
//

#import "CYIconBadge.h"

UIImage *CYIconBadgeCached(NSString *style, NSString *sfSymbol, UIColor *color, CGFloat size,
                           UIImage * (NS_NOESCAPE ^render)(void))
{
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 256;
    });

    // A system colour is dynamic and the bitmap bakes in whatever it resolves
    // to right now, so the key carries the resolved components (light and dark
    // get separate entries) and the screen scale.
    UITraitCollection *traits = UITraitCollection.currentTraitCollection;
    CGColorRef cg = [color resolvedColorWithTraitCollection:traits].CGColor;
    NSMutableString *key = [NSMutableString stringWithFormat:@"%@|%@|%.2f|%.1f|%d",
                            style, sfSymbol ?: @"", size, traits.displayScale,
                            (int)CGColorSpaceGetModel(CGColorGetColorSpace(cg))];
    const CGFloat *components = CGColorGetComponents(cg);
    size_t count = CGColorGetNumberOfComponents(cg);
    for (size_t i = 0; components && i < count; i++) [key appendFormat:@"|%.4f", components[i]];

    UIImage *image = [cache objectForKey:key];
    if (image) return image;
    image = render();
    if (image) [cache setObject:image forKey:key];
    return image;
}

UIImage *CYIconBadgeImage(NSString *sfSymbol, UIColor *color, CGFloat size)
{
    return CYIconBadgeCached(@"round", sfSymbol, color, size, ^UIImage *{
    UIGraphicsImageRendererFormat *fmt = [[UIGraphicsImageRendererFormat alloc] init];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size) format:fmt];

    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[color colorWithAlphaComponent:0.14] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, size, size)] fill];

        UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:size * 0.42 weight:UIImageSymbolWeightSemibold];
        UIImage *sym = [[UIImage systemImageNamed:sfSymbol withConfiguration:symCfg]
            imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (!sym) return;

        CGSize symSize = [sym size];
        CGFloat x = (size - symSize.width) / 2.0;
        CGFloat y = (size - symSize.height) / 2.0;
        [sym drawInRect:CGRectMake(x, y, symSize.width, symSize.height)];
    }];
    });
}

UIColor *CYSpectrumColor(NSUInteger index)
{
    static NSArray<UIColor *> *colors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        colors = @[
            UIColor.systemBlueColor,
            UIColor.systemTealColor,
            UIColor.systemGreenColor,
            UIColor.systemOrangeColor,
            UIColor.systemPinkColor,
            UIColor.systemPurpleColor,
            UIColor.systemIndigoColor,
            UIColor.systemCyanColor,
            UIColor.systemRedColor,
            UIColor.systemMintColor,
        ];
    });
    return colors[index % colors.count];
}

UIView *CYSectionHeaderView(NSString *title)
{
    UIView *container = [[UIView alloc] init];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    lbl.textColor = UIColor.labelColor;
    [container addSubview:lbl];

    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-20.0],
        [lbl.topAnchor      constraintEqualToAnchor:container.topAnchor constant:16.0],
        [lbl.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-6.0],
    ]];

    return container;
}

@implementation CYNavigationBar {
    BOOL _cyCapturedDefaultMargins;
    NSDirectionalEdgeInsets _cyDefaultMargins;
}

// A wider content inset (~20pt) so the large title and the integrated search bar
// line up with the app's inset-grouped cards, the same on every screen. This is
// applied CONSTANTLY — root and pushed screens alike — on purpose: earlier the
// inset was widened only on root screens and reset on push, but a single
// navigation-bar leading margin governs BOTH the large-title inset and the
// bar-button (back button) position, and both are on screen during a push. So
// toggling it mid-transition made the root's large title visibly jump from 20pt
// to the default inset as you drilled into a source. Keeping it constant means
// the margin never changes during a transition, so nothing can jump. The cost is
// that the back button on pushed screens sits at the same 20pt indent (aligned
// with the content), which is consistent rather than jarring. Public
// directionalLayoutMargins API only — no private-view manipulation.
static const CGFloat kCYRootLeading = 20.0;

- (void)layoutSubviews
{
    [super layoutSubviews];
    if (!_cyCapturedDefaultMargins) {
        _cyDefaultMargins = self.directionalLayoutMargins;
        _cyCapturedDefaultMargins = YES;
    }
    NSDirectionalEdgeInsets target = _cyDefaultMargins;
    target.leading  = MAX(target.leading,  kCYRootLeading);
    target.trailing = MAX(target.trailing, kCYRootLeading);
    NSDirectionalEdgeInsets cur = self.directionalLayoutMargins;
    if (fabs(cur.leading - target.leading) > 0.5 || fabs(cur.trailing - target.trailing) > 0.5) {
        self.directionalLayoutMargins = target;
    }
}

@end
