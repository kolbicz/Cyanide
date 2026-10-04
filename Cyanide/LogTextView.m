//
//  LogTextView.m
//  Cyanide
//
//  Created by seo on 4/7/26.
//

#import "LogTextView.h"
#import <UIKit/UIKit.h>
#import <unistd.h>
#import <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <time.h>
#import "kexploit/machine_info.h"

#define LOG_MAX_LINES   50000
#define LOG_TRIM_TO     30000
#define LOG_LINE_SIZE   2560

static char            log_buf[LOG_MAX_LINES][LOG_LINE_SIZE];
static int             log_count    = 0;
static int             log_dirty    = 0;
static int             log_trim_gen = 0;  // increments each time the buffer is trimmed
static int             log_verbose  = 1;
static pthread_mutex_t log_mutex    = PTHREAD_MUTEX_INITIALIZER;

// Session-log persistence. log_file is non-NULL while a chain run is active;
// every completed line is also written here with a wall-clock timestamp.
// Both fields are guarded by log_mutex.
static FILE *log_file                = NULL;
// 50 ms. The first captured panic log lost the line identifying which search
// mapping was being scanned, because it fell inside a 200 ms window. The whole
// exploit phase is only a couple of seconds, so a tighter interval costs little
// and buys resolution exactly where it matters.
#define LOG_FSYNC_INTERVAL_NS 50000000ULL
static uint64_t log_last_fsync_ns = 0;
static char  log_file_path_c[1024]   = {0};

// Always-open "live" log. The chain-session file (log_file) only exists during
// an exploit run, so everything logged OUTSIDE a run -- KRW park/reattach
// churn during scrolling, the errors that precede a surprise re-arm -- went
// only to the in-memory ring buffer and was lost on close or panic. The live
// log captures every line to <Documents>/live.log continuously.
//
// Durability without the disk-writes resource kill (see the F_FULLFSYNC note on
// the session path and the 1 GB diskwrites report): every line is fflush()'d,
// which is enough to survive a normal close / jetsam / resource kill (the bytes
// sit in the OS buffer cache and reach the file even though the process dies).
// F_FULLFSYNC -- the expensive, media-durable, panic-surviving one -- runs only
// when NO chain session is already covering this window (during a run the chain
// file's own 50 ms fsync provides it) and is throttled to 1 s so a burst of
// lines can't amplify into gigabytes of journal writes.
#define LIVE_LOG_MAX_BYTES        (4 * 1024 * 1024)
#define LIVE_LOG_FSYNC_INTERVAL_NS 1000000000ULL
static FILE     *live_log_file        = NULL;
static char      live_log_path_c[1024] = {0};
static uint64_t  live_last_fsync_ns   = 0;

static NSURL *log_session_dir_url(void);   // defined below

// Open (append) the live log, computing its path once and rotating a single
// backup when it grows past the cap. Caller must hold log_mutex.
static void live_log_open_if_needed(void) {
    if (live_log_file) return;
    if (live_log_path_c[0] == '\0') {
        @autoreleasepool {
            NSURL *dir = log_session_dir_url();
            if (!dir) return;
            NSURL *url = [dir URLByAppendingPathComponent:@"live.log"];
            strlcpy(live_log_path_c, url.path.fileSystemRepresentation, sizeof(live_log_path_c));
        }
    }
    if (live_log_path_c[0] == '\0') return;

    struct stat st;
    if (stat(live_log_path_c, &st) == 0 && st.st_size > LIVE_LOG_MAX_BYTES) {
        char bak[1100];
        snprintf(bak, sizeof(bak), "%s.1", live_log_path_c);
        rename(live_log_path_c, bak);   // keep exactly one previous file
    }
    live_log_file = fopen(live_log_path_c, "a");
    if (live_log_file) {
        time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
        fprintf(live_log_file,
                "\n# --- Cyanide live log opened %04d-%02d-%02d %02d:%02d:%02d "
                "(built %s %s, round41) ---\n",
                tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                tm.tm_hour, tm.tm_min, tm.tm_sec, __DATE__, __TIME__);
        fflush(live_log_file);
    }
}

