MODULE BarevAddress;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* IPv6 and locally encoded identities for direct peers on Yggdrasil's 200::/7 network. *)

IMPORT Items := XmppItems, T := XmppTypes;

CONST maxIdentityBytes* = 384;
TYPE IP* = ARRAY 16 OF CHAR;
  Selection* = RECORD chosen: IP; found, ambiguous, explicit, invalid: BOOLEAN END;

PROCEDURE Length(text: ARRAY OF CHAR): LONGINT;
  VAR n: LONGINT;
BEGIN n := 0; WHILE (n < LEN(text)) & (text[n] # 0X) DO INC(n) END; RETURN n END Length;

PROCEDURE Hex(ch: CHAR): LONGINT;
BEGIN
  IF (ch >= "0") & (ch <= "9") THEN RETURN ORD(ch)-ORD("0") END;
  IF (ch >= "a") & (ch <= "f") THEN RETURN ORD(ch)-ORD("a")+10 END;
  IF (ch >= "A") & (ch <= "F") THEN RETURN ORD(ch)-ORD("A")+10 END;
  RETURN -1
END Hex;

PROCEDURE ParseIP*(text: ARRAY OF CHAR; VAR ip: IP): BOOLEAN;
  VAR words: ARRAY 8 OF LONGINT; n, at, count, gap, value, digits, h, index, tail: LONGINT;
BEGIN
  n := Length(text); IF (n < 2) OR (n > 39) OR (n = LEN(text)) THEN RETURN FALSE END;
  at := 0; count := 0; gap := -1;
  IF text[0] = ":" THEN
    IF text[1] # ":" THEN RETURN FALSE END;
    gap := 0; at := 2
  END;
  WHILE at < n DO
    IF count = 8 THEN RETURN FALSE END;
    value := 0; digits := 0;
    WHILE (at < n) & (text[at] # ":") DO
      h := Hex(text[at]); IF (h < 0) OR (digits = 4) THEN RETURN FALSE END;
      value := 16*value+h; INC(digits); INC(at)
    END;
    IF digits = 0 THEN RETURN FALSE END;
    words[count] := value; INC(count);
    IF at < n THEN
      INC(at);
      IF (at < n) & (text[at] = ":") THEN
        IF gap >= 0 THEN RETURN FALSE END;
        gap := count; INC(at)
      ELSIF at = n THEN RETURN FALSE
      END
    END
  END;
  IF gap >= 0 THEN
    IF count >= 8 THEN RETURN FALSE END;
    tail := count-gap;
    FOR index := tail-1 TO 0 BY -1 DO words[7-(tail-1-index)] := words[gap+index] END;
    FOR index := gap TO 7-tail DO words[index] := 0 END
  ELSIF count # 8 THEN RETURN FALSE
  END;
  FOR index := 0 TO 7 DO ip[2*index] := CHR(words[index] DIV 256); ip[2*index+1] := CHR(words[index] MOD 256) END;
  RETURN TRUE
END ParseIP;

PROCEDURE Yggdrasil*(ip: IP): BOOLEAN;
BEGIN RETURN (ip[0] = 2X) OR (ip[0] = 3X) END Yggdrasil;

PROCEDURE Equal*(left, right: IP): BOOLEAN;
  VAR index: LONGINT;
BEGIN FOR index := 0 TO 15 DO IF left[index] # right[index] THEN RETURN FALSE END END; RETURN TRUE END Equal;

PROCEDURE ReadIP*(bytes: ARRAY OF CHAR; VAR ip: IP): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  IF LEN(bytes) # 16 THEN RETURN FALSE END;
  FOR i := 0 TO 15 DO ip[i] := bytes[i] END;
  RETURN TRUE
END ReadIP;

PROCEDURE Port*(port: LONGINT): BOOLEAN;
BEGIN RETURN (port >= 1) & (port <= 65535) END Port;

PROCEDURE BeginSelection*(VAR selection: Selection; configured: ARRAY OF CHAR): BOOLEAN;
BEGIN
  selection.found := FALSE; selection.ambiguous := FALSE; selection.invalid := FALSE;
  selection.explicit := FALSE;
  IF Length(configured) = LEN(configured) THEN selection.invalid := TRUE; RETURN FALSE END;
  selection.explicit := Length(configured) # 0;
  IF selection.explicit THEN
    IF ~ParseIP(configured, selection.chosen) OR ~Yggdrasil(selection.chosen) THEN
      selection.invalid := TRUE; RETURN FALSE
    END;
    selection.found := TRUE
  END;
  RETURN TRUE
END BeginSelection;

PROCEDURE NeedCandidates*(VAR selection: Selection): BOOLEAN;
BEGIN RETURN ~selection.explicit & ~selection.invalid END NeedCandidates;

PROCEDURE Consider*(VAR selection: Selection; bytes: ARRAY OF CHAR; scope: HUGEINT);
  VAR ip: IP;
BEGIN
  IF selection.explicit OR selection.invalid OR (scope # 0) OR ~ReadIP(bytes, ip) OR ~Yggdrasil(ip) THEN RETURN END;
  IF selection.found & ~Equal(selection.chosen, ip) THEN selection.ambiguous := TRUE END;
  selection.chosen := ip; selection.found := TRUE
END Consider;

PROCEDURE Selected*(VAR selection: Selection; VAR ip: IP): BOOLEAN;
BEGIN
  IF ~selection.found OR selection.ambiguous OR selection.invalid THEN RETURN FALSE END;
  ip := selection.chosen; RETURN TRUE
END Selected;

PROCEDURE SocketEndpoints*(local, peer, selected, expected: ARRAY OF CHAR;
    localScope, peerScope: HUGEINT; matchPeer: BOOLEAN): BOOLEAN;
  VAR own, remote, chosen, wanted: IP;
BEGIN
  IF (localScope # 0) OR (peerScope # 0) OR ~ReadIP(local, own) OR ~ReadIP(peer, remote) OR
     ~ReadIP(selected, chosen) OR ~Yggdrasil(own) OR ~Yggdrasil(remote) OR ~Equal(own, chosen) THEN RETURN FALSE END;
  IF matchPeer THEN RETURN ReadIP(expected, wanted) & Equal(remote, wanted) END;
  RETURN TRUE
END SocketEndpoints;

PROCEDURE Format*(ip: IP; VAR text: ARRAY OF CHAR): BOOLEAN;
  VAR index, value, divisor, digit, position, run, bestStart, bestLength: LONGINT;
    hex: ARRAY 17 OF CHAR; started: BOOLEAN;
BEGIN
  IF LEN(text) < 40 THEN RETURN FALSE END;
  hex := "0123456789abcdef"; position := 0;
  bestStart := -1; bestLength := 1; index := 0;
  WHILE index < 8 DO
    run := 0;
    WHILE (index+run < 8) & (ip[2*(index+run)] = 0X) & (ip[2*(index+run)+1] = 0X) DO INC(run) END;
    IF run > bestLength THEN bestStart := index; bestLength := run END;
    IF run = 0 THEN INC(index) ELSE INC(index, run) END
  END;
  index := 0;
  WHILE index < 8 DO
    IF index = bestStart THEN
      text[position] := ":"; text[position+1] := ":"; INC(position, 2); INC(index, bestLength)
    ELSE
      IF (position > 0) & (text[position-1] # ":") THEN text[position] := ":"; INC(position) END;
      value := ORD(ip[2*index])*256+ORD(ip[2*index+1]); divisor := 4096; started := FALSE;
      WHILE divisor > 0 DO
        digit := value DIV divisor; value := value MOD divisor;
        IF started OR (digit # 0) OR (divisor = 1) THEN text[position] := hex[digit]; INC(position); started := TRUE END;
        divisor := divisor DIV 16
      END;
      INC(index)
    END
  END;
  text[position] := 0X; RETURN TRUE
END Format;

PROCEDURE Lower(ch: CHAR): CHAR;
BEGIN
  IF (ch >= "A") & (ch <= "Z") THEN RETURN CHR(ORD(ch)+32) END;
  RETURN ch
END Lower;

PROCEDURE EncodedHost*(ip: IP; VAR text: ARRAY OF CHAR): BOOLEAN;
  VAR alphabet: ARRAY 33 OF CHAR; label: ARRAY 26 OF CHAR; suffix: ARRAY 14 OF CHAR;
    index, bit, value, run, bestStart, bestLength, position: LONGINT;
BEGIN
  IF LEN(text) < 40 THEN RETURN FALSE END;
  alphabet := "abcdefghijklmnopqrstuvwxyz234567"; suffix := ".barev.v6.alt";
  FOR index := 0 TO 25 DO
    value := 0;
    FOR bit := 0 TO 4 DO
      value := value*2;
      IF index*5+bit < 128 THEN
        INC(value, ORD(ip[(index*5+bit) DIV 8]) DIV ASH(1, 7-(index*5+bit) MOD 8) MOD 2)
      END
    END;
    label[index] := alphabet[value]
  END;
  bestStart := -1; bestLength := 1; index := 1;
  WHILE index < 25 DO
    run := 0;
    WHILE (index+run < 25) & (label[index+run] = "a") DO INC(run) END;
    IF run > bestLength THEN bestStart := index; bestLength := run END;
    IF run = 0 THEN INC(index) ELSE INC(index, run) END
  END;
  position := 0; index := 0;
  WHILE index < 26 DO
    IF index = bestStart THEN text[position] := "-"; INC(index, bestLength)
    ELSE text[position] := label[index]; INC(index)
    END;
    INC(position)
  END;
  FOR index := 0 TO 13 DO text[position+index] := suffix[index] END;
  RETURN TRUE
END EncodedHost;

PROCEDURE DecodeHost*(text: ARRAY OF CHAR; VAR ip: IP): BOOLEAN;
  VAR suffix: ARRAY 14 OF CHAR; label: ARRAY 26 OF CHAR;
    n, size, index, hyphen, position, count, value, digit: LONGINT; ch: CHAR;
BEGIN
  n := Length(text); IF (n = LEN(text)) OR (n < 15) OR (n > 40) THEN RETURN FALSE END;
  IF text[n-1] = "." THEN DEC(n) END;
  suffix := ".barev.v6.alt"; size := n-13;
  IF (size < 3) OR (size > 26) THEN RETURN FALSE END;
  FOR index := 0 TO 12 DO IF Lower(text[size+index]) # suffix[index] THEN RETURN FALSE END END;
  hyphen := -1;
  FOR index := 0 TO size-1 DO
    IF text[index] = "-" THEN
      IF (hyphen >= 0) OR (index = 0) OR (index = size-1) OR (size > 25) THEN RETURN FALSE END;
      hyphen := index
    END
  END;
  IF (hyphen < 0) & (size # 26) THEN RETURN FALSE END;
  position := 0;
  FOR index := 0 TO size-1 DO
    IF index = hyphen THEN
      FOR count := 0 TO 26-size DO label[position] := "a"; INC(position) END
    ELSE label[position] := Lower(text[index]); INC(position)
    END
  END;
  value := 0; count := 0; position := 0;
  FOR index := 0 TO 25 DO
    ch := label[index];
    IF (ch >= "a") & (ch <= "z") THEN digit := ORD(ch)-ORD("a")
    ELSIF (ch >= "2") & (ch <= "7") THEN digit := ORD(ch)-ORD("2")+26
    ELSE RETURN FALSE
    END;
    value := value*32+digit; INC(count, 5);
    IF count >= 8 THEN
      DEC(count, 8); ip[position] := CHR(value DIV ASH(1, count)); INC(position);
      value := value MOD ASH(1, count)
    END
  END;
  (* RFC 4648's two unused low bits must be zero. *)
  RETURN value = 0
END DecodeHost;

PROCEDURE Before*(left, right: ARRAY OF CHAR): BOOLEAN;
(* Use Barev's ASCII-insensitive collision order, then distinguish case-only identities. *)
  VAR index, leftLength, rightLength: LONGINT; l, r: CHAR;
BEGIN
  index := 0; leftLength := Length(left); rightLength := Length(right);
  WHILE (index < leftLength) & (index < rightLength) DO
    l := left[index]; r := right[index];
    IF (l >= "A") & (l <= "Z") THEN l := CHR(ORD(l)+32) END;
    IF (r >= "A") & (r <= "Z") THEN r := CHR(ORD(r)+32) END;
    IF l # r THEN RETURN l < r END;
    INC(index)
  END;
  IF leftLength # rightLength THEN RETURN leftLength < rightLength END;
  FOR index := 0 TO leftLength-1 DO
    IF left[index] # right[index] THEN RETURN left[index] < right[index] END
  END;
  RETURN FALSE
END Before;

PROCEDURE Nick*(text: ARRAY OF CHAR): BOOLEAN;
  VAR units: T.String; n, index, code: LONGINT;
BEGIN
  n := Length(text); IF (n = 0) OR (n > 256) OR (n = LEN(text)) THEN RETURN FALSE END;
  units := Items.UTF8(text); IF units = NIL THEN RETURN FALSE END;
  index := 0;
  WHILE units[index] # 0 DO
    code := units[index];
    IF (code <= 32) OR ((code >= 127) & (code <= 160)) OR
       (code = ORD("@")) OR (code = ORD("/")) OR (code = 1680H) OR
       ((code >= 2000H) & (code <= 200FH)) OR ((code >= 2028H) & (code <= 202FH)) OR
       ((code >= 205FH) & (code <= 206FH)) OR (code = 3000H) OR (code = 0FEFFH) OR
       (code = 0FFFEH) OR (code = 0FFFFH) THEN RETURN FALSE END;
    INC(index)
  END;
  RETURN TRUE
END Nick;

PROCEDURE Identity*(text: ARRAY OF CHAR; VAR canonical: ARRAY OF CHAR; VAR ip: IP): BOOLEAN;
  VAR nick: ARRAY 257 OF CHAR; address: ARRAY 41 OF CHAR; normalized: ARRAY 40 OF CHAR;
    n, at, index, length: LONGINT;
BEGIN
  n := Length(text); IF (n = LEN(text)) OR (n >= maxIdentityBytes) THEN RETURN FALSE END;
  at := 0; WHILE (at < n) & (text[at] # "@") DO INC(at) END;
  IF (at = 0) OR (at > 256) OR (at = n) OR (n-at-1 > 40) THEN RETURN FALSE END;
  FOR index := 0 TO at-1 DO nick[index] := text[index] END; nick[at] := 0X;
  FOR index := at+1 TO n-1 DO address[index-at-1] := text[index] END; address[n-at-1] := 0X;
  IF ~Nick(nick) OR (~ParseIP(address, ip) & ~DecodeHost(address, ip)) OR
     ~Yggdrasil(ip) OR ~Format(ip, normalized) THEN RETURN FALSE END;
  length := Length(normalized);
  IF LEN(canonical) < at+length+2 THEN RETURN FALSE END;
  FOR index := 0 TO at-1 DO canonical[index] := nick[index] END; canonical[at] := "@";
  FOR index := 0 TO length DO canonical[at+1+index] := normalized[index] END;
  RETURN TRUE
END Identity;

PROCEDURE EncodedIdentity*(text: ARRAY OF CHAR; VAR encoded: ARRAY OF CHAR): BOOLEAN;
  VAR canonical: ARRAY maxIdentityBytes OF CHAR; host: ARRAY 40 OF CHAR; ip: IP;
    at, index, n: LONGINT;
BEGIN
  IF ~Identity(text, canonical, ip) OR ~EncodedHost(ip, host) THEN RETURN FALSE END;
  at := 0; WHILE canonical[at] # "@" DO INC(at) END;
  n := Length(host); IF LEN(encoded) < at+n+2 THEN RETURN FALSE END;
  FOR index := 0 TO at DO encoded[index] := canonical[index] END;
  FOR index := 0 TO n DO encoded[at+1+index] := host[index] END;
  RETURN TRUE
END EncodedIdentity;

END BarevAddress.
