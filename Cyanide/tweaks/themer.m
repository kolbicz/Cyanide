//
//  themer.m
//  RemoteCall-only icon theming. Per-bundle PNG swap on every SBIconView.
//

#import "themer.h"
#import "remote_objc.h"
#import "sb_walk.h"
#import "../map_app.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"
#import "../SBLArchiveExtractor.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <time.h>

typedef struct {
    char bundle[128];
    uint64_t image;      // retained SB UIImage*
    uint64_t dataSource; // retained SB helper from earlier model experiments
    bool iconServicesSeeded;
} ThemerEntry;

typedef struct {
    uint64_t icon;
    char bundle[128];
} ThemerIconBundleEntry;

static const int    kThemerMaxCache    = 512;
static const int    kThemerMaxIconBundleCache = 512;
static const size_t kThemerMaxPngBytes = THEMER_MAX_ICON_BYTES;   // 256 KB hard cap per icon
static const NSUInteger kThemerBulkModelGraftCap = 128;
static const uint32_t kThemerApplySettleUS = 0;
static const bool kThemerDetailedIconLogs = false;

// Debug focus: when non-empty, only apply to this single bundle. Keeps the
// log readable while we figure out which iOS 26 render path actually sticks.
// Set to "" or NULL to re-enable the full theme.
static const char *kThemerFocusBundle = "";

static ThemerEntry gThemerCache[kThemerMaxCache];
static int         gThemerCacheCount = 0;
static ThemerIconBundleEntry gThemerIconBundleCache[kThemerMaxIconBundleCache];
static int         gThemerIconBundleCacheCount = 0;
static NSDictionary<NSString *, NSData *> *__strong gThemerActiveThemeDataByBundle = nil;
static int         gThemerLogBudget  = 48;
static bool        gThemerModelProbeLogged = false;
static bool        gThemerIconServicesProbeLogged = false;
static int         gThemerHostIOSMajor = -1;
static bool        gThemerVisiblePolicyLogged = false;

// -1 unprobed, 0 nothing works, 1/2/3/4 chosen rung.
static int  gThemerRung              = -1;
static bool gThemerHasUpdateAfter    = false;
static bool gThemerHasUpdateImageView = false;

static uint64_t themer_now_us(void)
{
    struct timespec ts = {0};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((uint64_t)ts.tv_sec * 1000000ULL) + ((uint64_t)ts.tv_nsec / 1000ULL);
}

static int themer_host_ios_major(void)
{
    if (gThemerHostIOSMajor >= 0) return gThemerHostIOSMajor;
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    gThemerHostIOSMajor = (int)v.majorVersion;
    return gThemerHostIOSMajor;
}

static NSArray<NSString *> *themer_priority_theme_bundles(void)
{
    static NSArray<NSString *> *bundles = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundles = @[
            @"com.apple.AppStore",
            @"com.apple.DocumentsApp",
            @"com.apple.Health",
            @"com.apple.Home",
            @"com.apple.Maps",
            @"com.apple.MobileAddressBook",
            @"com.apple.MobileSMS",
            @"com.apple.Music",
            @"com.apple.Passbook",
            @"com.apple.Preferences",
            @"com.apple.Translate",
            @"com.apple.VoiceMemos",
            @"com.apple.calculator",
            @"com.apple.camera",
            @"com.apple.findmy",
            @"com.apple.freeform",
            @"com.apple.iBooks",
            @"com.apple.mobilecal",
            @"com.apple.mobilemail",
            @"com.apple.mobilenotes",
            @"com.apple.mobilephone",
            @"com.apple.mobilesafari",
            @"com.apple.mobileslideshow",
            @"com.apple.mobiletimer",
            @"com.apple.podcasts",
            @"com.apple.reminders",
            @"com.apple.shortcuts",
            @"com.apple.stocks",
            @"com.apple.weather",
            @"com.alipay.iphoneclient",
            @"com.taobao.taobao4iphone",
            @"com.autonavi.minimap",
            @"com.360buy.jdmobile",
            @"com.jd.jrapp",
            @"com.taobao.fleamarket",
            @"com.tmall.wireless",
            @"com.alibaba.wireless",
            @"com.cainiao.Cainiao4iPhone",
            @"com.hpbr.bosszhipin",
            @"com.xingin.discover",
            @"com.sina.weibo",
            @"com.zhihu.ios",
            @"com.baidu.searchbox",
            @"com.baidu.map",
            @"com.baidu.netdisk",
            @"com.baidu.tieba",
            @"com.xiaojukeji.didi",
            @"ctrip.com",
            @"com.qunar.iphoneclient",
            @"com.meituan.imeituan",
            @"com.meituan.waimai",
            @"com.dianping.dpscope",
            @"me.ele.ios.eleme",
            @"com.netease.cloudmusic",
            @"com.qiyi.iphone",
            @"com.youku.YouKu",
            @"com.tencent.live4iphone",
            @"com.tencent.map",
            @"com.tencent.mttlite",
            @"com.tencent.QQMusic",
            @"com.tencent.qqmail",
            @"com.tencent.karaoke",
            @"com.laiwang.DingTalk",
            @"com.tencent.ww",
            @"com.larksuite.Lark",
            @"com.kingsoft.wpsoffice",
            @"com.xunlei.download",
            @"cmb.pb",
            @"com.icbc.iphoneclient",
            @"com.ccb.ccbMobileBank",
            @"com.abchina.iphone.abchina",
            @"com.bocmbci.bocmbci",
            @"cn.com.spdb.mobilebank.per",
            @"com.ecitic.bank.mobile",
            @"com.pingan.paces.ccms",
            @"com.pingan.pabank",
            @"com.google.ios.youtube",
            @"com.ss.iphone.ugc.Aweme",
            @"com.kuaishou.gifmaker",
            @"tv.danmaku.biliblue",
            @"tv.danmaku.bilianime",
            @"com.tencent.xin",
            @"com.tencent.mqq",
            @"com.xunmeng.pinduoduo",
            @"com.github.stormbreaker.prod",
            @"com.liguangming.Shadowrocket",
            @"com.atebits.Tweetie2",
            @"com.autonavi.amap",
        ];
    });
    return bundles;
}

static NSString *themer_join_strings_for_log(id strings, NSUInteger limit)
{
    if (![strings respondsToSelector:@selector(allObjects)] &&
        ![strings respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
        return @"";
    }

    NSArray *raw = [strings respondsToSelector:@selector(allObjects)]
        ? [strings allObjects]
        : (NSArray *)strings;
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (id obj in raw) {
        if (![obj isKindOfClass:NSString.class] || [obj length] == 0) continue;
        [items addObject:obj];
    }
    [items sortUsingSelector:@selector(compare:)];

    NSUInteger total = items.count;
    if (limit > 0 && items.count > limit) {
        items = [[items subarrayWithRange:NSMakeRange(0, limit)] mutableCopy];
        [items addObject:[NSString stringWithFormat:@"...(+%lu)", (unsigned long)(total - limit)]];
    }
    return [items componentsJoinedByString:@","];
}

static NSString *themer_theme_path_for_bundle(NSDictionary<NSString *, NSString *> *pathByBundle,
                                              NSString *bundle)
{
    if (![bundle isKindOfClass:NSString.class] || bundle.length == 0) return nil;
    NSString *path = pathByBundle[bundle];
    if (!path) path = pathByBundle[bundle.lowercaseString];
    return path;
}

static uint64_t themer_lookup_cached(const char *bundle)
{
    if (!bundle || !bundle[0]) return 0;
    for (int i = 0; i < gThemerCacheCount; i++) {
        if (strcmp(gThemerCache[i].bundle, bundle) == 0) {
            return gThemerCache[i].image;
        }
    }
    return 0;
}

static ThemerEntry *themer_lookup_entry(const char *bundle)
{
    if (!bundle || !bundle[0]) return NULL;
    for (int i = 0; i < gThemerCacheCount; i++) {
        if (strcmp(gThemerCache[i].bundle, bundle) == 0) {
            return &gThemerCache[i];
        }
    }
    return NULL;
}

// Takes ownership of `image` on success. On failure (cache full) the caller
// still owns the +1 image and must release it.
static bool themer_cache_image(const char *bundle, uint64_t image)
{
    if (!bundle || !bundle[0] || !r_is_objc_ptr(image)) return false;
    if (gThemerCacheCount >= kThemerMaxCache) {
        static int fullLogs = 0;
        if (fullLogs < 4) {
            printf("[THEMER] image cache full (%d) bundle=%s skipped\n",
                   kThemerMaxCache, bundle);
            fullLogs++;
        }
        return false;
    }
    ThemerEntry *e = &gThemerCache[gThemerCacheCount++];
    snprintf(e->bundle, sizeof(e->bundle), "%s", bundle);
    e->image = image;
    e->dataSource = 0;
    e->iconServicesSeeded = false;
    return true;
}

static void themer_cache_icon_bundle(uint64_t icon, const char *bundle)
{
    if (!r_is_objc_ptr(icon) || !bundle || !bundle[0]) return;
    for (int i = 0; i < gThemerIconBundleCacheCount; i++) {
        if (gThemerIconBundleCache[i].icon == icon) {
            snprintf(gThemerIconBundleCache[i].bundle,
                     sizeof(gThemerIconBundleCache[i].bundle),
                     "%s", bundle);
            return;
        }
    }
    if (gThemerIconBundleCacheCount >= kThemerMaxIconBundleCache) return;
    ThemerIconBundleEntry *e = &gThemerIconBundleCache[gThemerIconBundleCacheCount++];
    e->icon = icon;
    snprintf(e->bundle, sizeof(e->bundle), "%s", bundle);
}

static bool themer_lookup_icon_bundle(uint64_t icon, char *out, size_t outLen)
{
    if (!r_is_objc_ptr(icon) || !out || outLen == 0) return false;
    for (int i = 0; i < gThemerIconBundleCacheCount; i++) {
        if (gThemerIconBundleCache[i].icon == icon &&
            gThemerIconBundleCache[i].bundle[0]) {
            snprintf(out, outLen, "%s", gThemerIconBundleCache[i].bundle);
            return out[0] != '\0';
        }
    }
    return false;
}

static void themer_reset_icon_bundle_cache(void)
{
    for (int i = 0; i < kThemerMaxIconBundleCache; i++) {
        gThemerIconBundleCache[i].icon = 0;
        gThemerIconBundleCache[i].bundle[0] = '\0';
    }
    gThemerIconBundleCacheCount = 0;
}

// Read a remote ObjC object's class name into a local C buffer.
static void themer_read_class_name(uint64_t obj, char *out, size_t outLen)
{
    if (!out || outLen == 0) return;
    out[0] = '\0';
    if (!r_is_objc_ptr(obj)) return;
    uint64_t cls = r_dlsym_call(R_TIMEOUT, "object_getClass", obj, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(cls)) return;
    uint64_t name = r_dlsym_call(R_TIMEOUT, "class_getName", cls, 0, 0, 0, 0, 0, 0, 0);
    if (!name) return;
    uint64_t heap = r_dlsym_call(R_TIMEOUT, "strdup", name, 0, 0, 0, 0, 0, 0, 0);
    if (!heap) return;
    if (remote_read(heap, out, outLen - 1)) out[outLen - 1] = '\0';
    r_free(heap);
}

static void themer_read_class_object_name(uint64_t cls, char *out, size_t outLen)
{
    if (!out || outLen == 0) return;
    out[0] = '\0';
    if (!r_is_objc_ptr(cls)) return;
    uint64_t name = r_dlsym_call(R_TIMEOUT, "class_getName",
                                 cls, 0, 0, 0, 0, 0, 0, 0);
    if (!name) return;
    uint64_t heap = r_dlsym_call(R_TIMEOUT, "strdup",
                                 name, 0, 0, 0, 0, 0, 0, 0);
    if (!heap) return;
    if (remote_read(heap, out, outLen - 1)) out[outLen - 1] = '\0';
    r_free(heap);
}

static uint64_t themer_lookup_class(const char *name)
{
    if (!name || !name[0]) return 0;
    uint64_t s = r_alloc_str(name);
    if (!s) return 0;
    uint64_t cls = r_dlsym_call(R_TIMEOUT, "objc_lookUpClass",
                                s, 0, 0, 0, 0, 0, 0, 0);
    r_free(s);
    return cls;
}

static uint64_t themer_method_imp(uint64_t cls, const char *selName)
{
    if (!r_is_objc_ptr(cls) || !selName) return 0;
    uint64_t sel = r_sel(selName);
    if (!sel) return 0;
    uint64_t method = r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod",
                                   cls, sel, 0, 0, 0, 0, 0, 0);
    if (!method) return 0;
    return r_dlsym_call(R_TIMEOUT, "method_getImplementation",
                        method, 0, 0, 0, 0, 0, 0, 0);
}

static bool themer_add_method(uint64_t cls, const char *selName,
                              uint64_t imp, const char *types)
{
    if (!r_is_objc_ptr(cls) || !selName || !imp || !types) return false;
    uint64_t sel = r_sel(selName);
    uint64_t typeStr = r_alloc_str(types);
    if (!sel || !typeStr) {
        if (typeStr) r_free(typeStr);
        return false;
    }
    uint64_t ok = r_dlsym_call(R_TIMEOUT, "class_addMethod",
                               cls, sel, imp, typeStr, 0, 0, 0, 0);
    r_free(typeStr);
    return (ok & 0xff) != 0;
}

static bool themer_add_methods(uint64_t cls, const char **sels, int count,
                               uint64_t imp, const char *types)
{
    if (!r_is_objc_ptr(cls) || !sels || count <= 0 || !imp || !types) return false;
    bool ok = true;
    for (int i = 0; i < count; i++) {
        ok = themer_add_method(cls, sels[i], imp, types) && ok;
    }
    return ok;
}

static uint64_t themer_remote_symbol_addr(const char *name)
{
    if (!name || !name[0]) return 0;
    uint64_t remoteName = r_alloc_str(name);
    if (!remoteName) return 0;
    uint64_t sym = r_dlsym_call(R_TIMEOUT, "dlsym",
                                (uint64_t)-2, remoteName, 0, 0, 0, 0, 0, 0);
    r_free(remoteName);
    return sym;
}

