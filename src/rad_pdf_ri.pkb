CREATE OR REPLACE PACKAGE BODY rad_pdf_ri AS

  c_path_re CONSTANT VARCHAR2(200) :=
    '^[A-Za-z_][A-Za-z0-9_]*(\[\])?(\.([A-Za-z_][A-Za-z0-9_]*(\[\])?|[0-9]+))*$';

  PROCEDURE fail(p_msg IN VARCHAR2) IS
  BEGIN
    raise_application_error(c_err_ri, '[PDF_RI] ' || substr(p_msg, 1, 1900));
  END fail;

  -- ---------------------------------------------------------------------------
  -- internals
  -- ---------------------------------------------------------------------------
  PROCEDURE check_open(p_ri IN t_ri) IS
  BEGIN
    IF p_ri.ri_version IS NULL THEN fail('not an RI: use new_ri'); END IF;
    IF p_ri.sealed = 'Y' THEN fail('the RI is sealed: it is immutable'); END IF;
  END check_open;

  FUNCTION kind_of(p_ri IN t_ri, p_id IN t_id) RETURN VARCHAR2 IS
  BEGIN
    IF p_id IS NULL OR NOT p_ri.nodes.EXISTS(p_id) THEN fail('no node ' || nvl(to_char(p_id), 'NULL')); END IF;
    RETURN p_ri.nodes(p_id).kind;
  END kind_of;

  FUNCTION add_node(p_ri IN OUT NOCOPY t_ri, p_parent IN t_id, p_node IN t_node) RETURN t_id IS
    l_id t_id;
  BEGIN
    p_ri.n := p_ri.n + 1;
    l_id := p_ri.n;
    p_ri.nodes(l_id) := p_node;
    p_ri.nodes(l_id).parent := p_parent;
    p_ri.children(l_id) := t_num_list();
    IF p_parent IS NOT NULL THEN
      p_ri.children(p_parent).EXTEND;
      p_ri.children(p_parent)(p_ri.children(p_parent).COUNT) := l_id;
    END IF;
    RETURN l_id;
  END add_node;

  -- the placement: a node of p_what may go only in a container of its family
  PROCEDURE require_in(p_ri IN t_ri, p_in IN t_id, p_what IN VARCHAR2, p_family IN VARCHAR2) IS
    l_k VARCHAR2(16) := kind_of(p_ri, p_in);
  BEGIN
    IF (p_family = 'BLOCK'  AND l_k NOT IN ('zone', 'cell', 'block_region'))
    OR (p_family = 'INLINE' AND l_k NOT IN ('paragraph', 'inline_region'))
    OR (p_family = 'ROW'    AND l_k NOT IN ('table', 'row_region'))
    OR (p_family = 'CELL'   AND l_k <> 'row')
    THEN
      fail(p_what || ' cannot be placed in a ' || l_k || ' (node ' || p_in || ')');
    END IF;
  END require_in;

  FUNCTION inside(p_ri IN t_ri, p_id IN t_id, p_kind IN VARCHAR2) RETURN BOOLEAN IS
    l_id t_id := p_id;
  BEGIN
    WHILE l_id IS NOT NULL LOOP
      IF p_ri.nodes(l_id).kind = p_kind THEN RETURN TRUE; END IF;
      l_id := p_ri.nodes(l_id).parent;
    END LOOP;
    RETURN FALSE;
  END inside;

  PROCEDURE check_measure(p_name IN VARCHAR2, p_v IN NUMBER, p_positive IN BOOLEAN DEFAULT FALSE) IS
  BEGIN
    IF p_v IS NULL OR p_v < 0 OR (p_positive AND p_v = 0) THEN
      fail(p_name || ' must be ' || CASE WHEN p_positive THEN 'a positive' ELSE 'a non-negative' END
           || ' measure in points (got ' || nvl(to_char(p_v), 'NULL') || ')');
    END IF;
  END check_measure;

  PROCEDURE check_flag(p_name IN VARCHAR2, p_v IN VARCHAR2) IS
  BEGIN
    IF p_v IS NULL OR p_v NOT IN ('Y', 'N') THEN fail(p_name || ' must be Y or N'); END IF;
  END check_flag;

  PROCEDURE check_color(p_name IN VARCHAR2, p_v IN VARCHAR2, p_nullable IN BOOLEAN DEFAULT FALSE) IS
  BEGIN
    IF p_v IS NULL AND p_nullable THEN RETURN; END IF;
    IF p_v IS NULL OR NOT regexp_like(p_v, '^[0-9A-Fa-f]{6}$') THEN fail(p_name || ' must be RRGGBB'); END IF;
  END check_color;

  PROCEDURE check_border(p_name IN VARCHAR2, p_b IN t_border) IS
  BEGIN
    IF p_b.style IS NULL THEN RETURN; END IF;           -- not set: none
    IF p_b.style NOT IN ('NONE', 'SINGLE') THEN fail(p_name || ': border style NONE or SINGLE'); END IF;
    IF p_b.style = 'SINGLE' THEN
      check_measure(p_name || ' width', p_b.width, TRUE);
      check_color(p_name || ' color', p_b.color);
    END IF;
  END check_border;

  PROCEDURE check_borders(p_name IN VARCHAR2, p_b IN t_borders) IS
  BEGIN
    check_border(p_name || '.top', p_b.top);       check_border(p_name || '.bottom', p_b.bottom);
    check_border(p_name || '.left', p_b.lft);      check_border(p_name || '.right', p_b.rgt);
    check_border(p_name || '.inside_h', p_b.inside_h); check_border(p_name || '.inside_v', p_b.inside_v);
  END check_borders;

  PROCEDURE check_fmt(p_fmt IN t_run_fmt) IS
  BEGIN
    IF p_fmt.font IS NULL THEN fail('a run format needs its font'); END IF;
    check_measure('font size', p_fmt.size_pt, TRUE);
    check_flag('bold', p_fmt.bold); check_flag('italic', p_fmt.italic); check_flag('underline', p_fmt.underline);
    check_color('run color', p_fmt.color);
  END check_fmt;

  PROCEDURE check_ref(p_kind IN VARCHAR2, p_scope IN VARCHAR2, p_path IN VARCHAR2) IS
  BEGIN
    IF p_path IS NULL OR NOT regexp_like(p_path, c_path_re) THEN fail(p_kind || ': invalid resolved path ' || p_path); END IF;
    IF p_scope IS NOT NULL THEN
      IF NOT regexp_like(p_scope, c_path_re) THEN fail(p_kind || ': invalid scope ' || p_scope); END IF;
      IF substr(p_path, 1, length(p_scope) + 3) <> p_scope || '[].' THEN
        fail(p_kind || ': the path ' || p_path || ' is not inside its scope ' || p_scope);
      END IF;
    END IF;
  END check_ref;

  FUNCTION region(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_what IN VARCHAR2, p_family IN VARCHAR2,
                  p_kind IN VARCHAR2, p_scope IN VARCHAR2, p_path IN VARCHAR2) RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, p_what, p_family);
    IF p_kind IS NULL OR p_kind NOT IN ('LOOP', 'SECTION') THEN fail(p_what || ': kind LOOP or SECTION'); END IF;
    check_ref(p_what, p_scope, p_path);
    l.kind := p_what; l.region_kind := p_kind; l.ref_scope := p_scope; l.ref_path := p_path;
    RETURN add_node(p_ri, p_in, l);
  END region;

  -- ---------------------------------------------------------------------------
  -- builder
  -- ---------------------------------------------------------------------------
  FUNCTION new_ri RETURN t_ri IS
    l_ri t_ri;
    l    t_node;
    l_id t_id;
  BEGIN
    l_ri.ri_version := c_ri_version;
    l.kind := 'document';
    l_id := add_node(l_ri, NULL, l);
    RETURN l_ri;
  END new_ri;

  FUNCTION section(p_ri IN OUT NOCOPY t_ri, p_page_w IN NUMBER, p_page_h IN NUMBER, p_orientation IN CHAR,
                   p_mar_top IN NUMBER, p_mar_bottom IN NUMBER, p_mar_left IN NUMBER, p_mar_right IN NUMBER,
                   p_mar_header IN NUMBER, p_mar_footer IN NUMBER, p_title_page IN t_flag) RETURN t_id IS
    l    t_node;
    l_id t_id;
    z    t_node;
    l_z  t_id;
  BEGIN
    check_open(p_ri);
    IF p_ri.section_id IS NOT NULL THEN fail('one section only in v1'); END IF;
    check_measure('page width', p_page_w, TRUE);  check_measure('page height', p_page_h, TRUE);
    IF p_orientation IS NULL OR p_orientation NOT IN ('P', 'L') THEN fail('orientation P or L'); END IF;
    check_measure('top margin', p_mar_top);   check_measure('bottom margin', p_mar_bottom);
    check_measure('left margin', p_mar_left); check_measure('right margin', p_mar_right);
    check_measure('header distance', p_mar_header); check_measure('footer distance', p_mar_footer);
    check_flag('title_page', p_title_page);
    IF p_mar_left + p_mar_right >= p_page_w OR p_mar_top + p_mar_bottom >= p_page_h THEN
      fail('the margins leave no body on the page');
    END IF;
    l.kind := 'section'; l.page_w := p_page_w; l.page_h := p_page_h; l.orientation := p_orientation;
    l.mar_top := p_mar_top; l.mar_bottom := p_mar_bottom; l.mar_left := p_mar_left; l.mar_right := p_mar_right;
    l.mar_header := p_mar_header; l.mar_footer := p_mar_footer; l.title_page := p_title_page;
    l_id := add_node(p_ri, 1, l);
    p_ri.section_id := l_id;
    FOR i IN 1 .. 5 LOOP
      z := NULL;
      z.kind := 'zone';
      z.zone_name := CASE i WHEN 1 THEN 'body' WHEN 2 THEN 'header_first' WHEN 3 THEN 'header_default'
                            WHEN 4 THEN 'footer_first' ELSE 'footer_default' END;
      l_z := add_node(p_ri, l_id, z);
    END LOOP;
    RETURN l_id;
  END section;

  FUNCTION zone(p_ri IN t_ri, p_name IN VARCHAR2) RETURN t_id IS
    l_kids t_num_list;
  BEGIN
    IF p_ri.section_id IS NULL THEN fail('no section yet'); END IF;
    l_kids := p_ri.children(p_ri.section_id);
    FOR i IN 1 .. l_kids.COUNT LOOP
      IF p_ri.nodes(l_kids(i)).zone_name = p_name THEN RETURN l_kids(i); END IF;
    END LOOP;
    fail('no zone ' || p_name);
  END zone;

  FUNCTION add_image(p_ri IN OUT NOCOPY t_ri, p_bytes IN BLOB, p_format IN VARCHAR2,
                     p_px_w IN PLS_INTEGER, p_px_h IN PLS_INTEGER) RETURN t_id IS
    l_i t_image;
    l_id t_id;
  BEGIN
    check_open(p_ri);
    IF p_format IS NULL OR p_format NOT IN ('PNG', 'JPEG') THEN fail('image format PNG or JPEG'); END IF;
    IF p_bytes IS NULL OR dbms_lob.getlength(p_bytes) = 0 THEN fail('an image needs its bytes'); END IF;
    IF p_px_w IS NULL OR p_px_w <= 0 OR p_px_h IS NULL OR p_px_h <= 0 THEN fail('image pixels must be positive'); END IF;
    dbms_lob.createtemporary(l_i.bytes, TRUE);
    dbms_lob.copy(l_i.bytes, p_bytes, dbms_lob.getlength(p_bytes));
    l_i.format := p_format; l_i.px_w := p_px_w; l_i.px_h := p_px_h;
    l_i.sha256 := lower(rad_pdf_codec.sha256_hex(p_bytes));
    l_id := p_ri.images.COUNT + 1;
    p_ri.images(l_id) := l_i;
    RETURN l_id;
  END add_image;

  FUNCTION paragraph(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_fmt IN t_para_fmt, p_tabs IN t_tab_list DEFAULT NULL) RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, 'paragraph', 'BLOCK');
    IF p_fmt.align IS NULL OR p_fmt.align NOT IN ('L', 'C', 'R', 'J') THEN fail('paragraph align L, C, R or J'); END IF;
    check_measure('left indent', p_fmt.ind_left); check_measure('right indent', p_fmt.ind_right);
    IF p_fmt.ind_first IS NULL THEN fail('first-line indent must be set (0 for none)'); END IF;
    IF p_fmt.ind_left + p_fmt.ind_first < 0 THEN fail('a hanging indent larger than the left indent'); END IF;
    check_measure('space before', p_fmt.space_before); check_measure('space after', p_fmt.space_after);
    check_measure('line spacing', p_fmt.line_mult, TRUE);
    check_flag('keep_next', p_fmt.keep_next);
    IF p_tabs IS NOT NULL THEN
      FOR i IN 1 .. p_tabs.COUNT LOOP
        check_measure('tab position', p_tabs(i).pos);
        IF p_tabs(i).kind IS NULL OR p_tabs(i).kind NOT IN ('L', 'R', 'D') THEN fail('tab kind L, R or D'); END IF;
        IF i > 1 AND p_tabs(i).pos <= p_tabs(i - 1).pos THEN fail('tab stops in increasing position'); END IF;
      END LOOP;
    END IF;
    l.kind := 'paragraph'; l.para := p_fmt; l.tabs := nvl(p_tabs, t_tab_list());
    RETURN add_node(p_ri, p_in, l);
  END paragraph;

  FUNCTION table_(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_grid IN t_num_list, p_borders IN t_borders) RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, 'table', 'BLOCK');
    IF inside(p_ri, p_in, 'cell') THEN fail('a table in a cell: nested tables are not in v1'); END IF;
    IF p_grid IS NULL OR p_grid.COUNT = 0 THEN fail('a table needs its grid'); END IF;
    FOR i IN 1 .. p_grid.COUNT LOOP check_measure('grid column ' || i, p_grid(i), TRUE); END LOOP;
    check_borders('table borders', p_borders);
    l.kind := 'table'; l.grid := p_grid; l.borders := p_borders;
    RETURN add_node(p_ri, p_in, l);
  END table_;

  FUNCTION page_break(p_ri IN OUT NOCOPY t_ri, p_in IN t_id) RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, 'page_break', 'BLOCK');
    IF inside(p_ri, p_in, 'cell') THEN fail('a page break in a cell'); END IF;
    l.kind := 'page_break';
    RETURN add_node(p_ri, p_in, l);
  END page_break;

  FUNCTION fixed_box(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_res IN t_id, p_width IN NUMBER, p_height IN NUMBER,
                     p_keep_next IN t_flag DEFAULT 'N') RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, 'fixed_box', 'BLOCK');
    IF p_res IS NULL OR NOT p_ri.images.EXISTS(p_res) THEN fail('fixed_box: no resource ' || p_res); END IF;
    check_measure('fixed_box width', p_width, TRUE); check_measure('fixed_box height', p_height, TRUE);
    check_flag('fixed_box keep_next', p_keep_next);
    l.kind := 'fixed_box'; l.image_res := p_res; l.width := p_width; l.height := p_height; l.keep_next := p_keep_next;
    RETURN add_node(p_ri, p_in, l);
  END fixed_box;

  FUNCTION block_region(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_kind IN VARCHAR2, p_scope IN VARCHAR2, p_path IN VARCHAR2) RETURN t_id IS
  BEGIN
    RETURN region(p_ri, p_in, 'block_region', 'BLOCK', p_kind, p_scope, p_path);
  END block_region;

  FUNCTION run(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_text IN VARCHAR2, p_fmt IN t_run_fmt) RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, 'run', 'INLINE');
    IF p_text IS NULL THEN fail('an empty run'); END IF;
    IF instr(p_text, chr(9)) > 0 OR instr(p_text, chr(10)) > 0 OR instr(p_text, chr(13)) > 0 THEN
      fail('a run holds no tab nor line break: they are nodes');
    END IF;
    check_fmt(p_fmt);
    l.kind := 'run'; l.text := p_text; l.fmt := p_fmt;
    RETURN add_node(p_ri, p_in, l);
  END run;

  FUNCTION field(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_code IN VARCHAR2, p_fmt IN t_run_fmt) RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, 'field', 'INLINE');
    IF p_code IS NULL OR p_code NOT IN ('PAGE', 'NUMPAGES') THEN fail('field PAGE or NUMPAGES (96a §7.2)'); END IF;
    check_fmt(p_fmt);
    l.kind := 'field'; l.field_code := p_code; l.fmt := p_fmt;
    RETURN add_node(p_ri, p_in, l);
  END field;

  FUNCTION tab(p_ri IN OUT NOCOPY t_ri, p_in IN t_id) RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, 'tab', 'INLINE');
    l.kind := 'tab';
    RETURN add_node(p_ri, p_in, l);
  END tab;

  FUNCTION line_break(p_ri IN OUT NOCOPY t_ri, p_in IN t_id) RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, 'line_break', 'INLINE');
    l.kind := 'line_break';
    RETURN add_node(p_ri, p_in, l);
  END line_break;

  FUNCTION image(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_res IN t_id, p_width IN NUMBER, p_height IN NUMBER) RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, 'image', 'INLINE');
    IF p_res IS NULL OR NOT p_ri.images.EXISTS(p_res) THEN fail('image: no resource ' || p_res); END IF;
    check_measure('image width', p_width, TRUE); check_measure('image height', p_height, TRUE);
    l.kind := 'image'; l.image_res := p_res; l.width := p_width; l.height := p_height;
    RETURN add_node(p_ri, p_in, l);
  END image;

  FUNCTION tag(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_op IN VARCHAR2, p_scope IN VARCHAR2, p_path IN VARCHAR2,
               p_fmt IN t_run_fmt) RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, 'tag', 'INLINE');
    IF p_op IS NULL OR p_op NOT IN ('FIELD', 'IMAGE', 'PAGEBREAK') THEN fail('tag op FIELD, IMAGE or PAGEBREAK'); END IF;
    check_ref('tag', p_scope, p_path);
    check_fmt(p_fmt);
    l.kind := 'tag'; l.tag_op := p_op; l.ref_scope := p_scope; l.ref_path := p_path; l.fmt := p_fmt;
    RETURN add_node(p_ri, p_in, l);
  END tag;

  FUNCTION inline_region(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_kind IN VARCHAR2, p_scope IN VARCHAR2, p_path IN VARCHAR2) RETURN t_id IS
  BEGIN
    RETURN region(p_ri, p_in, 'inline_region', 'INLINE', p_kind, p_scope, p_path);
  END inline_region;

  FUNCTION row_(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_header IN t_flag DEFAULT 'N', p_cant_split IN t_flag DEFAULT 'N') RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, 'row', 'ROW');
    check_flag('header', p_header); check_flag('cant_split', p_cant_split);
    IF p_ri.nodes(p_in).kind = 'row_region' THEN
      IF p_header = 'Y' THEN fail('a row_region holds no header row'); END IF;
      IF p_ri.children(p_in).COUNT > 0 THEN fail('a row_region holds exactly one row'); END IF;
    END IF;
    l.kind := 'row'; l.header := p_header; l.cant_split := p_cant_split;
    RETURN add_node(p_ri, p_in, l);
  END row_;

  FUNCTION row_region(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_kind IN VARCHAR2, p_scope IN VARCHAR2, p_path IN VARCHAR2) RETURN t_id IS
  BEGIN
    IF kind_of(p_ri, p_in) <> 'table' THEN fail('row_region cannot be placed in a ' || kind_of(p_ri, p_in) || ' (node ' || p_in || ')'); END IF;
    RETURN region(p_ri, p_in, 'row_region', 'ROW', p_kind, p_scope, p_path);
  END row_region;

  FUNCTION cell(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, p_fmt IN t_cell_fmt) RETURN t_id IS
    l t_node;
  BEGIN
    check_open(p_ri);
    require_in(p_ri, p_in, 'cell', 'CELL');
    IF p_fmt.grid_span IS NULL OR p_fmt.grid_span < 1 THEN fail('grid_span >= 1'); END IF;
    check_borders('cell borders', p_fmt.borders);
    check_color('cell shading', p_fmt.shading, TRUE);
    check_measure('cell top margin', p_fmt.mar_top);   check_measure('cell bottom margin', p_fmt.mar_bottom);
    check_measure('cell left margin', p_fmt.mar_left); check_measure('cell right margin', p_fmt.mar_right);
    l.kind := 'cell'; l.cell := p_fmt;
    RETURN add_node(p_ri, p_in, l);
  END cell;

  -- ---------------------------------------------------------------------------
  -- seal: the global invariants
  -- ---------------------------------------------------------------------------
  -- the paths of the LOOP regions around a node, innermost first, as one string ',a,b,'
  FUNCTION loops_around(p_ri IN t_ri, p_id IN t_id) RETURN VARCHAR2 IS
    l_id t_id := p_ri.nodes(p_id).parent;
    l_s  VARCHAR2(4000) := ',';
  BEGIN
    WHILE l_id IS NOT NULL LOOP
      IF p_ri.nodes(l_id).kind IN ('inline_region', 'block_region', 'row_region')
         AND p_ri.nodes(l_id).region_kind = 'LOOP' THEN
        l_s := l_s || p_ri.nodes(l_id).ref_path || ',';
      END IF;
      l_id := p_ri.nodes(l_id).parent;
    END LOOP;
    RETURN l_s;
  END loops_around;

  FUNCTION row_cells_span(p_ri IN t_ri, p_row IN t_id) RETURN PLS_INTEGER IS
    l_k t_num_list := p_ri.children(p_row);
    l_s PLS_INTEGER := 0;
  BEGIN
    FOR i IN 1 .. l_k.COUNT LOOP l_s := l_s + p_ri.nodes(l_k(i)).cell.grid_span; END LOOP;
    RETURN l_s;
  END row_cells_span;

  PROCEDURE seal(p_ri IN OUT NOCOPY t_ri) IS
    l       t_node;
    l_k     t_num_list;
    l_body  PLS_INTEGER := 0;
    l_seen_body_row BOOLEAN;
    l_n     PLS_INTEGER;
  BEGIN
    check_open(p_ri);
    IF p_ri.section_id IS NULL THEN fail('a document needs its section'); END IF;
    FOR id IN 1 .. p_ri.n LOOP
      l := p_ri.nodes(id);
      l_k := p_ri.children(id);
      CASE l.kind
        WHEN 'table' THEN
          l_seen_body_row := FALSE;
          IF l_k.COUNT = 0 THEN fail('table ' || id || ' has no row'); END IF;
          FOR i IN 1 .. l_k.COUNT LOOP
            IF p_ri.nodes(l_k(i)).kind = 'row' THEN
              IF p_ri.nodes(l_k(i)).header = 'Y' THEN
                IF l_seen_body_row THEN fail('table ' || id || ': a header row after a body row'); END IF;
              ELSE
                l_seen_body_row := TRUE;
              END IF;
            ELSE
              l_seen_body_row := TRUE;                   -- a row_region is a body row
            END IF;
          END LOOP;
        WHEN 'row' THEN
          IF l_k.COUNT = 0 THEN fail('row ' || id || ' has no cell'); END IF;
          -- the table of the row: its parent, or the parent of its row_region
          l_n := CASE WHEN p_ri.nodes(l.parent).kind = 'table' THEN l.parent ELSE p_ri.nodes(l.parent).parent END;
          IF row_cells_span(p_ri, id) <> p_ri.nodes(l_n).grid.COUNT THEN
            fail('row ' || id || ': grid_span sums to ' || row_cells_span(p_ri, id) || ', the table has '
                 || p_ri.nodes(l_n).grid.COUNT || ' columns');
          END IF;
        WHEN 'row_region' THEN
          IF l_k.COUNT <> 1 THEN fail('row_region ' || id || ' holds ' || l_k.COUNT || ' rows: exactly one'); END IF;
        WHEN 'cell' THEN
          IF l_k.COUNT = 0 THEN fail('cell ' || id || ' holds no block'); END IF;
        WHEN 'inline_region' THEN
          IF l_k.COUNT = 0 THEN fail('inline_region ' || id || ' is empty'); END IF;
        WHEN 'block_region' THEN
          IF l_k.COUNT = 0 THEN fail('block_region ' || id || ' is empty'); END IF;
        ELSE NULL;
      END CASE;
      -- the scope of a tag or a region: the root, or a LOOP around it
      IF l.kind IN ('tag', 'inline_region', 'block_region', 'row_region') AND l.ref_scope IS NOT NULL THEN
        IF instr(loops_around(p_ri, id), ',' || l.ref_scope || ',') = 0 THEN
          fail(l.kind || ' ' || id || ': ' || l.ref_path || ' resolved in the scope ' || l.ref_scope
               || ', which no loop around it opens');
        END IF;
      END IF;
      -- regions and tags in a header or footer zone: the tag of a loop element cannot be there
      IF l.kind = 'zone' AND l.zone_name = 'body' THEN l_body := l_body + 1; END IF;
    END LOOP;
    IF l_body <> 1 THEN fail('one body zone'); END IF;
    p_ri.sealed := 'Y';
  END seal;

  -- ---------------------------------------------------------------------------
  -- reading
  -- ---------------------------------------------------------------------------
  FUNCTION node_count(p_ri IN t_ri) RETURN PLS_INTEGER IS BEGIN RETURN p_ri.n; END node_count;

  FUNCTION kids(p_ri IN t_ri, p_id IN t_id) RETURN t_num_list IS
  BEGIN
    IF NOT p_ri.children.EXISTS(p_id) THEN fail('no node ' || p_id); END IF;
    RETURN p_ri.children(p_id);
  END kids;

  FUNCTION fonts(p_ri IN t_ri) RETURN t_font_reqs IS
    TYPE t_map IS TABLE OF VARCHAR2(4) INDEX BY VARCHAR2(100);
    l_map t_map;
    l_v   VARCHAR2(1);
    l_key VARCHAR2(100);
    l_out t_font_reqs := t_font_reqs();
  BEGIN
    FOR id IN 1 .. p_ri.n LOOP
      IF p_ri.nodes(id).kind IN ('run', 'field', 'tag') THEN
        l_v := CASE WHEN p_ri.nodes(id).fmt.bold = 'Y' AND p_ri.nodes(id).fmt.italic = 'Y' THEN 'X'
                    WHEN p_ri.nodes(id).fmt.bold = 'Y' THEN 'B' WHEN p_ri.nodes(id).fmt.italic = 'Y' THEN 'I' ELSE 'R' END;
        l_key := p_ri.nodes(id).fmt.font;
        IF NOT l_map.EXISTS(l_key) THEN l_map(l_key) := l_v;                 -- '' would be NULL in Oracle
        ELSIF instr(l_map(l_key), l_v) = 0 THEN l_map(l_key) := l_map(l_key) || l_v; END IF;
      END IF;
    END LOOP;
    l_key := l_map.FIRST;
    WHILE l_key IS NOT NULL LOOP
      l_out.EXTEND;
      l_out(l_out.COUNT).name := l_key;
      -- variants in a fixed order
      l_out(l_out.COUNT).variants := CASE WHEN instr(l_map(l_key), 'R') > 0 THEN 'R' END
                                  || CASE WHEN instr(l_map(l_key), 'B') > 0 THEN 'B' END
                                  || CASE WHEN instr(l_map(l_key), 'I') > 0 THEN 'I' END
                                  || CASE WHEN instr(l_map(l_key), 'X') > 0 THEN 'X' END;
      l_key := l_map.NEXT(l_key);
    END LOOP;
    RETURN l_out;
  END fonts;

  -- ---------------------------------------------------------------------------
  -- serialization
  -- ---------------------------------------------------------------------------
  FUNCTION j_border(p_b IN t_border) RETURN json_object_t IS
    o json_object_t := json_object_t();
  BEGIN
    o.put('style', p_b.style); o.put('width', p_b.width); o.put('color', p_b.color);
    RETURN o;
  END j_border;

  FUNCTION j_borders(p_b IN t_borders) RETURN json_object_t IS
    o json_object_t := json_object_t();
  BEGIN
    IF p_b.top.style IS NOT NULL THEN o.put('top', j_border(p_b.top)); END IF;
    IF p_b.bottom.style IS NOT NULL THEN o.put('bottom', j_border(p_b.bottom)); END IF;
    IF p_b.lft.style IS NOT NULL THEN o.put('left', j_border(p_b.lft)); END IF;
    IF p_b.rgt.style IS NOT NULL THEN o.put('right', j_border(p_b.rgt)); END IF;
    IF p_b.inside_h.style IS NOT NULL THEN o.put('inside_h', j_border(p_b.inside_h)); END IF;
    IF p_b.inside_v.style IS NOT NULL THEN o.put('inside_v', j_border(p_b.inside_v)); END IF;
    RETURN o;
  END j_borders;

  FUNCTION j_fmt(p_f IN t_run_fmt) RETURN json_object_t IS
    o json_object_t := json_object_t();
  BEGIN
    o.put('font', p_f.font); o.put('size', p_f.size_pt); o.put('bold', p_f.bold); o.put('italic', p_f.italic);
    o.put('underline', p_f.underline); o.put('color', p_f.color);
    RETURN o;
  END j_fmt;

  FUNCTION j_node(p_ri IN t_ri, p_id IN t_id) RETURN json_object_t IS
    l  t_node := p_ri.nodes(p_id);
    o  json_object_t := json_object_t();
    a  json_array_t;
    t  json_object_t;
    kk t_num_list := p_ri.children(p_id);
  BEGIN
    o.put('kind', l.kind);
    CASE l.kind
      WHEN 'section' THEN
        o.put('page_w', l.page_w); o.put('page_h', l.page_h); o.put('orientation', l.orientation);
        o.put('mar_top', l.mar_top); o.put('mar_bottom', l.mar_bottom); o.put('mar_left', l.mar_left);
        o.put('mar_right', l.mar_right); o.put('mar_header', l.mar_header); o.put('mar_footer', l.mar_footer);
        o.put('title_page', l.title_page);
      WHEN 'zone' THEN o.put('name', l.zone_name);
      WHEN 'paragraph' THEN
        o.put('align', l.para.align); o.put('ind_left', l.para.ind_left); o.put('ind_right', l.para.ind_right);
        o.put('ind_first', l.para.ind_first); o.put('space_before', l.para.space_before);
        o.put('space_after', l.para.space_after); o.put('line_mult', l.para.line_mult);
        o.put('keep_next', l.para.keep_next);
        a := json_array_t();
        FOR i IN 1 .. l.tabs.COUNT LOOP
          t := json_object_t(); t.put('pos', l.tabs(i).pos); t.put('kind', l.tabs(i).kind); a.append(t);
        END LOOP;
        o.put('tabs', a);
      WHEN 'run' THEN o.put('text', l.text); o.put('fmt', j_fmt(l.fmt));
      WHEN 'field' THEN o.put('code', l.field_code); o.put('fmt', j_fmt(l.fmt));
      WHEN 'image' THEN o.put('res', l.image_res); o.put('width', l.width); o.put('height', l.height);
      WHEN 'fixed_box' THEN o.put('res', l.image_res); o.put('width', l.width); o.put('height', l.height);
                             o.put('keep_next', l.keep_next);
      WHEN 'tag' THEN o.put('op', l.tag_op); o.put('scope', l.ref_scope); o.put('path', l.ref_path);
                      o.put('fmt', j_fmt(l.fmt));
      WHEN 'table' THEN
        a := json_array_t();
        FOR i IN 1 .. l.grid.COUNT LOOP a.append(l.grid(i)); END LOOP;
        o.put('grid', a); o.put('borders', j_borders(l.borders));
      WHEN 'row' THEN o.put('header', l.header); o.put('cant_split', l.cant_split);
      WHEN 'cell' THEN
        o.put('grid_span', l.cell.grid_span); o.put('borders', j_borders(l.cell.borders));
        o.put('shading', l.cell.shading); o.put('mar_top', l.cell.mar_top); o.put('mar_bottom', l.cell.mar_bottom);
        o.put('mar_left', l.cell.mar_left); o.put('mar_right', l.cell.mar_right);
      ELSE
        IF l.kind IN ('inline_region', 'block_region', 'row_region') THEN
          o.put('region', l.region_kind); o.put('scope', l.ref_scope); o.put('path', l.ref_path);
        END IF;
    END CASE;
    IF kk.COUNT > 0 THEN
      a := json_array_t();
      FOR i IN 1 .. kk.COUNT LOOP a.append(j_node(p_ri, kk(i))); END LOOP;
      o.put('children', a);
    END IF;
    RETURN o;
  END j_node;

  FUNCTION b64(p_blob IN BLOB) RETURN CLOB IS
    l_out CLOB;
    l_pos PLS_INTEGER := 1;
    l_len PLS_INTEGER := dbms_lob.getlength(p_blob);
    l_chunk CONSTANT PLS_INTEGER := 23808;              -- a multiple of 3 and of 48
  BEGIN
    dbms_lob.createtemporary(l_out, TRUE);
    WHILE l_pos <= l_len LOOP
      dbms_lob.append(l_out, translate(utl_raw.cast_to_varchar2(utl_encode.base64_encode(
        dbms_lob.substr(p_blob, l_chunk, l_pos))), 'x' || chr(10) || chr(13), 'x'));
      l_pos := l_pos + l_chunk;
    END LOOP;
    RETURN l_out;
  END b64;

  FUNCTION unb64(p_clob IN CLOB) RETURN BLOB IS
    l_out BLOB;
    l_pos PLS_INTEGER := 1;
    l_len PLS_INTEGER := dbms_lob.getlength(p_clob);
    l_chunk CONSTANT PLS_INTEGER := 31744;              -- a multiple of 4
    l_raw RAW(32767);
  BEGIN
    dbms_lob.createtemporary(l_out, TRUE);
    WHILE l_pos <= l_len LOOP
      l_raw := utl_encode.base64_decode(utl_raw.cast_to_raw(dbms_lob.substr(p_clob, l_chunk, l_pos)));
      dbms_lob.writeappend(l_out, utl_raw.length(l_raw), l_raw);
      l_pos := l_pos + l_chunk;
    END LOOP;
    RETURN l_out;
  END unb64;

  FUNCTION to_json(p_ri IN t_ri) RETURN CLOB IS
    o  json_object_t := json_object_t();
    a  json_array_t := json_array_t();
    t  json_object_t;
    fr t_font_reqs;
  BEGIN
    IF p_ri.sealed <> 'Y' THEN fail('only a sealed RI is serialized'); END IF;
    o.put('ri_version', p_ri.ri_version);
    FOR i IN 1 .. p_ri.images.COUNT LOOP
      t := json_object_t();
      t.put('id', i); t.put('format', p_ri.images(i).format); t.put('px_w', p_ri.images(i).px_w);
      t.put('px_h', p_ri.images(i).px_h); t.put('sha256', p_ri.images(i).sha256);
      t.put('bytes', b64(p_ri.images(i).bytes));
      a.append(t);
    END LOOP;
    o.put('images', a);
    fr := fonts(p_ri);
    a := json_array_t();
    FOR i IN 1 .. fr.COUNT LOOP
      t := json_object_t(); t.put('name', fr(i).name); t.put('variants', fr(i).variants); a.append(t);
    END LOOP;
    o.put('fonts', a);
    o.put('document', j_node(p_ri, 1));
    RETURN o.to_clob;
  END to_json;

  -- reading back: through the builder
  FUNCTION r_border(o IN json_object_t, k IN VARCHAR2) RETURN t_border IS
    b t_border;
    x json_object_t;
  BEGIN
    IF o IS NULL OR NOT o.has(k) THEN RETURN b; END IF;
    x := o.get_object(k);
    b.style := x.get_string('style'); b.width := x.get_number('width'); b.color := x.get_string('color');
    RETURN b;
  END r_border;

  FUNCTION r_borders(o IN json_object_t) RETURN t_borders IS
    b t_borders;
  BEGIN
    b.top := r_border(o, 'top'); b.bottom := r_border(o, 'bottom'); b.lft := r_border(o, 'left');
    b.rgt := r_border(o, 'right'); b.inside_h := r_border(o, 'inside_h'); b.inside_v := r_border(o, 'inside_v');
    RETURN b;
  END r_borders;

  FUNCTION r_fmt(o IN json_object_t) RETURN t_run_fmt IS
    f t_run_fmt;
  BEGIN
    f.font := o.get_string('font'); f.size_pt := o.get_number('size'); f.bold := o.get_string('bold');
    f.italic := o.get_string('italic'); f.underline := o.get_string('underline'); f.color := o.get_string('color');
    RETURN f;
  END r_fmt;

  PROCEDURE r_node(p_ri IN OUT NOCOPY t_ri, p_in IN t_id, o IN json_object_t) IS
    k    VARCHAR2(16) := o.get_string('kind');
    l_id t_id;
    a    json_array_t;
    pf   t_para_fmt;
    tb   t_tab_list := t_tab_list();
    cf   t_cell_fmt;
    g    t_num_list := t_num_list();
    t    json_object_t;
  BEGIN
    CASE k
      WHEN 'section' THEN
        l_id := section(p_ri, o.get_number('page_w'), o.get_number('page_h'), o.get_string('orientation'),
                        o.get_number('mar_top'), o.get_number('mar_bottom'), o.get_number('mar_left'),
                        o.get_number('mar_right'), o.get_number('mar_header'), o.get_number('mar_footer'),
                        o.get_string('title_page'));
      WHEN 'zone' THEN l_id := zone(p_ri, o.get_string('name'));
      WHEN 'paragraph' THEN
        pf.align := o.get_string('align'); pf.ind_left := o.get_number('ind_left'); pf.ind_right := o.get_number('ind_right');
        pf.ind_first := o.get_number('ind_first'); pf.space_before := o.get_number('space_before');
        pf.space_after := o.get_number('space_after'); pf.line_mult := o.get_number('line_mult');
        pf.keep_next := o.get_string('keep_next');
        a := o.get_array('tabs');
        FOR i IN 0 .. a.get_size - 1 LOOP
          t := treat(a.get(i) AS json_object_t);
          tb.EXTEND; tb(tb.COUNT).pos := t.get_number('pos'); tb(tb.COUNT).kind := t.get_string('kind');
        END LOOP;
        l_id := paragraph(p_ri, p_in, pf, tb);
      WHEN 'run' THEN l_id := run(p_ri, p_in, o.get_string('text'), r_fmt(o.get_object('fmt')));
      WHEN 'field' THEN l_id := field(p_ri, p_in, o.get_string('code'), r_fmt(o.get_object('fmt')));
      WHEN 'tab' THEN l_id := tab(p_ri, p_in);
      WHEN 'line_break' THEN l_id := line_break(p_ri, p_in);
      WHEN 'image' THEN l_id := image(p_ri, p_in, o.get_number('res'), o.get_number('width'), o.get_number('height'));
      WHEN 'fixed_box' THEN l_id := fixed_box(p_ri, p_in, o.get_number('res'), o.get_number('width'),
                                              o.get_number('height'), o.get_string('keep_next'));
      WHEN 'page_break' THEN l_id := page_break(p_ri, p_in);
      WHEN 'tag' THEN l_id := tag(p_ri, p_in, o.get_string('op'), o.get_string('scope'), o.get_string('path'),
                                  r_fmt(o.get_object('fmt')));
      WHEN 'table' THEN
        a := o.get_array('grid');
        FOR i IN 0 .. a.get_size - 1 LOOP g.EXTEND; g(g.COUNT) := a.get_number(i); END LOOP;
        l_id := table_(p_ri, p_in, g, r_borders(o.get_object('borders')));
      WHEN 'row' THEN l_id := row_(p_ri, p_in, o.get_string('header'), o.get_string('cant_split'));
      WHEN 'cell' THEN
        cf.grid_span := o.get_number('grid_span'); cf.borders := r_borders(o.get_object('borders'));
        cf.shading := o.get_string('shading'); cf.mar_top := o.get_number('mar_top');
        cf.mar_bottom := o.get_number('mar_bottom'); cf.mar_left := o.get_number('mar_left');
        cf.mar_right := o.get_number('mar_right');
        l_id := cell(p_ri, p_in, cf);
      WHEN 'inline_region' THEN l_id := inline_region(p_ri, p_in, o.get_string('region'), o.get_string('scope'), o.get_string('path'));
      WHEN 'block_region' THEN l_id := block_region(p_ri, p_in, o.get_string('region'), o.get_string('scope'), o.get_string('path'));
      WHEN 'row_region' THEN l_id := row_region(p_ri, p_in, o.get_string('region'), o.get_string('scope'), o.get_string('path'));
      ELSE fail('unknown node kind ' || k);
    END CASE;
    IF o.has('children') THEN
      a := o.get_array('children');
      FOR i IN 0 .. a.get_size - 1 LOOP
        r_node(p_ri, l_id, treat(a.get(i) AS json_object_t));
      END LOOP;
    END IF;
  END r_node;

  FUNCTION from_json(p_json IN CLOB) RETURN t_ri IS
    o    json_object_t;
    d    json_object_t;
    a    json_array_t;
    t    json_object_t;
    l_ri t_ri;
    l_id t_id;
  BEGIN
    BEGIN
      o := json_object_t.parse(p_json);
    EXCEPTION WHEN OTHERS THEN fail('not JSON: ' || sqlerrm);
    END;
    IF o.get_number('ri_version') IS NULL OR o.get_number('ri_version') <> c_ri_version THEN
      fail('ri_version ' || o.get_number('ri_version') || ' (this engine reads ' || c_ri_version || ')');
    END IF;
    l_ri := new_ri;
    a := o.get_array('images');
    FOR i IN 0 .. a.get_size - 1 LOOP
      t := treat(a.get(i) AS json_object_t);
      l_id := add_image(l_ri, unb64(t.get_clob('bytes')), t.get_string('format'), t.get_number('px_w'), t.get_number('px_h'));
      IF l_id <> t.get_number('id') OR l_ri.images(l_id).sha256 <> t.get_string('sha256') THEN
        fail('image ' || t.get_number('id') || ': id or hash do not match its bytes');
      END IF;
    END LOOP;
    d := o.get_object('document');
    IF d IS NULL OR d.get_string('kind') <> 'document' THEN fail('no document node'); END IF;
    IF d.has('children') THEN
      a := d.get_array('children');
      FOR i IN 0 .. a.get_size - 1 LOOP r_node(l_ri, 1, treat(a.get(i) AS json_object_t)); END LOOP;
    END IF;
    seal(l_ri);
    RETURN l_ri;
  END from_json;

  -- ---------------------------------------------------------------------------
  -- helpers
  -- ---------------------------------------------------------------------------
  FUNCTION border(p_style IN VARCHAR2, p_width IN NUMBER DEFAULT 0.5, p_color IN VARCHAR2 DEFAULT '000000') RETURN t_border IS
    b t_border;
  BEGIN
    b.style := p_style; b.width := p_width; b.color := p_color;
    RETURN b;
  END border;

  FUNCTION borders_all(p_b IN t_border) RETURN t_borders IS
    b t_borders;
  BEGIN
    b.top := p_b; b.bottom := p_b; b.lft := p_b; b.rgt := p_b; b.inside_h := p_b; b.inside_v := p_b;
    RETURN b;
  END borders_all;

END rad_pdf_ri;
/
