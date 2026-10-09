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
// Kept while the Repo sources switch hides it, so turning it back on restores
// the same tab.
@property (nonatomic, strong) UINavigationController *sourcesNav;
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
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(repoSourcesEnabledDidChange:)
                                                 name:RepoSourcesEnabledDidChangeNotification
                                               object:nil];

    [self updateSourcesBadge];
    [self refreshSourcesIfNeeded];
    self.sourcesRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:kSourcesRefreshInterval
                                                               target:self
                                                             selector:@selector(refreshSourcesIfNeeded)
                                                             userInfo:nil
                                                              repeats:YES];
}

// Wrap a root view controller in a nav controller the SAME way for every tab, so
// they behave identically (the storyboard vs code-created nav controllers gave
// large titles different leading insets otherwise). CYNavigationBar lines the
// title and search bar up with the app's cards.
- (UINavigationController *)cy_tabNavWithRoot:(UIViewController *)root
                                        title:(NSString *)title
                                       symbol:(NSString *)symbol
{
    UINavigationController *nav =
        [[UINavigationController alloc] initWithNavigationBarClass:CYNavigationBar.class toolbarClass:nil];
    if (root) [nav setViewControllers:@[root]];
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:title
                                                   image:[UIImage systemImageNamed:symbol]
                                                     tag:0];
    return nav;
}

- (void)installPackagesAndSourcesTabsIfNeeded
{
    NSArray<UIViewController *> *existing = self.viewControllers;
    if (existing.count == 0) return;
    // Rebuild once: presence of the Home tab means it already ran.
    for (UIViewController *vc in existing) {
        if ([vc.tabBarItem.title isEqualToString:@"Home"]) return;
    }

    // Reuse the storyboard-instantiated root VCs (they carry their configured
    // table styles etc.), matched by class or tab title.
    UIViewController *pkgRoot = nil, *setRoot = nil, *logRoot = nil;
    for (UIViewController *vc in existing) {
        if (![vc isKindOfClass:UINavigationController.class]) continue;
        UIViewController *root = [(UINavigationController *)vc viewControllers].firstObject;
        if (!root) continue;
        NSString *cls = NSStringFromClass(root.class);
        NSString *t = vc.tabBarItem.title;
        if ([cls isEqualToString:@"PackagesViewController"] || [t isEqualToString:@"Packages"]) pkgRoot = root;
        else if ([cls isEqualToString:@"SettingsViewController"] || [t isEqualToString:@"Settings"]) setRoot = root;
        else if ([cls isEqualToString:@"LogViewController"] || [t isEqualToString:@"Log"]) logRoot = root;
    }

    // Detach the reused roots from their old (storyboard) nav controllers before
    // re-wrapping — a VC can only belong to one nav controller.
    for (UIViewController *vc in existing) {
        if ([vc isKindOfClass:UINavigationController.class]) {
            [(UINavigationController *)vc setViewControllers:@[]];
        }
    }

    if (pkgRoot) { pkgRoot.title = @"Packages"; pkgRoot.navigationItem.title = @"Packages"; }

    HomeViewController *home = [[HomeViewController alloc] init];
    SourcesViewController *sources = [[SourcesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    self.sourcesNav = [self cy_tabNavWithRoot:sources title:@"Sources" symbol:@"tray.and.arrow.down.fill"];

    NSMutableArray<UIViewController *> *tabs = [NSMutableArray array];
    [tabs addObject:[self cy_tabNavWithRoot:home    title:@"Home"     symbol:@"house.fill"]];
    if (pkgRoot) [tabs addObject:[self cy_tabNavWithRoot:pkgRoot title:@"Packages" symbol:@"shippingbox.fill"]];
    if (repotweaks_sources_enabled()) [tabs addObject:self.sourcesNav];
    if (logRoot) [tabs addObject:[self cy_tabNavWithRoot:logRoot title:@"Log"      symbol:@"terminal"]];
    if (setRoot) [tabs addObject:[self cy_tabNavWithRoot:setRoot title:@"Settings" symbol:@"gear"]];

    [self setViewControllers:tabs animated:NO];
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

- (void)setPopupBarSuppressed:(BOOL)suppressed
{
    if (self.popupBar.suppressed == suppressed) return;
    self.popupBar.suppressed = suppressed;
    [self refreshChildInsetsAnimated:YES];
}

- (void)queueDidChange:(NSNotification *)note
{
    [self refreshChildInsetsAnimated:YES];
    if ([note.name isEqualToString:kSettingsActionsDidCompleteNotification]) {
        [self updateSourcesBadge];
    }
}

- (void)refreshChildInsetsAnimated:(BOOL)animated
{
    BOOL visible = !self.popupBar.suppressed && [PackageQueue sharedQueue].pendingCount > 0;
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

- (void)repoSourcesEnabledDidChange:(NSNotification *)note
{
    BOOL enabled = repotweaks_sources_enabled();
    if (!enabled) {
        // Repo packages are no longer listed, so nothing queued for them
        // should be applied either.
        PackageQueue *queue = [PackageQueue sharedQueue];
        NSArray<Package *> *queued = [queue.queuedInstalls arrayByAddingObjectsFromArray:queue.queuedUninstalls];
        for (Package *pkg in queued) {
            if (pkg.kind == PackageInstallKindRepoTweak) [queue removePackage:pkg];
        }
        [self.refreshBanner removeFromSuperview];
        self.refreshBanner = nil;
    }
    [self updateSourcesTabVisibility];
    [self updateSourcesBadge];
    if (enabled) [self refreshSourcesIfNeeded];
}

- (void)updateSourcesTabVisibility
{
    if (!self.sourcesNav) return;
    BOOL enabled = repotweaks_sources_enabled();
    NSMutableArray<UIViewController *> *tabs = [self.viewControllers mutableCopy];
    BOOL present = [tabs containsObject:self.sourcesNav];
    if (enabled == present) return;

    UIViewController *selected = self.selectedViewController;
    if (enabled) {
        // Back to its usual place, right after Packages.
        NSUInteger insertAt = 1;
        for (NSUInteger i = 0; i < tabs.count; i++) {
            if ([tabs[i].tabBarItem.title isEqualToString:@"Packages"]) { insertAt = i + 1; break; }
        }
        [tabs insertObject:self.sourcesNav atIndex:MIN(insertAt, tabs.count)];
    } else {
        [tabs removeObject:self.sourcesNav];
        if (selected == self.sourcesNav) selected = tabs.firstObject;
    }
    [self setViewControllers:tabs animated:NO];
    if (selected) self.selectedViewController = selected;
}

- (void)refreshSourcesIfNeeded
{
    if (!repotweaks_sources_enabled()) return;
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
