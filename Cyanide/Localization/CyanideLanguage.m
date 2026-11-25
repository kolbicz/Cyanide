//
//  CyanideLanguage.m
//  Cyanide
//

#import "CyanideLanguage.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NSString * const CyanideLanguageEnglish = @"en";
NSString * const CyanideLanguageSimplifiedChinese = @"zh-Hans";
NSString * const CyanideLanguagePreferenceKey = @"CyanideLanguageCode";

static NSString *gLanguageCode;
static NSDictionary<NSString *, NSString *> *gStrings;
static NSArray<NSDictionary *> *gPatterns;

NSArray<NSString *> *CyanideLanguageSupportedCodes(void) {
    return @[ CyanideLanguageEnglish, CyanideLanguageSimplifiedChinese, @"de", @"fr",
               @"es", @"it", @"ja", @"ko", @"pl", @"pt-BR", @"ru", @"th", @"tr", @"vi", @"ar" ];
}

static BOOL CyanideLanguageIsSupported(NSString *code) {
    return [CyanideLanguageSupportedCodes() containsObject:code];
}

NSString *CyanideLanguageNativeName(NSString *code) {
    if ([code isEqualToString:CyanideLanguageEnglish]) return @"English";
    if ([code isEqualToString:CyanideLanguageSimplifiedChinese]) return @"简体中文";
    if ([code isEqualToString:@"de"]) return @"Deutsch";
    if ([code isEqualToString:@"fr"]) return @"Français";
    if ([code isEqualToString:@"es"]) return @"Español";
    if ([code isEqualToString:@"it"]) return @"Italiano";
    if ([code isEqualToString:@"ja"]) return @"日本語";
    if ([code isEqualToString:@"ko"]) return @"한국어";
    if ([code isEqualToString:@"pl"]) return @"Polski";
    if ([code isEqualToString:@"pt-BR"]) return @"Português (Brasil)";
    if ([code isEqualToString:@"ru"]) return @"Русский";
    if ([code isEqualToString:@"th"]) return @"ไทย";
    if ([code isEqualToString:@"tr"]) return @"Türkçe";
    if ([code isEqualToString:@"vi"]) return @"Tiếng Việt";
    if ([code isEqualToString:@"ar"]) return @"العربية";
    return code ?: @"";
}

static NSString *CyanideLanguageSystemName(void) {
    return CyanideLanguageNativeName(CyanideLanguageSystemCode());
}

NSString *CyanideLanguageSystemCode(void) {
    for (NSString *preferred in [NSLocale preferredLanguages]) {
        if ([preferred hasPrefix:@"zh"]) return CyanideLanguageSimplifiedChinese;
        if ([preferred hasPrefix:@"de"]) return @"de";
        if ([preferred hasPrefix:@"fr"]) return @"fr";
        if ([preferred hasPrefix:@"es"]) return @"es";
        if ([preferred hasPrefix:@"it"]) return @"it";
        if ([preferred hasPrefix:@"ja"]) return @"ja";
        if ([preferred hasPrefix:@"ko"]) return @"ko";
        if ([preferred hasPrefix:@"pl"]) return @"pl";
        if ([preferred hasPrefix:@"pt"]) return @"pt-BR";
        if ([preferred hasPrefix:@"ru"]) return @"ru";
        if ([preferred hasPrefix:@"th"]) return @"th";
        if ([preferred hasPrefix:@"tr"]) return @"tr";
        if ([preferred hasPrefix:@"vi"]) return @"vi";
        if ([preferred hasPrefix:@"ar"]) return @"ar";
    }
    return CyanideLanguageEnglish;
}

NSString *CyanideLanguageCurrentCode(void) {
    if (gLanguageCode.length) return gLanguageCode;
    NSString *stored = [[NSUserDefaults standardUserDefaults]
                        stringForKey:CyanideLanguagePreferenceKey];
    if (CyanideLanguageIsSupported(stored)) {
        gLanguageCode = [stored copy];
    } else {
        gLanguageCode = [CyanideLanguageSystemCode() copy];
    }
    return gLanguageCode;
}

