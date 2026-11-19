MODULE BarevPostAtom;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT P := BarevPost, Items := XmppItems, T := XmppTypes, S := LongStrings,
  XML := XmppXmlGen, PubSub := XmppPubSub, Msg;

CONST
  atomURI* = "http://www.w3.org/2005/Atom";
  threadURI* = "http://purl.org/syndication/thread/1.0";
  maxWireBytes* = PubSub.maxPayloadBytes;

PROCEDURE Text(parent: Items.Item; name, text: ARRAY OF CHAR): Items.Item;
VAR child: Items.Item; value: T.String;
BEGIN
  value := Items.UTF8(text); child := Items.New(name, atomURI);
  child.AddText(value^, 0, S.Length(value^)); parent.AddChild(child); RETURN child
END Text;

PROCEDURE Entry*(post: P.Post): Items.Item;
VAR header: P.Header; text: ARRAY P.maxTextBytes+1 OF CHAR;
  entry, child, author: Items.Item; value: T.String;
BEGIN
  IF ~P.Describe(post, header) OR ~P.Content(post, text) THEN RETURN NIL END;
  entry := Items.New("entry", atomURI);
  child := Text(entry, "id", header.id);
  child := Text(entry, "title", header.title); value := Items.Latin1("text"); child.SetParam("type", value^);
  author := Items.New("author", atomURI); child := Text(author, "name", header.author); entry.AddChild(author);
  child := Text(entry, "published", header.published); child := Text(entry, "updated", header.updated);
  child := Text(entry, "content", text); child.SetParam("type", value^);
  IF header.replyTo[0] # 0X THEN
    child := Items.New("in-reply-to", threadURI); value := Items.Latin1(header.replyTo);
    child.SetParam("ref", value^); entry.AddChild(child)
  END;
  RETURN entry
END Entry;

PROCEDURE Encode*(post: P.Post; maximum: LONGINT; VAR bytes: Items.Bytes; VAR length: LONGINT): BOOLEAN;
VAR entry: Items.Item; error: Msg.Msg;
BEGIN
  bytes := NIL; length := 0;
  IF (maximum < 1) OR (maximum > maxWireBytes) THEN RETURN FALSE END;
  entry := Entry(post); IF entry = NIL THEN RETURN FALSE END;
  XML.Encode(entry, maximum, bytes, length, error);
  IF error # NIL THEN bytes := NIL; length := 0; RETURN FALSE END;
  RETURN TRUE
END Encode;

PROCEDURE Publish*(post: P.Post; node: ARRAY OF CHAR): Items.Item;
VAR header: P.Header; entry: Items.Item; name, id: T.String;
BEGIN
  IF ~P.Token(node, P.maxItemBytes) OR ~P.Describe(post, header) THEN RETURN NIL END;
  entry := Entry(post); IF entry = NIL THEN RETURN NIL END;
  name := Items.Latin1(node); id := Items.Latin1(header.itemID);
  RETURN PubSub.BuildPublish(name^, id^, entry)
END Publish;

END BarevPostAtom.
