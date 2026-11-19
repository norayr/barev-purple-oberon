MODULE TestPostStore;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT S := BarevPostStore, P := BarevPost, A := BarevFeedAccess,
  Out, Heap, IntStr, Strings := oocStrings;

CONST owner = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";

VAR checks, failed, i: LONGINT;
  store, other, empty: S.Store;
  p, q, r, replacement: P.Post;
  header, saved: P.Header;
  public, selected, group, nobody: A.Node;
  contact, moved, changed: A.Contact;
  anonymous, reader: A.Reader;
  names: ARRAY A.maxMembers OF A.Name;
  groups: ARRAY A.maxGroups OF A.Name;
  key, newKey: ARRAY 32 OF CHAR;
  cursor, second: S.Cursor;
  page, captured: S.Page;
  info: S.NodeInfo;
  text: ARRAY P.maxTextBytes+1 OF CHAR;

PROCEDURE Check(value: BOOLEAN; message: ARRAY OF CHAR);
BEGIN INC(checks); IF ~value THEN INC(failed); Out.String(message); Out.Ln END END Check;

PROCEDURE Make(number: LONGINT; text: ARRAY OF CHAR): P.Post;
VAR digits: ARRAY 16 OF CHAR;
BEGIN
  header.owner := owner; header.author := "Ani@200::1";
  IntStr.IntToStr(number, digits);
  header.itemID := "post-"; Strings.Append(digits, header.itemID);
  header.id := "urn:post:"; Strings.Append(digits, header.id);
  header.replyTo := ""; header.title := "Title";
  header.published := "2026-11-20T00:00:00Z"; header.updated := header.published;
  RETURN P.New(header, text)
END Make;

PROCEDURE Setup;
BEGIN
  S.Close(store); S.Close(other);
  store := S.New(owner, S.maxNodes, S.maxPosts, S.maxBytes);
  names[0] := "reader@200::2"; groups[0] := "friends";
  public := A.NewNode(A.open, names, 0);
  selected := A.NewNode(A.whitelist, names, 1);
  group := A.NewNode(A.roster, groups, 1);
  nobody := A.NewNode(A.whitelist, names, 0);
  contact := A.NewContact(names[0], key, TRUE, groups, 1);
  moved := A.NewContact(names[0], key, TRUE, groups, 0);
  changed := A.NewContact(names[0], newKey, TRUE, groups, 1);
  A.Anonymous(anonymous);
  Check(A.Authenticate(reader, names[0], key, TRUE, TRUE), "capturing fixture connection");
  Check(S.AddNodeOwner(store, "public", "Public", public) = S.okay, "adding public node");
  Check(S.AddNodeOwner(store, "selected", "Selected", selected) = S.okay, "adding whitelist node");
  Check(S.AddNodeOwner(store, "group", "Group", group) = S.okay, "adding roster node")
END Setup;

