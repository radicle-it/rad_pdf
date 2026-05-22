CREATE OR REPLACE PACKAGE BODY rad_pdf_fonts IS
/*
  rad_pdf_fonts body — Phase 4 of the RAD_PDF modular refactoring.

  Key changes from src/new/rad_pdf_fonts.pkb:
    - Per-document state: g_doc_state tracks doc_fonts and used_fonts per handle.
    - load_ttf / load_ttc gain p_doc as first parameter.
    - close_doc(p_doc) replaces reset_fonts; frees only doc-scoped fonts.
    - write_font_objects(p_doc) uses rad_pdf_serial.xxx(p_doc) instead of pdf_writer.
    - mark_font_used sets g_doc_state(p_doc).used_fonts(p_font_idx) := 0.
    - All DBMS_LOB.APPEND(BLOB, RAW) replaced with DBMS_LOB.WRITEAPPEND.
    - to_char_round replaced with rad_pdf_codec.fmt(x, 2).
    - CID variable-reuse bug fixed: l_fi (font index), l_gi (glyph index),
      l_font_obj (initial Type0 object number).
*/

-- ---------------------------------------------------------------------------
-- Internal types
-- ---------------------------------------------------------------------------
  TYPE t_pls_tab IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
  TYPE t_name_idx IS TABLE OF VARCHAR2(20) INDEX BY VARCHAR2(210);

  TYPE t_font IS RECORD (
    standard          BOOLEAN      := FALSE,
    preloaded         BOOLEAN      := FALSE,
    family            VARCHAR2(100),
    style             VARCHAR2(2),
    name              VARCHAR2(100),
    fontname          VARCHAR2(100),
    subtype           VARCHAR2(15),
    encoding          VARCHAR2(100),
    charset           VARCHAR2(1000),
    cid               BOOLEAN      := FALSE,
    embed             BOOLEAN      := FALSE,
    compress_font     BOOLEAN      := TRUE,
    fontsize          NUMBER       := 12,
    unit_norm         NUMBER,
    bb_xmin           PLS_INTEGER,
    bb_ymin           PLS_INTEGER,
    bb_xmax           PLS_INTEGER,
    bb_ymax           PLS_INTEGER,
    flags             PLS_INTEGER,
    first_char        PLS_INTEGER,
    last_char         PLS_INTEGER,
    italic_angle      NUMBER,
    ascent            PLS_INTEGER,
    descent           PLS_INTEGER,
    capheight         PLS_INTEGER,
    stemv             PLS_INTEGER,
    diff              VARCHAR2(32767),
    char_width_tab    t_pls_tab,
    used_chars        t_pls_tab,
    code2glyph        t_pls_tab,
    hmetrics          t_pls_tab,
    loca              t_pls_tab,
    numGlyphs         PLS_INTEGER,
    indexToLocFormat  PLS_INTEGER,
    fontfile2         BLOB,
    ttf_offset        PLS_INTEGER  := 1
  );

  TYPE t_font_tab IS TABLE OF t_font INDEX BY PLS_INTEGER;

  -- Per-document state record
  TYPE t_font_doc_state IS RECORD (
    doc_fonts  t_pls_tab,   -- custom font indices belonging to this doc (freed on close)
    used_fonts t_pls_tab    -- font indices written to page streams (for write_font_objects)
  );
  TYPE t_font_doc_map IS TABLE OF t_font_doc_state INDEX BY PLS_INTEGER;

-- ---------------------------------------------------------------------------
-- Package-level state
-- ---------------------------------------------------------------------------
  g_fonts      t_font_tab;
  g_std_init   BOOLEAN := FALSE;
  g_name_idx   t_name_idx;               -- key = lower(fontname), value = font_idx as VARCHAR2
  g_doc_state  t_font_doc_map;           -- per-document state

-- ---------------------------------------------------------------------------
-- PRIVATE: raw TTF binary access helpers
-- ---------------------------------------------------------------------------
  FUNCTION num2raw(p_value IN NUMBER) RETURN RAW IS
  BEGIN
    RETURN HEXTORAW(TO_CHAR(p_value, 'FM0XXXXXXX'));
  END num2raw;

  FUNCTION raw2num(p_value IN RAW) RETURN NUMBER IS
  BEGIN
    RETURN TO_NUMBER(RAWTOHEX(p_value), 'XXXXXXXX');
  END raw2num;

  FUNCTION raw2num(p_value IN RAW, p_pos IN PLS_INTEGER, p_len IN PLS_INTEGER)
    RETURN PLS_INTEGER IS
  BEGIN
    RETURN TO_NUMBER(RAWTOHEX(UTL_RAW.SUBSTR(p_value, p_pos, p_len)), 'XXXXXXXX');
  END raw2num;

  FUNCTION blob2num(p_blob IN BLOB, p_len IN PLS_INTEGER, p_pos IN PLS_INTEGER)
    RETURN NUMBER IS
  BEGIN
    RETURN TO_NUMBER(RAWTOHEX(DBMS_LOB.SUBSTR(p_blob, p_len, p_pos)), 'XXXXXXXX');
  END blob2num;

  FUNCTION to_short(p_val IN RAW) RETURN NUMBER IS
    t_rv NUMBER;
  BEGIN
    t_rv := TO_NUMBER(RAWTOHEX(p_val), 'XXXXXXXXXX');
    IF t_rv > 32767 THEN t_rv := t_rv - 65536; END IF;
    RETURN t_rv;
  END to_short;

