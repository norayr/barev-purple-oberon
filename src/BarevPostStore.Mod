MODULE BarevPostStore;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT P := BarevPost, A := BarevFeedAccess, Items := XmppItems, B := BarevPostBinary;

CONST
  okay* = 0; invalid* = 1; denied* = 2; missing* = 3; conflict* = 4;
  full* = 5; stale* = 6;
  maxNodes* = 16; maxPosts* = 256; maxBytes* = 4194304; maxPage* = 32;
  maxNodeBytes* = 128;
  maxSnapshotBytes* = B.maxBytes;

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
  PolicyNames = POINTER TO ARRAY A.maxMembers OF A.Name;

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

PROCEDURE CopyOwner*(source: Store): Store;
VAR copy: Store; i: LONGINT;
BEGIN
  IF ~Valid(source) THEN RETURN NIL END;
  copy := New(source.owner, source.nodeLimit, source.postLimit, source.byteLimit);
  copy.nodes := source.nodes; copy.used := source.used; copy.live := source.live; copy.bytes := source.bytes;
  FOR i := 0 TO source.nodes-1 DO
    NEW(copy.destinations[i]); copy.destinations[i]^ := source.destinations[i]^
  END;
  FOR i := 0 TO source.used-1 DO copy.posts[i] := source.posts[i] END;
  RETURN copy
END CopyOwner;

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

PROCEDURE ReferenceOwner*(store: Store; id: ARRAY OF CHAR; VAR info: NodeInfo): BOOLEAN;
VAR i: LONGINT;
BEGIN
  IF ~Valid(store) OR ~P.Reference(id, FALSE) THEN RETURN FALSE END;
  FOR i := 0 TO store.used-1 DO
    IF store.posts[i].id^ = id THEN NodeSnapshot(store.destinations[store.posts[i].node], info); RETURN TRUE END
  END;
  RETURN FALSE
END ReferenceOwner;

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

