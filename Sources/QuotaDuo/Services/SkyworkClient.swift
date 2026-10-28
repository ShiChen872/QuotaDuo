import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

struct SkyworkClient: Sendable {
    private let benefitsURL = URL(string: "https://api.skywork.ai/marketing/mark/get_user_benefits")!
    private let detailURL = URL(string: "https://api.skywork.ai/marketing/mark/detail")!
    private let clientKeysURL = URL(string: "https://static-s3.skyworkcdn.com/fe/skywork-client-config/client-keys.js")!
    /// Public browser HMAC secret shipped in client-keys.js (not a user credential).
    private let fallbackAuthorizeSecret = "2DCKzOel4s0ismPf2d4nAQkwp9Tmh3mKhMt5QuG6qUc="
    private let monthlyQuota: Double = 10_000
    private static let detailSplitSource = "detail"
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

    /// Automatic refresh passes `includeDetail: false` and only reads the safe
    /// benefits total. The panel's refresh button passes `true` and reads
    /// `/marketing/mark/detail` once. That endpoint can return 630120 and kick
    /// the Chrome login, so a failure is not retried and is not treated as a
    /// dead session.
    func fetch(includeDetail: Bool = false) async throws -> ProviderUsage {
        let first = try loadSession(forceChrome: false)
        do {
            return try await fetchWithSession(first, includeDetail: includeDetail)
        } catch let error as SkyworkError where error.isAuthFailure && first.canRefreshFromChrome {
            Self.state.clearSession()
            try? FileManager.default.removeItem(at: Self.sessionFileURL())
            return try await fetchWithSession(try loadSession(forceChrome: true), includeDetail: includeDetail)
        }
    }

    static func detailRequestCount() -> Int {
        state.detailRequestCount()
    }

    private func fetchWithSession(_ session: SkyworkSession, includeDetail: Bool) async throws -> ProviderUsage {
        let secret = await loadAuthorizeSecret()
        let now = Date.now
        let benefits = try await loadBenefits(session: session, secret: secret)
        let plan = benefits.plan
        let total = benefits.total

        if includeDetail {
            switch await readDetailOnce(session: session, secret: secret, total: total) {
            case .ready(let snapshot):
                persistSession(session, snapshot: snapshot)
                return makeUsage(total: total, plan: plan, now: now, split: snapshot, note: nil)
            case .deviceLimit:
                return makeUsage(total: total, plan: plan, now: now, split: nil, note: "设备数限制，未读取分桶")
            case .unavailable:
                return makeUsage(total: total, plan: plan, now: now, split: nil, note: "未读取分桶")
            }
        }

        if let snapshot = loadDetailSnapshot(), abs(snapshot.total - total) <= 1 {
            return makeUsage(total: total, plan: plan, now: now, split: snapshot, note: nil)
        }
        return makeUsage(total: total, plan: plan, now: now, split: nil, note: "分桶需点一次刷新")
    }

    private func loadBenefits(session: SkyworkSession, secret: String) async throws -> (plan: String, total: Double) {
        let benefitsData = try await request(
            benefitsURL,
            method: "POST",
            session: session,
            secret: secret,
            body: Data("{}".utf8)
        )
        let envelope = try JSONDecoder().decode(BenefitsEnvelope.self, from: benefitsData)
        if Self.isAuthCode(envelope.code) {
            throw SkyworkError.authUnavailable("Skywork 会话已失效，请在 Chrome 重新登录 skywork.ai")
        }
        guard envelope.code == 0, let data = envelope.data, let remaining = data.markBalance else {
            throw SkyworkError.malformedUsage
        }
        let plan = data.membershipTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Basic"
        return (plan, remaining)
    }

