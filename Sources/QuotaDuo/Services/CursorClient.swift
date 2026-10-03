import Foundation
import SQLite3

struct CursorClient: Sendable {
    private let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    private let currentPeriodURL = URL(string: "https://cursor.com/api/dashboard/get-current-period-usage")!
    private let aggregatedUsageURL = URL(string: "https://cursor.com/api/dashboard/get-aggregated-usage-events")!
    private let maximumPayloadSize = 1_048_576

    /// Local credential probe (no network).
    func isConfigured() -> Bool {
        (try? loadSession()) != nil
    }

    func fetch() async throws -> ProviderUsage {
        let session = try loadSession()
        let now = Date.now

        async let summaryOutcome: Result<Data, Error> = {
            do { return .success(try await self.request(self.usageSummaryURL, method: "GET", session: session, body: nil)) }
            catch { return .failure(error) }
        }()
        async let periodOutcome: Result<Data, Error> = {
            do {
                return .success(
                    try await self.request(
                        self.currentPeriodURL,
                        method: "POST",
                        session: session,
                        body: Data("{}".utf8)
                    )
                )
            } catch {
                return .failure(error)
            }
        }()
        async let tokenOutcome: TokenTotals? = {
            do {
                let data = try await self.request(
                    self.aggregatedUsageURL,
                    method: "POST",
                    session: session,
                    body: Data("{\"teamId\":0}".utf8)
                )
                return TokenTotals(decoding: data)
            } catch {
                return nil
            }
        }()

        let (summaryResult, periodResult, tokenTotals) = await (summaryOutcome, periodOutcome, tokenOutcome)

        var authFailures: [Error] = []
        var requestFailures: [Error] = []

        let summary: UsageSummary?
        switch summaryResult {
        case .success(let data):
            summary = try? JSONDecoder().decode(UsageSummary.self, from: data)
        case .failure(let error):
            summary = nil
            if Self.isAuthFailure(error) {
                authFailures.append(error)
            } else {
                requestFailures.append(error)
            }
        }

        let period: CurrentPeriodUsage?
        switch periodResult {
        case .success(let data):
            period = try? JSONDecoder().decode(CurrentPeriodUsage.self, from: data)
        case .failure(let error):
            period = nil
            if Self.isAuthFailure(error) {
                authFailures.append(error)
            } else {
                requestFailures.append(error)
            }
        }

        var lines: [UsageLine] = []
        var planName: String?
        var detail: String?
        let resetAt = period?.billingCycleEnd ?? summary?.billingCycleEnd

        planName = summary?.membershipType?.capitalized
            ?? period?.planUsage?.planName?.capitalized

        // --- Prefer usage-summary plan bucket (most stable for Pro) ---
        if let plan = summary?.individualUsage?.plan {
            let limitCents = plan.limit
            let usedPct = plan.totalPercentUsed
                ?? plan.percentUsed
                ?? percent(used: plan.used, limit: limitCents)

            if let usedPct {
                let usedCents = resolvedUsedCents(
                    reportedUsed: plan.used,
                    remaining: plan.remaining,
                    limit: limitCents,
                    percentUsed: usedPct
                )
                let money: String?
                if let usedCents, let limitCents {
                    let text = "\(formatCents(usedCents)) / \(formatCents(limitCents))"
                    money = text
                    detail = "已用 \(text)"
                } else if let remaining = plan.remaining {
                    money = "剩余 \(formatCents(remaining))"
                    detail = money
                } else {
                    money = nil
                }
                lines.append(
                    UsageLine(
                        label: "Plan",
                        usedPercent: usedPct.clampedPercent,
                        resetsAt: resetAt ?? plan.billingCycleEnd,
                        subtitle: money
                    )
                )
            }

            if let auto = plan.autoPercentUsed {
                lines.append(
                    UsageLine(
                        label: "Auto",
                        usedPercent: auto.clampedPercent,
                        resetsAt: resetAt,
                        subtitle: nil
                    )
                )
            }
            if let api = plan.apiPercentUsed {
                lines.append(
                    UsageLine(
                        label: "API",
                        usedPercent: api.clampedPercent,
                        resetsAt: resetAt,
                        subtitle: nil
                    )
                )
            }
        }

        // --- Enrich / fallback from get-current-period-usage ---
        if let period {
            if let plan = period.planUsage {
                planName = plan.planName?.capitalized ?? planName

                let usedCents = plan.totalSpend ?? plan.includedSpend
                let limitCents = plan.limit
                let usedPct = plan.totalPercentUsed
                    ?? plan.percentUsed
                    ?? percent(used: usedCents, limit: limitCents)

                if !lines.contains(where: { $0.label == "Plan" }), let usedPct {
                    let money: String?
                    if let usedCents, let limitCents {
                        let text = "\(formatCents(usedCents)) / \(formatCents(limitCents))"
                        money = text
                        detail = detail ?? "已用 \(text)"
                    } else {
                        money = nil
                    }
                    lines.append(
                        UsageLine(
                            label: "Plan",
                            usedPercent: usedPct.clampedPercent,
                            resetsAt: resetAt,
                            subtitle: money
                        )
                    )
                } else if let usedCents, let limitCents {
                    // Only adopt period spend when it roughly matches the ring percent.
                    let inferredPct = (usedCents / limitCents * 100).clampedPercent
                    if let planLine = lines.first(where: { $0.label == "Plan" }),
                       abs(inferredPct - planLine.usedPercent) <= 8 {
                        let money = "\(formatCents(usedCents)) / \(formatCents(limitCents))"
                        detail = "已用 \(money)"
                        if let idx = lines.firstIndex(where: { $0.label == "Plan" }) {
                            let old = lines[idx]
                            lines[idx] = UsageLine(
                                label: old.label,
                                usedPercent: old.usedPercent,
                                resetsAt: old.resetsAt ?? resetAt,
                                subtitle: money
                            )
                        }
                    }
                }

                if !lines.contains(where: { $0.label == "Auto" }), let auto = plan.autoPercentUsed {
                    lines.append(
                        UsageLine(
                            label: "Auto",
                            usedPercent: auto.clampedPercent,
                            resetsAt: resetAt,
                            subtitle: nil
                        )
                    )
                }
                if !lines.contains(where: { $0.label == "API" }), let api = plan.apiPercentUsed {
                    lines.append(
                        UsageLine(
                            label: "API",
                            usedPercent: api.clampedPercent,
                            resetsAt: resetAt,
                            subtitle: nil
                        )
                    )
                }
            }

            // Top-level percents (older response shapes).
            if !lines.contains(where: { $0.label == "Auto" }), let auto = period.autoPercentUsed {
                lines.append(
                    UsageLine(
                        label: "Auto",
                        usedPercent: auto.clampedPercent,
                        resetsAt: resetAt,
                        subtitle: nil
                    )
                )
            }
            if !lines.contains(where: { $0.label == "API" }), let api = period.apiPercentUsed {
                lines.append(
                    UsageLine(
                        label: "API",
                        usedPercent: api.clampedPercent,
                        resetsAt: resetAt,
                        subtitle: nil
                    )
                )
            }
        }

        // On-demand from summary (only when a hard limit exists).
        if let onDemand = summary?.individualUsage?.onDemand,
           onDemand.enabled != false,
           let used = onDemand.used,
           let limit = onDemand.limit,
           limit > 0 {
            lines.append(
                UsageLine(
                    label: "On-Demand",
                    usedPercent: (used / limit * 100).clampedPercent,
                    resetsAt: resetAt,
                    subtitle: "\(formatCents(used)) / \(formatCents(limit))"
                )
            )
        } else if let onDemand = summary?.individualUsage?.onDemand,
                  let used = onDemand.used,
                  used > 0 {
            let extra = "按量 \(formatCents(used))"
            detail = detail.map { "\($0) · \(extra)" } ?? extra
        }

        // Fill missing reset dates.
        if let resetAt {
            lines = lines.map { line in
                guard line.resetsAt == nil else { return line }
                return UsageLine(
                    label: line.label,
                    usedPercent: line.usedPercent,
                    resetsAt: resetAt,
                    subtitle: line.subtitle
                )
            }
        }

        guard !lines.isEmpty else {
            if let auth = authFailures.first {
                throw auth
            }
            if let request = requestFailures.first {
                throw request
            }
            if summary == nil && period == nil {
                throw CursorError.requestFailed("用量接口均无有效响应")
            }
            throw CursorError.malformedUsage
        }

        var seen: [String: UsageLine] = [:]
        for line in lines where seen[line.label] == nil {
            seen[line.label] = line
        }
        let orderedLabels = ["Plan", "Auto", "API", "On-Demand"]
        let ordered = orderedLabels.compactMap { seen[$0] }
            + seen.keys.filter { !orderedLabels.contains($0) }.sorted().compactMap { seen[$0] }

        if let tokenLine = tokenTotals?.detailLine() {
            detail = detail.map { "\($0)\n\(tokenLine)" } ?? tokenLine
        }

        return ProviderUsage(
            providerId: .cursor,
            plan: planName,
            lines: ordered,
            fetchedAt: now,
            detail: detail
        )
    }

