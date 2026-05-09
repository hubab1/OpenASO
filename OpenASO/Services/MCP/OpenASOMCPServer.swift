import Foundation
import MCP

struct OpenASOMCPServerConfiguration: Sendable {
    let name: String
    let version: String
    let instructions: String

    init(
        name: String = "OpenASO",
        version: String = "0.1.0",
        instructions: String = "Use OpenASO as the evidence layer for ASO work: gather local and live app metadata, rankings, keyword metrics, reviews, screenshots, competitors, freshness warnings, and localization context through tools before recommending actions. Keep refreshes bounded, continue with partial results when providers cap or fail, and label unsupported or missing data such as downloads, revenue, conversion rate, hidden keyword fields, paid campaign performance, and exact App Store Connect analytics instead of inventing it."
    ) {
        self.name = name
        self.version = version
        self.instructions = instructions
    }
}

struct OpenASOMCPServerFactory: Sendable {
    let service: OpenASOMCPService
    let configuration: OpenASOMCPServerConfiguration

    init(
        service: OpenASOMCPService,
        configuration: OpenASOMCPServerConfiguration = OpenASOMCPServerConfiguration()
    ) {
        self.service = service
        self.configuration = configuration
    }

    func makeServer() async -> Server {
        let server = Server(
            name: configuration.name,
            version: configuration.version,
            instructions: configuration.instructions,
            capabilities: .init(
                prompts: .init(listChanged: true),
                resources: .init(subscribe: false, listChanged: true),
                tools: .init(listChanged: true)
            )
        )

        await registerTools(on: server)
        await registerResources(on: server)
        await registerPrompts(on: server)
        return server
    }

