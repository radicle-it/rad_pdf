CREATE OR REPLACE PACKAGE rad_pdf_table AUTHID CURRENT_USER IS
/*
  rad_pdf_table — table and label rendering for RAD_PDF.
  Oracle 19c+. AUTHID CURRENT_USER (executes queries with caller's privileges).

  table_flow / query2table build a t_table_def and register it with rad_pdf_layout;
  they return / add a t_flowable of type TABLE.

  measure_table and draw_table are called by rad_pdf_layout.render (not user code).
*/

-- ---------------------------------------------------------------------------
-- Flowable builders — return a t_flowable for rad_pdf_layout.add
-- ---------------------------------------------------------------------------
  FUNCTION table_flow(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_query   IN VARCHAR2,
    p_columns IN rad_pdf_types.t_columns,
    p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
    p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options())
    RETURN rad_pdf_types.t_flowable;

  FUNCTION table_flow(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_query   IN CLOB,
    p_columns IN rad_pdf_types.t_columns,
    p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
    p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options())
    RETURN rad_pdf_types.t_flowable;

  FUNCTION table_flow(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_rc      IN OUT SYS_REFCURSOR,
    p_columns IN rad_pdf_types.t_columns,
    p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
    p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options())
    RETURN rad_pdf_types.t_flowable;

-- ---------------------------------------------------------------------------
-- Procedural shortcuts — build flowable and add it to the document
-- ---------------------------------------------------------------------------
  PROCEDURE query2table(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_query   IN VARCHAR2,
    p_columns IN rad_pdf_types.t_columns,
    p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
    p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options());

  PROCEDURE query2table(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_query   IN CLOB,
    p_columns IN rad_pdf_types.t_columns,
    p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
    p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options());

  PROCEDURE refcursor2table(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_rc      IN OUT SYS_REFCURSOR,
    p_columns IN rad_pdf_types.t_columns,
    p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
    p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options());

-- ---------------------------------------------------------------------------
-- Label grid
-- ---------------------------------------------------------------------------
  PROCEDURE query2labels(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_query   IN VARCHAR2,
    p_columns IN rad_pdf_types.t_columns,
    p_label   IN rad_pdf_types.t_label_def     DEFAULT rad_pdf_units.default_label_def(),
    p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
    p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options());

  PROCEDURE query2labels(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_query   IN CLOB,
    p_columns IN rad_pdf_types.t_columns,
    p_label   IN rad_pdf_types.t_label_def     DEFAULT rad_pdf_units.default_label_def(),
    p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
    p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options());

  PROCEDURE refcursor2labels(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_rc      IN OUT SYS_REFCURSOR,
    p_columns IN rad_pdf_types.t_columns,
    p_label   IN rad_pdf_types.t_label_def     DEFAULT rad_pdf_units.default_label_def(),
    p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
    p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options());

-- ---------------------------------------------------------------------------
-- Internal API (called by rad_pdf_layout during render/measure pass)
-- ---------------------------------------------------------------------------

  -- Fetch data (unless streaming), cache it, return total height in pt.
  FUNCTION measure_table(
    p_doc       IN rad_pdf_types.t_doc_handle,
    p_table_ref IN PLS_INTEGER,
    p_width     IN NUMBER) RETURN NUMBER;

  -- Draw header + data rows using cached data. Handles row-level page breaks.
  PROCEDURE draw_table(
    p_doc       IN rad_pdf_types.t_doc_handle,
    p_table_ref IN PLS_INTEGER,
    p_x         IN NUMBER,
    p_y         IN NUMBER,
    p_width     IN NUMBER);

  -- Release per-document table cache. Called by rad_pdf_ctx.close_doc.
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle);

END rad_pdf_table;
/
