//
//  RepoTweaks.m
//

#import <JavaScriptCore/JavaScriptCore.h>
#import "RepoTweaks.h"
#import "QuickLoader.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"
#import "../utils/file.h"
#import "../SettingsViewController.h"
#import <CommonCrypto/CommonDigest.h>
#import <math.h>
#import <pthread.h>

extern uint64_t r_nsstr_retained(const char *str);

static const NSUInteger kRepoTweaksMaxRepoBytes = 512 * 1024;
static const NSUInteger kRepoTweaksMaxScriptBytes = 512 * 1024;
static NSString * const kRepoTweaksDefaultRepoURL = @"https://raw.githubusercontent.com/MinePlayer16/MinePlayer16.github.io/refs/heads/main/repotweaks.json";
static NSString * const kRepoTweaksDefaultReposSeedVersionKey = @"RepoTweaksDefaultReposSeedVersion";
static NSString * const kRepoTweaksDefaultReposSeedVersion = @"6";
static NSString * const kRepoTweaksHideHomeBarMaterialKitAssets =
    @"/System/Library/PrivateFrameworks/MaterialKit.framework/Assets.car";

static NSMutableDictionary<NSString *, JSContext *> *g_repo_contexts = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, id> *> *g_repo_timers_registry = nil;
static int g_repo_timer_id_counter = 0;
static int g_repo_shutting_down = 0;
static char g_repo_queue_key;
static pthread_mutex_t g_repo_queue_lock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t g_repo_queue = nil;
static uint64_t g_repo_generation = 1;

static dispatch_queue_t repotweaks_create_js_queue_locked(void) {
    NSString *label = [NSString stringWithFormat:@"com.zeroxjf.cyanide.repotweaks.js.%llu",
                       (unsigned long long)g_repo_generation];
    dispatch_queue_t q = dispatch_queue_create(label.UTF8String, DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(q, &g_repo_queue_key, &g_repo_queue_key, NULL);
    return q;
}

static dispatch_queue_t repotweaks_js_queue(void) {
    pthread_mutex_lock(&g_repo_queue_lock);
    if (!g_repo_queue) {
        g_repo_queue = repotweaks_create_js_queue_locked();
    }
    dispatch_queue_t q = g_repo_queue;
    pthread_mutex_unlock(&g_repo_queue_lock);
    return q;
}

static uint64_t repotweaks_current_generation(void) {
    pthread_mutex_lock(&g_repo_queue_lock);
    uint64_t generation = g_repo_generation;
    pthread_mutex_unlock(&g_repo_queue_lock);
    return generation;
}

static void repotweaks_set_shutting_down(BOOL shuttingDown) {
    pthread_mutex_lock(&g_repo_queue_lock);
    g_repo_shutting_down = shuttingDown ? 1 : 0;
    pthread_mutex_unlock(&g_repo_queue_lock);
}

static uint64_t repotweaks_begin_apply_generation(void) {
    pthread_mutex_lock(&g_repo_queue_lock);
    g_repo_generation++;
    if (g_repo_generation == 0) g_repo_generation = 1;
    g_repo_shutting_down = 0;
    if (!g_repo_queue) {
        g_repo_queue = repotweaks_create_js_queue_locked();
    }
    uint64_t generation = g_repo_generation;
    pthread_mutex_unlock(&g_repo_queue_lock);
    return generation;
}

static BOOL repotweaks_generation_is_current(uint64_t generation) {
    pthread_mutex_lock(&g_repo_queue_lock);
    BOOL current = (generation == g_repo_generation);
    pthread_mutex_unlock(&g_repo_queue_lock);
    return current;
}

static BOOL repotweaks_generation_is_active(uint64_t generation) {
    pthread_mutex_lock(&g_repo_queue_lock);
    BOOL active = !g_repo_shutting_down && generation == g_repo_generation;
    pthread_mutex_unlock(&g_repo_queue_lock);
    return active;
}

static void repotweaks_abandon_js_queue_after_timeout(const char *reason, BOOL shuttingDown) {
    pthread_mutex_lock(&g_repo_queue_lock);
    g_repo_generation++;
    if (g_repo_generation == 0) g_repo_generation = 1;
    g_repo_shutting_down = shuttingDown ? 1 : 0;
    g_repo_queue = repotweaks_create_js_queue_locked();
    g_repo_contexts = nil;
    g_repo_timers_registry = nil;
    pthread_mutex_unlock(&g_repo_queue_lock);
    log_user("[RepoTweaks] Abandoned wedged JS queue after %s; future runs will use a fresh queue.\n",
             reason ? reason : "timeout");
}

static bool repotweaks_perform_sync_timeout(dispatch_block_t block, int64_t timeoutNsec) {
    if (!block) return true;
    if (dispatch_get_specific(&g_repo_queue_key)) {
        block();
        return true;
    }

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    dispatch_async(repotweaks_js_queue(), ^{
        block();
        dispatch_semaphore_signal(sema);
    });
    dispatch_time_t deadline = timeoutNsec < 0
        ? DISPATCH_TIME_FOREVER
        : dispatch_time(DISPATCH_TIME_NOW, timeoutNsec);
    return dispatch_semaphore_wait(sema, deadline) == 0;
}

static uint64_t repo_js_to_uint64(JSValue *val) {
    if ([val isString]) return strtoull([[val toString] UTF8String], NULL, 16);
    return (uint64_t)[val toDouble];
}

static NSString *repo_uint64_to_js(uint64_t val) {
    return [NSString stringWithFormat:@"0x%llx", val];
}

static BOOL repotweaks_is_https_url(NSString *urlString) {
    if (![urlString isKindOfClass:NSString.class] || urlString.length == 0) return NO;
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    return [components.scheme.lowercaseString isEqualToString:@"https"] && components.host.length > 0;
}

static BOOL repotweaks_valid_identifier(NSString *name) {
    if (![name isKindOfClass:NSString.class] || name.length == 0) return NO;
    unichar first = [name characterAtIndex:0];
    if (![[NSCharacterSet letterCharacterSet] characterIsMember:first] && first != '_' && first != '$') return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$"];
    return [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSString *repotweaks_js_string_literal(NSString *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value ?: @""]
                                                   options:0
                                                     error:nil];
    NSString *arrayLiteral = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (arrayLiteral.length >= 2 && [arrayLiteral hasPrefix:@"["] && [arrayLiteral hasSuffix:@"]"]) {
        return [arrayLiteral substringWithRange:NSMakeRange(1, arrayLiteral.length - 2)];
    }
    return @"\"\"";
}

static NSString *repotweaks_js_number_literal(NSString *value) {
    double number = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
    if (!isfinite(number)) number = 0.0;
    return [NSString stringWithFormat:@"%.12g", number];
}

static NSString *repotweaks_string_or_empty(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
}

NSString *repotweaks_storage_key(NSString *repoURL, NSString *tweakId) {
    NSString *safeURL = repotweaks_string_or_empty(repoURL);
    NSString *safeID = repotweaks_string_or_empty(tweakId);
    NSString *input = [NSString stringWithFormat:@"%@\n%@", safeURL, safeID];
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

NSString *repotweaks_enabled_defaults_key(NSString *repoURL, NSString *tweakId) {
    return [NSString stringWithFormat:@"RepoTweakEnabled_%@", repotweaks_storage_key(repoURL, tweakId)];
}

NSString *repotweaks_script_defaults_key(NSString *repoURL, NSString *tweakId) {
    return [NSString stringWithFormat:@"RepoTweakScript_%@", repotweaks_storage_key(repoURL, tweakId)];
}

NSString *repotweaks_values_defaults_key(NSString *repoURL, NSString *tweakId) {
    return [NSString stringWithFormat:@"RepoTweakValues_%@", repotweaks_storage_key(repoURL, tweakId)];
}

static NSMutableDictionary *repotweaks_string_values_dictionary(id raw) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (![raw isKindOfClass:NSDictionary.class]) return out;
    [(NSDictionary *)raw enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        (void)stop;
        if ([key isKindOfClass:NSString.class] && [obj isKindOfClass:NSString.class]) {
            out[key] = obj;
        }
    }];
    return out;
}

