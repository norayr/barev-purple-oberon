MODULE BarevPostStore;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT P := BarevPost, A := BarevFeedAccess, Items := XmppItems;

CONST
  okay* = 0; invalid* = 1; denied* = 2; missing* = 3; conflict* = 4;
  full* = 5; stale* = 6;
  maxNodes* = 16; maxPosts* = 256; maxBytes* = 4194304; maxPage* = 32;
  maxNodeBytes* = 128;

TYPE
  NodeInfo* = RECORD
    name*: ARRAY maxNodeBytes+1 OF CHAR;
    title*: ARRAY P.maxTitleBytes+1 OF CHAR;
    model*: LONGINT
  END;
  Node = POINTER TO RECORD
    name, title: Items.Bytes; policy: A.Node; generation: LONGINT
  END;
  Slot = RECORD node: LONGINT; itemID, id: Items.Bytes; post: P.Post END;
  Store* = POINTER TO StoreDesc;
  StoreDesc* = RECORD
    owner: ARRAY 65 OF CHAR; active: BOOLEAN;
    nodeLimit, postLimit, byteLimit, nodes, used, live, bytes: LONGINT;
    destinations: ARRAY maxNodes OF Node;
    posts: ARRAY maxPosts OF Slot
  END;
  Cursor* = RECORD store: Store; node, generation, next: LONGINT; owner: BOOLEAN END;
  Page* = POINTER TO PageDesc;
  PageDesc* = RECORD size: LONGINT; posts: ARRAY maxPage OF P.Post END;

