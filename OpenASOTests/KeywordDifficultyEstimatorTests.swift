import Testing
@testable import OpenASO

struct KeywordDifficultyEstimatorTests {
    @Test
    func rejectsEmptyKeywordWithoutInventingMetadataEvidence() throws {
        let unavailable = try requireUnavailable(KeywordDifficultyEstimator.estimate(
            keyword: "  --  ",
            rankedResults: makeResults(count: 10, ratingCount: 1_000)
        ))

        #expect(unavailable.reason == .emptyKeyword)
        #expect(unavailable.evidence.consideredResultCount == 10)
        #expect(unavailable.evidence.ratedResultCount == 10)
        #expect(unavailable.evidence.metadataSaturationScore == nil)
        #expect(unavailable.evidence.resultEvidence.allSatisfy { $0.metadataMatchScore == nil })
        #expect(unavailable.notes.first?.contains("not Apple Ads") == true)
    }

    @Test
    func requiresThreeUniqueTopTenResults() throws {
        let unavailable = try requireUnavailable(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: [
                makeResult(position: 0, appStoreID: 1, ratingCount: 1_000),
                makeResult(position: 1, appStoreID: 2, ratingCount: 1_000),
                makeResult(position: 2, appStoreID: 2, ratingCount: 1_000),
                makeResult(position: 3, appStoreID: 3, ratingCount: 1_000),
                makeResult(position: 11, appStoreID: 4, ratingCount: 1_000)
            ]
        ))

