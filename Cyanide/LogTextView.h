//
//  LogTextView.h
//  Cyanide
//
//  Created by seo on 4/7/26.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface LogTextView : UITextView
@end

void log_init(void);
void log_write(const char *msg);
void log_write_raw_no_timestamp(const char *msg);
void log_set_verbose(BOOL enabled);
BOOL log_verbose_enabled(void);
void log_user(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// Persistent session logs. When a chain run begins, call log_session_begin()
// to open a timestamped file at <Documents>/chain-YYYYMMDD-HHMMSS.log.
// Every subsequent line emitted via the printf macro / log_user / log_write
// is tee'd into that file with an [HH:MM:SS.mmm] prefix. Call log_session_end()
// when the chain run finishes (typically in @finally) to flush + close.
// Info.plist's UIFileSharingEnabled surfaces these files in Files.app under
// On My iPhone → Cyanide.
void log_session_begin(void);
void log_session_end(void);
void log_session_flush(void);  // flush + fsync, keep file open for background tail

// Force the always-open live log (<Documents>/live.log) to media. Every line is
// already fflush()'d (survives a normal close); call this to also make it
// panic-durable up to now (e.g. on app backgrounding). Safe to call anytime.
void log_live_flush(void);

// Absolute path of the most recent session log file, or nil if none exist.
NSString * _Nullable log_most_recent_session_path(void);

// Absolute path owned by the currently open chain session, or nil when no
// session is active. Uploads use this while a run is in progress instead of
// inferring ownership from filesystem modification time.
NSString * _Nullable log_current_session_path(void);

// Snapshot of the in-app ring buffer (joined with '\n'). Always reflects the
// current state of what the user sees in Settings → View Log — boot identity,
// chain output, anything emitted via the printf macro / log_user. Returned
// even when no chain session is active, so the Contact email can ship live
// context regardless of whether log_session_begin/end ran.
NSString *log_inapp_buffer_snapshot(void);

// Round 43: when YES (default), routine [RC] RemoteCall lines are kept out of
// the in-app log + live.log (failures/problems still shown). The Process Viewer
// "Verbose logging" debug option passes NO to restore the full [RC] firehose.
void log_set_rc_filter(BOOL hideRoutineRemoteCall);

// Mirror printf into the LogTextView ring buffer. Any TU that imports this
// header gets its printf calls echoed both to stdout and to the in-app log.
#define printf(fmt, ...) ({ \
    printf(fmt, ##__VA_ARGS__); \
    char _logbuf[2560]; \
    snprintf(_logbuf, sizeof(_logbuf), fmt, ##__VA_ARGS__); \
    log_write(_logbuf); \
})
