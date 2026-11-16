CREATE OR REPLACE PACKAGE BODY rad_pdf IS
/*
  rad_pdf body — Phase 8 of the RAD_PDF modular refactoring.
  Public facade: orchestrates all lower-level packages.

  finalize sequence:
    1. rad_pdf_layout.render  (layout mode) or rad_pdf_canvas.run_page_procs (canvas mode)
    2. rad_pdf_fonts.write_font_objects
    3. rad_pdf_images.write_image_objects
    4. rad_pdf_canvas.write_page_objects  → Pages root obj nr
    5. Catalog object
    6. Info object (with PDF date string)
    7. rad_pdf_serial.finish_doc  (xref + trailer)
    8. rad_pdf_serial.take_doc  → transfer BLOB ownership to caller
    (2-8 are rad_pdf_doc.assemble, the core; the Swiss QR-bill is drawn between 1 and 2)
    9. close_document: the flowable layer and the extensions, then rad_pdf_doc.close_doc
*/

-- ---------------------------------------------------------------------------
-- Version
-- ---------------------------------------------------------------------------
  FUNCTION version RETURN VARCHAR2 IS
  BEGIN
    RETURN rad_pdf_types.c_version;
  END version;

-- ---------------------------------------------------------------------------
-- PRIVATE: build PDF date string in D:YYYYMMDDHHmmSSZ format (UTC).
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
  FUNCTION new_document(
    p_info     IN rad_pdf_types.t_doc_info      DEFAULT NULL,
    p_template IN rad_pdf_types.t_page_template DEFAULT NULL,
    p_compress_pages IN BOOLEAN DEFAULT TRUE)
    RETURN rad_pdf_types.t_doc_handle IS
    l_doc  rad_pdf_types.t_doc_handle;
  BEGIN
    l_doc := rad_pdf_doc.open_doc(p_info, p_compress_pages);
    -- Apply template if any meaningful field is set
    IF p_template.page_format_name IS NOT NULL OR
       p_template.page_width       IS NOT NULL OR
       p_template.page_height      IS NOT NULL OR
       p_template.margin_top       IS NOT NULL OR
       p_template.margin_bottom    IS NOT NULL OR
       p_template.margin_left      IS NOT NULL OR
       p_template.margin_right     IS NOT NULL OR
       p_template.header_proc      IS NOT NULL OR
       p_template.footer_proc      IS NOT NULL OR
       NVL(p_template.n_columns,1) != 1 THEN
      rad_pdf_layout.set_template(l_doc, p_template);
    END IF;
    -- Create the first page
    rad_pdf_canvas.new_page(l_doc);
    RETURN l_doc;
  EXCEPTION
    WHEN OTHERS THEN
      -- the initialization error wins: a cleanup error must not replace it
      BEGIN close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
      RAISE;
  END new_document;

-- ---------------------------------------------------------------------------
  PROCEDURE set_conformance(p_doc   IN rad_pdf_types.t_doc_handle,
                            p_level IN VARCHAR2) IS
  BEGIN
    rad_pdf_ctx.set_conformance(p_doc, p_level);
  END set_conformance;

