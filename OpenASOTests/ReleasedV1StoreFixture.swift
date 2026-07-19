import CryptoKit
import Foundation

enum ReleasedV1FixtureSentinel {
    static let fixtureID = "v0.3.2-v1"
    static let sourceTag = "v0.3.2"
    static let sourceCommit = "7a2c3752fa895ad820663a5b4baeaf926f0b65f9"
    static let schemaVersion = "1.0.0"

    static let fixtureDate = ISO8601DateFormatter().date(from: "2026-05-01T12:34:56Z")!
    static let priorDate = ISO8601DateFormatter().date(from: "2026-04-30T10:20:30Z")!
    static let releaseDate = ISO8601DateFormatter().date(from: "2024-03-02T01:02:03Z")!
    static let refreshAttemptDate = ISO8601DateFormatter().date(from: "2026-05-02T08:09:10Z")!
    static let ratingDate = "2026-05-01"
    static let dailyRatingDate = "2026-04-30"

    static let folderID = UUID(uuidString: "03200000-0000-4000-8000-000000000001")!
    static let folderName = "Released v0.3.2 Fixture"
    static let appStoreID: Int64 = 320_032_001
    static let bundleID = "com.thirdtech.openaso.fixture.v032"
    static let appName = "OpenASO v0.3.2 Migration Fixture"
    static let storefront = "gb"
    static let keyword = "migration fixture keyword"
    static let queryKey = "migration fixture keyword::gb::iphone"
    static let trackIdentityKey = "320032001::migration fixture keyword::gb::iphone"
    static let originalTrackNotes = "released-v0.3.2-sentinel"
    static let reopenWriteNotes = "reopened-and-written-by-current-schema"
    static let metadataDescription = "Persisted by OpenASO release 7a2c375"
    static let screenshotURLString = "https://example.com/openaso-v032-fixture.png"
    static let rank = 7
    static let resultCount = 42

    static let competitorPosition = 3
    static let competitorAppStoreID: Int64 = 320_032_999
    static let competitorName = "Fixture Competitor"
    static let competitorBundleID = "com.example.fixture-competitor"

    static let reviewID = "released-review-032"
    static let reviewKey = "320032001::gb::released-review-032"
    static let crawlObservedHour = 493_836
    static let crawlResultCount = 50
}

enum ExactV4FixtureSentinel {
    static let fixtureID = "77bc4c3-v4"
    static let sourceCommit = "77bc4c39735f8d68376347f671fd4c8ac34d684c"
    static let sourceTree = "f99c6e8349b253e8220b8dae9258059e3c8ab455"
    static let schemaVersion = "4.0.0"

    static let rankingStatusKey =
        "v4-fixture::ranking-status::00000000-0000-4000-8000-000000000001"
    static let popularityStatusKey =
        "v4-fixture::popularity-status::00000000-0000-4000-8000-000000000002"
    static let rankingStatusMessage = "V3 ranking status sentinel"
    static let estimatedCalculationID = UUID(
        uuidString: "77bc4c30-0000-4000-8000-000000000001",
    )!
    static let unavailableCalculationID = UUID(
        uuidString: "77bc4c30-0000-4000-8000-000000000002",
    )!
    static let unavailableKeyword = "v4 unavailable difficulty"
    static let unavailableQueryKey = "v4 unavailable difficulty::gb::iphone"
}

struct StoredMigrationFixtureDescriptor: Sendable {
    let formatVersion: Int
    let fixtureID: String
    let sourceTag: String?
    let sourceCommit: String
    let sourceTree: String?
    let schemaVersion: String
    let generatorCommand: String

    static let releasedV1 = Self(
        formatVersion: 1,
        fixtureID: ReleasedV1FixtureSentinel.fixtureID,
        sourceTag: ReleasedV1FixtureSentinel.sourceTag,
        sourceCommit: ReleasedV1FixtureSentinel.sourceCommit,
        sourceTree: nil,
        schemaVersion: ReleasedV1FixtureSentinel.schemaVersion,
        generatorCommand: "./script/generate_v032_migration_fixture.sh",
    )

    static let exactV4 = Self(
        formatVersion: 2,
        fixtureID: ExactV4FixtureSentinel.fixtureID,
        sourceTag: nil,
        sourceCommit: ExactV4FixtureSentinel.sourceCommit,
        sourceTree: ExactV4FixtureSentinel.sourceTree,
        schemaVersion: ExactV4FixtureSentinel.schemaVersion,
        generatorCommand: "./script/generate_v4_migration_fixture.sh",
    )
}

struct StoredMigrationFixtureManifest: Codable, Equatable {
    struct Artifact: Codable, Hashable {
        let filename: String
        let byteCount: Int
        let sha256: String
    }

    let formatVersion: Int
    let fixtureID: String
    let sourceTag: String?
    let sourceCommit: String
    let sourceTree: String?
    let schemaVersion: String
    let storeFilename: String
    let artifacts: [Artifact]

