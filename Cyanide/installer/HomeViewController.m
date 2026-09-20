//
//  HomeViewController.m
//  Cyanide
//

#import "HomeViewController.h"
#import "SourcesViewController.h"
#import "../SettingsViewController.h"
#import "../tweaks/RepoTweaks.h"

static NSString * const kGitHubIssuesURL = @"https://github.com/kolbicz/cyanide/issues";
static NSString * const kGitHubRepoURL   = @"https://github.com/kolbicz/cyanide";

static const CGFloat kMargin = 20.0;

@interface HomeViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, weak) UIView *heroView;
@property (nonatomic, weak) CAGradientLayer *heroGrad;
@end

@implementation HomeViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Home";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.title = @"Cyanide";

    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    self.stack = [[UIStackView alloc] init];
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 24.0;
    self.stack.alignment = UIStackViewAlignmentFill;
    [self.scrollView addSubview:self.stack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor      constraintEqualToAnchor:self.view.topAnchor],
        [self.scrollView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
        [self.stack.topAnchor      constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:4.0],
        [self.stack.leadingAnchor  constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:kMargin],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-kMargin],
        [self.stack.bottomAnchor   constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-32.0],
        [self.stack.widthAnchor    constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-kMargin * 2],
    ]];

    [self.stack addArrangedSubview:[self buildHero]];
    [self.stack addArrangedSubview:[self buildQuickActions]];
    [self.stack addArrangedSubview:[self buildWhatsNew]];
    [self.stack addArrangedSubview:[self buildGetStarted]];
    [self.stack addArrangedSubview:[self buildCommunity]];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // Force the pending layout so the hero card already has its final bounds
    // when this appearance's first frame is composited. The gradient layer is
    // not resized here: layoutIfNeeded runs viewDidLayoutSubviews:, which owns
    // that (and every later pass).
    [self.view layoutIfNeeded];
}

#pragma mark - Hero

- (UIView *)buildHero
{
    UIView *hero = [[UIView alloc] init];
    hero.layer.cornerRadius = 20.0;
    hero.layer.cornerCurve = kCACornerCurveContinuous;
    hero.clipsToBounds = YES;

    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.colors = @[
        (id)[UIColor colorWithRed:0.0 green:0.72 blue:0.84 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.0 green:0.50 blue:0.90 alpha:1.0].CGColor,
    ];
    grad.startPoint = CGPointMake(0.0, 0.0);
    grad.endPoint = CGPointMake(1.0, 1.0);
    [hero.layer insertSublayer:grad atIndex:0];

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *appIcon = [UIImage imageNamed:@"AppIcon60x60"];
    if (!appIcon) {
        NSString *f = [[[NSBundle mainBundle] infoDictionary][@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"] lastObject];
        appIcon = f ? [UIImage imageNamed:f] : nil;
    }
    icon.image = appIcon;
    icon.layer.cornerRadius = 14.0;
    icon.layer.cornerCurve = kCACornerCurveContinuous;
    icon.clipsToBounds = YES;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.layer.borderWidth = 1.5;
    icon.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    [hero addSubview:icon];

    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";

    UILabel *tagline = [[UILabel alloc] init];
    tagline.translatesAutoresizingMaskIntoConstraints = NO;
    tagline.text = @"SpringBoard tweaks for stock iOS";
    tagline.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
    tagline.textColor = UIColor.whiteColor;
    tagline.textAlignment = NSTextAlignmentCenter;
    [hero addSubview:tagline];

    UILabel *sub = [[UILabel alloc] init];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.text = [NSString stringWithFormat:@"No jailbreak required · v%@", ver];
    sub.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    sub.textAlignment = NSTextAlignmentCenter;
    [hero addSubview:sub];

    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor  constraintEqualToAnchor:hero.centerXAnchor],
        [icon.topAnchor      constraintEqualToAnchor:hero.topAnchor constant:20.0],
        [icon.widthAnchor    constraintEqualToConstant:48.0],
        [icon.heightAnchor   constraintEqualToConstant:48.0],

        [tagline.centerXAnchor  constraintEqualToAnchor:hero.centerXAnchor],
        [tagline.topAnchor      constraintEqualToAnchor:icon.bottomAnchor constant:10.0],

        [sub.centerXAnchor  constraintEqualToAnchor:hero.centerXAnchor],
        [sub.topAnchor      constraintEqualToAnchor:tagline.bottomAnchor constant:4.0],
        [sub.bottomAnchor   constraintEqualToAnchor:hero.bottomAnchor constant:-18.0],
    ]];

    self.heroGrad = grad;
    self.heroView = hero;
    return hero;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (self.heroGrad && self.heroView) {
        self.heroGrad.frame = self.heroView.bounds;
    }
}

