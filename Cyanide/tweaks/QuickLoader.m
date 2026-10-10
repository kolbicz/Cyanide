//
//  QuickLoader.m
//

#import <JavaScriptCore/JavaScriptCore.h>

#import "QuickLoader.h"
#import "RepoTweaks.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../utils/file.h"
#import "../SettingsViewController.h"
#import <stdio.h>
#import <unistd.h>
#import <string.h>
#import <pthread.h>
#import <math.h>
#import <Foundation/Foundation.h>
#import "../LogTextView.h"


extern uint64_t r_nsstr_retained(const char *str);

static NSString * const kQuickLoaderHideHomeBarMaterialKitAssets =
    @"/System/Library/PrivateFrameworks/MaterialKit.framework/Assets.car";

// ==========================================
// 1: 64-Bit Pointer Translation Helpers
// ==========================================
static uint64_t js_to_uint64(JSValue *val) {
    if ([val isString]) {
        return strtoull([[val toString] UTF8String], NULL, 16);
    }
    return (uint64_t)[val toDouble];
}

static NSString* uint64_to_js(uint64_t val) {
    return [NSString stringWithFormat:@"0x%llx", val];
}

static NSMutableDictionary *quickloader_string_values_dictionary(id raw) {
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

static NSString *quickloader_pref_string(NSDictionary *prefs, NSString *key) {
    if (![prefs isKindOfClass:NSDictionary.class] || ![key isKindOfClass:NSString.class]) return @"";
    id value = prefs[key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static NSString *quickloader_string_or_empty(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
}

static BOOL quickloader_valid_identifier(NSString *name) {
    if (![name isKindOfClass:NSString.class] || name.length == 0) return NO;
    unichar first = [name characterAtIndex:0];
    if (![[NSCharacterSet letterCharacterSet] characterIsMember:first] && first != '_' && first != '$') return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$"];
    return [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSString *quickloader_js_string_literal(NSString *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value ?: @""]
                                                   options:0
                                                     error:nil];
    NSString *arrayLiteral = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (arrayLiteral.length >= 2 && [arrayLiteral hasPrefix:@"["] && [arrayLiteral hasSuffix:@"]"]) {
        return [arrayLiteral substringWithRange:NSMakeRange(1, arrayLiteral.length - 2)];
    }
    return @"\"\"";
}

static NSString *quickloader_js_number_literal(NSString *value) {
    double number = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
    if (!isfinite(number)) number = 0.0;
    return [NSString stringWithFormat:@"%.12g", number];
}

static NSString * const kQuickLoaderSourceRepoURLKey = @"QuickLoaderSourceRepoURL";
static NSString * const kQuickLoaderSourceTweakIDKey = @"QuickLoaderSourceTweakID";

static NSString *quickloader_compiled_script_for_raw_script(NSString *rawScript,
                                                            NSMutableDictionary *values) {
    if (![rawScript isKindOfClass:NSString.class] || rawScript.length == 0) return nil;
    if (![values isKindOfClass:NSMutableDictionary.class]) values = [NSMutableDictionary dictionary];

    NSMutableString *finalScript = [NSMutableString stringWithString:@"//Variables injected by Cyanide\n"];
    NSArray *lines = [rawScript componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        if (![line containsString:@"@param:"]) continue;
        NSArray *parts = [line componentsSeparatedByString:@"|"];
        if (parts.count < 4) continue;

        NSArray *typeParts = [parts[0] componentsSeparatedByString:@"@param:"];
        if (typeParts.count < 2) continue;
        NSString *type = [quickloader_string_or_empty(typeParts[1]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *varName = [quickloader_string_or_empty(parts[1]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *defValue = [quickloader_string_or_empty(parts[3]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!quickloader_valid_identifier(varName)) continue;

        NSString *currentValue = quickloader_string_or_empty(values[varName]);
        if (currentValue.length == 0) {
            currentValue = defValue;
            values[varName] = defValue ?: @"";
        }

        if ([type isEqualToString:@"switch"]) {
            [finalScript appendFormat:@"var %@ = %@;\n", varName, [currentValue boolValue] ? @"true" : @"false"];
        } else if ([type isEqualToString:@"text"] || [type isEqualToString:@"color"]) {
            [finalScript appendFormat:@"var %@ = %@;\n", varName, quickloader_js_string_literal(currentValue)];
        } else if ([type isEqualToString:@"slider"] || [type isEqualToString:@"number"]) {
            [finalScript appendFormat:@"var %@ = %@;\n", varName, quickloader_js_number_literal(currentValue)];
        }
    }

    [finalScript appendString:@"// --------------------------------------\n\n"];
    [finalScript appendString:rawScript];
    return finalScript;
}

static bool quickloader_save_repo_tweak_internal(NSString *repoURL,
                                                 NSString *tweakID,
                                                 NSString *displayName,
                                                 NSString *rawScript,
                                                 NSDictionary *values,
                                                 BOOL logQueued) {
    NSString *safeRepo = quickloader_string_or_empty(repoURL);
    NSString *safeID = quickloader_string_or_empty(tweakID);
    NSString *safeName = quickloader_string_or_empty(displayName);
    if (safeRepo.length == 0 || safeID.length == 0 || rawScript.length == 0) return false;

    NSMutableDictionary *mutableValues = quickloader_string_values_dictionary(values);
    NSString *compiled = quickloader_compiled_script_for_raw_script(rawScript, mutableValues);
    if (compiled.length == 0) return false;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:safeName.length ? safeName : safeID forKey:@"QuickLoaderSourceScriptName"];
    [d setObject:rawScript forKey:@"QuickLoaderSourceRawJS"];
    [d setObject:mutableValues forKey:@"QuickLoaderSourceValues"];
    [d setObject:safeRepo forKey:kQuickLoaderSourceRepoURLKey];
    [d setObject:safeID forKey:kQuickLoaderSourceTweakIDKey];
    [d setObject:compiled forKey:@"QuickLoaderSavedJS"];
    [d setObject:mutableValues forKey:repotweaks_values_defaults_key(safeRepo, safeID)];
    [d synchronize];
    if (logQueued) {
        log_user("[QuickLoader] Queued repo package: %s\n", (safeName.length ? safeName : safeID).UTF8String);
    }
    return true;
}

bool quickloader_save_repo_tweak(NSString *repoURL,
                                 NSString *tweakID,
                                 NSString *displayName,
                                 NSString *rawScript,
                                 NSDictionary *values) {
    return quickloader_save_repo_tweak_internal(repoURL,
                                                tweakID,
                                                displayName,
                                                rawScript,
                                                values,
                                                YES);
}

bool quickloader_is_repo_tweak_installed(NSString *repoURL, NSString *tweakID) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *safeRepo = quickloader_string_or_empty(repoURL);
    NSString *safeID = quickloader_string_or_empty(tweakID);
    if (safeRepo.length == 0 || safeID.length == 0) return false;
    return [[d stringForKey:kQuickLoaderSourceRepoURLKey] isEqualToString:safeRepo] &&
           [[d stringForKey:kQuickLoaderSourceTweakIDKey] isEqualToString:safeID] &&
           [[d stringForKey:@"QuickLoaderSavedJS"] length] > 0;
}

void quickloader_clear_repo_tweak_if_matches(NSString *repoURL, NSString *tweakID) {
    if (!quickloader_is_repo_tweak_installed(repoURL, tweakID)) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:@"QuickLoaderSourceScriptName"];
    [d removeObjectForKey:@"QuickLoaderSourceRawJS"];
    [d removeObjectForKey:@"QuickLoaderSourceValues"];
    [d removeObjectForKey:kQuickLoaderSourceRepoURLKey];
    [d removeObjectForKey:kQuickLoaderSourceTweakIDKey];
    [d removeObjectForKey:@"QuickLoaderSavedJS"];
    [d synchronize];
}

bool quickloader_is_driven_by_repo_tweak(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *repoURL = quickloader_string_or_empty([d stringForKey:kQuickLoaderSourceRepoURLKey]);
    return repoURL.length > 0;
}

bool quickloader_refresh_active_repo_tweak(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *repoURL = quickloader_string_or_empty([d stringForKey:kQuickLoaderSourceRepoURLKey]);
    NSString *tweakID = quickloader_string_or_empty([d stringForKey:kQuickLoaderSourceTweakIDKey]);
    if (repoURL.length == 0 || tweakID.length == 0) return false;

    NSString *rawScript = [d stringForKey:repotweaks_script_defaults_key(repoURL, tweakID)];
    if (rawScript.length == 0) {
        log_user("[QuickLoader] Selected repo package script is missing; refresh its source first.\n");
        return false;
    }

    NSDictionary *values = [d dictionaryForKey:repotweaks_values_defaults_key(repoURL, tweakID)] ?: @{};
    NSString *displayName = [d stringForKey:@"QuickLoaderSourceScriptName"];
    return quickloader_save_repo_tweak_internal(repoURL,
                                                tweakID,
                                                displayName.length ? displayName : tweakID,
                                                rawScript,
                                                values,
                                                NO);
}


// ==========================================
// Global variables for js daemon and kill switch
// ==========================================
static JSContext *g_quickloader_context = nil;
static NSMutableDictionary *g_quickloader_timers = nil;
static int g_quickloader_timer_id = 0;

static int g_quickloader_shutting_down = 0;
static char g_quickloader_queue_key;
static pthread_mutex_t g_quickloader_queue_lock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t g_quickloader_queue = nil;
static uint64_t g_quickloader_generation = 1;

static dispatch_queue_t quickloader_create_js_queue_locked(void) {
    NSString *label = [NSString stringWithFormat:@"com.zeroxjf.cyanide.quickloader.js.%llu",
                       (unsigned long long)g_quickloader_generation];
    dispatch_queue_t q = dispatch_queue_create(label.UTF8String, DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(q, &g_quickloader_queue_key, &g_quickloader_queue_key, NULL);
    return q;
}

static dispatch_queue_t quickloader_js_queue(void) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    if (!g_quickloader_queue) {
        g_quickloader_queue = quickloader_create_js_queue_locked();
    }
    dispatch_queue_t q = g_quickloader_queue;
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return q;
}

static uint64_t quickloader_current_generation(void) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    uint64_t generation = g_quickloader_generation;
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return generation;
}

static void quickloader_set_shutting_down(BOOL shuttingDown) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    g_quickloader_shutting_down = shuttingDown ? 1 : 0;
    pthread_mutex_unlock(&g_quickloader_queue_lock);
}

static uint64_t quickloader_begin_run_generation(void) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    g_quickloader_generation++;
    if (g_quickloader_generation == 0) g_quickloader_generation = 1;
    g_quickloader_shutting_down = 0;
    if (!g_quickloader_queue) {
        g_quickloader_queue = quickloader_create_js_queue_locked();
    }
    uint64_t generation = g_quickloader_generation;
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return generation;
}

static BOOL quickloader_generation_is_current(uint64_t generation) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    BOOL current = (generation == g_quickloader_generation);
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return current;
}

static BOOL quickloader_generation_is_active(uint64_t generation) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    BOOL active = !g_quickloader_shutting_down && generation == g_quickloader_generation;
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return active;
}

