import Foundation
import MCP
import SwiftData
import Testing
import Darwin
@testable import OpenASO

@MainActor
struct OpenASOMCPServerTests {
    @Test
    func serverExposesToolsResourcesPromptsAndReturnsJSONToolContent() async throws {
        let context = try ServerTestContext()
        try context.insertTrackedApp(appStoreID: 123, name: "Focus Timer")
        let server = await OpenASOMCPServerFactory(service: context.service).makeServer()
        let client = Client(name: "OpenASO MCP Test Client", version: "1.0")
        let transports = await InMemoryTransport.createConnectedPair()

        try await server.start(transport: transports.server)
        defer {
            Task {
                await client.disconnect()
                await server.stop()
            }
        }

        let initialize = try await client.connect(transport: transports.client)
        #expect(initialize.serverInfo.name == "OpenASO")
        #expect(initialize.capabilities.tools != nil)
        #expect(initialize.capabilities.resources != nil)
        #expect(initialize.capabilities.prompts != nil)

        let tools = try await client.listTools().tools
        #expect(tools.map(\.name).contains("list_apps"))
        #expect(tools.map(\.name).contains("fetch_website_markdown"))
        #expect(tools.map(\.name).contains("list_competitors"))
        #expect(tools.map(\.name).contains("score_keywords"))
        #expect(tools.map(\.name).contains("get_localization_research_context"))
        let rankingRefreshTool = try #require(tools.first { $0.name == "refresh_keyword_rankings" })
        let rankingRefreshDescription = try #require(rankingRefreshTool.description)
        #expect(rankingRefreshDescription.contains("defaults to 20"))
        #expect(rankingRefreshDescription.contains("1...25"))
        #expect(rankingRefreshDescription.contains("survives OpenASO relaunches"))

        let toolResult = try await client.callTool(
            name: "list_apps",
            arguments: [
                "limit": 10
            ]
        )
        #expect(toolResult.isError == nil)
        let toolJSON = try #require(toolResult.content.first?.textValue)
        let appPage = try JSONDecoder.openASOMCP.decode(OpenASOMCPPage<OpenASOMCPAppSummary>.self, from: Data(toolJSON.utf8))
        #expect(appPage.items.map(\.appStoreID) == ["123"])

        let resources = try await client.listResources().resources
        #expect(resources.map(\.uri).contains("openaso://workspace/summary"))
        let resourceContent = try await client.readResource(uri: "openaso://apps/123")
        let overviewJSON = try #require(resourceContent.first?.text)
        let overview = try JSONDecoder.openASOMCP.decode(OpenASOMCPAppOverview.self, from: Data(overviewJSON.utf8))
        #expect(overview.app.appStoreID == "123")

        let prompts = try await client.listPrompts().prompts
        let promptNames = prompts.map(\.name)
        #expect(promptNames.contains("review_theme_analysis"))
        #expect(promptNames.contains("keyword_research_brief"))
        #expect(promptNames.contains("competitor_landscape"))
        #expect(promptNames.contains("localization_opportunity_analysis"))
        #expect(promptNames.contains("aso_action_plan"))
        #expect(promptNames.contains("aso_audit_scorecard"))
        #expect(promptNames.contains("metadata_optimization_package"))
        #expect(promptNames.contains("screenshot_optimization_plan"))
        #expect(promptNames.contains("store_listing_test_plan"))

        let prompt = try await client.getPrompt(name: "aso_action_plan", arguments: ["appStoreID": "123"])
        #expect(prompt.messages.count == 1)
        #expect(String(describing: prompt.messages).contains("score_keywords"))
        #expect(String(describing: prompt.messages).contains("bounded follow-up tool calls"))
        #expect(String(describing: prompt.messages).contains("downloads"))
        let keywordPrompt = try await client.getPrompt(name: "keyword_research_brief", arguments: ["appStoreID": "123"])
        #expect(String(describing: keywordPrompt.messages).contains("verification_budget_exceeded"))
        #expect(String(describing: keywordPrompt.messages).contains("opportunity scoring"))
        let localizationPrompt = try await client.getPrompt(name: "localization_opportunity_analysis", arguments: ["appStoreID": "123"])
        #expect(String(describing: localizationPrompt.messages).contains("get_localization_research_context"))
        #expect(String(describing: localizationPrompt.messages).contains("OCR"))
        #expect(String(describing: localizationPrompt.messages).contains("market-specific research"))
        let auditPrompt = try await client.getPrompt(name: "aso_audit_scorecard", arguments: ["appStoreID": "123"])
        #expect(String(describing: auditPrompt.messages).contains("get_app_overview"))
        #expect(String(describing: auditPrompt.messages).contains("unsupported or missing data"))
        let metadataPrompt = try await client.getPrompt(name: "metadata_optimization_package", arguments: ["appStoreID": "123"])
        #expect(String(describing: metadataPrompt.messages).contains("30 characters"))
        #expect(String(describing: metadataPrompt.messages).contains("100"))
        #expect(String(describing: metadataPrompt.messages).contains("Avoid repeating keyword words"))
        let screenshotPrompt = try await client.getPrompt(name: "screenshot_optimization_plan", arguments: ["appStoreID": "123"])
        #expect(String(describing: screenshotPrompt.messages).contains("slot 1"))
        #expect(String(describing: screenshotPrompt.messages).contains("slots 2-3"))
        #expect(String(describing: screenshotPrompt.messages).contains("export_competitor_screenshots"))
        let testPlanPrompt = try await client.getPrompt(name: "store_listing_test_plan", arguments: ["appStoreID": "123"])
        #expect(String(describing: testPlanPrompt.messages).contains("PPO can test app icon"))
        #expect(String(describing: testPlanPrompt.messages).contains("conversion rate"))
    }