// Append one already-stamped line to the live log. Caller must hold log_mutex.
// sessionActive == (log_file != NULL): when true we skip F_FULLFSYNC here
// because the chain file is already fsyncing this window.
static void live_log_append(const char *stamped_line, bool sessionActive) {
    live_log_open_if_needed();
    if (!live_log_file) return;
    fprintf(live_log_file, "%s\n", stamped_line);
    fflush(live_log_file);   // survives close / jetsam / resource kill
    if (!sessionActive) {
        uint64_t nowNS = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        if (nowNS - live_last_fsync_ns >= LIVE_LOG_FSYNC_INTERVAL_NS) {
            fcntl(fileno(live_log_file), F_FULLFSYNC, 0);   // panic-durable
            live_last_fsync_ns = nowNS;
        }
    }
    if (ftello(live_log_file) > LIVE_LOG_MAX_BYTES) {
        fclose(live_log_file);
        live_log_file = NULL;   // reopened (with rotation) on the next line
    }
}

void log_init(void) {
    pthread_mutex_lock(&log_mutex);
    log_count = 0;
    log_dirty = 0;
    pthread_mutex_unlock(&log_mutex);
}

static char line_buf[LOG_LINE_SIZE];
static int  line_pos = 0;

static void log_timestamp_prefix(char *out, size_t outLen) {
    if (!out || outLen == 0) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    int ms = (int)(tv.tv_usec / 1000);
    snprintf(out, outLen, "[%02d:%02d:%02d.%03d] ",
             tm.tm_hour, tm.tm_min, tm.tm_sec, ms);
}

static int log_skip_timestamp = 0;

static void log_write_raw_internal(const char *msg, int skipTimestamp) {
    pthread_mutex_lock(&log_mutex);

    while (*msg) {
        if (*msg == '\n') {
            line_buf[line_pos] = '\0';
            char stamped_line[LOG_LINE_SIZE];
            if (line_pos > 0) {
                if (skipTimestamp) {
                    strlcpy(stamped_line, line_buf, sizeof(stamped_line));
                } else {
                    char prefix[32];
                    log_timestamp_prefix(prefix, sizeof(prefix));
                    snprintf(stamped_line, sizeof(stamped_line), "%s%s", prefix, line_buf);
                }
            } else {
                stamped_line[0] = '\0';
            }

            if (log_count >= LOG_MAX_LINES) {
                memmove(log_buf[0], log_buf[LOG_MAX_LINES - LOG_TRIM_TO], LOG_TRIM_TO * LOG_LINE_SIZE);
                log_count = LOG_TRIM_TO;
                log_trim_gen++;
            }
            strlcpy(log_buf[log_count], stamped_line, LOG_LINE_SIZE);
            log_count++;
            log_dirty = 1;

            if (log_file) {
                fprintf(log_file, "%s\n", stamped_line);
                fflush(log_file);
                // fflush only hands the bytes to the OS; on a kernel panic the
                // filesystem buffers never reach flash, so the run that most
                // needs a log leaves a 0-byte file (see chain-20260829-142508.log
                // and chain-20260830-133739.log, both from panicking runs).
                // F_FULLFSYNC forces them out. Rate-limited so the exploit's timing
                // is not perturbed by a flash write per line -- worst case we
                // lose the last LOG_FSYNC_INTERVAL_NS of output.
                uint64_t nowNS = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
                if (nowNS - log_last_fsync_ns >= LOG_FSYNC_INTERVAL_NS) {
                    // fsync() is NOT enough on Apple platforms -- it only pushes
                    // to the drive, which is why chain logs were still 0 bytes
                    // after panics. F_FULLFSYNC is the one that reaches media.
                    fcntl(fileno(log_file), F_FULLFSYNC, 0);
                    log_last_fsync_ns = nowNS;
                }
            }

            // Always mirror to the persistent live log so lines produced outside
            // a chain session (KRW park/reattach during scrolling) survive close
            // and panic, not just the in-memory ring buffer.
            if (stamped_line[0])
                live_log_append(stamped_line, log_file != NULL);

            line_pos  = 0;
        } else {
            if (line_pos < LOG_LINE_SIZE - 1)
                line_buf[line_pos++] = *msg;
        }
        msg++;
    }

    pthread_mutex_unlock(&log_mutex);
}

static void log_write_raw(const char *msg) {
    log_write_raw_internal(msg, log_skip_timestamp);
}

void log_write_raw_no_timestamp(const char *msg) {
    log_write_raw_internal(msg, 1);
}

