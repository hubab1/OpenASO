import Foundation
import SwiftData
import Testing
@testable import OpenASO

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HeadlessRefreshServiceTests {
    @Test
    func planLoaderBuildsDeterministicScopeAndCredentialSnapshots() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = container.mainContext

        let trackedApp = TrackedApp(
            appStoreID: 200,
            bundleID: "com.example.tracked",
            name: "Tracked App",
            subtitle: "Tracked subtitle",
            sellerName: "Tracked seller",
            defaultPlatform: .iphone
        )
        trackedApp.storeApp.defaultStorefront = "de"
        let firstTrack = try insertTrack(
            term: "First",
            storefront: " GB ",
            app: trackedApp,
            in: modelContext
        )
        let secondTrack = try insertTrack(
            term: "Second",
            storefront: "us",
            app: trackedApp,
            in: modelContext
        )

        let fallbackApp = TrackedApp(
            appStoreID: 100,
            bundleID: "com.example.fallback",
            name: "Fallback App",
            sellerName: "Fallback seller",
            defaultPlatform: .ipad
        )
        fallbackApp.storeApp.defaultStorefront = "  "

        let defaultApp = TrackedApp(
            appStoreID: 300,
            bundleID: nil,
            name: "Default App",
            sellerName: nil,
            defaultPlatform: .mac
        )
        defaultApp.storeApp.defaultStorefront = " JP "

        modelContext.insert(trackedApp)
        modelContext.insert(fallbackApp)
        modelContext.insert(defaultApp)
        try modelContext.save()

        var session = AppleAdsWebSession(
            cookieHeader: "session-cookie-sentinel",
            xsrfToken: "session-token-sentinel",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        var credentials = AppStoreConnectCredentials(
            issuerID: "issuer-sentinel",
            keyID: "key-sentinel",
            privateKey: "private-key-sentinel"
        )
        let capturedSession = session
        let capturedCredentials = credentials
        let loader = DailyRefreshPlanLoader(
            backgroundModelStore: BackgroundModelStore(modelContainer: container)
        )

        let plan = try await loader.load(configuration: DailyRefreshPlanConfiguration(
            fallbackStorefrontCodes: [" ca ", "US", "ca", ""],
            refreshRatingsAndReviews: true,
            popularityContextAppStoreID: 9_999,
            appleAdsWebSession: session,
            appStoreConnectCredentials: credentials
        ))

        session.cookieHeader = "mutated-cookie"
        session.xsrfToken = "mutated-token"
        credentials.privateKey = "mutated-private-key"
        trackedApp.name = "Mutated app name"
        trackedApp.storeApp.defaultStorefront = "fr"

        #expect(plan.apps.map(\.appStoreID) == [100, 200, 300])

        let fallbackPlan = try #require(plan.apps.first { $0.appStoreID == 100 })
        #expect(fallbackPlan.metadataRequest.requestedStorefronts == ["us"])
        #expect(!fallbackPlan.metadataRequest.includesDefaultStorefront)
        #expect(!fallbackPlan.metadataRequest.includesTrackedStorefronts)
        #expect(storefrontCodes(in: fallbackPlan.appDetailRequest) == ["us"])

        let trackedPlan = try #require(plan.apps.first { $0.appStoreID == 200 })
        #expect(trackedPlan.metadataRequest.requestedStorefronts == ["de", "gb", "us"])
        #expect(!trackedPlan.metadataRequest.includesDefaultStorefront)
        #expect(!trackedPlan.metadataRequest.includesTrackedStorefronts)
        #expect(storefrontCodes(in: trackedPlan.appDetailRequest) == ["gb", "us"])
        #expect(trackedPlan.appDetailRequest.trackIdentityKeys == [
            firstTrack.identityKey,
            secondTrack.identityKey,
        ].sorted())
        #expect(trackedPlan.appDetailRequest.app.name == "Tracked App")
        #expect(trackedPlan.appDetailRequest.app.subtitle == "Tracked subtitle")
        #expect(trackedPlan.appDetailRequest.trigger == "daily_refresh")
        #expect(trackedPlan.appDetailRequest.refreshKeywords)
        #expect(trackedPlan.appDetailRequest.refreshMetrics)
        #expect(trackedPlan.appDetailRequest.refreshRatings)
        #expect(trackedPlan.appDetailRequest.refreshReviews)
        #expect(!trackedPlan.appDetailRequest.recordsRatingsReviewsRefresh)
        #expect(trackedPlan.appDetailRequest.popularityContextAppStoreID == 9_999)
        #expect(trackedPlan.appDetailRequest.appleAdsWebSession == capturedSession)
        #expect(trackedPlan.appDetailRequest.appStoreConnectCredentials == capturedCredentials)

        let defaultPlan = try #require(plan.apps.first { $0.appStoreID == 300 })
        #expect(defaultPlan.metadataRequest.requestedStorefronts == ["jp"])
        #expect(storefrontCodes(in: defaultPlan.appDetailRequest) == ["jp"])
    }

    @Test
    func planLoaderRejectsAnInconsistentTrackOwnershipSnapshot() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = container.mainContext
        let app = TrackedApp(
            appStoreID: 400,
            bundleID: "com.example.inconsistent",
            name: "Inconsistent App",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        modelContext.insert(app)
        let track = try insertTrack(
            term: "Mismatch",
            storefront: "us",
            app: app,
            in: modelContext
        )
        track.appStoreID = 401
        try modelContext.save()

        let loader = DailyRefreshPlanLoader(
            backgroundModelStore: BackgroundModelStore(modelContainer: container)
        )
        await #expect(throws: DailyRefreshPlanLoaderError.inconsistentTrackedApp) {
            try await loader.load(configuration: makePlanConfiguration())
        }
    }

    @Test
    func planLoaderRejectsAStaleSameAppTrackIdentitySnapshot() async throws {
        let container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = container.mainContext
        let app = TrackedApp(
            appStoreID: 410,
            bundleID: "com.example.stale-identity",
            name: "Stale Identity App",
            sellerName: "Example",
            defaultPlatform: .iphone
        )
        modelContext.insert(app)
        let track = try insertTrack(
            term: "Expected",
            storefront: "us",
            app: app,
            in: modelContext
        )
        track.identityKey = TrackedAppKeyword.makeIdentityKey(
            appStoreID: app.appStoreID,
            term: "Different",
            storefront: track.storefront,
            platform: track.platform
        )
        try modelContext.save()

        let loader = DailyRefreshPlanLoader(
            backgroundModelStore: BackgroundModelStore(modelContainer: container)
        )
        await #expect(throws: DailyRefreshPlanLoaderError.inconsistentTrackedApp) {
            try await loader.load(configuration: makePlanConfiguration())
        }
    }

    @Test
    func zeroWorkFinishesOnceWithoutInvokingAnAppRefresh() async {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let instant = Date(timeIntervalSince1970: 1_000)
        let request = HeadlessRefreshRunRequest(
            id: runID,
            scheduledFor: instant,
            refreshRatingsAndReviews: true
        )
        let events = HeadlessRefreshEventRecorder()
        let appCalls = HeadlessRefreshAppCallRecorder()
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { _ in HeadlessRefreshPlan(apps: []) },
            refreshApp: { plan in
                await appCalls.record(plan.appStoreID)
                return .succeeded()
            },
            now: { instant },
            recordEvent: { event in await events.record(event) }
        ))

        let summary = await service.run(request)
        let snapshot = await service.snapshot()

        #expect(summary.disposition == .noWork)
        #expect(summary.plannedAppCount == 0)
        #expect(summary.completedAppCount == 0)
        #expect(summary.successfulAppCount == 0)
        #expect(summary.partialFailureAppCount == 0)
        #expect(summary.failedAppCount == 0)
        #expect(!summary.ratingsReviewsAttempted)
        #expect(!summary.ratingsReviewsFullySucceeded)
        #expect(summary.issue == nil)
        #expect(await appCalls.values().isEmpty)
        #expect(snapshot.activeRun == nil)
        #expect(snapshot.recentRuns == [summary])
        #expect(await events.values() == [
            .runStarted(runID: runID, scheduledFor: instant, startedAt: instant),
            .planLoaded(runID: runID, plannedAppCount: 0),
            .runFinished(summary),
        ])
    }

    @Test
    func sequentialAppFailuresContinueAndProduceAnExactPartialSummary() async throws {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let instant = Date(timeIntervalSince1970: 2_000)
        let request = HeadlessRefreshRunRequest(
            id: runID,
            scheduledFor: instant,
            refreshRatingsAndReviews: true
        )
        let plan = HeadlessRefreshPlan(apps: [
            makeAppPlan(appStoreID: 3),
            makeAppPlan(appStoreID: 1),
            makeAppPlan(appStoreID: 2),
        ])
        let refresher = ControlledHeadlessAppRefresher()
        let events = HeadlessRefreshEventRecorder()
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { _ in plan },
            refreshApp: { appPlan in try await refresher.refresh(appPlan) },
            now: { instant },
            recordEvent: { event in await events.record(event) }
        ))

        let task = Task { await service.run(request) }
        defer { task.cancel() }

        try await refresher.waitForStartCount(1)
        var snapshot = await service.snapshot()
        #expect(snapshot.activeRun?.phase == .refreshing)
        #expect(snapshot.activeRun?.plannedAppCount == 3)
        #expect(snapshot.activeRun?.completedAppCount == 0)
        #expect(snapshot.activeRun?.currentAppStoreID == 1)
        #expect(await refresher.startedAppStoreIDs() == [1])

        await refresher.fail(appStoreID: 1, error: ControlledHeadlessRefreshError.expected)
        try await refresher.waitForStartCount(2)
        snapshot = await service.snapshot()
        #expect(snapshot.activeRun?.completedAppCount == 1)
        #expect(snapshot.activeRun?.currentAppStoreID == 2)
        #expect(await refresher.startedAppStoreIDs() == [1, 2])

        await refresher.succeed(
            appStoreID: 2,
            result: HeadlessRefreshAppExecutionResult(
                disposition: .partialFailure,
                ratingsReviewsAttempted: true,
                ratingsReviewsFullySucceeded: false,
                issue: HeadlessRefreshIssue(kind: .appRefreshFailed)
            )
        )
        try await refresher.waitForStartCount(3)
        snapshot = await service.snapshot()
        #expect(snapshot.activeRun?.completedAppCount == 2)
        #expect(snapshot.activeRun?.currentAppStoreID == 3)
        #expect(await refresher.startedAppStoreIDs() == [1, 2, 3])

        await refresher.succeed(
            appStoreID: 3,
            result: .succeeded(ratingsReviewsAttempted: true)
        )
        let summary = await task.value

        #expect(summary.disposition == .partialFailure)
        #expect(summary.plannedAppCount == 3)
        #expect(summary.completedAppCount == 3)
        #expect(summary.successfulAppCount == 1)
        #expect(summary.partialFailureAppCount == 1)
        #expect(summary.failedAppCount == 1)
        #expect(summary.ratingsReviewsAttempted)
        #expect(!summary.ratingsReviewsFullySucceeded)
        #expect(summary.issue?.kind == .appRefreshFailed)
        #expect((await service.snapshot()).activeRun == nil)
        #expect((await service.snapshot()).recentRuns == [summary])
        #expect(await events.values() == [
            .runStarted(runID: runID, scheduledFor: instant, startedAt: instant),
            .planLoaded(runID: runID, plannedAppCount: 3),
            .appStarted(runID: runID, appStoreID: 1, position: 1, total: 3),
            .appFinished(runID: runID, appStoreID: 1, position: 1, total: 3, disposition: .failure),
            .appStarted(runID: runID, appStoreID: 2, position: 2, total: 3),
            .appFinished(runID: runID, appStoreID: 2, position: 2, total: 3, disposition: .partialFailure),
            .appStarted(runID: runID, appStoreID: 3, position: 3, total: 3),
            .appFinished(runID: runID, appStoreID: 3, position: 3, total: 3, disposition: .success),
            .runFinished(summary),
        ])
    }

    @Test
    func planningFailurePublishesOnlyTheRedactedIssue() async throws {
        let secret = "private-plan-payload-sentinel"
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let instant = Date(timeIntervalSince1970: 3_000)
        let request = HeadlessRefreshRunRequest(
            id: runID,
            scheduledFor: instant,
            refreshRatingsAndReviews: false
        )
        let events = HeadlessRefreshEventRecorder()
        let appCalls = HeadlessRefreshAppCallRecorder()
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { _ in throw SecretHeadlessPlanningError(payload: secret) },
            refreshApp: { plan in
                await appCalls.record(plan.appStoreID)
                return .succeeded()
            },
            now: { instant },
            recordEvent: { event in await events.record(event) }
        ))

        let summary = await service.run(request)
        let issue = try #require(summary.issue)
        let renderedIssue = [issue.title, issue.message].joined(separator: " ")

        #expect(summary.disposition == .failure)
        #expect(summary.plannedAppCount == 0)
        #expect(summary.completedAppCount == 0)
        #expect(issue.kind == .planUnavailable)
        #expect(!renderedIssue.contains(secret))
        #expect(!String(reflecting: summary).contains(secret))
        #expect(await appCalls.values().isEmpty)
        #expect(await events.values() == [
            .runStarted(runID: runID, scheduledFor: instant, startedAt: instant),
            .runFinished(summary),
        ])
    }

    @Test
    func duplicateInvocationSkipsWhileTheOriginalPlanIsLoading() async throws {
        let firstRunID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let secondRunID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let instant = Date(timeIntervalSince1970: 4_000)
        let firstRequest = HeadlessRefreshRunRequest(
            id: firstRunID,
            scheduledFor: instant,
            refreshRatingsAndReviews: false
        )
        let secondRequest = HeadlessRefreshRunRequest(
            id: secondRunID,
            scheduledFor: instant,
            refreshRatingsAndReviews: false
        )
        let planLoader = ControlledHeadlessPlanLoader()
        let events = HeadlessRefreshEventRecorder()
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { request in try await planLoader.load(request) },
            refreshApp: { _ in .succeeded() },
            now: { instant },
            recordEvent: { event in await events.record(event) }
        ))

        let firstTask = Task { await service.run(firstRequest) }
        defer { firstTask.cancel() }
        try await planLoader.waitForCallCount(1)

        let activeSnapshot = await service.snapshot()
        #expect(activeSnapshot.activeRun?.runID == firstRunID)
        #expect(activeSnapshot.activeRun?.phase == .planning)

        let skipped = await service.run(secondRequest)
        #expect(skipped.disposition == .skippedAlreadyRunning)
        #expect(skipped.runID == secondRunID)
        #expect(skipped.activeRunID == firstRunID)
        #expect(skipped.startedAt == instant)
        #expect(skipped.finishedAt == instant)
        #expect(await planLoader.callCount() == 1)

        await planLoader.succeed(HeadlessRefreshPlan(apps: []))
        let first = await firstTask.value
        let finalSnapshot = await service.snapshot()

        #expect(first.disposition == .noWork)
        #expect(finalSnapshot.activeRun == nil)
        #expect(finalSnapshot.recentRuns == [first])
        #expect(await events.values() == [
            .runStarted(runID: firstRunID, scheduledFor: instant, startedAt: instant),
            .runSkipped(requestRunID: secondRunID, activeRunID: firstRunID, at: instant),
            .planLoaded(runID: firstRunID, plannedAppCount: 0),
            .runFinished(first),
        ])
    }

    @Test
    func completedRequestReplayReusesTheBoundedPriorResultWithoutProviderWork() async {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let instant = Date(timeIntervalSince1970: 4_500)
        let request = HeadlessRefreshRunRequest(
            id: runID,
            scheduledFor: instant,
            refreshRatingsAndReviews: false
        )
        let appCalls = HeadlessRefreshAppCallRecorder()
        let events = HeadlessRefreshEventRecorder()
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { _ in HeadlessRefreshPlan(apps: [makeAppPlan(appStoreID: 1)]) },
            refreshApp: { plan in
                await appCalls.record(plan.appStoreID)
                return .succeeded()
            },
            now: { instant },
            recordEvent: { event in await events.record(event) }
        ))

        let first = await service.run(request)
        let replay = await service.run(request)

        #expect(replay == first)
        #expect(await appCalls.values() == [1])
        #expect((await service.snapshot()).recentRuns == [first])
        #expect(await events.values() == [
            .runStarted(runID: runID, scheduledFor: instant, startedAt: instant),
            .planLoaded(runID: runID, plannedAppCount: 1),
            .appStarted(runID: runID, appStoreID: 1, position: 1, total: 1),
            .appFinished(runID: runID, appStoreID: 1, position: 1, total: 1, disposition: .success),
            .runFinished(first),
            .completedRunReused(
                requestRunID: runID,
                priorDisposition: first.disposition,
                at: instant
            ),
        ])
    }

    @Test
    func completedRequestReplaySurvivesVisibleHistoryEviction() async {
        let instant = Date(timeIntervalSince1970: 4_510)
        let firstRequest = HeadlessRefreshRunRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            scheduledFor: instant,
            refreshRatingsAndReviews: false
        )
        let secondRequest = HeadlessRefreshRunRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
            scheduledFor: instant.addingTimeInterval(86_400),
            refreshRatingsAndReviews: false
        )
        let appCalls = HeadlessRefreshAppCallRecorder()
        let service = HeadlessRefreshService(
            recentRunLimit: 1,
            dependencies: HeadlessRefreshDependencies(
                loadPlan: { request in
                    HeadlessRefreshPlan(apps: [makeAppPlan(
                        appStoreID: request.id == firstRequest.id ? 1 : 2
                    )])
                },
                refreshApp: { plan in
                    await appCalls.record(plan.appStoreID)
                    return .succeeded()
                },
                now: { instant }
            )
        )

        let first = await service.run(firstRequest)
        let second = await service.run(secondRequest)
        let replay = await service.run(firstRequest)

        #expect(replay == first)
        #expect(await appCalls.values() == [1, 2])
        #expect((await service.snapshot()).recentRuns == [second])
    }

    @Test
    func completedRequestReplayWinsWhileAnUnrelatedRunIsActive() async throws {
        let instant = Date(timeIntervalSince1970: 4_520)
        let completedRequest = HeadlessRefreshRunRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000015")!,
            scheduledFor: instant,
            refreshRatingsAndReviews: false
        )
        let activeRequest = HeadlessRefreshRunRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000016")!,
            scheduledFor: instant.addingTimeInterval(86_400),
            refreshRatingsAndReviews: false
        )
        let activePlanLoader = ControlledHeadlessPlanLoader()
        let events = HeadlessRefreshEventRecorder()
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { request in
                if request.id == completedRequest.id {
                    return HeadlessRefreshPlan(apps: [])
                }
                return try await activePlanLoader.load(request)
            },
            refreshApp: { _ in .succeeded() },
            now: { instant },
            recordEvent: { event in await events.record(event) }
        ))

        let completed = await service.run(completedRequest)
        let activeTask = Task { await service.run(activeRequest) }
        defer { activeTask.cancel() }
        try await activePlanLoader.waitForCallCount(1)

        let replay = await service.run(completedRequest)
        #expect(replay == completed)

        await activePlanLoader.succeed(HeadlessRefreshPlan(apps: []))
        let active = await activeTask.value
        #expect(active.disposition == .noWork)
        #expect(await events.values() == [
            .runStarted(
                runID: completedRequest.id,
                scheduledFor: completedRequest.scheduledFor,
                startedAt: instant
            ),
            .planLoaded(runID: completedRequest.id, plannedAppCount: 0),
            .runFinished(completed),
            .runStarted(
                runID: activeRequest.id,
                scheduledFor: activeRequest.scheduledFor,
                startedAt: instant
            ),
            .completedRunReused(
                requestRunID: completedRequest.id,
                priorDisposition: completed.disposition,
                at: instant
            ),
            .planLoaded(runID: activeRequest.id, plannedAppCount: 0),
            .runFinished(active),
        ])
    }

    @Test
    func conflictingCompletedRequestIdentityIsRejectedWithoutProviderWork() async {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000017")!
        let instant = Date(timeIntervalSince1970: 4_530)
        let firstRequest = HeadlessRefreshRunRequest(
            id: runID,
            scheduledFor: instant,
            refreshRatingsAndReviews: false
        )
        let conflictingRequest = HeadlessRefreshRunRequest(
            id: runID,
            scheduledFor: instant,
            refreshRatingsAndReviews: true
        )
        let events = HeadlessRefreshEventRecorder()
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { _ in HeadlessRefreshPlan(apps: []) },
            refreshApp: { _ in .succeeded() },
            now: { instant },
            recordEvent: { event in await events.record(event) }
        ))

        let first = await service.run(firstRequest)
        let rejected = await service.run(conflictingRequest)

        #expect(rejected.disposition == .rejectedRequestConflict)
        #expect(rejected.issue?.kind == .requestIdentityConflict)
        #expect((await service.snapshot()).recentRuns == [first])
        #expect(await events.values() == [
            .runStarted(runID: runID, scheduledFor: instant, startedAt: instant),
            .planLoaded(runID: runID, plannedAppCount: 0),
            .runFinished(first),
            .runRejected(requestRunID: runID, at: instant),
        ])
    }

    @Test
    func ratingsFactsStayDisabledWhenAnAdapterReturnsAnImpossibleAttempt() async {
        let instant = Date(timeIntervalSince1970: 4_600)
        let request = HeadlessRefreshRunRequest(
            scheduledFor: instant,
            refreshRatingsAndReviews: false
        )
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { _ in HeadlessRefreshPlan(apps: [makeAppPlan(appStoreID: 1)]) },
            refreshApp: { _ in .succeeded(ratingsReviewsAttempted: true) },
            now: { instant }
        ))

        let summary = await service.run(request)

        #expect(summary.disposition == .success)
        #expect(!summary.ratingsReviewsAttempted)
        #expect(!summary.ratingsReviewsFullySucceeded)
    }

    @Test
    func cancellationWhilePublishingThePlanDoesNotBecomeNoWork() async throws {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let instant = Date(timeIntervalSince1970: 4_700)
        let request = HeadlessRefreshRunRequest(
            id: runID,
            scheduledFor: instant,
            refreshRatingsAndReviews: false
        )
        let events = PausingHeadlessEventRecorder(pausePoint: .planLoaded)
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { _ in HeadlessRefreshPlan(apps: []) },
            refreshApp: { _ in .succeeded() },
            now: { instant },
            recordEvent: { event in await events.record(event) }
        ))

        let task = Task { await service.run(request) }
        defer { task.cancel() }
        try await events.waitUntilPaused()
        task.cancel()
        await events.resume()
        let summary = await task.value

        #expect(summary.disposition == .cancelled)
        #expect(summary.plannedAppCount == 0)
        #expect(await events.values() == [
            .runStarted(runID: runID, scheduledFor: instant, startedAt: instant),
            .planLoaded(runID: runID, plannedAppCount: 0),
            .runFinished(summary),
        ])
    }

    @Test
    func cancellationWhilePublishingAnAppStartNeverBeginsProviderWork() async throws {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let instant = Date(timeIntervalSince1970: 4_800)
        let request = HeadlessRefreshRunRequest(
            id: runID,
            scheduledFor: instant,
            refreshRatingsAndReviews: false
        )
        let appCalls = HeadlessRefreshAppCallRecorder()
        let events = PausingHeadlessEventRecorder(pausePoint: .appStarted)
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { _ in HeadlessRefreshPlan(apps: [makeAppPlan(appStoreID: 1)]) },
            refreshApp: { plan in
                await appCalls.record(plan.appStoreID)
                return .succeeded()
            },
            now: { instant },
            recordEvent: { event in await events.record(event) }
        ))

        let task = Task { await service.run(request) }
        defer { task.cancel() }
        try await events.waitUntilPaused()
        task.cancel()
        await events.resume()
        let summary = await task.value

        #expect(summary.disposition == .cancelled)
        #expect(summary.plannedAppCount == 1)
        #expect(summary.completedAppCount == 0)
        #expect(await appCalls.values().isEmpty)
        #expect(await events.values() == [
            .runStarted(runID: runID, scheduledFor: instant, startedAt: instant),
            .planLoaded(runID: runID, plannedAppCount: 1),
            .appStarted(runID: runID, appStoreID: 1, position: 1, total: 1),
            .appFinished(runID: runID, appStoreID: 1, position: 1, total: 1, disposition: .cancelled),
            .runFinished(summary),
        ])
    }

    @Test
    func urlCancellationFromPlanLoadingIsReportedAsCancellation() async {
        let instant = Date(timeIntervalSince1970: 4_900)
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { _ in throw URLError(.cancelled) },
            refreshApp: { _ in .succeeded() },
            now: { instant }
        ))

        let summary = await service.run(HeadlessRefreshRunRequest(
            scheduledFor: instant,
            refreshRatingsAndReviews: false
        ))

        #expect(summary.disposition == .cancelled)
        #expect(summary.issue == nil)
    }

    @Test
    func terminalEventObservesTheRunAsInactive() async {
        let instant = Date(timeIntervalSince1970: 4_950)
        let probe = HeadlessRefreshTerminalSnapshotProbe()
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { _ in HeadlessRefreshPlan(apps: []) },
            refreshApp: { _ in .succeeded() },
            now: { instant },
            recordEvent: { event in await probe.record(event) }
        ))
        await probe.attach(service)

        _ = await service.run(HeadlessRefreshRunRequest(
            scheduledFor: instant,
            refreshRatingsAndReviews: false
        ))

        #expect(await probe.activeRunObservedAtFinish() == nil)
    }

    @Test
    func cancellationOfTheActiveAppStopsEveryLaterApp() async throws {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let instant = Date(timeIntervalSince1970: 5_000)
        let request = HeadlessRefreshRunRequest(
            id: runID,
            scheduledFor: instant,
            refreshRatingsAndReviews: true
        )
        let plan = HeadlessRefreshPlan(apps: [
            makeAppPlan(appStoreID: 1),
            makeAppPlan(appStoreID: 2),
            makeAppPlan(appStoreID: 3),
        ])
        let refresher = ControlledHeadlessAppRefresher()
        let events = HeadlessRefreshEventRecorder()
        let service = HeadlessRefreshService(dependencies: HeadlessRefreshDependencies(
            loadPlan: { _ in plan },
            refreshApp: { appPlan in try await refresher.refresh(appPlan) },
            now: { instant },
            recordEvent: { event in await events.record(event) }
        ))

        let task = Task { await service.run(request) }
        defer { task.cancel() }
        try await refresher.waitForStartCount(1)
        #expect(await refresher.startedAppStoreIDs() == [1])
        #expect((await service.snapshot()).activeRun?.currentAppStoreID == 1)

        task.cancel()
        await refresher.succeed(appStoreID: 1, result: .succeeded(ratingsReviewsAttempted: true))
        let summary = await task.value

        #expect(summary.disposition == .cancelled)
        #expect(summary.plannedAppCount == 3)
        #expect(summary.completedAppCount == 0)
        #expect(summary.successfulAppCount == 0)
        #expect(summary.partialFailureAppCount == 0)
        #expect(summary.failedAppCount == 0)
        #expect(!summary.ratingsReviewsAttempted)
        #expect(await refresher.startedAppStoreIDs() == [1])
        #expect((await service.snapshot()).activeRun == nil)
        #expect(await events.values() == [
            .runStarted(runID: runID, scheduledFor: instant, startedAt: instant),
            .planLoaded(runID: runID, plannedAppCount: 3),
            .appStarted(runID: runID, appStoreID: 1, position: 1, total: 3),
            .appFinished(runID: runID, appStoreID: 1, position: 1, total: 3, disposition: .cancelled),
            .runFinished(summary),
        ])
    }

    @Test
    func snapshotsRetainNewestRunsInExactBoundedEventOrder() async {
        let instant = Date(timeIntervalSince1970: 6_000)
        let requests = [
            HeadlessRefreshRunRequest(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
                scheduledFor: instant,
                refreshRatingsAndReviews: false
            ),
            HeadlessRefreshRunRequest(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!,
                scheduledFor: instant.addingTimeInterval(86_400),
                refreshRatingsAndReviews: false
            ),
            HeadlessRefreshRunRequest(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
                scheduledFor: instant.addingTimeInterval(2 * 86_400),
                refreshRatingsAndReviews: false
            ),
        ]
        let events = HeadlessRefreshEventRecorder()
        let service = HeadlessRefreshService(
            recentRunLimit: 2,
            dependencies: HeadlessRefreshDependencies(
                loadPlan: { _ in HeadlessRefreshPlan(apps: []) },
                refreshApp: { _ in .succeeded() },
                now: { instant },
                recordEvent: { event in await events.record(event) }
            )
        )

        var summaries: [HeadlessRefreshRunSummary] = []
        for request in requests {
            summaries.append(await service.run(request))
        }
        let snapshot = await service.snapshot()

        #expect(snapshot.activeRun == nil)
        #expect(snapshot.recentRuns == [summaries[2], summaries[1]])
        #expect(!snapshot.recentRuns.contains(summaries[0]))
        #expect(await events.values() == [
            .runStarted(runID: requests[0].id, scheduledFor: requests[0].scheduledFor, startedAt: instant),
            .planLoaded(runID: requests[0].id, plannedAppCount: 0),
            .runFinished(summaries[0]),
            .runStarted(runID: requests[1].id, scheduledFor: requests[1].scheduledFor, startedAt: instant),
            .planLoaded(runID: requests[1].id, plannedAppCount: 0),
            .runFinished(summaries[1]),
            .runStarted(runID: requests[2].id, scheduledFor: requests[2].scheduledFor, startedAt: instant),
            .planLoaded(runID: requests[2].id, plannedAppCount: 0),
            .runFinished(summaries[2]),
        ])
    }

    @Test
    func appAdapterReducesEveryMetadataAndDetailStatusCombination() {
        let plan = makeAppPlan(
            appStoreID: 901,
            refreshRatingsAndReviews: false
        )
        let expectedError = OpenASOError.providerUnavailable("expected")
        let detailCases: [(HeadlessRefreshAppStageDisposition, AppDetailRefreshResult)] = [
            (
                .success,
                AppDetailRefreshResult(
                    keywordOutcomes: [],
                    ratingOutcomes: [],
                    reviewOutcomes: [],
                    firstError: nil
                )
            ),
            (
                .partialFailure,
                AppDetailRefreshResult(
                    keywordOutcomes: [
                        KeywordBackgroundRefreshOutcome(
                            trackIdentityKey: "successful",
                            error: nil
                        ),
                        KeywordBackgroundRefreshOutcome(
                            trackIdentityKey: "failed",
                            error: expectedError
                        ),
                    ],
                    ratingOutcomes: [],
                    reviewOutcomes: [],
                    firstError: expectedError
                )
            ),
            (
                .failure,
                AppDetailRefreshResult(
                    keywordOutcomes: [
                        KeywordBackgroundRefreshOutcome(
                            trackIdentityKey: "failed",
                            error: expectedError
                        ),
                    ],
                    ratingOutcomes: [],
                    reviewOutcomes: [],
                    firstError: expectedError
                )
            ),
        ]
        let metadataCases: [(AppMetadataRefreshStatus, HeadlessRefreshAppStageDisposition)] = [
            (.succeeded, .success),
            (.partial, .partialFailure),
            (.failed, .failure),
        ]

        for (metadataStatus, metadataDisposition) in metadataCases {
            for (detailDisposition, detailResult) in detailCases {
                let result = HeadlessRefreshAppResultAdapter.map(
                    metadataStatus: metadataStatus,
                    detailResult: detailResult,
                    request: plan.appDetailRequest
                )
                let expectedDisposition: HeadlessRefreshAppDisposition
                switch (metadataDisposition, detailDisposition) {
                case (.success, .success):
                    expectedDisposition = .success
                case (.failure, .failure):
                    expectedDisposition = .failure
                default:
                    expectedDisposition = .partialFailure
                }

                #expect(result.disposition == expectedDisposition)
                #expect((result.issue == nil) == (expectedDisposition == .success))
            }
        }
    }

    @Test
    func appAdapterReportsRatingsAndReviewsOnlyFromNonemptySuccessfulOutcomes() {
        let plan = makeAppPlan(appStoreID: 902)
        let providerError = OpenASOError.providerUnavailable("expected")
        let empty = HeadlessRefreshAppResultAdapter.map(
            metadataStatus: .succeeded,
            detailResult: AppDetailRefreshResult(
                keywordOutcomes: [],
                ratingOutcomes: [],
                reviewOutcomes: [],
                firstError: nil
            ),
            request: plan.appDetailRequest
        )
        let fullySucceeded = HeadlessRefreshAppResultAdapter.map(
            metadataStatus: .succeeded,
            detailResult: AppDetailRefreshResult(
                keywordOutcomes: [
                    KeywordBackgroundRefreshOutcome(
                        trackIdentityKey: "failed-keyword",
                        error: providerError
                    ),
                ],
                ratingOutcomes: [
                    AppStorefrontRatingRefreshOutcome(
                        storefront: "us",
                        result: nil,
                        error: nil
                    ),
                ],
                reviewOutcomes: [
                    AppStorefrontReviewRefreshOutcome(
                        storefront: "us",
                        fetchedReviews: 0,
                        storedReviews: 0,
                        error: nil
                    ),
                ],
                firstError: providerError
            ),
            request: plan.appDetailRequest
        )
        let partiallySucceeded = HeadlessRefreshAppResultAdapter.map(
            metadataStatus: .succeeded,
            detailResult: AppDetailRefreshResult(
                keywordOutcomes: [],
                ratingOutcomes: [
                    AppStorefrontRatingRefreshOutcome(
                        storefront: "us",
                        result: nil,
                        error: providerError
                    ),
                ],
                reviewOutcomes: [],
                firstError: providerError
            ),
            request: plan.appDetailRequest
        )

        #expect(!empty.ratingsReviewsAttempted)
        #expect(!empty.ratingsReviewsFullySucceeded)
        #expect(empty.disposition == .partialFailure)
        #expect(fullySucceeded.ratingsReviewsAttempted)
        #expect(fullySucceeded.ratingsReviewsFullySucceeded)
        #expect(fullySucceeded.disposition == .partialFailure)
        #expect(partiallySucceeded.ratingsReviewsAttempted)
        #expect(!partiallySucceeded.ratingsReviewsFullySucceeded)
    }

    @Test
    func appAdapterRunsStagesInOrderAndPreservesPartialWorkAfterOrdinaryThrows() async throws {
        let plan = makeAppPlan(
            appStoreID: 903,
            refreshRatingsAndReviews: false
        )
        let metadataFailureCalls = HeadlessAppAdapterCallRecorder()
        let metadataFailureAdapter = HeadlessRefreshAppAdapter(
            refreshMetadata: { _ in
                await metadataFailureCalls.record("metadata")
                throw HeadlessAppAdapterTestError.expected
            },
            refreshDetail: { _ in
                await metadataFailureCalls.record("detail")
                return AppDetailRefreshResult(
                    keywordOutcomes: [],
                    ratingOutcomes: [],
                    reviewOutcomes: [],
                    firstError: nil
                )
            }
        )

        let metadataFailureResult = try await metadataFailureAdapter.refresh(plan)

        #expect(await metadataFailureCalls.values() == ["metadata", "detail"])
        #expect(metadataFailureResult.disposition == .partialFailure)

        let detailFailureCalls = HeadlessAppAdapterCallRecorder()
        let detailFailureAdapter = HeadlessRefreshAppAdapter(
            refreshMetadata: { request in
                await detailFailureCalls.record("metadata")
                return makeMetadataResult(
                    appStoreID: request.appStoreID,
                    status: .succeeded
                )
            },
            refreshDetail: { _ in
                await detailFailureCalls.record("detail")
                throw HeadlessAppAdapterTestError.expected
            }
        )

        let detailFailureResult = try await detailFailureAdapter.refresh(plan)

        #expect(await detailFailureCalls.values() == ["metadata", "detail"])
        #expect(detailFailureResult.disposition == .partialFailure)

        let totalFailureAdapter = HeadlessRefreshAppAdapter(
            refreshMetadata: { _ in throw HeadlessAppAdapterTestError.expected },
            refreshDetail: { _ in throw HeadlessAppAdapterTestError.expected }
        )
        let totalFailureResult = try await totalFailureAdapter.refresh(plan)
        #expect(totalFailureResult.disposition == .failure)
    }

    @Test
    func appAdapterPropagatesTaskCancellationButTreatsProviderURLCancellationAsFailure() async throws {
        let plan = makeAppPlan(
            appStoreID: 904,
            refreshRatingsAndReviews: false
        )
        let cancellationCalls = HeadlessAppAdapterCallRecorder()
        let cancellationAdapter = HeadlessRefreshAppAdapter(
            refreshMetadata: { _ in
                await cancellationCalls.record("metadata")
                throw CancellationError()
            },
            refreshDetail: { _ in
                await cancellationCalls.record("detail")
                return AppDetailRefreshResult(
                    keywordOutcomes: [],
                    ratingOutcomes: [],
                    reviewOutcomes: [],
                    firstError: nil
                )
            }
        )

        await #expect(throws: CancellationError.self) {
            try await cancellationAdapter.refresh(plan)
        }
        #expect(await cancellationCalls.values() == ["metadata"])

        let providerCancellationCalls = HeadlessAppAdapterCallRecorder()
        let providerCancellationAdapter = HeadlessRefreshAppAdapter(
            refreshMetadata: { _ in
                await providerCancellationCalls.record("metadata")
                throw URLError(.cancelled)
            },
            refreshDetail: { _ in
                await providerCancellationCalls.record("detail")
                return AppDetailRefreshResult(
                    keywordOutcomes: [],
                    ratingOutcomes: [],
                    reviewOutcomes: [],
                    firstError: nil
                )
            }
        )

        let providerCancellationResult = try await providerCancellationAdapter.refresh(plan)

        #expect(await providerCancellationCalls.values() == ["metadata", "detail"])
        #expect(providerCancellationResult.disposition == .partialFailure)
    }

    @Test
    func appAdapterDefensivelyPropagatesACancelledDetailResult() async {
        let plan = makeAppPlan(appStoreID: 905)
        let adapter = HeadlessRefreshAppAdapter(
            refreshMetadata: { request in
                makeMetadataResult(appStoreID: request.appStoreID, status: .succeeded)
            },
            refreshDetail: { _ in .cancelled }
        )

        await #expect(throws: CancellationError.self) {
            try await adapter.refresh(plan)
        }
    }
}