PROCEDURE Configuration;
VAR number: ARRAY 16 OF CHAR; name: ARRAY S.maxNodeBytes+1 OF CHAR; j: LONGINT;
BEGIN
  Check(S.New("bad", 1, 1, 1) = NIL, "requiring persistent owner identifier");
  Check(S.New(owner, 0, 1, 1) = NIL, "rejecting zero node quota");
  Check(S.New(owner, S.maxNodes+1, 1, 1) = NIL, "bounding node quota");
  Check(S.New(owner, 1, 0, 1) = NIL, "rejecting zero post quota");
  Check(S.New(owner, 1, S.maxPosts+1, 1) = NIL, "bounding post quota");
  Check(S.New(owner, 1, 1, 0) = NIL, "rejecting zero byte quota");
  Check(S.New(owner, 1, 1, S.maxBytes+1) = NIL, "bounding byte quota");
  Check(S.New(owner, MAX(LONGINT), MAX(LONGINT), MAX(LONGINT)) = NIL, "rejecting oversized capacities before allocation");
  Setup;
  Check(S.AddNodeOwner(store, "public", "Duplicate", public) = S.conflict, "node IDs are unique");
  Check(S.AddNodeOwner(store, "bad node", "Title", public) = S.invalid, "checking node tokens");
  Check(S.AddNodeOwner(store, "empty", "", public) = S.invalid, "requiring safe node title");
  Check(S.AddNodeOwner(store, "empty", "Title", NIL) = S.invalid, "requiring explicit audience policy");
  Check(S.PolicyOwner(store, "public", selected) = S.invalid, "preserving public access model");
  Check(S.PolicyOwner(store, "selected", public) = S.invalid, "preventing private node becoming public");
  Check(S.PolicyOwner(store, "group", selected) = S.invalid, "preserving private access model");
  Check(S.PolicyOwner(store, "selected", NIL) = S.invalid, "rejecting missing replacement policy");
  Check(S.PolicyOwner(store, "absent", public) = S.missing, "reporting unknown owner node");
  Check(S.NodesOwner(store) = 3, "counting owner destinations");
  Check(S.NodeOwner(store, 0, info) & (info.name = "public") & (info.title = "Public") &
    (info.model = A.open), "reading owner node snapshot");
  info.title := "changed";
  Check(S.NodeOwner(store, 0, info) & (info.title = "Public"), "node metadata is copied on retrieval");
  Check(~S.NodeOwner(store, -1, info) & ~S.NodeOwner(store, 3, info), "bounding owner node indices");
  Check(S.DescribeNode(store, "public", anonymous, NIL, info), "public node description is visible");
  Check(~S.DescribeNode(store, "selected", anonymous, contact, info) & (info.name = "public"), "private node denial does not write output");
  Check(~S.DescribeNode(store, "missing", anonymous, NIL, info), "missing and hidden node descriptions are indistinguishable");
  Check(S.DescribeNode(store, "selected", reader, contact, info) & (info.model = A.whitelist), "authorized private node description");
  other := S.New(owner, 1, 1, 2);
  Check(S.AddNodeOwner(other, "public", "Public", public) = S.full, "charging node strings to byte quota");
  S.Close(other); other := S.New(owner, S.maxNodes, 1, 4096);
  FOR j := 0 TO S.maxNodes-1 DO
    IntStr.IntToStr(j, number); name := "node-"; Strings.Append(number, name);
    Check(S.AddNodeOwner(other, name, "Title", public) = S.okay, "accepting every bounded node slot")
  END;
  Check(S.AddNodeOwner(other, "overflow", "Title", public) = S.full, "enforcing node count bound");
  Check(S.AddNodeOwner(NIL, "public", "Public", public) = S.invalid, "rejecting missing store");
  NEW(empty);
  Check(S.AddNodeOwner(empty, "public", "Public", public) = S.invalid, "rejecting unconfigured store");
  S.Close(empty); Check(empty = NIL, "closing unconfigured store")
END Configuration;

