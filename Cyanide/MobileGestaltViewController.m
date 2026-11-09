//
//  MobileGestaltViewController.m
//  Cyanide
//
//  Settings → Lara → MobileGestalt. Ported from lara by rooootdev
//  (views/tweaks/mobilegestalt/GestaltView.swift and GestaltFileView.swift),
//  with his permission. Changes are collected here and written in one go with
//  Apply; tweaks/mobilegestalt.m does the file work.
//

#import "MobileGestaltViewController.h"
#import "SettingsViewController.h"
#import "LogTextView.h"
#import "tweaks/mobilegestalt.h"

static NSString * const kMGCredit =
    @"Ported from lara by rooootdev. Keys from Nugget by leminlimez and SparseBox by khanhduytran0.";

typedef NS_ENUM(NSInteger, MGRowKind) {
    MGRowApply,
    MGRowDiscard,
    MGRowRestore,
    MGRowAllKeys,
    MGRowSubtype,
    MGRowDeviceName,
    MGRowProductType,
    MGRowTweak,
};

typedef struct { int value; const char *title; double minVersion; } MGSubtype;
static const MGSubtype kMGSubtypes[] = {
    { 2436, "2436 · notch (iPhone X style; hides the Dynamic Island)", 0 },
    { 2556, "2556 · iPhone 14 Pro, 15, 15 Pro, 16", 0 },
    { 2796, "2796 · 14 Pro Max, 15 Plus, 15 Pro Max, 16 Plus", 0 },
    { 2622, "2622 · iPhone 16 Pro", 18.0 },
    { 2868, "2868 · iPhone 16 Pro Max", 18.0 },
    { 2736, "2736 · iPhone Air", 26.0 },
};

typedef struct { const char *type; const char *title; double minVersion; BOOL pad; } MGModel;
static const MGModel kMGModels[] = {
    { "iPhone16,1", "iPhone 15 Pro", 0, NO },
    { "iPhone16,2", "iPhone 15 Pro Max", 0, NO },
    { "iPhone17,3", "iPhone 16", 18.0, NO },
    { "iPhone17,4", "iPhone 16 Plus", 18.0, NO },
    { "iPhone17,1", "iPhone 16 Pro", 18.0, NO },
    { "iPhone17,2", "iPhone 16 Pro Max", 18.0, NO },
    { "iPhone18,3", "iPhone 17", 26.0, NO },
    { "iPhone18,1", "iPhone 17 Pro", 26.0, NO },
    { "iPhone18,2", "iPhone 17 Pro Max", 26.0, NO },
    { "iPhone18,4", "iPhone Air", 26.0, NO },
    { "iPad16,3", "iPad Pro 11-inch (M4)", 17.4, YES },
    { "iPad16,4", "iPad Pro 11-inch (M4, Cellular)", 17.4, YES },
    { "iPad14,3", "iPad Pro 11-inch (4th generation)", 0, YES },
    { "iPad14,4", "iPad Pro 11-inch (4th generation, Cellular)", 0, YES },
};

@interface MGKeysViewController : UITableViewController
- (instancetype)initWithCache:(NSDictionary *)mg;
@end

@interface MobileGestaltViewController ()
@property (nonatomic, strong) NSMutableDictionary *mg;   // working copy; nil until loaded
@property (nonatomic) BOOL dirty;
@property (nonatomic) BOOL busy;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) NSArray<NSDictionary *> *sections;   // title, rows: [@[kind, index]]
@end

@implementation MobileGestaltViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"MobileGestalt";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self buildSections];
    [self load];
}

- (BOOL)isPad
{
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
}

