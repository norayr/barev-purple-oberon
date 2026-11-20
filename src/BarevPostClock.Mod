MODULE BarevPostClock;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT P := BarevPost;

PROCEDURE Digits(value, width, start: LONGINT; VAR text: ARRAY OF CHAR);
BEGIN
  WHILE width > 0 DO DEC(width); text[start+width] := CHR(ORD("0")+value MOD 10); value := value DIV 10 END
END Digits;

PROCEDURE UTC*(seconds: HUGEINT; VAR stamp: ARRAY OF CHAR): BOOLEAN;
VAR days, sod, z, era, doe, yoe, doy, mp, year, month, day: LONGINT;
  next: ARRAY 21 OF CHAR;
BEGIN
  IF (LEN(stamp) < 21) OR (seconds < 0) OR (seconds > 253402300799) THEN RETURN FALSE END;
  days := SHORT(seconds DIV 86400); sod := SHORT(seconds MOD 86400);
  z := days+719468; era := z DIV 146097; doe := z-era*146097;
  yoe := (doe-doe DIV 1460+doe DIV 36524-doe DIV 146096) DIV 365;
  doy := doe-(365*yoe+yoe DIV 4-yoe DIV 100); mp := (5*doy+2) DIV 153;
  day := doy-(153*mp+2) DIV 5+1;
  IF mp < 10 THEN month := mp+3 ELSE month := mp-9 END;
  year := yoe+era*400; IF month <= 2 THEN INC(year) END;
  next := "0000-00-00T00:00:00Z";
  Digits(year, 4, 0, next); Digits(month, 2, 5, next); Digits(day, 2, 8, next);
  Digits(sod DIV 3600, 2, 11, next); Digits(sod MOD 3600 DIV 60, 2, 14, next); Digits(sod MOD 60, 2, 17, next);
  IF ~P.Timestamp(next) THEN RETURN FALSE END;
  COPY(next, stamp); RETURN TRUE
END UTC;

END BarevPostClock.
