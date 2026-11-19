MODULE TestPostSnapshot;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT S := BarevPostStore, P := BarevPost, A := BarevFeedAccess,
  B := BarevPostBinary, I := XmppItems, Out, Heap;

CONST owner = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";

VAR checks, failed, length, copyLength, i, j: LONGINT;
  store, restored, previous, empty: S.Store;
  p, q: P.Post; header: P.Header;
  names: ARRAY A.maxMembers OF A.Name;
  groups: ARRAY A.maxGroups OF A.Name;
  key: ARRAY 32 OF CHAR;
  public, selected, roster: A.Node;
  contact: A.Contact; reader, anonymous: A.Reader;
  data, copy, synthetic: I.Bytes;
  writer: B.Writer; binary: B.Reader;
  word, position: LONGINT; saved: CHAR;
  text: ARRAY 64 OF CHAR;

PROCEDURE Check(value: BOOLEAN; message: ARRAY OF CHAR);
BEGIN INC(checks); IF ~value THEN INC(failed); Out.String(message); Out.Ln END END Check;

PROCEDURE Post(item, id, body: ARRAY OF CHAR): P.Post;
BEGIN
  header.owner := owner; header.author := "Անի@200::1";
  COPY(item, header.itemID); COPY(id, header.id);
  header.title := "Բարեւ 😀"; header.replyTo := "";
  header.published := "2026-11-20T00:00:00Z"; header.updated := header.published;
  RETURN P.New(header, body)
END Post;

PROCEDURE Fixture;
BEGIN
  S.Close(store); S.Close(restored); S.Close(previous);
  names[0] := "reader@200::2"; groups[0] := "ընկերներ";
  public := A.NewNode(A.open, names, 0); selected := A.NewNode(A.whitelist, names, 1);
  roster := A.NewNode(A.roster, groups, 1);
  contact := A.NewContact(names[0], key, TRUE, groups, 1);
  Check(A.Authenticate(reader, names[0], key, TRUE, TRUE), "capturing snapshot fixture reader");
  A.Anonymous(anonymous);
  store := S.New(owner, 8, 16, 65536);
  Check(S.AddNodeOwner(store, "public", "Public", public) = S.okay, "snapshot public destination");
  Check(S.AddNodeOwner(store, "selected", "Selected", selected) = S.okay, "snapshot whitelist destination");
  Check(S.AddNodeOwner(store, "group", "Group", roster) = S.okay, "snapshot roster destination");
  p := Post("post-1", "urn:post:1", "Public content");
  Check(S.PutOwner(store, "public", p) = S.okay, "snapshot public post");
  p := Post("post-2", "urn:post:2", "Private content");
  Check(S.PutOwner(store, "selected", p) = S.okay, "snapshot private post");
  p := Post("post-3", "urn:post:3", "Group content");
  Check(S.PutOwner(store, "group", p) = S.okay, "snapshot group post");
  p := Post("post-4", "urn:post:4", "Retracted content");
  Check(S.PutOwner(store, "public", p) = S.okay, "snapshot retraction fixture");
  Check(S.RetractOwner(store, "public", "post-4") = S.okay, "snapshot tombstone")
END Fixture;

