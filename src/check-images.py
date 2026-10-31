#!/usr/bin/env python3
"""Local BoB/IBB, libpurple preview, and C/Oberon interoperability checks."""
import base64
import contextlib
import ctypes as C
import fcntl
import hashlib
import os
from pathlib import Path
import struct
import time
import xml.etree.ElementTree as ET
from xml.sax.saxutils import quoteattr
import zlib

BOB = "urn:xmpp:bob"
IBB = "http://jabber.org/protocol/ibb"
SI = "http://jabber.org/protocol/si"
FILE = SI+"/profile/file-transfer"
FEATURE = "http://jabber.org/protocol/feature-neg"
FORM = "jabber:x:data"
XHTML = "http://www.w3.org/1999/xhtml"
CLIENT = "{jabber:client}"


def chunk(tag, data):
    return struct.pack(">I", len(data))+tag+data+struct.pack(">I", zlib.crc32(tag+data))


def png(width=1, height=1, padding=0):
    return (b"\x89PNG\r\n\x1a\n"+
            chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))+
            (chunk(b"tEXt", b"fixture\0"+b"x"*padding) if padding else b"")+
            chunk(b"IDAT", zlib.compress((b"\0"+b"\x11\x22\x33\xff"*width)*height))+
            chunk(b"IEND", b""))


def cid(data):
    return "sha1+"+hashlib.sha1(data).hexdigest()+"@bob.xmpp.org"


def message(data):
    return ("<message type='chat'><body>Picture</body><html xmlns='http://jabber.org/protocol/xhtml-im'>"
            f"<body xmlns='{XHTML}'><img src='cid:{cid(data)}'/></body></html></message>")


def bob_reply(request, data, content_id=None, mime="image/png"):
    return (f"<iq type='result' id={quoteattr(request.get('id'))}><data xmlns='{BOB}' "
            f"cid='{content_id or cid(data)}' type='{mime}'>{base64.b64encode(data).decode()}</data></iq>")


def offer(data):
    return (f"<iq type='set' id='offer'><si xmlns='{SI}' id='fixture' profile='{FILE}' mime-type='image/png'>"
            f"<file xmlns='{FILE}' name='original.png' size='{len(data)}'/>"
            f"<feature xmlns='{FEATURE}'><x xmlns='{FORM}' type='form'><field var='stream-method' type='list-single'>"
            f"<option><value>{IBB}</value></option></field></x></feature></si></iq>")


def ibb(kind, id, extra="", body=""):
    return f"<iq type='set' id='{id}'><{kind} xmlns='{IBB}' sid='fixture' {extra}>{body}</{kind}></iq>"


