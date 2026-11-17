MODULE TestIdentity;
(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT I := BarevIdentity, Args, Out;
VAR key: I.Key; profile: ARRAY 4096 OF CHAR; account: ARRAY 258 OF CHAR;
  expected: ARRAY 258 OF CHAR; identifier: I.Identifier; fingerprint: I.Fingerprint; result: LONGINT;
BEGIN
  Args.Get(1, profile); Args.Get(2, account); Args.Get(3, expected);
  result := I.Open(profile, account, expected, key);
  Out.Int(result, 0); Out.Ln;
  IF result = I.okay THEN
    IF ~I.IdentifierOf(key, identifier) OR ~I.FingerprintOf(key, fingerprint) THEN HALT(2) END;
    Out.String(identifier); Out.Ln; Out.String(fingerprint); Out.Ln
  END;
  I.Clear(key);
  IF I.IdentifierOf(key, identifier) OR I.FingerprintOf(key, fingerprint) THEN HALT(3) END
END TestIdentity.
