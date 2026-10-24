-- =============================================================================
-- apex_sample17.sql - Swiss - CHF / NON con campi da compilare
-- WHERE: Execute Server-side Code, On Load - Before Header; no page items needed.
-- Demo app: catalog page 4 -> page 3; G_ESEMPIO = SWISS_OPEN.
-- Corresponding standalone example: docs/sample24.sql.
-- Uses published sample accounts and synthetic invoices, not live payment data.
-- PREREQUISITES: full RAD_PDF installer with rad_pdf_swiss in parsing schema.
-- Replace the demo data with your authorized invoice service/TAPI result.
-- =============================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_options rad_pdf_swiss.t_options;
  l_bill rad_pdf_swiss.t_bill;
BEGIN
  rad_pdf_styles.load_defaults;
  l_bill.account := 'CH5800791123000889012';
  l_bill.creditor.name := 'Muster Stiftung';
  l_bill.creditor.street := 'Musterstrasse'; l_bill.creditor.building_no := '12';
  l_bill.creditor.postal_code := '3001'; l_bill.creditor.town := 'Bern';
  l_bill.creditor.country := 'CH';
  l_bill.currency := 'CHF';
  l_bill.reference_type := 'NON'; l_bill.reference := NULL;
  l_bill.amount := NULL;
  -- Leave every debtor field NULL: a partial address is rejected.
  l_bill.message := 'Contribution volontaire - exemple de demonstration';
  l_options.language := 'FR'; l_options.placement := 'INTEGRATED';
  l_doc := rad_pdf.new_document;
  rad_pdf.swiss_qr_bill(l_doc,l_bill,l_options);
  rad_pdf.heading(l_doc,'Bollettino dimostrativo con campi liberi',1);
  rad_pdf.write(l_doc,'L''importo e il pagatore saranno compilati a mano.');
  rad_pdf.write(l_doc,'I campi delimitati sono stampati sia sulla ricevuta sia sulla sezione di pagamento.');
  rad_pdf.write(l_doc,'Esempio con dati di collaudo, non destinato al pagamento.');
  l_pdf := rad_pdf.finalize(l_doc);
  -- Finalize/validate BEFORE sending any HTTP headers.
  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: '||DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="swiss_chf_open.pdf"');
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
