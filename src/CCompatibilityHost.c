/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Drive an unmodified C Barev receiver without opening network listeners. */
#include <glib.h>
#include <gmodule.h>
#include <libpurple/blist.h>
#include <libpurple/connection.h>
#include <libpurple/conversation.h>
#include <libpurple/core.h>
#include <libpurple/eventloop.h>
#include <libpurple/imgstore.h>
#include <libpurple/plugin.h>
#include <libpurple/util.h>
#include <libpurple/xmlnode.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "image-ui.h"

static unsigned delivered;

G_MODULE_EXPORT int bonjour_jabber_start(void *data)
{ (void)data; return -1; }

static void written(PurpleConversation *conversation, const char *who, const char *alias,
                    const char *message, PurpleMessageFlags flags, time_t when)
{
    const char *start, *end;
    GData *attributes;
    gchar *encoded;
    (void)conversation; (void)who; (void)alias; (void)when;
    if (!(flags & PURPLE_MESSAGE_RECV)) return;
    if (purple_markup_find_tag("img", message, &start, &end, &attributes)) {
        const char *value = g_datalist_get_data(&attributes, "id");
        PurpleStoredImage *image = value ? purple_imgstore_find_by_id(atoi(value)) : NULL;
        if (!image) g_error("C receiver supplied no preview image");
        encoded = g_base64_encode(purple_imgstore_get_data(image), purple_imgstore_get_size(image));
        g_print("IMAGE %s\n", encoded); g_free(encoded); g_datalist_clear(&attributes);
    } else {
        encoded = g_base64_encode((const guchar *)message, strlen(message));
        g_print("MARKUP %s\n", encoded); g_free(encoded);
    }
    ++delivered;
}

#define LOAD(name, target) do { \
    gpointer symbol = NULL; \
    if (!g_module_symbol(module, name, &symbol)) g_error("Missing C receiver API: %s", name); \
    memcpy(&(target), &symbol, sizeof(target)); \
} while (0)

int main(int argc, char **argv)
{
    PurpleEventLoopUiOps events = {.timeout_add = g_timeout_add, .timeout_remove = g_source_remove,
                                   .timeout_add_seconds = g_timeout_add_seconds};
    PurpleConversationUiOps conversations = {.write_conv = written};
    PurplePlugin *plugin;
    PurpleAccount *account;
    PurpleBuddy *buddy;
    GModule *module;
    gchar *bytes = NULL;
    gsize size = 0;
    void (*packet)(PurpleBuddy *, xmlnode *);
    BarevImageUI *(*create)(PurpleAccount *, const BarevImageBackend *);
    void (*event)(BarevImageUI *, const char *, int, int, size_t, const char *, const char *, const guchar *, size_t);
    void (*close_ui)(BarevImageUI *);
    if (argc != 5) return 2;
    purple_util_set_user_dir(argv[1]); purple_eventloop_set_ui_ops(&events);
    if (!purple_core_init("barev-c-compatibility")) return 3;
    purple_conversations_set_ui_ops(&conversations);
    purple_set_blist(purple_blist_new());
    plugin = purple_plugins_find_with_id("prpl-barev"); if (plugin) purple_plugin_destroy(plugin);
    plugin = purple_plugin_probe(argv[2]);
    if (!plugin || !purple_plugin_load(plugin)) return 4;
    purple_plugins_probe("barev-test-no-scan");
    module = g_module_open(argv[2], G_MODULE_BIND_LOCAL); if (!module) return 5;
    account = purple_account_new("fixture", "prpl-barev"); purple_accounts_add(account);
    purple_account_set_enabled(account, purple_core_get_ui(), TRUE);
    if (!purple_account_get_connection(account)) return 6;
    buddy = purple_buddy_new(account, "peer@200::2", NULL);
    purple_blist_add_buddy(buddy, NULL, NULL, NULL);
    if (!g_file_get_contents(argv[4], &bytes, &size, NULL)) return 7;
    if (!strcmp(argv[3], "markup")) {
        xmlnode *node = xmlnode_from_str(bytes, size);
        if (!node) return 8;
        LOAD("bonjour_jabber_process_packet", packet);
        packet(buddy, node); xmlnode_free(node);
    } else if (!strcmp(argv[3], "image")) {
        BarevImageBackend backend = {0}; BarevImageUI *ui;
        LOAD("BarevImageUI_New", create); LOAD("BarevImageUI_Event", event); LOAD("BarevImageUI_Close", close_ui);
        ui = create(account, &backend);
        event(ui, "peer@200::2", 0, 2, size, "image", "", (const guchar *)bytes, size);
        close_ui(ui);
    } else return 9;
    g_free(bytes); purple_account_disconnect(account); purple_core_quit(); g_module_close(module);
    return delivered == 1 ? 0 : 10;
}