#pragma mark - Quick Actions

- (UIView *)buildQuickActions
{
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 12.0;
    row.distribution = UIStackViewDistributionFillEqually;

    [row addArrangedSubview:[self actionCard:@"Packages"
                                       icon:@"shippingbox.fill"
                                      color:UIColor.systemBlueColor
                                        sel:@selector(openPackagesTab)]];
    [row addArrangedSubview:[self actionCard:@"Sources"
                                       icon:@"tray.and.arrow.down.fill"
                                      color:UIColor.systemGreenColor
                                        sel:@selector(openSourcesTab)]];

    return row;
}

- (UIView *)actionCard:(NSString *)title icon:(NSString *)iconName color:(UIColor *)color sel:(SEL)sel
{
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 16.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UIView *iconCircle = [[UIView alloc] init];
    iconCircle.translatesAutoresizingMaskIntoConstraints = NO;
    iconCircle.backgroundColor = [color colorWithAlphaComponent:0.12];
    iconCircle.layer.cornerRadius = 20.0;
    [card addSubview:iconCircle];

    UIImageView *iv = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:iconName
               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightSemibold]]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.tintColor = color;
    iv.contentMode = UIViewContentModeCenter;
    [iconCircle addSubview:iv];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    lbl.textColor = UIColor.labelColor;
    [card addSubview:lbl];

    UIImageView *chev = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"chevron.right"
               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11.0 weight:UIImageSymbolWeightBold]]];
    chev.translatesAutoresizingMaskIntoConstraints = NO;
    chev.tintColor = UIColor.tertiaryLabelColor;
    [card addSubview:chev];

    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintEqualToConstant:64.0],
        [iconCircle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [iconCircle.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconCircle.widthAnchor constraintEqualToConstant:40.0],
        [iconCircle.heightAnchor constraintEqualToConstant:40.0],
        [iv.centerXAnchor constraintEqualToAnchor:iconCircle.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:iconCircle.centerYAnchor],
        [lbl.leadingAnchor constraintEqualToAnchor:iconCircle.trailingAnchor constant:12.0],
        [lbl.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [chev.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [chev.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
    ]];

    UIButton *tap = [UIButton buttonWithType:UIButtonTypeCustom];
    tap.translatesAutoresizingMaskIntoConstraints = NO;
    [tap addAction:[UIAction actionWithHandler:^(UIAction *_) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:sel];
        #pragma clang diagnostic pop
    }] forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:tap];
    [NSLayoutConstraint activateConstraints:@[
        [tap.topAnchor constraintEqualToAnchor:card.topAnchor],
        [tap.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [tap.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [tap.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    return card;
}

#pragma mark - What's New

- (UIView *)buildWhatsNew
{
    UIView *card = [self card];
    UIStackView *s = [self vstackInCard:card spacing:14.0];

    UILabel *header = [self sectionHeader:@"What's New"];
    [s addArrangedSubview:header];

    [s addArrangedSubview:[self compactRow:@"JavaScript tweak support by @MinePlayer16"
                                     icon:@"bolt.fill" color:UIColor.systemOrangeColor]];
    [s addArrangedSubview:[self compactRow:@"Source repos with browsable tweak catalogs"
                                     icon:@"tray.and.arrow.down.fill" color:UIColor.systemGreenColor]];
    [s addArrangedSubview:[self compactRow:@"SnowBoard Lite and SpringBoard stability fixes"
                                     icon:@"wrench.and.screwdriver.fill" color:UIColor.systemBlueColor]];

    return card;
}

#pragma mark - Get Started

- (UIView *)buildGetStarted
{
    UIView *card = [self card];
    UIStackView *s = [self vstackInCard:card spacing:12.0];

    [s addArrangedSubview:[self sectionHeader:@"Get Started"]];

    [s addArrangedSubview:[self bigActionButton:@"Open QuickLoader"
                                          sub:@"Run a local .js tweak file"
                                         icon:@"bolt.fill"
                                        color:UIColor.systemOrangeColor
                                          sel:@selector(openQuickLoader)]];
    [s addArrangedSubview:[self bigActionButton:@"Add a Source"
                                          sub:@"Browse and install JS tweaks from repos"
                                         icon:@"plus.circle.fill"
                                        color:UIColor.systemGreenColor
                                          sel:@selector(openSourcesTab)]];
    return card;
}

- (UIView *)bigActionButton:(NSString *)title sub:(NSString *)sub icon:(NSString *)iconName color:(UIColor *)color sel:(SEL)sel
{
    UIView *btn = [[UIView alloc] init];
    btn.backgroundColor = [color colorWithAlphaComponent:0.08];
    btn.layer.cornerRadius = 14.0;
    btn.layer.cornerCurve = kCACornerCurveContinuous;

    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.backgroundColor = [color colorWithAlphaComponent:0.18];
    dot.layer.cornerRadius = 18.0;
    [btn addSubview:dot];

    UIImageView *iv = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:iconName
               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold]]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.tintColor = color;
    iv.contentMode = UIViewContentModeCenter;
    [dot addSubview:iv];

    UILabel *t = [[UILabel alloc] init];
    t.translatesAutoresizingMaskIntoConstraints = NO;
    t.text = title;
    t.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    t.textColor = UIColor.labelColor;
    [btn addSubview:t];

    UILabel *d = [[UILabel alloc] init];
    d.translatesAutoresizingMaskIntoConstraints = NO;
    d.text = sub;
    d.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    d.textColor = UIColor.secondaryLabelColor;
    [btn addSubview:d];

    UIImageView *chev = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"chevron.right"
               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12.0 weight:UIImageSymbolWeightBold]]];
    chev.translatesAutoresizingMaskIntoConstraints = NO;
    chev.tintColor = [color colorWithAlphaComponent:0.6];
    [btn addSubview:chev];

    [NSLayoutConstraint activateConstraints:@[
        [btn.heightAnchor   constraintEqualToConstant:64.0],
        [dot.leadingAnchor  constraintEqualToAnchor:btn.leadingAnchor constant:14.0],
        [dot.centerYAnchor  constraintEqualToAnchor:btn.centerYAnchor],
        [dot.widthAnchor    constraintEqualToConstant:36.0],
        [dot.heightAnchor   constraintEqualToConstant:36.0],
        [iv.centerXAnchor   constraintEqualToAnchor:dot.centerXAnchor],
        [iv.centerYAnchor   constraintEqualToAnchor:dot.centerYAnchor],
        [t.leadingAnchor    constraintEqualToAnchor:dot.trailingAnchor constant:12.0],
        [t.bottomAnchor     constraintEqualToAnchor:btn.centerYAnchor constant:0.0],
        [d.leadingAnchor    constraintEqualToAnchor:t.leadingAnchor],
        [d.topAnchor        constraintEqualToAnchor:t.bottomAnchor constant:2.0],
        [chev.trailingAnchor constraintEqualToAnchor:btn.trailingAnchor constant:-14.0],
        [chev.centerYAnchor  constraintEqualToAnchor:btn.centerYAnchor],
    ]];

    UIButton *tap = [UIButton buttonWithType:UIButtonTypeCustom];
    tap.translatesAutoresizingMaskIntoConstraints = NO;
    [tap addAction:[UIAction actionWithHandler:^(UIAction *_) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:sel];
        #pragma clang diagnostic pop
    }] forControlEvents:UIControlEventTouchUpInside];
    [btn addSubview:tap];
    [NSLayoutConstraint activateConstraints:@[
        [tap.topAnchor constraintEqualToAnchor:btn.topAnchor],
        [tap.leadingAnchor constraintEqualToAnchor:btn.leadingAnchor],
        [tap.trailingAnchor constraintEqualToAnchor:btn.trailingAnchor],
        [tap.bottomAnchor constraintEqualToAnchor:btn.bottomAnchor],
    ]];

    return btn;
}

