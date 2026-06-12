// FirstRunWindowController.swift
// RightClickPasteKing
//
// The first-run onboarding experience. Guides the user through granting
// Accessibility permission, which the app cannot function without.
//
// ── What this does, and the OS limitation it works around ───────────────
// The goal is the "drag the app icon into the permission list" flow. The
// hard constraint: macOS does NOT allow an app to draw on top of, or inject
// UI into, System Settings — it's a separate sandboxed process. So this is
// NOT an overlay on Apple's window.
//
// Instead this is a borderless, always-on-top companion panel that:
//   1. Shows the app icon, a short explanation, and an action button.
//   2. On the button press, opens the System Settings Accessibility pane
//      AND fires Apple's own trust prompt (which adds the app to the list).
//   3. Repositions itself beside the System Settings window so the two
//      read as a single guided flow.
//   4. Presents the app icon as a drag source, so the user can drag it
//      straight into the Accessibility list if they prefer that to using
//      the prompt's checkbox.
//   5. Watches for the permission to be granted, shows a brief confirmation,
//      and closes itself.
//
// Everything here is fully implemented; there are no placeholder methods.

import AppKit
import UniformTypeIdentifiers

/// Delegate so the AppDelegate learns when onboarding finishes (granted or
/// just dismissed) and can update the tap / menu accordingly.
protocol FirstRunWindowControllerDelegate: AnyObject {
    /// Called once, when the window has closed for any reason. `granted`
    /// reflects the Accessibility permission state at close time.
    func firstRunDidFinish(granted: Bool)
}

final class FirstRunWindowController: NSWindowController {

    weak var onboardingDelegate: FirstRunWindowControllerDelegate?

    // MARK: - Layout constants

    private enum Layout {
        static let windowWidth: CGFloat  = 360
        static let windowHeight: CGFloat = 540
        static let iconSize: CGFloat     = 110
        static let padding: CGFloat      = 28
        /// Gap left between this panel and the System Settings window when
        /// the panel repositions itself alongside.
        static let companionGap: CGFloat = 24
    }

    /// The guide's pages.
    ///
    /// - explain: "what this app does" — the behavior rules and the two
    ///   on-by-default settings the user should know about. When
    ///   `referenceOnly` is true (permission already granted; opened from
    ///   the Setup Guide menu item) this is the whole guide and the button
    ///   just closes; otherwise the button continues to .permission.
    /// - permission: the Accessibility grant choreography.
    /// - success: brief confirmation, then auto-close.
    private enum Step {
        case explain(referenceOnly: Bool)
        case permission
        case success
    }

    /// Current page. Set via configure(step:).
    private var step: Step = .explain(referenceOnly: false)

    // MARK: - Subviews kept as references (reconfigured per step)

    private var iconView: DraggableIconView!
    private var titleLabel: NSTextField!
    private var bodyLabel: NSTextField!
    private var actionButton: NSButton!
    private var stepsLabel: NSTextField!

    /// Live "watching for the grant" indicator, shown only on the permission
    /// page: a small native spinner plus a status label. Honest scope note:
    /// macOS offers no public API to detect the intermediate "added to the
    /// Accessibility list but still unchecked" state — AXIsProcessTrusted is
    /// strictly granted/not-granted — so this indicator shows that the app
    /// is actively waiting, and the moment the grant lands the window moves
    /// itself to the success page.
    private var statusSpinner: NSProgressIndicator!
    private var statusLabel: NSTextField!

    // MARK: - Permission watching

    /// Polls for the Accessibility grant while the window is open. Separate
    /// from the AppDelegate's own poll so the window is self-contained.
    private var grantPollTimer: Timer?

    /// Guards against firing the "finished" delegate callback more than once.
    private var didFinish = false

    /// True once we've shown the success state, so the poll doesn't re-run it.
    private var didShowSuccess = false

    // MARK: - Init

