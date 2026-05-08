import Foundation
import SwiftData

final class AppCatalogService: Sendable {
    private let appResolver: any AppResolver

    init(appResolver: any AppResolver) {
        self.appResolver = appResolver
    }

    struct SearchRankingPageCache {
        fileprivate var storeAppsByID: [Int64: StoreApp]
        fileprivate var storefrontMetadataByIdentityKey: [String: AppStorefrontMetadata]
    }

    fileprivate struct ScreenshotReplacementItem: Equatable {
        let platformRaw: String
        let displayTypeRaw: String
        let sortOrder: Int
        let urlString: String
        let width: Int?
        let height: Int?
    }

    @discardableResult
    func upsertStoreApp(
        from resolvedApp: ResolvedApp,
        storefrontCode: String? = nil,
        in modelContext: ModelContext
    ) throws -> StoreApp {
        let normalizedStorefront = normalizedStorefrontCode(storefrontCode)
        let storeApp: StoreApp
        if let existing = try fetchStoreApp(appStoreID: resolvedApp.appStoreID, in: modelContext) {
            storeApp = existing
        } else {
            storeApp = StoreApp(
                appStoreID: resolvedApp.appStoreID,
                bundleID: resolvedApp.bundleID,
                name: resolvedApp.name,
                subtitle: resolvedApp.subtitle,
                sellerName: resolvedApp.sellerName,
                iconURLString: resolvedApp.iconURLString,
                defaultStorefront: normalizedStorefront,
                supportedLanguageCodes: normalizedLanguageCodes(resolvedApp.supportedLanguageCodes),
                supportedLanguageCodesSource: .iTunesLookup,
                supportedLanguageCodesFetchedAt: resolvedApp.supportedLanguageCodes.isEmpty ? nil : .now,
                releaseDate: resolvedApp.releaseDate,
                currentVersionReleaseDate: resolvedApp.currentVersionReleaseDate,
                version: resolvedApp.version,
                primaryGenreID: resolvedApp.primaryGenreID,
                primaryGenreName: resolvedApp.primaryGenreName,
                defaultPlatform: resolvedApp.defaultPlatform
            )
            modelContext.insert(storeApp)
        }

        update(
            storeApp,
            storefront: normalizedStorefront,
            bundleID: resolvedApp.bundleID,
            name: resolvedApp.name,
            subtitle: resolvedApp.subtitle,
            sellerName: resolvedApp.sellerName,
            iconURLString: resolvedApp.iconURLString,
            supportedLanguageCodes: resolvedApp.supportedLanguageCodes,
            supportedLanguageCodesSource: .iTunesLookup,
            releaseDate: resolvedApp.releaseDate,
            currentVersionReleaseDate: resolvedApp.currentVersionReleaseDate,
            version: resolvedApp.version,
            primaryGenreID: resolvedApp.primaryGenreID,
            primaryGenreName: resolvedApp.primaryGenreName,
            defaultPlatform: resolvedApp.defaultPlatform
        )
        try upsertStorefrontMetadata(
            from: resolvedApp,
            storefront: normalizedStorefront,
            storeApp: storeApp,
            in: modelContext
        )

        return storeApp
    }

    @discardableResult
    func upsertStoreApp(
        from item: SearchRankingItem,
        storefrontCode: String? = nil,
        in modelContext: ModelContext
    ) throws -> StoreApp {
        var cache = try makeSearchRankingPageCache(
            items: [item],
            storefrontCode: storefrontCode,
            in: modelContext
        )
        return try upsertStoreApp(
            from: item,
            storefrontCode: storefrontCode,
            in: modelContext,
            cache: &cache
        )
    }

    func makeSearchRankingPageCache(
        items: [SearchRankingItem],
        storefrontCode: String?,
        in modelContext: ModelContext
    ) throws -> SearchRankingPageCache {
        let normalizedStorefront = normalizedStorefrontCode(storefrontCode)
        let appStoreIDs = Array(Set(items.map(\.appStoreID)))
        let metadataIdentityKeys = appStoreIDs.map {
            AppStorefrontMetadata.makeIdentityKey(appStoreID: $0, storefront: normalizedStorefront)
        }

        return SearchRankingPageCache(
            storeAppsByID: try fetchStoreApps(appStoreIDs: appStoreIDs, in: modelContext),
            storefrontMetadataByIdentityKey: try fetchStorefrontMetadata(
                identityKeys: metadataIdentityKeys,
                in: modelContext
            )
        )
    }

