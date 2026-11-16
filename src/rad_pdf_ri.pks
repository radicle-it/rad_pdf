CREATE OR REPLACE PACKAGE rad_pdf_ri AUTHID DEFINER AS
-- =============================================================================
-- RAD_PDF_RI: the intermediate representation of a document template (the RI of middleware-docs 96a §1b.1, step B1
-- of the Word evolution). A VALUE, not package state: built by code (the builder below) or, later, by the Word
-- reader; sealed once, then immutable; consumed by the data merge and the paginator. Two documents in one session
-- never share anything here.
--
--   document ── section ── zone body | header_first | header_default | footer_first | footer_default
--   zone | cell | block_region          hold blocks:  paragraph | table | page_break | fixed_box | block_region
--   paragraph | inline_region           hold inlines: run | field | tab | line_break | image | tag | inline_region
--   table | row_region                  hold rows:    row | row_region (a row_region holds exactly ONE row, never a header)
--   row ── cell (grid_span >= 1, no nested table in v1)
--
-- Every measure is in POINTS. The RI holds the template only, never the data of a document. Every violation of a
-- placement (at insert) or of an invariant (at seal) raises [PDF_RI] with c_err_ri.
-- =============================================================================

  c_ri_version CONSTANT PLS_INTEGER := 1;
  c_err_ri     CONSTANT PLS_INTEGER := -20840;          -- [PDF_RI]

  SUBTYPE t_id   IS PLS_INTEGER;
  SUBTYPE t_flag IS CHAR(1);                             -- 'Y' | 'N'

  TYPE t_num_list IS TABLE OF NUMBER;

  -- one side of a border: style NONE | SINGLE, width in points, colour RRGGBB
  TYPE t_border IS RECORD (style VARCHAR2(6), width NUMBER, color VARCHAR2(6));
  TYPE t_borders IS RECORD (top t_border, bottom t_border, lft t_border, rgt t_border, inside_h t_border, inside_v t_border);

  -- the resolved format of a run (and of the text a field or a tag produces)
  TYPE t_run_fmt IS RECORD (
    font      VARCHAR2(100),                             -- the font the template asks for (resolved at print, D3)
    size_pt   NUMBER,
    bold      t_flag := 'N',
    italic    t_flag := 'N',
    underline t_flag := 'N',
    color     VARCHAR2(6) := '000000');

  -- the resolved properties of a paragraph
  TYPE t_para_fmt IS RECORD (
    align        CHAR(1) := 'L',                         -- L | C | R | J
    ind_left     NUMBER  := 0,
    ind_right    NUMBER  := 0,
    ind_first    NUMBER  := 0,                           -- negative: hanging
    space_before NUMBER  := 0,
    space_after  NUMBER  := 0,
    line_mult    NUMBER  := 1,                           -- multiple line spacing (1 = single)
    keep_next    t_flag  := 'N');

  TYPE t_tab IS RECORD (pos NUMBER, kind CHAR(1));       -- kind L | R | D (decimal)
  TYPE t_tab_list IS TABLE OF t_tab;

  TYPE t_cell_fmt IS RECORD (
    grid_span  PLS_INTEGER := 1,
    borders    t_borders,
    shading    VARCHAR2(6),                              -- fill RRGGBB, NULL none
    mar_top    NUMBER := 0,
    mar_bottom NUMBER := 0,
    mar_left   NUMBER := 0,
    mar_right  NUMBER := 0);

  -- one node: the fields of its kind only (listed per kind), never a field reused for another meaning
  TYPE t_node IS RECORD (
    kind        VARCHAR2(16),                            -- document section zone paragraph run field tab line_break
                                                         -- image tag table row cell page_break fixed_box
                                                         -- inline_region block_region row_region
    parent      t_id,
    zone_name   VARCHAR2(16),                            -- zone
    page_w      NUMBER, page_h NUMBER, orientation CHAR(1),       -- section (orientation P | L)
    mar_top     NUMBER, mar_bottom NUMBER, mar_left NUMBER, mar_right NUMBER,
    mar_header  NUMBER, mar_footer NUMBER, title_page t_flag,
    para        t_para_fmt,                              -- paragraph
    tabs        t_tab_list,                              -- paragraph
    text        VARCHAR2(32767),                         -- run
    fmt         t_run_fmt,                               -- run field tag
    field_code  VARCHAR2(8),                             -- field: PAGE | NUMPAGES
    image_res   t_id,                                    -- image fixed_box: the resource
    width       NUMBER, height NUMBER,                   -- image fixed_box
    keep_next   t_flag,                                  -- fixed_box
    tag_op      VARCHAR2(9),                             -- tag: FIELD | IMAGE | PAGEBREAK
    ref_scope   VARCHAR2(400),                           -- tag, regions: NULL = the root, else the path of the loop
    ref_path    VARCHAR2(400),                           -- tag, regions: the resolved absolute path (96a §6.3)
    region_kind VARCHAR2(7),                             -- regions: LOOP | SECTION
    grid        t_num_list,                              -- table: column widths
    borders     t_borders,                               -- table: default borders
    header      t_flag,                                  -- row: repeated header
    cant_split  t_flag,                                  -- row
    cell        t_cell_fmt);                             -- cell

  TYPE t_nodes    IS TABLE OF t_node     INDEX BY PLS_INTEGER;
  TYPE t_children IS TABLE OF t_num_list INDEX BY PLS_INTEGER;

  TYPE t_image IS RECORD (bytes BLOB, format VARCHAR2(4), px_w PLS_INTEGER, px_h PLS_INTEGER, sha256 VARCHAR2(64));
  TYPE t_images IS TABLE OF t_image INDEX BY PLS_INTEGER;

  TYPE t_ri IS RECORD (
    ri_version PLS_INTEGER,
    sealed     t_flag := 'N',
    n          PLS_INTEGER := 0,                         -- nodes so far (ids 1..n, 1 = document)
    nodes      t_nodes,
    children   t_children,
    images     t_images,
    section_id t_id);

  -- the font a template asks for and its variants used (R B I X = regular bold italic bold-italic): computed at seal
  TYPE t_font_req IS RECORD (name VARCHAR2(100), variants VARCHAR2(4));
  TYPE t_font_reqs IS TABLE OF t_font_req;

  -- ---------------------------------------------------------------------------
  -- Builder
  -- ---------------------------------------------------------------------------
  FUNCTION new_ri RETURN t_ri;

  -- the one section, with its five zones
  FUNCTION section(p_ri IN OUT NOCOPY t_ri, p_page_w IN NUMBER, p_page_h IN NUMBER, p_orientation IN CHAR,
                   p_mar_top IN NUMBER, p_mar_bottom IN NUMBER, p_mar_left IN NUMBER, p_mar_right IN NUMBER,
                   p_mar_header IN NUMBER, p_mar_footer IN NUMBER, p_title_page IN t_flag) RETURN t_id;
  -- body | header_first | header_default | footer_first | footer_default
  FUNCTION zone(p_ri IN t_ri, p_name IN VARCHAR2) RETURN t_id;

  FUNCTION add_image(p_ri IN OUT NOCOPY t_ri, p_bytes IN BLOB, p_format IN VARCHAR2,
                     p_px_w IN PLS_INTEGER, p_px_h IN PLS_INTEGER) RETURN t_id;

  -- blocks (in a zone, a cell or a block_region)
  FUNCTION paragraph (p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_fmt IN t_para_fmt, p_tabs IN t_tab_list DEFAULT NULL) RETURN t_id;
  FUNCTION table_    (p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_grid IN t_num_list, p_borders IN t_borders) RETURN t_id;
  FUNCTION page_break(p_ri IN OUT NOCOPY t_ri, p_in IN t_id) RETURN t_id;
  FUNCTION fixed_box (p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_res IN t_id, p_width IN NUMBER, p_height IN NUMBER,
                      p_keep_next IN t_flag DEFAULT 'N') RETURN t_id;
  FUNCTION block_region(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_kind IN VARCHAR2, p_scope IN VARCHAR2, p_path IN VARCHAR2) RETURN t_id;

  -- inlines (in a paragraph or an inline_region)
  FUNCTION run       (p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_text IN VARCHAR2, p_fmt IN t_run_fmt) RETURN t_id;
  FUNCTION field     (p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_code IN VARCHAR2, p_fmt IN t_run_fmt) RETURN t_id;
  FUNCTION tab       (p_ri IN OUT NOCOPY t_ri, p_in IN t_id) RETURN t_id;
  FUNCTION line_break(p_ri IN OUT NOCOPY t_ri, p_in IN t_id) RETURN t_id;
  FUNCTION image     (p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_res IN t_id, p_width IN NUMBER, p_height IN NUMBER) RETURN t_id;
  FUNCTION tag       (p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_op IN VARCHAR2, p_scope IN VARCHAR2, p_path IN VARCHAR2,
                      p_fmt IN t_run_fmt) RETURN t_id;
  FUNCTION inline_region(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_kind IN VARCHAR2, p_scope IN VARCHAR2, p_path IN VARCHAR2) RETURN t_id;

  -- rows (in a table or a row_region) and cells
  FUNCTION row_      (p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_header IN t_flag DEFAULT 'N', p_cant_split IN t_flag DEFAULT 'N') RETURN t_id;
  FUNCTION row_region(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_kind IN VARCHAR2, p_scope IN VARCHAR2, p_path IN VARCHAR2) RETURN t_id;
  FUNCTION cell      (p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_fmt IN t_cell_fmt) RETURN t_id;

  -- the global invariants, then the RI is immutable (every builder call raises after it)
  PROCEDURE seal(p_ri IN OUT NOCOPY t_ri);

  -- the CONSUME BOUNDARY: the record is public, so neither the sealed flag nor the fields are trusted. Every consumer
  -- (to_json, the data merge, the paginator) calls validate first: the RI is replayed through the builder and sealed
  -- again (the same rules, in one place); a record altered after seal raises [PDF_RI].
  PROCEDURE validate(p_ri IN t_ri);

  -- ---------------------------------------------------------------------------
  -- Reading
  -- ---------------------------------------------------------------------------
  FUNCTION node_count(p_ri IN t_ri) RETURN PLS_INTEGER;
  FUNCTION kids(p_ri IN t_ri, p_id IN t_id) RETURN t_num_list;
  FUNCTION fonts(p_ri IN t_ri) RETURN t_font_reqs;

  -- ---------------------------------------------------------------------------
  -- Serialization: canonical JSON (same RI → same text; validate first); from_json reads strictly (every member
  -- present and of its JSON type) and rebuilds through the builder and seals, so a text that breaks an invariant is
  -- refused like a builder call
  -- ---------------------------------------------------------------------------
  FUNCTION to_json  (p_ri   IN t_ri) RETURN CLOB;
  FUNCTION from_json(p_json IN CLOB) RETURN t_ri;

  -- the temporary LOBs of the images (the RI owns copies of their bytes); the RI is empty after it
  PROCEDURE free(p_ri IN OUT NOCOPY t_ri);

  -- helpers for callers that build formats
  FUNCTION border(p_style IN VARCHAR2, p_width IN NUMBER DEFAULT 0.5, p_color IN VARCHAR2 DEFAULT '000000') RETURN t_border;
  FUNCTION borders_all(p_b IN t_border) RETURN t_borders;

END rad_pdf_ri;
/
