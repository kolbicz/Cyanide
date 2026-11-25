#!/usr/bin/env python3
"""Source-contract checks for App Decrypt custom bundle IDs (issue #16)."""
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[3]
HEADER = ROOT / "Cyanide/tweaks/app_decrypt.h"
IMPL = ROOT / "Cyanide/tweaks/app_decrypt.m"
UI = ROOT / "Cyanide/LaraViewController.m"

header = HEADER.read_text(encoding="utf-8")
assert "customBundleID" in header, "app_decrypt_make_ipa lacks customBundleID"

impl = IMPL.read_text(encoding="utf-8")
for symbol in ("ad_rewrite_bundle_ids", "CFBundleIdentifier",
               "WKCompanionAppBundleIdentifier", "WKAppBundleIdentifier",
               "_custom"):
    assert symbol in impl, f"app_decrypt.m missing {symbol}"

ui = UI.read_text(encoding="utf-8")
for symbol in ("addTextFieldWithConfigurationHandler", "isValidBundleID",
               "customBundleID", "Invalid Bundle ID"):
    assert symbol in ui, f"LaraViewController.m missing {symbol}"

print("app-decrypt custom bundle ID source contract: PASS")
