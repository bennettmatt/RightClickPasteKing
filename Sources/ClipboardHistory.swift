// ClipboardHistory.swift
// RightClickPasteKing
//
// Keeps the most recent text copies in an in-memory buffer so they can be
// re-selected from the menu bar — the recovery path for the app's own
// "clear clipboard after paste" behavior, and a small convenience besides.
//
// ── How it watches ───────────────────────────────────────────────────────
// NSPasteboard has no change notification, so like every clipboard utility
// on macOS this polls `changeCount` on a timer. Unlike SMAppService.status
// (the XPC-per-call mistake this project already made once), changeCount is
// designed for exactly this kind of cheap, frequent polling.
//
// ── Privacy rules (non-negotiable) ──────────────────────────────────────
//   * Entries live in MEMORY ONLY. Nothing is ever written to disk; quit
//     the app and the history is gone.
//   * Pasteboard contents marked with the standard concealed or transient
//     types (the nspasteboard.org convention used by password managers and
//     the like) are NEVER recorded — the change is observed and skipped.
//   * Only plain text is recorded. Images, files, rich content: ignored.

import AppKit

final class ClipboardHistory {

    // MARK: - Configuration

    /// Maximum number of entries retained, newest first.
    static let capacity = 10

    /// Poll interval. Every clipboard manager polls in this range; the
    /// tolerance lets the system coalesce the timer with other wakeups.
    private static let pollInterval: TimeInterval = 0.8

    /// Pasteboard marker types (nspasteboard.org convention) whose presence
    /// means "do not record this". Concealed = secrets (password managers);
    /// transient = ephemeral data not meant for history.
    private static let excludedMarkerTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    /// Entries longer than this are not recorded — multi-megabyte copies
    /// (logs, file dumps) would bloat memory and are useless as menu items.
    private static let maxEntryLength = 100_000

    // MARK: - State

    /// The pasteboard being watched. NSPasteboard.general in the app;
    /// tests inject isolated private pasteboards so they never touch (or
    /// depend on) the user's real clipboard.
    private let pasteboard: NSPasteboard

    /// Newest first. Memory only — never persisted.
    private(set) var entries: [String] = []

    /// Fired on the main thread whenever the clipboard transitions between
    /// "has text" and "empty/non-text" (also once at start() with the
    /// initial state). Drives the menu bar icon tint. The Bool is "the
    /// clipboard currently advertises a string type" — deliberately the
    /// same test the right-click gate uses, so the tint means exactly
    /// "right-click would paste".
    var onTextStateChange: ((Bool) -> Void)?

    private var pollTimer: Timer?
    private var lastSeenChangeCount: Int

    /// Last reported value of "clipboard has a string type", so the
    /// callback fires only on transitions.
    private var lastHasText: Bool = false

    /// Set while we ourselves write to the pasteboard (select(_:)), so the
    /// next poll tick doesn't re-process our own write.
    private var ignoreNextChange = false

    /// `pasteboard` defaults to the system clipboard; tests pass an
    /// isolated NSPasteboard(name:) instead.
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastSeenChangeCount = pasteboard.changeCount
    }

    // MARK: - Lifecycle

    /// Begins watching the pasteboard. Idempotent.
    func start() {
        guard pollTimer == nil else { return }
        // Capture the current count so pre-existing clipboard contents are
        // not retroactively recorded — we only record changes from now on.
        lastSeenChangeCount = pasteboard.changeCount

        // Report the INITIAL text state so the icon tint is correct from
        // launch, even though pre-existing contents aren't recorded.
        lastHasText = Self.hasStringType(pasteboard)
        onTextStateChange?(lastHasText)

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        timer.tolerance = Self.pollInterval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Stops watching. The buffer is kept (it's only memory; quit clears it).
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit {
        stop()
    }

    // MARK: - Public operations

    /// Puts `text` on the system clipboard and moves it to the top of the
    /// history (the natural "most recently used" order). Identified by
    /// value, not index: the history can shift while a menu referencing it
    /// is open (the watcher's timer runs in menu-tracking mode), so an
    /// index captured at menu-build time can go stale — the string itself
    /// cannot. If the entry has meanwhile been evicted from the buffer,
    /// the clipboard is still set; that's the half the user observes.
    func select(text: String) {
        if let existing = entries.firstIndex(of: text) {
            entries.remove(at: existing)
        }
        entries.insert(text, at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }

        ignoreNextChange = true
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Empties the history buffer. Does not touch the clipboard itself.
    func clear() {
        entries.removeAll()
    }

    // MARK: - Polling

    /// One poll step. Internal (not private) so unit tests can drive the
    /// watcher deterministically without the timer.
    func pollTick() {
        let count = pasteboard.changeCount
        guard count != lastSeenChangeCount else { return }
        lastSeenChangeCount = count

        // Tint state first, on EVERY change — including our own writes and
        // concealed content the recorder below skips. The tint reflects
        // "does the clipboard have a string type", which is true for a
        // password manager's concealed copy too (right-click would paste
        // it); revealing non-emptiness is not revealing content.
        let hasText = Self.hasStringType(pasteboard)
        if hasText != lastHasText {
            lastHasText = hasText
            onTextStateChange?(hasText)
        }

        // Our own select(_:) write — already at the top of the buffer.
        if ignoreNextChange {
            ignoreNextChange = false
            return
        }

        guard let types = pasteboard.types else { return }

        // Privacy: never record concealed or transient content.
        for marker in Self.excludedMarkerTypes where types.contains(marker) {
            return
        }

        // Text only, non-empty, sane size.
        guard types.contains(.string),
              let text = pasteboard.string(forType: .string),
              !text.isEmpty,
              text.count <= Self.maxEntryLength else {
            return
        }

        record(text)
    }

    /// Cheap type-metadata check (never reads contents — same rule as the
    /// event tap's gate).
    private static func hasStringType(_ pasteboard: NSPasteboard) -> Bool {
        return pasteboard.types?.contains(.string) ?? false
    }

    /// Inserts at the top; an identical existing entry is moved up rather
    /// than duplicated; the buffer is trimmed to capacity.
    private func record(_ text: String) {
        if let existing = entries.firstIndex(of: text) {
            entries.remove(at: existing)
        }
        entries.insert(text, at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
    }

    // MARK: - Menu previews

    /// A single-line, length-capped preview of an entry for menu display:
    /// whitespace runs (including newlines) collapse to single spaces, then
    /// the result is truncated with an ellipsis.
    static func preview(of text: String, maxLength: Int = 40) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxLength {
            return collapsed
        }
        return String(collapsed.prefix(maxLength)) + "…"
    }
}