-- ---------------------------------------------------------------------------
-- PRIVATE: security validation helpers
-- ---------------------------------------------------------------------------
  PROCEDURE assert_dir_and_file(p_dir IN VARCHAR2, p_filename IN VARCHAR2) IS
  BEGIN
    IF NOT REGEXP_LIKE(UPPER(p_dir), '^[A-Z0-9_$#]+$') THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_fonts: invalid Oracle directory name "' || p_dir || '"', TRUE);
    END IF;
    IF p_filename IS NULL OR
       INSTR(p_filename, '..') > 0 OR
       INSTR(p_filename, '/') > 0  OR
       INSTR(p_filename, '\') > 0  OR
       INSTR(p_filename, CHR(0)) > 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_fonts: invalid filename "' || NVL(p_filename,'<null>') || '"', TRUE);
    END IF;
  END assert_dir_and_file;

  PROCEDURE assert_https_url(p_url IN VARCHAR2) IS
  BEGIN
    IF p_url IS NULL OR LOWER(SUBSTR(p_url, 1, 8)) != 'https://' THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_fonts: only HTTPS URLs are allowed for font loading', TRUE);
    END IF;
  END assert_https_url;

-- ---------------------------------------------------------------------------
-- PRIVATE: name-index helpers
-- ---------------------------------------------------------------------------
  PROCEDURE register_font_name(p_idx IN PLS_INTEGER) IS
  BEGIN
    g_name_idx(LOWER(g_fonts(p_idx).fontname)) := TO_CHAR(p_idx);
    IF LOWER(g_fonts(p_idx).family) IS NOT NULL AND
       LOWER(g_fonts(p_idx).style)  IS NOT NULL THEN
      g_name_idx(LOWER(g_fonts(p_idx).family) || '|' || LOWER(g_fonts(p_idx).style))
        := TO_CHAR(p_idx);
    END IF;
  END register_font_name;

-- ---------------------------------------------------------------------------
-- PRIVATE: standard-font width table from CSV
-- ---------------------------------------------------------------------------
  FUNCTION decode_widths(p_csv IN VARCHAR2) RETURN t_pls_tab IS
    l_rv  t_pls_tab;
    l_pos PLS_INTEGER := 1;
    l_nxt PLS_INTEGER;
    l_val PLS_INTEGER;
  BEGIN
    IF p_csv IS NOT NULL THEN
      FOR i IN 0 .. 255 LOOP
        l_nxt := INSTR(p_csv, ',', l_pos);
        IF l_nxt = 0 THEN l_nxt := LENGTH(p_csv) + 1; END IF;
        l_val := TO_NUMBER(SUBSTR(p_csv, l_pos, l_nxt - l_pos));
        IF l_val != 0 THEN l_rv(i) := l_val; END IF;
        l_pos := l_nxt + 1;
      END LOOP;
    END IF;
    RETURN l_rv;
  END decode_widths;

-- ---------------------------------------------------------------------------
-- PRIVATE: initialise one standard font entry
-- ---------------------------------------------------------------------------
  PROCEDURE init_std_font(p_idx   IN PLS_INTEGER, p_family IN VARCHAR2,
                          p_style IN VARCHAR2,    p_name   IN VARCHAR2,
                          p_csv   IN VARCHAR2) IS
  BEGIN
    g_fonts(p_idx).standard   := TRUE;
    g_fonts(p_idx).preloaded  := TRUE;
    g_fonts(p_idx).family     := p_family;
    g_fonts(p_idx).style      := p_style;
    g_fonts(p_idx).name       := p_name;
    g_fonts(p_idx).fontname   := p_name;
    g_fonts(p_idx).encoding   := 'WE8MSWIN1252';
    g_fonts(p_idx).charset    :=
      SUBSTR(SYS_CONTEXT('USERENV','LANGUAGE'), 1,
             INSTR(SYS_CONTEXT('USERENV','LANGUAGE'), '.')) || 'WE8MSWIN1252';
    g_fonts(p_idx).char_width_tab := decode_widths(p_csv);
    register_font_name(p_idx);
  END init_std_font;

-- ---------------------------------------------------------------------------
-- Standard font loading (idempotent, per-session)
-- ---------------------------------------------------------------------------
  PROCEDURE load_standard_fonts IS
    c_hv  CONSTANT VARCHAR2(2000) :=
      '278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,' ||
      '278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,355,556,' ||
      '556,889,667,191,333,333,389,584,278,333,278,278,556,556,556,556,556,556,' ||
      '556,556,556,556,278,278,584,584,584,556,1015,667,667,722,722,667,611,778,' ||
      '722,278,500,667,556,833,722,778,667,778,722,667,611,722,667,944,667,667,' ||
      '611,278,278,278,469,556,333,556,556,500,556,556,278,556,556,222,222,500,' ||
      '222,833,556,556,556,556,333,500,278,556,500,722,500,500,500,334,260,334,' ||
      '584,350,556,350,222,556,333,1000,556,556,333,1000,667,333,1000,350,611,' ||
      '350,350,222,222,333,333,350,556,1000,333,1000,500,333,944,350,500,667,' ||
      '278,333,556,556,556,556,260,556,333,737,370,556,584,333,737,333,400,584,' ||
      '333,333,333,556,537,278,333,333,365,556,834,834,834,611,667,667,667,667,' ||
      '667,667,1000,722,667,667,667,667,278,278,278,278,722,722,778,778,778,778,' ||
      '778,584,778,722,722,722,722,667,667,611,556,556,556,556,556,556,889,500,' ||
      '556,556,556,556,278,278,278,278,556,556,556,556,556,556,556,584,611,556,' ||
      '556,556,556,500,556,500';
    c_hvb CONSTANT VARCHAR2(2000) :=
      '278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,' ||
      '278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,333,474,556,' ||
      '556,889,722,238,333,333,389,584,278,333,278,278,556,556,556,556,556,556,' ||
      '556,556,556,556,333,333,584,584,584,611,975,722,722,722,722,667,611,778,' ||
      '722,278,556,722,611,833,722,778,667,778,722,667,611,722,667,944,667,667,' ||
      '611,333,278,333,584,556,333,556,611,556,611,556,333,611,611,278,278,556,' ||
      '278,889,611,611,611,611,389,556,333,611,556,778,556,556,500,389,280,389,' ||
      '584,350,556,350,278,556,500,1000,556,556,333,1000,667,333,1000,350,611,' ||
      '350,350,278,278,500,500,350,556,1000,333,1000,556,333,944,350,500,667,' ||
      '278,333,556,556,556,556,280,556,333,737,370,556,584,333,737,333,400,584,' ||
      '333,333,333,611,556,278,333,333,365,556,834,834,834,611,722,722,722,722,' ||
      '722,722,1000,722,667,667,667,667,278,278,278,278,722,722,778,778,778,778,' ||
      '778,584,778,722,722,722,722,667,667,611,556,556,556,556,556,556,889,556,' ||
      '556,556,556,556,278,278,278,278,611,611,611,611,611,611,611,584,611,611,' ||
      '611,611,611,556,611,556';
    c_tr  CONSTANT VARCHAR2(2000) :=
      '250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,' ||
      '250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,333,408,500,' ||
      '500,833,778,180,333,333,500,564,250,333,250,278,500,500,500,500,500,500,' ||
      '500,500,500,500,278,278,564,564,564,444,921,722,667,667,722,611,556,722,' ||
      '722,333,389,722,611,889,722,722,556,722,667,556,611,722,722,944,722,722,' ||
      '611,333,278,333,469,500,333,444,500,444,500,444,333,500,500,278,278,500,' ||
      '278,778,500,500,500,500,333,389,278,500,500,722,500,500,444,480,200,480,' ||
      '541,350,500,350,333,500,444,1000,500,500,333,1000,556,333,889,350,611,' ||
      '350,350,333,333,444,444,350,500,1000,333,980,389,333,722,350,444,722,' ||
      '250,333,500,500,500,500,200,500,333,760,276,500,564,333,760,333,400,564,' ||
      '300,300,333,500,453,250,333,300,310,500,750,750,750,444,722,722,722,722,' ||
      '722,722,889,667,611,611,611,611,333,333,333,333,722,722,722,722,722,722,' ||
      '722,564,722,722,722,722,722,722,556,500,444,444,444,444,444,444,667,444,' ||
      '444,444,444,444,278,278,278,278,500,500,500,500,500,500,500,564,500,500,' ||
      '500,500,500,500,500,500';
    c_ti  CONSTANT VARCHAR2(2000) :=
      '250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,' ||
      '250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,333,420,500,' ||
      '500,833,778,214,333,333,500,675,250,333,250,278,500,500,500,500,500,500,' ||
      '500,500,500,500,333,333,675,675,675,500,920,611,611,667,722,611,611,722,' ||
      '722,333,444,667,556,833,667,722,611,722,611,500,556,722,611,833,611,556,' ||
      '556,389,278,389,422,500,333,500,500,444,500,444,278,500,500,278,278,444,' ||
      '278,722,500,500,500,500,389,389,278,500,444,667,444,444,389,400,275,400,' ||
      '541,350,500,350,333,500,556,889,500,500,333,1000,500,333,944,350,556,' ||
      '350,350,333,333,556,556,350,500,889,333,980,389,333,667,350,389,556,' ||
      '250,389,500,500,500,500,275,500,333,760,276,500,675,333,760,333,400,675,' ||
      '300,300,333,500,523,250,333,300,310,500,750,750,750,500,611,611,611,611,' ||
      '611,611,889,667,611,611,611,611,333,333,333,333,722,667,722,722,722,722,' ||
      '722,675,722,722,722,722,722,556,611,500,500,500,500,500,500,500,667,444,' ||
      '444,444,444,444,278,278,278,278,500,500,500,500,500,500,500,675,500,500,' ||
      '500,500,500,444,500,444';
    c_tb  CONSTANT VARCHAR2(2000) :=
      '250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,' ||
      '250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,333,555,500,' ||
      '500,1000,833,278,333,333,500,570,250,333,250,278,500,500,500,500,500,500,' ||
      '500,500,500,500,333,333,570,570,570,500,930,722,667,722,722,667,611,778,' ||
      '778,389,500,778,667,944,722,778,611,778,722,556,667,722,722,1000,722,722,' ||
      '667,333,278,333,581,500,333,500,556,444,556,444,333,500,556,278,333,556,' ||
      '278,833,556,500,556,556,444,389,333,556,500,722,500,500,444,394,220,394,' ||
      '520,350,500,350,333,500,500,1000,500,500,333,1000,556,333,1000,350,667,' ||
      '350,350,333,333,500,500,350,500,1000,333,1000,389,333,722,350,444,722,' ||
      '250,333,500,500,500,500,220,500,333,747,300,500,570,333,747,333,400,570,' ||
      '300,300,333,556,540,250,333,300,330,500,750,750,750,500,722,722,722,722,' ||
      '722,722,1000,722,667,667,667,667,389,389,389,389,722,722,778,778,778,778,' ||
      '778,570,778,722,722,722,722,722,611,556,500,500,500,500,500,500,722,444,' ||
      '444,444,444,444,278,278,278,278,500,556,500,500,500,500,500,570,500,556,' ||
      '556,556,556,500,556,500';
    c_tbi CONSTANT VARCHAR2(2000) :=
      '250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,' ||
      '250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,389,555,500,' ||
      '500,833,778,278,333,333,500,570,250,333,250,278,500,500,500,500,500,500,' ||
      '500,500,500,500,333,333,570,570,570,500,832,667,667,667,722,667,667,722,' ||
      '778,389,500,667,611,889,722,722,611,722,667,556,611,722,667,889,667,611,' ||
      '611,333,278,333,570,500,333,500,500,444,500,444,333,500,556,278,278,500,' ||
      '278,778,556,500,500,500,389,389,278,556,444,667,500,444,389,348,220,348,' ||
      '570,250,500,250,278,500,500,1000,500,500,333,1000,556,333,944,250,611,' ||
      '250,250,333,333,500,500,350,500,1000,333,1000,389,333,722,250,389,611,' ||
      '250,389,500,500,500,500,220,500,333,747,266,500,606,333,747,333,400,570,' ||
      '300,300,333,576,500,250,333,300,300,500,750,750,750,500,667,667,667,667,' ||
      '667,667,944,667,667,667,667,667,389,389,389,389,722,722,722,722,722,722,' ||
      '722,570,722,722,722,722,722,611,611,500,500,500,500,500,500,500,722,444,' ||
      '444,444,444,444,278,278,278,278,500,556,500,500,500,500,500,570,500,556,' ||
      '556,556,556,444,500,444';
    c_sym CONSTANT VARCHAR2(2000) :=
      '250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,' ||
      '250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,333,713,500,' ||
      '549,833,778,439,333,333,500,549,250,549,250,278,500,500,500,500,500,500,' ||
      '500,500,500,500,278,278,549,549,549,444,549,722,667,722,612,611,763,603,' ||
      '722,333,631,722,686,889,722,722,768,741,556,592,611,690,439,768,645,795,' ||
      '611,333,863,333,658,500,500,631,549,549,494,439,521,411,603,329,603,549,' ||
      '549,576,521,549,549,521,549,603,439,576,713,686,493,686,494,480,200,480,' ||
      '549,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,' ||
      '0,750,620,247,549,167,713,500,753,753,753,753,1042,987,603,987,603,400,' ||
      '549,411,549,549,713,494,460,549,549,549,549,0,603,1000,658,823,686,795,' ||
      '987,768,768,823,768,768,713,713,713,713,713,713,713,768,713,790,790,890,' ||
      '823,549,250,713,603,603,1042,987,603,987,603,494,329,790,790,786,713,384,' ||
      '384,384,384,384,384,494,494,494,494,0,329,274,686,686,686,384,384,384,' ||
      '384,384,384,494,494,494,0';
    c_zd  CONSTANT VARCHAR2(2000) :=
      '0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,278,' ||
      '974,961,974,980,719,789,790,791,690,960,939,549,855,911,933,911,945,974,' ||
      '755,846,762,761,571,677,763,760,759,754,494,552,537,577,692,786,788,788,' ||
      '790,793,794,816,823,789,841,823,833,816,831,923,744,723,749,790,792,695,' ||
      '776,768,792,759,707,708,682,701,826,815,762,761,571,677,763,760,759,754,' ||
      '494,552,537,577,692,786,788,788,790,793,794,816,823,789,841,823,833,816,' ||
      '831,923,744,723,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,' ||
      '0,0,0,0,0,0,0,0,732,544,544,910,667,760,760,776,595,694,626,788,788,788,' ||
      '788,816,816,789,789,789,789,789,789,789,789,789,789,789,789,789,789,894,' ||
      '838,1016,458,748,924,748,918,927,928,928,834,873,828,924,924,917,930,931,' ||
      '463,883,836,836,867,867,696,696,874,0,874,760,946,771,865,771,888,967,' ||
      '888,831,873,927,970,918,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0';
  BEGIN
    IF g_std_init THEN RETURN; END IF;

    init_std_font(1,  'helvetica',    'N',  'Helvetica',             c_hv);
    init_std_font(2,  'helvetica',    'I',  'Helvetica-Oblique',     c_hv);
    init_std_font(3,  'helvetica',    'B',  'Helvetica-Bold',        c_hvb);
    init_std_font(4,  'helvetica',    'BI', 'Helvetica-BoldOblique', c_hvb);
    init_std_font(5,  'times',        'N',  'Times-Roman',           c_tr);
    init_std_font(6,  'times',        'I',  'Times-Italic',          c_ti);
    init_std_font(7,  'times',        'B',  'Times-Bold',            c_tb);
    init_std_font(8,  'times',        'BI', 'Times-BoldItalic',      c_tbi);

    -- Courier family: fixed width 600 units for all characters
    g_fonts(9).standard := TRUE; g_fonts(9).preloaded := TRUE;
    g_fonts(9).family := 'courier'; g_fonts(9).style := 'N';
    g_fonts(9).name := 'Courier'; g_fonts(9).fontname := 'Courier';
    g_fonts(9).encoding := 'WE8MSWIN1252';
    g_fonts(9).charset :=
      SUBSTR(SYS_CONTEXT('USERENV','LANGUAGE'), 1,
             INSTR(SYS_CONTEXT('USERENV','LANGUAGE'), '.')) || 'WE8MSWIN1252';
    FOR i IN 0 .. 255 LOOP g_fonts(9).char_width_tab(i) := 600; END LOOP;
    register_font_name(9);

    g_fonts(10) := g_fonts(9);
    g_fonts(10).style := 'I'; g_fonts(10).name := 'Courier-Oblique';
    g_fonts(10).fontname := 'Courier-Oblique';
    register_font_name(10);

    g_fonts(11) := g_fonts(9);
    g_fonts(11).style := 'B'; g_fonts(11).name := 'Courier-Bold';
    g_fonts(11).fontname := 'Courier-Bold';
    register_font_name(11);

    g_fonts(12) := g_fonts(9);
    g_fonts(12).style := 'BI'; g_fonts(12).name := 'Courier-BoldOblique';
    g_fonts(12).fontname := 'Courier-BoldOblique';
    register_font_name(12);

    init_std_font(13, 'symbol',       'N',  'Symbol',                c_sym);
    init_std_font(14, 'zapfdingbats', 'N',  'ZapfDingbats',          c_zd);

    g_std_init := TRUE;
  END load_standard_fonts;

-- ---------------------------------------------------------------------------
-- PRIVATE: next available custom font index (>= 15)
-- ---------------------------------------------------------------------------
  FUNCTION next_font_idx RETURN PLS_INTEGER IS
    l_idx PLS_INTEGER;
  BEGIN
    IF g_fonts.COUNT = 0 THEN RETURN 15; END IF;
    l_idx := g_fonts.LAST + 1;
    IF l_idx < 15 THEN l_idx := 15; END IF;
    RETURN l_idx;
  END next_font_idx;

-- ---------------------------------------------------------------------------
-- PRIVATE: TTF table parser
-- ---------------------------------------------------------------------------
  PROCEDURE parse_ttf_tables(p_font IN BLOB, p_offset IN PLS_INTEGER,
                             p_idx  IN PLS_INTEGER) IS
    l_n_tables   PLS_INTEGER;
    l_tag        VARCHAR2(4);
    l_tbl_offset NUMBER;
    l_tbl_len    NUMBER;
    l_raw        RAW(32767);
    l_pos        NUMBER;
    l_loca_fmt   PLS_INTEGER;
    l_n_glyphs   PLS_INTEGER;
    l_n_hmetrics PLS_INTEGER;
    l_n_chars    PLS_INTEGER;
    l_seg        PLS_INTEGER;
    l_seg_count  PLS_INTEGER;
    l_end_code   DBMS_SQL.NUMBER_TABLE;
    l_start_code DBMS_SQL.NUMBER_TABLE;
    l_id_delta   DBMS_SQL.NUMBER_TABLE;
    l_id_rofs    DBMS_SQL.NUMBER_TABLE;
  BEGIN
    l_n_tables := blob2num(p_font, 2, p_offset + 4);

    FOR i IN 1 .. l_n_tables LOOP
      l_pos := p_offset + 12 + (i - 1) * 16;
      l_tag := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(p_font, 4, l_pos));
      l_tbl_offset := blob2num(p_font, 4, l_pos + 8) + 1;
      l_tbl_len    := blob2num(p_font, 4, l_pos + 12);

      CASE l_tag
        WHEN 'head' THEN
          g_fonts(p_idx).unit_norm        := 1000 / blob2num(p_font, 2, l_tbl_offset + 18);
          g_fonts(p_idx).indexToLocFormat := blob2num(p_font, 2, l_tbl_offset + 50);
          g_fonts(p_idx).bb_xmin          := to_short(DBMS_LOB.SUBSTR(p_font, 2, l_tbl_offset + 36));
          g_fonts(p_idx).bb_ymin          := to_short(DBMS_LOB.SUBSTR(p_font, 2, l_tbl_offset + 38));
          g_fonts(p_idx).bb_xmax          := to_short(DBMS_LOB.SUBSTR(p_font, 2, l_tbl_offset + 40));
          g_fonts(p_idx).bb_ymax          := to_short(DBMS_LOB.SUBSTR(p_font, 2, l_tbl_offset + 42));
        WHEN 'hhea' THEN
          g_fonts(p_idx).ascent           := to_short(DBMS_LOB.SUBSTR(p_font, 2, l_tbl_offset + 4));
          g_fonts(p_idx).descent          := to_short(DBMS_LOB.SUBSTR(p_font, 2, l_tbl_offset + 6));
          l_n_hmetrics := blob2num(p_font, 2, l_tbl_offset + 34);
        WHEN 'maxp' THEN
          l_n_glyphs := blob2num(p_font, 2, l_tbl_offset + 4);
          g_fonts(p_idx).numGlyphs := l_n_glyphs;
        WHEN 'OS/2' THEN
          g_fonts(p_idx).capheight := to_short(DBMS_LOB.SUBSTR(p_font, 2, l_tbl_offset + 88));
          g_fonts(p_idx).stemv     := TRUNC(10 + 220 * POWER((blob2num(p_font, 2, l_tbl_offset + 4) / 65536), 2));
          g_fonts(p_idx).flags     := CASE WHEN BITAND(blob2num(p_font, 2, l_tbl_offset + 62), 1) = 1 THEN 4 ELSE 32 END;
        WHEN 'post' THEN
          g_fonts(p_idx).italic_angle := blob2num(p_font, 2, l_tbl_offset + 4) +
                                         blob2num(p_font, 2, l_tbl_offset + 6) / 65536;
          g_fonts(p_idx).subtype := 'TrueType';
        WHEN 'loca' THEN
          l_loca_fmt := NVL(g_fonts(p_idx).indexToLocFormat, 0);
          IF l_loca_fmt = 0 THEN
            FOR g IN 0 .. l_n_glyphs LOOP
              g_fonts(p_idx).loca(g) := blob2num(p_font, 2, l_tbl_offset + g * 2);
            END LOOP;
          ELSE
            FOR g IN 0 .. l_n_glyphs LOOP
              g_fonts(p_idx).loca(g) := blob2num(p_font, 4, l_tbl_offset + g * 4);
            END LOOP;
          END IF;
        WHEN 'hmtx' THEN
          FOR g IN 0 .. l_n_hmetrics - 1 LOOP
            g_fonts(p_idx).hmetrics(g) := blob2num(p_font, 2, l_tbl_offset + g * 4);
          END LOOP;
        WHEN 'cmap' THEN
          l_n_chars := blob2num(p_font, 2, l_tbl_offset + 2);
          FOR c IN 1 .. l_n_chars LOOP
            l_pos := l_tbl_offset + 4 + (c - 1) * 8;
            IF blob2num(p_font, 2, l_pos) IN (0, 3) THEN
              l_pos := l_tbl_offset + blob2num(p_font, 4, l_pos + 4);
              IF blob2num(p_font, 2, l_pos) = 4 THEN  -- Format 4
                l_seg_count := blob2num(p_font, 2, l_pos + 6) / 2;
                FOR s IN 1 .. l_seg_count LOOP
                  l_end_code(s)   := blob2num(p_font, 2, l_pos + 14 + (s-1)*2);
                  l_start_code(s) := blob2num(p_font, 2, l_pos + 16 + l_seg_count*2 + (s-1)*2);
                  l_id_delta(s)   := to_short(DBMS_LOB.SUBSTR(p_font, 2, l_pos + 16 + l_seg_count*4 + (s-1)*2));
                  l_id_rofs(s)    := blob2num(p_font, 2, l_pos + 16 + l_seg_count*6 + (s-1)*2);
                END LOOP;
                FOR s IN 1 .. l_seg_count LOOP
                  IF l_id_rofs(s) = 0 THEN
                    FOR code IN l_start_code(s) .. l_end_code(s) LOOP
                      IF code != 65535 THEN
                        g_fonts(p_idx).code2glyph(code) := MOD(code + l_id_delta(s), 65536);
                        g_fonts(p_idx).char_width_tab(code) :=
                          TRUNC(g_fonts(p_idx).hmetrics(
                            LEAST(g_fonts(p_idx).code2glyph(code), l_n_hmetrics - 1))
                          * g_fonts(p_idx).unit_norm);
                      END IF;
                    END LOOP;
                  END IF;
                END LOOP;
                EXIT;
              END IF;
            END IF;
          END LOOP;
        WHEN 'name' THEN
          DECLARE
            l_cnt     PLS_INTEGER := blob2num(p_font, 2, l_tbl_offset + 2);
            l_str_off PLS_INTEGER := l_tbl_offset + blob2num(p_font, 2, l_tbl_offset + 4);
            l_nid     PLS_INTEGER;
            l_nlen    PLS_INTEGER;
            l_nofs    PLS_INTEGER;
            l_plat    PLS_INTEGER;
          BEGIN
            FOR n IN 0 .. l_cnt - 1 LOOP
              l_pos  := l_tbl_offset + 6 + n * 12;
              l_plat := blob2num(p_font, 2, l_pos);
              l_nid  := blob2num(p_font, 2, l_pos + 6);
              l_nlen := blob2num(p_font, 2, l_pos + 8);
              l_nofs := blob2num(p_font, 2, l_pos + 10);
              IF l_nid = 6 AND l_plat = 3 THEN
                g_fonts(p_idx).name :=
                  UTL_I18N.RAW_TO_CHAR(
                    DBMS_LOB.SUBSTR(p_font, l_nlen, l_str_off + l_nofs + 1),
                    'AL16UTF16');
                EXIT;
              ELSIF l_nid = 6 AND l_plat = 1 AND g_fonts(p_idx).name IS NULL THEN
                g_fonts(p_idx).name :=
                  UTL_RAW.CAST_TO_VARCHAR2(
                    DBMS_LOB.SUBSTR(p_font, l_nlen, l_str_off + l_nofs + 1));
              END IF;
            END LOOP;
          END;
        ELSE NULL;
      END CASE;
    END LOOP;
  END parse_ttf_tables;

