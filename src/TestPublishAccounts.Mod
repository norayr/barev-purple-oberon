MODULE TestPublishAccounts;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT H := BarevPublishAccounts, Pub := BarevPublishing, P := BarevPost, S := BarevPostStore,
  A := BarevFeedAccess, Clock := BarevPostClock, Private := BarevIdentityFiles,
  Args, Platform, Out, Heap, Strings := oocStrings;

CONST identity = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
  token = "00000000000040008000000000000001";
  token2 = "00000000000040008000000000000002";
VAR checks, failed, handle, old, status, i, lock: LONGINT; changed: BOOLEAN;
  profile, path: ARRAY 4096 OF CHAR; action: ARRAY 32 OF CHAR;
  next, first, second: ARRAY 65 OF CHAR; stamp: ARRAY 21 OF CHAR; short: ARRAY 2 OF CHAR;
  names: ARRAY 1 OF A.Name; page, captured: S.Page; post: P.Post; header: P.Header;

PROCEDURE Check(value: BOOLEAN; message: ARRAY OF CHAR);
BEGIN INC(checks); IF ~value THEN INC(failed); Out.String(message); Out.Ln END END Check;

PROCEDURE Finish(): LONGINT;
VAR status, attempts: LONGINT;
BEGIN
  attempts := 0; status := H.Poll(handle, 77, changed);
  WHILE (status = Pub.pending) & (attempts < 5000) DO
    Platform.Delay(1); INC(attempts); status := H.Poll(handle, 77, changed)
  END;
  RETURN status
END Finish;

PROCEDURE Drain(): BOOLEAN;
VAR attempts: LONGINT;
BEGIN
  attempts := 0;
  WHILE ~H.Idle() & (attempts < 5000) DO Platform.Delay(1); INC(attempts) END;
  RETURN H.Idle()
END Drain;

PROCEDURE Times;
BEGIN
  Check(Clock.UTC(0, stamp) & (stamp = "1970-01-01T00:00:00Z"), "formatting Unix epoch in UTC");
  Check(Clock.UTC(951782400, stamp) & (stamp = "2000-02-29T00:00:00Z"), "formatting Gregorian leap day");
  Check(Clock.UTC(2147483648, stamp) & (stamp = "2038-01-19T03:14:08Z"), "formatting timestamps beyond signed 32-bit seconds");
  Check(Clock.UTC(4107542400, stamp) & (stamp = "2100-03-01T00:00:00Z"), "handling a non-leap century");
  Check(Clock.UTC(253402300799, stamp) & (stamp = "9999-12-31T23:59:59Z"), "bounding the last supported Atom year");
  Check(~Clock.UTC(253402300800, stamp) & (stamp = "9999-12-31T23:59:59Z"), "invalid time preserves output");
  Check(~Clock.UTC(-1, stamp), "rejecting negative source time");
  short := "x"; Check(~Clock.UTC(0, short) & (short = "x"), "short timestamp output stays unchanged")
END Times;

