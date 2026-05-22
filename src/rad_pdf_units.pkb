CREATE OR REPLACE PACKAGE BODY rad_pdf_units IS
/*
  rad_pdf_units body — stateless conversion functions.
  1 inch = 72 pt
  1 mm   = 72/25.4 pt  ≈ 2.83465 pt
  1 cm   = 72/2.54 pt  ≈ 28.3465 pt
  1 pica = 12 pt
*/

  c_mm_to_pt  CONSTANT NUMBER := 72 / 25.4;
  c_cm_to_pt  CONSTANT NUMBER := 72 / 2.54;
  c_in_to_pt  CONSTANT NUMBER := 72;
  c_pc_to_pt  CONSTANT NUMBER := 12;

-- ---------------------------------------------------------------------------
  FUNCTION to_pt(p_value IN NUMBER, p_unit IN rad_pdf_types.t_unit) RETURN NUMBER IS
    l_u VARCHAR2(7) := LOWER(TRIM(p_unit));
  BEGIN
    CASE l_u
      WHEN 'mm'    THEN RETURN p_value * c_mm_to_pt;
      WHEN 'cm'    THEN RETURN p_value * c_cm_to_pt;
      WHEN 'in'    THEN RETURN p_value * c_in_to_pt;
      WHEN 'inch'  THEN RETURN p_value * c_in_to_pt;
      WHEN 'pt'    THEN RETURN p_value;
      WHEN 'point' THEN RETURN p_value;
      WHEN 'em'    THEN RETURN p_value * c_pc_to_pt;
      WHEN 'pica'  THEN RETURN p_value * c_pc_to_pt;
      WHEN 'pc'    THEN RETURN p_value * c_pc_to_pt;
      WHEN 'p'     THEN RETURN p_value * c_pc_to_pt;
      ELSE
        RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
          'rad_pdf_units.to_pt: unknown unit "' || p_unit || '"', TRUE);
    END CASE;
  END to_pt;

-- ---------------------------------------------------------------------------
  FUNCTION from_pt(p_value_pt IN NUMBER, p_unit IN rad_pdf_types.t_unit) RETURN NUMBER IS
    l_u VARCHAR2(7) := LOWER(TRIM(p_unit));
  BEGIN
    CASE l_u
      WHEN 'mm'    THEN RETURN p_value_pt / c_mm_to_pt;
      WHEN 'cm'    THEN RETURN p_value_pt / c_cm_to_pt;
      WHEN 'in'    THEN RETURN p_value_pt / c_in_to_pt;
      WHEN 'inch'  THEN RETURN p_value_pt / c_in_to_pt;
      WHEN 'pt'    THEN RETURN p_value_pt;
      WHEN 'point' THEN RETURN p_value_pt;
      WHEN 'em'    THEN RETURN p_value_pt / c_pc_to_pt;
      WHEN 'pica'  THEN RETURN p_value_pt / c_pc_to_pt;
      WHEN 'pc'    THEN RETURN p_value_pt / c_pc_to_pt;
      WHEN 'p'     THEN RETURN p_value_pt / c_pc_to_pt;
      ELSE
        RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
          'rad_pdf_units.from_pt: unknown unit "' || p_unit || '"', TRUE);
    END CASE;
  END from_pt;

-- ---------------------------------------------------------------------------
  FUNCTION parse_with_unit(p_str IN VARCHAR2) RETURN NUMBER IS
    l_str  VARCHAR2(50) := LOWER(TRIM(p_str));
    l_num  NUMBER;
    l_unit rad_pdf_types.t_unit;
    l_pos  PLS_INTEGER;
  BEGIN
    IF l_str IS NULL THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_units.parse_with_unit: NULL input', TRUE);
    END IF;

    l_pos := LENGTH(l_str);
    WHILE l_pos >= 1 AND SUBSTR(l_str, l_pos, 1) NOT IN
          ('0','1','2','3','4','5','6','7','8','9') LOOP
      l_pos := l_pos - 1;
    END LOOP;

    IF l_pos < 1 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_units.parse_with_unit: no numeric part in "' || p_str || '"', TRUE);
    END IF;

    BEGIN
      l_num := TO_NUMBER(SUBSTR(l_str, 1, l_pos));
    EXCEPTION
      WHEN VALUE_ERROR THEN
        RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
          'rad_pdf_units.parse_with_unit: invalid number in "' || p_str || '"', TRUE);
    END;

    l_unit := TRIM(SUBSTR(l_str, l_pos + 1));

    IF l_unit IS NULL OR l_unit = 'pt' OR l_unit = 'point' THEN
      RETURN l_num;
    END IF;

    RETURN to_pt(l_num, l_unit);
  END parse_with_unit;

-- ---------------------------------------------------------------------------
  FUNCTION rgb(p_r IN PLS_INTEGER, p_g IN PLS_INTEGER, p_b IN PLS_INTEGER)
    RETURN rad_pdf_types.t_rgb IS
  BEGIN
    IF p_r NOT BETWEEN 0 AND 255 OR
       p_g NOT BETWEEN 0 AND 255 OR
       p_b NOT BETWEEN 0 AND 255 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_units.rgb: components must be 0-255', TRUE);
    END IF;
    RETURN LPAD(TO_CHAR(p_r, 'XX'), 2, '0') ||
           LPAD(TO_CHAR(p_g, 'XX'), 2, '0') ||
           LPAD(TO_CHAR(p_b, 'XX'), 2, '0');
  END rgb;