    func validate(against descriptor: StoredMigrationFixtureDescriptor) throws {
        guard formatVersion == descriptor.formatVersion else {
            throw StoredMigrationFixtureError.invalidManifest(
                "formatVersion must be \(descriptor.formatVersion)",
            )
        }
        guard fixtureID == descriptor.fixtureID else {
            throw StoredMigrationFixtureError.invalidManifest("unexpected fixtureID \(fixtureID)")
        }
        guard sourceTag == descriptor.sourceTag else {
            throw StoredMigrationFixtureError.invalidManifest(
                "unexpected sourceTag \(String(describing: sourceTag))",
            )
        }
        guard sourceCommit == descriptor.sourceCommit else {
            throw StoredMigrationFixtureError.invalidManifest(
                "unexpected sourceCommit \(sourceCommit)",
            )
        }
        guard sourceTree == descriptor.sourceTree else {
            throw StoredMigrationFixtureError.invalidManifest(
                "unexpected sourceTree \(String(describing: sourceTree))",
            )
        }
        guard schemaVersion == descriptor.schemaVersion else {
            throw StoredMigrationFixtureError.invalidManifest(
                "unexpected schemaVersion \(schemaVersion)",
            )
        }
        guard storeFilename == "default.store" else {
            throw StoredMigrationFixtureError.invalidManifest(
                "storeFilename must be default.store",
            )
        }
        guard !artifacts.isEmpty else {
            throw StoredMigrationFixtureError.invalidManifest("artifacts must not be empty")
        }
        guard artifacts.map(\.filename) == artifacts.map(\.filename).sorted() else {
            throw StoredMigrationFixtureError.invalidManifest(
                "artifacts must use stable filename ordering",
            )
        }
        guard Set(artifacts.map(\.filename)).count == artifacts.count else {
            throw StoredMigrationFixtureError.invalidManifest(
                "artifact filenames must be unique",
            )
        }
        guard artifacts.contains(where: { $0.filename == storeFilename }) else {
            throw StoredMigrationFixtureError.invalidManifest(
                "artifacts must include default.store",
            )
        }

        let allowedFilenames = Set(["default.store", "default.store-shm", "default.store-wal"])
        for artifact in artifacts {
            guard allowedFilenames.contains(artifact.filename) else {
                throw StoredMigrationFixtureError.invalidManifest(
                    "unsupported artifact filename \(artifact.filename)",
                )
            }
            guard artifact.byteCount > 0 else {
                throw StoredMigrationFixtureError.invalidManifest(
                    "artifact \(artifact.filename) must not be empty",
                )
            }
            guard artifact.sha256.count == 64,
                  artifact.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else {
                throw StoredMigrationFixtureError.invalidManifest(
                    "artifact \(artifact.filename) must have a lowercase SHA-256 digest",
                )
            }
        }
    }
}

struct StoredMigrationFixture {
    struct MaterializedCopy {
        let directoryURL: URL
        let storeURL: URL
    }

    let directoryURL: URL
    let manifest: StoredMigrationFixtureManifest
    let descriptor: StoredMigrationFixtureDescriptor

