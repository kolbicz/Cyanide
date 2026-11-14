> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.18.0

A MobileGestalt editor for device features, and folder sizes in the File Browser.

## New

- **MobileGestalt** (Settings → Lara → MobileGestalt, [#17](https://github.com/kolbicz/Cyanide/issues/17)): switches device features on or off by editing iOS's cached device answers. Ported from lara by rooootdev with his permission; keys from Nugget by leminlimez and SparseBox by khanhduytran0.
  - **Features:** Dynamic Island, Always-On Display, charge limit, boot chime, Camera Control and Action Button settings, Apple Intelligence, region restrictions, iPadOS apps and Stage Manager, internal flags and more. Features this device already has are marked as built in.
  - **Remove China Restrictions (Experimental):** for mainland China models (FaceTime Audio, eSIM and others). Idea and values from GestaltX by huamidev.
  - **Screen shape, model name and model** can be changed too.
  - **Apply Changes** saves the switches you changed; **Discard Changes** drops them.
  - **Safe to undo:** turning a switch off puts the original value back, every save keeps a dated backup first, and **Restore Original…** puts the file back as it was. **All Keys** lists the cached values and can share the current and original files.
  - Respring to see the changes; some only show after a restart.
- **Folder Size** (File Browser: long-press a folder, or ••• → **Size of This Folder**): the size on disk, the size of the data and the number of files and folders. It runs in the background and can be cancelled. With Root Access on, folders only root can read are included.

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
