import AppKit
import ImageIO
import SwiftData
import SwiftUI

struct KeywordRankingListSheet: View {
    @Environment(AppServices.self) private var services

    let keyword: String
    let storefrontCode: String
    let platform: AppPlatform
    let searchedAt: Date?
    let resultCount: Int?
    let crawlKey: String?
    let trackedAppStoreID: Int64
    let modelContext: ModelContext
    let appCatalogService: AppCatalogService
    let appIconStore: AppIconStore

    @State private var items: [KeywordRankingListItem]
    @State private var enrichedRows: [KeywordRankingCatalogRow] = []
    @State private var enrichedRowsIncludeScreenshots = false
    @State private var storefrontLanguageCode: String?
    @State private var storefrontFlagEmoji: String?
    @AppStorage(
        "keywordRankingListShowsScreenshots",
        store: .openASOShared
    ) private var isShowingScreenshots = false
    @State private var sortOrder = [
        KeyPathComparator(\KeywordRankingCatalogRow.positionSortValue)
    ]

    init(
        row: KeywordWorkspaceRow,
        trackedAppStoreID: Int64,
        modelContext: ModelContext,
        appCatalogService: AppCatalogService,
        appIconStore: AppIconStore
    ) {
        self.keyword = row.track.term
        self.storefrontCode = row.track.storefront
        self.platform = row.track.platform
        self.searchedAt = row.latestSnapshot?.searchedAt
        self.resultCount = row.latestSnapshot?.resultCount
        self.crawlKey = row.latestSnapshot?.id
        self.trackedAppStoreID = trackedAppStoreID
        self.modelContext = modelContext
        self.appCatalogService = appCatalogService
        self.appIconStore = appIconStore
        _items = State(initialValue: row.rankingApps.map(KeywordRankingListItem.init))
    }

    private var sortedRows: [KeywordRankingCatalogRow] {
        enrichedRows.sorted(using: sortOrder)
    }

    private var enrichmentID: String {
        [
            storefrontCode.lowercased(),
            items.map { "\($0.appStoreID):\($0.position)" }.joined(separator: ",")
        ].joined(separator: "::")
    }

    var body: some View {
        VStack(spacing: 0) {
            KeywordRankingListHeader(
                keyword: keyword,
                storefrontCode: storefrontCode,
                storefrontFlagEmoji: storefrontFlagEmoji,
                searchedAt: searchedAt,
                resultCount: resultCount
            )

            Divider()

            if items.isEmpty {
                ContentUnavailableView(
                    "No Ranking Apps",
                    systemImage: "list.number",
                    description: Text("Refresh this keyword to capture ranking apps for this country.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if isShowingScreenshots {
                    KeywordRankingScreenshotList(
                        rows: sortedRows,
                        keyword: keyword,
                        storefrontCode: storefrontCode,
                        storefrontLanguageCode: storefrontLanguageCode,
                        platform: platform,
                        trackedAppStoreID: trackedAppStoreID,
                        modelContext: modelContext,
                        appCatalogService: appCatalogService,
                        appIconStore: appIconStore
                    )
                } else {
                    Table(sortedRows, sortOrder: $sortOrder) {
                        TableColumn("Rank", value: \.positionSortValue) { row in
                            KeywordRankingPositionCell(row: row)
                        }
                        .width(min: 55, ideal: 60)

                        TableColumn("App", value: \.appNameSortValue) { row in
                            KeywordRankingAppCell(
                                row: row,
                                keyword: keyword,
                                storefrontCode: storefrontCode,
                                trackedAppStoreID: trackedAppStoreID,
                                modelContext: modelContext,
                                appCatalogService: appCatalogService,
                                appIconStore: appIconStore
                            )
                        }
                        .width(min: 300, ideal: 340)

                        TableColumn("Ratings", value: \.ratingCountSortValue) { row in
                            KeywordRankingRatingCountCell(row: row)
                        }
                        .width(min: 66, ideal: 72, max: 82)

                        TableColumn("Avg. Rating", value: \.averageRatingSortValue) { row in
                            KeywordRankingAverageRatingCell(row: row)
                        }
                        .width(min: 72, ideal: 78, max: 88)

                        TableColumn("New Ratings (30d)", value: \.newRatingsSortValue) { row in
                            KeywordRankingNewRatingsCell(row: row)
                        }
                        .width(min: 140, ideal: 150, max: 180)

                        TableColumn("Localized", value: \.localizationSortValue) { row in
                            KeywordRankingLocalizationCell(row: row, storefrontLanguageCode: storefrontLanguageCode)
                        }
                        .width(min: 82, ideal: 92, max: 104)

                        TableColumn("Released", value: \.releaseDateSortValue) { row in
                            KeywordRankingDateCell(date: row.releaseDate)
                        }
                        .width(min: 80, ideal: 92)

                        TableColumn("Last Updated", value: \.updatedDateSortValue) { row in
                            KeywordRankingTimeAgoCell(date: row.currentVersionReleaseDate)
                        }
                        .width(min: 100, ideal: 112)
                    }
                }
            }

            Divider()

            KeywordRankingListFooter(
                keyword: keyword,
                isShowingScreenshots: $isShowingScreenshots,
                canDownloadScreenshots: !sortedRows.isEmpty,
                downloadTopTenScreenshots: startTopTenScreenshotDownload
            )
        }
        .task(id: crawlKey) {
            loadRankingItems()
            loadEnrichedRows(includeScreenshots: isShowingScreenshots)
        }
        .task(id: isShowingScreenshots) {
            guard isShowingScreenshots, !enrichedRowsIncludeScreenshots else { return }
            loadEnrichedRows(includeScreenshots: true)
        }
        .frame(minWidth: 1_260, idealWidth: 1_420, minHeight: 720, idealHeight: 920)
    }

    private func loadRankingItems() {
        guard let crawlKey else { return }

        let targetCrawlKey = crawlKey
        let descriptor = FetchDescriptor<KeywordAppRanking>(
            predicate: #Predicate { ranking in
                ranking.crawlKey == targetCrawlKey
            },
            sortBy: [
                SortDescriptor(\KeywordAppRanking.position, order: .forward)
            ]
        )

        items = ((try? modelContext.fetch(descriptor)) ?? [])
            .map(KeywordRankingAppSummary.init)
            .map { KeywordRankingListItem(result: $0) }
    }

