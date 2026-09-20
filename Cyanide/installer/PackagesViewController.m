//
//  PackagesViewController.m
//  Cyanide
//

#import "PackagesViewController.h"
#import "CYIconBadge.h"
#import "PackageCatalog.h"
#import "PackageDetailViewController.h"
#import "PackageQueue.h"
#import "../SettingsViewController.h"
#import "../tweaks/RepoTweaks.h"

static NSString * const kPkgCellID    = @"PkgCell";
static NSString * const kSearchCellID = @"SearchPkgCell";

@interface PackagesViewController () <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<Package *> *allPackagesSorted;
@property (nonatomic, copy) NSArray<Package *> *searchResults;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, strong) UISearchController *searchCtl;
@end

@implementation PackagesViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Packages";
    self.navigationItem.title = @"Packages";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.searchText = @"";

    [self refreshCatalog];

    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;
    self.tableView.sectionFooterHeight = 4.0;

    self.searchCtl = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchCtl.searchResultsUpdater = self;
    self.searchCtl.obscuresBackgroundDuringPresentation = NO;
    self.searchCtl.searchBar.placeholder = @"Search all tweaks";
    self.navigationItem.searchController = self.searchCtl;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    // Re-queue tweaks applied in this session so they can be applied again
    // without relaunching. Only shown while Cyanide stays open (after an
    // in-session apply emptied the queue); on a fresh relaunch the queue already
    // shows the tweaks, so the button is hidden. See updateReapplyButtonVisibility.
    [self updateReapplyButtonVisibility];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(catalogDidChange:)
                                                 name:PackageQueueDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(catalogDidChange:)
                                                 name:kSettingsActionsDidCompleteNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(catalogDidChange:)
                                                 name:RepoTweaksDidRefreshNotification
                                               object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshCatalog];
    [self.tableView reloadData];
    [self updateReapplyButtonVisibility];
}

- (void)catalogDidChange:(NSNotification *)note
{
    if (!self.isViewLoaded) return;
    [self refreshCatalog];
    [self.tableView reloadData];
    [self updateReapplyButtonVisibility];
}

- (void)updateReapplyButtonVisibility
{
    if (!self.isViewLoaded) return;
    if (settings_has_reappliable_tweaks()) {
        if (!self.navigationItem.rightBarButtonItem) {
            UIBarButtonItem *item =
                [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
                                                 style:UIBarButtonItemStylePlain
                                                target:self
                                                action:@selector(reapplyAppliedTweaks)];
            item.accessibilityLabel = @"Re-apply tweaks";
            self.navigationItem.rightBarButtonItem = item;
        }
    } else {
        self.navigationItem.rightBarButtonItem = nil;
    }
}

- (void)reapplyAppliedTweaks
{
    settings_requeue_applied_tweaks_for_reapply();
    // The applied set is now empty and the queue bar has repopulated, so the
    // button is no longer needed — hide it.
    [self updateReapplyButtonVisibility];
}

- (void)refreshCatalog
{
    // Source-imported JavaScript tweaks are browsed and managed from the Sources
    // tab, so they are left out of this list (and out of its search results, which
    // are built from the same array). Repo-only status travels with them: update
    // availability, the UPDATE badge and the "seen" timestamp are the Sources
    // tab's job now, so this file reads no repotweaks_* state any more.
    NSMutableArray<Package *> *visible = [NSMutableArray array];
    for (Package *p in [PackageCatalog allPackages]) {
        if ([p.category isEqualToString:@"JavaScript Tweaks"]) continue;
        [visible addObject:p];
    }

    self.allPackagesSorted = [visible sortedArrayUsingComparator:^NSComparisonResult(Package *a, Package *b) {
        return [a.name caseInsensitiveCompare:b.name];
    }];
    [self rebuildSearchResults];
}

- (BOOL)isSearchActive { return self.searchText.length > 0; }

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *q = searchController.searchBar.text ?: @"";
    if ([q isEqualToString:self.searchText]) return;
    self.searchText = q;
    [self rebuildSearchResults];
    [self.tableView reloadData];
}

