import SwiftData
import SwiftUI

struct AddAppSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @Query(sort: [SortDescriptor(\Storefront.name, order: .forward)])
    private var storefronts: [Storefront]

    @State private var searchTerm = ""
    @State private var appStoreIDText = ""
    @State private var storefrontCode = "us"
    @State private var searchResults: [ResolvedApp] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    init(
        searchTerm: String = "",
        appStoreIDText: String = "",
        storefrontCode: String = "us",
        searchResults: [ResolvedApp] = []
    ) {
        _searchTerm = State(initialValue: searchTerm)
        _appStoreIDText = State(initialValue: appStoreIDText)
        _storefrontCode = State(initialValue: storefrontCode)
        _searchResults = State(initialValue: searchResults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Tracked App")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Picker("Country", selection: $storefrontCode) {
                    ForEach(storefronts) { storefront in
                        Text(storefront.title)
                            .tag(storefront.code)
                    }
                }

                HStack {
                    TextField("Search app name", text: $searchTerm)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .font(.body)
                        .onSubmit {
                            performSearch()
                        }

                    Button("Search") {
                        performSearch()
                    }
                    .controlSize(.large)
                    .disabled(searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                }

                HStack {
                    TextField("Direct App Store ID", text: $appStoreIDText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .font(.body)
                        .onSubmit {
                            addByAppStoreID()
                        }

                    Button("Add by ID") {
                        addByAppStoreID()
                    }
                    .controlSize(.large)
                    .disabled(appStoreIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                }

                Text("Search by name to pick the exact app or paste the numeric App Store ID for a direct lookup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            resultsView
                .frame(idealHeight: 280, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, -AddAppSheetLayout.sheetPadding)

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding(AddAppSheetLayout.sheetPadding)
        .frame(minWidth: 720, idealHeight: 540)
        .presentationSizing(.fitted)
    }

    private var resultsView: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(searchResults) { result in
                        ResultRow(
                            result: result,
                            storefrontCode: storefrontCode,
                            addAction: {
                                Task {
                                    await addResolvedApp(result, source: "search")
                                }
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            if isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, searchResults.isEmpty ? 24 : 8)
            }
        }
    }

    private func performSearch() {
        let trimmedSearchTerm = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchTerm.isEmpty, !isSearching else {
            return
        }

        isSearching = true
        errorMessage = nil

        Task {
            do {
                let resolvedApps = try await services.appResolver.searchApps(
                    named: trimmedSearchTerm,
                    storefrontCode: storefrontCode,
                    limit: 25
                )
                searchResults = resolvedApps

                if resolvedApps.isEmpty {
                    errorMessage = OpenASOError.appNotFound.localizedDescription
                }
            } catch {
                errorMessage = OpenASOError.map(error).localizedDescription
            }
            isSearching = false
        }
    }

    private func addByAppStoreID() {
        guard !isSearching else {
            return
        }

        let trimmedAppStoreID = appStoreIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let appStoreID = Int64(trimmedAppStoreID) else {
            errorMessage = OpenASOError.invalidAppStoreID.localizedDescription
            return
        }

        isSearching = true
        errorMessage = nil

        Task {
            do {
                let resolvedApp = try await services.appResolver.resolve(appStoreID: appStoreID, storefrontCode: storefrontCode)
                await addResolvedApp(resolvedApp, source: "manual")
            } catch {
                errorMessage = OpenASOError.map(error).localizedDescription
            }
            isSearching = false
        }
    }

    @MainActor
    private func addResolvedApp(_ resolvedApp: ResolvedApp, source: String) async {
        let appStoreID = resolvedApp.appStoreID
        let descriptor = FetchDescriptor<TrackedApp>(
            predicate: #Predicate { trackedApp in
                trackedApp.appStoreID == appStoreID
            }
        )

        do {
            let storeApp = try services.appCatalogService.upsertStoreApp(
                from: resolvedApp,
                storefrontCode: storefrontCode,
                in: modelContext
            )

            let didCreateTrackedApp: Bool
            let trackedAppSnapshot: AppDetailRefreshAppSnapshot
            if let existing = try modelContext.fetch(descriptor).first {
                existing.storeApp = storeApp
                existing.bundleID = resolvedApp.bundleID
                existing.name = resolvedApp.name
                existing.subtitle = resolvedApp.subtitle
                existing.sellerName = resolvedApp.sellerName
                didCreateTrackedApp = false
                trackedAppSnapshot = AppDetailRefreshAppSnapshot(
                    appStoreID: existing.appStoreID,
                    bundleID: existing.bundleID,
                    name: existing.name,
                    subtitle: existing.subtitle,
                    sellerName: existing.sellerName,
                    defaultPlatform: existing.defaultPlatform
                )
            } else {
                let sidebarSortOrder = try modelContext.fetch(FetchDescriptor<TrackedApp>())
                    .filter { $0.folder == nil }
                    .map(\.sidebarSortOrder)
                    .max()
                    .map { $0 + 1 } ?? 0
                let trackedApp = TrackedApp(
                    appStoreID: resolvedApp.appStoreID,
                    storeApp: storeApp,
                    sidebarSortOrder: sidebarSortOrder
                )
                modelContext.insert(trackedApp)
                didCreateTrackedApp = true
                trackedAppSnapshot = AppDetailRefreshAppSnapshot(
                    appStoreID: trackedApp.appStoreID,
                    bundleID: trackedApp.bundleID,
                    name: trackedApp.name,
                    subtitle: trackedApp.subtitle,
                    sellerName: trackedApp.sellerName,
                    defaultPlatform: trackedApp.defaultPlatform
                )
            }

            try modelContext.save()
            if didCreateTrackedApp {
                services.analyticsService.capture(.trackedAppAdded(platform: resolvedApp.defaultPlatform, source: source))
                refreshRatingsAndReviewsForNewApp(trackedAppSnapshot)
            }
            dismiss()
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    private func refreshRatingsAndReviewsForNewApp(_ app: AppDetailRefreshAppSnapshot) {
        guard let refreshService = services.appDetailRefreshService else {
            return
        }
        let storefrontCodes = allStorefrontCodesForRatingsAndReviewsRefresh()

        let request = AppDetailRefreshRequest(
            app: app,
            workspace: .ratings,
            storefrontSelection: .all(codes: storefrontCodes),
            trackIdentityKeys: [],
            trigger: "after_add_app",
            refreshKeywords: false,
            refreshMetrics: false,
            refreshRatings: true,
            refreshReviews: true,
            recordsRatingsReviewsRefresh: false,
            popularityContextAppStoreID: services.settingsStore.popularityContextAppStoreID,
            appleAdsWebSession: services.appleAdsWebSessionStore.recoverSessionIfNeeded(),
            appStoreConnectCredentials: services.appStoreConnectCredentialStore.credentials
        )

        Task(priority: .utility) {
            _ = await refreshService.refresh(request)
        }
    }

    private func allStorefrontCodesForRatingsAndReviewsRefresh() -> [String] {
        let queryCodes = normalizedStorefrontCodes(storefronts.map(\.code))
        if !queryCodes.isEmpty {
            return queryCodes
        }

        if let bundledStorefronts = try? services.storefrontCatalog.bundledStorefronts() {
            let bundledCodes = normalizedStorefrontCodes(bundledStorefronts.map(\.code))
            if !bundledCodes.isEmpty {
                return bundledCodes
            }
        }

        return normalizedStorefrontCodes([storefrontCode])
    }

    private func normalizedStorefrontCodes(_ codes: [String]) -> [String] {
        Array(Set(codes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted()
    }
}

private struct ResultRow: View {
    let result: ResolvedApp
    let storefrontCode: String
    let addAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AppIconView(
                    appStoreID: result.appStoreID,
                    storefrontCode: storefrontCode,
                    preferredIconURLString: result.iconURLString,
                    size: 44,
                    cornerRadius: 10
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.name)
                        .font(.headline)
                    Text(result.sellerName ?? "Unknown Seller")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "App ID \(result.appStoreID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Add", action: addAction)
                    .controlSize(.regular)
            }
            .padding(.vertical, 10)
            .padding(.leading, AddAppSheetLayout.sheetPadding)
            .padding(.trailing, AddAppSheetLayout.sheetPadding)

            Divider()
                .padding(.leading, AddAppSheetLayout.sheetPadding + 54)
                .padding(.trailing, AddAppSheetLayout.sheetPadding)
        }
    }
}

private enum AddAppSheetLayout {
    static let sheetPadding: CGFloat = 24
}

#Preview("Add Tracked App") {
    AddAppSheetPreview()
}

