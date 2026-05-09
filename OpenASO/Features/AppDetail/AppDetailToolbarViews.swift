import SwiftData
import SwiftUI

struct AppDetailRefreshToolbarButton: View {
    let isRefreshing: Bool
    let isDisabled: Bool
    let action: () -> Void
    let refreshAllAction: () -> Void

    var body: some View {
        Menu {
            Button {
                refreshAllAction()
            } label: {
                Label("Refresh All Apps", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isDisabled)
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        } primaryAction: {
            action()
        }
        .disabled(isDisabled)
        .help("Refresh App")
    }
}

struct AppDetailWorkspaceViewPicker: View {
    @Binding var selectedWorkspaceView: AppDetailWorkspaceView

    var body: some View {
        HStack(spacing: 0) {
            Picker("View", selection: $selectedWorkspaceView) {
                ForEach(AppDetailWorkspaceView.allCases) { view in
                    Text(view.title)
                        .tag(view)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
        }
        .padding(.horizontal, 2)
        .help("Choose View")
    }
}

struct AppDetailStorefrontPickerButton: View {
    let trackedAppStoreID: Int64

    @Binding var selectedStorefrontFilter: StorefrontFilter
    @State private var isShowingStorefrontPicker = false
    @State private var storefrontSearchText = ""

    var body: some View {
        Button(action: showPicker) {
            HStack(spacing: 8) {
                Text(selectedStorefrontFilter.icon)
                Text(selectedStorefrontFilter.shortTitle)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minWidth: 150)
            .activeToolbarBorder(selectedStorefrontFilter != .all)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingStorefrontPicker, arrowEdge: .bottom) {
            AppDetailStorefrontPickerPopover(
                selectedStorefrontFilter: $selectedStorefrontFilter,
                isShowingStorefrontPicker: $isShowingStorefrontPicker,
                storefrontSearchText: $storefrontSearchText,
                trackedAppStoreID: trackedAppStoreID
            )
        }
        .help("Choose Country")
    }

    private func showPicker() {
        isShowingStorefrontPicker.toggle()
    }
}

struct AppDetailFilterToolbarItems: View {
    @Binding var keywordWorkspaceState: KeywordWorkspaceState

    var body: some View {
        AppDetailDateRangeToolbarMenu(selectedDateRange: $keywordWorkspaceState.selectedDateRange)

        AppDetailFilterButton(
            selectedPlatformFilter: $keywordWorkspaceState.selectedPlatformFilter,
            popularityFilterRange: $keywordWorkspaceState.popularityFilterRange,
            difficultyFilterRange: $keywordWorkspaceState.difficultyFilterRange,
            positionFilterRange: $keywordWorkspaceState.positionFilterRange,
            changeFilterRange: $keywordWorkspaceState.changeFilterRange,
            showsOnlyChangedKeywords: $keywordWorkspaceState.showsOnlyChangedKeywords,
            resetFilters: {
                keywordWorkspaceState.resetFilters()
            }
        )
    }
}

struct AppDetailDateRangeToolbarMenu: View {
    @Binding var selectedDateRange: TrendDateRange

    var body: some View {
        AppDetailToolbarMenu(label: selectedDateRange.title, systemImage: "calendar") {
            ForEach(TrendDateRange.allCases) { option in
                Button(option.title) {
                    selectedDateRange = option
                }
            }
        }
    }
}

struct AppDetailToolbarSearchField: View {
    let selectedWorkspaceView: AppDetailWorkspaceView
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(selectedWorkspaceView.searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .background(.clear)

            if !searchText.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: 240)
    }

    private func clearSearch() {
        searchText = ""
    }
}

struct AppDetailImportExportToolbarMenu: View {
    let exportAction: () -> Void
    let exportHistoryAction: () -> Void
    let importAction: () -> Void
    let isImportDisabled: Bool

    var body: some View {
        Menu {
            Button(action: exportAction) {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }

            Button(action: exportHistoryAction) {
                Label("Export Historical Rankings CSV", systemImage: "clock.arrow.circlepath")
            }

            Button(action: importAction) {
                Label("Import CSV", systemImage: "square.and.arrow.down")
            }
            .disabled(isImportDisabled)
        } label: {
            Label("Import/Export", systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
                .padding(.horizontal, 2)
        }
        .help("Import or Export CSV")
    }
}

struct AppDetailExportToolbarButton: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "square.and.arrow.up")
                .labelStyle(.titleAndIcon)
        }
        .help(help)
    }
}

struct AppDetailAddKeywordsToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Add Keywords", systemImage: "plus")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.white)
        }
        .background(Color.accentColor)
        .clipShape(Capsule())
        .help("Add Keywords")
    }
}

private struct AppDetailFilterButton: View {
    @Binding var selectedPlatformFilter: PlatformFilter
    @Binding var popularityFilterRange: ClosedRange<Double>
    @Binding var difficultyFilterRange: ClosedRange<Double>
    @Binding var positionFilterRange: ClosedRange<Double>
    @Binding var changeFilterRange: ClosedRange<Double>
    @Binding var showsOnlyChangedKeywords: Bool

    let resetFilters: () -> Void
    @State private var isShowingFilters = false

    var body: some View {
        Button(action: toggleFilters) {
            Label("Filters", systemImage: "slider.horizontal.3")
                .labelStyle(.iconOnly)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .activeToolbarBorder(hasActiveFilters)
        }
        .buttonStyle(.plain)
        .help("Filters")
        .popover(isPresented: $isShowingFilters, arrowEdge: .bottom) {
            AppDetailFilterPopover(
                selectedPlatformFilter: $selectedPlatformFilter,
                popularityFilterRange: $popularityFilterRange,
                difficultyFilterRange: $difficultyFilterRange,
                positionFilterRange: $positionFilterRange,
                changeFilterRange: $changeFilterRange,
                showsOnlyChangedKeywords: $showsOnlyChangedKeywords,
                resetFilters: resetFilters
            )
        }
    }

    private func toggleFilters() {
        isShowingFilters.toggle()
    }

    private var hasActiveFilters: Bool {
        selectedPlatformFilter != .all
            || !MetricFilterRange.popularity.isDefault(popularityFilterRange)
            || !MetricFilterRange.difficulty.isDefault(difficultyFilterRange)
            || !MetricFilterRange.position.isDefault(positionFilterRange)
            || !MetricFilterRange.change.isDefault(changeFilterRange)
            || showsOnlyChangedKeywords
    }
}

private struct AppDetailFilterPopover: View {
    @Binding var selectedPlatformFilter: PlatformFilter
    @Binding var popularityFilterRange: ClosedRange<Double>
    @Binding var difficultyFilterRange: ClosedRange<Double>
    @Binding var positionFilterRange: ClosedRange<Double>
    @Binding var changeFilterRange: ClosedRange<Double>
    @Binding var showsOnlyChangedKeywords: Bool

    let resetFilters: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filters")
                .font(.headline)

            Picker("Device", selection: $selectedPlatformFilter) {
                ForEach(PlatformFilter.allCases) { filter in
                    Label(filter.title, systemImage: filter.systemImage)
                        .tag(filter)
                }
            }
            .pickerStyle(.menu)

            Divider()
            FilterRangeSlider(range: $popularityFilterRange, configuration: .popularity)
            Divider()
            FilterRangeSlider(range: $difficultyFilterRange, configuration: .difficulty)
            Divider()
            FilterRangeSlider(range: $positionFilterRange, configuration: .position)
            Divider()
            Toggle("Changed only", isOn: $showsOnlyChangedKeywords)
                .toggleStyle(.checkbox)
            Divider()
            FilterRangeSlider(range: $changeFilterRange, configuration: .change)
            Divider()

