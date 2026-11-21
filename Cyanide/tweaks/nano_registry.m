//
//  nano_registry.m
//

#import "nano_registry.h"
#import "remote_objc.h"
#import "../LogTextView.h"
#import "../TaskRop/RemoteCall.h"
#import "../kexploit/kexploit_opa334.h"
#import "../kexploit/krw.h"
#import "../kexploit/kutils.h"
#import "../kexploit/offsets.h"
#import "../kexploit/persistence.h"
#import "../utils/sandbox.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <errno.h>
#import <notify.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <unistd.h>

static NSString * const kNanoRegistryPlistPath =
    @"/var/mobile/Library/Preferences/com.apple.NanoRegistry.plist";
static NSString * const kNanoRegistryDPlistPath =
    @"/var/mobile/Library/Preferences/com.apple.nanoregistryd.plist";
static NSString * const kNanoPairingCompatibilityAssetName =
    @"NanoRegistryPairingCompatibilityIndex.plist";

static NSString * const kKeyMax        = @"maxPairingCompatibilityVersion";
static NSString * const kKeyMin        = @"minPairingCompatibilityVersion";
static NSString * const kKeyMinChipID  = @"minPairingCompatibilityVersionWithChipID";
static NSString * const kKeyMinQuick   = @"minQuickSwitchCompatibilityVersion";

// Notify token NRPairingCompatibilityVersionInfo registers for so it picks up
// new values without a respring. Posting it on its own doesn't refresh
// cfprefsd's cache, so callers still need a respring/reboot in practice —
// the post just lets us announce intent.
static const char *kNanoRegistryChangeNotification =
    "com.apple.nanoregistry.pairingcompatibilityversion";

static NSString *nano_registry_short_value(id value);

// Try to land /private/var rw access for the app, mirroring what
// darksword_ota does. Order: existing sandbox → launchd-issued file token →
// patch_sandbox_ext → borrow extensions from known-good donors.
static bool nano_registry_prepare_sandbox(void)
{
    if (check_sandbox_var_rw() == 0) {
        return true;
    }

    if (krw_persistence_consume_launchd_root_file_token() &&
        check_sandbox_var_rw() == 0) {
        printf("[NANO] sandbox ok via launchd root file token\n");
        return true;
    }

    if (patch_sandbox_ext() == 0 && check_sandbox_var_rw() == 0) {
        printf("[NANO] sandbox ok via patch_sandbox_ext\n");
        return true;
    }

    static const char *donors[] = {
        "cfprefsd",
        "sysdiagnosed",
        "softwareupdateservicesd",
        "mobile_installation_proxy",
        "installd",
        NULL,
    };

    for (int i = 0; donors[i]; i++) {
        if (borrow_sandbox_ext(donors[i]) == 0 && check_sandbox_var_rw() == 0) {
            printf("[NANO] sandbox ok via borrow_sandbox_ext(%s)\n", donors[i]);
            return true;
        }
    }

    printf("[NANO] could not unlock /private/var rw access\n");
    return false;
}

static NSMutableDictionary *nano_registry_read_plist(BOOL *outExisted)
{
    if (outExisted) *outExisted = NO;

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:kNanoRegistryPlistPath
                                          options:0
                                            error:&readError];
    if (data.length == 0) {
        if (readError && [readError.domain isEqualToString:NSCocoaErrorDomain] &&
            readError.code == NSFileReadNoSuchFileError) {
            return [NSMutableDictionary dictionary];
        }
        printf("[NANO] read %s failed: %s\n",
               kNanoRegistryPlistPath.UTF8String,
               readError ? readError.description.UTF8String : "empty file");
        // Unreadable or empty is not "absent": only a missing file (above) is.
        // Left as NO, callers took a failed read for "no override" -- Clear
        // then reported success while the override was still in place.
        if (outExisted) *outExisted = YES;
        return nil;
    }

    if (outExisted) *outExisted = YES;

    NSError *parseError = nil;
    id obj = [NSPropertyListSerialization
        propertyListWithData:data
                     options:NSPropertyListMutableContainersAndLeaves
                      format:NULL
                       error:&parseError];
    if (![obj isKindOfClass:NSMutableDictionary.class]) {
        printf("[NANO] parse %s failed: %s\n",
               kNanoRegistryPlistPath.UTF8String,
               parseError ? parseError.description.UTF8String : "not a dictionary");
        return nil;
    }
    return (NSMutableDictionary *)obj;
}

