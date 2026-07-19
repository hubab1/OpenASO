import Foundation
import SwiftData

struct KeywordResearchProjectRevision: Equatable, Hashable, Sendable {
    let generation: KeywordResearchProjectGeneration
    let updatedAt: Date
}

struct KeywordResearchKeywordRevision: Equatable, Hashable, Sendable {
    let generation: KeywordResearchKeywordGeneration
    let updatedAt: Date
}

struct KeywordResearchProjectSnapshot: Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    let incarnationID: UUID
    let name: String
    let bundleID: String?
    let defaultStorefront: String
    let defaultPlatform: AppPlatform
    let notes: String
    let createdAt: Date
    let updatedAt: Date

    var generation: KeywordResearchProjectGeneration {
        KeywordResearchProjectGeneration(id: id, incarnationID: incarnationID)
    }

    var revision: KeywordResearchProjectRevision {
        KeywordResearchProjectRevision(generation: generation, updatedAt: updatedAt)
    }
}

struct KeywordResearchKeywordSnapshot: Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    let incarnationID: UUID
    let projectID: UUID
    let queryKey: String
    let term: String
    let storefront: String
    let platform: AppPlatform
    let notes: String
    let createdAt: Date
    let updatedAt: Date

    var generation: KeywordResearchKeywordGeneration {
        KeywordResearchKeywordGeneration(id: id, incarnationID: incarnationID)
    }

    var revision: KeywordResearchKeywordRevision {
        KeywordResearchKeywordRevision(generation: generation, updatedAt: updatedAt)
    }
}

struct KeywordResearchKeywordAddition: Equatable, Hashable, Sendable {
    let project: KeywordResearchProjectSnapshot
    let keyword: KeywordResearchKeywordSnapshot
}

struct KeywordResearchPage<Item: Sendable>: Sendable {
    let items: [Item]
    let nextOffset: Int?
}

extension KeywordResearchPage: Equatable where Item: Equatable {}
extension KeywordResearchPage: Hashable where Item: Hashable {}

/// The MCP dependency intentionally exposes reads only. A future standalone
/// mutation surface must first add store-wide, cross-process coordination;
/// process-local actor isolation is not sufficient for two persistent
/// containers writing the same workspace.
protocol KeywordResearchProjectReading: Sendable {
    func loadProject(
        generation: KeywordResearchProjectGeneration
    ) async throws -> KeywordResearchProjectSnapshot

    func listProjects(
        offset: Int,
        limit: Int
    ) async throws -> [KeywordResearchProjectSnapshot]

    func listProjectsPage(
        offset: Int,
        limit: Int
    ) async throws -> KeywordResearchPage<KeywordResearchProjectSnapshot>

    func listKeywords(
        in projectGeneration: KeywordResearchProjectGeneration,
        offset: Int,
        limit: Int
    ) async throws -> [KeywordResearchKeywordSnapshot]

    func listKeywordsPage(
        in projectGeneration: KeywordResearchProjectGeneration,
        offset: Int,
        limit: Int
    ) async throws -> KeywordResearchPage<KeywordResearchKeywordSnapshot>
}

enum KeywordResearchProjectStoreError: Error, Equatable, Sendable {
    case invalidName
    case invalidBundleID
    case invalidStorefront
    case invalidTerm
    case invalidNotes
    case invalidOffset
    case invalidLimit
    case projectLimitReached(maximum: Int)
    case keywordLimitReached(projectID: UUID, maximum: Int)
    case projectNotFound(UUID)
    case keywordNotFound(UUID)
    case keywordIdentifierConflict(UUID)
    case staleProjectRevision(UUID)
    case staleKeywordRevision(UUID)
}

