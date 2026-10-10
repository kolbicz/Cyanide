//
//  Package.m
//  Cyanide
//

#import "Package.h"
#import "PackageQueue.h"
#import "../SettingsViewController.h"
#import "../LogTextView.h"
#import "../tweaks/QuickLoader.h"
#import "../tweaks/RepoTweaks.h"
#import <math.h>

@interface Package ()
@property (nonatomic, readwrite, copy) NSString *symbolName;
@property (nonatomic, readwrite, copy) NSString *author;
@end

@implementation Package

static NSString *PackageStringValue(NSDictionary *values, NSString *key, NSString *fallback)
{
    id value = [values isKindOfClass:NSDictionary.class] ? values[key] : nil;
    return [value isKindOfClass:NSString.class] ? (NSString *)value : (fallback ?: @"");
}

static BOOL PackageBoolValue(NSDictionary *values, NSString *key, BOOL fallback)
{
    NSString *raw = PackageStringValue(values, key, fallback ? @"true" : @"false").lowercaseString;
    if ([raw isEqualToString:@"true"] || [raw isEqualToString:@"yes"] || [raw isEqualToString:@"1"]) return YES;
    if ([raw isEqualToString:@"false"] || [raw isEqualToString:@"no"] || [raw isEqualToString:@"0"]) return NO;
    return fallback;
}

static NSInteger PackageIntegerValue(NSDictionary *values, NSString *key, NSInteger fallback, NSInteger minValue, NSInteger maxValue)
{
    NSString *raw = PackageStringValue(values, key, @"");
    NSInteger n = raw.length ? (NSInteger)llround(raw.doubleValue) : fallback;
    if (n < minValue) n = minValue;
    if (n > maxValue) n = maxValue;
    return n;
}

static BOOL PackageRepoScriptRequiresNativeBridge(NSString *rawScript)
{
    if (![rawScript isKindOfClass:NSString.class] || rawScript.length == 0) return NO;
    return [rawScript containsString:@"nativeCallBuff"] ||
           [rawScript containsString:@"runOnMainEvaluate"] ||
           [rawScript containsString:@"Native.callSymbol"];
}

- (instancetype)initWithIdentifier:(NSString *)identifier
                              name:(NSString *)name
                  shortDescription:(NSString *)shortDescription
                   longDescription:(NSString *)longDescription
                           version:(NSString *)version
                            author:(NSString *)author
                          category:(NSString *)category
                        symbolName:(NSString *)symbolName
                              kind:(PackageInstallKind)kind
                        enabledKey:(NSString *)enabledKey
                             isNew:(BOOL)isNew
{
    if ((self = [super init])) {
        _identifier       = [identifier copy];
        _name             = [name copy];
        _shortDescription = [shortDescription copy];
        _longDescription  = [longDescription copy];
        _version          = [version copy];
        _author           = [author copy];
        _category         = [category copy];
        _symbolName       = [symbolName copy];
        _kind             = kind;
        _enabledKey       = [enabledKey copy];
        _isNew            = isNew;
        _settingsSection  = NSIntegerMax;
    }
    return self;
}

- (instancetype)initRepoTweakWithIdentifier:(NSString *)identifier
                                      name:(NSString *)name
                          shortDescription:(NSString *)shortDescription
                                   version:(NSString *)version
                                    author:(NSString *)author
                                  repoName:(NSString *)repoName
                                   repoURL:(NSString *)repoURL
                               repoTweakID:(NSString *)repoTweakID
                              repoScriptURL:(NSString *)repoScriptURL
{
    NSString *source = repoName.length ? repoName : @"Repo Source";
    NSString *longDescription = shortDescription.length > 0
        ? shortDescription
        : @"JavaScript tweak from a source.";

    if ((self = [self initWithIdentifier:identifier
                                    name:name.length ? name : repoTweakID
                        shortDescription:shortDescription.length ? shortDescription : @"JavaScript tweak from a source"
                         longDescription:longDescription
                                 version:version.length ? version : @"1.0"
                                  author:author.length ? author : source
                                category:@"JavaScript Tweaks"
                              symbolName:@"shippingbox.and.arrow.down.fill"
                                    kind:PackageInstallKindRepoTweak
                              enabledKey:nil
                                   isNew:NO])) {
        _repoName = [source copy];
        _repoURL = [repoURL copy];
        _repoTweakID = [repoTweakID copy];
        _repoScriptURL = [repoScriptURL copy];
    }
    return self;
}

- (NSString *)repoNativeEnabledKey
{
    if (self.kind != PackageInstallKindRepoTweak) return nil;
    if ([self.repoTweakID isEqualToString:@"lightsaber.sbcustomizer"]) return kSettingsSBCEnabled;
    if ([self.repoTweakID isEqualToString:@"lightsaber.statbar"]) return kSettingsStatBarEnabled;
    if ([self.repoTweakID isEqualToString:@"lightsaber.powercuff"]) return kSettingsPowercuffEnabled;
    return nil;
}

- (BOOL)repoTweakUsesQuickLoader
{
    return self.kind == PackageInstallKindRepoTweak && self.repoNativeEnabledKey.length == 0;
}

