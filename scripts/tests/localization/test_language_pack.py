#!/usr/bin/env python3
"""Source-contract checks for the runtime language pack."""
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
PACK = ROOT / "Cyanide/Localization-zh-Hans.plist"
INFO = ROOT / "Cyanide/Info.plist"
IMPL = ROOT / "Cyanide/Localization/CyanideLanguage.m"

data = plistlib.loads(PACK.read_bytes())
strings = data.get("strings")
patterns = data.get("patterns")
assert isinstance(strings, dict) and strings, "strings dictionary missing"
assert isinstance(patterns, list), "patterns array missing"

for key, value in strings.items():
    assert isinstance(key, str) and key.strip(), f"bad key: {key!r}"
    assert isinstance(value, str) and value.strip(), f"empty translation for {key!r}"

required = [
    "Home", "Packages", "Sources", "Log", "Settings", "Language",
    "Follow System", "English", "Cancel", "OK", "Install", "File Browser",
    "Process Viewer", "Kernel access is not active. Run the chain first.",
]
missing = [k for k in required if k not in strings]
assert not missing, f"missing required translations: {missing}"

for item in patterns:
    assert isinstance(item, dict), f"bad pattern entry: {item!r}"
    pattern = item.get("pattern")
    template = item.get("template")
    assert isinstance(pattern, str) and pattern, f"bad pattern: {item!r}"
    assert isinstance(template, str) and template, f"bad template: {item!r}"
    re.compile(pattern)

impl = IMPL.read_text(encoding="utf-8")
for symbol in ("CyanideLanguageInstall", "CyanideLocalized",
               "cy_language_setText:", "cy_language_setTitle:",
               "CyanideStringMatchesEnglish"):
    assert symbol in impl, f"localization implementation missing {symbol}"

info = plistlib.loads(INFO.read_bytes())
localizations = info.get("CFBundleLocalizations") or []
assert "zh-Hans" in localizations, "Info.plist does not advertise zh-Hans"

print(f"language pack ok: {len(strings)} strings, {len(patterns)} patterns")