    private func registerTools(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.tools)
        }

        await server.withMethodHandler(CallTool.self) { parameters in
            try await callTool(parameters)
        }
    }

    private func registerResources(on server: Server) async {
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: Self.resources)
        }

        await server.withMethodHandler(ReadResource.self) { parameters -> ReadResource.Result in
            switch parameters.uri {
            case "openaso://workspace/summary":
                let apps = try await service.listApps()
                return try Self.resourceResult(
                    uri: parameters.uri,
                    value: OpenASOMCPWorkspaceSummaryResource(
                        trackedAppCount: apps.total ?? apps.items.count,
                        apps: apps
                    )
                )
            case "openaso://apps":
                let apps = try await service.listApps()
                return try Self.resourceResult(uri: parameters.uri, value: apps)
            default:
                return try await readAppResource(uri: parameters.uri)
            }
        }
    }

    private func readAppResource(uri: String) async throws -> ReadResource.Result {
        guard
            let resource = OpenASOMCPAppResource(uri: uri)
        else {
            throw MCPError.invalidParams("Unsupported resource URI: \(uri)")
        }

        switch resource.kind {
        case .overview:
            let overview = try await service.getAppOverview(appStoreID: resource.appStoreID)
            return try Self.resourceResult(uri: uri, value: overview)
        case .reviews:
            let reviews = try await service.listReviews(
                appStoreID: resource.appStoreID,
                page: .init(limit: 50, cursor: nil)
            )
            return try Self.resourceResult(uri: uri, value: reviews)
        case .keywords:
            let keywords = try await service.listKeywords(
                appStoreID: resource.appStoreID,
                page: .init(limit: 100, cursor: nil)
            )
            return try Self.resourceResult(uri: uri, value: keywords)
        case .screenshots:
            let screenshots = try await service.listScreenshots(
                appStoreID: resource.appStoreID,
                page: .init(limit: 100, cursor: nil)
            )
            return try Self.resourceResult(uri: uri, value: screenshots)
        case .competitors:
            let competitors = try await service.listCompetitors(
                appStoreID: resource.appStoreID,
                limit: 25,
                lookbackDays: 180
            )
            return try Self.resourceResult(uri: uri, value: competitors)
        }
    }

    private func registerPrompts(on server: Server) async {
        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(prompts: Self.prompts)
        }

        await server.withMethodHandler(GetPrompt.self) { parameters in
            guard let template = Self.promptTemplate(named: parameters.name, arguments: parameters.arguments) else {
                throw MCPError.invalidParams("Unknown prompt: \(parameters.name)")
            }
            return template
        }
    }

    private func callTool(_ parameters: CallTool.Parameters) async throws -> CallTool.Result {
        let arguments = parameters.arguments ?? [:]
        switch parameters.name {
        case "list_apps":
            let result = try await service.listApps(
                includeUntrackedCatalogApps: arguments.bool("include_untracked_catalog_apps") ?? false,
                folder: arguments.string("folder"),
                page: .init(limit: arguments.int("limit"), cursor: arguments.string("cursor"))
            )
            return try Self.toolResult(result)

        case "search_app_store_apps":
            let result = try await service.searchAppStoreApps(
                query: try arguments.requiredString("query"),
                storefront: arguments.string("storefront") ?? "us",
                limit: arguments.int("limit")
            )
            return try Self.toolResult(result)

        case "detect_app":
            let result = try await service.detectApp(
                query: try arguments.requiredString("query"),
                storefront: arguments.string("storefront") ?? "us",
                limit: arguments.int("limit")
            )
            return try Self.toolResult(result)

        case "add_tracked_app":
            let result = try await service.addTrackedApp(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefront: arguments.string("storefront") ?? "us"
            )
            return try Self.toolResult(result)

        case "get_app_overview":
            let result = try await service.getAppOverview(appStoreID: try arguments.requiredInt64("appStoreID"))
            return try Self.toolResult(result)

        case "list_reviews":
            let result = try await service.listReviews(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                ratingMin: arguments.int("rating_min"),
                ratingMax: arguments.int("rating_max"),
                version: arguments.string("version"),
                dateFrom: try arguments.date("date_from"),
                dateTo: try arguments.date("date_to"),
                page: .init(limit: arguments.int("limit"), cursor: arguments.string("cursor"))
            )
            return try Self.toolResult(result)

        case "list_keywords":
            let result = try await service.listKeywords(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                platform: arguments.string("platform"),
                page: .init(limit: arguments.int("limit"), cursor: arguments.string("cursor"))
            )
            return try Self.toolResult(result)

        case "score_keywords":
            let result = try await service.scoreKeywords(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                platform: arguments.string("platform")
            )
            return try Self.toolResult(result)

        case "add_keywords":
            let result = try await service.addKeywords(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                keywords: try arguments.requiredStringArray("keywords"),
                storefronts: try arguments.requiredStringArray("storefronts"),
                platform: arguments.string("platform")
            )
            return try Self.toolResult(result)

        case "update_keyword_notes":
            let result = try await service.updateKeywordNotes(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                keyword: try arguments.requiredString("keyword"),
                storefront: try arguments.requiredString("storefront"),
                platform: arguments.string("platform"),
                notes: try arguments.requiredString("notes")
            )
            return try Self.toolResult(result)

        case "list_screenshots":
            let result = try await service.listScreenshots(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                platform: arguments.string("platform"),
                page: .init(limit: arguments.int("limit"), cursor: arguments.string("cursor"))
            )
            return try Self.toolResult(result)

        case "export_screenshots":
            let result = try await service.exportScreenshots(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                platform: arguments.string("platform"),
                destinationDirectoryPath: try arguments.requiredString("destination_directory_path")
            )
            return try Self.toolResult(result)

        case "fetch_website_markdown":
            let result = try await service.fetchWebsiteMarkdown(urlString: try arguments.requiredString("url"))
            return try Self.toolResult(result)

        case "fetch_app_website_markdown":
            let result = try await service.fetchAppWebsiteMarkdown(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefront: arguments.string("storefront") ?? "us"
            )
            return try Self.toolResult(result)

        case "list_competitors":
            let result = try await service.listCompetitors(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                platform: arguments.string("platform"),
                limit: arguments.int("limit"),
                lookbackDays: arguments.int("lookback_days") ?? 180,
                evidenceLimit: arguments.int("evidence_limit")
            )
            return try Self.toolResult(result)

        case "get_ranked_apps_for_keyword":
            let result = try await service.getRankedAppsForKeyword(
                keyword: try arguments.requiredString("keyword"),
                storefront: arguments.string("storefront") ?? "us",
                platform: arguments.string("platform"),
                targetAppStoreID: arguments.int("target_app_store_id").map(Int64.init),
                limit: arguments.int("limit")
            )
            return try Self.toolResult(result)

        case "suggest_keywords":
            let result = try await service.suggestKeywords(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                platform: arguments.string("platform"),
                limit: arguments.int("limit"),
                websiteMarkdown: arguments.string("website_markdown")
            )
            return try Self.toolResult(result)

        case "refresh_keyword_rankings":
            let result = try await service.refreshKeywordRankings(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                platform: arguments.string("platform"),
                limit: arguments.int("limit")
            )
            return try Self.toolResult(result)

        case "refresh_keyword_metrics":
            let result = try await service.refreshKeywordMetrics(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                platform: arguments.string("platform")
            )
            return try Self.toolResult(result)

        case "refresh_reviews":
            let result = try await service.refreshReviews(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                limitPerStorefront: arguments.int("limit_per_storefront") ?? arguments.int("limit")
            )
            return try Self.toolResult(result)

        case "download_all_reviews":
            let result = try await service.downloadAllReviews(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                batchPageCount: arguments.int("batch_page_count")
            )
            return try Self.toolResult(result)

        case "discover_keyword_landscape":
            let result = try await service.discoverKeywordLandscape(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                platform: arguments.string("platform"),
                keywordLimit: arguments.int("keyword_limit"),
                competitorLimit: arguments.int("competitor_limit"),
                reviewsPerStorefront: arguments.int("reviews_per_storefront") ?? arguments.int("reviews_per_competitor"),
                includeReviews: arguments.bool("include_reviews") ?? true,
                websiteMarkdown: arguments.string("website_markdown")
            )
            return try Self.toolResult(result)

        case "refresh_competitor_reviews":
            let result = try await service.refreshCompetitorReviews(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                platform: arguments.string("platform"),
                competitorLimit: arguments.int("competitor_limit"),
                reviewsPerStorefront: arguments.int("reviews_per_storefront") ?? arguments.int("reviews_per_competitor")
            )
            return try Self.toolResult(result)

        case "export_competitor_screenshots":
            let result = try await service.exportCompetitorScreenshots(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                platform: arguments.string("platform"),
                competitorLimit: arguments.int("competitor_limit"),
                destinationDirectoryPath: try arguments.requiredString("destination_directory_path")
            )
            return try Self.toolResult(result)

        case "get_localization_research_context":
            let result = try await service.getLocalizationResearchContext(
                appStoreID: try arguments.requiredInt64("appStoreID"),
                storefronts: arguments.stringArray("storefronts"),
                platform: arguments.string("platform"),
                competitorLimit: arguments.int("competitor_limit"),
                includeTargetApp: arguments.bool("include_target_app") ?? true,
                refreshMissingMetadata: arguments.bool("refresh_missing_metadata") ?? true,
                destinationDirectoryPath: arguments.string("destination_directory_path")
            )
            return try Self.toolResult(result)

        default:
            throw MCPError.invalidParams("Unknown tool: \(parameters.name)")
        }
    }
}

