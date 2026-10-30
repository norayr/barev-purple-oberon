MODULE BarevStream;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Bounded, byte-fed peer streams. Native adapters own sockets and the clock. *)

IMPORT A := BarevAddress, LS := LongStrings, Items := XmppItems,
  XML := XmppXmlStream, Gen := XmppXmlGen, T := XmppTypes, St := BarevStanzas,
  Av := BarevAvatar, Files := BarevFiles, FS := BarevFileStanzas, Msg, IntStr, SL := StringList,
  Network := BarevNetwork, Markup := BarevMarkup;

CONST
  maxAccounts* = Network.maxAccounts; maxContacts* = Network.maxContacts; maxConnections* = Network.maxSockets;
  failed* = -1; pending* = 0; online* = 1;
  invalidText* = -2; outputFull* = -3;
  queued* = 2;
  maxPendingMessages* = 16; maxPendingContactBytes* = 65536; maxPendingAccountBytes* = 262144;
  maxStanzaBytes* = 131072; maxOutputBytes* = 262144;
  maxReceiveBytesPerSecond* = Network.receiveBytesPerSecond;
  maxMessages* = 16; maxMessageQueueBytes* = 65536;
  maxAvatarQueueBytes* = 4*Av.maxBytes;
  avatarRequested* = 1; avatarReceived* = 2; avatarRemoved* = 3;
  avatarRejected* = 4; avatarMismatch* = 5; avatarExpired* = 6;
  avatarQueueFull* = 7; avatarSuperseded* = 8; avatarError* = 9;
  clientURI = "jabber:client"; pingURI = "urn:xmpp:ping"; oldPingURI = "urn:yggb:ping";
  maxGeneration = (MAX(LONGINT)-maxConnections) DIV maxConnections;
  maxAccountGeneration = (MAX(LONGINT)-maxAccounts) DIV maxAccounts;

TYPE
  Contact = RECORD
    jid, message, avatarHash, desiredHash: Items.Bytes; ip: A.IP;
    connection, status, typing, typingAge, avatarNotice: LONGINT; up, avatarDirty: BOOLEAN; avatar: Av.Image;
    pending: SL.TStringList; pendingBytes: LONGINT
  END;
  Received = POINTER TO RECORD next: Received; jid, body, markup: Items.Bytes; contact: LONGINT END;
  Account = POINTER TO RECORD
    jid, message: Items.Bytes; ip: A.IP; contacts: ARRAY maxContacts OF Contact;
    token, status, receivedCount, receivedBytes, avatarBytes: LONGINT; first, last: Received; avatar: Av.Image;
    pendingBytes: LONGINT; pingReply: BOOLEAN
  END;
  Connection = POINTER TO RECORD
    account: Account; expected, contact, token: LONGINT; peerIP: A.IP; wirePeer: Items.Bytes;
    incoming, header, sentHeader, up, dead: BOOLEAN;
    parser: XML.Stream; output, reason, pingID: Items.Bytes;
    offset, sinceRX, pingAge, serial, frameAge, avatarAge, avatarDelay: LONGINT;
    avatarID, requestedHash: Items.Bytes; pendingEnd, socket: LONGINT
  END;

VAR
  accounts: ARRAY maxAccounts OF Account;
  accountGenerations: ARRAY maxAccounts OF LONGINT;
  connections: ARRAY maxConnections OF Connection;
  generations: ARRAY maxConnections OF LONGINT;

PROCEDURE Acc(handle: LONGINT): Account;
  VAR index: LONGINT;
BEGIN
  IF handle <= 0 THEN RETURN NIL END;
  index := (handle-1) MOD maxAccounts;
  IF accountGenerations[index] # (handle-1) DIV maxAccounts THEN RETURN NIL END;
  RETURN accounts[index]
END Acc;

PROCEDURE Conn(handle: LONGINT): Connection;
  VAR index: LONGINT;
BEGIN
  IF handle <= 0 THEN RETURN NIL END;
  index := (handle-1) MOD maxConnections;
  IF generations[index] # (handle-1) DIV maxConnections THEN RETURN NIL END;
  RETURN connections[index]
END Conn;

PROCEDURE Die(c: Connection; reason: ARRAY OF CHAR);
BEGIN
  IF ~c.dead THEN c.dead := TRUE; c.reason := Items.Copy8(reason) END
END Die;

PROCEDURE Find(account: Account; jid: ARRAY OF CHAR): LONGINT;
  VAR index: LONGINT;
