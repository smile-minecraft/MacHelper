import Foundation

@testable import CleanEngine

/// Nothing is running: no guard may pause a rule or an item because of this table.
let nothingRunning = RunningApplications(bundleIDs: { [] }, processNames: { [] })

/// A process table a test owns: an app or an executable can start and stop while a scan or a clean
/// batch is already running. Replaces starting a real process and polling the process list, which
/// made the guard tests depend on this machine's scheduler.
final class FakeRunningApplications: @unchecked Sendable {
    private let lock = NSLock()
    private var bundleIDs: Set<String>
    private var processNames: Set<String>

    init(processNames: Set<String> = [], bundleIDs: Set<String> = []) {
        self.processNames = processNames
        self.bundleIDs = bundleIDs
    }

    /// The source to hand to a scanner or an executor. It reads the current sets on every call.
    var source: RunningApplications {
        RunningApplications(bundleIDs: { self.locked { self.bundleIDs } },
                            processNames: { self.locked { self.processNames } })
    }

    func start(process name: String) {
        locked { self.processNames.insert(name) }
    }

    func stop(process name: String) {
        locked { self.processNames.remove(name) }
    }

    func start(bundleID id: String) {
        locked { self.bundleIDs.insert(id) }
    }

    func stopAll() {
        locked {
            self.processNames.removeAll()
            self.bundleIDs.removeAll()
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