static bool themer_ensure_iconservices_loaded(void)
{
    if (r_is_objc_ptr(themer_lookup_class("ISBundleIdentifierIcon")) &&
        r_is_objc_ptr(themer_lookup_class("ISImageDescriptor")) &&
        r_is_objc_ptr(themer_lookup_class("ISIconManager")) &&
        r_is_objc_ptr(themer_lookup_class("IFImage"))) {
        return true;
    }

    uint64_t foundationPath = r_alloc_str("/System/Library/PrivateFrameworks/IconFoundation.framework/IconFoundation");
    if (foundationPath) {
        r_dlsym_call(R_TIMEOUT, "dlopen", foundationPath, 1, 0, 0, 0, 0, 0, 0);
        r_free(foundationPath);
    }

    uint64_t path = r_alloc_str("/System/Library/PrivateFrameworks/IconServices.framework/IconServices");
    if (!path) return false;
    uint64_t handle = r_dlsym_call(R_TIMEOUT, "dlopen", path, 1, 0, 0, 0, 0, 0, 0);
    r_free(path);
    (void)handle;

    return r_is_objc_ptr(themer_lookup_class("ISBundleIdentifierIcon")) &&
           r_is_objc_ptr(themer_lookup_class("ISImageDescriptor")) &&
           r_is_objc_ptr(themer_lookup_class("ISIconManager")) &&
           r_is_objc_ptr(themer_lookup_class("IFImage"));
}

static NSData *themer_rounded_png_data(NSData *bytes, const char *label)
{
    if (!bytes || bytes.length == 0 || bytes.length > kThemerMaxPngBytes) return bytes;
    // Header-declared dimensions are checked before any decode/render: a tiny
    // PNG can declare a huge canvas (review F-12). Rejected bytes are also
    // refused by themer_build_remote_uiimage_from_data.
    if (!SBLImageDataPassesPixelPreflight(bytes)) return bytes;

    @autoreleasepool {
        UIImage *src = [UIImage imageWithData:bytes];
        CGImageRef cg = src.CGImage;
        if (!src || !cg) return bytes;

        size_t width = CGImageGetWidth(cg);
        size_t height = CGImageGetHeight(cg);
        if (width < 2 || height < 2) return bytes;

        CGSize size = CGSizeMake((CGFloat)width, (CGFloat)height);
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = 1.0;
        format.opaque = NO;

        CGFloat radius = (CGFloat)MIN(width, height) * 0.225;
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
        UIImage *rounded = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            (void)ctx;
            CGRect rect = CGRectMake(0, 0, size.width, size.height);
            [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius] addClip];
            [src drawInRect:rect];
        }];

        NSData *out = UIImagePNGRepresentation(rounded);
        if (out.length > 0 && out.length <= kThemerMaxPngBytes) return out;

        if (out.length > kThemerMaxPngBytes) {
            printf("[THEMER] rounded PNG too large bundle=%s rounded=%lu original=%lu cap=%zu\n",
                   label ?: "?",
                   (unsigned long)out.length,
                   (unsigned long)bytes.length,
                   kThemerMaxPngBytes);
        }
        return bytes;
    }
}

static double themer_screen_scale(void)
{
    double scale = 3.0;
    uint64_t UIScreen = r_class("UIScreen");
    uint64_t screen = r_is_objc_ptr(UIScreen)
        ? r_msg2(UIScreen, "mainScreen", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(screen) && r_responds_main(screen, "scale")) {
        uint64_t bits = r_msg2_main(screen, "scale", 0, 0, 0, 0);
        memcpy(&scale, &bits, sizeof(scale));
    }
    if (scale < 1.0 || scale > 4.0) scale = 3.0;
    return scale;
}

static uint64_t themer_make_is_descriptor(double pointSize,
                                          double scale,
                                          int64_t appearance,
                                          uint64_t variant,
                                          bool useVariantFactory)
{
    uint64_t descCls = themer_lookup_class("ISImageDescriptor");
    if (!r_is_objc_ptr(descCls)) return 0;

    uint64_t desc = 0;
    if (useVariantFactory &&
        r_responds_main(descCls, "imageDescriptorWithIconVariant:options:")) {
        desc = r_msg2_main(descCls, "imageDescriptorWithIconVariant:options:",
                           variant, 0, 0, 0);
        if (r_is_objc_ptr(desc))
            desc = r_msg2(desc, "retain", 0, 0, 0, 0);
    }

    if (!r_is_objc_ptr(desc)) {
        uint64_t alloc = r_msg2(descCls, "alloc", 0, 0, 0, 0);
        struct { double width; double height; } size = { pointSize, pointSize };
        desc = r_is_objc_ptr(alloc)
            ? r_msg2_main_raw(alloc, "initWithSize:scale:",
                              &size, sizeof(size),
                              &scale, sizeof(scale),
                              NULL, 0, NULL, 0)
            : 0;
    }
    if (!r_is_objc_ptr(desc)) return 0;

    struct { double width; double height; } size = { pointSize, pointSize };
    if (r_responds_main(desc, "setSize:")) {
        r_msg2_main_raw(desc, "setSize:",
                        &size, sizeof(size),
                        NULL, 0, NULL, 0, NULL, 0);
    }
    if (r_responds_main(desc, "setScale:")) {
        r_msg2_main_raw(desc, "setScale:",
                        &scale, sizeof(scale),
                        NULL, 0, NULL, 0, NULL, 0);
    }
    if (r_responds_main(desc, "setAppearance:")) {
        r_msg2_main(desc, "setAppearance:", (uint64_t)appearance, 0, 0, 0);
    }
    if (r_responds_main(desc, "setAppearanceVariant:")) {
        r_msg2_main(desc, "setAppearanceVariant:", (uint64_t)appearance, 0, 0, 0);
    }
    if (r_responds_main(desc, "setIgnoreCache:")) {
        r_msg2_main(desc, "setIgnoreCache:", 0, 0, 0, 0);
    }
    return desc;
}

static uint64_t themer_make_if_image(uint64_t uiImage)
{
    if (!r_is_objc_ptr(uiImage)) return 0;

    uint64_t IFImage = themer_lookup_class("IFImage");
    if (!r_is_objc_ptr(IFImage)) return 0;

    uint64_t cgImage = r_responds_main(uiImage, "CGImage")
        ? r_msg2_main(uiImage, "CGImage", 0, 0, 0, 0) : 0;
    if (!cgImage) return 0;

    double scale = themer_screen_scale();
    if (r_responds_main(uiImage, "scale")) {
        uint64_t bits = r_msg2_main(uiImage, "scale", 0, 0, 0, 0);
        memcpy(&scale, &bits, sizeof(scale));
        if (scale < 1.0 || scale > 4.0) scale = themer_screen_scale();
    }

    uint64_t alloc = r_msg2(IFImage, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(alloc)) return 0;
    return r_msg2_main_raw(alloc, "initWithCGImage:scale:",
                           &cgImage, sizeof(cgImage),
                           &scale, sizeof(scale),
                           NULL, 0, NULL, 0);
}

static int themer_seed_iconservices_cache(const char *bundle,
                                          uint64_t image,
                                          double pointSize)
{
    if (!bundle || !bundle[0] || !r_is_objc_ptr(image)) return 0;
    if (!themer_ensure_iconservices_loaded()) return 0;

    uint64_t bid = r_nsstr_retained(bundle);
    uint64_t iconCls = themer_lookup_class("ISBundleIdentifierIcon");
    uint64_t mgrCls = themer_lookup_class("ISIconManager");
    if (!r_is_objc_ptr(bid) || !r_is_objc_ptr(iconCls) || !r_is_objc_ptr(mgrCls)) {
        if (r_is_objc_ptr(bid)) r_msg2(bid, "release", 0, 0, 0, 0);
        return 0;
    }

    uint64_t iconAlloc = r_msg2(iconCls, "alloc", 0, 0, 0, 0);
    uint64_t icon = r_is_objc_ptr(iconAlloc)
        ? r_msg2_main(iconAlloc, "initWithBundleIdentifier:", bid, 0, 0, 0)
        : 0;
    r_msg2(bid, "release", 0, 0, 0, 0);
    if (!r_is_objc_ptr(icon)) return 0;

    uint64_t mgr = r_msg2(mgrCls, "sharedInstance", 0, 0, 0, 0);
    uint64_t createdIcon = icon;
    uint64_t registered = (r_is_objc_ptr(mgr) &&
                           r_responds_main(mgr, "findOrRegisterIcon:"))
        ? r_msg2_main(mgr, "findOrRegisterIcon:", icon, 0, 0, 0) : 0;
    if (r_is_objc_ptr(registered) && registered != icon) {
        r_msg2(icon, "release", 0, 0, 0, 0);
        icon = registered;
    }

    uint64_t imageCache = r_responds_main(icon, "imageCache")
        ? r_msg2_main(icon, "imageCache", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(imageCache) ||
        !r_responds_main(imageCache, "setImage:forDescriptor:")) {
        if (icon == createdIcon) r_msg2(icon, "release", 0, 0, 0, 0);
        return 0;
    }

    uint64_t cacheImage = themer_make_if_image(image);
    if (!r_is_objc_ptr(cacheImage)) {
        if (icon == createdIcon) r_msg2(icon, "release", 0, 0, 0, 0);
        return 0;
    }

    double scale = themer_screen_scale();
    if (pointSize < 20.0 || pointSize > 120.0) pointSize = 60.0;

    // Notifications (UserNotificationsUIKit, in SpringBoard) load their app
    // icon once per request through _NCIconImageForApplicationIdentifierWithFormat:
    // a plain initWithSize:scale: descriptor, appearance 0 (light) or 1 (dark),
    // 38 pt for banners and the badge on a communication notification's
    // avatar, 40 / 56 pt for other formats. IFImageBag prefers an exact size,
    // so a 38 pt image cached before theming beat the 60 pt seed; seeding
    // these sizes replaces it (insertImage: swaps an equal size). Plain
    // descriptors only: that is what the notification code builds.
    double sizes[5] = { pointSize, 60.0, 38.0, 40.0, 56.0 };
    int seeded = 0;
    int readbackHits = 0;
    bool checkedReadback = false;
    for (int s = 0; s < 5; s++) {
        bool duplicate = false;
        for (int p = 0; p < s; p++) if (sizes[p] == sizes[s]) duplicate = true;
        if (duplicate) continue;
        for (int appearance = 0; appearance <= 1; appearance++) {
            for (int variant = 0; variant < (s < 2 ? 2 : 1); variant++) {
                uint64_t desc = themer_make_is_descriptor(sizes[s], scale,
                                                          appearance,
                                                          (uint64_t)variant,
                                                          variant != 0);
                if (!r_is_objc_ptr(desc)) continue;
                r_msg2_main(imageCache, "setImage:forDescriptor:",
                            cacheImage, desc, 0, 0);
                seeded++;

                uint64_t readback = (!checkedReadback &&
                                      r_responds_main(icon, "imageForDescriptor:"))
                    ? r_msg2_main(icon, "imageForDescriptor:", desc, 0, 0, 0) : 0;
                checkedReadback = true;
                if (readback == cacheImage) readbackHits++;
                r_msg2(desc, "release", 0, 0, 0, 0);
            }
        }
    }

    if (!gThemerIconServicesProbeLogged) {
        gThemerIconServicesProbeLogged = true;
        uint64_t cachePath = 0;
        uint64_t iconCache = (r_is_objc_ptr(mgr) && r_responds_main(mgr, "iconCache"))
            ? r_msg2_main(mgr, "iconCache", 0, 0, 0, 0) : 0;
        if (r_is_objc_ptr(iconCache) && r_responds_main(iconCache, "cachePath")) {
            cachePath = r_msg2_main(iconCache, "cachePath", 0, 0, 0, 0);
        }
        char cachePathStr[240] = {0};
        if (r_is_objc_ptr(cachePath)) {
            r_read_nsstring(cachePath, cachePathStr, sizeof(cachePathStr));
        }
        printf("[THEMER] IconServices seed probe bundle=%s icon=0x%llx imageCache=0x%llx "
               "ifImage=0x%llx seeded=%d readback=%d pointSize=%.1f scale=%.1f cachePath=\"%s\"\n",
               bundle,
               (unsigned long long)icon,
               (unsigned long long)imageCache,
               (unsigned long long)cacheImage,
               seeded, readbackHits,
               pointSize, scale,
               cachePathStr);
    }

    r_msg2(cacheImage, "release", 0, 0, 0, 0);
    if (icon == createdIcon) r_msg2(icon, "release", 0, 0, 0, 0);
    return seeded;
}

// Ships PNG bytes into SB and returns a retained SB UIImage* (+1 owned by
// caller). `label` is just for log output (e.g. "com.apple.mobilesafari").
static uint64_t themer_build_remote_uiimage_from_data(NSData *bytes, const char *label)
{
    if (!bytes || bytes.length == 0 || bytes.length > kThemerMaxPngBytes) {
        printf("[THEMER] PNG size out of range label=%s size=%lu cap=%zu\n",
               label ?: "?",
               (unsigned long)bytes.length,
               kThemerMaxPngBytes);
        return 0;
    }
    if (!SBLImageDataPassesPixelPreflight(bytes)) {
        printf("[THEMER] PNG dimensions rejected label=%s size=%lu\n",
               label ?: "?", (unsigned long)bytes.length);
        return 0;
    }

    uint64_t remoteBuf = r_dlsym_call(R_TIMEOUT, "malloc",
                                      bytes.length, 0, 0, 0, 0, 0, 0, 0);
    if (!remoteBuf) {
        printf("[THEMER] remote malloc(%lu) failed label=%s\n",
               (unsigned long)bytes.length, label ?: "?");
        return 0;
    }
    if (!remote_write(remoteBuf, bytes.bytes, bytes.length)) {
        printf("[THEMER] remote_write failed buf=0x%llx size=%lu label=%s\n",
               (unsigned long long)remoteBuf, (unsigned long)bytes.length, label ?: "?");
        r_free(remoteBuf);
        return 0;
    }

    uint64_t NSDataCls  = r_class("NSData");
    uint64_t UIImageCls = r_class("UIImage");
    if (!r_is_objc_ptr(NSDataCls) || !r_is_objc_ptr(UIImageCls)) {
        printf("[THEMER] missing class NSData=0x%llx UIImage=0x%llx\n",
               (unsigned long long)NSDataCls,
               (unsigned long long)UIImageCls);
        r_free(remoteBuf);
        return 0;
    }

    uint64_t dataAlloc = r_msg2(NSDataCls, "alloc", 0, 0, 0, 0);
    uint64_t nsdata = r_is_objc_ptr(dataAlloc)
        ? r_msg2(dataAlloc, "initWithBytes:length:", remoteBuf, bytes.length, 0, 0)
        : 0;
    r_free(remoteBuf);  // NSData copied the bytes

    if (!r_is_objc_ptr(nsdata)) {
        printf("[THEMER] NSData init failed label=%s\n", label ?: "?");
        return 0;
    }

    uint64_t image = r_msg2(UIImageCls, "imageWithData:", nsdata, 0, 0, 0);
    if (r_is_objc_ptr(image))
        r_msg2(image, "retain", 0, 0, 0, 0);
    r_msg2(nsdata, "release", 0, 0, 0, 0);

    if (!r_is_objc_ptr(image)) {
        printf("[THEMER] UIImage decode failed for %s (PNG malformed?)\n",
               label ?: "?");
        return 0;
    }
    return image;
}

