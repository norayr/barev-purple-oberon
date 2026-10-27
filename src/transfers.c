/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <glib.h>
#include <libpurple/account.h>
#include <libpurple/debug.h>
#include <libpurple/eventloop.h>
#include <libpurple/request.h>
#include <arpa/inet.h>
#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include "runtime.h"
#include "BarevFiles.h"
#include "BarevStream.h"
#include "protocol-constants.h"
#include "transfers.h"

typedef struct Transfer Transfer;
struct BarevTransfers {
    PurpleAccount *account;
    int32_t handle;
    struct in6_addr local;
    char address[INET6_ADDRSTRLEN];
    gboolean fixture, closing;
    GList *files;
    unsigned refs;
    BarevTransferPeer peer;
    void (*flush)(gpointer);
    gpointer owner;
};
struct Transfer {
    BarevTransfers *context;
    PurpleXfer *purple;
    int32_t token, stream;
    struct in6_addr peer;
    int fd, listener;
    guint read_watch, write_watch, listen_watch;
    gboolean connecting, handed, retired, reported, control_lost;
    const char *failure;
    int socket_error;
    unsigned refs;
};
static unsigned native_count;

gboolean BarevTransfers_Idle(void) { return native_count == 0; }

static void context_unref(BarevTransfers *context)
{ if (!--context->refs) g_free(context); }
static void ref(Transfer *transfer) { ++transfer->refs; }
static void unref(Transfer *transfer)
{
    if (--transfer->refs) return;
    purple_xfer_unref(transfer->purple);
    context_unref(transfer->context);
    g_free(transfer);
}
static void remove_watch(guint *watch)
{ guint id = *watch; *watch = 0; if (id) purple_input_remove(id); }

static gboolean failed(Transfer *transfer, const char *reason, int error)
{
    if (!transfer->failure) { transfer->failure = reason; transfer->socket_error = error; }
    return FALSE;
}

static const char *failure_reason(INT32 reason)
{
    switch (reason) {
    case BarevFiles_cancelled: return "local cancellation";
    case BarevFiles_peerRejected: return "peer rejected negotiation";
    case BarevFiles_invalidReply: return "invalid negotiation reply";
    case BarevFiles_invalidHost: return "streamhost rejected by address/port policy";
    case BarevFiles_handshakeFailed: return "invalid SOCKS5 handshake";
    case BarevFiles_negotiationTimeout: return "negotiation timeout";
    case BarevFiles_idleTimeout: return "idle timeout";
    case BarevFiles_connectionClosed: return "messaging connection closed";
    default: return NULL;
    }
}

/* Diagnostics deliberately omit identities, paths, filenames and wire IDs. */
static void report(Transfer *transfer, const char *fallback)
{
    INT32 phase, age, reason = BarevFiles_Diagnostics(transfer->token, &phase, &age);
    const char *message = transfer->failure ? transfer->failure : failure_reason(reason);
    if (transfer->reported) return;
    transfer->reported = TRUE;
    if (purple_xfer_is_completed(transfer->purple)) message = "completed";
    purple_debug_info("voc-barev", "File transfer %d (%s): %s; phase=%d idle=%d bytes=%zu/%zu errno=%d\n",
        transfer->token, purple_xfer_get_type(transfer->purple) == PURPLE_XFER_SEND ? "send" : "receive",
        message ? message : fallback, phase, age, purple_xfer_get_bytes_sent(transfer->purple),
        purple_xfer_get_size(transfer->purple), transfer->socket_error);
}

/* A failed transfer must discard queued bytes instead of draining them before
   the receiver can observe closure. Successful transfers close gracefully. */
static void abort_socket(int fd)
{
    struct linger linger = {1, 0};
    if (fd >= 0 && setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, sizeof(linger)))
        purple_debug_warning("voc-barev", "File transfer abortive close setup failed: errno=%d\n", errno);
}

/* Detach callbacks before notifying the host: UI signals may disconnect the
   account or remove a contact synchronously. Snapshot references keep this
   native state alive until the current callback has returned. */