            HStack {
                Spacer()
                Button("Reset", action: resetFilters)
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct AppDetailStorefrontPickerPopover: View {
    @Environment(\.modelContext) private var modelContext

    @Binding var selectedStorefrontFilter: StorefrontFilter
    @Binding var isShowingStorefrontPicker: Bool
    @Binding var storefrontSearchText: String

    let trackedAppStoreID: Int64

    private var filteredStorefrontOptions: [StorefrontPickerOption] {
        let normalizedSearch = storefrontSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return storefrontPickerOptions.filter { option in
            guard !normalizedSearch.isEmpty else { return true }
            return option.title.localizedCaseInsensitiveContains(normalizedSearch)
                || option.code.localizedCaseInsensitiveContains(normalizedSearch)
        }
    }

    private var storefrontPickerOptions: [StorefrontPickerOption] {
        let tracks = trackedKeywords()
        let keywordCounts = Dictionary(grouping: tracks, by: \.storefront)
            .mapValues(\.count)
        let options = storefrontDefinitions.map { storefront in
            StorefrontPickerOption(
                filter: .storefront(code: storefront.code, title: storefront.title),
                code: storefront.code,
                icon: storefront.flagEmoji,
                title: storefront.name,
                keywordCount: keywordCounts[storefront.code, default: 0]
            )
        }

        return [
            StorefrontPickerOption(
                filter: .all,
                code: "all",
                icon: "🌎",
                title: "All",
                keywordCount: tracks.count
            )
        ] + options.sorted {
            let leftCount = $0.keywordCount
            let rightCount = $1.keywordCount
            if leftCount == rightCount {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return leftCount > rightCount
        }
    }

    private func trackedKeywords() -> [TrackedAppKeyword] {
        let appStoreID = trackedAppStoreID
        let descriptor = FetchDescriptor<TrackedAppKeyword>(
            predicate: #Predicate { track in
                track.appStoreID == appStoreID
            },
            sortBy: [
                SortDescriptor(\TrackedAppKeyword.term, order: .forward),
                SortDescriptor(\TrackedAppKeyword.storefront, order: .forward),
                SortDescriptor(\TrackedAppKeyword.platformRaw, order: .forward)
            ]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private var storefrontDefinitions: [StorefrontDefinition] {
        ((try? StorefrontCatalog().bundledStorefronts()) ?? []).map {
            StorefrontDefinition(
                code: $0.code.lowercased(),
                name: $0.name,
                flagEmoji: $0.flagEmoji,
                title: "\($0.flagEmoji) \($0.name)"
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppDetailStorefrontSearchField(storefrontSearchText: $storefrontSearchText)
            AppDetailStorefrontOptionList(
                selectedStorefrontFilter: $selectedStorefrontFilter,
                isShowingStorefrontPicker: $isShowingStorefrontPicker,
                storefrontSearchText: $storefrontSearchText,
                options: filteredStorefrontOptions
            )
        }
        .padding(10)
        .frame(width: 420, height: 520)
    }
}

private struct AppDetailStorefrontSearchField: View {
    @Binding var storefrontSearchText: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search a Country", text: $storefrontSearchText)
                .textFieldStyle(.plain)

            Button(action: clearSearch) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear Country Search")
        }
        .font(.title3)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func clearSearch() {
        storefrontSearchText = ""
    }
}

private struct AppDetailStorefrontOptionList: View {
    @Binding var selectedStorefrontFilter: StorefrontFilter
    @Binding var isShowingStorefrontPicker: Bool
    @Binding var storefrontSearchText: String

    let options: [StorefrontPickerOption]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(options) { option in
                    AppDetailStorefrontOptionButton(
                        option: option,
                        isSelected: option.filter == selectedStorefrontFilter,
                        selectOption: selectOption
                    )
                    Divider()
                        .padding(.leading, 54)
                }
            }
        }
    }

    private func selectOption(_ option: StorefrontPickerOption) {
        selectedStorefrontFilter = option.filter
        isShowingStorefrontPicker = false
        storefrontSearchText = ""
    }
}

private struct AppDetailStorefrontOptionButton: View {
    let option: StorefrontPickerOption
    let isSelected: Bool
    let selectOption: (StorefrontPickerOption) -> Void

    var body: some View {
        Button(action: selectCurrentOption) {
            HStack(spacing: 12) {
                Text(option.icon)
                    .font(.title2)
                    .frame(width: 28)

                Text(option.title)
                    .font(.title3.weight(.medium))

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()

                Text(option.keywordCount.formatted())
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }

    private func selectCurrentOption() {
        selectOption(option)
    }
}

private struct AppDetailToolbarMenu<Content: View>: View {
    let label: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Label(label, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background {
                    AppDetailToolbarPill()
                }
        }
        .menuStyle(.borderlessButton)
    }
}

private struct AppDetailToolbarPill: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(Color(NSColor.controlBackgroundColor))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.secondary.opacity(0.12))
            )
    }
}

private extension View {
    @ViewBuilder
    func activeToolbarBorder(_ isActive: Bool) -> some View {
        if isActive {
            overlay {
                Capsule(style: .continuous)
                    .stroke(.purple, lineWidth: 1.5)
            }
        } else {
            self
        }
    }
}