void log_write(const char *msg) {
    if (!log_verbose_enabled()) return;
    log_write_raw(msg);
}

void log_set_verbose(BOOL enabled) {
    pthread_mutex_lock(&log_mutex);
    log_verbose = enabled ? 1 : 0;
    pthread_mutex_unlock(&log_mutex);
}

BOOL log_verbose_enabled(void) {
    pthread_mutex_lock(&log_mutex);
    BOOL enabled = log_verbose != 0;
    pthread_mutex_unlock(&log_mutex);
    return enabled;
}

void log_user(const char *fmt, ...) {
    char buf[LOG_LINE_SIZE];
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    vfprintf(stdout, fmt, ap2);
    va_end(ap2);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    log_write_raw(buf);
}

// ---------------------------------------------------------------------------
// Session log persistence
//
// log_session_begin opens a timestamped file under <Documents>/logs/. While it
// is open, log_write_raw (above) tees each completed line into it with an
// [HH:MM:SS.mmm] prefix. log_session_end flushes + closes.
// A capped retention policy keeps the newest N session logs and prunes older
// ones each time a session begins, so the directory doesn't grow unbounded.

#define LOG_SESSIONS_KEEP 20

static NSURL *log_session_dir_url(void) {
    // Logs land at the root of the app's Documents, which Info.plist's
    // UIFileSharingEnabled exposes to Files.app under
    // On My iPhone → Cyanide → chain-*.log.
    NSURL *docs = [[[NSFileManager defaultManager]
                    URLsForDirectory:NSDocumentDirectory
                           inDomains:NSUserDomainMask] firstObject];
    return docs;
}

