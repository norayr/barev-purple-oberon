MODULE TestTLSFlow;
IMPORT Args, Out, Platform, BarevTLS, Identity := BarevIdentity;
VAR keys: ARRAY 2 OF Identity.Key; pins: ARRAY 2, 32 OF CHAR;
  handles, states: ARRAY 2 OF LONGINT; descriptors: ARRAY 4 OF LONGINT;
  profile: ARRAY 4096 OF CHAR; arg, identifier: ARRAY 65 OF CHAR;
  bytes, received: ARRAY BarevTLS.maxPlain OF CHAR;
  i, j, fd, sent, got, count, n, started, old: LONGINT;

PROCEDURE Digit(c: CHAR): LONGINT;
BEGIN IF c <= "9" THEN RETURN ORD(c)-ORD("0") END; RETURN ORD(c)-ORD("a")+10 END Digit;

PROCEDURE Deadline;
BEGIN IF Platform.Time()-started > 15000 THEN HALT(20) END END Deadline;

BEGIN
  started := Platform.Time();
  FOR j := 0 TO 1 DO
    Args.Get(SHORT(j+1), profile);
    IF Identity.Open(profile, "tls-test", "", keys[j]) # Identity.okay THEN HALT(1) END;
    IF ~Identity.IdentifierOf(keys[j], identifier) THEN HALT(2) END;
    FOR i := 0 TO 31 DO pins[j, i] := CHR(Digit(identifier[i*2])*16+Digit(identifier[i*2+1])) END
  END;
  FOR j := 0 TO 3 DO
    Args.Get(SHORT(j+3), arg); fd := 0; i := 0;
    WHILE (arg[i] >= "0") & (arg[i] <= "9") DO fd := fd*10+ORD(arg[i])-ORD("0"); INC(i) END;
    descriptors[j] := fd
  END;
  FOR j := 0 TO 1 DO
    handles[j] := BarevTLS.Begin(descriptors[j], j = 1, keys[j], pins[1-j], 32);
    IF handles[j] = 0 THEN HALT(3) END; states[j] := 0
  END;
  IF BarevTLS.Begin(descriptors[0], FALSE, keys[0], pins[1], 32) # 0 THEN HALT(15) END;
  REPEAT
    FOR j := 0 TO 1 DO states[j] := BarevTLS.Poll(handles[j]); IF states[j] < 0 THEN HALT(4) END END;
    Deadline
  UNTIL (states[0] = 1) & (states[1] = 1);
  sent := 0; got := 0;
  WHILE got < 65537 DO
    IF sent < 65537 THEN
      count := 65537-sent; IF count > LEN(bytes) THEN count := LEN(bytes) END;
      FOR i := 0 TO count-1 DO bytes[i] := CHR((sent+i)*7 MOD 256) END;
      n := BarevTLS.Write(handles[0], bytes, count);
      IF n > 0 THEN INC(sent, n) ELSIF n # BarevTLS.wouldBlock THEN HALT(5) END
    END;
    n := BarevTLS.Read(handles[1], received, LEN(received));
    IF n > 0 THEN
      FOR i := 0 TO n-1 DO IF received[i] # CHR((got+i)*7 MOD 256) THEN HALT(6) END END;
      INC(got, n)
    ELSIF n # BarevTLS.wouldBlock THEN HALT(7)
    END;
    Deadline
  END;
  IF (sent # 65537) OR BarevTLS.Pending(handles[1]) THEN HALT(8) END;
  FOR i := 0 TO LEN(bytes)-1 DO bytes[i] := 11X END;
  REPEAT n := BarevTLS.Write(handles[0], bytes, LEN(bytes)); Deadline UNTIL n <= 0;
  IF (n # BarevTLS.wouldBlock) OR ~BarevTLS.WantsWrite(handles[0]) THEN HALT(9) END;
  bytes[0] := 12X;
  IF (BarevTLS.Write(handles[0], bytes, LEN(bytes)) # -1) OR BarevTLS.Authenticated(handles[0]) THEN HALT(10) END;
  old := handles[0]; FOR j := 0 TO 1 DO BarevTLS.Close(handles[j]) END;
  IF ~BarevTLS.Idle() THEN HALT(11) END;
  FOR j := 0 TO 1 DO
    handles[j] := BarevTLS.Begin(descriptors[j+2], j = 1, keys[j], pins[1-j], 32);
    IF handles[j] = 0 THEN HALT(12) END
  END;
  IF (old = handles[0]) OR BarevTLS.Authenticated(old) OR (BarevTLS.Read(old, bytes, 1) # -1) OR
     (BarevTLS.Poll(old) # -1) THEN HALT(13) END;
  BarevTLS.Close(old);
  IF BarevTLS.Certificate(handles[0], bytes) <= 0 THEN HALT(16) END;
  FOR j := 0 TO 1 DO BarevTLS.Close(handles[j]); Identity.Clear(keys[j]) END;
  IF ~BarevTLS.Idle() THEN HALT(14) END;
  Out.String("PASS TLS backpressure, retry integrity and stale handles"); Out.Ln
END TestTLSFlow.
