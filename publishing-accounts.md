# Rooted publishing accounts

`BarevPublishAccounts` retains publishing services in Oberon module variables,
so garbage collection can reach every active store, pending candidate and
checkpoint context. Native hosts retain integer handles and supply the owning
connection's integer identity on every operation. Retired handles are not reused.

The native libpurple plugin attaches this backend to `org.barev.Publishing1` and
advertises `local-posts`. It lazily opens connected accounts on the first local
publishing request. A 25 ms main-context timer polls completions on the runtime's
owning thread. Pending mutations retain their D-Bus calls until completion or
account disconnect, which returns `Unavailable` and retires the service.

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

The libpurple marker is the account string `barev_publishing=initialized`. It is
set before first checkpoint submission. An established checkpoint also restores
the marker when missing. Account settings use libpurple's normal asynchronous
configuration save; the marker and checkpoint are separate persistence records.

`Poll` consumes one asynchronous completion and reports whether it represents a
successful mutation. Initial loads, explicit reloads, failed saves and idempotent
publication retries do not report a new mutation. Failed saves make account
state unavailable until an explicit reload. Closing an account drops its roots
and pending completion; accepted file writes may finish without reviving it.

Identity loading and checkpoint I/O share the profile lock. Reconnect waits
asynchronously for same-profile background jobs to finish before loading identity
and pin settings, with a 10-second deadline. Disconnect cancels that deferred
initialization. Unloading waits for retained timer callbacks, service roots,
workers and D-Bus calls to drain.

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

`make dbus-publishing-plugin-test` exercises the complete host binding on a
disposable session bus, including persisted account settings, pending-call
retirement and deferred-login timer failures. Background writes and completion
polling have separate lifetimes: pausing the test host's poller leaves accepted
file I/O running.
