import Darwin
import Foundation

/// A process-scoped guard that is released automatically by the kernel on
/// crash or exit. A compatibility LaunchAgent waits so it can take over if a
/// stale Service Management copy exits; ordinary duplicate launches return.
final class ProcessSingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(waitForAvailability: Bool) -> ProcessSingleInstanceLock? {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("io.github.ruodou233.MacWiFiPicker.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }

        let operation = LOCK_EX | (waitForAvailability ? 0 : LOCK_NB)
        guard flock(descriptor, operation) == 0 else {
            _ = close(descriptor)
            return nil
        }
        return ProcessSingleInstanceLock(descriptor: descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}