static void quickloader_cancel_timer_sources(NSArray *sources) {
    for (id timerSource in sources) {
        if (timerSource) dispatch_source_cancel((dispatch_source_t)timerSource);
    }
}

// The caller must hold g_quickloader_queue_lock. Clearing the registry while
// the lock is held prevents an old timer callback from racing the abandoning
// thread; cancellation itself happens after the lock is released.
static NSArray *quickloader_detach_timer_sources_locked(NSMutableDictionary *registry) {
    if (!registry) return @[];

    NSMutableArray *sources = [NSMutableArray array];
    [sources addObjectsFromArray:registry.allValues];
    [registry removeAllObjects];
    return [sources copy];
}

static NSArray *quickloader_replace_timer_registry(NSMutableDictionary *newRegistry) {
    NSArray *oldSources = nil;
    pthread_mutex_lock(&g_quickloader_queue_lock);
    NSMutableDictionary *oldRegistry = g_quickloader_timers;
    g_quickloader_timers = newRegistry;
    oldSources = quickloader_detach_timer_sources_locked(oldRegistry);
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return oldSources;
}

static int quickloader_next_timer_id(uint64_t generation) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    int timerID = 0;
    if (!g_quickloader_shutting_down && generation == g_quickloader_generation) {
        timerID = ++g_quickloader_timer_id;
        if (timerID == 0) timerID = ++g_quickloader_timer_id;
    }
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return timerID;
}

