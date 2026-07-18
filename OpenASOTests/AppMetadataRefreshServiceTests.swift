import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
struct AppMetadataRefreshServiceTests {
    private let appStoreID: Int64 = 13_013

    @Test
    func scopeNormalizesDeduplicatesOrdersRequestsAndReportsProgress() async throws {
        let probe = MetadataProviderProbe()
        let store = StubMetadataRefreshStore(scope: AppMetadataRefreshStoredScope(
            defaultStorefront: " JP ",
            trackedStorefronts: ["gb", " JP ", "ca", "gb"]
        ))
        let iconInvalidator = RecordingMetadataIconInvalidator()
        let progressRecorder = MetadataProgressRecorder()
        let resolver = ClosureMetadataAppResolver { appStoreID, storefront in
            await probe.begin("itunes:\(storefront)")
            await probe.end()
            return makeMetadataResolvedApp(
                appStoreID: appStoreID,
                storefront: storefront
            )
        }
        let webProvider = ClosureMetadataWebProvider { appStoreID, storefront in
            await probe.begin("web:\(storefront)")
            await probe.end()
            return makeMetadataWebResponse(
                appStoreID: appStoreID,
                storefront: storefront
            )
        }
        let service = AppMetadataRefreshService(
            appResolver: resolver,
            webMetadataProvider: webProvider,
            store: store,
            iconInvalidator: iconInvalidator
        )

        let result = try await service.refresh(AppMetadataRefreshRequest(
            appStoreID: appStoreID,
            requestedStorefronts: [" DE ", "jp", "fr", "de"]
        )) { event in
            await progressRecorder.record(event)
        }

        let expectedStorefronts = ["jp", "de", "fr", "ca", "gb"]
        #expect(result.defaultStorefront == "jp")
        #expect(result.storefronts.map(\.storefront) == expectedStorefronts)
        #expect(result.status == .succeeded)
        #expect(result.succeededStorefrontCount == expectedStorefronts.count)
        #expect(result.persistedStorefrontCount == expectedStorefronts.count)
        #expect(await probe.maximumInFlight() == 1)
        #expect(await probe.events() == expectedStorefronts.flatMap { storefront in
            ["itunes:\(storefront)", "web:\(storefront)"]
        })
        #expect(await store.successfulPersistenceRecords().map(\.storefront) == expectedStorefronts.flatMap {
            [$0, $0]
        })

        let progress = await progressRecorder.events()
        #expect(progress.first == .batchStarted(
            appStoreID: appStoreID,
            storefronts: expectedStorefronts
        ))
        #expect(progress.last == .batchFinished(result))
        #expect(progress.compactMap { event -> String? in
            guard case .storefrontStarted(let storefront, _, _) = event else { return nil }
            return storefront
        } == expectedStorefronts)
        #expect(progress.compactMap { event -> String? in
            guard case .storefrontFinished(let outcome, _, _) = event else { return nil }
            return outcome.storefront
        } == expectedStorefronts)
    }

    @Test
    func productionStoreKeepsDefaultCanonicalAndRetainsPerStorefrontScreenshots() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let oldIconURL = "https://example.com/old-icon.png"
        try insertTrackedApp(
            appStoreID: appStoreID,
            defaultStorefront: "us",
            iconURLString: oldIconURL,
            trackedStorefronts: ["jp"],
            in: modelContext
        )
        try modelContext.save()

        let usReleaseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let usCurrentVersionReleaseDate = Date(timeIntervalSince1970: 1_710_000_000)
        let japanReleaseDate = Date(timeIntervalSince1970: 1_600_000_000)
        let japanCurrentVersionReleaseDate = Date(timeIntervalSince1970: 1_720_000_000)
        let resolver = ClosureMetadataAppResolver { appStoreID, storefront in
            makeMetadataResolvedApp(
                appStoreID: appStoreID,
                storefront: storefront,
                bundleID: storefront == "us" ? "com.example.us-canonical" : "com.example.jp-localized",
                name: storefront == "us" ? "US iTunes Name" : "Japan iTunes Name",
                sellerName: storefront == "us" ? "US iTunes Seller" : "Japan iTunes Seller",
                iconURLString: storefront == "us"
                    ? "https://example.com/new-icon.png"
                    : "https://example.com/japan-icon.png",
                screenshots: ["https://example.com/\(storefront)-itunes.png"],
                supportedLanguageCodes: storefront == "us" ? ["en-US", "fr"] : ["ja"],
                releaseDate: storefront == "us" ? usReleaseDate : japanReleaseDate,
                currentVersionReleaseDate: storefront == "us"
                    ? usCurrentVersionReleaseDate
                    : japanCurrentVersionReleaseDate,
                version: storefront == "us" ? "1.0-US" : "2.0-JP",
                primaryGenreID: storefront == "us" ? 6002 : 6014,
                primaryGenreName: storefront == "us" ? "US Utilities" : "Japan Games",
                defaultPlatform: storefront == "us" ? .iphone : .ipad
            )
        }
        let webProvider = ClosureMetadataWebProvider { appStoreID, storefront in
            makeMetadataWebResponse(
                appStoreID: appStoreID,
                storefront: storefront,
                name: storefront == "us" ? "US Web Name" : "Japan Web Name",
                subtitle: storefront == "us" ? "US Web Subtitle" : "Japan Web Subtitle",
                sellerName: storefront == "us" ? "US Web Seller" : "Japan Web Seller",
                screenshots: storefront == "us"
                    ? ["https://example.com/us-web.png"]
                    : []
            )
        }
        let backgroundStore = BackgroundModelStore(modelContainer: container)
        let iconInvalidator = RecordingMetadataIconInvalidator()
        let service = AppMetadataRefreshService(
            appResolver: resolver,
            webMetadataProvider: webProvider,
            store: SwiftDataAppMetadataRefreshStore(
                backgroundModelStore: backgroundStore,
                appCatalogService: AppCatalogService(appResolver: resolver)
            ),
            iconInvalidator: iconInvalidator
        )

        let result = try await service.refresh(AppMetadataRefreshRequest(appStoreID: appStoreID))
        let snapshot = try await persistedMetadataSnapshot(
            appStoreID: appStoreID,
            using: backgroundStore
        )

        #expect(result.storefronts.map(\.storefront) == ["us", "jp"])
        #expect(result.status == .succeeded)
        #expect(result.iconInvalidated)
        #expect(await iconInvalidator.appStoreIDs() == [appStoreID])
        #expect(snapshot.bundleID == "com.example.us-canonical")
        #expect(snapshot.name == "US Web Name")
        #expect(snapshot.subtitle == "US Web Subtitle")
        #expect(snapshot.sellerName == "US Web Seller")
        #expect(snapshot.iconURLString == "https://example.com/new-icon.png")
        #expect(snapshot.defaultStorefront == "us")
        #expect(snapshot.supportedLanguageCodes == ["EN-US", "FR"])
        #expect(snapshot.supportedLanguageCodesSource == .iTunesLookup)
        #expect(snapshot.supportedLanguageCodesFetchedAt != nil)
        #expect(snapshot.releaseDate == usReleaseDate)
        #expect(snapshot.currentVersionReleaseDate == usCurrentVersionReleaseDate)
        #expect(snapshot.version == "1.0-US")
        #expect(snapshot.primaryGenreID == 6002)
        #expect(snapshot.primaryGenreName == "US Utilities")
        #expect(snapshot.defaultPlatform == .iphone)
        #expect(snapshot.metadata == [
            PersistedStorefrontMetadataSnapshot(
                storefront: "jp",
                name: "Japan Web Name",
                source: .appStoreWeb,
                screenshotURLs: ["https://example.com/jp-itunes.png"]
            ),
            PersistedStorefrontMetadataSnapshot(
                storefront: "us",
                name: "US Web Name",
                source: .appStoreWeb,
                screenshotURLs: ["https://example.com/us-web.png"]
            ),
        ])
    }

    @Test
    func strictRefreshRepairsExistingCanonicalStorefrontValues() async throws {
        let cases: [(rawDefault: String, expectedDefault: String, appStoreID: Int64)] = [
            (" GB ", "gb", appStoreID),
            ("   ", "us", appStoreID + 1),
        ]

        for testCase in cases {
            let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
            let modelContext = ModelContext(container)
            let storeApp = makeStoredApp(
                appStoreID: testCase.appStoreID,
                name: "Stale Name",
                iconURLString: "https://example.com/stale-icon.png",
                defaultStorefront: testCase.rawDefault
            )
            storeApp.defaultStorefront = testCase.rawDefault
            modelContext.insert(storeApp)
            try modelContext.save()

            let resolver = ClosureMetadataAppResolver { appStoreID, storefront in
                makeMetadataResolvedApp(
                    appStoreID: appStoreID,
                    storefront: storefront,
                    name: "Fresh iTunes Name",
                    sellerName: "Fresh Seller",
                    iconURLString: "https://example.com/fresh-icon.png",
                    supportedLanguageCodes: ["en"]
                )
            }
            let backgroundStore = BackgroundModelStore(modelContainer: container)
            let iconInvalidator = RecordingMetadataIconInvalidator()
            let service = AppMetadataRefreshService(
                appResolver: resolver,
                webMetadataProvider: ClosureMetadataWebProvider { appStoreID, storefront in
                    makeMetadataWebResponse(
                        appStoreID: appStoreID,
                        storefront: storefront,
                        name: "Fresh Web Name",
                        sellerName: "Fresh Web Seller"
                    )
                },
                store: SwiftDataAppMetadataRefreshStore(
                    backgroundModelStore: backgroundStore,
                    appCatalogService: AppCatalogService(appResolver: resolver)
                ),
                iconInvalidator: iconInvalidator
            )

            let result = try await service.refresh(AppMetadataRefreshRequest(
                appStoreID: testCase.appStoreID
            ))
            let snapshot = try await persistedMetadataSnapshot(
                appStoreID: testCase.appStoreID,
                using: backgroundStore
            )

            #expect(result.defaultStorefront == testCase.expectedDefault)
            #expect(result.storefronts.map(\.storefront) == [testCase.expectedDefault])
            #expect(result.iconInvalidated)
            #expect(await iconInvalidator.appStoreIDs() == [testCase.appStoreID])
            #expect(snapshot.defaultStorefront == testCase.expectedDefault)
            #expect(snapshot.name == "Fresh Web Name")
            #expect(snapshot.sellerName == "Fresh Web Seller")
            #expect(snapshot.iconURLString == "https://example.com/fresh-icon.png")
            #expect(snapshot.supportedLanguageCodes == ["EN"])
            #expect(snapshot.supportedLanguageCodesSource == .iTunesLookup)
        }
    }

    @Test
    func successfulCanonicalRefreshAdvancesUnchangedLanguageFreshness() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let staleFetchedAt = Date(timeIntervalSince1970: 1_600_000_000)
        let storeApp = makeStoredApp(
            appStoreID: appStoreID,
            name: "Existing Name",
            defaultStorefront: "us"
        )
        storeApp.supportedLanguageCodes = ["EN", "FR"]
        storeApp.supportedLanguageCodesSource = .iTunesLookup
        storeApp.supportedLanguageCodesFetchedAt = staleFetchedAt
        modelContext.insert(storeApp)
        try modelContext.save()

        let resolver = ClosureMetadataAppResolver { appStoreID, storefront in
            makeMetadataResolvedApp(
                appStoreID: appStoreID,
                storefront: storefront,
                supportedLanguageCodes: ["fr", "en"]
            )
        }
        let backgroundStore = BackgroundModelStore(modelContainer: container)
        let service = AppMetadataRefreshService(
            appResolver: resolver,
            webMetadataProvider: ClosureMetadataWebProvider { appStoreID, storefront in
                makeMetadataWebResponse(appStoreID: appStoreID, storefront: storefront)
            },
            store: SwiftDataAppMetadataRefreshStore(
                backgroundModelStore: backgroundStore,
                appCatalogService: AppCatalogService(appResolver: resolver)
            ),
            iconInvalidator: RecordingMetadataIconInvalidator()
        )

        _ = try await service.refresh(AppMetadataRefreshRequest(appStoreID: appStoreID))
        let snapshot = try await persistedMetadataSnapshot(
            appStoreID: appStoreID,
            using: backgroundStore
        )

        #expect(snapshot.supportedLanguageCodes == ["EN", "FR"])
        #expect(snapshot.supportedLanguageCodesSource == .iTunesLookup)
        #expect(snapshot.supportedLanguageCodesFetchedAt.map { $0 > staleFetchedAt } == true)
    }

    @Test
    func webFallbackPersistsWhenITunesCannotResolveTheApp() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let backgroundStore = BackgroundModelStore(modelContainer: container)
        let resolver = ClosureMetadataAppResolver { _, _ in
            throw OpenASOError.appNotFound
        }
        let webProvider = ClosureMetadataWebProvider { appStoreID, storefront in
            makeMetadataWebResponse(
                appStoreID: appStoreID,
                storefront: storefront,
                name: "Web-only App",
                screenshots: ["https://example.com/web-only.png"]
            )
        }
        let service = AppMetadataRefreshService(
            appResolver: resolver,
            webMetadataProvider: webProvider,
            store: SwiftDataAppMetadataRefreshStore(
                backgroundModelStore: backgroundStore,
                appCatalogService: AppCatalogService(appResolver: resolver)
            ),
            iconInvalidator: RecordingMetadataIconInvalidator()
        )

        let result = try await service.refresh(AppMetadataRefreshRequest(
            appStoreID: appStoreID,
            requestedStorefronts: ["jp"]
        ))
        let snapshot = try await persistedMetadataSnapshot(
            appStoreID: appStoreID,
            using: backgroundStore
        )

        #expect(result.status == .partial)
        #expect(result.storefronts.first?.status == .partial)
        #expect(providerFailureStage(result.storefronts.first?.iTunesLookup) == .fetch)
        #expect(snapshot.name == "Web-only App")
        #expect(snapshot.defaultStorefront == "jp")
        #expect(snapshot.metadata.first?.screenshotURLs == ["https://example.com/web-only.png"])
    }

    @Test
    func laterNondefaultSuccessCannotBecomeCanonicalWhenDefaultProvidersFail() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let backgroundStore = BackgroundModelStore(modelContainer: container)
        let resolver = ClosureMetadataAppResolver { appStoreID, storefront in
            guard storefront != "us" else {
                throw OpenASOError.appNotFound
            }
            return makeMetadataResolvedApp(
                appStoreID: appStoreID,
                storefront: storefront,
                bundleID: "com.example.jp-localized",
                name: "Japan iTunes Name",
                sellerName: "Japan Seller",
                iconURLString: "https://example.com/japan-icon.png",
                screenshots: ["https://example.com/japan-itunes.png"],
                supportedLanguageCodes: ["ja"],
                releaseDate: Date(timeIntervalSince1970: 1_600_000_000),
                currentVersionReleaseDate: Date(timeIntervalSince1970: 1_610_000_000),
                version: "2.0-JP",
                primaryGenreID: 6014,
                primaryGenreName: "Japan Games",
                defaultPlatform: .ipad
            )
        }
        let webProvider = ClosureMetadataWebProvider { appStoreID, storefront in
            guard storefront != "us" else {
                throw OpenASOError.appNotFound
            }
            return makeMetadataWebResponse(
                appStoreID: appStoreID,
                storefront: storefront,
                name: "Japan Web Name",
                subtitle: "Japan Web Subtitle",
                sellerName: "Japan Web Seller",
                screenshots: ["https://example.com/japan-web.png"]
            )
        }
        let iconInvalidator = RecordingMetadataIconInvalidator()
        let service = AppMetadataRefreshService(
            appResolver: resolver,
            webMetadataProvider: webProvider,
            store: SwiftDataAppMetadataRefreshStore(
                backgroundModelStore: backgroundStore,
                appCatalogService: AppCatalogService(appResolver: resolver)
            ),
            iconInvalidator: iconInvalidator
        )

        let result = try await service.refresh(AppMetadataRefreshRequest(
            appStoreID: appStoreID,
            requestedStorefronts: ["us", "jp"]
        ))
        let snapshot = try await persistedMetadataSnapshot(
            appStoreID: appStoreID,
            using: backgroundStore
        )

        #expect(result.defaultStorefront == "us")
        #expect(result.storefronts.map(\.status) == [.failed, .succeeded])
        #expect(result.status == .partial)
        #expect(!result.iconInvalidated)
        #expect(await iconInvalidator.appStoreIDs().isEmpty)
        #expect(snapshot.defaultStorefront == "us")
        #expect(snapshot.bundleID == nil)
        #expect(snapshot.name == "App \(appStoreID)")
        #expect(snapshot.subtitle == nil)
        #expect(snapshot.sellerName == nil)
        #expect(snapshot.iconURLString == nil)
        #expect(snapshot.supportedLanguageCodes.isEmpty)
        #expect(snapshot.supportedLanguageCodesSource == nil)
        #expect(snapshot.supportedLanguageCodesFetchedAt == nil)
        #expect(snapshot.releaseDate == nil)
        #expect(snapshot.currentVersionReleaseDate == nil)
        #expect(snapshot.version == nil)
        #expect(snapshot.primaryGenreID == nil)
        #expect(snapshot.primaryGenreName == nil)
        #expect(snapshot.defaultPlatform == .iphone)
        #expect(snapshot.metadata == [
            PersistedStorefrontMetadataSnapshot(
                storefront: "jp",
                name: "Japan Web Name",
                source: .appStoreWeb,
                screenshotURLs: ["https://example.com/japan-web.png"]
            ),
        ])
    }

    @Test
    func providerAndPersistenceFailuresArePerStorefrontAndDoNotStopLaterWork() async throws {
        let store = StubMetadataRefreshStore(
            scope: AppMetadataRefreshStoredScope(
                defaultStorefront: "us",
                trackedStorefronts: []
            ),
            failingPersistenceKeys: ["appStoreWeb:jp"]
        )
        let resolver = ClosureMetadataAppResolver { appStoreID, storefront in
            if storefront == "de" || storefront == "fr" {
                throw OpenASOError.networkUnavailable
            }
            return makeMetadataResolvedApp(appStoreID: appStoreID, storefront: storefront)
        }
        let webProvider = ClosureMetadataWebProvider { appStoreID, storefront in
            if storefront == "fr" {
                throw OpenASOError.decodingFailed
            }
            return makeMetadataWebResponse(appStoreID: appStoreID, storefront: storefront)
        }
        let service = AppMetadataRefreshService(
            appResolver: resolver,
            webMetadataProvider: webProvider,
            store: store,
            iconInvalidator: RecordingMetadataIconInvalidator()
        )

        let result = try await service.refresh(AppMetadataRefreshRequest(
            appStoreID: appStoreID,
            requestedStorefronts: ["jp", "de", "fr"]
        ))

        #expect(result.storefronts.map(\.status) == [
            .succeeded,
            .partial,
            .partial,
            .failed,
        ])
        #expect(result.status == .partial)
        #expect(result.persistedStorefrontCount == 3)
        #expect(result.failedStorefrontCount == 1)
        #expect(providerFailureStage(result.storefronts[1].appStoreWeb) == .persistence)
        #expect(providerFailureStage(result.storefronts[2].iTunesLookup) == .fetch)
        #expect(providerFailureStage(result.storefronts[3].iTunesLookup) == .fetch)
        #expect(providerFailureStage(result.storefronts[3].appStoreWeb) == .fetch)
        #expect(await store.successfulPersistenceRecords().map(\.storefront) == [
            "us", "us", "jp", "de",
        ])
    }

    @Test
    func mismatchedProviderResponsesAreRejectedWithoutPersistence() async throws {
        let store = StubMetadataRefreshStore(scope: AppMetadataRefreshStoredScope(
            defaultStorefront: "us",
            trackedStorefronts: []
        ))
        let resolver = ClosureMetadataAppResolver { appStoreID, storefront in
            makeMetadataResolvedApp(appStoreID: appStoreID + 1, storefront: storefront)
        }
        let webProvider = ClosureMetadataWebProvider { appStoreID, _ in
            makeMetadataWebResponse(appStoreID: appStoreID, storefront: "jp")
        }
        let service = AppMetadataRefreshService(
            appResolver: resolver,
            webMetadataProvider: webProvider,
            store: store,
            iconInvalidator: RecordingMetadataIconInvalidator()
        )

        let result = try await service.refresh(AppMetadataRefreshRequest(appStoreID: appStoreID))

        #expect(result.status == .failed)
        #expect(result.persistedStorefrontCount == 0)
        #expect(providerFailureStage(result.storefronts.first?.iTunesLookup) == .validation)
        #expect(providerFailureStage(result.storefronts.first?.appStoreWeb) == .validation)
        #expect(await store.persistenceAttempts().isEmpty)
    }

    @Test
    func invalidRequestsFailBeforeStartingProviders() async {
        let store = StubMetadataRefreshStore(scope: AppMetadataRefreshStoredScope(
            defaultStorefront: "us",
            trackedStorefronts: []
        ))
        let probe = MetadataProviderProbe()
        let service = AppMetadataRefreshService(
            appResolver: ClosureMetadataAppResolver { appStoreID, storefront in
                await probe.begin("itunes:\(storefront)")
                await probe.end()
                return makeMetadataResolvedApp(appStoreID: appStoreID, storefront: storefront)
            },
            webMetadataProvider: ClosureMetadataWebProvider { appStoreID, storefront in
                await probe.begin("web:\(storefront)")
                await probe.end()
                return makeMetadataWebResponse(appStoreID: appStoreID, storefront: storefront)
            },
            store: store,
            iconInvalidator: RecordingMetadataIconInvalidator()
        )

        await #expect(throws: AppMetadataRefreshServiceError.invalidAppStoreID) {
            _ = try await service.refresh(AppMetadataRefreshRequest(appStoreID: 0))
        }
        await #expect(throws: AppMetadataRefreshServiceError.emptyStorefrontScope) {
            _ = try await service.refresh(AppMetadataRefreshRequest(
                appStoreID: appStoreID,
                includesDefaultStorefront: false,
                includesTrackedStorefronts: false
            ))
        }
        #expect(await probe.events().isEmpty)
    }

    @Test
    func iconInvalidationRequiresACommittedDefaultStorefrontURLChange() async throws {
        let changedResult = AppMetadataRefreshPersistenceResult(
            canonicalIconURLBefore: "https://example.com/old.png",
            canonicalIconURLAfter: "https://example.com/new.png"
        )
        let unchangedResult = AppMetadataRefreshPersistenceResult(
            canonicalIconURLBefore: "https://example.com/new.png",
            canonicalIconURLAfter: "https://example.com/new.png"
        )
        let store = StubMetadataRefreshStore(
            scope: AppMetadataRefreshStoredScope(
                defaultStorefront: "us",
                trackedStorefronts: []
            ),
            persistenceResults: [
                "iTunesLookup:us": changedResult,
                "iTunesLookup:jp": unchangedResult,
                "appStoreWeb:us": unchangedResult,
                "appStoreWeb:jp": unchangedResult,
            ]
        )
        let invalidator = RecordingMetadataIconInvalidator()
        let service = makeSuccessfulService(store: store, iconInvalidator: invalidator)

        let result = try await service.refresh(AppMetadataRefreshRequest(
            appStoreID: appStoreID,
            requestedStorefronts: ["jp"]
        ))

        #expect(result.iconInvalidated)
        #expect(await invalidator.appStoreIDs() == [appStoreID])

        let unchangedStore = StubMetadataRefreshStore(
            scope: AppMetadataRefreshStoredScope(
                defaultStorefront: "us",
                trackedStorefronts: []
            ),
            persistenceResults: ["iTunesLookup:us": unchangedResult]
        )
        let unchangedInvalidator = RecordingMetadataIconInvalidator()
        let unchangedRefresh = try await makeSuccessfulService(
            store: unchangedStore,
            iconInvalidator: unchangedInvalidator
        ).refresh(AppMetadataRefreshRequest(appStoreID: appStoreID))

        #expect(!unchangedRefresh.iconInvalidated)
        #expect(await unchangedInvalidator.appStoreIDs().isEmpty)

        let failedStore = StubMetadataRefreshStore(
            scope: AppMetadataRefreshStoredScope(
                defaultStorefront: "us",
                trackedStorefronts: []
            ),
            failingPersistenceKeys: ["iTunesLookup:us"],
            persistenceResults: ["iTunesLookup:us": changedResult]
        )
        let failedInvalidator = RecordingMetadataIconInvalidator()
        let failedResult = try await makeSuccessfulService(
            store: failedStore,
            iconInvalidator: failedInvalidator
        ).refresh(AppMetadataRefreshRequest(appStoreID: appStoreID))

        #expect(!failedResult.iconInvalidated)
        #expect(await failedInvalidator.appStoreIDs().isEmpty)
    }

    @Test
    func cancellationPreservesCompletedProvidersAndDoesNotPublishFalseCompletion() async throws {
        let signal = MetadataAsyncSignal()
        let progressRecorder = MetadataProgressRecorder()
        let store = StubMetadataRefreshStore(scope: AppMetadataRefreshStoredScope(
            defaultStorefront: "us",
            trackedStorefronts: []
        ))
        let resolver = ClosureMetadataAppResolver { appStoreID, storefront in
            if storefront == "jp" {
                await signal.signal()
                try await Task.sleep(for: .seconds(60))
            }
            return makeMetadataResolvedApp(appStoreID: appStoreID, storefront: storefront)
        }
        let webProvider = ClosureMetadataWebProvider { appStoreID, storefront in
            makeMetadataWebResponse(appStoreID: appStoreID, storefront: storefront)
        }
        let service = AppMetadataRefreshService(
            appResolver: resolver,
            webMetadataProvider: webProvider,
            store: store,
            iconInvalidator: RecordingMetadataIconInvalidator()
        )
        let task = Task {
            try await service.refresh(AppMetadataRefreshRequest(
                appStoreID: appStoreID,
                requestedStorefronts: ["jp", "de"]
            )) { event in
                await progressRecorder.record(event)
            }
        }

        await signal.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        #expect(await store.successfulPersistenceRecords().map(\.storefront) == ["us", "us"])
        let progress = await progressRecorder.events()
        #expect(progress.contains { event in
            guard case .storefrontFinished(let outcome, _, _) = event else { return false }
            return outcome.storefront == "us"
        })
        #expect(!progress.contains { event in
            if case .batchFinished = event { return true }
            return false
        })
        #expect(!progress.contains { event in
            guard case .storefrontStarted(let storefront, _, _) = event else { return false }
            return storefront == "de"
        })
    }

    @Test
    func cancellationDuringStorefrontStartedProgressStopsBeforeProviders() async throws {
        let progressStarted = MetadataAsyncSignal()
        let releaseProgress = MetadataAsyncSignal()
        let providerProbe = MetadataProviderProbe()
        let store = StubMetadataRefreshStore(scope: AppMetadataRefreshStoredScope(
            defaultStorefront: "us",
            trackedStorefronts: []
        ))
        let service = AppMetadataRefreshService(
            appResolver: ClosureMetadataAppResolver { appStoreID, storefront in
                await providerProbe.begin("itunes:\(storefront)")
                await providerProbe.end()
                return makeMetadataResolvedApp(appStoreID: appStoreID, storefront: storefront)
            },
            webMetadataProvider: ClosureMetadataWebProvider { appStoreID, storefront in
                await providerProbe.begin("web:\(storefront)")
                await providerProbe.end()
                return makeMetadataWebResponse(appStoreID: appStoreID, storefront: storefront)
            },
            store: store,
            iconInvalidator: RecordingMetadataIconInvalidator()
        )
        let task = Task {
            try await service.refresh(AppMetadataRefreshRequest(appStoreID: appStoreID)) { event in
                guard case .storefrontStarted = event else { return }
                await progressStarted.signal()
                await releaseProgress.wait()
            }
        }

        await progressStarted.wait()
        task.cancel()
        await releaseProgress.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        #expect(await providerProbe.events().isEmpty)
        #expect(await store.persistenceAttempts().isEmpty)
    }

    @Test
    func backgroundWritesRollbackFailedMutationsBeforeTheNextSave() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let backgroundStore = BackgroundModelStore(modelContainer: container)
        let targetAppStoreID = appStoreID

        await #expect(throws: MetadataRefreshTestError.self) {
            let _: Void = try await backgroundStore.write { modelContext in
                modelContext.insert(makeStoredApp(appStoreID: targetAppStoreID, name: "Must Roll Back"))
                throw MetadataRefreshTestError.expected
            }
        }
        try await backgroundStore.write { modelContext in
            modelContext.insert(makeStoredApp(appStoreID: targetAppStoreID + 1, name: "Committed"))
        }
        let persistedIDs = try await backgroundStore.read { modelContext in
            try modelContext.fetch(FetchDescriptor<StoreApp>()).map(\.appStoreID).sorted()
        }

        #expect(persistedIDs == [targetAppStoreID + 1])
    }

    @Test
    func appServicesComposesRefreshServiceOnlyWhenAStoreExists() async throws {
        let withoutStore = AppServices.mocked(httpClient: MockHTTPClient { _ in
            throw OpenASOError.networkUnavailable
        })
        #expect(withoutStore.appMetadataRefreshService == nil)

        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        var requestedURLs: [URL] = []
        let withStore = AppServices.mocked(
            httpClient: MockHTTPClient { request in
                if let url = request.url {
                    requestedURLs.append(url)
                }
                throw OpenASOError.networkUnavailable
            },
            modelContainer: container
        )
        let service = try #require(withStore.appMetadataRefreshService)
        let result = try await service.refresh(AppMetadataRefreshRequest(
            appStoreID: appStoreID,
            requestedStorefronts: ["us"]
        ))

        #expect(result.status == .failed)
        #expect(requestedURLs.count == 2)
        #expect(requestedURLs[0].host == "itunes.apple.com")
        #expect(requestedURLs[0].path == "/lookup")
        #expect(requestedURLs[1].host == "apps.apple.com")
        #expect(requestedURLs[1].path == "/us/app/id\(appStoreID)")
    }

    private func makeSuccessfulService(
        store: any AppMetadataRefreshStoring,
        iconInvalidator: any AppIconInvalidating
    ) -> AppMetadataRefreshService {
        AppMetadataRefreshService(
            appResolver: ClosureMetadataAppResolver { appStoreID, storefront in
                makeMetadataResolvedApp(appStoreID: appStoreID, storefront: storefront)
            },
            webMetadataProvider: ClosureMetadataWebProvider { appStoreID, storefront in
                makeMetadataWebResponse(appStoreID: appStoreID, storefront: storefront)
            },
            store: store,
            iconInvalidator: iconInvalidator
        )
    }

    private func insertTrackedApp(
        appStoreID: Int64,
        defaultStorefront: String,
        iconURLString: String?,
        trackedStorefronts: [String],
        in modelContext: ModelContext
    ) throws {
        let storeApp = makeStoredApp(
            appStoreID: appStoreID,
            name: "Existing Name",
            iconURLString: iconURLString,
            defaultStorefront: defaultStorefront
        )
        let trackedApp = TrackedApp(appStoreID: appStoreID, storeApp: storeApp)
        modelContext.insert(storeApp)
        modelContext.insert(trackedApp)

        for (index, storefront) in trackedStorefronts.enumerated() {
            let term = "tracked-\(index)"
            let query = KeywordQuery(term: term, storefront: storefront, platform: .iphone)
            let track = TrackedAppKeyword(
                term: term,
                storefront: storefront,
                platform: .iphone,
                trackedApp: trackedApp,
                query: query
            )
            trackedApp.keywordTracks.append(track)
            query.tracks.append(track)
            modelContext.insert(query)
            modelContext.insert(track)
        }
    }
}

