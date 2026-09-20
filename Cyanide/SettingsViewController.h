//
//  SettingsViewController.h
//  Cyanide
//

#import <UIKit/UIKit.h>

// Underlying section indices for the Settings tab and the detail-mode
// SettingsViewController push (initWithUnderlyingSection:). Shared here so the
// package catalog can reference these by name instead of duplicating the raw
// numbers — the duplicated copy silently drifted once and mis-navigated every
// package customize button past SectionNiceBarLite. Keep new sections appended
// in display order.
typedef NS_ENUM(NSInteger, SettingsSection) {
    SectionWarning = 0,
    SectionLaunch,
    SectionActions,
    SectionOTA,
    SectionSBC,
    SectionStatBar,
    SectionNSBar,
    SectionNiceBarLite,
    SectionAxonLite,
    SectionPowercuff,
    SectionDarkSwordTweaks,
    SectionDragCoefficient,
    SectionLayoutExtras,
    SectionNanoRegistry,
    SectionThemer,
    SectionSnowBoardLite,
    SectionLiveWP,
    SectionLocationSim,
    SectionGravityLite,
    SectionAppSwitcherGrid,
    SectionFastLockXLite,
    SectionQuickLoader,
    SectionRepoTweaks,
    SectionLockScreenDuration,
    SectionCount,
};

void settings_park_krw_filter_for_background(void);
void settings_detach_krw_for_background(void);
// True when the KRW primitive can be handed to launchd without anything in
// the app immediately taking it back: no live tweak loop is running and no
// applied tweak is holding the SpringBoard session open. Consulted by the
// kexploit layer before it parks the primitive in launchd.
BOOL settings_krw_idle_detach_allowed(void);
void settings_reattach_krw_for_foreground(void);

extern NSString * const kSettingsA18ExploitPath;
extern NSString * const kSettingsA18Interleave;
extern NSString * const kSettingsA18MemoryShaping;
extern NSString * const kSettingsA18BoundedSearch;
extern NSString * const kSettingsRemoteSettleMode;
extern NSString * const kSettingsAutoRunKexploit;
extern NSString * const kSettingsRunSandboxEscape;
extern NSString * const kSettingsRunPatchSandboxExt;
extern NSString * const kSettingsKeepAlive;

extern NSString * const kSettingsSBCEnabled;
extern NSString * const kSettingsSBCDockIcons;
extern NSString * const kSettingsSBCCols;
extern NSString * const kSettingsSBCRows;
extern NSString * const kSettingsSBCHideLabels;
extern NSString * const kSettingsSBCArrangePages;
extern NSString * const kSettingsSBCFirstPageIcons;
extern NSString * const kSettingsSBCOtherPageIcons;
extern NSString * const kSettingsSBCAutoDockApp;
extern NSString * const kSettingsSBCDockAppBundleID;

extern NSString * const kSettingsPowercuffEnabled;
extern NSString * const kSettingsPowercuffLevel;

extern NSString * const kSettingsDSDisableAppLibrary;
extern NSString * const kSettingsDSDisableIconFlyIn;
extern NSString * const kSettingsDSZeroWakeAnimation;
extern NSString * const kSettingsDSZeroBacklightFade;
extern NSString * const kSettingsDSDoubleTapToLock;

extern NSString * const kSettingsDSDragCoefficientEnabled;
extern NSString * const kSettingsDSDragCoefficientValue;

extern NSString * const kSettingsLockDurationValue;

extern NSString * const kSettingsLayoutExtrasEnabled;
extern NSString * const kSettingsLayoutHomeExtraLeft;
extern NSString * const kSettingsLayoutHomeExtraRight;
extern NSString * const kSettingsLayoutHomeExtraTop;
extern NSString * const kSettingsLayoutHomeExtraBottom;
extern NSString * const kSettingsLayoutDockExtraLeft;
extern NSString * const kSettingsLayoutDockExtraRight;
extern NSString * const kSettingsLayoutHomeScalePct;
extern NSString * const kSettingsLayoutDockScalePct;

extern NSString * const kSettingsStatBarEnabled;
extern NSString * const kSettingsStatBarCelsius;
extern NSString * const kSettingsStatBarShowNet;
extern NSString * const kSettingsStatBarShowCPU;
extern NSString * const kSettingsStatBarShowLabels;
extern NSString * const kSettingsStatBarNetworkOnly;
extern NSString * const kSettingsStatBarRefreshRateSec;

extern NSString * const kSettingsNSBarEnabled;
extern NSString * const kSettingsNSBarPosition;

extern NSString * const kSettingsNiceBarLiteEnabled;


extern NSString * const kSettingsAxonLiteEnabled;

extern NSString * const kSettingsAppSwitcherGridEnabled;
extern NSString * const kSettingsFastLockXLiteEnabled;

extern NSString * const kSettingsGravityLiteEnabled;
extern NSString * const kSettingsGravityLiteDockEnabled;
extern NSString * const kSettingsGravityLiteMagnitudePct;
extern NSString * const kSettingsGravityLiteBouncePct;
extern NSString * const kSettingsGravityLiteFrictionPct;
extern NSString * const kSettingsGravityLiteResistancePct;

extern NSString * const kSettingsStageStripEnabled;

