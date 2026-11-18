MODULE BarevAuth;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* STARTTLS and SASL EXTERNAL sequencing for an already selected, pinned contact. *)
IMPORT I := XmppItems, S := LongStrings, T := XmppTypes;

CONST
  none* = 0; tlsFeatures* = 1; startTLS* = 2; proceed* = 3; beginTLS* = 4;
  restartTLS* = 5; externalFeatures* = 6; external* = 7; success* = 8;
  restartSASL* = 9; finalFeatures* = 10; ready* = 11; failed* = -1;
  initial = 0; wantTLSFeatures = 1; wantStartTLS = 2; wantProceed = 3;
  sendingProceed = 4; handshake = 5; tlsHeaders = 6; wantExternalFeatures = 7;
  wantExternal = 8; wantSuccess = 9; sendingSuccess = 10; finalHeaders = 11;
  wantFinalFeatures = 12; sendingFinalFeatures = 13; authenticated = 14; dead = 15;
  streamsURI = "http://etherx.jabber.org/streams";
  tlsURI = "urn:ietf:params:xml:ns:xmpp-tls"; saslURI = "urn:ietf:params:xml:ns:xmpp-sasl";

TYPE State* = RECORD phase, output: LONGINT; server: BOOLEAN END;

PROCEDURE Init*(VAR s: State; server: BOOLEAN);
BEGIN s.phase := initial; s.output := none; s.server := server END Init;

PROCEDURE Fail*(VAR s: State): LONGINT;
BEGIN s.phase := dead; s.output := none; RETURN failed END Fail;

PROCEDURE Send(VAR s: State; action, phase: LONGINT): LONGINT;
BEGIN s.phase := phase; s.output := action; RETURN action END Send;

PROCEDURE Opened*(VAR s: State): LONGINT;
BEGIN
  IF s.output # none THEN RETURN Fail(s) END;
  IF s.phase = initial THEN
    IF s.server THEN RETURN Send(s, tlsFeatures, wantStartTLS) END;
    s.phase := wantTLSFeatures
  ELSIF s.phase = tlsHeaders THEN
    IF s.server THEN RETURN Send(s, externalFeatures, wantExternal) END;
    s.phase := wantExternalFeatures
  ELSIF s.phase = finalHeaders THEN
    IF s.server THEN RETURN Send(s, finalFeatures, sendingFinalFeatures) END;
    s.phase := wantFinalFeatures
  ELSE RETURN Fail(s)
  END;
  RETURN none
END Opened;

PROCEDURE Sent*(VAR s: State): LONGINT;
BEGIN
  IF s.output = none THEN RETURN Fail(s) END;
  s.output := none;
  IF s.phase = sendingProceed THEN s.phase := handshake; RETURN beginTLS END;
  IF s.phase = sendingSuccess THEN s.phase := finalHeaders; RETURN restartSASL END;
  IF s.phase = sendingFinalFeatures THEN s.phase := authenticated; RETURN ready END;
  RETURN none
END Sent;

