#!/usr/bin/env python3
"""Source-contract checks for the runtime language packs."""
import json
import pathlib
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[3]
INFO = ROOT / "Cyanide/Info.plist"
IMPL = ROOT / "Cyanide/Localization/CyanideLanguage.m"

PACKS = {
    "zh-Hans": ROOT / "Cyanide/Localization-zh-Hans.plist",
    "de": ROOT / "Cyanide/Localization-de.plist",
    "fr": ROOT / "Cyanide/Localization-fr.plist",
    "es": ROOT / "Cyanide/Localization-es.plist",
    "it": ROOT / "Cyanide/Localization-it.plist",
    "ja": ROOT / "Cyanide/Localization-ja.plist",
    "ko": ROOT / "Cyanide/Localization-ko.plist",
    "pl": ROOT / "Cyanide/Localization-pl.plist",
    "pt-BR": ROOT / "Cyanide/Localization-pt-BR.plist",
    "ru": ROOT / "Cyanide/Localization-ru.plist",
    "th": ROOT / "Cyanide/Localization-th.plist",
    "tr": ROOT / "Cyanide/Localization-tr.plist",
    "vi": ROOT / "Cyanide/Localization-vi.plist",
    "ar": ROOT / "Cyanide/Localization-ar.plist",
}
REQUIRED = [
    "Home", "Packages", "Sources", "Log", "Settings", "Language",
    "Follow System", "Cancel", "OK", "Install", "File Browser",
    "Process Viewer", "Kernel access is not active. Run the chain first.",
    "Checking for Updates…", "Update Available", "Clear Queue?", "Favorites",
    "CarPlay without Siri", "Turning On Location Services",
    "Turning Off Location Services", "Location Services On", "Location Services Off",
]

catalogs = {}
pattern_sets = {}
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
    xml_keys = ET.fromstring(pack_path.read_bytes()).findall("./dict/dict/key")
    assert len(xml_keys) == len(strings), f"{code}: duplicate string key"
    catalogs[code] = set(strings)

    compiled = []
    for item in patterns:
        pattern = item.get("pattern")
        template = item.get("template")
        assert isinstance(pattern, str) and pattern, f"{code}: bad pattern"
        assert isinstance(template, str) and template, f"{code}: bad template"
        regex = re.compile(pattern)
        references = set(map(int, re.findall(r"\$(\d+)", template)))
        assert references == set(range(1, regex.groups + 1)), (
            f"{code}: capture mismatch for {pattern!r}: {template!r}"
        )
        compiled.append(regex.pattern)
    assert len(compiled) == len(set(compiled)), f"{code}: duplicate pattern"
    pattern_sets[code] = compiled

for code in PACKS:
    missing = catalogs["de"] - catalogs[code]
    extra = catalogs[code] - catalogs["de"]
    assert not (missing or extra), f"{code}: missing {sorted(missing)}; extra {sorted(extra)}"
    assert pattern_sets[code] == pattern_sets["de"], f"{code}: pattern coverage or order differs"

impl = IMPL.read_text(encoding="utf-8")
for symbol in ("CyanideLanguageInstall", "CyanideLocalized",
               "cy_language_setText:", "cy_language_setTitle:",
               "CyanideStringMatchesEnglish", "CyanideLanguageSupportedCodes"):
    assert symbol in impl, f"localization implementation missing {symbol}"
assert '"de"' in impl, "German is not registered in the language list"

info = plistlib.loads(INFO.read_bytes())
localizations = info.get("CFBundleLocalizations") or []
assert set(localizations) == {"en", *PACKS}, "Info.plist and language packs differ"

permission_keys = {key for key in info if key.endswith("UsageDescription")}
for code in PACKS:
    permission_path = ROOT / f"Cyanide/{code}.lproj/InfoPlist.strings"
    permission_copy = permission_path.read_text(encoding="utf-8")
    translated_keys = re.findall(r'^"([^"]+)"\s*=\s*"\S', permission_copy, re.MULTILINE)
    assert sorted(translated_keys) == sorted(permission_keys), f"{code}: permission copy differs"

controls = json.loads((ROOT / "CyanideControls/Localizable.xcstrings").read_text(encoding="utf-8"))
assert controls["sourceLanguage"] == "en"
assert controls["strings"], "Control Center and Shortcuts catalog is empty"
for key, item in controls["strings"].items():
    assert set(item["localizations"]) == set(PACKS), f"Controls: incomplete {key!r}"
    for code, localization in item["localizations"].items():
        unit = localization["stringUnit"]
        assert unit["state"] == "translated" and unit["value"].strip(), f"Controls: {code} {key!r}"

for code, pack_path in PACKS.items():
    strings = plistlib.loads(pack_path.read_bytes())["strings"]
    print(f"{code}: {len(strings)} strings, {len(plistlib.loads(pack_path.read_bytes())['patterns'])} patterns")
print("language packs ok")
