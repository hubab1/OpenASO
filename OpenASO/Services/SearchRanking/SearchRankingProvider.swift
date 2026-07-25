import Foundation

protocol SearchRankingProvider: Sendable {
    func search(keyword: String, storefrontCode: String, platform: AppPlatform, limit: Int) async throws -> SearchRankingPage
}
