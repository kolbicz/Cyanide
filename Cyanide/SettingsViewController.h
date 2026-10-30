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
    SectionPasscodeTheme,
    SectionFloatingDock,
    SectionSupervision,
    SectionCount,
};

void settings_park_krw_filter_for_background(void);
void settings_detach_krw_for_background(void);
// True when the KRW primitive can be handed to launchd without anything in
// the app immediately taking it back: no live tweak loop is running and no
// applied tweak is holding the SpringBoard session open. Consulted by the
// kexploit layer before it parks the primitive in launchd.
BOOL settings_krw_idle_detach_allowed(void);
// True when lazy reattach-from-launchd should be suppressed (app backgrounded /
// screen off and no live tweak needs KRW). Stops the Process Viewer's in-flight
// poll from thrashing detach/reattach right after a background detach.
BOOL settings_krw_reattach_suppressed(void);
void settings_reattach_krw_for_foreground(void);

// File Browser listing options (both off by default; set from the browser's
// options button).
extern NSString * const kSettingsFileBrowserShowHidden;
extern NSString * const kSettingsFileBrowserShowInaccessible;
// Root access (read-only) for the File Browser, through launchd. Off by
// default; enabled from the browser's options menu.
extern NSString * const kSettingsFileBrowserRootAccess;

// Read-only root access for the File Browser, run inside launchd (pid 1).
// Both return nil and set *errorOut (if given) on failure. Call off-main;
// each may take a moment (it may warm a launchd session first).
// *incompleteOut: the listing was cut short (entry cap or a readdir error);
// the entries returned are a prefix, not the whole folder.
NSArray<NSDictionary *> *settings_root_list_directory(NSString *path, BOOL *incompleteOut, NSString **errorOut);
NSData *settings_root_read_file(NSString *path, NSUInteger maxBytes, BOOL *truncatedOut, NSString **errorOut);
// removexattr as root (through launchd); a missing attribute counts as removed.
BOOL settings_root_remove_xattr(NSString *path, const char *name, NSString **errorOut);
extern NSString * const kSettingsA18ExploitPath;
extern NSString * const kSettingsA18Interleave;
extern NSString * const kSettingsA18MemoryShaping;
extern NSString * const kSettingsA18BoundedSearch;
extern NSString * const kSettingsRemoteSettleMode;
extern NSString * const kSettingsAutoRunKexploit;
extern NSString * const kSettingsRunPatchSandboxExt;
extern NSString * const kSettingsKeepAlive;

extern NSString * const kSettingsSBCEnabled;
extern NSString * const kSettingsSBCDockIcons;
extern NSString * const kSettingsSBCCols;
extern NSString * const kSettingsSBCRows;
extern NSString * const kSettingsSBCHideLabels;
extern NSString * const kSettingsSBCDockLabels;
extern NSString * const kSettingsSBCArrangePages;
extern NSString * const kSettingsSBCFirstPageIcons;
extern NSString * const kSettingsSBCOtherPageIcons;
extern NSString * const kSettingsSBCAutoDockApp;
extern NSString * const kSettingsSBCDockAppBundleID;

extern NSString * const kSettingsPowercuffEnabled;
extern NSString * const kSettingsPowercuffLevel;

extern NSString * const kSettingsDSDisableAppLibrary;
extern NSString * const kSettingsDSDisableIconFlyIn;
extern NSString * const kSettingsDSHideNewAppDots;
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
extern NSString * const kSettingsFloatingDockEnabled;
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


extern NSString * const kSettingsActionsDidCompleteNotification;
// Live status text for the progress screen during a long apply step;
// userInfo[kSettingsApplyStatusTextKey] is the text, or absent to restore the
// default status line.
extern NSString * const kSettingsApplyStatusDidChangeNotification;
// Kernel access or the SpringBoard session changed (posted on any thread).
extern NSString * const kSettingsRemoteCallStateDidChangeNotification;
extern NSString * const kSettingsApplyStatusTextKey;
extern NSString * const kSettingsActionsDidCompleteSuccessKey;
// YES when the run succeeded but some requested stages did not apply.
extern NSString * const kSettingsActionsDidCompletePartialKey;
extern NSString * const kSettingsActionsDidCompleteMessageKey;

// Completion message of the main chain run when the exploit stage fails to
// acquire KRW. The progress UI matches on this to offer its Run Again button.
extern NSString * const kSettingsRunKRWFailedMessage;

// Re-runs the chain in the same mode (full Apply vs pending-only) as the last
// invocation. Used by the progress UI's Run Again button after a KRW failure.
void settings_rerun_last_actions(void);

