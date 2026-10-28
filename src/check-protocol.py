#!/usr/bin/env python3
"""Exercise a real libpurple protocol host with isolated IPv6 stream fixtures."""
from pathlib import Path
import contextlib
import base64
import hashlib
import html
import os
import resource
import re
import selectors
import socket
import subprocess
import struct
import sys
import tempfile
import time
import zlib
import xml.etree.ElementTree as ET
from xml.sax.saxutils import quoteattr

build = Path(sys.argv[1]).resolve()
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
checks = 0
unit_counts = set()


def check(value, text):
    global checks
    if not value:
        raise AssertionError(text)
    checks += 1


for module in ["BarevAddress", "BarevStanzas", "BarevAvatar", "BarevStream", "TestBarev",
               "BarevFiles", "BarevFileStanzas", "BarevSocks", "BarevSHA1"]:
    text = (Path(__file__).resolve().parent / (module+".Mod")).read_text()
    text = re.sub(r"\(\*.*?\*\)", "", text, flags=re.S)
    imports = re.search(r"\bIMPORT\s+(.*?);", text, re.S).group(1)
    check(all(entry.split(":=")[-1].strip() != "SYSTEM" for entry in imports.split(",")),
          ("ordinary Oberon protocol boundary", module))


class Host:
    def __init__(self, port=9, production=False, failure=None, nick="alice", peer="bob@200::2", gio=False,
                 icon=None, icon_mode=None, converted_icon=None, peer_icon=None, peer_checksum=None):
        self.directory = tempfile.TemporaryDirectory(prefix="protocol-host-", dir=build)
        private = self.directory.name
        environment = dict(os.environ, HOME=private, XDG_CONFIG_HOME=private,
                           XDG_CACHE_HOME=private, XDG_DATA_HOME=private,
                           G_DEBUG="fatal-criticals")
        environment.pop("DBUS_SESSION_BUS_ADDRESS", None)
        environment.pop("BAREV_TEST_ICON_FILE", None)
        environment.pop("BAREV_TEST_PEER_ICON_FILE", None)
        environment.pop("BAREV_TEST_PEER_ICON_HASH", None)
        for key in ("BAREV_TEST_ICON_MODE", "BAREV_TEST_CONVERTED_ICON_FILE", "BAREV_TEST_PIDGIN_UI"):
            environment.pop(key, None)
        if icon is not None:
            path = Path(private) / "startup-icon.bin"
            path.write_bytes(icon)
            environment["BAREV_TEST_ICON_FILE"] = str(path)
        if peer_icon is not None:
            path = Path(private) / "peer-icon.bin"
            path.write_bytes(peer_icon)
            environment["BAREV_TEST_PEER_ICON_FILE"] = str(path)
        if peer_checksum is not None:
            environment["BAREV_TEST_PEER_ICON_HASH"] = peer_checksum
        if icon_mode:
            environment["BAREV_TEST_ICON_MODE"] = icon_mode
            if icon_mode == "global": environment["BAREV_TEST_PIDGIN_UI"] = "1"
        if converted_icon is not None:
            path = Path(private) / "converted-icon.bin"
            path.write_bytes(converted_icon)
            environment["BAREV_TEST_CONVERTED_ICON_FILE"] = str(path)
        self.error = tempfile.TemporaryFile(dir=build)
        library = "libvoc-barev.so" if production else "libvoc-barev-test.so"
        self.process = subprocess.Popen([str(build / "ProtocolHost"), str(build / library),
                                         private, str(port), "production" if production else failure or ("gio" if gio else "test"), nick, peer],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.error, env=environment, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.events = []
        try:
            if not production:
                units = self.wait("UNITS ")
                count = int(units.split()[1]); unit_counts.add(count)
                check(count > 0, ("Oberon unit checks", self.events))
            if production or failure:
                self.wait("ERROR ")
                self.port = 0
            else:
                self.port = int(self.wait("READY ").split()[1])
                check(self.port > 0, "isolated listener ready")
        except BaseException:
            self.close(failed=True)
            raise

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        self.close(failed=kind is not None)

    def wait(self, prefix, timeout=5):
        end = time.monotonic()+timeout
        while True:
            if b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                text = line.decode("utf-8", "replace")
                self.events.append(text)
                if text.startswith(prefix):
                    return text
                continue
            remaining = end-time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise AssertionError(("host event deadline", prefix, self.events))
            data = os.read(self.process.stdout.fileno(), 65536)
            if not data:
                self.error.seek(0)
                raise AssertionError(("host exited", self.process.poll(), self.events,
                                      self.error.read().decode("utf-8", "replace")))
            self.buffer += data

    def command(self, command):
        self.process.stdin.write((command+"\n").encode())
        self.process.stdin.flush()

    def state(self):
        self.command("state")
        return tuple(map(int, self.wait("STATE ").split()[1:]))

    def tick(self, seconds):
        self.command(f"tick {seconds}")
        self.wait("TICK")

    def wait_connections(self, count):
        deadline = time.monotonic()+5
        while self.state()[1] != count:
            if time.monotonic() >= deadline:
                raise AssertionError(("connection count deadline", count))
            time.sleep(0.01)

    def status(self, mode, message=""):
        encoded = base64.b64encode(message.encode()).decode()
        self.command(f"status {mode} {encoded}")
        self.wait("STATUS-SET")

    def buddy_status(self):
        self.command("buddy-status")
        parts = self.wait("STATUS ").split(maxsplit=2)
        return parts[1], base64.b64decode(parts[2]).decode() if len(parts) > 2 else ""

    def wait_status(self, mode, message=""):
        end = time.monotonic()+5
        while self.buddy_status() != (mode, message):
            if time.monotonic() >= end:
                raise AssertionError(("status deadline", mode, message))
            time.sleep(0.01)

    def send(self, message):
        encoded = base64.b64encode(message.encode()).decode()
        self.command(f"send {encoded}")
        return int(self.wait("SENT ").split()[1])

    def send_typing(self, mode):
        self.command(f"typing {mode}")
        return int(self.wait("TYPING-SENT ").split()[1])

    def typing(self):
        self.command("buddy-typing")
        return int(self.wait("TYPING-STATE ").split()[1])

    def wait_typing(self, mode):
        end = time.monotonic()+5
        while self.typing() != mode:
            if time.monotonic() >= end:
                raise AssertionError(("typing deadline", mode, self.events))
            time.sleep(0.01)

    def icon(self, data):
        self.command("icon "+base64.b64encode(data).decode())
        self.wait("ICON-SET")

    def avatar(self):
        self.command("buddy-avatar")
        _, hash, encoded = self.wait("ICON ").split()
        return (hash, base64.b64decode(encoded)) if hash != "-" else (None, None)

    def wait_avatar(self, data):
        expected = (hashlib.sha1(data).hexdigest(), data) if data else (None, None)
        end = time.monotonic()+5
        while self.avatar() != expected:
            if time.monotonic() >= end:
                raise AssertionError(("avatar deadline", expected[0], self.events))
            time.sleep(0.01)

    def close(self, failed=False):
        try:
            if self.process.poll() is None:
                self.command("quit")
            try:
                self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            tail = self.buffer+self.process.stdout.read()
            self.error.seek(0)
            errors = self.error.read().decode("utf-8", "replace")
            if not failed:
                check(self.process.returncode == 0, ("host exit", self.process.returncode, errors))
                check(b"CLOSED\n" in tail, "protocol shared object physically unmapped")
                check(b"CLEAN\n" in tail, "all native timer and socket sources released")
                check("CRITICAL" not in errors and "runtime error:" not in errors,
                      ("native diagnostics", errors))
        finally:
            self.selector.close()
            self.process.stdin.close()
            self.process.stdout.close()
            self.error.close()
            self.directory.cleanup()


class Wire:
    def __init__(self, sock):
        self.socket = sock
        self.socket.settimeout(5)
        self.buffer = b""

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.socket.close()

    def until(self, token):
        while token not in self.buffer:
            data = self.socket.recv(65536)
            if not data:
                raise AssertionError(("early socket EOF", token, self.buffer))
            self.buffer += data
        at = self.buffer.index(token)+len(token)
        result, self.buffer = self.buffer[:at], self.buffer[at:]
        return result

    def header(self, identity="alice@200::1"):
        data = self.until(b">")
        if data.startswith(b"<?xml"):
            data += self.until(b">")
        root = ET.fromstring(data+b"</stream:stream>")
        check(root.tag == "{http://etherx.jabber.org/streams}stream" and
              root.get("from") == identity, ("local stream identity", data))
        return data

    def send(self, data):
        self.socket.sendall(data.encode("utf-8") if isinstance(data, str) else data)

    def stanza(self):
        parser = ET.XMLPullParser(events=("start", "end"))
        parser.feed("<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client'>")
        list(parser.read_events())
        depth = 1
        while True:
            if not self.buffer:
                self.buffer = self.socket.recv(65536)
                if not self.buffer:
                    raise AssertionError("EOF while reading a stanza")
            byte, self.buffer = self.buffer[:1], self.buffer[1:]
            parser.feed(byte)
            if hasattr(parser, "flush"):
                parser.flush()
            for event, element in parser.read_events():
                if event == "start":
                    depth += 1
                else:
                    depth -= 1
                    if depth == 1:
                        return element

    def closed(self):
        try:
            while self.socket.recv(65536):
                pass
        except ConnectionResetError:
            pass


def opening(identity="bob@200::2", to="alice@200::1"):
    return ("<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client' "
            f"from={quoteattr(identity)} to={quoteattr(to)}>")


def incoming(host):
    return Wire(socket.create_connection(("::1", host.port), timeout=5))


def establish(host, wire, outgoing=False):
    if outgoing:
        wire.header()
    wire.send(opening())
    if not outgoing:
        wire.header()
    check(wire.stanza().tag == "{jabber:client}presence", "baseline presence for C Barev interoperability")
    host.wait("ONLINE")
    check(host.state()[0] == 1, "contact online after checked stream exchange")


@contextlib.contextmanager
def listener():
    sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    sock.bind(("::1", 0))
    sock.listen(16)
    sock.settimeout(8)
    try:
        yield sock
    finally:
        sock.close()


def file_checks():
    from file_tests import run
    run(Host, incoming, establish, check)


if "--files-only" in sys.argv[2:]:
    file_checks()
    print(f"Barev file-transfer checks passed: {checks}")
    sys.exit(0)

if "--file-backpressure" in sys.argv[2:]:
    from file_tests import backpressure
    backpressure(Host, incoming, establish, check)
    print(f"Barev file-transfer backpressure checks passed: {checks}")
    sys.exit(0)

if "--file-control-loss" in sys.argv[2:]:
    from file_tests import backpressure, receiving_control_loss
    backpressure(Host, incoming, establish, check, control_loss=True)
    receiving_control_loss(Host, incoming, establish, check)
    print(f"Barev file-transfer control-loss checks passed: {checks}")
    sys.exit(0)


for library, extra in [("libvoc-barev.so", set()), ("libvoc-barev-test.so", {"barev_protocol_test_api"})]:
    path = build / library
    exports = {line.split()[-1] for line in subprocess.check_output(
        ["nm", "-D", "--defined-only", str(path)], text=True).splitlines()}
    check(exports == {"purple_init_plugin", "g_module_check_init", "g_module_unload"} | extra,
          ("ELF protocol export boundary", library, exports))
    dynamic = subprocess.check_output(["readelf", "-d", str(path)], text=True)
    check("libvoc" not in dynamic and "TEXTREL" not in dynamic, "private runtime linkage")

with Host(production=True) as host:
    check(not any(event.startswith("READY ") for event in host.events), "production rejects non-Yggdrasil local IPv6")

for failure in ["fail-timer", "fail-input"]:
    with Host(failure=failure) as host:
        check(not any(event.startswith("READY ") for event in host.events), "listener/timer registration fails cleanly")

with Host() as host:
    host.command("fail-input")
    host.wait("ARMED")
    with incoming(host) as wire:
        wire.send(opening())
        wire.closed()
    check(host.state() == (0, 0), "read-watch registration failure closes the accepted socket")
    with incoming(host) as wire:
        establish(host, wire)

with Host() as host, incoming(host) as wire:
    establish(host, wire)
    host.command("can-unload")
    check(host.wait("UNLOAD ") == "UNLOAD 0", "active account refuses plugin unload")
    wire.send("</s:stream>")
    wire.closed()
    host.wait("OFFLINE")
    check(host.state()[0] == 0, "stream close marks offline")

with listener() as server, Host(server.getsockname()[1]) as host:
    with Wire(server.accept()[0]) as wire:
        establish(host, wire, outgoing=True)
    host.wait("OFFLINE")
    check(host.state()[0] == 0, "socket EOF marks offline")

rejections = [
    opening("bob@200::3"), opening("mallory@200::2"),
    opening(to="other@200::1"), opening("bob@::1"),
    "<s:stream xmlns:s='wrong' from='bob@200::2'>",
    "<s:stream xmlns:s='http://etherx.jabber.org/streams'>",
    "<!DOCTYPE stream [<!ENTITY x SYSTEM 'file:///fixture'>]><stream>",
    opening().replace("from=", "version='99' from="),
    opening().replace("bob@200", "bob@0200:0:0:0:0:0:0:2@200"),
    b"<s:stream xmlns:s='http://etherx.jabber.org/streams' from='\xc0\xaf@200::2'>",
    " "*4097,
]
for payload in rejections:
    with Host() as host, incoming(host) as wire:
        wire.send(payload)
        wire.closed()
        check(host.state()[0] == 0 and "ONLINE" not in host.events, "invalid incoming identity/XML stays offline")

with listener() as server, Host(server.getsockname()[1]) as host:
    with Wire(server.accept()[0]) as wire:
        wire.header()
        wire.send(opening("other@200::2"))
        wire.closed()
        check(host.state()[0] == 0 and "ONLINE" not in host.events, "outgoing connection pins expected contact")

with Host() as host, incoming(host) as wire:
    establish(host, wire)
    with incoming(host) as duplicate:
        duplicate.send(opening())
        duplicate.closed()
    check(host.state() == (1, 1), "first established stream survives a duplicate")
    for namespace in ["urn:xmpp:ping", "urn:yggb:ping"]:
        wire.send(f"<iq type='get' id='a&amp;b'><ping xmlns='{namespace}'/></iq>")
        response = wire.until(b"/>")
        reply = ET.fromstring(response)
        check(reply.get("type") == "result" and reply.get("id") == "a&b", "standard and legacy ping replies")
    host.tick(30)
    check(b"urn:xmpp:ping" in wire.until(b"</iq>"), "idle connection sends a liveness probe")
    wire.send("<iq type='result' id='1'/>")
    wire.send("<iq type='get' id='ping-check'><ping xmlns='urn:xmpp:ping'/></iq>"); wire.stanza()
    check(host.state()[0] == 1, "matching ping response keeps contact online")
    check("DEBUG Ping: received peer response" in host.events, "successful peer ping response is logged without an identity")
    host.tick(45)
    check(host.state()[0] == 0, "unanswered liveness probe expires")
    wire.closed()

with listener() as server, Host(server.getsockname()[1]) as host:
    with Wire(server.accept()[0]) as outgoing:
        outgoing.header()
        with incoming(host) as crossed:
            crossed.send(opening())
            crossed.closed()
        outgoing.send(opening())
        check(outgoing.stanza().tag == "{jabber:client}presence", "simultaneous connect retains deterministic pipe")
        host.wait("ONLINE")
        check(host.state() == (1, 1), "simultaneous connection converges")

for action in ["remove", "disconnect"]:
    with Host() as host, incoming(host) as wire:
        establish(host, wire)
        host.command(action)
        host.wait("REMOVED" if action == "remove" else "DISCONNECTED")
        wire.closed()
        check(host.state()[1] == 0, "contact removal/account disconnect removes socket watchers")
        if action == "disconnect":
            try:
                unexpected = socket.create_connection(("::1", host.port), timeout=2)
            except ConnectionRefusedError:
                check(True, "account disconnect closes its listener")
            else:
                unexpected.close()
                raise AssertionError("disconnected account retained a listener")

with Host() as host, incoming(host) as wire:
    host.command("reentrant")
    host.wait("ARMED")
    wire.send(opening())
    host.wait("ONLINE")
    wire.closed()
    check(host.state()[1] == 0, "disconnect from online notification is safe")

with Host() as host:
    host.command("fail-remove")
    host.wait("ARMED")
    host.command("disconnect")
    host.wait("DISCONNECTED")
    host.command("can-unload")
    check(host.wait("UNLOAD ") == "UNLOAD 0", "failed timer removal retains callback state")
    deadline = time.monotonic()+5
    while True:
        host.command("can-unload")
        if host.wait("UNLOAD ") == "UNLOAD 1":
            break
        if time.monotonic() >= deadline:
            raise AssertionError("closing timer did not retire")
        time.sleep(0.05)
    check(host.state()[1] == 0, "retired timer permits safe unload")

with Host() as host, incoming(host) as wire:
    host.wait_connections(1)
    host.tick(30)
    wire.closed()
    check(host.state()[0] == 0, "silent incoming stream deadline")

with Host() as host, incoming(host) as wire:
    establish(host, wire)
    wire.send("<message><body>"+"x"*131073)
    wire.closed()
    host.wait("OFFLINE")
    check("DEBUG Closing peer stream: invalid or oversized XML" in host.events,
          "parser failure is logged before the socket and protocol handle are discarded")
    check(host.state()[0] == 0, "stanza byte budget closes oversized input")

with Host(nick="Անի😀", peer="Բոբ😀@200::2") as host, incoming(host) as wire:
    wire.send(opening("Բոբ😀@0200:0:0:0:0:0:0:2", "Անի😀@200::1"))
    wire.header("Անի😀@200::1")
    wire.stanza()
    host.wait("ONLINE")
    check(host.state()[0] == 1, "UTF-8 identities reach libpurple availability callbacks")

with Host() as host:
    for cycle in range(3):
        with incoming(host) as wire:
            establish(host, wire)
            host.command("disconnect")
            host.wait("DISCONNECTED")
            wire.closed()
        check(host.state()[1] == 0, "account cycle releases sockets")
        host.command("reconnect")
        host.port = int(host.wait("READY ").split()[1])

client = "{jabber:client}"
with Host() as host, incoming(host) as wire:
    establish(host, wire)
    for show, mode, message in [("away", "away", "հեռու 😀 & <busy>"),
                                ("dnd", "dnd", "Do not disturb"),
                                ("xa", "xa", ""), ("chat", "available", "chatty"),
                                ("", "available", "")]:
        wire.send("<presence>"+(f"<show>{show}</show>" if show else "")+
                  f"<status>{html.escape(message)}</status></presence>")
        host.wait_status(mode, message)
        check(host.state()[0] == 1, "away/DND remain online on the same stream")
        wire.send("<iq type='get' id='keep'><ping xmlns='urn:xmpp:ping'/></iq>")
        check(wire.stanza().get("type") == "result", "presence stream still answers pings")
        check(host.buddy_status() == (mode, message), "ping does not reset explicit status or message")
    for mode, show in [("away", "away"), ("dnd", "dnd"), ("xa", "xa"), ("available", None)]:
        host.status(mode, "<b>կարգավիճակ 😀 &amp; text</b>")
        presence = wire.stanza()
        check(presence.tag == client+"presence", "local status callback emits presence")
        check(presence.findtext(client+"show") == show, "local away/DND wire state")
        check(presence.findtext(client+"status") == "կարգավիճակ 😀 & text", "local status text is plain UTF-8")
    payload = "բարեւ 😀 & <literal>\nsecond line"
    check(host.send(html.escape(payload)) > 0, "libpurple outgoing message accepted")
    message = wire.stanza()
    check(message.tag == client+"message" and message.get("type") == "chat", "outgoing chat stanza")
    check(message.findtext(client+"body") == payload, "outgoing UTF-8 body and XML escaping")
    payload = "literal <b>words</b> & <img src='fixture'>\nՀայերեն 😀"
    host.command("conv-send "+base64.b64encode(html.escape(payload).encode()).decode())
    host.wait("CONVERSATION-SENT")
    check(wire.stanza().findtext(client+"body") == payload, "conversation editor path preserves literal markup and UTF-8")
    payload = "Բարեւ 😀 & <img src='fixture'>"
    wire.send(f"<message type='chat'><body>{html.escape(payload)}</body>"
              "<html xmlns='http://jabber.org/protocol/xhtml-im'><body xmlns='http://www.w3.org/1999/xhtml'>ignored</body></html></message>")
    displayed = base64.b64decode(host.wait("MESSAGE ").split()[1]).decode()
    check(html.unescape(displayed) == payload, "incoming UTF-8 body reaches libpurple")
    check("<img" not in displayed, "wire text cannot inject UI markup")
    check(host.send("x"*8193) < 0, "oversized outgoing message fails explicitly")
    check(host.state()[0] == 1, "rejected user message leaves stream usable")

with Host() as host:
    check(host.send("offline") > 0, "offline peer message is accepted into the RAM queue")
    host.status("dnd", "busy before connection")
    with incoming(host) as wire:
        wire.send(opening()); wire.header()
        presence = wire.stanza(); host.wait("ONLINE")
        check(presence.findtext(client+"show") == "dnd", "first stream receives current local status")
        check(presence.findtext(client+"status") == "busy before connection", "initial status text retained")
        check(wire.stanza().findtext(client+"body") == "offline", "offline message drains after stream establishment")

with Host() as host:
    payloads = ["առաջին 😀 & <literal>", "second", "second"]
    for payload in payloads:
        check(host.send(html.escape(payload)) > 0, "offline FIFO accepts UTF-8 and repeated messages")
    payload = "conversation queue 😀"
    host.command("conv-send "+base64.b64encode(payload.encode()).decode())
    check(host.wait("QUEUED-NOTICE ") == "QUEUED-NOTICE 1", "conversation reports in-memory queueing without logging a delivery claim")
    host.wait("CONVERSATION-SENT")
    with incoming(host) as wire:
        establish(host, wire)
        for payload in [*payloads, payload]:
            check(wire.stanza().findtext(client+"body") == payload, "offline FIFO drains once and in original order")
        check(host.send("live after queue") > 0, "normal sending resumes after draining")
        check(wire.stanza().findtext(client+"body") == "live after queue", "live messages do not overtake the queue")
    host.wait_connections(0)
    check(host.send("after dropped stream") > 0, "stream loss returns subsequent messages to the contact queue")
    with incoming(host) as wire:
        establish(host, wire)
        check(wire.stanza().findtext(client+"body") == "after dropped stream", "queued messages survive replacement of the stream")

with listener() as server, Host(server.getsockname()[1]) as host:
    with Wire(server.accept()[0]) as wire:
        wire.header()
        check(host.send("during handshake") > 0, "in-progress connection does not prevent queueing")
        check(host.state()[0] == 0, "queueing does not mark an unfinished stream online")
    host.wait_connections(0)
    with incoming(host) as wire:
        establish(host, wire)
        check(wire.stanza().findtext(client+"body") == "during handshake", "failed handshake leaves its queued message intact")

with Host() as host:
    for index in range(16):
        check(host.send(f"queued {index}") > 0, "per-contact count budget accepts a bounded FIFO")
    check(host.send("overflow") < 0, "full pending queue rejects the extra message explicitly")
    check(host.send("x"*8193) < 0, "offline oversized messages are rejected before queueing")
    with incoming(host) as wire:
        establish(host, wire)
        for index in range(16):
            check(wire.stanza().findtext(client+"body") == f"queued {index}", "full FIFO drains without dropping an accepted message")
        check(host.send("after full queue") > 0, "draining releases the queue budget")
        check(wire.stanza().findtext(client+"body") == "after full queue", "rejected overflow never reaches the wire")

for action in ("remove", "disconnect"):
    with Host() as host:
        check(host.send("discard pending") > 0, "cleanup fixture has a pending message")
        host.command(action); host.wait("REMOVED" if action == "remove" else "DISCONNECTED")
        host.wait_connections(0)
        if action == "remove":
            check(host.send("unknown contact") < 0, "removed contacts cannot acquire another pending queue")
            host.command("add"); host.wait("ADDED")
        else:
            check(host.send("disconnected account") < 0, "disconnected accounts do not silently accept messages")
            host.command("reconnect"); host.port = int(host.wait("READY ").split()[1])
        with incoming(host) as wire:
            establish(host, wire)
            wire.send("<iq type='get' id='queue-cleared'><ping xmlns='urn:xmpp:ping'/></iq>")
            reply = wire.stanza()
            check(reply.tag == client+"iq" and reply.get("id") == "queue-cleared", "contact/account cleanup discards pending messages")

with Host() as host:
    with incoming(host) as wire:
        establish(host, wire)
        wire.send("<message><body>final before EOF</body></message>")
    check(base64.b64decode(host.wait("MESSAGE ").split()[1]).decode() == "final before EOF",
          "complete received message survives immediate socket EOF")

with Host() as host, incoming(host) as wire:
    establish(host, wire)
    host.command("reentrant-message"); host.wait("ARMED")
    wire.send("<message><body>disconnect safely</body></message>")
    host.wait("MESSAGE "); wire.closed()
    check(host.state()[1] == 0, "message-triggered disconnect on the next event-loop turn is safe")

for stanza in ["<message from='other@200::2'><body>spoofed</body></message>",
               "<message><body>one</body><body>two</body></message>",
               "<message><body><b>nested</b></body></message>",
               "<presence><show>away</show><show>dnd</show></presence>",
               "<presence><status>"+"x"*1025+"</status></presence>",
               "<message><body>"+"x"*8193+"</body></message>"]:
    with Host() as host, incoming(host) as wire:
        establish(host, wire)
        wire.send(stanza); wire.closed(); host.wait("OFFLINE")
        check(not any(event.startswith("MESSAGE ") for event in host.events), "invalid/oversized stanza has no UI message")

with listener() as server, Host(server.getsockname()[1], gio=True) as host:
    with Wire(server.accept()[0]) as wire:
        establish(host, wire, outgoing=True)
        wire.send("<presence><show>dnd</show><status>busy</status></presence>")
        host.wait_status("dnd", "busy")
        check(host.send("GIO &amp; channel 😀") > 0, "Pidgin-style GIOChannel outgoing message")
        check(wire.stanza().findtext(client+"body") == "GIO & channel 😀", "GIOChannel escaped message content")
        wire.send("<message><body>GIO reply 😀</body></message>")
        check(base64.b64decode(host.wait("MESSAGE ").split()[1]).decode() == "GIO reply 😀", "GIOChannel incoming message")
        host.status("away", "next turn")
        check(wire.stanza().findtext(client+"show") == "away", "GIOChannel status callback")
        host.command("disconnect"); host.wait("DISCONNECTED"); wire.closed()
        check(host.state()[1] == 0, "GIOChannel source removal and disconnect")

chatstates = "{http://jabber.org/protocol/chatstates}"
update_uri = "vcard-temp:x:update"
vcard_uri = "vcard-temp"


def png(width=1, height=1, color=b"\x11\x22\x33\xff", extra=b""):
    def chunk(tag, data):
        return struct.pack(">I", len(data))+tag+data+struct.pack(">I", zlib.crc32(tag+data))
    return (b"\x89PNG\r\n\x1a\n"+
            chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))+extra+
            chunk(b"IDAT", zlib.compress((b"\0"+color*width)*height))+chunk(b"IEND", b""))


