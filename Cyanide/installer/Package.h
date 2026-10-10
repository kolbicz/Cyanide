//
//  Package.h
//  Cyanide
//
//  Model object representing one tweak in the Installer-style packages tab.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PackageInstallKind) {
    // Master enable is a BOOL in NSUserDefaults under enabledKey. Installing
    // sets it to YES; uninstalling sets NO. settings_run_actions() applies.
    PackageInstallKindToggle = 0,

    // One-shot plist edit gated by kexploit + sandbox patch (NanoRegistry
    // watchOS pairing-compatibility override). Installing calls
    // settings_apply_nano_registry_now(YES) which writes the four
    // compatibility keys from the Settings bundle; uninstalling clears them.
    // No live RC loop, doesn't run settings_run_actions.
    PackageInstallKindNanoRegistry = 2,

    // One-shot CallServices audio replacement gated by kexploit + sandbox
    // patch. Installing writes bundled silent disclosure sounds and stores
    // the first originals in Cyanide's app container; uninstalling restores
    // those backups when present.
    PackageInstallKindCallRecordingSound = 3,

    // One-shot MaterialKit asset page zero. Installing hides
    // the home bar after respring; restoring needs a respring.
    PackageInstallKindHideHomeBar = 4,

    // Direct settings tool. It has a Settings bundle but no install queue,
    // active state, or PackageQueue commit step.
    PackageInstallKindDirectTool = 5,

    // Dynamic package fetched from a RepoTweaks source. Known repo IDs can map
    // to Cyanide's native tweak backends; other compatible JS snippets are
    // imported into QuickLoader and applied through the normal run-actions path.
    PackageInstallKindRepoTweak = 6,
};

@interface Package : NSObject

@property (nonatomic, readonly, copy)     NSString *identifier;
@property (nonatomic, readonly, copy)     NSString *name;
@property (nonatomic, readonly, copy)     NSString *shortDescription;
@property (nonatomic, readonly, copy)     NSString *longDescription;
@property (nonatomic, readonly, copy)     NSString *version;
@property (nonatomic, readonly, copy)     NSString *author;
@property (nonatomic, readonly, copy)     NSString *category;
@property (nonatomic, readonly, copy)     NSString *symbolName;
@property (nonatomic, readonly, assign)   PackageInstallKind kind;
@property (nonatomic, readonly, copy, nullable) NSString *enabledKey;
@property (nonatomic, readonly, assign)   BOOL isNew;
@property (nonatomic, readonly, copy, nullable) NSString *repoURL;
@property (nonatomic, readonly, copy, nullable) NSString *repoTweakID;
@property (nonatomic, readonly, copy, nullable) NSString *repoScriptURL;
@property (nonatomic, readonly, copy, nullable) NSString *repoName;
@property (nonatomic, readonly, copy, nullable) NSString *repoNativeEnabledKey;
@property (nonatomic, readonly, assign) BOOL repoTweakUsesQuickLoader;

// SettingsSection enum value that corresponds to this package's bundle in the
// Settings tab. NSIntegerMax means the package has no Settings bundle
// (install/uninstall is its only operation).
@property (nonatomic, assign) NSInteger settingsSection;

// If non-nil, the detail view renders this text as a red disclaimer banner
// above the Information card. Use for packages that are known to be unstable
// (SpringBoard crashes, dropped events, layout glitches, etc.) so users can't
// miss the warning.
@property (nonatomic, copy, nullable) NSString *unstableWarning;

// Non-nil means users can view the package and uninstall an existing install,
// but cannot queue a fresh install until the reason is cleared.
@property (nonatomic, copy, nullable) NSString *installDisabledReason;

// YES means the package is gated behind kSettingsExperimentalTweaksEnabled.
// Prefer installDisabledReason for visible in-development packages.
@property (nonatomic, assign) BOOL experimental;

// YES means the package is internal-only. Public package lists hide it, and
// direct detail views keep the action disabled.
@property (nonatomic, assign) BOOL creatorOnly;

// Non-nil means the package detail view shows a prominent "Known Issues" card.
// Each string is one bullet. Set in PackageCatalog.
@property (nonatomic, copy, nullable) NSArray<NSString *> *knownIssues;

@property (nonatomic, readonly, assign) BOOL isInstalled;
@property (nonatomic, readonly, assign) BOOL isQueuedForApply;
@property (nonatomic, readonly, assign) BOOL isInstallDisabled;

- (instancetype)initWithIdentifier:(NSString *)identifier
                              name:(NSString *)name
                  shortDescription:(NSString *)shortDescription
                   longDescription:(NSString *)longDescription
                           version:(NSString *)version
                            author:(NSString *)author
                          category:(NSString *)category
                        symbolName:(NSString *)symbolName
                              kind:(PackageInstallKind)kind
                        enabledKey:(nullable NSString *)enabledKey
                             isNew:(BOOL)isNew NS_DESIGNATED_INITIALIZER;

- (instancetype)initRepoTweakWithIdentifier:(NSString *)identifier
                                      name:(NSString *)name
                          shortDescription:(NSString *)shortDescription
                                   version:(NSString *)version
                                    author:(NSString *)author
                                  repoName:(NSString *)repoName
                                   repoURL:(NSString *)repoURL
                               repoTweakID:(NSString *)repoTweakID
                              repoScriptURL:(NSString *)repoScriptURL;

- (instancetype)init NS_UNAVAILABLE;

- (void)install;
- (void)uninstall;
// Returns NO when the requested state could not be applied (already logged).
- (BOOL)applyCommittedState:(BOOL)installed;
- (void)syncRepoTweakOptionsToNativeSettings;

@end

NS_ASSUME_NONNULL_END
