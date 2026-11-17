MODULE TestPeerPins;
(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT P := BarevPeerPins, Args, Out;
VAR profile: ARRAY 4096 OF CHAR; own, expected, replacement: ARRAY 258 OF CHAR;
  peer: ARRAY 512 OF CHAR; identifier: P.Identifier; fingerprint: P.Fingerprint; status: LONGINT;
BEGIN
  Args.Get(1, profile); Args.Get(2, own); Args.Get(3, peer);
  IF Args.argc = 6 THEN
    Args.Get(4, expected); Args.Get(5, replacement);
    status := P.Save(profile, own, peer, expected, replacement)
  ELSE status := P.Load(profile, own, peer, identifier, fingerprint)
  END;
  Out.Int(status, 0); Out.Ln;
  IF (Args.argc = 4) & (status = P.okay) THEN Out.String(identifier); Out.Ln; Out.String(fingerprint); Out.Ln END
END TestPeerPins.
