import Foundation

enum ProviderID: String, Sendable, CaseIterable, Identifiable {
    case codex
    case cursor
    case claude
    case skywork

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .claude: return "Claude"
        case .skywork: return "Skywork"
        }
    }

    /// Compact prefix for the menu bar (C / X / A / S).
    var menuBarPrefix: String {
        switch self {
        case .codex: return "C"
        case .cursor: return "X"
        case .claude: return "A"
        case .skywork: return "S"
        }
    }

    /// Labels that drive the menu-bar percentage for this provider.
    var primaryLabels: Set<String> {
        switch self {
        case .codex: return ["Session", "Weekly"]
        case .cursor: return ["Plan"]
        case .claude: return ["Session", "Weekly"]
        case .skywork: return ["月度"]
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

    /// Lowest remaining among primary lines; falls back to all lines.
    var primaryRemainingPercent: Double? {
        let primary = lines.filter { providerId.primaryLabels.contains($0.label) }
        let pool = primary.isEmpty ? lines : primary
        return pool.map(\.remainingPercent).min()
    }

    var lowestRemainingPercent: Double? {
        lines.map(\.remainingPercent).min()
    }
}

enum ProviderLoadState: Sendable, Equatable {
    /// No local credentials — do not reserve UI space.
    case hidden
    case idle
    case loading
    case loaded(ProviderUsage)
    case unavailable(String)
}

struct ProviderSlot: Identifiable, Sendable, Equatable {
    let id: ProviderID
    var state: ProviderLoadState
    var softError: String?

    var isVisible: Bool {
        if case .hidden = state { return false }
        return true
    }
}

enum AuthErrorDetector {
    static func isAuthUnavailable(_ error: Error) -> Bool {
        if let error = error as? CodexError, case .authUnavailable = error { return true }
        if let error = error as? CursorError, case .authUnavailable = error { return true }
        if let error = error as? ClaudeError, case .authUnavailable = error { return true }
        if let error = error as? SkyworkError, case .authUnavailable = error { return true }
        return false
    }
}

extension Double {
    var clampedPercent: Double { max(0, min(100, self)) }
}
