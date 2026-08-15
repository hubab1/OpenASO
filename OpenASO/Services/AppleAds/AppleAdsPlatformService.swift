import AppleAdsClient
import Foundation
import OpenAPIRuntime

struct AppleAdsPlatformAccount: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let orgID: Int64?
    let roles: [String]
}

struct AppleAdsPlatformConnection: Codable, Equatable, Sendable {
    let userID: Int64?
    let orgID: Int64?
    let accounts: [AppleAdsPlatformAccount]
    let selectedAdAccountID: Int64

    func applying(to credentials: AppleAdsCredentials) -> AppleAdsCredentials {
        AppleAdsCredentials(
            clientID: credentials.clientID,
            teamID: credentials.teamID,
            keyID: credentials.keyID,
            privateKey: credentials.privateKey,
            orgID: orgID.map(String.init) ?? credentials.orgID,
            adAccountID: String(selectedAdAccountID)
        )
    }
}

struct AppleAdsPlatformCampaignSummary: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let status: String?
    let displayStatus: String?
    let promotedObjectID: String?
    let modifiedAt: Date?
}

struct AppleAdsSearchTermPopularity: Codable, Equatable, Identifiable, Sendable {
    let searchTerm: String
    let countryOrRegion: String
    let genre: String
    let week: String?
    let month: String?
    let rankInGenre: Int?
    let popularityInGenre: Int?
    let popularity1to100: Int?
    let popularity1to5: Int?

    var id: String {
        [countryOrRegion, normalizedSearchTerm, week ?? month ?? "", genre]
            .joined(separator: "|")
    }

    var normalizedSearchTerm: String {
        Self.normalized(searchTerm)
    }

    static func normalized(_ searchTerm: String) -> String {
        searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct AppleAdsSearchTermPopularityWindow: Codable, Equatable, Sendable {
    let start: String
    let end: String

    static func recentCompletedWeeks(
        asOf date: Date,
        weekCount: Int = 4
    ) -> AppleAdsSearchTermPopularityWindow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startOfToday = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfToday)
        let daysSinceCompletedSaturday = weekday == 7 ? 7 : weekday
        let end = calendar.date(
            byAdding: .day,
            value: -daysSinceCompletedSaturday,
            to: startOfToday
        )!
        let start = calendar.date(
            byAdding: .day,
            value: -(max(1, weekCount) * 7 - 1),
            to: end
        )!

        return AppleAdsSearchTermPopularityWindow(
            start: Self.dateString(start, calendar: calendar),
            end: Self.dateString(end, calendar: calendar)
        )
    }

    private static func dateString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

struct AppleAdsPlatformCoverage: Codable, Equatable, Sendable {
    struct Family: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let operationCount: Int
    }

    let clientVersion: String
    let baseURL: String
    let operationCount: Int
    let families: [Family]

    static let current = AppleAdsPlatformCoverage(
        clientVersion: "1.109.0",
        baseURL: "https://api.ads.apple.com/v1",
        operationCount: 99,
        families: [
            Family(id: "accounts", title: "Accounts & access", operationCount: 8),
            Family(id: "apps", title: "Apps & eligibility", operationCount: 6),
            Family(id: "maps", title: "Maps brands & locations", operationCount: 14),
            Family(id: "campaigns", title: "Campaigns & ad groups", operationCount: 13),
            Family(id: "targeting", title: "Keywords & targeting", operationCount: 17),
            Family(id: "creative", title: "Ads, creatives & assets", operationCount: 15),
            Family(id: "reporting", title: "Reports & impression share", operationCount: 12),
            Family(id: "optimization", title: "Insights, recommendations & suggestions", operationCount: 14),
        ]
    )
}

protocol AppleAdsPlatformAPI: Sendable {
    var coverage: AppleAdsPlatformCoverage { get }

    func verify(credentials: AppleAdsCredentials) async throws -> AppleAdsPlatformConnection

