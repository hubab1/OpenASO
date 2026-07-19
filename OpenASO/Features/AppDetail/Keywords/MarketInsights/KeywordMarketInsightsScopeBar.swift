import SwiftUI

struct KeywordMarketInsightsScopeBar: View {
    let appStoreID: Int64
    let platform: AppPlatform
    let storefronts: [String]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 20) {
                    LabeledContent("App ID") {
                        Text(appStoreID, format: .number.grouping(.never))
                            .textSelection(.enabled)
                    }

                    Divider()

                    LabeledContent("Platform") {
                        Label(platform.displayName, systemImage: platformSystemImage)
                    }

                    Divider()

                    LabeledContent("Countries") {
                        Text(storefrontDescription)
                            .lineLimit(1)
                            .help(storefronts.map { $0.uppercased() }.joined(separator: ", "))
                    }

                    Spacer(minLength: 0)
                }

                Text(
                    "Includes all tracked keywords for these countries and this platform. Workspace search, date, and metric filters are not applied."
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var storefrontDescription: String {
        guard !storefronts.isEmpty else { return "None" }
        if storefronts.count <= 6 {
            return storefronts.map { $0.uppercased() }.joined(separator: ", ")
        }
        let preview = storefronts.prefix(5).map { $0.uppercased() }.joined(separator: ", ")
        return "\(storefronts.count) countries · \(preview), …"
    }

    private var platformSystemImage: String {
        switch platform {
        case .iphone:
            "iphone"
        case .ipad:
            "ipad"
        case .mac:
            "macbook"
        }
    }
}
