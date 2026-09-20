//
//  SourcesViewController.m
//  Cyanide
//

#import "SourcesViewController.h"
#import "CYIconBadge.h"
#import "JSTweakDocsViewController.h"
#import "CategoryPackagesViewController.h"
#import "Package.h"
#import "PackageCatalog.h"
#import "PackageDetailViewController.h"
#import "PackageQueue.h"
#import "../SettingsViewController.h"
#import "../tweaks/RepoTweaks.h"
#import "../tweaks/QuickLoader.h"
#import "MainTabBarController.h"

@interface Package ()
@property (nonatomic, readwrite, copy) NSString *symbolName;
@property (nonatomic, readwrite, copy) NSString *author;
@end

static NSString * const kSourceCellID      = @"SourceCell";
static NSString * const kSourcePkgCellID   = @"SourcePkgCell";
static NSString * const kCategoryCellID    = @"CategoryCell";

typedef NS_ENUM(NSInteger, SourcesSection) {
    SourcesSectionRepos = 0,
    SourcesSectionQuickLoader,
    SourcesSectionCategories,
    SourcesSectionDeveloper,
    SourcesSectionCount,
};

static NSString *sources_string_or_empty(id value)
{
    return [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
}

static NSArray<NSString *> *sources_urls(void)
{
    id raw = [NSUserDefaults.standardUserDefaults objectForKey:@"RepoTweaksURLs"];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    for (id value in (NSArray *)raw) {
        if ([value isKindOfClass:NSString.class]) [urls addObject:value];
    }
    return urls;
}

static NSDictionary *sources_caches(void)
{
    id raw = [NSUserDefaults.standardUserDefaults objectForKey:@"RepoTweaksCaches"];
    return [raw isKindOfClass:NSDictionary.class] ? (NSDictionary *)raw : @{};
}

static NSDictionary *sources_repo_for_url(NSString *url)
{
    id repo = url.length ? sources_caches()[url] : nil;
    return [repo isKindOfClass:NSDictionary.class] ? (NSDictionary *)repo : @{};
}

static NSArray<NSDictionary *> *sources_tweaks_for_url(NSString *url)
{
    id raw = sources_repo_for_url(url)[@"tweaks"];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (id value in (NSArray *)raw) {
        if ([value isKindOfClass:NSDictionary.class]) [out addObject:value];
    }
    return out;
}

static Package *sources_package_for_tweak(NSString *url, NSDictionary *tweak)
{
    NSDictionary *repo = sources_repo_for_url(url);
    NSString *tweakID = sources_string_or_empty(tweak[@"id"]);
    NSString *identifier = [NSString stringWithFormat:@"repo.%@", repotweaks_storage_key(url, tweakID)];
    Package *pkg = [[Package alloc] initRepoTweakWithIdentifier:identifier
                                                           name:sources_string_or_empty(tweak[@"name"])
                                               shortDescription:sources_string_or_empty(tweak[@"description"])
                                                        version:sources_string_or_empty(tweak[@"version"])
                                                         author:sources_string_or_empty(repo[@"author"])
                                                       repoName:sources_string_or_empty(repo[@"repoName"])
                                                        repoURL:url
                                                    repoTweakID:tweakID
                                                   repoScriptURL:sources_string_or_empty(tweak[@"scriptURL"])];
    NSString *tweakAuthor = sources_string_or_empty(tweak[@"author"]);
    if (tweakAuthor.length > 0) pkg.author = tweakAuthor;
    NSString *symbol = sources_string_or_empty(tweak[@"symbol"]);
    if (symbol.length > 0) pkg.symbolName = symbol;
    NSString *unsupportedReason = repotweaks_unsupported_reason(tweak);
    if (unsupportedReason.length > 0) {
        pkg.installDisabledReason = unsupportedReason;
        pkg.unstableWarning = unsupportedReason;
    } else if ([[NSUserDefaults.standardUserDefaults stringForKey:repotweaks_script_defaults_key(url, tweakID)] length] == 0) {
        pkg.installDisabledReason = @"Refresh this source before installing.";
    }
    return pkg;
}

static BOOL sources_tweak_has_update(NSString *url, NSDictionary *tweak)
{
    if (repotweaks_unsupported_reason(tweak).length > 0) return NO;
    NSString *tweakID = sources_string_or_empty(tweak[@"id"]);
    if (tweakID.length == 0) return NO;
    NSString *installed = [NSUserDefaults.standardUserDefaults stringForKey:repotweaks_installed_version_key(url, tweakID)];
    if (!installed.length) return NO;
    NSString *repoVersion = sources_string_or_empty(tweak[@"version"]);
    if (!repoVersion.length) return NO;
    return repotweaks_compare_versions(repoVersion, installed) == NSOrderedDescending;
}

static NSUInteger sources_update_count_for_url(NSString *url)
{
    NSUInteger count = 0;
    for (NSDictionary *tweak in sources_tweaks_for_url(url)) {
        if (sources_tweak_has_update(url, tweak)) count++;
    }
    return count;
}

static void sources_clear_repo_defaults(NSString *url)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSDictionary *tweak in sources_tweaks_for_url(url)) {
        NSString *tweakID = sources_string_or_empty(tweak[@"id"]);
        if (tweakID.length == 0) continue;
        [d removeObjectForKey:repotweaks_enabled_defaults_key(url, tweakID)];
        [d removeObjectForKey:repotweaks_script_defaults_key(url, tweakID)];
        [d removeObjectForKey:repotweaks_values_defaults_key(url, tweakID)];
        repotweaks_cancel_tweak(url, tweakID);
        quickloader_clear_repo_tweak_if_matches(url, tweakID);
    }
}