- (void)buildSections
{
    NSMutableArray *sections = [NSMutableArray array];
    [sections addObject:@{ @"title": @"", @"rows": @[@[@(MGRowApply), @0], @[@(MGRowDiscard), @0],
                                                    @[@(MGRowRestore), @0], @[@(MGRowAllKeys), @0]] }];
    NSMutableArray *artwork = [NSMutableArray array];
    if (!self.isPad) [artwork addObject:@[@(MGRowSubtype), @0]];
    [artwork addObject:@[@(MGRowDeviceName), @0]];
    [sections addObject:@{ @"title": @"Device Artwork", @"rows": artwork }];

    const MGTweak *t = mg_tweaks();
    NSString *current = nil;
    NSMutableArray *rows = nil;
    for (NSInteger i = 0; t[i].title; i++) {
        NSString *section = @(t[i].section);
        if (![section isEqualToString:current]) {
            if (rows) [sections addObject:@{ @"title": current, @"rows": rows }];
            current = section;
            rows = [NSMutableArray array];
        }
        [rows addObject:@[@(MGRowTweak), @(i)]];
        if ([section isEqualToString:@"Eligibility"] && !(t[i + 1].title && !strcmp(t[i + 1].section, "Eligibility")))
            [rows addObject:@[@(MGRowProductType), @0]];
    }
    if (rows) [sections addObject:@{ @"title": current, @"rows": rows }];
    self.sections = sections;
}

#pragma mark Running

// File work with the usual kernel-access handling (offers an exploit run when
// only a full run would help).
- (void)run:(NSString *)name work:(BOOL (^)(NSString **message))work done:(void (^)(BOOL ok, NSString *message))done
{
    if (self.busy) return;
    self.busy = YES;
    self.status = [name stringByAppendingString:@"…"];
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    settings_kernel_file_tool_async("MobileGestalt", NO, work, ^(BOOL ok, NSString *message) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me.busy = NO;
        if ([message isEqualToString:kSettingsFullExploitRequiredMessage]) {
            me.status = kSettingsNoKernelAccessHint;
            [me.tableView reloadData];
            settings_tool_needs_exploit(me, me.tableView, @"MobileGestalt", ^{
                [weakSelf run:name work:work done:done];
            });
            return;
        }
        me.status = ok ? nil : (message ?: @"It didn't work. Check the log.");
        if (done) done(ok, message);
        [me.tableView reloadData];
    });
}

- (void)load
{
    __block NSMutableDictionary *loaded = nil;
    __weak typeof(self) weakSelf = self;
    [self run:@"Reading" work:^BOOL(NSString **message) {
        loaded = mg_load(message);
        return loaded != nil;
    } done:^(BOOL ok, NSString *message) {
        if (!ok) return;
        weakSelf.mg = loaded;
        weakSelf.dirty = NO;
    }];
}

