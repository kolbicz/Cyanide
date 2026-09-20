//
//  MainTabBarController.m
//  Cyanide
//

#import "MainTabBarController.h"
#import "QueuePopupBar.h"
#import "QueueReviewViewController.h"
#import "PackageQueue.h"
#import "HomeViewController.h"
#import "SourcesViewController.h"
#import "CYIconBadge.h"
#import "../SettingsViewController.h"
#import "../tweaks/RepoTweaks.h"

static const CGFloat kPopupHeight  = 56.0;
static const CGFloat kPopupGap     = 8.0;
static const CGFloat kPopupPadding = 2.0;
static const NSTimeInterval kSourcesRefreshInterval = 3 * 60 * 60; // 3 hours
static NSString * const kSourcesLastRefreshKey = @"RepoTweaksLastRefreshTimestamp";

@interface MainTabBarController ()
@property (nonatomic, strong) QueuePopupBar *popupBar;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *popupBarConstraints;
@property (nonatomic, strong) NSTimer *sourcesRefreshTimer;
@property (nonatomic, strong) UIView *refreshBanner;
@end

@implementation MainTabBarController

- (void)viewDidLoad
{
    [super viewDidLoad];

    [self installPackagesAndSourcesTabsIfNeeded];

    self.popupBar = [[QueuePopupBar alloc] initWithFrame:CGRectZero];
    self.popupBar.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    self.popupBar.onTap = ^{ [weakSelf showQueueReview]; };
    [self.view addSubview:self.popupBar];

    [self installPopupBarConstraintsIfReady];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(queueDidChange:)
                                                 name:PackageQueueDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(queueDidChange:)
                                                 name:kSettingsActionsDidCompleteNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sourcesDidRefresh:)
                                                 name:RepoTweaksDidRefreshNotification
                                               object:nil];

    [self updateSourcesBadge];
    [self refreshSourcesIfNeeded];
    self.sourcesRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:kSourcesRefreshInterval
                                                               target:self
                                                             selector:@selector(refreshSourcesIfNeeded)
                                                             userInfo:nil
                                                              repeats:YES];
}

- (void)installPackagesAndSourcesTabsIfNeeded
{
    NSMutableArray<UIViewController *> *controllers = [self.viewControllers mutableCopy];
    if (controllers.count == 0) return;

    UIViewController *packages = controllers.firstObject;
    packages.tabBarItem.title = @"Packages";
    packages.tabBarItem.image = [UIImage systemImageNamed:@"shippingbox.fill"];
    if ([packages isKindOfClass:UINavigationController.class]) {
        UINavigationController *nav = (UINavigationController *)packages;
        nav.tabBarItem.title = @"Packages";
        nav.topViewController.title = @"Packages";
        nav.topViewController.navigationItem.title = @"Packages";
    }

    // Inject Home tab at position 0 if not already present.
    BOOL hasHome = NO;
    for (UIViewController *vc in controllers) {
        if ([vc.tabBarItem.title isEqualToString:@"Home"]) { hasHome = YES; break; }
    }
    if (!hasHome) {
        HomeViewController *home = [[HomeViewController alloc] init];
        UINavigationController *homeNav = [[UINavigationController alloc] init];
        [homeNav setViewControllers:@[home]];
        homeNav.navigationBar.barStyle = UIBarStyleBlack;
        homeNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Home"
                                                           image:[UIImage systemImageNamed:@"house.fill"]
                                                             tag:0];
        [controllers insertObject:homeNav atIndex:0];
    }

    // Inject Sources tab right after Packages if not already present.
    BOOL hasSources = NO;
    for (UIViewController *vc in controllers) {
        if ([vc.tabBarItem.title isEqualToString:@"Sources"]) { hasSources = YES; break; }
    }
    if (!hasSources) {
        SourcesViewController *sources = [[SourcesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        UINavigationController *nav = [[UINavigationController alloc] init];
        [nav setViewControllers:@[sources]];
        nav.navigationBar.barStyle = UIBarStyleBlack;
        nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Sources"
                                                       image:[UIImage systemImageNamed:@"tray.and.arrow.down.fill"]
                                                         tag:0];
        // Find Packages and insert Sources right after it.
        NSUInteger pkgIdx = 0;
        for (NSUInteger i = 0; i < controllers.count; i++) {
            if ([controllers[i].tabBarItem.title isEqualToString:@"Packages"]) { pkgIdx = i; break; }
        }
        NSUInteger insertIndex = MIN(pkgIdx + 1, controllers.count);
        [controllers insertObject:nav atIndex:insertIndex];
    }

    [self setViewControllers:controllers animated:NO];
    self.selectedIndex = 0;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self installPopupBarConstraintsIfReady];
}