extern NSString * const kSettingsLocationSimLatitude;
extern NSString * const kSettingsLocationSimLongitude;
extern NSString * const kSettingsLocationSimAltitude;
extern NSString * const kSettingsLocationSimHorizontalAccuracy;
extern NSString * const kSettingsLocationSimHostProcess;

extern NSString * const kSettingsThemerEnabled;
extern NSString * const kSettingsThemerThemeID;
extern NSString * const kSettingsThemerCustomThemePath;
extern NSString * const kSettingsThemerCustomThemeName;

extern NSString * const kSettingsSnowBoardLiteEnabled;
extern NSString * const kSettingsSnowBoardLiteSelectedThemeID;

extern NSString * const kSettingsLiveWPEnabled;
extern NSString * const kSettingsLiveWPVideoPath;

extern NSString * const kSettingsQuickLoaderEnabled;

extern NSString * const kSettingsRepoTweaksEnabled;

extern NSString * const kSettingsExperimentalTweaksEnabled;

extern NSString * const kSettingsLogUploadEnabled;

extern NSString * const kSettingsActionsDidCompleteNotification;
extern NSString * const kSettingsActionsDidCompleteSuccessKey;
extern NSString * const kSettingsActionsDidCompleteMessageKey;

// Returns YES if the tweak whose master enable lives at `key` was successfully
// applied in this app session. Cleared on launch, on cleanup, and whenever the
// SpringBoard RemoteCall session goes away.
BOOL settings_tweak_is_applied(NSString *key);
void settings_mark_tweak_needs_apply(NSString *key);
// Re-queue already-applied tweaks so they can be applied again without
// relaunching Cyanide (relaunch-equivalent; clears only process-local applied
// state). Fires PackageQueueDidChangeNotification so the queue/bar repopulate.
void settings_requeue_applied_tweaks_for_reapply(void);
// True only while tweaks are applied in the current session (queue emptied by an
// in-session apply); false on a fresh relaunch where the queue already shows
// them. Use to show the re-apply button only when it's useful.
BOOL settings_has_reappliable_tweaks(void);

void settings_register_defaults(void);
BOOL settings_device_supported(void);
// Opens the Contact email composer (MFMailComposeViewController if Mail is
// configured, else mailto: fallback) prefilled with the latest diagnostic log
// inline. Presented from `host`.
void cyanide_present_contact(UIViewController *host);
BOOL settings_themer_has_selected_theme(void);
NSString *settings_themer_selected_theme_display_name(void);
BOOL settings_snowboardlite_has_selected_theme(void);
NSString *settings_snowboardlite_selected_theme_display_name(void);

// Synchronously runs kexploit and writes/clears the NanoRegistry pairing-
// compatibility override using the four numbers currently in NSUserDefaults
// (kSettingsNanoMaxPairing, etc.). Returns YES on success.
BOOL settings_apply_nano_registry_now(BOOL apply);
BOOL settings_apply_call_recording_sound_disabled(BOOL disabled);
BOOL settings_apply_hide_home_bar_hidden(BOOL hidden);
BOOL settings_hide_home_bar_hidden(void);
void settings_note_hide_home_bar_respring_pending(void);
BOOL settings_hide_home_bar_respring_pending(void);
void settings_present_hide_home_bar_respring_prompt(UIViewController *host);

void settings_run_actions(void);
void settings_run_pending_actions(void);
void settings_destroy_springboard_remote_call(void);
void settings_destroy_springboard_remote_call_sync(void);
void settings_best_effort_termination_cleanup(const char *reason);
void settings_application_did_enter_background(void);
void settings_application_will_enter_foreground(void);
void settings_application_did_become_active(void);

@interface SettingsViewController : UITableViewController

// Detail-mode init: renders a single underlying section (one tweak bundle).
// Pass underlyingSection == NSIntegerMax for root-mode (default storyboard path).
- (instancetype)initWithUnderlyingSection:(NSInteger)underlyingSection
                              bundleTitle:(nullable NSString *)bundleTitle NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;

// When set on a bundle-detail SettingsViewController launched from a package
// row's "Configure" entry, the nav bar shows a left-side back button
// ("← <package name>") that pops Settings to root and switches the user
// back to the tab they came from — so the install action stays one tap away
// after customizing.
@property (nonatomic, copy, nullable) NSString *installerReturnPackageName;

// Title of the bottom tab the back button switches to (Packages, Sources, ...),
// instead of always landing on Packages. It is normally the tab the package
// controls were opened from, but an entry can point somewhere else: the Home
// QuickLoader row returns to the Sources front page. Setting it on its own —
// without installerReturnPackageName — still shows the button, labelled with
// this tab title (the QuickLoader pages have no package).
@property (nonatomic, copy, nullable) NSString *installerReturnTabTitle;

// When YES, the target tab is popped to its root before the switch, so the
// button lands on that tab's front page instead of wherever that tab was left.
@property (nonatomic, assign) BOOL installerReturnResetsTargetTab;
@property (nonatomic, assign) BOOL quickLoaderStandalone;

// Current values for each configurable row in a settings section.
// Each entry: @{@"title": <label string>, @"value": <current value string>}.
// Returns empty array when the section has no configurable rows.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)settingsSummaryForSection:(NSInteger)section;
+ (BOOL)liveWPHasSelectedVideo;

@end
