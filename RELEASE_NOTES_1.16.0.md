> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.16.0

Supervised mode, Gravity Lite without the Installer, and live tweaks in the background again.

## New

- **Supervision** (Settings → System → Supervision): Activate marks the device as supervised, with "Cyanide" as the organization, so configuration profiles with supervised-only restrictions can be installed. Only the flag is set: no device management is involved and nothing is restricted by itself.
  - Takes effect right away (reopen Settings) and persists across reboots.
  - Deactivate puts the previous state back. A device supervised by a real organization is left alone.
- **Gravity Lite** now has Activate / Deactivate buttons on its Settings page and is no longer an Installer package. A full exploit run is only offered when there is no saved kernel access.

## Fixes

- **Live tweaks run in the background again**: Gravity Lite, StatBar, NSBar, NiceBar Lite, Axon Lite and LiveWP keep updating while Cyanide is in the background (needs "Keep app alive in background", on by default).
- **Location Services control** (Control Center / Shortcuts): switching it while a live tweak runs no longer crashes SpringBoard.
- **iPad Dock with SBCustomizer's extra Dock icons** ([#12](https://github.com/kolbicz/Cyanide/issues/12)): the iPad Dock is resized after SBCustomizer changes the Dock, so an extra icon is no longer squeezed in at the left edge.

## Removed

- **Sandbox escape** launch option. The File Browser, Cache Cleaner, System Info and the Lara tools lift the sandbox themselves when opened, so runs no longer spend a step on it.

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