def announce(hash):
    return f"<presence><x xmlns='{update_uri}'><photo>{hash}</photo></x></presence>"


def card(id, data, mime="image/png", encoded=None, kind="result"):
    binary = encoded if encoded is not None else base64.b64encode(data).decode()
    return (f"<iq type='{kind}' id={quoteattr(id)}><vCard xmlns='{vcard_uri}'>"
            f"<PHOTO><TYPE>{mime}</TYPE><BINVAL>{binary}</BINVAL></PHOTO></vCard></iq>")


def barrier(wire):
    wire.send("<iq type='get' id='barrier'><ping xmlns='urn:xmpp:ping'/></iq>")
    reply = wire.stanza()
    check(reply.get("type") == "result" and reply.get("id") == "barrier", "extension traffic leaves no stray output")


with Host() as host, incoming(host) as wire:
    establish(host, wire)
    for mode, element in [(1, "composing"), (2, "active"), (0, "active")]:
        refresh = host.send_typing(mode)
        message = wire.stanza()
        check(message.tag == client+"message" and message.get("type") == "chat", "outgoing chat state envelope")
        check(message.find(chatstates+element) is not None and message.find(client+"body") is None,
              "typing uses a bodyless interoperable chat state")
        check(refresh == (5 if mode == 1 else 0), "typing refresh interval")
    for element, state in [("composing", 1), ("paused", 2), ("active", 0),
                            ("composing", 1), ("inactive", 0), ("composing", 1), ("gone", 0)]:
        wire.send(f"<message type='chat'><{element} xmlns='http://jabber.org/protocol/chatstates'/></message>")
        host.wait_typing(state)
        check(host.state()[0] == 1, "chat state preserves contact connection")
    wire.send("<message><body>body and state 😀</body><composing xmlns='http://jabber.org/protocol/chatstates'/></message>")
    check(base64.b64decode(host.wait("MESSAGE ").split()[1]).decode() == "body and state 😀", "chat state does not suppress a message body")
    check(host.typing() == 1, "message can carry explicit composing state")
    wire.send("<message><body>plain body</body></message>"); host.wait("MESSAGE ")
    check(host.typing() == 0, "plain message clears stale typing")
    wire.send("<message><composing xmlns='urn:fixture:wrong'/></message>"); barrier(wire)
    check(host.typing() == 0, "foreign namespace cannot activate typing")
    wire.send("<message type='groupchat'><composing xmlns='http://jabber.org/protocol/chatstates'/></message>"); barrier(wire)
    check(host.typing() == 0, "groupchat state does not affect a direct conversation")
    wire.send("<message><composing xmlns='http://jabber.org/protocol/chatstates'/></message>"); host.wait_typing(1)
    host.tick(15); host.wait_typing(0)
    check(host.state()[0] == 1, "typing expiry does not disconnect a peer")

