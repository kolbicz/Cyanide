# Cyanide 1.8.0

A File Browser, a Location Services switch for Control Center and Shortcuts, and a long list of safety fixes.

## New

- **File Browser.** Browse the file system, view files and edit plists right on the device. Editing is off until you turn on write mode. Read-only root access (through launchd) is a separate option, also off by default. Every save keeps a backup, and a save that couldn't finish is reported instead of leaving a half-written file. You can share files up to 64 MB.
- **No write access as root, on purpose.** Root access is read-only. This isn't a technical limit: writing to system files as root is one of the easiest ways to leave a device unable to boot, so Cyanide doesn't offer it.
- **Location Services toggle for Control Center (iOS 18).** Turns Location Services on or off from Control Center. Cyanide opens with a small progress screen and goes back to where you were when it's done.
- **Location Services action for Shortcuts (iOS 17+).** The same switch as a Shortcuts action (Toggle, Turn On, Turn Off), also usable from Siri and the Action button.
- **Location Services links.** `cyanide://location-services/on`, `/off` and `/toggle` for your own automations. Off by default, because any app can open a link: turn them on in Settings → Launch Options → Location Services links.
- **Tools on the Home tab.** Process Viewer and File Browser are now one tap away.

## How the Location Services switch behaves

- It needs kernel access from an earlier run. It never starts a full exploit run on its own; after a restart, open Cyanide and run it once first.
- If the switch had to open Cyanide, Cyanide removes itself from the App Switcher afterwards. If Cyanide was already open, or live tweaks are running, it stays.

## Improvements

- **Process Viewer:** more accurate CPU usage. Force Quit checks that the row is still the same process before acting. The list shows when it stops updating.
- **Importing passcode originals** now runs in the background with a progress alert and a Cancel button.
- **Sources:** the refresh banner now says when some sources failed. Error details appear only when you refresh yourself, not at every launch.
- **Removing a repo package or deleting a source** now also stops its running script.
- **Log upload:** only the most recent part of the log is sent, and paths to your own files and data are removed first.

## Fixes

- Fixed a SpringBoard crash (respring) that could follow using the File Browser after the Process Viewer.
- Importing a damaged ZIP or `.deb` now fails as a whole instead of leaving half-imported files behind.
- SBCustomizer, Home Layout Extras and the DarkSword tweaks stop safely when SpringBoard doesn't answer, instead of guessing and possibly applying a change twice. Their status now only reports changes SpringBoard confirmed.
- Double Tap to Lock can no longer end up installed twice.
- Axon can no longer show a notification twice after switching apps in its filter.
- Many more places in the kernel access code now stop safely when a read or write fails, instead of continuing with bad data. That kind of failure is what can reboot the device.

## Good to know

> [!CAUTION]
> **You're responsible for your changes.** Editing files with the File Browser is at your own risk. We can't take responsibility for changes you make that break iOS, your apps or your data. Keep a backup before editing anything you aren't sure about.


- On A18 / M4, a run can still reboot the device instead of succeeding. pe_v3 (Settings → Launch Options → A18 exploit path) makes this less likely.