static uint64_t themer_ensure_datasource_class(void)
{
    static uint64_t cls = 0;
    if (r_is_objc_ptr(cls)) return cls;

    cls = themer_lookup_class("CNDIconLayerDataSource");
    if (r_is_objc_ptr(cls)) return cls;

    uint64_t NSObject = r_class("NSObject");
    if (!r_is_objc_ptr(NSObject)) return 0;

    uint64_t name = r_alloc_str("CNDIconLayerDataSource");
    if (!name) return 0;
    cls = r_dlsym_call(R_TIMEOUT, "objc_allocateClassPair",
                       NSObject, name, 0, 0, 0, 0, 0, 0);
    r_free(name);
    if (!r_is_objc_ptr(cls)) return 0;

    uint64_t getAssocImp = themer_remote_symbol_addr("objc_getAssociatedObject");
    bool ok = getAssocImp &&
        themer_add_method(cls, "icon:imageWithInfo:traitCollection:options:",
                          getAssocImp, "@@:@@@Q") &&
        themer_add_method(cls, "icon:layerWithInfo:traitCollection:options:",
                          getAssocImp, "@@:@@@Q") &&
        themer_add_method(cls, "icon:displayNameForLocation:",
                          getAssocImp, "@@:@q") &&
        themer_add_method(cls, "icon:accessibilityLabelForLocation:",
                          getAssocImp, "@@:@q");

    r_dlsym_call(R_TIMEOUT, "objc_registerClassPair",
                 cls, 0, 0, 0, 0, 0, 0, 0);

    if (!ok) {
        printf("[THEMER] model graft: datasource class incomplete getAssoc=0x%llx\n",
               (unsigned long long)getAssocImp);
        return 0;
    }
    return cls;
}

static double themer_icon_width_for_view(uint64_t iconView)
{
    uint64_t iiv = r_ivar_value(iconView, "_iconImageView");
    if (!r_is_objc_ptr(iiv) && r_responds_main(iconView, "_iconImageView")) {
        iiv = r_msg2_main(iconView, "_iconImageView", 0, 0, 0, 0);
    }
    uint64_t layer = r_is_objc_ptr(iiv) && r_responds_main(iiv, "layer")
        ? r_msg2_main(iiv, "layer", 0, 0, 0, 0) : 0;
    struct { double x, y, w, h; } b = {0};
    if (r_is_objc_ptr(layer) &&
        r_responds_main(layer, "bounds") &&
        r_msg2_main_struct_ret(layer, "bounds", &b, sizeof(b),
            NULL, 0, NULL, 0, NULL, 0, NULL, 0) &&
        b.w > 1.0) {
        return b.w;
    }
    return 60.0;
}

static uint64_t themer_icon_image_view_for_iconview(uint64_t iconView)
{
    if (!r_is_objc_ptr(iconView)) return 0;
    uint64_t iiv = r_ivar_value(iconView, "_iconImageView");
    if (!r_is_objc_ptr(iiv) && r_responds_main(iconView, "_iconImageView")) {
        iiv = r_msg2_main(iconView, "_iconImageView", 0, 0, 0, 0);
    }
    return r_is_objc_ptr(iiv) ? iiv : 0;
}

static bool themer_icon_is_application_icon(uint64_t icon)
{
    if (!r_is_objc_ptr(icon)) return false;
    char cls[96] = {0};
    themer_read_class_name(icon, cls, sizeof(cls));
    return strstr(cls, "ApplicationIcon") != NULL &&
           strstr(cls, "WidgetIcon") == NULL &&
           strstr(cls, "FolderIcon") == NULL;
}

static uint64_t themer_application_icon_for_iconview(uint64_t iconView)
{
    if (!r_is_objc_ptr(iconView) || !r_responds_main(iconView, "icon")) return 0;
    uint64_t icon = r_msg2_main(iconView, "icon", 0, 0, 0, 0);
    return themer_icon_is_application_icon(icon) ? icon : 0;
}

static bool themer_should_pin_dynamic_overlay(const char *bundle, uint64_t iconView)
{
    int major = themer_host_ios_major();
    if (major > 0 && major < 26) return false;

    if (!r_is_objc_ptr(themer_application_icon_for_iconview(iconView))) return false;

    if (!bundle ||
        (strcmp(bundle, "com.apple.mobiletimer") != 0 &&
         strcmp(bundle, "com.apple.mobilecal") != 0)) {
        return false;
    }

    // Clock/Calendar use live renderers; only pin over their real app icon.
    // Widget icons can share nearby image-view classes and must never receive
    // these overlays.
    uint64_t iiv = themer_icon_image_view_for_iconview(iconView);
    char cls[128] = {0};
    themer_read_class_name(iiv, cls, sizeof(cls));
    return strstr(cls, "Clock") != NULL ||
           strstr(cls, "Calendar") != NULL;
}

static bool themer_prefers_view_level_overlay(const char *bundle)
{
    if (bundle &&
        (strcmp(bundle, "com.apple.mobiletimer") == 0 ||
         strcmp(bundle, "com.apple.mobilecal") == 0)) {
        return true;
    }
    return false;
}

static bool themer_needs_visible_push(const char *bundle)
{
    (void)bundle;
    // Keep SnowBoard Lite on the model/cache path. The visible setter path can
    // draw an extra image layer above SpringBoard's own rounded icon mask.
    return false;
}

static bool themer_should_push_visible_theme_icon(const char *bundle)
{
    if (!bundle || !bundle[0]) return false;

    int major = themer_host_ios_major();
    if (major > 0 && major < 26) {
        return themer_needs_visible_push(bundle);
    }
    if (major < 26) return false;

    // iOS 26 can report a successful model/cache graft while the mounted
    // SBIconView keeps drawing its old contents. For active SnowBoard Lite
    // themes, also push the current visible view so the user sees the theme
    // immediately; the model/cache graft still carries future layout redraws.
    NSDictionary<NSString *, NSData *> *activeData = gThemerActiveThemeDataByBundle;
    if (activeData.count == 0) return false;
    NSString *key = [NSString stringWithUTF8String:bundle];
    return key.length > 0 && activeData[key] != nil;
}

static NSDictionary<NSString *, NSData *> *themer_normalized_theme_data(NSDictionary<NSString *, NSData *> *input)
{
    if (input.count == 0) return @{};

    NSMutableDictionary<NSString *, NSData *> *out = [NSMutableDictionary dictionaryWithCapacity:input.count];
    NSUInteger aliases = 0;
    for (NSString *key in input) {
        NSData *data = input[key];
        if (![key isKindOfClass:NSString.class] ||
            ![data isKindOfClass:NSData.class] ||
            data.length == 0) {
            continue;
        }

        BOOL usedAlias = NO;
        NSArray<NSString *> *mappedTargets = CNDMappedIOSBundleIDsForIconName(key, &usedAlias);
        if (mappedTargets.count == 0) mappedTargets = @[key];
        for (NSString *target in mappedTargets) {
            if (target.length == 0 || out[target]) continue;
            out[target] = data;
            if (usedAlias) aliases++;
        }
    }

    if (aliases > 0 || out.count != input.count) {
        printf("[THEMER] normalized theme data entries=%lu -> %lu aliases=%lu\n",
               (unsigned long)input.count,
               (unsigned long)out.count,
               (unsigned long)aliases);
    }
    return out;
}

static bool themer_clear_overlay_on_object(uint64_t obj, uint64_t key)
{
    if (!r_is_objc_ptr(obj) || !key) return false;

    uint64_t overlay = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                    obj, key, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(overlay)) return false;

    if (r_responds_main(overlay, "setHidden:")) {
        r_msg2_main(overlay, "setHidden:", 1, 0, 0, 0);
    }
    if (r_responds_main(overlay, "removeFromSuperview")) {
        r_msg2_main(overlay, "removeFromSuperview", 0, 0, 0, 0);
    }
    r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                 obj, key, 0, 1, 0, 0, 0, 0);
    return true;
}

static bool themer_clear_dynamic_overlay(uint64_t iconView)
{
    if (!r_is_objc_ptr(iconView)) return false;
    uint64_t key = r_sel("cnd_themer_pinned_overlay");
    if (!key) return false;

    bool cleared = themer_clear_overlay_on_object(iconView, key);
    uint64_t iiv = themer_icon_image_view_for_iconview(iconView);
    cleared = themer_clear_overlay_on_object(iiv, key) || cleared;
    return cleared;
}

static bool themer_clear_visible_override(uint64_t iconView)
{
    if (!r_is_objc_ptr(iconView) ||
        !r_responds_main(iconView, "setOverrideImage:")) {
        return false;
    }

    uint64_t cur = r_responds_main(iconView, "overrideImage")
        ? r_msg2_main(iconView, "overrideImage", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(cur)) return false;

    r_msg2_main(iconView, "setOverrideImage:", 0, 0, 0, 0);
    if (r_responds_main(iconView, "setOverrideIconImageAppearance:")) {
        r_msg2_main(iconView, "setOverrideIconImageAppearance:", 0, 0, 0, 0);
    }
    if (r_responds_main(iconView, "_updateIconImageViewAnimated:")) {
        r_msg2_main(iconView, "_updateIconImageViewAnimated:", 0, 0, 0, 0);
    } else if (r_responds_main(iconView,
                               "_updateAfterManualIconImageInfoChangeInvalidatingLayout:")) {
        r_msg2_main(iconView,
                    "_updateAfterManualIconImageInfoChangeInvalidatingLayout:",
                    0, 0, 0, 0);
    }
    return true;
}

static bool themer_pin_dynamic_overlay(uint64_t iconView, uint64_t image,
                                       const char *bundle)
{
    if (!r_is_objc_ptr(iconView) || !r_is_objc_ptr(image)) return false;

    uint64_t iiv = themer_icon_image_view_for_iconview(iconView);
    if (!r_is_objc_ptr(iiv)) return false;
    bool viewLevel = themer_prefers_view_level_overlay(bundle);
    uint64_t overlayParent = viewLevel ? iconView : iiv;

    uint64_t key = r_sel("cnd_themer_pinned_overlay");
    if (!key) return false;

    uint64_t overlay = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                    iconView, key, 0, 0, 0, 0, 0, 0);
    uint64_t imageViewOverlay = r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                                             iiv, key, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(overlay) && r_is_objc_ptr(imageViewOverlay)) {
        overlay = imageViewOverlay;
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     iconView, key, overlay, 1, 0, 0, 0, 0);
    } else if (r_is_objc_ptr(overlay) && r_is_objc_ptr(imageViewOverlay) &&
               overlay != imageViewOverlay) {
        themer_clear_overlay_on_object(iiv, key);
    }

    bool created = false;
    if (!r_is_objc_ptr(overlay)) {
        uint64_t overlayCls = r_class("UIImageView");
        uint64_t alloc = r_is_objc_ptr(overlayCls)
            ? r_msg2(overlayCls, "alloc", 0, 0, 0, 0) : 0;
        overlay = r_is_objc_ptr(alloc)
            ? r_msg2_main(alloc, "initWithImage:", image, 0, 0, 0) : 0;
        if (!r_is_objc_ptr(overlay)) return false;

        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     iconView, key, overlay, 1, 0, 0, 0, 0);
        r_msg2(overlay, "release", 0, 0, 0, 0);
        created = true;
    } else if (r_responds_main(overlay, "setImage:")) {
        r_msg2_main(overlay, "setImage:", image, 0, 0, 0);
    }

    r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                 iiv, key, overlay, 1, 0, 0, 0, 0);
    if (r_responds_main(overlay, "removeFromSuperview")) {
        r_msg2_main(overlay, "removeFromSuperview", 0, 0, 0, 0);
    }
    if (r_responds_main(overlayParent, "addSubview:")) {
        r_msg2_main(overlayParent, "addSubview:", overlay, 0, 0, 0);
    }

    struct { double x, y, w, h; } bounds = {0.0, 0.0, 0.0, 0.0};
    if (!r_responds_main(iiv, "bounds") ||
        !r_msg2_main_struct_ret(iiv, "bounds",
            &bounds, sizeof(bounds),
            NULL, 0, NULL, 0, NULL, 0, NULL, 0) ||
        bounds.w <= 1.0 || bounds.h <= 1.0) {
        double width = themer_icon_width_for_view(iconView);
        bounds.w = width;
        bounds.h = width;
    }
    if (viewLevel &&
        r_responds_main(iiv, "frame")) {
        struct { double x, y, w, h; } frame = {0.0, 0.0, 0.0, 0.0};
        if (r_msg2_main_struct_ret(iiv, "frame",
            &frame, sizeof(frame),
            NULL, 0, NULL, 0, NULL, 0, NULL, 0) &&
            frame.w > 1.0 && frame.h > 1.0) {
            bounds.x = frame.x;
            bounds.y = frame.y;
            bounds.w = frame.w;
            bounds.h = frame.h;
        }
    }

    if (r_responds_main(overlay, "setFrame:")) {
        r_msg2_main_raw(overlay, "setFrame:",
            &bounds, sizeof(bounds),
            NULL, 0, NULL, 0, NULL, 0);
    }
    if (r_responds_main(overlay, "setBounds:")) {
        struct { double x, y, w, h; } localBounds = {0.0, 0.0, bounds.w, bounds.h};
        r_msg2_main_raw(overlay, "setBounds:",
            &localBounds, sizeof(localBounds),
            NULL, 0, NULL, 0, NULL, 0);
    }
    if (r_responds_main(overlay, "setAutoresizingMask:")) {
        r_msg2_main(overlay, "setAutoresizingMask:", 18, 0, 0, 0);
    }
    if (r_responds_main(overlay, "setUserInteractionEnabled:")) {
        r_msg2_main(overlay, "setUserInteractionEnabled:", 0, 0, 0, 0);
    }
    if (r_responds_main(overlay, "setContentMode:")) {
        r_msg2_main(overlay, "setContentMode:", 0, 0, 0, 0);
    }
    if (r_responds_main(overlay, "setHidden:")) {
        r_msg2_main(overlay, "setHidden:", 0, 0, 0, 0);
    }
    if (r_responds_main(overlayParent, "bringSubviewToFront:")) {
        r_msg2_main(overlayParent, "bringSubviewToFront:", overlay, 0, 0, 0);
    }

    uint64_t layer = r_responds_main(overlay, "layer")
        ? r_msg2_main(overlay, "layer", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(layer)) {
        double radius = bounds.w > 1.0 ? bounds.w * 0.225 : 15.0;
        if (r_responds_main(layer, "setCornerRadius:")) {
            r_msg2_main_raw(layer, "setCornerRadius:",
                &radius, sizeof(radius),
                NULL, 0, NULL, 0, NULL, 0);
        }
        if (r_responds_main(layer, "setMasksToBounds:")) {
            r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
        }
    }

    static bool logged = false;
    if (!logged) {
        logged = true;
        char iivCls[128] = {0};
        themer_read_class_name(iiv, iivCls, sizeof(iivCls));
        printf("[THEMER] dynamic overlay pinned bundle=%s iconView=0x%llx "
               "iiv=0x%llx (%s) overlay=0x%llx viewLevel=%d created=%d\n",
               bundle ?: "?",
               (unsigned long long)iconView,
               (unsigned long long)iiv,
               iivCls,
               (unsigned long long)overlay,
               viewLevel,
               created);
    }

    return true;
}