- (void)rebuildSearchResults
{
    if (![self isSearchActive]) { self.searchResults = nil; return; }
    NSString *q = self.searchText;
    NSStringCompareOptions opt = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSMutableArray *out = [NSMutableArray array];
    for (Package *p in self.allPackagesSorted) {
        if ([p.name rangeOfString:q options:opt].location != NSNotFound ||
            [p.shortDescription rangeOfString:q options:opt].location != NSNotFound ||
            [p.category rangeOfString:q options:opt].location != NSNotFound) {
            [out addObject:p];
        }
    }
    self.searchResults = out;
}

#pragma mark - Data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if ([self isSearchActive]) return (NSInteger)self.searchResults.count;
    return (NSInteger)self.allPackagesSorted.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if ([self isSearchActive]) return nil;
    return CYSectionHeaderView(@"All Packages");
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if ([self isSearchActive]) return 0.0;
    return 46.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    Package *pkg = [self isSearchActive] ? self.searchResults[indexPath.row]
                                         : self.allPackagesSorted[indexPath.row];
    return [self packageCellForPackage:pkg colorIndex:(NSUInteger)indexPath.row tableView:tableView];
}

- (UITableViewCell *)packageCellForPackage:(Package *)pkg colorIndex:(NSUInteger)colorIndex tableView:(UITableView *)tableView
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kPkgCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kPkgCellID];
    }

    BOOL installed = pkg.isInstalled;
    BOOL unsupported = pkg.isInstallDisabled && pkg.installDisabledReason.length > 0;
    BOOL disabledForInstall = pkg.isInstallDisabled && !installed;
    UIColor *iconColor = disabledForInstall ? UIColor.secondaryLabelColor : CYSpectrumColor(colorIndex);
    UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];
    config.image = CYIconBadgeImage(pkg.symbolName, iconColor, 32.0);
    config.imageProperties.reservedLayoutSize = CGSizeMake(32.0, 32.0);
    config.imageProperties.maximumSize = CGSizeMake(32.0, 32.0);
    config.imageToTextPadding = 12.0;
    config.text = pkg.name;
    config.textProperties.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    if (disabledForInstall) config.textProperties.color = UIColor.secondaryLabelColor;

    if (unsupported && installed && pkg.shortDescription.length > 0) {
        config.secondaryText = [NSString stringWithFormat:@"Installed, unsupported here · %@ · %@",
                                pkg.installDisabledReason,
                                pkg.shortDescription];
    } else if (unsupported && installed) {
        config.secondaryText = [NSString stringWithFormat:@"Installed, unsupported here · %@",
                                pkg.installDisabledReason];
    } else if (unsupported && pkg.shortDescription.length > 0) {
        config.secondaryText = [NSString stringWithFormat:@"%@ · %@", pkg.installDisabledReason, pkg.shortDescription];
    } else if (unsupported) {
        config.secondaryText = pkg.installDisabledReason;
    } else {
        config.secondaryText = pkg.shortDescription;
    }
    config.secondaryTextProperties.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    config.secondaryTextProperties.color = unsupported
        ? UIColor.systemOrangeColor
        : [UIColor.labelColor colorWithAlphaComponent:0.55];
    config.secondaryTextProperties.numberOfLines = 3;
    config.textToSecondaryTextVerticalPadding = 2.0;
    NSDirectionalEdgeInsets m = config.directionalLayoutMargins;
    m.top = 10.0; m.bottom = 10.0;
    config.directionalLayoutMargins = m;
    cell.contentConfiguration = config;

    if (unsupported && installed) {
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
    } else if (unsupported) {
        UILabel *pill = [[UILabel alloc] init];
        pill.text = [pkg.category isEqualToString:@"In Development"] ? @"DISABLED" : @"UNSUPPORTED";
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
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

#pragma mark - Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    Package *pkg = [self isSearchActive] ? self.searchResults[indexPath.row]
                                         : self.allPackagesSorted[indexPath.row];
    PackageDetailViewController *detail = [[PackageDetailViewController alloc] initWithPackage:pkg];
    [self.navigationController pushViewController:detail animated:YES];
}

@end
