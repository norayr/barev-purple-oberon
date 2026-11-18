MODULE TestTLS;
IMPORT Args, Out, Platform, BarevTLS, Identity := BarevIdentity;
VAR key: Identity.Key; profile, hex, arg, role, expected: ARRAY 4096 OF CHAR;
  pin: ARRAY 32 OF CHAR; data: ARRAY 32 OF CHAR; certificate: ARRAY 4096 OF CHAR;
  word: ARRAY 6 OF CHAR;
  identifier, after: Identity.Identifier; error: ARRAY 128 OF CHAR;
  i, length, fd, handle, result, started, at, old: LONGINT; writingSeen: BOOLEAN;

PROCEDURE Digit(c: CHAR): LONGINT;
BEGIN IF c <= "9" THEN RETURN ORD(c)-ORD("0") END; RETURN ORD(c)-ORD("a")+10 END Digit;

PROCEDURE Deadline;
BEGIN IF Platform.Time()-started > 15000 THEN BarevTLS.Close(handle); HALT(20) END END Deadline;

BEGIN
  Args.Get(1, profile); Args.Get(2, hex); Args.Get(3, arg); Args.Get(4, role); Args.Get(5, expected);
  IF Identity.Open(profile, "tls-test", "", key) # Identity.okay THEN HALT(1) END;
  IF ~Identity.IdentifierOf(key, identifier) THEN HALT(2) END;
  i := 0; length := 0;
  WHILE hex[i] # 0X DO pin[length] := CHR(Digit(hex[i])*16+Digit(hex[i+1])); INC(length); INC(i, 2) END;
  fd := 0; i := 0;
  WHILE (arg[i] >= "0") & (arg[i] <= "9") DO fd := fd*10+ORD(arg[i])-ORD("0"); INC(i) END;
  handle := BarevTLS.Begin(fd, role = "server", key, pin, length);
  IF ~Identity.IdentifierOf(key, after) OR (identifier # after) THEN HALT(3) END;
  IF expected = "begin-reject" THEN
    IF (handle # 0) OR ~BarevTLS.Idle() THEN HALT(4) END;
    BarevTLS.Error(handle, error); IF error[0] = 0X THEN HALT(5) END;
    HALT(0)
  END;
  IF handle = 0 THEN BarevTLS.Error(handle, error); Out.String(error); Out.Ln; HALT(6) END;
  length := BarevTLS.Certificate(handle, certificate); IF length <= 0 THEN HALT(7) END;
  Out.String("CERT "); FOR i := 0 TO length-1 DO Out.HexDigits(ORD(certificate[i]), 2) END; Out.Ln;
  data := "hello";
  IF BarevTLS.Authenticated(handle) OR (BarevTLS.Write(handle, data, 5) # -1) OR (BarevTLS.Read(handle, data, 5) # -1) THEN HALT(8) END;
  started := Platform.Time(); writingSeen := FALSE;
  REPEAT
    result := BarevTLS.Poll(handle); writingSeen := writingSeen OR BarevTLS.WantsWrite(handle);
    Platform.Delay(1); Deadline
  UNTIL result # 0;
  IF expected = "reject" THEN
    IF (result # -1) OR BarevTLS.Authenticated(handle) OR (BarevTLS.Write(handle, data, 5) # -1) OR
       (BarevTLS.Read(handle, data, 5) # -1) THEN HALT(9) END;
    BarevTLS.Error(handle, error); Out.String(error); Out.Ln;
    BarevTLS.Close(handle); IF ~BarevTLS.Idle() THEN HALT(10) END; HALT(0)
  END;
  IF (result # 1) OR ~BarevTLS.Authenticated(handle) OR ~writingSeen THEN HALT(11) END;
  IF role # "server" THEN
    REPEAT result := BarevTLS.Write(handle, data, 5); Platform.Delay(1); Deadline UNTIL result # BarevTLS.wouldBlock;
    IF result # 5 THEN HALT(12) END
  END;
  IF role = "server" THEN word := "hello" ELSE word := "world" END;
  at := 0;
  WHILE at < 5 DO
    REPEAT result := BarevTLS.Read(handle, data, 1); Platform.Delay(1); Deadline UNTIL result # BarevTLS.wouldBlock;
    IF result # 1 THEN HALT(13) END;
    IF data[0] # word[at] THEN HALT(14) END;
    INC(at); IF (at < 5) & ~BarevTLS.Pending(handle) THEN HALT(15) END
  END;
  IF role = "server" THEN
    data := "world";
    REPEAT result := BarevTLS.Write(handle, data, 5); Platform.Delay(1); Deadline UNTIL result # BarevTLS.wouldBlock;
    IF result # 5 THEN HALT(16) END
  END;
  old := handle; BarevTLS.Close(handle); BarevTLS.Close(handle);
  IF ~BarevTLS.Idle() OR BarevTLS.Authenticated(old) OR (BarevTLS.Read(old, data, 1) # -1) OR (BarevTLS.Poll(old) # -1) THEN HALT(17) END;
  IF ~Identity.IdentifierOf(key, after) OR (identifier # after) THEN HALT(18) END;
  Identity.Clear(key); Out.String("PASS authenticated TLS transport"); Out.Ln
END TestTLS.