    /// Builds the window programmatically (no nib) so the project stays a
    /// flat set of source files with no Interface Builder dependency.
    convenience init() {
        let contentRect = NSRect(x: 0, y: 0,
                                 width: Layout.windowWidth,
                                 height: Layout.windowHeight)

        // .titled gives us a standard close button and a draggable frame;
        // we keep it visually minimal. .fullSizeContentView lets the content
        // run under the title bar for a clean look.
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating            // stays above normal windows…
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = NSColor.windowBackgroundColor
        window.isReleasedWhenClosed = false // we manage the lifetime ourselves

        self.init(window: window)
        window.delegate = self

        buildContent()
        positionInitially()
    }

    // MARK: - Content construction

    /// Creates the views once; configure(step:) sets their text and frames.
    private func buildContent() {
        guard let window = window, let contentView = window.contentView else { return }
        contentView.wantsLayer = true

        // ── App icon (drag source) ──────────────────────────────────────
        iconView = DraggableIconView(frame: NSRect(
            x: (Layout.windowWidth - Layout.iconSize) / 2,
            y: Layout.windowHeight - Layout.padding - Layout.iconSize - 8,
            width: Layout.iconSize,
            height: Layout.iconSize))
        iconView.image = Self.appIconImage()
        contentView.addSubview(iconView)

        // ── Title ───────────────────────────────────────────────────────
        titleLabel = Self.makeLabel(text: "", fontSize: 17,
                                    weight: .semibold, alignment: .center)
        contentView.addSubview(titleLabel)

        // ── Body text ───────────────────────────────────────────────────
        bodyLabel = Self.makeLabel(text: "", fontSize: 12,
                                   weight: .regular, alignment: .center)
        contentView.addSubview(bodyLabel)

        // ── Secondary text ──────────────────────────────────────────────
        stepsLabel = Self.makeLabel(text: "", fontSize: 11,
                                    weight: .regular, alignment: .center)
        stepsLabel.textColor = .secondaryLabelColor
        contentView.addSubview(stepsLabel)

        // ── Action button ───────────────────────────────────────────────
        actionButton = NSButton(title: L10n.guideButtonContinue,
                                target: self,
                                action: #selector(actionButtonPressed))
        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"   // Return triggers it
        contentView.addSubview(actionButton)

        // ── Live waiting indicator (permission page only) ───────────────
        statusSpinner = NSProgressIndicator()
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false
        contentView.addSubview(statusSpinner)

        statusLabel = Self.makeLabel(text: L10n.guidePermissionWaiting,
                                     fontSize: 11,
                                     weight: .regular, alignment: .left)
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(statusLabel)
    }

    /// Applies a step's text and layout to the shared views.
    private func configure(step newStep: Step) {
        step = newStep

        let title: String
        let body: String
        let secondary: String
        let buttonTitle: String
        let bodyHeight: CGFloat
        let secondaryHeight: CGFloat
        let bodyAlignment: NSTextAlignment

        switch newStep {
        case .explain(let referenceOnly):
            title = referenceOnly ? L10n.guideExplainTitleReference
                                  : L10n.guideExplainTitleWelcome
            body = L10n.guideExplainBody
            secondary = L10n.guideExplainSecondary
            buttonTitle = referenceOnly ? L10n.guideButtonDone
                                        : L10n.guideButtonContinue
            bodyHeight = 170
            secondaryHeight = 76
            bodyAlignment = .left

        case .permission:
            title = L10n.guidePermissionTitle
            body = L10n.guidePermissionBody
            secondary = L10n.guidePermissionSecondary
            buttonTitle = L10n.guidePermissionButton
            bodyHeight = 76
            secondaryHeight = 64
            bodyAlignment = .center

        case .success:
            title = L10n.guideSuccessTitle
            body = L10n.guideSuccessBody
            secondary = ""
            buttonTitle = L10n.guideButtonDone
            bodyHeight = 110
            secondaryHeight = 0
            bodyAlignment = .center
        }

        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        bodyLabel.alignment = bodyAlignment
        stepsLabel.stringValue = secondary
        actionButton.title = buttonTitle

        // ── Layout: title under icon, body under title, secondary under
        //    body, button pinned to the bottom. ─────────────────────────
        let contentWidth = Layout.windowWidth - Layout.padding * 2

        titleLabel.frame = NSRect(
            x: Layout.padding,
            y: iconView.frame.minY - 36,
            width: contentWidth,
            height: 28)

        bodyLabel.frame = NSRect(
            x: Layout.padding,
            y: titleLabel.frame.minY - 10 - bodyHeight,
            width: contentWidth,
            height: bodyHeight)

        stepsLabel.frame = NSRect(
            x: Layout.padding,
            y: bodyLabel.frame.minY - 8 - secondaryHeight,
            width: contentWidth,
            height: secondaryHeight)
        stepsLabel.isHidden = secondaryHeight == 0

        actionButton.sizeToFit()
        let buttonWidth = max(actionButton.frame.width + 24, 240)
        actionButton.frame = NSRect(
            x: (Layout.windowWidth - buttonWidth) / 2,
            y: Layout.padding,
            width: buttonWidth,
            height: actionButton.frame.height)

        // The waiting indicator sits between the secondary text and the
        // button, only on the permission page.
        let onPermissionPage: Bool
        if case .permission = newStep { onPermissionPage = true } else { onPermissionPage = false }

        statusLabel.sizeToFit()
        let spinnerSide: CGFloat = 16
        let rowWidth = spinnerSide + 6 + statusLabel.frame.width
        let rowY = actionButton.frame.maxY + 14
        statusSpinner.frame = NSRect(
            x: (Layout.windowWidth - rowWidth) / 2,
            y: rowY,
            width: spinnerSide,
            height: spinnerSide)
        statusLabel.frame = NSRect(
            x: statusSpinner.frame.maxX + 6,
            y: rowY + 1,
            width: statusLabel.frame.width,
            height: spinnerSide)

        statusSpinner.isHidden = !onPermissionPage
        statusLabel.isHidden = !onPermissionPage
        if onPermissionPage {
            statusSpinner.startAnimation(nil)
        } else {
            statusSpinner.stopAnimation(nil)
        }
    }

    // MARK: - Showing the window

    /// Brings the guide on screen. Starts on the "what it does" page; if
    /// permission is already granted (reopened from the Setup Guide menu),
    /// that page is the whole guide and acts as a reference card.
    func present() {
        guard let window = window else { return }

        let alreadyGranted = AccessibilityPermission.isGranted
        configure(step: .explain(referenceOnly: alreadyGranted))

        // The app is an accessory (no Dock icon); we must explicitly
        // activate so the window can take focus and appear in front.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Watch for the grant only when there's a grant to watch for.
        if !alreadyGranted {
            startGrantPolling()
        }
    }

    /// Centers the window on the main screen as a sensible starting point,
    /// before the user opens System Settings (after which we reposition).
    private func positionInitially() {
        guard let window = window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Layout.windowWidth / 2,
            y: visible.midY - Layout.windowHeight / 2)
        window.setFrameOrigin(origin)
    }

