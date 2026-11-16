-- Swiss QR-bill IG 2.4: checksums, full payload, strict JSON and PDF integration.
SET DEFINE OFF
SET SQLBLANKLINES ON
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
DECLARE
  l_bill rad_pdf_swiss.t_bill;
  l_good rad_pdf_swiss.t_bill;
  l_copy rad_pdf_swiss.t_bill;
  l_options rad_pdf_swiss.t_options;
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_before BLOB;
  l_page BLOB;
  l_json CLOB;
  l_payload VARCHAR2(4000);
  l_json_text VARCHAR2(32767);
  l_text VARCHAR2(32767);
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  l_pass PLS_INTEGER := 0;
  l_n NUMBER;
  PROCEDURE ok(p_condition BOOLEAN,p_label VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_condition,FALSE) THEN RAISE_APPLICATION_ERROR(-20999,p_label); END IF;
    l_pass := l_pass+1; DBMS_OUTPUT.PUT_LINE('PASS  '||p_label);
  END;
  PROCEDURE bad(p_label VARCHAR2) IS
  BEGIN
    BEGIN
      l_payload := rad_pdf_swiss.payload(l_bill);
      ok(FALSE,p_label);
    EXCEPTION WHEN OTHERS THEN ok(SQLCODE=rad_pdf_swiss.c_err_swiss,p_label); END;
    l_bill := l_good;
  END;
  PROCEDURE bad_json(p_value VARCHAR2,p_label VARCHAR2) IS
  BEGIN
    BEGIN l_copy := rad_pdf_swiss.from_json(TO_CLOB(p_value)); ok(FALSE,p_label);
    EXCEPTION WHEN OTHERS THEN ok(SQLCODE=rad_pdf_swiss.c_err_swiss,p_label); END;
  END;
  PROCEDURE free_pdf IS BEGIN DBMS_LOB.FREETEMPORARY(l_pdf); END;
