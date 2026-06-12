// L10n.swift
// RightClickPasteKing
//
// Central table of user-facing strings. Every visible string in the app
// goes through here so localization lives in one place; the translations
// themselves are in Resources/<lang>.lproj/Localizable.strings.
//
// The app/brand name "RightClickPasteKing" is intentionally NOT localized.

import Foundation

enum L10n {

    // MARK: - Menu

    static let menuEnabled = NSLocalizedString(
        "menu.enabled", comment: "Menu: master on/off toggle")
    static let menuClearAfterPaste = NSLocalizedString(
        "menu.clearAfterPaste", comment: "Menu: clear clipboard after paste toggle")
    static let menuClearAfterPasteTooltip = NSLocalizedString(
        "menu.clearAfterPaste.tooltip", comment: "Tooltip explaining the clear-after-paste side effect")
    static let menuTintIcon = NSLocalizedString(
        "menu.tintIcon", comment: "Menu: tint the status icon purple while the clipboard has text")
    static let menuAccessibilityChecking = NSLocalizedString(
        "menu.accessibility.checking", comment: "Menu: permission status while checking")
    static let menuAccessibilityGranted = NSLocalizedString(
        "menu.accessibility.granted", comment: "Menu: permission granted status")
    static let menuAccessibilityRequired = NSLocalizedString(
        "menu.accessibility.required", comment: "Menu: permission missing and required")
    static let menuAccessibilityNotGranted = NSLocalizedString(
        "menu.accessibility.notGranted", comment: "Menu: permission missing, feature disabled")
    static let menuOpenAccessibility = NSLocalizedString(
        "menu.openAccessibility", comment: "Menu: open Accessibility settings")
    static let menuSetupGuide = NSLocalizedString(
        "menu.setupGuide", comment: "Menu: reopen the setup guide")
    static let menuLaunchAtLogin = NSLocalizedString(
        "menu.launchAtLogin", comment: "Menu: launch at login toggle")
    static let menuQuit = NSLocalizedString(
        "menu.quit", comment: "Menu: quit the app")
    static let menuRecentCopies = NSLocalizedString(
        "menu.recentCopies", comment: "Menu: recent copies submenu title")
    static let menuRecentCopiesEmpty = NSLocalizedString(
        "menu.recentCopies.empty", comment: "Recent copies submenu: empty state")
    static let menuRecentCopiesClear = NSLocalizedString(
        "menu.recentCopies.clear", comment: "Recent copies submenu: clear history")
    static let menuCheckForUpdates = NSLocalizedString(
        "menu.checkForUpdates", comment: "Menu: check for app updates via Sparkle")

    // MARK: - Status item tooltips

    static let tooltipActive = NSLocalizedString(
        "tooltip.active", comment: "Status item tooltip: running")
    static let tooltipNeedsPermission = NSLocalizedString(
        "tooltip.needsPermission", comment: "Status item tooltip: permission missing")
    static let tooltipDisabled = NSLocalizedString(
        "tooltip.disabled", comment: "Status item tooltip: user disabled")

    // MARK: - Alerts

    /// Format: %@ = underlying error description.
    static let alertLoginItemErrorFormat = NSLocalizedString(
        "alert.loginItemError", comment: "Alert: launch-at-login change failed; %@ is the error")

    // MARK: - Setup guide

    static let guideExplainTitleWelcome = NSLocalizedString(
        "guide.explain.title.welcome", comment: "Guide page 1 title on first run")
    static let guideExplainTitleReference = NSLocalizedString(
        "guide.explain.title.reference", comment: "Guide page 1 title when reopened as reference")
    static let guideExplainBody = NSLocalizedString(
        "guide.explain.body", comment: "Guide page 1: behavior rules (multi-line, bullets)")
    static let guideExplainSecondary = NSLocalizedString(
        "guide.explain.secondary", comment: "Guide page 1: disclosure of on-by-default settings")
    static let guideButtonContinue = NSLocalizedString(
        "guide.button.continue", comment: "Guide: continue button")
    static let guideButtonDone = NSLocalizedString(
        "guide.button.done", comment: "Guide: done button")
    static let guidePermissionTitle = NSLocalizedString(
        "guide.permission.title", comment: "Guide page 2 title")
    static let guidePermissionBody = NSLocalizedString(
        "guide.permission.body", comment: "Guide page 2: why the permission is needed")
    static let guidePermissionSecondary = NSLocalizedString(
        "guide.permission.secondary", comment: "Guide page 2: how to grant (toggle or drag)")
    static let guidePermissionButton = NSLocalizedString(
        "guide.permission.button", comment: "Guide page 2: open settings button")
    static let guidePermissionWaiting = NSLocalizedString(
        "guide.permission.waiting", comment: "Guide page 2: live status while waiting for the grant")
    static let guideSuccessTitle = NSLocalizedString(
        "guide.success.title", comment: "Guide success page title")
    static let guideSuccessBody = NSLocalizedString(
        "guide.success.body", comment: "Guide success page: confirmation plus try-it suggestion")
}
