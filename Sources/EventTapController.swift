// EventTapController.swift
// RightClickPasteKing
//
// The core of the app. Installs a CGEventTap that watches for
// right-mouse-down events. It intercepts a click only when BOTH Terminal
// is the frontmost app AND the click landed on a Terminal window (checked
// against the actual on-screen window stack) — then decides between COPY,
// PASTE, or "do nothing and let Terminal's own context menu appear".
// Clicks anywhere outside that dual gate pass through untouched.
//
// ── Behavior overview ───────────────────────────────────────────────────
// On a right-click in Terminal.app:
//   - There is a SELECTION       -> copy it. Always — clipboard state is
//                                   irrelevant to copying.
//   - No selection, clipboard
//     HAS TEXT                   -> paste the clipboard.
//   - No selection, clipboard
//     EMPTY (or non-text)        -> re-post the click so Terminal's normal
//                                   contextual menu appears (a beat late —
//                                   the price of probing for a selection).
//
// The click is always swallowed first: whether a selection exists can only
// be discovered by trying Cmd+C, which must happen before deciding. An
// earlier design passed empty-clipboard clicks through untouched, but that
// silently broke COPY whenever the clipboard was empty — which, with
// clearClipboardAfterPaste on by default, is most of the time.
//
// Optionally (clearClipboardAfterPaste, ON by default): after a PASTE, the
// system clipboard is cleared, making right-click paste a "consume once"
// action. This is a global side effect — it empties the clipboard for every
// app. It never applies after a copy. The user can turn it off in the menu.
//
// ── Why the "copy first, then check change count" approach ──────────────
// Distinguishing "selection exists" from "no selection" is the hard part:
//
// Terminal.app does NOT expose its selection reliably through the
// Accessibility API — AXSelectedText on Terminal's text area is frequently
// empty even when text is visibly highlighted. So we can't ask "is there a
// selection?" directly with any confidence.
//
// Instead we use Terminal's own Copy command and watch the pasteboard's
// changeCount:
//   1. Record NSPasteboard.general.changeCount.
//   2. Synthesize Cmd+C (Terminal's Copy).
//   3. After a short delay, re-read changeCount.
//      - If it incremented, a selection existed and was just copied. Done.
//      - If it did NOT change, there was no selection. Synthesize Cmd+V
//        to paste.
//
// This is reliable because it leans on Terminal's real Copy behavior rather
// than guessing at its internal state. The only side effect is the expected
// one: copying a selection replaces the clipboard contents.
//
// ── Recursion guard ─────────────────────────────────────────────────────
// We synthesize keyboard events, not mouse events, so the right-mouse tap
// won't see its own output. But we still tag synthesized events with a
// magic userData field and ignore anything carrying it, as defense in depth.

import AppKit
import CoreGraphics
import os.log

final class EventTapController {

    /// Gate diagnostics. Stream in Console.app with subsystem
    /// com.mrbco.RightClickPasteKing — every right-click logs the gate
    /// decision and the window-walk evidence behind it, so a misbehaving
    /// gate can be diagnosed from one captured click instead of guesswork.
    /// .info level so the messages appear in a default Console stream.
    private static let log = Logger(subsystem: "com.mrbco.RightClickPasteKing",
                                    category: "gate")

    // MARK: - Constants

    /// Bundle identifier of Apple's Terminal.app. Both halves of the
    /// gatekeeping check (frontmost-app and window-owner) compare against
    /// this — by bundle ID, never by localized app name.
    private static let terminalBundleID = "com.apple.Terminal"

    /// Magic value stamped into the userData of events we synthesize, so we
    /// can recognize and ignore them if they ever come back around.
    private static let synthesizedEventMagic: Int64 = 0x5452_4350 // "TRCP"

    /// How long to wait after issuing Cmd+C before checking whether the
    /// pasteboard changed. Terminal's copy is effectively synchronous, but a
    /// small delay absorbs scheduling jitter. 60 ms is comfortably enough
    /// without being perceptible.
    private static let copySettleDelay: TimeInterval = 0.060

    /// How long to wait after issuing Cmd+V before clearing the clipboard
    /// (only when clearClipboardAfterPaste is on). The paste must fully land
    /// in Terminal before the pasteboard is emptied out from under it, or the
    /// paste could be truncated. 120 ms is a safe margin — paste of typical
    /// clipboard text is near-instant, but this absorbs a slow machine.
    private static let pasteSettleDelay: TimeInterval = 0.120

    // MARK: - Configuration

