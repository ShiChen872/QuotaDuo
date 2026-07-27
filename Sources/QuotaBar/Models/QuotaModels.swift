import Foundation

enum ProviderID: String, Sendable, CaseIterable {
    case codex
    case cursor

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }
}

struct UsageLine: Identifiable, Sendable, Equatable {
    var id: String { label }
    let label: String
    /// Used percentage in 0...100
    let usedPercent: Double
    let resetsAt: Date?
    let subtitle: String?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct ProviderUsage: Identifiable, Sendable, Equatable {
    var id: String { providerId.rawValue }
    let providerId: ProviderID
    let plan: String?
    let lines: [UsageLine]
    let fetchedAt: Date
    let detail: String?

    var lowestRemainingPercent: Double? {
        lines.map(\.remainingPercent).min()
    }
}

enum ProviderLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded(ProviderUsage)
    case unavailable(String)
}

extension Double {
    var clampedPercent: Double { max(0, min(100, self)) }
}
