CREATE OR REPLACE PACKAGE rad_pdf_canvas AUTHID DEFINER IS
/*
  rad_pdf_canvas — drawing primitives for RAD_PDF.
  Oracle 19c+.  AUTHID DEFINER.  Per-document state.

  All public procedures accept p_doc as first parameter.

  Typical flow (canvas-only document):
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_fonts.load_standard_fonts;
    rad_pdf_canvas.new_page(l_doc);
    rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 18);
    rad_pdf_canvas.write_text(l_doc, 'Hello', 72, 700);
    ...
    rad_pdf_canvas.run_page_procs(l_doc, rad_pdf_serial.page_count(l_doc));
    l_font_res := rad_pdf_fonts.write_font_objects(l_doc);
    l_img_res  := rad_pdf_images.write_image_objects(l_doc);
    l_pages    := rad_pdf_canvas.write_page_objects(l_doc, l_font_res, l_img_res);

  Page-proc tokens (substituted in run_page_procs):
    #PAGE_NR#     — current page number (1-based)
    #PAGE_COUNT#  — total pages
    #DOC_HANDLE#  — numeric document handle value
*/

-- ---------------------------------------------------------------------------
-- Page lifecycle
-- ---------------------------------------------------------------------------
  PROCEDURE new_page (p_doc IN rad_pdf_types.t_doc_handle);
  PROCEDURE goto_page(p_doc IN rad_pdf_types.t_doc_handle,
                      p_page_nr IN PLS_INTEGER);

-- ---------------------------------------------------------------------------
-- Page geometry
-- ---------------------------------------------------------------------------
  PROCEDURE set_page_format(p_doc IN rad_pdf_types.t_doc_handle,
                            p_fmt IN rad_pdf_types.t_page_format);
  PROCEDURE set_margins    (p_doc    IN rad_pdf_types.t_doc_handle,
                            p_margins IN rad_pdf_types.t_margins);

-- ---------------------------------------------------------------------------
-- Font and colour
-- ---------------------------------------------------------------------------
  PROCEDURE set_font(p_doc    IN rad_pdf_types.t_doc_handle,
                     p_family IN VARCHAR2,
                     p_style  IN rad_pdf_types.t_font_style DEFAULT 'N',
                     p_size   IN NUMBER                 DEFAULT NULL);
  PROCEDURE set_font(p_doc      IN rad_pdf_types.t_doc_handle,
                     p_font_idx IN PLS_INTEGER,
                     p_size     IN NUMBER DEFAULT NULL);

  PROCEDURE set_color   (p_doc IN rad_pdf_types.t_doc_handle,
                         p_rgb IN rad_pdf_types.t_rgb DEFAULT '000000');
  PROCEDURE set_bk_color(p_doc IN rad_pdf_types.t_doc_handle,
                         p_rgb IN rad_pdf_types.t_rgb DEFAULT 'ffffff');

  -- Persistent graphics-state setters (v1.5.1).
  -- Apply to line, h_line, v_line when the per-call color / width is NULL.
  -- rect, polygon, path use per-call parameters only (NULL = no paint).
  PROCEDURE set_draw_color(p_doc IN rad_pdf_types.t_doc_handle,
                           p_rgb IN rad_pdf_types.t_rgb DEFAULT '000000');
  PROCEDURE set_fill_color(p_doc IN rad_pdf_types.t_doc_handle,
                           p_rgb IN rad_pdf_types.t_rgb DEFAULT NULL);
  PROCEDURE set_line_width(p_doc   IN rad_pdf_types.t_doc_handle,
                           p_width IN NUMBER DEFAULT 0.5,
                           p_unit  IN rad_pdf_types.t_unit DEFAULT 'pt');

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------
  PROCEDURE write_text(p_doc      IN rad_pdf_types.t_doc_handle,
                       p_text     IN VARCHAR2,
                       p_x        IN NUMBER,
                       p_y        IN NUMBER,
                       p_unit     IN rad_pdf_types.t_unit DEFAULT 'pt',
                       p_rotation IN NUMBER           DEFAULT NULL);

  -- p_align: 'L' left, 'C' centre, 'R' right, 'J' justified (last line is left).
  PROCEDURE write_wrapped(p_doc     IN rad_pdf_types.t_doc_handle,
                          p_text    IN VARCHAR2,
                          p_x       IN NUMBER              DEFAULT NULL,
                          p_y       IN NUMBER              DEFAULT NULL,
                          p_width   IN NUMBER              DEFAULT NULL,
                          p_align   IN rad_pdf_types.t_align_h DEFAULT 'L',
                          p_unit    IN rad_pdf_types.t_unit    DEFAULT 'pt',
                          p_leading IN NUMBER              DEFAULT NULL);

  FUNCTION text_width(p_doc  IN rad_pdf_types.t_doc_handle,
                      p_text IN VARCHAR2) RETURN NUMBER;

  FUNCTION measure_wrapped(p_doc     IN rad_pdf_types.t_doc_handle,
                           p_text    IN VARCHAR2,
                           p_width   IN NUMBER,
                           p_unit    IN rad_pdf_types.t_unit DEFAULT 'pt',
                           p_leading IN NUMBER          DEFAULT NULL)
    RETURN NUMBER;

