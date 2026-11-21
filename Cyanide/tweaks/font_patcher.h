//
//  font_patcher.h
//  Cyanide
//
//  Makes an ordinary TrueType font usable as an iOS system font, on the
//  device: the same idea as lara's font patcher (rooootdev / neonmodder123,
//  which uses fontTools in the browser). iOS asks for the system font by its
//  weight axes and their names, which a plain font doesn't have, so it falls
//  back to another font. The result keeps the system font's identity (fvar,
//  avar, STAT, trak, meta and the names they use) with the new font's glyphs,
//  an empty gvar so every weight shows them, and is scaled to the system
//  font's units per em.
//
//  Differences from lara's patcher: hinting is dropped (iOS doesn't use it),
//  kerning (GPOS) is dropped when the font has to be scaled, and system-font
//  tables that refer to its own glyph numbers (morx, kerx, ...) are dropped
//  instead of kept, since they would point at the wrong glyphs.
//
//  A collection (the Lock Screen clock's ADTNumeric.ttc: one font per clock
//  style) is adapted face by face, each keeping its own identity and names,
//  with the new glyph tables shared between them.
//

#import <Foundation/Foundation.h>

// Whether `source` has to be adapted to stand in for `target` (target has
// weight axes and source doesn't, or target is a collection).
BOOL fontpatch_needed(NSData *target, NSData *source);

// Whether `source` can replace `target` at all. fontpatch_needed answers NO
// both for "nothing to adapt" and for "source could not be read", so on its
// own it let a damaged file, a non-font with a font's extension or a static
// CFF font skip adaptation and be written over the system font as it was.
// NO with *why (the parser's reason) for those.
BOOL fontpatch_source_usable(NSData *target, NSData *source, NSString **why);

// Whether `font` came out of fontpatch_adapt (it may still carry Apple's
// names).
BOOL fontpatch_is_adapted(NSData *font);

// The font's family name (name ID 1, else 4), or nil.
NSString *fontpatch_family_name(NSData *font);

// The adapted font, or nil with *errorOut. *noteOut: what was changed (e.g.
// "scaled from 1000 to 2048 units, kerning dropped").
NSData *fontpatch_adapt(NSData *target, NSData *source, NSString **errorOut, NSString **noteOut);