    private static func isAuthFailure(_ error: Error) -> Bool {
        if let cursor = error as? CursorError, case .authUnavailable = cursor {
            return true
        }
        return false
    }

    private func percent(used: Double?, limit: Double?) -> Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return (used / limit * 100).clampedPercent
    }

    /// When `used == limit` but percent is much lower (bonus/included quirks),
    /// prefer percent-inferred spend for display.
    private func resolvedUsedCents(
        reportedUsed: Double?,
        remaining: Double?,
        limit: Double?,
        percentUsed: Double
    ) -> Double? {
        if let limit {
            let inferred = limit * percentUsed / 100.0
            if let remaining {
                let fromRemaining = max(0, limit - remaining)
                // Trust remaining only when it agrees with the ring percent.
                if abs(fromRemaining - inferred) <= max(1.0, limit * 0.08) {
                    return fromRemaining
                }
            }
            if let reportedUsed,
               abs(reportedUsed - limit) < 0.5,
               percentUsed < 99 {
                return inferred
            }
            if let reportedUsed {
                let reportedPct = (reportedUsed / limit * 100).clampedPercent
                if abs(reportedPct - percentUsed) <= 8 {
                    return reportedUsed
                }
                return inferred
            }
            return inferred
        }
        return reportedUsed
    }

    /// API monetary fields are USD cents.
    private func formatCents(_ cents: Double) -> String {
        String(format: "$%.2f", cents / 100.0)
    }

    /// Compact token counts: 1591475 → 1.6M, 193135750 → 193M.
    private static func formatTokenCount(_ value: Double) -> String {
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

    private func loadSession() throws -> CursorSession {
        if let env = ProcessInfo.processInfo.environment["CURSOR_SESSION_TOKEN"], !env.isEmpty {
            return CursorSession(cookieValue: normalizeCookie(env))
        }

        let dbURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
                isDirectory: false
            )
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw CursorError.authUnavailable("未找到 Cursor 本地登录状态，请先在 Cursor 中登录")
        }

        let jwt = try readAccessToken(from: dbURL)
        guard !jwt.isEmpty else {
            throw CursorError.authUnavailable("Cursor accessToken 为空，请重新登录")
        }

        let payload = JWT.decodePayload(jwt)
        let sub = payload?["sub"] as? String
        let cookie: String
        if let sub, !sub.isEmpty {
            cookie = "\(sub)::\(jwt)"
        } else {
            cookie = jwt
        }
        return CursorSession(cookieValue: normalizeCookie(cookie))
    }

    /// Prefer URL-encoded cookie value so `|` in OAuth subject is valid in Cookie header.
    private func normalizeCookie(_ raw: String) -> String {
        if raw.contains("%") {
            return raw
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    private func readAccessToken(from dbURL: URL) throws -> String {
        // Copy DB (and WAL/SHM if present) so reads don't fight the Cursor IDE.
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(
            "QuotaDuo-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let tempDB = tempDir.appendingPathComponent("state.vscdb")
        try fm.copyItem(at: dbURL, to: tempDB)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: dbURL.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(
                    at: side,
                    to: URL(fileURLWithPath: tempDB.path + suffix)
                )
            }
        }

        return try readAccessTokenDirect(from: tempDB)
    }

    private func readAccessTokenDirect(from dbURL: URL) throws -> String {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(dbURL.path, &db, flags, nil)
        guard openResult == SQLITE_OK, let db else {
            throw CursorError.authUnavailable("无法打开 Cursor state.vscdb")
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CursorError.authUnavailable("无法读取 Cursor accessToken")
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CursorError.authUnavailable("未找到 cursorAuth/accessToken，请在 Cursor 中登录")
        }

        if let cString = sqlite3_column_text(statement, 0) {
            return String(cString: cString)
        }

        let bytes = sqlite3_column_bytes(statement, 0)
        if bytes > 0, let blob = sqlite3_column_blob(statement, 0) {
            let data = Data(bytes: blob, count: Int(bytes))
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        throw CursorError.authUnavailable("accessToken 格式无法解析")
    }

    private func request(
        _ url: URL,
        method: String,
        session: CursorSession,
        body: Data?
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        request.setValue(
            "WorkosCursorSessionToken=\(session.cookieValue)",
            forHTTPHeaderField: "Cookie"
        )
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorError.requestFailed("无响应")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CursorError.authUnavailable("Cursor 会话已失效，请重新登录 Cursor 或设置 CURSOR_SESSION_TOKEN")
            }
            throw CursorError.requestFailed("HTTP \(http.statusCode)")
        }
        guard data.count <= maximumPayloadSize else {
            throw CursorError.requestFailed("响应过大")
        }
        return data
    }
}

