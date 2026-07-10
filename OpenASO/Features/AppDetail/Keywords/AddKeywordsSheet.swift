import SwiftData
import SwiftUI

struct AddKeywordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @Query(sort: [SortDescriptor(\Storefront.name, order: .forward)])
    private var storefronts: [Storefront]

    @Query private var trackedKeywords: [TrackedAppKeyword]
    @AppStorage("globalTrackedKeywordTemplatesJSON") private var globalKeywordTemplatesJSON = "[]"

    let trackedApp: TrackedApp
    let externalRefreshInProgress: Bool
    let queueKeywordAdd: (KeywordAddRequest) -> Void

    @State private var keywordInput = ""
    @State private var selectedPlatform: AppPlatform
    @State private var selectedStorefrontCodes: Set<String> = ["us"]
    @State private var selectedGlobalKeywordIDs = Set<String>()
    @State private var savesInputToGlobalKeywords = true
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
                SortDescriptor(\TrackedAppKeyword.term, order: .forward),
            ]
        )
        _selectedPlatform = State(initialValue: trackedApp.defaultPlatform)
        _selectedStorefrontCodes = State(initialValue: [
            Self.defaultStorefrontCode(from: initialStorefrontCode)
        ])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Keywords")
                .font(.title2)
                .bold()

            Text(
                "Paste one keyword per line or separate them with commas. Each keyword will be tracked for every selected country. Reusable keywords can be applied without copy-paste."
            )
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
                .frame(minHeight: 140)
                .disabled(isInputLocked)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                }

            Toggle(
                "Save pasted keywords to reusable global list", isOn: $savesInputToGlobalKeywords
            )
            .disabled(isInputLocked)

            reusableKeywordsSection

            Text("Countries")
                .font(.headline)

            AddKeywordsStorefrontSearchField(storefrontSearchText: $storefrontSearchText)
                .disabled(isInputLocked)

            List(filteredStorefronts, id: \.code) { storefront in
                Toggle(isOn: storefrontBinding(for: storefront.code)) {
                    HStack {
                        Text(storefront.title)
                        Spacer()
                        Text(keywordCount(for: storefront.code).formatted())
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
                Text(
                    "A refresh is running. Add Tracks will queue this change in the background and close this sheet."
                )
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
        .frame(minWidth: 780, minHeight: 780)
    }

    @ViewBuilder
    private var reusableKeywordsSection: some View {
        let keywords = reusableKeywordsForSelection
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reusable Keywords")
                    .font(.headline)
                Spacer()
                if !keywords.isEmpty {
                    Button("Select All") {
                        selectedGlobalKeywordIDs.formUnion(keywords.map(\.id))
                    }
                    .disabled(isInputLocked)
                    Button("Clear") {
                        selectedGlobalKeywordIDs.removeAll()
                    }
                    .disabled(isInputLocked || selectedGlobalKeywordIDs.isEmpty)
                }
            }

            if keywords.isEmpty {
                Text("No reusable keywords match the selected device and countries yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                List(keywords) { keyword in
                    Toggle(isOn: reusableKeywordBinding(for: keyword.id)) {
                        HStack(spacing: 10) {
                            Text(keyword.term)
                            Spacer()
                            Text(keyword.storefront.uppercased())
                                .foregroundStyle(.secondary)
                            Text(keyword.platform.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 110, maxHeight: 150)
                .disabled(isInputLocked)
            }
        }
    }

    private var filteredStorefronts: [Storefront] {
        let normalizedSearch = storefrontSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingStorefronts = storefronts.filter { storefront in
            guard !normalizedSearch.isEmpty else { return true }
            return storefront.title.localizedCaseInsensitiveContains(normalizedSearch)
                || storefront.code.localizedCaseInsensitiveContains(normalizedSearch)
        }

        return matchingStorefronts.sorted { lhs, rhs in
            let lhsCount = keywordCount(for: lhs.code)
            let rhsCount = keywordCount(for: rhs.code)
            if lhsCount == rhsCount {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhsCount > rhsCount
        }
    }

    private var keywordCountsByStorefront: [String: Int] {
        Dictionary(
            grouping: trackedKeywords.filter { $0.platform == selectedPlatform }, by: \.storefront
        )
        .mapValues(\.count)
    }

    private var globalKeywordTemplates: [GlobalTrackedKeywordTemplate] {
        GlobalTrackedKeywordTemplate.decodeList(from: globalKeywordTemplatesJSON)
    }

    private var reusableKeywordsForSelection: [GlobalTrackedKeywordTemplate] {
        globalKeywordTemplates
            .filter { template in
                template.platform == selectedPlatform
                    && selectedStorefrontCodes.contains(template.storefront)
            }
            .sorted { lhs, rhs in
                if lhs.storefront == rhs.storefront {
                    return lhs.term.localizedStandardCompare(rhs.term) == .orderedAscending
                }
                return lhs.storefront < rhs.storefront
            }
    }

    private func keywordCount(for storefrontCode: String) -> Int {
        keywordCountsByStorefront[
            storefrontCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), default: 0]
    }

    private func storefrontBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { selectedStorefrontCodes.contains(code) },
            set: { isSelected in
                if isSelected {
                    selectedStorefrontCodes.insert(code)
                } else {
                    selectedStorefrontCodes.remove(code)
                    selectedGlobalKeywordIDs.subtract(
                        globalKeywordTemplates.filter { $0.storefront == code }.map(\.id))
                }
            }
        )
    }

    private func reusableKeywordBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedGlobalKeywordIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedGlobalKeywordIDs.insert(id)
                } else {
                    selectedGlobalKeywordIDs.remove(id)
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
        case .preparing, .refreshingKeywords, .refreshingMetrics, .refreshingRatings,
            .refreshingReviews, .refreshingPricing, .finishing:
            return true
        }
    }

    private func addTracks() {
        guard !isSubmitting else {
            return
        }

        let candidates = keywordCandidates
        guard !candidates.isEmpty else {
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
            queueKeywordAdd(
                KeywordAddRequest(
                    candidates: candidates
                ))
            errorMessage = nil
            statusMessage =
                "Queued. These keywords will be added after the current refresh finishes."
            dismiss()
            return
        }

        addTracks(
            candidates: candidates, typedKeywords: parsedKeywords, storefrontCodes: storefrontCodes,
            platform: platform)
    }

    private func addTracks(
        candidates: [KeywordAddCandidate],
        typedKeywords: [String],
        storefrontCodes: Set<String>,
        platform: AppPlatform
    ) {
        isSubmitting = true
        errorMessage = nil
        statusMessage = nil

        let existingKeys: Set<String>
        do {
            existingKeys = try existingDuplicateKeys()
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
            isSubmitting = false
            return
        }
        var mutableExistingKeys = existingKeys
        var insertedCount = 0
        var insertedTracks: [TrackedAppKeyword] = []

        for candidate in candidates {
            let identityKey = duplicateKey(
                term: candidate.keyword, storefront: candidate.storefrontCode,
                platform: candidate.platform)

            guard !mutableExistingKeys.contains(identityKey) else { continue }

            let query: KeywordQuery
            do {
                query = try KeywordQuery.fetchOrInsert(
                    term: candidate.keyword,
                    storefront: candidate.storefrontCode,
                    platform: candidate.platform,
                    in: modelContext
                )
            } catch {
                errorMessage = OpenASOError.map(error).localizedDescription
                isSubmitting = false
                return
            }

            let track = TrackedAppKeyword(
                term: candidate.keyword,
                storefront: candidate.storefrontCode,
                platform: candidate.platform,
                trackedApp: trackedApp,
                query: query
            )

            trackedApp.keywordTracks.append(track)
            modelContext.insert(track)
            mutableExistingKeys.insert(identityKey)
            insertedCount += 1
            insertedTracks.append(track)
        }

        guard insertedCount > 0 else {
            errorMessage = "All of those keyword and country combinations already exist."
            isSubmitting = false
            return
        }

        if savesInputToGlobalKeywords, !typedKeywords.isEmpty {
            persistGlobalKeywords(
                keywords: typedKeywords, storefrontCodes: storefrontCodes, platform: platform)
        }

        do {
            try modelContext.save()
            services.analyticsService.capture(
                .keywordAdded(
                    keywordCount: Set(candidates.map(\.keyword.normalizedKeywordKey)).count,
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

    private func duplicateKey(term: String, storefront: String, platform: AppPlatform) -> String {
        [
            term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            platform.rawValue,
        ].joined(separator: "::")
    }

    private func existingDuplicateKeys() throws -> Set<String> {
        let appStoreID = trackedApp.appStoreID
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.appStoreID == appStoreID
            }
        )
        return Set(
            try modelContext.fetch(descriptor)
                .map {
                    duplicateKey(term: $0.term, storefront: $0.storefront, platform: $0.platform)
                }
        )
    }

    private var parsedKeywords: [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        let parts =
            keywordInput
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

    private var selectedGlobalKeywords: [GlobalTrackedKeywordTemplate] {
        globalKeywordTemplates.filter { selectedGlobalKeywordIDs.contains($0.id) }
    }

    private var keywordCandidates: [KeywordAddCandidate] {
        var seen = Set<String>()
        var candidates: [KeywordAddCandidate] = []

        for storefrontCode in selectedStorefrontCodes.sorted() {
            for keyword in parsedKeywords {
                let candidate = KeywordAddCandidate(
                    keyword: keyword,
                    storefrontCode: storefrontCode,
                    platform: selectedPlatform
                )
                guard seen.insert(candidate.identityKey).inserted else { continue }
                candidates.append(candidate)
            }
        }

        for template in selectedGlobalKeywords {
            let candidate = KeywordAddCandidate(
                keyword: template.term,
                storefrontCode: template.storefront,
                platform: template.platform
            )
            guard seen.insert(candidate.identityKey).inserted else { continue }
            candidates.append(candidate)
        }

        return candidates
    }

    private func persistGlobalKeywords(
        keywords: [String], storefrontCodes: Set<String>, platform: AppPlatform
    ) {
        var templates = globalKeywordTemplates
        var existingIDs = Set(templates.map(\.id))

        for storefrontCode in storefrontCodes.sorted() {
            for keyword in keywords {
                let template = GlobalTrackedKeywordTemplate(
                    term: keyword,
                    storefront: storefrontCode,
                    platform: platform
                )
                guard existingIDs.insert(template.id).inserted else { continue }
                templates.append(template)
            }
        }

        globalKeywordTemplatesJSON = GlobalTrackedKeywordTemplate.encodeList(templates)
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
    let candidates: [KeywordAddCandidate]

    var keywords: [String] {
        Array(Set(candidates.map(\.keyword))).sorted()
    }

    var storefrontCodes: Set<String> {
        Set(candidates.map(\.storefrontCode))
    }
}

struct KeywordAddCandidate: Hashable {
    let keyword: String
    let storefrontCode: String
    let platform: AppPlatform

    var identityKey: String {
        [
            keyword.normalizedKeywordKey,
            storefrontCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            platform.rawValue,
        ].joined(separator: "::")
    }
}

struct GlobalTrackedKeywordTemplate: Codable, Identifiable, Hashable {
    let term: String
    let storefront: String
    let platformRaw: String
    let createdAt: Date

    init(term: String, storefront: String, platform: AppPlatform, createdAt: Date = .now) {
        self.term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        self.storefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.platformRaw = platform.rawValue
        self.createdAt = createdAt
    }

    var id: String {
        [
            term.normalizedKeywordKey,
            storefront,
            platformRaw,
        ].joined(separator: "::")
    }

    var platform: AppPlatform {
        AppPlatform(rawValue: platformRaw) ?? .iphone
    }

    static func decodeList(from json: String) -> [GlobalTrackedKeywordTemplate] {
        guard let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([GlobalTrackedKeywordTemplate].self, from: data)) ?? []
    }

    static func encodeList(_ templates: [GlobalTrackedKeywordTemplate]) -> String {
        guard let data = try? JSONEncoder().encode(templates),
            let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }
}

struct ManageKeywordListsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @Query(sort: [SortDescriptor(\Storefront.name, order: .forward)])
    private var storefronts: [Storefront]

    @Query private var localKeywords: [TrackedAppKeyword]
    @AppStorage("globalTrackedKeywordTemplatesJSON") private var globalKeywordTemplatesJSON = "[]"

    let trackedApp: TrackedApp

    @State private var selectedScope = KeywordListScope.local
    @State private var editingEntry: KeywordListEditingEntry?
    @State private var resetConfirmation: KeywordListResetConfirmation?
    @State private var errorMessage: String?

    init(trackedApp: TrackedApp) {
        self.trackedApp = trackedApp

        let appStoreID = trackedApp.appStoreID
        _localKeywords = Query(
            filter: #Predicate<TrackedAppKeyword> { track in
                track.appStoreID == appStoreID
            },
            sort: [
                SortDescriptor(\TrackedAppKeyword.storefront, order: .forward),
                SortDescriptor(\TrackedAppKeyword.platformRaw, order: .forward),
                SortDescriptor(\TrackedAppKeyword.term, order: .forward),
            ]
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Keyword Lists")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            Picker("List", selection: $selectedScope) {
                ForEach(KeywordListScope.allCases) { scope in
                    Text(scope.title)
                        .tag(scope)
                }
            }
            .pickerStyle(.segmented)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            switch selectedScope {
            case .local:
                localKeywordList
            case .global:
                globalKeywordList
            }
        }
        .padding(24)
        .frame(minWidth: 820, minHeight: 620)
        .sheet(item: $editingEntry) { entry in
            KeywordListEntryEditor(
                title: entry.title,
                draft: entry.draft,
                allowsMultipleKeywords: entry.allowsMultipleKeywords,
                storefronts: editorStorefronts(including: entry.draft.storefront)
            ) { draft in
                save(entry: entry, draft: draft)
            }
        }
        .alert(item: $resetConfirmation) { confirmation in
            Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text(confirmation.buttonTitle)) {
                    reset(confirmation)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var localKeywordList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(localKeywords.count.formatted()) tracked keywords for \(trackedApp.name)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    resetConfirmation = .local(appName: trackedApp.name, count: localKeywords.count)
                } label: {
                    Label("Reset App Keywords", systemImage: "trash")
                }
                .disabled(localKeywords.isEmpty)
            }

            if localKeywords.isEmpty {
                ContentUnavailableView(
                    "No Local Keywords",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Use Add Keywords to create app-specific tracked keywords.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(localKeywords) { track in
                    KeywordListRow(
                        title: track.term,
                        storefront: storeTitle(for: track.storefront),
                        platform: track.platform.displayName,
                        notes: track.notes,
                        editAction: {
                            editingEntry = .local(track)
                        },
                        deleteAction: {
                            deleteLocalKeyword(track)
                        }
                    )
                }
                .listStyle(.plain)
            }
        }
    }

    private var globalKeywordList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(globalKeywordTemplates.count.formatted()) reusable global keywords")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    editingEntry = .newGlobal(defaultPlatform: trackedApp.defaultPlatform)
                } label: {
                    Label("Add Global Keyword", systemImage: "plus")
                }
                Button(role: .destructive) {
                    resetConfirmation = .global(count: globalKeywordTemplates.count)
                } label: {
                    Label("Reset Global Keywords", systemImage: "trash")
                }
                .disabled(globalKeywordTemplates.isEmpty)
            }

            if globalKeywordTemplates.isEmpty {
                ContentUnavailableView(
                    "No Global Keywords",
                    systemImage: "globe",
                    description: Text("Add reusable keywords here or save pasted keywords from Add Keywords.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(globalKeywordTemplates) { template in
                    KeywordListRow(
                        title: template.term,
                        storefront: storeTitle(for: template.storefront),
                        platform: template.platform.displayName,
                        notes: nil,
                        editAction: {
                            editingEntry = .global(template)
                        },
                        deleteAction: {
                            deleteGlobalKeyword(template)
                        }
                    )
                }
                .listStyle(.plain)
            }
        }
    }

    private var globalKeywordTemplates: [GlobalTrackedKeywordTemplate] {
        GlobalTrackedKeywordTemplate.decodeList(from: globalKeywordTemplatesJSON)
            .sorted { lhs, rhs in
                if lhs.storefront != rhs.storefront {
                    return lhs.storefront < rhs.storefront
                }
                if lhs.platformRaw != rhs.platformRaw {
                    return lhs.platformRaw < rhs.platformRaw
                }
                return lhs.term.localizedStandardCompare(rhs.term) == .orderedAscending
            }
    }

    private func save(entry: KeywordListEditingEntry, draft: KeywordListDraft) {
        errorMessage = nil
        let normalizedDraft = draft.normalized

        guard !normalizedDraft.term.isEmpty else {
            errorMessage = "Enter a keyword."
            return
        }
        guard !normalizedDraft.storefront.isEmpty else {
            errorMessage = "Choose a country."
            return
        }

        do {
            switch entry.source {
            case .local(let track):
                try saveLocalKeyword(track, draft: normalizedDraft)
            case .global(let existingID):
                try saveGlobalKeywords(existingID: existingID, draft: normalizedDraft)
            }
            editingEntry = nil
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    private func saveLocalKeyword(_ track: TrackedAppKeyword, draft: KeywordListDraft) throws {
        let duplicateKey = localDuplicateKey(
            term: draft.term,
            storefront: draft.storefront,
            platform: draft.platform
        )
        let hasDuplicate = localKeywords.contains { otherTrack in
            otherTrack.persistentModelID != track.persistentModelID
                && localDuplicateKey(
                    term: otherTrack.term,
                    storefront: otherTrack.storefront,
                    platform: otherTrack.platform
                ) == duplicateKey
        }
        guard !hasDuplicate else {
            throw OpenASOError.providerUnavailable(
                "That keyword, country, and device already exist for this app.")
        }

        let didChangeTrackingTarget = localDuplicateKey(
            term: track.term,
            storefront: track.storefront,
            platform: track.platform
        ) != duplicateKey

        let query = try KeywordQuery.fetchOrInsert(
            term: draft.term,
            storefront: draft.storefront,
            platform: draft.platform,
            in: modelContext
        )

        if didChangeTrackingTarget {
            deleteSnapshots(for: track)
            track.rankingAppCount = nil
            track.lastRefreshAt = nil
            track.statusMessage = "Edited. Refresh to collect rankings for the new keyword."
        }

        track.term = draft.term
        track.storefront = draft.storefront
        track.platform = draft.platform
        track.identityKey = TrackedAppKeyword.makeIdentityKey(
            appStoreID: trackedApp.appStoreID,
            term: draft.term,
            storefront: draft.storefront,
            platform: draft.platform
        )
        track.query = query
        track.notes = draft.notes

        try modelContext.save()
    }

    private func saveGlobalKeyword(existingID: String?, draft: KeywordListDraft) throws {
        let replacement = GlobalTrackedKeywordTemplate(
            term: draft.term,
            storefront: draft.storefront,
            platform: draft.platform
        )
        var templates = globalKeywordTemplates.filter { $0.id != existingID }

        guard !templates.contains(where: { $0.id == replacement.id }) else {
            throw OpenASOError.providerUnavailable(
                "That global keyword, country, and device already exist.")
        }

        templates.append(replacement)
        globalKeywordTemplatesJSON = GlobalTrackedKeywordTemplate.encodeList(templates)
    }

    private func saveGlobalKeywords(existingID: String?, draft: KeywordListDraft) throws {
        let keywords = parsedKeywords(from: draft.term)
        guard !keywords.isEmpty else {
            throw OpenASOError.providerUnavailable("Enter at least one keyword.")
        }

        if existingID != nil || keywords.count == 1 {
            try saveGlobalKeyword(
                existingID: existingID,
                draft: KeywordListDraft(
                    term: keywords[0],
                    storefront: draft.storefront,
                    platform: draft.platform,
                    notes: draft.notes
                )
            )
            return
        }

        var templates = globalKeywordTemplates
        var existingIDs = Set(templates.map(\.id))
        var insertedCount = 0

        for keyword in keywords {
            let template = GlobalTrackedKeywordTemplate(
                term: keyword,
                storefront: draft.storefront,
                platform: draft.platform
            )
            guard existingIDs.insert(template.id).inserted else { continue }
            templates.append(template)
            insertedCount += 1
        }

        guard insertedCount > 0 else {
            throw OpenASOError.providerUnavailable(
                "Those global keywords already exist for this country and device.")
        }

        globalKeywordTemplatesJSON = GlobalTrackedKeywordTemplate.encodeList(templates)
    }

    private func deleteLocalKeyword(_ track: TrackedAppKeyword) {
        modelContext.delete(track)
        do {
            try modelContext.save()
            services.analyticsService.capture(.keywordDeleted(deleteCount: 1))
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    private func deleteGlobalKeyword(_ template: GlobalTrackedKeywordTemplate) {
        globalKeywordTemplatesJSON = GlobalTrackedKeywordTemplate.encodeList(
            globalKeywordTemplates.filter { $0.id != template.id }
        )
    }

    private func reset(_ confirmation: KeywordListResetConfirmation) {
        switch confirmation {
        case .local:
            resetLocalKeywords()
        case .global:
            resetGlobalKeywords()
        }
    }

    private func resetLocalKeywords() {
        let deleteCount = localKeywords.count
        for track in localKeywords {
            modelContext.delete(track)
        }

        do {
            try modelContext.save()
            services.analyticsService.capture(.keywordDeleted(deleteCount: deleteCount))
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    private func resetGlobalKeywords() {
        globalKeywordTemplatesJSON = "[]"
    }

    private func deleteSnapshots(for track: TrackedAppKeyword) {
        for snapshot in track.snapshots {
            for result in snapshot.topResults {
                modelContext.delete(result)
            }
            snapshot.topResults.removeAll()
            modelContext.delete(snapshot)
        }
        track.snapshots.removeAll()
    }

    private func localDuplicateKey(term: String, storefront: String, platform: AppPlatform) -> String {
        [
            term.normalizedKeywordKey,
            storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            platform.rawValue,
        ].joined(separator: "::")
    }

    private func parsedKeywords(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        let parts = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return parts.filter { keyword in
            seen.insert(keyword.normalizedKeywordKey).inserted
        }
    }

    private func storeTitle(for code: String) -> String {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let storefront = storefronts.first(where: { $0.code.lowercased() == normalizedCode }) else {
            return code.uppercased()
        }
        return storefront.title
    }

    private func editorStorefronts(including code: String) -> [KeywordListStorefrontOption] {
        var options = storefronts.map {
            KeywordListStorefrontOption(code: $0.code.lowercased(), title: $0.title)
        }
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedCode.isEmpty, !options.contains(where: { $0.code == normalizedCode }) {
            options.append(KeywordListStorefrontOption(code: normalizedCode, title: normalizedCode.uppercased()))
        }
        return options.sorted { lhs, rhs in
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

private enum KeywordListScope: CaseIterable, Identifiable {
    case local
    case global

    var id: String { title }

    var title: String {
        switch self {
        case .local:
            return "This App"
        case .global:
            return "Global"
        }
    }
}

private enum KeywordListResetConfirmation: Identifiable {
    case local(appName: String, count: Int)
    case global(count: Int)

    var id: String {
        switch self {
        case .local:
            return "local"
        case .global:
            return "global"
        }
    }

    var title: String {
        switch self {
        case .local:
            return "Reset App Keywords?"
        case .global:
            return "Reset Global Keywords?"
        }
    }

    var message: String {
        switch self {
        case .local(let appName, let count):
            return
                "Delete all \(count.formatted()) tracked keywords for \(appName). This removes the app's keyword tracks and ranking history. The app itself stays tracked."
        case .global(let count):
            return
                "Delete all \(count.formatted()) reusable global keywords. App-specific tracked keywords will not be deleted."
        }
    }

    var buttonTitle: String {
        switch self {
        case .local:
            return "Reset App Keywords"
        case .global:
            return "Reset Global Keywords"
        }
    }
}

private struct KeywordListRow: View {
    let title: String
    let storefront: String
    let platform: String
    let notes: String?
    let editAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(storefront)
                    Text(platform)
                    if let notes, !notes.isEmpty {
                        Text(notes)
                            .lineLimit(1)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Edit", action: editAction)
            Button(role: .destructive, action: deleteAction) {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .help("Delete Keyword")
        }
        .padding(.vertical, 6)
    }
}

private struct KeywordListEntryEditor: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let allowsMultipleKeywords: Bool
    let storefronts: [KeywordListStorefrontOption]
    let save: (KeywordListDraft) -> Void

    @State private var draft: KeywordListDraft

    init(
        title: String,
        draft: KeywordListDraft,
        allowsMultipleKeywords: Bool,
        storefronts: [KeywordListStorefrontOption],
        save: @escaping (KeywordListDraft) -> Void
    ) {
        self.title = title
        self.allowsMultipleKeywords = allowsMultipleKeywords
        self.storefronts = storefronts
        self.save = save
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3)
                .bold()

            if allowsMultipleKeywords {
                Text("Paste one keyword per line or separate them with commas.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $draft.term)
                    .font(.body.monospaced())
                    .frame(minHeight: 150)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2))
                    }
            } else {
                TextField("Keyword", text: $draft.term)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Country", selection: $draft.storefront) {
                ForEach(storefronts) { storefront in
                    Text(storefront.title)
                        .tag(storefront.code)
                }
            }

            Picker("Device", selection: $draft.platform) {
                ForEach(AppPlatform.allCases) { platform in
                    Label(platform.displayName, systemImage: platform.keywordSheetSystemImage)
                        .tag(platform)
                }
            }
            .pickerStyle(.segmented)

            TextField("Notes", text: $draft.notes, axis: .vertical)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    save(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

private struct KeywordListStorefrontOption: Identifiable, Hashable {
    let code: String
    let title: String

    var id: String { code }
}

private struct KeywordListDraft: Hashable {
    var term: String
    var storefront: String
    var platform: AppPlatform
    var notes: String

    var normalized: KeywordListDraft {
        KeywordListDraft(
            term: term.trimmingCharacters(in: .whitespacesAndNewlines),
            storefront: storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            platform: platform,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

private struct KeywordListEditingEntry: Identifiable {
    let id = UUID()
    let source: KeywordListEditingSource
    let title: String
    let draft: KeywordListDraft

    var allowsMultipleKeywords: Bool {
        if case .global(existingID: nil) = source {
            return true
        }
        return false
    }

    static func local(_ track: TrackedAppKeyword) -> KeywordListEditingEntry {
        KeywordListEditingEntry(
            source: .local(track),
            title: "Edit Local Keyword",
            draft: KeywordListDraft(
                term: track.term,
                storefront: track.storefront,
                platform: track.platform,
                notes: track.notes
            )
        )
    }

    static func global(_ template: GlobalTrackedKeywordTemplate) -> KeywordListEditingEntry {
        KeywordListEditingEntry(
            source: .global(existingID: template.id),
            title: "Edit Global Keyword",
            draft: KeywordListDraft(
                term: template.term,
                storefront: template.storefront,
                platform: template.platform,
                notes: ""
            )
        )
    }

    static func newGlobal(defaultPlatform: AppPlatform) -> KeywordListEditingEntry {
        KeywordListEditingEntry(
            source: .global(existingID: nil),
            title: "Add Global Keyword",
            draft: KeywordListDraft(
                term: "",
                storefront: "us",
                platform: defaultPlatform,
                notes: ""
            )
        )
    }
}

private enum KeywordListEditingSource {
    case local(TrackedAppKeyword)
    case global(existingID: String?)
}

extension String {
    fileprivate var normalizedKeywordKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension AppPlatform {
    fileprivate var keywordSheetSystemImage: String {
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
