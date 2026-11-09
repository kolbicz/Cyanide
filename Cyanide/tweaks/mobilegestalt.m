//
//  mobilegestalt.m
//  Cyanide
//
//  Ported from lara by rooootdev (https://github.com/rooootdev/lara,
//  views/tweaks/mobilegestalt/GestaltView.swift), with his permission. lara's
//  editor is based on SparseBox by khanhduytran0 (thanks to @jurre111 and
//  @lunginspector, as credited there); the keys are Nugget's by leminlimez.
//
//  Differences from lara:
//  - Turning a tweak off puts back the device's original value instead of
//    deleting the key, and a capability the device already has is shown as
//    built in rather than offered.
//  - The file is replaced with its owner and mode kept (temp file + rename,
//    as for Supervision), and every write keeps a dated backup of the file as
//    it was, next to the untouched original.
//  - The CacheData offsets come from the OTA blocker's lookup, which checks
//    every step instead of asserting.
//

#import "mobilegestalt.h"
#import "darksword_ota.h"
#import "../LogTextView.h"
#import "../kexploit/vnode.h"
#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <unistd.h>

static NSString * const kMGCacheExtra = @"CacheExtra";
static NSString * const kMGCacheData = @"CacheData";
static NSString * const kMGArtworkKey = @"oPeik/9e8lQWMszEjbPzng";
static NSString * const kMGArtworkSubtype = @"ArtworkDeviceSubType";
static NSString * const kMGArtworkName = @"ArtworkDeviceProductDescription";
static NSString * const kMGProductTypeKey = @"h9jDsbgj7xIVeIQ8S3/X3Q";
static NSString * const kMGDeviceClassKey = @"+3Uf0Pm5F8Xy7Onyvko0vA";
static NSString * const kMGRegionCodeKey = @"h63QSdBCiT/z0WU6rdQv6Q";
static NSString * const kMGRegionInfoKey = @"zHeENZu+wbg7PUprwNwBWg";
// Folder mode to put back if a write that widened it was interrupted.
static NSString * const kMGDirRestoreDefaultsKey = @"MobileGestaltDirModeRestore";
static const NSUInteger kMGMaxBackups = 10;

static const char *kMGIPadUIKeys[] = {
    "uKc7FPnEO++lVhHWHFlGbQ",   // iPad
    "mG0AnH/Vy1veoqoLRAIgTA",   // MedusaFloatingLiveAppCapability
    "UCG5MkVahJxG1YULbbd5Bg",   // MedusaOverlayAppCapability
    "ZYqko/XM5zD3XBfN5RmaXA",   // MedusaPinnedAppCapability
    "nVh/gwNpy7Jv1NOk00CMrw",   // MedusaPIPCapability
    "qeaj75wk3HF4DwQ8qbIi7g",   // DeviceSupportsEnhancedMultitasking
    NULL,
};
static const char *kMGIPadUIClassKey = "mtrAoWJ3gsq+I90ZnQ0vQw";   // CacheData: device class number
static const char *kMGInternalKeys[] = {
    "EqrsVvjcYDdxHBiQmGhAWw",   // AppleInternalInstallCapability
    "Oji6HRoPi7rH7HPdWVakuw",   // HasInternalSettingsBundle
    "LBJfwOEzExRxzlAnSuI7eg",   // InternalBuild
    NULL,
};

