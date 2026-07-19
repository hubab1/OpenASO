import Foundation
import Testing
@testable import OpenASO

@MainActor
struct KeywordResearchProjectCopyModelTests {
    @Test
    func targetPagingRetainsLoadedAppsAcrossContinuationFailureAndExactRetry() async {
        let project = copyProject()
        let first = copyTarget(appStoreID: 101, token: "first")
        let duplicateFirst = copyTarget(
            appStoreID: 101,
            token: "first",
            name: "Updated First"
        )
        let second = copyTarget(appStoreID: 102, token: "second")
        let pages = ControlledOperation<KeywordResearchPage<KeywordResearchCopyTargetSnapshot>>()
        let calls = Recorder<PageCall>()
        let model = KeywordResearchProjectCopyModel(
            project: project,
            pageSize: 2,
            dependencies: copyDependencies(
                project: project,
                loadTargetsPage: { offset, limit in
                    await calls.record(PageCall(offset: offset, limit: limit))
                    return try await pages.call()
                }
            )
        )

        let reload = Task { @MainActor in await model.reloadTargets() }
        await pages.waitForCallCount(1)
        await pages.succeed(
            at: 0,
            with: KeywordResearchPage(items: [first, first], nextOffset: 2)
        )
        await reload.value
        #expect(model.targets == [first])
        #expect(model.nextTargetOffset == 2)

        let failedContinuation = Task { @MainActor in await model.loadNextTargetsPage() }
        await pages.waitForCallCount(2)
        await pages.fail(at: 0, with: OpenASOError.networkUnavailable)
        await failedContinuation.value
        #expect(model.targets == [first])
        #expect(model.nextTargetOffset == 2)
        #expect(model.failedTargetLoadOperation == .nextPage)

        let retry = Task { @MainActor in await model.retryFailedTargetLoad() }
        await pages.waitForCallCount(3)
        await pages.succeed(
            at: 0,
            with: KeywordResearchPage(
                items: [duplicateFirst, second],
                nextOffset: nil
            )
        )
        await retry.value

        #expect(model.targets == [duplicateFirst, second])
        #expect(model.nextTargetOffset == nil)
        #expect(await calls.values == [
            PageCall(offset: 0, limit: 2),
            PageCall(offset: 2, limit: 2),
            PageCall(offset: 2, limit: 2),
        ])
    }

    @Test
    func targetSwitchSuppressesLatePreviewAndRejectsReincarnatedTarget() async {
        let project = copyProject()
        let first = copyTarget(appStoreID: 201, token: "first")
        let second = copyTarget(appStoreID: 202, token: "second")
        let reincarnatedSecond = copyTarget(
            appStoreID: 202,
            token: "replacement",
            name: "Replacement"
        )
        let firstPreview = copyPreview(project: project, target: first, additions: 1)
        let secondPreview = copyPreview(project: project, target: second, additions: 2)
        let previewOperation = ControlledOperation<KeywordResearchProjectCopyPreview>()
        let model = KeywordResearchProjectCopyModel(
            project: project,
            dependencies: copyDependencies(
                project: project,
                loadTargetsPage: { _, _ in
                    KeywordResearchPage(items: [first, second], nextOffset: nil)
                },
                preview: { _, _ in try await previewOperation.call() }
            )
        )
        await model.reloadTargets()

        model.selectTarget(first.generation)
        let firstReview = Task { @MainActor in await model.reviewSelectedTarget() }
        await previewOperation.waitForCallCount(1)

        model.selectTarget(second.generation)
        let secondReview = Task { @MainActor in await model.reviewSelectedTarget() }
        await previewOperation.waitForCallCount(2)
        await previewOperation.succeed(at: 1, with: secondPreview)
        await secondReview.value
        #expect(model.workflowState == .ready(secondPreview))

        await previewOperation.succeed(at: 0, with: firstPreview)
        await firstReview.value
        #expect(model.workflowState == .ready(secondPreview))

        model.selectTarget(nil)
        model.selectTarget(second.generation)
        let replacementReview = Task { @MainActor in await model.reviewSelectedTarget() }
        await previewOperation.waitForCallCount(3)
        await previewOperation.succeed(
            at: 0,
            with: copyPreview(
                project: project,
                target: reincarnatedSecond,
                additions: 1
            )
        )
        await replacementReview.value

        #expect(model.selectedTargetGeneration == nil)
        #expect(model.targets.last == reincarnatedSecond)
        guard case .failed(nil, let error) = model.workflowState else {
            Issue.record("Expected target replacement to invalidate selection")
            return
        }
        #expect(error.kind == .conflict)
    }

    @Test
    func bundleAdvisoriesConfirmationAndRefreshPlanKeepExactServiceCounts() {
        let project = copyProject(bundleID: "com.example.project")
        let target = copyTarget(
            appStoreID: 301,
            token: "target",
            bundleID: "com.example.target"
        )
        let preview = copyPreview(
            project: project,
            target: target,
            additions: 2,
            duplicates: 1,
            compatibility: .mismatch,
            storefronts: ["us", "gb", "us"]
        )
        let result = copyResult(
            preview: preview,
            insertedIdentityKeys: Array(preview.trackIdentityKeys.prefix(2)),
            alreadyPresentIdentityKeys: [preview.trackIdentityKeys[2]]
        )

        let match = KeywordResearchCopyBundleAdvisory(.matches)
        let mismatch = KeywordResearchCopyBundleAdvisory(.mismatch)
        let unavailable = KeywordResearchCopyBundleAdvisory(.unavailable)
        #expect(match.kind == .match)
        #expect(mismatch.kind == .warning)
        #expect(unavailable.kind == .unavailable)
        #expect(mismatch.message.contains("Copying is allowed"))

        let confirmation = KeywordResearchCopyConfirmationPresentation(preview: preview)
        #expect(confirmation.title.contains("2 new keywords"))
        #expect(confirmation.message.contains("1 existing keyword"))
        #expect(confirmation.actionTitle == "Copy Anyway")

        let plan = KeywordResearchPostCopyRefreshPlan(preview: preview, result: result)
        #expect(plan?.target == target)
        #expect(plan?.trackIdentityKeys == preview.trackIdentityKeys)
        #expect(plan?.storefronts == ["gb", "us"])

        let completeRefresh = KeywordResearchPostCopyRefreshSummary(
            requestedTrackCount: 3,
            completedTrackCount: 3,
            failedTrackCount: 0,
            issue: nil
        )
        let popularityIssue = KeywordResearchPostCopyRefreshSummary(
            requestedTrackCount: 3,
            completedTrackCount: 3,
            failedTrackCount: 0,
            issue: .presenting(OpenASOError.providerUnavailable("Unavailable"))
        )
        #expect(completeRefresh.isFullySuccessful)
        #expect(!popularityIssue.isFullySuccessful)
    }

    @Test
    func copyIsSingleFlightRestoresCanceledPreviewAndPublishesCommittedReturn() async {
        let project = copyProject()
        let target = copyTarget(appStoreID: 401, token: "target")
        let preview = copyPreview(project: project, target: target, additions: 2)
        let result = copyResult(
            preview: preview,
            insertedIdentityKeys: preview.trackIdentityKeys
        )
        let copyOperation = ControlledOperation<KeywordResearchProjectCopyResult>()
        let model = readyCopyModel(
            project: project,
            target: target,
            preview: preview,
            copy: { _ in try await copyOperation.call() }
        )
        await prepare(model: model, target: target)

        let firstCopy = Task { @MainActor in await model.confirmCopy() }
        await copyOperation.waitForCallCount(1)
        #expect(model.blocksDismissal)

        await model.confirmCopy()
        #expect(await copyOperation.callCount == 1)

        await copyOperation.fail(at: 0, with: CancellationError())
        await firstCopy.value
        #expect(model.workflowState == .ready(preview))
        #expect(!model.blocksDismissal)

        let committedCopy = Task { @MainActor in await model.confirmCopy() }
        await copyOperation.waitForCallCount(2)
        committedCopy.cancel()
        await copyOperation.succeed(at: 0, with: result)
        await committedCopy.value

        #expect(model.workflowState == .copied(preview, result))
        #expect(!model.blocksDismissal)
        #expect(await copyOperation.callCount == 2)
    }

    @Test
    func allAlreadyTrackedScopeCanReachOptionalRefreshWithoutClaimingInsertions() async {
        let project = copyProject()
        let target = copyTarget(appStoreID: 451, token: "target")
        let preview = copyPreview(
            project: project,
            target: target,
            additions: 0,
            duplicates: 2,
            storefronts: ["gb", "us"]
        )
        let result = copyResult(
            preview: preview,
            insertedIdentityKeys: [],
            alreadyPresentIdentityKeys: preview.trackIdentityKeys
        )
        let copyCalls = Recorder<KeywordResearchProjectCopyPreview>()
        let model = readyCopyModel(
            project: project,
            target: target,
            preview: preview,
            copy: { received in
                await copyCalls.record(received)
                return result
            }
        )
        await prepare(model: model, target: target)

        #expect(model.canConfirmCopy)
        await model.confirmCopy()

        #expect(model.workflowState == .copied(preview, result))
        #expect(result.insertedCount == 0)
        #expect(result.alreadyPresentCount == 2)
        #expect(model.refreshPlan?.trackIdentityKeys == preview.trackIdentityKeys)
        #expect(model.refreshPlan?.storefronts == ["gb", "us"])
        #expect(await copyCalls.values == [preview])
    }

    @Test
    func inFlightTargetReloadBlocksCopyAndCannotOverwriteCompletion() async {
        let project = copyProject()
        let target = copyTarget(appStoreID: 452, token: "target")
        let preview = copyPreview(project: project, target: target, additions: 1)
        let result = copyResult(
            preview: preview,
            insertedIdentityKeys: preview.trackIdentityKeys
        )
        let pages = ControlledOperation<KeywordResearchPage<KeywordResearchCopyTargetSnapshot>>()
        let copies = ControlledOperation<KeywordResearchProjectCopyResult>()
        let model = KeywordResearchProjectCopyModel(
            project: project,
            dependencies: copyDependencies(
                project: project,
                loadTargetsPage: { _, _ in try await pages.call() },
                preview: { _, _ in preview },
                copy: { _ in try await copies.call() }
            )
        )

        let initialReload = Task { @MainActor in await model.reloadTargets() }
        await pages.waitForCallCount(1)
        await pages.succeed(
            at: 0,
            with: KeywordResearchPage(items: [target], nextOffset: nil)
        )
        await initialReload.value
        model.selectTarget(target.generation)
        await model.reviewSelectedTarget()

        let overlappingReload = Task { @MainActor in await model.reloadTargets() }
        await pages.waitForCallCount(2)
        #expect(!model.canConfirmCopy)
        await model.confirmCopy()
        #expect(await copies.callCount == 0)

        await pages.succeed(
            at: 0,
            with: KeywordResearchPage(items: [target], nextOffset: nil)
        )
        await overlappingReload.value
        #expect(model.workflowState == .ready(preview))

        let copy = Task { @MainActor in await model.confirmCopy() }
        await copies.waitForCallCount(1)
        #expect(model.blocksDismissal)
        await model.reloadTargets()
        #expect(await pages.callCount == 2)

        await copies.succeed(at: 0, with: result)
        await copy.value
        await model.reloadTargets()

        #expect(await pages.callCount == 2)
        #expect(model.workflowState == .copied(preview, result))
    }

    @Test
    func staleCopyRequiresExplicitFreshPreviewWithoutRetryingMutation() async {
        let project = copyProject()
        let updatedProject = copyProject(
            id: project.id,
            incarnationID: project.incarnationID,
            updatedAt: project.updatedAt.addingTimeInterval(1)
        )
        let target = copyTarget(appStoreID: 501, token: "target")
        let original = copyPreview(project: project, target: target, additions: 2)
        let refreshed = copyPreview(
            project: updatedProject,
            target: target,
            additions: 1,
            duplicates: 1
        )
        let copyCalls = Recorder<KeywordResearchProjectCopyPreview>()
        let projectLoads = ControlledOperation<KeywordResearchProjectSnapshot>()
        let previews = ControlledOperation<KeywordResearchProjectCopyPreview>()
        let model = KeywordResearchProjectCopyModel(
            project: project,
            dependencies: copyDependencies(
                project: project,
                loadTargetsPage: { _, _ in
                    KeywordResearchPage(items: [target], nextOffset: nil)
                },
                loadAuthoritativeProject: { _ in try await projectLoads.call() },
                preview: { _, _ in try await previews.call() },
                copy: { preview in
                    await copyCalls.record(preview)
                    throw KeywordResearchProjectCopyError.stalePreview
                }
            )
        )
        await model.reloadTargets()
        model.selectTarget(target.generation)

        let firstReview = Task { @MainActor in await model.reviewSelectedTarget() }
        await projectLoads.waitForCallCount(1)
        await projectLoads.succeed(at: 0, with: project)
        await previews.waitForCallCount(1)
        await previews.succeed(at: 0, with: original)
        await firstReview.value

        await model.confirmCopy()
        #expect(await copyCalls.values == [original])
        guard case .stale(let stalePreview, let error) = model.workflowState else {
            Issue.record("Expected stale state")
            return
        }
        #expect(stalePreview == original)
        #expect(error.kind == .conflict)
        #expect(await previews.callCount == 1)

        let refreshReview = Task { @MainActor in await model.reviewSelectedTarget() }
        await projectLoads.waitForCallCount(2)
        await projectLoads.succeed(at: 0, with: updatedProject)
        await previews.waitForCallCount(2)
        await previews.succeed(at: 0, with: refreshed)
        await refreshReview.value

        #expect(model.project == updatedProject)
        #expect(model.workflowState == .ready(refreshed))
        #expect(await copyCalls.values == [original])
    }

    @Test
    func removedTargetFailureClearsStalePreviewAndOffersReloadRecovery() async {
        let project = copyProject()
        let target = copyTarget(appStoreID: 551, token: "target")
        let preview = copyPreview(project: project, target: target, additions: 1)
        let model = readyCopyModel(
            project: project,
            target: target,
            preview: preview,
            copy: { _ in
                throw KeywordResearchProjectCopyError.targetNotFound(target.appStoreID)
            }
        )
        await prepare(model: model, target: target)

        await model.confirmCopy()

        #expect(model.selectedTargetGeneration == nil)
        #expect(model.targets.isEmpty)
        guard case .failed(nil, let error) = model.workflowState else {
            Issue.record("Expected a target reload recovery state")
            return
        }
        #expect(error.kind == .notFound)
    }

    @Test
    func postCopyRefreshUsesExactScopeAndFailureNeverRepeatsCopy() async throws {
        let project = copyProject()
        let target = copyTarget(appStoreID: 601, token: "target")
        let preview = copyPreview(
            project: project,
            target: target,
            additions: 1,
            duplicates: 1,
            storefronts: ["gb", "us"]
        )
        let result = copyResult(
            preview: preview,
            insertedIdentityKeys: [preview.trackIdentityKeys[0]],
            alreadyPresentIdentityKeys: [preview.trackIdentityKeys[1]]
        )
        let copyCalls = Recorder<KeywordResearchProjectCopyPreview>()
        let refreshCalls = Recorder<KeywordResearchPostCopyRefreshPlan>()
        let refreshOperation = ControlledOperation<KeywordResearchPostCopyRefreshSummary>()
        let model = readyCopyModel(
            project: project,
            target: target,
            preview: preview,
            copy: { received in
                await copyCalls.record(received)
                return result
            },
            refresh: { plan in
                await refreshCalls.record(plan)
                return try await refreshOperation.call()
            }
        )
        await prepare(model: model, target: target)
        await model.confirmCopy()

        let partial = KeywordResearchPostCopyRefreshSummary(
            requestedTrackCount: 2,
            completedTrackCount: 2,
            failedTrackCount: 1,
            issue: .presenting(OpenASOError.networkUnavailable)
        )
        let firstRefresh = Task { @MainActor in await model.refreshCopiedKeywords() }
        await refreshOperation.waitForCallCount(1)
        await refreshOperation.succeed(at: 0, with: partial)
        await firstRefresh.value

        #expect(model.refreshState == .current(partial))
        let recordedRefreshCalls = await refreshCalls.values
        let firstPlan = try #require(recordedRefreshCalls.first)
        #expect(firstPlan.trackIdentityKeys == preview.trackIdentityKeys)
        #expect(firstPlan.storefronts == ["gb", "us"])
        #expect(await copyCalls.values == [preview])

        let failedRetry = Task { @MainActor in await model.refreshCopiedKeywords() }
        await refreshOperation.waitForCallCount(2)
        await refreshOperation.fail(
            at: 0,
            with: SecretTestError(message: "private provider payload")
        )
        await failedRetry.value

        guard case .failed(let previous, let error) = model.refreshState else {
            Issue.record("Expected refresh failure")
            return
        }
        #expect(previous == partial)
        #expect(error.kind == .unexpected)
        #expect(!error.accessibilityLabel.contains("private provider payload"))
        #expect(await copyCalls.values == [preview])
        #expect(model.workflowState == .copied(preview, result))
    }

    @Test
    func copyErrorPresentationsRedactIdentifiersAndPrivatePayloads() {
        let secretQueryKey = "secret-query::us::iphone"
        let secretAppStoreID: Int64 = 9_999_999_999
        let errors: [Error] = [
            KeywordResearchProjectCopyError.invalidOffset,
            KeywordResearchProjectCopyError.invalidLimit,
            KeywordResearchProjectCopyError.targetNotFound(secretAppStoreID),
            KeywordResearchProjectCopyError.staleTarget(secretAppStoreID),
            KeywordResearchProjectCopyError.stalePreview,
            KeywordResearchProjectCopyError.projectKeywordLimitExceeded(maximum: 500),
            KeywordResearchProjectCopyError.sharedQueryNotFound(secretQueryKey),
            KeywordResearchProjectCopyError.sharedQueryMismatch(secretQueryKey),
            KeywordResearchProjectCopyError.targetTrackMismatch(secretQueryKey),
            SecretTestError(message: "private localized payload"),
        ]

        for error in errors {
            let presentation = KeywordResearchErrorPresentation.presentingCopyWorkflow(error)
            #expect(!presentation.accessibilityLabel.contains(secretQueryKey))
            #expect(!presentation.accessibilityLabel.contains(String(secretAppStoreID)))
            #expect(!presentation.accessibilityLabel.contains("private localized payload"))
        }
    }
}

