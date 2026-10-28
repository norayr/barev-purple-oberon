/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <glib.h>
#include <glib-unix.h>
#include <gmodule.h>
#include <libpurple/account.h>
#include <libpurple/blist.h>
#include <libpurple/buddyicon.h>
#include <libpurple/imgstore.h>
#include <libpurple/connection.h>
#include <libpurple/core.h>
#include <libpurple/debug.h>
#include <libpurple/debug.h>
#include <libpurple/eventloop.h>
#include <libpurple/notify.h>
#include <libpurple/ft.h>
#include <libpurple/request.h>
#include <libpurple/plugin.h>
#include <libpurple/prefs.h>
#include <libpurple/signals.h>
#include <libpurple/status.h>
#include <libpurple/server.h>
#include <libpurple/conversation.h>
#include <libpurple/util.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "protocol-test.h"

typedef struct { PurpleInputFunction function; gpointer data; gboolean owned; } Input;
typedef struct { GSourceFunc function; gpointer data; gboolean owned; } Timer;
static GMainLoop *loop;
static PurpleAccount *account;
static PurpleBuddy *buddy;
static char *buddy_name;
static const BarevProtocolTestAPI *api;
static gboolean disconnect_on_online;
static gboolean disconnect_on_message;
static gboolean disconnect_on_typing, disconnect_on_avatar;
static gboolean fail_input, fail_timer;
static gboolean fail_remove;
static gboolean channel_io;
static unsigned live_inputs, live_timers;
static PurplePlugin *plugin;
static PurpleXfer *last_file;
static gboolean disconnect_on_file, disconnect_on_file_complete;
static GCallback file_accept, file_cancel;
static PurpleRequestActionCb action_accept, action_cancel;
static gpointer file_argument, action_argument;
static int file_request_handle, action_request_handle;

static void new_file(PurpleXfer *file)
{
    if (last_file) purple_xfer_unref(last_file);
    last_file = file; purple_xfer_ref(file);
    printf("FILE-NEW %d\n", purple_xfer_get_type(file));
    if (disconnect_on_file) { disconnect_on_file = FALSE; purple_account_disconnect(account); }
}
static void file_progress(PurpleXfer *file, double fraction)
{
    (void)fraction;
    if (disconnect_on_file_complete && purple_xfer_is_completed(file)) {
        disconnect_on_file_complete = FALSE; purple_account_disconnect(account);
    }
}
static void file_added(PurpleXfer *file)
{ (void)file; puts("FILE-ADDED"); }
static void *choose_file(const char *title, const char *filename, gboolean save,
    GCallback okay, GCallback cancel, PurpleAccount *purple, const char *who,
    PurpleConversation *conversation, void *argument)
{
    (void)title; (void)filename; (void)save; (void)purple; (void)who; (void)conversation;
    file_accept = okay; file_cancel = cancel; file_argument = argument;
    puts("FILE-CHOOSE"); return &file_request_handle;
}
static void *request_file_action(const char *title, const char *primary, const char *secondary,
    int selected, PurpleAccount *purple, const char *who, PurpleConversation *conversation,
    void *argument, size_t count, va_list actions)
{
    size_t i;
    (void)title; (void)primary; (void)secondary; (void)selected; (void)purple; (void)who; (void)conversation;
    action_accept = action_cancel = NULL; action_argument = argument;
    for (i = 0; i < count; ++i) {
        const char *label = va_arg(actions, const char *);
        PurpleRequestActionCb callback = va_arg(actions, PurpleRequestActionCb);
        if (strstr(label, "Accept")) action_accept = callback;
        else action_cancel = callback;
    }
    puts("FILE-REQUEST"); return &action_request_handle;
}
static void close_file_request(PurpleRequestType type, void *handle)
{ (void)type; (void)handle; }
static int info_handle;

