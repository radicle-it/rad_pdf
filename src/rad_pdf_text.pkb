CREATE OR REPLACE PACKAGE BODY rad_pdf_text IS
  FUNCTION prepare_style(p_font_idx IN PLS_INTEGER,p_font_size IN NUMBER,
                         p_color IN rad_pdf_types.t_rgb,
                         p_leading IN NUMBER DEFAULT NULL) RETURN t_style IS
    l_style t_style;
  BEGIN
    IF NVL(p_font_size,0)<=0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_font,'Font size must be positive');
    END IF;
    l_style.font_idx := p_font_idx;
    l_style.font_size := p_font_size;
    l_style.cid := rad_pdf_fonts.is_cid(p_font_idx);
    l_style.leading := GREATEST(p_font_size*1.2,NVL(p_leading,0));
    l_style.prefix := 'BT'||CHR(10)||'/F'||p_font_idx||' '
      ||rad_pdf_codec.fmt(p_font_size,2)||' Tf'||CHR(10)
      ||rad_pdf_codec.rgb_to_pdf(NVL(p_color,'000000'))||' rg'||CHR(10);
    RETURN l_style;
  END;
  FUNCTION prepare_style(p_doc IN rad_pdf_types.t_doc_handle,
                         p_format IN rad_pdf_types.t_cell_format) RETURN t_style IS
  BEGIN
    RETURN prepare_style(rad_pdf_fonts.find_font(p_doc,NVL(p_format.font_name,'Helvetica'),p_format.font_style),
      NVL(p_format.font_size,10),p_format.font_color,
      CASE WHEN p_format.spacing IS NOT NULL THEN rad_pdf_units.parse_with_unit(p_format.spacing) END);
  END;
  FUNCTION compile(p_doc IN rad_pdf_types.t_doc_handle,
                   p_text IN CLOB,
                   p_runs IN rad_pdf_types.t_inline_run_list,
                   p_base_style IN VARCHAR2,
                   p_width IN NUMBER,
                   p_varchar IN VARCHAR2 DEFAULT NULL,
                   p_prepared_style IN t_style DEFAULT NULL,
                   p_alignment IN rad_pdf_types.t_align_h DEFAULT 'L') RETURN t_plan IS
    TYPE t_style_ids IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(110);
    TYPE t_width_cache IS TABLE OF NUMBER INDEX BY VARCHAR2(4040);
    TYPE t_spaces IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    l_ids t_style_ids;
    l_cache t_width_cache;
    l_spaces t_spaces;
    l_plan t_plan;
    l_base PLS_INTEGER;
    l_style PLS_INTEGER;
    l_fmt rad_pdf_types.t_cell_format;
    l_word VARCHAR2(4000);
    l_word_bytes PLS_INTEGER := 0;
    l_word_style PLS_INTEGER;
    l_pending_space BOOLEAN := FALSE;
    l_previous_cr BOOLEAN := FALSE;
    l_first PLS_INTEGER := 1;
    l_width NUMBER := 0;
    l_height NUMBER := 0;
    l_ascent NUMBER := 0;
    l_gaps PLS_INTEGER := 0;
    l_pos PLS_INTEGER := 1;
    l_len PLS_INTEGER;
    l_buf VARCHAR2(32767);
    i PLS_INTEGER;

    FUNCTION resolve_style(p_name VARCHAR2) RETURN PLS_INTEGER IS
      l_name VARCHAR2(110) := NVL(p_name,'body');
      l_id PLS_INTEGER;
      l_format rad_pdf_types.t_cell_format;
    BEGIN
      IF l_ids.EXISTS(l_name) THEN RETURN l_ids(l_name); END IF;
      l_id := l_plan.styles.COUNT+1;
      l_format := rad_pdf_styles.get(l_name);
      l_plan.styles(l_id) := prepare_style(p_doc,l_format);
      l_spaces(l_id) := rad_pdf_fonts.text_width(' ',l_plan.styles(l_id).font_idx,l_plan.styles(l_id).font_size);
      l_ids(l_name) := l_id;
      RETURN l_id;
    END;

    FUNCTION word_width(p_word VARCHAR2,p_id PLS_INTEGER) RETURN NUMBER IS
      l_key VARCHAR2(4040) := p_id||':'||p_word;
      l_result NUMBER;
    BEGIN
      IF l_cache.EXISTS(l_key) THEN RETURN l_cache(l_key); END IF;
      l_result := rad_pdf_fonts.text_width(p_word,l_plan.styles(p_id).font_idx,l_plan.styles(p_id).font_size);
      IF l_cache.COUNT=1024 THEN l_cache.DELETE; END IF;
      l_cache(l_key) := l_result;
      RETURN l_result;
    END;

    PROCEDURE end_line(p_terminal BOOLEAN) IS
      l_n PLS_INTEGER := l_plan.lines.COUNT+1;
    BEGIN
      l_plan.lines(l_n).first_fragment := l_first;
      l_plan.lines(l_n).last_fragment := l_plan.fragments.COUNT;
      l_plan.lines(l_n).width := l_width;
      l_plan.lines(l_n).height := GREATEST(l_height,l_plan.styles(l_base).leading);
      l_plan.lines(l_n).ascent := GREATEST(l_ascent,l_plan.styles(l_base).font_size);
      l_plan.lines(l_n).gaps := l_gaps;
      l_plan.lines(l_n).terminal := p_terminal;
      l_plan.height := l_plan.height+l_plan.lines(l_n).height;
      l_first := l_plan.fragments.COUNT+1;
      l_width := 0; l_height := 0; l_ascent := 0; l_gaps := 0;
    END;

    PROCEDURE place_piece(p_word VARCHAR2,p_id PLS_INTEGER,p_width NUMBER,p_space BOOLEAN) IS
      l_gap NUMBER := CASE WHEN l_plan.fragments.COUNT>=l_first AND p_space THEN l_spaces(p_id) ELSE 0 END;
      l_has_gap BOOLEAN := l_plan.fragments.COUNT>=l_first AND p_space;
      l_n PLS_INTEGER := l_plan.fragments.COUNT;
    BEGIN
      IF l_n>=l_first AND l_width+l_gap+p_width>l_plan.width THEN
        end_line(FALSE);
        l_gap := 0; l_has_gap := FALSE;
      END IF;
      IF l_has_gap THEN l_gaps := l_gaps+1; END IF;
      IF l_n>=l_first AND l_plan.fragments(l_n).style_id=p_id
         AND NOT (l_plan.alignment='J' AND l_plan.styles(p_id).cid)
         AND LENGTHB(l_plan.fragments(l_n).text)+LENGTHB(p_word)
             +CASE WHEN l_has_gap THEN 1 ELSE 0 END<=4000 THEN
        l_plan.fragments(l_n).text := l_plan.fragments(l_n).text
          ||CASE WHEN l_has_gap THEN ' ' END||p_word;
      ELSE
        l_n := l_n+1;
        l_plan.fragments(l_n).text := p_word;
        l_plan.fragments(l_n).style_id := p_id;
        l_plan.fragments(l_n).x := l_width+l_gap;
        l_plan.fragments(l_n).gaps_before := l_gaps;
      END IF;
      l_width := l_width+l_gap+p_width;
      l_height := GREATEST(l_height,l_plan.styles(p_id).leading);
      l_ascent := GREATEST(l_ascent,l_plan.styles(p_id).font_size);
    END;

    PROCEDURE emit_word IS
      l_w NUMBER;
      l_piece VARCHAR2(4000);
      l_piece_w NUMBER := 0;
      l_c VARCHAR2(4);
      l_cw NUMBER;
      l_space BOOLEAN := l_pending_space;
    BEGIN
      IF l_word IS NULL THEN RETURN; END IF;
      l_w := word_width(l_word,l_word_style);
      IF l_w<=l_plan.width THEN place_piece(l_word,l_word_style,l_w,l_space);
      ELSE
        FOR k IN 1..LENGTH(l_word) LOOP
          l_c := SUBSTR(l_word,k,1);
          l_cw := word_width(l_c,l_word_style);
          IF l_cw>l_plan.width THEN
            RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_layout,'Glyph exceeds content frame width');
          END IF;
          IF l_piece IS NOT NULL AND l_piece_w+l_cw>l_plan.width THEN
            place_piece(l_piece,l_word_style,l_piece_w,l_space);
            l_space := FALSE; l_piece := NULL; l_piece_w := 0;
          END IF;
          l_piece := l_piece||l_c; l_piece_w := l_piece_w+l_cw;
        END LOOP;
        IF l_piece IS NOT NULL THEN place_piece(l_piece,l_word_style,l_piece_w,l_space); END IF;
      END IF;
      l_word := NULL; l_word_bytes := 0; l_pending_space := FALSE;
    END;

    PROCEDURE feed(p_chunk VARCHAR2,p_id PLS_INTEGER) IS
      l_pos PLS_INTEGER := 1;
      l_end PLS_INTEGER := NVL(LENGTH(p_chunk),0)+1;
      l_space PLS_INTEGER;
      l_tab PLS_INTEGER;
      l_cr PLS_INTEGER;
      l_lf PLS_INTEGER;
      l_stop PLS_INTEGER;
      l_piece VARCHAR2(4000);
      l_bytes PLS_INTEGER;
      l_count PLS_INTEGER;
      FUNCTION next_at(p_delimiter VARCHAR2,p_from PLS_INTEGER) RETURN PLS_INTEGER IS
        l_found PLS_INTEGER := INSTR(p_chunk,p_delimiter,p_from);
      BEGIN
        RETURN CASE WHEN l_found=0 THEN l_end ELSE l_found END;
      END;
    BEGIN
      -- Search each delimiter only when consumed. Whole word spans bypass the
      -- character loop; only exceptionally long words need glyph processing.
      l_space := next_at(' ',1); l_tab := next_at(CHR(9),1);
      l_cr := next_at(CHR(13),1); l_lf := next_at(CHR(10),1);
      WHILE l_pos<l_end LOOP
        l_stop := LEAST(l_space,l_tab,l_cr,l_lf);
        WHILE l_pos<l_stop LOOP
          l_count := LEAST(l_stop-l_pos,1000);
          l_piece := SUBSTR(p_chunk,l_pos,l_count);
          l_bytes := LENGTHB(l_piece);
          IF l_word IS NOT NULL AND (l_word_bytes+l_bytes>4000 OR l_word_style!=p_id) THEN emit_word; END IF;
          l_word := l_word||l_piece;
          l_word_bytes := l_word_bytes+l_bytes;
          l_word_style := p_id;
          l_previous_cr := FALSE;
          l_pos := l_pos+l_count;
        END LOOP;
        EXIT WHEN l_pos=l_end;
        emit_word;
        IF l_stop=l_space OR l_stop=l_tab THEN
          l_pending_space := TRUE; l_previous_cr := FALSE;
        ELSE
          IF l_stop=l_cr OR NOT l_previous_cr THEN end_line(TRUE); END IF;
          l_pending_space := FALSE;
          l_previous_cr := l_stop=l_cr;
        END IF;
        l_pos := l_pos+1;
        IF l_stop=l_space THEN l_space := next_at(' ',l_pos); END IF;
        IF l_stop=l_tab THEN l_tab := next_at(CHR(9),l_pos); END IF;
        IF l_stop=l_cr THEN l_cr := next_at(CHR(13),l_pos); END IF;
        IF l_stop=l_lf THEN l_lf := next_at(CHR(10),l_pos); END IF;
      END LOOP;
    END;
  BEGIN
    IF NVL(p_width,0)<=0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_layout,'Text width must be positive');
    END IF;
    l_plan.width := p_width;
    IF p_prepared_style.font_idx IS NOT NULL THEN
      l_base := 1;
      l_plan.styles(1) := p_prepared_style;
      l_spaces(1) := rad_pdf_fonts.text_width(' ',p_prepared_style.font_idx,p_prepared_style.font_size);
      l_plan.alignment := NVL(p_alignment,'L');
      feed(p_varchar,1);
    ELSE
      l_base := resolve_style(p_base_style);
      l_fmt := rad_pdf_styles.get(NVL(p_base_style,'body'));
      l_plan.alignment := NVL(l_fmt.align_h,'L');
    IF p_text IS NOT NULL THEN
      l_len := DBMS_LOB.GETLENGTH(p_text);
      WHILE l_pos<=l_len LOOP
        l_buf := DBMS_LOB.SUBSTR(p_text,8191,l_pos);
        feed(l_buf,l_base);
        l_pos := l_pos+LENGTH(l_buf);
      END LOOP;
    ELSE
      i := p_runs.FIRST;
      WHILE i IS NOT NULL LOOP
        l_style := resolve_style(p_runs(i).style_name);
        IF p_runs(i).is_br THEN
          emit_word; end_line(TRUE); l_pending_space := FALSE; l_previous_cr := FALSE;
        ELSE feed(p_runs(i).text,l_style);
        END IF;
        i := p_runs.NEXT(i);
      END LOOP;
    END IF;
    END IF;
    emit_word;
    IF l_plan.fragments.COUNT>=l_first THEN end_line(TRUE); END IF;
    RETURN l_plan;
  END compile;

  FUNCTION prepare_varchar(p_text IN VARCHAR2,p_style IN t_style,
                           p_width IN NUMBER,p_alignment IN rad_pdf_types.t_align_h DEFAULT 'L') RETURN t_plan IS
    l_runs rad_pdf_types.t_inline_run_list;
  BEGIN
    RETURN compile(NULL,NULL,l_runs,NULL,p_width,p_text,p_style,p_alignment);
  END;
  FUNCTION prepare(p_doc IN rad_pdf_types.t_doc_handle,p_text IN CLOB,
                   p_style IN VARCHAR2,p_width IN NUMBER) RETURN t_plan IS
    l_runs rad_pdf_types.t_inline_run_list;
  BEGIN
    RETURN compile(p_doc,p_text,l_runs,p_style,p_width);
  END;
  FUNCTION prepare_runs(p_doc IN rad_pdf_types.t_doc_handle,
                        p_runs IN rad_pdf_types.t_inline_run_list,
                        p_base_style IN VARCHAR2,p_width IN NUMBER) RETURN t_plan IS
  BEGIN
    RETURN compile(p_doc,NULL,p_runs,p_base_style,p_width);
  END;
END rad_pdf_text;
/