for element in ["<composing xmlns='http://jabber.org/protocol/chatstates'/><active xmlns='http://jabber.org/protocol/chatstates'/>",
                "<composing xmlns='http://jabber.org/protocol/chatstates'><x/></composing>"]:
    with Host() as host, incoming(host) as wire:
        establish(host, wire); wire.send(f"<message>{element}</message>"); wire.closed(); host.wait("OFFLINE")
        check(not any(event.startswith("MESSAGE ") for event in host.events), "malformed typing produces no message")

with Host() as host:
    check(host.send_typing(1) == 0, "offline typing is not queued")

for action in ["remove", "disconnect"]:
    with Host() as host, incoming(host) as wire:
        establish(host, wire); host.send_typing(1); wire.stanza()
        wire.send("<message><composing xmlns='http://jabber.org/protocol/chatstates'/></message>"); host.wait_typing(1)
        host.command(action); host.wait("REMOVED" if action == "remove" else "DISCONNECTED"); wire.closed()
        check(host.typing() == 0, "contact removal/account disconnect clears frontend typing without a timer")

image = png()
other_image = png(color=b"\xaa\xbb\xcc\xff")
image_hash = hashlib.sha1(image).hexdigest()
other_hash = hashlib.sha1(other_image).hexdigest()

# A 96px RGBA photo can exceed 32 KiB even within the C plugin's icon limits.
noise = hashlib.shake_256(b"Barev bounded avatar fixture").digest(96*96*4)
def png_chunk(tag, data):
    return struct.pack(">I", len(data))+tag+data+struct.pack(">I", zlib.crc32(tag+data))