PROCEDURE RoundTrip;
VAR count: LONGINT; small: ARRAY 1 OF A.Name; two: A.Node;
BEGIN
  Fixture;
  Check(S.EncodeOwner(store, data, length) & (length > 100), "encoding bounded store image");
  Check(B.Checked(data, length), "snapshot checksum verifies");
  restored := S.DecodeOwner(data, length, owner);
  Check((restored # NIL) & (S.CountOwner(restored) = 3) &
    (S.ReservedOwner(restored) = 4) & (S.NodesOwner(restored) = 3), "restoring posts, destinations and reserved IDs");
  Check(S.BytesOwner(restored) = S.BytesOwner(store), "restoring logical byte accounting");
  Check(S.ExtendsOwner(store, restored) & S.ExtendsOwner(restored, store), "identical restored state preserves lineage");
  Check(S.EncodeOwner(restored, copy, copyLength) & B.Equal(data, length, copy, copyLength), "deterministic binary snapshot round trip");
  Check(S.Get(restored, "public", "post-1", anonymous, NIL) # NIL, "restored public access");
  Check(S.Get(restored, "selected", "post-2", anonymous, contact) = NIL, "restored anonymous private isolation");
  Check(S.Get(restored, "selected", "post-2", reader, contact) # NIL, "restored whitelist membership");
  Check(S.Get(restored, "group", "post-3", reader, contact) # NIL, "restored Unicode roster policy");
  Check(S.GetOwner(restored, "public", "post-4") = NIL, "restored tombstone has no live content");
  p := Post("post-4", "urn:post:4", "Reused identity");
  Check(S.PutOwner(restored, "public", p) = S.conflict, "reserved identities survive restoration");
  count := 7; names[0] := "unchanged";
  Check(~A.CopyPolicy(NIL, names, count) & (count = 7) & (names[0] = "unchanged"), "invalid policy copy preserves outputs");
  Check(A.CopyPolicy(selected, names, count) & (count = 1) & (names[0] = "reader@200::2"), "copying canonical policy names");
  names[0] := "modified";
  Check(A.CopyPolicy(selected, names, count) & (names[0] = "reader@200::2"), "policy snapshots cannot mutate source configuration");
  names[1] := "other@200::3"; two := A.NewNode(A.whitelist, names, 2);
  small[0] := "unchanged"; count := 7;
  Check(~A.CopyPolicy(two, small, count) & (count = 7) & (small[0] = "unchanged"), "short policy output leaves all results unchanged");
  Check(S.OwnedBy(store, owner) & ~S.OwnedBy(store, "bad"), "checking checkpoint owner binding");
  Heap.GC(FALSE);
  Check(S.GetOwner(restored, "selected", "post-2") # NIL, "rooting restored policy and post graphs");
  S.Close(restored); restored := S.DecodeOwner(data, length, owner);
  Check(restored # NIL, "decoding does not consume or mutate input image");
  Check(S.EncodeOwner(restored, copy, copyLength) & B.Equal(data, length, copy, copyLength), "input remains byte-identical after repeated restoration")
END RoundTrip;

PROCEDURE Patch(at, value: LONGINT);
VAR k: LONGINT;
BEGIN
  FOR k := 3 TO 0 BY -1 DO copy[at+k] := CHR(value MOD 256); value := value DIV 256 END
END Patch;

PROCEDURE Clone;
BEGIN
  NEW(copy, length);
  FOR j := 0 TO length-1 DO copy[j] := data[j] END;
  copyLength := length
END Clone;

PROCEDURE Corruption;
BEGIN
  FOR i := 0 TO length-1 DO
    Check(S.DecodeOwner(data, i, owner) = NIL, "rejecting every truncated snapshot")
  END;
  Clone;
  FOR i := 0 TO length-1 DO
    saved := copy[i]; copy[i] := CHR((ORD(saved)+1) MOD 256);
    Check(S.DecodeOwner(copy, length, owner) = NIL, "rejecting corruption at every snapshot byte");
    copy[i] := saved
  END;
  Check(S.DecodeOwner(NIL, 0, owner) = NIL, "rejecting missing image");
  Check(S.DecodeOwner(data, MAX(LONGINT), owner) = NIL, "bounding image length before access");
  Check(S.DecodeOwner(data, -1, owner) = NIL, "rejecting negative image length");
  Check(S.DecodeOwner(data, length, "bad") = NIL, "requiring expected persistent owner");
  Clone; copy[16] := "0"; Patch(length-4, B.CRC(copy^, length-4));
  Check(S.DecodeOwner(copy, length, owner) = NIL, "rejecting owner substitution with valid checksum");
  Clone; copy[11] := "2"; Patch(length-4, B.CRC(copy^, length-4));
  Check(S.DecodeOwner(copy, length, owner) = NIL, "rejecting unknown snapshot version");
  FOR i := 80 TO 96 BY 4 DO
    Clone; Patch(i, MAX(LONGINT)); Patch(length-4, B.CRC(copy^, length-4));
    Check(S.DecodeOwner(copy, length, owner) = NIL, "bounding all serialized quotas and counts")
  END;
  Clone; Patch(120, A.denied); Patch(length-4, B.CRC(copy^, length-4));
  Check(S.DecodeOwner(copy, length, owner) = NIL, "rejecting invalid serialized audience model");
  Clone; Patch(124, MAX(LONGINT)); Patch(length-4, B.CRC(copy^, length-4));
  Check(S.DecodeOwner(copy, length, owner) = NIL, "bounding serialized policy members");
  Clone; copy[104] := 0X; Patch(length-4, B.CRC(copy^, length-4));
  Check(S.DecodeOwner(copy, length, owner) = NIL, "rejecting embedded NUL in length-prefixed string");
  NEW(copy, length+4);
  FOR j := 0 TO length-5 DO copy[j] := data[j] END;
  Patch(length-4, 0); Patch(length, B.CRC(copy^, length));
  Check(S.DecodeOwner(copy, length+4, owner) = NIL, "rejecting extra fields with valid checksum")
END Corruption;

PROCEDURE Lineage;
BEGIN
  previous := S.DecodeOwner(data, length, owner);
  p := S.GetOwner(store, "public", "post-1"); Check(P.Describe(p, header), "copying persisted revision");
  header.updated := "2026-11-20T00:00:01Z"; q := P.New(header, "Edited after checkpoint");
  Check(S.EditOwner(store, "public", p, q) = S.okay, "editing checkpoint descendant");
  Check(S.ExtendsOwner(previous, store), "allowing newer immutable revision");
  Check(~S.ExtendsOwner(store, previous), "rejecting revision rollback");
  p := S.GetOwner(store, "selected", "post-2");
  Check(S.RetractOwner(store, "selected", "post-2") = S.okay, "retracting checkpoint descendant");
  Check(S.ExtendsOwner(previous, store), "allowing durable retraction");
  Check(~S.ExtendsOwner(store, previous), "rejecting tombstone resurrection");
  empty := S.New(owner, 8, 16, 65536);
  Check(~S.ExtendsOwner(previous, empty), "rejecting silent loss of persisted identities");
  S.Close(empty);
  Check(~S.ExtendsOwner(NIL, store) & ~S.ExtendsOwner(store, NIL), "rejecting missing lineage endpoints")
END Lineage;

PROCEDURE Binary;
VAR values: ARRAY 4 OF LONGINT; k: LONGINT; count: B.Writer;
BEGIN
  text := "123456789";
  Check(B.CRC(text, 9) = -873187034, "standard CRC-32 check vector");
  values[0] := 0; values[1] := -1; values[2] := MIN(LONGINT); values[3] := MAX(LONGINT);
  NEW(synthetic, 64); B.OpenWriter(writer, synthetic, 64);
  FOR k := 0 TO 3 DO B.PutWord(writer, values[k]) END;
  B.PutText(writer, "Հայ 😀"); B.Seal(writer); position := B.Written(writer);
  Check(B.Checked(synthetic, position), "sealing binary codec vector");
  B.OpenReader(binary, synthetic, position-4);
  FOR k := 0 TO 3 DO Check(B.Word(binary) = values[k], "portable signed word encoding") END;
  Check(B.Text(binary, text) & (text = "Հայ 😀") & B.End(binary), "length-prefixed UTF-8 round trip");
  B.OpenWriter(count, NIL, 64);
  FOR k := 0 TO 3 DO B.PutWord(count, values[k]) END;
  B.PutText(count, "Հայ 😀"); B.Seal(count);
  Check(B.Written(count) = position, "counting pass matches binary output");
  B.OpenWriter(count, NIL, 3); B.PutWord(count, 1);
  Check(B.Written(count) < 0, "refusing partial word output");
  B.OpenReader(binary, synthetic, 3); word := B.Word(binary);
  Check(~B.Good(binary), "refusing truncated word input");
  Check(~B.Equal(synthetic, position, synthetic, position+1), "comparing complete snapshot lengths");
  Check(B.Equal(NIL, 0, NIL, 0) & ~B.Equal(NIL, 1, NIL, 1), "distinguishing absent and malformed images")
END Binary;

BEGIN
  FOR i := 0 TO 31 DO key[i] := CHR(i) END;
  RoundTrip; Corruption; Lineage; Binary;
  S.Close(store); S.Close(restored); S.Close(previous);
  Out.String("TestPostSnapshot: "); Out.Int(checks, 0); Out.String(" checks, ");
  Out.Int(failed, 0); Out.String(" failed"); Out.Ln;
  IF failed # 0 THEN HALT(100) END
END TestPostSnapshot.