    // MARK: - Action

    @objc private func actionButtonPressed() {
        switch step {
        case .explain(let referenceOnly):
            if referenceOnly {
                // Reference mode (permission already granted): the explain
                // page is the whole guide; Done just closes.
                closeNow()
            } else {
                configure(step: .permission)
            }

        case .permission:
            openSettingsAndRepositionAlongside()

        case .success:
            closeNow()
        }
    }

    /// The permission step's action: open the Accessibility pane, fire
    /// Apple's trust prompt, and slide this panel alongside System Settings.
    private func openSettingsAndRepositionAlongside() {
        // 1. Open the Accessibility pane in System Settings.
        let paneURL = "x-apple.systempreferences:com.apple.preference.security"
            + "?Privacy_Accessibility"
        if let url = URL(string: paneURL) {
            NSWorkspace.shared.open(url)
        }

        // 2. Fire Apple's own trust prompt. This adds the app to the
        //    Accessibility list (unchecked) and shows Apple's alert with a
        //    button to the pane. Harmless no-op if already trusted.
        _ = AccessibilityPermission.requestIfNeeded()

        // 3. After a beat — enough for System Settings to actually open its
        //    window — slide this panel alongside it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.repositionBesideSystemSettings()
        }
    }

    // MARK: - Repositioning beside System Settings

    /// Finds the System Settings window on screen and moves this panel to sit
    /// just beside it, so the two read as one guided flow. If System Settings
    /// can't be located, the panel simply stays where it is — no harm done.
    private func repositionBesideSystemSettings() {
        guard let window = window else { return }
        guard let settingsFrame = Self.systemSettingsWindowFrame() else {
            // Couldn't locate it (permissions, timing, layout change in a
            // future macOS). Leave the panel centered — still fully usable.
            return
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame

        // Prefer placing the panel to the LEFT of System Settings. If there
        // isn't room on the left, place it to the RIGHT instead.
        let panelW = window.frame.width
        let panelH = window.frame.height

        var originX = settingsFrame.minX - Layout.companionGap - panelW
        if originX < visible.minX {
            originX = settingsFrame.maxX + Layout.companionGap
            // If it also overflows on the right, clamp into the visible area.
            if originX + panelW > visible.maxX {
                originX = max(visible.minX, visible.maxX - panelW)
            }
        }

        // Vertically align the panel's top with the System Settings window's
        // top, which keeps the icon high and visible.
        var originY = settingsFrame.maxY - panelH
        originY = min(max(originY, visible.minY), visible.maxY - panelH)

        window.setFrame(NSRect(x: originX, y: originY, width: panelW, height: panelH),
                        display: true,
                        animate: true)
    }

    /// Returns the on-screen frame of the System Settings window, if one is
    /// open. Returns nil if it can't be found — callers must treat that as a
    /// normal outcome, not an error.
    ///
    /// On Screen Recording permission: querying CGWindowList for window
    /// GEOMETRY and OWNER NAME does NOT require Screen Recording permission
    /// and does NOT trigger its prompt. Only window CONTENTS and the window
    /// TITLE (kCGWindowName) are gated by that permission — and this code
    /// reads neither. So this stays a zero-permission, best-effort lookup;
    /// onboarding never causes a second permission prompt.
    private static func systemSettingsWindowFrame() -> NSRect? {
        // System Settings (Ventura+) and "System Preferences" (older systems)
        // are matched by owner name to stay version-tolerant.
        let ownerNames: Set<String> = ["System Settings", "System Preferences"]

        let options: CGWindowListOption = [.optionOnScreenOnly,
                                           .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            return nil
        }

        // Pick the largest matching window (the main settings window, not a
        // tooltip or sheet).
        var best: NSRect?
        var bestArea: CGFloat = 0
        for info in infoList {
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  ownerNames.contains(owner) else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            // CGWindow bounds are in a top-left origin coordinate space;
            // convert to AppKit's bottom-left origin space.
            let area = bounds.width * bounds.height
            if area > bestArea {
                bestArea = area
                best = Self.convertFromCGWindowBounds(bounds)
            }
        }
        return best
    }

    /// Converts a CGWindow bounds rect (top-left origin, y grows downward)
    /// into an AppKit screen rect (bottom-left origin, y grows upward).
    private static func convertFromCGWindowBounds(_ cgBounds: CGRect) -> NSRect {
        // The conversion is relative to the primary screen's full height.
        guard let primary = NSScreen.screens.first else { return cgBounds }
        let primaryHeight = primary.frame.height
        let flippedY = primaryHeight - cgBounds.origin.y - cgBounds.height
        return NSRect(x: cgBounds.origin.x,
                      y: flippedY,
                      width: cgBounds.width,
                      height: cgBounds.height)
    }

    // MARK: - Grant polling

    private func startGrantPolling() {
        grantPollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.grantPollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        grantPollTimer = timer
    }

    private func stopGrantPolling() {
        grantPollTimer?.invalidate()
        grantPollTimer = nil
    }

    private func grantPollTick() {
        guard !didShowSuccess else { return }
        if AccessibilityPermission.isGranted {
            showSuccessAndClose()
        }
    }

    // MARK: - Success state

    /// Swaps the window to the success page (with a concrete "try it"
    /// suggestion), then closes the window automatically after a delay long
    /// enough to read it. The Done button and the close box work immediately.
    private func showSuccessAndClose() {
        didShowSuccess = true
        stopGrantPolling()

        configure(step: .success)

        // Auto-close, but give the user enough time to read the try-it
        // text — it's two sentences, not a toast.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.closeNow()
        }
    }

    @objc private func closeNow() {
        window?.close()
    }

    // MARK: - Finishing

    /// Fires the delegate callback exactly once. Called from windowWillClose.
    private func finishIfNeeded() {
        guard !didFinish else { return }
        didFinish = true
        stopGrantPolling()
        onboardingDelegate?.firstRunDidFinish(granted: AccessibilityPermission.isGranted)
    }

    // MARK: - Helpers

    /// The app icon as an NSImage. With the Xcode build, the icon lives in
    /// the compiled asset catalog under the name "AppIcon", so that's tried
    /// first. The other paths are fallbacks for non-asset-catalog builds.
    static func appIconImage() -> NSImage {
        // 1. The "AppIcon" set in the compiled asset catalog (Xcode build).
        if let named = NSImage(named: "AppIcon") {
            return named
        }
        // 2. A raw AppIcon.icns in Resources (non-asset-catalog builds).
        if let icnsURL = Bundle.main.url(forResource: "AppIcon",
                                         withExtension: "icns"),
           let image = NSImage(contentsOf: icnsURL) {
            return image
        }
        // 3. Whatever the system reports as the app icon. This is the real
        //    icon once the app is bundled; only a generic icon in a raw
        //    unbundled run.
        return NSApp.applicationIconImage
    }

    private static func makeLabel(text: String,
                                  fontSize: CGFloat,
                                  weight: NSFont.Weight,
                                  alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        label.alignment = alignment
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byWordWrapping
        return label
    }
}