static uint64_t themer_make_datasource(uint64_t image, double width)
{
    if (!r_is_objc_ptr(image)) return 0;
    uint64_t dsCls = themer_ensure_datasource_class();
    if (!r_is_objc_ptr(dsCls)) return 0;

    uint64_t alloc = r_msg2(dsCls, "alloc", 0, 0, 0, 0);
    uint64_t ds = r_is_objc_ptr(alloc)
        ? r_msg2_main(alloc, "init", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(ds)) return 0;

    uint64_t layerCls = r_class("CALayer");
    uint64_t layerAlloc = r_is_objc_ptr(layerCls)
        ? r_msg2(layerCls, "alloc", 0, 0, 0, 0) : 0;
    uint64_t layer = r_is_objc_ptr(layerAlloc)
        ? r_msg2_main(layerAlloc, "init", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(layer)) {
        r_msg2(ds, "release", 0, 0, 0, 0);
        return 0;
    }

    uint64_t cgImage = r_responds_main(image, "CGImage")
        ? r_msg2_main(image, "CGImage", 0, 0, 0, 0) : 0;
    if (cgImage && r_responds_main(layer, "setContents:")) {
        r_msg2_main(layer, "setContents:", cgImage, 0, 0, 0);
    }

    struct { double x, y, w, h; } bounds = {0.0, 0.0, width, width};
    if (r_responds_main(layer, "setBounds:")) {
        r_msg2_main_raw(layer, "setBounds:",
            &bounds, sizeof(bounds),
            NULL, 0, NULL, 0, NULL, 0);
    }

    double radius = width * 0.225;
    if (r_responds_main(layer, "setCornerRadius:")) {
        r_msg2_main_raw(layer, "setCornerRadius:",
            &radius, sizeof(radius),
            NULL, 0, NULL, 0, NULL, 0);
    }
    if (r_responds_main(layer, "setMasksToBounds:")) {
        r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
    }

    double scale = 3.0;
    uint64_t UIScreen = r_class("UIScreen");
    uint64_t screen = r_is_objc_ptr(UIScreen)
        ? r_msg2(UIScreen, "mainScreen", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(screen) && r_responds_main(screen, "scale")) {
        uint64_t bits = r_msg2_main(screen, "scale", 0, 0, 0, 0);
        memcpy(&scale, &bits, sizeof(scale));
    }
    if (r_responds_main(layer, "setContentsScale:")) {
        r_msg2_main_raw(layer, "setContentsScale:",
            &scale, sizeof(scale),
            NULL, 0, NULL, 0, NULL, 0);
    }

    uint64_t imageSel = r_sel("icon:imageWithInfo:traitCollection:options:");
    if (imageSel) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     ds, imageSel, image, 1, 0, 0, 0, 0);
    }
    uint64_t layerSel = r_sel("icon:layerWithInfo:traitCollection:options:");
    if (layerSel) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     ds, layerSel, layer, 1, 0, 0, 0, 0);
    }
    r_msg2(layer, "release", 0, 0, 0, 0);
    return ds;
}

static uint64_t themer_make_icon_layer(uint64_t image, double width)
{
    if (!r_is_objc_ptr(image)) return 0;

    uint64_t layerCls = r_class("CALayer");
    uint64_t layerAlloc = r_is_objc_ptr(layerCls)
        ? r_msg2(layerCls, "alloc", 0, 0, 0, 0) : 0;
    uint64_t layer = r_is_objc_ptr(layerAlloc)
        ? r_msg2_main(layerAlloc, "init", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(layer)) return 0;

    uint64_t cgImage = r_responds_main(image, "CGImage")
        ? r_msg2_main(image, "CGImage", 0, 0, 0, 0) : 0;
    if (cgImage && r_responds_main(layer, "setContents:")) {
        r_msg2_main(layer, "setContents:", cgImage, 0, 0, 0);
    }

    struct { double x, y, w, h; } bounds = {0.0, 0.0, width, width};
    if (r_responds_main(layer, "setBounds:")) {
        r_msg2_main_raw(layer, "setBounds:",
            &bounds, sizeof(bounds),
            NULL, 0, NULL, 0, NULL, 0);
    }

    double radius = width * 0.225;
    if (r_responds_main(layer, "setCornerRadius:")) {
        r_msg2_main_raw(layer, "setCornerRadius:",
            &radius, sizeof(radius),
            NULL, 0, NULL, 0, NULL, 0);
    }
    if (r_responds_main(layer, "setMasksToBounds:")) {
        r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
    }

    double scale = 3.0;
    uint64_t UIScreen = r_class("UIScreen");
    uint64_t screen = r_is_objc_ptr(UIScreen)
        ? r_msg2(UIScreen, "mainScreen", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(screen) && r_responds_main(screen, "scale")) {
        uint64_t bits = r_msg2_main(screen, "scale", 0, 0, 0, 0);
        memcpy(&scale, &bits, sizeof(scale));
    }
    if (r_responds_main(layer, "setContentsScale:")) {
        r_msg2_main_raw(layer, "setContentsScale:",
            &scale, sizeof(scale),
            NULL, 0, NULL, 0, NULL, 0);
    }

    return layer;
}

static uint64_t themer_copy_icon_label(uint64_t icon)
{
    if (!r_is_objc_ptr(icon)) return 0;

    uint64_t label = 0;
    if (r_responds_main(icon, "displayNameForLocation:")) {
        label = r_msg2_main(icon, "displayNameForLocation:", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(label) && r_responds_main(icon, "displayName")) {
        label = r_msg2_main(icon, "displayName", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(label) && r_responds_main(icon, "application")) {
        uint64_t app = r_msg2_main(icon, "application", 0, 0, 0, 0);
        if (r_is_objc_ptr(app) && r_responds_main(app, "displayName")) {
            label = r_msg2_main(app, "displayName", 0, 0, 0, 0);
        }
    }
    if (!r_is_objc_ptr(label)) return 0;
    return r_msg2(label, "copy", 0, 0, 0, 0);
}

static void themer_seed_datasource_metadata(uint64_t ds, uint64_t icon)
{
    if (!r_is_objc_ptr(ds) || !r_is_objc_ptr(icon)) return;

    uint64_t label = themer_copy_icon_label(icon);
    if (!r_is_objc_ptr(label)) return;

    uint64_t displaySel = r_sel("icon:displayNameForLocation:");
    if (displaySel) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     ds, displaySel, label, 1, 0, 0, 0, 0);
    }
    uint64_t axSel = r_sel("icon:accessibilityLabelForLocation:");
    if (axSel) {
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     ds, axSel, label, 1, 0, 0, 0, 0);
    }
    r_msg2(label, "release", 0, 0, 0, 0);
}

static uint64_t themer_ensure_model_class(uint64_t currentClass)
{
    if (!r_is_objc_ptr(currentClass)) return 0;

    uint64_t baseClass = currentClass;
    char clsName[160] = {0};
    themer_read_class_object_name(baseClass, clsName, sizeof(clsName));
    while (strncmp(clsName, "CNDThemed", 9) == 0) {
        uint64_t superCls = r_dlsym_call(R_TIMEOUT, "class_getSuperclass",
                                         baseClass, 0, 0, 0, 0, 0, 0, 0);
        if (!r_is_objc_ptr(superCls) || superCls == baseClass) break;
        baseClass = superCls;
        themer_read_class_object_name(baseClass, clsName, sizeof(clsName));
    }
    if (!clsName[0]) return 0;

    char subName[192] = {0};
    snprintf(subName, sizeof(subName), "CNDThemedV7_%s", clsName);

    uint64_t sub = themer_lookup_class(subName);
    if (r_is_objc_ptr(sub)) return sub;

    uint64_t name = r_alloc_str(subName);
    if (!name) return 0;
    sub = r_dlsym_call(R_TIMEOUT, "objc_allocateClassPair",
                       baseClass, name, 0, 0, 0, 0, 0, 0);
    r_free(name);
    if (!r_is_objc_ptr(sub)) return 0;

    uint64_t getAssocImp = themer_remote_symbol_addr("objc_getAssociatedObject");

    static const char *imageSels[] = {
        "makeIconImageWithInfo:traitCollection:context:options:",
        "iconImageWithInfo:traitCollection:context:options:",
    };
    static const char *imageSels3[] = {
        "iconImageWithInfo:traitCollection:options:",
    };

    bool ok = getAssocImp &&
        themer_add_methods(sub, imageSels, 2, getAssocImp, "@@:@@@Q") &&
        themer_add_methods(sub, imageSels3, 1, getAssocImp, "@@:@@Q");

    r_dlsym_call(R_TIMEOUT, "objc_registerClassPair",
                 sub, 0, 0, 0, 0, 0, 0, 0);

    if (!ok) {
        printf("[THEMER] model graft: subclass incomplete %s getAssoc=0x%llx\n",
               subName,
               (unsigned long long)getAssocImp);
        return 0;
    }
    return sub;
}

static bool themer_graft_icon_model(uint64_t icon, uint64_t image,
                                    ThemerEntry *entry, uint64_t iconView,
                                    bool *changedOut)
{
    if (changedOut) *changedOut = false;
    if (!r_is_objc_ptr(icon) || !r_is_objc_ptr(image) || !entry) return false;

    uint64_t currentClass = r_dlsym_call(R_TIMEOUT, "object_getClass",
                                         icon, 0, 0, 0, 0, 0, 0, 0);
    uint64_t themedClass = themer_ensure_model_class(currentClass);
    if (!r_is_objc_ptr(themedClass)) return false;

    static const char *imageSels[] = {
        "makeIconImageWithInfo:traitCollection:context:options:",
        "iconImageWithInfo:traitCollection:context:options:",
        "iconImageWithInfo:traitCollection:options:",
    };
    for (int i = 0; i < 3; i++) {
        uint64_t sel = r_sel(imageSels[i]);
        if (!sel) return false;
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     icon, sel, image, 1, 0, 0, 0, 0);
    }
    (void)iconView;

    if (themedClass != currentClass) {
        r_dlsym_call(R_TIMEOUT, "object_setClass",
                     icon, themedClass, 0, 0, 0, 0, 0, 0);
        if (changedOut) *changedOut = true;
    }

    if (!gThemerModelProbeLogged) {
        gThemerModelProbeLogged = true;
        printf("[THEMER] model graft: icon=0x%llx class=0x%llx changed=%d imageOnly=1\n",
               (unsigned long long)icon,
               (unsigned long long)themedClass,
               changedOut ? *changedOut : false);
    }

    return true;
}

static int themer_notify_icon_image_changed(uint64_t icon)
{
    if (!r_is_objc_ptr(icon)) return 0;

    int called = 0;
    static const char *selectors[] = {
        "purgeCachedImages",
        "clearCachedImages",
        "invalidateIconImageCache",
        "_invalidateIconImageCache",
        "reloadIconImage",
        "_reloadIconImage",
        "noteIconImageDidChange",
        "_noteIconImageDidChange",
    };

    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        const char *sel = selectors[i];
        if (!r_responds_main(icon, sel)) continue;
        r_msg2_main(icon, sel, 0, 0, 0, 0);
        called++;
    }
    return called;
}

// Resolve the bundle identifier for an app SBIconView/SBIcon.
static bool themer_read_bundle_for_icon(uint64_t icon,
                                        uint64_t probeIconView,
                                        char *out, size_t outLen)
{
    if (!r_is_objc_ptr(icon) || !out || outLen == 0) return false;

    // Try the SBHApplication path first. On iOS 26 the older leaf identifier
    // selectors can report support but return non-NSString/private values.
    uint64_t appObj = r_responds(icon, "application")
        ? r_msg2(icon, "application", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(appObj) && r_responds(appObj, "bundleIdentifier")) {
        uint64_t bid = r_msg2(appObj, "bundleIdentifier", 0, 0, 0, 0);
        if (r_is_objc_ptr(bid) && r_read_nsstring(bid, out, outLen) && out[0]) {
            themer_cache_icon_bundle(icon, out);
            return true;
        }
    }

    if (themer_lookup_icon_bundle(icon, out, outLen)) {
        static int fallbackLogs = 0;
        if (fallbackLogs < 8) {
            printf("[THEMER] model bundle fallback icon=0x%llx bundle=%s\n",
                   (unsigned long long)icon, out);
            fallbackLogs++;
        }
        return true;
    }

    // First-iconView verbose probe: keep this to the known-stable application
    // path. Calling object_getClass on legacy selector returns can PAC-crash
    // SpringBoard when a selector returns a private non-object payload.
    static bool probedShape = false;
    if (!probedShape) {
        probedShape = true;
        char ivCls[96] = {0}, iconCls[96] = {0};
        if (r_is_objc_ptr(probeIconView)) themer_read_class_name(probeIconView, ivCls, sizeof(ivCls));
        themer_read_class_name(icon, iconCls, sizeof(iconCls));
        printf("[THEMER] probe iconView class=%s icon=0x%llx class=%s\n",
               ivCls, (unsigned long long)icon, iconCls);
        if (r_is_objc_ptr(appObj)) {
            char appCls[96] = {0};
            themer_read_class_name(appObj, appCls, sizeof(appCls));
            bool appHasBID = r_responds(appObj, "bundleIdentifier");
            uint64_t appBID = appHasBID
                ? r_msg2(appObj, "bundleIdentifier", 0, 0, 0, 0) : 0;
            char appBIDStr[160] = {0};
            if (r_is_objc_ptr(appBID)) r_read_nsstring(appBID, appBIDStr, sizeof(appBIDStr));
            printf("[THEMER]   application=0x%llx class=%s bundleIdentifier=\"%s\"\n",
                   (unsigned long long)appObj, appCls, appBIDStr);
        }
    }

    return false;
}

