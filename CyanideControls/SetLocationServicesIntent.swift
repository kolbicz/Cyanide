//
//  SetLocationServicesIntent.swift
//  CyanideControls + Cyanide
//
//  The Control Center toggle's action. Compiled into BOTH the extension and
//  the app: with openAppWhenRun, iOS launches Cyanide and runs perform() in
//  the app process, where it hands the request to the same handler as the
//  cyanide://location-services URLs (quiet progress screen, return to Home).
//

import AppIntents
import Foundation

@available(iOS 18.0, *)
struct SetLocationServicesIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Location Services"
    static let description = IntentDescription("Opens Cyanide to turn Location Services on or off.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Location Services On")
    var value: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        // App-side handler (SceneDelegate +cy_runLocationURL:). Looked up at
        // run time: the class only exists in the app, not in the extension.
        let url = URL(string: "cyanide://location-services/\(value ? "on" : "off")")! as NSURL
        let selector = NSSelectorFromString("cy_runLocationURL:")
        if let handler = NSClassFromString("SceneDelegate") as? NSObject.Type,
           handler.responds(to: selector) {
            handler.perform(selector, with: url)
        }
        return .result()
    }
}
