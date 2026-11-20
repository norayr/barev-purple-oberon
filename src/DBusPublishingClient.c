/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <gio/gio.h>
#include <stdio.h>
#include <string.h>
#include "dbus-api.h"

static GMainLoop *loop;
static GDBusConnection *connection;
static GVariant *reply;
static GError *error;
static unsigned checks, signals;
static const char *account;
static const char *tokens[] = {"00000000000040008000000000000001", "00000000000040008000000000000002",
    "00000000000040008000000000000003", "00000000000040008000000000000004", "00000000000040008000000000000005"};
static const char *ids[] = {"urn:uuid:00000000-0000-4000-8000-000000000001", "urn:uuid:00000000-0000-4000-8000-000000000002",
    "urn:uuid:00000000-0000-4000-8000-000000000003", "urn:uuid:00000000-0000-4000-8000-000000000004", "urn:uuid:00000000-0000-4000-8000-000000000005"};
#define CHECK(value) do { ++checks; if (!(value)) g_error("Client check %u failed: %s%s%s", checks, #value, error ? ": " : "", error ? error->message : ""); } while (0)

static void completed(GObject *object, GAsyncResult *result, gpointer data)
{
    (void)data;
    reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), result, &error); g_main_loop_quit(loop);
}

static GVariant *call(const char *method, GVariant *parameters)
{
    reply = NULL; g_clear_error(&error);
    g_dbus_connection_call(connection, "org.barev.Native", BAREV_DBUS_NATIVE_PATH, BAREV_DBUS_INTERFACE,
        method, parameters, NULL, G_DBUS_CALL_FLAGS_NO_AUTO_START, 10000, NULL, completed, NULL);
    g_main_loop_run(loop); return reply;
}

static void changed(GDBusConnection *bus, const char *sender, const char *path, const char *interface,
                    const char *signal, GVariant *parameters, gpointer data)
{
    const char *identity;
    (void)bus; (void)sender; (void)path; (void)interface; (void)signal; (void)data;
    g_variant_get(parameters, "(&s)", &identity); CHECK(!strcmp(identity, account)); ++signals;
}

static void expected_error(const char *name)
{
    char *remote = error ? g_dbus_error_get_remote_error(error) : NULL;
    char *wanted = g_strconcat(BAREV_DBUS_INTERFACE ".", name, NULL);
    CHECK(!reply && remote && !strcmp(remote, wanted)); g_free(remote); g_free(wanted);
}

static char *state(void)
{
    GVariant *result = call("GetPublishingState", g_variant_new("(s)", account));
    char *text;
    CHECK(result && !error); g_variant_get(result, "(s)", &text); g_variant_unref(result); return text;
}

static void wait_state(const char *expected)
{
    gint64 deadline = g_get_monotonic_time()+10000000;
    char *value = state();
    while (!strcmp(value, "loading") && g_get_monotonic_time() < deadline) { g_free(value); g_usleep(5000); value = state(); }
    CHECK(!strcmp(value, expected)); g_free(value);
}

static GVariant *publish(unsigned token, const char *node, const char *body, const char *parent)
{ return call("Publish", g_variant_new("(ssssss)", account, node, tokens[token], "Բարեւ 😀", body, parent)); }

static void published(unsigned token, GVariant *result)
{
    const char *item, *id;
    CHECK(result && !error); g_variant_get(result, "(&s&s)", &item, &id);
    CHECK(!strcmp(item, tokens[token]) && !strcmp(id, ids[token])); g_variant_unref(result);
}

static void verify(void)
{
    GVariant *result, *row;
    const char *author, *body;
    wait_state("ready");
    result = call("GetPost", g_variant_new("(sss)", account, "public", tokens[0])); CHECK(result && !error);
    row = g_variant_get_child_value(result, 0);
    g_variant_get_child(row, 2, "&s", &author); g_variant_get_child(row, 4, "&s", &body);
    CHECK(!strcmp(author, "Անի@200::1") && !strcmp(body, "First <body> & text"));
    g_variant_unref(row); g_variant_unref(result);
}

