//
//  sbcustomizer.h
//  Native port of the sbcustomizer dock+grid+labels patch.
//

#ifndef sbcustomizer_h
#define sbcustomizer_h

#import <stdbool.h>

bool sbcustomizer_apply(int dockIcons, int hsCols, int hsRows, bool hideLabels,
                        bool arrangePages, int firstPageIcons, int otherPageIcons,
                        bool autoDockApp, const char *dockAppBundleID);
bool sbcustomizer_apply_in_session(int dockIcons, int hsCols, int hsRows, bool hideLabels,
                                   bool arrangePages, int firstPageIcons, int otherPageIcons,
                                   bool autoDockApp, const char *dockAppBundleID);

// Hide home-screen icon labels per SBIconView (setLabelHidden:+_updateLabel).
// iOS 17 has no config-level label toggle, so this is applied as the last
// home-screen step. Returns the number of icon views hidden. Session must be open.
int sbcustomizer_hide_home_labels_in_session(void);

// iOS 17 durable Hide Labels: repoint -[SBIconView _shouldShowLabel] at a
// NO-returning IMP so every page (incl. off-screen ones rebuilt on swipe) drops
// its labels at build time, with no live loop. Returns 1 if the hook was installed.
// restore undoes it (a respring also clears it). Session must be open.
int sbcustomizer_swizzle_home_labels_hidden(void);
int sbcustomizer_restore_home_labels(void);
// Is our _shouldShowLabel hook installed this session? (Re-installing on a hot path
// races with SpringBoard's animations, so callers install once and query this
// instead of re-arming.) forget clears the record after a respring/session drop.
int sbcustomizer_home_labels_hook_active(void);
void sbcustomizer_forget_home_labels_hook_state(void);

// Show (or hide) the app-name labels under the dock icons. Stock iOS hides
// them. Sets the dock icon location's showsLabels (durable on iOS 18) and
// clears setLabelHidden: on the dock's own icon views (the only lever on
// iOS 17, and an immediate repaint on both). Returns icon views changed.
// mayForceShowLabels: the caller's permission to install the process-wide
// _shouldShowLabel=YES hook if the dock icons turn out to need it (iOS 17,
// and Hide Labels not holding the same method). Ignored when show is false.
int sbcustomizer_set_dock_labels_in_session(bool show, bool mayForceShowLabels);

// iOS 17 Dock Labels: the mirror of sbcustomizer_swizzle_home_labels_hidden().
// Points -[SBIconView _shouldShowLabel] at -[NSProxy isProxy] (YES) so dock
// icons stop answering NO and their labels are built. Process-wide, so it
// cannot be held at the same time as Hide Labels. restore_home_labels undoes
// either direction. Session must be open.
int sbcustomizer_swizzle_labels_shown(void);

// Cheap current-page identity for the Hide Labels loop's change detection.
uint64_t sbcustomizer_current_page_token(void);

#endif