#pragma mark - Category icon/color helpers

static NSString *category_icon(NSString *cat)
{
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"Status Bar":          @"chart.bar.fill",
            @"Home Screen":         @"square.grid.3x3.fill",
            @"Theming":             @"paintbrush.fill",
            @"SpringBoard":         @"sparkle",
            @"System":              @"gear",
            @"Beta":                @"exclamationmark.triangle.fill",
            @"Experimental":        @"flask.fill",
            @"In Development":      @"hammer.fill",
            @"JavaScript Tweaks":   @"bolt.fill",
        };
    });
    return map[cat] ?: @"shippingbox.fill";
}

static UIColor *category_color(NSString *cat)
{
    static NSDictionary<NSString *, UIColor *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"Status Bar":          UIColor.systemTealColor,
            @"Home Screen":         UIColor.systemBlueColor,
            @"Theming":             UIColor.systemPinkColor,
            @"SpringBoard":         UIColor.systemCyanColor,
            @"System":              UIColor.systemGrayColor,
            @"Beta":                UIColor.systemPurpleColor,
            @"Experimental":        UIColor.systemRedColor,
            @"In Development":      UIColor.systemPurpleColor,
            @"JavaScript Tweaks":   UIColor.systemOrangeColor,
        };
    });
    return map[cat] ?: UIColor.secondaryLabelColor;
}

#pragma mark - Source Packages (drill-down)

@interface SourcePackagesViewController : UITableViewController
@property (nonatomic, copy) NSString *repoURL;
@end

