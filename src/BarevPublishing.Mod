MODULE BarevPublishing;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT S := BarevPostStore, P := BarevPost, A := BarevFeedAccess,
  Address := BarevAddress, Atom := BarevPostAtom, F := BarevPostFiles,
  Async := BarevPostAsync, I := XmppItems;

CONST
  okay* = S.okay; invalid* = S.invalid; denied* = S.denied; missing* = S.missing;
  conflict* = S.conflict; full* = S.full; stale* = S.stale;
  storageError* = 7; changed* = 8; wireFull* = 9; unavailable* = 10;
  pending* = 11; busy* = 12;
  loading = 1; saving = 2;

TYPE
  Service* = POINTER TO ServiceDesc;
  ServiceDesc* = RECORD
    profile: ARRAY 4096 OF CHAR; owner: ARRAY 65 OF CHAR;
    author: ARRAY Address.maxIdentityBytes OF CHAR;
    checkpoint: F.Context; store, candidate: S.Store; active, ready, known, asynchronous: BOOLEAN;
    context: Async.Context; request: Async.Request; operation: LONGINT
  END;
  Cursor* = RECORD service: Service; position: S.Cursor END;

PROCEDURE FileStatus(status: LONGINT): LONGINT;
BEGIN
  CASE status OF
    F.okay: RETURN okay
  | F.missing: RETURN missing
  | F.invalid: RETURN invalid
  | F.changed: RETURN changed
  | Async.pending: RETURN pending
  | Async.busy: RETURN busy
  ELSE RETURN storageError
  END
END FileStatus;