static bool themer_read_bundle_for_iconview(uint64_t iconView,
                                            char *out, size_t outLen)
{
    if (!r_is_objc_ptr(iconView) || !out || outLen == 0) return false;

    uint64_t icon = themer_application_icon_for_iconview(iconView);
    return themer_read_bundle_for_icon(icon, iconView, out, outLen);
}

// Rung 1: iOS 26 path —
//          setOverrideImage:                       (track the override slot)
//          + _iconImageView.updateImageContentsWithImage:imageAppearance:animated:
//            (or fallback: setDisplayedImage:)     (force the rendered pixels)
// Rung 2: setIconImage:           (iOS 18 and earlier)
// Rung 3: _setIconImage:          (private variant)
// Rung 4: _iconImageView.setImage: (last-resort UIImageView-style setter)
static bool gThemerInnerCanUpdateContents = false;
static bool gThemerInnerCanSetDisplayed = false;

static int themer_probe_rung(uint64_t iconView)
{
    if (gThemerRung >= 0) return gThemerRung;
    if (!r_is_objc_ptr(iconView)) return -1;

    bool r1 = r_responds_main(iconView, "setOverrideImage:");
    bool r2 = r_responds_main(iconView, "setIconImage:");
    bool r3 = r_responds_main(iconView, "_setIconImage:");

    uint64_t iiv = r_ivar_value(iconView, "_iconImageView");
    if (!r_is_objc_ptr(iiv) && r_responds_main(iconView, "_iconImageView")) {
        iiv = r_msg2_main(iconView, "_iconImageView", 0, 0, 0, 0);
    }
    bool r4 = r_is_objc_ptr(iiv) && r_responds_main(iiv, "setImage:");
    if (r_is_objc_ptr(iiv)) {
        gThemerInnerCanUpdateContents = r_responds_main(iiv,
            "updateImageContentsWithImage:imageAppearance:animated:");
        gThemerInnerCanSetDisplayed = r_responds_main(iiv, "setDisplayedImage:");
    }

    gThemerHasUpdateAfter = r_responds_main(iconView,
        "_updateAfterManualIconImageInfoChangeInvalidatingLayout:");
    gThemerHasUpdateImageView = r_responds_main(iconView,
        "_updateIconImageViewAnimated:");

    char iivCls[96] = {0};
    if (r_is_objc_ptr(iiv)) themer_read_class_name(iiv, iivCls, sizeof(iivCls));
    bool legacyVisible = themer_needs_visible_push(NULL);
    printf("[THEMER] probe iconView=0x%llx setOverrideImage:=%d setIconImage:=%d "
           "_setIconImage:=%d _iconImageView=0x%llx (%s) "
           "setImage:=%d updateContents:=%d setDisplayedImage:=%d "
           "update:=%d updateIV:=%d legacy=%d\n",
           (unsigned long long)iconView, r1, r2, r3,
           (unsigned long long)iiv, iivCls,
           r4, gThemerInnerCanUpdateContents, gThemerInnerCanSetDisplayed,
           gThemerHasUpdateAfter, gThemerHasUpdateImageView,
           legacyVisible);

    if (legacyVisible) {
        if (r2)      gThemerRung = 2;
        else if (r3) gThemerRung = 3;
        else if (r4) gThemerRung = 4;
        else if (r1) gThemerRung = 1;
        else         gThemerRung = 0;
    } else {
        if (r1)      gThemerRung = 1;
        else if (r2) gThemerRung = 2;
        else if (r3) gThemerRung = 3;
        else if (r4) gThemerRung = 4;
        else         gThemerRung = 0;
    }

    return gThemerRung;
}

// Returns the rung that succeeded (1/2/3/4) or 0 if nothing stuck.
static int themer_push_image(uint64_t iconView, uint64_t image)
{
    if (!r_is_objc_ptr(iconView) || !r_is_objc_ptr(image)) return 0;
    int rung = themer_probe_rung(iconView);

    switch (rung) {
        case 1: {
            // iOS 26 contents-path strategy (from RE of SpringBoardHome):
            //   shouldDisplayImageLayer is YES by default → sublayer path that
            //   ignores overrideImage. To force the flat contents path that
            //   DOES read overrideImage:
            //   1. Set overrideIconImageAppearance = +[SBHIconImageAppearance lightAppearance]
            //      (light = appearanceType 0/1 → hasGlass returns NO)
            //   2. Set iconImageView.showsSquareCorners = YES
            //   3. Now shouldDisplayImageLayer returns NO, and
            //      updateImageAnimated: takes updateImageContentsAnimated:,
            //      which calls updateImageContentsWithImage:imageAppearance:animated:
            //      using [iconView overrideImage].
            //   4. Set overrideImage = our UIImage (also triggers updateImageAnimated:NO).
            uint64_t iiv = r_ivar_value(iconView, "_iconImageView");
            if (!r_is_objc_ptr(iiv)) {
                iiv = r_msg2_main(iconView, "_iconImageView", 0, 0, 0, 0);
            }
            if (!r_is_objc_ptr(iiv)) break;

            // PERSISTENCE: populate SBHIconImageCache for this icon. The
            // home-screen render pipeline goes via SBIcon →
            // iconLayerViewWithInfo: → SBHIconImageVariantCache.cachedImage
            // → SBHIconImageAppearanceStore. Cache-populated images stick
            // across layout passes (page swipe, rotation) so home icons
            // don't revert. -[SBHIconImageCache cacheImage:forIcon:imageAppearance:]
            // calls through to setImage:forIcon:appearance: on the underlying
            // store plus bookkeeping.
            uint64_t icon = r_responds_main(iconView, "icon")
                ? r_msg2_main(iconView, "icon", 0, 0, 0, 0) : 0;
            uint64_t cache = r_responds_main(iiv, "iconImageCache")
                ? r_msg2_main(iiv, "iconImageCache", 0, 0, 0, 0) : 0;
            uint64_t appearance = r_responds_main(iiv, "effectiveIconImageAppearance")
                ? r_msg2_main(iiv, "effectiveIconImageAppearance", 0, 0, 0, 0) : 0;
            if (r_is_objc_ptr(cache) && r_is_objc_ptr(icon) &&
                r_is_objc_ptr(appearance) &&
                r_responds_main(cache, "cacheImage:forIcon:imageAppearance:")) {
                r_msg2_main(cache, "cacheImage:forIcon:imageAppearance:",
                            image, icon, appearance, 0);
            }

            uint64_t appearanceCls = r_class("SBHIconImageAppearance");
            uint64_t lightAppearance = r_is_objc_ptr(appearanceCls)
                ? r_msg2(appearanceCls, "lightAppearance", 0, 0, 0, 0) : 0;
            if (r_is_objc_ptr(lightAppearance) &&
                r_responds_main(iconView, "setOverrideIconImageAppearance:")) {
                r_msg2_main(iconView, "setOverrideIconImageAppearance:",
                            lightAppearance, 0, 0, 0);
            }
            if (r_responds_main(iiv, "setShowsSquareCorners:")) {
                r_msg2_main(iiv, "setShowsSquareCorners:", 1, 0, 0, 0);
            }
            r_msg2_main(iconView, "setOverrideImage:", image, 0, 0, 0);

            // App launch/resume can leave the SBIconView carrying our
            // overrideImage while its inner contents/layer was discarded.
            // Force the iOS 26 flat-contents path too, so a cached repaint
            // repairs that state even when setOverrideImage: sees the same
            // pointer it already had.
            uint64_t updateAppearance = r_is_objc_ptr(lightAppearance)
                ? lightAppearance : appearance;
            if (gThemerInnerCanUpdateContents && r_is_objc_ptr(updateAppearance) &&
                r_responds_main(iiv, "updateImageContentsWithImage:imageAppearance:animated:")) {
                r_msg2_main(iiv, "updateImageContentsWithImage:imageAppearance:animated:",
                            image, updateAppearance, 0, 0);
            } else if (gThemerInnerCanSetDisplayed &&
                       r_responds_main(iiv, "setDisplayedImage:")) {
                r_msg2_main(iiv, "setDisplayedImage:", image, 0, 0, 0);
            }

            // Also cache for the light appearance specifically, in case
            // future layout fetches request that variant (we've flipped the
            // override appearance to light, so the cache lookup key likely
            // ends up there).
            if (r_is_objc_ptr(cache) && r_is_objc_ptr(icon) &&
                r_is_objc_ptr(lightAppearance) &&
                r_responds_main(cache, "cacheImage:forIcon:imageAppearance:")) {
                r_msg2_main(cache, "cacheImage:forIcon:imageAppearance:",
                            image, icon, lightAppearance, 0);
            }

            // showsSquareCorners=YES exposed the full iconImageView bounds.
            // Reapply rounded mask on iiv.layer (~22.5% of width).
            uint64_t iivLayer = r_responds_main(iiv, "layer")
                ? r_msg2_main(iiv, "layer", 0, 0, 0, 0) : 0;
            if (r_is_objc_ptr(iivLayer)) {
                struct { double x, y, w, h; } b = {0};
                double radius = 15.0;
                if (r_responds_main(iivLayer, "bounds") &&
                    r_msg2_main_struct_ret(iivLayer, "bounds",
                        &b, sizeof(b),
                        NULL, 0, NULL, 0, NULL, 0, NULL, 0) &&
                    b.w > 0.0) {
                    radius = b.w * 0.225;
                }
                r_msg2_main_raw(iivLayer, "setCornerRadius:",
                    &radius, sizeof(radius),
                    NULL, 0, NULL, 0, NULL, 0);
                if (r_responds_main(iivLayer, "setMasksToBounds:")) {
                    r_msg2_main(iivLayer, "setMasksToBounds:", 1, 0, 0, 0);
                }
            }

            static bool postProbed = false;
            if (!postProbed) {
                postProbed = true;
                bool shouldDisplay = r_responds_main(iiv, "shouldDisplayImageLayer")
                    ? (r_msg2_main(iiv, "shouldDisplayImageLayer", 0, 0, 0, 0) & 0xff) != 0
                    : true;
                bool sqCorners = r_responds_main(iiv, "showsSquareCorners")
                    ? (r_msg2_main(iiv, "showsSquareCorners", 0, 0, 0, 0) & 0xff) != 0
                    : false;
                uint64_t effApp = r_responds_main(iiv, "effectiveIconImageAppearance")
                    ? r_msg2_main(iiv, "effectiveIconImageAppearance", 0, 0, 0, 0) : 0;
                bool hasGlass = (r_is_objc_ptr(effApp) && r_responds_main(effApp, "hasGlass"))
                    ? (r_msg2_main(effApp, "hasGlass", 0, 0, 0, 0) & 0xff) != 0
                    : true;
                uint64_t displayedRead = r_responds_main(iiv, "displayedImage")
                    ? r_msg2_main(iiv, "displayedImage", 0, 0, 0, 0) : 0;
                uint64_t overrideRead = r_responds_main(iconView, "overrideImage")
                    ? r_msg2_main(iconView, "overrideImage", 0, 0, 0, 0) : 0;
                char appCls[96] = {0};
                themer_read_class_name(effApp, appCls, sizeof(appCls));
                printf("[THEMER] post: shouldDisplayImageLayer=%d showsSquareCorners=%d "
                       "hasGlass=%d effApp=0x%llx (%s) displayed=0x%llx override=0x%llx "
                       "(want image=0x%llx) lightAppearance=0x%llx\n",
                       shouldDisplay, sqCorners, hasGlass,
                       (unsigned long long)effApp, appCls,
                       (unsigned long long)displayedRead,
                       (unsigned long long)overrideRead,
                       (unsigned long long)image,
                       (unsigned long long)lightAppearance);
            }
            break;
        }
        case 2:
            r_msg2_main(iconView, "setIconImage:", image, 0, 0, 0);
            break;
        case 3:
            r_msg2_main(iconView, "_setIconImage:", image, 0, 0, 0);
            break;
        case 4: {
            uint64_t iiv = r_ivar_value(iconView, "_iconImageView");
            if (!r_is_objc_ptr(iiv)) {
                iiv = r_msg2_main(iconView, "_iconImageView", 0, 0, 0, 0);
            }
            if (!r_is_objc_ptr(iiv)) return 0;
            r_msg2_main(iiv, "setImage:", image, 0, 0, 0);
            break;
        }
        default:
            return 0;
    }

    return rung;
}