- (void)apply
{
    if (!self.mg || !self.dirty) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Apply Changes?"
        message:@"The MobileGestalt cache is rewritten. The file as it is now is backed up first, and Restore Original puts the untouched cache back."
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSDictionary *snapshot = [weakSelf.mg copy];
        [weakSelf run:@"Writing" work:^BOOL(NSString **message) {
            BOOL ok = mg_write(snapshot, message);
            log_user("%s MobileGestalt: %s\n", ok ? "[OK]" : "[FAIL]", ok ? "changes written" : (*message).UTF8String);
            return ok;
        } done:^(BOOL ok, NSString *message) {
            typeof(self) me = weakSelf;
            if (!ok || !me) return;
            me.dirty = NO;
            settings_present_respring_prompt(me, @"MobileGestalt Saved",
                                             @"Respring to see the changes. Some only show after a restart.");
        }];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)restoreOriginal
{
    if (!mg_has_original_backup()) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Restore Original?"
        message:@"Puts back the MobileGestalt cache as it was before Cyanide first changed it. Every tweak on this page is undone."
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        __block NSMutableDictionary *reloaded = nil;
        [weakSelf run:@"Restoring" work:^BOOL(NSString **message) {
            BOOL ok = mg_restore_original(message);
            log_user("%s MobileGestalt: %s\n", ok ? "[OK]" : "[FAIL]", ok ? "original restored" : (*message).UTF8String);
            if (ok) reloaded = mg_load(NULL);
            return ok;
        } done:^(BOOL ok, NSString *message) {
            typeof(self) me = weakSelf;
            if (!ok || !me) return;
            if (reloaded) me.mg = reloaded;
            me.dirty = NO;
            settings_present_respring_prompt(me, @"Original Restored",
                                             @"Respring to see it. Some changes only go away after a restart.");
        }];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)changed
{
    self.dirty = YES;
    [self.tableView reloadData];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return self.mg ? (NSInteger)self.sections.count : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (!self.mg) return 0;
    return (NSInteger)[self.sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    NSString *title = self.mg ? self.sections[section][@"title"] : nil;
    return title.length ? title : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    NSMutableArray *parts = [NSMutableArray array];
    if (section == 0) {
        if (self.status) [parts addObject:self.status];
        else if (self.dirty) [parts addObject:@"Changes are not saved yet. Tap Apply Changes."];
        [parts addObject:@"Changes what iOS believes this device can do, by editing the MobileGestalt cache. A wrong value can break features or, in rare cases, stop the device from starting until it is restored. Every write is backed up (Documents/MobileGestalt), and Restore Original undoes everything."];
    }
    if (section == [self numberOfSectionsInTableView:tableView] - 1) [parts addObject:kMGCredit];
    return parts.count ? [parts componentsJoinedByString:@"\n\n"] : nil;
}

- (NSArray *)rowAt:(NSIndexPath *)indexPath
{
    return self.sections[indexPath.section][@"rows"][indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    NSArray *row = [self rowAt:indexPath];
    MGRowKind kind = (MGRowKind)[row[0] integerValue];
    UIColor *action = self.busy ? UIColor.secondaryLabelColor : UIColor.systemBlueColor;

    switch (kind) {
        case MGRowApply:
            c.text = @"Apply Changes";
            c.textProperties.color = self.dirty && !self.busy ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
            break;
        case MGRowDiscard:
            c.text = @"Discard Changes";
            c.textProperties.color = self.dirty && !self.busy ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
            break;
        case MGRowRestore:
            c.text = @"Restore Original…";
            c.textProperties.color = mg_has_original_backup() && !self.busy ? UIColor.systemRedColor
                                                                            : UIColor.secondaryLabelColor;
            break;
        case MGRowAllKeys:
            c.text = @"All Keys";
            c.textProperties.color = action;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case MGRowSubtype: {
            c.text = @"Screen Shape";
            c.image = [UIImage systemImageNamed:@"iphone"];
            NSNumber *now = mg_artwork_subtype(self.mg), *orig = mg_original_artwork_subtype();
            c.secondaryText = [now isEqual:orig] || !now ? [NSString stringWithFormat:@"Original (%@)", orig ?: now ?: @"?"]
                                                        : [self subtypeTitle:now.intValue];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case MGRowDeviceName: {
            c.text = @"Model Name";
            c.image = [UIImage systemImageNamed:@"character.cursor.ibeam"];
            NSString *name = mg_device_name(self.mg);
            BOOL custom = name && ![name isEqualToString:mg_original_device_name()];
            c.secondaryText = custom ? name : [NSString stringWithFormat:@"Original (%@)", name ?: mg_machine_name()];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case MGRowProductType: {
            c.text = @"Spoof Device Model";
            c.image = [UIImage systemImageNamed:@"theatermasks"];
            NSString *type = mg_product_type(self.mg);
            c.secondaryText = [type isEqualToString:mg_original_product_type()]
                ? [NSString stringWithFormat:@"Original (%@)", type] : [self modelTitle:type];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case MGRowTweak: {
            const MGTweak *t = &mg_tweaks()[[row[1] integerValue]];
            c.text = @(t->title);
            c.image = [UIImage systemImageNamed:@(t->icon)] ?: [UIImage systemImageNamed:@"gearshape"];
            NSString *why = nil;
            BOOL available = mg_tweak_available(t, &why);
            BOOL builtin = mg_tweak_builtin(t);
            c.secondaryText = !available ? why : (builtin ? @"Built into this device." : @(t->detail));
            UISwitch *sw = [UISwitch new];
            sw.on = mg_tweak_is_on(self.mg, t);
            sw.enabled = available && !builtin && !self.busy;
            sw.tag = [row[1] integerValue];
            [sw addTarget:self action:@selector(switched:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            if (!available) c.textProperties.color = UIColor.secondaryLabelColor;
            break;
        }
    }
    cell.contentConfiguration = c;
    return cell;
}

- (NSString *)subtypeTitle:(int)value
{
    for (size_t i = 0; i < sizeof(kMGSubtypes) / sizeof(kMGSubtypes[0]); i++)
        if (kMGSubtypes[i].value == value) return @(kMGSubtypes[i].title);
    return [NSString stringWithFormat:@"%d", value];
}

- (NSString *)modelTitle:(NSString *)type
{
    for (size_t i = 0; i < sizeof(kMGModels) / sizeof(kMGModels[0]); i++)
        if ([type isEqualToString:@(kMGModels[i].type)]) return @(kMGModels[i].title);
    return type;
}

- (void)switched:(UISwitch *)sw
{
    const MGTweak *t = &mg_tweaks()[sw.tag];
    BOOL on = sw.on;
    __weak typeof(self) weakSelf = self;
    void (^set)(void) = ^{
        typeof(self) me = weakSelf;
        if (!me) return;
        NSString *error = nil;
        if (!mg_tweak_set(me.mg, t, on, &error)) {
            me.status = error ?: @"That didn't work.";
            [me.tableView reloadData];
            return;
        }
        me.status = nil;
        [me changed];
    };
    if (on && (t->flags & MGTweakFlagConfirm) && t->warning) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@(t->title) message:@(t->warning)
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
            [sw setOn:NO animated:YES];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Turn On" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            set();
        }]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }
    set();
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.busy || !self.mg) return;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    switch ((MGRowKind)[[self rowAt:indexPath][0] integerValue]) {
        case MGRowApply: [self apply]; break;
        case MGRowDiscard: if (self.dirty) [self load]; break;
        case MGRowRestore: [self restoreOriginal]; break;
        case MGRowAllKeys:
            [self.navigationController pushViewController:[[MGKeysViewController alloc] initWithCache:self.mg] animated:YES];
            break;
        case MGRowSubtype: [self pickSubtypeFrom:cell]; break;
        case MGRowDeviceName: [self editDeviceName]; break;
        case MGRowProductType: [self pickModelFrom:cell]; break;
        case MGRowTweak: break;
    }
}

- (void)presentSheet:(UIAlertController *)sheet from:(UIView *)source
{
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = (source ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickSubtypeFrom:(UIView *)source
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Screen Shape"
        message:@"The device artwork iOS uses for the screen corners, the Dynamic Island and gestures. Respring to see it."
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSNumber *orig = mg_original_artwork_subtype();
    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Original (%@)", orig ?: @"?"]
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        mg_set_artwork_subtype(weakSelf.mg, orig);
        [weakSelf changed];
    }]];
    for (size_t i = 0; i < sizeof(kMGSubtypes) / sizeof(kMGSubtypes[0]); i++) {
        MGSubtype s = kMGSubtypes[i];
        if (s.minVersion > 0 && mg_system_version() + 0.001 < s.minVersion) continue;
        [sheet addAction:[UIAlertAction actionWithTitle:@(s.title) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            mg_set_artwork_subtype(weakSelf.mg, @(s.value));
            [weakSelf changed];
        }]];
    }
    [self presentSheet:sheet from:source];
}