@MainActor
private func readyCopyModel(
    project: KeywordResearchProjectSnapshot,
    target: KeywordResearchCopyTargetSnapshot,
    preview: KeywordResearchProjectCopyPreview,
    copy: @escaping @Sendable (
        KeywordResearchProjectCopyPreview
    ) async throws -> KeywordResearchProjectCopyResult,
    refresh: @escaping @MainActor @Sendable (
        KeywordResearchPostCopyRefreshPlan
    ) async throws -> KeywordResearchPostCopyRefreshSummary = { plan in
        KeywordResearchPostCopyRefreshSummary(
            requestedTrackCount: plan.trackIdentityKeys.count,
            completedTrackCount: plan.trackIdentityKeys.count,
            failedTrackCount: 0,
            issue: nil
        )
    }
) -> KeywordResearchProjectCopyModel {
    KeywordResearchProjectCopyModel(
        project: project,
        dependencies: copyDependencies(
            project: project,
            loadTargetsPage: { _, _ in
                KeywordResearchPage(items: [target], nextOffset: nil)
            },
            preview: { _, _ in preview },
            copy: copy,
            refreshCopiedKeywords: refresh
        )
    )
}

@MainActor
private func prepare(
    model: KeywordResearchProjectCopyModel,
    target: KeywordResearchCopyTargetSnapshot
) async {
    await model.reloadTargets()
    model.selectTarget(target.generation)
    await model.reviewSelectedTarget()
}

