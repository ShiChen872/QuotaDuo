import CryptoKit
import Foundation
import Security

struct ClaudeClient: Sendable {
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let maximumPayloadSize = 1_048_576

    /// Local credential probe (no network).
    func isConfigured() -> Bool {
        (try? loadCredentials()) != nil
    }

    func fetch() async throws -> ProviderUsage {
        var loaded = try loadCredentials()
        if shouldRefresh(expiresAtMilliseconds: loaded.credential.expiresAt),
           loaded.credential.refreshToken?.isEmpty == false {
            loaded = try await refresh(loaded)
        }

        let data: Data
        do {
            data = try await requestUsage(accessToken: loaded.credential.accessToken)
        } catch ClaudeError.requestFailed(let status) where status == 401 {
            let latest = try loadCredentials()
            if latest.credential.accessToken != loaded.credential.accessToken {
                loaded = latest
            } else {
                loaded = try await refresh(loaded)
            }
            data = try await requestUsage(accessToken: loaded.credential.accessToken)
        }

        let usage = try JSONDecoder().decode(UsageEnvelope.self, from: data)
        let now = Date.now

        var lines: [UsageLine] = []
        if let fiveHour = usage.fiveHour,
           let line = usageLine(label: "Session", window: fiveHour) {
            lines.append(line)
        }
        if let sevenDay = usage.sevenDay,
           let line = usageLine(label: "Weekly", window: sevenDay) {
            lines.append(line)
        }
        guard !lines.isEmpty else {
            throw ClaudeError.malformedUsage
        }

        return ProviderUsage(
            providerId: .claude,
            plan: planLabel(
                subscription: loaded.credential.subscriptionType,
                tier: loaded.credential.rateLimitTier
            ),
            lines: lines,
            fetchedAt: now,
            detail: nil
        )
    }

    private func usageLine(label: String, window: DirectWindow) -> UsageLine? {
        guard let utilization = window.utilization else { return nil }
        return UsageLine(
            label: label,
            usedPercent: utilization.clampedPercent,
            resetsAt: parseISO8601(window.resetsAt),
            subtitle: nil
        )
    }

    private func planLabel(subscription: String?, tier: String?) -> String? {
        guard let subscription else { return nil }
        let base: String
        switch subscription.lowercased() {
        case "pro": base = "Pro"
        case "max": base = "Max"
        default: base = subscription.capitalized
        }
        guard let tier,
              let range = tier.range(of: #"[0-9]+x"#, options: .regularExpression) else {
            return base
        }
        return "\(base) \(tier[range])"
    }

    private func shouldRefresh(expiresAtMilliseconds: Int64?, now: Date = .now) -> Bool {
        guard let expiresAtMilliseconds else { return false }
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        return expiresAtMilliseconds <= nowMilliseconds + 5 * 60 * 1_000
    }

    private func loadCredentials() throws -> LoadedCredential {
        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            return LoadedCredential(
                credential: OAuthCredential(accessToken: token),
                source: .environment
            )
        }

        let configDirectory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
        let credentialFile = configDirectory.appendingPathComponent(".credentials.json")
        if let data = try? boundedData(from: credentialFile),
           let decoded = decodeCredential(from: data) {
            return LoadedCredential(
                credential: decoded.credential,
                source: .file(url: credentialFile, encoding: decoded.encoding)
            )
        }

