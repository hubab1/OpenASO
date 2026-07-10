import Foundation
import SwiftData

@MainActor
final class StorefrontCatalog {
    private var cachedBundledStorefronts: [BundledStorefront]?

    func bundledStorefronts() throws -> [BundledStorefront] {
        if let cachedBundledStorefronts {
            return cachedBundledStorefronts
        }

        let storefronts = try Self.loadBundledStorefronts()
        cachedBundledStorefronts = storefronts
        return storefronts
    }

    nonisolated static func bundledStorefrontCodes() throws -> [String] {
        let codes = try loadBundledStorefronts()
            .map { $0.code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return Array(Set(codes)).sorted()
    }

    func seedIfNeeded(in modelContext: ModelContext) throws {
        let seeds = try bundledStorefronts()
        try Self.seedIfNeeded(seeds: seeds, in: modelContext)
    }

    func seedIfNeeded(using backgroundModelStore: BackgroundModelStore) async throws {
        let seeds = try await bundledStorefrontsInBackground()
        try await backgroundModelStore.write { modelContext in
            try Self.seedIfNeeded(seeds: seeds, in: modelContext)
        }
    }

    private func bundledStorefrontsInBackground() async throws -> [BundledStorefront] {
        if let cachedBundledStorefronts {
            return cachedBundledStorefronts
        }

        let storefronts = try await Task.detached(priority: .utility) {
            try Self.loadBundledStorefronts()
        }.value
        cachedBundledStorefronts = storefronts
        return storefronts
    }

    nonisolated private static func loadBundledStorefronts() throws -> [BundledStorefront] {
        guard let url = Bundle.main.url(forResource: "storefronts", withExtension: "json") else {
            throw OpenASOError.providerUnavailable("The bundled storefront list is missing.")
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([BundledStorefront].self, from: data)
    }

    nonisolated static func normalizedStorefrontCode(_ code: String?) -> String {
        guard let code else {
            return "app-store-connect"
        }

        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedCode.isEmpty else {
            return "app-store-connect"
        }

        return alpha3ToAlpha2StorefrontCodes()[normalizedCode] ?? normalizedCode
    }

    nonisolated static func storefrontCodeAliases(for code: String) -> [String] {
        let normalizedCode = normalizedStorefrontCode(code)
        var aliases = Set([normalizedCode])
        for (alpha3Code, alpha2Code) in alpha3ToAlpha2StorefrontCodes() where alpha2Code == normalizedCode {
            aliases.insert(alpha3Code)
        }
        return aliases.sorted()
    }

    nonisolated private static func alpha3ToAlpha2StorefrontCodes() -> [String: String] {
        guard let storefronts = try? loadBundledStorefronts() else {
            return [:]
        }

        return storefronts.reduce(into: [String: String]()) { partial, storefront in
            guard let alpha3Code = storefront.alpha3Code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !alpha3Code.isEmpty else {
                return
            }
            partial[alpha3Code] = storefront.code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    nonisolated private static func seedIfNeeded(seeds: [BundledStorefront], in modelContext: ModelContext) throws {
        let existingStorefronts = try modelContext.fetch(FetchDescriptor<Storefront>())
        let existingByCode = Dictionary(uniqueKeysWithValues: existingStorefronts.map { ($0.code, $0) })
        let seedCodes = Set(seeds.map { $0.code.lowercased() })
        var didChange = false

        for existing in existingStorefronts where !seedCodes.contains(existing.code) {
            modelContext.delete(existing)
            didChange = true
        }

        for seed in seeds {
            let normalizedCode = seed.code.lowercased()

            if let existing = existingByCode[normalizedCode] {
                if existing.name != seed.name {
                    existing.name = seed.name
                    didChange = true
                }

                if existing.flagEmoji != seed.flagEmoji {
                    existing.flagEmoji = seed.flagEmoji
                    didChange = true
                }

                if existing.languageCode != seed.languageCode {
                    existing.languageCode = seed.languageCode
                    didChange = true
                }

                continue
            }

            modelContext.insert(
                Storefront(
                    code: normalizedCode,
                    name: seed.name,
                    flagEmoji: seed.flagEmoji,
                    languageCode: seed.languageCode
                )
            )
            didChange = true
        }

        if didChange {
            try modelContext.save()
        }
    }
}

struct BundledStorefront: Decodable, Hashable, Sendable {
    let code: String
    let name: String
    let alpha3Code: String?
    let flagEmoji: String
    let languageCode: String
}
