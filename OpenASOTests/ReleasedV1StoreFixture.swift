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

struct ReleasedV1StoreFixtureManifest: Decodable {
    struct Artifact: Decodable, Hashable {
        let filename: String
        let byteCount: Int
        let sha256: String
    }

    let formatVersion: Int
    let fixtureID: String
    let sourceTag: String
    let sourceCommit: String
    let schemaVersion: String
    let storeFilename: String
    let artifacts: [Artifact]

    func validate() throws {
        guard formatVersion == 1 else {
            throw ReleasedV1StoreFixtureError.invalidManifest("formatVersion must be 1")
        }
        guard fixtureID == ReleasedV1FixtureSentinel.fixtureID else {
            throw ReleasedV1StoreFixtureError.invalidManifest("unexpected fixtureID \(fixtureID)")
        }
        guard sourceTag == ReleasedV1FixtureSentinel.sourceTag else {
            throw ReleasedV1StoreFixtureError.invalidManifest("unexpected sourceTag \(sourceTag)")
        }
        guard sourceCommit == ReleasedV1FixtureSentinel.sourceCommit else {
            throw ReleasedV1StoreFixtureError.invalidManifest("unexpected sourceCommit \(sourceCommit)")
        }
        guard schemaVersion == ReleasedV1FixtureSentinel.schemaVersion else {
            throw ReleasedV1StoreFixtureError.invalidManifest("unexpected schemaVersion \(schemaVersion)")
        }
        guard storeFilename == "default.store" else {
            throw ReleasedV1StoreFixtureError.invalidManifest("storeFilename must be default.store")
        }
        guard !artifacts.isEmpty else {
            throw ReleasedV1StoreFixtureError.invalidManifest("artifacts must not be empty")
        }
        guard artifacts.map(\.filename) == artifacts.map(\.filename).sorted() else {
            throw ReleasedV1StoreFixtureError.invalidManifest("artifacts must use stable filename ordering")
        }
        guard Set(artifacts.map(\.filename)).count == artifacts.count else {
            throw ReleasedV1StoreFixtureError.invalidManifest("artifact filenames must be unique")
        }
        guard artifacts.contains(where: { $0.filename == storeFilename }) else {
            throw ReleasedV1StoreFixtureError.invalidManifest("artifacts must include default.store")
        }

        let allowedFilenames = Set(["default.store", "default.store-shm", "default.store-wal"])
        for artifact in artifacts {
            guard allowedFilenames.contains(artifact.filename) else {
                throw ReleasedV1StoreFixtureError.invalidManifest(
                    "unsupported artifact filename \(artifact.filename)"
                )
            }
            guard artifact.byteCount > 0 else {
                throw ReleasedV1StoreFixtureError.invalidManifest(
                    "artifact \(artifact.filename) must not be empty"
                )
            }
            guard artifact.sha256.count == 64,
                  artifact.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else {
                throw ReleasedV1StoreFixtureError.invalidManifest(
                    "artifact \(artifact.filename) must have a lowercase SHA-256 digest"
                )
            }
        }
    }
}

struct ReleasedV1StoreFixture {
    struct MaterializedCopy {
        let directoryURL: URL
        let storeURL: URL
    }

    let directoryURL: URL
    let manifest: ReleasedV1StoreFixtureManifest

    static func loadFromTestBundle() throws -> Self {
        let bundle = Bundle(for: ReleasedV1FixtureBundleToken.self)
        let directDirectoryURL = bundle.resourceURL?.appendingPathComponent(
            ReleasedV1FixtureSentinel.fixtureID,
            isDirectory: true
        )
        let directoryURL = bundle.url(
            forResource: ReleasedV1FixtureSentinel.fixtureID,
            withExtension: nil
        ) ?? directDirectoryURL
        guard let directoryURL,
              FileManager.default.fileExists(atPath: directoryURL.path)
        else {
            throw ReleasedV1StoreFixtureError.missingFixture(
                "Run ./script/generate_v032_migration_fixture.sh to create the bundled fixture."
            )
        }
        let manifestURL = directoryURL.appendingPathComponent("manifest.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ReleasedV1StoreFixtureError.missingFixture(
                "Missing \(manifestURL.lastPathComponent); run ./script/generate_v032_migration_fixture.sh."
            )
        }
        let manifest = try JSONDecoder().decode(
            ReleasedV1StoreFixtureManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        try manifest.validate()
        let fixture = Self(directoryURL: directoryURL, manifest: manifest)
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
        let actualStoreFilenames = Set(
            try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("default.store") }
        )
        guard actualStoreFilenames == expectedFilenames else {
            throw ReleasedV1StoreFixtureError.artifactSetMismatch(
                expected: expectedFilenames.sorted(),
                actual: actualStoreFilenames.sorted()
            )
        }

        var dataByFilename: [String: Data] = [:]
        for artifact in manifest.artifacts {
            let artifactURL = directoryURL.appendingPathComponent(
                artifact.filename,
                isDirectory: false
            )
            let data = try Data(contentsOf: artifactURL, options: [.mappedIfSafe])
            guard data.count == artifact.byteCount else {
                throw ReleasedV1StoreFixtureError.byteCountMismatch(
                    filename: artifact.filename,
                    expected: artifact.byteCount,
                    actual: data.count
                )
            }
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", Int($0)) }
                .joined()
            guard digest == artifact.sha256 else {
                throw ReleasedV1StoreFixtureError.checksumMismatch(
                    filename: artifact.filename,
                    expected: artifact.sha256,
                    actual: digest
                )
            }
            dataByFilename[artifact.filename] = data
        }
        return dataByFilename
    }

    func makeTemporaryCopy() throws -> MaterializedCopy {
        try verifyBundledArtifacts()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OpenASO-ReleasedV1Fixture-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        do {
            for artifact in manifest.artifacts {
                try FileManager.default.copyItem(
                    at: self.directoryURL.appendingPathComponent(artifact.filename),
                    to: directoryURL.appendingPathComponent(artifact.filename)
                )
            }
            try verifyArtifacts(in: directoryURL)
            return MaterializedCopy(
                directoryURL: directoryURL,
                storeURL: directoryURL.appendingPathComponent(manifest.storeFilename)
            )
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }
}

enum ReleasedV1StoreFixtureError: LocalizedError {
    case missingFixture(String)
    case invalidManifest(String)
    case artifactSetMismatch(expected: [String], actual: [String])
    case byteCountMismatch(filename: String, expected: Int, actual: Int)
    case checksumMismatch(filename: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .missingFixture(let message), .invalidManifest(let message):
            return message
        case .artifactSetMismatch(let expected, let actual):
            return "Fixture artifacts differ: expected \(expected), found \(actual)."
        case .byteCountMismatch(let filename, let expected, let actual):
            return "Fixture \(filename) has \(actual) bytes; expected \(expected)."
        case .checksumMismatch(let filename, let expected, let actual):
            return "Fixture \(filename) SHA-256 is \(actual); expected \(expected)."
        }
    }
}

final class ReleasedV1FixtureBundleToken {}