/// Serializes process-local research-project workflows while keeping SwiftData
/// models inside the existing background model executor. Callers receive
/// immutable Sendable values only; no persistent model crosses either actor
/// boundary. Coordination with another OpenASO process remains store-backed,
/// not actor-backed.
actor KeywordResearchProjectStore {
    static let maximumNameByteCount = 200
    static let maximumBundleIDByteCount = 255
    static let maximumTermByteCount = 200
    static let maximumNotesByteCount = 10_000
    static let maximumPageLimit = 200
    static let maximumProjectCount = 100
    static let maximumKeywordCountPerProject = 500

    private static let minimumRevisionAdvance: TimeInterval = 0.001_1

    private let modelStore: BackgroundModelStore
    private let now: @Sendable () -> Date
    private let projectLimit: Int
    private let keywordLimitPerProject: Int

    init(
        backgroundModelStore: BackgroundModelStore,
        now: @escaping @Sendable () -> Date = { Date() },
        projectLimit: Int = KeywordResearchProjectStore.maximumProjectCount,
        keywordLimitPerProject: Int = KeywordResearchProjectStore.maximumKeywordCountPerProject
    ) {
        precondition(projectLimit > 0)
        precondition(keywordLimitPerProject > 0)
        self.modelStore = backgroundModelStore
        self.now = now
        self.projectLimit = projectLimit
        self.keywordLimitPerProject = keywordLimitPerProject
    }

    func createProject(
        id: UUID = UUID(),
        name: String,
        bundleID: String? = nil,
        defaultStorefront: String = "us",
        defaultPlatform: AppPlatform = .iphone,
        notes: String = ""
    ) async throws -> KeywordResearchProjectSnapshot {
        let values = try Self.normalizedProjectValues(
            name: name,
            bundleID: bundleID,
            storefront: defaultStorefront,
            platform: defaultPlatform,
            notes: notes
        )
        let now = self.now
        let projectLimit = projectLimit

        return try await modelStore.write { modelContext in
            if let existing = try Self.project(id: id, in: modelContext) {
                // The caller-owned UUID is the idempotency key. A retry after
                // later edits returns the current resource without replaying
                // or overwriting its original create payload.
                return Self.snapshot(existing)
            }
            guard try modelContext.fetchCount(
                FetchDescriptor<KeywordResearchProject>()
            ) < projectLimit else {
                throw KeywordResearchProjectStoreError.projectLimitReached(
                    maximum: projectLimit
                )
            }

            let project = KeywordResearchProject(
                id: id,
                name: values.name,
                bundleID: values.bundleID,
                defaultStorefront: values.storefront,
                defaultPlatform: values.platform,
                notes: values.notes,
                createdAt: now()
            )
            modelContext.insert(project)
            return Self.snapshot(project)
        }
    }

    func listProjects(
        offset: Int = 0,
        limit: Int = 50
    ) async throws -> [KeywordResearchProjectSnapshot] {
        try Self.validatePagination(offset: offset, limit: limit)

        return try await modelStore.fetch(Self.projectsDescriptor(offset: offset, limit: limit)) {
            $0.map(Self.snapshot)
        }
    }

    func loadProject(
        generation: KeywordResearchProjectGeneration
    ) async throws -> KeywordResearchProjectSnapshot {
        try await modelStore.read { modelContext in
            Self.snapshot(try Self.requireProject(
                generation: generation,
                in: modelContext
            ))
        }
    }

    func listProjectsPage(
        offset: Int = 0,
        limit: Int = 50
    ) async throws -> KeywordResearchPage<KeywordResearchProjectSnapshot> {
        try Self.validatePagination(offset: offset, limit: limit)

        return try await modelStore.fetch(
            Self.projectsDescriptor(offset: offset, limit: limit + 1)
        ) { projects in
            let snapshots = projects.map(Self.snapshot)
            return Self.page(items: snapshots, offset: offset, limit: limit)
        }
    }

    func updateProject(
        revision: KeywordResearchProjectRevision,
        name: String,
        bundleID: String? = nil,
        defaultStorefront: String,
        defaultPlatform: AppPlatform,
        notes: String = ""
    ) async throws -> KeywordResearchProjectSnapshot {
        let values = try Self.normalizedProjectValues(
            name: name,
            bundleID: bundleID,
            storefront: defaultStorefront,
            platform: defaultPlatform,
            notes: notes
        )
        let now = self.now

        return try await modelStore.write { modelContext in
            let project = try Self.requireProject(
                revision: revision,
                in: modelContext
            )
            project.name = values.name
            project.bundleID = values.bundleID
            project.defaultStorefront = values.storefront
            project.defaultPlatform = values.platform
            project.notes = values.notes
            project.updatedAt = Self.nextRevisionDate(
                previous: project.updatedAt,
                candidate: now()
            )
            return Self.snapshot(project)
        }
    }

    func deleteProject(
        revision: KeywordResearchProjectRevision
    ) async throws {
        try await modelStore.write { modelContext in
            let project = try Self.requireProject(
                revision: revision,
                in: modelContext
            )
            modelContext.delete(project)
        }
    }

    func listKeywords(
        in projectGeneration: KeywordResearchProjectGeneration,
        offset: Int = 0,
        limit: Int = 50
    ) async throws -> [KeywordResearchKeywordSnapshot] {
        try Self.validatePagination(offset: offset, limit: limit)

        return try await modelStore.read { modelContext in
            _ = try Self.requireProject(
                generation: projectGeneration,
                in: modelContext
            )
            let descriptor = Self.keywordsDescriptor(
                projectID: projectGeneration.id,
                offset: offset,
                limit: limit
            )
            return try modelContext.fetch(descriptor).map(Self.snapshot)
        }
    }

    func listKeywordsPage(
        in projectGeneration: KeywordResearchProjectGeneration,
        offset: Int = 0,
        limit: Int = 50
    ) async throws -> KeywordResearchPage<KeywordResearchKeywordSnapshot> {
        try Self.validatePagination(offset: offset, limit: limit)

        return try await modelStore.read { modelContext in
            _ = try Self.requireProject(
                generation: projectGeneration,
                in: modelContext
            )
            let descriptor = Self.keywordsDescriptor(
                projectID: projectGeneration.id,
                offset: offset,
                limit: limit + 1
            )
            let snapshots = try modelContext.fetch(descriptor).map(Self.snapshot)
            return Self.page(items: snapshots, offset: offset, limit: limit)
        }
    }

    func addKeyword(
        id: UUID = UUID(),
        to projectRevision: KeywordResearchProjectRevision,
        term: String,
        storefront: String,
        platform: AppPlatform,
        notes: String = ""
    ) async throws -> KeywordResearchKeywordAddition {
        let values = try Self.normalizedKeywordValues(
            term: term,
            storefront: storefront,
            platform: platform,
            notes: notes
        )
        let now = self.now
        let keywordLimitPerProject = keywordLimitPerProject

        return try await modelStore.write { modelContext in
            let project = try Self.requireProject(
                generation: projectRevision.generation,
                in: modelContext
            )
            let expectedQueryKey = KeywordQuery.makeQueryKey(
                term: values.term,
                storefront: values.storefront,
                platform: values.platform
            )

            let existingWithID = try Self.keyword(id: id, in: modelContext)
            if let existingWithID {
                guard existingWithID.projectID == project.id,
                      existingWithID.queryKey == expectedQueryKey
                else {
                    throw KeywordResearchProjectStoreError.keywordIdentifierConflict(id)
                }
            }

            let membershipKey = KeywordResearchKeyword.makeMembershipKey(
                projectID: project.id,
                queryKey: expectedQueryKey
            )
            let existingMembership = try Self.keyword(
                membershipKey: membershipKey,
                in: modelContext
            )

            // Always go through the V1 factory, including duplicate membership
            // retries, so an independently seeded V5 row cannot leave its
            // shared query missing.
            let query = try KeywordQuery.fetchOrInsert(
                term: values.term,
                storefront: values.storefront,
                platform: values.platform,
                in: modelContext
            )
            let queryKey = query.queryKey

            if let existingWithID {
                return KeywordResearchKeywordAddition(
                    project: Self.snapshot(project),
                    keyword: Self.snapshot(existingWithID)
                )
            }

            if let existingMembership {
                return KeywordResearchKeywordAddition(
                    project: Self.snapshot(project),
                    keyword: Self.snapshot(existingMembership)
                )
            }

            let targetProjectID = project.id
            let projectKeywordCount = try modelContext.fetchCount(
                FetchDescriptor<KeywordResearchKeyword>(
                    predicate: #Predicate { keyword in
                        keyword.projectID == targetProjectID
                    }
                )
            )
            guard projectKeywordCount < keywordLimitPerProject else {
                throw KeywordResearchProjectStoreError.keywordLimitReached(
                    projectID: project.id,
                    maximum: keywordLimitPerProject
                )
            }

            guard queryKey == expectedQueryKey else {
                throw KeywordResearchProjectStoreError.keywordIdentifierConflict(id)
            }
            try Self.requireCurrentProjectRevision(project, expected: projectRevision)
            let changedAt = now()

            let keyword = KeywordResearchKeyword(
                id: id,
                term: query.term,
                storefront: query.storefront,
                platform: query.platform,
                project: project,
                notes: values.notes,
                createdAt: changedAt
            )
            project.attachKeyword(keyword)
            modelContext.insert(keyword)
            project.updatedAt = Self.nextRevisionDate(
                previous: project.updatedAt,
                candidate: changedAt
            )
            return KeywordResearchKeywordAddition(
                project: Self.snapshot(project),
                keyword: Self.snapshot(keyword)
            )
        }
    }

    func removeKeyword(
        revision: KeywordResearchKeywordRevision,
        from projectRevision: KeywordResearchProjectRevision
    ) async throws -> KeywordResearchProjectSnapshot {
        let now = self.now

        return try await modelStore.write { modelContext in
            let project = try Self.requireProject(
                generation: projectRevision.generation,
                in: modelContext
            )
            let keyword = try Self.requireKeyword(
                revision: revision,
                in: modelContext
            )
            guard keyword.projectID == projectRevision.generation.id else {
                throw KeywordResearchProjectStoreError.keywordNotFound(revision.generation.id)
            }
            try Self.requireCurrentProjectRevision(project, expected: projectRevision)
            modelContext.delete(keyword)
            project.updatedAt = Self.nextRevisionDate(
                previous: project.updatedAt,
                candidate: now()
            )
            return Self.snapshot(project)
        }
    }
}

