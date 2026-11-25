//
//  LaraViewController.m
//  Cyanide
//
//  Settings → Lara: tools ported from lara by rooootdev
//  (https://github.com/rooootdev/lara), with his permission. The SpringBoard
//  work lives in tweaks/lara_tools.m; this screen only drives it.
//

#import "LaraViewController.h"
#import "SettingsViewController.h"
#import "tweaks/lara_tools.h"
#import "tweaks/app_decrypt.h"
#import "tweaks/sb_materials.h"
#import "tweaks/font_overwrite.h"
#import "FileBrowserViewController.h"
#import "LogTextView.h"
#import <errno.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const kLaraCredit = @"Ported from lara by rooootdev.";

typedef struct { int mode; const char *title; } LaraHUDMode;
static const LaraHUDMode kLaraHUDModes[] = {
    { -1, "Off" }, { 0, "Basic" }, { 1, "Backdrops" }, { 2, "Particles" }, { 3, "Full" },
    { 5, "Power" }, { 7, "EDR" }, { 8, "Glitches" }, { 9, "GPU Time" }, { 10, "Memory Bandwidth" },
};
static const NSInteger kLaraHUDModeCount = sizeof(kLaraHUDModes) / sizeof(kLaraHUDModes[0]);

@interface LaraViewController () <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic) LaraTool tool;
@property (nonatomic) BOOL busy;
@property (nonatomic, copy) NSString *status;        // shown in the first footer
@property (nonatomic) int hudMode;                   // -1 off, -2 unknown
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *prefStates;   // index -> 0/1
@property (nonatomic, copy) NSArray<NSDictionary *> *jitApps;   // nil until listed (JIT / app limit / cards)
@property (nonatomic, strong) NSDictionary *pickingCard;          // card whose image is being picked
@property (nonatomic, strong) UIProgressView *progressBar;        // under the navigation bar while decrypting
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *sbConfig;   // SpringBoard Tools choices
@property (nonatomic, copy) NSArray<NSString *> *fonts;          // Font Overwrite: imported fonts
@end

@implementation LaraViewController

- (instancetype)initWithTool:(LaraTool)tool
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _tool = tool;
        _hudMode = -2;
        _prefStates = [NSMutableDictionary dictionary];
        switch (tool) {
            case LaraToolPerformanceHUD: self.title = @"Performance HUD"; break;
            case LaraToolDebugOverlay:   self.title = @"Debug Overlay"; break;
            case LaraToolUpsideDown:     self.title = @"Upside Down"; break;
            case LaraToolHiddenSettings: self.title = @"Hidden Settings"; break;
            case LaraToolJIT:            self.title = @"JIT Enabler"; break;
            case LaraToolAppLimit:       self.title = @"3-App Limit"; break;
            case LaraToolCards:          self.title = @"Wallet Card Art"; break;
            case LaraToolDecrypt:        self.title = @"App Decrypt"; break;
            case LaraToolSpringBoard:    self.title = @"SpringBoard Tools"; break;
            case LaraToolFonts:          self.title = @"Font Overwrite"; break;
        }
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    if (self.tool == LaraToolPerformanceHUD || self.tool == LaraToolHiddenSettings) [self readState];
    if (self.tool == LaraToolJIT || self.tool == LaraToolAppLimit || self.tool == LaraToolCards ||
        self.tool == LaraToolDecrypt) [self listJITApps];
    if (self.tool == LaraToolFonts) self.fonts = fontow_imported_fonts();
}

#pragma mark Font Overwrite

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return self.tool == LaraToolFonts && indexPath.section == 0 && indexPath.row < (NSInteger)self.fonts.count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete || ![self tableView:tableView canEditRowAtIndexPath:indexPath]) return;
    [NSFileManager.defaultManager removeItemAtPath:self.fonts[indexPath.row] error:nil];
    self.fonts = fontow_imported_fonts();
    [tableView reloadData];
}

- (void)fontsImport
{
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFont ] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    if (self.tool != LaraToolFonts) return;
    NSString *error = nil;
    for (NSURL *url in urls) fontow_import(url, &error);
    self.fonts = fontow_imported_fonts();
    self.status = error;
    [self.tableView reloadData];
}

- (void)fontsChooseTargetFor:(NSString *)fontPath at:(NSIndexPath *)indexPath
{
    unsigned long long fontSize = [NSFileManager.defaultManager attributesOfItemAtPath:fontPath error:nil].fileSize;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:fontPath.lastPathComponent
        message:[NSString stringWithFormat:@"%@. Replace which system font? It has to be the same size or smaller.",
                 [NSByteCountFormatter stringFromByteCount:(long long)fontSize countStyle:NSByteCountFormatterCountStyleFile]]
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (FontOWTarget t = 0; t < FontOWTargetCount; t++) {
        unsigned long long max = fontow_target_size(t);
        if (!max) continue;
        NSString *title = [NSString stringWithFormat:@"%@ (up to %@)", fontow_target_title(t),
                           [NSByteCountFormatter stringFromByteCount:(long long)max countStyle:NSByteCountFormatterCountStyleFile]];
        UIAlertAction *a = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [weakSelf fontsRun:YES target:t font:fontPath];
        }];
        a.enabled = fontSize <= max;
        [sheet addAction:a];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)fontsRun:(BOOL)apply target:(FontOWTarget)target font:(NSString *)fontPath
{
    __block NSString *outcome = nil;
    __weak typeof(self) weakSelf = self;
    [self runNamed:apply ? @"Replacing the font" : @"Restoring the font"
              work:^BOOL{ return apply ? fontow_apply(target, fontPath, &outcome) : fontow_restore(target, &outcome); }
              done:^(BOOL ok) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me.status = outcome ?: (ok ? nil : @"It didn't work. Check the log.");
        if (ok && me.view.window)
            settings_present_respring_prompt(me, @"Respring Now?",
                [NSString stringWithFormat:@"SpringBoard loads the %@ again after a respring. If it keeps crashing afterwards, force-restart the device: the original font comes back.",
                 fontow_target_title(target).lowercaseString]);
    }];
}