-- ---------------------------------------------------------------------------
-- Graphics
-- ---------------------------------------------------------------------------
  -- p_color / p_width: pass NULL to use the persistent set_draw_color /
  -- set_line_width value (default is black / 0.5 pt when unset).
  PROCEDURE line(p_doc   IN rad_pdf_types.t_doc_handle,
                 p_x1    IN NUMBER,
                 p_y1    IN NUMBER,
                 p_x2    IN NUMBER,
                 p_y2    IN NUMBER,
                 p_color IN rad_pdf_types.t_rgb  DEFAULT NULL,
                 p_width IN NUMBER           DEFAULT NULL,
                 p_unit  IN rad_pdf_types.t_unit DEFAULT 'pt');

  PROCEDURE h_line(p_doc        IN rad_pdf_types.t_doc_handle,
                   p_x          IN NUMBER,
                   p_y          IN NUMBER,
                   p_width      IN NUMBER,
                   p_line_width IN NUMBER           DEFAULT NULL,
                   p_color      IN rad_pdf_types.t_rgb  DEFAULT NULL,
                   p_unit       IN rad_pdf_types.t_unit DEFAULT 'pt');

  PROCEDURE v_line(p_doc        IN rad_pdf_types.t_doc_handle,
                   p_x          IN NUMBER,
                   p_y          IN NUMBER,
                   p_height     IN NUMBER,
                   p_line_width IN NUMBER           DEFAULT NULL,
                   p_color      IN rad_pdf_types.t_rgb  DEFAULT NULL,
                   p_unit       IN rad_pdf_types.t_unit DEFAULT 'pt');

  PROCEDURE rect(p_doc        IN rad_pdf_types.t_doc_handle,
                 p_x          IN NUMBER,
                 p_y          IN NUMBER,
                 p_width      IN NUMBER,
                 p_height     IN NUMBER,
                 p_line_color IN rad_pdf_types.t_rgb  DEFAULT NULL,
                 p_fill_color IN rad_pdf_types.t_rgb  DEFAULT NULL,
                 p_line_width IN NUMBER           DEFAULT 0.5,
                 p_unit       IN rad_pdf_types.t_unit DEFAULT 'pt');

  PROCEDURE polygon(p_doc        IN rad_pdf_types.t_doc_handle,
                    p_xs         IN rad_pdf_types.t_number_list,
                    p_ys         IN rad_pdf_types.t_number_list,
                    p_line_color IN rad_pdf_types.t_rgb DEFAULT '000000',
                    p_fill_color IN rad_pdf_types.t_rgb DEFAULT NULL,
                    p_line_width IN NUMBER          DEFAULT 0.5);

  PROCEDURE path(p_doc        IN rad_pdf_types.t_doc_handle,
                 p_path       IN rad_pdf_types.t_path,
                 p_line_color IN rad_pdf_types.t_rgb DEFAULT '000000',
                 p_fill_color IN rad_pdf_types.t_rgb DEFAULT NULL,
                 p_line_width IN NUMBER          DEFAULT 0.5);

  -- Set the current dash pattern for subsequent stroked paths.
  -- p_dash: length of each dash (pt); p_gap: length of each gap (pt).
  -- Call with p_dash => 0 to restore solid lines.
  PROCEDURE set_line_dash(p_doc   IN rad_pdf_types.t_doc_handle,
                          p_dash  IN NUMBER,
                          p_gap   IN NUMBER  DEFAULT NULL,
                          p_phase IN NUMBER  DEFAULT 0,
                          p_unit  IN rad_pdf_types.t_unit DEFAULT 'pt');