static const MGTweak kMGTweaks[] = {
    // Software
    { "Dynamic Island", "The Dynamic Island on a device without one. May not work on every model.",
      "platter.filled.top.iphone", "Software", MGTweakKindKeys,
      { "YlEtTtHlNesRBMal1CqRaA", NULL }, 0, MGTweakFlagNone, NULL },
    { "Always-On Display", "The dimmed Lock Screen stays on.",
      "sun.max", "Software", MGTweakKindKeys,
      { "j8/Omm6s1lsmTDFsXjsBfA", "2OOJf1VhaM7NxfRok3HbWQ", NULL }, 18.0, MGTweakFlagNone, NULL },
    { "Always-On Vibrancy", "Brighter, more colourful always-on Lock Screen.",
      "rays", "Software", MGTweakKindKeys,
      { "ykpu7qyhqFweVMKtxNylWA", NULL }, 18.0, MGTweakFlagNone, NULL },
    { "Charge Limit", "The 80 % to 100 % charge limit in Battery settings.",
      "battery.100.bolt", "Software", MGTweakKindKeys,
      { "37NVydb//GP/GrhuTN+exg", NULL }, 17.0, MGTweakFlagNone, NULL },
    { "Boot Chime", "The startup sound option in Accessibility → Audio.",
      "speaker.wave.3", "Software", MGTweakKindKeys,
      { "QHxt+hGLaBPbQJbXiUJX3w", NULL }, 0, MGTweakFlagNone, NULL },
    { "Liquid Glass in Low Power Mode", "Keeps the Liquid Glass effects in Low Power Mode.",
      "app.background.dotted", "Software", MGTweakKindKeys,
      { "SAGvsp6O6kAQ4fEfDJpC4Q", NULL }, 26.0, MGTweakFlagNone, NULL },
    { "Disable Wallpaper Parallax", "The wallpaper no longer moves when you tilt the device.",
      "move.3d", "Software", MGTweakKindKeys,
      { "UIParallaxCapability", NULL }, 0, MGTweakFlagValueZero, NULL },

    // Hardware
    { "Camera Control", "The Camera Control settings (there is no button to use them).",
      "camera.shutter.button", "Hardware", MGTweakKindKeys,
      { "CwvKxM2cEogD3p+HYgaW0Q", "oOV1jhJbdV3AddkcCg0AEA", NULL }, 18.0, MGTweakFlagNone, NULL },
    { "Action Button", "The Action Button settings page.",
      "button.vertical.left.press", "Hardware", MGTweakKindKeys,
      { "cT44WE1EohiwRzhsZ8xEsw", NULL }, 17.0, MGTweakFlagNone, NULL },
    { "Crash Detection", "The Crash Detection settings. May not work.",
      "car", "Hardware", MGTweakKindKeys,
      { "HCzWusHQwZDea6nNhaKndw", NULL }, 0, MGTweakFlagNone, NULL },
    { "Tap to Wake", "Tap the screen to wake it (devices with a Home button).",
      "hand.tap", "Hardware", MGTweakKindKeys,
      { "yZf3GTRMGTuwSV/lD7Cagw", NULL }, 0, MGTweakFlagHomeButtonOnly, NULL },
    { "PWM Display Setting", "The Display Pulse Width Modulation option.",
      "eye", "Hardware", MGTweakKindKeys,
      { "6IejgN+1Fmu5/QrZFOIeNw", NULL }, 26.0, MGTweakFlagNone, NULL },

    // Eligibility
    { "Apple Intelligence", "Marks the device as able to run Apple Intelligence.",
      "apple.intelligence", "Eligibility", MGTweakKindKeys,
      { "A62OafQ85EJAiiqKn4agtg", NULL }, 18.1, MGTweakFlagNone, NULL },
    { "Disable Region Restrictions", "Reports a US model (US, LL/A).",
      "globe", "Eligibility", MGTweakKindRegion,
      { NULL }, 0, MGTweakFlagConfirm,
      "Don't use this to get around restrictions your country requires by law (for example the camera shutter sound)." },
    { "Security Research Device UI", "Shows the Security Research Device settings.",
      "terminal", "Eligibility", MGTweakKindKeys,
      { "XYlJKKkj2hztRP1NWWnhlw", NULL }, 26.0, MGTweakFlagNone, NULL },

    // iPadOS
    { "Allow Installing iPadOS Apps", "iPad-only apps can be installed.",
      "plus.app", "iPadOS", MGTweakKindKeys,
      { "9MZ5AdH43csAUajl/dU+IQ", NULL }, 0, MGTweakFlagValueIntList12, NULL },
    { "Apple Pencil", "The Apple Pencil settings.",
      "pencil", "iPadOS", MGTweakKindKeys,
      { "yhHcB0iH0d1XzPO/CFd3ow", NULL }, 0, MGTweakFlagNone, NULL },
    { "Stage Manager", "Stage Manager multitasking.",
      "squares.leading.rectangle", "iPadOS", MGTweakKindKeys,
      { "qeaj75wk3HF4DwQ8qbIi7g", NULL }, 0, MGTweakFlagIPadOnly, NULL },
    { "iPadOS Interface", "The iPad interface and multitasking on an iPhone. Unstable.",
      "ipad", "iPadOS", MGTweakKindIPadUI,
      { NULL }, 0, MGTweakFlagIPhoneOnly | MGTweakFlagConfirm,
      "This is risky. Don't use it with an alphanumeric passcode. Never turn off \"Show Dock\" in Stage Manager, or the device bootloops when you rotate it to landscape. Apps can be unstable and app data can disappear." },

    // Internal
    { "Internal Storage Info", "Internal storage details in Settings.",
      "externaldrive", "Internal", MGTweakKindKeys,
      { "LBJfwOEzExRxzlAnSuI7eg", NULL }, 0, MGTweakFlagNone, NULL },
    { "Internal Features", "Apple-internal options in Settings. Turning OTA updates back on in Cyanide clears these flags again.",
      "gearshape", "Internal", MGTweakKindInternal,
      { NULL }, 0, MGTweakFlagNone, NULL },
    { "Metal HUD in All Apps", "Allows the Metal performance overlay in every app. Turning OTA updates back on in Cyanide clears it.",
      "cpu", "Internal", MGTweakKindKeys,
      { "EqrsVvjcYDdxHBiQmGhAWw", NULL }, 0, MGTweakFlagNone, NULL },

    { NULL },
};