// Returns YES if the tweak whose master enable lives at `key` was successfully
// applied in this app session. Cleared on launch, on cleanup, and whenever the
// SpringBoard RemoteCall session goes away.
BOOL settings_tweak_is_applied(NSString *key);
void settings_mark_tweak_needs_apply(NSString *key);
// SpringBoard Tools applied with the tweaks (Settings → Lara → SpringBoard
// Tools → Apply with Tweaks). settings_sbtools_note: its screen applied the
// look itself (YES) or it changed and is due again (NO).
extern NSString * const kSettingsSBToolsWithTweaks;
void settings_sbtools_note(BOOL applied);
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
// Why this device / iOS version isn't supported (for the unsupported screen).
NSString *settings_unsupported_message(void);
// The Process Viewer and File Browser screens, for pushing from elsewhere
// (Home's quick tools).
UIViewController *settings_make_process_viewer(void);
UIViewController *settings_make_file_browser(void);
// A18 / A18 Pro / M4 family: the only devices with an A18 exploit path choice.
BOOL settings_device_is_a18_family(void);
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
// "Respring?" with Later / Respring, doing the full pre-respring cleanup.
void settings_present_respring_prompt(UIViewController *host, NSString *title, NSString *message);

// Applies the selected passcode style (apply == YES) or writes the backed-up
// original keypad digits back (apply == NO). Runs the keypad file edits
// immediately; returns YES when at least one digit was written and verified.
BOOL settings_apply_passcode_theme_now(BOOL apply);

// Newest entry of the bundled changelog (keys "version", "date", "changes"),
// or nil when the build carries none. The Home screen's What's New card.
NSDictionary *settings_latest_changelog_entry(void);

void settings_run_actions(void);
void settings_run_pending_actions(void);
// YES while a chain/run (not an ordinary action) owns the actions lock.
BOOL settings_run_in_flight(void);
// Before Cyanide switches itself to another app: waits for a live tweak's
// RemoteCall to finish and stops new ones (the background gate), so none is
// cut off half-way. Blocking; call off the main thread. Becoming active again
// reopens the gate.
void settings_quiesce_remote_calls_before_leaving(const char *why);
// Lets live tweaks call into SpringBoard again 2 s into a kept-alive
// background (Keep Alive playing); no-op in the foreground.
void settings_background_live_arm(const char *why);
// Records a pre-run failure (e.g. an installer package whose apply failed
// before the run started) to be folded into the next run's completion, so a
// failed install can't end with the progress screen showing "Done".
void settings_note_run_preflight_failure(NSString *message);
// Consume the pending pre-run failure message exactly once (installer path).
NSString * _Nullable settings_take_run_preflight_failure(void);
void settings_destroy_springboard_remote_call(void);
void settings_destroy_springboard_remote_call_sync(void);
void settings_best_effort_termination_cleanup(const char *reason);
void settings_application_did_enter_background(void);
void settings_application_will_enter_foreground(void);
void settings_application_did_become_active(void);
// File Browser: whether this process can read outside its sandbox, and lifting
// it through SpringBoard if not (`completion` on the main queue).
BOOL settings_filesystem_access_available(void);
// allowFullExploit: NO recovers a live or parked kernel session only; when a
// full exploit run would be needed it fails with
// kSettingsFullExploitRequiredMessage, so the caller can ask the user first
// (a full run can reboot A18/M4 devices) and retry with YES.
extern NSString * const kSettingsFullExploitRequiredMessage;
// cyanide://location-services links accepted (default NO: any app could open them).
extern NSString * const kSettingsLocationServicesLinksEnabled;
void settings_unlock_filesystem_async(BOOL allowFullExploit,
                                      void (^completion)(BOOL ok, NSString *message));
// Runs the exploit on its own (no tweaks applied) with the log window shown;
// a fresh run is confirmed first (it can reboot A18/M4). Completion is on the
// main queue and is called with NO for cancellation, failure, or an unavailable
// presentation opportunity; it is never silently dropped.
void settings_run_exploit_with_log(UIViewController *presenter, void (^completion)(BOOL ready));
// Live kernel access, or a parked session that can be restored without a run.
BOOL settings_kernel_access_available(void);
// What every tool does when only a fresh exploit run would give it kernel
// access: a "Run Exploit?" popup once per screen; `retry` runs once access is
// ready. Declined, the tool shows kSettingsNoKernelAccessHint. Main thread.
extern NSString * const kSettingsNoKernelAccessHint;
// Whether settings_tool_needs_exploit already showed its popup on `tool`.
BOOL settings_tool_exploit_was_offered(UIViewController *tool);
// Runs `work` inside SpringBoard for a tool screen, with the same kernel-access
// rules as the other tools (message kSettingsFullExploitRequiredMessage when
// only a manual run would help). completion(ok, message) on main.
void settings_springboard_tool_async(const char *tag, BOOL (^work)(void),
                                     void (^completion)(BOOL ok, NSString *message));
