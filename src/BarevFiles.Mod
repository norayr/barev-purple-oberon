MODULE BarevFiles;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Bounded file negotiation and handshake state. Accounts own deadlines;
   established data sockets can outlive their negotiating messaging stream.
   Native adapters receive monotonically increasing tokens, never pointers. *)

IMPORT I := XmppItems, S := LongStrings, F := BarevFileStanzas,
  Socks := BarevSocks, SHA := BarevSHA1, IntStr;

CONST
  maxTransfers* = 16; maxPerPeer* = 4;
  failed* = -1; offered* = 1; waitingReply* = 2; needListener* = 3;
  waitingHost* = 4; waitingSocket* = 5; needConnect* = 6;
  handshaking* = 7; ready* = 8; active* = 9;
  negotiationSeconds* = 120; idleSeconds* = 120;
  noFailure* = 0; cancelled* = 1; peerRejected* = 2; invalidReply* = 3;
  invalidHost* = 4; handshakeFailed* = 5; negotiationTimeout* = 6;
  idleTimeout* = 7; connectionClosed* = 8;

TYPE
  Transfer = POINTER TO RECORD
    token, account, owner, phase, size, port, age, reason, failurePhase: LONGINT;
    send, announced, confirmed, detached: BOOLEAN;
    local, peer, name, sid, offerID, queryID, host: I.Bytes;
    output: I.Item; socks: Socks.Session
  END;

VAR entries: ARRAY maxTransfers OF Transfer; serial: LONGINT;

PROCEDURE Find(token: LONGINT): Transfer;
  VAR i: LONGINT;