-- ---------------------------------------------------------------------------
-- Images
-- ---------------------------------------------------------------------------
  PROCEDURE put_image(p_doc      IN rad_pdf_types.t_doc_handle,
                      p_image_id IN PLS_INTEGER,
                      p_x        IN NUMBER,
                      p_y        IN NUMBER,
                      p_width    IN NUMBER              DEFAULT NULL,
                      p_height   IN NUMBER              DEFAULT NULL,
                      p_align    IN rad_pdf_types.t_align_h DEFAULT 'L',
                      p_valign   IN rad_pdf_types.t_align_v DEFAULT 'T',
                      p_unit     IN rad_pdf_types.t_unit    DEFAULT 'pt');

-- ---------------------------------------------------------------------------
-- Page-procedure callbacks
-- Tokens substituted in run_page_procs: #PAGE_NR#, #PAGE_COUNT#, #DOC_HANDLE#
-- ---------------------------------------------------------------------------
  PROCEDURE add_page_proc(p_doc IN rad_pdf_types.t_doc_handle, p_src IN VARCHAR2);
  PROCEDURE add_page_proc(p_doc IN rad_pdf_types.t_doc_handle, p_src IN CLOB);

-- ---------------------------------------------------------------------------
-- State queries
-- ---------------------------------------------------------------------------
  FUNCTION get_x   (p_doc IN rad_pdf_types.t_doc_handle) RETURN NUMBER;
  FUNCTION get_y   (p_doc IN rad_pdf_types.t_doc_handle) RETURN NUMBER;
  FUNCTION get_info(p_doc  IN rad_pdf_types.t_doc_handle,
                    p_what IN PLS_INTEGER) RETURN NUMBER;

-- ---------------------------------------------------------------------------
-- Internal API (called by rad_pdf_layout and rad_pdf.finalize — not for application use)
-- ---------------------------------------------------------------------------

  -- Execute all page procs for each page, substituting tokens.
  -- p_total: final page count as returned by rad_pdf_serial.page_count.
  PROCEDURE run_page_procs(p_doc    IN rad_pdf_types.t_doc_handle,
                           p_total  IN PLS_INTEGER);

  -- Write page content streams, page dict objects, and Pages root to the doc.
  -- Must be called AFTER run_page_procs, write_font_objects, write_image_objects.
  -- Returns the object number of the PDF Pages root (passed to finish_doc).
  FUNCTION write_page_objects(p_doc      IN rad_pdf_types.t_doc_handle,
                               p_font_res IN VARCHAR2,
                               p_img_res  IN VARCHAR2) RETURN NUMBER;

  -- Release per-document state (CLOBs in page_prcs + g_canvas entry).
  -- Called by rad_pdf_ctx.close_doc in reverse-dependency order.
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle);

-- ---------------------------------------------------------------------------
-- Watermark (v1.4.0)
-- Set a text watermark drawn on every page at finalization.
-- Replaces any previously registered watermark for p_doc.
-- p_font_size is in points. p_angle is degrees counter-clockwise.
-- p_layer: 'UNDER' (behind page content) or 'OVER' (in front).
-- ---------------------------------------------------------------------------
  PROCEDURE set_watermark(
    p_doc       IN rad_pdf_types.t_doc_handle,
    p_text      IN VARCHAR2,
    p_font_name IN VARCHAR2                DEFAULT 'Helvetica',
    p_font_size IN NUMBER                  DEFAULT 60,
    p_color     IN rad_pdf_types.t_rgb     DEFAULT 'C0C0C0',
    p_opacity   IN NUMBER                  DEFAULT 0.3,
    p_angle     IN NUMBER                  DEFAULT 45,
    p_layer     IN VARCHAR2                DEFAULT 'UNDER');

-- Set an image watermark drawn on every page at finalization.
-- p_image_id must be registered for p_doc via rad_pdf_images.load_image.
-- p_width_pct: [1, 100] percentage of page width; aspect ratio is preserved.
  PROCEDURE set_watermark_image(
    p_doc       IN rad_pdf_types.t_doc_handle,
    p_image_id  IN PLS_INTEGER,
    p_opacity   IN NUMBER  DEFAULT 0.3,
    p_width_pct IN NUMBER  DEFAULT 60,
    p_layer     IN VARCHAR2 DEFAULT 'UNDER');

-- Remove the watermark for p_doc. No-op if no watermark is set.
  PROCEDURE clear_watermark(p_doc IN rad_pdf_types.t_doc_handle);

END rad_pdf_canvas;
/