PROCEDURE Publication;
VAR count, bytes: LONGINT;
BEGIN
  Setup; p := Make(1, "Public text"); q := Make(2, "Private text");
  Check(S.PutOwner(store, "public", p) = S.okay, "publishing public text");
  Check(S.PutOwner(store, "selected", q) = S.okay, "publishing private text");
  count := S.CountOwner(store); bytes := S.BytesOwner(store);
  Check((count = 2) & (S.ReservedOwner(store) = 2), "counting accepted posts");
  Check(S.BeginOwner(store, "public", cursor) = S.okay, "starting owner snapshot");
  Check(S.PutOwner(store, "public", p) = S.okay, "idempotent publication retry");
  Check((S.CountOwner(store) = count) & (S.BytesOwner(store) = bytes), "retry leaves accounting unchanged");
  Check(S.ReadOwner(cursor, 1, page) = S.okay, "retry does not invalidate cursor");
  Check(S.GetOwner(store, "public", "post-1") = p, "owner retrieves exact immutable record");
  Check(S.PutOwner(store, "selected", p) = S.conflict, "preventing cross-node moves");
  Check(S.PutOwner(store, "public", q) = S.conflict, "preventing private republication under existing IDs");
  Check(P.Describe(p, header), "copying publication metadata");
  header.itemID := "other-item"; r := P.New(header, "Same Atom ID");
  Check(S.PutOwner(store, "public", r) = S.conflict, "Atom IDs are unique across nodes");
  Check(P.Describe(p, header), "copying item identity");
  header.id := "urn:other:post"; r := P.New(header, "Same item ID");
  Check(S.PutOwner(store, "public", r) = S.conflict, "item IDs are reserved across nodes");
  Check(P.Describe(p, header), "copying revision identity");
  r := P.New(header, "Changed without edit");
  Check(S.PutOwner(store, "public", r) = S.conflict, "publication cannot overwrite content");
  header.owner[0] := "0"; r := P.New(header, "Other owner");
  Check(S.PutOwner(store, "public", r) = S.denied, "binding publication to store owner");
  Check(S.PutOwner(store, "missing", p) = S.missing, "rejecting unknown destination");
  Check(S.PutOwner(store, "public", NIL) = S.invalid, "rejecting invalid post");
  Check((S.CountOwner(store) = count) & (S.BytesOwner(store) = bytes), "failed publications preserve all accounting");
  Check(S.Get(store, "public", "post-1", anonymous, NIL) = p, "anonymous public retrieval");
  Check(S.Get(store, "selected", "post-2", anonymous, contact) = NIL, "anonymous private isolation");
  Check(S.Get(store, "selected", "post-2", reader, contact) = q, "authenticated whitelist retrieval");
  Check(S.Get(store, "selected", "post-2", reader, changed) = NIL, "rechecking current pin at retrieval");
  Check(S.Get(store, "selected", "post-2", reader, NIL) = NIL, "requiring current contact snapshot");
  r := Make(3, "Group text"); Check(S.PutOwner(store, "group", r) = S.okay, "publishing to roster node");
  Check(S.Get(store, "group", "post-3", reader, contact) = r, "current group member reads history");
  Check(S.Get(store, "group", "post-3", reader, moved) = NIL, "group removal revokes retained history");
  Check(S.PolicyOwner(store, "selected", nobody) = S.okay, "updating live whitelist policy");
  Check(S.Get(store, "selected", "post-2", reader, contact) = NIL, "policy replacement takes effect immediately");
  Check(S.PolicyOwner(store, "selected", selected) = S.okay, "restoring selected member");
  Check(S.Get(store, "selected", "post-2", reader, contact) = q, "new membership grants retained history");
  A.Close(reader);
  Check(S.Get(store, "public", "post-1", reader, contact) = NIL, "disconnected reader has no transport authority");
  Heap.GC(FALSE);
  Check(S.GetOwner(store, "selected", "post-2") = q, "retaining store and immutable records through collection")
END Publication;

