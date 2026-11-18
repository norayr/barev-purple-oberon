MODULE BarevIdentity;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Persistent account identities. Network authentication is a separate protocol. *)
IMPORT F := BarevIdentityFiles, E := TLSEd25519, K := TLSEd25519Keys, TLSBytes, TLSSHA256,
  TLSIdentity, TLSCertGen;

CONST
  okay* = 0; storageError* = 1; invalidRecord* = 2; invalidAccount* = 3;
  invalidIdentifier* = 4; entropyError* = 5; accountMismatch* = 6; unsupported* = 7;

TYPE
  Key* = RECORD seed, publicKey: ARRAY 32 OF CHAR; active: BOOLEAN END;
  Identifier* = ARRAY 65 OF CHAR;
  Fingerprint* = ARRAY 72 OF CHAR;
  Record = ARRAY 72 OF CHAR;
  Link = ARRAY 40 OF CHAR;

PROCEDURE Wipe(VAR bytes: ARRAY OF CHAR);
VAR i: LONGINT;
BEGIN FOR i := 0 TO LEN(bytes)-1 DO bytes[i] := 0X END END Wipe;

PROCEDURE Clear*(VAR key: Key);
BEGIN Wipe(key.seed); Wipe(key.publicKey); key.active := FALSE END Clear;

PROCEDURE Hex(value: LONGINT): CHAR;
BEGIN IF value < 10 THEN RETURN CHR(ORD("0")+value) END; RETURN CHR(ORD("a")+value-10) END Hex;

PROCEDURE Encode(VAR bytes: ARRAY OF CHAR; VAR text: ARRAY OF CHAR);
VAR i: LONGINT;
BEGIN
  FOR i := 0 TO 31 DO text[i*2] := Hex(ORD(bytes[i]) DIV 16); text[i*2+1] := Hex(ORD(bytes[i]) MOD 16) END;
  text[64] := 0X
END Encode;

PROCEDURE ValidIdentifier*(text: ARRAY OF CHAR): BOOLEAN;
VAR i: LONGINT;
BEGIN
  IF LEN(text) < 65 THEN RETURN FALSE END;
  FOR i := 0 TO 63 DO
    IF ~((text[i] >= "0") & (text[i] <= "9") OR (text[i] >= "a") & (text[i] <= "f")) THEN RETURN FALSE END
  END;
  RETURN text[64] = 0X
END ValidIdentifier;

