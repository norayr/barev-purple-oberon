/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BAREV_RUNTIME_H
#define BAREV_RUNTIME_H
#include <glib.h>
#include "SYSTEM.h"

typedef struct { ADDRESS previous; char **argv; } HostFrame;
extern GThread *owner_thread;
extern gboolean initialized, closed;
extern unsigned depth;
extern size_t allocation_count, allocation_bytes;

gboolean BarevRuntime_Enter(HostFrame *frame);
void BarevRuntime_Leave(HostFrame *frame);
void BarevRuntime_Release(void);
void BarevPlugin_Initialize(void);
gboolean BarevPlugin_Idle(void);
void BarevPlugin_Shutdown(void);
#endif