large_image = (b"\x89PNG\r\n\x1a\n"+
               png_chunk(b"IHDR", struct.pack(">IIBBBBB", 96, 96, 8, 6, 0, 0, 0))+
               png_chunk(b"IDAT", zlib.compress(b"".join(b"\0"+noise[row*384:(row+1)*384] for row in range(96))))+
               png_chunk(b"IEND", b""))
check(32768 < len(large_image) < 65535, "legacy-compatible large avatar fixture")
with Host() as host, incoming(host) as wire:
    establish(host, wire)
    wire.send(announce(hashlib.sha1(large_image).hexdigest())); request = wire.stanza()
    wire.send(card(request.get("id"), large_image)); barrier(wire)
    host.wait_avatar(large_image)
    check(host.state()[0] == 1, "legacy-size avatar preserves the established stream")
    host.tick(30); ping = wire.stanza()
    check(ping.find("{urn:xmpp:ping}ping") is not None, "liveness still operates after a large vCard result")
    wire.send(f"<iq type='result' id={quoteattr(ping.get('id'))}/>"); barrier(wire)
    wire.send(announce(hashlib.sha1(large_image).hexdigest())); barrier(wire)
    check(host.state() == (1, 1) and host.events.count("ONLINE") == 1 and "OFFLINE" not in host.events,
          "large avatar and repeated presence do not cycle a healthy contact offline and online")

