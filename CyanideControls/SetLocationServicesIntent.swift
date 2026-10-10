//
//  SetLocationServicesIntent.swift
//  CyanideControls + Cyanide
//
//  The Control Center toggle's action (iOS 18+) and the request logic it
//  shares with the Shortcuts action (iOS 17+). Compiled into BOTH the extension and
//  the app: with openAppWhenRun, iOS launches Cyanide and runs perform() in
//  the app process, where it hands the request to the same handler as the
//  cyanide://location-services URLs (quiet progress screen, return to Home)
//  and waits for the outcome, so Control Center reads the new state when
//  perform() returns.
//

import AppIntents
import Foundation

// The request itself, shared by the Control Center toggle (iOS 18+) and the
// Shortcuts action in the app (LocationServicesShortcut.swift, iOS 17+). Runs
// in the app process (both intents use openAppWhenRun) and hands the request
// to the same handler as the cyanide://location-services URLs, then waits for
// the real outcome.
struct CyanideLocationRequestFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

enum CyanideLocationRequest {
    @MainActor
    private final class Resolver {
        var continuation: CheckedContinuation<(ok: Bool, message: String), Never>?
        var timeout: Task<Void, Never>?

        func finish(_ ok: Bool, _ message: String) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            continuation.resume(returning: (ok, message))
        }
    }

    // A cold run without parked kernel access can take ~20 s; past this the
    // intent stops waiting (Cyanide still finishes and refreshes the control).
    private static let timeout: TimeInterval = 60

    /// action: "on", "off" or "toggle".
    @MainActor
    static func run(_ action: String) async throws {
        // App-side handler (SceneDelegate +cy_runLocationURL:completion:).
        // Looked up at run time: the class only exists in the app.
        let url = URL(string: "cyanide://location-services/\(action)")! as NSURL
        let selector = NSSelectorFromString("cy_runLocationURL:completion:")
        guard let handler = NSClassFromString("SceneDelegate") as? NSObject.Type,
              handler.responds(to: selector) else {
            throw CyanideLocationRequestFailure(message: "Cyanide couldn't take the request.")
        }
        // One-shot: the first of completion, timeout or cancellation wins;
        // the others are ignored. Cancellation only detaches the caller —
        // Cyanide finishes the change safely and refreshes the control.
        let resolver = Resolver()
        let outcome: (ok: Bool, message: String) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resolver.continuation = continuation
                let completion: @convention(block) (Bool, NSString) -> Void = { ok, message in
                    MainActor.assumeIsolated { resolver.finish(ok, message as String) }
                }
                handler.perform(selector, with: url, with: completion as AnyObject)
                guard resolver.continuation != nil else { return }   // already answered
                resolver.timeout = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
                    if Task.isCancelled { return }
                    resolver.finish(false, "Location Services is taking longer than expected.")
                }
                if Task.isCancelled { resolver.finish(false, "Cancelled.") }
            }
        } onCancel: {
            Task { @MainActor in resolver.finish(false, "Cancelled.") }
        }
        guard outcome.ok else { throw CyanideLocationRequestFailure(message: outcome.message) }
    }
}

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
        try await CyanideLocationRequest.run(value ? "on" : "off")
        return .result()
    }
}
