> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.21.0

Clean what an app leaves behind, and get back to your folders faster.

## New

- **Your own folders and files in the Cache Cleaner** ([#18](https://github.com/kolbicz/Cyanide/issues/18)): in the File Browser, long-press a folder or file inside an app's data and choose **Add to Cache Cleaner**. Instagram, for example, keeps uploaded videos in `Library/Application Support/Instagram/VideoUpload` long after they're posted.
  - When adding one, choose **Always Select** (selected after every scan and by Select All, like caches) or **Select by Hand** (you pick it each time). Long-press it in the Cache Cleaner under **Added by You** to switch **Select Automatically** later.
  - A folder is emptied (the folder itself stays), a file is deleted. Skipped while the app is running, like caches.
  - Only add what the app can do without: anything it keeps there (drafts, downloads, logins) is gone once cleaned.
  - Only items under the app's Library, Documents or tmp can be added, not those folders themselves and not the app's settings.
  - Saved per app, so it keeps working when the app moves to a new container. Long-press it in the Cache Cleaner to take it off the list.
- **Favorites and Recent in the File Browser:** ••• → **Add to Favorites** for the current folder (or long-press a folder), then open it from ••• → **Favorites**. ••• → **Recent** lists the last 15 folders you opened.

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
