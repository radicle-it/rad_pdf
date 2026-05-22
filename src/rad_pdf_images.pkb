CREATE OR REPLACE PACKAGE BODY rad_pdf_images IS
/*
  rad_pdf_images body — Phase 5 of the RAD_PDF modular refactoring.

  Key changes from src/new/rad_pdf_images.pkb:
    - Per-document state: g_doc_state tracks used_hash, used_id, next_id per handle.
    - All load_image / get_image_dimensions / image_exists / write_image_objects
      gain p_doc as first parameter.
    - reset_images replaced by close_doc(p_doc).
    - write_image_objects calls rad_pdf_serial.write_stream_obj(p_doc, ...) instead of
      pdf_writer.write_stream_obj.
    - All DBMS_LOB.APPEND(BLOB, RAW) replaced with blob_append_raw (private helper).
    - DBMS_LOB.COPY calls guarded against amount=0.
*/

-- ---------------------------------------------------------------------------
-- Internal record types
-- ---------------------------------------------------------------------------
  TYPE t_image IS RECORD (
    img_type    VARCHAR2(3),       -- 'jpg', 'png', 'gif'
    width       PLS_INTEGER,
    height      PLS_INTEGER,
    color_res   PLS_INTEGER,       -- bits per component
    nr_colors   PLS_INTEGER,       -- number of color channels
    greyscale   BOOLEAN,
    transp_idx  PLS_INTEGER,       -- GIF transparent palette index (NULL if none)
    pixels      BLOB,              -- pixel data (always a new CREATETEMPORARY BLOB)
    color_tab   RAW(768),          -- indexed palette (GIF / indexed PNG), up to 256*3 bytes
    sha256      VARCHAR2(64),
    pixels_raw  BOOLEAN,           -- TRUE = pixels is decompressed raw data (like GIF)
    smask       BLOB               -- alpha channel as raw greyscale pixels for PDF /SMask
  );

  TYPE t_cache_entry IS RECORD (
    img        t_image,
    byte_size  NUMBER,
    last_used  TIMESTAMP
  );

  TYPE t_img_cache  IS TABLE OF t_cache_entry INDEX BY VARCHAR2(64);  -- sha256 → entry
  TYPE t_hash_by_id IS TABLE OF VARCHAR2(64)  INDEX BY PLS_INTEGER;   -- image_id → sha256
  TYPE t_id_by_hash IS TABLE OF PLS_INTEGER   INDEX BY VARCHAR2(64);  -- sha256 → image_id

  -- Per-document state
  TYPE t_img_doc_state IS RECORD (
    used_hash  t_hash_by_id,
    used_id    t_id_by_hash,
    next_id    PLS_INTEGER
  );
  TYPE t_img_doc_map IS TABLE OF t_img_doc_state INDEX BY PLS_INTEGER;

-- ---------------------------------------------------------------------------
-- Package state
-- ---------------------------------------------------------------------------
  g_cache        t_img_cache;
  g_cache_bytes  NUMBER       := 0;
  g_cache_limit  NUMBER       := 52428800;  -- 50 MB
  g_doc_state    t_img_doc_map;

-- ---------------------------------------------------------------------------
-- PRIVATE: append a RAW value to a BLOB (WRITEAPPEND, amount must be > 0)
-- ---------------------------------------------------------------------------
  PROCEDURE blob_append_raw(p_lob IN OUT NOCOPY BLOB, p_raw IN RAW) IS
    l_len PLS_INTEGER := UTL_RAW.LENGTH(p_raw);
  BEGIN
    IF l_len > 0 THEN
      DBMS_LOB.WRITEAPPEND(p_lob, l_len, p_raw);
    END IF;
  END blob_append_raw;

-- ---------------------------------------------------------------------------
-- PRIVATE: Security validators
-- ---------------------------------------------------------------------------
  PROCEDURE assert_dir_and_file(p_dir IN VARCHAR2, p_filename IN VARCHAR2) IS
  BEGIN
    IF NOT REGEXP_LIKE(UPPER(p_dir), '^[A-Z0-9_$#]+$') THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_images: invalid directory name "' || p_dir || '"', TRUE);
    END IF;
    IF    p_filename IS NULL
       OR INSTR(p_filename, '..') > 0
       OR INSTR(p_filename, '/')  > 0
       OR INSTR(p_filename, '\')  > 0
       OR INSTR(p_filename, CHR(0)) > 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_images: invalid filename', TRUE);
    END IF;
  END assert_dir_and_file;

-- ---------------------------------------------------------------------------
  PROCEDURE assert_https_url(p_url IN VARCHAR2) IS
  BEGIN
    IF UPPER(SUBSTR(p_url, 1, 8)) != 'HTTPS://' THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_images: URL must start with https://', TRUE);
    END IF;
  END assert_https_url;

-- ---------------------------------------------------------------------------
-- PRIVATE: Blob binary reading helpers
-- ---------------------------------------------------------------------------
  FUNCTION blob2num(p_blob IN BLOB,
                    p_len  IN PLS_INTEGER,
                    p_pos  IN PLS_INTEGER) RETURN PLS_INTEGER IS
    l_raw RAW(4);
  BEGIN
    l_raw := DBMS_LOB.SUBSTR(p_blob, p_len, p_pos);
    IF l_raw IS NULL THEN RETURN NULL; END IF;
    RETURN UTL_RAW.CAST_TO_BINARY_INTEGER(l_raw, UTL_RAW.BIG_ENDIAN);
  END blob2num;

-- ---------------------------------------------------------------------------
  FUNCTION raw2num(p_raw IN RAW) RETURN PLS_INTEGER IS
  BEGIN
    IF p_raw IS NULL THEN RETURN 0; END IF;
    RETURN UTL_RAW.CAST_TO_BINARY_INTEGER(p_raw, UTL_RAW.BIG_ENDIAN);
  END raw2num;

-- ---------------------------------------------------------------------------
-- PRIVATE: JPEG parser
-- ---------------------------------------------------------------------------
  FUNCTION parse_jpg(p_blob IN BLOB) RETURN t_image IS
    l_img     t_image;
    l_len     NUMBER := NVL(DBMS_LOB.GETLENGTH(p_blob), 0);
    l_buf     RAW(2);
    l_pos     PLS_INTEGER;
    l_seg_len PLS_INTEGER;
  BEGIN
    IF l_len < 4 THEN RETURN l_img; END IF;

    -- Verify SOI (FFD8) and EOI (FFD9).
    IF DBMS_LOB.SUBSTR(p_blob, 2, 1)          != HEXTORAW('FFD8')
    OR DBMS_LOB.SUBSTR(p_blob, 2, l_len - 1)  != HEXTORAW('FFD9') THEN
      RETURN l_img;
    END IF;

    l_img.img_type  := 'jpg';
    l_img.nr_colors := 3;
    l_img.greyscale := FALSE;
    l_img.color_res := 8;
    l_img.width     := 1;
    l_img.height    := 1;

    -- Scan segments to find SOF0 (FFC0) which contains actual dimensions.
    l_pos := 3;
    LOOP
      l_buf := DBMS_LOB.SUBSTR(p_blob, 2, l_pos);
      EXIT WHEN l_buf IS NULL OR l_pos >= l_len;
      EXIT WHEN l_buf = HEXTORAW('FFDA');  -- SOS (Start of Scan)
      EXIT WHEN l_buf = HEXTORAW('FFD9');  -- EOI (End of Image)
      EXIT WHEN SUBSTR(RAWTOHEX(l_buf), 1, 2) != 'FF';

      -- Marker-only segments (no length field).
      IF RAWTOHEX(l_buf) IN ('FFD0','FFD1','FFD2','FFD3',
                              'FFD4','FFD5','FFD6','FFD7','FF01') THEN
        l_pos := l_pos + 2;
      ELSE
        IF l_buf = HEXTORAW('FFC0') THEN  -- SOF0: baseline DCT
          l_img.color_res := blob2num(p_blob, 1, l_pos + 4);
          l_img.height    := blob2num(p_blob, 2, l_pos + 5);
          l_img.width     := blob2num(p_blob, 2, l_pos + 7);
          l_img.nr_colors := blob2num(p_blob, 1, l_pos + 9);
          l_img.greyscale := (l_img.nr_colors = 1);
        END IF;
        l_seg_len := blob2num(p_blob, 2, l_pos + 2);
        EXIT WHEN l_seg_len IS NULL;
        l_pos := l_pos + 2 + l_seg_len;
      END IF;
    END LOOP;

    -- For JPEG the pixels blob must be a copy — the caller may free p_blob.
    DBMS_LOB.CREATETEMPORARY(l_img.pixels, TRUE, DBMS_LOB.SESSION);
    IF l_len > 0 THEN
      DBMS_LOB.COPY(l_img.pixels, p_blob, l_len);
    END IF;

    RETURN l_img;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_img.pixels IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_img.pixels) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_img.pixels);
      END IF;
      RAISE;
  END parse_jpg;