const MGTweak *mg_tweaks(void)
{
    return kMGTweaks;
}

#pragma mark - Device

NSString *mg_machine_name(void)
{
    struct utsname info;
    if (uname(&info) != 0) return @"";
    return [NSString stringWithUTF8String:info.machine] ?: @"";
}

double mg_system_version(void)
{
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    return (double)v.majorVersion + (double)v.minorVersion / 10.0;
}

static BOOL mg_has_home_button(void)
{
    UIDevice *device = UIDevice.currentDevice;
    SEL sel = NSSelectorFromString(@"_hasHomeButton");
    if ([device respondsToSelector:sel]) {
        BOOL (*call)(id, SEL) = (BOOL (*)(id, SEL))[device methodForSelector:sel];
        return call(device, sel);
    }
    return NO;
}

static BOOL mg_is_ipad(void)
{
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
}

BOOL mg_tweak_available(const MGTweak *t, NSString **why)
{
    NSString *reason = nil;
    if (t->minVersion > 0 && mg_system_version() + 0.001 < t->minVersion)
        reason = [NSString stringWithFormat:@"Needs iOS %g or later.", t->minVersion];
    else if ((t->flags & MGTweakFlagHomeButtonOnly) && !mg_has_home_button())
        reason = @"Only on devices with a Home button.";
    else if ((t->flags & MGTweakFlagIPadOnly) && !mg_is_ipad())
        reason = @"Only on iPad.";
    else if ((t->flags & MGTweakFlagIPhoneOnly) && mg_is_ipad())
        reason = @"Only on iPhone.";
    if (why) *why = reason;
    return reason == nil;
}

#pragma mark - Backups

static NSString *mg_backup_dir(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"MobileGestalt"];
}

NSString *mg_original_backup_path(void)
{
    return [mg_backup_dir() stringByAppendingPathComponent:@"Original.plist"];
}

BOOL mg_has_original_backup(void)
{
    return [NSFileManager.defaultManager fileExistsAtPath:mg_original_backup_path()];
}

static NSDictionary *mg_parse(NSData *data, NSPropertyListMutabilityOptions options)
{
    if (data.length == 0) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:options format:NULL error:nil];
    if (![plist isKindOfClass:NSDictionary.class]) return nil;
    if (![plist[kMGCacheExtra] isKindOfClass:NSDictionary.class] || [plist[kMGCacheExtra] count] == 0) return nil;
    return plist;
}

// The original backup's CacheExtra, read once.
static NSDictionary *mg_original_extra(void)
{
    static NSDictionary *extra;
    @synchronized (NSNull.null) {
        if (!extra) {
            NSDictionary *plist = mg_parse([NSData dataWithContentsOfFile:mg_original_backup_path()],
                                           NSPropertyListImmutable);
            extra = plist[kMGCacheExtra];
        }
        return extra;
    }
}

