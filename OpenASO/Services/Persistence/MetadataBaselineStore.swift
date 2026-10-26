import Foundation

struct MetadataAcquisitionEvidence: Codable, Equatable, Sendable {
    let periodStart: Date
    let periodEnd: Date
    let searchImpressions: Int?
    let searchDownloads: Int?
    let source: String

    func validate() throws {
        guard periodStart < periodEnd,
              searchImpressions.map({ $0 >= 0 }) ?? true,
              searchDownloads.map({ $0 >= 0 }) ?? true,
              searchImpressions != nil || searchDownloads != nil,
              source == "caller_provided" else {
            throw OpenASOError.providerUnavailable("Acquisition evidence needs a valid reporting period and nonnegative counts; its source is caller_provided.")
        }
    }
}

struct MetadataBaseline: Codable, Sendable {
    let id: UUID
    let label: String
    let capturedAt: Date
    let audit: KeywordTargetingAudit
    let acquisition: MetadataAcquisitionEvidence?
}

struct MetadataBaselineSummary: Codable, Sendable {
    let id: UUID
    let appStoreID: Int64
    let locale: String
    let platform: String
    let storefront: String
    let version: String
    let label: String
    let capturedAt: Date
}

/// UUID-named immutable records avoid cross-process read/modify/write races.
/// Records contain private metadata, so both the directory and files are private.
actor MetadataBaselineStore {
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func save(_ baseline: MetadataBaseline) throws {
        try baseline.acquisition?.validate()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent(baseline.id.uuidString + ".json")
        guard !manager.fileExists(atPath: url.path) else {
            throw OpenASOError.providerUnavailable("Metadata baseline already exists; baselines are immutable.")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(baseline).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func load(_ id: UUID) throws -> MetadataBaseline {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        let data = try Data(contentsOf: url)
        guard data.count <= 4_000_000 else {
            throw OpenASOError.providerUnavailable("Metadata baseline exceeds the supported record size.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(MetadataBaseline.self, from: data)
        guard record.id == id, record.audit.metadataHash == record.audit.metadata.contentHash else {
            throw OpenASOError.unexpectedResponse
        }
        return record
    }

    func list(appStoreID: Int64, limit: Int = 20) throws -> [MetadataBaselineSummary] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        guard files.count <= 1_000 else {
            throw OpenASOError.providerUnavailable("Metadata baseline directory exceeds the supported scan size.")
        }
        var records: [MetadataBaseline] = []
        for file in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            let record = try load(id)
            if record.audit.metadata.appStoreID == appStoreID { records.append(record) }
        }
        return records.sorted { $0.capturedAt > $1.capturedAt }.prefix(max(1, min(limit, 50))).map {
            .init(id: $0.id, appStoreID: $0.audit.metadata.appStoreID, locale: $0.audit.metadata.locale,
                  platform: $0.audit.searchPlatform, storefront: $0.audit.storefront,
                  version: $0.audit.metadata.version, label: $0.label, capturedAt: $0.capturedAt)
        }
    }
}

struct MetadataRankChange: Codable, Sendable {
    let keyword: String
    let before: KeywordTargetingRanking?
    let after: KeywordTargetingRanking?
    let nativeRankImprovement: Int?
}

struct MetadataBaselineComparison: Codable, Sendable {
    let baselineID: UUID
    let label: String
    let before: KeywordTargetingAudit
    let after: KeywordTargetingAudit
    /// nil means private metadata visibility is insufficient to establish a change.
    let metadataChanged: Bool?
    let versionChanged: Bool
    let gainedCoverage: [String]
    let lostCoverage: [String]
    let rankChanges: [MetadataRankChange]
    let acquisitionBefore: MetadataAcquisitionEvidence?
    let acquisitionAfter: MetadataAcquisitionEvidence?
    let notes: [String]
}
