import Foundation
import SQLite3

struct CursorClient: Sendable {
    private let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    private let currentPeriodURL = URL(string: "https://cursor.com/api/dashboard/get-current-period-usage")!
    private let maximumPayloadSize = 1_048_576

    func fetch() async throws -> ProviderUsage {
        let session = try loadSession()
        let now = Date.now

        async let summaryData = try? request(usageSummaryURL, method: "GET", session: session, body: nil)
        async let periodData = try? request(
            currentPeriodURL,
            method: "POST",
            session: session,
            body: Data("{}".utf8)
        )

        let summary = await summaryData.flatMap { try? JSONDecoder().decode(UsageSummary.self, from: $0) }
        let period = await periodData.flatMap { try? JSONDecoder().decode(CurrentPeriodUsage.self, from: $0) }

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
                let subtitle: String?
                if let usedCents, let limitCents {
                    subtitle = "\(formatCents(usedCents)) / \(formatCents(limitCents))"
                    detail = "已用 \(subtitle!)"
                } else if let remaining = plan.remaining {
                    subtitle = "剩余 \(formatCents(remaining))"
                    detail = subtitle
                } else {
                    subtitle = nil
                }
                lines.append(
                    UsageLine(
                        label: "Plan",
                        usedPercent: usedPct.clampedPercent,
                        resetsAt: resetAt ?? plan.billingCycleEnd,
                        subtitle: subtitle
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
                    let subtitle: String?
                    if let usedCents, let limitCents {
                        subtitle = "\(formatCents(usedCents)) / \(formatCents(limitCents))"
                        detail = detail ?? "已用 \(subtitle!)"
                    } else {
                        subtitle = nil
                    }
                    lines.append(
                        UsageLine(
                            label: "Plan",
                            usedPercent: usedPct.clampedPercent,
                            resetsAt: resetAt,
                            subtitle: subtitle
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
            throw CursorError.malformedUsage
        }

        var seen: [String: UsageLine] = [:]
        for line in lines where seen[line.label] == nil {
            seen[line.label] = line
        }
        let orderedLabels = ["Plan", "Auto", "API", "On-Demand"]
        let ordered = orderedLabels.compactMap { seen[$0] }
            + seen.keys.filter { !orderedLabels.contains($0) }.sorted().compactMap { seen[$0] }

        return ProviderUsage(
            providerId: .cursor,
            plan: planName,
            lines: ordered,
            fetchedAt: now,
            detail: detail
        )
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
}

private func parseISO8601(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let basic = ISO8601DateFormatter()
    basic.formatOptions = [.withInternetDateTime]
    return basic.date(from: value)
}