max_image = image[:-12]+png_chunk(b"tEXt", b"fixture\0"+b"x"*(65535-len(image)-20))+image[-12:]
check(len(max_image) == 65535, "exact legacy byte limit fixture")
with Host(gio=True, icon=max_image) as host:
    for cycle in range(3):
        with incoming(host) as wire:
            wire.send(opening()); wire.header(); presence = wire.stanza(); host.wait("ONLINE")
            check(presence.findtext(f"{{{update_uri}}}x/{{{update_uri}}}photo") == hashlib.sha1(max_image).hexdigest(),
                  "cached maximum-size icon survives account startup and reconnect")
            wire.send("<iq type='get' id='max-photo'><vCard xmlns='vcard-temp'/></iq>")
            reply = wire.stanza()
            check(reply.get("type") == "result" and reply.get("id") == "max-photo", "maximum photo response correlation")
            check(base64.b64decode(reply.findtext(f"{{{vcard_uri}}}vCard/{{{vcard_uri}}}PHOTO/{{{vcard_uri}}}BINVAL")) == max_image,
                  "maximum photo crosses the complete output queue and socket writer")
            wire.send(announce(hashlib.sha1(max_image).hexdigest()))
            if cycle == 0:
                request = wire.stanza()
                encoded = base64.b64encode(max_image).decode()
                wrapped = "\n".join(encoded[i:i+76] for i in range(0, len(encoded), 76))
                wire.send(card(request.get("id"), max_image, encoded=wrapped))
            barrier(wire)
            host.wait_avatar(max_image)
            check(host.send("message after maximum avatar") > 0, "maximum avatar preserves outgoing messaging")
            check(wire.stanza().findtext(client+"body") == "message after maximum avatar", "message after maximum avatar bytes")
            host.command("disconnect"); host.wait("DISCONNECTED"); wire.closed()
        if cycle < 2:
            host.command("reconnect"); host.port = int(host.wait("READY ").split()[1])

