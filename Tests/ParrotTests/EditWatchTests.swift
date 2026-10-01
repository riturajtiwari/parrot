import XCTest
@testable import ParrotCore

/// Replays sequences of field states through the edit watcher. Made-up
/// words only.
final class EditWatchTests: XCTestCase {
    private let pasted = " ping the kwilbo team today "
    private let prefix = "Hi all,"

    private func watch() -> EditWatch {
        EditWatch(pasted: pasted, expected: (prefix as NSString).length, at: 0)
    }

    private func field(_ text: String, focused: Bool = true, placeholder: String? = nil) -> FieldState {
        FieldState(text: text, focused: focused, placeholder: placeholder)
    }

    func testLearnsACorrectionOnceItIsStable() {
        var w = watch()
        XCTAssertEqual(w.step(field(prefix + pasted), at: 0.3), .following)
        XCTAssertEqual(w.step(field(prefix + " ping the Qwilbo team today "), at: 1), .following)
        XCTAssertEqual(w.step(field(prefix + " ping the Qwilbo team today "), at: 1.5), .following)
        XCTAssertEqual(w.finish(.nextDictation), .ended(.nextDictation, [WordChange(heard: ["kwilbo"], corrected: ["Qwilbo"])]))
    }

    func testAHalfTypedWordIsNeverLearned() {
        var w = watch()
        _ = w.step(field(prefix + pasted), at: 0.3)
        // Still typing: never the same twice before the message is sent.
        _ = w.step(field(prefix + " ping the Q team today "), at: 1)
        _ = w.step(field(prefix + " ping the Qw team today "), at: 1.5)
        XCTAssertEqual(w.step(field("", placeholder: "Message #general"), at: 2), .ended(.emptied, []))
    }

    func testASentMessageUsesTheLastStableRead() {
        var w = watch()
        _ = w.step(field(prefix + pasted), at: 0.3)
        _ = w.step(field(prefix + " ping the Qwilbo team today "), at: 1)
        _ = w.step(field(prefix + " ping the Qwilbo team today "), at: 1.5)
        XCTAssertEqual(w.step(field("Message #general", placeholder: "Message #general"), at: 2),
                       .ended(.emptied, [WordChange(heard: ["kwilbo"], corrected: ["Qwilbo"])]))
    }

    func testTextTypedBeforeTheRegionDoesNotMatter() {
        var w = watch()
        _ = w.step(field(prefix + pasted), at: 0.3)
        let moved = "Hello everyone. " + prefix + " ping the Qwilbo team today "
        _ = w.step(field(moved), at: 1)
        _ = w.step(field(moved), at: 1.5)
        XCTAssertEqual(w.finish(.focusChanged), .ended(.focusChanged, [WordChange(heard: ["kwilbo"], corrected: ["Qwilbo"])]))
    }

    func testAnEditedAnchorEndsTheWatchAfterSeveralReads() {
        var w = watch()
        _ = w.step(field(prefix + pasted), at: 0.3)
        let edited = field("Hey all," + " ping the Qwilbo team today ")
        for read in 1..<5 { XCTAssertEqual(w.step(edited, at: Double(read)), .following) }
        XCTAssertEqual(w.step(edited, at: 5), .ended(.anchorLost, []))
        XCTAssertEqual(w.lastMiss, "before")
    }

    func testAMissedReadDoesNotEndTheWatch() {
        var w = watch()
        _ = w.step(field(prefix + pasted), at: 0.3)
        // A busy app misses a read now and then.
        XCTAssertEqual(w.step(nil, at: 0.7), .following)
        XCTAssertEqual(w.step(field(prefix + " ping the Qwilbo team today "), at: 1), .following)
        XCTAssertEqual(w.step(field(prefix + " ping the Qwilbo team today "), at: 1.5), .following)
        XCTAssertEqual(w.finish(.nextDictation), .ended(.nextDictation, [WordChange(heard: ["kwilbo"], corrected: ["Qwilbo"])]))
    }

    func testAFieldThatStaysUnreadableEndsTheWatch() {
        var w = watch()
        _ = w.step(field(prefix + pasted), at: 0.3)
        for read in 1..<5 { XCTAssertEqual(w.step(nil, at: 0.3 + Double(read) * 0.4), .following) }
        XCTAssertEqual(w.step(nil, at: 2.5), .ended(.unreadable, []))
        XCTAssertEqual(w.lastMiss, "read")
    }

    func testARewriteLearnsNothing() {
        var w = watch()
        _ = w.step(field(prefix + pasted), at: 0.3)
        XCTAssertEqual(w.step(field(prefix + " actually never mind that "), at: 1), .ended(.rewritten, []))
    }

    func testAFocusChangeEndsTheWatch() {
        var w = watch()
        _ = w.step(field(prefix + pasted), at: 0.3)
        XCTAssertEqual(w.step(field(prefix + pasted, focused: false), at: 1), .ended(.focusChanged, []))
    }

    func testAPasteThatNeverAppearsEndsTheWatch() {
        var w = watch()
        XCTAssertEqual(w.step(field(prefix), at: 0.5), .waiting)
        XCTAssertEqual(w.step(field(prefix), at: 2), .ended(.notFound, []))
    }

    func testIdleAndTimeLimits() {
        var w = watch()
        _ = w.step(field(prefix + pasted), at: 0.3)
        _ = w.step(field(prefix + " ping the Qwilbo team today "), at: 1)
        _ = w.step(field(prefix + " ping the Qwilbo team today "), at: 1.5)
        XCTAssertEqual(w.step(field(prefix + " ping the Qwilbo team today "), at: 22), .ended(.idle, [WordChange(heard: ["kwilbo"], corrected: ["Qwilbo"])]))

        var long = watch()
        _ = long.step(field(prefix + pasted), at: 0.3)
        XCTAssertEqual(long.step(field(prefix + pasted), at: 61), .ended(.timeUp, []))
    }

    func testWordsTypedAfterAPasteAtTheEndAreNotACorrection() {
        var w = EditWatch(pasted: " fix the kwilbo", expected: 5, at: 0)
        _ = w.step(field("Note: fix the kwilbo"), at: 0.3)
        let typed = "Note: fix the Qwilbo thanks"
        _ = w.step(field(typed), at: 1)
        _ = w.step(field(typed), at: 1.5)
        XCTAssertEqual(w.finish(.nextDictation), .ended(.nextDictation, []))
    }
}
