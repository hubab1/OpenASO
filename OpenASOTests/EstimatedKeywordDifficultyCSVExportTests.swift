import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct EstimatedKeywordDifficultyCSVExportTests {
    @Test
    func formatEmitsExactEvidenceContractAndSummaryRowsDeterministically() throws {
        let rankingFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let asOf = rankingFetchedAt.addingTimeInterval(
            EstimatedKeywordDifficultyFreshness.maximumAge
        )
        let estimated = makeSnapshot(
            keyword: "focus timer",
            stateRaw: EstimatedKeywordDifficultyState.estimated.rawValue,
            score: 67,
            confidenceScore: 83,
            confidenceRaw: EstimatedKeywordDifficultyConfidence.medium.rawValue,
            unavailableReasonRaw: nil,
            rankingFetchedAt: rankingFetchedAt,
            fallbackProviderRaw: RankingSource.appStoreWeb.rawValue,
            fallbackCategoryRaw: EstimatedKeywordDifficultyFallbackCategory.response.rawValue,
            fallbackResponseFailureRaw: EstimatedKeywordDifficultyFallbackResponseFailure.pageShapeChanged.rawValue,
            notes: ["Heuristic, evidence", "Uses \"quotes\""],
            resultEvidence: [
                makeEvidence(position: 2, appStoreID: 222, title: "Second"),
                makeEvidence(position: 1, appStoreID: 111, title: "First, Result")
            ]
        )
        let unavailable = makeSnapshot(
            keyword: "zebra planner",
            stateRaw: EstimatedKeywordDifficultyState.unavailable.rawValue,
            score: nil,
            confidenceScore: nil,
            confidenceRaw: nil,
            unavailableReasonRaw: EstimatedKeywordDifficultyUnavailableReason.insufficientResults.rawValue,
            rankingFetchedAt: rankingFetchedAt.addingTimeInterval(60),
            fallbackProviderRaw: nil,
            fallbackCategoryRaw: nil,
            fallbackResponseFailureRaw: nil,
            notes: [],
            resultEvidence: []
        )
        let items = [
            makeItem(keyword: unavailable.keyword, snapshot: unavailable),
            makeItem(keyword: estimated.keyword, snapshot: estimated)
        ]

        let firstCSV = EstimatedKeywordDifficultyCSVFormat.encode(items: items, asOf: asOf)
        let secondCSV = EstimatedKeywordDifficultyCSVFormat.encode(
            items: Array(items.reversed()),
            asOf: asOf
        )
        #expect(firstCSV == secondCSV)

        let table = CSVTable.parse(firstCSV)
        let headers = try #require(table.first)
        #expect(headers == expectedHeaders)
        #expect(headers.count == 48)
        #expect(table.count == 4)
        #expect(table.dropFirst().allSatisfy { $0.count == 48 })

        let firstEvidence = rowDictionary(headers: headers, row: table[1])
        #expect(firstEvidence["OpenASO Export Type"] == EstimatedKeywordDifficultyCSVFormat.evidenceExportType)
        #expect(firstEvidence["App Name"] == "Writer, Pro")
        #expect(firstEvidence["State"] == "estimated")
        #expect(firstEvidence["Estimated Difficulty"] == "67")
        #expect(firstEvidence["Confidence Score"] == "83")
        #expect(firstEvidence["Evidence Position"] == "1")
        #expect(firstEvidence["Evidence App Store Id"] == "111")
        #expect(firstEvidence["Evidence Title"] == "First, Result")
        #expect(firstEvidence["Fallback Provider"] == RankingSource.appStoreWeb.rawValue)
        #expect(firstEvidence["Fallback Category"] == EstimatedKeywordDifficultyFallbackCategory.response.rawValue)
        #expect(firstEvidence["Fallback Response Failure"] == EstimatedKeywordDifficultyFallbackResponseFailure.pageShapeChanged.rawValue)
        #expect(firstEvidence["Stale At"] == CSVTable.string(from: asOf))
        #expect(firstEvidence["Is Stale"] == "true")
        #expect(firstEvidence["Notes JSON"] == "[\"Heuristic, evidence\",\"Uses \\\"quotes\\\"\"]")

        let secondEvidence = rowDictionary(headers: headers, row: table[2])
        #expect(secondEvidence["Evidence Position"] == "2")
        #expect(secondEvidence["Evidence App Store Id"] == "222")

        let summary = rowDictionary(headers: headers, row: table[3])
        #expect(summary["OpenASO Export Type"] == EstimatedKeywordDifficultyCSVFormat.summaryExportType)
        #expect(summary["State"] == "unavailable")
        #expect(summary["Unavailable Reason"] == "insufficientResults")
        #expect(summary["Estimated Difficulty"] == "")
        #expect(summary["Evidence Position"] == "")
        #expect(summary["Notes JSON"] == "[]")
    }

    @Test
    func missingSnapshotExportsOneNonImportableSummaryWithoutFreshnessOrEvidence() throws {
        let item = makeItem(keyword: "uncalculated keyword", snapshot: nil)
        let csv = EstimatedKeywordDifficultyCSVFormat.encode(
            items: [item],
            asOf: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let table = CSVTable.parse(csv)
        let headers = try #require(table.first)
        #expect(table.count == 2)

        let row = rowDictionary(headers: headers, row: table[1])
        #expect(row["OpenASO Export Type"] == EstimatedKeywordDifficultyCSVFormat.summaryExportType)
        #expect(row["State"] == "missing")
        #expect(row["Estimated Difficulty"] == "")
        #expect(row["Ranking Fetched At"] == "")
        #expect(row["Computed At"] == "")
        #expect(row["Stale At"] == "")
        #expect(row["Is Stale"] == "")
        #expect(row["Evidence Position"] == "")
        #expect(row["Evidence App Store Id"] == "")
        #expect(row["Notes JSON"] == "[]")

        #expect(throws: CSVError.missingColumn("Store Domain")) {
            _ = try TrackedKeywordCSVFormat.decode(csv)
        }
    }

    @Test
    func dedicatedExportNeutralizesSpreadsheetFormulaPrefixesInExternalText() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let keyword = "+KEYWORD"
        let snapshot = makeSnapshot(
            keyword: keyword,
            storefront: "=STORE",
            stateRaw: EstimatedKeywordDifficultyState.estimated.rawValue,
            score: 55,
            confidenceScore: 70,
            confidenceRaw: EstimatedKeywordDifficultyConfidence.medium.rawValue,
            unavailableReasonRaw: nil,
            rankingFetchedAt: fetchedAt,
            fallbackProviderRaw: nil,
            fallbackCategoryRaw: nil,
            fallbackResponseFailureRaw: nil,
            notes: [],
            resultEvidence: [
                makeEvidence(
                    position: 1,
                    appStoreID: 111,
                    title: "-TITLE",
                    subtitle: "@SUBTITLE"
                ),
                makeEvidence(
                    position: 2,
                    appStoreID: 222,
                    title: "\tTITLE",
                    subtitle: "\rSUBTITLE"
                ),
                makeEvidence(
                    position: 3,
                    appStoreID: 333,
                    title: "\nTITLE",
                    subtitle: "+SUBTITLE"
                ),
            ]
        )
        let item = EstimatedKeywordDifficultyCSVItem(
            appName: "=APP",
            appStoreID: 123,
            keyword: keyword,
            queryKey: snapshot.queryKey,
            storefront: "gb",
            platformRaw: AppPlatform.iphone.rawValue,
            snapshot: snapshot
        )

        let table = CSVTable.parse(
            EstimatedKeywordDifficultyCSVFormat.encode(items: [item], asOf: fetchedAt)
        )
        let headers = try #require(table.first)
        let first = rowDictionary(headers: headers, row: table[1])
        let second = rowDictionary(headers: headers, row: table[2])
        let third = rowDictionary(headers: headers, row: table[3])

        #expect(first["App Name"] == "'=APP")
        #expect(first["Keyword"] == "'+KEYWORD")
        #expect(first["Query Key"] == "'\(snapshot.queryKey)")
        #expect(first["Storefront"] == "'=STORE")
        #expect(first["Evidence Title"] == "'-TITLE")
        #expect(first["Evidence Subtitle"] == "'@SUBTITLE")
        #expect(second["Evidence Title"] == "'\tTITLE")
        #expect(second["Evidence Subtitle"] == "'\rSUBTITLE")
        #expect(third["Evidence Title"] == "'\nTITLE")
        #expect(third["Evidence Subtitle"] == "'+SUBTITLE")
    }

    @Test
    func exporterUsesBackgroundSnapshotsAndRespectsAppStorefrontPlatformAndSearch() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let selectedApp = TrackedApp(
            appStoreID: 123,
            bundleID: "com.example.selected",
            name: "Selected",
            sellerName: "Example",
            defaultPlatform: .ipad
        )
        let otherApp = TrackedApp(
            appStoreID: 456,
            bundleID: "com.example.other",
            name: "Other",
            sellerName: "Example",
            defaultPlatform: .ipad
        )
        context.insert(selectedApp)
        context.insert(otherApp)

        let matchingTrack = try insertTrack(
            term: "Focus Timer",
            storefront: "gb",
            platform: .ipad,
            app: selectedApp,
            in: context
        )
        _ = try insertTrack(
            term: "Focus Timer US",
            storefront: "us",
            platform: .ipad,
            app: selectedApp,
            in: context
        )
        _ = try insertTrack(
            term: "Focus Timer Mac",
            storefront: "gb",
            platform: .mac,
            app: selectedApp,
            in: context
        )
        _ = try insertTrack(
            term: "Sleep Sounds",
            storefront: "gb",
            platform: .ipad,
            app: selectedApp,
            in: context
        )
        _ = try insertTrack(
            term: "Focus Timer Other App",
            storefront: "gb",
            platform: .ipad,
            app: otherApp,
            in: context
        )
        context.insert(KeywordDailyMetric(
            queryKey: matchingTrack.queryKey,
            keyword: matchingTrack.term,
            storefront: matchingTrack.storefront,
            platform: matchingTrack.platform,
            popularityScore: 80,
            difficultyScore: 99,
            source: .appleAdsPopularity,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        _ = try EstimatedKeywordDifficultyStore.upsert(
            makePayload(for: matchingTrack, score: 25),
            in: context
        )
        try context.save()

        let document = try await AppDetailEstimatedDifficultyCSVExporter.makeDocument(
            appStoreID: selectedApp.appStoreID,
            appName: selectedApp.name,
            selectedStorefrontFilter: .storefront(code: "GB", title: "🇬🇧 United Kingdom"),
            selectedPlatformFilter: .platform(.ipad),
            difficultyFilterRange: 20 ... 30,
            searchText: "focus timer",
            backgroundModelStore: BackgroundModelStore(modelContainer: container),
            asOf: Date(timeIntervalSince1970: 1_700_086_400)
        )

        let table = CSVTable.parse(document.text)
        let headers = try #require(table.first)
        #expect(table.count == 4)
        #expect(!headers.contains("Difficulty"))
        let row = rowDictionary(headers: headers, row: table[1])
        #expect(row["App Id"] == "123")
        #expect(row["Keyword"] == "Focus Timer")
        #expect(row["Storefront"] == "gb")
        #expect(row["Platform"] == "ipad")
        #expect(row["State"] == "estimated")
        #expect(row["Estimated Difficulty"] == "25")
        #expect(row["Estimated Difficulty"] != "99")

        let legacyOnlyRangeDocument = try await AppDetailEstimatedDifficultyCSVExporter.makeDocument(
            appStoreID: selectedApp.appStoreID,
            appName: selectedApp.name,
            selectedStorefrontFilter: .storefront(code: "GB", title: "🇬🇧 United Kingdom"),
            selectedPlatformFilter: .platform(.ipad),
            difficultyFilterRange: 90 ... 100,
            searchText: "focus timer",
            backgroundModelStore: BackgroundModelStore(modelContainer: container),
            asOf: Date(timeIntervalSince1970: 1_700_086_400)
        )
        #expect(CSVTable.parse(legacyOnlyRangeDocument.text).count == 1)
    }

    @Test
    func historyExporterFiltersOnEstimatedDifficultyAndKeepsLegacyDifficultyOutput() throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let app = TrackedApp(
            appStoreID: 123,
            bundleID: "com.example.selected",
            name: "Selected",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        context.insert(app)

        let estimatedTrack = try insertTrack(
            term: "Focus Timer",
            storefront: "gb",
            platform: .iphone,
            app: app,
            in: context
        )
        let missingTrack = try insertTrack(
            term: "Missing Estimate",
            storefront: "gb",
            platform: .iphone,
            app: app,
            in: context
        )
        let unavailableTrack = try insertTrack(
            term: "Unavailable Estimate",
            storefront: "gb",
            platform: .iphone,
            app: app,
            in: context
        )
        addHistory(to: estimatedTrack, in: context)
        addHistory(to: missingTrack, in: context)
        addHistory(to: unavailableTrack, in: context)

        context.insert(KeywordDailyMetric(
            queryKey: estimatedTrack.queryKey,
            keyword: estimatedTrack.term,
            storefront: estimatedTrack.storefront,
            platform: estimatedTrack.platform,
            popularityScore: 80,
            difficultyScore: 99,
            source: .appleAdsPopularity,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        _ = try EstimatedKeywordDifficultyStore.upsert(
            makePayload(for: estimatedTrack, score: 25),
            in: context
        )
        _ = try EstimatedKeywordDifficultyStore.upsert(
            makeUnavailablePayload(for: unavailableTrack),
            in: context
        )
        try context.save()

        var workspaceState = KeywordWorkspaceState()
        workspaceState.selectedDateRange = .allTime
        workspaceState.difficultyFilterRange = 20 ... 30
        let narrowedDocument = try AppDetailView.KeywordHistoryCSVExporter.makeDocument(
            tracks: [estimatedTrack, missingTrack, unavailableTrack],
            appName: app.name,
            appStoreID: app.appStoreID,
            selectedStorefrontFilter: .all,
            workspaceState: workspaceState,
            searchText: "",
            modelContext: context,
            storefrontTitle: { $0.uppercased() }
        )

        let narrowedTable = CSVTable.parse(narrowedDocument.text)
        let headers = try #require(narrowedTable.first)
        #expect(narrowedTable.count == 3)
        #expect(headers.contains("Difficulty"))
        #expect(!headers.contains("Estimated Difficulty"))
        for row in narrowedTable.dropFirst() {
            let values = rowDictionary(headers: headers, row: row)
            #expect(values["Keyword"] == estimatedTrack.term)
            #expect(values["Difficulty"] == "99")
        }

        workspaceState.difficultyFilterRange = MetricFilterRange.difficulty.defaultRange
        let defaultDocument = try AppDetailView.KeywordHistoryCSVExporter.makeDocument(
            tracks: [estimatedTrack, missingTrack, unavailableTrack],
            appName: app.name,
            appStoreID: app.appStoreID,
            selectedStorefrontFilter: .all,
            workspaceState: workspaceState,
            searchText: "",
            modelContext: context,
            storefrontTitle: { $0.uppercased() }
        )
        let defaultTable = CSVTable.parse(defaultDocument.text)
        #expect(defaultTable.count == 7)
        #expect(Set(defaultTable.dropFirst().compactMap { row in
            rowDictionary(headers: headers, row: row)["Keyword"]
        }) == Set([estimatedTrack.term, missingTrack.term, unavailableTrack.term]))
    }

    private var expectedHeaders: [String] {
        [
            "OpenASO Export Type",
            "App Name",
            "App Id",
            "Keyword",
            "Query Key",
            "Storefront",
            "Platform",
            "State",
            "Estimated Difficulty",
            "Confidence Score",
            "Confidence",
            "Unavailable Reason",
            "Estimation Source",
            "Algorithm Identifier",
            "Algorithm Version",
            "Requested Result Limit",
            "Provider Result Count",
            "Considered Result Count",
            "Rated Result Count",
            "Weighted Rating Coverage Percentage",
            "Maximum Rating Count",
            "Median Rating Count",
            "Rating Authority Score",
            "Metadata Saturation Score",
            "Exact Title Phrase Match Count",
            "Exact Subtitle Phrase Match Count",
            "Ranking Source",
            "Ranking Fetched At",
            "Computed At",
            "Stale At",
            "Is Stale",
            "Fallback Provider",
            "Fallback Category",
            "Fallback Transport Code",
            "Fallback HTTP Status",
            "Fallback Response Failure",
            "Notes JSON",
            "Evidence Position",
            "Evidence App Store Id",
            "Evidence Title",
            "Evidence Subtitle",
            "Evidence Rating Count",
            "Evidence Rating Authority Score",
            "Evidence Title Token Coverage Percentage",
            "Evidence Combined Token Coverage Percentage",
            "Evidence Metadata Match Score",
            "Evidence Exact Title Phrase Match",
            "Evidence Exact Subtitle Phrase Match"
        ]
    }

    private func makeItem(
        keyword: String,
        snapshot: EstimatedKeywordDifficultySnapshot?
    ) -> EstimatedKeywordDifficultyCSVItem {
        EstimatedKeywordDifficultyCSVItem(
            appName: "Writer, Pro",
            appStoreID: 123,
            keyword: keyword,
            queryKey: KeywordQuery.makeQueryKey(
                term: keyword,
                storefront: "gb",
                platform: .iphone
            ),
            storefront: "gb",
            platformRaw: AppPlatform.iphone.rawValue,
            snapshot: snapshot
        )
    }

    private func makeSnapshot(
        keyword: String,
        storefront: String = "gb",
        stateRaw: String,
        score: Int?,
        confidenceScore: Int?,
        confidenceRaw: String?,
        unavailableReasonRaw: String?,
        rankingFetchedAt: Date,
        fallbackProviderRaw: String?,
        fallbackCategoryRaw: String?,
        fallbackResponseFailureRaw: String?,
        notes: [String],
        resultEvidence: [EstimatedKeywordDifficultyResultEvidence]
    ) -> EstimatedKeywordDifficultySnapshot {
        EstimatedKeywordDifficultySnapshot(
            queryKey: KeywordQuery.makeQueryKey(
                term: keyword,
                storefront: storefront,
                platform: .iphone
            ),
            calculationID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32)),
            keyword: keyword,
            storefront: storefront,
            platformRaw: AppPlatform.iphone.rawValue,
            stateRaw: stateRaw,
            score: score,
            confidenceScore: confidenceScore,
            confidenceRaw: confidenceRaw,
            unavailableReasonRaw: unavailableReasonRaw,
            estimationSourceRaw: EstimatedKeywordDifficultySource.topResultsHeuristic.rawValue,
            algorithmIdentifier: "top10-authority-saturation",
            algorithmVersion: 1,
            requestedResultLimit: 10,
            providerResultCount: 8,
            consideredResultCount: resultEvidence.count,
            ratedResultCount: resultEvidence.count,
            weightedRatingCoveragePercentage: resultEvidence.isEmpty ? 0 : 100,
            maximumRatingCount: resultEvidence.compactMap(\.ratingCount).max(),
            medianRatingCount: resultEvidence.isEmpty ? nil : 150,
            ratingAuthorityScore: resultEvidence.isEmpty ? nil : 62,
            metadataSaturationScore: resultEvidence.isEmpty ? nil : 71,
            exactTitlePhraseMatchCount: resultEvidence.count(where: \.exactTitlePhraseMatch),
            exactSubtitlePhraseMatchCount: resultEvidence.count(where: \.exactSubtitlePhraseMatch),
            rankingSourceRaw: RankingSource.iTunesFallback.rawValue,
            rankingFetchedAt: rankingFetchedAt,
            computedAt: rankingFetchedAt.addingTimeInterval(30),
            fallbackProviderRaw: fallbackProviderRaw,
            fallbackCategoryRaw: fallbackCategoryRaw,
            fallbackTransportCode: nil,
            fallbackHTTPStatus: nil,
            fallbackResponseFailureRaw: fallbackResponseFailureRaw,
            notes: notes,
            resultEvidence: resultEvidence
        )
    }

    private func makeEvidence(
        position: Int,
        appStoreID: Int64,
        title: String,
        subtitle: String? = nil
    ) -> EstimatedKeywordDifficultyResultEvidence {
        EstimatedKeywordDifficultyResultEvidence(
            position: position,
            appStoreID: appStoreID,
            title: title,
            subtitle: subtitle ?? "Subtitle \(position)",
            ratingCount: position * 100,
            ratingAuthorityScore: 40 + position,
            titleTokenCoveragePercentage: 80 + position,
            combinedTokenCoveragePercentage: 85 + position,
            metadataMatchScore: 70 + position,
            exactTitlePhraseMatch: position == 1,
            exactSubtitlePhraseMatch: position == 2
        )
    }

    private func makePayload(
        for track: TrackedAppKeyword,
        score: Int
    ) -> EstimatedKeywordDifficultyPersistencePayload {
        let evidence: [EstimatedKeywordDifficultyResultEvidence] = [
            makeEvidence(position: 1, appStoreID: 10_001, title: "Focus Result 1"),
            makeEvidence(position: 2, appStoreID: 10_002, title: "Focus Result 2"),
            makeEvidence(position: 3, appStoreID: 10_003, title: "Focus Result 3")
        ]
        let rankingFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return EstimatedKeywordDifficultyPersistencePayload(
            queryKey: track.queryKey,
            calculationID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 33)),
            keyword: track.term,
            storefront: track.storefront,
            platform: track.platform,
            result: .estimated(
                score: score,
                confidenceScore: 80,
                confidence: .medium
            ),
            algorithmIdentifier: "top10-authority-saturation",
            algorithmVersion: 1,
            requestedResultLimit: 10,
            providerResultCount: 3,
            evidence: EstimatedKeywordDifficultyEvidence(
                consideredResultCount: 3,
                ratedResultCount: 3,
                weightedRatingCoveragePercentage: 100,
                maximumRatingCount: 300,
                medianRatingCount: 200,
                ratingAuthorityScore: 62,
                metadataSaturationScore: 71,
                resultEvidence: evidence
            ),
            rankingSource: .appStoreWeb,
            rankingFetchedAt: rankingFetchedAt,
            computedAt: rankingFetchedAt.addingTimeInterval(30),
            notes: ["Estimated from current ranking evidence."]
        )
    }

    private func makeUnavailablePayload(
        for track: TrackedAppKeyword
    ) -> EstimatedKeywordDifficultyPersistencePayload {
        let rankingFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return EstimatedKeywordDifficultyPersistencePayload(
            queryKey: track.queryKey,
            calculationID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 34)),
            keyword: track.term,
            storefront: track.storefront,
            platform: track.platform,
            result: .unavailable(reason: .insufficientResults),
            algorithmIdentifier: "top10-authority-saturation",
            algorithmVersion: 1,
            requestedResultLimit: 10,
            providerResultCount: 0,
            evidence: EstimatedKeywordDifficultyEvidence(
                consideredResultCount: 0,
                ratedResultCount: 0,
                weightedRatingCoveragePercentage: 0,
                maximumRatingCount: nil,
                medianRatingCount: nil,
                ratingAuthorityScore: nil,
                metadataSaturationScore: nil,
                resultEvidence: []
            ),
            rankingSource: .appStoreWeb,
            rankingFetchedAt: rankingFetchedAt,
            computedAt: rankingFetchedAt.addingTimeInterval(30),
            notes: ["Estimate unavailable from current ranking evidence."]
        )
    }

    private func addHistory(
        to track: TrackedAppKeyword,
        in context: ModelContext
    ) {
        let older = TrackedKeywordDailyRanking(
            rank: 8,
            searchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .appStoreWeb,
            resultCount: 10,
            keywordTrack: track
        )
        let newer = TrackedKeywordDailyRanking(
            rank: 5,
            searchedAt: Date(timeIntervalSince1970: 1_700_086_400),
            source: .appStoreWeb,
            resultCount: 10,
            keywordTrack: track
        )
        track.snapshots.append(contentsOf: [older, newer])
        context.insert(older)
        context.insert(newer)
    }

    private func insertTrack(
        term: String,
        storefront: String,
        platform: AppPlatform,
        app: TrackedApp,
        in modelContext: ModelContext
    ) throws -> TrackedAppKeyword {
        let query = try KeywordQuery.fetchOrInsert(
            term: term,
            storefront: storefront,
            platform: platform,
            in: modelContext
        )
        let track = TrackedAppKeyword(
            term: term,
            storefront: storefront,
            platform: platform,
            trackedApp: app,
            query: query
        )
        app.keywordTracks.append(track)
        modelContext.insert(track)
        return track
    }

    private func rowDictionary(headers: [String], row: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.enumerated().map { index, header in
            (header, row.indices.contains(index) ? row[index] : "")
        })
    }
}
