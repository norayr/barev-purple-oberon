MODULE TestPostAsync;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT F := BarevPostAsync, IO := BarevPostIOHost, Sync := BarevPostFiles,
  S := BarevPostStore, P := BarevPost, A := BarevFeedAccess, I := XmppItems,
  Private := BarevIdentityFiles, Args, Out, Heap, Platform, IntStr, Strings := oocStrings;

CONST owner = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
VAR checks, failed, i, lock, status: LONGINT;
  profile, validProfile: ARRAY 4096 OF CHAR; action: ARRAY 32 OF CHAR;
  context, second, savedContext: F.Context;
  request, other, alias: F.Request;
  store, competitor, disk, savedStore: S.Store;
  sync: Sync.Context; public, selected: A.Node; names: ARRAY 1 OF A.Name;
  header: P.Header; post: P.Post; text: ARRAY 64 OF CHAR;
  bytes: I.Bytes; short: ARRAY 1 OF CHAR;

PROCEDURE Check(value: BOOLEAN; message: ARRAY OF CHAR);
BEGIN INC(checks); IF ~value THEN INC(failed); Out.String(message); Out.Ln END END Check;

PROCEDURE Loaded(VAR request: F.Request; VAR context: F.Context; VAR store: S.Store): LONGINT;
VAR status, attempts: LONGINT;
BEGIN
  attempts := 0; status := F.Loaded(request, context, store);
  WHILE (status = F.pending) & (attempts < 5000) DO
    Platform.Delay(1); INC(attempts); status := F.Loaded(request, context, store)
  END;
  RETURN status
END Loaded;

PROCEDURE Saved(VAR request: F.Request): LONGINT;
VAR status, attempts: LONGINT;
BEGIN
  attempts := 0; status := F.Saved(request);
  WHILE (status = F.pending) & (attempts < 5000) DO
    Platform.Delay(1); INC(attempts); status := F.Saved(request)
  END;
  RETURN status
END Saved;

PROCEDURE Drained(): BOOLEAN;
VAR attempts: LONGINT;
BEGIN
  attempts := 0;
  WHILE ~F.Idle() & (attempts < 5000) DO Platform.Delay(1); INC(attempts) END;
  RETURN F.Idle()
END Drained;

PROCEDURE Post(number: LONGINT; body: ARRAY OF CHAR): P.Post;
VAR digits: ARRAY 16 OF CHAR;
BEGIN
  header.owner := owner; header.author := "Ani@200::1"; header.title := "Բարեւ 😀";
  IntStr.IntToStr(number, digits); header.itemID := "post-"; Strings.Append(digits, header.itemID);
  header.id := "urn:post:"; Strings.Append(digits, header.id); header.replyTo := "";
  header.published := "2026-11-20T00:00:00Z"; header.updated := header.published;
  RETURN P.New(header, body)
END Post;

PROCEDURE Read(profile: ARRAY OF CHAR; VAR context: F.Context; VAR store: S.Store): LONGINT;
VAR request: F.Request; status: LONGINT;
BEGIN
  status := F.Load(profile, owner, request);
  IF status # F.pending THEN RETURN status END;
  RETURN Loaded(request, context, store)
END Read;