- (void)pickModelFrom:(UIView *)source
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Spoof Device Model"
        message:@"Only for downloading Apple Intelligence models. It can break Face ID. If you switch back and want to keep Apple Intelligence, don't open Apple Intelligence & Siri in Settings again."
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Original (%@)", mg_original_product_type()]
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        mg_set_product_type(weakSelf.mg, nil);
        [weakSelf changed];
    }]];
    for (size_t i = 0; i < sizeof(kMGModels) / sizeof(kMGModels[0]); i++) {
        MGModel m = kMGModels[i];
        if (m.pad != self.isPad) continue;
        if (m.minVersion > 0 && mg_system_version() + 0.001 < m.minVersion) continue;
        NSString *title = [NSString stringWithFormat:@"%s (%s)", m.title, m.type];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            mg_set_product_type(weakSelf.mg, @(m.type));
            [weakSelf changed];
        }]];
    }
    [self presentSheet:sheet from:source];
}

- (void)editDeviceName
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Model Name"
        message:@"The model name shown in Settings → General → About."
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = mg_device_name(self.mg);
        f.placeholder = mg_original_device_name() ?: @"Model name";
        f.clearButtonMode = UITextFieldViewModeAlways;
    }];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Use Original" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        mg_set_device_name(weakSelf.mg, nil);
        [weakSelf changed];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Set" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = [ac.textFields.firstObject.text
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        mg_set_device_name(weakSelf.mg, name.length ? name : nil);
        [weakSelf changed];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

