# Version changes

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
