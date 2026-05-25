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
  -- Variables must precede subprogram declarations in Oracle PL/SQL.
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;

  -- ---------------------------------------------------------------------------
  -- Helper: assert a boolean condition; raise if FALSE.
  -- ---------------------------------------------------------------------------
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;

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
    DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' ||
      DBMS_LOB.GETLENGTH(l_pdf) || ')');
    DBMS_LOB.FREETEMPORARY(l_pdf);   -- free after reading length
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
-- Test 11: error - <if> tag with missing bind attribute raises ORA-20810
-- ===========================================================================
DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_binds rad_pdf_types.t_bind_array;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 11: ORA-20810 for <if> missing bind attribute');
  l_binds(1).key := 'X'; l_binds(1).value := 'y';
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    -- <if x="y"> has the '<if ' prefix but no bind attribute -> ORA-20810
    rad_pdf_template.render(l_doc,
      TO_CLOB('<p>Before</p><if x="y"><p>content</p></if><p>After</p>'), l_binds);
    RAISE_APPLICATION_ERROR(-20999, 'Expected ORA-20810 not raised');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20810 THEN
        DBMS_OUTPUT.PUT_LINE('  PASS  (ORA-20810 raised as expected)');
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
-- Test 16: entity encoding — bind values are auto-escaped (no escape_value call)
-- ===========================================================================
DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_binds rad_pdf_types.t_bind_array;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 16: entity encoding in bind values and template');
  -- Value contains HTML special chars; auto-escape (raw=FALSE, default) handles it.
  -- No explicit escape_value() call required.
  l_binds(1).key   := 'EXPR';
  l_binds(1).value := 'a < b & c > d';   -- auto-escaped by apply_binds

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

