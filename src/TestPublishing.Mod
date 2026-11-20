MODULE TestPublishing;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT Pub := BarevPublishing, S := BarevPostStore, P := BarevPost, A := BarevFeedAccess,
  F := BarevPostFiles, Private := BarevIdentityFiles, Args, Out, Heap, Platform,
  IntStr, Strings := oocStrings;

CONST owner = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
VAR checks, failed, i, handle, status: LONGINT;
  profile, extra, path: ARRAY 4096 OF CHAR; action: ARRAY 32 OF CHAR;
  service, second, saved: Pub.Service; cursor: Pub.Cursor;
  page, captured: S.Page; info: S.NodeInfo;
  context: F.Context; disk: S.Store;
  post, original, replacement: P.Post; header: P.Header;
  names: ARRAY 1 OF A.Name; public, selected, nobody: A.Node;
  reader: A.Reader; contact: A.Contact; key: ARRAY 32 OF CHAR;
  text: ARRAY P.maxTextBytes+1 OF CHAR;

PROCEDURE Check(value: BOOLEAN; message: ARRAY OF CHAR);
BEGIN INC(checks); IF ~value THEN INC(failed); Out.String(message); Out.Ln END END Check;

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
  Check(Pub.Ready(service), "restored service is available");
  Check(Pub.Node(service, 0, info) & (info.name = "public") & (info.model = A.open), "retaining public destination");
  Check(Pub.Node(service, 1, info) & (info.name = "selected") & (info.model = A.whitelist), "retaining private destination");
  post := Pub.Get(service, "public", "post-1");
  Check(P.Content(post, text) & (text = "Edited"), "retaining successful revision");
  Check(Pub.Get(service, "selected", "post-2") = NIL, "retaining retraction");
  post := Pub.Get(service, "selected", "post-3");
  Check(P.Describe(post, header) & (header.replyTo = "urn:post:2"), "retaining independent private reply");
  Check(Pub.Begin(service, "public", cursor) = Pub.okay, "starting restored owner page");
  Check((Pub.Read(service, cursor, S.maxPage, page) = Pub.okay) & (S.PageSize(page) = 5), "paging only selected destination");
  Check(P.Describe(S.PagePost(page, 0), header) & (header.itemID = "post-8"), "preserving publication order");
  Check((Pub.Read(service, cursor, S.maxPage, page) = Pub.okay) & (S.PageSize(page) = 0), "finishing bounded page");
  Check(F.Load(profile, owner, context, disk) = F.okay, "independently reading committed checkpoint");
  Check((S.CountOwner(disk) = 7) & (S.ReservedOwner(disk) = 8), "durable live and reserved counts");
  F.Close(context); S.Close(disk)
END Inspect;