PROCEDURE Revisions;
VAR bytes: LONGINT;
BEGIN
  Setup; p := Make(1, "Original"); Check(S.PutOwner(store, "public", p) = S.okay, "storing revision fixture");
  bytes := S.BytesOwner(store); Check(P.Describe(p, header), "reading original header");
  header.updated := "2026-11-20T00:00:01Z"; q := P.New(header, "Edited and longer");
  Check(S.BeginOwner(store, "public", cursor) = S.okay, "capturing pre-edit cursor");
  Check(S.EditOwner(store, "public", p, q) = S.okay, "replacing expected revision");
  Check(S.GetOwner(store, "public", "post-1") = q, "reading latest immutable revision");
  Check((S.CountOwner(store) = 1) & (S.ReservedOwner(store) = 1) &
    (S.BytesOwner(store) = bytes+P.Size(q)-P.Size(p)), "revision accounting does not allocate another ID");
  Check(P.Content(p, text) & (text = "Original"), "previously delivered revision remains unchanged");
  Check((S.ReadOwner(cursor, 1, page) = S.stale) & (page = NIL), "edit invalidates same-node cursor");
  Check(S.BeginOwner(store, "public", cursor) = S.okay, "capturing post-edit cursor");
  Check(S.EditOwner(store, "public", p, q) = S.okay, "idempotent edit retry");
  Check(S.ReadOwner(cursor, 1, page) = S.okay, "edit retry does not invalidate cursor");
  header.updated := "2026-11-20T00:00:02Z"; r := P.New(header, "Concurrent edit");
  Check(S.EditOwner(store, "public", p, r) = S.conflict, "rejecting stale expected revision");
  Check(S.EditOwner(store, "public", q, r) = S.okay, "accepting current expected revision");
  saved := header; header.published := "2026-11-19T00:00:00Z";
  header.updated := "2026-11-20T00:00:03Z"; replacement := P.New(header, "Changed publication time");
  Check(S.EditOwner(store, "public", r, replacement) = S.conflict, "preserving publication time");
  header := saved; header.updated := "2026-11-20T00:00:03Z"; header.replyTo := "urn:external:parent";
  replacement := P.New(header, "Changed parent");
  Check(S.EditOwner(store, "public", r, replacement) = S.conflict, "preserving reply relationship");
  header := saved; header.updated := "2026-11-20T00:00:03Z"; header.author := "Other@200::2";
  replacement := P.New(header, "Changed author");
  Check(S.EditOwner(store, "public", r, replacement) = S.conflict, "preserving author identity");
  header := saved; header.updated := "2026-11-20T00:00:03Z"; header.id := "urn:changed:identity";
  replacement := P.New(header, "Changed Atom identity");
  Check(S.EditOwner(store, "public", r, replacement) = S.conflict, "preserving Atom identifier");
  Check(S.EditOwner(store, "selected", r, r) = S.missing, "edits cannot move publications between nodes");
  Check(S.EditOwner(store, "public", NIL, r) = S.invalid, "requiring expected immutable revision");
  Check(S.GetOwner(store, "public", "post-1") = r, "failed edits leave current revision intact")
END Revisions;

PROCEDURE Retractions;
VAR bytes, reserved: LONGINT;
BEGIN
  Setup; p := Make(1, "Retracted text"); q := Make(2, "Retained text");
  Check(S.PutOwner(store, "public", p) = S.okay, "storing retraction fixture");
  Check(S.PutOwner(store, "public", q) = S.okay, "storing retained fixture");
  Check(P.Describe(p, header), "reading retracted identifiers");
  bytes := S.BytesOwner(store); reserved := Strings.Length(header.itemID)+Strings.Length(header.id);
  Check(S.BeginOwner(store, "public", cursor) = S.okay, "capturing pre-retraction cursor");
  Check(S.RetractOwner(store, "public", "post-1") = S.okay, "retracting publication");
  Check((S.CountOwner(store) = 1) & (S.ReservedOwner(store) = 2) &
    (S.BytesOwner(store) = bytes-P.Size(p)+reserved), "releasing content budget while reserving IDs");
  Check((S.GetOwner(store, "public", "post-1") = NIL) &
    (S.Get(store, "public", "post-1", anonymous, NIL) = NIL), "retracted posts are absent from reads");
  Check(S.ReadOwner(cursor, 2, page) = S.stale, "retraction invalidates same-node paging");
  bytes := S.BytesOwner(store);
  Check(S.RetractOwner(store, "public", "post-1") = S.okay, "idempotent retraction retry");
  Check(S.BytesOwner(store) = bytes, "retraction retry leaves accounting unchanged");
  Check(S.PutOwner(store, "public", p) = S.conflict, "preventing resurrection after retraction");
  header.itemID := "new-item"; r := P.New(header, "Reusing Atom ID");
  Check(S.PutOwner(store, "selected", r) = S.conflict, "reserving retracted Atom ID across nodes");
  header.itemID := "post-1"; header.id := "urn:new:identity"; r := P.New(header, "Reusing item ID");
  Check(S.PutOwner(store, "public", r) = S.conflict, "reserving retracted item ID");
  Check(S.EditOwner(store, "public", p, p) = S.conflict, "retracted publication cannot be edited");
  Check(S.RetractOwner(store, "public", "absent") = S.missing, "unknown retraction does not allocate tombstone");
  Check(S.BeginOwner(store, "public", cursor) = S.okay, "paging retained publications");
  Check((S.ReadOwner(cursor, 2, page) = S.okay) & (S.PageSize(page) = 1) &
    (S.PagePost(page, 0) = q), "pages exclude retracted records");
  Check(P.Content(p, text) & (text = "Retracted text"), "already delivered copy survives local retraction")
