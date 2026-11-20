MODULE BarevPublishing;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT S := BarevPostStore, P := BarevPost, A := BarevFeedAccess,
  Address := BarevAddress, Atom := BarevPostAtom, F := BarevPostFiles, I := XmppItems;

CONST
  okay* = S.okay; invalid* = S.invalid; denied* = S.denied; missing* = S.missing;
  conflict* = S.conflict; full* = S.full; stale* = S.stale;
  storageError* = 7; changed* = 8; wireFull* = 9; unavailable* = 10;

TYPE
  Service* = POINTER TO ServiceDesc;
  ServiceDesc* = RECORD
    profile: ARRAY 4096 OF CHAR; owner: ARRAY 65 OF CHAR;
    author: ARRAY Address.maxIdentityBytes OF CHAR;
    checkpoint: F.Context; store: S.Store; active, ready, known: BOOLEAN
  END;
  Cursor* = RECORD service: Service; position: S.Cursor END;

PROCEDURE FileStatus(status: LONGINT): LONGINT;
BEGIN
  CASE status OF
    F.okay: RETURN okay
  | F.missing: RETURN missing
  | F.invalid: RETURN invalid
  | F.changed: RETURN changed
  ELSE RETURN storageError
  END
END FileStatus;

PROCEDURE Ready*(service: Service): BOOLEAN;
BEGIN RETURN (service # NIL) & service.active & service.ready END Ready;

PROCEDURE Close*(VAR service: Service);
BEGIN
  IF service = NIL THEN RETURN END;
  service.active := FALSE; service.ready := FALSE;
  F.Close(service.checkpoint); S.Close(service.store); service := NIL
END Close;

PROCEDURE Open*(profile, owner, author: ARRAY OF CHAR; VAR service: Service): LONGINT;
VAR next: Service; context: F.Context; store: S.Store; status: LONGINT;
  canonical: ARRAY Address.maxIdentityBytes OF CHAR; ip: Address.IP;
BEGIN
  IF ~Address.Identity(author, canonical, ip) THEN RETURN invalid END;
  status := F.Load(profile, owner, context, store);
  IF (status # F.okay) & (status # F.missing) THEN RETURN FileStatus(status) END;
  NEW(next); COPY(profile, next.profile); COPY(owner, next.owner); COPY(canonical, next.author);
  next.checkpoint := context; next.store := store; next.active := TRUE;
  next.ready := status = F.okay; next.known := next.ready;
  service := next; RETURN FileStatus(status)
END Open;

PROCEDURE Reload*(service: Service): LONGINT;
VAR context: F.Context; store: S.Store; status: LONGINT;
BEGIN
  IF (service = NIL) OR ~service.active THEN RETURN invalid END;
  service.ready := FALSE;
  status := F.Load(service.profile, service.owner, context, store);
  IF (status # F.okay) & (status # F.missing) THEN RETURN FileStatus(status) END;
  IF (status = F.missing) & service.known THEN F.Close(context); RETURN missing END;
  F.Close(service.checkpoint); S.Close(service.store);
  service.checkpoint := context; service.store := store; service.ready := status = F.okay;
  IF service.ready THEN service.known := TRUE END;
  RETURN FileStatus(status)
END Reload;

PROCEDURE Commit(service: Service; VAR candidate: S.Store): LONGINT;
VAR status: LONGINT;
BEGIN
  status := F.Save(service.checkpoint, candidate);
  IF status = F.okay THEN
    S.Close(service.store); service.store := candidate; candidate := NIL;
    service.ready := TRUE; service.known := TRUE
  ELSE
    service.ready := FALSE; S.Close(candidate)
  END;
  RETURN FileStatus(status)
END Commit;

PROCEDURE Initialize*(service: Service; nodes, posts, bytes: LONGINT): LONGINT;
VAR candidate: S.Store;
BEGIN
  IF (service = NIL) OR ~service.active THEN RETURN invalid END;
  IF service.known THEN RETURN conflict END;
  candidate := S.New(service.owner, nodes, posts, bytes); IF candidate = NIL THEN RETURN invalid END;
  RETURN Commit(service, candidate)
END Initialize;

PROCEDURE AddNode*(service: Service; name, title: ARRAY OF CHAR; policy: A.Node): LONGINT;
VAR candidate: S.Store; status: LONGINT;
BEGIN
  IF ~Ready(service) THEN RETURN unavailable END;
  candidate := S.CopyOwner(service.store); status := S.AddNodeOwner(candidate, name, title, policy);
  IF status # okay THEN S.Close(candidate); RETURN status END;
  RETURN Commit(service, candidate)
END AddNode;

PROCEDURE Policy*(service: Service; name: ARRAY OF CHAR; policy: A.Node): LONGINT;
VAR candidate: S.Store; status: LONGINT;
BEGIN
  IF ~Ready(service) THEN RETURN unavailable END;
  candidate := S.CopyOwner(service.store); status := S.PolicyOwner(candidate, name, policy);
  IF status # okay THEN S.Close(candidate); RETURN status END;
  RETURN Commit(service, candidate)
END Policy;

PROCEDURE Wire(post: P.Post): LONGINT;
VAR bytes: I.Bytes; length: LONGINT;
BEGIN
  IF ~P.Valid(post) THEN RETURN invalid END;
  IF ~Atom.Encode(post, Atom.maxWireBytes, bytes, length) THEN RETURN wireFull END;
  RETURN okay
END Wire;

PROCEDURE Put*(service: Service; node: ARRAY OF CHAR; post: P.Post): LONGINT;
VAR candidate: S.Store; status: LONGINT; header: P.Header; parent: S.NodeInfo;
BEGIN
  IF ~Ready(service) THEN RETURN unavailable END;
  IF ~P.Describe(post, header) THEN RETURN invalid END;
  IF (header.owner # service.owner) OR (header.author # service.author) THEN RETURN denied END;
  IF (header.replyTo[0] # 0X) & ~S.ReferenceOwner(service.store, header.replyTo, parent) THEN RETURN denied END;
  status := Wire(post); IF status # okay THEN RETURN status END;
  candidate := S.CopyOwner(service.store); status := S.PutOwner(candidate, node, post);
  IF status # okay THEN S.Close(candidate); RETURN status END;
  RETURN Commit(service, candidate)
END Put;

PROCEDURE Edit*(service: Service; node: ARRAY OF CHAR; expected, replacement: P.Post): LONGINT;
VAR candidate: S.Store; status: LONGINT;
BEGIN
  IF ~Ready(service) THEN RETURN unavailable END;
  status := Wire(replacement); IF status # okay THEN RETURN status END;
  candidate := S.CopyOwner(service.store); status := S.EditOwner(candidate, node, expected, replacement);
  IF status # okay THEN S.Close(candidate); RETURN status END;
  RETURN Commit(service, candidate)
END Edit;

PROCEDURE Retract*(service: Service; node, itemID: ARRAY OF CHAR): LONGINT;
VAR candidate: S.Store; status: LONGINT;
BEGIN
  IF ~Ready(service) THEN RETURN unavailable END;
  candidate := S.CopyOwner(service.store); status := S.RetractOwner(candidate, node, itemID);
  IF status # okay THEN S.Close(candidate); RETURN status END;
  RETURN Commit(service, candidate)
END Retract;

PROCEDURE Node*(service: Service; index: LONGINT; VAR info: S.NodeInfo): BOOLEAN;
BEGIN RETURN Ready(service) & S.NodeOwner(service.store, index, info) END Node;

PROCEDURE Get*(service: Service; node, itemID: ARRAY OF CHAR): P.Post;
BEGIN IF ~Ready(service) THEN RETURN NIL END; RETURN S.GetOwner(service.store, node, itemID) END Get;

PROCEDURE Begin*(service: Service; node: ARRAY OF CHAR; VAR cursor: Cursor): LONGINT;
BEGIN
  cursor.service := NIL; S.Cancel(cursor.position);
  IF ~Ready(service) THEN RETURN unavailable END;
  cursor.service := service; RETURN S.BeginOwner(service.store, node, cursor.position)
END Begin;

PROCEDURE Read*(service: Service; VAR cursor: Cursor; maximum: LONGINT; VAR page: S.Page): LONGINT;
BEGIN
  page := NIL; IF ~Ready(service) THEN RETURN unavailable END;
  IF cursor.service # service THEN RETURN invalid END;
  RETURN S.ReadOwner(cursor.position, maximum, page)
END Read;

END BarevPublishing.
