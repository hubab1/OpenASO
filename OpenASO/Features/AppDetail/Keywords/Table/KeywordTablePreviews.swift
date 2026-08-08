import SwiftData
import SwiftUI

#Preview("Preview Fixtures") {
    KeywordTableCellsPreview()
}

struct KeywordTableCellsPreview: View {
    private let preview = KeywordTablePreview()

    var body: some View {
        let rows = preview.rows
        VStack(alignment: .leading, spacing: 14) {
            if let row = rows.first {
                previewRow("Keyword") {
                    KeywordCell(row: row)
                }
                previewRow("Last Updated") {
                    KeywordLastUpdatedCell(row: row)
                }
                previewRow("Country") {
                    KeywordStoreCell(row: row)
                }
                previewRow("Popularity") {
                    KeywordPopularityCell(row: row) {}
                }
                previewRow("Position") {
                    KeywordPositionCell(row: row)
                }
                previewRow("Trend") {
                    KeywordTrendCell(row: row)
                }
                previewRow("Apps in Ranking") {
                    AppsInRankingCell(
                        row: row,
                        trackedAppStoreID: preview.trackedAppStoreID,
                        modelContext: preview.previewContainer.modelContainer.mainContext,
                        appCatalogService: preview.services.appCatalogService,
                        appIconStore: preview.services.appIconStore
                    )
                }
                if let rankingApp = row.rankingApps.first {
                    previewRow("Icon Wrapper") {
                        AppIconView(
                            appStoreID: rankingApp.appStoreID,
                            storefrontCode: row.track.storefront,
                            size: 24,
                            cornerRadius: 6
                        )
                    }
                    previewRow("Icon Explicit") {
                        AppIconImageView(
                            appStoreID: rankingApp.appStoreID,
                            storefrontCode: row.track.storefront,
                            size: 24,
                            cornerRadius: 6,
                            modelContext: preview.previewContainer.modelContainer.mainContext,
                            appCatalogService: preview.services.appCatalogService,
                            appIconStore: preview.services.appIconStore
                        )
                    }
                }
                previewRow("Notes") {
                    KeywordNotesCell(row: row) {}
                }
            }

            if let statusRow = rows.first(where: { $0.statusMessage != nil }) {
                previewRow("Status") {
                    KeywordStatusCell(row: statusRow) {}
                }
            }
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
        .openASOPreviewEnvironment(preview.previewContainer)
    }

    private func previewRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct KeywordTableNotesPreview: View {
    private let preview = KeywordTablePreview()

    var body: some View {
        if let row = preview.rows.first {
            KeywordNotesSheet(track: row.track)
                .openASOPreviewEnvironment(preview.previewContainer)
        }
    }
}

struct KeywordTableSupportPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                MetricBarView(value: 82, maxValue: 100, colorScale: .lowRedHighGreen, placeholder: "-")
                MetricBarView(value: 79, maxValue: 100, colorScale: .lowGreenHighRed, placeholder: "-")
                MetricBarView(value: nil, maxValue: 100, colorScale: .lowRedHighGreen, placeholder: "-")
            }

            HStack(spacing: 14) {
                RankingPositionBadge(rank: 1, hasSnapshot: true)
                RankingPositionBadge(rank: 2, hasSnapshot: true)
                RankingPositionBadge(rank: 3, hasSnapshot: true)
                RankingPositionBadge(rank: 12, hasSnapshot: true)
            }

            Text("flight tracker".highlightingMatches(of: "flight"))
                .font(.headline)
        }
        .padding(24)
        .frame(width: 380, alignment: .leading)
    }
}

enum KeywordRankingListPreviewFixtures {
    static func seed(in modelContext: ModelContext) -> (row: KeywordWorkspaceRow, trackedAppStoreID: Int64) {
        makeSeed(in: modelContext, includesRankingApps: true)
    }

    static func seedEmptyRanking(in modelContext: ModelContext) -> (row: KeywordWorkspaceRow, trackedAppStoreID: Int64) {
        makeSeed(in: modelContext, includesRankingApps: false)
    }