static bool nano_registry_write_plist(NSDictionary *plist)
{
    NSError *serializeError = nil;
    NSData *outData = [NSPropertyListSerialization
        dataWithPropertyList:plist
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:&serializeError];
    if (outData.length == 0) {
        printf("[NANO] serialize failed: %s\n",
               serializeError ? serializeError.description.UTF8String : "empty");
        return false;
    }

    struct stat existing = {0};
    BOOL hadExisting = (stat(kNanoRegistryPlistPath.UTF8String, &existing) == 0);

    NSError *writeError = nil;
    BOOL ok = [outData writeToFile:kNanoRegistryPlistPath
                           options:NSDataWritingAtomic
                             error:&writeError];
    if (!ok) {
        printf("[NANO] write %s failed: %s\n",
               kNanoRegistryPlistPath.UTF8String,
               writeError ? writeError.description.UTF8String : "unknown");
        return false;
    }

    if (hadExisting) {
        if (chown(kNanoRegistryPlistPath.UTF8String, existing.st_uid, existing.st_gid) != 0) {
            printf("[NANO] chown restore errno=%d\n", errno);
        }
        if (chmod(kNanoRegistryPlistPath.UTF8String, existing.st_mode & 07777) != 0) {
            printf("[NANO] chmod restore errno=%d\n", errno);
        }
    } else {
        chmod(kNanoRegistryPlistPath.UTF8String, 0644);
    }

    int notifyRet = notify_post(kNanoRegistryChangeNotification);
    printf("[NANO] wrote %lu bytes to %s; notify_post(%s) ret=%d\n",
           (unsigned long)outData.length,
           kNanoRegistryPlistPath.UTF8String,
           kNanoRegistryChangeNotification,
           notifyRet);
    return true;
}

bool nano_registry_load(nano_registry_values *out_values, bool *out_present)
{
    if (!out_values) return false;
    if (out_present) *out_present = false;

    BOOL existed = NO;
    NSMutableDictionary *plist = nano_registry_read_plist(&existed);
    if (!plist) {
        return existed ? false : true;
    }

    bool anyKey = false;
    id v;
    if ((v = plist[kKeyMax])       && [v respondsToSelector:@selector(intValue)]) { out_values->max_pairing         = [v intValue]; anyKey = true; }
    if ((v = plist[kKeyMin])       && [v respondsToSelector:@selector(intValue)]) { out_values->min_pairing         = [v intValue]; anyKey = true; }
    if ((v = plist[kKeyMinChipID]) && [v respondsToSelector:@selector(intValue)]) { out_values->min_pairing_chip_id = [v intValue]; anyKey = true; }
    if ((v = plist[kKeyMinQuick])  && [v respondsToSelector:@selector(intValue)]) { out_values->min_quick_switch    = [v intValue]; anyKey = true; }

    if (out_present) *out_present = anyKey;
    return true;
}

bool nano_registry_apply(const nano_registry_values *values)
{
    if (!kexploit_krw_ready()) {
        printf("[NANO] refusing apply: KRW is not active/recovered\n");
        log_user("[NANO] Failed: kernel recovery is not active. Run the chain first.\n");
        return false;
    }

    if (!values) return false;

    if (values->min_pairing > values->max_pairing
        || values->min_pairing_chip_id > values->max_pairing
        || values->min_quick_switch > values->max_pairing) {
        printf("[NANO] refuse apply: min* (%d/%d/%d) must be <= max (%d)\n",
               values->min_pairing, values->min_pairing_chip_id,
               values->min_quick_switch, values->max_pairing);
        return false;
    }

    if (!nano_registry_prepare_sandbox()) return false;

    BOOL existed = NO;
    NSMutableDictionary *plist = nano_registry_read_plist(&existed);
    if (!plist) {
        printf("[NANO] apply aborted: plist unreadable\n");
        return false;
    }

    plist[kKeyMax]       = @(values->max_pairing);
    plist[kKeyMin]       = @(values->min_pairing);
    plist[kKeyMinChipID] = @(values->min_pairing_chip_id);
    plist[kKeyMinQuick]  = @(values->min_quick_switch);

    if (!nano_registry_write_plist(plist)) return false;

    log_user("[NANO] Wrote pairing gates: max=%d min=%d minChip=%d minQuick=%d. Respring/reboot to apply.\n",
             values->max_pairing,
             values->min_pairing,
             values->min_pairing_chip_id,
             values->min_quick_switch);
    return true;
}

