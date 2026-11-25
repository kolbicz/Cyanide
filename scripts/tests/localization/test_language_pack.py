#!/usr/bin/env python3
"""Source-contract checks for the runtime language packs."""
import pathlib
import plistlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[3]
INFO = ROOT / "Cyanide/Info.plist"
IMPL = ROOT / "Cyanide/Localization/CyanideLanguage.m"

PACKS = {
    "zh-Hans": ROOT / "Cyanide/Localization-zh-Hans.plist",
    "de": ROOT / "Cyanide/Localization-de.plist",
    "fr": ROOT / "Cyanide/Localization-fr.plist",
}
REQUIRED = [
    "Home", "Packages", "Sources", "Log", "Settings", "Language",
    "Follow System", "Cancel", "OK", "Install", "File Browser",
    "Process Viewer", "Kernel access is not active. Run the chain first.",
]

for code, pack_path in PACKS.items():
    data = plistlib.loads(pack_path.read_bytes())
    strings = data.get("strings")
    patterns = data.get("patterns")
    assert isinstance(strings, dict) and strings, f"{code}: strings missing"
    assert isinstance(patterns, list) and patterns, f"{code}: patterns missing"

    for key, value in strings.items():
        assert isinstance(key, str) and key.strip(), f"{code}: bad key {key!r}"
        assert isinstance(value, str) and value.strip(), f"{code}: empty value for {key!r}"

    missing = [k for k in REQUIRED if k not in strings]
    assert not missing, f"{code}: missing translations {missing}"

    for item in patterns:
        pattern = item.get("pattern")
        template = item.get("template")
        assert isinstance(pattern, str) and pattern, f"{code}: bad pattern"
        assert isinstance(template, str) and template, f"{code}: bad template"
        re.compile(pattern)

impl = IMPL.read_text(encoding="utf-8")
for symbol in ("CyanideLanguageInstall", "CyanideLocalized",
               "cy_language_setText:", "cy_language_setTitle:",
               "CyanideStringMatchesEnglish", "CyanideLanguageSupportedCodes"):
    assert symbol in impl, f"localization implementation missing {symbol}"
assert '"de"' in impl, "German is not registered in the language list"

info = plistlib.loads(INFO.read_bytes())
localizations = info.get("CFBundleLocalizations") or []
for code in PACKS:
    assert code in localizations, f"Info.plist does not advertise {code}"

for code, pack_path in PACKS.items():
    strings = plistlib.loads(pack_path.read_bytes())["strings"]
    print(f"{code}: {len(strings)} strings, {len(plistlib.loads(pack_path.read_bytes())['patterns'])} patterns")
print("language packs ok")