private extension OpenASOMCPServerFactory {
    static let jsonMimeType = "application/json"

    static func toolResult<T: Codable>(_ value: T) throws -> CallTool.Result {
        let json = try jsonString(value)
        let structuredContent = try structuredValue(value)
        return CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: Optional<MCP.Value>.some(structuredContent)
        )
    }

    static func resourceResult<T: Codable>(uri: String, value: T) throws -> ReadResource.Result {
        ReadResource.Result(contents: [
            .text(try jsonString(value), uri: uri, mimeType: jsonMimeType)
        ])
    }

    static func jsonString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try jsonData(value), as: UTF8.self)
    }

    static func structuredValue<T: Encodable>(_ value: T) throws -> MCP.Value {
        try JSONDecoder().decode(MCP.Value.self, from: jsonData(value))
    }

    static func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static var tools: [Tool] {
        [
            tool("list_apps", "List tracked apps and optionally untracked catalog apps.", schema(
                optional: [
                    "include_untracked_catalog_apps": .boolean,
                    "folder": .string,
                    "limit": .integer,
                    "cursor": .string
                ]
            ), readOnly: true),
            tool("search_app_store_apps", "Search the App Store without tracking the result.", schema(
                required: ["query"],
                optional: ["query": .string, "storefront": .string, "limit": .integer]
            ), readOnly: true, openWorld: true),
            tool("detect_app", "Resolve an app name, App Store URL, or app ID into onboarding candidates and a confirmation prompt.", schema(
                required: ["query"],
                optional: ["query": .string, "storefront": .string, "limit": .integer]
            ), readOnly: true, openWorld: true),
            tool("add_tracked_app", "Resolve App Store metadata and create or update a tracked app.", schema(
                required: ["appStoreID"],
                optional: ["appStoreID": .integer, "storefront": .string]
            ), readOnly: false, destructive: false, idempotent: false, openWorld: true),
            tool("get_app_overview", "Get catalog metadata, ratings, reviews, keywords, screenshots, and competitor evidence.", appIDSchema, readOnly: true),
            tool("list_reviews", "List stored App Store reviews with filters and pagination.", schema(
                required: ["appStoreID"],
                optional: commonAppFilters.merging([
                    "rating_min": .integer,
                    "rating_max": .integer,
                    "version": .string,
                    "date_from": .string,
                    "date_to": .string,
                    "limit": .integer,
                    "cursor": .string
                ]) { current, _ in current }
            ), readOnly: true),
            tool("list_keywords", "List tracked keywords with latest rank and metrics.", schema(
                required: ["appStoreID"],
                optional: commonAppFilters.merging(["limit": .integer, "cursor": .string]) { current, _ in current }
            ), readOnly: true),
            tool("score_keywords", "Classify tracked keywords into defend, attack, long-tail, brand, experimental, or noisy buckets using rank, popularity, and phrase-quality heuristics.", schema(
                required: ["appStoreID"],
                optional: commonAppFilters
            ), readOnly: true),
            tool("add_keywords", "Add missing keyword/storefront/platform tracks and skip duplicates.", schema(
                required: ["appStoreID", "keywords", "storefronts"],
                optional: ["appStoreID": .integer, "keywords": .stringArray, "storefronts": .stringArray, "platform": .string]
            ), readOnly: false, destructive: false, idempotent: true),
            tool("update_keyword_notes", "Update notes for one tracked keyword.", schema(
                required: ["appStoreID", "keyword", "storefront", "notes"],
                optional: ["appStoreID": .integer, "keyword": .string, "storefront": .string, "platform": .string, "notes": .string]
            ), readOnly: false, destructive: false, idempotent: true),
            tool("list_screenshots", "List stored App Store screenshot metadata.", schema(
                required: ["appStoreID"],
                optional: commonAppFilters.merging(["limit": .integer, "cursor": .string]) { current, _ in current }
            ), readOnly: true),
            tool("export_screenshots", "Download stored screenshot URLs into a user-selected directory.", schema(
                required: ["appStoreID", "destination_directory_path"],
                optional: commonAppFilters.merging(["destination_directory_path": .string]) { current, _ in current }
            ), readOnly: false, destructive: false, idempotent: false, openWorld: true),
            tool("fetch_website_markdown", "Fetch markdown for a website through markdown.new.", schema(
                required: ["url"],
                optional: ["url": .string]
            ), readOnly: true, openWorld: true),
            tool("fetch_app_website_markdown", "Resolve an app's App Store seller website and fetch it through markdown.new when available.", schema(
                required: ["appStoreID"],
                optional: ["appStoreID": .integer, "storefront": .string]
            ), readOnly: true, openWorld: true),
            tool("list_competitors", "Derive competitor apps from latest ranking rows for shared tracked keywords.", schema(
                required: ["appStoreID"],
                optional: commonAppFilters.merging([
                    "limit": .integer,
                    "lookback_days": .integer,
                    "evidence_limit": .integer
                ]) { current, _ in current }
            ), readOnly: true),
            tool("get_ranked_apps_for_keyword", "Search live App Store rankings for one keyword and return top apps, ratings, screenshots, and optional target-app rank.", schema(
                required: ["keyword"],
                optional: [
                    "keyword": .string,
                    "storefront": .string,
                    "platform": .string,
                    "target_app_store_id": .integer,
                    "limit": .integer
                ]
            ), readOnly: true, openWorld: true),
            tool("suggest_keywords", "Generate candidate keywords from app metadata and verify a bounded live-ranking sample; returns partial candidates and errors when verification is capped.", schema(
                required: ["appStoreID"],
                optional: commonAppFilters.merging(["limit": .integer, "website_markdown": .string]) { current, _ in current }
            ), readOnly: true, openWorld: true),
            tool("refresh_keyword_rankings", "Refresh and persist rankings for tracked keywords so keyword and competitor tools share the same evidence. The limit argument caps keyword tracks refreshed.", schema(
                required: ["appStoreID"],
                optional: commonAppFilters.merging(["limit": .integer]) { current, _ in current }
            ), readOnly: false, destructive: false, idempotent: false, openWorld: true),
            tool("refresh_keyword_metrics", "Refresh keyword popularity metrics when Apple Ads is configured; otherwise return actionable setup status per keyword.", schema(
                required: ["appStoreID"],
                optional: commonAppFilters
            ), readOnly: false, destructive: false, idempotent: false, openWorld: true),
            tool("refresh_reviews", "Fetch and store a bounded most-recent public App Store review sample. Defaults to the US storefront.", schema(
                required: ["appStoreID"],
                optional: ["appStoreID": .integer, "storefronts": .stringArray, "limit_per_storefront": .integer, "limit": .integer]
            ), readOnly: false, destructive: false, idempotent: false, openWorld: true),
            tool("download_all_reviews", "Exhaustively fetch and store public App Store reviews for selected storefronts in persistence batches. Defaults to the US storefront.", schema(
                required: ["appStoreID"],
                optional: ["appStoreID": .integer, "storefronts": .stringArray, "batch_page_count": .integer]
            ), readOnly: false, destructive: false, idempotent: false, openWorld: true),
            tool("discover_keyword_landscape", "Run bounded onboarding discovery: seed keywords, verify a capped ranking sample, derive competitors, and optionally sample competitor reviews.", schema(
                required: ["appStoreID"],
                optional: commonAppFilters.merging([
                    "keyword_limit": .integer,
                    "competitor_limit": .integer,
                    "reviews_per_storefront": .integer,
                    "reviews_per_competitor": .integer,
                    "include_reviews": .boolean,
                    "website_markdown": .string
                ]) { current, _ in current }
            ), readOnly: false, destructive: false, idempotent: false, openWorld: true),
            tool("refresh_competitor_reviews", "Fetch and store bounded recent reviews for derived competitors.", schema(
                required: ["appStoreID"],
                optional: commonAppFilters.merging([
                    "competitor_limit": .integer,
                    "reviews_per_storefront": .integer,
                    "reviews_per_competitor": .integer
                ]) { current, _ in current }
            ), readOnly: false, destructive: false, idempotent: false, openWorld: true),
            tool("export_competitor_screenshots", "Export screenshots for derived competitors into a user-selected directory for agent-side visual analysis.", schema(
                required: ["appStoreID", "destination_directory_path"],
                optional: commonAppFilters.merging([
                    "competitor_limit": .integer,
                    "destination_directory_path": .string
                ]) { current, _ in current }
            ), readOnly: false, destructive: false, idempotent: false, openWorld: true),
            tool("get_localization_research_context", "Gather target and competitor localization evidence across storefronts, including deterministic metadata and screenshot URL comparisons for agent-side OCR and recommendation.", schema(
                required: ["appStoreID"],
                optional: commonAppFilters.merging([
                    "competitor_limit": .integer,
                    "include_target_app": .boolean,
                    "refresh_missing_metadata": .boolean,
                    "destination_directory_path": .string
                ]) { current, _ in current }
            ), readOnly: false, destructive: false, idempotent: false, openWorld: true)
        ]
    }

    static let resources: [Resource] = [
        Resource(
            name: "workspace_summary",
            uri: "openaso://workspace/summary",
            title: "Workspace Summary",
            description: "Tracked app count and high-level app summaries.",
            mimeType: jsonMimeType
        ),
        Resource(
            name: "apps",
            uri: "openaso://apps",
            title: "Apps",
            description: "Tracked apps with high-level metrics.",
            mimeType: jsonMimeType
        )
    ]

    static let prompts: [Prompt] = [
        prompt("review_theme_analysis", "Summarize review praise, complaints, feature requests, regressions, pricing objections, and version-specific issues."),
        prompt("keyword_research_brief", "Inspect app metadata, current keywords, scored keyword buckets, competitors, website markdown, screenshots, popularity, and ranking gaps before recommending keywords."),
        prompt("competitor_landscape", "Combine tracked rankings, derived competitors, ranked apps, screenshots, and reviews for a competitor landscape."),
        prompt("localization_opportunity_analysis", "Use localization research context, screenshot OCR, and metadata comparisons to recommend languages and localization scope."),
        prompt("aso_action_plan", "Produce prioritized ASO actions across keywords, metadata hypotheses, review-derived fixes, screenshot observations, and competitor monitoring."),
        prompt("aso_audit_scorecard", "Score ASO health from OpenASO evidence, then return quick wins, high-impact changes, and strategic recommendations."),
        prompt("metadata_optimization_package", "Generate App Store metadata recommendations from verified keywords, review language, competitor positioning, and Apple field rules."),
        prompt("screenshot_optimization_plan", "Use target and competitor screenshot evidence to build a 10-slot App Store screenshot strategy and creative test hypotheses."),
        prompt("store_listing_test_plan", "Create PPO and custom product page test plans from OpenASO evidence while requesting ASC-only inputs when needed.")
    ]

    static func promptTemplate(named name: String, arguments: [String: String]?) -> GetPrompt.Result? {
        let appStoreID = arguments?["appStoreID"] ?? "{appStoreID}"
        let storefronts = arguments?["storefronts"] ?? "relevant storefronts"
        let body: String
        switch name {
        case "review_theme_analysis":
            body = """
            For appStoreID \(appStoreID), start with get_app_overview to inspect reviewSummary and freshnessWarnings, then use list_reviews for \(storefronts). Refresh reviews only when data is missing or stale, using a bounded recent sample before considering download_all_reviews.
            Summarize praise, complaints, feature requests, regressions, pricing objections, trust concerns, version-specific issues, competitor mentions, and repeated language users use to describe value.
            Separate product issues from ASO messaging opportunities. Include review counts, rating ranges, versions, storefronts, and representative evidence themes rather than isolated anecdotes.
            When drafting review responses, use a HEAR structure: hear the specific issue, empathize briefly, state the action or limitation, and route to support or a fix. Do not ask users to change ratings or offer incentives.
            Label missing or unsupported data explicitly, including response-rate history, exact rating prompt timing, retention analytics, downloads, revenue, and App Store Connect conversion metrics.
            """
        case "keyword_research_brief":
            body = """
            For appStoreID \(appStoreID), inspect get_app_overview, list_keywords, score_keywords, list_competitors, list_reviews, list_screenshots, and any available website markdown before recommending keywords.
            Use staged, bounded discovery: start with current evidence, then run suggest_keywords or discover_keyword_landscape for the top 1-2 storefronts or a small seed limit before broadening. Continue with partial results when a tool returns verification_budget_exceeded or per-keyword errors.
            Classify keywords as defend, attack, long-tail, brand, experimental, or noisy. Drop generic fragments and irrelevant phrases unless ranking evidence proves relevance.
            Apply opportunity scoring as a rubric, not a substitute for evidence: weigh popularity, rankability/difficulty or result count, relevance, current rank, competitor overlap, and review-language support.
            Recommend keywords only after separating hypotheses from verified ranking/popularity evidence. Prioritize terms with direct download intent and avoid broad phrases that do not describe the app's core value.
            For iOS metadata recommendations, avoid repeating words across title, subtitle, and hidden keyword field, prefer singular keyword-field terms, use comma-separated values without spaces, and do not include competitor brands, app name, category names, or unsupported claims.
            """
        case "competitor_landscape":
            body = """
            For appStoreID \(appStoreID), use list_competitors and shared keyword evidence for \(storefronts). Refresh rankings first when shared evidence is missing or stale.
            Keep live refreshes bounded: prefer refresh_keyword_rankings with a small limit and use get_ranked_apps_for_keyword for specific high-value keywords instead of broad unconstrained crawls.
            Separate direct competitors from incidental ranking matches. Compare competitors by shared keyword count, average rank, best rank, rating count, review themes, pricing complaints, metadata positioning, and first-3 screenshot strategy.
            For screenshots, inspect first-screenshot hook, social proof, benefit clarity, visual contrast, proof claims, app UI visibility, and screenshot ordering. Export screenshots when visual analysis is requested.
            Use competitor reviews as evidence of unmet needs, switching triggers, table-stakes features, and messaging opportunities. Use refresh_competitor_reviews in a bounded way when stored reviews are missing.
            Label unavailable market intelligence such as downloads, revenue, paid campaign spend, and exact conversion rates instead of estimating it from ratings or rank alone.
            """
        case "localization_opportunity_analysis":
            body = """
            For appStoreID \(appStoreID), call get_localization_research_context for \(storefronts). Treat OpenASO's name, subtitle, description, and screenshot URL comparisons as deterministic evidence, not final recommendations.
            Narrow storefronts when researching visually or when refreshing missing metadata. If a broad localization request returns partial data, continue with the strongest storefronts and clearly label missing metadata, screenshots, or review coverage.
            Use OCR and visual interpretation on screenshot URLs or exported screenshot files to determine whether screenshot copy and creative are localized, market-specific, or unchanged from the US baseline.
            Compare App Store title, subtitle, and description differences against the US baseline. Use supported language codes only as evidence of in-app localization availability, not as proof of localized App Store metadata.
            Treat localized keywords as market-specific research, not translations of English terms. Use local competitor metadata, local review language, and live keyword/ranking checks before proposing localized title, subtitle, or keyword-field terms.
            Prioritize markets with a clear mix of opportunity, competitive localization gaps, implementation effort, revenue fit, and app-language support. Label revenue potential as a hypothesis unless the user provides ASC revenue by country.
            Recommend languages/storefronts with confidence and required scope: metadata_only, metadata_and_screenshots, or full_app_localization. Include competitor evidence and call out missing data separately from weak opportunity.
            """
        case "aso_action_plan":
            body = """
            For appStoreID \(appStoreID), produce prioritized ASO actions using get_app_overview, score_keywords, list_competitors, review themes, screenshot evidence, and ranking freshness.
            Prefer actionable partial evidence over repeated broad calls: if a crawl times out or returns a capped verification error, finish the plan with the evidence already gathered and list the next bounded query to run.
            Group actions by impact, effort, confidence, and evidence source: keyword tracking, metadata hypotheses, screenshot tests, review-derived product fixes, localization opportunities, and competitor monitoring.
            Explicitly identify noisy keywords to remove or de-prioritize, defend keywords where the app already ranks well, and attack keywords where competitors rank strongly.
            Apply ASO rubrics from domain knowledge only after OpenASO evidence is gathered. Mark unsupported inputs such as downloads, revenue, conversion rate, paid campaign performance, hidden keyword field contents, and exact App Store Connect analytics as missing or user-provided.
            Return concise next steps with bounded follow-up tool calls, not broad crawls.
            """
        case "aso_audit_scorecard":
            body = """
            For appStoreID \(appStoreID), create an ASO health audit from OpenASO evidence. Start with get_app_overview, then inspect score_keywords, list_keywords, list_reviews, list_screenshots, and list_competitors for \(storefronts). Refresh rankings, reviews, or keyword metrics only when overview freshnessWarnings show stale or missing evidence, and keep refreshes bounded.
            Score these factors on a 0-10 scale and compute a weighted 100-point score: title, subtitle, keyword coverage, description/conversion copy, screenshots, ratings and reviews, icon/search-result signal when available, keyword rankings, competitor position, and conversion/testing readiness.
            Use ASO rubrics as analysis criteria: Apple title and subtitle are 30 characters, hidden keyword field is 100 characters when user-provided, descriptions are conversion-oriented on iOS, first screenshots drive product-page comprehension, ratings below strong category norms can hurt conversion, and keyword rank/relevance matter more than raw keyword volume.
            Separate verified evidence from hypotheses. Label unsupported or missing data explicitly, especially downloads, revenue, exact conversion rate, impressions, hidden keyword field contents, paid campaign data, and ASC analytics.
            Return an ASO Score Card, Quick Wins, High-Impact Changes, Strategic Recommendations, and a Competitor Comparison table with evidence notes.
            """
        case "metadata_optimization_package":
            body = """
            For appStoreID \(appStoreID), build metadata recommendations from OpenASO evidence. Inspect get_app_overview, list_keywords, score_keywords, list_competitors, list_reviews, and any available website markdown for \(storefronts). Use suggest_keywords or discover_keyword_landscape only as a bounded expansion step after reviewing existing evidence.
            Produce title, subtitle, keyword-field, description, promotional-text, and What's New recommendations where evidence supports them. Use 30 characters for title, 30 for subtitle, 100 for the iOS keyword field when the user wants hidden keywords, 170 for promotional text, and 4000 for description and release notes.
            Build a keyword coverage matrix. Avoid repeating keyword words across title, subtitle, and keyword field; prefer singular keyword-field terms; use comma-separated keyword-field values without spaces; avoid app name, category names, competitor brands, "app", "free", and unsupported claims in the keyword field.
            Use review language and competitor positioning to improve conversion copy, but keep keyword recommendations tied to verified rankings, popularity metrics, competitor overlap, direct user intent, or clearly labeled hypotheses.
            If current hidden keyword field, conversion rate, downloads, revenue, or ASC product-page metrics are unavailable, ask the user for them or label them missing rather than inferring them from public metadata.
            Return a recommended metadata package, two alternatives, character counts, keyword coverage, before/after comparison, rationale, and evidence gaps.
            """
        case "screenshot_optimization_plan":
            body = """
            For appStoreID \(appStoreID), create a screenshot optimization plan from OpenASO evidence. Inspect get_app_overview, list_screenshots, list_reviews, score_keywords, and list_competitors for \(storefronts). Use export_screenshots or export_competitor_screenshots when visual/OCR analysis is requested or screenshot URLs are insufficient.
            Analyze screenshots with App Store creative rubrics: slot 1 must explain the core benefit quickly, slots 2-3 should prove core value, slots 4-7 can show feature breadth, slots 8-9 can show trust or differentiation, and slot 10 can reinforce a call to action. Prefer benefit-driven overlay copy, visible real UI, high contrast, and localized copy where relevant.
            Compare competitors by first-screenshot hook, screenshot count, visual clarity, proof/social claims, feature order, market-specific localization, and whether app UI is visible enough to understand.
            Mine review themes and keyword intent for what users need to see before downloading. Separate creative hypotheses from screenshot evidence and avoid claims that OpenASO cannot verify.
            Return a 10-slot screenshot plan with headline/caption ideas, screen to show, evidence source, competitor contrast, localization notes, and candidate PPO/CPP test hypotheses.
            """
        case "store_listing_test_plan":
            body = """
            For appStoreID \(appStoreID), design App Store Product Page Optimization and custom product page tests from OpenASO evidence. Inspect get_app_overview, score_keywords, list_reviews, list_screenshots, and list_competitors for \(storefronts) before proposing tests.
            Prioritize hypotheses from evidence: first screenshot clarity, screenshot order, benefit framing, social proof, icon/search-result distinctiveness when visible, localized screenshots, metadata positioning, and review-derived objections.
            Respect Apple testing limits: PPO can test app icon, screenshots, and app preview videos, not title, subtitle, keyword field, or description. CPPs can target audiences with custom screenshots, app previews, and promotional text, but are not randomized organic A/B tests.
            Ask for ASC-only inputs needed for sample sizing and interpretation: impressions, conversion rate, product page views, traffic source, country split, current test duration, confidence, and variant metrics. Label these missing if not provided; do not infer exact conversion or download lift from OpenASO public data.
            Return a test roadmap with hypothesis, variants, primary metric, evidence source, required ASC inputs, minimum detectable effect assumptions if user supplies baseline traffic, and the next OpenASO evidence refresh to run after the test.
            """
        default:
            return nil
        }

        return GetPrompt.Result(
            description: prompts.first { $0.name == name }?.description,
            messages: [.user(.text(text: body))]
        )
    }

    static func prompt(_ name: String, _ description: String) -> Prompt {
        Prompt(
            name: name,
            description: description,
            arguments: [
                .init(name: "appStoreID", description: "The numeric App Store ID.", required: true),
                .init(name: "storefronts", description: "Optional comma-separated storefront country codes.", required: false)
            ]
        )
    }

    static let appIDSchema = schema(required: ["appStoreID"], optional: ["appStoreID": .integer])
    static let commonAppFilters: [String: JSONSchemaType] = [
        "appStoreID": .integer,
        "storefronts": .stringArray,
        "platform": .string
    ]

    static func tool(
        _ name: String,
        _ description: String,
        _ inputSchema: Value,
        readOnly: Bool,
        destructive: Bool? = nil,
        idempotent: Bool? = nil,
        openWorld: Bool? = false
    ) -> Tool {
        Tool(
            name: name,
            description: description,
            inputSchema: inputSchema,
            annotations: .init(
                title: name,
                readOnlyHint: readOnly,
                destructiveHint: destructive,
                idempotentHint: idempotent,
                openWorldHint: openWorld
            )
        )
    }

    static func schema(required: [String] = [], optional properties: [String: JSONSchemaType]) -> Value {
        var propertyValues: [String: Value] = [:]
        for (name, type) in properties {
            propertyValues[name] = type.schemaValue
        }
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(propertyValues),
            "additionalProperties": false
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }
}

