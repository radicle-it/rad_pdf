-- =============================================================================
-- sample21.sql  -  PDF/A-2b: archival-grade conformant documents
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A PDF/A-2b conformant document (ISO 19005-2) - the format required for
--   long-term archiving and, in Italy, for "conservazione sostitutiva".
--   One call switches the document to conformance mode:
--
--     rad_pdf.set_conformance(l_doc, 'PDF/A-2B');
--
--   At finalize RAD_PDF emits XMP metadata (synchronised with the Info
--   dictionary), an sRGB OutputIntent and the file /ID required by the
--   standard.
--
-- KEY RULES
--   - EVERY font used must be EMBEDDED: load a TrueType with
--     p_embed => TRUE. The standard 14 PDF fonts (Helvetica, Times,
--     Courier) are metrics-only and raise ORA-20700 in this mode, naming
--     the offending font.
--   - Charts inherit the current document font, so set the embedded font
--     BEFORE drawing charts.
--   - Vector content (charts, QR/barcodes, lines) and images are fine;
--     watermark transparency is allowed (PDF/A-2; it would not be in A-1).
--   - Validate the output with veraPDF (https://verapdf.org):
--       verapdf -f 2b document.pdf      -> isCompliant="true"
--
-- DATA
--   Requires a TTF font readable through an Oracle Directory:
--     CREATE OR REPLACE DIRECTORY FONT_DIR AS '/path/to/fonts';
--     GRANT READ ON DIRECTORY FONT_DIR TO your_schema;
--
-- HOW TO RUN
--   Adjust FONT_DIR / font filename, then run as sample01.sql.
--
-- PREREQUISITES
--   RAD_PDF v1.7.0+ installed (run src/install.sql).
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_info rad_pdf_types.t_doc_info;
  l_fi   PLS_INTEGER;
  l_v    rad_pdf_types.t_number_list;
  l_l    rad_pdf_types.t_text_list;
BEGIN
  rad_pdf_styles.load_defaults;

  l_info.title   := 'Relazione conservazione 2026';
  l_info.author  := 'Radicle S.r.l.';
  l_info.subject := 'Documento PDF/A-2b generato da Oracle';
  l_doc := rad_pdf.new_document(p_info => l_info);

  -- 1. Switch to PDF/A-2b BEFORE adding content
  rad_pdf.set_conformance(l_doc, 'PDF/A-2B');

  -- 2. Load and EMBED a TrueType font; make it the current font
  l_fi := rad_pdf_fonts.load_ttf(l_doc,
            p_dir      => 'FONT_DIR',
            p_filename => 'YourFont.ttf',   -- adjust
            p_embed    => TRUE);
  rad_pdf_canvas.set_font(l_doc, l_fi, 16);
  rad_pdf_canvas.write_text(l_doc, 'Relazione conservazione 2026', 20, 270, 'mm');
  rad_pdf_canvas.set_font(l_doc, l_fi, 10);
  rad_pdf_canvas.write_text(l_doc,
    'Documento conforme ISO 19005-2 (PDF/A-2b), generato interamente in PL/SQL.',
    20, 262, 'mm');

  -- 3. Vector content works as usual (the chart inherits the embedded font)
  l_v(1) := 120; l_v(2) := 340; l_v(3) := 260;
  l_l(1) := '2024'; l_l(2) := '2025'; l_l(3) := '2026';
  rad_pdf.bar_chart(l_doc, l_v, 20, 160, 90, 70,
                    p_labels => l_l, p_title => 'Volumi archiviati (k)',
                    p_unit => 'mm');
  rad_pdf.qrcode(l_doc, 'https://archive.example.com/doc/2026-001',
                 130, 165, 50, p_unit => 'mm');

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('PDF/A generated: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  DBMS_OUTPUT.PUT_LINE('Validate with: verapdf -f 2b <file>');

  -- rad_pdf.save(l_pdf, 'PDF_OUT', 'sample21_pdfa.pdf');
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
