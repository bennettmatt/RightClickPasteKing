// LoginItem.swift
// RightClickPasteKing
//
// Launch-at-login support via SMAppService (macOS 13+). For a plain
// .app bundle, SMAppService.mainApp manages the login-item registration
// without needing a separate helper target.
//
// ── A note on cost ──────────────────────────────────────────────────────
// Reading SMAppService.mainApp.status is NOT a cheap property access — it
// triggers an XPC round-trip to the system service-management daemon
// (smd), which does a real on-disk lookup of the app bundle. Querying it
// on every menu refresh or timer tick causes visible system-wide IPC
// chatter and can slow other operations (e.g. event-tap latency) noticeably.
//
// Callers should cache `isRegistered` and only re-query when something has
// actually changed (the user toggled the setting, the menu opened after an
// app launch, etc.) — not on a periodic poll.

import ServiceManagement

enum LoginItem {

    /// Whether the app is currently registered to launch at login.
    /// IMPORTANT: each call costs an XPC round-trip — see file header. Cache
    /// the result; do NOT call this from a timer or per-menu-refresh path.
    static var isRegistered: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    /// Register the app to launch at login. Throws if the system rejects it
    /// (e.g. the user has it blocked in System Settings > General > Login Items).
    static func register() throws {
        if SMAppService.mainApp.status != .enabled {
            try SMAppService.mainApp.register()
        }
    }

    /// Remove the app from login items. Throws on failure.
    static func unregister() throws {
        if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
