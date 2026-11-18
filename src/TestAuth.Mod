MODULE TestAuth;
IMPORT Args, Out, BarevAuth, XML := XmppXmlStream, S := LongStrings;
VAR s: BarevAuth.State; role: ARRAY 16 OF CHAR; command: ARRAY 2048 OF CHAR;
  output: ARRAY 512 OF CHAR; parser: XML.Stream; i: INTEGER; used, result: LONGINT; event: SHORTINT;
  header: ARRAY 128 OF CHAR;

PROCEDURE Flag(value: BOOLEAN);
BEGIN Out.Char(" "); IF value THEN Out.Char("1") ELSE Out.Char("0") END END Flag;

BEGIN
  Args.Get(1, role); BarevAuth.Init(s, role = "server");
  header := "<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>";
  FOR i := 2 TO Args.argc-1 DO
    Args.Get(i, command);
    IF command = "open" THEN result := BarevAuth.Opened(s)
    ELSIF command = "sent" THEN result := BarevAuth.Sent(s)
    ELSIF (command = "secure") OR (command = "bad-tls") THEN result := BarevAuth.Secured(s, command = "secure")
    ELSE
      parser := XML.NewLimited(4096, 4096, 24, 512);
      event := parser.Feed(header, 0, S.Length8(header), used);
      IF event # XML.opened THEN HALT(1) END;
      event := parser.Feed(command, 0, S.Length8(command), used);
      IF event = XML.stanza THEN result := BarevAuth.Receive(s, parser.item) ELSE result := BarevAuth.Fail(s) END
    END;
    Out.Int(result, 0); Flag(BarevAuth.Ready(s)); Flag(BarevAuth.Handshaking(s));
    Flag(BarevAuth.Writing(s)); Out.Char(" ");
    BarevAuth.Output(s, output); Out.String(output); Out.Ln
  END
END TestAuth.