// Apps signed with get-task-allow; needs the filesystem sandbox lifted.
- (void)listJITApps
{
    if (self.busy) return;
    self.busy = YES;
    self.status = @"Looking for apps…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    settings_unlock_filesystem_async(NO, ^(BOOL ok, NSString *message) {
        typeof(self) me = weakSelf;
        if (!me) return;
        if (!ok) {
            me.busy = NO;
            BOOL needsRun = [message isEqualToString:kSettingsFullExploitRequiredMessage];
            me.status = needsRun ? kSettingsNoKernelAccessHint : (message ?: @"Filesystem access is not available.");
            [me.tableView reloadData];
            if (needsRun) settings_tool_needs_exploit(me, me.tableView, @"JIT Enabler", ^{ [weakSelf listJITApps]; });
            return;
        }
        BOOL limit = me.tool == LaraToolAppLimit, cards = me.tool == LaraToolCards, decrypt = me.tool == LaraToolDecrypt;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray *apps = decrypt ? app_decrypt_store_apps() : cards ? lara_wallet_cards()
                          : limit ? lara_sideloaded_apps() : lara_jit_candidate_apps();
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) me2 = weakSelf;
                if (!me2) return;
                me2.busy = NO;
                me2.jitApps = apps;
                // Keep a result message set while the list reloaded.
                BOOL placeholder = [me2.status isEqualToString:@"Looking for apps…"];
                me2.status = apps.count ? (placeholder ? nil : me2.status)
                    : decrypt ? @"No App Store apps found."
                    : cards ? @"No cards found in Wallet."
                    : limit ? @"No sideloaded apps found."
                    : @"No app here can get JIT. It only works for apps installed with a development profile (get-task-allow), e.g. sideloaded with a developer certificate.";
                [me2.tableView reloadData];
            });
        });
    });
}

#pragma mark Running

// Runs `work` in SpringBoard; handles busy state, the kernel-access popup and
// errors the same way for every Lara tool.
- (void)runNamed:(NSString *)name work:(BOOL (^)(void))work done:(void (^)(BOOL ok))done
{
    if (self.busy) return;
    self.busy = YES;
    self.status = [name stringByAppendingString:@"…"];
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    settings_springboard_tool_async("Lara", work, ^(BOOL ok, NSString *message) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me.busy = NO;
        if ([message isEqualToString:kSettingsFullExploitRequiredMessage]) {
            me.status = kSettingsNoKernelAccessHint;
            [me.tableView reloadData];
            settings_tool_needs_exploit(me, me.tableView, @"Lara", ^{
                [weakSelf runNamed:name work:work done:done];
            });
            return;
        }
        me.status = ok ? nil : (message ?: @"It didn't work. Check the log.");
        if (done) done(ok);
        [me.tableView reloadData];
    });
}

- (void)readState
{
    __weak typeof(self) weakSelf = self;
    if (self.tool == LaraToolPerformanceHUD) {
        __block int mode = -2;
        [self runNamed:@"Reading" work:^BOOL{
            mode = lara_perf_hud_get_in_session();
            return mode != -2;
        } done:^(BOOL ok) { weakSelf.hudMode = mode; }];
        return;
    }
    NSMutableDictionary *states = [NSMutableDictionary dictionary];
    [self runNamed:@"Reading" work:^BOOL{
        const LaraPrefToggle *t = lara_pref_toggles();
        for (NSInteger i = 0; t[i].title; i++) {
            int v = lara_pref_get_in_session(&t[i]);
            if (v >= 0) states[@(i)] = @(v);
        }
        return YES;
    } done:^(BOOL ok) { [weakSelf.prefStates setDictionary:states]; }];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    if (self.tool == LaraToolFonts) return 2;   // your fonts, system fonts
    // App limit: action, then the apps. Decrypt: finished IPAs, then the apps.
    if (self.tool == LaraToolSpringBoard) return 1 + (NSInteger)[self sbItemCount];   // Apply/Reset, then one per item
    return (self.tool == LaraToolAppLimit || self.tool == LaraToolDecrypt) ? 2 : 1;
}

#pragma mark SpringBoard Tools

- (NSUInteger)sbItemCount
{
    NSUInteger n = 0;
    for (const SBMatItem *item = sbmat_items(); item->key; item++) n++;
    return n;
}

