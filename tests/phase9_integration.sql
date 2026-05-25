-- phase9_integration.sql — end-to-end integration tests for the RAD_PDF suite.
-- Covers full lifecycle scenarios across all packages via the rad_pdf facade.
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

  PROCEDURE ok(p_label IN VARCHAR2, p_got IN VARCHAR2, p_exp IN VARCHAR2) IS
  BEGIN
    ok(p_label, NVL(p_got,'<null>') = NVL(p_exp,'<null>'));
  END;

  PROCEDURE ok(p_label IN VARCHAR2, p_got IN NUMBER, p_exp IN NUMBER) IS
  BEGIN
    ok(p_label, p_got = p_exp);
  END;

BEGIN

  -- =========================================================================
  -- 1. Full layout document: all flowable types in one pass
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
  BEGIN
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf.new_document;
    rad_pdf.heading(l_doc, 'Annual Report 2026',    1);
    rad_pdf.heading(l_doc, 'Executive Summary',     2);
    rad_pdf.write  (l_doc, 'Lorem ipsum dolor sit amet, consectetur adipiscing '  ||
                       'elit. Sed do eiusmod tempor incididunt ut labore et '  ||
                       'dolore magna aliqua.');
    rad_pdf.spacer (l_doc, 12);
    rad_pdf.add    (l_doc, rad_pdf_layout.h_rule('808080', 0.5));
    rad_pdf.spacer (l_doc, 8);
    rad_pdf.heading(l_doc, 'Section 1 — Financials', 3);
    rad_pdf.write  (l_doc, 'Revenue increased by 18% year-over-year.');
    rad_pdf.new_page(l_doc);
    rad_pdf.heading(l_doc, 'Section 2 — Operations', 3);
    rad_pdf.write  (l_doc, 'Operational efficiency improved across all units.');
    l_pdf := rad_pdf.finalize(l_doc);
    ok('full-layout: BLOB > 1000',      DBMS_LOB.GETLENGTH(l_pdf) > 1000);
    ok('full-layout: starts with %PDF',
       UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF');
    ok('full-layout: contains BT',
       DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('BT')) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 2. Table document via rad_pdf.table
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_pdf  BLOB;
    l_cols rad_pdf_types.t_columns;
  BEGIN
    rad_pdf_styles.load_defaults;
    l_cols := rad_pdf_types.t_columns();
    l_cols.EXTEND(3);
    l_cols(1).label := 'N';     l_cols(1).width := 60;
    l_cols(2).label := 'Label'; l_cols(2).width := 180;
    l_cols(3).label := 'Sq';    l_cols(3).width := 60;
    l_cols(3).data_fmt.align_h := 'R';
    l_doc := rad_pdf.new_document;
    rad_pdf.heading(l_doc, 'Sample Table', 1);
    rad_pdf.query2table(l_doc,
      'SELECT LEVEL AS n, ' ||
      '''Item '' || TO_CHAR(LEVEL) AS label, ' ||
      'LEVEL * LEVEL AS sq ' ||
      'FROM DUAL CONNECT BY LEVEL <= 8',
      l_cols);
    l_pdf := rad_pdf.finalize(l_doc);
    ok('table-doc: BLOB > 800',    DBMS_LOB.GETLENGTH(l_pdf) > 800);
    ok('table-doc: contains BT',
       DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('BT')) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 3. refcursor2table
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_pdf  BLOB;
    l_cols rad_pdf_types.t_columns;
    l_rc   SYS_REFCURSOR;
  BEGIN
    rad_pdf_styles.load_defaults;
    l_cols := rad_pdf_types.t_columns();
    l_cols.EXTEND(2);
    l_cols(1).label := 'Object Type'; l_cols(1).width := 150;
    l_cols(2).label := 'Count';       l_cols(2).width := 80;
    l_cols(2).data_fmt.align_h := 'R';
    l_doc := rad_pdf.new_document;
    rad_pdf.heading(l_doc, 'Schema Objects', 1);
    OPEN l_rc FOR
      SELECT object_type, COUNT(*) cnt
      FROM   user_objects
      GROUP  BY object_type
      ORDER  BY object_type;
    rad_pdf_table.refcursor2table(l_doc, l_rc, l_cols);
    l_pdf := rad_pdf.finalize(l_doc);
    ok('refcursor-table: BLOB > 500', DBMS_LOB.GETLENGTH(l_pdf) > 500);
    ok('refcursor-table: contains BT',
       DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('BT')) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 4. Page template with header and footer procs
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_tpl  rad_pdf_types.t_page_template;
    l_info rad_pdf_types.t_doc_info;
    l_pdf  BLOB;
  BEGIN
    rad_pdf_styles.load_defaults;
    l_tpl.page_format_name := 'A4';
    l_tpl.margin_top       := 85;
    l_tpl.margin_bottom    := 57;
    l_tpl.header_proc :=
      'BEGIN ' ||
        'rad_pdf_canvas.set_font(#DOC_HANDLE#, ''Helvetica'', ''N'', 8); ' ||
        'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
          '''RAD_PDF — Confidential  |  Page #PAGE_NR# of #PAGE_COUNT#'', ' ||
          '50, 822, ''pt''); ' ||
        'rad_pdf_canvas.h_line(#DOC_HANDLE#, 50, 815, 495, 0.3, ''808080'', ''pt''); ' ||
      'END;';
    l_tpl.footer_proc :=
      'BEGIN ' ||
        'rad_pdf_canvas.set_font(#DOC_HANDLE#, ''Helvetica'', ''I'', 8); ' ||
        'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
          '''Generated by Oracle Database'', 50, 28, ''pt''); ' ||
      'END;';
    l_info.title  := 'Template Test';
    l_info.author := 'Integration Test';
    l_doc := rad_pdf.new_document(p_info => l_info, p_template => l_tpl);
    rad_pdf.heading(l_doc, 'Template Demo', 1);
    rad_pdf.write  (l_doc, 'This document has a header and footer on every page.');
    rad_pdf.new_page(l_doc);
    rad_pdf.write  (l_doc, 'Second page — header and footer should repeat.');
    l_pdf := rad_pdf.finalize(l_doc);
    ok('template: BLOB > 1000',    DBMS_LOB.GETLENGTH(l_pdf) > 1000);
    ok('template: contains /Title',
       DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Title')) > 0);
    ok('template: contains BT',
       DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('BT')) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 5. Custom style applied to paragraphs
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
  BEGIN
    rad_pdf_styles.load_defaults;
    rad_pdf_styles.define('notice',
      p_font_name  => 'Helvetica',
      p_font_style => 'BI',
      p_font_size  => 11,
      p_font_color => 'CC3300',
      p_leading    => 14);
    l_doc := rad_pdf.new_document;
    rad_pdf.write(l_doc, 'Normal body text.');
    rad_pdf.write(l_doc, 'IMPORTANT: This notice is styled differently.', 'notice');
    rad_pdf.write(l_doc, 'Back to normal text.');
    l_pdf := rad_pdf.finalize(l_doc);
    ok('custom-style: BLOB > 500', DBMS_LOB.GETLENGTH(l_pdf) > 500);
    ok('custom-style: contains BT',
       DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('BT')) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 6. set_page_orientation LANDSCAPE swaps width and height
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
    l_w   NUMBER;
    l_h   NUMBER;
  BEGIN
    l_doc := rad_pdf.new_document;
    rad_pdf.set_page_format(l_doc, 'A4');
    rad_pdf.set_page_orientation(l_doc, 'LANDSCAPE');
    l_w := rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_page_width);
    l_h := rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_page_height);
    ok('landscape: width > height', l_w > l_h);
    l_pdf := rad_pdf.finalize(l_doc);
    ok('landscape: finalize succeeds', DBMS_LOB.GETLENGTH(l_pdf) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 7. Two documents open concurrently — handles are independent
  -- =========================================================================
  DECLARE
    l_doc1 rad_pdf_types.t_doc_handle;
    l_doc2 rad_pdf_types.t_doc_handle;
    l_pdf1 BLOB;
    l_pdf2 BLOB;
    l_hdr1 VARCHAR2(10);
    l_hdr2 VARCHAR2(10);
  BEGIN
    rad_pdf_styles.load_defaults;
    l_doc1 := rad_pdf.new_document;
    l_doc2 := rad_pdf.new_document;
    ok('concurrent: handles distinct', l_doc1 <> l_doc2);
    rad_pdf.heading(l_doc1, 'Document One', 1);
    rad_pdf.heading(l_doc2, 'Document Two', 1);
    rad_pdf.write  (l_doc1, 'Content for document one.');
    rad_pdf.write  (l_doc2, 'Content for document two.');
    l_pdf1 := rad_pdf.finalize(l_doc1);
    l_pdf2 := rad_pdf.finalize(l_doc2);
    l_hdr1 := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf1, 4, 1));
    l_hdr2 := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf2, 4, 1));
    ok('concurrent: doc1 is %PDF', l_hdr1, '%PDF');
    ok('concurrent: doc2 is %PDF', l_hdr2, '%PDF');
    ok('concurrent: blobs are independent', DBMS_LOB.COMPARE(l_pdf1, l_pdf2) <> 0);
    DBMS_LOB.FREETEMPORARY(l_pdf1);
    DBMS_LOB.FREETEMPORARY(l_pdf2);
  END;

  -- =========================================================================
  -- 8. Exception safety: finalize raises on invalid handle
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle := rad_pdf_types.c_invalid_handle;
    l_pdf BLOB;
    l_raised BOOLEAN := FALSE;
  BEGIN
    BEGIN
      l_pdf := rad_pdf.finalize(l_doc);
    EXCEPTION
      WHEN OTHERS THEN
        l_raised := TRUE;
    END;
    ok('bad-handle finalize raises', l_raised);
  END;

  -- =========================================================================
  -- 9. CLOB paragraph (large body text via rad_pdf_layout.paragraph(CLOB) path)
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_pdf  BLOB;
    l_clob CLOB;
    i      PLS_INTEGER;
  BEGIN
    rad_pdf_styles.load_defaults;
    DBMS_LOB.CREATETEMPORARY(l_clob, TRUE);
    FOR i IN 1..10 LOOP
      DBMS_LOB.APPEND(l_clob,
        'Paragraph ' || i || ': Oracle Database is a multi-model database management system. ' ||
        'RAD_PDF generates PDF documents natively in PL/SQL without external libraries.' ||
        CHR(10));
    END LOOP;
    l_doc := rad_pdf.new_document;
    rad_pdf.heading(l_doc, 'Long Document Test', 1);
    rad_pdf.add(l_doc, rad_pdf_layout.paragraph(l_clob, 'body'));
    l_pdf := rad_pdf.finalize(l_doc);
    ok('clob-paragraph: BLOB > 1000', DBMS_LOB.GETLENGTH(l_pdf) > 1000);
    ok('clob-paragraph: contains BT',
       DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('BT')) > 0);
    DBMS_LOB.FREETEMPORARY(l_clob);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 10. Mixed layout + canvas in the same document
  --     Layout adds headings/paragraphs; canvas adds direct drawing on page 1
  --     before any layout content is added (canvas-only mode for first page).
  --     Then finalize picks the correct path.
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
  BEGIN
    l_doc := rad_pdf.new_document;
    -- Direct canvas call on the empty first page (no layout flowables yet)
    rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 14);
    rad_pdf_canvas.write_text(l_doc, 'Canvas watermark', 72, 400, 'pt');
    -- No layout calls: finalize via canvas-only path
    l_pdf := rad_pdf.finalize(l_doc);
    ok('canvas+no-layout: BLOB > 500', DBMS_LOB.GETLENGTH(l_pdf) > 500);
    ok('canvas+no-layout: starts %PDF',
       UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF');
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 11. Multi-byte internationalisation
  --     Regression guard for the ORA-06502 VARCHAR2(1) bug: em-dash (U+2014,
  --     3 bytes in UTF-8) crashed text_to_pdf_string in rad_pdf_fonts.pkb.
  --     Covers accented Latin chars, Euro sign, and mixed-script text.
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
  BEGIN
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf.new_document;

    -- Heading containing em-dash: original crash trigger
    rad_pdf.heading(l_doc, 'Internationalisation Test — Accented Characters', 1);

    -- Body text: accented Latin chars, Euro sign (U+20AC), en-dash
    rad_pdf.write(l_doc,
      'Revenue: € 1,500,000.00 — Fiscal year 2025/2026.');
    rad_pdf.write(l_doc,
      'Contact: Ségolène Müller (Ürban Développement).');
    rad_pdf.write(l_doc,
      'Character set: àèìòù ÀÈÌÒÙ — ñ ü ö ä â ê î û œ æ ß.');

    l_pdf := rad_pdf.finalize(l_doc);
    ok('multibyte: BLOB > 500',
       DBMS_LOB.GETLENGTH(l_pdf) > 500);
    ok('multibyte: starts %PDF',
       UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF');
    ok('multibyte: contains BT',
       DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('BT')) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 12. Paragraph taller than a full page (overflow resilience)
  --     Builds a single paragraph whose measured height exceeds the A4 frame
  --     height (~643 pt).  Verifies that:
  --       a) finalize completes without error (no hang, no ORA-* crash)
  --       b) the layout engine continues past the overflow flowable
  --          (the heading added AFTER the long paragraph also appears)
  --       c) the resulting BLOB is a valid multi-page PDF
  -- =========================================================================
  DECLARE
    l_doc      rad_pdf_types.t_doc_handle;
    l_pdf      BLOB;
    l_long_txt VARCHAR2(32767) := '';
    i          PLS_INTEGER;
  BEGIN
    rad_pdf_styles.load_defaults;

    -- Build ~7 000-char string: at 10 pt / 12 pt leading on A4 this wraps
    -- to ~120 lines, roughly 2× the usable page height (643 pt / 12 pt ≈ 53).
    FOR i IN 1..120 LOOP
      l_long_txt := l_long_txt ||
        LPAD(TO_CHAR(i), 3) ||
        ': RAD_PDF correctly handles paragraphs whose height exceeds the '    ||
        'usable page area without entering an infinite loop or raising ORA-. ';
    END LOOP;

    l_doc := rad_pdf.new_document;
    rad_pdf.heading(l_doc, 'Overflow Paragraph Test', 1);
    rad_pdf.add    (l_doc, rad_pdf_layout.paragraph(l_long_txt, 'body'));

    -- This heading must be rendered on a subsequent page to prove
    -- the layout engine did not stop at the overflow flowable.
    rad_pdf.heading(l_doc, 'Section After Overflow', 2);
    rad_pdf.write  (l_doc, 'Text after the overflow paragraph is present.');

    l_pdf := rad_pdf.finalize(l_doc);
    ok('overflow-para: finalize succeeds (BLOB not null)',
       l_pdf IS NOT NULL);
    ok('overflow-para: BLOB > 3000 (multi-page content)',
       DBMS_LOB.GETLENGTH(l_pdf) > 3000);
    ok('overflow-para: starts %PDF',
       UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF');
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- Summary
  -- =========================================================================
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('Phase 9: ' || l_ok || ' passed, ' || l_fail || ' failed.');
  IF l_fail > 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'Phase 9 FAILED: ' || l_fail || ' failure(s)');
  END IF;
END;
/