-- ---------------------------------------------------------------------------
-- PRIVATE: TTF glyph subsetting
-- Fixes DBMS_LOB.APPEND(BLOB, RAW) -> DBMS_LOB.WRITEAPPEND throughout.
-- ---------------------------------------------------------------------------
  FUNCTION subset_font(p_idx IN PLS_INTEGER) RETURN BLOB IS
    t_used_glyphs   t_pls_tab;
    t_tables        BLOB;
    t_tmp           BLOB;
    t_header        BLOB;
    t_table_records RAW(32767);
    t_raw           RAW(32767);
    t_len           PLS_INTEGER;
    t_offset        NUMBER;
    t_factor        PLS_INTEGER;
    t_fmt           VARCHAR2(10);
    t_unicode       PLS_INTEGER;
    t_code          PLS_INTEGER;
    l_utf16_cs      VARCHAR2(1000);
    l_n_tables      PLS_INTEGER;
    l_tag           VARCHAR2(4);
    l_raw_len       PLS_INTEGER;
  BEGIN
    -- Build used glyph set
    IF g_fonts(p_idx).cid THEN
      t_used_glyphs := g_fonts(p_idx).used_chars;
      t_used_glyphs(0) := 0;
    ELSE
      l_utf16_cs := SUBSTR(g_fonts(p_idx).charset, 1,
                           INSTR(g_fonts(p_idx).charset, '.')) || 'AL16UTF16';
      t_used_glyphs(0) := 0;
      t_code := g_fonts(p_idx).used_chars.FIRST;
      WHILE t_code IS NOT NULL LOOP
        t_unicode := TO_NUMBER(RAWTOHEX(
          UTL_RAW.CONVERT(HEXTORAW(TO_CHAR(t_code, 'FM0X')),
                          l_utf16_cs, g_fonts(p_idx).charset)), 'XXXXXXXX');
        IF g_fonts(p_idx).flags = 4 THEN
          t_used_glyphs(g_fonts(p_idx).code2glyph(
            g_fonts(p_idx).code2glyph.FIRST + t_unicode - 32)) := 0;
        ELSIF g_fonts(p_idx).code2glyph.EXISTS(t_unicode) THEN
          t_used_glyphs(g_fonts(p_idx).code2glyph(t_unicode)) := 0;
        END IF;
        t_code := g_fonts(p_idx).used_chars.NEXT(t_code);
      END LOOP;
    END IF;

    DBMS_LOB.CREATETEMPORARY(t_tables, TRUE, DBMS_LOB.SESSION);
    l_n_tables      := blob2num(g_fonts(p_idx).fontfile2, 2, g_fonts(p_idx).ttf_offset + 4);
    t_header        := UTL_RAW.CONCAT(HEXTORAW('00010000'),
                         DBMS_LOB.SUBSTR(g_fonts(p_idx).fontfile2, 8, g_fonts(p_idx).ttf_offset + 4));
    t_offset        := 12 + l_n_tables * 16;
    t_table_records := DBMS_LOB.SUBSTR(g_fonts(p_idx).fontfile2,
                                       l_n_tables * 16,
                                       g_fonts(p_idx).ttf_offset + 12);

    FOR i IN 1 .. l_n_tables LOOP
      l_tag := UTL_RAW.CAST_TO_VARCHAR2(UTL_RAW.SUBSTR(t_table_records, i * 16 - 15, 4));
      CASE l_tag
        WHEN 'post' THEN
          -- Fix: DBMS_LOB.APPEND(BLOB, RAW) -> DBMS_LOB.WRITEAPPEND
          DECLARE
            l_r RAW(32767);
          BEGIN
            l_r := UTL_RAW.CONCAT(UTL_RAW.SUBSTR(t_table_records, i*16-15, 4),
                                  HEXTORAW('00000000'),
                                  num2raw(t_offset + DBMS_LOB.GETLENGTH(t_tables)),
                                  num2raw(32));
            l_raw_len := UTL_RAW.LENGTH(l_r);
            IF l_raw_len > 0 THEN
              DBMS_LOB.WRITEAPPEND(t_header, l_raw_len, l_r);
            END IF;
            l_r := UTL_RAW.CONCAT(HEXTORAW('00030000'),
                                  DBMS_LOB.SUBSTR(g_fonts(p_idx).fontfile2, 28,
                                    raw2num(t_table_records, i*16-7, 4) + 5));
            l_raw_len := UTL_RAW.LENGTH(l_r);
            IF l_raw_len > 0 THEN
              DBMS_LOB.WRITEAPPEND(t_tables, l_raw_len, l_r);
            END IF;
          END;

        WHEN 'loca' THEN
          t_fmt := CASE g_fonts(p_idx).indexToLocFormat WHEN 0 THEN 'FM0XXX' ELSE 'FM0XXXXXXX' END;
          t_raw := NULL;
          DBMS_LOB.CREATETEMPORARY(t_tmp, TRUE, DBMS_LOB.SESSION);
          t_len := 0;
          FOR g IN 0 .. g_fonts(p_idx).numGlyphs - 1 LOOP
            t_raw := UTL_RAW.CONCAT(t_raw, HEXTORAW(TO_CHAR(t_len, t_fmt)));
            IF UTL_RAW.LENGTH(t_raw) > 32770 THEN
              l_raw_len := UTL_RAW.LENGTH(t_raw);
              DBMS_LOB.WRITEAPPEND(t_tmp, l_raw_len, t_raw);
              t_raw := NULL;
            END IF;
            IF t_used_glyphs.EXISTS(g) THEN
              t_len := t_len + g_fonts(p_idx).loca(g+1) - g_fonts(p_idx).loca(g);
            END IF;
          END LOOP;
          t_raw := UTL_RAW.CONCAT(t_raw, HEXTORAW(TO_CHAR(t_len, t_fmt)));
          l_raw_len := UTL_RAW.LENGTH(t_raw);
          IF l_raw_len > 0 THEN
            DBMS_LOB.WRITEAPPEND(t_tmp, l_raw_len, t_raw);
          END IF;
          DECLARE
            l_r RAW(32767);
          BEGIN
            l_r := UTL_RAW.CONCAT(UTL_RAW.SUBSTR(t_table_records, i*16-15, 4),
                                  HEXTORAW('00000000'),
                                  num2raw(t_offset + DBMS_LOB.GETLENGTH(t_tables)),
                                  num2raw(DBMS_LOB.GETLENGTH(t_tmp)));
            l_raw_len := UTL_RAW.LENGTH(l_r);
            IF l_raw_len > 0 THEN
              DBMS_LOB.WRITEAPPEND(t_header, l_raw_len, l_r);
            END IF;
          END;
          DECLARE
            l_tmp_len NUMBER := DBMS_LOB.GETLENGTH(t_tmp);
          BEGIN
            IF l_tmp_len > 0 THEN
              DBMS_LOB.APPEND(t_tables, t_tmp);
            END IF;
          END;
          DBMS_LOB.FREETEMPORARY(t_tmp);

        WHEN 'glyf' THEN
          t_factor := CASE g_fonts(p_idx).indexToLocFormat WHEN 0 THEN 2 ELSE 1 END;
          t_raw := NULL;
          DBMS_LOB.CREATETEMPORARY(t_tmp, TRUE, DBMS_LOB.SESSION);
          FOR g IN 0 .. g_fonts(p_idx).numGlyphs - 1 LOOP
            IF t_used_glyphs.EXISTS(g) AND
               g_fonts(p_idx).loca(g+1) > g_fonts(p_idx).loca(g) THEN
              t_raw := UTL_RAW.CONCAT(t_raw,
                DBMS_LOB.SUBSTR(g_fonts(p_idx).fontfile2,
                  (g_fonts(p_idx).loca(g+1) - g_fonts(p_idx).loca(g)) * t_factor,
                  g_fonts(p_idx).loca(g) * t_factor +
                    raw2num(t_table_records, i*16-7, 4) + 1));
              IF UTL_RAW.LENGTH(t_raw) > 32778 THEN
                l_raw_len := UTL_RAW.LENGTH(t_raw);
                DBMS_LOB.WRITEAPPEND(t_tmp, l_raw_len, t_raw);
                t_raw := NULL;
              END IF;
            END IF;
          END LOOP;
          IF NVL(UTL_RAW.LENGTH(t_raw), 0) > 0 THEN
            DBMS_LOB.WRITEAPPEND(t_tmp, UTL_RAW.LENGTH(t_raw), t_raw);
          END IF;
          DECLARE
            l_r       RAW(32767);
            l_tmp_len NUMBER := DBMS_LOB.GETLENGTH(t_tmp);
          BEGIN
            l_r := UTL_RAW.CONCAT(UTL_RAW.SUBSTR(t_table_records, i*16-15, 4),
                                  HEXTORAW('00000000'),
                                  num2raw(t_offset + DBMS_LOB.GETLENGTH(t_tables)),
                                  num2raw(l_tmp_len));
            l_raw_len := UTL_RAW.LENGTH(l_r);
            IF l_raw_len > 0 THEN
              DBMS_LOB.WRITEAPPEND(t_header, l_raw_len, l_r);
            END IF;
            IF l_tmp_len > 0 THEN
              DBMS_LOB.APPEND(t_tables, t_tmp);
            END IF;
          END;
          DBMS_LOB.FREETEMPORARY(t_tmp);

        ELSE
          DECLARE
            l_r        RAW(32767);
            l_copy_len NUMBER := raw2num(t_table_records, i*16-3, 4);
          BEGIN
            l_r := UTL_RAW.CONCAT(UTL_RAW.SUBSTR(t_table_records, i*16-15, 4),
                                  UTL_RAW.SUBSTR(t_table_records, i*16-11, 4),
                                  num2raw(t_offset + DBMS_LOB.GETLENGTH(t_tables)),
                                  UTL_RAW.SUBSTR(t_table_records, i*16-3, 4));
            l_raw_len := UTL_RAW.LENGTH(l_r);
            IF l_raw_len > 0 THEN
              DBMS_LOB.WRITEAPPEND(t_header, l_raw_len, l_r);
            END IF;
            IF l_copy_len > 0 THEN
              DBMS_LOB.COPY(t_tables, g_fonts(p_idx).fontfile2,
                l_copy_len,
                DBMS_LOB.GETLENGTH(t_tables) + 1,
                raw2num(t_table_records, i*16-7, 4) + 1);
            END IF;
          END;
      END CASE;
    END LOOP;

    DECLARE
      l_tbl_len NUMBER := DBMS_LOB.GETLENGTH(t_tables);
    BEGIN
      IF l_tbl_len > 0 THEN
        DBMS_LOB.APPEND(t_header, t_tables);
      END IF;
    END;
    DBMS_LOB.FREETEMPORARY(t_tables);
    RETURN t_header;
  EXCEPTION
    WHEN OTHERS THEN
      IF t_tables IS NOT NULL AND DBMS_LOB.ISTEMPORARY(t_tables) = 1 THEN
        DBMS_LOB.FREETEMPORARY(t_tables);
      END IF;
      RAISE;
  END subset_font;

