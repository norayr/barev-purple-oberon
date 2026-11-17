/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "pin-ui.h"
#include <libpurple/request.h>
#include <libpurple/core.h>
#include <libpurple/eventloop.h>
#include <libpurple/util.h>
#include <string.h>

static unsigned checks, saves, inputs, actions, errors, closed;
static BarevPinUI *ui;
static char current[65], *description;
static int load_error, save_error;
static gboolean close_input, close_action, sync_input, sync_action;
static PurpleRequestInputCb input_ok, input_cancel;
static PurpleRequestActionCb choices[2];
static gpointer input_data, action_data;
static int input_handle, action_handle;
static const char *first = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c";
static const char *second = "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025";
#define CHECK(x) do { ++checks; if (!(x)) g_error("pin UI check %u failed", checks); } while (0)

static int load(gpointer owner, const char *who, char key[65], char fp[72])
{
    (void)owner; CHECK(!strcmp(who, "Bob@200::1"));
    strcpy(key, current); g_snprintf(fp, 72, "SHA256:%s", current);
    return load_error ? load_error : *current ? 0 : 1;
}
static gboolean describe(gpointer owner, const char *text, char key[65], char fp[72])
{
    unsigned i;
    (void)owner;
    if (strlen(text) != 64) return FALSE;
    for (i = 0; i < 64; ++i) if (!g_ascii_isxdigit(text[i])) return FALSE;
    strcpy(key, text); g_snprintf(fp, 72, "SHA256:%s", text); return TRUE;
}
static int save(gpointer owner, const char *who, const char *expected, const char *key)
{
    (void)owner; CHECK(!strcmp(who, "Bob@200::1"));
    if (save_error) return save_error;
    if (strcmp(current, expected)) return 4;
    strcpy(current, key); ++saves; return 0;
}
static void shutdown_ui(void) { BarevPinUI *old = ui; ui = NULL; BarevPinUI_Close(old); }
static void *request_input(const char *title, const char *primary, const char *secondary,
    const char *value, gboolean multiline, gboolean masked, gchar *hint, const char *ok, GCallback yes,
    const char *cancel, GCallback no, PurpleAccount *account, const char *who,
    PurpleConversation *conversation, void *data)
{
    (void)title; (void)primary; (void)value; (void)multiline; (void)masked; (void)hint;
    (void)ok; (void)cancel; (void)account; (void)who; (void)conversation;
    ++inputs; input_ok = (PurpleRequestInputCb)yes; input_cancel = (PurpleRequestInputCb)no; input_data = data;
    g_free(description); description = g_strdup(secondary);
    if (close_input) shutdown_ui();
    else if (sync_input) input_ok(data, first);
    return &input_handle;
}
static void *request_action(const char *title, const char *primary, const char *secondary,
    int selected, PurpleAccount *account, const char *who, PurpleConversation *conversation,
    void *data, size_t count, va_list list)
{
    unsigned i;
    (void)title; (void)primary; (void)account; (void)who; (void)conversation;
    CHECK(count == 2 && selected == 0); ++actions; action_data = data;
    for (i = 0; i < 2; ++i) { (void)va_arg(list, const char *); choices[i] = va_arg(list, PurpleRequestActionCb); }
    g_free(description); description = g_strdup(secondary);
    if (close_action) shutdown_ui();
    else if (sync_action) choices[1](data, 0);
    return &action_handle;
}
static void request_close(PurpleRequestType type, void *handle)
{
    (void)handle; ++closed;
    if (type == PURPLE_REQUEST_INPUT) input_data = NULL;
    if (type == PURPLE_REQUEST_ACTION) action_data = NULL;
}
static void *notice(PurpleNotifyMsgType type, const char *title, const char *primary, const char *secondary)
{ (void)title; (void)primary; (void)secondary; if (type == PURPLE_NOTIFY_MSG_ERROR) ++errors; return NULL; }
static void enter_key(const char *text)
{
    PurpleRequestInputCb cb = input_ok; gpointer data = input_data;
    CHECK(data != NULL); purple_request_close(PURPLE_REQUEST_INPUT, &input_handle); cb(data, text);
}
static void choose(unsigned choice)
{
    PurpleRequestActionCb cb = choices[choice]; gpointer data = action_data;
    CHECK(data != NULL); purple_request_close(PURPLE_REQUEST_ACTION, &action_handle); cb(data, 1-(int)choice);
}
static void open(void) { BarevPinUI_Open(ui, "Bob@200::1"); }