-- ---------------------------------------------------------------------------
  PROCEDURE render_pages(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    -- Layout also applies page templates for canvas-only documents.
    rad_pdf_layout.render(p_doc);
    -- the Swiss QR-bill draws itself on the last page, after the render (rad_pdf_layout knows no extension)
    IF rad_pdf_swiss.attached(p_doc) THEN
      rad_pdf_canvas.goto_page(p_doc, rad_pdf_serial.page_count(p_doc) - 1);
      rad_pdf_swiss.draw_attached(p_doc);
    END IF;
  END render_pages;

  FUNCTION finalize(p_doc IN rad_pdf_types.t_doc_handle) RETURN BLOB IS
    l_result BLOB;
  BEGIN
    render_pages(p_doc);
    l_result := rad_pdf_doc.assemble(p_doc);
    close_document(p_doc);
    RETURN l_result;
  EXCEPTION
    WHEN OTHERS THEN
      IF DBMS_LOB.ISTEMPORARY(l_result)=1 THEN DBMS_LOB.FREETEMPORARY(l_result); END IF;
      BEGIN close_document(p_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
      RAISE;
  END finalize;

-- ---------------------------------------------------------------------------
  PROCEDURE save(p_doc      IN rad_pdf_types.t_doc_handle,
                 p_dir      IN VARCHAR2,
                 p_filename IN VARCHAR2) IS
    l_blob   BLOB;
    l_file   UTL_FILE.FILE_TYPE;
    l_buf    RAW(32767);
    l_chunk  CONSTANT PLS_INTEGER := 32767;
    l_pos    NUMBER := 1;
    l_len    NUMBER;
    l_piece  PLS_INTEGER;
  BEGIN
    IF INSTR(p_filename, '/')  > 0 OR
       INSTR(p_filename, '\')  > 0 OR
       INSTR(p_filename, '..') > 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf.save: filename must not contain path separators or ".."', TRUE);
    END IF;
    l_blob := finalize(p_doc);   -- p_doc is closed by finalize
    l_len  := DBMS_LOB.GETLENGTH(l_blob);
    l_file := UTL_FILE.FOPEN(p_dir, p_filename, 'WB', 32767);
    WHILE l_pos <= l_len LOOP
      l_piece := LEAST(l_chunk, l_len - l_pos + 1);
      l_buf   := DBMS_LOB.SUBSTR(l_blob, l_piece, l_pos);
      UTL_FILE.PUT_RAW(l_file, l_buf);
      l_pos := l_pos + l_piece;
    END LOOP;
    UTL_FILE.FCLOSE(l_file);
    DBMS_LOB.FREETEMPORARY(l_blob);
  EXCEPTION
    WHEN OTHERS THEN
      IF UTL_FILE.IS_OPEN(l_file) THEN UTL_FILE.FCLOSE(l_file); END IF;
      IF l_blob IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_blob); END IF;
      RAISE;
  END save;

-- ---------------------------------------------------------------------------
  PROCEDURE close_document(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_state rad_pdf_doc.t_close;
    -- the closers of the flowable layer and of the extensions, the highest level first; then the core
    -- (rad_pdf_doc.close_doc), which raises the first failure of both levels
    PROCEDURE run(p_package IN VARCHAR2) IS
    BEGIN
      rad_pdf_doc.inject(p_package);
      CASE p_package
        WHEN 'rad_pdf_template' THEN rad_pdf_template.close_doc(p_doc);
        WHEN 'rad_pdf_layout'   THEN rad_pdf_layout.close_doc(p_doc);
        WHEN 'rad_pdf_flow'     THEN rad_pdf_flow.close_doc(p_doc);
        WHEN 'rad_pdf_table'    THEN rad_pdf_table.close_doc(p_doc);
        WHEN 'rad_pdf_swiss'    THEN rad_pdf_swiss.close_doc(p_doc);
      END CASE;
    EXCEPTION
      WHEN OTHERS THEN rad_pdf_doc.note(l_state, p_package);
    END run;
  BEGIN
    IF p_doc IS NULL THEN RETURN; END IF;
    IF rad_pdf_ctx.is_valid(p_doc) THEN
      run('rad_pdf_template');
      run('rad_pdf_layout');
      run('rad_pdf_flow');
      run('rad_pdf_table');
      run('rad_pdf_swiss');
    END IF;
    rad_pdf_doc.close_doc(p_doc, l_state);
  END close_document;

-- ---------------------------------------------------------------------------
  PROCEDURE add(p_doc IN rad_pdf_types.t_doc_handle, p_flow IN rad_pdf_types.t_flowable) IS
  BEGIN
    rad_pdf_layout.add(p_doc, p_flow);
  END add;

-- ---------------------------------------------------------------------------
  PROCEDURE write(p_doc   IN rad_pdf_types.t_doc_handle,
                  p_text  IN VARCHAR2,
                  p_style IN VARCHAR2 DEFAULT 'body') IS
  BEGIN
    rad_pdf_layout.add(p_doc, rad_pdf_layout.paragraph(p_text, NVL(p_style, 'body')));
  END write;

-- ---------------------------------------------------------------------------
  PROCEDURE heading(p_doc      IN rad_pdf_types.t_doc_handle,
                    p_text     IN VARCHAR2,
                    p_level    IN PLS_INTEGER DEFAULT 1,
                    p_bookmark IN BOOLEAN     DEFAULT FALSE) IS
  BEGIN
    rad_pdf_layout.add(p_doc,
      rad_pdf_layout.heading(p_text, NVL(p_level, 1), NVL(p_bookmark, FALSE)));
  END heading;

-- ---------------------------------------------------------------------------
  PROCEDURE add_bookmark(p_doc   IN rad_pdf_types.t_doc_handle,
                         p_title IN VARCHAR2,
                         p_level IN PLS_INTEGER DEFAULT 1,
                         p_y     IN NUMBER      DEFAULT NULL,
                         p_unit  IN rad_pdf_types.t_unit DEFAULT 'pt') IS
  BEGIN
    rad_pdf_canvas.add_bookmark(p_doc, p_title, p_level, p_y, p_unit);
  END add_bookmark;

-- ---------------------------------------------------------------------------
  -- the bill attached to the document, the room it needs asked to layout (it draws itself in finalize)
  PROCEDURE attach_swiss(p_doc IN rad_pdf_types.t_doc_handle, p_bill IN rad_pdf_swiss.t_bill,
                         p_options IN rad_pdf_swiss.t_options) IS
  BEGIN
    rad_pdf_swiss.attach(p_doc, p_bill, p_options);
    IF rad_pdf_swiss.placement(p_doc) = 'INTEGRATED' THEN
      rad_pdf_layout.reserve_bottom(p_doc, rad_pdf_units.to_pt(115, 'mm'));
    ELSE
      rad_pdf_layout.final_page(p_doc);
    END IF;
  END attach_swiss;

  PROCEDURE swiss_qr_bill(p_doc IN rad_pdf_types.t_doc_handle,
                          p_bill IN rad_pdf_swiss.t_bill,
                          p_options IN rad_pdf_swiss.t_options DEFAULT NULL) IS
  BEGIN
    attach_swiss(p_doc,p_bill,p_options);
  END;
  PROCEDURE swiss_qr_bill(p_doc IN rad_pdf_types.t_doc_handle,
                          p_json IN CLOB,
                          p_options IN rad_pdf_swiss.t_options DEFAULT NULL) IS
  BEGIN
    attach_swiss(p_doc,rad_pdf_swiss.from_json(p_json),p_options);
  END;

  PROCEDURE spacer(p_doc    IN rad_pdf_types.t_doc_handle,
                   p_height IN NUMBER DEFAULT 12) IS
  BEGIN
    rad_pdf_layout.add(p_doc, rad_pdf_layout.spacer(NVL(p_height, 12)));
  END spacer;

-- ---------------------------------------------------------------------------
  PROCEDURE new_page(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    IF rad_pdf_layout.has_flowables(p_doc) THEN
      rad_pdf_layout.add(p_doc, rad_pdf_layout.page_break);
    ELSE
      rad_pdf_canvas.new_page(p_doc);
    END IF;
  END new_page;

-- ---------------------------------------------------------------------------
  PROCEDURE query2table(p_doc     IN rad_pdf_types.t_doc_handle,
                        p_query   IN VARCHAR2,
                        p_columns IN rad_pdf_types.t_columns,
                        p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                        p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options()) IS
  BEGIN
    rad_pdf_table.query2table(p_doc, p_query, p_columns, p_colors, p_options);
  END query2table;

-- ---------------------------------------------------------------------------
  PROCEDURE query2table(p_doc     IN rad_pdf_types.t_doc_handle,
                        p_query   IN CLOB,
                        p_columns IN rad_pdf_types.t_columns,
                        p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                        p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options()) IS
  BEGIN
    rad_pdf_table.query2table(p_doc, p_query, p_columns, p_colors, p_options);
  END query2table;

-- ---------------------------------------------------------------------------
  PROCEDURE refcursor2table(p_doc     IN rad_pdf_types.t_doc_handle,
                            p_rc      IN OUT SYS_REFCURSOR,
                            p_columns IN rad_pdf_types.t_columns,
                            p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                            p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options()) IS
  BEGIN
    rad_pdf_table.refcursor2table(p_doc, p_rc, p_columns, p_colors, p_options);
  END refcursor2table;

-- ---------------------------------------------------------------------------
  PROCEDURE image(p_doc      IN rad_pdf_types.t_doc_handle,
                  p_image_id IN PLS_INTEGER,
                  p_width    IN NUMBER DEFAULT NULL,
                  p_height   IN NUMBER DEFAULT NULL) IS
  BEGIN
    rad_pdf_layout.add(p_doc, rad_pdf_layout.image(p_image_id, p_width, p_height));
  END image;

-- ---------------------------------------------------------------------------
  PROCEDURE qrcode(p_doc      IN rad_pdf_types.t_doc_handle,
                   p_value    IN VARCHAR2,
                   p_x        IN NUMBER,
                   p_y        IN NUMBER,
                   p_size     IN NUMBER,
                   p_ec_level IN VARCHAR2              DEFAULT 'M',
                   p_color    IN rad_pdf_types.t_rgb  DEFAULT '000000',
                   p_unit     IN rad_pdf_types.t_unit DEFAULT 'pt') IS
  BEGIN
    rad_pdf_barcode.qrcode(p_doc, p_value, p_x, p_y, p_size,
                           p_ec_level, p_color, p_unit);
  END qrcode;

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
                    p_unit      IN rad_pdf_types.t_unit DEFAULT 'pt') IS
  BEGIN
    CASE UPPER(REPLACE(REPLACE(p_type, '-'), ' '))
      WHEN 'CODE128' THEN
        rad_pdf_barcode.code128(p_doc, p_value, p_x, p_y, p_width, p_height,
                                p_show_text, p_color, p_unit);
      WHEN 'CODE39' THEN
        rad_pdf_barcode.code39(p_doc, p_value, p_x, p_y, p_width, p_height,
                               p_show_text, FALSE, p_color, p_unit);
      WHEN 'EAN13' THEN
        -- EAN-13 is 113 modules wide incl. quiet zones; derive the module.
        rad_pdf_barcode.ean13(p_doc, p_value, p_x, p_y, p_height,
                              p_module_w  => p_width / 113,
                              p_show_text => p_show_text,
                              p_unit      => p_unit);
      ELSE
        RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_barcode,
          'Unknown barcode type "' || p_type
          || '" — use CODE128, CODE39 or EAN13');
    END CASE;
  END barcode;

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
    p_unit        IN rad_pdf_types.t_unit      DEFAULT 'pt') IS
  BEGIN
    rad_pdf_chart.bar_chart(p_doc, p_values, p_x, p_y, p_width, p_height,
                            p_labels, p_colors, p_show_values, p_title, p_unit);
  END bar_chart;

-- ---------------------------------------------------------------------------
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
    p_unit         IN rad_pdf_types.t_unit      DEFAULT 'pt') IS
  BEGIN
    rad_pdf_chart.line_chart(p_doc, p_values, p_x, p_y, p_width, p_height,
                             p_labels, p_colors, p_show_markers, p_title, p_unit);
  END line_chart;