    static func loadFromTestBundle(
        descriptor: StoredMigrationFixtureDescriptor,
    ) throws -> Self {
        let bundle = Bundle(for: ReleasedV1FixtureBundleToken.self)
        let directDirectoryURL = bundle.resourceURL?.appendingPathComponent(
            descriptor.fixtureID,
            isDirectory: true,
        )
        let directoryURL = bundle.url(
            forResource: descriptor.fixtureID,
            withExtension: nil,
        ) ?? directDirectoryURL
        guard let directoryURL,
              FileManager.default.fileExists(atPath: directoryURL.path)
        else {
            throw StoredMigrationFixtureError.missingFixture(
                "Run \(descriptor.generatorCommand) to create the bundled fixture.",
            )
        }
        let manifestURL = directoryURL.appendingPathComponent(
            "manifest.json",
            isDirectory: false,
        )
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw StoredMigrationFixtureError.missingFixture(
                "Missing manifest.json; run \(descriptor.generatorCommand).",
            )
        }
        let manifest = try JSONDecoder().decode(
            StoredMigrationFixtureManifest.self,
            from: Data(contentsOf: manifestURL),
        )
        try manifest.validate(against: descriptor)
        let fixture = Self(
            directoryURL: directoryURL,
            manifest: manifest,
            descriptor: descriptor,
        )
        try fixture.verifyBundledArtifacts()
        return fixture
    }

    func verifyBundledArtifacts() throws {
        try verifyArtifacts(in: directoryURL)
    }

    func verifyArtifacts(in directoryURL: URL) throws {
        _ = try artifactData(in: directoryURL)
    }

    func artifactData(in directoryURL: URL) throws -> [String: Data] {
        let expectedFilenames = Set(manifest.artifacts.map(\.filename))
        let actualStoreFilenames = try Set(
            FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
            )
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("default.store") },
        )
        guard actualStoreFilenames == expectedFilenames else {
            throw StoredMigrationFixtureError.artifactSetMismatch(
                expected: expectedFilenames.sorted(),
                actual: actualStoreFilenames.sorted(),
            )
        }

        var dataByFilename: [String: Data] = [:]
        for artifact in manifest.artifacts {
            let artifactURL = directoryURL.appendingPathComponent(
                artifact.filename,
                isDirectory: false,
            )
            let data = try Data(contentsOf: artifactURL, options: [.mappedIfSafe])
            guard data.count == artifact.byteCount else {
                throw StoredMigrationFixtureError.byteCountMismatch(
                    filename: artifact.filename,
                    expected: artifact.byteCount,
                    actual: data.count,
                )
            }
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", Int($0)) }
                .joined()
            guard digest == artifact.sha256 else {
                throw StoredMigrationFixtureError.checksumMismatch(
                    filename: artifact.filename,
                    expected: artifact.sha256,
                    actual: digest,
                )
            }
            dataByFilename[artifact.filename] = data
        }
        return dataByFilename
    }

    func makeTemporaryCopy() throws -> MaterializedCopy {
        try verifyBundledArtifacts()
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OpenASO-StoredFixture-\(descriptor.fixtureID)-\(UUID().uuidString)",
                isDirectory: true,
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true,
        )
        do {
            for artifact in manifest.artifacts {
                try FileManager.default.copyItem(
                    at: directoryURL.appendingPathComponent(artifact.filename),
                    to: temporaryDirectoryURL.appendingPathComponent(artifact.filename),
                )
            }
            try verifyArtifacts(in: temporaryDirectoryURL)
            return MaterializedCopy(
                directoryURL: temporaryDirectoryURL,
                storeURL: temporaryDirectoryURL.appendingPathComponent(manifest.storeFilename),
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
            throw error
        }
    }
}

struct ReleasedV1StoreFixture {
    typealias MaterializedCopy = StoredMigrationFixture.MaterializedCopy

    private let fixture: StoredMigrationFixture

    var directoryURL: URL { fixture.directoryURL }
    var manifest: StoredMigrationFixtureManifest { fixture.manifest }

    static func loadFromTestBundle() throws -> Self {
        try Self(fixture: .loadFromTestBundle(descriptor: .releasedV1))
    }

    func verifyBundledArtifacts() throws { try fixture.verifyBundledArtifacts() }
    func verifyArtifacts(in directoryURL: URL) throws {
        try fixture.verifyArtifacts(in: directoryURL)
    }

    func artifactData(in directoryURL: URL) throws -> [String: Data] {
        try fixture.artifactData(in: directoryURL)
    }

    func makeTemporaryCopy() throws -> MaterializedCopy { try fixture.makeTemporaryCopy() }
}

struct ExactV4StoreFixture {
    typealias MaterializedCopy = StoredMigrationFixture.MaterializedCopy

    private let fixture: StoredMigrationFixture

    var directoryURL: URL { fixture.directoryURL }
    var manifest: StoredMigrationFixtureManifest { fixture.manifest }

    static func loadFromTestBundle() throws -> Self {
        try Self(fixture: .loadFromTestBundle(descriptor: .exactV4))
    }

    func verifyBundledArtifacts() throws { try fixture.verifyBundledArtifacts() }
    func verifyArtifacts(in directoryURL: URL) throws {
        try fixture.verifyArtifacts(in: directoryURL)
    }

    func artifactData(in directoryURL: URL) throws -> [String: Data] {
        try fixture.artifactData(in: directoryURL)
    }

    func makeTemporaryCopy() throws -> MaterializedCopy { try fixture.makeTemporaryCopy() }
}

enum StoredMigrationFixtureError: LocalizedError {
    case missingFixture(String)
    case invalidManifest(String)
    case artifactSetMismatch(expected: [String], actual: [String])
    case byteCountMismatch(filename: String, expected: Int, actual: Int)
    case checksumMismatch(filename: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .missingFixture(message), let .invalidManifest(message):
            message
        case let .artifactSetMismatch(expected, actual):
            "Fixture artifacts differ: expected \(expected), found \(actual)."
        case let .byteCountMismatch(filename, expected, actual):
            "Fixture \(filename) has \(actual) bytes; expected \(expected)."
        case let .checksumMismatch(filename, expected, actual):
            "Fixture \(filename) SHA-256 is \(actual); expected \(expected)."
        }
    }
}

typealias ReleasedV1StoreFixtureManifest = StoredMigrationFixtureManifest
typealias ReleasedV1StoreFixtureError = StoredMigrationFixtureError

final class ReleasedV1FixtureBundleToken {}