- (void)dealloc
{
    [self.sourcesRefreshTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)view:(UIView *)view sharesHierarchyWithView:(UIView *)otherView
{
    if (!view || !otherView) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if ([otherView isDescendantOfView:ancestor]) return YES;
    }
    return NO;
}

- (void)installPopupBarConstraintsIfReady
{
    if (self.popupBarConstraints.count > 0) return;

    NSLayoutYAxisAnchor *bottomAnchor = self.view.safeAreaLayoutGuide.bottomAnchor;
    CGFloat bottomConstant = -kPopupGap;
    if ([self view:self.popupBar sharesHierarchyWithView:self.tabBar]) {
        bottomAnchor = self.tabBar.topAnchor;
    }

    self.popupBarConstraints = @[
        [self.popupBar.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor  constant:12.0],
        [self.popupBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12.0],
        [self.popupBar.bottomAnchor   constraintEqualToAnchor:bottomAnchor constant:bottomConstant],
        [self.popupBar.heightAnchor   constraintEqualToConstant:kPopupHeight],
    ];
    [NSLayoutConstraint activateConstraints:self.popupBarConstraints];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.popupBar refreshFromQueueAnimated:NO];
    [self refreshChildInsetsAnimated:NO];
    [self updateSourcesBadge];
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated
{
    [super setViewControllers:viewControllers animated:animated];
    [self refreshChildInsetsAnimated:NO];
}

#pragma mark - Popup inset propagation

- (void)queueDidChange:(NSNotification *)note
{
    [self refreshChildInsetsAnimated:YES];
    if ([note.name isEqualToString:kSettingsActionsDidCompleteNotification]) {
        [self updateSourcesBadge];
    }
}

- (void)refreshChildInsetsAnimated:(BOOL)animated
{
    BOOL visible = [PackageQueue sharedQueue].pendingCount > 0;
    UIEdgeInsets insets = UIEdgeInsetsZero;
    if (visible) {
        insets.bottom = kPopupHeight + kPopupGap + kPopupPadding;
    }
    void (^apply)(void) = ^{
        for (UIViewController *vc in self.viewControllers) {
            vc.additionalSafeAreaInsets = insets;
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.25 animations:apply];
    } else {
        apply();
    }
}

- (void)sourcesDidRefresh:(NSNotification *)note
{
    [self updateSourcesBadge];
    [self showRefreshSuccessThenHide];
}

- (void)refreshSourcesIfNeeded
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSTimeInterval last = [d doubleForKey:kSourcesLastRefreshKey];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (last > 0 && (now - last) < kSourcesRefreshInterval) return;

    [self showRefreshBanner];
    repotweaks_refresh_all_sources(^{
        NSUserDefaults *dd = [NSUserDefaults standardUserDefaults];
        [dd setDouble:[[NSDate date] timeIntervalSince1970] forKey:kSourcesLastRefreshKey];
        [dd synchronize];
    });
}