extension KeywordResearchProjectStore: KeywordResearchProjectReading {}

private extension KeywordResearchProjectStore {
    struct ProjectValues: Sendable {
        let name: String
        let bundleID: String?
        let storefront: String
        let platform: AppPlatform
        let notes: String
    }

    struct KeywordValues: Sendable {
        let term: String
        let storefront: String
        let platform: AppPlatform
        let notes: String
    }

    static func normalizedProjectValues(
        name: String,
        bundleID: String?,
        storefront: String,
        platform: AppPlatform,
        notes: String
    ) throws -> ProjectValues {
        let normalizedName = KeywordResearchProject.normalizedName(name)
        guard !normalizedName.isEmpty,
              normalizedName.utf8.count <= maximumNameByteCount
        else {
            throw KeywordResearchProjectStoreError.invalidName
        }

        let normalizedBundleID = KeywordResearchProject.normalizedBundleID(bundleID)
        guard normalizedBundleID?.utf8.count ?? 0 <= maximumBundleIDByteCount else {
            throw KeywordResearchProjectStoreError.invalidBundleID
        }

        return ProjectValues(
            name: normalizedName,
            bundleID: normalizedBundleID,
            storefront: try normalizedStorefront(storefront),
            platform: platform,
            notes: try validatedNotes(notes)
        )
    }