static void log_prune_old_sessions(NSInteger keep) {
    @autoreleasepool {
        NSURL *dir = log_session_dir_url();
        if (!dir) return;
        NSArray<NSURL *> *files = [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:dir
            includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                             options:0
                               error:nil];
        if (!files) return;
        NSPredicate *isLog = [NSPredicate predicateWithFormat:@"pathExtension = 'log'"];
        NSArray<NSURL *> *logs = [files filteredArrayUsingPredicate:isLog];
        if (logs.count <= (NSUInteger)keep) return;
        NSArray<NSURL *> *sorted = [logs sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            NSDate *da = nil, *db = nil;
            [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
            [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
            return [db compare:da]; // newest first
        }];
        for (NSUInteger i = (NSUInteger)keep; i < sorted.count; i++) {
            [[NSFileManager defaultManager] removeItemAtURL:sorted[i] error:nil];
        }
    }
}

void log_session_begin(void) {
    NSURL *fileURL = nil;
    @autoreleasepool {
        NSURL *dir = log_session_dir_url();
        if (!dir) return;
        [[NSFileManager defaultManager] createDirectoryAtURL:dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];

        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyyMMdd-HHmmss";
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.timeZone = [NSTimeZone localTimeZone];
        NSString *name = [NSString stringWithFormat:@"chain-%@.log",
                          [df stringFromDate:[NSDate date]]];
        fileURL = [dir URLByAppendingPathComponent:name];
    }
    if (!fileURL) return;

    pthread_mutex_lock(&log_mutex);
    if (log_file) {
        fclose(log_file);
        log_file = NULL;
    }
    strlcpy(log_file_path_c, fileURL.path.fileSystemRepresentation, sizeof(log_file_path_c));
    log_file = fopen(log_file_path_c, "w");
    if (log_file) {
        time_t t = time(NULL);
        struct tm tm; localtime_r(&t, &tm);
        fprintf(log_file,
                "# Cyanide chain session %04d-%02d-%02d %02d:%02d:%02d\n",
                tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                tm.tm_hour, tm.tm_min, tm.tm_sec);

        // Device and build banner. Logs arrive from other people with no idea
        // what they were running on; every question about one of them so far
        // has started with "which device, which iOS, which Cyanide".
        {
            char machine[64] = {0};
            size_t sz = sizeof(machine);
            if (sysctlbyname("hw.machine", machine, &sz, NULL, 0) != 0)
                strlcpy(machine, "unknown", sizeof(machine));

            char osbuild[64] = {0};
            sz = sizeof(osbuild);
            if (sysctlbyname("kern.osversion", osbuild, &sz, NULL, 0) != 0)
                strlcpy(osbuild, "unknown", sizeof(osbuild));

            uint32_t cpuFamily = 0;
            sz = sizeof(cpuFamily);
            if (sysctlbyname("hw.cpufamily", &cpuFamily, &sz, NULL, 0) != 0)
                cpuFamily = 0;

            // Boot time and uptime. Without these, grouping runs by boot has to
            // be reconstructed from panic-log timestamps, which is guesswork --
            // and guessing it wrong is exactly how the "second run in a boot"
            // theory got made up on 2026-08-31.
            struct timeval boottv = {0};
            size_t btsz = sizeof(boottv);
            char bootDesc[64];
            if (sysctlbyname("kern.boottime", &boottv, &btsz, NULL, 0) == 0 && boottv.tv_sec) {
                time_t bt = boottv.tv_sec;
                struct tm btm;
                localtime_r(&bt, &btm);
                char stamp[32];
                strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &btm);
                long up = (long)(time(NULL) - bt);
                snprintf(bootDesc, sizeof(bootDesc), "%s (up %ldm %lds)",
                         stamp, up / 60, up % 60);
            } else {
                strlcpy(bootDesc, "unknown", sizeof(bootDesc));
            }

            NSString *osVersion = UIDevice.currentDevice.systemVersion ?: @"unknown";
            NSBundle *bundle = [NSBundle mainBundle];
            NSString *appVersion =
                [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
            NSString *appBuild =
                [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";

            // Keep the raw family alongside the name: the name is what makes
            // a log readable at a glance, the hex is what identifies a chip we
            // have no name for yet.
            const char *cpuName = machine_cpu_name(cpuFamily);
            char cpuDesc[64];
            if (cpuName)
                snprintf(cpuDesc, sizeof(cpuDesc), "%s (0x%08x)", cpuName, cpuFamily);
            else
                snprintf(cpuDesc, sizeof(cpuDesc), "0x%08x", cpuFamily);

            fprintf(log_file,
                    "# device %s  iOS %s (%s)  cpu %s\n"
                    "# booted %s\n"
                    "# Cyanide %s (%s)\n",
                    machine, osVersion.UTF8String, osbuild, cpuDesc,
                    bootDesc,
                    appVersion.UTF8String, appBuild.UTF8String);
        }
        fflush(log_file);
        // Same reason as the write path: without F_FULLFSYNC even the header
        // can be lost, which is how a panicking run left a 0-byte file.
        fcntl(fileno(log_file), F_FULLFSYNC, 0);
        log_last_fsync_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    }
    pthread_mutex_unlock(&log_mutex);

    log_prune_old_sessions(LOG_SESSIONS_KEEP);
}

void log_session_end(void) {
    pthread_mutex_lock(&log_mutex);
    if (log_file) {
        fflush(log_file);
        fclose(log_file);
        log_file = NULL;
        log_file_path_c[0] = '\0';
    }
    pthread_mutex_unlock(&log_mutex);
}

// Make everything so far durable WITHOUT closing the file. A chain run used to
// call log_session_end() at [DONE], which closed the file -- so the idle-park
// worker and live-tweak loops that keep logging in the background had nowhere
// to write, and their output showed only in the in-app view, never the
// shareable chain-*.log. Flushing instead leaves the file open to capture that
// tail; the next log_session_begin() rotates it.
void log_session_flush(void) {
    pthread_mutex_lock(&log_mutex);
    if (log_file) {
        fflush(log_file);
        fcntl(fileno(log_file), F_FULLFSYNC, 0);
        log_last_fsync_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    }
    pthread_mutex_unlock(&log_mutex);
}

// Force the live log all the way to media. fflush already makes each line
// survive a normal close, but a kernel panic loses the buffer cache; call this
// at moments worth a guaranteed flush (app backgrounding, terminal cleanup) so
// the live log is panic-durable up to that point without a per-line F_FULLFSYNC.
void log_live_flush(void) {
    pthread_mutex_lock(&log_mutex);
    if (live_log_file) {
        fflush(live_log_file);
        fcntl(fileno(live_log_file), F_FULLFSYNC, 0);
        live_last_fsync_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    }
    pthread_mutex_unlock(&log_mutex);
}

NSString *log_inapp_buffer_snapshot(void) {
    pthread_mutex_lock(&log_mutex);
    NSMutableString *out = [NSMutableString stringWithCapacity:log_count * 80];
    for (int i = 0; i < log_count; i++) {
        [out appendFormat:@"%s\n", log_buf[i]];
    }
    // Also flush the in-progress line that hasn't seen its newline yet, so
    // mid-flight chain state isn't dropped from the snapshot.
    if (line_pos > 0) {
        char tail[LOG_LINE_SIZE];
        int n = line_pos < LOG_LINE_SIZE - 1 ? line_pos : LOG_LINE_SIZE - 1;
        memcpy(tail, line_buf, n);
        tail[n] = '\0';
        [out appendFormat:@"%s", tail];
    }
    pthread_mutex_unlock(&log_mutex);
    return out;
}

NSString *log_most_recent_session_path(void) {
    @autoreleasepool {
        NSURL *dir = log_session_dir_url();
        if (!dir) return nil;
        NSArray<NSURL *> *files = [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:dir
            includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                             options:0
                               error:nil];
        if (!files) return nil;
        NSPredicate *isLog = [NSPredicate predicateWithFormat:@"pathExtension = 'log'"];
        NSArray<NSURL *> *logs = [files filteredArrayUsingPredicate:isLog];
        if (logs.count == 0) return nil;
        NSArray<NSURL *> *sorted = [logs sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            NSDate *da = nil, *db = nil;
            [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
            [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
            return [db compare:da];
        }];
        return sorted.firstObject.path;
    }
}

// Returns only lines [fromLine, log_count). Outputs current total and trim
// generation so callers can detect full-buffer trims. Returns nil if nothing new.
static NSString *log_snapshot_from(int fromLine, int *outTotal, int *outTrimGen) {
    pthread_mutex_lock(&log_mutex);
    int total   = log_count;
    int trimGen = log_trim_gen;
    if (outTotal)   *outTotal   = total;
    if (outTrimGen) *outTrimGen = trimGen;

    if (fromLine >= total && !log_dirty) {
        pthread_mutex_unlock(&log_mutex);
        return nil;
    }
    log_dirty = 0;

    int start = (fromLine < total) ? fromLine : total;
    if (start >= total) {
        pthread_mutex_unlock(&log_mutex);
        return nil;
    }

    NSMutableString *s = [[NSMutableString alloc] initWithCapacity:(total - start) * 80];
    for (int i = start; i < total; i++) {
        NSString *line = [NSString stringWithUTF8String:log_buf[i]];
        if (!line) line = [[NSString alloc] initWithBytes:log_buf[i]
                                                   length:strlen(log_buf[i])
                                                 encoding:NSISOLatin1StringEncoding];
        if (line) { [s appendString:line]; [s appendString:@"\n"]; }
    }

    pthread_mutex_unlock(&log_mutex);
    return s;
}

// ---------------------------------------------------------------------------
// Color map

static UIColor *colorForLogLine(NSString *line) {
    // ASCII banner (cyan bottle art)
    if ([line containsString:@"╭"] || [line containsString:@"╰"] ||
        [line containsString:@"│"] || [line containsString:@"├"] ||
        [line containsString:@"C Y A N I D E"])
        return [UIColor colorWithRed:0.00 green:0.90 blue:0.95 alpha:1.0]; // bright cyan

    // Strip timestamp prefix if present: "[HH:MM:SS.mmm] " -> check what follows
    NSString *content = line;
    if (line.length > 15 && [line characterAtIndex:0] == '[') {
        NSRange closeBracket = [line rangeOfString:@"] "];
        if (closeBracket.location != NSNotFound && closeBracket.location < 20) {
            content = [line substringFromIndex:closeBracket.location + 2];
        }
    }

    // Slim-mode milestone labels
    if ([content hasPrefix:@"[OK]"])          return [UIColor colorWithRed:0.38 green:0.90 blue:0.55 alpha:1.0]; // bright green
    if ([content hasPrefix:@"[WARN]"])        return [UIColor colorWithRed:0.96 green:0.38 blue:0.32 alpha:1.0]; // red
    if ([content hasPrefix:@"[FAIL]"])        return [UIColor colorWithRed:0.98 green:0.25 blue:0.50 alpha:1.0]; // pink-red
    if ([content hasPrefix:@"[DONE]"])        return [UIColor colorWithRed:0.30 green:0.85 blue:0.95 alpha:1.0]; // cyan
    if ([content hasPrefix:@"[RUN"])          return [UIColor colorWithRed:0.98 green:0.82 blue:0.30 alpha:1.0]; // gold ([RUN] and [RUN N/N])
    if ([content hasPrefix:@"[PLAN]"])        return [UIColor colorWithRed:0.65 green:0.60 blue:0.95 alpha:1.0]; // indigo
    if ([content hasPrefix:@"[BOOT]"])        return [UIColor colorWithRed:0.55 green:0.72 blue:0.92 alpha:1.0]; // cornflower
    if ([content hasPrefix:@"[SESSION]"])     return [UIColor colorWithRed:0.38 green:0.68 blue:0.98 alpha:1.0]; // bright sky blue
    if ([content hasPrefix:@"[CLEANUP]"])     return [UIColor colorWithRed:0.82 green:0.72 blue:0.56 alpha:1.0]; // warm tan
    if ([content hasPrefix:@"[LOG]"])         return [UIColor colorWithRed:0.60 green:0.62 blue:0.68 alpha:1.0]; // muted gray

    // Verbose subsystem labels
    if ([content hasPrefix:@"[SETTINGS]"])    return [UIColor colorWithRed:0.72 green:0.88 blue:1.00 alpha:1.0]; // ice blue (distinct from SESSION)
    if ([content hasPrefix:@"[APP]"])         return [UIColor colorWithRed:0.90 green:0.82 blue:0.52 alpha:1.0]; // warm gold
    if ([content hasPrefix:@"[INIT]"])        return [UIColor colorWithRed:0.60 green:0.40 blue:0.92 alpha:1.0]; // medium purple
    if ([content hasPrefix:@"[AXONLITE]"])    return [UIColor colorWithRed:0.72 green:0.98 blue:0.28 alpha:1.0]; // chartreuse
    if ([content hasPrefix:@"[THEMER]"])      return [UIColor colorWithRed:0.92 green:0.35 blue:0.85 alpha:1.0]; // fuchsia
    if ([content hasPrefix:@"[STAGE]"])       return [UIColor colorWithRed:0.78 green:0.48 blue:0.98 alpha:1.0]; // electric violet (Dynamic Stage Lite)
    if ([content hasPrefix:@"[TYPEBANNER]"])  return [UIColor colorWithRed:1.00 green:0.68 blue:0.48 alpha:1.0]; // warm peach
    if ([content hasPrefix:@"[RSSI]"])        return [UIColor colorWithRed:0.18 green:0.58 blue:0.95 alpha:1.0]; // cobalt blue
    if ([content hasPrefix:@"[KILLALL]"])     return [UIColor colorWithRed:0.88 green:0.18 blue:0.22 alpha:1.0]; // dark crimson
    if ([content hasPrefix:@"[INSTALLER]"])   return [UIColor colorWithRed:0.22 green:0.78 blue:0.88 alpha:1.0]; // cerulean
    if ([content hasPrefix:@"[UPDATE]"])      return [UIColor colorWithRed:0.28 green:0.88 blue:0.70 alpha:1.0]; // seafoam
    if ([content hasPrefix:@"[NANO"])         return [UIColor colorWithRed:0.22 green:0.90 blue:0.82 alpha:1.0]; // turquoise ([NANO] and [NANO-PROBE])
    if ([content hasPrefix:@"[RemoteCall]"])  return [UIColor colorWithRed:0.30 green:0.80 blue:1.00 alpha:1.0]; // vivid azure
    if ([content hasPrefix:@"[SBX]"])         return [UIColor colorWithRed:0.95 green:0.52 blue:0.88 alpha:1.0]; // hot magenta-pink
    if ([content hasPrefix:@"[kutils]"])      return [UIColor colorWithRed:0.90 green:0.50 blue:0.28 alpha:1.0]; // rust orange
    if ([content hasPrefix:@"[SBC]"])         return [UIColor colorWithRed:0.80 green:0.58 blue:0.90 alpha:1.0]; // lavender
    if ([content hasPrefix:@"[STATBAR]"])     return [UIColor colorWithRed:0.56 green:0.88 blue:0.64 alpha:1.0]; // mint
    if ([content hasPrefix:@"[POWERCUFF]"])   return [UIColor colorWithRed:0.96 green:0.50 blue:0.50 alpha:1.0]; // coral
    if ([content hasPrefix:@"[DST"])          return [UIColor colorWithRed:0.40 green:0.90 blue:0.88 alpha:1.0]; // teal ([DST] [DST:APPLIB] etc.)
    if ([content hasPrefix:@"[OTA]"])         return [UIColor colorWithRed:1.00 green:0.88 blue:0.40 alpha:1.0]; // amber
    if ([content hasPrefix:@"[ota]"])         return [UIColor colorWithRed:1.00 green:0.88 blue:0.40 alpha:1.0]; // amber (lowercase variant)
    if ([content hasPrefix:@"[RESPRING]"])    return [UIColor colorWithRed:1.00 green:0.72 blue:0.30 alpha:1.0]; // orange
    if ([content hasPrefix:@"[5ICON]"])       return [UIColor colorWithRed:0.98 green:0.95 blue:0.55 alpha:1.0]; // pale yellow
    if ([content hasPrefix:@"[KRW]"])         return [UIColor colorWithRed:0.70 green:0.56 blue:1.00 alpha:1.0]; // violet (was pink — read as an error next to [WARN]/[FAIL])
    if ([content hasPrefix:@"[PERSIST]"])     return [UIColor colorWithRed:0.70 green:0.75 blue:0.85 alpha:1.0]; // steel blue
    if ([content hasPrefix:@"[HSSPACE]"])     return [UIColor colorWithRed:0.50 green:0.95 blue:0.42 alpha:1.0]; // spring green
    if ([content hasPrefix:@"[DOCKSPACE]"])   return [UIColor colorWithRed:0.50 green:0.95 blue:0.42 alpha:1.0]; // spring green
    if ([content hasPrefix:@"[HSSCALE]"])     return [UIColor colorWithRed:0.50 green:0.95 blue:0.42 alpha:1.0]; // spring green
    if ([content hasPrefix:@"[DOCKSCALE]"])   return [UIColor colorWithRed:0.50 green:0.95 blue:0.42 alpha:1.0]; // spring green
    if ([content hasPrefix:@"[LAYOUT26]"])    return [UIColor colorWithRed:0.50 green:0.95 blue:0.42 alpha:1.0]; // spring green
    if ([content hasPrefix:@"[GRAVITY]"])     return [UIColor colorWithRed:0.60 green:0.80 blue:1.00 alpha:1.0]; // sky blue
    // Exploit chain debug prefixes
    if ([content hasPrefix:@"[+]"])          return [UIColor colorWithRed:0.45 green:0.82 blue:0.72 alpha:1.0]; // jade green
    if ([content hasPrefix:@"[i]"])          return [UIColor colorWithRed:0.58 green:0.72 blue:0.92 alpha:1.0]; // soft periwinkle
    if ([content hasPrefix:@"[-]"])          return [UIColor colorWithRed:0.92 green:0.45 blue:0.38 alpha:1.0]; // warm red

    return [UIColor colorWithWhite:0.86 alpha:1.0];
}

// ---------------------------------------------------------------------------

@interface LogTextView ()
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic) int renderedLineCount;
@property (nonatomic) int renderedTrimGen;
@property (nonatomic) BOOL followTail;
@property (nonatomic) BOOL pendingTailScroll;
@end

@implementation LogTextView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self setup];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self setup];
    return self;
}