#pragma mark - Community

- (UIView *)buildCommunity
{
    UIView *card = [self card];
    UIStackView *s = [self vstackInCard:card spacing:0.0];

    UILabel *header = [self sectionHeader:@"Community"];
    UIView *headerWrap = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [headerWrap addSubview:header];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:headerWrap.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:headerWrap.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:headerWrap.trailingAnchor],
        [header.bottomAnchor constraintEqualToAnchor:headerWrap.bottomAnchor constant:-4.0],
    ]];
    [s addArrangedSubview:headerWrap];

    [s addArrangedSubview:[self linkCell:@"Report a Bug" icon:@"exclamationmark.bubble.fill"
                                  color:UIColor.systemRedColor url:kGitHubIssuesURL sep:YES]];
    [s addArrangedSubview:[self linkCell:@"GitHub" icon:@"chevron.left.forwardslash.chevron.right"
                                  color:UIColor.systemGrayColor url:kGitHubRepoURL sep:NO]];
    return card;
}

#pragma mark - Card primitives

- (UIView *)card
{
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    v.layer.cornerRadius = 16.0;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    return v;
}

- (UIStackView *)vstackInCard:(UIView *)card spacing:(CGFloat)spacing
{
    UIStackView *s = [[UIStackView alloc] init];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = spacing;
    s.alignment = UIStackViewAlignmentFill;
    [card addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:card.topAnchor constant:16.0],
        [s.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [s.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [s.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16.0],
    ]];
    return s;
}