    @discardableResult
    func upsertStoreApp(
        from item: SearchRankingItem,
        storefrontCode: String? = nil,
        in modelContext: ModelContext,
        cache: inout SearchRankingPageCache
    ) throws -> StoreApp {
        let normalizedStorefront = normalizedStorefrontCode(storefrontCode)
        let storeApp: StoreApp
        if let existing = try cache.storeAppsByID[item.appStoreID] ?? fetchStoreApp(appStoreID: item.appStoreID, in: modelContext) {
            storeApp = existing
            cache.storeAppsByID[item.appStoreID] = existing
        } else {
            storeApp = StoreApp(
                appStoreID: item.appStoreID,
                bundleID: item.bundleID,
                name: item.name,
                subtitle: item.subtitle,
                sellerName: item.sellerName,
                iconURLString: item.iconURLString,
                defaultStorefront: normalizedStorefront,
                supportedLanguageCodes: normalizedLanguageCodes(item.supportedLanguageCodes),
                supportedLanguageCodesSource: .iTunesSearch,
                supportedLanguageCodesFetchedAt: .now,
                releaseDate: item.releaseDate,
                currentVersionReleaseDate: item.currentVersionReleaseDate,
                version: item.version,
                primaryGenreID: item.primaryGenreID,
                primaryGenreName: item.primaryGenreName,
                defaultPlatform: item.platform
            )
            modelContext.insert(storeApp)
            cache.storeAppsByID[item.appStoreID] = storeApp
        }

        update(
            storeApp,
            storefront: normalizedStorefront,
            bundleID: item.bundleID,
            name: item.name,
            subtitle: item.subtitle,
            sellerName: item.sellerName,
            iconURLString: item.iconURLString,
            supportedLanguageCodes: item.supportedLanguageCodes,
            supportedLanguageCodesSource: .iTunesSearch,
            releaseDate: item.releaseDate,
            currentVersionReleaseDate: item.currentVersionReleaseDate,
            version: item.version,
            primaryGenreID: item.primaryGenreID,
            primaryGenreName: item.primaryGenreName,
            defaultPlatform: item.platform
        )
        try upsertStorefrontMetadata(
            from: item,
            storefront: normalizedStorefront,
            storeApp: storeApp,
            in: modelContext,
            cache: &cache
        )

        return storeApp
    }

    func upsertStoreApps(from resolvedApps: [ResolvedApp], in modelContext: ModelContext) throws {
        for resolvedApp in resolvedApps {
            _ = try upsertStoreApp(from: resolvedApp, in: modelContext)
        }
    }

    func upsertStoreApps(from items: [SearchRankingItem], in modelContext: ModelContext) throws {
        for item in items {
            _ = try upsertStoreApp(from: item, in: modelContext)
        }
    }

    @discardableResult
    func upsertStoreApp(
        from webMetadata: AppStoreWebMetadata,
        storefrontCode: String? = nil,
        in modelContext: ModelContext
    ) throws -> StoreApp {
        let normalizedStorefront = normalizedStorefrontCode(storefrontCode ?? webMetadata.storefront)
        let storeApp: StoreApp
        if let existing = try fetchStoreApp(appStoreID: webMetadata.appStoreID, in: modelContext) {
            storeApp = existing
        } else {
            storeApp = StoreApp(
                appStoreID: webMetadata.appStoreID,
                bundleID: nil,
                name: nonEmpty(webMetadata.name) ?? "App \(webMetadata.appStoreID)",
                subtitle: webMetadata.subtitle,
                sellerName: webMetadata.sellerName,
                iconURLString: nil,
                defaultStorefront: normalizedStorefront,
                defaultPlatform: .iphone
            )
            modelContext.insert(storeApp)
        }

        update(
            storeApp,
            storefront: normalizedStorefront,
            bundleID: nil,
            name: nonEmpty(webMetadata.name) ?? storeApp.name,
            subtitle: webMetadata.subtitle,
            sellerName: webMetadata.sellerName,
            iconURLString: nil,
            supportedLanguageCodes: [],
            supportedLanguageCodesSource: nil,
            releaseDate: nil,
            currentVersionReleaseDate: nil,
            version: nil,
            primaryGenreID: nil,
            primaryGenreName: nil,
            defaultPlatform: storeApp.defaultPlatform
        )
        try upsertStorefrontMetadata(
            from: webMetadata,
            storefront: normalizedStorefront,
            storeApp: storeApp,
            in: modelContext
        )

        return storeApp
    }

