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

## Asynchronous accounts

`Start` enables background checkpoint work. `OpenAsync` validates the account
arguments and submits a load, returning `pending` with a service whose committed
state is initially unavailable. Poll `Poll(service)` on the runtime's owning
thread until it returns a terminal status. A missing first checkpoint still
requires explicit `Initialize`; a failed load cannot initialize over corrupt
history. Synchronous `Open` remains available for standalone hosts.

Operations on an asynchronously opened service prepare a private candidate and
return `pending` when its checkpoint is accepted. `Busy` reports an outstanding
operation. Further mutations, initialization and reload return `busy` while it
is pending. Reads continue to return the previous committed state during a save;
the candidate remains hidden even if the worker has already installed its bytes.
An explicit reload makes reads unavailable until completion.

Only a successful save completion swaps the candidate into the committed store
and invalidates previous cursors. Adapters emit success and change notifications
after consuming that completion. Failed save completions discard the candidate
and block reads until reload. Polling an idle or closed service returns `invalid`;
a completion is consumed once.

`Close` retires the account and abandons its pending result without waiting. An
already accepted write may finish on disk, but a late completion cannot revive
the retired account or expose its candidate. Close application services, call
`Stop`, and keep the worker module loaded until `Idle` succeeds. See
[post-async.md](post-async.md) for the underlying request lifetime contract.

The additional application statuses are `pending` (11) and `busy` (12).

## Execution and validation

Calls are serialized on the Oberon runtime's owning thread. Services opened with
`Open` perform synchronous filesystem operations. Services opened with
`OpenAsync` use the bounded background file binding while validation and candidate
commit decisions remain in Oberon. Live desktop adapters use this asynchronous
mode and retain account lifetimes until outstanding work is consumed or retired.
The application API uses Oberon records rather than widget or GVariant types.

`make publishing-test` uses disposable profiles to check durable operations,
wire limits, failed saves, stale writers, restart recovery, account-scoped cursors,
reply privacy and lost/corrupt checkpoints. Validation is VOC/Linux; the file
adapter depends on VOC's platform APIs. Shared core copying and record operations
use portable array and word conventions.

`make publish-async-test` checks application-level commit ordering, hidden pending
destinations/posts/edits/retractions, readable committed snapshots, serialized
mutations, wire-limit failures, stale competing writers, account retirement,
restart recovery and missing/corrupt history.