static int themer_iter_iconviews(uint64_t listView,
                                 NSDictionary<NSString *, NSData *> *dataByBundle,
                                 uint64_t iconViewCls,
                                 int *rungHits,
                                 int *misses)
{
    if (!r_is_objc_ptr(listView) || !r_is_objc_ptr(iconViewCls)) return 0;

    // BFS the list view so we pick up SBIconViews regardless of how iOS 26
    // wraps them (AMUIInfographIconListLayout adds intermediate containers).
    enum { IV_CAP = 64 };
    uint64_t ivs[IV_CAP];
    int n = sb_collect_views_main(listView, iconViewCls, ivs, IV_CAP);

    if (n == 0) {
        if (gThemerLogBudget > 0) {
            uint64_t subs = r_msg2_main(listView, "subviews", 0, 0, 0, 0);
            uint64_t sc = r_is_objc_ptr(subs) ? r_msg2_main(subs, "count", 0, 0, 0, 0) : 0;
            char lvCls[96];
            themer_read_class_name(listView, lvCls, sizeof(lvCls));
            printf("[THEMER] listView=0x%llx class=%s no iconViews; direct subviews=%llu\n",
                   (unsigned long long)listView, lvCls, (unsigned long long)sc);
            uint64_t cap = sc > 6 ? 6 : sc;
            for (uint64_t i = 0; i < cap; i++) {
                uint64_t child = r_msg2_main(subs, "objectAtIndex:", i, 0, 0, 0);
                char cls[96] = {0};
                themer_read_class_name(child, cls, sizeof(cls));
                printf("[THEMER]   subview[%llu]=0x%llx class=%s\n",
                       (unsigned long long)i, (unsigned long long)child, cls);
            }
            gThemerLogBudget--;
        }
        return 0;
    }

    if (gThemerLogBudget > 0) {
        printf("[THEMER] listView=0x%llx iconViews=%d (BFS)\n",
               (unsigned long long)listView, n);
        gThemerLogBudget--;
    }

    int applied = 0;
    for (int i = 0; i < n; i++) {
        uint64_t v = ivs[i];
        if (!r_is_objc_ptr(v)) continue;

        char bundle[128] = {0};
        if (!themer_read_bundle_for_iconview(v, bundle, sizeof(bundle))) {
            themer_clear_dynamic_overlay(v);
            themer_clear_visible_override(v);
            if (gThemerLogBudget > 0) {
                char ivCls[96] = {0};
                themer_read_class_name(v, ivCls, sizeof(ivCls));
                printf("[THEMER]   bundle read failed iconView=0x%llx class=%s\n",
                       (unsigned long long)v, ivCls);
                gThemerLogBudget--;
            }
            continue;
        }

        // Debug: skip everything except the focus bundle so the log is
        // small enough to reason about.
        if (kThemerFocusBundle && kThemerFocusBundle[0] &&
            strcmp(bundle, kThemerFocusBundle) != 0) {
            continue;
        }

        bool dynamicOverlay = themer_should_pin_dynamic_overlay(bundle, v);
        bool visiblePush = themer_should_push_visible_theme_icon(bundle);
        if (!dynamicOverlay) themer_clear_visible_override(v);

        uint64_t image = themer_lookup_cached(bundle);
        if (!image) {
            NSString *key = [NSString stringWithUTF8String:bundle];
            NSData *pngBytes = key ? dataByBundle[key] : nil;
            if (!pngBytes) {
                themer_clear_dynamic_overlay(v);
                themer_clear_visible_override(v);
                if (misses) (*misses)++;
                if (gThemerLogBudget > 0) {
                    printf("[THEMER] miss bundle=%s (no override in theme)\n", bundle);
                    gThemerLogBudget--;
                }
                continue;
            }
            NSData *uploadBytes = themer_rounded_png_data(pngBytes, bundle);
            image = themer_build_remote_uiimage_from_data(uploadBytes ?: pngBytes, bundle);
            if (!image) {
                themer_clear_dynamic_overlay(v);
                themer_clear_visible_override(v);
                if (misses) (*misses)++;
                continue;
            }
            if (!themer_cache_image(bundle, image)) {
                r_msg2(image, "release", 0, 0, 0, 0);
                themer_clear_dynamic_overlay(v);
                themer_clear_visible_override(v);
                if (misses) (*misses)++;
                continue;
            }
            if (gThemerLogBudget > 0) {
                printf("[THEMER] built bundle=%s image=0x%llx\n",
                       bundle, (unsigned long long)image);
                gThemerLogBudget--;
            }
        }
        if (!dynamicOverlay) {
            themer_clear_dynamic_overlay(v);
            uint64_t icon = themer_application_icon_for_iconview(v);
            ThemerEntry *entry = themer_lookup_entry(bundle);
            if (entry && r_is_objc_ptr(icon)) {
                bool changed = false;
                if (themer_graft_icon_model(icon, image, entry, v, &changed)) {
                    (void)themer_notify_icon_image_changed(icon);
                    if (!entry->iconServicesSeeded) {
                        double iconWidth = themer_icon_width_for_view(v);
                        entry->iconServicesSeeded =
                            themer_seed_iconservices_cache(bundle, image, iconWidth) > 0;
                    }
                    applied++;
                }
            }
            if (!visiblePush && !themer_needs_visible_push(bundle)) {
                continue;
            }
        }

        // Most icons persist through the model/cache pass. Dynamic/special
        // icons keep a pinned overlay because their mounted image views can
        // redraw from private live renderers.
        bool viewLevelOverlay = themer_prefers_view_level_overlay(bundle);
        (void)viewLevelOverlay;
        int rung = 0;
        if (dynamicOverlay && themer_pin_dynamic_overlay(v, image, bundle)) {
            rung = 1;
        } else if (!dynamicOverlay &&
                   (visiblePush || themer_needs_visible_push(bundle))) {
            rung = themer_push_image(v, image);
        }

        ThemerEntry *entry = themer_lookup_entry(bundle);
        if (entry && !entry->iconServicesSeeded) {
            double iconWidth = themer_icon_width_for_view(v);
            entry->iconServicesSeeded =
                themer_seed_iconservices_cache(bundle, image, iconWidth) > 0;
        }
        if (rung > 0) {
            applied++;
            if (rungHits && rung >= 1 && rung <= 4) rungHits[rung - 1]++;
            if (kThemerDetailedIconLogs) {
                uint64_t superv = r_responds_main(v, "superview")
                    ? r_msg2_main(v, "superview", 0, 0, 0, 0) : 0;
                char supCls[96] = {0};
                themer_read_class_name(superv, supCls, sizeof(supCls));
                double alpha = 1.0;
                if (r_responds_main(v, "alpha")) {
                    r_msg2_main_struct_ret(v, "alpha", &alpha, sizeof(alpha),
                        NULL, 0, NULL, 0, NULL, 0, NULL, 0);
                }
                bool hidden = r_responds_main(v, "isHidden")
                    ? (r_msg2_main(v, "isHidden", 0, 0, 0, 0) & 0xff) != 0
                    : false;
                bool wasBorrowed = r_responds_main(v, "isIconImageViewBorrowed")
                    ? (r_msg2_main(v, "isIconImageViewBorrowed", 0, 0, 0, 0) & 0xff) != 0
                    : false;
                printf("[THEMER]   %s superview=%s borrowed=%d alpha=%.2f hidden=%d\n",
                       bundle, supCls, wasBorrowed, alpha, hidden);
            }
        } else {
            if (misses) (*misses)++;
            if (gThemerLogBudget > 0) {
                printf("[THEMER] no rung stuck bundle=%s iconView=0x%llx\n",
                       bundle, (unsigned long long)v);
                gThemerLogBudget--;
            }
        }
    }
    return applied;
}

static int themer_repaint_cached_iconviews(uint64_t listView,
                                           uint64_t iconViewCls,
                                           int *rungHits,
                                           int *misses,
                                           int *skips,
                                           bool force)
{
    if (!r_is_objc_ptr(listView) || !r_is_objc_ptr(iconViewCls)) return 0;

    enum { IV_CAP = 64 };
    uint64_t ivs[IV_CAP];
    int n = sb_collect_views_main(listView, iconViewCls, ivs, IV_CAP);
    int applied = 0;

    for (int i = 0; i < n; i++) {
        uint64_t v = ivs[i];
        if (!r_is_objc_ptr(v)) continue;

        char bundle[128] = {0};
        if (!themer_read_bundle_for_iconview(v, bundle, sizeof(bundle))) {
            themer_clear_dynamic_overlay(v);
            themer_clear_visible_override(v);
            if (misses) (*misses)++;
            continue;
        }

        uint64_t image = themer_lookup_cached(bundle);
        if (!r_is_objc_ptr(image)) {
            themer_clear_dynamic_overlay(v);
            themer_clear_visible_override(v);
            if (misses) (*misses)++;
            continue;
        }

        uint64_t overrideRead = r_responds_main(v, "overrideImage")
            ? r_msg2_main(v, "overrideImage", 0, 0, 0, 0) : 0;
        uint64_t iiv = r_ivar_value(v, "_iconImageView");
        if (!r_is_objc_ptr(iiv) && r_responds_main(v, "_iconImageView")) {
            iiv = r_msg2_main(v, "_iconImageView", 0, 0, 0, 0);
        }
        uint64_t displayedRead = (r_is_objc_ptr(iiv) &&
                                  r_responds_main(iiv, "displayedImage"))
            ? r_msg2_main(iiv, "displayedImage", 0, 0, 0, 0) : 0;
        bool dynamicOverlay = themer_should_pin_dynamic_overlay(bundle, v);
        bool visiblePush = themer_should_push_visible_theme_icon(bundle);
        if (!dynamicOverlay) themer_clear_visible_override(v);
        if (!force && !dynamicOverlay &&
            overrideRead == image && displayedRead == image) {
            themer_clear_dynamic_overlay(v);
            if (skips) (*skips)++;
            continue;
        }
        if (!dynamicOverlay) {
            themer_clear_dynamic_overlay(v);
            if (!visiblePush && !themer_needs_visible_push(bundle)) {
                if (skips) (*skips)++;
                continue;
            }
        }

        int rung = 0;
        if (dynamicOverlay && themer_pin_dynamic_overlay(v, image, bundle)) {
            rung = 1;
        } else if (!dynamicOverlay &&
                   (visiblePush || themer_needs_visible_push(bundle))) {
            rung = themer_push_image(v, image);
        }
        if (rung > 0) {
            applied++;
            if (rungHits && rung >= 1 && rung <= 4) rungHits[rung - 1]++;
        } else if (misses) {
            (*misses)++;
        }
    }

    return applied;
}

static int themer_repaint_dynamic_iconviews(uint64_t listView,
                                            uint64_t iconViewCls,
                                            int *rungHits,
                                            int *misses)
{
    if (!r_is_objc_ptr(listView) || !r_is_objc_ptr(iconViewCls)) return 0;

    enum { IV_CAP = 64 };
    uint64_t ivs[IV_CAP];
    int n = sb_collect_views_main(listView, iconViewCls, ivs, IV_CAP);
    int applied = 0;

    for (int i = 0; i < n; i++) {
        uint64_t v = ivs[i];
        if (!r_is_objc_ptr(v)) continue;

        char bundle[128] = {0};
        if (!themer_read_bundle_for_iconview(v, bundle, sizeof(bundle))) {
            if (misses) (*misses)++;
            continue;
        }
        if (!themer_should_pin_dynamic_overlay(bundle, v)) continue;

        uint64_t image = themer_lookup_cached(bundle);
        if (!r_is_objc_ptr(image)) {
            if (misses) (*misses)++;
            continue;
        }

        int rung = themer_pin_dynamic_overlay(v, image, bundle) ? 1 : 0;
        if (rung > 0) {
            applied++;
            if (rungHits) rungHits[0]++;
        } else if (misses) {
            (*misses)++;
        }
    }

    return applied;
}

static void themer_add_unique(uint64_t *items, int *count, int cap, uint64_t item)
{
    if (!r_is_objc_ptr(item) || !items || !count || *count >= cap) return;
    for (int i = 0; i < *count; i++) {
        if (items[i] == item) return;
    }
    items[(*count)++] = item;
}

static int themer_collect_model_lookup_roots(uint64_t *roots, int cap)
{
    if (!roots || cap <= 0) return 0;
    int count = 0;

    uint64_t controllerCls = r_class("SBIconController");
    uint64_t controller = (r_is_objc_ptr(controllerCls) &&
                           r_responds(controllerCls, "sharedInstance"))
        ? r_msg2(controllerCls, "sharedInstance", 0, 0, 0, 0) : 0;
    themer_add_unique(roots, &count, cap, controller);

    uint64_t managerCls = r_class("SBHIconManager");
    uint64_t manager = (r_is_objc_ptr(managerCls) &&
                        r_responds(managerCls, "sharedInstance"))
        ? r_msg2(managerCls, "sharedInstance", 0, 0, 0, 0) : 0;
    themer_add_unique(roots, &count, cap, manager);

    const char *childSels[] = {
        "model",
        "iconModel",
        "_iconModel",
        "rootFolder",
        "rootFolderController",
        "rootFolderViewController",
    };
    int initial = count;
    for (int i = 0; i < initial && count < cap; i++) {
        uint64_t root = roots[i];
        for (size_t s = 0; s < sizeof(childSels) / sizeof(childSels[0]) && count < cap; s++) {
            if (!r_responds_main(root, childSels[s])) continue;
            uint64_t child = r_msg2_main(root, childSels[s], 0, 0, 0, 0);
            themer_add_unique(roots, &count, cap, child);
        }
    }

    return count;
}

static uint64_t themer_lookup_model_icon_for_bundle(const char *bundle)
{
    if (!bundle || !bundle[0]) return 0;

    uint64_t bid = r_nsstr_retained(bundle);
    if (!r_is_objc_ptr(bid)) return 0;

    enum { ROOT_CAP = 24 };
    uint64_t roots[ROOT_CAP] = {0};
    int rootCount = themer_collect_model_lookup_roots(roots, ROOT_CAP);

    const char *lookupSels[] = {
        "applicationIconForBundleIdentifier:",
        "applicationIconForDisplayIdentifier:",
        "expectedIconForDisplayIdentifier:",
        "iconForApplicationIdentifier:",
        "iconForIdentifier:",
        "leafIconForIdentifier:",
        "_leafIconForIdentifier:",
        "iconWithIdentifier:",
    };

    static bool loggedShape = false;
    uint64_t found = 0;
    const char *foundSel = NULL;
    uint64_t foundRoot = 0;
    static int mismatchLogs = 0;
    for (int r = 0; r < rootCount && !found; r++) {
        uint64_t root = roots[r];
        for (size_t s = 0; s < sizeof(lookupSels) / sizeof(lookupSels[0]); s++) {
            const char *sel = lookupSels[s];
            if (!r_responds_main(root, sel)) continue;
            uint64_t icon = r_msg2_main(root, sel, bid, 0, 0, 0);
            if (!r_is_objc_ptr(icon)) continue;

            char actual[128] = {0};
            if (!themer_read_bundle_for_icon(icon, 0, actual, sizeof(actual)) ||
                strcmp(actual, bundle) != 0) {
                if (mismatchLogs < 8) {
                    printf("[THEMER] model lookup rejected requested=%s actual=%s "
                           "root=0x%llx selector=%s icon=0x%llx\n",
                           bundle,
                           actual[0] ? actual : "?",
                           (unsigned long long)root,
                           sel,
                           (unsigned long long)icon);
                    mismatchLogs++;
                }
                continue;
            }

            found = icon;
            foundSel = sel;
            foundRoot = root;
            break;
        }
    }
    r_msg2(bid, "release", 0, 0, 0, 0);

    if (!loggedShape) {
        loggedShape = true;
        printf("[THEMER] model lookup probe roots=%d firstBundle=%s root=0x%llx "
               "selector=%s icon=0x%llx\n",
               rootCount,
               bundle,
               (unsigned long long)foundRoot,
               foundSel ?: "(none)",
               (unsigned long long)found);
    }

    if (r_is_objc_ptr(found)) {
        themer_cache_icon_bundle(found, bundle);
    }

    return found;
}

