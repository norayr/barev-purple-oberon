MODULE BarevPeerPins;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT A := BarevAddress, F := oocFiles, Channel, Platform, PlatformNative,
  TLSBytes, TLSSHA256;

CONST okay* = 0; unpinned* = 1; invalid* = 2; storageError* = 3; changed* = 4;
TYPE Identifier* = ARRAY 65 OF CHAR; Fingerprint* = ARRAY 72 OF CHAR;
  Bytes = ARRAY 32 OF CHAR; Record = ARRAY 104 OF CHAR;
  Path = ARRAY 4096 OF CHAR;

PROCEDURE Length(text: ARRAY OF CHAR): LONGINT;
VAR n: LONGINT;
BEGIN n := 0; WHILE (n < LEN(text)) & (text[n] # 0X) DO INC(n) END; RETURN n END Length;

PROCEDURE Digit(ch: CHAR): LONGINT;
BEGIN
  IF (ch >= "0") & (ch <= "9") THEN RETURN ORD(ch)-ORD("0") END;
  IF (ch >= "a") & (ch <= "f") THEN RETURN ORD(ch)-ORD("a")+10 END;
  IF (ch >= "A") & (ch <= "F") THEN RETURN ORD(ch)-ORD("A")+10 END;
  RETURN -1
END Digit;

PROCEDURE Encode(VAR bytes: ARRAY OF CHAR; VAR text: ARRAY OF CHAR);
VAR digits: ARRAY 17 OF CHAR; i: LONGINT;
BEGIN
  digits := "0123456789abcdef";
  FOR i := 0 TO 31 DO text[2*i] := digits[ORD(bytes[i]) DIV 16]; text[2*i+1] := digits[ORD(bytes[i]) MOD 16] END;
  text[64] := 0X
END Encode;

PROCEDURE Decode(text: ARRAY OF CHAR; VAR bytes: Bytes): BOOLEAN;
VAR i, hi, lo: LONGINT;
BEGIN
  IF Length(text) # 64 THEN RETURN FALSE END;
  FOR i := 0 TO 31 DO
    hi := Digit(text[2*i]); lo := Digit(text[2*i+1]);
    IF (hi < 0) OR (lo < 0) THEN RETURN FALSE END;
    bytes[i] := CHR(hi*16+lo)
  END;
  RETURN TRUE
END Decode;

PROCEDURE Hash(VAR input: TLSBytes.Buffer; VAR bytes: Bytes);
VAR digest: TLSBytes.Buffer; hash: TLSSHA256.Digest; i: LONGINT;
BEGIN
  TLSSHA256.DigestBuffer(input, hash); TLSSHA256.DigestToBuffer(hash, digest);
  FOR i := 0 TO 31 DO bytes[i] := digest.data[i] END
END Hash;

PROCEDURE Describe*(text: ARRAY OF CHAR; VAR normalized: ARRAY OF CHAR; VAR fingerprint: ARRAY OF CHAR): BOOLEAN;
VAR bytes, digest: Bytes; input: TLSBytes.Buffer; encoded: Identifier; i: LONGINT;
BEGIN
  IF (LEN(normalized) < 65) OR (LEN(fingerprint) < 72) OR ~Decode(text, bytes) THEN RETURN FALSE END;
  Encode(bytes, normalized); TLSBytes.Init(input); TLSBytes.AppendOpen(input, bytes, 32); Hash(input, digest);
  Encode(digest, encoded); COPY("SHA256:", fingerprint);
  FOR i := 0 TO 64 DO fingerprint[7+i] := encoded[i] END;
  RETURN TRUE
END Describe;

PROCEDURE Locate(profile, own, peer: ARRAY OF CHAR; VAR path: Path; VAR ownBytes, name: Bytes): BOOLEAN;
VAR canonical: ARRAY A.maxIdentityBytes OF CHAR; ip: A.IP; input: TLSBytes.Buffer;
  encoded: Identifier; prefix: ARRAY 13 OF CHAR; i, n: LONGINT;
BEGIN
  n := Length(profile);
  IF (n = 0) OR (n = LEN(profile)) OR (n > 3900) OR (profile[0] # "/") OR
     ~Decode(own, ownBytes) OR ~A.Identity(peer, canonical, ip) THEN RETURN FALSE END;
  WHILE (n > 1) & (profile[n-1] = "/") DO DEC(n) END;
  TLSBytes.Init(input); TLSBytes.AppendString(input, "Barev peer pin v1"); TLSBytes.AppendByte(input, 10);
  TLSBytes.AppendOpen(input, ownBytes, 32); TLSBytes.AppendString(input, canonical); Hash(input, name); Encode(name, encoded);
  FOR i := 0 TO n-1 DO path[i] := profile[i] END;
  path[n] := 0X;
  IF n = 1 THEN DEC(n) END;
  prefix := "/barev/peer-";
  FOR i := 0 TO 11 DO path[n+i] := prefix[i] END; INC(n, 12);
  FOR i := 0 TO 63 DO path[n+i] := encoded[i] END; INC(n, 64);
  path[n] := "."; path[n+1] := "p"; path[n+2] := "i"; path[n+3] := "n"; path[n+4] := 0X;
  RETURN TRUE
END Locate;

PROCEDURE Read(path: Path; VAR own, name: Bytes; VAR identifier: Identifier): LONGINT;
VAR file: F.File; reader: Channel.Reader; result: F.Result; record: Record;
  error: LONGINT; kind: INTEGER; i: LONGINT; status: LONGINT; bytes: Bytes; header: ARRAY 9 OF CHAR;
BEGIN
  identifier[0] := 0X;
  error := PlatformNative.PathKind(path, FALSE, kind);
  IF error # 0 THEN
    IF Platform.Absent(SHORT(error)) THEN RETURN unpinned END;
    RETURN storageError
  END;
  IF kind # 2 THEN RETURN storageError END;
  file := F.Old(path, {F.read}, result);
  IF file = NIL THEN RETURN storageError END;
  status := invalid;
  IF file.Length() = 104 THEN
    reader := file.NewReader(); reader.ReadBytes(record, 0, 104);
    IF reader.res = F.done THEN
      status := okay;
      header := "BAREVPN1";
      FOR i := 0 TO 7 DO IF record[i] # header[i] THEN status := invalid END END;
      FOR i := 0 TO 31 DO
        IF (record[8+i] # own[i]) OR (record[40+i] # name[i]) THEN status := invalid END;
        bytes[i] := record[72+i]
      END
    ELSE status := storageError
    END
  END;
  file.Close;
  IF file.res # F.done THEN status := storageError END;
  IF status = okay THEN Encode(bytes, identifier) END;
  RETURN status
END Read;

PROCEDURE Load*(profile, own, peer: ARRAY OF CHAR; VAR identifier: ARRAY OF CHAR; VAR fingerprint: ARRAY OF CHAR): LONGINT;
VAR path: Path; ownBytes, name: Bytes; found: Identifier; status: LONGINT;
BEGIN
  IF LEN(identifier) > 0 THEN identifier[0] := 0X END;
  IF LEN(fingerprint) > 0 THEN fingerprint[0] := 0X END;
  IF (LEN(identifier) < 65) OR (LEN(fingerprint) < 72) OR ~Locate(profile, own, peer, path, ownBytes, name) THEN RETURN invalid END;
  status := Read(path, ownBytes, name, found);
  IF status = okay THEN
    IF ~Describe(found, identifier, fingerprint) THEN RETURN invalid END
  END;
  RETURN status
END Load;

PROCEDURE Save*(profile, own, peer, expected, replacement: ARRAY OF CHAR): LONGINT;
VAR path: Path; ownBytes, name, bytes, oldBytes: Bytes; record: Record; file: F.File;
  writer: Channel.Writer; result: F.Result; current, wanted: Identifier; status, i: LONGINT; header: ARRAY 9 OF CHAR;
BEGIN
  IF ~Locate(profile, own, peer, path, ownBytes, name) OR ~Decode(replacement, bytes) OR
     (Length(expected) = LEN(expected)) THEN RETURN invalid END;
  IF expected[0] # 0X THEN
    IF ~Decode(expected, oldBytes) THEN RETURN invalid END;
    Encode(oldBytes, wanted)
  ELSE wanted[0] := 0X
  END;
  status := Read(path, ownBytes, name, current);
  IF (status # okay) & (status # unpinned) THEN RETURN status END;
  IF current # wanted THEN RETURN changed END;
  Encode(bytes, current); IF current = wanted THEN RETURN okay END;
  header := "BAREVPN1";
  FOR i := 0 TO 7 DO record[i] := header[i] END;
  FOR i := 0 TO 31 DO record[8+i] := ownBytes[i]; record[40+i] := name[i]; record[72+i] := bytes[i] END;
  file := F.Tmp(path, {F.write}, result);
  IF file = NIL THEN RETURN storageError END;
  writer := file.NewWriter(); writer.WriteBytes(record, 0, 104);
  status := storageError;
  IF writer.res = F.done THEN
    IF Read(path, ownBytes, name, current) IN {okay, unpinned} THEN
      IF current = wanted THEN file.Register; IF file.res = F.done THEN status := okay END
      ELSE status := changed
      END
    END
  END;
  file.Close;
  IF file.res # F.done THEN status := storageError END;
  RETURN status
END Save;

END BarevPeerPins.
