CREATE OR REPLACE PACKAGE rad_pdf_doc AUTHID DEFINER IS
/*
  rad_pdf_doc -- the lifecycle of a document in the CORE (2026-11-16, A4; middleware-docs 96a §1b).
  Oracle 19c+.

  The core makes a PDF without the flowable layer: open_doc, the canvas, the fonts and the images, then assemble and
  close_doc. It calls no package of the flowable layer (rad_pdf_layout, rad_pdf_flow, rad_pdf_table,
  rad_pdf_template) nor any extension (the Swiss QR-bill, charts, barcodes): rad_pdf (the facade of the product) and
  rad_pdf_pager (the Word path) build on it.

  close_doc closes every package of the core that holds per-document state, then frees the handle
  (rad_pdf_ctx.release_doc). The facade closes the flowable layer and the extensions first (rad_pdf.close_document)
  with note and inject, then calls close_doc with the same t_close: every closer of both levels runs even when one
  before it fails; the first failure is raised at the end as c_err_internal 'Document cleanup: <package>: <error
  stack>' and its backtrace, cut to the 2048 bytes of RAISE_APPLICATION_ERROR (package, code and message first, the
  backtrace in the bytes left). Fault injection for the tests (inject) is compiled only with
  PLSQL_CCFLAGS='rad_pdf_test:TRUE'.
  The handle is freed in any case, and a second close of it is a no-op: if a closer fails part-way, what it had not
  dropped stays in its package until the session ends. Handles are never reused (rad_pdf_ctx.new_doc counts up), so
  that leftover is never read by another document. A package of the core that gains per-document state adds its
  close_doc HERE, never in rad_pdf_ctx; one of the flowable layer adds it to rad_pdf.close_document.
*/
  -- a document opened by the core: its serial state, the standard fonts, its metadata; no page yet
  FUNCTION open_doc(p_info IN rad_pdf_types.t_doc_info DEFAULT NULL,
                    p_compress_pages IN BOOLEAN DEFAULT TRUE) RETURN rad_pdf_types.t_doc_handle;

  -- the PDF of a document whose pages are drawn: font and image objects, pages, outline, PDF/A objects, catalog, info,
  -- xref and trailer; the caller frees the BLOB and closes the document
  FUNCTION assemble(p_doc IN rad_pdf_types.t_doc_handle) RETURN BLOB;

  -- the first failure of a cleanup: noted by every level, raised once at the end
  TYPE t_close IS RECORD (head VARCHAR2(4000), trace VARCHAR2(4000));
  PROCEDURE note  (p_state IN OUT NOCOPY t_close, p_package IN VARCHAR2);
  PROCEDURE inject(p_package IN VARCHAR2);

  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle);
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle, p_state IN OUT NOCOPY t_close);
END rad_pdf_doc;
/