-- ---------------------------------------------------------------------------
-- PRIVATE: PNG parser
-- ---------------------------------------------------------------------------
  FUNCTION parse_png(p_blob IN BLOB) RETURN t_image IS
    l_img        t_image;
    l_len        NUMBER := NVL(DBMS_LOB.GETLENGTH(p_blob), 0);
    l_pos        PLS_INTEGER := 9;
    l_chunk_len  PLS_INTEGER;
    l_chunk_typ  VARCHAR2(4);
    l_color_type PLS_INTEGER;
  BEGIN
    IF l_len < 8 THEN RETURN l_img; END IF;
    IF RAWTOHEX(DBMS_LOB.SUBSTR(p_blob, 8, 1)) != '89504E470D0A1A0A' THEN
      RETURN l_img;
    END IF;

    l_img.img_type := 'png';
    DBMS_LOB.CREATETEMPORARY(l_img.pixels, TRUE, DBMS_LOB.SESSION);

    LOOP
      EXIT WHEN l_pos > l_len;
      l_chunk_len := blob2num(p_blob, 4, l_pos);
      EXIT WHEN l_chunk_len IS NULL;
      l_chunk_typ := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(p_blob, 4, l_pos + 4));

      CASE l_chunk_typ
        WHEN 'IHDR' THEN
          l_img.width      := blob2num(p_blob, 4, l_pos + 8);
          l_img.height     := blob2num(p_blob, 4, l_pos + 12);
          l_img.color_res  := blob2num(p_blob, 1, l_pos + 16);
          l_color_type     := blob2num(p_blob, 1, l_pos + 17);
          l_img.greyscale  := l_color_type IN (0, 4);
          l_img.nr_colors  := CASE l_color_type
                                WHEN 0 THEN 1   -- greyscale
                                WHEN 2 THEN 3   -- RGB
                                WHEN 3 THEN 1   -- indexed
                                WHEN 4 THEN 2   -- greyscale + alpha
                                ELSE        4   -- RGBA
                              END;
        WHEN 'PLTE' THEN
          l_img.color_tab := DBMS_LOB.SUBSTR(p_blob,
                               LEAST(l_chunk_len, 768), l_pos + 8);
        WHEN 'IDAT' THEN
          IF l_chunk_len > 0 THEN
            DBMS_LOB.COPY(l_img.pixels, p_blob, l_chunk_len,
                          DBMS_LOB.GETLENGTH(l_img.pixels) + 1, l_pos + 8);
          END IF;
        WHEN 'IEND' THEN EXIT;
        ELSE NULL;
      END CASE;

      l_pos := l_pos + 4 + 4 + l_chunk_len + 4;  -- length + type + data + CRC
    END LOOP;

    RETURN l_img;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_img.pixels IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_img.pixels) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_img.pixels);
      END IF;
      RAISE;
  END parse_png;

