import SwiftUI

#Preview("Ranking Result Row") {
    let previewContainer = OpenASOPreviewContainer { modelContext in
        let storeApp = StoreApp(
            appStoreID: 382233851,
            bundleID: "com.flightradar24free",
            name: "Flightradar24 | Flight Tracker",
            subtitle: "Live plane tracking and flight status",
            sellerName: "Flightradar24 AB",
            iconURLString: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/17/b6/1a/17b61adf-2c94-6ba0-e6bb-cc4f3dd14a10/AppIcon-0-0-1x_U007epad-0-1-0-85-220.png/100x100bb.jpg",
            defaultPlatform: .iphone
        )
        modelContext.insert(storeApp)
    }

    KeywordRankingResultRow(
        item: KeywordRankingListItem(
            id: 382233851,
            position: 1,
            appStoreID: 382233851,
            name: "Flightradar24 | Flight Tracker",
            subtitle: "Live plane tracking and flight status",
            sellerName: "Flightradar24 AB",
            iconURLString: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/17/b6/1a/17b61adf-2c94-6ba0-e6bb-cc4f3dd14a10/AppIcon-0-0-1x_U007epad-0-1-0-85-220.png/100x100bb.jpg"
        ),
        keyword: "flight tracker",
        storefrontCode: "us",
        trackedAppStoreID: 1358823008
    )
    .padding(24)
    .frame(width: 760)
    .openASOPreviewEnvironment(previewContainer, allowsIconNetworkFetches: true)
}

struct KeywordRankingListItem: Identifiable, Sendable {
    let id: Int64
    let position: Int
    let appStoreID: Int64
    let name: String
    let subtitle: String?
    let sellerName: String?
    let iconURLString: String?

    init(
        id: Int64,
        position: Int,
        appStoreID: Int64,
        name: String,
        subtitle: String?,
        sellerName: String?,
        iconURLString: String? = nil
    ) {
        self.id = id
        self.position = position
        self.appStoreID = appStoreID
        self.name = name
        self.subtitle = subtitle
        self.sellerName = sellerName
        self.iconURLString = iconURLString
    }

    init(result: TrackedKeywordRankedResult) {
        self.id = result.appStoreID
        self.position = result.position
        self.appStoreID = result.appStoreID
        self.name = result.name
        self.subtitle = result.subtitle
        self.sellerName = result.sellerName
        self.iconURLString = nil
    }

    init(result: KeywordRankingAppSummary) {
        self.id = result.appStoreID
        self.position = result.position
        self.appStoreID = result.appStoreID
        self.name = result.name
        self.subtitle = result.subtitle
        self.sellerName = result.sellerName
        self.iconURLString = nil
    }
}

struct KeywordRankingResultRow: View {
    let item: KeywordRankingListItem
    let keyword: String
    let storefrontCode: String
    let trackedAppStoreID: Int64

    var appTitle: String {
        item.name
    }

    var appSubtitle: String? {
        trimmed(item.subtitle)
    }

    var appSellerName: String {
        trimmed(item.sellerName) ?? "Unknown Seller"
    }

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(
                appStoreID: item.appStoreID,
                storefrontCode: storefrontCode,
                preferredIconURLString: item.iconURLString,
                size: 54,
                cornerRadius: 12
            )

            Text("\(item.position)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(appTitle)
                        .font(.headline.weight(item.appStoreID == trackedAppStoreID ? .semibold : .regular))
                        .lineLimit(1)

                    if item.appStoreID == trackedAppStoreID {
                        Text("Tracked App")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.green.opacity(0.15), in: Capsule())
                    }
                }

                if let subtitle = appSubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(appSellerName)
                    Text(verbatim: "App ID \(item.appStoreID)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 12)
    }

    func trimmed(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedValue, !trimmedValue.isEmpty else {
            return nil
        }
        return trimmedValue
    }
}
