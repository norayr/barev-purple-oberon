MODULE BarevPostBinary;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT I := XmppItems, B := TLSBytes;

CONST maxBytes* = 6291456;
  polynomial = -306674912; (* Reflected IEEE CRC-32 polynomial EDB88320. *)

TYPE
  Writer* = RECORD data: I.Bytes; position, maximum: LONGINT; valid: BOOLEAN END;
  Reader* = RECORD data: I.Bytes; position, maximum: LONGINT; valid: BOOLEAN END;

PROCEDURE OpenWriter*(VAR writer: Writer; data: I.Bytes; maximum: LONGINT);
BEGIN
  writer.data := data; writer.position := 0; writer.maximum := maximum;
  writer.valid := (maximum >= 0) & (maximum <= maxBytes);
  IF (data # NIL) & (maximum > LEN(data^)) THEN writer.valid := FALSE END
END OpenWriter;

PROCEDURE PutWord*(VAR writer: Writer; word: LONGINT);
VAR i, value: LONGINT;
BEGIN
  IF ~writer.valid THEN RETURN END;
  IF writer.maximum-writer.position < 4 THEN writer.valid := FALSE; RETURN END;
  IF writer.data # NIL THEN
    value := word;
    FOR i := 3 TO 0 BY -1 DO
      writer.data[writer.position+i] := CHR(value MOD 256); value := value DIV 256
    END
  END;
  INC(writer.position, 4)
END PutWord;

PROCEDURE PutText*(VAR writer: Writer; text: ARRAY OF CHAR);
VAR n, i: LONGINT;
BEGIN
  IF ~writer.valid THEN RETURN END;
  n := 0;
  WHILE (n < LEN(text)) & (text[n] # 0X) DO
    IF n = writer.maximum THEN writer.valid := FALSE; RETURN END;
    INC(n)
  END;
  IF (n = LEN(text)) OR (writer.maximum-writer.position < 4) OR
      (n > writer.maximum-writer.position-4) THEN writer.valid := FALSE; RETURN END;
  PutWord(writer, n);
  IF writer.data # NIL THEN
    FOR i := 0 TO n-1 DO writer.data[writer.position+i] := text[i] END
  END;
  INC(writer.position, n)
END PutText;

PROCEDURE CRC*(VAR data: ARRAY OF CHAR; length: LONGINT): LONGINT;
VAR crc, i, bit: LONGINT;
BEGIN
  IF (length < 0) OR (length > LEN(data)) OR (length > maxBytes) THEN RETURN 0 END;
  crc := -1;
  FOR i := 0 TO length-1 DO
    crc := B.Xor32(crc, LONG(ORD(data[i])));
    FOR bit := 0 TO 7 DO
      IF ODD(crc) THEN crc := B.Xor32(B.Shr32(crc, 1), polynomial)
      ELSE crc := B.Shr32(crc, 1)
      END
    END
  END;
  RETURN B.Not32(crc)
END CRC;

PROCEDURE Seal*(VAR writer: Writer);
VAR crc: LONGINT;
BEGIN
  IF ~writer.valid THEN RETURN END;
  crc := 0;
  IF writer.data # NIL THEN crc := CRC(writer.data^, writer.position) END;
  PutWord(writer, crc)
END Seal;

PROCEDURE Written*(VAR writer: Writer): LONGINT;
BEGIN IF ~writer.valid THEN RETURN -1 END; RETURN writer.position END Written;

PROCEDURE OpenReader*(VAR reader: Reader; data: I.Bytes; length: LONGINT);
BEGIN
  reader.data := data; reader.position := 0; reader.maximum := length;
  reader.valid := (data # NIL) & (length >= 0) & (length <= maxBytes);
  IF reader.valid THEN reader.valid := length <= LEN(data^) END
END OpenReader;

PROCEDURE Word*(VAR reader: Reader): LONGINT;
VAR value, i: LONGINT;
BEGIN
  IF ~reader.valid THEN RETURN 0 END;
  IF reader.maximum-reader.position < 4 THEN reader.valid := FALSE; RETURN 0 END;
  value := ORD(reader.data[reader.position]); IF value >= 128 THEN DEC(value, 256) END;
  FOR i := 1 TO 3 DO value := value*256+LONG(ORD(reader.data[reader.position+i])) END;
  INC(reader.position, 4); RETURN value
END Word;

PROCEDURE Text*(VAR reader: Reader; VAR text: ARRAY OF CHAR): BOOLEAN;
VAR n, i: LONGINT;
BEGIN
  n := Word(reader);
  IF ~reader.valid THEN RETURN FALSE END;
  IF (n < 0) OR (n >= LEN(text)) OR (n > reader.maximum-reader.position) THEN
    reader.valid := FALSE; RETURN FALSE
  END;
  FOR i := 0 TO n-1 DO
    IF reader.data[reader.position+i] = 0X THEN reader.valid := FALSE; RETURN FALSE END;
    text[i] := reader.data[reader.position+i]
  END;
  text[n] := 0X; INC(reader.position, n); RETURN TRUE
END Text;

PROCEDURE Good*(VAR reader: Reader): BOOLEAN;
BEGIN RETURN reader.valid END Good;

PROCEDURE End*(VAR reader: Reader): BOOLEAN;
BEGIN RETURN reader.valid & (reader.position = reader.maximum) END End;

PROCEDURE Checked*(data: I.Bytes; length: LONGINT): BOOLEAN;
VAR reader: Reader; expected: LONGINT;
BEGIN
  OpenReader(reader, data, length);
  IF ~reader.valid OR (length < 4) THEN RETURN FALSE END;
  reader.position := length-4; expected := Word(reader);
  RETURN CRC(data^, length-4) = expected
END Checked;

PROCEDURE Equal*(left: I.Bytes; leftLength: LONGINT; right: I.Bytes; rightLength: LONGINT): BOOLEAN;
VAR i: LONGINT;
BEGIN
  IF (leftLength # rightLength) OR (leftLength < 0) OR (leftLength > maxBytes) THEN RETURN FALSE END;
  IF (left = NIL) OR (right = NIL) THEN RETURN (left = right) & (leftLength = 0) END;
  IF (leftLength > LEN(left^)) OR (rightLength > LEN(right^)) THEN RETURN FALSE END;
  FOR i := 0 TO leftLength-1 DO IF left[i] # right[i] THEN RETURN FALSE END END;
  RETURN TRUE
END Equal;

END BarevPostBinary.
