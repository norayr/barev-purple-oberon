MODULE BarevFeedAccess;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT A := BarevAddress, Items := XmppItems, T := XmppTypes;

CONST
  denied* = 0; open* = 1; roster* = 2; whitelist* = 3;
  maxGroups* = 16; maxMembers* = 256; maxGroupBytes* = 256;
  publicReader = 1; privateReader = 2;

TYPE
  Name* = ARRAY A.maxIdentityBytes OF CHAR;
  Key = ARRAY 32 OF CHAR;
  Node* = POINTER TO NodeDesc;
  NodeDesc* = RECORD
    model, count: LONGINT;
    names: ARRAY maxMembers OF Name
  END;
  Contact* = POINTER TO ContactDesc;
  ContactDesc* = RECORD
    peer: Name; pin: Key;
    count: LONGINT; groups: ARRAY maxGroups OF Name
  END;
  Reader* = RECORD
    kind: LONGINT; peer: Name; key: Key
  END;

PROCEDURE Group(name: ARRAY OF CHAR): BOOLEAN;
VAR i, n: LONGINT; text: T.String;
BEGIN
  n := 0;
  WHILE (n < LEN(name)) & (name[n] # 0X) DO INC(n) END;
  IF (n = 0) OR (n = LEN(name)) OR (n > maxGroupBytes) THEN RETURN FALSE END;
  text := Items.UTF8(name); IF text = NIL THEN RETURN FALSE END;
  i := 0;
  WHILE text[i] # 0 DO
    IF (text[i] < 32) OR ((text[i] >= 127) & (text[i] <= 159)) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END Group;

PROCEDURE Canonical(name: ARRAY OF CHAR; VAR result: Name): BOOLEAN;
VAR ip: A.IP;
BEGIN RETURN A.Identity(name, result, ip) END Canonical;

(* Node policies and contact snapshots are immutable. NIL always denies private access. *)
PROCEDURE NewNode*(model: LONGINT; VAR names: ARRAY OF Name; count: LONGINT): Node;
VAR node: Node; i, j: LONGINT;
BEGIN
  IF (count < 0) OR (count > LEN(names)) OR (count > maxMembers) OR
     ((model # open) & (model # roster) & (model # whitelist)) OR
     ((model = open) & (count # 0)) OR ((model = roster) & (count > maxGroups)) THEN RETURN NIL END;
  NEW(node); node.model := model; node.count := count;
  FOR i := 0 TO count-1 DO
    IF model = roster THEN
      IF ~Group(names[i]) THEN RETURN NIL END;
      COPY(names[i], node.names[i])
    ELSIF ~Canonical(names[i], node.names[i]) THEN RETURN NIL
    END;
    FOR j := 0 TO i-1 DO IF node.names[i] = node.names[j] THEN RETURN NIL END END
  END;
  RETURN node
END NewNode;

(* Supply the current manual chat authorization and verified pin, not wire attributes. *)
PROCEDURE NewContact*(peer: ARRAY OF CHAR; VAR pin: ARRAY OF CHAR; authorized: BOOLEAN;
    VAR groups: ARRAY OF Name; count: LONGINT): Contact;
VAR contact: Contact; i, j: LONGINT;
BEGIN
  IF ~authorized OR (LEN(pin) # 32) OR (count < 0) OR (count > LEN(groups)) OR
     (count > maxGroups) THEN RETURN NIL END;
  NEW(contact);
  IF ~Canonical(peer, contact.peer) THEN RETURN NIL END;
  FOR i := 0 TO 31 DO contact.pin[i] := pin[i] END;
  contact.count := count;
  FOR i := 0 TO count-1 DO
    IF ~Group(groups[i]) THEN RETURN NIL END;
    COPY(groups[i], contact.groups[i]);
    FOR j := 0 TO i-1 DO IF contact.groups[i] = contact.groups[j] THEN RETURN NIL END END
  END;
  RETURN contact
END NewContact;

PROCEDURE Close*(VAR reader: Reader);
VAR i: LONGINT;
BEGIN
  reader.kind := denied; reader.peer[0] := 0X;
  FOR i := 0 TO 31 DO reader.key[i] := 0X END
END Close;

(* Call only after the public transport and anonymous resource binding are ready. *)
PROCEDURE Anonymous*(VAR reader: Reader);
BEGIN Close(reader); reader.kind := publicReader END Anonymous;

(* Capture the key from a live mutual TLS/SASL EXTERNAL session, never its claimed JID. *)
PROCEDURE Authenticate*(VAR reader: Reader; peer: ARRAY OF CHAR;
    VAR capturedKey: ARRAY OF CHAR; mutualTLS, external: BOOLEAN): BOOLEAN;
VAR i: LONGINT;
BEGIN
  Close(reader);
  IF ~mutualTLS OR ~external OR (LEN(capturedKey) # 32) OR
     ~Canonical(peer, reader.peer) THEN RETURN FALSE END;
  FOR i := 0 TO 31 DO reader.key[i] := capturedKey[i] END;
  reader.kind := privateReader; RETURN TRUE
END Authenticate;

PROCEDURE Current(VAR reader: Reader; contact: Contact): BOOLEAN;
VAR i, different: LONGINT;
BEGIN
  IF (reader.kind # privateReader) OR (contact = NIL) OR (reader.peer # contact.peer) THEN RETURN FALSE END;
  different := 0;
  FOR i := 0 TO 31 DO IF reader.key[i] # contact.pin[i] THEN INC(different) END END;
  RETURN different = 0
END Current;

(* Use the current contact snapshot for discovery, retrieval and each queued notification. *)
PROCEDURE CanRead*(node: Node; VAR reader: Reader; contact: Contact): BOOLEAN;
VAR i, j: LONGINT;
BEGIN
  IF (node = NIL) OR ((reader.kind # publicReader) & (reader.kind # privateReader)) THEN RETURN FALSE END;
  IF node.model = open THEN RETURN TRUE END;
  IF ~Current(reader, contact) THEN RETURN FALSE END;
  IF node.model = whitelist THEN
    FOR i := 0 TO node.count-1 DO IF reader.peer = node.names[i] THEN RETURN TRUE END END
  ELSIF node.model = roster THEN
    FOR i := 0 TO node.count-1 DO
      FOR j := 0 TO contact.count-1 DO
        IF node.names[i] = contact.groups[j] THEN RETURN TRUE END
      END
    END
  END;
  RETURN FALSE
END CanRead;

PROCEDURE Model*(node: Node): LONGINT;
BEGIN IF node = NIL THEN RETURN denied END; RETURN node.model END Model;

PROCEDURE CopyPolicy*(node: Node; VAR names: ARRAY OF Name; VAR count: LONGINT): BOOLEAN;
VAR i: LONGINT;
BEGIN
  IF (node = NIL) OR (node.model = denied) OR (LEN(names) < node.count) THEN RETURN FALSE END;
  FOR i := 0 TO node.count-1 DO names[i] := node.names[i] END;
  count := node.count; RETURN TRUE
END CopyPolicy;

END BarevFeedAccess.