private func insertTrack(
    term: String,
    storefront: String,
    app: TrackedApp,
    in modelContext: ModelContext
) throws -> TrackedAppKeyword {
    let query = try KeywordQuery.fetchOrInsert(
        term: term,
        storefront: storefront,
        platform: .iphone,
        in: modelContext
    )
    let track = TrackedAppKeyword(
        term: term,
        storefront: storefront,
        platform: .iphone,
        trackedApp: app,
        query: query
    )
    app.keywordTracks.append(track)
    modelContext.insert(track)
    return track
}

private func storefrontCodes(in request: AppDetailRefreshRequest) -> [String] {
    switch request.storefrontSelection {
    case .all(let codes):
        codes
    case .storefront(let code):
        [code]
    }
}

private func makePlanConfiguration() -> DailyRefreshPlanConfiguration {
    DailyRefreshPlanConfiguration(
        fallbackStorefrontCodes: ["us"],
        refreshRatingsAndReviews: false,
        popularityContextAppStoreID: nil,
        appleAdsWebSession: nil,
        appStoreConnectCredentials: AppStoreConnectCredentials(
            issuerID: "",
            keyID: "",
            privateKey: ""
        )
    )
}

private func makeMetadataResult(
    appStoreID: Int64,
    status: AppMetadataRefreshStatus
) -> AppMetadataRefreshResult {
    let iTunesFailure = AppMetadataRefreshFailure(
        provider: .iTunesLookup,
        stage: .fetch,
        error: .providerUnavailable("expected")
    )
    let webFailure = AppMetadataRefreshFailure(
        provider: .appStoreWeb,
        stage: .fetch,
        error: .providerUnavailable("expected")
    )
    let outcome: AppMetadataRefreshStorefrontOutcome
    switch status {
    case .succeeded:
        outcome = AppMetadataRefreshStorefrontOutcome(
            storefront: "us",
            iTunesLookup: .succeeded,
            appStoreWeb: .succeeded
        )
    case .partial:
        outcome = AppMetadataRefreshStorefrontOutcome(
            storefront: "us",
            iTunesLookup: .succeeded,
            appStoreWeb: .failed(webFailure)
        )
    case .failed:
        outcome = AppMetadataRefreshStorefrontOutcome(
            storefront: "us",
            iTunesLookup: .failed(iTunesFailure),
            appStoreWeb: .failed(webFailure)
        )
    }
    return AppMetadataRefreshResult(
        appStoreID: appStoreID,
        defaultStorefront: "us",
        storefronts: [outcome],
        iconInvalidated: false
    )
}