PROCEDURE Mutations;
BEGIN
  Check(Pub.Open(profile, owner, "Ani@0200:0:0:0:0:0:0:1", service) = Pub.missing, "opening uninitialized service explicitly");
  Check(~Pub.Ready(service), "missing checkpoint is not a ready empty history");
  Check(Pub.AddNode(service, "public", "Public", public) = Pub.unavailable, "uninitialized service refuses mutations");
  Check(Pub.Initialize(service, 0, 8, 131072) = Pub.invalid, "initialization validates quotas");
  Check(Pub.Initialize(service, 4, 8, 131072) = Pub.okay, "saving explicit empty initialization");
  Check(Pub.Initialize(service, 4, 8, 131072) = Pub.conflict, "initialization cannot erase existing history");
  Check(Pub.AddNode(service, "public", "Public", public) = Pub.okay, "durably creating public destination");
  Check(Pub.AddNode(service, "selected", "Selected", selected) = Pub.okay, "durably creating private destination");
  Check(Pub.AddNode(service, "public", "Duplicate", public) = Pub.conflict, "duplicate destination leaves committed state available");
  Check(Pub.Policy(service, "selected", public) = Pub.invalid, "refusing private access-model downgrade");
  saved := service;
  Check((Pub.Open(profile, owner, "bad", service) = Pub.invalid) & (service = saved), "failed open preserves service output");
  Check((Pub.Open(profile, "bad", "Ani@200::1", service) = Pub.invalid) & (service = saved), "failed owner validation preserves service");
  original := Make(1, "Original", "");
  Check(Pub.Put(service, "public", original) = Pub.okay, "saving first publication");
  Check(Pub.Put(service, "public", original) = Pub.okay, "retrying exact post without new identity");
  post := Make(2, "Private", "");
  Check(Pub.Put(service, "selected", post) = Pub.okay, "saving private publication");
  post := Make(3, "Private reply", "urn:post:2");
  Check(Pub.Put(service, "public", post) = Pub.denied, "reply reference cannot widen private audience");
  Check(Pub.Put(service, "selected", post) = Pub.okay, "saving independent same-node reply");
  post := Make(4, "Unknown reply", "urn:unknown");
  Check(Pub.Put(service, "public", post) = Pub.denied, "refusing unauthenticated external parent context");
  post := Make(4, "Foreign", ""); header.author := "Other@200::2"; post := P.New(header, "Foreign");
  Check(Pub.Put(service, "public", post) = Pub.denied, "new publication author must match local account");
  header.author := "Ani@200::1"; header.owner[0] := "0"; post := P.New(header, "Wrong owner");
  Check(Pub.Put(service, "public", post) = Pub.denied, "new publication must match persistent owner");
  FOR i := 0 TO P.maxTextBytes-1 DO text[i] := "&" END; text[P.maxTextBytes] := 0X;
  post := Make(4, text, "");
  Check(P.Valid(post) & (Pub.Put(service, "public", post) = Pub.wireFull), "checking XML expansion before persistence");
  Check(Pub.Get(service, "public", "post-4") = NIL, "oversized wire payload reserves no identity");
  Check(P.Describe(original, header), "copying immutable original header");
  header.updated := "2026-11-20T00:00:01Z"; replacement := P.New(header, text);
  Check(Pub.Edit(service, "public", original, replacement) = Pub.wireFull, "checking edit wire size before persistence");
  Check(Pub.Get(service, "public", "post-1") = original, "failed validation preserves original record");
  replacement := P.New(header, "Edited");
  Check(Pub.Edit(service, "public", original, replacement) = Pub.okay, "committing valid optimistic edit");
  header.updated := "2026-11-20T00:00:02Z"; post := P.New(header, "Conflicting");
  Check(Pub.Edit(service, "public", original, post) = Pub.conflict, "stale revision cannot overwrite committed edit");
  Check(Pub.Begin(service, "public", cursor) = Pub.okay, "capturing page before persistence failure");
  Check(Pub.Read(service, cursor, 1, captured) = Pub.okay, "retaining delivered immutable page");
  handle := Private.Open(profile); Check(handle >= 0, "locking checkpoint for failure scenario");
  post := Make(4, "After lock", "");
  Check(Pub.Put(service, "public", post) = Pub.storageError, "storage failure does not commit candidate");
  Private.Close(handle);
  Check(~Pub.Ready(service) & (Pub.Get(service, "public", "post-4") = NIL), "persistence failure requires reload before access");
  Check((Pub.Read(service, cursor, 1, page) = Pub.unavailable) & (page = NIL), "unavailable service emits no partial page");
  Check(Pub.Put(service, "public", post) = Pub.unavailable, "blocking further writes until reload");
  Check(Pub.Reload(service) = Pub.okay, "recovering committed checkpoint after storage failure");
  Check(Pub.Get(service, "public", "post-4") = NIL, "reload cannot expose unsaved candidate");
  Check((Pub.Read(service, cursor, 1, page) = Pub.invalid) & (page = NIL), "reload invalidates previous cursor");
  Heap.GC(FALSE);
  Check(P.Content(S.PagePost(captured, 0), text) & (text = "Edited"), "delivered page survives reload and collection");
  Check(Pub.Put(service, "public", post) = Pub.okay, "retrying unchanged identity after recovery");
  handle := Private.Open(profile); Check(handle >= 0, "locking checkpoint before membership update");
  Check(Pub.Policy(service, "selected", nobody) = Pub.storageError, "failed membership persistence blocks service");
  Private.Close(handle);
  info.name := "unchanged";
  Check(~Pub.Node(service, 0, info) & (info.name = "unchanged"), "blocked metadata read preserves output");
  Check(Pub.Reload(service) = Pub.okay, "recovering original membership policy");
  Check(F.Load(profile, owner, context, disk) = F.okay, "reading policy after failed save");
  Check(A.Authenticate(reader, names[0], key, TRUE, TRUE), "authenticating policy fixture reader");
  contact := A.NewContact(names[0], key, TRUE, names, 0);
  Check(S.Get(disk, "selected", "post-2", reader, contact) # NIL, "failed membership update preserves durable audience");
  F.Close(context); S.Close(disk);
  Check(Pub.Open(profile, owner, "Ani@200::1", second) = Pub.okay, "opening independent writer");
  Check(Pub.Begin(service, "public", cursor) = Pub.okay, "capturing account-scoped cursor");
  Check((Pub.Read(second, cursor, 1, page) = Pub.invalid) & (page = NIL), "cursor belongs to one service instance");
  post := Make(5, "Winner", "");
  Check(Pub.Put(second, "public", post) = Pub.okay, "committing competing writer");
  post := Make(6, "Loser", "");
  Check(Pub.Put(service, "public", post) = Pub.changed, "stale checkpoint refuses candidate");
  Check(~Pub.Ready(service), "conflicting writer requires reload");
  Check(Pub.Reload(service) = Pub.okay, "reloading winning writer");
  Check((Pub.Get(service, "public", "post-5") # NIL) & (Pub.Get(service, "public", "post-6") = NIL), "committed winner replaces no unrelated state");
  Pub.Close(second);
  Check(Pub.Retract(service, "selected", "post-2") = Pub.okay, "durably retracting private parent");
  Check(Pub.Retract(service, "selected", "post-2") = Pub.okay, "idempotent durable retraction");
  post := Make(2, "Resurrection", "");
  Check(Pub.Put(service, "selected", post) = Pub.conflict, "durable tombstone prevents identity reuse");
  post := Make(7, "Later reply", "urn:post:2");
  Check(Pub.Put(service, "public", post) = Pub.denied, "tombstone retains private reply context");
  Check(Pub.Put(service, "selected", post) = Pub.okay, "reply to removed same-node parent");
  Check(Pub.Policy(service, "selected", nobody) = Pub.okay, "persisting live whitelist membership change");
  post := Make(6, "Recovered identity", "");
  Check(Pub.Put(service, "public", post) = Pub.okay, "failed stale candidate consumed no durable slot");
  post := Make(8, "Last slot", "");
  Check(Pub.Put(service, "public", post) = Pub.okay, "filling configured reserved slots");
  post := Make(9, "Overflow", "");
  Check(Pub.Put(service, "public", post) = Pub.full, "quota failure leaves committed service available");
  Inspect;
  Pub.Close(service)
END Mutations;

PROCEDURE LostCheckpoint;
BEGIN
  COPY(profile, extra); Strings.Append("-lost", extra);
  Check(Pub.Open(extra, owner, "Ani@200::1", service) = Pub.missing, "opening loss scenario");
  Check(Pub.Initialize(service, 1, 1, 1024) = Pub.okay, "initializing loss scenario");
  COPY(extra, path); Strings.Append("/barev/posts-", path); Strings.Append(owner, path); Strings.Append(".state", path);
  Check(Platform.Unlink(path) = 0, "removing initialized checkpoint");
  Check((Pub.Reload(service) = Pub.missing) & ~Pub.Ready(service), "missing established history blocks reads");
  Check(Pub.Initialize(service, 1, 1, 1024) = Pub.conflict, "missing established history cannot be silently reinitialized");
  saved := service; Pub.Close(service);
  Check(~Pub.Ready(saved) & (Pub.Reload(saved) = Pub.invalid), "closing invalidates retained aliases");
  Check((Pub.Get(NIL, "public", "post-1") = NIL) & (Pub.Reload(NIL) = Pub.invalid), "nil service fails safely");
  Pub.Close(saved)
END LostCheckpoint;

BEGIN
  Args.Get(1, profile); Args.Get(2, action);
  names[0] := "reader@200::2";
  public := A.NewNode(A.open, names, 0); selected := A.NewNode(A.whitelist, names, 1);
  nobody := A.NewNode(A.whitelist, names, 0);
  IF action = "verify" THEN
    Check(Pub.Open(profile, owner, "Ani@200::9", service) = Pub.okay, "reopening with current account address");
    Inspect;
    post := Make(9, "Old author", "");
    Check(Pub.Put(service, "public", post) = Pub.denied, "new publications use current address after reconnect");
    original := Pub.Get(service, "public", "post-1");
    Check(P.Describe(original, header), "reading original author after address change");
    header.updated := "2026-11-20T00:00:03Z"; replacement := P.New(header, "Edited");
    Check(Pub.Edit(service, "public", original, replacement) = Pub.okay, "owner can edit earlier publication after address change");
    Check(Pub.Reload(service) = Pub.okay, "reloading revision after address change");
    post := Pub.Get(service, "public", "post-1");
    Check(P.Describe(post, header) & (header.author = "Ani@200::1") &
      (header.updated = "2026-11-20T00:00:03Z"), "revision preserves original author and durable identity");
    Pub.Close(service)
  ELSIF action = "invalid" THEN
    Check(Pub.Open(profile, owner, "Ani@200::1", service) = Pub.invalid, "refusing invalid persisted history");
    Check(service = NIL, "invalid open produces no partial service")
  ELSE Mutations; LostCheckpoint
  END;
  Out.String("TestPublishing: "); Out.Int(checks, 0); Out.String(" checks, "); Out.Int(failed, 0); Out.String(" failed"); Out.Ln;
  IF failed # 0 THEN HALT(100) END
END TestPublishing.