static BOOL quickloader_register_timer(uint64_t generation,
                                       NSMutableDictionary *timers,
                                       NSNumber *timerID,
                                       dispatch_source_t timer) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    BOOL active = !g_quickloader_shutting_down && generation == g_quickloader_generation;
    if (active) timers[timerID] = timer;
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return active;
}

static dispatch_source_t quickloader_remove_timer(NSMutableDictionary *timers,
                                                  NSNumber *timerID) {
    pthread_mutex_lock(&g_quickloader_queue_lock);
    id timerSource = timers[timerID];
    if (timerSource) [timers removeObjectForKey:timerID];
    pthread_mutex_unlock(&g_quickloader_queue_lock);
    return (dispatch_source_t)timerSource;
}

static void quickloader_abandon_js_queue_after_timeout(const char *reason, BOOL shuttingDown) {
    NSMutableDictionary *abandonedRegistry = nil;
    NSArray *abandonedSources = nil;

    pthread_mutex_lock(&g_quickloader_queue_lock);
    g_quickloader_generation++;
    if (g_quickloader_generation == 0) g_quickloader_generation = 1;
    g_quickloader_shutting_down = shuttingDown ? 1 : 0;
    abandonedRegistry = g_quickloader_timers;
    g_quickloader_timers = nil;
    abandonedSources = quickloader_detach_timer_sources_locked(abandonedRegistry);
    g_quickloader_queue = quickloader_create_js_queue_locked();
    g_quickloader_context = nil;
    pthread_mutex_unlock(&g_quickloader_queue_lock);

    // Do not enqueue cleanup on the old queue: it is the queue that timed out.
    // The generation was invalidated before these sources were cancelled.
    quickloader_cancel_timer_sources(abandonedSources);
    log_user("[QuickLoader] Abandoned wedged JS queue after %s; future runs will use a fresh queue.\n",
             reason ? reason : "timeout");
}

