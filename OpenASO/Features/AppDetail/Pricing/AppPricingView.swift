import SwiftData
import SwiftUI

struct AppPricingView: View {
    @Environment(AppServices.self) private var services

    @Query(sort: [SortDescriptor(\Storefront.name, order: .forward)])
    private var storefronts: [Storefront]

    let appStoreID: Int64
    let selectedStorefrontFilter: StorefrontFilter
    let searchText: String
    let refreshToken: Int

    @State private var comparison: OpenASOMCPAppPricingComparison?
    @State private var isLoading = false
    @State private var pricingFetchProgress: PricingFetchProgress?
    @State private var errorMessage: String?

    private var filteredPlans: [OpenASOMCPAppStorefrontPlan] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (comparison?.plans ?? [])
            .filter { plan in
                plan.error == nil && !plan.name.isEmpty
            }
            .filter { plan in
                guard !normalizedSearch.isEmpty else { return true }
                return plan.name.lowercased().contains(normalizedSearch)
                    || plan.storefront.lowercased().contains(normalizedSearch)
                    || storeTitle(for: plan.storefront).lowercased().contains(normalizedSearch)
                    || plan.displayPrice.lowercased().contains(normalizedSearch)
            }
            .sorted { lhs, rhs in
                if lhs.name == rhs.name {
                    return lhs.storefront < rhs.storefront
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private var localizedPricingByPlanKey: [String: OpenASOMCPLocalizedPricingComparison] {
        Dictionary(grouping: comparison?.localizedPricing ?? []) {
            comparisonKey(
                appStoreID: $0.appStoreID,
                planName: $0.planName,
                storefront: $0.storefront,
                displayPrice: $0.displayPrice
            )
        }.compactMapValues { comparisons in
            comparisons.first { $0.percentDifferenceFromUS != nil } ?? comparisons.first
        }
    }

    private var failedPricingStorefronts: [String] {
        guard let comparison else { return [] }
        var storefronts = Set<String>()
        for price in comparison.prices where price.appStoreID == String(appStoreID) && price.error != nil {
            storefronts.insert(normalizedStorefront(price.storefront))
        }
        for plan in comparison.plans where plan.appStoreID == String(appStoreID) && plan.error != nil {
            storefronts.insert(normalizedStorefront(plan.storefront))
        }
        return storefronts
            .filter { !$0.isEmpty }
            .sorted { storeTitle(for: $0).localizedStandardCompare(storeTitle(for: $1)) == .orderedAscending }
    }

    private var isRefreshInProgress: Bool {
        if services.refreshProgressStore.pendingAppRefreshCount > 0 {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pricing")
                        .font(.title2.bold())
                    Text("Public App Store prices and visible in-app purchase rows by country.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !failedPricingStorefronts.isEmpty {
                    Button {
                        Task { await retryFailedPricing() }
                    } label: {
                        Label("Retry Failed", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(isLoading || isRefreshInProgress)
                }
                Button {
                    Task { await loadPricing(forceRefresh: true) }
                } label: {
                    Label("Refresh Pricing", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || isRefreshInProgress)
            }

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView(
                        value: Double(pricingFetchProgress?.completed ?? 0),
                        total: Double(max(pricingFetchProgress?.total ?? 1, 1))
                    )
                    .frame(width: 220)
                    Text(pricingProgressTitle)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Pricing Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredPlans.isEmpty {
                ContentUnavailableView(
                    comparison == nil ? "Pricing Not Loaded" : "No Plans Found",
                    systemImage: "tag",
                    description: Text(comparison == nil
                        ? "Use Refresh Pricing or Refresh All Apps to fetch pricing for this app."
                        : "The public App Store page did not expose visible in-app purchase or subscription rows for this selection.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                pricingTable
            }
        }
        .padding(24)
        .task(id: refreshSignature) {
            await loadPricing(forceRefresh: false)
        }
    }

    private var pricingTable: some View {
        Table(filteredPlans) {
            TableColumn("Plan") { plan in
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.name)
                        .fontWeight(.medium)
                    Text(plan.billingCadence?.capitalized ?? "Cadence unknown")
                        .font(.caption)
                        .foregroundStyle(plan.billingCadence == nil ? .tertiary : .secondary)
                }
            }

            TableColumn("Country") { plan in
                Text("\(storeFlag(for: plan.storefront)) \(storeTitle(for: plan.storefront))")
            }

            TableColumn("Local Price") { plan in
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.displayPrice)
                        .fontWeight(.semibold)
                    Text(plan.currency ?? "Currency unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TableColumn("USD") { plan in
                Text(formattedUSD(plan.priceUSD))
                    .foregroundStyle(plan.priceUSD == nil ? .tertiary : .primary)
            }

            TableColumn("Vs US") { plan in
                let localizedPricing = localizedPricingByPlanKey[
                    comparisonKey(
                        appStoreID: plan.appStoreID,
                        planName: plan.name,
                        storefront: plan.storefront,
                        displayPrice: plan.displayPrice
                    )
                ]
                PricingDeltaBadge(comparison: localizedPricing)
            }
        }
    }

    private var refreshSignature: String {
        [
            String(appStoreID),
            selectedStorefrontFilter.id,
            String(refreshToken),
        ].joined(separator: "::")
    }

    @MainActor
    private func loadPricing(forceRefresh: Bool) async {
        guard !isLoading else { return }
        if !comparisonMatchesCurrentApp {
            comparison = nil
        }
        guard let backgroundModelStore = services.backgroundModelStore else {
            errorMessage = "The workspace store is not ready."
            return
        }

        isLoading = true
        pricingFetchProgress = nil
        errorMessage = nil
        defer {
            isLoading = false
            pricingFetchProgress = nil
        }

        do {
            if !forceRefresh,
               let cached = await services.appPricingCache.comparison(
                appStoreID: appStoreID,
                requestedStorefronts: requestedStorefronts
               )
            {
                comparison = cached
                return
            }

            if !forceRefresh,
               let persisted = try await AppPricingPersistence.comparison(
                appStoreID: appStoreID,
                requestedStorefronts: requestedStorefronts,
                using: backgroundModelStore
               )
            {
                await services.appPricingCache.store(persisted)
                comparison = persisted
                return
            }

            if !forceRefresh {
                return
            }

            guard !isRefreshInProgress else { return }

            let service = OpenASOMCPService(
                backgroundModelStore: backgroundModelStore,
                appResolver: services.appResolver,
                appCatalogService: services.appCatalogService
            )
            let fetched = try await service.compareAppPricing(
                appStoreIDs: [appStoreID],
                storefronts: requestedStorefronts
            ) { completed, total, failureCount in
                await MainActor.run {
                    pricingFetchProgress = PricingFetchProgress(
                        completed: completed,
                        total: total,
                        failureCount: failureCount
                    )
                }
            }
            await services.appPricingCache.store(fetched)
            try await AppPricingPersistence.store(fetched, using: backgroundModelStore)
            comparison = fetched
        } catch {
            comparison = nil
            errorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    @MainActor
    private func retryFailedPricing() async {
        let failedStorefronts = failedPricingStorefronts
        guard !failedStorefronts.isEmpty else { return }
        guard let existingComparison = comparison else { return }
        guard !isLoading else { return }
        guard let backgroundModelStore = services.backgroundModelStore else {
            errorMessage = "The workspace store is not ready."
            return
        }
        guard !isRefreshInProgress else { return }

        isLoading = true
        pricingFetchProgress = nil
        errorMessage = nil
        defer {
            isLoading = false
            pricingFetchProgress = nil
        }

        do {
            let service = OpenASOMCPService(
                backgroundModelStore: backgroundModelStore,
                appResolver: services.appResolver,
                appCatalogService: services.appCatalogService
            )
            let retryComparison = try await service.compareAppPricing(
                appStoreIDs: [appStoreID],
                storefronts: failedStorefronts
            ) { completed, total, failureCount in
                await MainActor.run {
                    pricingFetchProgress = PricingFetchProgress(
                        completed: completed,
                        total: total,
                        failureCount: failureCount
                    )
                }
            }
            let merged = mergedComparison(
                existing: existingComparison,
                retry: retryComparison,
                retriedStorefronts: failedStorefronts
            )
            await services.appPricingCache.store(merged)
            try await AppPricingPersistence.store(merged, using: backgroundModelStore)
            comparison = merged
        } catch {
            errorMessage = OpenASOError.map(error).localizedDescription
        }
    }

    private var requestedStorefronts: [String]? {
        switch selectedStorefrontFilter {
        case .all:
            return nil
        case .storefront(let code, _):
            let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalizedCode == "us" ? ["us"] : ["us", normalizedCode]
        }
    }

    private var comparisonMatchesCurrentApp: Bool {
        guard let comparison else { return true }
        return comparison.appStoreIDs.contains(String(appStoreID))
    }

    private func mergedComparison(
        existing: OpenASOMCPAppPricingComparison,
        retry: OpenASOMCPAppPricingComparison,
        retriedStorefronts: [String]
    ) -> OpenASOMCPAppPricingComparison {
        let retried = Set(retriedStorefronts.map(normalizedStorefront))
        let prices = existing.prices.filter { !retried.contains(normalizedStorefront($0.storefront)) }
            + retry.prices
        let plans = existing.plans.filter { !retried.contains(normalizedStorefront($0.storefront)) }
            + retry.plans
        let storefronts = Array(Set(existing.storefronts.map(normalizedStorefront) + retry.storefronts.map(normalizedStorefront)))
            .filter { !$0.isEmpty }
            .sorted()
        let appStoreIDs = Array(Set(existing.appStoreIDs + retry.appStoreIDs)).sorted()

        return OpenASOMCPAppPricingComparison(
            generatedAt: retry.generatedAt,
            appStoreIDs: appStoreIDs,
            storefronts: storefronts,
            prices: prices,
            plans: plans,
            localizedPricing: OpenASOMCPService.localizedPricingComparisons(from: plans),
            notes: retry.notes.isEmpty ? existing.notes : retry.notes
        )
    }

    private var pricingProgressTitle: String {
        guard let pricingFetchProgress else {
            return "Preparing pricing fetch"
        }

        let base = "Fetching pricing \(pricingFetchProgress.completed) of \(pricingFetchProgress.total) countries"
        guard pricingFetchProgress.failureCount > 0 else { return base }
        return "\(base), \(pricingFetchProgress.failureCount) failed"
    }

    private func storeTitle(for code: String) -> String {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return storefronts.first { $0.code.lowercased() == normalizedCode }?.title
            ?? normalizedCode.uppercased()
    }

    private func storeFlag(for code: String) -> String {
        storefronts.first { $0.code.lowercased() == code.lowercased() }?.flagEmoji ?? ""
    }

    private func formattedUSD(_ value: Double?) -> String {
        guard let value else { return "-" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func comparisonKey(appStoreID: String, planName: String, storefront: String, displayPrice: String) -> String {
        [
            appStoreID,
            normalizedPlanName(planName),
            storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            normalizedPlanName(displayPrice),
        ].joined(separator: "::")
    }

    private func normalizedPlanName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedStorefront(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct PricingDeltaBadge: View {
    let comparison: OpenASOMCPLocalizedPricingComparison?

    var body: some View {
        guard let comparison else {
            return AnyView(
                Text("US baseline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
        }

        guard let percentDifference = comparison.percentDifferenceFromUS else {
            return AnyView(
                Text("No FX")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
        }

        let label = percentDifference.formatted(.number.precision(.fractionLength(1))) + "%"
        let color: Color = percentDifference < -1 ? .green : (percentDifference > 1 ? .orange : .secondary)
        let prefix = percentDifference < -1 ? "Lower " : (percentDifference > 1 ? "Higher " : "")
        return AnyView(
            Text(prefix + label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        )
    }
}

private struct PricingFetchProgress {
    let completed: Int
    let total: Int
    let failureCount: Int
}