    private func loadEnrichedRows(includeScreenshots: Bool) {
        let appStoreIDs = items.map(\.appStoreID)
        let appStoreIDSet = Set(appStoreIDs)
        let normalizedStorefront = storefrontCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !appStoreIDs.isEmpty else {
            enrichedRows = []
            enrichedRowsIncludeScreenshots = false
            return
        }

        let storeAppsDescriptor = FetchDescriptor<StoreApp>(
            predicate: #Predicate { app in
                appStoreIDs.contains(app.appStoreID)
            }
        )
        let storeApps = (try? modelContext.fetch(storeAppsDescriptor)) ?? []
        let catalogAppsByID = Dictionary(
            uniqueKeysWithValues: storeApps
                .map { ($0.appStoreID, StoreAppDisplayValue($0)) }
        )
        let storefrontDisplay = storefrontDisplay(for: normalizedStorefront)
        storefrontLanguageCode = storefrontDisplay?.languageCode
        storefrontFlagEmoji = storefrontDisplay?.flagEmoji

        let storefrontMetadataByID = storefrontMetadataByAppStoreID(
            storefront: normalizedStorefront,
            appStoreIDSet: appStoreIDSet,
            includeScreenshots: includeScreenshots
        )
        let usMetadataByID = normalizedStorefront == "us"
            ? storefrontMetadataByID
            : storefrontMetadataByAppStoreID(
                storefront: "us",
                appStoreIDSet: appStoreIDSet,
                includeScreenshots: includeScreenshots
            )