@implementation SourcePackagesViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    NSDictionary *repo = sources_repo_for_url(self.repoURL);
    NSString *name = sources_string_or_empty(repo[@"repoName"]);
    self.title = name.length ? name : @"Source";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)sources_tweaks_for_url(self.repoURL).count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSourcePkgCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kSourcePkgCellID];
    }
    NSArray *tweaks = sources_tweaks_for_url(self.repoURL);
    if (indexPath.row >= (NSInteger)tweaks.count) return cell;
    NSDictionary *tweak = tweaks[indexPath.row];

    NSString *sym = sources_string_or_empty(tweak[@"symbol"]);
    if (sym.length == 0) sym = @"shippingbox.and.arrow.down.fill";
    UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];
    config.image = CYIconBadgeImage(sym, CYSpectrumColor((NSUInteger)indexPath.row), 32.0);
    config.imageProperties.reservedLayoutSize = CGSizeMake(32.0, 32.0);
    config.imageProperties.maximumSize = CGSizeMake(32.0, 32.0);
    config.imageToTextPadding = 12.0;
    config.text = sources_string_or_empty(tweak[@"name"]);
    config.textProperties.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    NSString *version = sources_string_or_empty(tweak[@"version"]);
    NSString *desc = sources_string_or_empty(tweak[@"description"]);
    NSString *unsupportedReason = repotweaks_unsupported_reason(tweak);
    NSString *compatibility = unsupportedReason.length ? unsupportedReason : repotweaks_compatibility_note(tweak);
    Package *pkg = sources_package_for_tweak(self.repoURL, tweak);
    BOOL installed = pkg.isInstalled;
    BOOL disabledForInstall = unsupportedReason.length > 0 && !installed;
    if (disabledForInstall) {
        config.image = CYIconBadgeImage(sym, UIColor.secondaryLabelColor, 32.0);
        config.textProperties.color = UIColor.secondaryLabelColor;
    }
    if (installed && unsupportedReason.length && desc.length) {
        config.secondaryText = [NSString stringWithFormat:@"Installed, unsupported here · %@ · %@", unsupportedReason, desc];
    } else if (installed && unsupportedReason.length) {
        config.secondaryText = [NSString stringWithFormat:@"Installed, unsupported here · %@", unsupportedReason];
    } else if (version.length && compatibility.length && desc.length) {
        config.secondaryText = [NSString stringWithFormat:@"v%@ · %@ · %@", version, compatibility, desc];
    } else if (version.length && compatibility.length) {
        config.secondaryText = [NSString stringWithFormat:@"v%@ · %@", version, compatibility];
    } else if (version.length) {
        config.secondaryText = [NSString stringWithFormat:@"v%@ · %@", version, desc];
    } else if (compatibility.length && desc.length) {
        config.secondaryText = [NSString stringWithFormat:@"%@ · %@", compatibility, desc];
    } else {
        config.secondaryText = desc;
    }
    config.secondaryTextProperties.color = unsupportedReason.length
        ? UIColor.systemOrangeColor
        : [UIColor.labelColor colorWithAlphaComponent:0.55];
    config.secondaryTextProperties.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    config.secondaryTextProperties.numberOfLines = 2;
    config.textToSecondaryTextVerticalPadding = 2.0;
    NSDirectionalEdgeInsets m = config.directionalLayoutMargins;
    m.top = 10.0; m.bottom = 10.0;
    config.directionalLayoutMargins = m;
    cell.contentConfiguration = config;

    if (installed && unsupportedReason.length > 0) {
        UILabel *pill = [[UILabel alloc] init];
        pill.text = @"INSTALLED";
        pill.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightHeavy];
        pill.textColor = UIColor.systemGreenColor;
        pill.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.15];
        pill.textAlignment = NSTextAlignmentCenter;
        [pill sizeToFit];
        CGRect f = pill.frame;
        f.size.width += 14.0;
        f.size.height = 22.0;
        pill.frame = f;
        pill.layer.cornerRadius = f.size.height / 2.0;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.layer.masksToBounds = YES;
        cell.accessoryView = pill;
    } else if (unsupportedReason.length > 0) {
        UILabel *pill = [[UILabel alloc] init];
        pill.text = @"UNSUPPORTED";
        pill.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightHeavy];
        pill.textColor = UIColor.systemOrangeColor;
        pill.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.15];
        pill.textAlignment = NSTextAlignmentCenter;
        [pill sizeToFit];
        CGRect f = pill.frame;
        f.size.width += 14.0;
        f.size.height = 22.0;
        pill.frame = f;
        pill.layer.cornerRadius = f.size.height / 2.0;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.layer.masksToBounds = YES;
        cell.accessoryView = pill;
    } else if (sources_tweak_has_update(self.repoURL, tweak)) {
        UILabel *pill = [[UILabel alloc] init];
        pill.text = @"UPDATE";
        pill.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightHeavy];
        pill.textColor = UIColor.systemBlueColor;
        pill.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.15];
        pill.textAlignment = NSTextAlignmentCenter;
        [pill sizeToFit];
        CGRect f = pill.frame;
        f.size.width += 14.0;
        f.size.height = 22.0;
        pill.frame = f;
        pill.layer.cornerRadius = f.size.height / 2.0;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.layer.masksToBounds = YES;
        cell.accessoryView = pill;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *tweaks = sources_tweaks_for_url(self.repoURL);
    if (indexPath.row >= (NSInteger)tweaks.count) return;
    PackageDetailViewController *detail = [[PackageDetailViewController alloc] initWithPackage:sources_package_for_tweak(self.repoURL, tweaks[indexPath.row])];
    [self.navigationController pushViewController:detail animated:YES];
}