void settings_tool_needs_exploit(UIViewController *tool, UITableView *tableView, NSString *toolName,
                                 void (^retry)(void));
// Daemons screen (launchd disabled.plist). `disabled` maps label -> value as
// stored (nil on failure, with `message`); `running` maps every catalog label
// to @{ @"name": executable, @"pid": pid if running } (nil if the process
// list couldn't be read). Changes map label -> @YES to disable / @NO to
// enable. allowFullExploit as above. Completions on main.
void settings_daemons_read_async(BOOL allowFullExploit,
                                 void (^completion)(NSDictionary *disabled, NSDictionary *running,
                                                    NSString *message));
void settings_daemons_apply_async(NSDictionary<NSString *, NSNumber *> *changes, BOOL allowFullExploit,
                                  void (^completion)(BOOL ok, NSString *message));
// The Daemons screen, for pushing from Home's tools.
UIViewController *settings_make_daemons_viewer(void);
// System Info. Kernel access: @{ state: Active/Parked/None, detail, springboard: BOOL }.
NSDictionary *settings_kernel_access_status(void);
// AppleSmartBattery registry properties: read in Cyanide if the sandbox
// allows, else inside SpringBoard (kernel access as for Daemons). `source`
// says which; completion on main.
void settings_battery_info_async(BOOL allowFullExploit,
                                 void (^completion)(NSDictionary *battery, NSString *source, NSString *message));
UIViewController *settings_make_system_info_viewer(void);
// Names of all running processes (as the kernel keeps them: at most 31
// characters), nil when kernel access or the process list is unavailable.
// Blocking; off the main thread.
NSSet<NSString *> *settings_running_process_names(void);
// Names of processes that are actually running (not merely suspended/prewarmed).
// Suspended apps — including iOS prewarming — are absent; an uncalibrated entry
// is treated as active so it is protected. Blocking; off the main thread.
NSSet<NSString *> *settings_active_process_names(void);
// The cache cleaner screen.
UIViewController *settings_make_cleaner_viewer(void);
// System-wide Location Services: desired 1 = on, 0 = off, -1 = toggle.
// The result is posted as soon as it is confirmed; `completion` (optional)
// runs on the main queue after cleanup, with how long ago that was.
// removeFromSwitcher: on success, SpringBoard deletes Cyanide's App Switcher
// card ~2 s later (meant for shortcut runs that return to the Home Screen);
// homeDelay: how much longer than usual the caller stays in front before it
// goes Home (the removal is pushed back by that much).
// Progress for a running action: move to `fraction` (0…1), animated over
// `animateOver` seconds (0 = at once), and show `step`. `target` is what the
// action is setting (Location Services: 1 = on, 0 = off). Main queue.
typedef void (^SettingsProgressBlock)(float fraction, NSString *step, NSTimeInterval animateOver, int target);
// allowFullExploit: as for settings_unlock_filesystem_async -- NO never starts
// a fresh exploit run and fails with kSettingsFullExploitRequiredMessage instead.
// resolveOrigin: on a SpringBoard success, also record where the user was
// before this request brought Cyanide to the front; read it in `completion`
// with settings_location_services_take_origin().
void settings_location_services_set_async(int desired, BOOL allowFullExploit,
                                          BOOL removeFromSwitcher,
                                          BOOL resolveOrigin,
                                          NSTimeInterval homeDelay,
                                          SettingsProgressBlock progress,
                                          void (^completion)(BOOL ok, NSString *message,
                                                             NSTimeInterval resultAge));
// YES while a card removal armed by an earlier shortcut run can still fire
// (ending Cyanide). It cannot be cancelled safely (a pre-fire SpringBoard
// hijack is the activation ABBA deadlock), so new requests must fail fast
// instead of starting work the removal will kill.
BOOL settings_switcher_removal_pending(void);
// The origin recorded by the last resolveOrigin run, then cleared: 0 unknown,
// 1 Home Screen, 2 an app (its bundle ID in *bundleID). Main queue.
NSInteger settings_location_services_take_origin(NSString **bundleID);

@interface SettingsViewController : UITableViewController

// Root mode: expands the What's New section and scrolls to it.
- (void)showWhatsNew;

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
