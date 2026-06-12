// AccessibilityPermission.swift
// RightClickPasteKing
//
// Thin wrapper around the Accessibility trust API. A CGEventTap that
// listens to mouse events system-wide requires the process to be trusted
// for Accessibility, so we check/request it here.

import ApplicationServices

enum AccessibilityPermission {

    /// True if this process is currently trusted for Accessibility.
    /// Does not prompt.
    static var isGranted: Bool {
        return AXIsProcessTrusted()
    }

    /// Returns true if already granted. If not granted, shows the standard
    /// system prompt that adds the app to the Accessibility list and points
    /// the user at System Settings, then returns false (the grant happens
    /// asynchronously after the user acts).
    @discardableResult
    static func requestIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options: CFDictionary = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
