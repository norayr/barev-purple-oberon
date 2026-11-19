# Local post storage

`BarevPost` holds an immutable local text publication. Its header contains the
PubSub item identifier, Atom identifier, persistent author key identifier,
canonical Barev author address, title, publication/update timestamps and an
optional parent Atom identifier. Content and metadata are copied on construction
and retrieval; callers cannot mutate an accepted record through its inputs or
returned snapshots.

## Validation

- Content is nonempty UTF-8 text, up to 16,384 bytes.
- Titles contain up to 256 UTF-8 bytes and may be empty.
- Text accepts XML 1.0 characters, including tabs and line breaks. XML escaping
  belongs to the serializer; content is stored verbatim.
- Local item identifiers contain up to 128 ASCII letters, digits, dots, hyphens
  or underscores.
- Atom and parent identifiers are absolute ASCII URI references, up to 1,024
  bytes, checked with the existing URI parser. Non-ASCII IRI identifiers require
  a later profile extension; identifiers are never silently rewritten.
- Timestamps use `YYYY-MM-DDThh:mm:ssZ`, Gregorian years 0001–9999 and ordinary
  seconds 00–59. Updates cannot precede publication.
- A post cannot directly reference itself as its parent.

`Identifiers` formats a UUIDv4 Atom identifier and a separate 32-character PubSub
item identifier from 16 caller-supplied entropy bytes. The caller must supply
fresh cryptographically random bytes and distinct output buffers. Formatting
does not obtain entropy or change its input. Both identifiers must be retained
with the post.

`Revision` checks that an edit preserves item/Atom IDs, author key/address,
publication time and parent reference, and advances the update timestamp.
Audience authorization is a store/service responsibility. An author field alone
does not authorize publication.

These records are a backend foundation. Persistence and service integration are
separate layers.

The store's versioned binary snapshot format and restoration checks are described
in [post-snapshots.md](post-snapshots.md).

## Atom serialization

`BarevPostAtom.Entry` builds a fresh standalone Atom 1.0 entry with its own author,
ID, title, publication/update times and one `content` element. Title and content
use `type="text"`. Replies carry RFC 4685 `in-reply-to` metadata in the Atom
threading namespace. `Publish` wraps the entry in a standard XEP-0060 publish
payload for an explicitly selected node.

`Encode` uses the checked namespace-aware XML writer and returns bounded UTF-8
bytes. It preserves literal markup, entities, Unicode, tabs and carriage returns
as text. The maximum wire payload is the PubSub library's 65,536-byte limit.
Escaping can expand an otherwise valid local post beyond that limit; serialization
then fails with no partial output. Publishing adapters must check the wire budget
before accepting a publication for transmission. Audience configuration remains
node metadata and is not embedded in public/private entry payloads.

## Store and audiences

`BarevPostStore` binds a collection to one persistent author key identifier.
Each destination has an opaque node identifier, a display title and an immutable
`BarevFeedAccess` policy. Node IDs and titles are supplied separately from roster
group labels; service adapters must choose outward-facing metadata that does not
disclose private roster configuration.

The caller chooses per-store node, reserved-post and logical-byte quotas within
hard limits of 16 nodes, 256 reserved post identities and 4 MiB. The byte quota
counts node IDs/titles and post metadata/content, excluding terminators and
allocator overhead. Policy configurations have the separate bounds enforced by
`BarevFeedAccess`. Full stores reject writes without evicting existing posts.

Procedures ending in `Owner` belong to the trusted local backend. They create
destinations, publish, edit, retract, enumerate metadata and inspect accounting.
The post's key identifier must match the store owner, but that field alone does
not authenticate a remote caller. Remote service dispatch must use the separate
reader-authorized operations and must not expose owner procedures.

`Get`, `DescribeNode`, `Begin` and `Read` check the current node policy against
the completed transport's reader state and a current contact snapshot. Pin
replacement, roster changes and whitelist replacement therefore affect the next
read. Missing and inaccessible destinations have the same remote result. Node
snapshots expose only the node ID, display title and access model.

`PolicyOwner` replaces a node policy only within its original access model.
Membership updates apply to retained history. Public/private model changes and
moving an existing post between nodes require a separate publication workflow.

## Revisions, replies and retractions

Identical publication retries succeed without allocating space or changing
paging state. Conflicting reuse of either identifier is rejected across all
nodes. `EditOwner` compares the expected immutable revision before replacing it;
stale edits fail. Repeating an already accepted edit succeeds without another
change. Smaller edits release logical-byte quota.

Replies occupy their own post slots. A known local private parent requires the
same destination node, including after that parent has been retracted. A public
parent can receive a narrower reply. The store rejects cycles formed by known
live parent relationships. For missing or external parents, the caller must
validate the audience using its separately authenticated context; the reference
alone supplies no audience or delivery guarantee.

Retraction removes the current content and retains a tombstone containing both
identifiers and its original node. Tombstones consume reserved-post slots and
identifier bytes. Retries are harmless, and retracted IDs cannot be reused during
the store's lifetime. Long-term pruning and restoration of reserved identities
belong to the persistence layer. Previously delivered immutable records and pages
remain readable by their holders.

## Paging and lifetime

Pages contain at most 32 immutable records in reverse insertion order, with the
most recently accepted publication first. Edits retain the original insertion
position. Each node has its own change generation:
publication, edit, retraction and policy replacement invalidate that node's
cursors. Unrelated nodes do not invalidate a cursor or expose their change count.
Failed writes and identical retries leave cursors valid.

Remote access is checked again on each page before reporting a stale cursor.
Owner and remote cursors are distinct. Failed reads clear the output page and do
not advance the cursor. Start a fresh sequence after a stale result.

Cursors are opaque in-process values, not wire tokens. Adapters must not serialize
their internal scan positions or generations. Closing a store invalidates every
cursor referencing it and releases its retained records and tombstones.

## Tests

Run `make post-test` for the standalone Oberon checks. They cover immutable
snapshots, canonical author addresses, byte limits, malformed UTF-8, XML controls,
Gregorian dates, URI references, UUID formatting and revision invariants. The
suite also runs through `make test`. Validation uses VOC; other compilers require
their own runs.

Run `make post-atom-test` for standalone entry and PubSub builder checks, plus an
independent XML parser check of the emitted UTF-8 entry. This suite also runs
through `make test`.

Run `make post-store-test` for bounded storage, owner binding, audience checks,
revision conflicts, retractions, reply privacy, cursor invalidation, quota
rollback and garbage-collection lifetime checks. This suite also runs through
`make test` and uses no peer connections or filesystem storage.
