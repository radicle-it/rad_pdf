-- Swiss QR-bill IG 2.4, JSON service input and ordinary invoice content.
-- Run after src/install.sql. Uses SIX sample account/reference, not real billing data.
SET DEFINE OFF
SET SQLBLANKLINES ON
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
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
BEGIN
  rad_pdf_styles.load_defaults;
  l_options.language := 'IT';
  -- Set 'SEPARATE' to append a payment page without reserving invoice space.
  l_options.placement := 'INTEGRATED';
  l_doc := rad_pdf.new_document;
  rad_pdf.swiss_qr_bill(l_doc,l_json,l_options);
  rad_pdf.heading(l_doc,'Fattura 1024',1);
  rad_pdf.write(l_doc,'Prestazioni professionali — CHF 2 500.25');
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('Swiss QR-bill PDF: '||DBMS_LOB.GETLENGTH(l_pdf)||' bytes');
  -- Store/stream l_pdf here; alternatively use rad_pdf.save(doc, directory, filename).
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION WHEN OTHERS THEN
  rad_pdf.close_document(l_doc);
  IF DBMS_LOB.ISTEMPORARY(l_pdf)=1 THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/
