-- rad_pdf_gif_decoder.sql — GIF (LZW → raw pixels → FlateDecode) image decoder.
-- Only the first image frame is decoded (animated GIFs: first frame only).
CREATE OR REPLACE TYPE rad_pdf_gif_decoder FORCE UNDER rad_pdf_img_decoder (
  OVERRIDING MEMBER FUNCTION detect(p_header IN RAW)  RETURN NUMBER,
  OVERRIDING MEMBER FUNCTION decode (p_blob   IN BLOB) RETURN rad_pdf_img_data
);
/

CREATE OR REPLACE TYPE BODY rad_pdf_gif_decoder AS

  OVERRIDING MEMBER FUNCTION detect(p_header IN RAW) RETURN NUMBER IS
  BEGIN
    -- GIF starts with ASCII 'GIF' (47 49 46).
    IF p_header IS NULL OR UTL_RAW.LENGTH(p_header) < 3 THEN RETURN 0; END IF;
    IF UTL_RAW.CAST_TO_VARCHAR2(UTL_RAW.SUBSTR(p_header, 1, 3)) = 'GIF' THEN
      RETURN 1;
    END IF;
    RETURN 0;
  END detect;

  OVERRIDING MEMBER FUNCTION decode(p_blob IN BLOB) RETURN rad_pdf_img_data IS
    -- Variables first, then nested subprograms.
    l_len        NUMBER      := NVL(DBMS_LOB.GETLENGTH(p_blob), 0);
    l_ind        PLS_INTEGER;
    l_t_len      PLS_INTEGER;
    l_byte1      RAW(1);
    l_done       BOOLEAN     := FALSE;
    l_color_tab  RAW(768);
    l_transp_idx NUMBER      := NULL;
    l_width      NUMBER      := 0;
    l_height     NUMBER      := 0;
    l_pixels     BLOB;

    FUNCTION blob2num(p_b IN BLOB, p_len IN PLS_INTEGER, p_pos IN PLS_INTEGER)
      RETURN PLS_INTEGER IS
      l_raw RAW(4);
    BEGIN
      l_raw := DBMS_LOB.SUBSTR(p_b, p_len, p_pos);
      IF l_raw IS NULL THEN RETURN NULL; END IF;
      RETURN UTL_RAW.CAST_TO_BINARY_INTEGER(l_raw, UTL_RAW.BIG_ENDIAN);
    END blob2num;

    FUNCTION raw2num(p_raw IN RAW) RETURN PLS_INTEGER IS
    BEGIN
      IF p_raw IS NULL THEN RETURN 0; END IF;
      RETURN UTL_RAW.CAST_TO_BINARY_INTEGER(p_raw, UTL_RAW.BIG_ENDIAN);
    END raw2num;

    FUNCTION lzw_decompress(p_b IN BLOB, p_bits IN PLS_INTEGER) RETURN BLOB IS
      TYPE t_lzw_dict IS TABLE OF RAW(1000) INDEX BY PLS_INTEGER;
      l_dict     t_lzw_dict;
      l_result   BLOB;
      l_clr      PLS_INTEGER;
      l_nxt      PLS_INTEGER;
      l_new      PLS_INTEGER;
      l_old      PLS_INTEGER;
      l_bits     PLS_INTEGER := p_bits;
      l_bi       PLS_INTEGER := 0;
      l_buf_val  PLS_INTEGER := 0;
      l_buf_bits PLS_INTEGER := 0;
      l_blen     NUMBER      := NVL(DBMS_LOB.GETLENGTH(p_b), 0);
      l_pwr      DBMS_SQL.NUMBER_TABLE;

      FUNCTION get_code RETURN PLS_INTEGER IS
        l_rv   PLS_INTEGER;
        l_byte PLS_INTEGER;
      BEGIN
        WHILE l_buf_bits < l_bits LOOP
          l_bi := l_bi + 1;
          EXIT WHEN l_bi > l_blen;
          l_byte     := raw2num(DBMS_LOB.SUBSTR(p_b, 1, l_bi));
          l_buf_val  := l_buf_val + l_byte * l_pwr(l_buf_bits);
          l_buf_bits := l_buf_bits + 8;
        END LOOP;
        l_rv       := MOD(l_buf_val, l_pwr(l_bits));
        l_buf_val  := TRUNC(l_buf_val / l_pwr(l_bits));
        l_buf_bits := l_buf_bits - l_bits;
        RETURN l_rv;
      END get_code;

    BEGIN
      FOR i IN 0 .. 30 LOOP
        l_pwr(i) := POWER(2, i);
      END LOOP;

      l_clr := l_pwr(p_bits - 1);
      l_nxt := l_clr + 2;

      FOR i IN 0 .. LEAST(l_clr - 1, 255) LOOP
        l_dict(i) := HEXTORAW(TO_CHAR(i, 'FM0X'));
      END LOOP;

      DBMS_LOB.CREATETEMPORARY(l_result, TRUE, DBMS_LOB.SESSION);

      l_old := NULL;
      l_new := get_code();

      LOOP
        CASE NVL(l_new, l_clr + 1)
          WHEN l_clr + 1 THEN
            EXIT;
          WHEN l_clr THEN
            l_new  := NULL;
            l_bits := p_bits;
            l_nxt  := l_clr + 2;
          ELSE
            IF l_new = l_nxt THEN
              l_dict(l_nxt) := UTL_RAW.CONCAT(
                l_dict(l_old), UTL_RAW.SUBSTR(l_dict(l_old), 1, 1));
              DBMS_LOB.APPEND(l_result, l_dict(l_nxt));
              l_nxt := l_nxt + 1;
            ELSIF l_new > l_nxt THEN
              EXIT;
            ELSE
              DBMS_LOB.APPEND(l_result, l_dict(l_new));
              IF l_old IS NOT NULL THEN
                l_dict(l_nxt) := UTL_RAW.CONCAT(
                  l_dict(l_old), UTL_RAW.SUBSTR(l_dict(l_new), 1, 1));
                l_nxt := l_nxt + 1;
              END IF;
            END IF;
            IF l_bits < 12 AND MOD(l_nxt, l_pwr(l_bits)) = 0 THEN
              l_bits := l_bits + 1;
            END IF;
        END CASE;
        l_old := l_new;
        l_new := get_code();
      END LOOP;

      l_dict.DELETE;
      RETURN l_result;
    EXCEPTION
      WHEN OTHERS THEN
        IF l_result IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_result) = 1 THEN
          DBMS_LOB.FREETEMPORARY(l_result);
        END IF;
        RAISE;
    END lzw_decompress;

  BEGIN
    IF l_len < 6 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
        'rad_pdf_gif_decoder.decode: data too short', TRUE);
    END IF;

    IF DBMS_LOB.SUBSTR(p_blob, 3, 1) != UTL_RAW.CAST_TO_RAW('GIF') THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
        'rad_pdf_gif_decoder.decode: not a GIF file', TRUE);
    END IF;

    -- Skip 6-byte header + 7-byte Logical Screen Descriptor = start at byte 14.
    l_ind := 14;

    -- Global Color Table present if bit 7 of packed field (byte 11) is set.
    IF raw2num(DBMS_LOB.SUBSTR(p_blob, 1, 11)) > 127 THEN
      l_t_len := 3 * POWER(2,
                   raw2num(UTL_RAW.BIT_AND(
                     DBMS_LOB.SUBSTR(p_blob, 1, 11), HEXTORAW('07'))) + 1);
      l_color_tab := DBMS_LOB.SUBSTR(p_blob, LEAST(l_t_len, 768), l_ind);
      l_ind := l_ind + l_t_len;
    END IF;

    LOOP
      EXIT WHEN l_ind > l_len OR l_done;
      l_byte1 := DBMS_LOB.SUBSTR(p_blob, 1, l_ind);

      IF l_byte1 = HEXTORAW('3B') THEN        -- Trailer
        EXIT;

      ELSIF l_byte1 = HEXTORAW('21') THEN     -- Extension block
        IF DBMS_LOB.SUBSTR(p_blob, 1, l_ind + 1) = HEXTORAW('F9') THEN
          -- Graphic Control Extension: transparent colour flag in bit 0.
          IF UTL_RAW.BIT_AND(DBMS_LOB.SUBSTR(p_blob, 1, l_ind + 3),
                              HEXTORAW('01')) = HEXTORAW('01') THEN
            l_transp_idx := blob2num(p_blob, 1, l_ind + 6);
          END IF;
        END IF;
        l_ind := l_ind + 2;
        LOOP
          l_t_len := blob2num(p_blob, 1, l_ind);
          EXIT WHEN l_t_len = 0;
          l_ind := l_ind + 1 + l_t_len;
        END LOOP;
        l_ind := l_ind + 1;  -- skip terminal Block Size (0)

      ELSIF l_byte1 = HEXTORAW('2C') THEN     -- Image Descriptor
        DECLARE
          l_img_blob  BLOB;
          l_min_bits  PLS_INTEGER;
          l_flags     RAW(1);
        BEGIN
          l_width  := UTL_RAW.CAST_TO_BINARY_INTEGER(
                        DBMS_LOB.SUBSTR(p_blob, 2, l_ind + 5), UTL_RAW.LITTLE_ENDIAN);
          l_height := UTL_RAW.CAST_TO_BINARY_INTEGER(
                        DBMS_LOB.SUBSTR(p_blob, 2, l_ind + 7), UTL_RAW.LITTLE_ENDIAN);
          l_ind    := l_ind + 1 + 8;

          l_flags := DBMS_LOB.SUBSTR(p_blob, 1, l_ind);

          -- Local Color Table overrides global palette.
          IF UTL_RAW.BIT_AND(l_flags, HEXTORAW('80')) = HEXTORAW('80') THEN
            l_t_len := 3 * POWER(2,
                         raw2num(UTL_RAW.BIT_AND(l_flags, HEXTORAW('07'))) + 1);
            l_color_tab := DBMS_LOB.SUBSTR(p_blob, LEAST(l_t_len, 768), l_ind + 1);
          END IF;
          l_ind := l_ind + 1;

          l_min_bits := blob2num(p_blob, 1, l_ind);
          l_ind := l_ind + 1;

          DBMS_LOB.CREATETEMPORARY(l_img_blob, TRUE, DBMS_LOB.SESSION);
          LOOP
            l_t_len := blob2num(p_blob, 1, l_ind);
            EXIT WHEN l_t_len = 0;
            DBMS_LOB.APPEND(l_img_blob,
                            DBMS_LOB.SUBSTR(p_blob, l_t_len, l_ind + 1));
            l_ind := l_ind + 1 + l_t_len;
          END LOOP;
          l_ind := l_ind + 1;

          l_pixels := lzw_decompress(l_img_blob, l_min_bits + 1);
          DBMS_LOB.FREETEMPORARY(l_img_blob);

          -- De-interlace if Interlace flag (bit 6) is set.
          IF UTL_RAW.BIT_AND(l_flags, HEXTORAW('40')) = HEXTORAW('40') THEN
            DECLARE
              l_deint BLOB;
              l_pass  PLS_INTEGER;
              l_pi    DBMS_SQL.NUMBER_TABLE;
            BEGIN
              DBMS_LOB.CREATETEMPORARY(l_deint, TRUE, DBMS_LOB.SESSION);
              l_pi(1) := 1;
              l_pi(2) := TRUNC((l_height - 1) / 8) + 1;
              l_pi(3) := l_pi(2) + TRUNC((l_height + 3) / 8);
              l_pi(4) := l_pi(3) + TRUNC((l_height + 1) / 4);
              l_pi(2) := l_pi(2) * l_width + 1;
              l_pi(3) := l_pi(3) * l_width + 1;
              l_pi(4) := l_pi(4) * l_width + 1;
              FOR i IN 0 .. l_height - 1 LOOP
                IF    MOD(i, 8) = 0 THEN l_pass := 1;
                ELSIF MOD(i, 8) = 4 THEN l_pass := 2;
                ELSIF MOD(i, 8) IN (2, 6) THEN l_pass := 3;
                ELSE  l_pass := 4;
                END IF;
                DBMS_LOB.APPEND(l_deint,
                  DBMS_LOB.SUBSTR(l_pixels, l_width, l_pi(l_pass)));
                l_pi(l_pass) := l_pi(l_pass) + l_width;
              END LOOP;
              IF DBMS_LOB.ISTEMPORARY(l_pixels) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_pixels);
              END IF;
              l_pixels := l_deint;
            END;
          END IF;

          l_done := TRUE;
        EXCEPTION
          WHEN OTHERS THEN
            BEGIN
              IF l_img_blob IS NOT NULL
                 AND DBMS_LOB.ISTEMPORARY(l_img_blob) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_img_blob);
              END IF;
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
            RAISE;
        END;
      ELSE
        EXIT;
      END IF;
    END LOOP;

    IF l_width = 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
        'rad_pdf_gif_decoder.decode: image frame not found', TRUE);
    END IF;

    -- GIF is always indexed colour (palette-based).
    RETURN rad_pdf_img_data('GIF', l_width, l_height, 8, 1,
                        0, l_transp_idx, l_pixels, l_color_tab);
  EXCEPTION
    WHEN OTHERS THEN
      IF l_pixels IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_pixels) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_pixels);
      END IF;
      RAISE;
  END decode;

END;
/