    func searchOwnedApps(
        named query: String?,
        using credentials: AppleAdsCredentials,
        limit: Int
    ) async throws -> [AppleAdsPromotedApp]

    func listCampaigns(
        using credentials: AppleAdsCredentials,
        limit: Int
    ) async throws -> [AppleAdsPlatformCampaignSummary]

    func searchTermPopularity(
        for searchTerms: [String],
        countryOrRegion: String,
        window: AppleAdsSearchTermPopularityWindow,
        using credentials: AppleAdsCredentials
    ) async throws -> [AppleAdsSearchTermPopularity]
}

struct OfficialAppleAdsPlatformAPI: AppleAdsPlatformAPI {
    let coverage = AppleAdsPlatformCoverage.current

    func verify(credentials: AppleAdsCredentials) async throws -> AppleAdsPlatformConnection {
        let credentials = try validated(credentials)

        return try await perform(credentials: credentials) { client in
            let mePayload = try await client.getMe().ok.body.json
            let aclPayload = try await client.getUserAcls().ok.body.json
            let accounts = (aclPayload.result?.acls ?? []).compactMap { acl -> AppleAdsPlatformAccount? in
                guard let account = acl.adAccount, let id = account.id else { return nil }
                return AppleAdsPlatformAccount(
                    id: id,
                    name: account.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        ?? "Ad account \(id)",
                    orgID: account.orgId,
                    roles: (acl.roles ?? []).sorted()
                )
            }
            .sorted { left, right in
                left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }

            guard !accounts.isEmpty else {
                throw OpenASOError.providerUnavailable(
                    "Apple Ads credentials were accepted, but no accessible ad accounts were returned."
                )
            }

            let requestedAccountID = Int64(credentials.adAccountID)
            let selectedAccountID = accounts.first(where: { $0.id == requestedAccountID })?.id
                ?? accounts[0].id

            return AppleAdsPlatformConnection(
                userID: mePayload.result?.userId,
                orgID: mePayload.result?.orgId ?? accounts.first?.orgID,
                accounts: accounts,
                selectedAdAccountID: selectedAccountID
            )
        }
    }

    func searchOwnedApps(
        named query: String?,
        using credentials: AppleAdsCredentials,
        limit: Int = 50
    ) async throws -> [AppleAdsPromotedApp] {
        let credentials = try validated(credentials)
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedQuery, !normalizedQuery.isEmpty, normalizedQuery.count < 3 {
            throw OpenASOError.providerUnavailable(
                "Enter at least three characters to search Apple Ads apps."
            )
        }
        let resolvedCredentials = try await credentialsWithAccount(credentials)
        let accountID = try requiredAdAccountID(from: resolvedCredentials)
        let pageLimit = Int32(max(1, min(limit, 1_000)))

        return try await perform(credentials: resolvedCredentials) { client in
            let output = try await client.searchApps(
                query: .init(
                    query: normalizedQuery?.nilIfEmpty,
                    returnOwnedApps: true,
                    limit: pageLimit
                ),
                headers: .init(xApContext: XApContext(adAccountID: accountID).rawValue)
            )
            let payload = try output.ok.body.json
            return payload.value2.result.map {
                AppleAdsPromotedApp(
                    adamId: $0.adamId,
                    appName: $0.appName,
                    developerName: $0.developerName,
                    countryOrRegionCodes: $0.countryOrRegionCodes
                )
            }
        }
    }