static NSString *repotweaks_pref_string(NSString *storageKey, NSString *key) {
    if (![storageKey isKindOfClass:NSString.class] || storageKey.length == 0 ||
        ![key isKindOfClass:NSString.class]) {
        return @"";
    }
    NSString *valuesKey = [NSString stringWithFormat:@"RepoTweakValues_%@", storageKey];
    NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:valuesKey];
    id value = [prefs isKindOfClass:NSDictionary.class] ? prefs[key] : nil;
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static BOOL repotweaks_seed_default_values_for_script(NSUserDefaults *d, NSString *repoURL, NSString *tweakId, NSString *jsCode) {
    if (![jsCode isKindOfClass:NSString.class] || jsCode.length == 0) return NO;

    NSString *valuesKey = repotweaks_values_defaults_key(repoURL, tweakId);
    NSMutableDictionary *values = repotweaks_string_values_dictionary([d dictionaryForKey:valuesKey]);
    BOOL changed = NO;

    for (NSString *line in [jsCode componentsSeparatedByString:@"\n"]) {
        if (![line containsString:@"@param:"]) continue;
        NSArray *parts = [line componentsSeparatedByString:@"|"];
        if (parts.count < 4) continue;

        NSString *varName = [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *defValue = [parts[3] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!repotweaks_valid_identifier(varName)) continue;

        if (![values[varName] isKindOfClass:NSString.class]) {
            values[varName] = defValue ?: @"";
            changed = YES;
        }
    }

    if (changed) {
        [d setObject:values forKey:valuesKey];
    }
    return changed;
}

static BOOL repotweaks_content_type_matches(NSHTTPURLResponse *response, NSArray<NSString *> *allowedPrefixes) {
    if (![response isKindOfClass:NSHTTPURLResponse.class]) return YES;
    NSString *contentType = response.allHeaderFields[@"Content-Type"];
    if (![contentType isKindOfClass:NSString.class] || contentType.length == 0) return YES;
    NSString *lower = contentType.lowercaseString;
    for (NSString *prefix in allowedPrefixes) {
        if ([lower hasPrefix:prefix]) return YES;
    }
    return NO;
}

static NSString *repotweaks_cache_busted_url_string(NSString *urlString) {
    if (![urlString isKindOfClass:NSString.class] || urlString.length == 0) return @"";
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    if (!components || ![components.scheme.lowercaseString isEqualToString:@"https"] || components.host.length == 0) {
        return urlString;
    }

    NSMutableArray<NSURLQueryItem *> *items = [[components.queryItems ?: @[] mutableCopy] ?: [NSMutableArray array] mutableCopy];
    for (NSInteger i = (NSInteger)items.count - 1; i >= 0; i--) {
        if ([items[(NSUInteger)i].name isEqualToString:@"_cyanideBust"]) {
            [items removeObjectAtIndex:(NSUInteger)i];
        }
    }

    NSString *stamp = [NSString stringWithFormat:@"%.0f-%@",
                       NSDate.date.timeIntervalSince1970 * 1000.0,
                       NSUUID.UUID.UUIDString];
    [items addObject:[NSURLQueryItem queryItemWithName:@"_cyanideBust" value:stamp]];
    components.queryItems = items;
    return components.URL.absoluteString ?: urlString;
}

static NSMutableURLRequest *repotweaks_uncached_request(NSString *urlString, NSTimeInterval timeout) {
    NSString *busted = repotweaks_cache_busted_url_string(urlString);
    NSURL *url = [NSURL URLWithString:busted];
    if (!url) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                       timeoutInterval:timeout > 0 ? timeout : 20.0];
    [request setValue:@"no-cache, no-store, max-age=0, must-revalidate" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];
    [request setValue:@"0" forHTTPHeaderField:@"Expires"];
    return request;
}

static NSURLSession *repotweaks_uncached_session(NSTimeInterval timeout) {
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.URLCache = nil;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    cfg.timeoutIntervalForRequest = timeout > 0 ? timeout : 20.0;
    cfg.timeoutIntervalForResource = timeout > 0 ? timeout : 20.0;
    return [NSURLSession sessionWithConfiguration:cfg];
}

