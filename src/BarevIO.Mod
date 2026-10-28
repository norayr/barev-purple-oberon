MODULE BarevIO;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Own socket objects while C holds descriptors for libpurple event watches.
   Release explicitly transfers ownership to libpurple's file-transfer engine. *)

IMPORT S := Sockets, A := BarevAddress;

CONST maxSockets = 128;
VAR sockets: ARRAY maxSockets OF S.Socket;
  lastError: LONGINT;

PROCEDURE Find(fd: LONGINT): S.Socket;
  VAR i: LONGINT;
BEGIN
  FOR i := 0 TO maxSockets-1 DO
    IF (sockets[i] # NIL) & (sockets[i].fd = fd) THEN RETURN sockets[i] END
  END;
  RETURN NIL
END Find;

PROCEDURE Keep(s: S.Socket): LONGINT;
  VAR i: LONGINT;
BEGIN
  IF s = NIL THEN lastError := S.res; RETURN -1 END;
  FOR i := 0 TO maxSockets-1 DO IF sockets[i] = NIL THEN sockets[i] := s; RETURN s.fd END END;
  S.Close(s); lastError := -24; RETURN -1
END Keep;

PROCEDURE Address(bytes: ARRAY OF CHAR; VAR address: S.Address): BOOLEAN;
  VAR ip: A.IP; i: LONGINT;
BEGIN
  IF ~A.ReadIP(bytes, ip) THEN RETURN FALSE END;
  address.family := S.Inet6; FOR i := 0 TO 15 DO address.addr[i] := ip[i] END;
  RETURN TRUE
END Address;

PROCEDURE Listen*(local: ARRAY OF CHAR; port, backlog: LONGINT): LONGINT;
  VAR address: S.Address;
BEGIN
  IF ~Address(local, address) THEN lastError := -22; RETURN -1 END;
  RETURN Keep(S.ListenNonblocking(address, port, backlog))
END Listen;

PROCEDURE Connect*(local, peer: ARRAY OF CHAR; port: LONGINT): LONGINT;
  VAR own, remote: S.Address;
BEGIN
  IF ~Address(local, own) OR ~Address(peer, remote) THEN lastError := -22; RETURN -1 END;
  RETURN Keep(S.ConnectFrom(own, remote, port))
END Connect;

PROCEDURE Accept*(fd: LONGINT): LONGINT;
  VAR endpoint: S.Endpoint; s: S.Socket;
BEGIN
  s := Find(fd); IF s = NIL THEN RETURN -1 END;
  RETURN Keep(S.AcceptNonblocking(s, endpoint))
END Accept;

PROCEDURE Pending*(fd: LONGINT): BOOLEAN;
  VAR s: S.Socket;
BEGIN s := Find(fd); RETURN (s # NIL) & S.Pending(s.res) END Pending;

PROCEDURE IsPending*(result: LONGINT): BOOLEAN;
BEGIN RETURN S.Pending(result) END IsPending;

PROCEDURE Error*(): LONGINT;
BEGIN RETURN lastError END Error;

PROCEDURE ConnectError*(fd: LONGINT): LONGINT;
BEGIN RETURN S.ConnectError(Find(fd)) END ConnectError;

PROCEDURE Endpoint(fd: LONGINT; local: BOOLEAN; VAR bytes: ARRAY OF CHAR;
    VAR scope: HUGEINT; VAR port: LONGINT): BOOLEAN;
  VAR endpoint: S.Endpoint; s: S.Socket; okay: BOOLEAN; i: LONGINT;
BEGIN
  s := Find(fd); IF (s = NIL) OR (LEN(bytes) # 16) THEN RETURN FALSE END;
  IF local THEN okay := S.LocalEndpoint(s, endpoint) ELSE okay := S.PeerEndpoint(s, endpoint) END;
  IF ~okay OR (endpoint.address.family # S.Inet6) THEN RETURN FALSE END;
  FOR i := 0 TO 15 DO bytes[i] := endpoint.address.addr[i] END;
  scope := endpoint.scope; port := endpoint.port; RETURN TRUE
END Endpoint;

PROCEDURE Local*(fd: LONGINT; VAR bytes: ARRAY OF CHAR; VAR scope: HUGEINT; VAR port: LONGINT): BOOLEAN;
BEGIN RETURN Endpoint(fd, TRUE, bytes, scope, port) END Local;

PROCEDURE Peer*(fd: LONGINT; VAR bytes: ARRAY OF CHAR; VAR scope: HUGEINT; VAR port: LONGINT): BOOLEAN;
BEGIN RETURN Endpoint(fd, FALSE, bytes, scope, port) END Peer;

PROCEDURE Read*(fd: LONGINT; VAR bytes: ARRAY OF CHAR; length: LONGINT): LONGINT;
BEGIN RETURN S.ReadDescriptor(fd, bytes, 0, length) END Read;

PROCEDURE Write*(fd: LONGINT; VAR bytes: ARRAY OF CHAR; length: LONGINT): LONGINT;
BEGIN RETURN S.WriteDescriptor(fd, bytes, 0, length) END Write;

PROCEDURE WouldBlock*(result: LONGINT): BOOLEAN;
BEGIN RETURN S.WouldBlock(result) END WouldBlock;

PROCEDURE Interrupted*(result: LONGINT): BOOLEAN;
BEGIN RETURN S.Interrupted(result) END Interrupted;

PROCEDURE Abort*(fd: LONGINT): BOOLEAN;
  VAR okay: BOOLEAN;
BEGIN okay := S.AbortDescriptor(fd); lastError := S.res; RETURN okay END Abort;

PROCEDURE Release*(fd: LONGINT): LONGINT;
  VAR i: LONGINT; s: S.Socket;
BEGIN
  FOR i := 0 TO maxSockets-1 DO
    s := sockets[i];
    IF (s # NIL) & (s.fd = fd) THEN sockets[i] := NIL; RETURN S.Release(s) END
  END;
  RETURN -1
END Release;

PROCEDURE Close*(fd: LONGINT);
  VAR i: LONGINT; s: S.Socket;
BEGIN
  FOR i := 0 TO maxSockets-1 DO
    s := sockets[i]; IF (s # NIL) & (s.fd = fd) THEN sockets[i] := NIL; S.Close(s); RETURN END
  END
END Close;

PROCEDURE Idle*(): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  FOR i := 0 TO maxSockets-1 DO IF sockets[i] # NIL THEN RETURN FALSE END END;
  RETURN TRUE
END Idle;

END BarevIO.