PROCEDURE Ready*(service: Service): BOOLEAN;
BEGIN RETURN (service # NIL) & service.active & service.ready END Ready;

PROCEDURE Busy*(service: Service): BOOLEAN;
BEGIN RETURN (service # NIL) & service.active & (service.operation # 0) END Busy;

PROCEDURE Start*(): BOOLEAN;
BEGIN RETURN Async.Start() END Start;

PROCEDURE MutationStatus(service: Service): LONGINT;
BEGIN
  IF Busy(service) THEN RETURN busy END;
  IF ~Ready(service) THEN RETURN unavailable END;
  RETURN okay
END MutationStatus;

PROCEDURE Close*(VAR service: Service);
BEGIN
  IF service = NIL THEN RETURN END;
  service.active := FALSE; service.ready := FALSE;
  Async.Cancel(service.request); Async.Close(service.context); S.Close(service.candidate);
  service.operation := 0; F.Close(service.checkpoint); S.Close(service.store); service := NIL
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

PROCEDURE OpenAsync*(profile, owner, author: ARRAY OF CHAR; VAR service: Service): LONGINT;
VAR next: Service; request: Async.Request; status: LONGINT;
  canonical: ARRAY Address.maxIdentityBytes OF CHAR; ip: Address.IP;
BEGIN
  IF ~Address.Identity(author, canonical, ip) THEN RETURN invalid END;
  status := Async.Load(profile, owner, request);
  IF status # Async.pending THEN RETURN FileStatus(status) END;
  NEW(next); COPY(profile, next.profile); COPY(owner, next.owner); COPY(canonical, next.author);
  next.active := TRUE; next.asynchronous := TRUE; next.request := request; next.operation := loading;
  service := next; RETURN pending
END OpenAsync;

PROCEDURE Poll*(service: Service): LONGINT;
VAR status: LONGINT; context: Async.Context; store: S.Store;
BEGIN
  IF ~Busy(service) THEN RETURN invalid END;
  IF service.operation = loading THEN
    status := Async.Loaded(service.request, context, store);
    IF status = Async.pending THEN RETURN pending END;
    service.operation := 0;
    IF (status = Async.missing) & service.known THEN
      Async.Close(context); service.ready := FALSE; RETURN missing
    END;
    IF (status = Async.okay) OR (status = Async.missing) THEN
      Async.Close(service.context); S.Close(service.store);
      service.context := context; service.store := store; service.ready := status = Async.okay;
      IF service.ready THEN service.known := TRUE END
    ELSE service.ready := FALSE
    END
  ELSE
    status := Async.Saved(service.request);
    IF status = Async.pending THEN RETURN pending END;
    service.operation := 0;
    IF status = Async.okay THEN
      S.Close(service.store); service.store := service.candidate; service.candidate := NIL;
      service.ready := TRUE; service.known := TRUE
    ELSE service.ready := FALSE; S.Close(service.candidate)
    END
  END;
  RETURN FileStatus(status)
END Poll;

PROCEDURE Reload*(service: Service): LONGINT;
VAR context: F.Context; store: S.Store; status: LONGINT;
BEGIN
  IF (service = NIL) OR ~service.active THEN RETURN invalid END;
  IF Busy(service) THEN RETURN busy END;
  IF service.asynchronous THEN
    status := Async.Load(service.profile, service.owner, service.request);
    IF status = Async.pending THEN service.operation := loading; service.ready := FALSE END;
    RETURN FileStatus(status)
  END;
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
  IF service.asynchronous THEN
    status := Async.Save(service.context, candidate, service.request);
    IF status = Async.pending THEN
      service.operation := saving; service.candidate := candidate; candidate := NIL
    ELSE S.Close(candidate)
    END;
    RETURN FileStatus(status)
  END;
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
  IF Busy(service) THEN RETURN busy END;
  IF service.known THEN RETURN conflict END;
  IF service.asynchronous & ~Async.Ready(service.context) THEN RETURN unavailable END;
  candidate := S.New(service.owner, nodes, posts, bytes); IF candidate = NIL THEN RETURN invalid END;
  RETURN Commit(service, candidate)
END Initialize;

PROCEDURE AddNode*(service: Service; name, title: ARRAY OF CHAR; policy: A.Node): LONGINT;
VAR candidate: S.Store; status: LONGINT;
BEGIN
  status := MutationStatus(service); IF status # okay THEN RETURN status END;
  candidate := S.CopyOwner(service.store); status := S.AddNodeOwner(candidate, name, title, policy);
  IF status # okay THEN S.Close(candidate); RETURN status END;
  RETURN Commit(service, candidate)
END AddNode;

PROCEDURE Policy*(service: Service; name: ARRAY OF CHAR; policy: A.Node): LONGINT;
VAR candidate: S.Store; status: LONGINT;
BEGIN
  status := MutationStatus(service); IF status # okay THEN RETURN status END;
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
  status := MutationStatus(service); IF status # okay THEN RETURN status END;
  IF ~P.Describe(post, header) THEN RETURN invalid END;
  IF (header.owner # service.owner) OR (header.author # service.author) THEN RETURN denied END;
  IF (header.replyTo[0] # 0X) & ~S.ReferenceOwner(service.store, header.replyTo, parent) THEN RETURN denied END;
  status := Wire(post); IF status # okay THEN RETURN status END;
  candidate := S.CopyOwner(service.store); status := S.PutOwner(candidate, node, post);
  IF status # okay THEN S.Close(candidate); RETURN status END;
  RETURN Commit(service, candidate)
END Put;

PROCEDURE Hex(ch: CHAR): LONGINT;
BEGIN
  IF (ch >= "0") & (ch <= "9") THEN RETURN ORD(ch)-ORD("0") END;
  IF (ch >= "a") & (ch <= "f") THEN RETURN ORD(ch)-ORD("a")+10 END;
  RETURN -1
END Hex;

PROCEDURE Publish*(service: Service; node, token, title, text, parent, stamp: ARRAY OF CHAR): LONGINT;
VAR header, previous: P.Header; entropy: ARRAY 16 OF CHAR;
  content: ARRAY P.maxTextBytes+1 OF CHAR; post: P.Post; i, high, low, status: LONGINT;
BEGIN
  status := MutationStatus(service); IF status # okay THEN RETURN status END;
  IF (LEN(token) < 33) OR (token[32] # 0X) OR ~P.Text(title, P.maxTitleBytes, TRUE) OR
      ~P.Text(text, P.maxTextBytes, FALSE) OR ~P.Reference(parent, TRUE) OR ~P.Timestamp(stamp) THEN RETURN invalid END;
  FOR i := 0 TO 15 DO
    high := Hex(token[2*i]); low := Hex(token[2*i+1]);
    IF (high < 0) OR (low < 0) THEN RETURN invalid END;
    entropy[i] := CHR(high*16+low)
  END;
  IF ~P.Identifiers(entropy, header.itemID, header.id) OR (header.itemID # token) THEN RETURN invalid END;
  post := S.GetOwner(service.store, node, header.itemID);
  IF P.Describe(post, previous) THEN
    IF (previous.id # header.id) OR (previous.title # title) OR (previous.replyTo # parent) OR
        ~P.Content(post, content) OR (content # text) THEN RETURN conflict END;
    RETURN okay
  END;
  COPY(service.owner, header.owner); COPY(service.author, header.author); COPY(title, header.title);
  COPY(parent, header.replyTo); COPY(stamp, header.published); COPY(stamp, header.updated);
  post := P.New(header, text); RETURN Put(service, node, post)
END Publish;

PROCEDURE Edit*(service: Service; node: ARRAY OF CHAR; expected, replacement: P.Post): LONGINT;
VAR candidate: S.Store; status: LONGINT;
BEGIN
  status := MutationStatus(service); IF status # okay THEN RETURN status END;
  status := Wire(replacement); IF status # okay THEN RETURN status END;
  candidate := S.CopyOwner(service.store); status := S.EditOwner(candidate, node, expected, replacement);
  IF status # okay THEN S.Close(candidate); RETURN status END;
  RETURN Commit(service, candidate)
END Edit;

PROCEDURE Retract*(service: Service; node, itemID: ARRAY OF CHAR): LONGINT;
VAR candidate: S.Store; status: LONGINT;
BEGIN
  status := MutationStatus(service); IF status # okay THEN RETURN status END;
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

PROCEDURE Stop*;
BEGIN Async.Stop END Stop;

PROCEDURE Idle*(): BOOLEAN;
BEGIN RETURN Async.Idle() END Idle;

END BarevPublishing.
