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
    l_defl_len   NUMBER;
  BEGIN
    -- UTL_COMPRESS.LZ_COMPRESS produces GZIP format (RFC 1952):
    --   10-byte header (1F 8B 08 00 mtime4 XFL OS) + deflate + 8-byte
    --   trailer (CRC32 + ISIZE).
    -- PDF /FlateDecode requires a zlib stream (RFC 1950):
    --   2-byte header (78 9C) + deflate + 4-byte Adler32.
    -- Strip the gzip envelope, keep the raw deflate, rebuild the zlib one.
    -- (Adler32 is computed on the original uncompressed data.)
    l_compressed := UTL_COMPRESS.LZ_COMPRESS(p_src);
    l_defl_len   := DBMS_LOB.GETLENGTH(l_compressed) - 18;

    DBMS_LOB.CREATETEMPORARY(l_result, TRUE, DBMS_LOB.SESSION);
    DBMS_LOB.WRITEAPPEND(l_result, 2, HEXTORAW('789C'));
    IF l_defl_len > 0 THEN
      DBMS_LOB.COPY(
        l_result,
        l_compressed,
        l_defl_len,
        3,   -- dest offset (after the 2-byte zlib header)
        11   -- src offset  (skip the 10-byte gzip header)
      );
    END IF;

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
    -- Pure PL/SQL inflate (RFC 1950 zlib wrapper + RFC 1951 deflate).
    --
    -- UTL_COMPRESS cannot be used here: it only speaks gzip (RFC 1952) and
    -- VALIDATES the trailer CRC32, which is computed over the UNCOMPRESSED
    -- data — unavailable before inflating.  zlib streams carry an Adler-32
    -- instead, so no valid gzip envelope can be constructed.  (Verified on
    -- 19c/23ai: LZ_UNCOMPRESS raises ORA-29294 on any forged CRC, and the
    -- piecewise LZ_UNCOMPRESS_EXTRACT path validates it as well.)
    --
    -- Huffman decoding follows the canonical counts/offsets approach of
    -- Mark Adler's puff.c.  Performance note: ~1-2 s per MB of decompressed
    -- data; callers (rad_pdf_images) cache the decoded result by SHA-256,
    -- so the cost is paid once per distinct image and session.
    l_src_len PLS_INTEGER := NVL(DBMS_LOB.GETLENGTH(p_src), 0);

    TYPE t_ints IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    l_in     t_ints;            -- input bytes, 0-based
    l_pos    PLS_INTEGER := 0;  -- next input byte index
    l_bitbuf PLS_INTEGER := 0;
    l_bitcnt PLS_INTEGER := 0;
    l_pow2   t_ints;            -- 2^0 .. 2^24

    l_win    t_ints;            -- 32k LZ77 ring buffer
    l_wpos   PLS_INTEGER := 0;  -- total bytes emitted
    l_hex    VARCHAR2(32760);   -- pending output as hex
    l_out    BLOB;

    l_final  PLS_INTEGER;
    l_type   PLS_INTEGER;
    l_cmf    PLS_INTEGER;
    l_flg    PLS_INTEGER;

    -- canonical Huffman tables: counts per bit length + sorted symbols
    l_lcnt   t_ints;  l_lsym  t_ints;   -- literal/length
    l_dcnt   t_ints;  l_dsym  t_ints;   -- distance

    PROCEDURE err(p_msg IN VARCHAR2) IS
    BEGIN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_rendering,
        'rad_pdf_codec.flate_decode: ' || p_msg, TRUE);
    END err;

    FUNCTION next_byte RETURN PLS_INTEGER IS
      l_b PLS_INTEGER;
    BEGIN
      IF l_pos >= l_src_len THEN
        err('unexpected end of compressed stream');
      END IF;
      l_b := l_in(l_pos);
      l_pos := l_pos + 1;
      RETURN l_b;
    END next_byte;

    FUNCTION getbits(p_n IN PLS_INTEGER) RETURN PLS_INTEGER IS
      l_v PLS_INTEGER;
    BEGIN
      WHILE l_bitcnt < p_n LOOP
        l_bitbuf := l_bitbuf + next_byte * l_pow2(l_bitcnt);
        l_bitcnt := l_bitcnt + 8;
      END LOOP;
      l_v := MOD(l_bitbuf, l_pow2(p_n));
      l_bitbuf := TRUNC(l_bitbuf / l_pow2(p_n));
      l_bitcnt := l_bitcnt - p_n;
      RETURN l_v;
    END getbits;

    PROCEDURE flush_out IS
    BEGIN
      IF l_hex IS NOT NULL THEN
        DBMS_LOB.WRITEAPPEND(l_out, LENGTH(l_hex) / 2, HEXTORAW(l_hex));
        l_hex := NULL;
      END IF;
    END flush_out;

    PROCEDURE emit(p_b IN PLS_INTEGER) IS
    BEGIN
      l_win(MOD(l_wpos, 32768)) := p_b;
      l_wpos := l_wpos + 1;
      l_hex := l_hex || LPAD(TO_CHAR(p_b, 'FMXX'), 2, '0');
      IF LENGTH(l_hex) >= 32700 THEN
        flush_out;
      END IF;
    END emit;

    -- Build canonical counts/symbols from a 0-based code-length array.
    PROCEDURE build(p_len IN t_ints, p_n IN PLS_INTEGER,
                    p_cnt IN OUT NOCOPY t_ints,
                    p_sym IN OUT NOCOPY t_ints) IS
      l_offs t_ints;
      l_o    PLS_INTEGER := 0;
    BEGIN
      FOR i IN 0 .. 15 LOOP
        p_cnt(i) := 0;
      END LOOP;
      FOR i IN 0 .. p_n - 1 LOOP
        p_cnt(p_len(i)) := p_cnt(p_len(i)) + 1;
      END LOOP;
      FOR i IN 1 .. 15 LOOP
        l_offs(i) := l_o;
        l_o := l_o + p_cnt(i);
      END LOOP;
      FOR i IN 0 .. p_n - 1 LOOP
        IF p_len(i) > 0 THEN
          p_sym(l_offs(p_len(i))) := i;
          l_offs(p_len(i)) := l_offs(p_len(i)) + 1;
        END IF;
      END LOOP;
    END build;

    -- Decode one symbol (puff.c walk: code/first/index per bit length).
    FUNCTION decode(p_cnt IN t_ints, p_sym IN t_ints) RETURN PLS_INTEGER IS
      l_code  PLS_INTEGER := 0;
      l_first PLS_INTEGER := 0;
      l_index PLS_INTEGER := 0;
      l_count PLS_INTEGER;
    BEGIN
      FOR len IN 1 .. 15 LOOP
        l_code := l_code + getbits(1);
        l_count := p_cnt(len);
        IF l_code - l_first < l_count THEN
          RETURN p_sym(l_index + l_code - l_first);
        END IF;
        l_index := l_index + l_count;
        l_first := (l_first + l_count) * 2;
        l_code  := l_code * 2;
      END LOOP;
      err('invalid Huffman code');
      RETURN NULL;
    END decode;

    PROCEDURE inflate_block_data IS
      -- length codes 257..285: base + extra bits; distance codes 0..29
      TYPE t_tab IS VARRAY(30) OF PLS_INTEGER;
      c_lbase  CONSTANT t_tab := t_tab(3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,
                                       35,43,51,59,67,83,99,115,131,163,195,227,258);
      c_lext   CONSTANT t_tab := t_tab(0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,
                                       3,3,3,3,4,4,4,4,5,5,5,5,0);
      c_dbase  CONSTANT t_tab := t_tab(1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,
                                       257,385,513,769,1025,1537,2049,3073,4097,
                                       6145,8193,12289,16385,24577);
      c_dext   CONSTANT t_tab := t_tab(0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,
                                       9,9,10,10,11,11,12,12,13,13);
      l_sym  PLS_INTEGER;
      l_len  PLS_INTEGER;
      l_dist PLS_INTEGER;
    BEGIN
      LOOP
        l_sym := decode(l_lcnt, l_lsym);
        IF l_sym < 256 THEN
          emit(l_sym);
        ELSIF l_sym = 256 THEN
          EXIT;
        ELSE
          IF l_sym > 285 THEN
            err('invalid length symbol ' || l_sym);
          END IF;
          l_len := c_lbase(l_sym - 256) + getbits(c_lext(l_sym - 256));
          l_sym := decode(l_dcnt, l_dsym);
          IF l_sym > 29 THEN
            err('invalid distance symbol ' || l_sym);
          END IF;
          l_dist := c_dbase(l_sym + 1) + getbits(c_dext(l_sym + 1));
          IF l_dist > l_wpos THEN
            err('distance back-reference before start of output');
          END IF;
          FOR i IN 1 .. l_len LOOP
            emit(l_win(MOD(l_wpos - l_dist, 32768)));
          END LOOP;
        END IF;
      END LOOP;
    END inflate_block_data;

    PROCEDURE fixed_tables IS
      l_len t_ints;
    BEGIN
      FOR i IN 0 .. 143 LOOP l_len(i) := 8; END LOOP;
      FOR i IN 144 .. 255 LOOP l_len(i) := 9; END LOOP;
      FOR i IN 256 .. 279 LOOP l_len(i) := 7; END LOOP;
      FOR i IN 280 .. 287 LOOP l_len(i) := 8; END LOOP;
      build(l_len, 288, l_lcnt, l_lsym);
      FOR i IN 0 .. 29 LOOP l_len(i) := 5; END LOOP;
      build(l_len, 30, l_dcnt, l_dsym);
    END fixed_tables;

    PROCEDURE dynamic_tables IS
      TYPE t_ord IS VARRAY(19) OF PLS_INTEGER;
      c_order CONSTANT t_ord := t_ord(16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15);
      l_hlit  PLS_INTEGER;
      l_hdist PLS_INTEGER;
      l_hclen PLS_INTEGER;
      l_cl    t_ints;            -- code-length code lengths
      l_ccnt  t_ints;
      l_csym  t_ints;
      l_lens  t_ints;            -- combined lit/len + dist code lengths
      l_n     PLS_INTEGER;
      l_sym   PLS_INTEGER;
      l_rep   PLS_INTEGER;
      l_prev  PLS_INTEGER;
      i       PLS_INTEGER;
      l_dl    t_ints;
    BEGIN
      l_hlit  := getbits(5) + 257;
      l_hdist := getbits(5) + 1;
      l_hclen := getbits(4) + 4;
      FOR j IN 0 .. 18 LOOP l_cl(j) := 0; END LOOP;
      FOR j IN 1 .. l_hclen LOOP
        l_cl(c_order(j)) := getbits(3);
      END LOOP;
      build(l_cl, 19, l_ccnt, l_csym);

      l_n := l_hlit + l_hdist;
      i := 0;
      WHILE i < l_n LOOP
        l_sym := decode(l_ccnt, l_csym);
        IF l_sym < 16 THEN
          l_lens(i) := l_sym;
          l_prev := l_sym;
          i := i + 1;
        ELSIF l_sym = 16 THEN
          IF i = 0 THEN err('repeat with no previous code length'); END IF;
          l_rep := 3 + getbits(2);
          FOR j IN 1 .. l_rep LOOP l_lens(i) := l_prev; i := i + 1; END LOOP;
        ELSIF l_sym = 17 THEN
          l_rep := 3 + getbits(3);
          FOR j IN 1 .. l_rep LOOP l_lens(i) := 0; i := i + 1; END LOOP;
        ELSE
          l_rep := 11 + getbits(7);
          FOR j IN 1 .. l_rep LOOP l_lens(i) := 0; i := i + 1; END LOOP;
        END IF;
      END LOOP;
      IF i > l_n THEN err('code length repeat overflows table'); END IF;

      build(l_lens, l_hlit, l_lcnt, l_lsym);
      FOR j IN 0 .. l_hdist - 1 LOOP
        l_dl(j) := l_lens(l_hlit + j);
      END LOOP;
      build(l_dl, l_hdist, l_dcnt, l_dsym);
    END dynamic_tables;

    PROCEDURE stored_block IS
      l_len  PLS_INTEGER;
      l_nlen PLS_INTEGER;
    BEGIN
      -- discard remaining bits of the current byte
      l_bitbuf := 0;
      l_bitcnt := 0;
      l_len  := next_byte + next_byte * 256;
      l_nlen := next_byte + next_byte * 256;
      IF l_len + l_nlen != 65535 THEN
        err('stored block LEN/NLEN mismatch');
      END IF;
      FOR i IN 1 .. l_len LOOP
        emit(next_byte);
      END LOOP;
    END stored_block;

  BEGIN
    IF l_src_len < 7 THEN
      err('zlib stream too short (' || l_src_len || ' bytes)');
    END IF;

    -- Load the whole input into a byte table (hex parse in 16k chunks).
    DECLARE
      l_chunk VARCHAR2(32760);
      l_cn    PLS_INTEGER;
      l_base  PLS_INTEGER := 0;
    BEGIN
      WHILE l_base < l_src_len LOOP
        l_cn := LEAST(16000, l_src_len - l_base);
        l_chunk := RAWTOHEX(DBMS_LOB.SUBSTR(p_src, l_cn, l_base + 1));
        FOR i IN 0 .. l_cn - 1 LOOP
          l_in(l_base + i) := TO_NUMBER(SUBSTR(l_chunk, 2 * i + 1, 2), 'XX');
        END LOOP;
        l_base := l_base + l_cn;
      END LOOP;
    END;

    FOR i IN 0 .. 24 LOOP
      l_pow2(i) := POWER(2, i);
    END LOOP;

    -- zlib header (RFC 1950): CM must be 8 (deflate); FDICT unsupported.
    l_cmf := next_byte;
    l_flg := next_byte;
    IF MOD(l_cmf, 16) != 8 THEN
      err('not a zlib/deflate stream (CM=' || MOD(l_cmf, 16) || ')');
    END IF;
    IF MOD(TRUNC(l_flg / 32), 2) = 1 THEN
      err('zlib preset dictionary (FDICT) is not supported');
    END IF;

    DBMS_LOB.CREATETEMPORARY(l_out, TRUE, DBMS_LOB.SESSION);

    LOOP
      l_final := getbits(1);
      l_type  := getbits(2);
      CASE l_type
        WHEN 0 THEN stored_block;
        WHEN 1 THEN fixed_tables;   inflate_block_data;
        WHEN 2 THEN dynamic_tables; inflate_block_data;
        ELSE err('invalid deflate block type 3');
      END CASE;
      EXIT WHEN l_final = 1;
    END LOOP;
    flush_out;

    -- Trailing Adler-32 is not validated (4 bytes after the deflate data).
    RETURN l_out;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_out IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_out) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_out);
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

