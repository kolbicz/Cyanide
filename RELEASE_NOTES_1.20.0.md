> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.20.0

See where your storage goes: Folder Size now shows the largest folders and files.

## New

- **Largest Items** ([#18](https://github.com/kolbicz/Cyanide/issues/18)): in the File Browser, **Size of This Folder** (••• or long-press a folder) now opens a breakdown instead of a summary.
  - The folder's contents, largest first, with each one's share of the total. Tap a folder to measure the next level down.
  - The 25 largest files anywhere inside it. Tap one to open its folder.
  - **Copy** puts the result on the clipboard, ready to paste into an issue.
  - Turn on **Root Access** in ••• first so folders only root can read are counted too.

## Fixes

- **Clearer warnings before deleting.** A large file isn't necessarily safe to remove: much of the space belongs to iOS, and deleting the wrong file can leave the device unable to start up, which only a full restore fixes. The Largest Items screen, turning on write mode and the Delete confirmation (outside an app's own data) now say so.
- **Folder sizes and copies.** Copies of a file made on the device can share their storage, and each is counted in full, so deleting one may free less than its size. Largest Items notes this.

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