enum CursorError: LocalizedError {
    case authUnavailable(String)
    case requestFailed(String)
    case malformedUsage

    var errorDescription: String? {
        switch self {
        case .authUnavailable(let message): return message
        case .requestFailed(let message): return "Cursor 请求失败：\(message)"
        case .malformedUsage: return "Cursor 用量数据为空或格式异常"
        }
    }
}

private extension CursorClient {
    struct CursorSession: Sendable {
        let cookieValue: String
    }

    struct UsageSummary: Decodable {
        let membershipType: String?
        let billingCycleStart: Date?
        let billingCycleEnd: Date?
        let individualUsage: IndividualUsage?

        enum CodingKeys: String, CodingKey {
            case membershipType
            case billingCycleStart
            case billingCycleEnd
            case individualUsage
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            membershipType = try container.decodeIfPresent(String.self, forKey: .membershipType)
            individualUsage = try container.decodeIfPresent(IndividualUsage.self, forKey: .individualUsage)
            billingCycleStart = Self.decodeFlexibleDate(container, key: .billingCycleStart)
            billingCycleEnd = Self.decodeFlexibleDate(container, key: .billingCycleEnd)
        }

        static func decodeFlexibleDate(
            _ container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> Date? {
            if let seconds = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
            }
            if let text = try? container.decodeIfPresent(String.self, forKey: key) {
                return parseISO8601(text)
            }
            return nil
        }
    }