END Retractions;

PROCEDURE Paging;
VAR j, expected: LONGINT;
BEGIN
  Setup;
  FOR j := 0 TO 13 DO
    p := Make(j, "Page fixture");
    IF ODD(j) THEN Check(S.PutOwner(store, "selected", p) = S.okay, "interleaving private posts")
    ELSE Check(S.PutOwner(store, "public", p) = S.okay, "interleaving public posts") END
  END;
  Check(S.Begin(store, "public", anonymous, NIL, cursor) = S.okay, "starting authorized page sequence");
  Check((S.Read(cursor, anonymous, NIL, 0, page) = S.invalid) & (page = NIL), "rejecting zero page size");
  Check(S.Read(cursor, anonymous, NIL, S.maxPage+1, page) = S.invalid, "bounding page size");
  Check(S.Read(cursor, anonymous, NIL, MAX(LONGINT), page) = S.invalid, "rejecting oversized page request");
  expected := 12;
  WHILE expected >= 0 DO
    Check(S.Read(cursor, anonymous, NIL, 3, page) = S.okay, "reading bounded public-only page");
    Check((S.PageSize(page) > 0) & (S.PageSize(page) <= 3), "bounding actual result count");
    FOR j := 0 TO S.PageSize(page)-1 DO
      Check(P.Describe(S.PagePost(page, j), saved), "reading paged metadata");
      p := Make(expected, "Page fixture");
      Check(P.Describe(p, header) & (header.id = saved.id), "newest-first order skips private slots");
      DEC(expected, 2)
    END;
    p := Make(100+expected, "Unrelated private mutation");
    Check(S.PutOwner(store, "selected", p) = S.okay, "private changes do not invalidate public paging")
  END;
  Check((S.Read(cursor, anonymous, NIL, 1, page) = S.okay) & (S.PageSize(page) = 0), "exhausted cursor returns empty page");
  Check((S.PagePost(page, -1) = NIL) & (S.PagePost(page, 0) = NIL) &
    (S.PagePost(NIL, 0) = NIL), "bounding page indexing");
  Check(S.Begin(store, "public", anonymous, NIL, cursor) = S.okay, "starting new public snapshot");
  p := Make(200, "New public post"); Check(S.PutOwner(store, "public", p) = S.okay, "mutating public node");
  Check((S.Read(cursor, anonymous, NIL, 1, page) = S.stale) & (page = NIL), "public mutation requires fresh cursor");
  Check(S.Begin(store, "selected", reader, contact, cursor) = S.okay, "starting private snapshot");
  Check(S.Read(cursor, reader, changed, 1, page) = S.denied, "rechecking pin on every page");
  Check(S.Read(cursor, reader, contact, 1, page) = S.okay, "failed access does not advance cursor");
  captured := page;
  Check(S.PolicyOwner(store, "selected", nobody) = S.okay, "revoking private snapshot access");
  Check((S.Read(cursor, reader, contact, 1, page) = S.denied) & (page = NIL), "authorization precedes stale-cursor result");
  Check(S.PolicyOwner(store, "selected", selected) = S.okay, "restoring private policy");
  Check(S.Read(cursor, reader, contact, 1, page) = S.stale, "policy change invalidates old cursor");
  Check(S.PageSize(captured) = 1, "already delivered page is an immutable snapshot");
  Check(S.BeginOwner(store, "selected", cursor) = S.okay, "starting owner cursor");
  Check(S.Read(cursor, anonymous, contact, 1, page) = S.denied, "owner cursor cannot grant remote access");
  Check(S.Begin(store, "selected", reader, contact, cursor) = S.okay, "starting remote cursor");
  Check(S.ReadOwner(cursor, 1, page) = S.invalid, "remote cursor is distinct from owner cursor");
  Check(S.Begin(store, "selected", anonymous, contact, cursor) = S.denied, "denied begin cancels old cursor");
  Check(S.Read(cursor, reader, contact, 1, page) = S.denied, "cancelled cursor cannot resume old authority");
  Check(S.Begin(store, "missing", anonymous, NIL, cursor) = S.denied, "hidden and missing node have same remote result");
  Check(S.BeginOwner(store, "public", cursor) = S.okay, "capturing close fixture");
  other := store; S.Close(store);
  Check((store = NIL) & (S.CountOwner(other) = 0), "closing all aliases of store state");
  Check((S.ReadOwner(cursor, 1, page) = S.invalid) & (page = NIL), "closing store invalidates old cursors");
  S.Close(other); S.Cancel(cursor)
