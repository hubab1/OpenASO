import CryptoKit
import Foundation
import MCP
import SwiftData
import Synchronization
import Testing
@testable import OpenASO

@MainActor
struct KeywordTargetingTests {
    @Test
    func auditCompetitionRequiresNativeRatedEvidenceAndDoesNotPersistIt() async throws {
        let fixture = try TargetingFixture()
        defer { fixture.cleanup() }
        fixture.state.value.withLock { $0.rank = nil; $0.competitorCount = 5 }
        let native = try await fixture.service.auditKeywordTargeting(appStoreID: 123, keywords: ["voice notes"], rankingLimit: 1)
        let competition = try #require(native.items.first?.competition)
        #expect(competition.score != nil)
        #expect(competition.confidence != nil)
        #expect(competition.evidence?.consideredResultCount == 5)
        #expect(competition.evidence?.ratedResultCount == 5)
        #expect(competition.algorithmIdentifier == "top10-authority-saturation")
        #expect(try fixture.context.fetchCount(FetchDescriptor<EstimatedKeywordDifficultyMetric>()) == 0)
        #expect(try fixture.context.fetchCount(FetchDescriptor<TrackedAppKeyword>()) == 0)
        fixture.state.value.withLock { $0.rankingSource = .iTunesFallback }
        let fallback = try await fixture.service.auditKeywordTargeting(appStoreID: 123, keywords: ["voice notes"], rankingLimit: 1)
        #expect(fallback.items.first?.competition?.score == nil)
        #expect(fallback.items.first?.competition?.unavailableReason == "native_ranking_required")
        fixture.state.value.withLock { $0.rankingSource = .appStoreWeb; $0.competitorCount = 1 }
        let sparse = try await fixture.service.auditKeywordTargeting(appStoreID: 123, keywords: ["voice notes"], rankingLimit: 1)
        #expect(sparse.items.first?.competition?.score == nil)
        #expect(sparse.items.first?.competition?.unavailableReason == "insufficientResults")
        fixture.state.value.withLock { $0.competitorCount = 5; $0.omitsRatings = true }
        let unrated = try await fixture.service.auditKeywordTargeting(appStoreID: 123, keywords: ["voice notes"], rankingLimit: 1)
        #expect(unrated.items.first?.competition?.score == nil)
        #expect(unrated.items.first?.competition?.unavailableReason == "insufficientRatingEvidence")
        let skipped = try await fixture.service.auditKeywordTargeting(appStoreID: 123, keywords: ["voice notes"], rankingLimit: 0)
        #expect(skipped.items.first?.competition == nil)
    }

    @Test
    func ownedMetadataSelectsLiveAndEditableWithoutMixingTheirFields() async throws {
        let fixture = try TargetingFixture()
        defer { fixture.cleanup() }
        let live = try await fixture.service.getAppStoreMetadata(appStoreID: 123)
        #expect(live.version == "1.0")
        #expect(live.fields.title == "Utter - Voice Notes")
        #expect(live.fields.keywords == "audio,meeting,recorder")
        let editable = try await fixture.service.getAppStoreMetadata(appStoreID: 123, scope: "editable")
        #expect(editable.version == "2.0")
        #expect(editable.fields.title == "Utter Draft")
        #expect(editable.fields.keywords == "draft")
        #expect(editable.contentHash != live.contentHash)
        let again = try await fixture.service.getAppStoreMetadata(appStoreID: 123)
        #expect(again.contentHash == live.contentHash)
        #expect(fixture.state.value.withLock { $0.methods.allSatisfy { $0 == "GET" } })
    }