@end

#pragma mark - Sources list

@interface SourcesViewController ()
@property (nonatomic, copy) NSArray<NSString *> *urls;
@property (nonatomic, copy) NSArray<NSString *> *categories;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<Package *> *> *packagesByCategory;
@end

@implementation SourcesViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Sources";
    self.navigationItem.title = @"Sources";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;

    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                         target:self
                                                                         action:@selector(addSource)];
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                             target:self
                                                                             action:@selector(refreshAll)];
    self.navigationItem.rightBarButtonItems = @[add, refresh];

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(pullToRefresh) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;

    repotweaks_seed_default_repos();
    [self reloadSources];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sourcesDidRefresh:)
                                                 name:RepoTweaksDidRefreshNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sourcesDidRefresh:)
                                                 name:PackageQueueDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sourcesDidRefresh:)
                                                 name:kSettingsActionsDidCompleteNotification
                                               object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

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
            // QuickLoader has no package page to return to, so the back button
            // is labelled with, and switches to, the tab it was opened from.
            ql.installerReturnTabTitle = self.navigationController.tabBarItem.title;
            [nav pushViewController:ql animated:NO];
            tab.selectedIndex = i;
            return;
        }
    }
}

- (void)pullToRefresh
{
    [self.refreshControl endRefreshing];
    MainTabBarController *tab = (MainTabBarController *)self.tabBarController;
    if ([tab respondsToSelector:@selector(showRefreshBanner)]) [tab showRefreshBanner];
    repotweaks_refresh_all_sources(nil);
}

- (void)sourcesDidRefresh:(NSNotification *)note
{
    if (!self.isViewLoaded) return;
    [self reloadSources];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadSources];
}

- (void)reloadSources
{
    self.urls = sources_urls();
    [self refreshCategories];
    [self.tableView reloadData];
}

- (void)refreshCategories
{
    NSDictionary<NSString *, NSArray<Package *> *> *all = [PackageCatalog packagesByCategory];
    NSMutableArray<NSString *> *cats = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSArray<Package *> *> *filtered = [NSMutableDictionary dictionary];

    for (NSString *cat in [PackageCatalog categoriesInOrder]) {
        NSArray<Package *> *pkgs = all[cat];
        if (pkgs.count > 0) {
            [cats addObject:cat];
            filtered[cat] = pkgs;
        }
    }
    self.categories = cats;
    self.packagesByCategory = filtered;
}

- (void)showDocsForMode:(JSTweakDocsMode)mode
{
    JSTweakDocsViewController *docs = [[JSTweakDocsViewController alloc] init];
    docs.docsMode = mode;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:docs];
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Cell renderers

- (UITableViewCell *)categoryCellForRow:(NSInteger)row tableView:(UITableView *)tableView
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCategoryCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kCategoryCellID];
    }

    NSString *cat = self.categories[row];
    NSUInteger count = self.packagesByCategory[cat].count;

    UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];
    config.image = CYIconBadgeImage(category_icon(cat), category_color(cat), 32.0);
    config.imageProperties.reservedLayoutSize = CGSizeMake(32.0, 32.0);
    config.imageProperties.maximumSize = CGSizeMake(32.0, 32.0);
    config.imageToTextPadding = 12.0;
    config.text = cat;
    config.textProperties.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    config.secondaryText = [NSString stringWithFormat:@"%lu package%@",
                            (unsigned long)count, count == 1 ? @"" : @"s"];
    config.secondaryTextProperties.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    config.secondaryTextProperties.color = [UIColor.labelColor colorWithAlphaComponent:0.55];
    config.textToSecondaryTextVerticalPadding = 2.0;
    NSDirectionalEdgeInsets m = config.directionalLayoutMargins;
    m.top = 10.0; m.bottom = 10.0;
    config.directionalLayoutMargins = m;
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.accessoryView = nil;
    return cell;
}

