/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <glib.h>
#include <gmodule.h>
#include <libpurple/account.h>
#include <libpurple/accountopt.h>
#include <libpurple/blist.h>
#include <libpurple/buddyicon.h>
#include <libpurple/imgstore.h>
#include <libpurple/connection.h>
#include <libpurple/core.h>
#include <libpurple/debug.h>
#include <libpurple/eventloop.h>
#include <libpurple/notify.h>
#include <libpurple/plugin.h>
#include <libpurple/prefs.h>
#include <libpurple/prpl.h>
#include <libpurple/status.h>
#include <libpurple/server.h>
#include <libpurple/util.h>
#include <libpurple/value.h>
#include <libpurple/version.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>

#include "runtime.h"
#include "transfers.h"
#include "Heap.h"
#include "BarevAddress.h"
#include "BarevStream.h"
#include "BarevStanzas.h"
#include "BarevAvatar.h"
#include "protocol-constants.h"
#ifdef BAREV_PROTOCOL_TEST
#include "protocol-test.h"
#include "TestBarev.h"
#endif

_Static_assert(sizeof(INT32) == 4 && sizeof(BOOLEAN) == 1, "VOC scalar ABI mismatch");

#define CONTACTS 128
#define CONNECTIONS 64
#define DEFAULT_PORT 1337
#define BAREV_VERSION "0.5.3"

typedef struct Account Account;
typedef struct Pipe Pipe;
typedef struct {
    char *jid;
    int32_t index;
    int port;
    int32_t status, typing;
    char *message;
    gint64 retry;
    unsigned backoff;
} Contact;
struct Account {
    PurpleAccount *purple;
    int32_t handle;
    int listener, port;
    guint listener_watch, timer;
    char address[INET6_ADDRSTRLEN];
    struct in6_addr native;
    Contact contacts[CONTACTS];
    GList *pipes;
    unsigned refs;
    gboolean closing;
    gint64 last_tick;
    BarevTransfers *transfers;
};
struct Pipe {
    Account *account;
    Contact *expected;
    int fd;
    int32_t handle;
    guint read_watch, write_watch;
    gboolean connecting, incoming;
    gint64 deadline;
    gint64 rate_second;
    unsigned received;
};

static GList *accounts;
static unsigned pipe_count;
#ifdef BAREV_PROTOCOL_TEST
static char fixture_local[40], fixture_peer[40];
#endif

static gboolean enter(HostFrame *frame) { return BarevRuntime_Enter(frame); }
static void leave(HostFrame *frame) { BarevRuntime_Leave(frame); }
void BarevPlugin_Initialize(void) { BarevStream__init(); }
gboolean BarevPlugin_Idle(void) { return accounts == NULL && pipe_count == 0 && BarevTransfers_Idle(); }
void BarevPlugin_Shutdown(void)
{
    HostFrame frame;
    if (!initialized || closed) return;
    if (!BarevPlugin_Idle() || depth || !enter(&frame)) g_error("Cannot destroy an active Barev runtime");
    Heap_FINALL();
    leave(&frame);
    BarevRuntime_Release();
}

static void account_ref(Account *account) { ++account->refs; }
static void account_unref(Account *account)
{
    unsigned index;
    if (--account->refs) return;
    for (index = 0; index < CONTACTS; ++index) {
        g_free(account->contacts[index].jid);
        g_free(account->contacts[index].message);
    }
    g_free(account);
}

static void remove_input(guint *source)
{
    guint id = *source;
    *source = 0;
    if (!id) return;
    purple_debug_misc("voc-barev", "Removing input source %u\n", id);
    purple_input_remove(id);
}

/* Keep the account rooted if the host cannot confirm timer removal. The
 * timer's next invocation retires it without entering protocol state. */
static void retire_account(Account *account)
{
    account->closing = TRUE;
    if (account->timer) purple_debug_misc("voc-barev", "Removing timer source %u\n", account->timer);
    if (account->timer && !purple_timeout_remove(account->timer)) {
        if (!g_list_find(accounts, account)) accounts = g_list_prepend(accounts, account);
        return;
    }
    account->timer = 0;
    accounts = g_list_remove(accounts, account);
    account_unref(account);
}

static gboolean ygg(const struct in6_addr *ip)
{ return ip->s6_addr[0] == 2 || ip->s6_addr[0] == 3; }

static gboolean local_address(PurpleAccount *purple, char *text, struct in6_addr *native)
{
    const char *configured = purple_account_get_string(purple, "local_ipv6", "");
    struct ifaddrs *list, *item;
    struct in6_addr chosen;
    gboolean found = FALSE, ambiguous = FALSE;
#ifdef BAREV_PROTOCOL_TEST
    if (*fixture_local) {
        g_strlcpy(text, fixture_local, INET6_ADDRSTRLEN);
        return inet_pton(AF_INET6, "::1", native) == 1;
    }
#endif
    if (*configured) {
        if (inet_pton(AF_INET6, configured, native) != 1 || !ygg(native)) return FALSE;
        return inet_ntop(AF_INET6, native, text, INET6_ADDRSTRLEN) != NULL;
    }
    if (getifaddrs(&list) != 0) return FALSE;
    for (item = list; item; item = item->ifa_next) {
        const struct sockaddr_in6 *address;
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET6) continue;
        address = (const struct sockaddr_in6 *)item->ifa_addr;
        if (!ygg(&address->sin6_addr)) continue;
        if (found && memcmp(&chosen, &address->sin6_addr, sizeof(chosen))) ambiguous = TRUE;
        chosen = address->sin6_addr;
        found = TRUE;
    }
    freeifaddrs(list);
    if (!found || ambiguous) return FALSE;
    *native = chosen;
    return inet_ntop(AF_INET6, native, text, INET6_ADDRSTRLEN) != NULL;
}