-- ---------------------------------------------------------------------------
-- PRIVATE: core TTF load from BLOB
--   p_doc     : document handle (NULL means preload / session-scoped)
--   p_preload : TRUE if font should survive close_doc
-- ---------------------------------------------------------------------------
  FUNCTION load_ttf_from_blob(p_doc      IN rad_pdf_types.t_doc_handle,
                              p_font     IN BLOB,
                              p_family   IN VARCHAR2,
                              p_style    IN VARCHAR2,
                              p_encoding IN VARCHAR2,
                              p_embed    IN BOOLEAN,
                              p_compress IN BOOLEAN,
                              p_offset   IN NUMBER,
                              p_preload  IN BOOLEAN DEFAULT FALSE)
    RETURN PLS_INTEGER IS
    l_idx   PLS_INTEGER := next_font_idx;
    l_magic RAW(4);
    l_len   NUMBER;
  BEGIN
    -- Validate TTF magic bytes
    l_magic := DBMS_LOB.SUBSTR(p_font, 4, NVL(p_offset, 1));
    IF l_magic NOT IN (HEXTORAW('00010000'), UTL_RAW.CAST_TO_RAW('true'),
                       UTL_RAW.CAST_TO_RAW('OTTO')) THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_font,
        'rad_pdf_fonts.load_ttf: not a valid TTF/OTF file (bad magic bytes)', TRUE);
    END IF;

    g_fonts(l_idx).standard      := FALSE;
    g_fonts(l_idx).preloaded     := p_preload;
    g_fonts(l_idx).family        := LOWER(NVL(p_family, 'font' || l_idx));
    g_fonts(l_idx).style         := UPPER(NVL(p_style, 'N'));
    g_fonts(l_idx).encoding      := p_encoding;
    g_fonts(l_idx).cid           := (UPPER(p_encoding) = 'CID');
    g_fonts(l_idx).embed         := p_embed;
    g_fonts(l_idx).compress_font := p_compress;
    g_fonts(l_idx).ttf_offset    := NVL(p_offset, 1);
    g_fonts(l_idx).charset       :=
      SUBSTR(SYS_CONTEXT('USERENV','LANGUAGE'), 1,
             INSTR(SYS_CONTEXT('USERENV','LANGUAGE'), '.')) || p_encoding;

    DBMS_LOB.CREATETEMPORARY(g_fonts(l_idx).fontfile2, TRUE, DBMS_LOB.SESSION);
    l_len := DBMS_LOB.GETLENGTH(p_font);
    IF l_len > 0 THEN
      DBMS_LOB.COPY(g_fonts(l_idx).fontfile2, p_font, l_len);
    END IF;

    parse_ttf_tables(g_fonts(l_idx).fontfile2, NVL(p_offset, 1) - 1, l_idx);

    IF g_fonts(l_idx).name IS NULL THEN
      g_fonts(l_idx).name := 'Font' || l_idx;
    END IF;
    g_fonts(l_idx).fontname := g_fonts(l_idx).name;
    register_font_name(l_idx);

    -- Track in per-document state if this is a doc-scoped (non-preload) font
    IF NOT p_preload AND p_doc IS NOT NULL THEN
      IF NOT g_doc_state.EXISTS(p_doc) THEN
        g_doc_state(p_doc).doc_fonts.DELETE;
        g_doc_state(p_doc).used_fonts.DELETE;
      END IF;
      g_doc_state(p_doc).doc_fonts(l_idx) := 0;
    END IF;

    RETURN l_idx;
  END load_ttf_from_blob;

