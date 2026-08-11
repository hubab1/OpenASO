import Foundation
import SwiftData
@testable import OpenASO

let testDate = Date(timeIntervalSinceReferenceDate: 807_000_000)

func makeRankingFact(
    position: Int,
    appStoreID: Int64,
    bundleID: String?,
    name: String,
    subtitle: String? = nil,
    sellerName: String?,
    observation: RankingCrawlRecord,
    in modelContext: ModelContext
) -> RankingFact {
    let payload = RankingAppRevisionPayload(
        appStoreID: appStoreID,
        bundleID: bundleID,
        name: name,
        subtitle: subtitle,
        sellerName: sellerName
    )
    let revision = try! RankingAppRevisionStore.revisions(
        for: [payload],
        in: modelContext
    )[payload.revisionKey]!
    return RankingFact(
        position: position,
        appStoreID: appStoreID,
        revision: revision,
        observation: observation
    )
}

struct PageCall: Equatable, Sendable {
    let offset: Int
    let limit: Int
}

struct SecretTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []

    func record(_ value: Value) {
        values.append(value)
    }
}

actor ControlledOperation<Value: Sendable> {
    private var continuations: [CheckedContinuation<Value, any Error>] = []
    private var callCountWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private(set) var callCount = 0

    func call() async throws -> Value {
        callCount += 1
        resumeSatisfiedWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCallCount(_ expectedCount: Int) async {
        guard callCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((expectedCount, continuation))
        }
    }

    func succeed(at index: Int, with value: Value) {
        continuations.remove(at: index).resume(returning: value)
    }

    func fail(at index: Int, with error: any Error) {
        continuations.remove(at: index).resume(throwing: error)
    }

    private func resumeSatisfiedWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in callCountWaiters {
            if callCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        callCountWaiters = pending
    }
}

extension KeywordResearchMetricsIssueCode {
    static let allPresentationTestCases: [Self] = [
        .missingContextApp,
        .missingSession,
        .reconnectRequired,
        .sessionExpired,
        .configurationChanged,
        .unsupportedStorefront,
        .rateLimited,
        .providerFailure,
    ]
}

func makeProject(
    id: UUID = UUID(),
    incarnationID: UUID = UUID(),
    name: String = "Project",
    createdAt: Date = testDate,
    updatedAt: Date = testDate
) -> KeywordResearchProjectSnapshot {
    KeywordResearchProjectSnapshot(
        id: id,
        incarnationID: incarnationID,
        name: name,
        bundleID: nil,
        defaultStorefront: "us",
        defaultPlatform: .iphone,
        notes: "",
        createdAt: createdAt,
        updatedAt: updatedAt
    )
}

func makeKeyword(
    id: UUID = UUID(),
    incarnationID: UUID = UUID(),
    project: KeywordResearchProjectSnapshot,
    term: String = "keyword",
    createdAt: Date = testDate,
    updatedAt: Date = testDate
) -> KeywordResearchKeywordSnapshot {
    KeywordResearchKeywordSnapshot(
        id: id,
        incarnationID: incarnationID,
        projectID: project.id,
        queryKey: KeywordQuery.makeQueryKey(
            term: term,
            storefront: "us",
            platform: .iphone
        ),
        term: term,
        storefront: "us",
        platform: .iphone,
        notes: "",
        createdAt: createdAt,
        updatedAt: updatedAt
    )
}

func makeObservation(
    project: KeywordResearchProjectSnapshot,
    keyword: KeywordResearchKeywordSnapshot,
    id: String = UUID().uuidString,
    observedAt: Date = testDate
) -> KeywordResearchRankingObservationSnapshot {
    KeywordResearchRankingObservationSnapshot(
        id: id,
        projectGeneration: project.generation,
        keywordGeneration: keyword.generation,
        queryKey: keyword.queryKey,
        term: keyword.term,
        storefront: keyword.storefront,
        platform: keyword.platform,
        observedAt: observedAt,
        observedHour: 12,
        source: .appStoreWeb,
        resultCount: 2,
        submissionCount: 1,
        winningCount: 1,
        confidence: "high",
        items: []
    )
}

func makeMetric(
    project: KeywordResearchProjectSnapshot,
    keyword: KeywordResearchKeywordSnapshot,
    score: Int?,
    issue: KeywordResearchMetricsIssue? = nil
) -> KeywordResearchMetricsOutcome {
    KeywordResearchMetricsOutcome(
        projectGeneration: project.generation,
        keywordGeneration: keyword.generation,
        queryKey: keyword.queryKey,
        term: keyword.term,
        storefront: keyword.storefront,
        platform: keyword.platform,
        popularityScore: score,
        observedAt: testDate,
        provenance: .sharedCacheContextUnknown,
        disposition: issue == nil ? .refreshed : .staleCacheFallback,
        issue: issue
    )
}