bool nano_registry_clear(void)
{
    if (!kexploit_krw_ready()) {
        printf("[NANO] refusing clear: KRW is not active/recovered\n");
        log_user("[NANO] Failed: kernel recovery is not active. Run the chain first.\n");
        return false;
    }

    if (!nano_registry_prepare_sandbox()) return false;

    BOOL existed = NO;
    NSMutableDictionary *plist = nano_registry_read_plist(&existed);
    if (!plist) {
        if (!existed) {
            log_user("[NANO] No override to clear (plist absent).\n");
            return true;
        }
        return false;
    }

    int removed = 0;
    for (NSString *key in @[kKeyMax, kKeyMin, kKeyMinChipID, kKeyMinQuick]) {
        if (plist[key]) { [plist removeObjectForKey:key]; removed++; }
    }

    if (removed == 0) {
        log_user("[NANO] No override keys present; nothing to clear.\n");
        return true;
    }

    if (!nano_registry_write_plist(plist)) return false;
    log_user("[NANO] Cleared %d override key(s). Respring/reboot to apply.\n", removed);
    return true;
}

static id nano_registry_read_any_plist(NSString *path)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) return nil;

    NSError *error = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data
                                                        options:0
                                                         format:NULL
                                                          error:&error];
    if (!obj && error) {
        log_user("[NANO-PROBE] plist parse failed %s: %s\n",
                 path.UTF8String, error.description.UTF8String);
    }
    return obj;
}

static bool nano_registry_write_any_plist(NSString *path, id plist, const char *tag)
{
    NSError *serializeError = nil;
    NSData *outData = [NSPropertyListSerialization
        dataWithPropertyList:plist
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:&serializeError];
    if (outData.length == 0) {
        log_user("[%s] serialize failed for %s: %s\n",
                 tag,
                 path.UTF8String,
                 serializeError ? serializeError.description.UTF8String : "empty");
        return false;
    }

    struct stat existing = {0};
    BOOL hadExisting = (stat(path.UTF8String, &existing) == 0);

    NSError *writeError = nil;
    BOOL ok = [outData writeToFile:path options:NSDataWritingAtomic error:&writeError];
    if (!ok) {
        log_user("[%s] write failed for %s: %s\n",
                 tag,
                 path.UTF8String,
                 writeError ? writeError.description.UTF8String : "unknown");
        return false;
    }

    if (hadExisting) {
        if (chown(path.UTF8String, existing.st_uid, existing.st_gid) != 0) {
            log_user("[%s] chown restore failed for %s errno=%d\n",
                     tag, path.UTF8String, errno);
        }
        if (chmod(path.UTF8String, existing.st_mode & 07777) != 0) {
            log_user("[%s] chmod restore failed for %s errno=%d\n",
                     tag, path.UTF8String, errno);
        }
    }

    log_user("[%s] wrote %lu bytes to %s\n",
             tag, (unsigned long)outData.length, path.UTF8String);
    return true;
}

static bool nano_registry_backup_file_once(NSString *path, const char *tag)
{
    NSString *backup = [path stringByAppendingString:@".cyanide.bak"];
    if ([NSFileManager.defaultManager fileExistsAtPath:backup]) {
        log_user("[%s] backup already exists: %s\n", tag, backup.UTF8String);
        return true;
    }

    NSError *error = nil;
    BOOL ok = [NSFileManager.defaultManager copyItemAtPath:path
                                                    toPath:backup
                                                     error:&error];
    if (!ok) {
        log_user("[%s] backup failed %s -> %s: %s\n",
                 tag,
                 path.UTF8String,
                 backup.UTF8String,
                 error ? error.description.UTF8String : "unknown");
        return false;
    }

    log_user("[%s] backed up original to %s\n", tag, backup.UTF8String);
    return true;
}

static NSString *nano_registry_latest_compatibility_index_path(void)
{
    NSDictionary *daemonPrefs = nano_registry_read_any_plist(kNanoRegistryDPlistPath);
    if (![daemonPrefs isKindOfClass:NSDictionary.class]) return nil;

    id value = daemonPrefs[@"latestAssetURL"];
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] == 0) {
        return nil;
    }

    NSURL *url = [NSURL URLWithString:value];
    NSString *assetPath = url.isFileURL ? url.path : value;
    if (assetPath.length == 0) return nil;
    return [assetPath stringByAppendingPathComponent:kNanoPairingCompatibilityAssetName];
}