@contextlib.contextmanager
def file_ports():
    directory = Path(__file__).resolve().parents[1] / "build"
    directory.mkdir(exist_ok=True)
    with (directory / "file-tests.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


class CWire:
    """Driving the production C engine without sockets or a libpurple account."""
    class Event(C.Structure):
        _fields_ = [("token", C.c_int), ("kind", C.c_int), ("size", C.c_size_t),
                    ("name", C.c_char_p), ("caption", C.c_char_p),
                    ("data", C.c_void_p), ("blob", C.c_void_p)]

    def __init__(self, library, automatic=262144, bob=65536):
        self.lib = C.CDLL(str(library))
        signatures = {
            "barev_image_wire_new": (C.c_void_p, [C.c_int, C.c_int]),
            "barev_image_wire_send": (C.c_int, [C.c_void_p, C.c_char_p, C.c_size_t, C.c_char_p]),
            "barev_image_wire_receive": (C.c_int, [C.c_void_p, C.c_void_p]),
            "barev_image_wire_packet": (C.c_void_p, [C.c_void_p]),
            "barev_image_wire_event": (C.POINTER(self.Event), [C.c_void_p]),
            "barev_image_event_free": (None, [C.POINTER(self.Event)]),
            "barev_image_wire_free": (None, [C.c_void_p]),
            "barev_image_wire_memory": (C.c_size_t, []),
            "xmlnode_from_str": (C.c_void_p, [C.c_char_p, C.c_int]),
            "xmlnode_to_str": (C.c_void_p, [C.c_void_p, C.c_void_p]),
            "xmlnode_free": (None, [C.c_void_p]),
            "g_free": (None, [C.c_void_p]),
        }
        for name, (result, args) in signatures.items():
            function = getattr(self.lib, name)
            function.restype, function.argtypes = result, args
        self.context = self.lib.barev_image_wire_new(automatic, bob)

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.lib.barev_image_wire_free(self.context)
        assert self.lib.barev_image_wire_memory() == 0

    def send(self, data):
        return self.lib.barev_image_wire_send(self.context, data, len(data), b"original.png")

    def receive(self, element):
        raw = ET.tostring(element) if isinstance(element, ET.Element) else element.encode()
        node = self.lib.xmlnode_from_str(raw, len(raw))
        assert node
        try:
            return self.lib.barev_image_wire_receive(self.context, node)
        finally:
            self.lib.xmlnode_free(node)

    def packet(self):
        node = self.lib.barev_image_wire_packet(self.context)
        if not node:
            return None
        text = self.lib.xmlnode_to_str(node, None)
        try:
            return ET.fromstring(C.string_at(text))
        finally:
            self.lib.g_free(text)
            self.lib.xmlnode_free(node)

    def event(self):
        event = self.lib.barev_image_wire_event(self.context)
        if not event:
            return None
        try:
            e = event.contents
            return e.kind, C.string_at(e.data, e.size) if e.data else None
        finally:
            self.lib.barev_image_event_free(event)


def run(Host, incoming, establish, check, build):
    tiny = png()
    original = png(padding=280000)
    jpeg = base64.b64decode(Path(__file__).with_name("fixtures").joinpath("avatar-jpeg.base64").read_text())

    def preview(host):
        data = base64.b64decode(host.wait("IMAGE ").split()[1])
        check(data.startswith(b"\x89PNG"), "received preview uses local PNG image-store bytes")
        width, height = struct.unpack(">II", data[16:24])
        check(max(width, height) <= 640, "display preview is bounded to 640 pixels")
        return data

    def acknowledged(wire, packet):
        wire.send(packet)
        reply = wire.stanza()
        check(reply.get("type") == "result", ("IBB acknowledgement", ET.tostring(reply)))

    def transfer(wire, data, bad_sequence=False):
        acknowledged(wire, ibb("open", "open", "block-size='4096' stanza='iq'"))
        for seq, at in enumerate(range(0, len(data), 4096)):
            packet = ibb("data", f"d{seq}", f"seq='{seq+1 if bad_sequence else seq}'",
                         base64.b64encode(data[at:at+4096]).decode())
            if bad_sequence:
                wire.send(packet)
                check(wire.stanza().get("type") == "error", "out-of-sequence IBB data is rejected")
                return
            acknowledged(wire, packet)
        acknowledged(wire, ibb("close", "close"))

    with Host() as host, incoming(host) as wire:
        host.command("image-capability")
        check(host.wait("IMAGE-CAPABILITY ") == "IMAGE-CAPABILITY 1", "protocol advertises Pidgin's Insert Image capability")
        establish(host, wire)
        check(host.send_image(tiny) > 0, "native Send Image accepts PNG")
        stanza = wire.stanza()
        img = stanza.find(f"{{http://jabber.org/protocol/xhtml-im}}html/{{{XHTML}}}body/{{{XHTML}}}img")
        check(img is not None and img.get("src") == "cid:"+cid(tiny), "outgoing standard XHTML-IM BoB reference")
        wire.send(f"<iq type='get' id='bob'><data xmlns='{BOB}' cid='{cid(tiny)}'/></iq>")
        reply = wire.stanza().find(f"{{{BOB}}}data")
        check(reply is not None and base64.b64decode(reply.text) == tiny, "BoB preserves original bytes")
        incoming_image = png(2, 1)
        wire.send(message(incoming_image)); request = wire.stanza()
        check(request.find(f"{{{BOB}}}data").get("cid") == cid(incoming_image), "receiver retrieves a peer-scoped BoB object")
        wire.send(bob_reply(request, incoming_image)); preview(host)
        wire.send(message(incoming_image)); preview(host)
        wire.send("<message><body>after cached image</body></message>")
        check(base64.b64decode(host.wait("MESSAGE ").split()[1]) == b"after cached image", "cached delivery leaves text chat working")

    with Host() as host, incoming(host) as wire:
        establish(host, wire); wire.send(message(jpeg)); request = wire.stanza()
        wire.send(bob_reply(request, jpeg, mime="image/jpeg")); preview(host)
        check(host.send_image(jpeg) > 0, "native Send Image accepts JPEG")
        wire.stanza()
        wire.send(f"<iq type='get' id='jpeg'><data xmlns='{BOB}' cid='{cid(jpeg)}'/></iq>")
        reply = wire.stanza().find(f"{{{BOB}}}data")
        check(reply.get("type") == "image/jpeg" and base64.b64decode(reply.text) == jpeg, "JPEG BoB uses its validated MIME type and original bytes")

    for automatic, bad_sequence in [(256, False), (0, False), (0, True)]:
        data = png(padding=20000) if automatic else original
        with Host(image_auto=automatic) as host, incoming(host) as wire:
            establish(host, wire); wire.send(offer(data))
            if not automatic:
                host.wait("FILE-REQUEST")
                host.command("file-name")
                check(base64.b64decode(host.wait("FILE-NAME ").split()[1]) == b"original.png", "SI image filename survives the native boundary")
                host.command("file-accept"); host.wait("FILE-ACCEPTED")
            check(wire.stanza().get("type") == "result", "SI IBB offer accepted under receiver policy")
            try:
                transfer(wire, data, bad_sequence)
            except BaseException as error:
                host.error.seek(0)
                raise AssertionError((automatic, bad_sequence, host.events, host.error.read().decode())) from error
            if not bad_sequence:
                preview(host)
                if not automatic:
                    host.command("file-data")
                    check(base64.b64decode(host.wait("FILE-DATA ").split()[1]) == data, "accepted original saved byte-for-byte")

    with Host(image_auto=0) as host, incoming(host) as wire:
        establish(host, wire); wire.send(message(tiny)); host.wait("FILE-REQUEST")
        host.command("file-accept"); host.wait("FILE-ACCEPTED")
        wire.send(bob_reply(wire.stanza(), tiny)); preview(host)
        host.command("file-data")
        check(base64.b64decode(host.wait("FILE-DATA ").split()[1]) == tiny, "explicitly accepted BoB object is saved unchanged")

    with Host(image_bob=256) as host, incoming(host) as wire:
        establish(host, wire); data = png(padding=100000)
        check(host.send_image(data) > 0, "BoB supports objects larger than the avatar checksum limit")
        stanza = wire.stanza()
        img = stanza.find(f"{{http://jabber.org/protocol/xhtml-im}}html/{{{XHTML}}}body/{{{XHTML}}}img")
        check(img is not None and img.get("src") == "cid:"+cid(data), "large BoB content ID matches SHA-1")
        wire.send(f"<iq type='get' id='large-bob'><data xmlns='{BOB}' cid='{cid(data)}'/></iq>")
        check(base64.b64decode(wire.stanza().findtext(f"{{{BOB}}}data")) == data, "large BoB object retains every byte")

    with Host(image_auto=0) as host, incoming(host) as wire:
        establish(host, wire); wire.send(offer(original)); host.wait("FILE-REQUEST")
        host.command("file-reject"); host.wait("FILE-REJECTED")
        check(wire.stanza().get("type") == "error", "declining image rejects SI offer")

    for action in ("file-cancel", "remove", "disconnect", "reentrant-file", "reentrant-file-complete"):
        with Host(image_auto=0) as host, incoming(host) as wire:
            establish(host, wire)
            if action == "reentrant-file":
                host.command(action); host.wait("ARMED")
            wire.send(offer(original))
            if action == "reentrant-file":
                wire.closed()
                check(host.state()[1] == 0, "disconnect during image transfer creation releases streams")
                continue
            host.wait("FILE-REQUEST")
            host.command("file-accept"); host.wait("FILE-ACCEPTED"); wire.stanza()
            acknowledged(wire, ibb("open", "open", "block-size='4096' stanza='iq'"))
            if action == "reentrant-file-complete":
                host.command(action); host.wait("ARMED")
                for seq, at in enumerate(range(0, len(original), 4096)):
                    acknowledged(wire, ibb("data", f"d{seq}", f"seq='{seq}'", base64.b64encode(original[at:at+4096]).decode()))
                wire.send(ibb("close", "close")); wire.closed()
                check(host.state()[1] == 0, "disconnect during image completion releases streams")
            else:
                host.command(action); host.wait({"file-cancel": "FILE-CANCELED", "remove": "REMOVED", "disconnect": "DISCONNECTED"}[action])
                if action == "file-cancel":
                    check(wire.stanza().find(f"{{{IBB}}}close") is not None, "receiver cancellation closes the IBB session")
                    check(host.state()[0] == 1, "image cancellation preserves text connection")
                else:
                    wire.closed()

    for altered in (png(2, 2), b"not an image"):
        with Host() as host, incoming(host) as wire:
            establish(host, wire); wire.send(message(tiny)); request = wire.stanza()
            wire.send(bob_reply(request, altered, cid(tiny)))
            host.command("state"); host.wait("STATE ")
            check(not any(e.startswith("IMAGE ") for e in host.events), "mismatched or invalid BoB bytes have no preview")

    for logging in (False, True):
        with Host(image_logging=logging) as host, incoming(host) as wire:
            establish(host, wire); wire.send(message(tiny)); request = wire.stanza()
            wire.send(bob_reply(request, tiny)); rendered = preview(host)
            host.state()
            files = list(Path(host.directory.name).rglob("*.png"))
            check(any(path.read_bytes() == rendered for path in files) == logging,
                  "HTML logging persists previews only when logging is enabled")

    # Ordinary SI/SOCKS5 file transfers still preserve the accepted original and add a preview.
    import file_tests
    with file_ports(), Host() as host, incoming(host) as wire, file_tests.listener() as server:
        establish(host, wire)
        wire.send(file_tests.offer(name="picture.png", size=len(tiny))); host.wait("FILE-REQUEST")
        host.command("file-accept"); host.wait("FILE-ACCEPTED"); wire.stanza()
        wire.send(file_tests.host_query(server.getsockname()[1])); stream, unused = server.accept()
        with stream:
            stream.settimeout(5)
            file_tests.read_exact(stream, 3); stream.sendall(b"\x05\x00"); file_tests.read_exact(stream, 47)
            stream.sendall(b"\x05\x00\x00\x01"+b"\0"*6); wire.stanza(); stream.sendall(tiny)
            preview(host)
            check(file_tests.wait_state(host, 4) == len(tiny), "ordinary image file transfer completes")
            host.command("file-data")
            check(base64.b64decode(host.wait("FILE-DATA ").split()[1]) == tiny, "ordinary Send File preserves original image")

    for choice in (0, 1, 2):
        with Host() as host, incoming(host) as wire:
            establish(host, wire); data = png(1600, 800)
            check(host.send_image(data) > 0, "large-dimension image enters resize choice")
            host.command(f"image-choice {choice}"); host.wait("IMAGE-CHOSEN")
            if choice == 2:
                continue
            stanza = wire.stanza()
            img = stanza.find(f"{{http://jabber.org/protocol/xhtml-im}}html/{{{XHTML}}}body/{{{XHTML}}}img")
            check(img is not None, "fitted and compressible original image use BoB")
            content_id = img.get("src")[4:]
            wire.send(f"<iq type='get' id='copy'><data xmlns='{BOB}' cid='{content_id}'/></iq>")
            sent = base64.b64decode(wire.stanza().findtext(f"{{{BOB}}}data"))
            check(sent == data if choice == 1 else max(struct.unpack(">II", sent[16:24])) <= 1280,
                  "original choice preserves bytes; fit choice bounds dimensions")
            check((Path(host.directory.name)/"image-input.png").read_bytes() == data, "resizing leaves sender file unchanged")

    with Host(image_bob=1) as host, incoming(host) as wire:
        establish(host, wire)
        check(host.send_image(png(padding=20000)) > 0, "native sender starts IBB transfer")
        wire.stanza()
        if "FILE-NEW 1" not in host.events:
            host.wait("FILE-NEW 1")
        check("FILE-NEW 1" in host.events, "outgoing IBB exposes a cancellable transfer")
        host.command("file-cancel"); host.wait("FILE-CANCELED")
        check(wire.stanza().find(f"{{{IBB}}}close") is not None, "sender cancellation closes IBB session")
        check(host.state()[0] == 1, "sender cancellation preserves text connection")

    library = os.environ.get("BAREV_C_IMAGE_LIBRARY")
    if library:
        for data in (tiny, png(padding=20000), jpeg):
            # Both directions use the production C protocol engine and the checked Oberon stream.
            with Host(image_bob=1) as host, incoming(host) as wire, CWire(library, bob=1024) as c:
                establish(host, wire)
                check(c.send(data) > 0, "C sender queues image")
                for _ in range(1000):
                    packet = c.packet()
                    if packet is None:
                        break
                    wire.send(ET.tostring(packet))
                    if packet.tag == "iq" and packet.get("type") == "result":
                        continue
                    check(c.receive(wire.stanza()), "C sender handles checked Oberon response")
                else:
                    raise AssertionError("C/Oberon transfer did not finish")
                preview(host)
                while c.event() is not None:
                    pass
                check(host.send_image(data) > 0, "Oberon sender queues image")
                check(c.receive(wire.stanza()), "C receives Oberon image announcement")
                events = []
                for _ in range(1000):
                    packet = c.packet()
                    while (event := c.event()) is not None:
                        events.append(event)
                    if packet is not None:
                        wire.send(ET.tostring(packet))
                    if (2, data) in events:
                        break
                    check(packet is not None, "C receiver produces a request or acknowledgement")
                    check(c.receive(wire.stanza()), "C receiver handles checked Oberon packets")
                check((2, data) in events, "C receives the exact Oberon image bytes")
