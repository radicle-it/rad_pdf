# RAD_PDF Template Engine — APEX Developer Guide

The template engine (`rad_pdf_template`) lets you describe the content and layout
of a PDF document as a CLOB of lightweight XML-like tags and `#PLACEHOLDER#` tokens.
Instead of calling dozens of low-level canvas or layout primitives you write something
very close to HTML, pass in a bind array populated from APEX session state, and get a
finished PDF back in a single `render()` call.

---

## Contents

1. [Prerequisites](#prerequisites)
2. [How the pipeline works](#how-the-pipeline-works)
3. [Tag reference](#tag-reference)
4. [Bind substitution](#bind-substitution)
5. [Conditional blocks](#conditional-blocks)
6. [Types and options](#types-and-options)
7. [Examples](#examples)
8. [Error codes](#error-codes)
9. [Common patterns](#common-patterns)

---

## Prerequisites

| Requirement | Notes |
|---|---|
| RAD_PDF installed | All 9 phases (`@src/install.sql`) |
| `rad_pdf_styles.load_defaults` | Call once per session — put it in an **Application Process** that runs *On New Session* |
| EMP / DEPT tables | Oracle sample schema; must be accessible to the parsing schema |
| `register_columns` (for `<table>`) | Call once per session in the same On New Session process |

```sql
-- Suggested Application Process: "RAD_PDF Session Init"
-- Condition: Run On New Session
BEGIN
  rad_pdf_styles.load_defaults;

  -- Register column sets that will be used by <table> tags.
  -- Only needed when templates contain <table> tags.
  DECLARE
    l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  BEGIN
    l_cols.EXTEND(5);
    l_cols(1).label := 'No';      l_cols(1).width := 42;
    l_cols(1).header_fmt.align_h := 'C'; l_cols(1).data_fmt.align_h := 'C';
    l_cols(2).label := 'Name';    l_cols(2).width := 110;
    l_cols(3).label := 'Job';     l_cols(3).width := 90;
    l_cols(4).label := 'Hired';   l_cols(4).width := 80;
    l_cols(4).header_fmt.align_h := 'C'; l_cols(4).data_fmt.align_h := 'C';
    l_cols(5).label := 'Salary';  l_cols(5).width := 64;
    l_cols(5).header_fmt.align_h := 'R'; l_cols(5).data_fmt.align_h := 'R';
    l_cols(5).data_fmt.num_format := '999,990.00';
    rad_pdf_template.register_columns('EMP_ROSTER', l_cols);
  END;
END;
```

---

## How the pipeline works

Every `render()` call with binds goes through four phases in this order:

```
Input CLOB
   │
   ▼ Phase 0 — Case normalisation
   │  <IF …> / </IF>  →  <if …> / </if>   (REPLACE on CLOB)
   │
   ▼ Phase 1 — Conditional evaluation
   │  <if bind="KEY">…</if>  →  content kept or removed
   │  Evaluated BEFORE bind substitution, so suppressed blocks
   │  never cause NULL-bind errors.
   │
   ▼ Phase 2 — Bind substitution
   │  #KEY#  →  escaped bind value
   │  ##     →  literal #
   │
   ▼ Phase 3 — Parse and render
      CLOB scanner produces flowables (headings, paragraphs, tables …)
      passed to the layout engine.
```

---

## Tag reference

### Block tags (document-level structure)

| Tag | Attributes | Notes |
|---|---|---|
| `<p>…</p>` | `style="name"` (optional) | Paragraph; defaults to `body` style |
| `<h1>…</h1>` … `<h6>…</h6>` | — | Headings; support inline markup |
| `<ul>…</ul>` | `style="name"` | Unordered list; items in `<li>…</li>` |
| `<ol>…</ol>` | `style="name"` | Ordered (numbered) list |
| `<spacer/>` | `height="Xpt"` | Vertical gap (default 12 pt) |
| `<hr/>` | `color="RRGGBB"` `width="N"` | Horizontal rule |
| `<pagebreak/>` | — | Force a new page |
| `<img/>` | `id="N"` `width="Xmm"` `height="Ymm"` | Inline image (preloaded with `rad_pdf_images`) |
| `<table/>` | `columns="NAME"` `query="SQL"` `allow_query="true"` `row_height` `max_rows` `header_bg` `alt_bg` `border_color` | Data table from a SQL query |

Block tag names are **case-insensitive** (`<P>`, `<H1>`, `<Ul>` all work).

### Inline tags (inside `<p>`, `<li>`, and `<h1>`–`<h6>`)

| Tag | Notes |
|---|---|
| `<b>…</b>` | Bold run |
| `<i>…</i>` | Italic run |
| `<br/>` | Forced line break (same-paragraph) |
| `<color rgb="RRGGBB">…</color>` | Custom ink colour; single-level nesting |
| `<font size="Xpt">…</font>` | Custom font size; any unit (pt, mm, cm, in) |

Inline tag names are **case-insensitive**.

---

## Bind substitution

```
#KEY#   →   value of bind entry whose key = 'KEY' (case-insensitive)
##      →   literal '#' character
```

Bind values are **auto-escaped** by default: `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`.
This makes user-supplied text (APEX page items) safe without any extra call.

To bypass escaping (e.g. the value is already HTML-entity-encoded, or it intentionally
contains template markup), set `raw = TRUE` on the `t_bind_entry`.

> **DEPRECATED**: `rad_pdf_template.escape_value()`.
> Calling it and then keeping `raw=FALSE` (default) double-encodes:
> `&` → `&amp;` → `&amp;amp;`.
> Remove all calls to `escape_value()` and rely on automatic escaping.

---

## Conditional blocks

```xml
<if bind="KEY">
  ... any block or inline content ...
</if>
```

The block is **included** when the bind value for `KEY` is non-NULL and non-empty.
The block is **removed** when the key is absent from the array or its value is NULL.

Because conditionals are evaluated **before** bind substitution, tokens inside a
suppressed block never reach `apply_binds` and never trigger the NULL-bind error.

```sql
-- Good: NOTES is absent → <if> block dropped → #NOTES# never processed
l_binds(1).key := 'TITLE'; l_binds(1).value := 'Q1 Report';
-- l_binds does not contain NOTES at all

rad_pdf_template.render(l_doc,
  '<h1>#TITLE#</h1>'                          ||
  '<if bind="NOTES"><p>#NOTES#</p></if>'      ||
  '<p>Generated: #TODAY#</p>',
  l_binds);
```

`<if>` and `</if>` are case-insensitive (Phase 0 normalises them).
**Nested `<if>` blocks are not supported** — the first `</if>` closes the block.

---

## Types and options

### `t_bind_entry`

```sql
TYPE t_bind_entry IS RECORD (
  key   VARCHAR2(200),     -- bind token name (case-insensitive)
  value VARCHAR2(4000),    -- substitution value
  raw   BOOLEAN := FALSE   -- FALSE = auto-escape; TRUE = verbatim
);
TYPE t_bind_array IS TABLE OF t_bind_entry INDEX BY BINARY_INTEGER;
```

### `t_template_options`

```sql
TYPE t_template_options IS RECORD (
  default_font_name   VARCHAR2(100)  := NULL,   -- e.g. 'Arial' (overrides body style)
  default_font_style  t_font_style   := NULL,   -- 'N','B','I','BI'
  default_font_size   NUMBER         := NULL,   -- in pt; e.g. 11
  default_style       VARCHAR2(100)  := 'body', -- base style for <p> without style=""
  strict_tags         BOOLEAN        := TRUE,   -- TRUE = error on unknown tags
  allow_queries       BOOLEAN        := FALSE   -- must be TRUE to execute <table> queries
);
```

All fields default to safe, conservative values.  Passing an uninitialised record is
always safe.  Pass `NULL` (no record) to use all defaults.

---

## Examples

| File | Feature demonstrated |
|---|---|
| [apex_template_01.sql](apex_template_01.sql) | Document structure: `<h1>`–`<h6>`, `<p>`, `<spacer>`, `<hr>` |
| [apex_template_02.sql](apex_template_02.sql) | Bind substitution: employee card from `P1_EMPNO` |
| [apex_template_03.sql](apex_template_03.sql) | Inline formatting: `<b>`, `<i>` inside paragraphs |
| [apex_template_04.sql](apex_template_04.sql) | Inline colour and font size: `<color>`, `<font size>` |
| [apex_template_05.sql](apex_template_05.sql) | Forced line breaks: `<br/>` in address / note blocks |
| [apex_template_06.sql](apex_template_06.sql) | Conditional blocks: `<if bind="…">` with APEX page items |
| [apex_template_07.sql](apex_template_07.sql) | Lists: `<ul>`, `<ol>`, `<li>` with inline markup |
| [apex_template_08.sql](apex_template_08.sql) | Data table: `<table columns="…" query="…">` |
| [apex_template_09.sql](apex_template_09.sql) | Page break: two-page report with `<pagebreak/>` |
| [apex_template_10.sql](apex_template_10.sql) | Inline markup in headings: `<b>`, `<color>` inside `<h1>`–`<h6>` |
| [apex_template_11.sql](apex_template_11.sql) | Multi-section: three `render()` calls on the same document |
| [apex_template_12.sql](apex_template_12.sql) | Custom default font via `t_template_options` |
| [apex_template_13.sql](apex_template_13.sql) | DB-driven templates: load and render from a database table |
| [apex_template_14.sql](apex_template_14.sql) | Complete department report (all features combined) |

---

## Error codes

| Code | Constant | Raised when |
|---|---|---|
| `-20810` | `c_err_template` | Unclosed tag; `<if>` missing `bind` attribute; `</if>` not found; `<p>` > 32767 chars with inline markup |
| `-20811` | — | Unknown block tag (only when `strict_tags = TRUE`) |
| `-20813` | — | `<table>` missing `columns` or `query` attribute |
| `-20814` | — | `<table>` column set not registered via `register_columns` |
| `-20815` | — | `<table>` query blocked — error message names which opt-in is missing (tag or options) |
| `-20816` | — | `<img>` missing `id` attribute |
| `-20817` | — | Non-numeric value in a numeric attribute (`height`, `width`, `max_rows`) |

---

## Common patterns

### Streaming the PDF to the browser

```sql
-- Always the last block of the page process
OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
HTP.P('Content-Disposition: attachment; filename="report.pdf"');
OWA_UTIL.HTTP_HEADER_CLOSE;
WPG_DOCLOAD.DOWNLOAD_FILE(l_pdf);
DBMS_LOB.FREETEMPORARY(l_pdf);
APEX_APPLICATION.STOP_APEX_ENGINE;
```

Place the page process at **On Load — Before Header** so it runs before APEX
has emitted any HTML.

### Exception handler pattern

```sql
EXCEPTION
  WHEN APEX_APPLICATION.E_STOP_APEX_ENGINE THEN RAISE;
  WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
```

Always re-raise `E_STOP_APEX_ENGINE` — it is the mechanism APEX uses internally
after `stop_apex_engine` and must propagate unchanged.

### NULL-safe bind values

```sql
-- Use NVL so a missing APEX item does not trigger the NULL-bind error
l_binds(3).key   := 'SAL_FORMATTED';
l_binds(3).value := NVL(TO_CHAR(:P1_SAL, '999,990.00'), '—');
```

Or use `<if bind="SAL">` to suppress the entire section when the value is absent.

### Inlining numeric values safely in `<table query>`

```sql
-- #DEPTNO# is replaced verbatim in the SQL before execution.
-- Validate it as numeric before placing it in a bind to prevent injection.
l_binds(2).key   := 'DEPTNO';
l_binds(2).value := TO_CHAR(TO_NUMBER(:P1_DEPTNO));  -- TO_NUMBER validates

-- Template:
-- <table columns="EMP_ROSTER"
--        query="SELECT empno, ename, job, TO_CHAR(hiredate,'DD-Mon-YYYY'), sal
--                 FROM emp WHERE deptno = #DEPTNO# ORDER BY ename"
--        allow_query="true"/>
```

### Multiple render() calls for a multi-section document

```sql
-- Each render() appends to the same document — no new document needed.
rad_pdf_template.render(l_doc, l_header_tmpl, l_header_binds);
rad_pdf_template.render(l_doc, '<pagebreak/>');          -- no binds needed
rad_pdf_template.render(l_doc, l_body_tmpl,   l_body_binds,   l_opts);
rad_pdf_template.render(l_doc, l_footer_tmpl, l_footer_binds);
l_pdf := rad_pdf.finalize(l_doc);
```
