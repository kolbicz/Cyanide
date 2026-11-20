//
//  PowerActionIntents.swift
//  CyanideControls + Cyanide
//
//  Respring and Reboot actions for Shortcuts, Siri, the Action button and
//  the Control Center buttons (PowerControls.swift). Compiled into both the
//  extension and the app: with openAppWhenRun, iOS opens Cyanide and runs
//  perform() there, which hands the request to the same handler as the
//  cyanide://respring and cyanide://reboot links. Unlike those links, these
//  need no setting: iOS only runs them for the user's own shortcuts and
//  controls.
//

import AppIntents

struct RespringIntent: AppIntent {
    static let title: LocalizedStringResource = "Respring"
    static let description = IntentDescription("Opens Cyanide to restart SpringBoard. Live tweaks stop first.")
    static let openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await CyanideLocationRequest.runURL("cyanide://respring",
                                                timeoutMessage: "The respring is taking longer than expected.")
        return .result()
    }
}

struct RebootIntent: AppIntent {
    static let title: LocalizedStringResource = "Reboot"
    static let description = IntentDescription("Opens Cyanide to reboot the device. Needs kernel access from an earlier Cyanide run.")
    static let openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await CyanideLocationRequest.runURL("cyanide://reboot",
                                                timeoutMessage: "The reboot is taking longer than expected.")
        return .result()
    }
}

// CarPlay without Siri: lifts iOS 18's "To use CarPlay, enable Siri" lock-out
// for the current connection. Meant for a "When CarPlay connects" automation
// in Shortcuts, or the Control Center button. The tweak must be on in
// Cyanide, and kernel access from an earlier run must be live or parked.
struct UnlockCarPlayIntent: AppIntent {
    static let title: LocalizedStringResource = "CarPlay without Siri"
    static let description = IntentDescription("Opens Cyanide to let CarPlay start while Siri is off, for the current connection.")
    static let openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await CyanideLocationRequest.runURL("cyanide://carplay",
                                                timeoutMessage: "CarPlay is taking longer than expected.")
        return .result()
    }
}
