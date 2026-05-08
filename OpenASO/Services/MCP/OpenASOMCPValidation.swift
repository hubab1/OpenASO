import Foundation

enum OpenASOMCPValidation {
    static func storefront(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            throw OpenASOError.providerUnavailable("Storefront must be a non-empty country code.")
        }
        return normalized
    }

    static func storefronts(_ values: [String]?) throws -> [String] {
        guard let values, !values.isEmpty else { return [] }
        return Array(Set(try values.map(storefront))).sorted()
    }

    static func platform(_ value: String?) throws -> AppPlatform {
        guard let value else { return .iphone }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let platform = AppPlatform(rawValue: normalized) else {
            throw OpenASOError.providerUnavailable("Unsupported platform '\(value)'.")
        }
        return platform
    }

    static func appStoreID(_ value: Int64) throws -> Int64 {
        guard value > 0 else { throw OpenASOError.invalidAppStoreID }
        return value
    }

    static func keyword(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw OpenASOError.emptyQuery }
        return normalized
    }

    static func keywords(_ values: [String]) throws -> [String] {
        var seen = Set<String>()
        return try values.compactMap { value in
            let keyword = try keyword(value)
            guard seen.insert(keyword.lowercased()).inserted else { return nil }
            return keyword
        }
    }

    static func cappedLimit(_ value: Int?, default defaultValue: Int, maximum: Int) -> Int {
        min(max(value ?? defaultValue, 1), maximum)
    }

    static func offset(from cursor: String?) -> Int {
        guard
            let cursor,
            let offset = Int(cursor),
            offset > 0
        else {
            return 0
        }
        return offset
    }

    static func nextCursor(offset: Int, limit: Int, returnedCount: Int, totalCount: Int? = nil) -> String? {
        let nextOffset = offset + returnedCount
        if let totalCount {
            return nextOffset < totalCount ? String(nextOffset) : nil
        }
        return returnedCount == limit ? String(nextOffset) : nil
    }

    static func webURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = url.host
        else {
            throw OpenASOError.providerUnavailable("URL must be an absolute http or https URL.")
        }
        guard url.user == nil, url.password == nil else {
            throw OpenASOError.providerUnavailable("URL must not include credentials.")
        }
        guard !isBlockedNetworkHost(host) else {
            throw OpenASOError.providerUnavailable("URL must point to a public website.")
        }
        return url
    }

    static func existingDirectory(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenASOError.providerUnavailable("Destination directory must be a non-empty path.")
        }

        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OpenASOError.providerUnavailable("Destination directory does not exist: \(trimmed)")
        }
        return url
    }

    static func writableDirectory(_ path: String, createIfNeeded: Bool = false) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenASOError.providerUnavailable("Destination directory must be a non-empty path.")
        }

        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw OpenASOError.providerUnavailable("Destination path exists but is not a directory: \(trimmed)")
            }
        } else if createIfNeeded {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            throw OpenASOError.providerUnavailable("Destination directory does not exist: \(trimmed)")
        }

        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw OpenASOError.providerUnavailable("Destination directory is not writable: \(trimmed)")
        }
        return url
    }

    private static func isBlockedNetworkHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized.hasSuffix(".local") {
            return true
        }
        if normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" || normalized.hasPrefix("fe80:") || normalized.hasPrefix("fc") || normalized.hasPrefix("fd") {
            return true
        }

        let octets = normalized.split(separator: ".")
        if octets.count == 4, let first = Int(octets[0]), let second = Int(octets[1]) {
            if first == 0 || first == 10 || first == 127 { return true }
            if first == 169 && second == 254 { return true }
            if first == 172 && (16...31).contains(second) { return true }
            if first == 192 && second == 168 { return true }
        }
        return false
    }
}