    /// When true, the system clipboard is cleared after a right-click PASTE
    /// (never after a copy). Set by AppDelegate from the user's preference at
    /// launch and whenever it's toggled. The user preference defaults to ON;
    /// this initializer value is only the state during the brief window
    /// before AppDelegate pushes the persisted value in.
    ///
    /// This is a global side effect — it empties the clipboard for every
    /// app, not just Terminal.
    var clearClipboardAfterPaste: Bool = true

    // MARK: - State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// True between successful start() and stop().
    private(set) var isRunning: Bool = false

    // MARK: - Public API

    /// True if the tap exists and is currently enabled by the system.
    /// The system can silently disable a tap (timeout, sleep/wake); use
    /// `reenableIfNeeded()` to recover.
    var isTapEnabled: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Install and enable the event tap. Safe to call repeatedly; a no-op if
    /// already running. Requires Accessibility permission to actually succeed.
    func start() {
        guard !isRunning else {
            reenableIfNeeded()
            return
        }
        guard AccessibilityPermission.isGranted else {
            // Caller is responsible for not calling start() without
            // permission, but we guard anyway rather than create a dead tap.
            return
        }

        // We listen for rightMouseDown. We intercept on *down* (not up) so
        // that Terminal never begins showing its own contextual menu.
        let eventMask: CGEventMask = (1 << CGEventType.rightMouseDown.rawValue)

        // `self` is passed through as the tap's userInfo so the C callback
        // can call back into this instance.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,            // .defaultTap = active: we can drop/replace events
            eventsOfInterest: eventMask,
            callback: EventTapController.eventTapCallback,
            userInfo: selfPtr
        ) else {
            // tapCreate returns nil if Accessibility permission is missing or
            // revoked. Leave state clean so a later start() can retry.
            isRunning = false
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            // Extremely unlikely, but if the run loop source can't be made
            // the tap is useless — disable it and leave state clean so a
            // later start() can retry from scratch.
            CGEvent.tapEnable(tap: tap, enable: false)
            isRunning = false
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isRunning = true
    }

    deinit {
        // Defensive: AppDelegate owns this controller for the app's whole
        // lifetime and calls stop() in applicationWillTerminate, but if that
        // ever changes, tearing the tap down here prevents the C callback
        // from being invoked with a dangling unretained self pointer.
        stop()
    }

    /// Disable and tear down the event tap. Safe to call when not running.
    func stop() {
        guard isRunning || eventTap != nil else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        isRunning = false
    }

