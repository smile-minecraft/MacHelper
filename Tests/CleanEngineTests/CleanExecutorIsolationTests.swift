import Foundation
import Testing
@testable import CleanEngine

/// A removal backend for tests: trashed items move into a directory inside the test's temporary
/// tree, and every call is recorded. A test using this backend cannot reach the user's Trash.
final class TestTrashBackend: @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        case trash

        var errorDescription: String? {
            switch self {
            case .trash: return "test trash failed"
            }
        }
    }

    let trashDirectory: URL
    private let lock = NSLock()
    private var trashCalls: [String] = []
    private var deleteCalls: [String] = []
    private var trashFailure: Error?

    init(trashDirectory: URL) {
        self.trashDirectory = trashDirectory
    }

    /// The backend to hand to `CleanExecutor`. It is always `.custom`, never `.system`.
    var backend: RemovalBackend {
        .custom(
            trash: { try self.moveToTestTrash($0) },
            delete: { try self.removePermanently($0) }
        )
    }

    func failTrash(_ error: Error = Failure.trash) {
        locked { trashFailure = error }
    }

    var trashedPaths: [String] { locked { trashCalls } }
    var deletedPaths: [String] { locked { deleteCalls } }

    func trashContents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: trashDirectory.path)) ?? []).sorted()
    }

    private func moveToTestTrash(_ url: URL) throws {
        locked { trashCalls.append(url.path) }
        if let error = locked({ trashFailure }) { throw error }
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: uniqueDestination(for: url.lastPathComponent))
    }

    private func removePermanently(_ url: URL) throws {
        locked { deleteCalls.append(url.path) }
        try FileManager.default.removeItem(at: url)
    }

    private func uniqueDestination(for name: String) -> URL {
        let preferred = trashDirectory.appending(path: name)
        guard FileManager.default.fileExists(atPath: preferred.path) else { return preferred }
        return trashDirectory.appending(path: "\(UUID().uuidString)-\(name)")
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private extension RemovalBackend {
    var isSystem: Bool {
        if case .system = self { return true }
        return false
    }
}

@Suite struct CleanExecutorIsolationTests {
    private func safety(for t: TempDir, minimumDepth: Int = 2, protected: [String] = []) -> PathSafety {
        PathSafety(protectedPaths: protected, whitelist: [], allowedRoots: [t.path], minimumDepth: minimumDepth)
    }

    private func executor(_ t: TempDir, _ backend: TestTrashBackend, log: OperationLog? = nil,
                          permanent: Bool = false, alwaysTrash: Bool = false) -> CleanExecutor {
        CleanExecutor.injected(safety: safety(for: t),
                               log: log ?? OperationLog(url: t.url.appending(path: "operations.jsonl")),
                               removal: backend.backend,
                               permanent: permanent, alwaysTrash: alwaysTrash)
    }

    @Test func testInitializerRequiresAnExplicitBackend() {
        // Constructing the executor does not remove anything; this only checks which backend the
        // public initializer selects. An explicit empty whitelist keeps this from reading the
        // user's clean-whitelist.txt.
        let publicExecutor = CleanExecutor(safety: .forCleaning(whitelist: []))
        #expect(publicExecutor.removal.isSystem, "the public initializer keeps the system Trash")

        let injected = CleanExecutor.injected(
            safety: .forCleaning(whitelist: []),
            log: OperationLog(url: URL(fileURLWithPath: "/nonexistent-test-log")),
            removal: TestTrashBackend(trashDirectory: URL(fileURLWithPath: "/nonexistent-test-trash")).backend
        )
        #expect(!injected.removal.isSystem, "the test initializer requires a backend and does not fall back")
    }

    @Test func dryRunCallsNoRemovalOperation() throws {
        let t = try TempDir()
        let file = try t.file("a/b/file.bin", bytes: 123)
        let backend = TestTrashBackend(trashDirectory: t.url.appending(path: "test-trash"))
        let log = OperationLog(url: t.url.appending(path: "operations.jsonl"))
        let report = executor(t, backend, log: log)
            .execute([RemovalItem(path: file, source: "r", bytes: 123, action: .trash)], dryRun: true, command: "test")

        #expect(report.items.map(\.result) == [.wouldTrash])
        #expect(t.exists("a/b/file.bin"))
        #expect(backend.trashedPaths.isEmpty)
        #expect(backend.deletedPaths.isEmpty)
        #expect(log.read().isEmpty, "dry runs are not logged")
    }

    @Test func deleteActionCallsOnlyTheDeleteOperation() throws {
        let t = try TempDir()
        let file = try t.file("a/b/file.bin", bytes: 123)
        let backend = TestTrashBackend(trashDirectory: t.url.appending(path: "test-trash"))
        let log = OperationLog(url: t.url.appending(path: "operations.jsonl"))
        let report = executor(t, backend, log: log)
            .execute([RemovalItem(path: file, source: "r", bytes: 123, action: .delete)], dryRun: false, command: "test")

        #expect(report.items.map(\.result) == [.deleted])
        #expect(report.freedBytes == 123)
        #expect(!t.exists("a/b/file.bin"))
        #expect(backend.deletedPaths == [file])
        #expect(backend.trashedPaths.isEmpty)
        #expect(log.read().map(\.result) == ["deleted"])
    }

    @Test func permanentDeleteCallsOnlyTheDeleteOperation() throws {
        let t = try TempDir()
        let file = try t.file("a/b/file.bin", bytes: 123)
        let backend = TestTrashBackend(trashDirectory: t.url.appending(path: "test-trash"))
        let log = OperationLog(url: t.url.appending(path: "operations.jsonl"))
        let report = executor(t, backend, log: log, permanent: true)
            .execute([RemovalItem(path: file, source: "r", bytes: 123, action: .trash)], dryRun: false, command: "test")

        #expect(report.items.map(\.result) == [.deleted])
        #expect(!t.exists("a/b/file.bin"))
        #expect(backend.deletedPaths == [file])
        #expect(backend.trashedPaths.isEmpty, "permanent deletion never uses the Trash")
        #expect(log.read().map(\.result) == ["deleted"])
    }

    @Test func trashFailureIsReportedWithoutDeletingTheItem() throws {
        let t = try TempDir()
        let file = try t.file("a/b/file.bin", bytes: 123)
        let backend = TestTrashBackend(trashDirectory: t.url.appending(path: "test-trash"))
        backend.failTrash()
        let log = OperationLog(url: t.url.appending(path: "operations.jsonl"))
        let report = executor(t, backend, log: log)
            .execute([RemovalItem(path: file, source: "r", bytes: 123, action: .trash)], dryRun: false, command: "test")

        try #require(report.items.count == 1)
        #expect(report.items[0].result == .failed)
        #expect(report.items[0].bytes == 0)
        #expect(report.items[0].message == "test trash failed")
        #expect(report.failures.count == 1)
        #expect(t.exists("a/b/file.bin"), "a failed trash leaves the item in place")
        #expect(backend.trashedPaths == [file], "the trash operation was attempted")
        #expect(backend.deletedPaths.isEmpty, "a failed trash never falls back to deletion")
        #expect(log.read().map(\.result) == ["failed"])
    }

    @Test func safetyRefusalCallsNoRemovalOperation() throws {
        let t = try TempDir()
        let file = try t.file("top.bin")
        let backend = TestTrashBackend(trashDirectory: t.url.appending(path: "test-trash"))
        let log = OperationLog(url: t.url.appending(path: "operations.jsonl"))
        let report = CleanExecutor.injected(safety: safety(for: t, minimumDepth: 2), log: log, removal: backend.backend)
            .execute([RemovalItem(path: file, source: "r", bytes: 1, action: .trash)], dryRun: false, command: "test")

        #expect(report.items.map(\.result) == [.skipped])
        #expect(report.items[0].message?.hasPrefix("safety:") == true)
        #expect(t.exists("top.bin"))
        #expect(backend.trashedPaths.isEmpty)
        #expect(backend.deletedPaths.isEmpty)
        #expect(log.read().map(\.result) == ["skipped"])
    }
}
