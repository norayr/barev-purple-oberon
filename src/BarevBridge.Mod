MODULE BarevBridge;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Bounded, generation-checked state retained across native host callbacks. *)

IMPORT S := SYSTEM, Heap;

CONST
  maxSlots* = 32; maxBytes* = 4096;
  stackProbeObjects = 64;
  maxGeneration = (MAX(LONGINT)-maxSlots) DIV maxSlots;

TYPE
  Bytes = POINTER TO ARRAY OF CHAR;
  Session = POINTER TO RECORD
    owner: S.ADDRESS;
    bytes: Bytes;
    length, ticks: LONGINT
  END;
  Temporary = POINTER TO RECORD marker: LONGINT END;

VAR
  sessions: ARRAY maxSlots OF Session;
  generations: ARRAY maxSlots OF LONGINT;
  lifetime: Temporary;
  count, finalized: LONGINT;

PROCEDURE -Reenter(): LONGINT "BarevHost_Reenter()";
PROCEDURE -Include '#include "host.h"';

PROCEDURE Index(handle: LONGINT; owner: S.ADDRESS): LONGINT;
  VAR index, generation: LONGINT;
BEGIN
  IF handle <= 0 THEN RETURN -1 END;
  index := (handle-1) MOD maxSlots; generation := (handle-1) DIV maxSlots;
  IF (sessions[index] = NIL) OR (generations[index] # generation) OR
     (sessions[index].owner # owner) THEN RETURN -1 END;
  RETURN index
END Index;

PROCEDURE Open*(owner: S.ADDRESS): LONGINT;
  VAR index: LONGINT;
BEGIN
  IF owner = 0 THEN RETURN 0 END;
  index := 0;
  WHILE (index < maxSlots) & ((sessions[index] # NIL) OR (generations[index] = maxGeneration)) DO INC(index) END;
  IF index = maxSlots THEN RETURN 0 END;
  INC(generations[index]); NEW(sessions[index]); sessions[index].owner := owner;
  INC(count); RETURN generations[index]*maxSlots+index+1
END Open;

PROCEDURE Close*(handle: LONGINT; owner: S.ADDRESS): LONGINT;
  VAR index: LONGINT;
BEGIN
  index := Index(handle, owner); IF index < 0 THEN RETURN 0 END;
  sessions[index] := NIL; DEC(count); RETURN 1
END Close;

PROCEDURE Valid(data: ARRAY OF CHAR; length: LONGINT): BOOLEAN;
  VAR index: LONGINT;
BEGIN
  IF (length < 0) OR (length > maxBytes) OR (length > LEN(data)) THEN RETURN FALSE END;
  FOR index := 0 TO length-1 DO IF data[index] = 0X THEN RETURN FALSE END END;
  RETURN TRUE
END Valid;

PROCEDURE Put*(handle: LONGINT; owner: S.ADDRESS; data: ARRAY OF CHAR; length: LONGINT): LONGINT;
  VAR index, position: LONGINT; bytes: Bytes;
BEGIN
  index := Index(handle, owner); IF (index < 0) OR ~Valid(data, length) THEN RETURN 0 END;
  NEW(bytes, length+1);
  FOR position := 0 TO length-1 DO bytes[position] := data[position] END; bytes[length] := 0X;
  sessions[index].bytes := bytes; sessions[index].length := length; RETURN 1
END Put;

PROCEDURE Matches*(handle: LONGINT; owner: S.ADDRESS; data: ARRAY OF CHAR; length: LONGINT): LONGINT;
  VAR index, position: LONGINT;
BEGIN
  index := Index(handle, owner); IF (index < 0) OR ~Valid(data, length) THEN RETURN 0 END;
  IF (sessions[index].bytes = NIL) OR (sessions[index].length # length) THEN RETURN 0 END;
  FOR position := 0 TO length-1 DO IF sessions[index].bytes[position] # data[position] THEN RETURN 0 END END;
  RETURN 1
END Matches;

PROCEDURE Pulse*(handle: LONGINT; owner: S.ADDRESS): LONGINT;
  VAR index: LONGINT; garbage: Bytes;
BEGIN
  index := Index(handle, owner); IF index < 0 THEN RETURN 0 END;
  NEW(garbage, 65536); garbage[0] := "x";
  Heap.GC(TRUE);
  IF sessions[index].ticks < MAX(LONGINT) THEN INC(sessions[index].ticks) END;
  RETURN 1
END Pulse;

PROCEDURE Ticks*(handle: LONGINT; owner: S.ADDRESS): LONGINT;
  VAR index: LONGINT;
BEGIN index := Index(handle, owner); IF index < 0 THEN RETURN -1 END; RETURN sessions[index].ticks END Ticks;

PROCEDURE Collect*(stack: LONGINT);
BEGIN Heap.GC(stack # 0) END Collect;

PROCEDURE Finalize(object: S.PTR);
BEGIN IF finalized < MAX(LONGINT) THEN INC(finalized) END END Finalize;

PROCEDURE Nested*(): LONGINT;
  VAR objects: ARRAY stackProbeObjects OF Temporary;
    index, before: LONGINT; result: LONGINT;
BEGIN
  before := finalized;
  FOR index := 0 TO stackProbeObjects-1 DO
    NEW(objects[index]); objects[index].marker := 1234567+index;
    Heap.RegisterFinalizer(objects[index], Finalize)
  END;
  result := Reenter();
  IF (result # 1) OR (finalized # before) THEN RETURN 0 END;
  FOR index := 0 TO stackProbeObjects-1 DO
    IF objects[index].marker # 1234567+index THEN RETURN 0 END
  END;
  RETURN 1
END Nested;

PROCEDURE Count*(): LONGINT;
BEGIN RETURN count END Count;

PROCEDURE ByteLimit*(): LONGINT;
BEGIN RETURN maxBytes END ByteLimit;

PROCEDURE Finalized*(): LONGINT;
BEGIN RETURN finalized END Finalized;

PROCEDURE Reset*;
  VAR index: LONGINT;
BEGIN
  FOR index := 0 TO maxSlots-1 DO sessions[index] := NIL END;
  count := 0; Heap.GC(FALSE)
END Reset;

BEGIN
  NEW(lifetime); lifetime.marker := 7654321;
  Heap.RegisterFinalizer(lifetime, Finalize)
END BarevBridge.
