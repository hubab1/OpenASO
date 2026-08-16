# Changelog

## 0.4.4 - 2026-08-16

OpenASO 0.4.4 fixes credential storage in directly distributed builds.

- Fix App Store Connect and Apple Ads private keys failing to save to Keychain in production builds.
- Preserve existing login-Keychain credentials when Data Protection Keychain migration is unavailable.

## 0.4.3 - 2026-08-15

OpenASO 0.4.3 moves keyword popularity to Apple’s supported Apple Ads Platform API and strengthens ranking storage and day-to-day app management.

- Use Apple’s official Swift client and Search Term Popularity API for current 1–100 keyword popularity.
- Add guided Apple Ads credential verification and account selection, with private keys stored in macOS Keychain.
- Add an Apple Ads workspace for Search Popularity, campaigns, and owned apps, plus corresponding read-only MCP tools.
- Show Apple’s threshold-based unavailable state instead of retaining an invalid stale popularity score, and avoid repeatedly requesting the same unavailable term during its freshness window.
- Keep keyword sorting active while ranking and popularity values update during a refresh.
- Normalize ranking persistence with a validated V6 migration that preserves existing ranking history while reducing redundant storage.
- Accept App Store URLs as well as numeric IDs when adding an app.
- Improve window sizing and key sheets on smaller displays.

## 0.4.2 - 2026-08-08

OpenASO 0.4.2 adds reliable scheduled daily refreshes that can run while the app is closed and hardens headless MCP operation.

- Register a native macOS background agent for the existing daily refresh schedule.
- Catch up after login or wake while avoiding duplicate in-app and background refreshes.
- Show background service readiness and the latest persisted refresh result in Settings.
- Preserve credential access for background runs through data-protection keychain migration.
- Keep concurrent --mcp-stdio and scheduled-agent processes fully headless with prohibited macOS UI activation.
- Default new installations to a 5:00 AM daily refresh while preserving existing saved times.

## 0.4.1 - 2026-08-08

OpenASO 0.4.1 makes daily refreshes significantly more responsive and reliable for large keyword workspaces.

- Update only affected keyword cells during a refresh instead of rebuilding the full table.
- Keep sorting and navigation responsive while rankings and popularity values arrive.
- Parallelize ranking requests and reduce ranking persistence CPU, memory, and duplicate history storage.
- Scope refresh progress to the selected tracked app, not competitor apps.
- Preserve ranking history and popularity/trend data when Apple search authentication is refreshed.

## 0.4.0 - 2026-07-26

OpenASO 0.4.0 adds a complete pre-live Keyword Research workspace for organizing projects, gathering ranking and popularity evidence, reviewing shared history, and copying selected keywords into tracked apps.

- Add web-first App Store ranking with provider provenance and fallback handling.
- Add ranked-app pricing comparisons and visible in-app purchase pricing.
- Make large keyword workspaces and switching between apps substantially faster.
- Add scoped metadata refresh progress, daily headless refresh, and provider observability.
- Expand MCP with paginated history, pricing tools, and stdio parity with the in-app server.
- Improve reliability across request pacing and retries, Apple Ads session expiry, Keychain reads, and versioned database migrations.

## 0.3.2 - 2026-05-09

OpenASO 0.3.2 makes keyword research more accurate when you track App Store performance across iPhone, iPad, and Mac.  You can now choose the target device when adding keywords, keep platform context through CSV imports and exports, and filter refreshes around the device results you care about. Keyword tables and charts also do a better job of showing platform-specific ranking history, reducing duplicate-looking data when the same keyword is tracked in multiple contexts.  This release also improves refresh reliability by queueing overlapping app refreshes, prevents duplicate CSV import processing, and adds a new OpenASO ASO skill for evidence-led audits, keyword research, metadata recommendations, screenshot planning, competitor review, and localization work.

## 0.3.1 - 2026-05-08

Add OpenASO MCP workflows.

- Add a local MCP server for inspecting and updating OpenASO workspaces from compatible clients.
- Expose tools for app discovery, app onboarding, keyword tracking, rank refreshes, keyword scoring, reviews, ratings, screenshots, competitor analysis, and localization research.
- Add MCP resources and prompts for workspace summaries, app overviews, reviews, keywords, screenshots, competitors, keyword audits, competitor briefs, and localization audits.
- Add settings UI for starting, stopping, and configuring the bundled MCP server.
- Add validation and tests covering MCP tool calls, resource reads, server lifecycle behavior, and ASO workflow outputs.

## 0.3.0 - 2026-05-07

Initial release.  - Track App Store keyword rankings across storefronts. - View app ratings, reviews, and store metadata in one place. - Export ranking and storefront data for analysis. - Receive future updates automatically through the built-in updater.

## 0.2.0 - 2026-05-07

Initial release.  - Track App Store keyword rankings across storefronts. - View app ratings, reviews, and store metadata in one place. - Export ranking and storefront data for analysis. - Receive future updates automatically through the built-in updater.

## 0.1.0 - 2026-05-07

Initial release.  - Track App Store keyword rankings across storefronts. - View app ratings, reviews, and store metadata in one place. - Export ranking and storefront data for analysis. - Receive future updates automatically through the built-in updater.

All notable changes to OpenASO releases are recorded here. The release workflow inserts the newest version at the top and reuses the same entry for GitHub Releases and Sparkle release notes.

## 0.1 - Unreleased

- Initial release preparation.