static NSString *nano_registry_short_value(id value)
{
    if (!value || value == (id)kCFNull) {
        return @"(nil)";
    } else if ([value isKindOfClass:NSString.class]) {
        return value;
    } else if ([value isKindOfClass:NSNumber.class]) {
        return [(NSNumber *)value stringValue];
    } else if ([value isKindOfClass:NSDictionary.class]) {
        return [NSString stringWithFormat:@"<dict:%lu>", (unsigned long)[(NSDictionary *)value count]];
    } else if ([value isKindOfClass:NSArray.class]) {
        return [NSString stringWithFormat:@"<array:%lu>", (unsigned long)[(NSArray *)value count]];
    } else if ([value isKindOfClass:NSData.class]) {
        return [NSString stringWithFormat:@"<data:%lu>", (unsigned long)[(NSData *)value length]];
    }
    return [NSString stringWithFormat:@"<%@>", NSStringFromClass([value class])];
}

static NSString *nano_registry_current_product_type(void)
{
    struct utsname u;
    if (uname(&u) == 0 && u.machine[0]) {
        return [NSString stringWithUTF8String:u.machine];
    }
    return @"unknown";
}

static NSString *nano_registry_join_limited_strings(NSArray *values, NSUInteger limit)
{
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    for (id value in values) {
        if (![value isKindOfClass:NSString.class]) continue;
        [strings addObject:value];
    }
    [strings sortUsingSelector:@selector(localizedStandardCompare:)];

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *value in strings) {
        if (out.count >= limit) break;
        [out addObject:value];
    }
    NSString *joined = [out componentsJoinedByString:@","];
    if (strings.count > out.count) {
        joined = [joined stringByAppendingFormat:@",...(+%lu)",
                  (unsigned long)(strings.count - out.count)];
    }
    return joined.length ? joined : @"(none)";
}

static NSString *nano_registry_join_limited_key_values(NSDictionary *dict, NSUInteger limit)
{
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (id key in dict) {
        if ([key isKindOfClass:NSString.class]) {
            [keys addObject:key];
        }
    }
    [keys sortUsingSelector:@selector(localizedStandardCompare:)];

    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    for (NSString *key in keys) {
        if (pairs.count >= limit) break;
        [pairs addObject:[NSString stringWithFormat:@"%@=%@",
                                                    key,
                                                    nano_registry_short_value(dict[key])]];
    }
    NSString *joined = [pairs componentsJoinedByString:@","];
    if (keys.count > pairs.count) {
        joined = [joined stringByAppendingFormat:@",...(+%lu)",
                  (unsigned long)(keys.count - pairs.count)];
    }
    return joined.length ? joined : @"(none)";
}

static uint64_t nano_registry_remote_objc_constant(const char *symbol)
{
    uint64_t name = r_alloc_str(symbol);
    if (!name) return 0;

    // RTLD_DEFAULT == (void *)-2. This only resolves a symbol from images the
    // target process already has loaded; it does not load a dylib.
    uint64_t slot = do_remote_call_stable(R_TIMEOUT, "dlsym",
                                          0xfffffffffffffffeULL,
                                          name,
                                          0, 0, 0, 0, 0, 0);
    r_free(name);
    if (!slot) return 0;
    return remote_read64(slot);
}

static BOOL nano_registry_remote_copy_nsstring(uint64_t nsString, char *out, size_t outLen)
{
    if (!out || outLen == 0) return NO;
    out[0] = '\0';
    if (!r_is_objc_ptr(nsString)) return NO;

    uint64_t cstr = r_msg2(nsString, "UTF8String", 0, 0, 0, 0);
    if (!cstr) return NO;

    if (!remote_read(cstr, out, outLen - 1)) return NO;
    out[outLen - 1] = '\0';
    return YES;
}

static BOOL nano_registry_should_alias_watch_product(const char *product)
{
    if (!product || !product[0]) return NO;

    static const char *newWatch7Products[] = {
        "Watch7,12",
        "Watch7,15",
        "Watch7,16",
        "Watch7,19",
        "Watch7,20",
        NULL,
    };

    for (int i = 0; newWatch7Products[i]; i++) {
        if (strcmp(product, newWatch7Products[i]) == 0) return YES;
    }
    return NO;
}