static void *show_info(PurpleConnection *gc, const char *who, PurpleNotifyUserInfo *info)
{
    GList *entry;
    (void)gc; (void)who;
    for (entry = purple_notify_user_info_get_entries(info); entry; entry = entry->next) {
        const char *label = purple_notify_user_info_entry_get_label(entry->data);
        const char *value = purple_notify_user_info_entry_get_value(entry->data);
        char *encoded = g_base64_encode((const guchar *)(value ? value : ""), value ? strlen(value) : 0);
        printf("INFO %s %s\n", label ? label : "-", encoded); g_free(encoded);
        if (label && !strcmp(label, "Avatar") && value) {
            int id = 0;
            if (sscanf(value, "<img id=\"%d\"", &id) == 1) {
                PurpleStoredImage *image = purple_imgstore_find_by_id(id);
                if (image) {
                    char *data = g_base64_encode(purple_imgstore_get_data(image), purple_imgstore_get_size(image));
                    printf("INFO-IMAGE %s\n", data); g_free(data);
                }
            }
        }
    }
    puts("INFO-END");
    return &info_handle;
}
static void close_info(PurpleNotifyType type, void *handle)
{ (void)type; (void)handle; }

static gboolean plugin_function(const void *function)
{
    Dl_info info;
    return dladdr(function, &info) && strstr(info.dli_fname, "/libvoc-barev");
}
static void input_free(gpointer data)
{ Input *input = data; if (input->owned) --live_inputs; g_free(input); }
static void timer_free(gpointer data)
{ Timer *timer = data; if (timer->owned) --live_timers; g_free(timer); }
static gboolean timer_ready(gpointer data)
{
    Timer *timer = data;
    GSourceFunc function = timer->function;
    gpointer argument = timer->data;
    return function(argument);
}
static guint timeout_add(guint interval, GSourceFunc function, gpointer data)
{
    Timer *timer;
    if (fail_timer && plugin_function((const void *)function)) { fail_timer = FALSE; return 0; }
    timer = g_new0(Timer, 1); timer->function = function; timer->data = data;
    timer->owned = plugin_function((const void *)function);
    if (timer->owned) ++live_timers;
    return g_timeout_add_full(G_PRIORITY_DEFAULT, interval, timer_ready, timer, timer_free);
}
static guint timeout_seconds(guint interval, GSourceFunc function, gpointer data)
{
    Timer *timer = g_new0(Timer, 1);
    timer->function = function; timer->data = data;
    timer->owned = plugin_function((const void *)function);
    if (timer->owned) ++live_timers;
    return g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, interval, timer_ready, timer, timer_free);
}
static gboolean timeout_remove(guint source)
{
    if (fail_remove) { fail_remove = FALSE; return FALSE; }
    return g_source_remove(source);
}

