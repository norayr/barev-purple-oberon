# Rooted publishing accounts

`BarevPublishAccounts` retains publishing services in Oberon module variables,
so garbage collection can reach every active store, pending candidate and
checkpoint context. Native hosts retain integer handles and supply the owning
connection's integer identity on every operation. Retired handles are not reused.

The registry permits 16 active publishing accounts, with one owner per persistent
publisher key. Opening an account loads its checkpoint asynchronously. The caller
supplies whether the account was previously configured for publishing. A missing
configured checkpoint is unavailable and cannot be silently initialized.

First initialization requires the host to record setup intent in its persistent
account settings before submitting the first checkpoint. `Initialize` returns
`markerRequired` until that marker is confirmed with `Marked`. Existing history
also requests a marker when needed. A failed first setup can retry within the
same session after reload; missing marked history after reconnect requires
explicit recovery. These settings follow the host's normal configuration
persistence contract.

`Poll` consumes one asynchronous completion and reports whether it represents a
successful mutation. Initial loads, explicit reloads, failed saves and idempotent
publication retries do not report a new mutation. Failed saves make account
state unavailable until an explicit reload. Closing an account drops its roots
and pending completion; accepted file writes may finish without reviving it.

## Cursors

Each account has 16 cursors, bound to the client bus name, destination and active
service. Cursor tokens rotate after each successful page read. Reusing an old
token returns `stale`, allowing clients to restart after a lost reply rather than
silently skipping a page. Empty input starts a new sequence; empty output ends it.
An exact-size final page may require one additional empty read.

Abandoned cursors expire after 300 seconds of host-supplied monotonic time. A
clock rollback expires affected cursors. Committed mutations, reloads and account
retirement invalidate cursors; validation failures and exact publication retries
preserve them. Returned immutable pages remain usable after account replacement.

## Time and validation

`BarevPostClock.UTC` converts host-supplied 64-bit Unix seconds to Atom UTC text in
Oberon. It accepts years 1970 through 9999, including dates after 2038, and leaves
outputs unchanged on failure. Timestamp authoring remains independent of local
time zones and frontend input.

`make publish-accounts-test` checks module roots during collection, connection
ownership, persistent-setup guards, post-save visibility, retry metadata, cursor
binding/rotation/expiry, account reconnection and UTC boundaries. Tests use
disposable profiles with VOC on Linux.