static int nano_registry_steer_alias_in_remote_process(const char *processName)
{
    if (!processName) return 0;

    if (init_remote_call(processName, false) != 0) {
        log_user("[NANO-STEER] %s not running/reachable; skipped.\n", processName);
        return 0;
    }

    int changed = 0;
    @try {
        uint64_t productKey = nano_registry_remote_objc_constant("NRDevicePropertyProductType");
        if (!r_is_objc_ptr(productKey)) {
            log_user("[NANO-STEER] %s has no NRDevicePropertyProductType symbol; skipped.\n",
                     processName);
            goto out;
        }

        uint64_t discoveryClass = r_class("NRDeviceDiscoveryController");
        if (!r_is_objc_ptr(discoveryClass)) {
            log_user("[NANO-STEER] %s has no NRDeviceDiscoveryController class; skipped.\n",
                     processName);
            goto out;
        }

        uint64_t controller = r_msg2(discoveryClass, "sharedInstance", 0, 0, 0, 0);
        if (!r_is_objc_ptr(controller)) {
            log_user("[NANO-STEER] %s NRDeviceDiscoveryController sharedInstance is nil.\n",
                     processName);
            goto out;
        }

        (void)r_msg2(controller, "begin", 0, 0, 0, 0);
        sleep(3);

        uint64_t devices = r_msg2(controller, "devices", 0, 0, 0, 0);
        uint64_t count = r_is_objc_ptr(devices) ? r_msg2(devices, "count", 0, 0, 0, 0) : 0;
        log_user("[NANO-STEER] %s discovery devices=%llu\n",
                 processName,
                 (unsigned long long)count);

        if (!count) goto out;

        uint64_t alias = r_nsstr_retained("Watch7,11");
        if (!r_is_objc_ptr(alias)) {
            log_user("[NANO-STEER] %s could not allocate alias string.\n", processName);
            goto out;
        }

        for (uint64_t i = 0; i < count && i < 12; i++) {
            uint64_t device = r_msg2(devices, "objectAtIndex:", i, 0, 0, 0);
            if (!r_is_objc_ptr(device)) continue;

            uint64_t oldProduct = r_msg2(device, "valueForProperty:", productKey, 0, 0, 0);
            char oldBuf[96] = {0};
            BOOL hasOld = nano_registry_remote_copy_nsstring(oldProduct, oldBuf, sizeof(oldBuf));
            BOOL shouldAlias = nano_registry_should_alias_watch_product(oldBuf);
            if (!shouldAlias && !hasOld && count == 1) {
                shouldAlias = YES;
            }

            if (!shouldAlias) {
                log_user("[NANO-STEER] %s device[%llu] product=%s unchanged.\n",
                         processName,
                         (unsigned long long)i,
                         hasOld ? oldBuf : "(nil)");
                continue;
            }

            uint64_t ok = r_msg2(device, "setValue:forProperty:", alias, productKey, 0, 0);
            if ((ok & 0xff) == 0 && r_responds(device, "_setValue:forProperty:")) {
                (void)r_msg2(device, "_setValue:forProperty:", alias, productKey, 0, 0);
                ok = 1;
            }

            uint64_t newProduct = r_msg2(device, "valueForProperty:", productKey, 0, 0, 0);
            char newBuf[96] = {0};
            (void)nano_registry_remote_copy_nsstring(newProduct, newBuf, sizeof(newBuf));

            log_user("[NANO-STEER] %s device[%llu] product %s -> %s ok=%llu\n",
                     processName,
                     (unsigned long long)i,
                     hasOld ? oldBuf : "(nil)",
                     newBuf[0] ? newBuf : "(nil)",
                     (unsigned long long)(ok & 0xff));
            changed++;
        }

        if (r_is_objc_ptr(alias)) {
            (void)r_msg2(alias, "release", 0, 0, 0, 0);
        }
out:
        destroy_remote_call();
    } @catch (NSException *e) {
        log_user("[NANO-STEER] %s exception: %s\n",
                 processName,
                 e.reason.UTF8String);
        destroy_remote_call();
    }

    return changed;
}

