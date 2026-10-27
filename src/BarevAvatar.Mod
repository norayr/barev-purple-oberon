MODULE BarevAvatar;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Bounded vCard photos. SHA-1 identifies image bytes for XEP-0153 caching;
   it does not authenticate an image or peer. All arithmetic is overflow-free. *)

IMPORT Items := XmppItems, T := XmppTypes, S := LongStrings, SHA := BarevSHA1;

CONST
  vcardURI* = "vcard-temp"; updateURI* = "vcard-temp:x:update";
  maxBytes* = 65535; maxDimension* = 2048; requestSeconds* = 15;
  maxTextBytes* = 98304;

TYPE
  Image* = POINTER TO RECORD data*: Items.Bytes; length*: LONGINT; hash*, mime*: Items.Bytes END;

VAR alphabet: ARRAY 65 OF CHAR;

PROCEDURE Hash*(bytes: ARRAY OF CHAR; length: LONGINT): Items.Bytes;
BEGIN
  RETURN SHA.Hash(bytes, length)
END Hash;

PROCEDURE MIME(bytes: ARRAY OF CHAR; length: LONGINT): Items.Bytes;
  VAR at, marker, count, width, height, components, start: LONGINT; frame, data, scan: BOOLEAN;
BEGIN
  IF (length >= 33) & (bytes[0] = 89X) & (bytes[1] = "P") & (bytes[2] = "N") & (bytes[3] = "G") &
     (bytes[4] = 0DX) & (bytes[5] = 0AX) & (bytes[6] = 1AX) & (bytes[7] = 0AX) &
     (bytes[8] = 0X) & (bytes[9] = 0X) & (bytes[10] = 0X) & (bytes[11] = 0DX) &
     (bytes[12] = "I") & (bytes[13] = "H") & (bytes[14] = "D") & (bytes[15] = "R") THEN
    IF (bytes[16] # 0X) OR (bytes[17] # 0X) OR (bytes[20] # 0X) OR (bytes[21] # 0X) THEN RETURN NIL END;
    width := ORD(bytes[18])*256+ORD(bytes[19]); height := ORD(bytes[22])*256+ORD(bytes[23]);
    IF (width < 1) OR (height < 1) OR (width > maxDimension) OR (height > maxDimension) THEN RETURN NIL END;
    at := 33; data := FALSE;
    WHILE at+12 <= length DO
      IF (bytes[at] # 0X) OR (bytes[at+1] # 0X) THEN RETURN NIL END;
      count := ORD(bytes[at+2])*256+ORD(bytes[at+3]);
      IF count > length-at-12 THEN RETURN NIL END;
      IF ((bytes[at+4] = "a") & (bytes[at+5] = "c") & (bytes[at+6] = "T") & (bytes[at+7] = "L")) OR
         ((bytes[at+4] = "I") & (bytes[at+5] = "H") & (bytes[at+6] = "D") & (bytes[at+7] = "R")) THEN RETURN NIL END;
      IF (bytes[at+4] = "I") & (bytes[at+5] = "D") & (bytes[at+6] = "A") & (bytes[at+7] = "T") THEN data := TRUE END;
      IF (bytes[at+4] = "I") & (bytes[at+5] = "E") & (bytes[at+6] = "N") & (bytes[at+7] = "D") THEN
        IF data & (count = 0) & (at+12 = length) THEN RETURN Items.Copy8("image/png") ELSE RETURN NIL END
      END;
      INC(at, count+12)
    END;
    RETURN NIL
  END;
  IF (length >= 4) & (bytes[0] = 0FFX) & (bytes[1] = 0D8X) THEN
    at := 2; frame := FALSE; data := FALSE;
    WHILE at+2 <= length DO
      IF bytes[at] # 0FFX THEN RETURN NIL END;
      WHILE (at < length) & (bytes[at] = 0FFX) DO INC(at) END;
      IF at >= length THEN RETURN NIL END;
      marker := ORD(bytes[at]); INC(at);
      IF marker = 0D9H THEN
        IF frame & data & (at = length) THEN RETURN Items.Copy8("image/jpeg") ELSE RETURN NIL END
      END;
      IF (marker = 0D8H) OR (marker = 0DCH) OR (at+2 > length) THEN RETURN NIL END;
      count := ORD(bytes[at])*256+ORD(bytes[at+1]);
      IF (count < 2) OR (count > length-at) THEN RETURN NIL END;
      IF (marker >= 0C0H) & (marker <= 0C2H) THEN
        IF frame OR (count < 8) OR (bytes[at+2] # 8X) THEN RETURN NIL END;
        height := ORD(bytes[at+3])*256+ORD(bytes[at+4]); width := ORD(bytes[at+5])*256+ORD(bytes[at+6]);
        components := ORD(bytes[at+7]);
        IF (width < 1) OR (height < 1) OR (width > maxDimension) OR (height > maxDimension) OR
           ((components # 1) & (components # 3)) OR (count # 8+3*components) THEN RETURN NIL END;
        frame := TRUE
      ELSIF (marker >= 0C3H) & (marker <= 0CFH) & (marker # 0C4H) & (marker # 0CCH) THEN RETURN NIL
      END;
      INC(at, count);
      IF marker = 0DAH THEN
        IF ~frame THEN RETURN NIL END;
        data := TRUE; scan := TRUE;
        WHILE (at < length) & scan DO
          IF bytes[at] # 0FFX THEN INC(at)
          ELSE
            start := at;
            WHILE (at < length) & (bytes[at] = 0FFX) DO INC(at) END;
            IF at = length THEN RETURN NIL END;
            marker := ORD(bytes[at]);
            IF (marker = 0) OR ((marker >= 0D0H) & (marker <= 0D7H)) THEN INC(at)
            ELSE at := start; scan := FALSE
            END
          END
        END
      END
    END
  END;
  RETURN NIL
END MIME;

PROCEDURE New*(bytes: ARRAY OF CHAR; length: LONGINT): Image;
  VAR image: Image; mime: Items.Bytes; i: LONGINT;
BEGIN
  IF (length <= 0) OR (length > LEN(bytes)) OR (length > maxBytes) THEN RETURN NIL END;
  mime := MIME(bytes, length); IF mime = NIL THEN RETURN NIL END;
  NEW(image); NEW(image.data, length); image.length := length; image.mime := mime;
  FOR i := 0 TO length-1 DO image.data[i] := bytes[i] END;
  image.hash := Hash(bytes, length); RETURN image
END New;

PROCEDURE Encode*(bytes: ARRAY OF CHAR; length: LONGINT): Items.Bytes;
  VAR text: Items.Bytes; at, out, a, b, c: LONGINT;
BEGIN
  IF (length < 0) OR (length > LEN(bytes)) OR (length > maxBytes) THEN RETURN NIL END;
  NEW(text, ((length+2) DIV 3)*4+1); at := 0; out := 0;
  WHILE at < length DO
    a := ORD(bytes[at]); b := 0; c := 0;
    IF at+1 < length THEN b := ORD(bytes[at+1]) END;
    IF at+2 < length THEN c := ORD(bytes[at+2]) END;
    text[out] := alphabet[a DIV 4]; text[out+1] := alphabet[(a MOD 4)*16+b DIV 16];
    IF at+1 < length THEN text[out+2] := alphabet[(b MOD 16)*4+c DIV 64] ELSE text[out+2] := "=" END;
    IF at+2 < length THEN text[out+3] := alphabet[c MOD 64] ELSE text[out+3] := "=" END;
    INC(at, 3); INC(out, 4)
  END;
  text[out] := 0X; RETURN text
END Encode;

PROCEDURE Decode*(text: ARRAY OF CHAR; VAR length: LONGINT): Items.Bytes;
  VAR bytes: Items.Bytes; group: ARRAY 4 OF LONGINT; at, n, v, pads, count: LONGINT; ch: CHAR; ended: BOOLEAN;
BEGIN
  length := 0; NEW(bytes, maxBytes); at := 0; n := 0; ended := FALSE;
  WHILE (at < LEN(text)) & (at < maxTextBytes) & (text[at] # 0X) DO
    ch := text[at]; INC(at);
    IF (ch # " ") & (ch # 9X) & (ch # 0AX) & (ch # 0DX) THEN
      IF ended THEN RETURN NIL END;
      v := 0; WHILE (v < 64) & (alphabet[v] # ch) DO INC(v) END;
      IF (v = 64) & (ch # "=") THEN RETURN NIL END;
      group[n] := v; INC(n);
      IF n = 4 THEN
        IF (group[0] = 64) OR (group[1] = 64) THEN RETURN NIL END;
        pads := 0;
        IF group[3] = 64 THEN INC(pads); group[3] := 0 END;
        IF group[2] = 64 THEN IF pads = 0 THEN RETURN NIL END; INC(pads); group[2] := 0 END;
        IF ((pads = 2) & (group[1] MOD 16 # 0)) OR ((pads = 1) & (group[2] MOD 4 # 0)) THEN RETURN NIL END;
        count := 3-pads; IF count > maxBytes-length THEN RETURN NIL END;
        bytes[length] := CHR(group[0]*4+group[1] DIV 16);
        IF count > 1 THEN bytes[length+1] := CHR((group[1] MOD 16)*16+group[2] DIV 4) END;
        IF count > 2 THEN bytes[length+2] := CHR((group[2] MOD 4)*64+group[3]) END;
        INC(length, count); ended := pads # 0; n := 0
      END
    END
  END;
  IF (at = LEN(text)) OR (text[at] # 0X) OR (n # 0) THEN RETURN NIL END;
  RETURN bytes
END Decode;

PROCEDURE Child(parent: Items.Item; uri, name: ARRAY OF CHAR; VAR child: Items.Item): BOOLEAN;
  VAR content: Items.Content;
BEGIN
  child := NIL; content := parent.content;
  WHILE content # NIL DO
    IF (content.element # NIL) & (content.element.namespaceURI^ = uri) & S.Equal8(content.element.name^, name) THEN
      IF child # NIL THEN RETURN FALSE END;
      child := content.element
    END;
    content := content.next
  END;
  RETURN TRUE
END Child;

PROCEDURE Plain(item: Items.Item; maximum: LONGINT; VAR bytes: Items.Bytes): BOOLEAN;
  VAR content: Items.Content; text: T.String;
BEGIN
  bytes := Items.Copy8(""); IF item = NIL THEN RETURN TRUE END;
  content := item.content;
  WHILE content # NIL DO IF content.element # NIL THEN RETURN FALSE END; content := content.next END;
  text := item.Text(); bytes := Items.UTF8Bytes(text^);
  RETURN (bytes # NIL) & (S.Length8(bytes^) <= maximum)
END Plain;

PROCEDURE ReadUpdate*(item: Items.Item; VAR present: BOOLEAN; VAR hash: Items.Bytes): BOOLEAN;
  VAR update, photo: Items.Item; i: LONGINT;
BEGIN
  present := FALSE; hash := NIL;
  IF ~Child(item, updateURI, "x", update) THEN RETURN FALSE END;
  IF update = NIL THEN RETURN TRUE END;
  IF ~Child(update, updateURI, "photo", photo) THEN RETURN FALSE END;
  IF photo = NIL THEN RETURN TRUE END;
  present := TRUE;
  IF ~Plain(photo, 40, hash) THEN RETURN FALSE END;
  IF hash[0] = 0X THEN RETURN TRUE END;
  IF S.Length8(hash^) # 40 THEN RETURN FALSE END;
  FOR i := 0 TO 39 DO
    IF (hash[i] >= "A") & (hash[i] <= "F") THEN hash[i] := CHR(ORD(hash[i])+32) END;
    IF ~(((hash[i] >= "0") & (hash[i] <= "9")) OR ((hash[i] >= "a") & (hash[i] <= "f"))) THEN RETURN FALSE END
  END;
  RETURN TRUE
END ReadUpdate;

PROCEDURE ReadCard*(item: Items.Item; VAR image: Image): BOOLEAN;
  VAR card, photo, binary, mime: Items.Item; text, bytes, kind: Items.Bytes; length: LONGINT;
BEGIN
  image := NIL;
  IF ~Child(item, vcardURI, "vCard", card) OR (card = NIL) THEN RETURN FALSE END;
  IF ~Child(card, vcardURI, "PHOTO", photo) THEN RETURN FALSE END;
  IF photo = NIL THEN RETURN TRUE END;
  IF ~Child(photo, vcardURI, "BINVAL", binary) OR ~Child(photo, vcardURI, "TYPE", mime) THEN RETURN FALSE END;
  IF (binary = NIL) OR ~Plain(binary, maxTextBytes, text) OR ~Plain(mime, 32, kind) THEN RETURN FALSE END;
  bytes := Decode(text^, length); IF (bytes = NIL) OR (length = 0) THEN RETURN FALSE END;
  image := New(bytes^, length);
  IF image = NIL THEN RETURN FALSE END;
  RETURN (kind[0] = 0X) OR (kind^ = image.mime^)
END ReadCard;

PROCEDURE Add(parent: Items.Item; uri, name: ARRAY OF CHAR; bytes: Items.Bytes);
  VAR child: Items.Item; text: T.String;
BEGIN
  child := Items.New(name, uri); text := Items.Latin1(bytes^);
  IF text[0] # 0 THEN child.AddText(text^, 0, S.Length(text^)) END;
  parent.AddChild(child)
END Add;

PROCEDURE Advertise*(presence: Items.Item; image: Image);
  VAR update: Items.Item; hash: Items.Bytes;
BEGIN
  update := Items.New("x", updateURI);
  IF image = NIL THEN hash := Items.Copy8("") ELSE hash := image.hash END;
  Add(update, updateURI, "photo", hash); presence.AddChild(update)
END Advertise;

PROCEDURE Card*(image: Image; id: T.String): Items.Item;
  VAR reply, card, photo: Items.Item; kind: T.String; binary: Items.Bytes;
BEGIN
  reply := Items.New("iq", "jabber:client"); reply.SetParam("id", id^);
  kind := Items.Latin1("result"); reply.SetParam("type", kind^); card := Items.New("vCard", vcardURI);
  IF image # NIL THEN
    photo := Items.New("PHOTO", vcardURI); Add(photo, vcardURI, "TYPE", image.mime);
    binary := Encode(image.data^, image.length); Add(photo, vcardURI, "BINVAL", binary); card.AddChild(photo)
  END;
  reply.AddChild(card); RETURN reply
END Card;

BEGIN
  COPY("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", alphabet)
END BarevAvatar.
