MODULE BarevPostIOHost;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT SYSTEM, I := XmppItems;

CONST maxBytes* = 6291456; maxJobs* = 4;
  okay* = 0; missing* = 1; invalid* = 2; storageError* = 3; changed* = 4; pending* = 5;

PROCEDURE -AAinclude '#include "post-io.h"';
PROCEDURE -NativeStart(): LONGINT "BarevPostIO_Start()";
PROCEDURE -NativeRead(profile, owner: ARRAY OF CHAR): LONGINT
  "BarevPostIO_Read((char*)profile, (char*)owner)";
PROCEDURE -NativeReplace(profile, owner: ARRAY OF CHAR; VAR expected: ARRAY OF CHAR; expectedLength: LONGINT;
    VAR replacement: ARRAY OF CHAR; replacementLength: LONGINT): LONGINT
  "BarevPostIO_Replace((char*)profile, (char*)owner, (unsigned char*)expected, expectedLength, (unsigned char*)replacement, replacementLength)";
PROCEDURE -NativeStatus(handle: LONGINT): LONGINT "BarevPostIO_Status(handle)";
PROCEDURE -NativeLength(handle: LONGINT): LONGINT "BarevPostIO_Length(handle)";
PROCEDURE -NativeCopy(handle: LONGINT; VAR bytes: ARRAY OF CHAR; capacity: LONGINT): LONGINT
  "BarevPostIO_Copy(handle, (unsigned char*)bytes, capacity)";
PROCEDURE -NativeRelease(handle: LONGINT) "BarevPostIO_Release(handle)";
PROCEDURE -NativeStop "BarevPostIO_Stop()";
PROCEDURE -NativeIdle(): LONGINT "BarevPostIO_Idle()";

PROCEDURE Names(profile, owner: ARRAY OF CHAR): BOOLEAN;
VAR n: LONGINT;
BEGIN
  IF (LEN(owner) < 65) OR (owner[64] # 0X) THEN RETURN FALSE END;
  n := 0; WHILE (n < LEN(profile)) & (n <= 3800) & (profile[n] # 0X) DO INC(n) END;
  RETURN (n < LEN(profile)) & (n <= 3800)
END Names;

PROCEDURE Start*(): BOOLEAN;
BEGIN RETURN NativeStart() # 0 END Start;

PROCEDURE Read*(profile, owner: ARRAY OF CHAR): LONGINT;
BEGIN IF ~Names(profile, owner) THEN RETURN 0 END; RETURN NativeRead(profile, owner) END Read;

PROCEDURE Replace*(profile, owner: ARRAY OF CHAR; expected: I.Bytes; expectedLength: LONGINT;
    replacement: I.Bytes; replacementLength: LONGINT): LONGINT;
VAR empty: ARRAY 1 OF CHAR;
BEGIN
  IF ~Names(profile, owner) OR (expectedLength < -1) OR (expectedLength > maxBytes) OR
      (replacementLength < 0) OR (replacementLength > maxBytes) THEN RETURN 0 END;
  IF expectedLength > 0 THEN
    IF (expected = NIL) OR (expectedLength > LEN(expected^)) THEN RETURN 0 END
  END;
  IF replacementLength > 0 THEN
    IF (replacement = NIL) OR (replacementLength > LEN(replacement^)) THEN RETURN 0 END
  END;
  empty[0] := 0X;
  IF expected = NIL THEN
    IF replacement = NIL THEN RETURN NativeReplace(profile, owner, empty, expectedLength, empty, replacementLength) END;
    RETURN NativeReplace(profile, owner, empty, expectedLength, replacement^, replacementLength)
  END;
  IF replacement = NIL THEN RETURN NativeReplace(profile, owner, expected^, expectedLength, empty, replacementLength) END;
  RETURN NativeReplace(profile, owner, expected^, expectedLength, replacement^, replacementLength)
END Replace;

PROCEDURE Status*(handle: LONGINT): LONGINT;
BEGIN RETURN NativeStatus(handle) END Status;

PROCEDURE Length*(handle: LONGINT): LONGINT;
BEGIN RETURN NativeLength(handle) END Length;

PROCEDURE Copy*(handle: LONGINT; VAR bytes: ARRAY OF CHAR): LONGINT;
BEGIN RETURN NativeCopy(handle, bytes, LEN(bytes)) END Copy;

PROCEDURE Release*(VAR handle: LONGINT);
BEGIN NativeRelease(handle); handle := 0 END Release;

PROCEDURE Stop*;
BEGIN NativeStop END Stop;

PROCEDURE Idle*(): BOOLEAN;
BEGIN RETURN NativeIdle() # 0 END Idle;

END BarevPostIOHost.
