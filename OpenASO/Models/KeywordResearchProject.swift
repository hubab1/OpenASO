import Foundation
import SwiftData

/// A pre-live keyword research workspace with an identity that is independent
/// of any App Store record.
///
/// The caller-facing UUID and a durable incarnation UUID form the generation
/// identity used by later actor-isolated mutation workflows. Display names,
/// bundle identifiers, and timestamps are deliberately not identities and may
/// be duplicated.
@Model
final class KeywordResearchProject {
    #Index<KeywordResearchProject>(
        [\.name],
        [\.createdAt],
        [\.updatedAt]
    )

    @Attribute(.unique) private(set) var id: UUID
    @Attribute(.unique) private(set) var incarnationID: UUID
    var name: String
    var bundleID: String?
    var defaultStorefront: String
    var defaultPlatformRaw: String
    var notes: String
    private(set) var createdAt: Date
    var updatedAt: Date

    /// A project owns only its membership rows. Query, ranking, metric, and
    /// difficulty records remain shared app-independent data keyed by queryKey.
    @Relationship(deleteRule: .cascade, inverse: \KeywordResearchKeyword.project)
    private(set) var keywords: [KeywordResearchKeyword]

    init(
        id: UUID = UUID(),
        name: String,
        bundleID: String? = nil,
        defaultStorefront: String = "us",
        defaultPlatform: AppPlatform = .iphone,
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.incarnationID = UUID()
        self.name = Self.normalizedName(name)
        self.bundleID = Self.normalizedBundleID(bundleID)
        self.defaultStorefront = Self.normalizedStorefront(defaultStorefront)
        self.defaultPlatformRaw = defaultPlatform.rawValue
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = max(updatedAt ?? createdAt, createdAt)
        self.keywords = []
    }

    /// Establishes the owning side of the SwiftData relationship without
    /// exposing arbitrary replacement or removal of the membership array.
    /// The membership's immutable project reference must already target this
    /// project; deletion remains a `ModelContext` operation.
    func attachKeyword(_ keyword: KeywordResearchKeyword) {
        precondition(keyword.project === self)
        guard !keywords.contains(where: { $0.id == keyword.id }) else { return }
        keywords.append(keyword)
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedBundleID(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedStorefront(_ storefront: String) -> String {
        storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var defaultPlatform: AppPlatform {
        get { AppPlatform(rawValue: defaultPlatformRaw) ?? .iphone }
        set { defaultPlatformRaw = newValue.rawValue }
    }

    var generation: KeywordResearchProjectGeneration {
        KeywordResearchProjectGeneration(
            id: id,
            incarnationID: incarnationID
        )
    }
}

struct KeywordResearchProjectGeneration: Equatable, Hashable, Sendable {
    let id: UUID
    let incarnationID: UUID
}
