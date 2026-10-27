#!/usr/bin/env python3
"""Direct SI/SOCKS5 file-transfer fixtures on isolated IPv6 loopback sockets."""
import base64
import contextlib
import errno
import fcntl
import hashlib
from pathlib import Path
import select
import socket
import struct
import time
from xml.sax.saxutils import quoteattr

SI = "http://jabber.org/protocol/si"
FILE = "http://jabber.org/protocol/si/profile/file-transfer"
FEATURE = "http://jabber.org/protocol/feature-neg"
DATA = "jabber:x:data"
STREAM = "http://jabber.org/protocol/bytestreams"


def selection(kind):
    value = f"<value>{STREAM}</value>"
    if kind == "form":
        value = f"<option>{value}</option>"
    return (f"<feature xmlns='{FEATURE}'><x xmlns='{DATA}' type='{kind}'>"
            f"<field var='stream-method'>{value}</field></x></feature>")


def offer(id="offer", sid="session", name="զեկոյց & draft.bin", size=1234):
    return (f"<iq type='set' id={quoteattr(id)}><si xmlns='{SI}' id={quoteattr(sid)} profile='{FILE}'>"
            f"<file xmlns='{FILE}' name={quoteattr(name)} size={quoteattr(str(size))}/>"
            f"{selection('form')}</si></iq>")


def accepted(id):
    return f"<iq type='result' id={quoteattr(id)}><si xmlns='{SI}'>{selection('submit')}</si></iq>"


def host_query(port, sid="session", host="200::2", jid="bob@200::2"):
    return (f"<iq type='set' id='bytestream'><query xmlns='{STREAM}' sid={quoteattr(sid)} mode='tcp'>"
            f"<streamhost jid={quoteattr(jid)} host={quoteattr(host)} port='{port}'/></query></iq>")


@contextlib.contextmanager
def listener():
    server = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    try:
        for port in range(50000, 50050):
            try:
                server.bind(("::1", port))
                break
            except OSError as error:
                if error.errno != errno.EADDRINUSE:
                    raise
        else:
            raise AssertionError("no loopback test port available in 50000-50049")
        server.listen(4)
        server.settimeout(5)
        yield server
    finally:
        server.close()


def read_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count-len(data))
        if not chunk:
            raise AssertionError(("short data socket", count, len(data)))
        data += chunk
    return data


def fragmented(sock, data):
    for byte in data:
        sock.sendall(bytes([byte]))


def state(host):
    host.command("file-state")
    return tuple(map(int, host.wait("FILE-STATE ").split()[1:]))


def wait_state(host, expected):
    deadline = time.monotonic()+5
    while True:
        status, count = state(host)
        if status == expected:
            return count
        if time.monotonic() >= deadline:
            raise AssertionError(("transfer state deadline", expected, status, host.events))
        time.sleep(0.01)


def diagnostic(host, check, reason):
    # A command response ensures earlier diagnostics have reached the reader.
    state(host)
    summaries = [event for event in host.events if event.startswith("DEBUG File transfer ") and "; phase=" in event]
    check(any(reason in event for event in summaries), ("transfer failure reason recorded", reason, summaries))
    check(all(not any(value in event for value in ["alice", "bob", "200::", ".bin", "session"])
              for event in summaries),
          "transfer diagnostics omit identities and filenames")