    private static func makeSeed(
        in modelContext: ModelContext,
        includesRankingApps: Bool
    ) -> (row: KeywordWorkspaceRow, trackedAppStoreID: Int64) {
        let trackedApp = TrackedApp(
            appStoreID: 1358823008,
            bundleID: "com.flightyapp.flighty",
            name: "Flighty - Live Flight Tracker",
            subtitle: "World's Fastest Delay Alerts",
            sellerName: "Flighty LLC",
            defaultPlatform: .iphone
        )
        let storefront = Storefront(code: "us", name: "United States", flagEmoji: "US", languageCode: "en")
        let query = try! KeywordQuery.fetchOrInsert(
            term: "flight tracker",
            storefront: storefront.code,
            platform: .iphone,
            in: modelContext
        )
        let track = TrackedAppKeyword(
            term: "flight tracker",
            storefront: storefront.code,
            platform: .iphone,
            trackedApp: trackedApp,
            query: query
        )
        track.notes = "High intent keyword from the Flighty import."
        track.rankingAppCount = includesRankingApps ? 164 : 0

        let metrics = KeywordDailyMetric(
            queryKey: track.queryKey,
            keyword: track.term,
            storefront: track.storefront,
            platform: track.platform,
            popularityScore: 82,
            difficultyScore: 79,
            source: .appleAdsPopularity
        )
        let trendSnapshots = [
            TrackedKeywordDailyRanking(rank: 12, searchedAt: Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now, source: .iTunesFallback, resultCount: 151, keywordTrack: track),
            TrackedKeywordDailyRanking(rank: 8, searchedAt: Calendar.current.date(byAdding: .day, value: -4, to: .now) ?? .now, source: .iTunesFallback, resultCount: 158, keywordTrack: track),
            TrackedKeywordDailyRanking(
                rank: includesRankingApps ? 5 : nil,
                searchedAt: Calendar.current.date(byAdding: .hour, value: -2, to: .now) ?? .now,
                source: .iTunesFallback,
                resultCount: includesRankingApps ? 164 : 0,
                keywordTrack: track
            )
        ]
        let snapshot = trendSnapshots[2]

        modelContext.insert(trackedApp)
        modelContext.insert(storefront)
        modelContext.insert(track)
        modelContext.insert(metrics)
        trackedApp.keywordTracks.append(track)
        trendSnapshots.forEach {
            modelContext.insert($0)
            track.snapshots.append($0)
        }

        let calendar = Calendar.current

        if includesRankingApps {
            flightTrackerApps.forEach { app in
                let releaseDate = calendar.date(byAdding: .day, value: -(4_200 - app.position * 145), to: .now)
                let currentVersionReleaseDate = calendar.date(byAdding: .day, value: -app.position * 4, to: .now)
                let storeApp = StoreApp(
                    appStoreID: app.appStoreID,
                    bundleID: app.bundleID,
                    name: app.name,
                    subtitle: app.subtitle,
                    sellerName: app.sellerName,
                    iconURLString: app.iconURLString,
                    releaseDate: releaseDate,
                    currentVersionReleaseDate: currentVersionReleaseDate,
                    version: "8.\(app.position).0",
                    defaultPlatform: .iphone
                )
                let result = TrackedKeywordRankedResult(
                    position: app.position,
                    appStoreID: app.appStoreID,
                    bundleID: app.bundleID,
                    name: app.name,
                    subtitle: app.subtitle,
                    sellerName: app.sellerName,
                    snapshot: snapshot
                )
                modelContext.insert(storeApp)
                modelContext.insert(result)
                seedRatingsHistory(
                    for: storeApp,
                    storefront: storefront.code,
                    position: app.position,
                    state: ratingHistoryState(for: app.position),
                    in: modelContext
                )
                snapshot.topResults.append(result)
            }
        }

        try? modelContext.save()

        let storefrontDefinition = StorefrontDefinition(
            code: storefront.code,
            name: storefront.name,
            flagEmoji: storefront.flagEmoji,
            title: storefront.title
        )
        let row = KeywordWorkspaceRow(
            track: track,
            storefront: storefrontDefinition,
            metrics: metrics,
            latestSnapshot: snapshot,
            trendSnapshots: trendSnapshots,
            rankingApps: snapshot.sortedTopResults
        )
        return (row, trackedApp.appStoreID)
    }

