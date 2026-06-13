// AppDelegate.swift
// RightClickPasteKing
//
// Owns:
//   - the menu bar status item and its menu
//   - the EventTapController (the actual right-click interception)
//   - enable/disable state, persisted to UserDefaults
//   - login-item registration via SMAppService
//   - polling for Accessibility permission so the menu reflects reality
//
// Everything here is fully implemented; there are no placeholder methods.

import AppKit
import ServiceManagement
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Sparkle

    /// Sparkle's standard updater. Constructed at init (Sparkle requires
    /// early creation so it can hook app launch for scheduled checks);
    /// startingUpdater: true begins the background update schedule with
    /// Sparkle's defaults (user-consent prompt on first run, daily checks).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil)

    // MARK: - Persisted state keys

    private enum DefaultsKey {
        static let enabled = "TRCP.enabled"
        static let clearClipboardAfterPaste = "TRCP.clearClipboardAfterPaste"
        static let tintIconWhenClipboardFull = "TRCP.tintIconWhenClipboardFull"
        static let deselectAfterCopy = "TRCP.deselectAfterCopy"
        /// One-shot flag: have we ever attempted the first-launch auto-
        /// registration of the login item? Set the first time the app runs
        /// and never read again after that — its only purpose is to ensure
        /// the auto-registration is a true one-time-ever event, so if the
        /// user later disables Launch at Login we don't re-enable it on the
        /// next launch.
        static let didAutoRegisterLoginItem = "TRCP.didAutoRegisterLoginItem"
    }

    // MARK: - UI

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var enabledMenuItem: NSMenuItem!
    private var permissionMenuItem: NSMenuItem!
    private var openPermissionMenuItem: NSMenuItem!
    private var setupGuideMenuItem: NSMenuItem!
    private var clearAfterPasteMenuItem: NSMenuItem!
    private var deselectAfterCopyMenuItem: NSMenuItem!
    private var tintIconMenuItem: NSMenuItem!
    private var recentCopiesMenuItem: NSMenuItem!
    private let recentCopiesSubmenu = NSMenu()
    private var loginItemMenuItem: NSMenuItem!

    /// Last clipboard text-state reported by ClipboardHistory's watcher.
    /// Drives the status icon tint (purple when text is present).
    private var clipboardHasText = false

    // MARK: - Core

    private let tapController = EventTapController()

    /// The recent-copies buffer (memory only; see ClipboardHistory.swift for
    /// the privacy rules). Runs for the whole app lifetime, independent of
    /// the Enabled toggle — the toggle governs right-click interception, and
    /// the history menu stays useful either way.
    private let clipboardHistory = ClipboardHistory()

    /// The first-run / setup-guide window. Held so it isn't deallocated while
    /// on screen, and so we don't open a second one if it's already up.
    private var firstRunWindowController: FirstRunWindowController?

    /// Timer that re-checks Accessibility permission so the menu and the
    /// tap state stay in sync if the user grants/revokes it while we run.
    private var permissionPollTimer: Timer?

    /// Cached value of LoginItem.isRegistered.
    ///
    /// Each read of LoginItem.isRegistered hits the system service-management
    /// daemon (smd) over XPC — it is NOT a cheap property access. Calling it
    /// from the every-2-seconds permission poll path causes visible IPC
    /// chatter (visible in Console.app as repeated `Service MainAppService
    /// status: …` entries) and, on machines under any load, measurably slows
    /// the event-tap's keystroke round-trips. So we read it once at launch
    /// and only refresh it when we know it may have changed (after our own
    /// register/unregister calls, or when the menu is about to open).
    private var cachedLoginItemRegistered: Bool = false

    /// Whether the user wants the feature on. Distinct from "is the tap
    /// actually running" — the tap can only run if permission is granted.
    private var isEnabled: Bool {
        get {
            // Default to true on first launch.
            if UserDefaults.standard.object(forKey: DefaultsKey.enabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: DefaultsKey.enabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.enabled)
        }
    }

    /// Whether to clear the system clipboard after a right-click paste. This
    /// is a global side effect (it empties the clipboard for every app).
    /// Defaults to ON — right-click paste is treated as "consume once" unless
    /// the user turns this off.
    private var clearClipboardAfterPaste: Bool {
        get {
            // Absent key -> true (the default). UserDefaults.bool would
            // return false for an absent key, so we check for presence
            // explicitly, the same pattern as `isEnabled`.
            if UserDefaults.standard.object(forKey: DefaultsKey.clearClipboardAfterPaste) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: DefaultsKey.clearClipboardAfterPaste)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.clearClipboardAfterPaste)
        }
    }

    /// Whether the status icon turns purple while the clipboard holds text.
    /// Purely cosmetic feedback — purple means "right-click in Terminal
    /// will paste". Defaults to ON; the user can turn it off in the menu.
    private var tintIconWhenClipboardFull: Bool {
        get {
            // Absent key -> true (the default), same pattern as above.
            if UserDefaults.standard.object(forKey: DefaultsKey.tintIconWhenClipboardFull) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: DefaultsKey.tintIconWhenClipboardFull)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.tintIconWhenClipboardFull)
        }
    }

    /// Whether a right-click copy also clears the selection, so the next
    /// right-click pastes instead of re-copying. Defaults to ON.
    private var deselectAfterCopy: Bool {
        get {
            if UserDefaults.standard.object(forKey: DefaultsKey.deselectAfterCopy) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: DefaultsKey.deselectAfterCopy)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.deselectAfterCopy)
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disk-image installer flow FIRST, before any other launch work:
        // if we're running from the DMG and the user accepts the move to
        // /Applications, this process is about to terminate and relaunch —
        // nothing else (login item, watchers, first-run window) should
        // happen in that case.
        if DiskImageInstaller.offerMoveToApplicationsIfNeeded() {
            return
        }
        // Relaunched-with-consent case: silently eject our image and trash
        // the .dmg, then continue a normal launch.
        DiskImageInstaller.performConsentedCleanupIfRequested()

        buildStatusItem()
        buildMenu()

        // Push the persisted "clear clipboard after paste" preference into
        // the tap controller before it starts handling clicks.
        tapController.clearClipboardAfterPaste = clearClipboardAfterPaste
        tapController.deselectAfterCopy = deselectAfterCopy

        // First-launch-only: enable Launch at Login by default. We use a
        // sticky one-shot flag in UserDefaults so this only ever fires the
        // FIRST time the app runs — if the user later turns Launch at Login
        // off, we honor that and do not re-enable it on the next launch.
        autoRegisterLoginItemIfFirstLaunch()

        // Seed the cached login-item state once at launch. From here on we
        // only refresh it after our own register/unregister or when the menu
        // is about to open — never from the periodic poll. (See the property
        // comment on cachedLoginItemRegistered for the reason.)
        refreshLoginItemCache()

        // Apply persisted state. This will start the tap if enabled AND
        // permission is already granted; otherwise it stays dormant.
        applyEnabledState(isEnabled, requestPermissionIfNeeded: false)

        // Wire the clipboard text-state callback BEFORE starting the
        // watcher — start() reports the initial state synchronously, and we
        // want it to land on the icon. The callback fires only on
        // transitions, so the tint work is rare and cheap.
        clipboardHistory.onTextStateChange = { [weak self] hasText in
            self?.clipboardHasText = hasText
            self?.refreshStatusItemTint()
        }

        // Start the recent-copies watcher (memory-only buffer; concealed and
        // transient pasteboard content is never recorded).
        clipboardHistory.start()

        startPermissionPolling()
        refreshMenuState()

        // First-run experience: if Accessibility permission isn't granted
        // yet, the app can't do anything, so guide the user through granting
        // it. This shows on every launch until permission is granted (after
        // which it never appears on its own again — see permissionPollTick).
        if !AccessibilityPermission.isGranted {
            showFirstRunWindow()
        }

        // Dragged-properly-but-DMG-still-mounted case: offer to eject the
        // image and trash the .dmg. Delayed a beat so it doesn't land on
        // top of the first-run window appearing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            DiskImageInstaller.offerCleanupOfLeftoverImage()
        }
    }

    /// On the very first launch ever, register the app as a login item so
    /// Launch at Login defaults to on. Uses a sticky one-shot flag — this is
    /// NOT "make sure it's registered every launch"; that would override the
    /// user's choice to disable it. Errors are intentionally swallowed: if
    /// the system rejects registration (e.g. it's blocked in System Settings
    /// > General > Login Items), the user can still turn it on manually from
    /// the app's menu.
    private func autoRegisterLoginItemIfFirstLaunch() {
        // Never auto-register while running from a disk image (or App
        // Translocation): SMAppService registers the RUNNING bundle's path,
        // and a /Volumes path is dead the moment the image ejects. The
        // one-shot flag is deliberately NOT burned here — the registration
        // should still happen on the first launch from a real install
        // location.
        guard !DiskImageInstaller.isRunningFromDiskImage else { return }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: DefaultsKey.didAutoRegisterLoginItem) else {
            return
        }
        // Mark the flag BEFORE attempting registration, so even if it fails
        // we don't keep retrying on every subsequent launch.
        defaults.set(true, forKey: DefaultsKey.didAutoRegisterLoginItem)
        try? LoginItem.register()
    }

    /// Refreshes `cachedLoginItemRegistered` from the system. Costly (XPC).
    /// Call only after register/unregister or when the menu is about to open.
    private func refreshLoginItemCache() {
        cachedLoginItemRegistered = LoginItem.isRegistered
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        clipboardHistory.stop()
        tapController.stop()
    }

    // MARK: - Status item / menu construction

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // SF Symbol that reads as "clipboard / paste". Falls back to a
            // text glyph on the (very unlikely) chance the symbol is missing.
            let symbolName = "doc.on.clipboard"
            if let image = NSImage(systemSymbolName: symbolName,
                                   accessibilityDescription: "RightClickPasteKing") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "⌘V"
            }
            button.toolTip = "RightClickPasteKing"
        }
    }

    private func buildMenu() {
        menu.autoenablesItems = false

        // Title row (disabled, acts as a header).
        // Title with version + build, so "which binary is actually running"
        // is always answerable at a glance — vital when DMG installs and
        // Xcode builds coexist on the same machine.
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let titleItem = NSMenuItem(title: "RightClickPasteKing \(shortVersion) (\(buildNumber))",
                                   action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        // Enable / disable toggle.
        enabledMenuItem = NSMenuItem(title: L10n.menuEnabled,
                                     action: #selector(toggleEnabled(_:)),
                                     keyEquivalent: "")
        enabledMenuItem.target = self
        menu.addItem(enabledMenuItem)

        // "Clear clipboard after paste" toggle — a behavior option, so it
        // sits next to the Enabled toggle. On by default. The tooltip spells
        // out the global side effect so it's not a surprise.
        clearAfterPasteMenuItem = NSMenuItem(title: L10n.menuClearAfterPaste,
                                             action: #selector(toggleClearAfterPaste(_:)),
                                             keyEquivalent: "")
        clearAfterPasteMenuItem.target = self
        clearAfterPasteMenuItem.toolTip = L10n.menuClearAfterPasteTooltip
        menu.addItem(clearAfterPasteMenuItem)

        // Deselect-after-copy toggle: completes the one-finger cycle —
        // right-click copies AND deselects, so the next right-click pastes.
        deselectAfterCopyMenuItem = NSMenuItem(title: L10n.menuDeselectAfterCopy,
                                               action: #selector(toggleDeselectAfterCopy(_:)),
                                               keyEquivalent: "")
        deselectAfterCopyMenuItem.target = self
        deselectAfterCopyMenuItem.toolTip = L10n.menuDeselectAfterCopyTooltip
        menu.addItem(deselectAfterCopyMenuItem)

        // Purple-icon-when-clipboard-full toggle. Cosmetic feedback; the
        // tint itself is applied by refreshStatusItemTint().
        tintIconMenuItem = NSMenuItem(title: L10n.menuTintIcon,
                                      action: #selector(toggleTintIcon(_:)),
                                      keyEquivalent: "")
        tintIconMenuItem.target = self
        menu.addItem(tintIconMenuItem)

        // Recent copies submenu — the recovery path for consumed pastes.
        // Its items are rebuilt every time the menu opens (menuNeedsUpdate).
        recentCopiesMenuItem = NSMenuItem(title: L10n.menuRecentCopies,
                                          action: nil,
                                          keyEquivalent: "")
        recentCopiesMenuItem.submenu = recentCopiesSubmenu
        menu.addItem(recentCopiesMenuItem)

        menu.addItem(.separator())

        // Accessibility permission status (disabled — informational).
        permissionMenuItem = NSMenuItem(title: L10n.menuAccessibilityChecking,
                                        action: nil,
                                        keyEquivalent: "")
        permissionMenuItem.isEnabled = false
        menu.addItem(permissionMenuItem)

        // Button to jump straight to the Accessibility settings pane.
        openPermissionMenuItem = NSMenuItem(title: L10n.menuOpenAccessibility,
                                            action: #selector(openAccessibilitySettings(_:)),
                                            keyEquivalent: "")
        openPermissionMenuItem.target = self
        menu.addItem(openPermissionMenuItem)

        // Reopen the guided first-run window. Useful if the user dismissed it
        // before granting permission, or if permission was later revoked.
        setupGuideMenuItem = NSMenuItem(title: L10n.menuSetupGuide,
                                        action: #selector(showSetupGuide(_:)),
                                        keyEquivalent: "")
        setupGuideMenuItem.target = self
        menu.addItem(setupGuideMenuItem)

        // Check for updates — wired straight to Sparkle's standard action.
        let updatesItem = NSMenuItem(title: L10n.menuCheckForUpdates,
                                     action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                     keyEquivalent: "")
        updatesItem.target = updaterController
        menu.addItem(updatesItem)

        menu.addItem(.separator())

        // Launch-at-login toggle.
        loginItemMenuItem = NSMenuItem(title: L10n.menuLaunchAtLogin,
                                       action: #selector(toggleLoginItem(_:)),
                                       keyEquivalent: "")
        loginItemMenuItem.target = self
        menu.addItem(loginItemMenuItem)

        menu.addItem(.separator())

        // Quit.
        let quitItem = NSMenuItem(title: L10n.menuQuit,
                                  action: #selector(quit(_:)),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Become the menu's delegate so menuNeedsUpdate(_:) fires when the
        // user clicks the menu bar item. That's the right moment — and the
        // ONLY moment outside our own toggle calls — to re-read
        // SMAppService.mainApp.status, so the displayed Launch-at-Login
        // checkmark is correct even if the user changed it from System
        // Settings while the app was running. It's also where the Recent
        // Copies submenu is rebuilt from the current history buffer.
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Recent copies submenu

    /// Rebuilds the Recent Copies submenu from the current history buffer.
    /// Called from menuNeedsUpdate so the list is fresh each time the menu
    /// opens. Selecting an entry puts it back on the system clipboard.
    private func rebuildRecentCopiesSubmenu() {
        recentCopiesSubmenu.removeAllItems()

        if clipboardHistory.entries.isEmpty {
            let empty = NSMenuItem(title: L10n.menuRecentCopiesEmpty,
                                   action: nil,
                                   keyEquivalent: "")
            empty.isEnabled = false
            recentCopiesSubmenu.addItem(empty)
            return
        }

        for entry in clipboardHistory.entries {
            let item = NSMenuItem(title: ClipboardHistory.preview(of: entry),
                                  action: #selector(selectRecentCopy(_:)),
                                  keyEquivalent: "")
            item.target = self
            // The full entry rides on the item itself. Selection is by
            // VALUE, not by index — the history can shift while the menu
            // is open (the watcher keeps running in menu-tracking mode),
            // which would make a captured index point at the wrong entry.
            item.representedObject = entry
            // Full text as tooltip (capped by AppKit's own tooltip limits)
            // so a truncated preview can still be inspected before pasting.
            item.toolTip = entry.count <= 1000 ? entry : nil
            recentCopiesSubmenu.addItem(item)
        }

        recentCopiesSubmenu.addItem(.separator())
        let clearItem = NSMenuItem(title: L10n.menuRecentCopiesClear,
                                   action: #selector(clearRecentCopies(_:)),
                                   keyEquivalent: "")
        clearItem.target = self
        recentCopiesSubmenu.addItem(clearItem)
    }

    @objc private func selectRecentCopy(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        clipboardHistory.select(text: text)
    }

    @objc private func clearRecentCopies(_ sender: NSMenuItem) {
        clipboardHistory.clear()
    }

    // MARK: - Menu actions

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        let newValue = !isEnabled
        isEnabled = newValue
        // When the user explicitly turns the feature on, that's the right
        // moment to prompt for Accessibility permission if we don't have it.
        applyEnabledState(newValue, requestPermissionIfNeeded: newValue)
        refreshMenuState()
    }

    @objc private func toggleClearAfterPaste(_ sender: NSMenuItem) {
        let newValue = !clearClipboardAfterPaste
        clearClipboardAfterPaste = newValue
        // Push the change straight into the tap controller so it takes
        // effect on the very next paste — no relaunch needed.
        tapController.clearClipboardAfterPaste = newValue
        refreshMenuState()
    }

    @objc private func toggleDeselectAfterCopy(_ sender: NSMenuItem) {
        let newValue = !deselectAfterCopy
        deselectAfterCopy = newValue
        tapController.deselectAfterCopy = newValue
        refreshMenuState()
    }

    @objc private func toggleTintIcon(_ sender: NSMenuItem) {
        tintIconWhenClipboardFull = !tintIconWhenClipboardFull
        // Apply immediately — turning the setting off while the clipboard
        // is full should un-purple the icon right now, not on the next
        // clipboard change.
        refreshStatusItemTint()
        refreshMenuState()
    }

    /// Applies (or removes) the purple tint on the status item. The icon is
    /// a template SF Symbol, so contentTintColor recolors it cleanly in
    /// both light and dark menu bars; nil restores the standard adaptive
    /// monochrome. Coexists with appearsDisabled (set in refreshMenuState),
    /// which dims whatever color is showing.
    private func refreshStatusItemTint() {
        guard let button = statusItem?.button else { return }
        let tint = tintIconWhenClipboardFull && clipboardHasText
        button.contentTintColor = tint ? .systemPurple : nil
    }

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        // Deep-link straight to the Accessibility pane in System Settings.
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        // Also fire the system prompt, which adds the app to the list if it
        // isn't there yet. This is a no-op if permission is already granted.
        _ = AccessibilityPermission.requestIfNeeded()
    }

    @objc private func showSetupGuide(_ sender: NSMenuItem) {
        showFirstRunWindow()
    }

    // MARK: - First-run window management

    /// Shows the guided setup window. If it's already on screen, just brings
    /// it to the front rather than opening a second one.
    private func showFirstRunWindow() {
        if let existing = firstRunWindowController {
            existing.present()
            return
        }
        let controller = FirstRunWindowController()
        controller.onboardingDelegate = self
        firstRunWindowController = controller
        controller.present()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        // Use the CACHED value to decide direction so we don't pay another
        // XPC round-trip just to read what we already know.
        let currentlyRegistered = cachedLoginItemRegistered
        do {
            if currentlyRegistered {
                try LoginItem.unregister()
            } else {
                try LoginItem.register()
            }
        } catch {
            presentError(String(format: L10n.alertLoginItemErrorFormat,
                                error.localizedDescription))
        }
        // The system state actually changed (or attempted to), so re-seed
        // the cache from the authoritative source. This is the right place
        // to pay the XPC cost — once per user-initiated toggle, not once
        // every 2 seconds.
        refreshLoginItemCache()
        refreshMenuState()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - State application

    /// Brings the event tap in line with `enabled` and the current permission
    /// state. The tap only actually runs when enabled == true AND Accessibility
    /// permission is granted.
    ///
    /// - Parameters:
    ///   - enabled: whether the user wants the feature on.
    ///   - requestPermissionIfNeeded: if true and permission is missing, shows
    ///     the system Accessibility prompt.
    private func applyEnabledState(_ enabled: Bool, requestPermissionIfNeeded: Bool) {
        guard enabled else {
            tapController.stop()
            return
        }

        let hasPermission: Bool
        if requestPermissionIfNeeded {
            hasPermission = AccessibilityPermission.requestIfNeeded()
        } else {
            hasPermission = AccessibilityPermission.isGranted
        }

        if hasPermission {
            tapController.start()
        } else {
            // Wanted on, but we can't run yet. The permission poll timer will
            // start the tap automatically once the user grants access.
            tapController.stop()
        }
    }

    // MARK: - Permission polling

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.permissionPollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func permissionPollTick() {
        // If the feature is enabled, keep the tap's running state matched to
        // whatever the current permission situation is.
        if isEnabled {
            let hasPermission = AccessibilityPermission.isGranted
            if hasPermission && !tapController.isRunning {
                tapController.start()
            } else if !hasPermission && tapController.isRunning {
                tapController.stop()
            } else if hasPermission && tapController.isRunning && !tapController.isTapEnabled {
                // The tap can be disabled by the system (e.g. after a timeout
                // or being woken from sleep). Re-arm it.
                tapController.reenableIfNeeded()
            }
        }
        refreshMenuState()
    }

    // MARK: - Menu state refresh

    private func refreshMenuState() {
        let enabled = isEnabled
        let hasPermission = AccessibilityPermission.isGranted

        enabledMenuItem.state = enabled ? .on : .off

        // "Clear clipboard after paste" checkmark reflects the persisted
        // preference. It stays available regardless of permission state —
        // it's a behavior preference, not something gated on the tap running.
        clearAfterPasteMenuItem.state = clearClipboardAfterPaste ? .on : .off

        // Same for the deselect-after-copy and purple-icon toggles.
        deselectAfterCopyMenuItem.state = deselectAfterCopy ? .on : .off
        tintIconMenuItem.state = tintIconWhenClipboardFull ? .on : .off

        if hasPermission {
            permissionMenuItem.title = L10n.menuAccessibilityGranted
            openPermissionMenuItem.isHidden = true
        } else {
            permissionMenuItem.title = enabled
                ? L10n.menuAccessibilityRequired
                : L10n.menuAccessibilityNotGranted
            openPermissionMenuItem.isHidden = false
        }

        // Use the CACHED login-item state. Reading LoginItem.isRegistered
        // here would hit smd over XPC on every menu refresh — including the
        // every-2-second poll tick, which was the cause of significant
        // event-tap latency on Release builds. The cache is refreshed at
        // launch, after the user toggles the setting, and when the menu is
        // about to open (see menuNeedsUpdate).
        loginItemMenuItem.state = cachedLoginItemRegistered ? .on : .off

        // Reflect the true running state in the status item's tooltip and
        // give a subtle visual cue via the symbol's appearance.
        if let button = statusItem.button {
            let active = enabled && hasPermission && tapController.isRunning
            button.appearsDisabled = !active
            button.toolTip = active
                ? L10n.tooltipActive
                : (enabled ? L10n.tooltipNeedsPermission : L10n.tooltipDisabled)
        }
    }

    // MARK: - Error presentation

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "RightClickPasteKing"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - FirstRunWindowControllerDelegate

extension AppDelegate: FirstRunWindowControllerDelegate {

    /// Called when the first-run window closes, whether the user granted
    /// permission or just dismissed it.
    func firstRunDidFinish(granted: Bool) {
        // Release the controller so a later "Setup Guide…" builds a fresh
        // one (and so it isn't retained needlessly while not on screen).
        firstRunWindowController = nil

        // If permission was granted, bring the tap up immediately rather
        // than waiting for the next 2-second poll tick.
        if granted {
            applyEnabledState(isEnabled, requestPermissionIfNeeded: false)
        }
        refreshMenuState()
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {

    /// Called just before the menu becomes visible. We use it to refresh
    /// state that's relatively expensive to query and might have changed
    /// without us being told — specifically, the Launch-at-Login state,
    /// which the user could have toggled via System Settings while the app
    /// was running. Catching it here means the next menu open shows the
    /// correct checkmark; the cost (one XPC round-trip to smd) is paid
    /// only when the user actually opens the menu, not on every poll tick.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshLoginItemCache()
        rebuildRecentCopiesSubmenu()
        refreshMenuState()
    }
}
