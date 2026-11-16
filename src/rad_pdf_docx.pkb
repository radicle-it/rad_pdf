CREATE OR REPLACE PACKAGE BODY rad_pdf_docx AS

  -- ===========================================================================
  -- namespaces, relationship types, content types
  -- ===========================================================================
  c_ns_w      CONSTANT VARCHAR2(80) := 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  c_ns_r      CONSTANT VARCHAR2(80) := 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  c_ns_wp     CONSTANT VARCHAR2(80) := 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
  c_ns_a      CONSTANT VARCHAR2(80) := 'http://schemas.openxmlformats.org/drawingml/2006/main';
  c_ns_pic    CONSTANT VARCHAR2(80) := 'http://schemas.openxmlformats.org/drawingml/2006/picture';
  c_ns_pr     CONSTANT VARCHAR2(80) := 'http://schemas.openxmlformats.org/package/2006/relationships';
  c_ns_ct     CONSTANT VARCHAR2(80) := 'http://schemas.openxmlformats.org/package/2006/content-types';
  c_ns_mc     CONSTANT VARCHAR2(80) := 'http://schemas.openxmlformats.org/markup-compatibility/2006';
  c_ns_vml    CONSTANT VARCHAR2(80) := 'urn:schemas-microsoft-com:vml';
  c_ns_ext    CONSTANT VARCHAR2(80) := 'http://schemas.microsoft.com/office/word/';     -- prefix: w14, w15, w16...
  c_ns_strict CONSTANT VARCHAR2(80) := 'http://purl.oclc.org/ooxml/';                   -- prefix: Strict Open XML
  c_rel       CONSTANT VARCHAR2(80) := 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/';
  c_ct_doc    CONSTANT VARCHAR2(100) := 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml';
  c_ct_dot    CONSTANT VARCHAR2(100) := 'application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml';
  c_uri_pic   CONSTANT VARCHAR2(80) := 'http://schemas.openxmlformats.org/drawingml/2006/picture';

  -- ===========================================================================
  -- the working types of one read (no package state: everything lives in t_ctx)
  -- ===========================================================================
  -- an XML element of a flattened part: document order, depth, the links of the tree
  TYPE t_el IS RECORD (
    ns     VARCHAR2(8),                                  -- w r wp a pic pr ct mc v ext strict x
    nm     VARCHAR2(100),
    uri    VARCHAR2(300),
    depth  PLS_INTEGER,
    parent PLS_INTEGER,
    first  PLS_INTEGER,
    last   PLS_INTEGER,
    nxt    PLS_INTEGER,
    txt    VARCHAR2(32767),                              -- w:t / w:instrText: at most c_chunk characters
    more   rad_pdf_ri.t_num_list,                        -- a longer w:t: the index of its other pieces in t_ctx.long
    attrs  VARCHAR2(32767),                              -- ' p:name=value' pairs, values URI-encoded
    ign    VARCHAR2(4000));                              -- the root only: the namespaces its mc:Ignorable declares
  TYPE t_els IS TABLE OF t_el INDEX BY PLS_INTEGER;
  TYPE t_strs IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;
  c_chunk CONSTANT PLS_INTEGER := 2000;                 -- characters per text piece (8000 bytes at most in UTF-8)

  TYPE t_rel IS RECORD (kind VARCHAR2(100), target VARCHAR2(400), external BOOLEAN);
  TYPE t_rels IS TABLE OF t_rel INDEX BY VARCHAR2(200);
  TYPE t_map IS TABLE OF VARCHAR2(400) INDEX BY VARCHAR2(400);
  TYPE t_nmap IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(400);

  TYPE t_style IS RECORD (kind VARCHAR2(10), based_on VARCHAR2(200), ppr PLS_INTEGER, rpr PLS_INTEGER,
                          tblpr PLS_INTEGER, tcpr PLS_INTEGER, cond BOOLEAN := FALSE);
  TYPE t_styles IS TABLE OF t_style INDEX BY VARCHAR2(200);

  -- partial properties: NULL = not set at this level
  TYPE t_rp IS RECORD (font VARCHAR2(100), size_pt NUMBER, bold CHAR(1), italic CHAR(1), underline CHAR(1),
                       color VARCHAR2(6));
  TYPE t_tabop IS RECORD (pos NUMBER, kind CHAR(1));     -- L R D, or X = clear
  TYPE t_tabops IS TABLE OF t_tabop;
  TYPE t_pp IS RECORD (align CHAR(1), ind_left NUMBER, ind_right NUMBER, ind_first NUMBER, space_before NUMBER,
                       space_after NUMBER, line_mult NUMBER, keep_next CHAR(1), break_before CHAR(1),
                       widow CHAR(1), tabs t_tabops := t_tabops());
  -- a table's properties (style chain, then direct): the effective values decide the diagnostics
  TYPE t_tp IS RECORD (borders rad_pdf_ri.t_borders, mar_top NUMBER, mar_bottom NUMBER, mar_left NUMBER,
                       mar_right NUMBER, jc VARCHAR2(20), ind NUMBER, layout VARCHAR2(10));

  -- the model of pass A: containers, blocks, tokens
  TYPE t_obj IS RECORD (
    kind    VARCHAR2(5),                                 -- ZONE CELL PARA TABLE ROW PBRK
    parent  PLS_INTEGER,
    kids    rad_pdf_ri.t_num_list := rad_pdf_ri.t_num_list(),
    zone    VARCHAR2(16),
    para    rad_pdf_ri.t_para_fmt,
    tabs    rad_pdf_ri.t_tab_list,
    t1      PLS_INTEGER,
    t2      PLS_INTEGER,                                 -- tokens t1..t2 (t2 < t1: none)
    grid    rad_pdf_ri.t_num_list,
    borders rad_pdf_ri.t_borders,
    header  CHAR(1),
    cant    CHAR(1),
    cell    rad_pdf_ri.t_cell_fmt,
    part    VARCHAR2(400),
    pos     VARCHAR2(200),
    near    VARCHAR2(100));
  TYPE t_objs IS TABLE OF t_obj INDEX BY PLS_INTEGER;

  TYPE t_tok IS RECORD (
    kind  VARCHAR2(5),                                   -- TEXT TAB BR FIELD IMAGE TAG (PAGE: atoms only)
    text  VARCHAR2(32767),
    fmt   rad_pdf_ri.t_run_fmt,
    code  VARCHAR2(8),
    res   PLS_INTEGER,
    w     NUMBER,
    h     NUMBER,
    op    CHAR(1),                                       -- tag: F field, # open, / close, % image, ? page break
    path  VARCHAR2(400),
    para  PLS_INTEGER,
    reg   PLS_INTEGER,
    scope VARCHAR2(400),
    abs   VARCHAR2(400));
  TYPE t_toks IS TABLE OF t_tok INDEX BY PLS_INTEGER;
  TYPE t_atoms IS TABLE OF t_tok INDEX BY PLS_INTEGER;   -- the atoms of one paragraph, before the tags are found

  TYPE t_reg IS RECORD (
    place   VARCHAR2(10),                                -- ROW PARAGRAPHS INLINE
    kind    VARCHAR2(7),                                 -- LOOP SECTION
    scope   VARCHAR2(400),
    abs     VARCHAR2(400),
    path    VARCHAR2(400),                               -- as written
    o       PLS_INTEGER,
    c       PLS_INTEGER,
    row_id  PLS_INTEGER,
    emitted BOOLEAN := FALSE);
  TYPE t_regs IS TABLE OF t_reg INDEX BY PLS_INTEGER;

  TYPE t_rule IS RECORD (severity VARCHAR2(7), text VARCHAR2(300));
  TYPE t_rules IS TABLE OF t_rule INDEX BY VARCHAR2(30);

  TYPE t_ctx IS RECORD (
    docx      BLOB,
    z         rad_pdf_zip.t_zip,
    sch       t_map,                                     -- schema path -> type
    rules     t_rules,
    res       t_result,
    seen      t_nmap,                                    -- issues already reported (styles: once)
    ct_def    t_map,                                     -- content types by extension
    ct_part   t_map,                                     -- content types by part
    sx        t_els,                                     -- the styles part
    sp        VARCHAR2(400),                             -- its name
    styles    t_styles,
    def_para  VARCHAR2(200),
    def_char  VARCHAR2(200),
    def_table VARCHAR2(200),
    dd_ppr    PLS_INTEGER,
    dd_rpr    PLS_INTEGER,
    major     VARCHAR2(100),
    minor     VARCHAR2(100),
    x         t_els,                                     -- the part being read
    part      VARCHAR2(400),
    rels      t_rels,
    tbl_style VARCHAR2(200),                             -- the table style of the table being read
    objs      t_objs,
    toks      t_toks,
    regs      t_regs,
    images    t_nmap,                                    -- image part -> resource
    text_w    NUMBER,                                    -- the width between the margins
    long      t_strs,                                    -- the pieces of long w:t beyond their first one
    elements  NUMBER := 0,                               -- XML elements read so far
    compat_ts BOOLEAN := FALSE,                          -- settings: overrideTableStyleFontSizeAndJustification
    widow     BOOLEAN := FALSE,                          -- a paragraph with widow control in effect
    even_odd  BOOLEAN := FALSE);

  -- ===========================================================================
  -- the matrix (96a §7.2): the single source of the codes, their severity and their text
  -- ===========================================================================
  FUNCTION rules RETURN t_rules IS
    r t_rules;
    PROCEDURE e(p_code VARCHAR2, p_text VARCHAR2) IS BEGIN r(p_code).severity := 'ERROR'; r(p_code).text := p_text; END;
    PROCEDURE w(p_code VARCHAR2, p_text VARCHAR2) IS BEGIN r(p_code).severity := 'WARNING'; r(p_code).text := p_text; END;
  BEGIN
    -- 96a §7.2, errors
    e('TABLE_CONDITIONAL', 'a table style with conditional formats');
    e('FIELD',             'a field other than PAGE and NUMPAGES');
    e('NESTED_TABLE',      'a table inside a table');
    e('ANCHORED',          'an anchored (floating) image, shape, frame or table: it would be lost');
    e('TEXTBOX',           'a text box: it would be lost');
    e('SECTION',           'a second section or more than one column: it would be lost');
    e('DRAWING',           'SmartArt, a chart, WordArt or a shape');
    e('REVISION',          'tracked changes: accept or reject them first');
    e('COMMENT',           'a comment');
    e('NOTE',              'a footnote or an endnote');
    e('IMAGE_FORMAT',      'an image that is not PNG or JPEG (EMF, WMF, SVG ...)');
    e('RTL',               'right-to-left text');
    -- 96a §6 (tags) and §8 (images), errors
    e('TAG_SYNTAX',        'a "{" that does not start a valid tag (96a §6.1; no escape in v1)');
    e('TAG_PATH',          'a path unknown to the schema (96a §6.3)');
    e('TAG_TYPE',          'a path of the wrong type for its use (96a §6.3)');
    e('TAG_REGION',        'a block that is neither a whole row, whole paragraphs nor inside one paragraph (96a §6.2)');
    e('TAG_BALANCE',       'an opening without its closing, a closing without its opening, or crossed blocks');
    e('TAG_DEPTH',         'loops nested more than 3 deep (96a §8)');
    e('IMAGE_BUDGET',      'an image above 5 MB or 4000 x 4000 px (96a §8)');
    e('IMAGE_EXTERNAL',    'a linked image: external relationships are never followed (96a §8)');
    -- the subset of 96a §7.1 made explicit: anything else is an error, never silently lost
    e('OBJECT',            'an embedded object or a control');
    e('GRID',              'a row that skips grid columns or merges cells horizontally the old way');
    e('ELEMENT',           'an element outside the supported subset');
    -- 96a §7.2, warnings
    w('VMERGE',            'vertically merged cells: drawn as separate cells');
    w('VALIGN',            'vertical alignment in a cell: drawn at the top');
    w('LINE_RULE',         'exact, at-least or automatic spacing: drawn as single spacing');
    w('TAB_LEADER',        'a tab leader or a positional tab: drawn as a plain tab');
    w('TAB_CENTER',        'a centred or bar tab stop: ignored');
    w('HIGHLIGHT',         'highlighting: ignored');
    w('WIDOW',             'widow and orphan control: ignored');
    w('LIST',              'a numbered or bulleted list: drawn without numbers or bullets');
    -- warnings beyond the matrix of 96a v0.3 (proposed in the B4 delivery)
    w('KEEP_LINES',        'keep lines together: ignored');
    w('LINK',              'a hyperlink: drawn as plain text');
    w('ROW_HEIGHT',        'a fixed or minimum row height: ignored');
    w('TABLE_LAYOUT',      'table alignment, indent, cell spacing, autofit, row exceptions or table shading: ignored');
    w('BORDER_STYLE',      'a border style other than single: drawn single');
    w('SHADING',           'a shading pattern, a paragraph border or a paragraph shading: approximated or ignored');
    w('RUN_EFFECT',        'a character effect (caps, strike, super/subscript, spacing, scale, hidden ...): ignored');
    w('CONTEXTUAL',        'contextual spacing: ignored');
    w('SYMBOL',            'a symbol character: omitted');
    w('SECTION_PAGE',      'page numbering start, gutter, page vertical alignment, page borders, line numbers or '
                           || 'even-page headers: ignored');
    w('DEFAULT_TAB',       'a default tab stop other than 36 pt: 36 pt used');
    w('INDENT',            'a negative or character-based indent: clamped or ignored');
    RETURN r;
  END rules;

  FUNCTION matrix_text RETURN CLOB IS
    r t_rules := rules;
    k VARCHAR2(30) := r.FIRST;
    l CLOB;
  BEGIN
    dbms_lob.createtemporary(l, TRUE);
    WHILE k IS NOT NULL LOOP
      dbms_lob.append(l, k || chr(9) || r(k).severity || chr(9) || r(k).text || chr(10));
      k := r.NEXT(k);
    END LOOP;
    RETURN l;
  END matrix_text;

  -- ===========================================================================
  -- small helpers
  -- ===========================================================================
  PROCEDURE refuse(p_msg IN VARCHAR2) IS
  BEGIN
    raise_application_error(c_err_docx, '[PDF_DOCX] ' || p_msg);
  END refuse;

  PROCEDURE over(p_msg IN VARCHAR2) IS
  BEGIN
    raise_application_error(c_err_budget, '[PDF_BUDGET] ' || p_msg);
  END over;

  PROCEDURE issue(c IN OUT NOCOPY t_ctx, p_code IN VARCHAR2, p_detail IN VARCHAR2, p_part IN VARCHAR2,
                  p_pos IN VARCHAR2, p_near IN VARCHAR2 DEFAULT NULL, p_once IN BOOLEAN DEFAULT FALSE) IS
    l t_issue;
    k VARCHAR2(400) := substr(p_code || '|' || p_part || '|' || p_pos || '|' || p_detail, 1, 400);
  BEGIN
    IF p_once AND c.seen.EXISTS(k) THEN RETURN; END IF;
    c.seen(k) := 1;
    l.severity := c.rules(p_code).severity;
    l.code     := p_code;
    l.part     := p_part;
    l.position := substr(p_pos, 1, 200);
    l.near     := substr(p_near, 1, 100);
    l.message  := substr(c.rules(p_code).text || CASE WHEN p_detail IS NOT NULL THEN ' (' || p_detail || ')' END, 1, 1000);
    c.res.report.EXTEND;
    c.res.report(c.res.report.COUNT) := l;
    IF l.severity = 'ERROR' THEN c.res.errors := c.res.errors + 1; ELSE c.res.warnings := c.res.warnings + 1; END IF;
  END issue;

  -- a number written with '.' as the decimal separator, whatever the session
  FUNCTION num(p_v IN VARCHAR2) RETURN NUMBER IS
  BEGIN
    IF p_v IS NULL OR NOT regexp_like(p_v, '^[+-]?[0-9]+(\.[0-9]+)?$') THEN RETURN NULL; END IF;
    RETURN to_number(p_v, '999999999990D9999999999', 'NLS_NUMERIC_CHARACTERS=''.,''');
  END num;

  -- a measure in points: a bare number divided by p_div (20 for twips, 2 for half-points, 8 for eighths, 12700 for
  -- EMU), or a universal measure (mm cm in pt pc pi)
  FUNCTION pts(p_v IN VARCHAR2, p_div IN NUMBER) RETURN NUMBER IS
    l_n NUMBER;
    l_u VARCHAR2(2);
  BEGIN
    IF p_v IS NULL THEN RETURN NULL; END IF;
    l_n := num(p_v);
    IF l_n IS NOT NULL THEN RETURN l_n / p_div; END IF;
    l_u := lower(regexp_substr(p_v, '(mm|cm|in|pt|pc|pi)$'));
    l_n := num(regexp_substr(p_v, '^[+-]?[0-9]+(\.[0-9]+)?'));
    IF l_u IS NULL OR l_n IS NULL THEN RETURN NULL; END IF;
    RETURN CASE l_u WHEN 'mm' THEN l_n * 72 / 25.4 WHEN 'cm' THEN l_n * 72 / 2.54 WHEN 'in' THEN l_n * 72
                    WHEN 'pt' THEN l_n ELSE l_n * 12 END;
  END pts;

  FUNCTION is_el(e IN t_el, p_ns IN VARCHAR2, p_nm IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN e.ns = p_ns AND e.nm = p_nm;
  END is_el;

  FUNCTION attr(e IN t_el, p_name IN VARCHAR2) RETURN VARCHAR2 IS
    l_s VARCHAR2(32767) := ' ' || e.attrs || ' ';
    l_i PLS_INTEGER := instr(l_s, ' ' || p_name || '=');
    l_v VARCHAR2(32767);
  BEGIN
    IF l_i = 0 THEN RETURN NULL; END IF;
    l_i := l_i + length(p_name) + 2;
    l_v := substr(l_s, l_i, instr(l_s, ' ', l_i) - l_i);
    RETURN utl_url.unescape(l_v, 'AL32UTF8');
  END attr;

  -- ST_OnOff: an element present without w:val is on
  FUNCTION onoff(e IN t_el) RETURN CHAR IS
    l_v VARCHAR2(10) := lower(attr(e, 'w:val'));
  BEGIN
    RETURN CASE WHEN l_v IN ('0', 'false', 'off') THEN 'N' ELSE 'Y' END;
  END onoff;

  FUNCTION color(p_v IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF p_v IS NULL OR lower(p_v) = 'auto' OR NOT regexp_like(p_v, '^[0-9A-Fa-f]{6}$') THEN RETURN '000000'; END IF;
    RETURN upper(p_v);
  END color;

  FUNCTION child(x IN t_els, p_i IN PLS_INTEGER, p_ns IN VARCHAR2, p_nm IN VARCHAR2) RETURN PLS_INTEGER IS
    k PLS_INTEGER;
  BEGIN
    IF p_i IS NULL THEN RETURN NULL; END IF;
    k := x(p_i).first;
    WHILE k IS NOT NULL LOOP
      IF x(k).ns = p_ns AND x(k).nm = p_nm THEN RETURN k; END IF;
      k := x(k).nxt;
    END LOOP;
    RETURN NULL;
  END child;

  -- the first descendant (document order: the subtree is the range after p_i of greater depth)
  FUNCTION descendant(x IN t_els, p_i IN PLS_INTEGER, p_ns IN VARCHAR2, p_nm IN VARCHAR2) RETURN PLS_INTEGER IS
    k PLS_INTEGER := p_i + 1;
  BEGIN
    WHILE x.EXISTS(k) AND x(k).depth > x(p_i).depth LOOP
      IF (p_ns IS NULL OR x(k).ns = p_ns) AND x(k).nm = p_nm THEN RETURN k; END IF;
      k := k + 1;
    END LOOP;
    RETURN NULL;
  END descendant;

  -- the text of the w:t under an element, for the "near" of the report
  FUNCTION text_of(x IN t_els, p_i IN PLS_INTEGER) RETURN VARCHAR2 IS
    k PLS_INTEGER := p_i + 1;
    l VARCHAR2(400);
  BEGIN
    WHILE x.EXISTS(k) AND x(k).depth > x(p_i).depth AND nvl(length(l), 0) < 80 LOOP
      IF x(k).ns = 'w' AND x(k).nm = 't' THEN l := substr(l || x(k).txt, 1, 200); END IF;
      k := k + 1;
    END LOOP;
    RETURN substr(l, 1, 80);
  END text_of;

  FUNCTION ns_of(p_uri IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE
      WHEN p_uri = c_ns_w   THEN 'w'
      WHEN p_uri = c_ns_r   THEN 'r'
      WHEN p_uri = c_ns_wp  THEN 'wp'
      WHEN p_uri = c_ns_a   THEN 'a'
      WHEN p_uri = c_ns_pic THEN 'pic'
      WHEN p_uri = c_ns_pr  THEN 'pr'
      WHEN p_uri = c_ns_ct  THEN 'ct'
      WHEN p_uri = c_ns_mc  THEN 'mc'
      WHEN p_uri = c_ns_vml THEN 'v'
      WHEN p_uri LIKE c_ns_ext || '%' THEN 'ext'
      WHEN p_uri LIKE c_ns_strict || '%' THEN 'strict'
      ELSE 'x' END;
  END ns_of;

  -- ===========================================================================
  -- the package: parts, XML, relationships
  -- ===========================================================================
  FUNCTION find_part(c IN t_ctx, p_name IN VARCHAR2) RETURN PLS_INTEGER IS
  BEGIN
    FOR i IN 1 .. c.z.entries.COUNT LOOP
      IF upper(c.z.entries(i).name) = upper(p_name) THEN RETURN i; END IF;      -- OPC part names ignore case
    END LOOP;
    RETURN 0;
  END find_part;

  FUNCTION part_bytes(c IN OUT NOCOPY t_ctx, p_name IN VARCHAR2) RETURN BLOB IS
    l_i PLS_INTEGER := find_part(c, p_name);
  BEGIN
    IF l_i = 0 THEN refuse('part "' || p_name || '" missing'); END IF;
    RETURN rad_pdf_zip.extract(c.docx, c.z, l_i);
  END part_bytes;

  -- one XML part flattened by one XMLTABLE query: no DTD and no entity (refused before parsing), UTF-8 only; the
  -- element count (c_max_elements over the whole read) and the depth (c_max_depth) checked BEFORE the flattening;
  -- a w:t longer than c_chunk characters comes back in pieces (no VARCHAR2 limit on a paragraph)
  FUNCTION load_xml(c IN OUT NOCOPY t_ctx, p_name IN VARCHAR2) RETURN t_els IS
    l_b    BLOB := part_bytes(c, p_name);
    l_x    XMLTYPE;
    l_els  t_els;
    l_head RAW(4);
    l_n    NUMBER;
    l_deep NUMBER;
    TYPE t_row IS RECORD (ord PLS_INTEGER, depth PLS_INTEGER, nm VARCHAR2(100), uri VARCHAR2(300), tlen NUMBER,
                          txt VARCHAR2(32767), attrs VARCHAR2(32767));
    TYPE t_rows IS TABLE OF t_row;
    l_rows  t_rows;
    TYPE t_stack IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    l_stack t_stack;
    l_p     PLS_INTEGER;
    l_long  CLOB;
  BEGIN
    l_head := dbms_lob.substr(l_b, 4, 1);
    IF utl_raw.substr(l_head, 1, 2) IN (hextoraw('FFFE'), hextoraw('FEFF')) THEN
      refuse('part "' || p_name || '" is not UTF-8');
    END IF;
    IF dbms_lob.instr(l_b, utl_raw.cast_to_raw('<!DOCTYPE')) > 0 OR dbms_lob.instr(l_b, utl_raw.cast_to_raw('<!ENTITY')) > 0 THEN
      refuse('part "' || p_name || '" declares a DTD or an entity');
    END IF;
    BEGIN
      l_x := xmltype(l_b, nls_charset_id('AL32UTF8'));
    EXCEPTION
      WHEN OTHERS THEN refuse('part "' || p_name || '" is not well-formed XML (' || substr(sqlerrm, 1, 200) || ')');
    END;
    dbms_lob.freetemporary(l_b);
    -- the budgets first, cheaply: how many elements, and the first one deeper than allowed (found early in a deep
    -- part: the walk stops at it)
    SELECT count(*) INTO l_n FROM xmltable('$x//*' PASSING l_x AS "x");
    c.elements := c.elements + l_n;
    IF c.elements > c_max_elements THEN
      over('more than ' || c_max_elements || ' XML elements (part "' || p_name || '")');
    END IF;
    SELECT count(*) INTO l_deep
      FROM xmltable('($x/descendant::*[count(ancestor::*) > $d])[1]' PASSING l_x AS "x", CAST(c_max_depth AS NUMBER) AS "d");
    IF l_deep > 0 THEN over('part "' || p_name || '" nests XML deeper than ' || c_max_depth); END IF;
    SELECT ord, depth, nm, uri, tlen, txt, attrs BULK COLLECT INTO l_rows
      FROM xmltable('$x//*' PASSING l_x AS "x" COLUMNS
             ord   FOR ORDINALITY,
             depth NUMBER          PATH 'count(ancestor::*)',
             nm    VARCHAR2(100)   PATH 'local-name(.)',
             uri   VARCHAR2(300)   PATH 'namespace-uri(.)',
             tlen  NUMBER          PATH 'if (local-name(.) = ("t", "instrText")) then string-length(.) else 0',
             txt   VARCHAR2(32767) PATH 'if (local-name(.) = ("t", "instrText")) then substring(string(.), 1, 2000) else ""',
             attrs VARCHAR2(32767) PATH 'string-join(for $a in @* return concat(
                 if (namespace-uri($a) = "http://schemas.openxmlformats.org/wordprocessingml/2006/main") then "w:"
                 else if (namespace-uri($a) = "http://schemas.openxmlformats.org/officeDocument/2006/relationships") then "r:"
                 else if (namespace-uri($a) = "http://www.w3.org/XML/1998/namespace") then "xml:"
                 else if (namespace-uri($a) = "") then "" else "x:",
                 local-name($a), "=", encode-for-uri(string($a))), " ")')
     ORDER BY ord;
    FOR i IN 1 .. l_rows.COUNT LOOP
      l_els(i).depth := l_rows(i).depth;
      l_els(i).nm    := l_rows(i).nm;
      l_els(i).uri   := l_rows(i).uri;
      l_els(i).ns    := ns_of(l_rows(i).uri);
      l_els(i).txt   := l_rows(i).txt;
      l_els(i).attrs := l_rows(i).attrs;
      IF l_els(i).ns = 'strict' THEN refuse('Strict Open XML is not supported (part "' || p_name || '")'); END IF;
      IF l_rows(i).tlen > c_chunk THEN
        -- the rest of a long text, read as a CLOB and cut into pieces of c_chunk characters
        SELECT t INTO l_long FROM xmltable('($x//*)[$n]' PASSING l_x AS "x", CAST(l_rows(i).ord AS NUMBER) AS "n"
                                           COLUMNS t CLOB PATH 'string(.)');
        l_els(i).more := rad_pdf_ri.t_num_list();
        FOR j IN 1 .. ceil(l_rows(i).tlen / c_chunk) - 1 LOOP
          c.long(c.long.COUNT + 1) := dbms_lob.substr(l_long, c_chunk, j * c_chunk + 1);
          l_els(i).more.EXTEND;
          l_els(i).more(j) := c.long.COUNT;
        END LOOP;
        dbms_lob.freetemporary(l_long);
      END IF;
      l_stack(l_rows(i).depth) := i;
      IF l_rows(i).depth > 0 THEN
        l_p := l_stack(l_rows(i).depth - 1);
        l_els(i).parent := l_p;
        IF l_els(l_p).first IS NULL THEN l_els(l_p).first := i; ELSE l_els(l_els(l_p).last).nxt := i; END IF;
        l_els(l_p).last := i;
      END IF;
    END LOOP;
    -- the namespaces the root declares ignorable (mc:Ignorable): its prefixes resolved on the root
    IF l_rows.COUNT > 0 THEN
      SELECT ign INTO l_els(1).ign
        FROM xmltable('$x/*' PASSING l_x AS "x" COLUMNS ign VARCHAR2(4000) PATH
               'string-join(for $p in tokenize(normalize-space(string(@*[local-name(.) = "Ignorable" and
                 namespace-uri(.) = "http://schemas.openxmlformats.org/markup-compatibility/2006"])), " ")
                 return string(namespace-uri-for-prefix($p, .)), " ")');
    END IF;
    RETURN l_els;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_b IS NOT NULL AND dbms_lob.istemporary(l_b) = 1 THEN dbms_lob.freetemporary(l_b); END IF;
      IF l_long IS NOT NULL AND dbms_lob.istemporary(l_long) = 1 THEN dbms_lob.freetemporary(l_long); END IF;
      RAISE;
  END load_xml;

  -- a relationship target resolved against the folder of its source part, inside the package
  FUNCTION resolve_target(p_source IN VARCHAR2, p_target IN VARCHAR2) RETURN VARCHAR2 IS
    l_path VARCHAR2(800);
    l_out  VARCHAR2(800);
    l_seg  VARCHAR2(400);
    l_a    PLS_INTEGER := 1;
    l_b    PLS_INTEGER;
  BEGIN
    IF p_target IS NULL OR instr(p_target, '\') > 0 OR regexp_like(p_target, '^[A-Za-z][A-Za-z0-9+.-]*:') THEN
      refuse('relationship target not allowed: "' || substr(p_target, 1, 100) || '"');
    END IF;
    IF substr(p_target, 1, 1) = '/' THEN l_path := substr(p_target, 2);
    ELSE l_path := substr(p_source, 1, instr(p_source, '/', -1)) || p_target;
    END IF;
    l_path := l_path || '/';
    LOOP                                                 -- the segments between the slashes
      l_b := instr(l_path, '/', l_a);
      EXIT WHEN l_b = 0;
      l_seg := substr(l_path, l_a, l_b - l_a);
      l_a := l_b + 1;
      IF l_seg = '..' THEN
        IF l_out IS NULL THEN refuse('relationship target outside the package: "' || substr(p_target, 1, 100) || '"'); END IF;
        l_out := CASE WHEN instr(l_out, '/', -1) > 0 THEN substr(l_out, 1, instr(l_out, '/', -1) - 1) END;
      ELSIF l_seg IS NOT NULL AND l_seg <> '.' THEN
        l_out := CASE WHEN l_out IS NULL THEN l_seg ELSE l_out || '/' || l_seg END;
      END IF;
    END LOOP;
    RETURN l_out;
  END resolve_target;

  -- the relationships of a part (its _rels/<name>.rels), none when the part has none
  FUNCTION load_rels(c IN OUT NOCOPY t_ctx, p_source IN VARCHAR2) RETURN t_rels IS
    l_name VARCHAR2(800) := substr(p_source, 1, instr(p_source, '/', -1)) || '_rels/'
                            || substr(p_source, instr(p_source, '/', -1) + 1) || '.rels';
    l_x    t_els;
    l_r    t_rels;
    l_rel  t_rel;
    k      PLS_INTEGER;
  BEGIN
    IF p_source IS NULL THEN l_name := '_rels/.rels'; END IF;
    IF find_part(c, l_name) = 0 THEN RETURN l_r; END IF;
    l_x := load_xml(c, l_name);
    k := l_x(1).first;
    WHILE k IS NOT NULL LOOP
      IF is_el(l_x(k), 'pr', 'Relationship') THEN
        l_rel.kind := attr(l_x(k), 'Type');
        l_rel.external := CASE WHEN attr(l_x(k), 'TargetMode') = 'External' THEN TRUE ELSE FALSE END;
        -- an external target is recorded, never resolved nor followed
        l_rel.target := CASE WHEN l_rel.external THEN attr(l_x(k), 'Target')
                             ELSE resolve_target(nvl(p_source, '/'), attr(l_x(k), 'Target')) END;
        IF l_r.EXISTS(attr(l_x(k), 'Id')) THEN refuse('duplicate relationship id in "' || l_name || '"'); END IF;
        l_r(attr(l_x(k), 'Id')) := l_rel;
      END IF;
      k := l_x(k).nxt;
    END LOOP;
    RETURN l_r;
  END load_rels;

  FUNCTION rel_kind(p_type IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN substr(p_type, instr(p_type, '/', -1) + 1);
  END rel_kind;

  -- the first relationship of a kind ('styles', 'theme' ...), its target part
  FUNCTION rel_target(r IN t_rels, p_kind IN VARCHAR2) RETURN VARCHAR2 IS
    k VARCHAR2(200) := r.FIRST;
  BEGIN
    WHILE k IS NOT NULL LOOP
      IF rel_kind(r(k).kind) = p_kind AND NOT r(k).external THEN RETURN r(k).target; END IF;
      k := r.NEXT(k);
    END LOOP;
    RETURN NULL;
  END rel_target;

  FUNCTION content_type(c IN t_ctx, p_part IN VARCHAR2) RETURN VARCHAR2 IS
    l_ext VARCHAR2(100) := lower(substr(p_part, instr(p_part, '.', -1) + 1));
  BEGIN
    IF c.ct_part.EXISTS(upper(p_part)) THEN RETURN c.ct_part(upper(p_part)); END IF;
    IF c.ct_def.EXISTS(l_ext) THEN RETURN c.ct_def(l_ext); END IF;
    RETURN NULL;
  END content_type;

  -- the package as a whole: content types, no macro, no embedded object, no active content
  PROCEDURE check_package(c IN OUT NOCOPY t_ctx) IS
    l_x t_els;
    k   PLS_INTEGER;
    l_n VARCHAR2(400);
    l_t VARCHAR2(400);
  BEGIN
    IF find_part(c, '[Content_Types].xml') = 0 THEN refuse('not an OPC package: [Content_Types].xml missing'); END IF;
    l_x := load_xml(c, '[Content_Types].xml');
    k := l_x(1).first;
    WHILE k IS NOT NULL LOOP
      IF is_el(l_x(k), 'ct', 'Default') THEN
        c.ct_def(lower(attr(l_x(k), 'Extension'))) := attr(l_x(k), 'ContentType');
      ELSIF is_el(l_x(k), 'ct', 'Override') THEN
        c.ct_part(upper(ltrim(attr(l_x(k), 'PartName'), '/'))) := attr(l_x(k), 'ContentType');
      END IF;
      k := l_x(k).nxt;
    END LOOP;
    FOR i IN 1 .. c.z.entries.COUNT LOOP
      l_n := lower(c.z.entries(i).name);
      l_t := lower(content_type(c, c.z.entries(i).name));
      IF l_n LIKE '%vbaproject%' OR l_n LIKE '%vbadata%' OR l_t LIKE '%macroenabled%' OR l_t LIKE '%vbaproject%' THEN
        refuse('a macro (part "' || c.z.entries(i).name || '")');
      END IF;
      IF l_n LIKE '%/embeddings/%' OR l_t LIKE '%oleobject%' OR l_t LIKE '%package' THEN
        refuse('an embedded object (part "' || c.z.entries(i).name || '")');
      END IF;
      IF l_n LIKE '%/activex/%' OR l_t LIKE '%activex%' THEN
        refuse('active content (part "' || c.z.entries(i).name || '")');
      END IF;
    END LOOP;
  END check_package;

  -- ===========================================================================
  -- styles and theme
  -- ===========================================================================
  PROCEDURE load_theme(c IN OUT NOCOPY t_ctx, p_part IN VARCHAR2) IS
    l_x t_els;
    k   PLS_INTEGER;
  BEGIN
    IF p_part IS NULL OR find_part(c, p_part) = 0 THEN RETURN; END IF;
    l_x := load_xml(c, p_part);
    k := descendant(l_x, 1, 'a', 'majorFont');
    IF k IS NOT NULL THEN c.major := attr(l_x(child(l_x, k, 'a', 'latin')), 'typeface'); END IF;
    k := descendant(l_x, 1, 'a', 'minorFont');
    IF k IS NOT NULL THEN c.minor := attr(l_x(child(l_x, k, 'a', 'latin')), 'typeface'); END IF;
  EXCEPTION
    WHEN value_error OR no_data_found THEN NULL;         -- a theme without latin fonts: no theme font
  END load_theme;

  PROCEDURE load_styles(c IN OUT NOCOPY t_ctx, p_part IN VARCHAR2) IS
    k   PLS_INTEGER;
    d   PLS_INTEGER;
    s   t_style;
    l_id VARCHAR2(200);
  BEGIN
    IF p_part IS NULL OR find_part(c, p_part) = 0 THEN RETURN; END IF;
    c.sx := load_xml(c, p_part);
    k := c.sx(1).first;
    WHILE k IS NOT NULL LOOP
      IF is_el(c.sx(k), 'w', 'docDefaults') THEN
        d := child(c.sx, k, 'w', 'rPrDefault');
        c.dd_rpr := child(c.sx, d, 'w', 'rPr');
        d := child(c.sx, k, 'w', 'pPrDefault');
        c.dd_ppr := child(c.sx, d, 'w', 'pPr');
      ELSIF is_el(c.sx(k), 'w', 'style') THEN
        s := NULL;
        s.cond := FALSE;
        l_id := attr(c.sx(k), 'w:styleId');
        s.kind := attr(c.sx(k), 'w:type');
        IF child(c.sx, k, 'w', 'basedOn') IS NOT NULL THEN s.based_on := attr(c.sx(child(c.sx, k, 'w', 'basedOn')), 'w:val'); END IF;
        s.ppr := child(c.sx, k, 'w', 'pPr');
        s.rpr := child(c.sx, k, 'w', 'rPr');
        s.tblpr := child(c.sx, k, 'w', 'tblPr');
        s.tcpr := child(c.sx, k, 'w', 'tcPr');
        s.cond := child(c.sx, k, 'w', 'tblStylePr') IS NOT NULL;
        IF l_id IS NOT NULL THEN c.styles(l_id) := s; END IF;
        IF onoff(c.sx(k)) = 'Y' AND attr(c.sx(k), 'w:default') IN ('1', 'true', 'on') THEN
          CASE s.kind WHEN 'paragraph' THEN c.def_para := l_id; WHEN 'character' THEN c.def_char := l_id;
                      WHEN 'table' THEN c.def_table := l_id; ELSE NULL; END CASE;
        END IF;
      END IF;
      k := c.sx(k).nxt;
    END LOOP;
  END load_styles;

  -- ---------------------------------------------------------------------------
  -- property layers: each procedure lays the properties of one element over the ones in hand, and reports the
  -- elements it does not support (p_once for styles: one report per style)
  -- ---------------------------------------------------------------------------
  -- ---------------------------------------------------------------------------
  -- property layers: one procedure per property element (rPr, pPr, tblPr, tcPr, borders, margins), the SAME for a
  -- style and for direct formatting; each lays its element over the properties in hand and classifies EVERY child:
  -- applied, ignored (no visible effect), a WARNING or an ERROR. p_once: a style reports once.
  -- ---------------------------------------------------------------------------

  -- an element of a Word extension namespace (w14, w15 ...): ignorable only when the part declares its namespace
  -- in mc:Ignorable AND the element is a known one; a known text effect is a warning; anything else is an ERROR
  -- (an unknown container may hold text that would vanish)
  PROCEDURE ext_issue(c IN OUT NOCOPY t_ctx, x IN t_els, p_k IN PLS_INTEGER, p_part VARCHAR2, p_pos VARCHAR2,
                      p_near VARCHAR2, p_once BOOLEAN) IS
    l_ign BOOLEAN := instr(' ' || x(1).ign || ' ', ' ' || x(p_k).uri || ' ') > 0;
  BEGIN
    IF l_ign AND x(p_k).nm IN ('ligatures', 'numForm', 'numSpacing', 'stylisticSets', 'cntxtAlts', 'collapsed',
                                'footnoteColumns', 'conflictMode') THEN
      NULL;
    ELSIF l_ign AND x(p_k).nm IN ('glow', 'shadow', 'reflection', 'textOutline', 'textFill', 'props3d', 'scene3d') THEN
      issue(c, 'RUN_EFFECT', x(p_k).nm, p_part, p_pos, p_near, TRUE);
    ELSE
      issue(c, 'ELEMENT', CASE WHEN l_ign THEN 'unknown extension ' ELSE 'extension not declared ignorable ' END
                          || x(p_k).nm || ' {' || x(p_k).uri || '}', p_part, p_pos, p_near, p_once);
    END IF;
  END ext_issue;

  -- the common head of every classifier: TRUE when the child is dealt with here (extension, foreign, revision)
  FUNCTION other_child(c IN OUT NOCOPY t_ctx, x IN t_els, p_k IN PLS_INTEGER, p_part VARCHAR2, p_pos VARCHAR2,
                       p_near VARCHAR2, p_once BOOLEAN) RETURN BOOLEAN;

  FUNCTION is_revision(e IN t_el) RETURN BOOLEAN IS
  BEGIN
    RETURN e.ns = 'w' AND e.nm IN ('ins', 'del', 'moveFrom', 'moveTo', 'rPrChange', 'pPrChange', 'tblPrChange',
                                    'tcPrChange', 'trPrChange', 'sectPrChange', 'tblGridChange', 'cellIns', 'cellDel',
                                    'cellMerge', 'numberingChange', 'moveFromRangeStart', 'moveFromRangeEnd',
                                    'moveToRangeStart', 'moveToRangeEnd', 'tblPrExChange');
  END is_revision;

  FUNCTION other_child(c IN OUT NOCOPY t_ctx, x IN t_els, p_k IN PLS_INTEGER, p_part VARCHAR2, p_pos VARCHAR2,
                       p_near VARCHAR2, p_once BOOLEAN) RETURN BOOLEAN IS
  BEGIN
    IF x(p_k).ns = 'ext' THEN ext_issue(c, x, p_k, p_part, p_pos, p_near, p_once); RETURN TRUE; END IF;
    IF x(p_k).ns <> 'w' THEN
      issue(c, CASE WHEN x(p_k).ns = 'mc' THEN 'DRAWING' ELSE 'ELEMENT' END, x(p_k).ns || ':' || x(p_k).nm,
            p_part, p_pos, p_near, p_once);
      RETURN TRUE;
    END IF;
    IF is_revision(x(p_k)) THEN issue(c, 'REVISION', 'w:' || x(p_k).nm, p_part, p_pos, p_near, p_once); RETURN TRUE; END IF;
    RETURN FALSE;
  END other_child;

  PROCEDURE border_of(c IN OUT NOCOPY t_ctx, x IN t_els, p_i IN PLS_INTEGER, b IN OUT NOCOPY rad_pdf_ri.t_border,
                      p_part VARCHAR2, p_pos VARCHAR2) IS
    l_v VARCHAR2(30) := attr(x(p_i), 'w:val');
  BEGIN
    IF l_v IN ('nil', 'none') THEN b.style := 'NONE'; b.width := 0; b.color := '000000'; RETURN; END IF;
    IF l_v <> 'single' THEN issue(c, 'BORDER_STYLE', l_v, p_part, p_pos, NULL, TRUE); END IF;
    b.style := 'SINGLE';
    b.width := nvl(pts(attr(x(p_i), 'w:sz'), 8), 0.5);
    b.color := color(attr(x(p_i), 'w:color'));
  END border_of;

  PROCEDURE borders_of(c IN OUT NOCOPY t_ctx, x IN t_els, p_i IN PLS_INTEGER, b IN OUT NOCOPY rad_pdf_ri.t_borders,
                       p_part VARCHAR2, p_pos VARCHAR2, p_once BOOLEAN) IS
    k PLS_INTEGER;
  BEGIN
    IF p_i IS NULL THEN RETURN; END IF;
    k := x(p_i).first;
    WHILE k IS NOT NULL LOOP
      IF NOT other_child(c, x, k, p_part, p_pos, NULL, p_once) THEN
        CASE
          WHEN x(k).nm = 'top' THEN border_of(c, x, k, b.top, p_part, p_pos);
          WHEN x(k).nm = 'bottom' THEN border_of(c, x, k, b.bottom, p_part, p_pos);
          WHEN x(k).nm IN ('left', 'start') THEN border_of(c, x, k, b.lft, p_part, p_pos);
          WHEN x(k).nm IN ('right', 'end') THEN border_of(c, x, k, b.rgt, p_part, p_pos);
          WHEN x(k).nm = 'insideH' THEN border_of(c, x, k, b.inside_h, p_part, p_pos);
          WHEN x(k).nm = 'insideV' THEN border_of(c, x, k, b.inside_v, p_part, p_pos);
          WHEN x(k).nm IN ('tl2br', 'tr2bl') THEN issue(c, 'BORDER_STYLE', 'diagonal', p_part, p_pos, NULL, TRUE);
          ELSE issue(c, 'ELEMENT', 'w:' || x(k).nm || ' in borders', p_part, p_pos, NULL, p_once);
        END CASE;
      END IF;
      k := x(k).nxt;
    END LOOP;
  END borders_of;

  -- tblCellMar / tcMar: twips (dxa) only; another unit is approximated as nothing
  PROCEDURE margins_of(c IN OUT NOCOPY t_ctx, x IN t_els, p_i IN PLS_INTEGER, t IN OUT NOCOPY t_tp,
                       p_part VARCHAR2, p_pos VARCHAR2, p_once BOOLEAN) IS
    k PLS_INTEGER;
    v NUMBER;
  BEGIN
    IF p_i IS NULL THEN RETURN; END IF;
    k := x(p_i).first;
    WHILE k IS NOT NULL LOOP
      IF NOT other_child(c, x, k, p_part, p_pos, NULL, p_once) THEN
        IF x(k).nm NOT IN ('top', 'bottom', 'left', 'start', 'right', 'end') THEN
          issue(c, 'ELEMENT', 'w:' || x(k).nm || ' in cell margins', p_part, p_pos, NULL, p_once);
        ELSIF nvl(attr(x(k), 'w:type'), 'dxa') <> 'dxa' THEN
          issue(c, 'TABLE_LAYOUT', 'cell margin of type ' || attr(x(k), 'w:type'), p_part, p_pos, NULL, TRUE);
        ELSE
          v := pts(attr(x(k), 'w:w'), 20);
          CASE
            WHEN x(k).nm = 'top' THEN t.mar_top := v;
            WHEN x(k).nm = 'bottom' THEN t.mar_bottom := v;
            WHEN x(k).nm IN ('left', 'start') THEN t.mar_left := v;
            ELSE t.mar_right := v;
          END CASE;
        END IF;
      END IF;
      k := x(k).nxt;
    END LOOP;
  END margins_of;

  -- a toggle property (b, i: ECMA-376 §17.7.3): absolute in docDefaults and in direct formatting; in a table or a
  -- character style ('T') a true value flips the state reached so far and a false one leaves it; in a paragraph style
  -- ('P') Word sets the state to the value given ([MS-OI29500] 2.1.258, Part 1 §17.7.8), so it is absolute there too
  PROCEDURE toggle(p_cur IN OUT CHAR, e IN t_el, p_mode IN CHAR) IS
  BEGIN
    IF p_mode = 'T' THEN
      IF onoff(e) = 'Y' THEN p_cur := CASE nvl(p_cur, 'N') WHEN 'Y' THEN 'N' ELSE 'Y' END; END IF;
    ELSE
      p_cur := onoff(e);
    END IF;
  END toggle;

  -- rPr; p_mode: D direct or docDefaults, P paragraph style, T table or character style
  -- p_mark: the paragraph mark's properties (pPr/rPr): the same classification, without the warnings of effects
  -- that are never drawn
  PROCEDURE rpr_of(c IN OUT NOCOPY t_ctx, x IN t_els, p_i IN PLS_INTEGER, r IN OUT NOCOPY t_rp, p_mode IN CHAR,
                   p_part VARCHAR2, p_pos VARCHAR2, p_near VARCHAR2, p_once BOOLEAN, p_mark BOOLEAN DEFAULT FALSE) IS
    k   PLS_INTEGER;
    l_t VARCHAR2(100);
    l_u VARCHAR2(30);
  BEGIN
    IF p_i IS NULL THEN RETURN; END IF;
    k := x(p_i).first;
    WHILE k IS NOT NULL LOOP
      IF NOT other_child(c, x, k, p_part, p_pos, p_near, p_once) THEN
        CASE x(k).nm
          WHEN 'rStyle' THEN NULL;                         -- the character style: applied by the caller, before
          WHEN 'rFonts' THEN
            l_t := attr(x(k), 'w:asciiTheme');
            IF l_t IS NOT NULL THEN
              r.font := CASE WHEN l_t LIKE 'major%' THEN c.major ELSE c.minor END;
            ELSIF attr(x(k), 'w:ascii') IS NOT NULL THEN
              r.font := attr(x(k), 'w:ascii');
            END IF;
          WHEN 'b' THEN toggle(r.bold, x(k), p_mode);
          WHEN 'i' THEN toggle(r.italic, x(k), p_mode);
          WHEN 'u' THEN
            l_u := nvl(attr(x(k), 'w:val'), 'single');
            r.underline := CASE WHEN l_u = 'none' THEN 'N' ELSE 'Y' END;
            IF l_u NOT IN ('none', 'single', 'words') AND NOT p_mark THEN issue(c, 'RUN_EFFECT', 'underline ' || l_u, p_part, p_pos, p_near, TRUE); END IF;
          WHEN 'color' THEN r.color := color(attr(x(k), 'w:val'));
          WHEN 'sz' THEN r.size_pt := pts(attr(x(k), 'w:val'), 2);
          WHEN 'highlight' THEN
            IF attr(x(k), 'w:val') <> 'none' AND NOT p_mark THEN issue(c, 'HIGHLIGHT', NULL, p_part, p_pos, p_near, TRUE); END IF;
          WHEN 'rtl' THEN
            IF onoff(x(k)) = 'Y' AND NOT p_mark THEN issue(c, 'RTL', NULL, p_part, p_pos, p_near, p_once); END IF;
          ELSE
            IF x(k).nm IN ('bCs', 'iCs', 'szCs', 'lang', 'noProof', 'webHidden', 'specVanish', 'kern', 'cs',
                           'eastAsianLayout', 'snapToGrid', 'oMath') THEN
              NULL;                                        -- no visible effect on Latin text
            ELSIF x(k).nm IN ('caps', 'smallCaps', 'strike', 'dstrike', 'vertAlign', 'spacing', 'position', 'w',
                              'effect', 'shadow', 'outline', 'emboss', 'imprint', 'bdr', 'shd', 'em', 'fitText',
                              'vanish') THEN
              IF NOT (x(k).nm IN ('caps', 'smallCaps', 'strike', 'dstrike', 'shadow', 'outline', 'emboss', 'imprint',
                                  'vanish') AND onoff(x(k)) = 'N')
                 AND NOT (x(k).nm = 'vertAlign' AND attr(x(k), 'w:val') = 'baseline') AND NOT p_mark THEN
                issue(c, 'RUN_EFFECT', 'w:' || x(k).nm, p_part, p_pos, p_near, TRUE);
              END IF;
            ELSE
              issue(c, 'ELEMENT', 'w:' || x(k).nm || ' in a run format', p_part, p_pos, p_near, p_once);
            END IF;
        END CASE;
      END IF;
      k := x(k).nxt;
    END LOOP;
  END rpr_of;

  PROCEDURE tabs_of(c IN OUT NOCOPY t_ctx, x IN t_els, p_i IN PLS_INTEGER, p IN OUT NOCOPY t_pp,
                    p_part VARCHAR2, p_pos VARCHAR2, p_near VARCHAR2, p_once BOOLEAN) IS
    k   PLS_INTEGER;
    l_v VARCHAR2(20);
    l_o t_tabop;
  BEGIN
    k := x(p_i).first;
    WHILE k IS NOT NULL LOOP
      IF other_child(c, x, k, p_part, p_pos, p_near, p_once) THEN NULL;
      ELSIF x(k).nm <> 'tab' THEN issue(c, 'ELEMENT', 'w:' || x(k).nm || ' in tab stops', p_part, p_pos, p_near, p_once);
      ELSE
        l_v := attr(x(k), 'w:val');
        l_o.pos := pts(attr(x(k), 'w:pos'), 20);
        l_o.kind := CASE WHEN l_v IN ('left', 'start') THEN 'L' WHEN l_v IN ('right', 'end') THEN 'R'
                         WHEN l_v = 'decimal' THEN 'D' WHEN l_v = 'clear' THEN 'X' END;
        IF l_o.kind IS NULL THEN issue(c, 'TAB_CENTER', l_v, p_part, p_pos, p_near, TRUE); END IF;
        IF nvl(attr(x(k), 'w:leader'), 'none') <> 'none' AND l_o.kind <> 'X' THEN
          issue(c, 'TAB_LEADER', attr(x(k), 'w:leader'), p_part, p_pos, p_near, TRUE);
        END IF;
        IF l_o.kind IS NOT NULL AND l_o.pos IS NOT NULL THEN p.tabs.EXTEND; p.tabs(p.tabs.COUNT) := l_o; END IF;
      END IF;
      k := x(k).nxt;
    END LOOP;
  END tabs_of;

  PROCEDURE ppr_of(c IN OUT NOCOPY t_ctx, x IN t_els, p_i IN PLS_INTEGER, p IN OUT NOCOPY t_pp,
                   p_part VARCHAR2, p_pos VARCHAR2, p_near VARCHAR2, p_once BOOLEAN) IS
    k   PLS_INTEGER;
    l_v VARCHAR2(30);
    l_n NUMBER;
    q   PLS_INTEGER;
  BEGIN
    IF p_i IS NULL THEN RETURN; END IF;
    k := x(p_i).first;
    WHILE k IS NOT NULL LOOP
      IF NOT other_child(c, x, k, p_part, p_pos, p_near, p_once) THEN
        CASE x(k).nm
          WHEN 'pStyle' THEN NULL;                         -- read by the caller
          WHEN 'keepNext' THEN p.keep_next := onoff(x(k));
          WHEN 'pageBreakBefore' THEN p.break_before := onoff(x(k));
          WHEN 'widowControl' THEN p.widow := onoff(x(k));   -- reported on its effective value (final_para)
          WHEN 'jc' THEN
            l_v := attr(x(k), 'w:val');
            p.align := CASE WHEN l_v IN ('left', 'start') THEN 'L' WHEN l_v = 'center' THEN 'C'
                            WHEN l_v IN ('right', 'end') THEN 'R' ELSE 'J' END;
          WHEN 'spacing' THEN
            IF attr(x(k), 'w:before') IS NOT NULL THEN p.space_before := pts(attr(x(k), 'w:before'), 20); END IF;
            IF attr(x(k), 'w:after') IS NOT NULL THEN p.space_after := pts(attr(x(k), 'w:after'), 20); END IF;
            IF attr(x(k), 'w:line') IS NOT NULL THEN
              IF nvl(attr(x(k), 'w:lineRule'), 'auto') = 'auto' THEN
                p.line_mult := num(attr(x(k), 'w:line')) / 240;
              ELSE
                p.line_mult := 1;
                issue(c, 'LINE_RULE', attr(x(k), 'w:lineRule'), p_part, p_pos, p_near, TRUE);
              END IF;
            END IF;
            IF attr(x(k), 'w:beforeLines') IS NOT NULL OR attr(x(k), 'w:afterLines') IS NOT NULL
               OR lower(attr(x(k), 'w:beforeAutospacing')) IN ('1', 'true', 'on')
               OR lower(attr(x(k), 'w:afterAutospacing')) IN ('1', 'true', 'on') THEN
              issue(c, 'LINE_RULE', 'spacing in lines or automatic', p_part, p_pos, p_near, TRUE);
            END IF;
          WHEN 'ind' THEN
            l_n := pts(nvl(attr(x(k), 'w:start'), attr(x(k), 'w:left')), 20);
            IF l_n IS NOT NULL THEN p.ind_left := l_n; END IF;
            l_n := pts(nvl(attr(x(k), 'w:end'), attr(x(k), 'w:right')), 20);
            IF l_n IS NOT NULL THEN p.ind_right := l_n; END IF;
            IF attr(x(k), 'w:hanging') IS NOT NULL THEN p.ind_first := -pts(attr(x(k), 'w:hanging'), 20);
            ELSIF attr(x(k), 'w:firstLine') IS NOT NULL THEN p.ind_first := pts(attr(x(k), 'w:firstLine'), 20);
            END IF;
            IF attr(x(k), 'w:startChars') IS NOT NULL OR attr(x(k), 'w:leftChars') IS NOT NULL
               OR attr(x(k), 'w:hangingChars') IS NOT NULL OR attr(x(k), 'w:firstLineChars') IS NOT NULL THEN
              issue(c, 'INDENT', 'indent in characters', p_part, p_pos, p_near, TRUE);
            END IF;
          WHEN 'tabs' THEN tabs_of(c, x, k, p, p_part, p_pos, p_near, p_once);
          WHEN 'rPr' THEN                                  -- the paragraph mark: classified like a run's, never drawn
            DECLARE l_mark t_rp; BEGIN
              rpr_of(c, x, k, l_mark, 'D', p_part, p_pos, p_near, p_once, TRUE);
            END;
          WHEN 'sectPr' THEN issue(c, 'SECTION', 'a section break', p_part, p_pos, p_near, p_once);
          WHEN 'numPr' THEN issue(c, 'LIST', NULL, p_part, p_pos, p_near, TRUE);
          WHEN 'keepLines' THEN
            IF onoff(x(k)) = 'Y' THEN issue(c, 'KEEP_LINES', NULL, p_part, p_pos, p_near, TRUE); END IF;
          WHEN 'contextualSpacing' THEN
            IF onoff(x(k)) = 'Y' THEN issue(c, 'CONTEXTUAL', NULL, p_part, p_pos, p_near, TRUE); END IF;
          WHEN 'framePr' THEN issue(c, 'ANCHORED', 'a frame', p_part, p_pos, p_near, p_once);
          WHEN 'bidi' THEN
            IF onoff(x(k)) = 'Y' THEN issue(c, 'RTL', NULL, p_part, p_pos, p_near, p_once); END IF;
          WHEN 'textDirection' THEN issue(c, 'RTL', 'text direction', p_part, p_pos, p_near, p_once);
          ELSE
            IF x(k).nm IN ('pBdr', 'shd') THEN
              issue(c, 'SHADING', 'w:' || x(k).nm, p_part, p_pos, p_near, TRUE);
            ELSIF x(k).nm NOT IN ('outlineLvl', 'snapToGrid', 'suppressAutoHyphens', 'adjustRightInd', 'autoSpaceDE',
                                  'autoSpaceDN', 'kinsoku', 'wordWrap', 'overflowPunct', 'topLinePunct',
                                  'textAlignment', 'suppressLineNumbers', 'mirrorIndents', 'suppressOverlap',
                                  'cnfStyle', 'divId', 'textboxTightWrap') THEN
              issue(c, 'ELEMENT', 'w:' || x(k).nm || ' in a paragraph format', p_part, p_pos, p_near, p_once);
            END IF;
        END CASE;
      END IF;
      k := x(k).nxt;
    END LOOP;
  END ppr_of;

  -- tblPr, of a table style or of a table: the same classification; jc, tblInd and tblLayout are judged on their
  -- effective values by the caller
  PROCEDURE tblpr_of(c IN OUT NOCOPY t_ctx, x IN t_els, p_i IN PLS_INTEGER, t IN OUT NOCOPY t_tp,
                     p_part VARCHAR2, p_pos VARCHAR2, p_near VARCHAR2, p_once BOOLEAN) IS
    k PLS_INTEGER;
  BEGIN
    IF p_i IS NULL THEN RETURN; END IF;
    k := x(p_i).first;
    WHILE k IS NOT NULL LOOP
      IF NOT other_child(c, x, k, p_part, p_pos, p_near, p_once) THEN
        CASE x(k).nm
          WHEN 'tblBorders' THEN borders_of(c, x, k, t.borders, p_part, p_pos, p_once);
          WHEN 'tblCellMar' THEN margins_of(c, x, k, t, p_part, p_pos, p_once);
          WHEN 'jc' THEN t.jc := nvl(attr(x(k), 'w:val'), 'left');
          WHEN 'tblInd' THEN
            t.ind := CASE WHEN nvl(attr(x(k), 'w:type'), 'dxa') = 'dxa' THEN nvl(pts(attr(x(k), 'w:w'), 20), 0) ELSE 1 END;
          WHEN 'tblLayout' THEN t.layout := nvl(attr(x(k), 'w:type'), 'autofit');
          WHEN 'tblpPr' THEN issue(c, 'ANCHORED', 'a floating table', p_part, p_pos, p_near, p_once);
          WHEN 'bidiVisual' THEN
            IF onoff(x(k)) = 'Y' THEN issue(c, 'RTL', 'a right-to-left table', p_part, p_pos, p_near, p_once); END IF;
          WHEN 'tblCellSpacing' THEN issue(c, 'TABLE_LAYOUT', 'cell spacing', p_part, p_pos, p_near, TRUE);
          WHEN 'shd' THEN issue(c, 'TABLE_LAYOUT', 'table shading', p_part, p_pos, p_near, TRUE);
          ELSE
            IF x(k).nm NOT IN ('tblStyle', 'tblW', 'tblLook', 'tblCaption', 'tblDescription', 'tblStyleRowBandSize',
                               'tblStyleColBandSize', 'tblOverlap') THEN
              issue(c, 'ELEMENT', 'w:' || x(k).nm || ' in a table format', p_part, p_pos, p_near, p_once);
            END IF;
        END CASE;
      END IF;
      k := x(k).nxt;
    END LOOP;
  END tblpr_of;

  -- tcPr, of a table style (the default of every cell) or of a cell; p_width: the dxa width of tcW (cells only)
  PROCEDURE tcpr_of(c IN OUT NOCOPY t_ctx, x IN t_els, p_i IN PLS_INTEGER, f IN OUT NOCOPY rad_pdf_ri.t_cell_fmt,
                    p_width OUT NUMBER, p_part VARCHAR2, p_pos VARCHAR2, p_near VARCHAR2, p_once BOOLEAN) IS
    k   PLS_INTEGER;
    l_v VARCHAR2(40);
    t   t_tp;
  BEGIN
    IF p_i IS NULL THEN RETURN; END IF;
    k := x(p_i).first;
    WHILE k IS NOT NULL LOOP
      IF NOT other_child(c, x, k, p_part, p_pos, p_near, p_once) THEN
        CASE x(k).nm
          WHEN 'gridSpan' THEN f.grid_span := nvl(num(attr(x(k), 'w:val')), 1);
          WHEN 'tcW' THEN
            IF nvl(attr(x(k), 'w:type'), 'dxa') = 'dxa' AND pts(attr(x(k), 'w:w'), 20) > 0 THEN
              p_width := pts(attr(x(k), 'w:w'), 20);
            END IF;
          WHEN 'tcBorders' THEN borders_of(c, x, k, f.borders, p_part, p_pos, p_once);
          WHEN 'shd' THEN
            l_v := attr(x(k), 'w:fill');
            IF l_v IS NOT NULL AND lower(l_v) <> 'auto' THEN f.shading := color(l_v); END IF;
            IF nvl(attr(x(k), 'w:val'), 'clear') NOT IN ('clear', 'nil') THEN
              issue(c, 'SHADING', 'pattern ' || attr(x(k), 'w:val'), p_part, p_pos, p_near, TRUE);
            END IF;
          WHEN 'tcMar' THEN
            margins_of(c, x, k, t, p_part, p_pos, p_once);
            f.mar_top := nvl(t.mar_top, f.mar_top); f.mar_bottom := nvl(t.mar_bottom, f.mar_bottom);
            f.mar_left := nvl(t.mar_left, f.mar_left); f.mar_right := nvl(t.mar_right, f.mar_right);
          WHEN 'vMerge' THEN issue(c, 'VMERGE', NULL, p_part, p_pos, p_near);
          WHEN 'vAlign' THEN
            IF nvl(attr(x(k), 'w:val'), 'top') <> 'top' THEN issue(c, 'VALIGN', NULL, p_part, p_pos, p_near); END IF;
          WHEN 'hMerge' THEN issue(c, 'GRID', 'w:hMerge', p_part, p_pos, p_near, p_once);
          WHEN 'textDirection' THEN
            IF nvl(attr(x(k), 'w:val'), 'lrTb') NOT IN ('lrTb', 'tb') THEN
              issue(c, 'RTL', 'text direction', p_part, p_pos, p_near, p_once);
            END IF;
          ELSE
            IF x(k).nm NOT IN ('noWrap', 'tcFitText', 'hideMark', 'cnfStyle', 'headers') THEN
              issue(c, 'ELEMENT', 'w:' || x(k).nm || ' in a cell format', p_part, p_pos, p_near, p_once);
            END IF;
        END CASE;
      END IF;
      k := x(k).nxt;
    END LOOP;
  END tcpr_of;

  -- one style and its basedOn chain (the chain first): the same visit for the three kinds; p_kind decides the
  -- toggle mode of its runs (P for a paragraph style, T for a table or character style) and the parts it reads
  PROCEDURE apply_style(c IN OUT NOCOPY t_ctx, p_id IN VARCHAR2, p_kind IN VARCHAR2, p IN OUT NOCOPY t_pp,
                        r IN OUT NOCOPY t_rp, t IN OUT NOCOPY t_tp, f IN OUT NOCOPY rad_pdf_ri.t_cell_fmt,
                        p_depth IN PLS_INTEGER DEFAULT 0) IS
    l_pos VARCHAR2(200) := 'style ' || p_id;
    l_w   NUMBER;
  BEGIN
    IF p_id IS NULL OR NOT c.styles.EXISTS(p_id) OR p_depth > 20 THEN RETURN; END IF;
    IF nvl(c.styles(p_id).kind, p_kind) <> p_kind THEN RETURN; END IF;     -- a reference to a style of another kind
    apply_style(c, c.styles(p_id).based_on, p_kind, p, r, t, f, p_depth + 1);
    IF p_kind = 'table' THEN
      IF c.styles(p_id).cond THEN issue(c, 'TABLE_CONDITIONAL', p_id, c.sp, l_pos, NULL, TRUE); END IF;
      tblpr_of(c, c.sx, c.styles(p_id).tblpr, t, c.sp, l_pos, NULL, TRUE);
      tcpr_of(c, c.sx, c.styles(p_id).tcpr, f, l_w, c.sp, l_pos, NULL, TRUE);
      IF c.compat_ts AND (c.styles(p_id).ppr IS NOT NULL OR c.styles(p_id).rpr IS NOT NULL) THEN
        issue(c, 'TABLE_LAYOUT', 'Word''s overrideTableStyleFontSizeAndJustification is not modelled', c.sp, l_pos,
              NULL, TRUE);
      END IF;
    END IF;
    IF p_kind <> 'character' THEN ppr_of(c, c.sx, c.styles(p_id).ppr, p, c.sp, l_pos, NULL, TRUE); END IF;
    rpr_of(c, c.sx, c.styles(p_id).rpr, r, CASE p_kind WHEN 'paragraph' THEN 'P' ELSE 'T' END, c.sp, l_pos, NULL, TRUE);
  END apply_style;

  -- the layers under the direct formatting of a paragraph: docDefaults -> table style -> paragraph style
  PROCEDURE base_layers(c IN OUT NOCOPY t_ctx, p_style IN VARCHAR2, p IN OUT NOCOPY t_pp, r IN OUT NOCOPY t_rp) IS
    t t_tp;
    f rad_pdf_ri.t_cell_fmt;
  BEGIN
    ppr_of(c, c.sx, c.dd_ppr, p, c.sp, 'docDefaults', NULL, TRUE);
    rpr_of(c, c.sx, c.dd_rpr, r, 'D', c.sp, 'docDefaults', NULL, TRUE);
    IF c.tbl_style IS NOT NULL THEN apply_style(c, c.tbl_style, 'table', p, r, t, f); END IF;
    apply_style(c, nvl(p_style, c.def_para), 'paragraph', p, r, t, f);
  END base_layers;

  FUNCTION final_fmt(r IN t_rp) RETURN rad_pdf_ri.t_run_fmt IS
    f rad_pdf_ri.t_run_fmt;
  BEGIN
    f.font := nvl(r.font, 'Times New Roman');
    f.size_pt := nvl(r.size_pt, 10);
    f.bold := nvl(r.bold, 'N');
    f.italic := nvl(r.italic, 'N');
    f.underline := nvl(r.underline, 'N');
    f.color := nvl(r.color, '000000');
    RETURN f;
  END final_fmt;

  PROCEDURE final_para(c IN OUT NOCOPY t_ctx, p IN t_pp, f OUT rad_pdf_ri.t_para_fmt, t OUT rad_pdf_ri.t_tab_list,
                       p_part VARCHAR2, p_pos VARCHAR2, p_near VARCHAR2) IS
    TYPE t_by IS TABLE OF CHAR(1) INDEX BY VARCHAR2(40);
    l_by t_by;
    k    VARCHAR2(40);
  BEGIN
    f.align := nvl(p.align, 'L');
    f.ind_left := nvl(p.ind_left, 0);
    f.ind_right := nvl(p.ind_right, 0);
    f.ind_first := nvl(p.ind_first, 0);
    f.space_before := nvl(p.space_before, 0);
    f.space_after := nvl(p.space_after, 0);
    f.line_mult := nvl(p.line_mult, 1);
    f.keep_next := nvl(p.keep_next, 'N');
    -- widow control: on unless the hierarchy turns it off (ECMA-376 §17.3.1.44); the paginator does not apply it
    IF nvl(p.widow, 'Y') = 'Y' THEN c.widow := TRUE; END IF;     -- reported once, at the end of the read
    IF f.ind_left < 0 OR f.ind_right < 0 OR f.ind_left + f.ind_first < 0 THEN
      issue(c, 'INDENT', 'negative indent', p_part, p_pos, p_near);
      f.ind_left := greatest(f.ind_left, 0);
      f.ind_right := greatest(f.ind_right, 0);
      f.ind_first := greatest(f.ind_first, -f.ind_left);
    END IF;
    IF f.line_mult <= 0 THEN f.line_mult := 1; END IF;
    -- the tab stops: the layers in order, a clear removes the stop of the same position
    FOR i IN 1 .. p.tabs.COUNT LOOP
      k := to_char(p.tabs(i).pos * 1000, 'FM000000000000');
      IF p.tabs(i).kind = 'X' THEN l_by.DELETE(k); ELSIF p.tabs(i).pos > 0 THEN l_by(k) := p.tabs(i).kind; END IF;
    END LOOP;
    t := rad_pdf_ri.t_tab_list();
    k := l_by.FIRST;
    WHILE k IS NOT NULL LOOP
      t.EXTEND;
      t(t.COUNT).pos := to_number(k) / 1000;
      t(t.COUNT).kind := l_by(k);
      k := l_by.NEXT(k);
    END LOOP;
  END final_para;

  -- ===========================================================================
  -- pass A: the model (containers, blocks, tokens)
  -- ===========================================================================
  FUNCTION new_obj(c IN OUT NOCOPY t_ctx, p_kind IN VARCHAR2, p_parent IN PLS_INTEGER, p_pos IN VARCHAR2,
                   p_near IN VARCHAR2 DEFAULT NULL) RETURN PLS_INTEGER IS
    o  t_obj;
    id PLS_INTEGER := c.objs.COUNT + 1;
  BEGIN
    o.kind := p_kind; o.parent := p_parent; o.part := c.part; o.pos := p_pos; o.near := p_near;
    o.kids := rad_pdf_ri.t_num_list();
    c.objs(id) := o;
    IF p_parent IS NOT NULL THEN
      c.objs(p_parent).kids.EXTEND;
      c.objs(p_parent).kids(c.objs(p_parent).kids.COUNT) := id;
    END IF;
    RETURN id;
  END new_obj;

  FUNCTION same_fmt(a IN rad_pdf_ri.t_run_fmt, b IN rad_pdf_ri.t_run_fmt) RETURN BOOLEAN IS
  BEGIN
    RETURN a.font = b.font AND a.size_pt = b.size_pt AND a.bold = b.bold AND a.italic = b.italic
       AND a.underline = b.underline AND a.color = b.color;
  END same_fmt;

  PROCEDURE add_tok(c IN OUT NOCOPY t_ctx, p_para IN PLS_INTEGER, t IN t_tok) IS
    n PLS_INTEGER := c.toks.COUNT;
  BEGIN
    -- adjacent text of one format is one run (Word splits runs for its own bookkeeping)
    IF t.kind = 'TEXT' AND n >= c.objs(p_para).t1 AND n > 0 AND c.toks(n).kind = 'TEXT' AND c.toks(n).para = p_para
       AND same_fmt(c.toks(n).fmt, t.fmt) AND length(c.toks(n).text) + length(t.text) <= 2 * c_chunk THEN
      c.toks(n).text := c.toks(n).text || t.text;
      RETURN;
    END IF;
    c.toks(n + 1) := t;
    c.toks(n + 1).para := p_para;
    c.objs(p_para).t2 := n + 1;
  END add_tok;

  -- the atoms of one paragraph become its tokens: tags found in each span of text (96a §6.1: lexical, across runs)

  -- one span of text atoms (consecutive TEXT, any formats) into tokens: tags found lexically across the atoms (96a
  -- §6.1). The span is read through a small window -- the atoms (at most c_chunk characters each) enter one by one,
  -- the text before a tag or with no pending "{" leaves at once -- so a paragraph has no length limit and a tag may
  -- straddle two atoms or two pieces of a long w:t
  PROCEDURE scan_span(c IN OUT NOCOPY t_ctx, a IN t_atoms, p_from IN PLS_INTEGER, p_to IN PLS_INTEGER,
                      p_para IN PLS_INTEGER) IS
    c_tag   CONSTANT VARCHAR2(100) := '^\{[#/%?]?[A-Za-z_][A-Za-z0-9_]*(\.([A-Za-z_][A-Za-z0-9_]*|[0-9]+))*\}';
    c_reach CONSTANT PLS_INTEGER := 500;                -- the longest tag looked for after a "{"
    l_s     VARCHAR2(32767);                             -- the window: text not emitted yet
    TYPE t_offs IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    l_start t_offs;                                      -- where atom k starts in the window (<= 0: partly gone)
    l_last  PLS_INTEGER;                                 -- the last atom in the window
    l_i     PLS_INTEGER := 1;
    l_p     PLS_INTEGER;
    l_m     VARCHAR2(600);
    t       t_tok;

    FUNCTION atom_at(p_off IN PLS_INTEGER) RETURN PLS_INTEGER IS
    BEGIN
      FOR k IN REVERSE p_from .. l_last LOOP
        IF l_start(k) <= p_off THEN RETURN k; END IF;
      END LOOP;
      RETURN p_from;
    END atom_at;

    PROCEDURE text(p_b IN PLS_INTEGER) IS                -- emits the window's characters 1 .. p_b - 1
      l_k PLS_INTEGER;
      l_e PLS_INTEGER;
      l_x PLS_INTEGER := 1;
    BEGIN
      WHILE l_x < p_b LOOP
        l_k := atom_at(l_x);
        l_e := least(p_b, l_start(l_k) + length(a(l_k).text));
        t := NULL;
        t.kind := 'TEXT'; t.text := substr(l_s, l_x, l_e - l_x); t.fmt := a(l_k).fmt;
        add_tok(c, p_para, t);
        l_x := l_e;
      END LOOP;
    END text;

    PROCEDURE drop_to(p_n IN PLS_INTEGER) IS            -- the window starts at its character p_n
    BEGIN
      l_s := substr(l_s, p_n);
      FOR k IN p_from .. l_last LOOP l_start(k) := l_start(k) - (p_n - 1); END LOOP;
    END drop_to;

    PROCEDURE scan(p_final IN BOOLEAN) IS
    BEGIN
      LOOP
        l_p := CASE WHEN l_s IS NULL THEN 0 ELSE instr(l_s, '{', l_i) END;
        IF l_p = 0 THEN                                  -- nothing pending: all of it leaves
          text(nvl(length(l_s), 0) + 1);
          l_s := NULL;
          FOR k IN p_from .. l_last LOOP l_start(k) := -1000000; END LOOP;
          l_i := 1;
          EXIT;
        END IF;
        l_m := regexp_substr(substr(l_s, l_p, c_reach), c_tag);
        IF l_m IS NULL AND NOT p_final AND length(l_s) - l_p < c_reach THEN
          text(l_p);                                     -- a tag may go on in the next atom: wait for it
          drop_to(l_p);
          l_i := 1;
          EXIT;
        ELSIF l_m IS NULL THEN
          issue(c, 'TAG_SYNTAX', NULL, c.objs(p_para).part, c.objs(p_para).pos, substr(l_s, l_p, 40));
          l_i := l_p + 1;
        ELSE
          text(l_p);
          t := NULL;
          t.kind := 'TAG';
          t.fmt := a(atom_at(l_p)).fmt;                  -- the format of the piece holding "{"
          t.op := CASE WHEN substr(l_m, 2, 1) IN ('#', '/', '%', '?') THEN substr(l_m, 2, 1) ELSE 'F' END;
          t.path := CASE WHEN t.op = 'F' THEN substr(l_m, 2, length(l_m) - 2) ELSE substr(l_m, 3, length(l_m) - 3) END;
          add_tok(c, p_para, t);
          drop_to(l_p + length(l_m));
          l_i := 1;
        END IF;
      END LOOP;
    END scan;
  BEGIN
    FOR k IN p_from .. p_to LOOP
      l_start(k) := nvl(length(l_s), 0) + 1;
      l_last := k;
      l_s := l_s || a(k).text;
      scan(k = p_to);
    END LOOP;
  END scan_span;

  FUNCTION field_code(p_instr IN VARCHAR2) RETURN VARCHAR2 IS
    l_t    VARCHAR2(4000) := upper(trim(regexp_replace(p_instr, '\s+', ' ')));
    l_name VARCHAR2(100) := regexp_substr(l_t, '^\S+');
    l_rest VARCHAR2(4000) := trim(substr(l_t, nvl(length(l_name), 0) + 1));
  BEGIN
    IF l_name IN ('PAGE', 'NUMPAGES') AND (l_rest IS NULL OR regexp_like(l_rest, '^(\\\* ?(MERGEFORMAT|ARABIC) ?)+$')) THEN
      RETURN l_name;
    END IF;
    RETURN NULL;
  END field_code;

  -- an inline picture: its resource (PNG or JPEG, within the budget of 96a §8), NULL after an issue
  FUNCTION image_res(c IN OUT NOCOPY t_ctx, p_part IN VARCHAR2, p_pos VARCHAR2, p_near VARCHAR2) RETURN PLS_INTEGER IS
    l_b   BLOB;
    l_h   RAW(32);
    l_fmt VARCHAR2(4);
    l_w   PLS_INTEGER;
    l_hh  PLS_INTEGER;
    l_p   NUMBER;
    l_mk  PLS_INTEGER;
    l_len NUMBER;
    l_id  PLS_INTEGER;
    FUNCTION be(p_off NUMBER, p_n PLS_INTEGER) RETURN NUMBER IS
    BEGIN
      RETURN to_number(rawtohex(dbms_lob.substr(l_b, p_n, p_off)), 'XXXXXXXX');
    END be;
  BEGIN
    IF c.images.EXISTS(p_part) THEN RETURN c.images(p_part); END IF;
    IF find_part(c, p_part) = 0 THEN refuse('image part "' || p_part || '" missing'); END IF;
    IF c.z.entries(find_part(c, p_part)).usize > rad_pdf_merge.c_max_image_bytes THEN
      issue(c, 'IMAGE_BUDGET', p_part, c.part, p_pos, p_near);
      RETURN NULL;
    END IF;
    l_b := part_bytes(c, p_part);
    l_h := dbms_lob.substr(l_b, 32, 1);
    IF utl_raw.substr(l_h, 1, 8) = hextoraw('89504E470D0A1A0A') AND dbms_lob.getlength(l_b) >= 24 THEN
      l_fmt := 'PNG'; l_w := be(17, 4); l_hh := be(21, 4);
    ELSIF utl_raw.substr(l_h, 1, 2) = hextoraw('FFD8') THEN
      l_fmt := 'JPEG';
      l_p := 3;
      FOR i IN 1 .. 1000 LOOP                            -- the markers up to the frame header (SOFn)
        EXIT WHEN l_p + 8 > dbms_lob.getlength(l_b) OR dbms_lob.substr(l_b, 1, l_p) <> hextoraw('FF');
        l_mk := be(l_p + 1, 1);
        IF l_mk BETWEEN 192 AND 207 AND l_mk NOT IN (196, 200, 204) THEN
          l_hh := be(l_p + 5, 2); l_w := be(l_p + 7, 2);
          EXIT;
        END IF;
        l_len := be(l_p + 2, 2);
        l_p := l_p + 2 + l_len;
      END LOOP;
    END IF;
    IF l_fmt IS NULL OR nvl(l_w, 0) <= 0 OR nvl(l_hh, 0) <= 0 THEN
      issue(c, 'IMAGE_FORMAT', p_part, c.part, p_pos, p_near);
    ELSIF l_w > rad_pdf_merge.c_max_image_px OR l_hh > rad_pdf_merge.c_max_image_px THEN
      issue(c, 'IMAGE_BUDGET', p_part || ' ' || l_w || 'x' || l_hh || ' px', c.part, p_pos, p_near);
    ELSE
      l_id := rad_pdf_ri.add_image(c.res.ri, l_b, l_fmt, l_w, l_hh);
      c.images(p_part) := l_id;
    END IF;
    dbms_lob.freetemporary(l_b);
    RETURN l_id;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_b IS NOT NULL AND dbms_lob.istemporary(l_b) = 1 THEN dbms_lob.freetemporary(l_b); END IF;
      RAISE;
  END image_res;

  -- w:drawing: an inline picture becomes an IMAGE atom; anything else is reported
  PROCEDURE drawing(c IN OUT NOCOPY t_ctx, p_i IN PLS_INTEGER, a IN OUT NOCOPY t_atoms, p_pos VARCHAR2, p_near VARCHAR2) IS
    l_in  PLS_INTEGER := child(c.x, p_i, 'wp', 'inline');
    l_gd  PLS_INTEGER;
    l_uri VARCHAR2(300);
    l_bl  PLS_INTEGER;
    l_rid VARCHAR2(200);
    l_ext PLS_INTEGER;
    t     t_tok;
  BEGIN
    IF child(c.x, p_i, 'wp', 'anchor') IS NOT NULL THEN
      issue(c, CASE WHEN descendant(c.x, p_i, NULL, 'txbx') IS NOT NULL THEN 'TEXTBOX' ELSE 'ANCHORED' END,
            NULL, c.part, p_pos, p_near);
      RETURN;
    END IF;
    IF l_in IS NULL THEN issue(c, 'ELEMENT', 'w:drawing without wp:inline', c.part, p_pos, p_near); RETURN; END IF;
    l_gd := descendant(c.x, l_in, 'a', 'graphicData');
    l_uri := CASE WHEN l_gd IS NOT NULL THEN attr(c.x(l_gd), 'uri') END;
    IF l_uri IS NULL OR l_uri <> c_uri_pic THEN
      issue(c, CASE WHEN descendant(c.x, l_in, NULL, 'txbx') IS NOT NULL THEN 'TEXTBOX' ELSE 'DRAWING' END,
            l_uri, c.part, p_pos, p_near);
      RETURN;
    END IF;
    l_bl := descendant(c.x, l_gd, 'a', 'blip');
    IF l_bl IS NULL THEN issue(c, 'IMAGE_FORMAT', 'no picture', c.part, p_pos, p_near); RETURN; END IF;
    IF descendant(c.x, l_bl, NULL, 'svgBlip') IS NOT NULL THEN issue(c, 'IMAGE_FORMAT', 'SVG', c.part, p_pos, p_near); RETURN; END IF;
    l_rid := attr(c.x(l_bl), 'r:embed');
    IF l_rid IS NULL OR NOT c.rels.EXISTS(l_rid) OR c.rels(l_rid).external THEN
      issue(c, 'IMAGE_EXTERNAL', nvl(attr(c.x(l_bl), 'r:link'), l_rid), c.part, p_pos, p_near);
      RETURN;
    END IF;
    l_ext := child(c.x, l_in, 'wp', 'extent');
    t.kind := 'IMAGE';
    t.res := image_res(c, c.rels(l_rid).target, p_pos, p_near);
    t.w := pts(attr(c.x(l_ext), 'cx'), 12700);
    t.h := pts(attr(c.x(l_ext), 'cy'), 12700);
    IF t.res IS NOT NULL THEN a(a.COUNT + 1) := t; END IF;
  END drawing;

  PROCEDURE walk_blocks(c IN OUT NOCOPY t_ctx, p_el IN PLS_INTEGER, p_container IN PLS_INTEGER, p_prefix IN VARCHAR2,
                        p_in_cell IN BOOLEAN);

  -- one w:p: its format, its atoms (runs, fields, tabs, breaks, pictures), split at page breaks, then its tokens
  PROCEDURE walk_para(c IN OUT NOCOPY t_ctx, p_el IN PLS_INTEGER, p_container IN PLS_INTEGER, p_pos IN VARCHAR2) IS
    l_near  VARCHAR2(100) := text_of(c.x, p_el);
    l_ppr   PLS_INTEGER := child(c.x, p_el, 'w', 'pPr');
    l_style VARCHAR2(200);
    p       t_pp;
    r0      t_rp;                                        -- the runs' base: the layers under the paragraph
    l_fmt   rad_pdf_ri.t_para_fmt;
    l_tabs  rad_pdf_ri.t_tab_list;
    a       t_atoms;
    l_fld   PLS_INTEGER := 0;                            -- field nesting
    l_state VARCHAR2(6);                                 -- INSTR | RESULT inside a field
    l_instr VARCHAR2(4000);
    l_ffmt  rad_pdf_ri.t_run_fmt;
    l_bad   BOOLEAN := FALSE;
    l_link  BOOLEAN := FALSE;
    l_para  PLS_INTEGER;
    l_from  PLS_INTEGER;

    PROCEDURE atom(p_kind VARCHAR2, p_text VARCHAR2 DEFAULT NULL, p_fmt rad_pdf_ri.t_run_fmt DEFAULT NULL,
                   p_code VARCHAR2 DEFAULT NULL) IS
      t t_tok;
    BEGIN
      t.kind := p_kind; t.text := p_text; t.fmt := p_fmt; t.code := p_code;
      a(a.COUNT + 1) := t;
    END atom;

    PROCEDURE field_end IS
    BEGIN
      IF l_fld = 1 AND NOT l_bad THEN
        IF field_code(l_instr) IS NULL THEN
          issue(c, 'FIELD', trim(substr(l_instr, 1, 60)), c.part, p_pos, l_near);
        ELSE
          atom('FIELD', NULL, l_ffmt, field_code(l_instr));
        END IF;
      END IF;
      l_fld := greatest(l_fld - 1, 0);
      IF l_fld = 0 THEN l_state := NULL; l_bad := FALSE; END IF;
    END field_end;

    PROCEDURE run(p_r IN PLS_INTEGER) IS
      r   t_rp := r0;
      f   rad_pdf_ri.t_run_fmt;
      k   PLS_INTEGER;
      l_v VARCHAR2(30);
      l_rpr PLS_INTEGER := child(c.x, p_r, 'w', 'rPr');
    BEGIN
      IF l_rpr IS NOT NULL AND child(c.x, l_rpr, 'w', 'rStyle') IS NOT NULL THEN
        DECLARE p t_pp; t t_tp; cf rad_pdf_ri.t_cell_fmt; BEGIN
          apply_style(c, attr(c.x(child(c.x, l_rpr, 'w', 'rStyle')), 'w:val'), 'character', p, r, t, cf);
        END;
      END IF;
      rpr_of(c, c.x, l_rpr, r, 'D', c.part, p_pos, l_near, FALSE);
      f := final_fmt(r);
      k := c.x(p_r).first;
      WHILE k IS NOT NULL LOOP
        IF c.x(k).ns <> 'w' AND other_child(c, c.x, k, c.part, p_pos, l_near, FALSE) THEN NULL;
        ELSIF c.x(k).nm = 'rPr' THEN NULL;
        ELSIF c.x(k).nm = 'fldChar' THEN
          l_v := attr(c.x(k), 'w:fldCharType');
          IF l_v = 'begin' THEN
            l_fld := l_fld + 1;
            IF l_fld > 1 THEN
              IF NOT l_bad THEN issue(c, 'FIELD', 'a field inside a field', c.part, p_pos, l_near); END IF;
              l_bad := TRUE;
            ELSE
              l_state := 'INSTR'; l_instr := NULL; l_ffmt := f;
            END IF;
          ELSIF l_v = 'separate' THEN
            IF l_fld = 1 THEN l_state := 'RESULT'; END IF;
          ELSIF l_v = 'end' THEN
            field_end;
          END IF;
        ELSIF c.x(k).nm = 'instrText' THEN
          IF l_fld = 1 AND l_state = 'INSTR' THEN l_instr := substr(l_instr || c.x(k).txt, 1, 4000); END IF;
        ELSIF l_fld > 0 THEN
          NULL;                                          -- the instruction's or the result's content
        ELSE
          CASE c.x(k).nm
            WHEN 't' THEN
              atom('TEXT', c.x(k).txt, f);
              IF c.x(k).more IS NOT NULL THEN
                FOR j IN 1 .. c.x(k).more.COUNT LOOP atom('TEXT', c.long(c.x(k).more(j)), f); END LOOP;
              END IF;
            WHEN 'tab' THEN atom('TAB');
            WHEN 'ptab' THEN issue(c, 'TAB_LEADER', 'positional tab', c.part, p_pos, l_near, TRUE); atom('TAB');
            WHEN 'cr' THEN atom('BR');
            WHEN 'br' THEN
              l_v := nvl(attr(c.x(k), 'w:type'), 'textWrapping');
              IF l_v = 'page' THEN atom('PAGE');
              ELSIF l_v = 'column' THEN issue(c, 'SECTION', 'a column break', c.part, p_pos, l_near);
              ELSE atom('BR');
              END IF;
            WHEN 'noBreakHyphen' THEN
              issue(c, 'RUN_EFFECT', 'a non-breaking hyphen drawn as a hyphen', c.part, p_pos, l_near, TRUE);
              atom('TEXT', '-', f);
            WHEN 'softHyphen' THEN NULL;
            WHEN 'lastRenderedPageBreak' THEN NULL;
            WHEN 'sym' THEN issue(c, 'SYMBOL', attr(c.x(k), 'w:font') || ' ' || attr(c.x(k), 'w:char'), c.part, p_pos, l_near);
            WHEN 'drawing' THEN drawing(c, k, a, p_pos, l_near);
            WHEN 'pict' THEN
              issue(c, CASE WHEN descendant(c.x, k, NULL, 'textbox') IS NOT NULL THEN 'TEXTBOX' ELSE 'DRAWING' END,
                    'VML', c.part, p_pos, l_near);
            WHEN 'object' THEN issue(c, 'OBJECT', NULL, c.part, p_pos, l_near);
            ELSE
              IF c.x(k).nm IN ('footnoteReference', 'endnoteReference', 'separator', 'continuationSeparator',
                               'footnoteRef', 'endnoteRef') THEN
                issue(c, 'NOTE', NULL, c.part, p_pos, l_near);
              ELSIF c.x(k).nm IN ('commentReference', 'annotationRef') THEN
                issue(c, 'COMMENT', NULL, c.part, p_pos, l_near);
              ELSIF c.x(k).nm IN ('delText', 'delInstrText') THEN
                issue(c, 'REVISION', 'w:' || c.x(k).nm, c.part, p_pos, l_near);
              ELSE
                issue(c, 'ELEMENT', 'w:' || c.x(k).nm || ' in a run', c.part, p_pos, l_near);
              END IF;
          END CASE;
        END IF;
        k := c.x(k).nxt;
      END LOOP;
    END run;

    PROCEDURE content(p_parent IN PLS_INTEGER) IS
      k PLS_INTEGER := c.x(p_parent).first;
    BEGIN
      WHILE k IS NOT NULL LOOP
        IF other_child(c, c.x, k, c.part, p_pos, l_near, FALSE) THEN NULL;
        ELSE
          CASE c.x(k).nm
            WHEN 'pPr' THEN NULL;
            WHEN 'r' THEN run(k);
            WHEN 'hyperlink' THEN
              IF NOT l_link THEN issue(c, 'LINK', NULL, c.part, p_pos, l_near); l_link := TRUE; END IF;
              content(k);
            WHEN 'fldSimple' THEN
              IF l_fld > 0 OR field_code(attr(c.x(k), 'w:instr')) IS NULL THEN
                issue(c, 'FIELD', trim(substr(attr(c.x(k), 'w:instr'), 1, 60)), c.part, p_pos, l_near);
              ELSE
                l_ffmt := final_fmt(r0);
                IF child(c.x, k, 'w', 'r') IS NOT NULL AND child(c.x, child(c.x, k, 'w', 'r'), 'w', 'rPr') IS NOT NULL THEN
                  DECLARE r t_rp := r0; BEGIN
                    rpr_of(c, c.x, child(c.x, child(c.x, k, 'w', 'r'), 'w', 'rPr'), r, 'D', c.part, p_pos, l_near, FALSE);
                    l_ffmt := final_fmt(r);
                  END;
                END IF;
                atom('FIELD', NULL, l_ffmt, field_code(attr(c.x(k), 'w:instr')));
              END IF;
            WHEN 'commentRangeStart' THEN issue(c, 'COMMENT', NULL, c.part, p_pos, l_near);
            WHEN 'commentRangeEnd' THEN NULL;
            ELSE
              IF c.x(k).nm IN ('bookmarkStart', 'bookmarkEnd', 'proofErr', 'permStart', 'permEnd') THEN NULL;
              ELSE issue(c, 'ELEMENT', 'w:' || c.x(k).nm || ' in a paragraph', c.part, p_pos, l_near);
              END IF;
          END CASE;
        END IF;
        k := c.x(k).nxt;
      END LOOP;
    END content;

    PROCEDURE open_para IS
    BEGIN
      l_para := new_obj(c, 'PARA', p_container, p_pos, l_near);
      c.objs(l_para).para := l_fmt;
      c.objs(l_para).tabs := l_tabs;
      c.objs(l_para).t1 := c.toks.COUNT + 1;
      c.objs(l_para).t2 := c.toks.COUNT;
    END open_para;
  BEGIN
    IF l_ppr IS NOT NULL AND child(c.x, l_ppr, 'w', 'pStyle') IS NOT NULL THEN
      l_style := attr(c.x(child(c.x, l_ppr, 'w', 'pStyle')), 'w:val');
    END IF;
    base_layers(c, l_style, p, r0);
    ppr_of(c, c.x, l_ppr, p, c.part, p_pos, l_near, FALSE);
    final_para(c, p, l_fmt, l_tabs, c.part, p_pos, l_near);
    content(p_el);
    IF l_fld > 0 THEN issue(c, 'FIELD', 'a field that spans paragraphs', c.part, p_pos, l_near); END IF;
    IF p.break_before = 'Y' THEN
      l_para := new_obj(c, 'PBRK', p_container, p_pos);
    END IF;
    open_para;
    -- the atoms in order: text spans scanned for tags, a page break closes the paragraph and opens another one
    l_from := NULL;
    FOR k IN 1 .. a.COUNT + 1 LOOP
      IF k <= a.COUNT AND a(k).kind = 'TEXT' THEN
        IF l_from IS NULL THEN l_from := k; END IF;
      ELSE
        IF l_from IS NOT NULL THEN scan_span(c, a, l_from, k - 1, l_para); l_from := NULL; END IF;
        IF k <= a.COUNT THEN
          IF a(k).kind = 'PAGE' THEN
            l_para := new_obj(c, 'PBRK', p_container, p_pos);
            open_para;
          ELSE
            add_tok(c, l_para, a(k));
          END IF;
        END IF;
      END IF;
    END LOOP;
  END walk_para;

  -- one w:tbl (never inside a cell: 96a §7.2)
  PROCEDURE walk_table(c IN OUT NOCOPY t_ctx, p_el IN PLS_INTEGER, p_container IN PLS_INTEGER, p_prefix IN VARCHAR2) IS
    l_pos    VARCHAR2(200) := p_prefix;
    l_near   VARCHAR2(100) := text_of(c.x, p_el);
    l_tpr    PLS_INTEGER := child(c.x, p_el, 'w', 'tblPr');
    l_style  VARCHAR2(200);
    t        t_tp;
    p0       t_pp;
    r0       t_rp;
    l_cf0    rad_pdf_ri.t_cell_fmt;                      -- the cells' default: the table style's tcPr, the margins
    l_cf     rad_pdf_ri.t_cell_fmt;
    l_tbl    PLS_INTEGER;
    l_row    PLS_INTEGER;
    l_cell   PLS_INTEGER;
    l_grid   rad_pdf_ri.t_num_list := rad_pdf_ri.t_num_list();
    l_saved  VARCHAR2(200) := c.tbl_style;
    l_nrow   PLS_INTEGER := 0;
    l_ncell  PLS_INTEGER;
    l_w      NUMBER;
    l_sum    NUMBER := 0;
    k        PLS_INTEGER;
    q        PLS_INTEGER;
    m        PLS_INTEGER;
    -- every cell: its row, span and dxa width, for the grid and its diagnostics
    TYPE t_cw IS RECORD (row PLS_INTEGER, span PLS_INTEGER, w NUMBER);
    TYPE t_cws IS TABLE OF t_cw INDEX BY PLS_INTEGER;
    l_cws    t_cws;
    l_col    PLS_INTEGER;
    l_exp    NUMBER;
    l_rowpos VARCHAR2(200);
    l_rownear VARCHAR2(100);
  BEGIN
    IF l_tpr IS NOT NULL AND child(c.x, l_tpr, 'w', 'tblStyle') IS NOT NULL THEN
      l_style := attr(c.x(child(c.x, l_tpr, 'w', 'tblStyle')), 'w:val');
    END IF;
    l_style := nvl(l_style, c.def_table);
    -- the table's properties: its style chain, then its own tblPr, classified by the same procedures
    -- the cell margins: a cell's own tcMar (style or direct) wins over the table's tblCellMar (style or direct),
    -- which wins over 0; NULL marks "not set" until the composition below
    l_cf0.mar_top := NULL; l_cf0.mar_bottom := NULL; l_cf0.mar_left := NULL; l_cf0.mar_right := NULL;
    apply_style(c, l_style, 'table', p0, r0, t, l_cf0);
    tblpr_of(c, c.x, l_tpr, t, c.part, l_pos, l_near, FALSE);
    c.tbl_style := l_style;
    l_tbl := new_obj(c, 'TABLE', p_container, l_pos, l_near);
    c.objs(l_tbl).borders := t.borders;
    l_cf0.grid_span := 1;
    l_cf0.mar_top := coalesce(l_cf0.mar_top, t.mar_top, 0); l_cf0.mar_bottom := coalesce(l_cf0.mar_bottom, t.mar_bottom, 0);
    l_cf0.mar_left := coalesce(l_cf0.mar_left, t.mar_left, 0); l_cf0.mar_right := coalesce(l_cf0.mar_right, t.mar_right, 0);
    -- the grid
    q := child(c.x, p_el, 'w', 'tblGrid');
    k := CASE WHEN q IS NOT NULL THEN c.x(q).first END;
    WHILE k IS NOT NULL LOOP
      IF other_child(c, c.x, k, c.part, l_pos, l_near, FALSE) THEN NULL;
      ELSIF c.x(k).nm = 'gridCol' THEN l_grid.EXTEND; l_grid(l_grid.COUNT) := nvl(pts(attr(c.x(k), 'w:w'), 20), 0);
      ELSE issue(c, 'ELEMENT', 'w:' || c.x(k).nm || ' in a table grid', c.part, l_pos, l_near);
      END IF;
      k := c.x(k).nxt;
    END LOOP;
    -- the rows
    k := c.x(p_el).first;
    WHILE k IS NOT NULL LOOP
      IF other_child(c, c.x, k, c.part, l_pos, l_near, FALSE) THEN NULL;
      ELSIF c.x(k).nm IN ('tblPr', 'tblGrid', 'bookmarkStart', 'bookmarkEnd', 'proofErr', 'permStart', 'permEnd') THEN NULL;
      ELSIF c.x(k).nm <> 'tr' THEN issue(c, 'ELEMENT', 'w:' || c.x(k).nm || ' in a table', c.part, l_pos, l_near);
      ELSE
        l_nrow := l_nrow + 1;
        l_rowpos := p_prefix || ', row ' || l_nrow;
        l_rownear := text_of(c.x, k);
        l_row := new_obj(c, 'ROW', l_tbl, l_rowpos, l_rownear);
        c.objs(l_row).header := 'N';
        c.objs(l_row).cant := 'N';
        l_ncell := 0;
        q := c.x(k).first;
        WHILE q IS NOT NULL LOOP
          IF other_child(c, c.x, q, c.part, l_rowpos, l_rownear, FALSE) THEN NULL;
          ELSIF c.x(q).nm = 'trPr' THEN
            m := c.x(q).first;
            WHILE m IS NOT NULL LOOP
              IF other_child(c, c.x, m, c.part, l_rowpos, l_rownear, FALSE) THEN NULL;
              ELSIF c.x(m).nm = 'tblHeader' THEN c.objs(l_row).header := onoff(c.x(m));
              ELSIF c.x(m).nm = 'cantSplit' THEN c.objs(l_row).cant := onoff(c.x(m));
              ELSIF c.x(m).nm = 'trHeight' THEN issue(c, 'ROW_HEIGHT', NULL, c.part, l_rowpos, l_rownear);
              ELSIF c.x(m).nm IN ('gridBefore', 'gridAfter') THEN
                IF nvl(num(attr(c.x(m), 'w:val')), 0) <> 0 THEN issue(c, 'GRID', 'w:' || c.x(m).nm, c.part, l_rowpos, l_rownear); END IF;
              ELSIF c.x(m).nm IN ('wBefore', 'wAfter') THEN
                IF nvl(num(attr(c.x(m), 'w:w')), 0) <> 0 THEN issue(c, 'GRID', 'w:' || c.x(m).nm, c.part, l_rowpos, l_rownear); END IF;
              ELSIF c.x(m).nm = 'tblCellSpacing' THEN issue(c, 'TABLE_LAYOUT', 'cell spacing', c.part, l_rowpos, l_rownear);
              ELSIF c.x(m).nm = 'hidden' THEN issue(c, 'ELEMENT', 'a hidden row', c.part, l_rowpos, l_rownear);
              ELSIF c.x(m).nm IN ('jc', 'cnfStyle', 'divId') THEN NULL;
              ELSE issue(c, 'ELEMENT', 'w:' || c.x(m).nm || ' in a row format', c.part, l_rowpos, l_rownear);
              END IF;
              m := c.x(m).nxt;
            END LOOP;
          ELSIF c.x(q).nm = 'tblPrEx' THEN issue(c, 'TABLE_LAYOUT', 'row exceptions', c.part, l_rowpos, l_rownear);
          ELSIF c.x(q).nm = 'tc' THEN
            l_ncell := l_ncell + 1;
            l_cell := new_obj(c, 'CELL', l_row, l_rowpos || ', cell ' || l_ncell, text_of(c.x, q));
            l_cf := l_cf0;
            l_w := NULL;
            tcpr_of(c, c.x, child(c.x, q, 'w', 'tcPr'), l_cf, l_w, c.part, c.objs(l_cell).pos, c.objs(l_cell).near, FALSE);
            c.objs(l_cell).cell := l_cf;
            l_cws(l_cws.COUNT + 1).row := l_nrow;
            l_cws(l_cws.COUNT).span := l_cf.grid_span;
            l_cws(l_cws.COUNT).w := l_w;
            walk_blocks(c, q, l_cell, l_rowpos || ', cell ' || l_ncell || ', ', TRUE);
          ELSIF c.x(q).nm IN ('bookmarkStart', 'bookmarkEnd', 'proofErr', 'permStart', 'permEnd') THEN NULL;
          ELSE issue(c, 'ELEMENT', 'w:' || c.x(q).nm || ' in a row', c.part, l_rowpos, l_rownear);
          END IF;
          q := c.x(q).nxt;
        END LOOP;
      END IF;
      k := c.x(k).nxt;
    END LOOP;
    -- the column widths. Word lays a fixed table out from its cells' preferred widths (tcW) and rewrites tblGrid
    -- from them: when the FIRST row has one dxa-wide cell per grid column, its widths are the grid; tblGrid
    -- otherwise. Any cell whose width then differs from its columns by more than 1 pt is reported (approximated).
    DECLARE
      l_first rad_pdf_ri.t_num_list := rad_pdf_ri.t_num_list();
      l_ok    BOOLEAN := TRUE;
    BEGIN
      FOR i IN 1 .. l_cws.COUNT LOOP
        IF l_cws(i).row = 1 THEN
          IF l_cws(i).span <> 1 OR l_cws(i).w IS NULL THEN l_ok := FALSE; ELSE l_first.EXTEND; l_first(l_first.COUNT) := l_cws(i).w; END IF;
        END IF;
      END LOOP;
      IF l_ok AND l_first.COUNT = l_grid.COUNT AND l_grid.COUNT > 0 THEN l_grid := l_first; END IF;
    END;
    c.objs(l_tbl).grid := l_grid;
    l_col := 0;
    FOR i IN 1 .. l_cws.COUNT LOOP
      IF i = 1 OR l_cws(i).row <> l_cws(i - 1).row THEN l_col := 0; END IF;
      l_exp := 0;
      FOR j IN l_col + 1 .. l_col + l_cws(i).span LOOP
        IF j <= l_grid.COUNT THEN l_exp := l_exp + l_grid(j); END IF;
      END LOOP;
      l_col := l_col + l_cws(i).span;
      IF l_cws(i).w IS NOT NULL AND abs(l_cws(i).w - l_exp) > 1 THEN
        issue(c, 'TABLE_LAYOUT', 'cell widths that differ from the columns: the columns are used', c.part, l_pos, l_near, TRUE);
      END IF;
      IF i = l_cws.COUNT OR l_cws(i + 1).row <> l_cws(i).row THEN
        IF l_col <> l_grid.COUNT THEN
          issue(c, 'GRID', 'row ' || l_cws(i).row || ' spans ' || l_col || ' of ' || l_grid.COUNT || ' columns', c.part, l_pos, l_near);
        END IF;
      END IF;
    END LOOP;
    -- the effective table properties that the RI does not carry
    FOR i IN 1 .. l_grid.COUNT LOOP l_sum := l_sum + l_grid(i); END LOOP;
    IF nvl(t.jc, 'left') NOT IN ('left', 'start') AND l_sum < c.text_w - 1 THEN
      issue(c, 'TABLE_LAYOUT', 'alignment ' || t.jc, c.part, l_pos, l_near);
    END IF;
    IF nvl(t.ind, 0) <> 0 THEN issue(c, 'TABLE_LAYOUT', 'indent', c.part, l_pos, l_near); END IF;
    IF nvl(t.layout, 'autofit') <> 'fixed' THEN issue(c, 'TABLE_LAYOUT', 'autofit', c.part, l_pos, l_near); END IF;
    c.tbl_style := l_saved;
  EXCEPTION
    WHEN OTHERS THEN
      c.tbl_style := l_saved;
      RAISE;
  END walk_table;

  PROCEDURE walk_blocks(c IN OUT NOCOPY t_ctx, p_el IN PLS_INTEGER, p_container IN PLS_INTEGER, p_prefix IN VARCHAR2,
                        p_in_cell IN BOOLEAN) IS
    k      PLS_INTEGER := c.x(p_el).first;
    l_np   PLS_INTEGER := 0;
    l_nt   PLS_INTEGER := 0;
  BEGIN
    WHILE k IS NOT NULL LOOP
      IF other_child(c, c.x, k, c.part, p_prefix || 'after paragraph ' || l_np, text_of(c.x, k), FALSE) THEN NULL;
      ELSE
        CASE c.x(k).nm
          WHEN 'p' THEN
            l_np := l_np + 1;
            walk_para(c, k, p_container, p_prefix || 'paragraph ' || l_np);
          WHEN 'tbl' THEN
            l_nt := l_nt + 1;
            IF p_in_cell THEN
              issue(c, 'NESTED_TABLE', NULL, c.part, p_prefix || 'table ' || l_nt, text_of(c.x, k));
            ELSE
              walk_table(c, k, p_container, p_prefix || 'table ' || l_nt);
            END IF;
          WHEN 'sectPr' THEN NULL;                       -- the body's own section: read by the caller
          WHEN 'tcPr' THEN NULL;
          ELSE
            IF c.x(k).nm IN ('bookmarkStart', 'bookmarkEnd', 'proofErr', 'permStart', 'permEnd', 'commentRangeEnd') THEN NULL;
            ELSIF c.x(k).nm = 'commentRangeStart' THEN issue(c, 'COMMENT', NULL, c.part, p_prefix || 'after paragraph ' || l_np);
            ELSIF c.x(k).nm = 'altChunk' THEN refuse('an altChunk (imported content)');
            ELSE issue(c, 'ELEMENT', 'w:' || c.x(k).nm, c.part, p_prefix || 'after paragraph ' || l_np, text_of(c.x, k));
            END IF;
        END CASE;
      END IF;
      k := c.x(k).nxt;
    END LOOP;
  END walk_blocks;

  -- a header or footer part into its zone
  PROCEDURE walk_zone_part(c IN OUT NOCOPY t_ctx, p_rid IN VARCHAR2, p_zone IN PLS_INTEGER, p_label IN VARCHAR2,
                           p_body_rels IN t_rels) IS
  BEGIN
    IF p_rid IS NULL THEN RETURN; END IF;
    IF NOT p_body_rels.EXISTS(p_rid) OR p_body_rels(p_rid).external THEN
      refuse('the ' || p_label || ' relationship "' || p_rid || '" is missing or external');
    END IF;
    c.part := p_body_rels(p_rid).target;
    c.x := load_xml(c, c.part);
    c.rels := load_rels(c, c.part);
    c.objs(p_zone).t1 := c.toks.COUNT + 1;
    walk_blocks(c, 1, p_zone, p_label || ', ', FALSE);
    c.objs(p_zone).t2 := c.toks.COUNT;
  END walk_zone_part;

  -- ===========================================================================
  -- pass B: the regions and the resolution of the paths (96a §6.2, §6.3)
  -- ===========================================================================
  FUNCTION schema_path(p_path IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN regexp_replace(p_path, '\.[0-9]+', '[]');
  END schema_path;

  FUNCTION kid_index(c IN t_ctx, p_parent IN PLS_INTEGER, p_kid IN PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN
    FOR i IN 1 .. c.objs(p_parent).kids.COUNT LOOP
      IF c.objs(p_parent).kids(i) = p_kid THEN RETURN i; END IF;
    END LOOP;
    RETURN NULL;
  END kid_index;

  PROCEDURE regions(c IN OUT NOCOPY t_ctx, p_zone IN PLS_INTEGER) IS
    TYPE t_stack IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    st     t_stack;                                      -- open regions
    l_n    PLS_INTEGER := 0;
    l_r    t_reg;
    l_id   PLS_INTEGER;
    l_po   PLS_INTEGER;
    l_pc   PLS_INTEGER;
    l_co   PLS_INTEGER;
    l_cc   PLS_INTEGER;
    l_row  PLS_INTEGER;
    l_ok   BOOLEAN;
    l_loops PLS_INTEGER;

    -- the path resolved against the schema: the innermost open loop first, then outwards, then the root
    PROCEDURE resolve(p_path IN VARCHAR2, p_upto IN PLS_INTEGER, p_scope OUT VARCHAR2, p_abs OUT VARCHAR2) IS
      l_cand VARCHAR2(800);
    BEGIN
      FOR i IN REVERSE 1 .. p_upto LOOP
        IF c.regs(st(i)).kind = 'LOOP' THEN
          l_cand := c.regs(st(i)).abs || '[].' || p_path;
          IF c.sch.EXISTS(schema_path(l_cand)) THEN p_scope := c.regs(st(i)).abs; p_abs := l_cand; RETURN; END IF;
        END IF;
      END LOOP;
      IF c.sch.EXISTS(schema_path(p_path)) THEN p_scope := NULL; p_abs := p_path; END IF;
    END resolve;

    PROCEDURE err(p_code VARCHAR2, p_detail VARCHAR2, p_tok PLS_INTEGER) IS
      o PLS_INTEGER := c.toks(p_tok).para;
    BEGIN
      issue(c, p_code, p_detail, c.objs(o).part, c.objs(o).pos, c.objs(o).near);
    END err;
  BEGIN
    FOR k IN c.objs(p_zone).t1 .. c.objs(p_zone).t2 LOOP
      IF c.toks(k).kind = 'TAG' THEN
        IF c.toks(k).op = '#' THEN
          l_r := NULL;
          l_r.path := c.toks(k).path;
          l_r.o := k;
          l_r.emitted := FALSE;
          resolve(l_r.path, l_n, l_r.scope, l_r.abs);
          IF l_r.abs IS NULL THEN
            err('TAG_PATH', '{#' || l_r.path || '}', k);
          ELSE
            l_r.kind := CASE WHEN c.sch(schema_path(l_r.abs)) = 'ARRAY' THEN 'LOOP' ELSE 'SECTION' END;
          END IF;
          l_id := c.regs.COUNT + 1;
          c.regs(l_id) := l_r;
          c.toks(k).reg := l_id;
          l_n := l_n + 1;
          st(l_n) := l_id;
          l_loops := 0;
          FOR i IN 1 .. l_n LOOP IF c.regs(st(i)).kind = 'LOOP' THEN l_loops := l_loops + 1; END IF; END LOOP;
          IF l_loops > rad_pdf_merge.c_max_loop_depth THEN err('TAG_DEPTH', '{#' || l_r.path || '}', k); END IF;
        ELSIF c.toks(k).op = '/' THEN
          IF l_n = 0 THEN
            err('TAG_BALANCE', '{/' || c.toks(k).path || '} without its opening', k);
          ELSIF c.regs(st(l_n)).path <> c.toks(k).path THEN
            err('TAG_BALANCE', '{/' || c.toks(k).path || '} while {#' || c.regs(st(l_n)).path || '} is open', k);
          ELSE
            l_id := st(l_n);
            l_n := l_n - 1;
            c.toks(k).reg := l_id;
            c.regs(l_id).c := k;
            -- the placement, in the order of 96a §6.2
            l_po := c.toks(c.regs(l_id).o).para;
            l_pc := c.toks(k).para;
            l_co := c.objs(l_po).parent;
            l_cc := c.objs(l_pc).parent;
            l_ok := FALSE;
            IF c.objs(l_co).kind = 'CELL' AND c.objs(l_cc).kind = 'CELL'
               AND c.objs(l_co).parent = c.objs(l_cc).parent THEN
              l_row := c.objs(l_co).parent;
              IF c.objs(l_row).kids(1) = l_co AND c.objs(l_co).kids(1) = l_po AND c.objs(l_po).t1 = c.regs(l_id).o
                 AND c.objs(l_row).kids(c.objs(l_row).kids.COUNT) = l_cc
                 AND c.objs(l_cc).kids(c.objs(l_cc).kids.COUNT) = l_pc AND c.objs(l_pc).t2 = k THEN
                c.regs(l_id).place := 'ROW';
                c.regs(l_id).row_id := l_row;
                l_ok := TRUE;
                IF c.objs(l_row).header = 'Y' THEN
                  err('TAG_REGION', 'a repeated row cannot be a repeated header row', k);
                END IF;
              END IF;
            END IF;
            IF NOT l_ok AND c.objs(l_po).t1 = c.regs(l_id).o AND c.objs(l_pc).t2 = k AND l_co = l_cc
               AND kid_index(c, l_co, l_po) <= kid_index(c, l_cc, l_pc) THEN
              c.regs(l_id).place := 'PARAGRAPHS';
              l_ok := TRUE;
            END IF;
            IF NOT l_ok AND l_po = l_pc THEN
              c.regs(l_id).place := 'INLINE';
              l_ok := TRUE;
              IF k = c.regs(l_id).o + 1 THEN err('TAG_REGION', 'an empty block', k); END IF;
            END IF;
            IF NOT l_ok THEN
              err('TAG_REGION', '{#' || c.regs(l_id).path || '}...{/' || c.regs(l_id).path || '}', k);
            END IF;
          END IF;
        ELSE
          resolve(c.toks(k).path, l_n, c.toks(k).scope, c.toks(k).abs);
          IF c.toks(k).abs IS NULL THEN
            err('TAG_PATH', '{' || CASE WHEN c.toks(k).op <> 'F' THEN c.toks(k).op END || c.toks(k).path || '}', k);
          END IF;
        END IF;
      END IF;
    END LOOP;
    FOR i IN 1 .. l_n LOOP
      err('TAG_BALANCE', '{#' || c.regs(st(i)).path || '} without its closing', c.regs(st(i)).o);
    END LOOP;
  END regions;

  -- ===========================================================================
  -- pass C: the RI (only when nothing is in error)
  -- ===========================================================================
  PROCEDURE emit_blocks(c IN OUT NOCOPY t_ctx, p_kids IN rad_pdf_ri.t_num_list, p_a IN PLS_INTEGER, p_b IN PLS_INTEGER,
                        p_parent IN rad_pdf_ri.t_id);

  PROCEDURE emit_para(c IN OUT NOCOPY t_ctx, p_o IN PLS_INTEGER, p_parent IN rad_pdf_ri.t_id) IS
    TYPE t_stack IS TABLE OF rad_pdf_ri.t_id INDEX BY PLS_INTEGER;
    st  t_stack;
    n   PLS_INTEGER := 1;
    l_x rad_pdf_ri.t_id;
    t   t_tok;
  BEGIN
    st(1) := rad_pdf_ri.paragraph(c.res.ri, p_parent, c.objs(p_o).para, c.objs(p_o).tabs);
    FOR k IN c.objs(p_o).t1 .. c.objs(p_o).t2 LOOP
      t := c.toks(k);
      CASE t.kind
        WHEN 'TEXT' THEN l_x := rad_pdf_ri.run(c.res.ri, st(n), t.text, t.fmt);
        WHEN 'TAB' THEN l_x := rad_pdf_ri.tab(c.res.ri, st(n));
        WHEN 'BR' THEN l_x := rad_pdf_ri.line_break(c.res.ri, st(n));
        WHEN 'FIELD' THEN l_x := rad_pdf_ri.field(c.res.ri, st(n), t.code, t.fmt);
        WHEN 'IMAGE' THEN l_x := rad_pdf_ri.image(c.res.ri, st(n), t.res, t.w, t.h);
        WHEN 'TAG' THEN
          IF t.op = '#' THEN
            IF c.regs(t.reg).place = 'INLINE' THEN
              n := n + 1;
              st(n) := rad_pdf_ri.inline_region(c.res.ri, st(n - 1), c.regs(t.reg).kind, c.regs(t.reg).scope, c.regs(t.reg).abs);
            END IF;
          ELSIF t.op = '/' THEN
            IF c.regs(t.reg).place = 'INLINE' THEN n := n - 1; END IF;
          ELSE
            l_x := rad_pdf_ri.tag(c.res.ri, st(n), CASE t.op WHEN 'F' THEN 'FIELD' WHEN '%' THEN 'IMAGE' ELSE 'PAGEBREAK' END,
                                  t.scope, t.abs, t.fmt);
          END IF;
        ELSE NULL;
      END CASE;
    END LOOP;
  END emit_para;

  PROCEDURE emit_table(c IN OUT NOCOPY t_ctx, p_o IN PLS_INTEGER, p_parent IN rad_pdf_ri.t_id) IS
    l_t    rad_pdf_ri.t_id := rad_pdf_ri.table_(c.res.ri, p_parent, c.objs(p_o).grid, c.objs(p_o).borders);
    l_p    rad_pdf_ri.t_id;
    l_r    rad_pdf_ri.t_id;
    l_c    rad_pdf_ri.t_id;
    l_row  PLS_INTEGER;
    l_cell PLS_INTEGER;
    l_best PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. c.objs(p_o).kids.COUNT LOOP
      l_row := c.objs(p_o).kids(i);
      l_p := l_t;
      LOOP                                               -- the ROW regions of this row, the outermost first
        l_best := NULL;
        FOR g IN 1 .. c.regs.COUNT LOOP
          IF c.regs(g).place = 'ROW' AND c.regs(g).row_id = l_row AND NOT c.regs(g).emitted
             AND (l_best IS NULL OR c.regs(g).o < c.regs(l_best).o) THEN
            l_best := g;
          END IF;
        END LOOP;
        EXIT WHEN l_best IS NULL;
        c.regs(l_best).emitted := TRUE;
        l_p := rad_pdf_ri.row_region(c.res.ri, l_p, c.regs(l_best).kind, c.regs(l_best).scope, c.regs(l_best).abs);
      END LOOP;
      l_r := rad_pdf_ri.row_(c.res.ri, l_p, c.objs(l_row).header, c.objs(l_row).cant);
      FOR j IN 1 .. c.objs(l_row).kids.COUNT LOOP
        l_cell := c.objs(l_row).kids(j);
        l_c := rad_pdf_ri.cell(c.res.ri, l_r, c.objs(l_cell).cell);
        emit_blocks(c, c.objs(l_cell).kids, 1, c.objs(l_cell).kids.COUNT, l_c);
      END LOOP;
    END LOOP;
  END emit_table;

  PROCEDURE emit_blocks(c IN OUT NOCOPY t_ctx, p_kids IN rad_pdf_ri.t_num_list, p_a IN PLS_INTEGER, p_b IN PLS_INTEGER,
                        p_parent IN rad_pdf_ri.t_id) IS
    i      PLS_INTEGER := p_a;
    o      PLS_INTEGER;
    l_best PLS_INTEGER;
    j      PLS_INTEGER;
    l_x    rad_pdf_ri.t_id;
  BEGIN
    WHILE i <= p_b LOOP
      o := p_kids(i);
      IF c.objs(o).kind = 'PARA' THEN
        l_best := NULL;                                  -- a PARAGRAPHS region opening here, the outermost first
        FOR g IN 1 .. c.regs.COUNT LOOP
          IF c.regs(g).place = 'PARAGRAPHS' AND NOT c.regs(g).emitted AND c.toks(c.regs(g).o).para = o
             AND (l_best IS NULL OR c.regs(g).o < c.regs(l_best).o) THEN
            l_best := g;
          END IF;
        END LOOP;
        IF l_best IS NOT NULL THEN
          c.regs(l_best).emitted := TRUE;
          j := i;
          WHILE p_kids(j) <> c.toks(c.regs(l_best).c).para LOOP j := j + 1; END LOOP;
          l_x := rad_pdf_ri.block_region(c.res.ri, p_parent, c.regs(l_best).kind, c.regs(l_best).scope, c.regs(l_best).abs);
          emit_blocks(c, p_kids, i, j, l_x);
          i := j + 1;
          CONTINUE;
        END IF;
        emit_para(c, o, p_parent);
      ELSIF c.objs(o).kind = 'TABLE' THEN
        emit_table(c, o, p_parent);
      ELSIF c.objs(o).kind = 'PBRK' THEN
        l_x := rad_pdf_ri.page_break(c.res.ri, p_parent);
      END IF;
      i := i + 1;
    END LOOP;
  END emit_blocks;

  -- ===========================================================================
  -- read
  -- ===========================================================================
  FUNCTION read(p_docx IN BLOB, p_schema IN rad_pdf_merge.t_schema) RETURN t_result IS
    c        t_ctx;
    l_rels   t_rels;
    l_main   VARCHAR2(400);
    l_body   PLS_INTEGER;
    l_sect   PLS_INTEGER;
    k        PLS_INTEGER;
    l_v      VARCHAR2(100);
    l_w      NUMBER := 12240 / 20;                       -- Word's defaults without a sectPr: Letter, 1 inch
    l_h      NUMBER := 15840 / 20;
    l_mt     NUMBER := 72; l_mb NUMBER := 72; l_ml NUMBER := 72; l_mr NUMBER := 72;
    l_mh     NUMBER := 36; l_mf NUMBER := 36;
    l_or     CHAR(1) := 'P';
    l_title  CHAR(1) := 'N';
    l_hdr_f  VARCHAR2(200); l_hdr_d VARCHAR2(200); l_ftr_f VARCHAR2(200); l_ftr_d VARCHAR2(200);
    l_even   BOOLEAN := FALSE;
    l_zones  rad_pdf_ri.t_num_list := rad_pdf_ri.t_num_list();
    TYPE t_names IS TABLE OF VARCHAR2(16);
    l_names  t_names := t_names('body', 'header_first', 'header_default', 'footer_first', 'footer_default');
    l_s      rad_pdf_ri.t_id;
    l_sx     t_els;
  BEGIN
    rad_pdf_merge.check_schema(p_schema);
    c.rules := rules;
    c.res.report := t_report();
    c.res.ri := rad_pdf_ri.new_ri;
    FOR i IN 1 .. p_schema.COUNT LOOP c.sch(p_schema(i).path) := p_schema(i).type; END LOOP;
    c.docx := p_docx;
    c.z := rad_pdf_zip.open_zip(p_docx);
    check_package(c);
    -- the main part and its relationships
    l_rels := load_rels(c, NULL);
    l_main := rel_target(l_rels, 'officeDocument');
    IF l_main IS NULL THEN refuse('no main document relationship'); END IF;
    IF nvl(content_type(c, l_main), '-') NOT IN (c_ct_doc, c_ct_dot) THEN
      refuse('the main part is not a Word document or template (' || content_type(c, l_main) || ')');
    END IF;
    l_rels := load_rels(c, l_main);
    k := NULL;
    l_v := l_rels.FIRST;
    WHILE l_v IS NOT NULL LOOP
      IF rel_kind(l_rels(l_v).kind) IN ('aFChunk', 'oleObject', 'package', 'control', 'vbaProject', 'activeXControlBinary') THEN
        refuse('the document relates to ' || rel_kind(l_rels(l_v).kind));
      END IF;
      l_v := l_rels.NEXT(l_v);
    END LOOP;
    load_theme(c, rel_target(l_rels, 'theme'));
    c.sp := rel_target(l_rels, 'styles');
    load_styles(c, c.sp);
    IF rel_target(l_rels, 'settings') IS NOT NULL AND find_part(c, rel_target(l_rels, 'settings')) > 0 THEN
      l_sx := load_xml(c, rel_target(l_rels, 'settings'));
      k := child(l_sx, 1, 'w', 'defaultTabStop');
      IF k IS NOT NULL AND pts(attr(l_sx(k), 'w:val'), 20) <> 36 THEN
        issue(c, 'DEFAULT_TAB', attr(l_sx(k), 'w:val'), rel_target(l_rels, 'settings'), 'settings');
      END IF;
      k := child(l_sx, 1, 'w', 'evenAndOddHeaders');
      l_even := k IS NOT NULL AND onoff(l_sx(k)) = 'Y';
      k := descendant(l_sx, 1, 'w', 'compatSetting');
      WHILE k IS NOT NULL LOOP                           -- the compatibility switches: only one matters here
        IF attr(l_sx(k), 'w:name') = 'overrideTableStyleFontSizeAndJustification' AND attr(l_sx(k), 'w:val') = '1' THEN
          c.compat_ts := TRUE;
        END IF;
        k := l_sx(k).nxt;
        IF k IS NOT NULL AND NOT is_el(l_sx(k), 'w', 'compatSetting') THEN k := NULL; END IF;
      END LOOP;
      l_sx.DELETE;
    END IF;
    -- the body
    c.part := l_main;
    c.x := load_xml(c, l_main);
    c.rels := l_rels;
    l_body := child(c.x, 1, 'w', 'body');
    IF l_body IS NULL THEN refuse('the main part has no body'); END IF;
    -- the section: the last child of the body
    l_sect := c.x(l_body).last;
    IF l_sect IS NOT NULL AND NOT is_el(c.x(l_sect), 'w', 'sectPr') THEN l_sect := NULL; END IF;
    k := CASE WHEN l_sect IS NOT NULL THEN c.x(l_sect).first END;
    WHILE k IS NOT NULL LOOP
      IF other_child(c, c.x, k, c.part, 'section', NULL, FALSE) THEN NULL;
      ELSE
        CASE c.x(k).nm
          WHEN 'pgSz' THEN
            l_w := nvl(pts(attr(c.x(k), 'w:w'), 20), l_w);
            l_h := nvl(pts(attr(c.x(k), 'w:h'), 20), l_h);
            l_or := CASE WHEN attr(c.x(k), 'w:orient') = 'landscape' THEN 'L' ELSE 'P' END;
          WHEN 'pgMar' THEN
            l_mt := abs(nvl(pts(attr(c.x(k), 'w:top'), 20), l_mt));
            l_mb := abs(nvl(pts(attr(c.x(k), 'w:bottom'), 20), l_mb));
            l_ml := nvl(pts(nvl(attr(c.x(k), 'w:left'), attr(c.x(k), 'w:start')), 20), l_ml);
            l_mr := nvl(pts(nvl(attr(c.x(k), 'w:right'), attr(c.x(k), 'w:end')), 20), l_mr);
            l_mh := nvl(pts(attr(c.x(k), 'w:header'), 20), l_mh);
            l_mf := nvl(pts(attr(c.x(k), 'w:footer'), 20), l_mf);
            IF nvl(pts(attr(c.x(k), 'w:gutter'), 20), 0) <> 0 THEN issue(c, 'SECTION_PAGE', 'gutter', c.part, 'section'); END IF;
          WHEN 'titlePg' THEN l_title := onoff(c.x(k));
          WHEN 'headerReference' THEN
            l_v := attr(c.x(k), 'w:type');
            IF l_v = 'first' THEN l_hdr_f := attr(c.x(k), 'r:id');
            ELSIF l_v = 'even' THEN IF l_even THEN issue(c, 'SECTION_PAGE', 'even-page header', c.part, 'section'); END IF;
            ELSE l_hdr_d := attr(c.x(k), 'r:id');
            END IF;
          WHEN 'footerReference' THEN
            l_v := attr(c.x(k), 'w:type');
            IF l_v = 'first' THEN l_ftr_f := attr(c.x(k), 'r:id');
            ELSIF l_v = 'even' THEN IF l_even THEN issue(c, 'SECTION_PAGE', 'even-page footer', c.part, 'section'); END IF;
            ELSE l_ftr_d := attr(c.x(k), 'r:id');
            END IF;
          WHEN 'cols' THEN
            IF nvl(num(attr(c.x(k), 'w:num')), 1) > 1 THEN issue(c, 'SECTION', 'columns', c.part, 'section'); END IF;
          WHEN 'pgNumType' THEN
            IF attr(c.x(k), 'w:start') IS NOT NULL THEN issue(c, 'SECTION_PAGE', 'page numbering start', c.part, 'section'); END IF;
          WHEN 'vAlign' THEN
            IF nvl(attr(c.x(k), 'w:val'), 'top') <> 'top' THEN issue(c, 'SECTION_PAGE', 'vertical alignment', c.part, 'section'); END IF;
          WHEN 'pgBorders' THEN issue(c, 'SECTION_PAGE', 'page borders', c.part, 'section');
          WHEN 'lnNumType' THEN issue(c, 'SECTION_PAGE', 'line numbers', c.part, 'section');
          WHEN 'bidi' THEN IF onoff(c.x(k)) = 'Y' THEN issue(c, 'RTL', 'section', c.part, 'section'); END IF;
          WHEN 'textDirection' THEN issue(c, 'RTL', 'text direction', c.part, 'section');
          ELSE
            IF c.x(k).nm NOT IN ('docGrid', 'formProt', 'paperSrc', 'rtlGutter', 'footnotePr', 'endnotePr', 'type',
                                 'printerSettings', 'noEndnote') THEN
              issue(c, 'ELEMENT', 'w:' || c.x(k).nm || ' in the section', c.part, 'section');
            END IF;
        END CASE;
      END IF;
      k := c.x(k).nxt;
    END LOOP;
    c.text_w := l_w - l_ml - l_mr;
    FOR i IN 1 .. 5 LOOP
      l_zones.EXTEND;
      l_zones(i) := new_obj(c, 'ZONE', NULL, l_names(i));
      c.objs(l_zones(i)).zone := l_names(i);
    END LOOP;
    c.objs(l_zones(1)).t1 := 1;
    walk_blocks(c, l_body, l_zones(1), 'body, ', FALSE);
    c.objs(l_zones(1)).t2 := c.toks.COUNT;
    -- the headers and the footers
    IF l_title = 'Y' THEN walk_zone_part(c, l_hdr_f, l_zones(2), 'header_first', l_rels); END IF;
    walk_zone_part(c, l_hdr_d, l_zones(3), 'header_default', l_rels);
    IF l_title = 'Y' THEN walk_zone_part(c, l_ftr_f, l_zones(4), 'footer_first', l_rels); END IF;
    walk_zone_part(c, l_ftr_d, l_zones(5), 'footer_default', l_rels);
    FOR i IN 1 .. 5 LOOP
      IF c.objs(l_zones(i)).t1 IS NOT NULL THEN regions(c, l_zones(i)); END IF;
    END LOOP;
    IF c.widow THEN
      issue(c, 'WIDOW', 'on for every paragraph that does not turn it off', l_main, 'document');
    END IF;
    c.x.DELETE;
    c.sx.DELETE;
    -- the RI, when nothing is in error
    IF c.res.errors = 0 THEN
      l_s := rad_pdf_ri.section(c.res.ri, l_w, l_h, l_or, l_mt, l_mb, l_ml, l_mr, l_mh, l_mf, l_title);
      FOR i IN 1 .. 5 LOOP
        emit_blocks(c, c.objs(l_zones(i)).kids, 1, c.objs(l_zones(i)).kids.COUNT, rad_pdf_ri.zone(c.res.ri, l_names(i)));
      END LOOP;
      rad_pdf_ri.seal(c.res.ri);
      BEGIN
        rad_pdf_merge.check_template(c.res.ri, p_schema);
      EXCEPTION
        WHEN OTHERS THEN
          IF sqlcode <> rad_pdf_merge.c_err_schema THEN RAISE; END IF;
          issue(c, 'TAG_TYPE', regexp_replace(substr(sqlerrm, 1, 400), '^ORA-[0-9]+: ', ''), l_main, 'template');
      END;
    END IF;
    IF c.res.errors > 0 THEN
      rad_pdf_ri.free(c.res.ri);
      c.res.ri := rad_pdf_ri.new_ri;
    END IF;
    RETURN c.res;
  EXCEPTION
    WHEN OTHERS THEN
      rad_pdf_ri.free(c.res.ri);
      RAISE;
  END read;

  FUNCTION report_json(p_result IN t_result) RETURN CLOB IS
    o json_object_t := json_object_t();
    a json_array_t := json_array_t();
    e json_object_t;
  BEGIN
    o.put('errors', p_result.errors);
    o.put('warnings', p_result.warnings);
    FOR i IN 1 .. nvl(p_result.report.COUNT, 0) LOOP
      e := json_object_t();
      e.put('severity', p_result.report(i).severity);
      e.put('code', p_result.report(i).code);
      e.put('part', p_result.report(i).part);
      e.put('position', p_result.report(i).position);
      e.put('near', p_result.report(i).near);
      e.put('message', p_result.report(i).message);
      a.append(e);
    END LOOP;
    o.put('issues', a);
    RETURN o.to_clob;
  END report_json;

END rad_pdf_docx;
/
