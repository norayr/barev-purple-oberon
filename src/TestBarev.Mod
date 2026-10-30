MODULE TestBarev;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Offline address, identity, stream-selection and lifecycle regressions. *)

IMPORT A := BarevAddress, B := BarevStream, St := BarevStanzas, Av := BarevAvatar,
  Items := XmppItems, T := XmppTypes, Gen := XmppXmlGen, Msg, LS := LongStrings, Heap, Out,
  Files := BarevFiles, FS := BarevFileStanzas, Socks := BarevSocks, NetworkTests := TestNetwork,
  MarkupTests := TestMarkup;

VAR checks, firstBad: LONGINT;
  phase: ARRAY 32 OF CHAR;

PROCEDURE Check(value: BOOLEAN);
BEGIN
  INC(checks);
  IF ~value & (firstBad = 0) THEN
    firstBad := checks; Out.String("Barev check failed in "); Out.String(phase);
    Out.String(": "); Out.Int(checks, 0); Out.Ln
  END
END Check;

PROCEDURE Receive(handle: LONGINT; text: ARRAY OF CHAR): LONGINT;
  VAR bytes: ARRAY 8192 OF CHAR;
BEGIN COPY(text, bytes); RETURN B.Feed(handle, bytes, LS.Length8(bytes)) END Receive;

PROCEDURE Drain(handle: LONGINT);
  VAR bytes: ARRAY 4096 OF CHAR; n, limit: LONGINT;
BEGIN
  limit := 0; n := B.Peek(handle, bytes);
  WHILE (n > 0) & (limit < 128) DO B.Sent(handle, n); n := B.Peek(handle, bytes); INC(limit) END;
  Check(limit < 128)
END Drain;

PROCEDURE Contains(bytes, part: ARRAY OF CHAR): BOOLEAN;
  VAR at, index, n, m: LONGINT;
BEGIN
  n := LS.Length8(bytes); m := LS.Length8(part);
  FOR at := 0 TO n-m DO
    index := 0; WHILE (index < m) & (bytes[at+index] = part[index]) DO INC(index) END;
    IF index = m THEN RETURN TRUE END
  END;
  RETURN FALSE
END Contains;

PROCEDURE Addresses;
  VAR ip, other: A.IP; text: ARRAY 384 OF CHAR; seed, sample, index: LONGINT;
BEGIN
  Check(A.ParseIP("200::1", ip) & A.Yggdrasil(ip));
  Check(A.ParseIP("0200:0000:0000:0000:0000:0000:0000:0001", other) & A.Equal(ip, other));
  Check(A.Format(ip, text) & (text = "200::1"));
  Check(A.ParseIP("200:1::a:b", ip)); Check(A.Format(ip, text) & (text = "200:1::a:b"));
  Check(A.ParseIP("2ff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", ip) & A.Yggdrasil(ip));
  Check(A.ParseIP("300::1", ip) & A.Yggdrasil(ip));
  Check(A.ParseIP("3ff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", ip) & A.Yggdrasil(ip));
  Check(A.ParseIP("400::1", ip) & ~A.Yggdrasil(ip));
  Check(A.ParseIP("1ff::1", ip) & ~A.Yggdrasil(ip));
  Check(A.ParseIP("::1", ip) & ~A.Yggdrasil(ip));
  Check(A.ParseIP("::", ip) & ~A.Yggdrasil(ip));
  Check(~A.ParseIP("200:::1", ip)); Check(~A.ParseIP("200::1::2", ip));
  Check(~A.ParseIP("200:1:2:3:4:5:6", ip)); Check(~A.ParseIP("200:1:2:3:4:5:6:7:8", ip));
  Check(~A.ParseIP("200:1:2:3:4:5:6:7::", ip)); Check(~A.ParseIP("200:00000::1", ip));
  Check(~A.ParseIP("[200::1]", ip)); Check(~A.ParseIP("200::1%ygg0", ip));
  Check(~A.ParseIP("::ffff:127.0.0.1", ip)); Check(~A.ParseIP("200::g", ip));
  Check(~A.ParseIP("200::1 ", ip)); Check(~A.ParseIP("200::1:", ip));
  Check(A.Identity("Անի@0200::ABCD", text, ip));
  Check(text = "Անի@200::abcd");
  Check(A.Identity("alice😀@300::1", text, ip));
  Check(~A.Identity("alice@::1", text, ip));
  Check(~A.Identity("alice@200::1/resource", text, ip));
  Check(~A.Identity("alice@200::1%eth0", text, ip));
  Check(~A.Identity("a@b@200::1", text, ip));
  Check(~A.Identity("a b@200::1", text, ip));
  Check(~A.Identity("@200::1", text, ip));
  Check(~A.Identity("alice@example.invalid", text, ip));
  Check(A.ParseIP("::", ip) & A.Format(ip, text) & (text = "::"));
  Check(A.ParseIP("200::", ip) & A.Format(ip, text) & (text = "200::"));
  Check(A.ParseIP("200:0:0:1:0:0:2:3", ip) & A.Format(ip, text) & (text = "200::1:0:0:2:3"));
  Check(A.ParseIP("200:0:1:2:3:4:5:6", ip) & A.Format(ip, text) & (text = "200:0:1:2:3:4:5:6"));
  Check(A.Before("Alice@200::1", "bob@200::2"));
  Check(~A.Before("bob@200::2", "Alice@200::1"));
  Check(A.Before("Alice@200::1", "alice@200::1"));
  Check(~A.Before("alice@200::1", "Alice@200::1"));
  Check(~A.Before("alice@200::1", "alice@200::1"));
  seed := 17;
  FOR sample := 0 TO 255 DO
    FOR index := 0 TO 15 DO
      seed := (seed*25173+13849) MOD 65536;
      IF sample MOD 3 = 0 THEN ip[index] := 0X ELSE ip[index] := CHR(seed DIV 256) END
    END;
    ip[sample MOD 16] := CHR(sample);
    Check(A.Format(ip, text) & A.ParseIP(text, other) & A.Equal(ip, other))
  END
END Addresses;

PROCEDURE Peer(account, contact: LONGINT): LONGINT;
  VAR handle: LONGINT;
BEGIN
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1"); Check(handle > 0);
  Drain(handle);
  Check(Receive(handle, "<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client' from='bob@200::2' to='alice@200::1'>") = B.online);
  Drain(handle); RETURN handle
END Peer;

PROCEDURE Rejected(header: ARRAY OF CHAR);
  VAR account, contact, handle: LONGINT;
BEGIN
  account := B.NewAccount("alice", "200::1"); contact := B.AddContact(account, "bob@200::2");
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1"); Drain(handle);
  Check(Receive(handle, header) = B.failed); Check(~B.ContactOnline(account, contact));
  B.Drop(handle); B.FreeAccount(account)
END Rejected;

PROCEDURE Headers;
  VAR account, contact, handle, index, result: LONGINT; bytes: ARRAY 4097 OF CHAR;
    header: ARRAY 256 OF CHAR; single: ARRAY 1 OF CHAR;
