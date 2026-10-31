MODULE BarevImages;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Peer-scoped image objects and SI/IBB sessions. No paths, sockets or native pointers. *)

IMPORT I := XmppItems, T := XmppTypes, S := LongStrings, F := BarevFileStanzas,
  Av := BarevAvatar, St := BarevStanzas, M := BarevMarkup, SHA := BarevSHA1, IntStr;

CONST
  bobURI* = "urn:xmpp:bob"; ibbURI* = "http://jabber.org/protocol/ibb";
  discoURI = "http://jabber.org/protocol/disco#info";
  maxImageBytes* = 16777216; maxBobBytes* = 262144; defaultBobBytes* = 65536;
  maxDimension* = 8192; maxPixels* = 16777216; maxMemory* = 67108864;
  blockBytes* = 4096; maxBlockBytes = 16384; cacheEntries = 8; maxEvents = 16;
  offer* = 1; received* = 2; sent* = 3; failed* = 4;
  waitOffer = 1; waitOpen = 2; waitData = 3; waitClose = 4; needConsent = 5; receiving = 6;

TYPE
  Blob = POINTER TO RECORD data: I.Bytes; size, refs: LONGINT; mime, cid: I.Bytes END;
  Event* = POINTER TO RECORD next: Event; token*, kind*, size*: LONGINT;
    name*, caption*: I.Bytes; blob: Blob END;
  Pending = POINTER TO RECORD token, age: LONGINT; cid, id, caption: I.Bytes; consent: BOOLEAN END;
  Transfer = POINTER TO RECORD token, phase, size, done, seq, block, age, count: LONGINT;
    sid, id, name, mime: I.Bytes; blob: Blob END;
  Packet = POINTER TO RECORD next: Packet; item: I.Item END;
  Context* = POINTER TO RECORD
    cache: ARRAY cacheEntries OF Blob; oldest, autoBytes, bobBytes, requestBudget, imageBudget: LONGINT;
    pending: ARRAY 4 OF Pending; tx, rx: Transfer;
    first, last: Packet; packets, events: LONGINT; event*, lastEvent: Event
  END;

VAR serial, memory: LONGINT;

PROCEDURE New*(automatic, bob: LONGINT): Context;
  VAR c: Context;
BEGIN
  NEW(c); c.autoBytes := automatic;
  IF c.autoBytes < 0 THEN c.autoBytes := 0 ELSIF c.autoBytes > maxImageBytes THEN c.autoBytes := maxImageBytes END;
  c.bobBytes := bob;
  IF c.bobBytes < 1024 THEN c.bobBytes := 1024 ELSIF c.bobBytes > maxBobBytes THEN c.bobBytes := maxBobBytes END;
  c.requestBudget := 8; c.imageBudget := 8; RETURN c
END New;

PROCEDURE Next(): LONGINT;
BEGIN IF serial = MAX(LONGINT) THEN RETURN 0 END; INC(serial); RETURN serial END Next;

PROCEDURE ID(prefix: ARRAY OF CHAR; number: LONGINT): I.Bytes;
  VAR text, digits: ARRAY 64 OF CHAR; i, n: LONGINT;
BEGIN
  IntStr.IntToStr(number, digits); COPY(prefix, text); n := S.Length8(text);
  FOR i := 0 TO S.Length8(digits) DO text[n+i] := digits[i] END;
  RETURN I.Copy8(text)
END ID;

PROCEDURE Retain(b: Blob);
BEGIN IF b # NIL THEN INC(b.refs) END END Retain;

PROCEDURE Release(VAR b: Blob);
BEGIN
  IF b # NIL THEN DEC(b.refs); IF b.refs = 0 THEN DEC(memory, b.size); b.data := NIL END; b := NIL END
END Release;

PROCEDURE Allocate(size: LONGINT): Blob;
  VAR b: Blob;
BEGIN
  IF (size <= 0) OR (size > maxImageBytes) OR (size > maxMemory-memory) THEN RETURN NIL END;
  NEW(b); NEW(b.data, size); b.size := size; b.refs := 1; INC(memory, size); RETURN b
END Allocate;

PROCEDURE Identify(b: Blob): BOOLEAN;
  VAR hash: I.Bytes; cid: ARRAY 80 OF CHAR; i: LONGINT;
