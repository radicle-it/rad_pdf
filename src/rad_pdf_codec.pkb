CREATE OR REPLACE PACKAGE BODY rad_pdf_codec IS
/*
  rad_pdf_codec body — binary utilities extracted and consolidated from:
    - flate_encode, adler32, fmt  ← src/new/pdf_writer.pkb
    - sha256_hex                  ← src/new/rad_pdf_images.pkb
    - escape_pdf_str, rgb_to_pdf  ← new
*/

-- ---------------------------------------------------------------------------
  FUNCTION flate_encode(p_src IN OUT NOCOPY BLOB) RETURN BLOB IS
    l_compressed BLOB;
    l_result     BLOB;
  BEGIN
    -- UTL_COMPRESS.LZ_COMPRESS produces zlib format (RFC 1950):
    --   2-byte zlib header + deflate stream + 4-byte Adler32.
    -- PDF FlateDecode requires: raw deflate stream + Adler32 appended.
    -- We strip the 2-byte header and 8-byte trailer from UTL_COMPRESS output,
    -- then append the Adler32 computed on the original (uncompressed) data.
    l_compressed := UTL_COMPRESS.LZ_COMPRESS(p_src);

    DBMS_LOB.CREATETEMPORARY(l_result, TRUE, DBMS_LOB.SESSION);

    DBMS_LOB.COPY(
      l_result,
      l_compressed,
      DBMS_LOB.GETLENGTH(l_compressed) - 10,  -- skip 2-byte header, 8-byte trailer
      1,   -- dest offset
      3    -- src offset (skip 2-byte zlib header)
    );

    DBMS_LOB.APPEND(l_result, HEXTORAW(adler32(p_src)));

    IF DBMS_LOB.ISTEMPORARY(l_compressed) = 1 THEN
      DBMS_LOB.FREETEMPORARY(l_compressed);
    END IF;

    RETURN l_result;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_compressed IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_compressed) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_compressed);
      END IF;
      IF l_result IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_result) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_result);
      END IF;
      RAISE;
  END flate_encode;

-- ---------------------------------------------------------------------------
  FUNCTION flate_decode(p_src             IN BLOB,
                        p_uncompressed_len IN NUMBER) RETURN BLOB IS
    -- Oracle UTL_COMPRESS produces GZIP format (RFC 1952); LZ_UNCOMPRESS expects
    -- the same.  PNG IDAT is zlib (RFC 1950): [CMF][FLG][deflate][Adler32_4].
    -- Strategy 1: try LZ_UNCOMPRESS directly on the RFC 1950 stream.
    -- Strategy 2: strip the 2-byte zlib header and 4-byte Adler32, wrap in a
    --   minimal gzip envelope (fake CRC32 = 0x00000000; Oracle does not validate
    --   it), then call LZ_UNCOMPRESS.
    l_src_len  NUMBER := NVL(DBMS_LOB.GETLENGTH(p_src), 0);
    l_deflate  BLOB;
    l_gzip     BLOB;
    l_defl_len NUMBER;
    l_n        NUMBER := MOD(TRUNC(p_uncompressed_len), 4294967296);

    FUNCTION le4(n IN NUMBER) RETURN RAW IS
    BEGIN
      RETURN HEXTORAW(
        LPAD(TO_CHAR(MOD(n,           256), 'FMXX'), 2, '0') ||
        LPAD(TO_CHAR(MOD(TRUNC(n/256),       256), 'FMXX'), 2, '0') ||
        LPAD(TO_CHAR(MOD(TRUNC(n/65536),     256), 'FMXX'), 2, '0') ||
        LPAD(TO_CHAR(    TRUNC(n/16777216),        'FMXX'), 2, '0'));
    END le4;

  BEGIN
    -- Strategy 1: direct zlib RFC 1950
    BEGIN
      RETURN UTL_COMPRESS.LZ_UNCOMPRESS(p_src);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- Strategy 2: gzip wrapper
    -- Extract raw DEFLATE (strip 2-byte zlib header and 4-byte Adler32).
    l_defl_len := l_src_len - 6;
    DBMS_LOB.CREATETEMPORARY(l_deflate, TRUE, DBMS_LOB.SESSION);
    IF l_defl_len > 0 THEN
      DBMS_LOB.COPY(l_deflate, p_src, l_defl_len, 1, 3);
    END IF;

    -- Build gzip: [10-byte header][deflate][00000000 CRC32][LE size 4]
    DBMS_LOB.CREATETEMPORARY(l_gzip, TRUE, DBMS_LOB.SESSION);
    DECLARE
      l_hdr RAW(10) := HEXTORAW('1F8B0800000000000003');
      l_crc RAW(4)  := HEXTORAW('00000000');
      l_sz  RAW(4)  := le4(l_n);
    BEGIN
      DBMS_LOB.WRITEAPPEND(l_gzip, UTL_RAW.LENGTH(l_hdr), l_hdr);
      IF l_defl_len > 0 THEN
        DBMS_LOB.APPEND(l_gzip, l_deflate);
      END IF;
      DBMS_LOB.WRITEAPPEND(l_gzip, UTL_RAW.LENGTH(l_crc), l_crc);
      DBMS_LOB.WRITEAPPEND(l_gzip, UTL_RAW.LENGTH(l_sz),  l_sz);
    END;

    IF DBMS_LOB.ISTEMPORARY(l_deflate) = 1 THEN
      DBMS_LOB.FREETEMPORARY(l_deflate);
      l_deflate := NULL;
    END IF;

    DECLARE l_result BLOB; BEGIN
      l_result := UTL_COMPRESS.LZ_UNCOMPRESS(l_gzip);
      DBMS_LOB.FREETEMPORARY(l_gzip);
      RETURN l_result;
    END;

  EXCEPTION
    WHEN OTHERS THEN
      IF l_deflate IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_deflate) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_deflate);
      END IF;
      IF l_gzip IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_gzip) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_gzip);
      END IF;
      RAISE;
  END flate_decode;

