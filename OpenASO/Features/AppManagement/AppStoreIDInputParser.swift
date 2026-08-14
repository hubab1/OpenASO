import Foundation

enum AppStoreIDInputParser {
    static func appStoreID(from input: String) -> Int64? {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let appStoreID = positiveAppStoreID(from: trimmedInput) {
            return appStoreID
        }

        guard let components = URLComponents(string: trimmedInput),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "apps.apple.com"
        else {
            return nil
        }

        for pathComponent in components.path.split(separator: "/").reversed() {
            guard pathComponent.hasPrefix("id") else { continue }

            let appStoreIDText = String(pathComponent.dropFirst(2))
            if let appStoreID = positiveAppStoreID(from: appStoreIDText) {
                return appStoreID
            }
        }

        return nil
    }

    private static func positiveAppStoreID(from text: String) -> Int64? {
        guard !text.isEmpty,
              text.allSatisfy(\.isNumber),
              let appStoreID = Int64(text),
              appStoreID > 0
        else {
            return nil
        }

        return appStoreID
    }
}