        let latestDescriptor = FetchDescriptor<LatestAppRating>(
            predicate: #Predicate { latest in
                latest.storefront == normalizedStorefront && appStoreIDs.contains(latest.appStoreID)
            },
            sortBy: [SortDescriptor(\.appStoreID, order: .forward)]
        )
        let latestByID = Dictionary(
            uniqueKeysWithValues: ((try? modelContext.fetch(latestDescriptor)) ?? [])
                .map { ($0.appStoreID, RatingLatestDisplayValue($0)) }
        )

        let snapshotDescriptor = FetchDescriptor<AppDailyRating>(
            predicate: #Predicate { snapshot in
                snapshot.storefront == normalizedStorefront && appStoreIDs.contains(snapshot.appStoreID)
            },
            sortBy: [
                SortDescriptor(\.appStoreID, order: .forward),
                SortDescriptor(\.ratingDate, order: .forward),
                SortDescriptor(\.observedAt, order: .forward)
            ]
        )
        let snapshotsByID = Dictionary(grouping: ((try? modelContext.fetch(snapshotDescriptor)) ?? [])
            .map(RatingSnapshotDisplayValue.init), by: \.appStoreID)

        enrichedRows = items.map { item in
            KeywordRankingCatalogRow(
                item: item,
                storeApp: catalogAppsByID[item.appStoreID],
                storefrontMetadata: storefrontMetadataByID[item.appStoreID],
                usMetadata: usMetadataByID[item.appStoreID],
                latestRating: latestByID[item.appStoreID],
                ratingSnapshots: snapshotsByID[item.appStoreID] ?? []
            )
        }
        enrichedRowsIncludeScreenshots = includeScreenshots
    }

    private func storefrontDisplay(for storefront: String) -> StorefrontDisplayValue? {
        let targetStorefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let descriptor = FetchDescriptor<Storefront>(
            predicate: #Predicate { storefront in
                storefront.code == targetStorefront
            }
        )
        return (try? modelContext.fetch(descriptor).first).map(StorefrontDisplayValue.init)
    }

    private func storefrontMetadataByAppStoreID(
        storefront: String,
        appStoreIDSet: Set<Int64>,
        includeScreenshots: Bool
    ) -> [Int64: AppStorefrontMetadataDisplayValue] {
        let targetStorefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let descriptor = FetchDescriptor<AppStorefrontMetadata>(
            predicate: #Predicate { metadata in
                metadata.storefront == targetStorefront && appStoreIDSet.contains(metadata.appStoreID)
            },
            sortBy: [SortDescriptor(\.appStoreID, order: .forward)]
        )
        return Dictionary(
            uniqueKeysWithValues: ((try? modelContext.fetch(descriptor)) ?? [])
                .map {
                    (
                        $0.appStoreID,
                        AppStorefrontMetadataDisplayValue($0, includeScreenshots: includeScreenshots)
                    )
                }
        )
    }

    @MainActor
    private func startTopTenScreenshotDownload() {
        guard !services.screenshotDownloadProgressStore.isDownloading else { return }
        guard let destinationDirectory = chooseScreenshotDownloadDirectory() else { return }

        let exportApps = sortedRows
            .prefix(10)
            .map(KeywordRankingScreenshotExportApp.init)
        let exporter = KeywordRankingScreenshotExportService(
            downloader: services.screenshotDownloadService
        )
        let title = "\(keyword) \(storefrontCode.uppercased()) screenshots"
        let exportRoot = exporter.exportRootURL(
            destinationDirectory: destinationDirectory,
            keyword: keyword,
            storefront: storefrontCode,
            date: .now
        )
        let totalScreenshotCount = exportApps.reduce(0) { count, app in
            count + app.groups.reduce(0) { $0 + $1.screenshots.count }
        }
        let progressID = services.screenshotDownloadProgressStore.begin(
            title: title,
            destinationURL: exportRoot,
            total: totalScreenshotCount
        )
        let progressStore = services.screenshotDownloadProgressStore

        Task {
            do {
                let summary = try await exporter.export(
                    apps: exportApps,
                    keyword: keyword,
                    storefront: storefrontCode,
                    platform: platform,
                    destinationDirectory: destinationDirectory,
                    exportRootURL: exportRoot
                ) { completed, total, failureCount in
                    await MainActor.run {
                        progressStore.update(
                            id: progressID,
                            completed: completed,
                            total: total,
                            failureCount: failureCount
                        )
                    }
                }

                await MainActor.run {
                    progressStore.finish(
                        id: progressID,
                        downloadedCount: summary.downloadedCount,
                        failureCount: summary.failureCount,
                        skippedAppCount: summary.skippedAppCount
                    )
                }
            } catch {
                await MainActor.run {
                    progressStore.fail(id: progressID, message: error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    private func chooseScreenshotDownloadDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Screenshot Download Folder"
        panel.prompt = "Download"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

#Preview("Ranking Sheet") {
    let previewContainer = OpenASOPreviewContainer(seed: KeywordRankingListPreviewFixtures.seed)
    let services = AppServices.mocked(
        httpClient: PreviewHTTPClient(),
        modelContainer: previewContainer.modelContainer
    )
    KeywordRankingListSheet(
        row: previewContainer.seedData.row,
        trackedAppStoreID: previewContainer.seedData.trackedAppStoreID,
        modelContext: previewContainer.modelContainer.mainContext,
        appCatalogService: services.appCatalogService,
        appIconStore: services.appIconStore
    )
    .openASOPreviewEnvironment(previewContainer, allowsIconNetworkFetches: true)
}

#Preview("Ranking Sheet - Empty") {
    let previewContainer = OpenASOPreviewContainer(seed: KeywordRankingListPreviewFixtures.seedEmptyRanking)
    let services = AppServices.mocked(
        httpClient: PreviewHTTPClient(),
        modelContainer: previewContainer.modelContainer
    )
    KeywordRankingListSheet(
        row: previewContainer.seedData.row,
        trackedAppStoreID: previewContainer.seedData.trackedAppStoreID,
        modelContext: previewContainer.modelContainer.mainContext,
        appCatalogService: services.appCatalogService,
        appIconStore: services.appIconStore
    )
    .openASOPreviewEnvironment(previewContainer)
}

private struct KeywordRankingCatalogRow: Identifiable {
    let item: KeywordRankingListItem
    let storeApp: StoreAppDisplayValue?
    let storefrontMetadata: AppStorefrontMetadataDisplayValue?
    let usMetadata: AppStorefrontMetadataDisplayValue?
    let latestRating: RatingLatestDisplayValue?
    let newRatingPoints: [KeywordRankingNewRatingPoint]

    var id: Int64 { item.id }
    var position: Int { item.position }
    var appStoreID: Int64 { item.appStoreID }
    var appName: String {
        trimmed(storefrontMetadata?.name)
            ?? trimmed(usMetadata?.name)
            ?? trimmed(storeApp?.name)
            ?? item.name
    }
    var subtitle: String? {
        trimmed(storefrontMetadata?.subtitle)
            ?? trimmed(usMetadata?.subtitle)
            ?? trimmed(storeApp?.subtitle)
            ?? trimmed(item.subtitle)
    }
    var sellerName: String {
        trimmed(storefrontMetadata?.sellerName)
            ?? trimmed(usMetadata?.sellerName)
            ?? trimmed(storeApp?.sellerName)
            ?? trimmed(item.sellerName)
            ?? "Unknown Seller"
    }
    var iconURLString: String? {
        storefrontMetadata?.iconURLString
            ?? usMetadata?.iconURLString
            ?? storeApp?.iconURLString
            ?? item.iconURLString
    }
    var supportedLanguageCodes: [String] {
        storeApp?.supportedLanguageCodes ?? []
    }
    var languageDataFetchedAt: Date? {
        storeApp?.supportedLanguageCodesFetchedAt
    }
    var screenshots: [AppStoreScreenshotDisplayValue] {
        storefrontMetadata?.screenshots ?? []
    }
    var screenshotGroups: [ScreenshotPlatformGroup] {
        ScreenshotPlatformGroup.groups(from: screenshots)
    }
    var ratingCount: Int? { latestRating?.ratingCount }
    var averageRating: Double? { latestRating?.averageRating }
    var releaseDate: Date? { storefrontMetadata?.releaseDate ?? usMetadata?.releaseDate ?? storeApp?.releaseDate }
    var currentVersionReleaseDate: Date? {
        storefrontMetadata?.currentVersionReleaseDate
            ?? usMetadata?.currentVersionReleaseDate
            ?? storeApp?.currentVersionReleaseDate
    }
    var totalNewRatings: Int? {
        guard newRatingPoints.allSatisfy(\.isComplete) else { return nil }
        return newRatingPoints.reduce(0) { $0 + $1.delta }
    }

    var positionSortValue: Int { position }
    var appNameSortValue: String { appName.localizedLowercase }
    var ratingCountSortValue: Int { ratingCount ?? -1 }
    var averageRatingSortValue: Double { averageRating ?? -1 }
    var newRatingsSortValue: Int { totalNewRatings ?? -1 }
    var releaseDateSortValue: Date { releaseDate ?? .distantPast }
    var updatedDateSortValue: Date { currentVersionReleaseDate ?? .distantPast }
    var localizationSortValue: Int { supportedLanguageCodes.isEmpty ? -1 : supportedLanguageCodes.count }

    init(
        item: KeywordRankingListItem,
        storeApp: StoreAppDisplayValue?,
        storefrontMetadata: AppStorefrontMetadataDisplayValue?,
        usMetadata: AppStorefrontMetadataDisplayValue?,
        latestRating: RatingLatestDisplayValue?,
        ratingSnapshots: [RatingSnapshotDisplayValue]
    ) {
        self.item = item
        self.storeApp = storeApp
        self.storefrontMetadata = storefrontMetadata
        self.usMetadata = usMetadata
        self.latestRating = latestRating
        self.newRatingPoints = Self.makeNewRatingPoints(from: ratingSnapshots)
    }

    private static func makeNewRatingPoints(from snapshots: [RatingSnapshotDisplayValue]) -> [KeywordRankingNewRatingPoint] {
        let sortedSnapshots = snapshots
            .filter { $0.ratingCount != nil }
            .sorted {
                if $0.ratingDate == $1.ratingDate {
                    return $0.observedAt < $1.observedAt
                }
                return $0.ratingDate < $1.ratingDate
            }

        guard sortedSnapshots.count >= 2 else {
            return Self.emptyNewRatingBuckets()
        }

        let recentSnapshots = Array(sortedSnapshots.suffix(31))
        var dailyDeltas: [Int] = []
        dailyDeltas.reserveCapacity(max(0, recentSnapshots.count - 1))

        for index in recentSnapshots.indices.dropFirst() {
            guard
                let previousCount = recentSnapshots[recentSnapshots.index(before: index)].ratingCount,
                let currentCount = recentSnapshots[index].ratingCount
            else {
                continue
            }

            dailyDeltas.append(max(0, currentCount - previousCount))
        }

        return Self.makeNewRatingBuckets(from: Array(dailyDeltas.suffix(30)))
    }

    private static func makeNewRatingBuckets(from dailyDeltas: [Int]) -> [KeywordRankingNewRatingPoint] {
        let bucketSize = 2
        let bucketCount = 15
        let paddedDeltas = Array(repeating: Int?.none, count: max(0, 30 - dailyDeltas.count)) + dailyDeltas.map(Optional.some)

        return (0..<bucketCount).map { bucketIndex in
            let startIndex = bucketIndex * bucketSize
            let bucketValues = paddedDeltas[startIndex..<startIndex + bucketSize]
            let availableValues = bucketValues.compactMap { $0 }

            return KeywordRankingNewRatingPoint(
                id: bucketIndex,
                label: "Days \(startIndex + 1)-\(startIndex + bucketSize)",
                delta: availableValues.reduce(0, +),
                hasData: !availableValues.isEmpty,
                isComplete: availableValues.count == bucketSize
            )
        }
    }

    private static func emptyNewRatingBuckets() -> [KeywordRankingNewRatingPoint] {
        makeNewRatingBuckets(from: [])
    }

    private func trimmed(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedValue, !trimmedValue.isEmpty else {
            return nil
        }
        return trimmedValue
    }
}

private struct StorefrontDisplayValue {
    let flagEmoji: String
    let languageCode: String

    init(_ storefront: Storefront) {
        self.flagEmoji = storefront.flagEmoji
        self.languageCode = storefront.languageCode
    }
}

private struct StoreAppDisplayValue {
    let appStoreID: Int64
    let name: String
    let subtitle: String?
    let sellerName: String?
    let iconURLString: String?
    let supportedLanguageCodes: [String]
    let supportedLanguageCodesFetchedAt: Date?
    let releaseDate: Date?
    let currentVersionReleaseDate: Date?

    init(_ storeApp: StoreApp) {
        self.appStoreID = storeApp.appStoreID
        self.name = storeApp.name
        self.subtitle = storeApp.subtitle
        self.sellerName = storeApp.sellerName
        self.iconURLString = storeApp.iconURLString
        self.supportedLanguageCodes = storeApp.supportedLanguageCodes
        self.supportedLanguageCodesFetchedAt = storeApp.supportedLanguageCodesFetchedAt
        self.releaseDate = storeApp.releaseDate
        self.currentVersionReleaseDate = storeApp.currentVersionReleaseDate
    }
}

private struct AppStorefrontMetadataDisplayValue {
    let appStoreID: Int64
    let name: String
    let subtitle: String?
    let sellerName: String?
    let iconURLString: String?
    let releaseDate: Date?
    let currentVersionReleaseDate: Date?
    let screenshots: [AppStoreScreenshotDisplayValue]

    init(_ metadata: AppStorefrontMetadata, includeScreenshots: Bool) {
        self.appStoreID = metadata.appStoreID
        self.name = metadata.name
        self.subtitle = metadata.subtitle
        self.sellerName = metadata.sellerName
        self.iconURLString = metadata.iconURLString
        self.releaseDate = metadata.releaseDate
        self.currentVersionReleaseDate = metadata.currentVersionReleaseDate
        self.screenshots = includeScreenshots
            ? metadata.screenshots.map(AppStoreScreenshotDisplayValue.init)
            : []
    }
}

private struct AppStoreScreenshotDisplayValue: Identifiable, Hashable {
    let id: String
    let platformRaw: String
    let displayTypeRaw: String
    let sortOrder: Int
    let urlString: String
    let width: Int?
    let height: Int?

    var aspectRatio: CGFloat {
        if let width, let height, width > 0, height > 0 {
            return CGFloat(width) / CGFloat(height)
        }

        switch platformRaw {
        case "iphone":
            return CGFloat(9.0 / 19.5)
        case "ipad":
            return CGFloat(4.0 / 3.0)
        case "watch":
            return CGFloat(4.0 / 5.0)
        case "mac", "desktop":
            return CGFloat(16.0 / 10.0)
        default:
            return CGFloat(9.0 / 16.0)
        }
    }

    init(_ screenshot: AppStoreScreenshot) {
        self.id = screenshot.identityKey
        self.platformRaw = screenshot.platformRaw
        self.displayTypeRaw = screenshot.displayTypeRaw
        self.sortOrder = screenshot.sortOrder
        self.urlString = screenshot.urlString
        self.width = screenshot.width
        self.height = screenshot.height
    }
}

private struct ScreenshotPlatformGroup: Identifiable, Hashable {
    let platformRaw: String
    let screenshots: [AppStoreScreenshotDisplayValue]

    var id: String { platformRaw }
    var displayName: String {
        switch platformRaw {
        case "iphone":
            return "iPhone"
        case "ipad":
            return "iPad"
        case "watch":
            return "Watch"
        case "mac", "desktop":
            return "Mac"
        case "tv":
            return "TV"
        default:
            return platformRaw.capitalized
        }
    }

    static func groups(from screenshots: [AppStoreScreenshotDisplayValue]) -> [ScreenshotPlatformGroup] {
        Dictionary(grouping: screenshots, by: \.platformRaw)
            .map { platform, screenshots in
                ScreenshotPlatformGroup(
                    platformRaw: platform,
                    screenshots: screenshots.sorted { $0.sortOrder < $1.sortOrder }
                )
            }
            .sorted { lhs, rhs in
                platformSortValue(lhs.platformRaw) < platformSortValue(rhs.platformRaw)
            }
    }

    private static func platformSortValue(_ platform: String) -> Int {
        switch platform {
        case "iphone":
            return 0
        case "ipad":
            return 1
        case "watch":
            return 2
        case "mac", "desktop":
            return 3
        case "tv":
            return 4
        default:
            return 99
        }
    }
}

private struct RatingLatestDisplayValue {
    let appStoreID: Int64
    let ratingCount: Int?
    let averageRating: Double?

    init(_ latest: LatestAppRating) {
        self.appStoreID = latest.appStoreID
        self.ratingCount = latest.ratingCount
        self.averageRating = latest.averageRating
    }
}

private struct RatingSnapshotDisplayValue {
    let appStoreID: Int64
    let ratingDate: String
    let ratingCount: Int?
    let observedAt: Date

    init(_ snapshot: AppDailyRating) {
        self.appStoreID = snapshot.appStoreID
        self.ratingDate = snapshot.ratingDate
        self.ratingCount = snapshot.ratingCount
        self.observedAt = snapshot.observedAt
    }
}

private struct KeywordRankingNewRatingPoint: Identifiable {
    let id: Int
    let label: String
    let delta: Int
    let hasData: Bool
    let isComplete: Bool
}

private struct KeywordRankingAppCell: View {
    let row: KeywordRankingCatalogRow
    let keyword: String
    let storefrontCode: String
    let trackedAppStoreID: Int64
    let modelContext: ModelContext
    let appCatalogService: AppCatalogService
    let appIconStore: AppIconStore
    var isProminent = false

    var body: some View {
        HStack(spacing: isProminent ? 12 : 10) {
            AppIconImageView(
                appStoreID: row.appStoreID,
                storefrontCode: storefrontCode,
                preferredIconURLString: row.iconURLString,
                size: isProminent ? 52 : 38,
                cornerRadius: isProminent ? 10 : 8,
                modelContext: modelContext,
                appCatalogService: appCatalogService,
                appIconStore: appIconStore
            )

            VStack(alignment: .leading, spacing: isProminent ? 5 : 3) {
                HStack(spacing: 8) {
                    Text(row.appName.highlightingMatches(of: keyword))
                        .font(appNameFont)
                        .lineLimit(1)

                    if row.appStoreID == trackedAppStoreID {
                        Text("Tracked")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }

                Text((row.subtitle ?? row.sellerName).highlightingMatches(of: keyword))
                    .font(isProminent ? .callout : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, isProminent ? 8 : 4)
    }

    private var appNameFont: Font {
        let weight: Font.Weight = row.appStoreID == trackedAppStoreID ? .semibold : .regular
        return isProminent ? .title3.weight(weight) : .body.weight(weight)
    }
}

private struct KeywordRankingPositionCell: View {
    let row: KeywordRankingCatalogRow

    var body: some View {
        HStack(spacing: 2) {
            RankingPositionBadge(rank: row.position, hasSnapshot: true)

            Text("\(row.position)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 22, alignment: .leading)
        }
        .frame(width: 46, alignment: .leading)
    }
}

private struct KeywordRankingRatingCountCell: View {
    let row: KeywordRankingCatalogRow

    var body: some View {
        Text(row.ratingCount.formattedCompactCount)
            .font(.body.monospacedDigit())
            .foregroundStyle(row.ratingCount == nil ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct KeywordRankingAverageRatingCell: View {
    let row: KeywordRankingCatalogRow

    var body: some View {
        HStack(spacing: 4) {
            Text(row.averageRating.formattedAverageRating)
                .monospacedDigit()
                .foregroundStyle(row.averageRating == nil ? .secondary : .primary)

            if row.averageRating != nil {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.medalGold)
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct KeywordRankingNewRatingsCell: View {
    let row: KeywordRankingCatalogRow

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Text(row.totalNewRatings.formattedCompactCount)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(row.totalNewRatings == nil ? .tertiary : .secondary)
                .frame(width: 38, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            KeywordRankingNewRatingsChart(points: row.newRatingPoints)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeywordRankingNewRatingsChart: View {
    let points: [KeywordRankingNewRatingPoint]

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(points) { point in
                RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                    .fill(Color.accentColor.opacity(opacity(for: point)))
                    .frame(width: 3, height: barHeight(for: point))
                    .accessibilityLabel(point.label)
                    .accessibilityValue(accessibilityValue(for: point))
            }
        }
        .frame(width: 101, height: 28, alignment: .bottomLeading)
        .accessibilityLabel("New ratings over the last 30 days")
    }

    private var yUpperBound: Int {
        max(1, points.map(\.delta).max() ?? 1)
    }

    private func barHeight(for point: KeywordRankingNewRatingPoint) -> CGFloat {
        guard point.hasData else {
            return 4
        }

        let normalizedValue = CGFloat(max(point.delta, 1)) / CGFloat(yUpperBound)
        return max(5, min(26, normalizedValue * 26))
    }

    private func opacity(for point: KeywordRankingNewRatingPoint) -> Double {
        if point.isComplete {
            return 0.78
        }

        if point.hasData {
            return 0.44
        }

        return 0.16
    }

    private func accessibilityValue(for point: KeywordRankingNewRatingPoint) -> String {
        if point.hasData {
            return "\(point.delta) new ratings"
        }

        return "No data"
    }
}

private struct KeywordRankingLocalizationCell: View {
    let row: KeywordRankingCatalogRow
    let storefrontLanguageCode: String?

    private var summary: LanguageLocalizationSummary {
        LanguageLocalizationSummary(
            supportedLanguageCodes: row.supportedLanguageCodes,
            storefrontLanguageCode: storefrontLanguageCode
        )
    }

    var body: some View {
        Text(summary.labelText)
            .font(.body)
            .foregroundStyle(summary.foregroundStyle)
            .lineLimit(1)
            .tooltip(summary.tooltip)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeywordRankingScreenshotList: View {
    let rows: [KeywordRankingCatalogRow]
    let keyword: String
    let storefrontCode: String
    let storefrontLanguageCode: String?
    let platform: AppPlatform
    let trackedAppStoreID: Int64
    let modelContext: ModelContext
    let appCatalogService: AppCatalogService
    let appIconStore: AppIconStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { row in
                        KeywordRankingScreenshotRow(
                            row: row,
                            keyword: keyword,
                            storefrontCode: storefrontCode,
                            storefrontLanguageCode: storefrontLanguageCode,
                            platform: platform,
                            trackedAppStoreID: trackedAppStoreID,
                            modelContext: modelContext,
                            appCatalogService: appCatalogService,
                            appIconStore: appIconStore
                        )
                    }
                } header: {
                    KeywordRankingScreenshotListHeader()
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct KeywordRankingScreenshotListHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Rank")
                .frame(width: 54, alignment: .leading)
            Text("App")
                .frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
            Text("Ratings")
                .frame(width: 74, alignment: .trailing)
            Text("Avg.")
                .frame(width: 66, alignment: .trailing)
            Text("New (30d)")
                .frame(width: 132, alignment: .leading)
            Text("Localized")
                .frame(width: 92, alignment: .leading)
            Text("Released")
                .frame(width: 92, alignment: .trailing)
            Text("Updated")
                .frame(width: 110, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct KeywordRankingScreenshotRow: View {
    let row: KeywordRankingCatalogRow
    let keyword: String
    let storefrontCode: String
    let storefrontLanguageCode: String?
    let platform: AppPlatform
    let trackedAppStoreID: Int64
    let modelContext: ModelContext
    let appCatalogService: AppCatalogService
    let appIconStore: AppIconStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                KeywordRankingPositionCell(row: row)
                    .frame(width: 54, alignment: .leading)

                KeywordRankingAppCell(
                    row: row,
                    keyword: keyword,
                    storefrontCode: storefrontCode,
                    trackedAppStoreID: trackedAppStoreID,
                    modelContext: modelContext,
                    appCatalogService: appCatalogService,
                    appIconStore: appIconStore,
                    isProminent: true
                )
                .frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)

                KeywordRankingRatingCountCell(row: row)
                    .frame(width: 74, alignment: .trailing)

                KeywordRankingAverageRatingCell(row: row)
                    .frame(width: 66, alignment: .trailing)

                KeywordRankingNewRatingsCell(row: row)
                    .frame(width: 132, alignment: .leading)

                KeywordRankingLocalizationCell(row: row, storefrontLanguageCode: storefrontLanguageCode)
                    .frame(width: 92, alignment: .leading)

                KeywordRankingDateCell(date: row.releaseDate)
                    .frame(width: 92, alignment: .trailing)

                KeywordRankingTimeAgoCell(date: row.currentVersionReleaseDate)
                    .frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(row.position.isMultiple(of: 2) ? Color.secondary.opacity(0.035) : Color.clear)

            KeywordRankingScreenshotStrip(row: row, desiredPlatform: platform)
                .padding(.leading, 82)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
                .background(row.position.isMultiple(of: 2) ? Color.secondary.opacity(0.035) : Color.clear)
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct KeywordRankingScreenshotStrip: View {
    let row: KeywordRankingCatalogRow
    let desiredPlatform: AppPlatform

    private var orderedGroups: [ScreenshotPlatformGroup] {
        row.screenshotGroups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if row.screenshotGroups.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle")
                    Text("No screenshots captured")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 44)
                .tooltip(ScreenshotAvailabilitySummary(row: row, desiredPlatform: desiredPlatform).tooltip)
            } else {
                ForEach(orderedGroups) { group in
                    screenshotGroup(group)
                }
            }
        }
    }

    private func screenshotGroup(_ group: ScreenshotPlatformGroup) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(group.displayName) (\(group.screenshots.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(group.screenshots) { screenshot in
                        AppStoreScreenshotThumbnail(screenshot: screenshot)
                    }
                }
                .padding(.bottom, 2)
            }
        }
    }
}

private struct AppStoreScreenshotThumbnail: View {
    @Environment(\.displayScale) private var displayScale

    let screenshot: AppStoreScreenshotDisplayValue

    @State private var image: CGImage?

    private var thumbnailSize: CGSize {
        let aspectRatio = screenshot.aspectRatio
        let targetHeight: CGFloat = 260
        let maxWidth: CGFloat = 430
        let minWidth: CGFloat = 82

        let unclampedWidth = targetHeight * aspectRatio
        let width = min(maxWidth, max(minWidth, unclampedWidth))
        return CGSize(width: width, height: width / aspectRatio)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))

            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16))
        }
        .task(id: "\(screenshot.urlString)::\(displayScale)::\(thumbnailSize.width)::\(thumbnailSize.height)") {
            image = await AppStoreScreenshotThumbnailStore.shared.image(
                urlString: screenshot.urlString,
                pixelSize: Int((max(thumbnailSize.width, thumbnailSize.height) * displayScale).rounded(.up))
            )
        }
    }
}

private actor AppStoreScreenshotThumbnailStore {
    static let shared = AppStoreScreenshotThumbnailStore()

    private let cache = NSCache<NSString, CGImage>()
    private var inFlightRequests: [String: Task<CGImage?, Never>] = [:]

    func image(urlString: String, pixelSize: Int) async -> CGImage? {
        let cacheKey = "\(urlString)::\(pixelSize)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let requestKey = cacheKey as String
        if let request = inFlightRequests[requestKey] {
            return await request.value
        }

        let request = Task<CGImage?, Never> {
            guard let url = URL(string: urlString) else { return nil }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      200 ..< 300 ~= httpResponse.statusCode else {
                    return nil
                }
                return Self.downsampleImage(data: data, pixelSize: pixelSize)
            } catch {
                return nil
            }
        }

        inFlightRequests[requestKey] = request
        let image = await request.value
        inFlightRequests[requestKey] = nil

        if let image {
            cache.setObject(image, forKey: cacheKey, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    private static func downsampleImage(data: Data, pixelSize: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return nil
        }

        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ] as CFDictionary

        return CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions)
    }
}

private struct LanguageLocalizationSummary {
    let supportedLanguageCodes: [String]
    let storefrontLanguageCode: String?

    var labelText: String {
        guard !normalizedSupportedCodes.isEmpty else { return "-" }
        return isLocalized ? "Yes" : "No"
    }

    var tooltip: String {
        guard !normalizedSupportedCodes.isEmpty else {
            return "Language data unavailable."
        }

        let supportList = normalizedSupportedCodes
            .map(Self.localizedLanguageName)
            .joined(separator: ", ")

        guard let storefrontLanguage = normalizedStorefrontLanguage else {
            return "Supports: \(supportList)."
        }

        let storefrontLanguageName = Self.localizedLanguageName(storefrontLanguage)
        if isLocalized {
            return "Localized for \(storefrontLanguageName). Supports: \(supportList)."
        }

        return "Not localized for \(storefrontLanguageName). Supports: \(supportList)."
    }

    var foregroundStyle: Color {
        guard !normalizedSupportedCodes.isEmpty else { return .secondary }
        return isLocalized ? .primary : .secondary
    }

    private var normalizedSupportedCodes: [String] {
        Array(Set(supportedLanguageCodes.compactMap(Self.normalizedLanguageCode))).sorted()
    }

    private var normalizedStorefrontLanguage: String? {
        Self.normalizedLanguageCode(storefrontLanguageCode)
    }

    private var isLocalized: Bool {
        guard normalizedSupportedCodes.count > 1 else { return false }
        guard let normalizedStorefrontLanguage else { return true }
        return normalizedSupportedCodes.contains(normalizedStorefrontLanguage)
    }

    private static func normalizedLanguageCode(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first?
            .uppercased()
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private static func localizedLanguageName(_ code: String) -> String {
        let localizedName = Locale.current.localizedString(forLanguageCode: code.lowercased())
        if let localizedName, !localizedName.isEmpty {
            return "\(localizedName) (\(code))"
        }
        return code
    }
}

private struct ScreenshotAvailabilitySummary {
    let row: KeywordRankingCatalogRow
    let desiredPlatform: AppPlatform

    var badgeText: String {
        guard !row.screenshotGroups.isEmpty else { return "-" }
        if let desiredGroup {
            return "\(desiredGroup.displayName.prefix(2)) \(desiredGroup.screenshots.count)"
        }
        if let firstGroup = row.screenshotGroups.first {
            return "\(firstGroup.displayName.prefix(2)) only"
        }
        return "-"
    }

    var tooltip: String {
        guard !row.screenshotGroups.isEmpty else {
            return "No screenshots captured."
        }

        let groupText = row.screenshotGroups
            .map { "\($0.displayName): \($0.screenshots.count)" }
            .joined(separator: ", ")

        if desiredGroup != nil {
            return groupText
        }

        return "Missing \(desiredPlatform.displayName) screenshots. Available: \(groupText)."
    }

    var foregroundStyle: Color {
        guard !row.screenshotGroups.isEmpty else { return .secondary }
        return desiredGroup == nil ? .orange : .secondary
    }

    var backgroundStyle: Color {
        foregroundStyle.opacity(0.12)
    }

    private var desiredGroup: ScreenshotPlatformGroup? {
        row.screenshotGroups.first { $0.platformRaw == desiredPlatform.rawValue }
    }
}

private struct KeywordRankingDateCell: View {
    let date: Date?

    var body: some View {
        Text(date.formattedTableDate)
            .font(.body.monospacedDigit())
            .foregroundStyle(date == nil ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct KeywordRankingTimeAgoCell: View {
    let date: Date?

    var body: some View {
        Group {
            if let date {
                Text(Self.relativeText(for: date))
                    .foregroundStyle(.primary)
            } else {
                Text("-")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    static func relativeText(for date: Date, now: Date = .now) -> String {
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(date)))

        if elapsedSeconds < 60 {
            return elapsedSeconds <= 5 ? "Just now" : "\(elapsedSeconds) seconds ago"
        }

        let elapsedMinutes = elapsedSeconds / 60
        if elapsedMinutes < 60 {
            return unitText(elapsedMinutes, singular: "minute")
        }

        let elapsedHours = elapsedMinutes / 60
        if elapsedHours < 24 {
            return unitText(elapsedHours, singular: "hour")
        }

        let elapsedDays = elapsedHours / 24
        if elapsedDays < 7 {
            return unitText(elapsedDays, singular: "day")
        }

        let elapsedWeeks = elapsedDays / 7
        if elapsedWeeks < 5 {
            return unitText(elapsedWeeks, singular: "week")
        }

        let elapsedMonths = elapsedDays / 30
        if elapsedMonths < 12 {
            return unitText(elapsedMonths, singular: "month")
        }

        let elapsedYears = elapsedDays / 365
        return unitText(elapsedYears, singular: "year")
    }

    private static func unitText(_ value: Int, singular: String) -> String {
        "\(value) \(singular)\(value == 1 ? "" : "s") ago"
    }
}

private extension Optional where Wrapped == Int {
    var formattedCompactCount: String {
        guard let self else { return "-" }
        return self.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

private extension Optional where Wrapped == Double {
    var formattedAverageRating: String {
        guard let self else { return "-" }
        return self.formatted(.number.precision(.fractionLength(1...2)))
    }
}

private extension Optional where Wrapped == Date {
    var formattedTableDate: String {
        guard let self else { return "-" }
        return self.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

private struct KeywordRankingListHeader: View {
    let keyword: String
    let storefrontCode: String
    let storefrontFlagEmoji: String?
    let searchedAt: Date?
    let resultCount: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apps in Ranking")
                    .font(.title2)
                    .bold()

                HStack(spacing: 8) {
                    Text(keyword)
                    Text(storefrontFlagEmoji?.nilIfEmpty ?? storefrontCode.uppercased())
                    if let searchedAt {
                        Text("Last updated \(KeywordRankingTimeAgoCell.relativeText(for: searchedAt))")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let resultCount {
                Text("\(resultCount) apps")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }
}

private struct KeywordRankingScreenshotExportApp {
    let rank: Int
    let appStoreID: Int64
    let name: String
    let groups: [ScreenshotPlatformGroup]

    init(_ row: KeywordRankingCatalogRow) {
        self.rank = row.position
        self.appStoreID = row.appStoreID
        self.name = row.appName
        self.groups = row.screenshotGroups
    }
}

private struct KeywordRankingScreenshotExportSummary {
    let downloadedCount: Int
    let failureCount: Int
    let skippedAppCount: Int
}

private final class KeywordRankingScreenshotExportService: Sendable {
    private let downloader: ScreenshotDownloadService

    init(downloader: ScreenshotDownloadService) {
        self.downloader = downloader
    }

    func exportRootURL(
        destinationDirectory: URL,
        keyword: String,
        storefront: String,
        date: Date
    ) -> URL {
        let dateString = Self.folderDateFormatter.string(from: date)
        let folderName = ScreenshotDownloadService.sanitizedPathComponent(
            "OpenASO Screenshots - \(keyword) - \(storefront.uppercased()) - \(dateString)",
            fallback: "OpenASO Screenshots"
        )
        return destinationDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    func export(
        apps: [KeywordRankingScreenshotExportApp],
        keyword: String,
        storefront: String,
        platform: AppPlatform,
        destinationDirectory: URL,
        exportRootURL: URL? = nil,
        progress: ScreenshotDownloadService.ProgressHandler? = nil
    ) async throws -> KeywordRankingScreenshotExportSummary {
        let rootURL = exportRootURL ?? self.exportRootURL(
            destinationDirectory: destinationDirectory,
            keyword: keyword,
            storefront: storefront,
            date: .now
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let plannedApps = Self.plannedApps(from: apps)
        let jobs = plannedApps.flatMap(\.screenshots).map(\.job)
        let result = await downloader.download(jobs: jobs, to: rootURL, progress: progress)
        let completedByID = Dictionary(uniqueKeysWithValues: result.completed.map { ($0.jobID, $0) })
        let failedByID = Dictionary(uniqueKeysWithValues: result.failed.map { ($0.jobID, $0) })
        let manifest = Self.manifest(
            keyword: keyword,
            storefront: storefront,
            platform: platform,
            rootURL: rootURL,
            plannedApps: plannedApps,
            completedByID: completedByID,
            failedByID: failedByID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: rootURL.appendingPathComponent("manifest.json"), options: [.atomic])

        return KeywordRankingScreenshotExportSummary(
            downloadedCount: result.completed.count,
            failureCount: result.failed.count,
            skippedAppCount: plannedApps.filter(\.screenshots.isEmpty).count
        )
    }

    private static func plannedApps(from apps: [KeywordRankingScreenshotExportApp]) -> [PlannedApp] {
        apps.map { app in
            let appDirectory = "\(Self.rankPrefix(app.rank)) - \(app.name) - id\(app.appStoreID)"
            var plannedScreenshots: [PlannedScreenshot] = []

            for group in app.groups {
                for screenshot in group.screenshots.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    let filenameStem = [
                        rankPrefix(screenshot.sortOrder + 1),
                        screenshot.displayTypeRaw,
                        dimensionText(width: screenshot.width, height: screenshot.height)
                    ]
                        .compactMap { $0 }
                        .joined(separator: " - ")
                    let jobID = screenshot.id
                    let job = ScreenshotDownloadJob(
                        id: jobID,
                        urlString: screenshot.urlString,
                        relativeDirectoryComponents: [appDirectory, group.platformRaw],
                        filenameStem: filenameStem,
                        metadata: [
                            "rank": String(app.rank),
                            "appStoreID": String(app.appStoreID),
                            "appName": app.name,
                            "platform": group.platformRaw,
                            "displayType": screenshot.displayTypeRaw,
                            "sortOrder": String(screenshot.sortOrder),
                            "width": screenshot.width.map(String.init) ?? "",
                            "height": screenshot.height.map(String.init) ?? ""
                        ]
                    )
                    plannedScreenshots.append(PlannedScreenshot(
                        job: job,
                        platformRaw: group.platformRaw,
                        displayTypeRaw: screenshot.displayTypeRaw,
                        sortOrder: screenshot.sortOrder,
                        width: screenshot.width,
                        height: screenshot.height
                    ))
                }
            }

            return PlannedApp(
                rank: app.rank,
                appStoreID: app.appStoreID,
                name: app.name,
                screenshots: plannedScreenshots
            )
        }
    }

    private static func manifest(
        keyword: String,
        storefront: String,
        platform: AppPlatform,
        rootURL: URL,
        plannedApps: [PlannedApp],
        completedByID: [String: DownloadedScreenshot],
        failedByID: [String: FailedScreenshotDownload]
    ) -> KeywordRankingScreenshotExportManifest {
        KeywordRankingScreenshotExportManifest(
            keyword: keyword,
            storefront: storefront.lowercased(),
            platform: platform.rawValue,
            exportedAt: .now,
            rootPath: rootURL.path,
            apps: plannedApps.map { app in
                let screenshots = app.screenshots.map { screenshot in
                    let completed = completedByID[screenshot.job.id]
                    let failed = failedByID[screenshot.job.id]
                    return KeywordRankingScreenshotExportManifest.Screenshot(
                        platform: screenshot.platformRaw,
                        displayType: screenshot.displayTypeRaw,
                        sortOrder: screenshot.sortOrder,
                        sourceURL: screenshot.job.urlString,
                        localPath: completed?.relativePath,
                        width: screenshot.width,
                        height: screenshot.height,
                        status: completed == nil ? "failed" : "downloaded",
                        error: failed?.errorDescription
                    )
                }
                return KeywordRankingScreenshotExportManifest.App(
                    rank: app.rank,
                    appStoreID: app.appStoreID,
                    name: app.name,
                    status: screenshots.isEmpty ? "no_screenshots" : "exported",
                    screenshots: screenshots
                )
            }
        )
    }

    private static func rankPrefix(_ value: Int) -> String {
        String(format: "%02d", value)
    }

    private static func dimensionText(width: Int?, height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)x\(height)"
    }

    private static var folderDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }

    private struct PlannedApp {
        let rank: Int
        let appStoreID: Int64
        let name: String
        let screenshots: [PlannedScreenshot]
    }

    private struct PlannedScreenshot {
        let job: ScreenshotDownloadJob
        let platformRaw: String
        let displayTypeRaw: String
        let sortOrder: Int
        let width: Int?
        let height: Int?
    }
}

private struct KeywordRankingScreenshotExportManifest: Codable {
    let keyword: String
    let storefront: String
    let platform: String
    let exportedAt: Date
    let rootPath: String
    let apps: [App]

    struct App: Codable {
        let rank: Int
        let appStoreID: Int64
        let name: String
        let status: String
        let screenshots: [Screenshot]
    }

    struct Screenshot: Codable {
        let platform: String
        let displayType: String
        let sortOrder: Int
        let sourceURL: String
        let localPath: String?
        let width: Int?
        let height: Int?
        let status: String
        let error: String?
    }
}

private struct KeywordRankingListFooter: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services

    let keyword: String
    @Binding var isShowingScreenshots: Bool
    let canDownloadScreenshots: Bool
    let downloadTopTenScreenshots: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if services.screenshotDownloadProgressStore.activeDownload != nil {
                ScreenshotDownloadStatusView(progressStore: services.screenshotDownloadProgressStore, placement: .sheet)
            }

            HStack {
                Text("Keyword: \(keyword)")
                    .foregroundStyle(.secondary)

                TertiaryActionButton(
                    isShowingScreenshots ? "Hide Screenshots" : "Show Screenshots",
                    systemImage: isShowingScreenshots ? "photo.stack.fill" : "photo.stack",
                    helpText: isShowingScreenshots ? "Hide screenshot rows" : "Show screenshot rows"
                ) {
                    isShowingScreenshots.toggle()
                }

                TertiaryActionButton(
                    "Download Screenshots for Top 10 Apps",
                    systemImage: "arrow.down.square",
                    helpText: "Download stored screenshots for the top 10 ranking apps"
                ) {
                    downloadTopTenScreenshots()
                }
                .disabled(!canDownloadScreenshots || services.screenshotDownloadProgressStore.isDownloading)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmedValue = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