    @Test
    func metadataRejectsMissingLocaleAmbiguousStateAndCredentialExfiltration() async throws {
        let fixture = try TargetingFixture()
        defer { fixture.cleanup() }
        await #expect(throws: OpenASOError.self) {
            _ = try await fixture.service.getAppStoreMetadata(appStoreID: 123, locale: "de-DE")
        }
        fixture.state.value.withLock { $0.ambiguousInfo = true }
        await #expect(throws: OpenASOError.self) {
            _ = try await fixture.service.getAppStoreMetadata(appStoreID: 123)
        }
        fixture.state.value.withLock { $0.ambiguousInfo = false; $0.unsafePagination = true }
        await #expect(throws: OpenASOError.self) {
            _ = try await fixture.service.getAppStoreMetadata(appStoreID: 123)
        }
        #expect(fixture.state.value.withLock { $0.hosts.allSatisfy { $0 == "api.appstoreconnect.apple.com" } })
    }

    @Test
    func coverageSeparatesPhrasesComponentsVariantsAndEnglishFiller() {
        let fields = AppStoreMetadataFields(title: "Utter - Voice Notes", subtitle: "AI Transcribe",
                                           keywords: "speech,audio,meeting,taker,text")
        let combined = KeywordTargetingAnalysis.coverage("AI meeting note taker", fields: fields, locale: "en-US")
        #expect(combined.status == "variant_combination")
        #expect(combined.missingTerms.isEmpty)
        #expect(combined.literalPhraseFields.isEmpty)
        #expect(KeywordTargetingAnalysis.coverage("voice notes", fields: fields, locale: "en-US").status == "literal_phrase")
        #expect(KeywordTargetingAnalysis.coverage("speech to text", fields: fields, locale: "en-US").missingTerms.isEmpty)
        #expect(KeywordTargetingAnalysis.coverage("note", fields: fields, locale: "fr-FR").missingTerms == ["note"])
        #expect(KeywordTargetingAnalysis.coverage("notebook", fields: fields, locale: "en-US").missingTerms == ["notebook"])
    }

    @Test
    func fieldValidationFindsOverflowDuplicatesPluralWasteAndMissingPrivateData() {
        let result = KeywordTargetingAnalysis.validate(.init(
            title: "Voice Notes", subtitle: "AI", keywords: "voice,note,free,to," + String(repeating: "x", count: 100)
        ), locale: "en-US")
        #expect(result.characterCounts["keywords"]! > 100)
        #expect(!result.errors.isEmpty)
        #expect(result.warnings.count >= 4)
        let unknown = KeywordTargetingAnalysis.validate(.init(title: "Utter", subtitle: "", keywords: nil), locale: "en-US")
        #expect(!unknown.warnings.isEmpty)
    }

    @Test
    func relevanceUsesTheActualAppAndItsOwnBrand() {
        let utter = KeywordAppContext(name: "Utter - Voice Notes", featureText: "Dictation and audio transcription")
        let atten = KeywordAppContext(name: "Atten - App Blocker", featureText: "Screen time and website limits")
        #expect(utter.relevance("dictation").score == 1)
        #expect(atten.relevance("dictation").score == 0)
        #expect(utter.relevance("Utter dictation").isOwnBrand)
        #expect(!utter.relevance("ScreenZen").isOwnBrand)
        #expect(atten.relevance("screen time limits").score == 1)
    }

    @Test
    func auditUsesFreshDemandButKeepsIrrelevantPopularityOutOfOpportunityBucket() async throws {
        let fixture = try TargetingFixture()
        defer { fixture.cleanup() }
        let audit = try await fixture.service.auditKeywordTargeting(
            appStoreID: 123, keywords: ["transcribe audio to text", "voice notes", "screen blocker"], rankingLimit: 0
        )
        let gap = try #require(audit.items.first { $0.keyword == "transcribe audio to text" })
        #expect(gap.coverage.missingTerms == ["text"])
        #expect(gap.popularity.popularityScore == 50)
        #expect(gap.opportunity == "metadata_gap")
        #expect(audit.items.first { $0.keyword == "screen blocker" }?.opportunity == "relevance_review")
        #expect(audit.items.first { $0.keyword == "voice notes" }?.coverage.status == "literal_phrase")
        #expect(try fixture.context.fetchCount(FetchDescriptor<KeywordDailyMetric>()) == 0)
        #expect(try fixture.context.fetchCount(FetchDescriptor<TrackedAppKeyword>()) == 0)
    }

    @Test
    func unavailablePrivateKeywordsRemainUnknownInsteadOfBecomingVerifiedGaps() async throws {
        let fixture = try TargetingFixture()
        defer { fixture.cleanup() }
        fixture.state.value.withLock { $0.omitsPrivateKeywords = true }
        let audit = try await fixture.service.auditKeywordTargeting(
            appStoreID: 123, keywords: ["transcribe audio to text"], rankingLimit: 0
        )
        #expect(audit.metadata.fields.keywords == nil)
        #expect(audit.items.first?.opportunity == "private_metadata_unknown")
        let draft = KeywordTargetingAnalysis.compare(
            audit, proposed: .init(title: audit.metadata.fields.title, subtitle: "Transcribe Audio to Text", keywords: "meeting")
        )
        #expect(draft.gainedCoverage.isEmpty)
        let baseline = try await fixture.service.recordMetadataBaseline(
            appStoreID: 123, keywords: ["transcribe audio to text"], rankingLimit: 0, label: "Incomplete private fields"
        )
        fixture.state.value.withLock { $0.omitsPrivateKeywords = false }
        let comparison = try await fixture.service.compareMetadataBaseline(baselineID: baseline.id)
        #expect(comparison.metadataChanged == nil)
    }

    @Test
    func draftComparisonShowsGainsLossesOverflowAndRejectsStaleBaseline() async throws {
        let fixture = try TargetingFixture()
        defer { fixture.cleanup() }
        let metadata = try await fixture.service.getAppStoreMetadata(appStoreID: 123)
        let draft = try await fixture.service.compareMetadataDraft(
            appStoreID: 123, keywords: ["transcribe audio to text", "voice notes"],
            proposedTitle: "Utter", proposedSubtitle: "Transcribe Audio to Text",
            expectedHash: metadata.contentHash
        )
        #expect(draft.gainedCoverage == ["transcribe audio to text"])
        #expect(draft.lostCoverage == ["voice notes"])
        #expect(draft.validation.errors.isEmpty)
        #expect(draft.validation.warnings.contains { $0.contains("voice notes") })
        fixture.state.value.withLock { $0.keywords = "changed" }
        await #expect(throws: OpenASOError.self) {
            _ = try await fixture.service.compareMetadataDraft(
                appStoreID: 123, proposedSubtitle: "New subtitle", expectedHash: metadata.contentHash
            )
        }
        let invalid = try await fixture.service.compareMetadataDraft(
            appStoreID: 123, keywords: ["voice notes"], proposedTitle: String(repeating: "x", count: 31)
        )
        #expect(!invalid.validation.errors.isEmpty)
    }

    @Test
    func draftFlagsRemovalOfOwnBrandAndNativeWinningCoverage() async throws {
        let fixture = try TargetingFixture()
        defer { fixture.cleanup() }
        let audit = try await fixture.service.auditKeywordTargeting(
            appStoreID: 123, keywords: ["voice notes"], rankingLimit: 1
        )
        let draft = KeywordTargetingAnalysis.compare(
            audit, proposed: .init(title: "Different Brand", subtitle: "", keywords: "")
        )
        #expect(draft.lostCoverage == ["voice notes"])
        #expect(draft.visibilityChanges.first?.beforeFields == ["title"])
        #expect(draft.visibilityChanges.first?.afterFields == [])
        #expect(draft.validation.warnings.contains { $0.contains("brand") })
        #expect(draft.validation.warnings.contains { $0.contains("voice notes") })
        #expect(draft.baselineMetadata.fields == audit.metadata.fields)
    }

    @Test
    func savedBaselinesSurviveNewStoreAndCompareOnlyTheSameQueries() async throws {
        let fixture = try TargetingFixture()
        defer { fixture.cleanup() }
        let baseline = try await fixture.service.recordMetadataBaseline(
            appStoreID: 123, keywords: ["voice notes", "transcribe audio to text"], rankingLimit: 1, label: "Before 1.1"
        )
        let reopened = MetadataBaselineStore(directory: fixture.directory)
        let restored = try await reopened.load(baseline.id)
        #expect(restored.audit.metadataHash == baseline.audit.metadataHash)
        #expect(try await reopened.list(appStoreID: 123).map(\.id) == [baseline.id])
        await #expect(throws: OpenASOError.self) { try await reopened.save(baseline) }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.directory.appendingPathComponent(baseline.id.uuidString + ".json").path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        fixture.state.value.withLock { $0.rank = 1; $0.keywords = "audio,meeting,recorder,text"; $0.version = "1.1" }
        let comparison = try await fixture.service.compareMetadataBaseline(baselineID: baseline.id)
        #expect(comparison.metadataChanged == true)
        #expect(comparison.versionChanged)
        #expect(comparison.gainedCoverage == ["transcribe audio to text"])
        #expect(Set(comparison.before.items.map(\.keyword)) == Set(comparison.after.items.map(\.keyword)))
        #expect(comparison.rankChanges.contains { $0.nativeRankImprovement == 2 })
    }

    @Test
    func fallbackAndAbsentRanksNeverProduceNativeImprovement() async throws {
        let fixture = try TargetingFixture()
        defer { fixture.cleanup() }
        fixture.state.value.withLock { $0.rankingSource = .iTunesFallback }
        let baseline = try await fixture.service.recordMetadataBaseline(
            appStoreID: 123, keywords: ["voice notes"], rankingLimit: 1, label: "Fallback"
        )
        fixture.state.value.withLock { $0.rank = 1 }
        let fallback = try await fixture.service.compareMetadataBaseline(baselineID: baseline.id)
        #expect(fallback.rankChanges.allSatisfy { $0.nativeRankImprovement == nil })
        #expect(fallback.after.items.first?.opportunity == "ranking_needs_verification")
        fixture.state.value.withLock { $0.rankingSource = .appStoreWeb; $0.rank = nil }
        let absent = try await fixture.service.compareMetadataBaseline(baselineID: baseline.id)
        #expect(absent.rankChanges.allSatisfy { $0.nativeRankImprovement == nil })
    }

    @Test
    func acquisitionEvidenceRequiresPeriodsAndRetainsCallerProvenance() async throws {
        let fixture = try TargetingFixture()
        defer { fixture.cleanup() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let invalid = MetadataAcquisitionEvidence(periodStart: start, periodEnd: start,
                                                  searchImpressions: -1, searchDownloads: nil, source: "caller_provided")
        #expect(throws: OpenASOError.self) { try invalid.validate() }
        let old = MetadataAcquisitionEvidence(periodStart: start, periodEnd: start.addingTimeInterval(604_800),
                                              searchImpressions: 100, searchDownloads: 10, source: "caller_provided")
        let baseline = try await fixture.service.recordMetadataBaseline(
            appStoreID: 123, keywords: ["voice notes"], rankingLimit: 0, label: "Analytics", acquisition: old
        )
        let current = MetadataAcquisitionEvidence(periodStart: start.addingTimeInterval(604_800),
                                                  periodEnd: start.addingTimeInterval(1_814_400),
                                                  searchImpressions: 200, searchDownloads: 18, source: "caller_provided")
        let compared = try await fixture.service.compareMetadataBaseline(baselineID: baseline.id, acquisition: current)
        #expect(compared.acquisitionBefore == old)
        #expect(compared.acquisitionAfter == current)
        #expect(compared.notes.contains { $0.contains("different lengths") })
    }

    @Test
    func metadataWorkflowRoundTripsOverMCPAndPublishesNothing() async throws {
        let fixture = try TargetingFixture()
        defer { fixture.cleanup() }
        let server = await OpenASOMCPServerFactory(service: fixture.service).makeServer()
        let client = Client(name: "Metadata workflow test", version: "1")
        let pair = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: pair.server)
        do {
            _ = try await client.connect(transport: pair.client)
            let tools = try await client.listTools().tools
            #expect(tools.first { $0.name == "compare_metadata_draft" }?.annotations.readOnlyHint == true)
            #expect(tools.first { $0.name == "record_metadata_baseline" }?.annotations.readOnlyHint == false)
            let snapshotResponse = try await client.callTool(name: "get_app_store_metadata", arguments: [
                "appStoreID": 123, "locale": "en-US"
            ])
            let snapshotText = try #require(snapshotResponse.content.first?.metadataText)
            let snapshotJSON = try #require(JSONSerialization.jsonObject(with: Data(snapshotText.utf8)) as? [String: Any])
            #expect((snapshotJSON["contentHash"] as? String)?.count == 64)
            let response = try await client.callTool(name: "record_metadata_baseline", arguments: [
                "appStoreID": 123, "locale": "en-US", "storefront": "us", "keywords": ["voice notes"],
                "ranking_limit": 0, "label": "MCP baseline",
            ])
            let text = try #require(response.content.first?.metadataText)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let baseline = try decoder.decode(MetadataBaseline.self, from: Data(text.utf8))
            let compared = try await client.callTool(name: "compare_metadata_baseline", arguments: [
                "baseline_id": .string(baseline.id.uuidString)
            ])
            let comparedText = try #require(compared.content.first?.metadataText)
            let result = try decoder.decode(MetadataBaselineComparison.self, from: Data(comparedText.utf8))
            #expect(result.metadataChanged == false)
            #expect(result.after.items.map(\.keyword) == ["voice notes"])
            #expect(fixture.state.value.withLock { $0.methods.allSatisfy { $0 == "GET" } })
            await client.disconnect()
            await server.stop()
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
    }
}

