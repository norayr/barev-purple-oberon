MODULE TestPublishAsync;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT Pub := BarevPublishing, S := BarevPostStore, P := BarevPost, A := BarevFeedAccess,
  Private := BarevIdentityFiles, Args, Out, Heap, Platform, IntStr, Strings := oocStrings;

CONST owner = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
VAR checks, failed, i, lock, result: LONGINT;
  profile, path: ARRAY 4096 OF CHAR; action: ARRAY 32 OF CHAR;
  service, second, saved: Pub.Service; cursor: Pub.Cursor; page, captured: S.Page;
  info: S.NodeInfo; header: P.Header; post, original, revision: P.Post;
  names: ARRAY 1 OF A.Name; public, selected: A.Node;
  text: ARRAY P.maxTextBytes+1 OF CHAR;

PROCEDURE Check(value: BOOLEAN; message: ARRAY OF CHAR);
BEGIN INC(checks); IF ~value THEN INC(failed); Out.String(message); Out.Ln END END Check;

PROCEDURE Finish(service: Pub.Service): LONGINT;
VAR status, attempts: LONGINT;
BEGIN
  attempts := 0; status := Pub.Poll(service);
  WHILE (status = Pub.pending) & (attempts < 5000) DO
    Platform.Delay(1); INC(attempts); status := Pub.Poll(service)
  END;
  RETURN status
END Finish;

PROCEDURE Drain(): BOOLEAN;
VAR attempts: LONGINT;
BEGIN
  attempts := 0;
  WHILE ~Pub.Idle() & (attempts < 5000) DO Platform.Delay(1); INC(attempts) END;
  RETURN Pub.Idle()
END Drain;

PROCEDURE Make(number: LONGINT; body, parent: ARRAY OF CHAR): P.Post;
VAR digits: ARRAY 16 OF CHAR;
BEGIN
  header.owner := owner; header.author := "Ani@200::1"; header.title := "Բարեւ 😀";
  IntStr.IntToStr(number, digits); header.itemID := "post-"; Strings.Append(digits, header.itemID);
  header.id := "urn:post:"; Strings.Append(digits, header.id); COPY(parent, header.replyTo);
  header.published := "2026-11-20T00:00:00Z"; header.updated := header.published;
  RETURN P.New(header, body)
END Make;

