/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <glib.h>
#include <gmodule.h>
#include <libpurple/plugin.h>
#include <libpurple/eventloop.h>
#include <libpurple/version.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "BarevBridge.h"
#include "Modules.h"
#include "Heap.h"
#include "host.h"
#include "test-api.h"
#include "runtime.h"

_Static_assert(sizeof(gboolean) == sizeof(INT32), "gboolean needs a C int adapter");
_Static_assert(sizeof(INT32) == 4 && sizeof(BOOLEAN) == 1, "VOC scalar ABI mismatch");
_Static_assert(sizeof(ADDRESS) == sizeof(void *), "opaque handles need pointer width");

typedef struct {
    PurplePlugin *plugin;
    guint source;
    int32_t handle;
} PluginState;

static PluginState *state;
static gboolean unload_during_reentry, nested_unload_refused;
static int32_t finalizer_count;

static gboolean enter(HostFrame *frame)
{
    return BarevRuntime_Enter(frame);
}

static void leave(HostFrame *frame)
{
    BarevRuntime_Leave(frame);
}

static gboolean valid_bytes(const char *data, int32_t length)
{
    return data && length >= 0 && length <= BarevBridge_ByteLimit() &&
        !memchr(data, 0, (size_t)length) && g_utf8_validate(data, length, NULL);
}

int32_t BarevHost_Reenter(void)
{
    HostFrame frame;
    if (g_thread_self() != owner_thread || !depth || !enter(&frame)) return 0;
    if (unload_during_reentry && state)
        nested_unload_refused = !purple_plugin_unload(state->plugin);
    BarevBridge_Collect(1);
    leave(&frame);
    return 1;
}

static gboolean pulse(gpointer data)
{
    PluginState *current = data;
    HostFrame frame;
    gboolean keep;
    if (g_thread_self() != owner_thread || state != current || !enter(&frame)) return FALSE;
    keep = BarevBridge_Pulse(current->handle, (ADDRESS)(uintptr_t)current->plugin) != 0;
    if (!keep) current->source = 0;
    leave(&frame);
    return keep;
}

static gboolean plugin_load(PurplePlugin *plugin)
{
    static const char label[] = "Բարեւ 😀";
    HostFrame frame;
    PluginState *current;
    if (g_thread_self() != owner_thread || state || depth || !enter(&frame)) return FALSE;
    current = g_new0(PluginState, 1);
    current->plugin = plugin;
    current->handle = BarevBridge_Open((ADDRESS)(uintptr_t)plugin);
    if (!current->handle || !valid_bytes(label, sizeof(label)-1) ||
        !BarevBridge_Put(current->handle, (ADDRESS)(uintptr_t)plugin,
                         (CHAR *)label, sizeof(label), sizeof(label)-1)) {
        if (current->handle) BarevBridge_Close(current->handle, (ADDRESS)(uintptr_t)plugin);
        g_free(current);
        leave(&frame);
        return FALSE;
    }
    state = current;
    current->source = purple_timeout_add(10, pulse, current);
    if (!current->source) {
        BarevBridge_Close(current->handle, (ADDRESS)(uintptr_t)plugin);
        state = NULL;
        g_free(current);
        leave(&frame);
        return FALSE;
    }
    plugin->extra = current;
    leave(&frame);
    return TRUE;
}

static gboolean plugin_unload(PurplePlugin *plugin)
{
    HostFrame frame;
    PluginState *current;
    if (g_thread_self() != owner_thread || depth) return FALSE;
    if (!state) return TRUE;
    if (state->plugin != plugin || !enter(&frame)) return FALSE;
    current = state;
    if (current->source && !purple_timeout_remove(current->source)) {
        leave(&frame);
        return FALSE;
    }
    state = NULL;
    plugin->extra = NULL;
    BarevBridge_Reset();
    g_free(current);
    leave(&frame);
    return TRUE;
}

static void shutdown_runtime(void)
{
    HostFrame frame;
    if (g_thread_self() != owner_thread) g_error("Foreign-thread Oberon runtime destruction");
    if (!initialized || closed) return;
    if (depth || state || !enter(&frame))
        g_error("Oberon runtime destroyed while callbacks are still reachable");
    BarevBridge_Reset();
    Heap_FINALL();
    finalizer_count = BarevBridge_Finalized();
    leave(&frame);
    BarevRuntime_Release();
}

static void plugin_destroy(PurplePlugin *plugin)
{
    if (g_thread_self() != owner_thread) g_error("Foreign-thread Oberon plugin destruction");
    if (state && state->plugin == plugin && !plugin_unload(plugin))
        g_error("Cannot destroy an active Oberon plugin");
    shutdown_runtime();
}