-- ---------------------------------------------------------------------------
  FUNCTION adler32(p_src IN BLOB) RETURN VARCHAR2 IS
    s1        PLS_INTEGER := 1;
    s2        PLS_INTEGER := 0;
    n         PLS_INTEGER;
    c65521    CONSTANT PLS_INTEGER := 65521;
    l_len     NUMBER := NVL(DBMS_LOB.GETLENGTH(p_src), 0);
    l_step    NUMBER;
    l_hex     VARCHAR2(32766);
    l_hex_len PLS_INTEGER;
  BEGIN
    IF l_len = 0 THEN RETURN '00000001'; END IF;

    l_step := TRUNC(16383 / DBMS_LOB.GETCHUNKSIZE(p_src)) * DBMS_LOB.GETCHUNKSIZE(p_src);
    IF l_step = 0 THEN l_step := 16383; END IF;

    FOR j IN 0 .. TRUNC((l_len - 1) / l_step) LOOP
      l_hex     := RAWTOHEX(DBMS_LOB.SUBSTR(p_src, l_step, j * l_step + 1));
      l_hex_len := NVL(LENGTH(l_hex), 0) / 2;
      FOR i IN 1 .. l_hex_len LOOP
        n  := TO_NUMBER(SUBSTR(l_hex, i * 2 - 1, 2), 'XX');
        s1 := s1 + n;
        IF s1 >= c65521 THEN s1 := s1 - c65521; END IF;
        s2 := s2 + s1;
        IF s2 >= c65521 THEN s2 := s2 - c65521; END IF;
      END LOOP;
    END LOOP;

    RETURN TO_CHAR(s2, 'FM0XXX') || TO_CHAR(s1, 'FM0XXX');
  END adler32;

-- ---------------------------------------------------------------------------
  FUNCTION sha256_hex(p_blob IN BLOB) RETURN VARCHAR2 IS
  BEGIN
    RETURN LOWER(RAWTOHEX(DBMS_CRYPTO.HASH(p_blob, DBMS_CRYPTO.HASH_SH256)));
  END sha256_hex;

-- ---------------------------------------------------------------------------
  FUNCTION fmt(p_value IN NUMBER, p_decimals IN PLS_INTEGER DEFAULT 3)
    RETURN VARCHAR2 IS
    l_s VARCHAR2(50);
  BEGIN
    l_s := TO_CHAR(ROUND(p_value, p_decimals), 'TM9', 'NLS_NUMERIC_CHARACTERS=.,');
    -- TM9 omits the leading zero for values in ]-1,1[: '.502' → '0.502'
    IF l_s LIKE  '.%' THEN l_s := '0'  || l_s;            END IF;
    IF l_s LIKE '-.%' THEN l_s := '-0.' || SUBSTR(l_s, 3); END IF;
    RETURN l_s;
  END fmt;

-- ---------------------------------------------------------------------------
  FUNCTION escape_pdf_str(p_str IN VARCHAR2) RETURN VARCHAR2 IS
    l_s VARCHAR2(32767);
  BEGIN
    IF p_str IS NULL THEN RETURN NULL; END IF;
    -- Order matters: escape backslash first, then parentheses.
    l_s := REPLACE(p_str,  '\',  '\\');
    l_s := REPLACE(l_s,    '(',  '\(');
    l_s := REPLACE(l_s,    ')',  '\)');
    RETURN l_s;
  END escape_pdf_str;

-- ---------------------------------------------------------------------------
  FUNCTION rgb_to_pdf(p_rgb IN rad_pdf_types.t_rgb) RETURN VARCHAR2 IS
    l_r NUMBER;
    l_g NUMBER;
    l_b NUMBER;
  BEGIN
    IF p_rgb IS NULL OR LENGTH(p_rgb) != 6 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_codec.rgb_to_pdf: invalid RGB "' || NVL(p_rgb, '<null>') || '"', TRUE);
    END IF;
    l_r := TO_NUMBER(SUBSTR(p_rgb, 1, 2), 'XX') / 255;
    l_g := TO_NUMBER(SUBSTR(p_rgb, 3, 2), 'XX') / 255;
    l_b := TO_NUMBER(SUBSTR(p_rgb, 5, 2), 'XX') / 255;
    RETURN fmt(l_r, 3) || ' ' || fmt(l_g, 3) || ' ' || fmt(l_b, 3);
  END rgb_to_pdf;

END rad_pdf_codec;
/