private func copyDependencies(
    project: KeywordResearchProjectSnapshot,
    loadTargetsPage: @escaping @Sendable (
        Int,
        Int
    ) async throws -> KeywordResearchPage<KeywordResearchCopyTargetSnapshot> = { _, _ in
        KeywordResearchPage(items: [], nextOffset: nil)
    },
    loadAuthoritativeProject: (@Sendable (
        KeywordResearchProjectGeneration
    ) async throws -> KeywordResearchProjectSnapshot)? = nil,
    preview: @escaping @Sendable (
        KeywordResearchProjectRevision,
        Int64
    ) async throws -> KeywordResearchProjectCopyPreview = { _, _ in
        throw SecretTestError(message: "unexpected preview")
    },
    copy: @escaping @Sendable (
        KeywordResearchProjectCopyPreview
    ) async throws -> KeywordResearchProjectCopyResult = { _ in
        throw SecretTestError(message: "unexpected copy")
    },
    refreshCopiedKeywords: @escaping @MainActor @Sendable (
        KeywordResearchPostCopyRefreshPlan
    ) async throws -> KeywordResearchPostCopyRefreshSummary = { plan in
        KeywordResearchPostCopyRefreshSummary(
            requestedTrackCount: plan.trackIdentityKeys.count,
            completedTrackCount: plan.trackIdentityKeys.count,
            failedTrackCount: 0,
            issue: nil
        )
    }
) -> KeywordResearchProjectCopyDependencies {
    KeywordResearchProjectCopyDependencies(
        loadTargetsPage: loadTargetsPage,
        loadAuthoritativeProject: loadAuthoritativeProject ?? { _ in project },
        preview: preview,
        copy: copy,
        refreshCopiedKeywords: refreshCopiedKeywords
    )
}