BEGIN
  FOR i := 0 TO maxTransfers-1 DO
    IF (entries[i] # NIL) & (entries[i].token = token) THEN RETURN entries[i] END
  END;
  RETURN NIL
END Find;

PROCEDURE New(account, owner: LONGINT; local, peer: ARRAY OF CHAR; send: BOOLEAN): Transfer;
  VAR i, slot, count: LONGINT; t: Transfer;
BEGIN
  slot := -1; count := 0;
  FOR i := 0 TO maxTransfers-1 DO
    IF entries[i] = NIL THEN slot := i
    ELSIF (entries[i].account = account) & F.SameIdentity(entries[i].peer^, peer) THEN INC(count)
    END
  END;
  IF (account <= 0) OR (owner <= 0) OR (slot < 0) OR (count >= maxPerPeer) OR (serial = MAX(LONGINT)) THEN RETURN NIL END;
  INC(serial); NEW(t); t.token := serial; t.account := account; t.owner := owner; t.send := send;
  t.local := I.Copy8(local); t.peer := I.Copy8(peer); entries[slot] := t; RETURN t
END New;

PROCEDURE Identifier(prefix: CHAR; token: LONGINT): I.Bytes;
  VAR number, result: ARRAY 32 OF CHAR; i: LONGINT;
BEGIN
  IntStr.IntToStr(token, number); result[0] := prefix;
  FOR i := 0 TO S.Length8(number) DO result[i+1] := number[i] END;
  RETURN I.Copy8(result)
END Identifier;

PROCEDURE Offer*(account, owner: LONGINT; local, peer, name: ARRAY OF CHAR; size: LONGINT): LONGINT;
  VAR t: Transfer;
BEGIN
  IF ~F.Name(name) OR (size < 0) OR (size > F.maxFileBytes) THEN RETURN 0 END;
  t := New(account, owner, local, peer, TRUE); IF t = NIL THEN RETURN 0 END;
  t.name := I.Copy8(name); t.size := size; t.sid := Identifier("f", t.token); t.offerID := t.sid;
  t.queryID := Identifier("b", t.token); t.output := F.Offer(t.offerID^, t.sid^, name, size);
  t.phase := waitingReply; t.announced := TRUE; RETURN t.token
END Offer;

PROCEDURE Accept*(token: LONGINT): BOOLEAN;
  VAR t: Transfer;
BEGIN
  t := Find(token); IF (t = NIL) OR (t.phase # offered) THEN RETURN FALSE END;
  t.phase := waitingHost; t.age := 0; t.output := F.Accept(t.offerID^); RETURN TRUE
END Accept;

PROCEDURE Fail(t: Transfer; reason: LONGINT);
BEGIN
  IF t.phase # failed THEN
    t.failurePhase := t.phase; t.reason := reason; t.phase := failed
  END
END Fail;

PROCEDURE Abort(t: Transfer; reason: LONGINT);
BEGIN
  IF ~t.send & ~t.detached & (t.phase # failed) THEN
    IF t.queryID # NIL THEN t.output := F.Reject(t.queryID^, "item-not-found")
    ELSE t.output := F.Reject(t.offerID^, "forbidden")
    END
  END;
  Fail(t, reason)
END Abort;

PROCEDURE Cancel*(token: LONGINT);
  VAR t: Transfer;
BEGIN
  t := Find(token); IF t # NIL THEN Abort(t, cancelled) END
END Cancel;

(* Keep the first failure and its phase until the native owner has logged it. *)
PROCEDURE Diagnostics*(token: LONGINT; VAR phase, age: LONGINT): LONGINT;
  VAR t: Transfer;
BEGIN
  t := Find(token); phase := failed; age := 0; IF t = NIL THEN RETURN noFailure END;
  phase := t.phase; age := t.age;
  IF phase = failed THEN phase := t.failurePhase END;
  RETURN t.reason
END Diagnostics;

PROCEDURE Receive*(account, owner: LONGINT; local, peer: ARRAY OF CHAR; item: I.Item; VAR reply: I.Item): BOOLEAN;
  VAR kind, id, sid, name, host: I.Bytes; t: Transfer; i, size, port: LONGINT;
    si, query: I.Item;
BEGIN
  reply := NIL; kind := F.Attribute(item, "type"); id := F.Attribute(item, "id");
  IF (kind = NIL) OR ~F.ID(id) THEN RETURN FALSE END;
  si := item.First(F.siURI, "si"); query := item.First(F.streamURI, "query");
  IF kind^ = "set" THEN
    IF si # NIL THEN
      IF ~F.ReadOffer(item, sid, name, size) THEN reply := F.Reject(id^, "bad-request"); RETURN TRUE END;
      FOR i := 0 TO maxTransfers-1 DO
        t := entries[i];
        IF (t # NIL) & (t.owner = owner) & ~t.send & ((t.sid^ = sid^) OR (t.offerID^ = id^)) THEN
          reply := F.Reject(id^, "unexpected-request"); RETURN TRUE
        END
      END;
      t := New(account, owner, local, peer, FALSE);
      IF t = NIL THEN reply := F.Reject(id^, "resource-constraint"); RETURN TRUE END;
      t.sid := sid; t.offerID := id; t.name := name; t.size := size; t.phase := offered; RETURN TRUE
    ELSIF query # NIL THEN
      sid := F.Attribute(query, "sid");
      IF F.ID(sid) THEN
        FOR i := 0 TO maxTransfers-1 DO
          t := entries[i];
          IF (t # NIL) & (t.owner = owner) & ~t.send & (t.phase = waitingHost) & (t.sid^ = sid^) THEN
            IF F.ReadHost(item, peer, sid, host, port) THEN
              t.queryID := id; t.host := host; t.port := port; t.phase := needConnect; t.age := 0
            ELSE Fail(t, invalidHost); reply := F.Reject(id^, "item-not-found")
            END;
            RETURN TRUE
          END
        END
      END;
      reply := F.Reject(id^, "item-not-found"); RETURN TRUE
    END
  ELSIF (kind^ = "result") OR (kind^ = "error") THEN
    FOR i := 0 TO maxTransfers-1 DO
      t := entries[i];
      IF (t # NIL) & (t.owner = owner) & t.send THEN
        IF (t.phase = waitingReply) & (t.offerID^ = id^) THEN
          IF (kind^ = "result") & F.Accepted(item) THEN t.phase := needListener; t.age := 0
          ELSIF kind^ = "error" THEN Fail(t, peerRejected)
          ELSE Fail(t, invalidReply)
          END;
          RETURN TRUE
        ELSIF ((t.phase = waitingSocket) OR (t.phase = handshaking)) & (t.queryID^ = id^) THEN
          IF (kind^ = "result") & F.Used(item, t.local^) THEN t.confirmed := TRUE; t.age := 0
          ELSIF kind^ = "error" THEN Fail(t, peerRejected)
          ELSE Fail(t, invalidReply)
          END;
          RETURN TRUE
        END
      END
    END
  END;
  RETURN FALSE
END Receive;

PROCEDURE TakePacket*(owner: LONGINT): I.Item;
  VAR i: LONGINT; packet: I.Item;
BEGIN
  FOR i := 0 TO maxTransfers-1 DO
    IF (entries[i] # NIL) & (entries[i].owner = owner) & (entries[i].output # NIL) THEN
      packet := entries[i].output; entries[i].output := NIL;
      F.Attr(packet, "from", entries[i].local^); F.Attr(packet, "to", entries[i].peer^); RETURN packet
    END
  END;
  RETURN NIL
END TakePacket;

PROCEDURE TakeOffer*(owner: LONGINT; VAR peer, name: ARRAY OF CHAR; VAR size: LONGINT): LONGINT;
  VAR i: LONGINT; t: Transfer;
BEGIN
  FOR i := 0 TO maxTransfers-1 DO
    t := entries[i];
    IF (t # NIL) & (t.owner = owner) & (t.phase = offered) & ~t.announced THEN
      IF (LEN(peer) <= S.Length8(t.peer^)) OR (LEN(name) <= S.Length8(t.name^)) THEN RETURN 0 END;
      COPY(t.peer^, peer); COPY(t.name^, name); size := t.size; t.announced := TRUE; RETURN t.token
    END
  END;
  RETURN 0
END TakeOffer;

PROCEDURE Listening*(token: LONGINT; address: ARRAY OF CHAR; port: LONGINT): BOOLEAN;
  VAR t: Transfer;
BEGIN
  t := Find(token);
  IF (t = NIL) OR (t.phase # needListener) OR (port < F.portMin) OR (port > F.portMax) THEN RETURN FALSE END;
  t.phase := waitingSocket; t.age := 0; t.output := F.Host(t.queryID^, t.sid^, t.local^, address, port); RETURN TRUE
END Listening;

PROCEDURE Endpoint*(token: LONGINT; VAR host: ARRAY OF CHAR): LONGINT;
  VAR t: Transfer;
BEGIN
  t := Find(token); IF (t = NIL) OR (t.host = NIL) OR (LEN(host) <= S.Length8(t.host^)) THEN RETURN 0 END;
  COPY(t.host^, host); RETURN t.port
END Endpoint;

PROCEDURE OpenSocket*(token: LONGINT): BOOLEAN;
  VAR t: Transfer; data, hash: I.Bytes; i, n, j: LONGINT;
BEGIN
  t := Find(token); IF (t = NIL) OR ((t.phase # waitingSocket) & (t.phase # needConnect)) THEN RETURN FALSE END;
  n := S.Length8(t.sid^)+S.Length8(t.local^)+S.Length8(t.peer^); NEW(data, n);
  j := 0; FOR i := 0 TO S.Length8(t.sid^)-1 DO data[j] := t.sid[i]; INC(j) END;
  IF t.send THEN
    FOR i := 0 TO S.Length8(t.local^)-1 DO data[j] := t.local[i]; INC(j) END;
    FOR i := 0 TO S.Length8(t.peer^)-1 DO data[j] := t.peer[i]; INC(j) END
  ELSE
    FOR i := 0 TO S.Length8(t.peer^)-1 DO data[j] := t.peer[i]; INC(j) END;
    FOR i := 0 TO S.Length8(t.local^)-1 DO data[j] := t.local[i]; INC(j) END
  END;
  hash := SHA.Hash(data^, n); t.socks := Socks.New(t.send, hash^); t.phase := handshaking; t.age := 0;
  RETURN t.socks # NIL
END OpenSocket;

PROCEDURE State*(token: LONGINT): LONGINT;
  VAR t: Transfer;
BEGIN
  t := Find(token); IF t = NIL THEN RETURN failed END;
  IF t.phase = handshaking THEN
    IF Socks.Failed(t.socks) THEN Abort(t, handshakeFailed)
    ELSIF Socks.Ready(t.socks) & (~t.send OR t.confirmed) THEN
      t.phase := ready; t.age := 0;
      IF ~t.send THEN t.output := F.Confirm(t.queryID^, t.peer^) END
    END
  END;
  RETURN t.phase
END State;

PROCEDURE Need*(token: LONGINT): LONGINT;
  VAR t: Transfer;
BEGIN t := Find(token); IF (t = NIL) OR (t.phase # handshaking) THEN RETURN 0 END; RETURN Socks.Need(t.socks) END Need;

PROCEDURE Feed*(token: LONGINT; bytes: ARRAY OF CHAR; length: LONGINT);
  VAR t: Transfer;
BEGIN t := Find(token); IF (t # NIL) & (t.phase = handshaking) THEN Socks.Feed(t.socks, bytes, length); t.age := 0 END END Feed;

PROCEDURE Peek*(token: LONGINT; VAR bytes: ARRAY OF CHAR): LONGINT;
  VAR t: Transfer;
BEGIN t := Find(token); IF (t = NIL) OR (t.phase # handshaking) THEN RETURN 0 END; RETURN Socks.Peek(t.socks, bytes) END Peek;

PROCEDURE Sent*(token, length: LONGINT);
  VAR t: Transfer;
BEGIN t := Find(token); IF (t # NIL) & (t.phase = handshaking) THEN Socks.Sent(t.socks, length); t.age := 0 END END Sent;

PROCEDURE Started*(token: LONGINT);
  VAR t: Transfer;
BEGIN t := Find(token); IF (t # NIL) & (t.phase = ready) THEN t.phase := active; t.age := 0 END END Started;

PROCEDURE Progress*(token: LONGINT);
  VAR t: Transfer;
BEGIN t := Find(token); IF (t # NIL) & (t.phase = active) THEN t.age := 0 END END Progress;

PROCEDURE Forget*(token: LONGINT);
  VAR i: LONGINT;
BEGIN
  FOR i := 0 TO maxTransfers-1 DO
    IF (entries[i] # NIL) & (entries[i].token = token) THEN entries[i] := NIL; RETURN END
  END
END Forget;

PROCEDURE DropOwner*(owner: LONGINT; keepActive: BOOLEAN);
  VAR i: LONGINT;
BEGIN
  FOR i := 0 TO maxTransfers-1 DO
    IF (entries[i] # NIL) & (entries[i].owner = owner) THEN
      IF keepActive & (entries[i].phase = active) THEN
        entries[i].detached := TRUE; entries[i].output := NIL
      ELSIF ~entries[i].announced THEN entries[i] := NIL
      ELSE Fail(entries[i], connectionClosed); entries[i].output := NIL
      END
    END
  END
END DropOwner;

(* Explicit roster/account removal still cancels detached data sockets. *)
PROCEDURE DropPeer*(account: LONGINT; peer: ARRAY OF CHAR);
  VAR i: LONGINT; t: Transfer;
BEGIN
  FOR i := 0 TO maxTransfers-1 DO
    t := entries[i];
    IF (t # NIL) & (t.account = account) & F.SameIdentity(t.peer^, peer) THEN
      IF ~t.announced THEN entries[i] := NIL
      ELSE Fail(t, connectionClosed); t.output := NIL
      END
    END
  END
END DropPeer;

PROCEDURE DropAccount*(account: LONGINT);
  VAR i: LONGINT; t: Transfer;
BEGIN
  FOR i := 0 TO maxTransfers-1 DO
    t := entries[i];
    IF (t # NIL) & (t.account = account) THEN
      IF ~t.announced THEN entries[i] := NIL
      ELSE Fail(t, connectionClosed); t.output := NIL
      END
    END
  END
END DropAccount;

PROCEDURE Tick*(account: LONGINT);
  VAR i: LONGINT; t: Transfer;
BEGIN
  FOR i := 0 TO maxTransfers-1 DO
    t := entries[i];
    IF (t # NIL) & (t.account = account) & (t.phase # failed) THEN
      INC(t.age);
      IF ((t.phase # active) & (t.age >= negotiationSeconds)) OR ((t.phase = active) & (t.age >= idleSeconds)) THEN
        IF t.phase = active THEN Abort(t, idleTimeout) ELSE Abort(t, negotiationTimeout) END;
        IF ~t.announced THEN entries[i] := NIL END
      END
    END
  END
END Tick;

END BarevFiles.