private final class ClosureMetadataAppResolver: AppResolver, Sendable {
    private let handler: @Sendable (Int64, String) async throws -> ResolvedApp

    init(handler: @escaping @Sendable (Int64, String) async throws -> ResolvedApp) {
        self.handler = handler
    }

    func resolve(appStoreID: Int64, storefrontCode: String) async throws -> ResolvedApp {
        try await handler(appStoreID, storefrontCode)
    }

    func searchApps(named query: String, storefrontCode: String, limit: Int) async throws -> [ResolvedApp] {
        []
    }
}

private final class ClosureMetadataWebProvider: AppStoreWebMetadataProviding, Sendable {
    private let handler: @Sendable (Int64, String) async throws -> AppStoreWebMetadata

    init(handler: @escaping @Sendable (Int64, String) async throws -> AppStoreWebMetadata) {
        self.handler = handler
    }

    func fetch(appStoreID: Int64, storefrontCode: String) async throws -> AppStoreWebMetadata {
        try await handler(appStoreID, storefrontCode)
    }
}

private actor StubMetadataRefreshStore: AppMetadataRefreshStoring {
    private let scope: AppMetadataRefreshStoredScope
    private let failingPersistenceKeys: Set<String>
    private let persistenceResults: [String: AppMetadataRefreshPersistenceResult]
    private var attempts: [MetadataPersistenceRecord] = []
    private var successfulRecords: [MetadataPersistenceRecord] = []

    init(
        scope: AppMetadataRefreshStoredScope,
        failingPersistenceKeys: Set<String> = [],
        persistenceResults: [String: AppMetadataRefreshPersistenceResult] = [:]
    ) {
        self.scope = scope
        self.failingPersistenceKeys = failingPersistenceKeys
        self.persistenceResults = persistenceResults
    }

    func loadScope(appStoreID: Int64) -> AppMetadataRefreshStoredScope {
        scope
    }

    func persist(
        resolvedApp: ResolvedApp,
        storefront: String,
        canonicalStorefront: String
    ) throws -> AppMetadataRefreshPersistenceResult {
        try persist(provider: .iTunesLookup, appStoreID: resolvedApp.appStoreID, storefront: storefront)
    }

    func persist(
        webMetadata: AppStoreWebMetadata,
        storefront: String,
        canonicalStorefront: String
    ) throws -> AppMetadataRefreshPersistenceResult {
        try persist(provider: .appStoreWeb, appStoreID: webMetadata.appStoreID, storefront: storefront)
    }

    func persistenceAttempts() -> [MetadataPersistenceRecord] {
        attempts
    }

    func successfulPersistenceRecords() -> [MetadataPersistenceRecord] {
        successfulRecords
    }

    private func persist(
        provider: AppMetadataRefreshProvider,
        appStoreID: Int64,
        storefront: String
    ) throws -> AppMetadataRefreshPersistenceResult {
        let record = MetadataPersistenceRecord(
            provider: provider,
            storefront: storefront,
            appStoreID: appStoreID
        )
        attempts.append(record)
        let key = "\(provider.rawValue):\(storefront)"
        if failingPersistenceKeys.contains(key) {
            throw MetadataRefreshTestError.expected
        }
        successfulRecords.append(record)
        return persistenceResults[key] ?? AppMetadataRefreshPersistenceResult(
            canonicalIconURLBefore: nil,
            canonicalIconURLAfter: nil
        )
    }
}