    @MainActor
    func enrichStorefrontMetadataIfNeeded(
        appStoreID: Int64,
        storefrontCode: String,
        platform: AppPlatform,
        freshnessInterval: TimeInterval,
        in modelContext: ModelContext
    ) async throws {
        guard try shouldEnrichStorefrontMetadata(
            appStoreID: appStoreID,
            storefrontCode: storefrontCode,
            platform: platform,
            freshnessInterval: freshnessInterval,
            in: modelContext
        ) else {
            return
        }

        let normalizedStorefront = normalizedStorefrontCode(storefrontCode)
        let resolvedApp = try await appResolver.resolve(appStoreID: appStoreID, storefrontCode: normalizedStorefront)
        _ = try upsertStoreApp(from: resolvedApp, storefrontCode: normalizedStorefront, in: modelContext)
        try modelContext.save()
    }

    @MainActor
    func storeApp(
        appStoreID: Int64,
        storefrontCode: String?,
        in modelContext: ModelContext
    ) async throws -> StoreApp? {
        if let existing = try fetchStoreApp(appStoreID: appStoreID, in: modelContext), existing.iconURLString != nil {
            return existing
        }

        let storefrontCode = normalizedStorefrontCode(storefrontCode)
        let resolvedApp = try await appResolver.resolve(appStoreID: appStoreID, storefrontCode: storefrontCode)
        let storeApp = try upsertStoreApp(from: resolvedApp, storefrontCode: storefrontCode, in: modelContext)
        try modelContext.save()
        return storeApp
    }

    func shouldEnrichStorefrontMetadata(
        appStoreID: Int64,
        storefrontCode: String,
        platform: AppPlatform,
        freshnessInterval: TimeInterval,
        in modelContext: ModelContext
    ) throws -> Bool {
        let normalizedStorefront = normalizedStorefrontCode(storefrontCode)
        let freshnessCutoff = Date.now.addingTimeInterval(-freshnessInterval)
        guard let storeApp = try fetchStoreApp(appStoreID: appStoreID, in: modelContext) else {
            return true
        }

        let languageDataIsStale = storeApp.supportedLanguageCodes.isEmpty
            || (storeApp.supportedLanguageCodesFetchedAt ?? .distantPast) < freshnessCutoff

        let identityKey = AppStorefrontMetadata.makeIdentityKey(
            appStoreID: appStoreID,
            storefront: normalizedStorefront
        )
        guard let metadata = try fetchStorefrontMetadata(identityKey: identityKey, in: modelContext) else {
            return true
        }

        let metadataIsStale = metadata.lastFetchedAt < freshnessCutoff
        let hasFreshWebEnrichment = metadata.source == .appStoreWeb && metadata.lastFetchedAt >= freshnessCutoff
        let desiredPlatform = platform.rawValue
        let hasDesiredPlatformScreenshots = metadata.screenshots.contains {
            $0.platformRaw == desiredPlatform
        }
        let hasAnyScreenshots = !metadata.screenshots.isEmpty
        let isMissingMetadata = nonEmpty(metadata.name) == nil || nonEmpty(metadata.subtitle) == nil

        let metadataHasGaps = isMissingMetadata || !hasAnyScreenshots || !hasDesiredPlatformScreenshots
        return languageDataIsStale || metadataIsStale || (metadataHasGaps && !hasFreshWebEnrichment)
    }

