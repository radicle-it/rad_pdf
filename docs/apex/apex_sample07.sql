-- apex_sample07.sql - Template engine example (Oracle APEX)
--
-- Demonstrates rad_pdf_template.render inside an APEX page process:
--   - Bind substitution from APEX session state (#KEY#)
--   - Block tags: <h1>, <h2>, <p>, <spacer>, <hr>
--   - Inline formatting: <b>, <i>, <br/>
--   - Optional <table> with registered column set
--
-- Prerequisites:
--   - RAD_PDF suite installed (all 9 phases).
--   - A page process of type "Execute Code" on the target APEX page.
--   - APEX page items P1_CUSTOMER_NAME, P1_ORDER_ID, P1_NOTES.
--   - The APEX application's parsing schema has EXECUTE privilege on rad_pdf,
--     rad_pdf_template, and rad_pdf_types.

DECLARE
  -- -------------------------------------------------------------------------
  -- Column definitions for the order lines table (registered once per session
  -- or in an APEX application initialization code block).
  -- -------------------------------------------------------------------------
  l_cols  rad_pdf_types.t_columns;

  -- -------------------------------------------------------------------------
  -- Template CLOB: structure and content of the document.
  -- Bind keys map to APEX page items (upper-cased, without the colon prefix).
  -- -------------------------------------------------------------------------
  l_tmpl  CLOB;

  -- -------------------------------------------------------------------------
  -- Bind array: populate from APEX session state.
  -- -------------------------------------------------------------------------
  l_binds rad_pdf_types.t_bind_array;

  -- -------------------------------------------------------------------------
  -- Options: enable queries for the <table> tag.
  -- -------------------------------------------------------------------------
  l_opts  rad_pdf_types.t_template_options;

  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;

  -- Helper: append a VARCHAR2 chunk to a CLOB.
  PROCEDURE wapp(p_clob IN OUT NOCOPY CLOB, p_str IN VARCHAR2) IS
  BEGIN
    IF p_str IS NOT NULL THEN
      DBMS_LOB.WRITEAPPEND(p_clob, LENGTH(p_str), p_str);
    END IF;
  END wapp;

BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Register the order lines column set (idempotent after first call).
  --    In a real application, move this to an Application Process that runs
  --    On New Session so it is registered only once per session.
  -- -------------------------------------------------------------------------
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(4);

  l_cols(1).label              := 'Line';
  l_cols(1).width              := 35;
  l_cols(1).header_fmt.align_h := 'C';
  l_cols(1).data_fmt.align_h   := 'C';

  l_cols(2).label              := 'Product';
  l_cols(2).width              := 170;

  l_cols(3).label              := 'Qty';
  l_cols(3).width              := 40;
  l_cols(3).header_fmt.align_h := 'C';
  l_cols(3).data_fmt.align_h   := 'R';

  l_cols(4).label              := 'Amount';
  l_cols(4).width              := 65;
  l_cols(4).header_fmt.align_h := 'R';
  l_cols(4).data_fmt.align_h   := 'R';
  l_cols(4).data_fmt.num_format := '999,990.00';

  rad_pdf_template.register_columns('ORDER_LINES', l_cols);

  -- -------------------------------------------------------------------------
  -- 2. Build the document template CLOB.
  -- -------------------------------------------------------------------------
  DBMS_LOB.CREATETEMPORARY(l_tmpl, TRUE);

  wapp(l_tmpl, '<h1>Order Confirmation</h1>');
  wapp(l_tmpl, '<spacer height="6pt"/>');
  wapp(l_tmpl, '<p>Order reference: <b>#ORDER_ID#</b></p>');
  wapp(l_tmpl, '<p>Customer: <b>#CUSTOMER_NAME#</b></p>');
  wapp(l_tmpl, '<spacer height="10pt"/>');
  wapp(l_tmpl, '<hr color="003366"/>');
  wapp(l_tmpl, '<spacer height="10pt"/>');

  wapp(l_tmpl, '<h2>Order Lines</h2>');
  wapp(l_tmpl, '<table columns="ORDER_LINES"');
  wapp(l_tmpl,        ' query="SELECT line_nr, product_name, quantity, unit_price * quantity');
  wapp(l_tmpl,                ' FROM order_lines');
  wapp(l_tmpl,               ' WHERE order_id = :order_id');
  wapp(l_tmpl,               ' ORDER BY line_nr"');
  wapp(l_tmpl,        ' allow_query="true"/>');

  wapp(l_tmpl, '<spacer height="12pt"/>');
  wapp(l_tmpl, '<h2>Notes</h2>');
  wapp(l_tmpl, '<p>#NOTES#</p>');

  -- -------------------------------------------------------------------------
  -- 3. Populate binds from APEX session state.
  --    Use escape_value for any user-supplied data to prevent tag injection.
  -- -------------------------------------------------------------------------
  l_binds(1).key   := 'ORDER_ID';
  l_binds(1).value := :P1_ORDER_ID;

  l_binds(2).key   := 'CUSTOMER_NAME';
  l_binds(2).value := rad_pdf_template.escape_value(:P1_CUSTOMER_NAME);

  l_binds(3).key   := 'NOTES';
  l_binds(3).value := rad_pdf_template.escape_value(
                        NVL(:P1_NOTES, 'No additional notes.'));

  -- -------------------------------------------------------------------------
  -- 4. Enable table query execution.
  -- -------------------------------------------------------------------------
  l_opts.allow_queries := TRUE;

  -- -------------------------------------------------------------------------
  -- 5. Render and stream the PDF to the browser.
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, l_tmpl, l_binds, l_opts);
  DBMS_LOB.FREETEMPORARY(l_tmpl);

  l_pdf := rad_pdf.finalize(l_doc);

  -- Stream to browser
  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="order_' ||
        :P1_ORDER_ID || '.pdf"');
  OWA_UTIL.HTTP_HEADER_CLOSE;
  WPG_DOCLOAD.DOWNLOAD_FILE(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  APEX_APPLICATION.STOP_APEX_ENGINE;

EXCEPTION
  WHEN APEX_APPLICATION.E_STOP_APEX_ENGINE THEN
    RAISE;
  WHEN OTHERS THEN
    IF DBMS_LOB.ISTEMPORARY(l_tmpl) = 1 THEN DBMS_LOB.FREETEMPORARY(l_tmpl); END IF;
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
/
