## Supported devices

**iPhone and iPad running iOS/iPadOS 17.0 – 18.7.1, or 26.0 – 26.0.1.**

| | |
| --- | --- |
| ✅ Supported | iOS/iPadOS **17.0 – 18.7.1** |
| ✅ Supported | iOS/iPadOS **26.0 – 26.0.1** |
| ❌ Not supported | iOS 16.x and earlier, **18.7.2 – 25.x**, **26.1 and later** |
| ❌ Not supported | **iPhone 17 family (A19 / A19 Pro)** and **M5** — Memory Integrity Enforcement blocks the exploit |

**iOS 15 and 16 are out of scope by choice, not by limitation.** Every device on
those versions is jailbreakable with
[Dopamine](https://github.com/opa334/Dopamine), so Cyanide has nothing to add —
use that instead.

iOS 17 is deliberately supported in full, including versions a jailbreak already
covers. Coverage there depends on the device, and Cyanide does not jailbreak the
device at all: tweaks are applied in memory for the current boot, so apps that
refuse to run on a jailbroken device are unaffected.

Any iPhone or iPad on a supported version should work, including A-series and
M-series iPads. There is no separate device whitelist: Cyanide checks the
iOS version and finds its kernel offsets by scanning, so hardware from older
A-series through A18 is handled by the same code.

Confirmed working on iPhone 16 Pro Max (iOS 18.5), iPhone 15 Pro Max
(iOS 17.3.1) and M-series iPad.

> **Note:** these devices are refused up front by model identifier
> (`iPhone18,x` and above, `iPad17,x` and above), so you get a clear message
> rather than a failed exploit.

## Tweaks

Installed from the in-app Installer. Everything is applied in memory for the
current boot — nothing is written to the filesystem, and a respring undoes it.

### Home Screen

| Tweak | What it does |
| --- | --- |
| **SBCustomizer** | Custom dock, grid, app placement, and page counts |
| **Home Layout Extras** | Extra home/dock padding and per-icon scaling |
| **Gravity Lite** | Make home-screen icons fall with physics |
| **Hide Home Bar** | Hide the bottom home indicator |

### SpringBoard

| Tweak | What it does |
| --- | --- |
| **Axon Lite** | Group Notification Center requests by app |
| **App Switcher Grid** | Grid-style app switcher |
| **QuickLoader** | Executes custom .js code |
| **Disable App Library** | Remove the App Library page |
| **Disable Icon Fly-In** | Skip the icon spring animation |
| **Zero Wake Animation** | Snap on instantly when waking |
| **Zero Backlight Fade** | Instant lock/unlock backlight |
| **Double-Tap to Lock** | Lock with a wallpaper double-tap |
| **Drag Coefficient** | Custom SpringBoard animation speed multiplier |

### Status Bar

| Tweak | What it does |
| --- | --- |
| **StatBar** | Battery temperature + free RAM overlay |
| **NSBar** | Network speed overlay in the status bar |
| **NiceBar Lite** | NiceBar-style status labels |

### Theming

| Tweak | What it does |
| --- | --- |
| **SnowBoard Lite** | Local SnowBoard-style icon themes |
| **LiveWP** | Video wallpaper for Home and Lock Screen |

### System

| Tweak | What it does |
| --- | --- |
| **Powercuff** | Underclock the CPU/GPU thermal pressure |
| **Location Simulator** | CoreLocation static point simulation |
| **Watch Pairing Override** | Pair a newer watch or revive an older one |
| **Call Recording Sound** | Silence disclosure start/stop sounds |
| **OTA Updates** | Enable or disable over-the-air system updates |

### Beta

| Tweak | What it does |
| --- | --- |
| **Dynamic Stage Lite** | Two floating app windows, iPad-style |
| **FastLockX Lite** | Face ID retry + unlock controls |

## Options

Under **Settings → Launch Options**:

| Option | |
| --- | --- |
| **A18 exploit path** | `pe_v1` (default) or `pe_v2` (fallback). A18/M4 only. |
| **Tweak apply speed** | Compatible / Fast / Fastest. Higher settings cut the delay paid between the remote calls that apply a tweak. |
| **Auto-run kexploit on launch** | Get kernel read/write as soon as Cyanide opens. |
| **Sandbox escape** | Run the sandbox escape demo. |
| **Keep app alive in background** | Needed by tweaks that keep running while Cyanide is backgrounded. |

Each tweak has its own section in Settings once installed.

## Project status

This repository is a fork of
[`zeroxjf/cyanide`](https://github.com/zeroxjf/cyanide), maintained by
[Kolbicz](https://github.com/kolbicz). Maintenance is focused primarily on
Kolbicz-based tweaks. No other changes are planned, and support is not provided
for tweaks that are not maintained by Kolbicz.

The original Cyanide project is no longer maintained by `zeroxjf`. Anyone may
fork this repository and continue development in accordance with the license.
The original authors and upstream projects remain credited below.

The old README is preserved below for historical context and build details.
Some of its information may be outdated.

<details>
<summary>Archived project README</summary>

<p align="center">
  <img src="https://raw.githubusercontent.com/kolbicz/cyanide/main/Cyanide/Assets.xcassets/AppIcon.appiconset/icon-ios-1024x1024.png" alt="Cyanide" width="160">
</p>

<h1 align="center">Cyanide</h1>

**By [@zeroxjf](https://github.com/zeroxjf)** — an iOS tweak runner built on top of the DarkSword kernel r/w primitive.

Cyanide is a fork of [`wh1te4ever/darksword-kexploit-fun`](https://github.com/wh1te4ever/darksword-kexploit-fun)
for iOS kernel research. It wraps the native DarkSword kernel stages in an
Objective-C iOS app, restructures the UI as an Installer/Settings split, and
adds a few reliability fixes for repeated local testing. It does not ship
the browser-delivered WebKit/dyld parts of the original DarkSword chain.

## Project Status

As of v1.3.6, Patreon integration has been removed. All installable Cyanide
tweaks are free and no tweak access depends on account linking.

Previously unreleased work-in-progress tweak code has been opened under the
same AGPL-3.0 license as the rest of the project. Some unfinished entries remain
visible in the app so contributors can find them, but installation stays
disabled until someone finishes and verifies them.

`zeroxjf` is stepping away from active Cyanide development. The code is now
open under AGPL-3.0 so anyone can fork it, study it, reuse it, or continue it
under the license terms.

## Install

Open this page on your iPhone/iPad and tap one of the buttons below.

<p align="center">
  <a href="https://celloserenity.github.io/altdirect/?url=https://raw.githubusercontent.com/kolbicz/cyanide/main/source.json" target="_blank">
    <img src="https://github.com/CelloSerenity/altdirect/blob/main/assets/png/AltSource_Blue.png?raw=true" alt="Add AltSource" width="200">
  </a>
  <a href="https://github.com/kolbicz/cyanide/releases/latest" target="_blank">
    <img src="https://github.com/CelloSerenity/altdirect/blob/main/assets/png/Download_Blue.png?raw=true" alt="Download .ipa" width="200">
  </a>
</p>

## Feedback

- [Report a bug](https://github.com/kolbicz/cyanide/issues/new?template=bug_report.yml)
- [Request a feature](https://github.com/kolbicz/cyanide/issues/new?template=feature_request.yml)

## Beta Tweaks

Beta tweaks are free and visible without account linking. They are unstable and
intended for testers who are comfortable with SpringBoard glitches, crashes, or
partial behavior.

## Tweaks

These tweaks have been tested on iOS 18.x and 26.x. Expect version drift in
SpringBoard and related daemons to break things on other releases.

### Status Bar

- **StatBar**: battery temperature and free-RAM overlay anchored to the
  SpringBoard status bar, with optional C/F and network-speed display.
- **NSBar**: compact live download/upload speed overlay for the status bar,
  with selectable corner/center positions. Ported from
  [`d1y/cyanide-ios`](https://github.com/d1y/cyanide-ios).
- **NiceBar Lite**: configurable status-bar-adjacent labels for custom text,
  date/time formats, battery, memory, traffic, uptime, IP address, disk,
  thermal state, and other live readouts. Ported from
  [`d1y/cyanide-ios`](https://github.com/d1y/cyanide-ios).

### Home Screen Layout

- **SBCustomizer**: dock icon count, home-screen columns/rows, and hidden icon
  labels.
- **Home Layout Extras**: extra padding around the home grid and dock, plus
  per-icon scale for home and dock icons. Stacks on top of SBCustomizer.

### Performance

- **Powercuff**: CPU/GPU underclocking through simulated `thermalmonitord`
  pressure levels (off, nominal, light, moderate, heavy). Lasts until reboot.
  Port of [`rpetrich/Powercuff`](https://github.com/rpetrich/Powercuff).

### SpringBoard Tweaks

Ported from [`kolbicz/DarkSword-Tweaks`](https://github.com/kolbicz/DarkSword-Tweaks):

- **Disable App Library**: removes the App Library page past the last home screen.
- **Disable Icon Fly-In**: skips the spring-in animation when icons appear.
- **Zero Wake Animation**: snaps the display on instantly when waking.
- **Zero Backlight Fade**: instant lock/unlock backlight.
- **Double-Tap to Lock**: lock the device with a wallpaper double-tap.

### System Updates

- **Disable OTA Updates**: toggles the launchd OTA `disabled.plist` to block or
  unblock update prompts. Persists across reboots.

### Beta

> ⚠︎ Work in progress — these may crash SpringBoard, glitch layout, work only
> partially, or need re-applying between builds.

- **Gravity Lite**: core port of Julio Verne's classic Gravity tweak. Applies
  UIDynamicAnimator physics to home-screen and dock icons — gravity, collisions,
  bounce, friction, accelerometer steering, shake pulses, and an explosion
  button. Use Restore Icon Layout if icons stay displaced after deactivating.
- **Axon Lite**: groups Notification Center requests by app with a SpringBoard
  overlay and dedups duplicates while the RemoteCall session is alive.
- **Dynamic Stage Lite**: brings Stage Manager-style split-view to iPhone over
  RemoteCall — no jailbreak required. Hosts a second app's scene alongside
  SpringBoard using the same scene-hosting design as [`tomt000`'s Dynamic Stage](https://havoc.app/package/dynamicstage).
- **FastLockX Lite**: keeps Face ID retry/unlock requests armed through
  SpringBoard timers so pickup-to-unlock can work after Cyanide closes.
- **Cyanide Themer**: per-bundle icon theme engine. Walks SpringBoard's
  SBIconView hierarchy and swaps each icon's image with a PNG matched on bundle
  ID. Ships with iOS 6 Theme; also accepts a custom folder of `<bundleID>.png`
  files or a binary plist. Pick a theme in Settings before running.
- **SnowBoard Lite**: imports SnowBoard/IconBundles-style theme folders or
  archives into Cyanide's local theme library, then applies the selected theme
  through the existing icon replacement pipeline. Ported from
  [`d1y/cyanide-ios`](https://github.com/d1y/cyanide-ios).
- **LiveWP**: copies a selected MP4/MOV/M4V into Cyanide's app container and
  plays it behind SpringBoard's home and lock screen windows while the live
  RemoteCall session is active. Ported from
  [`d1y/cyanide-ios`](https://github.com/d1y/cyanide-ios).
- **Watch Pairing Override**: edits the watchOS pairing range stored on the
  iPhone so you can pair a newer Apple Watch or revive an older one. Persists
  across reboots; respring before pairing.
- **Location Simulator**: drives Apple's CoreLocation simulation path from a
  RemoteCall host process and sets a static target coordinate. Simulated
  locations may violate app terms, platform rules, game rules, ride-share or
  delivery policies, or local law depending on how they are used. Use only where
  you have permission; you are responsible for your use and apply or restore it
  at your own risk. It may also affect location-tied system behavior such as
  time zone/date/time handling and can have unintended consequences; only use it
  if you know what you're doing. Credits: `kolbicz` provided the
  RemoteCall/CLSimulationManager GPS spoofer prototype, and `ezzuldinSt`'s
  LSpoof provided the app-side spoofing, picker, bookmarks, and route-simulation
  reference.
- **Call Recording Sound**: replaces the CallServices
  `StartDisclosureWithTone` and `StopDisclosure` audio files with Cyanide's
  bundled silent payloads, with separate Silence and Restore actions. Cyanide
  backs up the first originals into its app container before replacement, but
  this is still a persistent system-file edit under
  `/var/mobile/Library/CallServices/Greetings/default`. Disclosure sounds may be
  legally required where you live; you are responsible for your use and should
  restore the originals before removing Cyanide if you want Cyanide's backups
  written back. Credits: `YangJiiii` (`@duongduong0908`) for the EnsWilde and
  Disable Call Recording BookRestore reference tools, and `@Little_34306` as
  credited by the original projects for the Disable Call Recording concept.

### In Development

> These entries are visible but not installable because they do not work yet.
> Their app/source paths are left in place so someone can pick them up later.

- **Signal Readouts**: unfinished status-bar numeric signal readouts.
- **TypeBanner**: unfinished iMessage typing banner experiment.
- **Notification Island**: unfinished Dynamic Island notification mirror.
- **IPA Decryptor**: unfinished local IPA decryptor workflow.

## Supported Targets

Tested target range:

- iOS/iPadOS 17.0 through 18.7.1
- iOS/iPadOS 26.0 through 26.0.1
- A19/M5 devices are not supported

The kernel bugs used here, `CVE-2025-43510` and `CVE-2025-43520`, were fixed in
iOS/iPadOS 18.7.2 and 26.1. Later builds are outside this kernel exploit window.

## What This Fork Changes

- Cleans shared exploit state before each attempt.
- Matches the target process with an explicit marker.
- Validates sockets before using the spray path.
- Treats missed races as retryable failures instead of hard failures.
- Tightens the A18/M4 `pe_v2` path with initialized target-file contents,
  stable local remap addresses, bounded page freeing, socket-spray preflight
  checks, and controlled zone-trim retries.

## Kernel Research Features

- Escape the app sandbox.
- Control or crash userspace processes from the app.
- Change UID, GID, and sticky bits on target files.
- Disable ASLR by setting `P_DISABLE_ASLR` in `launchd`'s `proc->p_flag`.

## Credits

- [`opa334`](https://github.com/opa334): original [`darksword-kexploit`](https://github.com/opa334/darksword-kexploit), ChOma, and XPF — the kernel r/w primitive Cyanide is built on.
- [`wh1te4ever`](https://github.com/wh1te4ever): [`kfun` / `darksword-kexploit-fun`](https://github.com/wh1te4ever/darksword-kexploit-fun) — the RemoteCall implementation that lets a sideloaded app apply tweaks inside SpringBoard. Cyanide is a fork of this project.
- [`rooootdev`](https://github.com/rooootdev): working kexploit behavior used to stabilize this fork.
- [`neonmodder123`](https://github.com/neonmodder123): Web Respring method.
- [`kolbicz`](https://github.com/kolbicz): OTA Disabler, SpringBoard tweaks, and
  the RemoteCall/CLSimulationManager GPS spoofer prototype used as the starting
  point for Location Simulator.
- `ezzuldinSt`: LSpoof app-side `CLLocationManager` spoofing, picker,
  bookmarks, and route-simulation reference used while shaping Location
  Simulator.
- `YangJiiii` (`@duongduong0908`): EnsWilde and Disable Call Recording
  BookRestore reference tools used while shaping Call Recording Sound.
- `@Little_34306`: credited by the original call-recording projects for the
  Disable Call Recording concept.
- [`rpetrich`](https://github.com/rpetrich): Powercuff.
- [Julio Verne](https://github.com/julioverne): the original [Gravity](https://github.com/julioverne/Gravity) tweak that Gravity Lite is a core port of.
- [`d1y`](https://x.com/chenhonzhou): [`cyanide-ios`](https://github.com/d1y/cyanide-ios)
  AGPL-3.0 sources used for the NSBar, NiceBar Lite, SnowBoard Lite, and
  LiveWP ports.
- [`tomt000`](https://github.com/tomt000): [Dynamic Stage](https://havoc.app/package/dynamicstage) — the original Stage Manager-for-iPhone tweak whose split-view + scene-hosting design Dynamic Stage Lite re-implements over RemoteCall.

### UI inspiration

- The classic [Installer.app](https://github.com/AppTapp/Installer-3) (Ripdev & Nullriver Software, now maintained by AppTapp and the Legacy Jailbreak community) — the iPhoneOS 1 package-manager look that the Cyanide Installer tab is modeled after.
- The [Sileo Project](https://github.com/Sileo/Sileo) (the Sileo Team) — the queue → review → confirm install flow and the bottom queue-popup pattern.

## Build

```sh
./scripts/build.sh
```

The build script uses the `Cyanide` scheme, disables code signing, and writes
an unsigned IPA to:

```text
build/Cyanide.ipa
```

Equivalent manual build:

```sh
xcodebuild \
  -project Cyanide.xcodeproj \
  -scheme Cyanide \
  -sdk iphoneos \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## License

This repository is licensed under **AGPL-3.0**. See `LICENSE`.

The NSBar, NiceBar Lite, SnowBoard Lite, and LiveWP ports adapt AGPL-3.0 code
from [`d1y/cyanide-ios`](https://github.com/d1y/cyanide-ios) and remain in the
AGPL-covered tree.

## JavaScript Tweaks

Cyanide includes two JavaScript tweak runners contributed by Iggy05:

- **QuickLoader** imports a local `.js` file from Files and exposes declared
  `@param` values as settings rows.
- **RepoTweaks Store** imports HTTPS JSON repositories and downloads selected
  JavaScript tweaks from those sources. Cyanide seeds MinePlayer16's source at
  `https://raw.githubusercontent.com/MinePlayer16/MinePlayer16.github.io/refs/heads/main/repotweaks.json`
  by default.

Only run scripts and repositories you trust; JavaScript tweaks can call Cyanide
RemoteCall helpers and may destabilize SpringBoard if the script is buggy.


</details>
