CREATE OR REPLACE PACKAGE rad_pdf_fonts AUTHID DEFINER IS
/*
  rad_pdf_fonts — font management for the RAD_PDF suite.
  Oracle 19c+.

  Session-scoped state:
    g_fonts(1-14)  : standard PDF fonts, initialised once per session.
    g_fonts(15+)   : custom TTF/TTC fonts.
    g_std_init     : guard for idempotent load_standard_fonts.
    g_name_idx     : O(1) lookup table (LOWER(fontname) -> idx).

  Per-document state (g_doc_state):
    doc_fonts      : custom font indices belonging to a specific document.
    used_fonts     : font indices emitted to page streams (for write_font_objects).

  Standard font indices 1-14 are permanent. Custom fonts loaded without
  preloading are scoped to a document handle and freed by close_doc.
  Preloaded fonts (preload_ttf) survive all close_doc calls.
*/

-- ---------------------------------------------------------------------------
-- Standard font initialization (idempotent — safe to call multiple times).
-- ---------------------------------------------------------------------------
  PROCEDURE load_standard_fonts;

-- ---------------------------------------------------------------------------
-- Custom TTF / TTC font loading — per-document (freed on close_doc).
-- p_doc: the document handle that owns this font.
-- ---------------------------------------------------------------------------
  FUNCTION  load_ttf(p_doc      IN rad_pdf_types.t_doc_handle,
                     p_font     IN BLOB,
                     p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                     p_embed    IN BOOLEAN  DEFAULT FALSE,
                     p_compress IN BOOLEAN  DEFAULT TRUE,
                     p_offset   IN NUMBER   DEFAULT 1) RETURN PLS_INTEGER;

  FUNCTION  load_ttf(p_doc      IN rad_pdf_types.t_doc_handle,
                     p_dir      IN VARCHAR2,
                     p_filename IN VARCHAR2,
                     p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                     p_embed    IN BOOLEAN  DEFAULT FALSE,
                     p_compress IN BOOLEAN  DEFAULT TRUE) RETURN PLS_INTEGER;

  FUNCTION  load_ttf(p_doc      IN rad_pdf_types.t_doc_handle,
                     p_url      IN VARCHAR2,
                     p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                     p_embed    IN BOOLEAN  DEFAULT FALSE,
                     p_compress IN BOOLEAN  DEFAULT TRUE) RETURN PLS_INTEGER;

  PROCEDURE load_ttc(p_doc      IN rad_pdf_types.t_doc_handle,
                     p_ttc      IN BLOB,
                     p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                     p_embed    IN BOOLEAN  DEFAULT FALSE,
                     p_compress IN BOOLEAN  DEFAULT TRUE);

  PROCEDURE load_ttc(p_doc      IN rad_pdf_types.t_doc_handle,
                     p_dir      IN VARCHAR2,
                     p_filename IN VARCHAR2,
                     p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                     p_embed    IN BOOLEAN  DEFAULT FALSE,
                     p_compress IN BOOLEAN  DEFAULT TRUE);

-- ---------------------------------------------------------------------------
-- Batch-safe preloading — font survives all close_doc calls.
-- Do NOT pass p_doc; these are session-scoped.
-- ---------------------------------------------------------------------------
  FUNCTION  preload_ttf(p_font     IN BLOB,
                        p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                        p_embed    IN BOOLEAN  DEFAULT FALSE,
                        p_compress IN BOOLEAN  DEFAULT TRUE,
                        p_offset   IN NUMBER   DEFAULT 1) RETURN PLS_INTEGER;

  FUNCTION  preload_ttf(p_dir      IN VARCHAR2,
                        p_filename IN VARCHAR2,
                        p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                        p_embed    IN BOOLEAN  DEFAULT FALSE,
                        p_compress IN BOOLEAN  DEFAULT TRUE) RETURN PLS_INTEGER;

-- ---------------------------------------------------------------------------
-- Font lookup and metrics
-- ---------------------------------------------------------------------------
  -- Find a font index by family name and style. Raises c_err_font if not found.
  -- p_doc is reserved for future use; pass the current document handle.
  FUNCTION  find_font(p_doc    IN rad_pdf_types.t_doc_handle,
                      p_family IN VARCHAR2,
                      p_style  IN rad_pdf_types.t_font_style DEFAULT 'N')
    RETURN PLS_INTEGER;

  -- Calculate rendered text width in points for a given font and size.
  FUNCTION  text_width(p_text     IN VARCHAR2,
                       p_font_idx IN PLS_INTEGER,
                       p_size_pt  IN NUMBER) RETURN NUMBER;

-- ---------------------------------------------------------------------------
-- Internal interface (called by rad_pdf_canvas and rad_pdf_serial during rendering)
-- ---------------------------------------------------------------------------
  -- Mark a character code as used for TTF glyph subsetting.
  PROCEDURE mark_char_used(p_font_idx IN PLS_INTEGER, p_char_code IN PLS_INTEGER);

  -- Mark a font as used in a document's page streams (called by rad_pdf_canvas
  -- when emitting the Tf operator). Sets up the font for write_font_objects.
  PROCEDURE mark_font_used(p_doc IN rad_pdf_types.t_doc_handle, p_font_idx IN PLS_INTEGER);

  -- Convert text to the raw bytes expected by the PDF font encoding.
  FUNCTION  text_to_pdf_string(p_text     IN VARCHAR2,
                               p_font_idx IN PLS_INTEGER) RETURN VARCHAR2;

  -- Write all used font PDF objects for p_doc into the document stream.
  -- Returns a PDF resource fragment: '/F1 <obj> 0 R /F2 <obj> 0 R ...'
  -- Called once per document during finalization.
  FUNCTION  write_font_objects(p_doc IN rad_pdf_types.t_doc_handle) RETURN VARCHAR2;

  -- Release all per-document font state for p_doc (called by rad_pdf_ctx.close_doc).
  -- Preloaded and standard fonts are not affected.
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle);

-- ---------------------------------------------------------------------------
-- Accessors
-- ---------------------------------------------------------------------------
  FUNCTION  font_exists  (p_font_idx IN PLS_INTEGER) RETURN BOOLEAN;
  FUNCTION  is_cid       (p_font_idx IN PLS_INTEGER) RETURN BOOLEAN;
  FUNCTION  unit_norm    (p_font_idx IN PLS_INTEGER) RETURN NUMBER;
  FUNCTION  font_pdf_name(p_font_idx IN PLS_INTEGER) RETURN VARCHAR2;

END rad_pdf_fonts;
/