for unsupported in [b"not an image", max_image+b"x"]:
    with Host(icon=unsupported) as host, incoming(host) as wire:
        establish(host, wire)
        check(host.send("startup remains usable") > 0, "unsupported cached icon does not prevent account startup")
        check(wire.stanza().findtext(client+"body") == "startup remains usable", "messaging after ignored cached icon")

jpeg = base64.b64decode((Path(__file__).resolve().parent / "fixtures/avatar-jpeg.base64").read_text())

# Existing local and peer photos may retain their original pixel dimensions.
startup_photo = png(600, 600)
peer_photo = png(736, 736, color=b"\x55\x66\x77\xff")
changed_photo = png(400, 300, color=b"\x22\x44\x66\xff")
for mode in (None, "disk", "path", "global"):
    with Host(icon=startup_photo, icon_mode=mode, gio=True) as host, incoming(host) as wire:
        wire.send(opening()); wire.header(); presence = wire.stanza(); host.wait("ONLINE")
        check(presence.findtext(f"{{{update_uri}}}x/{{{update_uri}}}photo") == hashlib.sha1(startup_photo).hexdigest(),
              ("existing full-dimension avatar is advertised at startup", mode))
        wire.send("<iq type='get' id='existing-photo'><vCard xmlns='vcard-temp'/></iq>"); reply = wire.stanza()
        check(base64.b64decode(reply.findtext(f"{{{vcard_uri}}}vCard/{{{vcard_uri}}}PHOTO/{{{vcard_uri}}}BINVAL")) == startup_photo,
              "initial vCard serves existing avatar without reselection")
        for photo in (peer_photo, changed_photo):
            wire.send(announce(hashlib.sha1(photo).hexdigest())); host.tick(5)
            request = wire.stanza(); wire.send(card(request.get("id"), photo)); barrier(wire)
            host.wait_avatar(photo)
            check(host.avatar()[1] == photo, "initial and changed full-dimension peer avatars install exact bytes")
        check("DEBUG Avatar: received and checksum verified" in host.events,
              "avatar progress diagnostics report verified images without identifiers")
        check(host.state() == (1, 1), "full-dimension avatar exchange preserves the messaging stream")

