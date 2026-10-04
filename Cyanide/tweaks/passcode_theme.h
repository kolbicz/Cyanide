//
//  passcode_theme.h
//  Cyanide
//  Adapted from Lara's Passcode implementation (ruter) via Eagle
//  (https://github.com/leonardob8777-bit/Eagle, AGPL-3.0).
//
//  Lock Screen passcode keypad art (TelephonyUI digit PNGs) replacement.
//

#ifndef passcode_theme_h
#define passcode_theme_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdbool.h>

// Digits are "0"–"9". The library holds one style: a folder in Cyanide's own
// storage with one PNG per digit (<digit>.png). A style may cover only some
// digits; the rest stay stock.
NSDictionary *settings_passcode_selected_theme(void);
NSString *settings_passcode_selected_theme_display_name(void);
void settings_passcode_clear_selected_theme(void);
// Returns the selected style, creating an empty "My Style" folder first when
// nothing is stored yet, so single-digit photo picks have somewhere to land.
NSDictionary *settings_passcode_ensure_selected_theme(NSError **error);

// Imports the PNG/JPG digit art found in `url` (matched by filename) into
// Cyanide's library, replacing the current style's art. The source folder is
// left untouched.
BOOL settings_passcode_import_folder_named(NSURL *url,
                                           NSString *displayName,
                                           NSError **error);

// Digit art of a theme: digit -> PNG data. Digits without art are omitted.
NSDictionary<NSString *, NSData *> *settings_passcode_theme_digit_images(NSDictionary *theme);
// Whether the keypad cache currently holds the selected style. One digit is
// compared, which is enough for a status line. `Unknown` means the cache could
// not be read at all (no kernel access yet): after a reboot the style is still
// applied on disk, but nothing can be claimed either way.
typedef NS_ENUM(NSInteger, PTPasscodeStyleState) {
    PTPasscodeStyleStateUnknown = 0,
    PTPasscodeStyleStateApplied,
    PTPasscodeStyleStateNotApplied,
};
PTPasscodeStyleState settings_passcode_style_state(void);
// Digits the theme has art for. Cheap (file attribute checks only) so list rows
// can call it without loading the images.
NSSet<NSString *> *settings_passcode_theme_digit_presence(NSDictionary *theme);
// Stores one digit's art inside the theme folder, replacing any previous art
// for that digit.
BOOL settings_passcode_theme_set_digit_image(NSDictionary *theme,
                                             NSString *digit,
                                             NSData *pngData,
                                             NSError **error);
// Number of original digits backed up in Cyanide's app container.
NSUInteger settings_passcode_theme_backup_count(void);
// Distinct digits the saved originals cover. One digit usually has several
// variant files in the cache (@2x/@3x, dark/light), so the file count alone
// reads as a mystery number.
NSUInteger settings_passcode_backup_digit_count(void);

// Resizes a picked photo to the keypad art geometry (202 points tall) and
// returns PNG data, or nil when it cannot be encoded.
NSData *settings_passcode_png_data_for_image(UIImage *image);

// ---------------------------------------------------------------------------
// Core engine. Requires active KRW plus unlocked /private/var write access;
// the Settings layer gates this behind settings_ensure_kexploit().
// ---------------------------------------------------------------------------

// First existing /var/mobile/Library/Caches/TelephonyUI-* directory (newest
// first), or nil when this device has no keypad cache.
NSString *settings_passcode_telephony_base_path(void);
// digit -> target PNG paths under basePath.
NSDictionary<NSString *, NSArray<NSString *> *> *settings_passcode_targets_by_digit(NSString *basePath);
// Total keypad files matched under basePath (all variants of all digits).
NSUInteger settings_passcode_keypad_file_count(NSString *basePath);
// Digit art the keypad cache currently holds (first target per digit), or an
// empty dictionary when the cache cannot be read. Lets the preview show what
// the Lock Screen actually displays right now — including art another app
// wrote, or the stock art. Needs local /private/var read access.
NSDictionary<NSString *, NSData *> *settings_passcode_current_digit_images(void);

// Backs up the first originals into Cyanide's app container, writes each
// digit's art over every keypad file for that digit, and verifies each write
// by reading it back. A write that cannot be verified rolls back to the
// previous art; original backups are never overwritten, and a file that already
// holds the art being written is never filed as an original.
bool settings_passcode_apply_digits(NSDictionary<NSString *, NSData *> *digits);
// Writes every backed-up original digit back and verifies each restore. Pass nil
// (or an empty string) to resolve the keypad cache path inside, after
// /private/var has been unlocked — probing it while the sandbox is still closed
// makes every candidate directory look absent.
bool settings_passcode_restore_originals(NSString *basePath);

// ---------------------------------------------------------------------------
// Backup transfer. The originals live in Cyanide's app container, which a
// reinstall wipes, while the system keypad cache they mirror survives — so an
// exported copy is the only way to keep the stock art recoverable afterwards.
// ---------------------------------------------------------------------------

// Copies every *.orig found in the picked items into the backup store. Folders
// are searched recursively so an exported copy that landed inside another
// folder still works. Backups already present on the device are kept and never
// overwritten — the local copy may be the only genuine original left.
// Returns how many were added; *skippedOut receives how many were left alone,
// *failedOut how many could not be copied or verified, and *unrecognizedOut how
// many carry no TelephonyUI path — those are stored, but Restore can never write
// them back.
NSUInteger settings_passcode_import_backup_items(NSArray<NSURL *> *items,
                                                 NSUInteger *skippedOut,
                                                 NSUInteger *failedOut,
                                                 NSUInteger *unrecognizedOut);

// Packs every stored backup into one .zip under the temporary directory and
// returns its URL (nil on failure). Files handles a single archive far better
// than a folder of .orig files, and the importer reads the same archive back.
// skippedOut, when not NULL, reports how many backups could not be read and are
// therefore absent from the archive, so the caller can say so instead of
// handing over an archive that only looks complete.
NSURL *settings_passcode_create_backup_archive(NSError **error, NSUInteger *skippedOut);

// Deletes every stored original backup and returns how many were removed.
// Irreversible: Restore Original Digits has nothing to write back afterwards,
// and the current keypad art can no longer be proven stock — from here on an
// Apply would file the art already on disk as the "original".
NSUInteger settings_passcode_delete_all_backups(void);
// YES once the saved originals have been deleted on this device. The panel uses
// it to warn before an Apply would treat the current keypad art as stock.
BOOL settings_passcode_originals_were_discarded(void);

// Human-readable outcome of the last apply/restore for the Settings panel.
NSString *settings_passcode_last_result_summary(void);

#endif /* passcode_theme_h */