/* Return binary-validated socket endpoints; production has no address override. */
static gboolean endpoints(Pipe *pipe, char *peer, char *local)
{
    struct sockaddr_in6 remote = {0}, own = {0};
    socklen_t length = sizeof(remote);
    if (getpeername(pipe->fd, (struct sockaddr *)&remote, &length) || length != sizeof(remote) ||
        remote.sin6_family != AF_INET6 || remote.sin6_scope_id) return FALSE;
    length = sizeof(own);
    if (getsockname(pipe->fd, (struct sockaddr *)&own, &length) || length != sizeof(own) ||
        own.sin6_family != AF_INET6 || own.sin6_scope_id) return FALSE;
#ifdef BAREV_PROTOCOL_TEST
    if (*fixture_local && IN6_IS_ADDR_LOOPBACK(&remote.sin6_addr) && IN6_IS_ADDR_LOOPBACK(&own.sin6_addr)) {
        g_strlcpy(peer, fixture_peer, INET6_ADDRSTRLEN);
        g_strlcpy(local, fixture_local, INET6_ADDRSTRLEN);
        return TRUE;
    }
#endif
    if (!ygg(&remote.sin6_addr) || !ygg(&own.sin6_addr)) return FALSE;
    return inet_ntop(AF_INET6, &remote.sin6_addr, peer, INET6_ADDRSTRLEN) &&
        inet_ntop(AF_INET6, &own.sin6_addr, local, INET6_ADDRSTRLEN);
}

static gboolean canonical(const char *input, char *output)
{
    CHAR ip[16];
    if (!input || strlen(input) >= 384 || !g_utf8_validate(input, -1, NULL)) return FALSE;
    return BarevAddress_Identity((CHAR *)input, strlen(input)+1, (CHAR *)output, 384, ip) != 0;
}

static const char *status_id(int32_t status)
{
    switch (status) {
    case BarevStanzas_available: return "available";
    case BarevStanzas_away: return "away";
    case BarevStanzas_dnd: return "dnd";
    case BarevStanzas_extendedAway: return "xa";
    case BarevStanzas_chat: return "available";
    default: return "offline";
    }
}

static Contact *find_contact(Account *account, const char *name);

static const char *avatar_notice(INT32 notice)
{
    switch (notice) {
    case BarevStream_avatarRequested: return "requesting peer vCard";
    case BarevStream_avatarReceived: return "received and checksum verified";
    case BarevStream_avatarRemoved: return "peer removed image";
    case BarevStream_avatarRejected: return "rejected vCard image: unsupported format, limits or malformed data";
    case BarevStream_avatarMismatch: return "rejected checksum mismatch";
    case BarevStream_avatarExpired: return "vCard request expired";
    case BarevStream_avatarQueueFull: return "pending image budget full";
    case BarevStream_avatarSuperseded: return "ignored superseded vCard result";
    case BarevStream_avatarError: return "peer returned vCard error";
    default: return "unknown state";
    }
}

static void sync_contacts(Account *account)
{
    unsigned index;
    if (!account->closing && BarevStream_TakePingReply(account->handle))
        purple_debug_info("voc-barev", "Ping: received peer response\n");
    for (index = 0; index < CONTACTS && !account->closing; ++index) {
        Contact *contact = &account->contacts[index];
        INT32 status;
        CHAR text[BarevStanzas_maxStatusBytes+1];
        char *name, *message;
        if (!contact->jid) continue;
        status = BarevStream_ContactStatus(account->handle, contact->index, text, sizeof(text));
        if (status == contact->status && !g_strcmp0(contact->message, (char *)text)) continue;
        contact->status = status;
        g_free(contact->message); contact->message = g_strdup((char *)text);
        if (status != BarevStanzas_offline) contact->backoff = 5;
        name = g_strdup(contact->jid);
        message = g_strdup(contact->message);
        if (status == BarevStanzas_offline) purple_prpl_got_user_status(account->purple, name, "offline", NULL);
        else purple_prpl_got_user_status(account->purple, name, status_id(status), "message", message, NULL);
        g_free(message); g_free(name);
    }
    while (!account->closing) {
        CHAR name[384], body[BarevStanzas_maxMessageBytes+1];
        char *escaped;
        Contact *contact;
        if (!BarevStream_TakeMessage(account->handle, name, sizeof(name), body, sizeof(body))) break;
        contact = find_contact(account, (char *)name);
        /* serv_got_im clears frontend typing. Apply the final coalesced chat
         * state after all queued message bodies have reached libpurple. */
        if (contact) contact->typing = BarevStanzas_stopped;
        escaped = purple_markup_escape_text((char *)body, -1);
        serv_got_im(purple_account_get_connection(account->purple), (char *)name,
            escaped, PURPLE_MESSAGE_RECV, time(NULL));
        g_free(escaped);
    }
    for (index = 0; index < CONTACTS && !account->closing; ++index) {
        Contact *contact = &account->contacts[index];
        INT32 typing;
        char *name;
        if (!contact->jid) continue;
        typing = BarevStream_ContactTyping(account->handle, contact->index);
        if (typing == contact->typing) continue;
        contact->typing = typing; name = g_strdup(contact->jid);
        if (typing == BarevStanzas_stopped)
            serv_got_typing_stopped(purple_account_get_connection(account->purple), name);
        else serv_got_typing(purple_account_get_connection(account->purple), name, 0,
            typing == BarevStanzas_composing ? PURPLE_TYPING : PURPLE_TYPED);
        g_free(name);
    }
    while (!account->closing) {
        CHAR name[384], bytes[BarevAvatar_maxBytes], hash[41];
        INT32 length;
        void *copy = NULL;
        if (!BarevStream_TakeAvatar(account->handle, name, sizeof(name), bytes, sizeof(bytes), hash, sizeof(hash), &length)) break;
        if (length) { copy = g_malloc(length); memcpy(copy, bytes, length); }
        purple_buddy_icons_set_for_user(account->purple, (char *)name, copy, length, length ? (char *)hash : NULL);
    }
    while (!account->closing) {
        INT32 notice = BarevStream_TakeAvatarNotice(account->handle);
        if (!notice) break;
        purple_debug_info("voc-barev", "Avatar: %s\n", avatar_notice(notice));
    }
    if (!account->closing && account->transfers) {
        int32_t streams[CONNECTIONS];
        unsigned count = 0;
        GList *item;
        for (item = account->pipes; item && count < CONNECTIONS; item = item->next) {
            Pipe *pipe = item->data;
            if (pipe->handle && BarevStream_State(pipe->handle) == BarevStream_online) streams[count++] = pipe->handle;
        }
        for (index = 0; index < count && !account->closing; ++index)
            BarevTransfers_Offers(account->transfers, streams[index]);
        if (!account->closing) BarevTransfers_Sync(account->transfers);
    }
}

