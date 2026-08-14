import Foundation
import SwiftData

extension OpenASOSchemaV6 {
@Model
final class RankingMigrationState {
    static let singletonKey = "normalized-ranking-v6"

    @Attribute(.unique) var migrationKey: String
    var phaseRaw: String
    var lastObservationKey: String?
    var lastSnapshotKey: String?
    var legacyCrawlCount: Int
    var legacyFactCount: Int
    var legacyTrackedFactCount: Int
    var migratedCrawlCount: Int
    var migratedFactCount: Int
    var processedSnapshotCount: Int
    var migratedTrackedLinkCount: Int
    var recoveredCrawlCount: Int
    var startedAt: Date
    var completedAt: Date?

    init(startedAt: Date = .now) {
        self.migrationKey = Self.singletonKey
        self.phaseRaw = RankingMigrationPhase.copyingCrawls.rawValue
        self.lastObservationKey = nil
        self.lastSnapshotKey = nil
        self.legacyCrawlCount = 0
        self.legacyFactCount = 0
        self.legacyTrackedFactCount = 0
        self.migratedCrawlCount = 0
        self.migratedFactCount = 0
        self.processedSnapshotCount = 0
        self.migratedTrackedLinkCount = 0
        self.recoveredCrawlCount = 0
        self.startedAt = startedAt
        self.completedAt = nil
    }

    var phase: RankingMigrationPhase {
        get { RankingMigrationPhase(rawValue: phaseRaw) ?? .copyingCrawls }
        set { phaseRaw = newValue.rawValue }
    }
}
}

enum RankingMigrationPhase: String, Sendable {
    case copyingCrawls
    case linkingSnapshots
    case validating
    case cleaningLegacyRows
    case completed
}

typealias RankingMigrationState = OpenASOSchemaV6.RankingMigrationState
