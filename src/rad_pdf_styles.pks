CREATE OR REPLACE PACKAGE rad_pdf_styles AUTHID DEFINER IS
/*
  rad_pdf_styles — session-scoped named style registry.
  Oracle 19c+.

  Styles survive rad_pdf_ctx.close_doc (they are session-level, not per-document).
  Predefined styles are loaded lazily on first call to get() or load_defaults.

  Predefined style names:
    'default'       — base style (Helvetica N 10, black on white)
    'body'          — body text (same as default; explicit alias)
    'h1'..'h6'      — headings (Helvetica B, sizes 18/16/14/12/11/10)
    'caption'       — small grey caption (Helvetica I 8)
    'table_header'  — table header row (Helvetica B 9, white on navy)
    'table_even'    — even data rows (Helvetica N 9, white background)
    'table_odd'     — odd data rows  (Helvetica N 9, light grey background)
    'label'         — mailing label text (Helvetica N 9)
*/

  -- Define or update a named style. NULL parameters keep the field at its
  -- default value (from 'default' style). Idempotent.
  PROCEDURE define(
    p_name       IN VARCHAR2,
    p_font_name  IN VARCHAR2               DEFAULT NULL,
    p_font_style IN rad_pdf_types.t_font_style DEFAULT NULL,
    p_font_size  IN NUMBER                 DEFAULT NULL,
    p_font_color IN rad_pdf_types.t_rgb        DEFAULT NULL,
    p_back_color IN rad_pdf_types.t_rgb        DEFAULT NULL,
    p_line_color IN rad_pdf_types.t_rgb        DEFAULT NULL,
    p_line_size  IN NUMBER                 DEFAULT NULL,
    p_border     IN rad_pdf_types.t_border_msk DEFAULT NULL,
    p_align_h    IN rad_pdf_types.t_align_h    DEFAULT NULL,
    p_align_v    IN rad_pdf_types.t_align_v    DEFAULT NULL,
    p_leading    IN NUMBER                 DEFAULT NULL,
    p_num_format IN VARCHAR2               DEFAULT NULL
  );

  -- Retrieve a style by name. Returns the 'default' style if p_name is unknown.
  -- Calls load_defaults if the registry is empty.
  FUNCTION get(p_name IN VARCHAR2) RETURN rad_pdf_types.t_cell_format;

  FUNCTION  exists_style(p_name IN VARCHAR2) RETURN BOOLEAN;
  PROCEDURE drop_style  (p_name IN VARCHAR2);
  PROCEDURE clear_all;

  -- Load the predefined system styles. Idempotent.
  -- Called automatically by get() on first access.
  PROCEDURE load_defaults;

  -- Build a t_color_scheme from the 'table_header', 'table_even', 'table_odd' styles.
  FUNCTION default_scheme RETURN rad_pdf_types.t_color_scheme;

END rad_pdf_styles;
/
