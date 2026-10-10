//
//  LocationServicesControl.swift
//  CyanideControls
//
//  A Control Center toggle for Location Services. It shows the real state
//  (read with CLLocationManager, which needs no entitlement); tapping it runs
//  SetLocationServicesIntent, which opens Cyanide to do the actual switch.
//  Cyanide asks Control Center to refresh this control afterwards.
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
