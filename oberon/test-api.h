/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BAREV_OBERON_TEST_API_H
#define BAREV_OBERON_TEST_API_H

#include <glib.h>
#include <stdint.h>
#include <stddef.h>

typedef struct {
    unsigned version;
    gboolean initialized, closed, active;
    unsigned depth, ticks;
    int32_t count, finalized;
    size_t blocks, bytes;
} BarevStats;

typedef struct {
    unsigned version;
    void (*stats)(BarevStats *result);
    int32_t (*open)(uintptr_t owner);
    gboolean (*close)(int32_t handle, uintptr_t owner);
    gboolean (*put)(int32_t handle, uintptr_t owner, const char *data, int32_t length);
    gboolean (*matches)(int32_t handle, uintptr_t owner, const char *data, int32_t length);
    gboolean (*collect)(gboolean stack);
    gboolean (*nested)(void);
    gboolean (*try_unload_nested)(void);
} BarevTestAPI;

#endif