private struct TargetingState: Sendable {
    var keywords = "audio,meeting,recorder"
    var version = "1.0"
    var competitorCount = 0
    var omitsRatings = false
    var rank: Int? = 3
    var rankingSource: RankingSource = .appStoreWeb
    var ambiguousInfo = false
    var unsafePagination = false
    var omitsPrivateKeywords = false
    var methods: [String] = []
    var hosts: [String] = []
}

@MainActor
private struct TargetingFixture {
    let directory: URL
    let state: TargetingSharedState
    let service: OpenASOMCPService
    let context: ModelContext

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-tests-" + UUID().uuidString)
        let state = TargetingSharedState()
        self.state = state
        let client = MockHTTPClient { request in
            let url = try #require(request.url)
            let current = state.value.withLock {
                $0.methods.append(request.httpMethod ?? "GET"); $0.hosts.append(url.host ?? "")
                return $0
            }
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            var records: [[String: Any]]
            switch url.path {
            case "/v1/apps/123/appStoreVersions":
                records = [
                    ["id": "live-" + current.version, "attributes": ["versionString": current.version, "appVersionState": "READY_FOR_DISTRIBUTION", "createdDate": "2026-10-01T00:00:00Z"]],
                    ["id": "draft", "attributes": ["versionString": "2.0", "appVersionState": "PREPARE_FOR_SUBMISSION", "createdDate": "2026-10-20T00:00:00Z"]],
                    ["id": "old-replaced", "attributes": ["versionString": "0.9", "appVersionState": "REPLACED_WITH_NEW_VERSION", "appStoreState": "READY_FOR_SALE", "createdDate": "2026-10-24T00:00:00Z"]],
                ]
            case "/v1/apps/123/appInfos":
                records = [
                    ["id": "info-live", "attributes": ["state": "READY_FOR_DISTRIBUTION"]],
                    ["id": "info-edit", "attributes": ["state": "PREPARE_FOR_SUBMISSION"]],
                ]
                if current.ambiguousInfo { records.append(["id": "other", "attributes": ["state": "READY_FOR_DISTRIBUTION"]]) }
            case "/v1/appInfos/info-live/appInfoLocalizations":
                records = [["id": "name", "attributes": ["locale": "en-US", "name": "Utter - Voice Notes", "subtitle": "AI Transcribe"]]]
            case "/v1/appInfos/info-edit/appInfoLocalizations":
                records = [["id": "name-draft", "attributes": ["locale": "en-US", "name": "Utter Draft", "subtitle": "New subtitle"]]]
            case "/v1/appStoreVersions/draft/appStoreVersionLocalizations":
                records = [["id": "text-draft", "attributes": ["locale": "en-US", "keywords": "draft"]]]
            case "/v1/appStoreVersions/live-" + current.version + "/appStoreVersionLocalizations":
                var attributes: [String: Any] = [
                    "locale": "en-US", "keywords": current.keywords,
                    "description": "Voice notes and audio transcription. Dictation keyboard and meeting notes."
                ]
                if current.omitsPrivateKeywords { attributes.removeValue(forKey: "keywords") }
                records = [["id": "text", "attributes": attributes]]
            default:
                throw OpenASOError.unexpectedResponse
            }
            var body: [String: Any] = ["data": records]
            if current.unsafePagination && url.path.hasSuffix("appStoreVersions") {
                body["links"] = ["next": "https://untrusted.example/steal"]
            }
            return (try JSONSerialization.data(withJSONObject: body), makeHTTPURLResponse(url: url, statusCode: 200))
        }
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        context = ModelContext(container)
        let defaults = try #require(UserDefaults(suiteName: "metadata-tests-" + UUID().uuidString))
        let keychain = InMemoryKeychainService()
        let credentials = AppleAdsCredentialStore(defaults: defaults, keychain: keychain, loadsEnvironmentCredentials: false)
        try credentials.saveAPICredentials(.init(clientID: "c", teamID: "t", keyID: "k", privateKey: "fixture"))
        let ads = StaticAppleAdsPlatformAPI(apps: [], popularityRows: [
            ("voice notes", 49), ("transcribe audio to text", 50), ("screen blocker", 99)
        ].map {
            .init(searchTerm: $0.0, countryOrRegion: "US", genre: "Productivity", week: "2026-10-17",
                  month: nil, rankInGenre: nil, popularityInGenre: nil, popularity1to100: $0.1, popularity1to5: nil)
        })
        let metrics = KeywordMetricsService(httpClient: client, credentialStore: credentials,
                                           settingsStore: AppSettingsStore(defaults: defaults),
                                           webSessionStore: AppleAdsWebSessionStore(defaults: defaults, keychain: keychain),
                                           apiClient: ads)
        let resolver = DefaultAppResolver(httpClient: client)
        let asc = AppStoreConnectCredentials(issuerID: "issuer", keyID: "key", privateKey: P256.Signing.PrivateKey().pemRepresentation)
        service = OpenASOMCPService(
            backgroundModelStore: BackgroundModelStore(modelContainer: container), appResolver: resolver,
            appCatalogService: AppCatalogService(appResolver: resolver), httpClient: client,
            rankingProvider: TargetingRankingProvider(state: state), keywordMetricsService: metrics,
            appStoreConnectCredentialsProvider: { asc }, metadataBaselineStore: MetadataBaselineStore(directory: directory),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private struct TargetingRankingProvider: SearchRankingProvider {
    let state: TargetingSharedState

    func search(keyword: String, storefrontCode: String, platform: AppPlatform, limit: Int) async throws -> SearchRankingPage {
        let current = state.value.withLock { $0 }
        var items: [SearchRankingItem] = current.rank.map { position in
            [.init(position: position, appStoreID: 123, bundleID: "com.test.utter", name: "Utter",
                   sellerName: "Test", iconURLString: nil, primaryGenreName: "Productivity",
                   screenshotURLs: [], ratingCount: 20, averageRating: 4.5, platform: platform)]
        } ?? []
        for position in 0..<current.competitorCount {
            items.append(.init(position: position + 1, appStoreID: Int64(200 + position), bundleID: nil,
                               name: "Voice Notes Transcribe", sellerName: "Competitor", iconURLString: nil,
                               primaryGenreName: "Productivity", screenshotURLs: [],
                               ratingCount: current.omitsRatings ? nil : 100 + position * 100,
                               averageRating: 4.5, platform: platform))
        }
        return SearchRankingPage(items: items, source: current.rankingSource)
    }
}

private final class TargetingSharedState: Sendable {
    let value = Mutex(TargetingState())
}

private extension Tool.Content {
    var metadataText: String? {
        if case .text(let value, _, _) = self { return value }
        return nil
    }
}
