MODULE BarevMarkup;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Bounded XHTML trees shared by the wire encoder and the libpurple renderer.
   Rebuild supported markup from namespace-aware items before displaying it. *)

IMPORT I := XmppItems, S := LongStrings, T := XmppTypes, XML := XmppXmlStream;

CONST
  xhtmlURI* = "http://www.w3.org/1999/xhtml";
  imURI* = "http://jabber.org/protocol/xhtml-im";
  maxBytes* = 32768; maxPlainBytes* = 8192;
  maxDepth = 12; maxTree = 200;

TYPE Buffer = RECORD data: I.Bytes; length, maximum: LONGINT; okay: BOOLEAN END;

PROCEDURE Init(VAR b: Buffer; maximum: LONGINT);
BEGIN NEW(b.data, maximum+1); b.length := 0; b.maximum := maximum; b.okay := TRUE END Init;

PROCEDURE Put(VAR b: Buffer; text: ARRAY OF CHAR);
  VAR i, n: LONGINT;
BEGIN
  n := S.Length8(text);
  IF ~b.okay OR (n > b.maximum-b.length) THEN b.okay := FALSE; RETURN END;
  FOR i := 0 TO n-1 DO b.data[b.length+i] := text[i] END;
  INC(b.length, n); b.data[b.length] := 0X
END Put;

PROCEDURE Byte(VAR b: Buffer; ch: CHAR);
BEGIN
  IF ~b.okay OR (b.length = b.maximum) THEN b.okay := FALSE; RETURN END;
  b.data[b.length] := ch; INC(b.length); b.data[b.length] := 0X
END Byte;

PROCEDURE Position(part, text: ARRAY OF CHAR; start: LONGINT): LONGINT;
  VAR i, j, n, m: LONGINT;
BEGIN
  n := S.Length8(text); m := S.Length8(part);
  FOR i := start TO n-m DO
    j := 0; WHILE (j < m) & (part[j] = text[i+j]) DO INC(j) END;
    IF j = m THEN RETURN i END
  END;
  RETURN -1
END Position;

PROCEDURE Escape(VAR b: Buffer; text: T.String);
  VAR bytes: I.Bytes; i: LONGINT; ch: ARRAY 2 OF CHAR;
BEGIN
  bytes := I.UTF8Bytes(text^); IF bytes = NIL THEN b.okay := FALSE; RETURN END;
  ch[1] := 0X;
  FOR i := 0 TO S.Length8(bytes^)-1 DO
    CASE bytes[i] OF
    | "&": Put(b, "&amp;")
    | "<": Put(b, "&lt;")
    | ">": Put(b, "&gt;")
    | 22X: Put(b, "&quot;")
    | 27X: Put(b, "&apos;")
    ELSE ch[0] := bytes[i]; Put(b, ch)
    END
  END
END Escape;

PROCEDURE Lower(VAR text: ARRAY OF CHAR);
  VAR i: LONGINT;
BEGIN
  FOR i := 0 TO S.Length8(text)-1 DO
    IF (text[i] >= "A") & (text[i] <= "Z") THEN text[i] := CHR(ORD(text[i])+32) END
  END
END Lower;

PROCEDURE Attribute(item: I.Item; name: ARRAY OF CHAR; VAR value: ARRAY OF CHAR): BOOLEAN;
  VAR text: T.String; bytes: I.Bytes;
BEGIN
  value[0] := 0X; text := item.GetAttribute("", name); IF text = NIL THEN RETURN FALSE END;
  bytes := I.UTF8Bytes(text^);
  IF (bytes = NIL) OR (S.Length8(bytes^) >= LEN(value)) THEN RETURN FALSE END;
  COPY(bytes^, value); RETURN TRUE
END Attribute;

PROCEDURE Word(value: ARRAY OF CHAR): BOOLEAN;
  VAR i, n: LONGINT;
BEGIN
  n := S.Length8(value); IF (n = 0) OR (n > 32) THEN RETURN FALSE END;
  FOR i := 0 TO n-1 DO IF (value[i] < "a") OR (value[i] > "z") THEN RETURN FALSE END END;
  RETURN TRUE