    private func readDetailOnce(
        session: SkyworkSession,
        secret: String,
        total: Double
    ) async -> DetailRead {
        Self.state.bumpDetailRequest()
        do {
            let data = try await request(
                detailURL,
                method: "POST",
                session: session,
                secret: secret,
                body: Data("{}".utf8)
            )
            let envelope = try JSONDecoder().decode(DetailEnvelope.self, from: data)
            if envelope.code == 630120 {
                return .deviceLimit
            }
            guard envelope.code == 0, let payload = envelope.data else {
                return .unavailable
            }
            let snapshot = Self.snapshot(from: payload, total: total)
            if snapshot.partSum <= 0.5 && total > 0.5 {
                return .unavailable
            }
            return .ready(snapshot)
        } catch {
            return .unavailable
        }
    }

    private func makeUsage(
        total: Double,
        plan: String,
        now: Date,
        split: DetailSnapshot?,
        note: String?
    ) -> ProviderUsage {
        let menuBar = min(100, total / monthlyQuota * 100)
        let detail: String
        let lines: [UsageLine]
        if let split {
            let parts = [
                creditPart("登录", split.daily, expiry: split.dailyExpiresAt),
                creditPart("充值", split.recharge),
                creditPart("会员", split.member),
                creditPart("活动", split.event),
                creditPart("免费", split.fresh),
                creditPart("会员活动", split.memberActivity)
            ].compactMap { $0 }
            detail = parts.isEmpty
                ? "剩余 \(formatCredits(total))"
                : "剩余 \(formatCredits(total))（\(parts.joined(separator: " · "))）"
            lines = splitLines(split)
        } else {
            let suffix = note.map { "（\($0)）" } ?? ""
            detail = "剩余 \(formatCredits(total))\(suffix)"
            let capped = min(total, monthlyQuota)
            lines = [
                UsageLine(
                    label: "合计",
                    usedPercent: (max(0, monthlyQuota - capped) / monthlyQuota * 100).clampedPercent,
                    resetsAt: nil,
                    subtitle: formatCredits(total)
                )
            ]
        }
        return ProviderUsage(
            providerId: .skywork,
            plan: plan,
            lines: lines,
            fetchedAt: now,
            detail: detail,
            menuBarRemainingPercent: menuBar
        )
    }

    private func splitLines(_ split: DetailSnapshot) -> [UsageLine] {
        let memberAmount = split.member > monthlyQuota + 0.5
            ? formatCredits(split.member)
            : "\(formatCredits(split.member)) / \(formatCredits(monthlyQuota))"
        let memberSubtitle = split.memberExpiresAt.map { "\(memberAmount) · \(formatExpiry($0))" } ?? memberAmount
        let memberUsed = split.member > monthlyQuota
            ? 0
            : (max(0, monthlyQuota - split.member) / monthlyQuota * 100).clampedPercent
        var lines = [
            UsageLine(
                label: "会员",
                usedPercent: memberUsed,
                resetsAt: split.memberExpiresAt,
                subtitle: memberSubtitle
            )
        ]
        if split.recharge > 0.5 {
            lines.append(
                UsageLine(
                    label: "充值",
                    usedPercent: 0,
                    resetsAt: split.rechargeExpiresAt,
                    subtitle: formatCredits(split.recharge)
                )
            )
        }
        return lines
    }

    private func creditPart(_ name: String, _ value: Double, expiry: Date? = nil) -> String? {
        guard value > 0.5 else { return nil }
        if let expiry {
            return "\(name) \(formatCredits(value)) 至 \(formatExpiry(expiry))"
        }
        return "\(name) \(formatCredits(value))"
    }

    private static func isAuthCode(_ code: Int) -> Bool {
        code == 401 || code == 403 || code == 630120
    }

