ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SOURCE := $(ROOT)/src
VOC ?= voc
PYTHON ?= python3
BUILD ?= $(ROOT)/build
override BUILD := $(abspath $(BUILD))
.DEFAULT_GOAL := all
VOC_BINARY := $(shell command -v "$(VOC)" 2>/dev/null)
ifeq ($(VOC_BINARY),)
$(error VOC executable not found: $(VOC))
endif

$(BUILD)/voc-environment: FORCE | $(BUILD)
	$(file >$@.new,VOC=$(VOC_BINARY))
	$(file >>$@.new,VOCROOT=$(VOCROOT))
	$(file >>$@.new,VOCLIBDIR=$(VOCLIBDIR))
	@if cmp -s "$@.new" "$@"; then rm "$@.new"; else mv "$@.new" "$@"; fi

$(BUILD)/voc-toolchain.mk: $(SOURCE)/voc-toolchain.py $(VOC_BINARY) $(BUILD)/voc-environment
	$(PYTHON) "$(SOURCE)/voc-toolchain.py" "$(VOC_BINARY)" "$(BUILD)"

include $(BUILD)/voc-toolchain.mk

CC ?= cc
LINK ?= $(if $(findstring tcc,$(notdir $(firstword $(CC)))),cc,$(CC))
CFLAGS ?= -O0 -g
# VOC method overrides use base/derived receiver pointer casts in generated C.
OBERON_CFLAGS ?= $(if $(findstring clang,$(notdir $(firstword $(CC)))),-fno-sanitize=function)
PKG_CONFIG ?= pkg-config
PIDGIN_UI ?= $(shell $(PKG_CONFIG) --exists pidgin && echo 1 || echo 0)
ifeq ($(PIDGIN_UI),1)
SECURITY_UI_CFLAGS := $(shell $(PKG_CONFIG) --cflags pidgin) -DBAREV_PIDGIN_UI -Wno-deprecated-declarations
SECURITY_UI_LIBS := $(shell $(PKG_CONFIG) --libs pidgin gmodule-2.0)
endif
PURPLE_CFLAGS := $(shell $(PKG_CONFIG) --cflags purple gmodule-2.0) -DPURPLE_PLUGINS
PURPLE_LIBS := $(shell $(PKG_CONFIG) --libs purple gmodule-2.0)
DBUS ?= 1
ifeq ($(DBUS),1)
ifeq ($(shell $(PKG_CONFIG) --atleast-version=2.54 gio-2.0 && echo yes),)
$(error GIO 2.54 or newer is required; use DBUS=0 to disable the local interface)
endif
DBUS_CFLAGS := $(shell $(PKG_CONFIG) --cflags gio-2.0) -DBAREV_DBUS
DBUS_LIBS := $(shell $(PKG_CONFIG) --libs gio-2.0)
endif
PLUGINDIR ?= $(shell $(PKG_CONFIG) --variable=plugindir purple)
DATADIR ?= $(shell $(PKG_CONFIG) --variable=datadir purple)
ICONDIR ?= $(DATADIR)/pixmaps/pidgin/protocols
INSTALL ?= install
GENERATED := $(BUILD)/oberon
INCLUDEFLAG := $(if $(findstring tcc,$(notdir $(firstword $(CC)))),-I,-iquote)
INCLUDES := $(INCLUDEFLAG)"$(GENERATED)" $(INCLUDEFLAG)"$(SOURCE)"
NATIVE_FLAGS := -std=c11 -fPIC -fno-strict-aliasing -fvisibility=hidden
WARNINGS := -Wall -Wextra -Werror
EXPORT_FLAGS := -Wl,--version-script=$(SOURCE)/exports.map -Wl,-z,defs \
 -Wl,--wrap=Platform_OSAllocate -Wl,--wrap=Platform_OSFree
ifneq ($(findstring tcc,$(notdir $(firstword $(CC)))),)
BACKEND_LIBS := $(shell $(CC) -print-search-dirs | awk '/^libtcc1:/{getline; print $$1}')
BACKEND_LDFLAGS := -Wl,--no-eh-frame-hdr
endif