- (void)setup {
    self.editable   = NO;
    self.font       = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    self.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1.0];
    self.textColor  = [UIColor colorWithWhite:0.88 alpha:1.0];
    self.textContainerInset = UIEdgeInsetsMake(14, 16, 24, 16);
    self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    _followTail = YES;

    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    _displayLink.preferredFramesPerSecond = 60;
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        _renderedLineCount = 0;
        _followTail = YES;
        [self refreshLogTextForced:YES];
    }
}

- (void)tick {
    [self refreshLogTextForced:NO];
}

- (NSMutableAttributedString *)buildAttrStringForText:(NSString *)text {
    UIFont *font = self.font ?: [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    UIFont *boldFont = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.lineSpacing = 5.0;
    para.paragraphSpacing = 1.0;

    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] init];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *rawLine = lines[i];
        // skip the trailing empty element that follows the last \n
        if (i + 1 == lines.count && rawLine.length == 0) break;

        UIColor *color = colorForLogLine(rawLine); // use raw line for color matching

        // Build display string: strip [HH:MM:SS.mmm] timestamp
        NSString *display = rawLine;
        if (display.length > 15 && [display characterAtIndex:0] == '[') {
            NSRange tsClose = [display rangeOfString:@"] "];
            if (tsClose.location != NSNotFound && tsClose.location < 20)
                display = [display substringFromIndex:tsClose.location + 2];
        }

        // Strip brackets from [TAG] prefix — only for short identifiers (< 20 chars)
        NSRange tagRange = NSMakeRange(NSNotFound, 0);
        if (display.length > 2 && [display characterAtIndex:0] == '[') {
            NSRange tagClose = [display rangeOfString:@"] "];
            if (tagClose.location != NSNotFound && tagClose.location < 20) {
                NSString *tag  = [display substringWithRange:NSMakeRange(1, tagClose.location - 1)];
                NSString *rest = [display substringFromIndex:tagClose.location + 2];
                display  = [NSString stringWithFormat:@"%@ %@", tag, rest];
                tagRange = NSMakeRange(0, tag.length);
            }
        }

        NSString *lineText = [display stringByAppendingString:@"\n"];
        NSMutableAttributedString *lineAttr = [[NSMutableAttributedString alloc]
            initWithString:lineText
                attributes:@{
                    NSFontAttributeName:            font,
                    NSForegroundColorAttributeName: color,
                    NSParagraphStyleAttributeName:  para,
                }];
        if (tagRange.location != NSNotFound && NSMaxRange(tagRange) <= lineText.length)
            [lineAttr addAttribute:NSFontAttributeName value:boldFont range:tagRange];
        [attr appendAttributedString:lineAttr];
    }
    return attr;
}

