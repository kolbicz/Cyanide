//
//  darksword_ota.h
//

#ifndef darksword_ota_h
#define darksword_ota_h

#import <stdbool.h>

bool darksword_ota_set_disabled(bool disabled);

// Reads current OTA state from the launchd disabled.plist. Returns:
//   -1 = could not determine (no KRW / no filesystem access / read failed)
//    0 = enabled (none of our update daemons are blocked)
//    1 = fully disabled (all of our update daemons are blocked)
//    2 = partially disabled (some but not all)
int darksword_ota_read_disabled(void);

// Retries a launchd plist folder-mode restore left behind by an interrupted
// write. No-op when nothing is pending or kernel access is not ready.
void darksword_ota_retry_pending_dir_restore(void);

// Gives this app read/write access to /private/var (launchd token, sandbox
// patch or a borrowed daemon extension). Needs live kernel access.
bool darksword_prepare_var_rw(void);

#ifdef __OBJC__
#import <Foundation/Foundation.h>
// launchd's disabled.plist for any Daemons-catalog label (daemon_catalog.h).
// Both need live kernel access. Changes take effect after a restart.
// Returns the plist's contents, or nil if it couldn't be read.
NSDictionary<NSString *, id> *launchd_disabled_read(void);
// changes: label -> @YES (disable) / @NO (enable, i.e. remove the entry).
// Current catalog labels support both directions. A fixed set of labels from
// older catalogs supports only @NO recovery; all other labels are refused.
bool launchd_disabled_apply(NSDictionary<NSString *, NSNumber *> *changes);
#endif

#endif
