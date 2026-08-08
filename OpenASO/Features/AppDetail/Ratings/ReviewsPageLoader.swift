import Foundation
import SwiftData

struct ReviewsPageLoader: Sendable {
    let appStoreID: Int64
    let storefrontCode: String?
    let cutoffDate: Date?
    let rating: Int?
    let source: AppStorefrontReviewSource?
    let backgroundModelStore: BackgroundModelStore?

    func load(request: PaginatedListPageRequest) async throws -> PaginatedListPage<AppStoreReviewValue> {
        guard let backgroundModelStore else {
            throw OpenASOError.providerUnavailable("Reviews are unavailable until the model store is ready.")
        }

        let pageSize = request.limit
        let fetchLimit = pageSize + 1
        let appStoreID = appStoreID
        let storefrontCode = storefrontCode
        let cutoffDate = cutoffDate
        let rating = rating
        let sourceRaw = source?.rawValue

        let reviews = try await backgroundModelStore.read { modelContext in
            var descriptor = Self.makeDescriptor(
                appStoreID: appStoreID,
                storefrontCode: storefrontCode,
                cutoffDate: cutoffDate,
                rating: rating,
                sourceRaw: sourceRaw
            )
            descriptor.fetchOffset = request.offset
            descriptor.fetchLimit = fetchLimit
            return try modelContext.fetch(descriptor).map(AppStoreReviewValue.init)
        }

        return PaginatedListPage(
            items: Array(reviews.prefix(pageSize)),
            hasMore: reviews.count > pageSize
        )
    }

    func count() async throws -> Int {
        guard let backgroundModelStore else {
            throw OpenASOError.providerUnavailable("Reviews are unavailable until the model store is ready.")
        }

        let appStoreID = appStoreID
        let storefrontCode = storefrontCode
        let cutoffDate = cutoffDate
        let rating = rating
        let sourceRaw = source?.rawValue

        return try await backgroundModelStore.read { modelContext in
            let descriptor = Self.makeDescriptor(
                appStoreID: appStoreID,
                storefrontCode: storefrontCode,
                cutoffDate: cutoffDate,
                rating: rating,
                sourceRaw: sourceRaw
            )
            return try modelContext.fetchCount(descriptor)
        }
    }

    private static func makeDescriptor(
        appStoreID: Int64,
        storefrontCode: String?,
        cutoffDate: Date?,
        rating: Int?,
        sourceRaw: String?
    ) -> FetchDescriptor<AppStorefrontReview> {
        let sortBy = [SortDescriptor(\AppStorefrontReview.reviewedAt, order: .reverse)]
        let targetStorefronts = storefrontCode.map(StorefrontCatalog.storefrontCodeAliases) ?? []
        let targetCutoffDate = cutoffDate ?? .distantPast
        let targetRating = rating ?? 0
        let targetSourceRaw = sourceRaw ?? ""

        return FetchDescriptor(
            predicate: #Predicate { review in
                review.appStoreID == appStoreID
                    && (targetStorefronts.isEmpty || targetStorefronts.contains(review.storefront))
                    && review.reviewedAt >= targetCutoffDate
                    && (targetRating == 0 || review.rating == targetRating)
                    && (targetSourceRaw.isEmpty || review.sourceRaw == targetSourceRaw)
            },
            sortBy: sortBy
        )
    }
}