- (void)syncRepoTweakOptionsToNativeSettings
{
    if (self.kind != PackageInstallKindRepoTweak || self.repoNativeEnabledKey.length == 0) return;

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSDictionary *values = [d dictionaryForKey:repotweaks_values_defaults_key(self.repoURL, self.repoTweakID)] ?: @{};

    if ([self.repoTweakID isEqualToString:@"lightsaber.sbcustomizer"]) {
        [d setInteger:PackageIntegerValue(values, @"__sbc_dock_icons", 4, 4, 7)
               forKey:kSettingsSBCDockIcons];
        [d setInteger:PackageIntegerValue(values, @"__sbc_hs_cols", 4, 3, 7)
               forKey:kSettingsSBCCols];
        [d setInteger:PackageIntegerValue(values, @"__sbc_hs_rows", 6, 4, 8)
               forKey:kSettingsSBCRows];
        [d setBool:PackageBoolValue(values, @"__sbc_hide_labels", NO)
            forKey:kSettingsSBCHideLabels];
    } else if ([self.repoTweakID isEqualToString:@"lightsaber.statbar"]) {
        BOOL hideNet = PackageBoolValue(values, @"__sbc_statbar_hide_net", NO);
        [d setBool:PackageBoolValue(values, @"__sbc_statbar_celsius", NO)
            forKey:kSettingsStatBarCelsius];
        [d setBool:!hideNet forKey:kSettingsStatBarShowNet];
        [d setBool:YES forKey:kSettingsStatBarShowCPU];
        [d setBool:YES forKey:kSettingsStatBarShowLabels];
        [d setBool:NO forKey:kSettingsStatBarNetworkOnly];
    } else if ([self.repoTweakID isEqualToString:@"lightsaber.powercuff"]) {
        NSString *level = PackageStringValue(values, @"__powercuff_level", @"nominal").lowercaseString;
        NSSet<NSString *> *valid = [NSSet setWithArray:@[@"off", @"nominal", @"light", @"moderate", @"heavy"]];
        if (![valid containsObject:level]) level = @"nominal";
        [d setObject:level forKey:kSettingsPowercuffLevel];
    }

    [d synchronize];
}

- (BOOL)isInstalled
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    switch (self.kind) {
        case PackageInstallKindToggle:
            if (!self.enabledKey) return NO;
            if ([self.enabledKey isEqualToString:kSettingsDSDisableAppLibrary] &&
                NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17) {
                return NO;
            }
            if ([self.enabledKey isEqualToString:kSettingsQuickLoaderEnabled] &&
                quickloader_is_driven_by_repo_tweak()) return NO;
            return [d boolForKey:self.enabledKey];
        case PackageInstallKindNanoRegistry:
        case PackageInstallKindCallRecordingSound:
            // Manual-control packages: no persistent "installed" state from
            // the app's POV. The detail view shows an Apply/Remove menu and
            // each commit is a fresh one-shot run.
            return NO;
        case PackageInstallKindHideHomeBar:
            return settings_hide_home_bar_hidden();
        case PackageInstallKindDirectTool:
            return NO;
        case PackageInstallKindRepoTweak:
            if (self.repoNativeEnabledKey.length > 0) {
                return [d boolForKey:self.repoNativeEnabledKey];
            }
            return [d boolForKey:kSettingsQuickLoaderEnabled] &&
                   quickloader_is_repo_tweak_installed(self.repoURL, self.repoTweakID);
    }
}

- (BOOL)isQueuedForApply
{
    if (self.kind == PackageInstallKindRepoTweak) {
        if (self.repoNativeEnabledKey.length > 0) {
            return self.isInstalled && !settings_tweak_is_applied(self.repoNativeEnabledKey);
        }
        return self.isInstalled && !settings_tweak_is_applied(kSettingsQuickLoaderEnabled);
    }
    if (self.kind != PackageInstallKindToggle || !self.enabledKey) return NO;
    if ([self.enabledKey isEqualToString:kSettingsQuickLoaderEnabled] &&
        quickloader_is_driven_by_repo_tweak()) {
        return NO;
    }
    if (self.isInstallDisabled) return NO;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    return [d boolForKey:self.enabledKey] && !settings_tweak_is_applied(self.enabledKey);
}

- (BOOL)isInstallDisabled
{
    if (self.installDisabledReason.length > 0) return YES;
    if (self.experimental) {
        BOOL experimentalOn = [[NSUserDefaults standardUserDefaults] boolForKey:kSettingsExperimentalTweaksEnabled];
        if (!experimentalOn) return YES;
    }
    if (self.creatorOnly) return YES;
    return NO;
}

- (void)install   { [[PackageQueue sharedQueue] toggleForPackage:self]; }
- (void)uninstall { [[PackageQueue sharedQueue] toggleForPackage:self]; }

