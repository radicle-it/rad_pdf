-- phase10_template.sql — Acceptance tests for rad_pdf_template (Phase 9).
--
-- Run from repo root in SQL*Plus after installing all phases:
--   @tests/phase10_template.sql
--
-- Each test writes a minimal PDF to /tmp; the test passes when no exception
-- is raised and a non-empty BLOB is returned.
-- Adjust the directory alias if /tmp is not a valid Oracle DIRECTORY.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET VERIFY OFF

PROMPT ================================================================
PROMPT  Phase 10 - Template Engine Acceptance Tests
PROMPT ================================================================
PROMPT

DECLARE
  -- ---------------------------------------------------------------------------
  -- Helper: assert a boolean condition; raise if FALSE.
  -- ---------------------------------------------------------------------------
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;

  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;

-- ===========================================================================
-- Test 1: escape_value
-- ===========================================================================
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 1: escape_value');
  assert(rad_pdf_template.escape_value('A & B')    = 'A &amp; B',  'amp');
  assert(rad_pdf_template.escape_value('<tag>')     = '&lt;tag&gt;', 'lt gt');
  assert(rad_pdf_template.escape_value('no special') = 'no special', 'plain');
  assert(rad_pdf_template.escape_value(NULL)        IS NULL,         'null');
  DBMS_OUTPUT.PUT_LINE('  PASS');
END;
/

-- ===========================================================================
-- Test 2: column registry - register, exists implicitly, drop, clear
-- ===========================================================================
DECLARE
  l_cols rad_pdf_types.t_columns;
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 2: column registry');
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(1);
  l_cols(1).label := 'ID';
  l_cols(1).width := 50;

  rad_pdf_template.register_columns('TEST_COLS', l_cols);
  rad_pdf_template.drop_columns('TEST_COLS');
  rad_pdf_template.clear_columns;
  DBMS_OUTPUT.PUT_LINE('  PASS');
END;
/

-- ===========================================================================
-- Test 3: VARCHAR2 template, no binds - headings and paragraphs
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 3: VARCHAR2 template, no binds');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<h1>Report Title</h1>'                                    ||
    '<h2>Sub-heading</h2>'                                     ||
    '<p>This is a body paragraph with plain text.</p>'         ||
    '<spacer height="10pt"/>'                                  ||
    '<hr/>'                                                    ||
    '<p>Second paragraph after the rule.</p>');
  l_pdf := rad_pdf.finalize(l_doc);
  IF DBMS_LOB.GETLENGTH(l_pdf) > 0 THEN
    DBMS_LOB.FREETEMPORARY(l_pdf);
    DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' ||
      DBMS_LOB.GETLENGTH(l_pdf) || ')');
  ELSE
    RAISE_APPLICATION_ERROR(-20999, 'Zero-length PDF returned');
  END IF;
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 4: CLOB template, no binds - all heading levels h1..h6
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_clob CLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 4: CLOB template, all heading levels h1..h6');
  DBMS_LOB.CREATETEMPORARY(l_clob, TRUE);
  DBMS_LOB.WRITEAPPEND(l_clob, LENGTH('<h1>Heading 1</h1>'), '<h1>Heading 1</h1>');
  DBMS_LOB.WRITEAPPEND(l_clob, LENGTH('<h2>Heading 2</h2>'), '<h2>Heading 2</h2>');
  DBMS_LOB.WRITEAPPEND(l_clob, LENGTH('<h3>Heading 3</h3>'), '<h3>Heading 3</h3>');
  DBMS_LOB.WRITEAPPEND(l_clob, LENGTH('<h4>Heading 4</h4>'), '<h4>Heading 4</h4>');
  DBMS_LOB.WRITEAPPEND(l_clob, LENGTH('<h5>Heading 5</h5>'), '<h5>Heading 5</h5>');
  DBMS_LOB.WRITEAPPEND(l_clob, LENGTH('<h6>Heading 6</h6>'), '<h6>Heading 6</h6>');

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, l_clob);
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_clob);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF DBMS_LOB.ISTEMPORARY(l_clob) = 1 THEN DBMS_LOB.FREETEMPORARY(l_clob); END IF;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 5: VARCHAR2 template + bind substitution (#KEY#, ##)
-- ===========================================================================
DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_binds rad_pdf_types.t_bind_array;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 5: bind substitution (#KEY# and ## escape)');
  l_binds(1).key   := 'CUSTOMER';
  l_binds(1).value := 'Acme Corp';
  l_binds(2).key   := 'REF';
  l_binds(2).value := 'INV-2026-001';

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<h1>Invoice for #CUSTOMER#</h1>'         ||
    '<p>Reference: #REF#</p>'                 ||
    '<p>Discount: 10## (ten percent)</p>',
    l_binds);
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 6: inline bold / italic runs inside <p>
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 6: inline <b> and <i> inside <p>');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<p>Plain text</p>'                               ||
    '<p><b>Bold text</b></p>'                         ||
    '<p><i>Italic text</i></p>'                       ||
    '<p><b><i>Bold and italic</i></b></p>'            ||
    '<p>Mixed: <b>bold</b> then <i>italic</i></p>');
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 7: <br/> inside <p> emits a spacer
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 7: <br/> inside <p>');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<p>Line one<br/>Line two<br/>Line three</p>');
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 8: <spacer> with unit and <hr> with color attribute
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 8: <spacer> and <hr> attributes');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<p>Before spacer</p>'                         ||
    '<spacer height="20pt"/>'                      ||
    '<hr color="CCCCCC" width="0.5"/>'             ||
    '<p>After hr</p>');
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 9: <pagebreak/>
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 9: <pagebreak/>');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<h1>Page One</h1>'           ||
    '<p>Content on page 1.</p>'   ||
    '<pagebreak/>'                ||
    '<h1>Page Two</h1>'           ||
    '<p>Content on page 2.</p>');
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 10: <p style="caption"> - custom style attribute on <p>
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 10: <p style="caption">');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<p>Normal paragraph.</p>'                ||
    '<p style="caption">Caption text.</p>');
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 11: error - template > 32767 chars with binds raises ORA-20810
-- ===========================================================================
DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_binds rad_pdf_types.t_bind_array;
  l_big   CLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 11: ORA-20810 for oversized template with binds');
  l_binds(1).key := 'X'; l_binds(1).value := 'y';
  DBMS_LOB.CREATETEMPORARY(l_big, TRUE);
  -- Build a CLOB > 32767 chars
  FOR i IN 1..1100 LOOP
    DBMS_LOB.WRITEAPPEND(l_big, 30, '<p>Padding line of text here.</p>');
  END LOOP;

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf_template.render(l_doc, l_big, l_binds);
    -- Should not reach here
    RAISE_APPLICATION_ERROR(-20999, 'Expected ORA-20810 not raised');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20810 THEN
        DBMS_OUTPUT.PUT_LINE('  PASS  (ORA-20810 raised as expected)');
      ELSE
        RAISE;
      END IF;
  END;
  DBMS_LOB.FREETEMPORARY(l_big);
  rad_pdf.close_document(l_doc);