-- ---------------------------------------------------------------------------
  PROCEDURE assert_rgb(p_rgb IN rad_pdf_types.t_rgb) IS
  BEGIN
    IF p_rgb IS NULL OR LENGTH(p_rgb) != 6 OR
       NOT REGEXP_LIKE(p_rgb, '^[0-9A-Fa-f]{6}$') THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_units.assert_rgb: "' || NVL(p_rgb,'<null>') ||
        '" is not a valid hex RGB', TRUE);
    END IF;
  END assert_rgb;

-- ---------------------------------------------------------------------------
  FUNCTION default_color_scheme RETURN rad_pdf_types.t_color_scheme IS
    l_cs rad_pdf_types.t_color_scheme;
  BEGIN
    RETURN l_cs;
  END default_color_scheme;

-- ---------------------------------------------------------------------------
  FUNCTION default_cell_format RETURN rad_pdf_types.t_cell_format IS
    l_cf rad_pdf_types.t_cell_format;
  BEGIN
    RETURN l_cf;
  END default_cell_format;

-- ---------------------------------------------------------------------------
  FUNCTION default_table_options RETURN rad_pdf_types.t_table_options IS
    l_opt rad_pdf_types.t_table_options;
  BEGIN
    RETURN l_opt;
  END default_table_options;

-- ---------------------------------------------------------------------------
  FUNCTION default_margins RETURN rad_pdf_types.t_margins IS
    l_m rad_pdf_types.t_margins;
  BEGIN
    RETURN l_m;
  END default_margins;

-- ---------------------------------------------------------------------------
  FUNCTION default_page_format RETURN rad_pdf_types.t_page_format IS
    l_pf rad_pdf_types.t_page_format;
  BEGIN
    RETURN l_pf;
  END default_page_format;

-- ---------------------------------------------------------------------------
  FUNCTION default_label_def RETURN rad_pdf_types.t_label_def IS
    l_ld rad_pdf_types.t_label_def;
  BEGIN
    RETURN l_ld;
  END default_label_def;

-- ---------------------------------------------------------------------------
  FUNCTION default_page_template RETURN rad_pdf_types.t_page_template IS
    l_pt rad_pdf_types.t_page_template;
  BEGIN
    -- All fields already default to NULL (keep current) or sensible values.
    -- Callers override only the fields they care about.
    RETURN l_pt;
  END default_page_template;

-- ---------------------------------------------------------------------------
  FUNCTION page_format(p_name IN VARCHAR2) RETURN rad_pdf_types.t_page_format IS
    l_pf rad_pdf_types.t_page_format;
    l_n  VARCHAR2(20) := UPPER(TRIM(p_name));
  BEGIN
    CASE l_n
      WHEN 'A0'      THEN l_pf.width := 2383.937; l_pf.height := 3370.394;
      WHEN 'A1'      THEN l_pf.width := 1683.780; l_pf.height := 2383.937;
      WHEN 'A2'      THEN l_pf.width := 1190.551; l_pf.height := 1683.780;
      WHEN 'A3'      THEN l_pf.width :=  841.890; l_pf.height := 1190.551;
      WHEN 'A4'      THEN l_pf.width :=  595.276; l_pf.height :=  841.890;
      WHEN 'A5'      THEN l_pf.width :=  419.528; l_pf.height :=  595.276;
      WHEN 'A6'      THEN l_pf.width :=  297.638; l_pf.height :=  419.528;
      WHEN 'LETTER'  THEN l_pf.width :=  612;     l_pf.height :=  792;
      WHEN 'LEGAL'   THEN l_pf.width :=  612;     l_pf.height := 1008;
      WHEN 'TABLOID' THEN l_pf.width :=  792;     l_pf.height := 1224;
      WHEN 'B4'      THEN l_pf.width :=  708.661; l_pf.height := 1000.630;
      WHEN 'B5'      THEN l_pf.width :=  498.898; l_pf.height :=  708.661;
      ELSE
        RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
          'rad_pdf_units.page_format: unknown format "' || p_name || '"', TRUE);
    END CASE;
    RETURN l_pf;
  END page_format;

-- ---------------------------------------------------------------------------
  FUNCTION border_mask(p_str IN VARCHAR2) RETURN rad_pdf_types.t_border_msk IS
    l_s   VARCHAR2(20) := UPPER(TRIM(p_str));
    l_msk rad_pdf_types.t_border_msk := 0;
  BEGIN
    IF INSTR(l_s, 'T') > 0 THEN l_msk := l_msk + rad_pdf_types.c_border_top;    END IF;
    IF INSTR(l_s, 'B') > 0 THEN l_msk := l_msk + rad_pdf_types.c_border_bottom; END IF;
    IF INSTR(l_s, 'L') > 0 THEN l_msk := l_msk + rad_pdf_types.c_border_left;   END IF;
    IF INSTR(l_s, 'R') > 0 THEN l_msk := l_msk + rad_pdf_types.c_border_right;  END IF;
    RETURN l_msk;
  END border_mask;

-- ---------------------------------------------------------------------------
  FUNCTION decimal_sep RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE WHEN INSTR(TO_CHAR(1.5), '.') > 0 THEN '.' ELSE ',' END;
  END decimal_sep;

END rad_pdf_units;
/
