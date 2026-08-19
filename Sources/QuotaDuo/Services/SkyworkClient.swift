import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

struct SkyworkClient: Sendable {
    private let detailURL = URL(string: "https://api.skywork.ai/marketing/mark/detail")!
    private let benefitsURL = URL(string: "https://api.skywork.ai/marketing/mark/get_user_benefits")!
    private let clientKeysURL = URL(string: "https://static-s3.skyworkcdn.com/fe/skywork-client-config/client-keys.js")!
    /// Public browser HMAC secret shipped in client-keys.js (not a user credential).
    private let fallbackAuthorizeSecret = "2DCKzOel4s0ismPf2d4nAQkwp9Tmh3mKhMt5QuG6qUc="
    private let monthlyQuota: Double = 10_000
    private let maximumPayloadSize = 1_048_576

    func isConfigured() -> Bool {
        if let env = ProcessInfo.processInfo.environment["SKYWORK_COOKIE"], !env.isEmpty {
            return true
        }
        if Self.state.session() != nil {
            return true
        }
        if FileManager.default.fileExists(atPath: Self.sessionFileURL().path) {
            return true
        }
        return chromeHasTokenCookie()
    }

    func fetch() async throws -> ProviderUsage {
        let first = try loadSession(forceChrome: false)
        do {
            return try await fetchWithSession(first)
        } catch let error as SkyworkError where error.isAuthFailure && first.canRefreshFromChrome {
            Self.state.clearSession()
            try? FileManager.default.removeItem(at: Self.sessionFileURL())
            return try await fetchWithSession(try loadSession(forceChrome: true))
        }
    }

    private func fetchWithSession(_ session: SkyworkSession) async throws -> ProviderUsage {
        let secret = await loadAuthorizeSecret()
        let now = Date.now

        async let detailOutcome: Result<Data, Error> = {
            do {
                return .success(try await self.request(self.detailURL, method: "POST", session: session, secret: secret, body: nil))
            } catch {
                return .failure(error)
            }
        }()
        async let benefitsOutcome: Result<Data, Error> = {
            do {
                return .success(
                    try await self.request(
                        self.benefitsURL,
                        method: "POST",
                        session: session,
                        secret: secret,
                        body: Data("{}".utf8)
                    )
                )
            } catch {
                return .failure(error)
            }
        }()

        let (detailResult, benefitsResult) = await (detailOutcome, benefitsOutcome)
        let detailData = try detailResult.get()
        let envelope = try JSONDecoder().decode(DetailEnvelope.self, from: detailData)
        guard envelope.code == 0, let data = envelope.data else {
            if envelope.code == 401 {
                throw SkyworkError.authUnavailable("Skywork 会话已失效，请在 Chrome 重新登录 skywork.ai")
            }
            throw SkyworkError.malformedUsage
        }

        let member = data.memberCredits?.creditsBalance ?? 0
        let leftover = data.eventCredits?.creditsBalance ?? 0
        let daily = data.dailyCredits?.creditsBalance ?? 0
        let remaining = data.skyworkCredits ?? (member + leftover + daily)
        guard remaining > 0 || data.memberCredits != nil else {
            throw SkyworkError.malformedUsage
        }

        let usedPercent = max(0, monthlyQuota - remaining) / monthlyQuota * 100
        let resetsAt = latestExpiry(in: data.memberCredits) ?? Self.nextMonthlyReset(from: now)
        let plan = benefitsPlan(from: benefitsResult) ?? "Basic"
        let parts = [
            ("会员", member),
            ("存留", leftover),
            ("登录", daily)
        ].filter { $0.1 > 0 }.map { "\($0.0) \(formatCredits($0.1))" }
        let breakdown = parts.isEmpty ? nil : parts.joined(separator: " · ")

        return ProviderUsage(
            providerId: .skywork,
            plan: plan,
            lines: [
                UsageLine(
                    label: "月度",
                    usedPercent: usedPercent.clampedPercent,
                    resetsAt: resetsAt,
                    subtitle: "\(formatCredits(remaining)) / \(formatCredits(monthlyQuota))"
                )
            ],
            fetchedAt: now,
            detail: breakdown.map { "剩余 \(formatCredits(remaining))（\($0)）" }
                ?? "剩余 \(formatCredits(remaining)) / \(formatCredits(monthlyQuota))"
        )
    }

    private func benefitsPlan(from result: Result<Data, Error>) -> String? {
        guard case .success(let data) = result,
              let envelope = try? JSONDecoder().decode(BenefitsEnvelope.self, from: data),
              envelope.code == 0,
              let title = envelope.data?.membershipTitle,
              !title.isEmpty
        else {
            return nil
        }
        return title
    }