-- ---------------------------------------------------------------------------
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
    p_unit    IN rad_pdf_types.t_unit      DEFAULT 'pt') IS
  BEGIN
    rad_pdf_chart.pie_chart(p_doc, p_values, p_cx, p_cy, p_radius,
                            p_labels, p_colors, p_legend, p_title, p_unit);
  END pie_chart;

-- ---------------------------------------------------------------------------
  FUNCTION get_info(p_doc  IN rad_pdf_types.t_doc_handle,
                    p_info IN PLS_INTEGER) RETURN NUMBER IS
  BEGIN
    RETURN rad_pdf_canvas.get_info(p_doc, p_info);
  END get_info;

-- ---------------------------------------------------------------------------
  PROCEDURE set_page_format(p_doc IN rad_pdf_types.t_doc_handle, p_name IN VARCHAR2) IS
  BEGIN
    rad_pdf_canvas.set_page_format(p_doc, rad_pdf_units.page_format(p_name));
  END set_page_format;

-- ---------------------------------------------------------------------------
  PROCEDURE set_page_format(p_doc IN rad_pdf_types.t_doc_handle,
                            p_fmt IN rad_pdf_types.t_page_format) IS
  BEGIN
    rad_pdf_canvas.set_page_format(p_doc, p_fmt);
  END set_page_format;

