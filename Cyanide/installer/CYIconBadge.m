//
//  CYIconBadge.m
//  Cyanide
//

#import "CYIconBadge.h"

UIImage *CYIconBadgeImage(NSString *sfSymbol, UIColor *color, CGFloat size)
{
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
