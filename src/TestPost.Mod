MODULE TestPost;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT P := BarevPost, Out, Heap;

VAR checks, failed, i: LONGINT; header, copy, changed: P.Header;
  post, same, revision, invalid: P.Post;
  text: ARRAY P.maxTextBytes+2 OF CHAR;
  short: ARRAY 5 OF CHAR;
  entropy: ARRAY 16 OF CHAR; extra: ARRAY 17 OF CHAR;
  token: ARRAY 33 OF CHAR; id: ARRAY 46 OF CHAR;

PROCEDURE Check(value: BOOLEAN; message: ARRAY OF CHAR);
BEGIN INC(checks); IF ~value THEN INC(failed); Out.String(message); Out.Ln END END Check;

PROCEDURE Fixture;
BEGIN
  header.owner := "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
  header.author := "Անի@0200:0:0:0:0:0:0:1";
  header.itemID := "post-1"; header.id := "urn:uuid:00000000-0000-4000-8000-000000000001";
  header.replyTo := ""; header.title := "Բարեւ 😀";
  header.published := "2026-11-20T00:00:00Z"; header.updated := header.published
END Fixture;

PROCEDURE Records;
BEGIN
  Fixture; post := P.New(header, "Hello <world> & friends" );
  Check(P.Valid(post), "constructing bounded text post");
  Check(P.Describe(post, copy), "reading post metadata");
  Check(copy.author = "Անի@200::1", "canonicalizing author address");
  Check(P.Size(post) > 22, "accounting for metadata and content");
  header.title := "changed"; header.id := "urn:changed";
  Check(P.Describe(post, copy) & (copy.title = "Բարեւ 😀") &
    (copy.id = "urn:uuid:00000000-0000-4000-8000-000000000001"), "copying input metadata");
  copy.title := "mutated output";
  Check(P.Describe(post, copy) & (copy.title = "Բարեւ 😀"), "returning metadata snapshots");
  Check(P.Content(post, text) & (text = "Hello <world> & friends"), "reading exact post content");
  text[0] := "x";
  Check(P.Content(post, text) & (text[0] = "H"), "returning content copies");
  short := "safe";
  Check(~P.Content(post, short) & (short = "safe"), "refusing truncation without changing output");
  Heap.GC(FALSE);
  Check(P.Describe(post, copy) & (copy.title = "Բարեւ 😀") & P.Content(post, text), "retaining rooted immutable post through collection");
  NEW(invalid);
  Check(~P.Valid(NIL) & ~P.Valid(invalid) & (P.Size(invalid) = 0), "unconfigured post is invalid");
  Check(~P.Describe(NIL, copy) & ~P.Content(invalid, text), "rejecting invalid post access");
  Fixture; same := P.New(header, "Hello <world> & friends");
  Check(P.Same(post, same), "comparing identical post revisions");
  Check(~P.Same(post, NIL) & ~P.Revision(post, same), "requiring a later revision timestamp");
  header.updated := "2026-11-20T00:00:01Z";
  revision := P.New(header, "Edited text");
  Check(P.Revision(post, revision) & ~P.Revision(revision, post), "ordering immutable revisions");
  header.replyTo := "https://example.org/posts/parent";
  revision := P.New(header, "Independent reply");
  Check(P.Valid(revision) & ~P.Revision(post, revision), "reply relationship is fixed across edits");
  Check(P.Describe(revision, copy) & (copy.replyTo = header.replyTo), "preserving independent reply reference");
  header.replyTo := header.id;
  Check(P.New(header, "Self reply") = NIL, "rejecting direct self reply");
  Fixture; header.updated := "2026-11-19T23:59:59Z";
  Check(P.New(header, "Earlier edit") = NIL, "rejecting update before publication");
  Fixture; header.owner[0] := "G";
  Check(P.New(header, "Forged owner") = NIL, "requiring canonical public key identifier");
  Fixture; header.author := "Ani@example.org";
  Check(P.New(header, "Invalid author") = NIL, "requiring canonical Barev author identity");
  Fixture; header.itemID := "bad id";
  Check(P.New(header, "Invalid item") = NIL, "rejecting invalid local item token");
  Fixture; header.id := "relative";
  Check(P.New(header, "Invalid ID") = NIL, "requiring absolute Atom ID");
  Fixture; header.replyTo := "relative";
  Check(P.New(header, "Invalid parent") = NIL, "requiring absolute parent reference");
  Fixture; Check(P.New(header, "") = NIL, "rejecting empty post content");
  header.title := ""; Check(P.New(header, "Untitled") # NIL, "allowing empty text title")
END Records;

PROCEDURE Bounds;
VAR j: LONGINT;
BEGIN
  Fixture;
  FOR j := 0 TO P.maxTextBytes DO text[j] := "x" END;
  text[P.maxTextBytes+1] := 0X;
  Check(P.New(header, text) = NIL, "bounding content bytes");
  text[P.maxTextBytes] := 0X; post := P.New(header, text);
  Check(P.Valid(post), "accepting maximum content length");
  FOR j := 0 TO LEN(text)-1 DO text[j] := "x" END;
  Check(P.New(header, text) = NIL, "rejecting unterminated content");
  FOR j := 0 TO LEN(header.title)-1 DO header.title[j] := "x" END;
  Check(P.New(header, "title") = NIL, "rejecting unterminated title");
  header.title[P.maxTitleBytes] := 0X;
  Check(P.New(header, "title") # NIL, "accepting maximum title bytes");
  FOR j := 0 TO LEN(header.itemID)-1 DO header.itemID[j] := "x" END;
  Check(P.New(header, "item") = NIL, "rejecting unterminated item identifier");
  header.itemID[P.maxItemBytes] := 0X;
  Check(P.New(header, "item") # NIL, "accepting maximum item identifier");
  Fixture;
  FOR j := 1 TO 31 DO
    text[0] := CHR(j); text[1] := 0X;
    Check((P.New(header, text) # NIL) = ((j = 9) OR (j = 10) OR (j = 13)), "checking XML control characters")
  END;
  text[0] := 0C0X; text[1] := 0AFX; text[2] := 0X;
  Check(P.New(header, text) = NIL, "rejecting overlong UTF-8");
  text[0] := 0EDX; text[1] := 0A0X; text[2] := 80X; text[3] := 0X;
  Check(P.New(header, text) = NIL, "rejecting UTF-8 surrogate");
  text[0] := 0EFX; text[1] := 0BFX; text[2] := 0BEX; text[3] := 0X;
  Check(P.New(header, text) = NIL, "rejecting XML noncharacter");
  text[0] := 0F4X; text[1] := 90X; text[2] := 80X; text[3] := 80X; text[4] := 0X;
  Check(P.New(header, text) = NIL, "rejecting out-of-range Unicode");
  Check(P.New(header, "Բարեւ 😀") # NIL, "accepting multilingual content")
END Bounds;

PROCEDURE Times;
BEGIN
  Check(P.Timestamp("2000-02-29T23:59:59Z"), "Gregorian leap century");
  Check(~P.Timestamp("1900-02-29T23:59:59Z"), "Gregorian non-leap century");
  Check(P.Timestamp("2024-02-29T00:00:00Z"), "ordinary leap year");
  Check(~P.Timestamp("2026-02-29T00:00:00Z"), "ordinary non-leap year");
  Check(~P.Timestamp("2026-04-31T00:00:00Z"), "short calendar month");
  Check(~P.Timestamp("0000-01-01T00:00:00Z"), "rejecting year zero");
  Check(~P.Timestamp("2026-00-01T00:00:00Z"), "rejecting month zero");
  Check(~P.Timestamp("2026-13-01T00:00:00Z"), "rejecting month overflow");
  Check(~P.Timestamp("2026-01-00T00:00:00Z"), "rejecting day zero");
  Check(~P.Timestamp("2026-01-01T24:00:00Z"), "rejecting hour overflow");
  Check(~P.Timestamp("2026-01-01T00:60:00Z"), "rejecting minute overflow");
  Check(~P.Timestamp("2026-01-01T00:00:60Z"), "requiring ordinary UTC seconds");
  Check(~P.Timestamp("2026-01-01T00:00:00z"), "requiring canonical UTC marker");
  Check(~P.Timestamp("2026-01-01T00:00:00Zx"), "rejecting timestamp trailing data");
  Check(~P.Timestamp("2026-01-01"), "rejecting truncated timestamp");
  Check(P.Timestamp("0001-01-01T00:00:00Z") & P.Timestamp("9999-12-31T23:59:59Z"), "supporting four-digit Gregorian years")
END Times;

PROCEDURE IDs;
BEGIN
  FOR i := 0 TO 15 DO entropy[i] := CHR(i) END;
  Check(P.Identifiers(entropy, token, id), "formatting independent random identifiers");
  Check((token = "000102030405460788090a0b0c0d0e0f") &
    (id = "urn:uuid:00010203-0405-4607-8809-0a0b0c0d0e0f"), "canonical UUIDv4 and PubSub item IDs");
  Check(entropy[6] = 6X, "identifier formatting does not mutate entropy");
  short := "safe";
  Check(~P.Identifiers(entropy, short, id) & (short = "safe"), "rejecting short identifier output");
  Check(~P.Identifiers(extra, token, id), "requiring exactly sixteen entropy bytes");
  Check(P.Reference("tag:example.org,2026:post-1", FALSE), "accepting tag identifiers");
  Check(P.Reference("https://example.org/posts/1?x=1#reply", FALSE), "accepting absolute URI references");
  Check(~P.Reference("", FALSE) & P.Reference("", TRUE), "optional parent reference");
  Check(~P.Reference("urn:bad id", FALSE), "rejecting whitespace in identifiers");
  Check(~P.Reference("https://example.org/%xx", FALSE), "rejecting malformed URI escapes")
END IDs;

BEGIN
  Records; Bounds; Times; IDs;
  Out.String("TestPost: "); Out.Int(checks, 0); Out.String(" checks, ");
  Out.Int(failed, 0); Out.String(" failed"); Out.Ln;
  IF failed # 0 THEN HALT(100) END
END TestPost.