-- ---------------------------------------------------------------------------
-- PRIVATE: GIF LZW decompressor
-- ---------------------------------------------------------------------------
  FUNCTION lzw_decompress(p_blob IN BLOB, p_bits IN PLS_INTEGER) RETURN BLOB IS
    TYPE t_lzw_dict IS TABLE OF RAW(1000) INDEX BY PLS_INTEGER;
    l_dict       t_lzw_dict;
    l_result     BLOB;
    l_clr_code   PLS_INTEGER;
    l_nxt_code   PLS_INTEGER;
    l_new_code   PLS_INTEGER;
    l_old_code   PLS_INTEGER;
    l_bits       PLS_INTEGER := p_bits;
    l_ind        PLS_INTEGER := 0;
    l_buf_val    PLS_INTEGER := 0;
    l_buf_bits   PLS_INTEGER := 0;
    l_blob_len   NUMBER := NVL(DBMS_LOB.GETLENGTH(p_blob), 0);
    l_powers     DBMS_SQL.NUMBER_TABLE;

    FUNCTION get_code RETURN PLS_INTEGER IS
      l_rv   PLS_INTEGER;
      l_byte PLS_INTEGER;
    BEGIN
      WHILE l_buf_bits < l_bits LOOP
        l_ind := l_ind + 1;
        EXIT WHEN l_ind > l_blob_len;
        l_byte     := raw2num(DBMS_LOB.SUBSTR(p_blob, 1, l_ind));
        l_buf_val  := l_buf_val + l_byte * l_powers(l_buf_bits);
        l_buf_bits := l_buf_bits + 8;
      END LOOP;
      l_rv       := MOD(l_buf_val, l_powers(l_bits));
      l_buf_val  := TRUNC(l_buf_val / l_powers(l_bits));
      l_buf_bits := l_buf_bits - l_bits;
      RETURN l_rv;
    END get_code;

  BEGIN
    FOR i IN 0 .. 30 LOOP
      l_powers(i) := POWER(2, i);
    END LOOP;

    l_clr_code := l_powers(p_bits - 1);
    l_nxt_code := l_clr_code + 2;

    FOR i IN 0 .. LEAST(l_clr_code - 1, 255) LOOP
      l_dict(i) := HEXTORAW(TO_CHAR(i, 'FM0X'));
    END LOOP;

    DBMS_LOB.CREATETEMPORARY(l_result, TRUE, DBMS_LOB.SESSION);

    l_old_code := NULL;
    l_new_code := get_code();

    LOOP
      CASE NVL(l_new_code, l_clr_code + 1)
        WHEN l_clr_code + 1 THEN
          EXIT;
        WHEN l_clr_code THEN
          l_new_code := NULL;
          l_bits     := p_bits;
          l_nxt_code := l_clr_code + 2;
        ELSE
          IF l_new_code = l_nxt_code THEN
            l_dict(l_nxt_code) := UTL_RAW.CONCAT(
              l_dict(l_old_code),
              UTL_RAW.SUBSTR(l_dict(l_old_code), 1, 1));
            blob_append_raw(l_result, l_dict(l_nxt_code));
            l_nxt_code := l_nxt_code + 1;
          ELSIF l_new_code > l_nxt_code THEN
            EXIT;
          ELSE
            blob_append_raw(l_result, l_dict(l_new_code));
            IF l_old_code IS NOT NULL THEN
              l_dict(l_nxt_code) := UTL_RAW.CONCAT(
                l_dict(l_old_code),
                UTL_RAW.SUBSTR(l_dict(l_new_code), 1, 1));
              l_nxt_code := l_nxt_code + 1;
            END IF;
          END IF;
          IF l_bits < 12 AND MOD(l_nxt_code, l_powers(l_bits)) = 0 THEN
            l_bits := l_bits + 1;
          END IF;
      END CASE;
      l_old_code := l_new_code;
      l_new_code := get_code();
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

-- ---------------------------------------------------------------------------
-- PRIVATE: GIF parser
-- ---------------------------------------------------------------------------
  FUNCTION parse_gif(p_blob IN BLOB) RETURN t_image IS
    l_img    t_image;
    l_len    NUMBER := NVL(DBMS_LOB.GETLENGTH(p_blob), 0);
    l_ind    PLS_INTEGER;
    l_t_len  PLS_INTEGER;
    l_byte1  RAW(1);
    l_done   BOOLEAN := FALSE;
  BEGIN
    IF l_len < 6 THEN RETURN l_img; END IF;
    IF DBMS_LOB.SUBSTR(p_blob, 3, 1) != UTL_RAW.CAST_TO_RAW('GIF') THEN
      RETURN l_img;
    END IF;

    l_img.img_type  := 'gif';
    l_img.color_res := 8;

    -- Logical Screen Descriptor starts at byte 7 (6-byte header).
    -- Packed field (byte 5 of LSD = byte 11 overall) contains GCT flag and size.
    l_ind := 14;  -- first byte after the 13-byte header + LSD

    IF raw2num(DBMS_LOB.SUBSTR(p_blob, 1, 11)) > 127 THEN
      -- Global Color Table present; size = 2^(low3bits+1) entries * 3 bytes.
      l_t_len := 3 * POWER(2,
                   raw2num(UTL_RAW.BIT_AND(
                     DBMS_LOB.SUBSTR(p_blob, 1, 11), HEXTORAW('07'))) + 1);
      l_img.color_tab := DBMS_LOB.SUBSTR(p_blob, LEAST(l_t_len, 768), l_ind);
      l_ind := l_ind + l_t_len;
    END IF;

    LOOP
      EXIT WHEN l_ind > l_len OR l_done;
      l_byte1 := DBMS_LOB.SUBSTR(p_blob, 1, l_ind);

      IF l_byte1 = HEXTORAW('3B') THEN       -- Trailer
        EXIT;

      ELSIF l_byte1 = HEXTORAW('21') THEN    -- Extension block
        IF DBMS_LOB.SUBSTR(p_blob, 1, l_ind + 1) = HEXTORAW('F9') THEN
          -- Graphic Control Extension: check transparent colour flag.
          IF UTL_RAW.BIT_AND(DBMS_LOB.SUBSTR(p_blob, 1, l_ind + 3),
                              HEXTORAW('01')) = HEXTORAW('01') THEN
            l_img.transp_idx := blob2num(p_blob, 1, l_ind + 6);
          END IF;
        END IF;
        l_ind := l_ind + 2;  -- skip sentinel + label
        LOOP
          l_t_len := blob2num(p_blob, 1, l_ind);
          EXIT WHEN l_t_len = 0;
          l_ind := l_ind + 1 + l_t_len;
        END LOOP;
        l_ind := l_ind + 1;  -- skip terminal Block Size (0)

      ELSIF l_byte1 = HEXTORAW('2C') THEN    -- Image Descriptor
        DECLARE
          l_img_blob    BLOB;
          l_min_bits    PLS_INTEGER;
          l_flags       RAW(1);
        BEGIN
          l_img.width  := UTL_RAW.CAST_TO_BINARY_INTEGER(
                            DBMS_LOB.SUBSTR(p_blob, 2, l_ind + 5),
                            UTL_RAW.LITTLE_ENDIAN);
          l_img.height := UTL_RAW.CAST_TO_BINARY_INTEGER(
                            DBMS_LOB.SUBSTR(p_blob, 2, l_ind + 7),
                            UTL_RAW.LITTLE_ENDIAN);
          l_img.greyscale := FALSE;
          l_ind := l_ind + 1 + 8;  -- skip sentinel + 8 image descriptor bytes

          l_flags := DBMS_LOB.SUBSTR(p_blob, 1, l_ind);

          IF UTL_RAW.BIT_AND(l_flags, HEXTORAW('80')) = HEXTORAW('80') THEN
            -- Local Color Table overrides global palette.
            l_t_len := 3 * POWER(2,
                         raw2num(UTL_RAW.BIT_AND(l_flags, HEXTORAW('07'))) + 1);
            l_img.color_tab := DBMS_LOB.SUBSTR(
                                  p_blob, LEAST(l_t_len, 768), l_ind + 1);
          END IF;
          l_ind := l_ind + 1;

          l_min_bits := blob2num(p_blob, 1, l_ind);
          l_ind := l_ind + 1;

          -- Collect all LZW data sub-blocks into one BLOB.
          DBMS_LOB.CREATETEMPORARY(l_img_blob, TRUE, DBMS_LOB.SESSION);
          LOOP
            l_t_len := blob2num(p_blob, 1, l_ind);
            EXIT WHEN l_t_len = 0;
            blob_append_raw(l_img_blob,
                            DBMS_LOB.SUBSTR(p_blob, l_t_len, l_ind + 1));
            l_ind := l_ind + 1 + l_t_len;
          END LOOP;
          l_ind := l_ind + 1;  -- skip terminal Block Size (0)

          l_img.pixels := lzw_decompress(l_img_blob, l_min_bits + 1);
          DBMS_LOB.FREETEMPORARY(l_img_blob);

          -- De-interlace if the Interlace flag is set.
          IF UTL_RAW.BIT_AND(l_flags, HEXTORAW('40')) = HEXTORAW('40') THEN
            DECLARE
              l_deint BLOB;
              l_pass  PLS_INTEGER;
              l_pi    DBMS_SQL.NUMBER_TABLE;
            BEGIN
              DBMS_LOB.CREATETEMPORARY(l_deint, TRUE, DBMS_LOB.SESSION);
              l_pi(1) := 1;
              l_pi(2) := TRUNC((l_img.height - 1) / 8) + 1;
              l_pi(3) := l_pi(2) + TRUNC((l_img.height + 3) / 8);
              l_pi(4) := l_pi(3) + TRUNC((l_img.height + 1) / 4);
              l_pi(2) := l_pi(2) * l_img.width + 1;
              l_pi(3) := l_pi(3) * l_img.width + 1;
              l_pi(4) := l_pi(4) * l_img.width + 1;
              FOR i IN 0 .. l_img.height - 1 LOOP
                l_pass := CASE MOD(i, 8)
                            WHEN 0 THEN 1
                            WHEN 4 THEN 2
                            WHEN 2 THEN 3
                            WHEN 6 THEN 3
                            ELSE        4
                          END;
                blob_append_raw(l_deint,
                  DBMS_LOB.SUBSTR(l_img.pixels, l_img.width, l_pi(l_pass)));
                l_pi(l_pass) := l_pi(l_pass) + l_img.width;
              END LOOP;
              IF DBMS_LOB.ISTEMPORARY(l_img.pixels) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_img.pixels);
              END IF;
              l_img.pixels := l_deint;
            END;
          END IF;

          l_done := TRUE;  -- Only the first image frame is embedded.
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

    RETURN l_img;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_img.pixels IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_img.pixels) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_img.pixels);
      END IF;
      RAISE;
  END parse_gif;