    /// If the tap exists but the system has disabled it, switch it back on.
    func reenableIfNeeded() {
        guard let tap = eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: - C callback bridge

    /// The CGEventTap C callback. Bridges back to the owning instance and,
    /// for relevant events, into `handleRightMouseDown(...)`.
    private static let eventTapCallback: CGEventTapCallBack = {
        (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in

        guard let userInfo = userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let controller = Unmanaged<EventTapController>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        // The system can disable the tap and notify us via these event types.
        // Re-enable so we keep working after sleep/wake or a slow callback.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            controller.reenableIfNeeded()
            return Unmanaged.passUnretained(event)
        }

        guard type == .rightMouseDown else {
            return Unmanaged.passUnretained(event)
        }

        return controller.handleRightMouseDown(event: event)
    }

    // MARK: - Right-click handling

    /// Decides what to do with a right-mouse-down event.
    /// Returns nil to swallow the event (we handled it), or the event
    /// unmodified to let it pass through to Terminal.
    private func handleRightMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {

        // Ignore any event we synthesized ourselves (defense in depth).
        if event.getIntegerValueField(.eventSourceUserData) == EventTapController.synthesizedEventMagic {
            return Unmanaged.passUnretained(event)
        }

        // Only act when BOTH of these are true:
        //
        //   1. Terminal is the frontmost (focused) application, AND
        //   2. the click actually landed on a Terminal window.
        //
        // Each check covers the other's blind spot. The frontmost check alone
        // fails when another app's borderless overlay sits on top of Terminal,
        // or when Terminal is frontmost but the click lands on a DIFFERENT
        // app's background window (right-clicking a background window does
        // not change focus first — the old frontmost-only gate acted on those
        // clicks and interfered with other apps). The window check alone
        // fails the other way: a right-click on a background Terminal window
        // would pass it, but our synthesized Cmd+C/Cmd+V go to the keyboard
        // FOCUS — the frontmost app — so we'd paste into the wrong app.
        // Requiring both closes both failure modes: we act only when the
        // click is on Terminal and the keystrokes will also land in Terminal.
        let loc = event.location
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        Self.log.info("right-click at (\(loc.x, privacy: .public), \(loc.y, privacy: .public)) frontmost=\(front, privacy: .public)")

        guard isTerminalFrontmost() else {
            Self.log.info("VERDICT: pass through — Terminal is not frontmost")
            return Unmanaged.passUnretained(event)
        }
        guard isClickOnTerminalWindow(event: event) else {
            Self.log.info("VERDICT: pass through — click not on a Terminal window (see walk above)")
            return Unmanaged.passUnretained(event)
        }
        Self.log.info("VERDICT: gates passed — swallowing click, deciding copy/paste")

        // No clipboard gate here — the decision is fully asynchronous.
        //
        // Earlier versions passed the click through when the clipboard was
        // empty ("nothing to paste -> don't take over"). That rule silently
        // broke right-click COPY whenever the clipboard was empty — which,
        // with Clear Clipboard After Paste on by default, is most of the
        // time after any paste. Copying a selection must work regardless of
        // clipboard state, and the only way to know whether a selection
        // exists is to try Cmd+C — which requires swallowing the click
        // first. So: swallow now, decide async. If it turns out there was
        // no selection AND nothing to paste, performCopyOrPaste re-posts
        // this click (stamped, so the check above passes it through) and
        // Terminal's menu appears a beat late — the only case that pays
        // any delay.
        //
        // A copy of the original event is carried along for that re-post;
        // copying preserves location, window targeting, and click state
        // far better than synthesizing from scratch. The CGEventTapProxy is
        // deliberately NOT captured — it is only valid during this callback
        // invocation; all posting uses CGEvent.post(tap:).
        let originalClick = event.copy()
        DispatchQueue.main.async { [weak self] in
            self?.performCopyOrPaste(originalClick: originalClick)
        }

        // Swallow the right-click.
        return nil
    }

    /// True if the right-click `event` landed on a window belonging to
    /// Apple's Terminal.app. One half of the gatekeeping check (the other
    /// half is isTerminalFrontmost — see handleRightMouseDown for why both
    /// are required).
    ///
    /// The check looks at the actual on-screen window stack at the click
    /// point. Ownership is established via the window's owner PID resolved
    /// through NSRunningApplication to a bundle identifier — NOT via
    /// kCGWindowOwnerName, which is the LOCALIZED app name and therefore
    /// fragile on non-English systems.
    ///
    /// Permissions: this reads only window GEOMETRY, LAYER, ALPHA and OWNER
    /// PID from CGWindowList. None of those require Screen Recording
    /// permission and none trigger its prompt (only kCGWindowName / window
    /// CONTENTS are gated by that permission, and we read neither).
    ///
    /// Cost: a single CGWindowList query per right-click. This runs in the
    /// CGEventTap callback's hot path, so it must be fast — and it is: the
    /// query is hundreds of microseconds at most, and the callback only
    /// fires on right-mouse-down (not on every mouse move).
    private func isClickOnTerminalWindow(event: CGEvent) -> Bool {
        let clickLocation = event.location

        let options: CGWindowListOption = [.optionOnScreenOnly,
                                           .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            // The window list query failed (rare). The frontmost gate has
            // already passed by the time we're called, so degrading to the
            // frontmost answer preserves the old (pre-window-check) behavior
            // rather than going dead.
            return isTerminalFrontmost()
        }

        // The list is returned in z-order, front to back. The FIRST visible
        // window whose bounds contain the click point — whatever its layer —
        // is the thing the user actually clicked. We act only if that first
        // hit is a NORMAL-LAYER window owned by Terminal.
        //
        // The layer check must work this way (first-hit decides) and NOT as
        // "skip non-normal layers and keep searching underneath": the Dock,
        // the menu bar, notification banners etc. live in higher layers, and
        // a Terminal window's BOUNDS can extend under the Dock region (tall
        // windows, auto-hidden Dock, restored layouts). Skipping the Dock
        // and matching the Terminal window beneath it would misattribute a
        // Dock click to Terminal — swallowing the click and pasting. The
        // click target is whatever is visually on top at that point, period.
        // The mouse CURSOR is itself a window: the window server draws it
        // as a real entry in this list, at the dedicated cursor window
        // level, with bounds that contain the cursor position — which means
        // its bounds contain THE CLICK POINT ON EVERY CLICK, by definition.
        // Without skipping it, the first-hit rule below would stop at the
        // cursor on every walk, conclude "not a normal-layer Terminal
        // window", and the gate would never pass — silently disabling the
        // entire app. (Exactly that bug shipped briefly.) The level is
        // queried from the system rather than hardcoded.
        let cursorLayer = Int(CGWindowLevelForKey(.cursorWindow))
        Self.log.info("window walk: \(infoList.count, privacy: .public) windows, cursorLevel=\(cursorLayer, privacy: .public)")

        for info in infoList {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? "?"

            // Skip the cursor (see above) — it overlays every click point
            // and is never what the user is clicking ON.
            if layer == cursorLayer {
                Self.log.info("  skip cursor-level window owner=\(ownerName, privacy: .public)")
                continue
            }

            // Skip fully transparent windows. Some apps park invisible
            // (alpha == 0) normal-layer windows over large screen areas;
            // they aren't what the user sees or clicks.
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 {
                continue
            }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            guard bounds.contains(clickLocation) else { continue }

            // First visible window at the click point: this IS the click
            // target. Decide based on it alone — never look underneath.
            Self.log.info("  first hit: owner=\(ownerName, privacy: .public) layer=\(layer, privacy: .public) bounds=(\(Int(bounds.origin.x), privacy: .public),\(Int(bounds.origin.y), privacy: .public) \(Int(bounds.width), privacy: .public)x\(Int(bounds.height), privacy: .public))")

            // kCGWindowLayer 0 == the normal window layer. If the topmost
            // window here is in any other layer (Dock, menu bar, banners,
            // open menus), the click belongs to that UI, not to Terminal.
            guard layer == 0 else {
                Self.log.info("  -> non-normal layer, not Terminal")
                return false
            }

            // Identify the owner by PID -> bundle identifier (locale-proof,
            // unlike the localized kCGWindowOwnerName).
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  let ownerApp = NSRunningApplication(processIdentifier: ownerPID)
            else {
                Self.log.info("  -> owner PID unresolvable, not Terminal")
                return false
            }
            let bundleID = ownerApp.bundleIdentifier ?? "nil"
            let isTerminal = bundleID == EventTapController.terminalBundleID
            Self.log.info("  -> owner bundle=\(bundleID, privacy: .public) terminal=\(isTerminal, privacy: .public)")
            return isTerminal
        }

        Self.log.info("  -> no visible window contained the click point")

        // Click didn't land on any visible normal-layer window (e.g. clicked
        // on the desktop, the Dock, or between windows). Not on Terminal.
        return false
    }

    /// True if Apple's Terminal is the frontmost (focused) application —
    /// i.e. the app that will receive our synthesized keystrokes. One half
    /// of the gatekeeping check (see handleRightMouseDown). Also serves as
    /// the degraded answer when the window-list query fails.
    private func isTerminalFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return front.bundleIdentifier == EventTapController.terminalBundleID
    }