static void mg_keep_backup(NSData *current)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [mg_backup_dir() stringByAppendingPathComponent:@"Backups"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    NSString *path = [dir stringByAppendingPathComponent:
                      [[fmt stringFromDate:NSDate.date] stringByAppendingPathExtension:@"plist"]];
    if (![current writeToFile:path atomically:YES]) {
        printf("[MG] backup of the current file failed\n");
        return;
    }
    NSArray *all = [[fm contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; all.count > kMGMaxBackups && i < all.count - kMGMaxBackups; i++)
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:all[i]] error:nil];
}

#pragma mark - Reading

NSMutableDictionary *mg_load(NSString **error)
{
    if (!darksword_prepare_var_rw()) {
        if (error) *error = @"No access to /private/var (the sandbox could not be lifted).";
        return nil;
    }
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:MG_CACHE_PATH options:0 error:&readError];
    if (!data) {
        if (error) *error = [NSString stringWithFormat:@"The MobileGestalt cache could not be read: %@",
                             readError.localizedDescription ?: @"unknown error"];
        return nil;
    }
    NSMutableDictionary *mg = (NSMutableDictionary *)mg_parse(data, NSPropertyListMutableContainersAndLeaves);
    if (![mg isKindOfClass:NSMutableDictionary.class]) {
        if (error) *error = @"The MobileGestalt cache isn't in the expected format.";
        return nil;
    }
    if (!mg_has_original_backup()) {
        [NSFileManager.defaultManager createDirectoryAtPath:mg_backup_dir()
                                withIntermediateDirectories:YES attributes:nil error:nil];
        if ([data writeToFile:mg_original_backup_path() atomically:YES])
            printf("[MG] kept the original cache (%lu bytes)\n", (unsigned long)data.length);
        else
            printf("[MG] keeping the original cache failed\n");
    }
    if (![mg[kMGCacheData] isKindOfClass:NSMutableData.class] && [mg[kMGCacheData] isKindOfClass:NSData.class])
        mg[kMGCacheData] = [mg[kMGCacheData] mutableCopy];
    printf("[MG] loaded: %lu CacheExtra keys, CacheData %lu bytes\n",
           (unsigned long)[mg[kMGCacheExtra] count], (unsigned long)[mg[kMGCacheData] length]);
    return mg;
}

#pragma mark - Tweaks

static id mg_enable_value(const MGTweak *t)
{
    if (t->flags & MGTweakFlagValueIntList12) return @[@1, @2];
    if (t->flags & MGTweakFlagValueZero) return @0;
    return @1;
}

// Puts back the original value of `key`, or removes it when the original
// cache didn't have it (MobileGestalt then answers from the hardware).
static void mg_restore_key(NSMutableDictionary *extra, NSString *key)
{
    id original = mg_original_extra()[key];
    if (original) extra[key] = original;
    else [extra removeObjectForKey:key];
}

static BOOL mg_cachedata_get(NSDictionary *mg, const char *key, int64_t *out)
{
    NSData *data = mg[kMGCacheData];
    long off = ota_find_mobilegestalt_cachedata_offset(key);
    if (![data isKindOfClass:NSData.class] || off < 0 || (NSUInteger)off + sizeof(int64_t) > data.length) return NO;
    memcpy(out, (const uint8_t *)data.bytes + off, sizeof(int64_t));
    return YES;
}

static BOOL mg_cachedata_set(NSMutableDictionary *mg, const char *key, int64_t value)
{
    NSMutableData *data = mg[kMGCacheData];
    long off = ota_find_mobilegestalt_cachedata_offset(key);
    if (![data isKindOfClass:NSMutableData.class] || off < 0 || (NSUInteger)off + sizeof(int64_t) > data.length) {
        printf("[MG] CacheData slot for %s not found\n", key);
        return NO;
    }
    memcpy((uint8_t *)data.mutableBytes + off, &value, sizeof(value));
    return YES;
}

