# Cyanide 1.7.3

Faster tweaks, fewer reboots on A18 / M4, and a run that recovers on its own.

## Improvements

- **Tweaks apply much faster.** Applying the Home Screen tweaks used to spend most of its time waiting. On an iPhone 16 Pro Max, the DarkSword tweaks (App Library, icon fly-in, wake animation, backlight fade, double-tap to lock) went from about 1.7 seconds to about 0.3, and SBCustomizer's page arranging went from about 2.2 seconds to 1.4. Hide Labels, Dock Labels and the icon resize in Home Layout Extras are faster too.
- **See what Apply is doing.** The progress screen now shows the current step instead of only a spinner, for example "Resizing icons: page 3 of 7".
- **Auto-retry failed runs.** New in Settings → Launch Options: when the exploit misses, Cyanide can start the next attempt by itself until it works or reaches the attempt limit you set (1–20, default 8). Off by default. Each attempt carries the same small chance of a reboot, so the limit caps how many you take per tap.
- **Run Again button.** When a run fails to get kernel access, the progress screen offers Run Again right there.
- **Repo sources switch.** Settings → Launch Options → Repo sources turns the whole repo feature off: the Sources tab, repo packages, background refreshes and repo tweaks. Local QuickLoader `.js` files keep working.
- **New default tweak source.** The previous default source is offline. Cyanide now uses MinePlayer16's repository (MinePlayer16 / Iggy05). Tweaks you installed from the old source move over with their settings.

## A18 / M4: fewer reboots

- **New pe_v3 exploit path.** It stops before the steps most likely to reboot the device and starts a clean new attempt instead. In testing it got kernel access on about half of its attempts. On first launch, Cyanide asks once whether you want to switch to it. You can change this any time in Settings → Launch Options → A18 exploit path.
- **Less waiting on attempts that can't succeed.** pe_v3 now spots attempts that won't land and moves on to the next one right away instead of waiting about a minute.

## Fixes

- If the injection into SpringBoard gets stuck, Cyanide now notices, makes the device safe and offers a Restart Cyanide button instead of hanging. A new diagnostic option, "Controlled panic on injection wedge", restarts the device right away with a clearly labelled panic log, for bug reports.
- Process Viewer: a process that couldn't be checked is no longer shown as gone, and a Quit or Force Quit that failed is no longer reported as successful.
- Process Viewer: fixed a rare way reading a process's CPU usage could reboot the device while one of its threads was exiting.
- Process Viewer: after a failed Force Quit, the background helper it uses now shuts down after 10 idle seconds, as it already did after a successful one.
- Process Viewer: fixed CPU % sometimes using the wrong source after re-calibrating.
- Process Viewer: fixed a small resource leak on every refresh.
- Fixed Cyanide closing itself when a kernel access failed. It now skips that access safely and carries on.
- Fixed a crash when importing a damaged or malicious ZIP theme.

## Good to know

- On A18 / M4, a run can still reboot the device instead of succeeding. That's a limit of these chips that can't be fully fixed, but pe_v3 makes it less likely. If it reboots, just run again. Once a run works, it keeps working until your next restart.
- The A18 exploit path tabs are now simply "pe_v1 (default)", "pe_v2" and "pe_v3".
