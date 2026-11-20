MODULE PostFileHost;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT F := BarevPostFiles, S := BarevPostStore, P := BarevPost, A := BarevFeedAccess,
  Args, Out, IntStr, Strings := oocStrings, Platform;

VAR profile, path: ARRAY 4096 OF CHAR; action: ARRAY 32 OF CHAR;
  owner: ARRAY 258 OF CHAR; result, i: LONGINT;
  context, second, savedContext: F.Context;
  store, other, savedStore: S.Store;
  header: P.Header; post: P.Post;
  names: ARRAY 1 OF A.Name; key: ARRAY 32 OF CHAR;
  reader, anonymous: A.Reader; contact: A.Contact;
  policy: A.Node; text: ARRAY P.maxTextBytes+1 OF CHAR;

PROCEDURE Check(value: BOOLEAN);
BEGIN IF ~value THEN HALT(100) END END Check;

PROCEDURE Fresh(): S.Store;
VAR created: S.Store;
BEGIN
  created := S.New(owner, 8, 32, 65536);
  policy := A.NewNode(A.open, names, 0);
  Check(S.AddNodeOwner(created, "public", "Public", policy) = S.okay);
  names[0] := "reader@200::2"; policy := A.NewNode(A.whitelist, names, 1);
  Check(S.AddNodeOwner(created, "selected", "Selected", policy) = S.okay);
  RETURN created
END Fresh;

PROCEDURE Add(created: S.Store; number: LONGINT; node, body, parent: ARRAY OF CHAR);
VAR digits: ARRAY 16 OF CHAR;
BEGIN
  COPY(owner, header.owner); header.author := "Անի@200::1"; header.title := "Title";
  IntStr.IntToStr(number, digits); header.itemID := "post-"; Strings.Append(digits, header.itemID);
  header.id := "urn:post:"; Strings.Append(digits, header.id); COPY(parent, header.replyTo);
  header.published := "2026-11-20T00:00:00Z"; header.updated := header.published;
  post := P.New(header, body); Check(S.PutOwner(created, node, post) = S.okay)
END Add;

PROCEDURE Inspect;
BEGIN
  post := S.GetOwner(store, "public", "post-1");
  Check(P.Content(post, text) & (text = "Բարեւ <world> & 😀"));
  Check(S.GetOwner(store, "public", "post-3") = NIL);
  names[0] := "reader@200::2"; contact := A.NewContact(names[0], key, TRUE, names, 0);
  Check(A.Authenticate(reader, names[0], key, TRUE, TRUE)); A.Anonymous(anonymous);
  Check(S.Get(store, "selected", "post-2", anonymous, contact) = NIL);
  post := S.Get(store, "selected", "post-2", reader, contact);
  Check(P.Content(post, text) & (text = "Private text"));
  post := S.GetOwner(store, "public", "post-4");
  Check(P.Describe(post, header) & (header.replyTo = "urn:post:1"))
END Inspect;

BEGIN
  Args.Get(1, profile); Args.Get(2, action); Args.Get(3, owner);
  IF owner[0] = 0X THEN owner := "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a" END;
  FOR i := 0 TO 31 DO key[i] := CHR(i) END;
  result := F.Load(profile, owner, context, store);
  IF (action = "new") & (result = F.missing) THEN
    store := Fresh();
    Add(store, 1, "public", "Բարեւ <world> & 😀", "");
    Add(store, 2, "selected", "Private text", "");
    Add(store, 3, "public", "Retracted", "");
    Check(S.RetractOwner(store, "public", "post-3") = S.okay);
    Add(store, 4, "public", "Independent reply", "urn:post:1");
    result := F.Save(context, store)
  ELSIF result = F.okay THEN
    IF action = "inspect" THEN Inspect
    ELSIF action = "retry" THEN result := F.Save(context, store)
    ELSIF action = "append" THEN Add(store, 5, "public", "next", ""); result := F.Save(context, store)
    ELSIF action = "two" THEN
      Check(F.Load(profile, owner, second, other) = F.okay);
      Add(store, 5, "public", "writer-a", ""); Add(other, 6, "public", "writer-b", "");
      Check(F.Save(context, store) = F.okay); result := F.Save(second, other)
    ELSIF action = "winner" THEN
      Inspect; post := S.GetOwner(store, "public", "post-5");
      Check(P.Content(post, text) & (text = "writer-a"));
      Check(S.GetOwner(store, "public", "post-6") = NIL)
    ELSIF action = "forget" THEN S.Close(store); store := Fresh(); result := F.Save(context, store)
    ELSIF action = "bad-load" THEN
      savedContext := context; savedStore := store;
      result := F.Load("relative", owner, context, store);
      Check((result = F.invalid) & (context = savedContext) & (store = savedStore))
    ELSIF action = "closed" THEN
      savedContext := context; F.Close(context); result := F.Save(savedContext, store)
    ELSIF action = "delete" THEN
      COPY(profile, path); Strings.Append("/barev/posts-", path); Strings.Append(owner, path); Strings.Append(".state", path);
      Check(Platform.Unlink(path) = 0); result := F.Save(context, store)
    END
  END;
  Out.Int(result, 0); Out.Ln;
  IF store # NIL THEN Out.Int(S.CountOwner(store), 0); Out.Char(" "); Out.Int(S.ReservedOwner(store), 0); Out.Ln END;
  F.Close(context); F.Close(second); S.Close(store); S.Close(other)
END PostFileHost.
