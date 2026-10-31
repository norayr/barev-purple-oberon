# Conversation pictures

Barev sends static PNG and JPEG pictures directly over an established contact's
messaging connection. Pidgin's **Insert / Image** action uses this feature.

For a large picture, choose **Fit for chat**, **Send original**, or **Cancel**.
Fitting creates a copy at most 1280 pixels on its longest side and 256 KiB;
the source file stays unchanged. The default prompt threshold is 256 KiB;
pictures at least 1280 pixels wide or tall also qualify for the prompt.
The account's advanced options can select `ask`, `fit`, or `original` and change
the byte threshold.

Each resize-dialog button has its own callback, so its meaning is preserved
when Pidgin reverses the displayed button indices. Pidgin owns the Insert Image
file picker; Barev validates the selected bytes rather than trusting a filename
or extension. Unsupported, damaged or over-limit selections get an image-specific
notice directing the sender to Send File, without a second generic send error.

**Send File** continues to transfer the original file through SI/SOCKS5 on
ports 50000–50049. After an accepted PNG/JPEG file finishes, Barev adds a safe
preview to the conversation. Other file types remain ordinary file transfers.

## Receiving and storage

By default, images up to 256 KiB are accepted into memory. Larger image offers
require acceptance and a save location in libpurple's file-transfer dialog.
Progress and cancellation for IBB originals use the file-transfer window.
Disconnecting a messaging stream cancels its IBB transfers.

The automatic-receive threshold is an independent receiver preference; setting
it to zero asks for every image. BoB references do not announce a byte size, so
thresholds below the 256 KiB BoB ceiling require permission before fetching an
uncached reference. A fetched BoB object is still checked against that ceiling.

Displayed previews are at most 640 pixels on their longest side and use
libpurple's in-memory image store. When HTML conversation logging is enabled,
libpurple saves previews beside the conversation logs under
`~/.purple/logs/<protocol>/<account>/<contact>/`. With logging disabled, Barev
does not create an attachment cache. Explicitly accepted originals are saved
at the location chosen by the receiver.

## Wire protocol and limits

* **XEP-0231 Bits of Binary** objects are referenced by XHTML-IM `cid:` images.
  Barev sends images up to 64 KiB through BoB by default; the account setting
  permits thresholds from 1 to 256 KiB. SHA-1 content IDs identify bytes,
  independently of the validated peer identity.
* Larger originals use **XEP-0095 / XEP-0096 SI file offers**, selecting
  **XEP-0047 In-Band Bytestreams**. IQ acknowledgements pace 4096-byte chunks.
* Static PNG/JPEG only: 16 MiB per image, 8192 pixels per dimension, and
  16 megapixels. Native image decoding also enforces these limits.
* Protocol image storage is globally bounded to 64 MiB. Each peer has eight
  cached objects, four pending BoB references, and one incoming and one outgoing
  IBB original. Send multiple large originals individually.
* Per-peer request/offer budgets, bounded stanza queues, sequence validation,
  and 120-second idle/consent deadlines limit protocol resource use.

The Oberon implementation owns parsing, validation, checksums, cache accounting,
consent policy, and BoB/IBB state in checked Oberon. `BarevPictures` uses VOC's
native `PNG0` and `JPEG0` codecs over explicit memory files and bounded byte-array
encoders, with checked integer-area resizing that averages premultiplied colour
to preserve transparent edges. PNG output preserves alpha, including fully
transparent and partially transparent pixels. Fitted opaque images use JPEG quality 85; images
with an alpha channel use PNG. All displayed previews use PNG.

Image processing is memory-only: framing and pixel limits are checked before
image or component allocation, fitted output is capped at 256 KiB, and preview
output at 2 MiB. A fitted image that exceeds its encoded-byte limit is reduced again.
These per-call bounds are separate from the 64 MiB protocol-object budget;
codec scratch buffers and decoded pixels also consume memory. Dialogs retain
only original C-owned bytes, and native results are copied before returning
from the private Oberon runtime. The C adapter integrates libpurple dialogs,
file-transfer status and preview display.

## Building and testing

Build with VOC 4.0.6 or newer and its matching model-2 libraries, including the
memory-file and native PNG/JPEG codec APIs, plus libpurple 2.x and GLib/GModule
development headers. The codecs are linked from VOC's position-independent
static library into the plugin's private runtime. Rebuild the plugin after
upgrading VOC's libraries.

`make image-test` runs isolated loopback image/UI tests. `make protocol-test`
includes them alongside the existing stream and file-transfer regressions.
To test the C wire engine in both directions and pass native fitted pictures
through the unmodified C plugin's preview adapter:

```sh
BAREV_C_IMAGE_LIBRARY=/absolute/path/to/libbarev.so make image-test
```

The same environment variable with `make protocol-test` also checks selected
foreground and background colours through the C plugin's message receiver.
These tests use disposable profiles and IPv6 loopback fixtures.