    private func fetchStoreApp(appStoreID: Int64, in modelContext: ModelContext) throws -> StoreApp? {
        let targetAppStoreID = appStoreID
        var descriptor = FetchDescriptor<StoreApp>(
            predicate: #Predicate { storeApp in
                storeApp.appStoreID == targetAppStoreID
            }
        )
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first
    }

    private func fetchStoreApps(appStoreIDs: [Int64], in modelContext: ModelContext) throws -> [Int64: StoreApp] {
        guard !appStoreIDs.isEmpty else { return [:] }

        let targetAppStoreIDs = appStoreIDs
        let descriptor = FetchDescriptor<StoreApp>(
            predicate: #Predicate { storeApp in
                targetAppStoreIDs.contains(storeApp.appStoreID)
            }
        )

        return Dictionary(uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.appStoreID, $0) })
    }

    private func normalizedStorefrontCode(_ storefrontCode: String?) -> String {
        let normalized = storefrontCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalized, !normalized.isEmpty {
            return normalized
        }
        return "us"
    }

    private func update(
        _ storeApp: StoreApp,
        storefront: String? = nil,
        bundleID: String?,
        name: String,
        subtitle: String?,
        sellerName: String?,
        iconURLString: String?,
        supportedLanguageCodes: [String] = [],
        supportedLanguageCodesSource: AppStorefrontMetadataSource? = nil,
        releaseDate: Date?,
        currentVersionReleaseDate: Date?,
        version: String?,
        primaryGenreID: Int?,
        primaryGenreName: String?,
        defaultPlatform: AppPlatform
    ) {
        var changed = false
        if let bundleID, !bundleID.isEmpty {
            changed = assignIfChanged(storeApp, \.bundleID, bundleID) || changed
        }

        let shouldUpdateCanonicalMetadata = shouldUpdateCanonicalMetadata(storeApp: storeApp, storefront: storefront)

        if shouldUpdateCanonicalMetadata {
            changed = assignIfChanged(storeApp, \.name, name) || changed
        }

        let canonicalSubtitleIsMissing = nonEmpty(storeApp.subtitle) == nil
        if (shouldUpdateCanonicalMetadata || canonicalSubtitleIsMissing), let subtitle, !subtitle.isEmpty {
            changed = assignIfChanged(storeApp, \.subtitle, subtitle) || changed
        }

        if let sellerName, !sellerName.isEmpty {
            changed = assignIfChanged(storeApp, \.sellerName, sellerName) || changed
        }

        if shouldUpdateCanonicalMetadata, let iconURLString, !iconURLString.isEmpty {
            changed = assignIfChanged(storeApp, \.iconURLString, iconURLString) || changed
        }

        let normalizedLanguages = normalizedLanguageCodes(supportedLanguageCodes)
        if !normalizedLanguages.isEmpty {
            let languagesChanged = assignIfChanged(storeApp, \.supportedLanguageCodes, normalizedLanguages)
                || assignIfChanged(storeApp, \.supportedLanguageCodesSourceRaw, supportedLanguageCodesSource?.rawValue)
            if languagesChanged {
                storeApp.supportedLanguageCodesFetchedAt = .now
                changed = true
            }
        }

        if let releaseDate {
            changed = assignIfChanged(storeApp, \.releaseDate, releaseDate) || changed
        }

        if let currentVersionReleaseDate {
            changed = assignIfChanged(storeApp, \.currentVersionReleaseDate, currentVersionReleaseDate) || changed
        }

        if let version, !version.isEmpty {
            changed = assignIfChanged(storeApp, \.version, version) || changed
        }

        if let primaryGenreID {
            changed = assignIfChanged(storeApp, \.primaryGenreID, primaryGenreID) || changed
        }

        if let primaryGenreName, !primaryGenreName.isEmpty {
            changed = assignIfChanged(storeApp, \.primaryGenreName, primaryGenreName) || changed
        }

        changed = assignIfChanged(storeApp, \.defaultPlatformRaw, defaultPlatform.rawValue) || changed
        if changed {
            storeApp.lastMetadataRefreshAt = .now
        }
    }

    private func upsertStorefrontMetadata(
        from item: SearchRankingItem,
        storefront: String,
        storeApp: StoreApp,
        in modelContext: ModelContext
    ) throws {
        let identityKey = AppStorefrontMetadata.makeIdentityKey(
            appStoreID: item.appStoreID,
            storefront: storefront
        )
        var cache = SearchRankingPageCache(
            storeAppsByID: [storeApp.appStoreID: storeApp],
            storefrontMetadataByIdentityKey: try fetchStorefrontMetadata(identityKey: identityKey, in: modelContext)
                .map { [identityKey: $0] } ?? [:]
        )
        try upsertStorefrontMetadata(
            from: item,
            storefront: storefront,
            storeApp: storeApp,
            in: modelContext,
            cache: &cache
        )
    }

    private func upsertStorefrontMetadata(
        from item: SearchRankingItem,
        storefront: String,
        storeApp: StoreApp,
        in modelContext: ModelContext,
        cache: inout SearchRankingPageCache
    ) throws {
        let identityKey = AppStorefrontMetadata.makeIdentityKey(
            appStoreID: item.appStoreID,
            storefront: storefront
        )
        let metadata: AppStorefrontMetadata
        if let existing = try cache.storefrontMetadataByIdentityKey[identityKey]
            ?? fetchStorefrontMetadata(identityKey: identityKey, in: modelContext) {
            metadata = existing
            cache.storefrontMetadataByIdentityKey[identityKey] = existing
        } else {
            metadata = AppStorefrontMetadata(
                appStoreID: item.appStoreID,
                storefront: storefront,
                defaultPlatform: item.platform,
                name: item.name,
                subtitle: item.subtitle,
                sellerName: item.sellerName,
                descriptionText: item.descriptionText,
                releaseNotes: item.releaseNotes,
                iconURLString: item.iconURLString,
                version: item.version,
                releaseDate: item.releaseDate,
                currentVersionReleaseDate: item.currentVersionReleaseDate,
                primaryGenreID: item.primaryGenreID,
                primaryGenreName: item.primaryGenreName,
                isAvailable: true,
                source: .iTunesSearch,
                storeApp: storeApp
            )
            modelContext.insert(metadata)
            storeApp.storefrontMetadata.append(metadata)
            cache.storefrontMetadataByIdentityKey[identityKey] = metadata
        }

        var changed = false
        changed = assignIfChanged(metadata, \.appStoreID, item.appStoreID) || changed
        changed = assignIfChanged(metadata, \.storefront, storefront) || changed
        changed = assignIfChanged(metadata, \.defaultPlatformRaw, item.platform.rawValue) || changed
        changed = assignIfChanged(metadata, \.name, item.name) || changed
        if let subtitle = nonEmpty(item.subtitle) {
            changed = assignIfChanged(metadata, \.subtitle, subtitle) || changed
        }
        if let sellerName = nonEmpty(item.sellerName) {
            changed = assignIfChanged(metadata, \.sellerName, sellerName) || changed
        }
        if let descriptionText = nonEmpty(item.descriptionText) {
            changed = assignIfChanged(metadata, \.descriptionText, descriptionText) || changed
        }
        if let releaseNotes = nonEmpty(item.releaseNotes) {
            changed = assignIfChanged(metadata, \.releaseNotes, releaseNotes) || changed
        }
        if let iconURLString = nonEmpty(item.iconURLString) {
            changed = assignIfChanged(metadata, \.iconURLString, iconURLString) || changed
        }
        if let version = nonEmpty(item.version) {
            changed = assignIfChanged(metadata, \.version, version) || changed
        }
        if let releaseDate = item.releaseDate {
            changed = assignIfChanged(metadata, \.releaseDate, releaseDate) || changed
        }
        if let currentVersionReleaseDate = item.currentVersionReleaseDate {
            changed = assignIfChanged(metadata, \.currentVersionReleaseDate, currentVersionReleaseDate) || changed
        }
        if let primaryGenreID = item.primaryGenreID {
            changed = assignIfChanged(metadata, \.primaryGenreID, primaryGenreID) || changed
        }
        if let primaryGenreName = nonEmpty(item.primaryGenreName) {
            changed = assignIfChanged(metadata, \.primaryGenreName, primaryGenreName) || changed
        }
        changed = assignIfChanged(metadata, \.isAvailable, true) || changed
        changed = assignIfChanged(metadata, \.sourceRaw, AppStorefrontMetadataSource.iTunesSearch.rawValue) || changed
        if metadata.storeApp !== storeApp {
            metadata.storeApp = storeApp
            changed = true
        }

        let screenshotsChanged = replaceScreenshots(
            for: metadata,
            item: item,
            storefront: storefront,
            in: modelContext
        )
        if changed || screenshotsChanged {
            metadata.lastFetchedAt = .now
        }
    }

    private func upsertStorefrontMetadata(
        from resolvedApp: ResolvedApp,
        storefront: String,
        storeApp: StoreApp,
        in modelContext: ModelContext
    ) throws {
        let identityKey = AppStorefrontMetadata.makeIdentityKey(
            appStoreID: resolvedApp.appStoreID,
            storefront: storefront
        )
        let metadata: AppStorefrontMetadata
        if let existing = try fetchStorefrontMetadata(identityKey: identityKey, in: modelContext) {
            metadata = existing
        } else {
            metadata = AppStorefrontMetadata(
                appStoreID: resolvedApp.appStoreID,
                storefront: storefront,
                defaultPlatform: resolvedApp.defaultPlatform,
                name: resolvedApp.name,
                subtitle: resolvedApp.subtitle,
                sellerName: resolvedApp.sellerName,
                iconURLString: resolvedApp.iconURLString,
                version: resolvedApp.version,
                releaseDate: resolvedApp.releaseDate,
                currentVersionReleaseDate: resolvedApp.currentVersionReleaseDate,
                primaryGenreID: resolvedApp.primaryGenreID,
                primaryGenreName: resolvedApp.primaryGenreName,
                isAvailable: true,
                source: .iTunesLookup,
                storeApp: storeApp
            )
            modelContext.insert(metadata)
            storeApp.storefrontMetadata.append(metadata)
        }

        metadata.appStoreID = resolvedApp.appStoreID
        metadata.storefront = storefront
        metadata.defaultPlatform = resolvedApp.defaultPlatform
        metadata.name = resolvedApp.name
        metadata.subtitle = nonEmpty(resolvedApp.subtitle) ?? metadata.subtitle
        metadata.sellerName = nonEmpty(resolvedApp.sellerName) ?? metadata.sellerName
        metadata.iconURLString = nonEmpty(resolvedApp.iconURLString) ?? metadata.iconURLString
        metadata.version = nonEmpty(resolvedApp.version) ?? metadata.version
        metadata.releaseDate = resolvedApp.releaseDate ?? metadata.releaseDate
        metadata.currentVersionReleaseDate = resolvedApp.currentVersionReleaseDate ?? metadata.currentVersionReleaseDate
        metadata.primaryGenreID = resolvedApp.primaryGenreID ?? metadata.primaryGenreID
        metadata.primaryGenreName = nonEmpty(resolvedApp.primaryGenreName) ?? metadata.primaryGenreName
        metadata.isAvailable = true
        metadata.source = .iTunesLookup
        metadata.lastFetchedAt = .now
        metadata.storeApp = storeApp

        _ = replaceScreenshots(
            for: metadata,
            resolvedApp: resolvedApp,
            storefront: storefront,
            in: modelContext
        )
    }

    private func upsertStorefrontMetadata(
        from webMetadata: AppStoreWebMetadata,
        storefront: String,
        storeApp: StoreApp,
        in modelContext: ModelContext
    ) throws {
        let identityKey = AppStorefrontMetadata.makeIdentityKey(
            appStoreID: webMetadata.appStoreID,
            storefront: storefront
        )
        let metadata: AppStorefrontMetadata
        if let existing = try fetchStorefrontMetadata(identityKey: identityKey, in: modelContext) {
            metadata = existing
        } else {
            metadata = AppStorefrontMetadata(
                appStoreID: webMetadata.appStoreID,
                storefront: storefront,
                defaultPlatform: storeApp.defaultPlatform,
                name: nonEmpty(webMetadata.name) ?? storeApp.name,
                subtitle: webMetadata.subtitle,
                sellerName: webMetadata.sellerName,
                isAvailable: true,
                source: .appStoreWeb,
                storeApp: storeApp
            )
            modelContext.insert(metadata)
            storeApp.storefrontMetadata.append(metadata)
        }

        metadata.appStoreID = webMetadata.appStoreID
        metadata.storefront = storefront
        metadata.defaultPlatform = storeApp.defaultPlatform
        metadata.name = nonEmpty(webMetadata.name) ?? metadata.name
        metadata.subtitle = nonEmpty(webMetadata.subtitle) ?? metadata.subtitle
        metadata.sellerName = nonEmpty(webMetadata.sellerName) ?? metadata.sellerName
        metadata.isAvailable = true
        metadata.source = .appStoreWeb
        metadata.lastFetchedAt = .now
        metadata.storeApp = storeApp

        _ = replaceScreenshots(
            for: metadata,
            webMetadata: webMetadata,
            storefront: storefront,
            in: modelContext
        )
    }

    @discardableResult
    private func replaceScreenshots(
        for metadata: AppStorefrontMetadata,
        item: SearchRankingItem,
        storefront: String,
        in modelContext: ModelContext
    ) -> Bool {
        replaceScreenshots(
            for: metadata,
            appStoreID: item.appStoreID,
            storefront: storefront,
            groups: [
                ("iphone", item.screenshotURLs),
                ("ipad", item.ipadScreenshotURLs),
                ("tv", item.appletvScreenshotURLs)
            ],
            in: modelContext
        )
    }

    @discardableResult
    private func replaceScreenshots(
        for metadata: AppStorefrontMetadata,
        resolvedApp: ResolvedApp,
        storefront: String,
        in modelContext: ModelContext
    ) -> Bool {
        replaceScreenshots(
            for: metadata,
            appStoreID: resolvedApp.appStoreID,
            storefront: storefront,
            groups: [
                ("iphone", resolvedApp.screenshotURLs),
                ("ipad", resolvedApp.ipadScreenshotURLs),
                ("tv", resolvedApp.appletvScreenshotURLs)
            ],
            in: modelContext
        )
    }

    @discardableResult
    private func replaceScreenshots(
        for metadata: AppStorefrontMetadata,
        webMetadata: AppStoreWebMetadata,
        storefront: String,
        in modelContext: ModelContext
    ) -> Bool {
        let replacements = webMetadata.screenshotGroups.flatMap { group in
            group.screenshots.enumerated().compactMap { index, webScreenshot -> ScreenshotReplacementItem? in
                guard let urlString = nonEmpty(webScreenshot.urlString) else { return nil }
                return ScreenshotReplacementItem(
                    platformRaw: normalizedScreenshotPlatform(group.platformRaw),
                    displayTypeRaw: normalizedScreenshotDisplayType(group.displayTypeRaw),
                    sortOrder: index,
                    urlString: urlString,
                    width: webScreenshot.width,
                    height: webScreenshot.height
                )
            }
        }
        return replaceScreenshots(
            for: metadata,
            appStoreID: webMetadata.appStoreID,
            storefront: storefront,
            replacements: replacements,
            in: modelContext
        )
    }

    @discardableResult
    private func replaceScreenshots(
        for metadata: AppStorefrontMetadata,
        appStoreID: Int64,
        storefront: String,
        groups: [(platform: String, urls: [String])],
        in modelContext: ModelContext
    ) -> Bool {
        let replacements = groups.flatMap { group in
            group.urls.enumerated().compactMap { index, urlString -> ScreenshotReplacementItem? in
                guard let urlString = nonEmpty(urlString) else { return nil }
                return ScreenshotReplacementItem(
                    platformRaw: normalizedScreenshotPlatform(group.platform),
                    displayTypeRaw: "default",
                    sortOrder: index,
                    urlString: urlString,
                    width: nil,
                    height: nil
                )
            }
        }
        return replaceScreenshots(
            for: metadata,
            appStoreID: appStoreID,
            storefront: storefront,
            replacements: replacements,
            in: modelContext
        )
    }

    @discardableResult
    private func replaceScreenshots(
        for metadata: AppStorefrontMetadata,
        appStoreID: Int64,
        storefront: String,
        replacements: [ScreenshotReplacementItem],
        in modelContext: ModelContext
    ) -> Bool {
        let replacements = replacements.sortedForComparison
        guard !replacements.isEmpty else { return false }

        let existing = metadata.screenshots
        if existing.screenshotReplacementItems == replacements {
            return false
        }

        for screenshot in existing {
            modelContext.delete(screenshot)
        }
        metadata.screenshots.removeAll()

        for replacement in replacements {
            let screenshot = AppStoreScreenshot(
                appStoreID: appStoreID,
                storefront: storefront,
                platformRaw: replacement.platformRaw,
                displayTypeRaw: replacement.displayTypeRaw,
                sortOrder: replacement.sortOrder,
                urlString: replacement.urlString,
                width: replacement.width,
                height: replacement.height,
                source: metadata.source,
                metadata: metadata
            )
            metadata.screenshots.append(screenshot)
            modelContext.insert(screenshot)
        }
        return true
    }

    private func normalizedScreenshotPlatform(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedScreenshotDisplayType(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? "default" : normalized
    }

    private func fetchStorefrontMetadata(identityKey: String, in modelContext: ModelContext) throws -> AppStorefrontMetadata? {
        let targetIdentityKey = identityKey
        var descriptor = FetchDescriptor<AppStorefrontMetadata>(
            predicate: #Predicate { metadata in
                metadata.identityKey == targetIdentityKey
            }
        )
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first
    }

    private func fetchStorefrontMetadata(
        identityKeys: [String],
        in modelContext: ModelContext
    ) throws -> [String: AppStorefrontMetadata] {
        guard !identityKeys.isEmpty else { return [:] }

        let targetIdentityKeys = identityKeys
        let descriptor = FetchDescriptor<AppStorefrontMetadata>(
            predicate: #Predicate { metadata in
                targetIdentityKeys.contains(metadata.identityKey)
            }
        )

        return Dictionary(uniqueKeysWithValues: try modelContext.fetch(descriptor).map { ($0.identityKey, $0) })
    }

    private func shouldUpdateCanonicalMetadata(storeApp: StoreApp, storefront: String?) -> Bool {
        guard let storefront else { return true }
        let normalizedStorefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedStorefront == storeApp.defaultStorefront || storeApp.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func normalizedLanguageCodes(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { nonEmpty($0)?.uppercased() })).sorted()
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    @discardableResult
    private func assignIfChanged<Root: AnyObject, Value: Equatable>(
        _ object: Root,
        _ keyPath: ReferenceWritableKeyPath<Root, Value>,
        _ value: Value
    ) -> Bool {
        guard object[keyPath: keyPath] != value else { return false }
        object[keyPath: keyPath] = value
        return true
    }
}

private extension Array where Element == AppStoreScreenshot {
    var screenshotReplacementItems: [AppCatalogService.ScreenshotReplacementItem] {
        sortedForComparison
        .map {
            AppCatalogService.ScreenshotReplacementItem(
                platformRaw: $0.platformRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                displayTypeRaw: $0.displayTypeRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                sortOrder: $0.sortOrder,
                urlString: $0.urlString,
                width: $0.width,
                height: $0.height
            )
        }
    }

    private var sortedForComparison: [AppStoreScreenshot] {
        sorted {
            ($0.platformRaw, $0.displayTypeRaw, $0.sortOrder, $0.urlString)
                < ($1.platformRaw, $1.displayTypeRaw, $1.sortOrder, $1.urlString)
        }
    }
}

private extension Array where Element == AppCatalogService.ScreenshotReplacementItem {
    var sortedForComparison: [AppCatalogService.ScreenshotReplacementItem] {
        sorted {
            ($0.platformRaw, $0.displayTypeRaw, $0.sortOrder, $0.urlString)
                < ($1.platformRaw, $1.displayTypeRaw, $1.sortOrder, $1.urlString)
        }
    }
}