    struct IndividualUsage: Decodable {
        let plan: PlanBucket?
        let onDemand: PlanBucket?
    }

    struct PlanBucket: Decodable {
        let planName: String?
        let enabled: Bool?
        let used: Double?
        let limit: Double?
        let remaining: Double?
        let totalSpend: Double?
        let percentUsed: Double?
        let totalPercentUsed: Double?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let numRequests: Double?
        let billingCycleEnd: Date?
        let breakdownTotal: Double?

        enum CodingKeys: String, CodingKey {
            case planName
            case enabled
            case used
            case limit
            case remaining
            case totalSpend
            case percentUsed
            case totalPercentUsed
            case autoPercentUsed
            case apiPercentUsed
            case numRequests
            case billingCycleEnd
            case breakdown
        }

        enum BreakdownKeys: String, CodingKey {
            case total
            case included
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            planName = try container.decodeIfPresent(String.self, forKey: .planName)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            used = try container.decodeIfPresent(Double.self, forKey: .used)
            limit = try container.decodeIfPresent(Double.self, forKey: .limit)
            remaining = try container.decodeIfPresent(Double.self, forKey: .remaining)
            totalSpend = try container.decodeIfPresent(Double.self, forKey: .totalSpend)
            numRequests = try container.decodeIfPresent(Double.self, forKey: .numRequests)
            percentUsed = try container.decodeIfPresent(Double.self, forKey: .percentUsed)
            totalPercentUsed = try container.decodeIfPresent(Double.self, forKey: .totalPercentUsed)
            autoPercentUsed = try container.decodeIfPresent(Double.self, forKey: .autoPercentUsed)
            apiPercentUsed = try container.decodeIfPresent(Double.self, forKey: .apiPercentUsed)
            if let breakdown = try? container.nestedContainer(keyedBy: BreakdownKeys.self, forKey: .breakdown) {
                breakdownTotal = try breakdown.decodeIfPresent(Double.self, forKey: .total)
            } else {
                breakdownTotal = nil
            }
            if let seconds = try? container.decodeIfPresent(Double.self, forKey: .billingCycleEnd) {
                billingCycleEnd = Date(
                    timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds
                )
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .billingCycleEnd) {
                billingCycleEnd = parseISO8601(text)
            } else {
                billingCycleEnd = nil
            }
        }
    }

