# Release Notes

Keep concrete, user-facing release bullets here as changes land. The release
script reads `## Pending` before building, uses those bullets for GitHub release
notes and the generated in-app changelog, then moves them under `## Released`
after a successful build.

Good bullets describe the behavior users will notice:

- Reduced flicker when Dynamic Stage windows resize.
- Fixed installer queue badges after changing package selection.
- Added an iOS 17 fallback for Disable App Library.

Use one bullet per user-facing tweak or fix. Do not combine unrelated tweak
changes into the same bullet.

Avoid vague bullets like "Update settings", "Change project files", or
"Misc fixes".

It is OK to mention user-visible beta or experimental tweaks when describing
added or improved features. Credit original tweak or project authors alongside
the Cyanide port author when known. Do not mention experimental source movement,
non-public repository names, non-public implementation details, or commentary
about which experimental pieces are working versus not wired. If the change
cannot be phrased as a user-facing feature or fix without revealing internal
activity, omit it.

## Pending


## Released

### v1.9.0 - 2026-10-19

- [x] New Daemons screen: turn system services off and on, staged and written on Save, with each daemon's process and PID.
- [x] New System Info screen: device, uptime, kernel access, battery health and storage per app.
- [x] New Reboot button next to Respring in Quick Actions.
- [x] Faster respring: SpringBoard is asked to restart itself, with the old method as fallback.
- [x] The Location Services toggle returns to the app it was run from, or to the Home Screen; run inside Cyanide, it stays.
- [x] File Browser shows app names and icons for container folders, with a jump between bundle and data.
- [x] What's New is shown again in Settings, with Show Less at the top.
- [x] Tweaks report when a change couldn't be confirmed instead of "applied".
- [x] Turning off a DarkSword patch offers a respring; it stays active until then.
- [x] A tweak removed from its source is stopped and uninstalled; an out-of-date repo script no longer runs.
- [x] A failed theme apply keeps the current theme.
- [x] Safer imports: size limits while reading, no clearing of folders with content, changed files rejected.
- [x] pe_v3 is the default A18/M4 path, with checks after every hunt.

### v1.8.0 - 2026-10-10