.PHONY: all plugin install test check FORCE
all: $(BUILD)/libbarev-oberon.so $(BUILD)/libvoc-barev.so
plugin: $(BUILD)/libvoc-barev.so
install: plugin
	$(INSTALL) -d "$(DESTDIR)$(PLUGINDIR)" "$(DESTDIR)$(ICONDIR)/scalable"
	$(INSTALL) -m 755 "$(BUILD)/libvoc-barev.so" "$(DESTDIR)$(PLUGINDIR)/libvoc-barev.so"
	$(INSTALL) -m 644 "$(ROOT)/logo/scalable/barev.svg" "$(DESTDIR)$(ICONDIR)/scalable/voc-barev.svg"
	for size in 16 22 48; do \
		$(INSTALL) -d "$(DESTDIR)$(ICONDIR)/$$size"; \
		$(INSTALL) -m 644 "$(ROOT)/logo/$$size/voc-barev.png" "$(DESTDIR)$(ICONDIR)/$$size/voc-barev.png" || exit; \
	done

test: identity-test peer-pins-test pin-ui-test security-ui-test feed-access-test $(BUILD)/libbarev-oberon.so $(BUILD)/libbarev-oberon-test.so $(BUILD)/TestHost
	$(PYTHON) "$(SOURCE)/check.py" "$(BUILD)"

ifeq ($(DBUS),1)
test: dbus-test
endif

check:
	@test "$$(uname -s)" = Linux || { echo "The Oberon bridge prototype requires Linux/ELF."; exit 1; }
	@$(PKG_CONFIG) --atleast-version=2.0 purple
	@$(PKG_CONFIG) --max-version=2.99 purple
	@test -x "$(VOC_BINARY)" && test -f "$(VOC_ARCHIVE)"

$(BUILD):
	mkdir -p "$@"

define BUILD_CONFIGURATION
VOC=$(VOC)
VOC_BINARY=$(VOC_BINARY)
VOCROOT=$(VOCROOT)
VOCLIBDIR=$(VOCLIBDIR)
VOC_INCLUDE_DIR=$(VOC_INCLUDE_DIR)
VOC_ARCHIVE=$(VOC_ARCHIVE)
CC=$(CC)
LINK=$(LINK)
CFLAGS=$(CFLAGS)
OBERON_CFLAGS=$(OBERON_CFLAGS)
LDFLAGS=$(LDFLAGS)
PURPLE_CFLAGS=$(PURPLE_CFLAGS)
PURPLE_LIBS=$(PURPLE_LIBS)
PIDGIN_UI=$(PIDGIN_UI)
DBUS=$(DBUS)
DBUS_CFLAGS=$(DBUS_CFLAGS)
DBUS_LIBS=$(DBUS_LIBS)
BACKEND_LIBS=$(BACKEND_LIBS)
BACKEND_LDFLAGS=$(BACKEND_LDFLAGS)
endef

$(BUILD)/config: FORCE | $(BUILD)
	$(file >$@.new,$(BUILD_CONFIGURATION))
	@if cmp -s "$@.new" "$@"; then rm "$@.new"; else mv "$@.new" "$@"; fi

