import Foundation
import SwiftData
import SwiftUI

struct AppIconView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    let appStoreID: Int64
    let storefrontCode: String?
    let preferredIconURLString: String?
    let reloadToken: UInt64
    let size: CGFloat
    let cornerRadius: CGFloat

    init(
        appStoreID: Int64,
        storefrontCode: String? = nil,
        preferredIconURLString: String? = nil,
        reloadToken: UInt64 = 0,
        size: CGFloat = 40,
        cornerRadius: CGFloat = 9
    ) {
        self.appStoreID = appStoreID
        self.storefrontCode = storefrontCode
        self.preferredIconURLString = preferredIconURLString
        self.reloadToken = reloadToken
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        AppIconImageView(
            appStoreID: appStoreID,
            storefrontCode: storefrontCode,
            preferredIconURLString: preferredIconURLString,
            reloadToken: reloadToken,
            size: size,
            cornerRadius: cornerRadius,
            modelContext: modelContext,
            appCatalogService: services.appCatalogService,
            appIconStore: services.appIconStore
        )
    }
}

struct AppIconImageView: View {
    @Environment(\.displayScale) private var displayScale

    let appStoreID: Int64
    let storefrontCode: String?
    let preferredIconURLString: String?
    let reloadToken: UInt64
    let size: CGFloat
    let cornerRadius: CGFloat
    let modelContext: ModelContext
    let appCatalogService: AppCatalogService
    let appIconStore: AppIconStore

    @State private var image: CGImage?
    @State private var loadGeneration: UUID?

    init(
        appStoreID: Int64,
        storefrontCode: String? = nil,
        preferredIconURLString: String? = nil,
        reloadToken: UInt64 = 0,
        size: CGFloat,
        cornerRadius: CGFloat,
        modelContext: ModelContext,
        appCatalogService: AppCatalogService,
        appIconStore: AppIconStore
    ) {
        self.appStoreID = appStoreID
        self.storefrontCode = storefrontCode
        self.preferredIconURLString = preferredIconURLString
        self.reloadToken = reloadToken
        self.size = size
        self.cornerRadius = cornerRadius
        self.modelContext = modelContext
        self.appCatalogService = appCatalogService
        self.appIconStore = appIconStore
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.12))

            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .controlSize(progressControlSize)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: taskID) {
            guard !Task.isCancelled else { return }

            let generation = UUID()
            loadGeneration = generation
            image = nil
            await loadImage(generation: generation)
        }
    }

    private var taskID: String {
        [
            String(appStoreID),
            storefrontCode ?? "",
            preferredIconURLString ?? "",
            String(reloadToken),
        ].joined(separator: "::")
    }

    private var progressControlSize: ControlSize {
        switch size {
        case ..<32:
            .mini
        case ..<48:
            .small
        case ..<72:
            .regular
        default:
            .large
        }
    }

    @MainActor
    private func loadImage(generation: UUID) async {
        do {
            let iconURLString = try await resolveIconURLString()

            let loadedImage: CGImage?
            if let iconURLString {
                loadedImage = try await appIconStore.image(
                    for: appStoreID,
                    iconURLString: iconURLString,
                    pointSize: size,
                    displayScale: displayScale
                )
            } else {
                loadedImage = nil
            }

            guard !Task.isCancelled, loadGeneration == generation else { return }
            image = loadedImage
        } catch {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            image = nil
        }
    }

    @MainActor
    private func resolveIconURLString() async throws -> String? {
        if let preferredIconURLString, !preferredIconURLString.isEmpty {
            return preferredIconURLString
        }

        let storeApp = try await appCatalogService.storeApp(
            appStoreID: appStoreID,
            storefrontCode: storefrontCode,
            in: modelContext
        )

        return storeApp?.iconURLString
    }
}
