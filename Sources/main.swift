// main.swift
// RightClickPasteKing
//
// Entry point. Creates the application as an accessory (no Dock icon),
// installs the AppDelegate, and runs the run loop.
//
// We deliberately do NOT use @main / @NSApplicationMain so that we can
// force `.accessory` activation policy *before* the app finishes launching,
// which avoids a brief Dock-icon flash on startup.

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