- (UILabel *)sectionHeader:(NSString *)title
{
    UILabel *h = [[UILabel alloc] init];
    h.text = title;
    h.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    h.textColor = UIColor.labelColor;
    return h;
}

- (UIView *)compactRow:(NSString *)text icon:(NSString *)iconName color:(UIColor *)color
{
    UIView *row = [[UIView alloc] init];

    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.backgroundColor = [color colorWithAlphaComponent:0.14];
    dot.layer.cornerRadius = 16.0;
    [row addSubview:dot];

    UIImageView *iv = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:iconName
               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold]]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.tintColor = color;
    iv.contentMode = UIViewContentModeCenter;
    [dot addSubview:iv];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = text;
    lbl.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    lbl.textColor = UIColor.labelColor;
    lbl.numberOfLines = 0;
    [row addSubview:lbl];

    [NSLayoutConstraint activateConstraints:@[
        [dot.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [dot.topAnchor     constraintEqualToAnchor:row.topAnchor],
        [dot.widthAnchor   constraintEqualToConstant:32.0],
        [dot.heightAnchor  constraintEqualToConstant:32.0],
        [iv.centerXAnchor  constraintEqualToAnchor:dot.centerXAnchor],
        [iv.centerYAnchor  constraintEqualToAnchor:dot.centerYAnchor],
        [lbl.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:12.0],
        [lbl.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [lbl.centerYAnchor constraintEqualToAnchor:dot.centerYAnchor],
        [row.bottomAnchor  constraintGreaterThanOrEqualToAnchor:dot.bottomAnchor],
        [row.bottomAnchor  constraintGreaterThanOrEqualToAnchor:lbl.bottomAnchor],
    ]];
    return row;
}

- (UIView *)linkCell:(NSString *)title icon:(NSString *)iconName color:(UIColor *)color url:(NSString *)url sep:(BOOL)sep
{
    UIView *cell = [[UIView alloc] init];

    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.backgroundColor = [color colorWithAlphaComponent:0.14];
    dot.layer.cornerRadius = 14.0;
    [cell addSubview:dot];

    UIImageView *iv = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:iconName
               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold]]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.tintColor = color;
    iv.contentMode = UIViewContentModeCenter;
    [dot addSubview:iv];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    lbl.textColor = UIColor.labelColor;
    [cell addSubview:lbl];

    UIImageView *chev = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"chevron.right"
               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11.0 weight:UIImageSymbolWeightBold]]];
    chev.translatesAutoresizingMaskIntoConstraints = NO;
    chev.tintColor = UIColor.tertiaryLabelColor;
    [cell addSubview:chev];

    [NSLayoutConstraint activateConstraints:@[
        [cell.heightAnchor  constraintEqualToConstant:48.0],
        [dot.leadingAnchor  constraintEqualToAnchor:cell.leadingAnchor],
        [dot.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
        [dot.widthAnchor    constraintEqualToConstant:28.0],
        [dot.heightAnchor   constraintEqualToConstant:28.0],
        [iv.centerXAnchor   constraintEqualToAnchor:dot.centerXAnchor],
        [iv.centerYAnchor   constraintEqualToAnchor:dot.centerYAnchor],
        [lbl.leadingAnchor  constraintEqualToAnchor:dot.trailingAnchor constant:12.0],
        [lbl.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
        [chev.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
        [chev.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
    ]];

    if (sep) {
        UIView *line = [[UIView alloc] init];
        line.translatesAutoresizingMaskIntoConstraints = NO;
        line.backgroundColor = UIColor.separatorColor;
        [cell addSubview:line];
        [NSLayoutConstraint activateConstraints:@[
            [line.leadingAnchor constraintEqualToAnchor:lbl.leadingAnchor],
            [line.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
            [line.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
            [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
        ]];
    }

    UIButton *tap = [UIButton buttonWithType:UIButtonTypeCustom];
    tap.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) ws = self;
    [tap addAction:[UIAction actionWithHandler:^(UIAction *_) { [ws openURLString:url]; }] forControlEvents:UIControlEventTouchUpInside];
    [cell addSubview:tap];
    [NSLayoutConstraint activateConstraints:@[
        [tap.topAnchor constraintEqualToAnchor:cell.topAnchor],
        [tap.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
        [tap.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
        [tap.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
    ]];

    return cell;
}

#pragma mark - Navigation

- (void)openURLString:(NSString *)url
{
    NSURL *u = [NSURL URLWithString:url];
    if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
}

- (void)openPackagesTab
{
    UITabBarController *tab = self.tabBarController;
    if (!tab) return;
    for (NSUInteger i = 0; i < tab.viewControllers.count; i++) {
        if ([tab.viewControllers[i].tabBarItem.title isEqualToString:@"Packages"]) {
            tab.selectedIndex = i;
            return;
        }
    }
}

- (void)openQuickLoader
{
    UITabBarController *tab = self.tabBarController;
    if (!tab) return;
    for (NSUInteger i = 0; i < tab.viewControllers.count; i++) {
        UIViewController *vc = tab.viewControllers[i];
        if ([vc.tabBarItem.title isEqualToString:@"Settings"]) {
            UINavigationController *nav = [vc isKindOfClass:UINavigationController.class] ? (UINavigationController *)vc : nil;
            if (!nav) return;
            [nav popToRootViewControllerAnimated:NO];
            SettingsViewController *ql = [[SettingsViewController alloc] initWithUnderlyingSection:SectionQuickLoader bundleTitle:@"QuickLoader"];
            ql.quickLoaderStandalone = YES;
            // QuickLoader has no package page to return to. It belongs with the
            // JS-tweak sources flow, so the back button goes to the Sources front
            // page instead of back to Home.
            ql.installerReturnTabTitle = @"Sources";
            ql.installerReturnResetsTargetTab = YES;
            [nav pushViewController:ql animated:NO];
            tab.selectedIndex = i;
            return;
        }
    }
}

- (void)openSourcesTab
{
    UITabBarController *tab = self.tabBarController;
    if (!tab) return;
    for (NSUInteger i = 0; i < tab.viewControllers.count; i++) {
        if ([tab.viewControllers[i].tabBarItem.title isEqualToString:@"Sources"]) {
            tab.selectedIndex = i;
            return;
        }
    }
}

@end