static void destroy_pipe(Pipe *pipe)
{
    Account *account = pipe->account;
    CHAR reason[96] = {0};
    if (pipe->handle) BarevStream_Reason(pipe->handle, reason, sizeof(reason));
    if (*reason) purple_debug_info("voc-barev", "Closing peer stream: %s\n", (char *)reason);
    remove_input(&pipe->read_watch);
    remove_input(&pipe->write_watch);
    if (pipe->fd >= 0) close(pipe->fd);
    if (pipe->handle) BarevStream_Lost(pipe->handle);
    account->pipes = g_list_remove(account->pipes, pipe);
    --pipe_count;
    g_free(pipe);
}

static void reconcile(Account *account)
{
    GList *item = account->pipes;
    while (item) {
        Pipe *pipe = item->data;
        item = item->next;
        if (pipe->handle && BarevStream_State(pipe->handle) < 0) {
            destroy_pipe(pipe);
        }
    }
}

static void io_ready(gpointer data, gint fd, PurpleInputCondition condition);

static gboolean flush(Pipe *pipe)
{
    CHAR bytes[4096];
    unsigned budget = 16384;
    int32_t length;
    while (budget && (length = BarevStream_Peek(pipe->handle, bytes, sizeof(bytes))) > 0) {
        if ((unsigned)length > budget) length = (INT32)budget;
        ssize_t sent = send(pipe->fd, bytes, length, MSG_NOSIGNAL);
        if (sent < 0 && errno == EINTR) continue;
        if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (sent <= 0) return FALSE;
        BarevStream_Sent(pipe->handle, sent);
        budget -= (unsigned)sent;
    }
    length = BarevStream_Peek(pipe->handle, bytes, sizeof(bytes));
    if (length && !pipe->write_watch) {
        pipe->write_watch = purple_input_add(pipe->fd, PURPLE_INPUT_WRITE, io_ready, pipe);
        if (!pipe->write_watch) return FALSE;
    } else if (!length && pipe->write_watch) {
        remove_input(&pipe->write_watch);
    }
    return BarevStream_State(pipe->handle) >= 0;
}

static gboolean established(Pipe *pipe)
{
    char peer[INET6_ADDRSTRLEN], local[INET6_ADDRSTRLEN];
    if (!endpoints(pipe, peer, local)) return FALSE;
    pipe->handle = BarevStream_NewConnection(pipe->account->handle,
        pipe->expected ? pipe->expected->index : 0, (BOOLEAN)(pipe->incoming != FALSE),
        (CHAR *)peer, strlen(peer)+1, (CHAR *)local, strlen(local)+1);
    if (!pipe->handle) return FALSE;
    pipe->connecting = FALSE;
    pipe->read_watch = purple_input_add(pipe->fd, PURPLE_INPUT_READ, io_ready, pipe);
    return pipe->read_watch && flush(pipe);
}

