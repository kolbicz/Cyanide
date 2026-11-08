//
//  PowerControls.swift
//  CyanideControls
//
//  Control Center buttons for Respring and Reboot (iOS 18+). A respring or
//  reboot has no on/off state to show, so these are buttons rather than
//  toggles. Tapping one opens Cyanide, which runs the request at once.
//

import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct RespringControl: ControlWidget {
    static let kind = "com.zeroxjf.ios-cyanide1.controls.respring"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: RespringIntent()) {
                Label("Respring", systemImage: "arrow.clockwise.circle.fill")
            }
        }
        .displayName("Respring")
        .description("Restarts SpringBoard through Cyanide.")
    }
}

@available(iOS 18.0, *)
struct RebootControl: ControlWidget {
    static let kind = "com.zeroxjf.ios-cyanide1.controls.reboot"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: RebootIntent()) {
                Label("Reboot", systemImage: "power.circle.fill")
            }
        }
        .displayName("Reboot")
        .description("Reboots the device through Cyanide. Needs kernel access from an earlier run.")
    }
}
