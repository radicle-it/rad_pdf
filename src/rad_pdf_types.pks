CREATE OR REPLACE PACKAGE rad_pdf_types AUTHID DEFINER IS
/*
  rad_pdf_types — shared type definitions for the RAD_PDF suite.
  Oracle 19c+. No package body (spec only).
  All other packages in the suite depend on this one.
*/

-- ---------------------------------------------------------------------------
-- Version
-- ---------------------------------------------------------------------------
  c_version CONSTANT VARCHAR2(10) := '1.1.0';

-- ---------------------------------------------------------------------------
-- Scalar subtypes
-- ---------------------------------------------------------------------------
  SUBTYPE t_rgb        IS VARCHAR2(6);   -- 6-char hex RGB, e.g. 'ff0000'
  SUBTYPE t_unit       IS VARCHAR2(7);   -- 'mm','cm','pt','point','in','inch','em','pica','pc','p'
  SUBTYPE t_font_style IS VARCHAR2(2);   -- 'N','B','I','BI'
  SUBTYPE t_align_h    IS VARCHAR2(1);   -- 'L','C','R','J'
  SUBTYPE t_align_v    IS VARCHAR2(1);   -- 'T','M','B'
  SUBTYPE t_border_msk IS PLS_INTEGER;   -- bitmask: bit0=Top, bit1=Bottom, bit2=Left, bit3=Right

-- ---------------------------------------------------------------------------
-- Document handle
-- ---------------------------------------------------------------------------
  SUBTYPE t_doc_handle IS PLS_INTEGER;
  c_invalid_handle CONSTANT t_doc_handle := -1;

-- ---------------------------------------------------------------------------
-- Error code ranges
-- ---------------------------------------------------------------------------
  c_err_validation  CONSTANT PLS_INTEGER := -20400;
  c_err_io          CONSTANT PLS_INTEGER := -20500;
  c_err_rendering   CONSTANT PLS_INTEGER := -20600;
  c_err_font        CONSTANT PLS_INTEGER := -20700;
  c_err_image       CONSTANT PLS_INTEGER := -20710;
  c_err_layout      CONSTANT PLS_INTEGER := -20750;
  c_err_handle      CONSTANT PLS_INTEGER := -20760;
  c_err_internal    CONSTANT PLS_INTEGER := -20800;

-- ---------------------------------------------------------------------------
-- Path element type constants
-- ---------------------------------------------------------------------------
  c_move_to  CONSTANT NUMBER := 1;
  c_line_to  CONSTANT NUMBER := 2;
  c_curve_to CONSTANT NUMBER := 3;
  c_close    CONSTANT NUMBER := 4;

-- ---------------------------------------------------------------------------
-- Border bitmask constants
-- ---------------------------------------------------------------------------
  c_border_top    CONSTANT t_border_msk := 1;
  c_border_bottom CONSTANT t_border_msk := 2;
  c_border_left   CONSTANT t_border_msk := 4;
  c_border_right  CONSTANT t_border_msk := 8;
  c_border_all    CONSTANT t_border_msk := 15;
  c_border_none   CONSTANT t_border_msk := 0;

-- ---------------------------------------------------------------------------
-- Cell format
-- ---------------------------------------------------------------------------
  TYPE t_cell_format IS RECORD (
    font_name   VARCHAR2(100) := 'Helvetica',
    font_style  t_font_style  := 'N',
    font_size   NUMBER        := 10,
    font_color  t_rgb         := '000000',
    back_color  t_rgb         := 'ffffff',
    line_color  t_rgb         := '000000',
    line_size   NUMBER        := 0.5,
    border      t_border_msk  := 0,
    align_h     t_align_h     := 'L',
    align_v     t_align_v     := 'M',
    margin_top  NUMBER        := 1,
    margin_bot  NUMBER        := 1,
    margin_left NUMBER        := 1,
    margin_rgt  NUMBER        := 1,
    cell_height NUMBER        := NULL,
    num_format  VARCHAR2(100) := NULL,
    spacing     VARCHAR2(10)  := NULL,
    interline   VARCHAR2(10)  := NULL
  );

