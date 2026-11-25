//
//  app_decrypt.h
//  Cyanide
//
//  Settings → Lara → App Decrypt: makes a decrypted IPA of an App Store app
//  installed on this device, e.g. to inject a tweak into it and sideload it.
//  Idea from lara by rooootdev; implemented on Cyanide's own KRW. iOS 18
//  refuses mremap_encrypted outside the app itself, so the app is started
//  suspended in the background and its decrypted pages are read through the
//  kernel from the FairPlay pager objects in its VM map. Encrypted app
//  extensions and Watch apps aren't loaded by the app and are left out.
//
//  Needs filesystem access (sandbox lifted). Blocking; run off-main.
//

#import <Foundation/Foundation.h>

// App Store apps (FairPlay-encrypted: SC_Info, no embedded.mobileprovision).
// Each: @{ name, bundleID, version, path (the .app), (icon) }.
NSArray<NSDictionary *> *app_decrypt_store_apps(void);

// Where finished IPAs are kept (Cyanide's Documents/Decrypted).
NSString *app_decrypt_output_dir(void);

// Builds <output dir>/<Name>_<version>_decrypted.ipa. `progress(step, 0…1)` is
// called on the calling thread. Returns the IPA path, or nil with *errorOut.
// useSpringBoard: a SpringBoard session is open (caller holds it); when iOS
// won't decrypt inside Cyanide, SpringBoard does it.
// customBundleID: optional. When set, the main bundle and its nested
// extension/Watch bundle IDs are rewritten from the original ID; the caller
// must re-sign the IPA for the new ID before installing it.
NSString *app_decrypt_make_ipa(NSDictionary *app, BOOL useSpringBoard,
                               NSString *customBundleID,
                               void (^progress)(NSString *step, double fraction), NSString **errorOut);