    /// Implements the decision logic described in the file header:
    ///   selection exists                      -> copy (always)
    ///   no selection, clipboard has text      -> paste
    ///   no selection, clipboard empty/no text -> re-post the original click
    ///                                            so Terminal's menu appears
    /// Runs on the main queue, after the tap callback has returned — so it
    /// must not use the CGEventTapProxy (only valid inside the callback);
    /// all events are posted via CGEvent.post(tap:).
    private func performCopyOrPaste(originalClick: CGEvent?) {
        let pasteboard = NSPasteboard.general
        let changeCountBeforeCopy = pasteboard.changeCount

        // Step 1: issue Cmd+C. If Terminal has a selection, this populates
        // the pasteboard (incrementing changeCount). If not, it's a no-op.
        synthesizeKeystroke(keyCode: EventTapController.keyCode_C,
                            command: true)

        // Step 2: after a short settle delay, see whether the pasteboard moved.
        DispatchQueue.main.asyncAfter(deadline: .now() + EventTapController.copySettleDelay) {
            let changeCountAfterCopy = pasteboard.changeCount

            if changeCountAfterCopy != changeCountBeforeCopy {
                Self.log.info("decision: selection copied")
                // A selection existed and was copied. Behavior complete:
                // right-click-with-selection == copy, regardless of what the
                // clipboard held before. The clipboard is NOT cleared here —
                // clearClipboardAfterPaste applies to pastes only; clearing
                // what was just copied would be nonsensical.
                return
            }

            // No selection. If the clipboard holds text, paste it. This is
            // the first time we actually READ the clipboard contents (off
            // the tap callback, where a slow promised-data render can't
            // hurt anyone but us).
            guard EventTapController.clipboardHasText(pasteboard) else {
                // No selection AND nothing to paste: the one case where the
                // app has no job. Give the user what they expect from a
                // dead-end right-click — Terminal's own contextual menu —
                // by re-posting the click we swallowed. The re-posted event
                // is stamped with our magic, so handleRightMouseDown passes
                // it straight through instead of intercepting it again.
                Self.log.info("decision: no selection, clipboard empty — re-posting click for Terminal's menu")
                self.repostOriginalClick(originalClick)
                return
            }

            Self.log.info("decision: no selection, clipboard has text — pasting")
            self.synthesizeKeystroke(keyCode: EventTapController.keyCode_V,
                                     command: true)

            // Step 3 (optional): if enabled, clear the system clipboard after
            // the paste — making right-click paste a "consume once" action.
            // We wait pasteSettleDelay first so the Cmd+V has fully landed in
            // Terminal before the pasteboard is emptied; the clipboard
            // contents are read by the paste, so clearing too early could
            // truncate it.
            if self.clearClipboardAfterPaste {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + EventTapController.pasteSettleDelay
                ) {
                    // Only clear if the pasteboard is still the one we
                    // pasted. If its changeCount moved during the settle
                    // delay, the user (or another app) put something NEW on
                    // the clipboard — destroying that fresh copy would be
                    // data loss, so we leave it alone.
                    guard pasteboard.changeCount == changeCountBeforeCopy else {
                        return
                    }
                    // clearContents() empties the pasteboard for ALL apps —
                    // that's the documented, intended behavior of this option.
                    pasteboard.clearContents()
                }
            }
        }
    }

    /// Re-posts the right-click we swallowed, so Terminal shows its normal
    /// contextual menu. The down event is the COPY of the original (made in
    /// the tap callback — preserves location, window targeting, click
    /// state); the matching up is synthesized at the same location. Both
    /// are stamped so our own tap passes them through. The user's physical
    /// mouse-up already passed through long ago (the tap only intercepts
    /// downs); a stray up with no down is harmless, and context menus open
    /// on the down, so the re-posted pair reads as a normal right-click.
    private func repostOriginalClick(_ originalClick: CGEvent?) {
        guard let down = originalClick else { return }

        down.setIntegerValueField(.eventSourceUserData,
                                  value: EventTapController.synthesizedEventMagic)

        let location = down.location
        guard let up = CGEvent(mouseEventSource: nil,
                               mouseType: .rightMouseUp,
                               mouseCursorPosition: location,
                               mouseButton: .right) else {
            // Couldn't make the up half — post the down alone; the menu
            // still opens on the down.
            down.post(tap: .cgSessionEventTap)
            return
        }
        up.setIntegerValueField(.eventSourceUserData,
                                value: EventTapController.synthesizedEventMagic)

        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    // MARK: - Clipboard inspection

    /// True if the pasteboard currently holds a non-empty string. READS THE
    /// CONTENTS — which can block on the source app rendering promised data —
    /// so this must never be called from the tap callback; main-queue async
    /// paths only.
    private static func clipboardHasText(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        // Accept the standard string type. Terminal pastes plain text.
        if types.contains(.string),
           let s = pasteboard.string(forType: .string),
           !s.isEmpty {
            return true
        }
        return false
    }

    // MARK: - Keystroke synthesis

    // Virtual key codes (ANSI layout). These are layout-position constants,
    // not character codes, so they are correct regardless of keyboard locale.
    private static let keyCode_C: CGKeyCode = 0x08
    private static let keyCode_V: CGKeyCode = 0x09

    /// Synthesize a key-down + key-up pair for `keyCode`, optionally with the
    /// Command modifier held. Events are posted at the session event tap
    /// location via CGEvent.post(tap:) — NOT via CGEventTapProxy, which is
    /// only valid inside the tap callback and this method runs after it has
    /// returned. The events are stamped with our magic userData so we can
    /// recognize them later. Recursion is impossible regardless: our tap
    /// listens only for rightMouseDown, so keyboard events never re-enter it.
    private func synthesizeKeystroke(keyCode: CGKeyCode,
                                     command: Bool) {
        // A dedicated event source. .privateState keeps our synthetic
        // modifier flags from leaking into / colliding with the real
        // hardware keyboard state.
        guard let source = CGEventSource(stateID: .privateState) else {
            return
        }

        let flags: CGEventFlags = command ? .maskCommand : []

        guard let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: keyCode,
                                    keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: keyCode,
                                  keyDown: false) else {
            return
        }

        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.setIntegerValueField(.eventSourceUserData,
                                     value: EventTapController.synthesizedEventMagic)
        keyUp.setIntegerValueField(.eventSourceUserData,
                                   value: EventTapController.synthesizedEventMagic)

        // Session-level post: the events are delivered to the current
        // session's keyboard focus, which the handleRightMouseDown gate has
        // already verified is Terminal.
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }
}