static gboolean input_ready(gint fd, GIOCondition condition, gpointer data)
{
    Input *input = data;
    PurpleInputFunction function = input->function;
    gpointer argument = input->data;
    PurpleInputCondition purple = 0;
    if (condition & (G_IO_IN | G_IO_HUP | G_IO_ERR | G_IO_NVAL)) purple |= PURPLE_INPUT_READ;
    if (condition & G_IO_OUT) purple |= PURPLE_INPUT_WRITE;
    function(argument, fd, purple);
    return TRUE;
}
static gboolean channel_ready(GIOChannel *channel, GIOCondition condition, gpointer data)
{
    Input *input = data;
    PurpleInputFunction function = input->function;
    gpointer argument = input->data;
    PurpleInputCondition purple = 0;
    if (condition & (G_IO_IN | G_IO_HUP | G_IO_ERR)) purple |= PURPLE_INPUT_READ;
    if (condition & (G_IO_OUT | G_IO_HUP | G_IO_ERR | G_IO_NVAL)) purple |= PURPLE_INPUT_WRITE;
    function(argument, g_io_channel_unix_get_fd(channel), purple);
    return TRUE;
}
static guint input_add(int fd, PurpleInputCondition condition, PurpleInputFunction function, gpointer data)
{
    Input *input;
    GIOCondition flags = G_IO_HUP | G_IO_ERR | G_IO_NVAL;
    if (fail_input && plugin_function((const void *)function)) { fail_input = FALSE; return 0; }
    input = g_new0(Input, 1);
    input->function = function; input->data = data;
    if (condition & PURPLE_INPUT_READ) flags |= G_IO_IN;
    if (condition & PURPLE_INPUT_WRITE) flags |= G_IO_OUT;
    input->owned = plugin_function((const void *)function);
    if (input->owned) ++live_inputs;
    if (channel_io) {
        GIOChannel *channel = g_io_channel_unix_new(fd);
        guint source;
        flags = 0;
        if (condition & PURPLE_INPUT_READ) flags |= G_IO_IN | G_IO_HUP | G_IO_ERR;
        if (condition & PURPLE_INPUT_WRITE) flags |= G_IO_OUT | G_IO_HUP | G_IO_ERR | G_IO_NVAL;
        source = g_io_add_watch_full(channel, G_PRIORITY_DEFAULT, flags, channel_ready, input, input_free);
        g_io_channel_unref(channel);
        return source;
    }
    return g_unix_fd_add_full(G_PRIORITY_DEFAULT, fd, flags, input_ready, input, input_free);
}
static void signed_on(PurpleBuddy *who, gpointer data)
{
    (void)who; (void)data;
    puts("ONLINE");
    if (disconnect_on_online) purple_account_disconnect(account);
}
static void signed_off(PurpleBuddy *who, gpointer data)
{ (void)who; (void)data; puts("OFFLINE"); }
static void account_ready(PurpleConnection *gc, gpointer data)
{
    (void)gc; (void)data;
    printf("READY %d\n", api ? api->port(account) : 0);
}
static void report_disconnect(PurpleConnection *gc, PurpleConnectionError reason, const char *text)
{ (void)gc; (void)text; printf("ERROR %d\n", reason); }

static gboolean message_disconnect(gpointer data)
{
    (void)data;
    if (account && !purple_account_is_disconnected(account)) purple_account_disconnect(account);
    return FALSE;
}

static void message_received(PurpleAccount *purple, const char *sender, const char *message,
                             PurpleConversation *conversation, PurpleMessageFlags flags, gpointer data)
{
    char *encoded = g_base64_encode((const guchar *)message, strlen(message));
    (void)purple; (void)sender; (void)conversation; (void)flags; (void)data;
    printf("MESSAGE %s\n", encoded); g_free(encoded);
    /* libpurple emits this signal before constructing the conversation. Let
     * serv_got_im finish before disconnecting its connection. */
    if (disconnect_on_message) { disconnect_on_message = FALSE; g_idle_add(message_disconnect, NULL); }
}

static void conversation_written(PurpleConversation *conversation, const char *name, const char *alias,
                                 const char *message, PurpleMessageFlags flags, time_t timestamp)
{
    (void)conversation; (void)name; (void)alias; (void)timestamp;
    if ((flags & PURPLE_MESSAGE_SYSTEM) && g_str_has_prefix(message, "Message queued in memory"))
        printf("QUEUED-NOTICE %d\n", (flags & PURPLE_MESSAGE_NO_LOG) != 0);
}

static void typing_received(PurpleAccount *purple, const char *who, gpointer data)
{
    (void)purple; (void)who;
    printf("TYPING %d\n", GPOINTER_TO_INT(data));
    if (disconnect_on_typing) { disconnect_on_typing = FALSE; g_idle_add(message_disconnect, NULL); }
}

static void avatar_received(PurpleBuddy *who, gpointer data)
{
    (void)who; (void)data;
    puts("AVATAR-CHANGED");
    if (disconnect_on_avatar) { disconnect_on_avatar = FALSE; g_idle_add(message_disconnect, NULL); }
}

static gboolean debug_enabled(PurpleDebugLevel level, const char *category)
{
    (void)level;
    return category && !strcmp(category, "voc-barev");
}

static void debug_print(PurpleDebugLevel level, const char *category, const char *text)
{
    if (debug_enabled(level, category)) printf("DEBUG %s\n", text);
}

