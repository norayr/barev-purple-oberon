MODULE BarevPost;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT A := BarevAddress, Items := XmppItems, T := XmppTypes,
  U := URIParser, URI, US := URIString, Fragment := URIFragmentUnparsed, Error := URIError;

CONST
  maxItemBytes* = 128; maxIDBytes* = 1024; maxTitleBytes* = 256;
  maxTextBytes* = 16384;

TYPE
  Header* = RECORD
    itemID*: ARRAY maxItemBytes+1 OF CHAR;
    id*, replyTo*: ARRAY maxIDBytes+1 OF CHAR;
    owner*: ARRAY 65 OF CHAR;
    author*: ARRAY A.maxIdentityBytes OF CHAR;
    title*: ARRAY maxTitleBytes+1 OF CHAR;
    published*, updated*: ARRAY 21 OF CHAR
  END;
  Post* = POINTER TO PostDesc;
  PostDesc* = RECORD header: Header; text: Items.Bytes; size, length: LONGINT END;

PROCEDURE Length(text: ARRAY OF CHAR): LONGINT;
VAR n: LONGINT;
BEGIN n := 0; WHILE (n < LEN(text)) & (text[n] # 0X) DO INC(n) END; RETURN n END Length;

PROCEDURE Hex(ch: CHAR): LONGINT;
BEGIN
  IF (ch >= "0") & (ch <= "9") THEN RETURN ORD(ch)-ORD("0") END;
  IF (ch >= "a") & (ch <= "f") THEN RETURN ORD(ch)-ORD("a")+10 END;
  RETURN -1
END Hex;

PROCEDURE Owner*(text: ARRAY OF CHAR): BOOLEAN;
VAR i: LONGINT;
BEGIN
  IF (LEN(text) < 65) OR (Length(text) # 64) THEN RETURN FALSE END;
  FOR i := 0 TO 63 DO IF Hex(text[i]) < 0 THEN RETURN FALSE END END;
  RETURN TRUE
END Owner;

PROCEDURE Token*(text: ARRAY OF CHAR; maximum: LONGINT): BOOLEAN;
VAR n, i: LONGINT; ch: CHAR;
BEGIN
  n := Length(text);
  IF (n = 0) OR (n = LEN(text)) OR (n > maximum) THEN RETURN FALSE END;
  FOR i := 0 TO n-1 DO
    ch := text[i];
    IF ~(((ch >= "a") & (ch <= "z")) OR ((ch >= "A") & (ch <= "Z")) OR
        ((ch >= "0") & (ch <= "9")) OR (ch = "-") OR (ch = "_") OR (ch = ".")) THEN RETURN FALSE END
  END;
  RETURN TRUE
END Token;

PROCEDURE Text*(text: ARRAY OF CHAR; maximum: LONGINT; empty: BOOLEAN): BOOLEAN;
VAR n, i: LONGINT; units: T.String;
BEGIN
  n := Length(text);
  IF (n = LEN(text)) OR (n > maximum) OR ((n = 0) & ~empty) THEN RETURN FALSE END;
  units := Items.UTF8(text); IF units = NIL THEN RETURN FALSE END;
  i := 0;
  WHILE units[i] # 0 DO
    IF ((units[i] < 32) & (units[i] # 9) & (units[i] # 10) & (units[i] # 13)) OR
        (units[i] = 0FFFEH) OR (units[i] = 0FFFFH) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END Text;

PROCEDURE Reference*(text: ARRAY OF CHAR; empty: BOOLEAN): BOOLEAN;
VAR n, i: LONGINT; reference: URI.Reference; error: Error.Msg; scratch: URI.StringPtr;
BEGIN
  n := Length(text);
  IF (n = LEN(text)) OR (n > maxIDBytes) THEN RETURN FALSE END;
  IF n = 0 THEN RETURN empty END;
  FOR i := 0 TO n-1 DO
    IF (text[i] <= " ") OR (text[i] >= 7FX) THEN RETURN FALSE END
  END;
  (* The URI parser temporarily terminates the URI before its fragment. *)
  scratch := US.Copy(text);
  reference := U.NewReference(scratch^, NIL, Fragment.New(US.Copy("")), error);
  RETURN (error = NIL) & (reference # NIL) & (reference.uri.schemeId # NIL)
END Reference;

PROCEDURE Timestamp*(stamp: ARRAY OF CHAR): BOOLEAN;
VAR i, year, month, day, hour, minute, second, days: LONGINT;
BEGIN
  IF (LEN(stamp) < 21) OR (Length(stamp) # 20) THEN RETURN FALSE END;
  IF (stamp[4] # "-") OR (stamp[7] # "-") OR (stamp[10] # "T") OR
      (stamp[13] # ":") OR (stamp[16] # ":") OR (stamp[19] # "Z") THEN RETURN FALSE END;
  FOR i := 0 TO 18 DO
    IF (i # 4) & (i # 7) & (i # 10) & (i # 13) & (i # 16) &
        ((stamp[i] < "0") OR (stamp[i] > "9")) THEN RETURN FALSE END
  END;
  year := 0; FOR i := 0 TO 3 DO year := 10*year+ORD(stamp[i])-ORD("0") END;
  month := 10*(ORD(stamp[5])-ORD("0"))+ORD(stamp[6])-ORD("0");
  day := 10*(ORD(stamp[8])-ORD("0"))+ORD(stamp[9])-ORD("0");
  hour := 10*(ORD(stamp[11])-ORD("0"))+ORD(stamp[12])-ORD("0");
  minute := 10*(ORD(stamp[14])-ORD("0"))+ORD(stamp[15])-ORD("0");
  second := 10*(ORD(stamp[17])-ORD("0"))+ORD(stamp[18])-ORD("0");
  IF (year = 0) OR (month < 1) OR (month > 12) OR (hour > 23) OR (minute > 59) OR (second > 59) THEN RETURN FALSE END;
  days := 31;
  IF month = 2 THEN
    days := 28;
    IF (year MOD 4 = 0) & ((year MOD 100 # 0) OR (year MOD 400 = 0)) THEN days := 29 END
  ELSIF (month = 4) OR (month = 6) OR (month = 9) OR (month = 11) THEN days := 30
  END;
  RETURN (day >= 1) & (day <= days)
END Timestamp;

(* The caller supplies 16 fresh cryptographically random bytes for each new post. *)
PROCEDURE Identifiers*(VAR entropy: ARRAY OF CHAR; VAR itemID, atomID: ARRAY OF CHAR): BOOLEAN;
VAR i, j, value: LONGINT; digits: ARRAY 17 OF CHAR;
BEGIN
  IF (LEN(entropy) # 16) OR (LEN(itemID) < 33) OR (LEN(atomID) < 46) THEN RETURN FALSE END;
  digits := "0123456789abcdef";
  FOR i := 0 TO 15 DO
    value := ORD(entropy[i]);
    IF i = 6 THEN value := 64+value MOD 16 ELSIF i = 8 THEN value := 128+value MOD 64 END;
    itemID[2*i] := digits[value DIV 16]; itemID[2*i+1] := digits[value MOD 16]
  END;
  itemID[32] := 0X; COPY("urn:uuid:", atomID); j := 9;
  FOR i := 0 TO 31 DO
    IF (i = 8) OR (i = 12) OR (i = 16) OR (i = 20) THEN atomID[j] := "-"; INC(j) END;
    atomID[j] := itemID[i]; INC(j)
  END;
  atomID[j] := 0X; RETURN TRUE
END Identifiers;

PROCEDURE New*(VAR header: Header; text: ARRAY OF CHAR): Post;
VAR post: Post; canonical: ARRAY A.maxIdentityBytes OF CHAR; ip: A.IP;
BEGIN
  IF ~Owner(header.owner) OR ~Token(header.itemID, maxItemBytes) OR
      ~Reference(header.id, FALSE) OR ~Reference(header.replyTo, TRUE) OR
      (header.id = header.replyTo) OR ~Timestamp(header.published) OR ~Timestamp(header.updated) OR
      (header.updated < header.published) OR ~Text(header.title, maxTitleBytes, TRUE) OR
      ~Text(text, maxTextBytes, FALSE) OR ~A.Identity(header.author, canonical, ip) THEN RETURN NIL END;
  NEW(post); post.header := header; COPY(canonical, post.header.author);
  post.text := Items.Copy8(text); post.length := Length(text);
  post.size := Length(header.itemID)+Length(header.id)+Length(header.replyTo)+64+
    Length(canonical)+Length(header.title)+40+post.length;
  RETURN post
END New;

PROCEDURE Valid*(post: Post): BOOLEAN;
BEGIN RETURN (post # NIL) & (post.text # NIL) END Valid;

PROCEDURE Describe*(post: Post; VAR header: Header): BOOLEAN;
BEGIN IF ~Valid(post) THEN RETURN FALSE END; header := post.header; RETURN TRUE END Describe;

PROCEDURE Content*(post: Post; VAR text: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF ~Valid(post) OR (LEN(text) <= post.length) THEN RETURN FALSE END;
  COPY(post.text^, text); RETURN TRUE
END Content;

PROCEDURE Size*(post: Post): LONGINT;
BEGIN IF ~Valid(post) THEN RETURN 0 END; RETURN post.size END Size;

PROCEDURE Same*(left, right: Post): BOOLEAN;
BEGIN
  RETURN Valid(left) & Valid(right) & (left.header.itemID = right.header.itemID) &
    (left.header.id = right.header.id) & (left.header.replyTo = right.header.replyTo) &
    (left.header.owner = right.header.owner) & (left.header.author = right.header.author) &
    (left.header.title = right.header.title) & (left.header.published = right.header.published) &
    (left.header.updated = right.header.updated) & (left.text^ = right.text^)
END Same;

PROCEDURE Revision*(previous, next: Post): BOOLEAN;
BEGIN
  RETURN Valid(previous) & Valid(next) & (previous.header.itemID = next.header.itemID) &
    (previous.header.id = next.header.id) & (previous.header.replyTo = next.header.replyTo) &
    (previous.header.owner = next.header.owner) & (previous.header.author = next.header.author) &
    (previous.header.published = next.header.published) & (next.header.updated > previous.header.updated)
END Revision;

END BarevPost.
