> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.19.0

Tendies wallpapers, and much less battery use for icon themes on iOS 17 and 18.

## New

- **Tendies Wallpapers** (Settings → Lara → Tendies Wallpapers, [#17](https://github.com/kolbicz/Cyanide/issues/17)): installs `.tendies` wallpaper files into the Lock Screen wallpaper gallery. The format is Nugget's, by leminlimez; installing follows Nugget and mond by rooootdev.
  - **Install .tendies Files…** takes one or more files (up to 10 wallpapers at a time). PosterBoard restarts afterwards, so the Lock Screen may flash.
  - Then long-press the Lock Screen, tap **+** and pick the wallpaper from the gallery (Collections, or Photos for video wallpapers).
  - **Added by Cyanide** lists what was installed: swipe one to remove it, or use **Remove All Added**. Apple's wallpapers aren't touched. If a wallpaper is your current Lock Screen, choose another one before removing it.

## Fixes

- **Battery use of icon themes and SnowBoard Lite** on iOS 17 and 18 ([#19](https://github.com/kolbicz/Cyanide/issues/19)): they checked the Home Screen several times a second all day and redrew every icon every 12 seconds. Now they check much less often when nothing changes and not at all while the device is locked.

- **Folder Size with Root Access** ([#18](https://github.com/kolbicz/Cyanide/issues/18)): folders only root can read now show their real size on disk instead of an estimate. Files that reserve far more space than they use (such as a system symbol cache) no longer make a folder look many gigabytes too large.

## About A18 / M4

On A18 / M4 devices a run has about a 50/50 chance of rebooting the device (a
kernel "panic") instead of succeeding — a known limit of these chips that can't
be fully fixed. It's a coin flip, so if it reboots, just try again; a few
attempts usually gets there. Once a run works, it stays working until your next
restart.

If you keep hitting panics, Settings → Launch Options has four knobs for the
A18 chain — exploit path (pe_v3 default, pe_v1 / pe_v2), memory shaping,
interleaved search and bounded search. Defaults are unchanged in this release;
other combinations may do better on your device. Each applies to the next fresh
run.
