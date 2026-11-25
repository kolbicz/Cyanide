//
//  CyanideLanguage.h
//  Cyanide
//
//  Runtime language pack. The app predates NSLocalizedString and carries its
//  UI copy as English literals, so this layer translates at the UIKit edge
//  (labels, buttons, alerts, navigation/tab titles) from one central pack.
//  English is the identity language; Simplified Chinese is the first pack.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const CyanideLanguageEnglish;
FOUNDATION_EXPORT NSString * const CyanideLanguageSimplifiedChinese;
FOUNDATION_EXPORT NSString * const CyanideLanguagePreferenceKey;

/// Translates an English UI string for the active language. Returns the input
/// unchanged for English, unknown strings, and nil/empty input.
FOUNDATION_EXPORT NSString * _Nullable CyanideLocalized(NSString * _Nullable english);

/// Installs the UIKit translation hooks and loads the active pack. Call once
/// before UIApplicationMain.
FOUNDATION_EXPORT void CyanideLanguageInstall(void);

/// "en" or "zh-Hans"; follows the system when no override is stored.
FOUNDATION_EXPORT NSString *CyanideLanguageCurrentCode(void);
FOUNDATION_EXPORT NSString *CyanideLanguageSystemCode(void);

/// Every code with a bundled pack, in picker order.
FOUNDATION_EXPORT NSArray<NSString *> *CyanideLanguageSupportedCodes(void);

/// Native name for a language code ("Deutsch", "Français", …).
FOUNDATION_EXPORT NSString *CyanideLanguageNativeName(NSString *code);

/// Native name, or "Follow System (…)" when no override is stored.
FOUNDATION_EXPORT NSString *CyanideLanguageDisplayName(void);

/// YES when `actual` is the English title or its active-language translation.
/// Used where the code identifies a tab by its visible title.
FOUNDATION_EXPORT BOOL CyanideStringMatchesEnglish(NSString * _Nullable actual,
                                                   NSString * _Nullable english);

/// nil clears the override and follows the system; invalid values are ignored.
FOUNDATION_EXPORT void CyanideLanguageSetCode(NSString * _Nullable code);

NS_ASSUME_NONNULL_END