    private static func ratingHistoryState(for position: Int) -> RatingHistoryPreviewState {
        switch position {
        case 2:
            return .none
        case 4:
            return .partial
        default:
            return .full
        }
    }

    private enum RatingHistoryPreviewState {
        case full
        case partial
        case none
    }

    private static let flightTrackerApps: [PreviewRankingApp] = [
        PreviewRankingApp(position: 1, appStoreID: 382233851, bundleID: "com.flightradar24free", name: "Flightradar24 | Flight Tracker", subtitle: "Live plane tracking and flight status", sellerName: "Flightradar24 AB", iconURLString: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/17/b6/1a/17b61adf-2c94-6ba0-e6bb-cc4f3dd14a10/AppIcon-0-0-1x_U007epad-0-1-0-85-220.png/100x100bb.jpg"),
        PreviewRankingApp(position: 2, appStoreID: 533365777, bundleID: "com.impalastudios.flighttracker", name: "Flight Tracker +", subtitle: "Flight delays, gates and airport boards", sellerName: "Impala Studios B.V.", iconURLString: "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/0e/ce/7b/0ece7b19-c792-442f-c56b-e68aad277ac2/tft_appicon_2025-0-0-1x_U007epad-0-1-0-0-sRGB-0-0-85-220.png/100x100bb.jpg"),
        PreviewRankingApp(position: 3, appStoreID: 316793974, bundleID: "com.flightaware.flightaware-free", name: "FlightAware Flight Tracker", subtitle: "Real-time flight status and maps", sellerName: "FlightAware", iconURLString: "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/68/28/a7/6828a705-344b-01c3-2aeb-13d940c1a24f/AppIcon-0-0-1x_U007emarketing-0-11-0-85-220.png/100x100bb.jpg"),
        PreviewRankingApp(position: 4, appStoreID: 399057337, bundleID: "com.flightview.flightview", name: "Flightview - Flight Tracker", subtitle: "Real-time flight information", sellerName: "FlightView Inc.", iconURLString: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/bd/10/97/bd109740-028f-f064-a33f-cd3db97072f9/AppIcon-0-0-1x_U007epad-0-1-85-220.png/100x100bb.jpg"),
        PreviewRankingApp(position: 5, appStoreID: 1358823008, bundleID: "com.flightyapp.flighty", name: "Flighty - Live Flight Tracker", subtitle: "World's Fastest Delay Alerts", sellerName: "Flighty LLC", iconURLString: "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/af/2c/83/af2c83ad-92c0-7ab7-9e47-80e71479bd96/AppIcon-0-1x_U007epad-0-1-0-sRGB-85-220-0.png/100x100bb.jpg"),
        PreviewRankingApp(position: 6, appStoreID: 572700574, bundleID: "com.conducivetech.flightstats", name: "FlightStats", subtitle: "Flight status and airport tracking", sellerName: "LNRS Data Services Limited", iconURLString: "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/cc/c9/76/ccc976ef-5581-2d2a-947a-840fe8c11845/AppIcon-0-0-1x_U007emarketing-0-7-0-0-85-220.png/100x100bb.jpg"),
        PreviewRankingApp(position: 7, appStoreID: 361273585, bundleID: "com.pinkfroot.planefinderfree", name: "Plane Finder - Flight Tracker", subtitle: "Live air traffic in a map view", sellerName: "pinkfroot limited", iconURLString: "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/7d/24/12/7d24120c-3f6c-d5df-adda-1c6a9d15271e/AppLiveIcon-0-1x_U007epad-0-1-0-0-sRGB-GLES2_U002c0-512MB-85-220-0.png/100x100bb.jpg"),
        PreviewRankingApp(position: 8, appStoreID: 1097815000, bundleID: "com.apalonapps.radarfree", name: "Planes Live - Flight Tracker", subtitle: "Worldwide plane tracking and alerts", sellerName: "Mosaic S.r.l.", iconURLString: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/b2/30/cc/b230cc6a-7ce9-338a-d65e-c0c05ee0b76b/AppIcon-0-0-1x_U007emarketing-0-8-0-0-85-220.png/100x100bb.jpg")
    ]

    private struct PreviewRankingApp {
        let position: Int
        let appStoreID: Int64
        let bundleID: String
        let name: String
        let subtitle: String
        let sellerName: String
        let iconURLString: String
    }

    private static func seedRatingsHistory(
        for storeApp: StoreApp,
        storefront: String,
        position: Int,
        state: RatingHistoryPreviewState,
        in modelContext: ModelContext
    ) {
        let calendar = Calendar.current
        let baseRatingCount = 620_000 - (position * 41_000)
        let averageRating = max(3.8, 4.82 - (Double(position) * 0.05))
        var ratingCount = baseRatingCount

        let startingDayOffset: Int
        switch state {
        case .full:
            startingDayOffset = 31
        case .partial:
            startingDayOffset = 8
        case .none:
            startingDayOffset = -1
        }

        if startingDayOffset >= 0 {
            for dayOffset in stride(from: startingDayOffset, through: 0, by: -1) {
                let date = calendar.date(byAdding: .day, value: -dayOffset, to: .now) ?? .now
                let dayIndex = startingDayOffset - dayOffset
                let dailyGrowth = previewRatingGrowth(position: position, dayIndex: dayIndex)
                ratingCount += dailyGrowth

                let snapshot = AppDailyRating(
                    appStoreID: storeApp.appStoreID,
                    storefront: storefront,
                    ratingCount: ratingCount,
                    averageRating: averageRating,
                    ratingDate: LatestAppRating.utcDayString(for: date),
                    observedAt: date,
                    source: .iTunesSearch,
                    storeApp: storeApp
                )
                modelContext.insert(snapshot)
                storeApp.ratingSnapshots.append(snapshot)
            }
        }

        let latest = LatestAppRating(
            appStoreID: storeApp.appStoreID,
            storefront: storefront,
            ratingCount: ratingCount,
            averageRating: averageRating,
            observedAt: .now,
            source: .iTunesSearch,
            storeApp: storeApp
        )
        modelContext.insert(latest)
        storeApp.storefrontLatest.append(latest)
    }

    private static func previewRatingGrowth(position: Int, dayIndex: Int) -> Int {
        let bucketIndex = min(4, dayIndex / 6)
        let dayInBucket = dayIndex % 6
        let baseline = 36 + (position * 7)

        switch position % 5 {
        case 1:
            let ramp = [18, 28, 44, 72, 108][bucketIndex]
            return baseline + ramp + (dayInBucket * 5)
        case 2:
            let surge = bucketIndex == 2 ? 185 : 42 + (bucketIndex * 11)
            return baseline + surge + ((dayInBucket % 2) * 18)
        case 3:
            let taper = [128, 104, 74, 48, 30][bucketIndex]
            return baseline + taper - min(18, dayInBucket * 3)
        case 4:
            let pulse = [54, 142, 46, 166, 58][bucketIndex]
            return baseline + pulse + ((dayInBucket == 1 || dayInBucket == 4) ? 34 : 0)
        default:
            let steady = [78, 82, 76, 88, 80][bucketIndex]
            return baseline + steady + ((position + dayInBucket) % 4 * 9)
        }
    }
}

struct KeywordTablePreview: View {
    let previewContainer: OpenASOPreviewContainer<(
        rows: [KeywordWorkspaceRow],
        trackedAppStoreID: Int64,
        storefronts: [StorefrontDefinition]
    )>
    let services: AppServices

    init() {
        let previewContainer = OpenASOPreviewContainer(seed: Self.seed)
        self.previewContainer = previewContainer
        self.services = AppServices.mocked(
            httpClient: PreviewHTTPClient(),
            modelContainer: previewContainer.modelContainer
        )
    }

    var rows: [KeywordWorkspaceRow] {
        previewContainer.seedData.rows
    }

    var trackedAppStoreID: Int64 {
        previewContainer.seedData.trackedAppStoreID
    }

    var storefronts: [StorefrontDefinition] {
        previewContainer.seedData.storefronts
    }

    var body: some View {
        KeywordTableView(
            rows: rows,
            isLoadingRows: false,
            contentRevision: 0,
            trackedAppStoreID: trackedAppStoreID,
            chartSelectionScope: StorefrontFilter.all.id,
            insightsSummary: .months,
            storefronts: storefronts,
            modelContext: previewContainer.modelContainer.mainContext,
            appCatalogService: services.appCatalogService,
            appIconStore: services.appIconStore
        )
            .frame(width: 1280, height: 520)
            .padding(24)
            .openASOPreviewEnvironment(previewContainer)
    }

    private static func seed(in modelContext: ModelContext) -> (
        rows: [KeywordWorkspaceRow],
        trackedAppStoreID: Int64,
        storefronts: [StorefrontDefinition]
    ) {
        let trackedApp = TrackedApp(
            appStoreID: 6448311069,
            bundleID: "com.openai.chat",
            name: "ChatGPT",
            subtitle: "AI chatbot for writing and learning",
            sellerName: "OpenAI",
            defaultPlatform: .iphone
        )
        let storefronts = [
            Storefront(code: "us", name: "United States", flagEmoji: "US", languageCode: "en"),
            Storefront(code: "gb", name: "United Kingdom", flagEmoji: "GB", languageCode: "en"),
            Storefront(code: "ca", name: "Canada", flagEmoji: "CA", languageCode: "en"),
            Storefront(code: "au", name: "Australia", flagEmoji: "AU", languageCode: "en"),
            Storefront(code: "de", name: "Germany", flagEmoji: "DE", languageCode: "de"),
            Storefront(code: "ao", name: "Angola", flagEmoji: "AO", languageCode: "pt")
        ]
        let storefrontByCode = Dictionary(uniqueKeysWithValues: storefronts.map { ($0.code, $0) })
        let competitors = [
            PreviewRankedApp(appStoreID: trackedApp.appStoreID, name: trackedApp.name, subtitle: trackedApp.subtitle, sellerName: trackedApp.sellerName ?? "OpenAI"),
            PreviewRankedApp(appStoreID: 310633997, name: "Google", subtitle: "Search, images and AI chatbot help", sellerName: "Google LLC"),
            PreviewRankedApp(appStoreID: 1444383602, name: "Perplexity", subtitle: "Ask anything with AI search", sellerName: "Perplexity AI, Inc."),
            PreviewRankedApp(appStoreID: 1668000334, name: "Microsoft Copilot", subtitle: "Your everyday AI companion", sellerName: "Microsoft Corporation"),
            PreviewRankedApp(appStoreID: 6479726147, name: "Claude", subtitle: "AI assistant for deep work", sellerName: "Anthropic PBC"),
            PreviewRankedApp(appStoreID: 284882215, name: "Facebook", subtitle: "Explore social communities", sellerName: "Meta Platforms, Inc.")
        ]
        let fixtures = [
            PreviewKeywordFixture(
                term: "ai chatbot",
                storefrontCode: "us",
                popularity: 92,
                difficulty: 64,
                ranks: [19, 12, 8, 5, 3, 2, 1],
                note: "High-volume tracked keyword.",
                topApps: [0, 2, 3, 4, 1]
            ),
            PreviewKeywordFixture(
                term: "essay writer",
                storefrontCode: "us",
                popularity: 88,
                difficulty: 83,
                ranks: [7, 7, 8, 8, 9, 11, 12],
                note: "Competitive SERP with paid acquisition pressure.",
                topApps: [2, 3, 0, 4, 1]
            ),
            PreviewKeywordFixture(
                term: "homework help",
                storefrontCode: "gb",
                popularity: 76,
                difficulty: 71,
                ranks: [34, 31, 30, 28, 25, 21, 16],
                note: "Moving steadily after metadata update.",
                topApps: [3, 0, 2, 4, 1]
            ),
            PreviewKeywordFixture(
                term: "ai image generator",
                storefrontCode: "ca",
                popularity: 84,
                difficulty: 91,
                ranks: [42, 39, 44, 36, 38, 29, 24],
                note: "Volatile but improving.",
                topApps: [1, 2, 4, 0, 3]
            ),
            PreviewKeywordFixture(
                term: "translate app",
                storefrontCode: "de",
                popularity: 63,
                difficulty: 42,
                ranks: [14, 14, 14, 14, 14, 14, 14],
                note: "Stable position across the week.",
                topApps: [1, 0, 3, 2, 4]
            ),
            PreviewKeywordFixture(
                term: "voice assistant",
                storefrontCode: "au",
                popularity: 70,
                difficulty: 67,
                ranks: [22, 18, 19, 17, 14, 18, 23],
                note: "Lost ground after weekend refresh.",
                topApps: [3, 1, 4, 0, 2]
            ),
            PreviewKeywordFixture(
                term: "productivity ai",
                storefrontCode: "us",
                popularity: 58,
                difficulty: 46,
                ranks: [nil],
                errorMessage: "Lookup failed",
                note: "Latest refresh returned a provider error.",
                topApps: []
            ),
            PreviewKeywordFixture(
                term: "study planner",
                storefrontCode: "gb",
                popularity: 41,
                difficulty: 25,
                ranks: [51, 48, 45, 43, 41, 37, 33],
                note: "Lower volume, easier ranking opportunity.",
                resultCount: 75,
                topApps: [0, 4, 2, 3]
            ),
            PreviewKeywordFixture(
                term: "meeting notes",
                storefrontCode: "ca",
                popularity: 55,
                difficulty: 58,
                ranks: [5, 5, 6, 5, 5, 6, 5],
                note: nil,
                topApps: [0, 3, 2, 4, 1]
            ),
            PreviewKeywordFixture(
                term: "chat bot free",
                storefrontCode: "us",
                popularity: 96,
                difficulty: 94,
                ranks: [2, 3, 4, 4, 5, 7, 9],
                popularityUpdatedAt: Calendar.current.date(byAdding: .day, value: -8, to: .now) ?? .now,
                note: "High intent, rank softened this week.",
                topApps: [2, 0, 4, 3, 1]
            ),
            PreviewKeywordFixture(
                term: "ai keyboard",
                storefrontCode: "au",
                popularity: nil,
                difficulty: 39,
                ranks: [28, 26, 22, 23, 19, 17, 15],
                errorMessage: "Connect an Apple Ads web session in Settings.",
                note: "Popularity score unavailable.",
                topApps: [4, 0, 2, 3]
            ),
            PreviewKeywordFixture(
                term: "business planner",
                storefrontCode: "ao",
                popularity: nil,
                difficulty: nil,
                ranks: [nil],
                errorMessage: "Apple Ads does not support keyword popularity in Angola.",
                statusMessage: "Popularity unavailable. Apple Ads does not support keyword popularity in Angola.",
                note: "Unsupported Apple Ads popularity storefront.",
                topApps: []
            ),
            PreviewKeywordFixture(
                term: "grammar checker",
                storefrontCode: "de",
                popularity: 79,
                difficulty: nil,
                ranks: [],
                note: "Waiting for first rank capture.",
                topApps: []
            )
        ]

        modelContext.insert(trackedApp)
        storefronts.forEach(modelContext.insert)

        let rows = fixtures.map { fixture in
            let storefront = storefrontByCode[fixture.storefrontCode]
            let storefrontDefinition = storefront.map {
                StorefrontDefinition(
                    code: $0.code,
                    name: $0.name,
                    flagEmoji: $0.flagEmoji,
                    title: $0.title
                )
            }
            let query = try! KeywordQuery.fetchOrInsert(
                term: fixture.term,
                storefront: fixture.storefrontCode,
                platform: .iphone,
                in: modelContext
            )
            let track = TrackedAppKeyword(
                term: fixture.term,
                storefront: fixture.storefrontCode,
                platform: .iphone,
                trackedApp: trackedApp,
                query: query
            )
            track.notes = fixture.note ?? ""
            track.statusMessage = fixture.statusMessage ?? fixture.errorMessage.map { "Popularity failed to fetch. \($0)" }
            let metrics = KeywordDailyMetric(
                queryKey: track.queryKey,
                keyword: track.term,
                storefront: track.storefront,
                platform: track.platform,
                popularityScore: fixture.popularity,
                difficultyScore: fixture.difficulty,
                source: .appleAdsPopularity,
                updatedAt: fixture.popularityUpdatedAt
            )
            let snapshots = fixture.ranks.enumerated().map { offset, rank in
                TrackedKeywordDailyRanking(
                    rank: rank,
                    searchedAt: Calendar.current.date(
                        byAdding: .day,
                        value: offset - max(fixture.ranks.count - 1, 0),
                        to: .now
                    ) ?? .now,
                    source: .appStoreWeb,
                    resultCount: fixture.resultCount,
                    errorMessage: rank == nil ? fixture.errorMessage : nil,
                    keywordTrack: track
                )
            }

            trackedApp.keywordTracks.append(track)
            modelContext.insert(track)
            modelContext.insert(metrics)
            snapshots.forEach {
                track.snapshots.append($0)
                modelContext.insert($0)
            }

            if let latestSnapshot = snapshots.last {
                fixture.topApps.enumerated().forEach { position, competitorIndex in
                    let app = competitors[competitorIndex]
                    let result = TrackedKeywordRankedResult(
                        position: position + 1,
                        appStoreID: app.appStoreID,
                        bundleID: nil,
                        name: app.name,
                        subtitle: app.subtitle,
                        sellerName: app.sellerName,
                        snapshot: latestSnapshot
                    )
                    latestSnapshot.topResults.append(result)
                    modelContext.insert(result)
                }
            }

            return KeywordWorkspaceRow(
                track: track,
                storefront: storefrontDefinition,
                metrics: metrics,
                latestSnapshot: snapshots.last,
                trendSnapshots: snapshots,
                rankingApps: Array(snapshots.last?.topResults.prefix(5) ?? [])
            )
        }
        try? modelContext.save()

        let storefrontDefinitions = storefronts.map {
            StorefrontDefinition(
                code: $0.code,
                name: $0.name,
                flagEmoji: $0.flagEmoji,
                title: $0.title
            )
        }
        return (rows, trackedApp.appStoreID, storefrontDefinitions)
    }

    private struct PreviewKeywordFixture {
        let term: String
        let storefrontCode: String
        let popularity: Int?
        let difficulty: Int?
        let ranks: [Int?]
        let errorMessage: String?
        let statusMessage: String?
        let popularityUpdatedAt: Date
        let note: String?
        let resultCount: Int
        let topApps: [Int]

        init(
            term: String,
            storefrontCode: String,
            popularity: Int?,
            difficulty: Int?,
            ranks: [Int?],
            errorMessage: String? = nil,
            statusMessage: String? = nil,
            popularityUpdatedAt: Date = .now,
            note: String?,
            resultCount: Int = 50,
            topApps: [Int]
        ) {
            self.term = term
            self.storefrontCode = storefrontCode
            self.popularity = popularity
            self.difficulty = difficulty
            self.ranks = ranks
            self.errorMessage = errorMessage
            self.statusMessage = statusMessage
            self.popularityUpdatedAt = popularityUpdatedAt
            self.note = note
            self.resultCount = resultCount
            self.topApps = topApps
        }
    }

    private struct PreviewRankedApp {
        let appStoreID: Int64
        let name: String
        let subtitle: String?
        let sellerName: String
    }
}