def backpressure(Host, incoming, establish, check, stop=None, control_loss=False):
    with Host(gio=True) as host, incoming(host) as wire:
        establish(host, wire)
        host.command("file-generate 16777216"); host.wait("FILE-OFFERED"); packet = wire.stanza()
        wire.send(accepted(packet.get("id"))); packet = wire.stanza()
        query = packet.find(f"{{{STREAM}}}query")
        endpoint = query.find(f"{{{STREAM}}}streamhost")
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as data:
            data.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            data.settimeout(5); data.connect(("::1", int(endpoint.get("port"))))
            data.sendall(b"\x05\x01\x00"); read_exact(data, 2)
            digest = hashlib.sha1((query.get("sid")+"alice@200::1bob@200::2").encode()).hexdigest().encode()
            data.sendall(b"\x05\x01\x00\x03\x28"+digest+b"\x00\x00"); read_exact(data, 47)
            wire.send(f"<iq type='result' id={quoteattr(packet.get('id'))}><query xmlns='{STREAM}'><streamhost-used jid='alice@200::1'/></query></iq>")
            previous, stable = -1, 0
            deadline = time.monotonic()+5
            while stable < 4:
                status, count = state(host)
                stable = stable+1 if count == previous and count > 0 else 0
                previous = count
                if time.monotonic() >= deadline:
                    raise AssertionError("send-buffer backpressure deadline")
                time.sleep(0.03)
            initial = previous
            check(initial < 16777216, "large transfer fills the socket before reaching end of file")
            if control_loss:
                host.tick(30)
                check(wire.stanza().find("{urn:xmpp:ping}ping") is not None, "idle messaging stream sends a ping during file I/O")
                host.tick(15); wire.closed()
                check(host.state()[0] == 0, "unanswered messaging ping closes the control stream")
                check(state(host)[0] == 3, "established file socket survives a messaging ping deadline")
            if stop:
                if stop == "peer-reset":
                    data.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)); data.close()
                    check(wait_state(host, 6) == initial, "peer socket reset fails the blocked sender")
                    diagnostic(host, check, "data socket write failed")
                    check(host.state()[0] == 1, "data socket write failure preserves messaging")
                    return
                if stop == "timeout":
                    for unused in range(6):
                        barrier(wire); host.tick(20)
                    check(wait_state(host, 6) == initial, "blocked sender reaches the idle deadline without false progress")
                    diagnostic(host, check, "idle timeout")
                else:
                    host.command("file-cancel"); host.wait("FILE-CANCELED")
                    check(wait_state(host, 5) == initial, "blocked sender can be cancelled locally")
                drained, reset = 0, False
                data.settimeout(2)
                while True:
                    try:
                        chunk = data.recv(65536)
                    except ConnectionResetError:
                        reset = True; break
                    if not chunk:
                        break
                    drained += len(chunk)
                check(reset and drained < initial, "failed/cancelled sender discards queued data and promptly resets the peer socket")
                check(host.state()[0] == 1, "aborting a blocked transfer preserves messaging")
                return
            received = hashlib.sha256()
            chunk_size = 65536 if control_loss else 2048
            for unused in range(15):
                received.update(read_exact(data, chunk_size))
                # Let the TCP acknowledgment reach the sender before advancing
                # its monotonic test clock. The application socket stays full.
                time.sleep(0.05)
                if not control_loss:
                    barrier(wire)
                host.tick(10)
                status, count = state(host)
                check(status == 3, ("slow receiver is making progress despite a full sender buffer", status, initial, count))
            if control_loss:
                check(count > initial, "data-only I/O refreshes the detached transfer deadline")
            data.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024*1024)
            remaining = 16777216-15*chunk_size
            while remaining:
                chunk = data.recv(min(65536, remaining))
                if not chunk:
                    raise AssertionError(("large transfer ended early", remaining))
                received.update(chunk); remaining -= len(chunk)
            pattern = bytes((i*17+3) % 256 for i in range(4096))
            check(received.digest() == hashlib.sha256(pattern*4096).digest(), "large backpressured transfer preserves every byte")
            check(wait_state(host, 4) == 16777216, "large backpressured transfer completes")
            check(data.recv(1) == b"", "large successful transfer closes gracefully")
            # The test peer resets only after observing successful graceful EOF,
            # releasing the fixed loopback port without waiting for TIME_WAIT.
            data.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))


