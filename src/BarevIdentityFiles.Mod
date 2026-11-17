MODULE BarevIdentityFiles;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Descriptor-based private storage; records are opaque to the native boundary. *)
IMPORT SYSTEM;

PROCEDURE -AAinclude '#include "identity-store.h"';
PROCEDURE -NativeOpen(profile: ARRAY OF CHAR): LONGINT "BarevIdentityFile_Open((char*)profile)";
PROCEDURE -NativeClose(handle: LONGINT) "BarevIdentityFile_Close(handle)";
PROCEDURE -NativeRead(handle, kind: LONGINT; name: ARRAY OF CHAR; VAR bytes: ARRAY OF CHAR; length: LONGINT): LONGINT
  "BarevIdentityFile_Read(handle, kind, (char*)name, (unsigned char*)bytes, length)";
PROCEDURE -NativeInstall(handle, kind: LONGINT; name: ARRAY OF CHAR; VAR bytes: ARRAY OF CHAR; length: LONGINT): LONGINT
  "BarevIdentityFile_Install(handle, kind, (char*)name, (unsigned char*)bytes, length)";

PROCEDURE Open*(profile: ARRAY OF CHAR): LONGINT;
VAR i: LONGINT;
BEGIN
  i := 0; WHILE (i < LEN(profile)) & (profile[i] # 0X) DO INC(i) END;
  IF i = LEN(profile) THEN RETURN -1 END;
  RETURN NativeOpen(profile)
END Open;

PROCEDURE Close*(handle: LONGINT);
BEGIN NativeClose(handle) END Close;

PROCEDURE Read*(handle, kind: LONGINT; name: ARRAY OF CHAR; VAR bytes: ARRAY OF CHAR; length: LONGINT): LONGINT;
BEGIN
  IF (LEN(name) < 65) OR (name[64] # 0X) OR (length < 0) OR (length > LEN(bytes)) THEN RETURN -1 END;
  RETURN NativeRead(handle, kind, name, bytes, length)
END Read;

PROCEDURE Install*(handle, kind: LONGINT; name: ARRAY OF CHAR; VAR bytes: ARRAY OF CHAR; length: LONGINT): LONGINT;
BEGIN
  IF (LEN(name) < 65) OR (name[64] # 0X) OR (length < 0) OR (length > LEN(bytes)) THEN RETURN -1 END;
  RETURN NativeInstall(handle, kind, name, bytes, length)
END Install;

END BarevIdentityFiles.