/* Test fixture for Pidgin's optional host-owned image conversion boundary. */
G_MODULE_EXPORT gpointer pidgin_convert_buddy_icon(PurplePlugin *prpl, const char *path, size_t *length)
{
    const char *converted = g_getenv("BAREV_TEST_CONVERTED_ICON_FILE");
    gchar *bytes = NULL;
    gsize size = 0;
    (void)prpl;
    if (!g_file_get_contents(converted ? converted : path, &bytes, &size, NULL)) return NULL;
    *length = size; puts("HOST-ICON-CONVERTED"); return bytes;
}

static char *decode(const char *encoded)
{
    gsize length;
    guchar *bytes = g_base64_decode(encoded, &length);
    if (memchr(bytes, 0, length) || !g_utf8_validate((char *)bytes, length, NULL)) { g_free(bytes); return NULL; }
    bytes = g_realloc(bytes, length+1); bytes[length] = 0;
    return (char *)bytes;
}

static gboolean command(gint fd, GIOCondition condition, gpointer data)
{
    char line[131073];
    unsigned seconds;
    (void)fd; (void)condition; (void)data;
    if (!fgets(line, sizeof(line), stdin) || !strcmp(line, "quit\n")) {
        g_main_loop_quit(loop);
        return FALSE;
    }
    if (sscanf(line, "tick %u", &seconds) == 1 && api) { api->tick(account, seconds); puts("TICK"); }
    else if (sscanf(line, "advance %u", &seconds) == 1 && api) { api->advance(account, seconds); puts("ADVANCED"); }
    else if (!strcmp(line, "disconnect\n")) { purple_account_disconnect(account); puts("DISCONNECTED"); }
    else if (!strcmp(line, "reconnect\n")) purple_account_connect(account);
    else if (!strcmp(line, "remove\n")) {
        purple_account_remove_buddy(account, buddy, purple_buddy_get_group(buddy));
        purple_blist_remove_buddy(buddy); buddy = NULL; puts("REMOVED");
    }
    else if (!strcmp(line, "add\n") && !buddy) {
        buddy = purple_buddy_new(account, buddy_name, NULL);
        purple_blist_add_buddy(buddy, NULL, NULL, NULL);
        purple_account_add_buddy(account, buddy);
        puts("ADDED");
    }
    else if (!strcmp(line, "reentrant\n")) { disconnect_on_online = TRUE; puts("ARMED"); }
    else if (!strcmp(line, "reentrant-message\n")) { disconnect_on_message = TRUE; puts("ARMED"); }
    else if (!strcmp(line, "reentrant-typing\n")) { disconnect_on_typing = TRUE; puts("ARMED"); }
    else if (!strcmp(line, "reentrant-avatar\n")) { disconnect_on_avatar = TRUE; puts("ARMED"); }
    else if (!strcmp(line, "reentrant-file\n")) { disconnect_on_file = TRUE; puts("ARMED"); }
    else if (!strcmp(line, "reentrant-file-complete\n")) { disconnect_on_file_complete = TRUE; puts("ARMED"); }
    else if (g_str_has_prefix(line, "typing ")) {
        PurpleConnection *gc = purple_account_get_connection(account);
        if (gc && buddy) purple_conversation_new(PURPLE_CONV_TYPE_IM, account, purple_buddy_get_name(buddy));
        unsigned refresh = gc && buddy ? serv_send_typing(gc, purple_buddy_get_name(buddy), atoi(line+7)) : 0;
        printf("TYPING-SENT %u\n", refresh);
    }
    else if (!strcmp(line, "buddy-typing\n")) {
        PurpleConversation *conversation = purple_find_conversation_with_account(PURPLE_CONV_TYPE_IM, buddy_name, account);
        printf("TYPING-STATE %d\n", conversation ? purple_conv_im_get_typing_state(PURPLE_CONV_IM(conversation)) : 0);
    }
    else if (g_str_has_prefix(line, "icon ")) {
        gsize length;
        guchar *bytes = g_base64_decode(line+5, &length);
        purple_buddy_icons_set_account_icon(account, bytes, length);
        puts("ICON-SET");
    }
    else if (!strcmp(line, "buddy-avatar\n")) {
        PurpleBuddyIcon *icon = buddy ? purple_buddy_get_icon(buddy) : NULL;
        if (icon) {
            size_t length;
            gconstpointer bytes = purple_buddy_icon_get_data(icon, &length);
            const char *hash = purple_buddy_icon_get_checksum(icon);
            char *encoded = g_base64_encode(bytes, length);
            printf("ICON %s %s\n", hash ? hash : "-", encoded); g_free(encoded);
        } else puts("ICON - -");
    }
    else if (!strcmp(line, "get-info\n")) {
        PurpleConnection *gc = purple_account_get_connection(account);
        if (gc && buddy) serv_get_info(gc, purple_buddy_get_name(buddy));
    }
    else if (!strcmp(line, "close-info\n")) {
        purple_notify_close(PURPLE_NOTIFY_USERINFO, &info_handle); puts("INFO-CLOSED");
    }
    else if (g_str_has_prefix(line, "file-send ")) {
        gsize length;
        guchar *bytes = g_base64_decode(line+10, &length);
        char *path = g_build_filename(purple_user_dir(), "outgoing.bin", NULL);
        PurpleConnection *gc = purple_account_get_connection(account);
        if (!g_file_set_contents(path, (char *)bytes, length, NULL)) abort();
        if (gc) serv_send_file(gc, buddy_name, path);
        puts("FILE-OFFERED"); g_free(path); g_free(bytes);
    }
    else if (g_str_has_prefix(line, "file-generate ")) {
        unsigned size = (unsigned)strtoul(line+14, NULL, 10), i;
        char *path = g_build_filename(purple_user_dir(), "outgoing.bin", NULL);
        PurpleConnection *gc = purple_account_get_connection(account);
        FILE *file;
        guchar chunk[4096];
        if (size > 32*1024*1024 || !(file = fopen(path, "wb"))) abort();
        for (i = 0; i < sizeof(chunk); ++i) chunk[i] = (guchar)(i*17+3);
        while (size) {
            unsigned count = MIN(size, (unsigned)sizeof(chunk));
            if (fwrite(chunk, 1, count, file) != count) abort();
            size -= count;
        }
        if (fclose(file)) abort();
        if (gc) serv_send_file(gc, buddy_name, path);
        puts("FILE-OFFERED"); g_free(path);
    }
    else if (!strcmp(line, "file-accept\n")) {
        if (action_accept) {
            PurpleRequestActionCb callback = action_accept;
            gpointer argument = action_argument;
            action_accept = NULL;
            purple_request_close(PURPLE_REQUEST_ACTION, &action_request_handle);
            callback(argument, 0);
        }
        if (file_accept) {
            PurpleRequestFileCb callback = (PurpleRequestFileCb)file_accept;
            gpointer argument = file_argument;
            char *path = g_build_filename(purple_user_dir(), "received.bin", NULL);
            file_accept = NULL;
            purple_request_close(PURPLE_REQUEST_FILE, &file_request_handle);
            callback(argument, path); g_free(path);
        }
        puts("FILE-ACCEPTED");
    }
    else if (!strcmp(line, "file-reject\n")) {
        if (action_cancel) {
            PurpleRequestActionCb callback = action_cancel;
            gpointer argument = action_argument;
            action_cancel = NULL;
            purple_request_close(PURPLE_REQUEST_ACTION, &action_request_handle);
            callback(argument, 1);
        } else if (file_cancel) {
            PurpleRequestFileCb callback = (PurpleRequestFileCb)file_cancel;
            gpointer argument = file_argument;
            file_cancel = NULL;
            purple_request_close(PURPLE_REQUEST_FILE, &file_request_handle);
            callback(argument, NULL);
        }
        puts("FILE-REJECTED");
    }
    else if (!strcmp(line, "file-cancel\n")) {
        if (last_file && !purple_xfer_is_canceled(last_file) && !purple_xfer_is_completed(last_file)) purple_xfer_cancel_local(last_file);
        puts("FILE-CANCELED");
    }
    else if (!strcmp(line, "file-state\n")) {
        printf("FILE-STATE %d %zu\n", last_file ? (int)purple_xfer_get_status(last_file) : -1,
            last_file ? purple_xfer_get_bytes_sent(last_file) : 0);
    }
    else if (!strcmp(line, "file-data\n")) {
        char *path = g_build_filename(purple_user_dir(), "received.bin", NULL), *bytes = NULL;
        gsize length = 0;
        if (g_file_get_contents(path, &bytes, &length, NULL)) {
            char *encoded = g_base64_encode((guchar *)bytes, length); printf("FILE-DATA %s\n", encoded); g_free(encoded);
        } else puts("FILE-DATA -");
        g_free(path); g_free(bytes);
    }
    else if (g_str_has_prefix(line, "send ")) {
        char *message = decode(line+5);
        PurpleConnection *gc = purple_account_get_connection(account);
        int result = message && gc && buddy ? serv_send_im(gc, purple_buddy_get_name(buddy), message, PURPLE_MESSAGE_SEND) : -1;
        g_free(message); printf("SENT %d\n", result);
    }
    else if (g_str_has_prefix(line, "conv-send ")) {
        char *message = decode(line+10);
        PurpleConversation *conversation = buddy ? purple_conversation_new(PURPLE_CONV_TYPE_IM,
            account, purple_buddy_get_name(buddy)) : NULL;
        if (message && conversation) purple_conv_im_send_with_flags(PURPLE_CONV_IM(conversation), message, PURPLE_MESSAGE_SEND);
        g_free(message); puts("CONVERSATION-SENT");
    }
    else if (g_str_has_prefix(line, "status ")) {
        char *id = line+7, *encoded = strchr(id, ' '), *message;
        if (!encoded) return TRUE;
        *encoded++ = 0; message = decode(encoded);
        if (message) { purple_account_set_status(account, id, TRUE, "message", message, NULL); g_free(message); }
        puts("STATUS-SET");
    }
    else if (!strcmp(line, "buddy-status\n")) {
        PurpleStatus *status = purple_presence_get_active_status(purple_buddy_get_presence(buddy));
        const char *message = purple_status_get_attr_string(status, "message");
        char *encoded = g_base64_encode((const guchar *)(message ? message : ""), message ? strlen(message) : 0);
        printf("STATUS %s %s\n", purple_status_get_id(status), encoded); g_free(encoded);
    }
    else if (!strcmp(line, "fail-input\n")) { fail_input = TRUE; puts("ARMED"); }
    else if (!strcmp(line, "fail-remove\n")) { fail_remove = TRUE; puts("ARMED"); }
    else if (!strcmp(line, "can-unload\n")) printf("UNLOAD %d\n", plugin->info->unload(plugin));
    else if (!strcmp(line, "state\n"))
        printf("STATE %d %u\n", buddy && purple_presence_is_online(purple_buddy_get_presence(buddy)), api ? api->connections() : 0);
    return TRUE;
}