def receiving_control_loss(Host, incoming, establish, check):
    payload = bytes(range(256))*1024
    with Host(gio=True) as host, incoming(host) as wire, listener() as server:
        establish(host, wire)
        wire.send(offer(size=len(payload))); host.wait("FILE-REQUEST")
        host.command("file-accept"); host.wait("FILE-ACCEPTED"); wire.stanza()
        wire.send(host_query(server.getsockname()[1])); data, unused = server.accept()
        with data:
            data.settimeout(5); read_exact(data, 3); data.sendall(b"\x05\x00"); read_exact(data, 47)
            data.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
            wire.stanza()
            wire.send("</s:stream>"); wire.closed()
            check(host.state()[0] == 0 and state(host)[0] == 3, "receiver retains its established data socket after messaging EOF")
            for at in range(0, len(payload), 65536):
                data.sendall(payload[at:at+65536])
                deadline = time.monotonic()+5
                while state(host)[1] < at+65536:
                    if time.monotonic() >= deadline:
                        raise AssertionError("detached receiver progress deadline")
                    time.sleep(0.01)
                if at+65536 < len(payload):
                    host.tick(40)
            check(wait_state(host, 4) == len(payload), "detached receiver completes using data-only progress")
            host.command("file-data")
            check(base64.b64decode(host.wait("FILE-DATA ").split()[1]) == payload, "detached receiver preserves every byte")