static NSDictionary *repotweaks_sanitized_tweak(id raw, NSString **errorMessage) {
    if (![raw isKindOfClass:NSDictionary.class]) {
        if (errorMessage) *errorMessage = @"Repo tweak entry is not an object.";
        return nil;
    }
    NSDictionary *dict = (NSDictionary *)raw;
    NSString *tweakID = repotweaks_string_or_empty(dict[@"id"]);
    NSString *name = repotweaks_string_or_empty(dict[@"name"]);
    NSString *scriptURL = repotweaks_string_or_empty(dict[@"scriptURL"]);
    if (tweakID.length == 0 || name.length == 0 || scriptURL.length == 0) {
        if (errorMessage) *errorMessage = @"Repo tweak is missing id, name, or scriptURL.";
        return nil;
    }
    if (!repotweaks_is_https_url(scriptURL)) {
        if (errorMessage) *errorMessage = @"Repo tweak scriptURL must be HTTPS.";
        return nil;
    }

    NSMutableDictionary *out = [@{
        @"id": tweakID,
        @"name": name,
        @"scriptURL": scriptURL,
        @"description": repotweaks_string_or_empty(dict[@"description"]),
        @"version": repotweaks_string_or_empty(dict[@"version"]),
    } mutableCopy];
    NSString *symbol = repotweaks_string_or_empty(dict[@"symbol"]);
    if (symbol.length > 0) out[@"symbol"] = symbol;
    NSString *author = repotweaks_string_or_empty(dict[@"author"]);
    if (author.length > 0) out[@"author"] = author;
    NSString *minIOS = repotweaks_string_or_empty(dict[@"minIOS"]);
    if (minIOS.length > 0) out[@"minIOS"] = minIOS;
    NSString *maxIOS = repotweaks_string_or_empty(dict[@"maxIOS"]);
    if (maxIOS.length > 0) out[@"maxIOS"] = maxIOS;
    NSString *compatibilityNote = repotweaks_string_or_empty(dict[@"compatibilityNote"]);
    if (compatibilityNote.length > 0) out[@"compatibilityNote"] = compatibilityNote;
    NSString *unsupportedMessage = repotweaks_string_or_empty(dict[@"unsupportedMessage"]);
    if (unsupportedMessage.length > 0) out[@"unsupportedMessage"] = unsupportedMessage;
    return out;
}

static NSDictionary *repotweaks_sanitized_repo(id raw, NSString **errorMessage) {
    if (![raw isKindOfClass:NSDictionary.class]) {
        if (errorMessage) *errorMessage = @"Repository JSON root must be an object.";
        return nil;
    }
    NSDictionary *dict = (NSDictionary *)raw;
    id rawTweaks = dict[@"tweaks"];
    if (![rawTweaks isKindOfClass:NSArray.class]) {
        if (errorMessage) *errorMessage = @"Repository JSON must include a tweaks array.";
        return nil;
    }

    NSMutableArray *tweaks = [NSMutableArray array];
    NSMutableSet<NSString *> *seenIDs = [NSMutableSet set];
    for (id rawTweak in (NSArray *)rawTweaks) {
        NSString *entryError = nil;
        NSDictionary *tweak = repotweaks_sanitized_tweak(rawTweak, &entryError);
        if (tweak) {
            NSString *tweakID = tweak[@"id"];
            if ([seenIDs containsObject:tweakID]) {
                log_user("[RepoTweaks] Skipping duplicate tweak id in repo: %s\n", tweakID.UTF8String);
                continue;
            }
            [seenIDs addObject:tweakID];
            [tweaks addObject:tweak];
        } else if (entryError.length > 0) {
            log_user("[RepoTweaks] Skipping invalid entry: %s\n", entryError.UTF8String);
        }
    }
    if (tweaks.count == 0) {
        if (errorMessage) *errorMessage = @"Repository has no valid HTTPS-backed tweaks.";
        return nil;
    }

    return @{
        @"repoName": repotweaks_string_or_empty(dict[@"repoName"]).length ? repotweaks_string_or_empty(dict[@"repoName"]) : @"Repository",
        @"author": repotweaks_string_or_empty(dict[@"author"]),
        @"tweaks": tweaks,
    };
}

static NSArray<NSString *> *repotweaks_saved_urls(NSUserDefaults *d) {
    id raw = [d objectForKey:@"RepoTweaksURLs"];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    for (id value in (NSArray *)raw) {
        if ([value isKindOfClass:NSString.class]) [urls addObject:value];
    }
    return urls;
}

static NSDictionary *repotweaks_saved_caches(NSUserDefaults *d) {
    id raw = [d objectForKey:@"RepoTweaksCaches"];
    return [raw isKindOfClass:NSDictionary.class] ? raw : @{};
}

// Move a dead source's per-tweak state (enabled, cached script, values,
// installed version, seen) to its replacement, for every tweak id the dead
// source had cached. Those keys hash the source URL, so without this an
// installed tweak would silently drop out when its source URL changes; with
// it, a tweak the new source still lists (same id) stays installed and is
// offered as an update when the new version differs. Ids the new source no
// longer lists are moved too and simply stay unlisted, as before.
static void repotweaks_migrate_source(NSUserDefaults *d, NSMutableArray *urls,
                                      NSMutableDictionary *caches,
                                      NSString *fromURL, NSString *toURL) {
    if (![urls containsObject:fromURL]) return;
    NSDictionary *old = [caches[fromURL] isKindOfClass:NSDictionary.class] ? caches[fromURL] : nil;
    NSArray *tweaks = [old[@"tweaks"] isKindOfClass:NSArray.class] ? old[@"tweaks"] : @[];
    NSArray<NSString *> *prefixes = @[ @"RepoTweakEnabled_", @"RepoTweakScript_", @"RepoTweakValues_",
                                       @"RepoTweakInstalledVersion_", @"RepoTweakSeen_" ];
    NSUInteger moved = 0;
    for (NSDictionary *tweak in tweaks) {
        if (![tweak isKindOfClass:NSDictionary.class]) continue;
        NSString *tweakID = repotweaks_string_or_empty(tweak[@"id"]);
        if (tweakID.length == 0) continue;
        NSString *fromKey = repotweaks_storage_key(fromURL, tweakID);
        NSString *toKey = repotweaks_storage_key(toURL, tweakID);
        for (NSString *prefix in prefixes) {
            NSString *oldKey = [prefix stringByAppendingString:fromKey];
            id value = [d objectForKey:oldKey];
            if (!value) continue;
            NSString *newKey = [prefix stringByAppendingString:toKey];
            if (![d objectForKey:newKey]) [d setObject:value forKey:newKey];
            [d removeObjectForKey:oldKey];
            moved++;
        }
    }
    // QuickLoader remembers which source its current script came from.
    if ([[d stringForKey:@"QuickLoaderSourceRepoURL"] isEqualToString:fromURL])
        [d setObject:toURL forKey:@"QuickLoaderSourceRepoURL"];
    [urls removeObject:fromURL];
    [caches removeObjectForKey:fromURL];
    if (![urls containsObject:toURL]) [urls addObject:toURL];
    log_user("[RepoTweaks] Moved source %s -> %s (%lu saved setting(s) carried over)\n",
             fromURL.UTF8String, toURL.UTF8String, (unsigned long)moved);
}