-- ---------------------------------------------------------------------------
-- PRIVATE: Format detection and dispatch
-- ---------------------------------------------------------------------------
  FUNCTION parse_image(p_blob   IN BLOB,
                       p_sha256 IN VARCHAR2) RETURN t_image IS
    l_img  t_image;
    l_len  NUMBER := NVL(DBMS_LOB.GETLENGTH(p_blob), 0);
  BEGIN
    IF l_len = 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_images.load_image: empty image data', TRUE);
    END IF;

    -- Detect format by magic bytes.
    IF RAWTOHEX(DBMS_LOB.SUBSTR(p_blob, 8, 1)) = '89504E470D0A1A0A' THEN
      l_img := parse_png(p_blob);
    ELSIF DBMS_LOB.SUBSTR(p_blob, 3, 1) = UTL_RAW.CAST_TO_RAW('GIF') THEN
      l_img := parse_gif(p_blob);
    ELSIF RAWTOHEX(DBMS_LOB.SUBSTR(p_blob, 2, 1)) = 'FFD8' THEN
      l_img := parse_jpg(p_blob);
    ELSE
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
        'rad_pdf_images.load_image: unsupported image format '
        || '(expected PNG, GIF, or JPEG)', TRUE);
    END IF;

    IF l_img.width IS NULL OR l_img.width = 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
        'rad_pdf_images.load_image: could not determine image dimensions', TRUE);
    END IF;

    l_img.sha256 := p_sha256;
    RETURN l_img;
  END parse_image;

-- ---------------------------------------------------------------------------
-- PRIVATE: SHA-256 (computed once, stored as the cache key)
-- ---------------------------------------------------------------------------
  FUNCTION sha256_hex(p_blob IN BLOB) RETURN VARCHAR2 IS
  BEGIN
    RETURN RAWTOHEX(DBMS_CRYPTO.HASH(p_blob, DBMS_CRYPTO.HASH_SH256));
  END sha256_hex;

-- ---------------------------------------------------------------------------
-- PRIVATE: LRU eviction — free oldest entries until new_bytes fits in limit
-- ---------------------------------------------------------------------------
  PROCEDURE evict_to_fit(p_new_bytes IN NUMBER) IS
    l_key      VARCHAR2(64);
    l_oldest   VARCHAR2(64);
    l_oldest_t TIMESTAMP;
  BEGIN
    WHILE g_cache_bytes + p_new_bytes > g_cache_limit
          AND g_cache.COUNT > 0 LOOP
      l_key    := g_cache.FIRST;
      l_oldest := l_key;
      l_oldest_t := g_cache(l_key).last_used;
      WHILE l_key IS NOT NULL LOOP
        IF g_cache(l_key).last_used < l_oldest_t THEN
          l_oldest   := l_key;
          l_oldest_t := g_cache(l_key).last_used;
        END IF;
        l_key := g_cache.NEXT(l_key);
      END LOOP;
      IF g_cache(l_oldest).img.pixels IS NOT NULL
         AND DBMS_LOB.ISTEMPORARY(g_cache(l_oldest).img.pixels) = 1 THEN
        DBMS_LOB.FREETEMPORARY(g_cache(l_oldest).img.pixels);
      END IF;
      g_cache_bytes := g_cache_bytes - g_cache(l_oldest).byte_size;
      g_cache.DELETE(l_oldest);
    END LOOP;
  END evict_to_fit;

