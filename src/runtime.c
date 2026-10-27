/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <gmodule.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include "runtime.h"
#include "Modules.h"

typedef union Allocation Allocation;
union Allocation {
    struct { Allocation *next, *previous; size_t size; } info;
    max_align_t alignment;
};
static Allocation *allocations;
GThread *owner_thread;
gboolean initialized, closed;
unsigned depth;
size_t allocation_count, allocation_bytes;

/* Track cross-object Platform allocation calls for this private runtime. */
ADDRESS __wrap_Platform_OSAllocate(ADDRESS size)
{
    Allocation *block;
    if (size <= 0 || (uintmax_t)size > SIZE_MAX - sizeof(*block)) return 0;
    block = malloc(sizeof(*block) + (size_t)size);
    if (!block) return 0;
    block->info.next = allocations;
    block->info.previous = NULL;
    block->info.size = (size_t)size;
    if (allocations) allocations->info.previous = block;
    allocations = block;
    ++allocation_count;
    allocation_bytes += (size_t)size;
    return (ADDRESS)(uintptr_t)(block + 1);
}

void __wrap_Platform_OSFree(ADDRESS address)
{
    Allocation *block;
    if (!address) return;
    for (block = allocations; block; block = block->info.next)
        if ((uintptr_t)(block + 1) == (uintptr_t)address) break;
    if (!block) g_error("Foreign allocation passed to the private Oberon runtime");
    if (block->info.previous) block->info.previous->info.next = block->info.next;
    else allocations = block->info.next;
    if (block->info.next) block->info.next->info.previous = block->info.previous;
    --allocation_count;
    allocation_bytes -= block->info.size;
    free(block);
}

gboolean BarevRuntime_Enter(HostFrame *frame)
{
    static char *arguments[] = {"voc-barev", NULL};
    if (g_thread_self() != owner_thread || closed) return FALSE;
    frame->previous = Modules_MainStackFrame;
    frame->argv = arguments;
    if (!depth) Modules_MainStackFrame = (ADDRESS)(uintptr_t)&frame->argv;
    ++depth;
    if (!initialized) {
        Modules_Init(1, (ADDRESS)(uintptr_t)&frame->argv);
        initialized = TRUE;
        BarevPlugin_Initialize();
    }
    return TRUE;
}

void BarevRuntime_Leave(HostFrame *frame)
{
    if (!depth) g_error("Unbalanced Oberon callback boundary");
    --depth;
    if (!depth) Modules_MainStackFrame = frame->previous;
}

void BarevRuntime_Release(void)
{
    if (depth || !BarevPlugin_Idle()) g_error("Cannot release a reachable Oberon runtime");
    closed = TRUE;
    while (allocations) __wrap_Platform_OSFree((ADDRESS)(uintptr_t)(allocations + 1));
    if (allocation_count || allocation_bytes) g_error("Private runtime allocation accounting mismatch");
}

G_MODULE_EXPORT const gchar *g_module_check_init(GModule *module)
{
    (void)module;
    owner_thread = g_thread_self();
    return NULL;
}

G_MODULE_EXPORT void g_module_unload(GModule *module)
{
    (void)module;
    if (g_thread_self() != owner_thread || depth || !BarevPlugin_Idle())
        g_error("Cannot unmap an active Oberon plugin");
    BarevPlugin_Shutdown();
}
