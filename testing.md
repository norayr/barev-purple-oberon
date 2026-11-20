# Testing the native-codec plugin

The Oberon plugin uses an installed VOC with matching model-2 libraries,
including `TLSEd25519`, `TLSEd25519Keys`, pinned Ed25519 TLS handshakes and
`TLS13Live` readiness queries. Tests create disposable libpurple profiles and local IPv6 loopback
peers. They do not install the plugin or connect to configured contacts.

Run the bridge, protocol, file-transfer and picture checks with:

```sh
make all test protocol-test VOC=/usr/bin/voc
```

For version 0.5.8 on x86-64 Linux with installed VOC 4.0.6, GCC debug and optimized
builds and the Clang sanitizer profile passed 97,765 Oberon checks, 1,794 protocol
checks and 991 image/interoperability checks. Bridge tests passed 1,127 retention and
387 production lifecycle checks. TCC also passed the bridge and 991-image-check
profiles. An isolated installation image passed dependency, export and icon
checks. C interoperability was checked against both the previous C plugin and
the C build with the dialog fixes.

Set `BUILD` to an empty directory for an isolated build, and use
`CFLAGS='-O2 -g'` for an optimized build. `make image-test` runs the picture
checks separately.

For version 0.5.9, `make protocol-address-test` passes 306 address and Add Buddy
checks with GCC debug/optimized builds and Clang ASan/UBSan. These include
malformed repeated-prefix and concatenated usernames, rejection rollback,
aliases, reconnects, port errors, the contact limit and notification reentrancy.

## C interoperability

`make identity-test` checks persistent identity files, RFC-derived public keys,
fingerprints, account links, permissions, symlink rejection, corrupted records,
missing configured keys and concurrent first use. To check both implementations
against the same files, supply the C plugin's `tests/identity-test` executable:

```sh
python3 src/check-identities.py build/TestIdentity /path/to/c-plugin/tests/identity-test
```

`make peer-pins-test` checks public peer-pin records, independent SHA-256
fingerprints, canonical addresses, local-identity scoping, explicit replacement
and malformed records. Both plugins can be checked against the same profiles:

```sh
python3 src/check-peer-pins.py build/TestPeerPins /path/to/c-plugin/tests/peer-pins-test
```

`make pin-ui-test` exercises confirmation, cancellation, stale approvals,
unavailable dialogs, synchronous callbacks and disconnect cleanup.
`make protocol-address-test` also drives the actual contact menu and persistence
through reconnects in Pidgin and Haze profiles. These tests are headless; GTK
rendering remains a separate interactive check.

`make security-ui-test` checks conversation-header states, merged-account
switching, window recreation and reentrant cleanup using a headless GTK test
double. The live authentication tests verify that the security query follows
TLS/SASL readiness and the captured peer key. Saving a pin on an existing legacy
connection must not turn its status into authenticated. Visual placement and
icon-theme rendering require an interactive Pidgin check.

Point `BAREV_C_IMAGE_LIBRARY` at a built C Barev plugin:

```sh
BAREV_C_IMAGE_LIBRARY=/absolute/path/to/libbarev.so make protocol-test
```

The picture tests drive the C BoB/IBB engine in both directions. They pass
actual fitted PNG/JPEG output through the C receiver and its preview adapter.
The formatting tests pass the exact Oberon wire bytes through the C message
receiver, checking selected foreground and background colours. The C receiver
host prevents login from opening network listeners.

## Regression coverage

`make post-test` checks the immutable text-post records described in `posts.md`,
including Unicode, metadata bounds, timestamps, identifiers and edit invariants.
`make post-store-test` checks bounded in-memory storage, current audience checks,
owner binding, revision conflicts, tombstones, reply privacy, per-node paging
and retained-record lifetimes. These suites run through `make test`; live
publishing integration remains separate.
`make post-atom-test` checks standalone text Atom entries, RFC 4685 reply metadata,
PubSub publication payloads, XML escaping and serialization budgets. A supplemental
Python XML parser independently checks the generated entry, including Unicode,
literal entities and carriage-return preservation.
`make post-snapshot-test` checks the binary checkpoint codec, restored audiences,
tombstones, lineage and malformed or corrupted images. The versioned format is
documented in `post-snapshots.md`.
`make post-files-test` runs the Oberon checkpoint host in fresh processes with
disposable profiles. It checks restart recovery, exact-image conflict detection,
private directory validation, malformed files and the independent binary/CRC
decoder. The checkpoint adapter reuses the existing private-profile binding and
Oberon file APIs.
`make publishing-test` checks the durable account-scoped facade, including wire
budgets before saving, candidate isolation, lock failures, stale writers,
membership persistence, restart recovery and cursor lifetime. See `publishing.md`
for the application API and synchronous execution boundary.
`make post-io-test` checks the opaque-byte background file binding with injected
read, write, close, rename and synchronization failures, main-context heartbeat,
queue bounds and shutdown/restart lifetimes. The worker API and ownership rules
are described in `post-io.md`.
`make post-async-test` checks the Oberon request layer with background file I/O,
including snapshot validation, prepared-image isolation, garbage collection,
stale contexts, late completions, cancellation and shutdown. See `post-async.md`.
`make publish-async-test` checks account-level asynchronous commits and visibility,
including pending destinations, edits and retractions, serialized writes, failed
save recovery, competing writers and closed-account completions.
`make publish-accounts-test` checks the rooted account registry, setup markers,
connection-owned handles, bounded client/destination cursors and UTC formatting.
See `publishing-accounts.md` for ownership and recovery behavior.

