MODULE BarevPostAsync;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT IO := BarevPostIOHost, S := BarevPostStore, P := BarevPost, I := XmppItems;

CONST okay* = IO.okay; missing* = IO.missing; invalid* = IO.invalid;
  storageError* = IO.storageError; changed* = IO.changed; pending* = IO.pending; busy* = 6;
  loading = 1; saving = 2;

TYPE
  Context* = POINTER TO ContextDesc;
  ContextDesc* = RECORD
    profile: ARRAY 3801 OF CHAR; owner: ARRAY 65 OF CHAR;
    image: I.Bytes; length: LONGINT; baseline: S.Store; active, busy, blocked: BOOLEAN
  END;
  Request* = POINTER TO RequestDesc;
  RequestDesc* = RECORD
    context: Context; job, kind, length: LONGINT; image: I.Bytes; baseline: S.Store; active: BOOLEAN
  END;

PROCEDURE Start*(): BOOLEAN;
BEGIN RETURN IO.Start() END Start;

PROCEDURE Ready*(context: Context): BOOLEAN;
BEGIN RETURN (context # NIL) & context.active & ~context.busy & ~context.blocked END Ready;

PROCEDURE Close*(VAR context: Context);
BEGIN
  IF context = NIL THEN RETURN END;
  context.active := FALSE; S.Close(context.baseline); context.image := NIL; context := NIL
END Close;

PROCEDURE Retire(VAR request: Request);
BEGIN
  IO.Release(request.job); request.active := FALSE;
  S.Close(request.baseline); request.image := NIL;
  request.context.busy := FALSE; request.context := NIL; request := NIL
END Retire;

PROCEDURE Cancel*(VAR request: Request);
VAR context: Context;
BEGIN
  IF request = NIL THEN RETURN END;
  IF ~request.active THEN request := NIL; RETURN END;
  context := request.context;
  IF request.kind = loading THEN Close(context)
  ELSE request.context.blocked := TRUE
  END;
  Retire(request)
END Cancel;

PROCEDURE Load*(profile, owner: ARRAY OF CHAR; VAR request: Request): LONGINT;
VAR context: Context; next: Request; n, job: LONGINT;
BEGIN
  IF (request # NIL) & request.active THEN RETURN busy END;
  IF ~P.Owner(owner) THEN RETURN invalid END;
  n := 0; WHILE (n < LEN(profile)) & (n <= 3800) & (profile[n] # 0X) DO INC(n) END;
  IF (n = LEN(profile)) OR (n < 2) OR (n > 3800) OR (profile[0] # "/") THEN RETURN invalid END;
  WHILE (n > 1) & (profile[n-1] = "/") DO DEC(n) END;
  IF n < 2 THEN RETURN invalid END;
  job := IO.Read(profile, owner); IF job = 0 THEN RETURN busy END;
  NEW(context); COPY(profile, context.profile); COPY(owner, context.owner); context.active := TRUE;
  NEW(next); next.context := context; next.job := job; next.kind := loading; next.active := TRUE;
  request := next; RETURN pending
END Load;

PROCEDURE Loaded*(VAR request: Request; VAR context: Context; VAR store: S.Store): LONGINT;
VAR status, length: LONGINT; bytes: I.Bytes; baseline, loaded: S.Store; next: Context;
BEGIN
  IF (request = NIL) OR ~request.active OR (request.kind # loading) THEN RETURN invalid END;
  status := IO.Status(request.job); IF status = pending THEN RETURN pending END;
  baseline := NIL; loaded := NIL;
  next := request.context;
  IF status = okay THEN
    length := IO.Length(request.job);
    IF (length < 4) OR (length > S.maxSnapshotBytes) THEN status := invalid
    ELSE
      NEW(bytes, length);
      IF IO.Copy(request.job, bytes^) # length THEN status := storageError
      ELSE
        baseline := S.DecodeOwner(bytes, length, next.owner);
        loaded := S.DecodeOwner(bytes, length, next.owner);
        IF (baseline = NIL) OR (loaded = NIL) THEN status := invalid
        ELSE next.image := bytes; next.length := length; next.baseline := baseline
        END
      END
    END
  END;
  IF (status = okay) OR (status = missing) THEN context := next; store := loaded; Retire(request)
  ELSE
    S.Close(baseline); S.Close(loaded); Cancel(request)
  END;
  RETURN status
END Loaded;

PROCEDURE Save*(context: Context; store: S.Store; VAR request: Request): LONGINT;
VAR bytes: I.Bytes; baseline: S.Store; length, expected, job: LONGINT; next: Request;
BEGIN
  IF (request # NIL) & request.active THEN RETURN busy END;
  IF (context = NIL) OR ~context.active OR ~S.OwnedBy(store, context.owner) THEN RETURN invalid END;
  IF context.blocked THEN RETURN changed END;
  IF context.busy THEN RETURN busy END;
  IF (context.baseline # NIL) & ~S.ExtendsOwner(context.baseline, store) THEN RETURN changed END;
  IF ~S.EncodeOwner(store, bytes, length) THEN RETURN invalid END;
  baseline := S.DecodeOwner(bytes, length, context.owner); IF baseline = NIL THEN RETURN invalid END;
  expected := context.length; IF context.image = NIL THEN expected := -1 END;
  job := IO.Replace(context.profile, context.owner, context.image, expected, bytes, length);
  IF job = 0 THEN S.Close(baseline); RETURN busy END;
  NEW(next); next.context := context; next.job := job; next.kind := saving;
  next.image := bytes; next.length := length; next.baseline := baseline; next.active := TRUE;
  context.busy := TRUE; request := next; RETURN pending
END Save;

PROCEDURE Saved*(VAR request: Request): LONGINT;
VAR status: LONGINT; context: Context;
BEGIN
  IF (request = NIL) OR ~request.active OR (request.kind # saving) THEN RETURN invalid END;
  context := request.context;
  IF ~context.active THEN Cancel(request); RETURN invalid END;
  status := IO.Status(request.job); IF status = pending THEN RETURN pending END;
  IF status = okay THEN
    S.Close(context.baseline); context.baseline := request.baseline; request.baseline := NIL;
    context.image := request.image; context.length := request.length
  ELSE context.blocked := TRUE
  END;
  Retire(request); RETURN status
END Saved;

PROCEDURE Stop*;
BEGIN IO.Stop END Stop;

PROCEDURE Idle*(): BOOLEAN;
BEGIN RETURN IO.Idle() END Idle;

END BarevPostAsync.
