-- =============================================================================
-- sample24.sql - Swiss - CHF / NON con campi da compilare
-- Self-contained SIX sample data; no application tables, fonts or files required.
-- IG 2.4 rules: QRR is CHF-only; EUR uses ordinary IBAN with SCOR/NON.
-- Run after src/install.sql. Print PDF output at 100%, without fit-to-page.
-- APEX counterpart: docs/apex/apex_sample17.sql.
-- =============================================================================
SET DEFINE OFF
SET SQLBLANKLINES ON
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
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
  DBMS_OUTPUT.PUT_LINE('swiss_chf_open.pdf: '||DBMS_LOB.GETLENGTH(l_pdf)||' bytes');
  -- Store/stream l_pdf here, or use rad_pdf.save instead of finalize.
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF DBMS_LOB.ISTEMPORARY(l_pdf)=1 THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
/