// Find the shared SBHIconImageCache (and light/dark appearances) via a visible
// SBIconView's image view. The cache is keyed by icon, so populating it for an
// off-screen icon makes that icon render themed the moment its page is shown —
// no lock/unlock or app-cycle needed (issue #8).
static uint64_t themer_shared_icon_image_cache(uint64_t *lvs, int nlv)
{
    uint64_t iconViewCls = r_class("SBIconView");
    if (!r_is_objc_ptr(iconViewCls)) return 0;
    for (int i = 0; i < nlv; i++) {
        uint64_t subs = r_msg2_main(lvs[i], "subviews", 0, 0, 0, 0);
        if (!r_is_objc_ptr(subs)) continue;
        uint64_t n = r_msg2_main(subs, "count", 0, 0, 0, 0);
        if (n > 512) n = 512;
        for (uint64_t j = 0; j < n; j++) {
            uint64_t v = r_msg2_main(subs, "objectAtIndex:", j, 0, 0, 0);
            if (!r_is_objc_ptr(v) ||
                !r_msg2_main(v, "isKindOfClass:", iconViewCls, 0, 0, 0)) continue;
            uint64_t iiv = r_ivar_value(v, "_iconImageView");
            if (!r_is_objc_ptr(iiv) && r_responds_main(v, "_iconImageView"))
                iiv = r_msg2_main(v, "_iconImageView", 0, 0, 0, 0);
            if (!r_is_objc_ptr(iiv)) continue;
            uint64_t cache = r_responds_main(iiv, "iconImageCache")
                ? r_msg2_main(iiv, "iconImageCache", 0, 0, 0, 0) : 0;
            if (r_is_objc_ptr(cache)) return cache;
        }
    }
    return 0;
}

static int themer_graft_icon_models_for_theme(NSDictionary<NSString *, NSData *> *dataByBundle,
                                              uint64_t sharedCache,
                                              uint64_t lightAppearance,
                                              uint64_t darkAppearance,
                                              int *misses)
{
    int grafted = 0;
    int cached = 0;
    int modelMisses = 0;
    bool canCache = r_is_objc_ptr(sharedCache) &&
                    r_responds_main(sharedCache, "cacheImage:forIcon:imageAppearance:");
    for (NSString *key in dataByBundle) {
        if (![key isKindOfClass:NSString.class] || key.length == 0) continue;
        const char *bundle = key.UTF8String;
        if (!bundle || !bundle[0]) continue;

        if (kThemerFocusBundle && kThemerFocusBundle[0] &&
            strcmp(bundle, kThemerFocusBundle) != 0) {
            continue;
        }

        NSData *pngBytes = dataByBundle[key];
        if (![pngBytes isKindOfClass:NSData.class] || pngBytes.length == 0) continue;

        uint64_t image = themer_lookup_cached(bundle);
        if (!image) {
            NSData *uploadBytes = themer_rounded_png_data(pngBytes, bundle);
            image = themer_build_remote_uiimage_from_data(uploadBytes ?: pngBytes, bundle);
            if (!image) {
                modelMisses++;
                continue;
            }
            if (!themer_cache_image(bundle, image)) {
                r_msg2(image, "release", 0, 0, 0, 0);
                modelMisses++;
                continue;
            }
        }

        uint64_t icon = themer_lookup_model_icon_for_bundle(bundle);
        if (!r_is_objc_ptr(icon)) {
            modelMisses++;
            continue;
        }

        ThemerEntry *entry = themer_lookup_entry(bundle);
        if (entry && !entry->iconServicesSeeded) {
            entry->iconServicesSeeded =
                themer_seed_iconservices_cache(bundle, image, 60.0) > 0;
        }

        bool changed = false;
        if (entry && themer_graft_icon_model(icon, image, entry, 0, &changed)) {
            (void)themer_notify_icon_image_changed(icon);
            grafted++;
            // Populate the shared SBHIconImageCache for this icon (both
            // appearances) so off-screen pages render themed on first display,
            // not the stale cached image (issue #8).
            if (canCache) {
                if (r_is_objc_ptr(lightAppearance))
                    r_msg2_main(sharedCache, "cacheImage:forIcon:imageAppearance:",
                                image, icon, lightAppearance, 0);
                if (r_is_objc_ptr(darkAppearance))
                    r_msg2_main(sharedCache, "cacheImage:forIcon:imageAppearance:",
                                image, icon, darkAppearance, 0);
                cached++;
            }
        } else {
            modelMisses++;
        }
    }

    if (misses) *misses += modelMisses;
    printf("[THEMER] model pass grafted=%d cached=%d misses=%d cache=%d\n",
           grafted, cached, modelMisses, gThemerCacheCount);
    return grafted;
}

static bool themer_repaint_cached_views_internal(bool force)
{
    if (gThemerCacheCount <= 0) {
        printf("[THEMER] cached repaint skipped; cache empty\n");
        return false;
    }

    uint64_t startUS = themer_now_us();
    uint32_t prevSettle = r_settle_us(kThemerApplySettleUS);

    uint64_t listViewCls = r_class("SBIconListView");
    uint64_t iconViewCls = r_class("SBIconView");
    if (!r_is_objc_ptr(listViewCls) || !r_is_objc_ptr(iconViewCls)) {
        r_settle_us(prevSettle);
        return false;
    }

    enum { LV_CAP = 64 };
    uint64_t lvs[LV_CAP];
    int nlv = sb_collect_views_in_windows_main(listViewCls, lvs, LV_CAP);
    if (nlv == 0) {
        r_settle_us(prevSettle);
        printf("[THEMER] cached repaint: no visible SBIconListView\n");
        return false;
    }

    int rungHits[4] = {0};
    int misses = 0;
    int skips = 0;
    int applied = 0;
    for (int i = 0; i < nlv; i++) {
        applied += themer_repaint_cached_iconviews(lvs[i], iconViewCls,
                                                   rungHits, &misses, &skips,
                                                   force);
    }

    r_settle_us(prevSettle);
    uint64_t elapsedUS = themer_now_us() - startUS;
    printf("[THEMER] cached repaint%s lists=%d applied=%d skipped=%d misses=%d rungs={1:%d,2:%d,3:%d,4:%d} cache=%d elapsed=%llums\n",
           force ? " force" : "",
           nlv, applied, skips, misses,
           rungHits[0], rungHits[1], rungHits[2], rungHits[3],
           gThemerCacheCount,
           (unsigned long long)(elapsedUS / 1000ULL));
    return applied > 0 || skips > 0 || nlv > 0;
}

bool themer_repaint_cached_views_in_session(void)
{
    return themer_repaint_cached_views_internal(false);
}

bool themer_force_repaint_cached_views_in_session(void)
{
    return themer_repaint_cached_views_internal(true);
}

bool themer_repaint_dynamic_cached_views_in_session(void)
{
    if (gThemerCacheCount <= 0) {
        printf("[THEMER] dynamic repaint skipped; cache empty\n");
        return false;
    }

    uint64_t startUS = themer_now_us();
    uint32_t prevSettle = r_settle_us(kThemerApplySettleUS);

    uint64_t listViewCls = r_class("SBIconListView");
    uint64_t iconViewCls = r_class("SBIconView");
    if (!r_is_objc_ptr(listViewCls) || !r_is_objc_ptr(iconViewCls)) {
        r_settle_us(prevSettle);
        return false;
    }

    enum { LV_CAP = 64 };
    uint64_t lvs[LV_CAP];
    int nlv = sb_collect_views_in_windows_main(listViewCls, lvs, LV_CAP);
    if (nlv == 0) {
        r_settle_us(prevSettle);
        printf("[THEMER] dynamic repaint: no visible SBIconListView\n");
        return false;
    }

    int rungHits[4] = {0};
    int misses = 0;
    int applied = 0;
    for (int i = 0; i < nlv; i++) {
        applied += themer_repaint_dynamic_iconviews(lvs[i], iconViewCls,
                                                    rungHits, &misses);
    }

    uint64_t elapsed = (themer_now_us() - startUS) / 1000ULL;
    r_settle_us(prevSettle);
    printf("[THEMER] dynamic repaint lists=%d applied=%d misses=%d "
           "rungs={1:%d,2:%d,3:%d,4:%d} cache=%d elapsed=%llums\n",
           nlv, applied, misses,
           rungHits[0], rungHits[1], rungHits[2], rungHits[3],
           gThemerCacheCount,
           (unsigned long long)elapsed);
    return applied > 0;
}

bool themer_repaint_visible_theme_views_in_session(void)
{
    NSDictionary<NSString *, NSData *> *activeData = gThemerActiveThemeDataByBundle;
    if (gThemerCacheCount <= 0 && activeData.count == 0) {
        printf("[THEMER] visible theme repaint skipped; cache/theme empty\n");
        return false;
    }
    if (activeData.count == 0) {
        return themer_repaint_dynamic_cached_views_in_session();
    }

    uint64_t startUS = themer_now_us();
    uint32_t prevSettle = r_settle_us(kThemerApplySettleUS);

    uint64_t listViewCls = r_class("SBIconListView");
    uint64_t iconViewCls = r_class("SBIconView");
    if (!r_is_objc_ptr(listViewCls) || !r_is_objc_ptr(iconViewCls)) {
        r_settle_us(prevSettle);
        return false;
    }

    enum { LV_CAP = 64 };
    uint64_t lvs[LV_CAP];
    int nlv = sb_collect_views_in_windows_main(listViewCls, lvs, LV_CAP);
    if (nlv == 0) {
        r_settle_us(prevSettle);
        printf("[THEMER] visible theme repaint: no visible SBIconListView\n");
        return false;
    }

    int rungHits[4] = {0};
    int misses = 0;
    int applied = 0;
    for (int i = 0; i < nlv; i++) {
        applied += themer_iter_iconviews(lvs[i], activeData, iconViewCls,
                                         rungHits, &misses);
    }

    uint64_t elapsed = (themer_now_us() - startUS) / 1000ULL;
    r_settle_us(prevSettle);
    printf("[THEMER] visible theme repaint lists=%d applied=%d misses=%d "
           "rungs={1:%d,2:%d,3:%d,4:%d} cache=%d theme=%lu elapsed=%llums\n",
           nlv, applied, misses,
           rungHits[0], rungHits[1], rungHits[2], rungHits[3],
           gThemerCacheCount,
           (unsigned long)activeData.count,
           (unsigned long long)elapsed);
    return applied > 0;
}

static NSSet<NSString *> *themer_collect_visible_bundles(void)
{
    uint64_t listViewCls = r_class("SBIconListView");
    uint64_t iconViewCls = r_class("SBIconView");
    if (!r_is_objc_ptr(listViewCls) || !r_is_objc_ptr(iconViewCls)) return [NSSet set];

    enum { LV_CAP = 64 };
    uint64_t lvs[LV_CAP];
    int nlv = sb_collect_views_in_windows_main(listViewCls, lvs, LV_CAP);
    if (nlv == 0) return [NSSet set];

    NSMutableSet<NSString *> *bundles = [NSMutableSet set];
    for (int i = 0; i < nlv; i++) {
        enum { IV_CAP = 64 };
        uint64_t ivs[IV_CAP];
        int n = sb_collect_views_main(lvs[i], iconViewCls, ivs, IV_CAP);
        for (int j = 0; j < n; j++) {
            char bundle[128] = {0};
            if (themer_read_bundle_for_iconview(ivs[j], bundle, sizeof(bundle)) && bundle[0]) {
                [bundles addObject:@(bundle)];
            }
        }
    }
    return bundles;
}

// Cached remote images belong to the theme bytes they were built from. When a
// different theme is applied while the tweak stays enabled, release and drop
// every entry whose bytes changed or that the new theme no longer has, so a
// cache hit can never show the previous theme's image (review F-11). Entries
// whose bytes are identical are kept, so re-applying the same theme is
// unchanged. Grafted models/shared caches hold their own retains.
static int themer_drop_stale_cache_entries(NSDictionary<NSString *, NSData *> *previous,
                                           NSDictionary<NSString *, NSData *> *next)
{
    int kept = 0;
    int dropped = 0;
    for (int i = 0; i < gThemerCacheCount; i++) {
        ThemerEntry *e = &gThemerCache[i];
        NSString *key = e->bundle[0] ? [NSString stringWithUTF8String:e->bundle] : nil;
        NSData *oldBytes = key ? previous[key] : nil;
        NSData *newBytes = key ? next[key] : nil;
        if (oldBytes && newBytes && [oldBytes isEqualToData:newBytes]) {
            if (kept != i) gThemerCache[kept] = *e;
            kept++;
            continue;
        }
        if (r_is_objc_ptr(e->image))
            r_msg2(e->image, "release", 0, 0, 0, 0);
        if (r_is_objc_ptr(e->dataSource))
            r_msg2(e->dataSource, "release", 0, 0, 0, 0);
        dropped++;
    }
    for (int i = kept; i < gThemerCacheCount; i++) {
        gThemerCache[i].image = 0;
        gThemerCache[i].dataSource = 0;
        gThemerCache[i].iconServicesSeeded = false;
        gThemerCache[i].bundle[0] = '\0';
    }
    gThemerCacheCount = kept;
    return dropped;
}

// Revert a model icon grafted by themer_graft_icon_model back to its original
// class and drop the associated theme images. Only touches icons whose class is
// one of our CNDThemed* subclasses.
static bool themer_unthem_model_icon(const char *bundle)
{
    uint64_t icon = themer_lookup_model_icon_for_bundle(bundle);
    if (!r_is_objc_ptr(icon)) return false;

    uint64_t themedClass = r_dlsym_call(R_TIMEOUT, "object_getClass",
                                        icon, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(themedClass)) return false;
    char clsName[160] = {0};
    themer_read_class_object_name(themedClass, clsName, sizeof(clsName));
    if (strncmp(clsName, "CNDThemed", 9) != 0) return false;

    uint64_t baseClass = themedClass;
    while (strncmp(clsName, "CNDThemed", 9) == 0) {
        uint64_t superCls = r_dlsym_call(R_TIMEOUT, "class_getSuperclass",
                                         baseClass, 0, 0, 0, 0, 0, 0, 0);
        if (!r_is_objc_ptr(superCls) || superCls == baseClass) return false;
        baseClass = superCls;
        themer_read_class_object_name(baseClass, clsName, sizeof(clsName));
    }
    if (!clsName[0]) return false;

    // Class first, so SpringBoard never dispatches the themed getter after its
    // associated image is gone. But if the swap cannot be confirmed, clearing
    // the associations would leave a CNDThemed getter with no image (blank
    // icons) instead of the previous art. Only clear once the class is verified.
    uint64_t oldClass = r_dlsym_call(R_TIMEOUT, "object_setClass",
                                     icon, baseClass, 0, 0, 0, 0, 0, 0);
    bool swapConfirmed = r_last_call_ok() && oldClass == themedClass;
    if (swapConfirmed) {
        uint64_t nowClass = r_dlsym_call(R_TIMEOUT, "object_getClass",
                                         icon, 0, 0, 0, 0, 0, 0, 0);
        swapConfirmed = r_last_call_ok() && nowClass == baseClass;
    }
    if (!swapConfirmed) {
        printf("[THEMER] un-them: class swap NOT confirmed for %s; keeping the "
               "associated image (previous theme stays until respring)\n",
               bundle ?: "?");
        return false;
    }
    static const char *imageSels[] = {
        "makeIconImageWithInfo:traitCollection:context:options:",
        "iconImageWithInfo:traitCollection:context:options:",
        "iconImageWithInfo:traitCollection:options:",
    };
    for (int i = 0; i < 3; i++) {
        uint64_t sel = r_sel(imageSels[i]);
        if (!sel) continue;
        r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                     icon, sel, 0, 1, 0, 0, 0, 0);
    }
    (void)themer_notify_icon_image_changed(icon);
    return true;
}

