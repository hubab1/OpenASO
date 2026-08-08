import Foundation

enum KeywordWorkspaceProjection {
    struct MaterializationID: Hashable, Sendable {
        struct TrackIdentity: Hashable, Sendable {
            let identityKey: String
        }

        let refreshToken: Int
        let backgroundStoreRevision: Int
        let appStoreID: Int64
        let storefrontFilterID: String
        let platformFilterID: String
        let dateRangeID: String
        let tracks: [TrackIdentity]
    }

    struct Filters: Hashable, Sendable {
        let searchText: String
        let popularityRange: ClosedRange<Double>
        let difficultyRange: ClosedRange<Double>
        let positionRange: ClosedRange<Double>
        let changeRange: ClosedRange<Double>
        let showsOnlyChangedKeywords: Bool
    }

    struct FilterID: Hashable, Sendable {
        let materializationGeneration: Int
        let filters: Filters
    }

    static func orderedRows(_ rows: [KeywordWorkspaceRow]) -> [KeywordWorkspaceRow] {
        rows.sorted { lhs, rhs in
            switch (lhs.currentRank, rhs.currentRank) {
            case let (left?, right?):
                if left != right {
                    return left < right
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }

            let termComparison = lhs.track.term.localizedCaseInsensitiveCompare(rhs.track.term)
            if termComparison != .orderedSame {
                return termComparison == .orderedAscending
            }

            return lhs.track.identityKey < rhs.track.identityKey
        }
    }

    static func filteredRows(
        _ rows: [KeywordWorkspaceRow],
        filters: Filters
    ) -> [KeywordWorkspaceRow] {
        let searchText = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return rows.filter { row in
            matchesSearch(row, searchText: searchText)
                && matches(row.metrics?.popularityScore, in: filters.popularityRange, configuration: .popularity)
                && matches(row.metrics?.difficultyScore, in: filters.difficultyRange, configuration: .difficulty)
                && matches(row.currentRank, in: filters.positionRange, configuration: .position)
                && matches(row.trendDelta, in: filters.changeRange, configuration: .change)
                && (!filters.showsOnlyChangedKeywords || row.trendDelta.map { $0 != 0 } == true)
        }
    }

    @MainActor
    static func debouncedRows(
        _ rows: [KeywordWorkspaceRow],
        filters: Filters,
        delay: Duration = .milliseconds(150)
    ) async throws -> [KeywordWorkspaceRow] {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        return filteredRows(rows, filters: filters)
    }

    private static func matchesSearch(_ row: KeywordWorkspaceRow, searchText: String) -> Bool {
        searchText.isEmpty || row.track.term.localizedStandardContains(searchText)
    }

    private static func matches(
        _ value: Int?,
        in range: ClosedRange<Double>,
        configuration: MetricFilterRange
    ) -> Bool {
        if configuration.isDefault(range) {
            return true
        }

        guard let value else {
            return false
        }

        return range.contains(Double(value))
    }
}
