-- phase10_template.sql - Acceptance tests for rad_pdf_template (Phase 9).
--
-- Run from repo root in SQL*Plus after installing all phases:
--   @tests/phase10_template.sql
--
-- Each test writes a minimal PDF to /tmp; the test passes when no exception
-- is raised and a non-empty BLOB is returned.
-- Adjust the directory alias if /tmp is not a valid Oracle DIRECTORY.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET VERIFY OFF
-- Prevent & in string literals (e.g. escape_value test strings) from being
-- treated as substitution variable prefixes by SQL*Plus / SQLcl.
SET DEFINE OFF

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
-- Test 16: entity encoding - bind values are auto-escaped (no escape_value call)
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
    '<p>Status: <i>Pending</i> - Priority: <b><i>High</i></b></p>'        ||
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

  -- raw=TRUE: value used verbatim - useful for pre-escaped or intentionally
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
      '<li>Step two - <i>important</i></li>'                              ||
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

-- ===========================================================================
-- Test 27: <IF> uppercase normalization (Usability A fix)
-- <IF bind="KEY"> and </IF> must be normalized to lowercase automatically.
-- ===========================================================================
DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_binds rad_pdf_types.t_bind_array;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 27: <IF> uppercase normalization');
  l_binds(1).key   := 'DEPT';
  l_binds(1).value := 'SALES';
  -- ABSENT key -> FALSE block -> dropped even though tags are uppercase
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, TO_CLOB(
    '<h1>Dept: #DEPT#</h1>'                                        ||
    '<IF bind="ABSENT"><p>Should not appear.</p></IF>'             ||
    '<IF bind="DEPT"><p>Department is #DEPT#.</p></IF>'            ||
    '<p>Done.</p>'),
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