    static func normalizedKeywordValues(
        term: String,
        storefront: String,
        platform: AppPlatform,
        notes: String
    ) throws -> KeywordValues {
        let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTerm.isEmpty,
              normalizedTerm.utf8.count <= maximumTermByteCount
        else {
            throw KeywordResearchProjectStoreError.invalidTerm
        }

        return KeywordValues(
            term: normalizedTerm,
            storefront: try normalizedStorefront(storefront),
            platform: platform,
            notes: try validatedNotes(notes)
        )
    }

    static func normalizedStorefront(_ storefront: String) throws -> String {
        let normalized = KeywordResearchProject.normalizedStorefront(storefront)
        let bytes = Array(normalized.utf8)
        guard bytes.count == 2,
              bytes.allSatisfy({ (97...122).contains(Int($0)) })
        else {
            throw KeywordResearchProjectStoreError.invalidStorefront
        }
        return normalized
    }

    static func validatedNotes(_ notes: String) throws -> String {
        guard notes.utf8.count <= maximumNotesByteCount else {
            throw KeywordResearchProjectStoreError.invalidNotes
        }
        return notes
    }

    static func validatePagination(offset: Int, limit: Int) throws {
        guard offset >= 0 else {
            throw KeywordResearchProjectStoreError.invalidOffset
        }
        guard (1...maximumPageLimit).contains(limit) else {
            throw KeywordResearchProjectStoreError.invalidLimit
        }
        guard offset <= Int.max - limit else {
            throw KeywordResearchProjectStoreError.invalidOffset
        }
    }

    static func page<Item: Sendable>(
        items: [Item],
        offset: Int,
        limit: Int
    ) -> KeywordResearchPage<Item> {
        let hasMore = items.count > limit
        let pageItems = Array(items.prefix(limit))
        return KeywordResearchPage(
            items: pageItems,
            nextOffset: hasMore ? offset + pageItems.count : nil
        )
    }

    static func nextRevisionDate(previous: Date, candidate: Date) -> Date {
        max(candidate, previous.addingTimeInterval(minimumRevisionAdvance))
    }