PROCEDURE OwnedBy*(store: Store; owner: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN Valid(store) & P.Owner(owner) & (store.owner = owner) END OwnedBy;

PROCEDURE ExtendsOwner*(previous, next: Store): BOOLEAN;
VAR i: LONGINT; before, after: P.Post;
BEGIN
  IF ~Valid(previous) OR ~Valid(next) OR (previous.owner # next.owner) OR
      (previous.nodes > next.nodes) OR (previous.used > next.used) THEN RETURN FALSE END;
  FOR i := 0 TO previous.nodes-1 DO
    IF (previous.destinations[i].name^ # next.destinations[i].name^) OR
        (A.Model(previous.destinations[i].policy) # A.Model(next.destinations[i].policy)) THEN RETURN FALSE END
  END;
  FOR i := 0 TO previous.used-1 DO
    IF (previous.posts[i].node # next.posts[i].node) OR
        (previous.posts[i].itemID^ # next.posts[i].itemID^) OR (previous.posts[i].id^ # next.posts[i].id^) THEN RETURN FALSE END;
    before := previous.posts[i].post; after := next.posts[i].post;
    IF before = NIL THEN IF after # NIL THEN RETURN FALSE END
    ELSIF (after # NIL) & ~P.Same(before, after) & ~P.Revision(before, after) THEN RETURN FALSE
    END
  END;
  RETURN TRUE
END ExtendsOwner;

PROCEDURE WriteSnapshot(store: Store; VAR writer: B.Writer): BOOLEAN;
VAR i, j, count: LONGINT; names: PolicyNames; header: P.Header;
  text: ARRAY P.maxTextBytes+1 OF CHAR;
BEGIN
  B.PutText(writer, "BAREVPS1"); B.PutText(writer, store.owner);
  B.PutWord(writer, store.nodeLimit); B.PutWord(writer, store.postLimit); B.PutWord(writer, store.byteLimit);
  B.PutWord(writer, store.nodes); B.PutWord(writer, store.used); NEW(names);
  FOR i := 0 TO store.nodes-1 DO
    B.PutText(writer, store.destinations[i].name^); B.PutText(writer, store.destinations[i].title^);
    IF ~A.CopyPolicy(store.destinations[i].policy, names^, count) THEN RETURN FALSE END;
    B.PutWord(writer, A.Model(store.destinations[i].policy)); B.PutWord(writer, count);
    FOR j := 0 TO count-1 DO B.PutText(writer, names[j]) END
  END;
  FOR i := 0 TO store.used-1 DO
    B.PutWord(writer, store.posts[i].node);
    IF store.posts[i].post = NIL THEN B.PutWord(writer, 0) ELSE B.PutWord(writer, 1) END;
    B.PutText(writer, store.posts[i].itemID^); B.PutText(writer, store.posts[i].id^);
    IF store.posts[i].post # NIL THEN
      IF ~P.Describe(store.posts[i].post, header) OR ~P.Content(store.posts[i].post, text) THEN RETURN FALSE END;
      B.PutText(writer, header.author); B.PutText(writer, header.title);
      B.PutText(writer, header.published); B.PutText(writer, header.updated);
      B.PutText(writer, header.replyTo); B.PutText(writer, text)
    END
  END;
  B.Seal(writer); RETURN B.Written(writer) >= 0
END WriteSnapshot;

PROCEDURE EncodeOwner*(store: Store; VAR bytes: Items.Bytes; VAR length: LONGINT): BOOLEAN;
VAR writer: B.Writer; maximum: LONGINT;
BEGIN
  bytes := NIL; length := 0;
  IF ~Valid(store) THEN RETURN FALSE END;
  B.OpenWriter(writer, NIL, maxSnapshotBytes);
  IF ~WriteSnapshot(store, writer) THEN RETURN FALSE END;
  maximum := B.Written(writer); NEW(bytes, maximum);
  B.OpenWriter(writer, bytes, maximum);
  IF ~WriteSnapshot(store, writer) OR (B.Written(writer) # maximum) THEN bytes := NIL; RETURN FALSE END;
  length := maximum; RETURN TRUE
END EncodeOwner;

PROCEDURE ReadNodes(store: Store; VAR reader: B.Reader; count: LONGINT): BOOLEAN;
VAR i, j, model, members: LONGINT; names: PolicyNames; policy: A.Node;
  name: ARRAY maxNodeBytes+1 OF CHAR; title: ARRAY P.maxTitleBytes+1 OF CHAR;
BEGIN
  NEW(names);
  FOR i := 0 TO count-1 DO
    IF ~B.Text(reader, name) OR ~B.Text(reader, title) THEN RETURN FALSE END;
    model := B.Word(reader); members := B.Word(reader);
    IF ~B.Good(reader) OR (members < 0) OR (members > A.maxMembers) THEN RETURN FALSE END;
    FOR j := 0 TO members-1 DO IF ~B.Text(reader, names[j]) THEN RETURN FALSE END END;
    policy := A.NewNode(model, names^, members);
    IF AddNodeOwner(store, name, title, policy) # okay THEN RETURN FALSE END
  END;
  RETURN TRUE
END ReadNodes;

PROCEDURE ReadSlots(store: Store; VAR reader: B.Reader; count: LONGINT): BOOLEAN;
VAR i, j, node, state, size: LONGINT; header: P.Header; post: P.Post;
  text: ARRAY P.maxTextBytes+1 OF CHAR;
BEGIN
  COPY(store.owner, header.owner);
  FOR i := 0 TO count-1 DO
    node := B.Word(reader); state := B.Word(reader);
    IF ~B.Good(reader) OR (node < 0) OR (node >= store.nodes) OR ((state # 0) & (state # 1)) OR
        ~B.Text(reader, header.itemID) OR ~B.Text(reader, header.id) THEN RETURN FALSE END;
    IF state = 1 THEN
      IF ~B.Text(reader, header.author) OR ~B.Text(reader, header.title) OR
          ~B.Text(reader, header.published) OR ~B.Text(reader, header.updated) OR
          ~B.Text(reader, header.replyTo) OR ~B.Text(reader, text) THEN RETURN FALSE END;
      post := P.New(header, text);
      IF (PutOwner(store, store.destinations[node].name^, post) # okay) OR (store.used # i+1) THEN RETURN FALSE END
    ELSE
      IF ~P.Token(header.itemID, P.maxItemBytes) OR ~P.Reference(header.id, FALSE) THEN RETURN FALSE END;
      FOR j := 0 TO store.used-1 DO
        IF (store.posts[j].itemID^ = header.itemID) OR (store.posts[j].id^ = header.id) THEN RETURN FALSE END
      END;
      size := Length(header.itemID)+Length(header.id);
      IF size > store.byteLimit-store.bytes THEN RETURN FALSE END;
      store.posts[i].node := node; store.posts[i].itemID := Items.Copy8(header.itemID);
      store.posts[i].id := Items.Copy8(header.id); INC(store.used); INC(store.bytes, size)
    END
  END;
  RETURN TRUE
END ReadSlots;

PROCEDURE DecodeOwner*(data: Items.Bytes; length: LONGINT; owner: ARRAY OF CHAR): Store;
VAR reader: B.Reader; store: Store; magic: ARRAY 9 OF CHAR; found: ARRAY 65 OF CHAR;
  nodeLimit, postLimit, byteLimit, nodes, posts: LONGINT;
BEGIN
  IF ~P.Owner(owner) OR ~B.Checked(data, length) THEN RETURN NIL END;
  B.OpenReader(reader, data, length-4);
  IF ~B.Text(reader, magic) OR (magic # "BAREVPS1") OR ~B.Text(reader, found) OR (found # owner) THEN RETURN NIL END;
  nodeLimit := B.Word(reader); postLimit := B.Word(reader); byteLimit := B.Word(reader);
  nodes := B.Word(reader); posts := B.Word(reader);
  IF ~B.Good(reader) OR (nodes < 0) OR (nodes > nodeLimit) OR (posts < 0) OR (posts > postLimit) THEN RETURN NIL END;
  store := New(owner, nodeLimit, postLimit, byteLimit); IF store = NIL THEN RETURN NIL END;
  IF ~ReadNodes(store, reader, nodes) OR ~ReadSlots(store, reader, posts) OR ~B.End(reader) THEN
    Close(store); RETURN NIL
  END;
  RETURN store
END DecodeOwner;

END BarevPostStore.
