import Observation
import SwiftUI

@MainActor
@Observable
final class AppleAdsPlatformWorkspaceModel {
    enum Page: String, CaseIterable, Identifiable {
        case popularity = "Search Popularity"
        case campaigns = "Campaigns"
        case apps = "Owned Apps"

        var id: String { rawValue }
    }

    private let api: any AppleAdsPlatformAPI
    private let credentialStore: AppleAdsCredentialStore

    var page = Page.popularity
    var connection: AppleAdsPlatformConnection?
    var selectedAdAccountID = ""
    var campaigns: [AppleAdsPlatformCampaignSummary] = []
    var apps: [AppleAdsPromotedApp] = []
    var popularityRows: [AppleAdsSearchTermPopularity] = []
    var searchQuery = ""
    var searchTermsText = "productivity, focus, habits"
    var countryOrRegion = "US"
    var recentWeekCount = 4
    var isLoading = false
    var errorMessage: String?

    init(api: any AppleAdsPlatformAPI, credentialStore: AppleAdsCredentialStore) {
        self.api = api
        self.credentialStore = credentialStore
    }

    var coverage: AppleAdsPlatformCoverage { api.coverage }
    var isConfigured: Bool { credentialStore.apiCredentials.canVerify }

    func load() async {
        guard !isLoading else { return }
        guard isConfigured else {
            errorMessage = "Complete Apple Ads Platform API setup in Settings first."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let connection = try await api.verify(credentials: credentialStore.apiCredentials)
            self.connection = connection
            selectedAdAccountID = String(connection.selectedAdAccountID)
            try credentialStore.saveAPICredentials(
                connection.applying(to: credentialStore.apiCredentials)
            )
            try await loadSelectedPage()
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    func selectAccount() async {
        guard let accountID = Int64(selectedAdAccountID), accountID > 0 else { return }
        var credentials = credentialStore.apiCredentials
        credentials.adAccountID = String(accountID)

        do {
            try credentialStore.saveAPICredentials(credentials)
            await loadFresh()
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    func searchApps() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            apps = try await api.searchOwnedApps(
                named: query.isEmpty ? nil : query,
                using: credentialStore.apiCredentials,
                limit: 100
            )
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    func searchPopularity() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let searchTerms = searchTermsText
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !searchTerms.isEmpty else {
                throw OpenASOError.providerUnavailable("Enter at least one search term.")
            }
            popularityRows = try await api.searchTermPopularity(
                for: searchTerms,
                countryOrRegion: countryOrRegion,
                window: .recentCompletedWeeks(
                    asOf: .now,
                    weekCount: max(1, min(recentWeekCount, 65))
                ),
                using: credentialStore.apiCredentials
            )
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    func loadSelectedPage() async throws {
        switch page {
        case .popularity:
            break
        case .campaigns:
            campaigns = try await api.listCampaigns(
                using: credentialStore.apiCredentials,
                limit: 100
            )
        case .apps:
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            apps = try await api.searchOwnedApps(
                named: query.isEmpty ? nil : query,
                using: credentialStore.apiCredentials,
                limit: 100
            )
        }
    }

    func pageDidChange() async {
        guard isConfigured, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await loadSelectedPage()
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    private func loadFresh() async {
        connection = nil
        campaigns = []
        apps = []
        popularityRows = []
        await load()
    }
}

struct AppleAdsPlatformWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services

    var body: some View {
        AppleAdsPlatformWorkspaceContent(
            model: AppleAdsPlatformWorkspaceModel(
                api: services.appleAdsPlatformAPI,
                credentialStore: services.appleAdsCredentialStore
            )
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }
}

private struct AppleAdsPlatformWorkspaceContent: View {
    @State private var model: AppleAdsPlatformWorkspaceModel

    init(model: AppleAdsPlatformWorkspaceModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                coverageHeader
                Divider()
                controls
                Divider()
                pageContent
            }
            .navigationTitle("Apple Ads")
            .frame(minWidth: 820, minHeight: 620)
            .task { await model.load() }
            .onChange(of: model.page) { _, _ in
                Task { await model.pageDidChange() }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoading || !model.isConfigured)
                }
            }
        }
    }

    private var coverageHeader: some View {
        HStack(spacing: 24) {
            Label("Official Apple Swift client", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            LabeledContent("Client", value: model.coverage.clientVersion)
            LabeledContent("Generated operations", value: String(model.coverage.operationCount))
            Spacer()
            Text(model.coverage.baseURL)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Workspace", selection: $model.page) {
                    ForEach(AppleAdsPlatformWorkspaceModel.Page.allCases) { page in
                        Text(page.rawValue).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 460)

                Spacer()

                if let accounts = model.connection?.accounts, !accounts.isEmpty {
                    Picker("Ad Account", selection: $model.selectedAdAccountID) {
                        ForEach(accounts) { account in
                            Text("\(account.name) · \(account.id)")
                                .tag(String(account.id))
                        }
                    }
                    .frame(maxWidth: 340)
                    .onChange(of: model.selectedAdAccountID) { _, _ in
                        Task { await model.selectAccount() }
                    }
                }
            }

            if model.page == .popularity {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField(
                            "Search terms separated by commas",
                            text: $model.searchTermsText,
                            axis: .vertical
                        )
                        .lineLimit(1...3)
                        TextField("Country", text: $model.countryOrRegion)
                            .frame(width: 90)
                        Stepper(
                            "\(model.recentWeekCount) weeks",
                            value: $model.recentWeekCount,
                            in: 1...65
                        )
                        .frame(width: 150)
                        Button("Query") { Task { await model.searchPopularity() } }
                            .disabled(model.isLoading)
                    }
                    Text("Uses Apple's public weekly Search Term Popularity dataset. Terms below Apple's eligibility thresholds may not be returned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.page == .apps {
                HStack {
                    TextField("Search owned apps (3+ characters, or leave empty)", text: $model.searchQuery)
                        .onSubmit { Task { await model.searchApps() } }
                    Button("Search") { Task { await model.searchApps() } }
                        .disabled(
                            model.isLoading
                                || (!model.searchQuery.isEmpty && model.searchQuery.count < 3)
                        )
                }
            }

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var pageContent: some View {
        if model.isLoading && model.campaigns.isEmpty && model.apps.isEmpty {
            Spacer()
            ProgressView("Loading Apple Ads…")
            Spacer()
        } else if !model.isConfigured {
            ContentUnavailableView(
                "Apple Ads Setup Required",
                systemImage: "key.horizontal",
                description: Text("Open Settings and complete the guided Apple Ads Platform API setup.")
            )
        } else {
            switch model.page {
            case .popularity:
                popularityList
            case .campaigns:
                campaignList
            case .apps:
                appList
            }
        }
    }

    private var popularityList: some View {
        Table(model.popularityRows) {
            TableColumn("Search Term", value: \.searchTerm)
            TableColumn("Country", value: \.countryOrRegion)
            TableColumn("Week") { row in
                Text(row.week ?? row.month ?? "—")
                    .monospacedDigit()
            }
            TableColumn("Global") { row in
                Text(row.popularity1to100.map(String.init) ?? "—")
                    .monospacedDigit()
            }
            TableColumn("1–5") { row in
                Text(row.popularity1to5.map(String.init) ?? "—")
                    .monospacedDigit()
            }
            TableColumn("Genre", value: \.genre)
            TableColumn("Genre Score") { row in
                Text(row.popularityInGenre.map(String.init) ?? "—")
                    .monospacedDigit()
            }
            TableColumn("Genre Rank") { row in
                Text(row.rankInGenre.map(String.init) ?? "—")
                    .monospacedDigit()
            }
        }
        .overlay {
            if model.popularityRows.isEmpty {
                ContentUnavailableView(
                    "Query Search Popularity",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Enter search terms and a country or region, then query Apple's public dataset.")
                )
            }
        }
    }

    private var campaignList: some View {
        List(model.campaigns) { campaign in
            HStack(spacing: 12) {
                Image(systemName: "megaphone")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(campaign.name)
                        .font(.headline)
                    Text("Campaign ID \(campaign.id)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(campaign.displayStatus ?? campaign.status ?? "Unknown")
                    .foregroundStyle(.secondary)
                if let modifiedAt = campaign.modifiedAt {
                    Text(modifiedAt, style: .date)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if model.campaigns.isEmpty {
                ContentUnavailableView("No Campaigns", systemImage: "megaphone")
            }
        }
    }

    private var appList: some View {
        List(model.apps, id: \.adamId) { app in
            HStack(spacing: 12) {
                Image(systemName: "app")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.appName)
                        .font(.headline)
                    Text(app.developerName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(app.adamId))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if model.apps.isEmpty {
                ContentUnavailableView(
                    "Search Owned Apps",
                    systemImage: "app.badge",
                    description: Text("Run an empty search to list owned apps, or enter at least three characters.")
                )
            }
        }
    }
}