static bool quickloader_perform_sync_timeout(dispatch_block_t block, int64_t timeoutNsec) {
    if (!block) return true;
    if (dispatch_get_specific(&g_quickloader_queue_key)) {
        block();
        return true;
    }

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    dispatch_async(quickloader_js_queue(), ^{
        block();
        dispatch_semaphore_signal(sema);
    });
    dispatch_time_t deadline = timeoutNsec < 0
        ? DISPATCH_TIME_FOREVER
        : dispatch_time(DISPATCH_TIME_NOW, timeoutNsec);
    return dispatch_semaphore_wait(sema, deadline) == 0;
}


// ==========================================
// Session init with auto-load default settings
// ==========================================
bool quickloader_apply_in_session() {
    quickloader_set_shutting_down(NO);

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *activeRepoURL = quickloader_string_or_empty([d stringForKey:kQuickLoaderSourceRepoURLKey]);
    NSString *activeTweakID = quickloader_string_or_empty([d stringForKey:kQuickLoaderSourceTweakIDKey]);
    NSString *activeName = quickloader_string_or_empty([d stringForKey:@"QuickLoaderSourceScriptName"]);
    BOOL hasRepoPackage = activeRepoURL.length > 0 && activeTweakID.length > 0;

    if (hasRepoPackage) {
        log_user("[QuickLoader] Active session detected. Checking selected repo package: %s...\n",
                 (activeName.length ? activeName : activeTweakID).UTF8String);
        if (!quickloader_refresh_active_repo_tweak()) {
            return false;
        }
    } else {
        log_user("[QuickLoader] Active session detected. Checking manually selected JS tweak...\n");
    }

    NSString *savedJS = [d stringForKey:@"QuickLoaderSavedJS"];

    if (savedJS && savedJS.length > 0) {

        // ===============================================================
        // auto-loading default settings
        // ===============================================================
        NSMutableDictionary *savedValues = quickloader_string_values_dictionary([d dictionaryForKey:@"QuickLoaderSourceValues"]);
        BOOL didUpdateDefaults = NO;

        NSArray *lines = [savedJS componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            if ([line containsString:@"@param:"]) {
                NSArray *parts = [line componentsSeparatedByString:@"|"];
                if (parts.count >= 4) {
                    //extracting variable name and default
                    NSString *varName = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *defValue = [parts[3] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (!quickloader_valid_identifier(varName)) {
                        log_user("[QuickLoader] Skipping invalid parameter name: %s\n", varName.UTF8String);
                        continue;
                    }

                    //if new, use .js default values
                    if (!savedValues[varName]) {
                        savedValues[varName] = defValue;
                        didUpdateDefaults = YES;
                    }
                }
            }
        }

        //if defaults found, saves them in memory
        if (didUpdateDefaults) {
            [d setObject:savedValues forKey:@"QuickLoaderSourceValues"];
            [d synchronize];
        }
        // ===============================================================

        if (hasRepoPackage) {
            log_user("[QuickLoader] Executing repo package: %s\n",
                     (activeName.length ? activeName : activeTweakID).UTF8String);
        } else {
            log_user("[QuickLoader] Executing user-provided JS file...\n");
        }
        return quickloader_run_js_string(savedJS);
    } else {
        log_user("[QuickLoader] No JS file loaded.\n");
    }

    return false;
}

// ==========================================
// Javascript interpreter engine
// ==========================================
bool quickloader_run_js_string(NSString *jsCode) {
    if (!jsCode || jsCode.length == 0) return false;

    __block bool ok = true;
    uint64_t runGeneration = quickloader_begin_run_generation();
    bool completed = quickloader_perform_sync_timeout(^{
        if (!quickloader_generation_is_current(runGeneration)) return;
        log_user("[JS Engine] Initializing long-living environment...\n");

        NSMutableDictionary *timers = [[NSMutableDictionary alloc] init];
        NSArray *oldTimerSources = quickloader_replace_timer_registry(timers);
        quickloader_cancel_timer_sources(oldTimerSources);

        JSContext *context = [[JSContext alloc] init];
        pthread_mutex_lock(&g_quickloader_queue_lock);
        BOOL contextInstalled = !g_quickloader_shutting_down && runGeneration == g_quickloader_generation;
        if (contextInstalled) g_quickloader_context = context;
        pthread_mutex_unlock(&g_quickloader_queue_lock);
        if (!contextInstalled) return;

        context.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
            log_user("[JS ERROR] %s\n", [[exception toString] UTF8String]);
        };

        // Timers target the same serial queue as the JSContext. JavaScriptCore
        // contexts are not safe to touch concurrently, and SpringBoard
        // RemoteCall state is single-session by design.
        context[@"setInterval"] = ^JSValue*(JSValue *func, JSValue *delay) {
            if (!quickloader_generation_is_active(runGeneration)) return [JSValue valueWithInt32:0 inContext:[JSContext currentContext]];
            int tId = quickloader_next_timer_id(runGeneration);
            if (tId == 0) return [JSValue valueWithInt32:0 inContext:[JSContext currentContext]];
            uint64_t ms = [delay toUInt32];
            if (ms < 16) ms = 16;

            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, quickloader_js_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), ms * NSEC_PER_MSEC, (ms / 10) * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(timer, ^{
                if (quickloader_generation_is_active(runGeneration)) {
                    [func callWithArguments:@[]];
                }
            });

            dispatch_resume(timer);
            if (!quickloader_register_timer(runGeneration, timers, @(tId), timer)) {
                dispatch_source_cancel(timer);
                return [JSValue valueWithInt32:0 inContext:[JSContext currentContext]];
            }
            return [JSValue valueWithInt32:tId inContext:[JSContext currentContext]];
        };

        context[@"clearInterval"] = ^(JSValue *timerId) {
            if (!quickloader_generation_is_active(runGeneration)) return;
            int tId = [timerId toInt32];
            dispatch_source_t timer = quickloader_remove_timer(timers, @(tId));
            if (timer) {
                dispatch_source_cancel(timer);
            }
        };

        context[@"setTimeout"] = ^JSValue*(JSValue *func, JSValue *delay) {
            if (!quickloader_generation_is_active(runGeneration)) return [JSValue valueWithInt32:0 inContext:[JSContext currentContext]];
            int tId = quickloader_next_timer_id(runGeneration);
            if (tId == 0) return [JSValue valueWithInt32:0 inContext:[JSContext currentContext]];
            uint64_t ms = [delay toUInt32];

            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, quickloader_js_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), DISPATCH_TIME_FOREVER, 0);
            dispatch_source_set_event_handler(timer, ^{
                if (quickloader_generation_is_active(runGeneration)) {
                    [func callWithArguments:@[]];
                }
                dispatch_source_cancel(timer);
                (void)quickloader_remove_timer(timers, @(tId));
            });

            dispatch_resume(timer);
            if (!quickloader_register_timer(runGeneration, timers, @(tId), timer)) {
                dispatch_source_cancel(timer);
                return [JSValue valueWithInt32:0 inContext:[JSContext currentContext]];
            }
            return [JSValue valueWithInt32:tId inContext:[JSContext currentContext]];
        };

        context[@"clearTimeout"] = ^(JSValue *timerId) {
            if (!quickloader_generation_is_active(runGeneration)) return;
            int tId = [timerId toInt32];
            dispatch_source_t timer = quickloader_remove_timer(timers, @(tId));
            if (timer) {
                dispatch_source_cancel(timer);
            }
        };

        //Bridge ipc core (safe with kill-switch)
        context[@"log"] = ^(NSString *msg) {
            if (!quickloader_generation_is_active(runGeneration)) return;
            log_user("[JS] %s\n", [msg UTF8String]);
        };

        context[@"dz_zero_system_file_page"] = ^NSNumber*(NSString *path, JSValue *offsetValue) {
            if (!quickloader_generation_is_active(runGeneration)) return @(NO);
            if (![path isKindOfClass:NSString.class] || path.length == 0) {
                log_user("[QuickLoader] dz_zero_system_file_page missing path.\n");
                return @(NO);
            }
            // Only the Hide Home Bar asset: this zeroes a page of a system
            // file in the page cache, so a script must not aim it elsewhere.
            if (![path isEqualToString:kQuickLoaderHideHomeBarMaterialKitAssets]) {
                log_user("[QuickLoader] dz_zero_system_file_page refused for %s (not allowlisted).\n",
                         path.UTF8String);
                return @(NO);
            }
            uint64_t offset = offsetValue ? js_to_uint64(offsetValue) : 0;
            log_user("[QuickLoader] Stable page-zero request: %s offset=%llu\n",
                     path.UTF8String,
                     (unsigned long long)offset);
            int rc = zero_system_file_page(path.UTF8String, (off_t)offset);
            if (rc == 0 &&
                offset == 0 &&
                [path isEqualToString:kQuickLoaderHideHomeBarMaterialKitAssets]) {
                settings_note_hide_home_bar_respring_pending();
            }
            return @(rc == 0);
        };

        context[@"r_pref_num"] = ^NSNumber*(NSString *key) {
            if (!quickloader_generation_is_active(runGeneration)) return @(0);
            NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"QuickLoaderSourceValues"];
            return @([quickloader_pref_string(prefs, key) doubleValue]);
        };

        context[@"r_pref_str"] = ^NSString*(NSString *key) {
            if (!quickloader_generation_is_active(runGeneration)) return @"";
            NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"QuickLoaderSourceValues"];
            return quickloader_pref_string(prefs, key);
        };

        context[@"r_pref_bool"] = ^NSNumber*(NSString *key) {
            if (!quickloader_generation_is_active(runGeneration)) return @(0);
            NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"QuickLoaderSourceValues"];
            return @([quickloader_pref_string(prefs, key) boolValue]);
        };

        context[@"r_class"] = ^(NSString *className) {
            if (!quickloader_generation_is_active(runGeneration)) return uint64_to_js(0);
            uint64_t cls = r_class([className UTF8String]);
            return uint64_to_js(cls);
        };

        context[@"r_responds"] = ^() {
            if (!quickloader_generation_is_active(runGeneration)) return @(0);
            NSArray *args = [JSContext currentArguments];
            if (args.count < 2) return @(0);

            uint64_t target = js_to_uint64(args[0]);
            NSString *selector = [args[1] toString];
            return @(r_responds(target, [selector UTF8String]));
        };

        context[@"r_sel"] = ^NSString*(NSString *selName) {
            if (!quickloader_generation_is_active(runGeneration)) return uint64_to_js(0);
            if (![selName isKindOfClass:NSString.class]) return uint64_to_js(0);
            uint64_t selPtr = r_sel([selName UTF8String]);
            return uint64_to_js(selPtr);
        };

        context[@"r_msg2"] = ^() {
            if (!quickloader_generation_is_active(runGeneration)) return uint64_to_js(0);
            NSArray *args = [JSContext currentArguments];
            if (args.count < 2) return uint64_to_js(0);
            uint64_t target = js_to_uint64(args[0]);
            NSString *selector = [args[1] toString];

            uint64_t a1 = args.count > 2 ? js_to_uint64(args[2]) : 0;
            uint64_t a2 = args.count > 3 ? js_to_uint64(args[3]) : 0;
            uint64_t a3 = args.count > 4 ? js_to_uint64(args[4]) : 0;
            uint64_t a4 = args.count > 5 ? js_to_uint64(args[5]) : 0;

            uint64_t res = r_msg2(target, [selector UTF8String], a1, a2, a3, a4);
            return uint64_to_js(res);
        };

        context[@"r_msg2_main"] = ^() {
            if (!quickloader_generation_is_active(runGeneration)) return uint64_to_js(0);
            NSArray *args = [JSContext currentArguments];
            if (args.count < 2) return uint64_to_js(0);
            uint64_t target = js_to_uint64(args[0]);
            NSString *selector = [args[1] toString];

            uint64_t a1 = args.count > 2 ? js_to_uint64(args[2]) : 0;
            uint64_t a2 = args.count > 3 ? js_to_uint64(args[3]) : 0;
            uint64_t a3 = args.count > 4 ? js_to_uint64(args[4]) : 0;
            uint64_t a4 = args.count > 5 ? js_to_uint64(args[5]) : 0;

            uint64_t res = r_msg2_main(target, [selector UTF8String], a1, a2, a3, a4);
            return uint64_to_js(res);
        };

        context[@"r_nsstr"] = ^NSString*(NSString *str) {
            if (!quickloader_generation_is_active(runGeneration)) return uint64_to_js(0);
            if (!str) return uint64_to_js(0);
            uint64_t ptr = r_nsstr_retained([str UTF8String]);
            return uint64_to_js(ptr);
        };

        log_user("[JS Engine] Executing user script...\n");
        [context evaluateScript:jsCode];
        if (context.exception) {
            ok = false;
        } else {
            log_user("[JS Engine] Execution complete.\n");
        }
    }, 15 * NSEC_PER_SEC);

    if (!completed) {
        ok = false;
        quickloader_abandon_js_queue_after_timeout("run timeout", NO);
    }

    return ok;
}

// ==========================================
// Teardown engine
// ==========================================
bool quickloader_stop_in_session(void) {
    //Order timers to stop
    quickloader_set_shutting_down(YES);
    uint64_t stopGeneration = quickloader_current_generation();

    bool stopped = quickloader_perform_sync_timeout(^{
        if (!quickloader_generation_is_current(stopGeneration)) return;
        log_user("[QuickLoader] Clean Up: Green light, safely stopping JS timer...\n");

        NSArray *sources = nil;
        pthread_mutex_lock(&g_quickloader_queue_lock);
        sources = quickloader_detach_timer_sources_locked(g_quickloader_timers);
        g_quickloader_context = nil;
        pthread_mutex_unlock(&g_quickloader_queue_lock);
        quickloader_cancel_timer_sources(sources);
    }, 2 * NSEC_PER_SEC);

    if (!stopped) {
        log_user("[QuickLoader] Clean Up timed out; the script may be stuck in a long-running loop.\n");
        quickloader_abandon_js_queue_after_timeout("cleanup timeout", YES);
    }

    return stopped;
}
