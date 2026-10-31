MODULE TestPictures;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Native codec, RGBA and bounded downsampling regressions without OS files. *)

IMPORT P := BarevPictures, Files, PNG0, JPEG0, Heap, Out;

VAR checks, bad: LONGINT;

PROCEDURE Check(value: BOOLEAN);
BEGIN
  INC(checks);
  IF ~value & (bad = 0) THEN bad := checks; Out.String("Native picture check failed: "); Out.Int(checks, 0); Out.Ln END
END Check;

PROCEDURE Run*(): LONGINT;
  VAR img, decoded: PNG0.Image; jpeg: JPEG0.Image; p, scaled: P.Picture;
    bytes, rendered: Files.Bytes; length, size, res, w, h, i, descriptors: LONGINT; png: BOOLEAN;
    invalid: ARRAY 16 OF CHAR;
BEGIN
  checks := 0; bad := 0; descriptors := Heap.FileCount;
  invalid := ""; Check(P.Read(invalid, 0) = NIL);
  invalid := "bad"; Check(P.Read(invalid, -1) = NIL); Check(P.Read(invalid, 99) = NIL);
  invalid := "GIF89a"; Check(P.Read(invalid, 6) = NIL);
  invalid := "bad"; Check(~P.Render(invalid, 3, TRUE, rendered, size, png)); Check((rendered = NIL) & (size = 0));
  Check(~P.Inspect(invalid, 3, w, h)); Check((w = 0) & (h = 0));
  img := PNG0.NewImage(2, 1); img.alpha := TRUE;
  img.pix[0] := 0FFX; img.pix[3] := 0X; img.pix[6] := 0FFX; img.pix[7] := 0FFX;
  PNG0.EncodeBytes(img, 6, 4096, bytes, length, res); Check(res = PNG0.ok);
  Check(P.Inspect(bytes^, length, w, h) & (w = 2) & (h = 1));
  p := P.Read(bytes^, length); Check((p # NIL) & p.alpha);
  FOR i := 0 TO 7 DO Check(p.png.pix[i] = img.pix[i]) END;
  Check(P.Scale(p, 2) = p); Check(P.Scale(p, 0) = NIL); Check(P.Scale(p, P.fitEdge + 1) = NIL);
  scaled := P.Scale(p, 1); Check((scaled # NIL) & (scaled.width = 1) & (scaled.height = 1));
  Check((scaled.png.pix[0] = 0X) & (scaled.png.pix[1] = 0X) &
    (scaled.png.pix[2] = 0FFX) & (scaled.png.pix[3] = 80X));
  Check((p.png.pix[0] = 0FFX) & (p.png.pix[3] = 0X));
  Check(P.Render(bytes^, length, FALSE, rendered, size, png) & png & (size <= P.fitBytes));
  PNG0.DecodeBytes(rendered^, size, 16, decoded, res); Check(res = PNG0.ok);
  FOR i := 0 TO 7 DO Check(decoded.pix[i] = img.pix[i]) END;
  img.pix[3] := 80X; PNG0.EncodeBytes(img, 6, 4096, bytes, length, res); Check(res = PNG0.ok);
  Check(P.Render(bytes^, length, TRUE, rendered, size, png) & png & (size <= P.previewBytes));
  PNG0.DecodeBytes(rendered^, size, 16, decoded, res);
  Check((res = PNG0.ok) & (decoded.pix[3] = 80X));
  Check(P.Read(bytes^, length - 1) = NIL);
  bytes[length - 1] := CHR((ORD(bytes[length - 1]) + 1) MOD 256); Check(P.Read(bytes^, length) = NIL);
  PNG0.EncodeBytes(img, 6, 4096, bytes, length, res);
  bytes[18] := 20X; bytes[19] := 1X; Check(P.Read(bytes^, length) = NIL);
  bytes[19] := 0X; bytes[22] := 10X; bytes[23] := 0X; Check(P.Read(bytes^, length) = NIL);
  PNG0.EncodeBytes(img, 6, 4096, bytes, length, res);
  bytes[37] := "a"; bytes[38] := "c"; bytes[39] := "T"; bytes[40] := "L";
  Check(P.Read(bytes^, length) = NIL);

  jpeg := JPEG0.NewImage(8, 4);
  FOR i := 0 TO 8 * 4 - 1 DO jpeg.pix[4 * i] := 80X; jpeg.pix[4 * i + 3] := 0FFX END;
  JPEG0.EncodeBytes(jpeg, 90, 4096, bytes, length, res); Check(res = JPEG0.ok);
  p := P.Read(bytes^, length); Check((p # NIL) & ~p.alpha & (p.width = 8) & (p.height = 4));
  scaled := P.Scale(p, 3); Check((scaled.width = 3) & (scaled.height = 1) & ~scaled.alpha);
  Check(P.Render(bytes^, length, FALSE, rendered, size, png) & ~png & (size <= P.fitBytes));
  Check((rendered[0] = 0FFX) & (rendered[1] = 0D8X));
  Check(P.Render(bytes^, length, TRUE, rendered, size, png) & png & (size <= P.previewBytes));
  PNG0.DecodeBytes(rendered^, size, 32, decoded, res);
  Check((res = PNG0.ok) & (decoded.width = 8) & (decoded.height = 4));
  Check(P.Read(bytes^, length - 1) = NIL);

  img := PNG0.NewImage(1, 257); PNG0.EncodeBytes(img, 6, 4096, bytes, length, res);
  p := P.Read(bytes^, length); scaled := P.Scale(p, 128);
  Check((scaled.width = 1) & (scaled.height = 128));
  img := PNG0.NewImage(257, 1); PNG0.EncodeBytes(img, 6, 4096, bytes, length, res);
  p := P.Read(bytes^, length); scaled := P.Scale(p, 128);
  Check((scaled.width = 128) & (scaled.height = 1));
  Check(Heap.FileCount = descriptors);
  IF bad # 0 THEN RETURN -bad END;
  RETURN checks
END Run;

END TestPictures.
