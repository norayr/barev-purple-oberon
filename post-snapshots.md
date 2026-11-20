# Post-store snapshots

`BarevPostStore.EncodeOwner` produces a bounded, versioned binary image of a local
store. `DecodeOwner` requires its expected persistent owner identifier and either
constructs a complete validated store or returns `NIL`. Invalid images never
produce a partially restored store. These are trusted local storage operations;
the image includes private audience configuration and private post contents.

## Version 1 encoding

The image is at most 6 MiB. All integer words are four bytes, most significant
byte first. Counts, indices and lengths must be nonnegative and within the core's
limits. Text is a length word followed by that many UTF-8 bytes, without a NUL
terminator. Embedded NUL bytes are invalid. String fields retain their individual
size and content constraints.

The header contains, in order:

1. Text `BAREVPS1`.
2. The 64-character persistent owner key identifier.
3. Node, reserved-post and logical-byte quotas, as three words.
4. Destination count and reserved-post count, as two words.

Each destination contains its node ID and display title as text, followed by
access-model and member-count words and that many audience-name strings. Models
are `1` for open, `2` for roster and `3` for whitelist. Open nodes have no audience
names. Roster names are group labels; whitelist names are canonical Barev contact
identities. The normal audience bounds and duplicate checks apply.

Each reserved post slot contains:

1. A zero-based destination index.
2. A state word: `0` for a tombstone or `1` for a live post.
3. PubSub item ID and Atom ID as text.
4. For live posts only: author address, title, published timestamp, updated
   timestamp, parent Atom ID and content, in that order, as text.

Every live post inherits the header's owner key identifier. Destination and slot
order are retained, preserving publication order and tombstone reservations.
Derived counts, logical-byte usage and cursor generations are reconstructed,
rather than accepted from serialized counters.

The final word is the reflected IEEE CRC-32 of all preceding bytes, using
polynomial `EDB88320`, initial value `FFFFFFFF` and final XOR `FFFFFFFF`. It detects
accidental corruption; it is not an author signature or keyed authenticator.
Filesystem access controls provide the local trust boundary. Trailing data,
unknown versions, malformed fields, duplicate identities, invalid policies and
quota violations are rejected, including when their checksum is valid.

## Checkpoint lineage

`ExtendsOwner` checks that a newer store preserves the previous destination and
reserved-slot prefixes, destination access models and all reserved identifiers.
Live posts can remain unchanged, advance to a valid immutable revision or become
tombstones. Tombstones cannot become live posts again. New destinations and slots
may be appended. This check lets a persistence layer reject silent loss of saved
identities or rollback of saved revisions.

The binary codec uses portable Oberon word operations and byte copying. It does
not serialize record layouts, pointers, native endianness or cursor state.

## Profile checkpoints

`BarevPostFiles` stores a snapshot at
`PROFILE/barev/posts-OWNER.state`, where `OWNER` is the persistent key identifier.
It reuses the existing private-profile directory validation and nonblocking
exclusive directory lock. The `barev` directory must belong to the current user
and have mode `0700`. Snapshot files are plaintext and use the existing file
creation umask; their privacy depends on this validated private directory.

`Load(profile, owner, context, store)` returns a validated store and an independent
checkpoint context. A missing file returns a context with no saved baseline and
a `NIL` store; it does not silently construct an empty history. Invalid or failed
loads leave existing output variables unchanged. Callers must distinguish first
initialization from a missing previously configured checkpoint.

`Save(context, store)` first checks owner binding and checkpoint lineage. While
holding the directory lock, it compares the complete current file with the
context's previous bytes. A changed or deleted checkpoint rejects a stale save.
An identical already-installed image succeeds without rewriting the file.

New images are written to a temporary file in the same directory, flushed and
atomically registered over the old path, followed by directory synchronization.
The context advances only after success. A failure after registration can leave
the complete new image installed; callers should retry or reload instead of
assuming that every reported failure means the old image remains on disk.

Return statuses are `okay` (0), `missing` (1), `invalid` (2), `storageError` (3) and
`changed` (4). `Close` retires a context and its private baseline without closing
the separately returned application store. Calls are synchronous; desktop
integration must account for potentially slow filesystem operations.

## Tests

`make post-snapshot-test` checks round trips, restored audiences and tombstones,
checkpoint lineage, integer limits, every truncation and single-byte corruption
of a fixture, and invalid fields carrying recomputed checksums. It also checks
the standard CRC-32 `123456789` vector. The suite runs through `make test`.

`make post-files-test` runs fresh-process restart checks, an independent Python
decoder/CRC check, stale-writer and deletion conflicts, malformed files, private
directory validation, wrong file types, lock contention and temporary-file
cleanup. It uses disposable profiles and does not contact peers.
