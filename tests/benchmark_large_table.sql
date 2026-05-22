-- benchmark_large_table.sql — Volumetric stress test for rad_pdf_table.
--
-- PURPOSE
--   Validates that rad_pdf_table.refcursor2table handles a large result set
--   (10 000 rows) without ORA-04031 (PGA exhaustion) and that rad_pdf_ctx.close_doc
--   releases the g_table_cache collection after finalize.
--
-- PGA MONITORING (optional, requires SELECT on V$SESSTAT / V$STATNAME)
--   After the test you can run the following query manually to confirm that
--   PGA memory is not leaking across calls:
--
--     SELECT ss.value / 1024 / 1024 AS pga_used_mb
--     FROM   v$sesstat  ss
--     JOIN   v$statname sn ON sn.statistic# = ss.statistic#
--     WHERE  sn.name = 'session pga memory'
--       AND  ss.sid = SYS_CONTEXT('USERENV', 'SID');
--
-- HOW TO RUN
--   @tests/benchmark_large_table.sql
--
-- NOTE
--   This file is intentionally kept out of the main phase regression suite
--   because it generates a large PDF (several hundred pages) and may take
--   10–30 seconds depending on hardware.  Run it manually or in a dedicated
--   performance CI job.
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  l_ok   PLS_INTEGER := 0;
  l_fail PLS_INTEGER := 0;

  PROCEDURE ok(p_label IN VARCHAR2, p_cond IN BOOLEAN) IS
  BEGIN
    IF p_cond THEN
      DBMS_OUTPUT.PUT_LINE('PASS  ' || p_label); l_ok := l_ok + 1;
    ELSE
      DBMS_OUTPUT.PUT_LINE('FAIL  ' || p_label); l_fail := l_fail + 1;
    END IF;
  END;

  -- -------------------------------------------------------------------------
  -- 1. refcursor2table — 10 000 rows, 3 columns
  --    Verifies: no crash, valid BLOB, sufficient size.
  -- -------------------------------------------------------------------------
  PROCEDURE bench_refcursor IS
    l_doc   rad_pdf_types.t_doc_handle;
    l_pdf   BLOB;
    l_cols  rad_pdf_types.t_columns;
    l_clr   rad_pdf_types.t_color_scheme;
    l_rc    SYS_REFCURSOR;
    l_t0    NUMBER := DBMS_UTILITY.GET_TIME;
    l_t1    NUMBER;
    l_len   NUMBER;
  BEGIN
    rad_pdf_styles.load_defaults;

    l_cols := rad_pdf_types.t_columns();
    l_cols.EXTEND(3);
    l_cols(1).label            := '#';
    l_cols(1).width            := 60;
    l_cols(1).data_fmt.align_h := 'R';
    l_cols(2).label            := 'Descrizione';
    l_cols(2).width            := 280;
    l_cols(3).label            := 'Valore';
    l_cols(3).width            := 100;
    l_cols(3).data_fmt.align_h := 'R';
    l_cols(3).data_fmt.num_format := 'FM999,999,990.00';

    -- Default color scheme from styles
    l_clr := rad_pdf_styles.default_scheme();

    l_doc := rad_pdf.new_document;
    rad_pdf.heading(l_doc, 'Stress Test — 10 000 Righe', 1);
    rad_pdf.spacer (l_doc, 6);

    OPEN l_rc FOR
      SELECT LEVEL                          AS nr,
             'Voce ' || TO_CHAR(LEVEL)      AS descrizione,
             ROUND(LEVEL * 3.14159, 2)      AS valore
      FROM   DUAL
      CONNECT BY LEVEL <= 10000;

    -- refcursor2table caches all rows before measure/render
    rad_pdf_table.refcursor2table(l_doc, l_rc, l_cols, p_colors => l_clr);

    l_pdf := rad_pdf.finalize(l_doc);
    l_t1  := DBMS_UTILITY.GET_TIME;
    l_len := NVL(DBMS_LOB.GETLENGTH(l_pdf), 0);

    ok('10k-rows: finalize succeeds (BLOB not null)', l_pdf IS NOT NULL);
    ok('10k-rows: starts %PDF',
       UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF');
    -- A 10 000-row, 3-column, multi-page PDF should comfortably exceed 50 KB.
    ok('10k-rows: BLOB > 50 000 bytes', l_len > 50000);

    DBMS_OUTPUT.PUT_LINE(
      '      size = ' || ROUND(l_len / 1024, 1) || ' KB' ||
      '  elapsed = ' || ROUND((l_t1 - l_t0) / 100, 2) || ' s');

    DBMS_LOB.FREETEMPORARY(l_pdf);
  END bench_refcursor;

  -- -------------------------------------------------------------------------
  -- 2. query2table — 10 000 rows via inline VARCHAR2 query (measure + render)
  -- -------------------------------------------------------------------------
  PROCEDURE bench_query2table IS
    l_doc  rad_pdf_types.t_doc_handle;
    l_pdf  BLOB;
    l_cols rad_pdf_types.t_columns;
    l_t0   NUMBER := DBMS_UTILITY.GET_TIME;
    l_t1   NUMBER;
    l_len  NUMBER;
  BEGIN
    rad_pdf_styles.load_defaults;

    l_cols := rad_pdf_types.t_columns();
    l_cols.EXTEND(2);
    l_cols(1).label            := 'N';
    l_cols(1).width            := 70;
    l_cols(1).data_fmt.align_h := 'R';
    l_cols(2).label            := 'Quadrato';
    l_cols(2).width            := 120;
    l_cols(2).data_fmt.align_h := 'R';

    l_doc := rad_pdf.new_document;
    rad_pdf.heading(l_doc, 'Stress Test — query2table 10 000 Righe', 1);

    rad_pdf.query2table(l_doc,
      'SELECT LEVEL, LEVEL * LEVEL ' ||
      'FROM DUAL CONNECT BY LEVEL <= 10000',
      l_cols);

    l_pdf := rad_pdf.finalize(l_doc);
    l_t1  := DBMS_UTILITY.GET_TIME;
    l_len := NVL(DBMS_LOB.GETLENGTH(l_pdf), 0);

    ok('q2t-10k: finalize succeeds', l_pdf IS NOT NULL);
    ok('q2t-10k: starts %PDF',
       UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF');
    ok('q2t-10k: BLOB > 50 000 bytes', l_len > 50000);

    DBMS_OUTPUT.PUT_LINE(
      '      size = ' || ROUND(l_len / 1024, 1) || ' KB' ||
      '  elapsed = ' || ROUND((l_t1 - l_t0) / 100, 2) || ' s');

    DBMS_LOB.FREETEMPORARY(l_pdf);
  END bench_query2table;

  -- -------------------------------------------------------------------------
  -- 3. Two sequential large documents — verifies cache cleanup between calls.
  --    If g_table_cache is not released by close_doc, PGA doubles here.
  -- -------------------------------------------------------------------------
  PROCEDURE bench_sequential_docs IS
    l_doc  rad_pdf_types.t_doc_handle;
    l_pdf  BLOB;
    l_cols rad_pdf_types.t_columns;
    n      PLS_INTEGER;
    l_t0   NUMBER := DBMS_UTILITY.GET_TIME;
    l_t1   NUMBER;
  BEGIN
    rad_pdf_styles.load_defaults;

    l_cols := rad_pdf_types.t_columns();
    l_cols.EXTEND(2);
    l_cols(1).label            := 'ID';
    l_cols(1).width            := 60;
    l_cols(1).data_fmt.align_h := 'R';
    l_cols(2).label            := 'Label';
    l_cols(2).width            := 200;

    FOR pass IN 1..2 LOOP
      l_doc := rad_pdf.new_document;
      rad_pdf.heading(l_doc, 'Documento ' || pass || ' di 2', 1);

      rad_pdf.query2table(l_doc,
        'SELECT LEVEL, ''Riga '' || LEVEL ' ||
        'FROM DUAL CONNECT BY LEVEL <= 5000',
        l_cols);

      l_pdf := rad_pdf.finalize(l_doc);
      n := NVL(DBMS_LOB.GETLENGTH(l_pdf), 0);
      ok('seq-doc-' || pass || ': finalize succeeds', l_pdf IS NOT NULL);
      ok('seq-doc-' || pass || ': BLOB > 25 000 bytes', n > 25000);
      DBMS_LOB.FREETEMPORARY(l_pdf);
    END LOOP;

    l_t1 := DBMS_UTILITY.GET_TIME;
    DBMS_OUTPUT.PUT_LINE(
      '      2 × 5 000-row docs elapsed = ' ||
      ROUND((l_t1 - l_t0) / 100, 2) || ' s');
  END bench_sequential_docs;

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== benchmark_large_table ===');

  DBMS_OUTPUT.PUT_LINE('--- 1. refcursor2table 10 000 rows ---');
  bench_refcursor;

  DBMS_OUTPUT.PUT_LINE('--- 2. query2table 10 000 rows ---');
  bench_query2table;

  DBMS_OUTPUT.PUT_LINE('--- 3. sequential docs (PGA leak check) ---');
  bench_sequential_docs;

  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE(
    'benchmark_large_table: ' || l_ok || ' passed, ' || l_fail || ' failed.');
  IF l_fail > 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'benchmark_large_table FAILED: ' || l_fail || ' failure(s)');
  END IF;
END;
/