END Paging;

PROCEDURE Replies;
BEGIN
  Setup; p := Make(1, "Private parent");
  Check(S.PutOwner(store, "selected", p) = S.okay, "publishing private parent");
  q := Make(2, "Private reply"); header.replyTo := "urn:post:1"; q := P.New(header, "Private reply");
  Check(S.PutOwner(store, "public", q) = S.denied, "private parent reference cannot widen to public node");
  Check(S.PutOwner(store, "group", q) = S.denied, "different private node is not the same audience");
  Check(S.PutOwner(store, "selected", q) = S.okay, "reply is independent post in same private node");
  Check(S.RetractOwner(store, "selected", "post-1") = S.okay, "retracting private parent");
  r := Make(3, "Reply to removed parent"); header.replyTo := "urn:post:1"; r := P.New(header, "Reply to removed parent");
  Check(S.PutOwner(store, "public", r) = S.denied, "private tombstone still protects parent reference");
  p := Make(4, "Public parent"); Check(S.PutOwner(store, "public", p) = S.okay, "publishing public parent");
  r := Make(5, "Private response"); header.replyTo := "urn:post:4"; r := P.New(header, "Private response");
  Check(S.PutOwner(store, "group", r) = S.okay, "public parent can receive a narrower reply");
  p := Make(6, "Unknown parent"); header.replyTo := "urn:post:7"; p := P.New(header, "Unknown parent");
  Check(S.PutOwner(store, "public", p) = S.okay, "retaining missing parent context");
  q := Make(7, "Cyclic parent"); header.replyTo := "urn:post:6"; q := P.New(header, "Cyclic parent");
  Check(S.PutOwner(store, "public", q) = S.denied, "rejecting cycle completed by a later parent")
END Replies;

