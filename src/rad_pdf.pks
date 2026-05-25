CREATE OR REPLACE PACKAGE rad_pdf AUTHID CURRENT_USER IS
/*
  rad_pdf — public facade for the RAD_PDF suite.
  Oracle 19c+. AUTHID CURRENT_USER.

  This is the only package application code needs to call directly, together with
  rad_pdf_styles (custom styles), rad_pdf_fonts.preload_ttf (TTF fonts), and
  rad_pdf_images.set_image_cache_limit / clear_image_cache (batch image tuning).

  Typical flow:
    l_doc := rad_pdf.new_document(p_info => ..., p_template => ...);
    rad_pdf.heading(l_doc, 'Report Title');
    rad_pdf.write(l_doc, 'Body paragraph...');
    rad_pdf_table.query2table(l_doc, 'SELECT ...', l_cols);
    l_pdf := rad_pdf.finalize(l_doc);   -- l_doc is closed; caller owns l_pdf BLOB.
    -- or --
    rad_pdf.save(l_doc, 'MY_DIR', 'report.rad_pdf');

  Canvas-only (no layout engine):
    l_doc := rad_pdf.new_document;
    rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 16);
    rad_pdf_canvas.write_text(l_doc, 'Hello', 72, 700);
    l_pdf := rad_pdf.finalize(l_doc);
*/

-- ---------------------------------------------------------------------------
-- Version
-- ---------------------------------------------------------------------------

  -- Return the RAD_PDF version string, e.g. '1.1.0'.
  FUNCTION version RETURN VARCHAR2;

-- ---------------------------------------------------------------------------
-- Document lifecycle
-- ---------------------------------------------------------------------------

  -- Create a new document. Initialises the serial layer, loads standard fonts,
  -- applies optional template and document metadata, and creates the first page.
  -- Returns a handle valid until finalize / save / close_document is called.
  FUNCTION new_document(
    p_info     IN rad_pdf_types.t_doc_info      DEFAULT NULL,
    p_template IN rad_pdf_types.t_page_template DEFAULT NULL)
    RETURN rad_pdf_types.t_doc_handle;

  -- Finalise the document, close the handle, and return the PDF as a BLOB.
  -- The caller owns the BLOB and must call DBMS_LOB.FREETEMPORARY when done.
  -- Raises an exception and calls close_document if finalisation fails.
  FUNCTION finalize(p_doc IN rad_pdf_types.t_doc_handle) RETURN BLOB;

  -- Finalise, write to an Oracle directory, and close the handle.
  -- p_filename must contain only filename characters (no / \ ..).
  PROCEDURE save(p_doc      IN rad_pdf_types.t_doc_handle,
                 p_dir      IN VARCHAR2,
                 p_filename IN VARCHAR2);

  -- Release the document without producing output (aborts in-progress document).
  PROCEDURE close_document(p_doc IN rad_pdf_types.t_doc_handle);

-- ---------------------------------------------------------------------------
-- Content — layout engine (delegates to rad_pdf_layout)
-- ---------------------------------------------------------------------------

  PROCEDURE add    (p_doc   IN rad_pdf_types.t_doc_handle,
                    p_flow  IN rad_pdf_types.t_flowable);

  PROCEDURE write  (p_doc   IN rad_pdf_types.t_doc_handle,
                    p_text  IN VARCHAR2,
                    p_style IN VARCHAR2 DEFAULT 'body');

  PROCEDURE heading(p_doc   IN rad_pdf_types.t_doc_handle,
                    p_text  IN VARCHAR2,
                    p_level IN PLS_INTEGER DEFAULT 1);

  PROCEDURE spacer (p_doc    IN rad_pdf_types.t_doc_handle,
                    p_height IN NUMBER DEFAULT 12);

  -- In layout mode (after any write/heading/add call): inserts a page-break
  -- flowable. In canvas-only mode: calls rad_pdf_canvas.new_page directly.
  PROCEDURE new_page(p_doc IN rad_pdf_types.t_doc_handle);

