-- Golden bench extra (tests/golden/bench.py): TWO documents in ONE session rendering inline-formatted templates.
-- The template engine derives a style for each inline formatting (<b>, <i>, <font>); before A3 (doc 96 §11) the
-- derived styles went into the SESSION registry of rad_pdf_styles: the second document must render exactly like the
-- first when it is alone, and a third document with other inline formats must not be affected by the first two.
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<h1>Document 1</h1>' ||
    '<p>Plain, <b>bold</b>, <i>italic</i>, <b><i>both</i></b>, <font size="14pt">bigger</font>, <color rgb="CC0000">red</color>.</p>');
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc,
    '<h1>Document 2</h1>' ||
    '<p>Plain, <b>bold</b>, <i>italic</i>, <b><i>both</i></b>, <font size="14pt">bigger</font>, <color rgb="CC0000">red</color>.</p>');
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, '<p><font size="9pt">small</font> and <b>bold again</b>.</p>');
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
