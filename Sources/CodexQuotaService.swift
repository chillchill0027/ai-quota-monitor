import Foundation
import Darwin

/// Only the documented app-server metadata API is used. Never starts threads or model turns.
struct CodexQuotaService {
    struct Window: Decodable {
        let usedPercent: Double?
        let windowDurationMins: Int?
        let resetsAt: Double?

        var remaining: Double? {
            guard let usedPercent, usedPercent.isFinite else { return nil }
            return min(100, max(0, 100 - usedPercent))
        }
        var resetDate: Date? {
            guard let resetsAt, resetsAt.isFinite, resetsAt > 0 else { return nil }
            return Date(timeIntervalSince1970: resetsAt)
        }
    }

    struct Bucket: Decodable {
        let limitId: String?
        let primary: Window?
        let secondary: Window?
    }

    struct Response: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?

        // Never silently substitute a model-specific bucket for the general Codex allowance.
        var codexBucket: Bucket? {
            if let buckets = rateLimitsByLimitId { return buckets["codex"] }
            guard rateLimits?.limitId == nil || rateLimits?.limitId == "codex" else { return nil }
            return rateLimits
        }

        func snapshot(now: Date = Date()) -> QuotaWindowSnapshot {
            var snapshot = QuotaWindowSnapshot.defaultChatGPT()
            let windows = [codexBucket?.primary, codexBucket?.secondary].compactMap { $0 }
            let five = windows.first { $0.windowDurationMins == 300 }
            let week = windows.first { $0.windowDurationMins == 10_080 }
            snapshot.fiveHourRemainingPercent = five?.remaining
            snapshot.weeklyRemainingPercent = week?.remaining
            snapshot.fiveHourResetsAt = five?.resetDate
            snapshot.weeklyResetsAt = week?.resetDate
            snapshot.updatedAt = now
            snapshot.source = .officialAPI
            snapshot.status = (five?.remaining != nil || week?.remaining != nil) ? .ready : .unavailable
            snapshot.note = snapshot.status == .ready
                ? "Codex 订阅额度 · 官方接口 · \(Self.timeString(now)) 更新"
                : "接口未提供 5 小时 / 7 天窗口；请以官方用量页为准"
            return snapshot
        }

        private static func timeString(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }

    enum QueryError: LocalizedError, Equatable {
        case cliMissing, launchFailed, queryFailed, timedOut, serverRejected
        var requiresUserAction: Bool { self == .serverRejected }
        var errorDescription: String? {
            switch self {
            case .cliMissing: return "未找到 Codex CLI；请安装并运行 codex login 登录 ChatGPT"
            case .launchFailed: return "无法启动 Codex CLI；请检查安装或打开官方用量页"
            case .queryFailed: return "额度查询失败；请检查网络及 codex login 登录状态"
            case .timedOut: return "额度查询超时；查询进程已结束，可稍后手动重试"
            case .serverRejected: return "官方额度接口拒绝查询；请在官方客户端检查登录状态或更新 CLI"
            }
        }
    }

    static func executableURL() -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { String($0) + "/codex" }
        let candidates = paths + [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Injection is used only by offline process tests; ordinary callers use the installed CLI.
    static func fetch(executable: URL? = nil, timeoutSeconds: TimeInterval = 20) async throws -> QuotaWindowSnapshot {
        let cancellation = CancellationState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let snapshot = try await Task.detached(priority: .utility) {
                try query(executable: executable, timeoutSeconds: timeoutSeconds, cancellation: cancellation).snapshot()
            }.value
            try Task.checkCancellation()
            return snapshot
        } onCancel: {
            cancellation.cancel()
        }
    }

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private static func query(executable: URL?, timeoutSeconds: TimeInterval, cancellation: CancellationState) throws -> Response {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 600 else { throw QueryError.queryFailed }
        guard let executable = executable ?? executableURL() else { throw QueryError.cliMissing }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1_000_000_000)
        if cancellation.isCancelled { throw CancellationError() }
        let channel = try ChildChannel.start(executable: executable)
        defer { channel.finish() }