BEGIN
  b.mime := Av.ImageMIME(b.data^, b.size, maxDimension, maxPixels); IF b.mime = NIL THEN RETURN FALSE END;
  IF b.size > maxBobBytes THEN b.cid := I.Copy8(""); RETURN TRUE END;
  hash := SHA.Hash(b.data^, b.size); IF hash = NIL THEN RETURN FALSE END; cid := "sha1+";
  FOR i := 0 TO 39 DO cid[5+i] := hash[i] END;
  hash := I.Copy8("@bob.xmpp.org"); FOR i := 0 TO S.Length8(hash^) DO cid[45+i] := hash[i] END;
  b.cid := I.Copy8(cid); RETURN TRUE
END Identify;

PROCEDURE CID*(text: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT; suffix: ARRAY 14 OF CHAR; prefix: ARRAY 6 OF CHAR;
BEGIN
  IF S.Length8(text) # 58 THEN RETURN FALSE END;
  prefix := "sha1+"; FOR i := 0 TO 4 DO IF text[i] # prefix[i] THEN RETURN FALSE END END;
  FOR i := 5 TO 44 DO IF ~(((text[i] >= "0") & (text[i] <= "9")) OR ((text[i] >= "a") & (text[i] <= "f"))) THEN RETURN FALSE END END;
  suffix := "@bob.xmpp.org";
  FOR i := 0 TO 12 DO IF text[45+i] # suffix[i] THEN RETURN FALSE END END;
  RETURN TRUE
END CID;

PROCEDURE Cached(c: Context; cid: I.Bytes): Blob;
  VAR i: LONGINT;
BEGIN
  IF cid = NIL THEN RETURN NIL END;
  FOR i := 0 TO cacheEntries-1 DO IF (c.cache[i] # NIL) & (c.cache[i].cid^ = cid^) THEN RETURN c.cache[i] END END;
  RETURN NIL
END Cached;

PROCEDURE Cache(c: Context; b: Blob);
BEGIN
  IF Cached(c, b.cid) # NIL THEN RETURN END;
  Release(c.cache[c.oldest]); c.cache[c.oldest] := b; Retain(b); c.oldest := (c.oldest+1) MOD cacheEntries
END Cache;

PROCEDURE Queue(c: Context; item: I.Item): BOOLEAN;
  VAR p: Packet;
BEGIN
  IF (item = NIL) OR (c.packets >= 8) THEN RETURN FALSE END;
  NEW(p); p.item := item;
  IF c.last = NIL THEN c.first := p ELSE c.last.next := p END;
  c.last := p; INC(c.packets); RETURN TRUE
END Queue;

PROCEDURE TakePacket*(c: Context): I.Item;
  VAR item: I.Item;
BEGIN
  IF (c = NIL) OR (c.first = NIL) THEN RETURN NIL END;
  item := c.first.item; c.first := c.first.next; DEC(c.packets); IF c.first = NIL THEN c.last := NIL END;
  RETURN item
END TakePacket;

PROCEDURE Notify(c: Context; token, kind, size: LONGINT; name, caption: I.Bytes; b: Blob): BOOLEAN;
  VAR e: Event;
BEGIN
  IF c.events >= maxEvents THEN RETURN FALSE END;
  NEW(e); e.token := token; e.kind := kind; e.size := size; e.name := name; e.caption := caption; e.blob := b; Retain(b);
  IF c.lastEvent = NIL THEN c.event := e ELSE c.lastEvent.next := e END;
  c.lastEvent := e; INC(c.events); RETURN TRUE
END Notify;

PROCEDURE DropEvent*(c: Context);
BEGIN
  IF (c = NIL) OR (c.event = NIL) THEN RETURN END;
  Release(c.event.blob); c.event := c.event.next; DEC(c.events); IF c.event = NIL THEN c.lastEvent := NIL END
END DropEvent;

PROCEDURE ReadEvent*(c: Context; VAR bytes: ARRAY OF CHAR): LONGINT;
  VAR i, n: LONGINT;
BEGIN
  IF (c = NIL) OR (c.event = NIL) OR (c.event.blob = NIL) THEN RETURN 0 END;
  n := c.event.blob.size; IF n > LEN(bytes) THEN RETURN 0 END;
  FOR i := 0 TO n-1 DO bytes[i] := c.event.blob.data[i] END; RETURN n
END ReadEvent;

PROCEDURE Text(item: I.Item; maximum: LONGINT): I.Bytes;
  VAR part: I.Content; text: T.String; result: I.Bytes;
BEGIN
  IF item = NIL THEN RETURN NIL END;
  part := item.content; WHILE part # NIL DO IF part.element # NIL THEN RETURN NIL END; part := part.next END;
  text := item.Text(); result := I.UTF8Bytes(text^);
  IF (result = NIL) OR (S.Length8(result^) > maximum) THEN RETURN NIL END;
  RETURN result
END Text;

PROCEDURE Child(parent: I.Item; uri, name: ARRAY OF CHAR): I.Item;
  VAR item: I.Item;
BEGIN item := I.New(name, uri); parent.AddChild(item); RETURN item END Child;

PROCEDURE AddText(parent: I.Item; bytes: I.Bytes);
  VAR text: T.String;
BEGIN text := I.UTF8(bytes^); parent.AddText(text^, 0, S.Length(text^)) END AddText;

PROCEDURE Result(c: Context; id: I.Bytes);
BEGIN IF ~Queue(c, F.Packet(id^, "result")) THEN END END Result;

PROCEDURE Reject(c: Context; id: I.Bytes; condition: ARRAY OF CHAR);
BEGIN IF F.ID(id) THEN IF ~Queue(c, F.Reject(id^, condition)) THEN END END END Reject;

PROCEDURE DataPacket(b: Blob; id: I.Bytes): I.Item;
  VAR item, data: I.Item; encoded: I.Bytes;
BEGIN
  IF b.size > maxBobBytes THEN RETURN NIL END;
  encoded := Av.EncodeBounded(b.data^, b.size, maxBobBytes); IF encoded = NIL THEN RETURN NIL END;
  item := F.Packet(id^, "result"); data := Child(item, bobURI, "data");
  F.Attr(data, "cid", b.cid^); F.Attr(data, "type", b.mime^); F.Attr(data, "max-age", "600"); AddText(data, encoded);
  RETURN item
END DataPacket;

PROCEDURE BobMessage(b: Blob): I.Item;
  VAR item, body, html, img: I.Item; source: ARRAY 96 OF CHAR; i: LONGINT;
BEGIN
  item := I.New("message", "jabber:client"); F.Attr(item, "type", "chat");
  body := Child(item, "jabber:client", "body"); AddText(body, I.Copy8("[Image]"));
  html := Child(item, M.imURI, "html"); body := Child(html, M.xhtmlURI, "body"); img := Child(body, M.xhtmlURI, "img");
  source := "cid:"; FOR i := 0 TO S.Length8(b.cid^) DO source[4+i] := b.cid[i] END;
  F.Attr(img, "src", source); F.Attr(img, "alt", "Image"); RETURN item
END BobMessage;

PROCEDURE SI(t: Transfer; accept: BOOLEAN): I.Item;
  VAR item, si, file: I.Item; number: ARRAY 32 OF CHAR;
BEGIN
  IF accept THEN item := F.Packet(t.id^, "result") ELSE item := F.Packet(t.id^, "set") END;
  si := Child(item, F.siURI, "si");
  IF ~accept THEN
    F.Attr(si, "id", t.sid^); F.Attr(si, "profile", F.fileURI); F.Attr(si, "mime-type", t.mime^);
    file := Child(si, F.fileURI, "file"); F.Attr(file, "name", t.name^); IntStr.IntToStr(t.size, number); F.Attr(file, "size", number)
  END;
  F.SelectionFor(si, ~accept, ibbURI); RETURN item
END SI;

PROCEDURE SendBlock(c: Context);
  VAR t: Transfer; item, data: I.Item; encoded: I.Bytes; number: ARRAY 32 OF CHAR; chunk: ARRAY blockBytes OF CHAR; i: LONGINT;
BEGIN
  t := c.tx; t.id := ID("bid", Next()); item := F.Packet(t.id^, "set");
  IF t.done = t.size THEN data := Child(item, ibbURI, "close"); t.phase := waitClose
  ELSE
    t.count := t.size-t.done; IF t.count > blockBytes THEN t.count := blockBytes END;
    FOR i := 0 TO t.count-1 DO chunk[i] := t.blob.data[t.done+i] END;
    encoded := Av.Encode(chunk, t.count); data := Child(item, ibbURI, "data"); AddText(data, encoded);
    IntStr.IntToStr(t.seq, number); F.Attr(data, "seq", number); t.phase := waitData
  END;
  F.Attr(data, "sid", t.sid^); IF ~Queue(c, item) THEN t.phase := 0 END
END SendBlock;

PROCEDURE Send*(c: Context; bytes: ARRAY OF CHAR; length: LONGINT; name: ARRAY OF CHAR): LONGINT;
  VAR b: Blob; t: Transfer; i, token: LONGINT;
BEGIN
  IF (c = NIL) OR (length > LEN(bytes)) OR ~F.Name(name) OR (c.tx # NIL) THEN RETURN 0 END;
  b := Allocate(length); IF b = NIL THEN RETURN 0 END;
  FOR i := 0 TO length-1 DO b.data[i] := bytes[i] END;
  IF ~Identify(b) THEN Release(b); RETURN 0 END;
  token := Next(); IF token = 0 THEN Release(b); RETURN 0 END;
  IF length <= c.bobBytes THEN
    IF ~Queue(c, BobMessage(b)) THEN Release(b); RETURN 0 END;
    Cache(c, b); Release(b); RETURN token
  END;
  NEW(t); t.token := token; t.blob := b; t.size := length; t.mime := b.mime; t.name := I.Copy8(name);
  t.sid := ID("bis", token); t.id := ID("bio", token); t.phase := waitOffer;
  IF ~Queue(c, SI(t, FALSE)) THEN Release(t.blob); RETURN 0 END;
  c.tx := t;
  IF ~Notify(c, token, 5, length, t.name, I.Copy8("Sending original image over the messaging connection"), NIL) THEN END;
  RETURN token
END Send;

PROCEDURE FailTransfer(c: Context; VAR t: Transfer);
BEGIN
  IF t = NIL THEN RETURN END;
  IF ~Notify(c, t.token, failed, t.size, t.name, I.Copy8("Image transfer failed or was declined."), NIL) THEN END;
  Release(t.blob); t := NIL
END FailTransfer;

PROCEDURE Request(c: Context; p: Pending): BOOLEAN;
  VAR item, data: I.Item;
BEGIN
  p.id := ID("bib", p.token); item := F.Packet(p.id^, "get"); data := Child(item, bobURI, "data");
  F.Attr(data, "cid", p.cid^); p.age := 0; RETURN Queue(c, item)
END Request;

PROCEDURE Accept*(c: Context; token: LONGINT; accepted: BOOLEAN): BOOLEAN;
  VAR i: LONGINT; p: Pending; b: Blob;
BEGIN
  IF c = NIL THEN RETURN FALSE END;
  IF (c.rx # NIL) & (c.rx.token = token) THEN
    IF ~accepted THEN Reject(c, c.rx.id, "forbidden"); FailTransfer(c, c.rx); RETURN TRUE END;
    IF c.rx.phase # needConsent THEN RETURN FALSE END;
    c.rx.blob := Allocate(c.rx.size);
    IF c.rx.blob = NIL THEN Reject(c, c.rx.id, "resource-constraint"); FailTransfer(c, c.rx); RETURN FALSE END;
    IF ~Queue(c, SI(c.rx, TRUE)) THEN FailTransfer(c, c.rx); RETURN FALSE END;
    c.rx.phase := waitOpen; c.rx.age := 0; RETURN TRUE
  END;
  FOR i := 0 TO 3 DO
    p := c.pending[i];
    IF (p # NIL) & (p.token = token) THEN
      IF ~accepted THEN c.pending[i] := NIL; RETURN TRUE END;
      p.consent := TRUE; b := Cached(c, p.cid);
      IF b # NIL THEN
        IF ~Notify(c, token, received, b.size, I.Copy8("image"), p.caption, b) THEN RETURN FALSE END;
        c.pending[i] := NIL; RETURN TRUE
      END;
      RETURN Request(c, p)
    END
  END;
  RETURN FALSE
END Accept;

PROCEDURE Cancel*(c: Context; token: LONGINT);
  VAR i: LONGINT; item, data: I.Item; id: I.Bytes;
BEGIN
  IF c = NIL THEN RETURN END;
  IF (c.tx # NIL) & (c.tx.token = token) THEN
    id := ID("bix", Next()); item := F.Packet(id^, "set"); data := Child(item, ibbURI, "close"); F.Attr(data, "sid", c.tx.sid^);
    IF ~Queue(c, item) THEN END; FailTransfer(c, c.tx)
  ELSIF (c.rx # NIL) & (c.rx.token = token) THEN
    IF c.rx.phase = needConsent THEN Reject(c, c.rx.id, "forbidden")
    ELSE
      id := ID("bix", Next()); item := F.Packet(id^, "set"); data := Child(item, ibbURI, "close"); F.Attr(data, "sid", c.rx.sid^);
      IF ~Queue(c, item) THEN END
    END;
    FailTransfer(c, c.rx)
  ELSE FOR i := 0 TO 3 DO IF (c.pending[i] # NIL) & (c.pending[i].token = token) THEN c.pending[i] := NIL END END
  END
END Cancel;

PROCEDURE FindImages(c: Context; item: I.Item; caption: I.Bytes; depth: LONGINT; VAR found: LONGINT);
  VAR part: I.Content; source, cid: I.Bytes; p: Pending; b: Blob; index, i: LONGINT;
BEGIN
  IF (item = NIL) OR (depth > 16) OR (found >= 4) OR (item.namespaceURI^ # M.xhtmlURI) THEN RETURN END;
  IF S.Equal8(item.name^, "img") THEN
    source := F.Attribute(item, "src");
    IF (source = NIL) OR (S.Length8(source^) # 62) THEN RETURN END;
    IF (source[0] # "c") OR (source[1] # "i") OR (source[2] # "d") OR (source[3] # ":") THEN RETURN END;
    NEW(cid, 59); FOR i := 0 TO 58 DO cid[i] := source[i+4] END;
    IF ~CID(cid^) OR (c.imageBudget <= 0) THEN RETURN END;
    DEC(c.imageBudget);
    index := 0; WHILE (index < 4) & (c.pending[index] # NIL) DO INC(index) END;
    IF index = 4 THEN RETURN END;
    NEW(p); p.token := Next(); p.cid := cid; IF found = 0 THEN p.caption := caption ELSE p.caption := I.Copy8("") END;
    INC(found); c.pending[index] := p; b := Cached(c, cid);
    IF (c.autoBytes >= maxBobBytes) OR ((b # NIL) & (b.size <= c.autoBytes)) THEN
      p.consent := TRUE;
      IF b # NIL THEN
        IF ~Notify(c, p.token, received, b.size, I.Copy8("image"), p.caption, b) THEN END;
        c.pending[index] := NIL
      ELSIF ~Request(c, p) THEN c.pending[index] := NIL
      END
    ELSE
      IF ~Notify(c, p.token, offer, 0, I.Copy8("inline-image.png"), I.Copy8("Inline image (at most 256 KiB)"), NIL) THEN c.pending[index] := NIL END
    END;
    RETURN
  END;
  part := item.content;
  WHILE part # NIL DO IF part.element # NIL THEN FindImages(c, part.element, caption, depth+1, found) END; part := part.next END
END FindImages;

PROCEDURE References(item: I.Item; cid: I.Bytes; depth: LONGINT): BOOLEAN;
  VAR source: I.Bytes; part: I.Content; i: LONGINT;
BEGIN
  IF (item = NIL) OR (depth > 16) OR (item.namespaceURI^ # M.xhtmlURI) THEN RETURN FALSE END;
  IF S.Equal8(item.name^, "img") THEN
    source := F.Attribute(item, "src");
    IF (source = NIL) OR (S.Length8(source^) # 62) THEN RETURN FALSE END;
    IF (source[0] # "c") OR (source[1] # "i") OR (source[2] # "d") OR (source[3] # ":") THEN RETURN FALSE END;
    FOR i := 0 TO 58 DO IF source[i+4] # cid[i] THEN RETURN FALSE END END;
    RETURN TRUE
  END;
  part := item.content;
  WHILE part # NIL DO
    IF (part.element # NIL) & References(part.element, cid, depth+1) THEN RETURN TRUE END;
    part := part.next
  END;
  RETURN FALSE
END References;

PROCEDURE Receive*(c: Context; item: I.Item): BOOLEAN;
  VAR kind, id, cid, mime, text, bytes, sid, name, profile, value, caption, plain: I.Bytes;
    data, si, file, rich, query, feature: I.Item; p: Pending; b: Blob; t: Transfer;
    i, n, size, block, seq, found: LONGINT; okay: BOOLEAN;
BEGIN
  IF (c = NIL) OR (item = NIL) THEN RETURN FALSE END;
  IF S.Equal8(item.name^, "message") THEN
    kind := F.Attribute(item, "type");
    IF (kind # NIL) & (kind^ # "chat") & (kind^ # "normal") & (kind[0] # 0X) THEN RETURN FALSE END;
    rich := St.RichBody(item); IF rich = NIL THEN RETURN FALSE END;
    caption := I.Copy8(""); IF ~M.Display(rich, plain, caption) THEN caption := I.Copy8("") END;
    (* Only referenced, checked BoB objects may enter the peer's image cache. *)
    data := F.Unique(item, bobURI, "data");
    IF data # NIL THEN
      cid := F.Attribute(data, "cid"); mime := F.Attribute(data, "type"); text := Text(data, 350552);
      IF (c.imageBudget > 0) & (cid # NIL) & CID(cid^) & (mime # NIL) & (text # NIL) & References(rich, cid, 0) THEN
        bytes := Av.DecodeBounded(text^, maxBobBytes, 350552, size);
        IF bytes # NIL THEN
          b := Allocate(size);
          IF b # NIL THEN
            FOR i := 0 TO size-1 DO b.data[i] := bytes[i] END;
            IF Identify(b) & (b.cid^ = cid^) & (b.mime^ = mime^) THEN Cache(c, b) END;
            Release(b)
          END
        END
      END
    END;
    found := 0; FindImages(c, rich, caption, 0, found); RETURN found > 0
  END;
  IF ~S.Equal8(item.name^, "iq") THEN RETURN FALSE END;
  kind := F.Attribute(item, "type"); id := F.Attribute(item, "id"); IF (kind = NIL) OR ~F.ID(id) THEN RETURN FALSE END;
  data := F.Unique(item, bobURI, "data");
  IF (kind^ = "get") & (data # NIL) THEN
    cid := F.Attribute(data, "cid"); b := Cached(c, cid);
    IF (b = NIL) OR (b.size > maxBobBytes) THEN Reject(c, id, "item-not-found")
    ELSIF (c.requestBudget <= 0) OR (c.packets > 0) THEN Reject(c, id, "resource-constraint")
    ELSE DEC(c.requestBudget); IF ~Queue(c, DataPacket(b, id)) THEN END
    END;
    RETURN TRUE
  END;
  IF (kind^ = "get") & (F.Unique(item, discoURI, "query") # NIL) THEN
    query := F.Packet(id^, "result"); si := Child(query, discoURI, "query");
    feature := Child(si, discoURI, "feature"); F.Attr(feature, "var", bobURI);
    feature := Child(si, discoURI, "feature"); F.Attr(feature, "var", ibbURI);
    feature := Child(si, discoURI, "feature"); F.Attr(feature, "var", F.siURI);
    feature := Child(si, discoURI, "feature"); F.Attr(feature, "var", F.fileURI);
    feature := Child(si, discoURI, "feature"); F.Attr(feature, "var", M.imURI);
    IF ~Queue(c, query) THEN END; RETURN TRUE
  END;
  IF (kind^ = "result") OR (kind^ = "error") THEN
    FOR n := 0 TO 3 DO
      p := c.pending[n];
      IF (p # NIL) & (p.id # NIL) & (p.id^ = id^) THEN
        c.pending[n] := NIL; b := NIL; okay := FALSE;
        IF (kind^ = "result") & (data # NIL) THEN
          cid := F.Attribute(data, "cid"); mime := F.Attribute(data, "type"); text := Text(data, 350552);
          IF (cid # NIL) & (cid^ = p.cid^) & (mime # NIL) & (text # NIL) THEN
            bytes := Av.DecodeBounded(text^, maxBobBytes, 350552, size);
            IF bytes # NIL THEN
              b := Allocate(size);
              IF b # NIL THEN
                FOR i := 0 TO size-1 DO b.data[i] := bytes[i] END;
                okay := Identify(b) & (b.cid^ = cid^) & (b.mime^ = mime^)
              END
            END
          END
        END;
        IF okay THEN
          Cache(c, b); IF ~Notify(c, p.token, received, b.size, I.Copy8("image"), p.caption, b) THEN END
        ELSE IF ~Notify(c, p.token, failed, 0, I.Copy8("image"), I.Copy8("Inline image unavailable or invalid."), NIL) THEN END
        END;
        Release(b); RETURN TRUE
      END
    END;
    t := c.tx;
    IF (t = NIL) OR (t.id^ # id^) THEN RETURN FALSE END;
    IF kind^ = "error" THEN FailTransfer(c, c.tx); RETURN TRUE END;
    t.age := 0;
    IF t.phase = waitOffer THEN
      IF ~F.MethodFor(item, FALSE, ibbURI) THEN FailTransfer(c, c.tx); RETURN TRUE END;
      t.id := ID("biu", Next()); si := F.Packet(t.id^, "set"); data := Child(si, ibbURI, "open");
      F.Attr(data, "sid", t.sid^); F.Attr(data, "block-size", "4096"); F.Attr(data, "stanza", "iq");
      t.phase := waitOpen; IF ~Queue(c, si) THEN FailTransfer(c, c.tx) END
    ELSIF t.phase = waitOpen THEN SendBlock(c)
    ELSIF t.phase = waitData THEN INC(t.done, t.count); t.seq := (t.seq+1) MOD 65536; SendBlock(c)
    ELSIF t.phase = waitClose THEN
      IF ~Notify(c, t.token, sent, t.size, t.name, I.Copy8(""), NIL) THEN END;
      Release(t.blob); c.tx := NIL
    ELSE FailTransfer(c, c.tx)
    END;
    RETURN TRUE
  END;
  IF kind^ # "set" THEN RETURN FALSE END;
  si := F.Unique(item, F.siURI, "si");
  IF si # NIL THEN
    IF ~F.MethodFor(item, TRUE, ibbURI) THEN RETURN FALSE END;
    file := F.Unique(si, F.fileURI, "file"); mime := F.Attribute(si, "mime-type"); profile := F.Attribute(si, "profile");
    sid := F.Attribute(si, "id"); name := F.Attribute(file, "name");
    IF (profile = NIL) OR (profile^ # F.fileURI) OR (mime = NIL) OR
       ((mime^ # "image/png") & (mime^ # "image/jpeg")) OR ~F.ID(sid) OR (name = NIL) OR ~F.Name(name^) OR
       ~F.Number(F.Attribute(file, "size"), size) OR (size < 1) OR (size > maxImageBytes) THEN
      Reject(c, id, "not-acceptable"); RETURN TRUE
    END;
    IF c.rx # NIL THEN Reject(c, id, "resource-constraint"); RETURN TRUE END;
    IF c.imageBudget <= 0 THEN Reject(c, id, "resource-constraint"); RETURN TRUE END;
    DEC(c.imageBudget);
    NEW(t); t.token := Next(); t.id := id; t.sid := sid; t.size := size; t.name := name; t.mime := mime; t.phase := needConsent; c.rx := t;
    IF size <= c.autoBytes THEN okay := Accept(c, t.token, TRUE)
    ELSE
      IF ~Notify(c, t.token, offer, size, name, I.Copy8("Receive original image over the messaging connection"), NIL) THEN
        Reject(c, id, "resource-constraint"); FailTransfer(c, c.rx)
      END
    END;
    RETURN TRUE
  END;
  data := F.Unique(item, ibbURI, "open");
  IF data # NIL THEN
    t := c.rx; sid := F.Attribute(data, "sid"); value := F.Attribute(data, "stanza");
    IF (t = NIL) OR (sid = NIL) OR (sid^ # t.sid^) OR (t.phase # waitOpen) OR
       ((value # NIL) & (value^ # "iq")) OR ~F.Number(F.Attribute(data, "block-size"), block) OR
       (block < 1) OR (block > maxBlockBytes) THEN Reject(c, id, "unexpected-request"); RETURN TRUE END;
    t.block := block; t.phase := receiving; t.age := 0; Result(c, id); RETURN TRUE
  END;
  data := F.Unique(item, ibbURI, "data");
  IF data # NIL THEN
    t := c.rx; sid := F.Attribute(data, "sid");
    IF (t = NIL) OR (sid = NIL) OR (sid^ # t.sid^) OR (t.phase # receiving) THEN Reject(c, id, "unexpected-request"); RETURN TRUE END;
    text := Text(data, 23000); bytes := NIL;
    IF text # NIL THEN bytes := Av.DecodeBounded(text^, t.block, 23000, size) END;
    IF ~F.Number(F.Attribute(data, "seq"), seq) OR (seq # t.seq) OR (bytes = NIL) OR (size < 1) OR (size > t.size-t.done) THEN
      Reject(c, id, "bad-request"); FailTransfer(c, c.rx); RETURN TRUE
    END;
    FOR i := 0 TO size-1 DO t.blob.data[t.done+i] := bytes[i] END;
    INC(t.done, size); t.seq := (t.seq+1) MOD 65536; t.age := 0; Result(c, id); RETURN TRUE
  END;
  data := F.Unique(item, ibbURI, "close");
  IF data # NIL THEN
    t := c.rx; sid := F.Attribute(data, "sid");
    IF (c.tx # NIL) & (sid # NIL) & (sid^ = c.tx.sid^) THEN
      Result(c, id); FailTransfer(c, c.tx); RETURN TRUE
    END;
    IF (t = NIL) OR (sid = NIL) OR (sid^ # t.sid^) THEN Reject(c, id, "item-not-found"); RETURN TRUE END;
    IF (t.phase # receiving) OR (t.done # t.size) OR ~Identify(t.blob) OR (t.blob.mime^ # t.mime^) THEN
      Reject(c, id, "not-acceptable"); FailTransfer(c, c.rx); RETURN TRUE
    END;
    Result(c, id);
    IF ~Notify(c, t.token, received, t.size, t.name, I.Copy8(""), t.blob) THEN END;
    (* Large originals are retained only until the frontend consumes the event. *)
    IF t.size <= maxBobBytes THEN Cache(c, t.blob) END;
    Release(t.blob); c.rx := NIL; RETURN TRUE
  END;
  RETURN FALSE
END Receive;

PROCEDURE Progress*(c: Context; token: LONGINT): LONGINT;
BEGIN
  IF c = NIL THEN RETURN -1 END;
  IF (c.rx # NIL) & (c.rx.token = token) THEN RETURN c.rx.done END;
  IF (c.tx # NIL) & (c.tx.token = token) THEN RETURN c.tx.done END;
  RETURN -1
END Progress;

PROCEDURE Disconnect*(c: Context);
  VAR i: LONGINT;
BEGIN
  IF c = NIL THEN RETURN END;
  c.first := NIL; c.last := NIL; c.packets := 0; FailTransfer(c, c.tx); FailTransfer(c, c.rx);
  FOR i := 0 TO 3 DO
    IF c.pending[i] # NIL THEN
      IF ~Notify(c, c.pending[i].token, failed, 0, I.Copy8("image"), I.Copy8("Messaging connection closed."), NIL) THEN END;
      c.pending[i] := NIL
    END
  END
END Disconnect;

PROCEDURE Tick*(c: Context);
  VAR i: LONGINT; p: Pending;
BEGIN
  IF c = NIL THEN RETURN END;
  c.requestBudget := 8; c.imageBudget := 8;
  IF c.tx # NIL THEN INC(c.tx.age); IF (c.tx.age > 120) OR (c.tx.phase = 0) THEN FailTransfer(c, c.tx) END END;
  IF c.rx # NIL THEN INC(c.rx.age); IF c.rx.age > 120 THEN Reject(c, c.rx.id, "remote-server-timeout"); FailTransfer(c, c.rx) END END;
  FOR i := 0 TO 3 DO
    p := c.pending[i];
    IF p # NIL THEN
      INC(p.age);
      IF p.age > 120 THEN
        IF ~Notify(c, p.token, failed, 0, I.Copy8("image"), I.Copy8("Image request timed out."), NIL) THEN END;
        c.pending[i] := NIL
      END
    END
  END
END Tick;

PROCEDURE Free*(VAR c: Context);
  VAR i: LONGINT;
BEGIN
  IF c = NIL THEN RETURN END;
  Disconnect(c); WHILE c.event # NIL DO DropEvent(c) END;
  FOR i := 0 TO cacheEntries-1 DO Release(c.cache[i]) END; c := NIL
END Free;

PROCEDURE Memory*(): LONGINT;
BEGIN RETURN memory END Memory;

END BarevImages.