-- ---------------------------------------------------------------------------
-- Column definition
-- ---------------------------------------------------------------------------
  TYPE t_column_def IS RECORD (
    label      VARCHAR2(200)  := NULL,
    width      NUMBER         := 30,
    cell_row   PLS_INTEGER    := 1,
    offset_x   NUMBER         := NULL,
    offset_y   NUMBER         := NULL,
    wrap       BOOLEAN        := FALSE,
    header_fmt t_cell_format,
    data_fmt   t_cell_format
  );

  TYPE t_columns IS TABLE OF t_column_def;

-- ---------------------------------------------------------------------------
-- Table rendering options
-- ---------------------------------------------------------------------------
  TYPE t_table_options IS RECORD (
    unit          t_unit      := 'pt',
    start_x       NUMBER      := 0,
    start_y       NUMBER      := 0,
    h_row_height  NUMBER      := NULL,
    t_row_height  NUMBER      := NULL,
    interline     NUMBER      := 1.2,
    break_field   PLS_INTEGER := 0,
    max_rows      PLS_INTEGER := NULL,
    bulk_size     PLS_INTEGER := 200,
    frame         VARCHAR2(20):= NULL
  );

-- ---------------------------------------------------------------------------
-- Color scheme
-- ---------------------------------------------------------------------------
  TYPE t_color_scheme IS RECORD (
    header_ink    t_rgb := '000000',
    header_paper  t_rgb := 'e0ffff',
    header_border t_rgb := '000000',
    even_ink      t_rgb := '000000',
    even_paper    t_rgb := 'ffffff',
    even_border   t_rgb := '000000',
    odd_ink       t_rgb := '000000',
    odd_paper     t_rgb := 'd0d0d0',
    odd_border    t_rgb := '000000'
  );

-- ---------------------------------------------------------------------------
-- Label sheet definition
-- ---------------------------------------------------------------------------
  TYPE t_label_def IS RECORD (
    max_columns PLS_INTEGER := 2,
    max_rows    PLS_INTEGER := 8,
    width       NUMBER      := 170.079,
    height      NUMBER      := 85.039,
    h_distance  NUMBER      := 14.173,
    v_distance  NUMBER      := 0
  );

-- ---------------------------------------------------------------------------
-- Document metadata
-- ---------------------------------------------------------------------------
  TYPE t_doc_info IS RECORD (
    title    VARCHAR2(1024) := NULL,
    author   VARCHAR2(1024) := NULL,
    subject  VARCHAR2(1024) := NULL,
    keywords VARCHAR2(32767):= NULL
  );

-- ---------------------------------------------------------------------------
-- Page geometry (always in points)
-- ---------------------------------------------------------------------------
  TYPE t_page_format IS RECORD (
    width  NUMBER := 595.276,  -- A4 portrait
    height NUMBER := 841.890
  );

  TYPE t_margins IS RECORD (
    top    NUMBER := 85.039,   -- ~3cm
    left   NUMBER := 28.346,   -- ~1cm
    bottom NUMBER := 113.386,  -- ~4cm
    right  NUMBER := 28.346    -- ~1cm
  );

-- ---------------------------------------------------------------------------
-- Geometry helpers
-- ---------------------------------------------------------------------------
  TYPE t_number_list IS TABLE OF NUMBER INDEX BY BINARY_INTEGER;

  TYPE t_path_element IS RECORD (
    element_type NUMBER,
    x1 NUMBER := NULL, y1 NUMBER := NULL,
    x2 NUMBER := NULL, y2 NUMBER := NULL,
    x3 NUMBER := NULL, y3 NUMBER := NULL
  );
  TYPE t_path IS TABLE OF t_path_element INDEX BY BINARY_INTEGER;

-- ---------------------------------------------------------------------------
-- Page info selector constants
-- ---------------------------------------------------------------------------
  c_info_page_width   CONSTANT PLS_INTEGER := 0;
  c_info_page_height  CONSTANT PLS_INTEGER := 1;
  c_info_margin_top   CONSTANT PLS_INTEGER := 2;
  c_info_margin_right CONSTANT PLS_INTEGER := 3;
  c_info_margin_bot   CONSTANT PLS_INTEGER := 4;
  c_info_margin_left  CONSTANT PLS_INTEGER := 5;
  c_info_cursor_x     CONSTANT PLS_INTEGER := 6;
  c_info_cursor_y     CONSTANT PLS_INTEGER := 7;
  c_info_font_size    CONSTANT PLS_INTEGER := 8;
  c_info_font_idx     CONSTANT PLS_INTEGER := 9;
  c_info_page_count   CONSTANT PLS_INTEGER := 10;
  c_info_page_nr      CONSTANT PLS_INTEGER := 11;

