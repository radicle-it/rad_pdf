CREATE OR REPLACE PACKAGE BODY rad_pdf_swiss IS
  TYPE t_attached IS RECORD (bill t_bill, options t_options);
  TYPE t_attached_map IS TABLE OF t_attached INDEX BY PLS_INTEGER;
  g_attached t_attached_map;                     -- the bill of each document (per document: closed by close_doc)
  c_mm CONSTANT NUMBER := 72/25.4;
  c_countries CONSTANT VARCHAR2(1000) :=
    ' AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ'
    ||' CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR'
    ||' GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP'
    ||' KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT'
    ||' MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW'
    ||' SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG'
    ||' UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW ';
  PROCEDURE fail(p_message VARCHAR2) IS
  BEGIN RAISE_APPLICATION_ERROR(c_err_swiss,p_message); END;

  PROCEDURE field(p_value VARCHAR2,p_name VARCHAR2,p_max PLS_INTEGER,p_required BOOLEAN DEFAULT FALSE) IS
    l_cp NUMBER;
  BEGIN
    IF p_required AND TRIM(p_value) IS NULL THEN fail(p_name||' is required'); END IF;
    IF LENGTH(p_value)>p_max THEN fail(p_name||' exceeds '||p_max||' characters'); END IF;
    FOR i IN 1..NVL(LENGTH(p_value),0) LOOP
      l_cp := TO_NUMBER(RAWTOHEX(UTL_I18N.STRING_TO_RAW(SUBSTR(p_value,i,1),'AL16UTF16')),'XXXXXXXX');
      IF NOT (l_cp BETWEEN 32 AND 126 OR l_cp BETWEEN 160 AND 383 OR l_cp BETWEEN 536 AND 539 OR l_cp=8364) THEN
        fail(p_name||' contains a character outside the Swiss QR character set');
      END IF;
    END LOOP;
  END;
  FUNCTION has_address(p_address t_address) RETURN BOOLEAN IS
  BEGIN
    RETURN p_address.name IS NOT NULL OR p_address.street IS NOT NULL OR p_address.building_no IS NOT NULL
      OR p_address.postal_code IS NOT NULL OR p_address.town IS NOT NULL OR p_address.country IS NOT NULL;
  END;
  PROCEDURE address_check(p_address t_address,p_name VARCHAR2) IS
  BEGIN
    field(p_address.name,p_name||'.name',70,TRUE);
    field(p_address.street,p_name||'.street',70);
    field(p_address.building_no,p_name||'.building_no',16);
    field(p_address.postal_code,p_name||'.postal_code',16,TRUE);
    field(p_address.town,p_name||'.town',35,TRUE);
    IF LENGTH(p_address.country)!=2 OR p_address.country IS NULL
       OR INSTR(c_countries,' '||p_address.country||' ')=0 THEN fail(p_name||'.country must be an ISO 3166-1 alpha-2 code'); END IF;
  END;
  FUNCTION mod97(p_value VARCHAR2) RETURN PLS_INTEGER IS
    l_remainder PLS_INTEGER := 0;
    l_code PLS_INTEGER;
    l_c VARCHAR2(1);
  BEGIN
    FOR i IN 1..LENGTH(p_value) LOOP
      l_c := SUBSTR(p_value,i,1);
      IF l_c BETWEEN '0' AND '9' THEN l_code := ASCII(l_c)-48; l_remainder := MOD(l_remainder*10+l_code,97);
      ELSE l_code := ASCII(l_c)-55; l_remainder := MOD(l_remainder*100+l_code,97); END IF;
    END LOOP;
    RETURN l_remainder;
  END;
  FUNCTION qr_reference(p_base IN VARCHAR2) RETURN VARCHAR2 IS
    l_base VARCHAR2(26);
    l_carry PLS_INTEGER := 0;
    c_table CONSTANT VARCHAR2(10) := '0946827135';
  BEGIN
    IF p_base IS NULL OR LENGTH(p_base)>26 OR NOT REGEXP_LIKE(p_base,'^[0-9]+$','c') THEN
      fail('QR reference base must contain 1 to 26 digits');
    END IF;
    l_base := LPAD(p_base,26,'0');
    FOR i IN 1..26 LOOP l_carry := TO_NUMBER(SUBSTR(c_table,MOD(l_carry+TO_NUMBER(SUBSTR(l_base,i,1)),10)+1,1)); END LOOP;
    RETURN l_base||TO_CHAR(MOD(10-l_carry,10),'FM0');
  END;
  FUNCTION creditor_reference(p_base IN VARCHAR2) RETURN VARCHAR2 IS
    l_base VARCHAR2(21);
  BEGIN
    IF p_base IS NULL OR LENGTH(p_base)>21 OR NOT REGEXP_LIKE(p_base,'^[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0-9]+$','c') THEN
      fail('Creditor reference base must contain 1 to 21 alphanumeric characters');
    END IF;
    l_base := UPPER(p_base);
    RETURN 'RF'||TO_CHAR(98-mod97(l_base||'RF00'),'FM00')||l_base;
  END;
  PROCEDURE validate_fields(p_bill IN t_bill) IS
    l_qr BOOLEAN;
  BEGIN
    IF p_bill.account IS NULL OR LENGTH(p_bill.account)!=21
      OR NOT REGEXP_LIKE(p_bill.account,'^(CH|LI)[0-9]{7}[ABCDEFGHIJKLMNOPQRSTUVWXYZ0-9]{12}$','c')
      OR mod97(SUBSTR(p_bill.account,5)||SUBSTR(p_bill.account,1,4))!=1 THEN fail('Invalid CH/LI IBAN checksum or syntax'); END IF;
    l_qr := TO_NUMBER(SUBSTR(p_bill.account,5,5)) BETWEEN 30000 AND 31999;
    address_check(p_bill.creditor,'creditor');
    IF has_address(p_bill.debtor) THEN address_check(p_bill.debtor,'debtor'); END IF;
    IF p_bill.currency IS NULL OR p_bill.currency NOT IN ('CHF','EUR') THEN fail('currency must be CHF or EUR'); END IF;
    IF p_bill.amount IS NOT NULL AND (p_bill.amount<0.01 OR p_bill.amount>999999999.99 OR p_bill.amount!=ROUND(p_bill.amount,2)) THEN
      fail('amount must have at most two decimals and be between 0.01 and 999999999.99');
    END IF;
    IF p_bill.reference_type IS NULL OR p_bill.reference_type NOT IN ('QRR','SCOR','NON') THEN fail('reference_type must be QRR, SCOR or NON'); END IF;
    IF l_qr!=(p_bill.reference_type='QRR') THEN fail('QRR requires a QR-IBAN; SCOR/NON require an ordinary IBAN'); END IF;
    IF p_bill.reference_type='QRR' THEN
      IF p_bill.currency!='CHF' THEN fail('IG 2.4 only permits QRR in CHF'); END IF;
      IF p_bill.reference IS NULL OR NOT REGEXP_LIKE(p_bill.reference,'^[0-9]{27}$','c')
        OR qr_reference(SUBSTR(p_bill.reference,1,26))!=p_bill.reference THEN fail('Invalid QR reference checksum or syntax'); END IF;
    ELSIF p_bill.reference_type='SCOR' THEN
      IF p_bill.reference IS NULL OR NOT REGEXP_LIKE(p_bill.reference,'^RF[0-9]{2}[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0-9]{1,21}$','c')
        OR mod97(UPPER(SUBSTR(p_bill.reference,5)||SUBSTR(p_bill.reference,1,4)))!=1 THEN fail('Invalid ISO 11649 creditor reference'); END IF;
    ELSIF p_bill.reference IS NOT NULL THEN fail('NON must have an empty reference'); END IF;
    field(p_bill.message,'message',140);
    field(p_bill.billing_information,'billing_information',140);
    IF NVL(LENGTH(p_bill.message),0)+NVL(LENGTH(p_bill.billing_information),0)>140 THEN fail('message + billing_information exceed 140 characters'); END IF;
    IF p_bill.billing_information IS NOT NULL AND NOT REGEXP_LIKE(p_bill.billing_information,'^//[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0-9]{2}') THEN
      fail('billing_information must start with // and a two-character syntax identifier'); END IF;
    field(p_bill.alternative_1,'alternative_1',100);
    field(p_bill.alternative_2,'alternative_2',100);
    IF p_bill.alternative_2 IS NOT NULL AND p_bill.alternative_1 IS NULL THEN fail('alternative_2 requires alternative_1'); END IF;
  END;
  FUNCTION payload(p_bill IN t_bill) RETURN VARCHAR2 IS
    l_value VARCHAR2(4000) := 'SPC'||CHR(10)||'0200'||CHR(10)||'1';
    l_empty t_address;
    PROCEDURE line(p_value VARCHAR2) IS BEGIN l_value := l_value||CHR(10)||p_value; END;
    PROCEDURE addr(p_address t_address) IS
    BEGIN
      line(CASE WHEN has_address(p_address) THEN 'S' END);
      line(p_address.name); line(p_address.street); line(p_address.building_no);
      line(p_address.postal_code); line(p_address.town); line(p_address.country);
    END;
  BEGIN
    validate_fields(p_bill);
    line(p_bill.account); addr(p_bill.creditor); addr(l_empty);
    line(CASE WHEN p_bill.amount IS NOT NULL THEN TO_CHAR(p_bill.amount,'FM999999990D00','NLS_NUMERIC_CHARACTERS=''.,''') END);
    line(p_bill.currency); addr(p_bill.debtor); line(p_bill.reference_type);
    line(p_bill.reference); line(p_bill.message); line('EPD');
    IF p_bill.billing_information IS NOT NULL OR p_bill.alternative_1 IS NOT NULL THEN line(p_bill.billing_information); END IF;
    IF p_bill.alternative_1 IS NOT NULL THEN line(p_bill.alternative_1); END IF;
    IF p_bill.alternative_2 IS NOT NULL THEN line(p_bill.alternative_2); END IF;
    IF LENGTH(l_value)>997 OR UTL_RAW.LENGTH(UTL_I18N.STRING_TO_RAW(l_value,'AL32UTF8'))>997 THEN
      fail('Payload exceeds 997 characters or the UTF-8 byte capacity of QR version 25-M'); END IF;
    RETURN l_value;
  END;

  PROCEDURE validate(p_bill IN t_bill) IS
    l_payload VARCHAR2(4000);
  BEGIN
    l_payload := payload(p_bill);
  END;

  PROCEDURE keys(p_obj JSON_OBJECT_T,p_allowed VARCHAR2) IS
    l_keys JSON_KEY_LIST := p_obj.get_keys;
  BEGIN
    FOR i IN 1..l_keys.COUNT LOOP
      IF INSTR(p_allowed,','||l_keys(i)||',')=0 THEN fail('Unknown JSON property: '||l_keys(i)); END IF;
    END LOOP;
  END;
  FUNCTION string_value(p_obj JSON_OBJECT_T,p_key VARCHAR2) RETURN VARCHAR2 IS
    l_element JSON_ELEMENT_T;
  BEGIN
    l_element := p_obj.get(p_key);
    IF l_element IS NULL THEN RETURN NULL; END IF;
    IF l_element.is_null THEN RETURN NULL; END IF;
    IF NOT l_element.is_string THEN fail('JSON '||p_key||' must be a string'); END IF;
    RETURN p_obj.get_string(p_key);
  END;
  FUNCTION read_address(p_element JSON_ELEMENT_T) RETURN t_address IS
    l_obj JSON_OBJECT_T;
    l_address t_address;
  BEGIN
    IF p_element IS NULL THEN RETURN l_address; END IF;
    IF p_element.is_null THEN RETURN l_address; END IF;
    IF NOT p_element.is_object THEN fail('JSON address must be an object'); END IF;
    l_obj := TREAT(p_element AS JSON_OBJECT_T);
    keys(l_obj,',name,street,building_no,postal_code,town,country,');
    l_address.name := string_value(l_obj,'name'); l_address.street := string_value(l_obj,'street');
    l_address.building_no := string_value(l_obj,'building_no'); l_address.postal_code := string_value(l_obj,'postal_code');
    l_address.town := string_value(l_obj,'town'); l_address.country := string_value(l_obj,'country');
    RETURN l_address;
  END;
  FUNCTION from_json(p_json IN CLOB) RETURN t_bill IS
    l_obj JSON_OBJECT_T;
    l_element JSON_ELEMENT_T;
    l_array JSON_ARRAY_T;
    l_bill t_bill;
    l_payload VARCHAR2(4000);
    l_valid PLS_INTEGER;
  BEGIN
    SELECT CASE WHEN p_json IS JSON STRICT WITH UNIQUE KEYS THEN 1 ELSE 0 END INTO l_valid FROM dual;
    IF l_valid=0 THEN fail('JSON must be strict and have unique keys'); END IF;
    l_obj := JSON_OBJECT_T.parse(p_json);
    keys(l_obj,',schema_version,account,creditor,amount,currency,debtor,reference_type,reference,message,billing_information,alternatives,');
    l_element := l_obj.get('schema_version');
    IF l_element IS NULL THEN fail('JSON schema_version is required'); END IF;
    IF NOT l_element.is_number OR l_obj.get_number('schema_version')!=1 THEN fail('Unsupported JSON schema_version'); END IF;
    l_bill.account := string_value(l_obj,'account'); l_bill.creditor := read_address(l_obj.get('creditor'));
    l_element := l_obj.get('debtor');
    l_bill.debtor := read_address(l_element);
    IF l_element IS NOT NULL THEN
      IF NOT l_element.is_null THEN address_check(l_bill.debtor,'debtor'); END IF;
    END IF;
    IF l_obj.has('currency') THEN l_bill.currency := string_value(l_obj,'currency'); END IF;
    IF l_obj.has('reference_type') THEN l_bill.reference_type := string_value(l_obj,'reference_type'); END IF;
    l_bill.reference := string_value(l_obj,'reference'); l_bill.message := string_value(l_obj,'message');
    l_bill.billing_information := string_value(l_obj,'billing_information');
    l_element := l_obj.get('amount');
    IF l_element IS NOT NULL THEN
      IF NOT l_element.is_null THEN
        IF NOT l_element.is_number THEN fail('JSON amount must be a number'); END IF;
        l_bill.amount := l_obj.get_number('amount');
      END IF;
    END IF;
    l_element := l_obj.get('alternatives');
    IF l_element IS NOT NULL THEN
      IF NOT l_element.is_array THEN fail('JSON alternatives must be an array'); END IF;
      l_array := TREAT(l_element AS JSON_ARRAY_T);
      IF l_array.get_size>2 THEN fail('At most two alternative procedures are allowed'); END IF;
      FOR i IN 0..l_array.get_size-1 LOOP
        l_element := l_array.get(i);
        IF NOT l_element.is_string THEN fail('JSON alternative must be a string'); END IF;
        IF TRIM(l_array.get_string(i)) IS NULL THEN fail('JSON alternative must not be empty'); END IF;
        IF i=0 THEN l_bill.alternative_1 := l_array.get_string(i); ELSE l_bill.alternative_2 := l_array.get_string(i); END IF;
      END LOOP;
    END IF;
    l_payload := payload(l_bill);
    RETURN l_bill;
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE=c_err_swiss THEN RAISE; END IF;
    fail('Invalid Swiss bill JSON: '||SUBSTR(SQLERRM,1,500));
    RETURN l_bill;
  END;
  FUNCTION to_json(p_bill IN t_bill) RETURN CLOB IS
    l_obj JSON_OBJECT_T := JSON_OBJECT_T();
    l_array JSON_ARRAY_T := JSON_ARRAY_T();
    l_payload VARCHAR2(4000);
    FUNCTION addr(p_address t_address) RETURN JSON_OBJECT_T IS
      l_a JSON_OBJECT_T := JSON_OBJECT_T();
    BEGIN
      l_a.put('name',p_address.name); l_a.put('street',p_address.street); l_a.put('building_no',p_address.building_no);
      l_a.put('postal_code',p_address.postal_code); l_a.put('town',p_address.town); l_a.put('country',p_address.country);
      RETURN l_a;
    END;
  BEGIN
    l_payload := payload(p_bill);
    l_obj.put('schema_version',1); l_obj.put('account',p_bill.account); l_obj.put('creditor',addr(p_bill.creditor));
    IF has_address(p_bill.debtor) THEN l_obj.put('debtor',addr(p_bill.debtor)); END IF;
    IF p_bill.amount IS NOT NULL THEN l_obj.put('amount',p_bill.amount); END IF;
    l_obj.put('currency',p_bill.currency); l_obj.put('reference_type',p_bill.reference_type);
    l_obj.put('reference',p_bill.reference); l_obj.put('message',p_bill.message);
    l_obj.put('billing_information',p_bill.billing_information);
    IF p_bill.alternative_1 IS NOT NULL THEN l_array.append(p_bill.alternative_1); END IF;
    IF p_bill.alternative_2 IS NOT NULL THEN l_array.append(p_bill.alternative_2); END IF;
    l_obj.put('alternatives',l_array);
    RETURN l_obj.to_clob;
  END;

  FUNCTION grouped(p_value VARCHAR2,p_size PLS_INTEGER,p_first PLS_INTEGER DEFAULT NULL) RETURN VARCHAR2 IS
    l_pos PLS_INTEGER := 1;
    l_step PLS_INTEGER := NVL(p_first,p_size);
    l_value VARCHAR2(4000);
  BEGIN
    WHILE l_pos<=LENGTH(p_value) LOOP
      l_value := l_value||CASE WHEN l_pos>1 THEN ' ' END||SUBSTR(p_value,l_pos,l_step);
      l_pos := l_pos+l_step; l_step := p_size;
    END LOOP;
    RETURN l_value;
  END;
  FUNCTION address_text(p_address t_address,p_receipt BOOLEAN) RETURN VARCHAR2 IS
    l_value VARCHAR2(4000) := p_address.name;
  BEGIN
    -- The receipt may omit street/building to leave room for names and town.
    IF NOT p_receipt AND (p_address.street IS NOT NULL OR p_address.building_no IS NOT NULL) THEN
      l_value := l_value||CHR(10)||TRIM(p_address.street||' '||p_address.building_no);
    END IF;
    RETURN l_value||CHR(10)||CASE WHEN p_address.country!='CH' THEN p_address.country||'-' END
      ||p_address.postal_code||' '||p_address.town;
  END;
  FUNCTION label(p_language VARCHAR2,p_id PLS_INTEGER) RETURN VARCHAR2 IS
    -- IG 2.4 Annex C: payment, receipt, account, reference, additional, debtor,
    -- blank debtor, currency, amount, acceptance, separation notice.
    l_labels VARCHAR2(2000);
  BEGIN
    CASE p_language
      WHEN 'IT' THEN l_labels := 'Sezione pagamento|Ricevuta|Conto / Pagabile a|Riferimento|Informazioni supplementari|Pagabile da|Pagabile da (nome/indirizzo)|Valuta|Importo|Punto di accettazione|Da staccare prima del versamento';
      WHEN 'EN' THEN l_labels := 'Payment part|Receipt|Account / Payable to|Reference|Additional information|Payable by|Payable by (name/address)|Currency|Amount|Acceptance point|Separate before paying in';
      WHEN 'DE' THEN l_labels := 'Zahlteil|Empfangsschein|Konto / Zahlbar an|Referenz|Zusätzliche Informationen|Zahlbar durch|Zahlbar durch (Name/Adresse)|Währung|Betrag|Annahmestelle|Vor der Einzahlung abzutrennen';
      WHEN 'FR' THEN l_labels := 'Section paiement|Récépissé|Compte / Payable à|Référence|Informations supplémentaires|Payable par|Payable par (nom/adresse)|Monnaie|Montant|Point de dépôt|A détacher avant le versement';
      WHEN 'RM' THEN l_labels := 'Part da pajament|Quittanza|Conto / Da pajar a|Referenza|Infurmaziuns supplementaras|Da pajar da|Da pajar da (num/adressa)|Valuta|Import|Post da recepziun|Da distatgar avant che pajar';
      ELSE fail('language must be IT, EN, DE, FR or RM');
    END CASE;
    RETURN REGEXP_SUBSTR(l_labels,'[^|]+',1,p_id);
  END;
  PROCEDURE draw(p_doc IN rad_pdf_types.t_doc_handle,p_bill IN t_bill,
                 p_options IN t_options DEFAULT NULL) IS
    TYPE t_block IS RECORD (plan rad_pdf_text.t_plan,x NUMBER,y NUMBER);
    TYPE t_blocks IS TABLE OF t_block INDEX BY PLS_INTEGER;
    TYPE t_corner IS RECORD (x NUMBER,y NUMBER,w NUMBER,h NUMBER);
    TYPE t_corners IS TABLE OF t_corner INDEX BY PLS_INTEGER;
    l_blocks t_blocks;
    l_corners t_corners;
    l_options t_options := p_options;
    l_payload VARCHAR2(4000);
    l_normal PLS_INTEGER;
    l_bold PLS_INTEGER;
    l_y NUMBER;
    l_info_end NUMBER;
    l_amount VARCHAR2(100);
    l_reference VARCHAR2(100);
    l_mark PLS_INTEGER;
    l_size NUMBER;
    l_style rad_pdf_text.t_style;
    l_name VARCHAR2(100);

    PROCEDURE text(p_value VARCHAR2,p_x NUMBER,p_y IN OUT NUMBER,p_width NUMBER,p_size NUMBER,p_bold BOOLEAN DEFAULT FALSE) IS
      l_n PLS_INTEGER := l_blocks.COUNT+1;
      l_idx PLS_INTEGER := CASE WHEN p_bold THEN l_bold ELSE l_normal END;
    BEGIN
      IF p_value IS NULL THEN RETURN; END IF;
      rad_pdf_fonts.assert_text_supported(p_value,l_idx);
      l_style := rad_pdf_text.prepare_style(l_idx,p_size,'000000');
      l_blocks(l_n).plan := rad_pdf_text.prepare_varchar(p_value,l_style,p_width*c_mm);
      l_blocks(l_n).x := p_x*c_mm; l_blocks(l_n).y := p_y*c_mm;
      p_y := p_y-l_blocks(l_n).plan.height/c_mm;
    END;
    PROCEDURE fixed_text(p_value VARCHAR2,p_x NUMBER,p_top NUMBER,p_width NUMBER,p_size NUMBER,p_bold BOOLEAN DEFAULT FALSE) IS
      l_top NUMBER := p_top;
    BEGIN
      text(p_value,p_x,l_top,p_width,p_size,p_bold);
      IF p_value IS NOT NULL AND l_blocks(l_blocks.LAST).plan.lines.COUNT>1 THEN
        fail('Fixed text does not fit on one line: '||SUBSTR(p_value,1,100));
      END IF;
    END;
    PROCEDURE corner(p_x NUMBER,p_y NUMBER,p_w NUMBER,p_h NUMBER) IS
      l_n PLS_INTEGER := l_corners.COUNT+1;
    BEGIN
      l_corners(l_n).x := p_x; l_corners(l_n).y := p_y;
      l_corners(l_n).w := p_w; l_corners(l_n).h := p_h;
    END;
    PROCEDURE information(p_receipt BOOLEAN,p_size NUMBER) IS
      l_x NUMBER := CASE WHEN p_receipt THEN 5 ELSE 118 END;
      l_w NUMBER := CASE WHEN p_receipt THEN 52 ELSE 87 END;
      l_additional VARCHAR2(4000) := p_bill.message;
      PROCEDURE section(p_label PLS_INTEGER,p_value VARCHAR2) IS
      BEGIN
        text(label(l_options.language,p_label),l_x,l_y,l_w,p_size-2,TRUE);
        text(p_value,l_x,l_y,l_w,p_size);
        l_y := l_y-2;
      END;
    BEGIN
      l_y := CASE WHEN p_receipt THEN 93 ELSE 100 END;
      section(3,grouped(p_bill.account,4)||CHR(10)||address_text(p_bill.creditor,p_receipt));
      IF p_bill.reference IS NOT NULL THEN section(4,l_reference); END IF;
      IF NOT p_receipt THEN
        IF l_options.print_billing_information AND p_bill.billing_information IS NOT NULL THEN
          l_additional := l_additional||CASE WHEN l_additional IS NOT NULL THEN CHR(10) END||p_bill.billing_information;
        END IF;
        IF l_additional IS NOT NULL THEN section(5,l_additional); END IF;
      END IF;
      IF has_address(p_bill.debtor) THEN section(6,address_text(p_bill.debtor,p_receipt));
      ELSE
        text(label(l_options.language,7),l_x,l_y,l_w,p_size-2,TRUE);
        l_y := l_y-CASE WHEN p_receipt THEN 20 ELSE 25 END;
      END IF;
      l_info_end := l_y;
    END;
    PROCEDURE draw_corner(p_corner t_corner) IS
      x NUMBER := p_corner.x*c_mm; y NUMBER := p_corner.y*c_mm;
      w NUMBER := p_corner.w*c_mm; h NUMBER := p_corner.h*c_mm; s NUMBER := 3*c_mm;
    BEGIN
      FOR side IN 0..1 LOOP
        rad_pdf_canvas.h_line(p_doc,x,y+side*h,s,0.75,'000000');
        rad_pdf_canvas.h_line(p_doc,x+w-s,y+side*h,s,0.75,'000000');
        rad_pdf_canvas.v_line(p_doc,x+side*w,y+s,s,0.75,'000000');
        rad_pdf_canvas.v_line(p_doc,x+side*w,y+h,s,0.75,'000000');
      END LOOP;
    END;
    PROCEDURE alternative(p_value VARCHAR2,p_top NUMBER) IS
      l_pos PLS_INTEGER;
      l_prefix VARCHAR2(100);
      l_suffix VARCHAR2(4000);
      l_width NUMBER;
    BEGIN
      IF p_value IS NULL THEN RETURN; END IF;
      l_prefix := REGEXP_SUBSTR(p_value,'^[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0-9]+');
      l_pos := NVL(LENGTH(l_prefix),0)+1;
      l_suffix := SUBSTR(p_value,l_pos);
      l_width := rad_pdf_fonts.text_width(l_prefix,l_bold,7);
      IF l_width+rad_pdf_fonts.text_width(l_suffix,l_normal,7)>138*c_mm THEN
        fail('Alternative procedure does not fit the printed line; provide a shorter value'); END IF;
      fixed_text(l_prefix,67,p_top,GREATEST(l_width/c_mm+0.01,0.1),7,TRUE);
      fixed_text(l_suffix,67+l_width/c_mm,p_top,138-l_width/c_mm,7);
    END;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    l_payload := payload(p_bill);
    l_options.language := NVL(l_options.language,'IT');
    l_options.font_family := NVL(l_options.font_family,'Helvetica');
    l_name := label(l_options.language,1);
    IF LOWER(REPLACE(REPLACE(l_options.font_family,' ',''),'-','')) NOT IN ('arial','frutiger','helvetica','liberationsans') THEN
      fail('Swiss QR-bill permits Arial, Frutiger, Helvetica or Liberation Sans'); END IF;
    IF ABS(rad_pdf_canvas.get_info(p_doc,rad_pdf_types.c_info_page_width)-210*c_mm)>0.1
       OR rad_pdf_canvas.get_info(p_doc,rad_pdf_types.c_info_page_height)<110*c_mm THEN
      fail('Swiss payment section needs a 210 mm wide page at least 110 mm high'); END IF;
    IF (l_options.font_regular IS NULL AND l_options.font_bold IS NOT NULL)
       OR (l_options.font_regular IS NOT NULL AND l_options.font_bold IS NULL) THEN
      fail('Provide both font_regular and font_bold'); END IF;
    IF l_options.font_regular IS NOT NULL THEN
      l_normal := l_options.font_regular; l_bold := l_options.font_bold;
      IF NOT rad_pdf_fonts.font_exists(l_normal) OR NOT rad_pdf_fonts.font_exists(l_bold) THEN
        RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_font,'Swiss font index does not exist');
      END IF;
      FOR i IN 0..1 LOOP
        l_name := rad_pdf_fonts.font_pdf_name(CASE i WHEN 0 THEN l_normal ELSE l_bold END);
        IF NOT REGEXP_LIKE(l_name,'^(Arial|Frutiger|Helvetica|LiberationSans)','i')
           OR REGEXP_LIKE(l_name,'Italic|Oblique','i') THEN fail('Loaded font must be an allowed Swiss sans-serif face'); END IF;
        IF (i=1 AND NOT REGEXP_LIKE(l_name,'Bold|Demi','i'))
           OR (i=0 AND REGEXP_LIKE(l_name,'Bold|Demi','i')) THEN fail('Provide the regular and bold font faces in their respective options'); END IF;
      END LOOP;
    ELSE
      l_normal := rad_pdf_fonts.find_font(p_doc,l_options.font_family,'N');
      l_bold := rad_pdf_fonts.find_font(p_doc,l_options.font_family,'B');
    END IF;
    IF l_bold=l_normal THEN fail('Swiss QR-bill needs distinct regular and bold fonts'); END IF;
    l_reference := CASE WHEN p_bill.reference_type='QRR' THEN grouped(p_bill.reference,5,2) ELSE grouped(p_bill.reference,4) END;
    l_amount := TO_CHAR(p_bill.amount,'FM999G999G990D00','NLS_NUMERIC_CHARACTERS=''.,''');
    l_amount := REPLACE(l_amount,',',' ');
    -- Prepare all text before painting. Payment values may shrink 10 -> 8 pt,
    -- headings stay 2 pt smaller. Receipt values/headings remain 8/6 pt.
    fixed_text(label(l_options.language,1),67,100,51,11,TRUE);
    fixed_text(label(l_options.language,2),5,100,52,11,TRUE);
    fixed_text(label(l_options.language,11),5,109,200,7);
    information(TRUE,8);
    IF l_info_end<42 THEN fail('Receipt information does not fit; shorten name/address without losing identity'); END IF;
    IF NOT has_address(p_bill.debtor) THEN corner(5,l_info_end,52,20); END IF;
    l_mark := l_blocks.COUNT;
    FOR size_step IN REVERSE 8..10 LOOP
      WHILE l_blocks.COUNT>l_mark LOOP l_blocks.DELETE(l_blocks.LAST); END LOOP;
      information(FALSE,size_step);
      l_size := size_step;
      EXIT WHEN l_info_end>=15;
    END LOOP;
    IF l_info_end<15 THEN fail('Payment information does not fit at the minimum font size; shorten optional information'); END IF;
    IF NOT has_address(p_bill.debtor) THEN corner(118,l_info_end,65,25); END IF;
    fixed_text(label(l_options.language,8),67,37,13,l_size-2,TRUE);
    fixed_text(label(l_options.language,9),80,37,38,l_size-2,TRUE);
    fixed_text(p_bill.currency,67,33,11,l_size);
    fixed_text(l_amount,80,33,38,l_size);
    fixed_text(label(l_options.language,8),5,37,12,6,TRUE);
    fixed_text(label(l_options.language,9),18,37,39,6,TRUE);
    fixed_text(p_bill.currency,5,33,12,8);
    fixed_text(l_amount,18,33,39,8);
    fixed_text(label(l_options.language,10),57-rad_pdf_fonts.text_width(
      label(l_options.language,10),l_bold,6)/c_mm,20,52,6,TRUE);
    IF p_bill.amount IS NULL THEN corner(78,17,40,15); corner(27,22,30,10); END IF;
    alternative(p_bill.alternative_1,13); alternative(p_bill.alternative_2,9.5);
    -- White paper area and explicit black separations. The translated notice
    -- above the top line is the SIX-permitted alternative to scissors symbols.
    rad_pdf_canvas.rect(p_doc,0,0,210*c_mm,110*c_mm,NULL,'FFFFFF',0);
    rad_pdf_canvas.set_line_dash(p_doc,0);
    rad_pdf_canvas.h_line(p_doc,0,105*c_mm,210*c_mm,0.5,'000000');
    rad_pdf_canvas.v_line(p_doc,62*c_mm,105*c_mm,105*c_mm,0.5,'000000');
    rad_pdf_barcode.swiss_qrcode(p_doc,l_payload,67*c_mm,42*c_mm);
    FOR i IN 1..l_blocks.COUNT LOOP
      rad_pdf_canvas.paint_lines(p_doc,l_blocks(i).plan,l_blocks(i).x,l_blocks(i).y);
    END LOOP;
    FOR i IN 1..l_corners.COUNT LOOP draw_corner(l_corners(i)); END LOOP;
  END draw;
  -- ---------------------------------------------------------------------------
  -- the bill attached to a document
  -- ---------------------------------------------------------------------------
  PROCEDURE attach(p_doc IN rad_pdf_types.t_doc_handle, p_bill IN t_bill, p_options IN t_options DEFAULT NULL) IS
    l_payload VARCHAR2(4000);
    l_options t_options := p_options;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    l_payload := payload(p_bill);
    l_options.placement := NVL(l_options.placement,'INTEGRATED');
    IF l_options.placement NOT IN ('INTEGRATED','SEPARATE') THEN
      RAISE_APPLICATION_ERROR(c_err_swiss,'placement must be INTEGRATED or SEPARATE');
    END IF;
    IF g_attached.EXISTS(p_doc) THEN
      RAISE_APPLICATION_ERROR(c_err_swiss,'Document already has a Swiss payment section');
    END IF;
    g_attached(p_doc).bill := p_bill;
    g_attached(p_doc).options := l_options;
  END attach;

  FUNCTION attached(p_doc IN rad_pdf_types.t_doc_handle) RETURN BOOLEAN IS
  BEGIN
    RETURN g_attached.EXISTS(p_doc);
  END attached;

  FUNCTION placement(p_doc IN rad_pdf_types.t_doc_handle) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE WHEN g_attached.EXISTS(p_doc) THEN g_attached(p_doc).options.placement END;
  END placement;

  PROCEDURE draw_attached(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    IF g_attached.EXISTS(p_doc) THEN draw(p_doc, g_attached(p_doc).bill, g_attached(p_doc).options); END IF;
  END draw_attached;

  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    g_attached.DELETE(p_doc);
  END close_doc;

END rad_pdf_swiss;
/