static void initial(void)
{
    GVariant *result, *rows;
    const char *names[] = {"bob@200::2", NULL}, *empty[] = {NULL};
    char *cursor, *next, *old;
    const char *item;
    wait_state("uninitialized");
    result = call("InitializePublishing", g_variant_new("(s)", account)); CHECK(result && !error); g_variant_unref(result);
    result = call("CreateDestination", g_variant_new("(sssu^as)", account, "public", "Public", 1u, empty)); CHECK(result && !error); g_variant_unref(result);
    result = call("CreateDestination", g_variant_new("(sssu^as)", account, "selected", "Selected", 3u, names)); CHECK(result && !error); g_variant_unref(result);
    published(0, publish(0, "public", "First <body> & text", ""));
    published(0, publish(0, "public", "First <body> & text", ""));
    publish(0, "public", "Changed", ""); expected_error("Conflict");
    published(1, publish(1, "public", "Independent reply", ids[0]));
    published(2, publish(2, "selected", "Private response", ids[0]));
    publish(3, "public", "Widened reply", ids[2]); expected_error("Denied");
    result = call("ListDestinations", g_variant_new("(s)", account)); CHECK(result && !error);
    rows = g_variant_get_child_value(result, 0); CHECK(g_variant_n_children(rows) == 2); g_variant_unref(rows); g_variant_unref(result);
    result = call("ListPosts", g_variant_new("(sssu)", account, "public", "", 1u)); CHECK(result && !error);
    g_variant_get(result, "(@a(ssssssss)s)", &rows, &cursor); CHECK(g_variant_n_children(rows) == 1 && *cursor);
    { GVariant *row = g_variant_get_child_value(rows, 0); g_variant_get_child(row, 0, "&s", &item); CHECK(!strcmp(item, tokens[1])); g_variant_unref(row); }
    g_variant_unref(rows); g_variant_unref(result); old = g_strdup(cursor);
    call("ListPosts", g_variant_new("(sssu)", account, "selected", cursor, 1u)); expected_error("Stale");
    result = call("ListPosts", g_variant_new("(sssu)", account, "public", cursor, 1u)); CHECK(result && !error);
    g_variant_get(result, "(@a(ssssssss)s)", &rows, &next); CHECK(g_variant_n_children(rows) == 1 && *next);
    { GVariant *row = g_variant_get_child_value(rows, 0); g_variant_get_child(row, 0, "&s", &item); CHECK(!strcmp(item, tokens[0])); g_variant_unref(row); }
    g_variant_unref(rows); g_variant_unref(result); g_free(cursor);
    call("ListPosts", g_variant_new("(sssu)", account, "public", old, 1u)); expected_error("Stale"); g_free(old);
    result = call("ListPosts", g_variant_new("(sssu)", account, "public", next, 1u)); CHECK(result && !error);
    g_variant_get(result, "(@a(ssssssss)s)", &rows, &cursor); CHECK(g_variant_n_children(rows) == 0 && !*cursor);
    g_variant_unref(rows); g_variant_unref(result); g_free(cursor); g_free(next);
    result = call("ListPosts", g_variant_new("(sssu)", account, "selected", "", 32u)); CHECK(result && !error);
    rows = g_variant_get_child_value(result, 0); CHECK(g_variant_n_children(rows) == 1); g_variant_unref(rows); g_variant_unref(result);
    verify();
    CHECK(signals == 6);
}

static void deferred_done(GObject *object, GAsyncResult *result, gpointer data)
{
    GError *failure = NULL;
    GVariant *value;
    char *remote;
    (void)data;
    value = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), result, &failure);
    remote = failure ? g_dbus_error_get_remote_error(failure) : NULL;
    CHECK(!value && remote && !strcmp(remote, BAREV_DBUS_INTERFACE ".Unavailable"));
    g_clear_error(&failure); g_free(remote); g_main_loop_quit(loop);
}

int main(int argc, char **argv)
{
    GVariant *result;
    CHECK(argc == 3); account = argv[1];
    connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error); CHECK(connection && !error);
    loop = g_main_loop_new(NULL, FALSE);
    g_dbus_connection_signal_subscribe(connection, "org.barev.Native", BAREV_DBUS_INTERFACE,
        "PublishingChanged", BAREV_DBUS_NATIVE_PATH, NULL, G_DBUS_SIGNAL_FLAGS_NONE, changed, NULL, NULL);
    if (!strcmp(argv[2], "new")) initial();
    else if (!strcmp(argv[2], "verify")) { verify(); CHECK(signals == 0); }
    else if (!strcmp(argv[2], "fail-write")) {
        wait_state("ready"); publish(3, "public", "Retry after failure", ""); expected_error("StorageError");
        wait_state("unavailable"); CHECK(signals == 0);
    } else if (!strcmp(argv[2], "recover")) {
        result = call("ReloadPublishing", g_variant_new("(s)", account)); CHECK(result && !error); g_variant_unref(result);
        call("GetPost", g_variant_new("(sss)", account, "public", tokens[3])); expected_error("NotFound");
        CHECK(signals == 0);
        published(3, publish(3, "public", "Retry after failure", "")); verify();
        CHECK(signals == 1);
    } else if (!strcmp(argv[2], "missing")) {
        wait_state("unavailable"); call("InitializePublishing", g_variant_new("(s)", account)); expected_error("Conflict");
    } else if (!strcmp(argv[2], "deferred")) {
        wait_state("ready");
        g_dbus_connection_call(connection, "org.barev.Native", BAREV_DBUS_NATIVE_PATH, BAREV_DBUS_INTERFACE,
            "Publish", g_variant_new("(ssssss)", account, "public", tokens[4], "Title", "Accepted before disconnect", ""),
            NULL, G_DBUS_CALL_FLAGS_NO_AUTO_START, 10000, NULL, deferred_done, NULL);
        {
            char *value = state(); CHECK(!strcmp(value, "saving")); g_free(value);
        }
        puts("PENDING"); fflush(stdout); g_main_loop_run(loop);
    } else if (!strcmp(argv[2], "accepted")) {
        verify(); result = call("GetPost", g_variant_new("(sss)", account, "public", tokens[4]));
        CHECK(result && !error); g_variant_unref(result);
        CHECK(signals == 0);
    } else return 2;
    printf("Native D-Bus publishing client: %u checks passed\n", checks);
    g_clear_error(&error); g_main_loop_unref(loop); g_object_unref(connection); return 0;
}
