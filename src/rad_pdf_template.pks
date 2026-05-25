CREATE OR REPLACE PACKAGE rad_pdf_template AUTHID CURRENT_USER IS
/*
  rad_pdf_template - lightweight template engine for RAD_PDF.
  Oracle 19c+. Phase 9. AUTHID CURRENT_USER.

  Parses a CLOB or VARCHAR2 containing XML-like block/inline tags and
  #PLACEHOLDER# tokens, then renders the document by calling the rad_pdf
  layout engine.

  Supported block tags:
    <p [style="..."]>...</p>
    <h1>...</h1>  ..  <h6>...</h6>
    <ul [style="..."]><li>...</li></ul>          unordered list (bullet)
    <ol [style="..."]><li>...</li></ol>          ordered list (numbered)
    <spacer [height="20pt"]/>
    <hr [color="RRGGBB"] [width="N"]/>
    <img id="N" [width="Xmm"] [height="Ymm"]/>
    <table columns="NAME" query="SELECT ..."
           [row_height="Xpt"] [max_rows="N"]
           [header_bg="RRGGBB"] [alt_bg="RRGGBB"] [border_color="RRGGBB"]
           allow_query="true"/>
    <pagebreak/>
    Block tag names are case-insensitive (<P>, <H1>, <Ul> all work).

  Supported inline tags (inside <p>, <li>, and <h1>-<h6>):
    <b>...</b>                   bold run
    <i>...</i>                   italic run
    <br/>                        forced line break within the paragraph
    <color rgb="RRGGBB">...</color>
                                 custom ink colour (6-char hex, case-insensitive)
                                 Unlimited nesting depth (LIFO stack).
    <font size="Xpt">...</font>  custom font size (any unit accepted by
                                 rad_pdf_units).  Unlimited nesting depth.
    Inline tag names are case-insensitive (<B>, <Color>, <FONT> all work).

  Conditional blocks (evaluated BEFORE bind substitution):
    <if bind="KEY">...</if>
      Rendered only when the bind value for KEY is non-NULL and non-empty.
      Suppressed blocks are removed before apply_binds runs, so tokens
      inside a FALSE block never trigger NULL bind errors.
      NOTE: <if> / </if> are case-insensitive; <IF> / </IF> are
      automatically normalised to lowercase before evaluation.
      Nested <if> blocks are not supported.

  Placeholder tokens substituted AFTER conditional evaluation:
    #KEY#   ->  bind value (auto-escaped unless raw=TRUE in t_bind_entry)
    ##      ->  literal #

  Bind value escaping:
    render() auto-escapes all bind values (& -> &amp;  < -> &lt;  > -> &gt;)
    before substitution.  User-supplied text is safe by default.
    Set raw=TRUE on a t_bind_entry only for values that are already
    entity-encoded or that intentionally contain template markup.

  DEPRECATED: escape_value()
    escape_value() pre-dates the auto-escaping feature.  Calling it and
    then passing the result with raw=FALSE (the default) double-encodes:
      &  ->  &amp;  ->  &amp;amp;
    Migrate by removing the escape_value() call and keeping raw=FALSE.

  Multiple render() calls on the same document handle are additive: each
  call appends its flowables after the previous ones.  Use this pattern
  to build multi-section documents (header + body + footer) from separate
  templates without creating multiple documents.

  Quick start:
    DECLARE
      l_doc    rad_pdf_types.t_doc_handle;
      l_binds  rad_pdf_types.t_bind_array;
      l_pdf    BLOB;
    BEGIN
      rad_pdf_styles.load_defaults;
      l_doc          := rad_pdf.new_document;
      l_binds(1).key := 'CUSTOMER'; l_binds(1).value := 'Acme Corp';
      rad_pdf_template.render(l_doc, '<h1>Hello #CUSTOMER#</h1><p>Body.</p>', l_binds);
      l_pdf := rad_pdf.finalize(l_doc);
      ...
    END;

  Error codes (c_err_template = -20810):
    -20810  unclosed tag / unclosed <if> / malformed template
    -20811  unknown block tag (when strict_tags = TRUE)
    -20812  (reserved)
    -20813  <table> missing required attribute (columns or query)
    -20814  <table> column set not registered
    -20815  <table> query execution blocked (tag or options flag missing;
            error message indicates which one)
    -20816  <img> missing required "id" attribute
    -20817  invalid attribute value (e.g. non-numeric height)
*/

-- ---------------------------------------------------------------------------
-- Column set registry (session-scoped)
-- Register a named t_columns set so <table columns="name"> can reference it.
-- The registry is session-scoped: it survives close_doc but is lost at
-- session end (or DB restart).  In APEX, register in an Application Process
-- that runs On New Session so every pooled connection gets the definition.
-- ---------------------------------------------------------------------------
  PROCEDURE register_columns(
    p_name    IN VARCHAR2,
    p_columns IN rad_pdf_types.t_columns);

  PROCEDURE drop_columns(p_name IN VARCHAR2);
  PROCEDURE clear_columns;

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

  -- Entity-encode a value for use in a bind array.
  -- DEPRECATED: render() auto-escapes bind values by default (raw=FALSE).
  -- Calling escape_value() and then keeping raw=FALSE causes double-encoding.
  -- Remove calls to escape_value() and rely on the automatic escaping.
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