static void detach(Transfer *transfer)
{
    if (transfer->retired) return;
    transfer->retired = TRUE;
    remove_watch(&transfer->read_watch); remove_watch(&transfer->write_watch);
    remove_watch(&transfer->listen_watch);
    if (!purple_xfer_is_completed(transfer->purple)) {
        abort_socket(transfer->fd);
        if (transfer->handed) abort_socket(transfer->purple->fd);
    }
    if (transfer->fd >= 0) close(transfer->fd);
    if (transfer->listener >= 0) close(transfer->listener);
    transfer->fd = transfer->listener = -1;
    BarevFiles_Forget(transfer->token);
    transfer->purple->data = NULL;
    purple_xfer_set_init_fnc(transfer->purple, NULL);
    purple_xfer_set_request_denied_fnc(transfer->purple, NULL);
    purple_xfer_set_cancel_send_fnc(transfer->purple, NULL);
    purple_xfer_set_cancel_recv_fnc(transfer->purple, NULL);
    purple_xfer_set_end_fnc(transfer->purple, NULL);
    purple_xfer_set_ack_fnc(transfer->purple, NULL);
    purple_xfer_set_read_fnc(transfer->purple, NULL);
    purple_xfer_set_write_fnc(transfer->purple, NULL);
    transfer->context->files = g_list_remove(transfer->context->files, transfer);
    --native_count;
    unref(transfer);
}

static void stop(Transfer *transfer)
{
    PurpleXfer *purple = transfer->purple;
    if (transfer->retired) return;
    ref(transfer); purple_xfer_ref(purple);
    report(transfer, transfer->context->closing ? "account closed" : "native transfer failure");
    if (!transfer->retired && !transfer->context->closing) {
        BarevFiles_Cancel(transfer->token);
        transfer->context->flush(transfer->context->owner);
    }
    detach(transfer);
    if (!purple_xfer_is_canceled(purple) && !purple_xfer_is_completed(purple)) purple_xfer_cancel_remote(purple);
    purple_xfer_unref(purple); unref(transfer);
}

static void finished(PurpleXfer *purple)
{
    Transfer *transfer = purple->data;
    HostFrame frame;
    if (!transfer || !BarevRuntime_Enter(&frame)) return;
    ref(transfer);
    report(transfer, purple_xfer_get_status(purple) == PURPLE_XFER_STATUS_CANCEL_LOCAL ?
        "local cancellation or file I/O failure" : "file or socket I/O failure");
    if (!purple_xfer_is_completed(purple) && !transfer->context->closing) {
        BarevFiles_Cancel(transfer->token);
        transfer->context->flush(transfer->context->owner);
    }
    detach(transfer);
    BarevRuntime_Leave(&frame); unref(transfer);
}

static void init(PurpleXfer *purple)
{
    Transfer *transfer = purple->data;
    BarevTransfers *context;
    HostFrame frame;
    gboolean okay = FALSE;
    if (!transfer || !BarevRuntime_Enter(&frame)) return;
    ref(transfer); context = transfer->context;
    if (!context->closing) {
        if (purple_xfer_get_type(purple) == PURPLE_XFER_SEND) {
            size_t size = purple_xfer_get_size(purple);
            const char *name = purple_xfer_get_filename(purple);
            int32_t stream, contact;
            struct in6_addr peer;
            if (name && size <= BarevFileStanzas_maxFileBytes &&
                context->peer(context->owner, purple_xfer_get_remote_user(purple), &stream, &contact, &peer) && stream == transfer->stream) {
                transfer->token = BarevStream_OfferFile(context->handle, contact, (CHAR *)name, strlen(name)+1, (INT32)size);
                okay = transfer->token != 0;
            }
        } else okay = BarevFiles_Accept(transfer->token) != 0;
        if (okay) context->flush(context->owner);
    }
    if (!okay && !transfer->retired) {
        failed(transfer, "file offer could not be initialized", 0); stop(transfer);
    }
    BarevRuntime_Leave(&frame); unref(transfer);
}