    struct CurrentPeriodUsage: Decodable {
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let planUsage: PeriodPlanUsage?
        let billingCycleEnd: Date?

        enum CodingKeys: String, CodingKey {
            case autoPercentUsed
            case apiPercentUsed
            case planUsage
            case billingCycleEnd
            case billingCycleEndDate
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            autoPercentUsed = try container.decodeIfPresent(Double.self, forKey: .autoPercentUsed)
            apiPercentUsed = try container.decodeIfPresent(Double.self, forKey: .apiPercentUsed)
            planUsage = try container.decodeIfPresent(PeriodPlanUsage.self, forKey: .planUsage)
            if let seconds = try? container.decodeIfPresent(Double.self, forKey: .billingCycleEnd) {
                billingCycleEnd = Date(
                    timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds
                )
            } else if let text = try container.decodeIfPresent(String.self, forKey: .billingCycleEnd)
                ?? container.decodeIfPresent(String.self, forKey: .billingCycleEndDate) {
                billingCycleEnd = parseISO8601(text)
            } else {
                billingCycleEnd = nil
            }
        }
    }

    struct PeriodPlanUsage: Decodable {
        let planName: String?
        let totalSpend: Double?
        let includedSpend: Double?
        let limit: Double?
        let percentUsed: Double?
        let totalPercentUsed: Double?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
    }

    struct TokenTotals: Sendable {
        let total: Double
        let cursor: Double
        let other: Double

