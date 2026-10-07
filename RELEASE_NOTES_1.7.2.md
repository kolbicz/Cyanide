# Cyanide 1.7.2

A faster, more accurate Process Viewer.

## Improvements

- **Much faster refreshes.** Reading the process list used to take a few seconds and now takes a few milliseconds. The list keeps up with a 1-second auto-refresh, and the viewer puts far less load on the kernel session.
- **CPU % now works on every launch.** Before, the CPU column was often blank or stuck at 0.0%, and some processes never got a value. Now every process gets a reading.
- **CPU % is accurate.** Busy background services (Spotlight indexing, mail and others, especially while charging) now show their real load instead of almost nothing. 100% means one full core, so a busy multi-threaded process can go above 100%, up to 600% on a 6-core chip. The rows add up to the "CPU: X% busy" figure in the header, which counts all cores as 100%.

## Fixes

- Refreshes no longer overlap. Overlapping refreshes could briefly show an older list after a newer one, or a wrong CPU %.
- Tapping Force Quit on a second app while the first kill is still starting no longer freezes the screen.
- Auto-refresh now waits until every Force Quit in progress has finished before it resumes.
- Fixed a rare case where the check that blocks quitting critical processes (SpringBoard, backboardd, launchd) could read the wrong process name.
- Fixed a possible crash when a process name contains unusual characters.
- Extra safety checks on iOS 17 and later when reading details of processes that are just exiting.

## Good to know

- The CPU column fills in from the second refresh on, because it measures the change between two refreshes.
- If a process starts or ends threads between two refreshes, it can show 0.0% for that one refresh.

## About A18 / M4

On A18 / M4 devices a run has about a 50/50 chance of rebooting the device (a
kernel "panic") instead of succeeding — a known limit of these chips that can't
be fully fixed. It's a coin flip, so if it reboots, just try again; a few
attempts usually gets there. Once a run works, it stays working until your next
restart.

If you keep hitting panics, Settings → Launch Options has four knobs for the
A18 chain — exploit path (pe_v1 / pe_v2), memory shaping, interleaved search
and bounded search. Defaults are unchanged in this release; other combinations
may do better on your device. Each applies to the next fresh run.