private func copyProject(
    id: UUID = UUID(),
    incarnationID: UUID = UUID(),
    bundleID: String? = nil,
    updatedAt: Date = testDate
) -> KeywordResearchProjectSnapshot {
    KeywordResearchProjectSnapshot(
        id: id,
        incarnationID: incarnationID,
        name: "Research",
        bundleID: bundleID,
        defaultStorefront: "us",
        defaultPlatform: .iphone,
        notes: "",
        createdAt: testDate,
        updatedAt: updatedAt
    )
}

private func copyTarget(
    appStoreID: Int64,
    token: String,
    name: String = "Tracked App",
    bundleID: String? = "com.example.app"
) -> KeywordResearchCopyTargetSnapshot {
    KeywordResearchCopyTargetSnapshot(
        persistentIdentifierToken: Data(token.utf8),
        appStoreID: appStoreID,
        createdAt: testDate,
        name: name,
        bundleID: bundleID,
        subtitle: nil,
        sellerName: "Seller",
        iconURLString: nil,
        defaultPlatform: .iphone
    )
}

private func copyPreview(
    project: KeywordResearchProjectSnapshot,
    target: KeywordResearchCopyTargetSnapshot,
    additions: Int,
    duplicates: Int = 0,
    compatibility: KeywordResearchBundleCompatibility = .matches,
    storefronts: [String]? = nil
) -> KeywordResearchProjectCopyPreview {
    let total = additions + duplicates
    let scopes = storefronts ?? Array(repeating: "us", count: total)
    let items = (0..<total).map { index in
        let term = "keyword \(index)"
        let storefront = scopes[index]
        let keyword = KeywordResearchKeywordSnapshot(
            id: UUID(),
            incarnationID: UUID(),
            projectID: project.id,
            queryKey: KeywordQuery.makeQueryKey(
                term: term,
                storefront: storefront,
                platform: .iphone
            ),
            term: term,
            storefront: storefront,
            platform: .iphone,
            notes: "",
            createdAt: testDate.addingTimeInterval(Double(index)),
            updatedAt: testDate.addingTimeInterval(Double(index))
        )
        return KeywordResearchProjectCopyItem(
            keyword: keyword,
            trackIdentityKey: "track-\(index)",
            disposition: index < additions ? .add : .alreadyPresent
        )
    }
    return KeywordResearchProjectCopyPreview(
        project: project,
        target: target,
        bundleCompatibility: compatibility,
        items: items
    )
}

private func copyResult(
    preview: KeywordResearchProjectCopyPreview,
    insertedIdentityKeys: [String],
    alreadyPresentIdentityKeys: [String] = [],
    converged: Bool = false
) -> KeywordResearchProjectCopyResult {
    KeywordResearchProjectCopyResult(
        project: preview.project,
        target: preview.target,
        trackIdentityKeys: preview.trackIdentityKeys,
        insertedTrackIdentityKeys: insertedIdentityKeys,
        alreadyPresentTrackIdentityKeys: alreadyPresentIdentityKeys,
        convergedCompletedCopy: converged
    )
}
