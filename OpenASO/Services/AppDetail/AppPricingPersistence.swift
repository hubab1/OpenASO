import Foundation
import SwiftData

enum AppPricingPersistence {
    static func comparison(
        appStoreID: Int64,
        requestedStorefronts: [String]?,
        using backgroundModelStore: BackgroundModelStore
    ) async throws -> OpenASOMCPAppPricingComparison? {
        let requested = requestedStorefronts.map { storefronts in
            Set(storefronts.map(normalizedStorefront).filter { !$0.isEmpty })
        }

        return try await backgroundModelStore.read { modelContext in
            var descriptor = FetchDescriptor<AppPricingSnapshot>(
                predicate: #Predicate { snapshot in
                    snapshot.appStoreID == appStoreID
                }
            )
            descriptor.fetchLimit = 1
            guard let snapshot = try modelContext.fetch(descriptor).first else {
                return nil
            }

            let comparison = try JSONDecoder().decode(
                OpenASOMCPAppPricingComparison.self,
                from: snapshot.comparisonJSON
            )
            guard let requested else { return comparison }

            let stored = Set(comparison.storefronts.map(normalizedStorefront).filter { !$0.isEmpty })
            return requested.isSubset(of: stored) ? comparison : nil
        }
    }

    static func store(
        _ comparison: OpenASOMCPAppPricingComparison,
        using backgroundModelStore: BackgroundModelStore
    ) async throws {
        let appStoreIDs = comparison.appStoreIDs.compactMap(Int64.init)
        guard !appStoreIDs.isEmpty else { return }

        let normalizedStorefronts = comparison.storefronts
            .map(normalizedStorefront)
            .filter { !$0.isEmpty }
            .sorted()
        let storefrontsJSON = try JSONEncoder().encode(normalizedStorefronts)
        let comparisonJSON = try JSONEncoder().encode(comparison)
        let generatedAt = comparison.generatedAt
        let updatedAt = Date()

        try await backgroundModelStore.write { modelContext in
            for appStoreID in appStoreIDs {
                var descriptor = FetchDescriptor<AppPricingSnapshot>(
                    predicate: #Predicate { snapshot in
                        snapshot.appStoreID == appStoreID
                    }
                )
                descriptor.fetchLimit = 1

                if let snapshot = try modelContext.fetch(descriptor).first {
                    snapshot.generatedAt = generatedAt
                    snapshot.updatedAt = updatedAt
                    snapshot.storefrontsJSON = storefrontsJSON
                    snapshot.comparisonJSON = comparisonJSON
                } else {
                    modelContext.insert(AppPricingSnapshot(
                        appStoreID: appStoreID,
                        generatedAt: generatedAt,
                        storefrontsJSON: storefrontsJSON,
                        comparisonJSON: comparisonJSON,
                        updatedAt: updatedAt
                    ))
                }
            }
        }
    }

    private static func normalizedStorefront(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