    private func formatCredits(_ value: Double) -> String {
        let rounded = value.rounded()
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: rounded)) ?? "\(Int(rounded))"
    }

    private func formatExpiry(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    private static func snapshot(from payload: DetailData, total: Double) -> DetailSnapshot {
        DetailSnapshot(
            total: total,
            daily: balance(of: payload.dailyCredits),
            dailyExpiresAt: earliestExpiry(in: payload.dailyCredits),
            recharge: balance(of: payload.payCredits),
            rechargeExpiresAt: earliestExpiry(in: payload.payCredits),
            member: balance(of: payload.memberCredits),
            memberExpiresAt: earliestExpiry(in: payload.memberCredits),
            event: balance(of: payload.eventCredits),
            fresh: balance(of: payload.freshCredits),
            memberActivity: balance(of: payload.memberActivityCredits)
        )
    }

    private static func balance(of bucket: CreditBucket?) -> Double {
        max(0, bucket?.creditsBalance ?? 0)
    }

    /// Soonest expiry among packages that still have a balance.
    private static func earliestExpiry(in bucket: CreditBucket?) -> Date? {
        let packages = bucket?.detail ?? []
        let funded = packages.filter { ($0.creditsBalance ?? 0) > 0.5 }
        let pool = funded.isEmpty ? packages : funded
        let dates = pool.compactMap { package -> Date? in
            guard let raw = package.expireAt, raw > 0 else { return nil }
            let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
            return Date(timeIntervalSince1970: seconds)
        }
        return dates.min()
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

    private func persistSession(_ session: SkyworkSession, snapshot: DetailSnapshot? = nil) {
        let url = Self.sessionFileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try? JSONDecoder().decode(PersistedSession.self, from: Data(contentsOf: url))
        let stored = PersistedSession(
            cookieHeader: session.cookieHeader,
            deviceHash: session.deviceHash,
            monthlyRemaining: snapshot?.member ?? existing?.monthlyRemaining,
            rechargeRemaining: snapshot?.recharge ?? existing?.rechargeRemaining,
            leftoverRemaining: snapshot == nil ? existing?.leftoverRemaining : 0,
            rechargeExpiresAt: snapshot == nil
                ? existing?.rechargeExpiresAt
                : snapshot?.rechargeExpiresAt?.timeIntervalSince1970,
            cycleResetsAt: snapshot == nil
                ? existing?.cycleResetsAt
                : snapshot?.memberExpiresAt?.timeIntervalSince1970,
            splitSource: snapshot == nil ? existing?.splitSource : Self.detailSplitSource,
            splitTotal: snapshot?.total ?? existing?.splitTotal,
            dailyRemaining: snapshot?.daily ?? existing?.dailyRemaining,
            dailyExpiresAt: snapshot == nil
                ? existing?.dailyExpiresAt
                : snapshot?.dailyExpiresAt?.timeIntervalSince1970,
            eventRemaining: snapshot?.event ?? existing?.eventRemaining,
            freshRemaining: snapshot?.fresh ?? existing?.freshRemaining,
            memberActivityRemaining: snapshot?.memberActivity ?? existing?.memberActivityRemaining
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Inferred ledgers written before `splitSource == detail` are not a real split.
    private func loadDetailSnapshot() -> DetailSnapshot? {
        guard let stored = try? JSONDecoder().decode(
            PersistedSession.self,
            from: Data(contentsOf: Self.sessionFileURL())
        ), stored.splitSource == Self.detailSplitSource, let total = stored.splitTotal else {
            return nil
        }
        return DetailSnapshot(
            total: total,
            daily: stored.dailyRemaining ?? 0,
            dailyExpiresAt: stored.dailyExpiresAt.map { Date(timeIntervalSince1970: $0) },
            recharge: stored.rechargeRemaining ?? 0,
            rechargeExpiresAt: stored.rechargeExpiresAt.map { Date(timeIntervalSince1970: $0) },
            member: stored.monthlyRemaining ?? 0,
            memberExpiresAt: stored.cycleResetsAt.map { Date(timeIntervalSince1970: $0) },
            event: stored.eventRemaining ?? 0,
            fresh: stored.freshRemaining ?? 0,
            memberActivity: stored.memberActivityRemaining ?? 0
        )
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
            let (data, response) = try await ReachableHTTP.data(for: request)
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

        let (data, response) = try await ReachableHTTP.data(for: request)
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
        private var detailRequests = 0

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

        func bumpDetailRequest() {
            lock.lock()
            detailRequests += 1
            lock.unlock()
        }

        func detailRequestCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return detailRequests
        }
    }

    struct SkyworkSession: Sendable {
        let cookieHeader: String
        let deviceHash: String
        let canRefreshFromChrome: Bool
    }

    enum DetailRead {
        case ready(DetailSnapshot)
        case deviceLimit
        case unavailable
    }

    struct DetailSnapshot: Sendable {
        var total: Double
        var daily: Double
        var dailyExpiresAt: Date?
        var recharge: Double
        var rechargeExpiresAt: Date?
        var member: Double
        var memberExpiresAt: Date?
        var event: Double
        var fresh: Double
        var memberActivity: Double

        var partSum: Double {
            daily + recharge + member + event + fresh + memberActivity
        }
    }

    struct PersistedSession: Codable, Sendable {
        let cookieHeader: String
        let deviceHash: String
        var monthlyRemaining: Double?
        var rechargeRemaining: Double?
        var leftoverRemaining: Double?
        var rechargeExpiresAt: TimeInterval?
        var cycleResetsAt: TimeInterval?
        /// `"detail"` marks balances copied from `/marketing/mark/detail`. Older files are inferred and ignored.
        var splitSource: String? = nil
        var splitTotal: Double? = nil
        var dailyRemaining: Double? = nil
        var dailyExpiresAt: TimeInterval? = nil
        var eventRemaining: Double? = nil
        var freshRemaining: Double? = nil
        var memberActivityRemaining: Double? = nil
    }

    struct DetailEnvelope: Decodable {
        let code: Int
        let data: DetailData?
    }

    struct DetailData: Decodable {
        let dailyCredits: CreditBucket?
        let freshCredits: CreditBucket?
        let payCredits: CreditBucket?
        let eventCredits: CreditBucket?
        let memberCredits: CreditBucket?
        let memberActivityCredits: CreditBucket?

        enum CodingKeys: String, CodingKey {
            case dailyCredits = "daily_credits"
            case freshCredits = "fresh_credits"
            case payCredits = "pay_credits"
            case eventCredits = "event_credits"
            case memberCredits = "member_credits"
            case memberActivityCredits = "member_activity_credits"
        }
    }

    struct CreditBucket: Decodable {
        let creditsBalance: Double?
        let detail: [CreditPackage]?

        enum CodingKeys: String, CodingKey {
            case creditsBalance = "credits_balance"
            case detail
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            creditsBalance = container.decodeFlexibleDouble(forKey: .creditsBalance)
            detail = try container.decodeIfPresent([CreditPackage].self, forKey: .detail)
        }
    }

    struct CreditPackage: Decodable {
        let creditsBalance: Double?
        let expireAt: Double?

        enum CodingKeys: String, CodingKey {
            case creditsBalance = "credits_balance"
            case expireAt = "expire_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            creditsBalance = container.decodeFlexibleDouble(forKey: .creditsBalance)
            expireAt = container.decodeFlexibleDouble(forKey: .expireAt)
        }
    }

    struct BenefitsEnvelope: Decodable {
        let code: Int
        let data: BenefitsData?
    }

    struct BenefitsData: Decodable {
        let membershipTitle: String?
        let markBalance: Double?
        let benefitBalanceMap: [String: BenefitBucket]?

        var dailyLoginBalance: Double? {
            benefitBalanceMap?["daily_login_mark"]?.benefitBalance
        }

        enum CodingKeys: String, CodingKey {
            case membershipTitle = "membership_title"
            case markBalance = "mark_balance"
            case benefitBalanceMap = "benefit_balance_map"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            membershipTitle = try container.decodeIfPresent(String.self, forKey: .membershipTitle)
            markBalance = container.decodeFlexibleDouble(forKey: .markBalance)
            benefitBalanceMap = try container.decodeIfPresent([String: BenefitBucket].self, forKey: .benefitBalanceMap)
        }
    }

    struct BenefitBucket: Decodable {
        let benefitBalance: Double?

        enum CodingKeys: String, CodingKey {
            case benefitBalance = "benefit_balance"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            benefitBalance = container.decodeFlexibleDouble(forKey: .benefitBalance)
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let raw = try? decodeIfPresent(String.self, forKey: key) {
            return Double(raw.replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }
}
