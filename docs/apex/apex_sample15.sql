-- =============================================================================
-- apex_sample15.sql - Swiss - CHF / QRR integrata (JSON)
-- WHERE: Execute Server-side Code, On Load - Before Header; no page items needed.
-- Demo app: catalog page 4 -> page 3; G_ESEMPIO = SWISS_QRR.
-- Corresponding standalone example: docs/sample22.sql.
-- Uses published sample accounts and synthetic invoices, not live payment data.
-- PREREQUISITES: full RAD_PDF installer with rad_pdf_swiss in parsing schema.
-- Replace the demo data with your authorized invoice service/TAPI result.
-- =============================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_options rad_pdf_swiss.t_options;
  l_json CLOB := q'~{
  "schema_version": 1,
  "account": "CH4431999123000889012",
  "creditor": {
    "name": "Max Muster & Söhne",
    "street": "Musterstrasse",
    "building_no": "123",
    "postal_code": "8000",
    "town": "Seldwyla",
    "country": "CH"
  },
  "amount": 2500.25,
  "currency": "CHF",
  "debtor": {
    "name": "Simon Muster",
    "street": "Musterstrasse",
    "building_no": "1",
    "postal_code": "8000",
    "town": "Seldwyla",
    "country": "CH"
  },
  "reference_type": "QRR",
  "reference": "210000000003139471430009017",
  "message": "Invoice 1024",
  "billing_information": "//S1/10/1024",
  "alternatives": [
    "eBill/B/41010560425610107"
  ]
}~';
  l_cols rad_pdf_types.t_columns;
BEGIN
  rad_pdf_styles.load_defaults;
  l_options.language := 'IT';
  l_options.placement := 'INTEGRATED';
  l_doc := rad_pdf.new_document;
  -- JSON belongs to the service boundary; QR/payment validation is automatic.
  rad_pdf.swiss_qr_bill(l_doc,l_json,l_options);
  rad_pdf.heading(l_doc,'Fattura dimostrativa 1024',1);
  rad_pdf.write(l_doc,'Max Muster & Söhne - Simon Muster');
  rad_pdf.write(l_doc,'Esempio con dati SIX di collaudo, non destinato al pagamento.');
  rad_pdf.spacer(l_doc,8);
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(3);
  FOR i IN 1..3 LOOP
    l_cols(i).header_fmt.font_name := 'Helvetica';
    l_cols(i).header_fmt.font_style := 'B';
    l_cols(i).header_fmt.font_size := 9;
    l_cols(i).data_fmt.font_name := 'Helvetica';
    l_cols(i).data_fmt.font_size := 9;
    l_cols(i).data_fmt.margin_top := 4;
    l_cols(i).data_fmt.margin_bot := 4;
    l_cols(i).data_fmt.margin_left := 4;
    l_cols(i).data_fmt.margin_rgt := 4;
  END LOOP;
  l_cols(1).label := 'Descrizione'; l_cols(1).width := 280;
  l_cols(2).label := 'Quantita'; l_cols(2).width := 60;
  l_cols(3).label := 'Importo'; l_cols(3).width := 100;
  l_cols(2).data_fmt.align_h := 'R';
  l_cols(3).data_fmt.align_h := 'R';
  rad_pdf.query2table(l_doc,q'~
    SELECT description, quantity, amount FROM (
      SELECT 1 position, 'Consulenza' description, '5' quantity, '2 000.00 CHF' amount FROM dual
      UNION ALL
      SELECT 2, 'Configurazione e collaudo', '1', '500.25 CHF' FROM dual
    ) ORDER BY position
  ~',l_cols);
  rad_pdf.spacer(l_doc,8);
  rad_pdf.write(l_doc,'Totale da pagare: CHF 2 500.25');
  l_pdf := rad_pdf.finalize(l_doc);
  -- Finalize/validate BEFORE sending any HTTP headers.
  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: '||DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="swiss_chf_qrr.pdf"');
  HTP.P('Cache-Control: no-store, no-cache, must-revalidate');
  HTP.P('Pragma: no-cache');
  OWA_UTIL.HTTP_HEADER_CLOSE;
  WPG_DOCLOAD.DOWNLOAD_FILE(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  l_pdf := NULL;
  APEX_APPLICATION.STOP_APEX_ENGINE;
EXCEPTION
  WHEN APEX_APPLICATION.E_STOP_APEX_ENGINE THEN RAISE;
  WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF DBMS_LOB.ISTEMPORARY(l_pdf)=1 THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