END Word;

PROCEDURE Color(value: ARRAY OF CHAR): BOOLEAN;
  VAR i, n: LONGINT;
BEGIN
  n := S.Length8(value);
  IF (n > 0) & (value[0] = "#") THEN
    IF (n # 4) & (n # 7) THEN RETURN FALSE END;
    FOR i := 1 TO n-1 DO
      IF ~(((value[i] >= "0") & (value[i] <= "9")) OR ((value[i] >= "a") & (value[i] <= "f"))) THEN RETURN FALSE END
    END;
    RETURN TRUE
  END;
  RETURN Word(value)
END Color;

PROCEDURE Font(value: ARRAY OF CHAR): BOOLEAN;
  VAR i, n: LONGINT; c: CHAR;
BEGIN
  n := S.Length8(value); IF (n = 0) OR (n > 128) THEN RETURN FALSE END;
  FOR i := 0 TO n-1 DO
    c := value[i];
    IF ~(((c >= "a") & (c <= "z")) OR ((c >= "A") & (c <= "Z")) OR
         ((c >= "0") & (c <= "9")) OR (c >= 80X) OR (c = " ") OR (c = "-") OR (c = "_") OR (c = ",")) THEN RETURN FALSE END
  END;
  RETURN TRUE
END Font;

PROCEDURE Size(value: ARRAY OF CHAR): BOOLEAN;
  VAR i, j, n: LONGINT; unit: ARRAY 8 OF CHAR;
BEGIN
  IF (value = "xx-small") OR (value = "x-small") OR (value = "small") OR (value = "medium") OR
     (value = "large") OR (value = "x-large") OR (value = "xx-large") THEN RETURN TRUE END;
  i := 0; n := 0;
  WHILE (value[i] >= "0") & (value[i] <= "9") DO
    IF i = 3 THEN RETURN FALSE END;
    n := 10*n+ORD(value[i])-ORD("0"); INC(i)
  END;
  IF (i = 0) OR (S.Length8(value)-i >= LEN(unit)) THEN RETURN FALSE END;
  j := 0;
  WHILE value[i] # 0X DO unit[j] := value[i]; INC(i); INC(j) END;
  unit[j] := 0X;
  RETURN ((unit = "pt") & (n >= 6) & (n <= 72)) OR ((unit = "px") & (n >= 8) & (n <= 96)) OR
         ((unit = "%") & (n >= 50) & (n <= 200))
END Size;

PROCEDURE Declaration(VAR b: Buffer; key, value: ARRAY OF CHAR);
  VAR okay: BOOLEAN; lower: ARRAY 256 OF CHAR; name: ARRAY 32 OF CHAR;
BEGIN
  IF (S.Length8(value) = 0) OR (S.Length8(value) >= LEN(lower)) THEN RETURN END;
  COPY(value, lower); Lower(lower); COPY(key, name); Lower(name); okay := FALSE;
  IF name = "background" THEN COPY("background-color", name) END;
  IF (name = "color") OR (name = "background-color") THEN okay := Color(lower)
  ELSIF name = "font-family" THEN okay := Font(value)
  ELSIF name = "font-size" THEN okay := Size(lower)
  ELSIF name = "font-weight" THEN okay := (lower = "bold") OR (lower = "normal")
  ELSIF name = "font-style" THEN okay := (lower = "italic") OR (lower = "normal")
  ELSIF name = "text-decoration" THEN
    okay := (lower = "underline") OR (lower = "line-through") OR (lower = "none") OR
            (lower = "underline line-through") OR (lower = "line-through underline")
  ELSIF name = "text-align" THEN okay := (lower = "left") OR (lower = "right") OR (lower = "center") OR (lower = "justify")
  ELSIF name = "vertical-align" THEN okay := (lower = "sub") OR (lower = "super") OR (lower = "baseline")
  END;
  IF okay THEN
    Put(b, name); Put(b, ": ");
    IF name = "font-family" THEN Put(b, value) ELSE Put(b, lower) END;
    Put(b, "; ")
  END
END Declaration;

PROCEDURE Trim(text: ARRAY OF CHAR; start, end: LONGINT; VAR part: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  WHILE (start < end) & (text[start] <= " ") DO INC(start) END;
  WHILE (end > start) & (text[end-1] <= " ") DO DEC(end) END;
  IF end-start >= LEN(part) THEN RETURN FALSE END;
  FOR i := start TO end-1 DO part[i-start] := text[i] END;
  part[end-start] := 0X; RETURN TRUE
END Trim;

PROCEDURE Style(item: I.Item): I.Bytes;
  VAR b: Buffer; raw: ARRAY 1025 OF CHAR; key: ARRAY 32 OF CHAR; value: ARRAY 256 OF CHAR;
    start, colon, end, n: LONGINT;
BEGIN
  Init(b, 1024);
  IF Attribute(item, "style", raw) THEN
    start := 0; n := S.Length8(raw);
    WHILE start < n DO
      end := start; WHILE (end < n) & (raw[end] # ";") DO INC(end) END;
      colon := start; WHILE (colon < end) & (raw[colon] # ":") DO INC(colon) END;
      IF (colon < end) & Trim(raw, start, colon, key) & Trim(raw, colon+1, end, value) THEN Declaration(b, key, value) END;
      start := end+1
    END
  END;
  IF S.Equal8(item.name^, "font") THEN
    IF Attribute(item, "face", value) THEN Declaration(b, "font-family", value) END;
    IF Attribute(item, "color", value) THEN Declaration(b, "color", value) END;
    IF Attribute(item, "back", value) THEN Declaration(b, "background-color", value) END;
    IF Attribute(item, "size", value) THEN
      IF value = "1" THEN Declaration(b, "font-size", "xx-small")
      ELSIF value = "2" THEN Declaration(b, "font-size", "small")
      ELSIF value = "3" THEN Declaration(b, "font-size", "medium")
      ELSIF value = "4" THEN Declaration(b, "font-size", "large")
      ELSIF value = "5" THEN Declaration(b, "font-size", "x-large")
      ELSIF (value = "6") OR (value = "7") THEN Declaration(b, "font-size", "xx-large")
      END
    END;
    IF Attribute(item, "ABSZ", value) & (S.Length8(value) <= 2) THEN
      n := S.Length8(value); value[n] := "p"; value[n+1] := "t"; value[n+2] := 0X;
      Declaration(b, "font-size", value)
    END
  END;
  IF S.Equal8(item.name^, "body") THEN
    IF Attribute(item, "ichattextcolor", value) THEN Declaration(b, "color", value) END;
    IF Attribute(item, "ichatballooncolor", value) THEN Declaration(b, "background-color", value) END
  END;
  IF ~b.okay OR (b.length = 0) THEN RETURN NIL END;
  RETURN b.data
END Style;

PROCEDURE Link(value: ARRAY OF CHAR): BOOLEAN;
  VAR i, n: LONGINT; scheme: ARRAY 9 OF CHAR;
BEGIN
  n := S.Length8(value); IF (n = 0) OR (n > 2048) THEN RETURN FALSE END;
  FOR i := 0 TO n-1 DO
    IF (value[i] <= " ") OR (value[i] = 7FX) OR (value[i] = 5CX) THEN RETURN FALSE END
  END;
  i := 0;
  WHILE (i < n) & (i < LEN(scheme)-1) & (value[i] # ":") DO scheme[i] := value[i]; INC(i) END;
  scheme[i] := 0X; Lower(scheme);
  IF (i = n) OR (value[i] # ":") THEN RETURN FALSE END;
  IF (scheme = "http") OR (scheme = "https") THEN
    RETURN (n > i+3) & (value[i+1] = "/") & (value[i+2] = "/")
  END;
  RETURN ((scheme = "mailto") OR (scheme = "xmpp")) & (n > i+1)
END Link;

PROCEDURE Allowed(name: T.String): BOOLEAN;
BEGIN
  RETURN S.Equal8(name^, "body") OR S.Equal8(name^, "span") OR S.Equal8(name^, "font") OR
    S.Equal8(name^, "b") OR S.Equal8(name^, "strong") OR S.Equal8(name^, "i") OR S.Equal8(name^, "em") OR
    S.Equal8(name^, "u") OR S.Equal8(name^, "s") OR S.Equal8(name^, "strike") OR S.Equal8(name^, "a") OR
    S.Equal8(name^, "br") OR S.Equal8(name^, "p") OR S.Equal8(name^, "div") OR S.Equal8(name^, "pre") OR
    S.Equal8(name^, "code") OR S.Equal8(name^, "blockquote") OR S.Equal8(name^, "ul") OR S.Equal8(name^, "ol") OR
    S.Equal8(name^, "li") OR S.Equal8(name^, "cite") OR S.Equal8(name^, "q") OR S.Equal8(name^, "sub") OR S.Equal8(name^, "sup")
END Allowed;

PROCEDURE Clean(source: I.Item; depth: LONGINT; VAR budget: LONGINT): I.Item;
  VAR item, child: I.Item; content: I.Content; style: I.Bytes; value: ARRAY 2049 OF CHAR; text: T.String;
BEGIN
  IF (source.namespaceURI^ # xhtmlURI) OR ~Allowed(source.name) THEN RETURN NIL END;
  IF (depth > maxDepth) OR (budget <= 0) THEN budget := -1; RETURN NIL END;
  DEC(budget);
  IF S.Equal8(source.name^, "font") THEN item := I.New("span", xhtmlURI)
  ELSE item := I.New16(source.name^, xhtmlURI)
  END;
  style := Style(source);
  IF style # NIL THEN text := I.UTF8(style^); item.SetParam("style", text^); DEC(budget) END;
  IF S.Equal8(source.name^, "a") & Attribute(source, "href", value) & Link(value) THEN
    text := I.UTF8(value); item.SetParam("href", text^); DEC(budget)
  END;
  IF S.Equal8(source.name^, "br") THEN RETURN item END;
  content := source.content;
  WHILE (content # NIL) & (budget >= 0) DO
    IF content.element # NIL THEN
      child := Clean(content.element, depth+1, budget); IF child # NIL THEN item.AddChild(child) END
    ELSIF content.text # NIL THEN
      DEC(budget); item.AddText(content.text^, 0, S.Length(content.text^))
    END;
    content := content.next
  END;
  IF budget < 0 THEN RETURN NIL END;
  RETURN item
END Clean;

PROCEDURE Feed(s: XML.Stream; VAR bytes: ARRAY OF CHAR; VAR item: I.Item; VAR stage: LONGINT;
    namespaceURI, name: ARRAY OF CHAR): BOOLEAN;
  VAR at, used, n: LONGINT; event: SHORTINT;
BEGIN
  at := 0; n := S.Length8(bytes);
  WHILE at < n DO
    event := s.Feed(bytes, at, n-at, used); INC(at, used);
    IF event = XML.opened THEN IF stage # 0 THEN RETURN FALSE END; stage := 1
    ELSIF event = XML.stanza THEN
      IF (stage # 1) OR (s.item = NIL) OR (s.item.namespaceURI^ # namespaceURI) OR ~S.Equal8(s.item.name^, name) THEN RETURN FALSE END;
      item := s.item; stage := 2
    ELSIF event = XML.closed THEN IF stage # 2 THEN RETURN FALSE END; stage := 3
    ELSIF event = XML.failed THEN RETURN FALSE
    END;
    IF used = 0 THEN RETURN FALSE END
  END;
  RETURN TRUE
END Feed;

PROCEDURE Parse*(fragment: ARRAY OF CHAR): I.Item;
  VAR s: XML.Stream; source, item: I.Item; bytes: I.Bytes; part: ARRAY 192 OF CHAR; stage, budget, n: LONGINT;
BEGIN
  n := 0; WHILE (n < LEN(fragment)) & (n <= maxBytes) & (fragment[n] # 0X) DO INC(n) END;
  IF (n = 0) OR (n = LEN(fragment)) OR (n > maxBytes) THEN RETURN NIL END;
  s := XML.NewLimited(1024, maxBytes+1024, 24, 512); stage := 0; source := NIL;
  part := "<s:stream xmlns:s='http://etherx.jabber.org/streams'><body xmlns='http://www.w3.org/1999/xhtml'>";
  IF ~Feed(s, part, source, stage, xhtmlURI, "body") THEN RETURN NIL END;
  bytes := I.Copy8(fragment); IF ~Feed(s, bytes^, source, stage, xhtmlURI, "body") THEN RETURN NIL END;
  part := "</body></s:stream>";
  IF ~Feed(s, part, source, stage, xhtmlURI, "body") OR (stage # 3) OR ~s.Finish() THEN RETURN NIL END;
  budget := maxTree; item := Clean(source, 1, budget); RETURN item
END Parse;

PROCEDURE WireFits*(VAR bytes: ARRAY OF CHAR): BOOLEAN;
  VAR s: XML.Stream; item: I.Item; part: ARRAY 128 OF CHAR; stage: LONGINT;
BEGIN
  (* Check the combined fallback and two rich bodies against the receiving
     stream's limits, including text nodes created by escaped characters. *)
  s := XML.NewLimited(1024, 131072, 24, 512); stage := 0; item := NIL;
  part := "<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client'>";
  IF ~Feed(s, part, item, stage, "jabber:client", "message") OR
     ~Feed(s, bytes, item, stage, "jabber:client", "message") THEN RETURN FALSE END;
  part := "</s:stream>";
  RETURN Feed(s, part, item, stage, "jabber:client", "message") & (stage = 3) & s.Finish()
END WireFits;

PROCEDURE Copy*(source: I.Item): I.Item;
  VAR budget: LONGINT;
BEGIN budget := maxTree; RETURN Clean(source, 1, budget) END Copy;

PROCEDURE Formatted*(item: I.Item): BOOLEAN;
  VAR part: I.Content;
BEGIN
  IF item.attributes # NIL THEN RETURN TRUE END;
  part := item.content;
  WHILE part # NIL DO IF part.element # NIL THEN RETURN TRUE END; part := part.next END;
  RETURN FALSE
END Formatted;

PROCEDURE UIStyle(value: T.String): T.String;
  VAR style: I.Bytes; ui: Buffer; i, n: LONGINT;
BEGIN
  (* Pidgin 2's renderer accepts background rather than background-color. *)
  style := I.UTF8Bytes(value^); IF style = NIL THEN RETURN NIL END;
  Init(ui, 2048); i := 0; n := S.Length8(style^);
  WHILE i < n DO
    IF (style[i] = "b") & (Position("background-color:", style^, i) = i) THEN
      Put(ui, "background:"); INC(i, 17)
    ELSE Byte(ui, style[i]); INC(i)
    END
  END;
  IF ~ui.okay THEN RETURN NIL END;
  RETURN I.UTF8(ui.data^)
END UIStyle;

PROCEDURE LegacyStyles(item: I.Item): BOOLEAN;
  VAR attr: I.Attribute; part: I.Content; value: T.String;
BEGIN
  attr := item.attributes;
  WHILE attr # NIL DO
    IF S.Equal8(attr.name^, "style") THEN
      value := UIStyle(attr.value); IF value = NIL THEN RETURN FALSE END;
      item.SetAttribute(attr.name^, "", value^)
    END;
    attr := attr.next
  END;
  part := item.content;
  WHILE part # NIL DO
    IF (part.element # NIL) & ~LegacyStyles(part.element) THEN RETURN FALSE END;
    part := part.next
  END;
  RETURN TRUE
END LegacyStyles;

PROCEDURE Wire*(source: I.Item; legacy: BOOLEAN): I.Item;
  VAR html, body, font, child: I.Item; part: I.Content; attr: I.Attribute;
BEGIN
  body := Copy(source); IF body = NIL THEN RETURN NIL END;
  IF ~legacy THEN html := I.New("html", imURI); html.AddChild(body); RETURN html END;
  html := I.New("html", xhtmlURI); font := I.New("font", xhtmlURI); attr := body.attributes;
  WHILE attr # NIL DO font.SetAttribute(attr.name^, "", attr.value^); attr := attr.next END;
  part := body.content;
  WHILE part # NIL DO
    IF part.element # NIL THEN child := Copy(part.element); IF child = NIL THEN RETURN NIL END; font.AddChild(child)
    ELSE font.AddText(part.text^, 0, S.Length(part.text^))
    END;
    part := part.next
  END;
  body := I.New("body", xhtmlURI); body.AddChild(font); html.AddChild(body);
  IF ~LegacyStyles(html) THEN RETURN NIL END;
  RETURN html
END Wire;

PROCEDURE Plain(item: I.Item; VAR b: Buffer);
  VAR part: I.Content; block: BOOLEAN; bytes: I.Bytes;
BEGIN
  block := S.Equal8(item.name^, "p") OR S.Equal8(item.name^, "div") OR S.Equal8(item.name^, "li") OR S.Equal8(item.name^, "blockquote");
  IF S.Equal8(item.name^, "br") THEN Byte(b, 0AX)
  ELSIF block & (b.length > 0) & (b.data[b.length-1] # 0AX) THEN Byte(b, 0AX)
  END;
  part := item.content;
  WHILE part # NIL DO
    IF part.element # NIL THEN Plain(part.element, b)
    ELSE bytes := I.UTF8Bytes(part.text^); IF bytes = NIL THEN b.okay := FALSE ELSE Put(b, bytes^) END
    END;
    part := part.next
  END;
  IF block & (b.length > 0) & (b.data[b.length-1] # 0AX) THEN Byte(b, 0AX) END
END Plain;

PROCEDURE Render(item: I.Item; VAR b: Buffer);
  VAR part: I.Content; attr: I.Attribute; name: T.String; style, value: I.Bytes;
    text: T.String; italic: BOOLEAN;
BEGIN
  IF S.Equal8(item.name^, "body") THEN name := I.Latin1("span") ELSE name := item.name END;
  Put(b, "<"); value := I.UTF8Bytes(name^); Put(b, value^); attr := item.attributes; italic := FALSE;
  WHILE attr # NIL DO
    Put(b, " "); value := I.UTF8Bytes(attr.name^); Put(b, value^); Put(b, '="');
    IF S.Equal8(attr.name^, "style") THEN
      style := I.UTF8Bytes(attr.value^);
      italic := Position("font-style: italic;", style^, 0) >= 0;
      text := UIStyle(attr.value); IF text = NIL THEN b.okay := FALSE; RETURN END;
      Escape(b, text)
    ELSE Escape(b, attr.value)
    END;
    Put(b, '"'); attr := attr.next
  END;
  IF S.Equal8(item.name^, "br") THEN Put(b, "/>"); RETURN END;
  Put(b, ">"); IF italic THEN Put(b, "<i>") END;
  part := item.content;
  WHILE part # NIL DO
    IF part.element # NIL THEN Render(part.element, b) ELSE Escape(b, part.text) END;
    part := part.next
  END;
  IF italic THEN Put(b, "</i>") END;
  Put(b, "</"); value := I.UTF8Bytes(name^); Put(b, value^); Put(b, ">")
END Render;

PROCEDURE Display*(source: I.Item; VAR plain, markup: I.Bytes): BOOLEAN;
  VAR item: I.Item; p, m: Buffer;
BEGIN
  plain := NIL; markup := NIL; item := Copy(source); IF item = NIL THEN RETURN FALSE END;
  Init(p, maxPlainBytes); Plain(item, p);
  IF ~p.okay OR (p.length = 0) THEN RETURN FALSE END;
  Init(m, maxBytes); Render(item, m); IF ~m.okay THEN RETURN FALSE END;
  plain := p.data; markup := m.data; RETURN TRUE
END Display;

END BarevMarkup.