        init?(decoding data: Data) {
            guard let payload = try? JSONDecoder().decode(AggregatedUsage.self, from: data) else {
                return nil
            }
            let headline = (payload.totalInputTokens ?? 0)
                + (payload.totalOutputTokens ?? 0)
                + (payload.totalCacheWriteTokens ?? 0)
                + (payload.totalCacheReadTokens ?? 0)
            var cursor = 0.0
            var other = 0.0
            for row in payload.aggregations ?? [] {
                let amount = row.tokenCount
                if Self.isCursorModel(row) {
                    cursor += amount
                } else {
                    other += amount
                }
            }
            let total = headline > 0 ? headline : cursor + other
            guard total > 0 else { return nil }
            self.total = total
            self.cursor = cursor
            self.other = other
        }

        /// Billing page: Cursor models (Grok / Composer) vs third-party models.
        func detailLine() -> String? {
            guard total > 0 else { return nil }
            let totalText = "Token \(CursorClient.formatTokenCount(total))"
            var parts: [String] = []
            if cursor > 0 { parts.append("Cursor \(CursorClient.formatTokenCount(cursor))") }
            if other > 0 { parts.append("其他 \(CursorClient.formatTokenCount(other))") }
            guard !parts.isEmpty else { return totalText }
            return "\(totalText)（\(parts.joined(separator: " · "))）"
        }

        /// Grok and Composer draw from the Cursor pool. Tier 2 matches that pool
        /// when a new first-party name does not contain those words.
        private static func isCursorModel(_ row: ModelAggregation) -> Bool {
            let name = row.modelIntent?.lowercased() ?? ""
            if name.contains("grok") || name.contains("composer") || name.hasPrefix("cursor-") {
                return true
            }
            return row.tier == 2
        }
    }

    struct AggregatedUsage: Decodable {
        let totalInputTokens: Double?
        let totalOutputTokens: Double?
        let totalCacheWriteTokens: Double?
        let totalCacheReadTokens: Double?
        let aggregations: [ModelAggregation]?

        enum CodingKeys: String, CodingKey {
            case totalInputTokens
            case totalOutputTokens
            case totalCacheWriteTokens
            case totalCacheReadTokens
            case aggregations
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalInputTokens = decodeFlexibleCount(container, .totalInputTokens)
            totalOutputTokens = decodeFlexibleCount(container, .totalOutputTokens)
            totalCacheWriteTokens = decodeFlexibleCount(container, .totalCacheWriteTokens)
            totalCacheReadTokens = decodeFlexibleCount(container, .totalCacheReadTokens)
            aggregations = try container.decodeIfPresent([ModelAggregation].self, forKey: .aggregations)
        }
    }

    struct ModelAggregation: Decodable {
        let modelIntent: String?
        let tier: Int?
        let inputTokens: Double?
        let outputTokens: Double?
        let cacheWriteTokens: Double?
        let cacheReadTokens: Double?

        var tokenCount: Double {
            (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheWriteTokens ?? 0) + (cacheReadTokens ?? 0)
        }

        enum CodingKeys: String, CodingKey {
            case modelIntent
            case tier
            case inputTokens
            case outputTokens
            case cacheWriteTokens
            case cacheReadTokens
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            modelIntent = try container.decodeIfPresent(String.self, forKey: .modelIntent)
            tier = try container.decodeIfPresent(Int.self, forKey: .tier)
            inputTokens = decodeFlexibleCount(container, .inputTokens)
            outputTokens = decodeFlexibleCount(container, .outputTokens)
            cacheWriteTokens = decodeFlexibleCount(container, .cacheWriteTokens)
            cacheReadTokens = decodeFlexibleCount(container, .cacheReadTokens)
        }
    }
}

private func decodeFlexibleCount<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    _ key: Key
) -> Double? {
    if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
        return value
    }
    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
        return Double(value)
    }
    if let raw = try? container.decodeIfPresent(String.self, forKey: key) {
        return Double(raw.replacingOccurrences(of: ",", with: ""))
    }
    return nil
}

private func parseISO8601(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let basic = ISO8601DateFormatter()
    basic.formatOptions = [.withInternetDateTime]
    return basic.date(from: value)
}
