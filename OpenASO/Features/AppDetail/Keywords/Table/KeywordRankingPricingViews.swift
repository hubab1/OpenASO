import Observation
import SwiftUI

@Observable
@MainActor
final class KeywordRankingPricingModel {
    struct RequestID: Equatable, Hashable {
        let appStoreIDs: [Int64]
        let storefrontCode: String
        let platform: AppPlatform
        let retryToken: Int
    }

    private(set) var pricesByAppStoreID: [Int64: RankedAppPriceResult] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func load(
        request: RequestID,
        using service: RankedAppPricingService
    ) async {
        guard !request.appStoreIDs.isEmpty else {
            pricesByAppStoreID = [:]
            isLoading = false
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let results = try await service.prices(
                for: request.appStoreIDs,
                storefrontCode: request.storefrontCode,
                platform: request.platform
            )
            try Task.checkCancellation()
            pricesByAppStoreID = Dictionary(
                uniqueKeysWithValues: results.map { ($0.appStoreID, $0) }
            )
            isLoading = false
        } catch is CancellationError {
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

struct KeywordPricingComparisonApp: Identifiable, Equatable, Hashable, Sendable {
    let id: Int64
    let rank: Int
    let name: String
    let sellerName: String

    init(row: KeywordRankingCatalogRow) {
        self.id = row.appStoreID
        self.rank = row.position
        self.name = row.appName
        self.sellerName = row.sellerName
    }
}

@Observable
@MainActor
private final class KeywordPricingComparisonModel {
    struct RequestID: Equatable, Hashable {
        let appStoreIDs: [Int64]
        let storefrontCodes: [String]
        let platform: AppPlatform
        let retryToken: Int
    }

    private(set) var pricesByStorefront: [String: [Int64: RankedAppPriceResult]] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func price(appStoreID: Int64, storefrontCode: String) -> RankedAppPriceResult? {
        pricesByStorefront[storefrontCode]?[appStoreID]
    }

    func load(
        request: RequestID,
        using service: RankedAppPricingService
    ) async {
        guard !request.appStoreIDs.isEmpty, !request.storefrontCodes.isEmpty else {
            pricesByStorefront = [:]
            isLoading = false
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let loadedPrices = try await withThrowingTaskGroup(
                of: (String, [RankedAppPriceResult]).self
            ) { group in
                for storefrontCode in request.storefrontCodes {
                    group.addTask {
                        let prices = try await service.prices(
                            for: request.appStoreIDs,
                            storefrontCode: storefrontCode,
                            platform: request.platform
                        )
                        return (storefrontCode, prices)
                    }
                }

                var values: [String: [Int64: RankedAppPriceResult]] = [:]
                for try await (storefrontCode, results) in group {
                    values[storefrontCode] = Dictionary(
                        uniqueKeysWithValues: results.map { ($0.appStoreID, $0) }
                    )
                }
                return values
            }
            try Task.checkCancellation()
            pricesByStorefront = loadedPrices
            isLoading = false
        } catch is CancellationError {
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

@Observable
@MainActor
private final class VisibleProductPricingModel {
    struct RequestID: Equatable, Hashable {
        let appStoreID: Int64
        let storefrontCodes: [String]
        let retryToken: Int
    }

    private enum LoadOutcome: Sendable {
        case success(VisibleProductPriceResult)
        case failure(String)
    }

    private(set) var resultsByStorefront: [String: VisibleProductPriceResult] = [:]
    private(set) var errorsByStorefront: [String: String] = [:]
    private(set) var isLoading = false

    func load(
        request: RequestID,
        using service: VisibleProductPricingService
    ) async {
        resultsByStorefront = [:]
        errorsByStorefront = [:]
        isLoading = true

        let outcomes = await withTaskGroup(
            of: (String, LoadOutcome).self
        ) { group in
            for storefrontCode in request.storefrontCodes {
                group.addTask {
                    do {
                        let result = try await service.products(
                            for: request.appStoreID,
                            storefrontCode: storefrontCode
                        )
                        return (storefrontCode, .success(result))
                    } catch is CancellationError {
                        return (storefrontCode, .failure("Loading was cancelled."))
                    } catch {
                        return (storefrontCode, .failure(error.localizedDescription))
                    }
                }
            }

            var values: [(String, LoadOutcome)] = []
            for await outcome in group {
                values.append(outcome)
            }
            return values
        }
        guard !Task.isCancelled else {
            isLoading = false
            return
        }

        for (storefrontCode, outcome) in outcomes {
            switch outcome {
            case .success(let result):
                resultsByStorefront[storefrontCode] = result
            case .failure(let message):
                errorsByStorefront[storefrontCode] = message
            }
        }
        isLoading = false
    }
}

struct KeywordRankingPriceCell: View {
    let result: RankedAppPriceResult?
    let isLoading: Bool
    let storefrontCode: String

    var body: some View {
        Group {
            if let result {
                Text(result.value.displayPrice ?? "—")
                    .foregroundStyle(
                        result.value == .unavailable ? .secondary : .primary
                    )
                    .tooltip(tooltip(for: result))
            } else if isLoading {
                Text("…")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Loading price")
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
                    .tooltip("Price unavailable in \(storefrontCode.uppercased())")
            }
        }
        .font(.body.monospacedDigit())
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func tooltip(for result: RankedAppPriceResult) -> String {
        let storefront = result.storefrontCode.uppercased()
        let date = result.observedAt.formatted(date: .abbreviated, time: .shortened)
        switch result.value {
        case .free:
            return "Free in \(storefront) · checked \(date)"
        case .paid(_, _, let currencyCode):
            return "\(currencyCode) in \(storefront) · checked \(date)"
        case .unavailable:
            return "Not available in \(storefront) · checked \(date)"
        }
    }
}

struct KeywordRankingComparisonSelectionCell: View {
    let isSelected: Bool
    let canSelect: Bool
    let appName: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!isSelected && !canSelect)
        .help(isSelected ? "Remove \(appName) from comparison" : "Add \(appName) to comparison")
        .accessibilityLabel(
            isSelected ? "Remove \(appName) from pricing comparison" : "Add \(appName) to pricing comparison"
        )
    }
}

struct KeywordPricingComparisonSheet: View {
    private static let maximumStorefrontCount = 5

    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services

    let keyword: String
    let apps: [KeywordPricingComparisonApp]
    let platform: AppPlatform
    let trackedAppStoreID: Int64

    @State private var selectedStorefrontCodes: [String]
    @State private var pricingModel = KeywordPricingComparisonModel()
    @State private var visibleProductModel = VisibleProductPricingModel()
    @State private var expandedAppStoreID: Int64?
    @State private var retryToken = 0
    @State private var visibleProductRetryToken = 0

    init(
        keyword: String,
        apps: [KeywordPricingComparisonApp],
        storefrontCode: String,
        platform: AppPlatform,
        trackedAppStoreID: Int64
    ) {
        self.keyword = keyword
        self.apps = apps
        self.platform = platform
        self.trackedAppStoreID = trackedAppStoreID
        let normalizedStorefront = StorefrontCatalog.normalizedStorefrontCode(storefrontCode)
        _selectedStorefrontCodes = State(initialValue: [normalizedStorefront])
    }

    private var storefronts: [BundledStorefront] {
        ((try? services.storefrontCatalog.bundledStorefronts()) ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedStorefronts: [BundledStorefront] {
        selectedStorefrontCodes.compactMap { code in
            storefronts.first(where: { $0.code == code })
        }
    }

    private var requestID: KeywordPricingComparisonModel.RequestID {
        KeywordPricingComparisonModel.RequestID(
            appStoreIDs: apps.map(\.id),
            storefrontCodes: selectedStorefrontCodes,
            platform: platform,
            retryToken: retryToken
        )
    }

    private var visibleProductRequestID: VisibleProductPricingModel.RequestID? {
        guard let expandedAppStoreID else { return nil }
        return VisibleProductPricingModel.RequestID(
            appStoreID: expandedAppStoreID,
            storefrontCodes: selectedStorefrontCodes,
            retryToken: visibleProductRetryToken
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            storefrontToolbar
            Divider()
            comparisonGrid
            Divider()
            footer
        }
        .task(id: requestID) {
            await pricingModel.load(
                request: requestID,
                using: services.rankedAppPricingService
            )
        }
        .task(id: visibleProductRequestID) {
            guard let visibleProductRequestID else { return }
            await visibleProductModel.load(
                request: visibleProductRequestID,
                using: services.visibleProductPricingService
            )
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 480, idealHeight: 640)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pricing Comparison")
                    .font(.title2.weight(.semibold))
                Text("“\(keyword)” · \(apps.count) ranked apps")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Public App Store prices", systemImage: "storefront")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var storefrontToolbar: some View {
        HStack(spacing: 10) {
            Text("Storefronts")
                .font(.headline)

            ForEach(selectedStorefronts, id: \.code) { storefront in
                HStack(spacing: 5) {
                    Text(storefront.flagEmoji)
                    Text(storefront.code.uppercased())
                    if selectedStorefrontCodes.count > 1 {
                        Button {
                            removeStorefront(storefront.code)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(storefront.name)")
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            }

            Menu {
                ForEach(storefronts, id: \.code) { storefront in
                    Button {
                        addStorefront(storefront.code)
                    } label: {
                        Text("\(storefront.flagEmoji) \(storefront.name)")
                    }
                    .disabled(
                        selectedStorefrontCodes.contains(storefront.code)
                            || selectedStorefrontCodes.count >= Self.maximumStorefrontCount
                    )
                }
            } label: {
                Label("Add Storefront", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Text("Up to \(Self.maximumStorefrontCount)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var comparisonGrid: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("Ranked app")
                        .frame(width: 300, alignment: .leading)
                    ForEach(selectedStorefronts, id: \.code) { storefront in
                        Text("\(storefront.flagEmoji) \(storefront.code.uppercased())")
                            .frame(width: 128, alignment: .trailing)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                Divider()
                    .gridCellColumns(selectedStorefrontCodes.count + 1)

                ForEach(apps) { app in
                    GridRow {
                        comparisonAppCell(app)
                            .frame(width: 300, alignment: .leading)

                        ForEach(selectedStorefronts, id: \.code) { storefront in
                            KeywordRankingPriceCell(
                                result: pricingModel.price(
                                    appStoreID: app.id,
                                    storefrontCode: storefront.code
                                ),
                                isLoading: pricingModel.isLoading,
                                storefrontCode: storefront.code
                            )
                            .frame(width: 128, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        app.id == trackedAppStoreID
                            ? Color.accentColor.opacity(0.09)
                            : Color.clear
                    )

                    Divider()
                        .gridCellColumns(selectedStorefrontCodes.count + 1)

                    if expandedAppStoreID == app.id {
                        GridRow {
                            visibleProductDetails(for: app)
                                .gridCellColumns(selectedStorefrontCodes.count + 1)
                        }

                        Divider()
                            .gridCellColumns(selectedStorefrontCodes.count + 1)
                    }
                }
            }
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func comparisonAppCell(_ app: KeywordPricingComparisonApp) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy) {
                    expandedAppStoreID = expandedAppStoreID == app.id ? nil : app.id
                }
            } label: {
                Image(
                    systemName: expandedAppStoreID == app.id
                        ? "chevron.down"
                        : "chevron.right"
                )
                .font(.caption.weight(.semibold))
                .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(
                expandedAppStoreID == app.id
                    ? "Hide visible purchase prices"
                    : "Show visible purchase prices"
            )
            .accessibilityLabel(
                expandedAppStoreID == app.id
                    ? "Hide visible purchases for \(app.name)"
                    : "Show visible purchases for \(app.name)"
            )
            .accessibilityValue(expandedAppStoreID == app.id ? "Expanded" : "Collapsed")

            Text("#\(app.rank)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .fontWeight(app.id == trackedAppStoreID ? .semibold : .regular)
                        .lineLimit(1)
                    if app.id == trackedAppStoreID {
                        Text("Tracked")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(app.sellerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func visibleProductDetails(
        for app: KeywordPricingComparisonApp
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Visible purchases", systemImage: "cart")
                    .font(.caption.weight(.semibold))
                Text("Apple may show only a subset.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 300, alignment: .leading)

            ForEach(selectedStorefronts, id: \.code) { storefront in
                visibleProductStorefrontColumn(
                    app: app,
                    storefront: storefront
                )
                .frame(width: 128, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.045))
    }

    @ViewBuilder
    private func visibleProductStorefrontColumn(
        app: KeywordPricingComparisonApp,
        storefront: BundledStorefront
    ) -> some View {
        if visibleProductModel.isLoading,
           visibleProductModel.resultsByStorefront[storefront.code] == nil,
           visibleProductModel.errorsByStorefront[storefront.code] == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(
                    "Loading visible purchases for \(app.name) in \(storefront.name)"
                )
        } else if let result = visibleProductModel.resultsByStorefront[storefront.code] {
            if result.products.isEmpty {
                Text("None shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(result.products, id: \.self) { product in
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(product.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                            Text(product.displayPrice)
                                .font(.caption.monospacedDigit().weight(.medium))
                                .lineLimit(1)
                        }
                    }
                    if result.isTruncated {
                        Text("More may be available")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .tooltip(
                    "Visible App Store purchases in \(storefront.code.uppercased())"
                        + " · checked "
                        + result.observedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                )
            }
        } else if let errorMessage = visibleProductModel.errorsByStorefront[storefront.code] {
            VStack(alignment: .trailing, spacing: 4) {
                Text("Unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .tooltip(errorMessage)
                Button("Retry") {
                    visibleProductRetryToken &+= 1
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var footer: some View {
        HStack {
            if let errorMessage = pricingModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Try Again") {
                    retryToken &+= 1
                }
            } else if pricingModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Loading pricing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Prices are storefront-specific and may change. Expand an app for visible purchases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func addStorefront(_ code: String) {
        guard selectedStorefrontCodes.count < Self.maximumStorefrontCount,
              !selectedStorefrontCodes.contains(code) else {
            return
        }
        selectedStorefrontCodes.append(code)
    }

    private func removeStorefront(_ code: String) {
        guard selectedStorefrontCodes.count > 1 else { return }
        selectedStorefrontCodes.removeAll { $0 == code }
    }
}
