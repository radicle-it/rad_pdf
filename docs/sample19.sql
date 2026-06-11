-- =============================================================================
-- sample19.sql  -  Bookmarks: navigable document outline (sidebar)
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A multi-chapter report whose headings appear in the PDF reader's
--   bookmarks/outline sidebar (v1.6.0). Clicking an entry jumps to the
--   exact heading position. The document opens with the sidebar visible
--   (/PageMode /UseOutlines).
--
-- KEY TECHNIQUES
--   - rad_pdf.heading(..., p_bookmark => TRUE): one parameter turns every
--     heading into an outline entry at the same level (h1 -> level 1, ...)
--   - Hierarchy is automatic: a level-2 entry nests under the nearest
--     previous level-1 entry, and so on (up to 6 levels)
--   - rad_pdf.add_bookmark: manual entries at any canvas position - useful
--     for anchors that are not headings (tables, appendices, signatures)
--   - Accented titles are encoded as UTF-16BE automatically - they render
--     correctly in every PDF viewer
--   - All entries are created expanded
--
-- DATA
--   Self-contained; no tables required.
--
-- HOW TO RUN
--   Same as sample01.sql - see its header for output options.
--   Open the result in a PDF reader and check the bookmarks sidebar.
--
-- PREREQUISITES
--   RAD_PDF v1.6.0+ installed (run src/install.sql).
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  -- ---------------------------------------------------------------------
  -- Chapters and sections: p_bookmark => TRUE mirrors the heading levels
  -- into the outline sidebar
  -- ---------------------------------------------------------------------
  rad_pdf.heading(l_doc, 'Relazione annuale 2026', 1, p_bookmark => TRUE);
  rad_pdf.write  (l_doc, 'Sintesi della relazione annuale.');

  rad_pdf.heading(l_doc, 'Andamento economico', 2, p_bookmark => TRUE);
  rad_pdf.write  (l_doc, 'Il fatturato è cresciuto del 18% su base annua.');

  rad_pdf.heading(l_doc, 'Attività e passività', 2, p_bookmark => TRUE);
  rad_pdf.write  (l_doc, 'Dettaglio dello stato patrimoniale.');

  rad_pdf.new_page(l_doc);
  rad_pdf.heading(l_doc, 'Conclusioni e prospettive', 1, p_bookmark => TRUE);
  rad_pdf.heading(l_doc, 'Obiettivi 2027', 2, p_bookmark => TRUE);
  rad_pdf.write  (l_doc, 'Gli obiettivi del prossimo esercizio.');

  -- ---------------------------------------------------------------------
  -- Manual bookmark: an anchor that is not a heading (e.g. the signature
  -- block at an absolute position on the last page)
  -- ---------------------------------------------------------------------
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'N', 10);
  rad_pdf_canvas.write_text(l_doc, 'Firma: ______________________', 20, 40, 'mm');
  rad_pdf.add_bookmark(l_doc, 'Firma', 1, p_y => 45, p_unit => 'mm');

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('PDF generated: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');

  -- Option B - save to an Oracle Directory:
  -- rad_pdf.save(l_pdf, 'PDF_OUT', 'sample19_bookmarks.pdf');

  -- Option C - SQL Developer bind:
  -- :rad_pdf := l_pdf;

  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