PROCEDURE Inspect;
BEGIN
  Check(Pub.Ready(service) & ~Pub.Busy(service), "completed account is ready without pending work");
  Check(Pub.Node(service, 0, info) & (info.name = "public"), "retaining committed destination");
  post := Pub.Get(service, "public", "post-1");
  Check(P.Content(post, text) & (text = "Edited"), "retaining committed revision");
  Check(Pub.Get(service, "selected", "post-2") = NIL, "retaining committed tombstone");
  post := Pub.Get(service, "selected", "post-3");
  Check(P.Describe(post, header) & (header.replyTo = "urn:post:2"), "retaining independent private reply");
  Check(Pub.Get(service, "public", "post-4") # NIL, "retrying failed save retained its identity");
  Check(Pub.Get(service, "public", "post-5") # NIL, "retaining competing writer's successful state");
  Check(Pub.Get(service, "public", "post-6") # NIL, "recovering an accepted write after close");
  Check(Pub.Begin(service, "public", cursor) = Pub.okay, "starting restored account page");
  Check((Pub.Read(service, cursor, S.maxPage, page) = Pub.okay) & (S.PageSize(page) = 4), "restored page contains only committed public posts")
END Inspect;

PROCEDURE Operations;
BEGIN
  Check(Pub.OpenAsync(profile, owner, "Ani@0200:0:0:0:0:0:0:1", service) = Pub.pending, "submitting canonical account open");
  Check(Pub.Busy(service) & ~Pub.Ready(service), "pending open exposes no empty history");
  Check(Pub.Initialize(service, 4, 16, 131072) = Pub.busy, "serializing initialization behind open");
  Check(Finish(service) = Pub.missing, "completing first missing checkpoint");
  Check(Pub.Initialize(service, 4, 16, 131072) = Pub.pending, "submitting explicit initialization");
  Check(Pub.Reload(service) = Pub.busy, "reload cannot overtake pending initialization");
  Check(Finish(service) = Pub.okay, "committing explicit initialization");
  Check(Pub.Initialize(service, 4, 16, 131072) = Pub.conflict, "initialization cannot reset history");
  Check(Pub.AddNode(service, "public", "Public", public) = Pub.pending, "submitting public destination");
  info.name := "unchanged";
  Check(~Pub.Node(service, 0, info) & (info.name = "unchanged"), "uncommitted destination remains hidden");
  Check(Pub.AddNode(service, "selected", "Selected", selected) = Pub.busy, "preventing a second candidate from overtaking save");
  Check(Finish(service) = Pub.okay, "committing public destination");
  Check(Pub.AddNode(service, "selected", "Selected", selected) = Pub.pending, "submitting private destination");
  Check(Finish(service) = Pub.okay, "committing private destination");
  original := Make(1, "First", "");
  Check(Pub.Begin(service, "public", cursor) = Pub.okay, "capturing empty committed page");
  Check(Pub.Put(service, "public", original) = Pub.pending, "submitting immutable publication");
  Heap.GC(FALSE);
  Check(Pub.Ready(service) & Pub.Busy(service) & (Pub.Get(service, "public", "post-1") = NIL), "prepared publication remains hidden while old state is readable");
  Check((Pub.Read(service, cursor, 1, page) = Pub.okay) & (S.PageSize(page) = 0), "pending write preserves committed cursor");
  Check(Finish(service) = Pub.okay, "exposing publication after successful completion");
  Check((Pub.Read(service, cursor, 1, page) = Pub.invalid) & (page = NIL), "successful completion invalidates old cursor");
  Check(Pub.Get(service, "public", "post-1") = original, "committed candidate retains immutable record");
  Check(Pub.Poll(service) = Pub.invalid, "completion is consumed exactly once");
  post := Make(2, "Private", "");
  Check(Pub.Put(service, "selected", post) = Pub.pending, "submitting private publication"); Check(Finish(service) = Pub.okay, "committing private publication");
  post := Make(3, "Reply", "urn:post:2");
  Check(Pub.Put(service, "public", post) = Pub.denied, "reply cannot widen private audience");
  Check(Pub.Put(service, "selected", post) = Pub.pending, "submitting same-node reply"); Check(Finish(service) = Pub.okay, "committing independent reply");
  FOR i := 0 TO P.maxTextBytes-1 DO text[i] := "&" END; text[P.maxTextBytes] := 0X;
  post := Make(4, text, "");
  Check(Pub.Put(service, "public", post) = Pub.wireFull, "wire validation precedes background submission");
  Check(Pub.Ready(service) & ~Pub.Busy(service), "validation failure creates no pending operation");
  Check(P.Describe(original, header), "copying revision header"); header.updated := "2026-11-20T00:00:01Z";
  revision := P.New(header, text);
  Check(Pub.Edit(service, "public", original, revision) = Pub.wireFull, "bounding edited Atom payload before saving");
  revision := P.New(header, "Edited");
  Check(Pub.Edit(service, "public", original, revision) = Pub.pending, "submitting optimistic edit");
  Check(Pub.Get(service, "public", "post-1") = original, "pending edit preserves visible original");
  Check(Finish(service) = Pub.okay, "committing optimistic edit");
  Check(Pub.Begin(service, "public", cursor) = Pub.okay, "capturing committed revision");
  Check(Pub.Read(service, cursor, 1, captured) = Pub.okay, "retaining immutable delivered page");
  lock := Private.Open(profile); Check(lock >= 0, "holding private-profile lock for failure");
  post := Make(4, "Retry", "");
  Check(Pub.Put(service, "public", post) = Pub.pending, "submitting contended write");
  result := Finish(service); Private.Close(lock);
  Check((result = Pub.storageError) & ~Pub.Ready(service), "failed persistence blocks account reads");
  Check(Pub.Get(service, "public", "post-4") = NIL, "failed candidate is never exposed");
  Check(Pub.Reload(service) = Pub.pending, "submitting recovery reload");
  Check(Finish(service) = Pub.okay, "recovering durable state");
  Check(Pub.Get(service, "public", "post-4") = NIL, "recovery contains no failed candidate");
  Heap.GC(FALSE); Check(P.Content(S.PagePost(captured, 0), text) & (text = "Edited"), "delivered snapshot survives recovery");
  Check(Pub.Put(service, "public", post) = Pub.pending, "retrying same identity after recovery"); Check(Finish(service) = Pub.okay, "committing recovered retry");
  Check(Pub.OpenAsync(profile, owner, "Ani@200::1", second) = Pub.pending, "submitting independent writer open");
  Check(Finish(second) = Pub.okay, "opening independent writer");
  post := Make(5, "Winner", "");
  Check(Pub.Put(second, "public", post) = Pub.pending, "submitting competing winner"); Check(Finish(second) = Pub.okay, "committing competing winner");
  post := Make(6, "Stale candidate", "");
  Check(Pub.Put(service, "public", post) = Pub.pending, "submitting stale account snapshot");
  Check(Finish(service) = Pub.changed, "rejecting stale account writer");
  Check(~Pub.Ready(service) & (Pub.Get(service, "public", "post-6") = NIL), "stale candidate stays hidden");
  Check(Pub.Reload(service) = Pub.pending, "submitting winner reload"); Check(Finish(service) = Pub.okay, "recovering competing winner");
  Pub.Close(second);
  Check(Pub.Retract(service, "selected", "post-2") = Pub.pending, "submitting private retraction");
  Check(Pub.Get(service, "selected", "post-2") # NIL, "pending retraction preserves committed view");
  Check(Finish(service) = Pub.okay, "committing retraction");
  Check(Pub.Get(service, "selected", "post-2") = NIL, "completed retraction hides content");
  Check(Pub.Policy(service, "selected", public) = Pub.invalid, "asynchronous policy cannot change access model");
  post := Make(6, "Accepted before close", "");
  Check(Pub.Put(service, "public", post) = Pub.pending, "submitting before account close");
  saved := service; Pub.Close(service);
  Check((Pub.Poll(saved) = Pub.invalid) & ~Pub.Ready(saved), "late completion cannot revive closed account");
  Pub.Close(saved); Check(Drain(), "draining accepted write before reopening");
  Check(Pub.OpenAsync(profile, owner, "Ani@200::1", service) = Pub.pending, "submitting post-close recovery");
  Check(Finish(service) = Pub.okay, "recovering accepted write after account close"); Inspect;
  Pub.Close(service)
END Operations;

PROCEDURE Tokens;
CONST token = "00000000000040008000000000000001";
VAR directory: ARRAY 4096 OF CHAR;
BEGIN
  COPY(profile, directory); Strings.Append("-tokens", directory);
  Check(Pub.OpenAsync(directory, owner, "Ani@200::1", service) = Pub.pending, "opening token fixture");
  Check(Finish(service) = Pub.missing, "opening first token checkpoint");
  Check(Pub.Initialize(service, 4, 16, 131072) = Pub.pending, "initializing token fixture");
  Check(Finish(service) = Pub.okay, "committing token initialization");
  Check(Pub.AddNode(service, "public", "Public", public) = Pub.pending, "creating token destination");
  Check(Finish(service) = Pub.okay, "committing token destination");
  Check(Pub.Publish(service, "public", token, "Title", "Body", "", "2026-11-20T00:00:00Z") = Pub.pending, "submitting canonical publication token");
  Check(Pub.Publish(service, "public", token, "Title", "Body", "", "2026-11-20T00:00:01Z") = Pub.busy, "retry cannot overtake pending token");
  Check(Finish(service) = Pub.okay, "committing token publication");
  Check(Pub.AddNode(service, "selected", "Selected", selected) = Pub.pending, "creating alternate token audience");
  Check(Finish(service) = Pub.okay, "committing alternate token audience");
  Check(Pub.Publish(service, "selected", token, "Title", "Body", "", "2026-11-20T00:00:02Z") = Pub.conflict, "token cannot move a publication to another audience");
  original := Pub.Get(service, "public", token);
  Check(P.Describe(original, header) & (header.id = "urn:uuid:00000000-0000-4000-8000-000000000001"), "binding token to UUID Atom identity");
  Check(Pub.Publish(service, "public", token, "Title", "Body", "", "2026-11-20T00:00:02Z") = Pub.okay, "retry returns existing committed identity");
  Check(~Pub.Busy(service) & (Pub.Get(service, "public", token) = original), "idempotent retry preserves revision and timestamp");
  Check(Pub.Publish(service, "public", token, "Other", "Body", "", "2026-11-20T00:00:02Z") = Pub.conflict, "token cannot change title");
  Check(Pub.Publish(service, "public", token, "Title", "Other", "", "2026-11-20T00:00:02Z") = Pub.conflict, "token cannot change content");
  Check(Pub.Publish(service, "public", token, "Title", "Body", "urn:parent:1", "2026-11-20T00:00:02Z") = Pub.conflict, "token cannot change reply relationship");
  Check(Pub.Publish(service, "public", "bad", "Title", "Body", "", "2026-11-20T00:00:02Z") = Pub.invalid, "checking token length");
  Check(Pub.Publish(service, "public", "00000000000000008000000000000001", "Title", "Body", "", "2026-11-20T00:00:02Z") = Pub.invalid, "requiring canonical UUID version bits");
  Check(Pub.Publish(service, "public", token, "Title", "Body", "", "bad") = Pub.invalid, "validating host-provided timestamp");
  Pub.Close(service);
  Check(Pub.OpenAsync(directory, owner, "Ani@200::9", service) = Pub.pending, "reopening token under current address");
  Check(Finish(service) = Pub.okay, "restoring token after reconnect");
  Check(Pub.Publish(service, "public", token, "Title", "Body", "", "2026-11-20T00:00:03Z") = Pub.okay, "retry after reconnect preserves original author");
  post := Pub.Get(service, "public", token);
  Check(P.Describe(post, header) & (header.author = "Ani@200::1") &
    (header.published = "2026-11-20T00:00:00Z"), "retaining durable original metadata across retry");
  Check(Pub.Retract(service, "public", token) = Pub.pending, "retracting token identity");
  Check(Finish(service) = Pub.okay, "committing token tombstone");
  Check(Pub.Publish(service, "public", token, "Title", "Body", "", "2026-11-20T00:00:04Z") = Pub.conflict, "retry cannot resurrect a retracted token");
  Pub.Close(service)
END Tokens;

BEGIN
  Args.Get(1, profile); Args.Get(2, action);
  names[0] := "reader@200::2"; public := A.NewNode(A.open, names, 0); selected := A.NewNode(A.whitelist, names, 1);
  Check(Pub.Start(), "starting asynchronous publishing runtime");
  IF action = "new" THEN Operations; Tokens
  ELSE
    Check(Pub.OpenAsync(profile, owner, "Ani@200::9", service) = Pub.pending, "submitting existing account open");
    result := Finish(service);
    IF action = "invalid" THEN
      Check((result = Pub.invalid) & ~Pub.Ready(service), "corrupt history opens no ready service");
      Check(Pub.Initialize(service, 4, 16, 131072) = Pub.unavailable, "failed open cannot silently initialize history")
    ELSE
      Check(result = Pub.okay, "restoring existing account"); Inspect;
      IF action = "lost" THEN
        COPY(profile, path); Strings.Append("/barev/posts-", path); Strings.Append(owner, path); Strings.Append(".state", path);
        Check(Platform.Unlink(path) = 0, "removing established checkpoint");
        Check(Pub.Reload(service) = Pub.pending, "submitting missing-history reload");
        Check((Finish(service) = Pub.missing) & ~Pub.Ready(service), "missing established history blocks account");
        Check(Pub.Initialize(service, 4, 16, 131072) = Pub.conflict, "known missing history cannot be reset")
      ELSE
        original := Pub.Get(service, "public", "post-1");
        Check(P.Describe(original, header), "capturing original author after reconnect");
        header.updated := "2026-11-20T00:00:02Z"; revision := P.New(header, "Edited");
        Check(Pub.Edit(service, "public", original, revision) = Pub.pending, "editing earlier author after address change");
        Check(Finish(service) = Pub.okay, "committing revision after address change")
      END
    END;
    Pub.Close(service)
  END;
  Pub.Stop; Check(Drain(), "draining background work before shutdown");
  Out.String("TestPublishAsync: "); Out.Int(checks, 0); Out.String(" checks, "); Out.Int(failed, 0); Out.String(" failed"); Out.Ln;
  IF failed # 0 THEN HALT(100) END
END TestPublishAsync.
