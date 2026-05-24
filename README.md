# RAD_PDF

Native PL/SQL library for generating PDF documents from Oracle Database 19c+.  
No Java, no external tools, no OS dependencies.

**Author:** Roberto Capancioni - [Radicle S.r.l.](https://radicle.it)  
**Based on:** [AS_PDF](https://github.com/antonscheffer/as_pdf) by Anton Scheffer

---

## What it does

RAD_PDF generates PDF files entirely inside Oracle Database using PL/SQL.  
You write SQL and PL/SQL; RAD_PDF produces a valid PDF BLOB - no Java, no file system, no middle tier required.

```sql
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.heading(l_doc, 'Quarterly Report', 1);
  rad_pdf.write  (l_doc, 'Revenue increased 18% year-over-year.');
  rad_pdf.query2table(l_doc,
    'SELECT dept_name, headcount, budget FROM departments ORDER BY dept_name',
    l_columns);
  l_pdf := rad_pdf.finalize(l_doc);   -- returns a BLOB; caller owns it
  -- store in a table, return via bind variable, write to a directory, etc.
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
```

---

## Installation

**Requirements:** Oracle Database 19c or later. A schema with `CREATE PROCEDURE` privilege.

```sql
-- 1. Connect to Oracle as the target schema owner (SQL*Plus or SQL Developer)

-- 2. Set the working directory to src/ and run the installer
@install.sql

-- 3. Verify (optional but recommended)
@../tests/phase9_integration.sql
-- All lines should read PASS.
```

> **SQL Developer users:** use *File → Open* to open `src/install.sql`, then run it with F5
> while connected as the schema owner.

---

## Features

- **Layout engine** - automatic text wrap, page breaks, headings h1–h6, paragraphs, spacers, horizontal rules
- **Tables** - `query2table` / `refcursor2table`; column widths, alignment, color schemes, break fields, label grids
- **Standard PDF fonts** - Helvetica, Times, Courier (no embedding needed)
- **TrueType fonts** - load from BLOB, Oracle Directory, or HTTPS URL; embed and compress
- **Images** - JPEG, PNG, GIF; SHA-256 session cache; load from BLOB, directory, or HTTPS URL
- **Page templates** - header/footer PL/SQL blocks executed on every page; `#PAGE_NR#` / `#PAGE_COUNT#` tokens
- **Styles** - named, session-scoped style registry with built-in heading and table styles
- **Canvas API** - absolute positioning, lines, rectangles, polygons, rotated text for advanced layouts
- **Document metadata** - title, author, subject, keywords in PDF Info dictionary
- **AUTHID CURRENT_USER** - runs with the caller's privileges; safe in shared schemas

---

## Documentation

Full user guide, API reference, and examples: **[docs/README.md](docs/README.md)**

Runnable examples:

| File | Description |
|---|---|
| [docs/sample01.sql](docs/sample01.sql) | Minimal: new_document → write → finalize |
| [docs/sample02.sql](docs/sample02.sql) | Styled report with headings, spacers, and a custom style |
| [docs/sample03.sql](docs/sample03.sql) | Canvas-only: text, lines, rectangles, polygon |
| [docs/sample04.sql](docs/sample04.sql) | Table report with column definitions and color scheme |
| [docs/sample05.sql](docs/sample05.sql) | Full report: page template (header/footer), table, save to directory |
| [docs/sample06.sql](docs/sample06.sql) | Grouped report: refcursor2table with break_field |
| [docs/sample07.sql](docs/sample07.sql) | Label sheet: query2labels with t_label_def |
| [docs/sample08.sql](docs/sample08.sql) | Wide table in landscape orientation |
| [docs/sample09.sql](docs/sample09.sql) | Image embedding from directory / BLOB / HTTPS URL |
| [docs/apex/](docs/apex/) | Oracle APEX integration: 4 examples + setup guide |

---

## Repository layout

```
src/     PL/SQL packages + install scripts (start here)
tests/   Acceptance test suite (one file per phase)
docs/    User guide (README.md) and runnable examples
spec/    Architecture and refactoring specification documents
```

---

## Credits

RAD_PDF is a complete rewrite of [AS_PDF](https://github.com/antonscheffer/as_pdf),
originally created by **Anton Scheffer** (Oracle APEX team).
The PDF generation algorithms and font-width tables from AS_PDF are the foundation of this work.

| Role | Name |
|---|---|
| Original author | Anton Scheffer |
| AS_PDF contributors | Valerio Rossetti, Andreas Weiden, Lee Lindley, Javier Meza |
| RAD_PDF rewrite | Roberto Capancioni - Radicle S.r.l. |

---

## License

RAD_PDF is a derivative work of AS_PDF, which was published by Anton Scheffer without a formal
open-source license. This rewrite is distributed under the same informal terms: free to use and
adapt, with attribution to both Anton Scheffer and Roberto Capancioni / Radicle S.r.l.