BEGIN
  Rejected("<s:stream xmlns:s='http://etherx.jabber.org/streams' from='bob@200::3'>");
  Rejected("<s:stream xmlns:s='http://etherx.jabber.org/streams' from='mallory@200::2'>");
  Rejected("<s:stream xmlns:s='http://etherx.jabber.org/streams' from='bob@200::2' to='other@200::1'>");
  Rejected("<s:stream xmlns:s='http://etherx.jabber.org/streams' from='bob@200::2' to='alice@200::9'>");
  Rejected("<s:stream xmlns:s='http://etherx.jabber.org/streams' from='bob@::1'>");
  Rejected("<s:stream xmlns:s='http://etherx.jabber.org/streams'>");
  Rejected("<s:stream xmlns:s='wrong' from='bob@200::2'>");
  Rejected("<s:stream xmlns:s='http://etherx.jabber.org/streams' from='bob@200::2' version='9.9'>");
  Rejected("<s:stream xmlns:s='http://etherx.jabber.org/streams' from='bob@200::2' from='bob@200::2'>");
  Rejected("<!DOCTYPE stream [<!ENTITY x SYSTEM 'file:///fixture'>]><stream>");
  Rejected("<s:stream xmlns:s='http://etherx.jabber.org/streams' from='bob@200::2'/>");
  account := B.NewAccount("alice", "200::1"); contact := B.AddContact(account, "bob@200::2");
  Check(B.NewConnection(account, contact, FALSE, "200::3", "200::1") = 0);
  Check(B.NewConnection(account, contact, FALSE, "200::2", "200::9") = 0);
  Check(B.NewConnection(account, 0, TRUE, "::1", "200::1") = 0);
  Check(B.NewConnection(account, 0, TRUE, "200::9", "200::1") = 0);
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1"); Drain(handle);
  header := "<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client' from='bob@0200:0:0:0:0:0:0:2' to='alice@200::1'>";
  FOR index := 0 TO LS.Length8(header)-1 DO
    single[0] := header[index]; result := B.Feed(handle, single, 1);
    IF index < LS.Length8(header)-1 THEN Check(result = B.pending) ELSE Check(result = B.online) END
  END;
  Heap.GC(TRUE); Check(B.ContactOnline(account, contact));
  B.Drop(handle); Check(~B.ContactOnline(account, contact));
  Check(B.State(handle) = B.failed);
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1");
  FOR index := 0 TO 4096 DO bytes[index] := " " END;
  Check(B.Feed(handle, bytes, 4097) = B.failed);
  B.Drop(handle); B.FreeAccount(account)
END Headers;

PROCEDURE Selection;
  VAR account, contact, first, duplicate, incoming, index: LONGINT;
