import Foundation
import Network
import Security

/// URLSession prefers IPv6. This machine's WireGuard tunnel only captures IPv4,
/// so chatgpt.com's IPv6 handshake is reset and URLSession reports
/// `NSURLErrorSecureConnectionFailed` (-1200). On that error, retry once over IPv4.
enum ReachableHTTP {
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await sessionData(for: request)
        } catch let error as URLError where error.code == .secureConnectionFailed {
            return try await ipv4Data(for: request)
        }
    }

    private static func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = request.timeoutInterval > 0 ? request.timeoutInterval : 20
        return try await URLSession(configuration: configuration).data(for: request)
    }

    private static func ipv4Data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let host = url.host, !host.isEmpty else {
            throw URLError(.badURL)
        }
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (url.scheme == "http" ? 80 : 443))) ?? 443
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 20

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(min(max(timeout, 1), 60))
        let parameters = url.scheme == "http" ? NWParameters.tcp : NWParameters(tls: tls, tcp: tcp)
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let payload = try httpRequestData(request, host: host, port: Int(port.rawValue))

        return try await withCheckedThrowingContinuation { continuation in
            let exchange = IPv4Exchange(connection: connection, request: payload, url: url, timeout: timeout, continuation: continuation)
            exchange.start()
        }
    }

    private static func httpRequestData(_ request: URLRequest, host: String, port: Int) throws -> Data {
        let method = request.httpMethod ?? "GET"
        var path = request.url?.path ?? "/"
        if path.isEmpty { path = "/" }
        if let query = request.url?.query, !query.isEmpty {
            path += "?\(query)"
        }
        let defaultPort = request.url?.scheme == "http" ? 80 : 443
        let hostHeader = port == defaultPort ? host : "\(host):\(port)"
        var headers: [(String, String)] = [
            ("Host", hostHeader),
            ("Connection", "close"),
            ("Accept-Encoding", "identity")
        ]
        request.allHTTPHeaderFields?.forEach { name, value in
            let lower = name.lowercased()
            if lower == "host" || lower == "connection" || lower == "content-length" || lower == "accept-encoding" {
                return
            }
            headers.append((name, value))
        }
        let body = request.httpBody ?? Data()
        if request.httpBody != nil {
            headers.append(("Content-Length", "\(body.count)"))
        }
        var text = "\(method) \(path) HTTP/1.1\r\n"
        text += headers.map { "\($0.0): \($0.1)" }.joined(separator: "\r\n")
        text += "\r\n\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}

private final class IPv4Exchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let url: URL
    private let timeout: TimeInterval
    private let continuation: CheckedContinuation<(Data, URLResponse), Error>
    private let lock = NSLock()
    private var resumed = false
    private var buffer = Data()
    private var keepAlive: IPv4Exchange?
    private let maximumBytes = 2_097_152

    init(
        connection: NWConnection,
        request: Data,
        url: URL,
        timeout: TimeInterval,
        continuation: CheckedContinuation<(Data, URLResponse), Error>
    ) {
        self.connection = connection
        self.request = request
        self.url = url
        self.timeout = timeout
        self.continuation = continuation
    }

    func start() {
        keepAlive = self
        let queue = DispatchQueue(label: "local.QuotaDuo.ipv4")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send()
            case .failed(let error):
                self.finish(.failure(error))
            case .cancelled:
                self.finish(.failure(URLError(.cancelled)))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.isResumed else { return }
            self.connection.cancel()
            self.finish(.failure(URLError(.timedOut)))
        }
    }

    private var isResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }

    private func send() {
        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(.failure(error))
                return
            }
            self?.receive()
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.buffer.count > self.maximumBytes {
                    self.connection.cancel()
                    self.finish(.failure(URLError(.dataLengthExceedsMaximum)))
                    return
                }
            }
            if let response = self.completeResponse() {
                self.connection.cancel()
                self.finish(.success(response))
                return
            }
            if let error {
                self.finish(.failure(error))
                return
            }
            if isComplete {
                if let response = self.completeResponse(allowConnectionClose: true) {
                    self.finish(.success(response))
                } else {
                    self.finish(.failure(URLError(.badServerResponse)))
                }
                return
            }
            self.receive()
        }
    }

    private func completeResponse(allowConnectionClose: Bool = false) -> (Data, URLResponse)? {
        guard let marker = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[..<marker.lowerBound]
        var body = Data(buffer[marker.upperBound...])
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[name] = value
        }
        let encoding = fields.first { $0.key.lowercased() == "transfer-encoding" }?.value.lowercased() ?? ""
        if encoding.contains("chunked") {
            guard allowConnectionClose || chunkedBodyIsComplete(body) else { return nil }
            guard let decoded = decodeChunks(body) else { return nil }
            body = decoded
        } else if let lengthText = fields.first(where: { $0.key.lowercased() == "content-length" })?.value,
                  let length = Int(lengthText) {
            guard body.count >= length else { return nil }
            body = Data(body.prefix(length))
        } else if !allowConnectionClose {
            return nil
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)
            ?? HTTPURLResponse()
        return (body, response)
    }

    private func chunkedBodyIsComplete(_ data: Data) -> Bool {
        decodeChunks(data) != nil
    }

    private func decodeChunks(_ data: Data) -> Data? {
        var index = data.startIndex
        var output = Data()
        while index < data.endIndex {
            guard let lineEnd = data[index...].range(of: Data("\r\n".utf8)) else { return nil }
            let sizeLine = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            index = lineEnd.upperBound
            if size == 0 { return output }
            guard data.distance(from: index, to: data.endIndex) >= size + 2 else { return nil }
            output.append(data[index..<data.index(index, offsetBy: size)])
            index = data.index(index, offsetBy: size + 2)
        }
        return nil
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        connection.cancel()
        continuation.resume(with: result)
        keepAlive = nil
    }
}
