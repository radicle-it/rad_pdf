CREATE OR REPLACE PACKAGE rad_pdf_text AUTHID DEFINER IS
/* Internal text compiler. Resolves styles and line breaks once, then exposes an
   immutable plan shared by measurement and painting. No document state or LOBs. */
  TYPE t_style IS RECORD (
    font_idx PLS_INTEGER,
    font_size NUMBER,
    leading NUMBER,
    cid BOOLEAN,
    prefix VARCHAR2(512)
  );
  TYPE t_styles IS TABLE OF t_style INDEX BY PLS_INTEGER;
  FUNCTION prepare_style(p_font_idx IN PLS_INTEGER,p_font_size IN NUMBER,
                         p_color IN rad_pdf_types.t_rgb,
                         p_leading IN NUMBER DEFAULT NULL) RETURN t_style;
  FUNCTION prepare_style(p_doc IN rad_pdf_types.t_doc_handle,
                         p_format IN rad_pdf_types.t_cell_format) RETURN t_style;
  TYPE t_fragment IS RECORD (
    text VARCHAR2(4000),
    style_id PLS_INTEGER,
    x NUMBER,
    gaps_before PLS_INTEGER
  );
  TYPE t_fragments IS TABLE OF t_fragment INDEX BY PLS_INTEGER;
  TYPE t_line IS RECORD (
    first_fragment PLS_INTEGER,
    last_fragment PLS_INTEGER,
    width NUMBER,
    height NUMBER,
    ascent NUMBER,
    gaps PLS_INTEGER,
    terminal BOOLEAN
  );
  TYPE t_lines IS TABLE OF t_line INDEX BY PLS_INTEGER;
  TYPE t_plan IS RECORD (
    styles t_styles,
    fragments t_fragments,
    lines t_lines,
    width NUMBER,
    height NUMBER := 0,
    alignment rad_pdf_types.t_align_h
  );
  FUNCTION prepare_varchar(p_text IN VARCHAR2,p_style IN t_style,
                           p_width IN NUMBER,p_alignment IN rad_pdf_types.t_align_h DEFAULT 'L') RETURN t_plan;
  FUNCTION prepare(p_doc IN rad_pdf_types.t_doc_handle,
                   p_text IN CLOB,
                   p_style IN VARCHAR2,
                   p_width IN NUMBER) RETURN t_plan;
  FUNCTION prepare_runs(p_doc IN rad_pdf_types.t_doc_handle,
                        p_runs IN rad_pdf_types.t_inline_run_list,
                        p_base_style IN VARCHAR2,
                        p_width IN NUMBER) RETURN t_plan;
END rad_pdf_text;
/
