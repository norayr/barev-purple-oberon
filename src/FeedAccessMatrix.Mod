MODULE FeedAccessMatrix;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT F := BarevFeedAccess, A := BarevAddress, Out;

VAR reader: F.Reader; node: F.Node; contact: F.Contact;
  model, audience, session, person, count, i: LONGINT;
  key, changed: ARRAY 32 OF CHAR;
  members: ARRAY 1 OF F.Name;
  selected, supplied: ARRAY 2 OF F.Name;
  encoded, peer: F.Name;
  authenticated: BOOLEAN;

BEGIN
  FOR i := 0 TO 31 DO key[i] := CHR(i) END;
  changed := key; changed[31] := CHR(255-ORD(key[31]));
  members[0] := "reader@200::1"; selected[0] := "ընկերներ 😀"; selected[1] := "family";
  IF ~A.EncodedIdentity(members[0], encoded) THEN HALT(100) END;
  Out.String("feed-matrix-v1"); Out.Ln;
  FOR model := F.open TO F.whitelist DO
    FOR audience := 0 TO 1 DO
      IF model = F.roster THEN node := F.NewNode(model, selected, audience*2)
      ELSIF model = F.open THEN node := F.NewNode(model, members, 0)
      ELSE node := F.NewNode(model, members, audience)
      END;
      IF node = NIL THEN HALT(100) END;
      FOR session := 0 TO 9 DO
        F.Close(reader);
        IF session = 1 THEN F.Anonymous(reader)
        ELSIF session >= 2 THEN
          CASE session OF
            4: peer := "other@200::2"
          | 5: peer := "reader@example.org"
          | 8: peer := encoded
          | 9: peer := "reader@0200:0:0:0:0:0:0:1"
          ELSE peer := members[0]
          END;
          IF session = 3 THEN authenticated := F.Authenticate(reader, peer, changed, TRUE, TRUE)
          ELSE authenticated := F.Authenticate(reader, peer, key, session # 7, session # 6)
          END;
          IF authenticated # ((session # 5) & (session # 6) & (session # 7)) THEN HALT(100) END
        END;
        FOR person := 0 TO 7 DO
          supplied := selected;
          IF person = 6 THEN supplied[0] := "friends" ELSIF person = 7 THEN supplied[0] := "family" END;
          peer := members[0]; IF person = 4 THEN peer := "other@200::2" END;
          count := 2; IF person = 2 THEN count := 0 ELSIF person >= 6 THEN count := 1 END;
          IF person = 0 THEN contact := NIL
          ELSIF person = 3 THEN contact := F.NewContact(peer, changed, TRUE, supplied, count)
          ELSE contact := F.NewContact(peer, key, person # 5, supplied, count)
          END;
          Out.Int(model, 0); Out.Char(" "); Out.Int(audience, 0); Out.Char(" ");
          Out.Int(session, 0); Out.Char(" "); Out.Int(person, 0); Out.Char(" ");
          IF F.CanRead(node, reader, contact) THEN Out.Char("1") ELSE Out.Char("0") END; Out.Ln
        END
      END
    END
  END
END FeedAccessMatrix.
