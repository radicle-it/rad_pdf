-- rad_pdf_jpeg_decoder.sql — JPEG (DCTDecode) image decoder.
CREATE OR REPLACE TYPE rad_pdf_jpeg_decoder FORCE UNDER rad_pdf_img_decoder (
  OVERRIDING MEMBER FUNCTION detect(p_header IN RAW)  RETURN NUMBER,
  OVERRIDING MEMBER FUNCTION decode (p_blob   IN BLOB) RETURN rad_pdf_img_data
);
/

CREATE OR REPLACE TYPE BODY rad_pdf_jpeg_decoder AS

  OVERRIDING MEMBER FUNCTION detect(p_header IN RAW) RETURN NUMBER IS
  BEGIN
    -- JPEG starts with FFD8 (SOI marker).
    IF p_header IS NULL OR UTL_RAW.LENGTH(p_header) < 2 THEN RETURN 0; END IF;
    IF UTL_RAW.SUBSTR(p_header, 1, 2) = HEXTORAW('FFD8') THEN RETURN 1; END IF;
    RETURN 0;
  END detect;

  OVERRIDING MEMBER FUNCTION decode(p_blob IN BLOB) RETURN rad_pdf_img_data IS
    -- Variables first, then nested subprograms (PL/SQL declaration order).
    l_len      NUMBER    := NVL(DBMS_LOB.GETLENGTH(p_blob), 0);
    l_buf      RAW(2);
    l_pos      PLS_INTEGER;
    l_seg_len  PLS_INTEGER;
    l_pixels   BLOB;
    l_width    NUMBER    := 1;
    l_height   NUMBER    := 1;
    l_cres     NUMBER    := 8;
    l_ncolors  NUMBER    := 3;
    l_grey     NUMBER(1) := 0;

    FUNCTION blob2num(p_b IN BLOB, p_len IN PLS_INTEGER, p_pos IN PLS_INTEGER)
      RETURN PLS_INTEGER IS
      l_raw RAW(4);
    BEGIN
      l_raw := DBMS_LOB.SUBSTR(p_b, p_len, p_pos);
      IF l_raw IS NULL THEN RETURN NULL; END IF;
      RETURN UTL_RAW.CAST_TO_BINARY_INTEGER(l_raw, UTL_RAW.BIG_ENDIAN);
    END blob2num;

  BEGIN
    IF l_len < 4 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
        'rad_pdf_jpeg_decoder.decode: data too short', TRUE);
    END IF;

    IF DBMS_LOB.SUBSTR(p_blob, 2, 1)         != HEXTORAW('FFD8')
    OR DBMS_LOB.SUBSTR(p_blob, 2, l_len - 1) != HEXTORAW('FFD9') THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
        'rad_pdf_jpeg_decoder.decode: invalid JPEG (bad SOI or EOI)', TRUE);
    END IF;

    -- Scan segments for SOF0 (FFC0) to get actual dimensions.
    l_pos := 3;
    LOOP
      l_buf := DBMS_LOB.SUBSTR(p_blob, 2, l_pos);
      EXIT WHEN l_buf IS NULL OR l_pos >= l_len;
      EXIT WHEN l_buf = HEXTORAW('FFDA');  -- SOS
      EXIT WHEN l_buf = HEXTORAW('FFD9');  -- EOI
      EXIT WHEN SUBSTR(RAWTOHEX(l_buf), 1, 2) != 'FF';

      IF RAWTOHEX(l_buf) IN ('FFD0','FFD1','FFD2','FFD3',
                              'FFD4','FFD5','FFD6','FFD7','FF01') THEN
        l_pos := l_pos + 2;
      ELSE
        IF l_buf = HEXTORAW('FFC0') THEN  -- SOF0: baseline DCT
          l_cres    := blob2num(p_blob, 1, l_pos + 4);
          l_height  := blob2num(p_blob, 2, l_pos + 5);
          l_width   := blob2num(p_blob, 2, l_pos + 7);
          l_ncolors := blob2num(p_blob, 1, l_pos + 9);
          l_grey    := CASE WHEN l_ncolors = 1 THEN 1 ELSE 0 END;
        END IF;
        l_seg_len := blob2num(p_blob, 2, l_pos + 2);
        EXIT WHEN l_seg_len IS NULL;
        l_pos := l_pos + 2 + l_seg_len;
      END IF;
    END LOOP;

    -- Copy original bytes as pixel stream (JPEG is passed as-is to DCTDecode).
    DBMS_LOB.CREATETEMPORARY(l_pixels, TRUE, DBMS_LOB.SESSION);
    DBMS_LOB.COPY(l_pixels, p_blob, l_len);

    RETURN rad_pdf_img_data('JPG', l_width, l_height, l_cres, l_ncolors,
                        l_grey, NULL, l_pixels, NULL);
  EXCEPTION
    WHEN OTHERS THEN
      IF l_pixels IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_pixels) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_pixels);
      END IF;
      RAISE;
  END decode;

END;
/
