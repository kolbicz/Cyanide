> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.30.0

CarPlay without Siri, and the results of a full review of the app: safer writes, fewer crashes, and a lot of small things that now do what they say.

## New

- **CarPlay without Siri** (package, off until you turn it on): since iOS 18, CarPlay shows "CarPlay Not Available — To use CarPlay, enable Siri" while Siri is off. This lifts that screen, and Siri stays off. It is applied per connection: with the **CarPlay** Control Center button (iOS 18), the **CarPlay without Siri** Shortcuts action, a `cyanide://carplay` link, or Run while the car is connected. For hands-free use, create a Shortcuts automation **CarPlay → Connects → Run Immediately** with that action. It needs kernel access from an earlier Run.

## Safer

- **Repo tweaks keep running the code you installed:** refreshing a source no longer swaps the script behind an installed tweak. Changed code is offered as an update instead, even when its version number stayed the same.
- **Built-in packages** can only be switched on by Cyanide's own source, not by a package with the same ID from another source. Such a package now installs as an ordinary script.
- **Font Overwrite** checks a font before writing anything and refuses damaged files, files that aren't fonts, and static CFF fonts, with the reason.
- **MobileGestalt:** a change stops before writing when a backup could not be saved first.
- **Passcode Style:** an imported backup is only accepted when it is a real PNG image.
- **Location Simulator:** changing its settings no longer starts a full run by itself on A18 / M4.
- **Sources:** a default source you removed stays removed after an app update.

## Fixed

- **SnowBoard Lite on iOS 26** ([#22](https://github.com/kolbicz/Cyanide/issues/22)): icons shown in the App Library came back unthemed after swiping back to the Home Screen, for up to 30 seconds. The page is now re-themed as soon as it changes.
- **Plist editor:** no more crash when opening files written by apps as keyed archives; their references show as read-only values.
- **Plist editor:** Revert from inside a nested entry returns to the top of the reloaded file instead of showing old values.
- **File Browser:** saving a plain text file that happens to look like a property list (a UUID, a hostname, `key = value;`) no longer rewrites it as XML.
- **File Browser:** large images open downsampled instead of running out of memory.
- **iPad:** the NSBar position, weather language and NiceBar slot menus no longer crash.
- **Themes from `.deb` files:** files with paths longer than 100 characters are no longer dropped or misnamed.
- **Cache Cleaner:** Review Folders shows the real path of items you added, the confirmation lists them with their sizes, and the Select All label matches what it selects.
- **Call Recording Sound:** an already silenced sound is no longer saved as the "original" backup.
- **Watch Pairing Override:** an unreadable settings file is no longer treated as "no override".
- **Tendies:** a wallpaper that could not be removed stays in the list.
- **Runs:** a run requested while another one is active keeps its own scope, and no longer resets the automatic retry limit.
- **Runs:** the screen is allowed to sleep again when a second run is refused.
- **FastLockX Lite:** its background time is given back when it expires.
- **Sources:** a refresh replaced by a newer one is no longer reported as failed, and a tweak replaced by another no longer shows a phantom update.
- **Check for Updates:** the "Checking…" message can no longer get stuck on screen.
- **Package options:** typing into a text option no longer closes the keyboard after every character.
- **QuickLoader:** gray and white colours are saved correctly instead of as black, and colour pickers no longer stack up.
- **Wallet Card Art:** shows its result or error message.
- **Log:** a log that ends in the middle of a character opens instead of showing nothing.
- **NiceBar Lite:** Traffic History shows the recorded days instead of zeros.

## Faster and smaller

- Settings and package lists scroll and reload faster.
- The File Browser lists large folders faster.
- After a run, the log is written to disk less often, and a long session log is trimmed to its last 4 MB.
- Screens you close (package details, the install queue, QuickLoader options) are released from memory.
- The app no longer ships an unused library.

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
