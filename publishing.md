# Durable local publishing operations

`BarevPublishing` coordinates account-scoped destination and post operations over
the bounded post store and private-profile checkpoints. It supplies an Oberon
application boundary for a desktop or protocol adapter. Its operations are
currently exercised by standalone hosts; live stream and D-Bus dispatch remain
separate integration work.

## Opening an account

`Open(profile, owner, author, service)` binds the service to a persistent Ed25519
owner identifier and the account's current canonical Barev author address. A
successful open restores the checkpoint and returns a ready service. Failed
opens preserve the existing output variable.

A missing checkpoint returns `missing` with an uninitialized service. The caller
must explicitly invoke `Initialize` with its node, reserved-post and logical-byte
quotas before creating destinations. The account integration must distinguish
first setup from loss of an already configured checkpoint. Once a service has
established history, neither a missing-file reload nor repeated initialization
can silently reset it.

`Reload` replaces the service's state with a newly validated checkpoint.
`Close` retires the service, checkpoint context and mutable store, including
retained aliases. Returned post records and pages remain immutable snapshots.

## Mutations and visibility

`AddNode`, `Policy`, `Put`, `Edit` and `Retract` copy the committed store into a
private candidate. They validate and apply the operation to that candidate,
persist it, and expose it only after a successful checkpoint. Store copies own
their mutable destinations and slots while sharing immutable post records,
strings and audience policies.

Validation and quota failures preserve the current ready service. A persistence
failure makes the service unavailable until a successful reload, because atomic
replacement may already have installed the complete candidate before an error
is reported. Adapters must not emit success or change signals on that path.
After reload, callers inspect the retained IDs and revisions before retrying.

`Put` requires the persistent owner and canonical author to match the account.
The caller supplies a validated immutable post, including durable item/Atom IDs
and timestamps. Keep those IDs when retrying an operation. `BarevPost.Identifiers`
formats caller-supplied fresh cryptographic entropy for new posts. Edits retain
the original author even if the account's address has since changed.

Both publication and edit validate the serialized Atom payload against the
65,536-byte wire limit before saving. XML expansion can exceed that limit even
when local text quotas are satisfied. Wire-limit failures reserve no identifiers
and leave the previous revision intact.

Replies require a known local parent identity, including reserved tombstones.
The store enforces the destination's audience relationship. External or missing
parents require an authenticated audience-context operation before an adapter
can support them; reference text alone cannot authorize a reply.

## Owner reads and statuses

`Node`, `Get`, `Begin` and `Read` return local-owner metadata and post snapshots.
Cursors belong to one service instance. Successful mutations and reloads retire
the previous store and invalidate its cursors; validation failures leave them
usable. Remote retrieval uses the store's separate audience-aware operations.

Statuses retain the store values `okay` (0), `invalid` (1), `denied` (2),
`missing` (3), `conflict` (4), `full` (5) and `stale` (6). Additional statuses are
`storageError` (7), `changed` (8), `wireFull` (9) and `unavailable` (10).

## Execution and validation

Calls are synchronous and serialized on the Oberon runtime's owning thread.
Filesystem operations can block. A live desktop adapter needs a bounded
off-main-loop persistence design that preserves runtime ownership, immutable
inputs, completion ordering and shutdown lifetimes before exposing these calls.
The application API uses Oberon records rather than widget or GVariant types.

`make publishing-test` uses disposable profiles to check durable operations,
wire limits, failed saves, stale writers, restart recovery, account-scoped cursors,
reply privacy and lost/corrupt checkpoints. Validation is VOC/Linux; the file
adapter depends on VOC's platform APIs. Shared core copying and record operations
use portable array and word conventions.
