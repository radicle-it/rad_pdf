CREATE OR REPLACE PACKAGE rad_pdf_doc AUTHID DEFINER IS
/*
  rad_pdf_doc -- the lifecycle of a document (2026-11-16, A4).
  Oracle 19c+.

  close_doc closes every package that holds per-document state, the highest
  level first, then frees the handle (rad_pdf_ctx.release_doc). It collects the
  first error, closes everything anyway and raises it at the end. A package
  that gains per-document state adds its close_doc HERE, never in rad_pdf_ctx.
*/
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle);
END rad_pdf_doc;
/
