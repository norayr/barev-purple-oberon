# Testing the native-codec plugin

The Oberon plugin uses an installed VOC 4.0.6 or newer with matching model-2
libraries. Tests create disposable libpurple profiles and local IPv6 loopback
peers. They do not install the plugin or connect to configured contacts.

Run the bridge, protocol, file-transfer and picture checks with:

```sh
make all test protocol-test VOC=/usr/bin/voc
```

On x86-64 Linux with installed VOC 4.0.6, GCC debug and optimized builds and
the Clang sanitizer profile passed 97,765 Oberon checks, 1,794 protocol checks
and 991 image/interoperability checks. Bridge tests passed 1,127 retention and
387 production lifecycle checks. TCC also passed the bridge and 991-image-check
profiles. An isolated installation image passed dependency, export and icon
checks. C interoperability was checked against both the previous C plugin and
the C build with the dialog fixes.

Set `BUILD` to an empty directory for an isolated build, and use
`CFLAGS='-O2 -g'` for an optimized build. `make image-test` runs the picture
checks separately.

## C interoperability

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

- Checked image decoding, output capacities and alpha-preserving resizing.
- Independent PNG unfiltering to verify alpha 0 and 128 and transparent edges.
- Noisy RGB/RGBA inputs that force repeated fitting to the encoded-byte limit.
- Multi-megabyte original-image validation and explicit SI/IBB offers.
- Pidgin's reversed button indices for Fit, Send original and Cancel.
- Invalid Insert Image selections through both the protocol and conversation
  APIs, with a specific notice and no generic send-error message.
- Consent, exact original bytes, cancellation, disconnect/reentrancy, logging,
  ordinary SI/SOCKS5 transfers, address aliases and stream validation.
- ELF export isolation and the absence of direct GdkPixbuf, libpng, libjpeg,
  libgif or shared VOC dependencies in the production plugin.

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
