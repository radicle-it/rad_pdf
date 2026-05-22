-- =============================================================================
-- sample01.sql  —  Minimal: create a PDF with one line of text
-- =============================================================================
--
-- WHAT THIS SHOWS
--   The absolute minimum to generate a PDF with RAD_PDF:
--     1. new_document  — opens a new blank document
--     2. write         — adds a paragraph of text
--     3. finalize      — closes the document and returns the PDF as a BLOB
--
-- HOW TO RUN
--   Option A — SQL*Plus or SQL Developer (Script Output):
--     The script prints the file size to confirm it worked.
--     To save the PDF file, see Option B.
--
--   Option B — Save to a file via Oracle Directory:
--     Requires an Oracle Directory object pointing to a writable folder.
--     Uncomment the rad_pdf.save() call at the bottom and set the directory name.
--     Example setup (run once as DBA):
--       CREATE OR REPLACE DIRECTORY PDF_OUT AS '/tmp/rad_pdf';
--       GRANT WRITE ON DIRECTORY PDF_OUT TO your_schema;
--
--   Option C — SQL Developer bind variable:
--     Uncomment the ":rad_pdf := l_pdf" line.
--     After running, right-click the BLOB result in Script Output → Save As.
--
-- PREREQUISITES
--   RAD_PDF packages installed in the current schema (run src/install.sql).
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc rad_pdf_types.t_doc_handle;  -- handle that identifies this document
  l_pdf BLOB;                     -- the finished PDF binary
BEGIN
  -- Load the built-in text styles (h1-h6, body, caption, ...).
  -- Call this once per session, not once per document.
  rad_pdf_styles.load_defaults;

  -- Open a new document. RAD_PDF creates the first page automatically.
  -- A4 portrait with default margins is the default page setup.
  l_doc := rad_pdf.new_document;

  -- Add a line of body text. The layout engine wraps it automatically
  -- if it is longer than the printable width.
  rad_pdf.write(l_doc, 'Hello, RAD_PDF! This is my first PDF document.');

  -- Finalise the document: this builds the PDF binary (xref table,
  -- font objects, page streams) and returns it as a temporary BLOB.
  -- After finalize() the handle l_doc is invalid — do not use it again.
  l_pdf := rad_pdf.finalize(l_doc);

  -- Confirm it worked.
  DBMS_OUTPUT.PUT_LINE('PDF generated — size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');

  -- Option B: save to a directory on the database server.
  -- rad_pdf.save opens a new document internally, so call it INSTEAD of finalize,
  -- not after. Replace the finalize block above with:
  --   rad_pdf.save(l_doc, 'PDF_OUT', 'sample01.rad_pdf');
  -- (No BLOB to free in this case.)

  -- Option C: expose as a SQL Developer bind variable.
  -- :rad_pdf := l_pdf;

  -- Always free the temporary BLOB when you are done with it.
  -- Forgetting this leaks memory in the temporary tablespace.
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