-- ---------------------------------------------------------------------------
-- Public: load_ttf variants — per-document
-- ---------------------------------------------------------------------------
  FUNCTION load_ttf(p_doc      IN rad_pdf_types.t_doc_handle,
                    p_font     IN BLOB,
                    p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                    p_embed    IN BOOLEAN  DEFAULT FALSE,
                    p_compress IN BOOLEAN  DEFAULT TRUE,
                    p_offset   IN NUMBER   DEFAULT 1) RETURN PLS_INTEGER IS
  BEGIN
    RETURN load_ttf_from_blob(p_doc, p_font, NULL, NULL,
                              p_encoding, p_embed, p_compress, p_offset, FALSE);
  END load_ttf;

-- ---------------------------------------------------------------------------
  FUNCTION load_ttf(p_doc      IN rad_pdf_types.t_doc_handle,
                    p_dir      IN VARCHAR2,
                    p_filename IN VARCHAR2,
                    p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                    p_embed    IN BOOLEAN  DEFAULT FALSE,
                    p_compress IN BOOLEAN  DEFAULT TRUE) RETURN PLS_INTEGER IS
    l_blob BLOB;
    l_fh   UTL_FILE.FILE_TYPE;
    l_buf  RAW(32767);
    l_idx  PLS_INTEGER;
    l_len  PLS_INTEGER;
  BEGIN
    assert_dir_and_file(p_dir, p_filename);
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE, DBMS_LOB.SESSION);
    l_fh := UTL_FILE.FOPEN(p_dir, p_filename, 'rb', 32767);
    BEGIN
      LOOP
        UTL_FILE.GET_RAW(l_fh, l_buf, 32767);
        l_len := UTL_RAW.LENGTH(l_buf);
        IF l_len > 0 THEN
          DBMS_LOB.WRITEAPPEND(l_blob, l_len, l_buf);
        END IF;
      END LOOP;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN NULL;
      WHEN OTHERS THEN
        UTL_FILE.FCLOSE(l_fh);
        DBMS_LOB.FREETEMPORARY(l_blob);
        RAISE;
    END;
    UTL_FILE.FCLOSE(l_fh);
    l_idx := load_ttf_from_blob(p_doc, l_blob, NULL, NULL,
                                p_encoding, p_embed, p_compress, 1, FALSE);
    DBMS_LOB.FREETEMPORARY(l_blob);
    RETURN l_idx;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_blob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_blob) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_blob);
      END IF;
      RAISE;
  END load_ttf;