-- ---------------------------------------------------------------------------
-- PRIVATE: Add parsed image to session cache; return its sha256 key
-- ---------------------------------------------------------------------------
  FUNCTION cache_image(p_blob IN BLOB) RETURN VARCHAR2 IS
    l_sha256    VARCHAR2(64);
    l_entry     t_cache_entry;
    l_byte_size NUMBER;
  BEGIN
    l_sha256 := sha256_hex(p_blob);

    IF g_cache.EXISTS(l_sha256) THEN
      g_cache(l_sha256).last_used := SYSTIMESTAMP;
      RETURN l_sha256;
    END IF;

    l_entry.img       := parse_image(p_blob, l_sha256);
    l_byte_size       := NVL(DBMS_LOB.GETLENGTH(l_entry.img.pixels), 0);
    l_entry.byte_size := l_byte_size;
    l_entry.last_used := SYSTIMESTAMP;

    evict_to_fit(l_byte_size);

    g_cache(l_sha256) := l_entry;
    g_cache_bytes     := g_cache_bytes + l_byte_size;

    RETURN l_sha256;
  END cache_image;

-- ---------------------------------------------------------------------------
-- PRIVATE: Register image for p_doc; return its image_id
-- ---------------------------------------------------------------------------
  FUNCTION register_image(p_doc    IN rad_pdf_types.t_doc_handle,
                          p_sha256 IN VARCHAR2) RETURN PLS_INTEGER IS
    l_id PLS_INTEGER;
  BEGIN
    IF NOT g_doc_state.EXISTS(p_doc) THEN
      g_doc_state(p_doc).next_id := 1;
    END IF;
    IF g_doc_state(p_doc).used_id.EXISTS(p_sha256) THEN
      RETURN g_doc_state(p_doc).used_id(p_sha256);
    END IF;
    l_id := NVL(g_doc_state(p_doc).next_id, 1);
    g_doc_state(p_doc).next_id    := l_id + 1;
    g_doc_state(p_doc).used_hash(l_id)   := p_sha256;
    g_doc_state(p_doc).used_id(p_sha256) := l_id;
    RETURN l_id;
  END register_image;

-- ---------------------------------------------------------------------------
-- PRIVATE: Fetch a BLOB over HTTPS with redirect validation
-- ---------------------------------------------------------------------------
  FUNCTION fetch_https(p_url IN VARCHAR2) RETURN BLOB IS
    c_max_bytes CONSTANT NUMBER       := 10485760;  -- 10 MB
    c_max_redir CONSTANT PLS_INTEGER  := 3;
    l_req    UTL_HTTP.REQ;
    l_resp   UTL_HTTP.RESP;
    l_url    VARCHAR2(4000) := p_url;
    l_redir  PLS_INTEGER    := 0;
    l_buf    RAW(32767);
    l_result BLOB;
    l_total  NUMBER := 0;
    l_ctype  VARCHAR2(200);
    l_loc    VARCHAR2(4000);
    l_hname  VARCHAR2(256);
    l_hval   VARCHAR2(1024);
    l_done   BOOLEAN;
  BEGIN
    DBMS_LOB.CREATETEMPORARY(l_result, TRUE, DBMS_LOB.SESSION);

    LOOP
      assert_https_url(l_url);
      UTL_HTTP.SET_TRANSFER_TIMEOUT(30);
      l_req := UTL_HTTP.BEGIN_REQUEST(l_url, 'GET', 'HTTP/1.1');
      UTL_HTTP.SET_HEADER(l_req, 'User-Agent', 'rad_pdf_images/2.0');

      BEGIN
        l_resp := UTL_HTTP.GET_RESPONSE(l_req);
      EXCEPTION
        WHEN OTHERS THEN
          UTL_HTTP.END_REQUEST(l_req);
          RAISE;
      END;

      BEGIN
        IF l_resp.status_code IN (301, 302, 303, 307, 308) THEN
          l_redir := l_redir + 1;
          IF l_redir > c_max_redir THEN
            UTL_HTTP.END_RESPONSE(l_resp);
            RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_io,
              'rad_pdf_images: too many HTTP redirects', TRUE);
          END IF;
          l_loc := NULL;
          FOR i IN 1 .. UTL_HTTP.GET_HEADER_COUNT(l_resp) LOOP
            UTL_HTTP.GET_HEADER(l_resp, i, l_hname, l_hval);
            IF UPPER(l_hname) = 'LOCATION' THEN l_loc := l_hval; END IF;
          END LOOP;
          UTL_HTTP.END_RESPONSE(l_resp);
          IF l_loc IS NULL THEN
            RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_io,
              'rad_pdf_images: redirect with no Location header', TRUE);
          END IF;
          IF UPPER(SUBSTR(l_loc, 1, 8)) != 'HTTPS://' THEN
            RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
              'rad_pdf_images: redirect to non-HTTPS URL blocked', TRUE);
          END IF;
          l_url := l_loc;
          CONTINUE;
        END IF;

        IF l_resp.status_code != 200 THEN
          UTL_HTTP.END_RESPONSE(l_resp);
          RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_io,
            'rad_pdf_images: HTTP ' || l_resp.status_code, TRUE);
        END IF;

        -- Validate Content-Type.
        l_ctype := NULL;
        FOR i IN 1 .. UTL_HTTP.GET_HEADER_COUNT(l_resp) LOOP
          UTL_HTTP.GET_HEADER(l_resp, i, l_hname, l_hval);
          IF UPPER(l_hname) = 'CONTENT-TYPE' THEN l_ctype := LOWER(l_hval); END IF;
        END LOOP;
        IF l_ctype IS NOT NULL
           AND l_ctype NOT LIKE '%image/jpeg%'
           AND l_ctype NOT LIKE '%image/jpg%'
           AND l_ctype NOT LIKE '%image/png%'
           AND l_ctype NOT LIKE '%image/gif%'
           AND l_ctype NOT LIKE '%application/octet-stream%' THEN
          UTL_HTTP.END_RESPONSE(l_resp);
          RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
            'rad_pdf_images: unexpected Content-Type: ' || SUBSTR(l_ctype, 1, 100), TRUE);
        END IF;

        -- Read response body.
        l_done := FALSE;
        WHILE NOT l_done LOOP
          BEGIN
            UTL_HTTP.READ_RAW(l_resp, l_buf, 32767);
            l_total := l_total + UTL_RAW.LENGTH(l_buf);
            IF l_total > c_max_bytes THEN
              UTL_HTTP.END_RESPONSE(l_resp);
              RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
                'rad_pdf_images: image response exceeds 10 MB limit', TRUE);
            END IF;
            blob_append_raw(l_result, l_buf);
          EXCEPTION
            WHEN UTL_HTTP.END_OF_BODY THEN l_done := TRUE;
          END;
        END LOOP;
        UTL_HTTP.END_RESPONSE(l_resp);
        EXIT;
      EXCEPTION
        WHEN OTHERS THEN
          BEGIN UTL_HTTP.END_RESPONSE(l_resp); EXCEPTION WHEN OTHERS THEN NULL; END;
          RAISE;
      END;
    END LOOP;

    RETURN l_result;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_result IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_result) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_result);
      END IF;
      RAISE;
  END fetch_https;