-- ---------------------------------------------------------------------------
  PROCEDURE set_page_orientation(p_doc         IN rad_pdf_types.t_doc_handle,
                                 p_orientation IN VARCHAR2) IS
    l_pf  rad_pdf_types.t_page_format;
    l_tmp NUMBER;
  BEGIN
    l_pf.width  := rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_page_width);
    l_pf.height := rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_page_height);
    IF UPPER(p_orientation) = 'LANDSCAPE' AND l_pf.width < l_pf.height THEN
      l_tmp       := l_pf.width;
      l_pf.width  := l_pf.height;
      l_pf.height := l_tmp;
      rad_pdf_canvas.set_page_format(p_doc, l_pf);
    ELSIF UPPER(p_orientation) = 'PORTRAIT' AND l_pf.width > l_pf.height THEN
      l_tmp       := l_pf.width;
      l_pf.width  := l_pf.height;
      l_pf.height := l_tmp;
      rad_pdf_canvas.set_page_format(p_doc, l_pf);
    END IF;
  END set_page_orientation;

-- ---------------------------------------------------------------------------
  PROCEDURE set_margins(p_doc IN rad_pdf_types.t_doc_handle, p_margins IN rad_pdf_types.t_margins) IS
  BEGIN
    rad_pdf_canvas.set_margins(p_doc, p_margins);
  END set_margins;

