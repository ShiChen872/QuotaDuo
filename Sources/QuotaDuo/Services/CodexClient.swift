import Foundation

struct CodexClient: Sendable {
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let maximumPayloadSize = 1_048_576
    private let refreshLeeway: TimeInterval = 5 * 60

    /// Local credential probe (no network).
    func isConfigured() -> Bool {
        (try? loadAuthFile()) != nil
    }

    func fetch() async throws -> ProviderUsage {
        var auth = try loadAuthFile()
        if shouldRefresh(accessToken: auth.tokens?.accessToken) {
            auth = try await refreshAndPersist(current: auth)
        }

        let data: Data
        do {
            data = try await requestUsage(auth: auth)
        } catch CodexError.authUnavailable {
            // Token rejected — reload disk (another process may have refreshed), then refresh once.
            let latest = try loadAuthFile()
            if latest.tokens?.accessToken != auth.tokens?.accessToken,
               !shouldRefresh(accessToken: latest.tokens?.accessToken) {
                auth = latest
            } else {
                auth = try await refreshAndPersist(current: latest)
            }
            data = try await requestUsage(auth: auth)
        }

        let usage = try JSONDecoder().decode(UsageEnvelope.self, from: data)
        let now = Date.now

        let hasPrimary = usage.rateLimit?.primaryWindow?.usedPercent != nil
        let hasSecondary = usage.rateLimit?.secondaryWindow?.usedPercent != nil

        var lines: [UsageLine] = []
        if let primary = usage.rateLimit?.primaryWindow {
            let role: WindowRole = (hasPrimary && hasSecondary) ? .primary : .auto
            if let line = usageLine(from: primary, role: role, now: now) {
                lines.append(line)
            }
        }
        if let secondary = usage.rateLimit?.secondaryWindow {
            let role: WindowRole = (hasPrimary && hasSecondary) ? .secondary : .auto
            if let line = usageLine(from: secondary, role: role, now: now) {
                lines.append(line)
            }
        }

        guard !lines.isEmpty else {
            throw CodexError.malformedUsage
        }

        var unique: [String: UsageLine] = [:]
        for line in lines {
            unique[line.label] = line
        }
        let order: [String: Int] = ["Session": 0, "Weekly": 1]
        lines = unique.values.sorted {
            (order[$0.label] ?? 99) < (order[$1.label] ?? 99)
        }

        return ProviderUsage(
            providerId: .codex,
            plan: usage.planType?.uppercased(),
            lines: lines,
            fetchedAt: now,
            detail: nil
        )
    }

    private enum WindowRole {
        case primary
        case secondary
        case auto
    }

    private func usageLine(from window: DirectWindow, role: WindowRole, now: Date) -> UsageLine? {
        guard let usedPercent = window.usedPercent else { return nil }
        let duration = window.limitWindowSeconds
        let resetAt = window.resetAt.map { Date(timeIntervalSince1970: $0) }

        let label: String
        switch role {
        case .primary:
            label = "Session"
        case .secondary:
            label = "Weekly"
        case .auto:
            let isShort: Bool
            if let duration {
                isShort = duration <= 12 * 60 * 60
            } else if let resetAt {
                isShort = resetAt.timeIntervalSince(now) <= 12 * 60 * 60
            } else {
                return nil
            }
            label = isShort ? "Session" : "Weekly"
        }

        return UsageLine(
            label: label,
            usedPercent: usedPercent.clampedPercent,
            resetsAt: resetAt,
            subtitle: nil
        )
    }