PROCEDURE Length(text: ARRAY OF CHAR): LONGINT;
VAR n: LONGINT;
BEGIN n := 0; WHILE (n < LEN(text)) & (text[n] # 0X) DO INC(n) END; RETURN n END Length;

PROCEDURE Valid(store: Store): BOOLEAN;
BEGIN RETURN (store # NIL) & store.active END Valid;

PROCEDURE New*(owner: ARRAY OF CHAR; nodes, posts, bytes: LONGINT): Store;
VAR store: Store;
BEGIN
  IF ~P.Owner(owner) OR (nodes < 1) OR (nodes > maxNodes) OR
      (posts < 1) OR (posts > maxPosts) OR (bytes < 1) OR (bytes > maxBytes) THEN RETURN NIL END;
  NEW(store); COPY(owner, store.owner); store.active := TRUE;
  store.nodeLimit := nodes; store.postLimit := posts; store.byteLimit := bytes;
  RETURN store
END New;

PROCEDURE Close*(VAR store: Store);
VAR i: LONGINT;
BEGIN
  IF store = NIL THEN RETURN END;
  store.active := FALSE;
  FOR i := 0 TO store.nodes-1 DO store.destinations[i] := NIL END;
  FOR i := 0 TO store.used-1 DO
    store.posts[i].post := NIL; store.posts[i].itemID := NIL; store.posts[i].id := NIL
  END;
  store.nodes := 0; store.used := 0; store.live := 0; store.bytes := 0; store := NIL
END Close;

PROCEDURE FindNode(store: Store; name: ARRAY OF CHAR): LONGINT;
VAR i: LONGINT;
BEGIN
  IF ~Valid(store) OR ~P.Token(name, maxNodeBytes) THEN RETURN -1 END;
  FOR i := 0 TO store.nodes-1 DO IF store.destinations[i].name^ = name THEN RETURN i END END;
  RETURN -1
END FindNode;

PROCEDURE FindPost(store: Store; node: LONGINT; itemID: ARRAY OF CHAR): LONGINT;
VAR i: LONGINT;
BEGIN
  IF ~P.Token(itemID, P.maxItemBytes) THEN RETURN -1 END;
  FOR i := 0 TO store.used-1 DO
    IF (store.posts[i].node = node) & (store.posts[i].itemID^ = itemID) THEN RETURN i END
  END;
  RETURN -1
END FindPost;

PROCEDURE AddNodeOwner*(store: Store; name, title: ARRAY OF CHAR; policy: A.Node): LONGINT;
VAR node: Node; bytes, model: LONGINT;
BEGIN
  model := A.Model(policy);
  IF ~Valid(store) OR ~P.Token(name, maxNodeBytes) OR ~P.Text(title, P.maxTitleBytes, FALSE) OR
      ((model # A.open) & (model # A.roster) & (model # A.whitelist)) THEN RETURN invalid END;
  IF FindNode(store, name) >= 0 THEN RETURN conflict END;
  bytes := Length(name)+Length(title);
  IF (store.nodes = store.nodeLimit) OR (bytes > store.byteLimit-store.bytes) THEN RETURN full END;
  NEW(node); node.name := Items.Copy8(name); node.title := Items.Copy8(title);
  node.policy := policy; node.generation := 1;
  store.destinations[store.nodes] := node; INC(store.nodes); INC(store.bytes, bytes);
  RETURN okay
END AddNodeOwner;

PROCEDURE PolicyOwner*(store: Store; name: ARRAY OF CHAR; policy: A.Node): LONGINT;
VAR index, model: LONGINT; node: Node;
BEGIN
  IF ~Valid(store) THEN RETURN invalid END;
  index := FindNode(store, name); IF index < 0 THEN RETURN missing END;
  node := store.destinations[index]; model := A.Model(policy);
  IF (model = A.denied) OR (model # A.Model(node.policy)) THEN RETURN invalid END;
  IF policy = node.policy THEN RETURN okay END;
  IF node.generation = MAX(LONGINT) THEN RETURN full END;
  node.policy := policy; INC(node.generation); RETURN okay
END PolicyOwner;

PROCEDURE ParentAllowed(store: Store; node: LONGINT; VAR header: P.Header): BOOLEAN;
VAR i, parent, found, steps: LONGINT; id: Items.Bytes; previous: P.Header;
BEGIN
  IF header.replyTo[0] = 0X THEN RETURN TRUE END;
  FOR i := 0 TO store.used-1 DO
    IF store.posts[i].id^ = header.replyTo THEN
      parent := store.posts[i].node;
      IF (parent # node) & (A.Model(store.destinations[parent].policy) # A.open) THEN RETURN FALSE END
    END
  END;
  id := Items.Copy8(header.replyTo); steps := 0;
  WHILE id[0] # 0X DO
    IF (id^ = header.id) OR (steps > store.used) THEN RETURN FALSE END;
    found := -1;
    FOR i := 0 TO store.used-1 DO IF store.posts[i].id^ = id^ THEN found := i END END;
    IF (found < 0) OR ~P.Describe(store.posts[found].post, previous) THEN RETURN TRUE END;
    id := Items.Copy8(previous.replyTo); INC(steps)
  END;
  RETURN TRUE
END ParentAllowed;

PROCEDURE PutOwner*(store: Store; name: ARRAY OF CHAR; post: P.Post): LONGINT;
VAR index, i: LONGINT; header: P.Header; node: Node;
BEGIN
  IF ~Valid(store) OR ~P.Describe(post, header) THEN RETURN invalid END;
  IF header.owner # store.owner THEN RETURN denied END;
  index := FindNode(store, name); IF index < 0 THEN RETURN missing END;
  FOR i := 0 TO store.used-1 DO
    IF (store.posts[i].itemID^ = header.itemID) OR (store.posts[i].id^ = header.id) THEN
      IF (store.posts[i].node = index) & P.Same(store.posts[i].post, post) THEN RETURN okay END;
      RETURN conflict
    END
  END;
  IF ~ParentAllowed(store, index, header) THEN RETURN denied END;
  node := store.destinations[index];
  IF (store.used = store.postLimit) OR (P.Size(post) > store.byteLimit-store.bytes) OR
      (node.generation = MAX(LONGINT)) THEN RETURN full END;
  i := store.used; store.posts[i].node := index;
  store.posts[i].itemID := Items.Copy8(header.itemID); store.posts[i].id := Items.Copy8(header.id);
  store.posts[i].post := post;
  INC(store.used); INC(store.live); INC(store.bytes, P.Size(post)); INC(node.generation);
  RETURN okay
END PutOwner;

PROCEDURE EditOwner*(store: Store; name: ARRAY OF CHAR; expected, replacement: P.Post): LONGINT;
VAR index, slot, delta: LONGINT; header: P.Header; node: Node; previous: P.Post;
BEGIN
  IF ~Valid(store) OR ~P.Valid(expected) OR ~P.Describe(replacement, header) THEN RETURN invalid END;
  IF header.owner # store.owner THEN RETURN denied END;
  index := FindNode(store, name); IF index < 0 THEN RETURN missing END;
  slot := FindPost(store, index, header.itemID); IF slot < 0 THEN RETURN missing END;
  previous := store.posts[slot].post;
  IF ~P.Valid(previous) THEN RETURN conflict END;
  IF P.Same(previous, replacement) THEN RETURN okay END;
  IF ~P.Same(previous, expected) OR ~P.Revision(previous, replacement) THEN RETURN conflict END;
  node := store.destinations[index]; delta := P.Size(replacement)-P.Size(previous);
  IF (delta > store.byteLimit-store.bytes) OR (node.generation = MAX(LONGINT)) THEN RETURN full END;
  store.posts[slot].post := replacement; INC(store.bytes, delta); INC(node.generation);
  RETURN okay
END EditOwner;

PROCEDURE RetractOwner*(store: Store; name, itemID: ARRAY OF CHAR): LONGINT;
VAR index, slot: LONGINT; node: Node;
BEGIN
  IF ~Valid(store) THEN RETURN invalid END;
  index := FindNode(store, name); IF index < 0 THEN RETURN missing END;
  slot := FindPost(store, index, itemID); IF slot < 0 THEN RETURN missing END;
  IF store.posts[slot].post = NIL THEN RETURN okay END;
  node := store.destinations[index]; IF node.generation = MAX(LONGINT) THEN RETURN full END;
  DEC(store.bytes, P.Size(store.posts[slot].post)-Length(store.posts[slot].itemID^)-Length(store.posts[slot].id^));
  store.posts[slot].post := NIL; DEC(store.live); INC(node.generation);
  RETURN okay
END RetractOwner;

PROCEDURE GetOwner*(store: Store; name, itemID: ARRAY OF CHAR): P.Post;
VAR index, slot: LONGINT;
BEGIN
  index := FindNode(store, name); IF index < 0 THEN RETURN NIL END;
  slot := FindPost(store, index, itemID); IF slot < 0 THEN RETURN NIL END;
  RETURN store.posts[slot].post
END GetOwner;

PROCEDURE Get*(store: Store; name, itemID: ARRAY OF CHAR; VAR reader: A.Reader; contact: A.Contact): P.Post;
VAR index: LONGINT;
BEGIN
  index := FindNode(store, name);
  IF (index < 0) OR ~A.CanRead(store.destinations[index].policy, reader, contact) THEN RETURN NIL END;
  RETURN GetOwner(store, name, itemID)
END Get;

PROCEDURE NodeSnapshot(node: Node; VAR info: NodeInfo);
BEGIN COPY(node.name^, info.name); COPY(node.title^, info.title); info.model := A.Model(node.policy) END NodeSnapshot;

PROCEDURE NodeOwner*(store: Store; index: LONGINT; VAR info: NodeInfo): BOOLEAN;
BEGIN
  IF ~Valid(store) OR (index < 0) OR (index >= store.nodes) THEN RETURN FALSE END;
  NodeSnapshot(store.destinations[index], info); RETURN TRUE
END NodeOwner;

PROCEDURE DescribeNode*(store: Store; name: ARRAY OF CHAR; VAR reader: A.Reader;
    contact: A.Contact; VAR info: NodeInfo): BOOLEAN;
VAR index: LONGINT;
BEGIN
  index := FindNode(store, name);
  IF (index < 0) OR ~A.CanRead(store.destinations[index].policy, reader, contact) THEN RETURN FALSE END;
  NodeSnapshot(store.destinations[index], info); RETURN TRUE
END DescribeNode;

PROCEDURE Cancel*(VAR cursor: Cursor);
BEGIN cursor.store := NIL; cursor.owner := FALSE; cursor.next := -1 END Cancel;

PROCEDURE Position(store: Store; node: LONGINT; owner: BOOLEAN; VAR cursor: Cursor);
BEGIN
  cursor.store := store; cursor.node := node; cursor.owner := owner;
  cursor.generation := store.destinations[node].generation; cursor.next := store.used-1
END Position;

PROCEDURE BeginOwner*(store: Store; name: ARRAY OF CHAR; VAR cursor: Cursor): LONGINT;
VAR index: LONGINT;
BEGIN
  Cancel(cursor); index := FindNode(store, name);
  IF index < 0 THEN RETURN missing END;
  Position(store, index, TRUE, cursor); RETURN okay
END BeginOwner;

PROCEDURE Begin*(store: Store; name: ARRAY OF CHAR; VAR reader: A.Reader;
    contact: A.Contact; VAR cursor: Cursor): LONGINT;
VAR index: LONGINT;
BEGIN
  Cancel(cursor); index := FindNode(store, name);
  IF (index < 0) OR ~A.CanRead(store.destinations[index].policy, reader, contact) THEN RETURN denied END;
  Position(store, index, FALSE, cursor); RETURN okay
END Begin;

PROCEDURE Take(VAR cursor: Cursor; maximum: LONGINT; VAR page: Page): LONGINT;
VAR next: LONGINT;
BEGIN
  IF (maximum < 1) OR (maximum > maxPage) THEN RETURN invalid END;
  IF cursor.generation # cursor.store.destinations[cursor.node].generation THEN RETURN stale END;
  NEW(page); next := cursor.next;
  WHILE (next >= 0) & (page.size < maximum) DO
    IF (cursor.store.posts[next].node = cursor.node) & (cursor.store.posts[next].post # NIL) THEN
      page.posts[page.size] := cursor.store.posts[next].post; INC(page.size)
    END;
    DEC(next)
  END;
  cursor.next := next; RETURN okay
END Take;

PROCEDURE ReadOwner*(VAR cursor: Cursor; maximum: LONGINT; VAR page: Page): LONGINT;
BEGIN
  page := NIL;
  IF ~Valid(cursor.store) OR ~cursor.owner THEN RETURN invalid END;
  RETURN Take(cursor, maximum, page)
END ReadOwner;

PROCEDURE Read*(VAR cursor: Cursor; VAR reader: A.Reader; contact: A.Contact;
    maximum: LONGINT; VAR page: Page): LONGINT;
BEGIN
  page := NIL;
  IF ~Valid(cursor.store) OR cursor.owner THEN RETURN denied END;
  IF ~A.CanRead(cursor.store.destinations[cursor.node].policy, reader, contact) THEN RETURN denied END;
  RETURN Take(cursor, maximum, page)
END Read;

PROCEDURE PageSize*(page: Page): LONGINT;
BEGIN IF page = NIL THEN RETURN 0 END; RETURN page.size END PageSize;

PROCEDURE PagePost*(page: Page; index: LONGINT): P.Post;
BEGIN
  IF (page = NIL) OR (index < 0) OR (index >= page.size) THEN RETURN NIL END;
  RETURN page.posts[index]
END PagePost;

PROCEDURE CountOwner*(store: Store): LONGINT;
BEGIN IF ~Valid(store) THEN RETURN 0 END; RETURN store.live END CountOwner;

PROCEDURE NodesOwner*(store: Store): LONGINT;
BEGIN IF ~Valid(store) THEN RETURN 0 END; RETURN store.nodes END NodesOwner;

PROCEDURE ReservedOwner*(store: Store): LONGINT;
BEGIN IF ~Valid(store) THEN RETURN 0 END; RETURN store.used END ReservedOwner;

PROCEDURE BytesOwner*(store: Store): LONGINT;
BEGIN IF ~Valid(store) THEN RETURN 0 END; RETURN store.bytes END BytesOwner;

END BarevPostStore.
