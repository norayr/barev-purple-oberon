MODULE TestFeedAccess;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT F := BarevFeedAccess, A := BarevAddress, Out, IntStr, Strings := oocStrings, Heap;

VAR checks, failed, index: LONGINT;
  names: ARRAY F.maxMembers+1 OF F.Name;
  groups: ARRAY F.maxGroups+1 OF F.Name;
  key, changed: ARRAY 32 OF CHAR;
  node, public, selected, group, nobody, other: F.Node;
  contact, current, stranger, moved, replacement: F.Contact;

PROCEDURE Check(value: BOOLEAN; message: ARRAY OF CHAR);
BEGIN
  INC(checks);
  IF ~value THEN INC(failed); Out.String(message); Out.Ln END
END Check;

PROCEDURE Policies;
VAR reader: F.Reader; i: LONGINT;
BEGIN
  names[0] := "reader@200::1"; names[1] := "other@200::2";
  groups[0] := "friends"; groups[1] := "family";
  public := F.NewNode(F.open, names, 0);
  selected := F.NewNode(F.whitelist, names, 1);
  group := F.NewNode(F.roster, groups, 1);
  nobody := F.NewNode(F.whitelist, names, 0);
  other := F.NewNode(F.roster, groups, 0);
  Check((public # NIL) & (selected # NIL) & (group # NIL), "constructing access models");
  Check((F.Model(public) = F.open) & (F.Model(selected) = F.whitelist) &
    (F.Model(group) = F.roster) & (F.Model(NIL) = F.denied), "explicit access models");
  current := F.NewContact("reader@200::1", key, TRUE, groups, 1);
  stranger := F.NewContact("other@200::2", key, TRUE, groups, 1);
  Check((current # NIL) & (stranger # NIL), "current authorized contact snapshots");
  Heap.GC(FALSE);
  Check((F.Model(public) = F.open) & (F.Model(selected) = F.whitelist) &
    (F.Model(group) = F.roster), "retaining rooted policy snapshots across collection");
  F.Close(reader);
  Check(~F.CanRead(public, reader, current), "closed reader cannot read public node");
  NEW(node);
  Check(~F.CanRead(node, reader, current), "unconfigured node denies access");
  F.Anonymous(reader);
  Check(F.CanRead(public, reader, NIL), "anonymous public access without contact");
  Check(F.CanRead(public, reader, current), "public reading independent of contacts");
  Check(~F.CanRead(selected, reader, current) & ~F.CanRead(group, reader, current),
    "anonymous reader cannot borrow a contact snapshot");
  Check(~F.CanRead(NIL, reader, current) & ~F.CanRead(node, reader, current), "invalid policies deny access");
  Check(F.Authenticate(reader, "reader@200::1", key, TRUE, TRUE), "capturing authenticated connection");
  Check(F.CanRead(public, reader, NIL), "authenticated public access without private consent");
  Check(F.CanRead(selected, reader, current) & F.CanRead(group, reader, current), "private audience access");
  Check(~F.CanRead(selected, reader, NIL) & ~F.CanRead(group, reader, NIL), "missing current contact denies private access");
  Check(~F.CanRead(selected, reader, stranger) & ~F.CanRead(group, reader, stranger), "same key on another contact grants no access");
  Check(~F.CanRead(nobody, reader, current) & ~F.CanRead(other, reader, current), "empty private audience denies access");
  moved := F.NewContact("reader@200::1", key, TRUE, groups, 0);
  Check(~F.CanRead(group, reader, moved), "removing group membership takes effect on next check");
  Check(F.CanRead(selected, reader, moved), "whitelist independent of group membership");
  Check(F.CanRead(group, reader, current), "adding group membership grants retained-history access");
  names[0] := "other@200::2"; other := F.NewNode(F.whitelist, names, 1);
  Check(~F.CanRead(other, reader, current), "whitelist replacement withdraws previous membership");
  groups[0] := "family"; other := F.NewNode(F.roster, groups, 1);
  Check(~F.CanRead(other, reader, current), "node group configuration checked independently");
  groups[1] := "friends"; other := F.NewNode(F.roster, groups, 2);
  Check(F.CanRead(other, reader, current), "membership in any selected group grants access");
  FOR i := 0 TO 31 DO
    changed := key; changed[i] := CHR((ORD(key[i])+1) MOD 256);
    contact := F.NewContact("reader@200::1", changed, TRUE, groups, 2);
    Check(~F.CanRead(selected, reader, contact) & ~F.CanRead(group, reader, contact), "every captured key byte must match the current pin");
    Check(F.CanRead(public, reader, contact), "pin changes cannot make public nodes private")
  END;
  Check(F.Authenticate(reader, "reader@200::1", changed, TRUE, TRUE), "authenticating replacement key on a new connection");
  Check(F.CanRead(selected, reader, contact) & F.CanRead(group, reader, contact), "newly authenticated approved key restores access");
  Check(~F.CanRead(selected, reader, current), "new session cannot use old pin");
  Check(F.Authenticate(reader, "reader@200::1", key, TRUE, TRUE), "recapturing original connection");
  names[0] := "attacker@200::1"; names[1] := "reader@200::2";
  FOR i := 0 TO 1 DO
    contact := F.NewContact(names[i], key, TRUE, groups, 2);
    Check(~F.CanRead(selected, reader, contact) & ~F.CanRead(group, reader, contact), "nickname and address must both match")
  END;
  names[0] := "reader@200::1"; names[1] := "family";
  groups[0] := "changed";
  Check(F.CanRead(selected, reader, current) & F.CanRead(group, reader, current), "policy snapshots copy their input arrays");
  F.Close(reader);
  Check(~F.CanRead(public, reader, current) & ~F.CanRead(group, reader, current), "disconnect withdraws all session access");
  F.Anonymous(reader);
  Check(~F.CanRead(group, reader, current), "anonymous reconnect cannot reuse captured private identity")
END Policies;

PROCEDURE CapturedKeys;
VAR reader: F.Reader; captured, pin: ARRAY 32 OF CHAR;
BEGIN
  names[0] := "reader@200::1"; groups[0] := "friends";
  node := F.NewNode(F.whitelist, names, 1);
  pin := key; captured := key;
  contact := F.NewContact(names[0], pin, TRUE, groups, 1);
  Check(F.Authenticate(reader, names[0], captured, TRUE, TRUE), "capturing binary key containing zero bytes");
  pin[31] := 0FFX; captured[0] := 0FFX;
  Heap.GC(FALSE);
  Check(F.CanRead(node, reader, contact), "contact and session copy binary input keys");
  replacement := F.NewContact(names[0], pin, TRUE, groups, 1);
  Check(~F.CanRead(node, reader, replacement), "current replacement snapshot revokes captured old key");
  Check(~F.Authenticate(reader, names[0], captured, TRUE, FALSE), "failed SASL cannot retain old authority");
  Check(~F.CanRead(node, reader, contact), "failed recapture clears previous identity");
  F.Close(reader)
END CapturedKeys;

PROCEDURE Authentication;
VAR reader: F.Reader; i: LONGINT;
  short: ARRAY 31 OF CHAR; long: ARRAY 33 OF CHAR; empty: ARRAY 1 OF CHAR;
  unterminated: ARRAY 8 OF CHAR;
BEGIN
  names[0] := "reader@200::1"; groups[0] := "friends";
  node := F.NewNode(F.whitelist, names, 1);
  contact := F.NewContact(names[0], key, TRUE, groups, 1);
  FOR i := 0 TO 3 DO
    Check(F.Authenticate(reader, names[0], key, TRUE, TRUE), "starting authenticated session");
    Check(F.Authenticate(reader, names[0], key, ODD(i), i >= 2) = (i = 3), "requiring both mutual TLS and SASL EXTERNAL");
    Check(F.CanRead(node, reader, contact) = (i = 3), "failed authentication clears old session authority")
  END;
  empty[0] := 0X;
  FOR i := 0 TO 30 DO short[i] := key[i] END;
  FOR i := 0 TO 31 DO long[i] := key[i] END; long[32] := 0X;
  Check(~F.Authenticate(reader, names[0], short, TRUE, TRUE), "rejecting truncated captured key");
  Check(~F.Authenticate(reader, names[0], long, TRUE, TRUE), "rejecting oversized captured key");
  Check(~F.Authenticate(reader, names[0], empty, TRUE, TRUE), "rejecting missing captured key");
  Check(~F.Authenticate(reader, "reader@example.org", key, TRUE, TRUE), "rejecting non-Barev contact identity");
  Check(~F.Authenticate(reader, "reader@200::1/resource", key, TRUE, TRUE), "resource text cannot replace canonical contact identity");
  Check(~F.Authenticate(reader, "", key, TRUE, TRUE), "rejecting empty contact identity");
  FOR i := 0 TO 7 DO unterminated[i] := "x" END;
  Check(~F.Authenticate(reader, unterminated, key, TRUE, TRUE), "rejecting unterminated identity");
  Check(F.NewContact(names[0], key, FALSE, groups, 1) = NIL, "manual chat authorization remains required");
  Check(F.NewContact(names[0], empty, TRUE, groups, 1) = NIL, "missing pin denies contact snapshot");
  Check(F.NewContact(names[0], long, TRUE, groups, 1) = NIL, "pin size is exact");
  Check(F.NewContact("reader@example.org", key, TRUE, groups, 1) = NIL, "invalid saved identity denies contact snapshot");
  Check(F.Authenticate(reader, "reader@0200:0:0:0:0:0:0:1", key, TRUE, TRUE), "canonicalizing captured contact address");
  Check(F.CanRead(node, reader, contact), "equivalent numeric address matches current contact");
  Check(A.EncodedIdentity(names[0], names[1]), "encoding contact address");
  contact := F.NewContact(names[1], key, TRUE, groups, 1);
  Check(F.CanRead(node, reader, contact), "encoded contact address matches numeric session");
  node := F.NewNode(F.whitelist, names, 1);
  Check(F.Authenticate(reader, names[1], key, TRUE, TRUE) & F.CanRead(node, reader, contact), "encoded session matches numeric whitelist");
  contact := F.NewContact("Reader@200::1", key, TRUE, groups, 1);
  Check(~F.CanRead(node, reader, contact), "contact nicknames remain case sensitive");
  F.Close(reader)
END Authentication;

PROCEDURE Configuration;
VAR reader: F.Reader; i: LONGINT;
  number: ARRAY 16 OF CHAR;
BEGIN
  names[0] := "reader@200::1"; names[1] := "reader@0200:0:0:0:0:0:0:1";
  groups[0] := "friends"; groups[1] := "friends";
  Check(F.NewNode(-1, names, 0) = NIL, "rejecting negative access model");
  Check(F.NewNode(F.denied, names, 0) = NIL, "requiring explicit supported access model");
  Check(F.NewNode(4, names, 0) = NIL, "rejecting unknown access model");
  Check(F.NewNode(F.open, names, 1) = NIL, "public policy cannot silently discard private audience");
  Check(F.NewNode(F.roster, groups, -1) = NIL, "rejecting negative group count");
  Check(F.NewNode(F.whitelist, names, F.maxMembers+2) = NIL, "rejecting count beyond supplied names");
  Check(F.NewNode(F.whitelist, names, F.maxMembers+1) = NIL, "bounding node members");
  Check(F.NewNode(F.whitelist, names, MAX(LONGINT)) = NIL, "rejecting overflowing node count before indexing");
  Check(F.NewNode(F.roster, groups, F.maxGroups+1) = NIL, "bounding node groups");
  Check(F.NewNode(F.whitelist, names, 2) = NIL, "rejecting canonically duplicate whitelist members");
  Check(F.NewNode(F.roster, groups, 2) = NIL, "rejecting duplicate node groups");
  Check(F.NewContact(names[0], key, TRUE, groups, 2) = NIL, "rejecting duplicate contact groups");
  Check(F.NewContact(names[0], key, TRUE, groups, -1) = NIL, "rejecting negative contact group count");
  Check(F.NewContact(names[0], key, TRUE, groups, F.maxGroups+2) = NIL, "rejecting count beyond supplied contact groups");
  Check(F.NewContact(names[0], key, TRUE, groups, F.maxGroups+1) = NIL, "bounding contact groups");
  Check(F.NewContact(names[0], key, TRUE, groups, MAX(LONGINT)) = NIL, "rejecting overflowing contact count before indexing");
  names[0] := "invalid";
  Check(F.NewNode(F.whitelist, names, 1) = NIL, "rejecting invalid whitelist member");
  names[0] := "reader@200::1";
  FOR i := 0 TO 5 DO
    CASE i OF
    | 0: groups[0] := ""
    | 1: groups[0][0] := 1X; groups[0][1] := 0X
    | 2: groups[0][0] := 0C2X; groups[0][1] := 85X; groups[0][2] := 0X
    | 3: groups[0][0] := 0C0X; groups[0][1] := 0AFX; groups[0][2] := 0X
    | 4: groups[0][0] := 0EDX; groups[0][1] := 0A0X; groups[0][2] := 80X; groups[0][3] := 0X
    | 5: groups[0][0] := 0FFX; groups[0][1] := 0X
    ELSE HALT(100)
    END;
    Check(F.NewNode(F.roster, groups, 1) = NIL, "rejecting invalid group label in node");
    Check(F.NewContact(names[0], key, TRUE, groups, 1) = NIL, "rejecting invalid group label in contact")
  END;
  FOR i := 0 TO LEN(groups[0])-1 DO groups[0][i] := "x" END;
  Check(F.NewNode(F.roster, groups, 1) = NIL, "rejecting unterminated group label");
  groups[0][F.maxGroupBytes+1] := 0X;
  Check(F.NewNode(F.roster, groups, 1) = NIL, "bounding group label bytes");
  groups[0][F.maxGroupBytes] := 0X;
  node := F.NewNode(F.roster, groups, 1);
  contact := F.NewContact(names[0], key, TRUE, groups, 1);
  Check(F.Authenticate(reader, names[0], key, TRUE, TRUE) & F.CanRead(node, reader, contact), "accepting maximum-length group label");
  groups[0] := "ընկերներ 😀"; groups[1] := "Friends";
  node := F.NewNode(F.roster, groups, 1);
  contact := F.NewContact(names[0], key, TRUE, groups, 2);
  Check(F.CanRead(node, reader, contact), "matching Unicode group labels");
  groups[0] := "friends"; node := F.NewNode(F.roster, groups, 1);
  Check(~F.CanRead(node, reader, contact), "group labels remain case sensitive");
  FOR i := 0 TO F.maxGroups-1 DO
    IntStr.IntToStr(i, number); groups[i] := "group-"; Strings.Append(number, groups[i])
  END;
  node := F.NewNode(F.roster, groups, F.maxGroups);
  contact := F.NewContact(names[0], key, TRUE, groups, F.maxGroups);
  Check((node # NIL) & (contact # NIL) & F.CanRead(node, reader, contact), "accepting maximum group counts");
  groups[0] := groups[F.maxGroups-1]; node := F.NewNode(F.roster, groups, 1);
  Check(F.CanRead(node, reader, contact), "checking last contact group at the bound");
  FOR i := 0 TO F.maxMembers-1 DO
    IntStr.IntToStr(i, number); names[i] := "reader-";
    Strings.Append(number, names[i]); Strings.Append("@200::1", names[i])
  END;
  node := F.NewNode(F.whitelist, names, F.maxMembers);
  Check(node # NIL, "accepting maximum whitelist size");
  FOR i := 0 TO F.maxMembers-1 DO
    contact := F.NewContact(names[i], key, TRUE, groups, 0);
    Check(F.Authenticate(reader, names[i], key, TRUE, TRUE) & F.CanRead(node, reader, contact), "checking every bounded whitelist member")
  END;
  F.Close(reader)
END Configuration;

BEGIN
  FOR index := 0 TO 31 DO key[index] := CHR(index) END;
  Policies; CapturedKeys; Authentication; Configuration;
  Out.String("TestFeedAccess: "); Out.Int(checks, 0); Out.String(" checks, ");
  Out.Int(failed, 0); Out.String(" failed"); Out.Ln;
  IF failed # 0 THEN HALT(100) END
END TestFeedAccess.
