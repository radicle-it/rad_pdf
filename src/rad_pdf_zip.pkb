CREATE OR REPLACE PACKAGE BODY rad_pdf_zip AS

  c_sig_eocd    CONSTANT RAW(4) := HEXTORAW('504B0506');
  c_sig_central CONSTANT RAW(4) := HEXTORAW('504B0102');
  c_sig_local   CONSTANT RAW(4) := HEXTORAW('504B0304');
  c_gzip_head   CONSTANT RAW(10) := HEXTORAW('1F8B08000000000000FF');   -- deflate, no flags, no mtime, OS unknown
  c_max_expand  CONSTANT PLS_INTEGER := 1032;                             -- deflate's maximum expansion ratio

  PROCEDURE refuse(p_msg IN VARCHAR2) IS
  BEGIN
    raise_application_error(c_err_docx, '[PDF_DOCX] ' || p_msg);
  END refuse;

  PROCEDURE over(p_msg IN VARCHAR2) IS
  BEGIN
    raise_application_error(c_err_budget, '[PDF_BUDGET] ' || p_msg);
  END over;

  -- an unsigned little-endian integer of p_n bytes at the 1-based offset p_off
  FUNCTION u(p_zip IN BLOB, p_off IN NUMBER, p_n IN PLS_INTEGER) RETURN NUMBER IS
    l_r RAW(4) := dbms_lob.substr(p_zip, p_n, p_off);
  BEGIN
    IF l_r IS NULL OR utl_raw.length(l_r) <> p_n THEN refuse('truncated archive at byte ' || p_off); END IF;
    RETURN to_number(rawtohex(utl_raw.reverse(l_r)), 'XXXXXXXX');
  END u;

  -- every byte of p_raw printable ASCII (0x20 .. 0x7E), read as bytes: a regular expression range such as [ -~] follows
  -- NLS_SORT, and under a linguistic sort (an Italian APEX session) it raises ORA-12728
  FUNCTION printable_ascii(p_raw IN RAW) RETURN BOOLEAN IS
    l_b PLS_INTEGER;
  BEGIN
    FOR k IN 1 .. nvl(utl_raw.length(p_raw), 0) LOOP
      l_b := to_number(rawtohex(utl_raw.substr(p_raw, k, 1)), 'XX');
      IF l_b < 32 OR l_b > 126 THEN RETURN FALSE; END IF;
    END LOOP;
    RETURN TRUE;
  END printable_ascii;

  -- a safe OPC part name: relative, '/' separated, no '\', no '.' or '..' or empty segment, no control character
  PROCEDURE check_name(p_name IN VARCHAR2) IS
    l_seg VARCHAR2(400);
    l_dir BOOLEAN := substr(p_name, -1) = '/';
    l_body VARCHAR2(401) := CASE WHEN l_dir THEN substr(p_name, 1, length(p_name) - 1) ELSE p_name END;
    l_a    PLS_INTEGER := 1;
    l_b    PLS_INTEGER;
  BEGIN
    IF p_name IS NULL OR instr(p_name, '\') > 0 OR substr(p_name, 1, 1) = '/' OR regexp_like(p_name, '[[:cntrl:]]')
       OR regexp_like(p_name, '^[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz]:') THEN
      refuse('entry name not allowed: "' || substr(p_name, 1, 100) || '"');
    END IF;
    l_body := l_body || '/';
    LOOP                                                 -- the segments between the slashes
      l_b := instr(l_body, '/', l_a);
      EXIT WHEN l_b = 0;
      l_seg := substr(l_body, l_a, l_b - l_a);
      l_a := l_b + 1;
      IF l_seg IS NULL OR l_seg IN ('.', '..') THEN
        refuse('entry name with an empty, "." or ".." segment: "' || substr(p_name, 1, 100) || '"');
      END IF;
    END LOOP;
  END check_name;

  FUNCTION open_zip(p_zip IN BLOB) RETURN t_zip IS
    l_len   NUMBER := nvl(dbms_lob.getlength(p_zip), 0);
    l_eocd  NUMBER := 0;
    l_pos   NUMBER;
    l_nth   PLS_INTEGER := 1;
    l_from  NUMBER;
    l_count PLS_INTEGER;
    l_cd    NUMBER;
    l_cdlen NUMBER;
    l_p     NUMBER;
    l_flags PLS_INTEGER;
    l_nlen  PLS_INTEGER;
    l_lh    NUMBER;
    l_raw   RAW(2000);
    l_e     t_entry;
    l_z     t_zip;
    l_sum   NUMBER := 0;
    TYPE t_seen IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(400);
    l_seen  t_seen;
    TYPE t_span IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    l_start t_span;
    l_end   t_span;
    l_k     PLS_INTEGER;
    l_prev  NUMBER := 0;
  BEGIN
    IF l_len < 22 THEN refuse('not a ZIP archive (' || l_len || ' bytes)'); END IF;
    -- the end of central directory record: the LAST signature whose comment reaches exactly the end of the file
    l_from := greatest(1, l_len - 22 - 65535 + 1);
    LOOP
      l_pos := dbms_lob.instr(p_zip, c_sig_eocd, l_from, l_nth);
      EXIT WHEN nvl(l_pos, 0) = 0;
      IF l_pos + 21 <= l_len AND l_pos + 22 + u(p_zip, l_pos + 20, 2) = l_len + 1 THEN l_eocd := l_pos; END IF;
      l_nth := l_nth + 1;
    END LOOP;
    IF l_eocd = 0 THEN refuse('not a ZIP archive: no end of central directory'); END IF;
    IF u(p_zip, l_eocd + 4, 2) <> 0 OR u(p_zip, l_eocd + 6, 2) <> 0 THEN refuse('multi-disk archive'); END IF;
    l_count := u(p_zip, l_eocd + 10, 2);
    l_cdlen := u(p_zip, l_eocd + 12, 4);
    l_cd    := u(p_zip, l_eocd + 16, 4) + 1;
    IF l_count = 65535 OR l_cd = 4294967296 OR l_cdlen = 4294967295 THEN refuse('ZIP64 archive'); END IF;
    IF u(p_zip, l_eocd + 8, 2) <> l_count THEN refuse('multi-disk archive'); END IF;
    IF l_count > c_max_parts THEN over('the archive has ' || l_count || ' entries (at most ' || c_max_parts || ')'); END IF;
    IF l_cd + l_cdlen > l_eocd THEN refuse('central directory outside the archive'); END IF;
    l_z.entries := t_entries();
    l_p := l_cd;
    FOR i IN 1 .. l_count LOOP
      IF l_p + 46 > l_eocd OR dbms_lob.substr(p_zip, 4, l_p) <> c_sig_central THEN
        refuse('central directory record ' || i || ' damaged');
      END IF;
      l_flags := u(p_zip, l_p + 8, 2);
      IF bitand(l_flags, 1) <> 0 OR bitand(l_flags, 64) <> 0 THEN refuse('encrypted entry'); END IF;
      l_e.method := u(p_zip, l_p + 10, 2);
      l_e.crc32  := dbms_lob.substr(p_zip, 4, l_p + 16);
      l_e.csize  := u(p_zip, l_p + 20, 4);
      l_e.usize  := u(p_zip, l_p + 24, 4);
      l_nlen     := u(p_zip, l_p + 28, 2);
      l_lh       := u(p_zip, l_p + 42, 4) + 1;
      IF l_e.csize = 4294967295 OR l_e.usize = 4294967295 OR l_lh = 4294967296 THEN refuse('ZIP64 entry'); END IF;
      IF u(p_zip, l_p + 34, 2) <> 0 THEN refuse('multi-disk archive'); END IF;
      IF l_nlen = 0 OR l_nlen > 400 THEN refuse('entry ' || i || ': name length ' || l_nlen); END IF;
      l_raw := dbms_lob.substr(p_zip, l_nlen, l_p + 46);
      IF bitand(l_flags, 2048) = 0 AND NOT printable_ascii(l_raw) THEN
        refuse('entry ' || i || ': a non-ASCII name without the UTF-8 flag');
      END IF;
      l_e.name := utl_i18n.raw_to_char(l_raw, 'AL32UTF8');
      check_name(l_e.name);
      IF l_seen.EXISTS(upper(l_e.name)) THEN
        refuse('duplicate entry (names compared ignoring case): "' || l_e.name || '"');
      END IF;
      l_seen(upper(l_e.name)) := i;
      IF l_e.method NOT IN (0, 8) THEN refuse('entry "' || l_e.name || '": compression method ' || l_e.method); END IF;
      IF l_e.method = 0 AND l_e.csize <> l_e.usize THEN refuse('stored entry "' || l_e.name || '" with two sizes'); END IF;
      -- the local header: same name, data right after it
      IF l_lh + 30 > l_cd OR dbms_lob.substr(p_zip, 4, l_lh) <> c_sig_local THEN
        refuse('entry "' || l_e.name || '": local header missing');
      END IF;
      IF u(p_zip, l_lh + 26, 2) <> l_nlen OR dbms_lob.substr(p_zip, l_nlen, l_lh + 30) <> l_raw THEN
        refuse('entry "' || l_e.name || '": local and central names differ');
      END IF;
      -- the local metadata agrees with the central record (APPNOTE 4.4): method, no encryption, and, unless the
      -- sizes follow in a data descriptor (bit 3), the same CRC-32 and sizes
      IF u(p_zip, l_lh + 8, 2) <> l_e.method THEN refuse('entry "' || l_e.name || '": local and central methods differ'); END IF;
      IF bitand(u(p_zip, l_lh + 6, 2), 65) <> 0 THEN refuse('entry "' || l_e.name || '": encrypted (local header)'); END IF;
      IF bitand(u(p_zip, l_lh + 6, 2), 8) = 0 AND bitand(l_flags, 8) = 0
         AND (dbms_lob.substr(p_zip, 4, l_lh + 14) <> l_e.crc32 OR u(p_zip, l_lh + 18, 4) <> l_e.csize
              OR u(p_zip, l_lh + 22, 4) <> l_e.usize) THEN
        refuse('entry "' || l_e.name || '": local and central CRC or sizes differ');
      END IF;
      l_e.data_off := l_lh + 30 + l_nlen + u(p_zip, l_lh + 28, 2);
      IF l_e.data_off + l_e.csize > l_cd THEN refuse('entry "' || l_e.name || '" runs into the central directory'); END IF;
      IF l_e.usize > c_max_ratio * greatest(l_e.csize, 1) THEN
        over('entry "' || l_e.name || '": compression ratio above ' || c_max_ratio);
      END IF;
      -- an empty entry is checked here, whether it is read or not: no CRC, and a deflate stream that yields nothing
      IF l_e.usize = 0 THEN
        IF l_e.crc32 <> hextoraw('00000000') OR (l_e.method = 0 AND l_e.csize <> 0) THEN
          refuse('empty entry "' || l_e.name || '" with a CRC or bytes');
        ELSIF l_e.method = 8 THEN
          DECLARE
            l_b BLOB;
          BEGIN
            l_b := rad_pdf_codec.inflate_raw(p_zip, l_e.data_off, l_e.csize, 0);
            dbms_lob.freetemporary(l_b);
          EXCEPTION
            WHEN OTHERS THEN refuse('empty entry "' || l_e.name || '": its deflate stream is not empty or not valid');
          END;
        END IF;
      END IF;
      l_sum := l_sum + l_e.usize;
      IF l_sum > c_max_bytes THEN over('the archive declares more than ' || c_max_bytes || ' decompressed bytes'); END IF;
      l_start(l_lh) := i;
      l_end(i) := l_e.data_off + l_e.csize;
      l_z.entries.EXTEND;
      l_z.entries(i) := l_e;
      l_p := l_p + 46 + l_nlen + u(p_zip, l_p + 30, 2) + u(p_zip, l_p + 32, 2);
    END LOOP;
    IF l_p <> l_cd + l_cdlen THEN refuse('central directory size does not match its records'); END IF;
    -- no two entries share bytes (the overlapping-entries bomb)
    l_k := l_start.FIRST;
    WHILE l_k IS NOT NULL LOOP
      IF l_k < l_prev THEN refuse('entries overlap'); END IF;
      l_prev := l_end(l_start(l_k));
      l_k := l_start.NEXT(l_k);
    END LOOP;
    IF l_start.COUNT <> l_count THEN refuse('two entries share a local header'); END IF;
    RETURN l_z;
  END open_zip;

  FUNCTION find(p_z IN t_zip, p_name IN VARCHAR2) RETURN PLS_INTEGER IS
  BEGIN
    FOR i IN 1 .. p_z.entries.COUNT LOOP
      IF p_z.entries(i).name = p_name THEN RETURN i; END IF;
    END LOOP;
    RETURN 0;
  END find;

  -- the CRC-32 of some bytes, little-endian like the ZIP records: the trailer of UTL_COMPRESS's gzip output
  FUNCTION crc32(p_b IN BLOB) RETURN RAW IS
    l_g BLOB;
    l_r RAW(4);
  BEGIN
    IF nvl(dbms_lob.getlength(p_b), 0) = 0 THEN RETURN hextoraw('00000000'); END IF;
    l_g := utl_compress.lz_compress(p_b);
    l_r := dbms_lob.substr(l_g, 4, dbms_lob.getlength(l_g) - 7);
    dbms_lob.freetemporary(l_g);
    RETURN l_r;
  END crc32;

  -- One entry. Two paths, both bounded by the budget whatever the declared size says:
  --   native   UTL_COMPRESS.LZ_UNCOMPRESS on a gzip envelope carrying the central CRC-32 and size (both verified by
  --            Oracle), only when even a lying entry cannot exceed the budget: deflate expands at most 1032:1 (RFC 1951
  --            limit, zlib technical notes), so csize * c_max_expand bytes at most;
  --   bounded  rad_pdf_codec.inflate_raw otherwise: the bytes are counted DURING decompression and the read stops at
  --            the first byte beyond the declared size.
  -- Stored entries are copied. Every entry ends with its size and its CRC-32 checked (APPNOTE 4.4.7), an empty one
  -- included (its deflate stream is decoded: nothing may come out).
  -- (UTL_COMPRESS's piecewise API is not used: each LZ_UNCOMPRESS_OPEN leaves an abstract LOB in the session.)
  FUNCTION extract(p_zip IN BLOB, p_z IN OUT NOCOPY t_zip, p_index IN PLS_INTEGER) RETURN BLOB IS
    l_e      t_entry := p_z.entries(p_index);
    l_gz     BLOB;
    l_out    BLOB;
    l_n      NUMBER;
    l_native BOOLEAN := FALSE;
  BEGIN
    IF p_z.used + l_e.usize > c_max_bytes THEN over('more than ' || c_max_bytes || ' decompressed bytes'); END IF;
    IF l_e.method = 0 THEN
      dbms_lob.createtemporary(l_out, TRUE, dbms_lob.session);
      IF l_e.csize > 0 THEN dbms_lob.copy(l_out, p_zip, l_e.csize, 1, l_e.data_off); END IF;
    ELSIF l_e.usize > 0 AND l_e.csize * c_max_expand + 1024 <= c_max_bytes - p_z.used THEN
      l_native := TRUE;
      dbms_lob.createtemporary(l_gz, TRUE, dbms_lob.session);
      dbms_lob.writeappend(l_gz, 10, c_gzip_head);
      IF l_e.csize > 0 THEN dbms_lob.copy(l_gz, p_zip, l_e.csize, 11, l_e.data_off); END IF;
      dbms_lob.writeappend(l_gz, 4, l_e.crc32);
      dbms_lob.writeappend(l_gz, 4, utl_raw.reverse(hextoraw(lpad(to_char(mod(l_e.usize, 4294967296), 'FMXXXXXXXX'), 8, '0'))));
      BEGIN
        l_out := utl_compress.lz_uncompress(l_gz);
      EXCEPTION
        WHEN OTHERS THEN
          refuse('entry "' || l_e.name || '" cannot be decompressed (' || substr(sqlerrm, 1, 200) || ')');
      END;
      dbms_lob.freetemporary(l_gz);
    ELSE
      -- the bounded path, also for an empty entry: its deflate stream is decoded too (nothing may come out)
      BEGIN
        l_out := rad_pdf_codec.inflate_raw(p_zip, l_e.data_off, l_e.csize, l_e.usize);
      EXCEPTION
        WHEN OTHERS THEN
          IF sqlcode = rad_pdf_codec.c_err_inflate_limit THEN
            refuse('entry "' || l_e.name || '" decompresses beyond its declared size');
          END IF;
          refuse('entry "' || l_e.name || '" cannot be decompressed (' || substr(sqlerrm, 1, 200) || ')');
      END;
    END IF;
    l_n := nvl(dbms_lob.getlength(l_out), 0);
    IF l_n <> l_e.usize THEN refuse('entry "' || l_e.name || '" does not have its declared size'); END IF;
    -- the CRC-32 of every entry (the native path has it verified by Oracle already)
    IF NOT l_native AND crc32(l_out) <> l_e.crc32 THEN refuse('entry "' || l_e.name || '": CRC-32 mismatch'); END IF;
    p_z.used := p_z.used + l_n;
    RETURN l_out;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_gz IS NOT NULL AND dbms_lob.istemporary(l_gz) = 1 THEN dbms_lob.freetemporary(l_gz); END IF;
      IF l_out IS NOT NULL AND dbms_lob.istemporary(l_out) = 1 THEN dbms_lob.freetemporary(l_out); END IF;
      RAISE;
  END extract;

END rad_pdf_zip;
/