    private func authFileURL() -> URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent("auth.json")
    }

    private func loadAuthFile() throws -> AuthFile {
        let url = authFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexError.authUnavailable("未找到 ~/.codex/auth.json，请先登录 Codex")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 262_144 else {
            throw CodexError.authUnavailable("auth.json 异常过大")
        }

        let data = try Data(contentsOf: url)
        var file = try JSONDecoder().decode(AuthFile.self, from: data)
        file.sourceURL = url

        let tokens = file.tokens
        guard let accessToken = tokens?.accessToken, !accessToken.isEmpty else {
            throw CodexError.authUnavailable("auth.json 中没有 access_token，请重新登录 Codex")
        }
        if file.resolvedAccountId == nil {
            file.tokens?.accountId = accountId(from: accessToken)
        }
        return file
    }

    private func shouldRefresh(accessToken: String?) -> Bool {
        guard let accessToken, !accessToken.isEmpty else { return true }
        guard let exp = JWT.expiration(of: accessToken) else { return false }
        return exp.timeIntervalSinceNow <= refreshLeeway
    }

    private func refreshAndPersist(current: AuthFile) async throws -> AuthFile {
        // Reload from disk first — Codex CLI may have already rotated tokens.
        let latest = (try? loadAuthFile()) ?? current
        if !shouldRefresh(accessToken: latest.tokens?.accessToken),
           let access = latest.tokens?.accessToken, !access.isEmpty {
            return latest
        }

        guard let refreshToken = latest.tokens?.refreshToken, !refreshToken.isEmpty else {
            throw CodexError.authUnavailable("Codex refresh_token 不可用，请重新登录 Codex")
        }

        let body = RefreshRequest(
            clientId: clientID,
            grantType: "refresh_token",
            refreshToken: refreshToken
        )

        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard data.count <= maximumPayloadSize else {
            throw CodexError.requestFailed("刷新响应过大")
        }
        guard let http = response as? HTTPURLResponse else {
            throw CodexError.requestFailed("刷新无响应")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CodexError.authUnavailable("Codex refresh_token 已失效，请重新登录 Codex（运行 codex login）")
            }
            throw CodexError.requestFailed("刷新失败 HTTP \(http.statusCode)")
        }

        let refreshed = try JSONDecoder().decode(RefreshResponse.self, from: data)
        guard let newAccess = refreshed.accessToken, !newAccess.isEmpty else {
            throw CodexError.authUnavailable("刷新未返回 access_token")
        }

        var updated = latest
        var tokens = updated.tokens ?? AuthFile.Tokens()
        tokens.accessToken = newAccess
        if let idToken = refreshed.idToken, !idToken.isEmpty {
            tokens.idToken = idToken
        }
        if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty {
            tokens.refreshToken = newRefresh
        }
        if tokens.accountId == nil {
            tokens.accountId = accountId(from: newAccess)
        }
        updated.tokens = tokens
        updated.lastRefresh = iso8601Now()
        try persist(updated)
        return updated
    }

    private func persist(_ file: AuthFile) throws {
        let url = file.sourceURL ?? authFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Match Codex field names with snake_case / OPENAI_API_KEY via CodingKeys.
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func requestUsage(auth: AuthFile) async throws -> Data {
        guard let accessToken = auth.tokens?.accessToken, !accessToken.isEmpty else {
            throw CodexError.authUnavailable("缺少 access_token")
        }

        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("CODEX", forHTTPHeaderField: "OAI-Product-Sku")
        if let accountId = auth.resolvedAccountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexError.requestFailed("无响应")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CodexError.authUnavailable("Codex token 已失效")
            }
            throw CodexError.requestFailed("HTTP \(http.statusCode)")
        }
        guard data.count <= maximumPayloadSize else {
            throw CodexError.requestFailed("响应过大")
        }
        return data
    }

    private func accountId(from token: String) -> String? {
        guard let json = JWT.decodePayload(token) else { return nil }
        return json["https://api.openai.com/auth.chatgpt_account_id"] as? String
            ?? json["chatgpt_account_id"] as? String
    }

    private func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date.now)
    }
}

enum CodexError: LocalizedError {
    case authUnavailable(String)
    case requestFailed(String)
    case malformedUsage

    var errorDescription: String? {
        switch self {
        case .authUnavailable(let message): return message
        case .requestFailed(let message): return "Codex 请求失败：\(message)"
        case .malformedUsage: return "Codex 用量数据格式异常"
        }
    }
}

private extension CodexClient {
    struct AuthFile: Codable, Sendable {
        var authMode: String?
        var openaiApiKey: String?
        var tokens: Tokens?
        var lastRefresh: String?
        /// Not persisted — local path used for write-back.
        var sourceURL: URL? = nil

        var resolvedAccountId: String? {
            tokens?.accountId
        }

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case openaiApiKey = "OPENAI_API_KEY"
            case tokens
            case lastRefresh = "last_refresh"
        }

        struct Tokens: Codable, Sendable {
            var idToken: String?
            var accessToken: String?
            var refreshToken: String?
            var accountId: String?

            enum CodingKeys: String, CodingKey {
                case idToken = "id_token"
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case accountId = "account_id"
            }
        }
    }

    struct RefreshRequest: Encodable {
        let clientId: String
        let grantType: String
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case grantType = "grant_type"
            case refreshToken = "refresh_token"
        }
    }

    struct RefreshResponse: Decodable {
        let idToken: String?
        let accessToken: String?
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    struct UsageEnvelope: Decodable {
        let planType: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: DirectWindow?
        let secondaryWindow: DirectWindow?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct DirectWindow: Decodable {
        let usedPercent: Double?
        let resetAt: Double?
        let limitWindowSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }
}

enum JWT {
    static func decodePayload(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count > 1 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    static func expiration(of token: String) -> Date? {
        guard let payload = decodePayload(token) else { return nil }
        if let exp = payload["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = payload["exp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(exp))
        }
        if let exp = payload["exp"] as? Double {
            return Date(timeIntervalSince1970: exp)
        }
        return nil
    }
}