// Called by PackageQueue.commit — writes the persisted state without
// triggering settings_run_actions itself (the queue does that once).
- (BOOL)applyCommittedState:(BOOL)installed
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    switch (self.kind) {
        case PackageInstallKindToggle:
            if (self.enabledKey) {
                [d setBool:installed forKey:self.enabledKey];
                [d synchronize];
            }
            return YES;
        case PackageInstallKindNanoRegistry:
            if (settings_apply_nano_registry_now(installed)) {
                log_user("[INSTALLER] Watch pairing override %s.\n",
                         installed ? "applied" : "removed");
                return YES;
            }
            log_user("[INSTALLER] Watch pairing override %s failed; state was not changed.\n",
                     installed ? "apply" : "remove");
            return NO;
        case PackageInstallKindCallRecordingSound:
            if (settings_apply_call_recording_sound_disabled(installed)) {
                log_user("[INSTALLER] Call recording disclosure sound %s.\n",
                         installed ? "silenced" : "restored");
                return YES;
            }
            log_user("[INSTALLER] Call recording disclosure sound %s failed.\n",
                     installed ? "silence" : "restore");
            return NO;
        case PackageInstallKindHideHomeBar:
            if (settings_apply_hide_home_bar_hidden(installed)) {
                log_user("[INSTALLER] Home bar %s.\n",
                         installed ? "hidden; respring to apply" : "restore queued; respring to apply");
                return YES;
            }
            log_user("[INSTALLER] Home bar %s failed.\n",
                     installed ? "hide" : "restore");
            return NO;
        case PackageInstallKindDirectTool:
            return YES;
        case PackageInstallKindRepoTweak: {
            NSString *versionKey = repotweaks_installed_version_key(self.repoURL, self.repoTweakID);
            if (!installed) {
                [d removeObjectForKey:versionKey];
                [d synchronize];
            }

            NSString *nativeKey = self.repoNativeEnabledKey;
            if (nativeKey.length > 0) {
                if (quickloader_is_repo_tweak_installed(self.repoURL, self.repoTweakID)) {
                    quickloader_clear_repo_tweak_if_matches(self.repoURL, self.repoTweakID);
                    [d setBool:NO forKey:kSettingsQuickLoaderEnabled];
                }
                if (installed) {
                    [self syncRepoTweakOptionsToNativeSettings];
                    [d setBool:YES forKey:nativeKey];
                    [d setObject:(self.version ?: @"") forKey:versionKey];
                    settings_mark_tweak_needs_apply(nativeKey);
                    [d synchronize];
                    log_user("[INSTALLER] Native repo package install prepared: %s\n", self.name.UTF8String);
                } else {
                    [d setBool:NO forKey:nativeKey];
                    [d synchronize];
                    log_user("[INSTALLER] Native repo package removal prepared: %s\n", self.name.UTF8String);
                }
                return YES;
            }

            if (!installed) {
                BOOL wasCurrent = quickloader_is_repo_tweak_installed(self.repoURL, self.repoTweakID);
                quickloader_clear_repo_tweak_if_matches(self.repoURL, self.repoTweakID);
                if (wasCurrent) {
                    [d setBool:NO forKey:kSettingsQuickLoaderEnabled];
                    [d synchronize];
                    log_user("[INSTALLER] Removed QuickLoader repo tweak: %s\n", self.name.UTF8String);
                }
                return YES;
            }

            NSString *downloadMessage = nil;
            if (!repotweaks_download_script_sync(self.repoURL,
                                                 self.repoTweakID,
                                                 self.repoScriptURL,
                                                 25.0,
                                                 &downloadMessage)) {
                log_user("[INSTALLER] Cannot install %s: %s Refresh the source and try again.\n",
                         self.name.UTF8String,
                         (downloadMessage ?: @"could not fetch the latest cache-busted script.").UTF8String);
                return NO;
            }

            NSString *rawScript = [d stringForKey:repotweaks_script_defaults_key(self.repoURL, self.repoTweakID)];
            if (rawScript.length == 0) {
                log_user("[INSTALLER] Cannot install %s: script is missing. Refresh its source first.\n",
                         self.name.UTF8String);
                return NO;
            }
            if (PackageRepoScriptRequiresNativeBridge(rawScript)) {
                log_user("[INSTALLER] Cannot install %s through QuickLoader: this repo script needs a native injection backend.\n",
                         self.name.UTF8String);
                return NO;
            }

            NSDictionary *values = [d dictionaryForKey:repotweaks_values_defaults_key(self.repoURL, self.repoTweakID)] ?: @{};
            if (quickloader_save_repo_tweak(self.repoURL, self.repoTweakID, self.name, rawScript, values)) {
                [d setBool:YES forKey:kSettingsQuickLoaderEnabled];
                [d setBool:NO forKey:kSettingsRepoTweaksEnabled];
                [d setBool:NO forKey:repotweaks_enabled_defaults_key(self.repoURL, self.repoTweakID)];
                [d setObject:(self.version ?: @"") forKey:versionKey];
                settings_mark_tweak_needs_apply(kSettingsQuickLoaderEnabled);
                [d synchronize];
                log_user("[INSTALLER] Pending QuickLoader install prepared: %s\n", self.name.UTF8String);
                return YES;
            }
            log_user("[INSTALLER] Failed to prepare QuickLoader script for %s.\n", self.name.UTF8String);
            return NO;
        }
    }
    return YES;
}

@end