        #expect(unavailable.reason == .insufficientResults)
        #expect(unavailable.evidence.consideredResultCount == 2)
        #expect(unavailable.evidence.resultEvidence.map(\.appStoreID) == [2, 3])
    }

    @Test
    func distinguishesMissingAndInvalidRatingsFromRealZeroes() throws {
        let unavailable = try requireUnavailable(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: [
                makeResult(position: 1, appStoreID: 1, ratingCount: 0),
                makeResult(position: 2, appStoreID: 2, ratingCount: 0),
                makeResult(position: 3, appStoreID: 3, ratingCount: nil),
                makeResult(position: 4, appStoreID: 4, ratingCount: -1),
                makeResult(position: 5, appStoreID: 5, ratingCount: nil)
            ]
        ))

        #expect(unavailable.reason == .insufficientRatingEvidence)
        #expect(unavailable.evidence.ratedResultCount == 2)
        #expect(unavailable.evidence.ratingCoveragePercentage == 40)
        #expect(unavailable.evidence.maximumRatingCount == 0)
        #expect(unavailable.evidence.resultEvidence[2].ratingCount == nil)
        #expect(unavailable.evidence.resultEvidence[3].ratingCount == nil)

        let estimate = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(count: 3, ratingCount: 0)
        ))
        #expect(estimate.evidence.ratedResultCount == 3)
        #expect(estimate.evidence.ratingAuthorityScore == 0)
    }

    @Test
    func goldenUnmatchedFixtureUsesSeventyPercentRatingAuthority() throws {
        let estimate = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(count: 10, ratingCount: 999)
        ))

        #expect(estimate.score == 35)
        #expect(estimate.evidence.ratingAuthorityScore == 50)
        #expect(estimate.evidence.metadataSaturationScore == 0)
        #expect(estimate.confidenceScore == 100)
        #expect(estimate.confidence == .high)
    }

    @Test
    func goldenExactTitleFixtureAddsThirtyPercentMetadataSaturation() throws {
        let estimate = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(
                count: 10,
                ratingCount: 999,
                title: "Focus Timer"
            )
        ))

        #expect(estimate.score == 65)
        #expect(estimate.evidence.ratingAuthorityScore == 50)
        #expect(estimate.evidence.metadataSaturationScore == 100)
        #expect(estimate.evidence.exactTitlePhraseMatchCount == 10)
        #expect(estimate.evidence.exactSubtitlePhraseMatchCount == 0)
    }

    @Test
    func strongestEvidenceIsBoundedAtOneHundredWithoutOverflow() throws {
        let estimate = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(
                count: 10,
                ratingCount: Int.max,
                title: "Focus Timer"
            )
        ))

        #expect(estimate.score == 100)
        #expect(estimate.evidence.ratingAuthorityScore == 100)
        #expect(estimate.evidence.metadataSaturationScore == 100)
        #expect(estimate.evidence.maximumRatingCount == Int.max)
    }

    @Test
    func higherRankedAuthorityHasMoreWeight() throws {
        var topHeavy = makeResults(count: 10, ratingCount: 0)
        topHeavy[0] = makeResult(position: 1, appStoreID: 1, ratingCount: 99_999)

        var bottomHeavy = makeResults(count: 10, ratingCount: 0)
        bottomHeavy[9] = makeResult(position: 10, appStoreID: 10, ratingCount: 99_999)

        let topEstimate = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: topHeavy
        ))
        let bottomEstimate = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: bottomHeavy
        ))

        #expect((topEstimate.evidence.ratingAuthorityScore ?? 0) > (bottomEstimate.evidence.ratingAuthorityScore ?? 0))
        #expect(topEstimate.score > bottomEstimate.score)
    }

    @Test
    func mixedRankGoldenWeightsPositionExactlyOnce() throws {
        let estimate = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: [
                makeResult(position: 1, appStoreID: 1, ratingCount: 999_999),
                makeResult(position: 2, appStoreID: 2, ratingCount: 0),
                makeResult(position: 3, appStoreID: 3, ratingCount: 0)
            ]
        ))

        #expect(estimate.evidence.ratingAuthorityScore == 37)
        #expect(estimate.evidence.metadataSaturationScore == 0)
        #expect(estimate.score == 26)
    }

    @Test
    func ratingAuthorityAndMetadataCoverageAreMonotonic() throws {
        let noAuthority = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(count: 3, ratingCount: 0)
        ))
        let mediumAuthority = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(count: 3, ratingCount: 999)
        ))
        let highAuthority = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(count: 3, ratingCount: 999_999)
        ))
        let partialMetadata = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(
                count: 3,
                ratingCount: 0,
                title: "Focus Work"
            )
        ))
        let completeMetadata = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(
                count: 3,
                ratingCount: 0,
                title: "Focus Timer"
            )
        ))

        #expect((noAuthority.evidence.ratingAuthorityScore ?? 0) < (mediumAuthority.evidence.ratingAuthorityScore ?? 0))
        #expect((mediumAuthority.evidence.ratingAuthorityScore ?? 0) < (highAuthority.evidence.ratingAuthorityScore ?? 0))
        #expect((partialMetadata.evidence.metadataSaturationScore ?? 0) < (completeMetadata.evidence.metadataSaturationScore ?? 0))
        #expect(partialMetadata.score < completeMetadata.score)
    }

    @Test
    func confidenceTracksSampleAndRatingCompleteness() throws {
        let low = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(count: 3, ratingCount: 999)
        ))
        let medium = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(count: 5, ratingCount: 999)
        ))
        let high = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(count: 8, ratingCount: 999)
        ))

        #expect(low.confidenceScore == 55)
        #expect(low.confidence == .low)
        #expect(medium.confidenceScore == 71)
        #expect(medium.confidence == .medium)
        #expect(high.confidenceScore == 89)
        #expect(high.confidence == .high)
    }

    @Test
    func missingTopRankedRatingsLowersConfidenceMoreThanMissingBottomRatings() throws {
        let missingTop = (1...10).map { position in
            makeResult(
                position: position,
                appStoreID: Int64(position),
                ratingCount: position <= 2 ? nil : 999
            )
        }
        let missingBottom = (1...10).map { position in
            makeResult(
                position: position,
                appStoreID: Int64(position),
                ratingCount: position >= 9 ? nil : 999
            )
        }

        let topEstimate = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: missingTop
        ))
        let bottomEstimate = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: missingBottom
        ))

        #expect(topEstimate.evidence.ratingCoveragePercentage == 80)
        #expect(bottomEstimate.evidence.ratingCoveragePercentage == 80)
        #expect(topEstimate.evidence.weightedRatingCoveragePercentage < bottomEstimate.evidence.weightedRatingCoveragePercentage)
        #expect(topEstimate.confidenceScore < bottomEstimate.confidenceScore)
        #expect(topEstimate.confidence == .medium)
        #expect(bottomEstimate.confidence == .high)
    }

    @Test
    func exactSubtitlePhraseContributesCombinedMetadataCoverage() throws {
        let estimate = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(
                count: 3,
                ratingCount: 0,
                title: "Generic",
                subtitle: "A Focus Timer"
            )
        ))

        #expect(estimate.evidence.metadataSaturationScore == 75)
        #expect(estimate.evidence.exactTitlePhraseMatchCount == 0)
        #expect(estimate.evidence.exactSubtitlePhraseMatchCount == 3)
        #expect(estimate.score == 23)
    }

    @Test
    func dispersedTokensReceivePartialMetadataCredit() throws {
        let estimate = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(
                count: 3,
                ratingCount: 0,
                title: "Focus Work",
                subtitle: "A simple timer"
            )
        ))

        #expect(estimate.evidence.metadataSaturationScore == 75)
        #expect(estimate.evidence.exactTitlePhraseMatchCount == 0)
        #expect(estimate.evidence.exactSubtitlePhraseMatchCount == 0)
        #expect(estimate.score == 23)
    }

    @Test
    func matchingIsCaseDiacriticAndPunctuationInsensitiveButNotSubstringBased() throws {
        let matching = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "FOCUS timer",
            rankedResults: makeResults(
                count: 3,
                ratingCount: 0,
                title: "Generic",
                subtitle: "Fócus—Timer for Work"
            )
        ))
        let substring = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "car",
            rankedResults: makeResults(
                count: 3,
                ratingCount: 0,
                title: "Cart Planner"
            )
        ))

        #expect(matching.evidence.metadataSaturationScore == 75)
        #expect(matching.evidence.exactSubtitlePhraseMatchCount == 3)
        #expect(substring.evidence.metadataSaturationScore == 0)
        #expect(substring.evidence.exactTitlePhraseMatchCount == 0)
    }

    @Test
    func orderingDeduplicationAndTopTenBoundaryAreDeterministic() throws {
        var results = makeResults(count: 10, ratingCount: 0)
        results.append(makeResult(
            position: 2,
            appStoreID: 2,
            title: "Focus Timer",
            ratingCount: 99_999
        ))
        results.append(makeResult(
            position: 10,
            appStoreID: 99,
            title: "Focus Timer",
            ratingCount: 99_999
        ))
        results.append(makeResult(
            position: 11,
            appStoreID: 11,
            title: "Focus Timer",
            ratingCount: 99_999
        ))

        let forward = KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: results
        )
        let reversed = KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: Array(results.reversed())
        )
        let estimate = try requireEstimate(forward)

        #expect(forward == reversed)
        #expect(estimate.evidence.consideredResultCount == 10)
        #expect(estimate.evidence.resultEvidence.map(\.appStoreID).contains(11) == false)
        #expect(estimate.evidence.resultEvidence.filter { $0.appStoreID == 2 }.count == 1)
        #expect(estimate.evidence.resultEvidence.last?.appStoreID == 10)
    }

    @Test
    func duplicateConflictPrefersValidRatingEvidenceDeterministically() throws {
        let duplicates = [
            makeResult(
                position: 1,
                appStoreID: 1,
                title: "A Missing Result",
                subtitle: nil,
                ratingCount: nil
            ),
            makeResult(
                position: 1,
                appStoreID: 1,
                title: "Z Valid Result",
                subtitle: "Different subtitle",
                ratingCount: 99_999
            ),
            makeResult(position: 2, appStoreID: 2, ratingCount: 0),
            makeResult(position: 3, appStoreID: 3, ratingCount: 0)
        ]

        let forward = KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: duplicates
        )
        let reversed = KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: Array(duplicates.reversed())
        )

        #expect(forward == reversed)
        let estimate = try requireEstimate(forward)
        #expect(estimate.evidence.ratedResultCount == 3)
        #expect(estimate.evidence.resultEvidence.first?.ratingCount == 99_999)
    }

    @Test
    func reportsConventionalOddAndEvenRatingMedians() throws {
        let odd = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: [
                makeResult(position: 1, appStoreID: 1, ratingCount: 0),
                makeResult(position: 2, appStoreID: 2, ratingCount: 50_000),
                makeResult(position: 3, appStoreID: 3, ratingCount: 100_000)
            ]
        ))
        let even = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: [
                makeResult(position: 1, appStoreID: 1, ratingCount: 0),
                makeResult(position: 2, appStoreID: 2, ratingCount: 0),
                makeResult(position: 3, appStoreID: 3, ratingCount: 100_000),
                makeResult(position: 4, appStoreID: 4, ratingCount: 100_000)
            ]
        ))

        #expect(odd.evidence.medianRatingCount == 50_000)
        #expect(even.evidence.medianRatingCount == 50_000)
    }

    @Test
    func searchResultAdapterIgnoresExcludedRankingFields() {
        let rankedResults = makeResults(
            count: 3,
            ratingCount: 999,
            title: "Focus Timer"
        )
        let searchResults = rankedResults.map { result in
            SearchRankingItem(
                position: result.position,
                appStoreID: result.appStoreID,
                bundleID: "com.example.\(result.appStoreID)",
                name: result.title,
                subtitle: result.subtitle,
                sellerName: "Example",
                descriptionText: "Excluded evidence",
                screenshotURLs: ["https://example.com/screenshot.png"],
                ratingCount: result.ratingCount,
                averageRating: Double(result.position),
                platform: .ipad
            )
        }

        #expect(
            KeywordDifficultyEstimator.estimate(
                keyword: "focus timer",
                rankedResults: rankedResults
            ) == KeywordDifficultyEstimator.estimate(
                keyword: "focus timer",
                searchResults: searchResults
            )
        )
    }

    @Test
    func exposesStableVersionPerResultEvidenceAndHonestNotes() throws {
        let estimate = try requireEstimate(KeywordDifficultyEstimator.estimate(
            keyword: "focus timer",
            rankedResults: makeResults(count: 10, ratingCount: 999)
        ))

        #expect(estimate.algorithmIdentifier == "top10-authority-saturation")
        #expect(estimate.algorithmVersion == 1)
        #expect(estimate.evidence.resultEvidence.count == 10)
        #expect(estimate.notes.contains { $0.contains("Heuristic estimated competition") })
        #expect(estimate.notes.contains { $0.contains("70%") && $0.contains("30%") })
        #expect(estimate.notes.contains { $0.contains("not Apple Ads difficulty") })
        #expect(estimate.notes.contains { $0.contains("confidence high") })
    }
}

