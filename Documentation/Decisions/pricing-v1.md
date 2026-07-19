# Pricing v1 contract

- Status: Proposed
- Date: 2026-07-19
- Scope: Pricing schema, data source, UI, and read-only MCP work

## Decision summary

Pricing v1 will compare customer-facing prices that OpenASO can observe on
public App Store surfaces. A request covers one app and an explicit,
deduplicated selection of 1 to 25 storefronts.

For each storefront, OpenASO may report:

- the base app price; and
- rows currently visible in the public in-app purchase sections of the app's
  App Store product page.

The visible rows are evidence, not a product catalog. OpenASO must state that
their coverage may be incomplete even when the fetch succeeds. It must not
infer tax treatment, developer proceeds, billing cadence, or cross-store
product identity.

The exact local display price remains primary. A successful priced value keeps
the source display string, an exact base-10 decimal amount, and its currency.
An optional comparison-currency value may be derived only from dated European
Central Bank (ECB) reference rates and must be labeled as an approximate
reference conversion, not an amount that Apple will charge or pay.

Pricing v1 stores only the latest evidence and latest attempt state. It is not
a price-history feature.

## Context

OpenASO needs a useful way to inspect public app pricing across storefronts
without presenting scraped data as more complete or authoritative than it is.
The public product page can expose promoted in-app purchases, but Apple allows
developers to choose which items appear and supports only a bounded visible
selection. Apple describes these rows as items users can view from the product
page and notes that up to 20 items may be showcased across its in-app purchase
and subscription sections. See [Creating Your Product Page][apple-product-page]
and [Promoting Your In-App Purchases][apple-promoted-iap].

The feature direction was surfaced by the WIP implementation in
[`5de98ea`][wip-pricing-commit]. This ADR independently specifies the contract
before adopting any schema or runtime code. In particular, pricing v1 does not
adopt that patch's tax adjustments, inferred billing cadence, name-based
cross-store row matching, implicit all-storefront expansion, or opaque
whole-result persistence. The source link records design history and does not
imply shared authorship of this document or a future implementation.

ECB reference rates are suitable for a clearly labeled, dated comparison
reference. They are not transaction rates. The ECB says its euro reference
rates are published for information purposes and may not match actual market
transactions. See the [ECB exchange-rate overview][ecb-rates] and
[ECB Data API documentation][ecb-api].

## Normative language

The words **must**, **must not**, **should**, and **may** describe requirements
for pricing v1. Unknown or unavailable values must remain unknown; an
implementation must not invent a value to make a result look complete.

## Terms

- **Storefront**: a normalized App Store country code selected by the caller.
- **Base app price**: the customer-facing price to acquire the app in one
  storefront, including a genuine free value.
- **Visible purchase row**: a name and price row observed in a public in-app
  purchase section. It is not guaranteed to represent every product the app
  sells.
- **Local price**: the source display string plus an exact decimal amount and
  currency when all three can be established without guessing.
- **Price evidence**: a value, absence, or failure observed for one app and
  storefront at a recorded time.
- **Reference conversion**: a derived amount calculated with a dated ECB euro
  reference-rate set. It is approximate and is not a transaction, tax, or
  proceeds calculation.
- **Current evidence**: the latest successful evidence plus the latest attempt
  state. It does not form a historical series.

## Request boundary

A pricing comparison request must contain:

- exactly one positive App Store ID;
- 1 to 25 explicit storefronts; and
- an optional comparison currency, defaulting to USD.

The 25-storefront cap is an operational v1 bound. It says nothing about App
Store coverage or how many storefronts exist.

The raw storefront array must contain 1 to 25 values before normalization.
Each value is then trimmed, normalized to lowercase, and validated against
OpenASO's supported storefront catalog. Two raw values that normalize to the
same code are a `duplicate_storefront` validation error; the service never
silently deduplicates a request. A valid set is returned in deterministic code
order. An empty selection is invalid. Omitting storefronts must not mean "all
storefronts," and the service must not silently add the United States or any
tracked-app default. Native UI may prevent or remove duplicates before it
submits the request, but the shared service and MCP contract still reject
them.

