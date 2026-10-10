//
//  LocationServicesControl.swift
//  CyanideControls
//
//  A Control Center toggle for Location Services. It shows the real state
//  (read with CLLocationManager, which needs no entitlement) and, when
//  tapped, opens Cyanide's location shortcut URL — Cyanide does the actual
//  switch and asks Control Center to refresh this control afterwards.
//

import AppIntents
import CoreLocation
import SwiftUI
import WidgetKit

@main
struct CyanideControlsBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 18.0, *) {
            LocationServicesControl()
        }
    }
}

@available(iOS 18.0, *)
struct LocationServicesControl: ControlWidget {
    // Must match the kind Cyanide reloads after a change (CYControlReloader).
    static let kind = "com.zeroxjf.ios-cyanide1.controls.location"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isOn in
            ControlWidgetToggle("Location Services", isOn: isOn, action: SetLocationServicesIntent()) { on in
                Label(on ? "On" : "Off", systemImage: on ? "location.fill" : "location.slash.fill")
            }
            .tint(.blue)
        }
        .displayName("Location Services")
        .description("Turns Location Services on or off through Cyanide.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }

        func currentValue() async throws -> Bool {
            CLLocationManager.locationServicesEnabled()
        }
    }
}

// Flipping the toggle opens Cyanide with the matching URL; the quiet
// progress screen does the work and returns to the Home Screen.
@available(iOS 18.0, *)
struct SetLocationServicesIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Location Services"
    static let description = IntentDescription("Opens Cyanide to turn Location Services on or off.")

    @Parameter(title: "Location Services On")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        let url = URL(string: "cyanide://location-services/\(value ? "on" : "off")")!
        return .result(opensIntent: OpenURLIntent(url))
    }
}
