CREATE OR REPLACE PACKAGE rad_pdf_template AUTHID CURRENT_USER IS
/*
  rad_pdf_template - lightweight template engine for RAD_PDF.
  Oracle 19c+. Phase 9. AUTHID CURRENT_USER.

  Parses a CLOB or VARCHAR2 containing XML-like block/inline tags and
  #PLACEHOLDER# tokens, then renders the document by calling the rad_pdf
  layout engine.

  Supported block tags : <p>, <h1>-<h6>, <spacer>, <hr>, <table>, <img>,
                         <pagebreak>
  Supported inline tags: <b>, <i>, <br/>  (inside <p> only)
  Placeholder syntax   : #KEY#  (case-insensitive; ## = literal #)

  Quick start:
    DECLARE
      l_doc    rad_pdf_types.t_doc_handle;
      l_binds  rad_pdf_types.t_bind_array;
      l_opts   rad_pdf_types.t_template_options;
      l_pdf    BLOB;
    BEGIN
      rad_pdf_styles.load_defaults;
      l_doc          := rad_pdf.new_document;
      l_binds(1).key := 'CUSTOMER'; l_binds(1).value := 'Acme Corp';
      rad_pdf_template.render(l_doc, '<h1>Hello #CUSTOMER#</h1><p>Body.</p>', l_binds);
      l_pdf := rad_pdf.finalize(l_doc);
      ...
    END;

  v1 limitations:
    - Inline <b>/<i> inside <p> produce separate block-level flowables
      (each run on its own line); true mid-line style switching is not
      supported in v1.
    - Templates with bind values must be <= 32767 characters.
    - No conditional or loop constructs.
    - <table> requires double opt-in (see allow_queries / allow_query).

  Error codes (c_err_template = -20810):
    -20810  unclosed tag or template > 32767 chars with binds
    -20811  unknown block tag (when strict_tags = TRUE)
    -20812  inline tag outside <p>
    -20813  <table> missing required attribute
    -20814  <table> column set not registered
    -20815  <table> query execution not enabled
    -20816  <img> missing required "id" attribute
    -20817  invalid attribute value (e.g. non-numeric height)
*/

-- ---------------------------------------------------------------------------
-- Column set registry (session-scoped)
-- Register a named t_columns set so <table columns="name"> can reference it.
-- ---------------------------------------------------------------------------
  PROCEDURE register_columns(
    p_name    IN VARCHAR2,
    p_columns IN rad_pdf_types.t_columns);

  PROCEDURE drop_columns(p_name IN VARCHAR2);
  PROCEDURE clear_columns;

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

  -- Entity-encode a value before placing it in a bind array.
  -- Replaces & -> &amp;  < -> &lt;  > -> &gt;
  FUNCTION escape_value(p_value IN VARCHAR2) RETURN VARCHAR2;

-- ---------------------------------------------------------------------------
-- Render - CLOB overload (recommended for templates > 32767 bytes)
-- ---------------------------------------------------------------------------
  PROCEDURE render(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_clob    IN CLOB,
    p_binds   IN rad_pdf_types.t_bind_array,
    p_options IN rad_pdf_types.t_template_options DEFAULT NULL);

-- ---------------------------------------------------------------------------
-- Render - VARCHAR2 overload (convenience for short templates)
-- ---------------------------------------------------------------------------
  PROCEDURE render(
    p_doc      IN rad_pdf_types.t_doc_handle,
    p_template IN VARCHAR2,
    p_binds    IN rad_pdf_types.t_bind_array,
    p_options  IN rad_pdf_types.t_template_options DEFAULT NULL);

-- ---------------------------------------------------------------------------
-- Render - no-bind overloads (template has no #PLACEHOLDER# tokens)
-- ---------------------------------------------------------------------------
  PROCEDURE render(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_clob    IN CLOB,
    p_options IN rad_pdf_types.t_template_options DEFAULT NULL);

  PROCEDURE render(
    p_doc      IN rad_pdf_types.t_doc_handle,
    p_template IN VARCHAR2,
    p_options  IN rad_pdf_types.t_template_options DEFAULT NULL);

END rad_pdf_template;
/
