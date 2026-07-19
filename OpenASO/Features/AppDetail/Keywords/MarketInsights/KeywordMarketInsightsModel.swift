import Observation

@Observable
@MainActor
final class KeywordMarketInsightsModel {
    struct Snapshot: Equatable, Sendable {
        let scope: KeywordMarketInsightsViewScope
        let items: [KeywordMarketInsight]
        let rows: [KeywordMarketInsightsPresentation.KeywordRow]
        let nextCursor: String?
        let partialReasons: [KeywordMarketInsightsPartialReason]
        let staleMarketCount: Int
        let returnedMarketEvidenceCount: Int

        init(
            page: KeywordMarketInsightsPage,
            scope: KeywordMarketInsightsViewScope
        ) {
            self.scope = scope
            self.items = page.items
            self.rows = KeywordMarketInsightsPresentation(items: page.items).rows
            self.nextCursor = page.nextCursor
            self.partialReasons = page.partialReasons
            self.staleMarketCount = page.staleMarketCount
            self.returnedMarketEvidenceCount = page.returnedMarketEvidenceCount
        }

        func appending(_ page: KeywordMarketInsightsPage) -> Snapshot {
            var itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            var orderedIDs = items.map(\.id)
            for item in page.items {
                if itemsByID[item.id] == nil {
                    orderedIDs.append(item.id)
                }
                itemsByID[item.id] = item
            }

            let reasons = Set(partialReasons).union(page.partialReasons)
            return Snapshot(
                scope: scope,
                items: orderedIDs.compactMap { itemsByID[$0] },
                nextCursor: page.nextCursor,
                partialReasons: reasons.sorted { $0.rawValue < $1.rawValue },
                staleMarketCount: staleMarketCount + page.staleMarketCount,
                returnedMarketEvidenceCount:
                    returnedMarketEvidenceCount + page.returnedMarketEvidenceCount
            )
        }

        private init(
            scope: KeywordMarketInsightsViewScope,
            items: [KeywordMarketInsight],
            nextCursor: String?,
            partialReasons: [KeywordMarketInsightsPartialReason],
            staleMarketCount: Int,
            returnedMarketEvidenceCount: Int
        ) {
            self.scope = scope
            self.items = items
            self.rows = KeywordMarketInsightsPresentation(items: items).rows
            self.nextCursor = nextCursor
            self.partialReasons = partialReasons
            self.staleMarketCount = staleMarketCount
            self.returnedMarketEvidenceCount = returnedMarketEvidenceCount
        }
    }

    enum State: Equatable, Sendable {
        case idle
        case loading(previous: Snapshot?)
        case loaded(Snapshot)
        case failed(message: String, previous: Snapshot?)
    }

    private(set) var state: State = .idle
    private(set) var isLoadingNextPage = false
    private(set) var paginationErrorMessage: String?
    @ObservationIgnored private var requestGeneration = 0

    var snapshot: Snapshot? {
        switch state {
        case .idle:
            nil
        case .loading(let previous), .failed(_, let previous):
            previous
        case .loaded(let snapshot):
            snapshot
        }
    }

    var items: [KeywordMarketInsight] {
        snapshot?.items ?? []
    }

    var errorMessage: String? {
        guard case let .failed(message, _) = state else { return nil }
        return message
    }

    var isLoading: Bool {
        guard case .loading = state else { return false }
        return true
    }

    var canLoadNextPage: Bool {
        guard case let .loaded(snapshot) = state else { return false }
        return snapshot.nextCursor != nil && !isLoadingNextPage
    }

    func load(
        scope: KeywordMarketInsightsViewScope,
        using dataSource: KeywordMarketInsightsDataSource
    ) async {
        guard !Task.isCancelled else { return }

        requestGeneration &+= 1
        let generation = requestGeneration
        let previous = snapshot?.scope == scope ? snapshot : nil
        state = .loading(previous: previous)
        isLoadingNextPage = false
        paginationErrorMessage = nil

        do {
            let page = try await dataSource.load(scope: scope, cursor: nil)
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            state = .loaded(Snapshot(page: page, scope: scope))
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            restore(previous)
        } catch {
            guard generation == requestGeneration else { return }
            guard !Task.isCancelled else {
                restore(previous)
                return
            }
            state = .failed(
                message: OpenASOError.map(error).localizedDescription,
                previous: previous
            )
        }
    }

    func loadNextPage(using dataSource: KeywordMarketInsightsDataSource) async {
        guard
            !Task.isCancelled,
            !isLoadingNextPage,
            case let .loaded(previous) = state,
            let cursor = previous.nextCursor
        else {
            return
        }

        requestGeneration &+= 1
        let generation = requestGeneration
        isLoadingNextPage = true
        paginationErrorMessage = nil

        do {
            let page = try await dataSource.load(
                scope: previous.scope,
                cursor: cursor
            )
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            state = .loaded(previous.appending(page))
            isLoadingNextPage = false
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            isLoadingNextPage = false
        } catch {
            guard generation == requestGeneration else { return }
            isLoadingNextPage = false
            guard !Task.isCancelled else { return }
            paginationErrorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    private func restore(_ previous: Snapshot?) {
        if let previous {
            state = .loaded(previous)
        } else {
            state = .idle
        }
    }
}