BEGIN
  rad_pdf_styles.load_defaults;
  l_bill.account := 'CH4431999123000889012';
  l_bill.creditor.name := 'Max Muster & Söhne'; l_bill.creditor.street := 'Musterstrasse';
  l_bill.creditor.building_no := '123'; l_bill.creditor.postal_code := '8000';
  l_bill.creditor.town := 'Seldwyla'; l_bill.creditor.country := 'CH';
  l_bill.amount := 2500.25; l_bill.currency := 'CHF';
  l_bill.debtor.name := 'Simon Muster'; l_bill.debtor.street := 'Musterstrasse';
  l_bill.debtor.building_no := '1'; l_bill.debtor.postal_code := '8000';
  l_bill.debtor.town := 'Seldwyla'; l_bill.debtor.country := 'CH';
  l_bill.reference_type := 'QRR'; l_bill.reference := '210000000003139471430009017';
  l_bill.message := 'Invoice 1024';
  l_good := l_bill;
  ok(rad_pdf_swiss.qr_reference('21000000000313947143000901')=l_bill.reference,'known recursive modulo-10 reference');
  ok(rad_pdf_swiss.creditor_reference('539007547034')='RF18539007547034','known ISO 11649 reference');
  ok(LENGTH(rad_pdf_swiss.qr_reference('1'))=27,'QR reference generation pads to 27 digits');
  l_payload := rad_pdf_swiss.payload(l_bill);
  ok(SUBSTR(l_payload,1,11)='SPC'||CHR(10)||'0200'||CHR(10)||'1'||CHR(10),'SPC header uses version 0200');
  ok(REGEXP_COUNT(l_payload,CHR(10))=30,'mandatory payload contains 31 lines');
  ok(SUBSTR(l_payload,-3)='EPD','unused additional lines and final separator omitted');
  ok(INSTR(l_payload,CHR(13))=0 AND INSTR(l_payload,CHR(10)||'2500.25'||CHR(10)||'CHF')>0,'LF separators and invariant decimal amount');
  ok(INSTR(l_payload,'CH'||CHR(10)||RPAD(CHR(10),7,CHR(10))||'2500.25')>0,'ultimate creditor occupies seven empty lines');
  l_json := rad_pdf_swiss.to_json(l_bill);
  l_copy := rad_pdf_swiss.from_json(l_json);
  ok(rad_pdf_swiss.payload(l_copy)=l_payload,'JSON round-trip preserves all payment data');
  l_json_text := DBMS_LOB.SUBSTR(l_json,32767,1);
  bad_json(REGEXP_REPLACE(l_json_text,'"debtor":\{[^}]*\}','"debtor":{}'),'explicit empty debtor JSON object rejected');
  DBMS_LOB.FREETEMPORARY(l_json);
  l_bill.billing_information := '//S1/10/1024';
  l_bill.alternative_1 := 'eBill/B/41010560425610107';
  l_bill.alternative_2 := 'Test/123';
  l_payload := rad_pdf_swiss.payload(l_bill);
  ok(REGEXP_COUNT(l_payload,CHR(10))=33,'billing and two alternatives occupy lines 32 to 34');
  l_json := rad_pdf_swiss.to_json(l_bill); l_copy := rad_pdf_swiss.from_json(l_json);
  ok(rad_pdf_swiss.payload(l_copy)=l_payload,'JSON round-trip includes billing and both alternative procedures');
  DBMS_LOB.FREETEMPORARY(l_json);
  l_bill.billing_information := NULL;
  l_payload := rad_pdf_swiss.payload(l_bill);
  ok(INSTR(l_payload,'EPD'||CHR(10)||CHR(10)||'eBill/')>0,'empty billing line retained before alternatives');
  l_bill := l_good;
  l_bill.account := 'CH4431999123000889013'; bad('wrong IBAN checksum rejected');
  l_bill.account := 'DE89370400440532013000'; bad('non CH/LI account rejected');
  l_bill.account := 'CH44 3199 9123 0008 8901 2'; bad('formatted IBAN rejected rather than silently changed');
  l_bill.reference := '210000000003139471430009018'; bad('wrong QRR check digit rejected');
  l_bill.reference := NULL; bad('QRR requires reference');
  l_bill.reference_type := 'NON'; l_bill.reference := NULL; bad('QR-IBAN cannot use NON');
  l_bill.account := 'CH5800791123000889012'; bad('ordinary IBAN cannot use QRR');
  l_bill.currency := 'EUR'; bad('IG 2.4 rejects EUR with QRR');
  l_bill.currency := 'USD'; bad('unsupported currency rejected');
  l_bill.currency := NULL; bad('null currency rejected');
  l_bill.reference_type := NULL; bad('null reference type rejected');
  l_bill.amount := 0; bad('zero amount rejected');
  l_bill.amount := -1; bad('negative amount rejected');
  l_bill.amount := 1.001; bad('fractional cents rejected');
  l_bill.amount := 1000000000; bad('amount above maximum rejected');
  l_bill.amount := 999999999.99;
  ok(INSTR(rad_pdf_swiss.payload(l_bill),CHR(10)||'999999999.99'||CHR(10))>0,'maximum amount serialized without grouping');
  l_bill := l_good;
  l_bill.creditor.name := NULL; bad('creditor name required');
  l_bill.creditor.name := RPAD('A',71,'A'); bad('creditor name maximum is 70 characters');
  l_bill.creditor.postal_code := NULL; bad('structured postal code required');
  l_bill.creditor.country := 'ZZ'; bad('invalid ISO country rejected');
  l_bill.debtor.town := NULL; bad('partial debtor group rejected');
  l_bill.message := 'injected'||CHR(10)||'EPD'; bad('payload line injection rejected');
  l_bill.message := UNISTR('\0391'); bad('Greek excluded by Swiss QR character set');
  l_bill.message := UNISTR('\D83D\DE00'); bad('supplementary Unicode rejected with Swiss validation error');
  l_bill.message := RPAD('a',141,'a'); bad('message maximum length enforced');
  l_bill.message := RPAD('a',100,'a'); l_bill.billing_information := '//S1/'||RPAD('x',40,'x'); bad('combined additional information maximum enforced');
  l_bill.billing_information := 'invalid'; bad('billing syntax identifier required');
  l_bill.alternative_2 := 'eBill/123'; bad('second alternative needs first');
  l_bill.alternative_1 := RPAD('x',101,'x'); bad('alternative maximum length enforced');
  l_bill := l_good;
  l_bill.account := 'CH5800791123000889012'; l_bill.currency := 'EUR';
  l_bill.reference_type := 'SCOR'; l_bill.reference := 'RF18539007547034';
  rad_pdf_swiss.validate(l_bill); ok(TRUE,'ordinary IBAN with EUR and SCOR accepted');
  l_bill.reference := 'RF19539007547034'; bad('SCOR checksum validated');
  l_bill.account := 'CH5800791123000889012'; l_bill.reference_type := 'NON'; l_bill.reference := NULL;
  l_bill.amount := NULL; l_bill.debtor := l_copy.debtor;
  l_copy.debtor.name := NULL; l_copy.debtor.street := NULL; l_copy.debtor.building_no := NULL;
  l_copy.debtor.postal_code := NULL; l_copy.debtor.town := NULL; l_copy.debtor.country := NULL;
  l_bill.debtor := l_copy.debtor;
  rad_pdf_swiss.validate(l_bill); ok(TRUE,'open amount and absent debtor accepted');
  l_doc := rad_pdf.new_document;
  rad_pdf.swiss_qr_bill(l_doc,l_bill);
  l_pdf := rad_pdf.finalize(l_doc); ok(DBMS_LOB.GETLENGTH(l_pdf)>1000,'blank amount and debtor render with corner marks'); free_pdf;
  l_bill := l_good;
  l_bill.message := UNISTR('\0100\0153\0218\20AC'); rad_pdf_swiss.validate(l_bill);
  ok(TRUE,'extended Latin, Romanian comma and euro accepted in payload');
  l_doc := rad_pdf.new_document;
  rad_pdf_serial.page_flush(l_doc);
  l_page := rad_pdf_serial.get_page_blob(l_doc,0); l_n := DBMS_LOB.GETLENGTH(l_page);
  BEGIN rad_pdf_swiss.draw(l_doc,l_bill); ok(FALSE,'lossy Helvetica text rejected');
  EXCEPTION WHEN OTHERS THEN ok(SQLCODE=rad_pdf_types.c_err_font,'lossy Helvetica text rejected'); END;
  rad_pdf_serial.page_flush(l_doc);
  ok(DBMS_LOB.GETLENGTH(l_page)=l_n,'font coverage failure emits no PDF operators');
  rad_pdf.close_document(l_doc); l_bill := l_good;
  bad_json('{}','schema version mandatory');
  bad_json('{"schema_version":2}','unsupported schema rejected');
  bad_json('{"schema_version":1,"typo":2}','unknown root property rejected');
  bad_json('{"schema_version":1,"schema_version":1}','duplicate JSON keys rejected');
  bad_json('{"schema_version":1,"amount":"1.00"}','amount JSON type checked');
  bad_json('{"schema_version":1,"creditor":{"typo":1}}','unknown address property rejected');
  bad_json('{"schema_version":1,"alternatives":["a","b","c"]}','at most two JSON alternatives');
  bad_json('{"schema_version":1,"alternatives":[1]}','alternative JSON type checked');
  bad_json('{"schema_version":1,"creditor":"address"}','address must be an object');
  bad_json('{schema_version:1}','nonstandard JSON rejected');
  -- Both modes and all five official correspondence languages.
  FOR mode_nr IN 0..1 LOOP
    l_options.placement := CASE mode_nr WHEN 0 THEN 'INTEGRATED' ELSE 'SEPARATE' END;
    FOR lang IN 1..5 LOOP
      l_options.language := CASE lang WHEN 1 THEN 'IT' WHEN 2 THEN 'DE' WHEN 3 THEN 'FR' WHEN 4 THEN 'EN' ELSE 'RM' END;
      l_doc := rad_pdf.new_document;
      rad_pdf.swiss_qr_bill(l_doc,l_bill,l_options);
      rad_pdf.write(l_doc,'INVOICE_BODY_MARKER');
      l_pdf := rad_pdf.finalize(l_doc);
      ok(DBMS_LOB.GETLENGTH(l_pdf)>1000,'PDF generated: '||l_options.placement||' '||l_options.language); free_pdf;
    END LOOP;
  END LOOP;
  l_options.language := 'EN'; l_options.placement := 'SEPARATE';
  l_doc := rad_pdf.new_document;
  rad_pdf.swiss_qr_bill(l_doc,l_bill,l_options);
  rad_pdf_canvas.write_text(l_doc,'CANVAS_ONLY_BODY',30,700);
  rad_pdf.render_pages(l_doc);
  ok(rad_pdf_serial.page_count(l_doc)=2,'separate payment page appended to canvas-only invoice');
  rad_pdf.close_document(l_doc);
  l_options.placement := 'INTEGRATED';
  l_doc := rad_pdf.new_document(p_compress_pages=>FALSE);
  rad_pdf.swiss_qr_bill(l_doc,l_bill,l_options);
  BEGIN rad_pdf.swiss_qr_bill(l_doc,l_bill); ok(FALSE,'duplicate payment section rejected');
  EXCEPTION WHEN OTHERS THEN ok(SQLCODE=rad_pdf_swiss.c_err_swiss,'duplicate payment section rejected'); END;
  l_cols.EXTEND(1); l_cols(1).label := 'Rows'; l_cols(1).width := 180;
  rad_pdf.query2table(l_doc,'select ''DATA_''||level from dual connect by level<=120',l_cols);
  rad_pdf.render_pages(l_doc);
  ok(rad_pdf_canvas.get_info(l_doc,rad_pdf_types.c_info_margin_bot)>=rad_pdf_units.to_pt(115,'mm')-0.01,'integrated body frame reserves 115 mm');
  l_n := rad_pdf_serial.page_count(l_doc);
  ok(l_n>1,'Swiss invoice paginates table');
  rad_pdf_serial.page_flush(l_doc);
  FOR pg IN 0..l_n-1 LOOP
    l_page := rad_pdf_serial.get_page_blob(l_doc,pg);
    ok((DBMS_LOB.INSTR(l_page,UTL_RAW.CAST_TO_RAW('(Payment part)'))>0)=(pg=l_n-1),'payment part only on last page '||pg);
  END LOOP;
  rad_pdf.close_document(l_doc);
  DBMS_OUTPUT.PUT_LINE('Phase 21: '||l_pass||' assertions passed');
END;
/
