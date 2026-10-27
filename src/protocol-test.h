/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BAREV_PROTOCOL_TEST_H
#define BAREV_PROTOCOL_TEST_H
#include <libpurple/account.h>
#include <stdint.h>
typedef struct {
    unsigned version;
    int32_t (*unit)(void);
    gboolean (*fixture)(const char *local, const char *peer);
    int (*port)(PurpleAccount *account);
    void (*tick)(PurpleAccount *account, unsigned seconds);
    unsigned (*connections)(void);
} BarevProtocolTestAPI;
#endif
