CREATE OR REPLACE PACKAGE BODY rad_pdf_merge AS

  TYPE t_index IS TABLE OF t_field INDEX BY VARCHAR2(400);            -- the schema by path
  TYPE t_ctx   IS TABLE OF json_object_t INDEX BY VARCHAR2(400);      -- the current element of each open LOOP

  -- where a value is: in an object under a key, or in an array at an index; found = FALSE when absent
  TYPE t_loc IS RECORD (obj json_object_t, arr json_array_t, key VARCHAR2(400), idx PLS_INTEGER, found BOOLEAN := FALSE);

  -- an IMAGE value validated once (check_data) and reused by the emission: its data-URL, its resource in the instance
  TYPE t_img  IS RECORD (url CLOB, res rad_pdf_ri.t_id, px_w PLS_INTEGER, px_h PLS_INTEGER);
  TYPE t_imgs IS TABLE OF t_img INDEX BY PLS_INTEGER;
  TYPE t_bysha IS TABLE OF rad_pdf_ri.t_id INDEX BY VARCHAR2(64);

  -- the binding of a LOOP path before a loop opens it again (a LOOP may reopen the path of an outer one)
  TYPE t_saved IS RECORD (had BOOLEAN, prev json_object_t);

  -- the state of one merge, passed down (never package state)
  TYPE t_m IS RECORD (
    root      json_object_t,
    ctx       t_ctx,
    sch       t_index,
    src       rad_pdf_ri.t_ri,
    out       rad_pdf_ri.t_ri,
    imgs      t_imgs,
    bysha     t_bysha,
    lob_bytes NUMBER := 0);

  c_path_re CONSTANT VARCHAR2(100) := '^[A-Za-z_][A-Za-z0-9_]*(\[\])?(\.[A-Za-z_][A-Za-z0-9_]*(\[\])?)*$';

  PROCEDURE fail(p_code IN PLS_INTEGER, p_msg IN VARCHAR2) IS
  BEGIN
    raise_application_error(p_code, CASE p_code WHEN c_err_data THEN '[PRT_DATA] ' WHEN c_err_budget THEN '[PDF_BUDGET] '
                                                ELSE '[PRT_SCHEMA] ' END || substr(p_msg, 1, 1900));
  END fail;

  PROCEDURE free_lob(p_lob IN OUT NOCOPY BLOB) IS
  BEGIN
    IF p_lob IS NOT NULL AND dbms_lob.istemporary(p_lob) = 1 THEN dbms_lob.freetemporary(p_lob); END IF;
  END free_lob;

  PROCEDURE free_lob(p_lob IN OUT NOCOPY CLOB) IS
  BEGIN
    IF p_lob IS NOT NULL AND dbms_lob.istemporary(p_lob) = 1 THEN dbms_lob.freetemporary(p_lob); END IF;
  END free_lob;

  -- every temporary of a merge: the URLs kept by the image cache and the instance (on an error)
  PROCEDURE free_state(m IN OUT NOCOPY t_m, p_out IN BOOLEAN) IS
  BEGIN
    FOR i IN 1 .. m.imgs.COUNT LOOP free_lob(m.imgs(i).url); END LOOP;
    m.imgs.DELETE;
    IF p_out THEN rad_pdf_ri.free(m.out); END IF;
  END free_state;

  -- ---------------------------------------------------------------------------
  -- the schema
  -- ---------------------------------------------------------------------------
  FUNCTION field(p_path IN VARCHAR2, p_type IN VARCHAR2, p_required IN rad_pdf_ri.t_flag,
                 p_nullable IN rad_pdf_ri.t_flag DEFAULT NULL) RETURN t_field IS
    f t_field;
  BEGIN
    f.path := p_path; f.type := p_type; f.required := p_required;
    f.nullable := nvl(p_nullable, CASE WHEN p_required = 'N' AND p_type IN ('TEXT', 'IMAGE') THEN 'Y' ELSE 'N' END);
    RETURN f;
  END field;

  FUNCTION schema_from_json(p_json IN CLOB) RETURN t_schema IS
    o json_object_t;
    a json_array_t;
    t json_object_t;
    s t_schema := t_schema();
  BEGIN
    BEGIN
      o := json_object_t.parse(p_json);
      a := o.get_array('fields');
    EXCEPTION WHEN OTHERS THEN fail(c_err_schema, 'a schema text is JSON with a fields array: ' || sqlerrm);
    END;
    IF a IS NULL THEN fail(c_err_schema, 'a schema text needs its fields array'); END IF;
    FOR i IN 0 .. a.get_size - 1 LOOP
      IF NOT a.get(i).is_object THEN fail(c_err_schema, 'field ' || i || ' is not an object'); END IF;
      t := treat(a.get(i) AS json_object_t);
      s.EXTEND;
      s(s.COUNT) := field(t.get_string('path'), t.get_string('type'), t.get_string('required'),
                          CASE WHEN t.has('nullable') THEN t.get_string('nullable') END);
    END LOOP;
    RETURN s;
  END schema_from_json;

  -- the schema path of a resolved path: an index reads an element (lines.0.code -> lines[].code)
  FUNCTION schema_path(p_path IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN regexp_replace(p_path, '\.[0-9]+', '[]');
  END schema_path;

  FUNCTION index_of(p_schema IN t_schema) RETURN t_index IS
    l t_index;
    f t_field;
    l_pre VARCHAR2(400);
  BEGIN
    IF p_schema IS NULL OR p_schema.COUNT = 0 THEN fail(c_err_schema, 'an empty schema'); END IF;
    FOR i IN 1 .. p_schema.COUNT LOOP
      f := p_schema(i);
      IF f.path IS NULL OR NOT regexp_like(f.path, c_path_re) THEN fail(c_err_schema, 'invalid path ' || f.path); END IF;
      IF f.type IS NULL OR f.type NOT IN ('TEXT', 'BOOLEAN', 'IMAGE', 'ARRAY', 'OBJECT') THEN
        fail(c_err_schema, f.path || ': type TEXT, BOOLEAN, IMAGE, ARRAY or OBJECT');
      END IF;
      IF nvl(f.required, '#') NOT IN ('Y', 'N') OR nvl(f.nullable, '#') NOT IN ('Y', 'N') THEN
        fail(c_err_schema, f.path || ': required and nullable are Y or N');
      END IF;
      IF f.type IN ('ARRAY', 'BOOLEAN') AND f.nullable = 'Y' THEN
        fail(c_err_schema, f.path || ': ' || CASE f.type WHEN 'ARRAY' THEN 'an ARRAY' ELSE 'a BOOLEAN' END
                           || ' is never nullable (96a §5.1)');
      END IF;
      IF substr(f.path, -2) = '[]' THEN fail(c_err_schema, f.path || ': a path ends with a name'); END IF;
      IF l.EXISTS(f.path) THEN fail(c_err_schema, f.path || ' twice'); END IF;
      l(f.path) := f;
    END LOOP;
    -- every [] of a path is an element of an ARRAY of the schema
    FOR i IN 1 .. p_schema.COUNT LOOP
      FOR k IN 1 .. regexp_count(p_schema(i).path, '\[\]') LOOP
        l_pre := substr(p_schema(i).path, 1, instr(p_schema(i).path, '[]', 1, k) - 1);
        IF NOT l.EXISTS(l_pre) OR l(l_pre).type <> 'ARRAY' THEN
          fail(c_err_schema, p_schema(i).path || ': ' || l_pre || ' is not an ARRAY of the schema');
        END IF;
      END LOOP;
    END LOOP;
    RETURN l;
  END index_of;

  PROCEDURE check_schema(p_schema IN t_schema) IS
    l t_index;
  BEGIN
    l := index_of(p_schema);
  END check_schema;

  -- ---------------------------------------------------------------------------
  -- the template against the schema (publication, 96a §5.2)
  -- ---------------------------------------------------------------------------
  -- the LOOP regions around a node and the node itself when a LOOP: the structural depth (96a §8), whatever the paths
  FUNCTION loop_depth(p_ri IN rad_pdf_ri.t_ri, p_id IN rad_pdf_ri.t_id) RETURN PLS_INTEGER IS
    l_id rad_pdf_ri.t_id := p_id;
    l_n  PLS_INTEGER := 0;
  BEGIN
    WHILE l_id IS NOT NULL LOOP
      IF p_ri.nodes(l_id).kind IN ('inline_region', 'block_region', 'row_region') AND p_ri.nodes(l_id).region_kind = 'LOOP' THEN
        l_n := l_n + 1;
      END IF;
      l_id := p_ri.nodes(l_id).parent;
    END LOOP;
    RETURN l_n;
  END loop_depth;

  PROCEDURE check_template_idx(p_ri IN rad_pdf_ri.t_ri, p_sch IN t_index) IS
    n  rad_pdf_ri.t_node;
    sp VARCHAR2(400);
    l_need VARCHAR2(30);
  BEGIN
    FOR id IN 1 .. rad_pdf_ri.node_count(p_ri) LOOP
      n := p_ri.nodes(id);
      IF n.kind IN ('tag', 'inline_region', 'block_region', 'row_region') THEN
        sp := schema_path(n.ref_path);
        IF NOT p_sch.EXISTS(sp) THEN fail(c_err_schema, n.kind || ' ' || id || ': unknown path ' || n.ref_path); END IF;
        l_need := CASE
                    WHEN n.kind = 'tag' THEN CASE n.tag_op WHEN 'FIELD' THEN 'TEXT' WHEN 'IMAGE' THEN 'IMAGE' ELSE 'BOOLEAN' END
                    WHEN n.region_kind = 'LOOP' THEN 'ARRAY'
                  END;
        IF l_need IS NOT NULL AND p_sch(sp).type <> l_need THEN
          fail(c_err_schema, n.kind || ' ' || id || ': ' || n.ref_path || ' is ' || p_sch(sp).type || ', the '
               || CASE WHEN n.kind = 'tag' THEN n.tag_op || ' tag' ELSE 'LOOP' END || ' needs ' || l_need);
        END IF;
        IF n.kind <> 'tag' AND n.region_kind = 'SECTION' AND p_sch(sp).type = 'ARRAY' THEN
          fail(c_err_schema, n.kind || ' ' || id || ': ' || n.ref_path || ' is an ARRAY: a LOOP, not a SECTION');
        END IF;
        IF n.kind <> 'tag' AND n.region_kind = 'LOOP' AND loop_depth(p_ri, id) > c_max_loop_depth THEN
          fail(c_err_budget, n.kind || ' ' || id || ': loops nested deeper than ' || c_max_loop_depth);
        END IF;
      END IF;
    END LOOP;
  END check_template_idx;

  PROCEDURE check_template(p_ri IN rad_pdf_ri.t_ri, p_schema IN t_schema) IS
  BEGIN
    rad_pdf_ri.validate(p_ri);
    IF p_ri.instance = 'Y' THEN fail(c_err_schema, 'an instance is not a template'); END IF;
    check_template_idx(p_ri, index_of(p_schema));
  END check_template;

  -- ---------------------------------------------------------------------------
  -- images (96a §5.1, §8): one validation, its result reused by the emission
  -- ---------------------------------------------------------------------------
  -- a dimension of an IMAGE in points: a positive number and a unit cm mm in px (96 px/in); NULL when invalid
  FUNCTION dim_pt(p_text IN VARCHAR2) RETURN NUMBER IS
    l_num NUMBER;
  BEGIN
    IF p_text IS NULL OR NOT regexp_like(p_text, '^[0-9]+(\.[0-9]+)?(cm|mm|in|px)$') THEN RETURN NULL; END IF;
    l_num := to_number(regexp_substr(p_text, '^[0-9]+(\.[0-9]+)?'), '99999999990D9999999999', 'NLS_NUMERIC_CHARACTERS=''.,''');
    IF l_num <= 0 THEN RETURN NULL; END IF;
    RETURN l_num * CASE substr(p_text, -2) WHEN 'cm' THEN 72 / 2.54 WHEN 'mm' THEN 72 / 25.4 WHEN 'in' THEN 72 ELSE 72 / 96 END;
  END dim_pt;

  -- the data-URL of an IMAGE value: PNG or JPEG, its base64 text from p_start; NULL format when not one of them
  PROCEDURE data_url(p_url IN CLOB, p_format OUT VARCHAR2, p_start OUT PLS_INTEGER) IS
    l_head VARCHAR2(30) := dbms_lob.substr(p_url, 30, 1);
  BEGIN
    IF l_head LIKE 'data:image/png;base64,%' THEN p_format := 'PNG'; p_start := 23;
    ELSIF l_head LIKE 'data:image/jpeg;base64,%' THEN p_format := 'JPEG'; p_start := 24;
    END IF;
  END data_url;

  -- an optional string member of an IMAGE value; '' is refused like a wrong value
  FUNCTION img_member(o IN json_object_t, k IN VARCHAR2, p_where IN VARCHAR2) RETURN VARCHAR2 IS
    l VARCHAR2(4000);
  BEGIN
    IF NOT o.has(k) THEN RETURN NULL; END IF;
    IF NOT o.get(k).is_string THEN fail(c_err_data, p_where || '.' || k || ': a string'); END IF;
    l := o.get_string(k);
    IF l IS NULL THEN fail(c_err_data, p_where || '.' || k || ': empty'); END IF;
    RETURN l;
  END img_member;

  -- the IMAGE value at p_where, checked in full (Oracle form, base64, the bytes of the declared format, pixels, budgets),
  -- its bytes registered once as a resource of the instance; returns its entry in m.imgs
  FUNCTION check_image(m IN OUT NOCOPY t_m, o IN json_object_t, p_where IN VARCHAR2) RETURN PLS_INTEGER IS
    l_url   CLOB;
    l_fmt   VARCHAR2(4);
    l_start PLS_INTEGER;
    l_bytes BLOB;
    l_dec   rad_pdf_img_decoder;
    l_img   rad_pdf_img_data;
    l_sha   VARCHAR2(64);
    l_res   rad_pdf_ri.t_id;
    l_n     PLS_INTEGER;
    l_len   NUMBER;
  BEGIN
    IF nvl(img_member(o, 'source', p_where), '#') <> 'URL' THEN fail(c_err_data, p_where || ': an IMAGE has source "URL"'); END IF;
    IF NOT o.has('url') OR NOT o.get('url').is_string THEN fail(c_err_data, p_where || ': an IMAGE has its url'); END IF;
    FOR d IN 1 .. 2 LOOP
      IF o.has(CASE d WHEN 1 THEN 'width' ELSE 'height' END)
         AND dim_pt(img_member(o, CASE d WHEN 1 THEN 'width' ELSE 'height' END, p_where)) IS NULL THEN
        fail(c_err_data, p_where || '.' || CASE d WHEN 1 THEN 'width' ELSE 'height' END
             || ': a positive size with a unit cm, mm, in or px');
      END IF;
    END LOOP;
    l_url := o.get_clob('url');
    data_url(l_url, l_fmt, l_start);
    IF l_fmt IS NULL THEN fail(c_err_data, p_where || ': only data:image/png or data:image/jpeg base64 URLs'); END IF;
    l_len := dbms_lob.getlength(l_url);
    IF (l_len - l_start + 1) * 3 / 4 > c_max_image_bytes THEN
      fail(c_err_budget, p_where || ': an image over ' || c_max_image_bytes || ' bytes');
    END IF;
    -- the same URL already checked (an image repeated by a loop): its entry
    FOR i IN 1 .. m.imgs.COUNT LOOP
      IF dbms_lob.getlength(m.imgs(i).url) = l_len AND dbms_lob.compare(m.imgs(i).url, l_url) = 0 THEN
        free_lob(l_url);
        RETURN i;
      END IF;
    END LOOP;
    BEGIN
      l_bytes := rad_pdf_codec.base64_decode(l_url, l_start);
    EXCEPTION WHEN OTHERS THEN fail(c_err_data, p_where || ': the url is not valid base64 (' || sqlerrm || ')');
    END;
    IF l_fmt = 'PNG' THEN l_dec := rad_pdf_png_decoder(NULL); ELSE l_dec := rad_pdf_jpeg_decoder(NULL); END IF;
    IF l_dec.detect(dbms_lob.substr(l_bytes, 16, 1)) <> 1 THEN
      fail(c_err_data, p_where || ': the bytes are not a ' || l_fmt || ' image');
    END IF;
    BEGIN
      l_img := l_dec.decode(l_bytes);
    EXCEPTION WHEN OTHERS THEN fail(c_err_data, p_where || ': not a valid ' || l_fmt || ' image (' || sqlerrm || ')');
    END;
    free_lob(l_img.pixels);
    IF l_img.width > c_max_image_px OR l_img.height > c_max_image_px THEN
      fail(c_err_budget, p_where || ': an image over ' || c_max_image_px || 'x' || c_max_image_px || ' pixels');
    END IF;
    l_sha := lower(rad_pdf_codec.sha256_hex(l_bytes));
    IF m.bysha.EXISTS(l_sha) THEN                        -- the same bytes under another URL: one resource
      l_res := m.bysha(l_sha);
    ELSE
      m.lob_bytes := m.lob_bytes + dbms_lob.getlength(l_bytes);
      IF m.lob_bytes + l_len > c_max_lob_bytes THEN
        fail(c_err_budget, p_where || ': the images of the document exceed ' || c_max_lob_bytes || ' bytes');
      END IF;
      l_res := rad_pdf_ri.add_image(m.out, l_bytes, l_fmt, l_img.width, l_img.height);
      m.bysha(l_sha) := l_res;
    END IF;
    free_lob(l_bytes);
    m.lob_bytes := m.lob_bytes + l_len;                  -- the URL kept by the cache
    l_n := m.imgs.COUNT + 1;
    m.imgs(l_n).url := l_url; m.imgs(l_n).res := l_res;
    m.imgs(l_n).px_w := l_img.width; m.imgs(l_n).px_h := l_img.height;
    RETURN l_n;
  EXCEPTION
    WHEN OTHERS THEN
      free_lob(l_bytes);
      IF l_img IS NOT NULL THEN free_lob(l_img.pixels); END IF;
      IF l_n IS NULL THEN free_lob(l_url); END IF;       -- not kept by the cache
      RAISE;
  END check_image;

  -- ---------------------------------------------------------------------------
  -- the data against the schema (every print, 96a §5.2)
  -- ---------------------------------------------------------------------------
  PROCEDURE check_value(m IN OUT NOCOPY t_m, p_obj IN json_object_t, p_key IN VARCHAR2, f IN t_field, p_where IN VARCHAR2) IS
    e  json_element_t;
    a  json_array_t;
    l_i PLS_INTEGER;
  BEGIN
    IF NOT p_obj.has(p_key) THEN
      IF f.required = 'Y' THEN fail(c_err_data, p_where || ': required, missing'); END IF;
      RETURN;
    END IF;
    e := p_obj.get(p_key);
    IF e.is_null THEN
      IF f.nullable = 'N' THEN fail(c_err_data, p_where || ': null is not allowed'); END IF;
      RETURN;
    END IF;
    CASE f.type
      WHEN 'TEXT'    THEN IF NOT e.is_string  THEN fail(c_err_data, p_where || ': a TEXT must be a string'); END IF;
      WHEN 'BOOLEAN' THEN IF NOT e.is_boolean THEN fail(c_err_data, p_where || ': a BOOLEAN must be true or false'); END IF;
      WHEN 'OBJECT'  THEN IF NOT e.is_object  THEN fail(c_err_data, p_where || ': an OBJECT must be an object'); END IF;
      WHEN 'ARRAY'   THEN
        IF NOT e.is_array THEN fail(c_err_data, p_where || ': an ARRAY must be an array'); END IF;
        a := treat(e AS json_array_t);
        FOR i IN 0 .. a.get_size - 1 LOOP
          IF NOT a.get(i).is_object THEN fail(c_err_data, p_where || '[' || i || ']: an element is an object'); END IF;
        END LOOP;
      WHEN 'IMAGE'   THEN
        IF NOT e.is_object THEN fail(c_err_data, p_where || ': an IMAGE is an object {"source":"URL","url":...}'); END IF;
        l_i := check_image(m, treat(e AS json_object_t), p_where);
    END CASE;
  END check_value;

  -- a field of the schema at an object: p_rel is the rest of its path from there (it may cross arrays: lines[].code)
  PROCEDURE check_at(m IN OUT NOCOPY t_m, p_obj IN json_object_t, p_rel IN VARCHAR2, f IN t_field, p_where IN VARCHAR2) IS
    l_seg  VARCHAR2(400) := regexp_substr(p_rel, '^[^.]+');
    l_rest VARCHAR2(400) := substr(p_rel, length(l_seg) + 2);
    l_name VARCHAR2(400) := replace(l_seg, '[]');
    e      json_element_t;
    a      json_array_t;
    l_here VARCHAR2(4000) := p_where || CASE WHEN p_where IS NOT NULL THEN '.' END || l_name;
  BEGIN
    IF l_rest IS NULL THEN check_value(m, p_obj, l_name, f, l_here); RETURN; END IF;
    IF NOT p_obj.has(l_name) THEN
      IF f.required = 'Y' AND l_seg NOT LIKE '%[]' THEN fail(c_err_data, p_where || CASE WHEN p_where IS NOT NULL THEN '.' END
                                                                  || p_rel || ': required, missing'); END IF;
      RETURN;                                            -- an absent array is the error of its own field
    END IF;
    e := p_obj.get(l_name);
    IF l_seg LIKE '%[]' THEN
      IF NOT e.is_array THEN RETURN; END IF;             -- the array's own field reports it
      a := treat(e AS json_array_t);
      FOR i IN 0 .. a.get_size - 1 LOOP
        IF a.get(i).is_object THEN check_at(m, treat(a.get(i) AS json_object_t), l_rest, f, l_here || '[' || i || ']'); END IF;
      END LOOP;
    ELSIF e.is_null THEN
      IF f.required = 'Y' THEN fail(c_err_data, l_here || ': null where an object holds ' || p_rel); END IF;
    ELSIF NOT e.is_object THEN
      fail(c_err_data, l_here || ': an object is expected (it holds ' || l_rest || ')');
    ELSE
      check_at(m, treat(e AS json_object_t), l_rest, f, l_here);
    END IF;
  END check_at;

  -- the size of the JSON text in bytes of the database character set (5 MB: 96a §8); characters undercount it
  FUNCTION text_bytes(p_text IN CLOB) RETURN NUMBER IS
    l_chars NUMBER := dbms_lob.getlength(p_text);
    l_bytes NUMBER := 0;
    l_pos   PLS_INTEGER := 1;
  BEGIN
    IF l_chars > c_max_json_bytes THEN RETURN l_chars; END IF;          -- a character is at least one byte
    WHILE l_pos <= l_chars LOOP
      l_bytes := l_bytes + lengthb(dbms_lob.substr(p_text, 8000, l_pos));
      l_pos := l_pos + 8000;
    END LOOP;
    RETURN l_bytes;
  END text_bytes;

  FUNCTION parse_data(p_data IN CLOB) RETURN json_object_t IS
    o json_object_t;
  BEGIN
    IF p_data IS NULL THEN fail(c_err_data, 'no data'); END IF;
    IF text_bytes(p_data) > c_max_json_bytes THEN fail(c_err_budget, 'data over ' || c_max_json_bytes || ' bytes'); END IF;
    BEGIN
      o := json_object_t.parse(p_data);
    EXCEPTION WHEN OTHERS THEN fail(c_err_data, 'the data is not a JSON object: ' || sqlerrm);
    END;
    RETURN o;
  END parse_data;

  PROCEDURE check_data_m(m IN OUT NOCOPY t_m, p_schema IN t_schema) IS
  BEGIN
    FOR i IN 1 .. p_schema.COUNT LOOP                    -- schema order: a container's error before its elements'
      check_at(m, m.root, p_schema(i).path, p_schema(i), NULL);
    END LOOP;
  END check_data_m;

  PROCEDURE check_data(p_data IN CLOB, p_schema IN t_schema) IS
    m t_m;
  BEGIN
    m.sch := index_of(p_schema);                         -- the schema checked first
    m.root := parse_data(p_data);
    m.out := rad_pdf_ri.new_instance;                    -- a scratch instance: the images are decoded and counted
    check_data_m(m, p_schema);
    free_state(m, TRUE);
  EXCEPTION
    WHEN OTHERS THEN
      free_state(m, TRUE);
      RAISE;
  END check_data;

  -- ---------------------------------------------------------------------------
  -- reading a resolved reference (96a §6.3): the current element of its scope, or the root
  -- ---------------------------------------------------------------------------
  FUNCTION locate(m IN t_m, p_scope IN VARCHAR2, p_path IN VARCHAR2) RETURN t_loc IS
    l      t_loc;
    l_rel  VARCHAR2(400);
    l_seg  VARCHAR2(400);
    l_obj  json_object_t;
    l_arr  json_array_t;
    e      json_element_t;
  BEGIN
    IF p_scope IS NULL THEN l_obj := m.root; l_rel := p_path;
    ELSE l_obj := m.ctx(p_scope); l_rel := substr(p_path, length(p_scope) + 4);       -- after "scope[]."
    END IF;
    LOOP
      l_seg := regexp_substr(l_rel, '^[^.]+');
      l_rel := substr(l_rel, length(l_seg) + 2);
      IF regexp_like(l_seg, '^[0-9]+$') THEN                -- an index: the element of the array in hand
        IF l_arr IS NULL OR to_number(l_seg) >= l_arr.get_size THEN RETURN l; END IF;   -- out of range: missing
        IF l_rel IS NULL THEN l.arr := l_arr; l.idx := to_number(l_seg); l.found := TRUE; RETURN l; END IF;
        e := l_arr.get(to_number(l_seg));
      ELSE
        IF l_obj IS NULL OR NOT l_obj.has(l_seg) THEN RETURN l; END IF;
        IF l_rel IS NULL THEN l.obj := l_obj; l.key := l_seg; l.found := TRUE; RETURN l; END IF;
        e := l_obj.get(l_seg);
      END IF;
      l_obj := NULL; l_arr := NULL;
      IF e.is_object THEN l_obj := treat(e AS json_object_t);
      ELSIF e.is_array THEN l_arr := treat(e AS json_array_t);
      ELSE RETURN l;                                       -- a scalar on the way: missing
      END IF;
    END LOOP;
  END locate;

  FUNCTION elem(p_loc IN t_loc) RETURN json_element_t IS
  BEGIN
    RETURN CASE WHEN p_loc.obj IS NOT NULL THEN p_loc.obj.get(p_loc.key) ELSE p_loc.arr.get(p_loc.idx) END;
  END elem;

  FUNCTION text_of(p_loc IN t_loc) RETURN CLOB IS
  BEGIN
    RETURN CASE WHEN p_loc.obj IS NOT NULL THEN p_loc.obj.get_clob(p_loc.key) ELSE p_loc.arr.get_clob(p_loc.idx) END;
  END text_of;

  FUNCTION bool_of(p_loc IN t_loc) RETURN BOOLEAN IS
  BEGIN
    RETURN CASE WHEN p_loc.obj IS NOT NULL THEN p_loc.obj.get_boolean(p_loc.key) ELSE p_loc.arr.get_boolean(p_loc.idx) END;
  END bool_of;

  -- SECTION: false, "", [], null and absent hide (96a §6.3)
  FUNCTION truthy(m IN t_m, p_scope IN VARCHAR2, p_path IN VARCHAR2) RETURN BOOLEAN IS
    l t_loc := locate(m, p_scope, p_path);
    e json_element_t;
    t CLOB;
    r BOOLEAN;
  BEGIN
    IF NOT l.found THEN RETURN FALSE; END IF;
    e := elem(l);
    IF e.is_null THEN RETURN FALSE; END IF;
    IF e.is_boolean THEN RETURN bool_of(l); END IF;
    IF e.is_string THEN
      t := text_of(l);
      r := nvl(dbms_lob.getlength(t), 0) > 0;
      free_lob(t);
      RETURN r;
    END IF;
    IF e.is_array THEN RETURN treat(e AS json_array_t).get_size > 0; END IF;
    RETURN TRUE;
  END truthy;

  -- the elements of a LOOP ([] when absent: check_data has refused a required array missing)
  FUNCTION elements(m IN t_m, p_scope IN VARCHAR2, p_path IN VARCHAR2) RETURN json_array_t IS
    l t_loc := locate(m, p_scope, p_path);
    e json_element_t;
  BEGIN
    IF NOT l.found THEN RETURN json_array_t(); END IF;
    e := elem(l);
    IF NOT e.is_array THEN fail(c_err_data, p_path || ': a LOOP needs an array'); END IF;
    RETURN treat(e AS json_array_t);
  END elements;

  -- a LOOP opens its path: the binding it hides is kept and given back when the loop ends (R2: one helper for the
  -- inline, block and row loops)
  FUNCTION loop_enter(m IN t_m, p_path IN VARCHAR2) RETURN t_saved IS
    s t_saved;
  BEGIN
    s.had := m.ctx.EXISTS(p_path);
    IF s.had THEN s.prev := m.ctx(p_path); END IF;
    RETURN s;
  END loop_enter;

  PROCEDURE loop_leave(m IN OUT NOCOPY t_m, p_path IN VARCHAR2, s IN t_saved) IS
  BEGIN
    IF s.had THEN m.ctx(p_path) := s.prev; ELSE m.ctx.DELETE(p_path); END IF;
  END loop_leave;

  PROCEDURE budget(m IN t_m) IS
  BEGIN
    IF rad_pdf_ri.node_count(m.out) > c_max_nodes THEN
      fail(c_err_budget, 'the merged document exceeds ' || c_max_nodes || ' nodes');
    END IF;
  END budget;

  -- ---------------------------------------------------------------------------
  -- the expansion
  -- ---------------------------------------------------------------------------
  -- a text of the data as inline nodes: a tab and a line break of the text become their nodes (a run holds neither);
  -- the node budget is checked at every node, before a long text can build past it
  PROCEDURE emit_text(m IN OUT NOCOPY t_m, p_par IN rad_pdf_ri.t_id, p_text IN CLOB, p_fmt IN rad_pdf_ri.t_run_fmt) IS
    l_len   PLS_INTEGER := nvl(dbms_lob.getlength(p_text), 0);
    l_pos   PLS_INTEGER := 1;
    l_chunk VARCHAR2(32767);
    l_buf   VARCHAR2(32767);
    l_at    PLS_INTEGER;
    x       rad_pdf_ri.t_id;
    c_step  CONSTANT PLS_INTEGER := 4000;                -- characters: at most 16000 bytes per run
    PROCEDURE flush IS
    BEGIN
      IF l_buf IS NOT NULL THEN x := rad_pdf_ri.run(m.out, p_par, l_buf, p_fmt); l_buf := NULL; budget(m); END IF;
    END;
  BEGIN
    WHILE l_pos <= l_len LOOP
      l_chunk := replace(dbms_lob.substr(p_text, c_step, l_pos), chr(13));
      l_pos := l_pos + c_step;
      LOOP
        l_at := regexp_instr(l_chunk, '[' || chr(9) || chr(10) || ']');
        IF l_at = 0 THEN l_buf := l_buf || l_chunk; EXIT; END IF;
        l_buf := l_buf || substr(l_chunk, 1, l_at - 1);
        flush;
        IF substr(l_chunk, l_at, 1) = chr(9) THEN x := rad_pdf_ri.tab(m.out, p_par);
        ELSE x := rad_pdf_ri.line_break(m.out, p_par); END IF;
        budget(m);
        l_chunk := substr(l_chunk, l_at + 1);
      END LOOP;
      IF length(l_buf) >= c_step THEN flush; END IF;
    END LOOP;
    flush;
  END emit_text;

  -- an IMAGE value: the entry check_data has made (same URL), sized by 96a §5.1
  PROCEDURE emit_image(m IN OUT NOCOPY t_m, p_par IN rad_pdf_ri.t_id, p_loc IN t_loc, p_avail IN NUMBER, p_where IN VARCHAR2) IS
    o   json_object_t := treat(elem(p_loc) AS json_object_t);
    i   PLS_INTEGER := check_image(m, o, p_where);       -- found in the cache: no second decoding
    l_w NUMBER := CASE WHEN o.has('width') THEN dim_pt(o.get_string('width')) END;
    l_h NUMBER := CASE WHEN o.has('height') THEN dim_pt(o.get_string('height')) END;
    x   rad_pdf_ri.t_id;
  BEGIN
    IF l_w IS NULL AND l_h IS NULL THEN                  -- natural size at 96 dpi, within the available width
      l_w := m.imgs(i).px_w * 72 / 96; l_h := m.imgs(i).px_h * 72 / 96;
      IF p_avail > 0 AND l_w > p_avail THEN l_h := l_h * p_avail / l_w; l_w := p_avail; END IF;
    ELSIF l_w IS NULL THEN l_w := l_h * m.imgs(i).px_w / m.imgs(i).px_h;
    ELSIF l_h IS NULL THEN l_h := l_w * m.imgs(i).px_h / m.imgs(i).px_w;
    END IF;
    x := rad_pdf_ri.image(m.out, p_par, m.imgs(i).res, round(l_w, 3), round(l_h, 3));
  END emit_image;

  PROCEDURE m_blocks(m IN OUT NOCOPY t_m, p_src IN rad_pdf_ri.t_id, p_dst IN rad_pdf_ri.t_id, p_avail IN NUMBER);

  PROCEDURE m_inlines(m IN OUT NOCOPY t_m, p_src IN rad_pdf_ri.t_id, p_par IN OUT NOCOPY rad_pdf_ri.t_id,
                      p_container IN rad_pdf_ri.t_id, p_para IN rad_pdf_ri.t_node, p_avail IN NUMBER) IS
    k   rad_pdf_ri.t_num_list := rad_pdf_ri.kids(m.src, p_src);
    n   rad_pdf_ri.t_node;
    l   t_loc;
    a   json_array_t;
    x   rad_pdf_ri.t_id;
    e   json_element_t;
    s   t_saved;
    t   CLOB;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      n := m.src.nodes(k(j));
      CASE n.kind
        WHEN 'run'        THEN x := rad_pdf_ri.run(m.out, p_par, n.text, n.fmt);
        WHEN 'field'      THEN x := rad_pdf_ri.field(m.out, p_par, n.field_code, n.fmt);
        WHEN 'tab'        THEN x := rad_pdf_ri.tab(m.out, p_par);
        WHEN 'line_break' THEN x := rad_pdf_ri.line_break(m.out, p_par);
        WHEN 'image'      THEN x := rad_pdf_ri.image(m.out, p_par, n.image_res, n.width, n.height);
        WHEN 'tag' THEN
          l := locate(m, n.ref_scope, n.ref_path);
          IF l.found THEN
            e := elem(l);
            IF NOT e.is_null THEN
              CASE n.tag_op
                WHEN 'FIELD' THEN
                  IF NOT e.is_string THEN fail(c_err_data, n.ref_path || ': a text is expected'); END IF;
                  t := text_of(l);
                  emit_text(m, p_par, t, n.fmt);
                  free_lob(t);
                WHEN 'IMAGE' THEN emit_image(m, p_par, l, p_avail, n.ref_path);
                ELSE                                     -- PAGEBREAK: BOOLEAN only; true splits the paragraph
                  IF NOT e.is_boolean THEN fail(c_err_data, n.ref_path || ': a page break needs true or false'); END IF;
                  IF bool_of(l) THEN
                    x := rad_pdf_ri.page_break(m.out, p_container);
                    p_par := rad_pdf_ri.paragraph(m.out, p_container, p_para.para, p_para.tabs);
                  END IF;
              END CASE;
            END IF;
          END IF;
        WHEN 'inline_region' THEN
          IF n.region_kind = 'LOOP' THEN
            a := elements(m, n.ref_scope, n.ref_path);
            s := loop_enter(m, n.ref_path);
            FOR i IN 0 .. a.get_size - 1 LOOP
              m.ctx(n.ref_path) := treat(a.get(i) AS json_object_t);
              m_inlines(m, k(j), p_par, p_container, p_para, p_avail);
              budget(m);
            END LOOP;
            loop_leave(m, n.ref_path, s);
          ELSIF truthy(m, n.ref_scope, n.ref_path) THEN
            m_inlines(m, k(j), p_par, p_container, p_para, p_avail);
          END IF;
      END CASE;
      budget(m);
    END LOOP;
  END m_inlines;

  PROCEDURE m_paragraph(m IN OUT NOCOPY t_m, p_src IN rad_pdf_ri.t_id, p_dst IN rad_pdf_ri.t_id, p_avail IN NUMBER) IS
    n   rad_pdf_ri.t_node := m.src.nodes(p_src);
    l_p rad_pdf_ri.t_id;
  BEGIN
    l_p := rad_pdf_ri.paragraph(m.out, p_dst, n.para, n.tabs);
    m_inlines(m, p_src, l_p, p_dst, n, p_avail - n.para.ind_left - n.para.ind_right);
  END m_paragraph;

  -- the rows a table item gives with these data (a LOOP: one per element; a SECTION: 0 or 1)
  FUNCTION rows_of(m IN t_m, p_item IN rad_pdf_ri.t_id) RETURN PLS_INTEGER IS
    n rad_pdf_ri.t_node := m.src.nodes(p_item);
  BEGIN
    IF n.kind = 'row' THEN RETURN 1; END IF;
    IF n.region_kind = 'LOOP' THEN RETURN elements(m, n.ref_scope, n.ref_path).get_size; END IF;
    RETURN CASE WHEN truthy(m, n.ref_scope, n.ref_path) THEN 1 ELSE 0 END;
  END rows_of;

  PROCEDURE m_row(m IN OUT NOCOPY t_m, p_src IN rad_pdf_ri.t_id, p_table IN rad_pdf_ri.t_id, p_grid IN rad_pdf_ri.t_num_list) IS
    n     rad_pdf_ri.t_node := m.src.nodes(p_src);
    k     rad_pdf_ri.t_num_list := rad_pdf_ri.kids(m.src, p_src);
    l_r   rad_pdf_ri.t_id;
    l_c   rad_pdf_ri.t_id;
    l_col PLS_INTEGER := 1;
    l_w   NUMBER;
    cf    rad_pdf_ri.t_cell_fmt;
    pf    rad_pdf_ri.t_para_fmt;
  BEGIN
    l_r := rad_pdf_ri.row_(m.out, p_table, n.header, n.cant_split);
    FOR j IN 1 .. k.COUNT LOOP
      cf := m.src.nodes(k(j)).cell;
      l_w := 0;
      FOR c IN l_col .. l_col + cf.grid_span - 1 LOOP l_w := l_w + p_grid(c); END LOOP;
      l_col := l_col + cf.grid_span;
      l_c := rad_pdf_ri.cell(m.out, l_r, cf);
      m_blocks(m, k(j), l_c, l_w - cf.mar_left - cf.mar_right);
      IF rad_pdf_ri.kids(m.out, l_c).COUNT = 0 THEN      -- every block omitted: a cell keeps an empty paragraph (Word)
        l_c := rad_pdf_ri.paragraph(m.out, l_c, pf);
      END IF;
    END LOOP;
  END m_row;

  PROCEDURE m_table(m IN OUT NOCOPY t_m, p_src IN rad_pdf_ri.t_id, p_dst IN rad_pdf_ri.t_id) IS
    n     rad_pdf_ri.t_node := m.src.nodes(p_src);
    k     rad_pdf_ri.t_num_list := rad_pdf_ri.kids(m.src, p_src);
    l_t   rad_pdf_ri.t_id;
    l_cnt PLS_INTEGER := 0;
    a     json_array_t;
    rn    rad_pdf_ri.t_node;
    s     t_saved;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP l_cnt := l_cnt + rows_of(m, k(j)); END LOOP;
    IF l_cnt = 0 THEN RETURN; END IF;                    -- no row with these data: no table (a table has rows)
    l_t := rad_pdf_ri.table_(m.out, p_dst, n.grid, n.borders);
    FOR j IN 1 .. k.COUNT LOOP
      rn := m.src.nodes(k(j));
      IF rn.kind = 'row' THEN m_row(m, k(j), l_t, n.grid);
      ELSIF rn.region_kind = 'LOOP' THEN
        a := elements(m, rn.ref_scope, rn.ref_path);
        s := loop_enter(m, rn.ref_path);
        FOR i IN 0 .. a.get_size - 1 LOOP
          m.ctx(rn.ref_path) := treat(a.get(i) AS json_object_t);
          m_row(m, rad_pdf_ri.kids(m.src, k(j))(1), l_t, n.grid);
          budget(m);
        END LOOP;
        loop_leave(m, rn.ref_path, s);
      ELSIF truthy(m, rn.ref_scope, rn.ref_path) THEN
        m_row(m, rad_pdf_ri.kids(m.src, k(j))(1), l_t, n.grid);
      END IF;
    END LOOP;
  END m_table;

  PROCEDURE m_blocks(m IN OUT NOCOPY t_m, p_src IN rad_pdf_ri.t_id, p_dst IN rad_pdf_ri.t_id, p_avail IN NUMBER) IS
    k rad_pdf_ri.t_num_list := rad_pdf_ri.kids(m.src, p_src);
    n rad_pdf_ri.t_node;
    a json_array_t;
    x rad_pdf_ri.t_id;
    s t_saved;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      n := m.src.nodes(k(j));
      CASE n.kind
        WHEN 'paragraph'  THEN m_paragraph(m, k(j), p_dst, p_avail);
        WHEN 'table'      THEN m_table(m, k(j), p_dst);
        WHEN 'page_break' THEN x := rad_pdf_ri.page_break(m.out, p_dst);
        WHEN 'fixed_box'  THEN x := rad_pdf_ri.fixed_box(m.out, p_dst, n.image_res, n.width, n.height, n.keep_next);
        WHEN 'block_region' THEN
          IF n.region_kind = 'LOOP' THEN
            a := elements(m, n.ref_scope, n.ref_path);
            s := loop_enter(m, n.ref_path);
            FOR i IN 0 .. a.get_size - 1 LOOP
              m.ctx(n.ref_path) := treat(a.get(i) AS json_object_t);
              m_blocks(m, k(j), p_dst, p_avail);
              budget(m);
            END LOOP;
            loop_leave(m, n.ref_path, s);
          ELSIF truthy(m, n.ref_scope, n.ref_path) THEN
            m_blocks(m, k(j), p_dst, p_avail);
          END IF;
      END CASE;
      budget(m);
    END LOOP;
  END m_blocks;

  FUNCTION merge(p_ri IN rad_pdf_ri.t_ri, p_schema IN t_schema, p_data IN CLOB) RETURN rad_pdf_ri.t_ri IS
    m   t_m;
    s   rad_pdf_ri.t_node;
    z   rad_pdf_ri.t_num_list;
    x   rad_pdf_ri.t_id;
  BEGIN
    rad_pdf_ri.validate(p_ri);                           -- the consume boundary of the RI
    IF p_ri.instance = 'Y' THEN fail(c_err_schema, 'an instance is not a template'); END IF;
    m.sch := index_of(p_schema);
    check_template_idx(p_ri, m.sch);
    m.root := parse_data(p_data);
    m.src := p_ri;
    m.out := rad_pdf_ri.new_instance;
    FOR i IN 1 .. p_ri.images.COUNT LOOP                 -- the template's images keep their ids
      m.lob_bytes := m.lob_bytes + dbms_lob.getlength(p_ri.images(i).bytes);
      IF m.lob_bytes > c_max_lob_bytes THEN fail(c_err_budget, 'the images of the template exceed ' || c_max_lob_bytes || ' bytes'); END IF;
      x := rad_pdf_ri.add_image(m.out, p_ri.images(i).bytes, p_ri.images(i).format, p_ri.images(i).px_w, p_ri.images(i).px_h);
      m.bysha(p_ri.images(i).sha256) := x;
    END LOOP;
    check_data_m(m, p_schema);                           -- every IMAGE value decoded once, its resource registered
    s := p_ri.nodes(p_ri.section_id);
    x := rad_pdf_ri.section(m.out, s.page_w, s.page_h, s.orientation, s.mar_top, s.mar_bottom, s.mar_left, s.mar_right,
                            s.mar_header, s.mar_footer, s.title_page);
    z := rad_pdf_ri.kids(p_ri, p_ri.section_id);
    FOR i IN 1 .. z.COUNT LOOP
      m_blocks(m, z(i), rad_pdf_ri.zone(m.out, p_ri.nodes(z(i)).zone_name), s.page_w - s.mar_left - s.mar_right);
    END LOOP;
    rad_pdf_ri.seal(m.out);
    free_state(m, FALSE);
    RETURN m.out;
  EXCEPTION
    WHEN OTHERS THEN
      free_state(m, TRUE);
      RAISE;
  END merge;

END rad_pdf_merge;
/