PROCEDURE IdentifierOf*(VAR key: Key; VAR identifier: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF ~key.active OR (LEN(identifier) < 65) THEN RETURN FALSE END;
  Encode(key.publicKey, identifier); RETURN TRUE
END IdentifierOf;

PROCEDURE FingerprintOf*(VAR key: Key; VAR fingerprint: ARRAY OF CHAR): BOOLEAN;
VAR input, digest: TLSBytes.Buffer; hash: TLSSHA256.Digest; encoded: Identifier; i: LONGINT;
BEGIN
  IF ~key.active OR (LEN(fingerprint) < 72) THEN RETURN FALSE END;
  TLSBytes.Init(input); TLSBytes.AppendOpen(input, key.publicKey, 32);
  TLSSHA256.DigestBuffer(input, hash); TLSSHA256.DigestToBuffer(hash, digest);
  Encode(digest.data, encoded); fingerprint[0] := "S"; fingerprint[1] := "H"; fingerprint[2] := "A";
  fingerprint[3] := "2"; fingerprint[4] := "5"; fingerprint[5] := "6"; fingerprint[6] := ":";
  FOR i := 0 TO 64 DO fingerprint[7+i] := encoded[i] END;
  RETURN TRUE
END FingerprintOf;

PROCEDURE Header(VAR bytes: ARRAY OF CHAR; text: ARRAY OF CHAR): BOOLEAN;
VAR i: LONGINT;
BEGIN FOR i := 0 TO 7 DO IF bytes[i] # text[i] THEN RETURN FALSE END END; RETURN TRUE END Header;

PROCEDURE PutHeader(VAR bytes: ARRAY OF CHAR; text: ARRAY OF CHAR);
VAR i: LONGINT;
BEGIN FOR i := 0 TO 7 DO bytes[i] := text[i] END END PutHeader;

PROCEDURE AccountName(account: ARRAY OF CHAR; VAR name: Identifier): BOOLEAN;
VAR input, digest: TLSBytes.Buffer; hash: TLSSHA256.Digest; i: LONGINT;
BEGIN
  TLSBytes.Init(input); TLSBytes.AppendString(input, "Barev account v1"); TLSBytes.AppendByte(input, 10);
  i := 0;
  WHILE (i < LEN(account)) & (account[i] # 0X) DO
    IF i >= 256 THEN RETURN FALSE END;
    TLSBytes.AppendChar(input, account[i]); INC(i)
  END;
  IF (i = 0) OR (i = LEN(account)) THEN RETURN FALSE END;
  TLSSHA256.DigestBuffer(input, hash); TLSSHA256.DigestToBuffer(hash, digest); Encode(digest.data, name); RETURN TRUE
END AccountName;

PROCEDURE Acquire(handle: LONGINT; VAR name: Identifier; expected: ARRAY OF CHAR;
    VAR key: Key; VAR record: Record): LONGINT;
VAR link: Link; identifier, computed: Identifier; derived: ARRAY 32 OF CHAR; result, i, difference: LONGINT;
BEGIN
  result := F.Read(handle, 1, name, link, 40);
  IF result < 0 THEN RETURN storageError END;
  IF result = 0 THEN
    IF ~Header(link, "BAREVAC1") THEN RETURN invalidRecord END;
    FOR i := 0 TO 31 DO key.publicKey[i] := link[8+i] END;
    Encode(key.publicKey, identifier);
    IF (expected[0] # 0X) & (expected # identifier) THEN RETURN accountMismatch END
  ELSIF expected[0] # 0X THEN COPY(expected, identifier)
  ELSE identifier[0] := 0X
  END;
  IF identifier[0] = 0X THEN
    IF ~K.Generate(key.seed, key.publicKey) THEN RETURN entropyError END;
    Encode(key.publicKey, identifier);
    PutHeader(record, "BAREVID1");
    FOR i := 0 TO 31 DO record[8+i] := key.seed[i]; record[40+i] := key.publicKey[i] END;
    IF F.Install(handle, 0, identifier, record, 72) # 0 THEN RETURN storageError END
  ELSE
    IF F.Read(handle, 0, identifier, record, 72) # 0 THEN RETURN storageError END;
    IF ~Header(record, "BAREVID1") THEN RETURN invalidRecord END;
    FOR i := 0 TO 31 DO key.seed[i] := record[8+i]; key.publicKey[i] := record[40+i] END;
    IF ~E.PublicKey(key.seed, derived) THEN RETURN invalidRecord END;
    difference := 0;
    FOR i := 0 TO 31 DO IF derived[i] # key.publicKey[i] THEN INC(difference) END END;
    IF difference # 0 THEN RETURN invalidRecord END;
    Encode(key.publicKey, computed);
    IF computed # identifier THEN RETURN invalidRecord END
  END;
  IF result = 1 THEN
    PutHeader(link, "BAREVAC1");
    FOR i := 0 TO 31 DO link[8+i] := key.publicKey[i] END;
    IF F.Install(handle, 1, name, link, 40) # 0 THEN RETURN storageError END
  END;
  key.active := TRUE; RETURN okay
END Acquire;

(** Loads or creates a local account identity. An expected public identifier
    prevents silently replacing a missing configured identity. Failure clears key. *)
PROCEDURE Open*(profile, account, expected: ARRAY OF CHAR; VAR key: Key): LONGINT;
VAR name: Identifier; record: Record; result, handle: LONGINT;
BEGIN
  Clear(key);
  IF (LEN(expected) = 0) OR ((expected[0] # 0X) & ~ValidIdentifier(expected)) THEN RETURN invalidIdentifier END;
  IF ~AccountName(account, name) THEN RETURN invalidAccount END;
  handle := F.Open(profile);
  IF handle = -2 THEN RETURN unsupported END;
  IF handle < 0 THEN RETURN storageError END;
  result := Acquire(handle, name, expected, key, record);
  F.Close(handle); Wipe(record);
  IF result # okay THEN Clear(key) END;
  RETURN result
END Open;

(** Creates a TLS certificate and signing identity without changing the persistent key. *)
PROCEDURE ForTLS*(VAR key: Key; VAR identity: TLSIdentity.Identity): BOOLEAN;
VAR certificate: TLSBytes.Buffer;
BEGIN
  identity := NIL;
  RETURN key.active & TLSCertGen.Ed25519SelfSigned("barev", key.seed, 1, certificate) &
    TLSIdentity.FromEd25519(key.seed, certificate, identity)
END ForTLS;

END BarevIdentity.
