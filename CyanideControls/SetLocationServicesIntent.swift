//
//  SetLocationServicesIntent.swift
//  CyanideControls + Cyanide
//
//  The Control Center toggle's action. Compiled into BOTH the extension and
//  the app: with openAppWhenRun, iOS launches Cyanide and runs perform() in
//  the app process, where it hands the request to the same handler as the
//  cyanide://location-services URLs (quiet progress screen, return to Home)
//  and waits for the outcome, so Control Center reads the new state when
//  perform() returns.
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

    struct Failure: Error, CustomLocalizedStringResourceConvertible {
        let message: String
        var localizedStringResource: LocalizedStringResource { "\(message)" }
    }

    // A cold run without parked kernel access can take ~20 s; past this the
    // intent stops waiting (Cyanide still finishes and refreshes the control).
    private static let timeout: TimeInterval = 60

    @MainActor
    func perform() async throws -> some IntentResult {
        // App-side handler (SceneDelegate +cy_runLocationURL:completion:).
        // Looked up at run time: the class only exists in the app.
        let url = URL(string: "cyanide://location-services/\(value ? "on" : "off")")! as NSURL
        let selector = NSSelectorFromString("cy_runLocationURL:completion:")
        guard let handler = NSClassFromString("SceneDelegate") as? NSObject.Type,
              handler.responds(to: selector) else {
            throw Failure(message: "Cyanide couldn't take the request.")
        }
        let outcome: (ok: Bool, message: String) = await withCheckedContinuation { continuation in
            var resumed = false   // main actor only
            let finish = { (ok: Bool, message: String) in
                if resumed { return }
                resumed = true
                continuation.resume(returning: (ok, message))
            }
            let completion: @convention(block) (Bool, NSString) -> Void = { ok, message in
                MainActor.assumeIsolated { finish(ok, message as String) }
            }
            handler.perform(selector, with: url, with: completion as AnyObject)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) {
                MainActor.assumeIsolated {
                    finish(false, "Location Services is taking longer than expected.")
                }
            }
        }
        guard outcome.ok else { throw Failure(message: outcome.message) }
        return .result()
    }
}