- (void)showRefreshBanner
{
    if (self.refreshBanner) return;

    UIView *banner = [[UIView alloc] init];
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.9];
    banner.layer.cornerRadius = 10.0;
    banner.layer.cornerCurve = kCACornerCurveContinuous;
    banner.alpha = 0.0;
    banner.tag = 0;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.color = UIColor.whiteColor;
    spinner.tag = 100;
    [spinner startAnimating];
    [banner addSubview:spinner];

    UIImageView *checkmark = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"checkmark.circle.fill"
               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold]]];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.tintColor = UIColor.whiteColor;
    checkmark.tag = 101;
    checkmark.alpha = 0.0;
    checkmark.hidden = YES;
    [banner addSubview:checkmark];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"Refreshing sources…";
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor;
    label.tag = 102;
    [banner addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [spinner.leadingAnchor    constraintEqualToAnchor:banner.leadingAnchor constant:12.0],
        [spinner.centerYAnchor    constraintEqualToAnchor:banner.centerYAnchor],
        [checkmark.leadingAnchor  constraintEqualToAnchor:banner.leadingAnchor constant:12.0],
        [checkmark.centerYAnchor  constraintEqualToAnchor:banner.centerYAnchor],
        [label.leadingAnchor      constraintEqualToAnchor:spinner.trailingAnchor constant:8.0],
        [label.centerYAnchor      constraintEqualToAnchor:banner.centerYAnchor],
        [label.trailingAnchor     constraintLessThanOrEqualToAnchor:banner.trailingAnchor constant:-12.0],
    ]];

    [self.view addSubview:banner];

    [NSLayoutConstraint activateConstraints:@[
        [banner.topAnchor      constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4.0],
        [banner.centerXAnchor  constraintEqualToAnchor:self.view.centerXAnchor],
        [banner.heightAnchor   constraintEqualToConstant:34.0],
    ]];

    self.refreshBanner = banner;
    [self.view layoutIfNeeded];
    [UIView animateWithDuration:0.3 animations:^{ banner.alpha = 1.0; }];
}

- (void)showRefreshSuccessThenHide
{
    UIView *banner = self.refreshBanner;
    if (!banner) return;

    UIActivityIndicatorView *spinner = [banner viewWithTag:100];
    UIImageView *checkmark = (UIImageView *)[banner viewWithTag:101];
    UILabel *label = (UILabel *)[banner viewWithTag:102];

    [UIView animateWithDuration:0.25 animations:^{
        spinner.alpha = 0.0;
        banner.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.9];
    } completion:^(BOOL finished) {
        [spinner stopAnimating];
        checkmark.hidden = NO;
        label.text = @"Sources up to date";
        [UIView animateWithDuration:0.2 animations:^{
            checkmark.alpha = 1.0;
        }];
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.refreshBanner != banner) return;
        self.refreshBanner = nil;
        [UIView animateWithDuration:0.3 animations:^{
            banner.alpha = 0.0;
        } completion:^(BOOL finished) {
            [banner removeFromSuperview];
        }];
    });
}

- (void)hideRefreshBanner
{
    UIView *banner = self.refreshBanner;
    if (!banner) return;
    self.refreshBanner = nil;
    [UIView animateWithDuration:0.3 animations:^{
        banner.alpha = 0.0;
    } completion:^(BOOL finished) {
        [banner removeFromSuperview];
    }];
}

- (void)updateSourcesBadge
{
    // These updates belong to tweaks imported from source repos, which are
    // browsed and managed in the Sources tab; the Packages list no longer shows
    // them, so the count rides on Sources instead.
    NSUInteger count = repotweaks_available_update_count();
    NSString *badge = count > 0 ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : nil;
    for (UIViewController *vc in self.viewControllers) {
        if ([vc.tabBarItem.title isEqualToString:@"Sources"]) {
            vc.tabBarItem.badgeValue = badge;
            break;
        }
    }
}

- (void)showQueueReview
{
    UIViewController *selected = self.selectedViewController;
    UINavigationController *nav = [selected isKindOfClass:UINavigationController.class]
        ? (UINavigationController *)selected
        : selected.navigationController;
    if (!nav) return;

    // Don't re-push if it's already on top.
    if ([nav.topViewController isKindOfClass:QueueReviewViewController.class]) return;

    QueueReviewViewController *review = [[QueueReviewViewController alloc] init];
    [nav pushViewController:review animated:YES];
}

@end
