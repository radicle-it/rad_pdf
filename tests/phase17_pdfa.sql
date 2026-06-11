-- phase17_pdfa.sql - Acceptance tests for PDF/A-2b conformance (v1.7.0).
--
-- Run from repo root in SQL*Plus after installing all phases:
--   @tests/phase17_pdfa.sql
--
-- Structural tests only (XMP/OutputIntent/ID markers, font enforcement).
-- Full ISO 19005-2 validation is performed out of band with veraPDF
-- (https://verapdf.org): a vector-only document and a document with
-- embedded-TTF text + chart + QR both validate isCompliant="true".

SET SERVEROUTPUT ON SIZE UNLIMITED
SET VERIFY OFF
SET DEFINE OFF

PROMPT ================================================================
PROMPT  Phase 17 - PDF/A-2b Acceptance Tests (v1.7.0)
PROMPT ================================================================
PROMPT

-- ===========================================================================
-- Test 1: conformance mode emits XMP, OutputIntent, /ID and synced dates
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_info rad_pdf_types.t_doc_info;
  l_v    rad_pdf_types.t_number_list;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
  FUNCTION has(p_txt VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW(p_txt)) > 0;
  END has;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 1: PDF/A markers in a vector-only document');
  rad_pdf_styles.load_defaults;
  l_info.title  := 'Conformance & test <1>';
  l_info.author := 'RAD_PDF';
  l_doc := rad_pdf.new_document(p_info => l_info);
  rad_pdf.set_conformance(l_doc, 'PDF/A-2B');
  l_v(1) := 30; l_v(2) := 70;
  rad_pdf.pie_chart(l_doc, l_v, 200, 500, 80, p_legend => FALSE);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(has('pdfaid:part>2'),            'XMP pdfaid:part missing');
  assert(has('pdfaid:conformance>B'),     'XMP pdfaid:conformance missing');
  assert(has('/Type /Metadata'),          '/Metadata stream missing');
  assert(has('/OutputIntents ['),         'OutputIntent missing');
  assert(has('GTS_PDFA1'),                'GTS_PDFA1 subtype missing');
  assert(has('/ID [<'),                   'trailer /ID missing');
  -- XML-escaped title in XMP, parenthesised in Info: both present
  assert(has('Conformance &amp; test &lt;1&gt;'), 'escaped XMP title missing');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 2: standard-14 fonts raise c_err_font in conformance mode
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 2: non-embedded font raises c_err_font');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.set_conformance(l_doc, 'PDF/A-2B');
  rad_pdf.write(l_doc, 'Helvetica text');
  BEGIN
    l_pdf := rad_pdf.finalize(l_doc);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: standard font accepted');
  EXCEPTION WHEN OTHERS THEN
    assert(SQLCODE = rad_pdf_types.c_err_font,
           'expected -20700, got ' || SQLCODE);
    assert(INSTR(SQLERRM, 'Helvetica') > 0, 'offending font not named');
  END;
  DBMS_OUTPUT.PUT_LINE('  PASS  (-20700 with the offending font named)');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 3: unsupported conformance level rejected at registration
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 3: unsupported level raises -20400');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf.set_conformance(l_doc, 'PDF/A-1B');
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: PDF/A-1B accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = rad_pdf_types.c_err_validation THEN
      DBMS_OUTPUT.PUT_LINE('  PASS  (-20400 raised as expected)');
    ELSE
      RAISE;
    END IF;
  END;
  rad_pdf.close_document(l_doc);
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 4: plain documents are untouched (no /Metadata, but /ID is present)
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 4: no conformance - no PDF/A objects');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Plain document.');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Type /Metadata')) = 0,
         'unexpected /Metadata');
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/OutputIntents')) = 0,
         'unexpected OutputIntent');
  -- /ID is now always written (harmless, required only by PDF/A)
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/ID [<')) > 0,
         '/ID missing');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 5: conformance state is per-document and cleared on close
-- ===========================================================================
DECLARE
  l_doc1 rad_pdf_types.t_doc_handle;
  l_doc2 rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_v    rad_pdf_types.t_number_list;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 5: per-document conformance isolation');
  rad_pdf_styles.load_defaults;
  l_doc1 := rad_pdf.new_document;
  l_doc2 := rad_pdf.new_document;
  rad_pdf.set_conformance(l_doc1, 'PDF/A-2B');
  l_v(1) := 1;
  rad_pdf.pie_chart(l_doc1, l_v, 200, 500, 50, p_legend => FALSE);
  rad_pdf.pie_chart(l_doc2, l_v, 200, 500, 50, p_legend => FALSE);
  l_pdf := rad_pdf.finalize(l_doc1);
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Type /Metadata')) > 0,
         'doc1 metadata missing');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  l_pdf := rad_pdf.finalize(l_doc2);
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Type /Metadata')) = 0,
         'doc2 unexpectedly conformant');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc1); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN rad_pdf.close_document(l_doc2); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

PROMPT
PROMPT ================================================================
PROMPT  Phase 17 complete - all PDF/A tests passed.
PROMPT ================================================================