with Host(icon=b"native original image"*5000, icon_mode="global", converted_icon=image) as host, incoming(host) as wire:
    wire.send(opening()); wire.header(); presence = wire.stanza(); host.wait("ONLINE")
    check("HOST-ICON-CONVERTED" in host.events, "configured Pidgin icon uses the host conversion boundary")
    check(presence.findtext(f"{{{update_uri}}}x/{{{update_uri}}}photo") == image_hash,
          "global avatar absent from account cache is converted before initial presence")

for dimensions in ((2048, 1), (1, 2048)):
    photo = png(*dimensions)
    with Host() as host, incoming(host) as wire:
        establish(host, wire); wire.send(announce(hashlib.sha1(photo).hexdigest())); request = wire.stanza()
        wire.send(card(request.get("id"), photo)); barrier(wire); host.wait_avatar(photo)
        check(host.avatar()[1] == photo, "inclusive avatar dimension limits")

with Host() as host, incoming(host) as wire:
    establish(host, wire)
    host.icon(jpeg); presence = wire.stanza()
    check(presence.findtext(f"{{{update_uri}}}x/{{{update_uri}}}photo") == hashlib.sha1(jpeg).hexdigest(), "local JPEG checksum")
    wire.send("<iq type='get' id='jpeg'><vCard xmlns='vcard-temp'/></iq>"); reply = wire.stanza()
    check(reply.findtext(f"{{{vcard_uri}}}vCard/{{{vcard_uri}}}PHOTO/{{{vcard_uri}}}TYPE") == "image/jpeg", "JPEG MIME sniffing")
    check(base64.b64decode(reply.findtext(f"{{{vcard_uri}}}vCard/{{{vcard_uri}}}PHOTO/{{{vcard_uri}}}BINVAL")) == jpeg, "JPEG binary output")
    wire.send(announce(hashlib.sha1(jpeg).hexdigest())); request = wire.stanza()
    wire.send(card(request.get("id"), jpeg, mime="image/jpeg")); host.wait_avatar(jpeg)
    check(host.avatar()[1] == jpeg, "incoming JPEG photo")

with Host() as host:
    host.icon(image)
    with incoming(host) as wire:
        wire.send(opening()); wire.header(); presence = wire.stanza(); host.wait("ONLINE")
        check(presence.findtext(f"{{{update_uri}}}x/{{{update_uri}}}photo") == image_hash,
              "initial presence advertises current account avatar")
        wire.send("<iq type='get' id='get-photo'><vCard xmlns='vcard-temp'/></iq>")
        reply = wire.stanza()
        check(reply.get("type") == "result" and reply.get("id") == "get-photo", "vCard response preserves IQ correlation")
        check(base64.b64decode(reply.findtext(f"{{{vcard_uri}}}vCard/{{{vcard_uri}}}PHOTO/{{{vcard_uri}}}BINVAL")) == image,
              "local vCard contains exact binary image bytes")
        check(reply.findtext(f"{{{vcard_uri}}}vCard/{{{vcard_uri}}}PHOTO/{{{vcard_uri}}}TYPE") == "image/png", "local vCard MIME type")
        host.status("dnd", "busy with an avatar"); presence = wire.stanza()
        check(presence.findtext(client+"show") == "dnd" and
              presence.findtext(f"{{{update_uri}}}x/{{{update_uri}}}photo") == image_hash, "status changes preserve avatar advertisement")
        host.icon(other_image); presence = wire.stanza()
        check(presence.findtext(client+"show") == "dnd" and presence.findtext(client+"status") == "busy with an avatar",
              "avatar changes preserve status state and text")
        check(presence.findtext(f"{{{update_uri}}}x/{{{update_uri}}}photo") == other_hash, "avatar changes advertise new checksum")
        host.icon(b""); presence = wire.stanza()
        check(presence.find(f"{{{update_uri}}}x/{{{update_uri}}}photo") is not None and
              not presence.findtext(f"{{{update_uri}}}x/{{{update_uri}}}photo"), "avatar removal is advertised explicitly")
        wire.send("<iq type='get' id='empty'><vCard xmlns='vcard-temp'/></iq>"); reply = wire.stanza()
        check(reply.find(f"{{{vcard_uri}}}vCard/{{{vcard_uri}}}PHOTO") is None, "removed local avatar has an empty vCard")

with Host(peer_icon=image) as host:
    for reconnect in [False, True]:
        if reconnect:
            host.command("disconnect"); host.wait("DISCONNECTED")
            host.command("reconnect"); host.port = int(host.wait("READY ").split()[1])
        with incoming(host) as wire:
            establish(host, wire)
            wire.send(announce(image_hash)); barrier(wire)
            check(host.avatar() == (image_hash, image), "validated peer disk cache avoids a redundant vCard fetch across login")
            check("DEBUG Peer avatar cache: validated" in host.events, "persistent peer image is validated before reuse")

for cached in [other_image, png(2049, 1), b""]:
    with Host(peer_icon=cached, peer_checksum=image_hash) as host, incoming(host) as wire:
        establish(host, wire); wire.send(announce(image_hash)); request = wire.stanza()
        check(request.find(f"{{{vcard_uri}}}vCard") is not None, "stale, invalid or empty cached bytes cannot substitute for the advertised avatar")
        wire.send(card(request.get("id"), image)); host.wait_avatar(image)