static gssize write_data(const guchar *bytes, size_t length, PurpleXfer *purple)
{
    HostFrame frame;
    Transfer *transfer = purple->data;
    gssize written;
    if (!BarevRuntime_Enter(&frame)) return -1;
    written = send(purple->fd, bytes, MIN(length, (size_t)16384), MSG_NOSIGNAL);
    if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) written = 0;
    else if (written < 0 && transfer) failed(transfer, "data socket write failed", errno);
    BarevRuntime_Leave(&frame);
    return written;
}

static gssize read_data(guchar **bytes, PurpleXfer *purple)
{
    HostFrame frame;
    Transfer *transfer = purple->data;
    size_t length = MIN(purple_xfer_get_bytes_remaining(purple), purple->current_buffer_size);
    gssize received;
    if (!BarevRuntime_Enter(&frame)) return -1;
    *bytes = g_malloc(length);
    received = recv(purple->fd, *bytes, length, 0);
    if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) received = 0;
    else if (received <= 0) {
        if (transfer) failed(transfer, received ? "data socket read failed" : "data socket closed before end of file",
            received ? errno : 0);
        received = -1;
    }
    BarevRuntime_Leave(&frame);
    return received;
}
static void progress(PurpleXfer *purple, const guchar *bytes, size_t length)
{
    Transfer *transfer = purple->data;
    HostFrame frame;
    (void)bytes;
    if (!transfer || !length || !BarevRuntime_Enter(&frame)) return;
    BarevFiles_Progress(transfer->token);
    /* libpurple calls ack after accounting for socket I/O and writing received
       data to the file. Complete here so callbacks see the final byte count. */
    if (purple_xfer_get_bytes_sent(purple) >= purple_xfer_get_size(purple))
        purple_xfer_set_completed(purple, TRUE);
    BarevRuntime_Leave(&frame);
}

static Transfer *create(BarevTransfers *context, const char *name, PurpleXferType direction)
{
    Transfer *transfer;
    int32_t stream, contact;
    struct in6_addr peer;
    if (context->closing || native_count >= BarevFiles_maxTransfers ||
        !context->peer(context->owner, name, &stream, &contact, &peer)) return NULL;
    transfer = g_new0(Transfer, 1);
    transfer->context = context; transfer->stream = stream;
    transfer->peer = peer; transfer->fd = transfer->listener = -1; transfer->refs = 1;
    ++context->refs;
    transfer->purple = purple_xfer_new(context->account, direction, name);
    if (!transfer->purple || context->closing) {
        if (transfer->purple) purple_xfer_cancel_local(transfer->purple);
        context_unref(context); g_free(transfer); return NULL;
    }
    ++native_count;
    purple_xfer_ref(transfer->purple);
    transfer->purple->data = transfer;
    purple_xfer_set_init_fnc(transfer->purple, init);
    purple_xfer_set_request_denied_fnc(transfer->purple, finished);
    purple_xfer_set_cancel_send_fnc(transfer->purple, finished);
    purple_xfer_set_cancel_recv_fnc(transfer->purple, finished);
    purple_xfer_set_end_fnc(transfer->purple, finished);
    purple_xfer_set_ack_fnc(transfer->purple, progress);
    purple_xfer_set_read_fnc(transfer->purple, read_data);
    purple_xfer_set_write_fnc(transfer->purple, write_data);
    context->files = g_list_prepend(context->files, transfer);
    return transfer;
}

BarevTransfers *BarevTransfers_New(PurpleAccount *account, int32_t handle,
    const struct in6_addr *local, const char *address, gboolean fixture,
    BarevTransferPeer peer, void (*flush)(gpointer), gpointer owner)
{
    BarevTransfers *context = g_new0(BarevTransfers, 1);
    context->account = account; context->handle = handle; context->local = *local;
    g_strlcpy(context->address, address, sizeof(context->address)); context->fixture = fixture;
    context->peer = peer; context->flush = flush; context->owner = owner; context->refs = 1;
    return context;
}

