import Foundation
import Observation

@MainActor
@Observable
final class QuotaStore {
    private(set) var slots: [ProviderID: ProviderSlot] = Dictionary(
        uniqueKeysWithValues: ProviderID.allCases.map {
            ($0, ProviderSlot(id: $0, state: .idle, softError: nil))
        }
    )

    var isRefreshing = false
    /// Last time at least one provider refreshed successfully.
    var lastSuccessfulRefreshAt: Date?
    var lastAttemptAt: Date?

    private let codexClient = CodexClient()
    private let cursorClient = CursorClient()
    private let claudeClient = ClaudeClient()
    private let skyworkClient = SkyworkClient()
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 5 * 60

    /// Providers that should occupy panel space (configured / loaded / error).
    var visibleSlots: [ProviderSlot] {
        ProviderID.allCases.compactMap { id in
            guard let slot = slots[id], slot.isVisible else { return nil }
            return slot
        }
    }

    /// Compact menu-bar text, e.g. "C81·X79·A72" or "81%".
    var menuBarText: String? {
        var parts: [String] = []
        for id in ProviderID.allCases {
            guard case .loaded(let usage) = slots[id]?.state,
                  let value = usage.primaryRemainingPercent else { continue }
            parts.append("\(id.menuBarPrefix)\(Int(value.rounded()))")
        }
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 {
            return "\(parts[0].dropFirst())%"
        }
        return parts.joined(separator: "·")
    }

    var menuBarLowestPrimary: Double? {
        ProviderID.allCases.compactMap { id -> Double? in
            guard case .loaded(let usage) = slots[id]?.state else { return nil }
            return usage.primaryRemainingPercent
        }.min()
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.refreshInterval))
                guard !Task.isCancelled else { break }
                await self.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        // Probe local auth first — unconfigured providers stay hidden.
        var active: [ProviderID] = []
        for id in ProviderID.allCases {
            if isConfigured(id) {
                active.append(id)
                if case .hidden = slots[id]?.state {
                    slots[id]?.state = .idle
                }
                if case .idle = slots[id]?.state {
                    slots[id]?.state = .loading
                }
            } else {
                slots[id] = ProviderSlot(id: id, state: .hidden, softError: nil)
            }
        }

        guard !active.isEmpty else {
            lastAttemptAt = Date.now
            return
        }

        await withTaskGroup(of: (ProviderID, Result<ProviderUsage, Error>).self) { group in
            for id in active {
                group.addTask {
                    let result: Result<ProviderUsage, Error>
                    do {
                        switch id {
                        case .codex:
                            result = .success(try await self.codexClient.fetch())
                        case .cursor:
                            result = .success(try await self.cursorClient.fetch())
                        case .claude:
                            result = .success(try await self.claudeClient.fetch())
                        case .skywork:
                            result = .success(try await self.skyworkClient.fetch())
                        }
                    } catch {
                        result = .failure(error)
                    }
                    return (id, result)
                }
            }

            var anySuccess = false
            for await (id, outcome) in group {
                apply(id: id, outcome: outcome, anySuccess: &anySuccess)
            }
            lastAttemptAt = Date.now
            if anySuccess {
                lastSuccessfulRefreshAt = Date.now
            }
        }
    }

    private func isConfigured(_ id: ProviderID) -> Bool {
        switch id {
        case .codex: return codexClient.isConfigured()
        case .cursor: return cursorClient.isConfigured()
        case .claude: return claudeClient.isConfigured()
        case .skywork: return skyworkClient.isConfigured()
        }
    }

    private func apply(
        id: ProviderID,
        outcome: Result<ProviderUsage, Error>,
        anySuccess: inout Bool
    ) {
        switch outcome {
        case .success(let usage):
            slots[id] = ProviderSlot(id: id, state: .loaded(usage), softError: nil)
            anySuccess = true
        case .failure(let error):
            if AuthErrorDetector.isAuthUnavailable(error) {
                // Credentials disappeared mid-flight or are unusable — hide.
                slots[id] = ProviderSlot(id: id, state: .hidden, softError: nil)
                return
            }
            if case .loaded = slots[id]?.state {
                slots[id]?.softError = error.localizedDescription
            } else {
                slots[id] = ProviderSlot(
                    id: id,
                    state: .unavailable(error.localizedDescription),
                    softError: nil
                )
            }
        }
    }
}