private struct MetadataPersistenceRecord: Sendable, Equatable {
    let provider: AppMetadataRefreshProvider
    let storefront: String
    let appStoreID: Int64
}

private actor RecordingMetadataIconInvalidator: AppIconInvalidating {
    private var invalidatedAppStoreIDs: [Int64] = []

    func invalidate(appStoreID: Int64) {
        invalidatedAppStoreIDs.append(appStoreID)
    }

    func appStoreIDs() -> [Int64] {
        invalidatedAppStoreIDs
    }
}

private actor MetadataProgressRecorder {
    private var recordedEvents: [AppMetadataRefreshProgress] = []

    func record(_ event: AppMetadataRefreshProgress) {
        recordedEvents.append(event)
    }

    func events() -> [AppMetadataRefreshProgress] {
        recordedEvents
    }
}

private actor MetadataProviderProbe {
    private var recordedEvents: [String] = []
    private var inFlight = 0
    private var maximum = 0

    func begin(_ event: String) {
        inFlight += 1
        maximum = max(maximum, inFlight)
        recordedEvents.append(event)
    }

    func end() {
        inFlight -= 1
    }

    func events() -> [String] {
        recordedEvents
    }

    func maximumInFlight() -> Int {
        maximum
    }
}

private actor MetadataAsyncSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignalled = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        if isSignalled {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct PersistedAppMetadataSnapshot: Sendable, Equatable {
    let bundleID: String?
    let name: String
    let subtitle: String?
    let sellerName: String?
    let iconURLString: String?
    let defaultStorefront: String
    let supportedLanguageCodes: [String]
    let supportedLanguageCodesSource: AppStorefrontMetadataSource?
    let supportedLanguageCodesFetchedAt: Date?
    let releaseDate: Date?
    let currentVersionReleaseDate: Date?
    let version: String?
    let primaryGenreID: Int?
    let primaryGenreName: String?
    let defaultPlatform: AppPlatform
    let metadata: [PersistedStorefrontMetadataSnapshot]
}

private struct PersistedStorefrontMetadataSnapshot: Sendable, Equatable {
    let storefront: String
    let name: String
    let source: AppStorefrontMetadataSource
    let screenshotURLs: [String]
}

private enum MetadataRefreshTestError: Error, Sendable {
    case expected
}

private func makeMetadataResolvedApp(
    appStoreID: Int64,
    storefront: String,
    bundleID: String? = nil,
    name: String? = nil,
    sellerName: String = "Fixture Seller",
    iconURLString: String? = nil,
    screenshots: [String] = [],
    supportedLanguageCodes: [String] = ["en"],
    releaseDate: Date? = nil,
    currentVersionReleaseDate: Date? = nil,
    version: String? = nil,
    primaryGenreID: Int? = nil,
    primaryGenreName: String? = nil,
    defaultPlatform: AppPlatform = .iphone
) -> ResolvedApp {
    ResolvedApp(
        appStoreID: appStoreID,
        bundleID: bundleID ?? "com.example.\(appStoreID)",
        name: name ?? "\(storefront.uppercased()) iTunes App",
        sellerName: sellerName,
        iconURLString: iconURLString,
        releaseDate: releaseDate,
        currentVersionReleaseDate: currentVersionReleaseDate,
        version: version,
        primaryGenreID: primaryGenreID,
        primaryGenreName: primaryGenreName,
        supportedLanguageCodes: supportedLanguageCodes,
        screenshotURLs: screenshots,
        defaultPlatform: defaultPlatform
    )
}

private func makeMetadataWebResponse(
    appStoreID: Int64,
    storefront: String,
    name: String? = nil,
    subtitle: String = "Web subtitle",
    sellerName: String = "Web Seller",
    screenshots: [String] = []
) -> AppStoreWebMetadata {
    let groups = screenshots.isEmpty ? [] : [
        AppStoreWebScreenshotGroup(
            platformRaw: "iphone",
            displayTypeRaw: "phone",
            screenshots: screenshots.map {
                AppStoreWebScreenshot(urlString: $0, width: 1_290, height: 2_796)
            }
        ),
    ]
    return AppStoreWebMetadata(
        appStoreID: appStoreID,
        storefront: storefront,
        name: name ?? "\(storefront.uppercased()) Web App",
        subtitle: subtitle,
        sellerName: sellerName,
        averageRating: nil,
        ratingCount: nil,
        screenshotGroups: groups
    )
}

private func makeStoredApp(
    appStoreID: Int64,
    name: String,
    iconURLString: String? = nil,
    defaultStorefront: String = "us"
) -> StoreApp {
    StoreApp(
        appStoreID: appStoreID,
        bundleID: "com.example.\(appStoreID)",
        name: name,
        sellerName: "Fixture Seller",
        iconURLString: iconURLString,
        defaultStorefront: defaultStorefront,
        defaultPlatform: .iphone
    )
}

private func providerFailureStage(
    _ outcome: AppMetadataRefreshProviderOutcome?
) -> AppMetadataRefreshFailure.Stage? {
    guard let outcome, case .failed(let failure) = outcome else {
        return nil
    }
    return failure.stage
}

private func persistedMetadataSnapshot(
    appStoreID: Int64,
    using backgroundStore: BackgroundModelStore
) async throws -> PersistedAppMetadataSnapshot {
    try await backgroundStore.read { modelContext in
        let targetAppStoreID = appStoreID
        var appDescriptor = FetchDescriptor<StoreApp>(
            predicate: #Predicate { app in
                app.appStoreID == targetAppStoreID
            }
        )
        appDescriptor.fetchLimit = 1
        guard let app = try modelContext.fetch(appDescriptor).first else {
            throw MetadataRefreshTestError.expected
        }
        let metadata = app.storefrontMetadata.map { row in
            PersistedStorefrontMetadataSnapshot(
                storefront: row.storefront,
                name: row.name,
                source: row.source,
                screenshotURLs: row.screenshots.map(\.urlString).sorted()
            )
        }.sorted { $0.storefront < $1.storefront }
        return PersistedAppMetadataSnapshot(
            bundleID: app.bundleID,
            name: app.name,
            subtitle: app.subtitle,
            sellerName: app.sellerName,
            iconURLString: app.iconURLString,
            defaultStorefront: app.defaultStorefront,
            supportedLanguageCodes: app.supportedLanguageCodes,
            supportedLanguageCodesSource: app.supportedLanguageCodesSource,
            supportedLanguageCodesFetchedAt: app.supportedLanguageCodesFetchedAt,
            releaseDate: app.releaseDate,
            currentVersionReleaseDate: app.currentVersionReleaseDate,
            version: app.version,
            primaryGenreID: app.primaryGenreID,
            primaryGenreName: app.primaryGenreName,
            defaultPlatform: app.defaultPlatform,
            metadata: metadata
        )
    }
}