// Item for a table section (section 0 holds Apply and Reset).
- (const SBMatItem *)sbItemForSection:(NSInteger)section
{
    return section >= 1 && (NSUInteger)section <= [self sbItemCount] ? &sbmat_items()[section - 1] : NULL;
}

- (NSMutableDictionary<NSString *, NSDictionary *> *)sbConfig
{
    if (!_sbConfig) {
        NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kSBMatConfigKey];
        _sbConfig = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    }
    return _sbConfig;
}

- (NSDictionary *)sbChoiceFor:(const SBMatItem *)item
{
    NSDictionary *c = self.sbConfig[@(item->key)];
    return [c isKindOfClass:NSDictionary.class] ? c : @{};
}

- (void)sbSet:(id)value forKey:(NSString *)key item:(const SBMatItem *)item
{
    NSMutableDictionary *c = [[self sbChoiceFor:item] mutableCopy];
    c[key] = value;
    self.sbConfig[@(item->key)] = c;
    [NSUserDefaults.standardUserDefaults setObject:self.sbConfig forKey:kSBMatConfigKey];
    settings_sbtools_note(NO);   // due again with the tweaks
}

- (void)sbWithTweaksChanged:(UISwitch *)sw
{
    [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:kSettingsSBToolsWithTweaks];
    if (sw.on) settings_mark_tweak_needs_apply(kSettingsSBToolsWithTweaks);
    settings_sbtools_note(NO);
}

- (UIColor *)sbColorFor:(const SBMatItem *)item
{
    NSArray<NSNumber *> *rgba = [self sbChoiceFor:item][@"color"];
    if (![rgba isKindOfClass:NSArray.class] || rgba.count < 4) return [UIColor colorWithWhite:0 alpha:0.5];
    return [UIColor colorWithRed:rgba[0].doubleValue green:rgba[1].doubleValue blue:rgba[2].doubleValue alpha:rgba[3].doubleValue];
}

- (double)sbBlurFor:(const SBMatItem *)item
{
    NSNumber *blur = [self sbChoiceFor:item][@"blur"];
    return blur ? blur.doubleValue : item->defaultBlur;
}

- (void)sbModeChanged:(UISegmentedControl *)seg
{
    const SBMatItem *item = [self sbItemForSection:seg.tag];
    if (!item) return;
    [self sbSet:@(seg.selectedSegmentIndex) forKey:@"mode" item:item];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:seg.tag] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)sbColorChanged:(UIColorWell *)well
{
    const SBMatItem *item = [self sbItemForSection:well.tag];
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (!item || ![well.selectedColor getRed:&r green:&g blue:&b alpha:&a]) return;
    // Extended sRGB: P3 colors come back below 0 or above 1; CoreMaterial
    // only takes 0…1 (sbmat clamps too).
    CGFloat (^unit)(CGFloat) = ^CGFloat(CGFloat v) { return MIN(MAX(v, 0), 1); };
    [self sbSet:@[ @(unit(r)), @(unit(g)), @(unit(b)), @(unit(a)) ] forKey:@"color" item:item];
}

- (void)sbBlurChanged:(UISlider *)slider
{
    const SBMatItem *item = [self sbItemForSection:slider.tag];
    if (!item) return;
    double blur = round(slider.value);
    [self sbSet:@(blur) forKey:@"blur" item:item];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:slider.tag]];
    UIListContentConfiguration *c = (UIListContentConfiguration *)cell.contentConfiguration;
    if ([c isKindOfClass:UIListContentConfiguration.class]) {
        c.secondaryText = [NSString stringWithFormat:@"%.0f", blur];
        cell.contentConfiguration = c;
    }
}

- (void)sbApply
{
    NSDictionary *config = [self.sbConfig copy];
    __block NSString *why = nil;
    __weak typeof(self) weakSelf = self;
    [self runNamed:@"Applying" work:^BOOL{ return sbmat_apply_in_session(config, &why); }
              done:^(BOOL ok) {
        weakSelf.status = ok ? @"Applied. Open a folder, Control Center or the app switcher to see the rest."
                             : (why ?: @"It didn't work. Check the log.");
        if (ok) settings_sbtools_note(YES);
    }];
}