-- ---------------------------------------------------------------------------
  FUNCTION srgb_icc RETURN BLOB IS
    l_hex VARCHAR2(1000) :=
         '000001c86c636d73021000006d6e74725247422058595a2007e2000300140009000e001d'
      || '616373704d53465400000000736177736374726c0000000000000000000000000000f6d6'
      || '000100000000d32d68616e649d91003d4080b03d40742c819ea5228e0000000000000000'
      || '00000000000000000000000000000000000000000000000964657363000000f00000005f'
      || '637072740000010c0000000c7774707400000118000000147258595a0000012c00000014'
      || '6758595a00000140000000146258595a0000015400000014725452430000016800000060'
      || '675452430000016800000060625452430000016800000060646573630000000000000005'
      || '7552474200000000000000000000000074657874000000004343300058595a2000000000'
      || '0000f35400010000000116c958595a200000000000006fa0000038f20000038f58595a20'
      || '00000000000062960000b789000018da58595a2000000000000024a000000f850000b6c4'
      || '63757276000000000000002a0000007c00f8019c0275038304c9064e08120a180c620ef4'
      || '11cf14f6186a1c2e204324ac296a2e7e33eb39b33fd646574d3654765c17641d6c867556'
      || '7e8d882c92369caba78cb2dbbe99cac7d765e477f1f9ffff';
    l_b BLOB;
  BEGIN
    DBMS_LOB.CREATETEMPORARY(l_b, TRUE, DBMS_LOB.SESSION);
    DBMS_LOB.WRITEAPPEND(l_b, LENGTH(l_hex) / 2, HEXTORAW(l_hex));
    RETURN l_b;
  END srgb_icc;

-- ---------------------------------------------------------------------------
  FUNCTION xml_escape(p_str IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN REPLACE(REPLACE(REPLACE(p_str,
             '&', '&' || 'amp;'),
             '<', '&' || 'lt;'),
             '>', '&' || 'gt;');
  END xml_escape;

END rad_pdf_codec;
/
