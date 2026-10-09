//
//  darksword_layout.h
//  Ported from kolbicz/DarkSword-Tweaks
//    - dock_and_home_spacing.m
//    - dock_and_homescreen_scaling.m
//  Patches SpringBoard's SBIconController layout config so the home grid
//  and dock can take extra padding and per-icon scaling.
//

#ifndef darksword_layout_h
#define darksword_layout_h

#import <stdbool.h>

// Adds extra padding to SBIconController's root layout insets. Defaults are
// top=60 left=27 bottom=100 right=27; these arguments are *additional* deltas
// (negative is allowed but won't go below the layout's hard minimums).
bool darksword_layout_home_spacing_in_session(double extraLeft,
                                              double extraRight,
                                              double extraTop,
                                              double extraBottom);

// Adds extra left/right inset to the dock layout. Default left/right = 16.
bool darksword_layout_dock_spacing_in_session(double extraLeft, double extraRight);

// Sets per-icon image info (width/height/cornerRadius) at scale * 60pt.
// scale must be in (0, 2].
bool darksword_layout_home_scale_in_session(double scale);
bool darksword_layout_dock_scale_in_session(double scale);

// Progress of the home-screen icon resize (iOS 18 path), called on the
// applying thread: once with pagesDone=0 after the pages are found, then after
// each page. iconsDone/iconsTotal count icon views.
typedef void (^DSLayoutProgressHandler)(int pagesDone, int pagesTotal,
                                        int iconsDone, int iconsTotal);
void darksword_layout_set_progress_handler(DSLayoutProgressHandler handler);

// Convenience: applies all four if their values are meaningful. scale<=0
// means "leave alone".
bool darksword_layout_apply_in_session(double extraLeft,
                                       double extraRight,
                                       double extraTop,
                                       double extraBottom,
                                       double extraDockLeft,
                                       double extraDockRight,
                                       double homeScale,
                                       double dockScale);

#endif