- (NSUInteger)markedAppCount
{
    NSUInteger n = 0;
    for (NSDictionary *app in self.jitApps) if ([app[@"marked"] intValue] == 1) n++;
    return n;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (self.tool == LaraToolAppLimit) return section == 0 ? (self.jitApps ? 1 : 0) : (NSInteger)self.jitApps.count;
    if (self.tool == LaraToolDecrypt) return section == 0 ? 1 : (NSInteger)self.jitApps.count;
    switch (self.tool) {
        case LaraToolPerformanceHUD: return kLaraHUDModeCount;
        case LaraToolDebugOverlay:
        case LaraToolUpsideDown:     return 1;
        case LaraToolFonts:          return section == 0 ? (NSInteger)self.fonts.count + 1 : FontOWTargetCount;
        case LaraToolSpringBoard: {
            if (section == 0) return 3;   // Apply, Reset All, Apply with Tweaks
            const SBMatItem *item = [self sbItemForSection:section];
            return item && [[self sbChoiceFor:item][@"mode"] integerValue] == SBMatModeColor ? 3 : 1;   // mode, tint, blur
        }
        case LaraToolHiddenSettings: {
            NSInteger n = 0;
            for (const LaraPrefToggle *t = lara_pref_toggles(); t->title; t++) n++;
            return n;
        }
        case LaraToolJIT: return (NSInteger)self.jitApps.count;
        case LaraToolAppLimit: return 0;
        case LaraToolCards: return (NSInteger)self.jitApps.count;
        case LaraToolDecrypt: return 0;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (self.tool == LaraToolFonts) return section == 0 ? @"Your Fonts" : @"System Fonts";
    if (self.tool == LaraToolSpringBoard) {
        const SBMatItem *item = [self sbItemForSection:section];
        return item ? @(item->title) : nil;
    }
    if (section != 1 || !self.jitApps.count) return nil;
    if (self.tool == LaraToolAppLimit) return @"Sideloaded Apps";
    if (self.tool == LaraToolDecrypt) return @"App Store Apps";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section != [self numberOfSectionsInTableView:tableView] - 1) return nil;
    NSString *about = nil;
    switch (self.tool) {
        case LaraToolPerformanceHUD:
            about = @"Core Animation's frame-rate and GPU overlay. Stays on until you turn it off or restart the device.";
            break;
        case LaraToolDebugOverlay:
            about = @"Apple's internal UIKit inspector. After enabling, double-tap the status bar to open it. Lasts until the next respring.";
            break;
        case LaraToolUpsideDown:
            about = @"Lets the Home Screen and Lock Screen rotate to portrait upside down. Lasts until the next respring.";
            break;
        case LaraToolHiddenSettings:
            about = @"Hidden iOS preferences. Most take effect after a respring and stay until you turn them off.";
            break;
        case LaraToolDecrypt:
            about = @"Makes a decrypted IPA of an App Store app on this device, e.g. to inject a tweak into it and sideload it. The app is started in the background and its code is read decrypted from it; app extensions run separately and are left out. IPAs stay on this device (Documents/Decrypted) until you share them. Use it only for apps you own; removing copy protection may be restricted where you live.";
            break;
        case LaraToolCards:
            about = @"Replace the picture of a card in Wallet with your own (cosmetic only). The original is backed up and can be restored. Respring or reopen Wallet to see the change.";
            break;
        case LaraToolAppLimit:
            about = @"With a free Apple ID, iOS allows only 3 sideloaded apps: installd marks each one, and only marked apps count. Removing the marks frees the slots. Run it again after installing or refreshing (re-signing) an app, which marks it again.";
            break;
        case LaraToolSpringBoard:
            about = @"Changes the material behind the dock, folders, Control Center, notification banners and the app switcher: Apple's (Visible), your own tint and blur (Color), or none (Disabled). Tap Apply after changing something. It works in SpringBoard's memory, so a respring undoes it: apply again after one.\n\nNotification Banners: on the Lock Screen, iOS draws notifications as one shared blur cut into rounded shapes. With Color they drop out of it and show square there (with lara's files too); banners elsewhere stay rounded.\n\nControl Center Blur: with Color, Control Center's own uncolored blur shows for a moment while it closes; iOS fades it separately.";
            break;
        case LaraToolFonts:
            about = @"Replaces a system font in memory: nothing on the sealed system volume changes, and a restart always brings the original back; Restore does it without one (the original is backed up first). Import a .ttf, .otf or .ttc from Files, tap it and pick the font to replace; it has to be the same size or smaller. A plain font is adapted to the system font on the device first (its weights and names, as lara's font patcher does; kerning is dropped if it has to be scaled). Fonts with PostScript (CFF) outlines can't be adapted. Lock Screen Clock changes every clock style at once; the weight slider has no effect on the new font. If SpringBoard keeps crashing after the respring, force-restart the device.";
            break;
        case LaraToolJIT:
            about = @"Tap an app to open it with JIT (for emulators and similar apps). Only apps signed with a development profile can get it. JIT lasts until the app quits; some apps can't tell it's on.";
            break;
    }
    NSMutableArray *parts = [NSMutableArray array];
    if (self.status) [parts addObject:self.status];
    [parts addObject:about];
    [parts addObject:kLaraCredit];
    return [parts componentsJoinedByString:@"\n\n"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    switch (self.tool) {
        case LaraToolPerformanceHUD: {
            LaraHUDMode m = kLaraHUDModes[indexPath.row];
            c.text = [NSString stringWithUTF8String:m.title];
            if (m.mode == self.hudMode) cell.accessoryType = UITableViewCellAccessoryCheckmark;
            break;
        }
        case LaraToolDebugOverlay:
            c.text = @"Enable Debug Overlay";
            c.textProperties.color = self.busy ? UIColor.secondaryLabelColor : UIColor.systemBlueColor;
            break;
        case LaraToolUpsideDown:
            c.text = @"Enable Upside Down";
            c.textProperties.color = self.busy ? UIColor.secondaryLabelColor : UIColor.systemBlueColor;
            break;
        case LaraToolFonts: {
            if (indexPath.section == 0 && indexPath.row == (NSInteger)self.fonts.count) {
                c.text = @"Import Font…";
                c.image = [UIImage systemImageNamed:@"plus.circle.fill"];
                c.textProperties.color = self.busy ? UIColor.secondaryLabelColor : UIColor.systemBlueColor;
                break;
            }
            if (indexPath.section == 0) {
                NSString *font = self.fonts[indexPath.row];
                c.text = font.lastPathComponent.stringByDeletingPathExtension;
                c.secondaryText = [NSByteCountFormatter stringFromByteCount:
                    (long long)[NSFileManager.defaultManager attributesOfItemAtPath:font error:nil].fileSize
                    countStyle:NSByteCountFormatterCountStyleFile];
                c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
                c.image = [UIImage systemImageNamed:@"textformat"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            }
            FontOWTarget t = (FontOWTarget)indexPath.row;
            bool replaced = fontow_is_replaced(t);
            c.text = fontow_target_title(t);
            c.secondaryText = !fontow_target_size(t) ? @"Not on this iOS version"
                            : replaced ? @"Replaced — tap to restore the original" : @"Original";
            c.secondaryTextProperties.color = replaced ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
            if (!replaced) cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case LaraToolSpringBoard: {
            if (indexPath.section == 0 && indexPath.row == 2) {
                c.text = @"Apply with Tweaks";
                c.secondaryText = @"Applies this look in every Apply Tweaks run too, e.g. after a respring.";
                c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
                UISwitch *sw = [UISwitch new];
                sw.on = [NSUserDefaults.standardUserDefaults boolForKey:kSettingsSBToolsWithTweaks];
                [sw addTarget:self action:@selector(sbWithTweaksChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = sw;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            }
            if (indexPath.section == 0) {
                c.text = indexPath.row == 0 ? @"Apply" : @"Reset All";
                c.textProperties.color = self.busy ? UIColor.secondaryLabelColor
                                       : indexPath.row == 0 ? UIColor.systemBlueColor : UIColor.systemRedColor;
                break;
            }
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            const SBMatItem *item = [self sbItemForSection:indexPath.section];
            if (!item) break;
            if (indexPath.row == 0) {
                UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[ @"Visible", @"Color", @"Disabled" ]];
                seg.selectedSegmentIndex = MIN(MAX([[self sbChoiceFor:item][@"mode"] integerValue], 0), 2);
                seg.tag = indexPath.section;
                seg.enabled = !self.busy;
                [seg addTarget:self action:@selector(sbModeChanged:) forControlEvents:UIControlEventValueChanged];
                seg.translatesAutoresizingMaskIntoConstraints = NO;
                [cell.contentView addSubview:seg];
                UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
                [NSLayoutConstraint activateConstraints:@[
                    [seg.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
                    [seg.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
                    [seg.topAnchor constraintEqualToAnchor:m.topAnchor],
                    [seg.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
                ]];
                cell.imageView.image = nil;
                return cell;
            }
            if (indexPath.row == 1) {
                c.text = @"Tint";
                UIColorWell *well = [UIColorWell new];
                well.supportsAlpha = YES;
                well.selectedColor = [self sbColorFor:item];
                well.tag = indexPath.section;
                [well addTarget:self action:@selector(sbColorChanged:) forControlEvents:UIControlEventValueChanged];
                [well sizeToFit];
                cell.accessoryView = well;
            } else {
                c.text = @"Blur";
                c.secondaryText = [NSString stringWithFormat:@"%.0f", [self sbBlurFor:item]];
                c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
                UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 180, 30)];
                slider.minimumValue = 0;
                slider.maximumValue = 60;
                slider.value = (float)[self sbBlurFor:item];
                slider.tag = indexPath.section;
                [slider addTarget:self action:@selector(sbBlurChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = slider;
            }
            break;
        }
        case LaraToolHiddenSettings: {
            const LaraPrefToggle *t = &lara_pref_toggles()[indexPath.row];
            c.text = [NSString stringWithUTF8String:t->title];
            c.secondaryText = [NSString stringWithUTF8String:t->detail];
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            UISwitch *sw = [UISwitch new];
            NSNumber *state = self.prefStates[@(indexPath.row)];
            sw.on = state.boolValue;
            sw.enabled = !self.busy && state != nil;
            sw.tag = indexPath.row;
            [sw addTarget:self action:@selector(prefSwitched:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case LaraToolDecrypt: {
            if (indexPath.section == 0) {
                NSUInteger n = 0;
                for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:app_decrypt_output_dir() error:nil])
                    if ([f.pathExtension isEqualToString:@"ipa"]) n++;
                c.text = @"Decrypted IPAs";
                c.secondaryText = n ? [NSString stringWithFormat:@"%lu IPA%@ — open to share or delete", (unsigned long)n, n == 1 ? @"" : @"s"]
                                    : @"None yet";
                c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
                c.image = [UIImage systemImageNamed:@"shippingbox.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            }
            NSDictionary *app = self.jitApps[indexPath.row];
            c.text = app[@"name"];
            c.secondaryText = [NSString stringWithFormat:@"%@ · %@", app[@"bundleID"], app[@"version"]];
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            c.image = app[@"icon"] ?: [UIImage systemImageNamed:@"app.dashed"];
            c.imageProperties.maximumSize = CGSizeMake(36, 36);
            c.imageProperties.cornerRadius = 8;
            break;
        }
        case LaraToolCards: {
            NSDictionary *card = self.jitApps[indexPath.row];
            c.text = card[@"name"];
            c.secondaryText = [card[@"hasBackup"] boolValue] ? @"Custom image — tap to change or restore" : @"Original image";
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            c.image = card[@"preview"] ?: [UIImage systemImageNamed:@"creditcard"];
            c.imageProperties.maximumSize = CGSizeMake(64, 41);
            c.imageProperties.cornerRadius = 4;
            break;
        }
        case LaraToolAppLimit: {
            if (indexPath.section == 0) {
                NSUInteger marked = [self markedAppCount];
                c.text = marked ? [NSString stringWithFormat:@"Remove Limit Marks (%lu)", (unsigned long)marked]
                                : @"No App Counts Toward the Limit";
                c.textProperties.color = (marked && !self.busy) ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
                break;
            }
            NSDictionary *app = self.jitApps[indexPath.row];
            int marked = [app[@"marked"] intValue];
            c.text = app[@"name"];
            c.secondaryText = marked == 1 ? @"Counts toward the limit" : marked == 0 ? @"Not counted" : @"Unknown";
            c.secondaryTextProperties.color = marked == 1 ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
            c.image = app[@"icon"] ?: [UIImage systemImageNamed:@"app.dashed"];
            c.imageProperties.maximumSize = CGSizeMake(36, 36);
            c.imageProperties.cornerRadius = 8;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case LaraToolJIT: {
            NSDictionary *app = self.jitApps[indexPath.row];
            c.text = app[@"name"];
            c.secondaryText = app[@"bundleID"];
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            c.image = app[@"icon"] ?: [UIImage systemImageNamed:@"app.dashed"];
            c.imageProperties.maximumSize = CGSizeMake(36, 36);
            c.imageProperties.cornerRadius = 8;
            break;
        }
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.busy) return;
    __weak typeof(self) weakSelf = self;
    switch (self.tool) {
        case LaraToolPerformanceHUD: {
            int mode = kLaraHUDModes[indexPath.row].mode;
            [self runNamed:@"Setting the HUD" work:^BOOL{ return lara_perf_hud_set_in_session(mode); }
                      done:^(BOOL ok) { if (ok) weakSelf.hudMode = mode; }];
            break;
        }
        case LaraToolDebugOverlay: {
            CGRect screen = self.view.window.windowScene.screen.bounds;   // UIKit: read here, on main
            [self runNamed:@"Enabling" work:^BOOL{ return lara_debug_overlay_enable_in_session(screen); }
                      done:^(BOOL ok) { if (ok) weakSelf.status = @"Enabled. Double-tap the status bar."; }];
            break;
        }
        case LaraToolUpsideDown: {
            [self runNamed:@"Enabling" work:^BOOL{ return lara_upside_down_enable_in_session(); }
                      done:^(BOOL ok) { if (ok) weakSelf.status = @"Enabled. Turn the device upside down."; }];
            break;
        }
        case LaraToolSpringBoard:
            if (indexPath.section != 0 || indexPath.row == 2) break;
            if (indexPath.row == 1) {
                [self.sbConfig removeAllObjects];
                [NSUserDefaults.standardUserDefaults removeObjectForKey:kSBMatConfigKey];
                [self.tableView reloadData];
            }
            [self sbApply];
            break;
        case LaraToolFonts:
            if (indexPath.section == 0) {
                if (indexPath.row == (NSInteger)self.fonts.count) [self fontsImport];
                else [self fontsChooseTargetFor:self.fonts[indexPath.row] at:indexPath];
            } else if (fontow_is_replaced((FontOWTarget)indexPath.row)) {
                [self fontsRun:NO target:(FontOWTarget)indexPath.row font:nil];
            }
            break;
        case LaraToolHiddenSettings:
            break;
        case LaraToolAppLimit:
            if (indexPath.section == 0 && [self markedAppCount] > 0) [self removeLimitMarks];
            break;
        case LaraToolCards:
            [self cardTapped:self.jitApps[indexPath.row] at:indexPath];
            break;
        case LaraToolDecrypt:
            if (indexPath.section == 0) {
                [self.navigationController pushViewController:[[FileBrowserViewController alloc] initWithPath:app_decrypt_output_dir()]
                                                     animated:YES];
            } else {
                [self confirmDecrypt:self.jitApps[indexPath.row]];
            }
            break;
        case LaraToolJIT: {
            NSDictionary *app = self.jitApps[indexPath.row];
            NSString *bid = app[@"bundleID"], *name = app[@"name"];
            __block int err = 0;
            [self runNamed:[NSString stringWithFormat:@"Opening %@ with JIT", name]
                      work:^BOOL{ err = lara_jit_enable_in_session(bid); return err == 0; }
                      done:^(BOOL ok) {
                weakSelf.status = ok ? [NSString stringWithFormat:@"JIT is on for %@ until it quits.", name]
                    : err == ESRCH ? [NSString stringWithFormat:@"%@ didn't start. Open it once, then try again.", name]
                    : err == EPERM ? [NSString stringWithFormat:@"iOS refused to attach to %@. It needs a development profile (get-task-allow).", name]
                    : [NSString stringWithFormat:@"JIT couldn't be enabled for %@ (error %d). Check the log.", name, err];
            }];
            break;
        }
    }
}

#pragma mark App decrypt

- (void)confirmDecrypt:(NSDictionary *)app
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Decrypt %@?", app[@"name"]]
        message:@"Makes a decrypted IPA of this app for your own use (e.g. tweak injection and sideloading). It can take a while for large apps; keep Cyanide open.\n\nOptional: set a custom bundle ID to install it alongside the original. You must re-sign the IPA for that ID."
        preferredStyle:UIAlertControllerStyleAlert];
    __block UITextField *bundleField = nil;
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        bundleField = tf;
        tf.placeholder = app[@"bundleID"];
        tf.text = nil;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.spellCheckingType = UITextSpellCheckingTypeNo;
        tf.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightRegular];
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Decrypt" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *custom = [bundleField.text stringByTrimmingCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (custom.length && ![weakSelf isValidBundleID:custom]) {
            UIAlertController *bad = [UIAlertController
                alertControllerWithTitle:@"Invalid Bundle ID"
                                 message:@"Use a reverse-DNS identifier such as com.example.app."
                          preferredStyle:UIAlertControllerStyleAlert];
            [bad addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:bad animated:YES completion:nil];
            return;
        }
        if (custom.length && [custom isEqualToString:app[@"bundleID"]]) custom = nil;
        [weakSelf decrypt:app customBundleID:custom.length ? custom : nil];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (BOOL)isValidBundleID:(NSString *)bundleID
{
    if (bundleID.length == 0 || bundleID.length > 155) return NO;
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$"
                                                          options:0 error:nil];
    });
    return [regex numberOfMatchesInString:bundleID options:0
                                    range:NSMakeRange(0, bundleID.length)] == 1;
}


- (void)decrypt:(NSDictionary *)app customBundleID:(NSString *)customBundleID
{
    if (self.busy) return;
    self.busy = YES;
    self.status = [NSString stringWithFormat:@"Decrypting %@…", app[@"name"]];
    // Show the progress where it's visible (the footer is below the list).
    self.navigationItem.prompt = self.status;
    [self showProgressBar];
    [self.tableView reloadData];
    // A large app takes a while: keep going for a bit if Cyanide is backgrounded.
    __block UIBackgroundTaskIdentifier bg = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Decrypt" expirationHandler:^{
        [UIApplication.sharedApplication endBackgroundTask:bg];
        bg = UIBackgroundTaskInvalid;
    }];
    __weak typeof(self) weakSelf = self;
    __block NSString *ipa = nil, *error = nil;
    __block CFAbsoluteTime lastUI = 0;
    void (^progress)(NSString *, double) = ^(NSString *step, double fraction) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastUI < 0.25 && fraction < 1) return;   // don't flood the main queue
        lastUI = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.status = [NSString stringWithFormat:@"%@ — %.0f %%", step, fraction * 100];
            weakSelf.navigationItem.prompt = [NSString stringWithFormat:@"%.0f %% · %@", fraction * 100, step];
            // Never backwards: retries restart a step at a lower fraction.
            UIProgressView *bar = weakSelf.progressBar;
            if (fraction > bar.progress) [bar setProgress:(float)fraction animated:YES];
        });
    };
    // Inside a SpringBoard session: when iOS won't decrypt in Cyanide,
    // SpringBoard does it (same kernel-access rules as the other tools).
    settings_springboard_tool_async("App Decrypt", ^BOOL{
        ipa = app_decrypt_make_ipa(app, YES, customBundleID, progress, &error);
        return ipa != nil;
    }, ^(BOOL ok, NSString *message) {
        if (bg != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; }
        typeof(self) me = weakSelf;
        if (!me) return;
        me.busy = NO;
        me.navigationItem.prompt = nil;
        [me.progressBar removeFromSuperview];
        me.progressBar = nil;
        if ([message isEqualToString:kSettingsFullExploitRequiredMessage]) {
            me.status = kSettingsNoKernelAccessHint;
            [me.tableView reloadData];
            settings_tool_needs_exploit(me, me.tableView, @"App Decrypt", ^{ [weakSelf decrypt:app customBundleID:customBundleID]; });
            return;
        }
        NSString *failure = error ?: message ?: @"Decryption failed. Check the log.";
        me.status = ipa ? [NSString stringWithFormat:@"Saved %@.", ipa.lastPathComponent] : failure;
        [me.tableView reloadData];
        if (!me.view.window) return;
        // An alert, not just the footer: that is below the whole app list.
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:ipa ? @"IPA Ready" : @"Decryption Failed"
                             message:ipa ? [NSString stringWithFormat:@"%@ is saved in Decrypted IPAs.%@%@", ipa.lastPathComponent,
                                            customBundleID.length ? [NSString stringWithFormat:@"\n\nCustom bundle ID: %@. Re-sign the IPA with a profile for that ID before installing.", customBundleID] : @"",
                                            error.length ? [@"\n\n" stringByAppendingString:error] : @""] : failure
                      preferredStyle:UIAlertControllerStyleAlert];
        if (ipa) {
            NSString *path = ipa;
            [ac addAction:[UIAlertAction actionWithTitle:@"Share…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                typeof(self) me2 = weakSelf;
                UITableViewCell *cell = [me2.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
                if (me2) filebrowser_share_file(me2, path, NO, nil, cell, nil);
            }]];
        }
        [ac addAction:[UIAlertAction actionWithTitle:ipa ? @"Done" : @"OK" style:UIAlertActionStyleCancel handler:nil]];
        [me presentViewController:ac animated:YES completion:nil];
    });
}

