MODULE BarevPictures;

(* SPDX-License-Identifier: GPL-3.0-or-later *)
(* Bounded, memory-only conversation pictures using VOC's native codecs. *)

IMPORT Files, PNG0, JPEG0, Av := BarevAvatar, Limits := BarevImages;

CONST
  fitEdge* = 1280; previewEdge* = 640;
  fitBytes* = 262144; previewBytes* = 2097152;

TYPE
  Picture* = POINTER TO RECORD
    width*, height*: LONGINT; alpha*: BOOLEAN;
    png*: PNG0.Image; jpeg*: JPEG0.Image
  END;

(* VAR input arrays are read-only views here: value parameters would duplicate
   multi-megabyte buffers on the generated C stack. *)
PROCEDURE Read*(VAR data: ARRAY OF CHAR; length: LONGINT): Picture;
  VAR img: Picture; png: PNG0.Image; jpeg: JPEG0.Image; res: LONGINT;
    file: Files.File; rider: Files.Rider;
BEGIN
  IF (length <= 0) OR (length > LEN(data)) OR (length > Limits.maxImageBytes) THEN RETURN NIL END;
  (* Check complete static-image framing and dimensions before decoder allocation. *)
  IF Av.ImageMIME(data, length, Limits.maxDimension, Limits.maxPixels) = NIL THEN RETURN NIL END;
  file := Files.NewMemory(length); Files.Set(rider, file, 0); Files.WriteBytes(rider, data, length);
  IF Files.MemoryFailed(file) THEN RETURN NIL END;
  Files.Set(rider, file, 0);
  IF data[0] = 89X THEN
    PNG0.Decode(rider, png, res);
    IF (res # PNG0.ok) OR (png = NIL) THEN RETURN NIL END;
    NEW(img); img.width := png.width; img.height := png.height;
    img.alpha := png.alpha; img.png := png
  ELSE
    JPEG0.Decode(rider, jpeg, res);
    IF (res # JPEG0.ok) OR (jpeg = NIL) THEN RETURN NIL END;
    NEW(img); img.width := jpeg.width; img.height := jpeg.height;
    img.alpha := FALSE; img.jpeg := jpeg
  END;
  RETURN img
END Read;

PROCEDURE Inspect*(VAR data: ARRAY OF CHAR; length: LONGINT; VAR width, height: LONGINT): BOOLEAN;
  VAR img: Picture;
BEGIN
  width := 0; height := 0; img := Read(data, length);
  IF img = NIL THEN RETURN FALSE END;
  width := img.width; height := img.height; RETURN TRUE
END Inspect;

PROCEDURE Maximum(a, b: LONGINT): LONGINT;
BEGIN IF a > b THEN RETURN a ELSE RETURN b END END Maximum;

(* Integer-area downsampling averages premultiplied colour, so transparent
   pixels cannot introduce coloured fringes. Dimensions and offsets are bounded. *)
PROCEDURE ScalePixels(VAR pixels: ARRAY OF CHAR; width, height: LONGINT; transparent: BOOLEAN; edge: LONGINT): PNG0.Image;
  VAR out: PNG0.Image; w, h, x, y, sx, sy, left, right, top, bottom, at, dest, n, a: LONGINT;
    red, green, blue, alpha: HUGEINT;
BEGIN
  IF (edge < 1) OR (edge > fitEdge) THEN RETURN NIL END;
  w := width; h := height;
  IF (w < 1) OR (h < 1) OR (w > Limits.maxDimension) OR (h > Limits.maxDimension) OR
     (w > Limits.maxPixels DIV h) OR (w * h > LEN(pixels) DIV 4) THEN RETURN NIL END;
  IF w >= h THEN h := Maximum(1, h * edge DIV w); w := edge
  ELSE w := Maximum(1, w * edge DIV h); h := edge
  END;
  out := PNG0.NewImage(w, h); out.alpha := transparent;
  FOR y := 0 TO h - 1 DO
    top := y * height DIV h; bottom := (y + 1) * height DIV h;
    FOR x := 0 TO w - 1 DO
      left := x * width DIV w; right := (x + 1) * width DIV w;
      red := 0; green := 0; blue := 0; alpha := 0;
      FOR sy := top TO bottom - 1 DO
        at := (sy * width + left) * 4;
        FOR sx := left TO right - 1 DO
          IF transparent THEN a := ORD(pixels[at + 3]) ELSE a := 255 END;
          INC(alpha, a); INC(red, ORD(pixels[at]) * a);
          INC(green, ORD(pixels[at + 1]) * a); INC(blue, ORD(pixels[at + 2]) * a);
          INC(at, 4)
        END
      END;
      dest := (y * w + x) * 4; n := (right - left) * (bottom - top);
      IF alpha > 0 THEN
        out.pix[dest] := CHR(SHORT((red + alpha DIV 2) DIV alpha));
        out.pix[dest + 1] := CHR(SHORT((green + alpha DIV 2) DIV alpha));
        out.pix[dest + 2] := CHR(SHORT((blue + alpha DIV 2) DIV alpha))
      END;
      out.pix[dest + 3] := CHR(SHORT((alpha + n DIV 2) DIV n))
    END
  END;
  RETURN out
END ScalePixels;

PROCEDURE Scale*(img: Picture; edge: LONGINT): Picture;
  VAR out: Picture; png: PNG0.Image;
BEGIN
  IF (img = NIL) OR (edge < 1) OR (edge > fitEdge) THEN RETURN NIL END;
  IF Maximum(img.width, img.height) <= edge THEN RETURN img END;
  IF (img.png # NIL) & (img.png.pix # NIL) THEN
    png := ScalePixels(img.png.pix^, img.width, img.height, img.alpha, edge)
  ELSIF (img.jpeg # NIL) & (img.jpeg.pix # NIL) THEN
    png := ScalePixels(img.jpeg.pix^, img.width, img.height, FALSE, edge)
  ELSE RETURN NIL
  END;
  IF png = NIL THEN RETURN NIL END;
  NEW(out); out.width := png.width; out.height := png.height; out.alpha := png.alpha; out.png := png;
  RETURN out
END Scale;

(* Convert codec-specific buffer types only after fitting to the output edge. *)
PROCEDURE AsPNG(img: Picture): PNG0.Image;
  VAR png: PNG0.Image; i: LONGINT;
BEGIN
  IF img.png # NIL THEN RETURN img.png END;
  png := PNG0.NewImage(img.width, img.height);
  FOR i := 0 TO img.width * img.height * 4 - 1 DO png.pix[i] := img.jpeg.pix[i] END;
  RETURN png
END AsPNG;

PROCEDURE AsJPEG(img: Picture): JPEG0.Image;
  VAR jpeg: JPEG0.Image; i: LONGINT;
BEGIN
  IF img.jpeg # NIL THEN RETURN img.jpeg END;
  jpeg := JPEG0.NewImage(img.width, img.height);
  FOR i := 0 TO img.width * img.height * 4 - 1 DO jpeg.pix[i] := img.png.pix[i] END;
  RETURN jpeg
END AsJPEG;

PROCEDURE Render*(VAR data: ARRAY OF CHAR; length: LONGINT; preview: BOOLEAN;
    VAR bytes: Files.Bytes; VAR size: LONGINT; VAR png: BOOLEAN): BOOLEAN;
  VAR img: Picture; edge, capacity, pass, res: LONGINT;
BEGIN
  bytes := NIL; size := 0; png := TRUE;
  img := Read(data, length); IF img = NIL THEN RETURN FALSE END;
  IF preview THEN edge := previewEdge; capacity := previewBytes
  ELSE edge := fitEdge; capacity := fitBytes
  END;
  img := Scale(img, edge); IF img = NIL THEN RETURN FALSE END;
  png := preview OR img.alpha; pass := 0;
  WHILE pass < 8 DO
    IF png THEN PNG0.EncodeBytes(AsPNG(img), 6, capacity, bytes, size, res)
    ELSE JPEG0.EncodeBytes(AsJPEG(img), 85, capacity, bytes, size, res)
    END;
    IF res = 0 THEN RETURN TRUE END;
    IF preview OR (png & (res # PNG0.tooLarge)) OR (~png & (res # JPEG0.tooLarge)) THEN RETURN FALSE END;
    edge := Maximum(img.width, img.height) DIV 2;
    IF edge < 1 THEN RETURN FALSE END;
    img := Scale(img, edge); IF img = NIL THEN RETURN FALSE END;
    INC(pass)
  END;
  RETURN FALSE
END Render;

END BarevPictures.
