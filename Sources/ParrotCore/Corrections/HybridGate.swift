import Foundation

/// Hybrid learning adds rows on its own only after the user's own decisions
/// show that its proposals are right (ADR-006).
///
/// The automatic group is every decided pair whose first proposal held
/// `replace`: that is what hybrid would add without asking. Its precision
/// is the share the user accepted with `replace`. The gate opens at 95%
/// over at least 20 such decisions.
enum HybridGate {
    static let minPrecision = 0.95
    static let minDecisions = 20

    struct Status: Equatable {
        var decisions: Int
        var accepted: Int

        var precision: Double { decisions == 0 ? 0 : Double(accepted) / Double(decisions) }
        var isOpen: Bool { decisions >= HybridGate.minDecisions && precision >= HybridGate.minPrecision }

        var summary: String {
            let share = String(format: "%.0f%%", precision * 100)
            return isOpen
                ? "Automatic adds are on: \(share) right over \(decisions) reviews."
                : "Automatic adds wait: \(share) right over \(decisions) reviews; they need \(Int(HybridGate.minPrecision * 100))% over \(HybridGate.minDecisions)."
        }
    }

    static func status(_ pairs: [LearnedPair]) -> Status {
        let decided = pairs.filter {
            ($0.status == .added || $0.status == .rejected || $0.status == .suspect) && ($0.proposed ?? []).contains(.replace)
        }
        let accepted = decided.filter { $0.status == .added && $0.rules.contains(.replace) }
        return Status(decisions: decided.count, accepted: accepted.count)
    }
}
