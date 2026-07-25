import Foundation

enum AppDetailManualRefreshScope: Equatable, Sendable {
    case focused
    case allStorefronts
}

struct AppDetailManualRefreshTrack: Equatable, Sendable {
    let identityKey: String
    let storefront: String
}

enum AppDetailManualRefreshScopeResolver {
    static func selection(
        scope: AppDetailManualRefreshScope,
        selectedStorefrontFilter: StorefrontFilter,
        trackedStorefronts: [String],
        defaultStorefront: String?,
        bundledStorefronts: [String]
    ) -> AppDetailRefreshStorefrontSelection {
        switch scope {
        case .focused:
            switch selectedStorefrontFilter {
            case .all:
                return .all(codes: DailyRefreshStorefrontScope.codes(
                    trackedStorefronts: trackedStorefronts,
                    defaultStorefront: defaultStorefront,
                    fallback: bundledStorefronts
                ))
            case .storefront(let code, _):
                guard let code = normalized(code) else {
                    return .all(codes: DailyRefreshStorefrontScope.codes(
                        trackedStorefronts: trackedStorefronts,
                        defaultStorefront: defaultStorefront,
                        fallback: bundledStorefronts
                    ))
                }
                return .storefront(code: code)
            }
        case .allStorefronts:
            return .all(codes: normalized(bundledStorefronts).sorted())
        }
    }

    static func identityKeys(
        for tracks: [AppDetailManualRefreshTrack],
        storefrontSelection: AppDetailRefreshStorefrontSelection
    ) -> [String] {
        let selectedStorefronts = Set(normalized(storefrontSelection.codes))
        return tracks.compactMap { track in
            guard let storefront = normalized(track.storefront),
                  selectedStorefronts.contains(storefront)
            else {
                return nil
            }
            return track.identityKey
        }
    }

    private static func normalized(_ storefronts: [String]) -> [String] {
        Array(Set(storefronts.compactMap(normalized)))
    }

    private static func normalized(_ storefront: String?) -> String? {
        let value = storefront?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
