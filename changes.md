# Version changes

## 0.6.0 — 2026-11-19

- Adding persistent Ed25519 account identities, public keys and SHA-256
  fingerprints, with shared identity storage for C and Oberon Barev.
- Adding manually verified peer-key pins, explicit replacement confirmation and
  persistent pins scoped to the local identity and canonical contact address.
- Requiring mutual TLS 1.3 and SASL EXTERNAL for pinned contacts using VOC's
  native cryptographic and TLS implementations. Exact-key verification and
  authentication failures close the connection without plaintext fallback.
  Both contacts must pin each other's verified key and reconnect. Unpinned
  contacts retain legacy transport.

- Showing live pinned-identity authentication as one shield in Pidgin's conversation
  header, with authentication details and the captured peer fingerprint in a tooltip.
  Pending, legacy and closed connections hide the shield. Authentication state is
  queried from the Oberon stream core; the optional GTK adapter can be disabled
  with `PIDGIN_UI=0`.
- Passing Linux authentication, C/Oberon interoperability and ASan/UBSan checks,
  with interactive Pidgin validation of the shield-only indicator.

Build with VOC 5.3.0 or newer and matching model-2 network libraries. Back up the
libpurple profile, including `barev/`, before upgrading. TLS protects the chat
stream; separate file-transfer connections retain their existing Yggdrasil
transport. See [account identities](identity.md) for trust, backup and recovery.

## 0.5.9

- Rejected Add Buddy attempts on connected accounts are removed from Pidgin's local buddy list.
  Errors explain username, own-address, port, contact-limit and runtime failures
  separately. Regression tests cover full IPv6 identities, repeated additions,
  equivalent numeric/encoded addresses, aliases and notification reentrancy.

## 0.5.8

- Conversation pictures use the installed VOC 4.0.6 native PNG/JPEG codecs,
  explicit memory files and bounded byte-array encoders. Checked Oberon performs
  alpha-aware integer-area resizing; libpurple integration stays in the native
  adapter. Build with VOC 4.0.6 or newer and matching model-2 libraries.
- Fit for chat, Send original and Cancel use distinct callbacks. Their meanings
  stay correct when Pidgin reverses the action-button indices.
- Invalid Insert Image selections produce a specific image notice and do not
  also trigger libpurple's generic send failure. The Pidgin-owned file picker
  can still show other file types; use Send File to transfer those.
- The legacy XHTML body uses Pidgin-compatible `background` styles so C Barev
  displays selected background colours. The standard XHTML-IM body retains
  `background-color`.
- Multi-megabyte image paths use read-only `VAR` array views and memory riders
  to avoid generated-C stack copies. Image limits, explicit-original bytes,
  consent and cancellation, BoB/IBB transport and regular file transfers retain
  their existing policies. See [conversation pictures](images.md) for details.

See [testing](testing.md) for regression coverage and sanitizer commands.
