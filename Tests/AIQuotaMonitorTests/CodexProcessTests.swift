import Foundation
import Darwin

/// Real local pipes/processes, synthetic RPC only. Never discovers the user's CLI or reads credentials.
enum CodexProcessTests {
    static func run() async throws {
        try await testSuccessfulHandshakeAndCleanup()
        try await testDeadlineKillsTermIgnoringCLI()
        try await testInheritedStdoutCannotHoldQueryOpen()
        try await testCancellationStopsWorker()
        try await testImmediateExitAndServerRejection()
        print("PASS: 5 offline Codex process/deadline/cancellation tests")
    }

    private struct Fixture {
        let directory: URL
        var executable: URL { directory.appendingPathComponent("mock-codex") }
        var pidFile: URL { directory.appendingPathComponent("pid") }
        var logFile: URL { directory.appendingPathComponent("requests.jsonl") }
        var childPIDFile: URL { directory.appendingPathComponent("child-pid") }
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-process-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func install(_ body: String) throws {
            let script = "#!/bin/sh\necho $$ > \(quote(pidFile.path))\n" + body + "\n"
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        func cleanup() {
            // Test-only guard, also protects against a failed assertion in future test edits.
            if let pid = try? readPID(pidFile) { _ = Darwin.kill(-pid, SIGKILL) }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func readPID(_ file: URL) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(text), pid > 1 else { throw TestError.invalidPID }
        return pid
    }
    private enum TestError: Error { case invalidPID, unexpectedSuccess, fixtureNotStarted, processStillAlive }

    private static func assertReaped(_ pid: pid_t) {
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private static func testSuccessfulHandshakeAndCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.install("""
        IFS= read -r first
        printf '%s\\n' "$first" > \(quote(fixture.logFile.path))
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r second
        IFS= read -r third
        printf '%s\\n' "$second" "$third" >> \(quote(fixture.logFile.path))
        printf '%s\\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300},"secondary":{"usedPercent":40,"windowDurationMins":10080}}}}'
        # Keep a process alive after responding to prove normal success also cleans it up.
        trap '' TERM
        /bin/sleep 3
        """)
        let snapshot = try await CodexQuotaService.fetch(executable: fixture.executable, timeoutSeconds: 1.5)
        XCTAssertEqual(snapshot.fiveHourRemainingPercent, 75)
        XCTAssertEqual(snapshot.weeklyRemainingPercent, 60)
        let lines = try String(contentsOf: fixture.logFile, encoding: .utf8).split(separator: "\n")
        let methods = try lines.map { line -> String in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            return object["method"] as! String
        }
        XCTAssertEqual(methods, ["initialize", "initialized", "account/rateLimits/read"])
        assertReaped(try readPID(fixture.pidFile))
    }

    private static func testDeadlineKillsTermIgnoringCLI() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.install("""
        trap '' TERM
        IFS= read -r first
        printf '%s\\n' '{"id":1,"result":{}}'
        # Deliberately never returns rateLimits and ignores TERM. Self-exits eventually as a test guard.
        /bin/sleep 3
        """)
        let start = Date()
        do {
            _ = try await CodexQuotaService.fetch(executable: fixture.executable, timeoutSeconds: 0.8)
            throw TestError.unexpectedSuccess
        } catch let error as CodexQuotaService.QueryError {
            XCTAssertEqual(error, .timedOut)
            XCTAssertEqual(error.requiresUserAction, false)
        }
        XCTAssertEqual(Date().timeIntervalSince(start) < 1.8, true)
        assertReaped(try readPID(fixture.pidFile))
    }

    private static func testInheritedStdoutCannotHoldQueryOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let helper = "trap '' TERM; echo $$ > \(quote(fixture.childPIDFile.path)); /bin/sleep 3"
        try fixture.install("""
        /bin/sh -c \(quote(helper)) &
        while [ ! -f \(quote(fixture.childPIDFile.path)) ]; do /bin/sleep 0.01; done
        # Exit while the helper still owns stdout. EOF will not arrive until helper cleanup.
        exit 0
        """)
        let start = Date()
        do {
            _ = try await CodexQuotaService.fetch(executable: fixture.executable, timeoutSeconds: 0.9)
            throw TestError.unexpectedSuccess
        } catch is CodexQuotaService.QueryError { }
        XCTAssertEqual(Date().timeIntervalSince(start) < 1.8, true)
        assertReaped(try readPID(fixture.pidFile))
        // ps treats an adopted zombie as exited, while kill(pid, 0) still succeeds for zombies.
        let helperPID = try readPID(fixture.childPIDFile)
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(helperPID), "-o", "stat="]
        let output = Pipe()
        ps.standardOutput = output
        ps.standardError = FileHandle.nullDevice
        try ps.run()
        ps.waitUntilExit()
        let state = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard state.isEmpty || state.hasPrefix("Z") else { throw TestError.processStillAlive }
    }

    private static func testCancellationStopsWorker() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.install("trap '' TERM\n/bin/sleep 3")
        let task = Task { try await CodexQuotaService.fetch(executable: fixture.executable, timeoutSeconds: 1.8) }
        let startDeadline = Date().addingTimeInterval(1.5)
        while !FileManager.default.fileExists(atPath: fixture.pidFile.path), Date() < startDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard FileManager.default.fileExists(atPath: fixture.pidFile.path) else {
            task.cancel()
            _ = try? await task.value
            throw TestError.fixtureNotStarted
        }
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            throw TestError.unexpectedSuccess
        } catch is CancellationError { }
        XCTAssertEqual(Date().timeIntervalSince(cancelledAt) < 1, true)
        assertReaped(try readPID(fixture.pidFile))
    }

    private static func testImmediateExitAndServerRejection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.install("exit 0")
        do {
            _ = try await CodexQuotaService.fetch(executable: fixture.executable, timeoutSeconds: 1.2)
            throw TestError.unexpectedSuccess
        } catch let error as CodexQuotaService.QueryError {
            XCTAssertEqual(error.requiresUserAction, false)
        }
        try fixture.install("""
        IFS= read -r first
        printf '%s\\n' '{"id":1,"error":{"code":-32000,"message":"synthetic refusal"}}'
        /bin/sleep 3
        """)
        do {
            _ = try await CodexQuotaService.fetch(executable: fixture.executable, timeoutSeconds: 1.2)
            throw TestError.unexpectedSuccess
        } catch let error as CodexQuotaService.QueryError {
            XCTAssertEqual(error, .serverRejected)
            XCTAssertEqual(error.requiresUserAction, true)
        }
        assertReaped(try readPID(fixture.pidFile))
    }
}
