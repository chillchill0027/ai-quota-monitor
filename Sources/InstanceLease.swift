import Foundation
import Darwin

/// A process-lifetime OS lock, shared by both packaged entry points. No stale PID files.
final class InstanceLease {
    enum LeaseError: Error { case occupied, unavailable }
    private let descriptor: Int32
    init(url: URL) throws {
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LeaseError.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let occupied = errno == EWOULDBLOCK
            Darwin.close(fd)
            throw occupied ? LeaseError.occupied : LeaseError.unavailable
        }
        descriptor = fd
    }
    deinit { Darwin.close(descriptor) }
    static func applicationLease() throws -> InstanceLease {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIQuotaMonitor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        return try InstanceLease(url: directory.appendingPathComponent("instance.lock"))
    }
}
