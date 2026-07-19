import SwiftUI

struct EstimatedKeywordDifficultyProvenanceSection: View {
    let snapshot: EstimatedKeywordDifficultySnapshot

    private var staleAt: Date {
        snapshot.rankingFetchedAt.addingTimeInterval(
            EstimatedKeywordDifficultyFreshness.maximumAge
        )
    }

    var body: some View {
        GroupBox("Provenance") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(
                    "Estimation source",
                    value: snapshot.estimationSource?.displayName ?? "Unsupported source"
                )
                LabeledContent(
                    "Ranking source",
                    value: snapshot.rankingSource?.displayName ?? "Unsupported source"
                )
                LabeledContent("Ranking fetched") {
                    Text(snapshot.rankingFetchedAt, format: .dateTime.year().month().day().hour().minute().second())
                }
                LabeledContent("Computed") {
                    Text(snapshot.computedAt, format: .dateTime.year().month().day().hour().minute().second())
                }
                LabeledContent("Becomes stale") {
                    Text(staleAt, format: .dateTime.year().month().day().hour().minute().second())
                }

                Divider()

                LabeledContent("Algorithm", value: snapshot.algorithmIdentifier)
                LabeledContent("Algorithm version", value: snapshot.algorithmVersion.formatted())
                LabeledContent("Requested result limit", value: snapshot.requestedResultLimit.formatted())
                LabeledContent("Provider result count", value: snapshot.providerResultCount.formatted())

                if snapshot.fallbackProvider != nil || snapshot.fallbackCategory != nil {
                    Divider()
                    Text("Fallback")
                        .font(.headline)

                    if let fallbackProvider = snapshot.fallbackProvider {
                        LabeledContent("Provider", value: fallbackProvider.displayName)
                    }
                    if let fallbackCategory = snapshot.fallbackCategory {
                        LabeledContent("Reason category", value: fallbackCategory.displayName)
                    }
                    if let fallbackTransportCode = snapshot.fallbackTransportCode {
                        LabeledContent("Transport code", value: fallbackTransportCode.formatted())
                    }
                    if let fallbackHTTPStatus = snapshot.fallbackHTTPStatus {
                        LabeledContent("HTTP status", value: fallbackHTTPStatus.formatted())
                    }
                    if let fallbackResponseFailure = snapshot.fallbackResponseFailure {
                        LabeledContent("Response classification", value: fallbackResponseFailure.displayName)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }
}
