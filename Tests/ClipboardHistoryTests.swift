// ClipboardHistoryTests.swift
// RightClickPasteKingTests
//
// Unit tests for the recent-copies buffer. Each test uses a freshly named
// private NSPasteboard, so tests are isolated from each other AND from the
// user's real clipboard — running the suite never touches your copy buffer.
//
// The watcher's Timer is never started in tests; pollTick() is driven
// directly, which makes every test deterministic.

import XCTest
import AppKit

final class ClipboardHistoryTests: XCTestCase {

    private var pasteboard: NSPasteboard!
    private var history: ClipboardHistory!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("rcpk-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        history = ClipboardHistory(pasteboard: pasteboard)
    }

    override func tearDown() {
        history = nil
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func writeConcealed(_ text: String) {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("1", forType: concealed)
    }

    // MARK: - Recording

    func testRecordsCopies() {
        write("alpha")
        history.pollTick()
        write("beta")
        history.pollTick()
        XCTAssertEqual(history.entries, ["beta", "alpha"])
    }

    func testNoChangeNoRecord() {
        write("alpha")
        history.pollTick()
        history.pollTick() // changeCount unchanged — must not duplicate
        XCTAssertEqual(history.entries, ["alpha"])
    }

    func testDedupeMovesExistingToTop() {
        write("alpha"); history.pollTick()
        write("beta");  history.pollTick()
        write("alpha"); history.pollTick()
        XCTAssertEqual(history.entries, ["alpha", "beta"])
    }

    func testCapacityIsEnforcedNewestKept() {
        for i in 1...(ClipboardHistory.capacity + 3) {
            write("entry-\(i)")
            history.pollTick()
        }
        XCTAssertEqual(history.entries.count, ClipboardHistory.capacity)
        XCTAssertEqual(history.entries.first, "entry-\(ClipboardHistory.capacity + 3)")
        XCTAssertFalse(history.entries.contains("entry-1"))
    }

    func testEmptyStringNotRecorded() {
        write("")
        history.pollTick()
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testOversizeEntryNotRecorded() {
        write(String(repeating: "x", count: 100_001))
        history.pollTick()
        XCTAssertTrue(history.entries.isEmpty)
    }

    // MARK: - Privacy

    func testConcealedContentNeverRecorded() {
        writeConcealed("hunter2")
        history.pollTick()
        XCTAssertTrue(history.entries.isEmpty,
                      "password-manager (concealed) content must never enter history")
    }

    func testTransientContentNeverRecorded() {
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        pasteboard.declareTypes([.string, transient], owner: nil)
        pasteboard.setString("ephemeral", forType: .string)
        pasteboard.setString("1", forType: transient)
        history.pollTick()
        XCTAssertTrue(history.entries.isEmpty)
    }

    // MARK: - Selection

    func testSelectWritesPasteboardAndMovesToTop() {
        write("alpha"); history.pollTick()
        write("beta");  history.pollTick()

        history.select(text: "alpha")

        XCTAssertEqual(pasteboard.string(forType: .string), "alpha")
        XCTAssertEqual(history.entries, ["alpha", "beta"])
    }

    func testSelectOwnWriteNotReRecorded() {
        write("alpha"); history.pollTick()
        write("beta");  history.pollTick()
        history.select(text: "alpha")
        history.pollTick() // sees our own write; must skip via ignoreNextChange
        XCTAssertEqual(history.entries, ["alpha", "beta"])
    }

    func testSelectUnknownTextStillSetsPasteboard() {
        history.select(text: "ghost")
        XCTAssertEqual(pasteboard.string(forType: .string), "ghost")
        XCTAssertEqual(history.entries.first, "ghost")
    }

    // MARK: - Clear

    func testClearEmptiesHistoryNotPasteboard() {
        write("alpha"); history.pollTick()
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "alpha",
                       "clearing history must not touch the clipboard itself")
    }

    // MARK: - Text-state callback (drives the purple icon)

    func testTextStateTransitionsFire() {
        var reported: [Bool] = []
        history.onTextStateChange = { reported.append($0) }

        write("alpha")
        history.pollTick()              // empty -> has text
        pasteboard.clearContents()
        history.pollTick()              // has text -> empty
        write("beta")
        history.pollTick()              // empty -> has text
        write("gamma")
        history.pollTick()              // has text -> has text: NO event

        XCTAssertEqual(reported, [true, false, true])
    }

    func testConcealedContentStillTintsIcon() {
        // Concealed content is never RECORDED, but the clipboard genuinely
        // has text — right-click would paste it — so the tint must reflect
        // that. Non-emptiness is not content.
        var reported: [Bool] = []
        history.onTextStateChange = { reported.append($0) }
        writeConcealed("hunter2")
        history.pollTick()
        XCTAssertEqual(reported, [true])
        XCTAssertTrue(history.entries.isEmpty)
    }

    // MARK: - Preview

    func testPreviewCollapsesWhitespaceAndNewlines() {
        XCTAssertEqual(ClipboardHistory.preview(of: "  a\n\n b\t\tc  "), "a b c")
    }

    func testPreviewTruncatesWithEllipsis() {
        let long = String(repeating: "abcde ", count: 20)
        let preview = ClipboardHistory.preview(of: long, maxLength: 10)
        XCTAssertEqual(preview.count, 11) // 10 chars + ellipsis
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    func testPreviewShortStringUnchanged() {
        XCTAssertEqual(ClipboardHistory.preview(of: "short"), "short")
    }
}
