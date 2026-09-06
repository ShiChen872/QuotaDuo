import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

struct SkyworkClient: Sendable {
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

        // get_user_benefits is the safe source. /marketing/mark/detail returns
        // 630120 on extra device sessions and can kick the browser login.
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

        let daily = data.dailyLoginBalance ?? 0
        let buckets = Self.allocate(
            total: remaining,
            daily: daily,
            now: now,
            previous: loadPersistedBuckets(),
            monthlyQuota: monthlyQuota
        )
        persistSession(session, credits: buckets)

        let plan = data.membershipTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Basic"
        let stackedPercent = min(100, buckets.total / monthlyQuota * 100)
        let parts = [
            ("会员", buckets.monthly),
            ("充值", buckets.recharge),
            ("存留", buckets.leftover),
            ("登录", buckets.daily)
        ].filter { $0.1 > 0.5 }.map { "\($0.0) \(formatCredits($0.1))" }

        var lines = [
            UsageLine(
                label: "月度",
                usedPercent: (max(0, monthlyQuota - buckets.monthly) / monthlyQuota * 100).clampedPercent,
                resetsAt: buckets.cycleResetsAt,
                subtitle: "\(formatCredits(buckets.monthly)) / \(formatCredits(monthlyQuota))"
            )
        ]
        if buckets.recharge > 0.5 {
            lines.append(
                UsageLine(
                    label: "充值",
                    usedPercent: (max(0, monthlyQuota - buckets.recharge) / monthlyQuota * 100).clampedPercent,
                    resetsAt: buckets.rechargeExpiresAt,
                    subtitle: formatCredits(buckets.recharge)
                )
            )
        }

