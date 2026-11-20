MODULE BarevPostFiles;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
IMPORT S := BarevPostStore, P := BarevPost, B := BarevPostBinary, I := XmppItems,
  Private := BarevIdentityFiles, F := oocFiles, Channel, Platform, PlatformNative;

CONST okay* = 0; missing* = 1; invalid* = 2; storageError* = 3; changed* = 4;

TYPE
  Path = ARRAY 4096 OF CHAR;
  Context* = POINTER TO ContextDesc;
  ContextDesc* = RECORD
    profile, path: Path; owner: ARRAY 65 OF CHAR;
    image: I.Bytes; length: LONGINT; baseline: S.Store; active: BOOLEAN
  END;

PROCEDURE Locate(profile, owner: ARRAY OF CHAR; VAR base, path: Path): BOOLEAN;
VAR n, i: LONGINT; prefix: ARRAY 14 OF CHAR;
BEGIN
  IF ~P.Owner(owner) THEN RETURN FALSE END;
  n := 0;
  WHILE (n < LEN(profile)) & (profile[n] # 0X) DO
    IF n = 3800 THEN RETURN FALSE END;
    INC(n)
  END;
  IF (n = LEN(profile)) OR (n < 2) OR (profile[0] # "/") THEN RETURN FALSE END;
  WHILE (n > 1) & (profile[n-1] = "/") DO DEC(n) END;
  IF n = 1 THEN RETURN FALSE END;
  FOR i := 0 TO n-1 DO base[i] := profile[i]; path[i] := profile[i] END;
  base[n] := 0X; prefix := "/barev/posts-";
  FOR i := 0 TO 12 DO path[n+i] := prefix[i] END; INC(n, 13);
  FOR i := 0 TO 63 DO path[n+i] := owner[i] END; INC(n, 64);
  path[n] := "."; path[n+1] := "s"; path[n+2] := "t"; path[n+3] := "a";
  path[n+4] := "t"; path[n+5] := "e"; path[n+6] := 0X; RETURN TRUE
END Locate;

PROCEDURE Read(path: Path; owner: ARRAY OF CHAR; VAR bytes: I.Bytes; VAR length: LONGINT): LONGINT;
VAR file: F.File; reader: Channel.Reader; result: F.Result;
  error, status: LONGINT; kind: INTEGER; checked: S.Store;
BEGIN
  bytes := NIL; length := 0;
  error := PlatformNative.PathKind(path, FALSE, kind);
  IF error # 0 THEN
    IF Platform.Absent(SHORT(error)) THEN RETURN missing END;
    RETURN storageError
  END;
  IF kind # 2 THEN RETURN storageError END;
  file := F.Old(path, {F.read}, result); IF file = NIL THEN RETURN storageError END;
  length := file.Length(); status := invalid;
  IF file.res # F.done THEN status := storageError
  ELSIF (length >= 4) & (length <= S.maxSnapshotBytes) THEN
    NEW(bytes, length); reader := file.NewReader(); reader.ReadBytes(bytes^, 0, length);
    IF reader.res # F.done THEN status := storageError
    ELSE
      checked := S.DecodeOwner(bytes, length, owner);
      IF checked # NIL THEN status := okay; S.Close(checked) END
    END
  END;
  file.Close;
  IF file.res # F.done THEN status := storageError END;
  IF status # okay THEN bytes := NIL; length := 0 END;
  RETURN status
END Read;

PROCEDURE Close*(VAR context: Context);
BEGIN
  IF context = NIL THEN RETURN END;
  context.active := FALSE; S.Close(context.baseline); context.image := NIL;
  context.length := 0; context := NIL
END Close;

PROCEDURE Load*(profile, owner: ARRAY OF CHAR; VAR context: Context; VAR store: S.Store): LONGINT;
VAR base, path: Path; bytes: I.Bytes; length, handle, status: LONGINT;
  next: Context; loaded: S.Store;
BEGIN
  IF ~Locate(profile, owner, base, path) THEN RETURN invalid END;
  handle := Private.Open(base); IF handle < 0 THEN RETURN storageError END;
  status := Read(path, owner, bytes, length); Private.Close(handle);
  IF (status # okay) & (status # missing) THEN RETURN status END;
  NEW(next); next.profile := base; next.path := path; COPY(owner, next.owner);
  next.image := bytes; next.length := length; next.active := TRUE; loaded := NIL;
  IF status = okay THEN
    next.baseline := S.DecodeOwner(bytes, length, owner);
    loaded := S.DecodeOwner(bytes, length, owner);
    IF (next.baseline = NIL) OR (loaded = NIL) THEN
      Close(next); S.Close(loaded); RETURN invalid
    END
  END;
  context := next; store := loaded;
  RETURN status
END Load;

PROCEDURE Replace(path: Path; bytes: I.Bytes; length, handle: LONGINT): LONGINT;
VAR file: F.File; writer: Channel.Writer; result: F.Result; status: LONGINT;
BEGIN
  file := F.Tmp(path, {F.write}, result); IF file = NIL THEN RETURN storageError END;
  writer := file.NewWriter(); writer.WriteBytes(bytes^, 0, length); status := storageError;
  IF writer.res = F.done THEN
    file.Register;
    IF file.res = F.done THEN
      IF Platform.Sync(handle) = 0 THEN status := okay END
    END
  END;
  file.Close;
  IF file.res # F.done THEN status := storageError END;
  RETURN status
END Replace;

PROCEDURE Save*(context: Context; store: S.Store): LONGINT;
VAR bytes, current: I.Bytes; length, currentLength, handle, status: LONGINT; baseline: S.Store;
BEGIN
  IF (context = NIL) OR ~context.active OR ~S.OwnedBy(store, context.owner) THEN RETURN invalid END;
  IF (context.baseline # NIL) & ~S.ExtendsOwner(context.baseline, store) THEN RETURN changed END;
  IF ~S.EncodeOwner(store, bytes, length) THEN RETURN invalid END;
  baseline := S.DecodeOwner(bytes, length, context.owner); IF baseline = NIL THEN RETURN invalid END;
  handle := Private.Open(context.profile);
  IF handle < 0 THEN S.Close(baseline); RETURN storageError END;
  status := Read(context.path, context.owner, current, currentLength);
  IF (status = okay) OR (status = missing) THEN
    IF B.Equal(current, currentLength, bytes, length) THEN status := okay
    ELSIF ~B.Equal(current, currentLength, context.image, context.length) THEN status := changed
    ELSE status := Replace(context.path, bytes, length, handle)
    END
  END;
  Private.Close(handle);
  IF status = okay THEN
    S.Close(context.baseline); context.baseline := baseline;
    context.image := bytes; context.length := length
  ELSE S.Close(baseline)
  END;
  RETURN status
END Save;

END BarevPostFiles.