$(BUILD)/generated.stamp $(GENERATED)/BarevBridge.o &: $(ROOT)/Makefile $(SOURCE)/build-protocol.py $(wildcard $(SOURCE)/*.Mod) \
 $(SOURCE)/host.h $(SOURCE)/identity-store.h $(VOC_ARCHIVE) $(BUILD)/config $(BUILD)/voc-toolchain.mk | check
	CC="$(CC)" CFLAGS="$(CFLAGS)" OBERON_CFLAGS="$(OBERON_CFLAGS)" $(PYTHON) "$(SOURCE)/build-protocol.py" "$(SOURCE)" "$(BUILD)" "$(VOC_INCLUDE_DIR)" "$(VOC_ARCHIVE)" "$(VOC_BINARY)"
	touch "$(BUILD)/generated.stamp"

$(BUILD)/runtime.o: $(SOURCE)/runtime.c $(SOURCE)/runtime.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/identity-store.o: $(SOURCE)/identity-store.c $(SOURCE)/identity-store.h $(BUILD)/config
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) -c "$<" -o "$@"

$(BUILD)/TestIdentity: $(SOURCE)/TestIdentity.Mod $(BUILD)/generated.stamp $(BUILD)/identity-store.o
	cd "$(GENERATED)" && OBERON="$(GENERATED);$(BUILD)/voc-symbols" "$(VOC_BINARY)" -O2 -sFSm "$(SOURCE)/TestIdentity.Mod"
	$(LINK) $(CFLAGS) $(LDFLAGS) $(NATIVE_FLAGS) $(INCLUDES) $(INCLUDEFLAG)"$(VOC_INCLUDE_DIR)" -o "$@" "$(GENERATED)/TestIdentity.c" "$(GENERATED)/BarevIdentity.o" "$(GENERATED)/BarevIdentityFiles.o" "$(BUILD)/identity-store.o" "$(VOC_ARCHIVE)" $(BACKEND_LIBS) -lm

.PHONY: identity-test
identity-test: $(BUILD)/TestIdentity
	$(PYTHON) "$(SOURCE)/check-identities.py" "$(BUILD)/TestIdentity"

$(BUILD)/TestTLS: $(SOURCE)/TestTLS.Mod $(BUILD)/generated.stamp $(BUILD)/identity-store.o
	cd "$(GENERATED)" && OBERON="$(GENERATED);$(BUILD)/voc-symbols" "$(VOC_BINARY)" -O2 -sFSm "$(SOURCE)/TestTLS.Mod"
	$(LINK) $(CFLAGS) $(LDFLAGS) $(NATIVE_FLAGS) $(INCLUDES) $(INCLUDEFLAG)"$(VOC_INCLUDE_DIR)" -o "$@" "$(GENERATED)/TestTLS.c" "$(GENERATED)/BarevTLS.o" "$(GENERATED)/BarevNetwork.o" "$(GENERATED)/BarevAddress.o" "$(GENERATED)/BarevIdentity.o" "$(GENERATED)/BarevIdentityFiles.o" "$(BUILD)/identity-store.o" "$(VOC_ARCHIVE)" $(BACKEND_LIBS) -lm

.PHONY: tls-test
tls-test: $(BUILD)/TestTLS $(BUILD)/TestTLSFlow
	$(PYTHON) "$(SOURCE)/check-tls.py" --native "$(BUILD)/TestTLS"

$(BUILD)/TestAuth: $(SOURCE)/TestAuth.Mod $(BUILD)/generated.stamp
	cd "$(GENERATED)" && OBERON="$(GENERATED);$(BUILD)/voc-symbols" "$(VOC_BINARY)" -O2 -sFSm "$(SOURCE)/TestAuth.Mod"
	$(LINK) $(CFLAGS) $(LDFLAGS) $(NATIVE_FLAGS) $(INCLUDES) $(INCLUDEFLAG)"$(VOC_INCLUDE_DIR)" -o "$@" "$(GENERATED)/TestAuth.c" "$(GENERATED)/BarevAuth.o" "$(VOC_ARCHIVE)" $(BACKEND_LIBS) -lm

.PHONY: auth-test
auth-test: $(BUILD)/TestAuth
	$(PYTHON) "$(SOURCE)/check-auth-stream.py" "$(BUILD)/TestAuth"

.PHONY: auth-protocol-test
auth-protocol-test: $(BUILD)/libvoc-barev-test.so $(BUILD)/ProtocolHost
	$(PYTHON) "$(SOURCE)/check-auth-protocol.py" --native "$(BUILD)"

$(BUILD)/TestTLSFlow: $(SOURCE)/TestTLSFlow.Mod $(BUILD)/generated.stamp $(BUILD)/identity-store.o
	cd "$(GENERATED)" && OBERON="$(GENERATED);$(BUILD)/voc-symbols" "$(VOC_BINARY)" -O2 -sFSm "$(SOURCE)/TestTLSFlow.Mod"
	$(LINK) $(CFLAGS) $(LDFLAGS) $(NATIVE_FLAGS) $(INCLUDES) $(INCLUDEFLAG)"$(VOC_INCLUDE_DIR)" -o "$@" "$(GENERATED)/TestTLSFlow.c" "$(GENERATED)/BarevTLS.o" "$(GENERATED)/BarevNetwork.o" "$(GENERATED)/BarevAddress.o" "$(GENERATED)/BarevIdentity.o" "$(GENERATED)/BarevIdentityFiles.o" "$(BUILD)/identity-store.o" "$(VOC_ARCHIVE)" $(BACKEND_LIBS) -lm

$(BUILD)/TestPeerPins: $(SOURCE)/TestPeerPins.Mod $(BUILD)/generated.stamp
	cd "$(GENERATED)" && OBERON="$(GENERATED);$(BUILD)/voc-symbols" "$(VOC_BINARY)" -O2 -sFSm "$(SOURCE)/TestPeerPins.Mod"
	$(LINK) $(CFLAGS) $(LDFLAGS) $(NATIVE_FLAGS) $(INCLUDES) $(INCLUDEFLAG)"$(VOC_INCLUDE_DIR)" -o "$@" "$(GENERATED)/TestPeerPins.c" "$(GENERATED)/BarevPeerPins.o" "$(GENERATED)/BarevAddress.o" "$(VOC_ARCHIVE)" $(BACKEND_LIBS) -lm

.PHONY: peer-pins-test
peer-pins-test: $(BUILD)/TestPeerPins
	$(PYTHON) "$(SOURCE)/check-peer-pins.py" "$(BUILD)/TestPeerPins"

$(BUILD)/TestFeedAccess: $(SOURCE)/TestFeedAccess.Mod $(SOURCE)/BarevFeedAccess.Mod $(BUILD)/generated.stamp
	cd "$(GENERATED)" && OBERON="$(GENERATED);$(BUILD)/voc-symbols" "$(VOC_BINARY)" -O2 -sFS "$(SOURCE)/BarevFeedAccess.Mod"
	cd "$(GENERATED)" && OBERON="$(GENERATED);$(BUILD)/voc-symbols" "$(VOC_BINARY)" -O2 -sFSm "$(SOURCE)/TestFeedAccess.Mod"
	$(LINK) $(CFLAGS) $(OBERON_CFLAGS) $(LDFLAGS) $(NATIVE_FLAGS) $(INCLUDES) $(INCLUDEFLAG)"$(VOC_INCLUDE_DIR)" -o "$@" "$(GENERATED)/TestFeedAccess.c" "$(GENERATED)/BarevFeedAccess.c" "$(GENERATED)/BarevAddress.o" "$(VOC_ARCHIVE)" $(BACKEND_LIBS) -lm

.PHONY: feed-access-test
feed-access-test: $(BUILD)/TestFeedAccess
	"$(BUILD)/TestFeedAccess"

$(BUILD)/PinUIHost: $(SOURCE)/PinUIHost.c $(BUILD)/pin-ui.o $(SOURCE)/pin-ui.h
	$(CC) $(CFLAGS) $(LDFLAGS) -std=c11 $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -o "$@" "$<" "$(BUILD)/pin-ui.o" $(PURPLE_LIBS)

.PHONY: pin-ui-test
pin-ui-test: $(BUILD)/PinUIHost
	$(PYTHON) "$(SOURCE)/check-pin-ui.py" "$(BUILD)/PinUIHost"

$(BUILD)/bridge.o: $(SOURCE)/bridge.c $(SOURCE)/runtime.h $(SOURCE)/test-api.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/bridge-test.o: $(SOURCE)/bridge.c $(SOURCE)/runtime.h $(SOURCE)/test-api.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -DBAREV_BRIDGE_TEST -c "$<" -o "$@"

$(BUILD)/libbarev-oberon.so: $(BUILD)/runtime.o $(GENERATED)/BarevBridge.o $(BUILD)/bridge.o $(SOURCE)/exports.map $(VOC_ARCHIVE)
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -shared $(EXPORT_FLAGS) -o "$@" "$(BUILD)/runtime.o" "$(GENERATED)/BarevBridge.o" "$(BUILD)/bridge.o" "$(VOC_ARCHIVE)" $(PURPLE_LIBS) $(BACKEND_LIBS) -lm

$(BUILD)/libbarev-oberon-test.so: $(BUILD)/runtime.o $(GENERATED)/BarevBridge.o $(BUILD)/bridge-test.o $(SOURCE)/exports.map $(VOC_ARCHIVE)
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -shared $(EXPORT_FLAGS) -o "$@" "$(BUILD)/runtime.o" "$(GENERATED)/BarevBridge.o" "$(BUILD)/bridge-test.o" "$(VOC_ARCHIVE)" $(PURPLE_LIBS) $(BACKEND_LIBS) -lm

$(BUILD)/protocol.o: $(SOURCE)/protocol.c $(SOURCE)/runtime.h $(SOURCE)/transfers.h $(SOURCE)/pin-ui.h $(SOURCE)/dbus-api.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/protocol-test.o: $(SOURCE)/protocol.c $(SOURCE)/runtime.h $(SOURCE)/transfers.h $(SOURCE)/pin-ui.h $(SOURCE)/dbus-api.h $(SOURCE)/protocol-test.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -DBAREV_PROTOCOL_TEST -c "$<" -o "$@"

$(BUILD)/transfers.o: $(SOURCE)/transfers.c $(SOURCE)/transfers.h $(SOURCE)/runtime.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/image-ui.o: $(SOURCE)/image-ui.c $(SOURCE)/image-ui.h $(SOURCE)/runtime.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/pin-ui.o: $(SOURCE)/pin-ui.c $(SOURCE)/pin-ui.h $(BUILD)/config
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/dbus-interface.inc: $(SOURCE)/dbus-interface.xml $(SOURCE)/dbus-xml.py | $(BUILD)
	$(PYTHON) "$(SOURCE)/dbus-xml.py" "$<" "$@"

$(BUILD)/dbus-api.o: $(SOURCE)/dbus-api.c $(SOURCE)/dbus-api.h $(if $(filter 1,$(DBUS)),$(BUILD)/dbus-interface.inc) $(BUILD)/config
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(DBUS_CFLAGS) -I"$(BUILD)" -c "$<" -o "$@"

$(BUILD)/TestDBus: $(SOURCE)/TestDBus.c $(SOURCE)/dbus-api.h $(BUILD)/dbus-api.o
	$(CC) $(CFLAGS) $(LDFLAGS) -std=c11 $(WARNINGS) $(PURPLE_CFLAGS) $(DBUS_CFLAGS) -I"$(SOURCE)" "$<" "$(BUILD)/dbus-api.o" -o "$@" $(DBUS_LIBS) $(PURPLE_LIBS)

.PHONY: dbus-test dbus-plugin-test
dbus-test: $(BUILD)/TestDBus
	dbus-run-session -- "$(BUILD)/TestDBus" "$(SOURCE)/dbus-interface.xml"
	DBUS_SESSION_BUS_ADDRESS=unix:path="$(BUILD)/no-session-bus" "$(BUILD)/TestDBus" --no-bus

dbus-plugin-test: $(BUILD)/ProtocolHost $(BUILD)/libvoc-barev-test.so
	dbus-run-session -- $(PYTHON) "$(SOURCE)/check-dbus-plugin.py" "$(BUILD)"

$(BUILD)/security-ui.o: $(SOURCE)/security-ui.c $(SOURCE)/security-ui.h $(BUILD)/config
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(SECURITY_UI_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/SecurityUIHost: $(SOURCE)/SecurityUIHost.c $(SOURCE)/security-ui.c $(SOURCE)/security-ui.h $(SOURCE)/security-mock/gtkconv.h $(BUILD)/config | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -std=c11 $(WARNINGS) $(PURPLE_CFLAGS) -DBAREV_PIDGIN_UI -I"$(SOURCE)/security-mock" $(INCLUDES) "$(SOURCE)/SecurityUIHost.c" "$(SOURCE)/security-ui.c" -o "$@" $(PURPLE_LIBS) $(shell $(PKG_CONFIG) --libs gobject-2.0)

.PHONY: security-ui-test
security-ui-test: $(BUILD)/SecurityUIHost
	"$(BUILD)/SecurityUIHost"

$(BUILD)/transfers-test.o: $(SOURCE)/transfers.c $(SOURCE)/transfers.h $(SOURCE)/runtime.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -DBAREV_PROTOCOL_TEST -c "$<" -o "$@"

$(BUILD)/libvoc-barev-test.so: $(BUILD)/runtime.o $(BUILD)/protocol-test.o $(BUILD)/transfers-test.o $(BUILD)/image-ui.o $(BUILD)/pin-ui.o $(BUILD)/security-ui.o $(BUILD)/identity-store.o $(BUILD)/dbus-api.o $(SOURCE)/exports.map $(VOC_ARCHIVE)
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -shared $(EXPORT_FLAGS) -o "$@" "$(BUILD)/runtime.o" "$(BUILD)/protocol-test.o" "$(BUILD)/transfers-test.o" "$(BUILD)/image-ui.o" "$(BUILD)/pin-ui.o" "$(BUILD)/security-ui.o" "$(BUILD)/identity-store.o" "$(BUILD)/dbus-api.o" @"$(BUILD)/protocol-test-objects.rsp" "$(VOC_ARCHIVE)" $(PURPLE_LIBS) $(SECURITY_UI_LIBS) $(DBUS_LIBS) $(BACKEND_LIBS) -lm

.PHONY: protocol-test protocol-address-test image-test
protocol-test protocol-address-test image-test: $(BUILD)/libvoc-barev.so $(BUILD)/libvoc-barev-test.so $(BUILD)/ProtocolHost $(BUILD)/CCompatibilityHost

protocol-test:
	$(PYTHON) "$(SOURCE)/check-protocol.py" "$(BUILD)"
	$(PYTHON) "$(SOURCE)/check-protocol.py" "$(BUILD)" --images-only

image-test:
	$(PYTHON) "$(SOURCE)/check-protocol.py" "$(BUILD)" --images-only

protocol-address-test:
	$(PYTHON) "$(SOURCE)/check-protocol.py" "$(BUILD)" --addresses-only

$(BUILD)/ProtocolHost.o: $(SOURCE)/ProtocolHost.c $(SOURCE)/protocol-test.h $(BUILD)/config
	$(CC) $(CFLAGS) -std=c11 $(WARNINGS) $(PURPLE_CFLAGS) -c "$<" -o "$@"

$(BUILD)/ProtocolHost: $(BUILD)/ProtocolHost.o
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -o "$@" "$<" $(PURPLE_LIBS) $(BACKEND_LIBS) -ldl

$(BUILD)/CCompatibilityHost.o: $(SOURCE)/CCompatibilityHost.c $(SOURCE)/image-ui.h $(BUILD)/config | $(BUILD)
	$(CC) $(CFLAGS) -std=c11 $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDEFLAG)"$(SOURCE)" -c "$<" -o "$@"

$(BUILD)/CCompatibilityHost: $(BUILD)/CCompatibilityHost.o
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -o "$@" "$<" $(PURPLE_LIBS) $(BACKEND_LIBS)

$(BUILD)/libvoc-barev.so: $(BUILD)/runtime.o $(BUILD)/protocol.o $(BUILD)/transfers.o $(BUILD)/image-ui.o $(BUILD)/pin-ui.o $(BUILD)/security-ui.o $(BUILD)/identity-store.o $(BUILD)/dbus-api.o $(SOURCE)/exports.map $(VOC_ARCHIVE)
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -shared $(EXPORT_FLAGS) -o "$@" "$(BUILD)/runtime.o" "$(BUILD)/protocol.o" "$(BUILD)/transfers.o" "$(BUILD)/image-ui.o" "$(BUILD)/pin-ui.o" "$(BUILD)/security-ui.o" "$(BUILD)/identity-store.o" "$(BUILD)/dbus-api.o" @"$(BUILD)/protocol-objects.rsp" "$(VOC_ARCHIVE)" $(PURPLE_LIBS) $(SECURITY_UI_LIBS) $(DBUS_LIBS) $(BACKEND_LIBS) -lm

$(BUILD)/TestHost.o: $(SOURCE)/TestHost.c $(SOURCE)/test-api.h $(BUILD)/config | check $(BUILD)
	$(CC) $(CFLAGS) -std=c11 $(WARNINGS) $(PURPLE_CFLAGS) -c "$<" -o "$@"

$(BUILD)/TestHost: $(BUILD)/TestHost.o
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -o "$@" "$<" $(PURPLE_LIBS) -ldl $(BACKEND_LIBS)