-- ---------------------------------------------------------------------------
  FUNCTION load_ttf(p_doc      IN rad_pdf_types.t_doc_handle,
                    p_url      IN VARCHAR2,
                    p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                    p_embed    IN BOOLEAN  DEFAULT FALSE,
                    p_compress IN BOOLEAN  DEFAULT TRUE) RETURN PLS_INTEGER IS
    c_max_bytes  CONSTANT NUMBER := 10 * 1024 * 1024;  -- 10 MB
    c_timeout    CONSTANT NUMBER := 30;
    c_max_redir  CONSTANT NUMBER := 3;
    l_req        UTL_HTTP.REQ;
    l_resp       UTL_HTTP.RESP;
    l_url        VARCHAR2(4000) := p_url;
    l_blob       BLOB;
    l_buf        RAW(32767);
    l_ct         VARCHAR2(200);
    l_redir_cnt  PLS_INTEGER    := 0;
    l_idx        PLS_INTEGER;
    l_len        PLS_INTEGER;
  BEGIN
    assert_https_url(l_url);
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE, DBMS_LOB.SESSION);

    <<redirect_loop>>
    LOOP
      UTL_HTTP.SET_TRANSFER_TIMEOUT(c_timeout);
      l_req  := UTL_HTTP.BEGIN_REQUEST(l_url, 'GET', 'HTTP/1.1');
      l_resp := UTL_HTTP.GET_RESPONSE(l_req);

      IF l_resp.status_code IN (301, 302, 303, 307, 308) THEN
        UTL_HTTP.GET_HEADER_BY_NAME(l_resp, 'Location', l_url, 1);
        UTL_HTTP.END_RESPONSE(l_resp);
        assert_https_url(l_url);
        l_redir_cnt := l_redir_cnt + 1;
        IF l_redir_cnt > c_max_redir THEN
          RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_io,
            'rad_pdf_fonts.load_ttf: too many redirects for URL ' || p_url, TRUE);
        END IF;
        CONTINUE redirect_loop;
      END IF;

      IF l_resp.status_code != 200 THEN
        UTL_HTTP.END_RESPONSE(l_resp);
        RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_io,
          'rad_pdf_fonts.load_ttf: HTTP ' || l_resp.status_code || ' for URL ' || p_url, TRUE);
      END IF;

      BEGIN
        UTL_HTTP.GET_HEADER_BY_NAME(l_resp, 'Content-Type', l_ct, 1);
      EXCEPTION WHEN OTHERS THEN l_ct := ''; END;
      IF l_ct NOT LIKE '%font%' AND l_ct NOT LIKE '%octet-stream%' AND l_ct != '' THEN
        UTL_HTTP.END_RESPONSE(l_resp);
        RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_io,
          'rad_pdf_fonts.load_ttf: unexpected Content-Type "' || l_ct || '"', TRUE);
      END IF;

      BEGIN
        LOOP
          UTL_HTTP.READ_RAW(l_resp, l_buf, 32767);
          l_len := UTL_RAW.LENGTH(l_buf);
          IF l_len > 0 THEN
            DBMS_LOB.WRITEAPPEND(l_blob, l_len, l_buf);
          END IF;
          IF DBMS_LOB.GETLENGTH(l_blob) > c_max_bytes THEN
            UTL_HTTP.END_RESPONSE(l_resp);
            RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_io,
              'rad_pdf_fonts.load_ttf: font exceeds maximum size of 10 MB', TRUE);
          END IF;
        END LOOP;
      EXCEPTION
        WHEN UTL_HTTP.END_OF_BODY THEN UTL_HTTP.END_RESPONSE(l_resp);
        WHEN OTHERS THEN
          UTL_HTTP.END_RESPONSE(l_resp);
          RAISE;
      END;
      EXIT redirect_loop;
    END LOOP redirect_loop;

    l_idx := load_ttf_from_blob(p_doc, l_blob, NULL, NULL,
                                p_encoding, p_embed, p_compress, 1, FALSE);
    DBMS_LOB.FREETEMPORARY(l_blob);
    RETURN l_idx;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_blob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_blob) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_blob);
      END IF;
      RAISE;
  END load_ttf;

-- ---------------------------------------------------------------------------
-- Public: load_ttc variants — per-document
-- ---------------------------------------------------------------------------
  PROCEDURE load_ttc(p_doc      IN rad_pdf_types.t_doc_handle,
                     p_ttc      IN BLOB,
                     p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                     p_embed    IN BOOLEAN  DEFAULT FALSE,
                     p_compress IN BOOLEAN  DEFAULT TRUE) IS
    l_n_fonts PLS_INTEGER;
    l_offset  NUMBER;
    l_dummy   PLS_INTEGER;
  BEGIN
    IF UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(p_ttc, 4, 1)) != 'ttcf' THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_font,
        'rad_pdf_fonts.load_ttc: not a valid TTC file', TRUE);
    END IF;
    l_n_fonts := blob2num(p_ttc, 4, 9);
    FOR i IN 0 .. l_n_fonts - 1 LOOP
      l_offset := blob2num(p_ttc, 4, 13 + i * 4);
      l_dummy  := load_ttf_from_blob(p_doc, p_ttc, NULL, NULL,
                                     p_encoding, p_embed, p_compress, l_offset + 1, FALSE);
    END LOOP;
  END load_ttc;

  PROCEDURE load_ttc(p_doc      IN rad_pdf_types.t_doc_handle,
                     p_dir      IN VARCHAR2,
                     p_filename IN VARCHAR2,
                     p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                     p_embed    IN BOOLEAN  DEFAULT FALSE,
                     p_compress IN BOOLEAN  DEFAULT TRUE) IS
    l_blob BLOB;
    l_fh   UTL_FILE.FILE_TYPE;
    l_buf  RAW(32767);
    l_len  PLS_INTEGER;
  BEGIN
    assert_dir_and_file(p_dir, p_filename);
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE, DBMS_LOB.SESSION);
    l_fh := UTL_FILE.FOPEN(p_dir, p_filename, 'rb', 32767);
    BEGIN
      LOOP
        UTL_FILE.GET_RAW(l_fh, l_buf, 32767);
        l_len := UTL_RAW.LENGTH(l_buf);
        IF l_len > 0 THEN
          DBMS_LOB.WRITEAPPEND(l_blob, l_len, l_buf);
        END IF;
      END LOOP;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN NULL;
      WHEN OTHERS THEN
        UTL_FILE.FCLOSE(l_fh);
        DBMS_LOB.FREETEMPORARY(l_blob);
        RAISE;
    END;
    UTL_FILE.FCLOSE(l_fh);
    load_ttc(p_doc, l_blob, p_encoding, p_embed, p_compress);
    DBMS_LOB.FREETEMPORARY(l_blob);
  EXCEPTION
    WHEN OTHERS THEN
      IF l_blob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_blob) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_blob);
      END IF;
      RAISE;
  END load_ttc;

-- ---------------------------------------------------------------------------
-- Public: preload_ttf variants — session-scoped (no p_doc)
-- ---------------------------------------------------------------------------
  FUNCTION preload_ttf(p_font     IN BLOB,
                       p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                       p_embed    IN BOOLEAN  DEFAULT FALSE,
                       p_compress IN BOOLEAN  DEFAULT TRUE,
                       p_offset   IN NUMBER   DEFAULT 1) RETURN PLS_INTEGER IS
  BEGIN
    RETURN load_ttf_from_blob(NULL, p_font, NULL, NULL,
                              p_encoding, p_embed, p_compress, p_offset, TRUE);
  END preload_ttf;

  FUNCTION preload_ttf(p_dir      IN VARCHAR2,
                       p_filename IN VARCHAR2,
                       p_encoding IN VARCHAR2 DEFAULT 'WE8MSWIN1252',
                       p_embed    IN BOOLEAN  DEFAULT FALSE,
                       p_compress IN BOOLEAN  DEFAULT TRUE) RETURN PLS_INTEGER IS
    l_blob BLOB;
    l_fh   UTL_FILE.FILE_TYPE;
    l_buf  RAW(32767);
    l_idx  PLS_INTEGER;
    l_len  PLS_INTEGER;
  BEGIN
    assert_dir_and_file(p_dir, p_filename);
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE, DBMS_LOB.SESSION);
    l_fh := UTL_FILE.FOPEN(p_dir, p_filename, 'rb', 32767);
    BEGIN
      LOOP
        UTL_FILE.GET_RAW(l_fh, l_buf, 32767);
        l_len := UTL_RAW.LENGTH(l_buf);
        IF l_len > 0 THEN
          DBMS_LOB.WRITEAPPEND(l_blob, l_len, l_buf);
        END IF;
      END LOOP;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN NULL;
      WHEN OTHERS THEN
        UTL_FILE.FCLOSE(l_fh);
        DBMS_LOB.FREETEMPORARY(l_blob);
        RAISE;
    END;
    UTL_FILE.FCLOSE(l_fh);
    l_idx := load_ttf_from_blob(NULL, l_blob, NULL, NULL,
                                p_encoding, p_embed, p_compress, 1, TRUE);
    DBMS_LOB.FREETEMPORARY(l_blob);
    RETURN l_idx;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_blob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_blob) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_blob);
      END IF;
      RAISE;
  END preload_ttf;

-- ---------------------------------------------------------------------------
-- Public: find_font — O(1) lookup via hash table
--   p_doc is reserved for future per-document font scoping; currently unused.
-- ---------------------------------------------------------------------------
  FUNCTION find_font(p_doc    IN rad_pdf_types.t_doc_handle,
                     p_family IN VARCHAR2,
                     p_style  IN rad_pdf_types.t_font_style DEFAULT 'N')
    RETURN PLS_INTEGER IS
    l_key VARCHAR2(210);
  BEGIN
    l_key := LOWER(p_family) || '|' || LOWER(NVL(p_style,'N'));
    IF g_name_idx.EXISTS(l_key) THEN RETURN TO_NUMBER(g_name_idx(l_key)); END IF;
    l_key := LOWER(p_family);
    IF g_name_idx.EXISTS(l_key) THEN RETURN TO_NUMBER(g_name_idx(l_key)); END IF;
    RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_font,
      'rad_pdf_fonts.find_font: font "' || p_family || '" style "' || NVL(p_style,'N') || '" not found', TRUE);
  END find_font;

-- ---------------------------------------------------------------------------
-- Public: text_width
-- ---------------------------------------------------------------------------
  FUNCTION text_width(p_text     IN VARCHAR2,
                      p_font_idx IN PLS_INTEGER,
                      p_size_pt  IN NUMBER) RETURN NUMBER IS
    l_w   NUMBER := 0;
    l_len PLS_INTEGER := NVL(LENGTH(p_text), 0);
    l_c   PLS_INTEGER;
  BEGIN
    IF l_len = 0 OR NOT g_fonts.EXISTS(p_font_idx) THEN RETURN 0; END IF;
    FOR i IN 1 .. l_len LOOP
      l_c := ASCII(SUBSTR(p_text, i, 1));
      IF g_fonts(p_font_idx).char_width_tab.EXISTS(l_c) THEN
        l_w := l_w + g_fonts(p_font_idx).char_width_tab(l_c);
      END IF;
    END LOOP;
    RETURN l_w * p_size_pt / 1000;
  END text_width;

