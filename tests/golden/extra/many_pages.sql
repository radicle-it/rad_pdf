-- Golden bench extra (tests/golden/bench.py): a document of 3300 pages, so that the /Kids array of the page tree
-- passes the 27000 characters above which rad_pdf_serial writes an object from a CLOB (doc 96 A6). Recorded with the
-- VARCHAR2 code before A6: the CLOB path must give the same bytes.
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  FOR i IN 1 .. 3300 LOOP
    IF i > 1 THEN
      rad_pdf.new_page(l_doc);
    END IF;
    rad_pdf.write(l_doc, 'Page ' || i);
  END LOOP;
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
