import Darwin
import Foundation

enum CrossProcessLockAttempt<Value: Sendable>: Sendable {
    case acquired(Value)
    case unavailable
}

enum CrossProcessFileLockError: LocalizedError, Sendable {
    case couldNotOpen(path: String, code: Int32)
    case couldNotLock(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .couldNotOpen(let path, let code):
            "Could not open the background refresh lock at \(path) (errno \(code))."
        case .couldNotLock(let path, let code):
            "Could not acquire the background refresh lock at \(path) (errno \(code))."
        }
    }
}

struct CrossProcessFileLock: Sendable {
    let namespace: AppNamespace
    let fileName: String

    nonisolated(nonsending) func attempt<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> CrossProcessLockAttempt<Value> {
        let lockURL = try namespace.applicationSupportDirectoryURL()
            .appendingPathComponent("Locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: true
        )
        let fileURL = lockURL.appendingPathComponent(fileName, isDirectory: false)
        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw CrossProcessFileLockError.couldNotOpen(
                path: fileURL.path,
                code: errno
            )
        }
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let errorCode = errno
            if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                return .unavailable
            }
            throw CrossProcessFileLockError.couldNotLock(
                path: fileURL.path,
                code: errorCode
            )
        }
        defer { flock(descriptor, LOCK_UN) }

        return .acquired(try await operation())
    }
}