-- ---------------------------------------------------------------------------
-- Public: mark_char_used
-- ---------------------------------------------------------------------------
  PROCEDURE mark_char_used(p_font_idx IN PLS_INTEGER, p_char_code IN PLS_INTEGER) IS
  BEGIN
    IF g_fonts.EXISTS(p_font_idx) AND NOT g_fonts(p_font_idx).standard THEN
      g_fonts(p_font_idx).used_chars(p_char_code) := 0;
    END IF;
  END mark_char_used;

-- ---------------------------------------------------------------------------
-- Public: mark_font_used (called by rad_pdf_canvas when Tf is emitted)
-- ---------------------------------------------------------------------------
  PROCEDURE mark_font_used(p_doc IN rad_pdf_types.t_doc_handle, p_font_idx IN PLS_INTEGER) IS
  BEGIN
    IF p_doc IS NULL THEN RETURN; END IF;
    g_doc_state(p_doc).used_fonts(p_font_idx) := 0;
  END mark_font_used;

-- ---------------------------------------------------------------------------
-- Public: text_to_pdf_string
-- ---------------------------------------------------------------------------
  FUNCTION text_to_pdf_string(p_text     IN VARCHAR2,
                              p_font_idx IN PLS_INTEGER) RETURN VARCHAR2 IS
    l_rv  VARCHAR2(32767);
    l_len PLS_INTEGER := NVL(LENGTH(p_text), 0);
    l_c   PLS_INTEGER;
  BEGIN
    IF l_len = 0 THEN RETURN '()'; END IF;

    IF g_fonts(p_font_idx).cid THEN
      DECLARE
        l_raw RAW(32767);
      BEGIN
        l_raw := UTL_I18N.STRING_TO_RAW(p_text, 'AL16UTF16');
        FOR i IN 0 .. UTL_RAW.LENGTH(l_raw) / 2 - 1 LOOP
          l_c := TO_NUMBER(RAWTOHEX(UTL_RAW.SUBSTR(l_raw, i*2+1, 2)), 'XXXX');
          IF g_fonts(p_font_idx).code2glyph.EXISTS(l_c) THEN
            g_fonts(p_font_idx).used_chars(g_fonts(p_font_idx).code2glyph(l_c)) := 0;
          END IF;
        END LOOP;
        RETURN '<' || RAWTOHEX(l_raw) || '>';
      END;
    ELSE
      DECLARE
        l_ch VARCHAR2(4);
      BEGIN
        FOR i IN 1 .. l_len LOOP
          l_ch := SUBSTR(p_text, i, 1);
          l_c  := ASCII(l_ch);
          mark_char_used(p_font_idx, l_c);
          l_rv := l_rv || CASE l_ch
                            WHEN '\' THEN '\\'
                            WHEN '(' THEN '\('
                            WHEN ')' THEN '\)'
                            ELSE l_ch
                          END;
        END LOOP;
        RETURN '(' || l_rv || ')';
      END;
    END IF;
  END text_to_pdf_string;

