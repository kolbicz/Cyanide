> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.31.0

Fixes for the install queue, CarPlay without Siri and Arrange Pages.

## Fixed

- **Re-apply button (↻ in Packages):** it now also appears after reopening Cyanide, and puts every applied tweak back in the queue, including the ones still active from an earlier session. Before, those could only be applied again after a respring.
- **CarPlay without Siri in the queue:** it no longer stays pending forever. Before, the queue never emptied, applying it did nothing, and removing the package made the whole queue (with its Already Active list) disappear. Adding the package now goes through the queue once like any other: with a car connected it also lifts the Siri lock-out, otherwise it is simply turned on. The Control Center button, the Shortcuts action and `cyanide://carplay` still lift it for each connection.
- **Arrange Pages (SBCustomizer):** apps that iOS places in a page's free row between runs no longer push the following icons forward and mix up your order. Cyanide remembers which page each app was on and puts them back there.

## Improved

- **Arrange Pages:** the Log names any app that came onto or left the Home Screen since the last arrange.

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