- [x] New File Browser: browse files, view them and edit plists. Write mode is optional and off by default; every save keeps a backup.
- [x] Root access in the File Browser is read-only on purpose: writing system files as root can leave a device unable to boot.
- [x] Editing files is at your own risk: we can't take responsibility for changes that break iOS, apps or data.
- [x] New Location Services toggle for Control Center (iOS 18).
- [x] New Location Services action for Shortcuts, Siri and the Action button (iOS 17+).
- [x] Location Services links (cyanide://location-services/on, /off, /toggle), off by default: Settings → Launch Options.
- [x] The Location Services switch needs kernel access from an earlier run and never starts a full exploit run itself.
- [x] Cyanide only removes itself from the App Switcher if the switch opened it; it stays when it was open or live tweaks run.
- [x] Tools card on the Home tab for Process Viewer and File Browser.
- [x] Process Viewer: more accurate CPU usage, and Force Quit checks it is still the same process.
- [x] Importing passcode originals runs in the background with progress and Cancel.
- [x] Sources: the refresh banner says when some sources failed; details only when you refresh yourself.
- [x] Removing a repo package or deleting a source also stops its running script.
- [x] Log upload sends only the recent part of the log, without paths to your own files.
- [x] Fixed a respring that could follow using the File Browser after the Process Viewer.
- [x] A damaged ZIP or .deb now fails as a whole instead of leaving half-imported files.
- [x] SBCustomizer, Home Layout Extras and DarkSword tweaks stop safely when SpringBoard doesn't answer instead of applying twice.
- [x] Double Tap to Lock can no longer be installed twice; Axon can no longer show a notification twice.
- [x] More kernel access paths stop safely when a read or write fails, instead of risking a reboot.

### v1.7.3 - 2026-10-09

- [x] Tweaks apply much faster. Applying the Home Screen tweaks used to spend most of its time waiting. On an iPhone 16 Pro Max, the DarkSword tweaks (App Library, icon fly-in, wake animation, backlight fade, double-tap to lock) went from about 1.7 seconds to about 0.3, and SBCustomizer's page arranging went from about 2.2 seconds to 1.4. Hide Labels, Dock Labels and the icon resize in Home Layout Extras are faster too.
- [x] See what Apply is doing. The progress screen now shows the current step instead of only a spinner, for example "Resizing icons: page 3 of 7".
- [x] Auto-retry failed runs. New in Settings → Launch Options: when the exploit misses, Cyanide can start the next attempt by itself until it works or reaches the attempt limit you set (1–20, default 8). Off by default. Each attempt carries the same small chance of a reboot, so the limit caps how many you take per tap.
- [x] Run Again button. When a run fails to get kernel access, the progress screen offers Run Again right there.
- [x] Repo sources switch. Settings → Launch Options → Repo sources turns the whole repo feature off: the Sources tab, repo packages, background refreshes and repo tweaks. Local QuickLoader .js files keep working.
- [x] New default tweak source. The previous default source is offline. Cyanide now uses MinePlayer16's repository (MinePlayer16 / Iggy05). Tweaks you installed from the old source move over with their settings.
- [x] New pe_v3 exploit path. It stops before the steps most likely to reboot the device and starts a clean new attempt instead. In testing it got kernel access on about half of its attempts. On first launch, Cyanide asks once whether you want to switch to it. You can change this any time in Settings → Launch Options → A18 exploit path.
- [x] Less waiting on attempts that can't succeed. pe_v3 now spots attempts that won't land and moves on to the next one right away instead of waiting about a minute.
- [x] If the injection into SpringBoard gets stuck, Cyanide now notices, makes the device safe and offers a Restart Cyanide button instead of hanging. A new diagnostic option, "Controlled panic on injection wedge", restarts the device right away with a clearly labelled panic log, for bug reports.
- [x] Process Viewer: a process that couldn't be checked is no longer shown as gone, and a Force Quit that failed is no longer reported as successful.
- [x] Process Viewer: fixed a rare way reading a process's CPU usage could reboot the device while one of its threads was exiting.
- [x] Process Viewer: after a failed Force Quit, the background helper it uses now shuts down after 10 idle seconds, as it already did after a successful one.
- [x] Process Viewer: fixed CPU % sometimes using the wrong source after re-calibrating.
- [x] Process Viewer: fixed a small resource leak on every refresh.
- [x] Fixed Cyanide closing itself when a kernel access failed. It now skips that access safely and carries on.
- [x] Fixed a crash when importing a damaged or malicious ZIP theme.

### v1.7.2 - 2026-10-07

- [x] Much faster refreshes. Reading the process list used to take a few seconds and now takes a few milliseconds. The list keeps up with a 1-second auto-refresh, and the viewer puts far less load on the kernel session.
- [x] CPU % now works on every launch. Before, the CPU column was often blank or stuck at 0.0%, and some processes never got a value. Now every process gets a reading.
- [x] CPU % is accurate. Busy background services (Spotlight indexing, mail and others, especially while charging) now show their real load instead of almost nothing. 100% means one full core, so a busy multi-threaded process can go above 100%, up to 600% on a 6-core chip. The rows add up to the "CPU: X% busy" figure in the header, which counts all cores as 100%.
- [x] Refreshes no longer overlap. Overlapping refreshes could briefly show an older list after a newer one, or a wrong CPU %.
- [x] Tapping Force Quit on a second app while the first kill is still starting no longer freezes the screen.
- [x] Auto-refresh now waits until every Force Quit in progress has finished before it resumes.
- [x] Fixed a rare case where the check that blocks quitting critical processes (SpringBoard, backboardd, launchd) could read the wrong process name.
- [x] Fixed a possible crash when a process name contains unusual characters.
- [x] Extra safety checks on iOS 17 and later when reading details of processes that are just exiting.

### v1.7.1 - 2026-10-05

- [x] Fixed the main cause of a black screen on launch after using the Process Viewer. If you still hit one, please report it with a log.
- [x] The large title no longer shrinks and re-centers when you open the viewer.
- [x] The list no longer jumps down when the process count appears.
- [x] Force Quit starts faster, and the first kill's "finishing kill" banner now sits at the top and only shows for that first, slower kill — no more flicker on quick ones.
- [x] Cyanide now releases the privileged session on its own about ten seconds after a kill.
- [x] Verbose logging moved to Settings → Launch Options (it now also covers exploit runs and tweak applies, and it sticks across launches).

### v1.7.0 - 2026-10-05

- [x] New Process Viewer (Settings → Process Viewer): every running process with live CPU and memory, and Force Quit.
- [x] The kernel read/write primitive now survives backgrounding and sleep. When you leave Cyanide it hands the primitive to the system and re-attaches on return, so re-opening recovers in a couple of seconds instead of re-running the full exploit chain.
- [x] The log is quieter — the verbose RemoteCall internals are kept out of it. If you hit an issue worth reporting, turn on Settings → Process Viewer → Verbose logging before reproducing it, then share the log: that restores the full detail we need to look into it.

### v1.3.6 - 2026-06-27

- [x] Removed Patreon integration and ungated all installable Cyanide tweaks, with stale account-linking state cleared so beta access is the same for everyone.
- [x] Patreon note: tweaks previously gated behind the $3/month tier are now free, $3/month members will receive refunds, and the $10/month Researcher tier is being lowered to $7/month with partial refunds for members who already paid.
- [x] Made in-development tweaks visible but disabled, with notes that their unfinished source remains for future contributors.

### v1.3.5 - 2026-06-24

- [x] Fixed repo tweak update badges so failed installs no longer clear available updates.
- [x] Repo tweak updates now stay as badges until you tap Update, instead of automatically entering the install queue.
- [x] Fixed repo tweak queue rows showing a redundant QuickLoader prefix before the tweak name.
- [x] Made repo tweak updates obvious in the Packages list with an Update Available label and badge.
- [x] Repo tweaks can now declare iOS compatibility limits, with unsupported packages blocked while already-installed ones remain removable.
- [x] Fixed installed source tweaks still appearing as queued through their QuickLoader/native backing package after install.
- [x] Fixed source update badges lingering after installing an update until the source was refreshed again.
- [x] Fixed removing an installed source tweak so Apply Tweaks actually runs the cleanup path instead of only clearing package metadata.
- [x] Reorganized package categories into Status Bar, Home Screen, Theming, SpringBoard, System, and JavaScript Tweaks.
- [x] Fixed section headers shifting horizontally during scroll.

### v1.3.4 - 2026-06-24

- [x] Fixed the queue popup staying visible after Apply Tweaks completes.

### v1.3.3 - 2026-06-24

- [x] Repo tweak detail view now shows the actual tweak description instead of generic install text.
- [x] Cleaned up tweak detail view styling — larger, more readable description and info text.
- [x] Source refresh on update forces repo cache repopulation so per-tweak icons and authors appear immediately.
- [x] Package icon badges now cycle through a spectrum of colors across all list views.

### v1.3.2 - 2026-06-24

- [x] Redesigned Home, Packages, and Sources tabs with a unified visual style — gradient hero, colored icon badges, bold section headers, and compact list cells.
- [x] Packages tab now shows a Recently Added section for new source tweaks and a flat alphabetical package list; category browser moved to Sources.
- [x] Added per-tweak SF Symbol icons and per-tweak author to the repo JSON format.
- [x] Added pull-to-refresh on Packages and Sources, with a green success banner after refresh.
- [x] QuickLoader opened from Home or Sources now runs tweaks directly without going through the install queue.
- [x] Fixed repo tweaks showing both QuickLoader and the tweak itself in the queue and installed package lists.
- [x] Updated JS tweak repo documentation with the new symbol and author optional fields.

### v1.3.1 - 2026-06-24

- [x] Improved QuickLoader UI with loaded tweak display, active status indicator, clear button, and prominent activate button.
- [x] Made the install queue show the loaded QuickLoader script name instead of a generic label.
- [x] Restored Hide Home Bar's stable page-zero path, forced cache-busted repo script fetches before QuickLoader installs, and prompts for respring after repo-served Hide Home Bar runs.
- [x] Fixed Location Simulator coordinate entry for Chinese labels, directions, and full-width punctuation.
- [x] Fixed SnowBoard Lite only applying some visible icons on iOS 26.
- [x] Improved SnowBoard Lite live repair by reusing the SpringBoard channel between ticks and backing off background repair work that could make SpringBoard feel slow.
- [x] Blocked SnowBoard Lite activation until a theme is selected, with a shortcut to open theme settings.
- [x] Made Hide Home Bar stay registered as hidden after respring, with Restore shown as the next package action.

### v1.2.23 - 2026-06-23

- [x] Added a Home tab with What's New, JavaScript Tweaks and RemoteCall Tweaks overviews, and community links.
- [x] Redesigned Packages as a category browser — tap a category to see its tweaks.
- [x] Added JavaScript tweak support by @MinePlayer16: QuickLoader for local .js files and an online Sources tab for HTTPS repos, with the zeroxjf repo (including Hide Dock) pre-installed.
- [x] Added developer documentation in the Sources tab for writing JS tweaks and setting up a repo, with copy and share options.
- [x] Added automatic source refresh with update detection badges on the Sources tab.
- [x] Fixed JS runner stalls, SBCustomizer queue/apply issues, SnowBoard Lite respring delays, and kernel setup hangs on IOSurface mapping failures. Not all reported bugs are addressed yet, but this update should bring more stability overall.

### v1.2.22 - 2026-06-12

- [x] Made FastLockX Lite install through the normal Apply Tweaks queue so it uses the shared SpringBoard setup with other runtime tweaks.
- [x] Paused FastLockX Lite retry pulses while the device is unlocked.
- [x] Improved Hide Home Bar page zeroing stability with a DirtyZero-style single-page write path and verified fallback.
- [x] Improved kernel setup stability when preparing the memory-racing stage.
- [x] Improved FastLockX Lite compatibility with Dynamic Stage Lite by finishing FastLockX setup before Dynamic Stage starts its live control loop.
- [x] Fixed FastLockX Lite not resuming its retry pulse after the device locks on iOS 18.
- [x] Prevented Dynamic Stage Lite from background-filling App Library tiles while FastLockX Lite is active to avoid SpringBoard restarts.
- [x] Fixed Dynamic Stage Lite windows being torn down when the device locks or the screen sleeps.
- [x] Improved FastLockX Lite unlock reliability by debouncing lock-screen timer sync and using no-wake unlock nudges when Face ID leaves the lock screen awake.

### v1.2.21 - 2026-06-12

- [x] Split SnowBoard Lite import into separate Folder and Archive (ZIP/DEB) options so archive imports work reliably on all sideloaded installs.
- [x] Added a hint in the folder import dialog for sideloaded users whose signing tool needs "Match provisioning identifier" enabled.

### v1.2.20 - 2026-06-12

- [x] Fixed SBCustomizer showing as still queued after a successful icon-label or layout apply.
- [x] Fixed unsupported-version runs leaving the Activity sheet stuck in a running state.
- [x] Fixed local builds failing on macOS Bash when no simulator-only xcodebuild extras are set.
- [x] Fixed SnowBoard Lite imports on Signulous installs by copying selected themes into Cyanide instead of opening them in place.

### v1.2.19 - 2026-06-11

- [x] Added FastLockX Lite, available to Patrons for early access, as an experimental tool that automatically unlocks the screen once Face ID is accepted; tested on iOS 18 and iOS 26, with iOS 17 support not confirmed yet. Credits: original FastLockX author Artem Kasper and Cyanide port by zeroxjf.
- [x] Fixed a Patreon linking crash when returning from the in-app OAuth flow.

### v1.2.18 - 2026-06-11

- [x] Tightened Hide Home Bar standalone queue enforcement across all package actions.
- [x] Added iOS 17 support for Drag Coefficient and lowered its minimum value to 0.01.
- [x] Replaced Home Layout Extras sliders with exact number entry rows.

### v1.2.17 - 2026-06-09

- [x] Added Hide Home Bar as a beta package using DirtyZero-style MaterialKit page zeroing.
- [x] Made Hide Home Bar run as a standalone queue item with prominent install-queue guidance.
- [x] Added public Hide Home Bar credits in the package details.
- [x] Added a respring prompt after Hide Home Bar finishes so users know when the home indicator will disappear.
- [x] Fixed a queue review crash when pending changes finish while the queue screen is refreshing.
- [x] Reduced Dynamic Stage Lite picker startup work to avoid SpringBoard resprings on large app libraries.

### v1.2.16 - 2026-06-09

- [x] Prevented overlapping tweak actions from interfering with Apply Tweaks and direct controls.
- [x] Fixed Dynamic Stage Lite sidebar interference with the main tweak UI.

### v1.2.15 - 2026-06-09

- [x] Fixed Double Tap to Lock triggering while entering a Lock Screen passcode.
- [x] Added App Switcher Grid as a Beta tweak.
- [x] Replaced the installer contact button with Signal group and GitHub Issues links.
- [x] Removed the standalone Cyanide Themer listing in favor of SnowBoard Lite.
- [x] Let active Location Simulator target changes use parked kernel recovery before refreshing.
- [x] Kept OTA Block behind kernel recovery before editing launchd job state.
- [x] Kept Call Recording Sound behind kernel recovery before writing CallServices files.
- [x] Kept Watch Pairing override behind kernel recovery before writing NanoRegistry files.

### v1.2.14 - 2026-06-09

- [x] Fixed Dynamic Stage Lite visibility for paid users.
- [x] Fixed LiveWP video selection from Files and added Photos video selection.
- [x] Let active LiveWP users change videos from the installer without deactivating the wallpaper first.
- [x] Prevented LiveWP activation until a valid video has been selected.

### v1.2.13 - 2026-06-08

- [x] Moved Location Simulator to Beta and into the public app tree so it is available without enabling Experimental Tweaks.
- [x] Moved Call Recording Sound to Beta and into the public app tree so it is available without enabling Experimental Tweaks.

### v1.2.12 - 2026-06-08

- [x] Fixed Location Simulator exact coordinate entry so pasted decimal pairs and compass-suffix coordinates are normalized correctly.

### v1.2.11 - 2026-06-07

- [x] Added an optional simulator build path that uses a simulator XPF dylib without changing the normal device IPA build.
- [x] Added a StatBar option to show only live network upload and download speed.
- [x] Fixed the installer queue popup crash on iPadOS when the tab bar is attached after launch.
- [x] Fixed StatBar landscape placement on iPad by sizing the overlay from SpringBoard's active window bounds.
- [x] Fixed custom theme bundle-ID PNGs not preloading for apps that are only visible inside folders.
- [x] Prevented Dynamic Stage Lite and Cyanide Themer live icon repair from running together to avoid SpringBoard resprings.

### v1.2.10 - 2026-06-05

- [x] Updated the Cyanide Signal group invite link.

### v1.2.9 - 2026-06-05

- [x] Fixed NiceBar Lite weather slots by restoring the location-based weather picker, cache, and live refresh flow.

### v1.2.8 - 2026-06-05

- [x] Fixed LiveWP disappearing after leaving Cyanide and aligned NSBar/NiceBar Lite refresh loops with screen wake and sleep state.

### v1.2.7 - 2026-06-05

- [x] Fixed the Installer queue popup overlapping the bottom tab bar on iOS 18.

### v1.2.6 - 2026-06-05

- [x] Fixed LiveWP video changes stopping after one run and SnowBoard Lite icon themes drawing over rounded icon corners.

### v1.2.5 - 2026-06-05

- [x] Replaced the first-launch log collection notice with a Cyanide Signal group invite for feedback, feature requests, and support.
- [x] Added NSBar, NiceBar Lite, SnowBoard Lite, and LiveWP ports from d1y/cyanide-ios, with Settings controls and Installer package credits.
- [x] Allowed public Cyanide checkouts to build without optional experimental tweak sources.

### v1.2.4 - 2026-06-03

- [x] Added a StatBar refresh-rate setting and reduced battery use from repeated temperature polling.
- [x] Fixed Installer queue edge cases so no-op applies finish cleanly and pending activations are remembered after reopening Cyanide.

### v1.2.3 - 2026-06-03

- [x] Improved Gravity Lite startup on iOS 17 by using the faster live-icon capture path.
- [x] Fixed a recent tweak startup regression that could hang while opening the SpringBoard injection channel on A16+ iPhones.
- [x] Fixed Installer package state so successfully applied SpringBoard tweaks no longer appear stuck as activation pending.

### v1.2.2 - 2026-06-03

- [x] Fixed kernel panic on A16+/M-series iPads by guarding the t1sz_boot override so the PAC mask uses the correct value.

### v1.2.1 - 2026-06-03

- [x] Added Drag Coefficient tweak — custom SpringBoard animation speed multiplier ported from kolbicz/DarkSword-Tweaks, with a 5–200% slider (50% = 2× faster, 100% = stock).

### v1.2.0 - 2026-06-03

- [x] Added Gravity Lite with home screen and dock icon physics, tilt control, widget support, and iOS 18/26 compatibility.
- [x] Polished installer, settings, and log presentation with clearer status text, cleaner startup branding, and a maintained release-notes workflow.
- [x] Improved tweak activation and cleanup so unchanged tweaks are not reapplied unnecessarily and SpringBoard-backed tweaks deactivate more reliably.

### v1.1.22 - 2026-06-02

- [x] Reduced flicker when Dynamic Stage windows resize by staging new scene hosts and retiring old hosts after the remote layer has populated.
- [x] Added stronger transition shielding around Dynamic Stage app open, close, and apply paths.
- [x] Tracked DarkSword toggle apply results independently in Settings.
- [x] Improved Disable App Library handling with an iOS 17 fallback path.
- [x] Refined installer queue, badges, and activity status UI.
- [x] Tightened Log tab typography for dense verbose traces.
- [x] Updated the release script to capture dirty submodule changes before committing and tagging the parent release.