-- ---------------------------------------------------------------------------
-- Public: write_font_objects
--
-- Uses g_doc_state(p_doc).used_fonts to know which fonts to write.
-- Calls rad_pdf_serial.xxx(p_doc) for all document writes.
-- CID variable-reuse bug fixed: l_fi (font index outer loop),
--   l_gi (glyph index inner loop), l_font_obj (initial Type0 object number).
-- to_char_round replaced with rad_pdf_codec.fmt(x, 2).
-- ---------------------------------------------------------------------------
  FUNCTION write_font_objects(p_doc IN rad_pdf_types.t_doc_handle) RETURN VARCHAR2 IS
    l_resources VARCHAR2(32767) := '';
    l_obj_nr    NUMBER;
    l_dummy     NUMBER;        -- discarded return from begin_obj when nr not needed
    l_font_obj  NUMBER;        -- initial Type0 object number (CID branch)
    l_subset    BLOB;
    l_w         VARCHAR2(32767);
    l_fi        PLS_INTEGER;   -- outer loop: font index from used_fonts
    l_gi        PLS_INTEGER;   -- inner loop: glyph index for CID width array
    l_utf16_cs  VARCHAR2(1000);
    l_t_used    t_pls_tab;
    l_width     NUMBER;
  BEGIN
    IF NOT g_doc_state.EXISTS(p_doc) THEN
      RETURN '';
    END IF;

    l_fi := g_doc_state(p_doc).used_fonts.FIRST;
    WHILE l_fi IS NOT NULL LOOP
      IF g_fonts(l_fi).standard THEN
        -- Type1 standard font — single-call inline dict object
        l_obj_nr := rad_pdf_serial.begin_obj(p_doc,
          '/Type/Font/Subtype/Type1' ||
          '/BaseFont/' || g_fonts(l_fi).name ||
          '/Encoding/WinAnsiEncoding');

      ELSIF g_fonts(l_fi).cid THEN
        -- CID/Type0 font with ToUnicode CMap
        -- Fixed: l_font_obj captures the base object number; l_gi iterates glyphs.
        l_font_obj := rad_pdf_serial.begin_obj(p_doc);
        rad_pdf_serial.doc_write(p_doc,
          '<</Type/Font/Subtype/Type0/Encoding/Identity-H' ||
          '/BaseFont/' || g_fonts(l_fi).name ||
          '/DescendantFonts ' || TO_CHAR(l_font_obj+1) || ' 0 R' ||
          '/ToUnicode '       || TO_CHAR(l_font_obj+8) || ' 0 R>>');
        rad_pdf_serial.end_obj(p_doc);

        -- Descendant fonts array object
        l_dummy := rad_pdf_serial.begin_obj(p_doc);
        rad_pdf_serial.doc_write(p_doc, '[' || TO_CHAR(l_font_obj+2) || ' 0 R]');
        rad_pdf_serial.end_obj(p_doc);

        -- Build glyph width array using l_gi (not l_fi, to avoid variable reuse)
        l_utf16_cs := SUBSTR(g_fonts(l_fi).charset, 1,
                             INSTR(g_fonts(l_fi).charset, '.')) || 'AL16UTF16';
        l_t_used   := g_fonts(l_fi).used_chars;
        l_t_used(0) := 0;
        l_w := '';
        l_gi := l_t_used.FIRST;
        WHILE l_gi IS NOT NULL LOOP
          IF g_fonts(l_fi).hmetrics.EXISTS(l_gi) THEN
            l_width := g_fonts(l_fi).hmetrics(l_gi);
          ELSE
            l_width := g_fonts(l_fi).hmetrics(g_fonts(l_fi).hmetrics.LAST);
          END IF;
          l_width := TRUNC(l_width * g_fonts(l_fi).unit_norm);
          IF l_t_used.PRIOR(l_gi) IS NOT NULL AND
             l_t_used.PRIOR(l_gi) = l_gi - 1 THEN
            l_w := l_w || ' ' || l_width;
          ELSE
            l_w := l_w || '] ' || l_gi || ' [' || l_width;
          END IF;
          l_gi := l_t_used.NEXT(l_gi);
        END LOOP;
        l_w := '[' || LTRIM(l_w, '] ') || ']]';

        -- CIDFont dictionary (object l_font_obj+2)
        l_dummy := rad_pdf_serial.begin_obj(p_doc);
        rad_pdf_serial.doc_write(p_doc,
          '<</Type/Font/Subtype/CIDFontType2/CIDToGIDMap/Identity/DW 1000' ||
          '/BaseFont/' || g_fonts(l_fi).name ||
          '/CIDSystemInfo ' || TO_CHAR(l_font_obj+3) || ' 0 R' ||
          '/W '             || TO_CHAR(l_font_obj+4) || ' 0 R' ||
          '/FontDescriptor ' || TO_CHAR(l_font_obj+5) || ' 0 R>>');
        rad_pdf_serial.end_obj(p_doc);

        -- CIDSystemInfo object (l_font_obj+3)
        l_dummy := rad_pdf_serial.begin_obj(p_doc,
          '/Ordering(Identity) /Registry(Adobe) /Supplement 0');

        -- W (widths) array object (l_font_obj+4)
        l_dummy := rad_pdf_serial.begin_obj(p_doc);
        rad_pdf_serial.doc_write(p_doc, l_w);
        rad_pdf_serial.end_obj(p_doc);

        -- FontDescriptor object (l_font_obj+5)
        l_dummy := rad_pdf_serial.begin_obj(p_doc,
          '/Type/FontDescriptor' ||
          '/FontName/'    || g_fonts(l_fi).name ||
          '/Flags '       || g_fonts(l_fi).flags ||
          '/FontBBox ['   || g_fonts(l_fi).bb_xmin || ' ' || g_fonts(l_fi).bb_ymin ||
          ' '             || g_fonts(l_fi).bb_xmax || ' ' || g_fonts(l_fi).bb_ymax || ']' ||
          '/ItalicAngle ' || rad_pdf_codec.fmt(g_fonts(l_fi).italic_angle, 2) ||
          '/Ascent '      || g_fonts(l_fi).ascent ||
          '/Descent '     || g_fonts(l_fi).descent ||
          '/CapHeight '   || g_fonts(l_fi).capheight ||
          '/StemV '       || g_fonts(l_fi).stemv ||
          '/FontFile2 '   || TO_CHAR(l_font_obj+6) || ' 0 R');

        -- FontFile2 stream object (l_font_obj+6)
        l_subset := subset_font(l_fi);
        DECLARE
          l_extra VARCHAR2(60) := '/Length1 ' || DBMS_LOB.GETLENGTH(l_subset);
        BEGIN
          l_obj_nr := rad_pdf_serial.write_stream_obj(p_doc, l_subset, l_extra,
                                                  g_fonts(l_fi).compress_font);
        END;
        IF l_subset IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_subset) = 1 THEN
          DBMS_LOB.FREETEMPORARY(l_subset);
        END IF;

        -- ToUnicode CMap stub stream (l_font_obj+7 → we skip to l_font_obj+8 offset,
        -- so we need two objects here: l_font_obj+7 is unused padding,
        -- l_font_obj+8 is the actual ToUnicode stream).
        -- Write empty stub at l_font_obj+7 to preserve numbering.
        DECLARE
          l_empty BLOB;
        BEGIN
          DBMS_LOB.CREATETEMPORARY(l_empty, TRUE, DBMS_LOB.SESSION);
          l_obj_nr := rad_pdf_serial.write_stream_obj(p_doc, l_empty, NULL, FALSE);
          DBMS_LOB.FREETEMPORARY(l_empty);
        END;

        -- ToUnicode CMap stream (l_font_obj+8)
        DECLARE
          l_cmap_txt VARCHAR2(32767);
          l_cmap     BLOB;
          l_raw      RAW(32767);
          l_raw_len  PLS_INTEGER;
        BEGIN
          l_cmap_txt :=
            '/CIDInit /ProcSet findresource begin' || CHR(10) ||
            '12 dict begin' || CHR(10) ||
            'begincmap' || CHR(10) ||
            '/CIDSystemInfo <</Registry (Adobe) /Ordering (UCS) /Supplement 0>> def' || CHR(10) ||
            '/CMapName /Adobe-Identity-UCS def' || CHR(10) ||
            '/CMapType 2 def' || CHR(10) ||
            '1 begincodespacerange' || CHR(10) ||
            '<0000> <FFFF>' || CHR(10) ||
            'endcodespacerange' || CHR(10) ||
            'endcmap' || CHR(10) ||
            'CMapName currentdict /CMap defineresource pop' || CHR(10) ||
            'end' || CHR(10) ||
            'end';
          DBMS_LOB.CREATETEMPORARY(l_cmap, TRUE, DBMS_LOB.SESSION);
          l_raw := UTL_RAW.CAST_TO_RAW(l_cmap_txt);
          l_raw_len := UTL_RAW.LENGTH(l_raw);
          IF l_raw_len > 0 THEN
            DBMS_LOB.WRITEAPPEND(l_cmap, l_raw_len, l_raw);
          END IF;
          l_obj_nr := rad_pdf_serial.write_stream_obj(p_doc, l_cmap, NULL, FALSE);
          DBMS_LOB.FREETEMPORARY(l_cmap);
        END;

        l_obj_nr := l_font_obj;  -- resource entry uses base object number

      ELSE
        -- Non-CID TrueType (simple single-byte encoding)
        g_fonts(l_fi).first_char := g_fonts(l_fi).used_chars.FIRST;
        g_fonts(l_fi).last_char  := g_fonts(l_fi).used_chars.LAST;

        l_obj_nr := rad_pdf_serial.begin_obj(p_doc);
        rad_pdf_serial.doc_write(p_doc,
          '<</Type /Font /Subtype /' || g_fonts(l_fi).subtype ||
          ' /BaseFont /' || g_fonts(l_fi).name ||
          ' /FirstChar ' || g_fonts(l_fi).first_char ||
          ' /LastChar '  || g_fonts(l_fi).last_char  ||
          ' /Widths '    || TO_CHAR(l_obj_nr+1) || ' 0 R' ||
          ' /FontDescriptor ' || TO_CHAR(l_obj_nr+2) || ' 0 R' ||
          ' /Encoding '  || TO_CHAR(l_obj_nr+3) || ' 0 R>>');
        rad_pdf_serial.end_obj(p_doc);

        -- Widths array (l_obj_nr+1)
        l_dummy := rad_pdf_serial.begin_obj(p_doc);
        rad_pdf_serial.doc_write(p_doc, '[');
        FOR i IN g_fonts(l_fi).first_char .. g_fonts(l_fi).last_char LOOP
          IF g_fonts(l_fi).char_width_tab.EXISTS(i) THEN
            rad_pdf_serial.doc_write(p_doc, TO_CHAR(g_fonts(l_fi).char_width_tab(i)));
          ELSE
            rad_pdf_serial.doc_write(p_doc, '0');
          END IF;
        END LOOP;
        rad_pdf_serial.doc_write(p_doc, ']');
        rad_pdf_serial.end_obj(p_doc);

        -- FontDescriptor (l_obj_nr+2)
        l_dummy := rad_pdf_serial.begin_obj(p_doc,
          '/Type /FontDescriptor' ||
          ' /FontName /' || g_fonts(l_fi).name ||
          ' /Flags '     || g_fonts(l_fi).flags ||
          ' /FontBBox [' || g_fonts(l_fi).bb_xmin || ' ' || g_fonts(l_fi).bb_ymin ||
          ' '            || g_fonts(l_fi).bb_xmax || ' ' || g_fonts(l_fi).bb_ymax || ']' ||
          ' /ItalicAngle ' || rad_pdf_codec.fmt(g_fonts(l_fi).italic_angle, 2) ||
          ' /Ascent '      || g_fonts(l_fi).ascent ||
          ' /Descent '     || g_fonts(l_fi).descent ||
          ' /CapHeight '   || g_fonts(l_fi).capheight ||
          ' /StemV '       || g_fonts(l_fi).stemv ||
          CASE WHEN g_fonts(l_fi).embed AND g_fonts(l_fi).fontfile2 IS NOT NULL
               THEN ' /FontFile2 ' || TO_CHAR(l_obj_nr+4) || ' 0 R' END);

        -- Encoding (l_obj_nr+3)
        l_dummy := rad_pdf_serial.begin_obj(p_doc,
          '/Type /Encoding /BaseEncoding /WinAnsiEncoding ' || g_fonts(l_fi).diff);

        -- FontFile2 stream (l_obj_nr+4) — only if embedding
        IF g_fonts(l_fi).embed AND g_fonts(l_fi).fontfile2 IS NOT NULL THEN
          DECLARE
            l_extra VARCHAR2(60) :=
              '/Length1 ' || DBMS_LOB.GETLENGTH(g_fonts(l_fi).fontfile2);
            l_tmp   BLOB;
            l_flen  NUMBER := DBMS_LOB.GETLENGTH(g_fonts(l_fi).fontfile2);
          BEGIN
            DBMS_LOB.CREATETEMPORARY(l_tmp, TRUE, DBMS_LOB.SESSION);
            IF l_flen > 0 THEN
              DBMS_LOB.COPY(l_tmp, g_fonts(l_fi).fontfile2, l_flen);
            END IF;
            l_obj_nr := rad_pdf_serial.write_stream_obj(p_doc, l_tmp, l_extra,
                                                    g_fonts(l_fi).compress_font);
            DBMS_LOB.FREETEMPORARY(l_tmp);
          END;
        END IF;

      END IF;  -- font type branch

      l_resources := l_resources || '/F' || TO_CHAR(l_fi) ||
                     ' ' || TO_CHAR(l_obj_nr) || ' 0 R ';
      l_fi := g_doc_state(p_doc).used_fonts.NEXT(l_fi);
    END LOOP;

    RETURN l_resources;
  END write_font_objects;

-- ---------------------------------------------------------------------------
-- Public: close_doc
--   Frees only the fonts in g_doc_state(p_doc).doc_fonts.
--   Rebuilds g_name_idx from surviving fonts.
--   Deletes the doc entry from g_doc_state.
-- ---------------------------------------------------------------------------
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_idx PLS_INTEGER;
    l_di  PLS_INTEGER;
  BEGIN
    IF NOT g_doc_state.EXISTS(p_doc) THEN RETURN; END IF;

    -- Free each font blob that belongs to this document
    l_di := g_doc_state(p_doc).doc_fonts.FIRST;
    WHILE l_di IS NOT NULL LOOP
      IF g_fonts.EXISTS(l_di) THEN
        IF g_fonts(l_di).fontfile2 IS NOT NULL AND
           DBMS_LOB.ISTEMPORARY(g_fonts(l_di).fontfile2) = 1 THEN
          DBMS_LOB.FREETEMPORARY(g_fonts(l_di).fontfile2);
        END IF;
        g_fonts.DELETE(l_di);
      END IF;
      l_di := g_doc_state(p_doc).doc_fonts.NEXT(l_di);
    END LOOP;

    -- Delete doc state
    g_doc_state.DELETE(p_doc);

    -- Rebuild name index from surviving (preloaded/standard) fonts
    g_name_idx.DELETE;
    IF g_fonts.COUNT > 0 THEN
      l_idx := g_fonts.FIRST;
      WHILE l_idx IS NOT NULL LOOP
        register_font_name(l_idx);
        l_idx := g_fonts.NEXT(l_idx);
      END LOOP;
    END IF;
  END close_doc;

-- ---------------------------------------------------------------------------
-- Public: accessors
-- ---------------------------------------------------------------------------
  FUNCTION font_exists(p_font_idx IN PLS_INTEGER) RETURN BOOLEAN IS
  BEGIN
    RETURN g_fonts.EXISTS(p_font_idx);
  END font_exists;

  FUNCTION is_cid(p_font_idx IN PLS_INTEGER) RETURN BOOLEAN IS
  BEGIN
    RETURN g_fonts(p_font_idx).cid;
  END is_cid;

  FUNCTION unit_norm(p_font_idx IN PLS_INTEGER) RETURN NUMBER IS
  BEGIN
    RETURN g_fonts(p_font_idx).unit_norm;
  END unit_norm;

  FUNCTION font_pdf_name(p_font_idx IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN g_fonts(p_font_idx).name;
  END font_pdf_name;

END rad_pdf_fonts;
/