- (UITableViewCell *)docCellForRow:(NSInteger)row tableView:(UITableView *)tableView
{
    static NSString *kDocCellID = @"DocCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kDocCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kDocCellID];
    }

    UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];
    config.imageProperties.reservedLayoutSize = CGSizeMake(32.0, 32.0);
    config.imageProperties.maximumSize = CGSizeMake(32.0, 32.0);
    config.imageToTextPadding = 12.0;
    config.textProperties.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    config.secondaryTextProperties.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    config.secondaryTextProperties.color = [UIColor.labelColor colorWithAlphaComponent:0.55];
    config.textToSecondaryTextVerticalPadding = 2.0;
    NSDirectionalEdgeInsets m = config.directionalLayoutMargins;
    m.top = 10.0; m.bottom = 10.0;
    config.directionalLayoutMargins = m;

    if (row == 0) {
        config.image = CYIconBadgeImage(@"hammer.fill", UIColor.systemOrangeColor, 32.0);
        config.text = @"Build Your Own JS Tweak";
        config.secondaryText = @"Write scripts, declare parameters, use the RemoteCall API";
    } else {
        config.image = CYIconBadgeImage(@"server.rack", UIColor.systemIndigoColor, 32.0);
        config.text = @"Set Up a Tweak Repository";
        config.secondaryText = @"Host a JSON feed on GitHub Pages or any HTTPS server";
    }

    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - Add/Refresh

- (void)addSource
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Source"
                                                                   message:@"Paste an HTTPS RepoTweaks JSON URL."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://example.com/packages.json";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        NSString *url = alert.textFields.firstObject.text ?: @"";
        repotweaks_refresh_repo(url, ^(BOOL success, NSString *message) {
            [self reloadSources];
            [[NSNotificationCenter defaultCenter] postNotificationName:RepoTweaksDidRefreshNotification object:nil];
            if (!success) [self presentError:message ?: @"Could not refresh that source."];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)refreshAll
{
    NSArray<NSString *> *urls = sources_urls();
    if (urls.count == 0) return;

    MainTabBarController *tab = (MainTabBarController *)self.tabBarController;
    if ([tab respondsToSelector:@selector(showRefreshBanner)]) [tab showRefreshBanner];

    dispatch_group_t group = dispatch_group_create();
    __block NSString *firstError = nil;
    for (NSString *url in urls) {
        dispatch_group_enter(group);
        repotweaks_refresh_repo(url, ^(BOOL success, NSString *message) {
            if (!success && firstError.length == 0) firstError = message;
            dispatch_group_leave(group);
        });
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self reloadSources];
        [[NSNotificationCenter defaultCenter] postNotificationName:RepoTweaksDidRefreshNotification object:nil];
        if (firstError.length > 0) [self presentError:firstError];
    });
}

- (void)presentError:(NSString *)message
{
    UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Source Failed"
                                                                 message:message ?: @"Could not refresh source."
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:err animated:YES completion:nil];
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return SourcesSectionCount;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (section == SourcesSectionRepos) return self.urls.count > 0 ? CYSectionHeaderView(@"Repositories") : nil;
    if (section == SourcesSectionQuickLoader) return CYSectionHeaderView(@"QuickLoader");
    if (section == SourcesSectionCategories) return self.categories.count > 0 ? CYSectionHeaderView(@"Categories") : nil;
    return CYSectionHeaderView(@"Developer");
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if (section == SourcesSectionRepos && self.urls.count == 0) return 0.0;
    if (section == SourcesSectionCategories && self.categories.count == 0) return 0.0;
    return 46.0;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == SourcesSectionRepos) {
        if (self.urls.count == 0) return @"No sources added yet. Tap + to add an HTTPS RepoTweaks JSON URL.";
        return @"Swipe left to remove a source.";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == SourcesSectionRepos) return (NSInteger)self.urls.count;
    if (section == SourcesSectionQuickLoader) return 1;
    if (section == SourcesSectionCategories) return (NSInteger)self.categories.count;
    return 2;
}