        return ProviderUsage(
            providerId: .skywork,
            plan: plan,
            lines: lines,
            fetchedAt: now,
            detail: parts.isEmpty
                ? "剩余 \(formatCredits(buckets.total)) / \(formatCredits(monthlyQuota))"
                : "剩余 \(formatCredits(buckets.total))（\(parts.joined(separator: " · "))）",
            menuBarRemainingPercent: stackedPercent
        )
    }

    private static func isAuthCode(_ code: Int) -> Bool {
        code == 401 || code == 403 || code == 630120
    }

    /// Split spendable credits into monthly membership + extra recharge.
    /// Benefits only returns a combined `mark_balance`; we keep a local ledger
    /// so a ~10,000 grant on the 14th is monthly, and other increases are 充值.
    private static func allocate(
        total: Double,
        daily: Double,
        now: Date,
        previous: SkyworkBuckets?,
        monthlyQuota: Double
    ) -> SkyworkBuckets {
        let other = max(0, total - daily)
        let cycleResetsAt = nextMonthlyReset(from: now)

        guard let previous else {
            return initialAllocate(other: other, daily: daily, now: now, cycleResetsAt: cycleResetsAt, monthlyQuota: monthlyQuota)
        }

        var monthly = previous.monthly
        var recharge = previous.recharge
        var leftover = previous.leftover
        var rechargeExpiresAt = previous.rechargeExpiresAt

        if now >= previous.cycleResetsAt {
            monthly = 0
        }

        let previousOther = monthly + recharge + leftover
        let delta = other - previousOther

        if delta < -0.5 {
            var spend = -delta
            let fromMonthly = min(monthly, spend)
            monthly -= fromMonthly
            spend -= fromMonthly
            let fromLeftover = min(leftover, spend)
            leftover -= fromLeftover
            spend -= fromLeftover
            recharge = max(0, recharge - spend)
        } else if delta > 0.5 {
            if abs(delta - monthlyQuota) < 500 {
                monthly = min(monthlyQuota, monthly + delta)
                if monthly > monthlyQuota {
                    recharge += monthly - monthlyQuota
                    monthly = monthlyQuota
                }
            } else {
                recharge += delta
                if rechargeExpiresAt == nil || rechargeExpiresAt! < now {
                    rechargeExpiresAt = now.addingTimeInterval(Self.rechargeValidity)
                }
            }
        }

        let sum = monthly + recharge + leftover
        if abs(sum - other) > 1 {
            if sum <= 0 {
                recharge = other
                monthly = 0
                leftover = 0
            } else {
                let scale = other / sum
                monthly *= scale
                recharge *= scale
                leftover *= scale
            }
        }

        return SkyworkBuckets(
            monthly: monthly,
            recharge: recharge,
            leftover: leftover,
            daily: daily,
            rechargeExpiresAt: rechargeExpiresAt,
            cycleResetsAt: cycleResetsAt
        )
    }

    private static let rechargeValidity: TimeInterval = 90 * 24 * 60 * 60

    private static func initialAllocate(
        other: Double,
        daily: Double,
        now: Date,
        cycleResetsAt: Date,
        monthlyQuota: Double
    ) -> SkyworkBuckets {
        if other > monthlyQuota + 0.5 {
            return SkyworkBuckets(
                monthly: monthlyQuota,
                recharge: other - monthlyQuota,
                leftover: 0,
                daily: daily,
                rechargeExpiresAt: now.addingTimeInterval(rechargeValidity),
                cycleResetsAt: cycleResetsAt
            )
        }
        // Fresh monthly grant is close to 10,000. A mid-cycle leftover that is
        // clearly below that is treated as extra 充值 (monthly already spent).
        if other >= monthlyQuota * 0.95 {
            return SkyworkBuckets(
                monthly: other,
                recharge: 0,
                leftover: 0,
                daily: daily,
                rechargeExpiresAt: nil,
                cycleResetsAt: cycleResetsAt
            )
        }
        return SkyworkBuckets(
            monthly: 0,
            recharge: other,
            leftover: 0,
            daily: daily,
            rechargeExpiresAt: now.addingTimeInterval(rechargeValidity),
            cycleResetsAt: cycleResetsAt
        )
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
        persistSession(session, credits: nil)
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

    private func persistSession(_ session: SkyworkSession, credits: SkyworkBuckets?) {
        let url = Self.sessionFileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try? JSONDecoder().decode(PersistedSession.self, from: Data(contentsOf: url))
        let stored = PersistedSession(
            cookieHeader: session.cookieHeader,
            deviceHash: session.deviceHash,
            monthlyRemaining: credits?.monthly ?? existing?.monthlyRemaining,
            rechargeRemaining: credits?.recharge ?? existing?.rechargeRemaining,
            leftoverRemaining: credits?.leftover ?? existing?.leftoverRemaining,
            rechargeExpiresAt: credits?.rechargeExpiresAt?.timeIntervalSince1970 ?? existing?.rechargeExpiresAt,
            cycleResetsAt: credits?.cycleResetsAt.timeIntervalSince1970 ?? existing?.cycleResetsAt
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func loadPersistedBuckets() -> SkyworkBuckets? {
        guard let stored = try? JSONDecoder().decode(
            PersistedSession.self,
            from: Data(contentsOf: Self.sessionFileURL())
        ) else {
            return nil
        }
        guard stored.monthlyRemaining != nil || stored.rechargeRemaining != nil else {
            return nil
        }
        let cycle = stored.cycleResetsAt.map { Date(timeIntervalSince1970: $0) }
            ?? Self.nextMonthlyReset(from: .now)
        return SkyworkBuckets(
            monthly: stored.monthlyRemaining ?? 0,
            recharge: stored.rechargeRemaining ?? 0,
            leftover: stored.leftoverRemaining ?? 0,
            daily: 0,
            rechargeExpiresAt: stored.rechargeExpiresAt.map { Date(timeIntervalSince1970: $0) },
            cycleResetsAt: cycle
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

    struct SkyworkBuckets: Sendable {
        var monthly: Double
        var recharge: Double
        var leftover: Double
        var daily: Double
        var rechargeExpiresAt: Date?
        var cycleResetsAt: Date

        var total: Double { monthly + recharge + leftover + daily }
    }

    struct PersistedSession: Codable, Sendable {
        let cookieHeader: String
        let deviceHash: String
        var monthlyRemaining: Double?
        var rechargeRemaining: Double?
        var leftoverRemaining: Double?
        var rechargeExpiresAt: TimeInterval?
        var cycleResetsAt: TimeInterval?
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