PROCEDURE Limits;
VAR j, base, bytes: LONGINT;
BEGIN
  Setup; S.Close(other); other := S.New(owner, 1, 2, S.maxBytes);
  Check(S.AddNodeOwner(other, "public", "Public", public) = S.okay, "adding quota node");
  p := Make(1, "First"); q := Make(2, "Second"); r := Make(3, "Third");
  Check((S.PutOwner(other, "public", p) = S.okay) & (S.PutOwner(other, "public", q) = S.okay), "filling configured post quota");
  Check(S.PutOwner(other, "public", r) = S.full, "refusing full-store write");
  Check(S.PutOwner(other, "public", p) = S.okay, "full store still accepts idempotent retry");
  Check(S.RetractOwner(other, "public", "post-1") = S.okay, "retracting from full store");
  Check(S.PutOwner(other, "public", r) = S.full, "tombstones consume reserved ID slots");
  S.Close(other); other := S.New(owner, 1, S.maxPosts, S.maxBytes);
  Check(S.AddNodeOwner(other, "public", "Public", public) = S.okay, "adding maximum-slot fixture");
  FOR j := 0 TO S.maxPosts-1 DO
    p := Make(j, "Bounded"); Check(S.PutOwner(other, "public", p) = S.okay, "accepting every bounded post slot")
  END;
  p := Make(S.maxPosts, "Overflow"); Check(S.PutOwner(other, "public", p) = S.full, "enforcing hard post slot bound");
  Check((S.CountOwner(other) = S.maxPosts) & (S.ReservedOwner(other) = S.maxPosts), "hard slot accounting");
  S.Close(other);
  p := Make(1, "Budget"); base := 12;
  other := S.New(owner, 1, 2, base+P.Size(p));
  Check(S.AddNodeOwner(other, "public", "Public", public) = S.okay, "charging exact node budget");
  Check(S.PutOwner(other, "public", p) = S.okay, "accepting exact content byte quota");
  Check(S.BytesOwner(other) = base+P.Size(p), "exact logical byte accounting");
  Check(S.BeginOwner(other, "public", cursor) = S.okay, "capturing full-byte snapshot");
  Check(P.Describe(p, header), "copying byte-limit revision header");
  header.updated := "2026-11-20T00:00:01Z"; q := P.New(header, "Larger budget");
  Check(S.EditOwner(other, "public", p, q) = S.full, "rejecting edit exceeding byte quota");
  Check(S.GetOwner(other, "public", "post-1") = p, "failed edit leaves previous publication intact");
  Check(S.ReadOwner(cursor, 1, page) = S.okay, "failed write does not invalidate paging");
  bytes := S.BytesOwner(other); header.updated := "2026-11-20T00:00:02Z"; q := P.New(header, "x");
  Check(S.EditOwner(other, "public", p, q) = S.okay, "smaller revision releases byte quota");
  Check(S.BytesOwner(other) = bytes-P.Size(p)+P.Size(q), "smaller revision byte accounting");
  S.Close(other);
  Check((S.GetOwner(NIL, "public", "post-1") = NIL) & (S.BytesOwner(NIL) = 0), "nil store reads fail safely");
  Check((S.ReadOwner(second, 1, page) = S.invalid) & (page = NIL), "empty cursor fails safely")
END Limits;

PROCEDURE Roots;
VAR j: LONGINT;
BEGIN
  Setup;
  FOR j := 0 TO S.maxPage-1 DO
    p := Make(j, "Retained only by store");
    Check(S.PutOwner(store, "public", p) = S.okay, "rooting each stored immutable post")
  END;
  p := NIL; q := NIL; r := NIL; replacement := NIL;
  Heap.GC(FALSE);
  Check(S.BeginOwner(store, "public", cursor) = S.okay, "paging collected store graph");
  Check((S.ReadOwner(cursor, S.maxPage, page) = S.okay) & (S.PageSize(page) = S.maxPage), "retaining full page through collection");
  S.Close(store); Heap.GC(FALSE);
  FOR j := 0 TO S.maxPage-1 DO
    Check(P.Describe(S.PagePost(page, j), saved), "delivered page roots posts after store closes");
    Check(P.Content(S.PagePost(page, j), text) & (text = "Retained only by store"), "retaining immutable text through page snapshots")
  END
END Roots;

BEGIN
  FOR i := 0 TO 31 DO key[i] := CHR(i); newKey[i] := CHR(31-i) END;
  Configuration; Publication; Revisions; Retractions; Paging; Replies; Limits; Roots;
  S.Close(store); S.Close(other);
  Out.String("TestPostStore: "); Out.Int(checks, 0); Out.String(" checks, ");
  Out.Int(failed, 0); Out.String(" failed"); Out.Ln;
  IF failed # 0 THEN HALT(100) END
END TestPostStore.