// Bundles themed by the previous theme but absent from the new one.
static void themer_unthem_removed_bundles(NSDictionary<NSString *, NSData *> *previous,
                                          NSDictionary<NSString *, NSData *> *next)
{
    if (previous.count == 0) return;
    NSUInteger removed = 0;
    NSUInteger reverted = 0;
    for (NSString *key in previous) {
        if (next[key]) continue;
        removed++;
        if (reverted >= kThemerBulkModelGraftCap) continue;
        const char *bundle = key.UTF8String;
        if (bundle && bundle[0] && themer_unthem_model_icon(bundle)) reverted++;
    }
    if (removed == 0) return;
    printf("[THEMER] previous theme bundles not in new theme=%lu reverted=%lu\n",
           (unsigned long)removed, (unsigned long)reverted);
    if (reverted < removed) {
        printf("[THEMER] %lu icons keep the previous theme until respring\n",
               (unsigned long)(removed - reverted));
    }
}

bool themer_apply_data_in_session(NSDictionary<NSString *, NSData *> *imageDataByBundle)
{
    if (imageDataByBundle.count == 0) {
        printf("[THEMER] apply data: empty dictionary\n");
        return false;
    }
    imageDataByBundle = themer_normalized_theme_data(imageDataByBundle);
    if (imageDataByBundle.count == 0) {
        printf("[THEMER] apply data: normalization left no usable icons\n");
        return false;
    }

    // Drop the per-msgSend settle for the duration of the apply. The stable
    // RemoteCall trampoline already serializes the calls; sleeping before every
    // ObjC send just makes the initial icon flip visibly lag.
    uint64_t startUS = themer_now_us();
    uint32_t prevSettle = r_settle_us(kThemerApplySettleUS);

    // Resolve the target BEFORE committing the new theme. These checks can
    // fail (no visible SBIconListView, older/unknown SpringBoard); a failed
    // apply must leave the previous active theme and its image cache intact.
    uint64_t listViewCls = r_class("SBIconListView");
    uint64_t iconViewCls = r_class("SBIconView");
    if (!r_is_objc_ptr(listViewCls) || !r_is_objc_ptr(iconViewCls)) {
        printf("[THEMER] missing class SBIconListView=0x%llx SBIconView=0x%llx\n",
               (unsigned long long)listViewCls,
               (unsigned long long)iconViewCls);
        r_settle_us(prevSettle);
        return false;
    }

    enum { LV_CAP = 64 };
    uint64_t lvs[LV_CAP];
    int nlv = sb_collect_views_in_windows_main(listViewCls, lvs, LV_CAP);
    if (nlv == 0) {
        printf("[THEMER] no SBIconListView visible (home screen not active?)\n");
        r_settle_us(prevSettle);
        return false;
    }

    // The apply can proceed: commit the new theme now.
    NSDictionary<NSString *, NSData *> *previousData = gThemerActiveThemeDataByBundle;
    gThemerActiveThemeDataByBundle = [imageDataByBundle copy];
    int staleDropped = themer_drop_stale_cache_entries(previousData, imageDataByBundle);
    printf("[THEMER] apply data entries=%lu cacheCarried=%d staleDropped=%d\n",
           (unsigned long)imageDataByBundle.count, gThemerCacheCount, staleDropped);
    if (!gThemerVisiblePolicyLogged) {
        gThemerVisiblePolicyLogged = true;
        printf("[THEMER] visible push policy iosMajor=%d legacyVisible=%d\n",
               themer_host_ios_major(),
               themer_needs_visible_push(NULL));
    }
    themer_unthem_removed_bundles(previousData, imageDataByBundle);
    themer_reset_icon_bundle_cache();

    // Resolve the shared icon-image cache + appearances once so the model pass
    // can cache every themed icon (all pages), fixing off-screen pages showing
    // the old icon until a lock/unlock or app-cycle (issue #8).
    uint64_t sharedCache = themer_shared_icon_image_cache(lvs, nlv);
    uint64_t appearanceCls2 = r_class("SBHIconImageAppearance");
    uint64_t lightAppearance2 = (r_is_objc_ptr(appearanceCls2) &&
                                 r_responds(appearanceCls2, "lightAppearance"))
        ? r_msg2(appearanceCls2, "lightAppearance", 0, 0, 0, 0) : 0;
    uint64_t darkAppearance2 = (r_is_objc_ptr(appearanceCls2) &&
                                r_responds(appearanceCls2, "darkAppearance"))
        ? r_msg2(appearanceCls2, "darkAppearance", 0, 0, 0, 0) : 0;

    int rungHits[4] = {0};
    int misses = 0;
    int modelGrafted = 0;
    if (imageDataByBundle.count <= kThemerBulkModelGraftCap) {
        modelGrafted = themer_graft_icon_models_for_theme(imageDataByBundle,
                                                          sharedCache,
                                                          lightAppearance2,
                                                          darkAppearance2,
                                                          &misses);
    } else {
        printf("[THEMER] model pass deferred for large theme entries=%lu cap=%lu; "
               "visible icons will lazy-graft during apply/repair\n",
               (unsigned long)imageDataByBundle.count,
               (unsigned long)kThemerBulkModelGraftCap);
    }
    int applied = 0;
    for (int i = 0; i < nlv; i++) {
        applied += themer_iter_iconviews(lvs[i], imageDataByBundle, iconViewCls,
                                         rungHits, &misses);
    }

    r_settle_us(prevSettle);
    uint64_t elapsedUS = themer_now_us() - startUS;
    printf("[THEMER] done lists=%d model=%d applied=%d misses=%d rungs={1:%d,2:%d,3:%d,4:%d} cache=%d elapsed=%llums settle=%uus\n",
           nlv, modelGrafted, applied, misses,
           rungHits[0], rungHits[1], rungHits[2], rungHits[3],
           gThemerCacheCount,
           (unsigned long long)(elapsedUS / 1000ULL),
           kThemerApplySettleUS);
    return applied > 0;
}

bool themer_apply_in_session(const char *themePath)
{
    if (!themePath || !themePath[0]) {
        printf("[THEMER] apply: nil path\n");
        return false;
    }

    NSString *themeDir = @(themePath);
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:themeDir isDirectory:&isDir] || !isDir) {
        printf("[THEMER] apply: missing dir %s\n", themePath);
        return false;
    }

    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:themeDir error:NULL];
    NSMutableDictionary<NSString *, NSString *> *pathByBundle = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *explicitFileBundles = [NSMutableSet set];
    NSMutableSet<NSString *> *appleSystemBundles = [NSMutableSet set];
    NSMutableSet<NSString *> *aliasTargetBundles = [NSMutableSet set];
    NSUInteger availableCount = 0;
    NSUInteger aliasKeyCount = 0;
    for (NSString *f in files) {
        if (![f.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
        availableCount++;
        NSString *bundle = f.stringByDeletingPathExtension;
        NSString *path = [themeDir stringByAppendingPathComponent:f];
        pathByBundle[bundle] = path;
        if (bundle.length > 0) [explicitFileBundles addObject:bundle];
        if ([bundle.lowercaseString hasPrefix:@"com.apple."]) {
            [appleSystemBundles addObject:bundle];
        }
        NSString *lower = bundle.lowercaseString;
        if (lower.length > 0 && !pathByBundle[lower]) {
            pathByBundle[lower] = path;
        }
        if ([lower isEqualToString:@"com.autonavi.minimap"] && !pathByBundle[@"com.autonavi.amap"]) {
            pathByBundle[@"com.autonavi.amap"] = path;
            [aliasTargetBundles addObject:@"com.autonavi.amap"];
        }
        BOOL usedAlias = NO;
        NSArray<NSString *> *mappedTargets = CNDMappedIOSBundleIDsForIconName(f, &usedAlias);
        for (NSString *mapped in mappedTargets) {
            if (mapped.length == 0) continue;
            if ([mapped.lowercaseString hasPrefix:@"com.apple."]) {
                [appleSystemBundles addObject:mapped];
            }
            if (!pathByBundle[mapped]) {
                pathByBundle[mapped] = path;
                if (usedAlias) aliasKeyCount++;
            }
            if (usedAlias) {
                [aliasTargetBundles addObject:mapped];
            }
            NSString *mappedLower = mapped.lowercaseString;
            if (mappedLower.length > 0 && !pathByBundle[mappedLower]) {
                pathByBundle[mappedLower] = path;
            }
        }
    }
    printf("[THEMER] apply path=%s available=%lu aliasKeys=%lu\n",
           themePath, (unsigned long)availableCount, (unsigned long)aliasKeyCount);
    if (availableCount == 0) return false;

    printf("[THEMER] explicit file bundles count=%lu list=%s\n",
           (unsigned long)explicitFileBundles.count,
           themer_join_strings_for_log(explicitFileBundles, 200).UTF8String);
    printf("[THEMER] apple-system bundles count=%lu list=%s\n",
           (unsigned long)appleSystemBundles.count,
           themer_join_strings_for_log(appleSystemBundles, 200).UTF8String);
    printf("[THEMER] alias-target bundles count=%lu list=%s\n",
           (unsigned long)aliasTargetBundles.count,
           themer_join_strings_for_log(aliasTargetBundles, 240).UTF8String);
    NSMutableSet<NSString *> *targetBundles = [explicitFileBundles mutableCopy];
    NSUInteger priorityAdded = 0;
    NSUInteger appleAdded = 0;
    NSUInteger aliasAdded = 0;
    for (NSString *bid in appleSystemBundles) {
        if (![bid isKindOfClass:NSString.class] || bid.length == 0) continue;
        if ([targetBundles containsObject:bid]) continue;
        if (themer_theme_path_for_bundle(pathByBundle, bid)) {
            [targetBundles addObject:bid];
            appleAdded++;
        }
    }
    for (NSString *bid in aliasTargetBundles) {
        if (![bid isKindOfClass:NSString.class] || bid.length == 0) continue;
        if ([targetBundles containsObject:bid]) continue;
        if (themer_theme_path_for_bundle(pathByBundle, bid)) {
            [targetBundles addObject:bid];
            aliasAdded++;
        }
    }
    for (NSString *bid in themer_priority_theme_bundles()) {
        if (![bid isKindOfClass:NSString.class] || bid.length == 0) continue;
        if ([targetBundles containsObject:bid]) continue;
        if (themer_theme_path_for_bundle(pathByBundle, bid)) {
            [targetBundles addObject:bid];
            priorityAdded++;
        }
    }
    printf("[THEMER] target bundles count=%lu list=%s\n",
           (unsigned long)targetBundles.count,
           themer_join_strings_for_log(targetBundles, 240).UTF8String);
    NSMutableDictionary<NSString *, NSData *> *dict = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *matchedBundles = [NSMutableArray array];
    NSUInteger caseFallbacks = 0;
    for (NSString *bid in targetBundles) {
        NSString *path = themer_theme_path_for_bundle(pathByBundle, bid);
        if (path && !pathByBundle[bid]) {
            caseFallbacks++;
        }
        if (!path) continue;
        // Size/dimension check before the read (review F-12); the same
        // bytes would be refused at upload anyway.
        if (!SBLImageFilePassesPreflight(path, kThemerMaxPngBytes, NULL)) {
            printf("[THEMER] skip %s: file fails preflight (size cap=%zu or dimensions)\n",
                   bid.UTF8String, kThemerMaxPngBytes);
            continue;
        }
        NSData *bytes = [NSData dataWithContentsOfFile:path];
        if (bytes.length) {
            dict[bid] = bytes;
            [matchedBundles addObject:bid];
        }
    }
    printf("[THEMER] matched bundles count=%lu list=%s\n",
           (unsigned long)matchedBundles.count,
           themer_join_strings_for_log(matchedBundles, 240).UTF8String);
    printf("[THEMER] apply loaded=%lu matched of %lu target (%lu explicit + %lu apple + %lu alias + %lu priority), %lu available caseFallbacks=%lu\n",
           (unsigned long)dict.count,
           (unsigned long)targetBundles.count,
           (unsigned long)explicitFileBundles.count,
           (unsigned long)appleAdded,
           (unsigned long)aliasAdded,
           (unsigned long)priorityAdded,
           (unsigned long)availableCount,
           (unsigned long)caseFallbacks);
    return themer_apply_data_in_session(dict);
}

bool themer_stop_in_session(void)
{
    int released = 0;
    for (int i = 0; i < gThemerCacheCount; i++) {
        if (r_is_objc_ptr(gThemerCache[i].image)) {
            r_msg2(gThemerCache[i].image, "release", 0, 0, 0, 0);
            released++;
        }
        if (r_is_objc_ptr(gThemerCache[i].dataSource)) {
            r_msg2(gThemerCache[i].dataSource, "release", 0, 0, 0, 0);
            released++;
        }
        gThemerCache[i].image = 0;
        gThemerCache[i].dataSource = 0;
        gThemerCache[i].iconServicesSeeded = false;
        gThemerCache[i].bundle[0] = '\0';
    }
    gThemerCacheCount = 0;
    themer_reset_icon_bundle_cache();
    gThemerActiveThemeDataByBundle = nil;
    gThemerRung = -1;
    gThemerHasUpdateAfter = false;
    gThemerHasUpdateImageView = false;
    gThemerLogBudget = 48;
    gThemerModelProbeLogged = false;
    gThemerIconServicesProbeLogged = false;
    gThemerVisiblePolicyLogged = false;
    printf("[THEMER] stop released=%d\n", released);
    return true;
}

void themer_forget_remote_state(void)
{
    for (int i = 0; i < kThemerMaxCache; i++) {
        gThemerCache[i].image = 0;
        gThemerCache[i].dataSource = 0;
        gThemerCache[i].iconServicesSeeded = false;
        gThemerCache[i].bundle[0] = '\0';
    }
    gThemerCacheCount = 0;
    themer_reset_icon_bundle_cache();
    gThemerActiveThemeDataByBundle = nil;
    gThemerRung = -1;
    gThemerHasUpdateAfter = false;
    gThemerHasUpdateImageView = false;
    gThemerLogBudget = 48;
    gThemerModelProbeLogged = false;
    gThemerIconServicesProbeLogged = false;
    gThemerVisiblePolicyLogged = false;
}
