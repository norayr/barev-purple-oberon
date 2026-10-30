MODULE TestMarkup;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* XHTML protocol, rendering and queue regressions using checked Oberon only. *)

IMPORT M := BarevMarkup, St := BarevStanzas, B := BarevStream, I := XmppItems,
  S := LongStrings, Heap, Out, Gen := XmppXmlGen, Msg;

VAR checks, firstBad: LONGINT; phase: ARRAY 32 OF CHAR;

PROCEDURE Check(value: BOOLEAN);
BEGIN
  INC(checks);
  IF ~value & (firstBad = 0) THEN
    firstBad := checks; Out.String("Markup check failed in "); Out.String(phase);
    Out.String(": "); Out.Int(checks, 0); Out.Ln
  END
END Check;

PROCEDURE Contains(text, part: ARRAY OF CHAR): BOOLEAN;
  VAR i, j, n: LONGINT;
BEGIN
  n := S.Length8(part);
  FOR i := 0 TO S.Length8(text)-n DO
    j := 0; WHILE (j < n) & (text[i+j] = part[j]) DO INC(j) END;
    IF j = n THEN RETURN TRUE END
  END;
  RETURN FALSE
END Contains;

PROCEDURE Append(VAR text: ARRAY OF CHAR; part: ARRAY OF CHAR);
  VAR i, n, m: LONGINT;
BEGIN
  n := S.Length8(text); m := S.Length8(part); Check(n+m < LEN(text));
  IF n+m >= LEN(text) THEN RETURN END;
  FOR i := 0 TO m DO text[n+i] := part[i] END
END Append;

PROCEDURE Render(fragment: ARRAY OF CHAR; VAR plain, markup: I.Bytes);
  VAR item: I.Item;
