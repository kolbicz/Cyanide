//
//  PackageCatalog.m
//  Cyanide
//

#import "PackageCatalog.h"
#import "../SettingsViewController.h"
#import "../tweaks/RepoTweaks.h"
#import "../tweaks/experimental_tweaks.h"

@interface Package ()
@property (nonatomic, readwrite, copy) NSString *symbolName;
@property (nonatomic, readwrite, copy) NSString *author;
@end

@implementation PackageCatalog

static NSString *catalog_string_or_empty(id value)
{
    return [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
}

static NSArray<NSString *> *catalog_repotweaks_urls(NSUserDefaults *d)
{
    id raw = [d objectForKey:@"RepoTweaksURLs"];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    for (id value in (NSArray *)raw) {
        if ([value isKindOfClass:NSString.class]) [urls addObject:value];
    }
    return urls;
}

static NSDictionary *catalog_repotweaks_caches(NSUserDefaults *d)
{
    id raw = [d objectForKey:@"RepoTweaksCaches"];
    return [raw isKindOfClass:NSDictionary.class] ? (NSDictionary *)raw : @{};
}

static BOOL catalog_repo_script_requires_native_bridge(NSString *rawScript)
{
    if (![rawScript isKindOfClass:NSString.class] || rawScript.length == 0) return NO;
    return [rawScript containsString:@"nativeCallBuff"] ||
           [rawScript containsString:@"runOnMainEvaluate"] ||
           [rawScript containsString:@"Native.callSymbol"];
}

+ (NSArray<Package *> *)repoPackages
{
    if (!repotweaks_sources_enabled()) return @[];
    repotweaks_seed_default_repos();

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSDictionary *caches = catalog_repotweaks_caches(d);
    NSMutableArray<Package *> *packages = [NSMutableArray array];

    for (NSString *url in catalog_repotweaks_urls(d)) {
        id repoRaw = caches[url];
        if (![repoRaw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *repo = (NSDictionary *)repoRaw;
        NSString *repoName = catalog_string_or_empty(repo[@"repoName"]);
        NSString *author = catalog_string_or_empty(repo[@"author"]);
        id tweaksRaw = repo[@"tweaks"];
        if (![tweaksRaw isKindOfClass:NSArray.class]) continue;

        for (id tweakRaw in (NSArray *)tweaksRaw) {
            if (![tweakRaw isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *tweak = (NSDictionary *)tweakRaw;
            NSString *tweakID = catalog_string_or_empty(tweak[@"id"]);
            NSString *name = catalog_string_or_empty(tweak[@"name"]);
            NSString *scriptURL = catalog_string_or_empty(tweak[@"scriptURL"]);
            if (tweakID.length == 0 || name.length == 0 || scriptURL.length == 0) continue;

            NSString *identifier = [NSString stringWithFormat:@"repo.%@", repotweaks_storage_key(url, tweakID)];
            Package *pkg = [[Package alloc] initRepoTweakWithIdentifier:identifier
                                                                   name:name
                                                       shortDescription:catalog_string_or_empty(tweak[@"description"])
                                                                version:catalog_string_or_empty(tweak[@"version"])
                                                                 author:author
                                                               repoName:repoName
                                                                repoURL:url
                                                            repoTweakID:tweakID
                                                           repoScriptURL:scriptURL];
            NSString *symbol = catalog_string_or_empty(tweak[@"symbol"]);
            if (symbol.length > 0) pkg.symbolName = symbol;
            NSString *tweakAuthor = catalog_string_or_empty(tweak[@"author"]);
            if (tweakAuthor.length > 0) pkg.author = tweakAuthor;
            NSString *rawScript = [d stringForKey:repotweaks_script_defaults_key(url, tweakID)];
            NSString *unsupportedReason = repotweaks_unsupported_reason(tweak);
            if (unsupportedReason.length > 0) {
                pkg.installDisabledReason = unsupportedReason;
                pkg.unstableWarning = unsupportedReason;
            } else if (rawScript.length == 0) {
                pkg.installDisabledReason = @"Refresh this source from the Sources tab before installing.";
            } else if (pkg.repoTweakUsesQuickLoader && catalog_repo_script_requires_native_bridge(rawScript)) {
                pkg.installDisabledReason = @"This repo tweak needs a dedicated Cyanide native backend before it can install.";
            }
            [packages addObject:pkg];
        }
    }

    return [packages sortedArrayUsingComparator:^NSComparisonResult(Package *a, Package *b) {
        return [a.name caseInsensitiveCompare:b.name];
    }];
}

// Underlying section indices for the detail-mode SettingsViewController push.
// Defined directly from the shared SettingsSection enum (SettingsViewController.h)
// so they track the enum automatically — the previous hand-copied numbers had
// drifted (e.g. kSecLayoutExtras was 15 = SectionSnowBoardLite, so "Customize
// Home Layout Extras" opened the theme selector).
static const NSInteger kSecSBC              = SectionSBC;
static const NSInteger kSecStatBar          = SectionStatBar;
static const NSInteger kSecNSBar            = SectionNSBar;
static const NSInteger kSecNiceBarLite      = SectionNiceBarLite;
static const NSInteger kSecPowercuff        = SectionPowercuff;
static const NSInteger kSecDragCoefficient  = SectionDragCoefficient;
static const NSInteger kSecLayoutExtras     = SectionLayoutExtras;
static const NSInteger kSecNanoRegistry     = SectionNanoRegistry;
static const NSInteger kSecSnowBoardLite    = SectionSnowBoardLite;
static const NSInteger kSecLiveWP           = SectionLiveWP;
static const NSInteger kSecLocationSim      = SectionLocationSim;
static const NSInteger kSecGravityLite      = SectionGravityLite;
static const NSInteger kSecAppSwitcherGrid  = SectionAppSwitcherGrid;
static const NSInteger kSecFastLockXLite    = SectionFastLockXLite;
static const NSInteger kSecQuickLoader      = SectionQuickLoader;
static const NSInteger kSecRepoTweaks       = SectionRepoTweaks;
static const NSInteger kSecLockScreenDuration = SectionLockScreenDuration;
static const NSInteger kSecPasscodeTheme    = SectionPasscodeTheme;
static const NSInteger kSecOTA              = SectionOTA;

+ (NSArray<Package *> *)allPackages
{
    NSArray<Package *> *full = [self allPackagesIncludingExperimental];
    BOOL experimentalOn = [[NSUserDefaults standardUserDefaults]
                            boolForKey:kSettingsExperimentalTweaksEnabled];

    NSMutableArray<Package *> *out = [NSMutableArray arrayWithCapacity:full.count];
    for (Package *p in full) {
        if (p.creatorOnly) continue;
        if (p.experimental && !experimentalOn) continue;
        [out addObject:p];
    }
    return out;
}

+ (NSArray<Package *> *)allPackagesIncludingExperimental
{
    static NSArray<Package *> *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *version = @"1.0";
        Package *statBar = [[Package alloc] initWithIdentifier:@"com.darksword.statbar"
                                           name:@"StatBar"
                               shortDescription:@"Battery temperature + free RAM overlay"
                                longDescription:@"Installs an overlay window in SpringBoard that shows live battery temperature and free RAM next to the system status bar. Refresh timing is adjustable so you can trade live updates for battery life.\n\nConfigure units, visible metrics, and refresh speed in the Settings tab."
                                        version:version
                                         author:@"zeroxjf"
                                       category:@"Status Bar"
                                     symbolName:@"thermometer.medium"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsStatBarEnabled
                                          isNew:NO];
        statBar.settingsSection = kSecStatBar;

        Package *nsBar = [[Package alloc] initWithIdentifier:@"com.darksword.nsbar"
                                           name:@"NSBar"
                               shortDescription:@"Network speed overlay in the status bar"
                                longDescription:@"Displays real-time download and upload speed in a compact SpringBoard status-bar overlay. Pick its corner or center position in Settings.\n\nPorted from d1y/cyanide-ios."
                                        version:version
                                         author:@"d1y"
                                       category:@"Status Bar"
                                     symbolName:@"network"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsNSBarEnabled
                                          isNew:NO];
        nsBar.settingsSection = kSecNSBar;

        Package *niceBarLite = [[Package alloc] initWithIdentifier:@"com.darksword.nicebarlite"
                                           name:@"NiceBar Lite"
                               shortDescription:@"NiceBar-style status labels"
                                longDescription:@"Adds configurable text labels around the status bar. Slots can show custom text, date/time formats, and system values such as battery, memory, network speed, uptime, IP address, disk space, thermal state, and traffic counters.\n\nPorted from d1y/cyanide-ios."
                                        version:version
                                         author:@"d1y"
                                       category:@"Status Bar"
                                     symbolName:@"textformat.size"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsNiceBarLiteEnabled
                                          isNew:NO];
        niceBarLite.settingsSection = kSecNiceBarLite;

#if CYANIDE_EXPERIMENTAL_TWEAKS_AVAILABLE
#endif

        Package *sbc = [[Package alloc] initWithIdentifier:@"com.darksword.sbcustomizer"
                                           name:@"SBCustomizer"
                               shortDescription:@"Custom dock, grid, app placement, and page counts"
                                longDescription:@"Customizes the dock icon count and the home screen icon grid (columns and rows). It can move a selected app into a newly available Dock slot, optionally hide icon labels, and apply separate icon capacities to the first and remaining Home Screen pages.\n\nThe Watusi WhatsApp duplicate is selected by default for the optional Dock move; enter another app's bundle identifier in Settings to change it."
                                        version:@"1.1"
                                         author:@"zeroxjf / Kolbicz"
                                       category:@"Home Screen"
                                     symbolName:@"square.grid.3x3.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsSBCEnabled
                                          isNew:NO];
        sbc.settingsSection = kSecSBC;

        Package *powercuff = [[Package alloc] initWithIdentifier:@"com.darksword.powercuff"
                                           name:@"Powercuff"
                               shortDescription:@"Underclock the CPU/GPU thermal pressure"
                                longDescription:@"Drives thermalmonitord with synthetic thermal pressure to underclock the CPU and GPU. Useful for cooling-sensitive workloads or extending runtime under load. Effects persist until reboot.\n\nNominal is the daily-use default. Light, Moderate, and Heavy intentionally underclock the CPU more, so lag and slower app launches mean it is working as intended. Those levels can be too slow for comfortable day-to-day use, especially on older devices.\n\nPick a level in the Settings tab."
                                        version:version
                                         author:@"rpetrich"
                                       category:@"System"
                                     symbolName:@"bolt.slash.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsPowercuffEnabled
                                          isNew:NO];
        powercuff.settingsSection = kSecPowercuff;

        Package *axon = [[Package alloc] initWithIdentifier:@"com.darksword.axonlite"
                                           name:@"Axon Lite"
                               shortDescription:@"Group Notification Center requests by app"
                                longDescription:@"Groups visible Notification Center requests by app in a SpringBoard overlay and filters duplicates while Cyanide keeps the RemoteCall session alive.\n\nNo extra configuration."
                                        version:version
                                         author:@"zeroxjf"
                                       category:@"SpringBoard"
                                     symbolName:@"bell.badge.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsAxonLiteEnabled
                                          isNew:NO];
        axon.unstableWarning = @"⚠️ Experimental: work-in-progress. Expect SpringBoard crashes, dropped notifications, layout glitches, and breakage between Cyanide builds. Don't rely on it for anything important.";

#if CYANIDE_EXPERIMENTAL_TWEAKS_AVAILABLE



        Package *stageStrip = [[Package alloc] initWithIdentifier:@"com.darksword.stagestrip"
                                           name:@"Dynamic Stage Lite"
                               shortDescription:@"Two floating app windows, iPad-style"
                                longDescription:
            @"Run two apps as floating, resizable windows on top of SpringBoard.\n\n"
            @"Based on Dynamic Stage by tomt000 — the original Stage Manager-for-iPhone tweak. Dynamic Stage Lite is an independent, RemoteCall-only re-implementation of the split-view + scene-hosting design; no original tweak code or assets are reused. Go check out tomt000's full version on Havoc.\n\n"
            @"How to use:\n"
            @"• Tap the dot in the bottom-right corner of the screen to open the picker.\n"
            @"• Tap two apps to launch them side-by-side.\n"
            @"• Drag the top bar to move; drag any corner to resize.\n"
            @"• X in the top-left of a window closes it.\n"
            @"• Gear in the picker tray jumps back to Cyanide settings.\n\n"
            @"First Run is slow. The picker has to enumerate every installed app over RemoteCall and build a tile per app — expect 1-2 minutes on a fresh install. Re-Runs reuse the cache and are fast.\n\n"
            @"Rough edges:\n"
            @"• Touch routing into hosted apps isn't wired — windows are for viewing/switching, not scrolling or typing.\n"
            @"• Auto-close on full-screen launch is not yet hooked up; close manually with the X.\n"
            @"• Gestures may stutter while the App Library is still filling in."
                                        version:version
                                         author:@"zeroxjf"
                                       category:@"Beta"
                                     symbolName:@"sidebar.left"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsStageStripEnabled
                                          isNew:NO];
        stageStrip.unstableWarning = @"Beta / unstable: First Run takes 1-2 minutes because the picker enumerates every installed app and builds a tile per app. Re-Runs are fast. Touch routing into hosted windows isn't wired yet, so scrolling/typing inside a floating window may not work.";
#endif

        Package *locationSim = [[Package alloc] initWithIdentifier:@"com.darksword.locationsim"
                                           name:@"Location Simulator"
                               shortDescription:@"CoreLocation static point simulation"
                                longDescription:@"Spoofs the device's GPS location via Apple's CLSimulationManager. Requires Apple Maps installed and set up — Maps is the RemoteCall host process that drives the simulation.\n\nThis is a manual tool, not an installable package. Open Controls, choose a target, then use Simulate Current Target or Restore Real Location. Each run opens the activity log and marks completion when the request returns. Reset may take a few minutes and may require a reboot plus extra wait time.\n\nSettings exposes the current target plus altitude and accuracy. v1 is static-point only; route playback and alternate daemon hosts are next.\n\nNot all apps respect the simulated location. Apps that use their own location validation or additional signals may ignore it.\n\nCredits: kolbicz provided the GPS spoofer RemoteCall/CLSimulationManager prototype this is based on. ezzuldinSt's LSpoof provided the app-side CLLocationManager spoofing, picker, bookmarks, and route-simulation reference.\n\nSystem-behavior warning: simulated locations can affect more than maps. Features tied to location, including time zone, date/time behavior, weather, automation, reminders, and service checks, may behave unexpectedly. Only use this if you know what you're doing.\n\nLegal and service-use note: simulated locations may violate app terms, platform rules, game rules, ride-share or delivery policies, or local law depending on how they are used. Use only where you have permission. You are responsible for your use and apply or restore this tweak at your own risk."
                                        version:version
                                         author:@"zeroxjf, kolbicz, ezzuldinSt"
                                       category:@"System"
                                     symbolName:@"location.fill"
                                           kind:PackageInstallKindDirectTool
                                     enabledKey:nil
                                          isNew:NO];
        locationSim.settingsSection = kSecLocationSim;
        locationSim.experimental = NO;
        locationSim.unstableWarning = @"Beta: requires Apple Maps installed and set up. Changes CoreLocation's active simulation state — may affect time zone, date/time, and other location-tied behavior. Some apps and services prohibit or detect simulated locations. Only use this if you know what you're doing.";

        Package *snowboardLite = [[Package alloc] initWithIdentifier:@"com.darksword.snowboardlite"
                                           name:@"SnowBoard Lite"
                               shortDescription:@"Local SnowBoard-style icon themes"
                                longDescription:@"Imports SnowBoard/IconBundles themes into a local library and applies the selected theme through Cyanide's icon replacement pipeline. Supports the bundled iOS 6 theme and local folder imports.\n\nSnowBoard Lite is the main icon-theme entry point in Cyanide.\n\nPorted from d1y/cyanide-ios."
                                        version:version
                                         author:@"d1y"
                                       category:@"Theming"
                                     symbolName:@"square.stack.3d.up.fill"
                                          kind:PackageInstallKindToggle
                                     enabledKey:kSettingsSnowBoardLiteEnabled
                                          isNew:NO];
        snowboardLite.settingsSection = kSecSnowBoardLite;
        snowboardLite.unstableWarning = @"Preview: import or select a SnowBoard Lite theme before applying.";

        Package *liveWP = [[Package alloc] initWithIdentifier:@"com.darksword.livewp"
                                           name:@"LiveWP"
                               shortDescription:@"Video wallpaper for Home and Lock Screen"
                                longDescription:@"Plays a selected MP4/MOV/M4V video behind SpringBoard's home and lock screen windows while Cyanide keeps the RemoteCall session alive.\n\nPorted from d1y/cyanide-ios."
                                        version:version
                                         author:@"d1y"
                                       category:@"Theming"
                                     symbolName:@"play.rectangle.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsLiveWPEnabled
                                          isNew:NO];
        liveWP.settingsSection = kSecLiveWP;

        Package *layoutExtras = [[Package alloc] initWithIdentifier:@"com.darksword.layoutextras"
                                           name:@"Home Layout Extras"
                               shortDescription:@"Extra home/dock padding and per-icon scaling"
                                longDescription:@"Adds extra padding around the home grid and the dock, and scales icons up or down. Stacks on top of SBCustomizer.\n\nDial in left/right/top/bottom padding for the home screen, horizontal padding for the dock, and home/dock icon scale in the Settings tab. Defaults match stock (zero padding, 100% scale).\n\nApplied at Run; not persisted across respring.\n\niOS 18: mutates the SBIconController layout configuration directly (upstream kolbicz path).\niOS 26: walks the live SBIconListView/SBIconView hierarchy and adjusts frames + iconImageInfo per icon (the iOS 26 layout class is read-only). One-shot at Run on iOS 26 — rotation/page swipe may force iOS 26's auto-layout to re-fit, so re-Run if that happens."
                                        version:version
                                         author:@"kolbicz"
                                      category:@"Home Screen"
                                     symbolName:@"square.dashed.inset.filled"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsLayoutExtrasEnabled
                                          isNew:NO];
        layoutExtras.settingsSection = kSecLayoutExtras;
        NSInteger iosMajor = [[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
        if (iosMajor >= 26) {
            layoutExtras.knownIssues = @[
                @"iOS 26: layout may reset after rotation or page swipe. Re-run to reapply.",
            ];
        }

        // Lock Screen Duration is a manual tool (DirectTool): it appears in the
        // tweak list with author/version, but instead of a queued install it
        // opens its own Settings section whose Apply / Remove / Read buttons
        // write the SBMinimumLockscreenIdleTime floor and offer a respring. Like
        // OTA Updates it is not part of the Run queue.
        Package *lockScreenDuration = [[Package alloc] initWithIdentifier:@"com.darksword.lockscreen-duration"
                                           name:@"Lock Screen Duration"
                               shortDescription:@"Keep the lock screen awake longer"
                                longDescription:@"Extends the lock screen's own dim-then-sleep timer — the short countdown that turns the screen off while you read notifications, separate from Settings > Auto-Lock.\n\nThis is a manual tool, not a queued package. Open Controls, set the number of seconds, then tap Apply Lock Screen Duration. It writes the SpringBoard preference SBMinimumLockscreenIdleTime (a global floor applied to every lock-screen idle state, including after Face ID) and offers a respring to apply it. The value persists across respring and reboot. Use Remove to restore stock timing, or Read Current Value to see what is configured.\n\nMechanism: -[SBIdleTimerDescriptorFactory sanitizeDescriptorForLockscreenDefaults:] floors every lock-screen interval with max(interval, minimumLockscreenIdleTime). Face ID gaze (Attention Aware) can keep the screen on even longer.\n\nRun the chain at least once first so kernel access is active. Takes effect on the next respring."
                                        version:@"1.0"
                                         author:@"kolbicz"
                                       category:@"SpringBoard"
                                     symbolName:@"lock.rectangle.on.rectangle"
                                           kind:PackageInstallKindDirectTool
                                     enabledKey:nil
                                          isNew:YES];
        lockScreenDuration.settingsSection = kSecLockScreenDuration;

        Package *gravityLite = [[Package alloc] initWithIdentifier:@"com.darksword.gravitylite"
                                           name:@"Gravity Lite"
                               shortDescription:@"Make home-screen icons fall with physics"
                                longDescription:@"Core RemoteCall-only port of Julio Verne's classic Gravity tweak for iOS 26. Applies UIDynamicAnimator gravity, collision bounds, bounce, friction, resistance, optional dock physics, accelerometer steering, shake pulses, restore, and an explosion pulse to the currently visible SpringBoard icon views.\n\nThis is not a full Substrate-style port. Activator/Home-button hooks, drag gestures, and preference-daemon notifications are intentionally left out. Use Settings to tune the core physics and the Restore button to reset the layout."
                                        version:version
                                         author:@"Julio Verne / zeroxjf"
                                       category:@"Home Screen"
                                     symbolName:@"arrow.down.circle.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsGravityLiteEnabled
                                          isNew:NO];
        gravityLite.settingsSection = kSecGravityLite;
        gravityLite.unstableWarning = @"Beta: RemoteCall-only physics can be reset by SpringBoard relayouts such as page swipes, rotations, folder transitions, or resprings. Use Restore Icon Layout if icons stay displaced.";
        gravityLite.knownIssues = @[
            @"To disable, use the App Switcher to return to Cyanide and deactivate Gravity Lite. There is no other way to stop it right now.",
            @"Touch input does not register on displaced icons yet. Forwarding taps in this environment is a major WIP.",
            @"Install is slow as hell. WIP. Cyanide has to capture every visible icon and widget before physics start.",
            @"Page swipes, folder opens, or SpringBoard relayouts may stop the effect. Run Gravity again.",
        ];

        Package *appSwitcherGrid = [[Package alloc] initWithIdentifier:@"com.darksword.appswitchergrid"
                                           name:@"App Switcher Grid"
                               shortDescription:@"Grid-style app switcher"
                                longDescription:@"Applies a runtime SpringBoard method patch that makes the app switcher use grid/deck style.\n\nThis does not write system files. A respring restores the stock app switcher. If you respring after Hide Home Bar, run App Switcher Grid again because respring resets this live SpringBoard patch.\n\nPorted from d1y/cyanide-ios."
                                        version:version
                                         author:@"rooootdev"
                                       category:@"SpringBoard"
                                     symbolName:@"square.grid.2x2.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsAppSwitcherGridEnabled
                                          isNew:NO];
        appSwitcherGrid.settingsSection = kSecAppSwitcherGrid;
        appSwitcherGrid.unstableWarning = @"Beta: patches SpringBoard runtime methods in memory. Respring restores stock, but unsupported builds may glitch the app switcher or crash SpringBoard. Re-run after any respring.";

        Package *quickLoader = [[Package alloc] initWithIdentifier:@"com.darksword.quickloader"
                                           name:@"QuickLoader"
                               shortDescription:@"Executes custom .js code"
                                longDescription:@"Select a local JavaScript file from Files, configure any declared parameters, and run it through Cyanide's SpringBoard RemoteCall bridge.\n\nOnly run scripts you trust. JavaScript tweaks can send private SpringBoard messages and destabilize the device if the script is buggy."
                                        version:@"1.0"
                                         author:@"Iggy05"
                                       category:@"SpringBoard"
                                     symbolName:@"bolt.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsQuickLoaderEnabled
                                          isNew:NO];
        quickLoader.settingsSection = kSecQuickLoader;
        quickLoader.unstableWarning = @"Runs user-selected JavaScript with access to Cyanide's RemoteCall helpers. Only use scripts you trust; bad scripts can crash SpringBoard.";

#if CYANIDE_EXPERIMENTAL_TWEAKS_AVAILABLE
        Package *fastLockXLite = [[Package alloc] initWithIdentifier:@"com.darksword.fastlockx-lite"
                                           name:@"FastLockX Lite"
                               shortDescription:@"Face ID retry + unlock controls"
                                longDescription:@"RemoteCall-only port of the usable FastLockX primitives recovered from the iOS 15 tweak by Artem Kasper.\n\nCredits: original FastLockX by Artem Kasper; Cyanide FastLockX Lite port by zeroxjf.\n\nIt can pulse SpringBoard's biometric retry path, ask the iOS 26 biometric coordinator to start a Mesa/Face ID unlock, and send the original Lock Screen unlock request as a fallback. Installing it through Apply Tweaks keeps those retry/unlock requests armed with SpringBoard timers so pickup-to-unlock can work after Cyanide closes. The pulse loop pauses again after unlock.\n\nUse Disable, Clean Up, or a respring to stop the timers."
                                        version:version
                                         author:@"Artem Kasper / zeroxjf"
                                       category:@"Beta"
                                     symbolName:@"lock.open.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsFastLockXLiteEnabled
                                          isNew:NO];
        fastLockXLite.settingsSection = kSecFastLockXLite;
        fastLockXLite.unstableWarning = @"Beta / unstable: sends private SpringBoard lock-screen and biometric-resource messages. Always On runs SpringBoard timers while the device is locked, so disable it or respring if Face ID feels noisy or unstable.";
#endif

        Package *nanoRegistry = [[Package alloc] initWithIdentifier:@"com.darksword.nanoregistry"
                                           name:@"Watch Pairing Override"
                               shortDescription:@"Pair a newer watch or revive an older one"
                                longDescription:@"Changes the watchOS pairing range saved on this iPhone.\n\nMost people should use watchOS Range 99/23/10/6 in Settings, then apply the override. These are pairing protocol generations, not Apple Watch model numbers. 99 raises the watchOS pairing ceiling. 23 keeps the generation-23 setup protocol accepted. 10 and 6 leave the legacy chip and multi-watch floors at their normal values.\n\nApple Watch Ultra 3 cannot pair on iOS versions below 26 at this time.\n\nSystem-file warning: this modifies the local NanoRegistry compatibility-index MobileAsset and saves a .cyanide.bak backup beside the original file. Pairing-asset edits can fail, partially apply, require a respring or reboot to settle, or leave pairing state inconsistent. You apply or remove this override at your own risk.\n\nRespring or reboot after installing or removing the override before trying to pair."
                                        version:version
                                         author:@"zeroxjf"
                                       category:@"System"
                                     symbolName:@"applewatch.radiowaves.left.and.right"
                                           kind:PackageInstallKindNanoRegistry
                                     enabledKey:nil
                                          isNew:NO];
        nanoRegistry.settingsSection = kSecNanoRegistry;
        nanoRegistry.unstableWarning = @"Warning: modifies a local NanoRegistry MobileAsset. Cyanide saves a .cyanide.bak backup beside the original, but system-file edits can fail or require a respring/reboot. Apply or remove this override at your own risk.";

        Package *callRecordingSound = [[Package alloc] initWithIdentifier:@"com.darksword.callrecording-sound"
                                           name:@"Call Recording Sound"
                               shortDescription:@"Silence disclosure start/stop sounds"
                                longDescription:@"Replaces the CallServices StartDisclosureWithTone and StopDisclosure audio files with Cyanide's bundled silent payloads.\n\nCredits: YangJiiii (@duongduong0908) for the EnsWilde and Disable Call Recording BookRestore reference tools. @Little_34306 is credited by the original projects for the Disable Call Recording concept. Cyanide port, KRW-backed implementation, and generated replacement silent audio assets by zeroxjf.\n\nSystem-file warning: this modifies files under /var/mobile/Library/CallServices/Greetings/default. Cyanide backs up the first originals into its app container, but system file replacement can fail, partially apply, or require a respring/reboot to settle.\n\nLegal note: call-recording disclosure sounds may exist to satisfy consent, notification, or privacy-law requirements in some places. You are responsible for understanding and following the laws that apply to you.\n\nThis port does not use the old Books/BookRestore/sparserestore path. Cyanide runs KRW, unlocks local /private/var write access, then writes directly to the CallServices files.\n\nUse Restore Original Sounds to write Cyanide's backups back when present. You apply or restore this tweak at your own risk."
                                        version:version
                                         author:@"YangJiiii (@duongduong0908) / zeroxjf"
                                       category:@"System"
                                     symbolName:@"speaker.slash.fill"
                                           kind:PackageInstallKindCallRecordingSound
                                     enabledKey:nil
                                          isNew:NO];
        callRecordingSound.experimental = NO;
        callRecordingSound.unstableWarning = @"Beta: persistent CallServices system-file replacement. Disclosure sounds may be legally required where you live; you are responsible for your use and apply this at your own risk. Use Restore Original Sounds before removing Cyanide if you want Cyanide's backups written back.";

        Package *passcodeTheme = [[Package alloc] initWithIdentifier:@"com.darksword.passcode-theme"
                                           name:@"Passcode Style"
                               shortDescription:@"Custom Lock Screen passcode artwork"
                                longDescription:@"Replaces the Lock Screen keypad artwork under /var/mobile/Library/Caches/TelephonyUI-* with a style you import or build in the Passcode Style panel. A style may cover only some digits; the rest stay stock.\n\nOpen Controls to apply it or restore the saved originals. Lock and unlock (or respring) to see the change.\n\nSystem-file warning: the originals Cyanide saves live in Cyanide's own app container, so reinstalling Cyanide deletes them — export them from the Passcode Style panel first if you plan to reinstall.\n\nCredits: ported from the Passcode implementation created for Lara by ruter and neonmodder123, inherited and extended by leonardob8777-bit in Eagle (https://github.com/leonardob8777-bit/Eagle, AGPL-3.0). Cyanide port by FleetingDreamso."
                                        version:version
                                         author:@"ruter / neonmodder123 / leonardob8777-bit / FleetingDreamso"
                                       category:@"Theming"
                                     symbolName:@"circle.grid.3x3.fill"
                                           kind:PackageInstallKindDirectTool
                                     enabledKey:nil
                                          isNew:YES];
        passcodeTheme.settingsSection = kSecPasscodeTheme;
        passcodeTheme.unstableWarning = @"Warning: rewrites the system keypad artwork the Lock Screen uses. Cyanide verifies every write, but edits can still fail or partially apply. Restore Original Digits puts the saved originals back.";

        Package *hideHomeBar = [[Package alloc] initWithIdentifier:@"com.darksword.hide-home-bar"
                                           name:@"Hide Home Bar"
                               shortDescription:@"Hide the bottom home indicator"
                                longDescription:@"Zeros the first page of /System/Library/PrivateFrameworks/MaterialKit.framework/Assets.car using Cyanide's stable file-page zero path, which hides the bottom home indicator after SpringBoard reloads assets.\n\nRun Hide Home Bar by itself, then respring so SpringBoard refreshes the asset cache. To bring the home indicator back, choose Restore Home Bar and respring again. Other live SpringBoard tweaks, such as App Switcher Grid, should be applied in a separate run after the respring.\n\nCredits: C4ndyF1sh/ZeroCalories for the Home Bar target and jailbreakdotparty/dirtyZero for the original page-zeroing idea. Cyanide port by zeroxjf."
                                        version:version
                                         author:@"C4ndyF1sh / jailbreakdotparty / zeroxjf"
                                       category:@"Home Screen"
                                     symbolName:@"line.3.horizontal"
                                           kind:PackageInstallKindHideHomeBar
                                     enabledKey:nil
                                          isNew:NO];
        hideHomeBar.unstableWarning = @"Beta: system asset page zeroing. Run by itself, then respring after hiding. To restore the home indicator, choose Restore Home Bar and respring.";

        // Manual tool (DirectTool), same shape as Lock Screen Duration: the
        // detail view offers Open Controls, which opens the OTA Updates
        // section in Settings where Disable / Enable / Read Current Status
        // act immediately. It was a queued Disable/Enable menu before, which
        // routed a one-tap system-file edit through the install queue for no
        // benefit and split the read button off into Settings on its own.
        Package *otaBlock = [[Package alloc] initWithIdentifier:@"com.darksword.ota-block"
                                           name:@"OTA Updates"
                               shortDescription:@"Enable or disable over-the-air system updates"
                                longDescription:@"Disables or enables the launchd jobs responsible for over-the-air system updates by editing disabled.plist. State persists across reboots.\n\nSystem-file warning: this edits /private/var/db/com.apple.xpc.launchd/disabled.plist. Incorrect or partial writes can affect launchd job state across boot. You disable or re-enable OTA updates at your own risk.\n\nThis is a manual tool, not a queued package. Open Controls, then tap Disable OTA Updates to block them or Enable OTA Updates to restore them; the change is written immediately, with no Run or Apply step. Read Current Status reports whether the update daemons are currently blocked.\n\nRun the chain at least once first so kernel access is active — Read Current Status will not start it on its own.\n\nVersion 1.2 moves the controls into Settings; 1.1 added Read Current Status."
                                        version:@"1.2"
                                         author:@"kolbicz"
                                       category:@"System"
                                     symbolName:@"icloud.slash.fill"
                                          kind:PackageInstallKindDirectTool
                                    enabledKey:nil
                                         isNew:NO];
        otaBlock.settingsSection = kSecOTA;
        otaBlock.unstableWarning = @"Warning: persistent system-file edit. This package modifies launchd disabled.plist to change OTA job state across reboot. Disable or re-enable OTA updates at your own risk.";

        Package *disableAppLibrary = [[Package alloc] initWithIdentifier:@"com.darksword.disable-app-library"
                                           name:@"Disable App Library"
                               shortDescription:@"Remove the App Library page"
                                longDescription:@"Removes the App Library page that sits past your last home-screen page. Swiping past the last page becomes a no-op.\n\nWorks on iOS 17 and later."
                                        version:@"1.1"
                                         author:@"kolbicz"
                                       category:@"SpringBoard"
                                     symbolName:@"square.grid.2x2.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsDSDisableAppLibrary
                                          isNew:NO];

        list = @[
            statBar,
            nsBar,
            niceBarLite,
            sbc,
            layoutExtras,
            gravityLite,
            powercuff,

            disableAppLibrary,

            [[Package alloc] initWithIdentifier:@"com.darksword.disable-icon-flyin"
                                           name:@"Disable Icon Fly-In"
                               shortDescription:@"Skip the icon spring animation"
                                longDescription:@"Skips the spring animation that plays when home screen icons appear after unlock or app switch. Icons just appear in their final position."
                                        version:version
                                         author:@"kolbicz"
                                       category:@"SpringBoard"
                                     symbolName:@"sparkles"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsDSDisableIconFlyIn
                                          isNew:NO],

            [[Package alloc] initWithIdentifier:@"com.darksword.zero-wake-animation"
                                           name:@"Zero Wake Animation"
                               shortDescription:@"Snap on instantly when waking"
                                longDescription:@"Removes the fade-in animation when waking the display. The screen pops on at full brightness immediately."
                                        version:version
                                         author:@"kolbicz"
                                       category:@"SpringBoard"
                                     symbolName:@"moon.zzz.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsDSZeroWakeAnimation
                                          isNew:NO],

            [[Package alloc] initWithIdentifier:@"com.darksword.zero-backlight-fade"
                                           name:@"Zero Backlight Fade"
                               shortDescription:@"Instant lock/unlock backlight"
                                longDescription:@"Cuts the backlight fade duration to zero so the display switches on or off instantly on lock and unlock."
                                        version:version
                                         author:@"kolbicz"
                                       category:@"SpringBoard"
                                     symbolName:@"sun.max.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsDSZeroBacklightFade
                                          isNew:NO],

            [[Package alloc] initWithIdentifier:@"com.darksword.double-tap-to-lock"
                                           name:@"Double-Tap to Lock"
                               shortDescription:@"Lock with a wallpaper double-tap"
                                longDescription:@"Double-tap an empty area of the Home Screen or Lock Screen background to lock the device. Version 1.1 excludes icons and the passcode screen, fixing accidental locks while opening apps or entering a passcode."
                                        version:@"1.1"
                                         author:@"kolbicz"
                                       category:@"SpringBoard"
                                     symbolName:@"hand.tap.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsDSDoubleTapToLock
                                          isNew:NO],

            ({
                Package *drag = [[Package alloc] initWithIdentifier:@"com.darksword.drag-coefficient"
                                                               name:@"Drag Coefficient"
                                                   shortDescription:@"Custom SpringBoard animation speed multiplier"
                                                    longDescription:@"Overrides _UIAnimationDragCoefficient in SpringBoard to make all UIKit spring animations faster or slower.\n\nSet the coefficient in the Drag Coefficient settings panel. 50% = 0.50× (2× faster), 25% = 0.25× (4× faster), 100% = stock.\n\nImported from kolbicz/DarkSword-Tweaks."
                                                            version:@"1.1"
                                                             author:@"kolbicz"
                                                           category:@"SpringBoard"
                                                         symbolName:@"dial.medium.fill"
                                                               kind:PackageInstallKindToggle
                                                         enabledKey:kSettingsDSDragCoefficientEnabled
                                                              isNew:NO];
                drag.settingsSection = kSecDragCoefficient;
                drag;
            }),

            otaBlock,
            lockScreenDuration,

            // Higher-risk/manual packages last so their warnings sit below core tweaks.
#if CYANIDE_EXPERIMENTAL_TWEAKS_AVAILABLE
#endif
            axon,
            nanoRegistry,
            callRecordingSound,
            passcodeTheme,
            hideHomeBar,
#if CYANIDE_EXPERIMENTAL_TWEAKS_AVAILABLE
            stageStrip,
            fastLockXLite,
#endif
            locationSim,
            snowboardLite,
            liveWP,
            appSwitcherGrid,
            quickLoader,
        ];
    });
    NSArray<Package *> *repoPackages = [self repoPackages];
    if (repoPackages.count == 0) return list;
    return [list arrayByAddingObjectsFromArray:repoPackages];
}

+ (NSArray<NSString *> *)categoriesInOrder
{
    NSArray<NSString *> *preferred = @[
        @"In Development",
        @"Beta",
        @"Experimental",
        @"Status Bar",
        @"Home Screen",
        @"Theming",
        @"SpringBoard",
        @"System",
        @"JavaScript Tweaks",
    ];
    NSMutableArray<NSString *> *all = [NSMutableArray array];
    for (Package *p in [self allPackages]) {
        if (![all containsObject:p.category]) [all addObject:p.category];
    }
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSString *cat in preferred) {
        if ([all containsObject:cat]) [order addObject:cat];
    }
    for (NSString *cat in all) {
        if (![order containsObject:cat]) [order addObject:cat];
    }
    return order;
}

+ (NSDictionary<NSString *, NSArray<Package *> *> *)packagesByCategory
{
    NSMutableDictionary<NSString *, NSMutableArray<Package *> *> *buckets = [NSMutableDictionary dictionary];
    for (Package *p in [self allPackages]) {
        NSMutableArray<Package *> *bucket = buckets[p.category];
        if (!bucket) {
            bucket = [NSMutableArray array];
            buckets[p.category] = bucket;
        }
        [bucket addObject:p];
    }
    return buckets;
}

@end