static void CyanideLanguageLoadPatterns(NSArray *raw) {
    NSMutableArray *out = [NSMutableArray array];
    for (id obj in raw) {
        if (![obj isKindOfClass:NSDictionary.class]) continue;
        NSString *pattern = obj[@"pattern"];
        NSString *template = obj[@"template"];
        if (![pattern isKindOfClass:NSString.class] || !pattern.length ||
            ![template isKindOfClass:NSString.class] || !template.length) continue;
        NSError *error = nil;
        NSRegularExpression *regex = [NSRegularExpression
            regularExpressionWithPattern:pattern options:0 error:&error];
        if (!regex || error) continue;
        [out addObject:@{ @"regex": regex, @"template": template }];
    }
    gPatterns = [out copy];
}

static void CyanideLanguageReload(void) {
    gStrings = @{};
    gPatterns = @[];
    NSString *code = CyanideLanguageCurrentCode();
    if ([code isEqualToString:CyanideLanguageEnglish]) return;

    NSString *resource = [@"Localization-" stringByAppendingString:code];
    NSString *path = [[NSBundle mainBundle] pathForResource:resource ofType:@"plist"];
    NSDictionary *root = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if (![root isKindOfClass:NSDictionary.class]) {
        NSLog(@"[LANGUAGE] %@ pack missing or malformed at %@", code, path ?: @"(nil)");
        return;
    }
    NSDictionary *strings = root[@"strings"];
    if ([strings isKindOfClass:NSDictionary.class]) gStrings = [strings copy];
    id patterns = root[@"patterns"];
    if ([patterns isKindOfClass:NSArray.class]) CyanideLanguageLoadPatterns(patterns);
    NSLog(@"[LANGUAGE] loaded %@ (%lu strings, %lu patterns)",
          code, (unsigned long)gStrings.count, (unsigned long)gPatterns.count);
}

NSString *CyanideLocalized(NSString *english) {
    if (![english isKindOfClass:NSString.class] || english.length == 0) return english;
    if (gStrings.count == 0) return english;
    NSString *exact = gStrings[english];
    if (exact.length) return exact;

    NSRange full = NSMakeRange(0, english.length);
    for (NSDictionary *item in gPatterns) {
        NSRegularExpression *regex = item[@"regex"];
        NSString *template = item[@"template"];
        if (![regex isKindOfClass:NSRegularExpression.class] ||
            ![template isKindOfClass:NSString.class]) continue;
        if ([regex firstMatchInString:english options:0 range:full]) {
            return [regex stringByReplacingMatchesInString:english
                                                   options:0
                                                     range:full
                                              withTemplate:template];
        }
    }
    return english;
}

BOOL CyanideStringMatchesEnglish(NSString *actual, NSString *english) {
    if (![actual isKindOfClass:NSString.class] || ![english isKindOfClass:NSString.class]) return NO;
    if ([actual isEqualToString:english]) return YES;
    NSString *translated = CyanideLocalized(english);
    return translated.length > 0 && [actual isEqualToString:translated];
}

NSString *CyanideLanguageDisplayName(void) {
    NSString *stored = [[NSUserDefaults standardUserDefaults]
                        stringForKey:CyanideLanguagePreferenceKey];
    if (CyanideLanguageIsSupported(stored)) return CyanideLanguageNativeName(stored);
    return [NSString stringWithFormat:@"%@ (%@)",
            CyanideLocalized(@"Follow System"), CyanideLanguageSystemName()];
}

void CyanideLanguageSetCode(NSString *code) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (CyanideLanguageIsSupported(code)) {
        [defaults setObject:code forKey:CyanideLanguagePreferenceKey];
    } else {
        [defaults removeObjectForKey:CyanideLanguagePreferenceKey];
    }
    [defaults synchronize];
    gLanguageCode = nil;
    CyanideLanguageReload();
}

#pragma mark - UIKit hooks

