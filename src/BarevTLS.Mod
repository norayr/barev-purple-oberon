MODULE BarevTLS;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Root authenticated transport state while the host retains generation-checked handles. *)
IMPORT Identity := BarevIdentity, Network := BarevNetwork, TLS := TLS13Live, Server := TLS13Server,
  TLSIdentity, TLSBytes, Internet;

CONST
  maxSessions* = Network.maxSockets; maxPlain* = 16384; wouldBlock* = -2;
  maxGeneration = (MAX(LONGINT)-maxSessions) DIV maxSessions;

TYPE
  Session = POINTER TO RECORD
    live: TLS.State; pending: Server.Pending; identity: TLSIdentity.Identity;
    server, failed, closed: BOOLEAN; fd, writingLength: LONGINT;
    writing: ARRAY maxPlain OF CHAR; error: ARRAY 128 OF CHAR
  END;

VAR sessions: ARRAY maxSessions OF Session; generations: ARRAY maxSessions OF LONGINT;
  lastError: ARRAY 128 OF CHAR;

PROCEDURE Find(handle: LONGINT): Session;
VAR index: LONGINT;
BEGIN
  IF handle <= 0 THEN RETURN NIL END;
  index := (handle-1) MOD maxSessions;
  IF generations[index] # (handle-1) DIV maxSessions THEN RETURN NIL END;
  RETURN sessions[index]
END Find;

PROCEDURE WipeWriting(s: Session);
VAR i: LONGINT;
BEGIN
  FOR i := 0 TO s.writingLength-1 DO s.writing[i] := 0X END;
  s.writingLength := 0
END WipeWriting;

PROCEDURE Fail(s: Session; reason: ARRAY OF CHAR): LONGINT;
BEGIN
  IF ~s.failed THEN COPY(reason, s.error) END;
  s.failed := TRUE; Server.ClosePending(s.pending); TLS.CloseNow(s.live); s.fd := -1;
  WipeWriting(s); RETURN -1
END Fail;

(** Takes ownership of a connected descriptor, including on failure. The descriptor must
    first be released from BarevIO. An already-owned descriptor is rejected without closing it. *)
PROCEDURE Begin*(fd: LONGINT; server: BOOLEAN; VAR key: Identity.Key;
    VAR pin: ARRAY OF CHAR; length: LONGINT): LONGINT;
