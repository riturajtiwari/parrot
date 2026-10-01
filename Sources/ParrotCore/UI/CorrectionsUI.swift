import AppKit

/// Fix Word, the review window, Undo and the learning notice (ADR-006),
/// wired to the menu bar and to the "Fix Word in Parrot" service.
@MainActor
final class CorrectionsUI {
    private let menuBar: MenuBarController
    private let actions = CorrectionActions()
    private let fixWord = FixWordPanel()
    private let review: ReviewWindow
    private let settings: SettingsStore?
    /// Above the recording pill; a dictation observer, so a dictation hides it.
    let notice = LearningNotice()
    /// The service provider; `NSApp.servicesProvider` holds it weakly, so
    /// this keeps it alive.
    let service = FixWordService()

    /// `settings` lets Review Corrections edit the example sentence.
    init(menuBar: MenuBarController, settings: SettingsStore? = nil) {
        self.menuBar = menuBar
        self.settings = settings
        review = ReviewWindow(settings: settings)
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

    /// Opens Review Corrections, for example after a Wispr Flow import.
    func showReview() {
        review.show()
        refresh()
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

    // MARK: - The learning notice

    /// Says what the learner made of an edit, unless the user turned the
    /// notices off: Add or Not this for a question, Undo for an add.
    func present(_ outcomes: [EditLearner.Outcome]) {
        refresh()
        guard settings?.current.corrections.showNotices ?? true, let plan = LearningNoticePlan.plan(outcomes) else { return }
        switch plan.kind {
        case .added:
            guard let pair = plan.pair else { return }
            notice.show(.init(symbol: "book.closed", text: plan.text, actions: [
                .init(title: "Undo") { [weak self] in self?.undo(pair) },
            ], duration: plan.duration))
        case .ask:
            guard let pair = plan.pair else { return }
            notice.show(.init(symbol: "sparkles", text: plan.text, actions: [
                .init(title: "Add", primary: true) { [weak self] in self?.accept(pair) },
                .init(title: "Not this") { [weak self] in self?.reject(pair) },
            ], duration: plan.duration))
        case .reverted:
            notice.show(.init(symbol: "arrow.uturn.backward", text: plan.text, actions: [
                .init(title: "Review") { [weak self] in self?.showReview() },
            ], duration: plan.duration))
        case .notLearned:
            notice.show(.init(symbol: "eye", text: plan.text, duration: plan.duration, faint: true))
        }
    }

    /// Add on a question: the proposed rules, into the user's dictionary,
    /// like Accept in Review Corrections.
    private func accept(_ pair: LearnedPair) {
        let change = WordChange(heard: pair.heard.map { WordDiff.words($0).map(\.text) } ?? [],
                                corrected: WordDiff.words(pair.word).map(\.text))
        do {
            try actions.accept(change, rules: Set(pair.rules), source: pair.sources.first ?? .watched, seen: pair.seen)
            notice.show(.init(symbol: "checkmark", text: "Added “\(pair.word)”", duration: 1.5))
        } catch {
            notice.show(.init(symbol: "exclamationmark.triangle", text: "Not added: \(error)", duration: 3))
        }
        refresh()
    }

    /// Not this on a question: never proposed again.
    private func reject(_ pair: LearnedPair) {
        do {
            try actions.reject(word: pair.word, heard: pair.heard)
            notice.show(.init(symbol: "xmark", text: "Parrot won't suggest “\(pair.word)” again", duration: 1.5))
        } catch {
            Log.warning("reject failed: \(error)")
        }
        refresh()
    }

    /// Undo on an add: removes what it wrote.
    private func undo(_ pair: LearnedPair) {
        do {
            try actions.undo(pair)
            notice.show(.init(symbol: "arrow.uturn.backward", text: "Undone", duration: 1.5))
        } catch {
            notice.show(.init(symbol: "exclamationmark.triangle", text: "Couldn't undo: \(error)", duration: 3))
        }
        refresh()
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