The comparison currency must be a normalized three-letter currency code.
Accepting a code does not promise that the ECB publishes a rate for it. When a
required rate is absent, local evidence remains usable and the conversion is
unavailable.

One operation therefore has at most 25 app/storefront coordinates. Provider
work must use the shared request gate, bounded concurrency, cancellation, and
timeouts rather than creating one unbounded task per coordinate.

## Supported evidence

### Base app price

The base app price must come from a public Apple response for the exact App
Store ID and requested storefront.

A base-price result has one of these states:

- `priced`: display price, exact decimal amount, and currency are all known.
- `free`: the source explicitly reports a zero customer price. This is a known
  value, not a missing price.
- `not_available`: the public source unambiguously says the app is not offered
  in that storefront.
- `unparseable`: a price was exposed, but amount or currency could not be
  established without guessing.
- `unavailable`: the provider request or response failed.

An absent search result may be recorded as `not_available` only when the
provider contract makes that conclusion unambiguous. Rate limiting, a changed
response shape, decoding failure, or a transient empty response is
`unavailable`, not evidence that the app is absent.

### Publicly visible in-app purchase rows

Pricing v1 may retain rows from recognized public purchase sections of the
exact storefront product page. Distinct purchase and subscription sections may
both contribute rows, but the rows remain unclassified evidence. Each retained
row must preserve:

- its source order across the recognized sections and their rows;
- its source display name;
- its source display price;
- exact local amount and currency when losslessly established; and
- row-level parse state when amount or currency is unknown.

The implementation must not recursively combine similarly shaped data from
unrelated page sections. Multiple documented purchase sections are not an
ambiguity, but competing payloads for the same section are. If the
authoritative payload cannot be selected deterministically, the visible-row
result is unavailable with a source-shape error.

At most 20 visible rows are returned per storefront. If a public response
unexpectedly yields more, OpenASO retains the first 20 in source order and sets
`truncatedByClient` to true. This safety cap is separate from source
completeness.

The total order is section order on the rendered product page followed by row
order within each section. The 20-row cap applies once after rows from all
recognized sections are combined in that order. Identical-looking rows at
different source positions are preserved; pricing v1 does not deduplicate by
display name or price because those fields are not identity.

The coverage state for visible rows is one of:

- `visible_rows`: one or more public rows were retained. They may still be an
  incomplete subset.
- `none_visible`: a valid product page exposed no visible rows, whether its
  purchase sections were empty or absent. This does not mean the app sells no
  in-app purchases.
- `not_applicable`: authoritative base-price evidence says the app is not
  offered in the storefront, so no product page is expected there.
- `unavailable`: the page, authoritative section, or parser result was
  unavailable or ambiguous.

Every successful visible-row result must carry the fixed completeness label
`public_visible_subset`. Neither `visible_rows` nor `none_visible` may be
described as a complete product catalog.

### Monetary values

Source monetary values must use decimal arithmetic. A persisted exact amount
must be represented losslessly, for example as a validated canonical base-10
decimal string. Binary floating-point values must not be the source of truth.

The source display price must be preserved rather than reconstructed from the
amount. It may contain locale-specific spacing, punctuation, symbols, and
formatting. UI and MCP output show this local display value first.

If a display value cannot be parsed losslessly or its currency cannot be
established from authoritative source data, OpenASO preserves the bounded
display evidence, marks the value `unparseable`, and omits its amount,
currency, conversion, and numeric comparison. It must not infer a currency
from an ambiguous symbol such as `$` or `¥` alone.

Persisted source strings have these UTF-8 byte limits:

- visible purchase display name: 512 bytes;
- local display price: 128 bytes;
- stable source descriptor or source URL: 2,048 bytes; and
- stable error code: 64 bytes.

These limits apply before persistence and output. OpenASO must not truncate an
oversized source value because truncation would no longer preserve exact
evidence. An oversized display name or price makes that evidence component
unavailable with `field_too_large`, while previously stored evidence remains
intact. Source descriptors are constructed by OpenASO; an oversized one is a
provider-contract failure rather than user-visible partial text.

## Currency conversion

Pricing v1 uses only the ECB EXR daily euro foreign exchange reference rates.
The FX provider is replaceable behind a protocol, but an alternative provider
must not be enabled under the `pricing_v1` contract without a new decision or
contract version.