-- ---------------------------------------------------------------------------
-- Public: set_image_cache_limit
-- ---------------------------------------------------------------------------
  PROCEDURE set_image_cache_limit(p_bytes IN NUMBER DEFAULT 52428800) IS
  BEGIN
    g_cache_limit := NVL(p_bytes, 52428800);
  END set_image_cache_limit;

-- ---------------------------------------------------------------------------
-- Public: load_image (BLOB)
-- ---------------------------------------------------------------------------
  FUNCTION load_image(p_doc IN rad_pdf_types.t_doc_handle,
                      p_img IN BLOB) RETURN PLS_INTEGER IS
    l_sha256 VARCHAR2(64);
  BEGIN
    IF p_img IS NULL OR NVL(DBMS_LOB.GETLENGTH(p_img), 0) = 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_images.load_image: NULL or empty BLOB', TRUE);
    END IF;
    l_sha256 := cache_image(p_img);
    RETURN register_image(p_doc, l_sha256);
  END load_image;

-- ---------------------------------------------------------------------------
-- Public: load_image (Oracle Directory file)
-- ---------------------------------------------------------------------------
  FUNCTION load_image(p_doc      IN rad_pdf_types.t_doc_handle,
                      p_dir      IN VARCHAR2,
                      p_filename IN VARCHAR2) RETURN PLS_INTEGER IS
    l_bfile BFILE;
    l_blob  BLOB;
    l_id    PLS_INTEGER;
  BEGIN
    assert_dir_and_file(p_dir, p_filename);
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE, DBMS_LOB.SESSION);
    l_bfile := BFILENAME(p_dir, p_filename);
    DBMS_LOB.OPEN(l_bfile, DBMS_LOB.LOB_READONLY);
    DBMS_LOB.LOADFROMFILE(l_blob, l_bfile, DBMS_LOB.GETLENGTH(l_bfile));
    DBMS_LOB.CLOSE(l_bfile);
    l_id := load_image(p_doc, l_blob);
    DBMS_LOB.FREETEMPORARY(l_blob);
    RETURN l_id;
  EXCEPTION
    WHEN OTHERS THEN
      BEGIN DBMS_LOB.CLOSE(l_bfile); EXCEPTION WHEN OTHERS THEN NULL; END;
      IF l_blob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_blob) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_blob);
      END IF;
      RAISE;
  END load_image;

-- ---------------------------------------------------------------------------
-- Public: load_image (HTTPS URL)
-- ---------------------------------------------------------------------------
  FUNCTION load_image(p_doc IN rad_pdf_types.t_doc_handle,
                      p_url IN VARCHAR2) RETURN PLS_INTEGER IS
    l_blob BLOB;
    l_id   PLS_INTEGER;
  BEGIN
    assert_https_url(p_url);
    l_blob := fetch_https(p_url);
    l_id   := load_image(p_doc, l_blob);
    DBMS_LOB.FREETEMPORARY(l_blob);
    RETURN l_id;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_blob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_blob) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_blob);
      END IF;
      RAISE;
  END load_image;

-- ---------------------------------------------------------------------------
-- Public: get_image_dimensions
-- ---------------------------------------------------------------------------
  PROCEDURE get_image_dimensions(p_doc      IN  rad_pdf_types.t_doc_handle,
                                 p_image_id IN  PLS_INTEGER,
                                 p_width    OUT NUMBER,
                                 p_height   OUT NUMBER) IS
    l_sha256 VARCHAR2(64);
  BEGIN
    IF NOT g_doc_state.EXISTS(p_doc)
       OR NOT g_doc_state(p_doc).used_hash.EXISTS(p_image_id) THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_images.get_image_dimensions: invalid image_id ' || p_image_id, TRUE);
    END IF;
    l_sha256 := g_doc_state(p_doc).used_hash(p_image_id);
    p_width  := g_cache(l_sha256).img.width;
    p_height := g_cache(l_sha256).img.height;
  END get_image_dimensions;