PurpleXfer *BarevTransfers_NewXfer(BarevTransfers *context, const char *who)
{
    Transfer *transfer = create(context, who, PURPLE_XFER_SEND);
    return transfer ? transfer->purple : NULL;
}

void BarevTransfers_Offers(BarevTransfers *context, int32_t stream)
{
    ++context->refs;
    while (!context->closing) {
        CHAR name[384], filename[256];
        INT32 size, token = BarevFiles_TakeOffer(stream, name, sizeof(name), filename, sizeof(filename), &size);
        Transfer *transfer;
        if (!token) break;
        transfer = create(context, (char *)name, PURPLE_XFER_RECEIVE);
        if (!transfer || transfer->stream != stream) {
            if (transfer) stop(transfer);
            BarevFiles_Cancel(token);
            if (!context->closing) context->flush(context->owner);
            BarevFiles_Forget(token);
            continue;
        }
        transfer->token = token;
        purple_xfer_set_filename(transfer->purple, (char *)filename);
        purple_xfer_set_size(transfer->purple, size);
        purple_xfer_request(transfer->purple);
    }
    context_unref(context);
}

static gboolean checked_peer(Transfer *transfer, int fd)
{
    struct sockaddr_in6 peer = {0}, local = {0};
    socklen_t length = sizeof(peer);
    if (getpeername(fd, (struct sockaddr *)&peer, &length) || length != sizeof(peer) || peer.sin6_family != AF_INET6 || peer.sin6_scope_id) return FALSE;
    length = sizeof(local);
    if (getsockname(fd, (struct sockaddr *)&local, &length) || length != sizeof(local) || local.sin6_family != AF_INET6 || local.sin6_scope_id) return FALSE;
    if (memcmp(&local.sin6_addr, &transfer->context->local, sizeof(local.sin6_addr))) return FALSE;
#ifdef BAREV_PROTOCOL_TEST
    if (transfer->context->fixture) return IN6_IS_ADDR_LOOPBACK(&peer.sin6_addr);
#endif
    return !memcmp(&peer.sin6_addr, &transfer->peer, sizeof(peer.sin6_addr));
}

static void io(gpointer data, gint fd, PurpleInputCondition condition);
static gboolean watches(Transfer *transfer)
{
    CHAR bytes[260];
    INT32 output = BarevFiles_Peek(transfer->token, bytes, sizeof(bytes));
    gboolean reading = !transfer->connecting && BarevFiles_Need(transfer->token) > 0;
    gboolean writing = transfer->connecting || output > 0;
    if (!reading) remove_watch(&transfer->read_watch);
    else if (!transfer->read_watch) {
        transfer->read_watch = purple_input_add(transfer->fd, PURPLE_INPUT_READ, io, transfer);
        if (!transfer->read_watch) return failed(transfer, "socket read watch registration failed", 0);
    }
    if (!writing) remove_watch(&transfer->write_watch);
    else if (!transfer->write_watch) {
        transfer->write_watch = purple_input_add(transfer->fd, PURPLE_INPUT_WRITE, io, transfer);
        if (!transfer->write_watch) return failed(transfer, "socket write watch registration failed", 0);
    }
    return TRUE;
}

static gboolean handoff(Transfer *transfer)
{
    int fd = transfer->fd;
    remove_watch(&transfer->read_watch); remove_watch(&transfer->write_watch);
    transfer->fd = -1; transfer->handed = TRUE;
    BarevFiles_Started(transfer->token);
    transfer->context->flush(transfer->context->owner);
    if (transfer->retired || transfer->context->closing || BarevFiles_State(transfer->token) != BarevFiles_active) {
        abort_socket(fd); close(fd); return failed(transfer, "messaging connection closed before data handoff", 0);
    }
    purple_debug_info("voc-barev", "File transfer %d: starting data I/O\n", transfer->token);
    purple_xfer_start(transfer->purple, fd, NULL, 0);
    if (!transfer->retired && !purple_xfer_get_size(transfer->purple)) {
        purple_xfer_set_completed(transfer->purple, TRUE);
        purple_xfer_end(transfer->purple);
    }
    return TRUE;
}

