MODULE TestNetwork;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Deterministic policy checks: no sockets, host clock or native bindings. *)

IMPORT N := BarevNetwork, A := BarevAddress, Out;

VAR checks, firstBad: LONGINT; phase: ARRAY 32 OF CHAR;

PROCEDURE Check(value: BOOLEAN);
BEGIN
  INC(checks);
  IF ~value & (firstBad = 0) THEN
    firstBad := checks; Out.String("Network check failed in "); Out.String(phase);
    Out.String(": "); Out.Int(checks, 0); Out.Ln
  END
END Check;

PROCEDURE Scheduling;
  VAR local, peer, result: A.IP; i, socket, replacement: LONGINT; now: HUGEINT; short: ARRAY 15 OF CHAR;
BEGIN
  Check(A.ParseIP("200::1", local)); Check(A.ParseIP("200::2", peer));
  Check(~N.Open(0, local)); Check(N.Open(1001, local)); Check(~N.Open(1001, local));
  N.AddContact(1001, 1, peer); Check(N.Destination(1001, 1, result) = N.defaultPort);
  Check(A.Equal(peer, result)); Check(N.Destination(1001, 2, result) = 0);
  Check(N.Destination(1001, 1, short) = 0);
  Check(~N.SetPort(1001, 1, 0)); Check(~N.SetPort(1001, 1, 65536)); Check(~N.SetPort(1001, 2, 1234));
  Check(N.SetPort(1001, 1, 5299)); Check(N.Destination(1001, 1, result) = 5299);
  now := 4000000000000;
  Check(N.NextDial(1001, now) = 1); Check(N.NextDial(1001, now) = 0);
  Check(N.NextDial(1001, now+4999999) = 0); INC(now, 5000000); Check(N.NextDial(1001, now) = 1);
  Check(N.NextDial(1001, now+9999999) = 0); INC(now, 10000000); Check(N.NextDial(1001, now) = 1);
  Check(N.NextDial(1001, now+19999999) = 0); INC(now, 20000000); Check(N.NextDial(1001, now) = 1);
  FOR i := 0 TO 2 DO
    Check(N.NextDial(1001, now+29999999) = 0); INC(now, 30000000); Check(N.NextDial(1001, now) = 1)
  END;
  Check(N.NextDial(1001, -1) = 0); Check(N.NextDial(1001, 0) = 0);
  socket := N.NewSocket(1001, 1, now); Check(socket > 0);
  Check(N.NewSocket(1001, 1, now) = 0);
  Check(N.Owns(socket, 1001, 1)); Check(~N.Owns(socket, 1002, 1)); Check(~N.Owns(socket, 1001, 0));
  N.RequestDial(1001, 1); Check(N.NextDial(1001, now+30000000) = 0);
  N.DropSocket(socket); N.Online(1001, 1, TRUE); Check(N.NextDial(1001, now+30000000) = 0);
  Check(N.NewSocket(1001, 1, now) = 0); Check(~N.Owns(socket, 1001, 1));
  N.Online(1001, 1, FALSE); INC(now, 30000000); Check(N.NextDial(1001, now) = 1);
  Check(N.NextDial(1001, now+4999999) = 0); INC(now, 5000000); Check(N.NextDial(1001, now) = 1);
  N.RequestDial(1001, 1); Check(N.NextDial(1001, now) = 0); INC(now); Check(N.NextDial(1001, now) = 1);
  Check(N.Open(1002, local)); N.AddContact(1002, 1, peer); Check(N.NextDial(1002, now) = 1);
  socket := N.NewSocket(1001, 1, now); N.RemoveContact(1001, 1);
  Check(N.NextDial(1001, now+30000000) = 0); Check(N.Expired(socket, now));
  N.AddContact(1001, 1, peer); replacement := N.NewSocket(1001, 1, now); Check(replacement > socket);
  N.DropSocket(socket); Check(~N.Expired(replacement, now)); N.DropSocket(replacement);
  Check(N.NextDial(1001, MAX(HUGEINT)) = 1); Check(N.NextDial(1001, MAX(HUGEINT)) = 0);
  N.Close(1001); N.Close(1002); Check(N.NextDial(1001, now) = 0);
  FOR i := 1 TO N.maxAccounts DO Check(N.Open(2000+i, local)) END;
  Check(~N.Open(3000, local)); FOR i := 1 TO N.maxAccounts DO N.Close(2000+i) END
END Scheduling;

PROCEDURE Timing;
  VAR local, peer: A.IP; token, newer, i: LONGINT; held: ARRAY N.maxSockets OF LONGINT; now: HUGEINT;
