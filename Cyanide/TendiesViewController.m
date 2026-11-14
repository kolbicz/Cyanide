//
//  TendiesViewController.m
//  Cyanide
//
//  Settings → Lara → Tendies Wallpapers. Pick .tendies files and they are
//  installed right away (tweaks/tendies.m); the wallpapers Cyanide added are
//  listed and can be removed one by one (swipe) or all at once.
//

#import "TendiesViewController.h"
#import "SettingsViewController.h"
#import "tweaks/tendies.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const kTDCredit =
    @"The .tendies format is Nugget's, by leminlimez. Installing follows Nugget and mond by rooootdev.";

typedef NS_ENUM(NSInteger, TDSection) {
    TDSectionActions,
    TDSectionAdded,
    TDSectionCount,
};

@interface TendiesViewController () <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *added;
@property (nonatomic) BOOL busy;
@property (nonatomic, copy) NSString *status;
@end

@implementation TendiesViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Tendies Wallpapers";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.added = tendies_added();
}

#pragma mark Running

- (void)run:(NSString *)name work:(BOOL (^)(NSString **message))work done:(void (^)(BOOL ok, NSString *message))done
{
    if (self.busy) return;
    self.busy = YES;
    self.status = [name stringByAppendingString:@"…"];
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    settings_kernel_file_tool_async("Tendies", NO, work, ^(BOOL ok, NSString *message) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me.busy = NO;
        me.added = tendies_added();
        if ([message isEqualToString:kSettingsFullExploitRequiredMessage]) {
            me.status = kSettingsNoKernelAccessHint;
            [me.tableView reloadData];
            settings_tool_needs_exploit(me, me.tableView, @"Tendies Wallpapers", ^{
                [weakSelf run:name work:work done:done];
            });
            return;
        }
        me.status = ok ? message : (message ?: @"It didn't work. Check the log.");
        if (done) done(ok, message);
        [me.tableView reloadData];
    });
}

- (void)pickFiles
{
    if (self.busy) return;
    // .tendies has no registered type; it is a zip, so any data file is offered.
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeZIP, UTTypeData ] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    if (urls.count == 0) return;
    NSArray<NSURL *> *files = [urls copy];
    __block NSUInteger count = 0;
    __weak typeof(self) weakSelf = self;
    [self run:@"Installing" work:^BOOL(NSString **message) {
        BOOL ok = tendies_install(files, &count, message);
        for (NSURL *url in files) [NSFileManager.defaultManager removeItemAtURL:url error:nil];  // our picked copies
        return ok;
    } done:^(BOOL ok, NSString *message) {
        typeof(self) me = weakSelf;
        if (!ok || !me) return;
        NSString *body = [NSString stringWithFormat:
            @"%lu wallpaper%@ added. Long-press the Lock Screen, tap +, and pick it from the gallery (Collections, or Photos for video wallpapers).%@",
            (unsigned long)count, count == 1 ? @"" : @"s",
            message.length ? [@"\n\n" stringByAppendingString:message] : @""];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Wallpapers Installed" message:body
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [me presentViewController:ac animated:YES completion:nil];
    }];
}

- (void)removePaths:(NSArray<NSString *> *)paths title:(NSString *)title
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
        message:@"Removes the wallpaper from the gallery and restarts PosterBoard. If it is your current Lock Screen, choose another one first. Apple's wallpapers aren't touched."
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [weakSelf run:@"Removing" work:^BOOL(NSString **message) {
            return tendies_remove(paths, message);
        } done:nil];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return TDSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == TDSectionActions) return self.added.count ? 2 : 1;
    return self.added.count ? (NSInteger)self.added.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == TDSectionAdded ? @"Added by Cyanide" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == TDSectionActions) {
        NSString *help = @"Adds .tendies wallpapers to the Lock Screen wallpaper gallery. PosterBoard restarts afterwards, so the Lock Screen may flash. Install a few at a time: PosterBoard gets slow with many custom wallpapers.";
        return self.status.length ? [NSString stringWithFormat:@"%@\n\n%@", self.status, help] : help;
    }
    return self.added.count ? [@"Swipe a wallpaper to remove it.\n\n" stringByAppendingString:kTDCredit] : kTDCredit;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (indexPath.section == TDSectionActions) {
        BOOL import = indexPath.row == 0;
        c.text = import ? @"Install .tendies Files…" : @"Remove All Added";
        c.image = [UIImage systemImageNamed:import ? @"square.and.arrow.down" : @"trash"];
        c.textProperties.color = self.busy ? UIColor.secondaryLabelColor
                                           : (import ? self.view.tintColor : UIColor.systemRedColor);
        c.imageProperties.tintColor = c.textProperties.color;
    } else if (self.added.count == 0) {
        c.text = @"None yet";
        c.textProperties.color = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSDictionary *item = self.added[indexPath.row];
        c.text = item[@"name"];
        NSDate *date = item[@"date"];
        if ([date isKindOfClass:NSDate.class])
            c.secondaryText = [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterMediumStyle
                                                             timeStyle:NSDateFormatterShortStyle];
        c.image = [UIImage systemImageNamed:@"photo.on.rectangle"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != TDSectionActions || self.busy) return;
    if (indexPath.row == 0) {
        [self pickFiles];
    } else {
        [self removePaths:nil title:[NSString stringWithFormat:@"Remove %lu Wallpaper%@?",
                                     (unsigned long)self.added.count, self.added.count == 1 ? @"" : @"s"]];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == TDSectionAdded && self.added.count > 0 && !self.busy;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete || ![self tableView:tableView canEditRowAtIndexPath:indexPath]) return;
    NSDictionary *item = self.added[indexPath.row];
    [self removePaths:@[item[@"path"]] title:[NSString stringWithFormat:@"Remove “%@”?", item[@"name"]]];
}

@end