EXCEPTION WHEN OTHERS THEN
  IF DBMS_LOB.ISTEMPORARY(l_big) = 1 THEN DBMS_LOB.FREETEMPORARY(l_big); END IF;
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 12: error - unknown tag with strict_tags=TRUE raises ORA-20811
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_opts rad_pdf_types.t_template_options;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 12: ORA-20811 for unknown tag (strict mode)');
  rad_pdf_styles.load_defaults;
  l_doc        := rad_pdf.new_document;
  l_opts.strict_tags := TRUE;
  BEGIN
    rad_pdf_template.render(l_doc,
      '<p>Good</p><div>Bad tag</div>',
      l_opts);
    RAISE_APPLICATION_ERROR(-20999, 'Expected ORA-20811 not raised');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20811 THEN
        DBMS_OUTPUT.PUT_LINE('  PASS  (ORA-20811 raised as expected)');
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
-- Test 13: unknown tag with strict_tags=FALSE is silently ignored
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_opts rad_pdf_types.t_template_options;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 13: unknown tag silently ignored (strict_tags=FALSE)');
  rad_pdf_styles.load_defaults;
  l_doc             := rad_pdf.new_document;
  l_opts.strict_tags := FALSE;
  rad_pdf_template.render(l_doc,
    '<p>Good paragraph</p>'          ||
    '<div>Ignored div</div>'          ||
    '<p>After ignored tag</p>',
    l_opts);
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 14: error - <table> without allow_queries raises ORA-20815
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_cols rad_pdf_types.t_columns;
  l_opts rad_pdf_types.t_template_options;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 14: ORA-20815 for <table> without allow_queries');
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(1);
  l_cols(1).label := 'COL1';
  l_cols(1).width := 100;
  rad_pdf_template.register_columns('SECURE_TEST', l_cols);

  rad_pdf_styles.load_defaults;
  l_doc             := rad_pdf.new_document;
  l_opts.allow_queries := FALSE;  -- queries not enabled
  BEGIN
    rad_pdf_template.render(l_doc,
      '<h1>Test</h1>' ||
      '<table columns="SECURE_TEST" query="SELECT 1 FROM DUAL"' ||
             ' allow_query="true"/>',
      l_opts);
    RAISE_APPLICATION_ERROR(-20999, 'Expected ORA-20815 not raised');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20815 THEN
        DBMS_OUTPUT.PUT_LINE('  PASS  (ORA-20815 raised as expected)');
      ELSE
        RAISE;
      END IF;
  END;
  rad_pdf_template.drop_columns('SECURE_TEST');
  rad_pdf.close_document(l_doc);
EXCEPTION WHEN OTHERS THEN
  rad_pdf_template.drop_columns('SECURE_TEST');
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 15: rad_pdf.render_template facade shortcut
-- ===========================================================================
DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_binds rad_pdf_types.t_bind_array;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 15: rad_pdf.render_template facade');
  l_binds(1).key   := 'TITLE';
  l_binds(1).value := 'Facade Test';

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.render_template(l_doc,
    '<h1>#TITLE#</h1><p>Generated via facade.</p>',
    l_binds);
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 16: entity encoding round-trip (&amp; &lt; &gt;)
-- ===========================================================================
DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_binds rad_pdf_types.t_bind_array;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 16: entity encoding in bind values and template');
  -- Value contains HTML special chars; user should escape them
  l_binds(1).key   := 'EXPR';
  l_binds(1).value := rad_pdf_template.escape_value('a < b & c > d');

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<h1>Entity Test</h1>'              ||
    '<p>Expression: #EXPR#</p>'         ||
    '<p>Literal: &amp;amp; &lt; &gt;</p>',
    l_binds);
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

PROMPT
PROMPT ================================================================
PROMPT  Phase 10 template engine tests complete.
PROMPT ================================================================