- (UITableViewCell *)quickLoaderCellForTableView:(UITableView *)tableView
{
    static NSString *kQLCellID = @"QLCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kQLCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kQLCellID];
    }
    UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];
    config.image = CYIconBadgeImage(@"bolt.fill", UIColor.systemOrangeColor, 32.0);
    config.imageProperties.reservedLayoutSize = CGSizeMake(32.0, 32.0);
    config.imageProperties.maximumSize = CGSizeMake(32.0, 32.0);
    config.imageToTextPadding = 12.0;
    config.text = @"Open QuickLoader";
    config.textProperties.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    config.secondaryText = @"Run a local .js tweak file";
    config.secondaryTextProperties.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    config.secondaryTextProperties.color = [UIColor.labelColor colorWithAlphaComponent:0.55];
    config.textToSecondaryTextVerticalPadding = 2.0;
    NSDirectionalEdgeInsets m = config.directionalLayoutMargins;
    m.top = 10.0; m.bottom = 10.0;
    config.directionalLayoutMargins = m;
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == SourcesSectionQuickLoader) return [self quickLoaderCellForTableView:tableView];
    if (indexPath.section == SourcesSectionCategories) return [self categoryCellForRow:indexPath.row tableView:tableView];
    if (indexPath.section == SourcesSectionDeveloper) return [self docCellForRow:indexPath.row tableView:tableView];

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSourceCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kSourceCellID];
    }
    if (indexPath.row >= (NSInteger)self.urls.count) return cell;
    NSString *url = self.urls[indexPath.row];
    NSDictionary *repo = sources_repo_for_url(url);
    NSArray *tweaks = sources_tweaks_for_url(url);
    NSString *repoName = sources_string_or_empty(repo[@"repoName"]);
    NSString *author = sources_string_or_empty(repo[@"author"]);

    UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];
    config.image = CYIconBadgeImage(@"tray.and.arrow.down.fill", UIColor.systemGreenColor, 32.0);
    config.imageProperties.reservedLayoutSize = CGSizeMake(32.0, 32.0);
    config.imageProperties.maximumSize = CGSizeMake(32.0, 32.0);
    config.imageToTextPadding = 12.0;
    config.text = repoName.length ? repoName : @"Unknown Source";
    config.textProperties.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];

    NSUInteger updates = sources_update_count_for_url(url);
    NSMutableString *detail = [NSMutableString string];
    if (author.length) [detail appendFormat:@"%@ · ", author];
    [detail appendFormat:@"%lu package%@", (unsigned long)tweaks.count, tweaks.count == 1 ? @"" : @"s"];
    if (updates > 0) [detail appendFormat:@" · %lu update%@", (unsigned long)updates, updates == 1 ? @"" : @"s"];
    config.secondaryText = detail;
    config.secondaryTextProperties.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    config.secondaryTextProperties.color = updates > 0 ? UIColor.systemBlueColor : [UIColor.labelColor colorWithAlphaComponent:0.55];
    config.textToSecondaryTextVerticalPadding = 2.0;

    NSDirectionalEdgeInsets m = config.directionalLayoutMargins;
    m.top = 10.0; m.bottom = 10.0;
    config.directionalLayoutMargins = m;
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == SourcesSectionQuickLoader) {
        [self openQuickLoader];
        return;
    }

    if (indexPath.section == SourcesSectionCategories) {
        NSString *cat = self.categories[indexPath.row];
        CategoryPackagesViewController *list = [[CategoryPackagesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        list.categoryName = cat;
        [self.navigationController pushViewController:list animated:YES];
        return;
    }

    if (indexPath.section == SourcesSectionDeveloper) {
        [self showDocsForMode:(indexPath.row == 0) ? JSTweakDocsModeWriteTweak : JSTweakDocsModeSetupRepo];
        return;
    }

    if (indexPath.row >= (NSInteger)self.urls.count) return;
    SourcePackagesViewController *detail = [[SourcePackagesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    detail.repoURL = self.urls[indexPath.row];
    [self.navigationController pushViewController:detail animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == SourcesSectionRepos;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.row >= (NSInteger)self.urls.count) return;

    NSString *url = self.urls[indexPath.row];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    sources_clear_repo_defaults(url);

    NSMutableArray *urls = [sources_urls() mutableCopy];
    [urls removeObject:url];
    [d setObject:urls forKey:@"RepoTweaksURLs"];

    NSMutableDictionary *caches = [sources_caches() mutableCopy];
    [caches removeObjectForKey:url];
    [d setObject:caches forKey:@"RepoTweaksCaches"];
    [d synchronize];
    [self reloadSources];
}

@end