def run(Host, incoming, establish, check):
    # Configurations may run concurrently, but all exercise the same fixed
    # loopback port range. Serialize this suite, including its exhaustion case.
    directory = Path(__file__).resolve().parents[1] / "build"
    directory.mkdir(exist_ok=True)
    with (directory / "file-tests.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        run_locked(Host, incoming, establish, check)


def barrier(wire):
    wire.send("<iq type='get' id='file-barrier'><ping xmlns='urn:xmpp:ping'/></iq>")
    packet = wire.stanza()
    if packet.get("id") != "file-barrier":
        raise AssertionError(("file barrier", packet.tag, packet.attrib))


def run_locked(Host, incoming, establish, check):
    # The peer connects to the advertised Yggdrasil endpoint through a test-only
    # loopback mapping. Both the address policy and the fixed port policy remain
    # exercised by the production parser and native socket boundary.
    backpressure(Host, incoming, establish, check)
    backpressure(Host, incoming, establish, check, control_loss=True)
    receiving_control_loss(Host, incoming, establish, check)
    backpressure(Host, incoming, establish, check, stop="timeout")
    backpressure(Host, incoming, establish, check, stop="cancel")
    backpressure(Host, incoming, establish, check, stop="peer-reset")
    for payload, reentrant in [(b"\x00binary\xff"*8192, False), (b"", True), (b"complete then disconnect", True)]:
        with Host(gio=bool(payload)) as host, incoming(host) as wire:
            establish(host, wire)
            host.command("file-send "+base64.b64encode(payload).decode())
            host.wait("FILE-OFFERED")
            packet = wire.stanza()
            si = packet.find(f"{{{SI}}}si")
            metadata = si.find(f"{{{FILE}}}file")
            check(int(metadata.get("size")) == len(payload), "outgoing file size")
            wire.send(accepted(packet.get("id")))
            packet = wire.stanza()
            query = packet.find(f"{{{STREAM}}}query")
            endpoint = query.find(f"{{{STREAM}}}streamhost")
            port = int(endpoint.get("port"))
            check(50000 <= port <= 50049 and endpoint.get("host") == "200::1", "transfer advertises selected address and fixed-range port")
            with socket.create_connection(("::1", port), timeout=5) as data:
                fragmented(data, b"\x05\x01\x00")
                check(read_exact(data, 2) == b"\x05\x00", "SOCKS5 server selects no authentication")
                digest = hashlib.sha1((query.get("sid")+"alice@200::1"+"bob@200::2").encode()).hexdigest().encode()
                fragmented(data, b"\x05\x01\x00\x03\x28"+digest+b"\x00\x00")
                check(read_exact(data, 47) == b"\x05\x00\x00\x03\x28"+digest+b"\x00\x00", "fragmented SOCKS5 digest checked and acknowledged")
                if reentrant:
                    host.command("reentrant-file-complete"); host.wait("ARMED")
                wire.send(f"<iq type='result' id={quoteattr(packet.get('id'))}><query xmlns='{STREAM}'><streamhost-used jid='alice@200::1'/></query></iq>")
                check(read_exact(data, len(payload)) == payload, "outgoing file bytes are exact")
                check(wait_state(host, 4) == len(payload), "outgoing transfer completes")
                check("FILE-ADDED" in host.events, "fast and slow transfers reach the host's transfer-window callback")
                if payload and not reentrant:
                    check(data.recv(1) == b"", "successful sender retains graceful closure")
                if reentrant:
                    wire.closed(); check(host.state()[1] == 0, "completion callback can disconnect reentrantly")
                data.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))

    for payload, reentrant in [(b"\x00\xffreceived"*4096, False), (b"", False), (b"received then disconnect", True)]:
        with Host(gio=bool(payload)) as host, incoming(host) as wire, listener() as server:
            establish(host, wire)
            wire.send(offer(size=len(payload)))
            host.wait("FILE-REQUEST")
            wire.send(host_query(server.getsockname()[1]))
            check(wire.stanza().get("type") == "error", "data negotiation before approval is rejected")
            check(not select.select([server], [], [], 0)[0], "no data connection before user approval")
            host.command("file-accept"); host.wait("FILE-ACCEPTED")
            check(wire.stanza().get("type") == "result", "incoming offer requires approval")
            wire.send(host_query(server.getsockname()[1]))
            data, address = server.accept()
            with data:
                data.settimeout(5)
                check(address[0] == "::1", "outgoing data socket is locally bound")
                check(read_exact(data, 3) == b"\x05\x01\x00", "SOCKS5 client greeting")
                fragmented(data, b"\x05\x00")
                digest = hashlib.sha1(b"sessionbob@200::2alice@200::1").hexdigest().encode()
                check(read_exact(data, 47) == b"\x05\x01\x00\x03\x28"+digest+b"\x00\x00", "SOCKS5 client uses SID and wire identities")
                # C Barev returns the peer IP as BND.ADDR rather than the digest.
                # Coalesce payload with the last handshake byte to detect overread.
                response = b"\x05\x00\x00\x03\x06"+b"200::1"+b"\x00\x00"
                if reentrant:
                    host.command("reentrant-file-complete"); host.wait("ARMED")
                fragmented(data, response[:-1]); data.sendall(response[-1:]+payload)
                packet = wire.stanza()
                check(packet.find(f"{{{STREAM}}}query/{{{STREAM}}}streamhost-used").get("jid") == "bob@200::2", "receiver confirms selected streamhost")
                check(wait_state(host, 4) == len(payload), "incoming transfer completes")
                host.command("file-data")
                encoded = host.wait("FILE-DATA ").split(maxsplit=1)
                check(len(encoded) == 1 or encoded[1] != "-", "received file exists, including empty files")
                check(base64.b64decode(encoded[1]) == payload if len(encoded) > 1 else not payload, "received file content is exact")
                if reentrant:
                    wire.closed(); check(host.state()[1] == 0, "receive completion callback can disconnect reentrantly")

    with Host() as host, incoming(host) as wire:
        establish(host, wire)
        wire.send(offer()); host.wait("FILE-REQUEST")
        host.command("file-reject"); host.wait("FILE-REJECTED")
        check(wire.stanza().get("type") == "error", "declined offer gets an IQ error")
        check(host.state()[0] == 1, "declining a transfer preserves messaging")

    for changes in [dict(name="../escape"), dict(size="-1"), dict(size="2147483648")]:
        with Host() as host, incoming(host) as wire:
            establish(host, wire)
            wire.send(offer(**changes))
            check(wire.stanza().get("type") == "error", "invalid file metadata rejected")
            check(host.state()[0] == 1, "bad offers preserve the peer stream")

    for host_address, jid, port in [("200::3", "bob@200::2", 50000), ("::1", "bob@200::2", 50000),
                                    ("200::2", "other@200::2", 50000), ("200::2", "bob@200::2", 49999),
                                    ("200::2", "bob@200::2", 50050)]:
        with Host() as host, incoming(host) as wire:
            establish(host, wire)
            wire.send(offer()); host.wait("FILE-REQUEST")
            host.command("file-accept"); host.wait("FILE-ACCEPTED"); wire.stanza()
            wire.send(host_query(port, host=host_address, jid=jid))
            check(wire.stanza().get("type") == "error", "unsafe streamhost refused before connecting")
            check(wait_state(host, 6) == 0, "unsafe streamhost cancels transfer")
            diagnostic(host, check, "streamhost rejected by address/port policy")

    with Host() as host, incoming(host) as wire:
        establish(host, wire)
        host.command("file-send YWJj"); host.wait("FILE-OFFERED"); packet = wire.stanza()
        wire.send(f"<iq type='error' id={quoteattr(packet.get('id'))}><error type='cancel'/></iq>")
        check(wait_state(host, 6) == 0, "peer rejection fails a pending transfer")
        diagnostic(host, check, "peer rejected negotiation")

    with Host() as host, incoming(host) as wire, listener() as server:
        establish(host, wire)
        port = server.getsockname()[1]; server.close()
        wire.send(offer()); host.wait("FILE-REQUEST")
        host.command("file-accept"); host.wait("FILE-ACCEPTED"); wire.stanza()
        wire.send(host_query(port))
        check(wait_state(host, 6) == 0, "refused data connection fails negotiation")
        diagnostic(host, check, "data socket connect failed")

    for handshake in [False, True]:
        with Host() as host, incoming(host) as wire, contextlib.ExitStack() as stack:
            establish(host, wire)
            host.command("file-send YWJj"); host.wait("FILE-OFFERED"); packet = wire.stanza()
            if handshake:
                wire.send(accepted(packet.get("id"))); packet = wire.stanza()
                endpoint = packet.find(f"{{{STREAM}}}query/{{{STREAM}}}streamhost")
                stack.enter_context(socket.create_connection(("::1", int(endpoint.get("port"))), timeout=5))
            wire.send("</s:stream>"); wire.closed()
            check(wait_state(host, 6) == 0, "control loss cancels a transfer whose data negotiation is incomplete")
            diagnostic(host, check, "messaging connection closed")

    for action in ["file-cancel", "disconnect", "remove"]:
        with Host() as host, incoming(host) as wire:
            establish(host, wire)
            host.command("file-send "+base64.b64encode(b"pending data").decode()); host.wait("FILE-OFFERED")
            wire.stanza()
            host.command(action)
            host.wait({"file-cancel":"FILE-CANCELED", "disconnect":"DISCONNECTED", "remove":"REMOVED"}[action])
            current = state(host)
            check(current[0] in (5, 6), ("pending transfer releases on cancellation and stream teardown", action, current))

    for bad_request in [b"\x04\x01\x00", b"\x05\x01\x02", b"wrong-digest"]:
        with Host() as host, incoming(host) as wire:
            establish(host, wire)
            host.command("file-send YWJj"); host.wait("FILE-OFFERED"); packet = wire.stanza()
            wire.send(accepted(packet.get("id"))); packet = wire.stanza()
            endpoint = packet.find(f"{{{STREAM}}}query/{{{STREAM}}}streamhost")
            with socket.create_connection(("::1", int(endpoint.get("port"))), timeout=5) as data:
                if bad_request == b"wrong-digest":
                    data.sendall(b"\x05\x01\x00"); read_exact(data, 2)
                    data.sendall(b"\x05\x01\x00\x03\x28"+b"0"*40+b"\x00\x00")
                else:
                    data.sendall(bad_request)
                check(wait_state(host, 6) == 0, "invalid SOCKS5 handshake cancels without file data")
                diagnostic(host, check, "invalid SOCKS5 handshake")
                try:
                    closed = data.recv(1) == b""
                except ConnectionResetError:
                    closed = True
                check(closed, "invalid handshake socket closed")
                check(host.state()[0] == 1, "bad data handshake leaves messaging connected")

    with contextlib.ExitStack() as stack:
        # Hold every port. A TIME_WAIT socket may expire while the offer is
        # processed, so treating EADDRINUSE as a reservation makes this racy.
        pending = set(range(50000, 50050))
        deadline = time.monotonic()+90
        while pending:
            for port in list(pending):
                sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                try:
                    sock.bind(("::1", port)); sock.listen(1)
                except OSError as error:
                    sock.close()
                    if error.errno != errno.EADDRINUSE:
                        raise
                else:
                    stack.callback(sock.close); pending.remove(port)
            if pending:
                if time.monotonic() >= deadline:
                    raise AssertionError(("could not reserve the entire transfer port range", sorted(pending)))
                time.sleep(0.05)
        with Host() as host, incoming(host) as wire:
            establish(host, wire)
            host.command("file-send YWJj"); host.wait("FILE-OFFERED"); packet = wire.stanza()
            wire.send(accepted(packet.get("id")))
            check(wait_state(host, 6) == 0, "fixed port exhaustion fails cleanly")
            diagnostic(host, check, "transfer port range exhausted")
            check(host.state()[0] == 1, "port exhaustion preserves messaging")

    with Host() as host, incoming(host) as wire:
        establish(host, wire)
        host.command("file-send YWJj"); host.wait("FILE-OFFERED"); wire.stanza()
        for unused in range(6):
            barrier(wire); host.tick(20)
        check(wait_state(host, 6) == 0, "negotiation deadline releases a pending transfer")
        diagnostic(host, check, "negotiation timeout")
        check(host.state()[0] == 1, "transfer deadline does not disconnect messaging")

    for direction in ["send", "receive"]:
        with Host() as host, incoming(host) as wire:
            establish(host, wire); host.command("reentrant-file"); host.wait("ARMED")
            if direction == "send":
                host.command("file-send YWJj"); host.wait("FILE-OFFERED")
            else:
                wire.send(offer()); host.wait("FILE-NEW ")
            wire.closed()
            check(host.state()[1] == 0, "transfer-creation callback can disconnect reentrantly")

    with Host() as host, incoming(host) as wire:
        establish(host, wire)
        host.command("file-send YWJj"); host.wait("FILE-OFFERED"); packet = wire.stanza()
        host.command("fail-input"); host.wait("ARMED"); wire.send(accepted(packet.get("id")))
        check(wait_state(host, 6) == 0, "failed listener watch registration releases transfer resources")
        diagnostic(host, check, "listener watch registration failed")

    for interrupted in ["eof", "reset", "timeout", "detached-timeout", "detached-remove", "detached-disconnect"]:
        with Host() as host, incoming(host) as wire, listener() as server:
            establish(host, wire)
            wire.send(offer(size=100)); host.wait("FILE-REQUEST")
            host.command("file-accept"); host.wait("FILE-ACCEPTED"); wire.stanza()
            wire.send(host_query(server.getsockname()[1])); data, unused = server.accept()
            with data:
                data.settimeout(5); read_exact(data, 3); data.sendall(b"\x05\x00"); read_exact(data, 47)
                data.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00"+b"partial")
                wire.stanza()
                deadline = time.monotonic()+5
                while state(host)[1] < 7:
                    if time.monotonic() >= deadline:
                        raise AssertionError("partial file data deadline")
                    time.sleep(0.01)
                if interrupted == "eof":
                    data.shutdown(socket.SHUT_WR)
                elif interrupted == "reset":
                    data.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)); data.close()
                elif interrupted.startswith("detached-"):
                    wire.send("</s:stream>"); wire.closed()
                    check(state(host)[0] == 3, "control closure retains a partially received active transfer")
                    action = interrupted.removeprefix("detached-")
                    if action == "timeout":
                        for unused in range(6):
                            host.tick(20)
                    else:
                        host.command(action); host.wait({"remove": "REMOVED", "disconnect": "DISCONNECTED"}[action])
                else:
                    for unused in range(6):
                        barrier(wire); host.tick(20)
                check(wait_state(host, 6) == 7, "short or stalled data transfer fails without reporting success")
                diagnostic(host, check, {"eof": "data socket closed before end of file", "reset": "data socket read failed",
                                         "timeout": "idle timeout", "detached-timeout": "idle timeout",
                                         "detached-remove": "messaging connection closed", "detached-disconnect": "account closed"}[interrupted])
                if not interrupted.startswith("detached-"):
                    check(host.state()[0] == 1, "failed file payload preserves messaging")