void repotweaks_seed_default_repos(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableArray *urls = [[repotweaks_saved_urls(d) mutableCopy] ?: [NSMutableArray array] mutableCopy];
    NSMutableDictionary *caches = [[repotweaks_saved_caches(d) mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
    NSString *seedVersion = [d stringForKey:kRepoTweaksDefaultReposSeedVersionKey];
    BOOL firstSeedForVersion = ![seedVersion isEqualToString:kRepoTweaksDefaultReposSeedVersion];
    BOOL changed = NO;

    // Migration: the default source has moved twice -- zeroxjf.github.io
    // (renamed, now 404), then 0xjohnnydev.github.io (dead) -- and now lives
    // in MinePlayer16's repository. Existing installs switch over with their
    // installed tweaks' state carried across.
    for (NSString *deadRepoURL in @[ @"https://zeroxjf.github.io/cyanide-repotweaks.json",
                                     @"https://0xjohnnydev.github.io/cyanide-repotweaks.json" ]) {
        if ([urls containsObject:deadRepoURL]) {
            repotweaks_migrate_source(d, urls, caches, deadRepoURL, kRepoTweaksDefaultRepoURL);
            changed = YES;
        }
    }

    if (firstSeedForVersion && ![urls containsObject:kRepoTweaksDefaultRepoURL]) {
        [urls addObject:kRepoTweaksDefaultRepoURL];
        changed = YES;
    }

    if ([urls containsObject:kRepoTweaksDefaultRepoURL] && ![caches[kRepoTweaksDefaultRepoURL] isKindOfClass:NSDictionary.class]) {
        caches[kRepoTweaksDefaultRepoURL] = @{
            @"repoName": @"MinePlayer16's Repository",
            @"author": @"MinePlayer16/Iggy05",
            @"tweaks": @[],
        };
        changed = YES;
    }

    if (firstSeedForVersion) {
        [d setObject:kRepoTweaksDefaultReposSeedVersion forKey:kRepoTweaksDefaultReposSeedVersionKey];
        changed = YES;
    }
    if (changed) {
        [d setObject:urls forKey:@"RepoTweaksURLs"];
        [d setObject:caches forKey:@"RepoTweaksCaches"];
        [d synchronize];
    }

    // Seeding itself is local; only the fetch below needs Repo sources on.
    if (!repotweaks_sources_enabled()) return;
    NSDictionary *repo = repotweaks_saved_caches(d)[kRepoTweaksDefaultRepoURL];
    NSArray *tweaks = [repo isKindOfClass:NSDictionary.class] ? repo[@"tweaks"] : nil;
    if (firstSeedForVersion || ![tweaks isKindOfClass:NSArray.class] || tweaks.count == 0) {
        repotweaks_refresh_repo(kRepoTweaksDefaultRepoURL, ^(BOOL success, NSString *message) {
            if (!success) {
                log_user("[RepoTweaks] Default source refresh failed: %s\n", (message ?: @"Download failed.").UTF8String);
            }
        });
    }
}

static void repotweaks_cancel_tweak_locked(NSString *tweakID) {
    NSMutableDictionary *timers = g_repo_timers_registry[tweakID];
    for (id timerSource in timers.allValues) {
        dispatch_source_cancel((dispatch_source_t)timerSource);
    }
    [timers removeAllObjects];
    [g_repo_timers_registry removeObjectForKey:tweakID];
    [g_repo_contexts removeObjectForKey:tweakID];
}

void repotweaks_cancel_tweak(NSString *repoURL, NSString *tweakId) {
    NSString *storageKey = repotweaks_storage_key(repoURL, tweakId);
    uint64_t cancelGeneration = repotweaks_current_generation();
    bool cancelled = repotweaks_perform_sync_timeout(^{
        if (!repotweaks_generation_is_current(cancelGeneration)) return;
        repotweaks_cancel_tweak_locked(storageKey);
    }, 2 * NSEC_PER_SEC);
    if (!cancelled) {
        log_user("[RepoTweaks] Timed out stopping %s; the script may be stuck in a long-running loop.\n",
                 repotweaks_string_or_empty(tweakId).UTF8String);
        repotweaks_abandon_js_queue_after_timeout("cancel timeout", NO);
    }
}

bool repotweaks_run_isolated_js(NSString *tweakID, NSString *tweakName, NSString *jsCode) {
    if (![tweakID isKindOfClass:NSString.class] || tweakID.length == 0 ||
        ![jsCode isKindOfClass:NSString.class] || jsCode.length == 0) {
        return false;
    }

    __block bool ok = true;
    NSString *safeID = [tweakID copy];
    NSString *safeName = ([tweakName isKindOfClass:NSString.class] && tweakName.length > 0) ? [tweakName copy] : safeID;
    uint64_t runGeneration = repotweaks_current_generation();

    bool completed = repotweaks_perform_sync_timeout(^{
        if (!repotweaks_generation_is_current(runGeneration)) return;
        if (!g_repo_contexts) g_repo_contexts = [NSMutableDictionary dictionary];
        if (!g_repo_timers_registry) g_repo_timers_registry = [NSMutableDictionary dictionary];

        repotweaks_cancel_tweak_locked(safeID);
        NSMutableDictionary<NSNumber *, id> *tweakTimers = [NSMutableDictionary dictionary];
        g_repo_timers_registry[safeID] = tweakTimers;

        JSContext *context = [[JSContext alloc] init];
        g_repo_contexts[safeID] = context;

        context.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
            log_user("[RepoTweaks ERROR][%s] %s\n", safeName.UTF8String, [[exception toString] UTF8String]);
        };

        context[@"setInterval"] = ^JSValue*(JSValue *func, JSValue *delay) {
            if (!repotweaks_generation_is_active(runGeneration)) return [JSValue valueWithInt32:0 inContext:[JSContext currentContext]];
            int tId = ++g_repo_timer_id_counter;
            uint64_t ms = [delay toUInt32];
            if (ms < 16) ms = 16;

            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, repotweaks_js_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC),
                                      ms * NSEC_PER_MSEC, (ms / 10) * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(timer, ^{
                if (repotweaks_generation_is_active(runGeneration)) [func callWithArguments:@[]];
            });

            tweakTimers[@(tId)] = timer;
            dispatch_resume(timer);
            return [JSValue valueWithInt32:tId inContext:[JSContext currentContext]];
        };

        context[@"clearInterval"] = ^(JSValue *timerId) {
            if (!repotweaks_generation_is_active(runGeneration)) return;
            int tId = [timerId toInt32];
            dispatch_source_t timer = (dispatch_source_t)tweakTimers[@(tId)];
            if (timer) {
                dispatch_source_cancel(timer);
                [tweakTimers removeObjectForKey:@(tId)];
            }
        };

        context[@"setTimeout"] = ^JSValue*(JSValue *func, JSValue *delay) {
            if (!repotweaks_generation_is_active(runGeneration)) return [JSValue valueWithInt32:0 inContext:[JSContext currentContext]];
            int tId = ++g_repo_timer_id_counter;
            uint64_t ms = [delay toUInt32];

            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, repotweaks_js_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC),
                                      DISPATCH_TIME_FOREVER, 0);
            dispatch_source_set_event_handler(timer, ^{
                if (repotweaks_generation_is_active(runGeneration)) [func callWithArguments:@[]];
                dispatch_source_cancel(timer);
                [tweakTimers removeObjectForKey:@(tId)];
            });

            tweakTimers[@(tId)] = timer;
            dispatch_resume(timer);
            return [JSValue valueWithInt32:tId inContext:[JSContext currentContext]];
        };

        context[@"clearTimeout"] = ^(JSValue *timerId) {
            if (!repotweaks_generation_is_active(runGeneration)) return;
            int tId = [timerId toInt32];
            dispatch_source_t timer = (dispatch_source_t)tweakTimers[@(tId)];
            if (timer) {
                dispatch_source_cancel(timer);
                [tweakTimers removeObjectForKey:@(tId)];
            }
        };

        context[@"log"] = ^(NSString *msg) {
            if (!repotweaks_generation_is_active(runGeneration)) return;
            log_user("[RepoTweaks][%s] %s\n", safeName.UTF8String, [msg UTF8String]);
        };

        context[@"dz_zero_system_file_page"] = ^NSNumber*(NSString *path, JSValue *offsetValue) {
            if (!repotweaks_generation_is_active(runGeneration)) return @(NO);
            if (![path isKindOfClass:NSString.class] || path.length == 0) {
                log_user("[RepoTweaks][%s] dz_zero_system_file_page missing path.\n", safeName.UTF8String);
                return @(NO);
            }
            uint64_t offset = offsetValue ? repo_js_to_uint64(offsetValue) : 0;
            log_user("[RepoTweaks][%s] Stable page-zero request: %s offset=%llu\n",
                     safeName.UTF8String,
                     path.UTF8String,
                     (unsigned long long)offset);
            int rc = zero_system_file_page(path.UTF8String, (off_t)offset);
            if (rc == 0 &&
                offset == 0 &&
                [path isEqualToString:kRepoTweaksHideHomeBarMaterialKitAssets]) {
                settings_note_hide_home_bar_respring_pending();
            }
            return @(rc == 0);
        };

        context[@"r_pref_num"] = ^NSNumber*(NSString *key) {
            if (!repotweaks_generation_is_active(runGeneration)) return @(0);
            return @([repotweaks_pref_string(safeID, key) doubleValue]);
        };

        context[@"r_pref_str"] = ^NSString*(NSString *key) {
            if (!repotweaks_generation_is_active(runGeneration)) return @"";
            return repotweaks_pref_string(safeID, key);
        };

        context[@"r_pref_bool"] = ^NSNumber*(NSString *key) {
            if (!repotweaks_generation_is_active(runGeneration)) return @(0);
            return @([repotweaks_pref_string(safeID, key) boolValue]);
        };

        context[@"r_sel"] = ^NSString*(NSString *selName) {
            if (!repotweaks_generation_is_active(runGeneration)) return repo_uint64_to_js(0);
            if (![selName isKindOfClass:NSString.class]) return repo_uint64_to_js(0);
            uint64_t selPtr = r_sel([selName UTF8String]);
            return repo_uint64_to_js(selPtr);
        };

        context[@"r_responds"] = ^() {
            if (!repotweaks_generation_is_active(runGeneration)) return @(0);
            NSArray *args = [JSContext currentArguments];
            if (args.count < 2) return @(0);

            uint64_t target = repo_js_to_uint64(args[0]);
            NSString *selector = [args[1] toString];
            return @(r_responds(target, [selector UTF8String]));
        };

        context[@"r_class"] = ^NSString*(NSString *className) {
            if (!repotweaks_generation_is_active(runGeneration)) return repo_uint64_to_js(0);
            uint64_t res = r_class([className UTF8String]);
            return repo_uint64_to_js(res);
        };

        context[@"r_msg2"] = ^() {
            if (!repotweaks_generation_is_active(runGeneration)) return repo_uint64_to_js(0);
            NSArray *args = [JSContext currentArguments];
            if (args.count < 2) return repo_uint64_to_js(0);

            uint64_t target = repo_js_to_uint64(args[0]);
            NSString *selector = [args[1] toString];
            uint64_t a1 = args.count > 2 ? repo_js_to_uint64(args[2]) : 0;
            uint64_t a2 = args.count > 3 ? repo_js_to_uint64(args[3]) : 0;
            uint64_t a3 = args.count > 4 ? repo_js_to_uint64(args[4]) : 0;
            uint64_t a4 = args.count > 5 ? repo_js_to_uint64(args[5]) : 0;

            uint64_t res = r_msg2(target, [selector UTF8String], a1, a2, a3, a4);
            return repo_uint64_to_js(res);
        };

        context[@"r_msg2_main"] = ^() {
            if (!repotweaks_generation_is_active(runGeneration)) return repo_uint64_to_js(0);
            NSArray *args = [JSContext currentArguments];
            if (args.count < 2) return repo_uint64_to_js(0);

            uint64_t target = repo_js_to_uint64(args[0]);
            NSString *selector = [args[1] toString];
            uint64_t a1 = args.count > 2 ? repo_js_to_uint64(args[2]) : 0;
            uint64_t a2 = args.count > 3 ? repo_js_to_uint64(args[3]) : 0;
            uint64_t a3 = args.count > 4 ? repo_js_to_uint64(args[4]) : 0;
            uint64_t a4 = args.count > 5 ? repo_js_to_uint64(args[5]) : 0;

            uint64_t res = r_msg2_main(target, [selector UTF8String], a1, a2, a3, a4);
            return repo_uint64_to_js(res);
        };

        context[@"r_nsstr"] = ^NSString*(NSString *str) {
            if (!repotweaks_generation_is_active(runGeneration) || !str) return repo_uint64_to_js(0);
            uint64_t ptr = r_nsstr_retained([str UTF8String]);
            return repo_uint64_to_js(ptr);
        };

        log_user("[RepoTweaks] Spawning sandbox for: %s\n", safeName.UTF8String);
        [context evaluateScript:jsCode];
        if (context.exception) ok = false;
    }, 15 * NSEC_PER_SEC);

    if (!completed) {
        ok = false;
        repotweaks_abandon_js_queue_after_timeout("run timeout", NO);
    }

    return ok;
}

