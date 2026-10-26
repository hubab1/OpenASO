import Foundation

/// Transient startup status; never persisted and never starts maintenance work.
enum StoragePreparationProgress: Equatable, Sendable {
    case opening
    case waitingForClients
    case archiving(completed: Int, total: Int)
    case compacting
    case ready
}
