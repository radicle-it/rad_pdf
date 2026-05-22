-- rad_pdf_png_decoder.sql — PNG (FlateDecode + predictor 15) image decoder.
CREATE OR REPLACE TYPE rad_pdf_png_decoder FORCE UNDER rad_pdf_img_decoder (
  OVERRIDING MEMBER FUNCTION detect(p_header IN RAW)  RETURN NUMBER,
  OVERRIDING MEMBER FUNCTION decode (p_blob   IN BLOB) RETURN rad_pdf_img_data
);
/

CREATE OR REPLACE TYPE BODY rad_pdf_png_decoder AS

  OVERRIDING MEMBER FUNCTION detect(p_header IN RAW) RETURN NUMBER IS
  BEGIN
    -- PNG signature: 89 50 4E 47 0D 0A 1A 0A
    IF p_header IS NULL OR UTL_RAW.LENGTH(p_header) < 8 THEN RETURN 0; END IF;
    IF UTL_RAW.SUBSTR(p_header, 1, 8) = HEXTORAW('89504E470D0A1A0A') THEN
      RETURN 1;
    END IF;
    RETURN 0;
  END detect;

  OVERRIDING MEMBER FUNCTION decode(p_blob IN BLOB) RETURN rad_pdf_img_data IS
    -- Variables first, then nested subprograms.
    l_len        NUMBER      := NVL(DBMS_LOB.GETLENGTH(p_blob), 0);
    l_pos        PLS_INTEGER := 9;   -- first chunk starts after 8-byte signature
    l_chunk_len  PLS_INTEGER;
    l_chunk_typ  VARCHAR2(4);
    l_color_type PLS_INTEGER;
    l_pixels     BLOB;
    l_color_tab  RAW(768);
    l_width      NUMBER    := 0;
    l_height     NUMBER    := 0;
    l_cres       NUMBER    := 8;
    l_ncolors    NUMBER    := 3;
    l_grey       NUMBER(1) := 0;

    FUNCTION blob2num(p_b IN BLOB, p_len IN PLS_INTEGER, p_pos IN PLS_INTEGER)
      RETURN PLS_INTEGER IS
      l_raw RAW(4);
    BEGIN
      l_raw := DBMS_LOB.SUBSTR(p_b, p_len, p_pos);
      IF l_raw IS NULL THEN RETURN NULL; END IF;
      RETURN UTL_RAW.CAST_TO_BINARY_INTEGER(l_raw, UTL_RAW.BIG_ENDIAN);
    END blob2num;

  BEGIN
    IF l_len < 8 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
        'rad_pdf_png_decoder.decode: data too short', TRUE);
    END IF;

    IF RAWTOHEX(DBMS_LOB.SUBSTR(p_blob, 8, 1)) != '89504E470D0A1A0A' THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
        'rad_pdf_png_decoder.decode: invalid PNG signature', TRUE);
    END IF;

    DBMS_LOB.CREATETEMPORARY(l_pixels, TRUE, DBMS_LOB.SESSION);

    LOOP
      EXIT WHEN l_pos > l_len;
      l_chunk_len := blob2num(p_blob, 4, l_pos);
      EXIT WHEN l_chunk_len IS NULL;
      l_chunk_typ := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(p_blob, 4, l_pos + 4));

      CASE l_chunk_typ
        WHEN 'IHDR' THEN
          l_width      := blob2num(p_blob, 4, l_pos + 8);
          l_height     := blob2num(p_blob, 4, l_pos + 12);
          l_cres       := blob2num(p_blob, 1, l_pos + 16);
          l_color_type := blob2num(p_blob, 1, l_pos + 17);
          l_grey       := CASE WHEN l_color_type IN (0, 4) THEN 1 ELSE 0 END;
          l_ncolors    := CASE l_color_type
                            WHEN 0 THEN 1   -- greyscale
                            WHEN 2 THEN 3   -- RGB
                            WHEN 3 THEN 1   -- indexed
                            WHEN 4 THEN 2   -- greyscale + alpha
                            ELSE        4   -- RGBA
                          END;
        WHEN 'PLTE' THEN
          l_color_tab := DBMS_LOB.SUBSTR(p_blob, LEAST(l_chunk_len, 768), l_pos + 8);
        WHEN 'IDAT' THEN
          -- Concatenate all IDAT chunks; the result is the raw FlateDecode stream.
          DBMS_LOB.COPY(l_pixels, p_blob, l_chunk_len,
                        DBMS_LOB.GETLENGTH(l_pixels) + 1, l_pos + 8);
        WHEN 'IEND' THEN EXIT;
        ELSE NULL;
      END CASE;

      l_pos := l_pos + 4 + 4 + l_chunk_len + 4;  -- length + type + data + CRC
    END LOOP;

    IF l_width = 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
        'rad_pdf_png_decoder.decode: IHDR chunk not found', TRUE);
    END IF;

    RETURN rad_pdf_img_data('PNG', l_width, l_height, l_cres, l_ncolors,
                        l_grey, NULL, l_pixels, l_color_tab);
  EXCEPTION
    WHEN OTHERS THEN
      IF l_pixels IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_pixels) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_pixels);
      END IF;
      RAISE;
  END decode;

END;
/