    func listCampaigns(
        using credentials: AppleAdsCredentials,
        limit: Int = 100
    ) async throws -> [AppleAdsPlatformCampaignSummary] {
        let credentials = try await credentialsWithAccount(try validated(credentials))
        let accountID = try requiredAdAccountID(from: credentials)
        let pageSize = Int32(max(1, min(limit, 1_000)))

        return try await perform(credentials: credentials) { client in
            let output = try await client.postCampaignsQuery(
                headers: .init(xApContext: XApContext(adAccountID: accountID).rawValue),
                body: .json(.init(
                    sorting: [.init(field: "modificationTime", order: .desc)],
                    pagination: .init(pageSize: pageSize, offset: 0, fetchTotalCount: true)
                ))
            )
            let payload = try output.ok.body.json
            let encodedObjects = try JSONEncoder().encode(payload.value1.result ?? [])
            let campaigns = try JSONDecoder().decode(
                [Components.Schemas.Campaign].self,
                from: encodedObjects
            )
            return campaigns.compactMap { campaign in
                guard let id = campaign.id else { return nil }
                return AppleAdsPlatformCampaignSummary(
                    id: id,
                    name: campaign.name?.nilIfEmpty ?? "Campaign \(id)",
                    status: campaign.status?.value1.rawValue,
                    displayStatus: campaign.displayStatus?.value1.rawValue,
                    promotedObjectID: campaign.promotedObjectId,
                    modifiedAt: campaign.modificationTime
                )
            }
        }
    }