BOOL mg_tweak_is_on(NSDictionary *mg, const MGTweak *t)
{
    NSDictionary *extra = mg[kMGCacheExtra];
    switch (t->kind) {
        case MGTweakKindKeys:
            return t->keys[0] && [extra[@(t->keys[0])] isEqual:mg_enable_value(t)];
        case MGTweakKindRegion:
            return [extra[kMGRegionCodeKey] isEqual:@"US"] && [extra[kMGRegionInfoKey] isEqual:@"LL/A"];
        case MGTweakKindInternal: {
            int64_t v = 0;
            return mg_cachedata_get(mg, kMGInternalKeys[0], &v) && v == 1;
        }
        case MGTweakKindIPadUI:
            return [extra[@(kMGIPadUIKeys[0])] isEqual:@1];
    }
    return NO;
}

BOOL mg_tweak_builtin(const MGTweak *t)
{
    if (t->kind != MGTweakKindKeys || !t->keys[0]) return NO;
    return [mg_original_extra()[@(t->keys[0])] isEqual:mg_enable_value(t)];
}

BOOL mg_tweak_set(NSMutableDictionary *mg, const MGTweak *t, BOOL on, NSString **error)
{
    NSMutableDictionary *extra = mg[kMGCacheExtra];
    if (![extra isKindOfClass:NSMutableDictionary.class]) {
        if (error) *error = @"The cache has no CacheExtra.";
        return NO;
    }
    switch (t->kind) {
        case MGTweakKindKeys:
            for (int i = 0; t->keys[i]; i++) {
                if (on) extra[@(t->keys[i])] = mg_enable_value(t);
                else mg_restore_key(extra, @(t->keys[i]));
            }
            return YES;
        case MGTweakKindRegion:
            if (on) {
                extra[kMGRegionCodeKey] = @"US";
                extra[kMGRegionInfoKey] = @"LL/A";
            } else {
                mg_restore_key(extra, kMGRegionCodeKey);
                mg_restore_key(extra, kMGRegionInfoKey);
            }
            return YES;
        case MGTweakKindInternal:
            for (int i = 0; kMGInternalKeys[i]; i++) {
                if (!mg_cachedata_set(mg, kMGInternalKeys[i], on ? 1 : 0)) {
                    if (error) *error = @"This iOS version keeps the internal flags somewhere Cyanide can't find.";
                    return NO;
                }
            }
            return YES;
        case MGTweakKindIPadUI:
            if (on && ![extra[kMGDeviceClassKey] isEqual:@"iPhone"]) {
                if (error) *error = @"Only on iPhone.";
                return NO;
            }
            if (!mg_cachedata_set(mg, kMGIPadUIClassKey, on ? 3 : 1)) {
                if (error) *error = @"This iOS version keeps the device class somewhere Cyanide can't find.";
                return NO;
            }
            for (int i = 0; kMGIPadUIKeys[i]; i++) {
                if (on) extra[@(kMGIPadUIKeys[i])] = @1;
                else mg_restore_key(extra, @(kMGIPadUIKeys[i]));
            }
            return YES;
    }
    return NO;
}

#pragma mark - Artwork and model

static NSMutableDictionary *mg_artwork(NSDictionary *mg, BOOL create)
{
    NSMutableDictionary *extra = mg[kMGCacheExtra];
    NSMutableDictionary *art = extra[kMGArtworkKey];
    if (![art isKindOfClass:NSMutableDictionary.class]) {
        if (!create || ![extra isKindOfClass:NSMutableDictionary.class]) return nil;
        art = [art isKindOfClass:NSDictionary.class] ? [art mutableCopy] : [NSMutableDictionary dictionary];
        extra[kMGArtworkKey] = art;
    }
    return art;
}

NSNumber *mg_artwork_subtype(NSDictionary *mg)
{
    id v = mg_artwork(mg, NO)[kMGArtworkSubtype];
    return [v isKindOfClass:NSNumber.class] ? v : nil;
}

void mg_set_artwork_subtype(NSMutableDictionary *mg, NSNumber *subtype)
{
    NSMutableDictionary *art = mg_artwork(mg, YES);
    if (subtype) art[kMGArtworkSubtype] = subtype;
    else [art removeObjectForKey:kMGArtworkSubtype];
}

NSString *mg_device_name(NSDictionary *mg)
{
    id v = mg_artwork(mg, NO)[kMGArtworkName];
    return [v isKindOfClass:NSString.class] ? v : nil;
}