    @Test
    func serverExposesReadOnlyPricingToolAndReturnsStructuredNativePrices()
        async throws
    {
        let context = try ServerTestContext(httpHandler: { request in
            let url = try #require(request.url)
            #expect(url.host == "itunes.apple.com")
            return (
                Data(
                    """
                    {
                      "results": [
                        {
                          "trackId": 10,
                          "price": 0,
                          "formattedPrice": "Free",
                          "currency": "USD"
                        },
                        {
                          "trackId": 20,
                          "price": 2.99,
                          "formattedPrice": "$2.99",
                          "currency": "USD"
                        }
                      ]
                    }
                    """.utf8
                ),
                makeHTTPURLResponse(url: url, statusCode: 200)
            )
        })
        let server = await OpenASOMCPServerFactory(
            service: context.service
        ).makeServer()
        let client = Client(name: "OpenASO MCP Pricing Client", version: "1.0")
        let transports = await InMemoryTransport.createConnectedPair()

        try await server.start(transport: transports.server)
        defer {
            Task {
                await client.disconnect()
                await server.stop()
            }
        }

        _ = try await client.connect(transport: transports.client)
        let tools = try await client.listTools().tools
        let pricingTool = try #require(
            tools.first { $0.name == "compare_app_pricing" }
        )
        #expect(pricingTool.annotations.readOnlyHint == true)
        #expect(pricingTool.annotations.openWorldHint == true)
        #expect(pricingTool.description?.contains("1...10 apps") == true)
        #expect(pricingTool.description?.contains("five storefronts") == true)

        let result = try await client.callTool(
            name: "compare_app_pricing",
            arguments: [
                "appStoreIDs": [10, 20],
                "storefronts": ["us"],
                "platform": "iphone",
            ]
        )

