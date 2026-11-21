#!/usr/bin/env python3
"""Font Overwrite source validation, compiled natively from the real parser.

fontpatch_needed() answers NO both for "nothing to adapt" and for "the source
could not be read", so a damaged file, a non-font with a font's extension or a
static CFF font used to skip adaptation and be written over the system font as
it was. fontpatch_source_usable() is the gate added in front of it. The fonts
here are synthetic table directories, built in memory.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TWEAKS = ROOT / "Cyanide/tweaks"

HARNESS = r'''
#import <Foundation/Foundation.h>
#import "font_patcher.h"
static NSData *sfnt(const char *magic, NSArray<NSString *> *tags) {
    NSMutableData *d = [NSMutableData data];
    uint8_t head[12] = {0}; memcpy(head, magic, 4); head[5] = (uint8_t)tags.count;
    [d appendBytes:head length:12];
    uint32_t off = 12 + 16 * (uint32_t)tags.count;
    for (NSString *t in tags) {
        uint8_t r[16] = {0}; memcpy(r, t.UTF8String, 4);
        r[8] = off >> 24; r[9] = off >> 16; r[10] = off >> 8; r[11] = off; r[15] = 4;
        [d appendBytes:r length:16]; off += 4;
    }
    [d increaseLengthBy:4 * tags.count];
    return d;
}
int main(void) { @autoreleasepool {
    const char tt[4] = {0, 1, 0, 0};
    NSData *target = sfnt(tt, @[@"fvar", @"glyf"]);          // single variable TrueType target
    NSMutableData *ttc = [NSMutableData dataWithBytes:"ttcf\0\1\0\0\0\0\0\2\0\0\0\x14\0\0\0\x14" length:20];
    [ttc appendData:sfnt(tt, @[@"glyf"])];                    // collection target: 2 faces at offset 20
    struct { const char *name; NSData *target; NSData *source; BOOL want; } cases[] = {
        { "garbage bytes",            target, [@"this is not a font at all" dataUsingEncoding:NSUTF8StringEncoding], NO },
        { "truncated (5 bytes)",      target, [NSData dataWithBytes:"\0\1\0\0\0" length:5], NO },
        { "table past end",           target, [sfnt(tt, @[@"glyf"]) subdataWithRange:NSMakeRange(0, 28)], NO },
        { "plain TrueType",           target, sfnt(tt, @[@"glyf"]), YES },
        { "static CFF",               target, sfnt("OTTO", @[@"CFF "]), NO },
        { "variable CFF, single tgt", target, sfnt("OTTO", @[@"CFF2", @"fvar"]), YES },
        { "variable CFF, collection", ttc,    sfnt("OTTO", @[@"CFF2", @"fvar"]), NO },
    };
    int bad = 0;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        NSString *why = nil;
        BOOL got = fontpatch_source_usable(cases[i].target, cases[i].source, &why);
        printf("%-26s usable=%d (want %d)%s%s\n", cases[i].name, got, cases[i].want, why ? "  reason: " : "", why.UTF8String ?: "");
        if (got != cases[i].want || (!got && !why.length)) bad++;
    }
    printf(bad ? "FAIL\n" : "PASS\n");
    return bad;
} }
'''

# font_patcher.m imports ../LogTextView.h, which needs UIKit; it only uses the
# header for logging, so the copy is compiled next to a Foundation-only stand-in.
LOG_STUB = """#import <Foundation/Foundation.h>
#include <stdio.h>
static inline void log_user(const char *fmt, ...) { (void)fmt; }
"""


class FontSourceUsableTests(unittest.TestCase):
    def test_unreadable_and_static_cff_sources_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "tweaks").mkdir()
            shutil.copy(TWEAKS / "font_patcher.m", tmp / "tweaks/font_patcher.m")
            shutil.copy(TWEAKS / "font_patcher.h", tmp / "tweaks/font_patcher.h")
            (tmp / "LogTextView.h").write_text(LOG_STUB)
            (tmp / "main.m").write_text(HARNESS)
            exe = tmp / "check"
            subprocess.run(
                ["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc",
                 "-Wno-nullability-completeness", "-Wno-unused-function",
                 "-I", str(tmp / "tweaks"), "-framework", "Foundation",
                 str(tmp / "tweaks/font_patcher.m"), str(tmp / "main.m"), "-o", str(exe)],
                check=True,
            )
            result = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