BEGIN
  account := B.NewAccount("alice", "200::1"); contact := B.AddContact(account, "bob@200::2");
  first := Peer(account, contact);
  Check(B.NewConnection(account, contact, FALSE, "200::2", "200::1") = 0);
  duplicate := B.NewConnection(account, 0, TRUE, "200::2", "200::1");
  Check(Receive(duplicate, "<s:stream xmlns:s='http://etherx.jabber.org/streams' from='bob@200::2'>") = B.failed);
  B.Drop(duplicate); Check(B.ContactOnline(account, contact)); Check(B.State(first) = B.online);
  B.Drop(first);
  first := B.NewConnection(account, contact, FALSE, "200::2", "200::1");
  incoming := B.NewConnection(account, 0, TRUE, "200::2", "200::1");
  Check(Receive(incoming, "<s:stream xmlns:s='http://etherx.jabber.org/streams' from='bob@200::2'>") = B.failed);
  B.Drop(incoming); Check(B.State(first) = B.pending);
  Drain(first); Check(Receive(first, "<s:stream xmlns:s='http://etherx.jabber.org/streams' from='bob@200::2'>") = B.online);
  B.Drop(first); B.FreeAccount(account);
  account := B.NewAccount("zoe", "200::1"); contact := B.AddContact(account, "bob@200::2");
  first := B.NewConnection(account, contact, FALSE, "200::2", "200::1");
  incoming := B.NewConnection(account, 0, TRUE, "200::2", "200::1");
  Check(Receive(incoming, "<s:stream xmlns:s='http://etherx.jabber.org/streams' from='bob@200::2' to='zoe@200::1'>") = B.pending);
  Check(B.State(first) = B.failed); Drain(incoming); Check(B.State(incoming) = B.online);
  B.Drop(first); Check(B.ContactOnline(account, contact));
  B.Drop(incoming); Check(~B.ContactOnline(account, contact));
  FOR index := 1 TO 16 DO
    incoming := B.NewConnection(account, contact, FALSE, "200::2", "200::1");
    Check(incoming # first); Check(B.State(first) = B.failed); B.Drop(incoming)
  END;
  B.FreeAccount(account)
END Selection;

PROCEDURE Packets;
  VAR account, contact, handle, index, length: LONGINT; bytes: ARRAY 4097 OF CHAR;
BEGIN
  account := B.NewAccount("alice", "200::1"); contact := B.AddContact(account, "bob@200::2");
  handle := Peer(account, contact);
  phase := "custom ping";
  Check(Receive(handle, "<iq type='get' id='a&amp;b'><ping xmlns='urn:yggb:ping'/></iq>") = B.online);
  length := B.Peek(handle, bytes); bytes[length] := 0X;
  Check(Contains(bytes, "result") & Contains(bytes, "a&amp;b")); Drain(handle);
  FOR index := 1 TO 30 DO B.Tick(account) END;
  phase := "outgoing ping";
  length := B.Peek(handle, bytes); bytes[length] := 0X; Check(Contains(bytes, "urn:xmpp:ping")); Drain(handle);
  Check(Receive(handle, "<iq type='result' id='1'/>") = B.online);
  Check(B.TakePingReply(account)); Check(~B.TakePingReply(account));
  phase := "ping response";
  FOR index := 1 TO 29 DO B.Tick(account) END;
  Check(B.State(handle) = B.online);
  FOR index := 1 TO 16 DO B.Tick(account) END;
  phase := "ping deadline";
  Check(B.State(handle) = B.failed); B.Drop(handle); Check(~B.ContactOnline(account, contact));
  phase := "spoofed from";
  handle := Peer(account, contact);
  Check(Receive(handle, "<presence from='bob@200::3'/>") = B.failed); B.Drop(handle);
  phase := "spoofed to";
  handle := Peer(account, contact);
  Check(Receive(handle, "<presence to='other@200::1'/>") = B.failed); B.Drop(handle);
  phase := "unavailable";
  handle := Peer(account, contact);
  Check(Receive(handle, "<presence type='unavailable'/>") = B.failed); B.Drop(handle);
  phase := "stream error";
  handle := Peer(account, contact);
  Check(Receive(handle, "<s:error xmlns:s='http://etherx.jabber.org/streams'/>") = B.failed); B.Drop(handle);
  phase := "stream close";
  handle := Peer(account, contact);
  Check(Receive(handle, "</s:stream>") = B.failed); B.Drop(handle);
  phase := "malformed stanza";
  handle := Peer(account, contact);
  Check(Receive(handle, "<message><x/></wrong>") = B.failed); B.Drop(handle);
  phase := "header timeout";
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1");
  FOR index := 1 TO 30 DO B.Tick(account) END;
  Check(B.State(handle) = B.failed); B.Drop(handle);
  handle := Peer(account, contact); B.RemoveContact(account, contact);
  Check(B.State(handle) = B.failed); Check(~B.ContactOnline(account, contact));
  B.FreeAccount(account)
END Packets;

PROCEDURE Bounds;
  VAR account, previous, contact, handle, index: LONGINT;
    held: ARRAY B.maxAccounts OF LONGINT;
    pipes: ARRAY 4 OF LONGINT;
    name: ARRAY 64 OF CHAR; bytes: ARRAY 8 OF CHAR;
BEGIN
  account := B.NewAccount("alice", "200::1"); previous := account;
  contact := B.AddContact(account, "bob@200::2");
  Check(B.AddContact(account, "bob@0200::2") = contact);
  FOR index := 0 TO 3 DO
    pipes[index] := B.NewConnection(account, 0, TRUE, "200::2", "200::1"); Check(pipes[index] > 0)
  END;
  Check(B.NewConnection(account, 0, TRUE, "200::2", "200::1") = 0);
  B.FreeAccount(account);
  FOR index := 0 TO 3 DO Check(B.State(pipes[index]) = B.failed) END;
  FOR index := 0 TO B.maxAccounts-1 DO
    held[index] := B.NewAccount("alice", "200::1"); Check(held[index] > 0)
  END;
  Check(B.NewAccount("alice", "200::1") = 0);
  Check(B.AddContact(previous, "bob@200::2") = 0);
  B.FreeAccount(previous);
  account := held[0]; contact := B.AddContact(account, "bob@200::2"); Check(contact = 1);
  FOR index := 1 TO B.maxAccounts-1 DO B.FreeAccount(held[index]) END;
  FOR index := 1 TO B.maxContacts-1 DO
    name := "peerxx@200::2"; name[4] := CHR(ORD("a")+index DIV 26); name[5] := CHR(ORD("a")+index MOD 26);
    Check(B.AddContact(account, name) > 0)
  END;
  Check(B.AddContact(account, "overflow@200::2") = 0);
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1"); Check(handle > 0);
  Check(B.Feed(handle, bytes, -1) = B.failed); B.Drop(handle);
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1");
  Check(B.Feed(handle, bytes, LEN(bytes)+1) = B.failed); B.Drop(handle);
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1");
  B.Sent(handle, -1); Check(B.State(handle) = B.failed); B.Drop(handle);
  B.FreeAccount(account)
END Bounds;

PROCEDURE StatusMessages;
  VAR account, contact, handle, index, length, result: LONGINT;
    text: ARRAY 1025 OF CHAR; bytes: ARRAY 32769 OF CHAR;
    jid: ARRAY 384 OF CHAR; body: ARRAY 8194 OF CHAR; small: ARRAY 2 OF CHAR;
BEGIN
  account := B.NewAccount("alice", "200::1"); contact := B.AddContact(account, "bob@200::2");
  Check(B.SetStatus(account, St.dnd, "զբաղուած 😀 & <busy>"));
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1"); Drain(handle);
  Check(Receive(handle, "<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client' from='bob@200::2'>") = B.online);
  length := B.Peek(handle, bytes); bytes[length] := 0X;
  Check(Contains(bytes, ">dnd</show>") & Contains(bytes, "&amp;") & Contains(bytes, "&lt;busy&gt;")); Drain(handle);
  Check(B.ContactStatus(account, contact, text) = St.available); Check(text = "");
  Check(Receive(handle, "<presence><show>away</show><status>հեռու 😀 &amp; &lt;b&gt;</status></presence>") = B.online);
  Check(B.ContactStatus(account, contact, text) = St.away); Check(text = "հեռու 😀 & <b>");
  Check(Receive(handle, "<iq type='get' id='alive'><ping xmlns='urn:xmpp:ping'/></iq>") = B.online);
  Check(B.ContactStatus(account, contact, text) = St.away); Check(text = "հեռու 😀 & <b>"); Drain(handle);
  Check(Receive(handle, "<presence><show>dnd</show><status>busy</status></presence>") = B.online);
  Check(B.ContactStatus(account, contact, text) = St.dnd); Check(text = "busy");
  Check(Receive(handle, "<presence><show>xa</show></presence>") = B.online);
  Check(B.ContactStatus(account, contact, text) = St.extendedAway); Check(text = "");
  Check(Receive(handle, "<presence><show>chat</show></presence>") = B.online);
  Check(B.ContactStatus(account, contact, text) = St.chat);
  Check(Receive(handle, "<presence/>") = B.online);
  Check(B.ContactStatus(account, contact, text) = St.available); Check(text = "");
  Check(B.SetStatus(account, St.away, "gone"));
  length := B.Peek(handle, bytes); bytes[length] := 0X; Check(Contains(bytes, ">away</show>")); Drain(handle);
  Check(B.SetStatus(account, St.available, "")); Drain(handle);
  Check(~B.SetStatus(account, -1, "invalid"));
  small[0] := 1X; small[1] := 0X; Check(~B.SetStatus(account, St.available, small));
  Check(B.SendMessage(account, contact, small) = B.invalidText);
  Check(B.SendMessage(account, contact, "") = B.invalidText);
  Check(B.SendMessage(account, contact, "բարեւ 😀 & <b>literal</b>") = B.online);
  length := B.Peek(handle, bytes); bytes[length] := 0X;
  Check(Contains(bytes, ">բարեւ 😀 &amp; &lt;b&gt;literal&lt;/b&gt;</body>")); Drain(handle);
  Check(Receive(handle, "<message type='chat'><body>բարեւ 😀 &amp; &lt;img src='fixture'&gt;</body><html xmlns='http://jabber.org/protocol/xhtml-im'/></message>") = B.online);
  Check(~B.TakeMessage(account, small, body));
  Heap.GC(TRUE); Check(B.TakeMessage(account, jid, body));
  Check(jid = "bob@200::2"); Check(body = "բարեւ 😀 & <img src='fixture'>");
  Check(~B.TakeMessage(account, jid, body));
  Check(Receive(handle, "<message><body xmlns='urn:fixture:foreign'>ignored</body></message>") = B.online);
  Check(~B.TakeMessage(account, jid, body));
  Check(Receive(handle, "<message type='groupchat'><body>ignored</body></message>") = B.online);
  Check(~B.TakeMessage(account, jid, body));
  Check(Receive(handle, "<message><body>before close</body></message>") = B.online);
  B.Drop(handle); Check(B.TakeMessage(account, jid, body) & (body = "before close"));
  Check(B.SendMessage(account, contact, "offline") = B.queued);
  handle := Peer(account, contact);
  FOR index := 0 TO St.maxMessageBytes DO body[index] := "x" END; body[St.maxMessageBytes+1] := 0X;
  Check(B.SendMessage(account, contact, body) = B.invalidText);
  body[1024] := 0X; index := 0; result := B.online;
  WHILE (index < 400) & (result = B.online) DO result := B.SendMessage(account, contact, body); INC(index) END;
  Check(result = B.outputFull); Check(index < 400); Check(B.State(handle) = B.online); Drain(handle);
  Check(B.SendMessage(account, contact, "after draining") = B.online); Drain(handle);
  Check(Receive(handle, "<message><body>stale</body></message>") = B.online);
  B.RemoveContact(account, contact); contact := B.AddContact(account, "bob@200::2");
  Check(~B.TakeMessage(account, jid, body));
  handle := Peer(account, contact);
  FOR index := 1 TO B.maxMessages DO Check(Receive(handle, "<message><body>queued</body></message>") = B.online) END;
  Check(Receive(handle, "<message><body>overflow</body></message>") = B.failed);
  B.Drop(handle); B.FreeAccount(account);
  account := B.NewAccount("alice", "200::1"); contact := B.AddContact(account, "bob@200::2");
  handle := B.NewConnection(account, 0, TRUE, "200::2", "200::1");
  Check(Receive(handle, "<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client' from='bob@200::2'><presence><show>dnd</show></presence>") = B.pending);
  Drain(handle); Check(B.ContactStatus(account, contact, text) = St.dnd);
  Check(Receive(handle, "<message><body>one</body><body>two</body></message>") = B.failed);
  B.Drop(handle); handle := Peer(account, contact);
  Check(Receive(handle, "<presence><show>away</show><show>dnd</show></presence>") = B.failed);
  B.Drop(handle); B.FreeAccount(account)
END StatusMessages;

PROCEDURE QueuedPeer(account, contact: LONGINT): LONGINT;
  VAR handle: LONGINT;
BEGIN
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1"); Check(handle > 0);
  Drain(handle);
  Check(Receive(handle, "<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client' from='bob@200::2' to='alice@200::1'>") = B.online);
  RETURN handle
END QueuedPeer;

PROCEDURE MessageQueue;
  VAR account, other, contact, handle, length, index, result, count, previous: LONGINT;
    contacts: ARRAY 5 OF LONGINT; counts: ARRAY 5 OF LONGINT;
    bytes: ARRAY 65537 OF CHAR; body: ARRAY St.maxMessageBytes+2 OF CHAR;
    letter: ARRAY 2 OF CHAR; expected: ARRAY 32 OF CHAR;
BEGIN
  account := B.NewAccount("alice", "200::1"); contact := B.AddContact(account, "bob@200::2");
  Check(B.SendMessage(0, contact, "unknown") = B.failed);
  Check(B.SendMessage(account, 0, "unknown") = B.failed);
  Check(B.SendMessage(account, contact+1, "unknown") = B.failed);
  Check(B.SendMessage(account, contact, "") = B.invalidText);
  body[0] := 1X; body[1] := 0X; Check(B.SendMessage(account, contact, body) = B.invalidText);
  FOR index := 0 TO St.maxMessageBytes DO body[index] := "x" END; body[St.maxMessageBytes+1] := 0X;
  Check(B.SendMessage(account, contact, body) = B.invalidText);
  Check(B.SendMessage(account, contact, "առաջին 😀 & <one>") = B.queued);
  Check(B.SendMessage(account, contact, "second") = B.queued);
  Check(~B.ContactOnline(account, contact)); Heap.GC(TRUE);
  phase := "queue handshake retry";
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1");
  length := B.Peek(handle, bytes); bytes[length] := 0X;
  Check(~Contains(bytes, "</body>")); Drain(handle); B.Lost(handle);
  handle := QueuedPeer(account, contact);
  length := B.Peek(handle, bytes); bytes[length] := 0X;
  Check(Contains(bytes, "առաջին 😀 &amp; &lt;one&gt;</body>"));
  Check(~Contains(bytes, ">second</body>"));
  Check(B.Peek(handle, bytes) = length);
  B.Sent(handle, length-1); Check(B.Peek(handle, bytes) = 1); B.Lost(handle);
  phase := "queue partial write retry";
  Heap.GC(TRUE); handle := QueuedPeer(account, contact);
  length := B.Peek(handle, bytes); bytes[length] := 0X;
  Check(Contains(bytes, "առաջին 😀 &amp; &lt;one&gt;</body>"));
  Check(B.SendMessage(account, contact, "third") = B.queued);
  B.Sent(handle, length);
  length := B.Peek(handle, bytes); bytes[length] := 0X;
  Check(Contains(bytes, ">second</body>") & ~Contains(bytes, ">third</body>")); B.Sent(handle, length);
  length := B.Peek(handle, bytes); bytes[length] := 0X;
  Check(Contains(bytes, ">third</body>")); B.Sent(handle, length);
  Check(B.Peek(handle, bytes) = 0);
  Check(B.SendMessage(account, contact, "live") = B.online); Drain(handle);
  phase := "queue cleanup";
  B.Drop(handle);
  Check(B.SendMessage(account, contact, "discard with contact") = B.queued);
  B.RemoveContact(account, contact); Check(B.SendMessage(account, contact, "removed") = B.failed);
  contact := B.AddContact(account, "bob@200::2"); handle := QueuedPeer(account, contact);
  length := B.Peek(handle, bytes); bytes[length] := 0X; Check(~Contains(bytes, "</body>")); Drain(handle);
  B.Drop(handle); Check(B.SendMessage(account, contact, "discard with account") = B.queued);
  previous := account; B.FreeAccount(account); Heap.GC(TRUE);
  account := B.NewAccount("alice", "200::1"); contact := B.AddContact(account, "bob@200::2");
  Check(account # previous); Check(B.SendMessage(previous, contact, "stale account") = B.failed);
  handle := QueuedPeer(account, contact);
  length := B.Peek(handle, bytes); bytes[length] := 0X; Check(~Contains(bytes, "</body>")); Drain(handle);
  B.Drop(handle);

  (* An incoming connection must finish its local header before draining. *)
  phase := "queue incoming stream";
  Check(B.SendMessage(account, contact, "incoming") = B.queued);
  handle := B.NewConnection(account, 0, TRUE, "200::2", "200::1");
  Check(Receive(handle, "<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client' from='bob@200::2'>") = B.pending);
  length := B.Peek(handle, bytes); bytes[length] := 0X; Check(~Contains(bytes, "</body>"));
  B.Sent(handle, length);
  length := B.Peek(handle, bytes); bytes[length] := 0X; Check(Contains(bytes, ">incoming</body>"));
  B.Sent(handle, length); Check(B.Peek(handle, bytes) = 0); B.Drop(handle);

  letter[1] := 0X;
  phase := "queue count budget";
  FOR index := 0 TO B.maxPendingMessages-1 DO
    letter[0] := CHR(ORD("A")+index); Check(B.SendMessage(account, contact, letter) = B.queued)
  END;
  Check(B.SendMessage(account, contact, "overflow") = B.outputFull); Heap.GC(TRUE);
  handle := QueuedPeer(account, contact);
  FOR index := 0 TO B.maxPendingMessages-1 DO
    length := B.Peek(handle, bytes); bytes[length] := 0X;
    expected := ">A</body>"; expected[1] := CHR(ORD("A")+index); Check(Contains(bytes, expected));
    B.Sent(handle, length)
  END;
  Check(B.Peek(handle, bytes) = 0); B.Drop(handle);
  FOR index := 1 TO B.maxPendingMessages DO Check(B.SendMessage(account, contact, "reusing count budget") = B.queued) END;
  B.RemoveContact(account, contact); B.FreeAccount(account);

  account := B.NewAccount("alice", "200::1");
  contacts[0] := B.AddContact(account, "bob@200::2"); contacts[1] := B.AddContact(account, "carol@200::2");
  phase := "queue byte budgets";
  contacts[2] := B.AddContact(account, "dave@200::2"); contacts[3] := B.AddContact(account, "eve@200::2");
  contacts[4] := B.AddContact(account, "fred@200::2");
  FOR index := 0 TO St.maxMessageBytes-1 DO body[index] := "x" END; body[St.maxMessageBytes] := 0X;
  FOR index := 0 TO 4 DO
    count := 0; result := B.queued;
    WHILE (count <= B.maxPendingMessages) & (result = B.queued) DO
      result := B.SendMessage(account, contacts[index], body);
      IF result = B.queued THEN INC(count) END
    END;
    Check(result = B.outputFull); counts[index] := count;
    Check(count < B.maxPendingMessages)
  END;
  Check(counts[0] > 0); Check(counts[1] = counts[0]); Check(counts[4] < counts[0]);
  phase := "queue byte cleanup";
  other := B.NewAccount("alice", "200::1"); contact := B.AddContact(other, "bob@200::2");
  Check(B.SendMessage(other, contact, body) = B.queued); B.FreeAccount(other);
  B.RemoveContact(account, contacts[0]);
  Check(B.SendMessage(account, contacts[4], body) = B.queued);
  FOR index := 1 TO 4 DO B.RemoveContact(account, contacts[index]) END;
  contact := B.AddContact(account, "bob@200::2");
  FOR index := 1 TO counts[0] DO Check(B.SendMessage(account, contact, body) = B.queued) END;
  handle := QueuedPeer(account, contact);
  FOR index := 1 TO counts[0] DO
    phase := "queue large stanza drain";
    length := B.Peek(handle, bytes); bytes[length] := 0X;
    Check(Contains(bytes, ">xxxx")); B.Sent(handle, length)
  END;
  Check(B.Peek(handle, bytes) = 0); B.Drop(handle);
  FOR index := 1 TO counts[0] DO Check(B.SendMessage(account, contact, body) = B.queued) END;
  B.FreeAccount(account)
END MessageQueue;

PROCEDURE TypingChecks;
  VAR account, contact, handle, i, length: LONGINT; bytes: ARRAY 2048 OF CHAR;
BEGIN
  account := B.NewAccount("alice", "200::1"); contact := B.AddContact(account, "bob@200::2"); handle := Peer(account, contact);
  Check(B.SendTyping(account, contact, St.composing) = B.online);
  length := B.Peek(handle, bytes); bytes[length] := 0X; Check(Contains(bytes, "composing") & Contains(bytes, St.chatstatesURI)); Drain(handle);
  Check(B.SendTyping(account, contact, St.stopped) = B.online);
  length := B.Peek(handle, bytes); bytes[length] := 0X; Check(Contains(bytes, "active")); Drain(handle);
  Check(B.SendTyping(account, contact, 99) = B.invalidText);
  Check(Receive(handle, "<message><composing xmlns='http://jabber.org/protocol/chatstates'/></message>") = B.online);
  Check(B.ContactTyping(account, contact) = St.composing);
  FOR i := 1 TO St.typingSeconds-1 DO B.Tick(account) END; Check(B.ContactTyping(account, contact) = St.composing);
  B.Tick(account); Check(B.ContactTyping(account, contact) = St.stopped);
  Check(Receive(handle, "<message><paused xmlns='http://jabber.org/protocol/chatstates'/></message>") = B.online);
  Check(B.ContactTyping(account, contact) = St.paused);
  Check(Receive(handle, "<message><active xmlns='http://jabber.org/protocol/chatstates'/></message>") = B.online);
  Check(B.ContactTyping(account, contact) = St.stopped);
  Check(Receive(handle, "<message><body>text plus state</body><composing xmlns='http://jabber.org/protocol/chatstates'/></message>") = B.online);
  Check(B.ContactTyping(account, contact) = St.composing);
  Check(Receive(handle, "<message><body>plain text stops typing</body></message>") = B.online);
  Check(B.ContactTyping(account, contact) = St.stopped);
  Check(Receive(handle, "<message><composing xmlns='urn:fixture:wrong'/></message>") = B.online);
  Check(B.ContactTyping(account, contact) = St.stopped);
  Check(Receive(handle, "<message><composing xmlns='http://jabber.org/protocol/chatstates'/><active xmlns='http://jabber.org/protocol/chatstates'/></message>") = B.failed);
  B.Drop(handle); Check(B.ContactTyping(account, contact) = St.stopped);
  Check(B.SendTyping(account, contact, St.composing) = B.failed); B.FreeAccount(account)
END TypingChecks;

PROCEDURE AvatarBytes;
  VAR bytes: ARRAY Av.maxBytes+1 OF CHAR; i, length, size: LONGINT; text, raw, hash: Items.Bytes;
    image, decoded: Av.Image; item: Items.Item; id: T.String;
BEGIN
  FOR i := 0 TO LEN(bytes)-1 DO bytes[i] := CHR(i MOD 256) END;
  hash := Av.Hash(bytes, 0); Check(hash^ = "da39a3ee5e6b4b0d3255bfef95601890afd80709");
  hash := Av.Hash("abc", 3); Check(hash^ = "a9993e364706816aba3e25717850c26c9cd0d89d");
  hash := Av.Hash(bytes, 55); Check(hash^ = "8ae2d46729cfe68ff927af5eec9c7d1b66d65ac2");
  hash := Av.Hash(bytes, 56); Check(hash^ = "636e2ec698dac903498e648bd2f3af641d3c88cb");
  hash := Av.Hash(bytes, 63); Check(hash^ = "6d942da0c4392b123528f2905c713a3ce28364bd");
  hash := Av.Hash(bytes, 64); Check(hash^ = "c6138d514ffa2135bfce0ed0b8fac65669917ec7");
  hash := Av.Hash(bytes, 65); Check(hash^ = "69bd728ad6e13cd76ff19751fde427b00e395746");
  hash := Av.Hash(bytes, 16384); Check(hash^ = "80cb9c430d80c3084649f65e0ca25dabbffb1b62");
  hash := Av.Hash(bytes, Av.maxBytes); Check(hash^ = "03f4023e02eaad6aea7df22f42464d0060d87dd2");
  Check(Av.Hash(bytes, -1) = NIL); Check(Av.Hash(bytes, Av.maxBytes+1) = NIL);
  FOR size := 0 TO 128 DO
    text := Av.Encode(bytes, size); raw := Av.Decode(text^, length); Check((raw # NIL) & (length = size));
    FOR i := 0 TO size-1 DO Check(raw[i] = bytes[i]) END
  END;
  text := Av.Encode(bytes, Av.maxBytes); raw := Av.Decode(text^, length);
  Check((raw # NIL) & (length = Av.maxBytes)); FOR i := 0 TO length-1 DO Check(raw[i] = bytes[i]) END;
  Check(Av.Decode("Zg=", length) = NIL); Check(Av.Decode("Z===", length) = NIL);
  Check(Av.Decode("Zh==", length) = NIL); Check(Av.Decode("Zm9=", length) = NIL);
  Check(Av.Decode("Zg==AAAA", length) = NIL); Check(Av.Decode("!!!!", length) = NIL);
  Check(Av.Decode("=g==", length) = NIL); Check(Av.Decode("Zg=A", length) = NIL);
  raw := Av.Decode(" Z g = = ", length); Check((raw # NIL) & (length = 1) & (raw[0] = "f"));
  raw := Av.Decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQVDL+DwACFAFmBODefwAAAABJRU5ErkJggg==", length);
  image := Av.New(raw^, length); Check(image # NIL);
  Check((image.hash^ = "44f27add009ef062ec66d85284b1158049748940") & (image.mime^ = "image/png"));
  id := Items.Latin1("fixture"); item := Av.Card(image, id); Check(Av.ReadCard(item, decoded));
  Check((decoded # NIL) & (decoded.hash^ = image.hash^) & (decoded.length = image.length));
  FOR i := 0 TO length-1 DO Check(Av.New(raw^, i) = NIL) END;
  raw[18] := 9X; Check(Av.New(raw^, length) = NIL); raw[18] := 0X;
  Check(Av.New(raw^, 33) = NIL); Check(Av.New(raw^, length-1) = NIL);
  raw[37] := "a"; raw[38] := "c"; raw[39] := "T"; raw[40] := "L"; Check(Av.New(raw^, length) = NIL)
END AvatarBytes;

PROCEDURE AvatarStreams;
  VAR account, contact, handle, length, size, i: LONGINT; raw: Items.Bytes;
    bytes: ARRAY 4096 OF CHAR; data: ARRAY Av.maxBytes OF CHAR; jid: ARRAY 384 OF CHAR; hash: ARRAY 41 OF CHAR;
    small: ARRAY 1 OF CHAR;
BEGIN
  raw := Av.Decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQVDL+DwACFAFmBODefwAAAABJRU5ErkJggg==", size);
  account := B.NewAccount("alice", "200::1"); contact := B.AddContact(account, "bob@200::2"); handle := Peer(account, contact);
  Check(B.SetAvatar(account, raw^, size)); length := B.Peek(handle, bytes); bytes[length] := 0X;
  Check(Contains(bytes, Av.updateURI) & Contains(bytes, "44f27add009ef062ec66d85284b1158049748940")); Drain(handle);
  Check(Receive(handle, "<iq type='get' id='photo'><vCard xmlns='vcard-temp'/></iq>") = B.online);
  length := B.Peek(handle, bytes); bytes[length] := 0X;
  Check(Contains(bytes, "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQVDL+DwACFAFmBODefwAAAABJRU5ErkJggg==")); Drain(handle);
  phase := "avatar request";
  Check(Receive(handle, "<presence><x xmlns='vcard-temp:x:update'><photo>44f27add009ef062ec66d85284b1158049748940</photo></x></presence>") = B.online);
  length := B.Peek(handle, bytes); bytes[length] := 0X; Check(Contains(bytes, "a1") & Contains(bytes, Av.vcardURI)); Drain(handle);
  Check(Receive(handle, "<iq type='result' id='unsolicited'><vCard xmlns='vcard-temp'/></iq>") = B.online);
  Check(~B.TakeAvatar(account, jid, data, hash, length));
  phase := "avatar result";
  Check(Receive(handle, "<iq type='result' id='a1'><vCard xmlns='vcard-temp'><PHOTO><TYPE>image/png</TYPE><BINVAL>iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQVDL+DwACFAFmBODefwAAAABJRU5ErkJggg==</BINVAL></PHOTO></vCard></iq>") = B.online);
  Check(~B.TakeAvatar(account, jid, small, hash, length)); Heap.GC(TRUE);
  Check(B.TakeAvatar(account, jid, data, hash, length) & (length = size));
  Check((jid = "bob@200::2") & (hash = "44f27add009ef062ec66d85284b1158049748940"));
  FOR i := 0 TO length-1 DO Check(data[i] = raw[i]) END;
  Check(Receive(handle, "<presence><x xmlns='vcard-temp:x:update'><photo>44f27add009ef062ec66d85284b1158049748940</photo></x></presence>") = B.online);
  Check(B.Peek(handle, bytes) = 0);
  phase := "avatar removal";
  Check(Receive(handle, "<presence><x xmlns='vcard-temp:x:update'><photo/></x></presence>") = B.online);
  Check(B.TakeAvatar(account, jid, data, hash, length) & (length = 0) & (hash = ""));
  FOR i := 1 TO 5 DO B.Tick(account) END;
  Check(Receive(handle, "<presence><x xmlns='vcard-temp:x:update'><photo>44f27add009ef062ec66d85284b1158049748940</photo></x></presence>") = B.online); Drain(handle);
  phase := "avatar timeout";
  FOR i := 1 TO Av.requestSeconds DO B.Tick(account) END;
  Check(Receive(handle, "<iq type='result' id='a2'><vCard xmlns='vcard-temp'><PHOTO><BINVAL>iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQVDL+DwACFAFmBODefwAAAABJRU5ErkJggg==</BINVAL></PHOTO></vCard></iq>") = B.online);
  Check(~B.TakeAvatar(account, jid, data, hash, length)); Check(B.Peek(handle, bytes) = 0);
  Check(~B.SetAvatar(account, "invalid", 7)); Check(B.SetAvatar(account, "", 0)); Drain(handle);
  B.Drop(handle); B.FreeAccount(account)
END AvatarStreams;

PROCEDURE Encoded(handle: LONGINT; item: Items.Item): LONGINT;
  VAR encoded: Items.Bytes; chunk: ARRAY 4096 OF CHAR; length, at, count, i, result: LONGINT; error: Msg.Msg;
BEGIN
  Gen.Encode(item, B.maxStanzaBytes, encoded, length, error); Check(error = NIL);
  IF error # NIL THEN RETURN B.failed END;
  at := 0; result := B.online;
  WHILE (at < length) & (result >= 0) DO
    count := length-at; IF count > LEN(chunk) THEN count := LEN(chunk) END;
    FOR i := 0 TO count-1 DO chunk[i] := encoded[at+i] END;
    result := B.Feed(handle, chunk, count); INC(at, count)
  END;
  RETURN result
END Encoded;

PROCEDURE Remote(account, contact: LONGINT; jid, ip: ARRAY OF CHAR): LONGINT;
  VAR handle, length: LONGINT; bytes: Items.Bytes; to, from, empty: T.String; error: Msg.Msg;
BEGIN
  handle := B.NewConnection(account, contact, FALSE, ip, "200::1"); Check(handle # 0); Drain(handle);
  to := Items.Latin1("alice@200::1"); from := Items.Latin1(jid); empty := Items.Latin1("");
  Gen.OpenStream(to^, from^, empty^, empty^, bytes, length, error); Check(error = NIL);
  Check(B.Feed(handle, bytes^, length) = B.online); Drain(handle); RETURN handle
END Remote;

PROCEDURE AvatarBudget;
  VAR raw: Items.Bytes; image: Av.Image; bytes: ARRAY Av.maxBytes OF CHAR; small: ARRAY 1 OF CHAR;
    contacts, handles: ARRAY 5 OF LONGINT; jid: ARRAY 384 OF CHAR; ip: ARRAY 40 OF CHAR;
    hash: ARRAY 41 OF CHAR; account, size, count, index, i, at: LONGINT; item: Items.Item; id: T.String;
BEGIN
  raw := Av.Decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQVDL+DwACFAFmBODefwAAAABJRU5ErkJggg==", size);
  at := size-12; count := Av.maxBytes-size-12;
  FOR i := 0 TO LEN(bytes)-1 DO bytes[i] := 0X END;
  FOR i := 0 TO at-1 DO bytes[i] := raw[i] END;
  bytes[at] := 0X; bytes[at+1] := 0X; bytes[at+2] := CHR(count DIV 256); bytes[at+3] := CHR(count MOD 256);
  bytes[at+4] := "t"; bytes[at+5] := "E"; bytes[at+6] := "X"; bytes[at+7] := "t";
  FOR i := 0 TO 11 DO bytes[Av.maxBytes-12+i] := raw[size-12+i] END;
  image := Av.New(bytes, Av.maxBytes); Check(image # NIL);
  account := B.NewAccount("alice", "200::1"); id := Items.Latin1("a1");
  FOR index := 0 TO 4 DO
    COPY("bob@200::2", jid); jid[9] := CHR(ORD("2")+index);
    COPY("200::2", ip); ip[5] := jid[9];
    contacts[index] := B.AddContact(account, jid); handles[index] := Remote(account, contacts[index], jid, ip);
    item := St.Presence(St.available, ""); Av.Advertise(item, image);
    Check(Encoded(handles[index], item) = B.online); Drain(handles[index]);
    item := Av.Card(image, id);
    Check(Encoded(handles[index], item) = B.online);
    Check(B.ContactOnline(account, contacts[index]))
  END;
  Check(~B.TakeAvatar(account, jid, small, hash, size)); Heap.GC(TRUE);
  Check(B.TakeAvatar(account, jid, bytes, hash, size) & (size = Av.maxBytes));
  Check(jid = "bob@200::2");
  B.RemoveContact(account, contacts[1]); B.Drop(handles[4]);
  handles[4] := Remote(account, contacts[4], "bob@200::6", "200::6"); Drain(handles[4]);
  Check(Encoded(handles[4], Av.Card(image, id)) = B.online);
  B.RemoveContact(account, contacts[2]); B.RemoveContact(account, contacts[3]);
  Check(B.TakeAvatar(account, jid, bytes, hash, size) & (jid = "bob@200::6") & (size = Av.maxBytes));
  Check(~B.TakeAvatar(account, jid, bytes, hash, size)); B.FreeAccount(account)
END AvatarBudget;

PROCEDURE AvatarCache;
  VAR account, contact, handle, size: LONGINT; raw: Items.Bytes; image: Av.Image; item: Items.Item;
    bytes: ARRAY 4096 OF CHAR;
BEGIN
  raw := Av.Decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQVDL+DwACFAFmBODefwAAAABJRU5ErkJggg==", size);
  image := Av.New(raw^, size); Check(image # NIL);
  account := B.NewAccount("alice", "200::1"); contact := B.AddContact(account, "bob@200::2");
  Check(~B.RestoreAvatar(account, 0, raw^, size));
  Check(~B.RestoreAvatar(account, contact, "bad image", 9));
  Check(B.RestoreAvatar(account, contact, raw^, size));
  handle := Peer(account, contact); item := St.Presence(St.available, ""); Av.Advertise(item, image);
  Check(Encoded(handle, item) = B.online); Check(B.Peek(handle, bytes) = 0);
  B.Drop(handle); handle := Peer(account, contact);
  Check(Encoded(handle, item) = B.online); Check(B.Peek(handle, bytes) = 0);
  B.FreeAccount(account)
END AvatarCache;

PROCEDURE FileTransfers;
  VAR send, receive, n, size, i, rounds, savedPhase, age: LONGINT; item, reply: Items.Item;
    peer: ARRAY 384 OF CHAR; name: ARRAY 256 OF CHAR; host: ARRAY 64 OF CHAR;
    byte: ARRAY 1 OF CHAR; sid, filename: Items.Bytes; session: Socks.Session;
    tokens: ARRAY Files.maxPerPeer OF LONGINT; localIP, peerIP, endpoint: A.IP;
BEGIN
  Check(FS.Name("զեկոյց & <draft>.txt")); Check(~FS.Name("../secret")); Check(~FS.Name("a\b"));
  Check(~FS.Name(".")); Check(~FS.Name("..")); Check(~FS.Name("")); Check(~FS.Name("a:b"));
  send := Files.Offer(901, 501, "alice@200::1", "bob@200::2", "զեկոյց.txt", 1234); Check(send > 0);
  item := Files.TakePacket(501); Check(item # NIL);
  Check(FS.ReadOffer(item, sid, filename, size) & (size = 1234) & (filename^ = "զեկոյց.txt"));
  Check(Files.Receive(902, 502, "bob@200::2", "alice@200::1", item, reply) & (reply = NIL));
  receive := Files.TakeOffer(502, peer, name, size); Check(receive > 0);
  Check((peer = "alice@200::1") & (name = "զեկոյց.txt") & (size = 1234));
  Check(Files.TakeOffer(502, peer, name, size) = 0);
  Check(Files.Accept(receive)); item := Files.TakePacket(502);
  Check(Files.Receive(901, 501, "alice@200::1", "bob@200::2", item, reply));
  Check(Files.State(send) = Files.needListener);
  Check(~Files.Listening(send, "200::1", 49999)); Check(~Files.Listening(send, "200::1", 50050));
  Check(~Files.Listening(send, "200::3", 50000)); Check(~Files.Listening(send, "::1", 50000));
  Check(A.ParseIP("200::1", localIP)); Check(A.ParseIP("200::2", peerIP));
  Check(Files.SocketEndpoints(send, localIP, peerIP, 0, 0));
  Check(~Files.SocketEndpoints(send, peerIP, localIP, 0, 0));
  Check(~Files.SocketEndpoints(send, localIP, peerIP, 1, 0));
  Check(~Files.SocketEndpoints(send, localIP, peerIP, 0, 1));
  Check(Files.ConnectEndpoint(send, endpoint) = 0);
  Check(Files.Listening(send, "200::1", 50000));
  item := Files.TakePacket(501);
  Check(Files.Receive(902, 502, "bob@200::2", "alice@200::1", item, reply));
  Check(Files.State(receive) = Files.needConnect);
  Check((Files.Endpoint(receive, host) = 50000) & (host = "200::1"));
  Check(Files.ConnectEndpoint(receive, endpoint) = 50000); Check(A.Equal(endpoint, localIP));
  Check(Files.SocketEndpoints(receive, peerIP, localIP, 0, 0));
  Check(Files.OpenSocket(send)); Check(Files.OpenSocket(receive));
  rounds := 0;
  WHILE (Files.State(receive) # Files.ready) & (rounds < 200) DO
    n := Files.Peek(receive, byte);
    IF n = 1 THEN Check(Files.Need(send) > 0); Files.Feed(send, byte, 1); Files.Sent(receive, 1) END;
    n := Files.Peek(send, byte);
    IF n = 1 THEN Check(Files.Need(receive) > 0); Files.Feed(receive, byte, 1); Files.Sent(send, 1) END;
    INC(rounds)
  END;
  Check(rounds < 200); Check(Files.State(send) = Files.handshaking);
  item := Files.TakePacket(502); Check(item # NIL);
  Check(Files.Receive(901, 501, "alice@200::1", "bob@200::2", item, reply));
  Check(Files.State(send) = Files.ready);
  Files.Started(send); Files.Started(receive); Check(Files.State(send) = Files.active);
  Files.DropOwner(501, TRUE); Files.DropOwner(502, TRUE);
  Check(Files.State(send) = Files.active); Check(Files.State(receive) = Files.active);
  FOR i := 1 TO Files.idleSeconds-1 DO Files.Tick(902) END;
  Files.Progress(receive); Files.Tick(902);
  Check((Files.Diagnostics(receive, savedPhase, age) = Files.noFailure) & (savedPhase = Files.active) & (age = 1));
  FOR i := 2 TO Files.idleSeconds DO Files.Tick(902) END;
  Check(Files.State(receive) = Files.failed);
  Check((Files.Diagnostics(receive, savedPhase, age) = Files.idleTimeout) &
    (savedPhase = Files.active) & (age = Files.idleSeconds));
  Files.Cancel(receive);
  Files.Progress(receive);
  Check((Files.Diagnostics(receive, savedPhase, age) = Files.idleTimeout) & (age = Files.idleSeconds));
  Check(Files.TakePacket(502) = NIL);
  Files.DropPeer(901, "bob@0200::2"); Files.DropOwner(502, FALSE); Check(Files.State(send) = Files.failed);
  Check((Files.Diagnostics(send, savedPhase, age) = Files.connectionClosed) & (savedPhase = Files.active));
  Check(Files.Diagnostics(receive, savedPhase, age) = Files.idleTimeout);
  Files.Forget(send); Files.Forget(receive); Check(~Files.OpenSocket(send));
  Check(~Files.SocketEndpoints(send, localIP, peerIP, 0, 0));
  item := FS.Offer("offer", "sid", "okay.txt", 42);
  FS.Attr(FS.Unique(FS.Unique(item, FS.siURI, "si"), FS.fileURI, "file"), "size", "2147483648");
  Check(~FS.ReadOffer(item, sid, filename, size));
  item := FS.Host("query", "sid", "alice@200::1", "200::3", 50000);
  Check(~FS.ReadHost(item, "alice@200::1", sid, filename, size));
  item := FS.Host("query", "sid", "alice@200::1", "200::1", 49999);
  Check(~FS.ReadHost(item, "alice@200::1", sid, filename, size));
  item := FS.Host("query", "sid", "alice@200::1", "200::1", 50050);
  Check(~FS.ReadHost(item, "alice@200::1", sid, filename, size));
  item := FS.Host("query", "sid", "alice@200::1", "200::1", 50049);
  Check(FS.ReadHost(item, "alice@200::1", sid, filename, size) & (size = 50049));
  session := Socks.New(TRUE, "0123456789012345678901234567890123456789");
  byte[0] := 4X; Socks.Feed(session, byte, 1); byte[0] := 1X; Socks.Feed(session, byte, 1);
  Check(Socks.Failed(session));
  send := Files.Offer(901, 501, "alice@200::1", "bob@200::2", "timeout.txt", 0);
  FOR i := 1 TO Files.negotiationSeconds DO Files.Tick(901) END;
  Check(Files.State(send) = Files.failed);
  Files.Cancel(send);
  Check((Files.Diagnostics(send, savedPhase, age) = Files.negotiationTimeout) &
    (savedPhase = Files.waitingReply) & (age = Files.negotiationSeconds));
  Files.Forget(send);
  send := Files.Offer(901, 501, "alice@200::1", "bob@200::2", "rejected.txt", 1);
  item := Files.TakePacket(501); sid := FS.Attribute(item, "id"); item := FS.Reject(sid^, "forbidden");
  Check(Files.Receive(901, 501, "alice@200::1", "bob@200::2", item, reply));
  Check(Files.Diagnostics(send, savedPhase, age) = Files.peerRejected); Files.Forget(send);
  send := Files.Offer(901, 501, "alice@200::1", "bob@200::2", "bad-reply.txt", 1);
  item := Files.TakePacket(501); sid := FS.Attribute(item, "id"); item := FS.Packet(sid^, "result");
  Check(Files.Receive(901, 501, "alice@200::1", "bob@200::2", item, reply));
  Check(Files.Diagnostics(send, savedPhase, age) = Files.invalidReply); Files.Forget(send);
  FOR i := 0 TO Files.maxPerPeer-1 DO
    tokens[i] := Files.Offer(901, 501+i, "alice@200::1", "bob@200::2", "bounded.txt", 1); Check(tokens[i] > 0)
  END;
  Check(Files.Offer(901, 601, "alice@200::1", "bob@0200::2", "extra.txt", 1) = 0);
  FOR i := 0 TO Files.maxPerPeer-1 DO Files.Forget(tokens[i]) END;
  send := Files.Offer(901, 501, "alice@200::1", "bob@200::2", "new.txt", 1); Check(send > tokens[0]);
  Check(Files.State(tokens[0]) = Files.failed);
  Files.DropAccount(901); Check(Files.State(send) = Files.failed); Files.Forget(send)
END FileTransfers;

PROCEDURE Run*(): LONGINT;
  VAR networkChecks: LONGINT;
BEGIN
  checks := 0; firstBad := 0;
  networkChecks := NetworkTests.Run(); IF networkChecks < 0 THEN RETURN networkChecks END;
  INC(checks, networkChecks);
  networkChecks := MarkupTests.Run(); IF networkChecks < 0 THEN RETURN networkChecks END;
  INC(checks, networkChecks);
  phase := "addresses"; Addresses;
  phase := "headers"; Headers;
  phase := "selection"; Selection;
  phase := "packets"; Packets;
  phase := "bounds"; Bounds;
  phase := "status and messages"; StatusMessages;
  phase := "outgoing message queue"; MessageQueue;
  phase := "typing"; TypingChecks;
  phase := "avatar bytes"; AvatarBytes;
  phase := "avatar streams"; AvatarStreams;
  phase := "avatar budget"; AvatarBudget;
  phase := "avatar cache"; AvatarCache;
  phase := "file transfers"; FileTransfers;
  IF firstBad # 0 THEN RETURN -firstBad END;
  RETURN checks
END Run;

END TestBarev.