BEGIN
  FOR index := 0 TO maxContacts-1 DO
    IF (account.contacts[index].jid # NIL) & (account.contacts[index].jid^ = jid) THEN RETURN index END
  END;
  RETURN -1
END Find;

PROCEDURE Enqueue(c: Connection; bytes: Items.Bytes; length: LONGINT): BOOLEAN;
  VAR pending, index: LONGINT; output: Items.Bytes;
BEGIN
  IF c.dead THEN RETURN FALSE END;
  pending := 0; IF c.output # NIL THEN pending := LS.Length8(c.output^)-c.offset END;
  IF (bytes = NIL) OR (length < 0) OR (length > maxOutputBytes-pending) THEN RETURN FALSE END;
  NEW(output, pending+length+1);
  FOR index := 0 TO pending-1 DO output[index] := c.output[c.offset+index] END;
  FOR index := 0 TO length-1 DO output[pending+index] := bytes[index] END;
  output[pending+length] := 0X; c.output := output; c.offset := 0;
  RETURN TRUE
END Enqueue;

PROCEDURE Queue(c: Connection; bytes: Items.Bytes; length: LONGINT);
BEGIN IF ~Enqueue(c, bytes, length) THEN Die(c, "output limit") END
END Queue;

PROCEDURE Opening(c: Connection; peer: Items.Bytes);
  VAR bytes: Items.Bytes; error: Msg.Msg; length: LONGINT;
    to, from, empty: T.String;
BEGIN
  to := Items.UTF8(peer^); from := Items.UTF8(c.account.jid^); empty := Items.Latin1("");
  Gen.OpenStream(to^, from^, empty^, empty^, bytes, length, error);
  IF error # NIL THEN Die(c, "cannot encode stream") ELSE Queue(c, bytes, length) END
END Opening;

PROCEDURE Packet(c: Connection; item: Items.Item);
  VAR bytes: Items.Bytes; error: Msg.Msg; length: LONGINT;
BEGIN
  Gen.Encode(item, maxStanzaBytes, bytes, length, error);
  IF error # NIL THEN Die(c, "cannot encode stanza") ELSE Queue(c, bytes, length) END
END Packet;

PROCEDURE AddressContact(a: Account; contact: LONGINT; item: Items.Item);
  VAR value: T.String;
BEGIN
  value := Items.UTF8(a.jid^); item.SetParam("from", value^);
  value := Items.UTF8(a.contacts[contact].jid^); item.SetParam("to", value^)
END AddressContact;

PROCEDURE AddressPacket(c: Connection; item: Items.Item);
BEGIN
  AddressContact(c.account, c.contact, item)
END AddressPacket;

(* Keep the first pending stanza until the socket accepts all its bytes.
   Replacing a failed stream can then retry a partially written stanza. *)
PROCEDURE DrainPending(c: Connection);
  VAR list: SL.TStringList; text: SL.pstring; bytes: Items.Bytes;
BEGIN
  IF ~c.up OR c.dead OR (c.pendingEnd # 0) THEN RETURN END;
  list := c.account.contacts[c.contact].pending;
  IF (list = NIL) OR (list.Count = 0) THEN RETURN END;
  text := SL.GetString(list, 0); bytes := Items.Copy8(text^);
  IF Enqueue(c, bytes, LS.Length8(bytes^)) THEN
    c.pendingEnd := LS.Length8(c.output^)-c.offset
  END
END DrainPending;

PROCEDURE PacketType(item: Items.Item; text: ARRAY OF CHAR);
  VAR value: T.String;
BEGIN value := Items.Latin1(text); item.SetParam("type", value^) END PacketType;

PROCEDURE Presence(c: Connection): Items.Item;
  VAR item: Items.Item;
BEGIN
  item := St.Presence(c.account.status, c.account.message^);
  Av.Advertise(item, c.account.avatar); AddressPacket(c, item); RETURN item
END Presence;

PROCEDURE RequestAvatar(c: Connection);
  VAR hash: Items.Bytes; id, number: ARRAY 32 OF CHAR; item, card: Items.Item; value: T.String; i: LONGINT;
BEGIN
  hash := c.account.contacts[c.contact].desiredHash;
  IF ~c.up OR c.dead OR (hash = NIL) OR (hash[0] = 0X) OR (c.avatarID # NIL) OR (c.avatarDelay # 0) THEN RETURN END;
  IF ((c.account.contacts[c.contact].avatarHash # NIL) & (hash^ = c.account.contacts[c.contact].avatarHash^)) OR
     ((c.requestedHash # NIL) & (hash^ = c.requestedHash^)) THEN RETURN END;
  IF c.serial = MAX(LONGINT) THEN c.serial := 0 END; INC(c.serial);
  IntStr.IntToStr(c.serial, number); id[0] := "a";
  FOR i := 0 TO LS.Length8(number) DO id[i+1] := number[i] END;
  c.avatarID := Items.Copy8(id); c.requestedHash := hash; c.avatarAge := 0; c.avatarDelay := 5;
  c.account.contacts[c.contact].avatarNotice := avatarRequested;
  item := Items.New("iq", clientURI); value := Items.Latin1(id); item.SetParam("id", value^); PacketType(item, "get");
  card := Items.New("vCard", Av.vcardURI); item.AddChild(card); AddressPacket(c, item); Packet(c, item)
END RequestAvatar;

PROCEDURE Ready(c: Connection);
  VAR item: Items.Item;
BEGIN
  IF c.header & c.sentHeader & ~c.up & ~c.dead THEN
    c.up := TRUE; c.account.contacts[c.contact].up := TRUE;
    Network.Online(c.account.token, c.contact+1, TRUE); Network.Ready(c.socket);
    item := Presence(c); Packet(c, item); RequestAvatar(c)
  END
END Ready;

PROCEDURE NewAccount*(nick, address: ARRAY OF CHAR): LONGINT;
  VAR index, n, i: LONGINT; ip: A.IP; jid, canonical: ARRAY A.maxIdentityBytes OF CHAR;
BEGIN
  IF ~A.Nick(nick) OR ~A.ParseIP(address, ip) OR ~A.Yggdrasil(ip) THEN RETURN 0 END;
  n := LS.Length8(nick); COPY(nick, jid); jid[n] := "@";
  FOR i := 0 TO LS.Length8(address) DO jid[n+1+i] := address[i] END;
  IF ~A.Identity(jid, canonical, ip) THEN RETURN 0 END;
  FOR index := 0 TO maxAccounts-1 DO
    IF (accounts[index] = NIL) & (accountGenerations[index] < maxAccountGeneration) THEN
      NEW(accounts[index]); accounts[index].jid := Items.Copy8(canonical); accounts[index].ip := ip;
      accounts[index].status := St.available; accounts[index].message := Items.Copy8("");
      INC(accountGenerations[index]); accounts[index].token := accountGenerations[index]*maxAccounts+index+1;
      IF ~Network.Open(accounts[index].token, ip) THEN accounts[index] := NIL; RETURN 0 END;
      RETURN accounts[index].token
    END
  END;
  RETURN 0
END NewAccount;

PROCEDURE AddContact*(account: LONGINT; jid: ARRAY OF CHAR): LONGINT;
  VAR a: Account; canonical: ARRAY A.maxIdentityBytes OF CHAR; ip: A.IP; index, existing: LONGINT;
BEGIN
  a := Acc(account); IF (a = NIL) OR ~A.Identity(jid, canonical, ip) OR (canonical = a.jid^) THEN RETURN 0 END;
  existing := Find(a, canonical); IF existing >= 0 THEN RETURN existing+1 END;
  FOR index := 0 TO maxContacts-1 DO
    IF a.contacts[index].jid = NIL THEN
      a.contacts[index].jid := Items.Copy8(canonical); a.contacts[index].ip := ip;
      Network.AddContact(account, index+1, ip); RETURN index+1
    END
  END;
  RETURN 0
END AddContact;

PROCEDURE NewConnection*(account, expected: LONGINT; incoming: BOOLEAN; peer, local: ARRAY OF CHAR): LONGINT;
  VAR a: Account; c, previous: Connection; ip, localIP: A.IP; index, known, n, handle: LONGINT;
BEGIN
  a := Acc(account);
  IF (a = NIL) OR ~A.ParseIP(peer, ip) OR ~A.Yggdrasil(ip) OR
     ~A.ParseIP(local, localIP) OR ~A.Equal(a.ip, localIP) THEN RETURN 0 END;
  IF ~incoming THEN
    IF (expected < 1) OR (expected > maxContacts) OR (a.contacts[expected-1].jid = NIL) OR
       ~A.Equal(a.contacts[expected-1].ip, ip) THEN RETURN 0 END;
    previous := Conn(a.contacts[expected-1].connection);
    IF (previous # NIL) & ~previous.dead THEN RETURN 0 END
  END;
  known := 0; n := 0;
  FOR index := 0 TO maxContacts-1 DO
    IF (a.contacts[index].jid # NIL) & A.Equal(a.contacts[index].ip, ip) THEN INC(known) END
  END;
  FOR index := 0 TO maxConnections-1 DO
    c := connections[index];
    IF (c # NIL) & (c.account = a) & A.Equal(c.peerIP, ip) THEN INC(n) END
  END;
  IF (known = 0) OR (n >= 4) THEN RETURN 0 END;
  index := 0;
  WHILE (index < maxConnections) & ((connections[index] # NIL) OR (generations[index] = maxGeneration)) DO INC(index) END;
  IF index = maxConnections THEN RETURN 0 END;
  NEW(c); c.account := a; c.expected := expected-1; c.contact := -1;
  c.incoming := incoming; c.peerIP := ip;
  c.parser := XML.NewLimited(4096, maxStanzaBytes, 24, 512);
  INC(generations[index]); connections[index] := c;
  handle := generations[index]*maxConnections+index+1;
  c.token := handle;
  IF ~c.incoming THEN
    c.contact := c.expected; a.contacts[c.contact].connection := handle;
    Opening(c, a.contacts[c.expected].jid)
  END;
  RETURN handle
END NewConnection;

PROCEDURE AttachSocket*(handle, socket: LONGINT): BOOLEAN;
  VAR c: Connection;
BEGIN
  c := Conn(handle);
  IF (c = NIL) OR ~Network.Owns(socket, c.account.token, c.expected+1) THEN RETURN FALSE END;
  c.socket := socket; IF c.up THEN Network.Ready(socket) END;
  RETURN TRUE
END AttachSocket;

PROCEDURE Claim(c: Connection; handle: LONGINT; root: Items.Item);
  VAR value: T.String; from: Items.Bytes; canonical: ARRAY A.maxIdentityBytes OF CHAR;
    ip: A.IP; index: LONGINT; old: Connection; preferOutgoing: BOOLEAN;
BEGIN
  value := root.GetAttribute("", "from"); IF value = NIL THEN Die(c, "missing stream identity"); RETURN END;
  from := Items.UTF8Bytes(value^);
  IF (from = NIL) OR ~A.Identity(from^, canonical, ip) OR ~A.Equal(ip, c.peerIP) THEN
    Die(c, "stream identity does not match socket peer"); RETURN
  END;
  c.wirePeer := from;
  index := Find(c.account, canonical);
  IF (index < 0) OR (~c.incoming & (index # c.expected)) THEN Die(c, "unexpected contact identity"); RETURN END;
  value := root.GetAttribute("", "to");
  IF value # NIL THEN
    from := Items.UTF8Bytes(value^);
    IF (from = NIL) OR ~A.Identity(from^, canonical, ip) OR (canonical # c.account.jid^) THEN
      Die(c, "stream addressed to another identity"); RETURN
    END
  END;
  value := root.GetAttribute("", "version");
  IF (value # NIL) & ~LS.Equal8(value^, "1.0") THEN Die(c, "unsupported stream version"); RETURN END;
  old := Conn(c.account.contacts[index].connection);
  IF (old # NIL) & (old # c) & ~old.dead THEN
    IF old.up OR (old.incoming = c.incoming) THEN Die(c, "duplicate stream"); RETURN END;
    preferOutgoing := A.Before(c.account.jid^, c.account.contacts[index].jid^);
    IF c.incoming = preferOutgoing THEN Die(c, "simultaneous connection tie-break"); RETURN END;
    Die(old, "replaced simultaneous connection")
  END;
  c.contact := index; c.header := TRUE; c.account.contacts[index].connection := handle;
  c.account.contacts[index].status := St.available; c.account.contacts[index].message := Items.Copy8("");
  IF c.incoming THEN Opening(c, c.account.contacts[index].jid) END;
  Ready(c)
END Claim;

PROCEDURE CheckAddress(c: Connection; root: Items.Item; name: ARRAY OF CHAR; peer: BOOLEAN): BOOLEAN;
  VAR value: T.String; bytes: Items.Bytes;
    canonical: ARRAY A.maxIdentityBytes OF CHAR; ip: A.IP;
BEGIN
  value := root.GetAttribute("", name); IF value = NIL THEN RETURN TRUE END;
  bytes := Items.UTF8Bytes(value^);
  IF (bytes = NIL) OR ~A.Identity(bytes^, canonical, ip) THEN RETURN FALSE END;
  IF peer THEN RETURN canonical = c.account.contacts[c.contact].jid^ END;
  RETURN canonical = c.account.jid^
END CheckAddress;

PROCEDURE Receive(c: Connection; body, markup: Items.Bytes);
  VAR received: Received; length: LONGINT; a: Account;
BEGIN
  a := c.account; length := LS.Length8(body^)+LS.Length8(markup^);
  IF length = 0 THEN RETURN END;
  IF (a.receivedCount = maxMessages) OR (length > maxMessageQueueBytes-a.receivedBytes) THEN
    Die(c, "incoming message queue limit"); RETURN
  END;
  NEW(received); received.contact := c.contact; received.jid := a.contacts[c.contact].jid;
  received.body := body; received.markup := markup;
  IF a.last = NIL THEN a.first := received ELSE a.last.next := received END;
  a.last := received; INC(a.receivedCount); INC(a.receivedBytes, length)
END Receive;

PROCEDURE ReceiveAvatar(c: Connection; image: Av.Image);
  VAR previous, length: LONGINT; a: Account;
BEGIN
  a := c.account; previous := 0; length := 0;
  IF a.contacts[c.contact].avatar # NIL THEN previous := a.contacts[c.contact].avatar.length END;
  IF image # NIL THEN length := image.length END;
  IF length > maxAvatarQueueBytes-a.avatarBytes+previous THEN
    a.contacts[c.contact].avatarNotice := avatarQueueFull; RETURN
  END;
  INC(a.avatarBytes, length-previous); a.contacts[c.contact].avatar := image; a.contacts[c.contact].avatarDirty := TRUE;
  IF image = NIL THEN
    a.contacts[c.contact].avatarHash := Items.Copy8(""); a.contacts[c.contact].avatarNotice := avatarRemoved
  ELSE
    a.contacts[c.contact].avatarHash := image.hash; a.contacts[c.contact].avatarNotice := avatarReceived
  END
END ReceiveAvatar;

PROCEDURE Stanza(c: Connection; item: Items.Item);
  VAR kind, id: T.String; child, reply: Items.Item; text, hash, markup: Items.Bytes;
    mode: LONGINT; present, statePresent: BOOLEAN; image: Av.Image; local, peer: Items.Bytes;
BEGIN
  IF ~c.header THEN Die(c, "stanza before stream header"); RETURN END;
  IF ~CheckAddress(c, item, "from", TRUE) OR ~CheckAddress(c, item, "to", FALSE) THEN
    Die(c, "stanza identity mismatch"); RETURN
  END;
  IF item.namespaceURI^ = XML.streamsURI THEN
    IF LS.Equal8(item.name^, "error") THEN Die(c, "peer stream error") END;
    RETURN
  END;
  IF item.namespaceURI^ # clientURI THEN RETURN END;
  kind := item.GetAttribute("", "type");
  IF LS.Equal8(item.name^, "presence") THEN
    IF (kind # NIL) & (kind[0] # 0) & ~LS.Equal8(kind^, "unavailable") THEN RETURN END;
    IF ~St.ReadPresence(item, mode, text) THEN Die(c, "invalid or oversized presence"); RETURN END;
    IF mode = St.offline THEN Die(c, "peer unavailable")
    ELSE c.account.contacts[c.contact].status := mode; c.account.contacts[c.contact].message := text
    END;
    IF c.dead THEN RETURN END;
    IF ~Av.ReadUpdate(item, present, hash) THEN Die(c, "invalid avatar announcement"); RETURN END;
    IF present THEN
      c.account.contacts[c.contact].desiredHash := hash;
      IF hash[0] = 0X THEN
        c.avatarID := NIL; c.requestedHash := NIL;
        IF (c.account.contacts[c.contact].avatarHash = NIL) OR (c.account.contacts[c.contact].avatarHash[0] # 0X) THEN ReceiveAvatar(c, NIL) END
      ELSE RequestAvatar(c)
      END
    END;
    RETURN
  END;
  IF LS.Equal8(item.name^, "message") THEN
    IF (kind # NIL) & (kind[0] # 0) & ~LS.Equal8(kind^, "chat") & ~LS.Equal8(kind^, "normal") THEN RETURN END;
    IF ~St.ReadFormattedMessage(item, present, text, markup) THEN Die(c, "invalid or oversized message"); RETURN END;
    IF ~St.ReadTyping(item, statePresent, mode) THEN Die(c, "invalid chat state"); RETURN END;
    IF statePresent OR present THEN
      c.account.contacts[c.contact].typing := mode;
      c.account.contacts[c.contact].typingAge := St.typingSeconds
    END;
    IF present THEN Receive(c, text, markup) END;
    RETURN
  END;
  IF ~LS.Equal8(item.name^, "iq") OR (kind = NIL) THEN RETURN END;
  id := item.GetAttribute("", "id");
  IF (id = NIL) OR (LS.Length(id^) = 0) OR (LS.Length(id^) > 128) THEN RETURN END;
  local := FS.Attribute(item, "to"); IF local = NIL THEN local := c.account.jid END;
  peer := FS.Attribute(item, "from"); IF peer = NIL THEN peer := c.wirePeer END;
  IF c.up & Files.Receive(c.account.token, c.token, local^, peer^, item, reply) THEN
    IF reply # NIL THEN AddressPacket(c, reply); Packet(c, reply) END;
    RETURN
  END;
  IF LS.Equal8(kind^, "result") OR LS.Equal8(kind^, "error") THEN
    IF (c.pingID # NIL) & LS.Equal8(id^, c.pingID^) THEN
      c.pingID := NIL; c.pingAge := 0; c.account.pingReply := TRUE
    END;
    IF (c.avatarID # NIL) & LS.Equal8(id^, c.avatarID^) THEN
      c.avatarID := NIL;
      IF ~LS.Equal8(kind^, "result") THEN c.account.contacts[c.contact].avatarNotice := avatarError
      ELSIF (c.account.contacts[c.contact].desiredHash = NIL) OR
         (c.requestedHash^ # c.account.contacts[c.contact].desiredHash^) THEN
        c.account.contacts[c.contact].avatarNotice := avatarSuperseded
      ELSIF ~Av.ReadCard(item, image) OR (image = NIL) THEN
        c.account.contacts[c.contact].avatarNotice := avatarRejected
      ELSIF image.hash^ # c.requestedHash^ THEN c.account.contacts[c.contact].avatarNotice := avatarMismatch
      ELSE ReceiveAvatar(c, image)
      END
    END;
    RETURN
  END;
  child := item.First(Av.vcardURI, "vCard");
  IF LS.Equal8(kind^, "get") & (child # NIL) THEN
    reply := Av.Card(c.account.avatar, id); AddressPacket(c, reply); Packet(c, reply); RETURN
  END;
  child := item.First(pingURI, "ping"); IF child = NIL THEN child := item.First(oldPingURI, "ping") END;
  IF ~LS.Equal8(kind^, "get") OR (child = NIL) THEN RETURN END;
  reply := Items.New("iq", clientURI); reply.SetParam("id", id^); PacketType(reply, "result");
  AddressPacket(c, reply); Packet(c, reply)
END Stanza;

PROCEDURE Feed*(handle: LONGINT; VAR bytes: ARRAY OF CHAR; length: LONGINT): LONGINT;
  VAR c: Connection; used, at, events: LONGINT; event: SHORTINT;
BEGIN
  c := Conn(handle); IF (c = NIL) OR c.dead THEN RETURN failed END;
  IF (length < 0) OR (length > LEN(bytes)) OR (length > 16384) THEN Die(c, "input chunk limit"); RETURN failed END;
  at := 0; events := 0;
  WHILE (at < length) & ~c.dead DO
    event := c.parser.Feed(bytes, at, length-at, used); INC(at, used);
    IF event = XML.opened THEN Claim(c, handle, c.parser.header)
    ELSIF event = XML.stanza THEN Stanza(c, c.parser.item)
    ELSIF event = XML.closed THEN Die(c, "stream closed")
    ELSIF event = XML.failed THEN Die(c, "invalid or oversized XML")
    END;
    IF event # XML.needInput THEN c.frameAge := 0; INC(events) END;
    IF (events > 64) OR (used = 0) THEN Die(c, "input work limit") END
  END;
  c.sinceRX := 0;
  IF c.dead THEN RETURN failed END;
  IF c.up THEN RETURN online END;
  RETURN pending
END Feed;

PROCEDURE Peek*(handle: LONGINT; VAR bytes: ARRAY OF CHAR): LONGINT;
  VAR c: Connection; count, index: LONGINT; item: Items.Item;
BEGIN
  c := Conn(handle); IF (c = NIL) OR c.dead THEN RETURN 0 END;
  item := Files.TakePacket(handle);
  WHILE item # NIL DO Packet(c, item); item := Files.TakePacket(handle) END;
  DrainPending(c);
  IF c.dead OR (c.output = NIL) THEN RETURN 0 END;
  count := LS.Length8(c.output^)-c.offset; IF count > LEN(bytes) THEN count := LEN(bytes) END;
  FOR index := 0 TO count-1 DO bytes[index] := c.output[c.offset+index] END;
  RETURN count
END Peek;

PROCEDURE Sent*(handle, count: LONGINT);
  VAR c: Connection; list: SL.TStringList; text: SL.pstring; length: LONGINT;
BEGIN
  c := Conn(handle); IF (c = NIL) OR c.dead THEN RETURN END;
  IF (c.output = NIL) OR (count < 0) OR (count > LS.Length8(c.output^)-c.offset) THEN Die(c, "invalid write completion"); RETURN END;
  IF c.pendingEnd > 0 THEN
    DEC(c.pendingEnd, count);
    IF c.pendingEnd <= 0 THEN
      list := c.account.contacts[c.contact].pending; text := SL.GetString(list, 0); length := LS.Length8(text^);
      list.Delete(list, 0);
      DEC(c.account.contacts[c.contact].pendingBytes, length); DEC(c.account.pendingBytes, length);
      IF list.Count = 0 THEN c.account.contacts[c.contact].pending := NIL END;
      c.pendingEnd := 0
    END
  END;
  INC(c.offset, count);
  IF c.offset = LS.Length8(c.output^) THEN
    c.output := NIL; c.offset := 0;
    IF ~c.sentHeader THEN c.sentHeader := TRUE; Ready(c) END
  END
END Sent;

PROCEDURE SetStatus*(account, mode: LONGINT; message: ARRAY OF CHAR): BOOLEAN;
  VAR a: Account; c: Connection; item: Items.Item; index: LONGINT;
BEGIN
  a := Acc(account); IF (a = NIL) OR (mode < St.available) OR (mode > St.chat) THEN RETURN FALSE END;
  item := St.Presence(mode, message); IF item = NIL THEN RETURN FALSE END;
  a.status := mode; a.message := Items.Copy8(message);
  FOR index := 0 TO maxConnections-1 DO
    c := connections[index];
    IF (c # NIL) & (c.account = a) & c.up & ~c.dead THEN
      item := Presence(c); Packet(c, item)
    END
  END;
  RETURN TRUE
END SetStatus;

PROCEDURE SetAvatar*(account: LONGINT; bytes: ARRAY OF CHAR; length: LONGINT): BOOLEAN;
  VAR a: Account; image: Av.Image; c: Connection; index: LONGINT;
BEGIN
  a := Acc(account); IF (a = NIL) OR (length < 0) OR (length > LEN(bytes)) THEN RETURN FALSE END;
  image := NIL;
  IF length > 0 THEN image := Av.New(bytes, length); IF image = NIL THEN RETURN FALSE END END;
  a.avatar := image;
  FOR index := 0 TO maxConnections-1 DO
    c := connections[index];
    IF (c # NIL) & (c.account = a) & c.up & ~c.dead THEN Packet(c, Presence(c)) END
  END;
  RETURN TRUE
END SetAvatar;

(* libpurple owns persistent image bytes. Validate a cached peer image before
   remembering its SHA-1; the peer's presence still supplies the desired hash. *)
PROCEDURE RestoreAvatar*(account, contact: LONGINT; bytes: ARRAY OF CHAR; length: LONGINT): BOOLEAN;
  VAR a: Account; image: Av.Image;
BEGIN
  a := Acc(account);
  IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) THEN RETURN FALSE END;
  IF (a.contacts[contact-1].jid = NIL) OR a.contacts[contact-1].avatarDirty THEN RETURN FALSE END;
  image := Av.New(bytes, length); IF image = NIL THEN RETURN FALSE END;
  a.contacts[contact-1].avatarHash := image.hash; RETURN TRUE
END RestoreAvatar;

PROCEDURE TakePingReply*(account: LONGINT): BOOLEAN;
  VAR a: Account;
BEGIN
  a := Acc(account); IF (a = NIL) OR ~a.pingReply THEN RETURN FALSE END;
  a.pingReply := FALSE; RETURN TRUE
END TakePingReply;

PROCEDURE TakeAvatar*(account: LONGINT; VAR jid, bytes, hash: ARRAY OF CHAR; VAR length: LONGINT): BOOLEAN;
  VAR a: Account; index, i: LONGINT; image: Av.Image;
BEGIN
  a := Acc(account); length := 0; IF a = NIL THEN RETURN FALSE END;
  FOR index := 0 TO maxContacts-1 DO
    IF a.contacts[index].avatarDirty THEN
      image := a.contacts[index].avatar; IF image # NIL THEN length := image.length END;
      IF (LEN(bytes) < length) OR (LEN(jid) <= LS.Length8(a.contacts[index].jid^)) OR
         (LEN(hash) <= LS.Length8(a.contacts[index].avatarHash^)) THEN RETURN FALSE END;
      COPY(a.contacts[index].jid^, jid); COPY(a.contacts[index].avatarHash^, hash);
      IF image # NIL THEN FOR i := 0 TO length-1 DO bytes[i] := image.data[i] END END;
      DEC(a.avatarBytes, length); a.contacts[index].avatar := NIL; a.contacts[index].avatarDirty := FALSE;
      RETURN TRUE
    END
  END;
  RETURN FALSE
END TakeAvatar;

PROCEDURE TakeAvatarNotice*(account: LONGINT): LONGINT;
  VAR a: Account; index, notice: LONGINT;
BEGIN
  a := Acc(account); IF a = NIL THEN RETURN 0 END;
  FOR index := 0 TO maxContacts-1 DO
    notice := a.contacts[index].avatarNotice;
    IF notice # 0 THEN a.contacts[index].avatarNotice := 0; RETURN notice END
  END;
  RETURN 0
END TakeAvatarNotice;

PROCEDURE SendFormattedMessage*(account, contact: LONGINT; body, markup: ARRAY OF CHAR): LONGINT;
  VAR a: Account; c: Connection; item: Items.Item; bytes: Items.Bytes; length: LONGINT; error: Msg.Msg;
BEGIN
  a := Acc(account); IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) THEN RETURN failed END;
  DEC(contact); IF a.contacts[contact].jid = NIL THEN RETURN failed END;
  item := St.FormattedMessage(body, markup); IF item = NIL THEN RETURN invalidText END;
  AddressContact(a, contact, item); Gen.Encode(item, maxStanzaBytes, bytes, length, error);
  IF (item.First(Markup.imURI, "html") # NIL) & ((error # NIL) OR ~Markup.WireFits(bytes^)) THEN
    item := St.Message(body); AddressContact(a, contact, item);
    Gen.Encode(item, maxStanzaBytes, bytes, length, error);
  END;
  IF error # NIL THEN RETURN invalidText END;
  c := Conn(a.contacts[contact].connection);
  IF (c = NIL) OR c.dead OR ~c.up OR (a.contacts[contact].pending # NIL) THEN
    IF (length > maxPendingContactBytes-a.contacts[contact].pendingBytes) OR
       (length > maxPendingAccountBytes-a.pendingBytes) THEN RETURN outputFull END;
    IF a.contacts[contact].pending = NIL THEN a.contacts[contact].pending := SL.Create() END;
    IF a.contacts[contact].pending.Count = maxPendingMessages THEN RETURN outputFull END;
    SL.AppendString(a.contacts[contact].pending, bytes^);
    INC(a.contacts[contact].pendingBytes, length); INC(a.pendingBytes, length);
    Network.RequestDial(account, contact+1);
    RETURN queued
  END;
  IF ~Enqueue(c, bytes, length) THEN RETURN outputFull END;
  RETURN online
END SendFormattedMessage;

PROCEDURE SendMessage*(account, contact: LONGINT; body: ARRAY OF CHAR): LONGINT;
BEGIN RETURN SendFormattedMessage(account, contact, body, "") END SendMessage;

PROCEDURE SendTyping*(account, contact, mode: LONGINT): LONGINT;
  VAR a: Account; c: Connection; item: Items.Item; bytes: Items.Bytes; length: LONGINT; error: Msg.Msg;
BEGIN
  a := Acc(account); IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) THEN RETURN failed END;
  c := Conn(a.contacts[contact-1].connection);
  IF (c = NIL) OR c.dead OR ~c.up THEN RETURN failed END;
  item := St.Typing(mode); IF item = NIL THEN RETURN invalidText END;
  AddressPacket(c, item); Gen.Encode(item, 32768, bytes, length, error);
  IF error # NIL THEN RETURN invalidText END;
  IF ~Enqueue(c, bytes, length) THEN RETURN outputFull END;
  RETURN online
END SendTyping;

PROCEDURE ContactTyping*(account, contact: LONGINT): LONGINT;
  VAR a: Account;
BEGIN
  a := Acc(account);
  IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) OR ~a.contacts[contact-1].up THEN RETURN St.stopped END;
  RETURN a.contacts[contact-1].typing
END ContactTyping;

PROCEDURE TakeReceived(account: LONGINT; VAR jid, body, markup: ARRAY OF CHAR; formatted: BOOLEAN): BOOLEAN;
  VAR a: Account; received: Received; usable: BOOLEAN;
BEGIN
  a := Acc(account); IF a = NIL THEN RETURN FALSE END;
  WHILE a.first # NIL DO
    received := a.first;
    usable := (a.contacts[received.contact].jid # NIL) &
              (a.contacts[received.contact].jid^ = received.jid^);
    IF usable & ((LEN(jid) <= LS.Length8(received.jid^)) OR (LEN(body) <= LS.Length8(received.body^)) OR
       (formatted & (LEN(markup) <= LS.Length8(received.markup^)))) THEN RETURN FALSE END;
    a.first := received.next; IF a.first = NIL THEN a.last := NIL END;
    DEC(a.receivedCount); DEC(a.receivedBytes, LS.Length8(received.body^)+LS.Length8(received.markup^));
    IF usable THEN
      COPY(received.jid^, jid); COPY(received.body^, body);
      IF formatted THEN COPY(received.markup^, markup) END;
      RETURN TRUE
    END
  END;
  RETURN FALSE
END TakeReceived;

PROCEDURE TakeFormattedMessage*(account: LONGINT; VAR jid, body, markup: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN TakeReceived(account, jid, body, markup, TRUE) END TakeFormattedMessage;

PROCEDURE TakeMessage*(account: LONGINT; VAR jid, body: ARRAY OF CHAR): BOOLEAN;
  VAR ignored: ARRAY 1 OF CHAR;
BEGIN RETURN TakeReceived(account, jid, body, ignored, FALSE) END TakeMessage;

PROCEDURE ContactStatus*(account, contact: LONGINT; VAR message: ARRAY OF CHAR): LONGINT;
  VAR a: Account;
BEGIN
  IF LEN(message) = 0 THEN RETURN St.offline END;
  message[0] := 0X; a := Acc(account);
  IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) OR ~a.contacts[contact-1].up THEN RETURN St.offline END;
  IF LEN(message) <= LS.Length8(a.contacts[contact-1].message^) THEN RETURN St.offline END;
  COPY(a.contacts[contact-1].message^, message); RETURN a.contacts[contact-1].status
END ContactStatus;

PROCEDURE ContactConnection*(account, contact: LONGINT): LONGINT;
  VAR a: Account;
BEGIN
  a := Acc(account);
  IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) OR ~a.contacts[contact-1].up THEN RETURN 0 END;
  RETURN a.contacts[contact-1].connection
END ContactConnection;

PROCEDURE OfferFile*(account, contact: LONGINT; name: ARRAY OF CHAR; size: LONGINT): LONGINT;
  VAR a: Account; c: Connection;
BEGIN
  a := Acc(account); IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) THEN RETURN 0 END;
  c := Conn(a.contacts[contact-1].connection);
  IF (c = NIL) OR c.dead OR ~c.up THEN RETURN 0 END;
  RETURN Files.Offer(account, c.token, a.jid^, c.wirePeer^, name, size)
END OfferFile;

PROCEDURE State*(handle: LONGINT): LONGINT;
  VAR c: Connection;
BEGIN c := Conn(handle); IF (c = NIL) OR c.dead THEN RETURN failed END; IF c.up THEN RETURN online END; RETURN pending END State;

PROCEDURE Reason*(handle: LONGINT; VAR text: ARRAY OF CHAR);
  VAR c: Connection;
BEGIN
  IF LEN(text) = 0 THEN RETURN END;
  c := Conn(handle); text[0] := 0X;
  IF (c # NIL) & (c.reason # NIL) THEN COPY(c.reason^, text) END
END Reason;

PROCEDURE DropConnection(handle: LONGINT; keepFiles: BOOLEAN);
  VAR c: Connection; index: LONGINT;
BEGIN
  c := Conn(handle); IF c = NIL THEN RETURN END;
  Files.DropOwner(handle, keepFiles);
  index := c.contact;
  IF (index >= 0) & (c.account.contacts[index].connection = handle) THEN
    Network.Online(c.account.token, index+1, FALSE);
    c.account.contacts[index].connection := 0; c.account.contacts[index].up := FALSE;
    c.account.contacts[index].status := St.offline; c.account.contacts[index].message := NIL;
    c.account.contacts[index].typing := St.stopped; c.account.contacts[index].typingAge := 0
  END;
  connections[(handle-1) MOD maxConnections] := NIL
END DropConnection;

PROCEDURE Drop*(handle: LONGINT);
BEGIN DropConnection(handle, FALSE) END Drop;

PROCEDURE Lost*(handle: LONGINT);
BEGIN DropConnection(handle, TRUE) END Lost;

PROCEDURE RemoveContact*(account, contact: LONGINT);
  VAR a: Account; index: LONGINT; c: Connection; received, previous, next: Received;
BEGIN
  a := Acc(account); IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) THEN RETURN END;
  DEC(contact);
  IF a.contacts[contact].jid # NIL THEN Files.DropPeer(account, a.contacts[contact].jid^) END;
  FOR index := 0 TO maxConnections-1 DO
    c := connections[index];
    IF (c # NIL) & (c.account = a) & ((c.expected = contact) OR (c.contact = contact)) THEN
      Drop(generations[index]*maxConnections+index+1)
    END
  END;
  received := a.first; previous := NIL;
  WHILE received # NIL DO
    next := received.next;
    IF received.contact = contact THEN
      IF previous = NIL THEN a.first := next ELSE previous.next := next END;
      IF a.last = received THEN a.last := previous END;
      DEC(a.receivedCount); DEC(a.receivedBytes, LS.Length8(received.body^)+LS.Length8(received.markup^))
    ELSE previous := received
    END;
    received := next
  END;
  DEC(a.pendingBytes, a.contacts[contact].pendingBytes);
  a.contacts[contact].pending := NIL; a.contacts[contact].pendingBytes := 0;
  a.contacts[contact].jid := NIL; a.contacts[contact].up := FALSE; a.contacts[contact].connection := 0;
  a.contacts[contact].message := NIL; a.contacts[contact].status := St.offline;
  IF a.contacts[contact].avatar # NIL THEN DEC(a.avatarBytes, a.contacts[contact].avatar.length) END;
  a.contacts[contact].avatar := NIL; a.contacts[contact].avatarHash := NIL; a.contacts[contact].desiredHash := NIL;
  a.contacts[contact].avatarDirty := FALSE; a.contacts[contact].typing := St.stopped; a.contacts[contact].typingAge := 0;
  a.contacts[contact].avatarNotice := 0; Network.RemoveContact(account, contact+1)
END RemoveContact;

PROCEDURE ContactOnline*(account, contact: LONGINT): BOOLEAN;
  VAR a: Account;
BEGIN
  a := Acc(account); IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) THEN RETURN FALSE END;
  RETURN a.contacts[contact-1].up
END ContactOnline;

PROCEDURE Tick*(account: LONGINT);
  VAR a: Account; c: Connection; index: LONGINT; item, ping: Items.Item;
    id: ARRAY 24 OF CHAR; value: T.String;
BEGIN
  a := Acc(account); IF a = NIL THEN RETURN END;
  Files.Tick(account);
  FOR index := 0 TO maxContacts-1 DO
    IF a.contacts[index].typingAge > 0 THEN
      DEC(a.contacts[index].typingAge);
      IF a.contacts[index].typingAge = 0 THEN a.contacts[index].typing := St.stopped END
    END
  END;
  FOR index := 0 TO maxConnections-1 DO
    c := connections[index];
    IF (c # NIL) & (c.account = a) & ~c.dead THEN
      IF c.avatarDelay > 0 THEN DEC(c.avatarDelay) END;
      IF c.avatarID # NIL THEN
        INC(c.avatarAge);
        IF c.avatarAge >= Av.requestSeconds THEN
          c.avatarID := NIL; c.account.contacts[c.contact].avatarNotice := avatarExpired
        END
      END;
      IF c.header THEN RequestAvatar(c) END;
      INC(c.frameAge); IF c.sinceRX < 30 THEN INC(c.sinceRX) END;
      IF c.pingID # NIL THEN
        INC(c.pingAge); IF c.pingAge >= 15 THEN Die(c, "ping deadline") END
      ELSIF c.up & (c.sinceRX >= 30) THEN
        IF c.serial = MAX(LONGINT) THEN c.serial := 0 END; INC(c.serial);
        IntStr.IntToStr(c.serial, id);
        c.pingID := Items.Copy8(id); value := Items.Latin1(id);
        item := Items.New("iq", clientURI); item.SetParam("id", value^); PacketType(item, "get");
        AddressPacket(c, item); ping := Items.New("ping", pingURI); item.AddChild(ping); Packet(c, item)
      END;
      IF (~c.up & (c.frameAge >= 30)) OR (c.frameAge >= 120) THEN Die(c, "stream frame deadline") END
    END
  END
END Tick;

PROCEDURE FreeAccount*(handle: LONGINT);
  VAR a: Account; index: LONGINT;
BEGIN
  a := Acc(handle); IF a = NIL THEN RETURN END;
  Files.DropAccount(handle);
  FOR index := 0 TO maxConnections-1 DO
    IF (connections[index] # NIL) & (connections[index].account = a) THEN
      Drop(generations[index]*maxConnections+index+1)
    END
  END;
  Network.Close(handle); accounts[(handle-1) MOD maxAccounts] := NIL
END FreeAccount;

END BarevStream.