#pragma mark - All keys

// Read-only list of the cache's CacheExtra, with exports (lara's
// GestaltFileView).
@implementation MGKeysViewController {
    NSDictionary *_mg;
    NSDictionary *_extra;
    NSArray<NSString *> *_keys;
}

- (instancetype)initWithCache:(NSDictionary *)mg
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _mg = [mg copy];
        _extra = [mg[@"CacheExtra"] isKindOfClass:NSDictionary.class] ? mg[@"CacheExtra"] : @{};
        _keys = [_extra.allKeys sortedArrayUsingSelector:@selector(compare:)];
        self.title = @"All Keys";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(export:)];
}

- (void)export:(UIBarButtonItem *)sender
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Export" message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Current (with unsaved changes)" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [weakSelf shareCurrentFrom:sender]; }]];
    if (mg_has_original_backup()) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Original Backup" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [weakSelf shareURL:[NSURL fileURLWithPath:mg_original_backup_path()] from:sender];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)shareCurrentFrom:(UIBarButtonItem *)sender
{
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:_mg format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:nil];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.apple.MobileGestalt.plist"];
    if (![data writeToFile:path atomically:YES]) return;
    [self shareURL:[NSURL fileURLWithPath:path] from:sender];
}

- (void)shareURL:(NSURL *)url from:(UIBarButtonItem *)sender
{
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:share animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)_keys.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return [NSString stringWithFormat:@"%lu keys in CacheExtra. Long-press a row to copy it. %@",
            (unsigned long)_keys.count, kMGCredit];
}

- (NSString *)describe:(id)value
{
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    if ([value isKindOfClass:NSData.class]) return [NSString stringWithFormat:@"<%lu bytes>", (unsigned long)[value length]];
    NSString *d = [[value description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    while ([d containsString:@"  "]) d = [d stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return d;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"k"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"k"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    NSString *key = _keys[indexPath.row];
    c.text = key;
    c.textProperties.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    c.secondaryText = [self describe:_extra[key]];
    c.secondaryTextProperties.numberOfLines = 3;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cell.contentConfiguration = c;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    NSString *key = _keys[indexPath.row];
    NSString *value = [self describe:_extra[key]];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        return [UIMenu menuWithChildren:@[
            [UIAction actionWithTitle:@"Copy Key" image:[UIImage systemImageNamed:@"key"] identifier:nil
                              handler:^(UIAction *a) { UIPasteboard.generalPasteboard.string = key; }],
            [UIAction actionWithTitle:@"Copy Value" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                              handler:^(UIAction *a) { UIPasteboard.generalPasteboard.string = value; }],
        ]];
    }];
}

@end