- (void)showProgressBar
{
    [self.progressBar removeFromSuperview];
    UINavigationBar *navBar = self.navigationController.navigationBar;
    if (!navBar) return;
    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [navBar addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:navBar.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:navBar.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:navBar.bottomAnchor],
    ]];
    self.progressBar = bar;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    // The bar lives on the shared navigation bar: don't leave it on other screens.
    self.progressBar.hidden = YES;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.progressBar.hidden = NO;
}

#pragma mark Wallet card art

- (void)cardTapped:(NSDictionary *)card at:(NSIndexPath *)indexPath
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:card[@"name"] message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Choose Image…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf pickImageForCard:card];
    }]];
    if ([card[@"hasBackup"] boolValue]) {
        [ac addAction:[UIAlertAction actionWithTitle:@"Restore Original" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            NSString *err = nil;
            BOOL ok = lara_wallet_card_restore(card, &err);
            // Result after the reload starts: listJITApps puts its own
            // "Looking for apps…" placeholder in status, and only a message
            // set after that survives the reload. Set first, as it was, the
            // result -- an error included -- was never shown.
            [weakSelf listJITApps];
            weakSelf.status = ok ? @"Original restored. Respring or reopen Wallet to see it." : err;
            [weakSelf.tableView reloadData];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    ac.popoverPresentationController.sourceView = cell ?: self.view;
    ac.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)pickImageForCard:(NSDictionary *)card
{
    self.pickingCard = card;
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = PHPickerFilter.imagesFilter;
    cfg.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results
{
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSDictionary *card = self.pickingCard;
    self.pickingCard = nil;
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (!card || ![provider canLoadObjectOfClass:UIImage.class]) return;
    __weak typeof(self) weakSelf = self;
    [provider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([object isKindOfClass:UIImage.class]) [weakSelf applyImage:(UIImage *)object toCard:card];
        });
    }];
}

