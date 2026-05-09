---
name: openaso-aso
description: "Use when performing App Store Optimization work with OpenASO MCP data: ASO audits, keyword research, metadata optimization, screenshot strategy, review analysis, competitor research, localization planning, or store listing test plans. Prefer OpenASO evidence-gathering tools first, then apply ASO frameworks as analysis rubrics."
---

# OpenASO ASO

Use OpenASO as the evidence layer for ASO recommendations. Do not copy generic ASO prompts directly; gather OpenASO data first, then apply ASO domain rubrics to that evidence.

## Core Workflow

1. Identify the target app with `detect_app`, `search_app_store_apps`, `list_apps`, or the provided `appStoreID`.
2. Start every substantive ASO analysis with `get_app_overview` to check metadata, ratings, review/keyword/screenshot counts, top competitors, and freshness warnings.
3. Gather only the evidence needed for the requested workflow:
   - Keywords: `list_keywords`, `score_keywords`, `suggest_keywords`, `discover_keyword_landscape`, `get_ranked_apps_for_keyword`.
   - Reviews: `list_reviews`, `refresh_reviews`, `download_all_reviews` only when exhaustive history is explicitly needed.
   - Competitors: `list_competitors`, `refresh_keyword_rankings`, `refresh_competitor_reviews`.
   - Screenshots: `list_screenshots`, `export_screenshots`, `export_competitor_screenshots`.
   - Localization: `get_localization_research_context`.
   - Website positioning: `fetch_app_website_markdown` or `fetch_website_markdown`.
4. Keep refreshes bounded. Prefer narrow storefronts, small limits, and partial results over broad crawls.
5. Separate verified evidence from hypotheses. Label unsupported or missing inputs instead of inventing them.

## Unsupported Or User-Provided Data

OpenASO public/local evidence does not prove:

- Downloads, revenue, LTV, retention, or paid campaign performance.
- Exact App Store Connect impressions, product page views, conversion rate, or test results.
- The current hidden App Store keyword field unless the user provides it.
- Exact competitor conversion rates or revenue.

Ask for these inputs when required, or mark them as missing.

## ASO Rubrics To Apply

- Title and subtitle are 30 characters each.
- Hidden iOS keyword field is 100 characters when user-provided.
- Promotional text is 170 characters; description and release notes are 4000 characters.
- Avoid repeating keyword words across title, subtitle, and keyword field.
- Prefer comma-separated keyword-field terms without spaces.
- Do not use competitor brands, category names, app name, `app`, `free`, or unsupported claims in keyword-field recommendations.
- Keyword opportunity should weigh relevance, rankability/difficulty or result count, popularity, current rank, competitor overlap, and review-language support.
- Screenshot slots 1-3 should explain core value quickly; later slots can expand features, trust, differentiation, and calls to action.
- Localized keywords are market-specific research, not translations. Use local metadata, reviews, competitors, and ranking checks.
- PPO can test app icon, screenshots, and app previews. CPPs can target custom screenshot/app-preview/promotional-text variants, but are not randomized organic A/B tests.
- Review responses should follow HEAR: hear the issue, empathize briefly, state action or limitation, and route to support or a fix.

## Output Shape

For audits and action plans, group recommendations by impact, effort, confidence, and evidence source.

For keyword or metadata work, include a keyword coverage matrix, character counts, rationale, and evidence gaps.

For screenshots and tests, include a variant plan with hypothesis, evidence source, primary metric, required ASC inputs, and next OpenASO refresh to run after the test.