BEGIN
  item := M.Parse(fragment); Check(item # NIL);
  IF item # NIL THEN Check(M.Display(item, plain, markup)) END
END Render;

PROCEDURE Filtering;
  VAR plain, markup: I.Bytes; item, legacy: I.Item; input: ARRAY M.maxBytes+2 OF CHAR; i: LONGINT;
BEGIN
  Check(St.maxMarkupBytes = M.maxBytes); Check(St.maxMessageBytes = M.maxPlainBytes);
  Render("<b>բարեւ 😀 &amp; &lt;literal&gt;</b><br/><i>italic</i><u>underline</u>", plain, markup);
  Check(Contains(markup^, "<b>բարեւ 😀 &amp; &lt;literal&gt;</b>")); Check(Contains(markup^, "<i>italic</i>"));
  Check(Contains(plain^, "բարեւ 😀 & <literal>"));
  Render("<span style='color: #FF00aa; background: navy; font-weight: bold; font-style: italic; font-size: 12pt; font-family: DejaVu Sans'>text</span>", plain, markup);
  Check(Contains(markup^, "color: #ff00aa;")); Check(Contains(markup^, "background: navy;"));
  Check(Contains(markup^, "font-family: DejaVu Sans;")); Check(Contains(markup^, "<i>text</i>"));
  Render("<font face='DejaVu Sans' size='4' ABSZ='14' color='#123456' back='yellow'>old</font>", plain, markup);
  Check(Contains(markup^, "font-size: 14pt;")); Check(Contains(markup^, "background: yellow;"));
  Render("<p>one</p><p>two<br/><br/>three</p>", plain, markup);
  Check((S.Length8(plain^) = 15) & (plain[3] = 0AX) & (plain[7] = 0AX) & (plain[8] = 0AX) & (plain[14] = 0AX));
  Render("<a href='HTTPS://example.invalid/a?x=1&amp;y=2' onclick='bad()'>link &lt;b&gt;</a>", plain, markup);
  Check(Contains(markup^, 'href="HTTPS://example.invalid/a?x=1&amp;y=2"')); Check(~Contains(markup^, "onclick"));
  Render("<a href='jav&#97;script:bad()'>one</a><a href='data:text/html,bad'>two</a><a href='file:///etc/passwd'>three</a>", plain, markup);
  Check(~Contains(markup^, "href=")); Check(plain^ = "onetwothree");
  Render("<a href=' https://example.invalid'>space</a><a href='http&#9;://example.invalid'>tab</a><a href='//example.invalid'>relative</a>", plain, markup);
  Check(~Contains(markup^, "href="));
  Render("<a href='mailto:a@example.invalid'>mail</a><a href='xmpp:a@example.invalid'>chat</a>", plain, markup);
  Check(Contains(markup^, "mailto:")); Check(Contains(markup^, "xmpp:"));
  Render("<a href='https://example.invalid/&quot;&lt;img/src=x&gt;'>quoted</a>", plain, markup);
  Check(Contains(markup^, "&quot;&lt;img/src=x&gt;")); Check(~Contains(markup^, "<img"));
  Render("<span style='color: red; background: url(https://example.invalid/a); font-family: url(bad); font-size: 999pt; position: fixed; width: expression(bad); text-decoration: underline' onmouseover='bad()'>safe</span><script>bad()</script><img src='https://example.invalid/a'/><iframe>bad</iframe>", plain, markup);
  Check(plain^ = "safe"); Check(Contains(markup^, "color: red;")); Check(Contains(markup^, "text-decoration: underline;"));
  Check(~Contains(markup^, "url(")); Check(~Contains(markup^, "bad")); Check(~Contains(markup^, "img")); Check(~Contains(markup^, "999"));
  Render("<span xmlns:x='urn:foreign' x:style='color:red' x:onclick='bad'>safe</span><b xmlns='urn:foreign'>foreign</b>", plain, markup);
  Check(plain^ = "safe"); Check(~Contains(markup^, "color"));
  Check(M.Parse("<b>unfinished") = NIL);
  Check(M.Parse("<!DOCTYPE body [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>&x;") = NIL);
  Check(M.Parse("</body><body xmlns='http://www.w3.org/1999/xhtml'>injected") = NIL);
  input := ""; FOR i := 1 TO 13 DO Append(input, "<b>") END; Append(input, "deep");
  FOR i := 1 TO 13 DO Append(input, "</b>") END; Check(M.Parse(input) = NIL);
  input := ""; FOR i := 1 TO 110 DO Append(input, "<b>x</b>") END; Check(M.Parse(input) = NIL);
  FOR i := 0 TO M.maxBytes DO input[i] := "x" END; input[M.maxBytes+1] := 0X; Check(M.Parse(input) = NIL);
  item := St.FormattedMessage("fallback", "<b>formatted</b>"); Check(item # NIL);
  Check(item.First(M.xhtmlURI, "html") # NIL); Check(item.First(M.imURI, "html") # NIL);
  Check(item.content.next.element.namespaceURI^ = M.xhtmlURI);
  legacy := item.First(M.xhtmlURI, "html"); legacy := legacy.First(M.xhtmlURI, "body");
  Check(legacy.First(M.xhtmlURI, "font") # NIL);
  item := St.FormattedMessage("fallback", "<img src='https://example.invalid/a'/>");
  Check(item.First(M.xhtmlURI, "html") = NIL)
END Filtering;

PROCEDURE Feed(handle: LONGINT; text: ARRAY OF CHAR): LONGINT;
  VAR bytes: I.Bytes; at, count, n, i, result: LONGINT; part: ARRAY 4096 OF CHAR;
BEGIN
  bytes := I.Copy8(text); n := S.Length8(text); at := 0; result := B.online;
  WHILE (at < n) & (result >= 0) DO
    count := n-at; IF count > LEN(part) THEN count := LEN(part) END;
    FOR i := 0 TO count-1 DO part[i] := bytes[at+i] END;
    result := B.Feed(handle, part, count); INC(at, count)
  END;
  RETURN result
END Feed;

PROCEDURE Drain(handle: LONGINT);
  VAR bytes: ARRAY 4096 OF CHAR; n: LONGINT;
BEGIN
  n := B.Peek(handle, bytes); WHILE n > 0 DO B.Sent(handle, n); n := B.Peek(handle, bytes) END
END Drain;

PROCEDURE Peer(account, contact: LONGINT): LONGINT;
  VAR handle: LONGINT;
BEGIN
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1"); Check(handle > 0); Drain(handle);
  Check(Feed(handle, "<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client' from='bob@200::2'>") = B.online);
  Drain(handle); RETURN handle
END Peer;

PROCEDURE Streams;
  VAR account, contact, handle, n, i: LONGINT; present: BOOLEAN; item: I.Item; p, m: I.Bytes; error: Msg.Msg;
    jid: ARRAY 384 OF CHAR; plain: ARRAY St.maxMessageBytes+1 OF CHAR; markup: ARRAY M.maxBytes+1 OF CHAR;
    small: ARRAY 2 OF CHAR; bytes: ARRAY 65536 OF CHAR; stanza: ARRAY 32768 OF CHAR;
    link: ARRAY 2048 OF CHAR; ampPlain: ARRAY 186 OF CHAR; ampMarkup: ARRAY 1024 OF CHAR;
BEGIN
  account := B.NewAccount("alice", "200::1"); contact := B.AddContact(account, "bob@200::2");
  Check(B.SendFormattedMessage(account, contact, "queued", "<b>queued 😀</b>") = B.queued);
  handle := Peer(account, contact); (* Peer drains the queued message, so queue another before losing it. *)
  B.Drop(handle); Check(B.SendFormattedMessage(account, contact, "retry", "<i>retry</i>") = B.queued);
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1"); Drain(handle);
  Check(Feed(handle, "<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client' from='bob@200::2'>") = B.online);
  n := B.Peek(handle, bytes); bytes[n] := 0X;
  Check(Contains(bytes, "retry")); Check(Contains(bytes, M.imURI)); Check(Contains(bytes, M.xhtmlURI));
  B.Sent(handle, n-1); B.Lost(handle); Heap.GC(TRUE);
  handle := B.NewConnection(account, contact, FALSE, "200::2", "200::1"); Drain(handle);
  Check(Feed(handle, "<s:stream xmlns:s='http://etherx.jabber.org/streams' xmlns='jabber:client' from='bob@200::2'>") = B.online);
  n := B.Peek(handle, bytes); bytes[n] := 0X; Check(Contains(bytes, "retry")); Check(Contains(bytes, M.imURI)); Drain(handle);
  Check(Feed(handle, "<message><body>fallback</body><html xmlns='http://jabber.org/protocol/xhtml-im'><body xmlns='http://www.w3.org/1999/xhtml'><b>rich 😀</b></body></html></message>") = B.online);
  Check(~B.TakeFormattedMessage(account, jid, plain, small)); Heap.GC(TRUE);
  Check(B.TakeFormattedMessage(account, jid, plain, markup)); Check(plain = "fallback"); Check(Contains(markup, "<b>rich 😀</b>"));
  Check(Feed(handle, "<message><html xmlns='http://www.w3.org/1999/xhtml'><body ichattextcolor='#112233'><font face='DejaVu Sans' ABSZ='14'>legacy &amp; text</font></body></html></message>") = B.online);
  Check(B.TakeFormattedMessage(account, jid, plain, markup)); Check(plain = "legacy & text");
  Check(Contains(markup, "font-size: 14pt;")); Check(Contains(markup, "color: #112233;"));
  Check(Feed(handle, "<message><body>&lt;img src='literal'&gt;</body><html xmlns='http://jabber.org/protocol/xhtml-im'><body xmlns='http://www.w3.org/1999/xhtml'><script>bad</script><img src='https://example.invalid/a'/></body></html></message>") = B.online);
  Check(B.TakeFormattedMessage(account, jid, plain, markup)); Check(markup = ""); Check(plain = "<img src='literal'>");
  Check(Feed(handle, "<message><body>plain</body><html xmlns='urn:foreign'><body><b>foreign</b></body></html></message>") = B.online);
  Check(B.TakeFormattedMessage(account, jid, plain, markup)); Check((markup = "") & (plain = "plain"));
  Check(Feed(handle, "<message><body>plain</body><html xmlns='http://www.w3.org/1999/xhtml'><body><b>one</b></body></html><html xmlns='http://www.w3.org/1999/xhtml'><body><b>two</b></body></html></message>") = B.online);
  Check(B.TakeFormattedMessage(account, jid, plain, markup)); Check(markup = "");
  item := St.FormattedMessage("plain", "<u>standard priority</u>");
  Check(St.ReadFormattedMessage(item, present, p, m)); Check(present & Contains(m^, "standard priority"));
  phase := "dual representation roundtrip";
  stanza := ""; FOR i := 1 TO 95 DO Append(stanza, "<b>x</b>") END;
  item := St.FormattedMessage("many", stanza); Check(item.First(M.imURI, "html") # NIL);
  Gen.Encode(item, B.maxStanzaBytes, p, n, error); Check(error = NIL);
  Check(M.WireFits(p^));
  Check(Feed(handle, p^) = B.online); Check(B.TakeFormattedMessage(account, jid, plain, markup));
  Check((plain = "many") & Contains(markup, "<b>x</b>"));
  phase := "escaped text wire budget";
  ampMarkup := "<b>";
  FOR i := 0 TO 184 DO ampPlain[i] := "&"; Append(ampMarkup, "&amp;") END; ampPlain[185] := 0X;
  Append(ampMarkup, "</b>"); item := St.FormattedMessage(ampPlain, ampMarkup);
  Check(item.First(M.imURI, "html") # NIL); Gen.Encode(item, B.maxStanzaBytes, p, n, error); Check(error = NIL);
  Check(~M.WireFits(p^));
  Check(B.SendFormattedMessage(account, contact, ampPlain, ampMarkup) = B.online);
  n := B.Peek(handle, bytes); bytes[n] := 0X;
  Check(Contains(bytes, "&amp;")); Check(~Contains(bytes, M.imURI)); Check(M.WireFits(bytes)); Drain(handle);
  phase := "rich queue budget";
  link := "<a href='https://example.invalid/"; n := S.Length8(link);
  FOR i := n TO n+1799 DO link[i] := "a" END; link[n+1800] := 0X; Append(link, "'>x</a>");
  stanza := "<message><body>small</body><html xmlns='http://jabber.org/protocol/xhtml-im'><body xmlns='http://www.w3.org/1999/xhtml'>";
  FOR i := 1 TO 15 DO Append(stanza, link) END;
  Append(stanza, "</body></html></message>");
  Check(Feed(handle, stanza) = B.online); Check(Feed(handle, stanza) = B.online); Check(Feed(handle, stanza) = B.failed);
  B.RemoveContact(account, contact); contact := B.AddContact(account, "bob@200::2"); handle := Peer(account, contact);
  Check(Feed(handle, "<message><body>after cleanup</body></message>") = B.online);
  Check(B.TakeFormattedMessage(account, jid, plain, markup)); Check((plain = "after cleanup") & (markup = ""));
  B.FreeAccount(account)
END Streams;

PROCEDURE Run*(): LONGINT;
BEGIN
  checks := 0; firstBad := 0; phase := "filtering"; Filtering; phase := "streams"; Streams;
  IF firstBad # 0 THEN RETURN -firstBad END;
  RETURN checks
END Run;

END TestMarkup.
