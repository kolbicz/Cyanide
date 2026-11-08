> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.17.0

Notification previews for Face ID-locked apps, tweaks applied and undone one at a time, and Respring / Reboot from Shortcuts and Control Center.

## New

- **Locked App Previews** (Installer → SpringBoard): apps locked with "Require Face ID" (iOS 18) show their notification content again, following the normal preview setting (Always, When Unlocked or Never). Opening a locked app still asks for Face ID. The setting is saved by iOS and stays after a respring; turning the tweak off hides the previews again.
- **Apply Installer changes right away** (Settings → Launch Options, on by default): with saved kernel access, activating or deactivating a tweak applies just that tweak at once instead of adding it to the queue. Without kernel access, and for OTA, Hide Home Bar and repo tweaks, the queue works as before.
- **Apply Now**: a tweak waiting to be applied again (after reopening Cyanide or a respring) can be applied by itself from its page.
- **Respring and Reboot outside Cyanide**:
  - Shortcuts / Siri / Action button actions (iOS 17 and later).
  - Control Center buttons (iOS 18).
  - `cyanide://respring` and `cyanide://reboot` links, off by default: turn on Settings → Launch Options → Respring and reboot links. Any app can open these links; the Shortcuts actions and Control Center buttons don't need the option.
  - A progress screen like the Location Services toggle's shows each step instead of Cyanide's Home tab.
  - Reboot needs kernel access from an earlier run.

## Fixes

- **DarkSword tweaks can be turned off** without a respring: Disable App Library, Disable Icon Fly-In, Hide New App Dots, Zero Wake Animation, Zero Backlight Fade, Double Tap to Lock and Drag Coefficient now put back what they changed.
- **Tweaks are remembered after closing Cyanide**: tweaks that stay in SpringBoard by themselves no longer show up as "Activation pending" after reopening Cyanide, and are no longer all applied again with the next one. They show as pending again only after a respring or reboot.
- **iPad Dock** can be turned off after Cyanide was closed and reopened (it needed a respring before).
- **Log window** no longer goes black during a run (the text came back only after scrolling).

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
