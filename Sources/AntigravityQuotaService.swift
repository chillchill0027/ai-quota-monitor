import Foundation

/// Communicates with the local Google Antigravity Language Server Connect RPC endpoint.
/// Only retrieves metadata/quota via RetrieveUserQuotaSummary; never sends model prompts or tokens.
struct AntigravityQuotaService {
    enum ServiceError: LocalizedError {
        case processNotFound
        case csrfTokenMissing
        case connectionFailed(String)
        case invalidResponse
        case serverError(Int, String)

        var errorDescription: String? {
            switch self {
            case .processNotFound:
                return "未检测到 Antigravity 运行中；请启动 Antigravity 后重试"
            case .csrfTokenMissing:
                return "未获取到 Antigravity 本地 CSRF 凭据"
            case .connectionFailed(let msg):
                return "连接 Antigravity 本地服务失败：\(msg)"
            case .invalidResponse:
                return "Antigravity 返回的配额数据格式异常"
            case .serverError(let code, let msg):
                return "Antigravity 服务返回错误 (\(code))：\(msg)"
            }
        }
    }

    struct Response: Decodable {
        struct Group: Decodable {
            let displayName: String?
            let description: String?
            let buckets: [Bucket]?
        }

        struct Bucket: Decodable {
            let bucketId: String?
            let displayName: String?
            let description: String?
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?

            var remainingPercent: Double? {
                guard let remainingFraction, remainingFraction.isFinite else { return nil }
                let percent = remainingFraction * 100.0
                return min(100.0, max(0.0, (percent * 10.0).rounded() / 10.0))
            }

            var resetDate: Date? {
                guard let resetTime else { return nil }
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: resetTime) {
                    return date
                }
                return ISO8601DateFormatter().date(from: resetTime)
            }

            func resetCountdown(now: Date = Date()) -> String? {
                guard let date = resetDate else { return nil }
                let interval = date.timeIntervalSince(now)
                if interval <= 0 { return "即将重置" }
                let totalMinutes = max(1, Int(ceil(interval / 60.0)))
                let days = totalMinutes / 1440
                let hours = (totalMinutes % 1440) / 60
                let minutes = totalMinutes % 60
                if days > 0 {
                    return "\(days)d \(hours)h"
                } else if hours > 0 {
                    return "\(hours)h \(minutes)m"
                } else {
                    return "\(minutes)m"
                }
            }
        }

        struct Body: Decodable {
            let groups: [Group]?
            let description: String?
        }

        let response: Body?

        func snapshot(now: Date = Date()) -> AntigravityQuotaSnapshot {
            var snap = AntigravityQuotaSnapshot.placeholder
            guard let groups = response?.groups, !groups.isEmpty else {
                snap.status = .unavailable
                snap.note = "接口未返回配额分组"
                return snap
            }
            for group in groups {
                let name = (group.displayName ?? "").lowercased()
                let buckets = group.buckets ?? []
                if name.contains("gemini models") || (name.contains("gemini") && !name.contains("argon")) {
                    for b in buckets {
                        if b.window == "5h" || (b.displayName ?? "").lowercased().contains("five hour") {
                            snap.fiveHourRemainingPercent = b.remainingPercent
                            snap.fiveHourResetsAt = b.resetDate
                            snap.fiveHourResetText = b.resetCountdown(now: now).map { "重置剩余 \($0)" }
                        } else if b.window == "weekly" || (b.displayName ?? "").lowercased().contains("weekly") {
                            snap.weeklyRemainingPercent = b.remainingPercent
                            snap.weeklyResetsAt = b.resetDate
                            snap.weeklyResetText = b.resetCountdown(now: now).map { "重置剩余 \($0)" }
                        }
                    }
                } else if name.contains("argon") {
                    for b in buckets {
                        if b.window == "weekly" || (b.displayName ?? "").lowercased().contains("weekly") {
                            snap.argonWeeklyRemainingPercent = b.remainingPercent
                            snap.argonWeeklyResetsAt = b.resetDate
                            snap.argonWeeklyResetText = b.resetCountdown(now: now).map { "重置剩余 \($0)" }
                        }
                    }
                } else if name.contains("claude") || name.contains("gpt") || name.contains("3p") {
                    for b in buckets {
                        if b.window == "weekly" || (b.displayName ?? "").lowercased().contains("weekly") {
                            snap.thirdPartyWeeklyRemainingPercent = b.remainingPercent
                            snap.thirdPartyWeeklyResetText = b.resetCountdown(now: now).map { "重置剩余 \($0)" }
                        }
                    }
                }
            }
            snap.updatedAt = now
            snap.source = .officialAPI
            let hasAny = snap.fiveHourRemainingPercent != nil || snap.weeklyRemainingPercent != nil || snap.argonWeeklyRemainingPercent != nil
            snap.status = hasAny ? .ready : .unavailable
            snap.note = snap.status == .ready
                ? "官方接口 · 本机 Language Server · \(Self.timeString(now)) 同步"
                : "已连接本地服务，但未返回有效配额"
            return snap
        }