private enum JSONSchemaType: Sendable {
    case boolean
    case integer
    case string
    case stringArray

    var schemaValue: Value {
        switch self {
        case .boolean:
            return ["type": "boolean"]
        case .integer:
            return ["type": "integer"]
        case .string:
            return ["type": "string"]
        case .stringArray:
            return ["type": "array", "items": ["type": "string"]]
        }
    }
}

private struct OpenASOMCPWorkspaceSummaryResource: Codable, Sendable {
    let trackedAppCount: Int
    let apps: OpenASOMCPPage<OpenASOMCPAppSummary>
}

private struct OpenASOMCPAppResource: Sendable {
    enum Kind: Sendable {
        case overview
        case reviews
        case keywords
        case screenshots
        case competitors
    }

    let appStoreID: Int64
    let kind: Kind

    init?(uri: String) {
        guard let url = URL(string: uri), url.scheme == "openaso", url.host == "apps" else {
            return nil
        }

        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let appStoreIDValue = parts.first, let appStoreID = Int64(appStoreIDValue) else {
            return nil
        }

        self.appStoreID = appStoreID
        switch parts.dropFirst().first {
        case nil:
            self.kind = .overview
        case "reviews":
            self.kind = .reviews
        case "keywords":
            self.kind = .keywords
        case "screenshots":
            self.kind = .screenshots
        case "competitors":
            self.kind = .competitors
        default:
            return nil
        }
    }
}

