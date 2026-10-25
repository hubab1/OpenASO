import CryptoKit
import Foundation

struct AppStoreMetadataFields: Codable, Equatable, Sendable {
    var title: String
    var subtitle: String
    /// nil means the private keyword field was not available, rather than empty.
    var keywords: String?
}

struct AppStoreMetadataSnapshot: Codable, Equatable, Sendable {
    let appStoreID: Int64
    let locale: String
    let platform: String
    let scope: String
    let version: String
    let versionID: String
    let versionState: String
    let appInfoID: String
    let fields: AppStoreMetadataFields
    let observedAt: Date
    let source: String
    var descriptionText: String? = nil

    var contentHash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Only metadata and its identity determine the hash, not observation time.
        let identity = [
            String(appStoreID), locale.lowercased(), platform, versionID, appInfoID,
            fields.title, fields.subtitle, fields.keywords == nil ? "unavailable" : "available", fields.keywords ?? "",
        ]
        let data = (try? encoder.encode(identity)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension AppStoreMetadataSnapshot {
    private enum CodingKeys: String, CodingKey {
        case appStoreID, locale, platform, scope, version, versionID, versionState, appInfoID
        case fields, observedAt, source, descriptionText, contentHash
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            appStoreID: try value.decode(Int64.self, forKey: .appStoreID),
            locale: try value.decode(String.self, forKey: .locale),
            platform: try value.decode(String.self, forKey: .platform),
            scope: try value.decode(String.self, forKey: .scope),
            version: try value.decode(String.self, forKey: .version),
            versionID: try value.decode(String.self, forKey: .versionID),
            versionState: try value.decode(String.self, forKey: .versionState),
            appInfoID: try value.decode(String.self, forKey: .appInfoID),
            fields: try value.decode(AppStoreMetadataFields.self, forKey: .fields),
            observedAt: try value.decode(Date.self, forKey: .observedAt),
            source: try value.decode(String.self, forKey: .source),
            descriptionText: try value.decodeIfPresent(String.self, forKey: .descriptionText)
        )
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(appStoreID, forKey: .appStoreID)
        try value.encode(locale, forKey: .locale)
        try value.encode(platform, forKey: .platform)
        try value.encode(scope, forKey: .scope)
        try value.encode(version, forKey: .version)
        try value.encode(versionID, forKey: .versionID)
        try value.encode(versionState, forKey: .versionState)
        try value.encode(appInfoID, forKey: .appInfoID)
        try value.encode(fields, forKey: .fields)
        try value.encode(observedAt, forKey: .observedAt)
        try value.encode(source, forKey: .source)
        try value.encodeIfPresent(descriptionText, forKey: .descriptionText)
        try value.encode(contentHash, forKey: .contentHash)
    }
}

/// Reads one exact locale/version through the existing credential and HTTP seams.
/// It has no App Store write operations and does not fall back to a different locale.
struct AppStoreConnectMetadataService: Sendable {
    let httpClient: any HTTPClient