Each rate set must retain:

- source identifier `ecb_exr_reference_rate`;
- the ECB observation date;
- the time OpenASO fetched it;
- base currency EUR;
- every currency and exact decimal rate used; and
- sufficient dataset or request provenance to reproduce the rate selection.

Pricing v1 uses the most recent ECB daily observation available when the
comparison is assembled. The observation must be no more than seven calendar
days old at that time. This allows weekends and publication holidays without
silently relying on an indefinitely stale rate. If no qualifying rate set is
available, conversion is unavailable and local prices remain visible.

ECB EXR rates are expressed as units of a quoted currency per EUR. For a local
currency `L`, target currency `T`, and amount `A`, the derived target amount is:

```text
target amount = (A / units-of-L-per-EUR) * units-of-T-per-EUR
```

EUR uses a rate of exactly 1. Exact source amounts and rates remain canonical
base-10 decimals. For conversion, their decimal coefficients and scales form
the exact rational expression above. The service rounds the final target
amount once to eight fractional decimal places using round-half-to-even. It
does not round either source value or an intermediate quotient. Overflow or an
unrepresentable result makes conversion unavailable.

The eight-place derived value is approximate conversion evidence, not an exact
source amount. The UI applies target-currency formatting to that value only
for presentation.

Every converted value must include the target currency, rate observation
date, rate source, and an `approximate_reference_conversion` qualifier. If
either required rate is missing, zero, negative, malformed, or too old, no
converted value is returned.

When local and comparison currencies are the same, the exact local amount is
already comparable. The service may return it as `same_currency` without an FX
claim or rate date. A free base app remains `free`; it does not need a derived
zero in another currency.

FX conversion compares publicly displayed customer amounts only. It must not:

- remove or estimate taxes;
- estimate whether tax is included;
- estimate Apple's commission or developer proceeds;
- model purchasing-power parity or Apple's price tiers; or
- claim that the converted amount is the charge settled by a card network.

Base app prices for the same App Store ID may be compared across selected
storefronts. Visible purchase rows must not be paired across storefronts by
name, position, price, or inferred cadence. Their localized names are not
stable product identifiers, so pricing v1 does not calculate cross-store
percentage differences for those rows.

## Explicit non-goals and prohibited claims

Pricing v1 does not provide:

- a complete in-app purchase or subscription catalog;
- private App Store Connect pricing schedules, product identifiers, price
  points, introductory offers, offer eligibility, or future price changes;
- tax-inclusive or tax-exclusive normalization;
- developer proceeds, Apple commission, settlement, or accounting estimates;
- billing cadence, subscription duration, or product type inferred from a
  display name;
- cross-store identity for visible purchase rows;
- price-tier, affordability, or purchasing-power analysis;
- historical price charts, change detection, or backfilled observations; or
- automatic all-storefront discovery.

Words such as "all products," "complete catalog," "tax adjusted," "net
price," "proceeds," "monthly," "annual," or "same product" must not appear
as claims unless a future authoritative source and versioned contract support
them. Source text may still contain such words inside a preserved display
name; it remains unclassified source evidence.

## Lifecycle, freshness, and persistence

Pricing persistence is a global current-evidence cache keyed by public app
identity, not an event log and not a child of `TrackedApp`.

- The unique current coordinate is App Store ID plus storefront.
- Base-price and visible-row evidence have independent success, freshness, and
  error state within the coordinate.
- A successful component atomically replaces only that component's previous
  evidence. Replacing visible-row evidence replaces its owned child rows.
- A failed component records bounded latest-attempt metadata but does not erase
  that component's previous successful evidence.
- A retained component success older than 24 hours is `stale`; the UI and API
  must expose that state and its original fetch time.
- `generatedAt` for an assembled comparison is not evidence time. Every
  coordinate keeps its own `fetchedAt` and latest-attempt time.
- A force refresh bypasses freshness reuse but still follows the same bounded
  request and partial-error rules.
- A cancelled comparison commits none of that operation's new observations or
  latest-attempt changes. Previously stored evidence remains unchanged.

