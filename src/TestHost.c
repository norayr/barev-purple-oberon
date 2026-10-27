/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <glib.h>
#include <gmodule.h>
#include <libpurple/plugin.h>
#include <libpurple/eventloop.h>
#include <libpurple/prefs.h>
#include <libpurple/signals.h>
#include <libpurple/util.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "test-api.h"

static unsigned checks;
static gboolean refuse_timer, refuse_remove;
static guint last_source;

/* Colliding host exports make accidental runtime symbol interposition fatal. */
void Modules_Init(int32_t argc, intptr_t argv)
{
    (void)argc; (void)argv;
    g_error("Plugin called the host's Modules_Init");
}

void Heap_GC(unsigned char stack)
{
    (void)stack;
    g_error("Plugin called the host's Heap_GC");
}

intptr_t Platform_OSAllocate(intptr_t size)
{
    (void)size;
    g_error("Plugin called the host's Platform_OSAllocate");
    return 0;
}

static guint timer_add(guint interval, GSourceFunc callback, gpointer data)
{
    if (refuse_timer) return 0;
    last_source = g_timeout_add(interval, callback, data);
    return last_source;
}

static gboolean timer_remove(guint source)
{
    if (refuse_remove) return FALSE;
    return g_source_remove(source);
}

static void check(gboolean value, const char *name)
{
    if (!value) g_error("Barev bridge check failed: %s", name);
    ++checks;
}

static void host_signal(int number) { (void)number; }

static void production_cycle(PurplePlugin *plugin)
{
    unsigned reload;
    for (reload = 0; reload < 8; ++reload) {
        check(purple_plugin_load(plugin), "production plugin load");
        check(g_main_context_find_source_by_id(NULL, last_source) != NULL,
              "production timer registered");
        g_usleep(15000);
        check(g_main_context_iteration(NULL, FALSE), "production timer dispatched");
        check(purple_plugin_unload(plugin), "production plugin unload");
        check(g_main_context_find_source_by_id(NULL, last_source) == NULL,
              "production timer removed");
    }
    check(purple_plugin_load(plugin), "production reload before destruction");
    purple_plugin_destroy(plugin);
    check(g_main_context_find_source_by_id(NULL, last_source) == NULL,
          "production destruction removes timer");
}

static void wait_ticks(const BarevTestAPI *api, unsigned minimum)
{
    BarevStats stats;
    gint64 end = g_get_monotonic_time() + 3000000;
    do {
        g_main_context_iteration(NULL, FALSE);
        api->stats(&stats);
        if (stats.ticks >= minimum) return;
        g_usleep(1000);
    } while (g_get_monotonic_time() < end);
    g_error("Barev bridge timer deadline exceeded");
}

static gpointer other_thread(gpointer data)
{
    const BarevTestAPI *api = data;
    return GINT_TO_POINTER(!api->open(123) && !api->collect(TRUE) && !api->nested());
}

static void exercise(const BarevTestAPI *api)
{
    static const char text[] = "Բարեւ աշխարհ 😀";
    const uintptr_t owner = 0x12345678, stranger = 0xabcdef;
    int32_t handle, old, handles[31];
    char *copy, *large;
    BarevStats before, after;
    unsigned index;

    check(api->version == 1, "test interface version");
    api->stats(&before);
    check(before.initialized && !before.closed && before.active && !before.depth &&
          before.count == 1 && before.blocks && before.bytes, "private runtime initialized");
    check(!api->open(0), "invalid opaque owner");
    handle = api->open(owner);
    check(handle > 0, "opaque session handle");
    copy = g_strdup(text);
    check(api->put(handle, owner, copy, strlen(copy)), "UTF-8 transfer");
    memset(copy, 'x', strlen(copy));
    g_free(copy);
    check(api->collect(TRUE) && api->collect(FALSE), "forced stack and global-root collections");
    check(api->matches(handle, owner, text, sizeof(text)-1), "retained copy survives collections");
    check(!api->matches(handle, stranger, text, sizeof(text)-1), "owner checked");
    check(!api->put(handle, owner, "\xc0\xaf", 2), "overlong UTF-8 rejected");
    check(!api->put(handle, owner, "\xed\xa0\x80", 3), "UTF-8 surrogate rejected");
    check(!api->put(handle, owner, "\xf0\x9f\x98", 3), "incomplete UTF-8 rejected");
    check(!api->put(handle, owner, "a\0b", 3), "embedded NUL rejected");
    check(!api->put(handle, owner, NULL, 0) && !api->put(handle, owner, text, -1), "invalid buffer arguments");
    check(api->matches(handle, owner, text, sizeof(text)-1), "failed writes preserve state");
    large = g_malloc0(4098);
    memset(large, 'a', 4097);
    check(!api->put(handle, owner, large, 4097), "buffer limit exceeded");
    check(api->put(handle, owner, large, 4096), "buffer limit accepted");
    g_free(large);
    check(api->put(handle, owner, "", 0) && api->matches(handle, owner, "", 0), "empty buffer");

    api->stats(&before);
    check(api->nested(), "reentrant callback preserves outer stack roots");
    check(api->collect(FALSE), "temporary finalization");
    api->stats(&after);
    check(after.finalized == before.finalized+64, "stack-only objects collected after callback");
    check(api->try_unload_nested(), "unload refused during callback");
    check(api->collect(FALSE), "nested-unload temporary collection");
    check(GPOINTER_TO_INT(g_thread_join(g_thread_new("foreign-callback", other_thread, (gpointer)api))),
          "foreign-thread entry rejected");

    old = handle;
    check(api->close(handle, owner) && !api->close(handle, owner), "close is generation checked");
    handle = api->open(owner);
    check(handle && handle != old, "reused slot has a new generation");
    check(!api->put(old, owner, text, sizeof(text)-1) && !api->close(old, owner), "stale handle rejected");
    check(api->close(handle, owner), "replacement closed");
    for (index = 0; index < G_N_ELEMENTS(handles); ++index) {
        handles[index] = api->open(owner);
        check(handles[index] > 0, "bounded slot allocation");
    }
    check(!api->open(owner), "slot exhaustion returns failure");
    for (index = 0; index < G_N_ELEMENTS(handles); ++index)
        check(api->close(handles[index], owner), "bounded slot release");
    check(!api->close(INT32_MAX, owner) && !api->close(-1, owner), "invalid handle range");
    wait_ticks(api, 3);
    api->stats(&after);
    check(after.count == 1 && !after.depth && after.ticks >= 3, "GLib callback state");
}