private func makeAppPlan(
    appStoreID: Int64,
    refreshRatingsAndReviews: Bool = true
) -> HeadlessRefreshAppPlan {
    HeadlessRefreshAppPlan(
        appStoreID: appStoreID,
        metadataRequest: AppMetadataRefreshRequest(
            appStoreID: appStoreID,
            requestedStorefronts: ["us"]
        ),
        appDetailRequest: AppDetailRefreshRequest(
            app: AppDetailRefreshAppSnapshot(
                appStoreID: appStoreID,
                bundleID: "com.example.\(appStoreID)",
                name: "App \(appStoreID)",
                subtitle: nil,
                sellerName: "Example",
                defaultPlatform: .iphone
            ),
            workspace: .keywords,
            storefrontSelection: .all(codes: ["us"]),
            trackIdentityKeys: [],
            trigger: "daily_refresh",
            refreshRatings: refreshRatingsAndReviews,
            refreshReviews: refreshRatingsAndReviews,
            recordsRatingsReviewsRefresh: false,
            popularityContextAppStoreID: nil,
            appleAdsWebSession: nil,
            appStoreConnectCredentials: AppStoreConnectCredentials(
                issuerID: "",
                keyID: "",
                privateKey: ""
            )
        )
    )
}

private actor HeadlessRefreshEventRecorder {
    private var recordedEvents: [HeadlessRefreshEvent] = []

    func record(_ event: HeadlessRefreshEvent) {
        recordedEvents.append(event)
    }

    func values() -> [HeadlessRefreshEvent] {
        recordedEvents
    }
}