        #expect(result.isError == nil)
        let json = try #require(result.content.first?.textValue)
        let comparison = try JSONDecoder.openASOMCP.decode(
            OpenASOMCPAppPricingComparison.self,
            from: Data(json.utf8)
        )
        #expect(comparison.appStoreIDs == ["10", "20"])
        #expect(comparison.storefronts == ["us"])
        #expect(comparison.basePrices.map(\.kind) == ["free", "paid"])
        #expect(comparison.basePrices.map(\.displayPrice) == ["Free", "$2.99"])
        #expect(comparison.visibleProducts.isEmpty)
        #expect(comparison.failures.isEmpty)
    }

    @Test
    func historyToolsAreReadOnlyAndReturnFilteredAndSeededPages() async throws {
        let context = try ServerTestContext()
        try context.insertTrackedApp(appStoreID: 123, name: "Focus Timer")
        let fixtures = try context.insertHistoryFixtures(appStoreID: 123)
        let server = await OpenASOMCPServerFactory(service: context.service).makeServer()
        let client = Client(name: "OpenASO MCP History Test Client", version: "1.0")
        let transports = await InMemoryTransport.createConnectedPair()

        try await server.start(transport: transports.server)
        defer {
            Task {
                await client.disconnect()
                await server.stop()
            }
        }

        _ = try await client.connect(transport: transports.client)
        let tools = try await client.listTools().tools
        let historyToolNames = [
            "list_keyword_ranking_history",
            "list_keyword_ranking_results",
            "list_rating_history",
        ]
        for name in historyToolNames {
            let tool = try #require(tools.first { $0.name == name })
            #expect(tool.annotations.readOnlyHint == true)
        }

        let rankingHistoryResult = try await client.callTool(
            name: "list_keyword_ranking_history",
            arguments: [
                "appStoreID": 123,
                "storefronts": ["us"],
                "platform": "iphone",
                "keyword": "focus timer",
                "track_identity_key": "123|us|iphone|focus timer",
                "query_key": "us|iphone|focus timer",
                "date_from": "2026-05-01T00:00:00Z",
                "date_to": "2026-05-07T12:00:00Z",
                "result_limit": 5,
                "limit": 2,
            ]
        )
        #expect(rankingHistoryResult.isError == nil)
        let rankingHistoryJSON = try #require(rankingHistoryResult.content.first?.textValue)
        let rankingHistoryPage = try JSONDecoder.openASOMCP.decode(
            OpenASOMCPPage<OpenASOMCPTrackedRankingSnapshot>.self,
            from: Data(rankingHistoryJSON.utf8)
        )
        #expect(rankingHistoryPage.items.isEmpty)
        #expect(rankingHistoryPage.nextCursor == nil)
        #expect(rankingHistoryPage.total == 0)

        let rankingResultsResult = try await client.callTool(
            name: "list_keyword_ranking_results",
            arguments: [
                "appStoreID": 123,
                "storefronts": ["gb"],
                "platform": "ipad",
                "keyword": "productivity timer",
                "track_identity_key": "123|gb|ipad|productivity timer",
                "query_key": "gb|ipad|productivity timer",
                "date_from": "2026-04-01T00:00:00.000Z",
                "date_to": "2026-05-07T12:00:00.000Z",
                "result_limit": 10,
                "limit": 3,
            ]
        )
        #expect(rankingResultsResult.isError == nil)
        let rankingResultsJSON = try #require(rankingResultsResult.content.first?.textValue)
        let rankingResultsPage = try JSONDecoder.openASOMCP.decode(
            OpenASOMCPPage<OpenASOMCPRankingCrawlSnapshot>.self,
            from: Data(rankingResultsJSON.utf8)
        )
        #expect(rankingResultsPage.items.isEmpty)
        #expect(rankingResultsPage.nextCursor == nil)
        #expect(rankingResultsPage.total == 0)

        let ratingHistoryResult = try await client.callTool(
            name: "list_rating_history",
            arguments: [
                "appStoreID": 123,
                "storefronts": ["ca"],
                "date_from": "2026-01-01T00:00:00Z",
                "date_to": "2026-05-07T12:00:00Z",
                "limit": 4,
            ]
        )
        #expect(ratingHistoryResult.isError == nil)
        let ratingHistoryJSON = try #require(ratingHistoryResult.content.first?.textValue)
        let ratingHistoryPage = try JSONDecoder.openASOMCP.decode(
            OpenASOMCPPage<OpenASOMCPRatingSnapshot>.self,
            from: Data(ratingHistoryJSON.utf8)
        )
        #expect(ratingHistoryPage.items.isEmpty)
        #expect(ratingHistoryPage.nextCursor == nil)
        #expect(ratingHistoryPage.total == 0)

        let firstRankingHistoryResult = try await client.callTool(
            name: "list_keyword_ranking_history",
            arguments: [
                "appStoreID": .int(123),
                "track_identity_key": .string(fixtures.trackIdentityKey),
                "query_key": .string(fixtures.queryKey),
                "result_limit": .int(1),
                "limit": .int(1),
            ]
        )
        #expect(firstRankingHistoryResult.isError == nil)
        let firstRankingHistoryJSON = try #require(firstRankingHistoryResult.content.first?.textValue)
        let firstRankingHistoryPage = try JSONDecoder.openASOMCP.decode(
            OpenASOMCPPage<OpenASOMCPTrackedRankingSnapshot>.self,
            from: Data(firstRankingHistoryJSON.utf8)
        )
        #expect(firstRankingHistoryPage.items.map { $0.snapshotKey } == [fixtures.rankingSnapshotKeys[0]])
        #expect(firstRankingHistoryPage.items.first?.rankedApps.map { $0.appStoreID } == ["321"])
        #expect(firstRankingHistoryPage.total == 2)
        let rankingHistoryCursor = try #require(firstRankingHistoryPage.nextCursor)

        let secondRankingHistoryResult = try await client.callTool(
            name: "list_keyword_ranking_history",
            arguments: [
                "appStoreID": .int(123),
                "track_identity_key": .string(fixtures.trackIdentityKey),
                "query_key": .string(fixtures.queryKey),
                "result_limit": .int(1),
                "limit": .int(1),
                "cursor": .string(rankingHistoryCursor),
            ]
        )
        #expect(secondRankingHistoryResult.isError == nil)
        let secondRankingHistoryJSON = try #require(secondRankingHistoryResult.content.first?.textValue)
        let secondRankingHistoryPage = try JSONDecoder.openASOMCP.decode(
            OpenASOMCPPage<OpenASOMCPTrackedRankingSnapshot>.self,
            from: Data(secondRankingHistoryJSON.utf8)
        )
        #expect(secondRankingHistoryPage.items.map { $0.snapshotKey } == [fixtures.rankingSnapshotKeys[1]])
        #expect(secondRankingHistoryPage.nextCursor == nil)

        let positiveRankingResultsResult = try await client.callTool(
            name: "list_keyword_ranking_results",
            arguments: [
                "appStoreID": .int(123),
                "query_key": .string(fixtures.queryKey),
                "result_limit": .int(1),
                "limit": .int(10),
            ]
        )
        #expect(positiveRankingResultsResult.isError == nil)
        let positiveRankingResultsJSON = try #require(positiveRankingResultsResult.content.first?.textValue)
        let positiveRankingResultsPage = try JSONDecoder.openASOMCP.decode(
            OpenASOMCPPage<OpenASOMCPRankingCrawlSnapshot>.self,
            from: Data(positiveRankingResultsJSON.utf8)
        )
        #expect(positiveRankingResultsPage.items.map { $0.observationKey } == [fixtures.rankingCrawlKey])
        #expect(positiveRankingResultsPage.items.first?.rankedApps.map { $0.appStoreID } == ["456"])

        let positiveRatingHistoryResult = try await client.callTool(
            name: "list_rating_history",
            arguments: [
                "appStoreID": .int(123),
                "storefronts": .array([.string("us")]),
                "limit": .int(10),
            ]
        )
        #expect(positiveRatingHistoryResult.isError == nil)
        let positiveRatingHistoryJSON = try #require(positiveRatingHistoryResult.content.first?.textValue)
        let positiveRatingHistoryPage = try JSONDecoder.openASOMCP.decode(
            OpenASOMCPPage<OpenASOMCPRatingSnapshot>.self,
            from: Data(positiveRatingHistoryJSON.utf8)
        )
        #expect(positiveRatingHistoryPage.items.map { $0.identityKey } == [fixtures.ratingIdentityKey])
        #expect(positiveRatingHistoryPage.items.first?.ratingCount == 42)
    }

    @Test
    func historyDispatchRejectsPresentWrongTypedOptionalArguments() async throws {
        let context = try ServerTestContext()
        try context.insertTrackedApp(appStoreID: 123, name: "Focus Timer")
        let server = await OpenASOMCPServerFactory(service: context.service).makeServer()
        let client = Client(name: "OpenASO MCP History Validation Client", version: "1.0")
        let transports = await InMemoryTransport.createConnectedPair()

        try await server.start(transport: transports.server)
        defer {
            Task {
                await client.disconnect()
                await server.stop()
            }
        }

        _ = try await client.connect(transport: transports.client)
        let invalidCalls: [(tool: String, arguments: [String: MCP.Value])] = [
            (
                "list_keyword_ranking_history",
                ["appStoreID": 123, "platform": .int(7)]
            ),
            (
                "list_keyword_ranking_results",
                ["appStoreID": 123, "result_limit": .string("10")]
            ),
            (
                "list_rating_history",
                ["appStoreID": 123, "storefronts": .array([.string("us"), .int(7)])]
            ),
            (
                "list_rating_history",
                ["appStoreID": 123, "date_from": .int(0)]
            ),
        ]

        for invalidCall in invalidCalls {
            await #expect(throws: MCPError.self) {
                _ = try await client.callTool(
                    name: invalidCall.tool,
                    arguments: invalidCall.arguments
                )
            }
        }
    }

    @Test
    func controllerStartsLocalHTTPServerAndReturnsInitializeResponse() async throws {
        let context = try ServerTestContext()
        try context.insertTrackedApp(appStoreID: 123, name: "Focus Timer")
        let port = try availableLoopbackPort()
        let factoryRecorder = MCPServerFactoryRecorder()
        let controller = OpenASOMCPServerController(portProvider: { port }) {
            factoryRecorder.recordInvocation()
            return await OpenASOMCPServerFactory(service: context.service).makeServer()
        }

        controller.start()
        defer {
            controller.stop()
        }

        let endpointURL = try await waitForEndpointURL(controller)
        #expect(endpointURL.port == port)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"http-test","version":"1.0"}}}
        """.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        let sessionID = try #require(httpResponse.value(forHTTPHeaderField: "MCP-Session-Id"))
        #expect(factoryRecorder.invocationCount == 1)

        let json = try jsonRPCObject(from: data)
        let result = try #require(json["result"] as? [String: Any])
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "OpenASO")

        request.httpBody = Data("""
        {"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"second-http-test","version":"1.0"}}}
        """.utf8)

        let (secondInitializeData, secondInitializeResponse) = try await URLSession.shared.data(for: request)
        let secondInitializeHTTPResponse = try #require(secondInitializeResponse as? HTTPURLResponse)
        #expect(secondInitializeHTTPResponse.statusCode == 200)
        #expect(secondInitializeHTTPResponse.value(forHTTPHeaderField: "MCP-Session-Id") != sessionID)
        #expect(factoryRecorder.invocationCount == 2)

        let secondInitializeJSON = try jsonRPCObject(from: secondInitializeData)
        #expect(secondInitializeJSON["error"] == nil)
        let secondInitializeResult = try #require(secondInitializeJSON["result"] as? [String: Any])
        let secondInitializeServerInfo = try #require(secondInitializeResult["serverInfo"] as? [String: Any])
        #expect(secondInitializeServerInfo["name"] as? String == "OpenASO")

        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        request.httpBody = Data("""
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_apps","arguments":{"limit":10}}}
        """.utf8)

        let (toolData, toolResponse) = try await URLSession.shared.data(for: request)
        let toolHTTPResponse = try #require(toolResponse as? HTTPURLResponse)
        #expect(toolHTTPResponse.statusCode == 200)

        let toolJSON = try jsonRPCObject(from: toolData)
        let toolResult = try #require(toolJSON["result"] as? [String: Any])
        let structuredContent = try #require(toolResult["structuredContent"] as? [String: Any])
        let items = try #require(structuredContent["items"] as? [[String: Any]])
        #expect(items.first?["lastMetadataRefreshAt"] as? String == "2026-05-01T00:00:00Z")
        #expect(factoryRecorder.invocationCount == 2)
    }

    @Test
    func controllerRejectsRequestsOutsideExactMCPPathWithoutCreatingServer() async throws {
        let context = try ServerTestContext()
        let port = try availableLoopbackPort()
        let factoryRecorder = MCPServerFactoryRecorder()
        let controller = OpenASOMCPServerController(portProvider: { port }) {
            factoryRecorder.recordInvocation()
            return await OpenASOMCPServerFactory(service: context.service).makeServer()
        }

        controller.start()
        defer {
            controller.stop()
        }

        let endpointURL = try await waitForEndpointURL(controller)
        let initializeBody = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"rejected-route-test","version":"1.0"}}}
        """.utf8)
        let rejectedTargets: [(method: String, path: String, percentEncodedQuery: String?, body: Data?)] = [
            ("POST", "/", nil, initializeBody),
            ("GET", "/.well-known/oauth-protected-resource", nil, nil),
            ("GET", "/.well-known/oauth-protected-resource/mcp", nil, nil),
            ("GET", "/.well-known/oauth-authorization-server", nil, nil),
            ("POST", "/mcp/", nil, initializeBody),
            ("POST", "/mcp", "probe=1", initializeBody),
        ]

        for target in rejectedTargets {
            var components = try #require(URLComponents(url: endpointURL, resolvingAgainstBaseURL: false))
            components.path = target.path
            components.percentEncodedQuery = target.percentEncodedQuery
            let requestURL = try #require(components.url)

            var request = URLRequest(url: requestURL)
            request.httpMethod = target.method
            request.httpBody = target.body
            if target.body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            }

            let (_, response) = try await URLSession.shared.data(for: request)
            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(
                httpResponse.statusCode == 404,
                "Expected exact-path routing to reject \(requestURL.absoluteString)"
            )
            #expect(httpResponse.value(forHTTPHeaderField: "MCP-Session-Id") == nil)
            #expect(factoryRecorder.invocationCount == 0)
        }
    }

    @Test
    func controllerReportsInvalidConfiguredPort() async throws {
        let context = try ServerTestContext()
        let controller = OpenASOMCPServerController(portProvider: { 0 }) {
            await OpenASOMCPServerFactory(service: context.service).makeServer()
        }

        controller.start()

        let message = try await waitForFailureMessage(controller)
        #expect(message.contains("port 0"))
        #expect(message.contains("supported port range"))
    }
}

