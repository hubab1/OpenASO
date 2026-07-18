import Testing
@testable import OpenASO

struct AddKeywordsStorefrontProjectionTests {
    @Test
    func groupsLargeKeywordFixtureOnceAndSortsByCount() {
        let storefronts = (0..<200).map { index in
            (
                code: "s\(index)",
                name: "Store \(index)",
                title: "🏳️ Store \(index)"
            )
        }
        let trackedStorefrontCodes = (0..<200).flatMap { index in
            Array(repeating: "s\(index)", count: 200 - index)
        }

        let candidates = AddKeywordsStorefrontProjection.candidates(
            storefronts: storefronts,
            trackedStorefrontCodes: trackedStorefrontCodes,
            searchText: ""
        )

        #expect(trackedStorefrontCodes.count == 20_100)
        #expect(candidates.count == 200)
        #expect(candidates.first?.code == "s0")
        #expect(candidates.first?.keywordCount == 200)
        #expect(candidates.last?.code == "s199")
        #expect(candidates.last?.keywordCount == 1)
        #expect(zip(candidates, candidates.dropFirst()).allSatisfy { pair in
            pair.0.keywordCount >= pair.1.keywordCount
        })
    }

    @Test
    func searchAndTieBreakRemainDeterministic() {
        let candidates = AddKeywordsStorefrontProjection.candidates(
            storefronts: [
                (code: "zz", name: "Zulu", title: "🇿🇿 Zulu"),
                (code: "aa", name: "Alpha", title: "🇦🇦 Alpha"),
                (code: "ab", name: "Alpha", title: "🇦🇧 Alpha")
            ],
            trackedStorefrontCodes: ["zz", "aa", "ab"],
            searchText: "alpha"
        )

        #expect(candidates.map(\.code) == ["aa", "ab"])
        #expect(candidates.allSatisfy { $0.keywordCount == 1 })
    }
}
