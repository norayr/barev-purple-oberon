# Asynchronous Oberon checkpoints

`BarevPostAsync` validates and tracks checkpoint requests on the Oberon runtime's
owning thread while `BarevPostIOHost` copies opaque bytes to the background
[file-I/O binding](post-io.md). File opening, locking, reads, writes, renaming and
synchronization run on workers. Snapshot decoding, owner checks, lineage checks
and checkpoint-context advancement remain in Oberon.

## Loading

After `Start`, call `Load(profile, owner, request)`. An accepted operation returns
`pending` with a request. Poll `Loaded(request, context, store)` from the owning
thread. A pending or failed completion preserves the output context and store.
Successful completion decodes two independent stores: the caller's application
store and the checkpoint context's private baseline.

A missing file returns `missing`, a valid empty-baseline context and a `NIL`
application store. The caller decides whether this is first initialization or a
lost checkpoint. An existing empty, malformed, corrupt or wrong-owner image is
rejected by Oberon validation. Background reads alone never establish validity.

## Saving

`Save(context, store, request)` checks owner binding and lineage, serializes a
private image and validates a private next baseline before submitting opaque
bytes. It permits at most one pending save per context. Mutating or closing the
application store after submission cannot change the worker's copied image.

Poll `Saved(request)` to complete the operation. Only a successful completion
advances the checkpoint context. The application must expose its prepared
candidate and emit change notifications only after that success. The
asynchronous checkpoint layer does not mutate the caller's application store.

Validation failures leave the context usable. A failed or abandoned submitted
save blocks the context until it is replaced by a fresh successful load, because
the complete image may already be installed. Retain durable identifiers and
inspect reloaded state before retrying an uncertain operation.

`Ready(context)` reports an active, unblocked context with no pending save. A
ready context with an empty baseline still requires explicit application
initialization policy. `Close` retires the context and all its aliases without
waiting for workers or closing the separately returned application store.

## Requests and shutdown

`Loaded` and `Saved` consume completed requests. Retained aliases cannot be
completed twice. Passing a pending request to the wrong completion operation
returns `invalid` and leaves it pending. An active request variable cannot be
overwritten by another submission.

`Cancel` abandons the result and releases its native handle without waiting.
Closing a context before save completion prevents late context advancement.
Neither action cancels an accepted filesystem write. Workers retain native
copies of their inputs and never retain Oberon references.

`Stop` rejects new work and abandons native results. Complete or cancel remaining
Oberon requests, retire application contexts and keep the module loaded until
`Idle` succeeds. Starting again is permitted after all prior work has drained.

Statuses match the file binding: `okay` (0), `missing` (1), `invalid` (2),
`storageError` (3), `changed` (4) and `pending` (5). `busy` (6) reports an active
request, a busy context or unavailable submission capacity. Call `Start` before
submitting work.

## Building and tests

`BarevPostIOHost` is a VOC-specific native binding. It passes bounded byte arrays
to C and copies completed results into Oberon-owned arrays on the owning thread.
The file binding uses the existing GLib and POSIX libraries; it has no direct GIO
dependency and remains buildable with `DBUS=0`.

`make post-async-test` runs standalone VOC/Linux regressions for prepared-image
isolation, garbage collection during background work, synchronous/asynchronous
format equivalence, stale writers, lock contention, request aliases, cancellation,
late completions, shutdown/restart and fresh-process corruption handling.
`BarevPublishing.OpenAsync` supplies application-level candidate commit ordering;
see [publishing.md](publishing.md). Live D-Bus dispatch is a separate adapter.
