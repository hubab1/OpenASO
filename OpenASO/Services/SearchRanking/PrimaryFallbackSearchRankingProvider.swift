import Foundation

final class PrimaryFallbackSearchRankingProvider: SearchRankingProvider {
    typealias FallbackPlatformSupport = @Sendable (AppPlatform) -> Bool

    private let primary: any SearchRankingProvider
    private let fallback: any SearchRankingProvider
    private let fallbackSupportsPlatform: FallbackPlatformSupport

    init(
        primary: any SearchRankingProvider,
        fallback: any SearchRankingProvider
    ) {
        self.primary = primary
        self.fallback = fallback
        self.fallbackSupportsPlatform = { platform in
            switch platform {
            case .iphone, .ipad, .mac:
                true
            }
        }
    }

    init(
        primary: any SearchRankingProvider,
        fallback: any SearchRankingProvider,
        fallbackSupportsPlatform: @escaping FallbackPlatformSupport
    ) {
        self.primary = primary
        self.fallback = fallback
        self.fallbackSupportsPlatform = fallbackSupportsPlatform
    }

    func search(
        keyword: String,
        storefrontCode: String,
        platform: AppPlatform,
        limit: Int
    ) async throws -> SearchRankingPage {
        let request = try SearchRankingRequestValidator.validate(
            keyword: keyword,
            storefrontCode: storefrontCode,
            platform: platform,
            limit: limit
        )

        do {
            try Task.checkCancellation()
            return try await primary.search(
                keyword: request.keyword,
                storefrontCode: request.storefrontCode,
                platform: request.platform,
                limit: request.limit
            )
        } catch {
            try Task.checkCancellation()
            if Self.mustPropagate(error) {
                throw error
            }
            guard let primaryContext = Self.fallbackContext(
                for: error,
                provider: .appStoreWeb,
                requiresRecognizedFallbackFailure: true
            ) else {
                throw error
            }
            guard fallbackSupportsPlatform(request.platform) else {
                throw SearchRankingProviderError.fallbackUnavailable(
                    platform: request.platform,
                    primary: primaryContext
                )
            }

            do {
                try Task.checkCancellation()
                let page = try await fallback.search(
                    keyword: request.keyword,
                    storefrontCode: request.storefrontCode,
                    platform: request.platform,
                    limit: request.limit
                )
                try Task.checkCancellation()
                return SearchRankingPage(
                    items: page.items,
                    source: page.source,
                    fallbackContext: primaryContext
                )
            } catch {
                try Task.checkCancellation()
                if Self.mustPropagate(error) {
                    throw error
                }
                let fallbackContext = Self.fallbackContext(
                    for: error,
                    provider: .iTunesFallback,
                    requiresRecognizedFallbackFailure: false
                ) ?? SearchRankingFailureContext(
                    provider: .iTunesFallback,
                    category: .other
                )
                throw SearchRankingProviderError.allProvidersFailed(
                    primary: primaryContext,
                    fallback: fallbackContext
                )
            }
        }
    }

    private static func mustPropagate(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled || urlError.code == .timedOut
        }
        if let error = error as? OpenASOError {
            switch error {
            case .emptyQuery, .invalidAppStoreID:
                return true
            case .appNotFound,
                 .networkUnavailable,
                 .rateLimited,
                 .decodingFailed,
                 .unexpectedResponse,
                 .primaryProviderUnavailable,
                 .providerUnavailable:
                return false
            }
        }
        if let error = error as? SearchRankingProviderError {
            switch error {
            case .invalidStorefront,
                 .invalidLimit,
                 .unsupportedPlatform,
                 .fallbackUnavailable,
                 .allProvidersFailed:
                return true
            case .httpStatus, .responseFailure:
                return false
            }
        }
        return false
    }

    private static func fallbackContext(
        for error: any Error,
        provider: SearchRankingFailureContext.Provider,
        requiresRecognizedFallbackFailure: Bool
    ) -> SearchRankingFailureContext? {
        let category: SearchRankingFailureCategory
        if let error = error as? URLError {
            category = .transport(code: error.code.rawValue)
        } else if let error = error as? SearchRankingProviderError {
            switch error {
            case .httpStatus(let statusCode):
                category = .httpStatus(statusCode)
            case .responseFailure(let failure):
                category = .response(failure)
            case .invalidStorefront,
                 .invalidLimit,
                 .unsupportedPlatform,
                 .fallbackUnavailable,
                 .allProvidersFailed:
                return nil
            }
        } else if let error = error as? OpenASOError {
            switch error {
            case .appNotFound:
                category = .httpStatus(404)
            case .networkUnavailable:
                category = .transport(code: nil)
            case .rateLimited:
                category = .httpStatus(429)
            case .decodingFailed:
                category = .response(.decodingFailed)
            case .unexpectedResponse:
                category = .response(.nonHTTPResponse)
            case .primaryProviderUnavailable, .providerUnavailable:
                category = .provider
            case .emptyQuery, .invalidAppStoreID:
                return nil
            }
        } else {
            guard !requiresRecognizedFallbackFailure else { return nil }
            category = .other
        }

        return SearchRankingFailureContext(provider: provider, category: category)
    }
}