PROCEDURE Inspect;
BEGIN
  Check(F.Ready(context), "validated asynchronous context is ready");
  Check((S.CountOwner(store) = 4) & (S.ReservedOwner(store) = 5), "restoring complete asynchronous history");
  post := S.GetOwner(store, "public", "post-1");
  Check(P.Content(post, text) & (text = "First"), "retaining first immutable post");
  Check(S.GetOwner(store, "selected", "post-2") = NIL, "retaining asynchronous tombstone");
  Check(S.GetOwner(store, "public", "post-4") = NIL, "refusing stale-writer candidate");
  Check(S.GetOwner(store, "public", "post-6") # NIL, "accepted write outlives retired context");
  post := Post(2, "Resurrection");
  Check(S.PutOwner(store, "selected", post) = S.conflict, "retained identity cannot be reused after restart")
END Inspect;

PROCEDURE Operations;
BEGIN
  Check(F.Load(profile, owner, request) = F.pending, "starting background load"); alias := request;
  Check(F.Load(profile, owner, request) = F.busy, "refusing active request overwrite");
  Check(F.Saved(request) = F.invalid, "wrong completion operation leaves load request active");
  Check((Loaded(request, context, store) = F.missing) & (store = NIL), "missing load returns context without empty store");
  Check((request = NIL) & F.Ready(context), "consuming completed load request");
  Check(F.Loaded(alias, second, disk) = F.invalid, "retired request alias cannot be completed twice");
  F.Cancel(alias);
  store := S.New(owner, 4, 8, 131072);
  Check(S.AddNodeOwner(store, "public", "Public", public) = S.okay, "adding asynchronous public node");
  Check(S.AddNodeOwner(store, "selected", "Selected", selected) = S.okay, "adding asynchronous private node");
  post := Post(1, "First"); Check(S.PutOwner(store, "public", post) = S.okay, "adding first snapshot post");
  Check(F.Save(context, store, request) = F.pending, "starting background initial checkpoint"); alias := request;
  Check(~F.Ready(context), "one outstanding operation owns context");
  Check(F.Save(context, store, other) = F.busy, "serializing saves per context");
  Check(F.Loaded(request, second, disk) = F.invalid, "wrong completion operation leaves save active");
  post := Post(2, "Private"); Check(S.PutOwner(store, "selected", post) = S.okay, "mutating application store after submission");
  Heap.GC(FALSE);
  Check(Saved(request) = F.okay, "completing private prepared image after collection");
  Check(F.Saved(alias) = F.invalid, "retired save alias cannot advance context twice"); F.Cancel(alias);
  Check(Sync.Load(profile, owner, sync, disk) = Sync.okay, "reading async output through synchronous adapter");
  Check((S.CountOwner(disk) = 1) & (S.ReservedOwner(disk) = 1), "worker persisted prepared bytes rather than mutable application store");
  Sync.Close(sync); S.Close(disk);
  Check(S.RetractOwner(store, "selected", "post-2") = S.okay, "retaining private tombstone in next image");
  Check(F.Save(context, store, request) = F.pending, "saving subsequent complete state");
  Check(Saved(request) = F.okay, "advancing checkpoint baseline after success");
  Check(Read(profile, second, competitor) = F.okay, "opening independent checkpoint context");
  post := Post(3, "Winner"); Check(S.PutOwner(store, "public", post) = S.okay, "appending winning revision");
  Check(F.Save(context, store, request) = F.pending, "submitting winning writer"); Check(Saved(request) = F.okay, "committing winning writer");
  post := Post(4, "Loser"); Check(S.PutOwner(competitor, "public", post) = S.okay, "preparing stale-writer candidate");
  Check(F.Save(second, competitor, request) = F.pending, "submitting stale writer");
  Check(Saved(request) = F.changed, "exact baseline bytes reject stale writer");
  Check(~F.Ready(second) & (F.Save(second, competitor, request) = F.changed), "failed save blocks context until reload");
  F.Close(second); S.Close(competitor);
  competitor := S.New(owner, 4, 8, 131072);
  Check(F.Save(context, competitor, request) = F.changed, "validating lineage before worker submission");
  Check(F.Ready(context) & (request = NIL), "lineage validation failure preserves context and request"); S.Close(competitor);

  lock := Private.Open(profile); Check(lock >= 0, "holding private-profile lock");
  Check(F.Save(context, store, request) = F.pending, "submitting contended checkpoint");
  status := Saved(request); Private.Close(lock);
  Check(status = F.storageError, "reporting background lock contention");
  Check(~F.Ready(context), "storage failure blocks further writes");
  F.Close(context); S.Close(store);
  Check(Read(profile, context, store) = F.okay, "reloading validated history after failed save");

  post := Post(5, "Canceled completion"); Check(S.PutOwner(store, "public", post) = S.okay, "preparing abandoned write");
  Check(F.Save(context, store, request) = F.pending, "submitting write before cancellation"); alias := request;
  F.Cancel(request);
  Check((request = NIL) & ~F.Ready(context), "canceling result blocks potentially changed context");
  Check(F.Saved(alias) = F.invalid, "canceled alias cannot report success"); F.Cancel(alias);
  Check(Drained(), "abandoned worker keeps module alive until completion");
  F.Close(context); S.Close(store);
  Check(Read(profile, context, store) = F.okay, "recovering abandoned accepted write");
  Check(S.GetOwner(store, "public", "post-5") # NIL, "cancellation does not assume disk rollback");
  post := Post(6, "Closed context"); Check(S.PutOwner(store, "public", post) = S.okay, "preparing retirement scenario");
  Check(F.Save(context, store, request) = F.pending, "submitting before context close");
  savedContext := context; F.Close(context); S.Close(store);
  Check(F.Saved(request) = F.invalid, "closed context cannot advance from late completion");
  Check(~F.Ready(savedContext), "closed context aliases stay retired"); F.Close(savedContext);
  Check(Drained(), "draining late write without Oberon objects on worker");
  Check(Read(profile, context, store) = F.okay, "reloading late accepted write"); Inspect;

  savedContext := context; savedStore := store;
  Check(F.Load(profile, owner, request) = F.pending, "starting shutdown load");
  F.Stop;
  Check(Loaded(request, context, store) = F.invalid, "shutdown invalidates pending result handles");
  Check((context = savedContext) & (store = savedStore), "failed completion preserves output context and store");
  Check(Drained() & F.Start(), "restarting only after worker has drained");
  Check(F.Load("/", owner, request) = F.invalid, "validating absolute profile before submission");
  Check(F.Load(profile, "bad", request) = F.invalid, "validating owner before submission");
  Check(IO.Read(profile, "bad") = 0, "binding checks short owner arrays");
  short[0] := "x"; Check(IO.Read(short, owner) = 0, "binding checks unterminated profile arrays");
  NEW(bytes, 1);
  Check(IO.Replace(profile, owner, bytes, 2, bytes, 1) = 0, "binding bounds expected-image array");
  Check(IO.Replace(profile, owner, NIL, -1, bytes, 2) = 0, "binding bounds replacement-image array");
  Check(F.Save(NIL, store, request) = F.invalid, "rejecting absent checkpoint context");
  F.Close(context); S.Close(store)
END Operations;

BEGIN
  Args.Get(1, profile); Args.Get(2, action); Args.Get(3, validProfile);
  names[0] := "reader@200::2";
  public := A.NewNode(A.open, names, 0); selected := A.NewNode(A.whitelist, names, 1);
  Check(F.Start(), "starting opaque-byte worker binding");
  Check(IO.maxBytes = S.maxSnapshotBytes, "matching worker and snapshot image bounds");
  IF action = "verify" THEN
    Check(Read(profile, context, store) = F.okay, "reopening checkpoint in fresh process"); Inspect;
    F.Close(context); S.Close(store)
  ELSIF action = "invalid" THEN
    Check(Read(validProfile, context, store) = F.okay, "opening valid output-preservation fixture");
    savedContext := context; savedStore := store;
    Check(Read(profile, context, store) = F.invalid, "validating opaque loaded bytes on owner thread");
    Check((context = savedContext) & (store = savedStore) & F.Ready(context), "corrupt load leaves prior outputs unchanged");
    F.Close(context); S.Close(store)
  ELSE Operations
  END;
  F.Stop; Check(Drained(), "draining before runtime shutdown");
  Out.String("TestPostAsync: "); Out.Int(checks, 0); Out.String(" checks, "); Out.Int(failed, 0); Out.String(" failed"); Out.Ln;
  IF failed # 0 THEN HALT(100) END
END TestPostAsync.