@MainActor
private final class MCPServerFactoryRecorder {
    private(set) var invocationCount = 0

    func recordInvocation() {
        invocationCount += 1
    }
}

@MainActor
private func waitForEndpointURL(_ controller: OpenASOMCPServerController) async throws -> URL {
    for _ in 0..<50 {
        if let endpointURL = controller.state.endpointURL {
            return endpointURL
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    Issue.record("Timed out waiting for MCP local HTTP server to start")
    throw OpenASOError.providerUnavailable("Timed out waiting for MCP local HTTP server to start")
}

@MainActor
private func waitForFailureMessage(_ controller: OpenASOMCPServerController) async throws -> String {
    for _ in 0..<50 {
        if case .failed(let message) = controller.state {
            return message
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    Issue.record("Timed out waiting for MCP local HTTP server to fail")
    throw OpenASOError.providerUnavailable("Timed out waiting for MCP local HTTP server to fail")
}

private func jsonRPCObject(from data: Data) throws -> [String: Any] {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return object
    }

    guard let text = String(data: data, encoding: .utf8) else {
        Issue.record("MCP response was not UTF-8")
        throw OpenASOError.providerUnavailable("MCP response was not UTF-8")
    }

    for line in text.components(separatedBy: .newlines) {
        guard line.hasPrefix("data:") else {
            continue
        }

        let payload = line
            .dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        else {
            continue
        }

        return object
    }

    Issue.record("MCP response did not contain a JSON-RPC object")
    throw OpenASOError.providerUnavailable("MCP response did not contain a JSON-RPC object")
}

private func availableLoopbackPort() throws -> Int {
    let fileDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fileDescriptor >= 0 else {
        throw OpenASOError.providerUnavailable("Could not create a TCP socket for test port allocation.")
    }
    defer {
        close(fileDescriptor)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw OpenASOError.providerUnavailable("Could not bind a TCP socket for test port allocation.")
    }

    var boundAddress = sockaddr_in()
    var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            getsockname(fileDescriptor, sockaddrPointer, &boundAddressLength)
        }
    }
    guard nameResult == 0 else {
        throw OpenASOError.providerUnavailable("Could not read the allocated test TCP port.")
    }

    return Int(UInt16(bigEndian: boundAddress.sin_port))
}

private struct ServerTestContext {
    let container: ModelContainer
    let modelContext: ModelContext
    let service: OpenASOMCPService

    @MainActor
    init(
        httpHandler: @escaping (URLRequest) throws -> (Data, URLResponse) = {
            request in
            (
                Data(),
                makeHTTPURLResponse(url: request.url!, statusCode: 200)
            )
        }
    ) throws {
        container = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        modelContext = ModelContext(container)
        let backgroundModelStore = BackgroundModelStore(modelContainer: container)
        let resolver = ServerStubAppResolver()
        let httpClient = MockHTTPClient(handler: httpHandler)
        service = OpenASOMCPService(
            backgroundModelStore: backgroundModelStore,
            appResolver: resolver,
            appCatalogService: AppCatalogService(appResolver: resolver),
            httpClient: httpClient,
            now: { ISO8601DateFormatter().date(from: "2026-05-07T12:00:00Z")! }
        )
    }

    func insertTrackedApp(appStoreID: Int64, name: String) throws {
        let storeApp = StoreApp(
            appStoreID: appStoreID,
            bundleID: "com.example.\(appStoreID)",
            name: name,
            sellerName: "Example Seller",
            iconURLString: nil,
            defaultPlatform: .iphone,
            lastMetadataRefreshAt: ISO8601DateFormatter().date(from: "2026-05-01T00:00:00Z")!
        )
        let trackedApp = TrackedApp(appStoreID: appStoreID, storeApp: storeApp)
        modelContext.insert(storeApp)
        modelContext.insert(trackedApp)
        try modelContext.save()
    }

    func insertHistoryFixtures(appStoreID: Int64) throws -> ServerHistoryFixtures {
        let trackedApp = try #require(modelContext.fetch(FetchDescriptor<TrackedApp>(
            predicate: #Predicate { app in
                app.appStoreID == appStoreID
            }
        )).first)
        let query = try KeywordQuery.fetchOrInsert(
            term: "focus timer",
            storefront: "us",
            platform: .iphone,
            in: modelContext
        )
        let track = TrackedAppKeyword(
            term: "focus timer",
            storefront: "us",
            platform: .iphone,
            trackedApp: trackedApp,
            query: query
        )
        trackedApp.keywordTracks.append(track)
        modelContext.insert(track)

        let newerSnapshot = TrackedKeywordDailyRanking(
            rank: 3,
            searchedAt: ISO8601DateFormatter().date(from: "2026-05-06T10:00:00Z")!,
            source: .appStoreWeb,
            resultCount: 20,
            keywordTrack: track
        )
        let newerResult = TrackedKeywordRankedResult(
            position: 1,
            appStoreID: 321,
            bundleID: "com.example.321",
            name: "Ranked App",
            sellerName: "Example Seller",
            snapshot: newerSnapshot
        )
        newerSnapshot.topResults.append(newerResult)
        track.snapshots.append(newerSnapshot)
        modelContext.insert(newerSnapshot)
        modelContext.insert(newerResult)

        let olderSnapshot = TrackedKeywordDailyRanking(
            rank: 5,
            searchedAt: ISO8601DateFormatter().date(from: "2026-05-05T10:00:00Z")!,
            source: .iTunesFallback,
            resultCount: 20,
            keywordTrack: track
        )
        track.snapshots.append(olderSnapshot)
        modelContext.insert(olderSnapshot)

        let crawl = KeywordRankingCrawl(
            keyword: track.term,
            storefront: track.storefront,
            platform: track.platform,
            observedAt: ISO8601DateFormatter().date(from: "2026-05-06T11:00:00Z")!,
            source: .appStoreWeb,
            resultCount: 1,
            query: query
        )
        let crawlItem = KeywordAppRanking(
            position: 1,
            appStoreID: 456,
            bundleID: "com.example.456",
            name: "Crawl App",
            sellerName: "Example Seller",
            observation: crawl
        )
        crawl.items.append(crawlItem)
        modelContext.insert(crawl)
        modelContext.insert(crawlItem)

        let rating = AppDailyRating(
            appStoreID: appStoreID,
            storefront: "us",
            ratingCount: 42,
            averageRating: 4.5,
            ratingDate: "2026-05-06",
            observedAt: ISO8601DateFormatter().date(from: "2026-05-06T12:00:00Z")!,
            source: .appStorePage,
            storeApp: trackedApp.storeApp
        )
        modelContext.insert(rating)
        try modelContext.save()

        return ServerHistoryFixtures(
            trackIdentityKey: track.identityKey,
            queryKey: track.queryKey,
            rankingSnapshotKeys: [newerSnapshot.snapshotKey, olderSnapshot.snapshotKey],
            rankingCrawlKey: crawl.observationKey,
            ratingIdentityKey: rating.identityKey
        )
    }
}

private struct ServerHistoryFixtures {
    let trackIdentityKey: String
    let queryKey: String
    let rankingSnapshotKeys: [String]
    let rankingCrawlKey: String
    let ratingIdentityKey: String
}

private struct ServerStubAppResolver: AppResolver {
    func resolve(appStoreID: Int64, storefrontCode: String) async throws -> ResolvedApp {
        ResolvedApp(
            appStoreID: appStoreID,
            bundleID: "com.example.\(appStoreID)",
            name: "Resolved \(appStoreID)",
            sellerName: "Example Seller",
            defaultPlatform: .iphone
        )
    }

    func searchApps(named query: String, storefrontCode: String, limit: Int) async throws -> [ResolvedApp] {
        []
    }
}

private extension Tool.Content {
    var textValue: String? {
        if case .text(let text, _, _) = self {
            return text
        }
        return nil
    }
}

private extension JSONDecoder {
    static var openASOMCP: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
