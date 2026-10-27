MODULE BarevSocks;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Incremental XEP-0065 SOCKS5 handshake. Callers read exactly Need bytes so
   file payload is left on the socket for the file-transfer owner. *)

IMPORT S := LongStrings;

TYPE
  Session* = POINTER TO RECORD
    server, failed: BOOLEAN; stage, have, need, count, offset: LONGINT;
    input, output: ARRAY 262 OF CHAR; digest: ARRAY 41 OF CHAR
  END;

PROCEDURE New*(server: BOOLEAN; digest: ARRAY OF CHAR): Session;
  VAR s: Session;
BEGIN
  IF S.Length8(digest) # 40 THEN RETURN NIL END;
  NEW(s); s.server := server; COPY(digest, s.digest);
  IF server THEN s.need := 2
  ELSE s.output[0] := 5X; s.output[1] := 1X; s.output[2] := 0X; s.count := 3 END;
  RETURN s
END New;

PROCEDURE Need*(s: Session): LONGINT;
BEGIN
  IF (s = NIL) OR s.failed OR (s.count # 0) THEN RETURN 0 END;
  RETURN s.need-s.have
END Need;

PROCEDURE Ready*(s: Session): BOOLEAN;
BEGIN RETURN (s # NIL) & ~s.failed & (s.stage = 4) & (s.count = 0) END Ready;

PROCEDURE Failed*(s: Session): BOOLEAN;
BEGIN RETURN (s = NIL) OR s.failed END Failed;

PROCEDURE Feed*(s: Session; bytes: ARRAY OF CHAR; length: LONGINT);
  VAR i, n: LONGINT; found: BOOLEAN;
BEGIN
  IF (s = NIL) OR s.failed THEN RETURN END;
  IF (length < 0) OR (length > LEN(bytes)) OR (length > Need(s)) THEN s.failed := TRUE; RETURN END;
  FOR i := 0 TO length-1 DO s.input[s.have+i] := bytes[i] END;
  INC(s.have, length); IF s.have < s.need THEN RETURN END;
  IF s.server THEN
    CASE s.stage OF
    0:
      IF (s.input[0] # 5X) OR (s.input[1] = 0X) THEN s.failed := TRUE; RETURN END;
      s.need := 2+ORD(s.input[1]); s.stage := 1; RETURN
    | 1:
      found := FALSE;
      FOR i := 2 TO s.need-1 DO IF s.input[i] = 0X THEN found := TRUE END END;
      IF ~found THEN s.failed := TRUE; RETURN END;
      s.output[0] := 5X; s.output[1] := 0X; s.count := 2; s.stage := 2; s.need := 47
    | 2:
      IF (s.input[0] # 5X) OR (s.input[1] # 1X) OR (s.input[2] # 0X) OR
         (s.input[3] # 3X) OR (s.input[4] # 28X) OR (s.input[45] # 0X) OR (s.input[46] # 0X) THEN
        s.failed := TRUE; RETURN
      END;
      FOR i := 0 TO 39 DO IF s.input[i+5] # s.digest[i] THEN s.failed := TRUE; RETURN END END;
      FOR i := 0 TO 46 DO s.output[i] := s.input[i] END;
      s.output[1] := 0X; s.count := 47; s.stage := 4; s.need := 0
    ELSE s.failed := TRUE; RETURN
    END
  ELSE
    CASE s.stage OF
    0:
      IF (s.input[0] # 5X) OR (s.input[1] # 0X) THEN s.failed := TRUE; RETURN END;
      s.output[0] := 5X; s.output[1] := 1X; s.output[2] := 0X; s.output[3] := 3X; s.output[4] := 28X;
      FOR i := 0 TO 39 DO s.output[i+5] := s.digest[i] END;
      s.output[45] := 0X; s.output[46] := 0X; s.count := 47; s.stage := 1; s.need := 4
    | 1:
      IF (s.input[0] # 5X) OR (s.input[1] # 0X) OR (s.input[2] # 0X) THEN s.failed := TRUE; RETURN END;
      n := ORD(s.input[3]);
      IF n = 1 THEN s.need := 10; s.stage := 3; RETURN
      ELSIF n = 4 THEN s.need := 22; s.stage := 3; RETURN
      ELSIF n = 3 THEN s.need := 5; s.stage := 2; RETURN
      ELSE s.failed := TRUE; RETURN
      END
    | 2:
      IF s.input[4] = 0X THEN s.failed := TRUE; RETURN END;
      s.need := 7+ORD(s.input[4]);
      IF s.need > LEN(s.input) THEN s.failed := TRUE; RETURN END;
      s.stage := 3; RETURN
    | 3: s.stage := 4; s.need := 0
    ELSE s.failed := TRUE; RETURN
    END
  END;
  s.have := 0
END Feed;

PROCEDURE Peek*(s: Session; VAR bytes: ARRAY OF CHAR): LONGINT;
  VAR i, n: LONGINT;
BEGIN
  IF (s = NIL) OR s.failed THEN RETURN 0 END;
  n := s.count-s.offset; IF n > LEN(bytes) THEN n := LEN(bytes) END;
  FOR i := 0 TO n-1 DO bytes[i] := s.output[s.offset+i] END;
  RETURN n
END Peek;

PROCEDURE Sent*(s: Session; length: LONGINT);
BEGIN
  IF (s = NIL) OR s.failed THEN RETURN END;
  IF (length < 0) OR (length > s.count-s.offset) THEN s.failed := TRUE; RETURN END;
  INC(s.offset, length);
  IF s.offset = s.count THEN
    s.count := 0; s.offset := 0;
    IF ~s.server & (s.stage = 0) THEN s.need := 2 END
  END
END Sent;

END BarevSocks.