PROCEDURE Inspect;
BEGIN
  Check(H.State(handle, 77) = H.ready, "rooted account is ready");
  post := H.Get(handle, 77, "public", token);
  Check(P.Describe(post, header) & (header.published = "2038-01-19T03:14:08Z"), "retaining backend UTC metadata");
  Check(H.Get(handle, 78, "public", token) = NIL, "foreign owner cannot read account state");
  Check(H.Page(handle, 77, ":1.1", "public", "", 1, 100, page, first) = Pub.okay, "opening account/client cursor");
  Check((S.PageSize(page) = 1) & (first[0] # 0X), "returning bounded page and opaque continuation");
  Check(H.Page(handle, 77, ":1.2", "public", first, 1, 101, page, next) = Pub.stale, "cursor is client-bound");
  Check(H.Page(handle, 77, ":1.1", "other", first, 1, 101, page, next) = Pub.stale, "cursor is destination-bound");
  Check(H.Page(handle, 77, ":1.1", "public", first, 1, 101, page, second) = Pub.okay, "advancing account cursor");
  Check(H.Page(handle, 77, ":1.1", "public", first, 1, 102, page, next) = Pub.stale, "consumed cursor cannot silently skip a lost response");
  Check(H.Page(handle, 77, ":1.1", "public", second, 1, 102, page, next) = Pub.okay, "finishing exact-size page sequence");
  Check((S.PageSize(page) = 0) & (next = ""), "empty final page releases continuation");
  FOR i := 0 TO H.maxCursors-1 DO
    Check(H.Page(handle, 77, ":1.1", "public", "", 1, 200, page, next) = Pub.okay, "allocating each bounded cursor slot")
  END;
  Check(H.Page(handle, 77, ":1.1", "public", "", 1, 200, page, next) = Pub.busy, "enforcing account cursor bound");
  Check(H.Page(handle, 77, ":1.1", "public", "", 1, 200+H.cursorSeconds, page, first) = Pub.okay, "expiring abandoned cursors");
  Check(H.Page(handle, 77, ":1.1", "public", first, 1, 199, page, next) = Pub.stale, "clock rollback expires opaque cursors")
END Inspect;

PROCEDURE Operations;
BEGIN
  Check(H.State(handle, 77) = H.loading, "new root handle holds a pending load");
  Check(H.Open(77, profile, identity, "Ani@200::1", FALSE) = handle, "repeated attach retains the same account");
  Check(H.Open(78, profile, identity, "Ani@200::2", FALSE) = 0, "one active publisher per persistent identity");
  Check((Finish() = Pub.missing) & ~changed, "first missing checkpoint is not a publication change");
  Check(H.Initialize(handle, 77) = H.markerRequired, "requiring setup intent metadata before first checkpoint");
  Check(H.NeedsMarker(handle, 77) & ~H.Marked(handle, 78), "owner-binding setup metadata confirmation");
  Check(H.Marked(handle, 77), "confirming persistent setup marker");
  Check(H.Initialize(handle, 77) = Pub.pending, "submitting explicit first initialization");
  Check((Finish() = Pub.okay) & changed, "initialization changes only after persistence");
  Check(H.Initialize(handle, 77) = Pub.conflict, "existing history cannot be reset");
  Check(H.Create(handle, 77, "public", "Public", A.open, names, 0) = Pub.pending, "submitting public destination");
  Check((Finish() = Pub.okay) & changed, "committing public destination");
  Check(H.Publish(handle, 77, "public", token, "Title", "First", "", 2147483648) = Pub.pending, "submitting backend-timestamped publication");
  Check(H.State(handle, 77) = H.saving, "pending save reports its state");
  Check(H.Get(handle, 77, "public", token) = NIL, "pending publication remains private to candidate");
  Heap.GC(FALSE);
  Check((Finish() = Pub.okay) & changed, "module roots retain pending service through GC");
  Check(H.Publish(handle, 77, "public", token2, "Title", "Second", "", 2147483649) = Pub.pending, "submitting second publication");
  Check(Finish() = Pub.okay, "committing second publication");
  Check(H.Page(handle, 77, ":1.1", "public", "", 1, 1, captured, first) = Pub.okay, "capturing committed page");
  Check(H.Publish(handle, 77, "public", token, "Title", "First", "", 2147483650) = Pub.okay, "idempotent token retry creates no operation");
  Check(~H.Busy(handle, 77), "idempotent retry has no pending change hint");
  Check(H.Page(handle, 77, ":1.1", "public", first, 1, 2, page, next) = Pub.okay, "idempotent retry preserves active cursors");
  lock := Private.Open(profile); Check(lock >= 0, "holding profile lock");
  Check(H.Create(handle, 77, "failed", "Failed", A.open, names, 0) = Pub.pending, "submitting contended account mutation");
  status := Finish(); Private.Close(lock);
  Check((status = Pub.storageError) & ~changed, "failed mutation emits no successful change hint");
  Check(H.State(handle, 77) = H.unavailable, "uncertain storage state blocks account");
  Check(H.Reload(handle, 77) = Pub.pending, "submitting explicit account reload");
  Check((Finish() = Pub.okay) & ~changed, "reload restores without a mutation hint");
  Check(H.Page(handle, 77, ":1.1", "public", next, 1, 3, page, first) = Pub.stale, "reload invalidates prior cursors");
  Heap.GC(FALSE); Check(P.Describe(S.PagePost(captured, 0), header), "delivered page survives service replacement");
  Inspect;
  old := handle; H.Close(handle, 78); Check(H.State(handle, 77) = H.ready, "foreign owner cannot retire account");
  H.Close(handle, 77); Check(H.State(old, 77) = H.unavailable, "retired handle cannot read new account");
  handle := H.Open(77, profile, identity, "Ani@200::9", TRUE); Check(handle > old, "reconnect never reuses service handle");
  Check(Finish() = Pub.okay, "restoring account after reconnect");
  Check(H.State(old, 77) = H.unavailable, "stale handle remains invalid after reconnect");
  H.Close(handle, 77)
END Operations;

BEGIN
  Args.Get(1, profile); Args.Get(2, action); Times;
  Check(H.Start(), "starting rooted publishing account registry");
  handle := H.Open(77, profile, identity, "Ani@200::1", action # "new"); Check(handle > 0, "allocating rooted account handle");
  IF action = "new" THEN Operations
  ELSE
    status := Finish();
    IF action = "missing" THEN
      Check((status = Pub.missing) & (H.State(handle, 77) = H.unavailable), "missing configured history is unavailable");
      Check(H.Initialize(handle, 77) = Pub.conflict, "missing configured history cannot be initialized")
    ELSE
      Check(status = Pub.okay, "restoring existing configured account"); Inspect
    END;
    H.Close(handle, 77)
  END;
  H.Stop; Check(Drain(), "retiring all roots and draining workers before shutdown");
  Out.String("TestPublishAccounts: "); Out.Int(checks, 0); Out.String(" checks, "); Out.Int(failed, 0); Out.String(" failed"); Out.Ln;
  IF failed # 0 THEN HALT(100) END
END TestPublishAccounts.
