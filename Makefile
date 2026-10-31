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
PURPLE_CFLAGS := $(shell $(PKG_CONFIG) --cflags purple gmodule-2.0 gdk-pixbuf-2.0) -DPURPLE_PLUGINS
PURPLE_LIBS := $(shell $(PKG_CONFIG) --libs purple gmodule-2.0 gdk-pixbuf-2.0)
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

test: $(BUILD)/libbarev-oberon.so $(BUILD)/libbarev-oberon-test.so $(BUILD)/TestHost
	$(PYTHON) "$(SOURCE)/check.py" "$(BUILD)"

check:
	@test "$$(uname -s)" = Linux || { echo "The Oberon bridge prototype requires Linux/ELF."; exit 1; }
	@$(PKG_CONFIG) --atleast-version=2.0 purple
	@$(PKG_CONFIG) --max-version=2.99 purple
	@$(PKG_CONFIG) --exists gdk-pixbuf-2.0
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
BACKEND_LIBS=$(BACKEND_LIBS)
BACKEND_LDFLAGS=$(BACKEND_LDFLAGS)
endef

$(BUILD)/config: FORCE | $(BUILD)
	$(file >$@.new,$(BUILD_CONFIGURATION))
	@if cmp -s "$@.new" "$@"; then rm "$@.new"; else mv "$@.new" "$@"; fi

$(BUILD)/generated.stamp $(GENERATED)/BarevBridge.o &: $(ROOT)/Makefile $(SOURCE)/build-protocol.py $(wildcard $(SOURCE)/*.Mod) \
 $(SOURCE)/host.h $(VOC_ARCHIVE) $(BUILD)/config $(BUILD)/voc-toolchain.mk | check
	CC="$(CC)" CFLAGS="$(CFLAGS)" OBERON_CFLAGS="$(OBERON_CFLAGS)" $(PYTHON) "$(SOURCE)/build-protocol.py" "$(SOURCE)" "$(BUILD)" "$(VOC_INCLUDE_DIR)" "$(VOC_ARCHIVE)" "$(VOC_BINARY)"
	touch "$(BUILD)/generated.stamp"

$(BUILD)/runtime.o: $(SOURCE)/runtime.c $(SOURCE)/runtime.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/bridge.o: $(SOURCE)/bridge.c $(SOURCE)/runtime.h $(SOURCE)/test-api.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/bridge-test.o: $(SOURCE)/bridge.c $(SOURCE)/runtime.h $(SOURCE)/test-api.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -DBAREV_BRIDGE_TEST -c "$<" -o "$@"

$(BUILD)/libbarev-oberon.so: $(BUILD)/runtime.o $(GENERATED)/BarevBridge.o $(BUILD)/bridge.o $(SOURCE)/exports.map $(VOC_ARCHIVE)
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -shared $(EXPORT_FLAGS) -o "$@" "$(BUILD)/runtime.o" "$(GENERATED)/BarevBridge.o" "$(BUILD)/bridge.o" "$(VOC_ARCHIVE)" $(PURPLE_LIBS) $(BACKEND_LIBS) -lm

$(BUILD)/libbarev-oberon-test.so: $(BUILD)/runtime.o $(GENERATED)/BarevBridge.o $(BUILD)/bridge-test.o $(SOURCE)/exports.map $(VOC_ARCHIVE)
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -shared $(EXPORT_FLAGS) -o "$@" "$(BUILD)/runtime.o" "$(GENERATED)/BarevBridge.o" "$(BUILD)/bridge-test.o" "$(VOC_ARCHIVE)" $(PURPLE_LIBS) $(BACKEND_LIBS) -lm

$(BUILD)/protocol.o: $(SOURCE)/protocol.c $(SOURCE)/runtime.h $(SOURCE)/transfers.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/protocol-test.o: $(SOURCE)/protocol.c $(SOURCE)/runtime.h $(SOURCE)/transfers.h $(SOURCE)/protocol-test.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -DBAREV_PROTOCOL_TEST -c "$<" -o "$@"

$(BUILD)/transfers.o: $(SOURCE)/transfers.c $(SOURCE)/transfers.h $(SOURCE)/runtime.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/image-ui.o: $(SOURCE)/image-ui.c $(SOURCE)/image-ui.h $(BUILD)/config
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/transfers-test.o: $(SOURCE)/transfers.c $(SOURCE)/transfers.h $(SOURCE)/runtime.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -DBAREV_PROTOCOL_TEST -c "$<" -o "$@"

$(BUILD)/libvoc-barev-test.so: $(BUILD)/runtime.o $(BUILD)/protocol-test.o $(BUILD)/transfers-test.o $(BUILD)/image-ui.o $(SOURCE)/exports.map $(VOC_ARCHIVE)
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -shared $(EXPORT_FLAGS) -o "$@" "$(BUILD)/runtime.o" "$(BUILD)/protocol-test.o" "$(BUILD)/transfers-test.o" "$(BUILD)/image-ui.o" @"$(BUILD)/protocol-test-objects.rsp" "$(VOC_ARCHIVE)" $(PURPLE_LIBS) $(BACKEND_LIBS) -lm

.PHONY: protocol-test protocol-address-test image-test
protocol-test protocol-address-test image-test: $(BUILD)/libvoc-barev.so $(BUILD)/libvoc-barev-test.so $(BUILD)/ProtocolHost

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

$(BUILD)/libvoc-barev.so: $(BUILD)/runtime.o $(BUILD)/protocol.o $(BUILD)/transfers.o $(BUILD)/image-ui.o $(SOURCE)/exports.map $(VOC_ARCHIVE)
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -shared $(EXPORT_FLAGS) -o "$@" "$(BUILD)/runtime.o" "$(BUILD)/protocol.o" "$(BUILD)/transfers.o" "$(BUILD)/image-ui.o" @"$(BUILD)/protocol-objects.rsp" "$(VOC_ARCHIVE)" $(PURPLE_LIBS) $(BACKEND_LIBS) -lm

$(BUILD)/TestHost.o: $(SOURCE)/TestHost.c $(SOURCE)/test-api.h $(BUILD)/config | check $(BUILD)
	$(CC) $(CFLAGS) -std=c11 $(WARNINGS) $(PURPLE_CFLAGS) -c "$<" -o "$@"

$(BUILD)/TestHost: $(BUILD)/TestHost.o
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -o "$@" "$<" $(PURPLE_LIBS) -ldl $(BACKEND_LIBS)