private enum KeywordDifficultyEstimatorTestError: Error {
    case expectedEstimate
    case expectedUnavailable
}

private func requireEstimate(
    _ result: KeywordDifficultyEstimation
) throws -> EstimatedKeywordDifficulty {
    guard case .estimated(let estimate) = result else {
        throw KeywordDifficultyEstimatorTestError.expectedEstimate
    }
    return estimate
}

private func requireUnavailable(
    _ result: KeywordDifficultyEstimation
) throws -> KeywordDifficultyUnavailable {
    guard case .unavailable(let unavailable) = result else {
        throw KeywordDifficultyEstimatorTestError.expectedUnavailable
    }
    return unavailable
}

private func makeResults(
    count: Int,
    ratingCount: Int?,
    title: String = "Generic App",
    subtitle: String? = nil
) -> [KeywordDifficultyRankedResult] {
    (0..<count).map { index in
        let position = index + 1
        return makeResult(
            position: position,
            appStoreID: Int64(position),
            title: title,
            subtitle: subtitle,
            ratingCount: ratingCount
        )
    }
}

private func makeResult(
    position: Int,
    appStoreID: Int64,
    title: String = "Generic App",
    subtitle: String? = nil,
    ratingCount: Int?
) -> KeywordDifficultyRankedResult {
    KeywordDifficultyRankedResult(
        position: position,
        appStoreID: appStoreID,
        title: title,
        subtitle: subtitle,
        ratingCount: ratingCount
    )
}
