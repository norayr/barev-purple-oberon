MODULE BarevPublishAccounts;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT Pub := BarevPublishing, P := BarevPost, S := BarevPostStore,
  A := BarevFeedAccess, Clock := BarevPostClock, IntStr;

CONST maxAccounts* = 16; maxCursors* = 16; cursorSeconds* = 300; maxAudience* = 128;
  loading* = 1; uninitialized* = 2; ready* = 3; unavailable* = 4; saving* = 5;
  markerRequired* = 13;
  opening = 1; initializing = 2; creating = 3; publishing = 4; reloading = 5;

TYPE
  Cursor = RECORD
    position: Pub.Cursor; id, touched: LONGINT;
    client: ARRAY 256 OF CHAR; node: ARRAY S.maxNodeBytes+1 OF CHAR
  END;
  Account = POINTER TO RECORD
    handle, owner, operation, status: LONGINT;
    identity: ARRAY 65 OF CHAR; service: Pub.Service;
    expected, allowSetup, marked: BOOLEAN;
    cursors: ARRAY maxCursors OF Cursor
  END;

VAR slots: ARRAY maxAccounts OF Account; serial, cursorSerial: LONGINT;
  enabled: BOOLEAN; emptyCursor: Pub.Cursor;

PROCEDURE Find(handle, owner: LONGINT): Account;
VAR i: LONGINT;
BEGIN
  IF (handle <= 0) OR (owner <= 0) THEN RETURN NIL END;
  FOR i := 0 TO maxAccounts-1 DO
    IF (slots[i] # NIL) & (slots[i].handle = handle) & (slots[i].owner = owner) THEN RETURN slots[i] END
  END;
  RETURN NIL
END Find;

PROCEDURE Clear(account: Account);
VAR i: LONGINT;
BEGIN
  FOR i := 0 TO maxCursors-1 DO account.cursors[i].id := 0; account.cursors[i].position := emptyCursor END
END Clear;

PROCEDURE Start*(): BOOLEAN;
BEGIN enabled := Pub.Start(); RETURN enabled END Start;

PROCEDURE Open*(owner: LONGINT; profile, identity, author: ARRAY OF CHAR; expected: BOOLEAN): LONGINT;
VAR i, free, status: LONGINT; service: Pub.Service; account: Account;
BEGIN
  IF ~enabled OR (owner <= 0) OR ~P.Owner(identity) OR (serial = MAX(LONGINT)) THEN RETURN 0 END;
  free := -1;
  FOR i := 0 TO maxAccounts-1 DO
    IF slots[i] = NIL THEN IF free < 0 THEN free := i END
    ELSIF slots[i].identity = identity THEN
      IF slots[i].owner = owner THEN RETURN slots[i].handle END;
      RETURN 0
    ELSIF slots[i].owner = owner THEN RETURN 0
    END
  END;
  IF free < 0 THEN RETURN 0 END;
  status := Pub.OpenAsync(profile, identity, author, service); IF status # Pub.pending THEN RETURN 0 END;
  NEW(account); INC(serial); account.handle := serial; account.owner := owner; COPY(identity, account.identity);
  account.service := service; account.expected := expected; account.marked := expected;
  account.allowSetup := ~expected; account.operation := opening; account.status := Pub.pending;
  slots[free] := account; RETURN serial
END Open;

PROCEDURE Close*(handle, owner: LONGINT);
VAR i: LONGINT; account: Account;
BEGIN
  account := Find(handle, owner); IF account = NIL THEN RETURN END;
  Clear(account); Pub.Close(account.service);
  FOR i := 0 TO maxAccounts-1 DO IF slots[i] = account THEN slots[i] := NIL END END
END Close;

PROCEDURE Busy*(handle, owner: LONGINT): BOOLEAN;
VAR account: Account;
BEGIN account := Find(handle, owner); RETURN (account # NIL) & Pub.Busy(account.service) END Busy;

PROCEDURE State*(handle, owner: LONGINT): LONGINT;
VAR account: Account;
BEGIN
  account := Find(handle, owner); IF account = NIL THEN RETURN unavailable END;
  IF Pub.Ready(account.service) THEN IF Pub.Busy(account.service) THEN RETURN saving END; RETURN ready END;
  IF Pub.Busy(account.service) THEN RETURN loading END;
  IF (account.status = Pub.missing) & account.allowSetup THEN RETURN uninitialized END;
  RETURN unavailable
END State;

PROCEDURE Poll*(handle, owner: LONGINT; VAR changed: BOOLEAN): LONGINT;
VAR account: Account; status, operation: LONGINT;
BEGIN
  changed := FALSE; account := Find(handle, owner);
  IF (account = NIL) OR ~Pub.Busy(account.service) THEN RETURN Pub.invalid END;
  status := Pub.Poll(account.service); IF status = Pub.pending THEN RETURN status END;
  operation := account.operation; account.operation := 0; account.status := status;
  Clear(account);
  IF status = Pub.okay THEN
    account.expected := TRUE; account.allowSetup := FALSE;
    changed := (operation = initializing) OR (operation = creating) OR (operation = publishing)
  END;
  RETURN status
END Poll;

PROCEDURE NeedsMarker*(handle, owner: LONGINT): BOOLEAN;
VAR account: Account;
BEGIN account := Find(handle, owner); RETURN (account # NIL) & account.expected & ~account.marked END NeedsMarker;

PROCEDURE Marked*(handle, owner: LONGINT): BOOLEAN;
VAR account: Account;
BEGIN
  account := Find(handle, owner); IF (account = NIL) OR ~account.expected THEN RETURN FALSE END;
  account.marked := TRUE; RETURN TRUE
END Marked;

PROCEDURE Initialize*(handle, owner: LONGINT): LONGINT;
VAR account: Account; status: LONGINT;
BEGIN
  account := Find(handle, owner); IF account = NIL THEN RETURN Pub.invalid END;
  IF Pub.Busy(account.service) THEN RETURN Pub.busy END;
  IF ~account.allowSetup OR Pub.Ready(account.service) THEN RETURN Pub.conflict END;
  IF account.status # Pub.missing THEN RETURN Pub.unavailable END;
  account.expected := TRUE; IF ~account.marked THEN RETURN markerRequired END;
  status := Pub.Initialize(account.service, S.maxNodes, S.maxPosts, S.maxBytes);
  IF status = Pub.pending THEN account.operation := initializing END;
  RETURN status
END Initialize;

PROCEDURE Writable(account: Account): LONGINT;
BEGIN
  IF account = NIL THEN RETURN Pub.invalid END;
  IF Pub.Busy(account.service) THEN RETURN Pub.busy END;
  IF ~Pub.Ready(account.service) THEN RETURN Pub.unavailable END;
  IF ~account.marked THEN RETURN markerRequired END;
  RETURN Pub.okay
END Writable;

PROCEDURE Create*(handle, owner: LONGINT; node, title: ARRAY OF CHAR; model: LONGINT;
    VAR names: ARRAY OF A.Name; count: LONGINT): LONGINT;
VAR account: Account; policy: A.Node; status: LONGINT;
BEGIN
  account := Find(handle, owner); status := Writable(account); IF status # Pub.okay THEN RETURN status END;
  IF (count < 0) OR (count > maxAudience) OR (count > LEN(names)) THEN RETURN Pub.invalid END;
  policy := A.NewNode(model, names, count); IF policy = NIL THEN RETURN Pub.invalid END;
  status := Pub.AddNode(account.service, node, title, policy);
  IF status = Pub.pending THEN account.operation := creating END;
  RETURN status
END Create;

PROCEDURE Publish*(handle, owner: LONGINT; node, token, title, text, parent: ARRAY OF CHAR; seconds: HUGEINT): LONGINT;
VAR account: Account; status: LONGINT; stamp: ARRAY 21 OF CHAR;
BEGIN
  account := Find(handle, owner); status := Writable(account); IF status # Pub.okay THEN RETURN status END;
  IF ~Clock.UTC(seconds, stamp) THEN RETURN Pub.unavailable END;
  status := Pub.Publish(account.service, node, token, title, text, parent, stamp);
  IF status = Pub.pending THEN account.operation := publishing END;
  RETURN status
END Publish;

PROCEDURE Reload*(handle, owner: LONGINT): LONGINT;
VAR account: Account; status: LONGINT;
BEGIN
  account := Find(handle, owner); IF account = NIL THEN RETURN Pub.invalid END;
  status := Pub.Reload(account.service);
  IF status = Pub.pending THEN account.operation := reloading; Clear(account) END;
  RETURN status
END Reload;

PROCEDURE Node*(handle, owner, index: LONGINT; VAR info: S.NodeInfo): BOOLEAN;
VAR account: Account;
BEGIN account := Find(handle, owner); RETURN (account # NIL) & Pub.Node(account.service, index, info) END Node;

PROCEDURE Get*(handle, owner: LONGINT; node, item: ARRAY OF CHAR): P.Post;
VAR account: Account;
BEGIN
  account := Find(handle, owner); IF account = NIL THEN RETURN NIL END;
  RETURN Pub.Get(account.service, node, item)
END Get;

PROCEDURE Token(text: ARRAY OF CHAR): LONGINT;
VAR i, digit, value: LONGINT;
BEGIN
  IF (LEN(text) < 2) OR (text[0] < "1") OR (text[0] > "9") THEN RETURN 0 END;
  i := 0; value := 0;
  WHILE (i < LEN(text)) & (i < 10) & (text[i] # 0X) DO
    digit := ORD(text[i])-ORD("0");
    IF (digit < 0) OR (digit > 9) OR (value > (MAX(LONGINT)-digit) DIV 10) THEN RETURN 0 END;
    value := value*10+digit; INC(i)
  END;
  IF (i = LEN(text)) OR (text[i] # 0X) THEN RETURN 0 END;
  RETURN value
END Token;

PROCEDURE Page*(handle, owner: LONGINT; client, node, token: ARRAY OF CHAR; maximum, now: LONGINT;
    VAR page: S.Page; VAR next: ARRAY OF CHAR): LONGINT;
VAR account: Account; position: Pub.Cursor; result: S.Page;
  i, index, free, id, status: LONGINT;
BEGIN
  page := NIL; IF LEN(next) > 0 THEN next[0] := 0X END;
  IF (LEN(next) < 11) OR (LEN(token) < 1) OR (now < 0) OR (maximum < 1) OR (maximum > S.maxPage) OR
      ~P.Text(client, 255, FALSE) OR (client[0] # ":") OR ~P.Token(node, S.maxNodeBytes) THEN RETURN Pub.invalid END;
  account := Find(handle, owner); IF account = NIL THEN RETURN Pub.invalid END;
  IF ~Pub.Ready(account.service) THEN RETURN Pub.unavailable END;
  index := -1; free := -1; id := Token(token);
  FOR i := 0 TO maxCursors-1 DO
    IF (account.cursors[i].id # 0) & ((now < account.cursors[i].touched) OR
        (now-account.cursors[i].touched >= cursorSeconds)) THEN
      account.cursors[i].id := 0; account.cursors[i].position := emptyCursor
    END;
    IF account.cursors[i].id = 0 THEN IF free < 0 THEN free := i END
    ELSIF (account.cursors[i].id = id) & (account.cursors[i].client = client) &
        (account.cursors[i].node = node) THEN index := i
    END
  END;
  IF token[0] = 0X THEN
    IF free < 0 THEN RETURN Pub.busy END;
    index := free; status := Pub.Begin(account.service, node, position);
    IF status # Pub.okay THEN RETURN status END
  ELSE
    IF index < 0 THEN RETURN Pub.stale END;
    position := account.cursors[index].position
  END;
  IF cursorSerial = MAX(LONGINT) THEN RETURN Pub.full END;
  status := Pub.Read(account.service, position, maximum, result); IF status # Pub.okay THEN RETURN status END;
  IF S.PageSize(result) < maximum THEN account.cursors[index].id := 0; account.cursors[index].position := emptyCursor
  ELSE
    INC(cursorSerial); account.cursors[index].id := cursorSerial; account.cursors[index].position := position;
    account.cursors[index].touched := now; COPY(client, account.cursors[index].client); COPY(node, account.cursors[index].node);
    IntStr.IntToStr(cursorSerial, next)
  END;
  page := result; RETURN Pub.okay
END Page;

PROCEDURE Stop*;
VAR i: LONGINT;
BEGIN
  enabled := FALSE;
  FOR i := 0 TO maxAccounts-1 DO
    IF slots[i] # NIL THEN Clear(slots[i]); Pub.Close(slots[i].service); slots[i] := NIL END
  END;
  Pub.Stop
END Stop;

PROCEDURE Idle*(): BOOLEAN;
VAR i: LONGINT;
BEGIN
  FOR i := 0 TO maxAccounts-1 DO IF slots[i] # NIL THEN RETURN FALSE END END;
  RETURN Pub.Idle()
END Idle;

END BarevPublishAccounts.
