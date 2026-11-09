//
//  mobilegestalt.h
//  Cyanide
//
//  MobileGestalt editor: switches device capabilities by editing the cached
//  answers in com.apple.MobileGestalt.plist (CacheExtra and CacheData).
//  Ported from lara by rooootdev (views/tweaks/mobilegestalt/GestaltView.swift),
//  with his permission. lara's version is based on SparseBox by khanhduytran0;
//  the keys are the ones Nugget by leminlimez and SparseBox use.
//
//  Every call that touches the file needs live kernel access (the file lives in
//  a system group container); call them from the Settings tool helper.
//

#ifndef mobilegestalt_h
#define mobilegestalt_h

#import <Foundation/Foundation.h>

#define MG_CACHE_PATH \
    @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"

typedef NS_ENUM(NSInteger, MGTweakKind) {
    MGTweakKindKeys,       // keys[] in CacheExtra set to the enable value, removed when off
    MGTweakKindRegion,     // region/model code US + LL/A
    MGTweakKindInternal,   // three internal flags in CacheData
    MGTweakKindIPadUI,     // iPadOS user interface on an iPhone (CacheData + keys)
};

typedef NS_OPTIONS(NSUInteger, MGTweakFlags) {
    MGTweakFlagNone            = 0,
    MGTweakFlagHomeButtonOnly  = 1 << 0,
    MGTweakFlagIPadOnly        = 1 << 1,
    MGTweakFlagIPhoneOnly      = 1 << 2,
    MGTweakFlagConfirm         = 1 << 3,   // ask before turning it on (`warning`)
    MGTweakFlagValueZero       = 1 << 4,   // "on" stores 0 (turns a capability off)
    MGTweakFlagValueIntList12  = 1 << 5,   // "on" stores @[@1, @2]
};

typedef struct {
    const char *title;
    const char *detail;
    const char *icon;          // SF Symbol
    const char *section;       // section title; consecutive entries share it
    MGTweakKind kind;
    const char *keys[7];       // NULL-terminated
    double minVersion;         // 0 = any
    MGTweakFlags flags;
    const char *warning;       // shown before turning on (MGTweakFlagConfirm)
} MGTweak;

// The tweaks, terminated by an entry with title == NULL.
const MGTweak *mg_tweaks(void);

// Whether this device and iOS version can use `t`; *why says why not.
BOOL mg_tweak_available(const MGTweak *t, NSString **why);

// Reads the cache (mutable, with mutable containers). The first successful
// read also keeps an untouched copy as the original backup. nil + *error on
// failure.
NSMutableDictionary *mg_load(NSString **error);

BOOL mg_tweak_is_on(NSDictionary *mg, const MGTweak *t);
// The device already has it (the original cache has the enabled value).
BOOL mg_tweak_builtin(const MGTweak *t);
// Changes the in-memory copy only; mg_write saves it.
BOOL mg_tweak_set(NSMutableDictionary *mg, const MGTweak *t, BOOL on, NSString **error);

// Device artwork (the screen shape apps and SpringBoard use) and the model
// name shown in Settings → General → About.
NSNumber *mg_artwork_subtype(NSDictionary *mg);
void mg_set_artwork_subtype(NSMutableDictionary *mg, NSNumber *subtype);
NSString *mg_device_name(NSDictionary *mg);
void mg_set_device_name(NSMutableDictionary *mg, NSString *name);   // nil = original
NSString *mg_product_type(NSDictionary *mg);
void mg_set_product_type(NSMutableDictionary *mg, NSString *productType);
// The values from the original backup (nil if there is none yet).
NSNumber *mg_original_artwork_subtype(void);
NSString *mg_original_device_name(void);
NSString *mg_original_product_type(void);

// Validates and writes `mg` back, keeping the file's owner and mode. The file
// as it was is copied to Documents/MobileGestalt/Backups first.
BOOL mg_write(NSDictionary *mg, NSString **error);
// Writes the original backup back.
BOOL mg_restore_original(NSString **error);
BOOL mg_has_original_backup(void);
NSString *mg_original_backup_path(void);

// "iPhone17,2" for this device.
NSString *mg_machine_name(void);
double mg_system_version(void);

#endif