-- ---------------------------------------------------------------------------
-- PRIVATE: strip_png_alpha
-- Removes the alpha channel from a PNG with color_type 4 (grey+alpha) or
-- 6 (RGBA) by decompressing the IDAT stream, reversing all 5 PNG filter types,
-- dropping the alpha bytes, and storing the result as raw RGB/grey pixels.
-- p_img.pixels_raw is set to TRUE so write_image_objects uses write_stream_obj
-- with p_compress=TRUE (like GIF), skipping Predictor 15 DecodeParms.
-- Only 8-bit-per-channel images are supported (color_res = 8).
-- ---------------------------------------------------------------------------
  PROCEDURE strip_png_alpha(p_img IN OUT t_image) IS
    l_in_ch    PLS_INTEGER := p_img.nr_colors;          -- 2 (grey+A) or 4 (RGBA)
    l_out_ch   PLS_INTEGER := p_img.nr_colors - 1;      -- 1 or 3
    l_row_in   PLS_INTEGER := 1 + p_img.width * l_in_ch; -- bytes per input row (filter + pixels)
    l_uncomp   NUMBER      := p_img.height * l_row_in;
    l_raw      BLOB;  -- decompressed IDAT
    l_out      BLOB;  -- output raw colour pixels (no filter bytes, no alpha)
    l_alpha    BLOB;  -- output raw alpha pixels (greyscale, for SMask)

    TYPE t_bytes IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    l_cur  t_bytes;  -- reconstructed raw bytes for current row (width * in_ch)
    l_prev t_bytes;  -- reconstructed raw bytes for previous row

    l_row_hex   VARCHAR2(32767);
    l_out_hex   VARCHAR2(32767);
    l_alpha_hex VARCHAR2(32767);
    l_filt     PLS_INTEGER;
    l_byte     PLS_INTEGER;
    l_raw_byte PLS_INTEGER;
    l_a        PLS_INTEGER;  -- left (same channel, previous pixel)
    l_b        PLS_INTEGER;  -- up   (same channel, previous row)
    l_c        PLS_INTEGER;  -- upper-left
    l_p        PLS_INTEGER;
    i          PLS_INTEGER;
    p          PLS_INTEGER;
    ch         PLS_INTEGER;

    FUNCTION paeth(a PLS_INTEGER, b PLS_INTEGER, c PLS_INTEGER)
      RETURN PLS_INTEGER IS
      lp  PLS_INTEGER := a + b - c;
      lpa PLS_INTEGER := ABS(lp - a);
      lpb PLS_INTEGER := ABS(lp - b);
      lpc PLS_INTEGER := ABS(lp - c);
    BEGIN
      IF lpa <= lpb AND lpa <= lpc THEN RETURN a;
      ELSIF lpb <= lpc THEN RETURN b;
      ELSE RETURN c;
      END IF;
    END paeth;

  BEGIN
    IF p_img.color_res != 8 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
        'rad_pdf_images: alpha stripping requires 8-bit PNG'
        || ' - convert to 8-bit or JPEG', TRUE);
    END IF;

    -- Decompress the concatenated IDAT zlib stream.
    l_raw := rad_pdf_codec.flate_decode(p_img.pixels, l_uncomp);

    IF NVL(DBMS_LOB.GETLENGTH(l_raw), 0) < l_uncomp THEN
      DBMS_LOB.FREETEMPORARY(l_raw);
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
        'rad_pdf_images: PNG decompression returned unexpected size', TRUE);
    END IF;

    DBMS_LOB.CREATETEMPORARY(l_out,   TRUE, DBMS_LOB.SESSION);
    DBMS_LOB.CREATETEMPORARY(l_alpha, TRUE, DBMS_LOB.SESSION);

    -- Initialise previous row to all zeros (virtual row above first row).
    FOR i IN 0 .. p_img.width * l_in_ch - 1 LOOP
      l_prev(i) := 0;
    END LOOP;

    FOR row_idx IN 0 .. p_img.height - 1 LOOP
      -- Read one input row as hex string (filter byte + width*in_ch pixel bytes).
      l_row_hex := RAWTOHEX(
                     DBMS_LOB.SUBSTR(l_raw, l_row_in,
                                     1 + row_idx * l_row_in));
      l_filt := TO_NUMBER(SUBSTR(l_row_hex, 1, 2), 'XX');

      -- Reconstruct raw pixel bytes by reversing the filter for each byte.
      FOR i IN 0 .. p_img.width * l_in_ch - 1 LOOP
        l_byte := TO_NUMBER(SUBSTR(l_row_hex, 2*i + 3, 2), 'XX');
        l_a := CASE WHEN i >= l_in_ch THEN l_cur(i - l_in_ch) ELSE 0 END;
        l_b := NVL(l_prev(i), 0);
        l_c := CASE WHEN i >= l_in_ch THEN NVL(l_prev(i - l_in_ch), 0) ELSE 0 END;
        l_raw_byte := MOD(
          l_byte + CASE l_filt
                     WHEN 0 THEN 0
                     WHEN 1 THEN l_a
                     WHEN 2 THEN l_b
                     WHEN 3 THEN TRUNC((l_a + l_b) / 2)
                     WHEN 4 THEN paeth(l_a, l_b, l_c)
                     ELSE 0
                   END, 256);
        l_cur(i) := l_raw_byte;
      END LOOP;

      -- Build output: colour channels → l_out, alpha channel → l_alpha (SMask).
      l_out_hex   := '';
      l_alpha_hex := '';
      FOR p IN 0 .. p_img.width - 1 LOOP
        FOR ch IN 0 .. l_out_ch - 1 LOOP
          l_out_hex := l_out_hex
                    || LPAD(TO_CHAR(l_cur(p * l_in_ch + ch), 'FMXX'), 2, '0');
        END LOOP;
        -- Alpha is always the last channel.
        l_alpha_hex := l_alpha_hex
                    || LPAD(TO_CHAR(l_cur(p * l_in_ch + l_in_ch - 1), 'FMXX'), 2, '0');
      END LOOP;
      blob_append_raw(l_out,   HEXTORAW(l_out_hex));
      blob_append_raw(l_alpha, HEXTORAW(l_alpha_hex));

      -- Swap current row into previous.
      l_prev := l_cur;
    END LOOP;

    DBMS_LOB.FREETEMPORARY(l_raw);
    IF DBMS_LOB.ISTEMPORARY(p_img.pixels) = 1 THEN
      DBMS_LOB.FREETEMPORARY(p_img.pixels);
    END IF;

    p_img.pixels     := l_out;
    p_img.smask      := l_alpha;
    p_img.nr_colors  := l_out_ch;
    p_img.greyscale  := (l_out_ch = 1);
    p_img.pixels_raw := TRUE;

  EXCEPTION
    WHEN OTHERS THEN
      IF l_raw   IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_raw)   = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_raw);
      END IF;
      IF l_out   IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_out)   = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_out);
      END IF;
      IF l_alpha IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_alpha) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_alpha);
      END IF;
      RAISE;
  END strip_png_alpha;

