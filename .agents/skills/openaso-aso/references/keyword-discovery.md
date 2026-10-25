# Popularity-guided keyword discovery

Find relevant, incremental keywords with measured demand. A high popularity index supports a demand hypothesis; relevance, ranking evidence and competition determine whether it is an opportunity for this app.

## Establish scope

Use the app overview and existing tracks to identify its actual features, target audience, tracked terms and evidence freshness. If a broad workspace read times out, continue with narrow tool calls and disclose the missing context. Keep a ledger keyed by normalized keyword/storefront/platform, plus seeds and page offsets already requested.

Research one storefront at a time. Start with an app-based `suggest_keywords` call (omit `seed_keyword`) and two or three distinct feature/use-case seeds. Use `limit: 50` and `ranking_limit: 0` during expansion so the response budget goes to discovery. A default budget of eight suggestion requests per app is a useful starting point; increase it when the user requests broader coverage and new useful terms continue to appear.

## Expand with evidence

- `suggest_keywords` looks up fresh market popularity automatically when available. Retain `popularity.popularityScore`, its source and observation time separately from contextual `suggestionScore`. The latter can change with the seed and should be compared only within that request context.
- Use `get_keyword_popularity` to check untracked terms, synonyms, or evidence that is missing or stale, in batches of at most 50 terms. The service uses saved official credentials and the saved web-session fallback automatically. If access fails, retain candidates and report the reason instead of repeatedly retrying authentication.
- Prefer feature-relevant terms with market popularity above 5 as branch seeds. Keep scores of 0...5 and unknown scores in separate exploratory groups; missing data is not evidence of zero demand. Retain a low-score term when its feature coverage makes it worth testing.
- Exclude unrelated intent, unsupported features, wrong-language phrases and competitor brands from the organic opportunity shortlist before choosing branches. A popular competitor can supply research context without becoming a metadata recommendation.
- Re-query promising untried terms as `seed_keyword` values. Also follow `suggestionPages.nextOffset` with the same seed and limit to inspect another page. Deduplicate terms across pages and seeds while retaining every request context; flag already tracked terms using `isTracked`.
- Count the new, relevant above-floor terms returned by each expansion. Stop after two successive expansion calls add none, when the frontier is exhausted, or at the request budget. Return untried seeds/pages when the budget stops a productive search. Treat a partial page as provider pagination evidence, not proof that every possible keyword has been found.

## Verify and select

Use `get_ranked_apps_for_keyword` on the strongest shortlist to inspect target rank, competing apps, search intent and ranking provenance. Native App Store results and an iTunes fallback have different evidential strength; identify the fallback when used. Popularity alone does not establish downloads, exact search volume, conversion, or an achievable rank.

Prioritize by feature relevance, fresh market popularity, current rank and competitive evidence. Return a coverage summary with seeds/pages tried, unique candidates, above-floor relevant terms, new versus tracked counts, provider failures, and the remaining frontier. For each recommendation include its rationale, popularity source/time, seed context and ranking gaps. Keep low/unknown-demand hypotheses separate from the primary shortlist.

When keyword additions are authorized, use `add_keywords` for the selected new terms and preserve source context with `update_keyword_notes`. Keep contextual suggestion scores out of stored market-popularity fields. Use `refresh_keyword_metrics` with its `keywords` filter to persist fresh market popularity for the chosen terms in batches of at most 50. Refresh rankings in bounded batches when needed; distinguish adding a track from refreshing it.