Only the latest successful evidence and latest attempt state for each
component are retained. All component updates from one completed comparison
are committed in one final transaction. A schema must not quietly accumulate
prior observations as history.

The global cache is bounded to 2,000 app/storefront coordinates and 40,000
visible child rows. A component that has never produced successful evidence
has a hard seven-day expiry for that failure-only component state. A coordinate
with any retained success has a hard 90-day expiry after its latest access.
Expiry is enforced in the cache transaction before every cache read and before
every final pricing write, even while the store is below its hard caps.

Failure-only expiry is component-specific. If one component has retained
success, an expired failed-attempt-only sibling is cleared while the coordinate
and successful evidence remain. A coordinate is deleted when this cleanup
leaves it with neither component success nor non-expired attempt state. A
90-day coordinate expiry removes both components regardless of their source
freshness; a later request must fetch them again.

`lastAccessedAt` is initialized when the coordinate is created. A cache read
that returns any retained component advances it to the read time in the same
transaction when the stored access time is at least one hour older. Reads
within that one-hour coalescing window leave it unchanged. Expiry is checked
before this update, so a read cannot revive an already expired coordinate.
This timestamp is cache bookkeeping rather than source evidence and must not
change `fetchedAt`, freshness, provenance, or latest-attempt state.

Before a write that would exceed either hard cap, the store first performs the
same expiry cleanup and then removes enough least-recently-accessed
coordinates, ordered deterministically by `lastAccessedAt`, App Store ID, and
storefront. Coordinates in the active request are not eviction candidates
during that transaction. Owned visible rows are cascade-deleted with their
coordinate; the ECB cache and unrelated app data are not. If enough space
cannot be made, the whole final pricing write fails without partially evicting
or inserting data.

The Settings cache-clear action removes all pricing coordinates and their
owned rows in one transaction and reports failure rather than presenting a
partial clear. These retention rules are operational bounds, not statements
that older public prices are invalid.

Deleting a tracked app does not delete globally keyed public pricing evidence,
which may also have been populated by MCP or another public comparison. An
explicit pricing-cache clear or workspace reset removes it.

A request initiated from a tracked-app UI still captures the app generation
before leaving the store actor and revalidates it in the final write
transaction. If that generation was deleted or replaced, the operation writes
nothing, even though the cache is global. An MCP comparison that is not tied to
a tracked generation uses only its validated public App Store ID.

The current ECB rate cache is separate, dated, and replaceable. Derived
conversion values are computed from exact local evidence and the qualifying
rate set; they are not persisted as authoritative source prices.

## Provenance contract

Every current coordinate exposes provenance for its independently fetched
base and visible-row evidence:

- source kind, such as `public_app_store_lookup` or
  `public_app_store_product_page`;
- normalized App Store ID and storefront;
- fetch time;
- source URL or a stable, non-secret source descriptor;
- parser or contract version when parsing a public page;
- coverage and truncation state; and
- bounded latest error code and latest-attempt time.

A source-provided observation time may be recorded only when the source
actually supplies it. OpenASO must not relabel its fetch time as Apple's
publication time.

No merged comparison may imply that all coordinates were fetched together.
Cached and freshly fetched coordinates retain their individual timestamps and
states.

## Errors and partial results

Invalid App Store IDs, invalid or empty storefront selections, more than 25
storefronts, unsupported storefront codes, and malformed comparison currencies
fail before network work begins.

After validation, provider failures are represented per storefront and per
evidence source. One failed component must not discard successful results for
the others. An assembled result includes a deterministic result entry for
every requested storefront and reports two separate aggregate axes.

`evidenceCoverage` describes the current values returned, whether they came
from cache or this attempt:

- `satisfied`: every requested base and visible-row component has current or
  retained source evidence;
- `partial`: at least one component has source evidence and at least one is
  unavailable; or
- `unavailable`: no requested component has source evidence.

`refreshOutcome` describes only provider work for this call:

- `not_attempted`: cache-only mode or a fresh cache hit made no provider
  request;
- `succeeded`: every attempted component produced a non-`unavailable` evidence
  state;
- `partial`: attempted components include both success and failure; or
- `failed`: every attempted component failed.

