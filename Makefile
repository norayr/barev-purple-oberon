ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SOURCE := $(ROOT)/src
VOCSRC ?= $(abspath $(SOURCE)/../../compiler)
VOC ?= $(VOCSRC)/install/bin/voc
VOCROOT ?= $(VOCSRC)/install
BUILD ?= $(ROOT)/build
override BUILD := $(abspath $(BUILD))
CC ?= cc
LINK ?= $(if $(findstring tcc,$(notdir $(firstword $(CC)))),cc,$(CC))
CFLAGS ?= -O0 -g
CORE_CFLAGS ?= -O0 -g
# VOC method overrides use base/derived receiver pointer casts in generated C.
OBERON_CFLAGS ?= $(if $(findstring clang,$(notdir $(firstword $(CC)))),-fno-sanitize=function)
PKG_CONFIG ?= pkg-config
PURPLE_CFLAGS := $(shell $(PKG_CONFIG) --cflags purple gmodule-2.0) -DPURPLE_PLUGINS
PURPLE_LIBS := $(shell $(PKG_CONFIG) --libs purple gmodule-2.0)
RUNTIME := $(VOCSRC)/src/runtime
INCLUDEFLAG := $(if $(findstring tcc,$(notdir $(firstword $(CC)))),-I,-iquote)
INCLUDES := $(INCLUDEFLAG)$(BUILD) $(INCLUDEFLAG)$(SOURCE) $(INCLUDEFLAG)$(RUNTIME)
NATIVE_FLAGS := -std=c11 -fPIC -fno-strict-aliasing -fvisibility=hidden
WARNINGS := -Wall -Wextra -Werror
CORE_NAMES := SYSTEM PlatformNative Platform Heap Modules
CORE_OBJECTS := $(addprefix $(BUILD)/,$(addsuffix .o,$(CORE_NAMES)))
EXPORT_FLAGS := -Wl,--version-script=$(SOURCE)/exports.map -Wl,-z,defs \
 -Wl,--wrap=Platform_OSAllocate -Wl,--wrap=Platform_OSFree
ifneq ($(findstring tcc,$(notdir $(firstword $(CC)))),)
BACKEND_LIBS := $(shell $(CC) -print-search-dirs | awk '/^libtcc1:/{getline; print $$1}')
BACKEND_LDFLAGS := -Wl,--no-eh-frame-hdr
endif

.DEFAULT_GOAL := all
.PHONY: all test check FORCE
all: $(BUILD)/libbarev-oberon.so $(BUILD)/libvoc-barev.so
test: $(BUILD)/libbarev-oberon.so $(BUILD)/libbarev-oberon-test.so $(BUILD)/TestHost
	python3 "$(SOURCE)/check.py" "$(BUILD)"

check:
	@test "$$(uname -s)" = Linux || { echo "The Oberon bridge prototype requires Linux/ELF."; exit 1; }
	@$(PKG_CONFIG) --atleast-version=2.0 purple
	@$(PKG_CONFIG) --max-version=2.99 purple
	@test -x "$(VOC)" && test -f "$(RUNTIME)/Heap.Mod"

$(BUILD):
	mkdir -p "$@"

define BUILD_CONFIGURATION
VOC=$(VOC)
VOCROOT=$(VOCROOT)
CC=$(CC)
LINK=$(LINK)
CFLAGS=$(CFLAGS)
CORE_CFLAGS=$(CORE_CFLAGS)
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

$(BUILD)/generated.stamp: $(ROOT)/Makefile $(SOURCE)/BarevBridge.Mod $(SOURCE)/host.h $(BUILD)/config \
 $(RUNTIME)/SYSTEM.h $(RUNTIME)/PlatformNativeunix.Mod $(RUNTIME)/Platformunix.Mod \
 $(RUNTIME)/Heap.Mod $(RUNTIME)/Modules.Mod | check
	cp "$(RUNTIME)/SYSTEM.h" "$(BUILD)/SYSTEM.h"
	cd "$(BUILD)" && VOCROOT="$(VOCROOT)" OBERON="$(BUILD);$(VOCROOT)/2/sym" "$(VOC)" -O2 -sFS "$(RUNTIME)/PlatformNativeunix.Mod"
	cd "$(BUILD)" && VOCROOT="$(VOCROOT)" OBERON="$(BUILD);$(VOCROOT)/2/sym" "$(VOC)" -O2 -sFS "$(RUNTIME)/Platformunix.Mod"
	cd "$(BUILD)" && VOCROOT="$(VOCROOT)" OBERON="$(BUILD);$(VOCROOT)/2/sym" "$(VOC)" -O2 -sFSapx "$(RUNTIME)/Heap.Mod"
	cd "$(BUILD)" && VOCROOT="$(VOCROOT)" OBERON="$(BUILD);$(VOCROOT)/2/sym" "$(VOC)" -O2 -sFS "$(RUNTIME)/Modules.Mod"
	cd "$(BUILD)" && VOCROOT="$(VOCROOT)" OBERON="$(BUILD);$(VOCROOT)/2/sym" "$(VOC)" -O2 -sFS "$(SOURCE)/BarevBridge.Mod"
	touch "$@"

$(BUILD)/SYSTEM.o: $(RUNTIME)/SYSTEM.c $(BUILD)/generated.stamp
	$(CC) $(CORE_CFLAGS) $(NATIVE_FLAGS) $(INCLUDES) -c "$<" -o "$@"

