/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BAREV_TRANSFERS_H
#define BAREV_TRANSFERS_H
#include <libpurple/ft.h>
#include <netinet/in.h>
#include <stdint.h>

typedef struct BarevTransfers BarevTransfers;
typedef gboolean (*BarevTransferPeer)(gpointer owner, const char *name,
    int32_t *stream, int32_t *contact, struct in6_addr *peer);

BarevTransfers *BarevTransfers_New(PurpleAccount *account, int32_t handle,
    const struct in6_addr *local, const char *address, gboolean fixture,
    BarevTransferPeer peer, void (*flush)(gpointer owner), gpointer owner);
PurpleXfer *BarevTransfers_NewXfer(BarevTransfers *context, const char *who);
void BarevTransfers_Offers(BarevTransfers *context, int32_t stream);
void BarevTransfers_Sync(BarevTransfers *context);
void BarevTransfers_SetPreview(BarevTransfers *context, void (*preview)(gpointer, PurpleXfer *));
void BarevTransfers_Close(BarevTransfers *context);
gboolean BarevTransfers_Idle(void);
#endif
