MODULE TestImages;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Deterministic image-protocol tests without sockets, files or image decoders. *)

IMPORT B := BarevImages, Av := BarevAvatar, F := BarevFileStanzas, I := XmppItems,
  S := LongStrings, Heap, Out;

VAR checks, bad: LONGINT;

PROCEDURE Check(value: BOOLEAN);
BEGIN
  INC(checks);
  IF ~value & (bad = 0) THEN bad := checks; Out.String("Image protocol check failed: "); Out.Int(checks, 0); Out.Ln END
END Check;

PROCEDURE Deliver(from, to: B.Context): BOOLEAN;
  VAR item: I.Item;
BEGIN
  item := B.TakePacket(from); IF item = NIL THEN RETURN FALSE END;
  Check(B.Receive(to, item)); RETURN TRUE
END Deliver;

PROCEDURE Pump(a, b: B.Context);
  VAR work: BOOLEAN; limit: LONGINT;
BEGIN
  limit := 0;
  REPEAT work := Deliver(a, b); work := Deliver(b, a) OR work; INC(limit) UNTIL ~work OR (limit > 1024);
  Check(limit <= 1024)
END Pump;

PROCEDURE Run*(): LONGINT;
  VAR a, b, other: B.Context; raw, padded: I.Bytes; size, token, receiver, i, n: LONGINT;
    item, data, rich, body, img: I.Item; cid, id: I.Bytes; copied: ARRAY 32768 OF CHAR;
BEGIN
  checks := 0; bad := 0; Check(B.Memory() = 0);
  raw := Av.Decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQVDL+DwACFAFmBODefwAAAABJRU5ErkJggg==", size);
  a := B.New(262144, 65536); b := B.New(262144, 65536);
  token := B.Send(a, raw^, size, "pixel.png"); Check(token > 0);
  Pump(a, b); Check((b.event # NIL) & (b.event.kind = B.received) & (b.event.size = size));
  Check(B.ReadEvent(b, copied) = size); FOR i := 0 TO size-1 DO Check(copied[i] = raw[i]) END;
  B.DropEvent(b); Heap.GC(TRUE);
  Check(B.Send(a, raw^, size, "pixel.png") > 0); Check(Deliver(a, b)); Check(B.TakePacket(b) = NIL);
  Check((b.event # NIL) & (b.event.kind = B.received)); B.DropEvent(b);
  B.Free(a); B.Free(b); Check(B.Memory() = 0);

  (* A PNG ancillary chunk exercises several IBB blocks without a pixel decoder. *)
  n := 20000; NEW(padded, size+n+12);
  FOR i := 0 TO size-13 DO padded[i] := raw[i] END;
  padded[size-12] := 0X; padded[size-11] := 0X; padded[size-10] := CHR(n DIV 256); padded[size-9] := CHR(n MOD 256);
  padded[size-8] := "t"; padded[size-7] := "E"; padded[size-6] := "X"; padded[size-5] := "t";
  FOR i := 0 TO n+3 DO padded[size-4+i] := 0X END;
  FOR i := 0 TO 11 DO padded[size+n+i] := raw[size-12+i] END;
  INC(size, n+12);
  a := B.New(262144, 1024); b := B.New(0, 1024);
  Check(B.Send(a, padded^, size, "original.png") > 0); Check(Deliver(a, b));
  Check((a.event # NIL) & (a.event.kind = 5)); B.DropEvent(a);
  Check((b.event # NIL) & (b.event.kind = B.offer)); receiver := b.event.token;
  Check(B.TakePacket(b) = NIL); B.DropEvent(b); Check(B.Accept(b, receiver, TRUE));
  Pump(a, b); Check((b.event # NIL) & (b.event.kind = B.received));
  Check(B.ReadEvent(b, copied) = size); FOR i := 0 TO size-1 DO Check(copied[i] = padded[i]) END;
  Check((a.event # NIL) & (a.event.kind = B.sent)); B.DropEvent(a); B.DropEvent(b);
  Check(B.Progress(a, token) = -1); B.Free(a); B.Free(b); Check(B.Memory() = 0);

  (* A requested object must have the expected content ID and peer-local origin. *)
  a := B.New(262144, 65536); b := B.New(262144, 65536); other := B.New(262144, 65536);
  n := size-20012; Check(B.Send(a, raw^, n, "pixel.png") > 0);
  item := B.TakePacket(a); Check(B.Receive(b, item)); item := B.TakePacket(b);
  data := item.First(B.bobURI, "data"); cid := F.Attribute(data, "cid");
  Check(B.Receive(other, item)); item := B.TakePacket(other); id := F.Attribute(item, "type"); Check(id^ = "error");
  Check(B.Receive(a, F.Packet("unrelated", "result")) = FALSE);
  item := F.Packet("evil", "set"); data := I.New("open", B.ibbURI); F.Attr(data, "sid", "unknown"); item.AddChild(data);
  Check(B.Receive(b, item)); item := B.TakePacket(b); id := F.Attribute(item, "type"); Check(id^ = "error");
  FOR i := 0 TO 120 DO B.Tick(b) END; Check((b.event # NIL) & (b.event.kind = B.failed));
  B.Free(a); B.Free(b); B.Free(other); Check(B.Memory() = 0);

  (* No file paths, over-limit images or untrusted local image IDs are accepted. *)
  a := B.New(262144, 65536);
  Check(B.Send(a, raw^, n, "../secret.png") = 0); Check(B.Send(a, raw^, n, "C:\secret.png") = 0);
  Check(B.Send(a, "not an image", 12, "x.png") = 0);
  item := I.New("message", "jabber:client"); rich := I.New("html", "http://jabber.org/protocol/xhtml-im"); item.AddChild(rich);
  body := I.New("body", "http://www.w3.org/1999/xhtml"); rich.AddChild(body);
  img := I.New("img", "http://www.w3.org/1999/xhtml"); body.AddChild(img); F.Attr(img, "id", "123");
  Check(~B.Receive(a, item)); Check(B.TakePacket(a) = NIL);
  Check(~B.CID("sha1+bad@bob.xmpp.org"));
  B.Free(a); Check(B.Memory() = 0);
  IF bad # 0 THEN RETURN -bad END;
  RETURN checks
END Run;

END TestImages.
