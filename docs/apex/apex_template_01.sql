-- apex_template_01.sql  —  Document structure
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   The basic building blocks of a template document:
--     <h1>...<h6>  heading levels
--     <p>          body paragraph
--     <spacer>     vertical gap
--     <hr>         horizontal rule
--   No binds, no data queries — just static structure.
--
-- APEX SETUP
--   Page process — Execute Server-side Code
--   Point: On Load - Before Header
--   No page items required.
--
-- EMP / DEPT USAGE
--   None (this example is purely structural).
-- ===========================================================================

DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;

  -- Reusable stream helper (copy this to a local package in production).
  PROCEDURE stream_pdf(p_blob IN BLOB, p_filename IN VARCHAR2) IS
  BEGIN
    OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
    HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(p_blob));
    HTP.P('Content-Disposition: attachment; filename="' || p_filename || '"');
    OWA_UTIL.HTTP_HEADER_CLOSE;
    WPG_DOCLOAD.DOWNLOAD_FILE(p_blob);
    APEX_APPLICATION.STOP_APEX_ENGINE;
  END stream_pdf;

BEGIN
  -- load_defaults registers h1..h6, body, caption styles.
  -- Call this in an On New Session Application Process instead,
  -- so it runs only once per database session, not per page load.
  rad_pdf_styles.load_defaults;

  l_doc := rad_pdf.new_document;

  -- -------------------------------------------------------------------------
  -- render() accepts a VARCHAR2 (up to 32767 chars) or a CLOB.
  -- The template is a flat string of XML-like tags.
  -- Content between block tags (anything that is not a tag) is ignored —
  -- use it freely for whitespace and newlines to keep the template readable.
  -- -------------------------------------------------------------------------
  rad_pdf_template.render(l_doc,
    -- Six heading levels — h1 is the largest, h6 the smallest
    '<h1>Heading Level 1 — Report Title</h1>'          ||
    '<h2>Heading Level 2 — Section</h2>'               ||
    '<h3>Heading Level 3 — Sub-section</h3>'           ||
    '<h4>Heading Level 4</h4>'                         ||
    '<h5>Heading Level 5</h5>'                         ||
    '<h6>Heading Level 6 (smallest)</h6>'              ||

    -- A named spacer inserts vertical blank space.
    -- Default height is 12 pt; any CSS-style unit is accepted.
    '<spacer height="20pt"/>'                          ||

    -- A horizontal rule — default colour 000000, default width 0.5 pt.
    -- color is a 6-char hex RGB value (no leading #).
    '<hr color="336699" width="1"/>'                   ||

    '<spacer height="8pt"/>'                           ||

    -- Paragraphs use the predefined "body" style (Helvetica N 10 pt).
    -- Text is word-wrapped to the printable width.
    '<p>This is a regular body paragraph.  Text is automatically word-wrapped '     ||
    'to the printable width of the page.  Use multiple &lt;p&gt; tags to '         ||
    'create separate paragraphs; each one starts on a new line with normal '       ||
    'paragraph spacing.</p>'                           ||

    '<p>This is the second paragraph.  Note that &amp;lt; and &amp;gt; '           ||
    'are entity references for the &lt; and &gt; characters inside paragraph '     ||
    'content.</p>'                                     ||

    '<spacer height="12pt"/>'                          ||
    '<hr/>'                                            ||
    '<spacer height="8pt"/>'                           ||

    -- The "caption" predefined style is smaller (Helvetica I 8 pt, grey).
    '<p style="caption">Caption text uses the predefined "caption" style: '        ||
    'Helvetica italic 8 pt.  Pass style="" on any &lt;p&gt; tag to use a '        ||
    'different named style.</p>');

  l_pdf := rad_pdf.finalize(l_doc);
  stream_pdf(l_pdf, 'structure.pdf');

EXCEPTION
  WHEN APEX_APPLICATION.E_STOP_APEX_ENGINE THEN RAISE;
  WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
