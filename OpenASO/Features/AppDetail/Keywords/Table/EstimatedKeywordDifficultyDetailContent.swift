import SwiftUI

struct EstimatedKeywordDifficultyDetailContent: View {
    let snapshot: EstimatedKeywordDifficultySnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    Label {
                        Text("This is a local heuristic derived from public App Store ranking evidence. It is not Apple Ads difficulty, Search Popularity, or an Apple-provided metric.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                EstimatedKeywordDifficultyEstimateSection(snapshot: snapshot)
                EstimatedKeywordDifficultyEvidenceSection(snapshot: snapshot)
                EstimatedKeywordDifficultyProvenanceSection(snapshot: snapshot)
            }
            .padding(20)
        }
    }
}
