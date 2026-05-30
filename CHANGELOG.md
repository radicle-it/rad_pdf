# Changelog

All notable changes to RAD_PDF are documented here.  
Format: [Keep a Changelog](https://keepachangelog.com) - Versioning: [SemVer](https://semver.org)

## [Unreleased]

_No unreleased changes._

## [1.5.1] - Unreleased

### Fixed - Image cache memory leak (`rad_pdf_images`)

- **`evict_to_fit` smask leak**: when the LRU eviction loop freed a cache slot
  containing a PNG with an alpha channel, it freed `img.pixels` but left
  `img.smask` (the greyscale alpha BLOB) allocated in the session's TEMPORARY
  tablespace. Over long sessions with many transparent PNG replacements the
  unreferenced smask BLOBs would accumulate silently. Fixed to mirror the
  complete dual-BLOB cleanup already present in `clear_image_cache`.

### Added - Persistent graphics-state setters (`rad_pdf_canvas`)

- New procedures `set_draw_color`, `set_fill_color`, `set_line_width` on both
  `rad_pdf_canvas` and the `rad_pdf` public facade.
  They store values in the per-document canvas state and are used as fallback
  defaults by `line`, `h_line`, and `v_line` when the per-call `p_color` /
  `p_line_width` parameter is `NULL`. Initial state: stroke = `'000000'`,
  fill = `NULL` (no persistent fill), width = `0.5 pt` - matching the
  previous hard-coded defaults, so all existing code is backward-compatible.

- **`line`, `h_line`, `v_line`**: `p_color` and `p_width`/`p_line_width`
  now default to `NULL` (was `'000000'` / `0.5`). `NULL` means "inherit
  from the persistent state set by `set_draw_color` / `set_line_width`".
  Callers that never changed these parameters see identical output because
  the persistent defaults match the old hard-coded values.

- `rect`, `polygon`, `path` remain per-call only: `p_line_color = NULL`
  still means "no stroke" for those primitives.

## [1.5.0] - Unreleased

### Added - Line dash patterns (`rad_pdf_canvas.set_line_dash`)

- New procedure `rad_pdf.set_line_dash` (and `rad_pdf_canvas.set_line_dash`):
  set the current line dash pattern for subsequent stroked paths.
  Parameters: `p_dash` (dash length), `p_gap` (gap length, defaults to `p_dash`
  for a symmetric pattern), `p_phase` (offset into the pattern, default 0),
  `p_unit` (default `'pt'`). Call with `p_dash => 0` to restore solid lines
  (`[] 0 d`). The pattern persists until changed or the graphics state is
  restored.

### Added - Justified text (`rad_pdf_canvas.write_wrapped`)

- `write_wrapped` now accepts `p_align => 'J'` for full justification.
  Non-last wrapped lines emit a PDF `Tw` (word-spacing) operator that
  distributes the surplus line width across inter-word spaces so the text
  reaches both margins. The last line of each paragraph is always
  left-aligned (standard typographic convention). Single-word lines
  (where there are no inter-word spaces) are also left-aligned.
  All existing alignments (`'L'`, `'C'`, `'R'`) are unchanged.

## [1.4.1] - Unreleased

### Fixed - JPEG image improvements (`rad_pdf_images`)

- **Progressive JPEG (SOF2)**: `parse_jpg()` now recognises the `FFC2`
  Start-of-Frame marker in addition to `FFC0`. Progressive JPEGs whose
  dimensions were encoded only in a SOF2 marker previously fell through
  with default 1x1 dimensions, producing a corrupt or rejected image XObject.

- **CMYK JPEG**: `write_image_objects()` now detects 4-component JPEG images
  and emits `/ColorSpace /DeviceCMYK /Decode [1 0 1 0 1 0 1 0]` instead of
  `/ColorSpace /DeviceRGB`. Without this, Photoshop/press-export CMYK JPEGs
  were rendered with completely inverted (negative) colors. The `/Decode`
  array is required by the PDF specification to account for the Adobe
  convention where 0 = full ink, 255 = no ink.

## [1.4.0] - Unreleased

### Added - Watermark (`rad_pdf.set_watermark`)

- New procedure `rad_pdf.set_watermark`: register a text watermark drawn
  behind or in front of every page at finalization. Parameters: `p_text`
  (up to 500 chars), `p_font_name` (default `'Helvetica'`), `p_font_size`
  in points (default 60), `p_color` 6-char hex RGB (default `'C0C0C0'`),
  `p_opacity` in [0.0, 1.0] (default 0.3), `p_angle` counter-clockwise
  degrees in [-360, 360] (default 45), `p_layer` `'UNDER'` or `'OVER'`
  (default `'UNDER'`).

- New procedure `rad_pdf.set_watermark_image`: register an image watermark
  (loaded via `rad_pdf_images.load_image`). Parameters: `p_image_id`,
  `p_opacity` (default 0.3), `p_width_pct` in [1, 100] percent of page
  width with aspect ratio preserved (default 60), `p_layer` (default
  `'UNDER'`).

- New procedure `rad_pdf.clear_watermark`: remove a previously registered
  watermark. No-op if no watermark is set.

- All three procedures are also available directly on `rad_pdf_canvas` for
  canvas-only (no layout engine) documents.

- The watermark is written as a **single shared PDF stream object** referenced
  by every page's `/Contents` array. File size growth is independent of page
  count.

- **Zero change to existing output** when no watermark is set: no extra stream
  objects, no `/Contents` array, no `/ExtGState` in resources.

- Opacity < 1.0 adds `/ExtGState <</WM_GS ...>>` to each page's `/Resources`.
  Opacity = 1.0 emits no graphics state operator and no `/ExtGState` entry.

- Watermark drawing is wrapped in `q ... Q` (graphics state save/restore).
  The watermark CTM, colour, and opacity do not leak into surrounding content.

- Calling `set_watermark` or `set_watermark_image` twice replaces the previous
  registration. Only one watermark per document; text and image watermarks
  cannot coexist.

- `src/rad_pdf_types.pks`: version bumped to `'1.4.0'`.

- `src/install/install_phase10.sql`: upgrade-only script for v1.3.x to v1.4.0.
  Recompiles `rad_pdf_types`, `rad_pdf_canvas` (spec + body), `rad_pdf`
  (spec + body).

- `tests/phase11_watermark.sql`: 30 acceptance tests covering text and image
  watermarks, UNDER/OVER layer, opacity 0/1 boundary cases, angle variants,
  multi-page documents, page template + watermark combination, layout engine
  and template engine integration, `clear_watermark`, session isolation
  (two independent documents), all validation error paths, and a non-regression
  check that documents without a watermark produce no extra PDF structures.

- `docs/sample13.sql`: non-APEX example: "DRAFT" grey watermark on an EMP
  table report.

- `docs/apex/apex_sample09.sql`: APEX conditional watermark driven by a page
  item (`P1_IS_DRAFT`); includes an alternative snippet for APEX authorization
  scheme-based stamping.

## [1.3.0] - Unreleased

### Added - Auto-width columns (`t_column_def.auto_width`)

- New field `auto_width BOOLEAN := FALSE` on `t_column_def`: when `TRUE`, the
  column width is derived from content during the measure pass instead of using
  the declared `width` value.

- New field `max_width NUMBER := NULL` on `t_column_def`: upper cap for
  auto-width columns in the same unit as `width` (NULL = no cap).

- `width` is retained as a minimum floor: `auto_width` columns are never
  narrower than the declared `width` value.

- Width is measured from the populated row cache (no second query execution):
  max of header label width (in `header_fmt` font) and widest data cell (in
  `data_fmt` font), including left and right cell margins.

- `num_format` is honoured during measurement: the formatted display string
  (via `TO_CHAR(TO_NUMBER(...), num_format)`) is measured, not the raw value.

- `auto_width = TRUE` and `wrap = TRUE` on the same column: `auto_width` is
  silently ignored and the column behaves as a wrap column with the declared
  `width`. Wrap requires a fixed width to determine line-break points.

- Auto-width columns participate in `col_widths` proportional fill as normal;
  their content-based widths replace the declared widths before scaling.

- Streaming tables (`t_table_def.streaming = TRUE`): auto-width falls back to
  header-only measurement (the row cache is not populated for streaming tables).

- `src/install/install_phase11.sql`: recompiles `rad_pdf_types` and
  `rad_pdf_table` to pick up the new fields and `resolve_auto_widths` logic.

- `tests/phase12_autowidth.sql`: 16 acceptance tests covering single and
  multi-column auto-width, floor/cap, wrap interaction, NULL values,
  num_format measurement, refcursor source, multi-page tables, layout engine
  and template engine integration, and two-document session isolation.

## [1.2.0] - Unreleased

### Added — Template engine (`rad_pdf_template`, Phase 9)

- New package `rad_pdf_template` (spec + body, `AUTHID CURRENT_USER`) — a
  lightweight, injection-safe XML-like template engine that turns a CLOB or
  VARCHAR2 template into a PDF document section.

- **Block tags** supported in templates:
  `<p>`, `<h1>`–`<h6>`, `<ul>`, `<ol>`, `<li>`,
  `<spacer height="Xpt"/>`, `<hr [color="RRGGBB"] [width="N"]/>`,
  `<img id="N" [width="Xmm"] [height="Ymm"]/>`,
  `<table columns="NAME" query="SQL" allow_query="true" .../>`,
  `<pagebreak/>`

- **Inline tags** inside `<p>`, `<li>`, and `<h1>`–`<h6>`:
  `<b>`, `<i>`, `<br/>`, `<color rgb="RRGGBB">`, `<font size="Xpt">` —
  all with unlimited LIFO nesting depth.  Mixed-style paragraphs render
  inline on the same wrapped line via the `PARA_RUNS` flowable.

- **`#KEY#` bind substitution**: CLOB-level scanner (no 32767-char limit);
  `##` escapes to `#`; unknown tokens are written verbatim.

- **`<if bind="KEY">…</if>` conditional blocks**: evaluated before bind
  substitution so suppressed blocks never trigger NULL-bind errors.

- **Auto-escape** of bind values (`&` → `&amp;`, `<` → `&lt;`,
  `>` → `&gt;`); bypass per-entry with `t_bind_entry.raw = TRUE`.

- **SQL injection protection for `<table query>`**: `#TOKEN#` placeholders
  inside `query` attributes are automatically safe-quoted via a
  CHR(1)/CHR(2) sentinel mechanism (Phase 0b, `shield_query_attrs`).
  The raw bind value is wrapped in SQL single quotes with embedded quotes
  doubled — no manual `TO_NUMBER` validation is required for safety.

- **Column set registry**: `register_columns`, `drop_columns`,
  `clear_columns` — pre-register `t_columns` definitions once (e.g. in an
  APEX Application Process) and reference them by name in `<table>` tags.

- **`<table>` security double opt-in**: both `allow_query="true"` in the
  tag AND `p_options.allow_queries = TRUE` in `t_template_options` are
  required; each check raises a distinct error message naming the missing piece.

- **`<table>` optional attributes**: `row_height`, `max_rows`, `header_bg`,
  `alt_bg`, `border_color`; invalid hex colour values are silently ignored.

- **`t_template_options`** record: `default_font_name`, `default_font_style`,
  `default_font_size`, `default_style`, `strict_tags`, `allow_queries`,
  `max_rows` (global row cap applied to every `<table>` in the call).

- **`escape_value`** public utility function for callers that need to
  manually pre-escape a value before passing it as `raw = TRUE`.

- **Four `render` overloads**: `(doc, CLOB, binds, opts)`,
  `(doc, VARCHAR2, binds, opts)`, `(doc, CLOB, opts)`,
  `(doc, VARCHAR2, opts)`.

- **`rad_pdf.render_template`** facade (4 matching overloads) in the public
  package for callers who import only `rad_pdf`.

- **`t_bind_entry`** and **`t_bind_array`** types added to `rad_pdf_types`
  (plus `t_template_options`, `t_inline_run`, `t_inline_run_list`,
  `c_flow_para_runs`, `c_err_template`).

- **`src/install/install_phase9.sql`**: installs `rad_pdf_template`; uses
  `SET DEFINE OFF` around the `pkb` compile step so `&amp;` in
  `escape_value` is not substituted by SQL\*Plus/SQLcl.

- **`tests/phase10_template.sql`** with **36 acceptance tests** covering all
  tags, inline markup, conditional blocks, bind substitution, error paths,
  security (SQL injection), large-CLOB paths, and edge cases.

- **`docs/TEMPLATE_GUIDE.md`**: complete template engine reference —
  pipeline diagram, tag catalogue, bind substitution, conditional blocks,
  security model, APEX integration patterns, and error code table.

- **`docs/apex/apex_template_01.sql`–`apex_template_14.sql`**: 14 worked
  APEX examples (minimal hello-world through DB-driven templates, multi-page
  layouts, and conditional sections).

- **`docs/sample11.sql`**: non-APEX template engine example (standalone
  SQL\*Plus / SQL Developer).

- **`docs/sample12.sql`**: DB-driven template store pattern (`pdf_templates`
  table, hot-update without code change).

### Added — Other

- `rad_pdf_types.c_err_template` constant (`-20810`) and
  `t_inline_run` / `t_inline_run_list` / `t_flowable.para_runs_ref_id` for
  the new PARA_RUNS flowable type.

- `rad_pdf_layout.paragraph_runs` constructor and `render_para_runs` render
  pass for multi-style inline paragraphs.

### Changed

- Install scripts moved from `src/` into `src/install/` subfolder;
  `install.sql` updated to reference `@@install/install_phaseN.sql`.

- `docs/TEMPLATE_GUIDE.md` relocated from `docs/apex/` to `docs/`
  (root-level docs directory alongside `README.md`).

- `.gitignore`: `apex/` pattern anchored to repository root (`/apex/`) so
  that `docs/apex/` is no longer inadvertently excluded from version control.

### Fixed

- **SQL injection** via `#TOKEN#` in `<table query="...">` attributes:
  previously substituted verbatim, allowing single-quote injection; now
  wrapped in safe-quoted SQL string literals automatically.

- **`find_tag_end` ORA-06502**: `VARCHAR2(512)` buffer overflowed on 512-char
  chunks containing multi-byte UTF-8 characters (e.g. em-dash U+2014, 3
  bytes in AL32UTF8). Enlarged to `VARCHAR2(2048)`.

- **`draw_cell` vertical text alignment** (non-wrap cells): baseline was
  placed at `p_y + margin_bot` (≈1pt), clipping descenders below the cell
  border. New formula centres text: `p_y + p_h/2 − font_size × 0.25`.

- **Post-`<hr>` spacer**: headings placed after a horizontal rule with an
  8–10pt spacer had cap ascenders visually overlapping the rule. Spacer
  before `<h1>`/`<h2>` increased to 14pt across APEX template examples.

- **`rad_pdf_table` cursor leak**: DBMS_SQL cursors are now always closed
  in a `BEGIN/EXCEPTION` guard inside `table_flow`, `measure_table`,
  `query2labels`, and `refcursor2labels`. A `CLOSE_CURSOR` failure in the
  handler is silently swallowed so it never masks the original error.

- **`extract_attr` truncation**: return type widened from `VARCHAR2(4000)` to
  `VARCHAR2(32767)`, fixing silent truncation of long `<table query>` strings.

- **`<LI>` / `<IF>` uppercase normalisation**: the CLOB-level scanners use
  `DBMS_LOB.INSTR` which is case-sensitive; Phase 0 now normalises uppercase
  `<LI>`, `</LI>`, `<IF ...>`, `</IF>` to lowercase via SQL-engine `REPLACE`
  (which is CLOB-aware, avoiding the PL/SQL `REPLACE` varchar2 32767 limit).

- **`<br/>` routing**: always dispatched via PARA_RUNS regardless of whether
  other inline markup is present, giving consistent within-paragraph line
  breaks in all contexts.

- **`default_font_name` / `default_font_style` / `default_font_size`** in
  `t_template_options` were accepted but had no effect; now lazily derive a
  style variant from `default_style` and apply it for the render call.

- **`rad_pdf_template.pkb` compile corruption**: `shield_query_attrs` was
  declared before `find_tag_end` and `extract_attr` in the file, causing
  PLS-00313 forward-reference errors that were silently masked by SQL\*Plus
  consuming stdin lines during `&amp;` substitution; moved after `find_tag_end`.

### Refactored (internal, no API change)

- `rad_pdf_template.pkb`: extracted `normalize_clob` (Phase 0 CLOB
  case-folding), `handle_table_tag` (`<table>` attribute parsing and dispatch),
  and `emit_list_item` (list prefix + dispatch) as private procedures, reducing
  duplication across render overloads and dispatch paths.

- `rad_pdf_table.pkb`: extracted `fetch_into_cache` (shared
  DESCRIBE/DEFINE/EXECUTE/FETCH pattern for table and labels) and
  `draw_labels_from_cursor` (shared label-drawing loop), eliminating ~60
  lines of duplication across `table_flow`, `measure_table`, `query2labels`,
  and `refcursor2labels`.

---

## [1.1.0] - 2026-05-24

### Added
- `wrap` field on `t_column_def`: set `wrap = TRUE` to enable multi-line cell text
  with dynamic row height in `rad_pdf_table`; `wrap = FALSE` by default so all
  existing tables are unaffected
- `rad_pdf.get_info(p_doc, p_info)` in the public facade; delegates to
  `rad_pdf_canvas.get_info`; accepts `c_info_*` constants from `rad_pdf_types`
- `rad_pdf_types.c_version` constant (`'1.1.0'`) and `rad_pdf.version()` function
- `docs/apex/apex_sample05.sql`: complete working example of cover page on page 1
  with header/footer from page 2 using `IF #PAGE_NR# > 1` guard
- `docs/apex/apex_sample06.sql`: APEX example of table with `wrap = TRUE`
- `docs/sample10.sql`: SQL*Plus/SQL Developer example of table with `wrap = TRUE`
- Cover page pattern documented in `docs/README.md` and `docs/apex/README.md`
- `get_info` constants table and API entry in `docs/README.md`

### Fixed
- `num_format` on `t_column_def.data_fmt` was ignored when rendering table data
  cells; now applied via `TO_CHAR(TO_NUMBER(...), num_format)` with fallback for
  non-numeric values
- `has_wrap_cols` declared after `measure_table` in `rad_pdf_table.pkb` caused
  `PLS-00313` forward reference error on recompilation; moved before
  `draw_header_row`
- `install_phase2.sql` compiled the final `rad_pdf_ctx.pkb` before `rad_pdf_layout`
  and `rad_pdf_table` existed, causing `PLS-00201`; replaced with an inline stub
  body whose `close_doc` only frees the handle
- `install_phase6.sql` incorrectly included `@@rad_pdf_ctx.pkb`; removed (Phase 7
  compiles the full body correctly)

### Changed
- All em dashes replaced with hyphens in documentation and examples

## [1.0.0] - 2026-04-01

### Added
- Initial public release of the RAD_PDF core library
- Modular 8-phase install (`rad_pdf_types`, `rad_pdf_units`, `rad_pdf_codec`,
  `rad_pdf_styles`, `rad_pdf_ctx`, `rad_pdf_serial`, `rad_pdf_fonts`,
  `rad_pdf_images`, `rad_pdf_canvas`, `rad_pdf_layout`, `rad_pdf_table`, `rad_pdf`)
- Layout engine with flowable paragraph, heading, spacer, h_rule, page_break, image
- Canvas API: text, lines, rectangles, polygons, images at absolute coordinates
- Table rendering via `query2table` (VARCHAR2/CLOB), `refcursor2table`,
  `query2labels`, `refcursor2labels`
- Page templates with `header_proc` / `footer_proc` callbacks and token substitution
  (`#PAGE_NR#`, `#PAGE_COUNT#`, `#DOC_HANDLE#`)
- Font support: Type1 (Helvetica, Times, Courier) and TrueType/CID
- Image support: JPEG, PNG, GIF from BLOB, Oracle Directory, or HTTPS URL
- Examples `apex_sample00-04` and `sample01-09`
- Phase acceptance tests `phase1_foundation.sql` through `phase9_integration.sql`