static void instrumented_cycle(PurplePlugin *plugin, GModule *reference, unsigned cycle)
{
    gpointer raw_api;
    const BarevTestAPI *(*get_api)(void);
    const BarevTestAPI *api;
    BarevStats stats;
    int32_t finalized;
    unsigned reload;

    check(g_module_symbol(reference, "barev_oberon_test_api", &raw_api), "test interface lookup");
    memcpy(&get_api, &raw_api, sizeof(get_api));
    api = get_api();
    api->stats(&stats);
    check(!stats.initialized && !stats.active && !stats.blocks, "probing has no runtime side effects");
    refuse_timer = TRUE;
    check(!purple_plugin_load(plugin), "timer registration failure rejects loading");
    refuse_timer = FALSE;
    api->stats(&stats);
    check(stats.initialized && !stats.closed && !stats.active && !stats.count && !stats.depth,
          "failed load releases session state");
    check(purple_plugin_load(plugin), "real libpurple plugin load");
    exercise(api);
    check(purple_plugin_is_loaded(plugin), "nested unload keeps libpurple registration loaded");
    refuse_remove = TRUE;
    check(!purple_plugin_unload(plugin), "timer removal failure refuses unloading");
    refuse_remove = FALSE;
    api->stats(&stats);
    check(stats.active && stats.count == 1 && !stats.depth, "failed unload preserves callback state");
    wait_ticks(api, stats.ticks+1);
    for (reload = 0; reload < 8; ++reload) {
        check(purple_plugin_unload(plugin), "logical plugin unload");
        api->stats(&stats);
        check(!stats.active && !stats.count && !stats.depth, "unload clears roots and timer state");
        while (g_main_context_iteration(NULL, FALSE)) {}
        check(!api->open(1) && !api->nested(), "callbacks gated while inactive");
        check(purple_plugin_load(plugin), "logical plugin reload");
        wait_ticks(api, 1);
    }
    if (!(cycle % 2)) check(purple_plugin_unload(plugin), "final logical unload");
    api->stats(&stats);
    finalized = stats.finalized;
    purple_plugin_destroy(plugin);
    api->stats(&stats);
    check(stats.closed && !stats.active && !stats.depth && !stats.count &&
          !stats.blocks && !stats.bytes, "destroy finalizes and frees the private runtime");
    check(!api->open(1) && !api->collect(TRUE), "destroyed runtime refuses entry");
    check(stats.finalized == finalized+1, "destruction runs the rooted lifetime finalizer");
}

int main(int argc, char **argv)
{
    PurpleEventLoopUiOps event_ops = {
        .timeout_add = timer_add,
        .timeout_remove = timer_remove,
        .timeout_add_seconds = g_timeout_add_seconds
    };
    struct sigaction action = {0}, previous, current;
    unsigned cycle;
    gpointer raw_api;
    gboolean production;

    check(argc == 3 || (argc == 4 && !strcmp(argv[3], "--production")),
          "plugin path and isolated user directory");
    production = argc == 4;
    purple_util_set_user_dir(argv[2]);
    purple_signals_init();
    purple_prefs_init();
    purple_plugins_init();
    purple_eventloop_set_ui_ops(&event_ops);
    action.sa_handler = host_signal;
    sigemptyset(&action.sa_mask);
    check(sigaction(SIGSEGV, &action, &previous) == 0, "host signal handler installed");

    for (cycle = 0; cycle < 8; ++cycle) {
        PurplePlugin *plugin = purple_plugin_probe(argv[1]);
        GModule *reference;
        void *mapped;
        check(plugin && !plugin->unloadable && plugin->info &&
              !strcmp(plugin->info->id, "barev-oberon-bridge"), "real libpurple plugin probe");
        reference = g_module_open(argv[1], G_MODULE_BIND_LOCAL);
        check(reference != NULL, "shared object reference acquired");
        if (production) {
            check(!g_module_symbol(reference, "barev_oberon_test_api", &raw_api),
                  "production plugin keeps test interface private");
            production_cycle(plugin);
        } else {
            instrumented_cycle(plugin, reference, cycle);
        }
        check(g_module_close(reference), "shared object reference released");
        mapped = dlopen(argv[1], RTLD_NOW | RTLD_NOLOAD);
        check(mapped == NULL, "shared object physically unmapped");
        check(sigaction(SIGSEGV, NULL, &current) == 0 && current.sa_handler == host_signal,
              "host signal handler preserved");
    }
    check(sigaction(SIGSEGV, &previous, NULL) == 0, "host signal handler restored");
    purple_plugins_uninit();
    purple_prefs_uninit();
    purple_signals_uninit();
    purple_eventloop_set_ui_ops(NULL);
    printf("Barev Oberon libpurple %s checks passed: %u\n",
           production ? "production lifecycle" : "retention and lifecycle", checks);
    return 0;
}
