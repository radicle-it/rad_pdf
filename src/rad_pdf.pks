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
-- PDF/A conformance (v1.7.0).
--
-- set_conformance(p_doc, 'PDF/A-2B') switches the document to PDF/A-2b
-- mode.  Call it right after new_document, before adding content.
-- At finalize the document gains: XMP metadata (synchronised with the
-- Info dictionary), an sRGB OutputIntent, and a file /ID; every font used
-- must be EMBEDDED (load TrueType fonts with p_embed => TRUE — the
-- standard 14 PDF fonts raise c_err_font in this mode).
-- The watermark transparency is allowed (PDF/A-2; not PDF/A-1).
-- Validate the output with veraPDF (https://verapdf.org).
-- ---------------------------------------------------------------------------
  PROCEDURE set_conformance(p_doc   IN rad_pdf_types.t_doc_handle,
                            p_level IN VARCHAR2);

-- ---------------------------------------------------------------------------
-- Content — layout engine (delegates to rad_pdf_layout)
-- ---------------------------------------------------------------------------

  PROCEDURE add    (p_doc   IN rad_pdf_types.t_doc_handle,
                    p_flow  IN rad_pdf_types.t_flowable);

  PROCEDURE write  (p_doc   IN rad_pdf_types.t_doc_handle,
                    p_text  IN VARCHAR2,
                    p_style IN VARCHAR2 DEFAULT 'body');

  -- p_bookmark: also register a PDF outline (bookmark) entry for this
  -- heading at the level p_level — documents become navigable in the
  -- reader's sidebar with one parameter (v1.6.0).
  PROCEDURE heading(p_doc      IN rad_pdf_types.t_doc_handle,
                    p_text     IN VARCHAR2,
                    p_level    IN PLS_INTEGER DEFAULT 1,
                    p_bookmark IN BOOLEAN     DEFAULT FALSE);

-- ---------------------------------------------------------------------------
-- Bookmark / outline shortcut — delegates to rad_pdf_canvas.add_bookmark
-- (v1.6.0).  Registers an outline entry pointing at the current page;
-- p_level (1..6) nests the entry under the nearest previous lower level.
-- p_y NULL = current cursor position.
-- ---------------------------------------------------------------------------
  PROCEDURE add_bookmark(p_doc   IN rad_pdf_types.t_doc_handle,
                         p_title IN VARCHAR2,
                         p_level IN PLS_INTEGER DEFAULT 1,
                         p_y     IN NUMBER      DEFAULT NULL,
                         p_unit  IN rad_pdf_types.t_unit DEFAULT 'pt');

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

  PROCEDURE refcursor2table(p_doc     IN rad_pdf_types.t_doc_handle,
                            p_rc      IN OUT SYS_REFCURSOR,
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
-- QR code shortcut — delegates to rad_pdf_barcode.qrcode (v1.6.0).
-- Draws a QR code with lower-left corner at (p_x, p_y), p_size per side
-- (4-module quiet zone included).  See rad_pdf_barcode for details.
-- ---------------------------------------------------------------------------
  PROCEDURE qrcode(p_doc      IN rad_pdf_types.t_doc_handle,
                   p_value    IN VARCHAR2,
                   p_x        IN NUMBER,
                   p_y        IN NUMBER,
                   p_size     IN NUMBER,
                   p_ec_level IN VARCHAR2              DEFAULT 'M',
                   p_color    IN rad_pdf_types.t_rgb  DEFAULT '000000',
                   p_unit     IN rad_pdf_types.t_unit DEFAULT 'pt');

-- ---------------------------------------------------------------------------
-- 1D barcode shortcut — delegates to rad_pdf_barcode (v1.6.0).
-- p_type: 'CODE128' | 'CODE39' | 'EAN13' (case-insensitive).
-- The bars fill the p_width × p_height box (quiet zones included).
-- For EAN13 the standard fixes the proportions: the module width is derived
-- as p_width / 113 (use rad_pdf_barcode.ean13 directly to pass a module
-- width instead).  Unknown p_type raises c_err_barcode.
-- ---------------------------------------------------------------------------
  PROCEDURE barcode(p_doc       IN rad_pdf_types.t_doc_handle,
                    p_type      IN VARCHAR2,
                    p_value     IN VARCHAR2,
                    p_x         IN NUMBER,
                    p_y         IN NUMBER,
                    p_width     IN NUMBER,
                    p_height    IN NUMBER,
                    p_show_text IN BOOLEAN               DEFAULT TRUE,
                    p_color     IN rad_pdf_types.t_rgb  DEFAULT '000000',
                    p_unit      IN rad_pdf_types.t_unit DEFAULT 'pt');

-- ---------------------------------------------------------------------------
-- Chart shortcuts — delegate to rad_pdf_chart (v1.7.0).
-- Pure vector charts; see rad_pdf_chart for layout rules and validation.
-- ---------------------------------------------------------------------------
  PROCEDURE bar_chart(
    p_doc         IN rad_pdf_types.t_doc_handle,
    p_values      IN rad_pdf_types.t_number_list,
    p_x           IN NUMBER,
    p_y           IN NUMBER,
    p_width       IN NUMBER,
    p_height      IN NUMBER,
    p_labels      IN rad_pdf_types.t_text_list DEFAULT rad_pdf_chart.no_labels(),
    p_colors      IN rad_pdf_types.t_rgb_list  DEFAULT rad_pdf_chart.no_colors(),
    p_show_values IN BOOLEAN                   DEFAULT TRUE,
    p_title       IN VARCHAR2                  DEFAULT NULL,
    p_unit        IN rad_pdf_types.t_unit      DEFAULT 'pt');

  PROCEDURE line_chart(
    p_doc          IN rad_pdf_types.t_doc_handle,
    p_values       IN rad_pdf_types.t_number_list,
    p_x            IN NUMBER,
    p_y            IN NUMBER,
    p_width        IN NUMBER,
    p_height       IN NUMBER,
    p_labels       IN rad_pdf_types.t_text_list DEFAULT rad_pdf_chart.no_labels(),
    p_colors       IN rad_pdf_types.t_rgb_list  DEFAULT rad_pdf_chart.no_colors(),
    p_show_markers IN BOOLEAN                   DEFAULT TRUE,
    p_title        IN VARCHAR2                  DEFAULT NULL,
    p_unit         IN rad_pdf_types.t_unit      DEFAULT 'pt');

  PROCEDURE pie_chart(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_values  IN rad_pdf_types.t_number_list,
    p_cx      IN NUMBER,
    p_cy      IN NUMBER,
    p_radius  IN NUMBER,
    p_labels  IN rad_pdf_types.t_text_list DEFAULT rad_pdf_chart.no_labels(),
    p_colors  IN rad_pdf_types.t_rgb_list  DEFAULT rad_pdf_chart.no_colors(),
    p_legend  IN BOOLEAN                   DEFAULT TRUE,
    p_title   IN VARCHAR2                  DEFAULT NULL,
    p_unit    IN rad_pdf_types.t_unit      DEFAULT 'pt');

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

-- ---------------------------------------------------------------------------
-- Watermark (v1.4.0)
-- ---------------------------------------------------------------------------

  -- Register a text watermark drawn on every page at finalization.
  -- Replaces any previously registered watermark for p_doc.
  -- p_font_size is in points. p_angle is degrees counter-clockwise.
  -- p_layer: 'UNDER' (behind page content) or 'OVER' (in front).
  PROCEDURE set_watermark(
    p_doc       IN rad_pdf_types.t_doc_handle,
    p_text      IN VARCHAR2,
    p_font_name IN VARCHAR2              DEFAULT 'Helvetica',
    p_font_size IN NUMBER                DEFAULT 60,
    p_color     IN rad_pdf_types.t_rgb   DEFAULT 'C0C0C0',
    p_opacity   IN NUMBER                DEFAULT 0.3,
    p_angle     IN NUMBER                DEFAULT 45,
    p_layer     IN VARCHAR2              DEFAULT 'UNDER',
    p_pages     IN VARCHAR2 DEFAULT NULL);

  -- Register an image watermark drawn on every page at finalization.
  -- p_image_id must be registered for p_doc via rad_pdf_images.load_image.
  -- p_width_pct: [1, 100] percentage of page width; aspect ratio is preserved.
  PROCEDURE set_watermark_image(
    p_doc       IN rad_pdf_types.t_doc_handle,
    p_image_id  IN PLS_INTEGER,
    p_opacity   IN NUMBER   DEFAULT 0.3,
    p_width_pct IN NUMBER   DEFAULT 60,
    p_layer     IN VARCHAR2 DEFAULT 'UNDER',
    p_pages     IN VARCHAR2 DEFAULT NULL);

  -- Remove the watermark for p_doc. No-op if no watermark is set.
  PROCEDURE clear_watermark(p_doc IN rad_pdf_types.t_doc_handle);

  -- Set the line dash pattern for subsequent stroked paths.
  -- p_dash: dash length; p_gap: gap length (default = p_dash).
  -- Call with p_dash => 0 to restore solid lines.
  PROCEDURE set_line_dash(p_doc   IN rad_pdf_types.t_doc_handle,
                          p_dash  IN NUMBER,
                          p_gap   IN NUMBER  DEFAULT NULL,
                          p_phase IN NUMBER  DEFAULT 0,
                          p_unit  IN rad_pdf_types.t_unit DEFAULT 'pt');

  -- Persistent graphics-state setters (v1.5.1).
  -- set_draw_color / set_fill_color / set_line_width store values in document
  -- state; line, h_line, v_line use them when the per-call color / width is NULL.
  -- rect, polygon, path are per-call only (NULL = no paint).
  PROCEDURE set_draw_color(p_doc IN rad_pdf_types.t_doc_handle,
                           p_rgb IN rad_pdf_types.t_rgb DEFAULT '000000');
  PROCEDURE set_fill_color(p_doc IN rad_pdf_types.t_doc_handle,
                           p_rgb IN rad_pdf_types.t_rgb DEFAULT NULL);
  PROCEDURE set_line_width(p_doc   IN rad_pdf_types.t_doc_handle,
                           p_width IN NUMBER DEFAULT 0.5,
                           p_unit  IN rad_pdf_types.t_unit DEFAULT 'pt');

END rad_pdf;
/
