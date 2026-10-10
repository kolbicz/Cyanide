//
//  ControlReloader.swift
//  Cyanide
//
//  Lets the Objective-C side ask Control Center to refresh Cyanide's
//  controls after their state changed (ControlCenter is Swift-only).
//

import Foundation
import WidgetKit

@objc(CYControlReloader)
final class CYControlReloader: NSObject {
    // Must match LocationServicesControl.kind in the CyanideControls extension.
    private static let locationKind = "com.zeroxjf.ios-cyanide1.controls.location"

    @objc static func reloadLocationControl() {
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: locationKind)
        }
    }
}
