MODULE BarevSHA1;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* SHA-1 for protocol identifiers and checksums, not authentication. Arithmetic
   stays within HUGEINT without relying on signed wraparound. *)

IMPORT Items := XmppItems;

CONST maxBytes* = 65535; wordMod = 4294967296;
VAR xorNibble, andNibble: ARRAY 16, 16 OF LONGINT;
  hex: ARRAY 17 OF CHAR; power: ARRAY 33 OF HUGEINT;
  x, y, bit, a, b, value: LONGINT;

PROCEDURE Bits(a, b: HUGEINT; exclusive: BOOLEAN): HUGEINT;
  VAR result, place: HUGEINT; i, left, right: LONGINT;
BEGIN
  result := 0; place := 1;
  FOR i := 0 TO 7 DO
    left := SHORT(a MOD 16); right := SHORT(b MOD 16);
    IF exclusive THEN result := result+xorNibble[left, right]*place
    ELSE result := result+andNibble[left, right]*place
    END;
    a := a DIV 16; b := b DIV 16; place := place*16
  END;
  RETURN result
END Bits;

PROCEDURE Rotate(value: HUGEINT; count: LONGINT): HUGEINT;
BEGIN RETURN (value*power[count]) MOD wordMod+value DIV power[32-count] END Rotate;

PROCEDURE Hash*(bytes: ARRAY OF CHAR; length: LONGINT): Items.Bytes;
  VAR padded, hash: Items.Bytes; h: ARRAY 5 OF HUGEINT; w: ARRAY 80 OF HUGEINT;
    a, b, c, d, e, f, k, temp, number: HUGEINT; size, at, i, j: LONGINT;
BEGIN
  IF (length < 0) OR (length > LEN(bytes)) OR (length > maxBytes) THEN RETURN NIL END;
  size := ((length+72) DIV 64)*64; NEW(padded, size);
  FOR i := 0 TO length-1 DO padded[i] := bytes[i] END;
  padded[length] := 80X; number := length*8;
  FOR i := size-1 TO size-8 BY -1 DO padded[i] := CHR(SHORT(number MOD 256)); number := number DIV 256 END;
  h[0] := 1732584193; h[1] := 4023233417; h[2] := 2562383102; h[3] := 271733878; h[4] := 3285377520;
  at := 0;
  WHILE at < size DO
    FOR i := 0 TO 15 DO
      w[i] := 0; FOR j := 0 TO 3 DO w[i] := w[i]*256+ORD(padded[at+4*i+j]) END
    END;
    FOR i := 16 TO 79 DO w[i] := Rotate(Bits(Bits(w[i-3], w[i-8], TRUE), Bits(w[i-14], w[i-16], TRUE), TRUE), 1) END;
    a := h[0]; b := h[1]; c := h[2]; d := h[3]; e := h[4];
    FOR i := 0 TO 79 DO
      IF i < 20 THEN f := Bits(d, Bits(b, Bits(c, d, TRUE), FALSE), TRUE); k := 1518500249
      ELSIF i < 40 THEN f := Bits(Bits(b, c, TRUE), d, TRUE); k := 1859775393
      ELSIF i < 60 THEN f := Bits(b, c, FALSE)+Bits(d, Bits(b, c, TRUE), FALSE); k := 2400959708
      ELSE f := Bits(Bits(b, c, TRUE), d, TRUE); k := 3395469782
      END;
      temp := (Rotate(a, 5)+f+e+k+w[i]) MOD wordMod;
      e := d; d := c; c := Rotate(b, 30); b := a; a := temp
    END;
    h[0] := (h[0]+a) MOD wordMod; h[1] := (h[1]+b) MOD wordMod;
    h[2] := (h[2]+c) MOD wordMod; h[3] := (h[3]+d) MOD wordMod; h[4] := (h[4]+e) MOD wordMod;
    INC(at, 64)
  END;
  NEW(hash, 41);
  FOR i := 0 TO 4 DO
    number := h[i]; FOR j := 7 TO 0 BY -1 DO hash[8*i+j] := hex[SHORT(number MOD 16)]; number := number DIV 16 END
  END;
  hash[40] := 0X; RETURN hash
END Hash;

BEGIN
  COPY("0123456789abcdef", hex);
  power[0] := 1; FOR x := 1 TO 32 DO power[x] := power[x-1]*2 END;
  FOR x := 0 TO 15 DO
    FOR y := 0 TO 15 DO
      a := x; b := y; value := 1;
      FOR bit := 0 TO 3 DO
        IF ODD(a) # ODD(b) THEN INC(xorNibble[x, y], value) END;
        IF ODD(a) & ODD(b) THEN INC(andNibble[x, y], value) END;
        a := a DIV 2; b := b DIV 2; value := value*2
      END
    END
  END
END BarevSHA1.