    static func projectsDescriptor(
        offset: Int,
        limit: Int
    ) -> FetchDescriptor<KeywordResearchProject> {
        var descriptor = FetchDescriptor<KeywordResearchProject>(sortBy: [
            SortDescriptor(\KeywordResearchProject.createdAt, order: .forward),
            SortDescriptor(\KeywordResearchProject.id, order: .forward)
        ])
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return descriptor
    }

    static func keywordsDescriptor(
        projectID: UUID,
        offset: Int,
        limit: Int
    ) -> FetchDescriptor<KeywordResearchKeyword> {
        let targetProjectID = projectID
        var descriptor = FetchDescriptor<KeywordResearchKeyword>(
            predicate: #Predicate { keyword in
                keyword.projectID == targetProjectID
            },
            sortBy: [
                SortDescriptor(\KeywordResearchKeyword.createdAt, order: .forward),
                SortDescriptor(\KeywordResearchKeyword.id, order: .forward)
            ]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return descriptor
    }

    static func project(
        id: UUID,
        in modelContext: ModelContext
    ) throws -> KeywordResearchProject? {
        let targetID = id
        var descriptor = FetchDescriptor<KeywordResearchProject>(
            predicate: #Predicate { project in
                project.id == targetID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    static func keyword(
        id: UUID,
        in modelContext: ModelContext
    ) throws -> KeywordResearchKeyword? {
        let targetID = id
        var descriptor = FetchDescriptor<KeywordResearchKeyword>(
            predicate: #Predicate { keyword in
                keyword.id == targetID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    static func keyword(
        membershipKey: String,
        in modelContext: ModelContext
    ) throws -> KeywordResearchKeyword? {
        let targetMembershipKey = membershipKey
        var descriptor = FetchDescriptor<KeywordResearchKeyword>(
            predicate: #Predicate { keyword in
                keyword.membershipKey == targetMembershipKey
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    static func requireProject(
        generation: KeywordResearchProjectGeneration,
        in modelContext: ModelContext
    ) throws -> KeywordResearchProject {
        guard let project = try project(id: generation.id, in: modelContext) else {
            throw KeywordResearchProjectStoreError.projectNotFound(generation.id)
        }
        guard project.incarnationID == generation.incarnationID else {
            throw KeywordResearchProjectStoreError.staleProjectRevision(generation.id)
        }
        return project
    }

    static func requireProject(
        revision: KeywordResearchProjectRevision,
        in modelContext: ModelContext
    ) throws -> KeywordResearchProject {
        let project = try requireProject(
            generation: revision.generation,
            in: modelContext
        )
        guard project.updatedAt == revision.updatedAt else {
            throw KeywordResearchProjectStoreError.staleProjectRevision(revision.generation.id)
        }
        return project
    }

    static func requireCurrentProjectRevision(
        _ project: KeywordResearchProject,
        expected revision: KeywordResearchProjectRevision
    ) throws {
        guard project.incarnationID == revision.generation.incarnationID,
              project.updatedAt == revision.updatedAt
        else {
            throw KeywordResearchProjectStoreError.staleProjectRevision(revision.generation.id)
        }
    }

    static func requireKeyword(
        revision: KeywordResearchKeywordRevision,
        in modelContext: ModelContext
    ) throws -> KeywordResearchKeyword {
        guard let keyword = try keyword(id: revision.generation.id, in: modelContext) else {
            throw KeywordResearchProjectStoreError.keywordNotFound(revision.generation.id)
        }
        guard keyword.incarnationID == revision.generation.incarnationID,
              keyword.updatedAt == revision.updatedAt
        else {
            throw KeywordResearchProjectStoreError.staleKeywordRevision(revision.generation.id)
        }
        return keyword
    }

    static func snapshot(
        _ project: KeywordResearchProject
    ) -> KeywordResearchProjectSnapshot {
        KeywordResearchProjectSnapshot(
            id: project.id,
            incarnationID: project.incarnationID,
            name: project.name,
            bundleID: project.bundleID,
            defaultStorefront: project.defaultStorefront,
            defaultPlatform: project.defaultPlatform,
            notes: project.notes,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
    }

    static func snapshot(
        _ keyword: KeywordResearchKeyword
    ) -> KeywordResearchKeywordSnapshot {
        KeywordResearchKeywordSnapshot(
            id: keyword.id,
            incarnationID: keyword.incarnationID,
            projectID: keyword.projectID,
            queryKey: keyword.queryKey,
            term: keyword.term,
            storefront: keyword.storefront,
            platform: keyword.platform,
            notes: keyword.notes,
            createdAt: keyword.createdAt,
            updatedAt: keyword.updatedAt
        )
    }
}