-- ---------------------------------------------------------------------------
-- Public: write_image_objects
-- Writes PDF XObject streams for every image referenced in p_doc.
-- Returns the XObject resource string fragment, e.g. '/I1 5 0 R /I2 7 0 R'.
-- ---------------------------------------------------------------------------
  FUNCTION write_image_objects(p_doc IN rad_pdf_types.t_doc_handle) RETURN VARCHAR2 IS
    l_xobj_frag VARCHAR2(32767) := '';
    l_id        PLS_INTEGER;
    l_sha256    VARCHAR2(64);
    l_img       t_image;
    l_obj_nr    NUMBER;
    l_pal_obj    NUMBER;
    l_smask_obj  NUMBER;
    l_pal_blob   BLOB;
    l_smask_data BLOB;
    l_extra      VARCHAR2(500);
    l_data       BLOB;
  BEGIN
    IF NOT g_doc_state.EXISTS(p_doc)
       OR g_doc_state(p_doc).used_hash.COUNT = 0 THEN
      RETURN NULL;
    END IF;

    l_id := g_doc_state(p_doc).used_hash.FIRST;
    WHILE l_id IS NOT NULL LOOP
      l_sha256 := g_doc_state(p_doc).used_hash(l_id);
      l_img    := g_cache(l_sha256).img;

      -- Update LRU timestamp.
      g_cache(l_sha256).last_used := SYSTIMESTAMP;

      l_extra := ' /Type /XObject /Subtype /Image'
              || ' /Width '             || TO_CHAR(l_img.width)
              || ' /Height '            || TO_CHAR(l_img.height)
              || ' /BitsPerComponent '  || TO_CHAR(l_img.color_res);

      IF l_img.transp_idx IS NOT NULL THEN
        l_extra := l_extra
                || ' /Mask [' || l_img.transp_idx
                || ' '        || l_img.transp_idx || ']';
      END IF;

      -- Write palette stream object first.
      l_pal_obj  := NULL;
      l_pal_blob := NULL;
      IF l_img.color_tab IS NOT NULL THEN
        DBMS_LOB.CREATETEMPORARY(l_pal_blob, TRUE, DBMS_LOB.SESSION);
        blob_append_raw(l_pal_blob, l_img.color_tab);
        l_pal_obj := rad_pdf_serial.write_stream_obj(p_doc, l_pal_blob, NULL, FALSE);
        DBMS_LOB.FREETEMPORARY(l_pal_blob);
        l_pal_blob := NULL;

        l_extra := l_extra
                || ' /ColorSpace [/Indexed /DeviceRGB '
                || TO_CHAR(UTL_RAW.LENGTH(l_img.color_tab) / 3 - 1)
                || ' ' || TO_CHAR(l_pal_obj) || ' 0 R]';
      ELSIF l_img.greyscale THEN
        l_extra := l_extra || ' /ColorSpace /DeviceGray';
      ELSE
        l_extra := l_extra || ' /ColorSpace /DeviceRGB';
      END IF;

      l_data := l_img.pixels;

      IF l_img.img_type = 'jpg' THEN
        l_obj_nr := rad_pdf_serial.write_stream_obj(
          p_doc, l_data, l_extra || ' /Filter /DCTDecode', FALSE);

      ELSIF l_img.img_type = 'png' THEN
        IF l_img.nr_colors IN (2, 4) THEN
          -- Strip alpha channel (decompress IDAT, reverse filters, drop alpha).
          BEGIN
            strip_png_alpha(l_img);
            l_data := l_img.pixels;
          EXCEPTION
            WHEN OTHERS THEN
              RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_image,
                'rad_pdf_images: PNG alpha channel could not be removed'
                || ' (' || SQLERRM || ')'
                || ' - flatten to RGB or convert to JPEG', TRUE);
          END;
        END IF;

        IF NVL(l_img.pixels_raw, FALSE) THEN
          -- Alpha was stripped: write SMask XObject first (greyscale alpha channel),
          -- then reference it from the main colour image via /SMask.
          l_smask_obj  := NULL;
          l_smask_data := l_img.smask;
          IF l_smask_data IS NOT NULL
             AND DBMS_LOB.GETLENGTH(l_smask_data) > 0 THEN
            l_smask_obj := rad_pdf_serial.write_stream_obj(
              p_doc, l_smask_data,
              ' /Type /XObject /Subtype /Image'
              || ' /Width '            || TO_CHAR(l_img.width)
              || ' /Height '           || TO_CHAR(l_img.height)
              || ' /BitsPerComponent 8'
              || ' /ColorSpace /DeviceGray',
              TRUE);
          END IF;

          IF l_smask_obj IS NOT NULL THEN
            l_extra := l_extra || ' /SMask ' || TO_CHAR(l_smask_obj) || ' 0 R';
          END IF;

          l_obj_nr := rad_pdf_serial.write_stream_obj(p_doc, l_data, l_extra, TRUE);
        ELSE
          l_obj_nr := rad_pdf_serial.write_stream_obj(
            p_doc, l_data,
            l_extra
              || ' /Filter /FlateDecode /DecodeParms <</Predictor 15'
              || ' /Colors '           || TO_CHAR(l_img.nr_colors)
              || ' /BitsPerComponent ' || TO_CHAR(l_img.color_res)
              || ' /Columns '          || TO_CHAR(l_img.width) || '>>',
            FALSE);
        END IF;

      ELSE
        -- GIF: raw decompressed pixels; write_stream_obj adds FlateDecode.
        l_obj_nr := rad_pdf_serial.write_stream_obj(p_doc, l_data, l_extra, TRUE);
      END IF;

      l_xobj_frag := l_xobj_frag
                  || ' /Im' || TO_CHAR(l_id)
                  || ' '    || TO_CHAR(l_obj_nr) || ' 0 R';

      l_id := g_doc_state(p_doc).used_hash.NEXT(l_id);
    END LOOP;

    RETURN TRIM(l_xobj_frag);
  EXCEPTION
    WHEN OTHERS THEN
      IF l_pal_blob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_pal_blob) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_pal_blob);
      END IF;
      RAISE;
  END write_image_objects;


-- ---------------------------------------------------------------------------
-- Public: close_doc — release per-document tracking state
-- ---------------------------------------------------------------------------
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    IF g_doc_state.EXISTS(p_doc) THEN
      g_doc_state.DELETE(p_doc);
    END IF;
  END close_doc;

-- ---------------------------------------------------------------------------
-- Public: clear_image_cache
-- ---------------------------------------------------------------------------
  PROCEDURE clear_image_cache IS
    l_key VARCHAR2(64);
  BEGIN
    l_key := g_cache.FIRST;
    WHILE l_key IS NOT NULL LOOP
      IF g_cache(l_key).img.pixels IS NOT NULL
         AND DBMS_LOB.ISTEMPORARY(g_cache(l_key).img.pixels) = 1 THEN
        DBMS_LOB.FREETEMPORARY(g_cache(l_key).img.pixels);
      END IF;
      IF g_cache(l_key).img.smask IS NOT NULL
         AND DBMS_LOB.ISTEMPORARY(g_cache(l_key).img.smask) = 1 THEN
        DBMS_LOB.FREETEMPORARY(g_cache(l_key).img.smask);
      END IF;
      l_key := g_cache.NEXT(l_key);
    END LOOP;
    g_cache.DELETE;
    g_cache_bytes := 0;
  END clear_image_cache;

-- ---------------------------------------------------------------------------
-- Public: image_exists
-- ---------------------------------------------------------------------------
  FUNCTION image_exists(p_doc      IN rad_pdf_types.t_doc_handle,
                        p_image_id IN PLS_INTEGER) RETURN BOOLEAN IS
  BEGIN
    IF NOT g_doc_state.EXISTS(p_doc) THEN RETURN FALSE; END IF;
    RETURN g_doc_state(p_doc).used_hash.EXISTS(p_image_id);
  END image_exists;

END rad_pdf_images;
/
