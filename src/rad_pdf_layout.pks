CREATE OR REPLACE PACKAGE rad_pdf_layout AUTHID DEFINER IS
/*
  rad_pdf_layout — layout engine for RAD_PDF.
  Oracle 19c+. AUTHID DEFINER. Per-document state.

  Compile order (circular body dependency with rad_pdf_table):
    rad_pdf_layout.pks → rad_pdf_table.pks → rad_pdf_layout.pkb → rad_pdf_table.pkb

  Typical flow:
    rad_pdf_layout.set_template(l_doc, l_tpl);
    rad_pdf_layout.add(l_doc, rad_pdf_layout.heading('My Report'));
    rad_pdf_layout.add(l_doc, rad_pdf_layout.paragraph('Body text...'));
    rad_pdf_table.query2table(l_doc, 'SELECT ...', l_cols);
    -- rad_pdf.finalize calls rad_pdf_layout.render internally
*/

-- ---------------------------------------------------------------------------
-- Template
-- ---------------------------------------------------------------------------
  PROCEDURE set_template(p_doc      IN rad_pdf_types.t_doc_handle,
                         p_template IN rad_pdf_types.t_page_template);

-- ---------------------------------------------------------------------------
-- Flowable list
-- ---------------------------------------------------------------------------
  PROCEDURE add(p_doc  IN rad_pdf_types.t_doc_handle,
                p_flow IN rad_pdf_types.t_flowable);

-- ---------------------------------------------------------------------------
-- Flowable constructors
-- ---------------------------------------------------------------------------
  FUNCTION paragraph(p_text  IN VARCHAR2,
                     p_style IN VARCHAR2 DEFAULT 'body') RETURN rad_pdf_types.t_flowable;
  FUNCTION paragraph(p_text  IN CLOB,
                     p_style IN VARCHAR2 DEFAULT 'body') RETURN rad_pdf_types.t_flowable;

  -- p_bookmark: register a PDF outline entry (level = p_level) when the
  -- heading is placed during the render pass (v1.6.0).
  FUNCTION heading  (p_text     IN VARCHAR2,
                     p_level    IN PLS_INTEGER DEFAULT 1,
                     p_bookmark IN BOOLEAN     DEFAULT FALSE)
                                                          RETURN rad_pdf_types.t_flowable;

  FUNCTION image    (p_image_id IN PLS_INTEGER,
                     p_width    IN NUMBER DEFAULT NULL,
                     p_height   IN NUMBER DEFAULT NULL)  RETURN rad_pdf_types.t_flowable;

  FUNCTION spacer   (p_height IN NUMBER)                 RETURN rad_pdf_types.t_flowable;

  FUNCTION h_rule   (p_color  IN rad_pdf_types.t_rgb DEFAULT '000000',
                     p_width  IN NUMBER           DEFAULT 0.5)     RETURN rad_pdf_types.t_flowable;

  FUNCTION page_break                                    RETURN rad_pdf_types.t_flowable;

  -- QR code flowable (v1.7.0): a p_size × p_size square placed in the flow
  -- at the current position; p_align positions it inside the frame (L/C/R).
  -- p_size in POINTS.  Rendered via rad_pdf_barcode at finalize.
  FUNCTION qrcode   (p_value IN VARCHAR2,
                     p_size  IN NUMBER,
                     p_ec    IN VARCHAR2                 DEFAULT 'M',
                     p_color IN rad_pdf_types.t_rgb      DEFAULT '000000',
                     p_align IN rad_pdf_types.t_align_h  DEFAULT 'L')
                                                          RETURN rad_pdf_types.t_flowable;

  -- paragraph_runs: a paragraph whose text may contain inline bold / italic /
  -- colour changes.  p_runs is the pre-parsed list of inline segments; each
  -- segment carries its pre-computed style_name (from derive_style) and an
  -- optional is_br flag for forced line-breaks.
  -- The flowable renders all runs on a single, word-wrapped paragraph —
  -- different from creating separate flowables for each run (the v1 behaviour).
  FUNCTION paragraph_runs(
    p_doc   IN rad_pdf_types.t_doc_handle,
    p_runs  IN rad_pdf_types.t_inline_run_list,
    p_style IN VARCHAR2 DEFAULT 'body'
  ) RETURN rad_pdf_types.t_flowable;

-- ---------------------------------------------------------------------------
-- Internal API (called by rad_pdf_table and rad_pdf — not for application use)
-- ---------------------------------------------------------------------------

  -- Register a table definition; returns the table_ref_id for the flowable.
  FUNCTION register_table(p_doc       IN rad_pdf_types.t_doc_handle,
                          p_table_def IN rad_pdf_types.t_table_def) RETURN PLS_INTEGER;

  -- Retrieve a registered table definition by ref id (called by rad_pdf_table).
  FUNCTION get_table_def(p_doc       IN rad_pdf_types.t_doc_handle,
                         p_table_ref IN PLS_INTEGER) RETURN rad_pdf_types.t_table_def;

  -- Execute measure pass + render pass + run_page_procs.
  -- Called once by rad_pdf.finalize; do not invoke directly.
  PROCEDURE render(p_doc IN rad_pdf_types.t_doc_handle);

  -- Query: TRUE if the document has any flowables registered.
  FUNCTION has_flowables(p_doc IN rad_pdf_types.t_doc_handle) RETURN BOOLEAN;

  -- Release per-document state (flowable CLOBs, table def CLOBs, g_layout entry).
  -- Called by rad_pdf_ctx.close_doc.
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle);

END rad_pdf_layout;
/