-- ---------------------------------------------------------------------------
-- Flowable types — content units for the layout engine
-- ---------------------------------------------------------------------------
  SUBTYPE t_flowable_type IS VARCHAR2(20);
  c_flow_paragraph CONSTANT t_flowable_type := 'PARAGRAPH';
  c_flow_heading   CONSTANT t_flowable_type := 'HEADING';
  c_flow_table     CONSTANT t_flowable_type := 'TABLE';
  c_flow_image     CONSTANT t_flowable_type := 'IMAGE';
  c_flow_spacer    CONSTANT t_flowable_type := 'SPACER';
  c_flow_hline     CONSTANT t_flowable_type := 'HLINE';
  c_flow_pagebreak CONSTANT t_flowable_type := 'PAGEBREAK';

  -- t_flowable: rad_pdf_layout._close_doc is responsible for DBMS_LOB.FREETEMPORARY
  -- on each non-NULL text CLOB when destroying the document's flowable list.
  TYPE t_flowable IS RECORD (
    flow_type        t_flowable_type,
    text             CLOB,
    style_name       VARCHAR2(100),
    level            PLS_INTEGER,    -- HEADING (1..6)
    image_id         PLS_INTEGER,    -- IMAGE
    img_width        NUMBER,
    img_height       NUMBER,
    spacer_h         NUMBER,         -- SPACER
    table_ref_id     PLS_INTEGER,    -- TABLE: handle into rad_pdf_table's cache
    page_break_before BOOLEAN := FALSE,  -- set by measure pass
    measured_h        NUMBER  := 0        -- set by measure pass
  );
  TYPE t_flowable_list IS TABLE OF t_flowable INDEX BY PLS_INTEGER;

-- ---------------------------------------------------------------------------
-- Frame — rectangular content area (coords in pt, origin lower-left)
-- y is the UPPER edge; y_bottom = y - height
-- ---------------------------------------------------------------------------
  TYPE t_frame IS RECORD (
    x      NUMBER := 0,
    y      NUMBER := 0,
    width  NUMBER := 0,
    height NUMBER := 0
  );
  TYPE t_frame_list IS TABLE OF t_frame INDEX BY PLS_INTEGER;

-- ---------------------------------------------------------------------------
-- Page template — structure of a page for the layout engine.
-- All geometry fields default to NULL = "keep current value".
-- Use page_format_name OR (page_width + page_height), not both.
-- header_proc / footer_proc: anonymous PL/SQL blocks (BEGIN...END;).
-- Tokens: #PAGE_NR# (1-based), #PAGE_COUNT#.
-- Executed AFTER the render pass, when PAGE_COUNT is known.
-- ---------------------------------------------------------------------------
  TYPE t_page_template IS RECORD (
    page_format_name  VARCHAR2(20)    := NULL,
    page_width        NUMBER          := NULL,
    page_height       NUMBER          := NULL,
    margin_top        NUMBER          := NULL,
    margin_bottom     NUMBER          := NULL,
    margin_left       NUMBER          := NULL,
    margin_right      NUMBER          := NULL,
    n_columns         PLS_INTEGER     := 1,
    col_gap           NUMBER          := 20,
    header_proc       VARCHAR2(32767) := NULL,
    footer_proc       VARCHAR2(32767) := NULL
  );

-- ---------------------------------------------------------------------------
-- Table definition — shared between rad_pdf_layout and rad_pdf_table.
-- cache_ref_id is populated during the measure pass; do not set manually.
-- ---------------------------------------------------------------------------
  TYPE t_table_def IS RECORD (
    query_txt    VARCHAR2(32767) := NULL,
    query_clob   CLOB            := NULL,
    col_defs     t_columns,
    color_scheme t_color_scheme,
    options      t_table_options,
    streaming    BOOLEAN         := FALSE,
    cache_ref_id PLS_INTEGER     := NULL
  );

END rad_pdf_types;
/
