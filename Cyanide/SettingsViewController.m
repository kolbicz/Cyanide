//
//  SettingsViewController.m
//  Cyanide
//

#import "SettingsViewController.h"
#import "FileBrowserViewController.h"
#import <dirent.h>
#import <fcntl.h>
#import <sys/stat.h>
#import "AppDelegate.h"   // round 31: cyanide_launch_trace
#import "VPhoneDebug.h"
#import "kexploit/kexploit_opa334.h"
#import "kexploit/offsets.h"
#import "kexploit/krw.h"
#import "tweaks/sbcustomizer.h"
#import "tweaks/location_services.h"
#import "tweaks/app_switcher.h"
#import "tweaks/powercuff.h"
#import "tweaks/statbar.h"
#import "tweaks/experimental_tweaks.h"
#import "tweaks/nsbar.h"
#import "tweaks/nicebarlite.h"
#import "tweaks/axonlite.h"
#import "tweaks/darksword_tweaks.h"
#import "tweaks/darksword_drag.h"
#import "tweaks/darksword_ota.h"
#import "tweaks/darksword_layout.h"
#import "tweaks/nano_registry.h"
#import "tweaks/killallapps.h"
#import "tweaks/themer.h"
#import "tweaks/snowboardlite.h"
#import "tweaks/passcode_theme.h"
#import "tweaks/livewp.h"
#import "tweaks/gravitylite.h"
#import "tweaks/appswitchergrid.h"
#import "tweaks/hide_home_bar.h"
#import "tweaks/QuickLoader.h"
#import "tweaks/RepoTweaks.h"
#import <CoreMotion/CoreMotion.h>

#import <objc/runtime.h>
#import <objc/objc-sync.h>
#import <sys/time.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <errno.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/host_info.h>
#import "DSKeepAlive.h"
#import "TaskRop/RemoteCall.h"
#import "TaskRop/Exception.h"   // round 21: excport lifecycle gate
#import "kexploit/kutils.h"
#import "utils/process.h"
#import "LogViewController.h"
#import "kexploit/persistence.h"
#import "kexploit/machine_info.h"
#import "tweaks/remote_objc.h"
#import "installer/CYIconBadge.h"
#import "installer/InstallProgressViewController.h"
#import "installer/Package.h"
#import "installer/PackageCatalog.h"
#import "installer/PackageQueue.h"
#import "installer/MainTabBarController.h"
#import "docs/DocsViewController.h"
#import "UpdateChecker.h"
#import "SBLArchiveExtractor.h"
#import "NiceBarSettingsSupport.h"
#import <WebKit/WebKit.h>
#import <MessageUI/MessageUI.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Security/Security.h>
#import <notify.h>
#import <float.h>
#import <math.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <time.h>
#import <unistd.h>
#import <stdlib.h>




// Helper converting "#FF0000" in UIColor
static UIColor *colorFromHexString(NSString *hexString) {
    if (![hexString isKindOfClass:NSString.class]) return [UIColor blackColor];
    NSString *cleanString = [hexString stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (cleanString.length == 0) return [UIColor blackColor];

    unsigned rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:cleanString];
    [scanner scanHexInt:&rgbValue];

    return [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0
                           green:((rgbValue & 0xFF00) >> 8)/255.0
                            blue:(rgbValue & 0xFF)/255.0 alpha:1.0];
}

// Helper converting UIColor in "#FF0000"
static NSString *hexStringFromColor(UIColor *color) {
    if (![color isKindOfClass:UIColor.class]) return @"#000000";
    const CGFloat *components = CGColorGetComponents(color.CGColor);
    size_t count = CGColorGetNumberOfComponents(color.CGColor);

    if (count == 4) { // RGB
        return [NSString stringWithFormat:@"#%02lX%02lX%02lX",
                lroundf(components[0] * 255.0),
                lroundf(components[1] * 255.0),
                lroundf(components[2] * 255.0)];
    }
    return @"#000000"; // Fallback
}

static NSString *settings_string_or_empty(id value)
{
    return [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
}

static BOOL settings_js_identifier_valid(NSString *name)
{
    if (![name isKindOfClass:NSString.class] || name.length == 0) return NO;
    unichar first = [name characterAtIndex:0];
    if (![[NSCharacterSet letterCharacterSet] characterIsMember:first] && first != '_' && first != '$') return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$"];
    return [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSString *settings_js_string_literal(NSString *value)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value ?: @""]
                                                   options:0
                                                     error:nil];
    NSString *arrayLiteral = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (arrayLiteral.length >= 2 && [arrayLiteral hasPrefix:@"["] && [arrayLiteral hasSuffix:@"]"]) {
        return [arrayLiteral substringWithRange:NSMakeRange(1, arrayLiteral.length - 2)];
    }
    return @"\"\"";
}

static NSString *settings_js_number_literal(NSString *value)
{
    double number = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
    if (!isfinite(number)) number = 0.0;
    return [NSString stringWithFormat:@"%.12g", number];
}

static NSMutableDictionary *settings_string_values_dictionary(id raw)
{
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (![raw isKindOfClass:NSDictionary.class]) return out;
    [(NSDictionary *)raw enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        (void)stop;
        if ([key isKindOfClass:NSString.class] && [obj isKindOfClass:NSString.class]) {
            out[key] = obj;
        }
    }];
    return out;
}

static void settings_clear_repo_tweak_defaults(NSString *repoURL, NSString *tweakID)
{
    if (![repoURL isKindOfClass:NSString.class] || repoURL.length == 0 ||
        ![tweakID isKindOfClass:NSString.class] || tweakID.length == 0) {
        return;
    }
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:repotweaks_enabled_defaults_key(repoURL, tweakID)];
    [d removeObjectForKey:repotweaks_script_defaults_key(repoURL, tweakID)];
    [d removeObjectForKey:repotweaks_values_defaults_key(repoURL, tweakID)];
    [d synchronize];
    repotweaks_cancel_tweak(repoURL, tweakID);
}

static NSDictionary *settings_repotweaks_caches(void)
{
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:@"RepoTweaksCaches"];
    return [raw isKindOfClass:NSDictionary.class] ? (NSDictionary *)raw : @{};
}

static NSString * const kSettingsDefaultRepoURL = @"https://raw.githubusercontent.com/MinePlayer16/MinePlayer16.github.io/refs/heads/main/repotweaks.json";

static NSArray<NSString *> *settings_repotweaks_urls(void)
{
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:@"RepoTweaksURLs"];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    for (id value in (NSArray *)raw) {
        if ([value isKindOfClass:NSString.class]) [urls addObject:value];
    }
    return urls;
}

static NSDictionary *settings_repotweaks_repo_for_url(NSString *repoURL)
{
    id repo = repoURL.length ? settings_repotweaks_caches()[repoURL] : nil;
    return [repo isKindOfClass:NSDictionary.class] ? (NSDictionary *)repo : @{};
}

static NSArray<NSDictionary *> *settings_repotweaks_tweaks_for_url(NSString *repoURL)
{
    id raw = settings_repotweaks_repo_for_url(repoURL)[@"tweaks"];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (id value in (NSArray *)raw) {
        if ([value isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *tweak = [(NSDictionary *)value mutableCopy];
            if ([repoURL isKindOfClass:NSString.class] && repoURL.length > 0) {
                tweak[@"_repoURL"] = repoURL;
            }
            [out addObject:tweak];
        }
    }
    return out;
}



// =============================================================================
// REPOTWEAKS: Details and Dynamic parameters window
// =============================================================================
@interface RepoTweakDetailController : UITableViewController
@property (nonatomic, strong) NSDictionary *tweak;
@property (nonatomic, strong) NSString *tweakID;
@property (nonatomic, strong) NSString *repoURL;
@property (nonatomic, strong) NSString *rawScript;
@property (nonatomic, strong) NSArray<NSDictionary *> *params;
@property (nonatomic, strong) NSMutableDictionary *values;
@end

@implementation RepoTweakDetailController

- (instancetype)initWithTweak:(NSDictionary *)tweak {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        self.tweak = [tweak isKindOfClass:NSDictionary.class] ? tweak : @{};
        self.tweakID = settings_string_or_empty(self.tweak[@"id"]);
        self.repoURL = settings_string_or_empty(self.tweak[@"_repoURL"]);
        self.title = settings_string_or_empty(self.tweak[@"name"]).length ? settings_string_or_empty(self.tweak[@"name"]) : @"RepoTweak";

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        // Retrieve js code from repo
        NSString *scriptKey = repotweaks_script_defaults_key(self.repoURL, self.tweakID);
        self.rawScript = [d stringForKey:scriptKey] ?: @"";

        // Retrieve tweaks-specific user saved settings
        NSString *valuesKey = repotweaks_values_defaults_key(self.repoURL, self.tweakID);
        self.values = settings_string_values_dictionary([d dictionaryForKey:valuesKey]);

        // Analyze @param comments in js code
        NSMutableArray *parsedParams = [NSMutableArray array];
        NSArray *lines = [self.rawScript componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            if ([line containsString:@"@param:"]) {
                NSArray *parts = [line componentsSeparatedByString:@"|"];
                if (parts.count >= 4) {
                    NSArray *typeParts = [parts[0] componentsSeparatedByString:@"@param:"];
                    if (typeParts.count < 2) continue;
                    NSString *rawType = typeParts[1];
                    NSString *type = [rawType stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *varName = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *label = [parts[2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *defValue = [parts[3] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (!settings_js_identifier_valid(varName)) continue;

                    NSMutableDictionary *paramDict = [@{@"type": type, @"varName": varName, @"label": label, @"default": defValue} mutableCopy];
                    if (parts.count >= 5 && ([type isEqualToString:@"slider"] || [type isEqualToString:@"number"])) {
                        NSString *rangeStr = [parts[4] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        NSArray *rangeParts = [rangeStr componentsSeparatedByString:@"-"];
                        if (rangeParts.count == 2) {
                            paramDict[@"min"] = rangeParts[0];
                            paramDict[@"max"] = rangeParts[1];
                        }
                    }
                    [parsedParams addObject:paramDict];
                    if (!self.values[varName]) {
                        self.values[varName] = defValue; //default values if new
                    }
                }
            }
        }
        self.params = parsedParams;
    }
    return self;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.params.count > 0 ? 3 : 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2; //description and version
    if (section == 1) return 1; //status (active or not)
    return self.params.count;   //JS dynamic parameters
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section == 0) return CYSectionHeaderView(@"Tweak Infos");
    if (section == 1) return CYSectionHeaderView(@"Tweak Status");
    return CYSectionHeaderView(@"Personalization Options");
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return 46.0; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"info-cell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Description";
            cell.detailTextLabel.text = settings_string_or_empty(self.tweak[@"description"]);
            cell.detailTextLabel.numberOfLines = 0;
        } else {
            cell.textLabel.text = @"Version";
            cell.detailTextLabel.text = settings_string_or_empty(self.tweak[@"version"]);
        }
        return cell;
    }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"toggle-cell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = @"Enable Tweak";

        UISwitch *sw = [[UISwitch alloc] init];
        NSString *toggleKey = repotweaks_enabled_defaults_key(self.repoURL, self.tweakID);
        sw.on = [d boolForKey:toggleKey];

        UIAction *action = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            [d setBool:sw.isOn forKey:toggleKey];
            [d synchronize];
            if (!sw.isOn) {
                repotweaks_cancel_tweak(self.repoURL, self.tweakID);
            }
        }];
        [sw addAction:action forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    // Dynamic parameters section (same as QuickLoader)
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"param-cell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    NSDictionary *param = self.params[indexPath.row];
    cell.textLabel.text = param[@"label"];

    NSString *varName = param[@"varName"];
    NSString *pType = param[@"type"];
    NSString *currentValue = settings_string_or_empty(self.values[varName]);

    NSString *valuesKey = repotweaks_values_defaults_key(self.repoURL, self.tweakID);

    if ([pType isEqualToString:@"switch"]) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [currentValue isEqualToString:@"true"];
        UIAction *action = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            self.values[varName] = sw.isOn ? @"true" : @"false";
            [d setObject:self.values forKey:valuesKey];
            [d synchronize];
        }];
        [sw addAction:action forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }
    else if ([pType isEqualToString:@"text"]) {
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 150, 30)];
        tf.textAlignment = NSTextAlignmentRight;
        tf.textColor = UIColor.secondaryLabelColor;
        tf.text = currentValue;
        UIAction *action = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            self.values[varName] = tf.text;
            [d setObject:self.values forKey:valuesKey];
            [d synchronize];
        }];
        [tf addAction:action forControlEvents:UIControlEventEditingChanged];
        cell.accessoryView = tf;
    }
    else if ([pType isEqualToString:@"color"]) {
        UIColorWell *colorWell = [[UIColorWell alloc] init];
        colorWell.translatesAutoresizingMaskIntoConstraints = NO;
        //call to convert color
        colorWell.selectedColor = colorFromHexString(currentValue ?: @"#FF0000");

        UIAction *action = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            colorWell.title = param[@"label"];
            self.values[varName] = hexStringFromColor(colorWell.selectedColor);
            [d setObject:self.values forKey:valuesKey];
            [d synchronize];
        }];
        [colorWell addAction:action forControlEvents:UIControlEventValueChanged];

        [cell.contentView addSubview:colorWell];
        [NSLayoutConstraint activateConstraints:@[
            [colorWell.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [colorWell.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [colorWell.widthAnchor constraintEqualToConstant:32.0],
            [colorWell.heightAnchor constraintEqualToConstant:32.0]
        ]];
    }
    else if ([pType isEqualToString:@"slider"] || [pType isEqualToString:@"number"]) {
        UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, 220, 30)];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.spacing = 10;
        stack.alignment = UIStackViewAlignmentCenter;

        UISlider *slider = [[UISlider alloc] init];
        slider.minimumValue = param[@"min"] ? [param[@"min"] floatValue] : 0.0;
        slider.maximumValue = param[@"max"] ? [param[@"max"] floatValue] : 1.0;

        //if there is none, retrieve default value
        float defVal = param[@"default"] ? [param[@"default"] floatValue] : slider.minimumValue;
        slider.value = currentValue ? [currentValue floatValue] : defVal;

        UILabel *valLabel = [[UILabel alloc] init];
        valLabel.textColor = [UIColor secondaryLabelColor];
        valLabel.font = [UIFont systemFontOfSize:14];
        [valLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        void (^updateLabelText)(float) = ^(float value) {
            if (fabs(value - defVal) < 0.01) {
                valLabel.text = [NSString stringWithFormat:@"%.2f (Def)", value];
            } else {
                valLabel.text = [NSString stringWithFormat:@"%.2f", value];
            }
        };

        updateLabelText(slider.value);

        [stack addArrangedSubview:slider];
        [stack addArrangedSubview:valLabel];

        UIAction *updateTextAction = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            updateLabelText(slider.value);
        }];
        [slider addAction:updateTextAction forControlEvents:UIControlEventValueChanged];

        UIAction *saveAction = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
            self.values[varName] = [NSString stringWithFormat:@"%.2f", slider.value];
            [d setObject:self.values forKey:valuesKey];
            [d synchronize];
        }];
        [slider addAction:saveAction forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

        cell.accessoryView = stack;
    }

    return cell;
}

@end


// ==========================================
// REPOTWEAKS: REPO DETAIL VIEW CONTROLLER
// ==========================================
@interface RepoDetailController : UITableViewController
@property (nonatomic, strong) NSString *repoURL;
@end

@implementation RepoDetailController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSDictionary *repo = settings_repotweaks_repo_for_url(self.repoURL);
    NSString *repoName = settings_string_or_empty(repo[@"repoName"]);
    self.title = repoName.length ? repoName : @"Repository";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2; // Section 0: Tweaks, Section 1: Delete
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        NSDictionary *repo = settings_repotweaks_repo_for_url(self.repoURL);
        NSString *author = settings_string_or_empty(repo[@"author"]);
        return CYSectionHeaderView([NSString stringWithFormat:@"By %@", author.length ? author : @"Unknown"]);
    }
    return nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 0 ? UITableViewAutomaticDimension : 0.0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 1) return 1;
    return settings_repotweaks_tweaks_for_url(self.repoURL).count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];

    // The Delete Button
    if (indexPath.section == 1) {
        cell.textLabel.text = @"Delete Repository";
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        return cell;
    }

    // The Tweaks
    NSArray *tweaks = settings_repotweaks_tweaks_for_url(self.repoURL);
    if (indexPath.row >= (NSInteger)tweaks.count) return cell;
    NSDictionary *tweak = tweaks[indexPath.row];

    cell.textLabel.text = settings_string_or_empty(tweak[@"name"]);
    cell.detailTextLabel.text = settings_string_or_empty(tweak[@"description"]);
    cell.detailTextLabel.numberOfLines = 0;

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.tag = indexPath.row; // Link the switch to the tweak array index
    NSString *tweakID = settings_string_or_empty(tweak[@"id"]);
    NSString *key = repotweaks_enabled_defaults_key(self.repoURL, tweakID);
    toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:key];
    [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];

    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)toggled:(UISwitch *)sender {
    NSArray *tweaks = settings_repotweaks_tweaks_for_url(self.repoURL);
    if (sender.tag < 0 || sender.tag >= (NSInteger)tweaks.count) return;
    NSDictionary *tweak = tweaks[sender.tag];
    NSString *tweakID = settings_string_or_empty(tweak[@"id"]);
    if (tweakID.length == 0) return;
    NSString *key = repotweaks_enabled_defaults_key(self.repoURL, tweakID);
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (!sender.on) {
        repotweaks_cancel_tweak(self.repoURL, tweakID);
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        NSArray *tweaks = settings_repotweaks_tweaks_for_url(self.repoURL);
        if (indexPath.row >= (NSInteger)tweaks.count) return;
        RepoTweakDetailController *detailVC = [[RepoTweakDetailController alloc] initWithTweak:tweaks[indexPath.row]];
        [self.navigationController pushViewController:detailVC animated:YES];
        return;
    }

    // Handle Repo Deletion
    if (indexPath.section == 1) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        for (NSDictionary *tweak in settings_repotweaks_tweaks_for_url(self.repoURL)) {
            settings_clear_repo_tweak_defaults(self.repoURL, settings_string_or_empty(tweak[@"id"]));
        }

        NSMutableArray *urls = [settings_repotweaks_urls() mutableCopy];
        if (!urls) urls = [NSMutableArray array];
        [urls removeObject:self.repoURL];
        [d setObject:urls forKey:@"RepoTweaksURLs"];

        NSMutableDictionary *caches = [settings_repotweaks_caches() mutableCopy];
        if (!caches) caches = [NSMutableDictionary dictionary];
        [caches removeObjectForKey:self.repoURL];
        [d setObject:caches forKey:@"RepoTweaksCaches"];
        [d synchronize];

        [self.navigationController popViewControllerAnimated:YES]; // Slide back to main menu
    }
}
@end






// ==========================================
// REPOTWEAKS: REPO MANAGER CONTROLLER (the main page)
// ==========================================
@interface RepoManagerController : UITableViewController
@property (nonatomic, strong) NSArray *flattenedTweaks;
@end

@implementation RepoManagerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"RepoTweaks";

    // + and refresh buttons (menu bar)
    UIBarButtonItem *addButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addRepo)];
    UIBarButtonItem *refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshAll)];
    self.navigationItem.rightBarButtonItems = @[addButton, refreshButton];

    repotweaks_seed_default_repos();
    if ([settings_repotweaks_urls() containsObject:kSettingsDefaultRepoURL]) {
        NSDictionary *repo = settings_repotweaks_repo_for_url(kSettingsDefaultRepoURL);
        NSArray *tweaks = repo[@"tweaks"];
        if (![tweaks isKindOfClass:NSArray.class] || tweaks.count == 0) {
            __weak typeof(self) weakSelf = self;
            repotweaks_refresh_repo(kSettingsDefaultRepoURL, ^(BOOL success, NSString *message) {
                (void)success;
                (void)message;
                [weakSelf updateData];
            });
        }
    }
}

// auto refresh (there was a bug and I had to go back to the page and it would not refresh the UI without this)
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateData];
}

- (void)updateData {
    NSMutableArray *tempTweaks = [NSMutableArray array];
    for (NSString *url in settings_repotweaks_urls()) {
        [tempTweaks addObjectsFromArray:settings_repotweaks_tweaks_for_url(url)];
    }
    self.flattenedTweaks = tempTweaks;
    [self.tableView reloadData];
}

- (void)addRepo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Source" message:@"Paste the RAW link to your packages.json" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) { textField.placeholder = @"https://raw.githubusercontent.com/..."; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *url = alert.textFields.firstObject.text;
        if (url.length > 0) {
            repotweaks_add_repo(url, ^(BOOL success, NSString *message) {
                [self updateData];
                if (!success) {
                    UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Source Failed"
                                                                                 message:message ?: @"Could not refresh that repository."
                                                                          preferredStyle:UIAlertControllerStyleAlert];
                    [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:err animated:YES completion:nil];
                }
            });
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)refreshAll {
    NSArray *urls = settings_repotweaks_urls();
    if (urls.count == 0) return;

    // Refresh Alert
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Refreshing Sources"
                                                                   message:@"Nuking old scripts and downloading the latest..."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];

    // track download status
    dispatch_group_t group = dispatch_group_create();

    for (NSString *url in urls) {
        dispatch_group_enter(group);
        repotweaks_refresh_repo(url, ^(BOOL success, NSString *message) {
            dispatch_group_leave(group);
        });
    }

    //dismiss alert and refresh UI on success
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:^{
            [self updateData];
        }];
    });
}

// Native tweak sections
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return CYSectionHeaderView(section == 0 ? @"Sources" : @"All Tweaks");
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return 46.0; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return settings_repotweaks_urls().count;
    return self.flattenedTweaks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    if (indexPath.section == 0) {
        NSArray *urls = settings_repotweaks_urls();
        if (indexPath.row >= (NSInteger)urls.count) return cell;
        NSString *url = urls[indexPath.row];
        NSDictionary *repo = settings_repotweaks_repo_for_url(url);

        NSString *repoName = settings_string_or_empty(repo[@"repoName"]);
        cell.textLabel.text = repoName.length ? repoName : @"Unknown Repo";
        cell.detailTextLabel.text = url;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        if (indexPath.row >= (NSInteger)self.flattenedTweaks.count) return cell;
        NSDictionary *tweak = self.flattenedTweaks[indexPath.row];
        cell.textLabel.text = settings_string_or_empty(tweak[@"name"]);
        cell.detailTextLabel.text = settings_string_or_empty(tweak[@"description"]);
        cell.detailTextLabel.numberOfLines = 0;

        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.tag = indexPath.row;
        NSString *tweakID = settings_string_or_empty(tweak[@"id"]);
        NSString *repoURL = settings_string_or_empty(tweak[@"_repoURL"]);
        NSString *key = repotweaks_enabled_defaults_key(repoURL, tweakID);
        toggle.on = [d boolForKey:key];
        [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];

        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)toggled:(UISwitch *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)self.flattenedTweaks.count) return;
    NSDictionary *tweak = self.flattenedTweaks[sender.tag];
    NSString *tweakID = settings_string_or_empty(tweak[@"id"]);
    NSString *repoURL = settings_string_or_empty(tweak[@"_repoURL"]);
    if (tweakID.length == 0) return;
    NSString *key = repotweaks_enabled_defaults_key(repoURL, tweakID);
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (!sender.on) {
        repotweaks_cancel_tweak(repoURL, tweakID);
    }
}

//swipe to delete logic
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0; //only let user swipe to delete sources
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.section == 0) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSMutableArray *urls = [settings_repotweaks_urls() mutableCopy];
        if (!urls) urls = [NSMutableArray array];
        if (indexPath.row >= (NSInteger)urls.count) return;
        NSString *urlToRemove = urls[indexPath.row];
        for (NSDictionary *tweak in settings_repotweaks_tweaks_for_url(urlToRemove)) {
            settings_clear_repo_tweak_defaults(urlToRemove, settings_string_or_empty(tweak[@"id"]));
        }

        [urls removeObjectAtIndex:indexPath.row];
        [d setObject:urls forKey:@"RepoTweaksURLs"];

        NSMutableDictionary *caches = [settings_repotweaks_caches() mutableCopy];
        if (!caches) caches = [NSMutableDictionary dictionary];
        [caches removeObjectForKey:urlToRemove];
        [d setObject:caches forKey:@"RepoTweaksCaches"];
        [d synchronize];

        [self updateData]; //refreshes the ui
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    // Section 0: press on the repo, it lists all tweaks
    if (indexPath.section == 0) {
        NSArray *urls = settings_repotweaks_urls();
        if (indexPath.row >= (NSInteger)urls.count) return;
        RepoDetailController *detailVC = [[RepoDetailController alloc] initWithStyle:UITableViewStyleGrouped];
        detailVC.repoURL = urls[indexPath.row];
        [self.navigationController pushViewController:detailVC animated:YES];
    }
    // Section 1: press on a tweak, it lists all dynamic parameters
    else if (indexPath.section == 1) {
        if (indexPath.row >= (NSInteger)self.flattenedTweaks.count) return;
        NSDictionary *tweak = self.flattenedTweaks[indexPath.row];

        RepoTweakDetailController *detailVC = [[RepoTweakDetailController alloc] initWithTweak:tweak];
        [self.navigationController pushViewController:detailVC animated:YES];
    }
}
@end

@interface DSRespringOverlayView : UIView
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, assign) BOOL didLoadPayload;
@end

@implementation DSRespringOverlayView

- (NSString *)respringHTML {
    // Verbatim port of Lara's respring.swift payload (by rooootdev,
    // skidded from jailbreak.party; web approach by @neonmodder123).
    return @"<!DOCTYPE html>\n"
           @"<html>\n"
           @"    <body>\n"
           @"        <!--  big credit to @neonmodder123  -->\n"
           @"        <iframe id=\"frame\" srcdoc=\"\" sandbox=\"allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-presentation allow-scripts\"></iframe>\n"
           @"        <script>\n"
           @"            const frame = document.getElementById('frame');\n"
           @"            const script = `\n"
           @"                <html>\n"
           @"                <body>\n"
           @"                    <script>\n"
           @"                        const container = document.createElement('div');\n"
           @"                        container.style.cssText = 'perspective: 1px; perspective-origin: 9999999% 9999999%;';\n"
           @"                        document.body.appendChild(container);\n"
           @"    \n"
           @"                        for (let i = 0; i < 500; i++) {\n"
           @"                            let d = document.createElement('div');\n"
           @"                            d.style.cssText = 'position: absolute; width: 100vw; height: 100vh; backdrop-filter: blur(100px); -webkit-backdrop-filter: blur(100px); transform: translate3d(100000px, 100000px, ' + i + 'px) rotateY(90deg);';\n"
           @"                            container.appendChild(d);\n"
           @"                        }\n"
           @"    \n"
           @"                        setInterval(() => {\n"
           @"                            navigator.share({ title: 'R', text: 'R'.repeat(100000) }).catch(() => {});\n"
           @"                            let x = new Uint8Array(1024 * 1024 * 10);\n"
           @"                            crypto.getRandomValues(x);\n"
           @"                        }, 0);\n"
           @"                    <\\/script>\n"
           @"                </body>\n"
           @"                </html>\n"
           @"            `;\n"
           @"    \n"
           @"            frame.srcdoc = script;\n"
           @"        </script>\n"
           @"    </body>\n"
           @"</html>";
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor blackColor];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self loadRespringPayload];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.webView.frame = self.bounds;
}

- (void)loadRespringPayload {
    if (self.didLoadPayload) return;
    self.didLoadPayload = YES;
    printf("[RESPRING] loading Lara-style in-app WebKit overlay\n");

    // Mirrors Lara's respringview verbatim: default-init WKWebView, the
    // throwaway WKWebpagePreferences assignment (a no-op in Lara's Swift
    // source — kept for fidelity), then loadHTMLString.
    WKWebView *webView = [[WKWebView alloc] initWithFrame:self.bounds];
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [WKWebpagePreferences new].allowsContentJavaScript = YES;
    [self addSubview:webView];
    self.webView = webView;
    [webView loadHTMLString:[self respringHTML] baseURL:nil];
}

@end

NSString * const kSettingsA18ExploitPath   = @"A18ExploitPath";
NSString * const kSettingsA18Interleave = @"A18Interleave";
NSString * const kSettingsA18MemoryShaping = @"A18MemoryShaping";
NSString * const kSettingsA18BoundedSearch = @"A18BoundedSearch";
NSString * const kSettingsRemoteSettleMode  = @"RemoteSettleMode";
NSString * const kSettingsAutoRunKexploit    = @"AutoRunKexploit";
NSString * const kSettingsRunSandboxEscape   = @"RunSandboxEscape";
NSString * const kSettingsRunPatchSandboxExt = @"RunPatchSandboxExt";
NSString * const kSettingsKeepAlive          = @"KeepAlive";

NSString * const kSettingsSBCEnabled    = @"SBCEnabled";
NSString * const kSettingsSBCDockIcons  = @"SBCDockIcons";
NSString * const kSettingsSBCCols       = @"SBCCols";
NSString * const kSettingsSBCRows       = @"SBCRows";
NSString * const kSettingsSBCHideLabels = @"SBCHideLabels";
NSString * const kSettingsSBCDockLabels = @"SBCDockLabels";
NSString * const kSettingsSBCArrangePages = @"SBCArrangePages";
NSString * const kSettingsSBCFirstPageIcons = @"SBCFirstPageIcons";
NSString * const kSettingsSBCOtherPageIcons = @"SBCOtherPageIcons";
NSString * const kSettingsSBCAutoDockApp = @"SBCAutoDockApp";
NSString * const kSettingsSBCDockAppBundleID = @"SBCDockAppBundleID";

NSString * const kSettingsPowercuffEnabled = @"PowercuffEnabled";
NSString * const kSettingsPowercuffLevel   = @"PowercuffLevel";
static NSString * const kSettingsPowercuffNominalNoticeShown = @"cyanide.powercuff.nominalDefaultNoticeShown.v1";

NSString * const kSettingsDSDisableAppLibrary = @"DSDisableAppLibrary";
NSString * const kSettingsDSDisableIconFlyIn  = @"DSDisableIconFlyIn";
NSString * const kSettingsDSZeroWakeAnimation = @"DSZeroWakeAnimation";
NSString * const kSettingsDSZeroBacklightFade = @"DSZeroBacklightFade";
NSString * const kSettingsDSDoubleTapToLock   = @"DSDoubleTapToLock";

NSString * const kSettingsLockDurationValue   = @"LockDurationValue";

NSString * const kSettingsDSDragCoefficientEnabled = @"DSDragCoefficientEnabled";
NSString * const kSettingsDSDragCoefficientValue   = @"DSDragCoefficientValue";

NSString * const kSettingsLayoutExtrasEnabled  = @"LayoutExtrasEnabled";
NSString * const kSettingsLayoutHomeExtraLeft   = @"LayoutHomeExtraLeft";
NSString * const kSettingsLayoutHomeExtraRight  = @"LayoutHomeExtraRight";
NSString * const kSettingsLayoutHomeExtraTop    = @"LayoutHomeExtraTop";
NSString * const kSettingsLayoutHomeExtraBottom = @"LayoutHomeExtraBottom";
NSString * const kSettingsLayoutDockExtraLeft   = @"LayoutDockExtraLeft";
NSString * const kSettingsLayoutDockExtraRight  = @"LayoutDockExtraRight";
// Superseded by the separate L/R keys above; kept only so the one-time
// migration in settings_register_defaults can read a persisted old value.
static NSString * const kSettingsLayoutDockExtraHorizontalLegacy = @"LayoutDockExtraHorizontal";
NSString * const kSettingsLayoutHomeScalePct    = @"LayoutHomeScalePct";
NSString * const kSettingsLayoutDockScalePct    = @"LayoutDockScalePct";

static double settings_number_row_normalized_value(NSDictionary *row, double value)
{
    double minV = row[@"min"] ? [row[@"min"] doubleValue] : -DBL_MAX;
    double maxV = row[@"max"] ? [row[@"max"] doubleValue] : DBL_MAX;
    if (value < minV) value = minV;
    if (value > maxV) value = maxV;

    double step = row[@"step"] ? [row[@"step"] doubleValue] : 0.0;
    if (step > 0.0) {
        value = round(value / step) * step;
        if (value < minV) value = minV;
        if (value > maxV) value = maxV;
    }

    NSInteger precision = row[@"precision"] ? [row[@"precision"] integerValue] : 0;
    if (precision <= 0) value = (double)llround(value);
    return value;
}

static double settings_drag_coefficient_value(NSUserDefaults *d)
{
    id raw = [d objectForKey:kSettingsDSDragCoefficientValue];
    double value = [raw respondsToSelector:@selector(doubleValue)] ? [raw doubleValue] : 0.5;
    if (value <= 0.0) value = 0.5;

    // Older Cyanide builds stored this row as an integer percent (50 = 0.50).
    // New builds store the actual coefficient so typed values can reach 0.01.
    if (value > 2.0) value /= 100.0;

    NSDictionary *bounds = @{ @"min": @0.01, @"max": @2.0, @"step": @0.01, @"precision": @2 };
    return settings_number_row_normalized_value(bounds, value);
}

// Lock Screen Duration: seconds the lock screen stays awake before it dims and
// sleeps. Clamped to a sane range; defaults to 60s.
static const NSInteger kSettingsLockDurationMin     = 5;
static const NSInteger kSettingsLockDurationMax     = 3600;
static const NSInteger kSettingsLockDurationDefault = 60;

static long long settings_lock_duration_value(NSUserDefaults *d)
{
    id raw = [d objectForKey:kSettingsLockDurationValue];
    NSInteger value = [raw respondsToSelector:@selector(integerValue)]
        ? [raw integerValue]
        : kSettingsLockDurationDefault;
    if (value < kSettingsLockDurationMin) value = kSettingsLockDurationMin;
    if (value > kSettingsLockDurationMax) value = kSettingsLockDurationMax;
    return (long long)value;
}

static double settings_number_row_current_value(NSDictionary *row, NSUserDefaults *d)
{
    NSString *key = row[@"key"];
    if ([key isEqualToString:kSettingsDSDragCoefficientValue]) {
        return settings_drag_coefficient_value(d);
    }

    id raw = key.length > 0 ? [d objectForKey:key] : nil;
    double value = [raw respondsToSelector:@selector(doubleValue)]
        ? [raw doubleValue]
        : [row[@"default"] doubleValue];
    return settings_number_row_normalized_value(row, value);
}

static NSString *settings_number_row_value_string(NSDictionary *row, double value, BOOL includeUnit)
{
    NSInteger precision = row[@"precision"] ? [row[@"precision"] integerValue] : 0;
    NSString *unit = includeUnit ? (row[@"unit"] ?: @"") : @"";
    if (precision <= 0) {
        return [NSString stringWithFormat:@"%ld%@", (long)llround(value), unit];
    }
    return [NSString stringWithFormat:@"%.*f%@", (int)precision, value, unit];
}

NSString * const kSettingsStatBarEnabled = @"StatBarEnabled";
NSString * const kSettingsStatBarCelsius = @"StatBarCelsius";
NSString * const kSettingsStatBarShowNet = @"StatBarShowNet";
NSString * const kSettingsStatBarShowCPU = @"StatBarShowCPU";
NSString * const kSettingsStatBarShowLabels = @"StatBarShowLabels";
NSString * const kSettingsStatBarNetworkOnly = @"StatBarNetworkOnly";
NSString * const kSettingsStatBarRefreshRateSec = @"StatBarRefreshRateSec";

NSString * const kSettingsNSBarEnabled = @"NSBarEnabled";
NSString * const kSettingsNSBarPosition = @"NSBarPosition";

NSString * const kSettingsNiceBarLiteEnabled = @"NiceBarLiteEnabled";
static NSString * const kSettingsNiceBarLiteCelsius = @"NiceBarLiteCelsius";
static NSString * const kSettingsNiceBarLiteSlotKindPrefix = @"NiceBarLiteSlotKind";
static NSString * const kSettingsNiceBarLiteSlotSystemPrefix = @"NiceBarLiteSlotSystem";
static NSString * const kSettingsNiceBarLiteSlotTextPrefix = @"NiceBarLiteSlotText";
static NSString * const kSettingsNiceBarLiteSlotTimePrefix = @"NiceBarLiteSlotTime";
static NSString * const kSettingsNiceBarLiteSlotWeatherPrefix = @"NiceBarLiteSlotWeather";
static NSString * const kSettingsNiceBarLiteSlotWeatherLanguagePrefix = @"NiceBarLiteSlotWeatherLanguage";
static NSString * const kSettingsNiceBarLiteSlotSystemLanguagePrefix = @"NiceBarLiteSlotSystemLanguage";
static NSString * const kSettingsNiceBarLiteWeatherTemp = @"NiceBarLiteWeatherTemp";
static NSString * const kSettingsNiceBarLiteWeatherCode = @"NiceBarLiteWeatherCode";
static NSString * const kSettingsNiceBarLiteWeatherCache = @"NiceBarLiteWeatherCache";
static NSString * const kSettingsNiceBarLiteWeatherLastAttemptAt = @"NiceBarLiteWeatherLastAttemptAt";
static NSString * const kSettingsNiceBarLiteWeatherUpdatedAt = @"NiceBarLiteWeatherUpdatedAt";
static NSString * const kSettingsNiceBarLiteLayoutTopSideInset = @"NiceBarLiteLayoutTopSideInset";
static NSString * const kSettingsNiceBarLiteLayoutBottomSideInset = @"NiceBarLiteLayoutBottomSideInset";
static NSString * const kSettingsNiceBarLiteLayoutTopY = @"NiceBarLiteLayoutTopY";
static NSString * const kSettingsNiceBarLiteLayoutBottomY = @"NiceBarLiteLayoutBottomY";
static NSString * const kSettingsNiceBarLiteLayoutCenterX = @"NiceBarLiteLayoutCenterX";


NSString * const kSettingsAxonLiteEnabled = @"AxonLiteEnabled";

NSString * const kSettingsAppSwitcherGridEnabled = @"AppSwitcherGridEnabled";
NSString * const kSettingsFastLockXLiteEnabled = @"FastLockXLiteEnabled";
static NSString * const kSettingsFastLockXLiteBlockMusic = @"FastLockXLiteBlockMusic";
static NSString * const kSettingsFastLockXLiteBlockFlashlight = @"FastLockXLiteBlockFlashlight";
static NSString * const kSettingsFastLockXLiteBlockLowPower = @"FastLockXLiteBlockLowPower";
static NSString * const kSettingsFastLockXLiteRetryInterval = @"FastLockXLiteRetryInterval";
// Completion message of the main chain run when the exploit stage fails to
// acquire KRW. Shared between the run loop and the progress UI's retry button
// so the two can never drift apart.
NSString * const kSettingsRunKRWFailedMessage =
    @"Failed: kernel primitives were not acquired. Please try running chain again.";

// Auto-retry: when On, a chain run that fails to acquire KRW re-enters itself
// instead of reporting failure, up to the attempt cap. Each attempt is an
// independent aperture-panic dice roll, so the cap bounds per-tap exposure.
static NSString * const kSettingsRunAutoRetry = @"RunAutoRetry";
static NSString * const kSettingsRunAutoRetryMaxAttempts = @"RunAutoRetryMaxAttempts";
static NSString * const kSettingsHideHomeBarHidden = @"HideHomeBarHidden";
static NSString * const kSettingsHideHomeBarMaterialKitBootTime = @"HideHomeBarMaterialKitBootTime";
static NSString * const kSettingsHideHomeBarRespringPending = @"HideHomeBarRespringPending";
static NSString * const kSettingsHideHomeBarRespringPendingBootTime = @"HideHomeBarRespringPendingBootTime";
static NSString * const kSettingsHideHomeBarPendingHidden = @"HideHomeBarPendingHidden";

NSString * const kSettingsGravityLiteEnabled = @"GravityLiteEnabled";
NSString * const kSettingsGravityLiteDockEnabled = @"GravityLiteDockEnabled";
NSString * const kSettingsGravityLiteMagnitudePct = @"GravityLiteMagnitudePct";
NSString * const kSettingsGravityLiteBouncePct = @"GravityLiteBouncePct";
NSString * const kSettingsGravityLiteFrictionPct = @"GravityLiteFrictionPct";
NSString * const kSettingsGravityLiteResistancePct = @"GravityLiteResistancePct";
NSString * const kSettingsGravityLiteAngularResistancePct = @"GravityLiteAngularResistancePct";

NSString * const kSettingsStageStripEnabled = @"StageStripEnabled";

NSString * const kSettingsLocationSimEnabled = @"LocationSimEnabled";
NSString * const kSettingsLocationSimLatitude = @"LocationSimLatitude";
NSString * const kSettingsLocationSimLongitude = @"LocationSimLongitude";
NSString * const kSettingsLocationSimAltitude = @"LocationSimAltitude";
NSString * const kSettingsLocationSimHorizontalAccuracy = @"LocationSimHorizontalAccuracy";
NSString * const kSettingsLocationSimHostProcess = @"LocationSimHostProcess";
static NSString * const kSettingsLocationSimStarted = @"LocationSimStarted";


NSString * const kSettingsThemerEnabled = @"ThemerEnabled";
NSString * const kSettingsThemerThemeID = @"ThemerThemeID";
NSString * const kSettingsThemerCustomThemePath = @"ThemerCustomThemePath";
NSString * const kSettingsThemerCustomThemeName = @"ThemerCustomThemeName";

NSString * const kSettingsSnowBoardLiteEnabled = @"SnowBoardLiteEnabled";
NSString * const kSettingsSnowBoardLiteSelectedThemeID = @"SnowBoardLiteSelectedThemeID";

NSString * const kSettingsLiveWPEnabled = @"LiveWPEnabled";
NSString * const kSettingsLiveWPVideoPath = @"LiveWPVideoPath";

NSString * const kSettingsQuickLoaderEnabled = @"QuickLoaderEnabled";

NSString * const kSettingsRepoTweaksEnabled = @"RepoTweaksEnabled";

// Internal gate for unfinished in-development tweaks. There is no public
// account gate; beta packages that are ready for testing stay visible.
NSString * const kSettingsExperimentalTweaksEnabled = @"ExperimentalTweaksEnabled";

// NanoRegistry pairing-compatibility editor. Numbers are the watchOS pairing
// compatibility versions that NRPairingCompatibilityVersionInfo reads from
// /var/mobile/Library/Preferences/com.apple.NanoRegistry.plist via
// CFPreferencesCopyValue("com.apple.NanoRegistry").
NSString * const kSettingsNanoMaxPairing       = @"NanoRegistryMaxPairing";
NSString * const kSettingsNanoMinPairing       = @"NanoRegistryMinPairing";
NSString * const kSettingsNanoMinPairingChipID = @"NanoRegistryMinPairingChipID";
NSString * const kSettingsNanoMinQuickSwitch   = @"NanoRegistryMinQuickSwitch";

NSString * const kSettingsLogUploadEnabled = @"LogUploadEnabled";

static void cyanide_upload_log_if_enabled(void);
static void cyanide_upload_log_milestone(NSString *event);
static void cyanide_start_session_uploads(void);
static void cyanide_stop_session_uploads(void);
static NSObject *settings_rc_lock(void);
static BOOL settings_cleanup_in_progress(void);
static BOOL settings_screen_awake_cached(void);
static BOOL settings_screen_locked_cached(void);
static void settings_restart_gravity_motion_if_active(const char *reason);

extern int  escape_sbx_demo2(void);
extern int  escape_sbx_demo2_in_session(void);
extern int  escape_sbx_demo3(void);

static BOOL g_kexploit_done = NO;
static volatile int g_settings_actions_running = 0;
static volatile int g_settings_respring_cleanup_running = 0;
static volatile int g_settings_actions_rerun_requested = 0;
// Remembers how the last chain run was invoked so the post-failure "Run Again"
// alert can re-enter with the same mode (full Apply vs pending-only).
static volatile BOOL g_settings_actions_last_pending_only = NO;
// Counts consecutive auto-retries within one user-initiated run chain. Reset
// by every fresh public entry point and whenever a final outcome is posted.
static volatile int g_settings_actions_auto_retry_attempt = 0;
// Main-thread only. The idle-timer value from before the first attempt of a
// run group; auto-retries and queued follow-ups re-enter without restoring,
// so they must not re-capture the (now forced) YES as the original.
static BOOL g_settings_actions_idle_held = NO;
static BOOL g_settings_actions_idle_was_disabled = NO;
static volatile int g_springboard_rc_ready = 0;
static volatile int g_springboard_sandbox_escaped = 0;
static volatile int g_statbar_live_running = 0;
static volatile int g_statbar_live_stop_requested = 0;
static volatile int g_labels_live_running = 0;        // iOS 17 Hide Labels loop
static volatile int g_labels_live_stop_requested = 0;
static volatile int g_nsbar_live_running = 0;
static volatile int g_nsbar_live_stop_requested = 0;
static volatile int g_nicebarlite_live_running = 0;
static volatile int g_nicebarlite_live_stop_requested = 0;
static volatile int g_axonlite_live_running = 0;
static volatile int g_axonlite_live_stop_requested = 0;
static volatile int g_gravitylite_background_armed = 0;
static volatile int g_gravitylite_start_worker_running = 0;
static volatile int g_gravity_motion_stop_requested = 1;
static volatile uint64_t g_gravity_motion_generation = 0;
static CMMotionManager *g_gravity_motion_manager = nil;
static volatile int g_themer_live_running = 0;
static volatile int g_themer_live_stop_requested = 0;
static volatile int g_themer_repair_running = 0;
static volatile uint64_t g_themer_repair_generation = 0;
static volatile int g_themer_stage_suppression_logged = 0;
static volatile int g_livewp_live_running = 0;
static volatile int g_livewp_live_stop_requested = 0;

static void settings_mark_tweak_applied(NSString *key, BOOL applied);
static void settings_notify_package_queue_changed_async(void);

static BOOL settings_gravity_motion_can_remote_call(uint64_t generation,
                                                    CMMotionManager *manager)
{
    return manager &&
           manager == g_gravity_motion_manager &&
           generation == g_gravity_motion_generation &&
           g_gravity_motion_stop_requested == 0 &&
           g_springboard_rc_ready != 0 &&
           !settings_screen_locked_cached() &&
           settings_screen_awake_cached() &&
           !settings_cleanup_in_progress();
}

static void settings_start_gravity_motion(double magnitude, double explosionForce)
{
    (void)explosionForce;
    if (g_gravity_motion_manager) {
        [g_gravity_motion_manager stopDeviceMotionUpdates];
        [g_gravity_motion_manager stopAccelerometerUpdates];
        g_gravity_motion_manager = nil;
    }
    CMMotionManager *mm = [[CMMotionManager alloc] init];
    g_gravity_motion_manager = mm;
    uint64_t generation = __sync_add_and_fetch(&g_gravity_motion_generation, 1);
    __sync_lock_test_and_set(&g_gravity_motion_stop_requested, 0);
    NSOperationQueue *q = [[NSOperationQueue alloc] init];
    q.maxConcurrentOperationCount = 1;

    if (mm.deviceMotionAvailable) {
        mm.deviceMotionUpdateInterval = 0.05;
        [mm startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *motion, NSError *err) {
            if (!motion || err || !settings_gravity_motion_can_remote_call(generation, mm)) return;
            // gravity.x/y are already isolated from user movement.
            double tilt = hypot(motion.gravity.x, motion.gravity.y);
            double angle = (tilt < 0.14) ? M_PI_2 : atan2(-motion.gravity.y, motion.gravity.x);
            double effectiveMagnitude = magnitude * ((tilt < 0.14)
                                                     ? 0.65
                                                     : (0.90 + fmin(tilt, 1.0) * 0.60));

            @synchronized (settings_rc_lock()) {
                if (!settings_gravity_motion_can_remote_call(generation, mm)) return;
                gravitylite_update_gravity_angle_in_session(angle, effectiveMagnitude);
            }
        }];
    } else {
        mm.accelerometerUpdateInterval = 0.05;
        [mm startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *data, NSError *err) {
            if (!data || err || !settings_gravity_motion_can_remote_call(generation, mm)) return;
            double tilt = hypot(data.acceleration.x, data.acceleration.y);
            double angle = (tilt < 0.14) ? M_PI_2 : atan2(-data.acceleration.y, data.acceleration.x);
            double effectiveMagnitude = magnitude * ((tilt < 0.14)
                                                     ? 0.65
                                                     : (0.90 + fmin(tilt, 1.2) * 0.50));
            @synchronized (settings_rc_lock()) {
                if (!settings_gravity_motion_can_remote_call(generation, mm)) return;
                gravitylite_update_gravity_angle_in_session(angle, effectiveMagnitude);
            }
        }];
    }
    printf("[GRAVITY] Accelerometer active — tilt-only icon physics (magnitude=%.1fx)\n",
           magnitude);
}

static void settings_stop_gravity_motion(void)
{
    __sync_lock_test_and_set(&g_gravity_motion_stop_requested, 1);
    __sync_add_and_fetch(&g_gravity_motion_generation, 1);
    CMMotionManager *mm = g_gravity_motion_manager;
    if (!mm) return;
    g_gravity_motion_manager = nil;
    [mm stopDeviceMotionUpdates];
    [mm stopAccelerometerUpdates];
    printf("[GRAVITY] Accelerometer stopped.\n");
}

typedef void (*SettingsTweakRequestStopFunc)(void);
typedef bool (*SettingsTweakStopFunc)(BOOL springboardWillDie);
typedef void (*SettingsTweakForgetFunc)(void);
typedef BOOL (*SettingsTweakRunningFunc)(void);

typedef struct {
    __unsafe_unretained NSString *key;
    const char *name;
    SettingsTweakRequestStopFunc requestStop;
    SettingsTweakStopFunc stop;
    SettingsTweakForgetFunc forget;
    SettingsTweakRunningFunc isRunning;
    BOOL cleanupOnTermination;
    BOOL keepsSpringBoardSession;
} SettingsSpringBoardTweakCleanupEntry;

static void settings_request_statbar_stop(void) { g_statbar_live_stop_requested = 1; }
static void settings_request_labels_stop(void) { g_labels_live_stop_requested = 1; }
static void settings_request_nsbar_stop(void) { g_nsbar_live_stop_requested = 1; }
static void settings_request_nicebarlite_stop(void) { g_nicebarlite_live_stop_requested = 1; }
static void settings_request_axonlite_stop(void) { g_axonlite_live_stop_requested = 1; }
static void settings_request_themer_stop(void) { g_themer_live_stop_requested = 1; }
static void settings_request_gravitylite_stop(void)
{
    __sync_lock_test_and_set(&g_gravitylite_background_armed, 0);
    settings_stop_gravity_motion();
}
static void settings_request_stagestrip_stop(void) { stagestrip_stop_control_loop(); }
static void settings_request_livewp_stop(void) { g_livewp_live_stop_requested = 1; }

static BOOL settings_statbar_running(void) { return g_statbar_live_running != 0; }
static BOOL settings_labels_running(void) { return g_labels_live_running != 0; }
// Hide Labels on iOS 17 installs a DURABLE -[SBIconView _shouldShowLabel] hook that
// is meant to persist after Cyanide closes (that is the whole feature — it behaves
// like iOS 18's native switch). So termination / session-teardown cleanup must NOT
// remove it. The only things that clear it: the user turning Hide Labels off (the
// apply path calls sbcustomizer_restore_home_labels directly) and a respring
// (SpringBoard drops it on its own). We only stop the fallback live loop here, which
// is handled by requestStop; there is nothing else to undo.
static bool settings_stop_labels_registered(BOOL springboardWillDie)
{
    (void)springboardWillDie;
    return true;
}
// Nothing to forget on session teardown: whether the durable _shouldShowLabel hook
// is live is read straight from SpringBoard (authoritative, survives resprings), and
// the saved original IMP is invalidated there the moment the hook is seen gone. We
// intentionally keep the saved IMP across a session drop so a later toggle-off can
// still restore it while the process (and SpringBoard session) live on.
static void settings_labels_forget_remote_state(void) { }
static BOOL settings_nsbar_running(void) { return g_nsbar_live_running != 0; }
static BOOL settings_nicebarlite_running(void) { return g_nicebarlite_live_running != 0; }
static BOOL settings_axonlite_running(void) { return g_axonlite_live_running != 0; }
static BOOL settings_themer_running(void) { return g_themer_live_running != 0 || g_themer_repair_running != 0; }
static BOOL settings_livewp_running(void) { return g_livewp_live_running != 0; }

static bool settings_stop_statbar_registered(BOOL springboardWillDie)
{
    (void)springboardWillDie;
    return statbar_stop_in_session();
}

static bool settings_stop_nsbar_registered(BOOL springboardWillDie)
{
    (void)springboardWillDie;
    return nsbar_stop_in_session();
}

static bool settings_stop_nicebarlite_registered(BOOL springboardWillDie)
{
    (void)springboardWillDie;
    return nicebarlite_stop_in_session();
}

static bool settings_stop_axonlite_registered(BOOL springboardWillDie)
{
    return springboardWillDie ? axonlite_stop_in_session_fast()
                              : axonlite_stop_in_session();
}

static bool settings_stop_appswitchergrid_registered(BOOL springboardWillDie)
{
    if (springboardWillDie) {
        appswitchergrid_forget_remote_state();
        return false;
    }
    return appswitchergrid_stop_in_session();
}

static bool settings_stop_gravitylite_registered(BOOL springboardWillDie)
{
    (void)springboardWillDie;
    settings_request_gravitylite_stop();
    return gravitylite_stop_in_session();
}

static bool settings_stop_themer_registered(BOOL springboardWillDie)
{
    (void)springboardWillDie;
    return themer_stop_in_session();
}

static bool settings_stop_stagestrip_registered(BOOL springboardWillDie)
{
    (void)springboardWillDie;
    return stagestrip_stop_in_session();
}

static volatile int g_fastlockx_lite_remote_active_state = -1;
static volatile uint64_t g_fastlockx_lite_last_unlock_nudge_ms = 0;

static uint64_t settings_now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return ((uint64_t)tv.tv_sec * 1000ULL) + ((uint64_t)tv.tv_usec / 1000ULL);
}

static void settings_maybe_nudge_fastlockx_lite_awake_locked(const char *why,
                                                             BOOL awake,
                                                             BOOL locked)
{
    if (!awake || !locked) {
        __sync_lock_test_and_set(&g_fastlockx_lite_last_unlock_nudge_ms, 0);
        return;
    }

    uint64_t now = settings_now_ms();
    uint64_t lastNudge = g_fastlockx_lite_last_unlock_nudge_ms;
    if (now > lastNudge + 900 &&
        __sync_bool_compare_and_swap(&g_fastlockx_lite_last_unlock_nudge_ms,
                                     lastNudge,
                                     now)) {
        bool nudgeOK = fastlockx_lite_attempt_unlock_in_session(false);
        printf("[SETTINGS] FastLockX awake unlock nudge reason=%s ok=%d awake=%d locked=%d\n",
               why ?: "screen state",
               nudgeOK,
               awake,
               locked);
    }
}

static bool settings_stop_fastlockx_lite_registered(BOOL springboardWillDie)
{
    __sync_lock_test_and_set(&g_fastlockx_lite_remote_active_state, -1);
    __sync_lock_test_and_set(&g_fastlockx_lite_last_unlock_nudge_ms, 0);
    if (springboardWillDie) {
        fastlockx_lite_forget_remote_state();
        return true;
    }
    bool ok = fastlockx_lite_disable_always_on_in_session();
    if (!ok) __sync_lock_test_and_set(&g_fastlockx_lite_remote_active_state, -1);
    return ok;
}

static bool settings_stop_livewp_registered(BOOL springboardWillDie)
{
    (void)springboardWillDie;
    return livewp_stop_in_session();
}

static bool settings_stop_quickloader_registered(BOOL springboardWillDie)
{
    (void)springboardWillDie;
    return quickloader_stop_in_session();
}

static bool settings_stop_repotweaks_registered(BOOL springboardWillDie)
{
    (void)springboardWillDie;
    return repotweaks_stop_in_session();
}

static void settings_each_springboard_cleanup_entry(void (^block)(const SettingsSpringBoardTweakCleanupEntry *entry))
{
    if (!block) return;
    // Add new SpringBoard-backed tweaks here so Clean Up, Respring cleanup,
    // termination cleanup, live-loop waits, and applied-state reset stay in sync.
    const SettingsSpringBoardTweakCleanupEntry entries[] = {
        { kSettingsStatBarEnabled, "StatBar", settings_request_statbar_stop, settings_stop_statbar_registered, statbar_forget_remote_state, settings_statbar_running, YES, YES },
        // BOTH flags NO: Hide Labels is durable on its own (iOS 17 _shouldShowLabel
        // swizzle, iOS 18 config lever) and does NOT need the SpringBoard RemoteCall
        // session — nor termination cleanup — to persist. Either flag being YES makes
        // settings_has_persistent_springboard_remote_call_user() report a persistent
        // user (cleanupOnTermination feeds settings_has_active_termination_live_tweak,
        // checked first), which pins the session open and blocks KRW idle-detach. That
        // left our synthetic hijacked thread alive and the KRW filter under our
        // control across lock/unlock, and the teardown on close (or an inbound icmp6
        // packet against a badly-aimed parked filter) crashed SpringBoard (0x401).
        // With BOTH NO, a Hide Labels run releases the session and hands KRW to
        // launchd at session-end — exactly like a no-labels run — which does not undo
        // the label patch. The fallback live loop, if it ever runs, still holds the
        // session via settings_any_registered_live_loop_running().
        { kSettingsSBCHideLabels, "Hide Labels", settings_request_labels_stop, settings_stop_labels_registered, settings_labels_forget_remote_state, settings_labels_running, NO, NO },
        { kSettingsNSBarEnabled, "NSBar", settings_request_nsbar_stop, settings_stop_nsbar_registered, nsbar_forget_remote_state, settings_nsbar_running, YES, YES },
        { kSettingsNiceBarLiteEnabled, "NiceBar Lite", settings_request_nicebarlite_stop, settings_stop_nicebarlite_registered, nicebarlite_forget_remote_state, settings_nicebarlite_running, YES, YES },
        { kSettingsAxonLiteEnabled, "Axon Lite", settings_request_axonlite_stop, settings_stop_axonlite_registered, axonlite_forget_remote_state, settings_axonlite_running, YES, YES },
        { kSettingsAppSwitcherGridEnabled, "App Switcher Grid", NULL, settings_stop_appswitchergrid_registered, appswitchergrid_forget_remote_state, NULL, YES, YES },
        { kSettingsGravityLiteEnabled, "Gravity Lite", settings_request_gravitylite_stop, settings_stop_gravitylite_registered, gravitylite_forget_remote_state, NULL, YES, YES },
        { kSettingsThemerEnabled, "Themer", settings_request_themer_stop, settings_stop_themer_registered, themer_forget_remote_state, settings_themer_running, YES, YES },
        { kSettingsSnowBoardLiteEnabled, "SnowBoard Lite", NULL, settings_stop_themer_registered, themer_forget_remote_state, NULL, YES, YES },
        { kSettingsLiveWPEnabled, "LiveWP", settings_request_livewp_stop, settings_stop_livewp_registered, livewp_forget_remote_state, settings_livewp_running, YES, YES },
        { kSettingsStageStripEnabled, "Stage Strip", settings_request_stagestrip_stop, settings_stop_stagestrip_registered, stagestrip_forget_remote_state, NULL, YES, YES },
        { kSettingsFastLockXLiteEnabled, "FastLockX Lite", NULL, settings_stop_fastlockx_lite_registered, fastlockx_lite_forget_remote_state, NULL, NO, YES },
        { kSettingsQuickLoaderEnabled, "QuickLoader", NULL, settings_stop_quickloader_registered, NULL, NULL, YES, YES },
        { kSettingsRepoTweaksEnabled, "RepoTweaks", NULL, settings_stop_repotweaks_registered, NULL, NULL, YES, YES },
        { nil, "Kill All Apps", NULL, NULL, killallapps_forget_remote_state, NULL, NO, NO },
    };
    size_t count = sizeof(entries) / sizeof(entries[0]);
    for (size_t i = 0; i < count; i++) {
        block(&entries[i]);
    }
}

static BOOL settings_any_registered_live_loop_running(void)
{
    __block BOOL running = NO;
    settings_each_springboard_cleanup_entry(^(const SettingsSpringBoardTweakCleanupEntry *entry) {
        if (!running && entry->isRunning && entry->isRunning()) running = YES;
    });
    return running;
}

static NSString *settings_registered_live_loop_status_string(void)
{
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    settings_each_springboard_cleanup_entry(^(const SettingsSpringBoardTweakCleanupEntry *entry) {
        if (!entry->isRunning) return;
        [parts addObject:[NSString stringWithFormat:@"%s=%d",
                                                    entry->name ?: "tweak",
                                                    entry->isRunning() ? 1 : 0]];
    });
    return [parts componentsJoinedByString:@" "];
}

static BOOL settings_cleanup_entry_is_js_runner(const SettingsSpringBoardTweakCleanupEntry *entry)
{
    if (!entry || !entry->key) return NO;
    return [entry->key isEqualToString:kSettingsQuickLoaderEnabled] ||
           [entry->key isEqualToString:kSettingsRepoTweaksEnabled];
}

static BOOL settings_cleanup_entry_has_runtime_state(NSUserDefaults *d,
                                                     const SettingsSpringBoardTweakCleanupEntry *entry)
{
    if (!entry) return NO;
    if (entry->isRunning && entry->isRunning()) return YES;
    if (entry->key && settings_tweak_is_applied(entry->key)) return YES;
    (void)d;
    return NO;
}

static BOOL settings_cleanup_entry_should_stop(NSUserDefaults *d,
                                               const SettingsSpringBoardTweakCleanupEntry *entry,
                                               BOOL springboardWillDie)
{
    if (!entry || !entry->stop) return NO;
    if (!settings_cleanup_entry_has_runtime_state(d, entry)) return NO;

    BOOL running = entry->isRunning && entry->isRunning();

    // During a respring SpringBoard is about to die anyway. Avoid expensive
    // remote restoration for one-shot/applied tweaks and only stop things that
    // can keep app-side work alive long enough to race the restart.
    if (springboardWillDie) {
        return running || settings_cleanup_entry_is_js_runner(entry);
    }

    (void)d;
    return YES;
}
static volatile int g_app_in_background = 0;
// Round 35: a FRESH SpringBoard hijack (set_exception_ports → AMFI global
// entitlement lock) must not run while runningboardd / PerfPowerServices apply
// task_policy_set to our task at launch/activation — the two take the AMFI lock
// and the task/proc lock in OPPOSITE orders → ABBA deadlock, with launchd caught
// as our exception server → 90 s watchdog (proven: panic-full-2026-10-03-235811,
// symbolized identically in kc_22F76/SYMBOLIZATION_REPORT.md panic 1). This is
// the monotonic deadline until which a fresh SpringBoard establishment waits.
// Set on every activation/foreground; only the first (automatic launch-time)
// hijack pays it — a reused session and any user action after the window do not.
static volatile uint64_t g_activation_settle_until_ns = 0;
static const uint64_t kActivationSettleNs = 3ULL * 1000000000ULL; // 3 s
// Latest moment a switcher-card removal scheduled by the location shortcut
// can fire (it ends Cyanide). Folded into the settle window, so no fresh
// SpringBoard/launchd injection — from any feature — starts before it.
static volatile uint64_t g_removal_fire_bound_ns = 0;
static uint64_t settings_settle_until_after_activation(void)
{
    uint64_t until = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + kActivationSettleNs;
    return MAX(until, g_removal_fire_bound_ns);
}
// Kernel work of any kind (exploit, parked-KRW restore, launchd reads) must
// not be in flight when a pending card removal ends Cyanide: wait out the
// bound first. Only matters when Cyanide is reopened within a few seconds of
// a shortcut run. The bound is an estimate (the timer can run later if
// SpringBoard's main thread is busy), hence its generous margin. Returns NO
// if the app goes to the background meanwhile.
static BOOL settings_wait_for_pending_switcher_removal(void)
{
    uint64_t bound = g_removal_fire_bound_ns;
    if (bound <= clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) return YES;
    log_user("[SWITCHER] waiting for the pending App Switcher card removal before kernel work\n");
    while (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) < bound) {
        if (g_app_in_background || excport_gate_blocked()) return NO;
        usleep(100000);
    }
    return YES;
}

// YES while a switcher-card removal armed by an earlier shortcut run can
// still fire (ending Cyanide). Such a timer cannot be cancelled from here:
// the cancel would have to reach SpringBoard BEFORE the bound, but a fresh
// SpringBoard hijack that soon after activation is the runningboardd
// task_policy_set ABBA deadlock the settle window exists to prevent (panic
// 235811). So a request that arrives while this is pending must fail fast
// instead of starting kernel work the removal will kill mid-flight.
BOOL settings_switcher_removal_pending(void)
{
    return g_removal_fire_bound_ns > clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}
// Progress hook for the location shortcut: called when a fresh SpringBoard
// connection actually starts (after the settle wait). Set only while that
// action runs.
static void (^g_springboard_connect_progress)(void) = nil;
static volatile int g_screen_awake = 1;
static volatile int g_screen_locked = 0;
static volatile int g_screen_lock_state_logged = 0;
static volatile int g_settings_termination_cleanup_started = 0;
static volatile int g_settings_cleanup_running = 0;
static volatile uint64_t g_sbc_live_apply_generation = 0;
static UIBackgroundTaskIdentifier g_statbar_bg_task = (UIBackgroundTaskIdentifier)-1;
static int g_springboard_blanked_notify_token = NOTIFY_TOKEN_INVALID;
static int g_display_status_notify_token = NOTIFY_TOKEN_INVALID;
static int g_springboard_lockstate_notify_token = NOTIFY_TOKEN_INVALID;
static int g_springboard_finished_startup_notify_token = NOTIFY_TOKEN_INVALID;
static int g_springboard_app_state_notify_token = NOTIFY_TOKEN_INVALID;
static int g_springboard_frontmost_notify_token = NOTIFY_TOKEN_INVALID;
static const NSInteger kSBCDefaultDockIcons = 4;
static const NSInteger kSBCDefaultCols = 4;
static const NSInteger kSBCDefaultRows = 6;
static const BOOL kSBCDefaultHideLabels = NO;
// Stock iOS draws no dock labels, so off matches the system.
static const BOOL kSBCDefaultDockLabels = NO;
static const BOOL kSBCDefaultArrangePages = NO;
static const NSInteger kSBCDefaultFirstPageIcons = 20;
static const NSInteger kSBCDefaultOtherPageIcons = 25;
static const BOOL kSBCDefaultAutoDockApp = YES;
static NSString * const kSBCDefaultDockAppBundleID = @"com.fouadraheb.watusi";
static NSString * const kSBCLegacyDockAppBundleID = @"net.whatsapp.WhatsApp";
// Conservative seed values for the NanoRegistry editor. These represent the
// current "newer watch" baseline without changing the legacy-watch gates.
static const NSInteger kNanoDefaultMaxPairing       = 25;
static const NSInteger kNanoDefaultMinPairing       = 24;
static const NSInteger kNanoDefaultMinPairingChipID = 10;
static const NSInteger kNanoDefaultMinQuickSwitch   = 6;
// Pairing range used to let setup accept newer watchOS pairing generations
// while still accepting generation-23 setup messages from the existing flow.
static const NSInteger kNanoPresetNewerMaxPairing       = 99;
static const NSInteger kNanoPresetNewerMinPairing       = 23;
static const NSInteger kNanoPresetNewerMinPairingChipID = 10;
static const NSInteger kNanoPresetNewerMinQuickSwitch   = 6;
static const double kLocationSimDefaultLatitude = 40.55162017033417;
static const double kLocationSimDefaultLongitude = -73.93282297058470;
static const NSInteger kLocationSimDefaultAltitude = 0;
static const NSInteger kLocationSimDefaultAccuracy = 5;
static const NSInteger kNanoUIRowMin = 1;
static const NSInteger kNanoUIRowMax = 999;
static const useconds_t kStatBarLiveIntervalUS = 1000000;
static const NSInteger kStatBarDefaultRefreshRateSec = 1;
static const NSUInteger kStatBarLiveMaxTicks = 43200;
// Hide Labels loop (iOS 17 only): iOS 17 tears down off-screen pages' icon views
// and rebuilds them (with labels) on swipe, so labels can only be hidden once a
// page is shown. To make that near-instant without hammering, the loop polls a
// cheap current-page identity every 100ms and only does the full hide when the
// page changes (a swipe) — plus a periodic fallback for stragglers.
static const useconds_t kLabelsLiveIntervalUS = 100000;
static const NSUInteger kLabelsLiveMaxTicks = 400000;
static const useconds_t kNSBarLiveIntervalUS = 1000000;
static const useconds_t kNSBarLiveBackgroundIntervalUS = 1500000;
static const NSUInteger kNSBarLiveMaxTicks = 43200;
static const useconds_t kNiceBarLiteLiveIntervalUS = 1000000;
static const useconds_t kNiceBarLiteLiveBackgroundIntervalUS = 1500000;
static const NSUInteger kNiceBarLiteLiveMaxTicks = 43200;
static const NSTimeInterval kNiceBarLiteWeatherRefreshInterval = 15.0 * 60.0;
static const useconds_t kLiveWPLiveIntervalUS = 2000000;
static const useconds_t kLiveWPLiveBackgroundIntervalUS = 3000000;
static const NSUInteger kLiveWPLiveMaxTicks = 43200;
static const int64_t kLiveBackgroundTaskGraceSeconds = 10;
static const useconds_t kAxonLiteLiveIntervalUS = 500000;
static const useconds_t kAxonLiteLiveBackgroundIntervalUS = 1500000;
static const NSUInteger kAxonLiteLiveMaxTicks = 43200;
// The SpringBoard EXC_GUARD hijack only traps when an injected thread runs, so a
// loaded system (cold boot, or right after a heavy pe_v2 stage) can miss a tight
// window. Use a roomier first timeout and retry once with a longer one before
// failing the whole Run. Traps fire in <100 ms when healthy, so the higher
// ceilings only cost time in the rare loaded case.
static const int kSettingsSpringBoardRCFirstExceptionTimeoutMS = 5000;
static const int kSettingsSpringBoardRCRetryTimeoutMS          = 12000;
static const int kSettingsSpringBoardRCMaxAttempts             = 2;
// Only Clock/Calendar need periodic repair; normal icons persist through the
// model graft and should not be repainted during SpringBoard animations.
static const useconds_t kThemerLiveIntervalUS = 2000000;
static const useconds_t kThemerLiveBackgroundIntervalUS = 10000000;
static const useconds_t kThemerSnowBoardLiteSlowIntervalUS = 8000000;
static const useconds_t kThemerSnowBoardLiteSlowBackgroundIntervalUS = 30000000;
static const NSUInteger kThemerSnowBoardLiteInitialVisibleTicks = 3;
static const NSUInteger kThemerLiveMaxTicks = 86400;
static const NSUInteger kThemerLegacyLiveMaxTicks = 1;
// iOS <26: instead of theming once and exiting (which left off-screen pages
// unthemed until an app-cycle/unlock — issue #8), run a lightweight page-follow:
// poll a cheap current-page identity and only re-theme the visible page when it
// changes (a swipe), so each page themes as you swipe to it.
static const NSUInteger kThemerLegacyPageMaxTicks = 200000;
static const useconds_t kThemerLegacyPagePollUS   = 300000;   // 300ms cheap probe
static const useconds_t kThemerRepairInitialDelayUS = 900000;
static const useconds_t kThemerRepairIntervalUS = 450000;
static NSString * const kSettingsRemoteCallStateDidChangeNotification = @"SettingsRemoteCallStateDidChangeNotification";
NSString * const kSettingsActionsDidCompleteNotification = @"SettingsActionsDidCompleteNotification";
NSString * const kSettingsActionsDidCompleteSuccessKey = @"success";
NSString * const kSettingsActionsDidCompletePartialKey = @"partial";
NSString * const kSettingsFileBrowserShowHidden = @"FileBrowserShowHidden";
NSString * const kSettingsFileBrowserShowInaccessible = @"FileBrowserShowInaccessible";
NSString * const kSettingsFileBrowserRootAccess = @"FileBrowserRootAccess";
NSString * const kSettingsActionsDidCompleteMessageKey = @"message";
static NSString * const kSettingsCleanupStateDidChangeNotification = @"SettingsCleanupStateDidChangeNotification";

static void settings_notify_cleanup_state_changed(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:kSettingsCleanupStateDidChangeNotification
                          object:nil];
    });
}

static void settings_post_actions_complete_async(BOOL success, NSString *message)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *info = @{
            kSettingsActionsDidCompleteSuccessKey: @(success),
            kSettingsActionsDidCompleteMessageKey: message ?: @""
        };
        [[NSNotificationCenter defaultCenter]
            postNotificationName:kSettingsActionsDidCompleteNotification
                          object:nil
                        userInfo:info];
    });
}

// A failure that happened BEFORE the run (e.g. a repo tweak whose script
// download failed during the installer's queue commit). The progress screen's
// final status comes from the run's own completion, so without folding this
// in, a failed install shows as "Done" whenever the rest of the run succeeds.
// Set right before settings_run_pending_actions; consumed by that run's
// completion (auto-retries/re-runs return before consuming, so it survives
// into the completion that is actually posted).
static NSString *g_settings_run_preflight_failure = nil;
static NSObject *settings_preflight_failure_lock(void)
{
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

void settings_note_run_preflight_failure(NSString *message)
{
    @synchronized (settings_preflight_failure_lock()) {
        g_settings_run_preflight_failure = [message copy];
    }
}

// Consumed exactly once, by the completion that is posted.
static NSString *settings_take_run_preflight_failure(void)
{
    @synchronized (settings_preflight_failure_lock()) {
        NSString *message = g_settings_run_preflight_failure;
        g_settings_run_preflight_failure = nil;
        return message;
    }
}

static NSArray<NSString *> * const kPowercuffLevels = nil;

// Session-scoped record of which tweaks were actually applied since launch.
// Distinct from the persisted NSUserDefaults enable flag — these are wiped on
// app launch and whenever the SpringBoard RemoteCall session is torn down, so
// the UI can show accurate "Installed" state rather than a stale toggle.
static NSMutableSet<NSString *> *g_applied_tweak_keys = nil;

static NSMutableSet<NSString *> *settings_applied_keys_set(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_applied_tweak_keys = [NSMutableSet set];
    });
    return g_applied_tweak_keys;
}

static BOOL settings_key_persists_applied_state(NSString *key)
{
    // SBCustomizer mutates SpringBoard's live icon models. Those mutations
    // must be applied again after every SpringBoard restart, so its applied
    // state is intentionally process-local rather than persisted.
    return [key isEqualToString:kSettingsQuickLoaderEnabled] ||
           [key isEqualToString:kSettingsRepoTweaksEnabled];
}

static NSString *settings_persisted_applied_bool_key(NSString *key)
{
    return [@"CyanideApplied." stringByAppendingString:key ?: @""];
}

static NSString *settings_persisted_applied_pid_key(NSString *key)
{
    return [@"CyanideAppliedSpringBoardPID." stringByAppendingString:key ?: @""];
}

static void settings_set_persisted_applied(NSString *key, BOOL applied)
{
    if (!settings_key_persists_applied_state(key)) return;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *appliedKey = settings_persisted_applied_bool_key(key);
    NSString *pidKey = settings_persisted_applied_pid_key(key);
    if (applied) {
        int pid = remote_call_current_pid();
        [d setBool:YES forKey:appliedKey];
        if (pid > 0) [d setInteger:pid forKey:pidKey];
    } else {
        [d removeObjectForKey:appliedKey];
        [d removeObjectForKey:pidKey];
    }
    [d synchronize];
}

static BOOL settings_persisted_applied(NSString *key)
{
    if (!settings_key_persists_applied_state(key)) return NO;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:settings_persisted_applied_bool_key(key)]) return NO;

    // If a SpringBoard RemoteCall session is open, validate the marker against
    // that SpringBoard pid. If no session is open yet, trust the persisted
    // marker; explicit Clean Up / Respring / disabling the tweak clears it.
    NSInteger storedPid = [d integerForKey:settings_persisted_applied_pid_key(key)];
    int currentPid = remote_call_current_pid();
    if (storedPid > 0 && currentPid > 0 && storedPid != currentPid) {
        settings_set_persisted_applied(key, NO);
        return NO;
    }
    return YES;
}

static void settings_mark_tweak_applied(NSString *key, BOOL applied)
{
    if (!key) return;
    NSMutableSet *set = settings_applied_keys_set();
    @synchronized (set) {
        if (applied) [set addObject:key];
        else         [set removeObject:key];
    }
    settings_set_persisted_applied(key, applied);
}

BOOL settings_tweak_is_applied(NSString *key)
{
    if (!key) return NO;
    NSMutableSet *set = settings_applied_keys_set();
    @synchronized (set) {
        if ([set containsObject:key]) return YES;
    }
    return settings_persisted_applied(key);
}

void settings_mark_tweak_needs_apply(NSString *key)
{
    settings_mark_tweak_applied(key, NO);
}

// Re-queue every already-applied tweak so it shows in the queue and can be
// applied again — without relaunching Cyanide. Relaunching normally re-queues
// enabled tweaks because the in-memory applied set starts empty; this reproduces
// that in-process by clearing that set, so parked-state re-apply can be tested
// while the app stays open (closing/relaunching itself changes the primitive).
// Mirrors a relaunch: only the process-local applied state is cleared;
// persisted markers (QuickLoader/RepoTweaks) survive a relaunch and are left be.
void settings_requeue_applied_tweaks_for_reapply(void)
{
    NSMutableSet<NSString *> *set = settings_applied_keys_set();
    @synchronized (set) { [set removeAllObjects]; }
    settings_notify_package_queue_changed_async();
    log_user("[SETTINGS] Re-queued applied tweaks — apply again without relaunching.\n");
}

// True only while there are tweaks applied in THIS process session (the
// in-memory applied set). It is empty on a fresh relaunch — where the queue
// already re-shows the enabled tweaks — and non-empty after an in-session apply
// emptied the queue. Drives the re-apply button's visibility: it's only useful
// while Cyanide stays open.
BOOL settings_has_reappliable_tweaks(void)
{
    NSMutableSet<NSString *> *set = settings_applied_keys_set();
    @synchronized (set) { return set.count > 0; }
}

static BOOL settings_clear_all_applied_locked(void)
{
    NSMutableSet *set = settings_applied_keys_set();
    BOOL changed = NO;
    @synchronized (set) {
        if (set.count > 0) {
            [set removeAllObjects];
            changed = YES;
        }
    }
    for (NSString *key in @[ kSettingsSBCEnabled ]) {
        if (settings_persisted_applied(key)) {
            settings_set_persisted_applied(key, NO);
            changed = YES;
        }
    }
    return changed;
}

static NSArray<NSString *> *settings_rc_backed_tweak_keys(void)
{
    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *allKeys = [NSMutableArray arrayWithArray:@[
            kSettingsSBCEnabled,
            kSettingsPowercuffEnabled,
            kSettingsDSDisableAppLibrary,
            kSettingsDSDisableIconFlyIn,
            kSettingsDSZeroWakeAnimation,
            kSettingsDSZeroBacklightFade,
            kSettingsDSDoubleTapToLock,
            kSettingsDSDragCoefficientEnabled,
            kSettingsLayoutExtrasEnabled,
        ]];
        settings_each_springboard_cleanup_entry(^(const SettingsSpringBoardTweakCleanupEntry *entry) {
            if (entry->key && ![allKeys containsObject:entry->key]) {
                [allKeys addObject:entry->key];
            }
        });
        keys = [allKeys copy];
    });
    return keys;
}

static void settings_reconcile_applied_from_defaults(void)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSString *key in settings_rc_backed_tweak_keys()) {
        if (![d boolForKey:key]) settings_mark_tweak_applied(key, NO);
    }
}

static void settings_notify_package_queue_changed_async(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:PackageQueueDidChangeNotification
                                                            object:[PackageQueue sharedQueue]];
    });
}

static NSObject *settings_rc_lock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

static NSObject *settings_bg_lock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

static uint64_t settings_now_us(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ((uint64_t)ts.tv_sec * 1000000ULL) + ((uint64_t)ts.tv_nsec / 1000ULL);
}

static void settings_apply_statbar_once_async(const char *reason);
static void settings_apply_nsbar_once_async(const char *reason);
static void settings_apply_nicebarlite_once_async(const char *reason);
static void settings_apply_labels_once_async(const char *reason);
static void settings_start_livewp_live_loop(void);
static void settings_resume_livewp_after_wake_async(const char *reason);
static void settings_pause_livewp_for_sleep_async(const char *reason);
static void settings_start_themer_live_loop(void);
static void settings_schedule_themer_repair_burst(const char *reason);
static void settings_schedule_themer_quiet_repair_burst(const char *reason);
static void settings_notify_remote_call_state_changed(void);
static void settings_notify_remote_call_state_changed_preserving_applied(BOOL preserveApplied);
static void settings_request_all_live_loops_stop(const char *reason);
static void settings_clear_hide_home_bar_respring_pending(void);

static BOOL settings_should_log_statbar_tick(NSUInteger tick) {
    // One-shot: log the very first tick so the user can see the loop took
    // off, then go silent forever. The polling continues; we just stop
    // narrating it.
    return tick == 0;
}

static useconds_t settings_live_interval(useconds_t foregroundUS, useconds_t backgroundUS)
{
    return (g_app_in_background != 0) ? backgroundUS : foregroundUS;
}

static useconds_t settings_statbar_refresh_rate_us(void)
{
    NSInteger sec = [[NSUserDefaults standardUserDefaults] integerForKey:kSettingsStatBarRefreshRateSec];
    if (sec <= 0) sec = kStatBarDefaultRefreshRateSec;
    if (sec < 1) sec = 1;
    if (sec > 30) sec = 30;
    return (useconds_t)sec * 1000000;
}

static useconds_t settings_statbar_live_interval_us(void)
{
    return settings_live_interval(kStatBarLiveIntervalUS,
                                  settings_statbar_refresh_rate_us());
}

static const char *settings_live_context(void)
{
    return (g_app_in_background != 0) ? "background" : "foreground";
}

static BOOL settings_app_state_is_foreground(void)
{
    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    return state == UIApplicationStateActive || state == UIApplicationStateInactive;
}

static NSUInteger settings_live_failure_limit(NSUInteger foregroundLimit)
{
    return (g_app_in_background != 0 || g_screen_awake == 0) ? 1 : foregroundLimit;
}

static BOOL settings_experimental_tweaks_enabled(void)
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kSettingsExperimentalTweaksEnabled];
}

static BOOL settings_stagestrip_install_allowed(void)
{
    return cyanide_experimental_tweaks_available();
}

static BOOL settings_fastlockx_lite_install_allowed(void)
{
    return cyanide_experimental_tweaks_available();
}

static NSString *settings_legacy_access_label(void)
{
    return [@"Patr" stringByAppendingString:@"eon"];
}

static void settings_purge_legacy_access_auth(void)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *legacy = settings_legacy_access_label();
    NSArray<NSString *> *keys = @[
        [@"Cyanide" stringByAppendingFormat:@"%@Linked", legacy],
        [@"Cyanide" stringByAppendingFormat:@"%@DisplayName", legacy],
        [@"Cyanide" stringByAppendingFormat:@"%@TierTitle", legacy],
        [@"Cyanide" stringByAppendingFormat:@"%@PledgeCents", legacy],
        [@"Cyanide" stringByAppendingFormat:@"%@LastRefresh", legacy],
    ];
    BOOL changed = NO;
    for (NSString *key in keys) {
        if ([defaults objectForKey:key] != nil) {
            [defaults removeObjectForKey:key];
            changed = YES;
        }
    }
    if (changed) [defaults synchronize];

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: [@"com.zeroxjf.cyanide."
            stringByAppendingString:legacy.lowercaseString],
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
}

static BOOL settings_themer_dynamic_updates_blocked_by_stage(NSUserDefaults *d)
{
    if (!settings_stagestrip_install_allowed()) return NO;
    if (![d boolForKey:kSettingsStageStripEnabled]) return NO;
    return [d boolForKey:kSettingsThemerEnabled];
}

static BOOL settings_themer_live_repair_enabled(NSUserDefaults *d)
{
    return [d boolForKey:kSettingsThemerEnabled] &&
           settings_tweak_is_applied(kSettingsThemerEnabled);
}

static BOOL settings_snowboardlite_live_repair_enabled(NSUserDefaults *d)
{
    return [d boolForKey:kSettingsSnowBoardLiteEnabled] &&
           settings_tweak_is_applied(kSettingsSnowBoardLiteEnabled);
}

static BOOL settings_icon_theme_live_repair_enabled(NSUserDefaults *d)
{
    return settings_themer_live_repair_enabled(d) ||
           settings_snowboardlite_live_repair_enabled(d);
}

static useconds_t settings_themer_live_interval_for_tick(NSUserDefaults *d, NSUInteger completedTicks)
{
    if (settings_snowboardlite_live_repair_enabled(d) &&
        completedTicks >= kThemerSnowBoardLiteInitialVisibleTicks) {
        return settings_live_interval(kThemerSnowBoardLiteSlowIntervalUS,
                                      kThemerSnowBoardLiteSlowBackgroundIntervalUS);
    }
    return settings_live_interval(kThemerLiveIntervalUS,
                                  kThemerLiveBackgroundIntervalUS);
}

static BOOL settings_themer_live_tick_should_repair_visible(NSUserDefaults *d, NSUInteger tick)
{
    (void)tick;
    return settings_snowboardlite_live_repair_enabled(d);
}

static void settings_note_themer_stage_conflict(BOOL userVisible)
{
    g_themer_live_stop_requested = 1;
    printf("[SETTINGS] Themer live icon repair paused while Dynamic Stage Lite is enabled\n");
    if (userVisible && __sync_bool_compare_and_swap(&g_themer_stage_suppression_logged, 0, 1)) {
        log_user("[COMPAT] Dynamic Stage Lite is enabled, so icon theme live repair is paused to avoid SpringBoard resprings. The selected theme still applies once; live repair resumes after Dynamic Stage is disabled.\n");
    }
}

static BOOL settings_location_sim_install_allowed(void)
{
    return YES;
}

static BOOL settings_read_screen_awake(void)
{
    BOOL haveState = NO;
    BOOL awake = YES;

    if (g_springboard_blanked_notify_token != NOTIFY_TOKEN_INVALID) {
        uint64_t state = 0;
        if (notify_get_state(g_springboard_blanked_notify_token, &state) == NOTIFY_STATUS_OK) {
            haveState = YES;
            awake = (state == 0);
        }
    }

    if (!haveState && g_display_status_notify_token != NOTIFY_TOKEN_INVALID) {
        uint64_t state = 0;
        if (notify_get_state(g_display_status_notify_token, &state) == NOTIFY_STATUS_OK) {
            awake = (state != 0);
        }
    }

    return awake;
}

static BOOL settings_screen_awake_cached(void)
{
    return g_screen_awake != 0;
}

static BOOL settings_refresh_screen_awake_state(const char *reason)
{
    BOOL awake = settings_read_screen_awake();
    int newValue = awake ? 1 : 0;
    int old = __sync_lock_test_and_set(&g_screen_awake, newValue);
    if (old != newValue) {
        printf("[SETTINGS] screen state=%s%s%s\n",
               awake ? "awake" : "asleep",
               reason ? " via " : "",
               reason ?: "");
    }
    return old == 0 && newValue != 0;
}

static BOOL settings_statbar_screen_awake(void)
{
    (void)settings_refresh_screen_awake_state(NULL);
    return settings_screen_awake_cached();
}

static BOOL settings_read_screen_locked(void)
{
    if (g_springboard_lockstate_notify_token == NOTIFY_TOKEN_INVALID) return NO;

    uint64_t state = 0;
    if (notify_get_state(g_springboard_lockstate_notify_token, &state) != NOTIFY_STATUS_OK) {
        return NO;
    }

    return state != 0;
}

static BOOL settings_screen_locked_cached(void)
{
    return g_screen_locked != 0;
}

static BOOL settings_refresh_screen_lock_state(const char *reason)
{
    BOOL locked = settings_read_screen_locked();
    int newValue = locked ? 1 : 0;
    int old = __sync_lock_test_and_set(&g_screen_locked, newValue);
    (void)__sync_lock_test_and_set(&g_screen_lock_state_logged, 1);
    return old != newValue;
}

// Detach the KRW sockets to launchd when the screen sleeps and re-make them on
// wake. This is the real sleep/wake signal for Cyanide (keep-alive keeps the app
// running through a screen lock, so applicationDidEnterBackground does NOT fire).
// Call AFTER settings_refresh_screen_awake_state has updated the cached state.
// Reattach runs synchronously so the wake re-apply (StatBar etc., which uses
// KRW) sees live fds; detach runs off-main because it stops live loops and waits.
static void settings_krw_follow_screen_transition(void)
{
    static volatile int prevAwake = -1;
    static dispatch_once_t qonce;
    static dispatch_queue_t q;
    dispatch_once(&qonce, ^{
        q = dispatch_queue_create("com.cyanide.krw.screenfollow", DISPATCH_QUEUE_SERIAL);
    });

    int now = settings_screen_awake_cached() ? 1 : 0;
    int prev = __sync_lock_test_and_set(&prevAwake, now);
    if (prev == now) return;   // no transition

    if (now == 0) {
        // Screen asleep: hand the primitive to launchd BEFORE the app suspends,
        // so it survives screen-off. Do it even on the FIRST observation
        // (prev < 0): a suspended app holding live socket fds loses the primitive
        // (setsockopt EINVAL/errno 22 on wake), and detach is idempotent.
        //
        // When NO live tweak holds the session (the Process Viewer case), detach
        // SYNCHRONOUSLY on this observer callback. The detach is fast then (park
        // + close, no loops to stop), and a dispatch_async can be left unrun:
        // iOS suspends the app on screen-lock before the background queue is
        // scheduled, so the async detach never fires and the socket dies live
        // in-process (seen in live 2.log: screen asleep 19:00:56 -> nothing ->
        // errno 22 on wake at 19:03:36). Only when live loops must be stopped
        // off-main do we defer to the queue.
        if (settings_krw_idle_detach_allowed() && remote_call_inflight_count() <= 0) {
            settings_detach_krw_for_background();   // synchronous, completes now
        } else if (settings_krw_idle_detach_allowed()) {
            // Round 25 (D): an RC op (on-demand kill warm-up / kill) is in
            // flight, so the synchronous detach would park THIS observer
            // callback — the main queue — on the detach gate for up to 4 s
            // (a warm-up holds the guard for its whole 1.4-2.5 s init;
            // round-7-class UI freeze, search bar unusable while the screen
            // transition is processed).
            // Defer to the serial queue: the gate wait is harmless there, and
            // the detach still lands before suspension in the common case
            // (warm-up is ~2 s, suspension grace is longer). If iOS suspends
            // first, the gate's 4 s bound expires and the detach is SKIPPED —
            // the SOF_NODEFUNCT-parked primitive survives in-process, which is
            // exactly the fallback the synchronous path documents above.
            printf("[SETTINGS] background: RC op in flight — deferring detach "
                   "to serial queue (main thread stays responsive)\n");
            dispatch_async(q, ^{
                if (settings_screen_awake_cached()) return;   // woke before we ran
                settings_detach_krw_for_background();
            });
        } else {
            dispatch_async(q, ^{
                if (settings_screen_awake_cached()) return;   // woke before we ran
                settings_detach_krw_for_background();
            });
        }
    } else if (prev == 0) {
        // Screen awake after a sleep we saw. (A no-op today; the next kernel
        // access re-makes the fds. Skipped on first observation.)
        settings_reattach_krw_for_foreground();
    }
}

static void settings_sync_fastlockx_lite_for_screen_state_async(const char *reason)
{
    if (!settings_fastlockx_lite_install_allowed()) return;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsFastLockXLiteEnabled] ||
        !settings_tweak_is_applied(kSettingsFastLockXLiteEnabled)) {
        return;
    }

    const char *why = reason ? reason : "screen state";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        usleep(80000); // let SpringBoard's display/lock notify states settle
        if (settings_cleanup_in_progress()) return;
        @synchronized (settings_rc_lock()) {
            if (settings_cleanup_in_progress() ||
                ![d boolForKey:kSettingsFastLockXLiteEnabled] ||
                !settings_tweak_is_applied(kSettingsFastLockXLiteEnabled)) {
                return;
            }
            (void)settings_refresh_screen_awake_state(why);
            (void)settings_refresh_screen_lock_state(why);
            BOOL awake = settings_screen_awake_cached();
            BOOL locked = settings_screen_locked_cached();
            BOOL active = !awake && locked;
            int desiredState = active ? 1 : 0;
            if (!g_springboard_rc_ready || g_settings_actions_running) {
                printf("[SETTINGS] FastLockX screen sync skipped: ready=%d actions=%d reason=%s active=%d awake=%d locked=%d\n",
                       g_springboard_rc_ready,
                       g_settings_actions_running,
                       why,
                       active,
                       awake,
                       locked);
                return;
            }
            int lastState = g_fastlockx_lite_remote_active_state;
            if (lastState == desiredState) {
                settings_maybe_nudge_fastlockx_lite_awake_locked(why, awake, locked);
                printf("[SETTINGS] FastLockX screen sync unchanged reason=%s active=%d awake=%d locked=%d\n",
                       why,
                       active,
                       awake,
                       locked);
                return;
            }
            bool ok = fastlockx_lite_set_always_on_active_in_session(active);
            __sync_lock_test_and_set(&g_fastlockx_lite_remote_active_state,
                                     ok ? desiredState : -1);
            if (ok) {
                settings_maybe_nudge_fastlockx_lite_awake_locked(why, awake, locked);
            } else {
                __sync_lock_test_and_set(&g_fastlockx_lite_last_unlock_nudge_ms, 0);
            }
            printf("[SETTINGS] FastLockX screen sync reason=%s active=%d awake=%d locked=%d ok=%d\n",
                   why,
                   active,
                   awake,
                   locked,
                   ok);
        }
    });
}

static BOOL settings_axonlite_can_poll_springboard(void)
{
    // Locked-but-awake is the lockscreen — that's where Axon must run, so the
    // lock state is intentionally not part of this predicate. Only pause while
    // the screen is fully blanked, since SB tears down the cover-sheet VCs and
    // our cached pointers would PAC-fault if we kept calling through them.
    (void)settings_refresh_screen_awake_state(NULL);
    return settings_screen_awake_cached();
}

static const char *settings_axonlite_pause_reason(void)
{
    if (!settings_screen_awake_cached()) return "screen asleep";
    return "screen unavailable";
}

static void settings_stop_axonlite_then_forget_locked(const char *reason)
{
    if (g_springboard_rc_ready) {
        bool stopped = axonlite_stop_in_session();
        printf("[SETTINGS] Axon Lite stopped before state drop%s%s result=%d\n",
               reason ? ": " : "", reason ?: "", stopped);
    }
    axonlite_forget_remote_state();
}

static void settings_forget_springboard_tweak_state_locked(void)
{
    __sync_lock_test_and_set(&g_fastlockx_lite_remote_active_state, -1);
    __sync_lock_test_and_set(&g_fastlockx_lite_last_unlock_nudge_ms, 0);
    settings_each_springboard_cleanup_entry(^(const SettingsSpringBoardTweakCleanupEntry *entry) {
        if (entry->forget) entry->forget();
    });
}

static void settings_stop_springboard_tweaks_locked(const char *reason,
                                                    BOOL springboardWillDie)
{
    if (!g_springboard_rc_ready) {
        settings_forget_springboard_tweak_state_locked();
        return;
    }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    __block NSUInteger stoppedCount = 0;
    __block NSUInteger skippedCount = 0;

    void (^stopEntry)(const SettingsSpringBoardTweakCleanupEntry *) = ^(const SettingsSpringBoardTweakCleanupEntry *entry) {
        if (!entry->stop) return;
        if (!settings_cleanup_entry_should_stop(d, entry, springboardWillDie)) {
            skippedCount++;
            return;
        }
        if (entry->requestStop) entry->requestStop();
        @try {
            bool stopped = entry->stop(springboardWillDie);
            stoppedCount++;
            printf("[SETTINGS] %s %s stop%s result=%d\n",
                   reason ?: "SpringBoard cleanup",
                   entry->name ?: "tweak",
                   springboardWillDie ? " (fast)" : "",
                   stopped);
        } @catch (NSException *e) {
            printf("[SETTINGS] %s %s cleanup exception: %s\n",
                   reason ?: "SpringBoard cleanup",
                   entry->name ?: "tweak",
                   e.reason.UTF8String);
        }
    };

    // JS runners go first: if a script has active timers/contexts, stop it
    // before any other cleanup path can race SpringBoard restart.
    settings_each_springboard_cleanup_entry(^(const SettingsSpringBoardTweakCleanupEntry *entry) {
        if (!settings_cleanup_entry_is_js_runner(entry)) return;
        stopEntry(entry);
    });

    settings_each_springboard_cleanup_entry(^(const SettingsSpringBoardTweakCleanupEntry *entry) {
        if (settings_cleanup_entry_is_js_runner(entry)) return;
        stopEntry(entry);
    });

    if (skippedCount > 0) {
        printf("[SETTINGS] %s skipped %lu inactive SpringBoard tweak stop(s)%s\n",
               reason ?: "SpringBoard cleanup",
               (unsigned long)skippedCount,
               stoppedCount == 0 ? " (nothing active)" : "");
    }

    settings_forget_springboard_tweak_state_locked();
}

static BOOL settings_disabled_applied_springboard_cleanup_needed(NSUserDefaults *d)
{
    __block BOOL needed = NO;
    settings_each_springboard_cleanup_entry(^(const SettingsSpringBoardTweakCleanupEntry *entry) {
        if (needed || !entry->key || !entry->stop) return;
        needed = ![d boolForKey:entry->key] && settings_tweak_is_applied(entry->key);
    });
    return needed;
}

static void settings_stop_disabled_applied_springboard_tweaks_locked(NSUserDefaults *d)
{
    settings_each_springboard_cleanup_entry(^(const SettingsSpringBoardTweakCleanupEntry *entry) {
        if (!entry->key || !entry->stop) return;
        if ([d boolForKey:entry->key] || !settings_tweak_is_applied(entry->key)) return;
        if (entry->requestStop) entry->requestStop();
        @try {
            bool stopped = g_springboard_rc_ready ? entry->stop(NO) : false;
            if (entry->forget) entry->forget();
            settings_mark_tweak_applied(entry->key, NO);
            printf("[SETTINGS] disabled %s cleanup result=%d\n",
                   entry->name ?: "tweak",
                   stopped);
        } @catch (NSException *e) {
            printf("[SETTINGS] disabled %s cleanup exception: %s\n",
                   entry->name ?: "tweak",
                   e.reason.UTF8String);
        }
    });
}

static void settings_handle_springboard_restart(void)
{
    // SpringBoard just (re)started. Every pointer we cached from the previous
    // SB incarnation — class addresses, selector slots, retained objects,
    // ivar offsets, the trojan thread, our shmem map — is stale. Calling
    // through any of them under SB-2 hands a wild signed function pointer to
    // BLRAA and PAC-faults us. Drop everything before the next loop tick.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL hadSession = NO;
        @synchronized (settings_rc_lock()) {
            hadSession = (g_springboard_rc_ready != 0);
            // Tell live loops to bail at their next interval check.
            settings_request_all_live_loops_stop("SpringBoard restart");
            g_springboard_rc_ready = 0;
            g_springboard_sandbox_escaped = 0;

            settings_forget_springboard_tweak_state_locked();
            if (hadSession) {
                abandon_remote_call();
            }
        }
        printf("[SETTINGS] SpringBoard restart observed; dropped RemoteCall state (hadSession=%d)\n",
               (int)hadSession);
        settings_clear_hide_home_bar_respring_pending();
        if (hadSession) {
            log_user("[APP] SpringBoard restarted; tweak sessions cleared. Hit Run to rebuild.\n");
        }
        settings_notify_remote_call_state_changed();
    });
}

static void settings_install_screen_awake_observers(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        int status = notify_register_dispatch("com.apple.springboard.hasBlankedScreen",
                                              &g_springboard_blanked_notify_token,
                                              dispatch_get_main_queue(), ^(int token) {
            (void)token;
            BOOL woke = settings_refresh_screen_awake_state("springboard.hasBlankedScreen");
            settings_krw_follow_screen_transition();
            (void)settings_refresh_screen_lock_state("springboard.hasBlankedScreen");
            settings_sync_fastlockx_lite_for_screen_state_async("springboard.hasBlankedScreen");
            if (woke) {
                settings_apply_statbar_once_async("screen awake");
                settings_apply_nsbar_once_async("screen awake");
                settings_apply_nicebarlite_once_async("screen awake");
                settings_apply_labels_once_async("screen awake");
                settings_resume_livewp_after_wake_async("screen awake");
                settings_schedule_themer_quiet_repair_burst("screen awake");
                settings_restart_gravity_motion_if_active("screen awake");
            }
        });
        if (status != NOTIFY_STATUS_OK) {
            g_springboard_blanked_notify_token = NOTIFY_TOKEN_INVALID;
        }

        status = notify_register_dispatch("com.apple.iokit.hid.displayStatus",
                                          &g_display_status_notify_token,
                                          dispatch_get_main_queue(), ^(int token) {
            (void)token;
            BOOL woke = settings_refresh_screen_awake_state("iokit.displayStatus");
            settings_krw_follow_screen_transition();
            (void)settings_refresh_screen_lock_state("iokit.displayStatus");
            settings_sync_fastlockx_lite_for_screen_state_async("iokit.displayStatus");
            if (woke) {
                settings_apply_statbar_once_async("screen awake");
                settings_apply_nsbar_once_async("screen awake");
                settings_apply_nicebarlite_once_async("screen awake");
                settings_apply_labels_once_async("display awake");
                settings_resume_livewp_after_wake_async("display awake");
                settings_schedule_themer_quiet_repair_burst("display awake");
                settings_restart_gravity_motion_if_active("display awake");
            }
        });
        if (status != NOTIFY_STATUS_OK) {
            g_display_status_notify_token = NOTIFY_TOKEN_INVALID;
        }

        status = notify_register_dispatch("com.apple.springboard.lockstate",
                                          &g_springboard_lockstate_notify_token,
                                          dispatch_get_main_queue(), ^(int token) {
            (void)token;
            BOOL changed = settings_refresh_screen_lock_state("springboard.lockstate");
            if (changed) {
                (void)settings_refresh_screen_awake_state("springboard.lockstate");
                settings_sync_fastlockx_lite_for_screen_state_async("springboard.lockstate");
            }
            if (changed && g_screen_locked) {
                // Stop the accelerometer before the XPC/shmem stack tears down on lock —
                // otherwise the next callback fires into a stale shmem mapping.
                settings_stop_gravity_motion();
                gravitylite_forget_remote_state();
            }
        });
        if (status != NOTIFY_STATUS_OK) {
            g_springboard_lockstate_notify_token = NOTIFY_TOKEN_INVALID;
        }

        // Darwin notify fires when SpringBoard finishes its boot/respawn.
        // Either we just launched and SB is fine (cleanup is a no-op against
        // already-zero state) or SB crashed under us and we MUST drop every
        // cached pointer before the live loops fire again into SB-2.
        status = notify_register_dispatch("com.apple.springboard.finishedstartup",
                                          &g_springboard_finished_startup_notify_token,
                                          dispatch_get_main_queue(), ^(int token) {
            (void)token;
            settings_handle_springboard_restart();
        });
        if (status != NOTIFY_STATUS_OK) {
            g_springboard_finished_startup_notify_token = NOTIFY_TOKEN_INVALID;
        }

        status = notify_register_dispatch("com.apple.springboard.applicationStateChanged",
                                          &g_springboard_app_state_notify_token,
                                          dispatch_get_main_queue(), ^(int token) {
            uint64_t state = 0;
            (void)notify_get_state(token, &state);
            printf("[SETTINGS] springboard application state notify state=%llu\n",
                   (unsigned long long)state);
            settings_schedule_themer_repair_burst("springboard app state changed");
        });
        if (status != NOTIFY_STATUS_OK) {
            g_springboard_app_state_notify_token = NOTIFY_TOKEN_INVALID;
        }

        status = notify_register_dispatch("com.apple.springboard.frontmostApplicationChanged",
                                          &g_springboard_frontmost_notify_token,
                                          dispatch_get_main_queue(), ^(int token) {
            uint64_t state = 0;
            (void)notify_get_state(token, &state);
            printf("[SETTINGS] springboard frontmost app notify state=%llu\n",
                   (unsigned long long)state);
            settings_schedule_themer_repair_burst("springboard frontmost changed");
        });
        if (status != NOTIFY_STATUS_OK) {
            g_springboard_frontmost_notify_token = NOTIFY_TOKEN_INVALID;
        }

        // If the live loop tripped its 3-failure exit during a background
        // window, the screen-wake darwin notifications won't fire (the screen
        // never blanked) and the loop stays dead. Re-arm on app foreground.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            (void)note;
            // Re-make the KRW fds from launchd if we detached them on background,
            // before anything tries to use the primitive again.
            settings_reattach_krw_for_foreground();
            (void)settings_refresh_screen_awake_state("app became active");
            settings_apply_statbar_once_async("app became active");
            settings_schedule_themer_quiet_repair_burst("app became active");
        }];

        (void)settings_refresh_screen_awake_state("startup");
        (void)settings_refresh_screen_lock_state("startup");
    });
}

static void settings_end_statbar_background_task_async(const char *reason)
{
    void (^endTask)(void) = ^{
        @synchronized (settings_bg_lock()) {
            if (g_statbar_bg_task == UIBackgroundTaskInvalid) return;
            UIBackgroundTaskIdentifier task = g_statbar_bg_task;
            g_statbar_bg_task = UIBackgroundTaskInvalid;
            [[UIApplication sharedApplication] endBackgroundTask:task];
            printf("[SETTINGS] StatBar background task ended%s%s\n",
                   reason ? ": " : "", reason ?: "");
        }
    };

    if ([NSThread isMainThread]) {
        endTask();
    } else {
        dispatch_async(dispatch_get_main_queue(), endTask);
    }
}

// Bridge the foreground -> background transition with a short explicit
// UIBackgroundTask. DSKeepAlive's audio background mode carries the ongoing
// live feed; holding a UIBackgroundTask indefinitely trips UIKit's 30s watchdog
// warning and can get the app terminated.
static void settings_begin_statbar_background_task_async(const char *reason)
{
    void (^beginTask)(void) = ^{
        @synchronized (settings_bg_lock()) {
            if (g_statbar_bg_task != UIBackgroundTaskInvalid) return;
            UIApplication *app = [UIApplication sharedApplication];
            __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
            task = [app beginBackgroundTaskWithName:@"cyanide.statbar.live"
                                  expirationHandler:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    @synchronized (settings_bg_lock()) {
                        if (g_statbar_bg_task != task) return;
                        g_statbar_bg_task = UIBackgroundTaskInvalid;
                        [[UIApplication sharedApplication] endBackgroundTask:task];
                        printf("[SETTINGS] StatBar background task expired by iOS; live loop may pause\n");
                    }
                });
            }];
            if (task == UIBackgroundTaskInvalid) {
                printf("[SETTINGS] StatBar background task could not be acquired%s%s\n",
                       reason ? ": " : "", reason ?: "");
                return;
            }
            g_statbar_bg_task = task;
            printf("[SETTINGS] StatBar background task acquired id=%lu%s%s\n",
                   (unsigned long)task,
                   reason ? ": " : "", reason ?: "");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         kLiveBackgroundTaskGraceSeconds * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                @synchronized (settings_bg_lock()) {
                    if (g_statbar_bg_task != task) return;
                    g_statbar_bg_task = UIBackgroundTaskInvalid;
                    [[UIApplication sharedApplication] endBackgroundTask:task];
                    printf("[SETTINGS] StatBar background task ended: transition grace elapsed; keepAlive=%d\n",
                           ds_keepalive_is_running());
                }
            });
        }
    };

    if ([NSThread isMainThread]) {
        beginTask();
    } else {
        dispatch_sync(dispatch_get_main_queue(), beginTask);
    }
}

// ---- Round 40: safe-detach window around the backgrounding teardown ---------
// The hijack teardown on background restores launchd's threads and parks KRW.
// It runs SYNCHRONOUSLY in didEnterBackground and completes before iOS can
// suspend us (iOS waits for didEnterBackground to return) — that part is fine.
// What is NOT covered: after the teardown returns, one of Cyanide's OWN RemoteCall
// helper threads can still be mid-trap in the kernel (a set_exception_ports /
// MIG call that has not returned). If iOS suspends us with such a thread live,
// the process cannot fully exit → un-reaped corpse → black screen on reopen
// (live 41, 08:51:59: clean teardown, yet no `main: entry` on reopen = corpse).
//
// Fix: hold a UIBackgroundTask assertion ACROSS the teardown and then, on a
// background queue, WAIT (bounded) for every in-flight RemoteCall op to drain
// (remote_call_inflight_count()==0 && no warm-up) before releasing it — giving
// a slow-but-not-deadlocked helper the scheduling time to return so the process
// can exit cleanly. This is passive (it only POLLS the count; it never touches
// shared RC/KRW state), so it cannot recreate the round-32 teardown↔foreground
// freeze. If the wait times out, the op is genuinely wedged in-kernel (the
// irreducible floor) and we release anyway — no worse than before.
static UIBackgroundTaskIdentifier g_safe_detach_task = (UIBackgroundTaskIdentifier)-1;
static volatile int g_safe_detach_in_flight = 0;

static UIBackgroundTaskIdentifier settings_safe_detach_begin(const char *reason)
{
    UIApplication *app = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    task = [app beginBackgroundTaskWithName:@"cyanide.safe-detach"
                          expirationHandler:^{
        @synchronized (settings_bg_lock()) {
            if (task != UIBackgroundTaskInvalid && g_safe_detach_task == task) {
                printf("[SETTINGS] safe-detach: background task EXPIRED by iOS — "
                       "an in-flight RemoteCall op did not drain in time (wedged "
                       "in-kernel); releasing the assertion\n");
                [[UIApplication sharedApplication] endBackgroundTask:task];
                g_safe_detach_task = UIBackgroundTaskInvalid;
                __sync_lock_release(&g_safe_detach_in_flight);
            }
        }
    }];
    if (task == UIBackgroundTaskInvalid) {
        printf("[SETTINGS] safe-detach: background task unavailable (%s) — teardown "
               "runs without an extended window\n", reason ?: "backgrounding");
        return UIBackgroundTaskInvalid;
    }
    @synchronized (settings_bg_lock()) { g_safe_detach_task = task; }
    __sync_lock_test_and_set(&g_safe_detach_in_flight, 1);
    printf("[SETTINGS] safe-detach: window open id=%lu (%s)\n",
           (unsigned long)task, reason ?: "backgrounding");
    return task;
}

// Release the window after the in-flight RemoteCall ops have drained (so we do
// not suspend with a Cyanide helper thread mid-trap). Runs the drain-wait on a
// background queue; the assertion keeps us alive meanwhile.
static void locsvc_switcher_note_safe(BOOL clean);   // location shortcut, below

static void settings_safe_detach_drain_and_end(UIBackgroundTaskIdentifier task,
                                               const char *reason)
{
    if (task == UIBackgroundTaskInvalid) {
        __sync_lock_release(&g_safe_detach_in_flight);
        // No assertion was taken, so nothing was drained: not a confirmed safe point.
        locsvc_switcher_note_safe(NO);
        return;
    }
    const char *why = reason ?: "backgrounding";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const uint64_t deadlineNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
                                  + 8ULL * 1000000000ULL;   // 8 s bound
        int waited = 0;
        // Round 41: also wait on the tro-dance helper liveness count. The
        // round-40 drain polled only remote_call_inflight_count() — but a
        // helper wedged in-kernel (the 184716 ABBA class) is invisible to
        // that count (guard ops only), so the window could be released with
        // a Cyanide thread parked in-kernel: the exact un-reaped-corpse
        // shape this drain exists to prevent.
        while (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) < deadlineNs) {
            if (remote_call_inflight_count() == 0 &&
                remote_call_helper_unaccounted_count() == 0)
                break;
            usleep(100000);   // 100 ms
            waited++;
        }
        if (remote_call_helper_unaccounted_count() != 0) {
            printf("[SETTINGS] safe-detach: tro-dance helper WEDGED in-kernel "
                   "(unaccounted=%d, %s) — process must not exit; a corpse "
                   "would wedge on reopen\n",
                   remote_call_helper_unaccounted_count(), why);
            log_user("[WARN] Cyanide cannot safely exit — a kernel call is "
                     "stuck; keep the app open or reboot soon.\n");
        }
        if (remote_call_inflight_count() != 0)
            printf("[SETTINGS] safe-detach: in-flight RemoteCall op STILL live after "
                   "%d ms (%s) — wedged in-kernel; releasing window anyway\n",
                   waited * 100, why);
        else if (waited)
            printf("[SETTINGS] safe-detach: in-flight ops drained after %d ms (%s)\n",
                   waited * 100, why);
        // The location shortcut's measurement point: the toggle's teardown,
        // the background teardown/hand-off and this drain are all done.
        locsvc_switcher_note_safe(remote_call_inflight_count() == 0 &&
                                  remote_call_helper_unaccounted_count() == 0);
        @synchronized (settings_bg_lock()) {
            if (g_safe_detach_task == task) {
                [[UIApplication sharedApplication] endBackgroundTask:task];
                g_safe_detach_task = UIBackgroundTaskInvalid;
            }
        }
        __sync_lock_release(&g_safe_detach_in_flight);
    });
}

static void settings_notify_remote_call_state_changed(void)
{
    settings_notify_remote_call_state_changed_preserving_applied(NO);
}

static void settings_notify_remote_call_state_changed_preserving_applied(BOOL preserveApplied)
{
    BOOL ready = (g_springboard_rc_ready != 0);
    BOOL cleared = NO;
    if (!ready && !preserveApplied) {
        cleared = settings_clear_all_applied_locked();
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kSettingsRemoteCallStateDidChangeNotification
                                                            object:nil];
        if (cleared) {
            [[NSNotificationCenter defaultCenter] postNotificationName:PackageQueueDidChangeNotification
                                                                object:[PackageQueue sharedQueue]];
            [[NSNotificationCenter defaultCenter] postNotificationName:kSettingsActionsDidCompleteNotification
                                                                object:nil];
        }
    });
}

static BOOL settings_cleanup_in_progress(void)
{
    return g_settings_cleanup_running != 0 ||
           g_settings_respring_cleanup_running != 0;
}

static void settings_request_all_live_loops_stop(const char *reason)
{
    settings_each_springboard_cleanup_entry(^(const SettingsSpringBoardTweakCleanupEntry *entry) {
        if (entry->requestStop) entry->requestStop();
    });
    if (reason) {
        printf("[SETTINGS] requested all live RemoteCall loops stop: %s\n", reason);
    }
}

static BOOL settings_has_active_termination_live_tweak(void)
{
    if (settings_any_registered_live_loop_running()) {
        return YES;
    }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    __block BOOL active = NO;
    settings_each_springboard_cleanup_entry(^(const SettingsSpringBoardTweakCleanupEntry *entry) {
        if (active || !entry->cleanupOnTermination || !entry->key) return;
        active = [d boolForKey:entry->key] && settings_tweak_is_applied(entry->key);
    });
    return active;
}

static BOOL settings_has_persistent_springboard_remote_call_user(void)
{
    if (settings_has_active_termination_live_tweak()) {
        return YES;
    }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    __block BOOL active = NO;
    settings_each_springboard_cleanup_entry(^(const SettingsSpringBoardTweakCleanupEntry *entry) {
        if (active || !entry->keepsSpringBoardSession || !entry->key) return;
        active = [d boolForKey:entry->key] && settings_tweak_is_applied(entry->key);
    });
    return active;
}

static void settings_wait_live_loops_stopped_for_switch(const char *reason)
{
    uint64_t startUS = settings_now_us();
    BOOL logged = NO;
    while (settings_any_registered_live_loop_running()) {
        uint64_t nowUS = settings_now_us();
        uint64_t elapsedUS = (startUS != 0 && nowUS >= startUS) ? nowUS - startUS : 0;
        if (!logged) {
            printf("[SETTINGS] waiting for live RemoteCall loops to stop%s%s\n",
                   reason ? ": " : "", reason ?: "");
            logged = YES;
        }
        if (elapsedUS >= 2000000ULL) {
            NSString *status = settings_registered_live_loop_status_string();
            printf("[SETTINGS] live loop stop wait timed out%s%s %s\n",
                   reason ? ": " : "", reason ?: "",
                   status.UTF8String);
            break;
        }
        usleep(50000);
    }
    if (logged && !settings_any_registered_live_loop_running()) {
        printf("[SETTINGS] live RemoteCall loops stopped%s%s\n",
               reason ? ": " : "", reason ?: "");
    }
}

static void settings_live_loop_sleep_interruptible(uint64_t targetUS,
                                                  useconds_t fallbackUS,
                                                  volatile int *stopFlag)
{
    uint64_t sleptFallbackUS = 0;
    while (!settings_cleanup_in_progress() && (!stopFlag || *stopFlag == 0)) {
        uint64_t nowUS = settings_now_us();
        uint64_t remainingUS = 0;
        if (targetUS != 0 && nowUS != 0 && nowUS < targetUS) {
            remainingUS = targetUS - nowUS;
        } else if (targetUS == 0 && sleptFallbackUS < fallbackUS) {
            remainingUS = (uint64_t)fallbackUS - sleptFallbackUS;
        } else {
            break;
        }

        useconds_t chunkUS = (useconds_t)(remainingUS < 100000ULL ? remainingUS : 100000ULL);
        if (chunkUS == 0) break;
        usleep(chunkUS);
        if (targetUS == 0) sleptFallbackUS += chunkUS;
    }
}

static UIViewController *settings_top_view_controller(UIViewController *vc)
{
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:UINavigationController.class]) {
        return settings_top_view_controller(((UINavigationController *)vc).visibleViewController);
    }
    if ([vc isKindOfClass:UITabBarController.class]) {
        return settings_top_view_controller(((UITabBarController *)vc).selectedViewController);
    }
    return vc;
}

static UIViewController *settings_active_presenter(UIViewController *fallback)
{
    if (fallback.view.window) return settings_top_view_controller(fallback);

    UIWindow *candidate = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState != UISceneActivationStateForegroundActive &&
            ws.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }
        for (UIWindow *window in ws.windows) {
            if (window.isKeyWindow) {
                candidate = window;
                break;
            }
            if (!candidate && !window.hidden && window.rootViewController) {
                candidate = window;
            }
        }
        if (candidate) break;
    }

    return settings_top_view_controller(candidate.rootViewController ?: fallback);
}

static UIWindow *settings_active_window(UIViewController *fallback)
{
    if (fallback.view.window) return fallback.view.window;

    UIWindow *candidate = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState != UISceneActivationStateForegroundActive &&
            ws.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }
        for (UIWindow *window in ws.windows) {
            if (window.isKeyWindow) return window;
            if (!candidate && !window.hidden && window.rootViewController) {
                candidate = window;
            }
        }
    }
    return candidate;
}

static void settings_present_controller(UIViewController *controller, UIViewController *fallback)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = settings_active_presenter(fallback);
        if (!presenter) {
            printf("[SETTINGS] presentation skipped: no attached presenter\n");
            return;
        }
        [presenter presentViewController:controller animated:YES completion:nil];
    });
}

static void settings_show_respring_overlay(UIViewController *fallback)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = settings_active_window(fallback);
        if (!window) {
            printf("[RESPRING] overlay skipped: no active window\n");
            return;
        }
        DSRespringOverlayView *overlay = [[DSRespringOverlayView alloc] initWithFrame:window.bounds];
        [window addSubview:overlay];
        [overlay loadRespringPayload];
    });
}

static NSArray<NSString *> *powercuff_levels(void) {
    return @[ @"off", @"nominal", @"light", @"moderate", @"heavy" ];
}

// The window tint is the real accent colour: while a modal (the activity log)
// is up, the settings view is dimmed and self.view.tintColor returns a grey.
// That grey is a concrete UIColor, so once it is written into a cell it stays
// there after the modal closes — the buttons looked disabled until the cell
// was rebuilt. Reading the tint off the window avoids the dimmed value.
static UIColor *settings_cell_tint_color(UIView *view)
{
    // UIColor.tintColor is dynamic: UIKit resolves it against the tint of the
    // view it is drawn in, at draw time. Reading self.view.tintColor instead
    // freezes a concrete value — and while a modal (the activity log) dims the
    // panel, that value is a desaturated grey, which then stayed on the cell
    // after the modal closed. A dynamic colour also survives a reload that
    // happens while the dim is still up.
    if (@available(iOS 15.0, *)) return UIColor.tintColor;
    return view.window.tintColor ?: view.tintColor;
}

// The import mode lives on the picker instance, not on the controller: several
// pickers share this delegate, so a mode stored on the controller could leak
// from one sheet into the next. Associating it also means there is nothing to
// clean up — the mode dies with the picker.
static const void *kSettingsPickerModeKey = &kSettingsPickerModeKey;

static void settings_set_picker_mode(UIDocumentPickerViewController *picker, NSString *mode)
{
    if (!picker) return;
    objc_setAssociatedObject(picker, kSettingsPickerModeKey, mode, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static NSString *settings_picker_mode(UIDocumentPickerViewController *picker)
{
    if (!picker) return nil;
    return objc_getAssociatedObject(picker, kSettingsPickerModeKey);
}

static NSComparisonResult settings_compare_system_version(NSString *target)
{
    NSString *version = UIDevice.currentDevice.systemVersion ?: @"0";
    return [version compare:target options:NSNumericSearch];
}

BOOL settings_device_supported(void)
{
#if CYANIDE_VPHONE_DEBUG
    return YES;
#endif

    // iPhone 17 and newer (A19 / A19 Pro) and the M5 iPad Pro: Memory Integrity
    // Enforcement blocks the exploit, so refuse up front rather than failing
    // later with no explanation.
    if (is_unsupported_new_device()) return NO;

    BOOL ios17to18 =
        settings_compare_system_version(@"17.0") != NSOrderedAscending &&
        settings_compare_system_version(@"18.7.1") != NSOrderedDescending;

    BOOL ios26 =
        settings_compare_system_version(@"26.0") != NSOrderedAscending &&
        settings_compare_system_version(@"26.0.1") != NSOrderedDescending;

    return ios17to18 || ios26;
}

static NSString *settings_unsupported_message(void)
{
    NSString *version = UIDevice.currentDevice.systemVersion ?: @"unknown";
#if CYANIDE_VPHONE_DEBUG
    return [NSString stringWithFormat:@"VPhone debug build is bypassing Cyanide's iOS version gate on iOS %@.", version];
#endif
    if (is_unsupported_new_device()) {
        return @"Not supported on this device: Memory Integrity Enforcement "
                "(iPhone 17 and newer, M5 iPad Pro) blocks the kernel exploit "
                "this relies on.";
    }
    return [NSString stringWithFormat:@"Not supported on iOS %@. Supported: iOS/iPadOS 17.0-18.7.1 or 26.0-26.0.1.", version];
}

// Stage timing for the apply log. Each settings_progress() closes the previous
// stage and logs its wall time, RemoteCalls (all callers), synchronous
// main-thread dispatches with the time blocked in them, and settle sleep.
// Only the actions thread uses these (one run at a time).
static uint64_t g_stage_t0_ns = 0;
static RPerfSnapshot g_stage_perf0;
static char g_stage_name[96];

static void settings_log_perf_delta(const char *label, uint64_t t0Ns, const RPerfSnapshot *p0)
{
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    RPerfSnapshot p1;
    r_perf_snapshot(&p1);
    log_user("      [TIME] %s: %.2fs, %llu remote calls, %llu main-thread (%.2fs blocked), %.2fs settle sleep\n",
             label, (double)(now - t0Ns) / 1e9,
             (unsigned long long)(p1.rcCalls - p0->rcCalls),
             (unsigned long long)(p1.mainCalls - p0->mainCalls),
             (double)(p1.mainWaitUS - p0->mainWaitUS) / 1e6,
             (double)(p1.settleSleptUS - p0->settleSleptUS) / 1e6);
}

static void settings_stage_close(void)
{
    if (!g_stage_t0_ns) return;
    settings_log_perf_delta(g_stage_name, g_stage_t0_ns, &g_stage_perf0);
    g_stage_t0_ns = 0;
}

static void settings_stage_open(const char *name)
{
    settings_stage_close();
    strlcpy(g_stage_name, name ?: "", sizeof(g_stage_name));
    r_perf_snapshot(&g_stage_perf0);
    g_stage_t0_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}

static void settings_progress(NSUInteger *step, NSUInteger total, const char *message)
{
    if (!step || !message) return;
    settings_stage_open(message);
    (*step)++;
    log_user("[RUN %lu/%lu] %s\n",
             (unsigned long)*step,
             (unsigned long)total,
             message);
}

// A main-queue heartbeat for long, blocking apply steps. Some steps park the
// background actions thread inside a single synchronous RemoteCall for several
// seconds — most notably HSSCALE, whose first -setIconImageInfo: waits ~5s behind
// SpringBoard's post-arrange grid relayout. During that call the actions thread
// can't emit anything, so the log screen looks frozen. This timer runs on the
// main thread (which stays free — the blocked thread is SpringBoard's, in another
// process) and logs an elapsed-time line every second so the user sees progress.
// The first tick is at +1s, so steps that finish quickly produce no heartbeat.
//
// A step that can report real progress calls settings_apply_heartbeat_update()
// with the new text: it is logged at once and mirrored to the progress
// screen's status line, and the elapsed-time tick only resumes (counting from
// that update) when the step then goes quiet for a second or more.
NSString * const kSettingsApplyStatusDidChangeNotification = @"SettingsApplyStatusDidChangeNotification";
NSString * const kSettingsApplyStatusTextKey = @"text";

static dispatch_source_t g_apply_heartbeat_timer;   // main-queue only
static NSTimeInterval     g_apply_heartbeat_since;  // when the label was set
static NSTimeInterval     g_apply_heartbeat_last;   // last line logged
static NSString          *g_apply_heartbeat_label;

static void settings_post_apply_status(NSString *text)   // main queue
{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kSettingsApplyStatusDidChangeNotification
                      object:nil
                    userInfo:text ? @{ kSettingsApplyStatusTextKey: text } : nil];
}

static void settings_apply_heartbeat_start(NSString *label)
{
    NSString *msg = label.length ? label : @"Working";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_apply_heartbeat_timer) return;   // one at a time
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        g_apply_heartbeat_since = now;
        g_apply_heartbeat_last = now;
        g_apply_heartbeat_label = msg;
        settings_post_apply_status(msg);
        dispatch_source_t t = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
            (uint64_t)(1.0 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(t, ^{
            NSTimeInterval tick = [NSDate timeIntervalSinceReferenceDate];
            if (tick - g_apply_heartbeat_last < 0.95) return;
            g_apply_heartbeat_last = tick;
            int secs = (int)(tick - g_apply_heartbeat_since + 0.5);
            log_user("      … %s (%ds)\n", g_apply_heartbeat_label.UTF8String, secs);
            settings_post_apply_status([NSString stringWithFormat:@"%@ (%ds)", g_apply_heartbeat_label, secs]);
        });
        g_apply_heartbeat_timer = t;
        dispatch_resume(t);
    });
}

static void settings_apply_heartbeat_update(NSString *label)
{
    if (!label.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_apply_heartbeat_timer) return;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        g_apply_heartbeat_since = now;
        g_apply_heartbeat_last = now;
        g_apply_heartbeat_label = label;
        log_user("      %s\n", label.UTF8String);
        settings_post_apply_status(label);
    });
}

static void settings_apply_heartbeat_stop(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_apply_heartbeat_timer) return;
        dispatch_source_cancel(g_apply_heartbeat_timer);
        g_apply_heartbeat_timer = nil;
        g_apply_heartbeat_label = nil;
        settings_post_apply_status(nil);   // back to the default status line
    });
}

static BOOL settings_try_claim_actions_lock(const char *owner, const char *busyMessage)
{
    if (__sync_lock_test_and_set(&g_settings_actions_running, 1)) {
        printf("[SETTINGS] %s blocked: actions already running\n",
               owner ?: "action");
        if (busyMessage) log_user("%s\n", busyMessage);
        return NO;
    }
    return YES;
}

static void settings_release_actions_lock(void)
{
    __sync_lock_release(&g_settings_actions_running);
}

static NSString *settings_bundle_string(NSString *key, NSString *fallback)
{
    id value = [NSBundle mainBundle].infoDictionary[key];
    if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0) {
        return value;
    }
    return fallback;
}

static NSString *settings_app_version_string(void)
{
    return settings_bundle_string(@"CFBundleShortVersionString", @"unknown");
}

static NSString *settings_app_build_string(void)
{
    return settings_bundle_string(@"CFBundleVersion", @"unknown");
}

static void settings_log_run_context(void)
{
}

static BOOL settings_ensure_kexploit(void)
{
    if (!settings_wait_for_pending_switcher_removal()) return NO;
    if (!settings_device_supported()) {
        printf("[SETTINGS] unsupported device: %s\n", settings_unsupported_message().UTF8String);
        return NO;
    }

    if (g_kexploit_done) {
        if (kexploit_krw_ready()) {
            log_user("[KRW] Reusing the live app KRW session; no exploit rerun needed.\n");
            return YES;
        }
        printf("[SETTINGS] cached KRW is stale; clearing RemoteCall state and recovering\n");
        log_user("[KRW] Cached app KRW failed validation; clearing RemoteCall state and trying recovery.\n");
        g_kexploit_done = NO;
        g_springboard_rc_ready = 0;
        g_springboard_sandbox_escaped = 0;
        kutils_reset_self_cache();
        settings_notify_remote_call_state_changed();
    }

    int res = kexploit_opa334();
    if (res != 0) {
        printf("[SETTINGS] kexploit_opa334 failed: %d\n", res);
        return NO;
    }
    g_kexploit_done = YES;
    settings_notify_remote_call_state_changed();
    return YES;
}

// True when a KRW session can be had without running the exploit: one is
// already live in this process, or a parked primitive is on disk for this
// boot. Cheap on purpose (no kernel round-trip, no I/O beyond NSUserDefaults)
// so cellForRowAtIndexPath can ask on every reload.
static BOOL settings_krw_available_without_exploit(void)
{
    if (g_kexploit_done && kexploit_krw_session_active()) return YES;
    return krw_persistence_has_saved_recovery();
}

// settings_ensure_kexploit() for read-only actions.
//
// Recovers a parked session, but refuses to run a fresh exploit chain. The
// plain version acquires KRW by whatever means necessary, which turned a
// "Read Current Value" tap into a full A18 chain run and panicked the device
// on 2026-09-16 12:01 (same aperture signature as the other 14, 2.5 GB
// footprint from the live staging mapping). A query must never cost that.
static BOOL settings_ensure_kexploit_for_read(void)
{
    if (!settings_wait_for_pending_switcher_removal()) return NO;
    // Round 31: trace the parked-KRW restore boundaries — this is the one
    // launch-adjacent path that talks to the launchd-anchored primitive, and
    // it must never wedge the caller without a trace of where it stopped.
    cyanide_launch_trace("ensure_kexploit_for_read: entry");
    if (!settings_device_supported()) {
        printf("[SETTINGS] unsupported device: %s\n", settings_unsupported_message().UTF8String);
        return NO;
    }

    if (g_kexploit_done) {
        if (kexploit_krw_ready()) return YES;
        printf("[SETTINGS] cached KRW is stale; read-only action will not re-exploit\n");
        g_kexploit_done = NO;
        g_springboard_rc_ready = 0;
        g_springboard_sandbox_escaped = 0;
        kutils_reset_self_cache();
        settings_notify_remote_call_state_changed();
    }

    cyanide_launch_trace("recover_only: entry");
    int recoverRC = kexploit_opa334_recover_only();
    cyanide_launch_trace(recoverRC == 0 ? "recover_only: exit ok"
                                        : "recover_only: exit none");
    if (recoverRC != 0) {
        printf("[SETTINGS] read-only action: no parked session to recover; not re-exploiting\n");
        return NO;
    }
    g_kexploit_done = YES;
    settings_notify_remote_call_state_changed();
    return YES;
}

static BOOL settings_device_is_a18_above(void)
{
    static BOOL result = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t cpuFamily = 0;
        size_t len = sizeof(cpuFamily);
        if (sysctlbyname("hw.cpufamily", &cpuFamily, &len, NULL, 0) != 0) return;
        result = (cpuFamily == CPUFAMILY_ARM_TUPAI ||
                  cpuFamily == CPUFAMILY_ARM_TAHITI ||
                  cpuFamily == CPUFAMILY_ARM_DONAN);
    });
    return result;
}

BOOL settings_device_is_a18_family(void)
{
    return settings_device_is_a18_above();
}

static BOOL settings_nano_load_override_enabled(void)
{
    if (!settings_device_supported()) return NO;
    return krw_persistence_launchd_holds_krw() || krw_persistence_has_saved_recovery();
}

static BOOL settings_ensure_kexploit_recovery_only(void)
{
    if (!settings_wait_for_pending_switcher_removal()) return NO;
    if (!settings_device_supported()) {
        printf("[SETTINGS] unsupported device: %s\n", settings_unsupported_message().UTF8String);
        return NO;
    }

    if (g_kexploit_done) {
        if (kexploit_krw_ready() && krw_persistence_launchd_holds_krw()) {
            log_user("[KRW] Reusing parked/recovered KRW for NanoRegistry load.\n");
            return YES;
        }
        log_user("[KRW] NanoRegistry load requires parked KRW recovery; live state is not eligible.\n");
        return NO;
    }

    if (!krw_persistence_has_saved_recovery()) {
        log_user("[KRW] NanoRegistry load disabled: no parked KRW recovery state is saved.\n");
        return NO;
    }

    log_user("[KRW] NanoRegistry load: attempting parked recovery only; fresh spray is disabled for this button.\n");
    if (!krw_persistence_recover()) {
        log_user("[KRW] NanoRegistry load failed: parked KRW recovery was not available.\n");
        return NO;
    }

    g_kexploit_done = YES;
    settings_notify_remote_call_state_changed();
    return YES;
}

static BOOL settings_ensure_springboard_remote_call_locked(void)
{
    r_settle_set_mode((int)[[NSUserDefaults standardUserDefaults] integerForKey:kSettingsRemoteSettleMode]);
    if (g_springboard_rc_ready) {
        printf("[SETTINGS] reusing SpringBoard RemoteCall session\n");
        return YES;
    }

    // Round 35: a FRESH hijack must wait out the activation settle window. Arming
    // (set_exception_ports → AMFI global entitlement lock) while runningboardd /
    // PerfPowerServices run task_policy_set on our task at launch/activation is
    // an ABBA deadlock → 90 s watchdog (panic 235811). Only this first
    // establishment after an activation waits; the reuse path above and any
    // later user action (window already elapsed) are unaffected. Interruptible:
    // bail immediately on backgrounding/cleanup so we never hold across suspend.
    //
    // Round 41: the wait must NOT hold settings_rc_lock() — pre-41 this loop
    // uslept up to the full window with the lock held, serializing every other
    // SpringBoard-channel caller behind a multi-second sleep. Drop the lock
    // for the wait (objc_sync_exit/enter balances the caller's @synchronized
    // on the same recursive lock — all four call sites enter this function
    // via @synchronized (settings_rc_lock())), then re-acquire and
    // RE-VALIDATE: a concurrent caller may have opened the session while we
    // waited, or a re-activation may have re-extended the window.
    uint64_t settleUntil = g_activation_settle_until_ns;
    uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (settleUntil > nowNs) {
        printf("[SETTINGS] SpringBoard hijack deferred ~%llu ms — waiting out the "
               "launch/activation settle window (runningboardd task_policy_set "
               "ABBA avoidance; lock DROPPED for the wait)\n",
               (unsigned long long)((settleUntil - nowNs) / 1000000ULL));
        NSObject *rcLock = settings_rc_lock();
        // Round 42 guard: this exit/enter pair is only correct if the caller
        // holds @synchronized (settings_rc_lock()) at EXACTLY ONE nesting
        // level (verified for all four call sites: settings_apply_lock_screen_
        // duration_body, settings_read_lock_screen_duration, the tweak-run
        // "Opening SpringBoard injection channel" step, and the FastLockX
        // request). Zero levels → objc_sync_exit on an unheld lock (undefined);
        // two+ levels → one level stays held across the wait (reintroduces the
        // serialization this fixes). objc-sync exposes no recursion count, so
        // there is no cheap runtime assertion — if you add a call site, keep
        // the single-level invariant or refactor this.
        objc_sync_exit(rcLock);
        BOOL aborted = NO;
        while ((nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) < settleUntil) {
            if (g_app_in_background || settings_cleanup_in_progress() ||
                excport_gate_blocked()) {
                printf("[SETTINGS] SpringBoard hijack settle-wait aborted — app "
                       "backgrounding/cleanup; not arming now\n");
                aborted = YES;
                break;
            }
            usleep(100000);   // 100 ms, re-checking the bail conditions
        }
        objc_sync_enter(rcLock);
        if (aborted)
            return NO;
        // Re-validate after re-acquire (the world moved while we waited):
        if (g_springboard_rc_ready) {
            printf("[SETTINGS] SpringBoard session opened by another caller "
                   "during our settle wait — reusing it\n");
            return YES;
        }
        if (g_activation_settle_until_ns > clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) {
            printf("[SETTINGS] activation settle window RE-EXTENDED during our "
                   "wait (re-activation) — refusing to arm now; caller may retry\n");
            return NO;
        }
        printf("[SETTINGS] activation settle window elapsed — proceeding with "
               "SpringBoard hijack\n");
    }

    if (g_springboard_connect_progress) g_springboard_connect_progress();
    for (int attempt = 1; attempt <= kSettingsSpringBoardRCMaxAttempts; attempt++) {
        int timeoutMS = (attempt == 1) ? kSettingsSpringBoardRCFirstExceptionTimeoutMS
                                       : kSettingsSpringBoardRCRetryTimeoutMS;
        // Cap the SpringBoard arm surface at 3 threads (default is 6). The
        // one-shot is consumed by the matching init, so re-set it every
        // attempt. Fewer armed SpringBoard threads = fewer threads that can
        // park on our exception port if the init wedges (125410 watchdog);
        // the min-over-threads first trap still lands in ~1 s.
        remote_call_set_next_init_target_threads("SpringBoard", 3);
        if (init_remote_call_with_first_exception_timeout("SpringBoard",
                                                          false,
                                                          timeoutMS) == 0) {
            g_springboard_rc_ready = 1;
            g_springboard_sandbox_escaped = 0;
            settings_notify_remote_call_state_changed();
            return YES;
        }
        printf("[SETTINGS] init_remote_call(SpringBoard) attempt %d/%d failed (timeout=%dms)\n",
               attempt, kSettingsSpringBoardRCMaxAttempts, timeoutMS);
        if (attempt < kSettingsSpringBoardRCMaxAttempts) {
            log_user("[SESSION] SpringBoard channel didn't open yet — retrying...\n");
            usleep(500000);   // brief settle before re-injecting the guard
        }
    }
    printf("[SETTINGS] init_remote_call(SpringBoard) failed after %d attempts\n",
           kSettingsSpringBoardRCMaxAttempts);
    return NO;
}

static void settings_destroy_springboard_remote_call_locked_internal_ex(const char *reason, BOOL notifyState, BOOL preserveApplied)
{
    if (!g_springboard_rc_ready) return;

    printf("[SETTINGS] destroying SpringBoard RemoteCall session%s%s\n",
           reason ? ": " : "", reason ?: "");
    destroy_remote_call();
    g_springboard_rc_ready = 0;
    g_springboard_sandbox_escaped = 0;
    if (notifyState) settings_notify_remote_call_state_changed_preserving_applied(preserveApplied);
}

static void settings_destroy_springboard_remote_call_locked_internal(const char *reason, BOOL notifyState)
{
    settings_destroy_springboard_remote_call_locked_internal_ex(reason, notifyState, NO);
}

static void settings_destroy_springboard_remote_call_locked(const char *reason)
{
    settings_destroy_springboard_remote_call_locked_internal(reason, YES);
}

static void settings_prepare_for_respring_sync(void)
{
    log_user("[RESPRING] Stopping live sessions before respring.\n");
    printf("[SETTINGS] preparing for respring cleanup rcReady=%d\n", g_springboard_rc_ready);
    settings_request_all_live_loops_stop("pre-respring cleanup");
    settings_end_statbar_background_task_async("pre-respring cleanup");
    settings_wait_live_loops_stopped_for_switch("pre-respring cleanup");

    @synchronized (settings_rc_lock()) {
        if (g_springboard_rc_ready) {
            // SB is about to be killed by the respring, so cleanup uses the
            // fast variant for tweaks where full remote restoration is wasted.
            settings_stop_springboard_tweaks_locked("pre-respring cleanup", YES);
            settings_destroy_springboard_remote_call_locked("pre-respring cleanup");
        }
    }

    if (g_kexploit_done) {
        bool parked = kexploit_terminal_cleanup();
        printf("[SETTINGS] pre-respring terminal KRW cleanup parked=%d\n", parked);
        g_kexploit_done = NO;
        g_springboard_rc_ready = 0;
        g_springboard_sandbox_escaped = 0;
        kutils_reset_self_cache();
        settings_notify_remote_call_state_changed();
    }

    log_user("[RESPRING] Cleanup complete. Opening respring flow.\n");
    usleep(300000);
}

// Round 6: warm fastkill session lifetime policy.
//
// kFastKillSelfParking — the "self-parking command page polled by a loop
// inside launchd" design is INFEASIBLE on arm64e: the loop would be executable
// code, and we cannot inject code into launchd (anonymous RW pages are not
// executable; unsigned code cannot run; the PAC machinery here signs whole
// thread states, not multi-gadget ROP chains). Every no-code variant fails
// too: pause()/sigsuspend() cannot be woken without a signal we cannot send;
// a one-shot usleep cannot loop (one signed lr = one more call, and the
// callee's return value clobbers x0, so any chain degenerates into a busy or
// error spin); KRW-rewriting a blocked thread's saved state only takes effect
// when its syscall returns. The trojan thread's resting state IS a trap wait
// on OUR exception port (its start routine is the PAC-signed bogus PC
// FAKE_PC_TROJAN — TaskRop/RemoteCall.m), so there is nothing to "park".
// Kept as a flag so the design question stays answered in code.
//
// kFastKillTeardownOnBackground — the accepted fallback: a suspended app is
// SIGKILLed WITHOUT applicationWillTerminate, so the warm session must not
// outlive ANY backgrounding/screen-blank — its trapped thread orphaned at app
// death watchdogs launchd ~22 s later (panic-full-2026-09-29-195243:
// swipe-kill of the suspended app at ~19:52:21, panic 19:52:43; the round-3
// terminate teardown never ran). Tear down synchronously on the background/
// screen-blank path while KRW is still live; the session is rebuilt LAZILY by
// the first kill after each foreground return (round 8: pre-warm removed —
// per-cycle hijack churn caused panic-full-2026-09-29-215904).
static const BOOL kFastKillSelfParking __attribute__((unused)) = NO;
static const BOOL kFastKillTeardownOnBackground = YES;

static BOOL pm_fastkill_warm_session_exists(void);
static BOOL pm_fastkill_warm_session_hint(void);
static void pm_teardown_fastkill_session_for_terminate(const char *reason);
// Round 44: pm_prewarm_fastkill_session REMOVED — see the tombstone at the
// former definition site (live 45: speculative arming on viewer visibility
// is the black-screen trigger; kills warm on demand only).

static void settings_terminal_kexploit_cleanup_sync_internal(const char *reason)
{
    log_user("[CLEANUP] Tearing down live tweaks and releasing KRW state...\n");
    printf("[SETTINGS] terminal KRW cleanup requested%s%s done=%d rcReady=%d\n",
           reason ? ": " : "", reason ?: "",
           g_kexploit_done, g_springboard_rc_ready);
    settings_request_all_live_loops_stop("terminal KRW cleanup");
    settings_end_statbar_background_task_async("terminal KRW cleanup");
    settings_wait_live_loops_stopped_for_switch("terminal KRW cleanup");

    @synchronized (settings_rc_lock()) {
        if (g_springboard_rc_ready) {
            settings_stop_springboard_tweaks_locked("terminal cleanup", NO);
            settings_destroy_springboard_remote_call_locked(reason ?: "terminal KRW cleanup");
        } else {
            settings_forget_springboard_tweak_state_locked();
        }
    }

    // The Process Viewer's warm fastkill session holds a hijacked launchd
    // thread TRAPPED at our exception port between kills. If the app dies with
    // the session warm, the port dies with it, the pending exception escalates
    // to launchd's default handler, and launchd EXITS ~22 s later
    // ("initproc exited" — live 11.log: swipe-kill 18:31:37, panic 18:31:59).
    // Background/idle detach only parks the KRW sockets; it never touches this
    // session, so app termination is the one path that orphaned it. Tear it
    // down FIRST — the thread restore needs live KRW, which
    // kexploit_terminal_cleanup() is about to park.
    pm_teardown_fastkill_session_for_terminate(reason ?: "terminal KRW cleanup");

    if (!g_kexploit_done) {
        printf("[SETTINGS] terminal KRW cleanup skipped: no local KRW session\n");
        log_user("[CLEANUP] Nothing to clean up — no active KRW session.\n");
        g_springboard_rc_ready = 0;
        g_springboard_sandbox_escaped = 0;
        kutils_reset_self_cache();
        settings_notify_remote_call_state_changed();
        return;
    }

    bool parked = kexploit_terminal_cleanup();
    printf("[SETTINGS] terminal KRW cleanup result parked=%d\n", parked);
    // Round 17: "parked" alone does NOT mean recoverable — recovery needs the
    // NSUserDefaults primitive + launchd anchor saved THIS boot, and the
    // 12:34:43 cleanup parked kernel state with no saved primitive (the
    // boot's anchor attempt had failed at 12:33:26 and was never retried),
    // then told the user "next Run will recover in seconds". The next run
    // found nothing and had to re-exploit. Say what will actually happen.
    bool recoverable = parked && krw_persistence_has_saved_recovery();
    if (parked && !recoverable)
        printf("[SETTINGS] terminal cleanup: parked in-kernel but NO saved "
               "recovery primitive this boot — next run must re-exploit\n");
    log_user("%s Clean Up complete. %s\n",
             recoverable ? "[OK]" : "[WARN]",
             recoverable ? "KRW parked — next Run will recover in seconds."
                         : (parked ? "KRW parked in-kernel, but no recovery anchor was saved this boot — next Run will re-exploit."
                                   : "KRW not parked — next Run will re-exploit."));
    g_kexploit_done = NO;
    g_springboard_rc_ready = 0;
    g_springboard_sandbox_escaped = 0;
    kutils_reset_self_cache();
    settings_notify_remote_call_state_changed();
}

static void settings_terminal_kexploit_cleanup_sync(const char *reason)
{
    settings_terminal_kexploit_cleanup_sync_internal(reason);
}

static BOOL settings_acquire_actions_lock_wait(const char *owner, uint64_t timeoutUS)
{
    uint64_t startUS = settings_now_us();
    BOOL loggedWait = NO;

    while (__sync_lock_test_and_set(&g_settings_actions_running, 1)) {
        if (!loggedWait) {
            printf("[SETTINGS] %s waiting for active action before cleanup\n",
                   owner ?: "cleanup");
            log_user("[CLEANUP] Run in progress — cleanup queued for when it finishes.\n");
            loggedWait = YES;
        }

        if (timeoutUS != 0) {
            uint64_t nowUS = settings_now_us();
            if (startUS != 0 && nowUS >= startUS && nowUS - startUS >= timeoutUS) {
                printf("[SETTINGS] %s timed out waiting for action lock\n",
                       owner ?: "cleanup");
                log_user("[CLEANUP] Timed out waiting for the current run to finish — proceeding anyway.\n");
                return NO;
            }
        }

        usleep(100000);
    }

    if (loggedWait) {
        uint64_t nowUS = settings_now_us();
        uint64_t waitedUS = (startUS != 0 && nowUS >= startUS) ? nowUS - startUS : 0;
        printf("[SETTINGS] %s acquired action lock after %lluus\n",
               owner ?: "cleanup", waitedUS);
    }
    return YES;
}

static void settings_queue_terminal_kexploit_cleanup(const char *reason)
{
    if (__sync_lock_test_and_set(&g_settings_cleanup_running, 1)) {
        printf("[SETTINGS] terminal cleanup already queued/running%s%s\n",
               reason ? ": " : "", reason ?: "");
        log_user("[CLEANUP] Clean Up is already queued.\n");
        return;
    }
    settings_notify_cleanup_state_changed();

    settings_request_all_live_loops_stop("queued terminal cleanup");
    settings_end_statbar_background_task_async("queued terminal cleanup");

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        BOOL locked = settings_acquire_actions_lock_wait("terminal cleanup", 0);
        @try {
            settings_terminal_kexploit_cleanup_sync_internal(reason ?: "manual action");
        } @finally {
            if (locked) __sync_lock_release(&g_settings_actions_running);
            __sync_lock_release(&g_settings_cleanup_running);
            settings_notify_cleanup_state_changed();
        }
    });
}

void settings_best_effort_termination_cleanup(const char *reason)
{
    // Round 21: from here on, no NEW own-process exception-port trap may
    // start — the process is dying and runningboardd's exit-time policy
    // management of this task is exactly the ABBA counterparty of panics 1+3.
    // In-flight operations finish under the gate mutex; the teardown below
    // drains/restores what they armed.
    excport_gate_set_terminating();
    if (__sync_lock_test_and_set(&g_settings_termination_cleanup_started, 1)) {
        printf("[SETTINGS] termination cleanup already attempted%s%s\n",
               reason ? ": " : "", reason ?: "");
        return;
    }

    const char *why = reason ?: "app termination";
    log_user("[CLEANUP] App exiting (%s) — running last-chance teardown.\n", why);
    printf("[SETTINGS] best-effort termination cleanup requested: %s\n", why);

    // A live KRW session must be torn down on exit even with no live tweaks.
    // This guard used to check only for live tweaks, so the common workflow
    // — run the chain, apply SpringBoard modifications, close the app —
    // skipped cleanup entirely. That leaves the two leaked sockets' PCBs on the
    // raw6 inpcb list with in6p_icmp6filt still pointing at the last kernel
    // address touched (a SpringBoard thread struct, for SpringBoard work).
    // icmp6_rip6_input() dereferences that pointer for every inbound ICMPv6
    // packet, so once the thread dies the kernel reads freed memory: a
    // use-after-free in the threads zone, hours or days later, with Cyanide
    // long gone.
    // Also run when ONLY the fastkill warm session survives: it can outlive
    // g_kexploit_done (respring prep resets the flag without touching the
    // session) and its trapped launchd thread is precisely what must not be
    // orphaned at app death.
    if (!settings_has_active_termination_live_tweak() && !g_kexploit_done &&
        !pm_fastkill_warm_session_exists()) {
        printf("[SETTINGS] termination cleanup skipped: no live tweaks and no KRW session\n");
        log_user("[CLEANUP] No live tweaks and no KRW session — nothing to tear down.\n");
        return;
    }

    settings_request_all_live_loops_stop("termination cleanup");

    BOOL locked = settings_acquire_actions_lock_wait("termination cleanup", 1500000);
    if (!locked) {
        log_user("[CLEANUP] Last-chance cleanup skipped because another operation is still active.\n");
        return;
    }

    @try {
        settings_terminal_kexploit_cleanup_sync_internal(why);
        // Round 40: before the process is reaped, give any in-flight RemoteCall
        // helper thread a bounded window to RETURN from the kernel. If the app
        // was closed mid-kill, a Cyanide helper can still be in a set_exception_
        // ports / MIG trap; terminating with it live leaves an un-reaped corpse
        // → black screen on reopen (live 41). Bounded (3 s) to stay well under
        // the UIKit termination watchdog; if it does not drain it is wedged
        // in-kernel (irreducible) and we exit anyway — no worse than before.
        if (remote_call_inflight_count() != 0) {
            printf("[SETTINGS] termination: waiting for in-flight RemoteCall op(s) "
                   "to drain before exit (count=%d)\n", remote_call_inflight_count());
            for (int i = 0; i < 30 && remote_call_inflight_count() != 0; i++)
                usleep(100000);   // up to 3 s
            printf("[SETTINGS] termination: in-flight RemoteCall %s\n",
                   remote_call_inflight_count() == 0
                       ? "drained — clean exit"
                       : "STILL live (wedged in-kernel) — exiting anyway");
        }
        // Round 41: the in-flight count does NOT cover a tro-dance helper
        // wedged in-kernel (it counts guard ops only). Exiting with such a
        // thread live is the un-reaped-corpse shape (live 41) — say so
        // LOUDLY instead of going quietly. (We cannot block termination on
        // it: the count never clears once wedged, and the UIKit watchdog
        // would SIGKILL us anyway — which at least reaps the corpse.)
        if (remote_call_helper_unaccounted_count() != 0) {
            printf("[SETTINGS] termination: tro-dance helper WEDGED in-kernel "
                   "(unaccounted=%d) — exiting anyway; reopen may black-screen "
                   "until the corpse is reaped\n",
                   remote_call_helper_unaccounted_count());
            log_user("[WARN] Cyanide cannot safely exit — a kernel call is "
                     "stuck; keep the app open or reboot soon.\n");
        }
    } @finally {
        __sync_lock_release(&g_settings_actions_running);
    }
}

// Last-ditch safety net for the kill paths that never reach the cleanup above:
// jetsam, force-quit, or a crash. Parks the RW PCB's filter at an address that
// stays mapped, leaving the session otherwise intact and re-armable.
void settings_park_krw_filter_for_background(void)
{
    if (!g_kexploit_done) return;
    bool parked = kexploit_krw_park_filter_safe();
    printf("[SETTINGS] background KRW filter park: %d\n", parked);
}

// Whether handing the sockets to launchd is worth doing right now.
//
// It is always *safe*: every KRW access funnels through early_kread /
// early_kwrite32bytes, which re-make the fds via krw_lock_for_access() before
// taking krwLock, and the detach closes them under that same lock. But it is
// only *useful* when nothing is about to take them straight back. A live tweak
// loop reattaches on its next tick, so detaching around one is pure churn --
// and for a loop slower than the idle threshold it would detach and reattach
// on every cycle, logging a line each time.
//
// So while live tweaks hold the session, the primitive stays in this process
// and dies with it. Screen-lock and backgrounding are still covered: those
// paths stop the loops first, then detach.
BOOL settings_krw_idle_detach_allowed(void)
{
    if (settings_any_registered_live_loop_running()) return NO;
    if (settings_has_persistent_springboard_remote_call_user()) return NO;
    return YES;
}

// True when lazy reattach-from-launchd should be SUPPRESSED: the app is
// backgrounded or the screen is off, and no live tweak needs KRW there.
//
// Without this, a Process Viewer poll that was already in flight when the app
// backgrounded reattaches the socket ~1 ms after the background detach — then
// the next transition detaches again, thrashing detach/reattach many times a
// second. That churn is what leaves the primitive fragile enough to die across
// a suspend (the tweak flow survives because after ONE session-end detach
// nothing reattaches until the next run). Suppressing reattach here makes the
// backgrounded viewer behave like the tweak flow: detach once, rest untouched
// in launchd, reattach only on the next foreground access. Live tweaks
// (idle_detach NOT allowed) still reattach — they legitimately use KRW in the
// background.
BOOL settings_krw_reattach_suppressed(void)
{
    if (!settings_krw_idle_detach_allowed()) return NO;   // a live tweak needs KRW
    return (g_app_in_background != 0 || g_screen_awake == 0);
}

// Detach the KRW sockets to launchd on backgrounding so the primitive survives
// device sleep (a session still held live by a suspended Cyanide dies across
// sleep; one resting only in launchd's fileports does not). Live loops must be
// stopped first: early_kread/kwrite abort hard if their socket fd disappears
// mid-op. Falls back to the plain filter park when detach isn't available
// (launchd not yet anchoring, or no live session).
void settings_detach_krw_for_background(void)
{
    if (!g_kexploit_done) return;
    // Round 25 (A): hold the exception-port teardown bypass for the WHOLE
    // background-detach episode — the fastkill teardown below, the stop
    // request, the gate drain-wait, and the detach itself. The responder's
    // re-park/dispatch signs funnel through excport_gate_blocked_for_caller(),
    // which consults the process-wide depth, so holding it here lets late
    // traps be re-parked (signed) instead of refused → replied-unmodified →
    // re-fault ping-pong (live 28.log 15:16:48.360-.363: 16 crash-backlog
    // messages from exactly that refusal window). Depth-counted, so the
    // destroy/abandon internal bypass nests harmlessly.
    excport_teardown_bypass_begin("background-detach");
    // Round 6: a suspended app is SIGKILLed without applicationWillTerminate,
    // so the warm fastkill session must not outlive ANY backgrounding or screen
    // blank — its trapped thread, orphaned at app death, watchdogs launchd ~22 s
    // later (panic-full-2026-09-29-195243: swipe-kill of the suspended app, no
    // terminate cleanup ran). Tear it down HERE, while KRW is still live; the
    // session is rebuilt LAZILY by the first kill after each foreground return
    // (round 8: pre-warm removed — per-cycle hijack churn caused
    // panic-full-2026-09-29-215904; self-parking inside launchd is infeasible
    // on arm64e, see kFastKillSelfParking). Runs BEFORE the
    // already-detached early return on purpose: the teardown force-reattaches
    // idle-detached sockets, and the flow below then re-parks them — end state
    // unchanged (sockets resting in launchd, filter parked).
    if (kFastKillTeardownOnBackground)
        pm_teardown_fastkill_session_for_terminate("backgrounding/screen-blank");
    if (kexploit_krw_sockets_detached()) {
        // The idle parker already handed the fds over; nothing left to do.
        printf("[SETTINGS] background: KRW already detached to launchd\n");
        excport_teardown_bypass_end("background-detach");
        return;
    }
    settings_request_all_live_loops_stop("background KRW detach");
    settings_wait_live_loops_stopped_for_switch("background KRW detach");
    // A Process Viewer launchd kill (or its one-time warm-up hijack) is NOT a
    // registered live loop, so the wait above does not cover it. Detaching the
    // KRW sockets underneath an in-flight hijack strands a corrupted thread
    // inside launchd and black-screens the device (live 9.log; and live 10.log
    // 17:50:30 proved a drain-wait alone still races the NEXT acquisition —
    // the kill acquired the guard in the same millisecond the detach ran).
    //
    // Gate protocol: CLOSE the detach gate first — new RemoteCall acquisitions
    // fail-fast from here, so no kill can slip into the drain→detach gap —
    // then wait (bounded; warm-up is ~2 s) for the in-flight op to finish
    // restoring launchd's thread, then detach while the gate is still held.
    // If it can't finish in 4 s, DO NOT detach: the SOF_NODEFUNCT-parked
    // primitive survives backgrounding in-process, and the in-flight op keeps
    // the sockets it needs to put launchd's thread back.
    remote_call_request_stop("background KRW detach");
    if (remote_call_detach_gate_acquire(4000, "background KRW detach")) {
        if (krw_persistence_detach_for_background()) {
            printf("[SETTINGS] background: KRW sockets detached to launchd\n");
        } else {
            bool parked = kexploit_krw_park_filter_safe();
            printf("[SETTINGS] background: detach unavailable; filter park=%d\n", parked);
        }
        remote_call_detach_gate_release("background KRW detach (done)");
    } else {
        bool parked = kexploit_krw_park_filter_safe();
        printf("[SETTINGS] background: RemoteCall STILL in flight after 4 s — "
               "SKIPPING detach (parked=%d); KRW stays in-process so the "
               "hijacked launchd thread can be restored\n", parked);
    }
    excport_teardown_bypass_end("background-detach");
}

// Deliberately does NOT pull the fds back on wake any more.
//
// It used to reattach eagerly, because the wake re-apply (StatBar and friends)
// needed live fds. krw_lock_for_access() now re-makes them on the next kernel
// access instead, so the eager version only put the primitive back in the
// app's hands for no reason -- and that is where it dies. 20260916-134338 is
// the whole story in one log: handed to launchd at 13:43:44, survived the
// screen sleeping at 13:43:46, then reattached on wake at 13:46:11 with
// nothing asking for it, and was dead by 13:50:31. The next Run re-exploited.
//
// Leaving it detached costs one bootstrap_look_up on the next access and keeps
// the primitive where it demonstrably survives.
void settings_reattach_krw_for_foreground(void)
{
    if (!kexploit_krw_sockets_detached()) return;
    printf("[SETTINGS] foreground: KRW left resting in launchd; "
           "next kernel access re-makes the fds\n");
}

void settings_destroy_springboard_remote_call_sync(void)
{
    settings_request_all_live_loops_stop("remote call sync cleanup");
    settings_end_statbar_background_task_async("remote call sync cleanup");
    settings_wait_live_loops_stopped_for_switch("remote call sync cleanup");
    @synchronized (settings_rc_lock()) {
        if (g_springboard_rc_ready) {
            settings_stop_springboard_tweaks_locked("remote call sync cleanup", NO);
        }
        settings_destroy_springboard_remote_call_locked("manual/sync cleanup");
    }
}

void settings_destroy_springboard_remote_call(void)
{
    settings_request_all_live_loops_stop("remote call cleanup");
    settings_end_statbar_background_task_async("remote call cleanup");
    log_user("[SESSION] Closing SpringBoard injection session...\n");
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        settings_wait_live_loops_stopped_for_switch("remote call cleanup");
        @synchronized (settings_rc_lock()) {
            BOOL hadSession = g_springboard_rc_ready != 0;
            if (g_springboard_rc_ready) {
                settings_stop_springboard_tweaks_locked("remote call cleanup", NO);
            }
            settings_destroy_springboard_remote_call_locked("manual cleanup");
            log_user(hadSession ? "[OK] SpringBoard channel closed — live tweaks stopped.\n" :
                                  "[SESSION] No active SpringBoard session to close.\n");
        }
    });
}

static bool settings_apply_sbc_from_defaults_locked(NSUserDefaults *d)
{
    if (![d boolForKey:kSettingsSBCEnabled]) return false;

    return sbcustomizer_apply_in_session((int)[d integerForKey:kSettingsSBCDockIcons],
                                         (int)[d integerForKey:kSettingsSBCCols],
                                         (int)[d integerForKey:kSettingsSBCRows],
                                         [d boolForKey:kSettingsSBCHideLabels],
                                         [d boolForKey:kSettingsSBCArrangePages],
                                         (int)[d integerForKey:kSettingsSBCFirstPageIcons],
                                         (int)[d integerForKey:kSettingsSBCOtherPageIcons],
                                         [d boolForKey:kSettingsSBCAutoDockApp],
                                         [d stringForKey:kSettingsSBCDockAppBundleID].UTF8String);
}

static NSString *settings_nicebar_key(NSString *prefix, NSInteger slot)
{
    return [NSString stringWithFormat:@"%@%ld", prefix, (long)slot];
}

static NSString *settings_nicebar_slot_name(NSInteger slot)
{
    switch ((NiceBarLiteSlot)slot) {
        case NiceBarLiteSlotTopLeft: return @"Top Left";
        case NiceBarLiteSlotTopRight: return @"Top Right";
        case NiceBarLiteSlotBottomLeft: return @"Bottom Left";
        case NiceBarLiteSlotBottomRight: return @"Bottom Right";
        case NiceBarLiteSlotBottomCenter: return @"Bottom Center";
        case NiceBarLiteSlotCount: return @"Slot";
    }
    return @"Slot";
}

static NSString *settings_nicebar_kind_name(NSInteger kind)
{
    switch ((NiceBarLiteContentKind)kind) {
        case NiceBarLiteContentOff: return @"Off";
        case NiceBarLiteContentCustomText: return @"Custom Text";
        case NiceBarLiteContentSystem: return @"System";
        case NiceBarLiteContentTimeFormat: return @"Date / Time";
        case NiceBarLiteContentWeather: return @"Weather";
    }
    return @"Off";
}

static NSString *settings_nicebar_system_name(NSInteger item)
{
    switch ((NiceBarLiteSystemItem)item) {
        case NiceBarLiteSystemBatteryTemp: return @"Battery Temp";
        case NiceBarLiteSystemFreeRAM: return @"Free RAM";
        case NiceBarLiteSystemBatteryPercent: return @"Battery";
        case NiceBarLiteSystemNetworkSpeed: return @"Network Speed";
        case NiceBarLiteSystemUptime: return @"Uptime";
        case NiceBarLiteSystemDate: return @"Date";
        case NiceBarLiteSystemLunarDate: return @"Lunar Date";
        case NiceBarLiteSystemTodayTraffic: return @"Today Traffic";
        case NiceBarLiteSystemCurrentIP: return @"Current IP";
        case NiceBarLiteSystemFreeDisk: return @"Free Disk";
        case NiceBarLiteSystemThermalState: return @"Thermal State";
    }
    return @"System";
}

static BOOL settings_nicebar_has_weather_slots(NSUserDefaults *d)
{
    for (NSInteger i = 0; i < NiceBarLiteSlotCount; i++) {
        NSInteger kind = [d integerForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, i)];
        if (kind == NiceBarLiteContentWeather) return YES;
    }
    return NO;
}

static NSString *settings_nicebar_weather_text_for_slot(NSUserDefaults *d, NSInteger slot)
{
    NSNumber *tempNumber = [d objectForKey:kSettingsNiceBarLiteWeatherTemp];
    NSNumber *codeNumber = [d objectForKey:kSettingsNiceBarLiteWeatherCode];
    if (![tempNumber isKindOfClass:NSNumber.class] || ![codeNumber isKindOfClass:NSNumber.class]) {
        return [d stringForKey:kSettingsNiceBarLiteWeatherCache] ?:
               [d stringForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotWeatherPrefix, slot)] ?:
               @"Weather --";
    }

    NSString *language = [d stringForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotWeatherLanguagePrefix, slot)] ?: @"en";
    BOOL chinese = [language isEqualToString:@"zh"];
    NSString *summary = CyanideNiceBarWeatherSummary(codeNumber.integerValue, chinese);
    return [NSString stringWithFormat:@"%@ %.0f°", summary, tempNumber.doubleValue];
}

static BOOL settings_nicebar_has_resolved_weather(NSUserDefaults *d)
{
    NSNumber *tempNumber = [d objectForKey:kSettingsNiceBarLiteWeatherTemp];
    NSNumber *codeNumber = [d objectForKey:kSettingsNiceBarLiteWeatherCode];
    return [tempNumber isKindOfClass:NSNumber.class] &&
           [codeNumber isKindOfClass:NSNumber.class];
}

static void settings_nicebar_update_weather_slot_texts(NSUserDefaults *d)
{
    for (NSInteger i = 0; i < NiceBarLiteSlotCount; i++) {
        [d setObject:settings_nicebar_weather_text_for_slot(d, i)
              forKey:settings_nicebar_key(kSettingsNiceBarLiteSlotWeatherPrefix, i)];
    }
}

static void settings_nicebar_store_weather_result(NSUserDefaults *d,
                                                  NSNumber *temp,
                                                  NSNumber *code,
                                                  NSString *fallbackText,
                                                  BOOL fetched)
{
    if ([temp isKindOfClass:NSNumber.class] && [code isKindOfClass:NSNumber.class]) {
        [d setObject:temp forKey:kSettingsNiceBarLiteWeatherTemp];
        [d setObject:code forKey:kSettingsNiceBarLiteWeatherCode];
        NSString *cache = [NSString stringWithFormat:@"%@ %.0f°",
                           CyanideNiceBarWeatherSummary(code.integerValue, NO),
                           temp.doubleValue];
        [d setObject:cache forKey:kSettingsNiceBarLiteWeatherCache];
    } else {
        NSString *resolved = fallbackText.length ? fallbackText : @"Weather --";
        [d setObject:resolved forKey:kSettingsNiceBarLiteWeatherCache];
    }

    [d setObject:[NSDate date] forKey:kSettingsNiceBarLiteWeatherLastAttemptAt];
    if (fetched) {
        [d setObject:[NSDate date] forKey:kSettingsNiceBarLiteWeatherUpdatedAt];
    }
    settings_nicebar_update_weather_slot_texts(d);
    [d synchronize];
}

static NSString *settings_nsbar_position_name(NSInteger position)
{
    switch ((NSBarPosition)position) {
        case NSBarPositionTopLeft: return @"Top Left";
        case NSBarPositionBottomLeft: return @"Bottom Left";
        case NSBarPositionTopRight: return @"Top Right";
        case NSBarPositionBottomRight: return @"Bottom Right";
        case NSBarPositionCenter: return @"Center";
    }
    return @"Top Left";
}

static NSString *settings_livewp_video_detail(void)
{
    NSString *path = livewp_absolute_path();
    if (path.length == 0) return @"No video selected.";
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (attrs) {
        unsigned long long bytes = [attrs fileSize];
        NSByteCountFormatter *fmt = [[NSByteCountFormatter alloc] init];
        fmt.allowedUnits = NSByteCountFormatterUseMB | NSByteCountFormatterUseGB;
        fmt.countStyle = NSByteCountFormatterCountStyleFile;
        return [NSString stringWithFormat:@"%@ (%@)", path.lastPathComponent, [fmt stringFromByteCount:(long long)bytes]];
    }
    return [NSString stringWithFormat:@"%@ (missing)", path.lastPathComponent ?: path];
}

static NiceBarLiteConfig settings_nicebar_config_from_defaults(NSUserDefaults *d)
{
    NiceBarLiteConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.celsius = [d boolForKey:kSettingsNiceBarLiteCelsius];
    cfg.topSideInsetOffset = [d integerForKey:kSettingsNiceBarLiteLayoutTopSideInset];
    cfg.bottomSideInsetOffset = [d integerForKey:kSettingsNiceBarLiteLayoutBottomSideInset];
    cfg.topYOffset = [d integerForKey:kSettingsNiceBarLiteLayoutTopY];
    cfg.bottomYOffset = [d integerForKey:kSettingsNiceBarLiteLayoutBottomY];
    cfg.centerXOffset = [d integerForKey:kSettingsNiceBarLiteLayoutCenterX];
    cfg.updateMask = UINT32_MAX;

    for (NSInteger i = 0; i < NiceBarLiteSlotCount; i++) {
        NSString *text = [d stringForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotTextPrefix, i)] ?: @"";
        NSString *time = [d stringForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotTimePrefix, i)] ?: @"HH:mm";
        NSString *weather = settings_nicebar_weather_text_for_slot(d, i);
        NSString *language = [d stringForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotSystemLanguagePrefix, i)] ?: @"en";
        cfg.slots[i].kind = (int)[d integerForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, i)];
        cfg.slots[i].systemItem = (int)[d integerForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotSystemPrefix, i)];
        cfg.slots[i].customText = text.UTF8String;
        cfg.slots[i].timeFormat = time.UTF8String;
        cfg.slots[i].weatherText = weather.UTF8String;
        cfg.slots[i].systemLanguage = language.UTF8String;
    }
    return cfg;
}

static bool settings_apply_nicebarlite_from_defaults_locked(NSUserDefaults *d)
{
    if (![d boolForKey:kSettingsNiceBarLiteEnabled]) return false;
    return nicebarlite_apply_in_session(settings_nicebar_config_from_defaults(d));
}

static void settings_nicebar_schedule_apply_after_weather_update(void)
{
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (![d boolForKey:kSettingsNiceBarLiteEnabled] || !g_springboard_rc_ready) return;
        @synchronized (settings_rc_lock()) {
            if (settings_cleanup_in_progress() ||
                ![d boolForKey:kSettingsNiceBarLiteEnabled] ||
                !g_springboard_rc_ready) {
                return;
            }
            bool ok = settings_apply_nicebarlite_from_defaults_locked(d);
            settings_mark_tweak_applied(kSettingsNiceBarLiteEnabled, ok);
            printf("[SETTINGS] NiceBar Lite weather refresh apply result=%d\n", ok);
        }
        settings_notify_package_queue_changed_async();
    });
}

static volatile int g_nicebarlite_weather_refresh_requested = 0;

static void settings_nicebar_refresh_weather_if_needed(BOOL force,
                                                       void (^completion)(BOOL ok, NSString *text))
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (!settings_nicebar_has_weather_slots(d)) {
        if (force || completion) {
            log_user("[NICEBAR] Weather refresh skipped: no weather slot configured.\n");
        }
        if (completion) completion(NO, [d stringForKey:kSettingsNiceBarLiteWeatherCache] ?: @"");
        return;
    }

    BOOL hasResolvedWeather = settings_nicebar_has_resolved_weather(d);
    NSTimeInterval retryInterval = hasResolvedWeather ? kNiceBarLiteWeatherRefreshInterval : 60.0;
    if (!force && completion == nil) {
        NSDate *lastAttempt = [d objectForKey:kSettingsNiceBarLiteWeatherLastAttemptAt];
        if ([lastAttempt isKindOfClass:NSDate.class] &&
            [[NSDate date] timeIntervalSinceDate:lastAttempt] < retryInterval) {
            return;
        }
    }
    if (!force && completion == nil &&
        !__sync_bool_compare_and_swap(&g_nicebarlite_weather_refresh_requested, 0, 1)) {
        return;
    }

    [d setObject:[NSDate date] forKey:kSettingsNiceBarLiteWeatherLastAttemptAt];
    [d synchronize];
    log_user("[NICEBAR] Weather refresh requested force=%d cached=%d.\n",
             force ? 1 : 0,
             hasResolvedWeather ? 1 : 0);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[CyanideNiceBarWeatherRefresher sharedRefresher]
            refreshWeatherForce:force
                      useCelsius:[d boolForKey:kSettingsNiceBarLiteCelsius]
                      completion:^(BOOL ok, NSString *text, NSNumber *temp, NSNumber *code, BOOL fetched) {
            __sync_lock_release(&g_nicebarlite_weather_refresh_requested);
            NSUserDefaults *innerDefaults = [NSUserDefaults standardUserDefaults];
            if (fetched || force) {
                settings_nicebar_store_weather_result(innerDefaults, temp, code, text, ok);
            }
            if (fetched || force || completion) {
                log_user("[NICEBAR] Weather refresh finished ok=%d fetched=%d text=%s temp=%s code=%s\n",
                         ok ? 1 : 0,
                         fetched ? 1 : 0,
                         text.UTF8String ?: "(nil)",
                         temp ? temp.stringValue.UTF8String : "(nil)",
                         code ? code.stringValue.UTF8String : "(nil)");
            }
            if ((fetched || force) &&
                [innerDefaults boolForKey:kSettingsNiceBarLiteEnabled] &&
                g_springboard_rc_ready) {
                settings_nicebar_schedule_apply_after_weather_update();
            }
            if (completion) completion(ok, text);
        }];
    });
}

static BOOL settings_dark_tweaks_any_enabled(NSUserDefaults *d)
{
    return [d boolForKey:kSettingsDSDisableAppLibrary] ||
           [d boolForKey:kSettingsDSDisableIconFlyIn] ||
           [d boolForKey:kSettingsDSZeroWakeAnimation] ||
           [d boolForKey:kSettingsDSZeroBacklightFade] ||
           [d boolForKey:kSettingsDSDoubleTapToLock];
}

static BOOL settings_enabled_tweak_should_run(NSUserDefaults *d, NSString *key, BOOL pendingOnly)
{
    if (![d boolForKey:key]) return NO;
    return !pendingOnly || !settings_tweak_is_applied(key);
}

static NSTimeInterval settings_current_boot_epoch_seconds(void)
{
    struct timeval boottime;
    size_t len = sizeof(boottime);
    memset(&boottime, 0, sizeof(boottime));
    if (sysctlbyname("kern.boottime", &boottime, &len, NULL, 0) == 0 &&
        boottime.tv_sec > 0) {
        return (NSTimeInterval)boottime.tv_sec;
    }

    return [[NSDate date] timeIntervalSince1970] -
           [[NSProcessInfo processInfo] systemUptime];
}

static BOOL settings_hide_home_bar_materialkit_zero_active(NSUserDefaults *d)
{
    NSTimeInterval storedBoot = [d doubleForKey:kSettingsHideHomeBarMaterialKitBootTime];
    if (storedBoot <= 0.0) return NO;

    NSTimeInterval currentBoot = settings_current_boot_epoch_seconds();
    if (currentBoot <= 0.0) return YES;
    if (fabs(currentBoot - storedBoot) > 120.0) {
        // The MaterialKit page zero is memory-backed/transient; a reboot
        // restores the asset catalog, so stale conflict state can be dropped.
        [d removeObjectForKey:kSettingsHideHomeBarMaterialKitBootTime];
        [d synchronize];
        return NO;
    }
    return YES;
}

static BOOL settings_hide_home_bar_respring_pending_current_boot(NSUserDefaults *d)
{
    if (![d boolForKey:kSettingsHideHomeBarRespringPending]) return NO;

    NSTimeInterval storedBoot = [d doubleForKey:kSettingsHideHomeBarRespringPendingBootTime];
    if (storedBoot <= 0.0) return YES;

    NSTimeInterval currentBoot = settings_current_boot_epoch_seconds();
    if (currentBoot <= 0.0) return YES;
    if (fabs(currentBoot - storedBoot) > 120.0) {
        [d removeObjectForKey:kSettingsHideHomeBarRespringPending];
        [d removeObjectForKey:kSettingsHideHomeBarRespringPendingBootTime];
        [d removeObjectForKey:kSettingsHideHomeBarPendingHidden];
        [d synchronize];
        return NO;
    }
    return YES;
}

static void settings_set_hide_home_bar_registered_hidden(NSUserDefaults *d, BOOL hidden, BOOL needsRespring)
{
    NSTimeInterval boot = settings_current_boot_epoch_seconds();
    if (hidden) {
        [d setDouble:boot forKey:kSettingsHideHomeBarMaterialKitBootTime];
        [d setBool:YES forKey:kSettingsHideHomeBarHidden];
    } else {
        [d setBool:NO forKey:kSettingsHideHomeBarHidden];
        [d removeObjectForKey:kSettingsHideHomeBarMaterialKitBootTime];
    }
    if (needsRespring) {
        [d setBool:YES forKey:kSettingsHideHomeBarRespringPending];
        [d setDouble:boot forKey:kSettingsHideHomeBarRespringPendingBootTime];
        [d setBool:hidden forKey:kSettingsHideHomeBarPendingHidden];
    }
    [d synchronize];
}

static void settings_clear_hide_home_bar_respring_pending(void)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (![d boolForKey:kSettingsHideHomeBarRespringPending] &&
        [d objectForKey:kSettingsHideHomeBarRespringPendingBootTime] == nil &&
        [d objectForKey:kSettingsHideHomeBarPendingHidden] == nil) {
        return;
    }
    [d removeObjectForKey:kSettingsHideHomeBarRespringPending];
    [d removeObjectForKey:kSettingsHideHomeBarRespringPendingBootTime];
    [d removeObjectForKey:kSettingsHideHomeBarPendingHidden];
    [d synchronize];
}

BOOL settings_hide_home_bar_hidden(void)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (![d boolForKey:kSettingsHideHomeBarHidden]) return NO;
    if (!settings_hide_home_bar_materialkit_zero_active(d)) {
        // DirtyZero-style page-cache state survives respring, not reboot. If
        // the boot marker no longer matches, drop the installed registration.
        [d setBool:NO forKey:kSettingsHideHomeBarHidden];
        [d synchronize];
        return NO;
    }
    return YES;
}

void settings_note_hide_home_bar_respring_pending(void)
{
    settings_set_hide_home_bar_registered_hidden(NSUserDefaults.standardUserDefaults,
                                                 YES,
                                                 YES);
}

BOOL settings_hide_home_bar_respring_pending(void)
{
    return settings_hide_home_bar_respring_pending_current_boot(NSUserDefaults.standardUserDefaults);
}

void settings_present_hide_home_bar_respring_prompt(UIViewController *host)
{
    BOOL targetHidden = [NSUserDefaults.standardUserDefaults boolForKey:kSettingsHideHomeBarPendingHidden];
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:(targetHidden ? @"Respring to Hide Home Bar?" : @"Respring to Restore Home Bar?")
                         message:(targetHidden
                                  ? @"Hide Home Bar was applied, but SpringBoard needs to restart before the home indicator disappears."
                                  : @"Home Bar restore was queued, but SpringBoard needs to restart before the stock home indicator returns.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Later"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    __weak UIViewController *weakHost = host;
    [ac addAction:[UIAlertAction actionWithTitle:@"Respring"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *_) {
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            if (__sync_lock_test_and_set(&g_settings_actions_running, 1)) {
                printf("[SETTINGS] hide home bar respring blocked: actions already running\n");
                log_user("[RESPRING] Another action is still running. Try Respring again in a moment.\n");
                return;
            }

            __sync_lock_test_and_set(&g_settings_respring_cleanup_running, 1);
            settings_notify_cleanup_state_changed();
            @try {
                settings_prepare_for_respring_sync();
            } @finally {
                __sync_lock_release(&g_settings_actions_running);
                __sync_lock_release(&g_settings_respring_cleanup_running);
                settings_notify_cleanup_state_changed();
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                settings_show_respring_overlay(weakHost);
            });
        });
    }]];
    settings_present_controller(ac, host);
}

static BOOL settings_dark_tweaks_should_run(NSUserDefaults *d, BOOL pendingOnly)
{
    NSArray<NSString *> *keys = @[
        kSettingsDSDisableAppLibrary,
        kSettingsDSDisableIconFlyIn,
        kSettingsDSZeroWakeAnimation,
        kSettingsDSZeroBacklightFade,
        kSettingsDSDoubleTapToLock,
        kSettingsDSDragCoefficientEnabled,
    ];
    for (NSString *key in keys) {
        if (settings_enabled_tweak_should_run(d, key, pendingOnly)) return YES;
    }
    return NO;
}

typedef struct {
    bool any;
    bool disableAppLibrary;
    bool disableIconFlyIn;
    bool zeroWakeAnimation;
    bool zeroBacklightFade;
    bool doubleTapToLock;
    bool dragCoefficient;
} SettingsDarkTweaksResult;

static bool settings_dark_tweaks_result_all_ok(SettingsDarkTweaksResult result)
{
    return result.any &&
           result.disableAppLibrary &&
           result.disableIconFlyIn &&
           result.zeroWakeAnimation &&
           result.zeroBacklightFade &&
           result.doubleTapToLock &&
           result.dragCoefficient;
}

static SettingsDarkTweaksResult settings_apply_dark_tweaks_from_defaults_locked(NSUserDefaults *d)
{
    // The iOS 17 gate is lifted. darksword_tweaks.m carries a complete iOS 17
    // "singular controller" path that was never reachable from here, so it has
    // never actually been exercised on a device. It is enabled to be tested;
    // if it does not work the tweak reports failure rather than misbehaving.
    BOOL disableAppLibrary = [d boolForKey:kSettingsDSDisableAppLibrary];
    BOOL disableIconFlyIn = [d boolForKey:kSettingsDSDisableIconFlyIn];
    BOOL zeroWakeAnimation = [d boolForKey:kSettingsDSZeroWakeAnimation];
    BOOL zeroBacklightFade = [d boolForKey:kSettingsDSZeroBacklightFade];
    BOOL doubleTapToLock = [d boolForKey:kSettingsDSDoubleTapToLock];
    BOOL dragCoefficientEnabled = [d boolForKey:kSettingsDSDragCoefficientEnabled];
    SettingsDarkTweaksResult result = {
        .disableAppLibrary = true,
        .disableIconFlyIn = true,
        .zeroWakeAnimation = true,
        .zeroBacklightFade = true,
        .doubleTapToLock = true,
        .dragCoefficient = true,
    };

    printf("[DST] apply appLib=%d flyIn=%d wake=%d backlight=%d dblTap=%d drag=%d\n",
           disableAppLibrary,
           disableIconFlyIn,
           zeroWakeAnimation,
           zeroBacklightFade,
           doubleTapToLock,
           dragCoefficientEnabled);

    if (disableAppLibrary) {
        result.any = true;
        result.disableAppLibrary = darksword_tweak_disable_app_library_in_session();
    }
    if (disableIconFlyIn) {
        result.any = true;
        result.disableIconFlyIn = darksword_tweak_disable_icon_fly_in_in_session();
    }
    if (zeroWakeAnimation) {
        result.any = true;
        result.zeroWakeAnimation = darksword_tweak_zero_wake_animation_in_session();
    }
    if (zeroBacklightFade) {
        result.any = true;
        result.zeroBacklightFade = darksword_tweak_zero_backlight_fade_in_session();
    }
    if (doubleTapToLock) {
        result.any = true;
        result.doubleTapToLock = darksword_tweak_double_tap_to_lock_in_session();
    }
    if (dragCoefficientEnabled) {
        result.any = true;
        result.dragCoefficient = darksword_drag_coefficient_apply(settings_drag_coefficient_value(d));
    }
    return result;
}

// Manual apply for Lock Screen Duration (structured like the OTA disabler):
// opens a SpringBoard RemoteCall session, writes the SBMinimumLockscreenIdleTime
// preference, and leaves the rest to the respring the caller offers. Passing 0
// removes the floor. Takes effect on the next respring and persists.
static bool settings_apply_lock_screen_duration_body(long long seconds)
{
    if (!settings_ensure_kexploit()) {
        printf("[LSD] kernel primitives were not acquired\n");
        log_user("[LSD] Failed: kernel primitives were not acquired. Run the chain first.\n");
        return false;
    }
    bool ok = false;
    @synchronized (settings_rc_lock()) {
        if (!settings_ensure_springboard_remote_call_locked()) {
            printf("[LSD] could not open SpringBoard channel\n");
        } else {
            ok = darksword_tweak_extend_lockscreen_duration_in_session(seconds);
        }
    }
    settings_notify_package_queue_changed_async();
    return ok;
}

static BOOL settings_apply_lock_screen_duration(long long seconds)
{
    if (__sync_lock_test_and_set(&g_settings_actions_running, 1)) {
        printf("[LSD] actions already running; ignoring request\n");
        log_user("[LSD] Another action is already running.\n");
        return NO;
    }
    @try {
        return settings_apply_lock_screen_duration_body(seconds);
    } @finally {
        __sync_lock_release(&g_settings_actions_running);
    }
}

// Reads the configured Lock Screen Duration floor from inside SpringBoard.
// Returns seconds (>0), 0 when stock/unset, or a negative sentinel:
//   -3 = another action is running, -2 = no kernel access, -1 = channel/read error.
static long long settings_read_lock_screen_duration(void)
{
    if (__sync_lock_test_and_set(&g_settings_actions_running, 1)) {
        printf("[LSD] actions already running; ignoring read request\n");
        return -3;
    }
    @try {
        if (!settings_ensure_kexploit_for_read()) {
            printf("[LSD] read: no kernel access; not running the exploit for a read\n");
            return -2;
        }
        @synchronized (settings_rc_lock()) {
            if (!settings_ensure_springboard_remote_call_locked()) {
                printf("[LSD] read: could not open SpringBoard channel\n");
                return -1;
            }
            return darksword_tweak_read_lockscreen_duration_in_session();
        }
    } @finally {
        __sync_lock_release(&g_settings_actions_running);
    }
}

static bool settings_apply_layout_extras_from_defaults_locked(NSUserDefaults *d)
{
    if (![d boolForKey:kSettingsLayoutExtrasEnabled]) return false;
    double exL  = (double)[d integerForKey:kSettingsLayoutHomeExtraLeft];
    double exR  = (double)[d integerForKey:kSettingsLayoutHomeExtraRight];
    double exT  = (double)[d integerForKey:kSettingsLayoutHomeExtraTop];
    double exB  = (double)[d integerForKey:kSettingsLayoutHomeExtraBottom];
    double dockExL = (double)[d integerForKey:kSettingsLayoutDockExtraLeft];
    double dockExR = (double)[d integerForKey:kSettingsLayoutDockExtraRight];
    NSInteger hsPct = [d integerForKey:kSettingsLayoutHomeScalePct];
    NSInteger dkPct = [d integerForKey:kSettingsLayoutDockScalePct];
    double homeScale = (hsPct > 0) ? (double)hsPct / 100.0 : 1.0;
    double dockScale = (dkPct > 0) ? (double)dkPct / 100.0 : 1.0;
    return darksword_layout_apply_in_session(exL, exR, exT, exB, dockExL, dockExR, homeScale, dockScale);
}

static GravityLiteConfig settings_gravitylite_config_from_defaults(NSUserDefaults *d)
{
    NSInteger magnitudePct = [d integerForKey:kSettingsGravityLiteMagnitudePct];
    NSInteger bouncePct = [d integerForKey:kSettingsGravityLiteBouncePct];
    NSInteger frictionPct = [d integerForKey:kSettingsGravityLiteFrictionPct];
    NSInteger resistancePct = [d integerForKey:kSettingsGravityLiteResistancePct];
    NSInteger angularResistancePct = [d integerForKey:kSettingsGravityLiteAngularResistancePct];
    if (magnitudePct <= 0) magnitudePct = 100;
    if (resistancePct < 0) resistancePct = 0;
    if (angularResistancePct < 0) angularResistancePct = 0;

    GravityLiteConfig config = {
        .includeDock = [d boolForKey:kSettingsGravityLiteDockEnabled],
        .allowsRotation = true,
        .magnitude = (double)magnitudePct / 45.0,
        .bounce = (double)bouncePct / 100.0,
        .friction = (double)frictionPct / 100.0,
        .resistance = (double)resistancePct / 100.0,
        .angularResistance = (double)angularResistancePct / 100.0,
        .explosionForce = 7.0,
    };
    return config;
}

static bool settings_apply_gravitylite_from_defaults_locked(NSUserDefaults *d)
{
    if (![d boolForKey:kSettingsGravityLiteEnabled]) return false;
    return gravitylite_apply_in_session(settings_gravitylite_config_from_defaults(d));
}

static double settings_fastlockx_lite_retry_interval(NSUserDefaults *d)
{
    id raw = [d objectForKey:kSettingsFastLockXLiteRetryInterval];
    double value = [raw respondsToSelector:@selector(doubleValue)] ? [raw doubleValue] : 0.3;
    if (!isfinite(value) || value <= 0.0) value = 0.3;
    if (value < 0.1) value = 0.1;
    if (value > 2.0) value = 2.0;
    return value;
}

static FastLockXLiteConfig settings_fastlockx_lite_config_from_defaults(NSUserDefaults *d,
                                                                        BOOL pulse,
                                                                        BOOL unlock)
{
    FastLockXLiteConfig config = {
        .pulseBiometricRetry = pulse,
        .attemptUnlock = unlock,
        // Blockers are UI-disabled for now; keep the backend behavior aligned
        // so stale saved defaults don't silently change unlock behavior.
        .blockOnMusic = false,
        .blockOnFlashlight = false,
        .blockOnLowPowerMode = false,
        .diagnosticLogging = YES,
        .retryIntervalSeconds = settings_fastlockx_lite_retry_interval(d),
    };
    return config;
}

static void settings_restart_gravity_motion_if_active(const char *reason)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsGravityLiteEnabled]) return;
    if (!settings_tweak_is_applied(kSettingsGravityLiteEnabled)) return;
    if (!g_springboard_rc_ready || settings_cleanup_in_progress()) return;
    if (!settings_screen_awake_cached() || settings_screen_locked_cached()) return;
    if (g_gravity_motion_stop_requested == 0 && g_gravity_motion_manager) return;

    GravityLiteConfig config = settings_gravitylite_config_from_defaults(d);
    settings_start_gravity_motion(config.magnitude, config.explosionForce);
    printf("[GRAVITY] accelerometer loop restarted%s%s\n",
           reason ? ": " : "", reason ?: "");
}

static bool settings_arm_gravitylite_for_background_start_locked(NSUserDefaults *d,
                                                                 const char *reason)
{
    if (![d boolForKey:kSettingsGravityLiteEnabled]) return false;
    bool stopped = gravitylite_stop_in_session();
    __sync_lock_test_and_set(&g_gravitylite_background_armed, 1);
    settings_mark_tweak_applied(kSettingsGravityLiteEnabled, YES);
    printf("[SETTINGS] Gravity Lite armed for background start%s%s stop=%d\n",
           reason ? ": " : "", reason ?: "", stopped);
    return true;
}

static BOOL settings_gravitylite_start_window_ready(const char *reason)
{
    (void)settings_refresh_screen_awake_state(reason ?: "gravity start");
    (void)settings_refresh_screen_lock_state(reason ?: "gravity start");
    return settings_screen_awake_cached() && !settings_screen_locked_cached();
}

static void settings_apply_armed_gravitylite_once_async(const char *reason)
{
    if (g_gravitylite_start_worker_running != 0) {
        printf("[SETTINGS] Gravity async dispatch already running\n");
        return;
    }
    if (g_gravitylite_background_armed == 0) {
        printf("[SETTINGS] Gravity armed check failed: wasArmed=0\n");
        return;
    }
    if (settings_cleanup_in_progress()) {
        printf("[SETTINGS] Gravity skipped: cleanup in progress\n");
        return;
    }
    if (__sync_lock_test_and_set(&g_gravitylite_start_worker_running, 1)) {
        printf("[SETTINGS] Gravity async dispatch already running\n");
        return;
    }
    printf("[SETTINGS] Gravity async dispatch starting%s%s\n",
           reason ? ": " : "", reason ?: "");

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            printf("[SETTINGS] Gravity async worker entered state=%ld armed=%d rcReady=%d\n",
                   (long)[UIApplication sharedApplication].applicationState,
                   g_gravitylite_background_armed,
                   g_springboard_rc_ready);
            uint64_t waitDeadline = settings_now_us() + 30000000ULL;
            while (!settings_cleanup_in_progress() &&
                   g_gravitylite_background_armed != 0 &&
                   [d boolForKey:kSettingsGravityLiteEnabled] &&
                   g_springboard_rc_ready &&
                   !settings_gravitylite_start_window_ready(reason ?: "gravity start")) {
                if (settings_now_us() >= waitDeadline) {
                    printf("[SETTINGS] Gravity async dispatch waiting for app exit timed out\n");
                    return;
                }
                usleep(50000);
            }

            if (settings_cleanup_in_progress()) return;
            if (![d boolForKey:kSettingsGravityLiteEnabled] || !g_springboard_rc_ready) return;
            if (!settings_gravitylite_start_window_ready(reason ?: "gravity start")) return;

            bool ok = false;
            GravityLiteConfig appliedConfig = {0};
            uint64_t applyDeadline = settings_now_us() + 2000000ULL;
            int attempt = 0;
            do {
                usleep(80000);
                printf("[SETTINGS] Gravity async apply waiting for RemoteCall lock attempt=%d armed=%d state=%ld\n",
                       attempt + 1,
                       g_gravitylite_background_armed,
                       (long)[UIApplication sharedApplication].applicationState);
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() ||
                        !g_springboard_rc_ready ||
                        ![d boolForKey:kSettingsGravityLiteEnabled] ||
                        !settings_gravitylite_start_window_ready(reason ?: "gravity start")) {
                        return;
                    }
                    if (!__sync_bool_compare_and_swap(&g_gravitylite_background_armed, 1, 0) && attempt == 0) {
                        printf("[SETTINGS] Gravity armed check failed inside worker: wasArmed=%d\n",
                               g_gravitylite_background_armed);
                        return;
                    }
                    appliedConfig = settings_gravitylite_config_from_defaults(d);
                    printf("[SETTINGS] Gravity async apply attempt=%d begin\n", attempt + 1);
                    ok = gravitylite_apply_in_session(appliedConfig);
                    printf("[SETTINGS] Gravity async apply attempt=%d result=%d\n", attempt + 1, ok);
                    settings_mark_tweak_applied(kSettingsGravityLiteEnabled,
                                                ok && [d boolForKey:kSettingsGravityLiteEnabled]);
                }
                if (ok) break;
                attempt++;
                usleep(120000);
            } while (settings_now_us() < applyDeadline);

            if (ok) {
                settings_start_gravity_motion(appliedConfig.magnitude,
                                              appliedConfig.explosionForce);
                log_user("[OK] Gravity Lite active.\n");
                cyanide_upload_log_milestone(@"gravity-lite-applied");
            } else {
                log_user("[WARN] Gravity Lite did not start cleanly.\n");
                cyanide_upload_log_milestone(@"gravity-lite-warning");
            }

            printf("[SETTINGS] Gravity Lite start%s%s result=%d\n",
                   reason ? ": " : "", reason ?: "", ok);
            settings_notify_package_queue_changed_async();
        } @finally {
            __sync_lock_release(&g_gravitylite_start_worker_running);
        }
    });
}

static NSString * const kThemerThemeNone = @"";
static NSString * const kThemerThemeBuiltinIOS6 = @"builtin-ios6";
static NSString * const kThemerThemeCustom = @"custom";

static NSString *settings_themer_builtin_ios6_path(void)
{
    return [[NSBundle mainBundle].bundlePath
        stringByAppendingPathComponent:@"Themes-iOS6.plist"];
}

static NSString *settings_themer_documents_theme_root(void)
{
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.count == 0) return nil;
    return [docs.firstObject stringByAppendingPathComponent:@"Themes"];
}

static NSString *settings_themer_imported_theme_dir(void)
{
    NSString *root = settings_themer_documents_theme_root();
    return root ? [root stringByAppendingPathComponent:@"Imported"] : nil;
}

static NSString *settings_themer_imported_plist_path(void)
{
    NSString *root = settings_themer_documents_theme_root();
    return root ? [root stringByAppendingPathComponent:@"Imported.plist"] : nil;
}

static NSString *settings_themer_selected_theme_id(void)
{
    return [[NSUserDefaults standardUserDefaults] stringForKey:kSettingsThemerThemeID] ?: kThemerThemeNone;
}

BOOL settings_themer_has_selected_theme(void)
{
    NSString *theme = settings_themer_selected_theme_id();
    if ([theme isEqualToString:kThemerThemeBuiltinIOS6]) {
        return [[NSFileManager defaultManager] fileExistsAtPath:settings_themer_builtin_ios6_path()];
    }
    if ([theme isEqualToString:kThemerThemeCustom]) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *path = [d stringForKey:kSettingsThemerCustomThemePath];
        BOOL isDir = NO;
        return path.length > 0 &&
               [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    }
    return NO;
}

NSString *settings_themer_selected_theme_display_name(void)
{
    NSString *theme = settings_themer_selected_theme_id();
    if ([theme isEqualToString:kThemerThemeBuiltinIOS6]) return @"iOS 6 Theme";
    if ([theme isEqualToString:kThemerThemeCustom]) {
        NSString *name = [[NSUserDefaults standardUserDefaults]
            stringForKey:kSettingsThemerCustomThemeName];
        return name.length > 0 ? name : @"Imported Theme";
    }
    return @"None";
}

static NSDictionary<NSString *, NSData *> *settings_themer_load_plist_theme(NSString *plistPath)
{
    NSError *err = nil;
    NSData *raw = [NSData dataWithContentsOfFile:plistPath options:0 error:&err];
    if (!raw) {
        printf("[THEMER] resolve: failed to read plist err=%s\n",
               err.localizedDescription.UTF8String ?: "?");
        return nil;
    }
    id parsed = [NSPropertyListSerialization
        propertyListWithData:raw
                     options:NSPropertyListImmutable
                      format:NULL
                       error:&err];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        printf("[THEMER] resolve: plist parse failed err=%s\n",
               err.localizedDescription.UTF8String ?: "?");
        return nil;
    }
    NSDictionary *dict = (NSDictionary *)parsed;
    NSMutableDictionary<NSString *, NSData *> *out = [NSMutableDictionary dictionary];
    for (id key in dict) {
        id value = dict[key];
        if (![key isKindOfClass:NSString.class] ||
            ![value isKindOfClass:NSData.class] ||
            [(NSData *)value length] == 0) {
            continue;
        }
        out[key] = value;
    }
    printf("[THEMER] resolve: loaded plist theme entries=%lu size=%lu path=%s\n",
           (unsigned long)out.count,
           (unsigned long)raw.length,
           plistPath.UTF8String);
    return out;
}

// Per-bundle icon swap. A theme must be selected explicitly: either the bundled
// iOS 6 plist, or an imported folder/plist in Documents/Themes/.
static bool settings_apply_themer_from_defaults_locked(NSUserDefaults *d)
{
    if (![d boolForKey:kSettingsThemerEnabled]) {
        printf("[THEMER] resolve: toggle off, skipping\n");
        return false;
    }

    NSString *theme = settings_themer_selected_theme_id();
    if (![theme isEqualToString:kThemerThemeBuiltinIOS6] &&
        ![theme isEqualToString:kThemerThemeCustom]) {
        printf("[THEMER] resolve: no selected theme; install/apply blocked\n");
        log_user("[THEMER] Pick a theme in SnowBoard Lite settings before running.\n");
        return false;
    }

    if ([theme isEqualToString:kThemerThemeBuiltinIOS6]) {
        NSString *plistPath = settings_themer_builtin_ios6_path();
        if (![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
            printf("[THEMER] resolve: bundled plist missing at %s\n",
                   plistPath.UTF8String);
            return false;
        }
        NSDictionary *dict = settings_themer_load_plist_theme(plistPath);
        return dict.count > 0 ? themer_apply_data_in_session(dict) : false;
    }

    NSString *path = [d stringForKey:kSettingsThemerCustomThemePath];
    BOOL isDir = NO;
    if (path.length == 0 ||
        ![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]) {
        printf("[THEMER] resolve: selected custom theme missing path=%s\n",
               path.UTF8String ?: "");
        return false;
    }
    if (isDir) {
        printf("[THEMER] resolve: using imported folder %s\n", path.UTF8String);
        return themer_apply_in_session(path.fileSystemRepresentation);
    }
    NSDictionary *dict = settings_themer_load_plist_theme(path);
    return dict.count > 0 ? themer_apply_data_in_session(dict) : false;
}

static void settings_reset_sbc_defaults(void)
{
    if (!settings_device_supported()) {
        printf("[SETTINGS] SBC reset blocked: %s\n", settings_unsupported_message().UTF8String);
        return;
    }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:YES forKey:kSettingsSBCEnabled];
    [d setInteger:kSBCDefaultDockIcons forKey:kSettingsSBCDockIcons];
    [d setInteger:kSBCDefaultCols forKey:kSettingsSBCCols];
    [d setInteger:kSBCDefaultRows forKey:kSettingsSBCRows];
    [d setBool:kSBCDefaultHideLabels forKey:kSettingsSBCHideLabels];
    [d setBool:kSBCDefaultDockLabels forKey:kSettingsSBCDockLabels];
    [d setBool:kSBCDefaultArrangePages forKey:kSettingsSBCArrangePages];
    [d setInteger:kSBCDefaultFirstPageIcons forKey:kSettingsSBCFirstPageIcons];
    [d setInteger:kSBCDefaultOtherPageIcons forKey:kSettingsSBCOtherPageIcons];
    [d setBool:kSBCDefaultAutoDockApp forKey:kSettingsSBCAutoDockApp];
    [d setObject:kSBCDefaultDockAppBundleID forKey:kSettingsSBCDockAppBundleID];
    [d synchronize];

    printf("[SETTINGS] SBC reset defaults dock=%ld hs=%ldx%ld hideLabels=%d rcReady=%d\n",
           (long)kSBCDefaultDockIcons,
           (long)kSBCDefaultCols,
           (long)kSBCDefaultRows,
           kSBCDefaultHideLabels,
           g_springboard_rc_ready);

    if (!g_springboard_rc_ready) return;

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        @synchronized (settings_rc_lock()) {
            if (!g_springboard_rc_ready) return;
            bool ok = settings_apply_sbc_from_defaults_locked(d);
            settings_mark_tweak_applied(kSettingsSBCEnabled,
                                        ok && [d boolForKey:kSettingsSBCEnabled]);
            printf("[SETTINGS] SBC reset apply result=%d\n", ok);
        }
        settings_notify_package_queue_changed_async();
    });
}

static bool settings_apply_ota_disabled_body(BOOL disable)
{
    if (!settings_ensure_kexploit()) {
        printf("[OTA] kernel primitives were not acquired\n");
        log_user("[OTA] Failed: kernel primitives were not acquired. Please try running chain again.\n");
        return false;
    }

    bool ok = darksword_ota_set_disabled(disable);

    settings_notify_package_queue_changed_async();
    return ok;
}

// File-local since the OTA package stopped committing through the install
// queue; settings_run_ota_action() below is the only caller.
static BOOL settings_apply_ota_disabled(BOOL disable)
{
    if (__sync_lock_test_and_set(&g_settings_actions_running, 1)) {
        printf("[SETTINGS] actions already running; ignoring OTA request\n");
        log_user("[OTA] Another action is already running.\n");
        return NO;
    }
    @try {
        return settings_apply_ota_disabled_body(disable);
    } @finally {
        __sync_lock_release(&g_settings_actions_running);
    }
}

// Reads current OTA state. Returns 0/1/2 (see darksword_ota_read_disabled) or a
// negative sentinel: -3 = another action running, -2 = no kernel access,
// -1 = filesystem access denied / read failed.
static int settings_read_ota_status(void)
{
    if (__sync_lock_test_and_set(&g_settings_actions_running, 1)) {
        printf("[SETTINGS] actions already running; ignoring OTA status read\n");
        return -3;
    }
    @try {
        if (!settings_ensure_kexploit_for_read()) {
            printf("[OTA] status read: no kernel access; not running the exploit for a read\n");
            return -2;
        }
        return darksword_ota_read_disabled();
    } @finally {
        __sync_lock_release(&g_settings_actions_running);
    }
}

static void settings_run_ota_action(BOOL disable)
{
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        log_user("[OTA] %s OTA updates.\n", disable ? "Disabling" : "Enabling");
        bool ok = settings_apply_ota_disabled(disable);
        printf("[SETTINGS] OTA %s result=%d\n", disable ? "disable" : "enable", ok);
        if (ok) {
            log_user("[OK] OTA updates %s. Respring or reboot required for changes to take effect.\n",
                     disable ? "disabled" : "enabled");
        } else {
            log_user("[FAIL] OTA %s failed — see log for [OTA] lines (likely sandbox patch or disabled.plist write).\n",
                     disable ? "disable" : "enable");
        }
    });
}

static void settings_nano_set_defaults_values(NSInteger maxV, NSInteger minV, NSInteger minChipV, NSInteger minQuickV)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:maxV     forKey:kSettingsNanoMaxPairing];
    [d setInteger:minV     forKey:kSettingsNanoMinPairing];
    [d setInteger:minChipV forKey:kSettingsNanoMinPairingChipID];
    [d setInteger:minQuickV forKey:kSettingsNanoMinQuickSwitch];
}

static void settings_nano_load_from_plist_into_defaults(BOOL logResult)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    nano_registry_values values = {
        .max_pairing         = (int)[d integerForKey:kSettingsNanoMaxPairing],
        .min_pairing         = (int)[d integerForKey:kSettingsNanoMinPairing],
        .min_pairing_chip_id = (int)[d integerForKey:kSettingsNanoMinPairingChipID],
        .min_quick_switch    = (int)[d integerForKey:kSettingsNanoMinQuickSwitch],
    };
    bool present = false;
    bool ok = nano_registry_load(&values, &present);
    if (!ok) {
        if (logResult) log_user("[NANO] Could not read existing override plist (parse failure).\n");
        return;
    }
    [d setInteger:values.max_pairing         forKey:kSettingsNanoMaxPairing];
    [d setInteger:values.min_pairing         forKey:kSettingsNanoMinPairing];
    [d setInteger:values.min_pairing_chip_id forKey:kSettingsNanoMinPairingChipID];
    [d setInteger:values.min_quick_switch    forKey:kSettingsNanoMinQuickSwitch];
    if (logResult) {
        log_user(present
                 ? "[NANO] Loaded existing override: max=%d min=%d minChip=%d minQuick=%d.\n"
                 : "[NANO] No override present on device. Editor populated with current/seed values.\n",
                 values.max_pairing, values.min_pairing,
                 values.min_pairing_chip_id, values.min_quick_switch);
    }
}

// Synchronous entry point used by both the Settings UI buttons and the
// Installer's PackageQueue commit path. Logs progress to the in-app log so
// the InstallProgressViewController shows real lines during the apply.
BOOL settings_apply_nano_registry_now(BOOL apply)
{
    if (!settings_try_claim_actions_lock("NanoRegistry apply",
                                         "[NANO] Another action is already running.")) {
        return NO;
    }

    @try {
        if (!settings_ensure_kexploit()) {
            log_user("[NANO] Failed: kernel primitives were not acquired. Please try running chain again.\n");
            return NO;
        }

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        bool ok;
        nano_registry_values values = {
            .max_pairing         = (int)[d integerForKey:kSettingsNanoMaxPairing],
            .min_pairing         = (int)[d integerForKey:kSettingsNanoMinPairing],
            .min_pairing_chip_id = (int)[d integerForKey:kSettingsNanoMinPairingChipID],
            .min_quick_switch    = (int)[d integerForKey:kSettingsNanoMinQuickSwitch],
        };
        if (apply) {
            log_user("[NANO] Applying pairing override max=%d min=%d minChip=%d minQuick=%d.\n",
                     values.max_pairing, values.min_pairing,
                     values.min_pairing_chip_id, values.min_quick_switch);
            ok = nano_registry_apply(&values);
            if (!ok) {
                log_user("[FAIL] NanoRegistry override write failed — see log for [NANO] lines.\n");
            }
        } else {
            log_user("[NANO] Removing pairing override keys.\n");
            ok = nano_registry_clear();
            if (!ok) {
                log_user("[FAIL] NanoRegistry override clear failed — see log for [NANO] lines.\n");
            }
        }

        // The file write above is necessary but not sufficient — cfprefsd owns
        // the in-memory cache that every CFPreferencesCopyValue call serves
        // from, and it will overwrite our plist with its stale cache the next
        // time any process writes to com.apple.NanoRegistry via the API. Push
        // the same values into cfprefsd's cache so the cache *has* our
        // override and future serializations preserve it.
        if (ok) {
            bool pushed = nano_registry_push_to_cfprefsd(&values, apply ? true : false);
            if (!pushed) {
                log_user("[NANO] cfprefsd push failed; on-disk override may be overwritten by cfprefsd's stale cache.\n");
            }
        }

        return ok ? YES : NO;
    } @finally {
        settings_release_actions_lock();
    }
}

BOOL settings_apply_call_recording_sound_disabled(BOOL disabled)
{
    if (!settings_try_claim_actions_lock("CallRec sound apply",
                                         "[CALLREC] Another action is already running.")) {
        return NO;
    }

    @try {
        if (!settings_ensure_kexploit()) {
            log_user("[CALLREC] Failed: kernel primitives were not acquired. Please try running chain again.\n");
            return NO;
        }
        return call_recording_sound_set_disabled(disabled) ? YES : NO;
    } @finally {
        settings_release_actions_lock();
    }
}

BOOL settings_apply_passcode_theme_now(BOOL apply)
{
    if (!settings_try_claim_actions_lock("Passcode style apply",
                                         "[PASSCODE] Another action is already running.")) {
        return NO;
    }

    // No session handling here, same as every other panel action (Call
    // Recording, Hide Home Bar, Watch Pairing): the log lines go to the in-app
    // buffer and, when a chain session file is open, are appended to it. After a
    // fresh launch the queue run is what opens that file.
    @try {
        if (!settings_ensure_kexploit()) {
            log_user("[PASSCODE] Failed: kernel primitives were not acquired. Please try running chain again.\n");
            return NO;
        }

        if (!apply) {
            // nil: the cache path is resolved inside, after the sandbox is unlocked.
            return settings_passcode_restore_originals(nil) ? YES : NO;
        }

        NSDictionary *theme = settings_passcode_selected_theme();
        if (!theme) {
            log_user("[PASSCODE] Failed: no style is selected. Import or build one first.\n");
            return NO;
        }

        NSDictionary<NSString *, NSData *> *digits = settings_passcode_theme_digit_images(theme);
        if (digits.count == 0) {
            log_user("[PASSCODE] Failed: the selected style has no digit art.\n");
            return NO;
        }
        return settings_passcode_apply_digits(digits) ? YES : NO;
    } @finally {
        settings_release_actions_lock();
    }
}

BOOL settings_apply_hide_home_bar_hidden(BOOL hidden)
{
    if (!settings_try_claim_actions_lock("Hide Home Bar apply",
                                         "[HOME BAR] Another action is already running.")) {
        return NO;
    }

    @try {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (!hidden) {
            BOOL ok = hide_home_bar_restore() ? YES : NO;
            if (ok) {
                settings_set_hide_home_bar_registered_hidden(d, NO, YES);
            }
            return ok;
        }
        if (!settings_ensure_kexploit()) {
            log_user("[HOME BAR] Failed: kernel primitives were not acquired. Please try running chain again.\n");
            return NO;
        }
        BOOL ok = hide_home_bar_apply() ? YES : NO;
        if (ok) settings_set_hide_home_bar_registered_hidden(d, YES, YES);
        return ok;
    } @finally {
        settings_release_actions_lock();
    }
}

static void settings_run_nano_apply_action(void)
{
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        (void)settings_apply_nano_registry_now(YES);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:kSettingsActionsDidCompleteNotification
                              object:nil];
        });
    });
}

static void settings_run_nano_clear_action(void)
{
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        (void)settings_apply_nano_registry_now(NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:kSettingsActionsDidCompleteNotification
                              object:nil];
        });
    });
}

static void settings_run_nano_probe_action(void)
{
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        if (!settings_try_claim_actions_lock("NanoRegistry probe",
                                             "[NANO-PROBE] Another action is already running.")) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:kSettingsActionsDidCompleteNotification
                                  object:nil];
            });
            return;
        }
        @try {
            if (!settings_ensure_kexploit_for_read()) {
                log_user("[NANO-PROBE] Failed: no kernel access. Run the chain first — a probe "
                         "will not start the exploit on its own.\n");
            } else {
                (void)nano_registry_probe_pairing_assets();
            }
        } @finally {
            settings_release_actions_lock();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:kSettingsActionsDidCompleteNotification
                              object:nil];
        });
    });
}

static void settings_run_nano_steer_action(void)
{
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        if (!settings_try_claim_actions_lock("NanoRegistry steer",
                                             "[NANO-STEER] Another action is already running.")) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:kSettingsActionsDidCompleteNotification
                                  object:nil];
            });
            return;
        }
        @try {
            if (!settings_ensure_kexploit()) {
                log_user("[NANO-STEER] Failed: kernel primitives were not acquired. Please try running chain again.\n");
            } else {
                (void)nano_registry_steer_new_watch_product_alias();
            }
        } @finally {
            settings_release_actions_lock();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:kSettingsActionsDidCompleteNotification
                              object:nil];
        });
    });
}

static void settings_run_nano_seed_action(void)
{
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        if (!settings_try_claim_actions_lock("NanoRegistry seed",
                                             "[NANO-SEED] Another action is already running.")) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:kSettingsActionsDidCompleteNotification
                                  object:nil];
            });
            return;
        }
        @try {
            if (!settings_ensure_kexploit()) {
                log_user("[NANO-SEED] Failed: kernel primitives were not acquired. Please try running chain again.\n");
            } else {
                NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
                nano_registry_values values = {
                    .max_pairing         = (int)[d integerForKey:kSettingsNanoMaxPairing],
                    .min_pairing         = (int)[d integerForKey:kSettingsNanoMinPairing],
                    .min_pairing_chip_id = (int)[d integerForKey:kSettingsNanoMinPairingChipID],
                    .min_quick_switch    = (int)[d integerForKey:kSettingsNanoMinQuickSwitch],
                };
                bool ok = nano_registry_seed_current_phone_compatibility_index(values.max_pairing);
                if (ok) {
                    (void)nano_registry_push_to_cfprefsd(&values, true);
                }
            }
        } @finally {
            settings_release_actions_lock();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:kSettingsActionsDidCompleteNotification
                              object:nil];
        });
    });
}

static void settings_start_statbar_live_loop(void)
{
    if (!settings_device_supported()) return;
    if (settings_cleanup_in_progress()) return;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsStatBarEnabled]) return;

    if (__sync_lock_test_and_set(&g_statbar_live_running, 1)) {
        // Log-once for the process lifetime; further "already running" hits
        // during foreground/background lifecycle churn are pure noise.
        static volatile int loggedAlready = 0;
        if (__sync_bool_compare_and_swap(&loggedAlready, 0, 1)) {
            printf("[SETTINGS] StatBar live loop already running\n");
        }
        return;
    }

    if (settings_cleanup_in_progress()) {
        __sync_lock_release(&g_statbar_live_running);
        return;
    }

    g_statbar_live_stop_requested = 0;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSUInteger tick = 0;
        NSUInteger failures = 0;
        uint64_t nextTickUS = settings_now_us();
        BOOL pausedForSleep = NO;

        printf("[SETTINGS] StatBar live loop started interval=%uus background=%uus max=%lu\n",
               kStatBarLiveIntervalUS,
               settings_statbar_refresh_rate_us(),
               (unsigned long)kStatBarLiveMaxTicks);
        cyanide_upload_log_milestone(@"statbar-live-started");

        @try {
            while ([d boolForKey:kSettingsStatBarEnabled] &&
                   !settings_cleanup_in_progress() &&
                   !g_statbar_live_stop_requested &&
                   tick < kStatBarLiveMaxTicks) {
                useconds_t intervalUS = settings_statbar_live_interval_us();
                if (!settings_statbar_screen_awake()) {
                    if (!pausedForSleep) {
                        pausedForSleep = YES;
                        printf("[SETTINGS] StatBar paused while screen is asleep\n");
                    }
                    settings_live_loop_sleep_interruptible(0,
                                                           intervalUS,
                                                           &g_statbar_live_stop_requested);
                    nextTickUS = settings_now_us();
                    continue;
                }
                if (pausedForSleep) {
                    pausedForSleep = NO;
                    printf("[SETTINGS] StatBar resumed after screen wake\n");
                }

                uint64_t tickStartUS = settings_now_us();
                bool ok = false;

                @synchronized (settings_rc_lock()) {
                    if (g_statbar_live_stop_requested) break;
                    if (!g_springboard_rc_ready) {
                        printf("[SETTINGS] StatBar loop has no SpringBoard RemoteCall session\n");
                        failures++;
                        break;
                    }
                    ok = statbar_apply_in_session([d boolForKey:kSettingsStatBarCelsius],
                                                  [d boolForKey:kSettingsStatBarShowNet],
                                                  [d boolForKey:kSettingsStatBarShowCPU],
                                                  [d boolForKey:kSettingsStatBarShowLabels],
                                                  [d boolForKey:kSettingsStatBarNetworkOnly]);
                }

                if (tick == 0) {
                    printf("[SETTINGS] StatBar result=%d\n", ok);
                    cyanide_upload_log_milestone(ok ? @"statbar-live-first-ok" : @"statbar-live-first-failed");
                }
                if (ok) {
                    failures = 0;
                } else {
                    failures++;
                    printf("[SETTINGS] StatBar tick failed tick=%lu failures=%lu\n",
                           (unsigned long)tick, (unsigned long)failures);
                    if (failures >= settings_live_failure_limit(3)) break;
                }

                tick++;
                if (![d boolForKey:kSettingsStatBarEnabled] ||
                    g_statbar_live_stop_requested ||
                    tick >= kStatBarLiveMaxTicks) break;

                uint64_t nowUS = settings_now_us();
                uint64_t elapsedUS = (tickStartUS != 0 && nowUS >= tickStartUS) ? (nowUS - tickStartUS) : 0;
                if (nextTickUS != 0) {
                    intervalUS = settings_statbar_live_interval_us();
                    nextTickUS += intervalUS;
                    if (nowUS < nextTickUS) {
                        uint64_t sleepUS = nextTickUS - nowUS;
                        if (settings_should_log_statbar_tick(tick - 1)) {
                            printf("[SETTINGS] StatBar tick=%lu elapsed=%lluus sleep=%lluus mode=%s\n",
                                   (unsigned long)(tick - 1),
                                   elapsedUS,
                                   sleepUS,
                                   settings_live_context());
                        }
                        settings_live_loop_sleep_interruptible(nextTickUS,
                                                               (useconds_t)sleepUS,
                                                               &g_statbar_live_stop_requested);
                    } else {
                        uint64_t overrunUS = nowUS - nextTickUS;
                        if (settings_should_log_statbar_tick(tick - 1)) {
                            printf("[SETTINGS] StatBar tick=%lu elapsed=%lluus overrun=%lluus mode=%s\n",
                                   (unsigned long)(tick - 1),
                                   elapsedUS,
                                   overrunUS,
                                   settings_live_context());
                        }
                        nextTickUS = nowUS;
                    }
                } else {
                    settings_live_loop_sleep_interruptible(0,
                                                           settings_statbar_live_interval_us(),
                                                           &g_statbar_live_stop_requested);
                }
            }
        } @finally {
            printf("[SETTINGS] StatBar live loop exited ticks=%lu enabled=%d failures=%lu stop=%d\n",
                   (unsigned long)tick,
                   [d boolForKey:kSettingsStatBarEnabled],
                   (unsigned long)failures,
                   g_statbar_live_stop_requested);
            if (![d boolForKey:kSettingsStatBarEnabled] || g_statbar_live_stop_requested || failures > 0) {
                settings_end_statbar_background_task_async("live loop exited");
            }
            if (failures > 0)
                cyanide_upload_log_milestone(@"statbar-live-exited-failed");
            __sync_lock_release(&g_statbar_live_running);
        }
    });
}

static int settings_current_ios_major(void)
{
    return (int)[[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
}

// iOS 17 Hide Labels live loop. iOS 18+ has a durable layout-config label switch
// (handled in SBCustomizer), so this only runs on iOS < 18. Each tick re-hides
// the current home-screen page's icon labels; the per-view flag survives relayout,
// so a page only needs hiding the first time it's swiped into view. Keeping the
// SpringBoard session alive is handled by the "Hide Labels" cleanup-table entry,
// gated on kSettingsSBCHideLabels being applied (marked below).
static void settings_start_labels_live_loop(void)
{
    if (!settings_device_supported()) return;
    if (settings_cleanup_in_progress()) return;
    if (settings_current_ios_major() >= 18) return;   // config lever handles 18+

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsSBCEnabled] || ![d boolForKey:kSettingsSBCHideLabels]) return;

    if (__sync_lock_test_and_set(&g_labels_live_running, 1)) {
        static volatile int loggedAlready = 0;
        if (__sync_bool_compare_and_swap(&loggedAlready, 0, 1))
            printf("[SETTINGS] Hide Labels live loop already running\n");
        return;
    }
    if (settings_cleanup_in_progress()) { __sync_lock_release(&g_labels_live_running); return; }

    // Mark applied so settings_has_persistent_springboard_remote_call_user() keeps
    // the SpringBoard session alive for the loop.
    settings_mark_tweak_applied(kSettingsSBCHideLabels, YES);
    g_labels_live_stop_requested = 0;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSUInteger tick = 0;
        NSUInteger failures = 0;
        NSUInteger hotTicks = 0;   // keep hiding briefly after a page change
        uint64_t lastToken = 0;
        BOOL wasAsleep = NO;       // force a re-hide on the first awake tick
        printf("[SETTINGS] Hide Labels live loop started interval=%uus\n", kLabelsLiveIntervalUS);
        @try {
            while ([d boolForKey:kSettingsSBCEnabled] &&
                   [d boolForKey:kSettingsSBCHideLabels] &&
                   !settings_cleanup_in_progress() &&
                   !g_labels_live_stop_requested &&
                   tick < kLabelsLiveMaxTicks) {
                if (!settings_statbar_screen_awake()) {
                    wasAsleep = YES;   // unlock re-renders the home screen w/ labels
                    settings_live_loop_sleep_interruptible(0, kLabelsLiveIntervalUS,
                                                           &g_labels_live_stop_requested);
                    continue;
                }
                bool haveSession = false;
                @synchronized (settings_rc_lock()) {
                    if (g_labels_live_stop_requested) break;
                    if (g_springboard_rc_ready) {
                        haveSession = true;
                        // On wake (screen just turned back on / unlock), the home
                        // screen was re-rendered with labels; force an immediate
                        // re-hide + hot burst instead of waiting for the fallback.
                        if (wasAsleep) { wasAsleep = NO; lastToken = 0; hotTicks = 8; }
                        // Cheap poll: read the current page identity every tick and
                        // only do the full label walk when the page changed (a swipe)
                        // — or every ~1.5s as a fallback for stragglers (e.g. after an
                        // app closes and its icon view is rebuilt with a label).
                        uint64_t token = sbcustomizer_current_page_token();
                        bool changed = (token != lastToken);
                        // A page change flips the token early in the swipe, before
                        // all of the new page's icon views are built. Stay "hot" for
                        // ~800ms after a change so late-instantiating views get their
                        // labels hidden within a fraction of a second, not at the
                        // ~1.5s fallback.
                        if (changed) hotTicks = 8;
                        if (changed || hotTicks > 0 || tick == 0 || (tick % 15) == 0) {
                            int hid = sbcustomizer_hide_home_labels_in_session();
                            if (tick == 0)
                                printf("[SETTINGS] Hide Labels first tick hid=%d\n", hid);
                        }
                        if (hotTicks > 0) hotTicks--;
                        lastToken = token;
                    }
                }
                if (!haveSession) {
                    printf("[SETTINGS] Hide Labels loop has no SpringBoard session\n");
                    if (++failures >= settings_live_failure_limit(3)) break;
                } else {
                    failures = 0;
                }
                tick++;
                settings_live_loop_sleep_interruptible(0, kLabelsLiveIntervalUS,
                                                       &g_labels_live_stop_requested);
            }
        } @finally {
            printf("[SETTINGS] Hide Labels live loop exited ticks=%lu stop=%d\n",
                   (unsigned long)tick, g_labels_live_stop_requested);
            __sync_lock_release(&g_labels_live_running);
        }
    });
}

// Re-establish the Hide Labels loop on foreground/become-active, mirroring the
// other live tweaks (gated on an already-ready SpringBoard session).
static void settings_apply_labels_once_async(const char *reason)
{
    (void)reason;
    if (!settings_device_supported() || settings_cleanup_in_progress()) return;
    if (settings_current_ios_major() >= 18) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsSBCEnabled] || ![d boolForKey:kSettingsSBCHideLabels] ||
        !g_springboard_rc_ready) return;
    if (g_labels_live_running) return;

    // Ask SpringBoard whether the hook is still live. If it is (normal foreground/
    // unlock, same SpringBoard session), do nothing — it keeps the labels hidden on
    // its own, and re-writing the method table here is what crashed SpringBoard. Only
    // when it's genuinely gone (a respring wiped it) do we install it again — exactly
    // once, the thread-safe swap only, NO live-view walk.
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        BOOL ok = NO;
        @synchronized (settings_rc_lock()) {
            if (settings_cleanup_in_progress() ||
                ![d boolForKey:kSettingsSBCHideLabels] || !g_springboard_rc_ready) return;
            if (sbcustomizer_home_labels_hook_active()) {
                ok = YES;   // still installed; leave it alone
            } else {
                ok = sbcustomizer_swizzle_home_labels_hidden() != 0;
                printf("[SETTINGS] Hide Labels re-armed after session drop: durable=%d\n", ok);
            }
        }
        if (ok) settings_mark_tweak_applied(kSettingsSBCHideLabels, YES);
        else settings_start_labels_live_loop();   // fallback only
    });
}

static void settings_apply_statbar_once_async(const char *reason)
{
    if (!settings_device_supported()) return;
    if (settings_cleanup_in_progress()) return;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsStatBarEnabled] || !g_springboard_rc_ready) return;
    if (g_statbar_live_running) return;

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        if (settings_cleanup_in_progress()) return;
        bool ok = false;
        (void)settings_refresh_screen_awake_state(reason ?: "statbar apply");
        if (!settings_screen_awake_cached()) {
            printf("[SETTINGS] StatBar lifecycle apply%s%s skipped: screen asleep\n",
                   reason ? ": " : "", reason ?: "");
            settings_start_statbar_live_loop();
            return;
        }
        @synchronized (settings_rc_lock()) {
            if (settings_cleanup_in_progress() ||
                ![d boolForKey:kSettingsStatBarEnabled] ||
                !g_springboard_rc_ready) return;
            ok = statbar_apply_in_session([d boolForKey:kSettingsStatBarCelsius],
                                          [d boolForKey:kSettingsStatBarShowNet],
                                          [d boolForKey:kSettingsStatBarShowCPU],
                                          [d boolForKey:kSettingsStatBarShowLabels],
                                          [d boolForKey:kSettingsStatBarNetworkOnly]);
        }
        // Only log lifecycle applies that change result; a clean success on
        // every foreground/background flip is noise.
        static volatile int lastResult = -1;
        int now = ok ? 1 : 0;
        if (now != lastResult) {
            lastResult = now;
            printf("[SETTINGS] StatBar lifecycle apply%s%s result=%d\n",
                   reason ? ": " : "", reason ?: "", ok);
        }
        settings_start_statbar_live_loop();
    });
}

static void settings_start_nsbar_live_loop(void)
{
    if (!settings_device_supported() || settings_cleanup_in_progress()) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsNSBarEnabled] || !g_springboard_rc_ready) return;

    if (__sync_lock_test_and_set(&g_nsbar_live_running, 1)) return;
    g_nsbar_live_stop_requested = 0;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSUInteger tick = 0;
        NSUInteger failures = 0;
        BOOL pausedForSleep = NO;
        @try {
            while ([d boolForKey:kSettingsNSBarEnabled] &&
                   !settings_cleanup_in_progress() &&
                   !g_nsbar_live_stop_requested &&
                   tick < kNSBarLiveMaxTicks) {
                useconds_t intervalUS = settings_live_interval(kNSBarLiveIntervalUS,
                                                               kNSBarLiveBackgroundIntervalUS);
                if (!settings_statbar_screen_awake()) {
                    if (!pausedForSleep) {
                        pausedForSleep = YES;
                        printf("[SETTINGS] NSBar paused while screen is asleep\n");
                    }
                    settings_live_loop_sleep_interruptible(0,
                                                           intervalUS,
                                                           &g_nsbar_live_stop_requested);
                    continue;
                }
                if (pausedForSleep) {
                    pausedForSleep = NO;
                    printf("[SETTINGS] NSBar resumed after screen wake\n");
                }

                bool ok = false;
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() ||
                        ![d boolForKey:kSettingsNSBarEnabled] ||
                        !g_springboard_rc_ready) break;
                    ok = nsbar_apply_in_session((NSBarPosition)[d integerForKey:kSettingsNSBarPosition]);
                    settings_mark_tweak_applied(kSettingsNSBarEnabled,
                                                ok && [d boolForKey:kSettingsNSBarEnabled]);
                }
                if (tick == 0 || !ok) {
                    printf("[SETTINGS] NSBar live tick=%lu result=%d\n",
                           (unsigned long)tick, ok);
                }
                failures = ok ? 0 : failures + 1;
                if (failures >= settings_live_failure_limit(3)) break;
                tick++;
                settings_live_loop_sleep_interruptible(0,
                    intervalUS,
                    &g_nsbar_live_stop_requested);
            }
        } @finally {
            printf("[SETTINGS] NSBar live loop exited ticks=%lu enabled=%d failures=%lu stop=%d\n",
                   (unsigned long)tick,
                   [d boolForKey:kSettingsNSBarEnabled],
                   (unsigned long)failures,
                   g_nsbar_live_stop_requested);
            __sync_lock_release(&g_nsbar_live_running);
        }
    });
}

static void settings_apply_nsbar_once_async(const char *reason)
{
    if (!settings_device_supported() || settings_cleanup_in_progress()) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsNSBarEnabled] || !g_springboard_rc_ready) return;
    if (g_nsbar_live_running) return;

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        bool ok = false;
        (void)settings_refresh_screen_awake_state(reason ?: "nsbar apply");
        if (!settings_screen_awake_cached()) {
            printf("[SETTINGS] NSBar lifecycle apply%s%s skipped: screen asleep\n",
                   reason ? ": " : "", reason ?: "");
            settings_start_nsbar_live_loop();
            return;
        }
        @synchronized (settings_rc_lock()) {
            if (settings_cleanup_in_progress() ||
                ![d boolForKey:kSettingsNSBarEnabled] ||
                !g_springboard_rc_ready) return;
            ok = nsbar_apply_in_session((NSBarPosition)[d integerForKey:kSettingsNSBarPosition]);
            settings_mark_tweak_applied(kSettingsNSBarEnabled,
                                        ok && [d boolForKey:kSettingsNSBarEnabled]);
        }
        printf("[SETTINGS] NSBar lifecycle apply%s%s result=%d\n",
               reason ? ": " : "", reason ?: "", ok);
        settings_start_nsbar_live_loop();
        settings_notify_package_queue_changed_async();
    });
}

static void settings_start_nicebarlite_live_loop(void)
{
    if (!settings_device_supported() || settings_cleanup_in_progress()) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsNiceBarLiteEnabled] || !g_springboard_rc_ready) return;

    if (__sync_lock_test_and_set(&g_nicebarlite_live_running, 1)) return;
    g_nicebarlite_live_stop_requested = 0;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSUInteger tick = 0;
        NSUInteger failures = 0;
        BOOL pausedForSleep = NO;
        @try {
            while ([d boolForKey:kSettingsNiceBarLiteEnabled] &&
                   !settings_cleanup_in_progress() &&
                   !g_nicebarlite_live_stop_requested &&
                   tick < kNiceBarLiteLiveMaxTicks) {
                useconds_t intervalUS = settings_live_interval(kNiceBarLiteLiveIntervalUS,
                                                               kNiceBarLiteLiveBackgroundIntervalUS);
                if (!settings_statbar_screen_awake()) {
                    if (!pausedForSleep) {
                        pausedForSleep = YES;
                        printf("[SETTINGS] NiceBar Lite paused while screen is asleep\n");
                    }
                    settings_live_loop_sleep_interruptible(0,
                                                           intervalUS,
                                                           &g_nicebarlite_live_stop_requested);
                    continue;
                }
                if (pausedForSleep) {
                    pausedForSleep = NO;
                    printf("[SETTINGS] NiceBar Lite resumed after screen wake\n");
                }

                bool ok = false;
                settings_nicebar_refresh_weather_if_needed(NO, nil);
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() ||
                        ![d boolForKey:kSettingsNiceBarLiteEnabled] ||
                        !g_springboard_rc_ready) break;
                    ok = settings_apply_nicebarlite_from_defaults_locked(d);
                    settings_mark_tweak_applied(kSettingsNiceBarLiteEnabled,
                                                ok && [d boolForKey:kSettingsNiceBarLiteEnabled]);
                }
                if (tick == 0 || !ok) {
                    printf("[SETTINGS] NiceBar Lite live tick=%lu result=%d\n",
                           (unsigned long)tick, ok);
                }
                failures = ok ? 0 : failures + 1;
                if (failures >= settings_live_failure_limit(3)) break;
                tick++;
                settings_live_loop_sleep_interruptible(0,
                    intervalUS,
                    &g_nicebarlite_live_stop_requested);
            }
        } @finally {
            printf("[SETTINGS] NiceBar Lite live loop exited ticks=%lu enabled=%d failures=%lu stop=%d\n",
                   (unsigned long)tick,
                   [d boolForKey:kSettingsNiceBarLiteEnabled],
                   (unsigned long)failures,
                   g_nicebarlite_live_stop_requested);
            __sync_lock_release(&g_nicebarlite_live_running);
        }
    });
}

static void settings_apply_nicebarlite_once_async(const char *reason)
{
    if (!settings_device_supported() || settings_cleanup_in_progress()) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsNiceBarLiteEnabled] || !g_springboard_rc_ready) return;
    if (g_nicebarlite_live_running) return;

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        bool ok = false;
        settings_nicebar_refresh_weather_if_needed(!settings_nicebar_has_resolved_weather(d), nil);
        (void)settings_refresh_screen_awake_state(reason ?: "nicebarlite apply");
        if (!settings_screen_awake_cached()) {
            printf("[SETTINGS] NiceBar Lite lifecycle apply%s%s skipped: screen asleep\n",
                   reason ? ": " : "", reason ?: "");
            settings_start_nicebarlite_live_loop();
            return;
        }
        @synchronized (settings_rc_lock()) {
            if (settings_cleanup_in_progress() ||
                ![d boolForKey:kSettingsNiceBarLiteEnabled] ||
                !g_springboard_rc_ready) return;
            ok = settings_apply_nicebarlite_from_defaults_locked(d);
            settings_mark_tweak_applied(kSettingsNiceBarLiteEnabled,
                                        ok && [d boolForKey:kSettingsNiceBarLiteEnabled]);
        }
        printf("[SETTINGS] NiceBar Lite lifecycle apply%s%s result=%d\n",
               reason ? ": " : "", reason ?: "", ok);
        settings_start_nicebarlite_live_loop();
        settings_notify_package_queue_changed_async();
    });
}

static BOOL settings_livewp_should_play(void)
{
    (void)settings_refresh_screen_awake_state("LiveWP playback check");
    return settings_screen_awake_cached();
}

static void settings_start_livewp_live_loop(void)
{
    if (!settings_device_supported() || settings_cleanup_in_progress()) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsLiveWPEnabled] || !g_springboard_rc_ready) return;

    if (__sync_lock_test_and_set(&g_livewp_live_running, 1)) return;
    g_livewp_live_stop_requested = 0;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSUInteger tick = 0;
        @try {
            while ([d boolForKey:kSettingsLiveWPEnabled] &&
                   !settings_cleanup_in_progress() &&
                   !g_livewp_live_stop_requested &&
                   tick < kLiveWPLiveMaxTicks) {
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() ||
                        ![d boolForKey:kSettingsLiveWPEnabled] ||
                        !g_springboard_rc_ready) break;
                    if (settings_livewp_should_play()) {
                        (void)livewp_resume_in_session();
                        (void)livewp_repair_in_session();
                    } else {
                        (void)livewp_pause_in_session();
                    }
                }
                tick++;
                settings_live_loop_sleep_interruptible(0,
                    settings_live_interval(kLiveWPLiveIntervalUS, kLiveWPLiveBackgroundIntervalUS),
                    &g_livewp_live_stop_requested);
            }
        } @finally {
            printf("[SETTINGS] LiveWP live loop exited ticks=%lu enabled=%d stop=%d\n",
                   (unsigned long)tick,
                   [d boolForKey:kSettingsLiveWPEnabled],
                   g_livewp_live_stop_requested);
            __sync_lock_release(&g_livewp_live_running);
        }
    });
}

static void settings_pause_livewp_for_sleep_async(const char *reason)
{
    if (!settings_device_supported() || settings_cleanup_in_progress()) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsLiveWPEnabled] || !g_springboard_rc_ready) return;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        @synchronized (settings_rc_lock()) {
            if (settings_cleanup_in_progress() ||
                ![d boolForKey:kSettingsLiveWPEnabled] ||
                !g_springboard_rc_ready) return;
            if (settings_livewp_should_play()) return;
            bool ok = livewp_pause_in_session();
            printf("[SETTINGS] LiveWP pause%s%s result=%d\n",
                   reason ? ": " : "", reason ?: "", ok);
        }
    });
}

static void settings_resume_livewp_after_wake_async(const char *reason)
{
    if (!settings_device_supported() || settings_cleanup_in_progress()) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsLiveWPEnabled] || !g_springboard_rc_ready) return;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        bool ok = false;
        @synchronized (settings_rc_lock()) {
            if (settings_cleanup_in_progress() ||
                ![d boolForKey:kSettingsLiveWPEnabled] ||
                !g_springboard_rc_ready) return;
            if (!settings_livewp_should_play()) {
                (void)livewp_pause_in_session();
                return;
            }
            ok = livewp_resume_in_session();
            if (ok) settings_mark_tweak_applied(kSettingsLiveWPEnabled, YES);
        }
        printf("[SETTINGS] LiveWP resume%s%s result=%d\n",
               reason ? ": " : "", reason ?: "", ok);
        if (ok) settings_start_livewp_live_loop();
        settings_notify_package_queue_changed_async();
    });
}

static void settings_start_axonlite_live_loop(void)
{
    if (!settings_device_supported()) return;
    if (settings_cleanup_in_progress()) return;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsAxonLiteEnabled]) return;
    if (!g_springboard_rc_ready) return;

    if (__sync_lock_test_and_set(&g_axonlite_live_running, 1)) {
        static volatile int loggedAlready = 0;
        if (__sync_bool_compare_and_swap(&loggedAlready, 0, 1)) {
            printf("[SETTINGS] Axon Lite live loop already running\n");
        }
        return;
    }

    if (settings_cleanup_in_progress()) {
        __sync_lock_release(&g_axonlite_live_running);
        return;
    }

    g_axonlite_live_stop_requested = 0;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSUInteger tick = 0;
        NSUInteger failures = 0;
        uint64_t nextTickUS = settings_now_us();
        BOOL pausedForUnavailableScreen = NO;

        printf("[SETTINGS] Axon Lite live loop started interval=%uus background=%uus max=%lu\n",
               kAxonLiteLiveIntervalUS,
               kAxonLiteLiveBackgroundIntervalUS,
               (unsigned long)kAxonLiteLiveMaxTicks);
        cyanide_upload_log_milestone(@"axon-lite-live-started");

        @try {
            settings_live_loop_sleep_interruptible(0,
                                                   settings_live_interval(kAxonLiteLiveIntervalUS,
                                                                          kAxonLiteLiveBackgroundIntervalUS),
                                                   &g_axonlite_live_stop_requested);
            nextTickUS = settings_now_us();
            while ([d boolForKey:kSettingsAxonLiteEnabled] &&
                   !settings_cleanup_in_progress() &&
                   !g_axonlite_live_stop_requested &&
                   tick < kAxonLiteLiveMaxTicks) {
                useconds_t intervalUS = settings_live_interval(kAxonLiteLiveIntervalUS,
                                                               kAxonLiteLiveBackgroundIntervalUS);
                // While locked/asleep, CoverSheet churn is exactly where Axon
                // can put sustained pressure on SB. Pause locally without
                // messaging SB so the existing Axon roster/filter state is
                // still there when the screen wakes. The initial cache pass
                // is exempt — interrupting it leaves SB with requests we've
                // already removed but no segmented-control polling to bring
                // them back.
                if (!settings_axonlite_can_poll_springboard() &&
                    axonlite_initial_cache_ready()) {
                    if (!pausedForUnavailableScreen) {
                        pausedForUnavailableScreen = YES;
                        printf("[SETTINGS] Axon Lite paused while %s\n",
                               settings_axonlite_pause_reason());
                    }
                    settings_live_loop_sleep_interruptible(0,
                                                           intervalUS,
                                                           &g_axonlite_live_stop_requested);
                    nextTickUS = settings_now_us();
                    continue;
                }
                if (pausedForUnavailableScreen) {
                    pausedForUnavailableScreen = NO;
                    printf("[SETTINGS] Axon Lite resumed after screen unlock/wake\n");
                }

                uint64_t tickStartUS = settings_now_us();
                bool ok = false;

                @synchronized (settings_rc_lock()) {
                    if (g_axonlite_live_stop_requested) break;
                    if (!g_springboard_rc_ready) {
                        printf("[SETTINGS] Axon Lite loop has no SpringBoard RemoteCall session\n");
                        failures++;
                        break;
                    }
                    if (!settings_axonlite_can_poll_springboard() &&
                        axonlite_initial_cache_ready()) {
                        printf("[SETTINGS] Axon Lite tick skipped inside lock: %s\n",
                               settings_axonlite_pause_reason());
                        nextTickUS = settings_now_us();
                        continue;
                    }
                    ok = axonlite_apply_in_session();
                }

                if (tick == 0) {
                    printf("[SETTINGS] Axon Lite result=%d\n", ok);
                    cyanide_upload_log_milestone(ok ? @"axon-lite-live-first-ok" : @"axon-lite-live-first-failed");
                }
                if (ok) {
                    failures = 0;
                } else {
                    failures++;
                    printf("[SETTINGS] Axon Lite tick failed tick=%lu failures=%lu\n",
                           (unsigned long)tick, (unsigned long)failures);
                    if (failures >= settings_live_failure_limit(3)) break;
                }

                tick++;
                if (![d boolForKey:kSettingsAxonLiteEnabled] ||
                    g_axonlite_live_stop_requested ||
                    tick >= kAxonLiteLiveMaxTicks) break;

                uint64_t nowUS = settings_now_us();
                if (nextTickUS != 0) {
                    intervalUS = settings_live_interval(kAxonLiteLiveIntervalUS,
                                                        kAxonLiteLiveBackgroundIntervalUS);
                    nextTickUS += intervalUS;
                    if (nowUS < nextTickUS) {
                        settings_live_loop_sleep_interruptible(nextTickUS,
                                                               (useconds_t)(nextTickUS - nowUS),
                                                               &g_axonlite_live_stop_requested);
                    } else {
                        nextTickUS = nowUS;
                    }
                } else {
                    settings_live_loop_sleep_interruptible(0,
                                                           settings_live_interval(kAxonLiteLiveIntervalUS,
                                                                                  kAxonLiteLiveBackgroundIntervalUS),
                                                           &g_axonlite_live_stop_requested);
                }

                uint64_t elapsedUS = tickStartUS != 0 && nowUS >= tickStartUS ? nowUS - tickStartUS : 0;
                if (tick == 1) {
                    printf("[SETTINGS] Axon Lite tick=0 elapsed=%lluus\n", elapsedUS);
                }
            }
        } @finally {
            printf("[SETTINGS] Axon Lite live loop exited ticks=%lu enabled=%d failures=%lu stop=%d\n",
                   (unsigned long)tick,
                   [d boolForKey:kSettingsAxonLiteEnabled],
                   (unsigned long)failures,
                   g_axonlite_live_stop_requested);
            if (failures > 0)
                cyanide_upload_log_milestone(@"axon-lite-live-exited-failed");
            __sync_lock_release(&g_axonlite_live_running);
        }
    });
}

static void settings_start_themer_live_loop(void)
{
    if (!settings_device_supported()) return;
    if (settings_cleanup_in_progress()) return;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (!settings_icon_theme_live_repair_enabled(d)) return;
    if (!g_springboard_rc_ready) return;
    if (settings_themer_dynamic_updates_blocked_by_stage(d)) {
        settings_note_themer_stage_conflict(YES);
        return;
    }

    if (__sync_lock_test_and_set(&g_themer_live_running, 1)) {
        static volatile int loggedAlready = 0;
        if (__sync_bool_compare_and_swap(&loggedAlready, 0, 1)) {
            printf("[SETTINGS] Themer dynamic live loop already running\n");
        }
        return;
    }

    if (settings_cleanup_in_progress()) {
        __sync_lock_release(&g_themer_live_running);
        return;
    }

    g_themer_live_stop_requested = 0;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSUInteger tick = 0;
        NSUInteger failures = 0;
        NSInteger iosMajor = [[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
        BOOL legacyPageMode = (iosMajor > 0 && iosMajor < 26);
        NSUInteger maxTicks = legacyPageMode
            ? kThemerLegacyPageMaxTicks
            : kThemerLiveMaxTicks;
        uint64_t lastPageToken = 0;   // legacy page-follow: re-theme on page change
        NSUInteger hotTicks = 0;      // brief burst after a swipe for late-built views

        printf("[SETTINGS] Themer dynamic live loop started interval=%uus background=%uus sblSlow=%uus/%uus max=%lu iosMajor=%ld\n",
               kThemerLiveIntervalUS,
               kThemerLiveBackgroundIntervalUS,
               kThemerSnowBoardLiteSlowIntervalUS,
               kThemerSnowBoardLiteSlowBackgroundIntervalUS,
               (unsigned long)maxTicks,
               (long)iosMajor);

        @try {
            // Start with a sleep so we don't pile a tick on top of the
            // initial Run apply that just completed.
            settings_live_loop_sleep_interruptible(0,
                                                   legacyPageMode ? kThemerLegacyPagePollUS
                                                                  : settings_themer_live_interval_for_tick(d, tick),
                                                   &g_themer_live_stop_requested);
            while (settings_icon_theme_live_repair_enabled(d) &&
                   !settings_themer_dynamic_updates_blocked_by_stage(d) &&
                   !settings_cleanup_in_progress() &&
                   !g_themer_live_stop_requested &&
                   tick < maxTicks) {
                bool ok = false;
                BOOL repairVisibleIcons = settings_themer_live_tick_should_repair_visible(d, tick);

                @synchronized (settings_rc_lock()) {
                    if (g_themer_live_stop_requested) break;
                    if (!g_kexploit_done || g_settings_actions_running) {
                        // Wait for actions to finish before next tick.
                        ok = true;
                    } else {
                        if (!g_springboard_rc_ready) {
                            printf("[SETTINGS] Themer dynamic loop has no SpringBoard RemoteCall session\n");
                            failures++;
                            break;
                        }
                        if (legacyPageMode) {
                            // Cheap page-change poll: only re-theme the visible page
                            // when the current page changed (a swipe), plus a brief
                            // burst after and an occasional fallback. Idle ticks just
                            // read the page token, so a 300ms poll stays light.
                            uint64_t token = sbcustomizer_current_page_token();
                            if (token != lastPageToken) hotTicks = 5;
                            if (token != lastPageToken || tick == 0 || hotTicks > 0 ||
                                (tick % 40) == 0) {
                                ok = themer_repaint_visible_theme_views_in_session();
                            } else {
                                ok = true;
                            }
                            if (hotTicks > 0) hotTicks--;
                            lastPageToken = token;
                        } else if (repairVisibleIcons) {
                            ok = themer_repaint_visible_theme_views_in_session();
                        } else {
                            ok = themer_repaint_dynamic_cached_views_in_session();
                        }
                    }
                }

                if (tick == 0) {
                    printf("[SETTINGS] Themer dynamic live first tick result=%d\n", ok);
                }
                failures = ok ? 0 : failures + 1;

                tick++;
                if (!settings_icon_theme_live_repair_enabled(d) ||
                    settings_themer_dynamic_updates_blocked_by_stage(d) ||
                    g_themer_live_stop_requested ||
                    tick >= maxTicks) break;

                useconds_t intervalUS = legacyPageMode
                    ? kThemerLegacyPagePollUS
                    : settings_themer_live_interval_for_tick(d, tick);
                settings_live_loop_sleep_interruptible(0, intervalUS,
                                                       &g_themer_live_stop_requested);
            }
        } @finally {
            if (settings_themer_dynamic_updates_blocked_by_stage(d)) {
                settings_note_themer_stage_conflict(YES);
            }
            printf("[SETTINGS] Themer dynamic live loop exited ticks=%lu enabled=%d failures=%lu stop=%d\n",
                   (unsigned long)tick,
                   settings_icon_theme_live_repair_enabled(d),
                   (unsigned long)failures,
                   g_themer_live_stop_requested);
            __sync_lock_release(&g_themer_live_running);
        }
    });
}

static void settings_schedule_themer_repair_burst_internal(const char *reason, BOOL force)
{
    (void)force;
    if (!settings_device_supported()) return;
    if (settings_cleanup_in_progress()) return;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (!settings_icon_theme_live_repair_enabled(d)) return;
    if (!g_springboard_rc_ready) return;
    if (settings_themer_dynamic_updates_blocked_by_stage(d)) {
        settings_note_themer_stage_conflict(force);
        return;
    }

    __sync_add_and_fetch(&g_themer_repair_generation, 1);
    if (__sync_lock_test_and_set(&g_themer_repair_running, 1)) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint64_t seenGeneration = g_themer_repair_generation;
        NSUInteger tick = 0;
        NSUInteger quietTicks = 0;

        printf("[SETTINGS] Themer dynamic repair burst started%s%s\n",
               reason ? ": " : "", reason ?: "");

        @try {
            while (settings_icon_theme_live_repair_enabled(d) &&
                   !settings_themer_dynamic_updates_blocked_by_stage(d) &&
                   !settings_cleanup_in_progress() &&
                   !g_themer_live_stop_requested &&
                   tick < 1) {
                settings_live_loop_sleep_interruptible(0,
                                                       tick == 0
                                                           ? kThemerRepairInitialDelayUS
                                                           : kThemerRepairIntervalUS,
                                                       &g_themer_live_stop_requested);
                if (g_themer_live_stop_requested) break;

                bool ok = false;
                @synchronized (settings_rc_lock()) {
                    if (!g_springboard_rc_ready || !g_kexploit_done ||
                        g_settings_actions_running) {
                        ok = true;
                    } else {
                        ok = themer_repaint_visible_theme_views_in_session();
                    }
                }

                tick++;
                uint64_t currentGeneration = g_themer_repair_generation;
                if (currentGeneration != seenGeneration) {
                    seenGeneration = currentGeneration;
                    quietTicks = 0;
                } else {
                    quietTicks++;
                    if (quietTicks >= 2) break;
                }

                if (tick == 1) {
                    printf("[SETTINGS] Themer dynamic repair first repaint=%d\n", ok);
                }
            }
        } @finally {
            printf("[SETTINGS] Themer dynamic repair burst exited ticks=%lu\n",
                   (unsigned long)tick);
            __sync_lock_release(&g_themer_repair_running);
        }
    });
}

static void settings_schedule_themer_repair_burst(const char *reason)
{
    settings_schedule_themer_repair_burst_internal(reason, YES);
}

static void settings_schedule_themer_quiet_repair_burst(const char *reason)
{
    settings_schedule_themer_repair_burst_internal(reason, NO);
}

static void settings_apply_axonlite_once_async(const char *reason)
{
    if (!settings_device_supported()) return;
    if (settings_cleanup_in_progress()) return;
    if (g_axonlite_live_running) {
        if (reason) {
            printf("[SETTINGS] Axon Lite lifecycle apply skipped: live loop owns Axon (%s)\n",
                   reason);
        }
        return;
    }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kSettingsAxonLiteEnabled] || !g_springboard_rc_ready) return;

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        if (settings_cleanup_in_progress()) return;
        bool ok = false;
        if (!settings_axonlite_can_poll_springboard()) {
            printf("[SETTINGS] Axon Lite lifecycle apply%s%s skipped: %s\n",
                   reason ? ": " : "", reason ?: "",
                   settings_axonlite_pause_reason());
            settings_start_axonlite_live_loop();
            return;
        }
        @synchronized (settings_rc_lock()) {
            if (settings_cleanup_in_progress() ||
                ![d boolForKey:kSettingsAxonLiteEnabled] ||
                !g_springboard_rc_ready) return;
            if (!settings_axonlite_can_poll_springboard()) {
                printf("[SETTINGS] Axon Lite lifecycle apply%s%s skipped inside lock: %s\n",
                       reason ? ": " : "", reason ?: "",
                       settings_axonlite_pause_reason());
                settings_start_axonlite_live_loop();
                return;
            }
            ok = axonlite_apply_in_session();
        }
        printf("[SETTINGS] Axon Lite lifecycle apply%s%s result=%d\n",
               reason ? ": " : "", reason ?: "", ok);
        settings_start_axonlite_live_loop();
    });
}

// Swift (ControlReloader.swift): asks Control Center to refresh Cyanide's
// Location Services control after a change.
@interface CYControlReloader : NSObject
+ (void)reloadLocationControl;
@end

// --- Location shortcut: measured switcher-card removal delay ---------------
//
// SpringBoard removes Cyanide's switcher card (ending Cyanide, like a
// swipe-up) on a timer that has to be set while the SpringBoard channel is
// still open. Ending Cyanide is only safe once ALL of its privileged work is
// done: the toggle's SpringBoard teardown, and then the background handler's
// launchd-session teardown, KRW hand-off and RemoteCall drain. That last
// point ("safe") is reported by settings_safe_detach_drain_and_end.
//
// Each run measures arm → safe. The next delay is the longest of the last
// runs plus a margin. Rules that keep it from ever being shorter than needed:
//  - The timestamp is taken BEFORE the scheduling call (the timer may start
//    counting before that call returns).
//  - If the longest recent run plus margin exceeds the cap, the removal is
//    SKIPPED for that run rather than scheduled earlier than needed. The cap
//    equals the activation settle window: if Cyanide is reopened before an
//    old timer fires, no SpringBoard/launchd injection can start before it
//    has fired.
//  - A run whose safe point was never confirmed (marker still set) counts as
//    needing longer. Runs whose drain did not finish cleanly count the same.
//  - Runs keep being measured while removal is skipped, so a skip isn't
//    permanent.
// v3: quiet runs leave for Home as soon as the work is done (no result pause,
// no step replay), so earlier samples don't describe the current timing.
static NSString * const kLocSvcSwitcherSamplesKey = @"LocationShortcutArmToSafeSecondsV3";
static NSString * const kLocSvcSwitcherPendingKey = @"LocationShortcutRemovalPending";
static const double kLocSvcSwitcherMargin = 0.5, kLocSvcSwitcherMin = 1.2;
static const double kLocSvcSwitcherCap = 3.0;   // == kActivationSettleNs
static const double kLocSvcSwitcherDefault = 2.0;
static const NSUInteger kLocSvcSwitcherSampleCount = 10;

// One run at a time; all transitions under this lock.
static NSObject *locsvc_switcher_lock(void)
{
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static uint64_t g_locsvc_run_start_ns = 0;      // 0 = no run being measured
static BOOL g_locsvc_run_armed = NO;            // a removal timer may exist

static void locsvc_switcher_record_locked(double seconds)
{
    if (!isfinite(seconds) || seconds < 0) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableArray<NSNumber *> *samples = [NSMutableArray array];
    for (id n in [d arrayForKey:kLocSvcSwitcherSamplesKey])
        if ([n isKindOfClass:NSNumber.class] && isfinite([n doubleValue]) && [n doubleValue] >= 0) [samples addObject:n];
    [samples addObject:@(seconds)];
    while (samples.count > kLocSvcSwitcherSampleCount) [samples removeObjectAtIndex:0];
    [d setObject:samples forKey:kLocSvcSwitcherSamplesKey];
}

// Delay for this run, or a negative value if removal must be skipped.
// Consumes an unconfirmed marker from an earlier run.
static double locsvc_switcher_delay(void)
{
    @synchronized (locsvc_switcher_lock()) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        double pending = [d doubleForKey:kLocSvcSwitcherPendingKey];
        if (pending > 0) {
            // Crash, forced close, early removal, or a background that
            // never finished: unknown — assume it needed longer.
            log_user("[SWITCHER] the previous run's safe point was not confirmed — assuming it needed longer than %.2fs\n", pending);
            locsvc_switcher_record_locked(pending + kLocSvcSwitcherMargin);
            [d removeObjectForKey:kLocSvcSwitcherPendingKey];
        }
        double longest = -1;
        for (id n in [d arrayForKey:kLocSvcSwitcherSamplesKey])
            if ([n isKindOfClass:NSNumber.class]) longest = MAX(longest, [n doubleValue]);
        if (longest < 0) return kLocSvcSwitcherDefault;
        double needed = longest + kLocSvcSwitcherMargin;
        if (needed > kLocSvcSwitcherCap) return -needed;   // never schedule earlier than needed
        return MAX(kLocSvcSwitcherMin, needed);
    }
}

// Call right BEFORE the scheduling call (armed) — or, when removal is
// skipped, at the same point with armed = NO so the run is still measured.
// The marker is persisted first, then the timestamp is published.
static void locsvc_switcher_begin_run(BOOL armed, double delay)
{
    @synchronized (locsvc_switcher_lock()) {
        if (armed) {
            [NSUserDefaults.standardUserDefaults setDouble:delay forKey:kLocSvcSwitcherPendingKey];
            [NSUserDefaults.standardUserDefaults synchronize];   // must survive the removal ending the app
        }
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        g_locsvc_run_armed = armed;
        g_locsvc_run_start_ns = now;
    }
}

// The scheduling call definitely didn't arm a timer: nothing pending.
static void locsvc_switcher_disarm(void)
{
    @synchronized (locsvc_switcher_lock()) {
        g_locsvc_run_armed = NO;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kLocSvcSwitcherPendingKey];
    }
}

// From settings_safe_detach_drain_and_end: all privileged work is finished
// (clean) or the drain gave up (not clean).
static void locsvc_switcher_note_safe(BOOL clean)
{
    @synchronized (locsvc_switcher_lock()) {
        uint64_t t = g_locsvc_run_start_ns;
        if (!t) return;
        g_locsvc_run_start_ns = 0;
        double safe = (double)(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t) / 1e9;
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        double armedDelay = g_locsvc_run_armed ? [d doubleForKey:kLocSvcSwitcherPendingKey] : 0;
        if (clean) {
            locsvc_switcher_record_locked(safe);
            [d removeObjectForKey:kLocSvcSwitcherPendingKey];   // confirmed
        }
        // Not clean: the marker stays, so the next run treats it as unconfirmed.
        [d synchronize];
        log_user("[SWITCHER] safe %.2fs after scheduling%s%s\n", safe,
                 armedDelay > 0 ? [NSString stringWithFormat:@" (card removal at %.2fs)", armedDelay].UTF8String
                                : " (removal skipped this run)",
                 !clean ? " — drain NOT clean, not counted as safe"
                        : (armedDelay > 0 && safe > armedDelay ? " — TOO LATE, next delay grows" : ""));
    }
}


void settings_application_did_enter_background(void)
{
    // Round 21: refuse NEW own-process exception-port traps from this moment
    // (runningboardd starts policy-managing this task around the transition —
    // the ABBA deadlock window of panics 1+3). In-flight operations finish
    // under the gate mutex; the round-6 teardown below handles the rest.
    excport_gate_set_backgrounded(true);
    if (__sync_lock_test_and_set(&g_app_in_background, 1)) return;

    // Make the live log panic-durable up to this point (cheap; every line is
    // already fflush'd, this adds the media sync). Do it before the early-return
    // guards so a backgrounding always flushes.
    log_live_flush();

    if (settings_cleanup_in_progress()) return;

    // Round 6: tear down the warm fastkill session on EVERY backgrounding —
    // even when a live tweak keeps KRW in-process and the detach below is
    // skipped. A suspended app is SIGKILLed without applicationWillTerminate
    // (panic-full-2026-09-29-195243: swipe-kill of the suspended app → launchd
    // exited ~22 s later), so the trapped launchd thread must be restored
    // while KRW is still live. g_app_in_background was already set above, so a
    // kill's lazy warm-up queued behind pm_kill_lock sees the backgrounded
    // state and the teardown steals whatever it built. No-op when nothing is warm.
    //
    // Round 40: open a safe-detach window (UIBackgroundTask assertion) around
    // the teardown + KRW detach. The teardown still runs SYNCHRONOUSLY here
    // (iOS waits for didEnterBackground to return, and keeping it synchronous
    // avoids the round-32 teardown↔foreground race) — but afterwards we hold
    // the assertion and drain any in-flight RemoteCall helper thread before
    // letting iOS suspend us, so the process can never be frozen with a Cyanide
    // thread mid-trap (the un-reaped-corpse → black-screen bug, live 41).
    UIBackgroundTaskIdentifier safeDetach = settings_safe_detach_begin("backgrounding");

    // Round 6: tear down the warm fastkill session on EVERY backgrounding —
    // a suspended app is SIGKILLed without applicationWillTerminate
    // (panic-full-2026-09-29-195243), so the trapped launchd thread must be
    // restored while KRW is still live. No-op when nothing is warm.
    if (kFastKillTeardownOnBackground)
        pm_teardown_fastkill_session_for_terminate("backgrounding");

    // KRW background survival: hand the socket fds to launchd so the primitive
    // survives device sleep (a suspended app holding live fds loses the socket).
    // Only when no live tweak needs the session in-process.
    if (settings_krw_idle_detach_allowed()) {
        settings_detach_krw_for_background();
    }

    // Hold the window until Cyanide's in-flight RemoteCall ops have drained,
    // then release it (background queue; passive poll — no shared-state touch).
    settings_safe_detach_drain_and_end(safeDetach, "backgrounding");

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL themerLiveNeeded =
        !settings_themer_dynamic_updates_blocked_by_stage(d) &&
        ((settings_themer_live_repair_enabled(d) && g_springboard_rc_ready) ||
         (settings_snowboardlite_live_repair_enabled(d) && g_springboard_rc_ready));
    BOOL anyLiveLoopNeeded =
        ([d boolForKey:kSettingsAxonLiteEnabled]    && g_springboard_rc_ready) ||
        ([d boolForKey:kSettingsStatBarEnabled]     && g_springboard_rc_ready) ||
        ([d boolForKey:kSettingsNSBarEnabled]       && g_springboard_rc_ready) ||
        ([d boolForKey:kSettingsNiceBarLiteEnabled] && g_springboard_rc_ready) ||
        ([d boolForKey:kSettingsGravityLiteEnabled] && g_springboard_rc_ready) ||
        themerLiveNeeded ||
        settings_labels_running() ||   // iOS 17 Hide Labels loop needs the app kept alive
        ([d boolForKey:kSettingsLiveWPEnabled]      && g_springboard_rc_ready);
    if (anyLiveLoopNeeded) {
        if ([d boolForKey:kSettingsKeepAlive]) {
            ds_keepalive_apply_enabled(YES);
        }
        settings_begin_statbar_background_task_async("entered background");
    }

    if ([d boolForKey:kSettingsAxonLiteEnabled] && g_springboard_rc_ready) {
        settings_apply_axonlite_once_async("entered background");
    }
    if ([d boolForKey:kSettingsGravityLiteEnabled] && g_springboard_rc_ready) {
        if (g_gravitylite_background_armed != 0) {
            settings_apply_armed_gravitylite_once_async("entered background");
        }
    }
    (void)settings_refresh_screen_awake_state("entered background");
    (void)settings_refresh_screen_lock_state("entered background");
    settings_sync_fastlockx_lite_for_screen_state_async("entered background");
    if ([d boolForKey:kSettingsNSBarEnabled] && g_springboard_rc_ready) {
        settings_apply_nsbar_once_async("entered background");
    }
    if ([d boolForKey:kSettingsNiceBarLiteEnabled] && g_springboard_rc_ready) {
        settings_apply_nicebarlite_once_async("entered background");
    }
    if ([d boolForKey:kSettingsLiveWPEnabled] && g_springboard_rc_ready) {
        settings_pause_livewp_for_sleep_async("entered background");
    }
    if (![d boolForKey:kSettingsStatBarEnabled] || !g_springboard_rc_ready) {
        return;
    }

    printf("[SETTINGS] app entered background with app-side StatBar loop\n");
    settings_apply_statbar_once_async("entered background");
}

void settings_application_will_enter_foreground(void)
{
    // Round 31: gate ops moved ABOVE the foreground-state early return.
    // settings_app_state_is_foreground() reads UIApplicationState, which is
    // still Background when willEnterForeground fires — so this function used
    // to return BEFORE re-opening the exception-port gate, leaving
    // didBecomeActive as the ONLY re-open path on the scene lifecycle. The
    // gate is a lifecycle fact, not a foreground-work item: open it (and
    // clear the background flag) unconditionally, then gate the rest.
    g_app_in_background = 0;
    // Round 35: open the activation settle window — a fresh SpringBoard hijack
    // defers until it elapses (runningboardd task_policy_set ABBA avoidance).
    g_activation_settle_until_ns = settings_settle_until_after_activation();
    // Round 21: own-process exception-port traps are allowed again (pair of
    // the backgrounded gate set in settings_application_did_enter_background).
    excport_gate_set_backgrounded(false);
    if (!settings_app_state_is_foreground()) return;
    settings_end_statbar_background_task_async("foreground");
    if (settings_cleanup_in_progress()) return;
    settings_apply_statbar_once_async("will enter foreground");
    settings_apply_nsbar_once_async("will enter foreground");
    settings_apply_nicebarlite_once_async("will enter foreground");
    settings_apply_axonlite_once_async("will enter foreground");
    settings_apply_labels_once_async("will enter foreground");
    (void)settings_refresh_screen_awake_state("will enter foreground");
    (void)settings_refresh_screen_lock_state("will enter foreground");
    settings_sync_fastlockx_lite_for_screen_state_async("will enter foreground");
    settings_start_themer_live_loop();
    settings_resume_livewp_after_wake_async("will enter foreground");
}

// Set system-wide Location Services: desired 1 = on, 0 = off, -1 = toggle.
// Sent from SpringBoard (instant over the usual channel); if locationd ignores
// it there, retried from Preferences, which owns the real switch. Success is
// judged by the state this app reads back, not by the call returning.
// The result is posted (activity log turns Complete) as soon as the state is
// confirmed; closing the SpringBoard channel happens after that. `completion`
// runs on the main queue once everything, teardown included, is finished;
// `resultAge` is how long ago the result was posted. With removeFromSwitcher,
// a successful SpringBoard run also has SpringBoard delete Cyanide's App
// Switcher card a little later (after the caller has gone to the Home Screen).
void settings_location_services_set_async(int desired, BOOL allowFullExploit,
                                          BOOL removeFromSwitcher,
                                          NSTimeInterval homeDelay,
                                          SettingsProgressBlock progress,
                                          void (^completion)(BOOL ok, NSString *message,
                                                             NSTimeInterval resultAge))
{
    __block int target = desired;   // final once decided under the action lock
    void (^step)(float, NSString *, NSTimeInterval) = ^(float f, NSString *text, NSTimeInterval over) {
        int t = target;
        if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(f, text, over, t); });
    };
    // Every exit — including the early ones — posts the actions-complete
    // result, so an activity log opened for this request always finishes.
    void (^finishEarly)(NSString *) = ^(NSString *message) {
        log_user("[WARN] %s\n", message.UTF8String);
        settings_post_actions_complete_async(NO, message);
        [CYControlReloader reloadLocationControl];   // the request didn't change it: show the real state
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, message, 0); });
    };
    if (!settings_device_supported()) {
        finishEarly(settings_unsupported_message());
        return;
    }
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        if (!settings_try_claim_actions_lock("Location Services",
                                             "[LOCSVC] Another action is already running.")) {
            finishEarly(@"Another action is already running. Try again when it has finished.");
            return;
        }
        // The target is decided now, under the action lock, from one fresh
        // reading — not when the request was made (the state may have
        // changed since, and a toggle must flip what is actually there).
        BOOL enable = desired < 0 ? (locationservices_enabled_local() != 1) : (desired != 0);
        target = enable ? 1 : 0;
        NSString *verb = enable ? @"Turning on" : @"Turning off";
        __block BOOL ok = NO;
        __block BOOL doneSent = NO;   // the result phase is reported once
        __block NSString *message = nil;
        __block uint64_t resultPostedNs = 0;
        void (^postResult)(void) = ^{
            if (resultPostedNs) return;
            resultPostedNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
            if (message) log_user("%s %s\n", ok ? "[OK]" : "[WARN]", message.UTF8String);
            settings_post_actions_complete_async(ok, message ?: @"");
        };
        NSString *(^doneText)(void) = ^NSString *{
            return [NSString stringWithFormat:@"Location Services %@.", enable ? @"on" : @"off"];
        };
        @try {
            if (locationservices_enabled_local() == (enable ? 1 : 0)) {
                ok = YES;
                message = [NSString stringWithFormat:@"Location Services already %@.", enable ? @"on" : @"off"];
                step(1.0f, enable ? @"Already on" : @"Already off", 0);
                doneSent = YES;
                return;
            }
            log_user("[LOCSVC] Turning Location Services %s…\n", enable ? "on" : "off");
            // Only now that work is needed: no live or parked kernel access
            // (e.g. after a restart) means the full exploit chain runs first
            // (~10 s on A18) — say so.
            // A parked state can still turn out unusable: the chain says so
            // when it falls back to a full run.
            // Live or parked kernel access only, unless the caller has the
            // user's go-ahead for a full run (it can reboot A18/M4 devices):
            // without it, report kSettingsFullExploitRequiredMessage and let
            // the caller ask (in-app) or tell the user to open Cyanide.
            step(0.1f, @"Getting kernel ready", 0);
            BOOL kernelReady = settings_ensure_kexploit_for_read();
            if (!kernelReady && !allowFullExploit) {
                message = kSettingsFullExploitRequiredMessage;
                return;
            }
            if (!kernelReady) {
                step(0.45f, @"Running the full exploit", 12.0);
                kernelReady = settings_ensure_kexploit();
            }
            if (!kernelReady) {
                message = @"Failed: kernel primitives were not acquired. Run the chain, then try again.";
                return;
            }
            // The longest step is the activation settle window before the
            // SpringBoard channel can open (plus ~0.5 s to open it): let the
            // bar fill over exactly that time instead of standing still.
            {
                uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
                uint64_t until = g_activation_settle_until_ns;
                double settle = until > now ? (double)(until - now) / 1e9 : 0;
                // The settle window shows as "Getting kernel ready". The
                // "Connecting" phase is reported when the SpringBoard
                // connection actually starts (g_springboard_connect_progress).
                if (settle > 0.3) step(0.7f, @"Getting kernel ready", settle);
            }
            g_springboard_connect_progress = ^{ step(0.82f, @"Connecting", 0.5); };
            @synchronized (settings_rc_lock()) {
                if (settings_ensure_springboard_remote_call_locked()) {
                    step(0.85f, verb, 0.3);
                    LSCallResult sent = locationservices_set_enabled_in_session(enable);
                    // Not sent: nothing can change, don't wait for it.
                    // Sent/uncertain: the readback decides.
                    ok = sent != LSCallNotSent && locationservices_wait_for_state(enable, 3000);
                    uint64_t removalScheduledNs = 0;
                    double removalDelay = 0;
                    if (ok) {
                        // Report now; the teardown below runs while the
                        // result is already on screen.
                        message = doneText();
                        step(1.0f, @"Done", 0.2);
                        doneSent = YES;
                        postResult();
                        // Switcher card: SpringBoard deletes it removalDelay
                        // from now (measured; see locsvc_switcher_delay).
                        // Never while a live tweak keeps this channel open
                        // across the background: ending Cyanide would
                        // orphan it.
                        if (removeFromSwitcher && !settings_has_persistent_springboard_remote_call_user()) {
                            removalDelay = locsvc_switcher_delay();
                            // The caller stays in front up to homeDelay longer
                            // (log=1 result pause): the card goes that much later.
                            if (removalDelay > 0) removalDelay += MAX(0.0, homeDelay);
                            if (removalDelay > 0) {
                                locsvc_switcher_begin_run(YES, removalDelay - MAX(0.0, homeDelay));   // before the call: the timer may start first
                                removalScheduledNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
                                ASRemovalResult rr = appswitcher_schedule_remove_in_session(
                                    NSBundle.mainBundle.bundleIdentifier.UTF8String, removalDelay);
                                if (rr == ASRemovalNotScheduled) {
                                    locsvc_switcher_disarm();
                                    removalScheduledNs = 0;
                                } else {
                                    // Estimated latest firing: the timer was armed before
                                    // the call returned, so return + delay is late enough
                                    // for a normally running SpringBoard; the margin
                                    // covers a busy main thread (not a guarantee). No new
                                    // kernel work or injection starts before it.
                                    uint64_t bound = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
                                                   + (uint64_t)((removalDelay + 1.0) * 1e9);
                                    g_removal_fire_bound_ns = bound;
                                    g_activation_settle_until_ns = MAX(g_activation_settle_until_ns, bound);
                                }
                            } else {
                                log_user("[SWITCHER] card kept this run: recent runs needed %.2fs, over the %.0fs limit\n",
                                         -removalDelay, kLocSvcSwitcherCap);
                                locsvc_switcher_begin_run(NO, 0);   // still measure, so this can recover
                            }
                        }
                    }
                    if (!settings_has_persistent_springboard_remote_call_user() && g_springboard_rc_ready) {
                        settings_destroy_springboard_remote_call_locked_internal_ex("location services toggle",
                                                                                   YES, YES);
                    }
                    if (removalScheduledNs) {
                        double elapsed = (double)(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - removalScheduledNs) / 1e9;
                        if (elapsed > removalDelay - 0.25)
                            log_user("[SWITCHER] WARNING: scheduling + SpringBoard teardown took %.2fs — close to the "
                                     "%.2fs card removal.\n", elapsed, removalDelay);
                    }
                } else {
                    log_user("[LOCSVC] SpringBoard not reachable.\n");
                }
            }
            if (!ok) {
                // The request may have taken effect during the teardown.
                if (locationservices_enabled_local() == (enable ? 1 : 0)) {
                    ok = YES;
                    message = doneText();
                    if (!doneSent) { step(1.0f, @"Done", 0.2); doneSent = YES; }
                    return;
                }
                if (settings_any_registered_live_loop_running() || settings_has_persistent_springboard_remote_call_user()) {
                    message = @"SpringBoard didn't change it, and the Preferences fallback would need the "
                              @"SpringBoard channel closed while live tweaks use it. Stop them and try again.";
                    return;
                }
                // Fallback: Preferences, only if it's already running (see
                // locationservices_set_enabled_via_running_preferences).
                log_user("[LOCSVC] No change from SpringBoard; trying a running Preferences…\n");
                step(0.9f, @"Trying another way", 0.3);
                LSCallResult sent;
                @synchronized (settings_rc_lock()) {
                    settings_destroy_springboard_remote_call_locked_internal("switching to Preferences", NO);
                    sent = locationservices_set_enabled_via_running_preferences(enable);
                }
                ok = sent != LSCallNotSent && locationservices_wait_for_state(enable, 3000);
                if (!ok && sent == LSCallNotSent) {
                    message = @"Location Services did not change. Opening the Settings app once and trying "
                              @"again lets Cyanide use it as a fallback.";
                    return;
                }
            }
            if (ok && !doneSent) { step(1.0f, @"Done", 0.2); doneSent = YES; }
            message = ok ? doneText() : @"Location Services did not change. Check the log.";
        } @finally {
            g_springboard_connect_progress = nil;
            kexploit_set_full_run_notice(nil);
            settings_release_actions_lock();
            postResult();   // no-op if already reported
            [CYControlReloader reloadLocationControl];   // show the real state in Control Center
            NSString *finalMessage = message ?: @"";
            NSTimeInterval resultAge =
                (double)(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - resultPostedNs) / 1e9;
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(ok, finalMessage, resultAge);
            });
        }
    });
}

// File Browser access. The sandbox extension for "/" that SpringBoard issues
// (escape_sbx_demo2_in_session) is consumed into THIS process and lasts until
// it exits, independent of the SpringBoard channel. A path the app sandbox
// always denies is the cheapest proof that it is in effect.
BOOL settings_filesystem_access_available(void)
{
    DIR *dir = opendir("/private/var/mobile/Library");
    if (!dir) return NO;
    closedir(dir);
    return YES;
}

NSString * const kSettingsLocationServicesLinksEnabled = @"LocationServicesLinksEnabled";
NSString * const kSettingsFullExploitRequiredMessage =
    @"No saved kernel access — this needs a full exploit run first.";

// Lifts the sandbox for the File Browser if it isn't already. `completion`
// runs on the main queue. See the header for allowFullExploit.
void settings_unlock_filesystem_async(BOOL allowFullExploit,
                                      void (^completion)(BOOL ok, NSString *message))
{
    void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *message) {
        if (message) log_user("%s %s\n", ok ? "[OK]" : "[WARN]", message.UTF8String);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, message); });
    };
    if (settings_filesystem_access_available()) { finish(YES, nil); return; }
    if (!settings_device_supported()) { finish(NO, settings_unsupported_message()); return; }
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        if (!settings_try_claim_actions_lock("File Browser",
                                             "[FILES] Another action is already running.")) {
            finish(NO, @"Another action is already running. Try again when it has finished.");
            return;
        }
        BOOL ok = NO;
        NSString *message = nil;
        @try {
            log_user("[FILES] Lifting the filesystem sandbox…\n");
            // Live or parked kernel access only, unless the user confirmed a
            // full run: opening a browser must not reboot an A18 device unasked.
            BOOL kernelReady = settings_ensure_kexploit_for_read();
            if (!kernelReady && !allowFullExploit) {
                message = kSettingsFullExploitRequiredMessage;
                return;
            }
            if (!kernelReady) kernelReady = settings_ensure_kexploit();
            if (!kernelReady) {
                message = @"Kernel access could not be acquired. Run the chain, then try again.";
                return;
            }
            @synchronized (settings_rc_lock()) {
                if (!settings_ensure_springboard_remote_call_locked()) {
                    message = @"SpringBoard could not be reached.";
                    return;
                }
                int sbx = escape_sbx_demo2_in_session();
                g_springboard_sandbox_escaped = (sbx == 0);
                if (!settings_has_persistent_springboard_remote_call_user() && g_springboard_rc_ready) {
                    settings_destroy_springboard_remote_call_locked_internal_ex("file browser unlock",
                                                                               YES, YES);
                }
            }
            ok = settings_filesystem_access_available();
            message = ok ? @"Filesystem sandbox lifted — File Browser ready."
                         : @"The sandbox could not be lifted. Check the log.";
        } @finally {
            settings_release_actions_lock();
            finish(ok, message);
        }
    });
}

void settings_application_did_become_active(void)
{
    // Round 31: same reorder as will_enter_foreground — the gate re-open must
    // not depend on the UIApplicationState early return.
    g_app_in_background = 0;
    // Round 35: refresh the activation settle window (covers launch, where
    // didBecomeActive fires without a prior willEnterForeground).
    g_activation_settle_until_ns = settings_settle_until_after_activation();
    // Round 21: belt-and-braces pair of the backgrounded gate — covers the
    // become-active-without-will-enter-foreground edge (e.g. control-center
    // overlay dismiss after an inactive spell).
    excport_gate_set_backgrounded(false);
    if (!settings_app_state_is_foreground()) return;
    if (settings_cleanup_in_progress()) return;
    settings_apply_statbar_once_async("became active");
    settings_apply_nsbar_once_async("became active");
    settings_apply_nicebarlite_once_async("became active");
    settings_apply_axonlite_once_async("became active");
    settings_apply_labels_once_async("became active");
    (void)settings_refresh_screen_awake_state("became active");
    (void)settings_refresh_screen_lock_state("became active");
    settings_sync_fastlockx_lite_for_screen_state_async("became active");
    settings_start_themer_live_loop();
    settings_resume_livewp_after_wake_async("became active");
}

static BOOL settings_key_is_sbc(NSString *key)
{
    return [key isEqualToString:kSettingsSBCEnabled] ||
           [key isEqualToString:kSettingsSBCDockIcons] ||
           [key isEqualToString:kSettingsSBCCols] ||
           [key isEqualToString:kSettingsSBCRows] ||
           [key isEqualToString:kSettingsSBCHideLabels] ||
           [key isEqualToString:kSettingsSBCDockLabels] ||
           [key isEqualToString:kSettingsSBCArrangePages] ||
           [key isEqualToString:kSettingsSBCFirstPageIcons] ||
           [key isEqualToString:kSettingsSBCOtherPageIcons] ||
           [key isEqualToString:kSettingsSBCAutoDockApp] ||
           [key isEqualToString:kSettingsSBCDockAppBundleID];
}

static BOOL settings_key_is_sbc_configuration(NSString *key)
{
    return [key isEqualToString:kSettingsSBCDockIcons] ||
           [key isEqualToString:kSettingsSBCCols] ||
           [key isEqualToString:kSettingsSBCRows] ||
           [key isEqualToString:kSettingsSBCHideLabels] ||
           [key isEqualToString:kSettingsSBCDockLabels] ||
           [key isEqualToString:kSettingsSBCArrangePages] ||
           [key isEqualToString:kSettingsSBCFirstPageIcons] ||
           [key isEqualToString:kSettingsSBCOtherPageIcons] ||
           [key isEqualToString:kSettingsSBCAutoDockApp] ||
           [key isEqualToString:kSettingsSBCDockAppBundleID];
}

static void settings_note_package_configuration_changed(NSString *key)
{
    if (settings_key_is_sbc_configuration(key)) {
        // A configuration edit is new desired state, so invalidate the
        // process-local marker and let the Installer show an apply action.
        settings_mark_tweak_applied(kSettingsSBCEnabled, NO);
        printf("[SETTINGS] SBC config changed via %s; marked layout apply pending\n",
               key.UTF8String);
        log_user("[SBCUSTOMIZER] Settings changed — layout apply is pending.\n");
        settings_notify_package_queue_changed_async();
    }
}

static BOOL settings_key_is_quickloader(NSString *key)
{
    return [key isEqualToString:kSettingsQuickLoaderEnabled] ||
           [key isEqualToString:kSettingsRepoTweaksEnabled];
}

static BOOL settings_key_is_statbar(NSString *key)
{
    return [key isEqualToString:kSettingsStatBarEnabled] ||
           [key isEqualToString:kSettingsStatBarCelsius] ||
           [key isEqualToString:kSettingsStatBarShowNet] ||
           [key isEqualToString:kSettingsStatBarShowCPU] ||
           [key isEqualToString:kSettingsStatBarShowLabels] ||
           [key isEqualToString:kSettingsStatBarNetworkOnly] ||
           [key isEqualToString:kSettingsStatBarRefreshRateSec];
}

static BOOL settings_key_is_nsbar(NSString *key)
{
    return [key isEqualToString:kSettingsNSBarEnabled] ||
           [key isEqualToString:kSettingsNSBarPosition];
}

static BOOL settings_key_is_nicebarlite(NSString *key)
{
    if ([key isEqualToString:kSettingsNiceBarLiteEnabled] ||
        [key isEqualToString:kSettingsNiceBarLiteCelsius] ||
        [key isEqualToString:kSettingsNiceBarLiteLayoutTopSideInset] ||
        [key isEqualToString:kSettingsNiceBarLiteLayoutBottomSideInset] ||
        [key isEqualToString:kSettingsNiceBarLiteLayoutTopY] ||
        [key isEqualToString:kSettingsNiceBarLiteLayoutBottomY] ||
        [key isEqualToString:kSettingsNiceBarLiteLayoutCenterX]) {
        return YES;
    }
    for (NSInteger i = 0; i < NiceBarLiteSlotCount; i++) {
        if ([key isEqualToString:settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, i)] ||
            [key isEqualToString:settings_nicebar_key(kSettingsNiceBarLiteSlotSystemPrefix, i)] ||
            [key isEqualToString:settings_nicebar_key(kSettingsNiceBarLiteSlotTextPrefix, i)] ||
            [key isEqualToString:settings_nicebar_key(kSettingsNiceBarLiteSlotTimePrefix, i)] ||
            [key isEqualToString:settings_nicebar_key(kSettingsNiceBarLiteSlotWeatherPrefix, i)] ||
            [key isEqualToString:settings_nicebar_key(kSettingsNiceBarLiteSlotWeatherLanguagePrefix, i)] ||
            [key isEqualToString:settings_nicebar_key(kSettingsNiceBarLiteSlotSystemLanguagePrefix, i)]) {
            return YES;
        }
    }
    return NO;
}

static BOOL settings_key_is_axonlite(NSString *key)
{
    return [key isEqualToString:kSettingsAxonLiteEnabled];
}

static BOOL settings_key_is_appswitchergrid(NSString *key)
{
    return [key isEqualToString:kSettingsAppSwitcherGridEnabled];
}

static BOOL settings_key_is_gravitylite(NSString *key)
{
    return [key isEqualToString:kSettingsGravityLiteEnabled] ||
           [key isEqualToString:kSettingsGravityLiteDockEnabled] ||
           [key isEqualToString:kSettingsGravityLiteMagnitudePct] ||
           [key isEqualToString:kSettingsGravityLiteBouncePct] ||
           [key isEqualToString:kSettingsGravityLiteFrictionPct] ||
           [key isEqualToString:kSettingsGravityLiteResistancePct] ||
           [key isEqualToString:kSettingsGravityLiteAngularResistancePct];
}

static BOOL settings_key_is_location_sim(NSString *key)
{
    return [key isEqualToString:kSettingsLocationSimEnabled] ||
           [key isEqualToString:kSettingsLocationSimLatitude] ||
           [key isEqualToString:kSettingsLocationSimLongitude] ||
           [key isEqualToString:kSettingsLocationSimAltitude] ||
           [key isEqualToString:kSettingsLocationSimHorizontalAccuracy] ||
           [key isEqualToString:kSettingsLocationSimHostProcess];
}

static NSString *settings_location_sim_host_process(NSUserDefaults *d)
{
    NSString *host = [d stringForKey:kSettingsLocationSimHostProcess];
    return host.length > 0 ? host : @"Maps";
}

static NSString *settings_location_sim_normalized_coordinate_text(NSString *text)
{
    if (![text isKindOfClass:NSString.class] || text.length == 0) return @"";

    NSMutableString *normalized = [text mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)normalized,
                      NULL,
                      kCFStringTransformFullwidthHalfwidth,
                      false);
    NSDictionary<NSString *, NSString *> *replacements = @{
        @"−": @"-",
        @"－": @"-",
        @"﹣": @"-",
        @"–": @"-",
        @"—": @"-",
        @"。": @".",
        @"．": @".",
        @"，": @",",
        @"、": @",",
        @"；": @";",
        @"：": @":",
        @"（": @"(",
        @"）": @")",
        @"緯": @"纬",
        @"經": @"经",
        @"東": @"东",
    };
    [replacements enumerateKeysAndObjectsUsingBlock:^(NSString *from, NSString *to, BOOL *stop) {
        (void)stop;
        [normalized replaceOccurrencesOfString:from
                                    withString:to
                                       options:0
                                         range:NSMakeRange(0, normalized.length)];
    }];
    return normalized;
}

static NSArray<NSDictionary *> *settings_location_sim_number_tokens_from_text(NSString *text)
{
    NSMutableArray<NSDictionary *> *tokens = [NSMutableArray array];
    NSScanner *scanner = [NSScanner scannerWithString:text ?: @""];
    scanner.charactersToBeSkipped = nil;
    while (!scanner.isAtEnd) {
        double value = 0.0;
        NSUInteger start = scanner.scanLocation;
        if ([scanner scanDouble:&value]) {
            if (isfinite(value)) {
                NSRange range = NSMakeRange(start, scanner.scanLocation - start);
                [tokens addObject:@{ @"value": @(value),
                                     @"range": [NSValue valueWithRange:range] }];
            }
            continue;
        }
        scanner.scanLocation = scanner.scanLocation + 1;
    }
    return tokens;
}

static NSInteger settings_location_sim_axis_sign_for_word(NSString *word, BOOL latitude)
{
    NSString *upper = [(word ?: @"") uppercaseString];
    if (latitude) {
        if ([upper isEqualToString:@"N"] ||
            [upper isEqualToString:@"NORTH"] ||
            [upper containsString:@"北"]) return 1;
        if ([upper isEqualToString:@"S"] ||
            [upper isEqualToString:@"SOUTH"] ||
            [upper containsString:@"南"]) return -1;
    } else {
        if ([upper isEqualToString:@"E"] ||
            [upper isEqualToString:@"EAST"] ||
            [upper containsString:@"东"]) return 1;
        if ([upper isEqualToString:@"W"] ||
            [upper isEqualToString:@"WEST"] ||
            [upper containsString:@"西"]) return -1;
    }
    return 0;
}

static NSInteger settings_location_sim_axis_kind_for_word(NSString *word)
{
    NSString *upper = [(word ?: @"") uppercaseString];
    if ([upper isEqualToString:@"LAT"] ||
        [upper isEqualToString:@"LATITUDE"] ||
        [upper containsString:@"纬"]) {
        return 1;
    }
    if ([upper isEqualToString:@"LON"] ||
        [upper isEqualToString:@"LNG"] ||
        [upper isEqualToString:@"LONG"] ||
        [upper isEqualToString:@"LONGITUDE"] ||
        [upper containsString:@"经"]) {
        return 2;
    }
    return 0;
}

static BOOL settings_location_sim_is_axis_separator(unichar c)
{
    if ([NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c]) return YES;
    if ([NSCharacterSet.punctuationCharacterSet characterIsMember:c]) return YES;
    if ([NSCharacterSet.symbolCharacterSet characterIsMember:c]) return YES;
    return NO;
}

static NSString *settings_location_sim_axis_word_after_range(NSString *text, NSRange range)
{
    NSUInteger i = NSMaxRange(range);
    while (i < text.length &&
           settings_location_sim_is_axis_separator([text characterAtIndex:i])) {
        i++;
    }
    NSUInteger start = i;
    while (i < text.length &&
           [NSCharacterSet.letterCharacterSet characterIsMember:[text characterAtIndex:i]]) {
        i++;
    }
    return i > start ? [text substringWithRange:NSMakeRange(start, i - start)] : @"";
}

static NSString *settings_location_sim_axis_word_before_range(NSString *text, NSRange range)
{
    if (range.location == 0) return @"";
    NSInteger i = (NSInteger)range.location - 1;
    while (i >= 0 &&
           settings_location_sim_is_axis_separator([text characterAtIndex:(NSUInteger)i])) {
        i--;
    }
    NSInteger end = i + 1;
    while (i >= 0 &&
           [NSCharacterSet.letterCharacterSet characterIsMember:[text characterAtIndex:(NSUInteger)i]]) {
        i--;
    }
    NSInteger start = i + 1;
    return end > start ? [text substringWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end - start))] : @"";
}

static NSInteger settings_location_sim_axis_sign_near_range(NSString *text,
                                                            NSRange range,
                                                            BOOL latitude)
{
    NSInteger sign = settings_location_sim_axis_sign_for_word(settings_location_sim_axis_word_after_range(text ?: @"", range),
                                                              latitude);
    if (sign != 0) return sign;
    return settings_location_sim_axis_sign_for_word(settings_location_sim_axis_word_before_range(text ?: @"", range),
                                                   latitude);
}

static NSInteger settings_location_sim_axis_kind_near_range(NSString *text, NSRange range)
{
    NSInteger kind = settings_location_sim_axis_kind_for_word(settings_location_sim_axis_word_before_range(text ?: @"", range));
    if (kind != 0) return kind;
    return settings_location_sim_axis_kind_for_word(settings_location_sim_axis_word_after_range(text ?: @"", range));
}

static NSInteger settings_location_sim_axis_sign_from_text(NSString *text, BOOL latitude)
{
    NSString *upper = [(text ?: @"") uppercaseString];
    NSInteger sign = 0;
    for (NSUInteger i = 0; i < upper.length; i++) {
        unichar c = [upper characterAtIndex:i];
        NSInteger candidate = settings_location_sim_axis_sign_for_word([NSString stringWithCharacters:&c length:1],
                                                                       latitude);
        if (candidate == 0) continue;

        BOOL prevIsLetter = (i > 0) && [NSCharacterSet.letterCharacterSet characterIsMember:[upper characterAtIndex:i - 1]];
        BOOL nextIsLetter = (i + 1 < upper.length) && [NSCharacterSet.letterCharacterSet characterIsMember:[upper characterAtIndex:i + 1]];
        if (!prevIsLetter && !nextIsLetter) sign = candidate;
    }
    return sign;
}

static double settings_location_sim_apply_axis_sign(double value, NSInteger sign)
{
    return sign != 0 ? fabs(value) * (double)sign : value;
}

static BOOL settings_location_sim_coordinates_valid(double latitude, double longitude)
{
    return isfinite(latitude) && isfinite(longitude) &&
           latitude >= -90.0 && latitude <= 90.0 &&
           longitude >= -180.0 && longitude <= 180.0;
}

static BOOL settings_location_sim_component_valid(double value, BOOL latitude)
{
    if (!isfinite(value)) return NO;
    return latitude
        ? (value >= -90.0 && value <= 90.0)
        : (value >= -180.0 && value <= 180.0);
}

static BOOL settings_location_sim_parse_coordinate_component(NSString *text,
                                                             BOOL latitude,
                                                             double *outValue)
{
    if (!outValue) return NO;
    NSString *normalizedText = settings_location_sim_normalized_coordinate_text(text);
    NSArray<NSDictionary *> *tokens = settings_location_sim_number_tokens_from_text(normalizedText);
    if (tokens.count != 1) return NO;

    NSDictionary *token = tokens.firstObject;
    double value = [token[@"value"] doubleValue];
    NSRange range = [token[@"range"] rangeValue];
    NSInteger sign = settings_location_sim_axis_sign_near_range(normalizedText, range, latitude);
    if (sign == 0) sign = settings_location_sim_axis_sign_from_text(normalizedText, latitude);
    value = settings_location_sim_apply_axis_sign(value, sign);
    if (!settings_location_sim_component_valid(value, latitude)) return NO;

    *outValue = value;
    return YES;
}

static BOOL settings_location_sim_parse_coordinate_pair(NSString *text,
                                                        double *latitudeOut,
                                                        double *longitudeOut)
{
    if (!latitudeOut || !longitudeOut) return NO;
    NSString *normalizedText = settings_location_sim_normalized_coordinate_text(text);
    NSArray<NSDictionary *> *tokens = settings_location_sim_number_tokens_from_text(normalizedText);
    if (tokens.count != 2) return NO;

    NSDictionary *firstToken = tokens[0];
    NSDictionary *secondToken = tokens[1];
    double first = [firstToken[@"value"] doubleValue];
    double second = [secondToken[@"value"] doubleValue];
    NSRange firstRange = [firstToken[@"range"] rangeValue];
    NSRange secondRange = [secondToken[@"range"] rangeValue];
    NSInteger firstLatSign = settings_location_sim_axis_sign_near_range(normalizedText, firstRange, YES);
    NSInteger firstLonSign = settings_location_sim_axis_sign_near_range(normalizedText, firstRange, NO);
    NSInteger secondLatSign = settings_location_sim_axis_sign_near_range(normalizedText, secondRange, YES);
    NSInteger secondLonSign = settings_location_sim_axis_sign_near_range(normalizedText, secondRange, NO);
    NSInteger firstKind = settings_location_sim_axis_kind_near_range(normalizedText, firstRange);
    NSInteger secondKind = settings_location_sim_axis_kind_near_range(normalizedText, secondRange);

    if (firstKind == 1 && secondKind == 2) {
        double latitude = settings_location_sim_apply_axis_sign(first, firstLatSign);
        double longitude = settings_location_sim_apply_axis_sign(second, secondLonSign);
        if (!settings_location_sim_coordinates_valid(latitude, longitude)) return NO;
        *latitudeOut = latitude;
        *longitudeOut = longitude;
        return YES;
    }

    if (firstKind == 2 && secondKind == 1) {
        double latitude = settings_location_sim_apply_axis_sign(second, secondLatSign);
        double longitude = settings_location_sim_apply_axis_sign(first, firstLonSign);
        if (!settings_location_sim_coordinates_valid(latitude, longitude)) return NO;
        *latitudeOut = latitude;
        *longitudeOut = longitude;
        return YES;
    }

    if (firstLatSign != 0 && secondLonSign != 0) {
        double latitude = settings_location_sim_apply_axis_sign(first, firstLatSign);
        double longitude = settings_location_sim_apply_axis_sign(second, secondLonSign);
        if (!settings_location_sim_coordinates_valid(latitude, longitude)) return NO;
        *latitudeOut = latitude;
        *longitudeOut = longitude;
        return YES;
    }

    if (firstLonSign != 0 && secondLatSign != 0) {
        double latitude = settings_location_sim_apply_axis_sign(second, secondLatSign);
        double longitude = settings_location_sim_apply_axis_sign(first, firstLonSign);
        if (!settings_location_sim_coordinates_valid(latitude, longitude)) return NO;
        *latitudeOut = latitude;
        *longitudeOut = longitude;
        return YES;
    }

    NSInteger latitudeSign = settings_location_sim_axis_sign_from_text(normalizedText, YES);
    NSInteger longitudeSign = settings_location_sim_axis_sign_from_text(normalizedText, NO);

    double latitude = first;
    double longitude = second;
    latitude = settings_location_sim_apply_axis_sign(latitude, latitudeSign);
    longitude = settings_location_sim_apply_axis_sign(longitude, longitudeSign);
    if (!settings_location_sim_coordinates_valid(latitude, longitude)) {
        latitude = second;
        longitude = first;
        latitude = settings_location_sim_apply_axis_sign(latitude, latitudeSign);
        longitude = settings_location_sim_apply_axis_sign(longitude, longitudeSign);
        if (!settings_location_sim_coordinates_valid(latitude, longitude)) return NO;
    }

    *latitudeOut = latitude;
    *longitudeOut = longitude;
    return YES;
}

static BOOL settings_location_sim_parse_coordinate_fields(NSString *latitudeText,
                                                          NSString *longitudeText,
                                                          double *latitudeOut,
                                                          double *longitudeOut)
{
    if (!latitudeOut || !longitudeOut) return NO;
    if (settings_location_sim_parse_coordinate_pair(latitudeText, latitudeOut, longitudeOut)) return YES;
    if (settings_location_sim_parse_coordinate_pair(longitudeText, latitudeOut, longitudeOut)) return YES;

    double latitude = 0.0;
    double longitude = 0.0;
    BOOL ok = settings_location_sim_parse_coordinate_component(latitudeText, YES, &latitude) &&
              settings_location_sim_parse_coordinate_component(longitudeText, NO, &longitude) &&
              settings_location_sim_coordinates_valid(latitude, longitude);
    if (!ok) return NO;

    *latitudeOut = latitude;
    *longitudeOut = longitude;
    return YES;
}

static BOOL settings_location_sim_is_active(NSUserDefaults *d)
{
    return [d boolForKey:kSettingsLocationSimStarted];
}

static void settings_location_sim_set_target(NSUserDefaults *d,
                                             double latitude,
                                             double longitude)
{
    [d setDouble:latitude forKey:kSettingsLocationSimLatitude];
    [d setDouble:longitude forKey:kSettingsLocationSimLongitude];
    [d setObject:@"Maps" forKey:kSettingsLocationSimHostProcess];
    [d synchronize];
}

static void settings_location_sim_set_rockaway_defaults(NSUserDefaults *d)
{
    settings_location_sim_set_target(d, kLocationSimDefaultLatitude, kLocationSimDefaultLongitude);
    [d setInteger:kLocationSimDefaultAltitude forKey:kSettingsLocationSimAltitude];
    [d setInteger:kLocationSimDefaultAccuracy forKey:kSettingsLocationSimHorizontalAccuracy];
    [d synchronize];
}

static NSString *settings_location_sim_target_summary(NSUserDefaults *d)
{
    double lat = [d doubleForKey:kSettingsLocationSimLatitude];
    double lon = [d doubleForKey:kSettingsLocationSimLongitude];
    NSInteger altitude = [d integerForKey:kSettingsLocationSimAltitude];
    NSInteger accuracy = [d integerForKey:kSettingsLocationSimHorizontalAccuracy];
    if (accuracy <= 0) accuracy = kLocationSimDefaultAccuracy;
    return [NSString stringWithFormat:@"%.7f, %.7f via %@ (%ldm alt, %ldm acc)",
            lat,
            lon,
            settings_location_sim_host_process(d),
            (long)altitude,
            (long)accuracy];
}

static NSString *settings_location_sim_mode_summary(NSUserDefaults *d)
{
    BOOL simulationStarted = [d boolForKey:kSettingsLocationSimStarted];
    NSString *simulation = simulationStarted
        ? @"Mode: Target simulation started"
        : @"Mode: Real location requested";
    NSString *note = simulationStarted ? @"\nUse Restore Real Location to stop it." : @"";
    return [NSString stringWithFormat:@"%@%@\nTarget: %@", simulation, note,
            settings_location_sim_target_summary(d)];
}

static BOOL settings_apply_location_sim_from_defaults_locked(NSUserDefaults *d)
{
    NSInteger accuracy = [d integerForKey:kSettingsLocationSimHorizontalAccuracy];
    if (accuracy <= 0) accuracy = kLocationSimDefaultAccuracy;

    NSString *host = settings_location_sim_host_process(d);
    LocationSimConfig config = {
        .latitude = [d doubleForKey:kSettingsLocationSimLatitude],
        .longitude = [d doubleForKey:kSettingsLocationSimLongitude],
        .altitude = (double)[d integerForKey:kSettingsLocationSimAltitude],
        .horizontalAccuracy = (double)accuracy,
        .verticalAccuracy = (double)accuracy,
        .hostProcess = host.UTF8String,
        .launchHost = true,
    };
    return locationsim_apply_static(&config);
}

static BOOL settings_stop_location_sim_from_defaults_locked(NSUserDefaults *d)
{
    NSString *host = settings_location_sim_host_process(d);
    return locationsim_stop(host.UTF8String, true);
}

static BOOL settings_prime_location_sim_uber_stealth_locked(NSUserDefaults *d,
                                                            BOOL enable,
                                                            BOOL *systemApplyOKOut)
{
    NSInteger accuracy = [d integerForKey:kSettingsLocationSimHorizontalAccuracy];
    if (accuracy <= 0) accuracy = kLocationSimDefaultAccuracy;

    NSString *host = settings_location_sim_host_process(d);
    LocationSimConfig config = {
        .latitude = [d doubleForKey:kSettingsLocationSimLatitude],
        .longitude = [d doubleForKey:kSettingsLocationSimLongitude],
        .altitude = (double)[d integerForKey:kSettingsLocationSimAltitude],
        .horizontalAccuracy = (double)accuracy,
        .verticalAccuracy = (double)accuracy,
        .hostProcess = host.UTF8String,
        .launchHost = true,
    };

    BOOL systemOK = enable
        ? locationsim_apply_strict_hosts(&config)
        : locationsim_stop_strict_hosts(host.UTF8String, true);
    if (systemApplyOKOut) *systemApplyOKOut = systemOK;
    return systemOK;
}

static BOOL settings_key_is_dark_tweak(NSString *key)
{
    return [key isEqualToString:kSettingsDSDisableAppLibrary] ||
           [key isEqualToString:kSettingsDSDisableIconFlyIn] ||
           [key isEqualToString:kSettingsDSZeroWakeAnimation] ||
           [key isEqualToString:kSettingsDSZeroBacklightFade] ||
           [key isEqualToString:kSettingsDSDoubleTapToLock] ||
           [key isEqualToString:kSettingsDSDragCoefficientEnabled] ||
           [key isEqualToString:kSettingsDSDragCoefficientValue];
}

static BOOL settings_key_affects_package_state(NSString *key)
{
    return [settings_rc_backed_tweak_keys() containsObject:key];
}

// Repo sources switch. Turning it off stops repo JS already running in
// SpringBoard (RepoTweaks, and QuickLoader when its script came from a
// source); the installer tabs listen for the notification to hide Sources
// and repo packages and to drop queued repo packages.
static void settings_repo_sources_enabled_changed(BOOL enabled)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    log_user("[SETTINGS] Repo sources %s.\n", enabled ? "enabled" : "disabled");
    if (!enabled) {
        BOOL stopQuickLoader = quickloader_is_driven_by_repo_tweak();
        settings_mark_tweak_applied(kSettingsRepoTweaksEnabled, NO);
        if (stopQuickLoader) settings_mark_tweak_applied(kSettingsQuickLoaderEnabled, NO);
        if (g_springboard_rc_ready) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                @synchronized (settings_rc_lock()) {
                    if (!g_springboard_rc_ready) return;
                    repotweaks_stop_in_session();
                    if (stopQuickLoader) quickloader_stop_in_session();
                }
            });
        }
    } else {
        // Re-enabled: a repo-driven QuickLoader script runs again on next Apply.
        if ([d boolForKey:kSettingsRepoTweaksEnabled]) settings_mark_tweak_needs_apply(kSettingsRepoTweaksEnabled);
        if ([d boolForKey:kSettingsQuickLoaderEnabled] && quickloader_is_driven_by_repo_tweak())
            settings_mark_tweak_needs_apply(kSettingsQuickLoaderEnabled);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RepoSourcesEnabledDidChangeNotification object:nil];
    });
    settings_notify_package_queue_changed_async();
}

static void settings_schedule_live_apply_for_key(NSString *key)
{
    if (settings_cleanup_in_progress()) {
        printf("[SETTINGS] live apply skipped during cleanup for %s\n", key.UTF8String);
        return;
    }

    if (!settings_device_supported()) {
        printf("[SETTINGS] live apply blocked for %s: %s\n",
               key.UTF8String, settings_unsupported_message().UTF8String);
        return;
    }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (settings_key_is_location_sim(key)) {
        BOOL locsimStarted = [d boolForKey:kSettingsLocationSimStarted];
        if ([key isEqualToString:kSettingsLocationSimEnabled]) {
            [d setBool:NO forKey:kSettingsLocationSimEnabled];
            [d synchronize];
            settings_notify_package_queue_changed_async();
            return;
        }
        if (!locsimStarted) {
            settings_notify_package_queue_changed_async();
            return;
        }
        if (!settings_location_sim_install_allowed()) {
            log_user("[LOCSIM] Target refresh skipped: Location Simulator is unavailable in this build.\n");
            settings_notify_package_queue_changed_async();
            settings_post_actions_complete_async(NO, @"Location Simulator is unavailable in this build.");
            return;
        }
        if (settings_any_registered_live_loop_running()) {
            log_user("[LOCSIM] Location update deferred: a live SpringBoard tweak is running. Hit Apply Tweaks to serialize the process switch.\n");
            settings_notify_package_queue_changed_async();
            settings_post_actions_complete_async(NO, @"Location refresh deferred while another live tweak is running.");
            return;
        }
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            if (__sync_lock_test_and_set(&g_settings_actions_running, 1)) {
                log_user("[LOCSIM] Location update deferred: Apply Tweaks is still running.\n");
                settings_post_actions_complete_async(NO, @"Location refresh deferred while Apply Tweaks is running.");
                settings_notify_package_queue_changed_async();
                return;
            }
            @try {
                if (!settings_ensure_kexploit()) {
                    printf("[LOCSIM] live target refresh failed to acquire KRW\n");
                    log_user("[LOCSIM] Target refresh failed: kernel primitives were not acquired. Please try running chain again.\n");
                    settings_post_actions_complete_async(NO, @"Location refresh failed: kernel primitives were not acquired.");
                    settings_notify_package_queue_changed_async();
                    return;
                }
                if (settings_any_registered_live_loop_running()) {
                    log_user("[LOCSIM] Location update deferred: a live SpringBoard tweak started while recovery was running. Hit Apply Tweaks to serialize the process switch.\n");
                    settings_post_actions_complete_async(NO, @"Location refresh deferred while another live tweak is running.");
                    settings_notify_package_queue_changed_async();
                    return;
                }
                @synchronized (settings_rc_lock()) {
                    settings_destroy_springboard_remote_call_locked_internal("switching to Location Simulator", NO);
                    bool ok = settings_apply_location_sim_from_defaults_locked(d);
                    if (ok) {
                        [d setBool:YES forKey:kSettingsLocationSimStarted];
                        [d synchronize];
                    }
                    log_user("%s Location Simulator %s.\n",
                             ok ? "[OK]" : "[WARN]",
                             ok ? "target refreshed" : "did not apply cleanly");
                    settings_post_actions_complete_async(ok,
                        ok ? @"Location target refreshed." : @"Location refresh failed. Check the log.");
                }
                settings_notify_package_queue_changed_async();
            } @finally {
                __sync_lock_release(&g_settings_actions_running);
            }
        });
        return;
    }



    if (settings_key_is_appswitchergrid(key)) {
        if ([d boolForKey:kSettingsAppSwitcherGridEnabled] && g_springboard_rc_ready) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() ||
                        ![d boolForKey:kSettingsAppSwitcherGridEnabled] ||
                        !g_springboard_rc_ready) return;
                    bool ok = appswitchergrid_apply_in_session();
                    settings_mark_tweak_applied(kSettingsAppSwitcherGridEnabled,
                                                ok && [d boolForKey:kSettingsAppSwitcherGridEnabled]);
                    printf("[SETTINGS] live App Switcher Grid apply result=%d\n", ok);
                }
                settings_notify_package_queue_changed_async();
            });
        } else if (![d boolForKey:kSettingsAppSwitcherGridEnabled]) {
            settings_mark_tweak_applied(kSettingsAppSwitcherGridEnabled, NO);
            settings_notify_package_queue_changed_async();
            if (g_springboard_rc_ready) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    @synchronized (settings_rc_lock()) {
                        if (g_springboard_rc_ready) appswitchergrid_stop_in_session();
                    }
                });
            } else {
                appswitchergrid_forget_remote_state();
            }
        }
        return;
    }

    if (settings_key_is_nsbar(key)) {
        if ([d boolForKey:kSettingsNSBarEnabled] && g_springboard_rc_ready) {
            settings_apply_nsbar_once_async("live settings");
        } else if (![d boolForKey:kSettingsNSBarEnabled]) {
            g_nsbar_live_stop_requested = 1;
            settings_mark_tweak_applied(kSettingsNSBarEnabled, NO);
            settings_notify_package_queue_changed_async();
            if (g_springboard_rc_ready) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    @synchronized (settings_rc_lock()) {
                        if (g_springboard_rc_ready) nsbar_stop_in_session();
                    }
                });
            }
        }
        return;
    }

    if (settings_key_is_nicebarlite(key)) {
        BOOL forceWeatherRefresh = [key isEqualToString:kSettingsNiceBarLiteCelsius];
        if (forceWeatherRefresh || [key hasPrefix:kSettingsNiceBarLiteSlotKindPrefix]) {
            settings_nicebar_refresh_weather_if_needed(forceWeatherRefresh, nil);
        }
        if ([d boolForKey:kSettingsNiceBarLiteEnabled] && g_springboard_rc_ready) {
            settings_apply_nicebarlite_once_async("live settings");
        } else if (![d boolForKey:kSettingsNiceBarLiteEnabled]) {
            g_nicebarlite_live_stop_requested = 1;
            settings_mark_tweak_applied(kSettingsNiceBarLiteEnabled, NO);
            settings_notify_package_queue_changed_async();
            if (g_springboard_rc_ready) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    @synchronized (settings_rc_lock()) {
                        if (g_springboard_rc_ready) nicebarlite_stop_in_session();
                    }
                });
            }
        }
        return;
    }

    if ([key isEqualToString:kSettingsLiveWPVideoPath]) {
        settings_notify_package_queue_changed_async();
        return;
    }

    if ([key isEqualToString:kSettingsLiveWPEnabled]) {
        if ([d boolForKey:kSettingsLiveWPEnabled] && g_springboard_rc_ready) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                bool ok = false;
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() ||
                        ![d boolForKey:kSettingsLiveWPEnabled] ||
                        !g_springboard_rc_ready) return;
                    ok = livewp_apply_in_session();
                    settings_mark_tweak_applied(kSettingsLiveWPEnabled, ok);
                }
                printf("[SETTINGS] live LiveWP apply result=%d\n", ok);
                if (ok) settings_start_livewp_live_loop();
                settings_notify_package_queue_changed_async();
            });
        } else if (![d boolForKey:kSettingsLiveWPEnabled]) {
            g_livewp_live_stop_requested = 1;
            settings_mark_tweak_applied(kSettingsLiveWPEnabled, NO);
            settings_notify_package_queue_changed_async();
            if (g_springboard_rc_ready) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    @synchronized (settings_rc_lock()) {
                        if (g_springboard_rc_ready) livewp_stop_in_session();
                    }
                });
            }
        }
        return;
    }

    if (settings_key_is_gravitylite(key)) {
        if ([d boolForKey:kSettingsGravityLiteEnabled] && g_springboard_rc_ready) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() || !g_springboard_rc_ready) return;
                    bool ok = settings_app_state_is_foreground()
                        ? settings_arm_gravitylite_for_background_start_locked(d, "live settings")
                        : settings_apply_gravitylite_from_defaults_locked(d);
                    settings_mark_tweak_applied(kSettingsGravityLiteEnabled,
                                                ok && [d boolForKey:kSettingsGravityLiteEnabled]);
                    printf("[SETTINGS] live Gravity Lite apply result=%d\n", ok);
                }
                settings_notify_package_queue_changed_async();
            });
        } else if (![d boolForKey:kSettingsGravityLiteEnabled]) {
            __sync_lock_test_and_set(&g_gravitylite_background_armed, 0);
            settings_mark_tweak_applied(kSettingsGravityLiteEnabled, NO);
            settings_notify_package_queue_changed_async();
            if (g_springboard_rc_ready) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    @synchronized (settings_rc_lock()) {
                        if (g_springboard_rc_ready) gravitylite_stop_in_session();
                    }
                });
            }
        }
        return;
    }

    if (settings_key_is_axonlite(key)) {
        if ([d boolForKey:kSettingsAxonLiteEnabled] && g_springboard_rc_ready) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                if (!settings_axonlite_can_poll_springboard()) {
                    printf("[SETTINGS] live Axon Lite apply skipped: %s\n",
                           settings_axonlite_pause_reason());
                    settings_start_axonlite_live_loop();
                    settings_notify_package_queue_changed_async();
                    return;
                }
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() || !g_springboard_rc_ready) return;
                    if (!settings_axonlite_can_poll_springboard()) {
                        printf("[SETTINGS] live Axon Lite apply skipped inside lock: %s\n",
                               settings_axonlite_pause_reason());
                        settings_start_axonlite_live_loop();
                        settings_notify_package_queue_changed_async();
                        return;
                    }
                    bool ok = axonlite_apply_in_session();
                    settings_mark_tweak_applied(kSettingsAxonLiteEnabled,
                                                ok && [d boolForKey:kSettingsAxonLiteEnabled]);
                    printf("[SETTINGS] live Axon Lite apply result=%d\n", ok);
                }
                settings_start_axonlite_live_loop();
                settings_notify_package_queue_changed_async();
            });
        } else if (![d boolForKey:kSettingsAxonLiteEnabled]) {
            g_axonlite_live_stop_requested = 1;
            settings_mark_tweak_applied(kSettingsAxonLiteEnabled, NO);
            settings_notify_package_queue_changed_async();
            if (g_springboard_rc_ready) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    @synchronized (settings_rc_lock()) {
                        if (g_springboard_rc_ready) axonlite_stop_in_session();
                    }
                });
            }
        }
        return;
    }

    if (settings_key_is_statbar(key)) {
        if ([d boolForKey:kSettingsStatBarEnabled] && g_springboard_rc_ready) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() || !g_springboard_rc_ready) return;
                    bool ok = statbar_apply_in_session([d boolForKey:kSettingsStatBarCelsius],
                                                       [d boolForKey:kSettingsStatBarShowNet],
                                                       [d boolForKey:kSettingsStatBarShowCPU],
                                                       [d boolForKey:kSettingsStatBarShowLabels],
                                                       [d boolForKey:kSettingsStatBarNetworkOnly]);
                    settings_mark_tweak_applied(kSettingsStatBarEnabled,
                                                ok && [d boolForKey:kSettingsStatBarEnabled]);
                    printf("[SETTINGS] live StatBar apply result=%d\n", ok);
                }
                settings_start_statbar_live_loop();
                settings_notify_package_queue_changed_async();
            });
        } else if (![d boolForKey:kSettingsStatBarEnabled]) {
            g_statbar_live_stop_requested = 1;
            settings_mark_tweak_applied(kSettingsStatBarEnabled, NO);
            settings_notify_package_queue_changed_async();
            settings_end_statbar_background_task_async("StatBar disabled");
            if (g_springboard_rc_ready) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    @synchronized (settings_rc_lock()) {
                        if (g_springboard_rc_ready) statbar_stop_in_session();
                    }
                });
            }
        }
    }


    if (settings_key_is_dark_tweak(key)) {
        if (!g_springboard_rc_ready || ![d boolForKey:key]) return;
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            @synchronized (settings_rc_lock()) {
                if (settings_cleanup_in_progress() || !g_springboard_rc_ready) return;
                SettingsDarkTweaksResult result = settings_apply_dark_tweaks_from_defaults_locked(d);
                bool ok = settings_dark_tweaks_result_all_ok(result);
                if ([d boolForKey:kSettingsDSDisableAppLibrary])
                    settings_mark_tweak_applied(kSettingsDSDisableAppLibrary, result.disableAppLibrary);
                if ([d boolForKey:kSettingsDSDisableIconFlyIn])
                    settings_mark_tweak_applied(kSettingsDSDisableIconFlyIn, result.disableIconFlyIn);
                if ([d boolForKey:kSettingsDSZeroWakeAnimation])
                    settings_mark_tweak_applied(kSettingsDSZeroWakeAnimation, result.zeroWakeAnimation);
                if ([d boolForKey:kSettingsDSZeroBacklightFade])
                    settings_mark_tweak_applied(kSettingsDSZeroBacklightFade, result.zeroBacklightFade);
                if ([d boolForKey:kSettingsDSDoubleTapToLock])
                    settings_mark_tweak_applied(kSettingsDSDoubleTapToLock, result.doubleTapToLock);
                if ([d boolForKey:kSettingsDSDragCoefficientEnabled])
                    settings_mark_tweak_applied(kSettingsDSDragCoefficientEnabled, result.dragCoefficient);
                printf("[SETTINGS] live DarkSword memory patch results appLib=%d flyIn=%d wake=%d backlight=%d dblTap=%d drag=%d categoryOK=%d\n",
                       [d boolForKey:kSettingsDSDisableAppLibrary] ? result.disableAppLibrary : -1,
                       [d boolForKey:kSettingsDSDisableIconFlyIn] ? result.disableIconFlyIn : -1,
                       [d boolForKey:kSettingsDSZeroWakeAnimation] ? result.zeroWakeAnimation : -1,
                       [d boolForKey:kSettingsDSZeroBacklightFade] ? result.zeroBacklightFade : -1,
                       [d boolForKey:kSettingsDSDoubleTapToLock] ? result.doubleTapToLock : -1,
                       [d boolForKey:kSettingsDSDragCoefficientEnabled] ? result.dragCoefficient : -1,
                       ok);
            }
            settings_notify_package_queue_changed_async();
        });
        return;
    }
    if (settings_key_is_quickloader(key)) {
        BOOL repoTweaksKey = [key isEqualToString:kSettingsRepoTweaksEnabled];
        BOOL blockedByRepoSources = !repotweaks_sources_enabled() &&
                                    (repoTweaksKey || quickloader_is_driven_by_repo_tweak());
        if (blockedByRepoSources) return;
        if ([d boolForKey:key] && g_springboard_rc_ready) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() || !g_springboard_rc_ready) return;
                    bool ok = repoTweaksKey ? repotweaks_apply_in_session()
                                            : quickloader_apply_in_session();
                    settings_mark_tweak_applied(key, ok && [d boolForKey:key]);
                    printf("[SETTINGS] live %s apply result=%d\n",
                           repoTweaksKey ? "RepoTweaks" : "QuickLoader", ok);
                }
                settings_notify_package_queue_changed_async();
            });
        } else if (![d boolForKey:key]) {
            settings_mark_tweak_applied(key, NO);
            settings_notify_package_queue_changed_async();
            if (g_springboard_rc_ready) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    @synchronized (settings_rc_lock()) {
                        if (!g_springboard_rc_ready) return;
                        if (repoTweaksKey) {
                            repotweaks_stop_in_session();
                        } else {
                            quickloader_stop_in_session();
                        }
                    }
                });
            }
        }
        return;
    }

    if (settings_key_is_gravitylite(key)) {
        if ([d boolForKey:kSettingsGravityLiteEnabled] && g_springboard_rc_ready) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                bool ok = false;
                GravityLiteConfig config = {0};
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() || !g_springboard_rc_ready) return;
                    ok = settings_app_state_is_foreground()
                        ? settings_arm_gravitylite_for_background_start_locked(d, "live settings")
                        : settings_apply_gravitylite_from_defaults_locked(d);
                    config = settings_gravitylite_config_from_defaults(d);
                    settings_mark_tweak_applied(kSettingsGravityLiteEnabled,
                                                ok && [d boolForKey:kSettingsGravityLiteEnabled]);
                    printf("[SETTINGS] live Gravity Lite apply result=%d\n", ok);
                }
                if (ok && !settings_app_state_is_foreground()) {
                    settings_start_gravity_motion(config.magnitude, config.explosionForce);
                }
                settings_notify_package_queue_changed_async();
            });
        } else if (![d boolForKey:kSettingsGravityLiteEnabled]) {
            __sync_lock_test_and_set(&g_gravitylite_background_armed, 0);
            settings_stop_gravity_motion();
            settings_mark_tweak_applied(kSettingsGravityLiteEnabled, NO);
            settings_notify_package_queue_changed_async();
            if (g_springboard_rc_ready) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    @synchronized (settings_rc_lock()) {
                        if (g_springboard_rc_ready) gravitylite_stop_in_session();
                    }
                });
            }
        }
        return;
    }

    if ([key isEqualToString:kSettingsLiveWPEnabled]) {
        if ([d boolForKey:kSettingsLiveWPEnabled] && g_springboard_rc_ready) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                bool ok = false;
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() || !g_springboard_rc_ready) return;
                    ok = livewp_apply_in_session();
                    settings_mark_tweak_applied(kSettingsLiveWPEnabled, ok);
                    printf("[SETTINGS] live LiveWP apply result=%d\n", ok);
                }
                if (ok) settings_start_livewp_live_loop();
                settings_notify_package_queue_changed_async();
            });
        } else if (![d boolForKey:kSettingsLiveWPEnabled]) {
            g_livewp_live_stop_requested = 1;
            settings_mark_tweak_applied(kSettingsLiveWPEnabled, NO);
            settings_notify_package_queue_changed_async();
            if (g_springboard_rc_ready) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    @synchronized (settings_rc_lock()) {
                        if (g_springboard_rc_ready) livewp_stop_in_session();
                    }
                });
            }
        }
        return;
    }

    if (!settings_key_is_sbc(key) || !g_springboard_rc_ready) return;

    uint64_t generation = __sync_add_and_fetch(&g_sbc_live_apply_generation, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(0, 0), ^{
        if (generation != g_sbc_live_apply_generation) return;
        if (settings_cleanup_in_progress()) return;

        @synchronized (settings_rc_lock()) {
            if (settings_cleanup_in_progress() || !g_springboard_rc_ready) return;
            bool ok = settings_apply_sbc_from_defaults_locked(d);
            settings_mark_tweak_applied(kSettingsSBCEnabled,
                                        ok && [d boolForKey:kSettingsSBCEnabled]);
            printf("[SETTINGS] live SBC apply result=%d\n", ok);
            log_user("%s SBCustomizer settings %s live through SpringBoard.\n",
                     ok ? "[OK]" : "[WARN]",
                     ok ? "applied" : "did not apply; leaving refresh pending");
        }
        settings_notify_package_queue_changed_async();
    });
}

static NSString * const kSettingsVerboseLoggingEnabled = @"VerboseLoggingEnabled";

void settings_register_defaults(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults registerDefaults:@{
        // pe_v1 (stored as 1) stays the default. pe_v2 looked better over 44
        // fresh chain runs on iPhone17,2 / iOS 18.5 22F76 — 12/21 acquired
        // against 10/23, 5/21 panics against 9/23 — but neither gap is
        // significant (Fisher p=0.55 and p=0.34, confidence intervals almost
        // fully overlapping), so there is no evidence to change what ships.
        // What the logs do disprove is the old claim that pe_v2 has never
        // acquired on A18: it did, 12 times. See kexploit_opa334.m.
        // Must be spelled out as a registered default because reinstalling a
        // sideloaded build wipes NSUserDefaults.
        kSettingsA18ExploitPath:     @1,
        // Off by default: baseline bulk-spray + forward-scan is the proven pe_v1
        // path (~4/7). Interleave+reverse-scan (approach A) pins the find to the
        // mapping tail but has not measured a better panic rate, so it is opt-in.
        kSettingsA18Interleave:      @NO,
        // A18 memory shaping mode: 0 = off (standard geometry, 1 GB window, no
        // pin), 1 = dynamic (pin ~75% of live jetsam headroom, 4 MB window),
        // 2 = fixed 3 GB. Default 2 -- this is the 1.5.5 geometry, which field
        // data shows is markedly more reliable on A18/M4 (fewer aperture-panic
        // reboots) than dynamic. Dynamic shipped as the 1.5.7 default and cut
        // the success rate roughly in half on the devices we heard back from.
        // A one-time migration below (settings_register_defaults) moves anyone
        // still on dynamic -- including a 1.5.6 @YES that reads back as 1 -- to
        // 3 GB, so updaters get the 1.5.5 behaviour too, not just fresh installs.
        kSettingsA18MemoryShaping:   @2,
        // Default OFF = 1.5.5 behaviour: pe_v1 grinds until it acquires. On caps
        // the search at 4 passes and returns a clean retry instead of grinding,
        // which can otherwise end in an aperture panic on a device that never
        // lands the PCB.
        kSettingsA18BoundedSearch:   @NO,
        kSettingsRemoteSettleMode:   @2,
        kSettingsAutoRunKexploit:    @NO,
        kSettingsRunSandboxEscape:   @YES,
        kSettingsRunPatchSandboxExt: @NO,
        kSettingsKeepAlive:          @YES,

        kSettingsSBCEnabled:    @NO,
        kSettingsSBCDockIcons:  @(kSBCDefaultDockIcons),
        kSettingsSBCCols:       @(kSBCDefaultCols),
        kSettingsSBCRows:       @(kSBCDefaultRows),
        kSettingsSBCHideLabels: @(kSBCDefaultHideLabels),
        kSettingsSBCDockLabels: @(kSBCDefaultDockLabels),
        kSettingsSBCArrangePages: @(kSBCDefaultArrangePages),
        kSettingsSBCFirstPageIcons: @(kSBCDefaultFirstPageIcons),
        kSettingsSBCOtherPageIcons: @(kSBCDefaultOtherPageIcons),
        kSettingsSBCAutoDockApp: @(kSBCDefaultAutoDockApp),
        kSettingsSBCDockAppBundleID: kSBCDefaultDockAppBundleID,

        kSettingsPowercuffEnabled: @NO,
        kSettingsPowercuffLevel:   @"nominal",

        kSettingsDSDisableAppLibrary: @NO,
        kSettingsDSDisableIconFlyIn:  @NO,
        kSettingsDSZeroWakeAnimation: @NO,
        kSettingsDSZeroBacklightFade: @NO,
        kSettingsDSDoubleTapToLock:   @NO,

        kSettingsLockDurationValue:   @(kSettingsLockDurationDefault),

        kSettingsDSDragCoefficientEnabled: @NO,
        kSettingsDSDragCoefficientValue:   @0.5,

        kSettingsLayoutExtrasEnabled:       @NO,
        kSettingsLayoutHomeExtraLeft:       @0,
        kSettingsLayoutHomeExtraRight:      @0,
        kSettingsLayoutHomeExtraTop:        @0,
        kSettingsLayoutHomeExtraBottom:     @0,
        kSettingsLayoutDockExtraLeft:  @0,
        kSettingsLayoutDockExtraRight: @0,
        kSettingsLayoutHomeScalePct:        @100,
        kSettingsLayoutDockScalePct:        @100,

        kSettingsStatBarEnabled: @NO,
        kSettingsStatBarCelsius: @NO,
        kSettingsStatBarShowNet:    @NO,
        kSettingsStatBarShowCPU:    @YES,
        kSettingsStatBarShowLabels: @YES,
        kSettingsStatBarNetworkOnly: @NO,
        kSettingsStatBarRefreshRateSec: @(kStatBarDefaultRefreshRateSec),

        kSettingsNSBarEnabled: @NO,
        kSettingsNSBarPosition: @(NSBarPositionTopLeft),

        kSettingsNiceBarLiteEnabled: @NO,
        kSettingsNiceBarLiteCelsius: @YES,
        kSettingsNiceBarLiteLayoutTopSideInset: @0,
        kSettingsNiceBarLiteLayoutBottomSideInset: @0,
        kSettingsNiceBarLiteLayoutTopY: @0,
        kSettingsNiceBarLiteLayoutBottomY: @0,
        kSettingsNiceBarLiteLayoutCenterX: @0,
        settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, NiceBarLiteSlotTopLeft): @(NiceBarLiteContentTimeFormat),
        settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, NiceBarLiteSlotTopRight): @(NiceBarLiteContentSystem),
        settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, NiceBarLiteSlotBottomLeft): @(NiceBarLiteContentSystem),
        settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, NiceBarLiteSlotBottomRight): @(NiceBarLiteContentOff),
        settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, NiceBarLiteSlotBottomCenter): @(NiceBarLiteContentOff),
        settings_nicebar_key(kSettingsNiceBarLiteSlotSystemPrefix, NiceBarLiteSlotTopRight): @(NiceBarLiteSystemBatteryPercent),
        settings_nicebar_key(kSettingsNiceBarLiteSlotSystemPrefix, NiceBarLiteSlotBottomLeft): @(NiceBarLiteSystemFreeRAM),
        settings_nicebar_key(kSettingsNiceBarLiteSlotTimePrefix, NiceBarLiteSlotTopLeft): @"HH:mm",
        settings_nicebar_key(kSettingsNiceBarLiteSlotSystemLanguagePrefix, NiceBarLiteSlotTopRight): @"en",
        settings_nicebar_key(kSettingsNiceBarLiteSlotSystemLanguagePrefix, NiceBarLiteSlotBottomLeft): @"en",
        settings_nicebar_key(kSettingsNiceBarLiteSlotWeatherLanguagePrefix, NiceBarLiteSlotTopLeft): @"en",
        settings_nicebar_key(kSettingsNiceBarLiteSlotWeatherLanguagePrefix, NiceBarLiteSlotTopRight): @"en",
        settings_nicebar_key(kSettingsNiceBarLiteSlotWeatherLanguagePrefix, NiceBarLiteSlotBottomLeft): @"en",
        settings_nicebar_key(kSettingsNiceBarLiteSlotWeatherLanguagePrefix, NiceBarLiteSlotBottomRight): @"en",
        settings_nicebar_key(kSettingsNiceBarLiteSlotWeatherLanguagePrefix, NiceBarLiteSlotBottomCenter): @"en",
        kSettingsNiceBarLiteWeatherCache: @"Weather --",


        kSettingsAxonLiteEnabled: @NO,


        kSettingsFastLockXLiteEnabled: @NO,
        kSettingsFastLockXLiteBlockMusic: @NO,
        kSettingsFastLockXLiteBlockFlashlight: @NO,
        kSettingsFastLockXLiteBlockLowPower: @NO,
        kSettingsFastLockXLiteRetryInterval: @0.3,

        kSettingsRunAutoRetry: @NO,
        kRepoSourcesEnabledKey: @YES,
        kSettingsLocationServicesLinksEnabled: @NO,
        kSettingsRunAutoRetryMaxAttempts: @8,
        kRemoteCallControlledPanicOnWedge: @NO,

        kSettingsGravityLiteEnabled: @NO,
        kSettingsGravityLiteDockEnabled: @YES,
        kSettingsGravityLiteMagnitudePct: @100,
        kSettingsGravityLiteBouncePct: @50,
        kSettingsGravityLiteFrictionPct: @50,
        kSettingsGravityLiteResistancePct: @50,
        kSettingsGravityLiteAngularResistancePct: @0,

        kSettingsStageStripEnabled: @NO,

        kSettingsLocationSimEnabled: @NO,
        kSettingsLocationSimLatitude: @(kLocationSimDefaultLatitude),
        kSettingsLocationSimLongitude: @(kLocationSimDefaultLongitude),
        kSettingsLocationSimAltitude: @(kLocationSimDefaultAltitude),
        kSettingsLocationSimHorizontalAccuracy: @(kLocationSimDefaultAccuracy),
        kSettingsLocationSimHostProcess: @"Maps",
        kSettingsLocationSimStarted: @NO,

        kSettingsThemerEnabled: @NO,
        kSettingsThemerThemeID: kThemerThemeNone,
        kSettingsThemerCustomThemePath: @"",
        kSettingsThemerCustomThemeName: @"",

        kSettingsSnowBoardLiteEnabled: @NO,
        kSettingsSnowBoardLiteSelectedThemeID: @"",

        kSettingsLiveWPEnabled: @NO,
        kSettingsLiveWPVideoPath: @"",

        kSettingsAppSwitcherGridEnabled: @NO,

        kSettingsQuickLoaderEnabled: @NO,
        kSettingsRepoTweaksEnabled: @NO,

        kSettingsExperimentalTweaksEnabled: @NO,

        kSettingsNanoMaxPairing:       @(kNanoDefaultMaxPairing),
        kSettingsNanoMinPairing:       @(kNanoDefaultMinPairing),
        kSettingsNanoMinPairingChipID: @(kNanoDefaultMinPairingChipID),
        kSettingsNanoMinQuickSwitch:   @(kNanoDefaultMinQuickSwitch),
    }];
    // One-time: 1.5.7 shipped Dynamic (mode 1) as the shaping default, which
    // pins a fraction of live jetsam headroom instead of the fixed 3 GB that
    // 1.5.5 used. Field data showed the fixed 3 GB is markedly more reliable on
    // A18/M4 (fewer aperture-panic reboots), so 3 GB is the default again. Move
    // anyone still on Dynamic -- whether from the old registered default, from
    // an unset key (a 1.5.5 updater), or from a 1.5.6 BOOL "on" that reads back
    // as 1 -- onto 3 GB, once. An unset key now resolves to the @2 registration
    // default, so only a persisted 1 trips this. An explicit Off (0) is a
    // deliberate choice and is left alone, and because this is gated by a
    // one-shot flag, a user who re-selects Dynamic afterwards keeps it.
    static NSString * const kSettingsA18ShapeThreeGBMigration =
        @"cyanide.a18shape.default3GB.v1";
    if (![defaults boolForKey:kSettingsA18ShapeThreeGBMigration]) {
        if ([defaults integerForKey:kSettingsA18MemoryShaping] == 1) {
            [defaults setInteger:2 forKey:kSettingsA18MemoryShaping];
            printf("[SETTINGS] A18 memory shaping migrated Dynamic -> 3 GB "
                   "(1.5.5 default restored)\n");
        }
        [defaults setBool:YES forKey:kSettingsA18ShapeThreeGBMigration];
        [defaults synchronize];
    }
    // One-time: the single "Dock extra horizontal" padding became separate
    // left/right sliders. Seed both new keys from any persisted old value so an
    // existing symmetric setting carries over. One-shot flag, so later per-side
    // edits are never clobbered.
    static NSString * const kSettingsDockPadSplitMigration =
        @"cyanide.dockpad.splitLR.v1";
    if (![defaults boolForKey:kSettingsDockPadSplitMigration]) {
        id oldDockH = [defaults objectForKey:kSettingsLayoutDockExtraHorizontalLegacy];
        if (oldDockH != nil) {
            [defaults setObject:oldDockH forKey:kSettingsLayoutDockExtraLeft];
            [defaults setObject:oldDockH forKey:kSettingsLayoutDockExtraRight];
            [defaults removeObjectForKey:kSettingsLayoutDockExtraHorizontalLegacy];
            printf("[SETTINGS] Dock extra horizontal migrated -> separate L/R\n");
        }
        [defaults setBool:YES forKey:kSettingsDockPadSplitMigration];
        [defaults synchronize];
    }
    NSString *selectedDockBundle = [defaults stringForKey:kSettingsSBCDockAppBundleID];
    if ([selectedDockBundle isEqualToString:kSBCLegacyDockAppBundleID]) {
        [defaults setObject:kSBCDefaultDockAppBundleID
                    forKey:kSettingsSBCDockAppBundleID];
        [defaults synchronize];
        printf("[SETTINGS] SBC Dock app migrated %s -> %s\n",
               kSBCLegacyDockAppBundleID.UTF8String,
               kSBCDefaultDockAppBundleID.UTF8String);
    }
    settings_purge_legacy_access_auth();
    repotweaks_seed_default_repos();
    if (!cyanide_experimental_tweaks_available()) {
        BOOL changed = NO;
        NSArray<NSString *> *privateKeys = @[
            kSettingsStageStripEnabled,
            kSettingsFastLockXLiteEnabled,
        ];
        for (NSString *key in privateKeys) {
            if ([defaults boolForKey:key]) {
                [defaults setBool:NO forKey:key];
                changed = YES;
            }
        }
        if (changed) [defaults synchronize];
    }
    {
        BOOL changed = NO;
        NSArray<NSString *> *inDevKeys = @[
        ];
        if ([defaults boolForKey:kSettingsExperimentalTweaksEnabled]) {
            [defaults setBool:NO forKey:kSettingsExperimentalTweaksEnabled];
            changed = YES;
        }
        for (NSString *key in inDevKeys) {
            if ([defaults boolForKey:key]) {
                [defaults setBool:NO forKey:key];
                changed = YES;
            }
        }
        if (changed) [defaults synchronize];
    }
    if ([defaults boolForKey:kSettingsThemerEnabled]) {
        [defaults setBool:NO forKey:kSettingsThemerEnabled];
        [defaults synchronize];
    }
    if ([defaults boolForKey:kSettingsSnowBoardLiteEnabled] &&
        !settings_snowboardlite_has_selected_theme()) {
        [defaults setBool:NO forKey:kSettingsSnowBoardLiteEnabled];
        [defaults synchronize];
    }
    settings_install_screen_awake_observers();

    // Apply the persisted verbose-logging choice (default off) so the Settings
    // debug toggle survives relaunch and the RemoteCall guard/RC_DEBUG spam
    // stays suppressed unless explicitly enabled.
    remote_call_set_verbose([defaults boolForKey:kSettingsVerboseLoggingEnabled]);
    // Round 43: keep routine [RC] lines out of the user log unless verbose
    // debug is on (then show the full firehose for diagnosis).
    log_set_rc_filter(![defaults boolForKey:kSettingsVerboseLoggingEnabled]);
}

static void settings_run_actions_internal(BOOL pendingOnly)
{
    g_settings_actions_last_pending_only = pendingOnly;
    if (!settings_device_supported()) {
        NSString *message = settings_unsupported_message();
        // This completion is the one that gets posted: consume any installer
        // preflight note here too, or it would ride into an unrelated later run.
        (void)settings_take_run_preflight_failure();
        printf("[SETTINGS] run blocked: %s\n", message.UTF8String);
        log_user("[RUN] %s\n", message.UTF8String);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:PackageQueueDidChangeNotification
                                                                object:[PackageQueue sharedQueue]];
        });
        settings_post_actions_complete_async(NO, message);
        return;
    }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        if (__sync_lock_test_and_set(&g_settings_actions_running, 1)) {
            __sync_lock_test_and_set(&g_settings_actions_rerun_requested, 1);
            printf("[SETTINGS] actions already running; queued one follow-up run\n");
            log_user("[RUN] Already running. Queued one follow-up run for the latest package state.\n");
            return;
        }
        dispatch_sync(dispatch_get_main_queue(), ^{
            if (!g_settings_actions_idle_held) {
                g_settings_actions_idle_was_disabled = UIApplication.sharedApplication.idleTimerDisabled;
                g_settings_actions_idle_held = YES;
            }
            UIApplication.sharedApplication.idleTimerDisabled = YES;
        });
        if (!pendingOnly && settings_any_registered_live_loop_running()) {
            settings_request_all_live_loops_stop("Apply Tweaks");
            settings_wait_live_loops_stopped_for_switch("Apply Tweaks");
        }
        log_session_begin();
        cyanide_start_session_uploads();
        BOOL runSucceeded = NO;
        BOOL runHadBlockingFailure = NO;
        NSString *runCompletionMessage = @"Run failed. Check the log for details.";
        // Stages that ran but did not apply. They keep their pending marker
        // (settings_mark_tweak_applied(..., NO)), so the next run retries them;
        // this only makes the final status say so instead of "All finished".
        NSMutableArray<NSString *> *runWarnings = [NSMutableArray array];
        BOOL runPartial = NO;
        uint64_t runStartNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        RPerfSnapshot runPerf0;
        r_perf_snapshot(&runPerf0);
        @try {
            BOOL patchSandboxExt = [d boolForKey:kSettingsRunPatchSandboxExt];
            BOOL runPowercuff = settings_enabled_tweak_should_run(d, kSettingsPowercuffEnabled, pendingOnly);
            BOOL forceSpringBoardRefresh = runPowercuff &&
                                           settings_has_persistent_springboard_remote_call_user();
            BOOL springBoardPendingOnly = pendingOnly && !forceSpringBoardRefresh;
            BOOL statBarEnabled = [d boolForKey:kSettingsStatBarEnabled];
            BOOL nsBarEnabled = [d boolForKey:kSettingsNSBarEnabled];
            BOOL niceBarLiteEnabled = [d boolForKey:kSettingsNiceBarLiteEnabled];
            BOOL axonLiteEnabled = [d boolForKey:kSettingsAxonLiteEnabled];
            BOOL appSwitcherGridEnabled = [d boolForKey:kSettingsAppSwitcherGridEnabled];
            BOOL themerEnabled = [d boolForKey:kSettingsThemerEnabled];
            BOOL snowboardLiteEnabled = [d boolForKey:kSettingsSnowBoardLiteEnabled];
            BOOL liveWPEnabled = [d boolForKey:kSettingsLiveWPEnabled];
            BOOL layoutExtrasEnabled = [d boolForKey:kSettingsLayoutExtrasEnabled];
            BOOL stageStripEnabled = settings_stagestrip_install_allowed() && [d boolForKey:kSettingsStageStripEnabled];
            BOOL gravityLiteEnabled = [d boolForKey:kSettingsGravityLiteEnabled];
            BOOL runSBC = settings_enabled_tweak_should_run(d, kSettingsSBCEnabled, springBoardPendingOnly);
            BOOL runDarkTweaks = settings_dark_tweaks_should_run(d, springBoardPendingOnly);
            BOOL runStatBar = settings_enabled_tweak_should_run(d, kSettingsStatBarEnabled, springBoardPendingOnly);
            BOOL runNSBar = settings_enabled_tweak_should_run(d, kSettingsNSBarEnabled, springBoardPendingOnly);
            BOOL runNiceBarLite = settings_enabled_tweak_should_run(d, kSettingsNiceBarLiteEnabled, springBoardPendingOnly);
            BOOL runAxonLite = settings_enabled_tweak_should_run(d, kSettingsAxonLiteEnabled, springBoardPendingOnly);
            BOOL runAppSwitcherGrid = settings_enabled_tweak_should_run(d, kSettingsAppSwitcherGridEnabled, springBoardPendingOnly);
            BOOL runThemer = settings_enabled_tweak_should_run(d, kSettingsThemerEnabled, springBoardPendingOnly);
            BOOL runSnowBoardLite = settings_enabled_tweak_should_run(d, kSettingsSnowBoardLiteEnabled, springBoardPendingOnly);
            BOOL runLiveWP = settings_enabled_tweak_should_run(d, kSettingsLiveWPEnabled, springBoardPendingOnly);
            BOOL runLayoutExtras = settings_enabled_tweak_should_run(d, kSettingsLayoutExtrasEnabled, springBoardPendingOnly);
            // SBCustomizer changes the grid and Dock contents. Re-run enabled
            // Layout Extras even if it was already marked applied so spacing
            // is recalculated from the final SBCustomizer state.
            if (runSBC && layoutExtrasEnabled) runLayoutExtras = YES;
            BOOL runStageStrip = settings_stagestrip_install_allowed() && settings_enabled_tweak_should_run(d, kSettingsStageStripEnabled, springBoardPendingOnly);
            BOOL runFastLockXLite = settings_fastlockx_lite_install_allowed() && settings_enabled_tweak_should_run(d, kSettingsFastLockXLiteEnabled, springBoardPendingOnly);
            BOOL runGravityLite = settings_enabled_tweak_should_run(d, kSettingsGravityLiteEnabled, springBoardPendingOnly);
            // Repo sources switched off: skip repo tweaks, and QuickLoader too
            // while its script is one installed from a source.
            BOOL repoSourcesOn = repotweaks_sources_enabled();
            BOOL runQuickLoader = settings_enabled_tweak_should_run(d, kSettingsQuickLoaderEnabled, springBoardPendingOnly) &&
                                  (repoSourcesOn || !quickloader_is_driven_by_repo_tweak());
            BOOL runRepoTweaks = repoSourcesOn && settings_enabled_tweak_should_run(d, kSettingsRepoTweaksEnabled, springBoardPendingOnly);
            BOOL stagePausesThemerLive = settings_themer_dynamic_updates_blocked_by_stage(d);
            if (stagePausesThemerLive) {
                settings_note_themer_stage_conflict(YES);
            }
            BOOL cleanupDisabledSpringBoardTweaks = settings_disabled_applied_springboard_cleanup_needed(d);
            BOOL needsSpringBoardWork = runSBC || runDarkTweaks || runStatBar || runNSBar || runNiceBarLite || runAxonLite || runGravityLite || runLayoutExtras || runAppSwitcherGrid || runThemer || runSnowBoardLite || runLiveWP || runStageStrip || runFastLockXLite || runQuickLoader || runRepoTweaks || cleanupDisabledSpringBoardTweaks;
            BOOL runSandboxEscape = [d boolForKey:kSettingsRunSandboxEscape] && (!pendingOnly || needsSpringBoardWork);
            BOOL needsSpringBoard = runSandboxEscape || needsSpringBoardWork || forceSpringBoardRefresh;

            BOOL hasRunWork = patchSandboxExt || runPowercuff || needsSpringBoard;
            BOOL skipKernelForVPhoneSpringBoardOnly =
                cyanide_vphone_debug_build() &&
                needsSpringBoard &&
                !patchSandboxExt &&
                !runPowercuff;
            BOOL needsKernelPrimitiveStage = hasRunWork && !skipKernelForVPhoneSpringBoardOnly;
            NSUInteger total = needsKernelPrimitiveStage ? 1 : 0;
            if (patchSandboxExt) total++;
            if (runPowercuff) total++;
            if (needsSpringBoard) total++;
            if (runSandboxEscape) total++;
            if (runSBC) total++;
            if (runDarkTweaks) total++;
            if (runLayoutExtras) total++;
            if (runThemer) total++;
            if (runSnowBoardLite) total++;
            if (runLiveWP) total++;
            if (runStatBar) total++;
            if (runNSBar) total++;
            if (runNiceBarLite) total++;
            if (runAxonLite) total++;
            if (runGravityLite) total++;
            if (runAppSwitcherGrid) total++;
            if (runStageStrip) total++;
            if (runFastLockXLite) total++;
            if (runQuickLoader) total++;
            if (runRepoTweaks) total++;
            if (cleanupDisabledSpringBoardTweaks) total++;
            NSUInteger step = 0;
            BOOL startStageStripControlLoopAfterInstall = NO;

            settings_log_run_context();
            NSMutableArray *enabledTweaks = [NSMutableArray array];
            if (runSBC) [enabledTweaks addObject:@"layout"];
            if (runLayoutExtras) [enabledTweaks addObject:@"extras"];
            if (runStatBar) [enabledTweaks addObject:@"statbar"];
            if (runNSBar) [enabledTweaks addObject:@"nsbar"];
            if (runNiceBarLite) [enabledTweaks addObject:@"nicebar"];
            if (runAxonLite) [enabledTweaks addObject:@"axon"];
            if (runAppSwitcherGrid) [enabledTweaks addObject:@"app-switcher-grid"];
            if (runGravityLite) [enabledTweaks addObject:[NSString stringWithFormat:@"gravity(%ld%%)", (long)[d integerForKey:kSettingsGravityLiteMagnitudePct]]];
            if (runPowercuff) [enabledTweaks addObject:[NSString stringWithFormat:@"power(%@)", [d stringForKey:kSettingsPowercuffLevel] ?: @"nominal"]];
            if (runDarkTweaks) [enabledTweaks addObject:@"dark"];
            if (runThemer) [enabledTweaks addObject:@"themer"];
            if (runSnowBoardLite) [enabledTweaks addObject:@"snowboardlite"];
            if (runLiveWP) [enabledTweaks addObject:@"livewp"];
            if (runFastLockXLite) [enabledTweaks addObject:@"fastlockx"];
            if (runStageStrip) [enabledTweaks addObject:@"stagestrip"];
            if (runQuickLoader) [enabledTweaks addObject:@"quickloader"];
            if (runRepoTweaks) [enabledTweaks addObject:@"repotweaks"];
            if (cleanupDisabledSpringBoardTweaks) [enabledTweaks addObject:@"cleanup"];
            if (forceSpringBoardRefresh) [enabledTweaks addObject:@"springboard-refresh"];
            log_user("[PLAN] %lu stages: %s\n",
                     (unsigned long)total,
                     enabledTweaks.count ? [[enabledTweaks componentsJoinedByString:@", "] UTF8String] : "none");
            if (runFastLockXLite && runStageStrip) {
                log_user("[COMPAT] FastLockX Lite will arm before Dynamic Stage Lite starts its control loop.\n");
            }
            cyanide_upload_log_milestone(@"run-plan");

            if (!hasRunWork) {
                if (!statBarEnabled) g_statbar_live_stop_requested = 1;
                if (!nsBarEnabled) g_nsbar_live_stop_requested = 1;
                if (!niceBarLiteEnabled) g_nicebarlite_live_stop_requested = 1;
                if (!axonLiteEnabled) g_axonlite_live_stop_requested = 1;
                if (!themerEnabled && !snowboardLiteEnabled) g_themer_live_stop_requested = 1;
                if (!liveWPEnabled) g_livewp_live_stop_requested = 1;
                if (!gravityLiteEnabled) settings_request_gravitylite_stop();
                if (!stageStripEnabled) settings_request_stagestrip_stop();
                log_user("[DONE] No pending runtime changes to apply.\n");
                runSucceeded = YES;
                runCompletionMessage = @"Done. No pending runtime changes to apply.";
                cyanide_upload_log_milestone(@"run-noop");
                return;
            }

            if (needsKernelPrimitiveStage) {
                settings_progress(&step, total, "Racing kernel allocator for r/w primitives");
                if (!settings_ensure_kexploit()) {
                    log_user("[RUN] Failed: kernel primitives were not acquired. Please try running chain again.\n");
                    runCompletionMessage = kSettingsRunKRWFailedMessage;
                    cyanide_upload_log_milestone(@"krw-failed");
                    return;
                }
                log_user("[OK] Kernel r/w armed — injection staged.\n");
                cyanide_upload_log_milestone(@"krw-ready");
            } else if (skipKernelForVPhoneSpringBoardOnly) {
                log_user("[VPHONE] SpringBoard-only run — using the vphone bridge without app-side kernel primitives.\n");
                cyanide_upload_log_milestone(@"vphone-bridge-no-krw");
            }

            if (patchSandboxExt) {
                settings_progress(&step, total, "Patching sandbox-extension issue path");
                escape_sbx_demo3();
                log_user("[OK] Sandbox extension issue path patched.\n");
                cyanide_upload_log_milestone(@"sandbox-ext-patched");
            }
            if (runPowercuff) {
                settings_progress(&step, total, "Applying Powercuff via thermalmonitord");
                if (g_springboard_rc_ready || settings_any_registered_live_loop_running()) {
                    settings_request_all_live_loops_stop("Powercuff process switch");
                    settings_wait_live_loops_stopped_for_switch("Powercuff process switch");
                }
                @synchronized (settings_rc_lock()) {
                    // This is only a transient RemoteCall target switch. Do
                    // not run SpringBoard tweak stop paths or clear applied
                    // package state; enabled tweaks are reapplied below.
                    settings_destroy_springboard_remote_call_locked_internal("switching to thermalmonitord", NO);
                    NSString *lvl = [d stringForKey:kSettingsPowercuffLevel] ?: @"nominal";
                    bool ok = powercuff_apply(lvl.UTF8String);
                    settings_mark_tweak_applied(kSettingsPowercuffEnabled,
                                                ok && [d boolForKey:kSettingsPowercuffEnabled]);
                    log_user("%s Powercuff %s through thermalmonitord.\n",
                             ok ? "[OK]" : "[WARN]",
                             ok ? "applied" : "did not apply cleanly");
                    cyanide_upload_log_milestone(ok ? @"powercuff-applied" : @"powercuff-failed");
                    if (!ok) [runWarnings addObject:@"Powercuff"];
                }
            }

            if (needsSpringBoard) {
                // A fresh pe_v2 acquisition just wired/churned ~2 GB and hijacked
                // launchd; the system is briefly loaded, which can make the
                // SpringBoard EXC_GUARD hijack miss its trap window. Let it settle
                // first. Recovery (parked) does no staging, so skip it there, and
                // it's A18-only (pe_v1 stages little).
                if (needsKernelPrimitiveStage &&
                    !krw_persistence_is_recovered() &&
                    settings_device_is_a18_above() &&
                    [d integerForKey:kSettingsA18ExploitPath] != 1) {
                    log_user("[SESSION] Cooling down after staging before opening SpringBoard...\n");
                    usleep(2000000);   // 2s settle
                }
                @synchronized (settings_rc_lock()) {
                    settings_progress(&step, total, "Opening SpringBoard injection channel");
                    if (!settings_ensure_springboard_remote_call_locked()) {
                        log_user("[RUN] Failed: could not open the SpringBoard control session. Please try installing tweaks again.\n");
                        runCompletionMessage = @"Failed: could not open the SpringBoard control session. Please try installing tweaks again.";
                        cyanide_upload_log_milestone(@"springboard-remote-call-failed");
                        return;
                    }
                    log_user("[OK] SpringBoard channel open.\n");
                    cyanide_upload_log_milestone(@"springboard-remote-call-ready");

                    if (runSandboxEscape && !g_springboard_sandbox_escaped) {
                        settings_progress(&step, total, "Lifting SpringBoard filesystem sandbox");
                        int sbx = escape_sbx_demo2_in_session();
                        g_springboard_sandbox_escaped = (sbx == 0);
                        log_user("%s Filesystem sandbox %s.\n",
                                 sbx == 0 ? "[OK]" : "[WARN]",
                                 sbx == 0 ? "lifted — access granted" : "lift returned a warning");
                        cyanide_upload_log_milestone(sbx == 0 ? @"springboard-sandbox-token-ready" : @"springboard-sandbox-token-warning");
                    } else if (runSandboxEscape) {
                        settings_progress(&step, total, "Reusing sandbox token from prior run");
                        log_user("[OK] Sandbox already lifted — reusing token.\n");
                        cyanide_upload_log_milestone(@"springboard-sandbox-token-reused");
                    }

                    if (cleanupDisabledSpringBoardTweaks) {
                        settings_progress(&step, total, "Stopping disabled SpringBoard tweaks");
                        settings_stop_disabled_applied_springboard_tweaks_locked(d);
                        cyanide_upload_log_milestone(@"disabled-springboard-tweaks-stopped");
                    }


                    if (runDarkTweaks) {
                        settings_progress(&step, total, "Applying DarkSword tweaks");
                        SettingsDarkTweaksResult result = settings_apply_dark_tweaks_from_defaults_locked(d);
                        bool ok = settings_dark_tweaks_result_all_ok(result);
                        if ([d boolForKey:kSettingsDSDisableAppLibrary])
                            settings_mark_tweak_applied(kSettingsDSDisableAppLibrary, result.disableAppLibrary);
                        if ([d boolForKey:kSettingsDSDisableIconFlyIn])
                            settings_mark_tweak_applied(kSettingsDSDisableIconFlyIn, result.disableIconFlyIn);
                        if ([d boolForKey:kSettingsDSZeroWakeAnimation])
                            settings_mark_tweak_applied(kSettingsDSZeroWakeAnimation, result.zeroWakeAnimation);
                        if ([d boolForKey:kSettingsDSZeroBacklightFade])
                            settings_mark_tweak_applied(kSettingsDSZeroBacklightFade, result.zeroBacklightFade);
                        if ([d boolForKey:kSettingsDSDoubleTapToLock])
                            settings_mark_tweak_applied(kSettingsDSDoubleTapToLock, result.doubleTapToLock);
                        if ([d boolForKey:kSettingsDSDragCoefficientEnabled])
                            settings_mark_tweak_applied(kSettingsDSDragCoefficientEnabled, result.dragCoefficient);
                        printf("[SETTINGS] DarkSword memory patch results appLib=%d flyIn=%d wake=%d backlight=%d dblTap=%d drag=%d categoryOK=%d\n",
                               [d boolForKey:kSettingsDSDisableAppLibrary] ? result.disableAppLibrary : -1,
                               [d boolForKey:kSettingsDSDisableIconFlyIn] ? result.disableIconFlyIn : -1,
                               [d boolForKey:kSettingsDSZeroWakeAnimation] ? result.zeroWakeAnimation : -1,
                               [d boolForKey:kSettingsDSZeroBacklightFade] ? result.zeroBacklightFade : -1,
                               [d boolForKey:kSettingsDSDoubleTapToLock] ? result.doubleTapToLock : -1,
                               [d boolForKey:kSettingsDSDragCoefficientEnabled] ? result.dragCoefficient : -1,
                               ok);
                        log_user("%s DarkSword tweaks %s. Continuing with remaining changes…\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "applied" : "may need a refresh");
                        cyanide_upload_log_milestone(ok ? @"darksword-tweaks-applied" : @"darksword-tweaks-warning");
                        if (!ok) [runWarnings addObject:@"DarkSword tweaks"];
                    }

                    if (runThemer) {
                        settings_progress(&step, total, "Applying Icon Theme Engine");
                        bool ok = settings_apply_themer_from_defaults_locked(d);
                        settings_mark_tweak_applied(kSettingsThemerEnabled, ok);
                        printf("[SETTINGS] Themer result=%d\n", ok);
                        log_user("%s Icon Theme Engine %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "applied" : "did not apply cleanly");
                        cyanide_upload_log_milestone(ok ? @"themer-applied" : @"themer-warning");
                        if (!ok) [runWarnings addObject:@"Icon Theme Engine"];
                        if (ok) {
                            settings_start_themer_live_loop();
                        }
                    }

                    if (runSnowBoardLite) {
                        settings_progress(&step, total, "Applying SnowBoard Lite theme");
                        bool ok = settings_apply_snowboardlite_from_defaults_locked(d);
                        settings_mark_tweak_applied(kSettingsSnowBoardLiteEnabled,
                                                    ok && [d boolForKey:kSettingsSnowBoardLiteEnabled]);
                        printf("[SETTINGS] SnowBoard Lite result=%d\n", ok);
                        log_user("%s SnowBoard Lite %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "theme applied" : "did not apply cleanly");
                        cyanide_upload_log_milestone(ok ? @"snowboard-lite-applied" : @"snowboard-lite-warning");
                        if (!ok) [runWarnings addObject:@"SnowBoard Lite"];
                        if (ok && !settings_themer_live_repair_enabled(d)) {
                            log_user("[SBL] Live repair is enabled; Cyanide will keep the SpringBoard channel open so repair ticks reuse it.\n");
                            settings_start_themer_live_loop();
                        }
                    }

                    if (runGravityLite) {
                        settings_progress(&step, total, "Starting Gravity Lite icon physics");
                        log_user("[GRAVITY] Preparing icon physics state...\n");
                        __sync_lock_test_and_set(&g_gravitylite_background_armed, 0);
                        settings_stop_gravity_motion();
                        gravitylite_stop_in_session();
                        GravityLiteConfig glConfig = settings_gravitylite_config_from_defaults(d);
                        bool ok = gravitylite_apply_in_session(glConfig);
                        settings_mark_tweak_applied(kSettingsGravityLiteEnabled,
                                                    ok && [d boolForKey:kSettingsGravityLiteEnabled]);
                        if (ok) {
                            log_user("[GRAVITY] Starting tilt sensor feed...\n");
                            settings_start_gravity_motion(glConfig.magnitude,
                                                          glConfig.explosionForce);
                        }
                        if (ok) {
                            log_user("[OK] Gravity Lite active.\n");
                            cyanide_upload_log_milestone(@"gravity-lite-applied");
                        } else {
                            log_user("[WARN] Gravity Lite did not start cleanly.\n");
                            cyanide_upload_log_milestone(@"gravity-lite-warning");
                            runHadBlockingFailure = YES;
                            runCompletionMessage = @"Gravity Lite did not start cleanly.";
                        }
                    } else if (!gravityLiteEnabled) {
                        __sync_lock_test_and_set(&g_gravitylite_background_armed, 0);
                        settings_stop_gravity_motion();
                        gravitylite_stop_in_session();
                    }

                    if (runStatBar) {
                        settings_progress(&step, total, "Starting StatBar overlay and live feed");
                        bool ok = statbar_apply_in_session([d boolForKey:kSettingsStatBarCelsius],
                                                           [d boolForKey:kSettingsStatBarShowNet],
                                                           [d boolForKey:kSettingsStatBarShowCPU],
                                                           [d boolForKey:kSettingsStatBarShowLabels],
                                                           [d boolForKey:kSettingsStatBarNetworkOnly]);
                        settings_mark_tweak_applied(kSettingsStatBarEnabled,
                                                    ok && [d boolForKey:kSettingsStatBarEnabled]);
                        log_user("%s StatBar %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "showing thermal + memory overlay" : "did not start cleanly");
                        cyanide_upload_log_milestone(ok ? @"statbar-initial-applied" : @"statbar-initial-failed");
                        if (!ok) [runWarnings addObject:@"StatBar"];
                    }

                    if (runNSBar) {
                        settings_progress(&step, total, "Starting NSBar network speed overlay");
                        bool ok = nsbar_apply_in_session((NSBarPosition)[d integerForKey:kSettingsNSBarPosition]);
                        settings_mark_tweak_applied(kSettingsNSBarEnabled,
                                                    ok && [d boolForKey:kSettingsNSBarEnabled]);
                        printf("[SETTINGS] NSBar result=%d\n", ok);
                        log_user("%s NSBar %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "showing network speed" : "did not start cleanly");
                        cyanide_upload_log_milestone(ok ? @"nsbar-initial-applied" : @"nsbar-initial-failed");
                        if (!ok) [runWarnings addObject:@"NSBar"];
                    }

                    if (runNiceBarLite) {
                        settings_progress(&step, total, "Starting NiceBar Lite labels");
                        settings_nicebar_refresh_weather_if_needed(!settings_nicebar_has_resolved_weather(d), nil);
                        bool ok = settings_apply_nicebarlite_from_defaults_locked(d);
                        settings_mark_tweak_applied(kSettingsNiceBarLiteEnabled,
                                                    ok && [d boolForKey:kSettingsNiceBarLiteEnabled]);
                        printf("[SETTINGS] NiceBar Lite result=%d\n", ok);
                        log_user("%s NiceBar Lite %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "labels active" : "did not start cleanly");
                        cyanide_upload_log_milestone(ok ? @"nicebar-lite-initial-applied" : @"nicebar-lite-initial-failed");
                        if (!ok) [runWarnings addObject:@"NiceBar Lite"];
                    }


                    if (runLiveWP) {
                        settings_progress(&step, total, "Starting LiveWP video wallpaper");
                        bool ok = livewp_apply_in_session();
                        settings_mark_tweak_applied(kSettingsLiveWPEnabled,
                                                    ok && [d boolForKey:kSettingsLiveWPEnabled]);
                        printf("[SETTINGS] LiveWP result=%d\n", ok);
                        log_user("%s LiveWP %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "video wallpaper active" : "did not start cleanly");
                        cyanide_upload_log_milestone(ok ? @"livewp-initial-applied" : @"livewp-initial-failed");
                        if (!ok) [runWarnings addObject:@"LiveWP"];
                    }

                    if (runQuickLoader) {
                        settings_progress(&step, total, "Applying QuickLoader...");
                        bool ok = quickloader_apply_in_session();
                        settings_mark_tweak_applied(kSettingsQuickLoaderEnabled, ok);
                        if (!ok) [runWarnings addObject:@"QuickLoader"];
                    }

                    if (runRepoTweaks) {
                        settings_progress(&step, total, "Applying RepoTweaks...");
                        bool ok = repotweaks_apply_in_session();
                        settings_mark_tweak_applied(kSettingsRepoTweaksEnabled, ok);
                        if (!ok) [runWarnings addObject:@"RepoTweaks"];
                    }


                    if (runAxonLite) {
                        settings_progress(&step, total, "Starting Axon Lite notification hub");
                        bool ok = false;
                        bool deferred = false;
                        if (settings_axonlite_can_poll_springboard()) {
                            ok = axonlite_apply_in_session();
                            deferred = !ok && !axonlite_initial_cache_ready();
                        } else {
                            deferred = true;
                            printf("[SETTINGS] Axon Lite initial apply skipped: %s\n",
                                   settings_axonlite_pause_reason());
                        }
                        settings_mark_tweak_applied(kSettingsAxonLiteEnabled,
                                                    (ok || deferred) && [d boolForKey:kSettingsAxonLiteEnabled]);
                        printf("[SETTINGS] Axon Lite result=%d deferred=%d\n", ok, deferred);
                        log_user("%s Axon Lite %s.\n",
                                 (ok || deferred) ? "[OK]" : "[WARN]",
                                 ok ? "hub active — watching for notifications" :
                                 (deferred ? "standing by — fires when notifications appear" : "did not start cleanly"));
                        cyanide_upload_log_milestone(ok ? @"axon-lite-initial-applied" :
                                                     (deferred ? @"axon-lite-initial-deferred" : @"axon-lite-initial-failed"));
                        if (!ok && !deferred) [runWarnings addObject:@"Axon Lite"];
                    }


                    if (runAppSwitcherGrid) {
                        settings_progress(&step, total, "Enabling App Switcher Grid");
                        bool ok = appswitchergrid_apply_in_session();
                        settings_mark_tweak_applied(kSettingsAppSwitcherGridEnabled,
                                                    ok && [d boolForKey:kSettingsAppSwitcherGridEnabled]);
                        printf("[SETTINGS] App Switcher Grid result=%d\n", ok);
                        log_user("%s App Switcher Grid %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "enabled" : "did not apply cleanly");
                        cyanide_upload_log_milestone(ok ? @"app-switcher-grid-applied" : @"app-switcher-grid-failed");
                        if (!ok) [runWarnings addObject:@"App Switcher Grid"];
                    } else if (!appSwitcherGridEnabled) {
                        appswitchergrid_stop_in_session();
                    }

                    if (runFastLockXLite) {
                        settings_progress(&step, total, "Enabling FastLockX Lite Always On");
                        FastLockXLiteConfig config = settings_fastlockx_lite_config_from_defaults(d, YES, YES);
                        config.diagnosticLogging = NO;
                        bool ok = fastlockx_lite_enable_always_on_in_session(config);
                        if (ok) {
                            (void)settings_refresh_screen_awake_state("fastlockx install");
                            (void)settings_refresh_screen_lock_state("fastlockx install");
                            BOOL active = !settings_screen_awake_cached() && settings_screen_locked_cached();
                            bool syncOK = fastlockx_lite_set_always_on_active_in_session(active);
                            __sync_lock_test_and_set(&g_fastlockx_lite_remote_active_state,
                                                     syncOK ? (active ? 1 : 0) : -1);
                            __sync_lock_test_and_set(&g_fastlockx_lite_last_unlock_nudge_ms, 0);
                            printf("[SETTINGS] FastLockX initial screen sync active=%d awake=%d locked=%d ok=%d\n",
                                   active,
                                   settings_screen_awake_cached(),
                                   settings_screen_locked_cached(),
                                   syncOK);
                        }
                        settings_mark_tweak_applied(kSettingsFastLockXLiteEnabled,
                                                    ok && [d boolForKey:kSettingsFastLockXLiteEnabled]);
                        printf("[SETTINGS] FastLockX Lite result=%d\n", ok);
                        log_user("%s FastLockX Lite Always On %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "enabled" : "did not install cleanly");
                        cyanide_upload_log_milestone(ok ? @"fastlockx-lite-applied" :
                                                         @"fastlockx-lite-failed");
                        if (!ok) [runWarnings addObject:@"FastLockX Lite"];
                    }

                    if (runStageStrip) {
                        settings_progress(&step, total, "Installing Dynamic Stage Lite");
                        BOOL skipStageDeferredLibrary = settings_fastlockx_lite_install_allowed() &&
                            [d boolForKey:kSettingsFastLockXLiteEnabled];
                        if (skipStageDeferredLibrary) {
                            log_user("[COMPAT] Dynamic Stage Lite will skip background App Library tile fill-in while FastLockX Lite is active.\n");
                        }
                        stagestrip_set_deferred_library_build_enabled(!skipStageDeferredLibrary);
                        bool ok = stagestrip_apply_in_session(4);
                        stagestrip_set_deferred_library_build_enabled(true);
                        startStageStripControlLoopAfterInstall = ok;
                        settings_mark_tweak_applied(kSettingsStageStripEnabled,
                                                    ok && [d boolForKey:kSettingsStageStripEnabled]);
                        printf("[SETTINGS] Dynamic Stage Lite result=%d\n", ok);
                        log_user("%s Dynamic Stage Lite %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "overlay active" : "did not install cleanly");
                        cyanide_upload_log_milestone(ok ? @"stagestrip-initial-applied" : @"stagestrip-initial-failed");
                        if (!ok) [runWarnings addObject:@"Dynamic Stage Lite"];
                    } else if (!stageStripEnabled) {
                        // Uninstall path: tear down the overlay if one survived
                        // from a prior Run. No-op when the strip was never up.
                        stagestrip_stop_in_session();
                    }

                    // Apply the icon grid, Dock contents, and page
                    // redistribution last. Several SpringBoard tweaks above
                    // invalidate or rebuild icon-list models, which would
                    // otherwise discard SBCustomizer's earlier mutations.
                    if (runSBC) {
                        settings_progress(&step, total, "Finalizing Home Screen icon layout");
                        bool ok = settings_apply_sbc_from_defaults_locked(d);
                        settings_mark_tweak_applied(kSettingsSBCEnabled,
                                                    ok && [d boolForKey:kSettingsSBCEnabled]);
                        log_user("%s Home screen layout %s; dock=%ld home=%ldx%ld.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "applied" : "may need a refresh",
                                 (long)[d integerForKey:kSettingsSBCDockIcons],
                                 (long)[d integerForKey:kSettingsSBCCols],
                                 (long)[d integerForKey:kSettingsSBCRows]);
                        cyanide_upload_log_milestone(ok ? @"sbc-applied" : @"sbc-warning");
                        if (!ok) [runWarnings addObject:@"Home screen layout"];
                    }

                    // Layout Extras derives spacing and icon frames from the
                    // final grid and Dock contents, so it must run after
                    // SBCustomizer has finished moving icons.
                    if (runLayoutExtras) {
                        settings_progress(&step, total, "Applying Home Layout Extras to final icon layout");
                        // HSSCALE first waits ~5s behind SpringBoard's grid relayout
                        // (elapsed-time heartbeat), then reports page by page.
                        NSTimeInterval layoutStart = [NSDate timeIntervalSinceReferenceDate];
                        uint64_t layoutTrips = r_perf_round_trips();
                        settings_apply_heartbeat_start(@"Waiting for SpringBoard to lay out the new grid");
                        darksword_layout_set_progress_handler(^(int pagesDone, int pagesTotal,
                                                                int iconsDone, int iconsTotal) {
                            settings_apply_heartbeat_update(pagesDone == 0
                                ? [NSString stringWithFormat:@"Resizing %d icons on %d pages", iconsTotal, pagesTotal]
                                : [NSString stringWithFormat:@"Resizing icons: page %d of %d (%d of %d)",
                                                             pagesDone, pagesTotal, iconsDone, iconsTotal]);
                        });
                        bool ok = settings_apply_layout_extras_from_defaults_locked(d);
                        darksword_layout_set_progress_handler(nil);
                        settings_apply_heartbeat_stop();
                        log_user("      Home Layout Extras took %.1fs (%llu remote calls).\n",
                                 [NSDate timeIntervalSinceReferenceDate] - layoutStart,
                                 (unsigned long long)(r_perf_round_trips() - layoutTrips));
                        settings_mark_tweak_applied(kSettingsLayoutExtrasEnabled, ok);
                        printf("[SETTINGS] Layout extras result=%d\n", ok);
                        log_user("%s Home Layout Extras %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "applied to final layout" : "did not apply cleanly");
                        cyanide_upload_log_milestone(ok ? @"layout-extras-applied" : @"layout-extras-warning");
                        if (!ok) [runWarnings addObject:@"Home Layout Extras"];
                    }

                    // Hide labels LAST — after HSSCALE's relayout — so our own
                    // relayout can't re-show them. On iOS 17 label visibility is
                    // per-SBIconView and recomputed each layout (issue #7); doing
                    // it here is the only point in the run after the final relayout.
                    if ([d boolForKey:kSettingsSBCEnabled] && [d boolForKey:kSettingsSBCHideLabels]) {
                        // iOS 17: durably hide by repointing -[SBIconView
                        // _shouldShowLabel] at a NO-returning IMP, so every page
                        // (incl. off-screen ones rebuilt on swipe) drops its labels
                        // at build time — no live loop, no keep-alive. Fall back to
                        // the per-view live loop only if the hook can't be installed.
                        // iOS 18+ uses the durable config lever (no swizzle there).
                        BOOL legacyLabels = settings_current_ios_major() < 18;
                        int swizzled = legacyLabels ? sbcustomizer_swizzle_home_labels_hidden() : 0;
                        int nHid = sbcustomizer_hide_home_labels_in_session();
                        log_user("[OK] Hid labels on %d visible icon view(s)%s.\n",
                                 nHid, swizzled ? " (durable across pages)" : "");
                        if (legacyLabels && !swizzled) {
                            // Hook unavailable — keep the old live loop as a fallback.
                            settings_start_labels_live_loop();
                        } else {
                            settings_mark_tweak_applied(kSettingsSBCHideLabels, YES);
                        }
                    } else {
                        g_labels_live_stop_requested = 1;
                        sbcustomizer_restore_home_labels();
                        settings_mark_tweak_applied(kSettingsSBCHideLabels, NO);
                    }

                    // Dock labels run after the home-label step for the same
                    // reason it runs last: the dock's icon views are rebuilt by
                    // the resize and the auto-dock move, so this is the first
                    // point where every view that will exist is there. Applied
                    // in both directions so turning it back off restores the
                    // stock bare dock without needing a respring.
                    if ([d boolForKey:kSettingsSBCEnabled]) {
                        BOOL wantDockLabels = [d boolForKey:kSettingsSBCDockLabels];
                        BOOL hidingLabels = [d boolForKey:kSettingsSBCHideLabels];
                        // Hide icon labels wins, on every version. iOS 17 leaves no
                        // choice -- both settings drive the one _shouldShowLabel
                        // method, which cannot answer NO and YES at once. iOS 18 could
                        // do both, since root and dock are separate icon locations with
                        // their own layout configurations, but a bare home screen next
                        // to a labelled dock is not a combination anyone asks for, and
                        // one rule beats two behaviours to explain. So the dock follows
                        // the home screen either way.
                        //
                        // Note this applies the OFF state rather than just skipping:
                        // on iOS 18 a previous run's dock labels live in the dock's
                        // layout configuration, so they have to be actively cleared or
                        // they would survive turning Hide icon labels on.
                        BOOL showDock = wantDockLabels && !hidingLabels;
                        int nDock = sbcustomizer_set_dock_labels_in_session(showDock, !hidingLabels);
                        if (wantDockLabels && hidingLabels) {
                            log_user("[RUN] Dock labels skipped: Hide icon labels is on, and the "
                                     "dock follows it.\n");
                        } else if (wantDockLabels) {
                            log_user("[OK] Dock labels shown on %d icon view(s).\n", nDock);
                        } else if (!hidingLabels) {
                            // Turning dock labels off: drop the forced-YES hook if we
                            // are the ones holding it, so the dock goes back to stock.
                            sbcustomizer_restore_home_labels();
                        }
                        settings_mark_tweak_applied(kSettingsSBCDockLabels, wantDockLabels);
                    }
                }

                if (runStatBar) {
                    settings_start_statbar_live_loop();
                } else if (!statBarEnabled) {
                    g_statbar_live_stop_requested = 1;
                }
                if (runNSBar) {
                    settings_start_nsbar_live_loop();
                } else if (!nsBarEnabled) {
                    g_nsbar_live_stop_requested = 1;
                }
                if (runNiceBarLite) {
                    settings_start_nicebarlite_live_loop();
                } else if (!niceBarLiteEnabled) {
                    g_nicebarlite_live_stop_requested = 1;
                }
                if (runLiveWP) {
                    settings_start_livewp_live_loop();
                } else if (!liveWPEnabled) {
                    g_livewp_live_stop_requested = 1;
                }
                if (runAxonLite) {
                    settings_start_axonlite_live_loop();
                } else if (!axonLiteEnabled) {
                    g_axonlite_live_stop_requested = 1;
                }
            }

            if (startStageStripControlLoopAfterInstall) {
                stagestrip_start_control_loop();
            }
            if (runStatBar || runNSBar || runNiceBarLite || runAxonLite || runLiveWP || startStageStripControlLoopAfterInstall)
                cyanide_upload_log_milestone(@"live-tweaks-started");

            if (!settings_has_persistent_springboard_remote_call_user()) {
                BOOL closedNonLiveRemoteCall = NO;
                settings_stage_open("SpringBoard channel teardown");
                @synchronized (settings_rc_lock()) {
                    if (!settings_has_persistent_springboard_remote_call_user() &&
                        g_springboard_rc_ready) {
                        // Closing the synthetic-call channel does not undo
                        // one-shot SpringBoard patches like SBCustomizer's
                        // icon-label/layout changes. Keep the applied marker
                        // so Installer doesn't immediately re-queue a package
                        // that just finished successfully; SpringBoard restart,
                        // manual cleanup, and respring cleanup still clear it.
                        settings_destroy_springboard_remote_call_locked_internal_ex("non-live run complete",
                                                                                   YES,
                                                                                   YES);
                        closedNonLiveRemoteCall = YES;
                    }
                }
                if (closedNonLiveRemoteCall) {
                    kadjust32_report("SpringBoard session");
                    log_user("[OK] SpringBoard channel released — no persistent hooks.\n");
                    cyanide_upload_log_milestone(@"springboard-remote-call-closed");
                }
            }

            if (runHadBlockingFailure) {
                log_user("[RUN] Incomplete: a requested live tweak did not become active.\n");
                cyanide_upload_log_milestone(@"run-incomplete");
                return;
            }

            if (runWarnings.count) {
                log_user("[DONE] Finished with warnings — did not apply: %s. They stay "
                         "pending and are retried on the next run.\n",
                         [runWarnings componentsJoinedByString:@", "].UTF8String);
            } else {
                log_user("[DONE] All requested changes finished — active until respring.\n");
            }
            // Synchronous park + verify at session end. The idle parker and
            // the background hook are eventually-consistent; the post-success
            // panics fire while the device sits idle minutes after this line.
            // Harmless if live tweaks keep running -- their next KRW access
            // re-arms the primitive, and the idle parker re-parks after quiet.
            kexploit_krw_session_end_park();
            runSucceeded = YES;
            if (runWarnings.count) {
                runPartial = YES;
                runCompletionMessage = [NSString stringWithFormat:@"Finished with warnings. Did not apply: %@.",
                                        [runWarnings componentsJoinedByString:@", "]];
                cyanide_upload_log_milestone(@"run-complete-warnings");
            } else {
                runCompletionMessage = @"Done. All requested changes finished.";
                cyanide_upload_log_milestone(@"run-complete");
            }
        } @finally {
            settings_stage_close();
            settings_log_perf_delta("Whole run", runStartNs, &runPerf0);
            // Close any legacy uploader state before the final snapshot.
            cyanide_stop_session_uploads();
            // Flush, but keep the file open so post-[DONE] background output
            // (idle parking, live-tweak loops) still lands in the shareable log.
            // The next run's log_session_begin() rotates the file.
            log_session_flush();
            __sync_lock_release(&g_settings_actions_running);
            settings_reconcile_applied_from_defaults();
            // Auto-retry: a clean KRW-acquire miss is fully re-entrant in the
            // same boot, so instead of reporting failure, re-enter the chain
            // until it lands or the attempt cap is hit. No completion posts
            // meanwhile, so the progress screen simply keeps spinning. Never
            // retries a wedged injection (re-running there hangs again) and
            // never swallows a queued follow-up run.
            NSUserDefaults *retryDefaults = [NSUserDefaults standardUserDefaults];
            NSInteger maxRetryAttempts = [retryDefaults integerForKey:kSettingsRunAutoRetryMaxAttempts];
            if (maxRetryAttempts < 1) maxRetryAttempts = 1;
            if (!runSucceeded &&
                [runCompletionMessage isEqualToString:kSettingsRunKRWFailedMessage] &&
                [retryDefaults boolForKey:kSettingsRunAutoRetry] &&
                !remote_call_init_wedged() &&
                g_settings_actions_rerun_requested == 0 &&
                g_settings_actions_auto_retry_attempt < maxRetryAttempts) {
                int attempt = __sync_add_and_fetch(&g_settings_actions_auto_retry_attempt, 1);
                log_user("[RUN] Auto-retrying chain (attempt %d of %ld)…\n",
                         attempt, (long)maxRetryAttempts);
                cyanide_upload_log_milestone(@"krw-auto-retry");
                settings_run_actions_internal(pendingOnly);
                return;
            }
            g_settings_actions_auto_retry_attempt = 0;
            if (__sync_bool_compare_and_swap(&g_settings_actions_rerun_requested, 1, 0)) {
                log_user("[RUN] Applying queued follow-up run.\n");
                settings_run_actions_internal(pendingOnly);
                return;
            }
            // An installer preflight failure (e.g. a repo tweak whose script
            // download failed) rides along into this completion, so the
            // progress screen can't show "Done" for a failed install.
            NSString *preflightFailure = settings_take_run_preflight_failure();
            if (preflightFailure.length) {
                runSucceeded = NO;
                runPartial = YES;
                runCompletionMessage = runCompletionMessage.length
                    ? [NSString stringWithFormat:@"%@ — %@", preflightFailure, runCompletionMessage]
                    : preflightFailure;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                // A new run that started after the release above keeps the
                // hold and restores it when it finishes.
                if (g_settings_actions_idle_held && !g_settings_actions_running) {
                    UIApplication.sharedApplication.idleTimerDisabled = g_settings_actions_idle_was_disabled;
                    g_settings_actions_idle_held = NO;
                }
                NSDictionary *completionInfo = @{
                    kSettingsActionsDidCompleteSuccessKey: @(runSucceeded),
                    kSettingsActionsDidCompletePartialKey: @(runPartial),
                    kSettingsActionsDidCompleteMessageKey: runCompletionMessage ?: @""
                };
                [[NSNotificationCenter defaultCenter] postNotificationName:PackageQueueDidChangeNotification
                                                                    object:[PackageQueue sharedQueue]];
                [[NSNotificationCenter defaultCenter] postNotificationName:kSettingsActionsDidCompleteNotification
                                                                    object:nil
                                                                  userInfo:completionInfo];
                cyanide_upload_log_if_enabled();
            });
        }
    });
}

void settings_run_actions(void)
{
    g_settings_actions_auto_retry_attempt = 0;
    settings_run_actions_internal(NO);
}

void settings_run_pending_actions(void)
{
    g_settings_actions_auto_retry_attempt = 0;
    settings_run_actions_internal(YES);
}

void settings_rerun_last_actions(void)
{
    g_settings_actions_auto_retry_attempt = 0;
    settings_run_actions_internal(g_settings_actions_last_pending_only);
}

// SettingsSection enum moved to SettingsViewController.h so the package catalog
// can reference the same values by name (see the note there).

typedef NS_ENUM(NSInteger, RootSection) {
    RootSectionChangelog = 0,
    RootSectionActions,
    RootSectionTweakBundles,
    RootSectionInDev,
    RootSectionSystemBundles,
    RootSectionAbout,
    RootSectionWarning,
    RootSectionCount,
};

// Loads Cyanide/Changelog.plist (generated at build time by
// scripts/gen-changelog.sh from the last N release tags). Each entry is a
// dict with keys "version" (NSString), "date" (ISO yyyy-MM-dd NSString), and
// "changes" (NSArray<NSString *>). Empty array when the plist is missing or
// malformed — the "What's New" section silently hides itself in that case.
static NSArray<NSDictionary *> *settings_changelog_entries(void)
{
    static NSArray<NSDictionary *> *entries = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"Changelog" ofType:@"plist"];
        NSArray *raw = path ? [NSArray arrayWithContentsOfFile:path] : nil;
        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
        for (id obj in raw) {
            if (![obj isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *d = (NSDictionary *)obj;
            NSString *version = d[@"version"];
            NSArray *changes = d[@"changes"];
            if (![version isKindOfClass:[NSString class]] || version.length == 0) continue;
            if (![changes isKindOfClass:[NSArray class]] || changes.count == 0) continue;
            [out addObject:d];
        }
        entries = [out copy];
    });
    return entries;
}

// "2026-05-15" -> "May 15". Falls back to the raw string on parse failure.
static NSString *settings_pretty_date_for_iso(NSString *iso)
{
    if (!iso.length) return @"";
    static NSDateFormatter *in = nil;
    static NSDateFormatter *out = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        in  = [[NSDateFormatter alloc] init];
        in.dateFormat = @"yyyy-MM-dd";
        in.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        out = [[NSDateFormatter alloc] init];
        out.dateFormat = @"MMM d";
        out.locale = [NSLocale currentLocale];
    });
    NSDate *date = [in dateFromString:iso];
    return date ? [out stringFromDate:date] : iso;
}

@interface SettingsViewController () <UIDocumentPickerDelegate, PHPickerViewControllerDelegate>
@property (nonatomic, strong) UISegmentedControl *powercuffSegmented;
@property (nonatomic, assign) BOOL pendingManualActionsReload;
@property (nonatomic, assign) BOOL detailMode;
@property (nonatomic, assign) NSInteger underlyingSection;
@property (nonatomic, copy)   NSString *bundleTitle;
@property (nonatomic, assign) BOOL changelogExpanded;
// Set by returnToInstaller; consumed in viewDidDisappear. See both.
@property (nonatomic, assign) BOOL unwindSettingsStackWhenHidden;
@property (nonatomic, copy)   NSString *pendingPasscodeDigit;
- (void)handlePasscodeBackupImport:(NSArray<NSURL *> *)urls;
- (void)handlePasscodeBackupRowLongPress:(UILongPressGestureRecognizer *)recognizer;
- (void)presentPasscodeBackupDeletion;
- (NSString *)passcodeDeletionMessageForBackups:(NSUInteger)backups digits:(NSUInteger)digits remaining:(NSInteger)remaining;
- (void)deletePasscodeBackupsConfirmed;
@property (nonatomic, assign) BOOL qlStandalone;
@property (nonatomic, strong) NSString *qlScriptName;
@property (nonatomic, strong) NSString *qlRawScript;
@property (nonatomic, strong) NSMutableDictionary *qlValues;
@property (nonatomic, strong) NSArray *qlParams;
@end

// Keypad mock for the Passcode Style panel: draws the 3x4 Lock Screen gesture
// grid with each digit's selected art, falling back to the plain digit, and
// reports taps so the panel can open the photo picker for that key.
@interface CYPasscodeKeypadPreviewView : UIView
@property (nonatomic, copy) NSDictionary<NSString *, NSData *> *digitArt;
@property (nonatomic, copy) void (^onDigitTapped)(NSString *digit);
@end

@interface CYPasscodeKeypadPreviewView ()
// Decoded once per data change; drawing runs on every redraw, so decoding here
// keeps scrolling from re-parsing the PNGs.
@property (nonatomic, copy) NSDictionary<NSString *, UIImage *> *digitImages;
@end

// Grid geometry, shared by drawing and hit testing.
typedef struct {
    CGRect  card;
    CGFloat cell;
    CGFloat spacing;
    CGPoint origin;
} CYPasscodeKeypadMetrics;

static CYPasscodeKeypadMetrics CYPasscodeKeypadMetricsForBounds(CGRect bounds)
{
    static const CGFloat padding = 12.0;
    static const CGFloat spacing = 10.0;
    static const CGFloat verticalInset = 6.0;

    CYPasscodeKeypadMetrics metrics;
    metrics.spacing = spacing;
    metrics.cell = MIN((CGRectGetWidth(bounds) - padding * 2.0 - spacing * 2.0) / 3.0,
                       (CGRectGetHeight(bounds) - verticalInset * 2.0 - padding * 2.0 - spacing * 3.0) / 4.0);

    if (metrics.cell < 1.0) {
        metrics.cell = 0.0;
        metrics.card = CGRectZero;
        metrics.origin = CGPointZero;
        return metrics;
    }

    CGSize grid = CGSizeMake(metrics.cell * 3.0 + spacing * 2.0,
                             metrics.cell * 4.0 + spacing * 3.0);
    // The card hugs the grid instead of filling the row, so the keys keep a
    // tight, deliberate frame at any width.
    metrics.card = CGRectMake(CGRectGetMidX(bounds) - (grid.width + padding * 2.0) / 2.0,
                              CGRectGetMidY(bounds) - (grid.height + padding * 2.0) / 2.0,
                              grid.width + padding * 2.0,
                              grid.height + padding * 2.0);
    metrics.origin = CGPointMake(CGRectGetMidX(metrics.card) - grid.width / 2.0,
                                 CGRectGetMidY(metrics.card) - grid.height / 2.0);
    return metrics;
}

// 1-9 then 0 in the middle of the last row; the empty corners stay blank,
// exactly like the Lock Screen keypad.
static NSInteger CYPasscodeKeypadDigitAtIndex(NSInteger index)
{
    static const NSInteger kLayout[12] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, -1, 0, -1 };
    if (index < 0 || index > 11) return -1;
    return kLayout[index];
}

static CGRect CYPasscodeKeypadFrame(NSInteger index, CYPasscodeKeypadMetrics metrics)
{
    return CGRectMake(metrics.origin.x + (index % 3) * (metrics.cell + metrics.spacing),
                      metrics.origin.y + (index / 3) * (metrics.cell + metrics.spacing),
                      metrics.cell, metrics.cell);
}

static UIFont *CYPasscodeKeypadDigitFont(CGFloat size)
{
    UIFont *base = [UIFont systemFontOfSize:size weight:UIFontWeightMedium];
    UIFontDescriptor *rounded = [base.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return rounded ? [UIFont fontWithDescriptor:rounded size:size] : base;
}

@implementation CYPasscodeKeypadPreviewView

- (void)setDigitArt:(NSDictionary<NSString *, NSData *> *)digitArt
{
    _digitArt = [digitArt copy];

    NSMutableDictionary<NSString *, UIImage *> *images = [NSMutableDictionary dictionary];
    for (NSString *key in digitArt) {
        NSData *data = digitArt[key];
        if (data.length == 0) continue;
        UIImage *image = [UIImage imageWithData:data];
        if (image) images[key] = image;
    }
    _digitImages = [images copy];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect
{
    (void)rect;

    CYPasscodeKeypadMetrics metrics = CYPasscodeKeypadMetricsForBounds(self.bounds);
    if (metrics.cell <= 0.0) return;

    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;

    // Neutral system styling: the card only groups the keys, so the preview sits
    // inside the settings list instead of shouting over it. Every colour here
    // follows light and dark mode on its own.
    UIBezierPath *card = [UIBezierPath bezierPathWithRoundedRect:metrics.card cornerRadius:20.0];
    [[UIColor tertiarySystemGroupedBackgroundColor] setFill];
    [card fill];

    NSDictionary *attributes = @{
        NSFontAttributeName: CYPasscodeKeypadDigitFont(metrics.cell * 0.40),
        NSForegroundColorAttributeName: UIColor.labelColor,
    };

    for (NSInteger index = 0; index < 12; index++) {
        NSInteger digit = CYPasscodeKeypadDigitAtIndex(index);
        if (digit < 0) continue;

        CGRect frame = CYPasscodeKeypadFrame(index, metrics);
        UIBezierPath *shape = [UIBezierPath bezierPathWithOvalInRect:frame];
        [[UIColor secondarySystemGroupedBackgroundColor] setFill];
        [shape fill];
        // One neutral hairline for every key. The digit art itself already marks a
        // customised key, so no accent colour belongs here.
        [[UIColor separatorColor] setStroke];
        shape.lineWidth = 1.0;
        [shape stroke];

        NSString *key = [NSString stringWithFormat:@"%ld", (long)digit];
        UIImage *image = self.digitImages[key];

        if (image && image.size.width > 0.0 && image.size.height > 0.0) {
            // Aspect-fit inside the key circle, like the upstream implementation's
            // scaledToFit.
            CGFloat scale = MIN(CGRectGetWidth(frame) / image.size.width,
                                CGRectGetHeight(frame) / image.size.height);
            CGSize drawSize = CGSizeMake(image.size.width * scale, image.size.height * scale);

            CGContextSaveGState(context);
            [shape addClip];
            [image drawInRect:CGRectMake(CGRectGetMidX(frame) - drawSize.width / 2.0,
                                         CGRectGetMidY(frame) - drawSize.height / 2.0,
                                         drawSize.width, drawSize.height)];
            CGContextRestoreGState(context);
        } else {
            CGSize size = [key sizeWithAttributes:attributes];
            [key drawAtPoint:CGPointMake(CGRectGetMidX(frame) - size.width / 2.0,
                                         CGRectGetMidY(frame) - size.height / 2.0)
              withAttributes:attributes];
        }
    }
}

- (NSString *)digitAtPoint:(CGPoint)point
{
    CYPasscodeKeypadMetrics metrics = CYPasscodeKeypadMetricsForBounds(self.bounds);
    if (metrics.cell <= 0.0) return nil;

    for (NSInteger index = 0; index < 12; index++) {
        NSInteger digit = CYPasscodeKeypadDigitAtIndex(index);
        if (digit < 0) continue;

        // A slightly padded target keeps the small keys easy to hit.
        CGRect target = CGRectInset(CYPasscodeKeypadFrame(index, metrics), -4.0, -4.0);
        if (CGRectContainsPoint(target, point)) {
            return [NSString stringWithFormat:@"%ld", (long)digit];
        }
    }
    return nil;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)event;
    UITouch *touch = touches.anyObject;
    if (!touch) return;

    NSString *digit = [self digitAtPoint:[touch locationInView:self]];
    if (digit.length == 0) return;
    if (self.onDigitTapped) self.onDigitTapped(digit);
}

@end

// Singleton delegate so MFMailCompose's host VC doesn't need to conform. Lives
// for the app's lifetime — a single instance handles every dismissal across
// every entry point (Settings → Contact, Installer → Contact button, etc.).
@interface _CyanideMailDelegate : NSObject <MFMailComposeViewControllerDelegate>
@end
@implementation _CyanideMailDelegate
- (void)mailComposeController:(MFMailComposeViewController *)c
          didFinishWithResult:(MFMailComposeResult)r error:(NSError *)e
{
    (void)r; (void)e;
    [c dismissViewControllerAnimated:YES completion:nil];
}
@end
static _CyanideMailDelegate *_cyanide_mail_delegate(void) {
    static _CyanideMailDelegate *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [[_CyanideMailDelegate alloc] init]; });
    return d;
}

#pragma mark - Process Manager

typedef NS_ENUM(NSInteger, PMSortKey) { PMSortPID = 0, PMSortCPU, PMSortMem, PMSortName };

// Columned row: name + PID on the left, CPU% and memory right-aligned so they line
// up and read as sortable columns.
@interface PMProcCell : UITableViewCell
@property (nonatomic, strong) UILabel *nameL, *pidL, *cpuL, *memL;
@end

@implementation PMProcCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid
{
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    if (self) {
        _nameL = [UILabel new]; _nameL.font = [UIFont systemFontOfSize:15];
        _pidL  = [UILabel new]; _pidL.font  = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        _pidL.textColor = [UIColor secondaryLabelColor];
        _cpuL  = [UILabel new]; _cpuL.font  = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        _cpuL.textAlignment = NSTextAlignmentRight;
        _memL  = [UILabel new]; _memL.font  = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        _memL.textAlignment = NSTextAlignmentRight; _memL.textColor = [UIColor secondaryLabelColor];
        for (UILabel *l in @[_nameL, _pidL, _cpuL, _memL]) [self.contentView addSubview:l];
    }
    return self;
}
- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat W = self.contentView.bounds.size.width, H = self.contentView.bounds.size.height;
    CGFloat pad = 16, memW = 82, cpuW = 58, gap = 10;
    CGFloat memX = W - pad - memW, cpuX = memX - gap - cpuW;
    _memL.frame = CGRectMake(memX, 0, memW, H);
    _cpuL.frame = CGRectMake(cpuX, 0, cpuW, H);
    CGFloat nameW = cpuX - gap - pad;
    _nameL.frame = CGRectMake(pad, 5,  nameW, 19);
    _pidL.frame  = CGRectMake(pad, 25, nameW, 13);
}
@end

// A live process viewer: lists every process by walking the kernel proc list via
// KRW, reads CPU/memory read-only from kernel structs (self-calibrated), sorts by
// any column, and can force-quit. Needs kernel r/w armed — a Run this session.
@interface ProcessManagerViewController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<NSDictionary *> *allProcs;   // full snapshot
@property (nonatomic, strong) NSArray<NSDictionary *> *procs;      // filtered / shown
@property (nonatomic, copy)   NSString *filter;
@property (nonatomic, assign) BOOL krwReady;
@property (nonatomic, assign) BOOL arming;
// Round 8: routine foreground restore in flight (KRW detached, anchored in
// launchd). Separate from arming so the viewer keeps its rows and the neutral
// "Restoring kernel access…" prompt — "Arming kernel access…" is reserved for
// an actual user-facing arm/exploit run.
@property (nonatomic, assign) BOOL silentRestoring;
@property (nonatomic, assign) BOOL statsAvailable;
@property (nonatomic, assign) PMSortKey sortKey;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *prevCpu;  // pid -> cumulative cpu ns
// pid -> CLOCK_MONOTONIC_RAW ns when that pid's prevCpu reading was taken.
// %CPU divides each process's CPU delta by the time between ITS two readings,
// not by one interval for the whole pass: rows are read at different moments,
// and queue delays / calibration retries / a slower walk used to skew it (a
// fully busy process could show 200% when its read came 2 s later than in
// the previous pass).
@property (nonatomic, strong) NSDictionary<NSNumber *, NSNumber *> *prevCpuTime;
@property (nonatomic, assign) uint64_t prevWall;                                     // ns
@property (nonatomic, strong) UISearchController *searchCtrl;
@property (nonatomic, strong) NSTimer *autoRefreshTimer;
// Summary header (system memory / overall CPU / chip) above the list.
@property (nonatomic, strong) UILabel *pmHdrChip;
// Consecutive refresh passes whose process-list walk came back incomplete
// (a kernel read failed, here or elsewhere in the app). The list keeps its
// previous snapshot; from 2 in a row on, the prompt says it isn't updating.
@property (nonatomic, assign) NSUInteger pmIncompletePasses;
@property (nonatomic, strong) UILabel *pmHdrMem;
@property (nonatomic, strong) UILabel *pmHdrCpu;
@property (nonatomic, assign) uint64_t prevCpuBusyTicks;
@property (nonatomic, assign) uint64_t prevCpuTotalTicks;
@property (nonatomic, assign) BOOL havePrevCpuTicks;
// Pids with a kill in flight — rows are dimmed and non-selectable until the
// single-pid verify removes the row (or the failure path un-marks it).
@property (nonatomic, strong) NSMutableSet<NSNumber *> *terminatingPids;
// Round 49→50: the round-46 home-indicator auto-hide was REMOVED. It
// collapsed the large title to the centered inline title on entry/refresh
// (toggling prefersHomeIndicatorAutoHidden forces a nav-bar relayout), and it
// never delivered its stated goal anyway — hiding the indicator does NOT block
// the swipe-home gesture (that needs preferredScreenEdgesDeferringSystemGestures).
// Round 46: kill-in-progress shield — a small non-blocking pill shown from
// Force-Quit tap to verdict so the user keeps Cyanide open while the
// launchd session arms/executes (leaving mid-kill is the same surface).
// Round 47: a UIView pill (spinner + label) hosted inside the table view,
// not floating on the tab bar controller.
@property (nonatomic, strong) UIView *killShield;
// Round 47: pending-kill counter for the shield — two concurrent
// Force-Quits share the one pill, and the first verdict must not hide it
// while the second kill still runs. Main-queue confined (both call sites
// are main-queue blocks).
@property (nonatomic, assign) NSInteger killShieldPending;
// One refresh pass at a time. The timer, viewWillAppear, search keystrokes,
// pull-to-refresh, the refresh button and foreground return all call
// reloadProcs; overlapping passes doubled the KRW load, could land out of
// order (an older snapshot overwriting a newer one) and computed %CPU against
// the same baseline twice. A request that arrives mid-pass is coalesced into
// one follow-up pass. Main-queue confined.
@property (nonatomic, assign) BOOL reloadInFlight;
@property (nonatomic, assign) BOOL reloadPending;
// Force-Quits between tap and verdict. The auto-refresh timer stays stopped
// until the LAST one finishes (the first verdict used to restart it while a
// second kill was still running). Main-queue confined.
@property (nonatomic, assign) NSInteger killsInFlight;
@property (nonatomic, assign) uint64_t lastSearchReloadNs;
// CPU source of the previous pass (task totals + live threads vs live-only).
// When it changes, the old per-pid baselines are in a different basis and
// would produce a one-refresh spike — drop them for that pass.
@property (nonatomic, assign) BOOL prevCpuFullTotals;
// On screen (viewWillAppear..viewWillDisappear). The auto-refresh timer only
// runs while visible: a kill verdict landing after the user left used to
// restart it, and the (target-retaining) timer kept the hidden viewer alive
// and scanning KRW until the app next backgrounded. Main-queue confined.
@property (nonatomic, assign) BOOL pmVisible;
// Rows dropped after a confirmed kill, keyed pid -> removal epoch. A refresh
// pass that STARTED before a removal can still have read that pid; its
// snapshot must not resurrect the row. A pass started after the removal is
// authoritative (the pid may legitimately be reused). Main-queue confined.
@property (nonatomic, assign) NSUInteger pmRemovalEpoch;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *pmRemovedPids;
@end

static NSString * const kProcMgrAutoRefreshSecondsKey = @"procmgrAutoRefreshSeconds";

@implementation ProcessManagerViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Process Viewer";
    self.allProcs = @[];
    self.procs = @[];
    self.filter = @"";
    self.prevCpu = [NSMutableDictionary dictionary];
    self.terminatingPids = [NSMutableSet set];
    self.pmRemovedPids = [NSMutableDictionary dictionary];
    UIBarButtonItem *refreshItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(reloadProcs)];
    UIBarButtonItem *timerItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"timer"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(showAutoRefreshOptions:)];
    self.navigationItem.rightBarButtonItems = @[refreshItem, timerItem];
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reloadProcs)
                  forControlEvents:UIControlEventValueChanged];

    self.searchCtrl = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchCtrl.searchResultsUpdater = self;
    self.searchCtrl.obscuresBackgroundDuringPresentation = NO;
    self.searchCtrl.searchBar.placeholder = @"Filter by name or PID";
    self.navigationItem.searchController = self.searchCtrl;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    // Keep a stable large title; the sort control lives in the header (putting a
    // titleView here fought the large title and made it jump/hide on push).
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;

    // Round 51: reserve the nav-bar prompt line from the FIRST layout. The
    // prompt ("N active · M suspended", or "Arming…/Restoring…") is otherwise
    // first set only after arming/reloadProcs completes, so on entry the bar
    // had no prompt line and then grew one when the count appeared — the whole
    // view pushed down (iOS 17). Seeding a placeholder here fixes the bar height
    // up front; every later prompt change is text-only, same height, no jump.
    self.navigationItem.prompt = @"Scanning processes…";

    [self buildSummaryHeader];
    [self reloadProcs];

    // Suspend the auto-refresh timer while backgrounded. viewWillDisappear does
    // NOT fire when the app merely backgrounds under UIScene, so the timer used
    // to keep firing into a detached KRW session (reloadProcs self-guards, but
    // an in-flight pass started just before backgrounding was the 18:50:56
    // crash). Tie the timer to app-state notifications directly.
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(stopAutoRefreshTimer)
               name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(pm_foregroundRefresh)
               name:UIApplicationWillEnterForegroundNotification object:nil];
}

// Back in the foreground with the viewer on screen: restart the suspended
// auto-refresh timer and take a fresh snapshot (the lazy reattach re-makes the
// fds on the first kernel access).
- (void)pm_foregroundRefresh
{
    if (!self.isViewLoaded || !self.view.window) return;
    [self startAutoRefreshTimerIfNeeded];
    [self reloadProcs];
    // Round 44: no fastkill pre-warm here — arming launchd just because the
    // viewer is visible was the live-45 black-screen trigger; the kill path
    // warms on demand.
}

// --- round 46: kill-in-progress shield ----------------------------------------
// A small floating pill shown from Force-Quit tap to verdict. NON-BLOCKING
// (userInteractionEnabled=NO): the process list stays fully tappable while
// it is up. Hosted by the tab bar controller's view so it floats above the
// whole tab instead of scrolling with the table.

- (void)pmShowKillShield
{
    self.killShieldPending++;   // round 47: one pill, N pending kills
    if (self.killShield) { self.killShield.hidden = NO; return; }
    // Round 48: the pill floats at the TOP of the screen, above the process
    // count. The count is the nav-bar prompt ("N active · M suspended"); the
    // pill is hosted on the tab bar controller's view and pinned to its top
    // safe area — the same spot and host as the existing refresh banner
    // (MainTabBarController showRefreshBanner), so it sits over the top chrome
    // (above the prompt/title), never over the list rows or the tab bar.
    // Round 47 history: round 46 pinned it to the tab bar's BOTTOM (overlapped
    // the tab buttons); round 47 moved it into the table view's top safe area
    // (below the prompt, over the stats header). Overlay with constraints, not
    // inserted into any stack — no layout shift. userInteractionEnabled=NO:
    // the list stays fully tappable.
    UIView *pill = [[UIView alloc] init];
    pill.backgroundColor =
        [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:0.96];
    pill.layer.cornerRadius = 15;
    pill.layer.masksToBounds = YES;
    pill.userInteractionEnabled = NO;
    pill.translatesAutoresizingMaskIntoConstraints = NO;

    UIActivityIndicatorView *spin =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spin.translatesAutoresizingMaskIntoConstraints = NO;
    spin.userInteractionEnabled = NO;
    [spin startAnimating];

    UILabel *l = [[UILabel alloc] init];
    l.text = @"Finishing kill — keep Cyanide open for a second.";
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = UIColor.labelColor;
    l.translatesAutoresizingMaskIntoConstraints = NO;

    [pill addSubview:spin];
    [pill addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [spin.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:10],
        [spin.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
        [l.leadingAnchor constraintEqualToAnchor:spin.trailingAnchor constant:6],
        [l.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-12],
        [l.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
    ]];

    // Host at the very top of the screen — the tab bar controller's view, so
    // the pill floats above the nav-bar prompt (the process count), matching
    // the refresh banner. Fall back to the nav/table view if there is no tab
    // bar controller (defensive; the viewer always has one in practice).
    UIView *host = self.tabBarController.view
                 ?: (self.navigationController.view ?: self.view);
    [host addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
        [pill.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [pill.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor
                                       constant:4],
        [pill.widthAnchor constraintLessThanOrEqualToConstant:420],
        [pill.heightAnchor constraintEqualToConstant:30],
    ]];
    self.killShield = pill;
}

- (void)pmHideKillShield
{
    // Round 47: refcounted — the first verdict of two concurrent kills must
    // not hide the pill while the second kill still runs. Clamp at 0.
    if (self.killShieldPending > 0) self.killShieldPending--;
    if (self.killShieldPending > 0) return;
    [self.killShield removeFromSuperview];
    self.killShield = nil;
}

// Kill-target identity check: the comm read right before signalling must name
// the same process the user tapped. The row name is p_name truncated to
// procmgr_entry_t.name, so compare that many bytes. A mismatch means the pid
// exited and was recycled since the list pass — refuse (fail closed).
static BOOL pm_comm_matches_row(const char *comm, NSString *rowName) {
    const char *expected = rowName.UTF8String;
    if (!comm || !comm[0] || !expected || !expected[0]) return NO;
    return strncmp(comm, expected, sizeof(((procmgr_entry_t *)0)->name) - 1) == 0;
}

// Same process the user tapped? The name alone passes when the same app
// relaunched into a reused pid; the struct proc address from the list walk
// (row "kproc") changes with every new process. rowKproc 0 = unknown (older
// snapshot): the name check alone decides, as before.
static BOOL pm_identity_matches_row(const char *comm, uint64_t kproc,
                                    NSString *rowName, uint64_t rowKproc) {
    if (!pm_comm_matches_row(comm, rowName)) return NO;
    return rowKproc == 0 || kproc == rowKproc;
}

// --- summary header: live system info above the process list -----------------

static NSInteger pm_sysctl_int(const char *name) {
    int v = 0; size_t s = sizeof(v);
    return sysctlbyname(name, &v, &s, NULL, 0) == 0 ? (NSInteger)v : -1;
}

// Map hw.machine IDs to marketing chip names; fallback is the raw string.
static NSString *pm_chip_name(NSString *machine) {
    static NSDictionary<NSString *, NSString *> *chips = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        chips = @{
            @"iPhone16,1": @"A17 Pro", @"iPhone16,2": @"A17 Pro",
            @"iPhone17,1": @"A18 Pro", @"iPhone17,2": @"A18 Pro",
            @"iPhone17,3": @"A18",     @"iPhone17,4": @"A18",
        };
    });
    NSString *c = chips[machine];
    if (c) return c;
    if ([machine hasPrefix:@"iPhone18,"]) return @"A19 family";
    return machine;
}

- (NSString *)chipSummaryString
{
    char machine[64] = {0};
    size_t len = sizeof(machine);
    NSString *m = @"Unknown";
    if (sysctlbyname("hw.machine", machine, &len, NULL, 0) == 0 && machine[0])
        m = [NSString stringWithUTF8String:machine];
    NSString *chip = pm_chip_name(m);

    NSInteger ncpu = pm_sysctl_int("hw.ncpu");
    NSInteger phys = pm_sysctl_int("hw.physicalcpu");
    NSInteger cores = phys > 0 ? phys : ncpu;
    if (cores <= 0) return chip;

    NSInteger nperf = pm_sysctl_int("hw.nperflevels");
    NSInteger pCores = pm_sysctl_int("hw.perflevel0.physicalcpu");
    NSInteger eCores = pm_sysctl_int("hw.perflevel1.physicalcpu");
    if (nperf >= 2 && pCores > 0 && eCores > 0)
        return [NSString stringWithFormat:@"%@ · %ld cores (%ldP+%ldE)",
                chip, (long)cores, (long)pCores, (long)eCores];
    return [NSString stringWithFormat:@"%@ · %ld cores", chip, (long)cores];
}

- (void)buildSummaryHeader
{
    const CGFloat H = 112, pad = 16;
    // Width may still be 0 in viewDidLoad — labels therefore use Auto Layout
    // pinned to the header, and viewDidLayoutSubviews keeps the header's frame
    // matched to the table's real width (tableHeaderView width isn't managed
    // automatically).
    UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, H)];
    UILabel *(^mk)(CGFloat, CGFloat) = ^UILabel *(CGFloat y, CGFloat size) {
        UILabel *l = [UILabel new];
        l.font = [UIFont systemFontOfSize:size];
        l.textColor = [UIColor secondaryLabelColor];
        l.adjustsFontSizeToFitWidth = NO;
        l.translatesAutoresizingMaskIntoConstraints = NO;
        [hdr addSubview:l];
        [NSLayoutConstraint activateConstraints:@[
            [l.leadingAnchor constraintEqualToAnchor:hdr.leadingAnchor constant:pad],
            [l.trailingAnchor constraintEqualToAnchor:hdr.trailingAnchor constant:-pad],
            [l.topAnchor constraintEqualToAnchor:hdr.topAnchor constant:y],
        ]];
        return l;
    };
    self.pmHdrChip = mk(8, 13);
    self.pmHdrMem  = mk(27, 12);
    self.pmHdrCpu  = mk(45, 12);
    self.pmHdrChip.text = [self chipSummaryString];
    self.pmHdrMem.text = @"Memory: —";
    self.pmHdrCpu.text = @"CPU: —";

    // Sort control lives in the header (not a nav titleView, which fought the
    // large title). Always visible above the list.
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"PID", @"CPU", @"Mem", @"Name"]];
    seg.selectedSegmentIndex = self.sortKey;
    seg.translatesAutoresizingMaskIntoConstraints = NO;
    [seg addTarget:self action:@selector(sortChanged:) forControlEvents:UIControlEventValueChanged];
    [hdr addSubview:seg];
    [NSLayoutConstraint activateConstraints:@[
        [seg.leadingAnchor  constraintEqualToAnchor:hdr.leadingAnchor constant:pad],
        [seg.trailingAnchor constraintEqualToAnchor:hdr.trailingAnchor constant:-pad],
        [seg.topAnchor      constraintEqualToAnchor:hdr.topAnchor constant:70],
        [seg.heightAnchor   constraintEqualToConstant:30],
    ]];

    self.tableView.tableHeaderView = hdr;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    // Track the table's actual width (rotation, split view, late layout).
    UIView *hdr = self.tableView.tableHeaderView;
    CGFloat w = self.tableView.bounds.size.width;
    if (hdr && w > 0 && hdr.frame.size.width != w) {
        // Preserve the scroll position across the re-assign. Setting
        // tableHeaderView makes UIKit snap contentOffset to (0,0) — i.e.
        // "scrolled down by the safe-area inset" — which collapses the large
        // title. On the FIRST push the header is built before the table has its
        // real width, so this fires mid-transition and the title lands
        // minimized/centered (and stays), while later entries (width already
        // correct) don't trip it — the jumpy first-open. Re-pin to the top when
        // we were at the top so the large title stays expanded.
        CGFloat topY = -self.tableView.adjustedContentInset.top;
        BOOL atTop = self.tableView.contentOffset.y <= topY + 1.0;
        hdr.frame = CGRectMake(0, 0, w, hdr.frame.size.height);
        self.tableView.tableHeaderView = hdr;   // re-assign to force relayout
        if (atTop && self.tableView.contentOffset.y > topY)
            self.tableView.contentOffset = CGPointMake(0, topY);
    }
}

- (void)updateSummaryHeader
{
    static NSByteCountFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSByteCountFormatter new];
        fmt.countStyle = NSByteCountFormatterCountStyleMemory;
        fmt.includesUnit = YES;
    });

    // Memory: used = total − free (simple definition).
    uint64_t total = [NSProcessInfo processInfo].physicalMemory;
    // mach_host_self() returns a new send right each call; take one per
    // refresh, use it for both statistics and release it below (it leaked
    // twice per refresh).
    mach_port_t host = mach_host_self();
    vm_statistics64_data_t vm;
    mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64,
                          (host_info64_t)&vm, &cnt) == KERN_SUCCESS) {
        uint64_t freeB = (uint64_t)vm.free_count * (uint64_t)vm_page_size;
        uint64_t usedB = total > freeB ? total - freeB : 0;
        self.pmHdrMem.text = [NSString stringWithFormat:@"Memory: %@ used / %@ total (%@ free)",
            [fmt stringFromByteCount:(long long)usedB],
            [fmt stringFromByteCount:(long long)total],
            [fmt stringFromByteCount:(long long)freeB]];
    }

    // Overall CPU: busy fraction delta of cumulative host cpu_ticks.
    host_cpu_load_info_data_t cl;
    cnt = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics64(host, HOST_CPU_LOAD_INFO,
                          (host_info64_t)&cl, &cnt) == KERN_SUCCESS) {
        uint64_t busy = (uint64_t)cl.cpu_ticks[CPU_STATE_USER]
                      + (uint64_t)cl.cpu_ticks[CPU_STATE_SYSTEM]
                      + (uint64_t)cl.cpu_ticks[CPU_STATE_NICE];
        uint64_t all  = busy + (uint64_t)cl.cpu_ticks[CPU_STATE_IDLE];
        if (self.havePrevCpuTicks && all > self.prevCpuTotalTicks) {
            double pct = 100.0 * (double)(busy - self.prevCpuBusyTicks)
                               / (double)(all - self.prevCpuTotalTicks);
            self.pmHdrCpu.text = [NSString stringWithFormat:@"CPU: %.1f%% busy", pct];
        } else {
            self.pmHdrCpu.text = @"CPU: —";
        }
        self.prevCpuBusyTicks = busy;
        self.prevCpuTotalTicks = all;
        self.havePrevCpuTicks = YES;
    }
    mach_port_deallocate(mach_task_self(), host);
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // The queue popup bar is hosted by the tab bar controller, above pushed
    // content — suppress it while this screen is on top.
    UITabBarController *tbc = self.tabBarController;
    if ([tbc isKindOfClass:MainTabBarController.class]) {
        [(MainTabBarController *)tbc setPopupBarSuppressed:YES];
    }
    self.pmVisible = YES;
    [self startAutoRefreshTimerIfNeeded];

    // Auto-arm on open: armKRW tries the parked-primitive restore first (safe,
    // no confirmation) and only asks before running the full exploit.
    if (!self.krwReady && !self.arming) {
        [self armKRW];
    } else if (self.krwReady) {
        // Returning to the viewer (e.g. after opening another app): refresh so
        // newly-launched processes appear instead of showing a stale snapshot.
        // Skip when a pass is already running — on the first open viewDidLoad
        // just started one, and its result is fresh enough.
        if (!self.reloadInFlight) [self reloadProcs];
        // Round 44: no fastkill pre-warm here (live 45 — speculative arming
        // on viewer visibility is the black-screen trigger; kills warm on
        // demand only).
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    UITabBarController *tbc = self.tabBarController;
    if ([tbc isKindOfClass:MainTabBarController.class]) {
        [(MainTabBarController *)tbc setPopupBarSuppressed:NO];
    }
    self.pmVisible = NO;
    [self stopAutoRefreshTimer];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self stopAutoRefreshTimer];
}

#pragma mark Kill / refresh coordination

// A Quit or Force Quit is "in flight" from the moment it is sent until its
// final alive-check has finished, not just until the signal is out: a refresh
// in that window walks a list the kill is changing and could put the row back
// (or contend with the kill for the kernel channel). While any is in flight,
// refreshes (timer, pull-to-refresh, search) are deferred and the timer is
// stopped; when the last one ends, one deferred refresh runs and the timer
// restarts -- only if the viewer is still on screen.
- (void)pmKillBegan
{
    self.killsInFlight++;
    [self stopAutoRefreshTimer];
}

- (void)pmKillEnded
{
    if (self.killsInFlight > 0) self.killsInFlight--;
    if (self.killsInFlight > 0) return;
    [self startAutoRefreshTimerIfNeeded];   // no-op when not visible
    if (self.reloadPending && !self.reloadInFlight && self.pmVisible) {
        self.reloadPending = NO;
        [self reloadProcs];
    }
}

#pragma mark Auto Refresh

- (double)autoRefreshInterval
{
    return [NSUserDefaults.standardUserDefaults doubleForKey:kProcMgrAutoRefreshSecondsKey];
}

- (void)startAutoRefreshTimerIfNeeded
{
    [self stopAutoRefreshTimer];   // never stack timers
    if (self.killsInFlight > 0) return;   // the last kill verdict restarts it
    if (!self.pmVisible) return;          // off screen: viewWillAppear restarts it
    double interval = [self autoRefreshInterval];
    if (interval <= 0) return;
    // Weak: a scheduled target/selector timer retains the viewer.
    __weak typeof(self) weakSelf = self;
    self.autoRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                            repeats:YES
                                                              block:^(NSTimer *t) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.pmVisible) { [t invalidate]; return; }
        [strongSelf reloadProcs];
    }];
}

- (void)stopAutoRefreshTimer
{
    [self.autoRefreshTimer invalidate];
    self.autoRefreshTimer = nil;
}

- (void)showAutoRefreshOptions:(UIBarButtonItem *)sender
{
    NSArray<NSNumber *> *options = @[ @0, @1, @2, @5, @10 ];
    double current = [self autoRefreshInterval];

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Auto Refresh"
                         message:@"How often should the process list refresh itself?"
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSNumber *opt in options) {
        double seconds = opt.doubleValue;
        NSString *title = (seconds <= 0) ? @"Off"
                                         : [NSString stringWithFormat:@"Every %d second%@", (int)seconds,
                                            ((int)seconds == 1) ? @"" : @"s"];
        if (seconds == current) title = [title stringByAppendingString:@" ✓"];
        [ac addAction:[UIAlertAction actionWithTitle:title
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            [NSUserDefaults.standardUserDefaults setDouble:seconds forKey:kProcMgrAutoRefreshSecondsKey];
            [self startAutoRefreshTimerIfNeeded];
        }]];
    }

    // Verbose RemoteCall logging now lives in Settings → Launch Options
    // (it affects exploit + tweak applies too, not just the Process Viewer).

    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    ac.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)sortChanged:(UISegmentedControl *)seg
{
    self.sortKey = (PMSortKey)seg.selectedSegmentIndex;
    [self applyFilter];
}

// Present the "KRW not live" UI. MUST run on the main thread. Split out of
// reloadProcs (round 7) so both the main-thread triage and the background
// block's authoritative re-check can reach it without duplicating logic.
- (void)pm_presentKrwNotReadyUI
{
    // Detached-but-anchored (resting in launchd; reattach flapping or in
    // progress) is NOT "gone": keep the current rows, show a neutral
    // restoring state, and kick the silent restore — never empty the list
    // or flash the arm cell for a transient (the "rearm during usage"
    // complaint). Only genuinely-gone state falls through to the arm UI.
    if (kexploit_krw_sockets_detached() &&
        (krw_persistence_launchd_holds_krw() || krw_persistence_has_saved_recovery())) {
        printf("[PROCMGR] refresh: skipped (KRW detached, anchored in "
               "launchd — restoring)\n");
        self.navigationItem.prompt = @"Restoring kernel access…";
        [self.refreshControl endRefreshing];
        // Round 8: routine restore must NOT flash "Arming kernel access…" —
        // it goes through restoreKRWSilently (no arming state; the neutral
        // prompt above stays). "Arming…" is reserved for an actual exploit.
        if (!self.arming && !self.silentRestoring) [self restoreKRWSilently];
        return;
    }
    self.krwReady = NO;
    self.allProcs = @[];
    self.procs = @[];
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
    // Round 51: keep the prompt line reserved (was nil) so the nav bar never
    // loses/regains a line on the gone→armed transition — that height change
    // is the "view pushed down when the active/suspended row appears" jump.
    self.navigationItem.prompt = @"Kernel access needed";
    [self updateSummaryHeader];
}

- (void)reloadProcs
{
    // Don't poll KRW while the screen is off OR the app is backgrounded. The
    // auto-refresh timer keeps firing in both cases (viewWillDisappear does NOT
    // fire when the app merely backgrounds under UIScene), and each poll's
    // kernel access re-arms the socket in-process. That both prevents the
    // idle-detach from handing it to launchd AND, worse, runs heavy calibration
    // KRW/vm_allocate concurrently with the background detach — a race that left
    // the parked socket dead (setsockopt EINVAL / errno 22) even after a clean
    // hand-off to launchd. Going quiet lets the primitive rest in launchd where
    // it survives, and keeps the poll off the detach's back.
    if (g_app_in_background != 0 || !settings_screen_awake_cached()) {
        [self.refreshControl endRefreshing];
        return;
    }
    // Round 7: NEVER call kexploit_krw_ready() on the main thread. It
    // serializes on krwReattachLock and can itself run bootstrap_look_up for
    // seconds — during arming, the background recovery holds that lock through
    // its retry/backoff loop, and the 1 s auto-refresh timer + viewWillAppear
    // calling reloadProcs on main then froze the whole UI behind it (search
    // bar unusable for seconds). Peek (atomic/cached state only, no lock, no
    // reattach); the background block below re-verifies authoritatively and
    // falls back to the not-ready UI if the session died in between.
    if (!kexploit_krw_peek_live()) {
        [self pm_presentKrwNotReadyUI];
        return;
    }
    self.krwReady = YES;
    if (self.killsInFlight > 0) {
        self.reloadPending = YES;   // runs when the last kill's verdict is in (pmKillEnded)
        [self.refreshControl endRefreshing];
        return;
    }
    if (self.reloadInFlight) {
        self.reloadPending = YES;   // coalesce: one follow-up pass when this one lands
        return;
    }
    self.reloadInFlight = YES;

    // Enumerate via the KRW proc-walk, then read each process's memory/CPU from
    // the kernel task/thread structs using the self-calibrated, mapped-checked
    // read path (procmgr_stats). All read-only — no writes, no escalation — so
    // none of the 18.x write mitigations apply, and every dereference is gated by
    // ksafe so an unmapped/stale pointer degrades instead of panicking. libproc is
    // the fallback for our own (and permitted) pids. %CPU is a delta between
    // refreshes; done on a background queue so the UI never blocks on KRW.
    uint64_t prevWall = self.prevWall;
    NSUInteger passEpoch = self.pmRemovalEpoch;
    NSDictionary<NSNumber *, NSNumber *> *prevCpu = self.prevCpu;
    NSDictionary<NSNumber *, NSNumber *> *prevCpuTime = self.prevCpuTime ?: @{};
    BOOL prevCpuFullTotals = self.prevCpuFullTotals;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // The app may have backgrounded (or the screen blanked) between the guard
        // above and this block running. Bail before any KRW work so an in-flight
        // poll can't race the background detach and re-arm the socket it just
        // parked in launchd.
        if (g_app_in_background != 0 || !settings_screen_awake_cached()) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self pm_reloadFinished]; });
            return;
        }
        // Authoritative readiness re-check OFF the main thread (round 7): the
        // main-thread peek above can pass on a session that died microseconds
        // later, and the lazy reattach (bootstrap_look_up, seconds when
        // flapping) belongs here where blocking is harmless.
        if (!kexploit_krw_ready()) {
            printf("[PROCMGR] refresh: peek passed but authoritative check "
                   "failed — presenting not-ready UI\n");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self pm_reloadFinished];
                [self pm_presentKrwNotReadyUI];
            });
            return;
        }
        // Read-only route: self-calibrate the kernel-struct offsets from our own
        // process, then read every process's memory from the kernel ledger. No
        // writes anywhere, so none of the 18.5 write mitigations apply.
        procmgr_calibrate();
        BOOL cpuFullTotals = procmgr_cpu_calibrated();
        NSDictionary<NSNumber *, NSNumber *> *basePrev =
            (cpuFullTotals == prevCpuFullTotals) ? prevCpu : @{};

        // Wall clock for %CPU, taken here — after the reattach and calibration
        // above — so the interval brackets the counter reads rather than
        // including however long this pass waited to start.
        uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        double dWall = (prevWall > 0 && nowNs > prevWall) ? (double)(nowNs - prevWall) : 0;

        int cap = 4096;
        procmgr_entry_t *buf = calloc((size_t)cap, sizeof(procmgr_entry_t));
        int n = buf ? procmgr_list(buf, cap) : -1;
        // One-time sanity check of the derived p_stat offset: our own process
        // is certainly SRUN, so the KRW read must agree with libproc. If these
        // ever diverge the offset derivation is wrong for this build and
        // suspend-dimming / post-kill verdicts must not be trusted.
        static BOOL sPstatSelfChecked = NO;
        if (!sPstatSelfChecked) {
            sPstatSelfChecked = YES;
            int selfKrw = procmgr_pstat_krw((int)getpid());
            int selfLib = procmgr_pstat((int)getpid());
            printf("[PROCMGR] suspend: self-check krw=%d libproc=%d (off_p_stat=0x%x)%s\n",
                   selfKrw, selfLib, off_proc_p_stat,
                   (selfKrw == selfLib) ? "" : " — MISMATCH, p_stat offset suspect");
        }
        // Incomplete walk (KRW down, or a read failed mid-walk and may have
        // cut the list short): keep the previous list and %CPU baselines
        // rather than publishing an empty / partial one; the next pass retries.
        if (n < 0) {
            printf("[PROCMGR] refresh: process list incomplete — keeping previous snapshot\n");
            if (buf) free(buf);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.pmIncompletePasses++;
                [self applyFilter];   // prompt shows "not updating" from the 2nd pass on
                [self.refreshControl endRefreshing];
                [self pm_reloadFinished];
            });
            return;
        }
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
        NSMutableDictionary<NSNumber *, NSNumber *> *newCpu = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSNumber *, NSNumber *> *newCpuTime = [NSMutableDictionary dictionary];
        NSInteger ncpu = pm_sysctl_int("hw.ncpu");
        const double maxPct = 100.0 * (double)(ncpu > 0 ? ncpu : 8) * 1.05;
        static int sCpuSpikeLogCount = 0;
        int statCount = 0;
        for (int i = 0; i < n; i++) {
            // Mid-pass bail: a background detach can land while we walk rows —
            // the 18:50:56 crash pass kept reading detached sockets for ~10 s
            // after the app backgrounded. Every per-row stat below is a kernel
            // read; stop the pass and keep the previous snapshot instead.
            if (g_app_in_background != 0 || !settings_screen_awake_cached() ||
                !kexploit_krw_session_active()) {
                printf("[PROCMGR] refresh: aborted mid-pass at row %d/%d "
                       "(backgrounded or KRW detached)\n", i, n);
                if (buf) free(buf);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.refreshControl endRefreshing];
                    [self pm_reloadFinished];
                });
                return;
            }
            int pid = buf[i].pid;
            // stringWithUTF8String: returns nil for a torn / non-UTF-8 name,
            // and a nil value in the literal throws — fall back to the pid.
            NSString *pname = [NSString stringWithUTF8String:buf[i].name]
                           ?: [NSString stringWithFormat:@"pid %d", pid];
            NSMutableDictionary *row = [@{ @"pid": @(pid), @"name": pname } mutableCopy];
            if (buf[i].kproc) row[@"kproc"] = @(buf[i].kproc);   // identity for kill checks
            // One read pass per row from the proc pointer the list walk
            // already found (procmgr_row_info): p_stat FIRST (round 14) — a
            // zombie or mid-reap p_stat (outside SIDL..SZOMB) skips the task
            // entirely and renders dimmed with "—"; a pointer that no longer
            // names this pid (exited / recycled since the walk) is treated the
            // same. pstat == -1 (offset unavailable) falls through to the
            // stats gates, as before.
            procmgr_row_info_t ri;
            BOOL present = procmgr_row_info(buf[i].kproc, pid, &ri);
            uint64_t sampleNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);   // this row's reading
            int kst = ri.pstat;
            BOOL exiting = !present || (kst == PM_SZOMB) || (kst >= 0 && (kst < 1 || kst > 7));
            if (!exiting && ri.have_stats) {
                uint64_t mem = ri.mem, cpu = ri.cpu;
                statCount++;
                if (mem) row[@"mem"] = @(mem);
                // Only a real CPU reading becomes a baseline; a failed read
                // leaves none, so the next good pass shows "—" once instead
                // of lifetime-CPU-over-one-interval.
                if (ri.have_cpu) {
                    newCpu[@(pid)] = @(cpu);
                    newCpuTime[@(pid)] = @(sampleNs);
                    NSNumber *prev = basePrev[@(pid)];
                    // Matched pair: this row's previous reading and its time.
                    // Older snapshots without a per-row time use the pass's.
                    uint64_t t0 = [prevCpuTime[@(pid)] unsignedLongLongValue];
                    double dRow = (t0 && sampleNs > t0) ? (double)(sampleNs - t0) : dWall;
                    if (prev && dRow > 0) {
                        uint64_t p0 = prev.unsignedLongLongValue;
                        double pct = cpu >= p0 ? 100.0 * (double)(cpu - p0) / dRow : 0;
                        // No clamp: more than every core flat-out is not a
                        // measurement but a bug in the read path, and it must
                        // stay visible (row AND log), never be capped or hidden.
                        row[@"cpu"] = @(pct);
                        if (pct > maxPct && sCpuSpikeLogCount < 20) {
                            sCpuSpikeLogCount++;
                            printf("[PROCMGR] cpu: pid %d (%s) IMPOSSIBLE %.0f%% (> %.0f%% "
                                   "for %ld cores; prev=%llu now=%llu dWall=%.0fms) — "
                                   "read-path bug, shown unclamped\n",
                                   pid, buf[i].name, pct, maxPct, (long)ncpu,
                                   p0, cpu, dRow / 1e6);
                        }
                    }
                }
            }
            if (exiting) row[@"exiting"] = @YES;
            // Suspended rows are dimmed in the UI. Ground truth is the proc's
            // p_stat read straight from struct proc via KRW (libproc's
            // pbi_status can stay SRUN for a suspended app); the calibrated
            // task suspend_count is kept as a fallback. No calibration, no
            // task_policy_set (that path deadlocked the kernel against
            // PerfPowerServices and stays disabled).
            int sc = ri.suspend_count;
            BOOL suspended = (kst == PM_SSTOP || kst == PM_SZOMB || sc > 0);
            // Mach task role marks GUI apps (like CocoaTop): foreground = the
            // frontmost app, switcher = a backgrounded UI app in the app
            // switcher. A GUI app is a real, user-facing process the user may
            // want to quit, so it is NOT treated as an inert "suspended" row
            // even while iOS has it task-suspended in the background.
            // (Role calibration is currently disabled — this returns -1
            // without touching the kernel.)
            int role = procmgr_task_role(pid);
            if (procmgr_role_is_foreground(role))     row[@"approle"] = @"foreground";
            else if (procmgr_role_is_switcher(role))  row[@"approle"] = @"switcher";
            if (suspended && !procmgr_role_is_app(role))
                row[@"suspended"] = @YES;
            // Verbose, repeat-capped diagnostics so a mis-dimmed (or
            // not-dimmed) row can be traced to its signal values.
            static int sSuspendLogCount = 0;
            if (suspended && sSuspendLogCount < 40) {
                sSuspendLogCount++;
                // libproc p_stat only for this capped diagnostic — it used to
                // be fetched for every row of every pass and then dropped.
                printf("[PROCMGR] suspend: pid %d (%s) dimmed — krw_pstat=%d libproc=%d suspcount=%d\n",
                       pid, buf[i].name, kst, procmgr_pstat(pid), sc);
            }
            [rows addObject:row];
        }
        if (buf) free(buf);
        // Park the filter immediately after the reads. Every KRW read leaves the
        // socket's in6p_icmp6filt pointing at the last kernel address touched
        // (here, some process's task struct). Left that way between refreshes, a
        // sudden suspend parks nothing and the socket can die pointing at freed
        // memory. Parking now returns it to a safe, permanently-mapped target so
        // the primitive is in a clean state within the 2 s gap, not only 1 s
        // after the idle worker notices — closing the window the viewer's steady
        // polling otherwise leaves open. (Detach-before-suspend still does the
        // real save; this just keeps the resting state safe in between.)
        if (kexploit_krw_session_active() && !kexploit_krw_sockets_detached())
            kexploit_krw_park_filter_safe();
        [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"pid"] compare:b[@"pid"]];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.prevCpu = newCpu;
            self.prevCpuTime = newCpuTime;
            self.prevCpuFullTotals = cpuFullTotals;
            self.prevWall = nowNs;
            self.statsAvailable = (statCount > 0);
            [self updateSummaryHeader];
            if (self.pmRemovedPids.count) {
                NSDictionary<NSNumber *, NSNumber *> *removed = self.pmRemovedPids;
                [rows filterUsingPredicate:[NSPredicate predicateWithBlock:
                    ^BOOL(NSDictionary *r, NSDictionary *bindings) {
                        return removed[r[@"pid"]].unsignedIntegerValue <= passEpoch;
                    }]];
                // Removals this pass already post-dates are reflected in it.
                for (NSNumber *pid in removed.allKeys) {
                    if (removed[pid].unsignedIntegerValue <= passEpoch)
                        [self.pmRemovedPids removeObjectForKey:pid];
                }
            }
            self.allProcs = rows;
            self.pmIncompletePasses = 0;
            [self applyFilter];   // sets the "N processes" prompt
            [self.refreshControl endRefreshing];
            [self pm_reloadFinished];
        });
    });
}

// Main queue: end of a reloadProcs pass (any exit path). Runs the coalesced
// follow-up pass if a refresh was requested while this one was in flight.
- (void)pm_reloadFinished
{
    self.reloadInFlight = NO;
    if (self.reloadPending) {
        self.reloadPending = NO;
        [self reloadProcs];   // re-runs every guard (background / KRW peek)
    }
}

- (void)applyFilter
{
    NSString *q = [self.filter stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceCharacterSet]];
    if (q.length == 0) {
        self.procs = self.allProcs;
    } else {
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *p in self.allProcs) {
            NSString *name = p[@"name"];
            NSString *pid = [p[@"pid"] stringValue];
            if ([name rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [pid rangeOfString:q].location != NSNotFound) {
                [out addObject:p];
            }
        }
        self.procs = out;
    }

    PMSortKey key = self.sortKey;
    self.procs = [self.procs sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        switch (key) {
            case PMSortName:
                return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
            case PMSortCPU: {   // highest first; missing values last
                double ca = [a[@"cpu"] doubleValue], cb = [b[@"cpu"] doubleValue];
                if (ca == cb) return [a[@"pid"] compare:b[@"pid"]];
                return ca > cb ? NSOrderedAscending : NSOrderedDescending;
            }
            case PMSortMem: {   // highest first; missing values last
                unsigned long long ma = [a[@"mem"] unsignedLongLongValue], mb = [b[@"mem"] unsignedLongLongValue];
                if (ma == mb) return [a[@"pid"] compare:b[@"pid"]];
                return ma > mb ? NSOrderedAscending : NSOrderedDescending;
            }
            case PMSortPID:
            default:
                return [a[@"pid"] compare:b[@"pid"]];
        }
    }];

    if (q.length == 0) {
        NSUInteger total = self.allProcs.count, suspended = 0;
        for (NSDictionary *p in self.allProcs)
            if ([p[@"suspended"] boolValue]) suspended++;
        NSUInteger active = total - suspended;
        self.navigationItem.prompt =
            [NSString stringWithFormat:@"%lu active · %lu suspended",
             (unsigned long)active, (unsigned long)suspended];
    } else {
        self.navigationItem.prompt =
            [NSString stringWithFormat:@"%lu of %lu", (unsigned long)self.procs.count,
             (unsigned long)self.allProcs.count];
    }
    // One incomplete pass is a normal hiccup; two in a row means the list on
    // screen is going stale -- say so instead of freezing silently.
    if (self.pmIncompletePasses >= 2)
        self.navigationItem.prompt = [self.navigationItem.prompt
            stringByAppendingString:@" · not updating (kernel reads failing)"];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    self.filter = searchController.searchBar.text ?: @"";
    if (!self.krwReady) return;
    [self applyFilter];   // filter the existing snapshot immediately (cheap)

    // Also refresh the underlying process snapshot while searching, so an app
    // launched after the viewer opened shows up in the results. Throttled so we
    // don't re-walk the whole proc list on every keystroke.
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (now - self.lastSearchReloadNs > 800ULL * NSEC_PER_MSEC) {
        self.lastSearchReloadNs = now;
        [self reloadProcs];
    }
}

#pragma mark Arming

- (void)armKRW
{
    [self armKRWInternalSilent:NO];
}

// Round 8: routine foreground restore (KRW merely detached, anchored in
// launchd — the normal return-to-viewer path). Same recovery flow, but it must
// NOT take the arming state: the viewer keeps its rows and the neutral
// "Restoring kernel access…" prompt; the "Arming kernel access…" cell state is
// reserved for an actual user-facing arm/exploit run.
- (void)restoreKRWSilently
{
    [self armKRWInternalSilent:YES];
}

- (void)armKRWInternalSilent:(BOOL)silent
{
    if (self.arming || self.silentRestoring) return;
    if (silent) {
        self.silentRestoring = YES;
    } else {
        self.arming = YES;
        [self.tableView reloadData];
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Recover parked KRW via the shared helper, NOT kexploit_opa334_recover_only()
        // directly: the shared path sets g_kexploit_done (and notifies state). Without
        // it, g_kexploit_done stayed NO for a viewer session, and
        // settings_detach_krw_for_background() then silently returned at its
        // `if (!g_kexploit_done) return;` guard — so the primitive was NEVER handed
        // to launchd before the app suspended and the socket died (errno 22 on wake).
        // This is why tweak runs (which go through settings_ensure_kexploit) survived
        // sleep but the Process Viewer did not.
        // Retry with backoff ONLY while a parked state actually exists —
        // bootstrap_look_up of the parked service flaps for seconds at a time
        // (live 11.log: failed 18:27:11→16, escalation recovered 18:27:16), and
        // the arm flow must ride that out. When there is NO parked state, offer
        // the full exploit IMMEDIATELY, exactly as before the retry loop
        // existed: on a fresh boot, recover's boot-session guard forgets the
        // stale cross-boot save on attempt 1, so the predicate flips false and
        // we stop waiting (live 11.log: 18:26:27→35 burned 8 s delivering news
        // we already had). Each attempt runs the heavy NSUserDefaults recovery
        // via settings_ensure_kexploit_for_read() → kexploit_opa334_recover_only()
        // → krw_persistence_recover(), so the lazy-reattach escalation is
        // shared, not duplicated here. The in-flight flag (arming, or
        // silentRestoring on the round-8 routine-restore path) stays set
        // throughout, so a non-silent cell keeps showing "Arming kernel
        // access…" instead of flashing the alert during a flap.
        BOOL ok = settings_ensure_kexploit_for_read() || kexploit_krw_ready();
        for (int attempt = 2; attempt <= 5 && !ok; attempt++) {
            if (!krw_persistence_has_saved_recovery()) {
                printf("[PROCMGR] arm: no parked state exists — offering full "
                       "exploit without further retries\n");
                break;
            }
            printf("[PROCMGR] arm: parked-state restore attempt %d/5 after flap\n",
                   attempt);
            [NSThread sleepForTimeInterval:2.0];
            ok = settings_ensure_kexploit_for_read() || kexploit_krw_ready();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            // Peek, don't kexploit_krw_ready(): this is the main thread, and
            // ready() can block on krwReattachLock behind a background recovery
            // for seconds (round 7 UI freeze). The reloadProcs below re-verifies
            // authoritatively on its background block, so a stale peek degrades
            // to the not-ready UI instead of a freeze.
            if (ok && kexploit_krw_peek_live()) {
                self.arming = NO;
                self.silentRestoring = NO;
                [self reloadProcs];
                // Round 44: no fastkill pre-warm on KRW-armed-in-viewer (live 45
                // — speculative arming on viewer visibility is the black-screen
                // trigger; kills warm on demand only).
                return;
            }
            // No parked state to recover — a full exploit is the only way, and on
            // A18/M4 that can reboot the device. Ask before doing it.
            printf("[PROCMGR] arm: showing full-exploit alert (reason=%s)\n",
                   krw_persistence_has_saved_recovery()
                       ? "parked state exists but restore failed after all retries"
                       : "no parked kernel state");
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:@"No parked kernel state"
                                 message:@"Kernel access couldn't be restored from a parked state. Running the full exploit can reboot the device on A18/M4. Continue?"
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
                                                 handler:^(UIAlertAction *a) {
                self.arming = NO;
                self.silentRestoring = NO;
                [self.tableView reloadData];
            }]];
            [ac addAction:[UIAlertAction actionWithTitle:@"Run Full Exploit"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
                // Show the live log while the exploit runs, like a normal Run.
                LogViewController *log = [[LogViewController alloc] init];
                UINavigationController *lnav = [[UINavigationController alloc] initWithRootViewController:log];
                [self presentViewController:lnav animated:YES completion:^{
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        BOOL ran = settings_ensure_kexploit();   // sets g_kexploit_done on success
                        BOOL ready = ran && kexploit_krw_ready();
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.arming = NO;
                            self.silentRestoring = NO;
                            if (ready) {
                                // Success: drop the user straight into the working
                                // Process Viewer. Dismiss from the window root —
                                // an equality check against lnav is too fragile
                                // (anything chained on top of the log defeats it
                                // and the log then stays up forever).
                                printf("[PROCMGR] exploit succeeded from viewer prompt — "
                                       "dismissing log, entering Process Viewer\n");
                                UIViewController *root = self.view.window.rootViewController;
                                if (root.presentedViewController) {
                                    [root dismissViewControllerAnimated:YES completion:^{
                                        [self reloadProcs];
                                    }];
                                } else {
                                    [self reloadProcs];
                                }
                                // Round 8: no pre-warm after the exploit either —
                                // first kill warms up lazily (churn reduction).
                            } else {
                                // Failure: keep the log up so the reason stays visible.
                                printf("[PROCMGR] exploit from viewer prompt did not yield KRW — "
                                       "leaving log on screen\n");
                                [self.tableView reloadData];
                            }
                        });
                    });
                }];
            }]];
            [self presentViewController:ac animated:YES completion:nil];
        });
    });
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.krwReady ? (NSInteger)self.procs.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!self.krwReady) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"pmarm"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                 reuseIdentifier:@"pmarm"];
        cell.accessoryView = nil;
        if (self.arming) {
            cell.textLabel.text = @"Arming kernel access…";
            cell.detailTextLabel.text = @"Restoring the parked primitive.";
            cell.textLabel.textColor = [UIColor labelColor];
            UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spin startAnimating];
            cell.accessoryView = spin;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"Arm Kernel Access";
            cell.detailTextLabel.text = @"Tap to restore kernel r/w (no tweaks re-applied).";
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        return cell;
    }

    PMProcCell *cell = [tableView dequeueReusableCellWithIdentifier:@"pmrow"];
    if (!cell) cell = [[PMProcCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"pmrow"];

    NSDictionary *p = self.procs[indexPath.row];
    int pid = [p[@"pid"] intValue];
    // Protected = pid (kernel_task/launchd/self) OR comm (launchd/SpringBoard/
    // backboardd): shown in the list but never killable — same treatment as
    // the existing self-protection (round 5: a SpringBoard kill from inside
    // launchd panicked iOS 17.3.1 with "initproc exited").
    BOOL protectedPid = procmgr_pid_is_protected(pid) ||
                        procmgr_comm_is_protected([p[@"name"] UTF8String]);
    BOOL suspended = [p[@"suspended"] boolValue];
    BOOL exiting = [p[@"exiting"] boolValue];   // zombie / mid-reap: stats skipped
    BOOL terminating = [self.terminatingPids containsObject:@(pid)];

    cell.nameL.text = p[@"name"];
    // Only suspended/exiting rows are dimmed (KRW p_stat ground truth);
    // everything else gets normal label color.
    // Priority: terminating > exiting > suspended > protected > normal.
    cell.nameL.textColor = terminating ? [UIColor tertiaryLabelColor]
                           : exiting ? [UIColor tertiaryLabelColor]
                           : suspended ? [UIColor tertiaryLabelColor]
                           : protectedPid ? [UIColor secondaryLabelColor]
                                          : [UIColor labelColor];
    NSString *approle = p[@"approle"];   // "foreground" / "switcher" / nil
    if (terminating) {
        cell.pidL.text = [NSString stringWithFormat:@"PID %d · terminating…", pid];
        cell.pidL.textColor = [UIColor tertiaryLabelColor];
    } else if (exiting) {
        cell.pidL.text = [NSString stringWithFormat:@"PID %d · exiting", pid];
        cell.pidL.textColor = [UIColor tertiaryLabelColor];
    } else if (suspended) {
        cell.pidL.text = [NSString stringWithFormat:@"PID %d · suspended", pid];
        cell.pidL.textColor = [UIColor tertiaryLabelColor];
    } else if ([approle isEqualToString:@"foreground"]) {
        cell.pidL.text = [NSString stringWithFormat:@"PID %d · foreground app", pid];
        cell.pidL.textColor = [UIColor systemBlueColor];
    } else if ([approle isEqualToString:@"switcher"]) {
        cell.pidL.text = [NSString stringWithFormat:@"PID %d · app switcher", pid];
        cell.pidL.textColor = [UIColor systemTealColor];
    } else {
        cell.pidL.text = [NSString stringWithFormat:@"PID %d", pid];
        cell.pidL.textColor = [UIColor secondaryLabelColor];   // reset for cell reuse
    }

    // One shared formatter (main queue only) — the class method built a new
    // NSByteCountFormatter for every cell on every reload.
    static NSByteCountFormatter *memFmt = nil;
    if (!memFmt) {
        memFmt = [NSByteCountFormatter new];
        memFmt.countStyle = NSByteCountFormatterCountStyleMemory;
    }
    NSNumber *mem = p[@"mem"];
    cell.memL.text = mem ? [memFmt stringFromByteCount:(long long)mem.unsignedLongLongValue] : @"—";
    NSNumber *cpu = p[@"cpu"];
    cell.cpuL.text = cpu ? [NSString stringWithFormat:@"%.1f%%", cpu.doubleValue] : @"—";
    if (suspended || exiting) {
        cell.cpuL.textColor = [UIColor secondaryLabelColor];
        cell.memL.textColor = [UIColor secondaryLabelColor];
    } else {
        cell.cpuL.textColor = (cpu && cpu.doubleValue >= 1.0) ? [UIColor labelColor]
                                                              : [UIColor secondaryLabelColor];
        cell.memL.textColor = [UIColor secondaryLabelColor];   // PMProcCell default
    }

    // Round 44: a live spinner while a kill is in flight. The launchd force-quit
    // can take a couple of seconds (session warm-up) — without an active
    // indicator the dimmed row reads as "frozen". The spinner makes the wait
    // legibly busy. Reset to nil on every non-terminating row so cell reuse
    // never leaves a stray spinner.
    if (terminating) {
        UIActivityIndicatorView *spin = (UIActivityIndicatorView *)cell.accessoryView;
        if (![spin isKindOfClass:UIActivityIndicatorView.class]) {
            spin = [[UIActivityIndicatorView alloc]
                        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            spin.color = [UIColor secondaryLabelColor];
            cell.accessoryView = spin;
        }
        [spin startAnimating];
    } else if ([cell.accessoryView isKindOfClass:UIActivityIndicatorView.class]) {
        cell.accessoryView = nil;
    }

    // Suspended rows stay selectable: they go through the normal quit/force-quit
    // dialog (SIGCONT + SIGTERM, or launchd SIGKILL which kills SSTOP outright).
    cell.selectionStyle = (protectedPid || terminating) ? UITableViewCellSelectionStyleNone
                                                      : UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (!self.krwReady) {
        if (!self.arming) [self armKRW];
        return;
    }
    if (indexPath.row >= (NSInteger)self.procs.count) return;

    NSDictionary *p = self.procs[indexPath.row];
    int pid = [p[@"pid"] intValue];
    NSString *name = p[@"name"];
    uint64_t rowKproc = [p[@"kproc"] unsignedLongLongValue];   // 0 if unknown
    if (procmgr_pid_is_protected(pid) || procmgr_comm_is_protected(name.UTF8String)) return;
    if ([self.terminatingPids containsObject:@(pid)]) return;   // kill already in flight

    // Suspended rows go through the normal dialog like everything else: the
    // Quit path resumes the target (SIGCONT) so its pending SIGTERM lands, and
    // the launchd SIGKILL path kills a stopped (SSTOP) process outright. The
    // honest post-kill alive-check reports the outcome either way.

    BOOL isSystem = (pid < 100);   // low pids are core daemons — warn harder
    NSString *msg = isSystem
        ? [NSString stringWithFormat:@"%@ (PID %d) is a system process. Force-quitting it may respring or reboot the device.", name, pid]
        : [NSString stringWithFormat:@"Force-quit %@ (PID %d)?", name, pid];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Force Quit"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    // Clean termination via SIGTERM — only when we hold signal permission for
    // this pid (probed with kill(pid, 0)). SIGTERM can be caught or ignored by
    // the target, so verify like the force-quit path does.
    BOOL canSignal = (kill(pid, 0) == 0);
    if (canSignal) {
        [ac addAction:[UIAlertAction actionWithTitle:@"Quit"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            // FAIL CLOSED like every other kill entry point: the pid may have
            // exited and been RECYCLED — even to SpringBoard — between the
            // dialog and this tap. Re-verify the comm against the tapped row's
            // name before signalling; a failed lookup refuses (comm lookup
            // failed = cannot prove the target is not a protected process).
            // The comm lookup is a KRW allproc walk, so it and the signals run
            // off-main; alerts and row dimming hop back to main.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                char quitComm[64];
                uint64_t quitKproc = 0;
                BOOL lookupOK = (procmgr_identity_for_pid(pid, quitComm, sizeof(quitComm), &quitKproc) == 0);
                if (!lookupOK || procmgr_comm_is_protected(quitComm) ||
                    !pm_identity_matches_row(quitComm, quitKproc, name, rowKproc)) {
                    printf("[PROCMGR] kill: REFUSING pid %d — %s\n", pid,
                           !lookupOK
                               ? "comm lookup failed, cannot verify it is not a protected process"
                               : (procmgr_comm_is_protected(quitComm)
                                      ? "protected process (pid recycled since dialog?)"
                                      : "comm no longer matches the row (pid recycled since dialog?)"));
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIAlertController *err = [UIAlertController
                            alertControllerWithTitle:@"Couldn't Quit"
                                             message:@"The process identity couldn't be verified (it may have exited), so nothing was signalled."
                                      preferredStyle:UIAlertControllerStyleAlert];
                        [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:err animated:YES completion:nil];
                    });
                    return;
                }
                if (kill(pid, SIGTERM) != 0) {
                    int termErr = errno;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIAlertController *err = [UIAlertController
                            alertControllerWithTitle:@"Couldn't Quit"
                                             message:[NSString stringWithFormat:@"SIGTERM failed (errno %d — the process may have already exited).", termErr]
                                      preferredStyle:UIAlertControllerStyleAlert];
                        [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:err animated:YES completion:nil];
                    });
                    return;
                }
                // A suspended (SSTOP) process never runs its signal handlers, so
                // SIGTERM just sits pending while the app keeps showing in the
                // switcher. Nudge it with SIGCONT: the resume delivers the pending
                // SIGTERM and the app exits cleanly. Harmless if it wasn't stopped.
                kill(pid, SIGCONT);
                printf("[PROCMGR] fastkill: quit(%d) sent SIGTERM + SIGCONT\n", pid);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.terminatingPids addObject:@(pid)];
                    [self pmKillBegan];   // ended after the alive-check below
                    [self applyFilter];   // dim the row immediately (cheap, no KRW)
                    // Verify just this one pid after a short moment; only fall back to
                    // a full rescan when the single-pid check says it's still alive.
                    // A zombie counts as dead — its task is gone, reap is pending.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        bool krwPresent = false, krwKnown = false;
                        int krwStat = procmgr_pid_status_krw(pid, &krwPresent, &krwKnown);   // ONE walk (round 13)
                        BOOL alive = krwPresent && krwStat != PM_SZOMB;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self.terminatingPids removeObject:@(pid)];
                            [self pmKillEnded];
                            if (!krwKnown) {
                                // Couldn't check (KRW down or a read failed): no verdict either
                                // way -- neither drop the row nor claim it survived. A rescan decides.
                                printf("[PROCMGR] fastkill: pid %d status unknown (KRW read unavailable) — rescanning\n", pid);
                                [self reloadProcs];
                                return;
                            }
                            if (!alive) {
                                [self pmRemoveRowForPid:pid];
                                return;
                            }
                            printf("[PROCMGR] fastkill: pid %d still alive after quit (SIGTERM+SIGCONT)\n", pid);
                            UIAlertController *nope = [UIAlertController
                                alertControllerWithTitle:@"Didn't terminate"
                                                 message:[NSString stringWithFormat:@"%@ (PID %d) is still running — it caught or ignored SIGTERM. Use Force Quit instead.", name, pid]
                                          preferredStyle:UIAlertControllerStyleAlert];
                            [nope addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                            [self presentViewController:nope animated:YES completion:nil];
                            [self reloadProcs];
                        });
                    });
                });
            });
        }]];
    }

    [ac addAction:[UIAlertAction actionWithTitle:@"Force Quit"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) {
        // Optimistic: dim the row NOW so the kill feels instant, then run the
        // kill off-main (a plain SIGKILL is instant; the launchd fallback uses
        // a warm RemoteCall session — one hijack ever, milliseconds per kill).
        // Pause the KRW poll while we do it so the two don't contend.
        [self.terminatingPids addObject:@(pid)];
        [self applyFilter];   // reflect "terminating…" without a KRW rescan
        [self pmKillBegan];   // ended after the verdict (rc != 0) or the alive-check
        // Round 52: show the "finishing kill" banner only when a warm-up will
        // actually happen — i.e. the launchd session is cold (the first kill of
        // a foreground session, after a backgrounding, or after the 10 s idle
        // disarm). A warm session makes the kill ~ms, so the banner would just
        // blink. Paired show/hide via this captured flag keeps the refcount
        // balanced across concurrent kills.
        // Lock-free hint: pm_fastkill_warm_session_exists() takes pm_kill_lock,
        // which a cold kill holds through its whole launchd warm-up (~2 s) —
        // a second tap during that froze the main thread until it finished.
        BOOL showBanner = !pm_fastkill_warm_session_hint();
        if (showBanner) [self pmShowKillShield];   // tap → verdict (cold kill only)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int rc = procmgr_kill(pid, name.UTF8String, rowKproc);
            // -6 == our own SIGKILL was denied (the app sandbox blocks signalling
            // other apps). Kill it from launchd instead: launchd is root and
            // unsandboxed, so kill(pid, SIGKILL) run inside it lands on any
            // process. This is a clean syscall from a privileged context — no
            // memory corruption, so none of the crash-trick's panic risk.
            // Round 46: the middle rungs are gone for good — round 44's
            // ucred-swap (proc_ro is write-protected on 18.4+) and round 45's
            // unsandbox (MAC labels live in read-only kalloc on SPTM devices)
            // both EFAULT'd on-device on 21D61 AND 22F76. The launchd
            // RemoteCall is the only privileged kill path.
            if (rc == -6)
                rc = [self pmForceKillViaLaunchd:pid expectedName:name expectedKproc:rowKproc];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (showBanner) [self pmHideKillShield];   // verdict known — paired with the cold-kill show
                if (rc != 0) {
                    [self pmKillEnded];   // nothing to verify
                    [self.terminatingPids removeObject:@(pid)];
                    [self applyFilter];   // un-dim the row
                    NSString *msg;
                    switch (rc) {
                        case -3:
                            msg = @"The process has already exited.";
                            break;
                        case -6:
                            msg = @"The system denied the force-quit signal, and killing it from launchd didn't take either, so it's left running.";
                            break;
                        case -7:
                            // Warm-up failure (launchd hijack didn't take) —
                            // NOT a dead process. Say so and invite a retry;
                            // round 13's arm-attempt retry makes the next tap
                            // very likely to succeed.
                            msg = @"The kernel session into launchd couldn't be established (the warm-up hijack didn't take), so nothing was signalled. Try again.";
                            break;
                        case -9:
                            // Round 24: the lifecycle gate was closed (app
                            // backgrounded/locked mid-kill). Deterministic —
                            // retrying while backgrounded cannot work.
                            msg = @"Cyanide was backgrounded or the screen locked mid-force-quit, so nothing was signalled and the process is still running. Reopen Cyanide and try again.";
                            break;
                        case -10:
                            // Round 43: helper-wedge latch set (a kernel call
                            // stuck from an earlier backgrounding). Retrying
                            // CANNOT work while latched — say so honestly.
                            msg = @"A kernel call is stuck from an earlier backgrounding, so Force Quit is disabled for this session — nothing was signalled and the process is still running. Restart Cyanide to re-enable Force Quit.";
                            break;
                        default:
                            msg = [NSString stringWithFormat:@"Error %d (the process may have already exited).", rc];
                            break;
                    }
                    UIAlertController *err = [UIAlertController
                        alertControllerWithTitle:@"Couldn't Force Quit"
                                         message:msg
                                  preferredStyle:UIAlertControllerStyleAlert];
                    [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:err animated:YES completion:nil];
                    return;
                }
                // Verify just this pid after a short moment. Dead -> drop the
                // row surgically (no ~500-pid KRW rescan); still alive -> say
                // so honestly and rescan as the fallback.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    // Authoritative verdict: only drop the row when the pid is
                    // really gone (a zombie counts as dead — task reaped,
                    // collection pending). Still alive = honest failure path.
                    bool krwPresent = false, krwKnown = false;
                int krwStat = procmgr_pid_status_krw(pid, &krwPresent, &krwKnown);   // ONE walk (round 13)
                BOOL alive = krwPresent && krwStat != PM_SZOMB;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.terminatingPids removeObject:@(pid)];
                        [self pmKillEnded];   // the alive-check is done: refreshes may run again
                        if (!krwKnown) {
                            // Couldn't check (KRW down or a read failed): no verdict either
                            // way -- neither drop the row nor claim it survived. A rescan decides.
                            printf("[PROCMGR] fastkill: pid %d status unknown (KRW read unavailable) — rescanning\n", pid);
                            [self reloadProcs];
                            return;
                        }
                        if (!alive) {
                            [self pmRemoveRowForPid:pid];
                            return;
                        }
                        printf("[PROCMGR] fastkill: pid %d still alive after kill rc=%d\n", pid, rc);
                        UIAlertController *nope = [UIAlertController
                            alertControllerWithTitle:@"Didn't terminate"
                                             message:[NSString stringWithFormat:@"%@ (PID %d) is still running.", name, pid]
                                      preferredStyle:UIAlertControllerStyleAlert];
                        [nope addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:nope animated:YES completion:nil];
                        [self reloadProcs];
                    });
                });
            });
        });
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// Remove one pid's row from both the snapshot and the visible list without a
// KRW rescan — the fast path after a confirmed kill.
- (void)pmRemoveRowForPid:(int)pid
{
    self.pmRemovedPids[@(pid)] = @(++self.pmRemovalEpoch);
    NSIndexSet *idx = [self.allProcs indexesOfObjectsPassingTest:
        ^BOOL(NSDictionary *r, NSUInteger i, BOOL *stop) {
            return [r[@"pid"] intValue] == pid;
        }];
    if (idx.count) {
        NSMutableArray *all = [self.allProcs mutableCopy];
        [all removeObjectsAtIndexes:idx];
        self.allProcs = all;
    }
    [self applyFilter];
    printf("[PROCMGR] fastkill: pid %d row dropped surgically (no full rescan)\n", pid);
}

// Force-quit a process that our own SIGKILL can't reach (the app sandbox blocks
// signalling other apps). Run kill(pid, SIGKILL) *inside launchd* — pid 1 is
// root and unsandboxed, so it can signal anything.
//
// WARM SESSION: instead of building a fresh RemoteCallSession per kill
// (EXC_GUARD hijack + synthetic thread + cleanup ≈ 2.2 s), we hijack launchd
// ONCE and keep the session parked between kills — each kill is then just
// "set args, run, read result" (milliseconds). The session object is a plain
// retained RemoteCallSession; its push/pop state design makes repeated calls
// safe, and all KRW access underneath goes through krw_lock_for_access(), so
// the KRW idle park/detach lifecycle is unaffected (reattach is automatic on
// the next access). We deliberately do NOT register as a persistent-session
// user anywhere: idle detach must stay allowed so the primitive still rests
// in launchd across backgrounding.
//
// If a warm call fails while the target is still alive, the session is
// suspect (primitive hiccup, wedged thread): tear it down — symmetric
// destroy when KRW is up, abandon when it isn't (destroy IPCs the remote task
// and would hang) — rebuild once, and retry once. No memory corruption
// anywhere — a clean privileged syscall, so none of the old saved-state
// crash-trick's panic risk. Must be called off the main thread.
static RemoteCallSession *gPMKillSession = nil;

// Round 7: count of warm-up hijacks currently in flight (a kill's own lazy
// warm-up; runs under pm_kill_lock, so this is 0 or 1). A second kill that
// arrives while it is non-zero ATTACHES to the in-flight warm-up — waits on
// pm_kill_lock once and uses its result — instead of stacking a second hijack.
static volatile int gPMWarmupInFlight = 0;

// A teardown that has taken the session out from under pm_kill_lock and is
// destroying it OUTSIDE the lock. A fresh warm-up must not start until it has
// finished: the old session's teardown restores launchd's task_exc_guard
// flags and drains its ports while the new init is arming launchd threads
// (live 53, 22:32:05 — restore landed 170 ms after the new injection).
static volatile int gPMTeardownInFlight = 0;

static NSLock *pm_kill_lock(void) {
    static NSLock *l = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [NSLock new]; });
    return l;
}

static BOOL pm_fastkill_warm_session_exists(void)
{
    NSLock *lock = pm_kill_lock();
    [lock lock];
    BOOL exists = (gPMKillSession != nil);
    [lock unlock];
    return exists;
}

// Main-thread-safe, non-blocking variant for UI decisions (the cold-kill
// banner). Never waits on pm_kill_lock: a warm-up in flight means the next
// kill is cold; a lock held without a warm-up is a warm kill running (ms) —
// report warm. Cosmetic only; the kill path itself still uses the lock.
static BOOL pm_fastkill_warm_session_hint(void)
{
    if (__sync_add_and_fetch(&gPMWarmupInFlight, 0) > 0) return NO;
    NSLock *lock = pm_kill_lock();
    if (![lock tryLock]) return YES;
    BOOL exists = (gPMKillSession != nil);
    [lock unlock];
    return exists;
}

// Round 46: foreground idle disarm. A warm session between kills is a trapped
// launchd thread plus armed-KRW exposure, and round 6's teardown only fires
// when the app LEAVES the foreground — a user who kills one app and then
// keeps browsing the viewer holds that exposure indefinitely. After a
// successful kill, schedule a 10 s timer that tears the warm session down
// through the SAME safe path as backgrounding, while the app is verifiably
// foreground+active. Any new kill activity cancels/reschedules it (cheap —
// a kill that needs a session re-warms on demand), and backgrounding stays
// the immediate-teardown fallback. Generation-counter cancellation: no
// suspend/resume primitives, no deallocated-block risk.
static volatile int64_t g_pm_idle_disarm_gen = 0;
static volatile int     g_pm_idle_disarm_pending = 0;

static void pm_idle_disarm_cancel(const char *why)
{
    if (!g_pm_idle_disarm_pending) return;
    g_pm_idle_disarm_pending = 0;
    __sync_add_and_fetch(&g_pm_idle_disarm_gen, 1);
    printf("[PROCMGR] fastkill: idle disarm cancelled (%s)\n",
           why ?: "new kill activity");
}

static void pm_idle_disarm_schedule(void)
{
    g_pm_idle_disarm_pending = 1;
    int64_t gen = __sync_add_and_fetch(&g_pm_idle_disarm_gen, 1);
    printf("[PROCMGR] fastkill: idle disarm scheduled in 10 s "
           "(foreground-safe teardown)\n");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (gen != g_pm_idle_disarm_gen) return;   // cancelled/rescheduled
        g_pm_idle_disarm_pending = 0;
        // Guards: never tear down into a backgrounding (the background path
        // owns the session there) or mid-kill.
        if (g_app_in_background || excport_gate_blocked()) {
            printf("[PROCMGR] fastkill: idle disarm skipped — lifecycle gate "
                   "closed (background teardown owns the session now)\n");
            return;
        }
        if (__sync_add_and_fetch(&gPMWarmupInFlight, 0) > 0 ||
            remote_call_inflight_count() > 0) {
            printf("[PROCMGR] fastkill: idle disarm skipped — kill in flight\n");
            return;
        }
        if (!gPMKillSession) return;   // already torn down since scheduling
        // pm_teardown… re-cancels via pm_idle_disarm_cancel, but pending is
        // already 0 so that is a silent no-op — no noisy self-cancel log.
        pm_teardown_fastkill_session_for_terminate("idle disarm");
        printf("[PROCMGR] fastkill: idle disarm torn down (foreground-safe)\n");
    });
}

// Tear down the warm launchd session. Two drivers:
//  (a) the APP itself is exiting (applicationWillTerminate / SIGTERM /
//      WillTerminateNotification) — the round-3 backstop;
//  (b) the app is BACKGROUNDING or the screen blanked (round 6) — a suspended
//      app is SIGKILLed without applicationWillTerminate, so the session must
//      not outlive the foreground; see kFastKillTeardownOnBackground.
// Between kills the session's hijacked launchd thread sits TRAPPED at our
// exception port; if the process dies with the session warm, the port dies
// too, the pending exception escalates to launchd's default handler, and
// launchd EXITS ~22 s later ("initproc exited" — live 11.log: swipe-kill
// 18:31:37, panic 18:31:59; panic-full-2026-09-29-195243: swipe-kill of the
// SUSPENDED app ~19:52:21, panic 19:52:43, terminate cleanup never ran).
// Background/lock cycles were safe precisely because the app — and its ports
// — stayed alive; only app death orphans the thread. Round 6 closes the
// suspended-swipe-kill vector by making app death with a warm session
// impossible: any swipe-kill happens from a backgrounded state, and the
// background path tears the session down before suspension.
//
// The destroy path needs live KRW (stub-page munmap + PAC re-sign), but at
// terminate time the sockets are usually parked in launchd and lazy reattach
// is SUPPRESSED while backgrounded/screen-off — force it. Called BEFORE
// kexploit_terminal_cleanup() parks KRW. Runs off the main thread (the
// terminate cleanup is dispatched to a background queue / runs in the
// SIGTERM handler context).
static void pm_teardown_fastkill_session_for_terminate(const char *reason)
{
    // Round 46: an explicit teardown supersedes any pending idle disarm —
    // cancel it so it can't fire later against a session that is already
    // gone (the fire path would no-op on gPMKillSession==nil anyway; this
    // keeps the log honest). Silent when the idle-disarm fire path itself
    // is the caller (it clears pending first).
    pm_idle_disarm_cancel(reason);
    // Round 25 (A): hold the exception-port teardown bypass for the WHOLE
    // teardown episode — including the PRE-LOCK stop + un-arm below and every
    // concurrent responder re-park/dispatch sign while it runs. All signing
    // funnels through excport_gate_blocked_for_caller(), which consults the
    // process-wide depth, so the responder needs no code change: it passes the
    // gate for the episode's duration (live 28.log 15:16:48.359-.363: the
    // pre-lock stop ran OUTSIDE the round-24 bypass, the responder's re-park
    // signs were refused, and the thread re-fault ping-pong filled the crash
    // backlog the dead-KRW abandon then could not repair). Depth-counted —
    // nests with the destroy/abandon internal bypass and with the
    // "background-detach" episode hold on the call paths that have one.
    excport_teardown_bypass_begin("fastkill-teardown");
    // Round 20: a kill's on-demand warm-up HOLDS pm_kill_lock across its
    // whole init (single-flight). An in-flight warm-up must still be
    // interrupted promptly — issue the stop BEFORE taking the lock
    // (idempotent), or this teardown would queue behind the very init it is
    // trying to abort.
    if (__sync_add_and_fetch(&gPMWarmupInFlight, 0) > 0) {
        printf("[PROCMGR] fastkill: %s with warm-up IN FLIGHT — requesting "
               "stop + un-arm of the partially-armed init (pre-lock)\n",
               reason ?: "terminate");
        remote_call_request_stop(reason ?: "terminate warm-up");
    }
    NSLock *lock = pm_kill_lock();
    // A kill holds pm_kill_lock across its warm-up, dispatch and verdict. On
    // the main thread (scene backgrounding, terminate) an unbounded wait here
    // blocked the lifecycle callback for as long as a stalled kill took --
    // and if iOS's watchdog killed the app meanwhile, the warm session died
    // un-torn-down, the exact launchd-exit state this teardown prevents. So
    // on main wait at most 3 s, then finish the teardown on a background
    // queue, where it waits for the kill to release the lock (the caller's
    // safe-detach background task keeps the app alive meanwhile). Off-main
    // callers keep the plain wait.
    if (NSThread.isMainThread &&
        ![lock lockBeforeDate:[NSDate dateWithTimeIntervalSinceNow:3.0]]) {
        printf("[PROCMGR] fastkill: %s — a kill still holds the lock after 3 s; "
               "finishing the teardown off the main thread\n", reason ?: "terminate");
        char *deferredReason = strdup(reason ?: "terminate");   // caller's string may not outlive us
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            pm_teardown_fastkill_session_for_terminate(deferredReason ?: "terminate");
            free(deferredReason);
        });
        excport_teardown_bypass_end("fastkill-teardown");
        return;
    }
    if (!NSThread.isMainThread) [lock lock];
    RemoteCallSession *session = gPMKillSession;
    gPMKillSession = nil;
    BOOL warmupInFlight = (__sync_add_and_fetch(&gPMWarmupInFlight, 0) > 0);
    if (session) __sync_add_and_fetch(&gPMTeardownInFlight, 1);   // set while still locked
    [lock unlock];
    if (!session) {
        // Round 10: mid-init warm-up has no session object to tear down yet,
        // but its already-armed launchd threads are the detonator — the
        // 17:45:56 warm-up went silent 145 ms into its trap-wait with one
        // thread armed and this teardown was a no-op because gPMKillSession
        // was still nil. remote_call_request_stop() now un-arms any armed
        // thread via KRW (RemoteCall.m snapshot) and the in-flight init
        // aborts at its next stop checkpoint (walk top / heartbeat slice /
        // post-trap), so coverage starts at warm-up START, not at init
        // completion.
        if (warmupInFlight) {
            printf("[PROCMGR] fastkill: %s with warm-up IN FLIGHT — requesting "
                   "stop + un-arm of the partially-armed init\n",
                   reason ?: "terminate");
            remote_call_request_stop(reason ?: "terminate warm-up");
        }
        excport_teardown_bypass_end("fastkill-teardown");
        return;
    }

    printf("[PROCMGR] fastkill: tearing down warm session on %s — restoring "
           "launchd thread before KRW park\n", reason ?: "terminate");
    BOOL krwUp = kexploit_krw_ready() || kexploit_krw_force_reattach_for_teardown();
    if (krwUp) {
        [session destroyRemoteCall];   // symmetrical: restores the trojan thread
        printf("[PROCMGR] fastkill: warm session torn down on %s "
               "(thread restored=YES)\n", reason ?: "terminate");
    } else {
        // KRW genuinely gone: destroy IPCs the remote task and would hang on
        // dead sockets. Abandoning leaves the thread trapped in launchd — the
        // exact round-3 panic vector — but with no primitive there is nothing
        // left to restore it with. Log loudly so the next panic log names it.
        printf("[PROCMGR] fastkill: KRW unrecoverable on %s — abandoning "
               "warm session (thread restored=NO — residual initproc-exit risk)\n",
               reason ?: "terminate");
        [session abandonRemoteCall];
    }
    __sync_sub_and_fetch(&gPMTeardownInFlight, 1);
    excport_teardown_bypass_end("fastkill-teardown");
}

// Round 44: the speculative fastkill pre-warm is REMOVED (function and all
// three call sites: viewWillAppear, KRW-armed-in-viewer, foreground-return-
// while-visible). Arming launchd merely because the Process Viewer is VISIBLE
// is the live-45 black-screen trigger: the pre-warm hijacks launchd at the
// activation edge, its helper can wedge in-kernel through a background
// transition, and an un-reaped helper turns the process into a corpse that
// black-screens on reopen. Round 8 removed it for per-cycle churn, round 13
// brought it back viewer-scoped, rounds 36/41/43 layered on gates and
// latches — but the fundamental problem is that the warm exists BEFORE any
// kill is requested, so every foreground/viewer cycle re-rolls the dice for
// zero user-visible benefit. The kill path now warms the launchd session ON
// DEMAND (pmForceKillViaLaunchdGated, unchanged) — round 46 removed the
// unsandbox middle rung too (labels in read-only kalloc on SPTM), so the
// launchd RemoteCall is the only privileged path. First kill per
// foreground pays the warm-up; subsequent kills in the same foreground stay
// ~ms warm (round-6 backgrounding teardown unchanged).

// Round 46: the unsandbox rung is REMOVED (round 45's pmForceKillViaUnsandbox
// deleted) — proven dead on BOTH supported builds (live 46/47): the kwrite to
// the MAC label's sandbox slot EFAULTs (errno 14) on 21D61 AND 22F76; MAC
// labels live in read-only kalloc on SPTM devices, same wall as proc_ro
// (round 44's ucred-swap). Credential-adjacent kernel memory is simply not
// writable on 18.4+. The launchd RemoteCall is the ONLY privileged kill path
// now: procmgr_kill -> on EPERM, pmForceKillViaLaunchd. procmgr_unsandbox/
// resandbox/escalate/deescalate remain in utils/process.m, marked UNUSED.

// The warm launchd session: tears down an anomalous one, and warms a fresh
// one if needed (refusing while the activation settle window is open). Shared
// by Force Quit and the File Browser's root reads. Caller holds pm_kill_lock
// and the external RemoteCall guard. Returns 0, -2 (settle window) or -7
// (init failure).
static int pm_launchd_session_ensure_locked(const char *what)
{
    // Never warm while a previous session's teardown is still running outside
    // the lock (see gPMTeardownInFlight). Waiting here, under pm_kill_lock, is
    // deadlock-free: the teardown took the session and released the lock
    // before its counter went up. Bounded; bail into a backgrounding.
    if (!gPMKillSession && __sync_add_and_fetch(&gPMTeardownInFlight, 0) > 0) {
        printf("[PROCMGR] fastkill: %s waits for the previous launchd session's "
               "teardown to finish before warming\n", what);
        for (int i = 0; i < 250 && __sync_add_and_fetch(&gPMTeardownInFlight, 0) > 0; i++) {
            if (g_app_in_background || excport_gate_blocked()) return -2;
            usleep(20000);   // 20 ms, up to 5 s
        }
        if (__sync_add_and_fetch(&gPMTeardownInFlight, 0) > 0) {
            printf("[PROCMGR] fastkill: %s refused — previous teardown still "
                   "running after 5 s\n", what);
            return -2;
        }
    }
    // Round 20 (C): never reuse or keep an ANOMALOUS warm session — its
    // first-port responder saw a protocol park trap and exited, leaving a
    // launchd thread parked on that port with no owner (071602: watchdogd
    // turnstile-blocked on exactly such a parked worker → watchdog timeout).
    if (gPMKillSession && [gPMKillSession isAnomalous]) {
        printf("[PROCMGR] fastkill: warm session is ANOMALOUS (responder exited "
               "on a protocol park trap — a launchd thread is parked on its "
               "first port) — tearing it down with invariant repair and "
               "warming a fresh session\n");
        if (kexploit_krw_ready()) [gPMKillSession destroyRemoteCall];
        else                      [gPMKillSession abandonRemoteCall];
        gPMKillSession = nil;
    }
    if (!gPMKillSession) {
        // Round 39 (panic-full-2026-10-04-082220 "unexpected SIGKILL of
        // launchd"): a USER kill that has to warm a fresh launchd session must
        // ALSO wait out the activation settle window. Arming launchd
        // (set_exception_ports → AMFI global lock) while runningboardd /
        // PerfPowerServices policy-set our task during the launch/foreground
        // churn strands a launchd thread → SIGKILL of launchd (082220: user
        // kill at 08:21:52, INSIDE the settle window, armed 5 launchd threads,
        // hung → reboot 27 s later). Round 36 gated the automatic pre-warm; the
        // on-demand kill warm hit the same window. The kill runs off-main (the
        // row already shows "terminating…"), so a bounded wait is just a brief
        // delay; bail if the app backgrounds mid-wait (never arm into a suspend).
        //
        // Round 41: the WAIT ITSELF moved to the unlocked entry
        // (pmForceKillViaLaunchd) — it used to usleep here UNDER pm_kill_lock,
        // serializing every other kill behind one kill's multi-second settle.
        // Reaching this point with the window still pending means a fresh
        // activation re-extended it in the last few ms — refuse rather than
        // wait under the lock (nothing signalled; the kill can simply be
        // retried after the window — round 44 removed the automatic pre-warm
        // that used to re-warm it).
        uint64_t settleUntil = g_activation_settle_until_ns;
        uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        if (settleUntil > nowNs) {
            printf("[PROCMGR] fastkill: REFUSING %s warm — activation "
                   "settle window re-extended (%llu ms left) after the "
                   "pre-lock wait; not arming launchd under pm_kill_lock\n",
                   what, (unsigned long long)((settleUntil - nowNs) / 1000000ULL));
            return -2;
        }
    }
    if (!gPMKillSession) {
        printf("[PROCMGR] fastkill: warming launchd RemoteCall session "
               "(one-time hijack)…\n");
        __sync_add_and_fetch(&gPMWarmupInFlight, 1);
        uint64_t w0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        // Round 10: 10 s first-trap cap (was the 120 s session default).
        // Historical traps arrive in 0.5-2.5 s; a trap that takes longer is
        // never coming (armed candidate died mid-walk or is unparkable), and
        // every extra second is time an orphaned armed thread can detonate
        // against our dead ports if the app leaves the foreground
        // (17:45:56: silence 145 ms into the 120 s wait, panic <60 s).
        // Round 46: arm 4 candidates (was round-41's 2). With 2, the
        // first-trap wait measured 1–4.8 s on-device; the min over 4
        // injected threads should land in ~0.5–1 s. Strand surface stays
        // bounded (anchoring keeps 6; we stay under it).
        remote_call_set_next_init_target_threads("launchd", 4);
        gPMKillSession = [[RemoteCallSession alloc] initWithProcess:@"launchd"
                                                 useMigFilterBypass:NO
                                            firstExceptionTimeoutMS:10000];
        uint64_t warmMs = (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - w0) / 1000000ULL;
        __sync_sub_and_fetch(&gPMWarmupInFlight, 1);
        if (!gPMKillSession) {
            printf("[PROCMGR] fastkill: could not open remote-call session "
                   "(init failure=%s)\n",
                   remote_call_init_failure_description(remote_call_last_init_failure()));
            return -7;
        }
        printf("[PROCMGR] fastkill: warm session ready (launchd pid=%d) — warm-up "
               "took %llu ms (injected=%d, trap at %llu ms)\n",
               gPMKillSession.pid, (unsigned long long)warmMs,
               remote_call_last_init_injected(),
               (unsigned long long)remote_call_last_init_trap_ms());
    }
    return 0;
}

// --- File Browser root reads ------------------------------------------------
//
// Cyanide can't become root (proc_ro/ucred are read-only on SPTM, see
// procmgr_escalate), but launchd is root and unsandboxed. These run plain
// read-only libc calls INSIDE launchd over the same warm session Force Quit
// uses, under the same lock, guard, settle window and idle disarm. Nothing is
// written; only directories and regular files are opened, so the hijacked
// launchd thread can never block on a FIFO/device/socket (a blocked launchd
// thread is a watchdog panic).

static uint64_t pm_root_call(RemoteCallSession *s, int timeoutMS, const char *fn,
                             uint64_t a0, uint64_t a1, uint64_t a2, BOOL *ok);
static NSString *pm_root_errno_text(RemoteCallSession *session, const char *what)
{
    // Through pm_root_call, so a transport failure marks the session suspect.
    BOOL ok = NO;
    uint64_t errPtr = pm_root_call(session, 100, "__error", 0, 0, 0, &ok);
    if (!ok) errPtr = 0;
    // errno is a 4-byte int: copy exactly that, never 8 bytes.
    int err = 0;
    if (errPtr && ![session remoteRead:errPtr to:&err size:sizeof(err)]) err = 0;
    return err > 0 ? [NSString stringWithFormat:@"%s: %s", what, strerror(err)]
                   : [NSString stringWithFormat:@"%s failed", what];
}

// A root listing/read in progress stops as soon as the app starts leaving the
// foreground, so it never holds launchd (and the RemoteCall guard) into the
// background detach.
static BOOL pm_root_should_stop(void)
{
    return g_app_in_background || excport_gate_blocked() || remote_call_stop_requested();
}

// Set when any call of the current root operation (cleanup included) did not
// complete. pm_with_launchd_session then tears the session down rather than
// keeping it warm: a lost return doesn't tell whether close/free happened,
// so the session's state is uncertain and must not be reused or retried
// blindly. Only touched under pm_kill_lock.
static BOOL g_pm_root_session_suspect = NO;

// Runs `block` with the warm launchd session held, reusing the kill path's
// lock, guard, settle-window wait and idle-disarm scheduling. Off-main only.
static BOOL pm_with_launchd_session(const char *what, NSString **errorOut,
                                    void (^block)(RemoteCallSession *session))
{
    NSString *error = nil;
    if (!kexploit_krw_ready()) error = @"Kernel access is not active. Run the chain first.";
    else if (excport_gate_blocked()) error = @"Cyanide is not in the foreground.";
    else if (remote_call_helper_unaccounted_count() > 0)
        error = @"A kernel call is stuck from an earlier backgrounding. Restart Cyanide.";
    if (error) { if (errorOut) *errorOut = error; return NO; }

    pm_idle_disarm_cancel(what);
    uint64_t settleUntil = g_activation_settle_until_ns;   // wait OUTSIDE the lock
    while (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) < settleUntil) {
        if (g_app_in_background || excport_gate_blocked()) {
            if (errorOut) *errorOut = @"Cyanide left the foreground.";
            return NO;
        }
        usleep(100000);
    }
    NSLock *lock = pm_kill_lock();
    [lock lock];
    BOOL ran = NO;
    if (!remote_call_guard_acquire_external(what)) {
        error = @"Cyanide is going to the background.";
    } else {
        int rc = pm_launchd_session_ensure_locked(what);
        if (rc == 0 && gPMKillSession) {
            g_pm_root_session_suspect = NO;
            block(gPMKillSession);
            ran = YES;
            if (kexploit_krw_session_active() && !kexploit_krw_sockets_detached())
                kexploit_krw_park_filter_safe();
            if ([gPMKillSession isAnomalous] || g_pm_root_session_suspect) {
                printf("[FILES] root: launchd session %s — tearing it down\n",
                       g_pm_root_session_suspect ? "had a call that did not complete" : "ANOMALOUS");
                g_pm_root_session_suspect = NO;
                if (kexploit_krw_ready()) [gPMKillSession destroyRemoteCall];
                else                      [gPMKillSession abandonRemoteCall];
                gPMKillSession = nil;
            }
        } else {
            error = rc == -2 ? @"Cyanide was just activated. Try again in a moment."
                             : @"Root access through launchd could not be opened.";
        }
        remote_call_guard_release_external(what);
    }
    BOOL keepWarm = (gPMKillSession != nil);
    [lock unlock];
    if (keepWarm) pm_idle_disarm_schedule();   // shed the session after 10 idle s
    if (!ran && errorOut) *errorOut = error;
    return ran;
}

// struct dirent (64-bit inode): d_namlen (u16) at 18, d_name at 21.
enum { PM_DIRENT_NAMLEN_OFF = 18, PM_DIRENT_NAME_OFF = 21 };
static const NSUInteger kPMRootMaxEntries = 4000;

// launchd scratch layout shared by list/read: [path | stat | link | data].
// Every region has a fixed capacity; a path must fit its region BEFORE it is
// copied into launchd (the copy itself knows nothing about the allocation).
enum {
    PM_ROOT_PATH_CAP = PATH_MAX,              // path incl. NUL
    PM_ROOT_STAT_OFF = PM_ROOT_PATH_CAP,
    PM_ROOT_STAT_CAP = 512,                   // >= sizeof(struct stat)
    PM_ROOT_LINK_OFF = PM_ROOT_STAT_OFF + PM_ROOT_STAT_CAP,
    PM_ROOT_LINK_CAP = PATH_MAX,
    PM_ROOT_DATA_OFF = PM_ROOT_LINK_OFF + PM_ROOT_LINK_CAP,
};
_Static_assert(sizeof(struct stat) <= PM_ROOT_STAT_CAP, "stat region too small");

// Absolute, NUL-free, and short enough for the launchd path region.
static BOOL pm_root_path_ok(NSString *path)
{
    const char *p = path.fileSystemRepresentation;
    if (!p || p[0] != '/') return NO;
    return strlen(p) < PM_ROOT_PATH_CAP;
}

// One libc call inside launchd. *ok reports whether the call actually
// completed — a transport failure also returns 0, which would otherwise read
// as a valid fd 0, EOF, end of directory or a successful lstat.
static uint64_t pm_root_call(RemoteCallSession *s, int timeoutMS, const char *fn,
                             uint64_t a0, uint64_t a1, uint64_t a2, BOOL *ok)
{
    uint64_t r = [s doRemoteCallStableWithTimeout:timeoutMS functionName:fn
                                               x0:a0 x1:a1 x2:a2 x3:0 x4:0 x5:0 x6:0 x7:0];
    *ok = remote_call_last_call_ok();
    if (!*ok) {
        g_pm_root_session_suspect = YES;
        printf("[FILES] root: launchd call %s did not complete (transport)\n", fn);
    }
    return r;
}

static NSString *const kPMRootTransportError = @"A call into launchd did not complete. Try again.";

// lstat `path` inside launchd (plus stat + readlink for a symlink).
// Returns 1 ok, 0 libc failure (errno in launchd), -1 transport/copy failure.
static int pm_root_stat(RemoteCallSession *s, uint64_t buf, NSString *path,
                        struct stat *lst, struct stat *st, BOOL *haveSt, NSString **link)
{
    if (!pm_root_path_ok(path)) return 0;
    BOOL ok;
    uint64_t statBuf = buf + PM_ROOT_STAT_OFF;
    if (![s remoteWriteString:buf value:path.fileSystemRepresentation]) return -1;
    int rc = (int)pm_root_call(s, 1000, "lstat", buf, statBuf, 0, &ok);
    if (!ok) return -1;
    if (rc != 0) return 0;
    if (![s remoteRead:statBuf to:lst size:sizeof(*lst)]) return -1;
    *haveSt = NO;
    if (S_ISLNK(lst->st_mode)) {
        rc = (int)pm_root_call(s, 1000, "stat", buf, statBuf, 0, &ok);
        if (!ok) return -1;
        if (rc == 0) {
            if (![s remoteRead:statBuf to:st size:sizeof(*st)]) return -1;
            *haveSt = YES;
        }
        uint64_t linkBuf = buf + PM_ROOT_LINK_OFF;
        int64_t n = (int64_t)pm_root_call(s, 1000, "readlink", buf, linkBuf, PM_ROOT_LINK_CAP - 1, &ok);
        if (!ok) return -1;
        if (n > 0 && n < PM_ROOT_LINK_CAP && link) {
            char tmp[PM_ROOT_LINK_CAP];
            if (![s remoteRead:linkBuf to:tmp size:(uint64_t)n]) return -1;
            tmp[n] = 0;
            *link = @(tmp);
        }
    }
    return 1;
}

static NSDictionary *pm_root_entry_dict(NSString *name, const struct stat *lst,
                                        const struct stat *st, BOOL haveSt, NSString *link)
{
    BOOL isLink = S_ISLNK(lst->st_mode);
    NSMutableDictionary *d = [@{
        @"name": name, @"mode": @(lst->st_mode), @"uid": @(lst->st_uid), @"gid": @(lst->st_gid),
        @"size": @(lst->st_size), @"mtime": @(lst->st_mtimespec.tv_sec),
        @"isDirectory": @(isLink ? (haveSt && S_ISDIR(st->st_mode)) : S_ISDIR(lst->st_mode)),
    } mutableCopy];
    if (link) d[@"linkTarget"] = link;
    return d;
}

NSArray<NSDictionary *> *settings_root_list_directory(NSString *path, BOOL *incompleteOut, NSString **errorOut)
{
    if (incompleteOut) *incompleteOut = NO;
    if (!pm_root_path_ok(path)) {
        if (errorOut) *errorOut = @"Path is not absolute or too long.";
        return nil;
    }
    __block NSArray *out = nil;
    __block NSString *error = nil;
    __block BOOL incomplete = NO;
    pm_with_launchd_session("file browser root list", &error, ^(RemoteCallSession *s) {
        BOOL ok;
        uint64_t buf = pm_root_call(s, 1000, "malloc", PM_ROOT_DATA_OFF, 0, 0, &ok);
        if (!ok || !buf) { error = ok ? @"launchd could not allocate a buffer." : kPMRootTransportError; return; }
        struct stat lst, st; BOOL haveSt = NO;
        int src = pm_root_stat(s, buf, path, &lst, &st, &haveSt, NULL);
        if (src < 0) {
            error = kPMRootTransportError;
        } else if (src == 0) {
            error = pm_root_errno_text(s, "stat");
        } else if (!(S_ISDIR(lst.st_mode) || (S_ISLNK(lst.st_mode) && haveSt && S_ISDIR(st.st_mode)))) {
            error = @"Not a folder.";
        } else if (![s remoteWriteString:buf value:path.fileSystemRepresentation]) {
            error = kPMRootTransportError;
        } else {
            uint64_t dir = pm_root_call(s, 1000, "opendir", buf, 0, 0, &ok);
            if (!ok) {
                error = kPMRootTransportError;
            } else if (!dir) {
                error = pm_root_errno_text(s, "opendir");
            } else {
                NSMutableArray<NSString *> *names = [NSMutableArray array];
                BOOL stopped = NO, failed = NO;
                // Clear errno so a readdir error is distinguishable from EOF.
                // errno is a 4-byte int in launchd's thread storage: copy
                // exactly sizeof(int), never 8 bytes (that would overwrite
                // the neighbouring thread-local data).
                uint64_t errPtr = pm_root_call(s, 100, "__error", 0, 0, 0, &ok);
                if (!ok || !errPtr) failed = YES;
                const int zeroErrno = 0;
                while (!failed) {
                    if (pm_root_should_stop()) { stopped = YES; break; }
                    if (names.count >= kPMRootMaxEntries) {
                        // At the cap: one more readdir tells "more left" from
                        // "exactly the cap" (NULL with errno 0 = complete).
                        if (![s remoteWrite:errPtr from:&zeroErrno size:sizeof(zeroErrno)]) { failed = YES; break; }
                        uint64_t more = pm_root_call(s, 1000, "readdir", dir, 0, 0, &ok);
                        if (!ok) { failed = YES; break; }
                        int moreErrno = 0;
                        if (!more && ![s remoteRead:errPtr to:&moreErrno size:sizeof(moreErrno)]) { failed = YES; break; }
                        incomplete = (more != 0) || moreErrno != 0;
                        break;
                    }
                    if (![s remoteWrite:errPtr from:&zeroErrno size:sizeof(zeroErrno)]) { failed = YES; break; }
                    uint64_t ent = pm_root_call(s, 1000, "readdir", dir, 0, 0, &ok);
                    if (!ok) { failed = YES; break; }
                    if (!ent) {
                        // NULL is EOF only if errno stayed 0 (and we could read it).
                        int remoteErrno = 0;
                        if (![s remoteRead:errPtr to:&remoteErrno size:sizeof(remoteErrno)]) failed = YES;
                        else if (remoteErrno != 0) incomplete = YES;
                        break;
                    }
                    uint8_t head[PM_DIRENT_NAME_OFF];
                    if (![s remoteRead:ent to:head size:sizeof(head)]) { failed = YES; break; }
                    uint16_t namlen = (uint16_t)(head[PM_DIRENT_NAMLEN_OFF] | (head[PM_DIRENT_NAMLEN_OFF + 1] << 8));
                    if (namlen == 0 || namlen > 255) continue;
                    char name[256];
                    if (![s remoteRead:ent + PM_DIRENT_NAME_OFF to:name size:namlen]) { failed = YES; break; }
                    name[namlen] = 0;
                    if (!strcmp(name, ".") || !strcmp(name, "..")) continue;
                    NSString *n = [[NSString alloc] initWithBytes:name length:namlen encoding:NSUTF8StringEncoding];
                    if (n) [names addObject:n];
                }
                pm_root_call(s, 1000, "closedir", dir, 0, 0, &ok);
                NSMutableArray *entries = [NSMutableArray arrayWithCapacity:names.count];
                for (NSString *n in names) {
                    if (failed || stopped) break;
                    if (pm_root_should_stop()) { stopped = YES; break; }
                    NSString *full = [path stringByAppendingPathComponent:n];
                    struct stat el, es; BOOL eHave = NO; NSString *link = nil;
                    int r = pm_root_stat(s, buf, full, &el, &es, &eHave, &link);
                    if (r < 0) { failed = YES; break; }
                    if (r > 0) [entries addObject:pm_root_entry_dict(n, &el, &es, eHave, link)];
                    else       [entries addObject:@{ @"name": n, @"statFailed": @YES }];
                }
                if (stopped)     error = @"Stopped: Cyanide left the foreground.";
                else if (failed) error = kPMRootTransportError;
                else             out = entries;
            }
        }
        pm_root_call(s, 1000, "free", buf, 0, 0, &ok);
    });
    if (!out && errorOut) *errorOut = error ?: @"The folder could not be read.";
    if (incompleteOut) *incompleteOut = incomplete;
    printf("[FILES] root list %s: %s (%lu entries%s)\n", path.fileSystemRepresentation,
           out ? "ok" : "failed", (unsigned long)out.count, incomplete ? ", INCOMPLETE" : "");
    return out;
}

NSData *settings_root_read_file(NSString *path, NSUInteger maxBytes, BOOL *truncatedOut, NSString **errorOut)
{
    if (truncatedOut) *truncatedOut = NO;
    if (!pm_root_path_ok(path)) {
        if (errorOut) *errorOut = @"Path is not absolute or too long.";
        return nil;
    }
    __block NSMutableData *out = nil;
    __block NSString *error = nil;
    __block BOOL truncated = NO;
    pm_with_launchd_session("file browser root read", &error, ^(RemoteCallSession *s) {
        const size_t chunk = 64 * 1024;
        BOOL ok;
        uint64_t buf = pm_root_call(s, 1000, "malloc", PM_ROOT_DATA_OFF + chunk, 0, 0, &ok);
        if (!ok || !buf) { error = ok ? @"launchd could not allocate a buffer." : kPMRootTransportError; return; }
        uint64_t data = buf + PM_ROOT_DATA_OFF;
        struct stat lst, st; BOOL haveSt = NO;
        int src = pm_root_stat(s, buf, path, &lst, &st, &haveSt, NULL);
        if (src < 0) {
            error = kPMRootTransportError;
        } else if (src == 0) {
            error = pm_root_errno_text(s, "stat");
        } else if (!(S_ISREG(lst.st_mode) || (S_ISLNK(lst.st_mode) && haveSt && S_ISREG(st.st_mode)))) {
            error = @"Only regular files can be read as root.";   // never open FIFO/device/socket in launchd
        } else if (![s remoteWriteString:buf value:path.fileSystemRepresentation]) {
            error = kPMRootTransportError;
        } else {
            int fd = (int)pm_root_call(s, 1000, "open", buf, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0, &ok);
            if (!ok) {
                error = kPMRootTransportError;   // no fd was established: nothing to close
            } else if (fd < 0) {
                error = pm_root_errno_text(s, "open");
            } else {
                // The path could have been swapped between stat and open:
                // validate the opened object itself before reading.
                int frc = (int)pm_root_call(s, 1000, "fstat", (uint64_t)fd, buf + PM_ROOT_STAT_OFF, 0, &ok);
                struct stat fst;
                BOOL regular = ok && frc == 0 &&
                    [s remoteRead:buf + PM_ROOT_STAT_OFF to:&fst size:sizeof(fst)] && S_ISREG(fst.st_mode);
                if (!ok) error = kPMRootTransportError;
                else if (!regular) error = @"Only regular files can be read as root.";
                NSMutableData *acc = regular ? [NSMutableData data] : nil;
                BOOL readOK = regular;
                while (readOK && acc.length < maxBytes) {
                    if (pm_root_should_stop()) {
                        error = @"Stopped: Cyanide left the foreground."; readOK = NO; break;
                    }
                    size_t want = MIN(chunk, maxBytes - acc.length);
                    int64_t n = (int64_t)pm_root_call(s, 2000, "read", (uint64_t)fd, data, want, &ok);
                    if (!ok) { error = kPMRootTransportError; readOK = NO; break; }
                    if (n < 0) { error = pm_root_errno_text(s, "read"); readOK = NO; break; }
                    if ((uint64_t)n > want) { error = @"launchd returned an invalid read size."; readOK = NO; break; }
                    if (n == 0) break;
                    NSUInteger at = acc.length;
                    acc.length = at + (NSUInteger)n;
                    if (![s remoteRead:data to:(uint8_t *)acc.mutableBytes + at size:(uint64_t)n]) {
                        error = kPMRootTransportError; readOK = NO; break;
                    }
                }
                if (readOK) {
                    if (acc.length >= maxBytes) {
                        int64_t more = (int64_t)pm_root_call(s, 2000, "read", (uint64_t)fd, data, 1, &ok);
                        truncated = !ok || more != 0;   // unknown counts as truncated
                    }
                    out = acc;
                }
                pm_root_call(s, 1000, "close", (uint64_t)fd, 0, 0, &ok);
            }
        }
        pm_root_call(s, 1000, "free", buf, 0, 0, &ok);
    });
    if (!out && errorOut) *errorOut = error ?: @"The file could not be read.";
    if (truncatedOut) *truncatedOut = truncated;
    return out;
}

- (int)pmForceKillViaLaunchdLocked:(int)pid expectedName:(NSString *)expectedName
                     expectedKproc:(uint64_t)expectedKproc
                      allowRebuild:(BOOL)allowRebuild
{
    // ONE guard hold across warm-up + kill + verdict: a pending detach waits
    // for the count to drain AND closes the gate first, but without this hold
    // there is a release(init-hijack) → acquire(call-stable) gap the detach
    // slips into (live 10.log 17:50:30.483 — same-millisecond interleave,
    // device panicked "initproc exited" at 17:50:55). Fail-fast when a detach
    // is already pending: better an honest abort than a kill on dying sockets.
    if (!remote_call_guard_acquire_external("fastkill")) {
        printf("[PROCMGR] fastkill: detach gate closed (backgrounding in progress) — "
               "aborting kill(%d) before touching launchd\n", pid);
        return -2;
    }
    int rc = [self pmForceKillViaLaunchdGated:pid expectedName:expectedName expectedKproc:expectedKproc
                                 allowRebuild:allowRebuild];
    remote_call_guard_release_external("fastkill");
    return rc;
}

- (int)pmForceKillViaLaunchdGated:(int)pid expectedName:(NSString *)expectedName
                    expectedKproc:(uint64_t)expectedKproc
                     allowRebuild:(BOOL)allowRebuild
{
    // Deepest refusal, at the layer that builds the remote-call args (round 5):
    // pid <= 1 must NEVER reach a launchd-internal kill() — kill(0, …) from
    // pid 1 is a process-group kill that ends launchd itself (instant
    // "initproc exited"). This fires even if every caller above forgot to check.
    if (pid <= 1) {
        printf("[PROCMGR] fastkill: REFUSING to dispatch kill for pid %d "
               "(call-layer hard-stop)\n", pid);
        return -1;
    }
    // Round 24 (142628): never warm a session or dispatch a kill while the
    // lifecycle gate is closed — the init is refused (round-24 fail-fast) or,
    // pre-24, storm-retried for ~9 s and the kill silently never happened
    // while the UI hung on a dimmed row. Fail fast and loudly; rc -9 gives
    // the UI a distinct "process is still alive" message.
    if (excport_gate_blocked()) {
        printf("[PROCMGR] fastkill: REFUSING kill(%d) — lifecycle gate closed "
               "(app backgrounded/terminating); the process is still alive, "
               "nothing was signalled\n", pid);
        log_user("[PROCMGR] kill(%d) refused: app backgrounded mid-kill — "
                 "process still alive, nothing signalled\n", pid);
        return -9;
    }
    // Round 43 (live 44): while the helper-wedge latch is set, the launchd
    // warm-up CANNOT succeed (init fails fast, every arm refused) — refuse
    // here with a distinct rc so the UI says "restart Cyanide" instead of
    // "try again" (retrying cannot work while latched). The latch is
    // revocable: a late helper exit clears it and the next kill works.
    if (remote_call_helper_unaccounted_count() > 0) {
        printf("[PROCMGR] fastkill: REFUSING kill(%d) — tro-dance helper wedged "
               "in-kernel earlier this session (fail-closed latch); the process "
               "is still alive, nothing was signalled\n", pid);
        log_user("[PROCMGR] kill(%d) refused: a kernel call is stuck from an "
                 "earlier backgrounding — restart Cyanide to re-enable Force "
                 "Quit\n", pid);
        return -10;
    }
    // Same layer, comm hard-stop — FAIL CLOSED like every other kill entry
    // point: a failed lookup refuses (SpringBoard/backboardd have ordinary
    // pids; a transient KRW read failure must not re-open the panic vector).
    // The comm must also still name the row the user tapped: a mismatch means
    // the pid was recycled since the list pass. Checked once up front (don't
    // warm launchd for a refused target) and AGAIN right before the remote
    // kill — the warm-up can take ~2 s, long enough for exit + pid reuse.
    BOOL (^commOK)(const char *) = ^BOOL(const char *when) {
        char gComm[64];
        uint64_t gKproc = 0;
        if (procmgr_identity_for_pid(pid, gComm, sizeof(gComm), &gKproc) != 0) {
            printf("[PROCMGR] kill: REFUSING pid %d (%s) — comm lookup failed, "
                   "cannot verify it is not a protected process\n", pid, when);
            return NO;
        }
        if (procmgr_comm_is_protected(gComm)) {
            printf("[PROCMGR] fastkill: REFUSING protected process pid %d (%s) "
                   "(call-layer hard-stop, %s)\n", pid, gComm, when);
            return NO;
        }
        if (!pm_identity_matches_row(gComm, gKproc, expectedName, expectedKproc)) {
            printf("[PROCMGR] fastkill: REFUSING pid %d (%s) — '%s' proc=0x%llx no longer "
                   "matches row '%s' proc=0x%llx (pid recycled?)\n", pid, when, gComm,
                   (unsigned long long)gKproc, expectedName.UTF8String ?: "(nil)",
                   (unsigned long long)expectedKproc);
            return NO;
        }
        return YES;
    };
    if (!commOK("pre-warm-up")) return -1;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    BOOL warmed = (gPMKillSession != nil && ![gPMKillSession isAnomalous]);
    int warmRC = pm_launchd_session_ensure_locked("kill");
    if (warmRC != 0) return warmRC;
    if (!commOK("pre-kill")) return -1;
    uint64_t r = [gPMKillSession doRemoteCallStableWithTimeout:2000
                                                  functionName:"kill"
                                                            x0:(uint64_t)pid
                                                            x1:(uint64_t)SIGKILL
                                                            x2:0 x3:0 x4:0 x5:0 x6:0 x7:0];
    uint64_t ms = (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t0) / 1000000ULL;
    printf("[PROCMGR] fastkill: kill(%d, SIGKILL) via %s session returned %d "
           "in %llu ms\n", pid, warmed ? "warm" : "fresh", (int)r,
           (unsigned long long)ms);
    // Park the RW filter right after our kernel accesses — same hygiene as the
    // reloadProcs poll — so the socket never rests armed between kills.
    if (kexploit_krw_session_active() && !kexploit_krw_sockets_detached())
        kexploit_krw_park_filter_safe();

    // Verdict with grace. The remote return slot is NOT proof (a wedged warm
    // session funnels into `return 0` inside RemoteCall.m), and kill() rc=0
    // only means the signal was DELIVERED — a mid-reap proc reads p_stat=14
    // garbage (live 10.log: kill(346) rc=0, verdict +5 ms p_stat=14, but the
    // process was genuinely dying; that bogus "STILL ALIVE" caused the
    // teardown/re-hijack churn). Kernel-is-witness, polled over ~500 ms:
    // gone/SZOMB at any checkpoint = success; p_stat outside 1..7 (mid-reap)
    // or unreadable = INCONCLUSIVE — keep polling, never tear down on it.
    static const int kVerdictCheckMS[] = { 50, 150, 300, 500 };
    BOOL gone = NO;
    BOOL lastPresent = NO, lastValidStat = NO;
    BOOL sawOpError = NO;
    int lastKst = -2;
    uint64_t v0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    // Round 15: the latch is sticky and process-wide — clear it so it reflects
    // only THIS verdict's reads, then consult it before crediting "not found".
    krw_op_error_clear();
    for (int i = 0; i < 4; i++) {
        uint64_t elapsedMS = (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - v0) / 1000000ULL;
        if ((int)elapsedMS < kVerdictCheckMS[i])
            usleep((useconds_t)(kVerdictCheckMS[i] - (int)elapsedMS) * 1000);
        bool presentNow = false, knownNow = false;
        lastKst = procmgr_pid_status_krw(pid, &presentNow, &knownNow);   // ONE walk (round 13)
        lastPresent = presentNow;
        uint64_t atMS = (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - v0) / 1000000ULL;
        // "Not in the list" is only proof of death if the walk's reads really
        // happened. With crash→zero-fill, a transient socket failure zero-fills
        // every read and the walk reports not-found for a LIVE process — that
        // false "GONE" is exactly what krw_op_error() exists to catch.
        // !knownNow covers KRW not ready, which returns before any read and
        // so never latches the op-error flag on its own.
        if (!lastPresent && (!knownNow || krw_op_error())) {
            sawOpError = YES;
            printf("[PROCMGR] fastkill: verdict poll %d/4 at +%llu ms: pid %d not "
                   "found BUT KRW op-error latched (reads zero-filled) — "
                   "inconclusive, keep polling\n",
                   i + 1, (unsigned long long)atMS, pid);
            continue;
        }
        if (!lastPresent || lastKst == PM_SZOMB) {
            gone = YES;
            printf("[PROCMGR] fastkill: verdict poll %d/4 at +%llu ms: pid %d GONE "
                   "(present=%d p_stat=%d) — kill confirmed dead\n",
                   i + 1, (unsigned long long)atMS, pid, lastPresent, lastKst);
            break;
        }
        lastValidStat = (lastKst >= 1 && lastKst <= 7);   // SIDL..SZOMB; >7 is mid-reap garbage
        printf("[PROCMGR] fastkill: verdict poll %d/4 at +%llu ms: pid %d present, "
               "p_stat=%d (%s)\n",
               i + 1, (unsigned long long)atMS, pid, lastKst,
               lastValidStat ? "valid — alive" : "invalid — inconclusive, keep polling");
    }
    if (gone)
        return 0;

    // Signal failure with ESRCH = the process was already gone to the killer —
    // success regardless of what the proc-list walk says. Read launchd's errno
    // via the session (cheap second call) when kill returned -1.
    if ((int)r == -1) {
        uint64_t errPtr = [gPMKillSession doRemoteCallStableWithTimeout:100
                                                           functionName:"__error"
                                                                     x0:0 x1:0 x2:0 x3:0
                                                                     x4:0 x5:0 x6:0 x7:0];
        int remoteErr = -1;   // errno is 4 bytes: exact-width read
        if (errPtr && ![gPMKillSession remoteRead:errPtr to:&remoteErr size:sizeof(remoteErr)]) remoteErr = -1;
        printf("[PROCMGR] fastkill: kill rc=-1, remote errno=%d (%s)\n",
               remoteErr, remoteErr == ESRCH ? "ESRCH — already gone" : "other");
        if (remoteErr == ESRCH) {
            printf("[PROCMGR] fastkill: kill(%d) confirmed dead via ESRCH\n", pid);
            return 0;
        }
    }

    if ((lastPresent && !lastValidStat) || (!lastPresent && sawOpError)) {
        // INCONCLUSIVE: proc still in the list but its state never read clean
        // (mid-reap or KRW hiccup), OR it read as not-found while the op-error
        // latch says the walk's reads zero-filled (no proof either way). NOT
        // proof of a stale session — keep the session, report tentative
        // success on rc=0 (the UI's 0.4 s alive-check re-verifies with fresh
        // eyes) or an honest soft failure otherwise.
        // Round 20 (C): …unless the session went ANOMALOUS mid-kill (its
        // responder exited on a park trap — kill(745) at 07:14:21.432). A
        // warm session with a dead responder and a parked launchd thread is
        // the watchdog-timeout bomb; tear it down instead of keeping it.
        if ([gPMKillSession isAnomalous]) {
            printf("[PROCMGR] fastkill: session went ANOMALOUS during kill(%d) "
                   "(responder exited on a park trap) — tearing down instead "
                   "of keeping it warm\n", pid);
            if (kexploit_krw_ready()) [gPMKillSession destroyRemoteCall];
            else                      [gPMKillSession abandonRemoteCall];
            gPMKillSession = nil;
        }
        printf("[PROCMGR] fastkill: verdict INCONCLUSIVE for pid %d after 500 ms "
               "grace (rc=%d, present=%d, p_stat=%d, opError=%d) — session kept, %s\n",
               pid, (int)r, lastPresent, lastKst, sawOpError,
               (int)r == 0 ? "deferring to UI alive-check" : "reporting soft failure");
        return ((int)r == 0) ? 0 : -8;
    }

    // CONFIRMED alive: proc present + valid p_stat after the full grace window.
    printf("[PROCMGR] fastkill: pid %d CONFIRMED alive after 500 ms grace "
           "(rc=%d, p_stat=%d) — warm session is genuinely stale\n",
           pid, (int)r, lastKst);
    if (!allowRebuild) {
        printf("[PROCMGR] fastkill: pid %d still alive after kill rc=%d "
               "(rebuild already attempted — giving up)\n", pid, (int)r);
        return -8;
    }
    printf("[PROCMGR] fastkill: warm session suspect (rc=%d, pid %d alive) — "
           "tearing down and rebuilding once\n", (int)r, pid);
    if (kexploit_krw_ready()) [gPMKillSession destroyRemoteCall];   // symmetrical
    else                     [gPMKillSession abandonRemoteCall];    // KRW down: no IPC
    gPMKillSession = nil;
    return [self pmForceKillViaLaunchdGated:pid expectedName:expectedName expectedKproc:expectedKproc
                               allowRebuild:NO];
}

- (int)pmForceKillViaLaunchd:(int)pid expectedName:(NSString *)expectedName
              expectedKproc:(uint64_t)expectedKproc
{
    if (pid <= 1) {
        printf("[PROCMGR] fastkill: REFUSING protected pid %d (kernel_task/launchd)\n", pid);
        return -1;
    }
    // Round 46: new kill activity supersedes any pending idle disarm — the
    // session this kill warms/uses gets its own disarm schedule on success.
    pm_idle_disarm_cancel("new kill activity");
    // Round 13: the comm hard-stop that used to stand here was REMOVED as
    // redundant — it was the second of three identical allproc walks per kill
    // (procmgr_kill checks before its own kill(); pmForceKillViaLaunchdGated
    // checks again AFTER pm_kill_lock, which is the only check that cannot go
    // stale behind a queued warm-up, and it fires for every dispatch including
    // the session-rebuild retry). One full proc-list walk (~2 kreads/proc)
    // saved per kill; fail-closed semantics unchanged.
    if (!kexploit_krw_ready()) return -2;
    // Round 41: wait out the activation settle window BEFORE taking
    // pm_kill_lock. The round-39 wait lived inside pmForceKillViaLaunchdGated
    // — UNDER the lock — so one kill's multi-second settle usleep serialized
    // every other kill (and the backgrounding teardown) behind it. Same bail
    // semantics: backgrounding mid-wait aborts the kill (nothing signalled).
    // pmForceKillViaLaunchdGated re-checks under the lock and fail-fasts if
    // a fresh activation re-extended the window in the gap.
    uint64_t settleUntil = g_activation_settle_until_ns;
    uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (settleUntil > nowNs) {
        printf("[PROCMGR] fastkill: kill(%d) deferred ~%llu ms — activation "
               "settle window, waited OUTSIDE pm_kill_lock (launchd-hijack ⇄ "
               "task_policy_set strand avoidance)\n",
               pid, (unsigned long long)((settleUntil - nowNs) / 1000000ULL));
        while ((nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) < settleUntil) {
            if (g_app_in_background || excport_gate_blocked()) {
                printf("[PROCMGR] fastkill: kill(%d) aborted — app backgrounding "
                       "during settle wait; not arming launchd\n", pid);
                return -2;
            }
            usleep(100000);   // 100 ms, re-checking the bail conditions
        }
    }
    NSLock *lock = pm_kill_lock();
    // Round 7: if another kill's warm-up is in flight, ATTACH to it — wait on
    // pm_kill_lock once and use its result — rather than stacking a second
    // hijack behind it. gPMWarmupInFlight is 0 or 1 by construction (every
    // warm-up runs under this lock).
    BOOL attachToInflight = (__sync_add_and_fetch(&gPMWarmupInFlight, 0) > 0);
    if (attachToInflight)
        printf("[PROCMGR] fastkill: warm-up in flight — kill(%d) attaches to it "
               "(waits once; no second hijack stacked)\n", pid);
    [lock lock];
    if (attachToInflight)
        printf("[PROCMGR] fastkill: in-flight warm-up finished — kill(%d) uses %s\n",
               pid, gPMKillSession ? "the warmed session"
                                   : "no session (warm-up failed; warming now)");
    int rc = [self pmForceKillViaLaunchdLocked:pid expectedName:expectedName expectedKproc:expectedKproc
                                  allowRebuild:YES];
    [lock unlock];
    // Round 46: whenever the session stays warm after a kill, schedule the
    // foreground idle disarm so the trapped launchd thread + armed KRW
    // exposure is shed after 10 idle seconds instead of persisting until
    // backgrounding. This used to require rc == 0, so a failed kill (-8,
    // e.g. an inconclusive verdict) that kept the session had NO deadline --
    // and the kill itself had cancelled the previous one. Every exit that
    // keeps gPMKillSession gets one now; a torn-down session (nil) needs none.
    if (gPMKillSession)
        pm_idle_disarm_schedule();
    return rc;
}

@end

@interface ThemerFormatGuideViewController : UITableViewController
@end

@implementation ThemerFormatGuideViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Theme Format";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 2 ? 3 : 1;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return CYSectionHeaderView(@"Folder Theme");
        case 1: return CYSectionHeaderView(@"Plist Theme");
        case 2: return CYSectionHeaderView(@"Files");
        default: return nil;
    }
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return 46.0; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0) {
        return @"Only icons with matching bundle IDs change. Missing apps keep their stock icon.";
    }
    if (section == 1) {
        return @"Use a binary plist when you want one portable file instead of a folder of PNGs.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"guide"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"guide"];
        cell.detailTextLabel.numberOfLines = 0;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    if (indexPath.section == 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = @"PNG Files";
        cell.detailTextLabel.text =
            @"Make a folder containing PNG files named by app bundle ID:\n"
             "com.apple.mobilesafari.png\n"
             "com.apple.MobileSMS.png\n"
             "com.apple.mobiletimer.png";
    } else if (indexPath.section == 1) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = @"Bundle ID → PNG Data";
        cell.detailTextLabel.text =
            @"Make a dictionary plist. Each key is a bundle ID. Each value is raw PNG data. "
             "Cyanide imports the plist and copies it into Documents/Themes.";
    } else {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Share Sample Theme Plist";
            cell.detailTextLabel.text = @"Exports a small binary plist template with example bundle IDs.";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Share iOS 6 Theme Plist";
            cell.detailTextLabel.text = @"Exports the iOS 6 Theme plist. Icons by zagnut531/iOS-6-Icons.";
        } else {
            cell.textLabel.text = @"Share App Info.plist";
            cell.detailTextLabel.text = @"Exports Cyanide's bundled Info.plist for reference.";
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (NSData *)sampleIconPNGWithText:(NSString *)text color:(UIColor *)color
{
    CGSize size = CGSizeMake(120.0, 120.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size
                                                                               format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0.0, 0.0, size.width, size.height);
        [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:27.0] addClip];
        [color setFill];
        UIRectFill(rect);

        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:48.0 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: UIColor.whiteColor,
        };
        CGSize textSize = [text sizeWithAttributes:attrs];
        CGRect textRect = CGRectMake((size.width - textSize.width) / 2.0,
                                     (size.height - textSize.height) / 2.0,
                                     textSize.width,
                                     textSize.height);
        [text drawInRect:textRect withAttributes:attrs];
    }];
    return UIImagePNGRepresentation(image);
}

- (NSURL *)writeSamplePlist:(NSError **)error
{
    NSData *safari = [self sampleIconPNGWithText:@"S"
                                           color:[UIColor colorWithRed:0.05 green:0.45 blue:0.95 alpha:1.0]];
    NSData *sms = [self sampleIconPNGWithText:@"M"
                                        color:[UIColor colorWithRed:0.10 green:0.65 blue:0.25 alpha:1.0]];
    NSDictionary *plist = @{
        @"com.apple.mobilesafari": safari ?: [NSData data],
        @"com.apple.MobileSMS": sms ?: [NSData data],
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:error];
    if (!data) return nil;

    NSURL *url = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"CyanideThemeTemplate.plist"]];
    if (![data writeToURL:url options:NSDataWritingAtomic error:error]) return nil;
    return url;
}

- (NSURL *)copyBuiltInIOS6Plist:(NSError **)error
{
    NSString *src = [[NSBundle mainBundle] pathForResource:@"Themes-iOS6" ofType:@"plist"];
    if (!src) {
        if (error) {
            *error = [NSError errorWithDomain:@"CyanideThemerGuide"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Bundled iOS 6 plist was not found."}];
        }
        return nil;
    }

    NSURL *dst = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"Cyanide-iOS6-Theme.plist"]];
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:dst.path]) {
        [fm removeItemAtURL:dst error:nil];
    }
    if (![fm copyItemAtURL:[NSURL fileURLWithPath:src] toURL:dst error:error]) return nil;
    return dst;
}

- (NSURL *)copyAppInfoPlist:(NSError **)error
{
    NSString *src = [[NSBundle mainBundle] pathForResource:@"Info" ofType:@"plist"];
    if (!src) {
        if (error) {
            *error = [NSError errorWithDomain:@"CyanideThemerGuide"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Bundled Info.plist was not found."}];
        }
        return nil;
    }

    NSURL *dst = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"Cyanide-Info.plist"]];
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:dst.path]) {
        [fm removeItemAtURL:dst error:nil];
    }
    if (![fm copyItemAtURL:[NSURL fileURLWithPath:src] toURL:dst error:error]) return nil;
    return dst;
}

- (void)dismissGuide
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)shareURL:(NSURL *)url sourceView:(UIView *)sourceView
{
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                     applicationActivities:nil];
    UIView *anchor = sourceView ?: self.view;
    vc.popoverPresentationController.sourceView = anchor;
    vc.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)showExportError:(NSError *)error
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Export Failed"
                                                                message:error.localizedDescription ?: @"Could not write the plist."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 2) return;

    NSError *error = nil;
    NSURL *url = nil;
    if (indexPath.row == 0) {
        url = [self writeSamplePlist:&error];
    } else if (indexPath.row == 1) {
        url = [self copyBuiltInIOS6Plist:&error];
    } else {
        url = [self copyAppInfoPlist:&error];
    }
    if (!url) {
        [self showExportError:error];
        return;
    }

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    [self shareURL:url sourceView:cell.contentView ?: tableView];
}

@end

@implementation SettingsViewController

// Init-watchdog wedge (RemoteCall.m): an injection deadlocked uninterruptibly
// and was aborted externally. The app is safe, but no new injection channel
// can open in this session — and because the wedged thread belongs to a
// system process, the device will usually follow with a hardware-watchdog
// reset within ~2 minutes. Tell the user the truth and offer the guided app
// restart: park the KRW filter (idempotent, takes no locks — the wedged run
// worker may still hold the actions lock, so the full terminal-cleanup path
// is NOT safe here) and exit; the leaked KRW sockets survive by design and
// re-park on next launch.
- (void)remoteCallInitWedged:(NSNotification *)note
{
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Injection wedged — restart the iPhone soon"
                             message:@"A SpringBoard/launchd injection deadlocked and the init watchdog aborted it cleanly. Cyanide is safe — but the stuck system-process thread cannot be recovered, so the device will very likely reboot on its own within ~2 minutes.\n\nSave anything open and restart the iPhone proactively; a controlled reboot beats the watchdog's. Then relaunch Cyanide (no new injection channels can open in this session)."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Restart Cyanide"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
            (void)action;
            settings_park_krw_filter_for_background();
            exit(0);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Later"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

+ (BOOL)liveWPHasSelectedVideo
{
    NSString *path = livewp_absolute_path();
    if (path.length == 0) return NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (NSArray<NSDictionary *> *)quickLoaderRows {
    self.qlStandalone = self.quickLoaderStandalone;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    if (!self.qlStandalone && !self.qlRawScript && [d stringForKey:@"QuickLoaderSourceRawJS"]) {
        self.qlScriptName = [d stringForKey:@"QuickLoaderSourceScriptName"];
        self.qlRawScript = [d stringForKey:@"QuickLoaderSourceRawJS"];

        self.qlValues = settings_string_values_dictionary([d dictionaryForKey:@"QuickLoaderSourceValues"]);

        NSMutableArray *params = [NSMutableArray array];
        NSArray *lines = [self.qlRawScript componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            if ([line containsString:@"@param:"]) {
                NSArray *parts = [line componentsSeparatedByString:@"|"];
                if (parts.count >= 4) {
                    NSArray *typeParts = [parts[0] componentsSeparatedByString:@"@param:"];
                    if (typeParts.count < 2) continue;
                    NSString *rawType = typeParts[1];
                    NSString *type = [rawType stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *varName = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *label = [parts[2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *defValue = [parts[3] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (!settings_js_identifier_valid(varName)) continue;

                    // saving default to dictionary
                    NSMutableDictionary *paramDict = [NSMutableDictionary dictionaryWithDictionary:@{
                        @"type": type, @"varName": varName, @"label": label, @"default": defValue
                    }];

                    // extracting min-max values for slider
                    if (parts.count >= 5 && ([type isEqualToString:@"slider"] || [type isEqualToString:@"number"])) {
                        NSString *rangeStr = [parts[4] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        NSArray *rangeParts = [rangeStr componentsSeparatedByString:@"-"];
                        if (rangeParts.count == 2) {
                            paramDict[@"min"] = rangeParts[0];
                            paramDict[@"max"] = rangeParts[1];
                        }
                    }

                    [params addObject:paramDict];

                    //if new, it loads the default values
                    if (!self.qlValues[varName]) {
                        self.qlValues[varName] = defValue;
                    }
                }
            }
        }
        self.qlParams = params;
    }

    NSMutableArray *rows = [NSMutableArray array];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *filename;
    BOOL enabled;
    if (self.qlStandalone) {
        filename = self.qlScriptName;
        enabled = NO;
    } else {
        filename = self.qlScriptName ?: [ud stringForKey:@"QuickLoaderSourceScriptName"];
        enabled = [ud boolForKey:kSettingsQuickLoaderEnabled];
    }
    BOOL hasRepoTweak = !self.qlStandalone && [ud stringForKey:@"QuickLoaderSourceRepoURL"].length > 0;
    BOOL applied = enabled && settings_tweak_is_applied(kSettingsQuickLoaderEnabled);

    if (filename) {
        NSString *source = hasRepoTweak ? @"From source repo" : @"Local file";
        [rows addObject:@{ @"kind": @"ql-loaded",
                           @"title": filename,
                           @"subtitle": source,
                           @"enabled": @(enabled) }];
    } else {
        [rows addObject:@{ @"kind": @"ql-empty" }];
    }

    if (self.qlParams.count > 0) {
        for (NSDictionary *param in self.qlParams) {
            NSMutableDictionary *rowDict = [NSMutableDictionary dictionaryWithDictionary:@{
                @"kind": @"ql-param",
                @"paramType": param[@"type"],
                @"varName": param[@"varName"],
                @"title": param[@"label"],
                @"default": param[@"default"]
            }];
            if (param[@"min"]) rowDict[@"min"] = param[@"min"];
            if (param[@"max"]) rowDict[@"max"] = param[@"max"];
            [rows addObject:rowDict];
        }
    }

    if (self.qlStandalone) {
        if (filename) {
            [rows addObject:@{ @"kind": @"button", @"action": @"quickloader-run-now",
                               @"title": @"Run Tweak", @"style": @"prominent" }];
        }
    } else {
        if (filename && !enabled) {
            [rows addObject:@{ @"kind": @"button", @"action": @"quickloader-apply-dynamic",
                               @"title": @"Activate Tweak", @"style": @"prominent" }];
        } else if (filename && enabled && !applied) {
            [rows addObject:@{ @"kind": @"button", @"action": @"quickloader-apply-dynamic",
                               @"title": @"Queued — Run Apply Tweaks" }];
        } else if (filename && enabled) {
            [rows addObject:@{ @"kind": @"button", @"action": @"quickloader-apply-dynamic",
                               @"title": @"Re-run Tweak" }];
        }
    }

    [rows addObject:@{ @"kind": @"button", @"action": @"quickloader-run-js", @"title": @"Select .js File" }];
    [rows addObject:@{ @"kind": @"button", @"action": @"quickloader-open-sources", @"title": @"Browse Sources" }];

    if (filename) {
        [rows addObject:@{ @"kind": @"button", @"action": @"quickloader-clear",
                           @"title": @"Clear Loaded Tweak", @"destructive": @YES }];
    }

    return rows;
}



- (instancetype)initWithCoder:(NSCoder *)coder
{
    // Calling [super initWithCoder:] (not initWithStyle:) so UIViewController's
    // unarchiving runs: that's what wires up the parentViewController and
    // navigationController relationships established by the storyboard's
    // rootViewController segue. Going through initWithStyle leaves nav nil.
    if ((self = [super initWithCoder:coder])) {
        _underlyingSection = NSIntegerMax;
    }
    return self;
}

- (instancetype)initWithUnderlyingSection:(NSInteger)underlyingSection
                              bundleTitle:(NSString *)bundleTitle
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _detailMode = YES;
        _underlyingSection = underlyingSection;
        _bundleTitle = [bundleTitle copy];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.detailMode ? (self.bundleTitle ?: @"Settings") : @"Settings";
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    self.tableView.rowHeight                      = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight             = 44.0;
    self.tableView.sectionHeaderHeight            = UITableViewAutomaticDimension;
    self.tableView.estimatedSectionHeaderHeight   = 20.0;
    self.tableView.sectionFooterHeight            = UITableViewAutomaticDimension;
    self.tableView.estimatedSectionFooterHeight   = 10.0;
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0.0;
    }
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"toggle"];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"stepper"];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"slider"];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"segmented"];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"action"];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"button"];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"warning"];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"bundle"];
    [self installInstallerReturnButtonIfNeeded];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(remoteCallStateDidChange:)
                                                 name:kSettingsRemoteCallStateDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(cleanupStateDidChange:)
                                                 name:kSettingsCleanupStateDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(remoteCallInitWedged:)
                                                 name:kRemoteCallInitWedgedNotification
                                               object:nil];

    // Match the other tabs (Home, Packages, Sources): the Settings root shows a
    // standard large title. Pushed bundle-detail pages keep the small inline title.
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.largeTitleDisplayMode = self.detailMode
        ? UINavigationItemLargeTitleDisplayModeNever
        : UINavigationItemLargeTitleDisplayModeAlways;
    // No nav-bar Respring button: the Actions section already has a Respring row,
    // and two respring controls on one page is redundant.
}

- (void)presentRespringPromptWithTitle:(NSString *)title message:(NSString *)message
{
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:title
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Later"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Respring"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *_) {
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            if (__sync_lock_test_and_set(&g_settings_actions_running, 1)) {
                printf("[SETTINGS] respring blocked: actions already running\n");
                return;
            }
            __sync_lock_test_and_set(&g_settings_respring_cleanup_running, 1);
            settings_notify_cleanup_state_changed();
            @try {
                settings_prepare_for_respring_sync();
            } @finally {
                __sync_lock_release(&g_settings_actions_running);
                __sync_lock_release(&g_settings_respring_cleanup_running);
                settings_notify_cleanup_state_changed();
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                settings_show_respring_overlay(strongSelf);
            });
        });
    }]];
    settings_present_controller(ac, self);
}

- (void)runLockScreenDurationApply:(BOOL)remove
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    long long seconds = remove ? 0 : settings_lock_duration_value(d);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        log_user("[LSD] %s lock screen duration%s.\n",
                 remove ? "Removing" : "Applying",
                 remove ? "" : "");
        BOOL ok = settings_apply_lock_screen_duration(seconds);
        printf("[SETTINGS] lock duration %s result=%d value=%lld\n",
               remove ? "remove" : "apply", ok, seconds);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!ok) {
                UIAlertController *err = [UIAlertController
                    alertControllerWithTitle:@"Lock Screen Duration"
                                     message:@"Could not write the setting. Run the chain first, then try again."
                              preferredStyle:UIAlertControllerStyleAlert];
                [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                settings_present_controller(err, strongSelf);
                return;
            }
            NSString *msg = remove
                ? @"Lock screen duration cleared. Respring now to apply?"
                : [NSString stringWithFormat:@"Lock screen will stay awake for %lld seconds. Respring now to apply?", seconds];
            [strongSelf presentRespringPromptWithTitle:@"Applied" message:msg];
        });
    });
}

- (void)runLockScreenDurationRead
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        long long v = settings_read_lock_screen_duration();
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSString *msg;
            if (v == -3)      msg = @"Another action is running. Try again in a moment.";
            else if (v == -2) msg = @"Kernel access isn't active. Run the chain first, then try again.";
            else if (v < 0)   msg = @"Could not read the value — the SpringBoard channel wasn't available.";
            else if (v == 0)  msg = @"No floor is set — the lock screen uses stock timing.";
            else              msg = [NSString stringWithFormat:
                @"Configured floor: %lld seconds.\n\nThis is the value written to SpringBoard (SBMinimumLockscreenIdleTime). It takes effect after a respring.", v];
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:@"Lock Screen Duration"
                                 message:msg
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            settings_present_controller(ac, strongSelf);
        });
    });
}

- (void)runOTAStatusRead
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        int st = settings_read_ota_status();
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSString *msg;
            if (st == -3)      msg = @"Another action is running. Try again in a moment.";
            else if (st == -2) msg = @"Kernel access isn't active. Run the chain first, then try again.";
            else if (st < 0)   msg = @"Could not read OTA status — filesystem access was denied.";
            else if (st == 0)  msg = @"OTA updates are ENABLED (stock). The update daemons are not blocked.";
            else if (st == 1)  msg = @"OTA updates are DISABLED. All update daemons are blocked in launchd.";
            else               msg = @"OTA updates are PARTIALLY disabled — some update daemons are blocked but not all. Tap “Disable OTA Updates” to finish.";
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:@"OTA Updates"
                                 message:msg
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            settings_present_controller(ac, strongSelf);
        });
    });
}

- (void)cleanupStateDidChange:(NSNotification *)note
{
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

// Index of the tab whose item title matches `title`, or NSNotFound when no tab
// carries that title. Tab titles are the only handle these entries have on the
// tab a package's controls were opened from.
static NSUInteger settings_tab_index_for_title(UITabBarController *tab, NSString *title)
{
    if (title.length == 0) return NSNotFound;
    for (NSUInteger i = 0; i < tab.viewControllers.count; i++) {
        if ([tab.viewControllers[i].tabBarItem.title isEqualToString:title]) return i;
    }
    return NSNotFound;
}

- (void)installInstallerReturnButtonIfNeeded
{
    // Package controls label the button with the package name; QuickLoader has
    // no package, so it falls back to the tab it was opened from.
    NSString *label = self.installerReturnPackageName.length > 0
        ? self.installerReturnPackageName
        : self.installerReturnTabTitle;
    if (label.length == 0) return;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightSemibold];
    UIImage *chevron = [UIImage systemImageNamed:@"chevron.backward" withConfiguration:cfg];
    [btn setImage:chevron forState:UIControlStateNormal];
    [btn setTitle:[@" " stringByAppendingString:label] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightRegular];
    btn.tintColor = settings_cell_tint_color(self.view);
    btn.contentEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 4);
    [btn addTarget:self action:@selector(returnToInstaller) forControlEvents:UIControlEventTouchUpInside];
    [btn sizeToFit];

    UIBarButtonItem *backItem = [[UIBarButtonItem alloc] initWithCustomView:btn];
    self.navigationItem.leftBarButtonItem = backItem;
    self.navigationItem.hidesBackButton = YES;
}

- (void)returnToInstaller
{
    UITabBarController *tab = self.tabBarController;
    UINavigationController *settingsNav = self.navigationController;

    // Prefer the tab the package controls were opened from. Sources pushes the
    // same Settings bundle as Packages, and always unwinding to Packages
    // dropped those users out of the browse path they were in.
    NSUInteger installerIdx = settings_tab_index_for_title(tab, self.installerReturnTabTitle);
    if (installerIdx == NSNotFound) installerIdx = settings_tab_index_for_title(tab, @"Packages");
    if (installerIdx == NSNotFound) installerIdx = settings_tab_index_for_title(tab, @"Installer");

    // Switch tabs; unwind the Settings stack later, from viewDidDisappear.
    //
    // Both have to happen, and any attempt to time the unwind against the tab
    // switch shows the Settings root for a frame -- it gets laid out and
    // composited before the tab swap is drawn. Popping first, popping after,
    // and deferring the pop by one runloop turn were all tried; recording the
    // transition at 59 fps caught the flash in each of them on at least one
    // iOS version.
    //
    // So stop guessing when the view is off screen and let UIKit say so.
    // viewDidDisappear: runs once this controller is genuinely out of the
    // hierarchy, which is exactly the condition the pop needs, on every
    // version. The stack still has to be unwound -- otherwise tapping Settings
    // later lands back on the package's controls -- just not while anyone can
    // see it.
    if (installerIdx == NSNotFound) {
        // No installer tab to switch to; nothing will hide us, so pop now.
        [settingsNav popToRootViewControllerAnimated:NO];
        return;
    }

    // Some entries ask for the target tab's front page instead of wherever that
    // tab was left (the Home QuickLoader row returns to the Sources front page).
    // Reset it before switching: it is off screen now, so this cannot flash.
    if (self.installerReturnResetsTargetTab) {
        UIViewController *target = tab.viewControllers[installerIdx];
        if ([target isKindOfClass:UINavigationController.class]) {
            [(UINavigationController *)target popToRootViewControllerAnimated:NO];
        }
    }

    self.unwindSettingsStackWhenHidden = YES;
    tab.selectedIndex = installerIdx;
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (!self.unwindSettingsStackWhenHidden) return;
    self.unwindSettingsStackWhenHidden = NO;

    // Capture before popping: this controller leaves the stack here, and
    // self.navigationController is nil afterwards.
    UINavigationController *nav = self.navigationController;
    [nav popToRootViewControllerAnimated:NO];
}

- (void)selectBottomTabNamed:(NSString *)title
{
    UITabBarController *tab = self.tabBarController;
    if (![tab isKindOfClass:UITabBarController.class]) return;
    for (NSUInteger i = 0; i < tab.viewControllers.count; i++) {
        UIViewController *vc = tab.viewControllers[i];
        if ([vc.tabBarItem.title isEqualToString:title]) {
            tab.selectedIndex = i;
            return;
        }
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // UIKit normally restores the presenting view's tint when a modal closes,
    // but an interrupted presentation can leave the mode Dimmed, and a dimmed
    // view renders every tint-derived colour desaturated. Re-arm it here, at
    // the point where this view is guaranteed to be uncovered again.
    self.view.tintAdjustmentMode = UIViewTintAdjustmentModeAutomatic;
    [self reloadManualActions];

    // The NanoRegistry plist lives behind a sandbox wall on-device. Keep the
    // detail panel passive; the explicit "Load Current" button performs the
    // privileged KRW/sandbox setup before reading it.
    if (self.detailMode && self.underlyingSection == SectionNanoRegistry) {
        if (self.isViewLoaded) {
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                          withRowAnimation:UITableViewRowAnimationNone];
        }
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self presentPowercuffNominalNoticeIfNeeded];
    if (!self.pendingManualActionsReload) return;
    self.pendingManualActionsReload = NO;
    [self reloadManualActions];
}

- (void)presentPowercuffNominalNoticeIfNeeded
{
    if (!self.detailMode || self.underlyingSection != SectionPowercuff) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d boolForKey:kSettingsPowercuffNominalNoticeShown]) return;

    NSString *level = [d stringForKey:kSettingsPowercuffLevel] ?: @"nominal";
    BOOL alreadyNominal = [level isEqualToString:@"nominal"];
    NSString *message = @"Powercuff now defaults to Nominal.\n\nLight, Moderate, and Heavy intentionally underclock the CPU. That means lag or slower app launches can happen, especially on older devices. The lag means Powercuff is working, but those levels may be too slow for comfortable day-to-day use.\n\nUse Nominal for daily use, then raise it only when you want stronger throttling.";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Powercuff Level"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (!alreadyNominal) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Use Nominal"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults setObject:@"nominal" forKey:kSettingsPowercuffLevel];
            [defaults setBool:YES forKey:kSettingsPowercuffNominalNoticeShown];
            [defaults synchronize];
            [weakSelf.tableView reloadData];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:alreadyNominal ? @"OK" : @"Keep Current"
                                             style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *_) {
        [d setBool:YES forKey:kSettingsPowercuffNominalNoticeShown];
        [d synchronize];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)remoteCallStateDidChange:(NSNotification *)notification
{
    [self reloadManualActions];
}

- (void)reloadManualActions
{
    if (!self.isViewLoaded) return;
    if (self.detailMode) return;
    if (!self.tableView.window) {
        self.pendingManualActionsReload = YES;
        return;
    }

    NSIndexSet *sections = [NSIndexSet indexSetWithIndex:RootSectionActions];
    [UIView performWithoutAnimation:^{
        [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
        [self.tableView layoutIfNeeded];
    }];
}

- (UITableViewCell *)buildWarningCell:(UITableViewCell *)cell
{
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = nil;
    for (UIView *v in [cell.contentView.subviews copy]) [v removeFromSuperview];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"info.circle.fill"]];
    icon.tintColor = UIColor.systemOrangeColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [icon setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *label = [[UILabel alloc] init];
    label.text = @"Cyanide is a limited tweak environment. Session tweaks reset on reboot, while a few packages intentionally modify local system files and may persist until restored. Backups are best-effort only. Use these tools only where you have permission, understand the legal and service-rule impact, and accept the risk. Live tweaks like StatBar and Axon Lite stop if you force-quit Cyanide. A progress log opens while changes apply; tap Hide to dismiss.";
    label.textColor = UIColor.labelColor;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;

    [cell.contentView addSubview:icon];
    [cell.contentView addSubview:label];
    UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor   constraintEqualToAnchor:m.leadingAnchor],
        [icon.centerYAnchor   constraintEqualToAnchor:label.centerYAnchor],
        [icon.widthAnchor     constraintEqualToConstant:22],
        [icon.heightAnchor    constraintEqualToConstant:22],
        [label.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:10],
        [label.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [label.topAnchor      constraintEqualToAnchor:m.topAnchor constant:4],
        [label.bottomAnchor   constraintEqualToAnchor:m.bottomAnchor constant:-4],
    ]];
    return cell;
}

#pragma mark - Row models

- (NSArray<NSDictionary *> *)launchRows
{
    BOOL autoRetryOn = [NSUserDefaults.standardUserDefaults boolForKey:kSettingsRunAutoRetry];
    NSArray<NSDictionary *> *rows = @[
        @{ @"kind": @"a18path", @"key": kSettingsA18ExploitPath, @"a18Only": @YES, @"title": @"A18 exploit path" },
        @{ @"key": kSettingsA18Interleave, @"peV1Only": @YES, @"a18Only": @YES, @"title": @"A18 interleaved search",
           @"subtitle": @"Experimental. On interleaves the socket spray with search-mapping allocation and scans each mapping tail-first, aiming to find the PCB in fewer reads. Off uses the proven bulk-spray + forward-scan path. A18/M4 only; effective on the next fresh chain run." },
        @{ @"kind": @"a18shape", @"key": kSettingsA18MemoryShaping, @"peV1Only": @YES, @"a18Only": @YES, @"title": @"A18 memory shaping" },
        @{ @"key": kSettingsA18BoundedSearch, @"peV1Only": @YES, @"a18Only": @YES, @"title": @"A18 bounded search",
           @"subtitle": @"On stops after 4 search passes and reports a clean retry instead of grinding — which can otherwise end in an aperture panic on a device that never lands the PCB. Off (default, matches 1.5.5) grinds until the exploit acquires. A18/M4 only; effective on the next fresh chain run." },
        @{ @"key": kSettingsRunAutoRetry, @"title": @"Auto-retry failed chain runs",
           @"subtitle": @"On re-runs the chain automatically when the exploit misses, up to the attempt cap below — the progress screen just keeps spinning until it lands or the cap is hit. Never retries a wedged injection. Every attempt is an independent panic dice roll, so the cap bounds your exposure per tap." },
        @{ @"kind": @"stepper", @"key": kSettingsRunAutoRetryMaxAttempts, @"title": @"Auto-retry attempt cap",
           @"min": @1, @"max": @20, @"default": @8, @"disabled": @(!autoRetryOn),
           @"subtitle": @"Maximum automatic re-runs after the first miss. Enable Auto-retry failed chain runs to change this." },
        @{ @"key": kRemoteCallControlledPanicOnWedge, @"title": @"Controlled panic on injection wedge",
           @"subtitle": @"Diagnostic. When an injection wedges, the stuck system-process thread dooms the device to a hardware-watchdog reset within ~2 minutes — which can leave no panic log at all. On instead flushes the log and panics the kernel immediately via KRW: the reboot is instant and always writes a panic-full stamped with the CYANIDE signature address 0x4359414e494445xx. Off keeps the standard abort + restart flow." },
        @{ @"kind": @"settlemode", @"key": kSettingsRemoteSettleMode, @"title": @"Tweak apply speed" },
        @{ @"key": kSettingsVerboseLoggingEnabled, @"title": @"Verbose logging",
           @"subtitle": @"Logs the full RemoteCall internals for every exploit run, tweak apply and Process Viewer action. Off keeps the log readable; turn it on before reproducing an issue, then share the log." },
        @{ @"key": kSettingsAutoRunKexploit,    @"title": @"Auto-run kexploit on launch" },
        @{ @"key": kSettingsRunSandboxEscape,   @"title": @"Sandbox escape (escape_sbx_demo2)" },
        @{ @"key": kSettingsLocationServicesLinksEnabled, @"title": @"Location Services links",
           @"subtitle": @"Lets cyanide://location-services links turn Location Services on or off. Any app can open these links without asking, so this is off by default. The Control Center toggle and the Shortcuts action work without it." },
        @{ @"key": kRepoSourcesEnabledKey,      @"title": @"Repo sources",
           @"subtitle": @"Off hides the Sources tab and repo packages, stops refreshing sources, and skips repo tweaks when applying (running ones are stopped). Local QuickLoader .js files still work." },
        @{ @"key": kSettingsKeepAlive,          @"title": @"Keep app alive in background",
           @"subtitle": @"Required for app-driven live tweaks to persist while minimized, including StatBar receiving fresh live data." },
    ];
    // A18/M4-only options (exploit path, interleave, shaping, bounded) are
    // meaningless on other hardware -- pe_v1 standard geometry always runs there.
    // Hide them entirely off-family (A18/A18 Pro/M4 and above).
    if (settings_device_is_a18_above()) return rows;
    NSMutableArray<NSDictionary *> *filtered = [NSMutableArray array];
    for (NSDictionary *r in rows)
        if (![r[@"a18Only"] boolValue]) [filtered addObject:r];
    return filtered;
}

// The master enable / install-equivalent rows have been removed from each
// tweak's row list — install/uninstall is handled by the Installer tab's
// Install button. Settings only shows configuration knobs.

- (NSArray<NSDictionary *> *)sbcRows
{
    // Show dock labels is unavailable while Hide icon labels is on: the dock
    // follows the home screen, so offering the switch would promise something
    // the run will not do.
    BOOL hidingLabels = [NSUserDefaults.standardUserDefaults boolForKey:kSettingsSBCHideLabels];
    return @[
        @{ @"kind": @"stepper", @"key": kSettingsSBCDockIcons,  @"title": @"Dock icons", @"min": @4, @"max": @7, @"default": @(kSBCDefaultDockIcons) },
        @{ @"kind": @"toggle",  @"key": kSettingsSBCAutoDockApp, @"title": @"Auto-add selected app to Dock",
           @"subtitle": @"Moves the selected Home Screen app into a newly available Dock slot when SBCustomizer is applied." },
        @{ @"kind": @"text",    @"key": kSettingsSBCDockAppBundleID, @"title": @"Dock app bundle ID",
           @"placeholder": kSBCDefaultDockAppBundleID,
           @"subtitle": @"Defaults to the Watusi WhatsApp duplicate." },
        @{ @"kind": @"stepper", @"key": kSettingsSBCCols,       @"title": @"Home columns", @"min": @3, @"max": @7, @"default": @(kSBCDefaultCols) },
        @{ @"kind": @"stepper", @"key": kSettingsSBCRows,       @"title": @"Home rows", @"min": @4, @"max": @8, @"default": @(kSBCDefaultRows) },
        @{ @"kind": @"toggle",  @"key": kSettingsSBCHideLabels, @"title": @"Hide icon labels" },
        @{ @"kind": @"toggle",  @"key": kSettingsSBCDockLabels, @"title": @"Show dock labels",
           @"disabled": @(hidingLabels),
           @"subtitle": @"Draws app names under the dock icons, which stock iOS leaves off. Unavailable while Hide icon labels is on \u2014 the dock follows the home screen." },
        @{ @"kind": @"toggle",  @"key": kSettingsSBCArrangePages, @"title": @"Arrange icons by page" },
        @{ @"kind": @"stepper", @"key": kSettingsSBCFirstPageIcons, @"title": @"First page icons", @"min": @12, @"max": @49, @"default": @(kSBCDefaultFirstPageIcons) },
        @{ @"kind": @"stepper", @"key": kSettingsSBCOtherPageIcons, @"title": @"Other page icons", @"min": @12, @"max": @49, @"default": @(kSBCDefaultOtherPageIcons) },
        @{ @"kind": @"button",  @"title": @"Reset to Defaults" },
    ];
}

- (NSArray<NSDictionary *> *)powercuffRows
{
    return @[
        @{ @"kind": @"segmented", @"key": kSettingsPowercuffLevel,   @"title": @"Level" },
    ];
}

- (NSArray<NSDictionary *> *)otaRows
{
    return @[
        @{ @"kind": @"button", @"title": @"Disable OTA Updates" },
        @{ @"kind": @"button", @"title": @"Enable OTA Updates" },
        @{ @"kind": @"button", @"title": @"Read Current Status",
           @"requiresKRW": @YES },
    ];
}

- (NSArray<NSDictionary *> *)nanoRegistryRows
{
    return @[
        @{ @"kind": @"stepper",
           @"key": kSettingsNanoMaxPairing,
           @"title": @"watchOS Pairing Limit",
           @"subtitle": @"Highest watchOS pairing generation this iPhone will accept. 99 raises the phone-side ceiling for newer watchOS releases.",
           @"min": @(kNanoUIRowMin),
           @"max": @(kNanoUIRowMax),
           @"default": @(kNanoDefaultMaxPairing) },

        @{ @"kind": @"stepper",
           @"key": kSettingsNanoMinPairing,
           @"title": @"Setup Protocol Floor",
           @"subtitle": @"Lowest pairing setup generation this iPhone will accept. Keep this at 23 so generation-23 setup messages are not rejected.",
           @"min": @(kNanoUIRowMin),
           @"max": @(kNanoUIRowMax),
           @"default": @(kNanoDefaultMinPairing) },

        @{ @"kind": @"stepper",
           @"key": kSettingsNanoMinPairingChipID,
           @"title": @"Legacy Chip Floor",
           @"subtitle": @"Leave this alone unless you are trying to pair an old S-chip watch, such as a Series 3.",
           @"min": @(kNanoUIRowMin),
           @"max": @(kNanoUIRowMax),
           @"default": @(kNanoDefaultMinPairingChipID) },

        @{ @"kind": @"stepper",
           @"key": kSettingsNanoMinQuickSwitch,
           @"title": @"Multi-Watch Switching",
           @"subtitle": @"Leave this alone unless switching between multiple older paired watches is not working.",
           @"min": @(kNanoUIRowMin),
           @"max": @(kNanoUIRowMax),
           @"default": @(kNanoDefaultMinQuickSwitch) },

        @{ @"kind": @"button",
           @"title": @"Load Saved Override",
           @"action": @"nano-load" },

        @{ @"kind": @"button",
           @"title": @"Use watchOS Range 99/23/10/6",
           @"action": @"nano-preset-newer" },

        @{ @"kind": @"button",
           @"title": @"Apply Pairing Override",
           @"action": @"nano-apply" },

        @{ @"kind": @"button",
           @"title": @"Remove Override",
           @"action": @"nano-clear",
           @"destructive": @YES },
    ];
}

- (NSArray<NSDictionary *> *)darkSwordTweakRows
{
    return @[];
}

- (NSArray<NSDictionary *> *)lockScreenDurationRows
{
    return @[
        @{ @"kind": @"number",
           @"key": kSettingsLockDurationValue,
           @"title": @"Duration",
           @"subtitle": @"Seconds the lock screen stays awake before it dims and sleeps, while you read notifications. Separate from Settings > Auto-Lock. Default 60, min 5, max 3600. Face ID gaze can keep it on longer.",
           @"min": @(kSettingsLockDurationMin),
           @"max": @(kSettingsLockDurationMax),
           @"step": @1, @"unit": @"s",
           @"default": @(kSettingsLockDurationDefault) },
        @{ @"kind": @"button", @"action": @"lockdur-apply",
           @"title": @"Apply Lock Screen Duration",
           @"subtitle": @"Writes the value and offers a respring to apply it." },
        @{ @"kind": @"button", @"action": @"lockdur-remove",
           @"title": @"Remove (restore stock)",
           @"subtitle": @"Clears the floor; offers a respring to apply." },
        @{ @"kind": @"button", @"action": @"lockdur-read",
           @"title": @"Read Current Value",
           @"requiresKRW": @YES,
           @"subtitle": @"Shows the floor currently written in SpringBoard. "
                        @"Needs kernel access — run the chain first." },
    ];
}

- (NSArray<NSDictionary *> *)dragCoefficientRows
{
    return @[
        @{ @"kind": @"number",
           @"key": kSettingsDSDragCoefficientValue,
           @"title": @"Coefficient",
           @"subtitle": @"1.00 = default, 0.50 = 2× faster, 0.25 = 4× faster. Minimum is 0.01.",
           @"min": @0.01, @"max": @2.0, @"step": @0.01,
           @"precision": @2, @"default": @0.5 },
    ];
}

- (NSArray<NSDictionary *> *)layoutExtrasRows
{
    return @[
        @{ @"kind": @"number", @"key": kSettingsLayoutHomeExtraLeft,
           @"title": @"Home extra left",   @"min": @0,  @"max": @300, @"step": @1, @"unit": @"pt", @"default": @0 },
        @{ @"kind": @"number", @"key": kSettingsLayoutHomeExtraRight,
           @"title": @"Home extra right",  @"min": @0,  @"max": @300, @"step": @1, @"unit": @"pt", @"default": @0 },
        @{ @"kind": @"number", @"key": kSettingsLayoutHomeExtraTop,
           @"title": @"Home extra top",    @"min": @0,  @"max": @400, @"step": @1, @"unit": @"pt", @"default": @0 },
        @{ @"kind": @"number", @"key": kSettingsLayoutHomeExtraBottom,
           @"title": @"Home extra bottom", @"min": @0,  @"max": @400, @"step": @1, @"unit": @"pt", @"default": @0 },
        @{ @"kind": @"number", @"key": kSettingsLayoutDockExtraLeft,
           @"title": @"Dock extra left",  @"min": @0,  @"max": @200, @"step": @1, @"unit": @"pt", @"default": @0 },
        @{ @"kind": @"number", @"key": kSettingsLayoutDockExtraRight,
           @"title": @"Dock extra right", @"min": @0,  @"max": @200, @"step": @1, @"unit": @"pt", @"default": @0 },
        @{ @"kind": @"number", @"key": kSettingsLayoutHomeScalePct,
           @"title": @"Home icon scale",   @"min": @25, @"max": @250, @"step": @1, @"unit": @"%", @"default": @100 },
        @{ @"kind": @"number", @"key": kSettingsLayoutDockScalePct,
           @"title": @"Dock icon scale",   @"min": @25, @"max": @250, @"step": @1, @"unit": @"%", @"default": @100 },
    ];
}

- (NSArray<NSDictionary *> *)statbarRows
{
    return @[
        @{ @"kind": @"toggle", @"key": kSettingsStatBarCelsius,     @"title": @"Celsius" },
        @{ @"kind": @"toggle", @"key": kSettingsStatBarShowCPU,     @"title": @"Show CPU %" },
        @{ @"kind": @"toggle", @"key": kSettingsStatBarShowLabels,  @"title": @"Show CPU / RAM labels" },
        @{ @"kind": @"toggle", @"key": kSettingsStatBarShowNet,     @"title": @"Show network speed" },
        @{ @"kind": @"toggle", @"key": kSettingsStatBarNetworkOnly, @"title": @"Network speed only" },
        @{ @"kind": @"slider", @"key": kSettingsStatBarRefreshRateSec,
           @"title": @"Refresh rate", @"min": @1, @"max": @30, @"step": @1,
           @"unit": @"s", @"default": @(kStatBarDefaultRefreshRateSec) },
    ];
}

- (NSArray<NSDictionary *> *)nsbarRows
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return @[
        @{ @"kind": @"info",
           @"title": @"Position",
           @"subtitle": settings_nsbar_position_name([d integerForKey:kSettingsNSBarPosition]) },
        @{ @"kind": @"button",
           @"title": @"Choose Position…",
           @"action": @"nsbar-position" },
    ];
}

- (NSArray<NSDictionary *> *)nicebarLiteRows
{
    return @[
        @{ @"kind": @"nicebar-grid" },
        @{ @"kind": @"info",
           @"title": @"Layout",
           @"subtitle": @"Top and bottom rows move separately. Changes update live while NiceBar Lite is running." },
        @{ @"kind": @"slider", @"key": kSettingsNiceBarLiteLayoutTopSideInset,
           @"title": @"Top side inset", @"min": @(-80), @"max": @80, @"step": @1, @"unit": @"pt", @"default": @0 },
        @{ @"kind": @"slider", @"key": kSettingsNiceBarLiteLayoutBottomSideInset,
           @"title": @"Bottom side inset", @"min": @(-80), @"max": @80, @"step": @1, @"unit": @"pt", @"default": @0 },
        @{ @"kind": @"slider", @"key": kSettingsNiceBarLiteLayoutTopY,
           @"title": @"Top Y offset", @"min": @(-40), @"max": @80, @"step": @1, @"unit": @"pt", @"default": @0 },
        @{ @"kind": @"slider", @"key": kSettingsNiceBarLiteLayoutBottomY,
           @"title": @"Bottom Y offset", @"min": @(-40), @"max": @80, @"step": @1, @"unit": @"pt", @"default": @0 },
        @{ @"kind": @"slider", @"key": kSettingsNiceBarLiteLayoutCenterX,
           @"title": @"Center X offset", @"min": @(-120), @"max": @120, @"step": @1, @"unit": @"pt", @"default": @0 },
        @{ @"kind": @"toggle", @"key": kSettingsNiceBarLiteCelsius, @"title": @"Use Celsius" },
        @{ @"kind": @"button", @"title": @"Traffic History", @"action": @"nicebar-traffic-history" },
        @{ @"kind": @"button",
           @"title": @"Apply Now",
           @"action": @"nicebar-apply" },
    ];
}

- (NSArray<NSDictionary *> *)axonLiteRows
{
    return @[];
}

- (NSArray<NSDictionary *> *)gravityLiteRows
{
    return @[
        @{ @"kind": @"toggle",
           @"key": kSettingsGravityLiteDockEnabled,
           @"title": @"Include Dock" },
        @{ @"kind": @"slider",
           @"key": kSettingsGravityLiteMagnitudePct,
           @"title": @"Gravity strength",
           @"min": @25,
           @"max": @300,
           @"step": @5,
           @"unit": @"%",
           @"default": @100 },
        @{ @"kind": @"slider",
           @"key": kSettingsGravityLiteBouncePct,
           @"title": @"Bounce",
           @"min": @0,
           @"max": @100,
           @"step": @5,
           @"unit": @"%",
           @"default": @50 },
        @{ @"kind": @"slider",
           @"key": kSettingsGravityLiteFrictionPct,
           @"title": @"Friction",
           @"min": @0,
           @"max": @100,
           @"step": @5,
           @"unit": @"%",
           @"default": @50 },
        @{ @"kind": @"slider",
           @"key": kSettingsGravityLiteResistancePct,
           @"title": @"Resistance",
           @"min": @0,
           @"max": @200,
           @"step": @5,
           @"unit": @"%",
           @"default": @50 },
        @{ @"kind": @"slider",
           @"key": kSettingsGravityLiteAngularResistancePct,
           @"title": @"Spin resistance",
           @"min": @0,
           @"max": @200,
           @"step": @5,
           @"unit": @"%",
           @"default": @0 },
        @{ @"kind": @"button",
           @"title": @"Explosion Pulse",
           @"action": @"gravitylite-explosion" },
        @{ @"kind": @"button",
           @"title": @"Restore Icon Layout",
           @"action": @"gravitylite-restore",
           @"destructive": @YES },
    ];
}

- (NSArray<NSDictionary *> *)locationSimRows
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL locationOn = locationservices_enabled_local() == 1;
    return @[
        @{ @"kind": @"info",
           @"title": @"Location Services",
           @"subtitle": locationOn ? @"On" : @"Off" },

        @{ @"kind": @"button",
           @"title": locationOn ? @"Turn Location Services Off" : @"Turn Location Services On",
           @"subtitle": @"The same system-wide switch as Settings → Privacy & Security → Location Services.",
           @"action": @"locsvc-toggle",
           @"destructive": @(locationOn) },

        @{ @"kind": @"info",
           @"title": @"Mode",
           @"subtitle": settings_location_sim_mode_summary(d) },

        @{ @"kind": @"button",
           @"title": @"Set Exact Coordinates…",
           @"action": @"locsim-set-exact" },

        @{ @"kind": @"button",
           @"title": @"Major Cities…",
           @"action": @"locsim-major-cities" },

        @{ @"kind": @"button",
           @"title": @"Simulate Rockaway Test Point",
           @"action": @"locsim-preset-rockaway" },

        @{ @"kind": @"slider",
           @"key": kSettingsLocationSimAltitude,
           @"title": @"Altitude",
           @"min": @(-100),
           @"max": @1000,
           @"step": @1,
           @"unit": @"m",
           @"default": @(kLocationSimDefaultAltitude) },

        @{ @"kind": @"slider",
           @"key": kSettingsLocationSimHorizontalAccuracy,
           @"title": @"Accuracy",
           @"min": @1,
           @"max": @100,
           @"step": @1,
           @"unit": @"m",
           @"default": @(kLocationSimDefaultAccuracy) },

        @{ @"kind": @"button",
           @"title": @"Simulate Current Target",
           @"action": @"locsim-apply" },

        @{ @"kind": @"button",
           @"title": @"Restore Real Location",
           @"subtitle": @"Reset can take a few minutes. If location still looks simulated, reboot and wait a little longer.",
           @"action": @"locsim-stop",
           @"destructive": @YES },
    ];
}

- (NSArray<NSDictionary *> *)themerRows
{
    BOOL hasSelection = settings_themer_has_selected_theme();
    NSString *selected = settings_themer_selected_theme_display_name();
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithArray:@[
        @{ @"kind": @"info",
           @"title": @"Selected Theme",
           @"subtitle": hasSelection ? selected : @"None selected. Pick a theme before running the icon theme engine." },

        @{ @"kind": @"button",
           @"title": [selected isEqualToString:@"iOS 6 Theme"]
                ? @"iOS 6 Theme ✓" : @"Use iOS 6 Theme",
           @"action": @"themer-select-ios6" },

        @{ @"kind": @"button",
           @"title": @"Import Custom Theme…",
           @"action": @"themer-import" },

        @{ @"kind": @"button",
           @"title": @"Theme Format Guide",
           @"action": @"themer-guide" },
    ]];
    if (hasSelection) {
        [rows addObject:@{ @"kind": @"button",
                           @"title": @"Clear Selected Theme",
                           @"action": @"themer-clear",
                           @"destructive": @YES }];
    }
    return rows;
}

- (NSArray<NSDictionary *> *)snowboardLiteRows
{
    BOOL hasSelection = settings_snowboardlite_has_selected_theme();
    NSString *selected = settings_snowboardlite_selected_theme_display_name();
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithArray:@[
        @{ @"kind": @"info",
           @"title": @"Selected Theme",
           @"subtitle": hasSelection ? selected : @"None selected. Pick or import a theme before running SnowBoard Lite." },
        @{ @"kind": @"button",
           @"title": [selected isEqualToString:@"iOS 6 Theme"] ? @"iOS 6 Theme ✓" : @"Use iOS 6 Theme",
           @"action": @"sbl-select-ios6" },
        @{ @"kind": @"button",
           @"title": @"Import Theme Folder…",
           @"action": @"sbl-import-folder" },
        @{ @"kind": @"button",
           @"title": @"Import Theme Archive (ZIP/DEB)…",
           @"action": @"sbl-import-archive" },
    ]];
    if (hasSelection) {
        [rows addObject:@{ @"kind": @"button",
                           @"title": @"Clear Selected Theme",
                           @"action": @"sbl-clear",
                           @"destructive": @YES }];
    }
    return rows;
}

// Row index of the keypad preview inside passcodeThemeRows. heightForRowAtIndexPath
// reads it directly so row sizing never has to build the rows array.
static const NSInteger kPasscodePreviewRow = 1;

- (NSArray<NSDictionary *> *)passcodeThemeRows
{
    NSDictionary *theme = settings_passcode_selected_theme();
    NSSet<NSString *> *presentDigits = theme ? settings_passcode_theme_digit_presence(theme)
                                              : [NSSet set];
    PTPasscodeStyleState styleState = theme ? settings_passcode_style_state()
                                            : PTPasscodeStyleStateNotApplied;

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];

    // "Unknown" is its own case on purpose: right after a reboot the cache
    // cannot be read without kernel access, but the style is still in place on
    // disk. Claiming "not applied" there would be wrong.
    NSString *stateText = @"not applied";
    if (styleState == PTPasscodeStyleStateApplied) {
        stateText = @"in use";
    } else if (styleState == PTPasscodeStyleStateUnknown) {
        stateText = @"unknown (needs kernel access)";
    }

    [rows addObject:@{
        @"kind": @"info",
        @"title": @"Selected Style",
        @"subtitle": theme
            ? [NSString stringWithFormat:@"%@ · %lu/10 digits · %@",
                                       settings_passcode_selected_theme_display_name(),
                                       (unsigned long)presentDigits.count,
                                       stateText]
            : @"None selected. Import a style below, or tap a key in the preview.",
    }];

    [rows addObject:@{ @"kind": @"passcode-preview" }];

    [rows addObject:@{ @"kind": @"button",
                       @"title": @"Import Style (.passthm/ZIP)…",
                       @"action": @"passcode-import" }];

    if (theme) {
        [rows addObject:@{ @"kind": @"button",
                           @"title": @"Apply Style Now",
                           @"action": @"passcode-apply" }];
        [rows addObject:@{ @"kind": @"button",
                           @"title": @"Clear Selected Style",
                           @"action": @"passcode-clear",
                           @"destructive": @YES }];
    }

    // Saved originals are the only state worth a row: they decide whether Restore has
    // anything to write back. Cache paths and file counts live in the log.
    NSUInteger backups = settings_passcode_theme_backup_count();
    NSUInteger backupDigits = settings_passcode_backup_digit_count();
    [rows addObject:@{
        @"kind": @"info",
        @"title": @"Originals",
        @"subtitle": backups > 0
            ? [NSString stringWithFormat:@"%lu file(s) across %lu digit(s) saved",
                                         (unsigned long)backups, (unsigned long)backupDigits]
            : @"None saved yet. Restore needs a saved original to write back.",
    }];

    [rows addObject:@{ @"kind": @"button",
                       @"title": @"Restore Original Digits",
                       @"action": @"passcode-restore",
                       @"destructive": @YES }];

    // Transferring originals stays at the bottom: a .zip of originals is not a style,
    // so it must not read as part of the style actions above.
    if (backups > 0) {
        [rows addObject:@{ @"kind": @"button",
                           @"title": @"Export Originals…",
                           @"action": @"passcode-export-backups" }];
    }
    [rows addObject:@{ @"kind": @"button",
                       @"title": @"Import Originals…",
                       @"action": @"passcode-import-backups" }];

    return rows;
}

- (UITableViewCell *)buildPasscodePreviewCellInTableView:(UITableView *)tableView
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"passcode-preview"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"passcode-preview"];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    for (UIView *view in [cell.contentView.subviews copy]) [view removeFromSuperview];

    CYPasscodeKeypadPreviewView *preview =
        [[CYPasscodeKeypadPreviewView alloc] initWithFrame:CGRectZero];
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    preview.backgroundColor = UIColor.clearColor;
    [cell.contentView addSubview:preview];

    // The preview shows what the Lock Screen will look like after applying: the
    // selected style's digits, with the cache's current art behind them for any
    // digit the style does not cover. With no style selected it is simply the
    // current keypad.
    NSMutableDictionary<NSString *, NSData *> *art =
        [settings_passcode_current_digit_images() mutableCopy];
    NSDictionary *theme = settings_passcode_selected_theme();
    if (theme) {
        [art addEntriesFromDictionary:settings_passcode_theme_digit_images(theme)];
    }
    preview.digitArt = art;

    __weak typeof(self) weakSelf = self;
    preview.onDigitTapped = ^(NSString *digit) {
        [weakSelf presentPasscodeDigitPicker:digit];
    };

    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [preview.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [preview.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [preview.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [preview.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
    ]];
    return cell;
}

- (NSArray<NSDictionary *> *)liveWPRows
{
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithArray:@[
        @{ @"kind": @"info",
           @"title": @"Selected Video",
           @"subtitle": settings_livewp_video_detail() },
        @{ @"kind": @"button",
           @"title": @"Choose Video…",
           @"action": @"livewp-select-video" },
    ]];
    if ([[NSUserDefaults standardUserDefaults] stringForKey:kSettingsLiveWPVideoPath].length > 0) {
        [rows addObject:@{ @"kind": @"button",
                           @"title": @"Clear Selected Video",
                           @"action": @"livewp-clear",
                           @"destructive": @YES }];
    }
    return rows;
}

- (NSArray<NSDictionary *> *)appSwitcherGridRows
{
    BOOL applied = settings_tweak_is_applied(kSettingsAppSwitcherGridEnabled);
    return @[
        @{ @"kind": @"info",
           @"title": applied ? @"Current Style: Grid" : @"Current Style: Stock",
           @"subtitle": @"This is a runtime SpringBoard method patch. It does not write system files; respring restores the stock app switcher." },
        @{ @"kind": @"info",
           @"title": @"Session note",
           @"subtitle": @"If you respring after Hide Home Bar, run App Switcher Grid again because respring resets this live SpringBoard patch." },
        @{ @"kind": @"button",
           @"title": @"Restore Stock Switcher",
           @"subtitle": @"Restores the original switcher style in the active SpringBoard session when available.",
           @"action": @"appswitchergrid-restore",
           @"destructive": @YES },
    ];
}

- (NSArray<NSDictionary *> *)fastLockXLiteRows
{
    return @[
        @{ @"kind": @"info",
           @"title": @"FastLockX Lite",
           @"subtitle": @"Always On keeps the Face ID retry pulse and unlock request armed in SpringBoard until Disable, Clean Up, or respring." },
        @{ @"kind": @"button",
           @"title": @"Enable Always On",
           @"subtitle": @"Keeps pickup-to-unlock armed after Cyanide closes.",
           @"action": @"fastlockx-enable" },
        @{ @"kind": @"button",
           @"title": @"Disable",
           @"subtitle": @"Stops the SpringBoard timers.",
           @"action": @"fastlockx-disable" },
        @{ @"kind": @"number",
           @"key": kSettingsFastLockXLiteRetryInterval,
           @"title": @"Retry interval",
           @"subtitle": @"Always On uses this as the off→on pulse gap. Default is 0.3s.",
           @"min": @0.1, @"max": @2.0, @"step": @0.1, @"unit": @"s", @"precision": @1, @"default": @0.3 },
        @{ @"key": kSettingsFastLockXLiteBlockMusic,
           @"title": @"Block if media is active — In progress",
           @"subtitle": @"In progress — not wired yet. This blocker is disabled for now.",
           @"disabled": @YES },
        @{ @"key": kSettingsFastLockXLiteBlockFlashlight,
           @"title": @"Block if flashlight is on — In progress",
           @"subtitle": @"In progress — not wired yet. This blocker is disabled for now.",
           @"disabled": @YES },
        @{ @"key": kSettingsFastLockXLiteBlockLowPower,
           @"title": @"Block in Low Power Mode — In progress",
           @"subtitle": @"In progress — not wired yet. This blocker is disabled for now.",
           @"disabled": @YES },
    ];
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)settingsSummaryForSection:(NSInteger)section
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableArray *out = [NSMutableArray array];
    if (section == SectionSBC) {
        [out addObject:@{@"title": @"Dock icons",       @"value": [@([d integerForKey:kSettingsSBCDockIcons])  stringValue]}];
        [out addObject:@{@"title": @"Auto-add Dock app", @"value": [d boolForKey:kSettingsSBCAutoDockApp] ? @"On" : @"Off"}];
        if ([d boolForKey:kSettingsSBCAutoDockApp]) {
            [out addObject:@{@"title": @"Selected Dock app",
                             @"value": [d stringForKey:kSettingsSBCDockAppBundleID] ?: kSBCDefaultDockAppBundleID}];
        }
        [out addObject:@{@"title": @"Home columns",     @"value": [@([d integerForKey:kSettingsSBCCols])        stringValue]}];
        [out addObject:@{@"title": @"Home rows",        @"value": [@([d integerForKey:kSettingsSBCRows])        stringValue]}];
        [out addObject:@{@"title": @"Hide icon labels", @"value": [d boolForKey:kSettingsSBCHideLabels] ? @"On" : @"Off"}];
        [out addObject:@{@"title": @"Arrange pages", @"value": [d boolForKey:kSettingsSBCArrangePages] ? @"On" : @"Off"}];
        if ([d boolForKey:kSettingsSBCArrangePages]) {
            [out addObject:@{@"title": @"Page icon counts",
                             @"value": [NSString stringWithFormat:@"%ld / %ld",
                                        (long)[d integerForKey:kSettingsSBCFirstPageIcons],
                                        (long)[d integerForKey:kSettingsSBCOtherPageIcons]]}];
        }
    } else if (section == SectionLayoutExtras) {
        [out addObject:@{@"title": @"Home extra L/R",   @"value": [NSString stringWithFormat:@"%ld/%ld",
                                                                    (long)[d integerForKey:kSettingsLayoutHomeExtraLeft],
                                                                    (long)[d integerForKey:kSettingsLayoutHomeExtraRight]]}];
        [out addObject:@{@"title": @"Home extra T/B",   @"value": [NSString stringWithFormat:@"%ld/%ld",
                                                                    (long)[d integerForKey:kSettingsLayoutHomeExtraTop],
                                                                    (long)[d integerForKey:kSettingsLayoutHomeExtraBottom]]}];
        [out addObject:@{@"title": @"Dock extra L/R",   @"value": [NSString stringWithFormat:@"%ld/%ld",
                                                                    (long)[d integerForKey:kSettingsLayoutDockExtraLeft],
                                                                    (long)[d integerForKey:kSettingsLayoutDockExtraRight]]}];
        [out addObject:@{@"title": @"Home scale %",     @"value": [@([d integerForKey:kSettingsLayoutHomeScalePct]) stringValue]}];
        [out addObject:@{@"title": @"Dock scale %",     @"value": [@([d integerForKey:kSettingsLayoutDockScalePct]) stringValue]}];
    } else if (section == SectionStatBar) {
        [out addObject:@{@"title": @"Celsius",             @"value": [d boolForKey:kSettingsStatBarCelsius]    ? @"On" : @"Off"}];
        [out addObject:@{@"title": @"Show CPU %",          @"value": [d boolForKey:kSettingsStatBarShowCPU]    ? @"On" : @"Off"}];
        [out addObject:@{@"title": @"Show CPU/RAM labels", @"value": [d boolForKey:kSettingsStatBarShowLabels] ? @"On" : @"Off"}];
        [out addObject:@{@"title": @"Show net speed",      @"value": [d boolForKey:kSettingsStatBarShowNet]    ? @"On" : @"Off"}];
        [out addObject:@{@"title": @"Network speed only",  @"value": [d boolForKey:kSettingsStatBarNetworkOnly] ? @"On" : @"Off"}];
        [out addObject:@{@"title": @"Refresh rate",        @"value": [NSString stringWithFormat:@"%lds",
                                                                       (long)[d integerForKey:kSettingsStatBarRefreshRateSec]]}];
    } else if (section == SectionNSBar) {
        [out addObject:@{@"title": @"Position", @"value": settings_nsbar_position_name([d integerForKey:kSettingsNSBarPosition])}];
    } else if (section == SectionNiceBarLite) {
        for (NSInteger i = 0; i < NiceBarLiteSlotCount; i++) {
            NSInteger kind = [d integerForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, i)];
            [out addObject:@{@"title": settings_nicebar_slot_name(i),
                             @"value": settings_nicebar_kind_name(kind)}];
        }
    } else if (section == SectionAppSwitcherGrid) {
        [out addObject:@{@"title": @"Switcher style",
                         @"value": settings_tweak_is_applied(kSettingsAppSwitcherGridEnabled) ? @"Grid" : @"Stock"}];
    } else if (section == SectionFastLockXLite) {
        BOOL alwaysOnIntent = [d boolForKey:kSettingsFastLockXLiteEnabled];
        BOOL alwaysOnApplied = settings_tweak_is_applied(kSettingsFastLockXLiteEnabled);
        [out addObject:@{@"title": @"Always On",
                         @"value": alwaysOnApplied ? @"Enabled" : (alwaysOnIntent ? @"Queued" : @"Off")}];
        [out addObject:@{@"title": @"Retry interval",
                         @"value": [NSString stringWithFormat:@"%.1fs", settings_fastlockx_lite_retry_interval(d)]}];
        [out addObject:@{@"title": @"Blockers",
                         @"value": @"In progress"}];
    } else if (section == SectionPowercuff) {
        NSString *lvl = [d stringForKey:kSettingsPowercuffLevel] ?: @"nominal";
        [out addObject:@{@"title": @"Level", @"value": lvl}];
    } else if (section == SectionDragCoefficient) {
        double v = settings_drag_coefficient_value(d);
        [out addObject:@{@"title": @"Coefficient", @"value": [NSString stringWithFormat:@"%.2f", v]}];
    } else if (section == SectionLockScreenDuration) {
        [out addObject:@{@"title": @"Duration",
                         @"value": [NSString stringWithFormat:@"%llds", settings_lock_duration_value(d)]}];
    } else if (section == SectionNanoRegistry) {
        [out addObject:@{@"title": @"watchOS limit",      @"value": [@([d integerForKey:kSettingsNanoMaxPairing])       stringValue]}];
        [out addObject:@{@"title": @"Setup floor",        @"value": [@([d integerForKey:kSettingsNanoMinPairing])       stringValue]}];
        [out addObject:@{@"title": @"Legacy chip floor",  @"value": [@([d integerForKey:kSettingsNanoMinPairingChipID]) stringValue]}];
        [out addObject:@{@"title": @"Multi-watch switch", @"value": [@([d integerForKey:kSettingsNanoMinQuickSwitch])   stringValue]}];
    } else if (section == SectionThemer) {
        [out addObject:@{@"title": @"Theme", @"value": settings_themer_selected_theme_display_name()}];
    } else if (section == SectionSnowBoardLite) {
        [out addObject:@{@"title": @"Theme", @"value": settings_snowboardlite_selected_theme_display_name()}];
    } else if (section == SectionPasscodeTheme) {
        NSDictionary *passcodeTheme = settings_passcode_selected_theme();
        [out addObject:@{@"title": @"Style",
                         @"value": passcodeTheme ? settings_passcode_selected_theme_display_name() : @"None selected"}];
        if (passcodeTheme) {
            [out addObject:@{@"title": @"Digits in style",
                             @"value": [NSString stringWithFormat:@"%lu/10",
                                        (unsigned long)settings_passcode_theme_digit_presence(passcodeTheme).count]}];
        }
        [out addObject:@{@"title": @"Saved originals",
                         @"value": [@(settings_passcode_theme_backup_count()) stringValue]}];
    } else if (section == SectionLiveWP) {
        [out addObject:@{@"title": @"Video", @"value": settings_livewp_video_detail()}];
    } else if (section == SectionLocationSim) {
        [out addObject:@{@"title": @"Target", @"value": settings_location_sim_target_summary(d)}];
    } else if (section == SectionGravityLite) {
        [out addObject:@{@"title": @"Dock",         @"value": [d boolForKey:kSettingsGravityLiteDockEnabled] ? @"Included" : @"Home only"}];
        [out addObject:@{@"title": @"Strength",     @"value": [NSString stringWithFormat:@"%ld%%", (long)[d integerForKey:kSettingsGravityLiteMagnitudePct]]}];
        [out addObject:@{@"title": @"Bounce",       @"value": [NSString stringWithFormat:@"%ld%%", (long)[d integerForKey:kSettingsGravityLiteBouncePct]]}];
        [out addObject:@{@"title": @"Friction",     @"value": [NSString stringWithFormat:@"%ld%%", (long)[d integerForKey:kSettingsGravityLiteFrictionPct]]}];
        [out addObject:@{@"title": @"Resistance",   @"value": [NSString stringWithFormat:@"%ld%%", (long)[d integerForKey:kSettingsGravityLiteResistancePct]]}];
        [out addObject:@{@"title": @"Spin resist.", @"value": [NSString stringWithFormat:@"%ld%%", (long)[d integerForKey:kSettingsGravityLiteAngularResistancePct]]}];
    }
    return out;
}

- (NSArray<NSDictionary *> *)rowsForSection:(NSInteger)s
{
    switch (s) {
        case SectionLaunch:    return self.launchRows;
        case SectionSBC:       return self.sbcRows;
        case SectionDarkSwordTweaks: return self.darkSwordTweakRows;
        case SectionDragCoefficient: return self.dragCoefficientRows;
        case SectionLayoutExtras: return self.layoutExtrasRows;
        case SectionLockScreenDuration: return self.lockScreenDurationRows;
        case SectionOTA:       return self.otaRows;
        case SectionNanoRegistry: return self.nanoRegistryRows;
        case SectionThemer:  return self.themerRows;
        case SectionPowercuff: return self.powercuffRows;
        case SectionStatBar:   return self.statbarRows;
        case SectionNSBar:     return self.nsbarRows;
        case SectionNiceBarLite: return self.nicebarLiteRows;
        case SectionAxonLite:  return self.axonLiteRows;
        case SectionAppSwitcherGrid: return self.appSwitcherGridRows;
        case SectionFastLockXLite: return settings_fastlockx_lite_install_allowed() ? self.fastLockXLiteRows : @[];
        case SectionGravityLite: return self.gravityLiteRows;
        case SectionLocationSim: return self.locationSimRows;
        case SectionSnowBoardLite: return self.snowboardLiteRows;
        case SectionPasscodeTheme: return self.passcodeThemeRows;
        case SectionLiveWP: return self.liveWPRows;
        case SectionQuickLoader: return self.quickLoaderRows;
        case SectionRepoTweaks: return self.repoTweaksRows;
        default: return @[];
    }
}

#pragma mark - Bundle rows (root mode)

// Bundles whose underlying section has zero configuration rows are filtered
// out — install/uninstall is the only operation those tweaks expose, and
// that's already in the Installer tab.

- (NSArray<NSDictionary *> *)allTweakBundleRows
{
    return @[
        @{ @"title": @"Launch Options",     @"icon": @"bolt.fill",                          @"color": [UIColor systemRedColor],    @"section": @(SectionLaunch) },
        @{ @"title": @"SBCustomizer",       @"icon": @"square.grid.3x3.fill",                @"color": [UIColor systemBlueColor],   @"section": @(SectionSBC) },
        @{ @"title": @"StatBar",            @"icon": @"thermometer.medium",                  @"color": [UIColor systemRedColor],    @"section": @(SectionStatBar) },
        @{ @"title": @"NSBar",              @"icon": @"network",                             @"color": [UIColor systemBlueColor],   @"section": @(SectionNSBar) },
        @{ @"title": @"NiceBar Lite",       @"icon": @"textformat.size",                     @"color": [UIColor systemTealColor],   @"section": @(SectionNiceBarLite) },
        @{ @"title": @"Axon Lite",          @"icon": @"bell.badge.fill",                     @"color": [UIColor systemRedColor],    @"section": @(SectionAxonLite) },
#if CYANIDE_EXPERIMENTAL_TWEAKS_AVAILABLE
        @{ @"title": @"FastLockX Lite",     @"icon": @"lock.open.fill",                      @"color": [UIColor systemGreenColor],  @"section": @(SectionFastLockXLite) },
#endif
        @{ @"title": @"Gravity Lite",       @"icon": @"arrow.down.circle.fill",              @"color": [UIColor systemGreenColor],  @"section": @(SectionGravityLite) },
        @{ @"title": @"App Switcher Grid",  @"icon": @"square.grid.2x2.fill",                @"color": [UIColor systemOrangeColor], @"section": @(SectionAppSwitcherGrid) },
        @{ @"title": @"Location Simulator", @"icon": @"location.fill",                       @"color": [UIColor systemGreenColor],  @"section": @(SectionLocationSim) },
        @{ @"title": @"SnowBoard Lite",     @"icon": @"square.stack.3d.up.fill",             @"color": [UIColor systemCyanColor],   @"section": @(SectionSnowBoardLite) },
        @{ @"title": @"LiveWP",             @"icon": @"play.rectangle.fill",                 @"color": [UIColor systemPurpleColor], @"section": @(SectionLiveWP) },
        @{ @"title": @"QuickLoader",        @"icon": @"bolt.fill",                           @"color": [UIColor systemYellowColor], @"section": @(SectionQuickLoader) },
        @{ @"title": @"RepoTweaks",         @"icon": @"tray.and.arrow.down.fill",            @"color": [UIColor systemBlueColor],   @"section": @(SectionRepoTweaks) },
        @{ @"title": @"Powercuff",          @"icon": @"bolt.slash.fill",                     @"color": [UIColor systemOrangeColor], @"section": @(SectionPowercuff) },
        @{ @"title": @"Drag Coefficient",   @"icon": @"dial.medium.fill",                    @"color": [UIColor systemIndigoColor], @"section": @(SectionDragCoefficient) },
        @{ @"title": @"Home Layout Extras", @"icon": @"square.dashed.inset.filled",          @"color": [UIColor systemPurpleColor], @"section": @(SectionLayoutExtras) },
        @{ @"title": @"Lock Screen Duration", @"icon": @"lock.rectangle.on.rectangle",       @"color": [UIColor systemIndigoColor], @"section": @(SectionLockScreenDuration) },
        @{ @"title": @"Passcode Style",     @"icon": @"circle.grid.3x3.fill",                @"color": [UIColor systemPinkColor],   @"section": @(SectionPasscodeTheme) },
    ];
}

UIViewController *settings_make_process_viewer(void)
{
    return [[ProcessManagerViewController alloc] initWithStyle:UITableViewStylePlain];
}

UIViewController *settings_make_file_browser(void)
{
    return [[FileBrowserViewController alloc] initWithPath:@"/"];
}

- (NSArray<NSDictionary *> *)allSystemBundleRows
{
    return @[
        @{ @"title": @"OTA Updates",       @"icon": @"icloud.slash.fill",    @"color": [UIColor systemGrayColor],   @"section": @(SectionOTA) },
        @{ @"title": @"Watch Pairing",     @"icon": @"applewatch.radiowaves.left.and.right", @"color": [UIColor systemPurpleColor], @"section": @(SectionNanoRegistry) },
        // Process Viewer: shipped in 1.7.0 after the rounds 23–42 stability work
        // (launchd-hijack ABBA avoidance, tro-dance helper liveness, safe-detach
        // drains) — no longer WIP.
        @{ @"title": @"Process Viewer",    @"icon": @"list.bullet.rectangle.fill", @"color": [UIColor systemGrayColor], @"section": @(-1), @"custom": @"procmgr" },
        @{ @"title": @"File Browser",      @"icon": @"folder.fill", @"color": [UIColor systemBlueColor], @"section": @(-1), @"custom": @"filebrowser" },
    ];
}

- (NSArray<NSDictionary *> *)filterBundles:(NSArray<NSDictionary *> *)bundles
{
    BOOL experimentalOn = settings_experimental_tweaks_enabled();
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *bundle in bundles) {
        if ([bundle[@"indev"] boolValue]) continue;
        if ([bundle[@"experimental"] boolValue] && !experimentalOn) continue;
        if (bundle[@"custom"]) { [out addObject:bundle]; continue; }  // opens a custom screen, no config section
        NSInteger sec = [bundle[@"section"] integerValue];
        if ([self rowsForSection:sec].count > 0) {
            [out addObject:bundle];
        }
    }
    return out;
}

- (NSArray<NSDictionary *> *)inDevBundleRows
{
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *bundle in [self allTweakBundleRows]) {
        if (![bundle[@"indev"] boolValue]) continue;
        NSInteger sec = [bundle[@"section"] integerValue];
        if ([self rowsForSection:sec].count > 0) {
            [out addObject:bundle];
        }
    }
    return out;
}

- (NSArray<NSDictionary *> *)tweakBundleRows
{
    return [self filterBundles:[self allTweakBundleRows]];
}

- (NSArray<NSDictionary *> *)systemBundleRows
{
    return [self filterBundles:[self allSystemBundleRows]];
}

- (NSArray<NSDictionary *> *)bundleRowsForRootSection:(RootSection)section
{
    if (section == RootSectionTweakBundles)  return self.tweakBundleRows;
    if (section == RootSectionInDev)        return self.inDevBundleRows;
    if (section == RootSectionSystemBundles) return self.systemBundleRows;
    return @[];
}

#pragma mark - Table data

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return self.detailMode ? 1 : RootSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (self.detailMode) {
        return (NSInteger)[self rowsForSection:self.underlyingSection].count;
    }
    switch ((RootSection)section) {
        case RootSectionChangelog: {
            NSInteger n = (NSInteger)settings_changelog_entries().count;
            if (n == 0) return 0;
            return self.changelogExpanded ? n + 2 : 1;
        }
        case RootSectionActions:        return 4;
        case RootSectionTweakBundles:   return (NSInteger)self.tweakBundleRows.count;
        case RootSectionInDev:         return (NSInteger)self.inDevBundleRows.count;
        case RootSectionSystemBundles:  return (NSInteger)self.systemBundleRows.count;
        case RootSectionAbout:          return 6;
        case RootSectionWarning:        return 0;
        case RootSectionCount:          return 0;
    }
    return 0;
}

- (NSString *)settingsRootSectionTitle:(NSInteger)section
{
    if (self.detailMode) return nil;
    switch ((RootSection)section) {
        case RootSectionChangelog:      return self.changelogExpanded ? @"What's New" : nil;
        case RootSectionActions:        return @"Quick Actions";
        case RootSectionTweakBundles:   return self.tweakBundleRows.count   > 0 ? @"Tweaks" : nil;
        case RootSectionInDev:         return self.inDevBundleRows.count   > 0 ? @"In Development" : nil;
        case RootSectionSystemBundles:  return self.systemBundleRows.count  > 0 ? @"System" : nil;
        case RootSectionAbout:          return @"About";
        default:                        return nil;
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    NSString *title = [self settingsRootSectionTitle:section];
    return title ? CYSectionHeaderView(title) : nil;
}


- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (!self.detailMode) {
        if ((RootSection)section == RootSectionInDev && self.inDevBundleRows.count > 0) {
            return @"These entries are not installable because they do not work yet. They remain visible so the unfinished settings/source paths are discoverable for anyone who wants to continue them.";
        }
        return nil;
    }
    NSInteger s = self.underlyingSection;
    if (s == SectionLaunch) {
        return @"kexploit_opa334 runs once per app lifetime. Keep Alive applies only while Cyanide is minimized; an App Switcher kill still terminates the process.";
    }
    if (s == SectionSBC) {
        return [NSString stringWithFormat:@"Stock iOS defaults: dock %ld, columns %ld, rows %ld. The optional Dock app move runs after Dock expansion and before page arrangement; the Watusi WhatsApp duplicate is the initial selection. Page defaults are %ld icons on page one and %ld on later pages.",
                (long)kSBCDefaultDockIcons, (long)kSBCDefaultCols, (long)kSBCDefaultRows,
                (long)kSBCDefaultFirstPageIcons, (long)kSBCDefaultOtherPageIcons];
    }
    if (s == SectionDarkSwordTweaks) {
        return @"Imported from DarkSword-Tweaks. These are SpringBoard memory patches; turning one off only skips future applies.";
    }
    if (s == SectionDragCoefficient) {
        return @"Overrides _UIAnimationDragCoefficient in SpringBoard. Type the raw coefficient: 1.00 = stock, 0.50 = 2× faster, 0.25 = 4× faster, minimum 0.01. Imported from kolbicz/DarkSword-Tweaks.";
    }
    if (s == SectionLockScreenDuration) {
        return @"Extends the lock screen's own dim-then-sleep timer (separate from Settings > Auto-Lock) so you get more time to read notifications. Type the exact seconds, then tap Apply — it writes the SpringBoard preference SBMinimumLockscreenIdleTime (a global floor) and offers a respring to apply it. Like OTA Updates it is a manual action; the value persists across respring and reboot. Tap Remove to restore stock. Run the chain at least once first so kernel access is active.";
    }
    if (s == SectionLayoutExtras) {
        NSInteger major = [[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
        if (major >= 26) {
            return [NSString stringWithFormat:
                @"Adds extra padding and per-icon scaling on top of the stock home/dock layout.\n\n"
                @"Running on iOS %ld: the upstream config-mutation path doesn't exist (AMUIInfographIconListLayout has no mutable configuration), so the iOS 26 path instead walks the live SBIconListView/SBIconView hierarchy and adjusts frames + iconImageInfo directly. One-shot at Run; iOS 26 may re-fit on a subsequent layout pass (rotation, page swipe).",
                (long)major];
        }
        return @"Adds extra padding and per-icon scaling on top of the stock home/dock layout. Defaults are zero padding and 100% scale (no change). Toggle Enable on and hit Run to apply; values aren't persisted across respring.";
    }
    if (s == SectionOTA) {
        return @"Blocks or restores the launchd jobs that run over-the-air system updates. "
               @"Tap Disable OTA Updates to block them or Enable OTA Updates to restore them — "
               @"like Lock Screen Duration these are manual actions, written immediately with no "
               @"Run or Apply step, and the state persists across reboots. Read Current Status "
               @"reports whether the update daemons are currently blocked. "
               @"Run the chain at least once first so kernel access is active. "
               @"Edits launchd disabled.plist; a reboot or userspace restart is required for "
               @"changes to take effect.";
    }
    if (s == SectionNanoRegistry) {
        return @"Changes the watchOS pairing range saved on this iPhone.\n\n"
               @"Most people should tap Use watchOS Range 99/23/10/6, then Apply Pairing Override. "
               @"These are pairing protocol generations, not Apple Watch model numbers. "
               @"99 raises the watchOS pairing ceiling. 23 keeps the generation-23 setup protocol accepted. "
               @"10 and 6 leave the legacy chip and multi-watch floors at their normal values.\n\n"
               @"Apple Watch Ultra 3 cannot pair on iOS versions below 26 at this time.\n\n"
               @"Respring or reboot after applying before you try to pair.";
    }
    if (s == SectionPowercuff) {
        return @"Underclocks the CPU/GPU via thermalmonitord by simulating thermal pressure. Nominal is the daily-use default. Light, Moderate, and Heavy intentionally underclock the CPU more and can make the device feel laggy, especially on older hardware.";
    }
    if (s == SectionStatBar) {
        return @"Live overlay. When enabled, StatBar keeps a SpringBoard RemoteCall session open. Refresh rate applies when Cyanide is minimized but the screen is still awake; StatBar pauses while the screen is locked or asleep.";
    }
    if (s == SectionNSBar) {
        return @"Network speed overlay ported from d1y/cyanide-ios. When enabled, NSBar keeps a SpringBoard RemoteCall session open and refreshes roughly once per second.";
    }
    if (s == SectionNiceBarLite) {
        return @"Tap a box to choose what it shows. NiceBar Lite places plain text in the configured status-bar slots around the notch or Dynamic Island, including the bottom center position. Weather is fetched from your current location through Open-Meteo and follows the Celsius toggle.";
    }
    if (s == SectionAxonLite) {
        return @"RemoteCall-only Axon port. It uses a live app-side loop rather than substrate hooks, so it lasts for the active Cyanide SpringBoard session.";
    }
    if (s == SectionAppSwitcherGrid) {
        return @"Runtime patch. It changes SpringBoard's app switcher style in memory, writes no system files, and a respring restores stock. Unsupported builds may glitch the app switcher or crash SpringBoard.";
    }
    if (s == SectionGravityLite) {
        return @"RemoteCall-only core port of Julio Verne's Gravity. Run applies UIDynamicAnimator gravity, collision, bounce, friction, optional dock physics, and accelerometer steering to SpringBoard icon snapshots. It can restore the icon layout or fire a manual explosion pulse while the SpringBoard session is active.\n\nNot included in this core port: Activator/Home-button hooks, drag gestures, automatic shake effects, and preference-daemon notifications.";
    }
    if (s == SectionLocationSim) {
        return @"Beta CoreLocation simulation. Requires Apple Maps installed and set up — Maps is the RemoteCall host process that drives the simulation.\n\nThis is a manual tool, not an installable package. Use Simulate Current Target to start; use Restore Real Location to stop simulation and return CoreLocation to the device's real providers. Each run opens the activity log and marks completion when the request returns.\n\nNot all apps respect the simulated location. Apps that use their own location validation or additional signals may ignore it.\n\nCredits: kolbicz for the RemoteCall/CLSimulationManager GPS spoofer prototype, and ezzuldinSt's LSpoof for picker/route references.\n\nWarning: this can affect more than maps. Location-tied system behavior, including time zone and date/time handling, may behave unexpectedly. Only use this if you know what you're doing.";
    }
    if (s == SectionThemer) {
        return @"Legacy icon theme engine settings.\n\n"
               @"Pick a theme before running the icon theme engine.\n\n"
               @"Compatibility: when Dynamic Stage Lite is enabled, live icon repair is paused to avoid SpringBoard resprings. The selected theme still applies once.\n\n"
               @"Custom themes can be a folder of PNG files named by bundle ID, such as com.apple.mobilesafari.png, or a binary plist mapping bundle IDs to PNG data. Import copies the theme into Cyanide's Documents/Themes folder. Theme Format Guide includes examples and plist exports.";
    }
    if (s == SectionSnowBoardLite) {
        return @"SnowBoard/IconBundles importer ported from d1y/cyanide-ios. Folder imports are copied into Cyanide's Documents/SnowBoardLite library and applied through the existing icon replacement pipeline.\n\nThe import copies theme assets into Cyanide's local storage so the original theme in Files is not changed.\n\nCompatibility: SnowBoard Lite keeps live icon repair active and reuses the SpringBoard RemoteCall channel between repair ticks. Re-run it after a respring if icons reset.";
    }
    if (s == SectionLiveWP) {
        return @"Video wallpaper ported from d1y/cyanide-ios. Select an MP4, MOV, or M4V; Cyanide copies it into Documents/LiveWP and plays it in SpringBoard while the RemoteCall session stays alive.";
    }
    if (s == SectionPasscodeTheme) {
        return @"Replaces the Lock Screen keypad artwork with a style you import here. Every write is verified, and each keypad original is saved before the first change so Restore Original Digits can put the stock art back. Run the chain at least once first so kernel access is active. Lock and unlock (or respring) to see the change; touch and hold Import Originals to erase the saved originals.";
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if (!self.detailMode) {
        if ((RootSection)section == RootSectionWarning) return CGFLOAT_MIN;
        if ((RootSection)section == RootSectionChangelog     && settings_changelog_entries().count == 0) return CGFLOAT_MIN;
        if ((RootSection)section == RootSectionTweakBundles  && self.tweakBundleRows.count  == 0) return CGFLOAT_MIN;
        if ((RootSection)section == RootSectionInDev        && self.inDevBundleRows.count  == 0) return CGFLOAT_MIN;
        if ((RootSection)section == RootSectionSystemBundles && self.systemBundleRows.count == 0) return CGFLOAT_MIN;
    }
    return 46.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    if ([self tableView:tableView titleForFooterInSection:section].length > 0)
        return UITableViewAutomaticDimension;
    return 6.0;
}

#pragma mark - Icon badge

+ (UIImage *)iconBadgeWithSymbol:(NSString *)symbol color:(UIColor *)color size:(CGFloat)size
{
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGFloat radius = size * (7.0 / 29.0);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size) cornerRadius:radius];
        [color setFill];
        [path fill];

        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size * 0.58 weight:UIImageSymbolWeightSemibold];
        UIImage *symbolImage = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        if (symbolImage) {
            UIImage *whiteIcon = [symbolImage imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            CGFloat x = (size - whiteIcon.size.width) / 2.0;
            CGFloat y = (size - whiteIcon.size.height) / 2.0;
            [whiteIcon drawAtPoint:CGPointMake(x, y)];
        }
    }];
}

#pragma mark - Cells

- (UITableViewCell *)buildBundleCellWithRow:(NSDictionary *)row tableView:(UITableView *)tableView
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"bundle"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"bundle"];
    }
    cell.imageView.image = [SettingsViewController iconBadgeWithSymbol:row[@"icon"] color:row[@"color"] size:29.0];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)buildInDevCellWithRow:(NSDictionary *)row tableView:(UITableView *)tableView
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"indev"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"indev"];
    }
    cell.imageView.image = [SettingsViewController iconBadgeWithSymbol:row[@"icon"] color:[UIColor systemGrayColor] size:29.0];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.textLabel.textColor = UIColor.tertiaryLabelColor;
    cell.detailTextLabel.text = @"In Development";
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0];
    cell.detailTextLabel.textColor = UIColor.tertiaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = NO;
    return cell;
}

- (UITableViewCell *)buildChangelogCellAtRow:(NSInteger)row tableView:(UITableView *)tableView
{
    NSArray<NSDictionary *> *entries = settings_changelog_entries();
    NSDictionary *entry = (row >= 0 && row < (NSInteger)entries.count) ? entries[row] : nil;

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"changelog-entry"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"changelog-entry"];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = nil;
    cell.textLabel.text = nil;
    for (UIView *v in [cell.contentView.subviews copy]) [v removeFromSuperview];

    NSString *version = entry[@"version"] ?: @"";
    NSString *date    = settings_pretty_date_for_iso(entry[@"date"]);

    // Version pill
    UILabel *versionLabel = [[UILabel alloc] init];
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionLabel.text = [NSString stringWithFormat:@" v%@ ", version];
    versionLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
    versionLabel.textColor = UIColor.systemBlueColor;
    versionLabel.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.12];
    versionLabel.layer.cornerRadius = 4.0;
    versionLabel.layer.masksToBounds = YES;
    versionLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *dateLabel = [[UILabel alloc] init];
    dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    dateLabel.text = date;
    dateLabel.font = [UIFont systemFontOfSize:13.0];
    dateLabel.textColor = UIColor.tertiaryLabelColor;

    // Build bullet list with hanging indent
    NSArray *changes = entry[@"changes"];
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:changes.count];
    for (id c in changes) {
        if (![c isKindOfClass:[NSString class]]) continue;
        [lines addObject:(NSString *)c];
    }

    NSMutableParagraphStyle *bulletStyle = [[NSMutableParagraphStyle alloc] init];
    bulletStyle.headIndent = 14.0;
    bulletStyle.firstLineHeadIndent = 0.0;
    bulletStyle.paragraphSpacing = 4.0;
    bulletStyle.lineBreakMode = NSLineBreakByWordWrapping;

    NSDictionary *bulletAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:14.0],
        NSForegroundColorAttributeName: UIColor.labelColor,
        NSParagraphStyleAttributeName: bulletStyle,
    };
    NSDictionary *dotAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:14.0],
        NSForegroundColorAttributeName: UIColor.tertiaryLabelColor,
        NSParagraphStyleAttributeName: bulletStyle,
    };

    NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
    for (NSUInteger i = 0; i < lines.count; i++) {
        if (i > 0) [body appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        [body appendAttributedString:[[NSAttributedString alloc] initWithString:@"›  " attributes:dotAttrs]];
        [body appendAttributedString:[[NSAttributedString alloc] initWithString:lines[i] attributes:bulletAttrs]];
    }

    UILabel *bodyLabel = [[UILabel alloc] init];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.attributedText = body;
    bodyLabel.numberOfLines = 0;

    [cell.contentView addSubview:versionLabel];
    [cell.contentView addSubview:dateLabel];
    [cell.contentView addSubview:bodyLabel];

    UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [versionLabel.leadingAnchor  constraintEqualToAnchor:m.leadingAnchor],
        [versionLabel.topAnchor      constraintEqualToAnchor:m.topAnchor],
        [dateLabel.leadingAnchor     constraintEqualToAnchor:versionLabel.trailingAnchor constant:8],
        [dateLabel.centerYAnchor     constraintEqualToAnchor:versionLabel.centerYAnchor],
        [bodyLabel.leadingAnchor     constraintEqualToAnchor:m.leadingAnchor],
        [bodyLabel.trailingAnchor    constraintEqualToAnchor:m.trailingAnchor],
        [bodyLabel.topAnchor         constraintEqualToAnchor:versionLabel.bottomAnchor constant:8],
        [bodyLabel.bottomAnchor      constraintEqualToAnchor:m.bottomAnchor],
    ]];

    return cell;
}

- (UITableViewCell *)buildChangelogFooterCellInTableView:(UITableView *)tableView
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"changelog-footer"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"changelog-footer"];
    }
    cell.imageView.image = nil;
    cell.textLabel.text = @"See all releases on GitHub";
    cell.textLabel.font = [UIFont systemFontOfSize:15.0];
    cell.textLabel.textColor = settings_cell_tint_color(self.view);
    cell.detailTextLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)buildChangelogCollapsedCellInTableView:(UITableView *)tableView
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"changelog-collapsed"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"changelog-collapsed"];
    }
    NSArray<NSDictionary *> *entries = settings_changelog_entries();
    NSDictionary *first = entries.firstObject;
    NSString *version = first[@"version"] ?: @"";
    NSInteger count = 0;
    for (id c in first[@"changes"]) { if ([c isKindOfClass:[NSString class]]) count++; }
    cell.imageView.image = [SettingsViewController iconBadgeWithSymbol:@"sparkles" color:UIColor.systemYellowColor size:29.0];
    cell.textLabel.text = [NSString stringWithFormat:@"What's New in v%@", version];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld change%@", (long)count, count == 1 ? @"" : @"s"];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)buildChangelogCollapseCellInTableView:(UITableView *)tableView
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"changelog-collapse"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"changelog-collapse"];
    }
    cell.imageView.image = nil;
    cell.textLabel.text = @"Show Less";
    cell.textLabel.font = [UIFont systemFontOfSize:15.0];
    cell.textLabel.textColor = settings_cell_tint_color(self.view);
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)openReleasesPage
{
    NSURL *url = [NSURL URLWithString:@"https://github.com/kolbicz/cyanide/releases"];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (UITableViewCell *)buildDocsCellInTableView:(UITableView *)tableView
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"docs"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"docs"];
    }
    cell.imageView.image = [SettingsViewController iconBadgeWithSymbol:@"book.closed.fill" color:UIColor.systemPurpleColor size:29.0];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.textLabel.text = @"Tweak SDK";
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.text = @"How to write Cyanide tweaks";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)buildAboutCellAtRow:(NSInteger)row tableView:(UITableView *)tableView
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"about"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"about"];
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.text = nil;

    switch (row) {
        case 0:
            cell.imageView.image = [SettingsViewController iconBadgeWithSymbol:@"at" color:UIColor.systemBlueColor size:29.0];
            cell.textLabel.text = @"Twitter";
            cell.detailTextLabel.text = @"@_kolbicz";
            break;
        case 1:
            cell.imageView.image = [SettingsViewController iconBadgeWithSymbol:@"book.closed.fill" color:UIColor.systemPurpleColor size:29.0];
            cell.textLabel.text = @"Tweak SDK";
            break;
        case 2:
            cell.imageView.image = [SettingsViewController iconBadgeWithSymbol:@"app.fill" color:UIColor.systemTealColor size:29.0];
            cell.textLabel.text = @"App Icon";
            cell.detailTextLabel.text = [[self currentAppIconStyle] isEqualToString:@"classic"] ? @"Classic" : @"Modern";
            break;
        case 3:
            cell.imageView.image = [SettingsViewController iconBadgeWithSymbol:@"doc.text.magnifyingglass" color:UIColor.systemGrayColor size:29.0];
            cell.textLabel.text = @"View Log";
            break;
        case 4:
            cell.imageView.image = [SettingsViewController iconBadgeWithSymbol:@"square.and.arrow.up" color:UIColor.systemGreenColor size:29.0];
            cell.textLabel.text = @"Share Log";
            break;
        default:
            cell.imageView.image = [SettingsViewController iconBadgeWithSymbol:@"icloud.and.arrow.up" color:UIColor.systemIndigoColor size:29.0];
            cell.textLabel.text = @"Auto-Upload Logs";
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [[NSUserDefaults standardUserDefaults] boolForKey:kSettingsLogUploadEnabled];
            [sw addTarget:self action:@selector(logUploadSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            break;
    }
    return cell;
}

- (void)logUploadSwitchChanged:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.isOn forKey:kSettingsLogUploadEnabled];
}


- (void)reloadThemerSectionAndQueue
{
    settings_mark_tweak_applied(kSettingsThemerEnabled, NO);
    settings_notify_package_queue_changed_async();
    if (self.detailMode && self.underlyingSection == SectionThemer) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                      withRowAnimation:UITableViewRowAnimationAutomatic];
    } else {
        [self.tableView reloadData];
    }
}

- (void)selectBuiltInIOS6Theme
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:kThemerThemeBuiltinIOS6 forKey:kSettingsThemerThemeID];
    [d synchronize];
    log_user("[THEMER] Selected iOS 6 Theme.\n");
    [self reloadThemerSectionAndQueue];
}

- (void)clearSelectedTheme
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:kThemerThemeNone forKey:kSettingsThemerThemeID];
    [d setObject:@"" forKey:kSettingsThemerCustomThemePath];
    [d setObject:@"" forKey:kSettingsThemerCustomThemeName];
    if ([d boolForKey:kSettingsThemerEnabled]) {
        [d setBool:NO forKey:kSettingsThemerEnabled];
        g_themer_live_stop_requested = 1;
    }
    [d synchronize];
    log_user("[THEMER] Cleared selected theme; the icon theme engine is no longer pending activation.\n");
    [self reloadThemerSectionAndQueue];
}

- (void)presentThemerFormatGuide
{
    ThemerFormatGuideViewController *vc =
        [[ThemerFormatGuideViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    vc.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:vc
                                                      action:@selector(dismissGuide)];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)presentThemerImporter
{
    UIAlertController *hint = [UIAlertController
        alertControllerWithTitle:@"Import Theme Folder"
                         message:@"Navigate into your theme folder so you can see the PNG files inside, then tap Open in the top-right corner to import the folder."
                  preferredStyle:UIAlertControllerStyleAlert];
    [hint addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder, UTTypePropertyList]];
        settings_set_picker_mode(picker, @"themer");
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [hint addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:hint animated:YES completion:nil];
}

- (void)presentSnowBoardLiteFolderImporter
{
    UIAlertController *hint = [UIAlertController
        alertControllerWithTitle:@"Import Theme Folder"
                         message:@"Navigate into your theme folder so you can see IconBundles inside, then tap Open.\n\nIf tapping Open does nothing, your signing tool may need \"Match provisioning identifier\" enabled, or you can use Import Theme Archive instead."
                  preferredStyle:UIAlertControllerStyleAlert];
    [hint addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder]];
        settings_set_picker_mode(picker, @"snowboardlite");
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [hint addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:hint animated:YES completion:nil];
}

- (void)presentSnowBoardLiteArchiveImporter
{
    UIAlertController *hint = [UIAlertController
        alertControllerWithTitle:@"Import Theme Archive"
                         message:@"Pick a ZIP or DEB file that contains an IconBundles directory. Cyanide extracts and imports a local copy."
                  preferredStyle:UIAlertControllerStyleAlert];
    [hint addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        NSArray<UTType *> *types = @[
            UTTypeZIP,
            [UTType typeWithFilenameExtension:@"deb"] ?: UTTypeData,
        ];
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
        settings_set_picker_mode(picker, @"snowboardlite");
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [hint addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:hint animated:YES completion:nil];
}

- (void)presentPasscodeBackupExporter
{
    NSUInteger backups = settings_passcode_theme_backup_count();
    if (backups == 0) {
        log_user("[PASSCODE] Nothing to export: no original backups are saved yet.\n");
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"Nothing to Export"
                             message:@"Cyanide saves a keypad original the first time a style writes over it. Nothing has been saved yet — apply a style first, then export before reinstalling Cyanide."
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    // One archive instead of a folder of .orig files: Files, Mail and chat apps
    // all handle a single .zip, and the importer reads the same archive back.
    NSError *error = nil;
    NSUInteger skipped = 0;
    NSURL *archive = settings_passcode_create_backup_archive(&error, &skipped);
    if (!archive) {
        log_user("[PASSCODE] Could not pack the backups: %s\n",
                 error.localizedDescription.UTF8String ?: "unknown");
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"Could Not Pack Originals"
                             message:(error.localizedDescription ?: @"The originals could not be read.")
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    void (^presentExportPicker)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForExportingURLs:@[archive] asCopy:YES];
        // The exporting picker calls the same delegate as the importers. Without a
        // mode the callback falls through to the themer branch and reports an
        // import failure right after a successful export.
        settings_set_picker_mode(picker, @"passcode-export");
        picker.delegate = strongSelf;
        [strongSelf presentViewController:picker animated:YES completion:nil];
    };

    if (skipped == 0) {
        presentExportPicker();
        return;
    }

    // A backup that could not be read is left out of the archive. Say so before
    // the picker opens: an archive that quietly omits originals is worse than no
    // archive at all, because it looks complete.
    UIAlertController *skipAlert = [UIAlertController
        alertControllerWithTitle:@"Some Originals Were Skipped"
                         message:[NSString stringWithFormat:
                                  @"%lu saved original(s) could not be read and are not in this archive. Export the rest now, then retry on a device that still has them.",
                                  (unsigned long)skipped]
                  preferredStyle:UIAlertControllerStyleAlert];
    [skipAlert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        presentExportPicker();
    }]];
    [skipAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:skipAlert animated:YES completion:nil];
}

- (void)presentPasscodeBackupImporter
{
    NSMutableArray<UTType *> *types = [NSMutableArray arrayWithObjects:UTTypeZIP, UTTypeFolder, nil];
    UTType *origType = [UTType typeWithFilenameExtension:@"orig"];
    if (origType) [types addObject:origType];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    settings_set_picker_mode(picker, @"passcode-backups");
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

// Long-press entry point for erasing the stored originals. Deliberately not on
// the row's tap action: tapping Import Originals adds originals, this removes them.
- (void)handlePasscodeBackupRowLongPress:(UILongPressGestureRecognizer *)recognizer
{
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    [self presentPasscodeBackupDeletion];
}

- (NSString *)passcodeDeletionMessageForBackups:(NSUInteger)backups
                                         digits:(NSUInteger)digits
                                      remaining:(NSInteger)remaining
{
    NSString *warning = [NSString stringWithFormat:
        @"This erases %lu saved original(s) covering %lu digit(s). Restore Original Digits will not be able to put the stock keypad art back afterwards — use Export Originals first if you want to keep a copy.",
        (unsigned long)backups, (unsigned long)digits];
    if (remaining <= 0) return warning;
    return [NSString stringWithFormat:@"Delete becomes available in %lds…\n\n%@", (long)remaining, warning];
}

- (void)presentPasscodeBackupDeletion
{
    NSUInteger backups = settings_passcode_theme_backup_count();
    NSUInteger digits = settings_passcode_backup_digit_count();
    if (backups == 0) {
        log_user("[PASSCODE] Nothing to delete: no original backups are saved.\n");
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"Nothing to Delete"
                             message:@"No saved originals are on this device."
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    // Five seconds of enforced waiting before the button unlocks: these files are
    // the only way back to the stock keypad art on this device, and Cyanide has no
    // way to rebuild them.
    __block NSInteger remaining = 5;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Delete All Originals?"
                         message:[self passcodeDeletionMessageForBackups:backups
                                                                  digits:digits
                                                               remaining:remaining]
                  preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *deleteAction = [UIAlertAction
        actionWithTitle:@"Delete All Originals"
                  style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *action) {
        (void)action;
        [self deletePasscodeBackupsConfirmed];
    }];
    deleteAction.enabled = NO;
    [alert addAction:deleteAction];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [self presentViewController:alert animated:YES completion:nil];

    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        // The sheet is gone (cancelled or dismissed): stop ticking.
        if (alert.presentingViewController == nil) {
            [timer invalidate];
            return;
        }
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        remaining--;
        if (remaining <= 0) {
            deleteAction.enabled = YES;
            alert.message = [strongSelf passcodeDeletionMessageForBackups:backups
                                                                   digits:digits
                                                                remaining:0];
            [timer invalidate];
            return;
        }
        alert.message = [strongSelf passcodeDeletionMessageForBackups:backups
                                                               digits:digits
                                                            remaining:remaining];
    }];
}

- (void)deletePasscodeBackupsConfirmed
{
    NSUInteger removed = settings_passcode_delete_all_backups();
    [self reloadSectionOrAll:SectionPasscodeTheme];
    settings_notify_package_queue_changed_async();

    NSString *message = removed > 0
        ? [NSString stringWithFormat:@"%lu original(s) deleted. Restore Original Digits has nothing to write back now.",
                                     (unsigned long)removed]
        : @"No original files were found to delete.";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:(removed > 0 ? @"Originals Deleted" : @"Nothing Deleted")
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)handlePasscodeBackupImport:(NSArray<NSURL *> *)urls
{
    NSMutableArray<NSURL *> *scoped = [NSMutableArray array];
    for (NSURL *url in urls) {
        if ([url startAccessingSecurityScopedResource]) [scoped addObject:url];
    }

    // A .zip is unpacked first — that is how an export from another device
    // arrives (one file through Files, Mail or a chat app).
    NSMutableArray<NSURL *> *items = [NSMutableArray array];
    NSMutableArray<NSString *> *tempDirs = [NSMutableArray array];
    NSMutableArray<NSString *> *unzipFailures = [NSMutableArray array];
    for (NSURL *url in urls) {
        if (![url.pathExtension.lowercaseString isEqualToString:@"zip"]) {
            [items addObject:url];
            continue;
        }
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"PasscodeBackups-%@", NSUUID.UUID.UUIDString]];
        NSError *unzipError = nil;
        if (SBLExtractArchiveToDirectory(url, tmp, &unzipError)) {
            [items addObject:[NSURL fileURLWithPath:tmp isDirectory:YES]];
            [tempDirs addObject:tmp];
        } else {
            NSString *why = unzipError.localizedDescription ?: @"not a readable archive";
            log_user("[PASSCODE] Could not open %s: %s\n",
                     url.lastPathComponent.UTF8String, why.UTF8String);
            [unzipFailures addObject:[NSString stringWithFormat:@"%@ — %@",
                                                                url.lastPathComponent, why]];
        }
    }

    NSUInteger skipped = 0;
    NSUInteger failed = 0;
    NSUInteger unusable = 0;
    NSUInteger added = items.count > 0
        ? settings_passcode_import_backup_items(items, &skipped, &failed, &unusable)
        : 0;

    for (NSString *tmp in tempDirs) {
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    }
    for (NSURL *url in scoped) [url stopAccessingSecurityScopedResource];

    NSString *message;
    if (added == 0 && skipped == 0 && failed == 0 && unzipFailures.count > 0) {
        // The archive itself never opened — say that, instead of blaming what is
        // (or is not) inside it.
        message = [NSString stringWithFormat:@"Could not open the selected archive:\n\n%@",
                                             [unzipFailures componentsJoinedByString:@"\n"]];
    } else if (added == 0 && skipped == 0 && failed == 0) {
        message = @"No saved originals were found in the selection. On the device that still has the originals, tap Export Originals, then import the .zip it saves here.";
    } else if (added == 0 && failed == 0) {
        message = [NSString stringWithFormat:
            @"Nothing to import: all %lu original(s) are already present on this device.",
            (unsigned long)skipped];
    } else {
        // Report every outcome separately: a failure count reported on its own
        // reads as a clean success.
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        [parts addObject:[NSString stringWithFormat:@"Imported %lu original(s).", (unsigned long)added]];
        if (skipped > 0) {
            [parts addObject:[NSString stringWithFormat:@"%lu were already present and were kept.",
                                                        (unsigned long)skipped]];
        }
        if (failed > 0) {
            [parts addObject:[NSString stringWithFormat:@"%lu could not be copied or verified.",
                                                        (unsigned long)failed]];
        }
        if (unusable > 0) {
            [parts addObject:[NSString stringWithFormat:
                @"%lu cannot be matched to keypad files, so Restore Original Digits can't write them back.",
                (unsigned long)unusable]];
        }
        if (unzipFailures.count > 0) {
            [parts addObject:[NSString stringWithFormat:@"%lu archive(s) could not be opened.",
                                                        (unsigned long)unzipFailures.count]];
        }
        [parts addObject:@"Tap Restore Original Digits to write the imported originals back."];
        message = [parts componentsJoinedByString:@"\n\n"];
    }

    [self reloadSectionOrAll:SectionPasscodeTheme];
    settings_notify_package_queue_changed_async();

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Import Originals"
                                                              message:message
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)presentPasscodeThemeImporter
{
    UIAlertController *hint = [UIAlertController
        alertControllerWithTitle:@"Import Passcode Style"
                         message:@"Pick a .passthm style or a ZIP of keypad digit art — a .passthm is the same archive under another extension. An export of the saved originals works too. The art is copied into Cyanide's library; the file you pick stays untouched."
                  preferredStyle:UIAlertControllerStyleAlert];
    [hint addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        NSMutableArray<UTType *> *types = [NSMutableArray arrayWithObject:UTTypeZIP];
        UTType *passthm = [UTType typeWithFilenameExtension:@"passthm"];
        if (passthm && ![types containsObject:passthm]) [types addObject:passthm];

        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
        settings_set_picker_mode(picker, @"passcode");
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [hint addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:hint animated:YES completion:nil];
}

- (void)presentPasscodeDigitPicker:(NSString *)digit
{
    self.pendingPasscodeDigit = digit;

    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter imagesFilter];
    config.selectionLimit = 1;
    config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;

    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)clearPasscodeTheme
{
    settings_passcode_clear_selected_theme();
    log_user("[PASSCODE] Cleared the selected style. Original backups are kept.\n");
    [self reloadSectionOrAll:SectionPasscodeTheme];
    settings_notify_package_queue_changed_async();
}

- (void)runPasscodeThemeApply:(BOOL)apply
{
    if (apply && settings_passcode_selected_theme() == nil) {
        log_user("[PASSCODE] Failed: no style is selected. Import or build one first.\n");
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"No Style Selected"
                             message:@"Import a .passthm / ZIP style below, or tap a key in the preview to pick that digit's photo, then apply again."
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    if (!apply && settings_passcode_theme_backup_count() == 0) {
        log_user("[PASSCODE] Nothing to restore: no original digit backups were found.\n");
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"Nothing To Restore"
                             message:@"No originals are saved on this device. Styles applied by another app are not covered by Cyanide's originals."
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    NSString *title = apply ? @"Apply Passcode Style?"
                            : @"Restore Original Digits?";
    NSString *message = apply
        ? @"Applies the selected digits to the Lock Screen keypad and verifies every write.\n\nLock and unlock (or respring) afterwards to see the change."
        : @"Writes the saved originals back over the keypad art and verifies each restore.";

    if (apply && settings_passcode_theme_backup_count() == 0 &&
        settings_passcode_originals_were_discarded()) {
        message = [message stringByAppendingString:
            @"\n\nWarning: the saved originals were deleted, so the keypad art on this device cannot be proven to be the stock art. Apply saves whatever is there now as the \"original\", so Restore brings that back instead of the factory art."];
    }

    if (!settings_krw_available_without_exploit()) {
        message = [message stringByAppendingString:
            @"\n\nKernel access is not active yet: Cyanide runs the chain first, so this takes noticeably longer."];
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:(apply ? @"Apply" : @"Restore")
                                                style:(apply ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive)
                                              handler:^(UIAlertAction *a) {
        (void)a;
        [self performPasscodeThemeApply:apply];
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)performPasscodeThemeApply:(BOOL)apply
{
    // Same shape as the Location Simulator / FastLockX actions: present the
    // activity log first, run in the background, then report through Cyanide's
    // shared completion notification so that screen itself flips to "Complete"
    // with the result text. No extra alert of our own.
    dispatch_block_t startAction = ^{
        // __block so both the expiration handler and the completion can clear it:
        // an ended-but-not-invalidated task tells iOS the app is still holding
        // background time, and iOS answers that by killing the process.
        __block UIBackgroundTaskIdentifier bgTask = [[UIApplication sharedApplication]
            beginBackgroundTaskWithName:@"Passcode Style"
                      expirationHandler:^{
            log_user("[PASSCODE] Background time expired; the keypad write may not have finished.\n");
            if (bgTask != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:bgTask];
                bgTask = UIBackgroundTaskInvalid;
            }
        }];

        __weak typeof(self) weakSelf = self;
        // User-initiated work: the default-priority queue can be throttled under
        // low-power / background conditions, which is exactly when the keypad
        // write has to finish before the background task above expires.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL ok = settings_apply_passcode_theme_now(apply);
            NSString *summary = settings_passcode_last_result_summary()
                ?: (apply ? @"Passcode style finished." : @"Original digits restored.");

            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                [strongSelf reloadSectionOrAll:SectionPasscodeTheme];
                settings_notify_package_queue_changed_async();

                [[NSNotificationCenter defaultCenter]
                    postNotificationName:kSettingsActionsDidCompleteNotification
                                  object:nil
                                userInfo:@{
                    kSettingsActionsDidCompleteSuccessKey: @(ok),
                    kSettingsActionsDidCompleteMessageKey: summary
                }];

                if (bgTask != UIBackgroundTaskInvalid) {
                    [[UIApplication sharedApplication] endBackgroundTask:bgTask];
                    bgTask = UIBackgroundTaskInvalid;
                }
            });
        });
    };

    [self presentActivityLogWithCompletion:startAction];
}

- (void)presentLiveWPVideoPicker
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Choose Video"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Photos"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        (void)a;
        [self presentLiveWPPhotosPicker];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Files"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        (void)a;
        [self presentLiveWPDocumentPicker];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = self.view;
        pop.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        pop.permittedArrowDirections = 0;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentLiveWPPhotosPicker
{
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter videosFilter];
    config.selectionLimit = 1;
    config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;

    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (NSArray<UTType *> *)liveWPVideoDocumentTypes
{
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    NSArray<NSString *> *extensions = @[@"mp4", @"mov", @"m4v"];
    for (NSString *ext in extensions) {
        UTType *type = [UTType typeWithFilenameExtension:ext];
        if (type) [types addObject:type];
    }
    [types addObject:UTTypeMovie];
    [types addObject:UTTypeAudiovisualContent];
    return types;
}

- (void)presentLiveWPDocumentPicker
{
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:[self liveWPVideoDocumentTypes] asCopy:YES];
    settings_set_picker_mode(picker, @"livewp");
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (BOOL)importLiveWPVideoAtURL:(NSURL *)url error:(NSError **)error
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length == 0) return NO;
    NSString *liveDir = [docs stringByAppendingPathComponent:@"LiveWP"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:liveDir withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    NSString *ext = url.pathExtension.length ? url.pathExtension.lowercaseString : @"mov";
    NSSet<NSString *> *allowed = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v"]];
    if (![allowed containsObject:ext]) {
        if (error) {
            *error = [NSError errorWithDomain:@"LiveWP"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Choose an MP4, MOV, or M4V video."}];
        }
        return NO;
    }

    NSString *base = url.URLByDeletingPathExtension.lastPathComponent;
    if (base.length == 0) base = @"LiveWP";
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString *safeBase = [[base componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"-"];
    if (safeBase.length == 0) safeBase = @"LiveWP";
    NSString *fileName = [NSString stringWithFormat:@"%@-%llu.%@",
                          safeBase,
                          (unsigned long long)(NSDate.date.timeIntervalSince1970 * 1000.0),
                          ext];
    NSString *dest = [liveDir stringByAppendingPathComponent:fileName];
    if (![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:error]) {
        return NO;
    }

    NSString *relative = [@"LiveWP" stringByAppendingPathComponent:fileName];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:relative forKey:kSettingsLiveWPVideoPath];
    [d synchronize];
    log_user("[LIVEWP] Selected video: %s\n", fileName.UTF8String);
    return YES;
}

- (void)finishLiveWPVideoImportAndSwapIfRunning
{
    [self reloadSectionOrAll:SectionLiveWP];

    BOOL applied = settings_tweak_is_applied(kSettingsLiveWPEnabled);
    log_user("[LIVEWP] import: applied=%d rc_ready=%d\n", applied, g_springboard_rc_ready);
    if (!applied || !g_springboard_rc_ready) {
        settings_notify_package_queue_changed_async();
        return;
    }

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        bool ok = false;
        @synchronized (settings_rc_lock()) {
            if (settings_cleanup_in_progress() || !g_springboard_rc_ready) return;
            NSString *path = livewp_absolute_path();
            log_user("[LIVEWP] import: swap path=%s\n", path ? path.UTF8String : "(nil)");
            if (path.length > 0) {
                ok = livewp_swap_video_in_session(path);
                settings_mark_tweak_applied(kSettingsLiveWPEnabled, ok);
            }
        }
        log_user("%s LiveWP video swap %s.\n",
                 ok ? "[OK]" : "[WARN]",
                 ok ? "completed" : "did not complete");
        if (ok) settings_start_livewp_live_loop();
        settings_notify_package_queue_changed_async();
    });
}

- (NSString *)liveWPPreferredTypeIdentifierForProvider:(NSItemProvider *)provider
{
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (UTType *type in [self liveWPVideoDocumentTypes]) {
        if (type.identifier.length > 0) [identifiers addObject:type.identifier];
    }
    [identifiers addObjectsFromArray:@[
        @"public.mpeg-4",
        @"com.apple.m4v-video",
        @"com.apple.quicktime-movie",
        @"public.movie",
        @"public.audiovisual-content",
    ]];
    for (NSString *identifier in identifiers) {
        if ([provider hasItemConformingToTypeIdentifier:identifier]) return identifier;
    }
    return nil;
}

- (void)finishLiveWPVideoImportFromURL:(NSURL *)url
                           displayName:(NSString *)displayName
{
    NSError *err = nil;
    BOOL ok = [self importLiveWPVideoAtURL:url error:&err];
    BOOL liveReady = settings_tweak_is_applied(kSettingsLiveWPEnabled) && g_springboard_rc_ready;
    NSString *name = displayName.length ? displayName : (url.lastPathComponent ?: @"Video");
    NSString *successMessage = liveReady
        ? [NSString stringWithFormat:@"%@ was imported and will swap into the running LiveWP session.", name]
        : [NSString stringWithFormat:@"%@ is ready. Toggle LiveWP on and tap Run to apply.", name];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ok) {
            NSString *msg = err.localizedDescription ?: @"The selected video could not be imported.";
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Import Failed"
                                                                         message:msg
                                                                  preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
            return;
        }
        [self finishLiveWPVideoImportAndSwapIfRunning];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Video Selected"
                                                                     message:successMessage
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    });
}

- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results
{
    [picker dismissViewControllerAnimated:YES completion:nil];

    // Consume the digit target before the early return so a cancelled picker
    // cannot leave it armed for the next video selection.
    NSString *passcodeDigit = self.pendingPasscodeDigit;
    self.pendingPasscodeDigit = nil;

    PHPickerResult *result = results.firstObject;
    if (!result) return;

    if (passcodeDigit.length > 0) {
        [self handlePasscodeDigitPick:result digit:passcodeDigit];
        return;
    }

    NSItemProvider *provider = result.itemProvider;
    NSString *identifier = [self liveWPPreferredTypeIdentifierForProvider:provider];
    if (identifier.length == 0) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Import Failed"
                                                                     message:@"Choose an MP4, MOV, or M4V video."
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    NSString *displayName = provider.suggestedName ?: @"Video";
    [provider loadFileRepresentationForTypeIdentifier:identifier
                                    completionHandler:^(NSURL *url, NSError *error) {
        if (!url || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *msg = error.localizedDescription ?: @"The selected video could not be opened.";
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Import Failed"
                                                                             message:msg
                                                                      preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
            });
            return;
        }
        [self finishLiveWPVideoImportFromURL:url displayName:displayName];
    }];
}

- (void)handlePasscodeDigitPick:(PHPickerResult *)result digit:(NSString *)digit
{
    NSItemProvider *provider = result.itemProvider;
    if (![provider canLoadObjectOfClass:UIImage.class]) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Import Failed"
                                                                     message:@"That item is not a photo. Choose an image for the keypad digit."
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [provider loadObjectOfClass:UIImage.class
              completionHandler:^(__kindof id<NSItemProviderReading> object, NSError *error) {
        UIImage *image = [object isKindOfClass:UIImage.class] ? (UIImage *)object : nil;
        // Resize off the main thread; the keypad art is only 202 points tall.
        NSData *png = settings_passcode_png_data_for_image(image);

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (png.length == 0) {
                UIAlertController *ac = [UIAlertController
                    alertControllerWithTitle:@"Import Failed"
                                     message:(error.localizedDescription ?: @"The selected photo could not be read.")
                              preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [strongSelf presentViewController:ac animated:YES completion:nil];
                return;
            }

            NSError *err = nil;
            NSDictionary *theme = settings_passcode_ensure_selected_theme(&err);
            BOOL ok = theme && settings_passcode_theme_set_digit_image(theme, digit, png, &err);
            if (!ok) {
                UIAlertController *ac = [UIAlertController
                    alertControllerWithTitle:@"Digit Not Saved"
                                     message:(err.localizedDescription ?: @"The digit image could not be saved.")
                              preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [strongSelf presentViewController:ac animated:YES completion:nil];
                return;
            }

            log_user("[PASSCODE] Digit %s art saved into \"%s\".\n",
                     digit.UTF8String,
                     settings_passcode_selected_theme_display_name().UTF8String);
            [strongSelf reloadSectionOrAll:SectionPasscodeTheme];
            settings_notify_package_queue_changed_async();

            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:[NSString stringWithFormat:@"Digit %@ Saved", digit]
                                 message:@"Apply the style to write it over the keypad art."
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:ac animated:YES completion:nil];
        });
    }];
}

- (BOOL)importThemerFolderAtURL:(NSURL *)url error:(NSError **)error
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *target = settings_themer_imported_theme_dir();
    NSString *root = settings_themer_documents_theme_root();
    if (!target || !root) return NO;

    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:error];
    if (error && *error) return NO;

    NSArray<NSURL *> *files = [fm contentsOfDirectoryAtURL:url
                                includingPropertiesForKeys:nil
                                                   options:0
                                                     error:error];
    if (!files) return NO;

    NSMutableArray<NSURL *> *pngs = [NSMutableArray array];
    for (NSURL *file in files) {
        if ([file.pathExtension.lowercaseString isEqualToString:@"png"]) {
            [pngs addObject:file];
        }
    }
    if (pngs.count == 0) return NO;

    [fm removeItemAtPath:target error:nil];
    [fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:error];
    if (error && *error) return NO;
    [fm removeItemAtPath:settings_themer_imported_plist_path() error:nil];

    for (NSURL *png in pngs) {
        NSString *dst = [target stringByAppendingPathComponent:png.lastPathComponent];
        if (![fm copyItemAtURL:png toURL:[NSURL fileURLWithPath:dst] error:error]) {
            return NO;
        }
    }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:kThemerThemeCustom forKey:kSettingsThemerThemeID];
    [d setObject:target forKey:kSettingsThemerCustomThemePath];
    [d setObject:url.lastPathComponent.length ? url.lastPathComponent : @"Imported Theme"
          forKey:kSettingsThemerCustomThemeName];
    [d synchronize];
    log_user("[THEMER] Imported custom folder theme: %lu PNG file(s).\n",
             (unsigned long)pngs.count);
    return YES;
}

- (BOOL)importThemerPlistAtURL:(NSURL *)url error:(NSError **)error
{
    NSDictionary *dict = settings_themer_load_plist_theme(url.path);
    if (dict.count == 0) return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = settings_themer_documents_theme_root();
    NSString *target = settings_themer_imported_plist_path();
    if (!root || !target) return NO;
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:error];
    if (error && *error) return NO;
    [fm removeItemAtPath:target error:nil];
    [fm removeItemAtPath:settings_themer_imported_theme_dir() error:nil];
    if (![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:target] error:error]) {
        return NO;
    }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:kThemerThemeCustom forKey:kSettingsThemerThemeID];
    [d setObject:target forKey:kSettingsThemerCustomThemePath];
    [d setObject:url.lastPathComponent.length ? url.lastPathComponent : @"Imported Theme"
          forKey:kSettingsThemerCustomThemeName];
    [d synchronize];
    log_user("[THEMER] Imported custom plist theme: %lu icon entries.\n",
             (unsigned long)dict.count);
    return YES;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    // The mode belongs to the picker that was tapped, not to this controller, so
    // one sheet's mode cannot affect another pick. Pickers with no mode of their
    // own fall back to the extension branches below.
    NSString *mode = settings_picker_mode(controller) ?: @"themer";

    // An exporting picker reports through this delegate too: the archive has been
    // handed to Files and there is nothing to import.
    if ([mode isEqualToString:@"passcode-export"]) {
        log_user("[PASSCODE] Backup archive export finished.\n");
        return;
    }

    // Backup folders, .orig files and .zip archives are multi-item and the whole
    // array matters, so they are handled before the single-file paths below take
    // urls.firstObject.
    if ([mode isEqualToString:@"passcode-backups"]) {
        [self handlePasscodeBackupImport:urls];
        return;
    }

    NSURL *url = urls.firstObject;
    if (!url) return;
    NSString *ext = url.pathExtension.lowercaseString;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&isDir];
    printf("[IMPORT] url=%s scoped=%d exists=%d isDir=%d mode=%s\n",
           url.path.UTF8String, scoped, exists, isDir, mode.UTF8String);
    if (!exists) {
        if (scoped) [url stopAccessingSecurityScopedResource];
        log_user("[IMPORT] Cannot access selected file. Try a different location or file provider.\n");
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"Import Failed"
                              message:@"The selected item could not be accessed. Try picking from a different location or file provider."
                       preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }


    // =========================================================================
    // QuickLoader (JS text filter)
    // =========================================================================
    if ([ext isEqualToString:@"js"] || [ext isEqualToString:@"txt"]) {
        NSError *err = nil;
        NSString *content = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&err];

        if (content) {
            self.qlScriptName = [url lastPathComponent];
            self.qlRawScript = content;

            NSMutableArray *params = [NSMutableArray array];
            self.qlValues = [NSMutableDictionary dictionary];

            NSArray *lines = [content componentsSeparatedByString:@"\n"];
            for (NSString *line in lines) {
                if ([line containsString:@"@param:"]) {
                NSArray *parts = [line componentsSeparatedByString:@"|"];
                if (parts.count >= 4) {
                        NSArray *typeParts = [parts[0] componentsSeparatedByString:@"@param:"];
                        if (typeParts.count < 2) continue;
                        NSString *rawType = typeParts[1];
                        NSString *type = [rawType stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        NSString *varName = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        NSString *label = [parts[2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        NSString *defValue = [parts[3] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if (!settings_js_identifier_valid(varName)) continue;

                        NSMutableDictionary *paramDict = [NSMutableDictionary dictionaryWithDictionary:@{
                            @"type": type, @"varName": varName, @"label": label, @"default": defValue
                        }];

                        if (parts.count >= 5 && ([type isEqualToString:@"slider"] || [type isEqualToString:@"number"])) {
                            NSString *rangeStr = [parts[4] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                            NSArray *rangeParts = [rangeStr componentsSeparatedByString:@"-"];
                            if (rangeParts.count == 2) {
                                paramDict[@"min"] = rangeParts[0];
                                paramDict[@"max"] = rangeParts[1];
                            }
                        }

                        [params addObject:paramDict];
                        self.qlValues[varName] = defValue;
                    }
                }
            }
            self.qlParams = params;

            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            [d setObject:self.qlScriptName forKey:@"QuickLoaderSourceScriptName"];
            [d setObject:self.qlRawScript forKey:@"QuickLoaderSourceRawJS"];
            [d setObject:self.qlValues forKey:@"QuickLoaderSourceValues"];
            [d removeObjectForKey:@"QuickLoaderSourceRepoURL"];
            [d removeObjectForKey:@"QuickLoaderSourceTweakID"];
            [d synchronize];

            // first auto injection and ui refresh
            [self applyQuickLoaderScript];
            [self.tableView reloadData];
        }

        if (scoped) [url stopAccessingSecurityScopedResource];

        // So that the other tweaks don't get the .js file
        return;
    }


    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        BOOL ok = NO;
        NSString *successTitle = @"Theme Imported";
        NSString *successMessage = nil;

        if ([mode isEqualToString:@"livewp"]) {
            ok = [self importLiveWPVideoAtURL:url error:&err];
            successTitle = @"Video Selected";
            BOOL liveReady = settings_tweak_is_applied(kSettingsLiveWPEnabled) && g_springboard_rc_ready;
            successMessage = liveReady
                ? [NSString stringWithFormat:@"%@ was imported and will swap into the running LiveWP session.",
                                             url.lastPathComponent ?: @"Video"]
                : [NSString stringWithFormat:@"%@ is ready. Toggle LiveWP on and tap Run to apply.",
                                             url.lastPathComponent ?: @"Video"];
        } else if ([mode isEqualToString:@"snowboardlite"]) {
            if (isDir) {
                ok = settings_sbl_import_folder_theme(url, &err);
            } else {
                NSString *tmpRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"SnowBoardLite-%@", NSUUID.UUID.UUIDString]];
                ok = SBLExtractArchiveToDirectory(url, tmpRoot, &err);
                if (ok) {
                    NSString *displayName = url.URLByDeletingPathExtension.lastPathComponent ?: @"Imported Theme";
                    ok = settings_sbl_import_folder_theme_named([NSURL fileURLWithPath:tmpRoot],
                                                               displayName,
                                                               @"archive",
                                                               &err);
                }
                [[NSFileManager defaultManager] removeItemAtPath:tmpRoot error:nil];
            }
            successTitle = @"SnowBoard Theme Imported";
            NSString *name = settings_snowboardlite_selected_theme_display_name();
            successMessage = [NSString stringWithFormat:@"\"%@\" is now selected. Toggle SnowBoard Lite on and tap Run to apply.", name];
        } else if ([mode isEqualToString:@"passcode"]) {
            if (isDir) {
                ok = settings_passcode_import_folder_named(url, url.lastPathComponent, &err);
            } else {
                NSString *tmpRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"PasscodeTheme-%@", NSUUID.UUID.UUIDString]];
                ok = SBLExtractArchiveToDirectory(url, tmpRoot, &err);
                if (ok) {
                    NSString *displayName = url.URLByDeletingPathExtension.lastPathComponent ?: @"Imported Style";
                    ok = settings_passcode_import_folder_named([NSURL fileURLWithPath:tmpRoot],
                                                               displayName,
                                                               &err);
                }
                [[NSFileManager defaultManager] removeItemAtPath:tmpRoot error:nil];
            }
            successTitle = @"Passcode Style Imported";
            successMessage = [NSString stringWithFormat:
                @"\"%@\" is now selected. Use Apply Style Now below to write it to the keypad.",
                settings_passcode_selected_theme_display_name()];
        } else {
            ok = isDir ? [self importThemerFolderAtURL:url error:&err]
                       : [self importThemerPlistAtURL:url error:&err];
            NSString *name = settings_themer_selected_theme_display_name();
            successMessage = [NSString stringWithFormat:@"\"%@\" is now selected. Toggle SnowBoard Lite on and tap Run to apply.", name];
        }
        if (scoped) [url stopAccessingSecurityScopedResource];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                NSString *msg = err.localizedDescription ?: @"The selected item could not be imported.";
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Import Failed"
                                                                             message:msg
                                                                      preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:ac animated:YES completion:nil];
                return;
            }
            if ([mode isEqualToString:@"snowboardlite"]) {
                settings_mark_tweak_applied(kSettingsSnowBoardLiteEnabled, NO);
                settings_notify_package_queue_changed_async();
                if (self.detailMode && self.underlyingSection == SectionSnowBoardLite) {
                    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                                  withRowAnimation:UITableViewRowAnimationAutomatic];
                } else {
                    [self.tableView reloadData];
                }
            } else if ([mode isEqualToString:@"livewp"]) {
                [self finishLiveWPVideoImportAndSwapIfRunning];
            } else if ([mode isEqualToString:@"passcode"]) {
                settings_notify_package_queue_changed_async();
                [self reloadSectionOrAll:SectionPasscodeTheme];
            } else {
                [self reloadThemerSectionAndQueue];
            }
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:successTitle
                                 message:successMessage
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        });
    });
}


// ==========================================
// QUICKLOADER: injecting and saving
// ==========================================
- (NSString *)compileQuickLoaderScript {
    if (!self.qlRawScript) return nil;

    NSMutableString *finalScript = [NSMutableString stringWithString:@"//Variables injected by Cyanide\n"];
    for (NSDictionary *param in self.qlParams) {
        NSString *varName = param[@"varName"];
        NSString *type = param[@"type"];
        NSString *currentValue = settings_string_or_empty(self.qlValues[varName]);
        if (!settings_js_identifier_valid(varName)) continue;

        if ([type isEqualToString:@"switch"]) {
            [finalScript appendFormat:@"var %@ = %@;\n", varName, [currentValue boolValue] ? @"true" : @"false"];
        } else if ([type isEqualToString:@"text"] || [type isEqualToString:@"color"]) {
            [finalScript appendFormat:@"var %@ = %@;\n", varName, settings_js_string_literal(currentValue)];
        } else if ([type isEqualToString:@"slider"] || [type isEqualToString:@"number"]) {
            [finalScript appendFormat:@"var %@ = %@;\n", varName, settings_js_number_literal(currentValue)];
        }
    }
    [finalScript appendString:@"// --------------------------------------\n\n"];
    [finalScript appendString:self.qlRawScript];
    return finalScript;
}

- (void)applyQuickLoaderScript {
    if (!self.qlRawScript) return;

    NSMutableString *finalScript = [NSMutableString stringWithString:@"//Variables injected by Cyanide\n"];

    //from UI values to JS variables
    for (NSDictionary *param in self.qlParams) {
        NSString *varName = param[@"varName"];
        NSString *type = param[@"type"];
        NSString *currentValue = settings_string_or_empty(self.qlValues[varName]);
        if (!settings_js_identifier_valid(varName)) continue;

        if ([type isEqualToString:@"switch"]) {
            [finalScript appendFormat:@"var %@ = %@;\n", varName, [currentValue boolValue] ? @"true" : @"false"];
        } else if ([type isEqualToString:@"text"] || [type isEqualToString:@"color"]) {
            [finalScript appendFormat:@"var %@ = %@;\n", varName, settings_js_string_literal(currentValue)];
        } else if ([type isEqualToString:@"slider"] || [type isEqualToString:@"number"]) {
            [finalScript appendFormat:@"var %@ = %@;\n", varName, settings_js_number_literal(currentValue)];
        }
    }

    [finalScript appendString:@"// --------------------------------------\n\n"];

    //add original code
    [finalScript appendString:self.qlRawScript];

    //save for QuickLoader.m
    [[NSUserDefaults standardUserDefaults] setObject:finalScript forKey:@"QuickLoaderSavedJS"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSLog(@"[Cyanide] Dynamic JS Tweak Saved Successfully!");
}



- (void)reloadSectionOrAll:(NSInteger)section
{
    if (self.detailMode && self.underlyingSection == section) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                      withRowAnimation:UITableViewRowAnimationAutomatic];
    } else {
        [self.tableView reloadData];
    }
}

- (void)presentNSBarPositionPicker
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"NSBar Position"
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *positions = @[
        @(NSBarPositionTopLeft),
        @(NSBarPositionBottomLeft),
        @(NSBarPositionTopRight),
        @(NSBarPositionBottomRight),
        @(NSBarPositionCenter),
    ];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSNumber *number in positions) {
        NSInteger pos = number.integerValue;
        NSString *title = settings_nsbar_position_name(pos);
        if (pos == [d integerForKey:kSettingsNSBarPosition]) {
            title = [title stringByAppendingString:@" ✓"];
        }
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [d setInteger:pos forKey:kSettingsNSBarPosition];
            [d synchronize];
            settings_schedule_live_apply_for_key(kSettingsNSBarPosition);
            [self reloadSectionOrAll:SectionNSBar];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    settings_present_controller(ac, self);
}

- (NSString *)nicebarSubtitleForSlot:(NSInteger)slot
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger kind = [d integerForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, slot)];
    switch ((NiceBarLiteContentKind)kind) {
        case NiceBarLiteContentCustomText: {
            NSString *text = [d stringForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotTextPrefix, slot)] ?: @"";
            return text.length ? text : @"Text";
        }
        case NiceBarLiteContentSystem: {
            NSInteger item = [d integerForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotSystemPrefix, slot)];
            if (item == NiceBarLiteSystemThermalState) {
                NSString *language = [d stringForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotSystemLanguagePrefix, slot)] ?: @"en";
                return [NSString stringWithFormat:@"%@ · %@",
                        settings_nicebar_system_name(item),
                        CyanideNiceBarSystemLanguageName(language)];
            }
            return settings_nicebar_system_name(item);
        }
        case NiceBarLiteContentTimeFormat: {
            NSString *format = [d stringForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotTimePrefix, slot)] ?: @"HH:mm";
            return CyanideNiceBarTimeFormatName(format);
        }
        case NiceBarLiteContentWeather: {
            NSString *text = settings_nicebar_weather_text_for_slot(d, slot);
            return text.length ? text : @"Weather --";
        }
        case NiceBarLiteContentOff:
            return @"Hidden";
    }
    return @"Hidden";
}

- (UIButton *)nicebarSlotButton:(NSInteger)slot
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger kind = [d integerForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, slot)];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tag = slot;
    button.layer.cornerRadius = 10;
    button.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    button.layer.borderColor = UIColor.separatorColor.CGColor;
    button.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    button.titleLabel.numberOfLines = 0;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.78;
    button.contentEdgeInsets = UIEdgeInsetsMake(10, 8, 10, 8);
    [button addTarget:self action:@selector(nicebarSlotButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    NSString *title = [NSString stringWithFormat:@"%@\n%@\n%@",
                       settings_nicebar_slot_name(slot),
                       settings_nicebar_kind_name(kind),
                       [self nicebarSubtitleForSlot:slot]];
    [button setTitle:title forState:UIControlStateNormal];
    button.accessibilityLabel = [NSString stringWithFormat:@"%@ %@", settings_nicebar_slot_name(slot), [self nicebarSubtitleForSlot:slot]];
    return button;
}

- (UITableViewCell *)buildNiceBarGridCellInTableView:(UITableView *)tableView
                                           indexPath:(NSIndexPath *)indexPath
{
    (void)indexPath;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"nicebar-grid"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"nicebar-grid"];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    for (UIView *view in [cell.contentView.subviews copy]) [view removeFromSuperview];

    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self nicebarSlotButton:NiceBarLiteSlotTopLeft],
        [self nicebarSlotButton:NiceBarLiteSlotTopRight],
    ]];
    top.axis = UILayoutConstraintAxisHorizontal;
    top.spacing = 10;
    top.distribution = UIStackViewDistributionFillEqually;

    UIStackView *bottom = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self nicebarSlotButton:NiceBarLiteSlotBottomLeft],
        [self nicebarSlotButton:NiceBarLiteSlotBottomCenter],
        [self nicebarSlotButton:NiceBarLiteSlotBottomRight],
    ]];
    bottom.axis = UILayoutConstraintAxisHorizontal;
    bottom.spacing = 10;
    bottom.distribution = UIStackViewDistributionFillEqually;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[top, bottom]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.distribution = UIStackViewDistributionFillEqually;
    [cell.contentView addSubview:stack];

    UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [top.heightAnchor constraintEqualToConstant:84],
        [bottom.heightAnchor constraintEqualToConstant:84],
        [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:m.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
    ]];
    return cell;
}

- (void)presentNiceBarTextEditorForSlot:(NSInteger)slot
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *key = settings_nicebar_key(kSettingsNiceBarLiteSlotTextPrefix, slot);
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ Text", settings_nicebar_slot_name(slot)]
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Cyanide";
        field.text = [d stringForKey:key] ?: @"";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        NSString *value = ac.textFields.firstObject.text ?: @"";
        [d setInteger:NiceBarLiteContentCustomText forKey:settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, slot)];
        [d setObject:value forKey:key];
        [d synchronize];
        settings_schedule_live_apply_for_key(key);
        [self reloadSectionOrAll:SectionNiceBarLite];
    }]];
    settings_present_controller(ac, self);
}

- (void)nicebarSetTimeFormat:(NSString *)format forSlot:(NSInteger)slot
{
    if (slot < 0 || slot >= NiceBarLiteSlotCount) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:NiceBarLiteContentTimeFormat forKey:settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, slot)];
    [d setObject:format.length ? format : @"HH:mm" forKey:settings_nicebar_key(kSettingsNiceBarLiteSlotTimePrefix, slot)];
    [d synchronize];
    settings_schedule_live_apply_for_key(settings_nicebar_key(kSettingsNiceBarLiteSlotTimePrefix, slot));
    [self reloadSectionOrAll:SectionNiceBarLite];
}

- (void)nicebarSetKind:(NSInteger)kind forSlot:(NSInteger)slot
{
    if (slot < 0 || slot >= NiceBarLiteSlotCount) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:kind forKey:settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, slot)];
    [d synchronize];
    settings_schedule_live_apply_for_key(settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, slot));
    [self reloadSectionOrAll:SectionNiceBarLite];
}

- (void)presentNiceBarDateTimePickerForSlot:(NSInteger)slot
{
    if (slot < 0 || slot >= NiceBarLiteSlotCount) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *selectedFormat = [d stringForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotTimePrefix, slot)] ?: @"HH:mm";
    __weak typeof(self) weakSelf = self;
    CyanideNiceBarTimePresetPickerViewController *picker =
        [[CyanideNiceBarTimePresetPickerViewController alloc] initWithSlotTitle:[NSString stringWithFormat:@"%@ Date / Time", settings_nicebar_slot_name(slot)]
                                                                 selectedFormat:selectedFormat
                                                                      selection:^(NSString *format) {
        [weakSelf nicebarSetTimeFormat:format forSlot:slot];
    }];
    if (self.navigationController) {
        [self.navigationController pushViewController:picker animated:YES];
    } else {
        [self presentViewController:[[UINavigationController alloc] initWithRootViewController:picker] animated:YES completion:nil];
    }
}

- (void)refreshNiceBarWeatherForce:(BOOL)force
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (!settings_nicebar_has_weather_slots(d)) return;
    NSString *cached = [d stringForKey:kSettingsNiceBarLiteWeatherCache] ?: @"";
    if (!cached.length || force) {
        settings_nicebar_store_weather_result(d, nil, nil, @"Weather...", NO);
        [self reloadSectionOrAll:SectionNiceBarLite];
    }

    __weak typeof(self) weakSelf = self;
    settings_nicebar_refresh_weather_if_needed(force, ^(BOOL ok, NSString *text) {
        (void)ok;
        (void)text;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf reloadSectionOrAll:SectionNiceBarLite];
        });
    });
}

- (void)nicebarSetWeatherLanguage:(NSString *)language forSlot:(NSInteger)slot
{
    if (slot < 0 || slot >= NiceBarLiteSlotCount) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *resolved = [language isEqualToString:@"zh"] ? @"zh" : @"en";
    [d setInteger:NiceBarLiteContentWeather forKey:settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, slot)];
    [d setObject:resolved forKey:settings_nicebar_key(kSettingsNiceBarLiteSlotWeatherLanguagePrefix, slot)];
    settings_nicebar_update_weather_slot_texts(d);
    [d synchronize];
    settings_schedule_live_apply_for_key(settings_nicebar_key(kSettingsNiceBarLiteSlotWeatherLanguagePrefix, slot));
    [self reloadSectionOrAll:SectionNiceBarLite];
    [self refreshNiceBarWeatherForce:YES];
}

- (void)presentNiceBarWeatherLanguagePickerForSlot:(NSInteger)slot
{
    if (slot < 0 || slot >= NiceBarLiteSlotCount) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ Weather", settings_nicebar_slot_name(slot)]
                                                                   message:@"Choose the weather display language."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"English" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self nicebarSetWeatherLanguage:@"en" forSlot:slot];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"中文" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self nicebarSetWeatherLanguage:@"zh" forSlot:slot];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    settings_present_controller(sheet, self);
}

- (void)presentNiceBarSystemPickerForSlot:(NSInteger)slot
{
    if (slot < 0 || slot >= NiceBarLiteSlotCount) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger selectedItem = [d integerForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotSystemPrefix, slot)];
    NSString *selectedLanguage = [d stringForKey:settings_nicebar_key(kSettingsNiceBarLiteSlotSystemLanguagePrefix, slot)] ?: @"en";
    __weak typeof(self) weakSelf = self;
    CyanideNiceBarSystemItemPickerViewController *picker =
        [[CyanideNiceBarSystemItemPickerViewController alloc] initWithSlotTitle:[NSString stringWithFormat:@"%@ System Item", settings_nicebar_slot_name(slot)]
                                                                   selectedItem:selectedItem
                                                               selectedLanguage:selectedLanguage
                                                                      selection:^(NSInteger item, NSString *language) {
        NSUserDefaults *innerDefaults = NSUserDefaults.standardUserDefaults;
        [innerDefaults setInteger:NiceBarLiteContentSystem forKey:settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, slot)];
        [innerDefaults setInteger:item forKey:settings_nicebar_key(kSettingsNiceBarLiteSlotSystemPrefix, slot)];
        [innerDefaults setObject:language.length ? language : @"en"
                          forKey:settings_nicebar_key(kSettingsNiceBarLiteSlotSystemLanguagePrefix, slot)];
        [innerDefaults synchronize];
        settings_schedule_live_apply_for_key(settings_nicebar_key(kSettingsNiceBarLiteSlotSystemPrefix, slot));
        [weakSelf reloadSectionOrAll:SectionNiceBarLite];
    }];
    if (self.navigationController) {
        [self.navigationController pushViewController:picker animated:YES];
    } else {
        [self presentViewController:[[UINavigationController alloc] initWithRootViewController:picker] animated:YES completion:nil];
    }
}

- (void)presentNiceBarSlotEditor:(NSInteger)slot
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:settings_nicebar_slot_name(slot)
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"Off" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [d setInteger:NiceBarLiteContentOff forKey:settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, slot)];
        [d synchronize];
        settings_schedule_live_apply_for_key(settings_nicebar_key(kSettingsNiceBarLiteSlotKindPrefix, slot));
        [self reloadSectionOrAll:SectionNiceBarLite];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Custom Text" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self presentNiceBarTextEditorForSlot:slot];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"System Item" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self presentNiceBarSystemPickerForSlot:slot];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Date / Time" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self presentNiceBarDateTimePickerForSlot:slot];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Weather" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self presentNiceBarWeatherLanguagePickerForSlot:slot];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    settings_present_controller(ac, self);
}

- (void)nicebarSlotButtonTapped:(UIButton *)sender
{
    NSInteger slot = sender.tag;
    if (slot >= 0 && slot < NiceBarLiteSlotCount) {
        [self presentNiceBarSlotEditor:slot];
    }
}

- (void)selectSnowBoardLiteIOS6Theme
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:kSnowBoardLiteThemeBuiltinIOS6 forKey:kSettingsSnowBoardLiteSelectedThemeID];
    [d synchronize];
    settings_mark_tweak_applied(kSettingsSnowBoardLiteEnabled, NO);
    settings_notify_package_queue_changed_async();
    [self reloadSectionOrAll:SectionSnowBoardLite];
}

- (void)clearSnowBoardLiteTheme
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:@"" forKey:kSettingsSnowBoardLiteSelectedThemeID];
    if ([d boolForKey:kSettingsSnowBoardLiteEnabled]) {
        [d setBool:NO forKey:kSettingsSnowBoardLiteEnabled];
        g_themer_live_stop_requested = 1;
    }
    [d synchronize];
    settings_mark_tweak_applied(kSettingsSnowBoardLiteEnabled, NO);
    settings_notify_package_queue_changed_async();
    [self reloadSectionOrAll:SectionSnowBoardLite];
}

- (void)clearLiveWPVideo
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:@"" forKey:kSettingsLiveWPVideoPath];
    if ([d boolForKey:kSettingsLiveWPEnabled]) {
        [d setBool:NO forKey:kSettingsLiveWPEnabled];
        g_livewp_live_stop_requested = 1;
    }
    [d synchronize];
    settings_schedule_live_apply_for_key(kSettingsLiveWPEnabled);
    [self reloadSectionOrAll:SectionLiveWP];
}

// "Classic" alternate icon is registered in Info.plist with CFBundleIconFiles
// pointing to Cyanide-Classic@{2,3}x.png at the bundle root. Modern is the
// asset-catalog primary, selected by passing nil to setAlternateIconName:.
+ (UIImage *)appIconPreviewForStyle:(NSString *)style
{
    NSString *name = [style isEqualToString:@"classic"] ? @"preview-classic" : @"preview-modern";
    UIImage *raw = [UIImage imageNamed:name];
    if (!raw) return nil;
    // Render with iOS home-screen corner radius (≈22% of side) so the thumb
    // matches what users see on SpringBoard. 52pt fits in the default subtitle
    // cell row height without forcing layout overrides.
    CGFloat side = 52.0;
    CGFloat radius = side * 0.22;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side)
                                                      cornerRadius:radius];
        [p addClip];
        [raw drawInRect:CGRectMake(0, 0, side, side)];
    }];
}

- (NSString *)currentAppIconStyle
{
    NSString *alt = [UIApplication sharedApplication].alternateIconName;
    return [alt isEqualToString:@"Classic"] ? @"classic" : @"modern";
}

- (UITableViewCell *)buildAppIconCellAtRow:(NSInteger)row tableView:(UITableView *)tableView
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"appicon"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"appicon"];
        cell.detailTextLabel.numberOfLines = 0;
    }
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSString *style = (row == 0) ? @"modern" : @"classic";
    cell.imageView.image = [SettingsViewController appIconPreviewForStyle:style];

    if (row == 0) {
        cell.textLabel.text = @"Modern";
        cell.detailTextLabel.text = @"Default — refreshed v2 mark.";
    } else {
        cell.textLabel.text = @"Classic";
        cell.detailTextLabel.text = @"Original release artwork.";
    }

    BOOL selected = [[self currentAppIconStyle] isEqualToString:style];
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)selectAppIconAtRow:(NSInteger)row inTableView:(UITableView *)tableView
{
    NSString *style = (row == 0) ? @"modern" : @"classic";
    if ([[self currentAppIconStyle] isEqualToString:style]) return;

    if (![UIApplication sharedApplication].supportsAlternateIcons) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"Can't Change Icon"
                             message:@"This iOS build doesn't expose alternate icon switching."
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    NSString *altName = [style isEqualToString:@"classic"] ? @"Classic" : nil;
    [[UIApplication sharedApplication] setAlternateIconName:altName completionHandler:^(NSError * _Nullable error) {
        if (error) {
            printf("[SETTINGS] app icon switch to '%s' failed: %s\n",
                   style.UTF8String,
                   error.localizedDescription.UTF8String);
        } else {
            printf("[SETTINGS] app icon switched to %s\n", style.UTF8String);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSIndexSet *idx = [NSIndexSet indexSetWithIndex:RootSectionAbout];
            [tableView reloadSections:idx withRowAnimation:UITableViewRowAnimationNone];
        });
    }];
}

- (void)showAppIconPicker
{
    if (![UIApplication sharedApplication].supportsAlternateIcons) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"Can't Change Icon"
                             message:@"This iOS build doesn't expose alternate icon switching."
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }
    NSString *current = [self currentAppIconStyle];
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"App Icon"
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *modernTitle = [current isEqualToString:@"modern"] ? @"Modern ✓" : @"Modern";
    NSString *classicTitle = [current isEqualToString:@"classic"] ? @"Classic ✓" : @"Classic";
    [ac addAction:[UIAlertAction actionWithTitle:modernTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self selectAppIconAtRow:0 inTableView:self.tableView];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:classicTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self selectAppIconAtRow:1 inTableView:self.tableView];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 0, 0);
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Links

- (void)openTwitter
{
    NSURL *url = [NSURL URLWithString:@"https://twitter.com/_kolbicz"];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)openViewLog
{
    NSString *logPath = log_most_recent_session_path();
    NSString *text;
    if (!logPath) {
        text = @"No log yet. Run a chain at least once.";
    } else {
        NSError *err = nil;
        text = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:&err];
        if (!text) text = [NSString stringWithFormat:@"Failed to read log: %@", err.localizedDescription];
    }

    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = @"Log";
    vc.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UITextView *tv = [[UITextView alloc] init];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    tv.textColor = UIColor.labelColor;
    tv.backgroundColor = UIColor.systemGroupedBackgroundColor;
    tv.text = text;
    [vc.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor      constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor],
        [tv.bottomAnchor   constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor],
        [tv.leadingAnchor  constraintEqualToAnchor:vc.view.leadingAnchor constant:16.0],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-16.0],
    ]];

    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openShareLog
{
    NSString *logPath = log_most_recent_session_path();
    if (!logPath.length) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"No Log Yet"
                                                                     message:@"Run a chain once, then come back to share the latest diagnostic log."
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    NSURL *logURL = [NSURL fileURLWithPath:logPath];
    NSString *appVersion = settings_app_version_string();
    NSString *iosVersion = [UIDevice currentDevice].systemVersion ?: @"unknown";
    struct utsname info; uname(&info);
    NSString *machine = [NSString stringWithUTF8String:info.machine] ?: @"unknown";
    NSString *summary = [NSString stringWithFormat:@"Cyanide diagnostic log\nCyanide %@ · iOS %@ · %@",
                         appVersion, iosVersion, machine];

    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[summary, logURL]
                                                                     applicationActivities:nil];
    UIPopoverPresentationController *popover = vc.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                        CGRectGetMidY(self.view.bounds),
                                        1.0,
                                        1.0);
        popover.permittedArrowDirections = 0;
    }
    [self presentViewController:vc animated:YES completion:nil];
}

// Session-scoped state so uploaded snapshots from one chain run get grouped on
// the server side (same sessionId, monotonically increasing seq). A fresh
// session begins at every settings_run_actions() entry.
static dispatch_source_t g_cyanide_upload_timer = NULL;
static NSString         *g_cyanide_upload_session_id = nil;
static NSMutableSet<NSString *> *g_cyanide_upload_milestones = nil;
static volatile int      g_cyanide_upload_seq = 0;

// kind = "milestone" (important chain transition) or "final"
// (post-completion). Milestones are explicit so uploads line up with exploit,
// RemoteCall, tweak, and live-loop boundaries instead of timer noise.
static void cyanide_upload_log_with_kind_event(NSString *kind, NSString *event) {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kSettingsLogUploadEnabled]) return;
    NSString *path = log_current_session_path() ?: log_most_recent_session_path();
    if (!path) return;
    // Only the last 512 KiB: the end of a session is what matters, and this
    // runs at every milestone.
    static const unsigned long long kUploadMaxBytes = 512 * 1024;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return;
    // The error-returning variants: the old seekToEndOfFile /
    // readDataToEndOfFile throw an Objective-C exception on an I/O error,
    // which nothing here catches -- a log upload must never crash the app.
    unsigned long long size = 0;
    NSError *ioError = nil;
    BOOL clipped = NO;
    NSData *tail = nil;
    if ([fh seekToEndReturningOffset:&size error:&ioError]) {
        clipped = size > kUploadMaxBytes;
        if ([fh seekToOffset:clipped ? size - kUploadMaxBytes : 0 error:&ioError])
            tail = [fh readDataToEndOfFileAndReturnError:&ioError];
    }
    [fh closeAndReturnError:nil];
    if (!tail) {
        printf("[UPLOAD] log read failed (%s); skipping this upload\n",
               ioError.localizedDescription.UTF8String ?: "unknown");
        return;
    }
    // A cut through a multi-byte character: skip ahead to a valid start.
    NSString *rawLog = nil;
    for (NSUInteger skip = 0; skip < 4 && skip < tail.length && !rawLog; skip++)
        rawLog = [[NSString alloc] initWithData:[tail subdataWithRange:NSMakeRange(skip, tail.length - skip)]
                                       encoding:NSUTF8StringEncoding];
    if (!rawLog.length) return;
    if (clipped) rawLog = [@"[… earlier part of the log omitted …]\n" stringByAppendingString:rawLog];
    // Privacy: [FILES] lines name what the user browsed (including as root).
    // Only the fact of a file operation matters for diagnosis, so paths in
    // those lines are replaced before the log leaves the device. The local
    // log keeps them.
    {
        static NSRegularExpression *pathRe;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            pathRe = [NSRegularExpression regularExpressionWithPattern:@"/[^\\s]*" options:0 error:nil];
        });
        NSMutableArray<NSString *> *lines = [[rawLog componentsSeparatedByString:@"\n"] mutableCopy];
        for (NSUInteger i = 0; i < lines.count; i++) {
            NSString *line = lines[i];
            if (![line containsString:@"[FILES]"]) continue;
            lines[i] = [pathRe stringByReplacingMatchesInString:line options:0
                                                          range:NSMakeRange(0, line.length)
                                                   withTemplate:@"<path>"];
        }
        rawLog = [lines componentsJoinedByString:@"\n"];
    }

    int seq = __sync_add_and_fetch(&g_cyanide_upload_seq, 1);
    NSString *sessionId = g_cyanide_upload_session_id ?: @"adhoc";

    NSString *appVersion = settings_app_version_string();
    NSString *appBuild = settings_app_build_string();
    NSString *iosVersion = [UIDevice currentDevice].systemVersion;

    struct utsname sysInfo;
    uname(&sysInfo);
    NSString *machine = [NSString stringWithUTF8String:sysInfo.machine];

    // Prepend a diagnostic header so each uploaded log is self-contained.
    NSString *header = [NSString stringWithFormat:
        @"=== Cyanide Diagnostic Log ===\n"
        @"app_version : %@\n"
        @"app_build   : %@\n"
        @"ios_version : %@\n"
        @"device      : %@\n"
        @"log_file    : %@\n"
        @"session_id  : %@\n"
        @"kind        : %@\n"
        @"event       : %@\n"
        @"seq         : %d\n"
        @"==============================\n\n",
        appVersion, appBuild, iosVersion, machine, path.lastPathComponent,
        sessionId, kind, event ?: @"", seq];

    NSDictionary *body = @{
        @"log": [header stringByAppendingString:rawLog],
        @"meta": @{
            @"build":      [NSString stringWithFormat:@"cyanide-%@-%@", appVersion, appBuild],
            @"appVersion": appVersion,
            @"appBuild":   appBuild,
            @"source":     @"cyanide",
            @"ios":        iosVersion,
            @"device":     machine,
            @"sessionId":  sessionId,
            @"kind":       kind,
            @"event":      event ?: @"",
            @"seq":        @(seq),
        }
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!data) return;
    NSURL *url = [NSURL URLWithString:@"https://brokenblade-weblogs.hackerboii.workers.dev/log"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = data;
    printf("[LOG] uploading diagnostic (%s%s%s seq=%d, %zu bytes)...\n",
           kind.UTF8String,
           event.length ? ":" : "",
           event.length ? event.UTF8String : "",
           seq,
           (size_t)data.length);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e) {
            printf("[LOG] upload %s%s%s failed: %s\n",
                   kind.UTF8String,
                   event.length ? ":" : "",
                   event.length ? event.UTF8String : "",
                   e.localizedDescription.UTF8String);
        } else {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)r;
            BOOL httpOK = [http isKindOfClass:NSHTTPURLResponse.class] && http.statusCode / 100 == 2;
            printf("[LOG] upload %s%s%s %s: HTTP %ld\n",
                   kind.UTF8String,
                   event.length ? ":" : "",
                   event.length ? event.UTF8String : "",
                   httpOK ? "ok" : "rejected",
                   (long)http.statusCode);
        }
    }] resume];
}

static void cyanide_upload_log_with_kind(NSString *kind) {
    cyanide_upload_log_with_kind_event(kind, nil);
}

static void cyanide_upload_log_milestone(NSString *event) {
    if (!event.length) return;

    @synchronized ([NSUserDefaults standardUserDefaults]) {
        if (!g_cyanide_upload_milestones)
            g_cyanide_upload_milestones = [NSMutableSet set];
        if ([g_cyanide_upload_milestones containsObject:event])
            return;
        [g_cyanide_upload_milestones addObject:event];
    }

    cyanide_upload_log_with_kind_event(@"milestone", event);
}

static void cyanide_upload_log_if_enabled(void) {
    cyanide_upload_log_with_kind(@"final");
}

// Begin a diagnostic upload session. Uploads are milestone-driven; this no
// longer starts the old 3s/8s periodic checkpoint timer.
static void cyanide_start_session_uploads(void) {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kSettingsLogUploadEnabled]) return;
    if (g_cyanide_upload_timer) return;

    g_cyanide_upload_session_id = [[NSUUID UUID] UUIDString];
    @synchronized ([NSUserDefaults standardUserDefaults]) {
        g_cyanide_upload_milestones = [NSMutableSet set];
    }
    g_cyanide_upload_seq = 0;
}

static void cyanide_stop_session_uploads(void) {
    if (g_cyanide_upload_timer) {
        dispatch_source_cancel(g_cyanide_upload_timer);
        g_cyanide_upload_timer = NULL;
    }
}

// Contact owner (zeroxjf) with the diagnostic log inline in the body. Build
// info sits between the user's typing area at the top and the log dump
// below, so the user just types above the signature and hits send.
- (void)openContactEmail
{
    cyanide_present_contact(self);
}

// Public entry point for the Contact flow. Builds the email body (signature
// + inline diagnostic log) and presents MFMailComposeViewController from
// `host` when Mail is set up, else opens a mailto: URL with a truncated log
// tail so third-party mail apps still get useful context.
void cyanide_present_contact(UIViewController *host)
{
    if (!host) return;

    NSString *appVersion = settings_app_version_string();
    NSString *iosVersion = [UIDevice currentDevice].systemVersion ?: @"unknown";
    struct utsname info; uname(&info);
    NSString *machine = [NSString stringWithUTF8String:info.machine];

    // Single-line signature so it reads correctly even in mail clients that
    // collapse newlines from mailto: bodies (Gmail-iOS being the worst offender).
    NSString *signature = [NSString stringWithFormat:@"—— Cyanide %@ · iOS %@ · %@ ——",
                           appVersion, iosVersion, machine];

    NSString *subject = [NSString stringWithFormat:@"Cyanide %@ — Contact", appVersion];

    // CRLF rather than LF so iOS Mail, Gmail, Outlook, and the mailto: URL
    // path all preserve line breaks. Plain LF is fine in MFMailCompose but
    // some third-party clients eat them when the body arrives via mailto:.
    // Log inclusion is intentionally omitted for now — pipeline was unreliable
    // (in-app buffer snapshot wasn't landing in the email). Build/device info
    // still ships in the signature so I can at least see the user's setup.
    NSMutableString *body = [NSMutableString string];
    [body appendString:@"\r\n\r\n\r\n"]; // breathing room at top for the user to type
    [body appendString:signature];
    [body appendString:@"\r\n"];

    if ([MFMailComposeViewController canSendMail]) {
        MFMailComposeViewController *vc = [[MFMailComposeViewController alloc] init];
        vc.mailComposeDelegate = _cyanide_mail_delegate();
        [vc setToRecipients:@[@"zeroxjf@gmail.com"]];
        [vc setSubject:subject];
        [vc setMessageBody:body isHTML:NO];
        [host presentViewController:vc animated:YES completion:nil];
        return;
    }

    // Mail not configured — fall back to mailto:. Bodies get URL-encoded so
    // long logs produce long URLs; in practice iOS LaunchServices accepts
    // ~64KB and third-party mail apps still receive the full body. We send
    // the full log regardless and trust the client to handle it.
    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    NSString *q = [NSString stringWithFormat:@"subject=%@&body=%@",
        [subject stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"",
        [body stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @""];
    NSURL *url = [NSURL URLWithString:[@"mailto:zeroxjf@gmail.com?" stringByAppendingString:q]];
    if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return;
    }

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Mail Not Available"
                         message:@"Set up Mail in iOS Settings to send feedback, or DM @_kolbicz on Twitter. View Log in Settings to copy the latest diagnostic log."
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:ac animated:YES completion:nil];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // The keypad preview is drawn to a fixed height; every other row keeps the
    // automatic dimension the rest of the table uses. Matched by index so row
    // sizing never has to build the rows array.
    if (self.detailMode && self.underlyingSection == SectionPasscodeTheme &&
        indexPath.row == kPasscodePreviewRow) {
        return 280.0;
    }
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Preserve the table view's actual indexPath for dequeue calls (which
    // expect a path that exists in the current data source). `indexPath`
    // is remapped to the underlying SettingsSection for content lookup.
    NSIndexPath *dequeuePath = indexPath;

    if (!self.detailMode) {
        switch ((RootSection)indexPath.section) {
            case RootSectionWarning:
                indexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:SectionWarning];
                break;
            case RootSectionChangelog: {
                if (!self.changelogExpanded) {
                    return [self buildChangelogCollapsedCellInTableView:tableView];
                }
                NSInteger entryCount = (NSInteger)settings_changelog_entries().count;
                if (indexPath.row == entryCount) {
                    return [self buildChangelogFooterCellInTableView:tableView];
                }
                if (indexPath.row > entryCount) {
                    return [self buildChangelogCollapseCellInTableView:tableView];
                }
                return [self buildChangelogCellAtRow:indexPath.row tableView:tableView];
            }
            case RootSectionActions:
                indexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:SectionActions];
                break;
            case RootSectionTweakBundles:
                return [self buildBundleCellWithRow:self.tweakBundleRows[indexPath.row] tableView:tableView];
            case RootSectionInDev:
                return [self buildInDevCellWithRow:self.inDevBundleRows[indexPath.row] tableView:tableView];
            case RootSectionSystemBundles:
                return [self buildBundleCellWithRow:self.systemBundleRows[indexPath.row] tableView:tableView];
            case RootSectionAbout:
                return [self buildAboutCellAtRow:indexPath.row tableView:tableView];
            case RootSectionCount:
                return [[UITableViewCell alloc] init];
        }
    } else {
        indexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:self.underlyingSection];
    }

    if (indexPath.section == SectionWarning) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"warning" forIndexPath:dequeuePath];
        return [self buildWarningCell:cell];
    }
    if (indexPath.section == SectionActions) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"action-compact"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"action-compact"];
            cell.detailTextLabel.numberOfLines = 1;
        }
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.detailTextLabel.text = nil;

        BOOL supported = settings_device_supported();
        BOOL cleanupEnabled = supported && (g_kexploit_done ||
                                            g_springboard_rc_ready ||
                                            remote_call_has_local_state());
        BOOL anyInstalledOrQueued = NO;
        for (Package *p in [PackageCatalog allPackages]) {
            if (p.isInstalled || p.isQueuedForApply) { anyInstalledOrQueued = YES; break; }
        }
        if (!anyInstalledOrQueued) {
            anyInstalledOrQueued = [[PackageQueue sharedQueue] pendingCount] > 0;
        }

        BOOL rowEnabled = supported;
        NSString *symbol = nil;
        UIColor *color = nil;

        if (indexPath.row == 0) {
            rowEnabled = cleanupEnabled;
            BOOL running = g_settings_cleanup_running;
            symbol = @"xmark.circle.fill";
            color  = UIColor.systemRedColor;
            cell.textLabel.text = running ? @"Cleaning Up…" : @"Clean Up";
            cell.detailTextLabel.text = cleanupEnabled ? nil : @"No active session";
            if (running) {
                UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                spin.color = color;
                [spin startAnimating];
                cell.accessoryView = spin;
            }
        } else if (indexPath.row == 1) {
            BOOL running = g_settings_respring_cleanup_running;
            symbol = @"arrow.clockwise.circle.fill";
            color  = UIColor.systemOrangeColor;
            cell.textLabel.text = running ? @"Preparing…" : @"Respring";
            if (running) {
                UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                spin.color = color;
                [spin startAnimating];
                cell.accessoryView = spin;
            }
        } else if (indexPath.row == 2) {
            rowEnabled = anyInstalledOrQueued;
            symbol = @"trash.fill";
            color  = UIColor.systemRedColor;
            cell.textLabel.text = @"Reset All Packages";
            cell.detailTextLabel.text = anyInstalledOrQueued ? nil : @"Nothing active";
        } else {
            rowEnabled = YES;
            symbol = @"arrow.down.circle.fill";
            color  = UIColor.systemBlueColor;
            cell.textLabel.text = @"Check for Updates";
        }

        UIColor *effectiveColor = rowEnabled ? color : UIColor.tertiaryLabelColor;
        cell.imageView.image = [SettingsViewController iconBadgeWithSymbol:symbol color:effectiveColor size:29.0];
        cell.textLabel.font = [UIFont systemFontOfSize:17.0];
        cell.textLabel.textColor = rowEnabled ? UIColor.labelColor : UIColor.tertiaryLabelColor;
        cell.detailTextLabel.textColor = UIColor.tertiaryLabelColor;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0];
        cell.selectionStyle = rowEnabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = rowEnabled;
        return cell;
    }

    NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
    NSString *kind = row[@"kind"] ?: @"toggle";
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL supported = settings_device_supported();

    if ([kind isEqualToString:@"nicebar-grid"]) {
        return [self buildNiceBarGridCellInTableView:tableView indexPath:dequeuePath];
    }

    if ([kind isEqualToString:@"passcode-preview"]) {
        return [self buildPasscodePreviewCellInTableView:tableView];
    }

    if ([kind isEqualToString:@"info"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"info"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"info"];
            cell.detailTextLabel.numberOfLines = 0;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = NO;
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.textLabel.text = row[@"title"];
        cell.textLabel.textColor = UIColor.labelColor;
        cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        cell.detailTextLabel.text = row[@"subtitle"];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0];
        return cell;
    }

    if ([kind isEqualToString:@"button"]) {
        BOOL rowSupported = supported ||
                            indexPath.section == SectionOTA ||
                            indexPath.section == SectionThemer;
        NSString *action = row[@"action"];
        if (indexPath.section == SectionNanoRegistry &&
            [action isEqualToString:@"nano-load"]) {
            rowSupported = settings_nano_load_override_enabled();
        }
        // Read-only queries need a KRW session but must never start one --
        // see settings_ensure_kexploit_for_read(). Grey them out until the
        // chain has run (or a parked session is recoverable) so the button
        // reads as unavailable instead of silently doing nothing.
        if (rowSupported && [row[@"requiresKRW"] boolValue]) {
            rowSupported = settings_krw_available_without_exploit();
        }
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"button" forIndexPath:dequeuePath];
        cell.selectionStyle = rowSupported ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = rowSupported;
        cell.accessoryView = nil;
        cell.textLabel.text = row[@"title"];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;

        BOOL prominent = [row[@"style"] isEqualToString:@"prominent"];
        BOOL filled = prominent && rowSupported;
        if (filled) {
            cell.textLabel.textColor = UIColor.whiteColor;
            cell.textLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        } else {
            cell.textLabel.textColor = rowSupported
                ? ([row[@"destructive"] boolValue] ? UIColor.systemRedColor
                                                   : settings_cell_tint_color(self.view))
                : UIColor.tertiaryLabelColor;
            cell.textLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightRegular];
        }
        // Build a fresh configuration every time. Editing the cell's current one
        // instead let the fill from a previous use of the same reused cell
        // survive, which tinted unrelated rows (the destructive buttons after a
        // filled Apply row).
        UIBackgroundConfiguration *buttonBackground =
            [UIBackgroundConfiguration listGroupedCellConfiguration];
        if (filled) {
            buttonBackground.backgroundColor = settings_cell_tint_color(self.view);
        }
        cell.backgroundConfiguration = buttonBackground;

        // Long-press on Import Backups offers to erase the stored originals: it is
        // the one action in this panel with no undo, so it stays off the row's tap
        // action. Reused cells keep their old recognisers, so drop those first.
        for (UIGestureRecognizer *recognizer in [cell.gestureRecognizers copy]) {
            if ([recognizer isKindOfClass:UILongPressGestureRecognizer.class]) {
                [cell removeGestureRecognizer:recognizer];
            }
        }
        if ([row[@"action"] isEqualToString:@"passcode-import-backups"]) {
            UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc]
                initWithTarget:self action:@selector(handlePasscodeBackupRowLongPress:)];
            hold.minimumPressDuration = 0.8;
            [cell addGestureRecognizer:hold];
        }
        return cell;
    }

    if ([kind isEqualToString:@"stepper"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"stepper" forIndexPath:dequeuePath];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.textAlignment = NSTextAlignmentNatural;
        // Honor the same @"disabled" row flag the toggle cells use (e.g. the
        // auto-retry cap is greyed out while its master toggle is off).
        BOOL stepperEnabled = supported && ![row[@"disabled"] boolValue];
        cell.textLabel.textColor = stepperEnabled ? UIColor.labelColor : UIColor.tertiaryLabelColor;
        NSInteger value = [d integerForKey:row[@"key"]];
        NSString *combined = [NSString stringWithFormat:@"%@: %ld", row[@"title"], (long)value];
        NSString *subtitle = row[@"subtitle"];
        if (subtitle.length > 0) {
            UIListContentConfiguration *config = [UIListContentConfiguration cellConfiguration];
            config.text = combined;
            config.secondaryText = subtitle;
            config.textToSecondaryTextVerticalPadding = 3;
            config.textProperties.color = stepperEnabled ? UIColor.labelColor : UIColor.tertiaryLabelColor;
            config.secondaryTextProperties.color = stepperEnabled ? UIColor.secondaryLabelColor : UIColor.tertiaryLabelColor;
            config.secondaryTextProperties.font = [UIFont systemFontOfSize:12];
            config.secondaryTextProperties.numberOfLines = 0;
            cell.contentConfiguration = config;
        } else {
            cell.contentConfiguration = nil;
            cell.textLabel.text = combined;
        }
        UIStepper *stp = [[UIStepper alloc] init];
        stp.minimumValue = [row[@"min"] doubleValue];
        stp.maximumValue = [row[@"max"] doubleValue];
        stp.stepValue = 1;
        stp.value = (double)value;
        stp.enabled = stepperEnabled;
        stp.tag = (indexPath.section << 16) | indexPath.row;
        [stp addTarget:self action:@selector(stepperChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = stp;
        return cell;
    }

    if ([kind isEqualToString:@"number"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"number"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"number"];
            cell.detailTextLabel.numberOfLines = 0;
        }
        cell.selectionStyle = supported ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = supported;
        cell.accessoryType = supported ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.accessoryView = nil;
        cell.contentConfiguration = nil;

        double value = settings_number_row_current_value(row, d);
        NSString *valueText = settings_number_row_value_string(row, value, YES);
        cell.textLabel.text = [NSString stringWithFormat:@"%@: %@", row[@"title"], valueText];
        cell.textLabel.textAlignment = NSTextAlignmentNatural;
        cell.textLabel.textColor = supported ? UIColor.labelColor : UIColor.tertiaryLabelColor;
        cell.detailTextLabel.text = row[@"subtitle"] ?: @"Tap to enter an exact value.";
        cell.detailTextLabel.textColor = supported ? UIColor.secondaryLabelColor : UIColor.tertiaryLabelColor;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        return cell;
    }

    if ([kind isEqualToString:@"text"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"settings-text"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                         reuseIdentifier:@"settings-text"];
            cell.detailTextLabel.numberOfLines = 0;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = supported;
        cell.contentConfiguration = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.textLabel.text = row[@"title"];
        cell.textLabel.textColor = supported ? UIColor.labelColor : UIColor.tertiaryLabelColor;
        cell.detailTextLabel.text = row[@"subtitle"];
        cell.detailTextLabel.textColor = supported ? UIColor.secondaryLabelColor : UIColor.tertiaryLabelColor;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];

        NSString *key = row[@"key"];
        NSString *value = [d stringForKey:key];
        if (value.length == 0) value = row[@"placeholder"] ?: @"";

        UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 215, 36)];
        field.text = value;
        field.placeholder = row[@"placeholder"];
        field.enabled = supported;
        field.font = [UIFont systemFontOfSize:13];
        field.textAlignment = NSTextAlignmentRight;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.spellCheckingType = UITextSpellCheckingTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.returnKeyType = UIReturnKeyDone;
        field.borderStyle = UITextBorderStyleRoundedRect;
        objc_setAssociatedObject(field, "cyanideSettingsTextKey", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(field, "cyanideSettingsTextDefault", row[@"placeholder"] ?: @"",
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [field addTarget:self
                  action:@selector(settingsTextFieldEditingEnded:)
        forControlEvents:UIControlEventEditingDidEnd | UIControlEventEditingDidEndOnExit];
        cell.accessoryView = field;
        return cell;
    }

    if ([kind isEqualToString:@"slider"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"slider" forIndexPath:dequeuePath];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = nil;
        cell.detailTextLabel.text = nil;
        cell.accessoryView = nil;
        for (UIView *v in [cell.contentView.subviews copy]) [v removeFromSuperview];

        NSInteger minV = [row[@"min"] integerValue];
        NSInteger maxV = [row[@"max"] integerValue];
        NSInteger step = [row[@"step"] integerValue]; if (step <= 0) step = 1;
        NSInteger value = [d integerForKey:row[@"key"]];
        if (value < minV) value = minV;
        if (value > maxV) value = maxV;
        NSString *unit = row[@"unit"] ?: @"";

        UILabel *title = [[UILabel alloc] init];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        title.text = row[@"title"];
        title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        title.textColor = supported ? UIColor.labelColor : UIColor.tertiaryLabelColor;

        UILabel *valueLabel = [[UILabel alloc] init];
        valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        valueLabel.text = [NSString stringWithFormat:@"%ld%@", (long)value, unit];
        valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        valueLabel.textColor = supported ? UIColor.secondaryLabelColor : UIColor.tertiaryLabelColor;
        valueLabel.textAlignment = NSTextAlignmentRight;

        UISlider *slider = [[UISlider alloc] init];
        slider.translatesAutoresizingMaskIntoConstraints = NO;
        slider.minimumValue = (float)minV;
        slider.maximumValue = (float)maxV;
        slider.value = (float)value;
        slider.continuous = YES;
        slider.enabled = supported;
        slider.tag = (indexPath.section << 16) | indexPath.row;
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [slider addTarget:self action:@selector(sliderEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        // Stash the value label so sliderChanged: can update it without a full reload.
        objc_setAssociatedObject(slider, "cyanideValueLabel", valueLabel, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(slider, "cyanideUnit", unit, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(slider, "cyanideStep", @(step), OBJC_ASSOCIATION_RETAIN);

        [cell.contentView addSubview:title];
        [cell.contentView addSubview:valueLabel];
        [cell.contentView addSubview:slider];

        UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [title.leadingAnchor      constraintEqualToAnchor:m.leadingAnchor],
            [title.topAnchor          constraintEqualToAnchor:m.topAnchor],
            [valueLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [valueLabel.centerYAnchor  constraintEqualToAnchor:title.centerYAnchor],
            [valueLabel.leadingAnchor  constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:8],
            [slider.leadingAnchor   constraintEqualToAnchor:m.leadingAnchor],
            [slider.trailingAnchor  constraintEqualToAnchor:m.trailingAnchor],
            [slider.topAnchor       constraintEqualToAnchor:title.bottomAnchor constant:4],
            [slider.bottomAnchor    constraintEqualToAnchor:m.bottomAnchor],
        ]];
        return cell;
    }

    if ([kind isEqualToString:@"a18path"]) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                       reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UILabel *title = [UILabel new];
        title.text = row[@"title"];
        title.font = [UIFont systemFontOfSize:17.0];
        title.translatesAutoresizingMaskIntoConstraints = NO;

        UISegmentedControl *seg =
            [[UISegmentedControl alloc] initWithItems:@[@"pe_v1 (default)", @"pe_v2", @"pe_v3"]];
        seg.translatesAutoresizingMaskIntoConstraints = NO;
        // Display order is pe_v1 first, but the stored value is unchanged
        // (1 = pe_v1, 0 = pe_v2, 2 = pe_v3) so existing preferences keep their meaning.
        NSInteger storedPath = [d integerForKey:kSettingsA18ExploitPath];
        seg.selectedSegmentIndex = (storedPath == 1) ? 0 : (storedPath == 2) ? 2 : 1;
        seg.enabled = settings_device_is_a18_above();
        [seg addTarget:self action:@selector(a18PathSegChanged:)
      forControlEvents:UIControlEventValueChanged];

        UILabel *note = [UILabel new];
        note.numberOfLines = 0;
        note.font = [UIFont systemFontOfSize:12.0];
        note.textColor = UIColor.secondaryLabelColor;
        note.text = settings_device_is_a18_above()
            ? @"A18/M4 only. pe_v1 is the default (~50% per attempt; parked state makes it a "
               "one-time cost per boot). pe_v2 stages 2 GB as 131,072 separate IOSurfaces, but iOS "
               "caps a process at 16,384 — so most fail and it has not acquired reliably in "
               "testing. pe_v3 uses pe_v2's staging but hunts only one mapping, retries on "
               "already-proven pages instead of re-hunting, and stops early instead of reading "
               "memory likely to panic the device (~50% per attempt in testing) — so it probably "
               "causes fewer reboots."
            : @"A18/M4 devices only. This device uses pe_v1 already.";
        note.translatesAutoresizingMaskIntoConstraints = NO;

        [cell.contentView addSubview:title];
        [cell.contentView addSubview:seg];
        [cell.contentView addSubview:note];
        UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [title.leadingAnchor  constraintEqualToAnchor:m.leadingAnchor],
            [title.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [title.topAnchor      constraintEqualToAnchor:m.topAnchor],
            [seg.leadingAnchor    constraintEqualToAnchor:m.leadingAnchor],
            [seg.trailingAnchor   constraintEqualToAnchor:m.trailingAnchor],
            [seg.topAnchor        constraintEqualToAnchor:title.bottomAnchor constant:8],
            [note.leadingAnchor   constraintEqualToAnchor:m.leadingAnchor],
            [note.trailingAnchor  constraintEqualToAnchor:m.trailingAnchor],
            [note.topAnchor       constraintEqualToAnchor:seg.bottomAnchor constant:8],
            [note.bottomAnchor    constraintEqualToAnchor:m.bottomAnchor],
        ]];
        return cell;
    }

    if ([kind isEqualToString:@"a18shape"]) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                       reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UILabel *title = [UILabel new];
        title.text = row[@"title"];
        title.font = [UIFont systemFontOfSize:17.0];
        title.translatesAutoresizingMaskIntoConstraints = NO;

        UISegmentedControl *seg =
            [[UISegmentedControl alloc] initWithItems:@[@"Off", @"Dynamic", @"3 GB"]];
        seg.translatesAutoresizingMaskIntoConstraints = NO;
        seg.selectedSegmentIndex = [d integerForKey:kSettingsA18MemoryShaping];
        [seg addTarget:self
                action:@selector(a18ShapeSegChanged:)
      forControlEvents:UIControlEventValueChanged];
        // pe_v1-only: shaping does nothing on the pe_v2 path -- disable + dim.
        BOOL a18shapeEnabled = ([d integerForKey:kSettingsA18ExploitPath] == 1);
        seg.enabled = a18shapeEnabled;
        title.textColor = a18shapeEnabled ? UIColor.labelColor : UIColor.tertiaryLabelColor;

        UILabel *note = [UILabel new];
        note.numberOfLines = 0;
        note.font = [UIFont systemFontOfSize:12.0];
        note.textColor = a18shapeEnabled ? UIColor.secondaryLabelColor : UIColor.tertiaryLabelColor;
        note.text = @"A18/M4 only. Pins physical memory so the page after each search mapping is more "
                     "often ours and valid, lowering the aperture-panic rate. Off uses standard geometry "
                     "(no pin). Dynamic sizes the pin to live jetsam headroom (75%), adapting per device "
                     "to avoid the jetsam kill a fixed size can cause. 3 GB is the fixed 1.5.5 size. "
                     "Effective on the next fresh chain run.";
        note.translatesAutoresizingMaskIntoConstraints = NO;

        [cell.contentView addSubview:title];
        [cell.contentView addSubview:seg];
        [cell.contentView addSubview:note];
        UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [title.leadingAnchor  constraintEqualToAnchor:m.leadingAnchor],
            [title.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [title.topAnchor      constraintEqualToAnchor:m.topAnchor],
            [seg.leadingAnchor    constraintEqualToAnchor:m.leadingAnchor],
            [seg.trailingAnchor   constraintEqualToAnchor:m.trailingAnchor],
            [seg.topAnchor        constraintEqualToAnchor:title.bottomAnchor constant:8],
            [note.leadingAnchor   constraintEqualToAnchor:m.leadingAnchor],
            [note.trailingAnchor  constraintEqualToAnchor:m.trailingAnchor],
            [note.topAnchor       constraintEqualToAnchor:seg.bottomAnchor constant:8],
            [note.bottomAnchor    constraintEqualToAnchor:m.bottomAnchor],
        ]];
        return cell;
    }

    if ([kind isEqualToString:@"settlemode"]) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                       reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UILabel *title = [UILabel new];
        title.text = row[@"title"];
        title.font = [UIFont systemFontOfSize:17.0];
        title.translatesAutoresizingMaskIntoConstraints = NO;

        UISegmentedControl *seg =
            [[UISegmentedControl alloc] initWithItems:@[@"Compatible", @"Fast", @"Fastest"]];
        seg.translatesAutoresizingMaskIntoConstraints = NO;
        seg.selectedSegmentIndex = [d integerForKey:kSettingsRemoteSettleMode];
        [seg addTarget:self
                action:@selector(settleModeSegChanged:)
      forControlEvents:UIControlEventValueChanged];

        UILabel *note = [UILabel new];
        note.numberOfLines = 0;
        note.font = [UIFont systemFontOfSize:12.0];
        note.textColor = UIColor.secondaryLabelColor;
        note.text = @"Cyanide waits after each remote call so SpringBoard can settle. Compatible "
                     "waits 50 ms, Fast 5 ms, Fastest only after calls that leave work running. "
                     "Most of a tweak's apply time is this wait — Double Tap to Lock spends about "
                     "13 waits per Home Screen page. Drop to Fast first; if tweaks still apply "
                     "correctly, try Fastest. Go back to Compatible if anything misbehaves.";
        note.translatesAutoresizingMaskIntoConstraints = NO;

        [cell.contentView addSubview:title];
        [cell.contentView addSubview:seg];
        [cell.contentView addSubview:note];
        UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [title.leadingAnchor  constraintEqualToAnchor:m.leadingAnchor],
            [title.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [title.topAnchor      constraintEqualToAnchor:m.topAnchor],
            [seg.leadingAnchor    constraintEqualToAnchor:m.leadingAnchor],
            [seg.trailingAnchor   constraintEqualToAnchor:m.trailingAnchor],
            [seg.topAnchor        constraintEqualToAnchor:title.bottomAnchor constant:8],
            [note.leadingAnchor   constraintEqualToAnchor:m.leadingAnchor],
            [note.trailingAnchor  constraintEqualToAnchor:m.trailingAnchor],
            [note.topAnchor       constraintEqualToAnchor:seg.bottomAnchor constant:8],
            [note.bottomAnchor    constraintEqualToAnchor:m.bottomAnchor],
        ]];
        return cell;
    }

    if ([kind isEqualToString:@"segmented"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"segmented" forIndexPath:dequeuePath];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = nil;
        for (UIView *v in [cell.contentView.subviews copy]) [v removeFromSuperview];
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:powercuff_levels()];
        seg.translatesAutoresizingMaskIntoConstraints = NO;
        NSString *cur = [d stringForKey:row[@"key"]] ?: @"nominal";
        NSUInteger idx = [powercuff_levels() indexOfObject:cur];
        if (idx == NSNotFound) idx = [powercuff_levels() indexOfObject:@"nominal"];
        seg.selectedSegmentIndex = (NSInteger)idx;
        seg.enabled = supported;
        [seg addTarget:self action:@selector(powercuffSegChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.contentView addSubview:seg];
        [NSLayoutConstraint activateConstraints:@[
            [seg.leadingAnchor  constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [seg.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [seg.topAnchor      constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.topAnchor],
            [seg.bottomAnchor   constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.bottomAnchor],
        ]];
        return cell;
    }

    if ([kind isEqualToString:@"ql-loaded"]) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];
        BOOL active = [row[@"enabled"] boolValue];
        config.image = CYIconBadgeImage(@"doc.text.fill", active ? UIColor.systemGreenColor : UIColor.systemOrangeColor, 36.0);
        config.imageProperties.reservedLayoutSize = CGSizeMake(36.0, 36.0);
        config.imageProperties.maximumSize = CGSizeMake(36.0, 36.0);
        config.imageToTextPadding = 14.0;
        config.text = row[@"title"];
        config.textProperties.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        config.secondaryText = active
            ? [NSString stringWithFormat:@"%@ · Active", row[@"subtitle"]]
            : row[@"subtitle"];
        config.secondaryTextProperties.color = active ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
        config.textToSecondaryTextVerticalPadding = 2.0;
        NSDirectionalEdgeInsets m = config.directionalLayoutMargins;
        m.top = 12.0; m.bottom = 12.0;
        config.directionalLayoutMargins = m;
        cell.contentConfiguration = config;
        return cell;
    }

    if ([kind isEqualToString:@"ql-empty"]) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];
        config.image = CYIconBadgeImage(@"doc.text", UIColor.tertiaryLabelColor, 36.0);
        config.imageProperties.reservedLayoutSize = CGSizeMake(36.0, 36.0);
        config.imageProperties.maximumSize = CGSizeMake(36.0, 36.0);
        config.imageToTextPadding = 14.0;
        config.text = @"No tweak loaded";
        config.textProperties.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightMedium];
        config.textProperties.color = UIColor.tertiaryLabelColor;
        config.secondaryText = repotweaks_sources_enabled() ? @"Select a .js file or install from Sources"
                                                            : @"Select a .js file to run";
        config.secondaryTextProperties.color = UIColor.tertiaryLabelColor;
        config.textToSecondaryTextVerticalPadding = 2.0;
        NSDirectionalEdgeInsets m = config.directionalLayoutMargins;
        m.top = 12.0; m.bottom = 12.0;
        config.directionalLayoutMargins = m;
        cell.contentConfiguration = config;
        return cell;
    }

    if ([kind isEqualToString:@"ql-param"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ql-param"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"ql-param"];
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = row[@"title"];

        NSString *varName = row[@"varName"];
        NSString *pType = row[@"paramType"];
        NSString *currentValue = settings_string_or_empty(self.qlValues[varName]);

        if ([pType isEqualToString:@"switch"]) {
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [currentValue isEqualToString:@"true"];

            UIAction *action = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
                self.qlValues[varName] = sw.isOn ? @"true" : @"false";
                [[NSUserDefaults standardUserDefaults] setObject:self.qlValues forKey:@"QuickLoaderSourceValues"];
                [self applyQuickLoaderScript]; //auto-compiling
            }];
            [sw addAction:action forControlEvents:UIControlEventValueChanged];

            cell.accessoryView = sw;
        }
        else if ([pType isEqualToString:@"text"]) {
            UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 150, 30)];
            tf.textAlignment = NSTextAlignmentRight;
            tf.textColor = UIColor.secondaryLabelColor;
            tf.text = currentValue;

            UIAction *action = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
                self.qlValues[varName] = tf.text;
                [[NSUserDefaults standardUserDefaults] setObject:self.qlValues forKey:@"QuickLoaderSourceValues"];
                [self applyQuickLoaderScript]; //auto-compiling
            }];
            [tf addAction:action forControlEvents:UIControlEventEditingChanged];

            cell.accessoryView = tf;
        }
        else if ([pType isEqualToString:@"color"]) {
            // making sure AccessoryView is empty to avoid conflicts
            cell.accessoryView = nil;

            UIColorWell *colorWell = [[UIColorWell alloc] init];
            colorWell.translatesAutoresizingMaskIntoConstraints = NO;
            colorWell.title = row[@"title"];

            // if currentValue is null use red
            colorWell.selectedColor = colorFromHexString(currentValue ?: @"#FF0000");

            UIAction *action = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
                self.qlValues[varName] = hexStringFromColor(colorWell.selectedColor);
                [[NSUserDefaults standardUserDefaults] setObject:self.qlValues forKey:@"QuickLoaderSourceValues"];
                [self applyQuickLoaderScript]; //auto-compiling
            }];
            [colorWell addAction:action forControlEvents:UIControlEventValueChanged];

            //bypass accessoryView (color)
            [cell.contentView addSubview:colorWell];

            //force 32x32 and right formatting
            [NSLayoutConstraint activateConstraints:@[
                [colorWell.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
                [colorWell.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [colorWell.widthAnchor constraintEqualToConstant:32.0],
                [colorWell.heightAnchor constraintEqualToConstant:32.0]
            ]];
        }

        else if ([pType isEqualToString:@"slider"]) {
            //spacing for default text
            UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, 220, 30)];
            stack.axis = UILayoutConstraintAxisHorizontal;
            stack.spacing = 10;
            stack.alignment = UIStackViewAlignmentCenter;

            UISlider *slider = [[UISlider alloc] init];
            slider.minimumValue = row[@"min"] ? [row[@"min"] floatValue] : 0.0;
            slider.maximumValue = row[@"max"] ? [row[@"max"] floatValue] : 1.0;

            //if new use .js default settings
            float defVal = row[@"default"] ? [row[@"default"] floatValue] : slider.minimumValue;
            slider.value = currentValue ? [currentValue floatValue] : defVal;

            UILabel *valLabel = [[UILabel alloc] init];
            valLabel.textColor = [UIColor secondaryLabelColor];
            valLabel.font = [UIFont systemFontOfSize:14];
            [valLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

            //real-time text formatting
            void (^updateLabelText)(float) = ^(float value) {
                if (fabs(value - defVal) < 0.01) {
                    valLabel.text = [NSString stringWithFormat:@"%.2f (Def)", value];
                } else {
                    valLabel.text = [NSString stringWithFormat:@"%.2f", value];
                }
            };

            //initialize cell text
            updateLabelText(slider.value);

            [stack addArrangedSubview:slider];
            [stack addArrangedSubview:valLabel];

            //refresh text (when sliding)
            UIAction *updateTextAction = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
                updateLabelText(slider.value);
            }];
            [slider addAction:updateTextAction forControlEvents:UIControlEventValueChanged];

            //save and compile (after sliding)
            UIAction *saveAction = [UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
                self.qlValues[varName] = [NSString stringWithFormat:@"%.2f", slider.value];
                [[NSUserDefaults standardUserDefaults] setObject:self.qlValues forKey:@"QuickLoaderSourceValues"];
                [self applyQuickLoaderScript];
            }];
            [slider addAction:saveAction forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

            cell.accessoryView = stack;
        }

        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"toggle" forIndexPath:dequeuePath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    BOOL rowEnabled = supported && ![row[@"disabled"] boolValue];
    // pe_v1-only options (interleave/bounded) are inert on the pe_v2 path -- grey
    // them out so a control never looks live when it does nothing.
    if ([row[@"peV1Only"] boolValue] &&
        [d integerForKey:kSettingsA18ExploitPath] != 1)
        rowEnabled = NO;
    cell.userInteractionEnabled = rowEnabled;
    NSString *subtitle = row[@"subtitle"];
    if (subtitle.length > 0) {
        UIListContentConfiguration *config = [UIListContentConfiguration cellConfiguration];
        config.text = row[@"title"];
        config.secondaryText = subtitle;
        config.textToSecondaryTextVerticalPadding = 3;
        config.textProperties.color = rowEnabled ? UIColor.labelColor : UIColor.tertiaryLabelColor;
        config.secondaryTextProperties.color = rowEnabled ? UIColor.secondaryLabelColor : UIColor.tertiaryLabelColor;
        config.secondaryTextProperties.font = [UIFont systemFontOfSize:12];
        config.secondaryTextProperties.numberOfLines = 0;
        cell.contentConfiguration = config;
    } else {
        cell.contentConfiguration = nil;
        cell.textLabel.text = row[@"title"];
        cell.textLabel.textAlignment = NSTextAlignmentNatural;
        cell.textLabel.textColor = rowEnabled ? UIColor.labelColor : UIColor.tertiaryLabelColor;
    }
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = rowEnabled && [d boolForKey:row[@"key"]];
    sw.enabled = rowEnabled;
    sw.tag = (indexPath.section << 16) | indexPath.row;
    [sw addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

#pragma mark - Actions

- (NSDictionary *)rowForTag:(NSInteger)tag
{
    NSInteger section = (tag >> 16) & 0xFFFF;
    NSInteger row = tag & 0xFFFF;
    return [self rowsForSection:section][row];
}

- (void)presentApplyLogIfRunning
{
    // Skip if a modal is already up (e.g. the user just toggled a different
    // switch and the log is already visible).
    if (self.presentedViewController) return;
    // Skip if there's no live SpringBoard session — the change won't fire any
    // RemoteCall until the user runs the chain, so there's nothing to watch.
    if (!g_springboard_rc_ready) return;

    [self presentActivityLog];
}

- (void)presentActivityLog
{
    [self presentActivityLogWithCompletion:nil];
}

- (void)presentActivityLogWithCompletion:(dispatch_block_t)completion
{
    if (self.presentedViewController) {
        if ([self.presentedViewController isKindOfClass:UIAlertController.class]) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf presentActivityLogWithCompletion:completion];
            });
            return;
        }
        if (completion) completion();
        return;
    }

    InstallProgressViewController *vc = [[InstallProgressViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationAutomatic;
    [self presentViewController:nav animated:YES completion:completion];
}

- (void)toggleChanged:(UISwitch *)sender
{
    if (!settings_device_supported()) {
        sender.on = !sender.isOn;
        printf("[SETTINGS] toggle blocked: %s\n", settings_unsupported_message().UTF8String);
        return;
    }

    NSDictionary *row = [self rowForTag:sender.tag];
    if ([row[@"disabled"] boolValue]) {
        sender.on = !sender.isOn;
        printf("[SETTINGS] toggle blocked: %s is in progress\n", [row[@"key"] UTF8String]);
        return;
    }
    NSString *key = row[@"key"];
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:key];
    printf("[SETTINGS] toggle %s=%d\n", key.UTF8String, sender.isOn);
    settings_note_package_configuration_changed(key);
    if ([key isEqualToString:kSettingsKeepAlive]) {
        ds_keepalive_apply_enabled(sender.isOn);
        return;
    }
    if ([key isEqualToString:kRepoSourcesEnabledKey]) {
        settings_repo_sources_enabled_changed(sender.isOn);
        return;
    }
    if ([key isEqualToString:kSettingsVerboseLoggingEnabled]) {
        // Applies to ALL RemoteCall logging — exploit, tweak applies and the
        // Process Viewer — so it lives in Launch Options, not the Process Viewer.
        remote_call_set_verbose(sender.isOn);
        log_set_rc_filter(!sender.isOn);
        return;
    }
    if (settings_key_affects_package_state(key)) {
        if (!sender.isOn) settings_mark_tweak_applied(key, NO);
        settings_notify_package_queue_changed_async();
    }
    if ([key isEqualToString:kSettingsSBCHideLabels]) {
        // Mutually exclusive with Show dock labels. Clear it rather than leave a
        // switch on that the run will ignore, and redraw either way so the dock
        // row greys out or comes back live immediately.
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if (sender.isOn && [defaults boolForKey:kSettingsSBCDockLabels]) {
            [defaults setBool:NO forKey:kSettingsSBCDockLabels];
            printf("[SETTINGS] toggle %s=0 (cleared by %s)\n",
                   kSettingsSBCDockLabels.UTF8String, kSettingsSBCHideLabels.UTF8String);
            settings_note_package_configuration_changed(kSettingsSBCDockLabels);
            settings_mark_tweak_applied(kSettingsSBCDockLabels, NO);
        }
        [self.tableView reloadData];
    }
    if ([key isEqualToString:kSettingsRunAutoRetry]) {
        // Grey out / re-enable the attempt-cap stepper immediately.
        [self.tableView reloadData];
    }

    settings_schedule_live_apply_for_key(key);
    [self presentApplyLogIfRunning];
}

- (void)sliderChanged:(UISlider *)sender
{
    if (!settings_device_supported()) return;
    NSNumber *stepNum = objc_getAssociatedObject(sender, "cyanideStep");
    NSInteger step = stepNum ? [stepNum integerValue] : 1;
    if (step <= 0) step = 1;
    NSInteger value = (NSInteger)llround((double)sender.value / (double)step) * step;
    UILabel *valueLabel = objc_getAssociatedObject(sender, "cyanideValueLabel");
    NSString *unit = objc_getAssociatedObject(sender, "cyanideUnit") ?: @"";
    if (valueLabel) {
        valueLabel.text = [NSString stringWithFormat:@"%ld%@", (long)value, unit];
    }
}

- (void)settingsTextFieldEditingEnded:(UITextField *)sender
{
    [sender resignFirstResponder];
    if (!settings_device_supported()) return;

    NSString *key = objc_getAssociatedObject(sender, "cyanideSettingsTextKey");
    if (key.length == 0) return;

    NSString *value = [sender.text stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *defaultValue = objc_getAssociatedObject(sender, "cyanideSettingsTextDefault") ?: @"";
    if (value.length == 0) value = defaultValue;
    sender.text = value;

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *oldValue = [d stringForKey:key] ?: @"";
    if ([oldValue isEqualToString:value]) return;

    [d setObject:value forKey:key];
    [d synchronize];
    printf("[SETTINGS] text %s=%s\n", key.UTF8String, value.UTF8String);
    settings_note_package_configuration_changed(key);
    settings_schedule_live_apply_for_key(key);
    [self presentApplyLogIfRunning];
}

- (void)sliderEnded:(UISlider *)sender
{
    if (!settings_device_supported()) return;
    NSDictionary *row = [self rowForTag:sender.tag];
    if (!row) return;
    NSString *key = row[@"key"];
    NSInteger step = [row[@"step"] integerValue]; if (step <= 0) step = 1;
    NSInteger value = (NSInteger)llround((double)sender.value / (double)step) * step;
    sender.value = (float)value;  // snap thumb to the step grid
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL showLocationLog = settings_key_is_location_sim(key) && settings_location_sim_is_active(d);
    [d setInteger:value forKey:key];
    printf("[SETTINGS] slider %s=%ld\n", key.UTF8String, (long)value);
    settings_note_package_configuration_changed(key);
    if (showLocationLog) {
        [self presentActivityLogWithCompletion:^{
            settings_schedule_live_apply_for_key(key);
        }];
    } else {
        settings_schedule_live_apply_for_key(key);
        [self presentApplyLogIfRunning];
    }
    if (settings_key_is_location_sim(key)) {
        [self.tableView reloadData];
    }
}

- (void)presentNumberEntryForRow:(NSDictionary *)row section:(NSInteger)section
{
    NSString *key = row[@"key"];
    if (key.length == 0) return;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    double current = settings_number_row_current_value(row, d);
    NSString *minText = settings_number_row_value_string(row, [row[@"min"] doubleValue], YES);
    NSString *maxText = settings_number_row_value_string(row, [row[@"max"] doubleValue], YES);
    NSString *message = [NSString stringWithFormat:@"Enter %@ to %@.%@%@",
                         minText,
                         maxText,
                         [row[@"subtitle"] length] > 0 ? @"\n\n" : @"",
                         row[@"subtitle"] ?: @""];

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:row[@"title"]
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = settings_number_row_value_string(row, current, NO);
        field.placeholder = settings_number_row_value_string(row, [row[@"default"] doubleValue], NO);
        field.keyboardType = (row[@"precision"] && [row[@"precision"] integerValue] > 0)
            ? UIKeyboardTypeDecimalPad
            : UIKeyboardTypeNumberPad;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        [field selectAll:nil];
    }];

    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Save"
                                           style:UIAlertActionStyleDefault
                                         handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSString *input = ac.textFields.firstObject.text ?: @"";
        NSString *trimmed = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *normalizedInput = [trimmed stringByReplacingOccurrencesOfString:@"," withString:@"."];
        NSScanner *scanner = [NSScanner scannerWithString:normalizedInput];
        scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

        double parsed = 0.0;
        BOOL ok = [scanner scanDouble:&parsed];
        [scanner scanCharactersFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet intoString:NULL];
        if (!ok || ![scanner isAtEnd] || !isfinite(parsed)) {
            UIAlertController *err = [UIAlertController
                alertControllerWithTitle:@"Invalid Number"
                                 message:@"Enter a plain number, then try again."
                          preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                settings_present_controller(err, strongSelf);
            });
            return;
        }

        double value = settings_number_row_normalized_value(row, parsed);
        if ([key isEqualToString:kSettingsDSDragCoefficientValue] ||
            (row[@"precision"] && [row[@"precision"] integerValue] > 0)) {
            [d setDouble:value forKey:key];
        } else {
            [d setInteger:(NSInteger)llround(value) forKey:key];
        }
        [d synchronize];

        NSString *valueText = settings_number_row_value_string(row, value, YES);
        printf("[SETTINGS] number %s=%s\n", key.UTF8String, valueText.UTF8String);
        settings_note_package_configuration_changed(key);
        settings_schedule_live_apply_for_key(key);
        [strongSelf reloadSectionOrAll:section];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            [strongSelf presentApplyLogIfRunning];
        });
    }]];
    settings_present_controller(ac, self);
}

- (void)runLocationServicesToggle
{
    if (!settings_device_supported()) return;
    [self presentActivityLog];
    [self runLocationServicesToggleAllowingFullExploit:NO];
}

- (void)runLocationServicesToggleAllowingFullExploit:(BOOL)allowFullExploit
{
    __weak typeof(self) weakSelf = self;
    settings_location_services_set_async(-1, allowFullExploit, NO, 0, nil,
                                         ^(BOOL ok, NSString *message, NSTimeInterval resultAge) {
        typeof(self) me = weakSelf;
        [me reloadLocationSimUI];
        if (!me || ok || allowFullExploit ||
            ![message isEqualToString:kSettingsFullExploitRequiredMessage]) return;
        // Only a full exploit run would do: ask first, like the Process Viewer.
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"No parked kernel state"
                             message:@"Changing Location Services needs kernel access, and there is no saved session to reuse. Running the full exploit can reboot the device on A18/M4. Continue?"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Run Full Exploit"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            [weakSelf runLocationServicesToggleAllowingFullExploit:YES];
        }]];
        settings_present_controller(ac, me);
    });
}

- (void)reloadLocationSimUI
{
    [self.tableView reloadData];
    [[NSNotificationCenter defaultCenter] postNotificationName:PackageQueueDidChangeNotification
                                                        object:[PackageQueue sharedQueue]];
}

- (void)runGravityLiteAction:(NSString *)action
{
    if (!settings_device_supported()) return;
    BOOL restore = [action isEqualToString:@"gravitylite-restore"];
    BOOL explosion = [action isEqualToString:@"gravitylite-explosion"];
    if (!restore && !explosion) return;

    dispatch_block_t startAction = ^{
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            __block BOOL actionOK = NO;
            BOOL actionLockAcquired = NO;
            NSString *completionMessage = restore
                ? @"Gravity Lite restore failed. Check the log."
                : @"Gravity Lite explosion failed. Check the log.";
            @try {
                actionLockAcquired = settings_try_claim_actions_lock("Gravity Lite action",
                                                                     "[GRAVITY] Another action is already running.");
                if (!actionLockAcquired) {
                    completionMessage = @"Gravity Lite blocked: Apply Tweaks is still running.";
                    return;
                }
                if (!settings_ensure_kexploit()) {
                    log_user("[GRAVITY] Failed: kernel primitives not acquired. Please try running chain again.\n");
                    completionMessage = @"Gravity Lite failed: kernel primitives were not acquired. Please try running chain again.";
                    return;
                }

                @synchronized (settings_rc_lock()) {
                    if (g_springboard_rc_ready) {
                        actionOK = restore
                            ? gravitylite_stop_in_session()
                            : gravitylite_explosion_in_session(settings_gravitylite_config_from_defaults(d).explosionForce);
                    } else {
                        RemoteCallSession *springboardSession =
                            [[RemoteCallSession alloc] initWithProcess:@"SpringBoard"
                                                     useMigFilterBypass:NO
                                                firstExceptionTimeoutMS:kSettingsSpringBoardRCFirstExceptionTimeoutMS];
                        if (!springboardSession) {
                            log_user("[GRAVITY] SpringBoard not reachable.\n");
                        } else {
                            remote_call_with_session(springboardSession, ^{
                                actionOK = restore
                                    ? gravitylite_stop_in_session()
                                    : gravitylite_explosion_in_session(settings_gravitylite_config_from_defaults(d).explosionForce);
                            });
                            [springboardSession destroyRemoteCall];
                        }
                    }
                }

                if (restore) {
                    __sync_lock_test_and_set(&g_gravitylite_background_armed, 0);
                    settings_stop_gravity_motion();
                    settings_mark_tweak_applied(kSettingsGravityLiteEnabled, NO);
                    completionMessage = actionOK
                        ? @"Gravity Lite restored the icon layout."
                        : @"Gravity Lite restore found no active state.";
                    log_user("%s Gravity Lite restore %s.\n",
                             actionOK ? "[OK]" : "[WARN]",
                             actionOK ? "completed" : "found no active state");
                } else {
                    completionMessage = actionOK
                        ? @"Gravity Lite explosion pulse sent."
                        : @"Gravity Lite explosion found no active state.";
                    log_user("%s Gravity Lite explosion %s.\n",
                             actionOK ? "[OK]" : "[WARN]",
                             actionOK ? "sent" : "found no active state");
                }
            } @finally {
                if (actionLockAcquired) settings_release_actions_lock();
                settings_notify_package_queue_changed_async();
                settings_post_actions_complete_async(actionOK, completionMessage);
            }
        });
    };
    [self presentActivityLogWithCompletion:startAction];
}

- (void)runLocationSimApply:(BOOL)apply
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (apply && !settings_location_sim_install_allowed()) {
        log_user("[LOCSIM] Location Simulator is unavailable in this build.\n");
        return;
    }

    static volatile int sLocSimButtonInFlight = 0;
    if (__sync_lock_test_and_set(&sLocSimButtonInFlight, 1)) {
        log_user("[LOCSIM] A Location Simulator action is already running.\n");
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_block_t startAction = ^{
        log_user("[LOCSIM] %s %s.\n",
                 apply ? "Simulating" : "Restoring",
                 apply ? settings_location_sim_target_summary(d).UTF8String : "real location");
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            BOOL actionOK = NO;
            BOOL actionLockAcquired = NO;
            NSString *completionMessage = apply
                ? @"Location Simulator applied."
                : @"Restore request sent. Real location may take a few minutes.";
            @try {
                actionLockAcquired = settings_try_claim_actions_lock("Location Simulator action",
                                                                     "[LOCSIM] Another action is already running.");
                if (!actionLockAcquired) {
                    completionMessage = @"Location Simulator blocked: Apply Tweaks is still running.";
                    return;
                }
                if (!settings_ensure_kexploit()) {
                    log_user("[LOCSIM] Failed: kernel primitives not acquired. Please try running chain again.\n");
                    completionMessage = @"Location Simulator failed: kernel primitives were not acquired. Please try running chain again.";
                    return;
                }

                bool ok = false;
                @synchronized (settings_rc_lock()) {
                    settings_destroy_springboard_remote_call_locked_internal("switching to Location Simulator", NO);
                    ok = apply
                        ? settings_apply_location_sim_from_defaults_locked(d)
                        : settings_stop_location_sim_from_defaults_locked(d);
                    if (ok) {
                        if (apply) {
                            [d setBool:YES forKey:kSettingsLocationSimStarted];
                        } else {
                            [d setBool:NO forKey:kSettingsLocationSimStarted];
                        }
                        [d synchronize];
                    }
                }
                actionOK = ok;
                completionMessage = apply
                    ? (ok ? @"Location Simulator applied." : @"Location Simulator failed. Check the log.")
                    : (ok ? @"Restore request sent. Real location may take a few minutes." : @"Restore failed. Check the log.");
                log_user("%s Location Simulator %s.\n",
                         ok ? "[OK]" : "[WARN]",
                         apply ? (ok ? "applied" : "did not apply cleanly")
                               : (ok ? "stopped; real location should resume" : "did not stop cleanly"));
            } @finally {
                if (actionLockAcquired) settings_release_actions_lock();
                __sync_lock_release(&sLocSimButtonInFlight);
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    [strongSelf reloadLocationSimUI];
                    NSDictionary *info = @{
                        kSettingsActionsDidCompleteSuccessKey: @(actionOK),
                        kSettingsActionsDidCompleteMessageKey: completionMessage ?: @""
                    };
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:kSettingsActionsDidCompleteNotification
                                      object:nil
                                    userInfo:info];
                });
            }
        });
    };
    [self presentActivityLogWithCompletion:startAction];
}

- (void)runLocationSimUberStealth:(BOOL)enable
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (enable && !settings_location_sim_install_allowed()) {
        log_user("[LOCSIM] Location Simulator is unavailable in this build.\n");
        return;
    }

    static volatile int sLocSimUberStealthInFlight = 0;
    if (__sync_lock_test_and_set(&sLocSimUberStealthInFlight, 1)) {
        log_user("[LOCSIM] A Strict App Mode action is already running.\n");
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_block_t startAction = ^{
        log_user("[LOCSIM] %s Strict App Mode for %s.\n",
                 enable ? "Priming" : "Disabling",
                 enable ? settings_location_sim_target_summary(d).UTF8String : "the running process");
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            BOOL actionOK = NO;
            BOOL actionLockAcquired = NO;
            NSString *completionMessage = enable
                ? @"Strict App Mode failed. Check the log."
                : @"Strict App Mode disable failed. Check the log.";
            @try {
                actionLockAcquired = settings_try_claim_actions_lock("Location Simulator strict mode",
                                                                     "[LOCSIM] Another action is already running.");
                if (!actionLockAcquired) {
                    completionMessage = @"Strict App Mode blocked: Apply Tweaks is still running.";
                    return;
                }
                if (!settings_ensure_kexploit()) {
                    log_user("[LOCSIM] Strict App Mode failed: kernel primitives not acquired. Please try running chain again.\n");
                    completionMessage = @"Strict App Mode failed: kernel primitives were not acquired. Please try running chain again.";
                    return;
                }

                BOOL systemOK = NO;
                BOOL stealthOK = NO;
                @synchronized (settings_rc_lock()) {
                    settings_destroy_springboard_remote_call_locked_internal("switching to Location Simulator strict app mode", NO);
                    stealthOK = settings_prime_location_sim_uber_stealth_locked(d, enable, &systemOK);
                    if (enable && systemOK) {
                        [d setBool:YES forKey:kSettingsLocationSimStarted];
                        [d synchronize];
                    }
                }

                actionOK = stealthOK;
                if (enable) {
                    completionMessage = stealthOK
                        ? @"Strict mode host sweep finished. Force quit and reopen strict apps before testing."
                        : @"Strict App Mode failed. Check the log.";
                } else {
                    completionMessage = stealthOK
                        ? @"Strict mode simulation stop request sent."
                        : @"Strict App Mode disable failed. Check the log.";
                }

                log_user("%s Strict App Mode %s (hosts=%s).\n",
                         stealthOK ? "[OK]" : "[WARN]",
                         enable ? "prime finished" : "disable finished",
                         systemOK ? "ok" : "failed");
            } @finally {
                if (actionLockAcquired) settings_release_actions_lock();
                __sync_lock_release(&sLocSimUberStealthInFlight);
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    [strongSelf reloadLocationSimUI];
                    NSDictionary *info = @{
                        kSettingsActionsDidCompleteSuccessKey: @(actionOK),
                        kSettingsActionsDidCompleteMessageKey: completionMessage ?: @""
                    };
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:kSettingsActionsDidCompleteNotification
                                      object:nil
                                    userInfo:info];
                });
            }
        });
    };
    [self presentActivityLogWithCompletion:startAction];
}

- (void)setLocationSimTargetLatitude:(double)latitude
                            longitude:(double)longitude
                                 name:(NSString *)name
                        applyIfActive:(BOOL)applyIfActive
{
    if (!settings_location_sim_coordinates_valid(latitude, longitude)) {
        log_user("[LOCSIM] Invalid coordinates: lat=%f lon=%f\n", latitude, longitude);
        return;
    }

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL wasActive = settings_location_sim_is_active(d);
    settings_location_sim_set_target(d, latitude, longitude);
    log_user("[LOCSIM] Target set to %s: %s\n",
             (name.length > 0 ? name : @"custom").UTF8String,
             settings_location_sim_target_summary(d).UTF8String);
    [self reloadLocationSimUI];
    if (applyIfActive && wasActive) {
        [self runLocationSimApply:YES];
    }
}

- (void)presentLocationSimInvalidCoordinateAlert
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Invalid Coordinates"
                                                                message:@"Use decimal degrees. Latitude must be between -90 and 90. Longitude must be between -180 and 180. Chinese labels like 北纬/南纬/东经/西经 and full-width punctuation are supported."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    settings_present_controller(ac, self);
}

- (void)presentLocationSimExactCoordinatePrompt
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Exact Coordinates"
                                                                message:@"Enter decimal degrees, or paste a pair like 40.7128, -74.0060 or 北纬39.9042，东经116.4074."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Latitude or lat, lon";
        field.text = [NSString stringWithFormat:@"%.8f", [d doubleForKey:kSettingsLocationSimLatitude]];
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Longitude";
        field.text = [NSString stringWithFormat:@"%.8f", [d doubleForKey:kSettingsLocationSimLongitude]];
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    __weak typeof(self) weakSelf = self;
    void (^commit)(BOOL) = ^(BOOL simulateNow) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        double latitude = 0.0;
        double longitude = 0.0;
        BOOL ok = settings_location_sim_parse_coordinate_fields(ac.textFields.firstObject.text,
                                                                ac.textFields.lastObject.text,
                                                                &latitude,
                                                                &longitude);
        if (!ok) {
            [strongSelf presentLocationSimInvalidCoordinateAlert];
            return;
        }
        [strongSelf setLocationSimTargetLatitude:latitude
                                       longitude:longitude
                                            name:@"Exact coordinates"
                                   applyIfActive:!simulateNow];
        if (simulateNow) {
            [strongSelf runLocationSimApply:YES];
        }
    };

    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Set Target"
                                           style:UIAlertActionStyleDefault
                                         handler:^(__unused UIAlertAction *action) {
        commit(NO);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Set & Simulate"
                                           style:UIAlertActionStyleDefault
                                         handler:^(__unused UIAlertAction *action) {
        commit(YES);
    }]];
    settings_present_controller(ac, self);
}

- (void)presentLocationSimCityPicker
{
    NSArray<NSDictionary *> *cities = @[
        @{ @"name": @"New York City", @"lat": @40.7128, @"lon": @(-74.0060) },
        @{ @"name": @"Los Angeles", @"lat": @34.0522, @"lon": @(-118.2437) },
        @{ @"name": @"Chicago", @"lat": @41.8781, @"lon": @(-87.6298) },
        @{ @"name": @"Miami", @"lat": @25.7617, @"lon": @(-80.1918) },
        @{ @"name": @"London", @"lat": @51.5074, @"lon": @(-0.1278) },
        @{ @"name": @"Paris", @"lat": @48.8566, @"lon": @2.3522 },
        @{ @"name": @"Tokyo", @"lat": @35.6762, @"lon": @139.6503 },
        @{ @"name": @"Sydney", @"lat": @(-33.8688), @"lon": @151.2093 },
        @{ @"name": @"Dubai", @"lat": @25.2048, @"lon": @55.2708 },
        @{ @"name": @"Singapore", @"lat": @1.3521, @"lon": @103.8198 },
    ];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Major Cities"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSDictionary *city in cities) {
        NSString *name = city[@"name"];
        [ac addAction:[UIAlertAction actionWithTitle:name
                                               style:UIAlertActionStyleDefault
                                             handler:^(__unused UIAlertAction *action) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf setLocationSimTargetLatitude:[city[@"lat"] doubleValue]
                                           longitude:[city[@"lon"] doubleValue]
                                                name:name
                                       applyIfActive:NO];
            [strongSelf runLocationSimApply:YES];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = self.view.bounds;
    settings_present_controller(ac, self);
}

- (void)stepperChanged:(UIStepper *)sender
{
    if (!settings_device_supported()) {
        printf("[SETTINGS] stepper blocked: %s\n", settings_unsupported_message().UTF8String);
        return;
    }

    NSDictionary *row = [self rowForTag:sender.tag];
    NSInteger value = (NSInteger)sender.value;
    [[NSUserDefaults standardUserDefaults] setInteger:value forKey:row[@"key"]];

    // NanoRegistry steppers are seed values for an explicit Apply button;
    // they don't drive a live SpringBoard RC loop, so skip the auto-apply.
    NSString *key = row[@"key"];
    settings_note_package_configuration_changed(key);
    BOOL isNano = [key isEqualToString:kSettingsNanoMaxPairing]
                || [key isEqualToString:kSettingsNanoMinPairing]
                || [key isEqualToString:kSettingsNanoMinPairingChipID]
                || [key isEqualToString:kSettingsNanoMinQuickSwitch];
    if (!isNano) {
        settings_schedule_live_apply_for_key(key);
        [self presentApplyLogIfRunning];
    }

    UIView *v = sender.superview;
    while (v && ![v isKindOfClass:UITableViewCell.class]) v = v.superview;
    UITableViewCell *cell = (UITableViewCell *)v;
    if (cell) {
        NSString *combined = [NSString stringWithFormat:@"%@: %ld", row[@"title"], (long)value];
        NSString *subtitle = row[@"subtitle"];
        if (subtitle.length > 0 && [cell.contentConfiguration isKindOfClass:UIListContentConfiguration.class]) {
            UIListContentConfiguration *config = (UIListContentConfiguration *)[(id<NSCopying>)cell.contentConfiguration copyWithZone:nil];
            config.text = combined;
            cell.contentConfiguration = config;
        } else {
            cell.textLabel.text = combined;
        }
    }
}

- (void)a18PathSegChanged:(UISegmentedControl *)sender
{
    // Segment 0 is pe_v1, which is stored as 1 -- see the control's comment.
    // Stored values: 1 = pe_v1, 0 = pe_v2, 2 = pe_v3 (single-hunt).
    NSInteger path = (sender.selectedSegmentIndex == 0) ? 1
                   : (sender.selectedSegmentIndex == 2) ? 2 : 0;
    [[NSUserDefaults standardUserDefaults] setInteger:path forKey:kSettingsA18ExploitPath];
    [[NSUserDefaults standardUserDefaults] synchronize];
    log_user("[KRW] A18 exploit path set to %s. Takes effect on the next fresh chain run "
             "(a parked/recovered session skips the exploit entirely).\n",
             path == 1 ? "pe_v1 (default)"
             : path == 2 ? "pe_v3 (single-hunt)"
                         : "pe_v2 (fallback)");
    // The pe_v1-only options (shaping/interleave/bounded) enable/disable with the
    // path -- reload so they grey out or come back live immediately.
    [self.tableView reloadData];
}

- (void)settleModeSegChanged:(UISegmentedControl *)sender
{
    NSInteger mode = sender.selectedSegmentIndex;
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kSettingsRemoteSettleMode];
    [[NSUserDefaults standardUserDefaults] synchronize];
    r_settle_set_mode((int)mode);
    log_user("[TWEAKS] Apply speed set to %s. Watch the log for \"[R_OBJC] ... ms slept\" to see "
             "the difference on the next apply.\n",
             mode == 0 ? "Compatible" : mode == 1 ? "Fast" : "Fastest");
}

- (void)a18ShapeSegChanged:(UISegmentedControl *)sender
{
    NSInteger mode = sender.selectedSegmentIndex;
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kSettingsA18MemoryShaping];
    [[NSUserDefaults standardUserDefaults] synchronize];
    log_user("[KRW] A18 memory shaping set to %s. Effective on the next fresh chain run.\n",
             mode == 0 ? "Off (standard geometry)" :
             mode == 1 ? "Dynamic (75% of jetsam headroom)" : "3 GB (fixed)");
}

- (void)powercuffSegChanged:(UISegmentedControl *)sender
{
    if (!settings_device_supported()) {
        printf("[SETTINGS] powercuff level blocked: %s\n", settings_unsupported_message().UTF8String);
        return;
    }

    NSArray<NSString *> *levels = powercuff_levels();
    if (sender.selectedSegmentIndex < 0 || sender.selectedSegmentIndex >= (NSInteger)levels.count) return;
    [[NSUserDefaults standardUserDefaults] setObject:levels[sender.selectedSegmentIndex]
                                              forKey:kSettingsPowercuffLevel];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (!self.detailMode) {
        switch ((RootSection)indexPath.section) {
            case RootSectionWarning:
                return;
            case RootSectionChangelog: {
                if (!self.changelogExpanded) {
                    self.changelogExpanded = YES;
                    [tableView reloadSections:[NSIndexSet indexSetWithIndex:RootSectionChangelog]
                             withRowAnimation:UITableViewRowAnimationAutomatic];
                    return;
                }
                NSInteger entryCount = (NSInteger)settings_changelog_entries().count;
                if (indexPath.row == entryCount) {
                    [self openReleasesPage];
                } else if (indexPath.row > entryCount) {
                    self.changelogExpanded = NO;
                    [tableView reloadSections:[NSIndexSet indexSetWithIndex:RootSectionChangelog]
                             withRowAnimation:UITableViewRowAnimationAutomatic];
                }
                return;
            }
            case RootSectionActions:
                indexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:SectionActions];
                break;
            case RootSectionInDev:
            case RootSectionTweakBundles:
            case RootSectionSystemBundles: {
                NSArray<NSDictionary *> *bundles = (RootSection)indexPath.section == RootSectionInDev
                    ? self.inDevBundleRows
                    : ((RootSection)indexPath.section == RootSectionTweakBundles
                        ? self.tweakBundleRows
                        : self.systemBundleRows);
                NSDictionary *bundle = bundles[indexPath.row];
                if ([bundle[@"custom"] isEqualToString:@"procmgr"]) {
                    ProcessManagerViewController *pm = [[ProcessManagerViewController alloc] initWithStyle:UITableViewStylePlain];
                    [self.navigationController pushViewController:pm animated:YES];
                    return;
                }
                if ([bundle[@"custom"] isEqualToString:@"filebrowser"]) {
                    FileBrowserViewController *fb = [[FileBrowserViewController alloc] initWithPath:@"/"];
                    [self.navigationController pushViewController:fb animated:YES];
                    return;
                }
                NSInteger underlying = [bundle[@"section"] integerValue];
                NSString *pushTitle = bundle[@"title"];
                SettingsViewController *detail = [[SettingsViewController alloc] initWithUnderlyingSection:underlying
                                                                                              bundleTitle:pushTitle];
                [self.navigationController pushViewController:detail animated:YES];
                return;
            }
            case RootSectionAbout: {
                switch (indexPath.row) {
                    case 0: [self openTwitter]; break;
                    case 1: {
                        DocsViewController *docs = [[DocsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
                        [self.navigationController pushViewController:docs animated:YES];
                        break;
                    }
                    case 2: [self showAppIconPicker]; break;
                    case 3: [self openViewLog]; break;
                    case 4: [self openShareLog]; break;
                    // Row 5: Auto-Upload — UISwitch handles it
                }
                return;
            }
            case RootSectionCount:
                return;
        }
    } else {
        indexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:self.underlyingSection];
    }

    if (!settings_device_supported() &&
        indexPath.section != SectionWarning &&
        indexPath.section != SectionOTA &&
        indexPath.section != SectionThemer) {
        printf("[SETTINGS] tap blocked: %s\n", settings_unsupported_message().UTF8String);
        return;
    }

    NSArray<NSDictionary *> *rows = [self rowsForSection:indexPath.section];
    if (indexPath.row < (NSInteger)rows.count) {
        NSDictionary *row = rows[indexPath.row];
        if ([row[@"kind"] isEqualToString:@"number"]) {
            [self presentNumberEntryForRow:row section:indexPath.section];
            return;
        }
    }

    if (indexPath.section == SectionActions) {
        if (indexPath.row == 0) {
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:@"Clean Up?"
                                 message:@"Stops live SpringBoard sessions and closes local KRW state. The next Run will try recovery first."
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                   style:UIAlertActionStyleCancel
                                                 handler:nil]];
            [ac addAction:[UIAlertAction actionWithTitle:@"Clean Up"
                                                   style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction *_) {
                settings_queue_terminal_kexploit_cleanup("manual action");
            }]];
            settings_present_controller(ac, self);
        } else if (indexPath.row == 1) {
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:@"Respring?"
                                 message:@"Are you sure you want to respring? SpringBoard will restart."
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                   style:UIAlertActionStyleCancel
                                                 handler:nil]];
            __weak typeof(self) weakSelf = self;
            [ac addAction:[UIAlertAction actionWithTitle:@"Respring"
                                                   style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction *_) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    if (__sync_lock_test_and_set(&g_settings_actions_running, 1)) {
                        printf("[SETTINGS] respring blocked: actions already running\n");
                        return;
                    }

                    __sync_lock_test_and_set(&g_settings_respring_cleanup_running, 1);
                    settings_notify_cleanup_state_changed();
                    @try {
                        settings_prepare_for_respring_sync();
                    } @finally {
                        __sync_lock_release(&g_settings_actions_running);
                        __sync_lock_release(&g_settings_respring_cleanup_running);
                        settings_notify_cleanup_state_changed();
                    }

                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        if (!strongSelf) return;
                        settings_show_respring_overlay(strongSelf);
                    });
                });
            }]];
            settings_present_controller(ac, self);
        } else if (indexPath.row == 2) {
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:@"Reset All Packages?"
                                 message:@"Deactivates every package and clears pending changes. Already-applied patches stay until respring or reboot. Per-tweak settings are not affected."
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                   style:UIAlertActionStyleCancel
                                                 handler:nil]];
            [ac addAction:[UIAlertAction actionWithTitle:@"Reset"
                                                   style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction *_) {
                NSUInteger uninstalled = 0;
                for (Package *p in [PackageCatalog allPackages]) {
                    if (p.isInstalled || p.isQueuedForApply) {
                        [p applyCommittedState:NO];
                        uninstalled++;
                    }
                }
                NSInteger cleared = [[PackageQueue sharedQueue] pendingCount];
                [[PackageQueue sharedQueue] clear];
                log_user("[INSTALLER] Reset: deactivated %lu package(s), cleared %ld pending change(s).\n",
                         (unsigned long)uninstalled, (long)cleared);
                [self.tableView reloadData];
            }]];
            settings_present_controller(ac, self);
        } else if (indexPath.row == 3) {
            [[UpdateChecker shared] checkForUpdatesManuallyFrom:self];
        }
    }

    if (indexPath.section == SectionOTA) {
        if (indexPath.row == 2) {
            [self runOTAStatusRead];
        } else {
            settings_run_ota_action(indexPath.row == 0);
        }
        return;
    }

    if (indexPath.section == SectionLockScreenDuration) {
        NSArray<NSDictionary *> *rows = [self rowsForSection:SectionLockScreenDuration];
        if (indexPath.row < (NSInteger)rows.count) {
            NSString *action = rows[indexPath.row][@"action"];
            if ([action isEqualToString:@"lockdur-apply"]) {
                [self runLockScreenDurationApply:NO];
                return;
            }
            if ([action isEqualToString:@"lockdur-remove"]) {
                [self runLockScreenDurationApply:YES];
                return;
            }
            if ([action isEqualToString:@"lockdur-read"]) {
                [self runLockScreenDurationRead];
                return;
            }
        }
        // The number row falls through to the generic number-entry handler.
    }

    if (indexPath.section == SectionNanoRegistry) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if (![row[@"kind"] isEqualToString:@"button"]) return;
        NSString *action = row[@"action"];

        if ([action isEqualToString:@"nano-load"]) {
            if (!settings_nano_load_override_enabled()) {
                log_user("[NANO] Load Current Override requires parked KRW recovery; button is disabled until recovery is available.\n");
                return;
            }
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                if (!settings_try_claim_actions_lock("NanoRegistry load",
                                                     "[NANO] Another action is already running.")) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                                      withRowAnimation:UITableViewRowAnimationNone];
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:kSettingsActionsDidCompleteNotification
                                          object:nil];
                    });
                    return;
                }
                @try {
                    if (!settings_ensure_kexploit_recovery_only()) {
                        log_user("[NANO] Failed: parked KRW recovery was not acquired.\n");
                    } else {
                        settings_nano_load_from_plist_into_defaults(YES);
                    }
                } @finally {
                    settings_release_actions_lock();
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                                  withRowAnimation:UITableViewRowAnimationNone];
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:kSettingsActionsDidCompleteNotification
                                      object:nil];
                });
            });
        } else if ([action isEqualToString:@"nano-preset-newer"]) {
            settings_nano_set_defaults_values(kNanoPresetNewerMaxPairing,
                                              kNanoPresetNewerMinPairing,
                                              kNanoPresetNewerMinPairingChipID,
                                              kNanoPresetNewerMinQuickSwitch);
            log_user("[NANO] Loaded pairing range 99/23/10/6: max=%ld min=%ld minChip=%ld minQuick=%ld. Hit Apply to write.\n",
                     (long)kNanoPresetNewerMaxPairing,
                     (long)kNanoPresetNewerMinPairing,
                     (long)kNanoPresetNewerMinPairingChipID,
                     (long)kNanoPresetNewerMinQuickSwitch);
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                          withRowAnimation:UITableViewRowAnimationNone];
        } else if ([action isEqualToString:@"nano-apply"]) {
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:@"Apply Pairing Override?"
                                 message:@"Saves these watchOS pairing settings on this iPhone. Respring or reboot afterwards before trying to pair."
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [ac addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
                settings_run_nano_apply_action();
            }]];
            settings_present_controller(ac, self);
        } else if ([action isEqualToString:@"nano-probe"]) {
            settings_run_nano_probe_action();
        } else if ([action isEqualToString:@"nano-steer"]) {
            settings_run_nano_steer_action();
        } else if ([action isEqualToString:@"nano-seed"]) {
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:@"Seed Compatibility Index?"
                                 message:@"Adds this phone's product type to the local NanoRegistry compatibility-index MobileAsset and saves a .cyanide.bak backup beside the original file."
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [ac addAction:[UIAlertAction actionWithTitle:@"Seed" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
                settings_run_nano_seed_action();
            }]];
            settings_present_controller(ac, self);
        } else if ([action isEqualToString:@"nano-clear"]) {
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:@"Remove Pairing Override?"
                                 message:@"Removes the saved Watch Pairing Override without touching the rest of your watch data. Respring or reboot afterwards."
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [ac addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
                settings_run_nano_clear_action();
            }]];
            settings_present_controller(ac, self);
        }
        return;
    }

    if (indexPath.section == SectionGravityLite) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if (![row[@"kind"] isEqualToString:@"button"]) return;
        [self runGravityLiteAction:row[@"action"]];
        return;
    }

    if (indexPath.section == SectionLocationSim) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if (![row[@"kind"] isEqualToString:@"button"]) return;
        NSString *action = row[@"action"];
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;

        if ([action isEqualToString:@"locsim-preset-rockaway"]) {
            settings_location_sim_set_rockaway_defaults(d);
            log_user("[LOCSIM] Loaded Rockaway test point: %s\n",
                     settings_location_sim_target_summary(d).UTF8String);
            [self reloadLocationSimUI];
            [self runLocationSimApply:YES];
            return;
        }

        if ([action isEqualToString:@"locsim-set-exact"]) {
            [self presentLocationSimExactCoordinatePrompt];
            return;
        }

        if ([action isEqualToString:@"locsim-major-cities"]) {
            [self presentLocationSimCityPicker];
            return;
        }

        if ([action isEqualToString:@"locsvc-toggle"]) {
            [self runLocationServicesToggle];
            return;
        }

        if ([action isEqualToString:@"locsim-apply"] ||
            [action isEqualToString:@"locsim-stop"]) {
            BOOL apply = [action isEqualToString:@"locsim-apply"];
            [self runLocationSimApply:apply];
            return;
        }

        return;
    }




    if (indexPath.section == SectionFastLockXLite) {
        if (!settings_fastlockx_lite_install_allowed()) {
            log_user("[FLX] FastLockX Lite is unavailable in this build.\n");
            return;
        }
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if (![row[@"kind"] isEqualToString:@"button"]) return;
        NSString *action = row[@"action"];
        BOOL probe = [action isEqualToString:@"fastlockx-probe"];
        BOOL enableAlways = [action isEqualToString:@"fastlockx-enable"];
        BOOL disableAlways = [action isEqualToString:@"fastlockx-disable"];
        BOOL window = [action isEqualToString:@"fastlockx-window"];
        BOOL pulse = [action isEqualToString:@"fastlockx-once"] || window;
        BOOL unlock = [action isEqualToString:@"fastlockx-once"] ||
                      [action isEqualToString:@"fastlockx-unlock"] ||
                      window;
        if (!probe && !enableAlways && !disableAlways && !pulse && !unlock) return;

        [self presentActivityLog];
        UIBackgroundTaskIdentifier bgTask = [[UIApplication sharedApplication]
            beginBackgroundTaskWithName:@"FastLockX Lite"
                      expirationHandler:^{
            log_user("[FLX] Background time expired; stopping FastLockX Lite action.\n");
        }];

        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            BOOL actionLockAcquired = settings_try_claim_actions_lock("FastLockX Lite",
                                                                     "[FLX] Another action is already running.");
            if (!actionLockAcquired) {
                if (bgTask != UIBackgroundTaskInvalid) {
                    [[UIApplication sharedApplication] endBackgroundTask:bgTask];
                }
                return;
            }

            @try {
                if (!settings_ensure_kexploit()) {
                    log_user("[FLX] Failed: kernel primitives not acquired. Run the chain, then try again.\n");
                    return;
                }

                NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
                @synchronized (settings_rc_lock()) {
                    if (!settings_ensure_springboard_remote_call_locked()) {
                        log_user("[FLX] SpringBoard not reachable; cannot send FastLockX Lite request.\n");
                        return;
                    }

                    if (probe) {
                        bool ok = fastlockx_lite_probe_in_session();
                        log_user("%s FastLockX Lite probe %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "found usable primitives" : "did not find enough primitives");
                        return;
                    }

                    if (disableAlways) {
                        bool ok = fastlockx_lite_disable_always_on_in_session();
                        __sync_lock_test_and_set(&g_fastlockx_lite_remote_active_state, -1);
                        __sync_lock_test_and_set(&g_fastlockx_lite_last_unlock_nudge_ms, 0);
                        if (ok) {
                            [d setBool:NO forKey:kSettingsFastLockXLiteEnabled];
                            [d synchronize];
                            settings_mark_tweak_applied(kSettingsFastLockXLiteEnabled, NO);
                            settings_notify_package_queue_changed_async();
                        }
                        log_user("%s FastLockX Lite Always On %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "disabled" : "could not be disabled; respring will stop it");
                    } else if (enableAlways) {
                        [d setBool:YES forKey:kSettingsFastLockXLiteEnabled];
                        [d synchronize];
                        FastLockXLiteConfig config = settings_fastlockx_lite_config_from_defaults(d, YES, YES);
                        config.diagnosticLogging = NO;
                        bool ok = fastlockx_lite_enable_always_on_in_session(config);
                        if (ok) {
                            (void)settings_refresh_screen_awake_state("fastlockx direct enable");
                            (void)settings_refresh_screen_lock_state("fastlockx direct enable");
                            BOOL active = !settings_screen_awake_cached() && settings_screen_locked_cached();
                            bool syncOK = fastlockx_lite_set_always_on_active_in_session(active);
                            __sync_lock_test_and_set(&g_fastlockx_lite_remote_active_state,
                                                     syncOK ? (active ? 1 : 0) : -1);
                            __sync_lock_test_and_set(&g_fastlockx_lite_last_unlock_nudge_ms, 0);
                            printf("[SETTINGS] FastLockX direct screen sync active=%d awake=%d locked=%d ok=%d\n",
                                   active,
                                   settings_screen_awake_cached(),
                                   settings_screen_locked_cached(),
                                   syncOK);
                        }
                        settings_mark_tweak_applied(kSettingsFastLockXLiteEnabled,
                                                    ok && [d boolForKey:kSettingsFastLockXLiteEnabled]);
                        settings_notify_package_queue_changed_async();
                        log_user("%s FastLockX Lite Always On %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "enabled" : "failed to enable");
                    } else if (window) {
                        NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 15.0;
                        int tick = 0;
                        log_user("[FLX] 15s auto-unlock window started. Lock the device now and let Face ID authenticate.\n");
                        while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
                            if (settings_cleanup_in_progress()) {
                                log_user("[FLX] Stopping window: cleanup started.\n");
                                break;
                            }
                            FastLockXLiteConfig config = settings_fastlockx_lite_config_from_defaults(d, YES, YES);
                            config.diagnosticLogging = NO;
                            if (tick > 0) {
                                config.blockOnMusic = false;
                                config.blockOnFlashlight = false;
                                config.blockOnLowPowerMode = false;
                            }
                            bool ok = fastlockx_lite_run_in_session(config);
                            tick++;
                            printf("[FLX] window tick=%d ok=%d\n", tick, ok);
                            usleep(300000);
                        }
                        log_user("[FLX] 15s auto-unlock window stopped.\n");
                    } else {
                        FastLockXLiteConfig config = settings_fastlockx_lite_config_from_defaults(d, pulse, unlock);
                        bool ok = fastlockx_lite_run_in_session(config);
                        log_user("%s FastLockX Lite request %s.\n",
                                 ok ? "[OK]" : "[WARN]",
                                 ok ? "completed" : "did not complete");
                    }
                }
            } @finally {
                settings_release_actions_lock();
                if (bgTask != UIBackgroundTaskInvalid) {
                    [[UIApplication sharedApplication] endBackgroundTask:bgTask];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    [strongSelf reloadSectionOrAll:SectionFastLockXLite];
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:kSettingsActionsDidCompleteNotification
                                      object:nil];
                });
            }
        });
        return;
    }

    if (indexPath.section == SectionAppSwitcherGrid) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if (![row[@"kind"] isEqualToString:@"button"]) return;
        NSString *action = row[@"action"];
        if ([action isEqualToString:@"appswitchergrid-restore"]) {
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            [d setBool:NO forKey:kSettingsAppSwitcherGridEnabled];
            [d synchronize];
            settings_mark_tweak_applied(kSettingsAppSwitcherGridEnabled, NO);
            settings_notify_package_queue_changed_async();
            if (!g_springboard_rc_ready) {
                appswitchergrid_forget_remote_state();
                log_user("[ASG] App Switcher Grid disabled. No active SpringBoard session was available; respring restores stock if needed.\n");
                [self reloadSectionOrAll:SectionAppSwitcherGrid];
                return;
            }
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() || !g_springboard_rc_ready) return;
                    bool ok = appswitchergrid_stop_in_session();
                    log_user("%s App Switcher Grid restore %s.\n",
                             ok ? "[OK]" : "[WARN]",
                             ok ? "completed" : "did not find an active patch; respring restores stock");
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self reloadSectionOrAll:SectionAppSwitcherGrid];
                });
            });
        }
        return;
    }

    if (indexPath.section == SectionNSBar) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if ([row[@"action"] isEqualToString:@"nsbar-position"]) {
            [self presentNSBarPositionPicker];
        }
        return;
    }

    if (indexPath.section == SectionNiceBarLite) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        NSString *action = row[@"action"];
        if ([action isEqualToString:@"nicebar-traffic-history"]) {
            CyanideNiceBarTrafficHistoryViewController *vc = [[CyanideNiceBarTrafficHistoryViewController alloc] init];
            [self.navigationController pushViewController:vc animated:YES];
            return;
        }
        if ([action isEqualToString:@"nicebar-apply"]) {
            if (!g_springboard_rc_ready) {
                log_user("[NICEBAR] Needs an active SpringBoard session. Hit Run first.\n");
                return;
            }
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            [d setBool:YES forKey:kSettingsNiceBarLiteEnabled];
            [d synchronize];
            log_user("[NICEBAR] Manual apply requested.\n");
            [self refreshNiceBarWeatherForce:YES];
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                bool ok = false;
                @synchronized (settings_rc_lock()) {
                    if (settings_cleanup_in_progress() || !g_springboard_rc_ready) return;
                    ok = settings_apply_nicebarlite_from_defaults_locked(d);
                    settings_mark_tweak_applied(kSettingsNiceBarLiteEnabled, ok);
                }
                log_user("%s NiceBar Lite applied now.\n", ok ? "[OK]" : "[WARN]");
                if (ok) settings_start_nicebarlite_live_loop();
                settings_notify_package_queue_changed_async();
            });
            return;
        }
        if ([action hasPrefix:@"nicebar-slot-"]) {
            NSInteger slot = [[action substringFromIndex:[@"nicebar-slot-" length]] integerValue];
            if (slot >= 0 && slot < NiceBarLiteSlotCount) {
                [self presentNiceBarSlotEditor:slot];
            }
        }
        return;
    }

    if (indexPath.section == SectionSnowBoardLite) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if (![row[@"kind"] isEqualToString:@"button"]) return;
        NSString *action = row[@"action"];
        if ([action isEqualToString:@"sbl-select-ios6"]) {
            [self selectSnowBoardLiteIOS6Theme];
        } else if ([action isEqualToString:@"sbl-import-folder"]) {
            [self presentSnowBoardLiteFolderImporter];
        } else if ([action isEqualToString:@"sbl-import-archive"]) {
            [self presentSnowBoardLiteArchiveImporter];
        } else if ([action isEqualToString:@"sbl-clear"]) {
            [self clearSnowBoardLiteTheme];
        }
        return;
    }

    if (indexPath.section == SectionLiveWP) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if (![row[@"kind"] isEqualToString:@"button"]) return;
        NSString *action = row[@"action"];
        if ([action isEqualToString:@"livewp-select-video"]) {
            [self presentLiveWPVideoPicker];
        } else if ([action isEqualToString:@"livewp-clear"]) {
            [self clearLiveWPVideo];
        }
        return;
    }

    if (indexPath.section == SectionPasscodeTheme) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if (![row[@"kind"] isEqualToString:@"button"]) return;
        NSString *action = row[@"action"];
        if ([action isEqualToString:@"passcode-import"]) {
            [self presentPasscodeThemeImporter];
        } else if ([action isEqualToString:@"passcode-apply"]) {
            [self runPasscodeThemeApply:YES];
        } else if ([action isEqualToString:@"passcode-restore"]) {
            [self runPasscodeThemeApply:NO];
        } else if ([action isEqualToString:@"passcode-clear"]) {
            [self clearPasscodeTheme];
        } else if ([action isEqualToString:@"passcode-export-backups"]) {
            [self presentPasscodeBackupExporter];
        } else if ([action isEqualToString:@"passcode-import-backups"]) {
            [self presentPasscodeBackupImporter];
        }
        return;
    }

    if (indexPath.section == SectionQuickLoader) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if (![row[@"kind"] isEqualToString:@"button"]) return;

        NSString *action = row[@"action"];
        if ([action isEqualToString:@"quickloader-run-js"]) {
            // Opens the iOS Files App Picker to select a JS file
            NSArray *types = @[UTTypeJavaScript.identifier, UTTypePlainText.identifier];
            UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:types inMode:UIDocumentPickerModeImport];
            // No mode of its own: the callback recognises this picker by the
            // selected file's extension (js / txt).
            settings_set_picker_mode(dp, nil);
            dp.delegate = self;
            [self presentViewController:dp animated:YES completion:nil];
            return;
        } else if ([action isEqualToString:@"quickloader-open-sources"]) {
            [self selectBottomTabNamed:@"Sources"];
            return;
        } else if ([action isEqualToString:@"quickloader-clear"]) {
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            [d removeObjectForKey:@"QuickLoaderSourceScriptName"];
            [d removeObjectForKey:@"QuickLoaderSourceRawJS"];
            [d removeObjectForKey:@"QuickLoaderSourceValues"];
            [d removeObjectForKey:@"QuickLoaderSourceRepoURL"];
            [d removeObjectForKey:@"QuickLoaderSourceTweakID"];
            [d removeObjectForKey:@"QuickLoaderSavedJS"];
            [d setBool:NO forKey:kSettingsQuickLoaderEnabled];
            [d synchronize];
            self.qlScriptName = nil;
            self.qlRawScript = nil;
            self.qlParams = nil;
            self.qlValues = nil;
            [self.tableView reloadData];
            [[NSNotificationCenter defaultCenter] postNotificationName:PackageQueueDidChangeNotification object:nil];
            return;
        } else if ([action isEqualToString:@"quickloader-run-now"]) {
            [self applyQuickLoaderScript];
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            [d setBool:YES forKey:kSettingsQuickLoaderEnabled];
            settings_mark_tweak_needs_apply(kSettingsQuickLoaderEnabled);
            [d synchronize];
            settings_run_pending_actions();
            [self.tableView reloadData];
            return;
        } else if ([action isEqualToString:@"quickloader-apply-dynamic"]) {
            [self applyQuickLoaderScript];
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            [d setBool:YES forKey:kSettingsQuickLoaderEnabled];
            settings_mark_tweak_needs_apply(kSettingsQuickLoaderEnabled);
            [d synchronize];
            [self.tableView reloadData];
            [[NSNotificationCenter defaultCenter] postNotificationName:PackageQueueDidChangeNotification object:nil];
            return;
        }
        return;
    }



    if (indexPath.section == SectionRepoTweaks) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if (![row[@"kind"] isEqualToString:@"button"]) return;

        NSString *action = row[@"action"];

        if ([action isEqualToString:@"repotweaks-open-manager"]) {
            [self selectBottomTabNamed:@"Sources"];
        }
        return;
    }


    if (indexPath.section == SectionThemer) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if (![row[@"kind"] isEqualToString:@"button"]) return;
        NSString *action = row[@"action"];
        if ([action isEqualToString:@"themer-select-ios6"]) {
            [self selectBuiltInIOS6Theme];
        } else if ([action isEqualToString:@"themer-import"]) {
            [self presentThemerImporter];
        } else if ([action isEqualToString:@"themer-guide"]) {
            [self presentThemerFormatGuide];
        } else if ([action isEqualToString:@"themer-clear"]) {
            [self clearSelectedTheme];
        }
        return;
    }

    if (indexPath.section == SectionSBC) {
        NSDictionary *row = [self rowsForSection:indexPath.section][indexPath.row];
        if ([row[@"kind"] isEqualToString:@"button"]) {
            settings_reset_sbc_defaults();
            // In detail mode, SBC sits at table-view section 0.
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                          withRowAnimation:UITableViewRowAnimationNone];
        }
    }
}

- (NSArray<NSDictionary *> *)repoTweaksRows {
    return @[
        @{ @"kind": @"button", @"action": @"repotweaks-open-manager", @"title": @"📦 Open Sources Tab" }
    ];
}

@end