-- ---------------------------------------------------------------------------
  PROCEDURE set_margins(p_doc    IN rad_pdf_types.t_doc_handle,
                        p_top    IN NUMBER DEFAULT NULL,
                        p_bottom IN NUMBER DEFAULT NULL,
                        p_left   IN NUMBER DEFAULT NULL,
                        p_right  IN NUMBER DEFAULT NULL) IS
    l_mar rad_pdf_types.t_margins;
  BEGIN
    l_mar.top    := NVL(p_top,    rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_top));
    l_mar.bottom := NVL(p_bottom, rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_bot));
    l_mar.left   := NVL(p_left,   rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_left));
    l_mar.right  := NVL(p_right,  rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_right));
    rad_pdf_canvas.set_margins(p_doc, l_mar);
  END set_margins;

-- ---------------------------------------------------------------------------
-- Template engine shortcuts (delegate to rad_pdf_template)
-- ---------------------------------------------------------------------------
  PROCEDURE render_template(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_clob    IN CLOB,
    p_binds   IN rad_pdf_types.t_bind_array,
    p_options IN rad_pdf_types.t_template_options DEFAULT NULL) IS
  BEGIN
    rad_pdf_template.render(p_doc, p_clob, p_binds, p_options);
  END render_template;

  PROCEDURE render_template(
    p_doc      IN rad_pdf_types.t_doc_handle,
    p_template IN VARCHAR2,
    p_binds    IN rad_pdf_types.t_bind_array,
    p_options  IN rad_pdf_types.t_template_options DEFAULT NULL) IS
  BEGIN
    rad_pdf_template.render(p_doc, p_template, p_binds, p_options);
  END render_template;

  PROCEDURE render_template(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_clob    IN CLOB,
    p_options IN rad_pdf_types.t_template_options DEFAULT NULL) IS
  BEGIN
    rad_pdf_template.render(p_doc, p_clob, p_options);
  END render_template;

  PROCEDURE render_template(
    p_doc      IN rad_pdf_types.t_doc_handle,
    p_template IN VARCHAR2,
    p_options  IN rad_pdf_types.t_template_options DEFAULT NULL) IS
  BEGIN
    rad_pdf_template.render(p_doc, p_template, p_options);
  END render_template;

