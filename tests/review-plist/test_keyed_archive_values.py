#!/usr/bin/env python3
"""Plist editor value classification, compiled natively from the real source.

A keyed archive (NSKeyedArchiver) is a binary plist whose references are
CFKeyedArchiverUID objects: not a string, number, date, data, array or
dictionary. The editor used to classify anything unknown as a string and then
sent it NSString messages, which raised "unrecognized selector" as soon as such
a row was drawn. All data here is synthetic and in-memory.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Cyanide/PlistEditorViewController.m"


class KeyedArchiveValueTests(unittest.TestCase):
    def test_uid_values_are_opaque_and_summarised_without_string_calls(self):
        source = SOURCE.read_text()
        start = source.index("typedef NS_ENUM(NSInteger, PLType)")
        end = source.index("static id pl_default_value(PLType t)", start)
        helpers = source[start:end]
        harness = f'''
#import <Foundation/Foundation.h>
{helpers}

static void require_condition(BOOL condition, NSString *message)
{{
    if (condition) return;
    fprintf(stderr, "plist value test failed: %s\\n", message.UTF8String);
    exit(1);
}}

int main(void)
{{
    @autoreleasepool {{
        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:@{{ @"a": @"b" }}
                                                requiringSecureCoding:NO error:nil];
        NSDictionary *root = [NSPropertyListSerialization propertyListWithData:archive options:0
                                                                        format:NULL error:nil];
        require_condition([root isKindOfClass:NSDictionary.class], @"archive must parse as a plist");
        NSDictionary *top = root[@"$top"];
        id uid = top.allValues.firstObject;
        require_condition(uid != nil, @"archive must carry a $top reference");
        require_condition(![uid isKindOfClass:NSString.class], @"the reference is not a string");

        PLType type = pl_type_of(uid);
        require_condition(type == PLTypeOpaque, @"a reference must classify as opaque");
        require_condition(!pl_is_container(uid), @"a reference is not a container");
        // The call that used to raise: summarising the value for its row.
        NSString *summary = pl_summary(uid);
        require_condition(summary.length > 0, @"a reference must still be summarised");
        require_condition(pl_type_name(type).length > 0, @"an opaque value needs a row label");
        // Opaque stays out of the Add / Change Type menus.
        require_condition(pl_type_names().count == (NSUInteger)PLTypeOpaque,
                          @"the menu list must end before the opaque type");

        // Ordinary values keep their types and labels.
        require_condition(pl_type_of(@"x") == PLTypeString, @"string");
        require_condition(pl_type_of(@1) == PLTypeInteger, @"integer");
        require_condition(pl_type_of(@1.5) == PLTypeReal, @"real");
        require_condition(pl_type_of(@YES) == PLTypeBoolean, @"boolean");
        require_condition(pl_type_of(NSDate.date) == PLTypeDate, @"date");
        require_condition(pl_type_of(NSData.data) == PLTypeData, @"data");
        require_condition(pl_type_of(@[]) == PLTypeArray, @"array");
        require_condition(pl_type_of(@{{}}) == PLTypeDictionary, @"dictionary");
        require_condition([pl_type_name(PLTypeString) isEqualToString:@"String"], @"string label");
        require_condition([pl_summary(@"a\\nb") isEqualToString:@"a b"], @"string summary");
    }}
    return 0;
}}
'''
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "harness.m"
            exe = Path(tmp) / "harness"
            src.write_text(harness)
            subprocess.run(
                ["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-Wno-unused-function",
                 "-framework", "Foundation", str(src), "-o", str(exe)],
                check=True,
            )
            subprocess.run([str(exe)], check=True)


if __name__ == "__main__":
    unittest.main()