$(addprefix $(BUILD)/,$(addsuffix .o,PlatformNative Platform Heap Modules)): $(BUILD)/%.o: $(BUILD)/generated.stamp
	$(CC) $(CORE_CFLAGS) $(NATIVE_FLAGS) $(INCLUDES) -c "$(BUILD)/$*.c" -o "$@"

$(BUILD)/BarevBridge.o: $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(INCLUDES) -c "$(BUILD)/BarevBridge.c" -o "$@"

$(BUILD)/runtime.o: $(SOURCE)/runtime.c $(SOURCE)/runtime.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/bridge.o: $(SOURCE)/bridge.c $(SOURCE)/runtime.h $(SOURCE)/test-api.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/bridge-test.o: $(SOURCE)/bridge.c $(SOURCE)/runtime.h $(SOURCE)/test-api.h $(BUILD)/generated.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -DBAREV_BRIDGE_TEST -c "$<" -o "$@"

$(BUILD)/libbarev-oberon.so: $(CORE_OBJECTS) $(BUILD)/runtime.o $(BUILD)/BarevBridge.o $(BUILD)/bridge.o $(SOURCE)/exports.map
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -shared $(EXPORT_FLAGS) -o "$@" $(CORE_OBJECTS) "$(BUILD)/runtime.o" "$(BUILD)/BarevBridge.o" "$(BUILD)/bridge.o" $(PURPLE_LIBS) $(BACKEND_LIBS)

$(BUILD)/libbarev-oberon-test.so: $(CORE_OBJECTS) $(BUILD)/runtime.o $(BUILD)/BarevBridge.o $(BUILD)/bridge-test.o $(SOURCE)/exports.map
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -shared $(EXPORT_FLAGS) -o "$@" $(CORE_OBJECTS) "$(BUILD)/runtime.o" "$(BUILD)/BarevBridge.o" "$(BUILD)/bridge-test.o" $(PURPLE_LIBS) $(BACKEND_LIBS)

PROTOCOL_SOURCES := $(wildcard $(SOURCE)/*.Mod $(VOCSRC)/src/library/*.Mod \
 $(VOCSRC)/src/ports/ooc/*.Mod $(VOCSRC)/src/ports/xml/*.Mod $(VOCSRC)/src/ports/xmpp/*.Mod)
$(BUILD)/protocol.stamp: $(SOURCE)/build-protocol.py $(PROTOCOL_SOURCES) $(BUILD)/generated.stamp
	CC="$(CC)" CFLAGS="$(CFLAGS)" OBERON_CFLAGS="$(OBERON_CFLAGS)" python3 "$(SOURCE)/build-protocol.py" "$(SOURCE)" "$(VOCSRC)" "$(BUILD)" "$(VOC)" "$(VOCROOT)"
	touch "$@"

$(BUILD)/protocol.o: $(SOURCE)/protocol.c $(SOURCE)/runtime.h $(BUILD)/protocol.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -c "$<" -o "$@"

$(BUILD)/protocol-test.o: $(SOURCE)/protocol.c $(SOURCE)/runtime.h $(SOURCE)/protocol-test.h $(BUILD)/protocol.stamp
	$(CC) $(CFLAGS) $(NATIVE_FLAGS) $(WARNINGS) $(PURPLE_CFLAGS) $(INCLUDES) -DBAREV_PROTOCOL_TEST -c "$<" -o "$@"

$(BUILD)/libvoc-barev-test.so: $(CORE_OBJECTS) $(BUILD)/runtime.o $(BUILD)/protocol-test.o $(SOURCE)/exports.map
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -shared $(EXPORT_FLAGS) -o "$@" $(CORE_OBJECTS) "$(BUILD)/runtime.o" "$(BUILD)/protocol-test.o" @"$(BUILD)/protocol-test-objects.rsp" $(PURPLE_LIBS) $(BACKEND_LIBS) -lm

.PHONY: protocol-test
protocol-test: $(BUILD)/libvoc-barev.so $(BUILD)/libvoc-barev-test.so $(BUILD)/ProtocolHost
	python3 "$(SOURCE)/check-protocol.py" "$(BUILD)"

$(BUILD)/ProtocolHost.o: $(SOURCE)/ProtocolHost.c $(SOURCE)/protocol-test.h $(BUILD)/config
	$(CC) $(CFLAGS) -std=c11 $(WARNINGS) $(PURPLE_CFLAGS) -c "$<" -o "$@"

$(BUILD)/ProtocolHost: $(BUILD)/ProtocolHost.o
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -o "$@" "$<" $(PURPLE_LIBS) $(BACKEND_LIBS) -ldl

$(BUILD)/libvoc-barev.so: $(CORE_OBJECTS) $(BUILD)/runtime.o $(BUILD)/protocol.o $(SOURCE)/exports.map
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -shared $(EXPORT_FLAGS) -o "$@" $(CORE_OBJECTS) "$(BUILD)/runtime.o" "$(BUILD)/protocol.o" @"$(BUILD)/protocol-objects.rsp" $(PURPLE_LIBS) $(BACKEND_LIBS) -lm

$(BUILD)/TestHost.o: $(SOURCE)/TestHost.c $(SOURCE)/test-api.h $(BUILD)/config | check $(BUILD)
	$(CC) $(CFLAGS) -std=c11 $(WARNINGS) $(PURPLE_CFLAGS) -c "$<" -o "$@"

$(BUILD)/TestHost: $(BUILD)/TestHost.o
	$(LINK) $(CFLAGS) $(LDFLAGS) $(BACKEND_LDFLAGS) -o "$@" "$<" $(PURPLE_LIBS) -ldl $(BACKEND_LIBS)