-- ---------------------------------------------------------------------------
-- Table shortcuts — delegates to rad_pdf_table
-- ---------------------------------------------------------------------------

  PROCEDURE query2table(p_doc     IN rad_pdf_types.t_doc_handle,
                        p_query   IN VARCHAR2,
                        p_columns IN rad_pdf_types.t_columns,
                        p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                        p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options());

  PROCEDURE query2table(p_doc     IN rad_pdf_types.t_doc_handle,
                        p_query   IN CLOB,
                        p_columns IN rad_pdf_types.t_columns,
                        p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                        p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options());

-- ---------------------------------------------------------------------------
-- Image shortcut — adds an image flowable via the layout engine
-- ---------------------------------------------------------------------------
  PROCEDURE image(p_doc      IN rad_pdf_types.t_doc_handle,
                  p_image_id IN PLS_INTEGER,
                  p_width    IN NUMBER DEFAULT NULL,
                  p_height   IN NUMBER DEFAULT NULL);

-- ---------------------------------------------------------------------------
-- Document state query
-- ---------------------------------------------------------------------------

  -- Return a numeric property of the current document state.
  -- Use the c_info_* constants from rad_pdf_types as p_info:
  --   c_info_page_nr      current page number (1-based)
  --   c_info_page_count   total pages finalised so far
  --   c_info_page_width / c_info_page_height   page size in pt
  --   c_info_margin_top / _bot / _left / _right margins in pt
  --   c_info_cursor_x / c_info_cursor_y        current canvas cursor in pt
  --   c_info_font_size                         active font size in pt
  FUNCTION get_info(p_doc  IN rad_pdf_types.t_doc_handle,
                    p_info IN PLS_INTEGER) RETURN NUMBER;

-- ---------------------------------------------------------------------------
-- Template engine shortcut — delegates to rad_pdf_template.render
-- ---------------------------------------------------------------------------

  -- Render a CLOB or VARCHAR2 template with optional bind substitutions.
  -- All four overloads mirror rad_pdf_template.render exactly.
  PROCEDURE render_template(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_clob    IN CLOB,
    p_binds   IN rad_pdf_types.t_bind_array,
    p_options IN rad_pdf_types.t_template_options DEFAULT NULL);

  PROCEDURE render_template(
    p_doc      IN rad_pdf_types.t_doc_handle,
    p_template IN VARCHAR2,
    p_binds    IN rad_pdf_types.t_bind_array,
    p_options  IN rad_pdf_types.t_template_options DEFAULT NULL);

  PROCEDURE render_template(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_clob    IN CLOB,
    p_options IN rad_pdf_types.t_template_options DEFAULT NULL);

  PROCEDURE render_template(
    p_doc      IN rad_pdf_types.t_doc_handle,
    p_template IN VARCHAR2,
    p_options  IN rad_pdf_types.t_template_options DEFAULT NULL);

-- ---------------------------------------------------------------------------
-- Page geometry
-- ---------------------------------------------------------------------------

  PROCEDURE set_page_format(p_doc  IN rad_pdf_types.t_doc_handle,
                            p_name IN VARCHAR2);

  PROCEDURE set_page_format(p_doc IN rad_pdf_types.t_doc_handle,
                            p_fmt IN rad_pdf_types.t_page_format);

  -- Swap page width and height to achieve the requested orientation.
  -- p_orientation: 'PORTRAIT' or 'LANDSCAPE' (case-insensitive).
  PROCEDURE set_page_orientation(p_doc         IN rad_pdf_types.t_doc_handle,
                                 p_orientation IN VARCHAR2);

  PROCEDURE set_margins(p_doc     IN rad_pdf_types.t_doc_handle,
                        p_margins IN rad_pdf_types.t_margins);

  -- Set individual margins in points; NULL keeps the current value.
  PROCEDURE set_margins(p_doc    IN rad_pdf_types.t_doc_handle,
                        p_top    IN NUMBER DEFAULT NULL,
                        p_bottom IN NUMBER DEFAULT NULL,
                        p_left   IN NUMBER DEFAULT NULL,
                        p_right  IN NUMBER DEFAULT NULL);

END rad_pdf;
/
