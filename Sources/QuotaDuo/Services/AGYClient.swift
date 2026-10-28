import Foundation

struct AGYClient: Sendable {
    /// Monthly billing cycle anchor day for Google One AI Pro (18th of each month).
    private let billingAnchorDay = 18

    /// Local configuration & session probe (purely offline, zero network or OAuth access).
    func isConfigured() -> Bool {
        let cliRoot = geminiRoot().appendingPathComponent("antigravity-cli", isDirectory: true)
        let onboardingURL = cliRoot
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("onboarding.json", isDirectory: false)

        if let data = try? Data(contentsOf: onboardingURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let complete = json["onboardingComplete"] as? Bool,
           complete {
            return true
        }

        return !transcriptURLs().isEmpty
    }

    func fetch() async throws -> ProviderUsage {
        guard isConfigured() else {
            throw AGYError.authUnavailable("未检测到本地 AGY 登录或会话记录")
        }

        let now = Date.now
        let cycle = billingWindow(for: now)
        let startOfToday = Calendar.current.startOfDay(for: now)
        let defaultModel = readDefaultModel()
        let stats = collectTokenStats(
            cycleStart: cycle.start,
            todayStart: startOfToday,
            defaultModel: defaultModel
        )

        let planBadge = formatPlanBadge(model: defaultModel)

        let todayText = Self.formatTokenCount(stats.todayTokens)
        let cycleText = Self.formatTokenCount(stats.cycleTokens)
        let line1 = "今日 \(todayText) · 账期 \(cycleText)（\(stats.cycleConversations) 会话）"

        var detailLines: [String] = [line1]
        if let poolLine = stats.modelPoolLine() {
            detailLines.append(poolLine)
        }

        let cycleDuration = max(1, cycle.end.timeIntervalSince(cycle.start))
        let cycleElapsed = max(0, min(cycleDuration, now.timeIntervalSince(cycle.start)))
        let cycleUsedPercent = (cycleElapsed / cycleDuration * 100).clampedPercent

        let endFormatter = DateFormatter()
        endFormatter.locale = Locale(identifier: "zh_CN")
        endFormatter.dateFormat = "MM/dd"
        let cycleSubtitle = "至 \(endFormatter.string(from: cycle.end))"

        let lines: [UsageLine] = [
            UsageLine(
                label: "账期",
                usedPercent: cycleUsedPercent,
                resetsAt: cycle.end,
                subtitle: cycleSubtitle
            )
        ]

        return ProviderUsage(
            providerId: .agy,
            plan: planBadge,
            lines: lines,
            fetchedAt: now,
            detail: detailLines.joined(separator: "\n"),
            menuBarRemainingPercent: nil,
            includeInMenuBar: false
        )
    }

    // MARK: - Local Paths & Settings

    private func geminiRoot() -> URL {
        if let custom = ProcessInfo.processInfo.environment["AGY_GEMINI_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
    }

    private func readDefaultModel() -> String? {
        let settingsURL = geminiRoot()
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? String,
              !model.isEmpty else {
            return nil
        }
        return model
    }

    private func formatPlanBadge(model: String?) -> String {
        guard let raw = model?.lowercased(), !raw.isEmpty else {
            return "Pro"
        }
        if raw.contains("argon") {
            return "Pro · Argon"
        }
        if raw.contains("flash") {
            return "Pro · Flash"
        }
        if raw.contains("claude") || raw.contains("opus") || raw.contains("sonnet") {
            return "Pro · Claude"
        }
        return "Pro"
    }

    private func transcriptURLs() -> [URL] {
        let fm = FileManager.default
        let root = geminiRoot()
        let surfaces = ["antigravity-cli", "antigravity"]
        var urls: [URL] = []

        for surface in surfaces {
            let brainDir = root
                .appendingPathComponent(surface, isDirectory: true)
                .appendingPathComponent("brain", isDirectory: true)
            guard let convDirs = try? fm.contentsOfDirectory(
                at: brainDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for convDir in convDirs {
                let transcript = convDir
                    .appendingPathComponent(".system_generated", isDirectory: true)
                    .appendingPathComponent("logs", isDirectory: true)
                    .appendingPathComponent("transcript.jsonl", isDirectory: false)
                if fm.fileExists(atPath: transcript.path) {
                    urls.append(transcript)
                }
            }
        }
        return urls
    }

    // MARK: - Billing Window (18th of Month Anchor)

    private func billingWindow(for now: Date) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: now)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        let day = comps.day ?? 1

        var startComps = DateComponents()
        startComps.year = year
        startComps.month = month
        startComps.day = billingAnchorDay
        startComps.hour = 0
        startComps.minute = 0
        startComps.second = 0

        let anchorThisMonth = cal.date(from: startComps) ?? now
        let start: Date
        if day >= billingAnchorDay {
            start = anchorThisMonth
        } else {
            start = cal.date(byAdding: .month, value: -1, to: anchorThisMonth) ?? anchorThisMonth
        }
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? now.addingTimeInterval(30 * 86400)
        return (start, end)
    }

    // MARK: - Transcript Token Aggregation

    private struct TokenStats {
        var todayTokens: Double = 0
        var cycleTokens: Double = 0
        var geminiTokens: Double = 0
        var claudeTokens: Double = 0
        var otherTokens: Double = 0
        var cycleConversations: Int = 0

        func modelPoolLine() -> String? {
            guard cycleTokens > 0 else { return nil }
            let totalText = "Token \(AGYClient.formatTokenCount(cycleTokens))"
            var parts: [String] = []
            if geminiTokens > 0 {
                parts.append("Gemini \(AGYClient.formatTokenCount(geminiTokens))")
            }
            if claudeTokens > 0 {
                parts.append("Claude \(AGYClient.formatTokenCount(claudeTokens))")
            }
            if otherTokens > 0 {
                parts.append("其他 \(AGYClient.formatTokenCount(otherTokens))")
            }
            guard !parts.isEmpty else { return totalText }
            return "\(totalText)（\(parts.joined(separator: " · "))）"
        }
    }

    private enum ModelPool {
        case gemini
        case claude
        case other

        static func classify(_ raw: String?) -> ModelPool {
            guard let text = raw?.lowercased(), !text.isEmpty else {
                return .gemini
            }
            if text.contains("claude") || text.contains("opus") || text.contains("sonnet") {
                return .claude
            }
            if text.contains("gemini") || text.contains("argon") || text.contains("flash") {
                return .gemini
            }
            return .other
        }
    }

    private func collectTokenStats(
        cycleStart: Date,
        todayStart: Date,
        defaultModel: String?
    ) -> TokenStats {
        var stats = TokenStats()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoStandard = ISO8601DateFormatter()
        isoStandard.formatOptions = [.withInternetDateTime]

        for url in transcriptURLs() {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var currentPool = ModelPool.classify(defaultModel)
            var convHasCycleActivity = false

            for line in content.split(whereSeparator: \.isNewline) {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                if let text = obj["content"] as? String,
                   let switchedModel = Self.extractModelSelection(from: text) {
                    currentPool = ModelPool.classify(switchedModel)
                }

                guard (obj["type"] as? String) == "PLANNER_RESPONSE" else { continue }

                let input = Self.doubleValue(obj["input_tokens"])
                let output = Self.doubleValue(obj["output_tokens"])
                let cacheRead = Self.doubleValue(obj["cache_read_tokens"])
                let cacheWrite = Self.doubleValue(obj["cache_write_tokens"])
                let stepTotal = input + output + cacheRead + cacheWrite
                guard stepTotal > 0 else { continue }

                let stepDate: Date?
                if let createdAt = obj["created_at"] as? String {
                    stepDate = isoFractional.date(from: createdAt) ?? isoStandard.date(from: createdAt)
                } else {
                    stepDate = nil
                }

                let inCycle = stepDate.map { $0 >= cycleStart } ?? true
                let inToday = stepDate.map { $0 >= todayStart } ?? false

                if inToday {
                    stats.todayTokens += stepTotal
                }
                if inCycle {
                    convHasCycleActivity = true
                    stats.cycleTokens += stepTotal
                    switch currentPool {
                    case .gemini:
                        stats.geminiTokens += stepTotal
                    case .claude:
                        stats.claudeTokens += stepTotal
                    case .other:
                        stats.otherTokens += stepTotal
                    }
                }
            }

            if convHasCycleActivity {
                stats.cycleConversations += 1
            }
        }

        return stats
    }

    private static func extractModelSelection(from text: String) -> String? {
        let marker = "changed setting `Model Selection` from "
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...]
        guard let toRange = tail.range(of: " to ") else { return nil }
        let afterTo = tail[toRange.upperBound...]
        if let dotIndex = afterTo.firstIndex(where: { $0 == "." || $0 == "\n" }) {
            let model = afterTo[..<dotIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? nil : model
        }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return 0
    }

    static func formatTokenCount(_ value: Double) -> String {
        let magnitude = abs(value)
        let scaled: Double
        let suffix: String
        if magnitude >= 1_000_000 {
            scaled = value / 1_000_000
            suffix = "M"
        } else if magnitude >= 1_000 {
            scaled = value / 1_000
            suffix = "K"
        } else {
            return String(Int(value.rounded()))
        }
        let digits = abs(scaled) >= 100 ? 0 : 1
        var text = String(format: "%.\(digits)f", scaled)
        if text.hasSuffix(".0") {
            text.removeLast(2)
        }
        return text + suffix
    }
}

enum AGYError: LocalizedError {
    case authUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .authUnavailable(let message): return message
        }
    }
}
