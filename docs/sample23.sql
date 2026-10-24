-- =============================================================================
-- sample23.sql - Swiss - EUR / SCOR separata (record PL/SQL)
-- Self-contained SIX sample data; no application tables, fonts or files required.
-- IG 2.4 rules: QRR is CHF-only; EUR uses ordinary IBAN with SCOR/NON.
-- Run after src/install.sql. Print PDF output at 100%, without fit-to-page.
-- APEX counterpart: docs/apex/apex_sample16.sql.
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
  l_cols rad_pdf_types.t_columns;
BEGIN
  rad_pdf_styles.load_defaults;
  -- In a PL/SQL service prefer a typed record: no JSON conversion is needed.
  l_bill.account := 'CH5800791123000889012';
  l_bill.creditor.name := 'Muster Services';
  l_bill.creditor.street := 'Musterstrasse'; l_bill.creditor.building_no := '12';
  l_bill.creditor.postal_code := '8000'; l_bill.creditor.town := 'Seldwyla';
  l_bill.creditor.country := 'CH';
  l_bill.debtor.name := 'Mario Esempio';
  l_bill.debtor.street := 'Via Esempio'; l_bill.debtor.building_no := '5';
  l_bill.debtor.postal_code := '20100'; l_bill.debtor.town := 'Milano';
  l_bill.debtor.country := 'IT';
  l_bill.currency := 'EUR'; l_bill.amount := 1800;
  l_bill.reference_type := 'SCOR';
  l_bill.reference := rad_pdf_swiss.creditor_reference('202610240023');
  l_bill.message := 'Servizi professionali - dimostrazione 23';
  l_options.language := 'EN'; l_options.placement := 'SEPARATE';
  l_doc := rad_pdf.new_document;
  rad_pdf.swiss_qr_bill(l_doc,l_bill,l_options);
  rad_pdf.heading(l_doc,'Fattura dimostrativa 23 - EUR',1);
  rad_pdf.write(l_doc,'72 prestazioni da EUR 25.00 - totale EUR 1 800.00.');
  rad_pdf.write(l_doc,'Dati di collaudo: la pagina di pagamento segue tutte le righe.');
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
    SELECT 'Prestazione '||TO_CHAR(LEVEL,'FM00') description,
           '1' quantity, '25.00 EUR' amount
      FROM dual CONNECT BY LEVEL<=72
  ~',l_cols);
  rad_pdf.spacer(l_doc,8);
  rad_pdf.write(l_doc,'Totale da pagare: EUR 1 800.00');
  -- SEPARATE appends the payment page after the invoice, without shrinking
  -- the body frame. Do not add a manual new_page here.
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('swiss_eur_scor.pdf: '||DBMS_LOB.GETLENGTH(l_pdf)||' bytes');
  -- Store/stream l_pdf here, or use rad_pdf.save instead of finalize.
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF DBMS_LOB.ISTEMPORARY(l_pdf)=1 THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
/