// Scales the picture to fill the original card image (same pixel size, so
// Wallet lays it out exactly like the original), then writes it.
- (void)applyImage:(UIImage *)picked toCard:(NSDictionary *)card
{
    UIImage *original = [UIImage imageWithContentsOfFile:card[@"imagePath"]];
    CGSize px = original ? CGSizeMake(original.size.width * original.scale, original.size.height * original.scale)
                         : CGSizeMake(1536, 969);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 1;
    fmt.opaque = YES;
    UIImage *scaled = [[[UIGraphicsImageRenderer alloc] initWithSize:px format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGFloat k = MAX(px.width / picked.size.width, px.height / picked.size.height);
        CGSize s = CGSizeMake(picked.size.width * k, picked.size.height * k);
        [picked drawInRect:CGRectMake((px.width - s.width) / 2, (px.height - s.height) / 2, s.width, s.height)];
    }];
    NSString *err = nil;
    BOOL ok = lara_wallet_card_set_image(card, UIImagePNGRepresentation(scaled), &err);
    [self listJITApps];   // then the result: see the Restore Original handler
    self.status = ok ? @"Card image replaced. Respring or reopen Wallet to see it." : err;
    [self.tableView reloadData];
}

// Removes installd's free-profile mark from every counted app, as root
// through launchd (the bundles stay owned by installd), then rescans.
- (void)removeLimitMarks
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSDictionary *app in self.jitApps) if ([app[@"marked"] intValue] == 1) [paths addObject:app[@"path"]];
    if (!paths.count || self.busy) return;
    self.busy = YES;
    self.status = @"Removing the marks…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger done = 0;
        NSString *lastError = nil;
        for (NSString *path in paths) {
            NSString *err = nil;
            if (settings_root_remove_xattr(path, kLaraFreeProfileXattr, &err)) done++;
            else lastError = err;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) me = weakSelf;
            if (!me) return;
            me.busy = NO;
            [me listJITApps];
            me.status = done == paths.count
                ? [NSString stringWithFormat:@"Removed the mark from %lu app%@.", (unsigned long)done, done == 1 ? @"" : @"s"]
                : [NSString stringWithFormat:@"Removed %lu of %lu: %@", (unsigned long)done, (unsigned long)paths.count,
                                             lastError ?: @"see the log"];
        });
    });
}

- (void)prefSwitched:(UISwitch *)sw
{
    NSInteger index = sw.tag;
    BOOL on = sw.isOn;
    const LaraPrefToggle *t = &lara_pref_toggles()[index];
    __weak typeof(self) weakSelf = self;
    [self runNamed:@"Saving" work:^BOOL{ return lara_pref_set_in_session(t, on); }
              done:^(BOOL ok) {
        typeof(self) me = weakSelf;
        if (ok) {
            me.prefStates[@(index)] = @(on);
            me.status = @"Saved. Respring to apply.";
        }
    }];
}

@end
