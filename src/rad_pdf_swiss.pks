CREATE OR REPLACE PACKAGE rad_pdf_swiss AUTHID DEFINER IS
/* Swiss QR-bill IG 2.4. Pure data validation/serialization plus stateless painting.
   Invoice lines/taxes remain ordinary RAD_PDF content. No application SQL, TAPI or LOB state. */
  c_err_swiss CONSTANT PLS_INTEGER := -20830;
  TYPE t_address IS RECORD (
    name VARCHAR2(4000), street VARCHAR2(4000), building_no VARCHAR2(4000),
    postal_code VARCHAR2(4000), town VARCHAR2(4000), country VARCHAR2(4000)
  );
  TYPE t_bill IS RECORD (
    account VARCHAR2(4000), creditor t_address,
    amount NUMBER, currency VARCHAR2(4000) := 'CHF', debtor t_address,
    reference_type VARCHAR2(4000) := 'NON', reference VARCHAR2(4000),
    message VARCHAR2(4000), billing_information VARCHAR2(4000),
    alternative_1 VARCHAR2(4000), alternative_2 VARCHAR2(4000)
  );
  TYPE t_options IS RECORD (
    language VARCHAR2(2) := 'IT',
    placement VARCHAR2(10) := 'INTEGRATED',
    font_family VARCHAR2(100) := 'Helvetica',
    font_regular PLS_INTEGER, font_bold PLS_INTEGER,
    print_billing_information BOOLEAN := FALSE
  );
  PROCEDURE validate(p_bill IN t_bill);
  FUNCTION from_json(p_json IN CLOB) RETURN t_bill;

  -- The bill attached to a document (moved out of rad_pdf_layout: layout knows no extension). attach validates the bill
  -- and the placement (INTEGRATED by default: layout reserves 115 mm at the bottom of every page; SEPARATE: layout adds
  -- a final page); rad_pdf.finalize draws it after the render (draw_attached). One bill per document.
  PROCEDURE attach(p_doc IN rad_pdf_types.t_doc_handle, p_bill IN t_bill, p_options IN t_options DEFAULT NULL);
  FUNCTION  attached(p_doc IN rad_pdf_types.t_doc_handle) RETURN BOOLEAN;
  FUNCTION  placement(p_doc IN rad_pdf_types.t_doc_handle) RETURN VARCHAR2;
  PROCEDURE draw_attached(p_doc IN rad_pdf_types.t_doc_handle);
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle);
  FUNCTION to_json(p_bill IN t_bill) RETURN CLOB; -- caller-owned temporary CLOB
  FUNCTION payload(p_bill IN t_bill) RETURN VARCHAR2; -- UTF-8 when encoded; LF, no final LF
  FUNCTION qr_reference(p_base IN VARCHAR2) RETURN VARCHAR2;
  FUNCTION creditor_reference(p_base IN VARCHAR2) RETURN VARCHAR2;
  -- Internal painter: fixed 210 x 105 mm at the bottom of the current page.
  -- Prepare/check every text block before emitting PDF operators; never truncate.
  PROCEDURE draw(p_doc IN rad_pdf_types.t_doc_handle,p_bill IN t_bill,
                 p_options IN t_options DEFAULT NULL);
END rad_pdf_swiss;
/