private struct AddAppSheetPreview: View {
    private let previewContainer: OpenASOPreviewContainer<Void>

    init() {
        self.previewContainer = OpenASOPreviewContainer(seed: Self.seed)
    }

    var body: some View {
        AddAppSheet(
            searchTerm: "atten",
            appStoreIDText: "6448311069",
            searchResults: Self.previewResults
        )
        .openASOPreviewEnvironment(previewContainer)
        .frame(width: 720, height: 540)
        .padding(32)
    }

    private static var previewResults: [ResolvedApp] {
        [
            ResolvedApp(
                appStoreID: 6608976383,
                bundleID: "com.thirdtech.atten",
                name: "Atten - App Blocker",
                sellerName: "Third Tech Ltd",
                defaultPlatform: .iphone
            ),
            ResolvedApp(
                appStoreID: 1721692932,
                bundleID: "com.iris.attenix",
                name: "AttenIX App",
                sellerName: "iris eliezer",
                defaultPlatform: .iphone
            ),
            ResolvedApp(
                appStoreID: 1471508186,
                bundleID: "com.ezmatch.app",
                name: "EZMatch: 18+ Dating,Meet&Flirt",
                sellerName: "QUANG VU MINH",
                defaultPlatform: .iphone
            ),
            ResolvedApp(
                appStoreID: 6467501613,
                bundleID: "com.impofit.embassy360",
                name: "Embassy360-Smartcheck_Atten",
                sellerName: "IMPOF IT SOLUTIONS PRIVATE LIMITED",
                defaultPlatform: .iphone
            )
        ]
    }

    private static func seed(in modelContext: ModelContext) {
        [
            Storefront(code: "us", name: "United States", flagEmoji: "🇺🇸", languageCode: "en-US"),
            Storefront(code: "gb", name: "United Kingdom", flagEmoji: "🇬🇧", languageCode: "en-GB"),
            Storefront(code: "ca", name: "Canada", flagEmoji: "🇨🇦", languageCode: "en-CA")
        ].forEach(modelContext.insert)

        for result in previewResults {
            modelContext.insert(
                StoreApp(
                    appStoreID: result.appStoreID,
                    bundleID: result.bundleID,
                    name: result.name,
                    sellerName: result.sellerName,
                    iconURLString: result.iconURLString,
                    defaultPlatform: result.defaultPlatform
                )
            )
        }

        try? modelContext.save()
    }
}
