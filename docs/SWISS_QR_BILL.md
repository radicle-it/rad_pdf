# Swiss QR-bill

`rad_pdf_swiss` implements the payment part and receipt from SIX Swiss
Implementation Guidelines **2.4**, plus Style Guide **1.1**. The invoice body
(items, VAT, totals and commercial terms) continues to use ordinary RAD_PDF
flowables or templates. This module does not define a Swiss e-invoice interchange
format and does not send payments.

Sources:
[IG 2.4](https://www.six-group.com/dam/download/banking-services/standardization/qr-bill/ig-qr-bill-v2.4-en.pdf),
[Style Guide](https://www.six-group.com/dam/download/banking-services/standardization/qr-bill/style-guide-qr-bill-en.pdf),
[SIX download centre](https://www.six-group.com/en/products-services/banking-services/payment-standardization/downloads-faq/download-center.html).
IG 2.4 is valid from 14 November 2026. This implementation deliberately uses its
rules, including CHF-only QRR, regardless of the current date.

## Input contract

The canonical internal model is `rad_pdf_swiss.t_bill`. Services can send a CLOB
containing JSON matching [the versioned schema](schemas/swiss-qr-bill-v1.json).
The schema covers syntax; `validate`/`payload` additionally enforce financial
cross-field rules and checksums. A complete
[JSON example](schemas/swiss-qr-bill-example.json) and
[runnable JSON/CHF example](sample22.sql) use published sample data. Additional
examples cover [typed EUR/SCOR with a separate payment page](sample23.sql) and
[open amount/debtor fields](sample24.sql). Their matching APEX processes and demo
catalog integration are described in the [APEX guide](apex/README.md#swiss-qr-bill-examples).

| Input | Meaning |
|---|---|
| `schema_version` | JSON contract version, numeric `1`; not the QR version |
| `account` | Unformatted, uppercase CH/LI IBAN or QR-IBAN, 21 characters |
| `creditor` | Structured account-holder address; mandatory |
| `amount` | JSON number, 0.01–999999999.99, at most two decimals; omit/null for handwritten amount |
| `currency` | `CHF` (default) or `EUR` |
| `debtor` | Structured address; omit/null for handwritten payer details |
| `reference_type` | `NON` (default), `QRR` or `SCOR` |
| `reference` | Empty for NON; 27 digits/checksum for QRR; RF/ISO 11649 for SCOR |
| `message` | Payment message; printed on payment part, never on receipt |
| `billing_information` | Opaque booking syntax starting `//` + two-character identifier; QR line 32 |
| `alternatives` | Up to two opaque strings, each at most 100 characters; QR lines 33/34 |

Addresses have `name` (70), `street` (70, optional), `building_no` (16,
optional), `postal_code` (16), `town` (35) and ISO alpha-2 `country`.
The numbers in parentheses are maximum character counts. Combined/unstructured
addresses and ultimate-creditor data are intentionally absent from this contract:
IG 2.4 requires structured addresses and prohibits filling the ultimate creditor.
The latter's seven empty payload lines are nevertheless serialized.

All address values and optional text use the character repertoire of IG 2.4
§4.1.1: basic Latin, Latin-1 Supplement, Latin Extended A, U+0218–021B and euro.
Newlines, tabs, control characters and other Unicode ranges are rejected inside
fields. `message` + `billing_information` together must not exceed 140 characters.
Country membership, amount precision, IBAN mod 97, QRR recursive mod 10 and
SCOR mod 97 are checked without network calls or database tables.

A QR-IBAN (IID 30000–31999) must use QRR; QRR must use CHF. Ordinary IBANs must
use NON or SCOR. `qr_reference(base)` generates a padded 27-digit QR reference;
`creditor_reference(base)` generates an RF reference. Validation never silently
repairs a supplied checksum or normalizes an incorrectly formatted account.

The JSON parser rejects unknown properties, duplicate keys, incorrect JSON types
and unsupported contract versions. `to_json` returns a caller-owned temporary CLOB.
`payload` returns the 31 mandatory lines plus used additional lines, separated by
LF without BOM or final LF. Empty positional placeholders are preserved. Both the
997-character limit and the version-25-M UTF-8 byte capacity are enforced.

## Application integration

```sql
l_bill := rad_pdf_swiss.from_json(l_request_clob);
l_doc := rad_pdf.new_document;
rad_pdf.swiss_qr_bill(l_doc,l_bill,l_options);
rad_pdf.render_template(l_doc,l_invoice_template,l_binds);
l_pdf := rad_pdf.finalize(l_doc);
```

A service package following ExpreSQL conventions can map its TAPI/data records
into `t_bill` or pass JSON through this API. Within PL/SQL, prefer the typed
record to avoid unnecessary JSON serialization and parsing. XML sources (for example a payment
instruction) require an explicit service-side mapping; arbitrary XML, pain.001 or
ERP invoice JSON are not interpreted as if they were this contract.

`rad_pdf.swiss_qr_bill` registers one payment section per document, using the typed
record or a JSON CLOB overload. Call it before rendering or drawing canvas content.
Registering a second section raises `-20830`. It has no SQL or remote dependency;
all state belongs to the existing document layout and is released on close.

## Layout and print options

`rad_pdf_swiss.t_options` supports:

- `language`: `IT` (default), `DE`, `FR`, `EN`, `RM`; official Annex C headings.
- `placement`: `INTEGRATED` (default) or `SEPARATE`.
- `font_family`: Helvetica by default. For other approved faces, supply both
  explicit font indices below; loading a TrueType file does not register family/style aliases.
- `font_regular`, `font_bold`: explicit indices from loading/preloading approved
  TrueType faces. Supply both, for example embedded Arial regular/bold CID fonts.
- `print_billing_information`: false by default; when true also print the booking
  information under the payment message. It is always encoded when supplied.

INTEGRATED reserves a **115 mm bottom margin on every page** for deterministic
single-pass pagination, then draws the payment part on the final page only.
The earlier pages retain the reserved blank area. SEPARATE uses the full invoice
frame and appends a payment page; an otherwise empty document uses its first page.
This mode avoids sacrificing invoice space to a last-page reserve.

The fixed payment part/receipt is 210 × 105 mm at the lower page edge. A 5 mm band
above it holds the translated separation notice; invoice content stays above
115 mm. Page width must be 210 mm, normally portrait A4. Existing headers/footers
must stay above the reserved area. Canvas-only callers remain responsible for their
coordinates; SEPARATE appends a fresh page after drawn canvas content. Automatic reservation
controls flowables and tables, not arbitrary already-drawn PDF operators.
The payment painter owns and clears the lower 110 mm on its target page.

The symbol itself is **46 × 46 mm**, surrounded by 5 mm quiet space; encoding is
binary UTF-8 without ECI/BOM, level M, automatically selected smallest version,
maximum version 25. It reuses the existing vector QR encoder. The central 7 mm
cross follows the geometry of SIX's published SVG; no raster assets or additional
runtime package is required.

Print uses black approved sans-serif faces, 11 pt bold titles, payment values
10–8 pt with headings 2 pt smaller, and receipt values/headings 8/6 pt. Text plans
are checked before emitting drawing operators. The receipt omits street/building
as permitted by IG 2.4; names, country and town remain. IBAN and references use the
specified grouping. The receipt excludes additional information and alternatives.
Unspecified payer/amount produce the required corner-mark fields on both parts.
Alternative-procedure names are bold, 7 pt; no payment information is silently
truncated. If required text cannot fit, generation fails with an actionable error.
Optional billing and alternative syntax is transported as supplied, not interpreted
or validated against an external provider's specification.

Helvetica's WinAnsi encoding cannot represent the entire Swiss character set.
If a chosen font cannot print a supplied character, generation raises a font error
rather than replacing it. Load both approved faces with `p_encoding => 'CID'` and
`p_embed => TRUE`, then pass their indices. This also supports PDF/A generation;
font embedding and PDF/A validation retain the normal RAD_PDF requirements.

## Verification

Run after the full installer:

```sql
@tests/phase21_swiss_qr_bill.sql
@docs/sample22.sql
@docs/sample23.sql
@docs/sample24.sql
```

The development checks passed 692 assertions: 614 existing regression/stress
assertions and 78 Swiss checks. The tests cover known checksums, invalid combinations, positional payload lines,
strict JSON/round trips, five languages, both placements, font coverage failures,
blank fields and a multipage table. Independent QR decoding and PDF text/coordinate
checks can be run with `tests/validate_swiss_pdf.py` on exported fixtures:

```sql
spool /tmp/swiss-export.log
@tests/export_swiss_fixtures.sql
spool off
```

```sh
python tests/validate_swiss_pdf.py /tmp/swiss-export.log /tmp/swiss-checked
```

The independent checker needs test-only `zxing-cpp`, Pillow and Poppler. It checks
exact payload bytes from the rendered QR, 46 mm symbol size/position, quiet zones,
page placement and all 120 invoice rows. It also validates PDF xref offsets and
stream boundaries. Extended Latin was additionally checked using embedded Arial
CID regular/bold faces; that font asset is not distributed with this repository.

SIX's QR validation portal and the payee's bank remain the appropriate acceptance
checks before production use. The PDF generator cannot enforce printer scaling,
white/perforated paper requirements, account ownership or bank master membership.
Print at 100% size; the software tests do not constitute SIX/bank certification.