bool nano_registry_steer_new_watch_product_alias(void)
{
    log_user("[NANO-STEER] Steering newer Watch7 products to Watch7,11; no dlopen, no code patching.\n");

    const char *targets[] = {
        "Bridge",
        "nanoregistryd",
        "companion_proxy",
        "DKPairingUIService",
        "CompanionViewService",
        NULL,
    };

    int changed = 0;
    for (int i = 0; targets[i]; i++) {
        changed += nano_registry_steer_alias_in_remote_process(targets[i]);
    }

    log_user("[NANO-STEER] total product alias mutation(s)=%d\n", changed);
    return changed > 0;
}

static BOOL nano_registry_string_has_probe_needle(NSString *s)
{
    static NSArray<NSString *> *needles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        needles = @[
            @"NanoRegistryPairingCompatibilityIndex",
            @"N230",
            @"Skipper",
            @"Watch7",
            @"Ultra",
            @"2025",
            @"WatchSideBySide",
            @"M17",
            @"M15",
            @"M12",
            @"iPhone17",
        ];
    });

    for (NSString *needle in needles) {
        if ([s rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static void nano_registry_log_path_state(NSString *path)
{
    BOOL isDir = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
    log_user("[NANO-PROBE] %s: %s\n",
             path.UTF8String,
             exists ? (isDir ? "dir" : "file") : "missing");
}

static BOOL nano_registry_probe_name_interesting(NSString *name)
{
    return nano_registry_string_has_probe_needle(name);
}

static void nano_registry_probe_walk(NSString *path,
                                     NSUInteger depth,
                                     NSUInteger *visited,
                                     NSUInteger *logged)
{
    if (!path || depth == 0 || !visited || !logged || *visited >= 400 || *logged >= 80) {
        return;
    }

    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        return;
    }

    NSError *error = nil;
    NSArray<NSString *> *children = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:&error];
    if (!children) {
        log_user("[NANO-PROBE] list failed %s: %s\n",
                 path.UTF8String,
                 error ? error.description.UTF8String : "unknown");
        return;
    }

    for (NSString *child in children) {
        if (*visited >= 400 || *logged >= 80) break;
        NSString *full = [path stringByAppendingPathComponent:child];
        (*visited)++;

        BOOL childIsDir = NO;
        (void)[NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&childIsDir];
        if (nano_registry_probe_name_interesting(child)) {
            log_user("[NANO-PROBE] hit %s%s\n",
                     full.UTF8String,
                     childIsDir ? "/" : "");
            (*logged)++;
        }
        if (childIsDir) {
            nano_registry_probe_walk(full, depth - 1, visited, logged);
        }
    }
}

static void nano_registry_probe_search_plist(id obj,
                                             NSString *path,
                                             NSUInteger depth,
                                             NSUInteger *logged)
{
    if (!obj || !path || !logged || depth > 6 || *logged >= 60) return;

    if ([obj isKindOfClass:NSString.class]) {
        NSString *s = (NSString *)obj;
        if (nano_registry_string_has_probe_needle(s)) {
            log_user("[NANO-PROBE] plist hit %s = %s\n",
                     path.UTF8String,
                     nano_registry_short_value(s).UTF8String);
            (*logged)++;
        }
        return;
    }

    if ([obj isKindOfClass:NSNumber.class]) {
        if (nano_registry_string_has_probe_needle(path)) {
            log_user("[NANO-PROBE] plist hit %s = %s\n",
                     path.UTF8String,
                     nano_registry_short_value(obj).UTF8String);
            (*logged)++;
        }
        return;
    }

    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)obj;
        for (id key in dict) {
            if (*logged >= 60) break;
            NSString *keyString = [key isKindOfClass:NSString.class]
                ? key
                : [key description];
            NSString *childPath = [path stringByAppendingFormat:@".%@", keyString];
            if (nano_registry_string_has_probe_needle(keyString)) {
                log_user("[NANO-PROBE] plist hit %s = %s\n",
                         childPath.UTF8String,
                         nano_registry_short_value(dict[key]).UTF8String);
                (*logged)++;
            }
            nano_registry_probe_search_plist(dict[key], childPath, depth + 1, logged);
        }
        return;
    }

    if ([obj isKindOfClass:NSArray.class]) {
        NSArray *array = (NSArray *)obj;
        NSUInteger idx = 0;
        for (id value in array) {
            if (*logged >= 60) break;
            NSString *childPath = [path stringByAppendingFormat:@"[%lu]", (unsigned long)idx++];
            nano_registry_probe_search_plist(value, childPath, depth + 1, logged);
        }
    }
}