static void io(gpointer data, gint fd, PurpleInputCondition condition)
{
    Transfer *transfer = data;
    HostFrame frame;
    gboolean okay = TRUE;
    unsigned work;
    (void)fd; (void)condition;
    if (!BarevRuntime_Enter(&frame)) return;
    ref(transfer);
    if (transfer->connecting) {
        int error = 0;
        socklen_t length = sizeof(error);
        if (getsockopt(transfer->fd, SOL_SOCKET, SO_ERROR, &error, &length))
            okay = failed(transfer, "data socket connect status failed", errno);
        else if (error) okay = failed(transfer, "data socket connect failed", error);
        else if (!checked_peer(transfer, transfer->fd)) okay = failed(transfer, "data socket endpoint mismatch", 0);
        transfer->connecting = FALSE;
        if (okay && !BarevFiles_OpenSocket(transfer->token)) okay = failed(transfer, "unexpected socket negotiation state", 0);
    }
    for (work = 0; okay && !transfer->retired && work < 8; ++work) {
        CHAR bytes[260];
        INT32 count = BarevFiles_Peek(transfer->token, bytes, sizeof(bytes));
        ssize_t n;
        if (count) {
            n = send(transfer->fd, bytes, count, MSG_NOSIGNAL);
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            if (n <= 0) { okay = failed(transfer, "SOCKS5 socket write failed", n < 0 ? errno : 0); break; }
            BarevFiles_Sent(transfer->token, n);
        } else if ((count = BarevFiles_Need(transfer->token)) > 0) {
            n = recv(transfer->fd, bytes, MIN((INT32)sizeof(bytes), count), 0);
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            if (n <= 0) {
                okay = failed(transfer, n ? "SOCKS5 socket read failed" : "socket closed during SOCKS5 handshake", n < 0 ? errno : 0);
                break;
            }
            BarevFiles_Feed(transfer->token, bytes, n, n);
        } else break;
    }
    if (!transfer->retired) {
        INT32 state = BarevFiles_State(transfer->token);
        if (!okay || state < 0) stop(transfer);
        else if (state == BarevFiles_ready) { if (!handoff(transfer) && !transfer->retired) stop(transfer); }
        else if (!watches(transfer)) stop(transfer);
    }
    BarevRuntime_Leave(&frame); unref(transfer);
}

