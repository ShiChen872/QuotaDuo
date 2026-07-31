import Foundation

struct CodexClient: Sendable {
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let maximumPayloadSize = 1_048_576

    /// Local credential probe (no network).
    func isConfigured() -> Bool {
        (try? loadAuth()) != nil
    }

    func fetch() async throws -> ProviderUsage {
        let auth = try loadAuth()
        let data = try await request(usageURL, auth: auth)
        let usage = try JSONDecoder().decode(UsageEnvelope.self, from: data)
        let now = Date.now

        // Dual windows: primary → Session, secondary → Weekly.
        // Single window: fall back to duration / reset ETA heuristic.
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

        // De-dupe by label if both mapped to the same name.
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

    private func loadAuth() throws -> DirectAuth {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        let url = home.appendingPathComponent("auth.json")

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexError.authUnavailable("未找到 ~/.codex/auth.json，请先登录 Codex")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 262_144 else {
            throw CodexError.authUnavailable("auth.json 异常过大")
        }

        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(AuthEnvelope.self, from: data)
        let tokens = envelope.tokens ?? envelope.rootTokens
        guard let accessToken = tokens.accessToken, !accessToken.isEmpty else {
            throw CodexError.authUnavailable("auth.json 中没有 access_token，请重新登录 Codex")
        }
        let accountId = tokens.accountId ?? accountId(from: accessToken)
        return DirectAuth(accessToken: accessToken, accountId: accountId)
    }

    private func request(_ url: URL, auth: DirectAuth) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("CODEX", forHTTPHeaderField: "OAI-Product-Sku")
        if let accountId = auth.accountId {
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
                throw CodexError.authUnavailable("Codex token 已失效，请重新登录 Codex")
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
    struct DirectAuth: Sendable {
        let accessToken: String
        let accountId: String?
    }

    struct AuthEnvelope: Decodable {
        struct Tokens: Decodable {
            let accessToken: String?
            let accountId: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
            }
        }

        let tokens: Tokens?
        let accessToken: String?
        let accountId: String?

        var rootTokens: Tokens {
            Tokens(accessToken: accessToken, accountId: accountId)
        }

        enum CodingKeys: String, CodingKey {
            case tokens
            case accessToken = "access_token"
            case accountId = "account_id"
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
}