    func snapshot(
        appStoreID: Int64,
        locale: String,
        platform: String,
        scope: String,
        credentials: AppStoreConnectCredentials,
        now: Date
    ) async throws -> AppStoreMetadataSnapshot {
        guard credentials.isComplete else {
            throw OpenASOError.providerUnavailable("Connect App Store Connect in Settings to read the private keyword field.")
        }
        guard scope == "live" || scope == "editable" else {
            throw OpenASOError.providerUnavailable("Metadata scope must be live or editable.")
        }
        let token = try AppStoreConnectJWT(
            issuerID: credentials.trimmed.issuerID,
            keyID: credentials.trimmed.keyID,
            privateKey: credentials.trimmed.privateKey
        ).signed()
        let versions = try await resources(
            path: "/v1/apps/\(appStoreID)/appStoreVersions",
            query: [.init(name: "filter[platform]", value: platform)],
            token: token
        )
        guard let version = versions.filter({ matches($0.attributes.state, scope: scope) })
            .sorted(by: Self.newestFirst).first else {
            throw OpenASOError.providerUnavailable("No \(scope) \(platform) App Store version is available.")
        }
        let infos = try await resources(path: "/v1/apps/\(appStoreID)/appInfos", token: token)
        let matchingInfos = infos.filter { matches($0.attributes.state, scope: scope) }
        // App infos do not have a reliable version/date relation. Ambiguity must
        // remain visible instead of mixing live and draft names with keywords.
        guard matchingInfos.count == 1, let info = matchingInfos.first else {
            throw OpenASOError.providerUnavailable("Expected one \(scope) app-info record; found \(matchingInfos.count). Resolve the App Store Connect metadata state before auditing.")
        }
        let names = try await resources(path: "/v1/appInfos/\(info.id)/appInfoLocalizations", token: token)
        let texts = try await resources(path: "/v1/appStoreVersions/\(version.id)/appStoreVersionLocalizations", token: token)
        let normalizedLocale = locale.replacingOccurrences(of: "_", with: "-").lowercased()
        guard let name = names.first(where: {
            $0.attributes.locale?.replacingOccurrences(of: "_", with: "-").lowercased() == normalizedLocale
        }), let text = texts.first(where: {
            $0.attributes.locale?.replacingOccurrences(of: "_", with: "-").lowercased() == normalizedLocale
        }), let title = name.attributes.name, !title.isEmpty else {
            throw OpenASOError.providerUnavailable("The exact \(locale) localization is missing from the selected metadata. No other language was substituted.")
        }
        return AppStoreMetadataSnapshot(
            appStoreID: appStoreID,
            locale: name.attributes.locale ?? locale,
            platform: platform,
            scope: scope,
            version: version.attributes.versionString ?? "",
            versionID: version.id,
            versionState: version.attributes.state,
            appInfoID: info.id,
            fields: .init(title: title, subtitle: name.attributes.subtitle ?? "", keywords: text.attributes.keywords),
            observedAt: now,
            source: "app_store_connect",
            descriptionText: text.attributes.description
        )
    }

    private func matches(_ state: String, scope: String) -> Bool {
        if scope == "live" { return ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE"].contains(state) }
        return [
            "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
            "METADATA_REJECTED", "INVALID_BINARY", "READY_FOR_REVIEW",
        ].contains(state)
    }

    private static func newestFirst(_ left: Resource, _ right: Resource) -> Bool {
        let dates = [left.attributes.createdDate, right.attributes.createdDate].map { raw -> Date in
            guard let raw else { return .distantPast }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) ?? .distantPast
        }
        if dates[0] != dates[1] { return dates[0] > dates[1] }
        let order = (left.attributes.versionString ?? "").compare(right.attributes.versionString ?? "", options: .numeric)
        return order == .orderedSame ? left.id < right.id : order == .orderedDescending
    }

    private func resources(
        path: String,
        query: [URLQueryItem] = [],
        token: String
    ) async throws -> [Resource] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.appstoreconnect.apple.com"
        components.path = path
        components.queryItems = query + [.init(name: "limit", value: "200")]
        var next = components.url
        var visited = Set<URL>()
        var result: [Resource] = []
        while let url = next {
            try Task.checkCancellation()
            guard url.scheme == "https", url.host == "api.appstoreconnect.apple.com",
                  url.port == nil || url.port == 443, url.user == nil, url.password == nil,
                  url.path == path, visited.insert(url).inserted, visited.count <= 5 else {
                throw OpenASOError.providerUnavailable("Unsafe, repeated, or unbounded App Store Connect pagination.")
            }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data = try await validatedData(for: request, using: httpClient)
            let page = try JSONDecoder().decode(Page.self, from: data)
            result.append(contentsOf: page.data)
            if let raw = page.links?.next {
                guard let parsed = URL(string: raw, relativeTo: url)?.absoluteURL else {
                    throw OpenASOError.unexpectedResponse
                }
                next = parsed
            } else {
                next = nil
            }
        }
        return result
    }

    private struct Page: Decodable {
        let data: [Resource]
        let links: Links?
    }

    private struct Links: Decodable { let next: String? }
    private struct Resource: Decodable {
        let id: String
        let attributes: Attributes
    }
    private struct Attributes: Decodable {
        let appVersionState: String?
        let appStoreState: String?
        let stateValue: String?
        let versionString: String?
        let createdDate: String?
        let locale: String?
        let name: String?
        let subtitle: String?
        let keywords: String?
        let description: String?

        // Prefer the current state attribute over a stale legacy state.
        var state: String { appVersionState ?? stateValue ?? appStoreState ?? "" }

        enum CodingKeys: String, CodingKey {
            case appVersionState, appStoreState, versionString, createdDate, locale, name, subtitle, keywords, description
            case stateValue = "state"
        }
    }
}