void mg_set_device_name(NSMutableDictionary *mg, NSString *name)
{
    NSMutableDictionary *art = mg_artwork(mg, YES);
    NSString *value = name.length ? name : mg_original_device_name();
    if (value) art[kMGArtworkName] = value;
    else [art removeObjectForKey:kMGArtworkName];
}

NSString *mg_product_type(NSDictionary *mg)
{
    id v = mg[kMGCacheExtra][kMGProductTypeKey];
    return [v isKindOfClass:NSString.class] && [v length] ? v : mg_machine_name();
}

void mg_set_product_type(NSMutableDictionary *mg, NSString *productType)
{
    NSMutableDictionary *extra = mg[kMGCacheExtra];
    if (productType.length && ![productType isEqualToString:mg_original_product_type()])
        extra[kMGProductTypeKey] = productType;
    else
        mg_restore_key(extra, kMGProductTypeKey);
}

NSNumber *mg_original_artwork_subtype(void)
{
    id v = mg_original_extra()[kMGArtworkKey][kMGArtworkSubtype];
    return [v isKindOfClass:NSNumber.class] ? v : nil;
}

NSString *mg_original_device_name(void)
{
    id v = mg_original_extra()[kMGArtworkKey][kMGArtworkName];
    return [v isKindOfClass:NSString.class] ? v : nil;
}

NSString *mg_original_product_type(void)
{
    id v = mg_original_extra()[kMGProductTypeKey];
    return [v isKindOfClass:NSString.class] && [v length] ? v : mg_machine_name();
}

#pragma mark - Writing

static bool mg_mode_is(const char *path, mode_t mode)
{
    struct stat st = {0};
    return stat(path, &st) == 0 && (st.st_mode & 07777) == (mode & 07777);
}

static bool mg_restore_dir_mode(const char *dir, mode_t mode)
{
    (void)vnode_apfs_chmod(dir, mode);
    if (!mg_mode_is(dir, mode)) {
        printf("[MG] restoring folder mode %o failed; retried next time\n", mode & 07777);
        return false;
    }
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kMGDirRestoreDefaultsKey];
    return true;
}

static bool mg_write_all(int fd, NSData *data)
{
    const uint8_t *bytes = data.bytes;
    NSUInteger total = 0;
    while (total < data.length) {
        ssize_t n = write(fd, bytes + total, data.length - total);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        total += (NSUInteger)n;
    }
    return true;
}