bool repotweaks_apply_in_session(void) {
    repotweaks_begin_apply_generation();

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSDictionary *allRepos = repotweaks_saved_caches(d);
    if (allRepos.count == 0) return false;

    bool executedAny = false;
    for (NSString *url in allRepos) {
        if (![url isKindOfClass:NSString.class]) continue;
        NSDictionary *repoData = [allRepos[url] isKindOfClass:NSDictionary.class] ? allRepos[url] : nil;
        NSArray *tweaks = [repoData[@"tweaks"] isKindOfClass:NSArray.class] ? repoData[@"tweaks"] : @[];

        for (NSDictionary *tweak in tweaks) {
            if (![tweak isKindOfClass:NSDictionary.class]) continue;
            NSString *tweakID = repotweaks_string_or_empty(tweak[@"id"]);
            NSString *tweakName = repotweaks_string_or_empty(tweak[@"name"]);
            if (tweakID.length == 0) continue;
            NSString *storageKey = repotweaks_storage_key(url, tweakID);

            NSString *toggleKey = repotweaks_enabled_defaults_key(url, tweakID);
            if (![d boolForKey:toggleKey]) {
                uint64_t cancelGeneration = repotweaks_current_generation();
                bool cancelled = repotweaks_perform_sync_timeout(^{
                    if (!repotweaks_generation_is_current(cancelGeneration)) return;
                    repotweaks_cancel_tweak_locked(storageKey);
                }, 2 * NSEC_PER_SEC);
                if (!cancelled) {
                    log_user("[RepoTweaks] Timed out clearing disabled tweak %s; resetting JS queue.\n",
                             tweakID.UTF8String);
                    repotweaks_abandon_js_queue_after_timeout("disabled tweak cleanup timeout", NO);
                }
                continue;
            }

            NSString *scriptKey = repotweaks_script_defaults_key(url, tweakID);
            NSString *rawJsCode = [d stringForKey:scriptKey];
            if (rawJsCode.length == 0) continue;

            NSMutableString *finalScript = [NSMutableString stringWithString:@"// --- REPOTWEAKS PARAMS ---\n"];
            NSString *valuesKey = repotweaks_values_defaults_key(url, tweakID);
            NSMutableDictionary *savedValues = repotweaks_string_values_dictionary([d dictionaryForKey:valuesKey]);
            BOOL didUpdateDefaults = NO;

            for (NSString *line in [rawJsCode componentsSeparatedByString:@"\n"]) {
                if (![line containsString:@"@param:"]) continue;
                NSArray *parts = [line componentsSeparatedByString:@"|"];
                if (parts.count < 4) continue;
                NSArray *typeParts = [parts[0] componentsSeparatedByString:@"@param:"];
                if (typeParts.count < 2) continue;

                NSString *type = [typeParts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSString *varName = [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSString *defValue = [parts[3] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (!repotweaks_valid_identifier(varName)) {
                    log_user("[RepoTweaks] Skipping invalid parameter name: %s\n", varName.UTF8String);
                    continue;
                }

                NSString *currentValue = savedValues[varName];
                if (![currentValue isKindOfClass:NSString.class]) {
                    currentValue = defValue ?: @"";
                    savedValues[varName] = currentValue;
                    didUpdateDefaults = YES;
                }

                if ([type isEqualToString:@"switch"]) {
                    [finalScript appendFormat:@"var %@ = %@;\n", varName, [currentValue boolValue] ? @"true" : @"false"];
                } else if ([type isEqualToString:@"text"] || [type isEqualToString:@"color"]) {
                    [finalScript appendFormat:@"var %@ = %@;\n", varName, repotweaks_js_string_literal(currentValue)];
                } else if ([type isEqualToString:@"slider"] || [type isEqualToString:@"number"]) {
                    [finalScript appendFormat:@"var %@ = %@;\n", varName, repotweaks_js_number_literal(currentValue)];
                }
            }

            if (didUpdateDefaults) {
                [d setObject:savedValues forKey:valuesKey];
                [d synchronize];
            }

            [finalScript appendString:@"// -------------------------\n\n"];
            [finalScript appendString:rawJsCode];
            bool ok = repotweaks_run_isolated_js(storageKey, tweakName, finalScript);
            executedAny = executedAny || ok;
        }
    }
    return executedAny;
}

void repotweaks_refresh_repo(NSString *repoURL, void (^completion)(BOOL success, NSString *message)) {
    void (^finish)(BOOL, NSString *) = ^(BOOL success, NSString *message) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(success, message ?: @""); });
    };
    // Every source fetch goes through here: nothing connects while Repo
    // sources is off.
    if (!repotweaks_sources_enabled()) {
        finish(NO, @"Repo sources are turned off.");
        return;
    }
    if (!repotweaks_is_https_url(repoURL)) {
        finish(NO, @"Repository URL must be HTTPS.");
        return;
    }

    NSMutableURLRequest *request = repotweaks_uncached_request(repoURL, 20.0);
    if (!request) {
        finish(NO, @"Repository URL is invalid.");
        return;
    }

    NSURLSession *session = repotweaks_uncached_session(20.0);
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [session finishTasksAndInvalidate];
        if (error || !data) {
            finish(NO, error.localizedDescription ?: @"Download failed.");
            return;
        }
        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSInteger status = http.statusCode;
            if (status < 200 || status >= 300) {
                finish(NO, [NSString stringWithFormat:@"Repository returned HTTP %ld.", (long)status]);
                return;
            }
            if (!repotweaks_content_type_matches(http, @[@"application/json", @"text/json", @"text/plain"])) {
                finish(NO, @"Repository did not return JSON.");
                return;
            }
        }
        if (data.length == 0 || data.length > kRepoTweaksMaxRepoBytes) {
            finish(NO, @"Repository JSON is empty or too large.");
            return;
        }

        NSError *jsonErr = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        NSString *validationError = nil;
        NSDictionary *sanitized = repotweaks_sanitized_repo(json, &validationError);
        if (!sanitized) {
            finish(NO, validationError ?: jsonErr.localizedDescription ?: @"Invalid JSON.");
            return;
        }

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary *caches = [repotweaks_saved_caches(d) mutableCopy];
        NSDictionary *oldRepo = [caches[repoURL] isKindOfClass:NSDictionary.class] ? caches[repoURL] : nil;
        NSArray *oldTweaks = [oldRepo[@"tweaks"] isKindOfClass:NSArray.class] ? oldRepo[@"tweaks"] : @[];
        NSMutableDictionary<NSString *, NSString *> *oldVersions = [NSMutableDictionary dictionary];
        for (id t in oldTweaks) {
            if ([t isKindOfClass:NSDictionary.class]) {
                NSString *tid = repotweaks_string_or_empty(t[@"id"]);
                NSString *tv = repotweaks_string_or_empty(t[@"version"]);
                if (tid.length > 0) oldVersions[tid] = tv;
            }
        }

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        for (NSDictionary *tweak in sanitized[@"tweaks"]) {
            NSString *tid = repotweaks_string_or_empty(tweak[@"id"]);
            NSString *tv = repotweaks_string_or_empty(tweak[@"version"]);
            if (tid.length == 0) continue;
            NSString *seenKey = [NSString stringWithFormat:@"RepoTweakSeen_%@", repotweaks_storage_key(repoURL, tid)];
            NSString *oldV = oldVersions[tid];
            if (!oldV || (tv.length > 0 && ![tv isEqualToString:oldV])) {
                [d setDouble:now forKey:seenKey];
            } else if ([d doubleForKey:seenKey] == 0) {
                [d setDouble:now forKey:seenKey];
            }
        }

        caches[repoURL] = sanitized;
        [d setObject:caches forKey:@"RepoTweaksCaches"];

        NSMutableArray *urls = [[repotweaks_saved_urls(d) mutableCopy] ?: [NSMutableArray array] mutableCopy];
        if (![urls containsObject:repoURL]) [urls addObject:repoURL];
        [d setObject:urls forKey:@"RepoTweaksURLs"];
        [d synchronize];

        NSArray *tweaks = sanitized[@"tweaks"];
        dispatch_group_t group = dispatch_group_create();
        __block BOOL scriptsOK = YES;
        for (NSDictionary *tweak in tweaks) {
            dispatch_group_enter(group);
            repotweaks_download_script(repoURL, tweak[@"id"], tweak[@"scriptURL"], ^(BOOL success) {
                if (!success) scriptsOK = NO;
                dispatch_group_leave(group);
            });
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            finish(scriptsOK, scriptsOK ? @"Refreshed." : @"Refreshed, but one or more scripts failed to download.");
        });
    }] resume];
}