A component on these axes means Apple base-price or visible-row evidence.
Optional ECB conversion does not change either axis; its availability and
warnings are reported separately.

A failed refresh may therefore return `satisfied` retained evidence with a
`failed` refresh outcome. Cached evidence can be `satisfied` with
`not_attempted`; neither case is mislabeled as a failed comparison.

Stable error categories include:

- `network_unavailable`;
- `rate_limited`;
- `provider_unavailable`;
- `source_format_changed`;
- `response_too_large`;
- `field_too_large`; and
- `store_unavailable`.

Preflight validation also distinguishes `invalid_storefront_count` from
`duplicate_storefront`. Both occur before cache reads or network work and make
zero writes.

`not_available`, `none_visible`, and `not_applicable` are evidence states, not
generic transport errors. Cancellation remains cancellation and must not be
rewritten as a provider failure.

Observed but unparseable values count as source evidence for
`evidenceCoverage` and as a successful fetch for `refreshOutcome`; they do not
become numeric comparison values. `price_unparseable`, `currency_unknown`,
`fx_unavailable`, and `conversion_overflow` are structured data warnings, not
latest-attempt provider errors. They do not change either aggregate axis;
callers inspect the warning and the affected value's absent amount or
conversion while retaining the exact evidence that was available.

Error DTOs and logs must contain bounded, redacted classifications. They must
not persist response bodies, raw HTML, credentials, cookies, arbitrary server
messages, or user-entered text. HTTP status may be retained when useful, but a
response body must not be used as a display error.

Truncation is always explicit:

- request validation rejects a raw array with more than 25 storefront values
  and rejects semantic duplicates after normalization rather than silently
  dropping either;
- a visible-row result sets `truncatedByClient` when OpenASO applies its
  20-row cap; and
- source coverage remains `public_visible_subset` whether or not client
  truncation occurred.

## Privacy and security

Pricing v1 uses public, unauthenticated Apple and ECB endpoints only. It must
not send App Store Connect credentials, Apple Ads credentials, browser session
cookies, or Apple Account data.

Network implementations must:

- construct Apple URLs from validated App Store IDs and storefronts rather
  than accept arbitrary caller URLs;
- use HTTPS and restrict redirects to the expected public provider hosts;
- use the shared provider request gate, finite timeouts, bounded response
  sizes, bounded parser work, and cooperative cancellation;
- reject oversized or structurally ambiguous content instead of recursively
  scanning an unbounded object graph; and
- avoid logging app portfolios, product names, local display prices, response
  bodies, or selected storefront sets as analytics properties.

Persisted pricing evidence remains in the local SwiftData store. Raw public
HTML and raw provider JSON are transient and must not be persisted. Export and
MCP surfaces return only the bounded pricing contract, not raw source content.

## Acceptance criteria

### Schema and migration

- A new schema version is appended through the existing migration plan; no
  prior version is edited in place.
- The migration fixture proves all pre-pricing entities survive and initializes
  pricing storage empty.
- Current observations are uniquely keyed by App Store ID and storefront.
- The pricing cache is not owned by `TrackedApp`; tracked-app deletion leaves
  global public evidence intact, while explicit cache clearing removes it.
- The schema supports deterministic retention with `lastAccessedAt`, a hard
  2,000-coordinate cap, a hard 40,000-child-row cap, seven-day failure-only
  expiry, and 90-day retained-success expiry.
- Base price, visible rows, provenance, coverage, latest-attempt state, and
  truncation are queryable fields rather than one opaque whole-result blob.
- Exact source amounts and FX rates are not stored as `Double` source-of-truth
  values.
- Replacing or deleting a current observation removes its owned visible rows
  without deleting unrelated app data.
- The model cannot represent a successful visible-row result as a complete
  catalog.

### Service API and data sources

- The public request type enforces one app and a raw array of 1 to 25 explicit
  storefront values, then rejects duplicates after normalization.
- Request and result values are `Sendable`; SwiftData models do not cross actor
  boundaries.
- Cached reads, refresh-if-stale, and force-refresh behavior are explicit.
- Fetch, parse, and persist phases are cancellable and generation-safe.
- Provider fan-out is bounded and uses the shared request gate.
- Base price and visible rows have independent states and provenance.
- `evidenceCoverage` and `refreshOutcome` are independent and cache hits never
  appear as refresh failures.
