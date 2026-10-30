MODULE BarevStanzas;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Presence and bounded plain/XHTML messages for identified peer streams. *)

IMPORT LS := LongStrings, T := XmppTypes, Items := XmppItems, M := BarevMarkup;

CONST
  clientURI* = "jabber:client";
  offline* = 0; available* = 1; away* = 2; dnd* = 3; extendedAway* = 4; chat* = 5;
  maxStatusBytes* = 1024; maxMessageBytes* = 8192;
  maxMarkupBytes* = 32768;
  chatstatesURI* = "http://jabber.org/protocol/chatstates";
  stopped* = 0; composing* = 1; paused* = 2; typingSeconds* = 15; typingRefresh* = 5;

PROCEDURE Text*(bytes: ARRAY OF CHAR; maximum: LONGINT): T.String;
  VAR length, index, code: LONGINT; text: T.String;
BEGIN
  length := 0;
  WHILE (length < LEN(bytes)) & (bytes[length] # 0X) DO INC(length) END;
  IF (length = LEN(bytes)) OR (length > maximum) THEN RETURN NIL END;
  text := Items.UTF8(bytes); IF text = NIL THEN RETURN NIL END;
  index := 0;
  WHILE text[index] # 0 DO
    code := text[index];
    IF ((code < 32) & (code # 9) & (code # 10) & (code # 13)) OR
       (code = 0FFFEH) OR (code = 0FFFFH) THEN RETURN NIL END;
    INC(index)
  END;
  RETURN text
END Text;

PROCEDURE Add(item: Items.Item; name: ARRAY OF CHAR; text: T.String);
  VAR child: Items.Item;
BEGIN
  child := Items.New(name, clientURI); child.AddText(text^, 0, LS.Length(text^)); item.AddChild(child)
END Add;

PROCEDURE Presence*(mode: LONGINT; message: ARRAY OF CHAR): Items.Item;
  VAR item: Items.Item; text, show: T.String;
BEGIN
  IF (mode < offline) OR (mode > chat) THEN RETURN NIL END;
  text := Text(message, maxStatusBytes); IF text = NIL THEN RETURN NIL END;
  item := Items.New("presence", clientURI);
  CASE mode OF
  | offline: show := Items.Latin1("unavailable"); item.SetParam("type", show^)
  | away: show := Items.Latin1("away"); Add(item, "show", show)
  | dnd: show := Items.Latin1("dnd"); Add(item, "show", show)
  | extendedAway: show := Items.Latin1("xa"); Add(item, "show", show)
  | chat: show := Items.Latin1("chat"); Add(item, "show", show)
  | available:
  END;
  IF text[0] # 0 THEN Add(item, "status", text) END;
  RETURN item
END Presence;

PROCEDURE Message*(body: ARRAY OF CHAR): Items.Item;
  VAR item: Items.Item; text, kind: T.String;
BEGIN
  text := Text(body, maxMessageBytes); IF (text = NIL) OR (text[0] = 0) THEN RETURN NIL END;
  item := Items.New("message", clientURI); kind := Items.Latin1("chat"); item.SetParam("type", kind^);
  Add(item, "body", text); RETURN item
END Message;

PROCEDURE FormattedMessage*(body, fragment: ARRAY OF CHAR): Items.Item;
  VAR item, rich, legacy, standard: Items.Item; plain, display: Items.Bytes;
BEGIN
  item := Message(body); IF item = NIL THEN RETURN NIL END;
  rich := M.Parse(fragment);
  IF (rich = NIL) OR ~M.Formatted(rich) OR ~M.Display(rich, plain, display) THEN RETURN item END;
  legacy := M.Wire(rich, TRUE); standard := M.Wire(rich, FALSE);
  IF (legacy = NIL) OR (standard = NIL) THEN RETURN item END;
  (* C Barev/Bonjour selects the first html element by local name. Namespace-
     aware XHTML-IM peers select the standard representation independently. *)
  item.AddChild(legacy); item.AddChild(standard); RETURN item
END FormattedMessage;

PROCEDURE Field(item: Items.Item; name: ARRAY OF CHAR; maximum: LONGINT;
                VAR present: BOOLEAN; VAR value: Items.Bytes): BOOLEAN;
  VAR content, part: Items.Content; text: T.String;
BEGIN
  present := FALSE; value := Items.Copy8(""); content := item.content;
  WHILE content # NIL DO
    IF (content.element # NIL) & (content.element.namespaceURI^ = clientURI) &
       LS.Equal8(content.element.name^, name) THEN
      IF present THEN RETURN FALSE END;
      present := TRUE; part := content.element.content;
      WHILE part # NIL DO IF part.element # NIL THEN RETURN FALSE END; part := part.next END;
      text := content.element.Text(); value := Items.UTF8Bytes(text^);
      IF (value = NIL) OR (LS.Length8(value^) > maximum) THEN RETURN FALSE END
    END;
    content := content.next
  END;
  RETURN TRUE
END Field;

PROCEDURE ReadPresence*(item: Items.Item; VAR mode: LONGINT; VAR message: Items.Bytes): BOOLEAN;
  VAR kind: T.String; show: Items.Bytes; present: BOOLEAN;
BEGIN
  mode := available; kind := item.GetAttribute("", "type");
  IF (kind # NIL) & (kind[0] # 0) THEN
    IF LS.Equal8(kind^, "unavailable") THEN mode := offline ELSE RETURN FALSE END
  END;
  IF ~Field(item, "show", 16, present, show) OR
     ~Field(item, "status", maxStatusBytes, present, message) THEN RETURN FALSE END;
  IF mode # offline THEN
    IF show^ = "away" THEN mode := away
    ELSIF show^ = "dnd" THEN mode := dnd
    ELSIF show^ = "xa" THEN mode := extendedAway
    ELSIF show^ = "chat" THEN mode := chat
    END
  END;
  RETURN TRUE
END ReadPresence;

PROCEDURE ReadMessage*(item: Items.Item; VAR present: BOOLEAN; VAR body: Items.Bytes): BOOLEAN;
BEGIN RETURN Field(item, "body", maxMessageBytes, present, body) END ReadMessage;

PROCEDURE RichBody(item: Items.Item): Items.Item;
  VAR part, child: Items.Content; standard, legacy, body: Items.Item; ns, count, bodies: LONGINT;
BEGIN
  standard := NIL; legacy := NIL; part := item.content; count := 0;
  WHILE part # NIL DO
    IF (part.element # NIL) & LS.Equal8(part.element.name^, "html") THEN
      ns := 0;
      IF part.element.namespaceURI^ = M.imURI THEN ns := 1
      ELSIF part.element.namespaceURI^ = M.xhtmlURI THEN ns := 2
      END;
      IF ns # 0 THEN
        IF ((ns = 1) & ODD(count)) OR ((ns = 2) & (count >= 2)) THEN RETURN NIL END;
        INC(count, ns); child := part.element.content; body := NIL; bodies := 0;
        WHILE child # NIL DO
          IF (child.element # NIL) & (child.element.namespaceURI^ = M.xhtmlURI) & LS.Equal8(child.element.name^, "body") THEN
            body := child.element; INC(bodies)
          END;
          child := child.next
        END;
        IF bodies = 1 THEN IF ns = 1 THEN standard := body ELSE legacy := body END END
      END
    END;
    part := part.next
  END;
  IF standard # NIL THEN RETURN standard END;
  RETURN legacy
END RichBody;

PROCEDURE ReadFormattedMessage*(item: Items.Item; VAR present: BOOLEAN; VAR body, markup: Items.Bytes): BOOLEAN;
  VAR rich: Items.Item; plain: Items.Bytes;
BEGIN
  markup := Items.Copy8("");
  IF ~ReadMessage(item, present, body) THEN RETURN FALSE END;
  rich := RichBody(item);
  IF rich # NIL THEN
    IF M.Display(rich, plain, markup) THEN
      IF ~present THEN body := plain; present := TRUE END
    ELSE markup := Items.Copy8("")
    END
  END;
  RETURN TRUE
END ReadFormattedMessage;

PROCEDURE Typing*(mode: LONGINT): Items.Item;
  VAR item, state: Items.Item; kind: T.String;
BEGIN
  IF (mode < stopped) OR (mode > paused) THEN RETURN NIL END;
  item := Items.New("message", clientURI); kind := Items.Latin1("chat"); item.SetParam("type", kind^);
  IF mode = composing THEN state := Items.New("composing", chatstatesURI)
  ELSE state := Items.New("active", chatstatesURI)
  END;
  item.AddChild(state); RETURN item
END Typing;

PROCEDURE ReadTyping*(item: Items.Item; VAR present: BOOLEAN; VAR mode: LONGINT): BOOLEAN;
  VAR content, part: Items.Content; state: Items.Item;
BEGIN
  present := FALSE; mode := stopped; content := item.content;
  WHILE content # NIL DO
    state := content.element;
    IF (state # NIL) & (state.namespaceURI^ = chatstatesURI) THEN
      IF LS.Equal8(state.name^, "composing") OR LS.Equal8(state.name^, "paused") OR
         LS.Equal8(state.name^, "active") OR LS.Equal8(state.name^, "inactive") OR LS.Equal8(state.name^, "gone") THEN
        IF present THEN RETURN FALSE END;
        present := TRUE; part := state.content;
        WHILE part # NIL DO
          IF (part.element # NIL) OR ((part.text # NIL) & (part.text[0] # 0)) THEN RETURN FALSE END;
          part := part.next
        END;
        IF LS.Equal8(state.name^, "composing") THEN mode := composing
        ELSIF LS.Equal8(state.name^, "paused") THEN mode := paused
        END
      END
    END;
    content := content.next
  END;
  RETURN TRUE
END ReadTyping;

END BarevStanzas.