BEGIN
  Check(A.ParseIP("200::1", local)); Check(A.ParseIP("200::2", peer)); Check(N.Open(1001, local));
  N.AddContact(1001, 1, peer); now := 4000000000000;
  Check(N.Advance(1001, now) = 0); Check(N.Advance(1001, now+999999) = 0);
  Check(N.Advance(1001, now+1500000) = 1); Check(N.Advance(1001, now+2000000) = 1);
  Check(N.Advance(1001, now) = 0); Check(N.Advance(1001, -1) = 0);
  Check(N.Advance(1001, now+602000000) = 300); Check(N.Advance(1001, now+602000000) = 300);
  Check(N.Advance(1001, now+602000000) = 0);
  token := N.NewSocket(1001, 1, now); Check(token > 0);
  Check(N.Expired(token, -1));
  Check(~N.Expired(token, now+29999999)); Check(N.Expired(token, now+30000000));
  N.Ready(token); Check(~N.Expired(token, now+30000000)); Check(~N.Expired(token, MAX(HUGEINT)));
  Check(N.Receive(token, now, N.receiveBytesPerSecond)); Check(~N.Receive(token, now, 1));
  Check(~N.Receive(token, now-1000000, 1)); Check(~N.Receive(token, now, -1));
  Check(N.Receive(token, now+1000000, N.receiveBytesPerSecond)); Check(~N.Receive(token, now+1999999, 1));
  N.DropSocket(token); newer := N.NewSocket(1001, 0, now); Check(newer > token);
  Check(~N.Receive(token, now, 1)); Check(N.Expired(token, now)); N.Ready(token);
  Check(N.Expired(newer, now+30000000)); N.DropSocket(newer);
  Check(N.NewSocket(1001, -1, now) = 0); Check(N.NewSocket(1001, 2, now) = 0);
  Check(N.NewSocket(1001, 1, -1) = 0);
  FOR i := 0 TO N.maxSockets-1 DO held[i] := N.NewSocket(1001, 0, now); Check(held[i] > 0) END;
  Check(N.NewSocket(1001, 0, now) = 0); N.Close(1001);
  FOR i := 0 TO N.maxSockets-1 DO Check(N.Expired(held[i], now)) END;
  Check(N.Open(1001, local)); token := N.NewSocket(1001, 0, MAX(HUGEINT));
  Check(~N.Expired(token, MAX(HUGEINT))); N.Close(1001)
END Timing;

PROCEDURE Endpoints;
  VAR local, peer, other, result: A.IP; selection: A.Selection; token: LONGINT;
BEGIN
  Check(A.ParseIP("200::1", local)); Check(A.ParseIP("200::2", peer)); Check(A.ParseIP("300::3", other));
  Check(A.Port(1) & A.Port(65535)); Check(~A.Port(0) & ~A.Port(65536) & ~A.Port(-1));
  Check(A.BeginSelection(selection, "")); Check(~A.Selected(selection, result));
  Check(A.NeedCandidates(selection));
  A.Consider(selection, "short", 0); A.Consider(selection, local, 1); Check(~A.Selected(selection, result));
  A.Consider(selection, local, 0); A.Consider(selection, local, 0); Check(A.Selected(selection, result) & A.Equal(result, local));
  A.Consider(selection, peer, 0); A.Consider(selection, local, 0); Check(~A.Selected(selection, result));
  Check(A.BeginSelection(selection, "0200:0:0:0:0:0:0:1"));
  Check(~A.NeedCandidates(selection));
  A.Consider(selection, peer, 0); Check(A.Selected(selection, result) & A.Equal(result, local));
  Check(~A.BeginSelection(selection, "::1")); A.Consider(selection, local, 0); Check(~A.Selected(selection, result));
  Check(~A.BeginSelection(selection, "200::1%eth0"));
  Check(A.BeginSelection(selection, "")); Check(A.ParseIP("::1", result));
  A.Consider(selection, result, 0); Check(~A.Selected(selection, result));
  Check(A.SocketEndpoints(local, peer, local, peer, 0, 0, TRUE));
  Check(~A.SocketEndpoints(local, other, local, peer, 0, 0, TRUE));
  Check(A.SocketEndpoints(local, other, local, peer, 0, 0, FALSE));
  Check(~A.SocketEndpoints(other, peer, local, peer, 0, 0, TRUE));
  Check(~A.SocketEndpoints(local, peer, local, peer, 1, 0, TRUE));
  Check(~A.SocketEndpoints(local, peer, local, peer, 0, MAX(HUGEINT), TRUE));
  Check(~A.SocketEndpoints("short", peer, local, peer, 0, 0, TRUE));
  Check(A.ParseIP("::1", other)); Check(~A.SocketEndpoints(local, other, local, peer, 0, 0, FALSE));
  Check(N.Open(1001, local)); N.AddContact(1001, 1, peer); token := N.NewSocket(1001, 1, 0);
  Check(N.SocketEndpoints(token, local, peer, 0, 0)); Check(~N.SocketEndpoints(token, peer, local, 0, 0));
  N.RemoveContact(1001, 1); Check(~N.SocketEndpoints(token, local, peer, 0, 0)); N.Close(1001)
END Endpoints;

PROCEDURE Run*(): LONGINT;
BEGIN
  checks := 0; firstBad := 0;
  phase := "scheduling"; Scheduling; phase := "timing"; Timing; phase := "endpoints"; Endpoints;
  IF firstBad # 0 THEN RETURN -firstBad END;
  RETURN checks
END Run;

END TestNetwork.
