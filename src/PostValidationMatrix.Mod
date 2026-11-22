MODULE PostValidationMatrix;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT P := BarevPost, Strings := oocStrings, Out;

VAR byte, i, n: LONGINT; raw: ARRAY 4 OF CHAR; sample: ARRAY 64 OF CHAR;
  prefixes: ARRAY 7 OF ARRAY 16 OF CHAR;

PROCEDURE Flag(value: BOOLEAN);
BEGIN Out.Char(" "); IF value THEN Out.Char("1") ELSE Out.Char("0") END END Flag;

BEGIN
  prefixes[0] := "urn:x"; prefixes[1] := "x:/"; prefixes[2] := "x://";
  prefixes[3] := "x:/?"; prefixes[4] := "urn:x#"; prefixes[5] := ""; prefixes[6] := "urn:x%";
  Out.String("post-validation-v1"); Out.Ln;
  FOR byte := 1 TO 255 DO
    raw[0] := "a"; raw[1] := CHR(byte); raw[2] := "b"; raw[3] := 0X;
    Out.Int(byte, 0); Flag(P.Token(raw, 128)); Flag(P.Text(raw, 16384, FALSE));
    FOR i := 0 TO 6 DO
      COPY(prefixes[i], sample); n := Strings.Length(sample); sample[n] := CHR(byte); sample[n+1] := 0X;
      IF i = 5 THEN Strings.Append(":value", sample)
      ELSIF i = 6 THEN Strings.Append("0", sample)
      ELSE Strings.Append("y", sample)
      END;
      Flag(P.Reference(sample, FALSE))
    END;
    Out.Ln
  END
END PostValidationMatrix.