`make dbus-test` runs the shared GDBus adapter suite on a disposable session bus
created by `dbus-run-session`. It checks introspection, capabilities, concurrent
C/Oberon service paths, bounded account results, Unicode, invalid arguments,
signals, repeated startup/shutdown and bus disconnection. It does not use the
desktop's session bus. The interface and build option are described in `dbus.md`.
`make dbus-plugin-test` checks account identity, disconnect/reconnect snapshots,
name collisions and callback retirement through isolated native plugin hosts.
`make dbus-publishing-test` checks the optional typed publishing transport with
standalone deferred backends, bounded requests/results, capability gating and
retained-call teardown.
`make dbus-publishing-plugin-test` exercises the native connected-account backend
with persisted setup markers, exact publication retries, reply privacy, page
contents, mutation-only change hints, storage contention, explicit recovery and
disconnect/reconnect while a publication reply is pending. Deferred-login fixtures
cover main-context responsiveness, resumption, cancellation, failed timer
creation/removal and the 10-second deadline. The native plugin
advertises `local-posts`; the C plugin retains discovery-only capabilities.

`make feed-access-test` runs the standalone Oberon feed-audience policy suite.
It covers public-only anonymous readers, authenticated whitelist and live roster
groups, canonical contact identities, pin replacement, disconnects, binary key
capture and bounded Unicode group configuration. The suite also runs through
`make test`.

`BarevFeedAccess` creates immutable node policies and current contact snapshots.
Its private reader state captures the key of a live mutual TLS/SASL EXTERNAL
connection. Callers must supply current manual authorization, verified pins and
group membership on every access check, and close reader state on disconnect.
The same check applies before discovery, retrieval and notification enqueueing;
an empty private audience denies all remote readers. The standalone policy core
is tested with VOC; listener, persistence and feed UI integration remain separate.

`make tls-test` checks the native transport adapter against Python/OpenSSL,
including peer-key mismatches, client certificates, certificate usages, expiry,
TLS-version rejection, fragmented input, backpressure and stale handles. It
requires Python `cryptography`. To exercise both plugin adapters together:

```sh
python3 src/check-tls.py /path/to/c-plugin/tests/tls-test --native build/TestTLS
```

These transport tests validate TLS authentication independently of the XML
stream's STARTTLS and SASL EXTERNAL state transitions.

`make auth-test auth-protocol-test` checks the stream-authentication state
machine and live pinned connections. The live tests cover STARTTLS boundaries,
TLS and SASL stream restarts, contact binding, corrupt and mismatched pins,
pre-authentication application traffic, queued messages and write backpressure.
Both plugin socket paths can be tested together with:

```sh
python3 src/check-auth-protocol.py --native build \
  --c /path/to/c-plugin/tests/auth-protocol-host /path/to/c-plugin/libbarev.so
```

- Checked image decoding, output capacities and alpha-preserving resizing.
- Independent PNG unfiltering to verify alpha 0 and 128 and transparent edges.
- Noisy RGB/RGBA inputs that force repeated fitting to the encoded-byte limit.
- Multi-megabyte original-image validation and explicit SI/IBB offers.
- Pidgin's reversed button indices for Fit, Send original and Cancel.
- Invalid Insert Image selections through both the protocol and conversation
  APIs, with a specific notice and no generic send-error message.
- Consent, exact original bytes, cancellation, disconnect/reentrancy, logging,
  ordinary SI/SOCKS5 transfers, address aliases and stream validation.
- Add Buddy with full eight-group IPv6 addresses, repeated additions and
  equivalent numeric/encoded identities. Rejected usernames, self-additions,
  invalid ports and over-limit additions leave no local buddy; error reporting
  tolerates an account disconnect from the notification callback.
- ELF export isolation and the absence of direct libpng, libjpeg, libgif or
  shared VOC dependencies in the production plugin. The optional GTK adapter
  links GdkPixbuf through GTK; production image processing does not call it.

## Sanitizers

The Linux Clang ASan/UBSan profile uses:

```sh
LD_LIBRARY_PATH="$(clang -print-runtime-dir)" \
ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=0 \
UBSAN_OPTIONS=halt_on_error=1 \
make all test protocol-test CC=clang \
  CFLAGS='-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer' \
  LDFLAGS='-fsanitize=address,undefined -shared-libasan' \
  BUILD=/tmp/opencode/barev-native-sanitize
```

This instruments the plugin's native and generated Oberon C code. Installed
VOC libraries, including the conservative collector and codecs, remain
uninstrumented. Generated method-call function-type checking is disabled by the
Makefile's Clang profile. Native Windows and interactive GTK rendering checks
remain separate from these Linux headless regressions.
