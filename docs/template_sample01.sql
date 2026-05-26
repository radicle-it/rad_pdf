-- =============================================================================
-- template_sample01.sql  -  Template engine: basic document structure
-- =============================================================================
--
-- WHAT THIS SHOWS
--   The minimum needed to use the template engine:
--     • rad_pdf_template.render(l_doc, template_string)  - no binds needed
--     • Block tags: <h1>–<h6>, <p>, <spacer/>, <hr/>, <pagebreak/>
--
--   The template engine is an alternative to the Canvas API.  Instead of
--   calling rad_pdf.heading() / rad_pdf.write() for each element, you
--   describe the document as a lightweight XML-like string.  The engine
--   parses it and calls the layout engine for you.
--
--   When to use the template engine vs the Canvas API:
--     Template engine  - document structure comes from a CLOB string, a table
--                        column, or is built dynamically from query results;
--                        content varies but structure is consistent.
--     Canvas API       - you need pixel-level control over position, or the
--                        document has complex interleaved drawing (images at
--                        exact coordinates, polygons, rotated text, etc.).
--
-- HOW TO RUN
--   Option A - SQL*Plus or SQL Developer (Script Output):
--     The script prints the file size to confirm it worked.
--
--   Option B - Save to a file via Oracle Directory:
--     Replace the finalize() call pattern with rad_pdf.save() as shown below.
--     Requires CREATE DIRECTORY + WRITE privilege:
--       CREATE OR REPLACE DIRECTORY PDF_OUT AS '/tmp/rad_pdf';
--       GRANT WRITE ON DIRECTORY PDF_OUT TO your_schema;
--
--   Option C - SQL Developer bind variable:
--     Uncomment ":rad_pdf := l_pdf" after running.
--     Right-click the BLOB result in Script Output → Save As.
--
-- PREREQUISITES
--   RAD_PDF packages installed in the current schema (run src/install.sql).
--   No external tables required; DUAL is sufficient.
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  -- Load the built-in text styles (h1–h6, body, caption, ...).
  -- Call once per session, not once per document.
  rad_pdf_styles.load_defaults;

  l_doc := rad_pdf.new_document;

  -- The template engine accepts a VARCHAR2 (≤ 32767 chars) or CLOB.
  -- Tag names are case-insensitive: <H1>, <h1>, <P>, <p> are all valid.
  rad_pdf_template.render(l_doc,

    -- Headings h1 through h6 use the built-in heading styles.
    '<h1>Document Title (h1)</h1>'                                              ||
    '<h2>Section One (h2)</h2>'                                                 ||
    '<h3>Sub-section 1.1 (h3)</h3>'                                             ||

    -- <p> renders a wrapped paragraph of body text.
    '<p>This paragraph uses the built-in ''body'' style: Helvetica 10 pt, '    ||
    'black.  Long text wraps automatically when it reaches the right margin.  ' ||
    'The layout engine handles page breaks too.</p>'                            ||

    -- <spacer height="Nunit"/> adds a vertical gap.  Units: pt, mm, cm.
    '<spacer height="12pt"/>'                                                   ||

    -- <hr color="RRGGBB" width="N"/> draws a horizontal rule.
    '<hr color="003366" width="1.5"/>'                                          ||
    '<spacer height="12pt"/>'                                                   ||

    '<h2>Section Two (h2)</h2>'                                                 ||
    '<p>Another paragraph after the rule.</p>'                                  ||
    '<spacer height="8pt"/>'                                                    ||

    -- h4, h5, h6 are progressively smaller sub-headings.
    '<h4>Sub-section 2.1 (h4)</h4>'                                            ||

    -- style="caption" selects the built-in caption style (italic 8 pt, grey).
    -- Any registered style name is accepted.
    '<p style="caption">A caption-styled paragraph.</p>'                        ||

    '<h5>Level 5 heading (h5)</h5>'                                             ||
    '<h6>Level 6 heading (h6)</h6>'                                             ||
    '<p>Content under the deepest heading level.</p>'                           ||

    -- <pagebreak/> forces the layout engine to start a new page.
    '<pagebreak/>'                                                              ||

    -- Content after <pagebreak/> begins on page 2.
    -- Entity references work inside template strings: &lt; &gt; &amp;
    '<h1>Page Two</h1>'                                                         ||
    '<p>This paragraph starts on page 2.  The &lt;pagebreak/&gt; tag above '   ||
    'forced the page break.</p>'                                                ||
    '<spacer height="8pt"/>'                                                    ||
    '<hr color="CCCCCC" width="0.5"/>'                                          ||
    '<spacer height="8pt"/>'                                                    ||
    '<p style="caption">End of document.</p>');

  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF generated - size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  -- :rad_pdf := l_pdf;   -- SQL Developer: right-click → Save As to download

  -- Option B: save to a directory instead of returning the BLOB.
  -- Replace the finalize() block above with:
  --   rad_pdf.save(l_doc, 'PDF_OUT', 'template_sample01.pdf');
  -- (No BLOB to free in this case.)

  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