- (CGFloat)bottomContentOffsetY {
    CGFloat minY = -self.adjustedContentInset.top;
    CGFloat maxY = self.contentSize.height - self.bounds.size.height + self.adjustedContentInset.bottom;
    return MAX(minY, maxY);
}

- (BOOL)isCloseToBottom {
    return self.contentOffset.y >= ([self bottomContentOffsetY] - 80.0);
}

- (void)scrollToBottomNow {
    CGFloat y = [self bottomContentOffsetY];
    if (fabs(self.contentOffset.y - y) > 0.5) {
        [self setContentOffset:CGPointMake(0.0, y) animated:NO];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_pendingTailScroll || (_followTail && !self.tracking && !self.dragging && !self.decelerating)) {
        _pendingTailScroll = NO;
        [self scrollToBottomNow];
    }
}

- (void)refreshLogTextForced:(BOOL)force {
    if (force) _renderedLineCount = 0;

    int totalLines = 0, trimGen = 0;
    NSString *newText = log_snapshot_from(_renderedLineCount, &totalLines, &trimGen);

    // Buffer was trimmed: old rendered content is stale — full rebuild.
    BOOL needsRebuild = (trimGen != _renderedTrimGen);
    if (needsRebuild) {
        _renderedLineCount = 0;
        _renderedTrimGen   = trimGen;
        newText = log_snapshot_from(0, &totalLines, &trimGen);
    }

    if (!newText) return;

    NSMutableAttributedString *newAttr = [self buildAttrStringForText:newText];
    if (newAttr.length == 0) return;

    BOOL wasEmpty = (_renderedLineCount == 0);
    BOOL userScrolling = self.tracking || self.dragging || self.decelerating;
    if (wasEmpty || (!userScrolling && [self isCloseToBottom])) {
        _followTail = YES;
    } else if (userScrolling && ![self isCloseToBottom]) {
        _followTail = NO;
    }

    [self.textStorage beginEditing];
    if (needsRebuild || wasEmpty) {
        [self.textStorage replaceCharactersInRange:NSMakeRange(0, self.textStorage.length)
                               withAttributedString:newAttr];
    } else {
        [self.textStorage appendAttributedString:newAttr];
    }
    [self.textStorage endEditing];

    _renderedLineCount = totalLines;

    if (_followTail && !userScrolling) {
        _pendingTailScroll = YES;
        [self setNeedsLayout];
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            if (s.followTail && !s.tracking && !s.dragging && !s.decelerating) {
                s.pendingTailScroll = NO;
                [s layoutIfNeeded];
                [s scrollToBottomNow];
            }
        });
    }
}

- (void)removeFromSuperview {
    [_displayLink invalidate];
    _displayLink = nil;
    [super removeFromSuperview];
}

@end
