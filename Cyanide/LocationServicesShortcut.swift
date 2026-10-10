//
//  LocationServicesShortcut.swift
//  Cyanide
//
//  "Location Services" action for Shortcuts, Siri and the Action button,
//  iOS 17+ (custom Control Center controls need iOS 18; this is the iOS 17
//  way to reach the same switch). Opens Cyanide and runs the same request as
//  the Control Center toggle (CyanideLocationRequest, shared with the
//  CyanideControls extension). Lives only in the app target: the App
//  Shortcut below must be provided by the app, not the extension.
//

import AppIntents

enum LocationServicesAction: String, AppEnum {
    case toggle
    case on
    case off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Location Services Action"
    static let caseDisplayRepresentations: [LocationServicesAction: DisplayRepresentation] = [
        .toggle: "Toggle",
        .on: "Turn On",
        .off: "Turn Off",
    ]
}

struct LocationServicesShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Location Services"
    static let description = IntentDescription("Opens Cyanide to turn Location Services on, off, or toggle it.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Action", default: .toggle)
    var action: LocationServicesAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) Location Services")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await CyanideLocationRequest.run(action.rawValue)
        return .result()
    }
}

// Shows the action in the Shortcuts app without any setup, and makes it
// available to Siri and the Action button.
struct CyanideAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LocationServicesShortcutIntent(),
            phrases: [
                "Toggle Location Services with \(.applicationName)",
                "\(.applicationName) Location Services",
            ],
            shortTitle: "Location Services",
            systemImageName: "location.fill"
        )
    }
}
