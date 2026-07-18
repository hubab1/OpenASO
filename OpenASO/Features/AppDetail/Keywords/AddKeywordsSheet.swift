import SwiftData
import SwiftUI

struct AddKeywordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @Query(sort: [SortDescriptor(\Storefront.name, order: .forward)])
    private var storefronts: [Storefront]

    @Query private var trackedKeywords: [TrackedAppKeyword]

    let trackedApp: TrackedApp
    let externalRefreshInProgress: Bool
    let queueKeywordAdd: (KeywordAddRequest) -> Void

    @State private var keywordInput = ""
    @State private var selectedPlatform: AppPlatform
    @State private var selectedStorefrontCodes: Set<String> = ["us"]
    @State private var storefrontSearchText = ""
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isSubmitting = false

    init(
        trackedApp: TrackedApp,
        initialStorefrontCode: String? = nil,
        isRefreshInProgress: Bool = false,
        queueKeywordAdd: @escaping (KeywordAddRequest) -> Void = { _ in }
    ) {
        self.trackedApp = trackedApp
        self.externalRefreshInProgress = isRefreshInProgress
        self.queueKeywordAdd = queueKeywordAdd

        let appStoreID = trackedApp.appStoreID
        _trackedKeywords = Query(
            filter: #Predicate<TrackedAppKeyword> { track in
                track.appStoreID == appStoreID
            },
            sort: [
                SortDescriptor(\TrackedAppKeyword.storefront, order: .forward),
                SortDescriptor(\TrackedAppKeyword.platformRaw, order: .forward),
                SortDescriptor(\TrackedAppKeyword.term, order: .forward)
            ]
        )
        _selectedPlatform = State(initialValue: trackedApp.defaultPlatform)
        _selectedStorefrontCodes = State(initialValue: [Self.defaultStorefrontCode(from: initialStorefrontCode)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Keywords")
                .font(.title2)
                .bold()

            Text("Paste one keyword per line or separate them with commas. Each keyword will be tracked for every selected country.")
                .foregroundStyle(.secondary)

            Picker("Device", selection: $selectedPlatform) {
                ForEach(AppPlatform.allCases) { platform in
                    Label(platform.displayName, systemImage: platform.keywordSheetSystemImage)
                        .tag(platform)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isInputLocked)

            TextEditor(text: $keywordInput)
                .font(.body.monospaced())
                .frame(minHeight: 180)
                .disabled(isInputLocked)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                }

            Text("Countries")
                .font(.headline)

            AddKeywordsStorefrontSearchField(storefrontSearchText: $storefrontSearchText)
                .disabled(isInputLocked)

            List(filteredStorefronts) { storefront in
                Toggle(isOn: storefrontBinding(for: storefront.code)) {
                    HStack {
                        Text(storefront.title)
                        Spacer()
                        Text(storefront.keywordCount.formatted())
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 220)
            .disabled(isInputLocked)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            } else if isRefreshInProgress {
                Text("A refresh is running. Add Tracks will queue this change in the background and close this sheet.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button(addButtonTitle) {
                    addTracks()
                }
                .disabled(isSubmitting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 720)
    }

    private var filteredStorefronts: [AddKeywordsStorefrontProjection.Candidate] {
        AddKeywordsStorefrontProjection.candidates(
            storefronts: storefronts.map { storefront in
                (storefront.code, storefront.name, storefront.title)
            },
            trackedStorefrontCodes: trackedKeywords.compactMap { track in
                track.platform == selectedPlatform ? track.storefront : nil
            },
            searchText: storefrontSearchText
        )
    }

    private func storefrontBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { selectedStorefrontCodes.contains(code) },
            set: { isSelected in
                if isSelected {
                    selectedStorefrontCodes.insert(code)
                } else {
                    selectedStorefrontCodes.remove(code)
                }
            }
        )
    }

    private var isInputLocked: Bool {
        isSubmitting
    }

    private var addButtonTitle: String {
        if isRefreshInProgress {
            return "Queue Add Tracks"
        }
        return "Add Tracks"
    }

    private var isRefreshInProgress: Bool {
        if externalRefreshInProgress {
            return true
        }

        guard let refresh = services.refreshProgressStore.activeRefresh else {
            return false
        }

        switch refresh.phase {
        case .completed, .failed:
            return false
        case .preparing, .refreshingKeywords, .refreshingMetrics, .refreshingRatings, .refreshingReviews, .finishing:
            return true
        }
    }

    private func addTracks() {
        guard !isSubmitting else {
            return
        }

        let keywords = parsedKeywords
        guard !keywords.isEmpty else {
            errorMessage = "Enter at least one keyword."
            return
        }

        guard !selectedStorefrontCodes.isEmpty else {
            errorMessage = "Select at least one country."
            return
        }

        let storefrontCodes = selectedStorefrontCodes
        let platform = selectedPlatform
        if isRefreshInProgress {
            queueKeywordAdd(KeywordAddRequest(
                keywords: keywords,
                storefrontCodes: storefrontCodes,
                platform: platform
            ))
            errorMessage = nil
            statusMessage = "Queued. These keywords will be added after the current refresh finishes."
            dismiss()
            return
        }

        addTracks(keywords: keywords, storefrontCodes: storefrontCodes, platform: platform)
    }

    private func addTracks(keywords: [String], storefrontCodes: Set<String>, platform: AppPlatform) {
        isSubmitting = true
        errorMessage = nil
        statusMessage = nil

        let requestedCandidates = AddKeywordsQueryResolver.pendingCandidates(
            keywords: keywords,
            storefrontCodes: storefrontCodes,
            platform: platform,
            existingDuplicateKeys: []
        )

        let persistedIdentityKeys: Set<String>
        do {
            persistedIdentityKeys = try AddKeywordsQueryResolver.existingTrackIdentityKeys(
                for: requestedCandidates,
                appStoreID: trackedApp.appStoreID,
                in: modelContext
            )
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
            isSubmitting = false
            return
        }

        let localIdentityKeys = Set(
            trackedKeywords.map(\.identityKey) + trackedApp.keywordTracks.map(\.identityKey)
        )
        let existingIdentityKeys = persistedIdentityKeys.union(localIdentityKeys)
        let candidates = requestedCandidates.filter { candidate in
            !existingIdentityKeys.contains(
                candidate.trackIdentityKey(appStoreID: trackedApp.appStoreID)
            )
        }
        guard !candidates.isEmpty else {
            errorMessage = "All of those keyword and country combinations already exist."
            isSubmitting = false
            return
        }

        let queriesByKey: [String: KeywordQuery]
        do {
            queriesByKey = try AddKeywordsQueryResolver.resolveQueries(
                for: candidates,
                in: modelContext
            )
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
            isSubmitting = false
            return
        }

        var insertedTracks: [TrackedAppKeyword] = []

        for candidate in candidates {
            guard let query = queriesByKey[candidate.queryKey] else {
                errorMessage = OpenASOError.unexpectedResponse.localizedDescription
                isSubmitting = false
                return
            }

            let track = TrackedAppKeyword(
                term: candidate.term,
                storefront: candidate.storefront,
                platform: candidate.platform,
                trackedApp: trackedApp,
                query: query
            )

            trackedApp.keywordTracks.append(track)
            modelContext.insert(track)
            insertedTracks.append(track)
        }

        do {
            try modelContext.save()
            services.analyticsService.capture(.keywordAdded(
                keywordCount: keywords.count,
                storefrontCount: storefrontCodes.count
            ))
            dismiss()

            guard let refreshService = services.appDetailRefreshService else {
                isSubmitting = false
                return
            }

            let request = AppDetailRefreshRequest(
                app: AppDetailRefreshAppSnapshot(
                    appStoreID: trackedApp.appStoreID,
                    bundleID: trackedApp.bundleID,
                    name: trackedApp.name,
                    subtitle: trackedApp.subtitle,
                    sellerName: trackedApp.sellerName,
                    defaultPlatform: trackedApp.defaultPlatform
                ),
                workspace: .keywords,
                storefrontSelection: .all(codes: storefrontCodes.sorted()),
                trackIdentityKeys: insertedTracks.map(\.identityKey),
                trigger: "after_add_keyword",
                refreshRatings: false,
                refreshReviews: false,
                recordsRatingsReviewsRefresh: false,
                popularityContextAppStoreID: services.settingsStore.popularityContextAppStoreID,
                appleAdsWebSession: services.appleAdsWebSessionStore.session,
                appStoreConnectCredentials: services.appStoreConnectCredentialStore.credentials
            )

            Task(priority: .utility) {
                _ = await refreshService.refresh(request)
                await MainActor.run {
                    isSubmitting = false
                }
            }
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
            isSubmitting = false
        }
    }

    private var parsedKeywords: [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        let parts = keywordInput
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return parts.filter { keyword in
            let normalized = keyword.lowercased()
            let inserted = seen.insert(normalized).inserted
            return inserted
        }
    }

    private static func defaultStorefrontCode(from code: String?) -> String {
        let normalized = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, !normalized.isEmpty else {
            return "us"
        }
        return normalized
    }
}

struct KeywordAddRequest {
    let keywords: [String]
    let storefrontCodes: Set<String>
    let platform: AppPlatform
}

private extension AppPlatform {
    var keywordSheetSystemImage: String {
        switch self {
        case .iphone:
            return "iphone"
        case .ipad:
            return "ipad"
        case .mac:
            return "macbook"
        }
    }
}

private struct AddKeywordsStorefrontSearchField: View {
    @Binding var storefrontSearchText: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search countries", text: $storefrontSearchText)
                .textFieldStyle(.plain)

            if !storefrontSearchText.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Country Search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        }
    }

    private func clearSearch() {
        storefrontSearchText = ""
    }
}