-- ---------------------------------------------------------------------------
-- Watermark shortcuts (v1.4.0)
-- ---------------------------------------------------------------------------
  PROCEDURE set_watermark(
    p_doc       IN rad_pdf_types.t_doc_handle,
    p_text      IN VARCHAR2,
    p_font_name IN VARCHAR2              DEFAULT 'Helvetica',
    p_font_size IN NUMBER                DEFAULT 60,
    p_color     IN rad_pdf_types.t_rgb   DEFAULT 'C0C0C0',
    p_opacity   IN NUMBER                DEFAULT 0.3,
    p_angle     IN NUMBER                DEFAULT 45,
    p_layer     IN VARCHAR2              DEFAULT 'UNDER',
    p_pages     IN VARCHAR2              DEFAULT NULL) IS
  BEGIN
    rad_pdf_canvas.set_watermark(p_doc, p_text, p_font_name, p_font_size,
                                  p_color, p_opacity, p_angle, p_layer,
                                  p_pages);
  END set_watermark;

-- ---------------------------------------------------------------------------
  PROCEDURE set_watermark_image(
    p_doc       IN rad_pdf_types.t_doc_handle,
    p_image_id  IN PLS_INTEGER,
    p_opacity   IN NUMBER   DEFAULT 0.3,
    p_width_pct IN NUMBER   DEFAULT 60,
    p_layer     IN VARCHAR2 DEFAULT 'UNDER',
    p_pages     IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    rad_pdf_canvas.set_watermark_image(p_doc, p_image_id, p_opacity,
                                        p_width_pct, p_layer, p_pages);
  END set_watermark_image;

-- ---------------------------------------------------------------------------
  PROCEDURE clear_watermark(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    rad_pdf_canvas.clear_watermark(p_doc);
  END clear_watermark;

  PROCEDURE set_line_dash(p_doc   IN rad_pdf_types.t_doc_handle,
                          p_dash  IN NUMBER,
                          p_gap   IN NUMBER  DEFAULT NULL,
                          p_phase IN NUMBER  DEFAULT 0,
                          p_unit  IN rad_pdf_types.t_unit DEFAULT 'pt') IS
  BEGIN
    rad_pdf_canvas.set_line_dash(p_doc, p_dash, p_gap, p_phase, p_unit);
  END set_line_dash;

-- ---------------------------------------------------------------------------
  PROCEDURE set_draw_color(p_doc IN rad_pdf_types.t_doc_handle,
                           p_rgb IN rad_pdf_types.t_rgb DEFAULT '000000') IS
  BEGIN
    rad_pdf_canvas.set_draw_color(p_doc, p_rgb);
  END set_draw_color;

-- ---------------------------------------------------------------------------
  PROCEDURE set_fill_color(p_doc IN rad_pdf_types.t_doc_handle,
                           p_rgb IN rad_pdf_types.t_rgb DEFAULT NULL) IS
  BEGIN
    rad_pdf_canvas.set_fill_color(p_doc, p_rgb);
  END set_fill_color;

-- ---------------------------------------------------------------------------
  PROCEDURE set_line_width(p_doc   IN rad_pdf_types.t_doc_handle,
                           p_width IN NUMBER DEFAULT 0.5,
                           p_unit  IN rad_pdf_types.t_unit DEFAULT 'pt') IS
  BEGIN
    rad_pdf_canvas.set_line_width(p_doc, p_width, p_unit);
  END set_line_width;

END rad_pdf;
/
