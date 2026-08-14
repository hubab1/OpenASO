import Testing
@testable import OpenASO

struct AppStoreIDInputParserTests {
    @Test
    func acceptsNumericAppStoreID() {
        #expect(AppStoreIDInputParser.appStoreID(from: "6793099062") == 6_793_099_062)
        #expect(AppStoreIDInputParser.appStoreID(from: " 6793099062\n") == 6_793_099_062)
    }

    @Test
    func extractsAppStoreIDFromMacAppURL() {
        let input = "https://apps.apple.com/in/app/viewio-app/id6793099062?mt=12"

        #expect(AppStoreIDInputParser.appStoreID(from: input) == 6_793_099_062)
    }

    @Test
    func extractsAppStoreIDFromSupportedAppStoreURLShapes() {
        #expect(
            AppStoreIDInputParser.appStoreID(
                from: "https://apps.apple.com/us/app/example/id1234567890/"
            ) == 1_234_567_890
        )
        #expect(
            AppStoreIDInputParser.appStoreID(
                from: "https://apps.apple.com/app/id1234567890#details"
            ) == 1_234_567_890
        )
    }

    @Test
    func rejectsInvalidOrUntrustedInput() {
        #expect(AppStoreIDInputParser.appStoreID(from: "") == nil)
        #expect(AppStoreIDInputParser.appStoreID(from: "0") == nil)
        #expect(AppStoreIDInputParser.appStoreID(from: "-1") == nil)
        #expect(AppStoreIDInputParser.appStoreID(from: "viewio") == nil)
        #expect(
            AppStoreIDInputParser.appStoreID(
                from: "https://example.com/in/app/viewio-app/id6793099062"
            ) == nil
        )
        #expect(
            AppStoreIDInputParser.appStoreID(
                from: "https://apps.apple.com.example.com/app/id6793099062"
            ) == nil
        )
        #expect(
            AppStoreIDInputParser.appStoreID(
                from: "https://apps.apple.com/app/id9223372036854775808"
            ) == nil
        )
    }
}