void repotweaks_download_script(NSString *repoURL, NSString *tweakId, NSString *scriptURL, void (^completion)(BOOL success)) {
    void (^finish)(BOOL) = ^(BOOL success) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
    };
    if (!repotweaks_sources_enabled()) {
        finish(NO);
        return;
    }
    if (![tweakId isKindOfClass:NSString.class] || tweakId.length == 0 ||
        !repotweaks_is_https_url(scriptURL)) {
        finish(NO);
        return;
    }

    NSMutableURLRequest *request = repotweaks_uncached_request(scriptURL, 20.0);
    if (!request) {
        finish(NO);
        return;
    }

    NSURLSession *session = repotweaks_uncached_session(20.0);
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [session finishTasksAndInvalidate];
        if (error || !data) {
            finish(NO);
            return;
        }
        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSInteger status = http.statusCode;
            if (status < 200 || status >= 300) {
                finish(NO);
                return;
            }
            if (!repotweaks_content_type_matches(http, @[@"application/javascript", @"text/javascript", @"application/x-javascript", @"text/plain"])) {
                finish(NO);
                return;
            }
        }
        if (data.length == 0 || data.length > kRepoTweaksMaxScriptBytes) {
            finish(NO);
            return;
        }
        NSString *jsCode = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (jsCode.length == 0) {
            finish(NO);
            return;
        }

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:jsCode forKey:repotweaks_script_defaults_key(repoURL, tweakId)];
        repotweaks_seed_default_values_for_script(d, repoURL, tweakId, jsCode);
        [d synchronize];
        finish(YES);
    }] resume];
}

