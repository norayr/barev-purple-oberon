MODULE TestPostAtom;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT A := BarevPostAtom, P := BarevPost, I := XmppItems, T := XmppTypes,
  S := LongStrings, Out, Heap, Args;

VAR checks, failed, i, length, exact: LONGINT;
  header: P.Header; post: P.Post;
  entry, child, publish, item, changed: I.Item;
  bytes: I.Bytes; units: T.String;
  text: ARRAY P.maxTextBytes+1 OF CHAR; argument: ARRAY 16 OF CHAR;

PROCEDURE Check(value: BOOLEAN; message: ARRAY OF CHAR);
BEGIN INC(checks); IF ~value THEN INC(failed); Out.String(message); Out.Ln END END Check;

PROCEDURE Value(parent: I.Item; name, expected: ARRAY OF CHAR): BOOLEAN;
VAR child: I.Item; value, wanted: T.String;
BEGIN
  IF parent = NIL THEN RETURN FALSE END;
  child := parent.First(A.atomURI, name); IF child = NIL THEN RETURN FALSE END;
  value := child.Text(); wanted := I.UTF8(expected);
  RETURN (wanted # NIL) & S.Equal(value^, wanted^)
END Value;

PROCEDURE Count(parent: I.Item; uri, name: ARRAY OF CHAR): LONGINT;
VAR content: I.Content; count: LONGINT;
BEGIN
  count := 0; content := parent.content;
  WHILE content # NIL DO
    IF (content.element # NIL) & (content.element.namespaceURI^ = uri) &
        S.Equal8(content.element.name^, name) THEN INC(count) END;
    content := content.next
  END;
  RETURN count
END Count;

PROCEDURE Fixture;
BEGIN
  header.owner := "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
  header.author := "Անի@200::1"; header.itemID := "post-1";
  header.id := "urn:uuid:00000000-0000-4000-8000-000000000001";
  header.replyTo := ""; header.title := "Բարեւ <world> & 😀";
  header.published := "2026-11-20T00:00:00Z"; header.updated := "2026-11-20T00:00:01Z";
  text := "Text <script> & literal entities: &amp;";
  i := S.Length8(text); text[i] := 0DX; text[i+1] := 0AX; text[i+2] := 9X; text[i+3] := "x"; text[i+4] := 0X;
  post := P.New(header, text)
END Fixture;

PROCEDURE Entries;
BEGIN
  Fixture; entry := A.Entry(post);
  Check((entry # NIL) & (entry.namespaceURI^ = A.atomURI) & S.Equal8(entry.name^, "entry"), "standalone Atom entry");
  Check(Value(entry, "id", header.id) & Value(entry, "title", header.title), "required entry identity and title");
  Check(Value(entry, "published", header.published) & Value(entry, "updated", header.updated), "publication and revision timestamps");
  child := entry.First(A.atomURI, "author");
  Check(Value(child, "name", header.author), "standalone entry carries its own author");
  Check(Value(entry, "content", text), "preserving exact text payload before encoding");
  Check(Count(entry, A.atomURI, "content") = 1, "one Atom content element");
  Check(Count(entry, A.atomURI, "author") = 1, "one author person construct");
  child := entry.First(A.atomURI, "content"); units := child.GetAttribute("", "type");
  Check((units # NIL) & S.Equal8(units^, "text"), "explicit plain-text content type");
  child := entry.First(A.atomURI, "title"); units := child.GetAttribute("", "type");
  Check((units # NIL) & S.Equal8(units^, "text"), "explicit plain-text title type");
  Check(entry.First(A.threadURI, "in-reply-to") = NIL, "root posts have no reply element");
  Check(A.Encode(post, A.maxWireBytes, bytes, length), "encoding checked UTF-8 Atom XML");
  exact := length;
  Check((length > 0) & (length < A.maxWireBytes) & (bytes[length] = 0X), "bounded terminated XML output");
  Check(A.Encode(post, exact, bytes, length) & (length = exact), "accepting exact XML budget");
  Check(~A.Encode(post, exact-1, bytes, length) & (bytes = NIL) & (length = 0), "rejecting truncated XML budget atomically");
  Check(~A.Encode(post, 0, bytes, length) & ~A.Encode(post, -1, bytes, length), "rejecting invalid XML budgets");
  Check(~A.Encode(post, MAX(LONGINT), bytes, length), "bounding XML budget before writer invocation");
  Check(~A.Encode(NIL, A.maxWireBytes, bytes, length) & (bytes = NIL) & (length = 0), "rejecting invalid post serialization");
  child := entry.First(A.atomURI, "title"); units := I.Latin1("mutated"); child.AddText(units^, 0, 7);
  changed := A.Entry(post);
  Check(Value(changed, "title", header.title), "fresh XML trees do not mutate stored posts");
  Heap.GC(FALSE);
  Check(Value(changed, "id", header.id), "retaining rooted encoded entry tree");
  header.replyTo := "https://example.org/post/parent?x=1&y=2#context";
  post := P.New(header, text); entry := A.Entry(post);
  child := entry.First(A.threadURI, "in-reply-to");
  Check(child # NIL, "RFC 4685 reply element namespace");
  units := child.GetAttribute("", "ref");
  Check((units # NIL) & S.Equal8(units^, header.replyTo), "preserving parent Atom identifier");
  Check(Count(entry, A.threadURI, "in-reply-to") = 1, "one independent reply relationship");
  Check(A.Encode(post, A.maxWireBytes, bytes, length), "encoding escaped reply reference");
  publish := A.Publish(post, "public");
  Check(publish # NIL, "standard XEP-0060 publish payload");
  child := publish.First("http://jabber.org/protocol/pubsub", "publish");
  units := child.GetAttribute("", "node"); Check(S.Equal8(units^, "public"), "explicit destination node");
  item := child.First("http://jabber.org/protocol/pubsub", "item"); units := item.GetAttribute("", "id");
  Check(S.Equal8(units^, header.itemID), "separate PubSub item identifier");
  Check(Value(item.First(A.atomURI, "entry"), "id", header.id), "retaining Atom ID inside PubSub item");
  Check((A.Publish(post, "") = NIL) & (A.Publish(post, "bad node") = NIL) &
    (A.Publish(NIL, "public") = NIL), "validating publish inputs")
END Entries;

PROCEDURE Bounds;
BEGIN
  Fixture;
  FOR i := 0 TO P.maxTextBytes-1 DO text[i] := "x" END; text[P.maxTextBytes] := 0X;
  post := P.New(header, text);
  Check(A.Encode(post, A.maxWireBytes, bytes, length), "serializing maximum ordinary text content");
  FOR i := 0 TO P.maxTextBytes-1 DO text[i] := "&" END;
  post := P.New(header, text);
  Check(P.Valid(post), "local text quota is independent of XML expansion");
  Check(~A.Encode(post, A.maxWireBytes, bytes, length) & (bytes = NIL) & (length = 0), "bounding escaped XML expansion");
  Check(A.Publish(post, "public") = NIL, "PubSub uses the same payload budget");
  Fixture; header.title := ""; post := P.New(header, text);
  Check(Value(A.Entry(post), "title", ""), "retaining required empty Atom title")
END Bounds;

BEGIN
  Args.Get(1, argument);
  IF argument = "emit" THEN
    Fixture; header.replyTo := "https://example.org/post/parent?x=1&y=2#context";
    post := P.New(header, text);
    IF ~A.Encode(post, A.maxWireBytes, bytes, length) THEN HALT(100) END;
    Out.String(bytes^); Out.Ln
  ELSE
    Entries; Bounds;
    Out.String("TestPostAtom: "); Out.Int(checks, 0); Out.String(" checks, ");
    Out.Int(failed, 0); Out.String(" failed"); Out.Ln;
    IF failed # 0 THEN HALT(100) END
  END
END TestPostAtom.