static void io_ready(gpointer data, gint fd, PurpleInputCondition condition)
{
    Pipe *pipe = data;
    Account *account = pipe->account;
    HostFrame frame;
    gboolean okay = TRUE;
    (void)fd;
    account_ref(account);
    if (account->closing || !enter(&frame)) { account_unref(account); return; }
    if (pipe->connecting) {
        int error = 0;
        socklen_t length = sizeof(error);
        remove_input(&pipe->write_watch);
        okay = getsockopt(pipe->fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && !error;
        if (okay) okay = established(pipe);
    } else if (condition & PURPLE_INPUT_READ) {
        unsigned reads;
        for (reads = 0; okay && reads < 4; ++reads) {
            CHAR bytes[4096];
            ssize_t length = recv(pipe->fd, bytes, sizeof(bytes), 0);
            if (length < 0 && errno == EINTR) continue;
            if (length < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            if (length <= 0) {
                if (length == 0) purple_debug_info("voc-barev", "Peer socket reached EOF\n");
                else purple_debug_info("voc-barev", "Peer socket read failed (errno %d)\n", errno);
                okay = FALSE; break;
            }
            {
                gint64 second = g_get_monotonic_time()/1000000;
                if (pipe->rate_second != second) { pipe->rate_second = second; pipe->received = 0; }
                if ((unsigned)length > BarevStream_maxReceiveBytesPerSecond-pipe->received) {
                    purple_debug_info("voc-barev", "Peer socket receive-rate limit exceeded\n");
                    okay = FALSE; break;
                }
                pipe->received += (unsigned)length;
            }
            okay = BarevStream_Feed(pipe->handle, bytes, length, length) >= 0;
        }
        if (okay) okay = flush(pipe);
    } else if (condition & PURPLE_INPUT_WRITE) okay = flush(pipe);
    if (!okay) destroy_pipe(pipe);
    reconcile(account);
    sync_contacts(account);
    leave(&frame);
    account_unref(account);
}

static Pipe *new_pipe(Account *account, int fd, Contact *expected, gboolean incoming)
{
    Pipe *pipe;
    if (pipe_count >= CONNECTIONS) { close(fd); return NULL; }
    pipe = g_new0(Pipe, 1);
    pipe->account = account; pipe->fd = fd; pipe->expected = expected; pipe->incoming = incoming;
    pipe->deadline = g_get_monotonic_time()+30000000;
    account->pipes = g_list_prepend(account->pipes, pipe);
    ++pipe_count;
    return pipe;
}

static void accept_ready(gpointer data, gint fd, PurpleInputCondition condition)
{
    Account *account = data;
    HostFrame frame;
    unsigned count;
    (void)condition;
    account_ref(account);
    if (account->closing || !enter(&frame)) { account_unref(account); return; }
    for (count = 0; count < 8; ++count) {
        int accepted = accept4(fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        Pipe *pipe;
        if (accepted < 0) break;
        pipe = new_pipe(account, accepted, NULL, TRUE);
        if (pipe && !established(pipe)) destroy_pipe(pipe);
    }
    reconcile(account);
    sync_contacts(account);
    leave(&frame);
    account_unref(account);
}

static gboolean busy(Account *account, Contact *contact)
{
    GList *item;
    if (BarevStream_ContactOnline(account->handle, contact->index)) return TRUE;
    for (item = account->pipes; item; item = item->next) {
        Pipe *pipe = item->data;
        if (pipe->expected == contact) return TRUE;
    }
    return FALSE;
}

static void dial(Account *account, Contact *contact)
{
    struct sockaddr_in6 destination = {0}, local = {0};
    const char *address = strchr(contact->jid, '@')+1;
    int fd, result;
    Pipe *pipe;
    destination.sin6_family = AF_INET6; destination.sin6_port = htons(contact->port);
    if (inet_pton(AF_INET6, address, &destination.sin6_addr) != 1 || !ygg(&destination.sin6_addr)) return;
#ifdef BAREV_PROTOCOL_TEST
    if (*fixture_local) inet_pton(AF_INET6, "::1", &destination.sin6_addr);
#endif
    local.sin6_family = AF_INET6; local.sin6_addr = account->native;
    fd = socket(AF_INET6, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return;
    if (bind(fd, (struct sockaddr *)&local, sizeof(local))) { close(fd); return; }
    result = connect(fd, (struct sockaddr *)&destination, sizeof(destination));
    if (result && errno != EINPROGRESS) { close(fd); return; }
    pipe = new_pipe(account, fd, contact, FALSE);
    if (!pipe) return;
    if (!result) {
        if (!established(pipe)) destroy_pipe(pipe);
    } else {
        pipe->connecting = TRUE;
        pipe->write_watch = purple_input_add(fd, PURPLE_INPUT_WRITE, io_ready, pipe);
        if (!pipe->write_watch) destroy_pipe(pipe);
    }
}

static gboolean step(gpointer data)
{
    Account *account = data;
    HostFrame frame;
    GList *item;
    unsigned index;
    gint64 now = g_get_monotonic_time();
    account_ref(account);
    if (account->closing || !enter(&frame)) { account_unref(account); return FALSE; }
    {
        gint64 elapsed = MIN((now-account->last_tick)/1000000, 300);
        account->last_tick += elapsed*1000000;
        while (elapsed-- > 0) BarevStream_Tick(account->handle);
    }
    item = account->pipes;
    while (item) {
        Pipe *pipe = item->data;
        item = item->next;
        if ((pipe->connecting || BarevStream_State(pipe->handle) == 0) && now >= pipe->deadline)
            destroy_pipe(pipe);
        else if (!pipe->connecting && !flush(pipe)) destroy_pipe(pipe);
    }
    reconcile(account);
    for (index = 0; index < CONTACTS; ++index) {
        Contact *contact = &account->contacts[index];
        if (!contact->jid || contact->retry > now || busy(account, contact)) continue;
        contact->retry = now+(gint64)contact->backoff*1000000;
        if (contact->backoff < 30) contact->backoff = MIN(30, contact->backoff*2);
        dial(account, contact);
    }
    sync_contacts(account);
    leave(&frame);
    {
        gboolean keep = !account->closing;
        account_unref(account);
        return keep;
    }
}

static gboolean timer(gpointer data)
{
    Account *account = data;
    gboolean keep;
    account_ref(account);
    keep = step(account);
    if (account->closing && account->timer) {
        account->timer = 0;
        accounts = g_list_remove(accounts, account);
        account_unref(account);
    }
    account_unref(account);
    return keep;
}

static Contact *find_contact(Account *account, const char *name)
{
    unsigned index;
    for (index = 0; index < CONTACTS; ++index)
        if (account->contacts[index].jid && !strcmp(account->contacts[index].jid, name)) return &account->contacts[index];
    return NULL;
}

static gboolean transfer_peer(gpointer data, const char *who, int32_t *stream, int32_t *index, struct in6_addr *peer)
{
    Account *account = data;
    Contact *contact;
    char name[384];
    if (account->closing || !canonical(who, name) || !(contact = find_contact(account, name))) return FALSE;
    *stream = BarevStream_ContactConnection(account->handle, contact->index);
    *index = contact->index;
    return *stream && inet_pton(AF_INET6, strchr(name, '@')+1, peer) == 1;
}

static void transfer_flush(gpointer data)
{
    Account *account = data;
    GList *item = account->pipes;
    while (item && !account->closing) {
        Pipe *pipe = item->data;
        item = item->next;
        if (!pipe->connecting && !flush(pipe)) destroy_pipe(pipe);
    }
}

static void add_contact(Account *account, PurpleBuddy *buddy)
{
    char name[384];
    unsigned index;
    int port;
    int32_t handle;
    Contact *contact;
    PurpleBuddyIcon *icon;
    if (!canonical(purple_buddy_get_name(buddy), name) || find_contact(account, name)) return;
    port = purple_blist_node_get_int(PURPLE_BLIST_NODE(buddy), "barev_port");
    if (!port) port = purple_account_get_int(account->purple, "peer_port", DEFAULT_PORT);
    if (port < 1 || port > 65535) return;
    for (index = 0; index < CONTACTS; ++index) if (!account->contacts[index].jid) break;
    if (index == CONTACTS) return;
    handle = BarevStream_AddContact(account->handle, (CHAR *)name, strlen(name)+1);
    if (!handle) return;
    contact = &account->contacts[index];
    contact->jid = g_strdup(name); contact->index = handle; contact->port = port;
    contact->backoff = 5; contact->retry = 0; contact->status = BarevStanzas_offline;
    contact->typing = BarevStanzas_stopped;
    contact->message = g_strdup("");
    icon = purple_buddy_icons_find(account->purple, purple_buddy_get_name(buddy));
    if (icon) {
        size_t length;
        gconstpointer bytes = purple_buddy_icon_get_data(icon, &length);
        if (!account->closing && bytes && length <= BarevAvatar_maxBytes) {
            gboolean okay = BarevStream_RestoreAvatar(account->handle, handle, (CHAR *)bytes, length, length);
            purple_debug_info("voc-barev", "Peer avatar cache: %s\n", okay ? "validated" : "ignored unsupported image");
        }
        purple_buddy_icon_unref(icon);
    }
}

static gboolean save_status(Account *account, PurpleStatus *status)
{
    PurpleStatusPrimitive primitive;
    const char *message;
    char *plain = NULL;
    INT32 mode;
    gboolean okay;
    if (!status || !purple_status_is_online(status)) return TRUE;
    primitive = purple_status_type_get_primitive(purple_status_get_type(status));
    switch (primitive) {
    case PURPLE_STATUS_AWAY: mode = BarevStanzas_away; break;
    case PURPLE_STATUS_UNAVAILABLE: mode = BarevStanzas_dnd; break;
    case PURPLE_STATUS_EXTENDED_AWAY: mode = BarevStanzas_extendedAway; break;
    default: mode = BarevStanzas_available; break;
    }
    message = purple_status_get_attr_string(status, "message");
    if (!message) message = "";
    if (strnlen(message, 65537) > 65536 || !g_utf8_validate(message, -1, NULL)) return FALSE;
    purple_markup_html_to_xhtml(message, NULL, &plain);
    okay = plain && BarevStream_SetStatus(account->handle, mode, (CHAR *)plain, strlen(plain)+1);
    g_free(plain);
    return okay;
}

static gboolean save_avatar(Account *account, PurpleStoredImage *image)
{
    const void *bytes = image ? purple_imgstore_get_data(image) : "";
    size_t length = image ? purple_imgstore_get_size(image) : 0;
    if (length > BarevAvatar_maxBytes || (!bytes && length)) return FALSE;
    return BarevStream_SetAvatar(account->handle, (CHAR *)(bytes ? bytes : ""), length, length) != 0;
}

/* Only explicitly configured local icon paths reach this native file boundary.
 * Image data from peer stanzas never supplies a filename. */
static gpointer read_icon(const char *path, size_t *length)
{
    struct stat info;
    guchar *bytes;
    size_t at = 0;
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    *length = 0;
    if (fd < 0) return NULL;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > BarevAvatar_maxBytes) {
        close(fd); return NULL;
    }
    bytes = g_malloc((size_t)info.st_size);
    while (at < (size_t)info.st_size) {
        ssize_t count = read(fd, bytes+at, (size_t)info.st_size-at);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { g_free(bytes); close(fd); return NULL; }
        at += (size_t)count;
    }
    close(fd); *length = at; return bytes;
}

static void load_avatar(Account *account, PurpleConnection *gc)
{
    PurpleStoredImage *image = purple_buddy_icons_find_account_icon(account->purple);
    const char *path = NULL;
    gpointer bytes = NULL;
    size_t length = 0;
    if (image) {
        gboolean okay = save_avatar(account, image);
        purple_debug_info("voc-barev", "Startup cached avatar: %s\n", okay ? "loaded" : "unsupported image or limits");
        purple_imgstore_unref(image);
        return;
    }
    if (purple_account_get_bool(account->purple, "use-global-buddyicon", TRUE) &&
        !g_strcmp0(purple_core_get_ui(), "gtk-gaim") && purple_prefs_exists("/pidgin/accounts/buddyicon"))
        path = purple_prefs_get_path("/pidgin/accounts/buddyicon");
    if (!path || !*path) path = purple_account_get_buddy_icon_path(account->purple);
    if (!path || !*path) {
        purple_debug_info("voc-barev", "Startup avatar: none configured\n");
        return;
    }
    if (!g_strcmp0(purple_core_get_ui(), "gtk-gaim")) {
        GModule *host = g_module_open(NULL, G_MODULE_BIND_LAZY);
        gpointer symbol;
        gpointer (*convert)(PurplePlugin *, const char *, size_t *) = NULL;
        if (host && g_module_symbol(host, "pidgin_convert_buddy_icon", &symbol))
            memcpy(&convert, &symbol, sizeof(convert));
        /* Pidgin owns local image decoding, resizing and format conversion.
         * Its returned GLib allocation is copied into the Oberon state. */
        if (convert) bytes = convert(purple_connection_get_prpl(gc), path, &length);
        else bytes = read_icon(path, &length);
        if (host) g_module_close(host);
    } else bytes = read_icon(path, &length);
    if (bytes && length <= BarevAvatar_maxBytes &&
        BarevStream_SetAvatar(account->handle, bytes, length, length))
        purple_debug_info("voc-barev", "Startup configured avatar: loaded\n");
    else purple_debug_warning("voc-barev", "Startup configured avatar: unreadable, unsupported image or limits\n");
    g_free(bytes);
}

static void login(PurpleAccount *purple)
{
    PurpleConnection *gc = purple_account_get_connection(purple);
    HostFrame frame;
    Account *account;
    struct sockaddr_in6 address = {0};
    socklen_t length = sizeof(address);
    GSList *buddies, *item;
    int only6 = 1, reuse = 1;
    const char *nick = purple_account_get_username(purple);
    if (!enter(&frame)) return;
    purple_debug_info("voc-barev", "Starting VOC Barev %s\n", BAREV_VERSION);
    account = g_new0(Account, 1);
    account->purple = purple; account->listener = -1; account->refs = 1;
    account->last_tick = g_get_monotonic_time();
    account->port = purple_account_get_int(purple, "port", DEFAULT_PORT);
    if (!nick || !g_utf8_validate(nick, -1, NULL) || strlen(nick) > 256 ||
        !local_address(purple, account->address, &account->native)) goto bad_address;
    account->handle = BarevStream_NewAccount((CHAR *)nick, strlen(nick)+1,
        (CHAR *)account->address, strlen(account->address)+1);
    if (!account->handle) goto bad_address;
    if (!save_status(account, purple_presence_get_active_status(purple_account_get_presence(purple)))) goto bad_status;
    load_avatar(account, gc);
    if (account->port < 1 || account->port > 65535) {
#ifdef BAREV_PROTOCOL_TEST
        if (!*fixture_local || account->port != 0)
#endif
        goto bad_listener;
    }
    address.sin6_family = AF_INET6; address.sin6_addr = account->native;
    address.sin6_port = htons(account->port);
    account->listener = socket(AF_INET6, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (account->listener < 0) goto bad_listener;
    if (setsockopt(account->listener, IPPROTO_IPV6, IPV6_V6ONLY, &only6, sizeof(only6)) ||
        setsockopt(account->listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) ||
        bind(account->listener, (struct sockaddr *)&address, sizeof(address)) ||
        listen(account->listener, 16) ||
        getsockname(account->listener, (struct sockaddr *)&address, &length)) goto bad_listener;
    account->port = ntohs(address.sin6_port);
    account->listener_watch = purple_input_add(account->listener, PURPLE_INPUT_READ, accept_ready, account);
    account->timer = purple_timeout_add(1000, timer, account);
    if (!account->listener_watch || !account->timer) goto bad_listener;
    account->transfers = BarevTransfers_New(purple, account->handle, &account->native, account->address,
#ifdef BAREV_PROTOCOL_TEST
        *fixture_local != 0,
#else
        FALSE,
#endif
        transfer_peer, transfer_flush, account);
    accounts = g_list_prepend(accounts, account);
    purple_connection_set_protocol_data(gc, account);
    account_ref(account);
    buddies = purple_find_buddies(purple, NULL);
    for (item = buddies; item && !account->closing; item = item->next) add_contact(account, item->data);
    g_slist_free(buddies);
    if (!account->closing) purple_connection_set_state(gc, PURPLE_CONNECTED);
    if (!account->closing) step(account);
    account_unref(account);
    leave(&frame);
    return;
bad_address:
    purple_connection_error_reason(gc, PURPLE_CONNECTION_ERROR_INVALID_SETTINGS,
        "Use a UTF-8 nickname and an assigned Yggdrasil IPv6 address. Set Local IPv6 explicitly if several are available.");
    goto failed;
bad_status:
    purple_connection_error_reason(gc, PURPLE_CONNECTION_ERROR_INVALID_SETTINGS,
        "Status text must be valid UTF-8 of at most 1024 bytes.");
    goto failed;
bad_listener:
    purple_connection_error_reason(gc, PURPLE_CONNECTION_ERROR_NETWORK_ERROR,
        "Cannot listen on the selected Yggdrasil IPv6 address and port.");
failed:
    remove_input(&account->listener_watch);
    if (account->listener >= 0) close(account->listener);
    if (account->handle) BarevStream_FreeAccount(account->handle);
    retire_account(account);
    leave(&frame);
}

static void disconnect(PurpleConnection *gc)
{
    Account *account = purple_connection_get_protocol_data(gc);
    HostFrame frame;
    unsigned index;
    if (!account || !enter(&frame)) return;
    account->closing = TRUE;
    purple_connection_set_protocol_data(gc, NULL);
    {
        BarevTransfers *transfers = account->transfers;
        account->transfers = NULL;
        BarevTransfers_Close(transfers);
    }
    remove_input(&account->listener_watch);
    if (account->listener >= 0) close(account->listener);
    while (account->pipes) {
        Pipe *pipe = account->pipes->data;
        if (!pipe->connecting) {
            static const char ending[] = "</stream:stream>";
            (void)send(pipe->fd, ending, sizeof(ending)-1, MSG_NOSIGNAL);
        }
        destroy_pipe(pipe);
    }
    BarevStream_FreeAccount(account->handle);
    for (index = 0; index < CONTACTS; ++index) {
        Contact *contact = &account->contacts[index];
        contact->status = BarevStanzas_offline;
        if (contact->jid && contact->typing != BarevStanzas_stopped) {
            char *name = g_strdup(contact->jid);
            contact->typing = BarevStanzas_stopped;
            serv_got_typing_stopped(gc, name);
            g_free(name);
        }
    }
    leave(&frame);
    retire_account(account);
}

static const char *normalize(const PurpleAccount *account, const char *name)
{
    static char output[384];
    HostFrame frame;
    gboolean okay;
    if (!enter(&frame)) return NULL;
    okay = canonical(name, output);
    if (!okay && account && name && strlen(name) <= 256 &&
        !strcmp(name, purple_account_get_username(account)) && g_utf8_validate(name, -1, NULL) &&
        BarevAddress_Nick((CHAR *)name, strlen(name)+1)) {
        g_strlcpy(output, name, sizeof(output));
        okay = TRUE;
    }
    leave(&frame);
    return okay ? output : NULL;
}

static void add_buddy(PurpleConnection *gc, PurpleBuddy *buddy, PurpleGroup *group)
{
    Account *account = purple_connection_get_protocol_data(gc);
    HostFrame frame;
    (void)group;
    if (!account || !enter(&frame)) return;
    account_ref(account);
    add_contact(account, buddy);
    if (!find_contact(account, purple_buddy_get_name(buddy)))
        purple_notify_error(gc, "VOC Barev contact", "Contact could not be enabled",
            "Use nick@Yggdrasil-IPv6 and a port from 1 to 65535. Up to 128 contacts are supported.");
    if (!account->closing) step(account);
    leave(&frame);
    account_unref(account);
}

static void remove_buddy(PurpleConnection *gc, PurpleBuddy *buddy, PurpleGroup *group)
{
    Account *account = purple_connection_get_protocol_data(gc);
    Contact *contact;
    HostFrame frame;
    GList *item;
    char name[384];
    gboolean typing;
    (void)group;
    if (!account || account->closing || !enter(&frame)) return;
    if (!canonical(purple_buddy_get_name(buddy), name) || !(contact = find_contact(account, name))) { leave(&frame); return; }
    account_ref(account);
    typing = contact->typing != BarevStanzas_stopped;
    contact->typing = BarevStanzas_stopped;
    item = account->pipes;
    while (item) {
        Pipe *pipe = item->data;
        item = item->next;
        if (pipe->expected == contact) destroy_pipe(pipe);
    }
    BarevStream_RemoveContact(account->handle, contact->index);
    g_clear_pointer(&contact->jid, g_free);
    g_clear_pointer(&contact->message, g_free);
    reconcile(account);
    if (!account->closing && account->transfers) BarevTransfers_Sync(account->transfers);
    if (typing && !account->closing) serv_got_typing_stopped(gc, name);
    leave(&frame);
    account_unref(account);
}

static GList *status_types(PurpleAccount *account)
{
    GList *types = NULL;
    (void)account;
    types = g_list_append(types, purple_status_type_new_with_attrs(PURPLE_STATUS_AVAILABLE, "available", "Available", TRUE, TRUE, FALSE,
        "message", "Message", purple_value_new(PURPLE_TYPE_STRING), NULL));
    types = g_list_append(types, purple_status_type_new_with_attrs(PURPLE_STATUS_AWAY, "away", "Away", TRUE, TRUE, FALSE,
        "message", "Message", purple_value_new(PURPLE_TYPE_STRING), NULL));
    types = g_list_append(types, purple_status_type_new_with_attrs(PURPLE_STATUS_UNAVAILABLE, "dnd", "Do Not Disturb", TRUE, TRUE, FALSE,
        "message", "Message", purple_value_new(PURPLE_TYPE_STRING), NULL));
    types = g_list_append(types, purple_status_type_new_with_attrs(PURPLE_STATUS_EXTENDED_AWAY, "xa", "Extended Away", TRUE, TRUE, FALSE,
        "message", "Message", purple_value_new(PURPLE_TYPE_STRING), NULL));
    return g_list_append(types, purple_status_type_new_full(PURPLE_STATUS_OFFLINE, "offline", "Offline", TRUE, TRUE, FALSE));
}
static const char *list_icon(PurpleAccount *account, PurpleBuddy *buddy)
{ (void)account; (void)buddy; return "barev"; }
static int send_im(PurpleConnection *gc, const char *who, const char *text, PurpleMessageFlags flags)
{
    Account *account = purple_connection_get_protocol_data(gc);
    HostFrame frame;
    Contact *contact;
    char name[384], *plain = NULL;
    GList *item;
    int result;
    INT32 connection;
    (void)flags;
    if (!account || account->closing || !enter(&frame)) return -ENOTCONN;
    account_ref(account);
    result = -EINVAL;
    if (!canonical(who, name) || !(contact = find_contact(account, name)) || !text) goto done;
    if (strnlen(text, 65537) > 65536) { result = -E2BIG; goto done; }
    if (!g_utf8_validate(text, -1, NULL)) goto done;
    purple_markup_html_to_xhtml(text, NULL, &plain);
    if (!plain) goto done;
    connection = BarevStream_ContactConnection(account->handle, contact->index);
    result = BarevStream_SendMessage(account->handle, contact->index, (CHAR *)plain, strlen(plain)+1);
    if (result == BarevStream_invalidText) result = -E2BIG;
    else if (result == BarevStream_outputFull) result = -EAGAIN;
    else if (result < 0) result = -ENOTCONN;
    else {
        item = account->pipes;
        while (item) {
            Pipe *pipe = item->data;
            item = item->next;
            if (pipe->handle == connection && !flush(pipe)) { destroy_pipe(pipe); result = -EIO; }
        }
        reconcile(account);
        sync_contacts(account);
    }
done:
    g_free(plain);
    leave(&frame);
    account_unref(account);
    return result;
}

static void set_status(PurpleAccount *purple, PurpleStatus *status)
{
    PurpleConnection *gc = purple_account_get_connection(purple);
    Account *account = gc ? purple_connection_get_protocol_data(gc) : NULL;
    HostFrame frame;
    if (!account || account->closing || !enter(&frame)) return;
    account_ref(account);
    if (!save_status(account, status))
        purple_notify_error(gc, "VOC Barev status", "Status could not be sent",
            "Use valid UTF-8 text of at most 1024 bytes.");
    if (!account->closing) step(account);
    leave(&frame);
    account_unref(account);
}

static unsigned send_typing(PurpleConnection *gc, const char *who, PurpleTypingState state)
{
    Account *account = purple_connection_get_protocol_data(gc);
    HostFrame frame;
    Contact *contact;
    char name[384];
    INT32 mode, connection, result;
    unsigned refresh = 0;
    GList *item;
    if (!account || account->closing || !enter(&frame)) return 0;
    account_ref(account);
    if (!canonical(who, name) || !(contact = find_contact(account, name))) goto done;
    mode = state == PURPLE_TYPING ? BarevStanzas_composing : BarevStanzas_stopped;
    connection = BarevStream_ContactConnection(account->handle, contact->index);
    result = BarevStream_SendTyping(account->handle, contact->index, mode);
    if (result != BarevStream_online) goto done;
    refresh = mode == BarevStanzas_composing ? BarevStanzas_typingRefresh : 0;
    item = account->pipes;
    while (item) {
        Pipe *pipe = item->data;
        item = item->next;
        if (pipe->handle == connection && !flush(pipe)) { destroy_pipe(pipe); refresh = 0; }
    }
    reconcile(account); sync_contacts(account);
done:
    leave(&frame); account_unref(account);
    return refresh;
}

static void set_buddy_icon(PurpleConnection *gc, PurpleStoredImage *image)
{
    Account *account = purple_connection_get_protocol_data(gc);
    HostFrame frame;
    if (!account || account->closing || !enter(&frame)) return;
    account_ref(account);
    if (!save_avatar(account, image))
        purple_notify_error(gc, "VOC Barev avatar", "Avatar could not be sent",
            "Use a static PNG or JPEG up to 65535 bytes and 2048 by 2048 pixels.");
    if (!account->closing) step(account);
    leave(&frame); account_unref(account);
}

static PurpleXfer *new_xfer(PurpleConnection *gc, const char *who)
{
    Account *account = purple_connection_get_protocol_data(gc);
    PurpleXfer *xfer = NULL;
    HostFrame frame;
    if (!account || account->closing || !enter(&frame)) return NULL;
    account_ref(account);
    if (account->transfers) xfer = BarevTransfers_NewXfer(account->transfers, who);
    leave(&frame); account_unref(account); return xfer;
}

static void send_file(PurpleConnection *gc, const char *who, const char *path)
{
    PurpleXfer *xfer = new_xfer(gc, who);
    if (!xfer) return;
    if (path) purple_xfer_request_accepted(xfer, path);
    else purple_xfer_request(xfer);
}

static gboolean can_receive_file(PurpleConnection *gc, const char *who)
{
    Account *account = purple_connection_get_protocol_data(gc);
    HostFrame frame;
    struct in6_addr peer;
    int32_t stream, index;
    gboolean okay;
    if (!account || account->closing || !enter(&frame)) return FALSE;
    okay = transfer_peer(account, who, &stream, &index, &peer);
    leave(&frame); return okay;
}

static char *status_text(PurpleBuddy *buddy)
{
    PurpleStatus *status = purple_presence_get_active_status(purple_buddy_get_presence(buddy));
    const char *message = purple_status_get_attr_string(status, "message");
    return message && *message ? purple_markup_escape_text(message, -1) : NULL;
}

static void close_user_info(gpointer data)
{
    int id = GPOINTER_TO_INT(data);
    if (id) purple_imgstore_unref_by_id(id);
}

static void get_info(PurpleConnection *gc, const char *who)
{
    PurpleBuddy *buddy = purple_find_buddy(purple_connection_get_account(gc), who);
    PurpleNotifyUserInfo *info;
    PurpleBuddyIcon *icon;
    PurpleStatus *status;
    const char *message;
    int id = 0;

    if (!buddy) return;
    info = purple_notify_user_info_new();
    purple_notify_user_info_add_pair_plaintext(info, "JID", purple_buddy_get_name(buddy));
    status = purple_presence_get_active_status(purple_buddy_get_presence(buddy));
    message = status ? purple_status_get_attr_string(status, "message") : NULL;
    if (message && *message) purple_notify_user_info_add_pair_plaintext(info, "Status", message);
    icon = purple_buddy_get_icon(buddy);
    if (icon) {
        size_t length = 0;
        gconstpointer bytes = purple_buddy_icon_get_data(icon, &length);
        if (bytes && length && length <= BarevAvatar_maxBytes) {
            gpointer copy = g_malloc(length);
            memcpy(copy, bytes, length);
            id = purple_imgstore_add_with_id(copy, length, "avatar");
            if (id) {
                char *markup = g_strdup_printf("<img id=\"%d\" alt=\"avatar\"/>", id);
                purple_notify_user_info_add_pair(info, "Avatar", markup);
                g_free(markup);
            } else g_free(copy);
        }
    }
    if (!purple_notify_userinfo(gc, who, info, close_user_info, GINT_TO_POINTER(id)))
        close_user_info(GINT_TO_POINTER(id));
    purple_notify_user_info_destroy(info);
}
static gboolean unload(PurplePlugin *plugin)
{ (void)plugin; return !depth && BarevPlugin_Idle(); }
static void destroy(PurplePlugin *plugin)
{ (void)plugin; BarevPlugin_Shutdown(); }

static PurplePluginProtocolInfo protocol = {
    .options = OPT_PROTO_NO_PASSWORD,
    .icon_spec = {"png,jpeg", 0, 0, 96, 96, BarevAvatar_maxBytes, PURPLE_ICON_SCALE_SEND | PURPLE_ICON_SCALE_DISPLAY},
    .list_icon = list_icon,
    .status_types = status_types,
    .status_text = status_text,
    .login = login,
    .close = disconnect,
    .send_im = send_im,
    .send_typing = send_typing,
    .get_info = get_info,
    .new_xfer = new_xfer,
    .send_file = send_file,
    .can_receive_file = can_receive_file,
    .set_status = set_status,
    .set_buddy_icon = set_buddy_icon,
    .add_buddy = add_buddy,
    .remove_buddy = remove_buddy,
    .normalize = normalize,
    .struct_size = sizeof(PurplePluginProtocolInfo)
};
static PurplePluginInfo info = {
    .magic = PURPLE_PLUGIN_MAGIC,
    .major_version = PURPLE_MAJOR_VERSION,
    .minor_version = PURPLE_MINOR_VERSION,
    .type = PURPLE_PLUGIN_PROTOCOL,
    .priority = PURPLE_PRIORITY_DEFAULT,
    .id = "prpl-voc-barev",
    .name = "VOC Barev",
    .version = BAREV_VERSION,
    .summary = "Yggdrasil peer streams in Oberon",
    .description = "Checked Yggdrasil streams, presence, avatars, UTF-8 messages and typing in Oberon.",
    .homepage = "https://github.com/norayr/barev-purple",
    .unload = unload,
    .destroy = destroy,
    .extra_info = &protocol
};
static void init_plugin(PurplePlugin *plugin)
{
    (void)plugin;
    protocol.protocol_options = g_list_append(protocol.protocol_options,
        purple_account_option_string_new("Local Yggdrasil IPv6 (empty: detect)", "local_ipv6", ""));
    protocol.protocol_options = g_list_append(protocol.protocol_options,
        purple_account_option_int_new("Local port", "port", DEFAULT_PORT));
    protocol.protocol_options = g_list_append(protocol.protocol_options,
        purple_account_option_int_new("Default contact port", "peer_port", DEFAULT_PORT));
}
PURPLE_INIT_PLUGIN(voc_barev, init_plugin, info)

#ifdef BAREV_PROTOCOL_TEST
static int32_t unit(void)
{
    HostFrame frame;
    INT32 result;
    if (!enter(&frame)) return -1;
    TestBarev__init();
    result = TestBarev_Run();
    Heap_GC(1);
    leave(&frame);
    return result;
}
static gboolean fixture(const char *local, const char *peer)
{
    HostFrame frame;
    CHAR ip[16];
    if (accounts || !local || !peer || strlen(local) >= 40 || strlen(peer) >= 40 || !enter(&frame)) return FALSE;
    if (!BarevAddress_ParseIP((CHAR *)local, strlen(local)+1, ip) || !BarevAddress_Yggdrasil(ip) ||
        !BarevAddress_ParseIP((CHAR *)peer, strlen(peer)+1, ip) || !BarevAddress_Yggdrasil(ip)) { leave(&frame); return FALSE; }
    g_strlcpy(fixture_local, local, sizeof(fixture_local));
    g_strlcpy(fixture_peer, peer, sizeof(fixture_peer));
    leave(&frame);
    return TRUE;
}
static int port(PurpleAccount *purple)
{
    Account *account = purple_account_get_connection(purple) ?
        purple_connection_get_protocol_data(purple_account_get_connection(purple)) : NULL;
    return account ? account->port : 0;
}
static void tick(PurpleAccount *purple, unsigned seconds)
{
    Account *account = purple_connection_get_protocol_data(purple_account_get_connection(purple));
    HostFrame frame;
    if (!account || seconds > 300 || !enter(&frame)) return;
    account_ref(account);
    while (seconds--) BarevStream_Tick(account->handle);
    {
        GList *item = account->pipes;
        while (item) {
            Pipe *pipe = item->data;
            item = item->next;
            if (!pipe->connecting && !flush(pipe)) destroy_pipe(pipe);
        }
    }
    reconcile(account);
    sync_contacts(account);
    leave(&frame);
    account_unref(account);
}
static unsigned connections(void) { return pipe_count; }
G_MODULE_EXPORT const BarevProtocolTestAPI *barev_protocol_test_api(void)
{
    static const BarevProtocolTestAPI api = {1, unit, fixture, port, tick, connections};
    return &api;
}
#endif