    func searchTermPopularity(
        for searchTerms: [String],
        countryOrRegion: String,
        window: AppleAdsSearchTermPopularityWindow,
        using credentials: AppleAdsCredentials
    ) async throws -> [AppleAdsSearchTermPopularity] {
        let credentials = try await credentialsWithAccount(try validated(credentials))
        let accountID = try requiredAdAccountID(from: credentials)
        let countryCode = countryOrRegion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard countryCode.count == 2 else {
            throw OpenASOError.providerUnavailable(
                "Enter a two-letter Apple Ads country or region code."
            )
        }

        let terms = Self.uniqueSearchTerms(searchTerms)
        guard !terms.isEmpty else { return [] }

        return try await perform(credentials: credentials) { client in
            var allRows: [AppleAdsSearchTermPopularity] = []
            for batch in terms.chunkedForAppleAds(maximumCount: 100) {
                try Task.checkCancellation()
                var offset = 0
                let pageSize = 5_000

                while true {
                    try Task.checkCancellation()
                    let output = try await client.searchTermPopularityQuery(
                        .init(
                            headers: .init(
                                xApContext: XApContext(adAccountID: accountID).rawValue
                            ),
                            body: .json(try Self.searchTermPopularityRequest(
                                countryCode: countryCode,
                                searchTerms: batch,
                                window: window,
                                offset: offset,
                                pageSize: pageSize
                            ))
                        )
                    )
                    let payload = try output.ok.body.json
                    let rows = payload.result?.rows ?? []
                    allRows.append(contentsOf: rows.compactMap { row in
                        guard let searchTerm = row.searchTerm?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ), !searchTerm.isEmpty,
                              let returnedCountry = row.countryOrRegion?.trimmingCharacters(
                                in: .whitespacesAndNewlines
                              ), !returnedCountry.isEmpty
                        else { return nil }

                        return AppleAdsSearchTermPopularity(
                            searchTerm: searchTerm,
                            countryOrRegion: returnedCountry.uppercased(),
                            genre: row.genre?.trimmingCharacters(in: .whitespacesAndNewlines)
                                ?? "",
                            week: row.week,
                            month: row.month,
                            rankInGenre: row.rankInGenre,
                            popularityInGenre: row.searchPopularityInGenre,
                            popularity1to100: row.searchPopularity1to100,
                            popularity1to5: row.searchPopularity1to5
                        )
                    })

                    let totalCount = payload.pagination?.totalCount ?? rows.count
                    offset += rows.count
                    if rows.isEmpty || offset >= totalCount || rows.count < pageSize {
                        break
                    }
                }
            }

            return allRows.sorted(by: Self.searchTermPopularityOrdering)
        }
    }

    static func searchTermPopularityRequest(
        countryCode: String,
        searchTerms: [String],
        window: AppleAdsSearchTermPopularityWindow,
        offset: Int,
        pageSize: Int
    ) throws -> Components.Schemas.SearchTermPopularityQueryRequest {
        .init(
            filters: [
                .init(
                    field: "countryOrRegion",
                    _operator: .equals,
                    value: try OpenAPIValueContainer(unvalidatedValue: countryCode)
                ),
                .init(
                    field: "searchTerm",
                    _operator: ._in,
                    value: try OpenAPIValueContainer(unvalidatedValue: searchTerms)
                ),
            ],
            // AppleAdsClient 1.109.0 encodes generated sort items with an `order`
            // property that the live endpoint rejects. Its documented default order
            // is sufficient for pagination, and rows are sorted locally before return.
            sorting: nil,
            timeRange: .init(
                start: window.start,
                end: window.end,
                timeZone: .utc,
                granularity: .weeklySunSat
            ),
            pagination: .init(offset: offset, pageSize: pageSize)
        )
    }

    private func credentialsWithAccount(
        _ credentials: AppleAdsCredentials
    ) async throws -> AppleAdsCredentials {
        if Int64(credentials.adAccountID) != nil {
            return credentials
        }
        return try await verify(credentials: credentials).applying(to: credentials)
    }

    private func requiredAdAccountID(from credentials: AppleAdsCredentials) throws -> Int64 {
        guard let accountID = Int64(credentials.adAccountID), accountID > 0 else {
            throw OpenASOError.providerUnavailable(
                "Verify Apple Ads Platform credentials to select an ad account."
            )
        }
        return accountID
    }

    private func validated(_ credentials: AppleAdsCredentials) throws -> AppleAdsCredentials {
        let credentials = credentials.trimmed
        guard credentials.canVerify else {
            throw OpenASOError.providerUnavailable(
                "Enter the Apple Ads client ID, team ID, key ID, and private key."
            )
        }
        return credentials
    }

    private func perform<Result>(
        credentials: AppleAdsCredentials,
        operation: (Client) async throws -> Result
    ) async throws -> Result {
        let configuration = AppleAdsClient.Configuration(
            clientId: credentials.clientID,
            authMode: .key(
                teamId: credentials.teamID,
                keyId: credentials.keyID,
                privateKeyPEM: credentials.privateKey
            )
        )

        do {
            return try await AppleAdsClient.withClient(
                configuration: configuration,
                body: operation
            )
        } catch let error as OpenASOError {
            throw error
        } catch {
            throw OpenASOError.providerUnavailable(
                "Apple Ads Platform API: \(error.localizedDescription)"
            )
        }
    }

    private static func uniqueSearchTerms(_ searchTerms: [String]) -> [String] {
        var seen: Set<String> = []
        return searchTerms.compactMap { searchTerm in
            let trimmed = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = AppleAdsSearchTermPopularity.normalized(trimmed)
            guard seen.insert(normalized).inserted else { return nil }
            return trimmed
        }
    }

    private static func searchTermPopularityOrdering(
        _ left: AppleAdsSearchTermPopularity,
        _ right: AppleAdsSearchTermPopularity
    ) -> Bool {
        if left.countryOrRegion != right.countryOrRegion {
            return left.countryOrRegion < right.countryOrRegion
        }
        if left.normalizedSearchTerm != right.normalizedSearchTerm {
            return left.normalizedSearchTerm < right.normalizedSearchTerm
        }
        if left.week != right.week {
            return (left.week ?? "") > (right.week ?? "")
        }
        if left.genre != right.genre {
            return left.genre < right.genre
        }
        return (left.rankInGenre ?? .max) < (right.rankInGenre ?? .max)
    }
}

private extension Array {
    func chunkedForAppleAds(maximumCount: Int) -> [[Element]] {
        guard maximumCount > 0 else { return [self] }
        return stride(from: 0, to: count, by: maximumCount).map {
            Array(self[$0 ..< Swift.min($0 + maximumCount, count)])
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
