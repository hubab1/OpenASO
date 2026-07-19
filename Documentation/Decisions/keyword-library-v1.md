# Keyword Library v1 Contract

- Status: Proposed
- Date: 2026-07-19
- Scope: Public product and service contract; no implementation is included

## Summary

OpenASO will call this feature the **Keyword Library**. It is a local,
add-only collection of reusable keyword terms. A library entry has no app,
storefront, or platform scope until a user explicitly previews and applies it.

Applying entries is also add-only. It may create missing keyword tracks for an
explicit list of entries, tracked apps, storefronts, and exactly one platform.
It never edits or removes an existing track, targets an implicit "all" scope,
starts a refresh, or synchronizes the library elsewhere.

This intentionally narrow first version establishes a safe contract that the
native UI, persistence service, and any later MCP surface must share.

The words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** below describe
requirements for implementations of this contract.

## Context

A reusable list avoids re-entering the same terms for several apps and
storefronts. Calling that list "global" is misleading: the terms do not have
global App Store meaning, and a global action can imply an unsafe fan-out to
every app and storefront.

Two commits in the upstream WIP pull request informed this decision:

- [`ee8c34e`](https://github.com/akshaynexus/OpenASO/commit/ee8c34e0f7ac77b3d87811c12668ac994afb5b6c)
  made reusable terms storefront-agnostic and stopped refreshes from silently
  adding them to apps.
- [`9da616b`](https://github.com/akshaynexus/OpenASO/commit/9da616b88cc0fe2d48d846965289f31f521f5c51)
  explored a central manager and an apply workflow.

This contract is an independent redesign. It keeps the useful reusable-term
and explicit-apply concepts, but rejects the WIP's apply-to-all, replace,
reset, delete, and large Cartesian fan-out semantics. The source links record
that design history; they do not imply shared authorship of this document or a
future implementation.

## Terminology

- **Library entry**: one immutable reusable term with a stable UUID.
- **Apply scope**: explicit entry IDs, tracked-app generations, storefront
  codes, and one platform.
- **Candidate row**: one entry x one app x one storefront x the selected
  platform.
- **Preview**: a read-only, state-sensitive classification of every candidate
  row.
- **Apply operation**: the durable, resumable execution of one accepted
  preview.
- **App generation**: an App Store ID plus an immutable generation UUID.
  Deleting and re-adding the same App Store ID creates a different target.
- **Track generation**: an immutable scalar snapshot of the existing v1 track
  identity plus a generation UUID. Deleting and re-adding the same track creates
  a different target.

## Library contract

### Local and durable

- Entries and apply-operation checkpoints MUST remain on the user's device.
- They MUST use versioned, durable persistence so an operation can resume
  after relaunch. "Local" does not mean an unversioned preferences blob.
- Library work depends on preserve-in-place store opening and migration. If the
  existing store cannot open or migrate, OpenASO MUST leave it untouched,
  surface a recoverable `storeUnavailable` error, and perform zero library
  writes. It MUST NOT delete, recreate, or silently replace the store with an
  empty one.
- OpenASO MUST NOT upload or synchronize the library through iCloud, an
  OpenASO service, analytics, or another implicit channel.
- Adding an entry MUST NOT make an Apple or third-party network request.

### Add-only entries

- A v1 entry contains a stable UUID, the display term, its library-normalized
  term key, signed 64-bit creation microseconds, and the bounded structured
  source provenance defined below.
- Terms MUST be trimmed, non-empty, and at most 200 UTF-8 bytes.
- Duplicate library identity uses the library-only normalization below. Letter
  case and surrounding whitespace alone MUST NOT create a second entry.
- Entry identity MUST use a UUID or another structured key. It MUST NOT depend
  on joining user-controlled text with a delimiter.
- One add request may contain at most 25 terms. The local library may contain
  at most 200 unique entries.
- Adding a term that already exists is a successful no-op that returns the
  existing entry ID. Repeating the same request is therefore idempotent.
- V1 MUST NOT offer entry update, replace, archive, delete, or reset. A later
  contract may add non-destructive lifecycle controls after their history and
  provenance behavior is specified.

Keyword identity uses the versioned `openaso_keyword_identity_v1` algorithm,
based on [Unicode 15.1.0][unicode-15-1] data bundled with the implementation:

1. Validate a well-formed Unicode scalar sequence and normalize it to NFC.
2. Remove leading and trailing scalars with the Unicode 15.1.0 `White_Space`
   property. The result is the display term.
3. Apply Unicode 15.1.0 full default case folding using `CaseFolding.txt`
   common and full mappings, excluding Turkic-specific mappings.
4. Normalize the folded result to NFC. The result is the normalized term key.

Both results MUST be non-empty and no more than 200 UTF-8 bytes. Native, MCP,
and import library paths MUST call this same bundled implementation rather than
a client-specific lowercase function.

### Entry source provenance

Entry provenance has exactly two immutable scalar fields and this logical JSON
shape. The `importBatchID` property is always present:

```json
{
  "importBatchID": null,
  "kind": "nativeManual"
}
```

`kind` is exactly one of `nativeManual`, `csvImport`, or `plainTextImport`.
`nativeManual` requires `importBatchID` to be `null`; either import kind
requires a non-null, service-generated UUID in lowercase 8-4-4-4-12 form. An
import coordinator creates one batch UUID and may reuse it across several
atomic requests when an import contains more than 25 terms. It MUST NOT derive
the UUID from a path, filename, term, timestamp, or other user-controlled text.

The add service receives exactly one trusted provenance descriptor for the
whole request. The native manual workflow supplies `nativeManual`; the two
import adapters supply their matching kind and batch UUID. The public add
boundary does not accept arbitrary provenance strings, paths, filenames, URLs,
or caller-selected enum raw values. A future source kind requires a new
contract version; an unknown persisted raw value is `storeUnavailable`, not an
"other" bucket.

Every unique absent key inserted by a request receives that request's
provenance. The first occurrence of a duplicated normalized key still supplies
the display term; later `duplicateInRequest` results reference that same
planned entry and provenance. `alreadyExisting` never rewrites provenance and
returns the existing entry's provenance. If concurrent requests with different
sources race for the same absent key, the transaction that commits the unique
entry owns its immutable provenance and every loser re-resolves it as
`alreadyExisting`. Entry list responses expose only these bounded fields.

This algorithm is intentionally library-only. It MUST NOT rewrite existing
`KeywordQuery.queryKey` or `TrackedAppKeyword.identityKey` values, change their
v1 normalization helpers, or merge rows that collide under the new library
normalization. Library normalization is not query or track identity.

For each candidate, preview calls the unchanged v1 `KeywordQuery.makeQueryKey`
and `TrackedAppKeyword.makeIdentityKey` factories with the immutable entry
display term and explicit scope. It materializes their exact opaque outputs as
`queryKeySnapshot` and `trackIdentityKeySnapshot`; neither key is parsed. Each
snapshot MUST be non-empty and no more than 1,600 UTF-8 bytes, or preview fails
as `invalidSelection` without a digest. Both snapshots are included in the
digest and returned candidate. Apply persists them in the accepted plan. Native
and MCP digest code consumes these materialized snapshots rather than
independently reproducing Foundation normalization.

An add request is atomic. The service validates and normalizes every input,
then deduplicates normalized keys within the request before reading capacity or
writing. The first input occurrence supplies the display term. Each later
occurrence of that key is `duplicateInRequest` and references the same entry
ID. Existing library keys are `alreadyExisting`; absent keys are `inserted`.

Capacity is checked in the same serialized write transaction as insertion:

```text
current unique entries + unique absent request keys <= 200
```

If the equation would exceed 200, the request returns
`libraryCapacityExceeded` with zero writes and no partial result. Otherwise all
new entries and the result mapping commit together. For a successful request:

```text
inputCount = inserted + alreadyExisting + duplicateInRequest
```

## Explicit apply scope

Every preview and apply request MUST provide all of the following:

- 1 to 25 distinct library entry IDs;
- 1 to 20 distinct tracked-app generations;
- 1 to 20 distinct two-letter App Store storefront codes; and
- exactly one supported platform.

The service MUST normalize storefronts to lowercase and validate every entry,
app generation, storefront, and platform before producing a preview. Missing,
empty, duplicated, or malformed scope values are errors rather than defaults.
Every selected entry ID MUST resolve before candidate expansion. A missing or
stale entry makes the whole preview request `invalidSelection` and returns no
digest; v1 has no entry deletion and therefore needs no entry tombstone.

A well-formed app generation that no longer resolves is represented as an
`invalidTarget` preview row so the stale app selection remains visible.

The candidate count is:

```text
selected entries x selected app generations x selected storefronts
```

It MUST be no greater than 400. This limit applies before filtering candidates
that already exist. Requests over the limit MUST fail atomically and MUST NOT
be truncated.

A UI may provide selection conveniences, but the submitted scope MUST contain
the resolved IDs and codes. There is no wildcard, omitted-value default,
"current selection," "all apps," or "all storefronts" interpretation in the
service contract.

## Preview contract

Preview is required before apply. It MUST perform no mutation, refresh, or
network request.

For every candidate row, preview returns one of:

- `wouldAdd`: the exact keyword track does not exist;
- `alreadyExists`: the exact keyword track already exists; or
- `invalidTarget`: the selected app generation is no longer current.

The preview also returns exact totals for selected entries, apps, storefronts,
candidates, rows that would be added, existing rows, and invalid targets. Rows
MUST be ordered by numeric App Store ID, lowercase app-generation UUID,
storefront ASCII bytes, platform raw-value ASCII bytes, normalized-term UTF-8
bytes from the persisted library snapshot, and lowercase entry UUID. Locale
collation MUST NOT affect ordering.

### Immutable generations and timestamps

The feature MUST introduce additive v-next app-generation and
track-generation sidecar models. It MUST NOT add properties, relationships, or
inverse relationships to the frozen `OpenASOSchemaV1.TrackedApp` or
`OpenASOSchemaV1.TrackedAppKeyword` declarations, or change the v1 schema's
model metadata. A sidecar contains scalar snapshots only and has no model
relationship to a v1 row:

- an app sidecar stores App Store ID, generation UUID, and signed 64-bit
  creation microseconds; and
- a track sidecar stores exact opaque v1 query-key and track-identity-key
  snapshots, structured App Store ID/storefront/platform snapshots, generation
  UUID, and signed 64-bit creation microseconds.

The opaque key snapshots are not library-normalized and MUST NOT be parsed.
Their structured companion fields come from the v1 row itself; the full track
key snapshot permits an exact row lookup without interpreting delimiters.

Every sidecar field is immutable after initialization. Migration creates
exactly one sidecar for each existing v1 app and track. It copies the track's
persisted query and identity keys byte-for-byte without parsing, normalizing, or
asking the current factories to reproduce them; validates only the existing
scalar fields and object ownership; and assigns its UUID and timestamp snapshot
once. After migration, a missing, duplicate, or scalar/key-mismatched sidecar
for a live v1 row is a store invariant failure: opening the feature returns
`storeUnavailable` without lazily inventing a replacement generation.

After migration, every production create and delete of a tracked app or keyword
track MUST pass through the same serialized lifecycle coordinator used by apply.
It creates or removes the v1 row and scalar sidecar in one transaction. A
delete/re-add receives a fresh sidecar UUID even when all visible scalar values
are identical. Direct mutation of a v1 canonical identity is outside this
contract and MUST NOT be used to evade generation rotation; a future
identity-changing workflow must specify and perform an atomic old-generation to
new-generation transition through the coordinator.

The generation values used by this contract are:

- app generation: sidecar App Store ID plus app-generation UUID; and
- track generation: sidecar opaque and structured identity snapshots plus
  track-generation UUID.

Creation time is audit and digest evidence, not the generation identity. Its
canonical external value is a base-10 string matching `0|[1-9][0-9]*`, with no
sign, decimal point, exponent, or leading zero.

For a legacy v1 `Date`, migration treats its Unix-seconds IEEE 754 binary64 bit
pattern as an exact binary rational, multiplies that rational by 1,000,000, and
rounds once to the nearest integer with ties to even. A non-finite, negative, or
out-of-`Int64` value fails migration without replacing the existing store. The
sidecar integer is thereafter the only digest input; clients MUST NOT reconvert
a floating date or format a date string.

### Deterministic digest

Every preview MUST include a digest that binds an apply request to the exact
scope and relevant local state that was reviewed.

The logical digest payload has exactly this schema. Properties shown as `null`
MUST be present rather than omitted.

```json
{
  "appGenerations": [
    {
      "appStoreID": "123456789",
      "createdAtUnixMicroseconds": "1750000000000000",
      "generationID": "10000000-0000-4000-8000-000000000001"
    }
  ],
  "candidates": [
    {
      "acceptedDisposition": "alreadyExists",
      "appGenerationID": "10000000-0000-4000-8000-000000000001",
      "appStoreID": "123456789",
      "entryID": "20000000-0000-4000-8000-000000000001",
      "existingTrackGeneration": {
        "createdAtUnixMicroseconds": "1750000000000002",
        "generationID": "30000000-0000-4000-8000-000000000001",
        "identity": {
          "appStoreID": "123456789",
          "platform": "iphone",
          "queryKeySnapshot": "focus timer::us::iphone",
          "storefront": "us",
          "trackIdentityKeySnapshot": "123456789::focus timer::us::iphone"
        }
      },
      "libraryNormalizedTerm": "focus timer",
      "platform": "iphone",
      "queryKeySnapshot": "focus timer::us::iphone",
      "storefront": "us",
      "trackIdentityKeySnapshot": "123456789::focus timer::us::iphone"
    }
  ],
  "contractVersion": "keyword_library_v1",
  "entries": [
    {
      "createdAtUnixMicroseconds": "1750000000000001",
      "entryID": "20000000-0000-4000-8000-000000000001",
      "libraryNormalizedTerm": "focus timer"
    }
  ],
  "platform": "iphone",
  "storefronts": ["us"]
}
```

For `wouldAdd` and `invalidTarget`, `existingTrackGeneration` is `null`. For
`alreadyExists`, it is the exact immutable track generation observed by
preview. Entries sort by `libraryNormalizedTerm` UTF-8 bytes then entry UUID.
App generations sort by numeric App Store ID then generation UUID. Storefronts
use ascending ASCII-byte order; candidates use the preview row order above.

An app generation's `createdAtUnixMicroseconds` is its persisted value when
that exact generation resolves and is `null` when the submitted generation is
stale. The property is present in both cases. The stale row still binds the
submitted App Store ID and generation UUID without inventing a tombstone or
trusting caller-supplied creation evidence.

All UUIDs use lowercase 8-4-4-4-12 text. App Store IDs are positive signed
64-bit integers represented by strings matching `[1-9][0-9]*`. Every non-null
Unix-microsecond value is a non-negative signed 64-bit integer represented by a
string matching `0|[1-9][0-9]*`. Neither numeric value may exceed
`9223372036854775807`; using JSON strings prevents precision changes.
Storefronts match `[a-z]{2}`, and platform is exactly `iphone`, `ipad`, or
`mac`. Every
`existingTrackGeneration.identity` field MUST equal the corresponding
candidate field. Every `libraryNormalizedTerm` is the persisted output of
`openaso_keyword_identity_v1`. Each opaque key snapshot is a non-empty UTF-8
string of at most 1,600 bytes. Digest producers MUST consume the candidate
snapshots materialized by the local preview service rather than recompute or
parse either key. `acceptedDisposition` is exactly `wouldAdd`, `alreadyExists`,
or `invalidTarget`.

The payload is serialized with the [RFC 8785 JSON Canonicalization
Scheme][rfc-8785], including its property sorting and JSON string escaping, and
then encoded as UTF-8. JCS does not normalize Unicode; every persisted and
candidate library term MUST already satisfy the Unicode rules above. Opaque v1
key snapshots retain their factory-produced scalar sequence exactly and MUST
NOT be Unicode-normalized by a digest producer. JSON floating point values,
non-finite values, optional extra properties, and implementation-specific
escaping are forbidden.

The digest is SHA-256 of those canonical UTF-8 bytes. Its external form is
`sha256:<64 lowercase hexadecimal characters>`. Display terms,
locale-dependent labels, caller array ordering, preview time, and result counts
MUST NOT affect the payload.

Native and MCP implementations MUST share fixed byte-for-byte JCS and digest
fixtures. Fixtures include non-ASCII terms, composed and decomposed Unicode,
distinct library and opaque v1 key snapshots, JSON escaping, the
microsecond rounding boundary, maximum IDs, `null` track generation, and every
disposition. Reordering equivalent input MUST produce the same bytes and
digest; changing the persisted library term, either opaque key, target
generation, storefront, platform, existing-track generation, or disposition
MUST change it.

The digest is an integrity value, not an authorization token or secret. Apply
uses it together with the submitted scope and idempotency identity as defined
below.

## Apply and resume contract

An apply request that starts an operation MUST contain:

- `contractVersion` equal to `keyword_library_v1`;
- `intent` equal to `start`;
- the complete explicit scope: entry IDs, app generations, storefronts, and
  platform;
- the accepted preview digest;
- an idempotency namespace; and
- a caller-generated idempotency key.

The digest never stands in for its scope. Apply normalizes and validates the
submitted scope under the same limits as preview. It MUST NOT recover scope
from UI state, a cached preview object, or the digest.

An idempotent replay of a `start` request is status-only. It returns the
existing operation, counters, and committed results after the idempotency
comparison below, but MUST NOT claim the executor, run another batch, change
state, or act as consent to resume. Only the request that atomically creates a
new operation may continue directly into its first execution.

Resume is a separate local service intent with exactly this request shape:

```json
{
  "contractVersion": "keyword_library_v1",
  "intent": "resume",
  "operationID": "40000000-0000-4000-8000-000000000001"
}
```

`operationID` is a lowercase UUID for a persisted operation. A resume request
contains no scope, preview digest, namespace, or caller idempotency key; it uses
the operation's immutable accepted plan. The native UI may issue it only from
an explicit user action on that operation. V1 exposes no write-enabled MCP
resume tool. A malformed or unknown ID is `operationNotFound` with zero writes.
The raw caller key is neither needed nor reconstructed after relaunch.

For persistence and idempotency comparison, canonical scope has exactly this
logical JSON schema:

```json
{
  "appGenerations": [
    {
      "appStoreID": "123456789",
      "generationID": "10000000-0000-4000-8000-000000000001"
    }
  ],
  "contractVersion": "keyword_library_v1",
  "entryIDs": ["20000000-0000-4000-8000-000000000001"],
  "platform": "iphone",
  "storefronts": ["us"]
}
```

Entry IDs sort by the ASCII bytes of their lowercase UUID text. App generations
sort by numeric App Store ID then lowercase generation UUID. Storefronts sort
by ascending ASCII bytes. All values use the same canonical spellings and
ranges as the digest payload. The service persists the RFC 8785 JCS bytes of
this object and compares those bytes for an idempotency replay. Caller array
order therefore has no effect, and no unresolved UI or object identity enters
the comparison.

### Idempotency identity

The namespace is 1 to 64 lowercase ASCII bytes from `[a-z0-9._-]`. The key is
1 to 128 ASCII bytes from `[A-Za-z0-9._~-]`. Empty, oversized, non-ASCII, and
control-containing values are `invalidSelection`. The native app uses the
namespace `openaso.native`; a future write-enabled integration uses a stable,
documented namespace rather than a process or connection ID. A namespace is a
collision domain, not authentication.

OpenASO stores only this domain-separated digest of the caller value:

```text
SHA-256(
  ASCII("openaso.keyword-library.apply.v1") || 0x00 ||
  ASCII(namespace) || 0x00 || ASCII(key)
)
```

The stored form is `sha256:<64 lowercase hexadecimal characters>` and is
unique. The allowed alphabets exclude `0x00`, so the encoding is unambiguous.
Raw namespace and key values MUST NOT be persisted, logged, or emitted in
analytics.

### Store-wide writer coordination

The per-process lifecycle coordinator is only the in-process serialization
layer. A Swift actor turn MUST NOT be treated as a lock whose ownership
survives an `await`. Asynchronous preparation, operation-lock acquisition, and
retry backoff occur outside its mutation turn. Each mutation attempt enters one
isolated coordinator method that performs no suspension, tries the store-wide
lock, completes at most one fresh-context transaction when the lock is
available, releases it, and returns an immutable attempt result.

Every process that opens the persistent workspace, including the native app,
its loopback server, and every separately launched `--mcp-stdio` process, MUST
also use one OS-backed exclusive writer lock derived from the canonical
persistent-store URL. The lock uses a dedicated non-secret lock file beside the
store, has no user-controlled path component, and is held through an open file
descriptor so the operating system releases it if the owner exits or crashes.
It MUST NOT be implemented as a persisted Boolean or by creating, deleting,
renaming, or replacing a SwiftData store artifact.

Store opening and migration, and every production transaction that mutates the
workspace, MUST acquire this same cross-process lock. This includes existing
native and MCP paths that create or delete apps or tracks, library writes,
sidecar and origin writes, apply checkpoints, imports, refresh persistence, and
future writers. Read-only preview and list operations do not acquire the writer
lock.

An ordinary mutation attempt, including an operation-creation attempt, orders
its critical sections as per-process coordinator then store-wide writer lock.
The creation transaction commits the new operation as `planned`, releases both
critical sections, and only then may the caller that inserted it acquire the
operation lock. A status-only start replay uses the creation ordering and never
acquires the operation lock. Resume acquires the operation lock before entering
the coordinator. While an executor holds that lock, every state transition and
batch attempt orders its critical sections as operation lock, per-process
coordinator, then store-wide writer lock. No coordinator method or writer
transaction waits for an operation lock, performs retry backoff, or suspends.

One locked mutation attempt creates a fresh `ModelContext`, begins the complete
read-validate-write transaction, saves or rolls it back, discards that context,
and then releases the lock. Apply releases the lock between committed batches;
each later batch re-resolves current generations and identities after acquiring
it again. It never holds a SwiftData transaction open while waiting for the
cross-process lock.

Lock contention and retryable store conflicts use one shared cancellable retry
policy in the app and stdio runtime: at most eight total attempts, with delays
of 25, 50, 100, 200, 400, 800, and 1,000 milliseconds before the seven
attempts after the first. Cancellation stops before the next attempt. A retry
starts only after the prior coordinator turn has ended and the asynchronous
delay has completed. It repeats the entire transaction from a fresh context and
fresh reads; it does not replay captured model objects or a partial write set. A
unique-constraint race is re-resolved semantically, so a concurrently inserted
track becomes `alreadyExisting` and a concurrently inserted library key becomes
`alreadyExisting`, rather than leaking a constraint error. Exhausted contention
or retryable conflicts return `persistenceFailed` with bounded classification
`writerContention`. No cleanup or best-effort state mutation is attempted after
exhaustion: checkpoint, counters, state, and persisted failure classification
remain exactly as last committed. If `planned`, `paused`, or `cancelled` has not
yet transitioned to `running`, it remains in that prior state. If the durable
state was already `running`, it remains `running`; the executor releases its
operation lock, and only a later explicit resume that acquires the now-free
operation lock performs the orphan-recovery transition described below.

Database uniqueness constraints and the database engine's own locking remain
defense in depth. They do not replace this protocol. Conformance tests MUST run
native-style and stdio-style writers in separate processes and prove that
capacity, idempotency, sidecar atomicity, candidate outcomes, and checkpoints
remain correct under races and owner-process termination.

### Starting an operation

Within each process, all library, tracked-app lifecycle, sidecar, and track
writes MUST pass through one process-wide lifecycle coordinator backed by one
`BackgroundModelStore`.
For a `start` request, one non-suspending creation attempt under the coordinator
and writer lock performs these steps in order:

1. Validate scope, limits, digest syntax, namespace, and key.
2. Resolve the idempotency digest.
3. If an operation already owns that digest, require the same contract version,
   canonical scope, and preview digest, then return its current durable status
   without recomputing preview or executing work. Any difference is
   `idempotencyConflict`.
4. Otherwise recompute the preview from the submitted scope inside this same
   transaction and require its digest to match. A mismatch is
   `previewOutOfDate` with zero writes.
5. Reject any accepted `invalidTarget` row as `invalidSelection` with zero
   writes.
6. Persist the new operation in `planned` state and persist every ordered
   accepted candidate, including its accepted disposition, opaque key
   snapshots, and existing-track generation, before committing.

The operation's canonical scope, digest, ordered plan, accepted dispositions,
opaque key snapshots, and accepted generations are immutable after this commit.
Persisting them allows replay after earlier batches have legitimately changed
current preview state.

### Durable operation states and execution ownership

The persisted operation state is exactly `planned`, `running`, `paused`,
`cancelled`, `completed`, or `completedWithTargetChanges`. There is no implicit
resume-on-read state. Allowed transitions are:

```text
new -> planned
planned -> running
running -> running | paused | cancelled | completed | completedWithTargetChanges
paused -> running
cancelled -> running
```

`completed` and `completedWithTargetChanges` are terminal. No other transition
is valid. The start call that inserted the operation is itself the explicit
action that may acquire its operation lock after the creation transaction
commits and transition `planned -> running`. No other `start` request may do
so. After that call returns or is interrupted, only the separate `resume`
intent may transition `planned`, `paused`, or `cancelled` to `running`.
Resuming a terminal operation is a successful status-only no-op.

One executor holds an OS-backed operation lock, derived from the canonical
store URL and operation ID, for the entire multi-batch execution. The creating
start call tries that lock only after its creation coordinator turn and writer
transaction have ended; resume tries it before entering the coordinator. Every
post-creation mutation therefore follows operation lock, per-process
coordinator, then store-wide writer lock. If another process holds the operation
lock, start or resume returns `operationInProgress` and the durable status
without doing work.

Because the operating system releases the operation lock on process death, a
resume request that acquires it while the persisted state is `running` uses
coordinator-and-writer attempts to commit `running -> paused` with bounded
failure classification `interrupted`, then `paused -> running`, before it
executes another batch. If either transition exhausts the retry policy, the
last-committed-state rule above applies and no batch runs. A status-only start
replay never acquires the operation lock and never performs this recovery.

The executor changes state and any bounded failure classification in the same
store-wide locked transaction as the corresponding checkpoint. Each committed
non-final batch remains `running`. A transaction that detects identity
incompatibility writes no candidate effects and commits `running -> paused`
with `identityCompatibilityChanged`, without advancing counters. Retry
exhaustion follows the last-committed-state rule above and MUST NOT be reported
as a durable pause. Cancellation changes `running -> cancelled` only when that
transition commits under the writer lock; cancellation during lock backoff
leaves the last committed state unchanged. Completion changes `running` to the
applicable terminal state in the transaction that commits the final result.
Operation state raw values and failure classifications are persisted enums,
not localized strings.

Every later batch re-resolves app and track generations and writes created
tracks and their sidecars, shared queries, append-only row results, provenance,
and the next checkpoint in one serialized transaction. Unique constraints on
entry key, current sidecar identity, track identity, idempotency digest, and
`(operationID, candidateOrdinal)` are a second line of protection, not a
substitute for serialization.

### Candidate execution

- Candidate rows execute in accepted deterministic order.
- A persistence transaction contains at most 25 candidate rows.
- Before resolving a row, apply regenerates its full query and track identity
  keys from the immutable entry display term and candidate scope through the
  unchanged v1 factories, then exact-compares both with the accepted opaque
  snapshots. It never parses a key. A mismatch on a resumed operation rolls
  back and pauses the batch with `identityCompatibilityChanged`; it does not
  rewrite the accepted plan or recompute it as a new preview.
- The service resolves or creates a shared `KeywordQuery` in the same
  transaction as a newly created track and sidecar, using the exact accepted
  keys after that comparison.
- An accepted `wouldAdd` row creates a track only when its app generation is
  still current and no exact track exists. If the track now exists, the row is
  `alreadyExisting` and the existing track remains unchanged.
- An accepted `alreadyExists` row MUST NEVER create a track. If the exact
  accepted track generation still exists, the row is `alreadyExisting`. If it
  is missing or replaced, the row is `targetChanged`.
- Any deleted or replaced app generation produces `targetChanged` and receives
  no track.
- Existing tracks keep their notes, history, status, timestamps, generation,
  and provenance unchanged.
- Retrying after a process failure starts from the durable checkpoint and
  cannot overwrite an append-only result for an earlier ordinal.

`targetChanged` is a row outcome, not an operation error. For accepted
candidate count `N`, the durable counters always satisfy:

```text
processed = added + alreadyExisting + targetChanged
remaining = N - processed
0 <= checkpoint = processed <= N
```

An operation with `remaining == 0` is `completed` when `targetChanged == 0`
and `completedWithTargetChanges` otherwise. An operation with unprocessed rows
is `planned`, `running`, `paused`, or `cancelled`, never fully successful.

### Cancellation and failures

The service MUST check cancellation before starting, before every batch, and
while preparing each row. Cancellation prevents the current uncommitted batch
from saving and retains earlier committed batches. It becomes `cancelled` only
when that state transition commits under the writer lock; otherwise the service
returns the exact last durable state and resume position. Resuming is always an
explicit user action.

Input, limit, and stale-preview errors occur before any write. A persistence
failure rolls back its whole batch and leaves the checkpoint at the previous
committed batch. It may report `paused` only when that transition was durably
committed under the writer lock; otherwise the last-committed-state rule
applies, including leaving an already-running operation as `running`. The
implementation MUST NOT silently skip a failed persistence batch, advance its
checkpoint, or report a best-effort state transition that was not persisted.

At minimum, callers can distinguish:

- `invalidSelection`;
- `selectionLimitExceeded`;
- `candidateLimitExceeded`;
- `previewOutOfDate`;
- `idempotencyConflict`;
- `operationNotFound`;
- `operationInProgress`;
- `identityCompatibilityChanged`;
- `cancelled`;
- `persistenceFailed`;
- `responseLimitExceeded`;
- `libraryCapacityExceeded`; and
- `storeUnavailable`.

Human-readable text may accompany these codes, but control flow MUST NOT
depend on parsing an error string.

## Add-only effects

Apply may create only the missing `TrackedAppKeyword` rows and their required
shared query rows.

V1 MUST NOT:

- edit, replace, merge, archive, reset, or delete any existing keyword track;
- delete ranking, metric, rating, or review history;
- change an existing track's notes, status, freshness, or provenance;
- add library entries that were not explicitly selected;
- expand to apps or storefronts that were not explicitly selected;
- infer a platform per app or apply to more than one platform;
- add tracks during app launch, refresh, scheduled work, or another unrelated
  workflow;
- begin ranking, popularity, metadata, rating, or review refresh work after
  apply; or
- retry failed work in the background without an explicit resume action.

After apply, the UI may offer a separate, ordinary refresh action. Accepting
that action is outside the apply operation and uses the existing refresh
limits and provider policies.

## Provenance and auditability

Provenance MUST be structured rather than inferred from free-form notes.

- A library entry's stable ID, normalized term, creation microseconds, and exact
  two-field source-provenance record are immutable. V1 provenance contains no
  path, filename, URL, free-form label, or unbounded string.
- An apply operation owns immutable accepted-candidate rows and append-only
  result rows. Its operation ID, idempotency digest, preview digest, canonical
  scope, accepted plan, and creation time never change.
- Only operation state, exact counters, checkpoint, and latest bounded failure
  classification are mutable, and checkpoint/counters move monotonically. The
  optional persisted classification is one enum raw value from `interrupted`,
  `writerContention`, `identityCompatibilityChanged`, `persistenceFailed`, or
  `cancelled`; it contains no localized or provider-supplied text.
- A result row is unique by `(operationID, candidateOrdinal)` and records the
  accepted disposition, final row outcome, entry ID, app generation, relevant
  track generation, preview digest, and application time. Once inserted it is
  never rewritten or reused for another attempt.
- The result track generation is the created or observed generation for
  `added` and `alreadyExisting`, and `null` for `targetChanged`. The immutable
  accepted candidate separately retains the previewed track generation.
- A newly created track receives an immutable lifecycle-owned scalar origin
  sidecar in the same transaction. It records the opaque v1 query and track-key
  snapshots, track generation, entry ID, operation ID, candidate ordinal,
  preview digest, and application time. It adds no relationship or inverse to
  the frozen v1 track model.
- An origin is uniquely identified in two independent ways: its track-generation
  UUID is unique, and its `(operationID, candidateOrdinal)` pair is unique. The
  database enforces both constraints. The matching result row has outcome
  `added` and exactly the same track generation, operation ID, and ordinal; the
  result, origin, track sidecar, and new track commit atomically.
- An already-existing track is reported in the operation result but receives
  no origin record and MUST NOT be relabeled as library-created.

Every creation or application time introduced by this feature is captured once
as a non-negative signed 64-bit Unix-microsecond integer and is never stored as
a floating `Date`. Its external spelling follows the decimal-string rule used
by the digest. Tests inject an integer clock; relaunch and MCP presentation read
the persisted integer and never reconvert wall-clock floating point.

The operation relationship owns its accepted-candidate and result rows with a
cascade delete rule. V1 exposes no operation, result, entry, or provenance
delete API. To delete a track, the serialized lifecycle coordinator resolves
its exact current track sidecar, then performs one indexed origin lookup by that
sidecar's track-generation UUID. Zero origins is valid for a legacy or otherwise
non-library-created track. One origin must match the sidecar snapshots and its
`added` result's operation ID and candidate ordinal. More than one origin, or a
mismatch, is `storeUnavailable`; deletion does not guess by parsing an opaque
key or scanning by entry. The coordinator deletes the resolved origin, track
sidecar, and v1 track in the same transaction. App deletion applies this rule to
each owned track. No inverse relationship performs this cleanup. It does not
delete library entries, apply operations, or append-only results. Result rows
retain scalar generations as audit evidence and do not own the track. Deleting
an operation, if a future retention contract permits it, must not cascade into
tracks, shared queries, ranking history, or entries. A deliberate
whole-workspace reset may remove all of these records.

Provenance survives relaunch and resume and is sufficient to explain which
explicit operation created a surviving track without retaining secrets or
relying on logs.

## Privacy and observability

Keyword lists may be commercially sensitive even though they are not
credentials.

- Raw terms, app names, bundle IDs, library contents, and full candidate plans
  MUST NOT appear in analytics events or routine logs.
- Logs SHOULD use operation IDs, bounded counts, durations, and stable result
  classifications.
- Crash and error reports MUST redact raw terms and local file paths.
- Preview and stored domain-separated idempotency digests may be durable
  operation fields under this contract, but MUST NOT enter routine logs or
  analytics. Raw idempotency namespaces and keys are never persisted or logged.
  None of these values is authorization material or replaces normal local/MCP
  authorization.
- Preview and apply perform no network requests, so provider request counts
  for both operations MUST remain zero.

Conformance fixtures use only deterministic synthetic terms, opaque keys,
idempotency inputs, IDs, paths, and timestamps created for the test suite. Raw
synthetic inputs MAY appear where a normalization, hashing, or escaping vector
requires them. Fixtures MUST NOT be captured, copied, or derived from a user's
workspace, logs, filesystem paths, credentials, or sessions. Golden analytics,
log, crash, and error outputs may contain bounded synthetic operation IDs,
counts, durations, and enum classifications. Every raw term, filesystem path,
idempotency namespace or key, credential, and session value is absent or
replaced by the fixed literal `<redacted>`; shortening a value does not satisfy
this rule. Golden assertions use distinctive sentinel values and prove that
neither a complete sensitive sentinel nor configured sentinel prefixes and
suffixes that would reveal truncation appear in the encoded output.

## MCP follow-up

The first MCP follow-up is read-only and uses the same library normalization,
materialized opaque key snapshots, preview, limits, ordering, and digest
implementation as the native app. It may expose:

- a paginated `list_keyword_library_entries` tool; and
- a read-only `preview_keyword_library_apply` tool with explicit scope.

Entry pages default to 50 and cap at 200 rows. Preview retains the 25-entry,
20-app, 20-storefront, and 400-candidate calculation limits, but returns
candidate pages that default to and cap at 50 rows. Candidate pagination does
not truncate the logical preview: the digest and totals always cover all rows.

The first preview page returns the full digest and totals, candidate ordinals
starting at zero, at most 50 ordered candidates, and an opaque next cursor when
rows remain. Every later page request MUST resubmit the identical complete
scope plus that cursor. The service recomputes the full read-only preview; the
cursor binds the prior contract version, digest, and next ordinal. A digest
change returns `previewOutOfDate` with no page, and a malformed, oversized, or
out-of-range cursor is `invalidSelection`. The cursor never supplies or
recovers omitted scope. Entry and preview cursors are at most 4,096 bytes.

Native code keeps each opaque key snapshot as its exact string. To make the MCP
wire size independent of JSON escaping, MCP candidates encode the exact UTF-8
bytes in unpadded [RFC 4648 base64url][rfc-4648] fields named
`queryKeySnapshotUTF8Base64URL` and
`trackIdentityKeySnapshotUTF8Base64URL`, accompanied by decimal-string byte
counts. The same encoding is used for any repeated snapshots inside an existing
track generation. Decoding MUST produce well-formed UTF-8 of the stated length,
at most 1,600 bytes, and exactly the native snapshot bytes; base64url text never
enters the JCS digest. MCP candidate rows contain no app name, bundle ID,
localized label, free-form note, or other unbounded presentation field.

The size limit applies to the final production JSON-RPC/MCP response bytes, not
an inner domain result. The production transport encoder serializes the actual
JSON-RPC envelope and request ID, MCP result and content wrappers, every emitted
`structuredContent` field, and the additional JSON escaping of JSON carried in
a text-content field. The exact UTF-8 bytes that will be written to stdio or the
loopback response MUST be less than 2,097,152 bytes. Implementations MUST NOT
estimate this size or measure the domain object before those wrappers and
escaping are applied. An accepted JSON-RPC request ID has a production-encoded
representation of at most 4,096 bytes; a larger ID is rejected as an invalid
request with a `null` response ID before tool dispatch.

A page builder starts with the requested bounded row count and calls that same
production encoder with the actual request ID and complete wrappers. It
deterministically removes rows from the end and re-encodes, advancing the next
cursor to the first omitted ordinal, until the final response fits. It MUST
return at least one row whenever rows remain; the field, ID, and page bounds
above are chosen so one valid row always fits. Failure of one valid bounded row
to fit is the stable internal error `responseLimitExceeded`, never silent
truncation; that fixed, non-echoing error is itself serialized and checked by
the production encoder. Shared worst-case fixtures invoke the production
encoder and cover 50 `alreadyExists` candidates, 1,600-byte snapshots in every
snapshot field, maximum JSON escaping in bounded term fields, a maximum-size
request ID, all MCP wrappers, a next cursor, and all totals. They prove the
final wire response remains below the cap. Equivalent state, request ID, and
requested page size MUST choose the same row boundary.

V1 does not expose MCP tools that add entries or apply, update, replace,
delete, or reset library data. If remote mutations are proposed later, they
require a separate decision and MUST be disabled by default behind an explicit
local opt-in. Any future write tool must call the same preview/digest,
idempotency, batching, provenance, and cancellation engine; it may not create
a second mutation path. A future start tool MUST submit literal `start`, the
full explicit scope, accepted digest, bounded stable namespace, and bounded
idempotency key; a digest-only mutation request is invalid. A future remote
resume tool requires a separate authorization decision and must preserve the
operation-ID, explicit-intent, execution-lock, and status-only replay rules.

## Rejected alternatives

- Calling the feature "Global Keywords."
- Automatically applying every entry to every tracked app.
- Automatically expanding to all known storefronts.
- Treating omitted scope as "all" or as the current UI selection.
- Starting refresh work merely because tracks were added.
- Keeping the library in cloud-synchronized preferences.
- Adding sync before a conflict and privacy contract exists.
- Rewriting or parsing existing v1 query and track identity keys under the
  library normalizer.
- Adding generation fields or inverse relationships directly to frozen v1
  model declarations.
- Replace, reset, update, delete, or history-removal operations in v1.
- Unbounded fan-out, one transaction for the entire operation, or view-local
  mutation logic.
- Separate native and MCP implementations of preview or apply semantics.

## Verification required from an implementation

An implementation is not conformant until tests prove at least:

- a failed store open or migration preserves the store and its sidecars
  byte-for-byte, returns `storeUnavailable`, and performs zero writes without
  attempting delete, recreation, or empty-store fallback;
- migration leaves the frozen v1 model declarations and metadata unchanged,
  creates exactly one scalar-only sidecar with no relationship or inverse for
  every app and track, copies existing opaque keys byte-for-byte without factory
  regeneration, and exposes no setter for sidecar identity, generation, or
  creation fields;
- serialized lifecycle tests prove app/track creation and sidecar creation are
  atomic, deletion removes the current sidecar atomically, and delete/re-add
  rotates the generation even when every visible value is identical;
- a missing, duplicate, or identity-mismatched sidecar for a live migrated v1
  row returns `storeUnavailable` without lazy repair or a partial write;
- legacy timestamp fixtures cover exact binary64 conversion, values on both
  sides of a microsecond boundary, ties-to-even, zero, the signed 64-bit
  maximum, non-finite values, negative values, and overflow;
- Unicode 15.1 fixtures cover NFC composition and decomposition, full default
  case-fold expansion, excluded Turkic mappings, every `White_Space` boundary,
  malformed input, empty normalized output, and the 200-byte boundary in both
  native and MCP paths;
- entry provenance fixtures cover every exact kind/nullability combination,
  reject unknown kinds and arbitrary text, apply one descriptor to the whole
  request, preserve the first planned provenance for in-request duplicates,
  keep existing provenance immutable, and deterministically re-resolve the
  winning provenance under concurrent sources;
- compatibility fixtures prove preview materializes the unchanged v1 factories'
  exact full query/track keys, enforces each 1,600-byte bound, never parses
  delimiter-containing keys, and leaves existing keys untouched even when old
  rows collide under the library normalizer; native and MCP digest paths consume
  the materialized candidate snapshots;
- an add request validates all inputs before writing, deduplicates within the
  request before capacity evaluation, uses the first display term, returns the
  exact three disposition counts, and satisfies the add count equation;
- add requests at 25 terms and a library at exactly 200 unique entries succeed,
  while 26 terms or a transaction that would create entry 201 fails with zero
  writes; concurrent adds cannot bypass uniqueness or capacity;
- native-app and stdio-MCP subprocess tests acquire the same crash-released
  store lock, retry whole fresh-context transactions with the exact bounded
  schedule, reclassify unique races semantically, and preserve sidecar,
  idempotency, capacity, outcome, and checkpoint invariants when a lock owner is
  terminated;
- instrumented lock-order tests prove creation uses coordinator then writer and
  releases both before acquiring the operation lock, while every post-creation
  attempt uses operation lock then coordinator then writer; no actor turn spans
  operation-lock acquisition, retry delay, or another suspension, and retry
  exhaustion preserves the exact last committed state, including an orphaned
  `running` state that only a later explicit resume recovers;
- empty, duplicate, malformed, missing-entry, and over-limit preview selections
  return `invalidSelection` or the applicable limit error with zero writes; a
  stale entry returns no rows and no digest rather than an `invalidTarget` row;
- 25 entries with one app and storefront, 20 apps with one entry and
  storefront, 20 storefronts with one entry and app, and any valid exactly
  400-candidate product are accepted, while every product above 400 is rejected
  atomically;
- preview rows and all digest arrays follow the specified byte and numeric
  ordering independently of locale and caller array order;
- native and MCP fixtures produce identical RFC 8785 bytes and SHA-256 digests
  for non-ASCII, composed and decomposed, escaped, maximum-integer,
  microsecond-rounding, distinct library/opaque-key snapshots,
  null-generation, and all-disposition payloads;
- paginated MCP preview fixtures recompute and bind the full digest across
  pages, reject stale or malformed cursors, round-trip exact snapshot UTF-8 via
  unpadded base64url, and choose deterministic page boundaries; the worst-case
  50-row fixture calls the production transport encoder with a maximum request
  ID, JSON-RPC envelope, all MCP wrappers, and text-content escaping and proves
  the final wire response is below 2,097,152 bytes without truncating the
  logical 400-candidate preview;
- omitting a required property, replacing required `null`, adding a property,
  using a JSON number, changing permitted spelling or case, or exceeding the
  signed 64-bit ranges is rejected rather than silently canonicalized;
- equivalent input permutations have the same preview digest, while scope,
  the persisted library term, either opaque key snapshot, app or track
  generation, creation microseconds, platform, storefront, and accepted
  disposition changes alter it;
- start apply rejects a missing or wrong intent, missing or partial scope,
  digest-only request, malformed digest, wrong contract version, or any scope
  that fails preview validation;
- idempotency namespace and key tests cover both length boundaries, every
  allowed alphabet, empty, oversized, non-ASCII, control, and forbidden bytes;
- idempotency hashing uses the specified domain and NUL separators, stores only
  the lowercase digest, distinguishes namespaces, and never persists or logs
  the raw namespace or key;
- replay with the same idempotency identity, canonical scope, contract, and
  digest returns status without recomputing preview, acquiring execution
  ownership, changing state, or running a batch; any mismatch returns
  `idempotencyConflict` and creates no operation;
- an explicit resume request needs only contract, literal intent, and operation
  ID; it never reconstructs the raw caller key, follows every allowed state
  transition, returns terminal operations without work, rejects unknown IDs,
  and recovers an orphaned `running` operation only after acquiring its
  crash-released operation lock;
- operation creation serializes preview recomputation, digest comparison,
  accepted-plan persistence, and concurrent track/library changes in one write
  transaction; a stale digest produces zero writes;
- accepted candidate rows durably retain their exact order, disposition, opaque
  keys, and previewed track generation across relaunch and resume; apply
  regenerates and exact-compares both keys without parsing, and a resumed
  mismatch rolls back with `identityCompatibilityChanged`;
- a previewed `alreadyExists` row whose track is deleted or replaced becomes
  `targetChanged` and never recreates a track; a previewed `wouldAdd` row that
  races with an insertion becomes `alreadyExisting` without changing the track;
- replaced app generations receive only `targetChanged`, no late track, and no
  persistence error; all row counts, checkpoint, remaining count, and terminal
  state satisfy the specified equations after every committed batch;
- batches never exceed 25 rows, and cancellation or persistence failure rolls
  back only the current batch, preserves earlier append-only rows, and resumes
  from the exact durable checkpoint without duplicate tracks or results;
- created-track generation/origin sidecars, accepted-candidate, and result rows
  commit atomically; origins enforce uniqueness by both track-generation UUID
  and operation-plus-ordinal, results are append-only and unique by operation
  and ordinal, and retries cannot rewrite an earlier result or provenance
  record;
- operation ownership cascades only to accepted candidates and results; track
  or app deletion resolves an origin only by the exact current track-generation
  UUID, rejects duplicates or mismatches, and removes only its current
  generation/origin sidecars, while retained operation results preserve scalar
  audit evidence without retaining a track relationship;
- existing tracks and all notes, history, status, timestamps, generation, and
  provenance remain byte-for-byte semantically unchanged;
- preview and apply make zero provider requests; and
- committed fixtures contain only declared synthetic inputs and no captured or
  derived user data, while golden logs, analytics, crash reports, and errors
  omit or replace raw terms, paths, idempotency values, credentials, and session
  material with fixed `<redacted>` text and reject complete or truncated
  sentinel values.

## Consequences

This contract favors reviewability, bounded work, and recoverability over a
large first release. Users must choose scope and review impact, and applying a
large library may require several explicit operations. V1 also provides no
way to correct or remove a mistaken entry; adding archive or correction
semantics requires a later decision that preserves history and provenance.

In return, no feature named "global" can silently grow into an all-app x
all-storefront mutation, no refresh is hidden inside a local organization
tool, and native and MCP clients can rely on one deterministic contract.

[rfc-8785]: https://www.rfc-editor.org/rfc/rfc8785
[rfc-4648]: https://www.rfc-editor.org/rfc/rfc4648
[unicode-15-1]: https://www.unicode.org/versions/Unicode15.1.0/