void BarevPlugin_Initialize(void) { BarevBridge__init(); }
gboolean BarevPlugin_Idle(void) { return state == NULL; }
void BarevPlugin_Shutdown(void) { shutdown_runtime(); }

static PurplePluginInfo info = {
    .magic = PURPLE_PLUGIN_MAGIC,
    .major_version = PURPLE_MAJOR_VERSION,
    .minor_version = PURPLE_MINOR_VERSION,
    .type = PURPLE_PLUGIN_STANDARD,
    .priority = PURPLE_PRIORITY_DEFAULT,
    .id = "barev-oberon-bridge",
    .name = "Barev Oberon bridge",
    .version = "0.1",
    .summary = "Oberon callback and lifecycle development module",
    .description = "Exercises retained Oberon state through libpurple and GLib callbacks.",
    .homepage = "https://github.com/norayr/barev-purple",
    .load = plugin_load,
    .unload = plugin_unload,
    .destroy = plugin_destroy
};

static void init_plugin(PurplePlugin *plugin) { (void)plugin; }
PURPLE_INIT_PLUGIN(barev_oberon, init_plugin, info)

#ifdef BAREV_BRIDGE_TEST
static int32_t test_open(uintptr_t owner)
{
    HostFrame frame;
    int32_t result;
    if (g_thread_self() != owner_thread || !state || !enter(&frame)) return 0;
    result = BarevBridge_Open((ADDRESS)owner);
    leave(&frame);
    return result;
}

static gboolean test_close(int32_t handle, uintptr_t owner)
{
    HostFrame frame;
    gboolean result;
    if (g_thread_self() != owner_thread || !state || !enter(&frame)) return FALSE;
    result = BarevBridge_Close(handle, (ADDRESS)owner) != 0;
    leave(&frame);
    return result;
}

static gboolean test_text(int32_t handle, uintptr_t owner, const char *data,
                          int32_t length, gboolean compare)
{
    HostFrame frame;
    gboolean result;
    if (g_thread_self() != owner_thread || !state || !enter(&frame)) return FALSE;
    if (!valid_bytes(data, length)) {
        leave(&frame);
        return FALSE;
    }
    if (compare) result = BarevBridge_Matches(handle, (ADDRESS)owner, (CHAR *)data, length, length) != 0;
    else result = BarevBridge_Put(handle, (ADDRESS)owner, (CHAR *)data, length, length) != 0;
    leave(&frame);
    return result;
}

static gboolean test_put(int32_t handle, uintptr_t owner, const char *data, int32_t length)
{ return test_text(handle, owner, data, length, FALSE); }
static gboolean test_matches(int32_t handle, uintptr_t owner, const char *data, int32_t length)
{ return test_text(handle, owner, data, length, TRUE); }

static gboolean test_collect(gboolean stack)
{
    HostFrame frame;
    if (g_thread_self() != owner_thread || !state || !enter(&frame)) return FALSE;
    BarevBridge_Collect(stack != 0);
    leave(&frame);
    return TRUE;
}

static gboolean test_nested(void)
{
    HostFrame frame;
    gboolean result;
    if (g_thread_self() != owner_thread || !state || !enter(&frame)) return FALSE;
    result = BarevBridge_Nested() != 0;
    leave(&frame);
    return result;
}

static gboolean test_unload_nested(void)
{
    gboolean result;
    if (g_thread_self() != owner_thread) return FALSE;
    unload_during_reentry = TRUE;
    nested_unload_refused = FALSE;
    result = test_nested();
    unload_during_reentry = FALSE;
    return result && nested_unload_refused;
}

static void test_stats(BarevStats *result)
{
    HostFrame frame;
    memset(result, 0, sizeof(*result));
    result->version = 1;
    if (g_thread_self() != owner_thread) return;
    result->initialized = initialized;
    result->closed = closed;
    result->active = state != NULL;
    result->depth = depth;
    result->blocks = allocation_count;
    result->bytes = allocation_bytes;
    result->finalized = finalizer_count;
    if (initialized && !closed && enter(&frame)) {
        result->count = BarevBridge_Count();
        result->finalized = BarevBridge_Finalized();
        if (state) {
            INT32 ticks = BarevBridge_Ticks(state->handle, (ADDRESS)(uintptr_t)state->plugin);
            if (ticks < 0) g_error("Plugin lost its retained Oberon session");
            result->ticks = (unsigned)ticks;
        }
        leave(&frame);
    }
}

G_MODULE_EXPORT const BarevTestAPI *barev_oberon_test_api(void)
{
    static const BarevTestAPI api = {
        1, test_stats, test_open, test_close, test_put, test_matches,
        test_collect, test_nested, test_unload_nested
    };
    return &api;
}
#endif