with Host() as host, incoming(host) as wire:
    establish(host, wire)
    wire.send(card("unsolicited", image)); barrier(wire)
    check(host.avatar() == (None, None), "unsolicited image result cannot install a buddy icon")
    wire.send(announce(image_hash.upper())); request = wire.stanza()
    check(request.get("type") == "get" and request.find(f"{{{vcard_uri}}}vCard") is not None, "avatar hash requests a vCard")
    wire.send(card("wrong-id", image)); barrier(wire)
    check(host.avatar() == (None, None), "wrong IQ ID cannot install a buddy icon")
    encoded = "\n ".join(base64.b64encode(image).decode()[i:i+16] for i in range(0, len(base64.b64encode(image)), 16))
    wire.send(card(request.get("id"), image, encoded=encoded)); host.wait_avatar(image)
    check(host.avatar() == (image_hash, image), "matching vCard installs checksum-verified binary image")
    wire.send("<presence><status>Hi &amp; &lt;hello&gt;</status></presence>"); barrier(wire)
    host.wait_status("available", "Hi & <hello>")
    host.command("get-info"); host.wait("INFO-END")
    entries = [event for event in host.events if event.startswith("INFO ")]
    check(any(event.startswith("INFO JID ") and base64.b64decode(event.split()[2]).decode() == "bob@200::2" for event in entries), "contact info shows identity")
    check(any(event.startswith("INFO Status ") and "Hi &amp; &lt;hello&gt;" in base64.b64decode(event.split()[2]).decode() for event in entries), "contact info escapes status text")
    check(any(event.startswith("INFO-IMAGE ") and base64.b64decode(event.split()[1]) == image for event in host.events), "contact info shows cached avatar")
    host.command("close-info"); host.wait("INFO-CLOSED")
    wire.send(announce(image_hash)); barrier(wire)
    check(host.avatar() == (image_hash, image), "unchanged avatar does not trigger another request")
    wire.send(f"<presence><x xmlns='{update_uri}'/></presence>"); barrier(wire)
    check(host.avatar() == (image_hash, image), "omitted photo leaves a known buddy icon unchanged")
    wire.send(announce("")); barrier(wire); host.wait_avatar(None)
    check(host.avatar() == (None, None), "empty photo explicitly clears buddy icon")
    before = len(host.events)
    host.command("get-info"); host.wait("INFO-END")
    check(not any(event.startswith("INFO-IMAGE ") for event in host.events[before:]), "contact info works without an avatar")
    host.command("close-info"); host.wait("INFO-CLOSED")
    wire.send(card(request.get("id"), image)); barrier(wire)
    check(host.avatar() == (None, None), "late response cannot undo avatar removal")
    host.tick(5)
    wire.send(announce(image_hash)); request = wire.stanza(); wire.send(card(request.get("id"), image)); host.wait_avatar(image)
    check(host.avatar() == (image_hash, image), "same image can be fetched again after explicit removal")

with Host() as host, incoming(host) as wire:
    establish(host, wire)
    wire.send(announce(image_hash)); first = wire.stanza()
    wire.send(announce(other_hash)); wire.send(card(first.get("id"), image)); barrier(wire)
    check(host.avatar() == (None, None), "superseded in-flight avatar result is ignored")
    host.tick(5); second = wire.stanza()
    check(second.get("type") == "get" and second.get("id") != first.get("id"), "latest avatar has a separate bounded request")
    wire.send(card(second.get("id"), other_image)); host.wait_avatar(other_image)
    check(host.avatar() == (other_hash, other_image), "latest announced avatar wins")

for result_kind in ["timeout", "error"]:
    with Host() as host, incoming(host) as wire:
        establish(host, wire); wire.send(announce(image_hash)); request = wire.stanza()
        if result_kind == "timeout":
            host.tick(15)
        else:
            wire.send(f"<iq type='error' id={quoteattr(request.get('id'))}/>")
        wire.send(card(request.get("id"), image)); wire.send(announce(image_hash)); barrier(wire)
        check(host.avatar() == (None, None), "retired avatar request ignores late responses without retry loops")
        check(host.send("messaging still works") > 0, "avatar failure leaves messaging available")
        check(wire.stanza().findtext(client+"body") == "messaging still works", "message after avatar failure")

oversized_jpeg = bytearray(jpeg)
sof = jpeg.index(b"\xff\xc0")
oversized_jpeg[sof+7:sof+9] = b"\x08\x01"
bad_images = [(png(2049, 1), "image/png", None), (bytes(oversized_jpeg), "image/jpeg", None),
              (png(extra=struct.pack(">I", 8)+b"acTL"+b"\0"*12), "image/png", None),
              (image, "image/jpeg", None), (image, "image/png", "Zh=="),
              (image, "image/png", base64.b64encode(b"x"*65536).decode()),
              (b"not an image", "image/png", None)]
for data, mime, encoded in bad_images:
    with Host() as host, incoming(host) as wire:
        establish(host, wire); wire.send(announce(hashlib.sha1(data).hexdigest())); request = wire.stanza()
        wire.send(card(request.get("id"), data, mime=mime, encoded=encoded)); barrier(wire)
        check(host.avatar() == (None, None), "invalid, animated, oversized or mislabeled photo is not installed")
        check("DEBUG Avatar: rejected vCard image: unsupported format, limits or malformed data" in host.events,
              "rejected optional image has an identity-free diagnostic")
        check(host.state()[0] == 1, "invalid optional photo leaves a healthy messaging stream")

with Host() as host, incoming(host) as wire:
    establish(host, wire); wire.send(announce("0"*40)); request = wire.stanza()
    wire.send(card(request.get("id"), image)); barrier(wire)
    check(host.avatar() == (None, None), "photo bytes must match the advertised SHA-1 checksum")

for extension in ["<photo>not-a-checksum</photo>", "<photo/><photo/>", "<photo><x/></photo>"]:
    with Host() as host, incoming(host) as wire:
        establish(host, wire); wire.send(f"<presence><x xmlns='{update_uri}'>{extension}</x></presence>")
        wire.closed(); host.wait("OFFLINE")
        check(host.avatar() == (None, None), "malformed photo announcement has no image side effect")

for feature in ["typing", "avatar"]:
    with Host(gio=True) as host, incoming(host) as wire:
        establish(host, wire); host.command(f"reentrant-{feature}"); host.wait("ARMED")
        if feature == "typing":
            wire.send("<message><composing xmlns='http://jabber.org/protocol/chatstates'/></message>"); host.wait("TYPING ")
        else:
            wire.send(announce(image_hash)); request = wire.stanza(); wire.send(card(request.get("id"), image)); host.wait("AVATAR-CHANGED")
        wire.closed(); check(host.state()[1] == 0, "extension-triggered disconnect releases GIOChannel sources")

file_checks()
check(len(unit_counts) == 1, "consistent Oberon unit count")
print(f"Barev Oberon address/stream checks passed: {next(iter(unit_counts))}")
print(f"Barev IPv6/libpurple protocol checks passed: {checks}")