static void CYSwizzleInstance(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

static void CYSwizzleClass(Class cls, SEL original, SEL replacement) {
    Method a = class_getClassMethod(cls, original);
    Method b = class_getClassMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

@implementation UILabel (CyanideLanguage)
- (void)cy_language_setText:(NSString *)text {
    [self cy_language_setText:CyanideLocalized(text)];
}
@end

@implementation UIButton (CyanideLanguage)
- (void)cy_language_setTitle:(NSString *)title forState:(UIControlState)state {
    [self cy_language_setTitle:CyanideLocalized(title) forState:state];
}
@end

@implementation UIViewController (CyanideLanguage)
- (void)cy_language_setTitle:(NSString *)title {
    [self cy_language_setTitle:CyanideLocalized(title)];
}
@end

@implementation UINavigationItem (CyanideLanguage)
- (void)cy_language_setTitle:(NSString *)title {
    [self cy_language_setTitle:CyanideLocalized(title)];
}
- (void)cy_language_setPrompt:(NSString *)prompt {
    [self cy_language_setPrompt:CyanideLocalized(prompt)];
}
@end

@implementation UIBarButtonItem (CyanideLanguage)
- (instancetype)cy_language_initWithTitle:(NSString *)title
                                   style:(UIBarButtonItemStyle)style
                                  target:(id)target
                                  action:(SEL)action {
    return [self cy_language_initWithTitle:CyanideLocalized(title)
                                    style:style target:target action:action];
}
- (void)cy_language_setTitle:(NSString *)title {
    [self cy_language_setTitle:CyanideLocalized(title)];
}
@end

@implementation UITabBarItem (CyanideLanguage)
- (instancetype)cy_language_initWithTitle:(NSString *)title image:(UIImage *)image tag:(NSInteger)tag {
    return [self cy_language_initWithTitle:CyanideLocalized(title) image:image tag:tag];
}
- (instancetype)cy_language_initWithTitle:(NSString *)title
                                   image:(UIImage *)image
                           selectedImage:(UIImage *)selectedImage {
    return [self cy_language_initWithTitle:CyanideLocalized(title)
                                    image:image selectedImage:selectedImage];
}
- (void)cy_language_setTitle:(NSString *)title {
    [self cy_language_setTitle:CyanideLocalized(title)];
}
@end

@implementation UISegmentedControl (CyanideLanguage)
- (instancetype)cy_language_initWithItems:(NSArray *)items {
    NSMutableArray *translated = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        [translated addObject:[item isKindOfClass:NSString.class]
                               ? CyanideLocalized(item) : item];
    }
    return [self cy_language_initWithItems:translated];
}
- (void)cy_language_setTitle:(NSString *)title forSegmentAtIndex:(NSUInteger)segment {
    [self cy_language_setTitle:CyanideLocalized(title) forSegmentAtIndex:segment];
}
@end

@implementation UISearchBar (CyanideLanguage)
- (void)cy_language_setPlaceholder:(NSString *)placeholder {
    [self cy_language_setPlaceholder:CyanideLocalized(placeholder)];
}
@end

@implementation UITextField (CyanideLanguage)
- (void)cy_language_setPlaceholder:(NSString *)placeholder {
    [self cy_language_setPlaceholder:CyanideLocalized(placeholder)];
}
@end

@implementation UIAlertAction (CyanideLanguage)
+ (instancetype)cy_language_actionWithTitle:(NSString *)title
                                     style:(UIAlertActionStyle)style
                                   handler:(void (^)(UIAlertAction *))handler {
    return [self cy_language_actionWithTitle:CyanideLocalized(title)
                                      style:style handler:handler];
}
@end

@implementation UIAlertController (CyanideLanguage)
+ (instancetype)cy_language_alertControllerWithTitle:(NSString *)title
                                            message:(NSString *)message
                                     preferredStyle:(UIAlertControllerStyle)preferredStyle {
    return [self cy_language_alertControllerWithTitle:CyanideLocalized(title)
                                              message:CyanideLocalized(message)
                                       preferredStyle:preferredStyle];
}
@end

@implementation UIAction (CyanideLanguage)
+ (instancetype)cy_language_actionWithTitle:(NSString *)title
                                     image:(UIImage *)image
                                identifier:(UIActionIdentifier)identifier
                                   handler:(UIActionHandler)handler {
    return [self cy_language_actionWithTitle:CyanideLocalized(title)
                                       image:image identifier:identifier handler:handler];
}
@end

@implementation UIMenu (CyanideLanguage)
+ (instancetype)cy_language_menuWithTitle:(NSString *)title
                                children:(NSArray<UIMenuElement *> *)children {
    return [self cy_language_menuWithTitle:CyanideLocalized(title) children:children];
}
+ (instancetype)cy_language_menuWithTitle:(NSString *)title
                                   image:(UIImage *)image
                              identifier:(UIMenuIdentifier)identifier
                                 options:(UIMenuOptions)options
                                children:(NSArray<UIMenuElement *> *)children {
    return [self cy_language_menuWithTitle:CyanideLocalized(title)
                                    image:image identifier:identifier
                                  options:options children:children];
}
@end

void CyanideLanguageInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CYSwizzleInstance(UILabel.class, @selector(setText:), @selector(cy_language_setText:));
        CYSwizzleInstance(UIButton.class, @selector(setTitle:forState:),
                          @selector(cy_language_setTitle:forState:));
        CYSwizzleInstance(UIViewController.class, @selector(setTitle:),
                          @selector(cy_language_setTitle:));
        CYSwizzleInstance(UINavigationItem.class, @selector(setTitle:),
                          @selector(cy_language_setTitle:));
        CYSwizzleInstance(UINavigationItem.class, @selector(setPrompt:),
                          @selector(cy_language_setPrompt:));
        CYSwizzleInstance(UIBarButtonItem.class, @selector(initWithTitle:style:target:action:),
                          @selector(cy_language_initWithTitle:style:target:action:));
        CYSwizzleInstance(UIBarButtonItem.class, @selector(setTitle:),
                          @selector(cy_language_setTitle:));
        CYSwizzleInstance(UITabBarItem.class, @selector(initWithTitle:image:tag:),
                          @selector(cy_language_initWithTitle:image:tag:));
        CYSwizzleInstance(UITabBarItem.class, @selector(initWithTitle:image:selectedImage:),
                          @selector(cy_language_initWithTitle:image:selectedImage:));
        CYSwizzleInstance(UITabBarItem.class, @selector(setTitle:),
                          @selector(cy_language_setTitle:));
        CYSwizzleInstance(UISegmentedControl.class, @selector(initWithItems:),
                          @selector(cy_language_initWithItems:));
        CYSwizzleInstance(UISegmentedControl.class, @selector(setTitle:forSegmentAtIndex:),
                          @selector(cy_language_setTitle:forSegmentAtIndex:));
        CYSwizzleInstance(UISearchBar.class, @selector(setPlaceholder:),
                          @selector(cy_language_setPlaceholder:));
        CYSwizzleInstance(UITextField.class, @selector(setPlaceholder:),
                          @selector(cy_language_setPlaceholder:));
        CYSwizzleClass(UIAlertAction.class, @selector(actionWithTitle:style:handler:),
                       @selector(cy_language_actionWithTitle:style:handler:));
        CYSwizzleClass(UIAlertController.class,
                       @selector(alertControllerWithTitle:message:preferredStyle:),
                       @selector(cy_language_alertControllerWithTitle:message:preferredStyle:));
        CYSwizzleClass(UIAction.class, @selector(actionWithTitle:image:identifier:handler:),
                       @selector(cy_language_actionWithTitle:image:identifier:handler:));
        CYSwizzleClass(UIMenu.class, @selector(menuWithTitle:children:),
                       @selector(cy_language_menuWithTitle:children:));
        CYSwizzleClass(UIMenu.class,
                       @selector(menuWithTitle:image:identifier:options:children:),
                       @selector(cy_language_menuWithTitle:image:identifier:options:children:));
        CyanideLanguageReload();
        BOOL rtl = [CyanideLanguageCurrentCode() isEqualToString:@"ar"];
        [UIView appearance].semanticContentAttribute =
            rtl ? UISemanticContentAttributeForceRightToLeft
                : UISemanticContentAttributeForceLeftToRight;
    });
}
