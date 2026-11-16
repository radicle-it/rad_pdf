CREATE OR REPLACE PACKAGE rad_pdf_doc AUTHID DEFINER IS
/*
  rad_pdf_doc -- the lifecycle of a document (2026-11-16, A4).
  Oracle 19c+.

  close_doc closes every package that holds per-document state, the highest
  level first, then frees the handle (rad_pdf_ctx.release_doc). Every closer
  runs even when one before it fails; the first failure is raised at the end as
  c_err_internal 'Document cleanup: <package>: <message>' with its backtrace.
  The handle is freed in any case, and a second close_doc of it is a no-op: if
  a closer fails part-way, what it had not dropped stays in its package until
  the session ends. Handles are never reused (rad_pdf_ctx.new_doc counts up),
  so that leftover is never read by another document. A package that gains
  per-document state adds its close_doc HERE, never in rad_pdf_ctx.
*/
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle);
END rad_pdf_doc;
/