private actor HeadlessAppAdapterCallRecorder {
    private var calls: [String] = []

    func record(_ call: String) {
        calls.append(call)
    }

    func values() -> [String] {
        calls
    }
}

private enum HeadlessAppAdapterTestError: Error {
    case expected
}

private actor PausingHeadlessEventRecorder {
    private struct PendingPause {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct PauseWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    enum PausePoint {
        case planLoaded
        case appStarted
    }

    private let pausePoint: PausePoint
    private var recordedEvents: [HeadlessRefreshEvent] = []
    private var isPaused = false
    private var pauseWaiters: [PauseWaiter] = []
    private var pendingPause: PendingPause?

    init(pausePoint: PausePoint) {
        self.pausePoint = pausePoint
    }

    func record(_ event: HeadlessRefreshEvent) async {
        recordedEvents.append(event)
        guard !isPaused, shouldPause(on: event) else { return }
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.continuation.resume() }

        let pauseID = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (
                    continuation: CheckedContinuation<Void, any Error>
                ) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pendingPause = PendingPause(
                        id: pauseID,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task { await self.cancelPause(id: pauseID) }
            }
        } catch is CancellationError {
            return
        } catch {
            Issue.record("Unexpected event-pause error: \(error)")
        }
    }

    func waitUntilPaused() async throws {
        try Task.checkCancellation()
        guard !isPaused else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (
                continuation: CheckedContinuation<Void, any Error>
            ) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pauseWaiters.append(PauseWaiter(
                    id: waiterID,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelPauseWaiter(id: waiterID) }
        }
    }

    func resume() {
        let continuation = pendingPause?.continuation
        pendingPause = nil
        continuation?.resume()
    }

    func values() -> [HeadlessRefreshEvent] {
        recordedEvents
    }

    private func shouldPause(on event: HeadlessRefreshEvent) -> Bool {
        switch (pausePoint, event) {
        case (.planLoaded, .planLoaded), (.appStarted, .appStarted):
            true
        default:
            false
        }
    }

    private func cancelPause(id: UUID) {
        guard pendingPause?.id == id else { return }
        let continuation = pendingPause?.continuation
        pendingPause = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelPauseWaiter(id: UUID) {
        guard let index = pauseWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = pauseWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private actor HeadlessRefreshTerminalSnapshotProbe {
    private var service: HeadlessRefreshService?
    private var observedActiveRun: HeadlessRefreshActiveSnapshot?
    private var didObserveFinish = false

    func attach(_ service: HeadlessRefreshService) {
        self.service = service
    }

    func record(_ event: HeadlessRefreshEvent) async {
        guard case .runFinished = event, let service else { return }
        observedActiveRun = await service.snapshot().activeRun
        didObserveFinish = true
    }

    func activeRunObservedAtFinish() -> HeadlessRefreshActiveSnapshot? {
        precondition(didObserveFinish)
        return observedActiveRun
    }
}

private actor HeadlessRefreshAppCallRecorder {
    private var appStoreIDs: [Int64] = []

    func record(_ appStoreID: Int64) {
        appStoreIDs.append(appStoreID)
    }

    func values() -> [Int64] {
        appStoreIDs
    }
}

private actor ControlledHeadlessPlanLoader {
    private struct PendingLoad {
        let id: UUID
        let continuation: CheckedContinuation<HeadlessRefreshPlan, any Error>
    }

    private struct CallCountWaiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var requests: [HeadlessRefreshRunRequest] = []
    private var pendingLoad: PendingLoad?
    private var callCountWaiters: [CallCountWaiter] = []

    func load(_ request: HeadlessRefreshRunRequest) async throws -> HeadlessRefreshPlan {
        requests.append(request)
        resumeSatisfiedWaiters()
        let loadID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (
                continuation: CheckedContinuation<HeadlessRefreshPlan, any Error>
            ) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                precondition(pendingLoad == nil)
                pendingLoad = PendingLoad(id: loadID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelLoad(id: loadID) }
        }
    }

    func waitForCallCount(_ count: Int) async throws {
        try Task.checkCancellation()
        guard requests.count < count else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (
                continuation: CheckedContinuation<Void, any Error>
            ) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                callCountWaiters.append(CallCountWaiter(
                    id: waiterID,
                    count: count,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelCallCountWaiter(id: waiterID) }
        }
    }

    func callCount() -> Int {
        requests.count
    }

    func succeed(_ plan: HeadlessRefreshPlan) {
        let continuation = pendingLoad?.continuation
        pendingLoad = nil
        continuation?.resume(returning: plan)
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [CallCountWaiter] = []
        for waiter in callCountWaiters {
            if requests.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        callCountWaiters = remaining
    }

    private func cancelLoad(id: UUID) {
        guard pendingLoad?.id == id else { return }
        let continuation = pendingLoad?.continuation
        pendingLoad = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelCallCountWaiter(id: UUID) {
        guard let index = callCountWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = callCountWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private actor ControlledHeadlessAppRefresher {
    private struct PendingRefresh {
        let id: UUID
        let continuation: CheckedContinuation<HeadlessRefreshAppExecutionResult, any Error>
    }

    private struct StartWaiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var started: [Int64] = []
    private var pending: [Int64: PendingRefresh] = [:]
    private var startWaiters: [StartWaiter] = []

    func refresh(
        _ plan: HeadlessRefreshAppPlan
    ) async throws -> HeadlessRefreshAppExecutionResult {
        let refreshID = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (
                continuation: CheckedContinuation<HeadlessRefreshAppExecutionResult, any Error>
            ) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                started.append(plan.appStoreID)
                pending[plan.appStoreID] = PendingRefresh(
                    id: refreshID,
                    continuation: continuation
                )
                resumeSatisfiedWaiters()
            }
        } onCancel: {
            Task {
                await self.cancelRefresh(
                    appStoreID: plan.appStoreID,
                    id: refreshID
                )
            }
        }
        try Task.checkCancellation()
        return result
    }

    func waitForStartCount(_ count: Int) async throws {
        try Task.checkCancellation()
        guard started.count < count else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (
                continuation: CheckedContinuation<Void, any Error>
            ) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                startWaiters.append(StartWaiter(
                    id: waiterID,
                    count: count,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelStartWaiter(id: waiterID) }
        }
    }

    func startedAppStoreIDs() -> [Int64] {
        started
    }

    func succeed(
        appStoreID: Int64,
        result: HeadlessRefreshAppExecutionResult
    ) {
        let continuation = pending.removeValue(forKey: appStoreID)?.continuation
        continuation?.resume(returning: result)
    }

    func fail(appStoreID: Int64, error: any Error) {
        let continuation = pending.removeValue(forKey: appStoreID)?.continuation
        continuation?.resume(throwing: error)
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [StartWaiter] = []
        for waiter in startWaiters {
            if started.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        startWaiters = remaining
    }

    private func cancelRefresh(appStoreID: Int64, id: UUID) {
        guard pending[appStoreID]?.id == id else { return }
        let continuation = pending.removeValue(forKey: appStoreID)?.continuation
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelStartWaiter(id: UUID) {
        guard let index = startWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = startWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private enum ControlledHeadlessRefreshError: Error, Sendable {
    case expected
}

private struct SecretHeadlessPlanningError: LocalizedError, Sendable {
    let payload: String

    var errorDescription: String? {
        "Planning failed with \(payload)"
    }
}