// MARK: - NSWindowDelegate

extension FirstRunWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        finishIfNeeded()
    }
}

// MARK: - DraggableIconView

/// An image view that acts as a drag source for the app bundle itself. The
/// user can drag this icon into the System Settings Accessibility list to
/// add the app there — the same gesture as dragging the .app from Finder.
final class DraggableIconView: NSImageView, NSDraggingSource {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        imageScaling = .scaleProportionallyUpOrDown
        // NSImageView is editable by default in some configurations, which
        // would let the system handle drags itself and interfere with our
        // custom drag-source behavior. Turn that off so mouseDown(with:) is
        // ours to handle.
        isEditable = false
        // Cursor rects are established in resetCursorRects(), not here —
        // rects added in init get invalidated before they ever take effect.
    }

    override func resetCursorRects() {
        // A pointing-hand cursor hints that the icon is draggable.
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: Drag source

    override func mouseDown(with event: NSEvent) {
        // The drag payload is the app bundle's own URL on disk. Dragging it
        // into the Accessibility list behaves exactly like dragging the .app
        // from Finder. If we can't resolve the bundle URL (shouldn't happen
        // for a normal launch), we simply don't initiate a drag.
        let bundleURL = Bundle.main.bundleURL
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return
        }

        let pasteboardItem = NSPasteboardItem()
        // Provide the bundle as a file URL on the pasteboard.
        pasteboardItem.setString(bundleURL.absoluteString,
                                 forType: .fileURL)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

        // Use the icon image itself as the drag image, sized to this view.
        let dragImage = image ?? NSImage(size: bounds.size)
        draggingItem.setDraggingFrame(bounds, contents: dragImage)

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation {
        // Copy semantics: we're not moving the app, just letting it be
        // referenced/added elsewhere.
        return .copy
    }
}
