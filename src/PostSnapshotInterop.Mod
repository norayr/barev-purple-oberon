MODULE PostSnapshotInterop;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT S := BarevPostStore, P := BarevPost, A := BarevFeedAccess, I := XmppItems,
  F := oocFiles, Channel, Args, Out;

CONST owner = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
VAR action: ARRAY 32 OF CHAR; input, output: ARRAY 4096 OF CHAR;
  store: S.Store; bytes: I.Bytes; length: LONGINT;

PROCEDURE Check(value: BOOLEAN);
BEGIN IF ~value THEN HALT(100) END END Check;

PROCEDURE Add(store: S.Store; item, id, node, body: ARRAY OF CHAR);
VAR header: P.Header; post: P.Post;
BEGIN
  header.owner := owner; header.author := "Անի@0200:0:0:0:0:0:0:1";
  COPY(item, header.itemID); COPY(id, header.id); header.replyTo := ""; header.title := "Բարեւ 😀";
  header.published := "2026-11-20T00:00:00Z"; header.updated := header.published;
  post := P.New(header, body); Check(S.PutOwner(store, node, post) = S.okay)
END Add;

PROCEDURE Fixture(): S.Store;
VAR store: S.Store; names, groups: ARRAY 1 OF A.Name; policy: A.Node;
BEGIN
  store := S.New(owner, 8, 16, 65536); Check(store # NIL);
  policy := A.NewNode(A.open, names, 0); Check(S.AddNodeOwner(store, "public", "Public", policy) = S.okay);
  names[0] := "reader@200::2"; policy := A.NewNode(A.whitelist, names, 1);
  Check(S.AddNodeOwner(store, "selected", "Selected", policy) = S.okay);
  groups[0] := "ընկերներ"; policy := A.NewNode(A.roster, groups, 1);
  Check(S.AddNodeOwner(store, "group", "Group", policy) = S.okay);
  Add(store, "post-1", "urn:post:1", "public", "Public content");
  Add(store, "post-2", "urn:post:2", "selected", "Private content");
  Add(store, "post-3", "urn:post:3", "group", "Group content");
  Add(store, "post-4", "urn:post:4", "public", "Retracted content");
  Check(S.RetractOwner(store, "public", "post-4") = S.okay); RETURN store
END Fixture;

PROCEDURE Load(path: ARRAY OF CHAR; VAR bytes: I.Bytes; VAR length: LONGINT);
VAR file: F.File; reader: Channel.Reader; result: F.Result;
BEGIN
  file := F.Old(path, {F.read}, result); Check(file # NIL); length := file.Length();
  Check((file.res = F.done) & (length >= 0) & (length <= S.maxSnapshotBytes));
  bytes := NIL;
  IF length > 0 THEN
    NEW(bytes, length); reader := file.NewReader(); reader.ReadBytes(bytes^, 0, length); Check(reader.res = F.done)
  END;
  file.Close; Check(file.res = F.done)
END Load;

PROCEDURE Save(path: ARRAY OF CHAR; bytes: I.Bytes; length: LONGINT);
VAR file: F.File; writer: Channel.Writer; result: F.Result;
BEGIN
  file := F.Tmp(path, {F.write}, result); Check(file # NIL);
  writer := file.NewWriter(); writer.WriteBytes(bytes^, 0, length); Check(writer.res = F.done);
  file.Register; Check(file.res = F.done); file.Close; Check(file.res = F.done)
END Save;

BEGIN
  Args.Get(1, action); Args.Get(2, input); Args.Get(3, output);
  IF action = "--write" THEN
    store := Fixture(); Check(S.EncodeOwner(store, bytes, length)); Save(input, bytes, length)
  ELSE
    Load(input, bytes, length); store := S.DecodeOwner(bytes, length, owner);
    IF action = "--check" THEN IF store = NIL THEN Out.Char("1") ELSE Out.Char("0") END; Out.Ln
    ELSE Check(action = "--roundtrip"); Check(store # NIL);
      Check(S.EncodeOwner(store, bytes, length)); Save(output, bytes, length)
    END
  END;
  S.Close(store)
END PostSnapshotInterop.