int main(int argc, char **argv)
{
    PurpleEventLoopUiOps events = {.timeout_add = g_timeout_add, .timeout_remove = g_source_remove,
                                   .timeout_add_seconds = g_timeout_add_seconds};
    PurpleRequestUiOps requests = {.request_input = request_input, .request_action = request_action, .close_request = request_close};
    PurpleNotifyUiOps notify = {.notify_message = notice};
    BarevPinBackend backend = {NULL, load, describe, save};
    unsigned before;
    PurpleNotifyUserInfo *info;
    if (argc != 2) return 2;
    purple_util_set_user_dir(argv[1]); purple_eventloop_set_ui_ops(&events);
    CHECK(purple_core_init("barev-pin-ui-test"));
    purple_request_set_ui_ops(&requests); purple_notify_set_ui_ops(&notify);
    ui = BarevPinUI_New(NULL, &backend);
    open(); CHECK(inputs == 1 && saves == 0); open(); CHECK(inputs == 1);
    { PurpleRequestInputCb cb = input_cancel; gpointer data = input_data;
      purple_request_close(PURPLE_REQUEST_INPUT, &input_handle); cb(data, NULL); }
    open(); enter_key("invalid"); CHECK(errors == 1 && actions == 0 && saves == 0);
    open(); enter_key(first); CHECK(actions == 1 && strstr(description, first)); choose(0); CHECK(saves == 0);
    open(); enter_key(first); choose(1); CHECK(saves == 1 && !strcmp(current, first));
    info = purple_notify_user_info_new(); BarevPinUI_Info(ui, "Bob@200::1", info);
    CHECK(g_list_length(purple_notify_user_info_get_entries(info)) == 4); purple_notify_user_info_destroy(info);
    before = actions; open(); enter_key(first); CHECK(actions == before && saves == 1);
    open(); enter_key(second); CHECK(strstr(description, first) && strstr(description, second));
    choose(0); CHECK(!strcmp(current, first) && saves == 1);
    open(); enter_key(second); current[0] = '0'; choose(1); CHECK(errors == 2 && saves == 1 && current[0] == '0');
    strcpy(current, first); open(); enter_key(second); choose(1); CHECK(saves == 2 && !strcmp(current, second));
    save_error = 3; open(); enter_key(first); choose(1); CHECK(errors == 3 && saves == 2); save_error = 0;
    before = inputs; load_error = 2; open(); CHECK(inputs == before && errors == 4); load_error = 0;
    requests.request_input = NULL; open(); requests.request_input = request_input;
    open(); CHECK(input_data != NULL); enter_key(second);
    requests.request_action = NULL; open(); enter_key(first); requests.request_action = request_action;
    open(); CHECK(input_data != NULL); enter_key(second);
    open(); shutdown_ui(); CHECK(ui == NULL && input_data == NULL);
    ui = BarevPinUI_New(NULL, &backend); open(); enter_key(first); shutdown_ui(); CHECK(action_data == NULL);
    ui = BarevPinUI_New(NULL, &backend); close_input = TRUE; before = closed; open(); close_input = FALSE;
    CHECK(ui == NULL && closed > before);
    ui = BarevPinUI_New(NULL, &backend); open(); close_action = TRUE; enter_key(first); close_action = FALSE; CHECK(ui == NULL);
    current[0] = 0; ui = BarevPinUI_New(NULL, &backend); sync_action = TRUE;
    open(); enter_key(first); CHECK(saves == 3 && !strcmp(current, first)); shutdown_ui();
    current[0] = 0; ui = BarevPinUI_New(NULL, &backend); sync_input = TRUE;
    open(); CHECK(saves == 4 && !strcmp(current, first)); shutdown_ui();
    g_free(description);
    purple_core_quit();
    g_print("Peer pin UI: %u checks passed\n", checks); return 0;
}
