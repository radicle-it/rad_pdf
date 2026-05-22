# RAD_PDF — User Guide

**Author:** Roberto Capancioni — [Radicle S.r.l.](https://radicle.it)  
**Based on:** [AS_PDF](https://github.com/antonscheffer/as_pdf) by Anton Scheffer  
← [Back to project README](../README.md)

---

## Table of Contents

1. [Installation](#installation)
2. [Quick Start](#quick-start)
3. [Core Concepts](#core-concepts)
4. [Document Lifecycle](#document-lifecycle)
5. [Layout Engine](#layout-engine)
6. [Canvas API](#canvas-api)
7. [Tables](#tables)
8. [Styles](#styles)
9. [Page Geometry](#page-geometry)
10. [Page Templates (Header / Footer)](#page-templates)
11. [Fonts](#fonts)
12. [Images](#images)
13. [API Reference](#api-reference)
14. [Known Limitations](#known-limitations)
15. [Examples Index](#examples-index)

---

## Installation

### Requirements

- Oracle Database **19c or later**
- A schema with `CREATE PROCEDURE`, `CREATE PACKAGE`, `CREATE TYPE` privileges
- SQL*Plus or SQL Developer to run the install script

### Steps

**1. Get the source**

```bash
git clone https://github.com/your-org/rad_pdf.git
cd rad_pdf
```

**2. Connect to Oracle as the schema owner**

```bash
# SQL*Plus
sqlplus your_schema/your_password@your_db
```

Or open a SQL Developer connection as the target schema.

**3. Run the installer**

In SQL*Plus, set the working directory to `src/` then run:

```sql
-- SQL*Plus
CD src
@install.sql
```

In SQL Developer, open `src/install.sql` with *File → Open*, then press **F5** (Run Script)
while connected as the schema owner.

The installer compiles all 12 packages in dependency order. Each phase prints its name and
`SHOW ERRORS` output. A successful install ends with:

```
=== Phase 8 install complete ===
```

**4. Verify the installation**

```sql
-- From the repo root directory:
@tests/phase9_integration.sql
```

All lines should read `PASS`. The final line will show the total count:

```
Phase 9: 31 passed, 0 failed.
```

If any test fails, run the individual phase test to isolate the issue:

```sql
@tests/phase1_foundation.sql
@tests/phase2_ctx_decoders.sql
-- ... through phase8_pdf.sql
```

**5. Volumetric benchmark (optional)**

`tests/benchmark_large_table.sql` is a separate stress suite that generates large PDFs (10 000-row tables) to validate PGA behaviour and cache cleanup. It is **not** part of the standard regression run because it takes 10–30 seconds and produces several-hundred-page PDFs. Run it manually after installation:

```sql
@tests/benchmark_large_table.sql
```

Expected output:

```
=== benchmark_large_table ===
--- 1. refcursor2table 10 000 rows ---
PASS  10k-rows: finalize succeeds (BLOB not null)
PASS  10k-rows: starts %PDF
PASS  10k-rows: BLOB > 50 000 bytes
      size = NNN.N KB  elapsed = N.NN s
--- 2. query2table 10 000 rows ---
PASS  q2t-10k: finalize succeeds
PASS  q2t-10k: starts %PDF
PASS  q2t-10k: BLOB > 50 000 bytes
      size = NNN.N KB  elapsed = N.NN s
--- 3. sequential docs (PGA leak check) ---
PASS  seq-doc-1: finalize succeeds
PASS  seq-doc-1: BLOB > 25 000 bytes
PASS  seq-doc-2: finalize succeeds
PASS  seq-doc-2: BLOB > 25 000 bytes
      2 × 5 000-row docs elapsed = N.NN s
---
benchmark_large_table: 10 passed, 0 failed.
```

### Uninstall

```sql
DROP PACKAGE rad_pdf;
DROP PACKAGE rad_pdf_table;   DROP PACKAGE rad_pdf_layout;
DROP PACKAGE rad_pdf_canvas;  DROP PACKAGE rad_pdf_images;
DROP PACKAGE rad_pdf_fonts;   DROP PACKAGE rad_pdf_serial;
DROP PACKAGE rad_pdf_ctx;     DROP PACKAGE rad_pdf_styles;
DROP PACKAGE rad_pdf_codec;   DROP PACKAGE rad_pdf_units;
DROP PACKAGE rad_pdf_types;
```

---

## Quick Start

```sql
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  rad_pdf_styles.load_defaults;          -- load built-in styles (call once per session)

  l_doc := rad_pdf.new_document;         -- create document, get handle
  rad_pdf.heading(l_doc, 'My Report', 1);
  rad_pdf.write  (l_doc, 'Hello, World!');
  l_pdf := rad_pdf.finalize(l_doc);      -- close handle, get PDF as BLOB

  -- use the BLOB: write to a table, return via bind variable, etc.
  DBMS_OUTPUT.PUT_LINE('Size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  DBMS_LOB.FREETEMPORARY(l_pdf);     -- caller owns the BLOB; free when done
END;
```

The **only package application code needs to call** is `rad_pdf`.  
All other packages (`rad_pdf_canvas`, `rad_pdf_table`, `rad_pdf_styles`, `rad_pdf_fonts`, `rad_pdf_images`) are
optional extensions for advanced use.

---

## Core Concepts

### Document handle

`rad_pdf.new_document` returns a `rad_pdf_types.t_doc_handle` (a `PLS_INTEGER`).  
Pass this handle to every subsequent call. **One handle = one document.**  
`rad_pdf.finalize` closes the handle and returns the PDF BLOB.  
After `finalize`, the handle is invalid — do not reuse it.

### Two rendering modes

| Mode | When | How |
|---|---|---|
| **Layout mode** | After any `rad_pdf.write`, `rad_pdf.heading`, `rad_pdf.query2table`, etc. | Content flows automatically across pages |
| **Canvas mode** | If you call only `rad_pdf_canvas.*` directly | You position every element by explicit coordinates |

You cannot mix both modes in the same document. Canvas calls before the first layout call are fine (they go to the first page before the layout engine takes over), but calling layout functions after canvas functions is not supported.

### Coordinate system

PDF origin is the **lower-left corner** of the page. Y increases upward.  
Default unit in most canvas calls is points (`'pt'`).  
`rad_pdf_units.to_pt(value, 'mm')` converts from other units.

| Unit | Conversion |
|---|---|
| `'pt'` / `'point'` | 1 pt = 1/72 inch (base unit) |
| `'mm'` | 1 mm ≈ 2.835 pt |
| `'cm'` | 1 cm ≈ 28.35 pt |
| `'in'` / `'inch'` | 1 in = 72 pt |

---

## Document Lifecycle

```sql
-- 1. (Optional) Load styles once per session
rad_pdf_styles.load_defaults;

-- 2. Create document
DECLARE
  l_info rad_pdf_types.t_doc_info;
  l_tpl  rad_pdf_types.t_page_template;
  l_doc  rad_pdf_types.t_doc_handle;
BEGIN
  l_info.title  := 'Annual Report';
  l_info.author := 'Finance Dept';
  -- l_tpl.page_format_name := 'A4';    -- optional template
  l_doc := rad_pdf.new_document(p_info => l_info /*, p_template => l_tpl*/);

  -- 3. Add content
  rad_pdf.heading(l_doc, 'Title', 1);
  rad_pdf.write  (l_doc, 'Body text...');

  -- 4a. Finalise — returns BLOB, closes handle
  DECLARE l_pdf BLOB; BEGIN
    l_pdf := rad_pdf.finalize(l_doc);
    -- … use l_pdf …
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- 4b. Or save to a directory
  -- rad_pdf.save(l_doc, 'MY_DIR', 'report.rad_pdf');
END;
```

### Aborting a document

If you need to discard a document without producing output:

```sql
rad_pdf.close_document(l_doc);   -- releases all memory, no PDF produced
```

---

## Layout Engine

The layout engine automatically wraps text, measures element heights, and breaks pages.  
Add content via `rad_pdf.write`, `rad_pdf.heading`, `rad_pdf.spacer`, `rad_pdf.query2table`, or the lower-level
`rad_pdf.add` with explicit flowable constructors.

### Text paragraphs

```sql
-- Default 'body' style
rad_pdf.write(l_doc, 'Normal paragraph text.');

-- Named style (built-in or custom)
rad_pdf.write(l_doc, 'Caption text here.', 'caption');
rad_pdf.write(l_doc, 'A warning message.', 'notice');  -- if you defined 'notice'
```

### Headings (h1 – h6)

```sql
rad_pdf.heading(l_doc, 'Chapter 1',    1);   -- largest
rad_pdf.heading(l_doc, 'Section 1.1',  2);
rad_pdf.heading(l_doc, 'Sub-section',  3);
```

Built-in heading styles `h1`–`h6`: Helvetica Bold, sizes 18 / 16 / 14 / 12 / 11 / 10 pt.

### Spacer

```sql
rad_pdf.spacer(l_doc, 12);   -- 12-point vertical gap
```

### Horizontal rule

```sql
rad_pdf.add(l_doc, rad_pdf_layout.h_rule());                    -- black, 0.5 pt
rad_pdf.add(l_doc, rad_pdf_layout.h_rule('808080', 1));         -- grey, 1 pt thick
```

### Explicit page break

```sql
rad_pdf.new_page(l_doc);   -- in layout mode: inserts a page-break flowable
```

### CLOB paragraphs

```sql
DECLARE l_text CLOB; BEGIN
  DBMS_LOB.CREATETEMPORARY(l_text, TRUE);
  DBMS_LOB.APPEND(l_text, 'Long body text stored as a CLOB...');
  rad_pdf.add(l_doc, rad_pdf_layout.paragraph(l_text, 'body'));
  -- Note: the layout engine takes ownership; do NOT free l_text manually
END;
```

---

## Canvas API

Use `rad_pdf_canvas.*` for precise pixel-level control: watermarks, diagrams, custom headers.

```sql
l_doc := rad_pdf.new_document;   -- new_document always creates the first page

-- Font and colour
rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'B', 14);   -- family, style (N/B/I/BI), size
rad_pdf_canvas.set_color(l_doc, 'CC3300');                -- hex RGB ink colour

-- Text at absolute position (x, y in points from lower-left)
rad_pdf_canvas.write_text(l_doc, 'Hello', 72, 700, 'pt');

-- Word-wrapped text within a width
rad_pdf_canvas.write_wrapped(l_doc, 'Long text...', 72, 650, 400, 'L', 'pt');

-- Lines and shapes
rad_pdf_canvas.h_line  (l_doc, 50, 740, 495, 0.5, '808080', 'pt');  -- horiz. line
rad_pdf_canvas.v_line  (l_doc, 50, 600, 100, 0.5, '000000', 'pt');  -- vert. line
rad_pdf_canvas.rect    (l_doc, 50, 600, 200, 80, '003366', 'E0F0FF', 1, 'pt');  -- border, fill
rad_pdf_canvas.polygon (l_doc, l_xs, l_ys, '000000', 'FFE0A0', 1);  -- arbitrary polygon

-- New page (canvas mode)
rad_pdf_canvas.new_page(l_doc);

-- Finalize (canvas-only path: no layout pass)
l_pdf := rad_pdf.finalize(l_doc);
```

### State queries

```sql
l_x := rad_pdf_canvas.get_x(l_doc);    -- current cursor X (pt)
l_y := rad_pdf_canvas.get_y(l_doc);    -- current cursor Y (pt)

-- Named info selectors:
l_w := rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_page_width);
l_h := rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_page_height);
l_mt := rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_margin_top);
```

---

## Tables

Tables are rendered by the layout engine using `rad_pdf.query2table` (facade shortcut)
or `rad_pdf_table.query2table` / `rad_pdf_table.refcursor2table` (lower-level).

### Minimal table

```sql
DECLARE
  l_cols rad_pdf_types.t_columns;
BEGIN
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(3);
  l_cols(1).label := 'ID';     l_cols(1).width := 50;
  l_cols(2).label := 'Name';   l_cols(2).width := 200;
  l_cols(3).label := 'Amount'; l_cols(3).width := 80;
  l_cols(3).data_fmt.align_h := 'R';

  rad_pdf.query2table(l_doc,
    'SELECT id, name, amount FROM my_table ORDER BY id',
    l_cols);
END;
```

### Column definition fields (`rad_pdf_types.t_column_def`)

| Field | Default | Description |
|---|---|---|
| `label` | NULL | Column header text |
| `width` | 30 | Column width in the unit set by `t_table_options.unit` |
| `header_fmt` | Helvetica B 9, center | Header cell format (see below) |
| `data_fmt` | Helvetica N 9, left | Data cell format |
| `cell_row` | 1 | Row within a multi-line cell group (advanced) |
| `offset_x/y` | NULL | Cell offset in multi-line groups (advanced) |

### Cell format fields (`rad_pdf_types.t_cell_format`)

| Field | Default | Description |
|---|---|---|
| `font_name` | `'Helvetica'` | Font family name |
| `font_style` | `'N'` | `'N'`, `'B'`, `'I'`, `'BI'` |
| `font_size` | 10 | Points |
| `font_color` | `'000000'` | Hex RGB |
| `back_color` | `'ffffff'` | Background fill |
| `line_color` | `'000000'` | Border colour |
| `border` | 0 | Bitmask: `c_border_top=1`, `c_border_bottom=2`, `c_border_left=4`, `c_border_right=8`, `c_border_all=15` |
| `align_h` | `'L'` | `'L'` left, `'C'` centre, `'R'` right |

### Color scheme (`rad_pdf_types.t_color_scheme`)

```sql
DECLARE l_clr rad_pdf_types.t_color_scheme; BEGIN
  l_clr := rad_pdf_styles.default_scheme;   -- start from defaults
  l_clr.header_paper  := '003366';      -- navy header
  l_clr.header_ink    := 'FFFFFF';      -- white header text
  l_clr.odd_paper     := 'EEF4FF';      -- light blue odd rows
  rad_pdf.query2table(l_doc, l_query, l_cols, p_colors => l_clr);
END;
```

### Table options (`rad_pdf_types.t_table_options`)

| Field | Default | Description |
|---|---|---|
| `unit` | `'pt'` | Unit for `start_x`, `start_y`, column widths |
| `start_x` | 0 | Left edge (0 = use margin) |
| `start_y` | 0 | Top edge (0 = current cursor) |
| `bulk_size` | 200 | Rows fetched per batch |
| `max_rows` | NULL | Row limit (NULL = all) |
| `break_field` | 0 | Column index to group-break on (0 = none) |

### REF CURSOR

```sql
DECLARE
  l_rc SYS_REFCURSOR;
BEGIN
  OPEN l_rc FOR SELECT dept_id, dept_name FROM departments ORDER BY 1;
  rad_pdf_table.refcursor2table(l_doc, l_rc, l_cols);
END;
```

---

## Styles

Styles are **session-scoped** named sets of font + color + alignment properties.  
They survive `rad_pdf.finalize` and can be reused across documents in the same session.

### Built-in styles

| Name | Font | Size | Notes |
|---|---|---|---|
| `'body'` / `'default'` | Helvetica N | 10 | Base body text |
| `'h1'` … `'h6'` | Helvetica B | 18 / 16 / 14 / 12 / 11 / 10 | Heading levels |
| `'caption'` | Helvetica I | 8 | Small grey caption |
| `'table_header'` | Helvetica B | 9 | Table header row |
| `'table_even'` | Helvetica N | 9 | Even data rows |
| `'table_odd'` | Helvetica N | 9 | Odd data rows (light grey) |

### Defining custom styles

```sql
rad_pdf_styles.load_defaults;   -- ensure built-ins are loaded

rad_pdf_styles.define('notice',
  p_font_name  => 'Helvetica',
  p_font_style => 'BI',
  p_font_size  => 11,
  p_font_color => 'CC3300');

rad_pdf_styles.define('code',
  p_font_name  => 'Courier',
  p_font_style => 'N',
  p_font_size  => 9,
  p_back_color => 'F5F5F5');

-- Use in layout:
rad_pdf.write(l_doc, 'WARNING: disk usage above 90%.', 'notice');
rad_pdf.write(l_doc, 'SELECT * FROM dual;',             'code');
```

---

## Page Geometry

### Page format

```sql
-- By name (A4, A3, A5, LETTER, LEGAL, TABLOID)
rad_pdf.set_page_format(l_doc, 'A4');

-- By explicit dimensions (in points)
DECLARE l_fmt rad_pdf_types.t_page_format; BEGIN
  l_fmt.width  := 595.276;   -- A4 width
  l_fmt.height := 841.890;   -- A4 height
  rad_pdf.set_page_format(l_doc, l_fmt);
END;
```

### Orientation

```sql
rad_pdf.set_page_orientation(l_doc, 'LANDSCAPE');   -- swaps width and height
rad_pdf.set_page_orientation(l_doc, 'PORTRAIT');    -- restores if currently landscape
```

### Margins

```sql
-- Individual margins in points; NULL keeps the current value
rad_pdf.set_margins(l_doc,
  p_top    => 85.039,   -- ~3 cm
  p_bottom => 56.693,   -- ~2 cm
  p_left   => 42.520,   -- ~1.5 cm
  p_right  => 42.520);

-- Or via a record
DECLARE l_mar rad_pdf_types.t_margins; BEGIN
  l_mar.top    := rad_pdf_units.to_pt(3,   'cm');
  l_mar.bottom := rad_pdf_units.to_pt(2,   'cm');
  l_mar.left   := rad_pdf_units.to_pt(1.5, 'cm');
  l_mar.right  := rad_pdf_units.to_pt(1.5, 'cm');
  rad_pdf.set_margins(l_doc, l_mar);
END;
```

---

## Page Templates

A page template sets default geometry and registers header/footer PL/SQL blocks
that are executed on **every page** after the full render pass (so `#PAGE_COUNT#` is available).

```sql
DECLARE
  l_tpl rad_pdf_types.t_page_template;
BEGIN
  l_tpl.page_format_name := 'A4';
  l_tpl.margin_top       := 70;    -- points — leave room for header
  l_tpl.margin_bottom    := 50;    -- points — leave room for footer

  -- Header proc: anonymous PL/SQL block.
  -- Tokens substituted before execution:
  --   #DOC_HANDLE#  → the numeric document handle (for rad_pdf_canvas calls)
  --   #PAGE_NR#     → current page number (1-based)
  --   #PAGE_COUNT#  → total pages in the document
  l_tpl.header_proc :=
    'BEGIN ' ||
      'rad_pdf_canvas.set_font(#DOC_HANDLE#, ''Helvetica'', ''B'', 9); ' ||
      'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
        '''My Report  |  Page #PAGE_NR# of #PAGE_COUNT#'', 42, 818, ''pt''); ' ||
      'rad_pdf_canvas.h_line(#DOC_HANDLE#, 42, 810, 511, 0.4, ''808080'', ''pt''); ' ||
    'END;';

  l_tpl.footer_proc :=
    'BEGIN ' ||
      'rad_pdf_canvas.set_font(#DOC_HANDLE#, ''Helvetica'', ''I'', 8); ' ||
      'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
        '''Confidential'', 42, 28, ''pt''); ' ||
    'END;';

  l_doc := rad_pdf.new_document(p_template => l_tpl);
END;
```

> **Tip:** `rad_pdf_canvas.h_line(doc, x, y, width_pt, thickness, color, unit)` —
> a quick horizontal line without needing `set_color` separately.

---

## Fonts

### Standard PDF fonts (always available, no embedding required)

`Helvetica`, `Times`, `Courier`, `Symbol`, `ZapfDingbats`  
Each available in styles: `'N'` (Normal), `'B'` (Bold), `'I'` (Italic), `'BI'` (Bold-Italic).

```sql
rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 14);
rad_pdf_canvas.set_font(l_doc, 'Times',     'I', 10);
rad_pdf_canvas.set_font(l_doc, 'Courier',   'N', 9);
```

### TrueType fonts (TTF / TTC)

Load from a BLOB, an Oracle Directory, or an HTTPS URL:

```sql
-- From Oracle directory (recommended for production)
DECLARE l_fi PLS_INTEGER; BEGIN
  l_fi := rad_pdf_fonts.load_ttf(l_doc, 'MY_FONTS_DIR', 'OpenSans-Regular.ttf',
            p_embed => TRUE, p_compress => TRUE);
  rad_pdf_canvas.set_font(l_doc, l_fi, 12);   -- use the returned font index
END;

-- From a BLOB
DECLARE l_fi PLS_INTEGER; l_blob BLOB; BEGIN
  -- … populate l_blob …
  l_fi := rad_pdf_fonts.load_ttf(l_doc, l_blob, p_embed => TRUE);
  rad_pdf_canvas.set_font(l_doc, l_fi, 12);
END;
```

**`p_embed => TRUE`** includes the font program in the PDF (required for fonts not available on
all viewer platforms). **`p_compress => TRUE`** (default) compresses the embedded program.

### Preloading TTF fonts for batch reports

Per-document fonts are freed on `finalize`. For batch reports generating many PDFs:

```sql
-- Preload once per session — survives close_doc
rad_pdf_fonts.preload_ttf('MY_FONTS_DIR', 'OpenSans-Regular.ttf', p_embed => TRUE);
-- Then in each loop iteration:
l_doc := rad_pdf.new_document;
rad_pdf_canvas.set_font(l_doc, 'OpenSans-Regular', 'N', 10);
l_pdf := rad_pdf.finalize(l_doc);
```

---

## Images

Load JPEG, PNG, or GIF images from a BLOB, Oracle Directory, or HTTPS URL.  
Images are cached per-session by SHA-256 hash (default cache limit: 50 MB).

```sql
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_img PLS_INTEGER;
BEGIN
  l_doc := rad_pdf.new_document;

  -- Load from Oracle directory
  l_img := rad_pdf_images.load_image(l_doc, 'MY_IMAGES_DIR', 'logo.png');

  -- Place on canvas (x, y in points from lower-left; width/height optional — keeps aspect)
  rad_pdf_canvas.put_image(l_doc, l_img, 42, 760, 120, NULL, 'L', 'T', 'pt');

  -- Or add to layout flow (auto-positioned by layout engine)
  rad_pdf.image(l_doc, l_img, 120, NULL);   -- width 120 pt, height = auto

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
```

### Batch image pattern

```sql
-- Before the batch loop:
rad_pdf_images.set_image_cache_limit(104857600);   -- 100 MB cache

-- After the batch loop:
rad_pdf_images.clear_image_cache;
```

---

## API Reference

### `rad_pdf` package — public facade

| Subprogram | Description |
|---|---|
| `new_document(p_info, p_template)` | Create document. Returns handle. |
| `finalize(p_doc)` | Finalise, close handle, return BLOB. Caller must `FREETEMPORARY`. |
| `save(p_doc, p_dir, p_filename)` | Finalise and write to Oracle directory. |
| `close_document(p_doc)` | Discard document without producing output. |
| `write(p_doc, p_text, p_style)` | Add paragraph (layout mode). |
| `heading(p_doc, p_text, p_level)` | Add heading h1–h6 (layout mode). |
| `spacer(p_doc, p_height)` | Add vertical gap in points (layout mode). |
| `add(p_doc, p_flow)` | Add a pre-built flowable (layout mode). |
| `new_page(p_doc)` | Page break (layout) or new page (canvas). |
| `query2table(p_doc, p_query, p_columns, ...)` | Add table from SQL string or CLOB. |
| `image(p_doc, p_image_id, p_width, p_height)` | Add image flowable (layout mode). |
| `set_page_format(p_doc, p_name_or_fmt)` | Set page size by name or `t_page_format`. |
| `set_page_orientation(p_doc, p_orientation)` | `'PORTRAIT'` or `'LANDSCAPE'`. |
| `set_margins(p_doc, p_top, p_bottom, p_left, p_right)` | Set individual margins (points). |

### `rad_pdf_layout` package — flowable constructors

| Function | Returns |
|---|---|
| `paragraph(p_text, p_style)` | `t_flowable` for a text paragraph |
| `heading(p_text, p_level)` | `t_flowable` for a heading |
| `spacer(p_height)` | `t_flowable` for a vertical gap |
| `h_rule(p_color, p_width)` | `t_flowable` for a horizontal line |
| `page_break` | `t_flowable` for an explicit page break |
| `image(p_image_id, p_width, p_height)` | `t_flowable` for an image |

### `rad_pdf_styles` package — style registry

| Subprogram | Description |
|---|---|
| `load_defaults` | Load built-in styles (idempotent). Call once per session. |
| `define(p_name, p_font_name, p_font_style, p_font_size, ...)` | Define or update a named style. |
| `get(p_name)` | Retrieve a `t_cell_format` by name. |
| `default_scheme` | Return a `t_color_scheme` built from built-in table styles. |

### Error codes (`rad_pdf_types` constants)

| Constant | Code | When raised |
|---|---|---|
| `c_err_validation` | -20400 | Invalid arguments, bad filename/URL |
| `c_err_io` | -20500 | File or network I/O failure |
| `c_err_rendering` | -20600 | Rendering failure (e.g., bad stream) |
| `c_err_font` | -20700 | Font load or encoding error |
| `c_err_image` | -20710 | Image load or format error |
| `c_err_layout` | -20750 | Layout engine error |
| `c_err_handle` | -20760 | Invalid document handle |

---

## Known Limitations

1. **CLOB paragraphs > 32767 chars** are silently truncated by `DBMS_LOB.SUBSTR`.  
   For very long bodies, split the text into multiple `rad_pdf.write` calls.

2. **Streaming table mode** (`t_table_def.streaming = TRUE`) cannot supply `#PAGE_COUNT#`
   in header/footer procs during the measure pass (page count is unknown).  
   Use the default non-streaming mode for accurate page-count tokens.

3. **Standard fonts** (Helvetica, Times, Courier) are not embedded — the viewer must have them.  
   For full portability, embed a TTF font via `rad_pdf_fonts.load_ttf(..., p_embed => TRUE)`.

4. **GIF animation** — only the first frame is used.

5. **Right-to-left text** (Arabic, Hebrew) is not supported; glyphs are placed left-to-right.

---

## Examples Index

### Core examples

| File | Description |
|---|---|
| [sample01.sql](sample01.sql) | Minimal: `new_document` → `write` → `finalize` |
| [sample02.sql](sample02.sql) | Styled report: headings, body text, spacer, `h_rule`, custom style |
| [sample03.sql](sample03.sql) | Canvas-only: text, lines, rectangles, polygon at absolute positions |
| [sample04.sql](sample04.sql) | Table report: `query2table` with column defs and custom color scheme |
| [sample05.sql](sample05.sql) | Full report: page template (header/footer), metadata, table, `save` |
| [sample06.sql](sample06.sql) | Grouped report: `refcursor2table` with `break_field` (group separators) |
| [sample07.sql](sample07.sql) | Label sheet: `query2labels` with `t_label_def` (peel-off label grid) |
| [sample08.sql](sample08.sql) | Wide table in landscape orientation (`set_page_orientation`) |
| [sample09.sql](sample09.sql) | Image embedding: load from directory / BLOB / HTTPS URL |

### Oracle APEX examples

See **[apex/README.md](apex/README.md)** for APEX-specific installation and streaming patterns.

| File | Description |
|---|---|
| [apex/apex_sample01.sql](apex/apex_sample01.sql) | Minimal page process: generate PDF and stream to browser |
| [apex/apex_sample02.sql](apex/apex_sample02.sql) | Filtered report using APEX page items as bind variables |
| [apex/apex_sample03.sql](apex/apex_sample03.sql) | Store PDF in a table; stream from a separate download page |
| [apex/apex_sample04.sql](apex/apex_sample04.sql) | Full report with dynamic header, footer, and `V()` session info |