VAR index, i: LONGINT; s: Session; expected: TLSBytes.Buffer; okay: BOOLEAN;
BEGIN
  lastError := "";
  FOR index := 0 TO maxSessions-1 DO
    IF (sessions[index] # NIL) & (sessions[index].fd = fd) & (fd >= 0) THEN
      COPY("descriptor already belongs to a TLS session", lastError); RETURN 0
    END
  END;
  IF (fd < 0) OR (length # 32) OR (length > LEN(pin)) THEN
    IF fd >= 0 THEN Internet.Disconnect(fd) END;
    COPY("a connected descriptor and exact peer key pin are required", lastError); RETURN 0
  END;
  index := 0;
  WHILE (index < maxSessions) & ((sessions[index] # NIL) OR (generations[index] = maxGeneration)) DO INC(index) END;
  IF index = maxSessions THEN Internet.Disconnect(fd); COPY("TLS session limit", lastError); RETURN 0 END;
  NEW(s); s.fd := fd; s.server := server; TLS.Init(s.live);
  IF ~Identity.ForTLS(key, s.identity) THEN
    Internet.Disconnect(fd); COPY("cannot create the local TLS identity", lastError); RETURN 0
  END;
  TLSBytes.Init(expected); FOR i := 0 TO 31 DO TLSBytes.AppendChar(expected, pin[i]) END;
  IF server THEN okay := Server.BeginEd25519(fd, s.identity, expected, s.pending)
  ELSE okay := TLS.BeginEd25519("barev", fd, s.identity, expected, s.live)
  END;
  IF ~okay THEN
    IF server THEN COPY(Server.lastError, lastError) ELSE COPY(TLS.lastError, lastError) END;
    TLSIdentity.Clear(s.identity); RETURN 0
  END;
  INC(generations[index]); sessions[index] := s;
  RETURN generations[index]*maxSessions+index+1
END Begin;

PROCEDURE Poll*(handle: LONGINT): LONGINT;
VAR s: Session; result: INTEGER;
BEGIN
  s := Find(handle); IF (s = NIL) OR s.failed OR s.closed THEN RETURN -1 END;
  IF s.live.handshakeDone THEN RETURN 1 END;
  IF s.server THEN result := Server.PollEd25519(s.pending, s.live)
  ELSE result := TLS.PollHandshake(s.live)
  END;
  IF result < 0 THEN
    IF s.server THEN RETURN Fail(s, Server.lastError) ELSE RETURN Fail(s, TLS.lastError) END
  END;
  IF (result = 1) & (~s.live.peerAuthenticated OR ~s.live.identitySent) THEN
    RETURN Fail(s, "mutual Ed25519 authentication did not complete")
  END;
  RETURN result
END Poll;

PROCEDURE Authenticated*(handle: LONGINT): BOOLEAN;
VAR s: Session;
BEGIN
  s := Find(handle);
  RETURN (s # NIL) & ~s.failed & ~s.closed & s.live.handshakeDone & s.live.peerAuthenticated & s.live.identitySent
END Authenticated;

PROCEDURE WantsWrite*(handle: LONGINT): BOOLEAN;
VAR s: Session;
BEGIN
  s := Find(handle);
  RETURN (s # NIL) & ~s.failed & ~s.closed & (Server.WantsWrite(s.pending) OR TLS.WantsWrite(s.live))
END WantsWrite;

PROCEDURE Pending*(handle: LONGINT): BOOLEAN;
VAR s: Session;
BEGIN s := Find(handle); RETURN Authenticated(handle) & TLS.PendingPlaintext(s.live) END Pending;

PROCEDURE Error*(handle: LONGINT; VAR text: ARRAY OF CHAR);
VAR s: Session;
BEGIN
  s := Find(handle);
  IF s = NIL THEN COPY(lastError, text) ELSE COPY(s.error, text) END
END Error;

(** Copies the public DER certificate of the local TLS identity. *)
PROCEDURE Certificate*(handle: LONGINT; VAR bytes: ARRAY OF CHAR): LONGINT;
VAR s: Session; i, length: LONGINT;
BEGIN
  s := Find(handle); IF (s = NIL) OR (s.identity = NIL) THEN RETURN 0 END;
  length := s.identity.certs[0].len; IF length > LEN(bytes) THEN RETURN 0 END;
  FOR i := 0 TO length-1 DO bytes[i] := s.identity.certs[0].data[i] END;
  RETURN length
END Certificate;

PROCEDURE Write*(handle: LONGINT; VAR bytes: ARRAY OF CHAR; length: LONGINT): LONGINT;
VAR s: Session; count, i, result: LONGINT;
BEGIN
  s := Find(handle);
  IF ~Authenticated(handle) OR (length <= 0) OR (length > LEN(bytes)) THEN RETURN -1 END;
  IF s.writingLength = 0 THEN
    count := length; IF count > maxPlain THEN count := maxPlain END;
    s.writingLength := count; FOR i := 0 TO count-1 DO s.writing[i] := bytes[i] END
  ELSE
    IF length < s.writingLength THEN RETURN Fail(s, "TLS write retry changed its unconsumed prefix") END;
    FOR i := 0 TO s.writingLength-1 DO
      IF s.writing[i] # bytes[i] THEN RETURN Fail(s, "TLS write retry changed its unconsumed prefix") END
    END
  END;
  result := TLS.WriteSome(s.live, s.writing, 0, s.writingLength);
  IF result = wouldBlock THEN RETURN result END;
  IF result < 0 THEN RETURN Fail(s, TLS.lastError) END;
  IF result # s.writingLength THEN RETURN Fail(s, "incomplete TLS record write") END;
  WipeWriting(s); RETURN result
END Write;

PROCEDURE Read*(handle: LONGINT; VAR bytes: ARRAY OF CHAR; length: LONGINT): LONGINT;
VAR s: Session; result: LONGINT;
BEGIN
  s := Find(handle);
  IF (s = NIL) OR (length <= 0) OR (length > maxPlain) OR (length > LEN(bytes)) THEN RETURN -1 END;
  IF s.closed THEN RETURN 0 END;
  IF ~Authenticated(handle) THEN RETURN -1 END;
  result := TLS.ReadSome(s.live, bytes, 0, length);
  IF (result < 0) & (result # wouldBlock) THEN RETURN Fail(s, TLS.lastError) END;
  IF result = 0 THEN s.closed := TRUE; TLS.CloseNow(s.live); s.fd := -1 END;
  RETURN result
END Read;

PROCEDURE Close*(handle: LONGINT);
VAR s: Session;
BEGIN
  s := Find(handle); IF s = NIL THEN RETURN END;
  Server.ClosePending(s.pending); TLS.CloseNow(s.live); TLSIdentity.Clear(s.identity); WipeWriting(s);
  sessions[(handle-1) MOD maxSessions] := NIL
END Close;

PROCEDURE Idle*(): BOOLEAN;
VAR index: LONGINT;
BEGIN
  FOR index := 0 TO maxSessions-1 DO IF sessions[index] # NIL THEN RETURN FALSE END END;
  RETURN TRUE
END Idle;

END BarevTLS.
