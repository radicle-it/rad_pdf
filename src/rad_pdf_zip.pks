CREATE OR REPLACE PACKAGE rad_pdf_zip AUTHID DEFINER AS
-- =============================================================================
-- RAD_PDF_ZIP: reading a ZIP container (the OPC package of a .docx, middleware-docs 96a §8), nothing else.
--
--   open_zip   the central directory, checked BEFORE anything is decompressed: one disk, no ZIP64, no encryption,
--              methods stored/deflate only, entry names that are safe part names (no '\', no absolute path, no '.'
--              or '..' segment, no empty segment), no duplicate name even by case, the local header of every entry
--              matching its central record, entries that do not overlap, at most c_max_parts entries, the sum of the
--              declared sizes within the budget and every ratio within c_max_ratio
--   extract    one entry: deflate through UTL_COMPRESS (a gzip envelope carrying the CRC-32 and the size of the
--              central record, so the CRC is verified), read PIECEWISE: the bytes are counted DURING decompression
--              and the read stops as soon as the entry outgrows its declared size or the archive's byte budget
--
-- No package state: the archive and the running byte count are parameters. Errors: [PDF_DOCX] c_err_docx for a
-- malformed or refused archive, [PDF_BUDGET] c_err_budget for a budget exceeded.
-- =============================================================================

  c_err_docx   CONSTANT PLS_INTEGER := -20846;          -- [PDF_DOCX]
  c_err_budget CONSTANT PLS_INTEGER := -20842;          -- [PDF_BUDGET] (the code of rad_pdf_merge too)

  c_max_parts  CONSTANT PLS_INTEGER := 200;              -- 96a §8
  c_max_bytes  CONSTANT PLS_INTEGER := 30 * 1024 * 1024; -- decompressed bytes of one archive
  c_max_ratio  CONSTANT PLS_INTEGER := 100;              -- decompressed / compressed, per entry

  TYPE t_entry IS RECORD (
    name     VARCHAR2(400),                              -- as stored (UTF-8 decoded), a directory ends with '/'
    method   PLS_INTEGER,                                -- 0 stored | 8 deflate
    crc32    RAW(4),                                     -- as stored: little-endian
    csize    NUMBER,
    usize    NUMBER,
    data_off NUMBER);                                    -- 1-based offset of the compressed bytes
  TYPE t_entries IS TABLE OF t_entry;

  TYPE t_zip IS RECORD (
    entries t_entries,
    used    NUMBER := 0);                                -- decompressed bytes so far (extract adds to it)

  FUNCTION open_zip(p_zip IN BLOB) RETURN t_zip;

  -- the index of an entry by its exact name, 0 when absent
  FUNCTION find(p_z IN t_zip, p_name IN VARCHAR2) RETURN PLS_INTEGER;

  -- a new temporary BLOB (the caller frees it); p_z.used grows by its size
  FUNCTION extract(p_zip IN BLOB, p_z IN OUT NOCOPY t_zip, p_index IN PLS_INTEGER) RETURN BLOB;

END rad_pdf_zip;
/
