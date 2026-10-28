MODULE BarevNetwork;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Native adapters supply monotonic microseconds and socket facts. This module
   owns dial scheduling, attempt deadlines and receive budgets using tokens. *)

IMPORT A := BarevAddress;

CONST
  maxAccounts* = 8; maxContacts* = 128; maxSockets* = 64;
  initialRetry* = 5; maximumRetry* = 30; attemptSeconds* = 30;
  receiveBytesPerSecond* = 524288; defaultPort* = 1337;

TYPE
  Contact = RECORD
    enabled, online, attempted: BOOLEAN; ip: A.IP; port, backoff: LONGINT;
    retry, lastAttempt: HUGEINT
  END;
  Account = POINTER TO RECORD
    token: LONGINT; local: A.IP; contacts: ARRAY maxContacts OF Contact; lastTick: HUGEINT
  END;
  Socket = POINTER TO RECORD
    token, contact, received: LONGINT; account: Account; ready: BOOLEAN;
    started, second: HUGEINT
  END;

VAR accounts: ARRAY maxAccounts OF Account; sockets: ARRAY maxSockets OF Socket; serial: LONGINT;

PROCEDURE Find(account: LONGINT): Account;
  VAR i: LONGINT;
BEGIN
  FOR i := 0 TO maxAccounts-1 DO
    IF (accounts[i] # NIL) & (accounts[i].token = account) THEN RETURN accounts[i] END
  END;
  RETURN NIL
END Find;

PROCEDURE FindSocket(token: LONGINT): Socket;
  VAR i: LONGINT;
BEGIN
  FOR i := 0 TO maxSockets-1 DO
    IF (sockets[i] # NIL) & (sockets[i].token = token) THEN RETURN sockets[i] END
  END;
  RETURN NIL
END FindSocket;

PROCEDURE Open*(account: LONGINT; local: A.IP): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  IF (account <= 0) OR (Find(account) # NIL) OR ~A.Yggdrasil(local) THEN RETURN FALSE END;
  FOR i := 0 TO maxAccounts-1 DO
    IF accounts[i] = NIL THEN
      NEW(accounts[i]); accounts[i].token := account; accounts[i].local := local;
      accounts[i].lastTick := -1; RETURN TRUE
    END
  END;
  RETURN FALSE
END Open;

PROCEDURE Close*(account: LONGINT);
  VAR i: LONGINT;
BEGIN
  FOR i := 0 TO maxSockets-1 DO
    IF (sockets[i] # NIL) & (sockets[i].account.token = account) THEN sockets[i] := NIL END
  END;
  FOR i := 0 TO maxAccounts-1 DO
    IF (accounts[i] # NIL) & (accounts[i].token = account) THEN accounts[i] := NIL END
  END
END Close;

PROCEDURE AddContact*(account, contact: LONGINT; ip: A.IP);
  VAR a: Account;
BEGIN
  a := Find(account);
  IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) OR ~A.Yggdrasil(ip) THEN RETURN END;
  IF a.contacts[contact-1].enabled THEN RETURN END;
  DEC(contact); a.contacts[contact].enabled := TRUE; a.contacts[contact].ip := ip;
  a.contacts[contact].port := defaultPort; a.contacts[contact].backoff := initialRetry
END AddContact;

PROCEDURE SetPort*(account, contact, port: LONGINT): BOOLEAN;
  VAR a: Account;
BEGIN
  a := Find(account);
  IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) OR ~A.Port(port) THEN RETURN FALSE END;
  IF ~a.contacts[contact-1].enabled THEN RETURN FALSE END;
  a.contacts[contact-1].port := port; RETURN TRUE
END SetPort;

PROCEDURE RemoveContact*(account, contact: LONGINT);
  VAR a: Account; i: LONGINT; empty: Contact;
BEGIN
  a := Find(account); IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) THEN RETURN END;
  FOR i := 0 TO maxSockets-1 DO
    IF (sockets[i] # NIL) & (sockets[i].account = a) & (sockets[i].contact = contact) THEN sockets[i] := NIL END
  END;
  empty.enabled := FALSE; empty.online := FALSE; empty.attempted := FALSE;
  empty.port := 0; empty.backoff := 0; empty.retry := 0; empty.lastAttempt := 0;
  FOR i := 0 TO 15 DO empty.ip[i] := 0X END;
  a.contacts[contact-1] := empty
END RemoveContact;

PROCEDURE Online*(account, contact: LONGINT; online: BOOLEAN);
  VAR a: Account;
BEGIN
  a := Find(account); IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) THEN RETURN END;
  IF ~a.contacts[contact-1].enabled THEN RETURN END;
  a.contacts[contact-1].online := online;
  IF online THEN a.contacts[contact-1].backoff := initialRetry END
END Online;

PROCEDURE Busy(a: Account; contact: LONGINT): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  IF a.contacts[contact-1].online THEN RETURN TRUE END;
  FOR i := 0 TO maxSockets-1 DO
    IF (sockets[i] # NIL) & (sockets[i].account = a) & (sockets[i].contact = contact) THEN RETURN TRUE END
  END;
  RETURN FALSE
END Busy;

PROCEDURE RequestDial*(account, contact: LONGINT);
  VAR a: Account;
BEGIN
  a := Find(account); IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) THEN RETURN END;
  IF a.contacts[contact-1].enabled & ~Busy(a, contact) THEN a.contacts[contact-1].retry := 0 END
END RequestDial;

PROCEDURE NextDial*(account: LONGINT; now: HUGEINT): LONGINT;
  VAR a: Account; i, delay: LONGINT;
BEGIN
  a := Find(account); IF (a = NIL) OR (now < 0) THEN RETURN 0 END;
  FOR i := 0 TO maxContacts-1 DO
    IF a.contacts[i].enabled & (now >= a.contacts[i].retry) & ~Busy(a, i+1) &
       (~a.contacts[i].attempted OR (now > a.contacts[i].lastAttempt)) THEN
      delay := a.contacts[i].backoff*1000000;
      a.contacts[i].lastAttempt := now; a.contacts[i].attempted := TRUE;
      IF now > MAX(HUGEINT)-delay THEN a.contacts[i].retry := MAX(HUGEINT)
      ELSE a.contacts[i].retry := now+delay
      END;
      IF a.contacts[i].backoff < maximumRetry THEN
        a.contacts[i].backoff := 2*a.contacts[i].backoff;
        IF a.contacts[i].backoff > maximumRetry THEN a.contacts[i].backoff := maximumRetry END
      END;
      RETURN i+1
    END
  END;
  RETURN 0
END NextDial;

PROCEDURE Destination*(account, contact: LONGINT; VAR ip: ARRAY OF CHAR): LONGINT;
  VAR a: Account; i: LONGINT;
BEGIN
  a := Find(account);
  IF (a = NIL) OR (contact < 1) OR (contact > maxContacts) OR (LEN(ip) # 16) THEN RETURN 0 END;
  IF ~a.contacts[contact-1].enabled THEN RETURN 0 END;
  FOR i := 0 TO 15 DO ip[i] := a.contacts[contact-1].ip[i] END;
  RETURN a.contacts[contact-1].port
END Destination;

PROCEDURE SocketEndpoints*(token: LONGINT; local, peer: ARRAY OF CHAR; localScope, peerScope: HUGEINT): BOOLEAN;
  VAR s: Socket; expected: A.IP;
BEGIN
  s := FindSocket(token); IF s = NIL THEN RETURN FALSE END;
  expected := s.account.local;
  IF s.contact > 0 THEN
    IF ~s.account.contacts[s.contact-1].enabled THEN RETURN FALSE END;
    expected := s.account.contacts[s.contact-1].ip
  END;
  RETURN A.SocketEndpoints(local, peer, s.account.local, expected, localScope, peerScope, s.contact > 0)
END SocketEndpoints;

PROCEDURE NewSocket*(account, contact: LONGINT; now: HUGEINT): LONGINT;
  VAR a: Account; i: LONGINT;
BEGIN
  a := Find(account);
  IF (a = NIL) OR (now < 0) OR (contact < 0) OR (contact > maxContacts) OR (serial = MAX(LONGINT)) THEN RETURN 0 END;
  IF (contact > 0) & ~a.contacts[contact-1].enabled THEN RETURN 0 END;
  IF (contact > 0) & Busy(a, contact) THEN RETURN 0 END;
  FOR i := 0 TO maxSockets-1 DO
    IF sockets[i] = NIL THEN
      NEW(sockets[i]); INC(serial); sockets[i].token := serial; sockets[i].account := a;
      sockets[i].contact := contact; sockets[i].started := now; sockets[i].second := now DIV 1000000;
      RETURN serial
    END
  END;
  RETURN 0
END NewSocket;

PROCEDURE DropSocket*(token: LONGINT);
  VAR i: LONGINT;
BEGIN
  FOR i := 0 TO maxSockets-1 DO
    IF (sockets[i] # NIL) & (sockets[i].token = token) THEN sockets[i] := NIL; RETURN END
  END
END DropSocket;

PROCEDURE Ready*(token: LONGINT);
  VAR s: Socket;
BEGIN s := FindSocket(token); IF s # NIL THEN s.ready := TRUE END END Ready;

PROCEDURE Owns*(token, account, contact: LONGINT): BOOLEAN;
  VAR s: Socket;
BEGIN
  s := FindSocket(token);
  RETURN (s # NIL) & (s.account.token = account) & (s.contact = contact)
END Owns;

PROCEDURE Expired*(token: LONGINT; now: HUGEINT): BOOLEAN;
  VAR s: Socket;
BEGIN
  s := FindSocket(token); IF (s = NIL) OR (now < 0) THEN RETURN TRUE END;
  RETURN ~s.ready & (now >= s.started) & (now-s.started >= attemptSeconds*1000000)
END Expired;

PROCEDURE Receive*(token: LONGINT; now: HUGEINT; length: LONGINT): BOOLEAN;
  VAR s: Socket; second: HUGEINT;
BEGIN
  s := FindSocket(token); IF (s = NIL) OR (now < 0) OR (length < 0) THEN RETURN FALSE END;
  second := now DIV 1000000;
  IF second > s.second THEN s.second := second; s.received := 0 END;
  IF length > receiveBytesPerSecond-s.received THEN RETURN FALSE END;
  INC(s.received, length); RETURN TRUE
END Receive;

PROCEDURE Advance*(account: LONGINT; now: HUGEINT): LONGINT;
  VAR a: Account; elapsed: HUGEINT;
BEGIN
  a := Find(account); IF (a = NIL) OR (now < 0) THEN RETURN 0 END;
  IF a.lastTick < 0 THEN a.lastTick := now; RETURN 0 END;
  IF now < a.lastTick THEN RETURN 0 END;
  elapsed := (now-a.lastTick) DIV 1000000; IF elapsed > 300 THEN elapsed := 300 END;
  INC(a.lastTick, elapsed*1000000); RETURN SHORT(elapsed)
END Advance;

END BarevNetwork.
