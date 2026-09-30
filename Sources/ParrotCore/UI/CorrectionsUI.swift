import AppKit

/// Fix Word, the review window and Undo (ADR-006), wired to the menu bar
/// and to the "Fix Word in Parrot" service.
@MainActor
final class CorrectionsUI {
    private let menuBar: MenuBarController
    private let actions = CorrectionActions()
    private let fixWord = FixWordPanel()
    private let review = ReviewWindow()
    /// The service provider; `NSApp.servicesProvider` holds it weakly, so
    /// this keeps it alive.
    let service = FixWordService()

    init(menuBar: MenuBarController) {
        self.menuBar = menuBar
        fixWord.onAdd = { [weak self] change, rules in self?.add(change, rules) }
        review.onChange = { [weak self] in self?.refresh() }
        service.onText = { [weak self] text in self?.fixWord.show(heard: text) }
        menuBar.onFixWord = { [weak self] in self?.fixWordFromSelection() }
        menuBar.onReview = { [weak self] in self?.review.show() }
        menuBar.onUndoLearned = { [weak self] in self?.undoLast() }
        menuBar.onMenuOpen = { [weak self] in self?.refresh() }
        refresh()
    }

    /// Opens Fix Word with the selection of the app the user is in. The
    /// menu is open over that app, so its focused element still holds the
    /// selection.
    func fixWordFromSelection() {
        fixWord.show(heard: FocusSnapshot.selectedWords() ?? "")
    }

    func refresh() {
        let pending = (try? actions.pendingCount()) ?? 0
        menuBar.setReviewCount(pending)
        menuBar.setLastLearned((try? actions.added().first)?.word)
    }

    private func add(_ change: WordChange, _ rules: Set<CorrectionRule>) -> String? {
        do {
            try actions.accept(change, rules: rules, source: .fixWord)
            Log.info("fix word: added \(rules.count) rule(s)")
            refresh()
            return nil
        } catch {
            return "Not added: \(error)"
        }
    }

    private func undoLast() {
        guard let last = try? actions.added().first else { return }
        do {
            try actions.undo(last)
            refresh()
        } catch {
            Log.warning("undo failed: \(error)")
        }
    }
}

/// The "Fix Word in Parrot" service (Info.plist `NSServices`): the user
/// selects a word in any app and picks the service, or its shortcut from
/// System Settings → Keyboard → Keyboard Shortcuts → Services. No event tap.
final class FixWordService: NSObject {
    var onText: ((String) -> Void)?

    @objc(fixWord:userData:error:)
    func fixWord(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words = LearnedPair.isStorable(text) ? text : ""
        DispatchQueue.main.async { self.onText?(words) }
    }
}