-- ===========================================================================
-- Test 28: <LI> case-insensitive inside <ul> (Bug C fix)
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 28: <LI> case-insensitive inside <ul>/<ol>');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  -- Mix uppercase <LI> and lowercase <li> - both must be found
  rad_pdf_template.render(l_doc,
    '<h1>List Test</h1>'                                           ||
    '<ul>'                                                         ||
      '<LI>Item one (uppercase LI)</LI>'                          ||
      '<li>Item two (lowercase li)</li>'                          ||
      '<Li>Item three (mixed case Li)</Li>'                        ||
    '</ul>'                                                        ||
    '<ol>'                                                         ||
      '<LI>Numbered one</LI>'                                      ||
      '<li>Numbered two</li>'                                      ||
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

-- ===========================================================================
-- Test 29: <br/> in plain paragraph uses PARA_RUNS (Usability C fix)
-- A <p> with only <br/> and no other inline tags previously produced a
-- 2pt spacer (plain-paragraph path).  After the fix it uses PARA_RUNS,
-- giving a true forced line break inside the paragraph.
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 29: <br/> routes through PARA_RUNS even without bold/italic');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<h1>Break Test</h1>'                              ||
    '<p>Line one.<br/>Line two.<br/>Line three.</p>'   ||
    '<p>Second paragraph (no breaks).</p>');
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
-- Test 30: inline markup inside <h1>-<h6> (Completeness B fix)
-- Inline <b>, <color>, <font> inside a heading route through dispatch_paragraph
-- with 'h{N}' style instead of rad_pdf_layout.heading().
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 30: inline markup inside <h1>-<h6>');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<h1>Plain heading level 1</h1>'                                        ||
    '<h2>Heading with <b>bold</b> word</h2>'                               ||
    '<h3>Heading with <color rgb="CC0000">red</color> word</h3>'           ||
    '<h4>Heading <b><color rgb="003399">bold blue</color></b> combined</h4>'||
    '<h5>Heading with <font size="9pt">small</font> text</h5>'             ||
    '<h6>Plain h6 heading</h6>'                                             ||
    '<p>Body follows.</p>');
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
-- Test 31: t_template_options.default_font_name/style/size (Bug E fix)
-- Setting these options previously had no effect.  After the fix they
-- create a derived style and use it as the default_style.
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_opts rad_pdf_types.t_template_options;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 31: default_font_name / default_font_size options');
  rad_pdf_styles.load_defaults;
  l_opts.default_font_size  := 13;
  l_opts.default_font_style := 'B';
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<h1>Font Options Test</h1>'                                   ||
    '<p>This paragraph should be bold 13pt (from options).</p>'   ||
    '<p>So should this one.</p>',
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
-- Test 32: long <p> content (> 32767 chars) plain text (Bug B fix)
-- A single <p> block whose content exceeds 32767 characters previously
-- raised ORA-20810.  Plain text (no inline tags) now uses the CLOB overload
-- of rad_pdf_layout.paragraph.
-- ===========================================================================
DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_tmpl   CLOB;
  l_para   VARCHAR2(4000);
  l_chunk  VARCHAR2(100);
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 32: single <p> with content > 32767 chars (plain text)');
  DBMS_LOB.CREATETEMPORARY(l_tmpl, TRUE);

  -- Build a single <p> block with > 32767 chars of plain text
  l_chunk := '<p>';
  DBMS_LOB.WRITEAPPEND(l_tmpl, LENGTH(l_chunk), l_chunk);
  l_para  := 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. '
          || 'Pellentesque habitant morbi tristique senectus. ';
  WHILE NVL(DBMS_LOB.GETLENGTH(l_tmpl), 0) < 33800 LOOP
    DBMS_LOB.WRITEAPPEND(l_tmpl, LENGTH(l_para), l_para);
  END LOOP;
  l_chunk := '</p>';
  DBMS_LOB.WRITEAPPEND(l_tmpl, LENGTH(l_chunk), l_chunk);

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, l_tmpl);
  DBMS_LOB.FREETEMPORARY(l_tmpl);
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' || DBMS_LOB.GETLENGTH(l_pdf) || ')');
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
  IF DBMS_LOB.ISTEMPORARY(l_tmpl) = 1 THEN DBMS_LOB.FREETEMPORARY(l_tmpl); END IF;
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 33: <table> distinct error messages for tag vs options (Usability D fix)
-- Error -20815 must name which of the two opt-in conditions is missing.
-- ===========================================================================
DECLARE
  l_cols  rad_pdf_types.t_columns;
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_opts  rad_pdf_types.t_template_options;
  l_got   VARCHAR2(4000);
  l_tmpl_tag  CONSTANT VARCHAR2(400) :=
    '<table columns="ERR_COLS"'                            ||
    ' query="SELECT 1 FROM DUAL"'                         ||
    ' allow_query="true"/>';   -- tag has allow_query; options do NOT
  l_tmpl_opt  CONSTANT VARCHAR2(400) :=
    '<table columns="ERR_COLS"'                            ||
    ' query="SELECT 1 FROM DUAL"/>';  -- tag missing allow_query; options DO

  PROCEDURE assert_err(p_got IN VARCHAR2, p_fragment IN VARCHAR2) IS
  BEGIN
    IF INSTR(p_got, p_fragment) = 0 THEN
      RAISE_APPLICATION_ERROR(-20999,
        'Expected fragment "' || p_fragment || '" in error: ' || p_got);
    END IF;
  END;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 33: <table> distinct opt-in errors (tag vs options)');
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(1);
  l_cols(1).label := 'X';
  l_cols(1).width := 50;
  rad_pdf_template.register_columns('ERR_COLS', l_cols);

  -- Case A: tag has allow_query="true" but options.allow_queries = FALSE (default)
  BEGIN
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf.new_document;
    rad_pdf_template.render(l_doc, l_tmpl_tag);  -- no options passed -> allow_queries=FALSE
    l_pdf := rad_pdf.finalize(l_doc);
    DBMS_LOB.FREETEMPORARY(l_pdf);
    RAISE_APPLICATION_ERROR(-20999, 'Expected ORA-20815 but none raised (case A)');
  EXCEPTION
    WHEN OTHERS THEN
      l_got := SQLERRM;
      IF SQLCODE != -20815 THEN RAISE; END IF;
      assert_err(l_got, 't_template_options');  -- error mentions options
      BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  END;

  -- Case B: tag missing allow_query but options.allow_queries = TRUE
  BEGIN
    l_opts.allow_queries := TRUE;
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf.new_document;
    rad_pdf_template.render(l_doc, l_tmpl_opt, l_opts);
    l_pdf := rad_pdf.finalize(l_doc);
    DBMS_LOB.FREETEMPORARY(l_pdf);
    RAISE_APPLICATION_ERROR(-20999, 'Expected ORA-20815 but none raised (case B)');
  EXCEPTION
    WHEN OTHERS THEN
      l_got := SQLERRM;
      IF SQLCODE != -20815 THEN RAISE; END IF;
      assert_err(l_got, 'allow_query="true"');  -- error mentions tag attribute
      BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  END;

  rad_pdf_template.drop_columns('ERR_COLS');
  DBMS_OUTPUT.PUT_LINE('  PASS');