        var outgoing = Data()
        func enqueue(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            outgoing.append(data)
        }
        try enqueue(["id": 1, "method": "initialize", "params": ["clientInfo": [
            "name": "ai_quota_monitor", "title": "AI额度看板", "version": "1.4.4"
        ]]])
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        var expectedID = 1
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw QueryError.timedOut }

            // Both pipe ends are nonblocking. Even a dead child with a descendant holding
            // stdout open cannot trap this worker inside FileHandle.availableData.
            if !outgoing.isEmpty {
                let written = outgoing.withUnsafeBytes { Darwin.write(channel.input, $0.baseAddress, $0.count) }
                if written > 0 { outgoing.removeFirst(written) }
                else if written < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    throw QueryError.queryFailed
                }
            }
            var sawEOF = false
            while true {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(channel.output, $0.baseAddress, $0.count) }
                if count > 0 {
                    buffer.append(contentsOf: bytes.prefix(count))
                    guard buffer.count < 2_000_000 else { throw QueryError.queryFailed }
                    // A noisy CLI still observes the deadline/cancellation check each chunk.
                    if cancellation.isCancelled { throw CancellationError() }
                    guard DispatchTime.now().uptimeNanoseconds < deadline else { throw QueryError.timedOut }
                } else if count == 0 {
                    sawEOF = true
                } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    throw QueryError.queryFailed
                }
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let id = message["id"] as? Int, id == expectedID else { continue }
                    guard message["error"] == nil else { throw QueryError.serverRejected }
                    if id == 1 {
                        guard message["result"] != nil else { throw QueryError.queryFailed }
                        expectedID = 2
                        try enqueue(["method": "initialized", "params": [:]])
                        try enqueue(["id": 2, "method": "account/rateLimits/read"])
                    } else if let result = message["result"] as? [String: Any] {
                        let data = try JSONSerialization.data(withJSONObject: result)
                        return try JSONDecoder().decode(Response.self, from: data)
                    }
                }
                if count <= 0 { break }
            }
            if sawEOF || channel.hasExited() { throw QueryError.queryFailed }
            // poll is bounded by a monotonic deadline, and at most 50 ms to notice cancellation.
            let remainingMillis = max(1, min(50, Int((deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)) / 1_000_000)))
            var descriptors = [
                pollfd(fd: channel.output, events: Int16(POLLIN), revents: 0),
                pollfd(fd: channel.input, events: outgoing.isEmpty ? 0 : Int16(POLLOUT), revents: 0)
            ]
            if Darwin.poll(&descriptors, nfds_t(descriptors.count), Int32(remainingMillis)) < 0 && errno != EINTR {
                throw QueryError.queryFailed
            }
        }
    }

    /// The CLI owns a private process group so cleanup also stops inherited-stdout helpers.
    private final class ChildChannel {
        let input: Int32
        let output: Int32
        private let pid: pid_t
        private var reaped = false
        private var closed = false

        private init(pid: pid_t, input: Int32, output: Int32) {
            self.pid = pid; self.input = input; self.output = output
        }

        static func start(executable: URL) throws -> ChildChannel {
            var stdinPipe: [Int32] = [-1, -1]
            var stdoutPipe: [Int32] = [-1, -1]
            guard Darwin.pipe(&stdinPipe) == 0 else { throw QueryError.launchFailed }
            guard Darwin.pipe(&stdoutPipe) == 0 else {
                Darwin.close(stdinPipe[0]); Darwin.close(stdinPipe[1])
                throw QueryError.launchFailed
            }
            var transferred = false
            let null = Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
            defer {
                Darwin.close(stdinPipe[0]); Darwin.close(stdoutPipe[1])
                if null >= 0 { Darwin.close(null) }
                if !transferred { Darwin.close(stdinPipe[1]); Darwin.close(stdoutPipe[0]) }
            }
            for descriptor in stdinPipe + stdoutPipe {
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw QueryError.launchFailed }
            }
            guard null >= 0,
                  fcntl(stdinPipe[1], F_SETFL, fcntl(stdinPipe[1], F_GETFL) | O_NONBLOCK) == 0,
                  fcntl(stdoutPipe[0], F_SETFL, fcntl(stdoutPipe[0], F_GETFL) | O_NONBLOCK) == 0,
                  fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1) == 0 else { throw QueryError.launchFailed }

            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else { throw QueryError.launchFailed }
            defer { posix_spawn_file_actions_destroy(&actions) }
            guard posix_spawnattr_init(&attributes) == 0 else { throw QueryError.launchFailed }
            defer { posix_spawnattr_destroy(&attributes) }
            guard posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) == 0,
                  posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
                  posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw QueryError.launchFailed }
            // Keep the same neutral cwd as before; project files are never supplied to the CLI.
            let chdirStatus: Int32
            if #available(macOS 26.0, *) {
                chdirStatus = posix_spawn_file_actions_addchdir(&actions, NSHomeDirectory())
            } else {
                chdirStatus = posix_spawn_file_actions_addchdir_np(&actions, NSHomeDirectory())
            }
            guard chdirStatus == 0 else { throw QueryError.launchFailed }
            var arguments = [executable.path, "app-server"].map { strdup($0) }
            arguments.append(nil)
            var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
            environment.append(nil)
            defer {
                arguments.forEach { free($0) }
                environment.forEach { free($0) }
            }
            var pid: pid_t = 0
            let status = arguments.withUnsafeMutableBufferPointer { argv in
                environment.withUnsafeMutableBufferPointer { env in
                    posix_spawn(&pid, executable.path, &actions, &attributes, argv.baseAddress!, env.baseAddress!)
                }
            }
            guard status == 0 else { throw QueryError.launchFailed }
            transferred = true
            return ChildChannel(pid: pid, input: stdinPipe[1], output: stdoutPipe[0])
        }

        func hasExited() -> Bool {
            if reaped { return true }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) { reaped = true }
            return reaped
        }

        func finish() {
            guard !closed else { return }
            closed = true
            Darwin.close(input)
            Darwin.close(output)
            // Closing stdin lets a normal CLI exit cleanly. A short, bounded grace period
            // is followed by SIGKILL, including descendants which inherited stdout.
            Darwin.kill(-pid, SIGTERM)
            let gracefulDeadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
            while DispatchTime.now().uptimeNanoseconds < gracefulDeadline {
                if hasExited() { break }
                usleep(5_000)
            }
            Darwin.kill(-pid, SIGKILL)
            let reapDeadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
            while !hasExited() && DispatchTime.now().uptimeNanoseconds < reapDeadline { usleep(5_000) }
            if !reaped {
                // A pathological uninterruptible kernel wait must not hold the UI query open.
                let childPID = pid
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    while waitpid(childPID, &status, 0) == -1 && errno == EINTR { }
                }
            }
        }
        deinit { finish() }
    }
}