- Partial success retains successful components and reports failed ones.
- Failed refreshes preserve earlier evidence and expose its stale state.
- ECB conversion tests cover EUR pivot math, missing currencies, stale rates,
  malformed rates, zero values, rational intermediate math, eight-place
  half-even rounding, overflow, same-currency values, and provenance.
- Parser fixtures cover free apps, paid apps, no visible rows, ambiguous page
  sections, normally absent purchase sections, both recognized section types,
  section and row order, preserved identical-looking rows, locale formatting,
  unknown currency, changed source shape, oversized fields and responses, and
  the shared 20-row cap.
- Cache tests cover both hard caps, read- and write-time hard expiry, mixed
  component expiry, one-hour access-time coalescing, no revival at 90 days,
  deterministic LRU ties, active-request protection, owned-row deletion,
  atomic no-space failure, bookkeeping that does not change evidence time, and
  atomic clear.
- Request tests reject zero or 26 raw storefront values and reject `US` plus
  ` us ` as a duplicate before cache or provider work.
- No service output contains tax, proceeds, inferred cadence, or name-based
  cross-store product matches.

### UI

- The user explicitly selects 1 to 25 storefronts before fetching; there is no
  hidden all-storefront expansion.
- Base app price and publicly visible purchase rows are separate sections.
- The UI says visible rows may be incomplete, including when none are visible.
- Exact local display price is primary. Any converted value is secondary and
  says "Approx." with comparison currency and ECB rate date available in
  context.
- Cached, stale, unavailable, partial, and truncated states are distinguishable
  without relying on color alone.
- Retained evidence coverage and the latest refresh outcome are displayed
  separately.
- A failed refresh does not replace retained evidence with an empty state.
- The UI does not label visible rows as plans or subscriptions, infer cadence,
  show tax-adjusted values, estimate proceeds, or pair rows across storefronts.
- VoiceOver conveys storefront, local price state, freshness, coverage, and FX
  qualifier.

### MCP

- The read-only tool is named `compare_app_pricing` and returns contract version
  `pricing_v1`.
- `app_store_id` and `storefronts` are required; the raw array contains 1 to 25
  values and values must be distinct after trimming and lowercasing. Duplicate
  values are rejected, not silently collapsed. An omitted array never means
  all storefronts.
- `comparison_currency` is optional and defaults to USD.
- Results use the same service and semantics as the UI, in deterministic
  storefront and source-row order.
- Each result includes exact local evidence, source/fetch provenance, coverage,
  freshness, truncation, `evidenceCoverage`, `refreshOutcome`, structured data
  warnings, and structured partial errors.
- Converted values include the ECB rate date and approximate-reference
  qualifier; absent FX leaves local evidence intact.
- Output is bounded by 25 storefronts, one base-price entry per storefront, and
  at most 20 visible rows per storefront.
- The tool performs no tracked-app, keyword, credential, or remote account
  mutation. Updating the local current-evidence cache is an internal read-path
  optimization, not a workspace configuration mutation.
- Tool descriptions and DTO field names contain no completeness, tax,
  proceeds, cadence, or cross-store identity claims.

## Consequences

This contract delivers a narrower comparison than a private App Store Connect
integration could provide. It is intentionally honest about public-source
limits, remains useful without credentials, and gives later implementations a
stable boundary for persistence, UI, and MCP behavior.

Pricing history, account-backed catalog data, authoritative product IDs,
future schedules, tax treatment, and proceeds require separate sources,
privacy review, and versioned decisions. They cannot be added by silently
expanding `pricing_v1`.

[apple-product-page]: https://developer.apple.com/app-store/product-page/
[apple-promoted-iap]: https://developer.apple.com/app-store/promoting-in-app-purchases/
[ecb-rates]: https://data.ecb.europa.eu/key-figures/ecb-interest-rates-and-exchange-rates/exchange-rates
[ecb-api]: https://data.ecb.europa.eu/help/api/data
[wip-pricing-commit]: https://github.com/akshaynexus/OpenASO/commit/5de98ea762221b9b61cdb452cc9a31113e66057d
