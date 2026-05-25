# Changelog

All notable changes to RAD_PDF are documented here.  
Format: [Keep a Changelog](https://keepachangelog.com) - Versioning: [SemVer](https://semver.org)

## [Unreleased]

### Added
- `rad_pdf_template` package (Phase 9): lightweight XML-like template engine
  - Parses CLOB/VARCHAR2 templates with block tags (`<p>`, `<h1>`-`<h6>`,
    `<spacer>`, `<hr>`, `<table>`, `<img>`, `<pagebreak>`) and inline tags
    (`<b>`, `<i>`, `<br/>` inside `<p>`)
  - `#KEY#` placeholder substitution via `t_bind_array`; `##` escapes to `#`
  - Column set registry (`register_columns` / `drop_columns` / `clear_columns`)
    for referencing pre-defined `t_columns` from `<table>` tags
  - Security double opt-in for `<table>` query execution:
    `allow_query="true"` in tag AND `allow_queries = TRUE` in `t_template_options`
  - `escape_value` utility function for safe bind value encoding
  - Lazy bold/italic style derivation (creates `<style>__b`, `__i`, `__bi`
    variants on first use)
  - Four `render` overloads: CLOB+binds, VARCHAR2+binds, CLOB no-bind,
    VARCHAR2 no-bind
  - `rad_pdf.render_template` facade shortcuts (4 overloads) delegating to
    `rad_pdf_template.render`
  - `src/install_phase9.sql` and updated `src/install.sql`
  - `tests/phase10_template.sql` with 16 acceptance tests
  - `docs/sample11.sql`: non-APEX template engine example
  - `docs/apex/apex_sample07.sql`: APEX template engine example

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
