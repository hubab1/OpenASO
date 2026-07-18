import Foundation

enum AddKeywordsStorefrontProjection {
    struct Candidate: Identifiable, Equatable, Sendable {
        let code: String
        let name: String
        let title: String
        let keywordCount: Int

        var id: String { code }
    }

    static func candidates(
        storefronts: [(code: String, name: String, title: String)],
        trackedStorefrontCodes: [String],
        searchText: String
    ) -> [Candidate] {
        var countsByStorefront: [String: Int] = [:]
        countsByStorefront.reserveCapacity(storefronts.count)

        for code in trackedStorefrontCodes {
            countsByStorefront[code, default: 0] += 1
        }

        let searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return storefronts
            .lazy
            .filter { storefront in
                searchText.isEmpty
                    || storefront.title.localizedCaseInsensitiveContains(searchText)
                    || storefront.code.localizedCaseInsensitiveContains(searchText)
            }
            .map { storefront in
                Candidate(
                    code: storefront.code,
                    name: storefront.name,
                    title: storefront.title,
                    keywordCount: countsByStorefront[normalized(storefront.code), default: 0]
                )
            }
            .sorted { lhs, rhs in
                if lhs.keywordCount != rhs.keywordCount {
                    return lhs.keywordCount > rhs.keywordCount
                }

                let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }

                return lhs.code < rhs.code
            }
    }

    private static func normalized(_ storefrontCode: String) -> String {
        storefrontCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
