MODULE BarevFileStanzas;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Bounded SI file offers and direct XEP-0065 streamhosts. *)

IMPORT I := XmppItems, T := XmppTypes, S := LongStrings, A := BarevAddress, IntStr;

CONST
  siURI* = "http://jabber.org/protocol/si";
  fileURI* = "http://jabber.org/protocol/si/profile/file-transfer";
  streamURI* = "http://jabber.org/protocol/bytestreams";
  featureURI = "http://jabber.org/protocol/feature-neg"; dataURI = "jabber:x:data";
  portMin* = 50000; portMax* = 50049; maxFileBytes* = 2147483647;
  maxNameBytes* = 255; maxIDBytes* = 128;

PROCEDURE Attribute*(item: I.Item; name: ARRAY OF CHAR): I.Bytes;
  VAR value: T.String;
BEGIN
  IF item = NIL THEN RETURN NIL END;
  value := item.GetAttribute("", name); IF value = NIL THEN RETURN NIL END;
  RETURN I.UTF8Bytes(value^)
END Attribute;

PROCEDURE Unique*(parent: I.Item; uri, name: ARRAY OF CHAR): I.Item;
  VAR content: I.Content; found: I.Item;
BEGIN
  IF parent = NIL THEN RETURN NIL END;
  content := parent.content; found := NIL;
  WHILE content # NIL DO
    IF (content.element # NIL) & (content.element.namespaceURI^ = uri) & S.Equal8(content.element.name^, name) THEN
      IF found # NIL THEN RETURN NIL END;
      found := content.element
    END;
    content := content.next
  END;
  RETURN found
END Unique;

PROCEDURE ID*(text: I.Bytes): BOOLEAN;
BEGIN RETURN (text # NIL) & (S.Length8(text^) > 0) & (S.Length8(text^) <= maxIDBytes) END ID;

PROCEDURE Name*(text: ARRAY OF CHAR): BOOLEAN;
  VAR i, n: LONGINT; utf: T.String;
BEGIN
  n := S.Length8(text);
  IF (n = 0) OR (n > maxNameBytes) OR (text = ".") OR (text = "..") THEN RETURN FALSE END;
  utf := I.UTF8(text); IF utf = NIL THEN RETURN FALSE END;
  FOR i := 0 TO n-1 DO
    IF (ORD(text[i]) < 32) OR (text[i] = 7FX) OR (text[i] = "/") OR (text[i] = "\") OR (text[i] = ":") THEN RETURN FALSE END
  END;
  RETURN TRUE
END Name;

PROCEDURE Number*(text: I.Bytes; VAR number: LONGINT): BOOLEAN;
  VAR i, digit: LONGINT;
BEGIN
  number := 0; IF (text = NIL) OR (text[0] = 0X) OR (S.Length8(text^) > 10) THEN RETURN FALSE END;
  FOR i := 0 TO S.Length8(text^)-1 DO
    digit := ORD(text[i])-ORD("0");
    IF (digit < 0) OR (digit > 9) OR (number > (maxFileBytes-digit) DIV 10) THEN RETURN FALSE END;
    number := number*10+digit
  END;
  RETURN TRUE
END Number;

PROCEDURE SameIdentity*(left, right: ARRAY OF CHAR): BOOLEAN;
  VAR a, b: ARRAY A.maxIdentityBytes OF CHAR; ip: A.IP;
BEGIN RETURN A.Identity(left, a, ip) & A.Identity(right, b, ip) & (a = b) END SameIdentity;

PROCEDURE MethodFor*(item: I.Item; offer: BOOLEAN; method: ARRAY OF CHAR): BOOLEAN;
  VAR si, feature, form, field, value: I.Item; content: I.Content; text, kind, variable: I.Bytes; found: BOOLEAN; wide: T.String;
BEGIN
  si := Unique(item, siURI, "si"); feature := Unique(si, featureURI, "feature");
  form := Unique(feature, dataURI, "x"); kind := Attribute(form, "type");
  IF (kind = NIL) OR (offer & (kind^ # "form")) OR (~offer & (kind^ # "submit")) THEN RETURN FALSE END;
  field := Unique(form, dataURI, "field"); variable := Attribute(field, "var");
  IF (variable = NIL) OR (variable^ # "stream-method") THEN RETURN FALSE END;
  IF ~offer THEN
    value := Unique(field, dataURI, "value");
    IF value = NIL THEN RETURN FALSE END;
    wide := value.Text(); text := I.UTF8Bytes(wide^); RETURN (text # NIL) & (text^ = method)
  END;
  content := field.content; found := FALSE;
  WHILE content # NIL DO
    value := content.element;
    IF (value # NIL) & (value.namespaceURI^ = dataURI) & S.Equal8(value.name^, "option") THEN
      value := Unique(value, dataURI, "value");
      IF value # NIL THEN
        wide := value.Text(); text := I.UTF8Bytes(wide^);
        IF (text # NIL) & (text^ = method) THEN found := TRUE END
      END
    END;
    content := content.next
  END;
  RETURN found
END MethodFor;

PROCEDURE ReadOffer*(item: I.Item; VAR sid, name: I.Bytes; VAR size: LONGINT): BOOLEAN;
  VAR si, file: I.Item; profile: I.Bytes;
BEGIN
  si := Unique(item, siURI, "si"); profile := Attribute(si, "profile"); sid := Attribute(si, "id");
  file := Unique(si, fileURI, "file"); name := Attribute(file, "name");
  RETURN ID(sid) & (profile # NIL) & (profile^ = fileURI) & (name # NIL) & Name(name^) &
    Number(Attribute(file, "size"), size) & MethodFor(item, TRUE, streamURI)
END ReadOffer;

PROCEDURE Accepted*(item: I.Item): BOOLEAN;
BEGIN RETURN MethodFor(item, FALSE, streamURI) END Accepted;

PROCEDURE ReadHost*(item: I.Item; peer: ARRAY OF CHAR; VAR sid, host: I.Bytes; VAR port: LONGINT): BOOLEAN;
  VAR query, entry: I.Item; content: I.Content; jid, mode: I.Bytes; ip, expected: A.IP; canonical: ARRAY A.maxIdentityBytes OF CHAR;
BEGIN
  query := Unique(item, streamURI, "query"); sid := Attribute(query, "sid"); mode := Attribute(query, "mode");
  IF ~ID(sid) OR ((mode # NIL) & (mode^ # "tcp")) OR ~A.Identity(peer, canonical, expected) THEN RETURN FALSE END;
  content := query.content;
  WHILE content # NIL DO
    entry := content.element;
    IF (entry # NIL) & (entry.namespaceURI^ = streamURI) & S.Equal8(entry.name^, "streamhost") THEN
      host := Attribute(entry, "host"); jid := Attribute(entry, "jid");
      IF (host # NIL) & (jid # NIL) & SameIdentity(jid^, peer) & A.ParseIP(host^, ip) &
         A.Yggdrasil(ip) & A.Equal(ip, expected) & Number(Attribute(entry, "port"), port) &
         (port >= portMin) & (port <= portMax) THEN RETURN TRUE END
    END;
    content := content.next
  END;
  RETURN FALSE
END ReadHost;

PROCEDURE Used*(item: I.Item; local: ARRAY OF CHAR): BOOLEAN;
  VAR value: I.Bytes;
BEGIN
  value := Attribute(Unique(Unique(item, streamURI, "query"), streamURI, "streamhost-used"), "jid");
  RETURN (value # NIL) & SameIdentity(value^, local)
END Used;

PROCEDURE Attr*(item: I.Item; name, text: ARRAY OF CHAR);
  VAR value: T.String;
BEGIN value := I.UTF8(text); item.SetParam(name, value^) END Attr;

PROCEDURE Child(parent: I.Item; name, uri: ARRAY OF CHAR): I.Item;
  VAR child: I.Item;
BEGIN child := I.New(name, uri); parent.AddChild(child); RETURN child END Child;

PROCEDURE Packet*(id, kind: ARRAY OF CHAR): I.Item;
  VAR item: I.Item;
BEGIN item := I.New("iq", "jabber:client"); Attr(item, "id", id); Attr(item, "type", kind); RETURN item END Packet;

PROCEDURE SelectionFor*(si: I.Item; offer: BOOLEAN; method: ARRAY OF CHAR);
  VAR field, value: I.Item; text: T.String;
BEGIN
  field := Child(si, "feature", featureURI); field := Child(field, "x", dataURI);
  IF offer THEN Attr(field, "type", "form") ELSE Attr(field, "type", "submit") END;
  field := Child(field, "field", dataURI); Attr(field, "var", "stream-method");
  IF offer THEN Attr(field, "type", "list-single"); field := Child(field, "option", dataURI) END;
  value := Child(field, "value", dataURI); text := I.Latin1(method); value.AddText(text^, 0, S.Length(text^))
END SelectionFor;

PROCEDURE Offer*(id, sid, name: ARRAY OF CHAR; size: LONGINT): I.Item;
  VAR item, si, file: I.Item; number: ARRAY 32 OF CHAR;
BEGIN
  item := Packet(id, "set"); si := Child(item, "si", siURI); Attr(si, "id", sid); Attr(si, "profile", fileURI);
  file := Child(si, "file", fileURI); Attr(file, "name", name); IntStr.IntToStr(size, number); Attr(file, "size", number);
  SelectionFor(si, TRUE, streamURI); RETURN item
END Offer;

PROCEDURE Accept*(id: ARRAY OF CHAR): I.Item;
  VAR item, si: I.Item;
BEGIN item := Packet(id, "result"); si := Child(item, "si", siURI); SelectionFor(si, FALSE, streamURI); RETURN item END Accept;

PROCEDURE Host*(id, sid, local, address: ARRAY OF CHAR; port: LONGINT): I.Item;
  VAR item, query, host: I.Item; number: ARRAY 32 OF CHAR;
BEGIN
  item := Packet(id, "set"); query := Child(item, "query", streamURI); Attr(query, "sid", sid); Attr(query, "mode", "tcp");
  host := Child(query, "streamhost", streamURI); Attr(host, "jid", local); Attr(host, "host", address);
  IntStr.IntToStr(port, number); Attr(host, "port", number); RETURN item
END Host;

PROCEDURE Confirm*(id, peer: ARRAY OF CHAR): I.Item;
  VAR item, query, used: I.Item;
BEGIN
  item := Packet(id, "result"); query := Child(item, "query", streamURI);
  used := Child(query, "streamhost-used", streamURI); Attr(used, "jid", peer); RETURN item
END Confirm;

PROCEDURE Reject*(id, condition: ARRAY OF CHAR): I.Item;
  VAR item, error, child: I.Item;
BEGIN
  item := Packet(id, "error"); error := Child(item, "error", "jabber:client"); Attr(error, "type", "cancel");
  child := Child(error, condition, "urn:ietf:params:xml:ns:xmpp-stanzas"); RETURN item
END Reject;

END BarevFileStanzas.