    private func latestExpiry(in bucket: CreditBucket?) -> Date? {
        let stamps = (bucket?.detail ?? []).compactMap(\.expireAt).filter { $0 > 0 }
        guard let latest = stamps.max() else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(latest) / 1_000)
    }

    private func formatCredits(_ value: Double) -> String {
        let rounded = value.rounded()
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: rounded)) ?? "\(Int(rounded))"
    }

    static func nextMonthlyReset(from now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month], from: now)
        components.day = 14
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard let thisMonth = calendar.date(from: components) else { return now }
        if thisMonth > now {
            return thisMonth
        }
        return calendar.date(byAdding: .month, value: 1, to: thisMonth) ?? thisMonth
    }

    private func loadSession(forceChrome: Bool) throws -> SkyworkSession {
        if let env = ProcessInfo.processInfo.environment["SKYWORK_COOKIE"], !env.isEmpty {
            return SkyworkSession(
                cookieHeader: env,
                deviceHash: cookieValue(named: "k_device_hash", in: env) ?? "",
                canRefreshFromChrome: false
            )
        }

        if !forceChrome, let cached = Self.state.session() {
            return cached
        }

        if !forceChrome, let stored = try? readPersistedSession() {
            Self.state.store(session: stored)
            return stored
        }

        let cookies = try readChromeCookies()
        guard let token = cookies["token"], !token.isEmpty else {
            throw SkyworkError.authUnavailable("未找到 Skywork 登录 Cookie，请先在 Chrome 登录 skywork.ai，或设置 SKYWORK_COOKIE")
        }
        let names = ["token", "k_device_hash", "uid", "language"]
        let header = names.compactMap { name -> String? in
            guard let value = cookies[name], !value.isEmpty else { return nil }
            return "\(name)=\(value)"
        }.joined(separator: "; ")
        let session = SkyworkSession(
            cookieHeader: header,
            deviceHash: cookies["k_device_hash"] ?? "",
            canRefreshFromChrome: false
        )
        Self.state.store(
            session: SkyworkSession(
                cookieHeader: header,
                deviceHash: cookies["k_device_hash"] ?? "",
                canRefreshFromChrome: true
            )
        )
        persistSession(session)
        return session
    }

    static func sessionFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quotaduo/skywork.json")
    }

    private func readPersistedSession() throws -> SkyworkSession {
        let data = try Data(contentsOf: Self.sessionFileURL())
        let stored = try JSONDecoder().decode(PersistedSession.self, from: data)
        guard !stored.cookieHeader.isEmpty else {
            throw SkyworkError.authUnavailable("本地 Skywork 会话为空")
        }
        return SkyworkSession(
            cookieHeader: stored.cookieHeader,
            deviceHash: stored.deviceHash,
            canRefreshFromChrome: true
        )
    }

    private func persistSession(_ session: SkyworkSession) {
        let url = Self.sessionFileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = PersistedSession(cookieHeader: session.cookieHeader, deviceHash: session.deviceHash)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func chromeHasTokenCookie() -> Bool {
        let chromeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        return chromeCookieDatabases(in: chromeRoot).contains { databaseHasSkyworkToken($0) }
    }

    private func databaseHasSkyworkToken(_ dbURL: URL) -> Bool {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("QuotaDuo-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)) != nil else {
            return false
        }
        defer { try? fm.removeItem(at: tempDir) }
        let tempDB = tempDir.appendingPathComponent("Cookies")
        guard (try? fm.copyItem(at: dbURL, to: tempDB)) != nil else { return false }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: dbURL.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: URL(fileURLWithPath: tempDB.path + suffix))
            }
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(tempDB.path, &db, flags, nil) == SQLITE_OK, let db else {
            return false
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT 1 FROM cookies
        WHERE host_key LIKE '%skywork.ai%' AND name = 'token'
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func cookieValue(named name: String, in header: String) -> String? {
        header.split(separator: ";").lazy.compactMap { part -> String? in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { return nil }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == name else { return nil }
            return String(trimmed[trimmed.index(after: eq)...])
        }.first
    }

    private func readChromeCookies() throws -> [String: String] {
        let chromeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        guard FileManager.default.fileExists(atPath: chromeRoot.path) else {
            throw SkyworkError.authUnavailable("未找到 Chrome，请先在 Chrome 登录 skywork.ai")
        }

        let profiles = chromeCookieDatabases(in: chromeRoot)
        guard !profiles.isEmpty else {
            throw SkyworkError.authUnavailable("未找到 Chrome Cookie 库")
        }

        let key = try chromeEncryptionKey()
        for database in profiles {
            if let cookies = try? decryptSkyworkCookies(from: database, key: key), cookies["token"] != nil {
                return cookies
            }
        }
        throw SkyworkError.authUnavailable("Chrome 中没有 Skywork 登录态，请先打开 skywork.ai 并登录")
    }

    private func chromeCookieDatabases(in root: URL) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        let defaultDB = root.appendingPathComponent("Default/Cookies")
        if fm.fileExists(atPath: defaultDB.path) {
            urls.append(defaultDB)
        }
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return urls
        }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            guard name.hasPrefix("Profile ") else { continue }
            let db = child.appendingPathComponent("Cookies")
            if fm.fileExists(atPath: db.path) {
                urls.append(db)
            }
        }
        return urls
    }

    private func decryptSkyworkCookies(from dbURL: URL, key: Data) throws -> [String: String] {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("QuotaDuo-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let tempDB = tempDir.appendingPathComponent("Cookies")
        try fm.copyItem(at: dbURL, to: tempDB)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: dbURL.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: URL(fileURLWithPath: tempDB.path + suffix))
            }
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(tempDB.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw SkyworkError.authUnavailable("无法读取 Chrome Cookie")
        }
        defer { sqlite3_close(db) }

        let version = cookieDatabaseVersion(db)
        let sql = """
        SELECT name, encrypted_value FROM cookies
        WHERE host_key LIKE '%skywork.ai%' AND name IN ('token', 'k_device_hash', 'uid', 'language');
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SkyworkError.authUnavailable("无法查询 Chrome Cookie")
        }
        defer { sqlite3_finalize(statement) }

        var cookies: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePointer = sqlite3_column_text(statement, 0) else { continue }
            let name = String(cString: namePointer)
            let bytes = sqlite3_column_bytes(statement, 1)
            guard bytes > 3, let blob = sqlite3_column_blob(statement, 1) else { continue }
            let encrypted = Data(bytes: blob, count: Int(bytes))
            if let value = try? decryptChromeCookie(encrypted, key: key, databaseVersion: version), !value.isEmpty {
                cookies[name] = value
            }
        }
        return cookies
    }

    private func cookieDatabaseVersion(_ db: OpaquePointer) -> Int {
        let sql = "SELECT value FROM meta WHERE key = 'version' LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else {
            return 0
        }
        return Int(String(cString: pointer)) ?? 0
    }

    private func chromeEncryptionKey() throws -> Data {
        if let cached = Self.state.encryptionKey() {
            return cached
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let passwordData = result as? Data, !passwordData.isEmpty else {
            throw SkyworkError.authUnavailable("无法读取 Chrome Safe Storage。若弹出钥匙串请点一次「始终允许」，或设置 SKYWORK_COOKIE")
        }

        var derived = Data(count: 16)
        let salt = Data("saltysalt".utf8)
        let deriveStatus = derived.withUnsafeMutableBytes { derivedBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        16
                    )
                }
            }
        }
        guard deriveStatus == kCCSuccess else {
            throw SkyworkError.authUnavailable("Chrome Cookie 密钥派生失败")
        }
        Self.state.store(encryptionKey: derived)
        return derived
    }

    private func decryptChromeCookie(_ blob: Data, key: Data, databaseVersion: Int) throws -> String {
        let prefix = blob.prefix(3)
        guard prefix == Data("v10".utf8) || prefix == Data("v11".utf8) else {
            throw SkyworkError.authUnavailable("Chrome Cookie 加密格式不支持")
        }
        let ciphertext = blob.dropFirst(3)
        let iv = Data(repeating: 0x20, count: 16)
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var outputLength: size_t = 0
        let outputCapacity = output.count
        let cipherCount = ciphertext.count
        let keyCount = key.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            keyCount,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress,
                            cipherCount,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw SkyworkError.authUnavailable("Chrome Cookie 解密失败")
        }
        var plain = output.prefix(outputLength)
        if databaseVersion >= 24, plain.count > 32 {
            plain = plain.dropFirst(32)
        }
        guard let text = String(data: plain, encoding: .utf8), !text.isEmpty else {
            throw SkyworkError.authUnavailable("Chrome Cookie 解密结果无效")
        }
        return text
    }

    private func loadAuthorizeSecret() async -> String {
        var request = URLRequest(url: clientKeysURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let text = String(data: data, encoding: .utf8),
                  let secret = Self.parseAuthorizeSecret(text)
            else {
                return fallbackAuthorizeSecret
            }
            return secret
        } catch {
            return fallbackAuthorizeSecret
        }
    }

    static func parseAuthorizeSecret(_ javascript: String) -> String? {
        let pattern = #"apiAuthorizeSecret\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: javascript,
                range: NSRange(javascript.startIndex..., in: javascript)
              ),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: javascript)
        else {
            return nil
        }
        let value = String(javascript[range])
        return value.isEmpty ? nil : value
    }

    private func request(
        _ url: URL,
        method: String,
        session: SkyworkSession,
        secret: String,
        body: Data?
    ) async throws -> Data {
        let timestamp = String(Int(Date.now.timeIntervalSince1970 * 1_000))
        let lastSegment = url.path.split(separator: "/").last.map(String.init) ?? ""
        let verification = [method.lowercased(), lastSegment, timestamp].joined(separator: "_")
        let sign = hmacSHA256Hex(message: verification, secret: secret)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://skywork.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://skywork.ai/", forHTTPHeaderField: "Referer")
        request.setValue("web", forHTTPHeaderField: "device")
        request.setValue(session.deviceHash, forHTTPHeaderField: "device_id")
        request.setValue(session.deviceHash, forHTTPHeaderField: "device_hash")
        request.setValue("", forHTTPHeaderField: "channel")
        request.setValue("", forHTTPHeaderField: "ht")
        request.setValue(Self.timeZoneHeader(), forHTTPHeaderField: "time_zone")
        request.setValue(timestamp, forHTTPHeaderField: "timestamp")
        request.setValue(sign, forHTTPHeaderField: "sign")
        request.setValue(verification, forHTTPHeaderField: "verification-sign")
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SkyworkError.requestFailed("无响应")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SkyworkError.authUnavailable("Skywork 会话已失效，请在 Chrome 重新登录 skywork.ai")
        }
        guard http.statusCode == 200 else {
            throw SkyworkError.requestFailed("HTTP \(http.statusCode)")
        }
        guard data.count <= maximumPayloadSize else {
            throw SkyworkError.requestFailed("响应过大")
        }
        return data
    }

    private func hmacSHA256Hex(message: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func timeZoneHeader(now: Date = .now) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: now)
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        return String(format: "UTC%@%02d:%02d", sign, hours, minutes)
    }
}

enum SkyworkError: LocalizedError {
    case authUnavailable(String)
    case requestFailed(String)
    case malformedUsage

    var isAuthFailure: Bool {
        if case .authUnavailable = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .authUnavailable(let message): return message
        case .requestFailed(let message): return "Skywork 请求失败：\(message)"
        case .malformedUsage: return "Skywork 用量数据为空或格式异常"
        }
    }
}

private extension SkyworkClient {
    static let state = SharedState()

    final class SharedState: @unchecked Sendable {
        private let lock = NSLock()
        private var cachedSession: SkyworkSession?
        private var cachedEncryptionKey: Data?

        func session() -> SkyworkSession? {
            lock.lock()
            defer { lock.unlock() }
            return cachedSession
        }

        func store(session: SkyworkSession) {
            lock.lock()
            cachedSession = session
            lock.unlock()
        }

        func clearSession() {
            lock.lock()
            cachedSession = nil
            lock.unlock()
        }

        func encryptionKey() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return cachedEncryptionKey
        }

        func store(encryptionKey: Data) {
            lock.lock()
            cachedEncryptionKey = encryptionKey
            lock.unlock()
        }
    }

    struct SkyworkSession: Sendable {
        let cookieHeader: String
        let deviceHash: String
        let canRefreshFromChrome: Bool
    }

    struct PersistedSession: Codable, Sendable {
        let cookieHeader: String
        let deviceHash: String
    }

    struct DetailEnvelope: Decodable {
        let code: Int
        let message: String?
        let data: DetailData?
    }

    struct DetailData: Decodable {
        let skyworkCredits: Double?
        let memberCredits: CreditBucket?
        let eventCredits: CreditBucket?
        let dailyCredits: CreditBucket?

        enum CodingKeys: String, CodingKey {
            case skyworkCredits = "skywork_credits"
            case memberCredits = "member_credits"
            case eventCredits = "event_credits"
            case dailyCredits = "daily_credits"
        }
    }

    struct CreditBucket: Decodable {
        let creditsBalance: Double?
        let detail: [CreditPackage]?

        enum CodingKeys: String, CodingKey {
            case creditsBalance = "credits_balance"
            case detail
        }
    }

    struct CreditPackage: Decodable {
        let expireAt: Int64?

        enum CodingKeys: String, CodingKey {
            case expireAt = "expire_at"
        }
    }

    struct BenefitsEnvelope: Decodable {
        let code: Int
        let data: BenefitsData?
    }

    struct BenefitsData: Decodable {
        let membershipTitle: String?

        enum CodingKeys: String, CodingKey {
            case membershipTitle = "membership_title"
        }
    }
}