static void nano_registry_probe_compatibility_index(NSString *compatPath)
{
    id plist = nano_registry_read_any_plist(compatPath);
    if (![plist isKindOfClass:NSDictionary.class]) {
        log_user("[NANO-PROBE] compatibility index missing/unreadable at %s\n",
                 compatPath.UTF8String);
        return;
    }

    NSDictionary *root = (NSDictionary *)plist;
    log_user("[NANO-PROBE] compatibility index top keys(%lu): %s\n",
             (unsigned long)root.count,
             nano_registry_join_limited_strings(root.allKeys, 20).UTF8String);

    id iPhoneObj = root[@"iPhone"];
    if ([iPhoneObj isKindOfClass:NSDictionary.class]) {
        NSDictionary *iPhone = (NSDictionary *)iPhoneObj;
        NSString *product = nano_registry_current_product_type();
        log_user("[NANO-PROBE] compatibility iPhone entries=%lu current[%s]=%s iPhone17*=%s\n",
                 (unsigned long)iPhone.count,
                 product.UTF8String,
                 nano_registry_short_value(iPhone[product]).UTF8String,
                 nano_registry_join_limited_strings([iPhone.allKeys filteredArrayUsingPredicate:
                     [NSPredicate predicateWithBlock:^BOOL(id key, NSDictionary *bindings) {
                         (void)bindings;
                         return [key isKindOfClass:NSString.class] &&
                                [key hasPrefix:@"iPhone17"];
                     }]], 20).UTF8String);
        log_user("[NANO-PROBE] compatibility iPhone map: %s\n",
                 nano_registry_join_limited_key_values(iPhone, 30).UTF8String);
    } else {
        log_user("[NANO-PROBE] compatibility index has no iPhone dictionary.\n");
    }

    NSUInteger logged = 0;
    nano_registry_probe_search_plist(root, @"compat", 0, &logged);
    log_user("[NANO-PROBE] compatibility needle hits=%lu\n", (unsigned long)logged);
}

bool nano_registry_seed_current_phone_compatibility_index(int max_pairing_version)
{
    log_user("[NANO-SEED] Starting data-only compatibility-index seed; no code patching.\n");

    if (max_pairing_version < 1) {
        max_pairing_version = 99;
    }
    if (!nano_registry_prepare_sandbox()) return false;

    NSString *compatPath = nano_registry_latest_compatibility_index_path();
    if (compatPath.length == 0) {
        log_user("[NANO-SEED] no latestAssetURL compatibility-index path.\n");
        return false;
    }

    id plist = nano_registry_read_any_plist(compatPath);
    if (![plist isKindOfClass:NSDictionary.class]) {
        log_user("[NANO-SEED] compatibility index missing/unreadable at %s\n",
                 compatPath.UTF8String);
        return false;
    }

    NSMutableDictionary *root = [(NSDictionary *)plist mutableCopy];
    id iPhoneObj = root[@"iPhone"];
    if (![iPhoneObj isKindOfClass:NSDictionary.class]) {
        log_user("[NANO-SEED] compatibility index has no iPhone dictionary.\n");
        return false;
    }

    NSMutableDictionary *iPhone = [(NSDictionary *)iPhoneObj mutableCopy];
    NSString *product = nano_registry_current_product_type();
    NSNumber *oldValue = iPhone[product];
    NSNumber *newValue = @(max_pairing_version);
    log_user("[NANO-SEED] current product=%s old=%s new=%s\n",
             product.UTF8String,
             nano_registry_short_value(oldValue).UTF8String,
             nano_registry_short_value(newValue).UTF8String);

    if (!nano_registry_backup_file_once(compatPath, "NANO-SEED")) {
        return false;
    }

    iPhone[product] = newValue;
    root[@"iPhone"] = iPhone;
    if (!nano_registry_write_any_plist(compatPath, root, "NANO-SEED")) {
        return false;
    }

    int notifyRet = notify_post(kNanoRegistryChangeNotification);
    log_user("[NANO-SEED] notify_post(%s) ret=%d\n",
             kNanoRegistryChangeNotification, notifyRet);
    nano_registry_probe_compatibility_index(compatPath);
    return true;
}

