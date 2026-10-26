# Keyword targeting and metadata proposals

Connect keyword discovery to owned metadata and measured performance. Popularity is demand evidence; feature relevance, search intent, competition, existing visibility and evidence freshness determine whether a term is worth targeting.

## Read the actual baseline

Use `get_app_store_metadata` with the app ID, exact App Store locale, search platform and `scope: live` or `editable`. App Store Connect credentials are separate from Apple Ads access. The tool reads title/subtitle and version-specific private keywords using saved credentials, returns version/state and a content hash, and fails instead of silently substituting another language or mixing a draft with live metadata. If authenticated access is unavailable, request the missing fields or mark the audit partial.

Keep locale and storefront explicit: locale selects metadata language, storefront selects demand and rankings. Repeat research for each intended market instead of translating US keyword choices.

## Audit opportunities and current targeting

Run the keyword-discovery workflow first, then pass a curated shortlist to `audit_keyword_targeting`. Include promising new terms and valuable existing terms that a draft must protect. The tool defaults to at most 50 tracked terms ordered by stored popularity; this default is a bounded sample, not the complete keyword market.

The audit combines fresh market popularity, app-specific metadata overlap, lexical coverage and up to eight bounded ranking samples. Its relevance score is a heuristic; review actual feature fit, search-result intent, brands, language and unsupported claims. A popular phrase with no app relevance is a review candidate rather than an automatic opportunity.

For sampled keywords, inspect `competition`: its score is an OpenASO native-result heuristic with confidence, source/time and bounded competitor evidence. A missing score or fallback/insufficient-data reason means unknown competition. Compare demand and relevance with observed competitor authority and metadata saturation; do not treat a lower score as guaranteed rankability or an Apple metric. Audits calculate this evidence without persisting it.

Distinguish literal phrase presence, word combinations across fields, English plural variants, and missing components. Apple advises avoiding filler such as "to" and "the" in the private keyword field. Token presence and variant combinations do not prove indexing. A well-covered term with weak rankings needs a different diagnosis from a term with missing metadata components.

Use native App Store ranking evidence when available. Preserve source, observation time and sample size; iTunes fallback or an absent target in a bounded sample leaves native rank unknown. Do not turn a missing rank into a numeric position.

## Produce reviewable alternatives

Draft a conservative option and a broader positioning option. Preserve the app's brand, readable product promise and useful existing targets. Use `compare_metadata_draft` with proposed fields, the same keyword shortlist, and the baseline `expected_hash`.

Inspect 30/30/100 character validation, duplicate/plural/filler warnings and gained/lost lexical coverage. Explain which terms each field targets and which existing terms lose prominence. Review exact phrases as well as inferred combinations; avoid unsupported claims about title/subtitle ranking weights or predicted rank lift. Return character counts, source/time, before/after fields, tradeoffs and remaining evidence gaps.

These tools do not publish App Store changes. Any later apply step needs the user's authorized publishing scope and a fresh baseline check.

## Record and measure a release

Use `record_metadata_baseline` before a metadata release to save the live version, private fields, fixed keyword set and ranking/popularity evidence locally. Keep its ID and a release-oriented label. `list_metadata_baselines` finds prior records for an app.

Use `compare_metadata_baseline` after the release to compare the same app, locale, storefront, platform and queries. It repeats only previously sampled rank queries and computes deltas only from native positions present in both observations. Note version changes, coverage gains/losses, demand changes and source failures.

Optional App Store Search impression/download counts require explicit reporting periods and are labeled caller-provided. Match market and comparable periods, account for paid Apple Ads and seasonality, and keep aggregate acquisition separate from keyword attribution. The comparison is observational, not a randomized title/subtitle/keyword experiment. Schedule later measurement only when the user requests it.
