-- Export published sample data as PDFNAME/PAYLOADHEX/PDFHEX for independent checks.
-- SQLcl: spool /tmp/swiss-export.log; @tests/export_swiss_fixtures.sql; spool off
set define off
set sqlblanklines on
set serveroutput on size unlimited
whenever sqlerror exit sql.sqlcode rollback
DECLARE
  l_bill rad_pdf_swiss.t_bill;
  l_options rad_pdf_swiss.t_options;
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE dump_pdf(p_name VARCHAR2) IS
    l_pos PLS_INTEGER := 1;
  BEGIN
    DBMS_OUTPUT.PUT_LINE('PDFNAME:'||p_name);
    DBMS_OUTPUT.PUT_LINE('PAYLOADHEX:'||RAWTOHEX(UTL_I18N.STRING_TO_RAW(rad_pdf_swiss.payload(l_bill),'AL32UTF8')));
    WHILE l_pos<=DBMS_LOB.GETLENGTH(l_pdf) LOOP
      DBMS_OUTPUT.PUT_LINE('PDFHEX:'||RAWTOHEX(DBMS_LOB.SUBSTR(l_pdf,12000,l_pos)));
      l_pos := l_pos+12000;
    END LOOP;
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;
BEGIN
  rad_pdf_styles.load_defaults;
  l_bill.account := 'CH4431999123000889012';
  l_bill.creditor.name := 'Max Muster & Söhne'; l_bill.creditor.street := 'Musterstrasse';
  l_bill.creditor.building_no := '123'; l_bill.creditor.postal_code := '8000';
  l_bill.creditor.town := 'Seldwyla'; l_bill.creditor.country := 'CH';
  l_bill.debtor.name := 'Simon Muster'; l_bill.debtor.street := 'Musterstrasse';
  l_bill.debtor.building_no := '1'; l_bill.debtor.postal_code := '8000';
  l_bill.debtor.town := 'Seldwyla'; l_bill.debtor.country := 'CH';
  l_bill.amount := 2500.25; l_bill.reference_type := 'QRR';
  l_bill.reference := '210000000003139471430009017'; l_bill.message := 'Invoice 1024';
  l_bill.billing_information := '//S1/10/1024'; l_bill.alternative_1 := 'eBill/B/41010560425610107';
  l_options.language := 'IT';
  l_doc := rad_pdf.new_document;
  rad_pdf.swiss_qr_bill(l_doc,l_bill,l_options);
  rad_pdf.heading(l_doc,'Fattura 1024',1);
  l_cols.EXTEND(1); l_cols(1).label := 'Descrizione'; l_cols(1).width := 180;
  rad_pdf.query2table(l_doc,'select ''INVOICE_ROW_''||level from dual connect by level<=120',l_cols);
  l_pdf := rad_pdf.finalize(l_doc); dump_pdf('qrr_integrated');
  l_bill.account := 'CH5800791123000889012'; l_bill.currency := 'EUR';
  l_bill.reference_type := 'SCOR'; l_bill.reference := 'RF18539007547034';
  l_options.language := 'EN'; l_options.placement := 'SEPARATE';
  l_doc := rad_pdf.new_document;
  rad_pdf.swiss_qr_bill(l_doc,l_bill,l_options); rad_pdf.write(l_doc,'Separate payment section');
  l_pdf := rad_pdf.finalize(l_doc); dump_pdf('scor_separate');
  l_bill.reference_type := 'NON'; l_bill.reference := NULL; l_bill.amount := NULL;
  l_bill.billing_information := NULL; l_bill.alternative_1 := NULL; l_bill.message := NULL;
  l_bill.debtor.name := NULL; l_bill.debtor.street := NULL; l_bill.debtor.building_no := NULL;
  l_bill.debtor.postal_code := NULL; l_bill.debtor.town := NULL; l_bill.debtor.country := NULL;
  l_options.language := 'FR'; l_options.placement := 'INTEGRATED';
  l_doc := rad_pdf.new_document;
  rad_pdf.swiss_qr_bill(l_doc,l_bill,l_options);
  l_pdf := rad_pdf.finalize(l_doc); dump_pdf('non_blank');
END;
/