static void accept_ready(gpointer data, gint fd, PurpleInputCondition condition)
{
    Transfer *transfer = data;
    HostFrame frame;
    unsigned i;
    (void)condition;
    if (!BarevRuntime_Enter(&frame)) return;
    ref(transfer);
    for (i = 0; i < 8; ++i) {
        int accepted = accept4(fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (accepted < 0) break;
        if (!checked_peer(transfer, accepted)) { close(accepted); continue; }
        remove_watch(&transfer->listen_watch); close(transfer->listener); transfer->listener = -1;
        transfer->fd = accepted;
        if (!BarevFiles_OpenSocket(transfer->token) || !watches(transfer)) stop(transfer);
        break;
    }
    BarevRuntime_Leave(&frame); unref(transfer);
}

static gboolean listen_file(Transfer *transfer)
{
    struct sockaddr_in6 local = {0};
    int port, v6 = 1;
    transfer->listener = socket(AF_INET6, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (transfer->listener < 0) return failed(transfer, "listener socket creation failed", errno);
    if (setsockopt(transfer->listener, IPPROTO_IPV6, IPV6_V6ONLY, &v6, sizeof(v6)))
        return failed(transfer, "IPv6-only listener setup failed", errno);
    local.sin6_family = AF_INET6; local.sin6_addr = transfer->context->local;
    for (port = BarevFileStanzas_portMin; port <= BarevFileStanzas_portMax; ++port) {
        local.sin6_port = htons(port);
        if (!bind(transfer->listener, (struct sockaddr *)&local, sizeof(local))) break;
        if (errno != EADDRINUSE) return failed(transfer, "listener bind failed", errno);
    }
    if (port > BarevFileStanzas_portMax) return failed(transfer, "transfer port range exhausted", EADDRINUSE);
    if (listen(transfer->listener, 4)) return failed(transfer, "socket listen failed", errno);
    transfer->listen_watch = purple_input_add(transfer->listener, PURPLE_INPUT_READ, accept_ready, transfer);
    if (!transfer->listen_watch) return failed(transfer, "listener watch registration failed", 0);
    transfer->purple->local_port = port;
    return BarevFiles_Listening(transfer->token, (CHAR *)transfer->context->address, strlen(transfer->context->address)+1, port) != 0;
}

static gboolean connect_file(Transfer *transfer)
{
    CHAR host[64];
    struct sockaddr_in6 remote = {0}, local = {0};
    int port = BarevFiles_Endpoint(transfer->token, host, sizeof(host)), result;
    if (port < BarevFileStanzas_portMin || port > BarevFileStanzas_portMax ||
        inet_pton(AF_INET6, (char *)host, &remote.sin6_addr) != 1 ||
        memcmp(&remote.sin6_addr, &transfer->peer, sizeof(remote.sin6_addr)))
        return failed(transfer, "data socket endpoint rejected", 0);
#ifdef BAREV_PROTOCOL_TEST
    if (transfer->context->fixture) inet_pton(AF_INET6, "::1", &remote.sin6_addr);
#endif
    remote.sin6_family = AF_INET6; remote.sin6_port = htons(port);
    local.sin6_family = AF_INET6; local.sin6_addr = transfer->context->local;
    transfer->fd = socket(AF_INET6, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (transfer->fd < 0) return failed(transfer, "data socket creation failed", errno);
    if (bind(transfer->fd, (struct sockaddr *)&local, sizeof(local))) return failed(transfer, "data socket bind failed", errno);
    result = connect(transfer->fd, (struct sockaddr *)&remote, sizeof(remote));
    if (result && errno != EINPROGRESS) return failed(transfer, "data socket connect failed", errno);
    transfer->connecting = result != 0;
    if (!result && (!checked_peer(transfer, transfer->fd) || !BarevFiles_OpenSocket(transfer->token))) return FALSE;
    return watches(transfer);
}

void BarevTransfers_Sync(BarevTransfers *context)
{
    GList *snapshot = g_list_copy(context->files), *item;
    ++context->refs;
    for (item = snapshot; item; item = item->next) ref(item->data);
    for (item = snapshot; item; item = item->next) {
        Transfer *transfer = item->data;
        if (!transfer->retired && !context->closing && transfer->token) {
            INT32 state = BarevFiles_State(transfer->token);
            gboolean okay = TRUE;
            if (state == BarevFiles_active && !transfer->control_lost && BarevStream_State(transfer->stream) < 0) {
                transfer->control_lost = TRUE;
                purple_debug_info("voc-barev", "File transfer %d: messaging stream unavailable; continuing data I/O\n", transfer->token);
            }
            if (state < 0) okay = FALSE;
            else if (state == BarevFiles_needListener && transfer->listener < 0) okay = listen_file(transfer);
            else if (state == BarevFiles_needConnect && transfer->fd < 0) okay = connect_file(transfer);
            else if (state == BarevFiles_ready && !transfer->handed) okay = handoff(transfer);
            if (!okay && !transfer->retired) stop(transfer);
        }
        unref(transfer);
    }
    g_list_free(snapshot);
    if (!context->closing) context->flush(context->owner);
    context_unref(context);
}

void BarevTransfers_Close(BarevTransfers *context)
{
    if (!context || context->closing) return;
    context->closing = TRUE;
    while (context->files) stop(context->files->data);
    context_unref(context);
}