int main(int argc, char **argv)
{
    PurpleEventLoopUiOps events = {
        .timeout_add = timeout_add, .timeout_remove = timeout_remove,
        .input_add = input_add, .input_remove = g_source_remove,
        .timeout_add_seconds = timeout_seconds
    };
    PurpleConnectionUiOps connections = {.report_disconnect_reason = report_disconnect};
    PurpleConversationUiOps conversations = {.write_conv = conversation_written};
    PurpleDebugUiOps debug = {.print = debug_print, .is_enabled = debug_enabled};
    PurpleNotifyUiOps notify = {.notify_userinfo = show_info, .close_notify = close_info};
    PurpleXferUiOps transfers = {.new_xfer = new_file, .add_xfer = file_added, .update_progress = file_progress};
    PurpleRequestUiOps requests = {.request_file = choose_file, .request_action = request_file_action, .close_request = close_file_request};
    GModule *reference;
    gpointer symbol;
    const BarevProtocolTestAPI *(*get_api)(void);
    guint stdin_source;
    int signal_handle;
    gboolean production;
    void *mapped;

    if (argc != 5 && argc != 7) return 2;
    production = !strcmp(argv[4], "production");
    channel_io = !strcmp(argv[4], "gio");
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stdin, NULL, _IONBF, 0);
    purple_util_set_user_dir(argv[2]);
    purple_debug_set_ui_ops(&debug);
    purple_eventloop_set_ui_ops(&events);
    if (!purple_core_init(g_getenv("BAREV_TEST_PIDGIN_UI") ? "gtk-gaim" : "voc-barev-test")) return 3;
    purple_notify_set_ui_ops(&notify);
    purple_xfers_set_ui_ops(&transfers); purple_request_set_ui_ops(&requests);
    purple_connections_set_ui_ops(&connections);
    purple_conversations_set_ui_ops(&conversations);
    purple_set_blist(purple_blist_new());
    purple_blist_load();
    /* Core startup may discover a system-installed copy with the same ID.
     * Keep this isolated host bound to the library supplied by the test. */
    plugin = purple_plugins_find_with_id("prpl-voc-barev");
    if (plugin) purple_plugin_destroy(plugin);
    plugin = purple_plugin_probe(argv[1]);
    if (!plugin || plugin->unloadable || !purple_plugin_load(plugin)) return 4;
    purple_plugins_probe("barev-test-no-scan");
    reference = g_module_open(argv[1], G_MODULE_BIND_LOCAL);
    if (!reference) return 5;
    if (!production) {
        int32_t count;
        if (!g_module_symbol(reference, "barev_protocol_test_api", &symbol)) return 6;
        memcpy(&get_api, &symbol, sizeof(get_api));
        api = get_api();
        count = api->unit();
        printf("UNITS %d\n", count);
        if (count <= 0 || !api->fixture("200::1", "200::2")) return 7;
    } else if (g_module_symbol(reference, "barev_protocol_test_api", &symbol)) return 8;
    purple_signal_connect(purple_blist_get_handle(), "buddy-signed-on", &signal_handle, PURPLE_CALLBACK(signed_on), NULL);
    purple_signal_connect(purple_blist_get_handle(), "buddy-signed-off", &signal_handle, PURPLE_CALLBACK(signed_off), NULL);
    purple_signal_connect(purple_connections_get_handle(), "signed-on", &signal_handle, PURPLE_CALLBACK(account_ready), NULL);
    purple_signal_connect(purple_conversations_get_handle(), "received-im-msg", &signal_handle, PURPLE_CALLBACK(message_received), NULL);
    purple_signal_connect(purple_conversations_get_handle(), "buddy-typing", &signal_handle, PURPLE_CALLBACK(typing_received), GINT_TO_POINTER(1));
    purple_signal_connect(purple_conversations_get_handle(), "buddy-typed", &signal_handle, PURPLE_CALLBACK(typing_received), GINT_TO_POINTER(2));
    purple_signal_connect(purple_conversations_get_handle(), "buddy-typing-stopped", &signal_handle, PURPLE_CALLBACK(typing_received), GINT_TO_POINTER(0));
    purple_signal_connect(purple_blist_get_handle(), "buddy-icon-changed", &signal_handle, PURPLE_CALLBACK(avatar_received), NULL);
    account = purple_account_new(argc == 7 ? argv[5] : "alice", "prpl-voc-barev");
    purple_accounts_add(account);
    purple_account_set_string(account, "local_ipv6", "::1");
    purple_account_set_int(account, "port", production ? 1337 : 0);
    purple_account_set_int(account, "peer_port", atoi(argv[3]));
    {
        const char *path = g_getenv("BAREV_TEST_ICON_FILE");
        const char *mode = g_getenv("BAREV_TEST_ICON_MODE");
        if (path) {
            gchar *bytes;
            gsize length;
            if (!g_file_get_contents(path, &bytes, &length, NULL)) return 12;
            if (mode && !strcmp(mode, "disk")) {
                const char *directory = purple_buddy_icons_get_cache_dir();
                char *cache = g_build_filename(directory, "fixture-icon.png", NULL);
                g_mkdir_with_parents(directory, 0700);
                if (!g_file_set_contents(cache, bytes, length, NULL)) return 13;
                purple_account_set_string(account, "buddy_icon", "fixture-icon.png");
                g_free(cache); g_free(bytes);
            } else if (mode && !strcmp(mode, "path")) {
                purple_account_set_bool(account, "use-global-buddyicon", FALSE);
                purple_account_set_buddy_icon_path(account, path); g_free(bytes);
            } else if (mode && !strcmp(mode, "global")) {
                purple_prefs_add_none("/pidgin"); purple_prefs_add_none("/pidgin/accounts");
                purple_prefs_add_path("/pidgin/accounts/buddyicon", path); g_free(bytes);
            } else purple_buddy_icons_set_account_icon(account, (guchar *)bytes, length);
        }
    }
    buddy = purple_buddy_new(account, argc == 7 ? argv[6] : "bob@200::2", NULL);
    buddy_name = g_strdup(purple_buddy_get_name(buddy));
    purple_blist_add_buddy(buddy, NULL, NULL, NULL);
    {
        const char *path = g_getenv("BAREV_TEST_PEER_ICON_FILE");
        if (path) {
            gchar *bytes, *hash, *cache;
            gsize length;
            if (!g_file_get_contents(path, &bytes, &length, NULL)) return 14;
            hash = g_compute_checksum_for_data(G_CHECKSUM_SHA1, (guchar *)bytes, length);
            cache = g_build_filename(purple_buddy_icons_get_cache_dir(), "fixture-peer.png", NULL);
            g_mkdir_with_parents(purple_buddy_icons_get_cache_dir(), 0700);
            if (!g_file_set_contents(cache, bytes, length, NULL)) return 15;
            purple_blist_node_set_string(PURPLE_BLIST_NODE(buddy), "buddy_icon", "fixture-peer.png");
            purple_blist_node_set_string(PURPLE_BLIST_NODE(buddy), "icon_checksum",
                g_getenv("BAREV_TEST_PEER_ICON_HASH") ? g_getenv("BAREV_TEST_PEER_ICON_HASH") : hash);
            g_free(bytes); g_free(hash); g_free(cache);
        }
    }
    loop = g_main_loop_new(NULL, FALSE);
    stdin_source = g_unix_fd_add(STDIN_FILENO, G_IO_IN | G_IO_HUP, command, NULL);
    fail_timer = !strcmp(argv[4], "fail-timer");
    fail_input = !strcmp(argv[4], "fail-input");
    purple_account_set_enabled(account, purple_core_get_ui(), TRUE);
    purple_account_set_status(account, "available", TRUE, NULL);
    if (!purple_account_get_connection(account)) purple_account_connect(account);
    g_main_loop_run(loop);
    if (g_main_context_find_source_by_id(NULL, stdin_source)) g_source_remove(stdin_source);
    purple_signals_disconnect_by_handle(&signal_handle);
    if (last_file) { purple_xfer_unref(last_file); last_file = NULL; }
    purple_core_quit();
    g_free(buddy_name);
    account = NULL; buddy = NULL; api = NULL;
    g_main_loop_unref(loop);
    if (!g_module_close(reference)) return 9;
    mapped = dlopen(argv[1], RTLD_NOW | RTLD_NOLOAD);
    if (mapped) return 10;
    if (live_inputs || live_timers) {
        fprintf(stderr, "Unreleased sources: %u inputs, %u timers\n", live_inputs, live_timers);
        return 11;
    }
    puts("CLEAN");
    puts("CLOSED");
    return 0;
}
