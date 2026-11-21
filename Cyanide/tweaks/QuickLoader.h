//
//  QuickLoader.h
//

#ifndef QuickLoader_h
#define QuickLoader_h

#import <stdbool.h>
#import <Foundation/Foundation.h>

bool quickloader_apply_in_session();

bool quickloader_run_js_string(NSString *jsCode);

bool quickloader_stop_in_session(void);

bool quickloader_save_repo_tweak(NSString *repoURL,
                                 NSString *tweakID,
                                 NSString *displayName,
                                 NSString *rawScript,
                                 NSDictionary *values);
bool quickloader_is_repo_tweak_installed(NSString *repoURL, NSString *tweakID);
void quickloader_clear_repo_tweak_if_matches(NSString *repoURL, NSString *tweakID);
bool quickloader_refresh_active_repo_tweak(void);
// The QuickLoader slot is going to another owner (nil, nil: a local script or
// nothing): forget the previous repo tweak's installed version.
void quickloader_forget_previous_repo_owner(NSString *newRepoURL, NSString *newTweakID);
// True when the source's cached script for the installed repo tweak differs
// from the installed copy: the source changed the code (with or without a new
// version number) and the user has not taken the update yet.
bool quickloader_repo_tweak_has_changed_script(NSString *repoURL, NSString *tweakID);
bool quickloader_is_driven_by_repo_tweak(void);

#endif /* QuickLoader_h */
