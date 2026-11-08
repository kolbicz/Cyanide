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