BOOL repotweaks_download_script_sync(NSString *repoURL,
                                     NSString *tweakId,
                                     NSString *scriptURL,
                                     NSTimeInterval timeout,
                                     NSString **message) {
    if (message) *message = nil;
    if (![tweakId isKindOfClass:NSString.class] || tweakId.length == 0 ||
        !repotweaks_is_https_url(scriptURL)) {
        if (message) *message = @"Invalid script URL.";
        return NO;
    }

    __block BOOL ok = NO;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    repotweaks_download_script(repoURL, tweakId, scriptURL, ^(BOOL success) {
        ok = success;
        dispatch_semaphore_signal(sema);
    });

    NSTimeInterval boundedTimeout = timeout > 0 ? timeout : 25.0;
    long wait = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(boundedTimeout * NSEC_PER_SEC)));
    if (wait != 0) {
        if (message) *message = @"Timed out downloading latest script.";
        return NO;
    }
    if (!ok && message) *message = @"Failed to download latest script.";
    return ok;
}

bool repotweaks_stop_in_session(void) {
    repotweaks_set_shutting_down(YES);
    uint64_t stopGeneration = repotweaks_current_generation();

    bool stopped = repotweaks_perform_sync_timeout(^{
        if (!repotweaks_generation_is_current(stopGeneration)) return;
        log_user("[RepoTweaks] Safe stop: stopping timers.\n");
        if (g_repo_timers_registry) {
            for (NSString *tweakID in [g_repo_timers_registry allKeys]) {
                repotweaks_cancel_tweak_locked(tweakID);
            }
            [g_repo_timers_registry removeAllObjects];
        }
        [g_repo_contexts removeAllObjects];
    }, 2 * NSEC_PER_SEC);

    if (!stopped) {
        log_user("[RepoTweaks] Safe stop timed out; a script may be stuck in a long-running loop.\n");
        repotweaks_abandon_js_queue_after_timeout("cleanup timeout", YES);
    }

    return stopped;
}

#pragma mark - Update detection

NSString * const RepoTweaksDidRefreshNotification = @"RepoTweaksDidRefreshNotification";
NSString * const kRepoSourcesEnabledKey = @"RepoSourcesEnabled";
NSString * const RepoSourcesEnabledDidChangeNotification = @"RepoSourcesEnabledDidChangeNotification";

bool repotweaks_sources_enabled(void) {
    // Unset (fresh install, or before settings_register_defaults ran) is On.
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kRepoSourcesEnabledKey];
    return value ? [value boolValue] : true;
}