// Temp file + rename, with the original owner and mode. The folder is widened
// only if this app can't write it, and narrowed again afterwards (recorded
// first, so an interrupted write is undone next time). Same as Supervision.
static bool mg_replace_file(NSData *data)
{
    NSString *path = MG_CACHE_PATH;
    NSString *dirPath = path.stringByDeletingLastPathComponent;
    const char *dir = dirPath.fileSystemRepresentation;
    NSString *temp = [path stringByAppendingString:@".cyanide.tmp"];

    NSNumber *pending = [NSUserDefaults.standardUserDefaults objectForKey:kMGDirRestoreDefaultsKey];
    if ([pending isKindOfClass:NSNumber.class] && !mg_restore_dir_mode(dir, (mode_t)pending.unsignedIntValue))
        return false;

    struct stat dirStat = {0}, fileStat = {0};
    if (stat(dir, &dirStat) != 0 || stat(path.fileSystemRepresentation, &fileStat) != 0) {
        printf("[MG] stat failed errno=%d\n", errno);
        return false;
    }
    mode_t finalMode = fileStat.st_mode & 07777;
    printf("[MG] folder uid=%u mode=%o; file uid=%u gid=%u mode=%o\n", dirStat.st_uid, dirStat.st_mode & 07777,
           fileStat.st_uid, fileStat.st_gid, finalMode);

    bool widened = false;
    if (access(dir, W_OK | X_OK) != 0) {
        mode_t writable = (dirStat.st_mode | S_IWOTH | S_IXOTH) & 07777;
        [NSUserDefaults.standardUserDefaults setObject:@(dirStat.st_mode & 07777) forKey:kMGDirRestoreDefaultsKey];
        (void)vnode_apfs_chmod(dir, writable);
        if (!mg_mode_is(dir, writable)) {
            printf("[MG] widening the folder failed\n");
            (void)mg_restore_dir_mode(dir, dirStat.st_mode);
            return false;
        }
        widened = true;
    }

    bool ok = false;
    int fd = -1;
    do {
        unlink(temp.fileSystemRepresentation);
        fd = open(temp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) { printf("[MG] open temp failed errno=%d\n", errno); break; }
        if (!mg_write_all(fd, data)) { printf("[MG] write failed errno=%d\n", errno); break; }
        if (fchmod(fd, finalMode) != 0) printf("[MG] fchmod temp %o errno=%d; trying the kernel route\n", finalMode, errno);
        if (fsync(fd) != 0) { printf("[MG] fsync failed errno=%d\n", errno); break; }
        int closeRC = close(fd);
        fd = -1;
        if (closeRC != 0) { printf("[MG] close failed errno=%d\n", errno); break; }
        struct stat tempStat = {0};
        if (stat(temp.fileSystemRepresentation, &tempStat) != 0) break;
        if ((tempStat.st_uid != fileStat.st_uid || tempStat.st_gid != fileStat.st_gid) &&
            vnode_apfs_chown(temp.fileSystemRepresentation, fileStat.st_uid, fileStat.st_gid) != 0) {
            printf("[MG] chown temp failed\n");
            break;
        }
        if (!mg_mode_is(temp.fileSystemRepresentation, finalMode) &&
            chmod(temp.fileSystemRepresentation, finalMode) != 0 &&
            vnode_apfs_chmod(temp.fileSystemRepresentation, finalMode) != 0 &&
            !mg_mode_is(temp.fileSystemRepresentation, finalMode)) {
            printf("[MG] chmod temp to %o failed\n", finalMode);
            break;
        }
        if (rename(temp.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
            printf("[MG] rename failed errno=%d\n", errno);
            break;
        }
        printf("[MG] wrote the cache (%lu bytes)\n", (unsigned long)data.length);
        ok = true;
    } while (0);

    if (fd >= 0) close(fd);
    if (!ok) unlink(temp.fileSystemRepresentation);
    if (widened && !mg_restore_dir_mode(dir, dirStat.st_mode)) ok = false;
    return ok;
}

// Serializes and checks `plist` the way lara does before overwriting: a
// readable dictionary with CacheExtra and the same CacheData size.
static NSData *mg_checked_data(NSDictionary *plist, NSData *current, NSString **error)
{
    if (![NSPropertyListSerialization propertyList:plist isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
        if (error) *error = @"The edited cache isn't a valid property list.";
        return nil;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:nil];
    NSDictionary *back = mg_parse(data, NSPropertyListImmutable);
    NSDictionary *now = mg_parse(current, NSPropertyListImmutable);
    if (!back) {
        if (error) *error = @"The edited cache failed validation; nothing was written.";
        return nil;
    }
    if (now && [now[kMGCacheData] length] != [back[kMGCacheData] length]) {
        if (error) *error = @"The edited cache's CacheData has the wrong size; nothing was written.";
        return nil;
    }
    return data;
}

static BOOL mg_write_data_checked(NSDictionary *plist, NSString **error)
{
    if (!darksword_prepare_var_rw()) {
        if (error) *error = @"No access to /private/var (the sandbox could not be lifted).";
        return NO;
    }
    NSData *current = [NSData dataWithContentsOfFile:MG_CACHE_PATH];
    if (current.length == 0) {
        if (error) *error = @"The current cache is empty or unreadable; nothing was written.";
        return NO;
    }
    NSData *data = mg_checked_data(plist, current, error);
    if (!data) return NO;
    mg_keep_backup(current);
    if (!mg_replace_file(data)) {
        if (error) *error = @"Writing the cache failed. See the [MG] lines in the log.";
        return NO;
    }
    return YES;
}

BOOL mg_write(NSDictionary *mg, NSString **error)
{
    return mg_write_data_checked(mg, error);
}

BOOL mg_restore_original(NSString **error)
{
    NSDictionary *original = mg_parse([NSData dataWithContentsOfFile:mg_original_backup_path()], NSPropertyListImmutable);
    if (!original) {
        if (error) *error = @"There is no original backup.";
        return NO;
    }
    return mg_write_data_checked(original, error);
}