        for service in keychainServices() {
            if let data = try? keychainData(service: service),
               let decoded = decodeCredential(from: data) {
                return LoadedCredential(
                    credential: decoded.credential,
                    source: .keychain(service: service, encoding: decoded.encoding)
                )
            }
        }
        throw ClaudeError.authUnavailable("未找到 Claude Code 登录态")
    }

    private func refresh(_ loaded: LoadedCredential) async throws -> LoadedCredential {
        guard let refreshToken = loaded.credential.refreshToken, !refreshToken.isEmpty else {
            throw ClaudeError.authUnavailable("Claude token 已过期且无法刷新，请重新登录 Claude Code")
        }
        let scopes = loaded.credential.scopes?.filter { !$0.isEmpty }
        let requestedScopes = (scopes?.isEmpty == false ? scopes : nil) ?? OAuthCredential.defaultScopes
        let body = RefreshRequest(
            grantType: "refresh_token",
            refreshToken: refreshToken,
            clientId: clientID,
            scope: requestedScopes.joined(separator: " ")
        )

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard data.count <= maximumPayloadSize else {
            throw ClaudeError.requestFailed(0)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ClaudeError.authUnavailable("Claude token 刷新失败（HTTP \(status)），请重新登录 Claude Code")
        }

        let responseBody = try JSONDecoder().decode(RefreshResponse.self, from: data)
        let refreshed = loaded.credential.merging(responseBody, fallbackRefreshToken: refreshToken)
        try persist(refreshed, to: loaded.source)
        return LoadedCredential(credential: refreshed, source: loaded.source)
    }

    private func requestUsage(accessToken: String) async throws -> Data {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.170", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard data.count <= maximumPayloadSize else {
            throw ClaudeError.requestFailed(0)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ClaudeError.requestFailed(http.statusCode)
            }
            throw ClaudeError.requestFailed(http.statusCode)
        }
        return data
    }

    private func persist(_ credential: OAuthCredential, to source: CredentialSource) throws {
        guard source != .environment else { return }
        let encoded = try JSONEncoder().encode(CredentialEnvelope(claudeAiOauth: credential))

        switch source {
        case .environment:
            return
        case let .file(url, storageEncoding):
            let data = encodeForStorage(encoded, as: storageEncoding)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        case let .keychain(service, storageEncoding):
            let data = encodeForStorage(encoded, as: storageEncoding)
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service
            ]
            let update: [CFString: Any] = [kSecValueData: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else {
                throw ClaudeError.authUnavailable("无法写回刷新后的 Claude 凭证")
            }
        }
    }

    private func encodeForStorage(_ data: Data, as encoding: StorageEncoding) -> Data {
        switch encoding {
        case .json:
            return data
        case .hex:
            return Data(data.map { String(format: "%02x", $0) }.joined().utf8)
        }
    }

    private func keychainServices() -> [String] {
        let base = "Claude Code-credentials"
        guard let raw = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !raw.isEmpty else {
            return [base]
        }
        let normalized = raw.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return ["\(base)-\(suffix)", base]
    }

    private func keychainData(service: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw ClaudeError.authUnavailable("无法读取 Claude Keychain 凭证")
        }
        guard !data.isEmpty, data.count <= 262_144 else {
            throw ClaudeError.authUnavailable("Claude Keychain 凭证异常")
        }
        return data
    }

    private func decodeCredential(from data: Data) -> DecodedCredential? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(CredentialEnvelope.self, from: data),
           let credential = envelope.claudeAiOauth,
           !credential.accessToken.isEmpty {
            return DecodedCredential(credential: credential, encoding: .json)
        }

        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let hex = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return nil }
        var decoded = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            decoded.append(byte)
            index = next
        }
        guard let credential = (try? decoder.decode(CredentialEnvelope.self, from: decoded))?.claudeAiOauth,
              !credential.accessToken.isEmpty else {
            return nil
        }
        return DecodedCredential(credential: credential, encoding: .hex)
    }

    private func boundedData(from url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 262_144 else {
            throw ClaudeError.authUnavailable("Claude 凭证文件异常过大")
        }
        return try Data(contentsOf: url)
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum ClaudeError: LocalizedError {
    case authUnavailable(String)
    case requestFailed(Int)
    case malformedUsage

    var errorDescription: String? {
        switch self {
        case .authUnavailable(let message): return message
        case .requestFailed(let status):
            if status == 401 || status == 403 {
                return "Claude 会话已失效，请重新登录 Claude Code"
            }
            return "Claude 请求失败：HTTP \(status)"
        case .malformedUsage: return "Claude 用量数据为空或格式异常"
        }
    }
}

private extension ClaudeClient {
    enum StorageEncoding: Sendable {
        case json
        case hex
    }

    enum CredentialSource: Sendable, Equatable {
        case environment
        case file(url: URL, encoding: StorageEncoding)
        case keychain(service: String, encoding: StorageEncoding)
    }

    struct LoadedCredential: Sendable {
        let credential: OAuthCredential
        let source: CredentialSource
    }

    struct DecodedCredential: Sendable {
        let credential: OAuthCredential
        let encoding: StorageEncoding
    }

    struct CredentialEnvelope: Codable {
        let claudeAiOauth: OAuthCredential?
    }

    struct OAuthCredential: Codable, Sendable {
        static let defaultScopes = [
            "user:profile",
            "user:inference",
            "user:sessions:claude_code",
            "user:mcp_servers",
            "user:file_upload"
        ]

        let accessToken: String
        let refreshToken: String?
        let expiresAt: Int64?
        let scopes: [String]?
        let subscriptionType: String?
        let rateLimitTier: String?

        init(
            accessToken: String,
            refreshToken: String? = nil,
            expiresAt: Int64? = nil,
            scopes: [String]? = nil,
            subscriptionType: String? = nil,
            rateLimitTier: String? = nil
        ) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.scopes = scopes
            self.subscriptionType = subscriptionType
            self.rateLimitTier = rateLimitTier
        }

        func merging(_ response: RefreshResponse, fallbackRefreshToken: String) -> OAuthCredential {
            OAuthCredential(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken ?? fallbackRefreshToken,
                expiresAt: Int64((Date.now.timeIntervalSince1970 + response.expiresIn) * 1_000),
                scopes: response.scope?.split(separator: " ").map(String.init) ?? scopes,
                subscriptionType: subscriptionType,
                rateLimitTier: rateLimitTier
            )
        }
    }

    struct RefreshRequest: Encodable {
        let grantType: String
        let refreshToken: String
        let clientId: String
        let scope: String

        enum CodingKeys: String, CodingKey {
            case grantType = "grant_type"
            case refreshToken = "refresh_token"
            case clientId = "client_id"
            case scope
        }
    }

    struct RefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    struct UsageEnvelope: Decodable {
        let fiveHour: DirectWindow?
        let sevenDay: DirectWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    struct DirectWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}
