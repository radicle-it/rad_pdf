CREATE OR REPLACE PACKAGE rad_pdf_docx AUTHID DEFINER AS
-- =============================================================================
-- RAD_PDF_DOCX: the Word reader (step B4 of the Word evolution, middleware-docs 96a §6-§8). A .docx template + its
-- print schema -> the template RI (rad_pdf_ri, sealed) and the validator report of 96a §7.3.
--
--   package   rad_pdf_zip (central directory checked first, bytes counted during decompression), then OPC: the
--             content types, the package relationships, the main part of a .docx/.dotx (macro-enabled refused), the
--             parts it relates to; relationship targets resolved inside the package (never a path outside it, never
--             an external target dereferenced); macros, embedded objects, ActiveX and altChunk refused
--   XML       XMLTYPE/XMLTABLE: one query per part flattens it into elements (depth, namespace, name, attributes,
--             text of w:t/w:instrText); no DTD and no entity (refused before parsing), depth <= c_max_depth
--   styles    docDefaults -> table style -> paragraph style (basedOn chain) -> character style -> direct formatting;
--             theme fonts resolved from the theme part
--   content   one section, header/footer first/default, paragraphs, runs, tabs, PAGE/NUMPAGES fields, tables
--             (no nesting), inline PNG/JPEG images; EVERY element is on an allowlist: supported, ignored (no visible
--             effect), a WARNING (approximated) or an ERROR (96a §7.2) -- an unknown element is an ERROR
--   tags      96a §6.1 grammar, lexical inside one paragraph across runs; regions ROW > PARAGRAPHS > INLINE (§6.2);
--             paths resolved ONCE against the schema, innermost loop first (§6.3); rad_pdf_merge.check_template last
--
-- Errors raised (the package is refused, no report): [PDF_DOCX] c_err_docx (malformed or hostile package, DTD,
-- macro, embedded object), [PDF_BUDGET] c_err_budget (parts, bytes, ratio, depth). Everything about the CONTENT is
-- reported instead: with at least one ERROR the result holds no RI (96a §7.3: the version is not published).
-- No package state: every read works on its own context; the caller frees the RI with rad_pdf_ri.free.
-- =============================================================================

  c_err_docx   CONSTANT PLS_INTEGER := -20846;          -- [PDF_DOCX]
  c_err_budget CONSTANT PLS_INTEGER := -20842;          -- [PDF_BUDGET]
  c_max_depth    CONSTANT PLS_INTEGER := 64;            -- XML nesting (96a §8)
  c_max_elements CONSTANT PLS_INTEGER := 200000;        -- XML elements of one read, all parts (proposed with B4)

  -- one entry of the report (96a §7.3)
  TYPE t_issue IS RECORD (
    severity VARCHAR2(7),                                -- ERROR | WARNING
    code     VARCHAR2(30),
    part     VARCHAR2(400),                              -- word/document.xml, word/header1.xml, word/styles.xml ...
    position VARCHAR2(200),                              -- body, table 1, row 2, cell 3, paragraph 1 | style Heading1
    near     VARCHAR2(100),                              -- the text around it
    message  VARCHAR2(1000));
  TYPE t_report IS TABLE OF t_issue;

  TYPE t_result IS RECORD (
    ri       rad_pdf_ri.t_ri,                            -- sealed when errors = 0; empty otherwise
    report   t_report,
    errors   PLS_INTEGER := 0,
    warnings PLS_INTEGER := 0);

  -- the reader; p_schema is checked first (rad_pdf_merge.check_schema raises [PDF_SCHEMA])
  FUNCTION read(p_docx IN BLOB, p_schema IN rad_pdf_merge.t_schema) RETURN t_result;

  -- the report as JSON: {"errors":n,"warnings":n,"issues":[{"severity","code","part","position","near","message"}]}
  FUNCTION report_json(p_result IN t_result) RETURN CLOB;

  -- the degradation matrix (96a §7.2) as the reader applies it, the single source of its codes: one line per code,
  -- "CODE<tab>SEVERITY<tab>text" (for the guide and the tests)
  FUNCTION matrix_text RETURN CLOB;

END rad_pdf_docx;
/