-- Test 17: NULL bind value for a token present in the template raises ORA-20810
-- ---------------------------------------------------------------------------
-- Oracle REPLACE(str, search, NULL) silently removes the token rather than
-- substituting an empty string.  apply_binds must detect this and raise a
-- clear error so the caller can use NVL instead of getting a cryptic
-- ORA-00936 later when the corrupted SQL is executed.
-- ---------------------------------------------------------------------------
DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_binds rad_pdf_types.t_bind_array;
  l_ok    BOOLEAN := FALSE;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 17: NULL bind raises ORA-20810 (not silent token removal)');
  l_binds(1).key   := 'MYKEY';
  l_binds(1).value := NULL;          -- deliberately NULL

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf_template.render(l_doc,
      '<p>Value is #MYKEY# here.</p>',
      l_binds);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_template THEN
        l_ok := TRUE;
        DBMS_OUTPUT.PUT_LINE('  PASS  (ORA-20810 raised as expected: '
                             || SQLERRM || ')');
      ELSE
        RAISE;
      END IF;
  END;
  IF NOT NVL(l_ok, FALSE) THEN
    RAISE_APPLICATION_ERROR(-20999,
      'Expected ORA-20810 for NULL bind value but no error was raised');
  END IF;
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 18: '>' inside <table> query attribute is parsed correctly
-- ---------------------------------------------------------------------------
-- Bug: do_render used DBMS_LOB.INSTR(clob, '>') which found the first '>'
-- regardless of whether it was inside a quoted attribute value.  A query
-- such as  WHERE sal > 1000  caused the tag to be truncated at the '>' in
-- the SQL expression, making extract_attr return NULL for "query" and raising
-- ORA-20813 (<table> missing required "query" attribute).
--
-- Fix: find_tag_end() scans the CLOB in 512-byte chunks tracking quote state,
-- so '>' inside "..." or '...' is skipped; only an unquoted '>' ends the tag.
-- ---------------------------------------------------------------------------
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns;
  l_opts rad_pdf_types.t_template_options;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 18: > inside <table> query attribute (quote-aware parser)');

  -- Column set: two columns for the salary report
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(2);
  l_cols(1).label := 'Name';   l_cols(1).width := 150;
  l_cols(2).label := 'Salary'; l_cols(2).width := 100;
  l_cols(2).data_fmt.num_format := '999,990.00';
  rad_pdf_template.register_columns('TEST18_COLS', l_cols);

  l_opts.allow_queries := TRUE;
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  -- Template contains '>' (greater-than) and '>=' inside the query attribute.
  -- Before the fix this raised ORA-20813; after the fix it must succeed.
  rad_pdf_template.render(l_doc,
    '<h1>Salary Report</h1>'                                           ||
    '<table columns="TEST18_COLS"'                                     ||
    ' query="SELECT ename, sal FROM emp WHERE sal > 0'                 ||
    '   AND sal >= 800 ORDER BY sal DESC"'                             ||
    ' allow_query="true"/>',
    l_opts);

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' || DBMS_LOB.GETLENGTH(l_pdf) || ')');
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- =============================================================================
-- Test 19: Inline <b> and <i> render on the same line (PARA_RUNS flowable)
-- =============================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 19: inline <b>/<i> rendered on the same line (PARA_RUNS)');

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  -- Paragraph with bold inline: all three runs must land on one line,
  -- not be emitted as three separate block-level paragraphs.
  -- Verify: PDF is non-empty (rendering did not raise an error).
  rad_pdf_template.render(l_doc,
    '<p>The report by <b>Mario Rossi</b> has been approved.</p>'          ||
    '<p>Status: <i>Pending</i> — Priority: <b><i>High</i></b></p>'        ||
    '<p>Normal paragraph with no inline tags.</p>');

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' || DBMS_LOB.GETLENGTH(l_pdf) || ')');
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- =============================================================================
-- Test 20: auto-escape bind values (raw=FALSE default) and raw=TRUE opt-out
-- =============================================================================
DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_binds rad_pdf_types.t_bind_array;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 20: auto-escape (raw=FALSE) and raw=TRUE opt-out');

  -- raw=FALSE (default): & < > are auto-escaped before substitution.
  -- The rendered PDF should show literal "a < b & c > d" (not broken tags).
  l_binds(1).key   := 'USER_TEXT';
  l_binds(1).value := 'Tom & Jerry < Spike > everyone';
  -- raw=FALSE is the default; no need to set it explicitly

  -- raw=TRUE: value used verbatim — useful for pre-escaped or intentionally
  -- structured values (e.g. a numeric string that contains no special chars).
  l_binds(2).key   := 'SAFE_NUM';
  l_binds(2).value := '42';
  l_binds(2).raw   := TRUE;

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<h1>Auto-escape Test</h1>'                    ||
    '<p>User input: #USER_TEXT#</p>'               ||
    '<p>Safe number: #SAFE_NUM#</p>',
    l_binds);
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' || DBMS_LOB.GETLENGTH(l_pdf) || ')');
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- =============================================================================
-- Test 21: <ul> and <ol> list tags
-- =============================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 21: <ul> and <ol> list tags');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<h1>List Test</h1>'                                                   ||
    '<p>Unordered:</p>'                                                    ||
    '<ul>'                                                                 ||
      '<li>First plain item</li>'                                          ||
      '<li>Second item with <b>bold</b> text</li>'                        ||
      '<li>Third item</li>'                                                ||
    '</ul>'                                                                ||
    '<spacer height="8pt"/>'                                               ||
    '<p>Ordered:</p>'                                                      ||
    '<ol>'                                                                 ||
      '<li>Step one</li>'                                                  ||
      '<li>Step two — <i>important</i></li>'                              ||
      '<li>Step three</li>'                                                ||
    '</ol>');
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' || DBMS_LOB.GETLENGTH(l_pdf) || ')');
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- =============================================================================
-- Test 22: <table> with row_height, max_rows, header_bg, alt_bg, border_color
-- =============================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns;
  l_opts rad_pdf_types.t_template_options;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 22: <table> with row_height / max_rows / color attributes');

  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(2);
  l_cols(1).label := 'Name';   l_cols(1).width := 150;
  l_cols(2).label := 'Salary'; l_cols(2).width := 100;
  rad_pdf_template.register_columns('TEST22_COLS', l_cols);

  l_opts.allow_queries := TRUE;
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,
    '<h1>Styled Table</h1>'                                               ||
    '<table columns="TEST22_COLS"'                                        ||
    ' query="SELECT ename, sal FROM emp ORDER BY sal DESC"'               ||
    ' row_height="16pt"'                                                  ||
    ' max_rows="5"'                                                       ||
    ' header_bg="003366"'                                                  ||
    ' alt_bg="E8EEF4"'                                                    ||
    ' border_color="AAAAAA"'                                              ||
    ' allow_query="true"/>',
    l_opts);

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' || DBMS_LOB.GETLENGTH(l_pdf) || ')');
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 23: <if bind="KEY"> conditional blocks
-- ===========================================================================
DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
  l_tmpl   VARCHAR2(4000);
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 23: <if bind="KEY"> conditional blocks');
  -- Template has two conditional blocks:
  --   SHOWN is non-NULL -> its <p> is included
  --   HIDDEN is NULL    -> its <p> is suppressed
  l_tmpl :=
    '<h1>Conditional Test</h1>'                              ||
    '<if bind="SHOWN"><p>This paragraph is visible.</p></if>'||
    '<if bind="HIDDEN"><p>This should be hidden.</p></if>'   ||
    '<p>Always visible.</p>';

  l_binds(1).key   := 'SHOWN';
  l_binds(1).value := 'yes';

  -- HIDDEN intentionally omitted from the array -> key absent -> FALSE

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, TO_CLOB(l_tmpl), l_binds);
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' || DBMS_LOB.GETLENGTH(l_pdf) || ')');
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 24: <if bind> with bind substitution inside the block
--   - TRUE  block: content includes a #TOKEN# that is substituted
--   - FALSE block: content includes a #TOKEN# that is never substituted
--     (the block is discarded before apply_binds_clob runs, so the NULL
--     bind value for the suppressed block does NOT trigger the NULL guard)
-- ===========================================================================
DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
  l_tmpl   VARCHAR2(4000);
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 24: <if bind> with token substitution inside block');

  -- TRUE  block: DEPT_NOTES has a value -> included, #DEPT_NOTES# substituted
  -- FALSE block: EXTRA_NOTES is NULL    -> discarded; #EXTRA_NOTES# never seen
  --              by apply_binds_clob, so no NULL error is raised.
  l_tmpl :=
    '<h1>Report for #DEPT#</h1>'                                         ||
    '<if bind="DEPT_NOTES"><p>Notes: #DEPT_NOTES#</p></if>'             ||
    '<if bind="EXTRA_NOTES"><p>Extra: #EXTRA_NOTES#</p></if>'           ||
    '<p>End of report.</p>';

  l_binds(1).key   := 'DEPT';
  l_binds(1).value := 'SALES';

  l_binds(2).key   := 'DEPT_NOTES';
  l_binds(2).value := 'Q1 target exceeded by 12%.';

  -- EXTRA_NOTES is absent from the array entirely -> condition FALSE -> block dropped
  -- (There is no need to add EXTRA_NOTES to the array at all; the <if> block
  --  is skipped when the key is missing, and #EXTRA_NOTES# never reaches
  --  apply_binds_clob.)

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, TO_CLOB(l_tmpl), l_binds);
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' || DBMS_LOB.GETLENGTH(l_pdf) || ')');
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 25: large CLOB (> 32767 chars) with bind substitution
-- Verifies Point 5: CLOB-based apply_binds_clob has no size limit.
-- ===========================================================================
DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
  l_tmpl   CLOB;
  l_chunk  VARCHAR2(32767);
  l_para   VARCHAR2(200);
  l_n      PLS_INTEGER := 0;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 25: large CLOB (> 32767 chars) with bind substitution');
  DBMS_LOB.CREATETEMPORARY(l_tmpl, TRUE);

  -- Build a header with a bind token
  l_chunk := '<h1>Long Template: #TITLE#</h1>';
  DBMS_LOB.WRITEAPPEND(l_tmpl, LENGTH(l_chunk), l_chunk);

  -- Pad to well beyond 32767 characters using repeated <p> blocks
  l_para := '<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. '
         || 'Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.</p>';
  WHILE NVL(DBMS_LOB.GETLENGTH(l_tmpl), 0) < 40000 LOOP
    l_n := l_n + 1;
    DBMS_LOB.WRITEAPPEND(l_tmpl, LENGTH(l_para), l_para);
  END LOOP;

  -- Append a tail with another bind token
  l_chunk := '<p>Total paragraphs: #COUNT#. Done.</p>';
  DBMS_LOB.WRITEAPPEND(l_tmpl, LENGTH(l_chunk), l_chunk);

  l_binds(1).key   := 'TITLE';
  l_binds(1).value := 'Stress Test';
  l_binds(2).key   := 'COUNT';
  l_binds(2).value := TO_CHAR(l_n);

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, l_tmpl, l_binds);
  DBMS_LOB.FREETEMPORARY(l_tmpl);
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' || DBMS_LOB.GETLENGTH(l_pdf)
                       || ', paragraphs: ' || l_n || ')');
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
  IF DBMS_LOB.ISTEMPORARY(l_tmpl) = 1 THEN DBMS_LOB.FREETEMPORARY(l_tmpl); END IF;
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 26: inline <color> and <font size> tags
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 26: inline <color rgb="..."> and <font size="...">');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  -- Plain text + red-coloured run + bold-red run + font-size-change run
  rad_pdf_template.render(l_doc,
    '<h1>Inline Style Test</h1>'                                         ||
    '<p>Normal text, '                                                   ||
       '<color rgb="CC0000">red text</color>, '                         ||
       '<b><color rgb="CC0000">bold red</color></b>, '                  ||
       'back to normal.</p>'                                             ||
    '<p>Size change: '                                                   ||
       '<font size="14pt">large</font> and '                            ||
       '<font size="8pt">small</font> text.</p>'                        ||
    '<p>Combined: '                                                      ||
       '<b><font size="13pt"><color rgb="003399">blue bold 13pt'        ||
       '</color></font></b> done.</p>');

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' || DBMS_LOB.GETLENGTH(l_pdf) || ')');
  DBMS_LOB.FREETEMPORARY(l_pdf);
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
