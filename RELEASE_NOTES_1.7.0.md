# Cyanide 1.7.0

**New: Process Viewer.** A live look at everything running on your device — and the ability to end it.

## New

- **Process Viewer** (Settings → Process Viewer). A live process list, à la CocoaTop:
  - Every running process with CPU and memory, live-refreshing.
  - A count of **active vs suspended** processes at the top.
  - Suspended (parked) apps are **dimmed**, and apps currently in the App Switcher are **marked**, so you can see what's really doing work.
  - **Kill a process** — a gentle *Quit* (SIGTERM) or a *Force Quit* (SIGKILL). Sandboxed apps that your own process can't signal are terminated through a privileged path, so Force Quit lands on anything.
  - Works on iOS 17 and iOS 18.

  > **Why a Force Quit takes a moment.** The first kill shows a spinner for a second or two while Cyanide sets up a privileged kernel session. Further kills in the same sitting are quick.

## Improvements

- **The kernel read/write primitive now survives backgrounding and sleep.** When you leave Cyanide it hands the primitive to the system and re-attaches on return, so re-opening recovers in a couple of seconds instead of re-running the full exploit chain.
- The log is quieter — the verbose RemoteCall internals are kept out of it. If you hit an issue worth reporting, turn on **Settings → Process Viewer → Verbose logging** before reproducing it, then share the log: that restores the full detail we need to look into it.

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
