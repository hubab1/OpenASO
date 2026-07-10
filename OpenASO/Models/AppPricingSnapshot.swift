import Foundation
import SwiftData

extension OpenASOSchemaV2 {
@Model
final class AppPricingSnapshot {
    #Index<AppPricingSnapshot>(
        [\.appStoreID],
        [\.updatedAt]
    )

    @Attribute(.unique) var appStoreID: Int64
    var generatedAt: Date
    var updatedAt: Date
    var storefrontsJSON: Data
    var comparisonJSON: Data

    init(
        appStoreID: Int64,
        generatedAt: Date,
        storefrontsJSON: Data,
        comparisonJSON: Data,
        updatedAt: Date = .now
    ) {
        self.appStoreID = appStoreID
        self.generatedAt = generatedAt
        self.updatedAt = updatedAt
        self.storefrontsJSON = storefrontsJSON
        self.comparisonJSON = comparisonJSON
    }
}
}

typealias AppPricingSnapshot = OpenASOSchemaV2.AppPricingSnapshot