END;
/

-- ===========================================================================
-- Test 34: unlimited nesting depth for <color> and <font> (stack fix)
-- Before the fix: a single l_save_color variable - closing the outer </color>
-- restored the wrong value.  After the fix: LIFO stacks handle any depth.
--
-- Template layout (colour):
--   <color FF0000> Red
--     <color 00FF00> Green
--       <color 0000FF> Blue </color>   -> back to Green
--     </color>                         -> back to Red
--   </color>                           -> back to inherit (black)
--
-- Template layout (font size):
--   <font 14pt> large
--     <font 10pt> normal-inside-large </font>  -> back to 14pt
--   </font>                                    -> back to inherit
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 34: unlimited nesting depth for <color> and <font>');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<h1>Nested inline tag test</h1>'                                         ||
    '<p>'
    || '<color rgb="FF0000">Red '
    ||   '<color rgb="00FF00">Green '
    ||     '<color rgb="0000FF">Blue</color>'
    ||   ' Back-to-green</color>'
    || ' Back-to-red</color>'
    || ' Black-again'
    || '</p>'                                                                  ||
    '<p>'
    || 'Normal '
    || '<font size="14pt">Large '
    ||   '<font size="10pt">normal-inside-large</font>'
    || ' large-again</font>'
    || ' normal-again.'
    || '</p>');
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
-- Test 35: long <ul> content (> 32767 chars) with uppercase <LI> tags
-- Before the fix: DBMS_LOB.INSTR(p_content, '<li>') silently missed <LI>
-- items, producing an empty list.  After the fix: Phase 0 normalises
-- <LI> -> <li> before the CLOB reaches the long-list parser.
-- The no-binds render() overload is used so Phase 0 normalisation on that
-- code path is also exercised.
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_tmpl CLOB;
  l_item VARCHAR2(200);
  l_i    PLS_INTEGER := 1;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 35: long <ul> (>32767 chars) with uppercase <LI> tags');
  DBMS_LOB.CREATETEMPORARY(l_tmpl, TRUE);
  DBMS_LOB.WRITEAPPEND(l_tmpl, LENGTH('<ul>'), '<ul>');
  -- Build items using uppercase <LI> / </LI>; ~80 chars each -> >32767 after ~420 items
  WHILE NVL(DBMS_LOB.GETLENGTH(l_tmpl), 0) < 33800 LOOP
    l_item := '<LI>Item ' || TO_CHAR(l_i, 'FM0000')
           || ' - a moderately long description to inflate the CLOB size.</LI>';
    DBMS_LOB.WRITEAPPEND(l_tmpl, LENGTH(l_item), l_item);
    l_i := l_i + 1;
  END LOOP;
  DBMS_LOB.WRITEAPPEND(l_tmpl, LENGTH('</ul>'), '</ul>');

  -- Use the no-binds overload: exercises Phase 0 normalisation on that path
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, l_tmpl);
  DBMS_LOB.FREETEMPORARY(l_tmpl);
  l_pdf := rad_pdf.finalize(l_doc);
  -- A blank document is only ~682 bytes.  A 420-item list must be much larger.
  -- This assertion catches the regression where uppercase <LI> normalisation
  -- produces an implicit temporary LOB that do_render silently treats as empty.
  IF DBMS_LOB.GETLENGTH(l_pdf) < 5000 THEN
    RAISE_APPLICATION_ERROR(-20999,
      'PDF too small (' || DBMS_LOB.GETLENGTH(l_pdf) ||
      ' bytes) - list items were not rendered (blank document = ~682 bytes)');
  END IF;
  DBMS_OUTPUT.PUT_LINE('  PASS  (PDF bytes: ' || DBMS_LOB.GETLENGTH(l_pdf) || ')');
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
  IF l_tmpl IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_tmpl) = 1 THEN
    DBMS_LOB.FREETEMPORARY(l_tmpl);
  END IF;
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ---------------------------------------------------------------------------
-- Test 36: SQL injection via <table query="..."> is blocked by safe quoting.
--   shield_query_attrs replaces #TOKEN# in query attributes with sentinels
--   before Phase 2 (apply_binds_clob) runs.  handle_table_tag then resolves
--   each sentinel by wrapping the raw value in single quotes, doubling any
--   embedded quotes (SQL safe-quote: ' -> '').
--
--   We use DNAME (VARCHAR2) rather than DEPTNO (NUMBER) so the comparison
--   'QL_INJ_TEST''--' does not trigger ORA-01722 (implicit number coercion).
--   With naive concatenation the payload 'QL_INJ_TEST''--' would produce:
--     WHERE dname = QL_INJ_TEST'-- ...   <- ORA-01756 (unclosed string literal)
--   With safe quoting it produces:
--     WHERE dname = 'QL_INJ_TEST''--'    <- valid SQL; returns zero rows.
-- ---------------------------------------------------------------------------
DECLARE
  l_doc     rad_pdf_types.t_doc_handle;
  l_pdf     BLOB;
  l_binds   rad_pdf_types.t_bind_array;
  l_opts    rad_pdf_types.t_template_options;
  l_cols    rad_pdf_types.t_columns;
  l_col     rad_pdf_types.t_column_def;
  -- Payload: embedded single-quote breaks naive string concatenation.
  -- Leading prefix avoids any accidental match against real DNAME values.
  c_payload CONSTANT VARCHAR2(100) := 'QL_INJ_TEST' || CHR(39) || '--';
  l_ok      BOOLEAN := FALSE;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 36: SQL injection via <table query> is blocked');

  -- Register a minimal column set for DNAME (VARCHAR2 column)
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(1);
  l_col.label := 'DEPT NAME'; l_col.width := 80;
  l_col.data_fmt.font_name := 'Helvetica'; l_col.data_fmt.font_size := 9;
  l_col.header_fmt         := l_col.data_fmt;
  l_cols(1)                := l_col;
  rad_pdf_template.register_columns('INJ_TEST', l_cols);

  -- Bind value contains SQL injection payload (raw single-quote)
  l_binds(1).key   := 'FILTER_VAL';
  l_binds(1).value := c_payload;

  l_opts.allow_queries := TRUE;

  l_doc := rad_pdf.new_document;
  BEGIN
    -- FILTER_VAL is shielded before bind substitution: the payload is
    -- injected as a SQL string literal, not as raw SQL text.
    -- The WHERE clause becomes:
    --   WHERE dname = 'QL_INJ_TEST''--'
    -- which is valid SQL and returns zero rows (no such department).
    rad_pdf_styles.load_defaults;
    rad_pdf_template.render(l_doc,
      '<table columns="INJ_TEST"'
      || ' query="SELECT dname FROM dept WHERE dname = '
      || '#' || 'FILTER_VAL' || '#'
      || ' ORDER BY dname" allow_query="true"/>',
      l_binds, l_opts);
    l_pdf := rad_pdf.finalize(l_doc);
    l_ok := l_pdf IS NOT NULL AND DBMS_LOB.GETLENGTH(l_pdf) > 0;
    DBMS_LOB.FREETEMPORARY(l_pdf);
  EXCEPTION
    WHEN OTHERS THEN
      BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
      DBMS_OUTPUT.PUT_LINE('  FAIL  (unexpected exception: ' || SQLERRM || ')');
      RETURN;
  END;

  rad_pdf_template.drop_columns('INJ_TEST');

  IF l_ok THEN
    DBMS_OUTPUT.PUT_LINE('  PASS  (SQL injection payload safely quoted; query executed without error)');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  FAIL  (unexpected empty PDF)');
  END IF;
END;
/

-- ===========================================================================
-- Test 37: <if eq="..."> and <if ne="..."> comparison attributes (v1.6.0)
-- ===========================================================================
DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_binds rad_pdf_types.t_bind_array;

  FUNCTION has_text(p_pdf BLOB, p_txt VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN DBMS_LOB.INSTR(p_pdf, UTL_RAW.CAST_TO_RAW(p_txt)) > 0;
  END;

  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 37: <if eq/ne> comparison attributes');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_binds(1).key := 'STATUS'; l_binds(1).value := 'ACTIVE';
  rad_pdf_template.render(l_doc,
    '<if bind="STATUS" eq="active"><p>EQMATCH</p></if>'
 || '<if bind="STATUS" eq="CLOSED"><p>EQNOMATCH</p></if>'
 || '<if bind="STATUS" ne="CLOSED"><p>NEMATCH</p></if>'
 || '<if bind="STATUS" ne="active"><p>NENOMATCH</p></if>'
 || '<if bind="MISSING" ne="X"><p>NEABSENT</p></if>'
 || '<if bind="MISSING" eq="X"><p>EQABSENT</p></if>'
 || '<if bind="STATUS"><p>PLAINOLD</p></if>',
    l_binds);
  l_pdf := rad_pdf.finalize(l_doc);
  -- text is written uncompressed into the content stream: searchable
  assert(has_text(l_pdf, 'EQMATCH'),       'eq match block missing');
  assert(NOT has_text(l_pdf, 'EQNOMATCH'), 'eq no-match block rendered');
  assert(has_text(l_pdf, 'NEMATCH'),       'ne match block missing');
  assert(NOT has_text(l_pdf, 'NENOMATCH'), 'ne no-match block rendered');
  assert(has_text(l_pdf, 'NEABSENT'),      'ne on absent bind should be TRUE');
  assert(NOT has_text(l_pdf, 'EQABSENT'),  'eq on absent bind should be FALSE');
  assert(has_text(l_pdf, 'PLAINOLD'),      'plain <if bind> regression');
  DBMS_LOB.FREETEMPORARY(l_pdf);

  -- eq + ne on the same tag raises c_err_template
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf_template.render(l_doc,
      '<if bind="A" eq="1" ne="2"><p>x</p></if>', l_binds);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: eq+ne accepted');
  EXCEPTION WHEN OTHERS THEN
    assert(SQLCODE = rad_pdf_types.c_err_template,
           'expected -20810 for eq+ne, got ' || SQLCODE);
  END;
  rad_pdf.close_document(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 38: <qrcode> tag (v1.7.0) - flow placement, binds, validation
-- ===========================================================================
DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_binds rad_pdf_types.t_bind_array;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 38: <qrcode> tag');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_binds(1).key := 'INV'; l_binds(1).value := '2026-0042';
  rad_pdf_template.render(l_doc,
    '<h1>Fattura #INV#</h1>'
 || '<qrcode value="https://pay.example.com/inv/#INV#" size="30mm" align="C"/>'
 || '<p>Flow continues below.</p>',
    l_binds);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 2000, 'BLOB too small');
  DBMS_LOB.FREETEMPORARY(l_pdf);

  -- missing value attribute
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf_template.render(l_doc, '<qrcode size="30mm"/>', l_binds);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: missing value accepted');
  EXCEPTION WHEN OTHERS THEN
    assert(SQLCODE = -20817, 'expected -20817, got ' || SQLCODE);
  END;
  -- invalid align
  BEGIN
    rad_pdf_template.render(l_doc, '<qrcode value="X" align="Z"/>', l_binds);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: bad align accepted');
  EXCEPTION WHEN OTHERS THEN
    assert(SQLCODE = -20817, 'expected -20817 for align, got ' || SQLCODE);
  END;
  rad_pdf.close_document(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

PROMPT
PROMPT ================================================================
PROMPT  Phase 10 template engine tests complete.
PROMPT ================================================================