bool nano_registry_probe_pairing_assets(void)
{
    log_user("[NANO-PROBE] Starting data-only pairing asset probe; no code patching.\n");

    if (!nano_registry_prepare_sandbox()) return false;

    NSDictionary *nanoPrefs = nano_registry_read_any_plist(kNanoRegistryPlistPath);
    if ([nanoPrefs isKindOfClass:NSDictionary.class]) {
        log_user("[NANO-PROBE] com.apple.NanoRegistry max=%s min=%s minChip=%s minQuick=%s overrideDict=%s\n",
                 nano_registry_short_value(nanoPrefs[kKeyMax]).UTF8String,
                 nano_registry_short_value(nanoPrefs[kKeyMin]).UTF8String,
                 nano_registry_short_value(nanoPrefs[kKeyMinChipID]).UTF8String,
                 nano_registry_short_value(nanoPrefs[kKeyMinQuick]).UTF8String,
                 nano_registry_short_value(nanoPrefs[@"compatibilityIndexOverride"]).UTF8String);
    } else {
        log_user("[NANO-PROBE] com.apple.NanoRegistry plist missing or unreadable.\n");
    }

    NSDictionary *daemonPrefs = nano_registry_read_any_plist(kNanoRegistryDPlistPath);
    NSString *latestAssetURL = nil;
    if ([daemonPrefs isKindOfClass:NSDictionary.class]) {
        id value = daemonPrefs[@"latestAssetURL"];
        if ([value isKindOfClass:NSString.class]) latestAssetURL = value;
        log_user("[NANO-PROBE] com.apple.nanoregistryd latestAssetURL=%s\n",
                 nano_registry_short_value(value).UTF8String);
    } else {
        log_user("[NANO-PROBE] com.apple.nanoregistryd plist missing or unreadable.\n");
    }

    if (latestAssetURL.length > 0) {
        NSURL *url = [NSURL URLWithString:latestAssetURL];
        NSString *assetPath = url.isFileURL ? url.path : latestAssetURL;
        NSString *compatPath = [assetPath stringByAppendingPathComponent:kNanoPairingCompatibilityAssetName];
        nano_registry_log_path_state(assetPath);
        nano_registry_log_path_state(compatPath);
        nano_registry_probe_compatibility_index(compatPath);
    } else {
        log_user("[NANO-PROBE] no latestAssetURL; NanoRegistry will not find a local compatibility-index asset.\n");
    }

    NSArray<NSString *> *roots = @[
        @"/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_BridgeAssets",
        @"/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_ProductKit",
        @"/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_NanoRegistry",
        @"/private/var/mobile/Library/Caches/ProductKit",
        @"/private/var/mobile/Library/Caches/com.apple.Bridge",
        @"/private/var/mobile/Library/Caches/com.apple.NanoRegistry",
    ];
    for (NSString *root in roots) {
        nano_registry_log_path_state(root);
        NSUInteger visited = 0;
        NSUInteger logged = 0;
        nano_registry_probe_walk(root, 4, &visited, &logged);
        log_user("[NANO-PROBE] scanned %lu item(s), logged %lu hit(s) under %s\n",
                 (unsigned long)visited,
                 (unsigned long)logged,
                 root.UTF8String);
    }

    log_user("[NANO-PROBE] Done. Missing latestAssetURL or compatibility-index hits points to the data-only asset path, not a binary patch.\n");
    return true;
}

// --- cfprefsd cache hint -----------------------------------------------------
//
// Keep NanoRegistry Apply as a file edit only. The old path opened a launchd
// RemoteCall session and SIGKILLed cfprefsd, NanoRegistry, Bluetooth, and
// proximity daemons to force a live cache refresh. That is too much work for a
// settings toggle and can panic 26.x devices while KRW is otherwise healthy.
// A respring/reboot is the stable boundary for making the new plist visible.

bool nano_registry_push_to_cfprefsd(const nano_registry_values *values, bool apply)
{
    (void)values;
    (void)apply;

    int notifyRet = notify_post(kNanoRegistryChangeNotification);
    log_user("[NANO-PUSH] live daemon reset skipped for stability; notify_post ret=%d. "
             "Respring or reboot before pairing so cfprefsd/NanoRegistry reload the plist.\n",
             notifyRet);
    // Nothing reached cfprefsd's cache, so this is not a successful push:
    // callers report a partial result (file written, respring still needed)
    // instead of a clean success.
    return false;
}