PROCEDURE Secured*(VAR s: State; verified: BOOLEAN): LONGINT;
BEGIN
  IF (s.phase # handshake) OR ~verified THEN RETURN Fail(s) END;
  s.phase := tlsHeaders; RETURN restartTLS
END Secured;

PROCEDURE Is*(item: I.Item; uri, name: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN (item # NIL) & (item.namespaceURI^ = uri) & S.Equal8(item.name^, name) END Is;

PROCEDURE Text(item: I.Item; expected: ARRAY OF CHAR): BOOLEAN;
VAR content: I.Content; value: T.String;
BEGIN
  IF item = NIL THEN RETURN FALSE END;
  content := item.content;
  WHILE content # NIL DO
    IF content.element # NIL THEN RETURN FALSE END;
    content := content.next
  END;
  value := item.Text(); RETURN S.Equal8(value^, expected)
END Text;

PROCEDURE Empty(item: I.Item): BOOLEAN;
BEGIN RETURN (item # NIL) & (item.attributes = NIL) & Text(item, "") END Empty;

PROCEDURE OnlyChild(item: I.Item): I.Item;
VAR content: I.Content; found: I.Item; text: T.String; i: LONGINT;
BEGIN
  IF (item = NIL) OR (item.attributes # NIL) THEN RETURN NIL END;
  content := item.content; found := NIL;
  WHILE content # NIL DO
    IF content.element # NIL THEN
      IF found # NIL THEN RETURN NIL END;
      found := content.element
    ELSIF content.text # NIL THEN
      text := content.text; i := 0;
      WHILE text[i] # 0 DO
        IF (text[i] # 32) & (text[i] # 9) & (text[i] # 10) & (text[i] # 13) THEN RETURN NIL END;
        INC(i)
      END
    END;
    content := content.next
  END;
  RETURN found
END OnlyChild;

PROCEDURE Receive*(VAR s: State; item: I.Item): LONGINT;
VAR child, leaf: I.Item; attr: I.Attribute;
BEGIN
  IF (s.output # none) OR (item = NIL) THEN RETURN Fail(s) END;
  CASE s.phase OF
  | wantTLSFeatures:
      child := OnlyChild(item); leaf := OnlyChild(child);
      IF Is(item, streamsURI, "features") & Is(child, tlsURI, "starttls") & Is(leaf, tlsURI, "required") & Empty(leaf) THEN
        RETURN Send(s, startTLS, wantProceed)
      END
  | wantStartTLS:
      IF Is(item, tlsURI, "starttls") & Empty(item) THEN RETURN Send(s, proceed, sendingProceed) END
  | wantProceed:
      IF Is(item, tlsURI, "proceed") & Empty(item) THEN s.phase := handshake; RETURN beginTLS END
  | wantExternalFeatures:
      child := OnlyChild(item); leaf := OnlyChild(child);
      IF Is(item, streamsURI, "features") & Is(child, saslURI, "mechanisms") & Is(leaf, saslURI, "mechanism") &
         (leaf.attributes = NIL) & Text(leaf, "EXTERNAL") THEN RETURN Send(s, external, wantSuccess) END
  | wantExternal:
      attr := item.attributes;
      IF Is(item, saslURI, "auth") & (attr # NIL) & (attr.next = NIL) & (attr.namespaceURI^ = "") &
         S.Equal8(attr.name^, "mechanism") & S.Equal8(attr.value^, "EXTERNAL") & Text(item, "=") THEN
        RETURN Send(s, success, sendingSuccess)
      END
  | wantSuccess:
      IF Is(item, saslURI, "success") & Empty(item) THEN s.phase := finalHeaders; RETURN restartSASL END
  | wantFinalFeatures:
      IF Is(item, streamsURI, "features") & Empty(item) THEN s.phase := authenticated; RETURN ready END
  ELSE RETURN Fail(s)
  END;
  RETURN Fail(s)
END Receive;

PROCEDURE Output*(VAR s: State; VAR bytes: ARRAY OF CHAR);
BEGIN
  COPY("", bytes);
  CASE s.output OF
  | tlsFeatures: COPY("<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'><required/></starttls></stream:features>", bytes)
  | startTLS: COPY("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>", bytes)
  | proceed: COPY("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>", bytes)
  | externalFeatures: COPY("<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>EXTERNAL</mechanism></mechanisms></stream:features>", bytes)
  | external: COPY("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='EXTERNAL'>=</auth>", bytes)
  | success: COPY("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>", bytes)
  | finalFeatures: COPY("<stream:features/>", bytes)
  ELSE
  END
END Output;

PROCEDURE Ready*(VAR s: State): BOOLEAN;
BEGIN RETURN s.phase = authenticated END Ready;

PROCEDURE Handshaking*(VAR s: State): BOOLEAN;
BEGIN RETURN s.phase = handshake END Handshaking;

PROCEDURE Writing*(VAR s: State): BOOLEAN;
BEGIN RETURN s.output # none END Writing;

END BarevAuth.