        private static func timeString(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }

    struct ConnectionInfo {
        let hubPort: Int?
        let httpsPort: Int
        let csrfToken: String

        init(hubPort: Int? = nil, httpsPort: Int, csrfToken: String) {
            self.hubPort = hubPort
            self.httpsPort = httpsPort
            self.csrfToken = csrfToken
        }
    }

    static func currentHubURL() -> URL {
        if let port = findAgyHubPort(), let url = URL(string: "http://127.0.0.1:\(port)") {
            return url
        }
        return ProviderID.antigravity.consoleURL
    }

    final class LocalTLSTrustDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let host = challenge.protectionSpace.host as String?,
               (host == "127.0.0.1" || host == "localhost"),
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    static func discoverConnection(env: [String: String] = ProcessInfo.processInfo.environment) async throws -> ConnectionInfo {
        // 1. Discover Hub port via running `agy` process (`--hub-port=(\d+)`) or environment variable
        let envPort: Int? = {
            if let addr = env["ANTIGRAVITY_LS_ADDRESS"], let p = Int(addr.split(separator: ":").last ?? "") {
                return p
            }
            if let portStr = env["ANTIGRAVITY_PORT"], let p = Int(portStr) {
                return p
            }
            return nil
        }()

        guard let hubPort = findAgyHubPort() ?? envPort else {
            throw ServiceError.processNotFound
        }

        // 2. Extract live CSRF token from Hub web page (fallback to env token if available)
        let csrfToken: String
        if let liveToken = try? await fetchCsrfToken(hubPort: hubPort) {
            csrfToken = liveToken
        } else if let envToken = env["ANTIGRAVITY_CSRF_TOKEN"], !envToken.isEmpty {
            csrfToken = envToken
        } else {
            csrfToken = try await fetchCsrfToken(hubPort: hubPort)
        }

        let lspPort = hubPort + 5
        return ConnectionInfo(hubPort: hubPort, httpsPort: lspPort, csrfToken: csrfToken)
    }

    static func findAgyHubPort() -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-ax", "-o", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            // Read pipe data BEFORE waitUntilExit() to avoid 64KB kernel pipe buffer deadlock!
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            for line in output.components(separatedBy: .newlines) {
                if line.contains("agy") && line.contains("--hub-port=") {
                    let pattern = #"--hub-port=(\d+)"#
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
                       let range = Range(match.range(at: 1), in: line),
                       let port = Int(line[range]) {
                        return port
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func fetchCsrfToken(hubPort: Int) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(hubPort)/") else {
            throw ServiceError.connectionFailed("无效的 Hub 地址")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5.0
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw ServiceError.connectionFailed("Hub 响应异常")
            }
            let text = String(decoding: data, as: UTF8.self)
            guard let range = text.range(of: "\"csrfToken\":\"") else {
                throw ServiceError.csrfTokenMissing
            }
            let rest = text[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else {
                throw ServiceError.csrfTokenMissing
            }
            let token = String(rest[..<end])
            guard !token.isEmpty else { throw ServiceError.csrfTokenMissing }
            return token
        } catch let err as ServiceError {
            throw err
        } catch {
            throw ServiceError.connectionFailed(error.localizedDescription)
        }
    }

    static func fetch(
        connection: ConnectionInfo? = nil,
        customSession: URLSession? = nil,
        now: Date = Date()
    ) async throws -> AntigravityQuotaSnapshot {
        let conn: ConnectionInfo
        if let connection {
            conn = connection
        } else {
            conn = try await discoverConnection()
        }

        let session: URLSession
        if let customSession {
            session = customSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            session = URLSession(configuration: config, delegate: LocalTLSTrustDelegate(), delegateQueue: nil)
        }

        var candidateURLs: [URL] = []
        if let hubPort = conn.hubPort,
           let hubURL = URL(string: "http://127.0.0.1:\(hubPort)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") {
            candidateURLs.append(hubURL)
        }
        if let httpsURL = URL(string: "https://127.0.0.1:\(conn.httpsPort)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") {
            candidateURLs.append(httpsURL)
        }
        guard !candidateURLs.isEmpty else {
            throw ServiceError.connectionFailed("无效的 RPC 端点")
        }

        var lastError: Error = ServiceError.invalidResponse
        for endpoint in candidateURLs {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            req.setValue(conn.csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
            req.httpBody = Data("{}".utf8)
            req.timeoutInterval = 15.0

            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    lastError = ServiceError.invalidResponse
                    continue
                }
                guard (200...299).contains(http.statusCode) else {
                    let body = String(decoding: data, as: UTF8.self)
                    lastError = ServiceError.serverError(http.statusCode, body)
                    continue
                }
                let parsed = try JSONDecoder().decode(Response.self, from: data)
                return parsed.snapshot(now: now)
            } catch let err as ServiceError {
                lastError = err
            } catch is DecodingError {
                lastError = ServiceError.invalidResponse
            } catch {
                lastError = ServiceError.connectionFailed(error.localizedDescription)
            }
        }
        throw lastError
    }
}