private extension Dictionary where Key == String, Value == MCP.Value {
    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidParams("Missing required string argument: \(key)")
        }
        return value
    }

    func int(_ key: String) -> Int? {
        guard let value = self[key] else { return nil }
        return Int(value)
    }

    func requiredInt64(_ key: String) throws -> Int64 {
        guard let intValue = int(key) else {
            throw MCPError.invalidParams("Missing required integer argument: \(key)")
        }
        return Int64(intValue)
    }

    func bool(_ key: String) -> Bool? {
        guard let value = self[key] else { return nil }
        return Bool(value)
    }

    func stringArray(_ key: String) -> [String]? {
        self[key]?.arrayValue?.compactMap(\.stringValue)
    }

    func requiredStringArray(_ key: String) throws -> [String] {
        guard let values = stringArray(key), !values.isEmpty else {
            throw MCPError.invalidParams("Missing required string array argument: \(key)")
        }
        return values
    }

    func date(_ key: String) throws -> Date? {
        guard let stringValue = string(key) else { return nil }
        guard let date = ISO8601DateFormatter.openASOMCPDate(from: stringValue) else {
            throw MCPError.invalidParams("Invalid ISO-8601 date argument: \(key)")
        }
        return date
    }
}

private extension ISO8601DateFormatter {
    static func openASOMCPDate(from value: String) -> Date? {
        let fractionalSecondsFormatter = ISO8601DateFormatter()
        fractionalSecondsFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalSecondsFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