NSString *repotweaks_installed_version_key(NSString *repoURL, NSString *tweakId) {
    return [NSString stringWithFormat:@"RepoTweakInstalledVersion_%@", repotweaks_storage_key(repoURL, tweakId)];
}

NSComparisonResult repotweaks_compare_versions(NSString *a, NSString *b) {
    if (!a.length && !b.length) return NSOrderedSame;
    if (!a.length) return NSOrderedAscending;
    if (!b.length) return NSOrderedDescending;
    return [a compare:b options:NSNumericSearch];
}

static NSString *repotweaks_current_ios_version_string(void)
{
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    return [NSString stringWithFormat:@"%ld.%ld.%ld",
            (long)v.majorVersion,
            (long)v.minorVersion,
            (long)v.patchVersion];
}

static NSInteger repotweaks_version_major(NSString *version)
{
    NSString *safe = repotweaks_string_or_empty(version);
    if (safe.length == 0) return NSNotFound;
    return (NSInteger)[safe componentsSeparatedByString:@"."].firstObject.integerValue;
}

static BOOL repotweaks_bound_uses_major_wildcard(NSString *bound)
{
    NSString *safe = repotweaks_string_or_empty(bound).lowercaseString;
    return [safe hasSuffix:@".x"] || [safe hasSuffix:@".*"];
}

static NSComparisonResult repotweaks_compare_ios_to_bound(NSString *current, NSString *bound)
{
    if (repotweaks_bound_uses_major_wildcard(bound)) {
        NSInteger currentMajor = repotweaks_version_major(current);
        NSInteger boundMajor = repotweaks_version_major(bound);
        if (currentMajor == NSNotFound || boundMajor == NSNotFound) return NSOrderedSame;
        if (currentMajor < boundMajor) return NSOrderedAscending;
        if (currentMajor > boundMajor) return NSOrderedDescending;
        return NSOrderedSame;
    }
    return [repotweaks_string_or_empty(current) compare:repotweaks_string_or_empty(bound)
                                                options:NSNumericSearch];
}

NSString *repotweaks_compatibility_note(NSDictionary *tweak)
{
    if (![tweak isKindOfClass:NSDictionary.class]) return nil;
    NSString *note = repotweaks_string_or_empty(tweak[@"compatibilityNote"]);
    if (note.length > 0) return note;

    NSString *minIOS = repotweaks_string_or_empty(tweak[@"minIOS"]);
    NSString *maxIOS = repotweaks_string_or_empty(tweak[@"maxIOS"]);
    if (minIOS.length > 0 && maxIOS.length > 0) {
        return [NSString stringWithFormat:@"Tested on iOS %@–%@", minIOS, maxIOS];
    }
    if (maxIOS.length > 0) return [NSString stringWithFormat:@"Tested on iOS %@ and below", maxIOS];
    if (minIOS.length > 0) return [NSString stringWithFormat:@"Requires iOS %@ or newer", minIOS];
    return nil;
}

NSString *repotweaks_unsupported_reason(NSDictionary *tweak)
{
    if (![tweak isKindOfClass:NSDictionary.class]) return nil;
    NSString *current = repotweaks_current_ios_version_string();
    NSString *minIOS = repotweaks_string_or_empty(tweak[@"minIOS"]);
    NSString *maxIOS = repotweaks_string_or_empty(tweak[@"maxIOS"]);
    BOOL tooOld = minIOS.length > 0 &&
        repotweaks_compare_ios_to_bound(current, minIOS) == NSOrderedAscending;
    BOOL tooNew = maxIOS.length > 0 &&
        repotweaks_compare_ios_to_bound(current, maxIOS) == NSOrderedDescending;
    if (!tooOld && !tooNew) return nil;

    NSString *message = repotweaks_string_or_empty(tweak[@"unsupportedMessage"]);
    if (message.length > 0) return message;
    NSString *note = repotweaks_compatibility_note(tweak);
    if (note.length > 0) return note;
    if (tooNew && maxIOS.length > 0) return [NSString stringWithFormat:@"Only tested on iOS %@ and below.", maxIOS];
    if (tooOld && minIOS.length > 0) return [NSString stringWithFormat:@"Requires iOS %@ or newer.", minIOS];
    return @"This repo tweak is not supported on this iOS version.";
}

NSTimeInterval repotweaks_seen_timestamp(NSString *repoURL, NSString *tweakId) {
    NSString *key = [NSString stringWithFormat:@"RepoTweakSeen_%@", repotweaks_storage_key(repoURL, tweakId)];
    return [[NSUserDefaults standardUserDefaults] doubleForKey:key];
}

NSUInteger repotweaks_available_update_count(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSDictionary *caches = repotweaks_saved_caches(d);
    NSUInteger count = 0;

    for (NSString *url in repotweaks_saved_urls(d)) {
        id repoRaw = caches[url];
        if (![repoRaw isKindOfClass:NSDictionary.class]) continue;
        id tweaksRaw = ((NSDictionary *)repoRaw)[@"tweaks"];
        if (![tweaksRaw isKindOfClass:NSArray.class]) continue;

        for (id tweakRaw in (NSArray *)tweaksRaw) {
            if (![tweakRaw isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *tweak = (NSDictionary *)tweakRaw;
            if (repotweaks_unsupported_reason(tweak).length > 0) continue;
            NSString *tweakID = repotweaks_string_or_empty(tweak[@"id"]);
            if (tweakID.length == 0) continue;

            NSString *installedVersion = [d stringForKey:repotweaks_installed_version_key(url, tweakID)];
            if (!installedVersion.length) continue;

            NSString *repoVersion = repotweaks_string_or_empty(tweak[@"version"]);
            if (repoVersion.length && repotweaks_compare_versions(repoVersion, installedVersion) == NSOrderedDescending) {
                count++;
            }
        }
    }
    return count;
}

void repotweaks_refresh_all_sources(void (^completion)(void)) {
    if (!repotweaks_sources_enabled()) {
        if (completion) completion();
        return;
    }
    repotweaks_seed_default_repos();
    NSArray<NSString *> *urls = repotweaks_saved_urls([NSUserDefaults standardUserDefaults]);
    if (urls.count == 0) {
        if (completion) completion();
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    for (NSString *url in urls) {
        dispatch_group_enter(group);
        repotweaks_refresh_repo(url, ^(BOOL success, NSString *message) {
            dispatch_group_leave(group);
        });
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RepoTweaksDidRefreshNotification object:nil];
        if (completion) completion();
    });
}
