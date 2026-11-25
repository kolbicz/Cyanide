> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.40.0

Cyanide in 14 languages, and decrypted IPAs with their own bundle ID.

## New

- **Languages (Settings → About → Language, #24):** Cyanide is now available in Simplified Chinese, German, French, Spanish, Italian, Japanese, Korean, Polish, Portuguese (Brazil), Russian, Thai, Turkish, Vietnamese and Arabic. By default it follows the system language; restart Cyanide after changing it.
- **Control Center and Shortcuts in your language:** the Location Services, Respring, Reboot and CarPlay without Siri controls and actions, including their error messages, follow the system language.
- **App Decrypt with a custom bundle ID (#16):** when decrypting, you can enter a new bundle ID (e.g. `com.example.app`) to install the IPA next to the original app. The app's extensions and Watch app get matching IDs. The IPA is saved as `…_decrypted_custom.ipa` and must be re-signed for the new ID before installing. Leave the field empty to keep the original ID.

## Fixed

- **Cache Cleaner on iOS 26:** the Clean button is no longer hidden behind the tab bar (#26).
