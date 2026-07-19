import Foundation

protocol SearchRankingProvider: Sendable {
    func search(keyword: String, storefrontCode: String, platform: AppPlatform, limit: Int) async throws -> SearchRankingPage
}

enum SearchRankingProviderFactory {
    static func makeProduction(httpClient: any HTTPClient) -> any SearchRankingProvider {
        PrimaryFallbackSearchRankingProvider(
            primary: AppStoreWebRankingProvider(httpClient: httpClient),
            fallback: ITunesSearchFallbackProvider(httpClient: httpClient)
        )
    }
}
