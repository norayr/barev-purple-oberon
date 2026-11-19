# Post records

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

These records are an in-memory backend foundation. Persistence, Atom XML
serialization and service integration are separate layers.

## Tests

Run `make post-test` for the standalone Oberon checks. They cover immutable
snapshots, canonical author addresses, byte limits, malformed UTF-8, XML controls,
Gregorian dates, URI references, UUID formatting and revision invariants. The
suite also runs through `make test`. Validation uses VOC; other compilers require
their own runs.
