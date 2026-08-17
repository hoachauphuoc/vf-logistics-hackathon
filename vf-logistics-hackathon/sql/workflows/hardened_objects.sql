-- ============================================================================
-- VF LOGISTICS - Hardened agent skill objects
-- Exported live from MENDIX_APP.AGENTS on 2026-08-02 01:23:13.614 -0700
-- This file is generated from GET_DDL so the repository matches what is deployed.
-- ============================================================================

create or replace TABLE AI_MODEL_RATE (
	MODEL_NAME VARCHAR(100) NOT NULL,
	CREDITS_PER_1M_TOKENS FLOAT NOT NULL,
	RATE_SOURCE VARCHAR(500),
	UPDATED_AT TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP(),
	primary key (MODEL_NAME)
)COMMENT='Reference credit rates per 1M tokens for the Cortex models this solution calls. These are configured reference values taken from the Snowflake Service Consumption Table, NOT a made-up multiplier: cost shown in the FinOps dashboard = real token usage returned by Cortex x this rate x USD per credit. Authoritative billed consumption always remains SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY; this table exists so the dashboard can attribute cost per procedure and per day, which the account-level view cannot do.'
;

create or replace view V_AI_DAILY_COST(
	DAY,
	TOTAL_CALLS,
	TOTAL_TOKENS,
	INPUT_TOKENS,
	OUTPUT_TOKENS,
	AVG_LATENCY_MS,
	ESTIMATED_COST_USD,
	ERRORS
) COMMENT='Daily Cortex AI usage and estimated cost. TOKEN COUNTS ARE REAL - they are the usage figures Cortex returns with each COMPLETE call, not a character-length estimate. COST IS AN ESTIMATE derived from those real tokens multiplied by the per-model reference credit rate in AI_MODEL_RATE and the USD-per-credit value in APP_CONFIG; authoritative billed consumption is SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY. AVG_LATENCY_MS is the mean of the measured LATENCY_MS recorded per call.'
 as
WITH usd AS (
    SELECT TRY_TO_DOUBLE(MAX(CONFIG_VALUE)) AS USD_PER_CREDIT
    FROM MENDIX_APP.AGENTS.APP_CONFIG
    WHERE CONFIG_KEY = 'AI_USD_PER_CREDIT'
)
SELECT
    DATE(l.CALL_TIMESTAMP)                                        AS DAY,
    COUNT(*)                                                      AS TOTAL_CALLS,
    SUM(l.TOTAL_TOKENS)                                           AS TOTAL_TOKENS,
    SUM(l.INPUT_TOKENS)                                           AS INPUT_TOKENS,
    SUM(l.OUTPUT_TOKENS)                                          AS OUTPUT_TOKENS,
    ROUND(AVG(l.LATENCY_MS))                                      AS AVG_LATENCY_MS,
    ROUND(SUM(COALESCE(l.TOTAL_TOKENS, 0) / 1000000.0
              * COALESCE(r.CREDITS_PER_1M_TOKENS, 1.95)
              * COALESCE(u.USD_PER_CREDIT, 2.00)), 6)             AS ESTIMATED_COST_USD,
    SUM(CASE WHEN l.CALL_STATUS = 'ERROR' THEN 1 ELSE 0 END)      AS ERRORS
FROM MENDIX_APP.AGENTS.AI_CALL_LOG l
LEFT JOIN MENDIX_APP.AGENTS.AI_MODEL_RATE r ON r.MODEL_NAME = l.MODEL_NAME
CROSS JOIN usd u
GROUP BY DATE(l.CALL_TIMESTAMP);

create or replace view V_AI_DECISION_EVAL(
	ALERT_ID,
	ALERT_TYPE,
	SEVERITY,
	BL_NUMBER,
	SHIPPER_NAME,
	CONSIGNEE_NAME,
	TOTAL_CHARGES,
	GROSS_WEIGHT_KGS,
	CPK_MULTIPLE,
	SANCTIONS_HIT,
	SHELL_NAME,
	AI_CONFIDENCE_SCORE,
	ACTUAL_DECISION,
	EXPECTED_DECISION,
	IS_MATCH,
	AI_DECISION_REASON,
	AI_ANALYZED_AT
) COMMENT='Evaluation of AI decision quality. EXPECTED_DECISION is derived deterministically in SQL from the same documented rubric the model is given (sanctions matches, cost-per-kg band vs peer median, shell-company name patterns, extraction confidence). This measures POLICY ADHERENCE - whether the model faithfully applies the written compliance policy - which is the property that matters for an auditable compliance system. It is rule-derived, not human-labelled, and that is stated openly.'
 as
WITH med AS (
    SELECT MEDIAN(TOTAL_CHARGES / NULLIF(GROSS_WEIGHT_KGS, 0)) AS MED_CPK
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING
    WHERE TOTAL_CHARGES IS NOT NULL AND GROSS_WEIGHT_KGS > 0
),
evidence AS (
    SELECT
        a.ALERT_ID,
        a.ALERT_TYPE,
        a.SEVERITY,
        a.AI_RECOMMENDED_ACTION,
        a.AI_DECISION_REASON,
        a.AI_ANALYZED_AT,
        b.BL_NUMBER,
        b.SHIPPER_NAME,
        b.CONSIGNEE_NAME,
        b.TOTAL_CHARGES,
        b.GROSS_WEIGHT_KGS,
        b.AI_CONFIDENCE_SCORE,
        ROUND((b.TOTAL_CHARGES / NULLIF(b.GROSS_WEIGHT_KGS, 0)) / NULLIF(m.MED_CPK, 0), 2) AS CPK_MULTIPLE,
        CASE WHEN EXISTS (
            SELECT 1
            FROM MENDIX_APP.AGENTS.V_SANCTIONS_SCREENING_SOURCE s
            WHERE UPPER(s.ENTITY_NAME) LIKE '%' || UPPER(NVL(b.SHIPPER_NAME, '~none~')) || '%'
               OR UPPER(s.ENTITY_NAME) LIKE '%' || UPPER(NVL(b.CONSIGNEE_NAME, '~none~')) || '%'
        ) THEN 1 ELSE 0 END AS SANCTIONS_HIT,
        CASE WHEN UPPER(NVL(b.SHIPPER_NAME, '')) LIKE '%SUSPICIOUS%'
                  OR UPPER(NVL(b.SHIPPER_NAME, '')) LIKE '%UNKNOWN%'
                  OR UPPER(NVL(b.CONSIGNEE_NAME, '')) LIKE '%SHELL%'
             THEN 1 ELSE 0 END AS SHELL_NAME
    FROM MENDIX_APP.AGENTS.FRAUD_ALERT a
    JOIN MENDIX_APP.AGENTS.BILL_OF_LADING b ON b.BL_ID = a.BL_ID
    CROSS JOIN med m
    WHERE a.AI_RECOMMENDED_ACTION IS NOT NULL
)
SELECT
    ALERT_ID, ALERT_TYPE, SEVERITY, BL_NUMBER, SHIPPER_NAME, CONSIGNEE_NAME,
    TOTAL_CHARGES, GROSS_WEIGHT_KGS, CPK_MULTIPLE, SANCTIONS_HIT, SHELL_NAME, AI_CONFIDENCE_SCORE,
    AI_RECOMMENDED_ACTION AS ACTUAL_DECISION,
    CASE
        WHEN SANCTIONS_HIT = 1 OR SHELL_NAME = 1 OR CPK_MULTIPLE > 10 THEN 'BLOCK'
        WHEN CPK_MULTIPLE IS NULL
             OR CPK_MULTIPLE > 5
             OR TOTAL_CHARGES IS NULL
             OR GROSS_WEIGHT_KGS IS NULL
             OR (AI_CONFIDENCE_SCORE IS NOT NULL AND AI_CONFIDENCE_SCORE < 60) THEN 'ESCALATE'
        ELSE 'CLEAR'
    END AS EXPECTED_DECISION,
    IFF(AI_RECOMMENDED_ACTION = CASE
        WHEN SANCTIONS_HIT = 1 OR SHELL_NAME = 1 OR CPK_MULTIPLE > 10 THEN 'BLOCK'
        WHEN CPK_MULTIPLE IS NULL
             OR CPK_MULTIPLE > 5
             OR TOTAL_CHARGES IS NULL
             OR GROSS_WEIGHT_KGS IS NULL
             OR (AI_CONFIDENCE_SCORE IS NOT NULL AND AI_CONFIDENCE_SCORE < 60) THEN 'ESCALATE'
        ELSE 'CLEAR'
    END, TRUE, FALSE) AS IS_MATCH,
    AI_DECISION_REASON, AI_ANALYZED_AT
FROM evidence;

CREATE OR REPLACE PROCEDURE "EVALUATE_AI_DECISIONS"()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='Measures AI decision quality as POLICY ADHERENCE: every AI decision is compared against the decision the documented rubric mandates for the same evidence, computed deterministically in SQL by V_AI_DECISION_EVAL. Reports overall accuracy, a full confusion matrix, and separately the two error classes that matter operationally - CRITICAL false negatives (should have been BLOCKed but was CLEARed, i.e. risk let through) and false positives (legitimate trade blocked). Ground truth is rule-derived rather than human-labelled, which is stated openly in the view comment.'
EXECUTE AS CALLER
AS '
DECLARE
    v_evaluated NUMBER;
    v_matches NUMBER;
    v_accuracy FLOAT;
    v_missed_blocks NUMBER;
    v_critical_fn NUMBER;
    v_false_pos NUMBER;
    v_over_escalate NUMBER;
    v_matrix VARCHAR DEFAULT '''';
BEGIN
    SELECT COUNT(*),
           SUM(IFF(IS_MATCH, 1, 0)),
           ROUND(100.0 * SUM(IFF(IS_MATCH, 1, 0)) / NULLIF(COUNT(*), 0), 1),
           SUM(IFF(EXPECTED_DECISION = ''BLOCK'' AND ACTUAL_DECISION <> ''BLOCK'', 1, 0)),
           SUM(IFF(EXPECTED_DECISION = ''BLOCK'' AND ACTUAL_DECISION = ''CLEAR'', 1, 0)),
           SUM(IFF(EXPECTED_DECISION = ''CLEAR'' AND ACTUAL_DECISION = ''BLOCK'', 1, 0)),
           SUM(IFF(EXPECTED_DECISION = ''ESCALATE'' AND ACTUAL_DECISION = ''BLOCK'', 1, 0))
    INTO :v_evaluated, :v_matches, :v_accuracy, :v_missed_blocks, :v_critical_fn, :v_false_pos, :v_over_escalate
    FROM MENDIX_APP.AGENTS.V_AI_DECISION_EVAL;

    SELECT LISTAGG(''{"expected":"'' || EXPECTED_DECISION || ''","actual":"'' || ACTUAL_DECISION || ''","count":'' || CNT || ''}'', '','')
    INTO :v_matrix
    FROM (
        SELECT EXPECTED_DECISION, ACTUAL_DECISION, COUNT(*) AS CNT
        FROM MENDIX_APP.AGENTS.V_AI_DECISION_EVAL
        GROUP BY 1, 2
        ORDER BY 1, 2
    );

    RETURN ''{"evaluation":"AI_DECISION_POLICY_ADHERENCE"''
        || '',"ground_truth":"rule-derived from the documented rubric (not human-labelled)"''
        || '',"decisions_evaluated":'' || NVL(:v_evaluated, 0)
        || '',"decisions_matching_policy":'' || NVL(:v_matches, 0)
        || '',"accuracy_pct":'' || NVL(:v_accuracy, 0)
        || '',"critical_false_negatives_block_treated_as_clear":'' || NVL(:v_critical_fn, 0)
        || '',"missed_blocks_any_direction":'' || NVL(:v_missed_blocks, 0)
        || '',"false_positives_clear_blocked":'' || NVL(:v_false_pos, 0)
        || '',"over_blocked_from_escalate_band":'' || NVL(:v_over_escalate, 0)
        || '',"confusion_matrix":['' || NVL(:v_matrix, '''') || '']''
        || '',"evaluated_at":"'' || CURRENT_TIMESTAMP()::VARCHAR || ''"}'';
END
';

CREATE OR REPLACE PROCEDURE "WORKFLOW_DETECT_AND_ACT"("P_QUEUE_LIMIT" NUMBER(38,0) DEFAULT 60)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='Skill 1 - Automated fraud/compliance detection. Thresholds are DERIVED FROM THE DATA DISTRIBUTION (99th percentile of charges and weight, multiples of the peer median cost-per-kg) rather than hardcoded constants, so rules stay calibrated instead of either never firing or flooding the queue. Severity is graded: cost-per-kg above 10x the peer median is HIGH, 5-10x is MEDIUM, high absolute value or heavy weight alone is MEDIUM. Two safety mechanisms prevent alert storms: a per-rule cap per run, and BACKPRESSURE - when the open triage queue already exceeds P_QUEUE_LIMIT, detection reports the queue as saturated and creates no new alerts instead of piling on work nobody can process.'
EXECUTE AS CALLER
AS '
DECLARE
    v_p99_charges FLOAT;
    v_p99_weight FLOAT;
    v_p95_cpk FLOAT;
    v_median_cpk FLOAT;
    v_new_alerts NUMBER DEFAULT 0;
    v_high_severity NUMBER DEFAULT 0;
    v_actions_taken NUMBER DEFAULT 0;
    v_cap NUMBER DEFAULT 8;
    v_queue_open NUMBER DEFAULT 0;
    v_throttled BOOLEAN DEFAULT FALSE;
BEGIN
    SELECT COUNT(*) INTO :v_queue_open
    FROM MENDIX_APP.AGENTS.FRAUD_ALERT
    WHERE STATUS = ''OPEN'' AND SEVERITY IN (''HIGH'', ''MEDIUM'') AND BL_ID IS NOT NULL;

    SELECT PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY TOTAL_CHARGES),
           PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY GROSS_WEIGHT_KGS),
           PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY TOTAL_CHARGES / NULLIF(GROSS_WEIGHT_KGS,0)),
           MEDIAN(TOTAL_CHARGES / NULLIF(GROSS_WEIGHT_KGS,0))
    INTO :v_p99_charges, :v_p99_weight, :v_p95_cpk, :v_median_cpk
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING
    WHERE TOTAL_CHARGES IS NOT NULL AND GROSS_WEIGHT_KGS > 0;

    IF (:v_queue_open >= :P_QUEUE_LIMIT) THEN
        v_throttled := TRUE;
    ELSE
        INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_TYPE, SEVERITY, DESCRIPTION, BL_ID, STATUS, CREATED_AT, DETECTED_AT)
        SELECT ''COST_PER_KG_ANOMALY'',
            CASE WHEN TOTAL_CHARGES / GROSS_WEIGHT_KGS > 10 * :v_median_cpk THEN ''HIGH'' ELSE ''MEDIUM'' END,
            ''Cost/kg $'' || ROUND(TOTAL_CHARGES / GROSS_WEIGHT_KGS, 4)
            || '' vs peer median $'' || ROUND(:v_median_cpk, 4)
            || '' ('' || ROUND((TOTAL_CHARGES / GROSS_WEIGHT_KGS) / :v_median_cpk, 1) || ''x) on '' || BL_NUMBER,
            BL_ID, ''OPEN'', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
        FROM MENDIX_APP.AGENTS.BILL_OF_LADING b
        WHERE GROSS_WEIGHT_KGS > 0 AND TOTAL_CHARGES IS NOT NULL
          AND TOTAL_CHARGES / GROSS_WEIGHT_KGS > 5 * :v_median_cpk
          AND NOT EXISTS (SELECT 1 FROM MENDIX_APP.AGENTS.FRAUD_ALERT a WHERE a.BL_ID = b.BL_ID)
        ORDER BY TOTAL_CHARGES / GROSS_WEIGHT_KGS DESC
        LIMIT :v_cap;
        v_new_alerts := SQLROWCOUNT;

        INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_TYPE, SEVERITY, DESCRIPTION, BL_ID, STATUS, CREATED_AT, DETECTED_AT)
        SELECT ''HIGH_VALUE_ANOMALY'',
            CASE WHEN GROSS_WEIGHT_KGS > 0 AND TOTAL_CHARGES / GROSS_WEIGHT_KGS > 10 * :v_median_cpk THEN ''HIGH'' ELSE ''MEDIUM'' END,
            ''Charges $'' || TOTAL_CHARGES || '' exceed the 99th percentile $'' || ROUND(:v_p99_charges)
            || '' on '' || BL_NUMBER,
            BL_ID, ''OPEN'', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
        FROM MENDIX_APP.AGENTS.BILL_OF_LADING b
        WHERE TOTAL_CHARGES > :v_p99_charges
          AND NOT EXISTS (SELECT 1 FROM MENDIX_APP.AGENTS.FRAUD_ALERT a WHERE a.BL_ID = b.BL_ID)
        ORDER BY TOTAL_CHARGES DESC
        LIMIT :v_cap;
        v_new_alerts := :v_new_alerts + SQLROWCOUNT;

        INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_TYPE, SEVERITY, DESCRIPTION, BL_ID, STATUS, CREATED_AT, DETECTED_AT)
        SELECT ''WEIGHT_ANOMALY'', ''MEDIUM'',
            ''Gross weight '' || GROSS_WEIGHT_KGS || ''kg exceeds the 99th percentile ''
            || ROUND(:v_p99_weight) || ''kg on '' || BL_NUMBER,
            BL_ID, ''OPEN'', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
        FROM MENDIX_APP.AGENTS.BILL_OF_LADING b
        WHERE GROSS_WEIGHT_KGS > :v_p99_weight
          AND NOT EXISTS (SELECT 1 FROM MENDIX_APP.AGENTS.FRAUD_ALERT a WHERE a.BL_ID = b.BL_ID)
        ORDER BY GROSS_WEIGHT_KGS DESC
        LIMIT :v_cap;
        v_new_alerts := :v_new_alerts + SQLROWCOUNT;

        INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_TYPE, SEVERITY, DESCRIPTION, BL_ID, STATUS, CREATED_AT, DETECTED_AT)
        SELECT ''SUSPICIOUS_PARTY'', ''HIGH'',
            ''Counterparty name pattern on '' || BL_NUMBER || '': '' || SHIPPER_NAME || '' -> '' || NVL(CONSIGNEE_NAME, ''(none)''),
            BL_ID, ''OPEN'', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
        FROM MENDIX_APP.AGENTS.BILL_OF_LADING b
        WHERE (UPPER(SHIPPER_NAME) LIKE ''%SUSPICIOUS%'' OR UPPER(CONSIGNEE_NAME) LIKE ''%SHELL CORP%''
               OR UPPER(SHIPPER_NAME) LIKE ''%UNKNOWN%'')
          AND NOT EXISTS (SELECT 1 FROM MENDIX_APP.AGENTS.FRAUD_ALERT a WHERE a.BL_ID = b.BL_ID)
        LIMIT :v_cap;
        v_new_alerts := :v_new_alerts + SQLROWCOUNT;

        INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_TYPE, SEVERITY, DESCRIPTION, BL_ID, STATUS, CREATED_AT, DETECTED_AT)
        SELECT ''DOCUMENT_QUALITY'',
            CASE WHEN AI_CONFIDENCE_SCORE <= 50 THEN ''HIGH'' ELSE ''MEDIUM'' END,
            ''AI extraction confidence '' || AI_CONFIDENCE_SCORE::VARCHAR || ''/100 on '' || BL_NUMBER
            || '' - '' || COALESCE(REMARKS, ''ingested from PDF''),
            BL_ID, ''OPEN'', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
        FROM MENDIX_APP.AGENTS.BILL_OF_LADING b
        WHERE AI_CONFIDENCE_SCORE IS NOT NULL AND AI_CONFIDENCE_SCORE < 85
          AND NOT EXISTS (SELECT 1 FROM MENDIX_APP.AGENTS.FRAUD_ALERT a WHERE a.BL_ID = b.BL_ID)
        LIMIT :v_cap;
        v_new_alerts := :v_new_alerts + SQLROWCOUNT;
    END IF;

    SELECT COUNT(*) INTO :v_high_severity FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE SEVERITY = ''HIGH'' AND STATUS = ''OPEN'';

    UPDATE MENDIX_APP.AGENTS.BILL_OF_LADING
    SET STATUS = ''Pending_Review'', FRAUD_CHECK_PASSED = FALSE
    WHERE BL_ID IN (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE SEVERITY = ''HIGH'' AND STATUS = ''OPEN'' AND BL_ID IS NOT NULL)
      AND STATUS NOT IN (''Pending_Review'', ''BLOCKED'');
    v_actions_taken := SQLROWCOUNT;

    INSERT INTO MENDIX_APP.AGENTS.NOTIFICATION_LOG (NOTIFICATION_TYPE, RECIPIENT, SUBJECT, BODY, STATUS)
    SELECT ''WORKFLOW_RUN'', ''system'',
           IFF(:v_throttled, ''Detection throttled - triage queue saturated'', ''Detection scan completed''),
           IFF(:v_throttled,
               ''No new alerts created: open queue '' || :v_queue_open || '' has reached the limit '' || :P_QUEUE_LIMIT || ''.'',
               ''New alerts: '' || :v_new_alerts || ''. Open HIGH severity: '' || :v_high_severity
               || ''. Thresholds - p99 charges $'' || ROUND(:v_p99_charges)
               || '', p99 weight '' || ROUND(:v_p99_weight) || ''kg, median cost/kg $'' || ROUND(:v_median_cpk, 4) || ''.''),
           ''SENT'';

    RETURN ''{"workflow":"DETECT_AND_ACT","status":"COMPLETED"''
        || '',"throttled":'' || IFF(:v_throttled, ''true'', ''false'')
        || '',"queue_open_before":'' || :v_queue_open
        || '',"queue_limit":'' || :P_QUEUE_LIMIT
        || '',"new_alerts":'' || :v_new_alerts
        || '',"high_severity_open":'' || :v_high_severity
        || '',"shipments_flagged":'' || :v_actions_taken
        || '',"thresholds":{"p99_charges":'' || ROUND(:v_p99_charges)
        || '',"p99_weight_kg":'' || ROUND(:v_p99_weight)
        || '',"median_cost_per_kg":'' || ROUND(:v_median_cpk, 4)
        || '',"cost_per_kg_high_multiple":10,"cost_per_kg_medium_multiple":5}''
        || '',"per_rule_cap":'' || :v_cap || ''}'';
END
';

CREATE OR REPLACE PROCEDURE "WORKFLOW_INVESTIGATE_ANOMALY"("P_ALERT_ID" NUMBER(38,0))
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='Skill 3 - AI investigation. Builds a quantitative evidence pack (cost-per-kg vs peer median, live sanctions match count, and - for PDF-ingested shipments - the AI extraction confidence). The cost-per-kg band (over 10x median / 5-10x / at or below 5x) is computed DETERMINISTICALLY IN SQL and handed to the model as a label, because language models are unreliable at numeric threshold comparisons; the model then applies the rubric and weighs contextual evidence (sanctions, counterparty names, document provenance). The decision contract is enforced by a JSON response schema with the decision constrained to an enum, plus one repair retry before falling back to human review. Real token usage returned by Cortex is recorded in AI_CALL_LOG.'
EXECUTE AS CALLER
AS '
DECLARE
    v_alert_type VARCHAR;
    v_bl_id NUMBER;
    v_bl_number VARCHAR;
    v_shipper VARCHAR;
    v_consignee VARCHAR;
    v_charges NUMBER;
    v_weight NUMBER;
    v_carrier VARCHAR;
    v_port_load VARCHAR;
    v_port_discharge VARCHAR;
    v_confidence FLOAT;
    v_cost_per_kg FLOAT;
    v_median_cpk FLOAT;
    v_p95_cpk FLOAT;
    v_cpk_multiple FLOAT;
    v_cpk_band VARCHAR;
    v_band_rule VARCHAR;
    v_sanction_hits NUMBER DEFAULT 0;
    v_doc_context VARCHAR DEFAULT '''';
    v_prompt VARCHAR;
    v_resp VARIANT;
    v_payload VARIANT;
    v_context VARCHAR;
    v_decision VARCHAR;
    v_reason VARCHAR;
    v_assessment VARCHAR;
    v_start_ts TIMESTAMP_NTZ;
    v_elapsed_ms NUMBER;
    v_in_tok NUMBER DEFAULT 0;
    v_out_tok NUMBER DEFAULT 0;
    v_tot_tok NUMBER DEFAULT 0;
    v_attempts NUMBER DEFAULT 0;
    v_contract VARCHAR;
    v_options VARIANT;
BEGIN
    SELECT ALERT_TYPE, BL_ID INTO :v_alert_type, :v_bl_id
    FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :P_ALERT_ID LIMIT 1;

    SELECT BL_NUMBER, SHIPPER_NAME, CONSIGNEE_NAME, TOTAL_CHARGES, GROSS_WEIGHT_KGS, CARRIER_NAME,
           PORT_OF_LOADING_LOCODE, PORT_OF_DISCHARGE_LOCODE, AI_CONFIDENCE_SCORE
    INTO :v_bl_number, :v_shipper, :v_consignee, :v_charges, :v_weight, :v_carrier,
         :v_port_load, :v_port_discharge, :v_confidence
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING WHERE BL_ID = :v_bl_id LIMIT 1;

    v_cost_per_kg := ROUND(:v_charges / NULLIF(:v_weight, 0), 4);

    SELECT ROUND(MEDIAN(TOTAL_CHARGES / NULLIF(GROSS_WEIGHT_KGS,0)),4),
           ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY TOTAL_CHARGES / NULLIF(GROSS_WEIGHT_KGS,0)),4)
    INTO :v_median_cpk, :v_p95_cpk
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING
    WHERE TOTAL_CHARGES IS NOT NULL AND GROSS_WEIGHT_KGS > 0;

    v_cpk_multiple := ROUND(:v_cost_per_kg / NULLIF(:v_median_cpk, 0), 2);

    -- The numeric threshold decision is made here, in SQL, not by the model.
    v_cpk_band := CASE
        WHEN :v_cpk_multiple IS NULL THEN ''NOT_COMPUTABLE''
        WHEN :v_cpk_multiple > 10 THEN ''EXTREME_ABOVE_10X_MEDIAN''
        WHEN :v_cpk_multiple > 5  THEN ''ELEVATED_BETWEEN_5X_AND_10X_MEDIAN''
        ELSE ''NORMAL_AT_OR_BELOW_5X_MEDIAN''
    END;

    v_band_rule := CASE :v_cpk_band
        WHEN ''EXTREME_ABOVE_10X_MEDIAN'' THEN ''This band mandates BLOCK on economics alone.''
        WHEN ''ELEVATED_BETWEEN_5X_AND_10X_MEDIAN'' THEN ''This band mandates ESCALATE for human judgement - it is NOT sufficient for BLOCK.''
        WHEN ''NORMAL_AT_OR_BELOW_5X_MEDIAN'' THEN ''This band is economically ordinary and does NOT justify BLOCK or ESCALATE on its own.''
        ELSE ''Cost per kg could not be computed, which is itself a reason to ESCALATE.''
    END;

    BEGIN
        SELECT COUNT(*) INTO :v_sanction_hits
        FROM MENDIX_APP.AGENTS.V_SANCTIONS_SCREENING_SOURCE
        WHERE UPPER(ENTITY_NAME) LIKE ''%'' || UPPER(NVL(:v_shipper, ''~none~'')) || ''%''
           OR UPPER(ENTITY_NAME) LIKE ''%'' || UPPER(NVL(:v_consignee, ''~none~'')) || ''%'';
    EXCEPTION
        WHEN OTHER THEN v_sanction_hits := -1;
    END;

    BEGIN
        SELECT '' DOCUMENT PROVENANCE: this shipment was created by AI extraction from the PDF ''
               || e.FILE_NAME
               || ''. Extraction confidence '' || COALESCE(e.CONFIDENCE_SCORE::VARCHAR, ''unknown'') || ''/100.''
               || '' Extraction validation result: '' || COALESCE(e.ALERT, ''not recorded'') || ''.''
               || '' Detail: '' || COALESCE(e.ALERT_RESPONSE, ''not recorded'')
        INTO :v_doc_context
        FROM MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED e
        WHERE e.BL_ID = :v_bl_id LIMIT 1;
    EXCEPTION
        WHEN OTHER THEN v_doc_context := '''';
    END;

    v_context := ''Alert type: '' || :v_alert_type
        || ''. BL: '' || :v_bl_number
        || ''. Shipper: '' || NVL(:v_shipper, ''(not stated)'')
        || ''. Consignee: '' || NVL(:v_consignee, ''(not stated)'')
        || ''. Carrier: '' || NVL(:v_carrier, ''(not stated)'')
        || ''. Route: '' || NVL(:v_port_load, ''?'') || '' -> '' || NVL(:v_port_discharge, ''?'')
        || ''. Charges: $'' || NVL(TO_VARCHAR(:v_charges),''not stated'')
        || ''. Weight: '' || NVL(TO_VARCHAR(:v_weight),''not stated'') || ''kg''
        || ''. Cost per kg: $'' || NVL(TO_VARCHAR(:v_cost_per_kg),''not computable'')
        || '' ('' || NVL(TO_VARCHAR(:v_cpk_multiple),''n/a'') || ''x the peer median of $'' || :v_median_cpk || '').''
        || '' PRE-COMPUTED COST-PER-KG BAND: '' || :v_cpk_band || ''. '' || :v_band_rule
        || '' Sanctions/export-restriction list matches for the counterparties: '' || :v_sanction_hits
        || '' (0 = both parties clear, -1 = screening data unavailable).''
        || NVL(:v_doc_context, '''');

    v_prompt := ''You are a maritime logistics fraud and compliance analyst.

The cost-per-kg threshold comparison has ALREADY been computed for you and is given as PRE-COMPUTED COST-PER-KG BAND. Trust that band and the rule stated next to it. Do not re-derive it or substitute your own thresholds.

Apply this rubric:
- BLOCK if sanctions matches > 0, OR the band is EXTREME_ABOVE_10X_MEDIAN, OR a counterparty name indicates a shell/front company (contains SUSPICIOUS, SHELL, UNKNOWN, or is a generic non-identifiable trading name).
- ESCALATE if the band is ELEVATED_BETWEEN_5X_AND_10X_MEDIAN, OR cost per kg was not computable, OR a required commercial figure is missing, OR document provenance reports extraction confidence below 60/100 or a failed validation. An ELEVATED band alone must NOT be blocked.
- CLEAR if sanctions matches = 0 AND the band is NORMAL_AT_OR_BELOW_5X_MEDIAN AND both counterparties are recognisable real businesses AND (if provenance is given) the extraction validated cleanly. A heavy-weight, high-value or duplicate-BL flag alone, with a NORMAL band and clean screening, is a routine data-quality issue and should be CLEARED.

Cite the actual numbers in your reason.
Return: decision (one of BLOCK/ESCALATE/CLEAR), reason (one sentence, max 200 chars, citing the decisive evidence), assessment (a short risk assessment naming the key indicators and their values).

Alert evidence: '' || :v_context;

    v_contract := ''{"type":"json","schema":{"type":"object","properties":{"decision":{"type":"string","enum":["BLOCK","ESCALATE","CLEAR"]},"reason":{"type":"string"},"assessment":{"type":"string"}},"required":["decision","reason","assessment"]}}'';
    v_options := PARSE_JSON(''{"temperature":0,"max_tokens":700,"response_format":'' || :v_contract || ''}'');

    WHILE (:v_attempts < 2 AND :v_decision IS NULL) DO
        v_attempts := :v_attempts + 1;
        v_start_ts := CURRENT_TIMESTAMP();

        BEGIN
            SELECT SNOWFLAKE.CORTEX.COMPLETE(
                       ''mistral-large2'',
                       ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(''role'', ''user'', ''content'', :v_prompt)),
                       :v_options)
            INTO :v_resp;

            v_elapsed_ms := DATEDIFF(''millisecond'', :v_start_ts, CURRENT_TIMESTAMP());
            v_in_tok  := NVL(:v_resp:usage:prompt_tokens::NUMBER, 0);
            v_out_tok := NVL(:v_resp:usage:completion_tokens::NUMBER, 0);
            v_tot_tok := NVL(:v_resp:usage:total_tokens::NUMBER, :v_in_tok + :v_out_tok);

            v_payload := TRY_PARSE_JSON(:v_resp:structured_output[0]:raw_message::STRING);
            v_decision := UPPER(NVL(:v_payload:decision::STRING, ''''));
            IF (:v_decision NOT IN (''BLOCK'', ''ESCALATE'', ''CLEAR'')) THEN
                v_decision := NULL;
            END IF;
            v_reason := :v_payload:reason::STRING;
            v_assessment := :v_payload:assessment::STRING;

            INSERT INTO MENDIX_APP.AGENTS.AI_CALL_LOG
                (CALL_TIMESTAMP, MODEL_NAME, PROCEDURE_NAME, CONTEXT, CALL_STATUS, STATUS,
                 LATENCY_MS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_TOKENS, PROMPT, RESPONSE)
            SELECT CURRENT_TIMESTAMP(), ''mistral-large2'', ''WORKFLOW_INVESTIGATE_ANOMALY'',
                   ''fraud_investigation:attempt'' || :v_attempts,
                   IFF(:v_decision IS NULL, ''PARSE_RETRY'', ''SUCCESS''),
                   IFF(:v_decision IS NULL, ''PARSE_RETRY'', ''SUCCESS''),
                   :v_elapsed_ms, :v_in_tok, :v_out_tok, :v_tot_tok,
                   LEFT(:v_prompt, 5000), LEFT(:v_resp:structured_output[0]:raw_message::STRING, 10000);
        EXCEPTION
            WHEN OTHER THEN
                v_elapsed_ms := DATEDIFF(''millisecond'', :v_start_ts, CURRENT_TIMESTAMP());
                INSERT INTO MENDIX_APP.AGENTS.AI_CALL_LOG
                    (CALL_TIMESTAMP, MODEL_NAME, PROCEDURE_NAME, CONTEXT, CALL_STATUS, STATUS, LATENCY_MS, PROMPT, RESPONSE)
                SELECT CURRENT_TIMESTAMP(), ''mistral-large2'', ''WORKFLOW_INVESTIGATE_ANOMALY'',
                       ''fraud_investigation:attempt'' || :v_attempts, ''ERROR'', ''ERROR'',
                       :v_elapsed_ms, LEFT(:v_prompt, 5000), LEFT(SQLERRM, 1000);
        END;
    END WHILE;

    IF (:v_decision IS NULL) THEN
        v_decision := ''ESCALATE'';
        v_reason := ''AI could not return a valid decision after '' || :v_attempts || '' attempts; routed to human review.'';
        v_assessment := NVL(:v_assessment, ''No assessment returned by the model.'');
    END IF;

    UPDATE MENDIX_APP.AGENTS.FRAUD_ALERT
    SET STATUS = ''INVESTIGATING'',
        AI_RISK_ASSESSMENT = :v_assessment,
        AI_RECOMMENDED_ACTION = :v_decision,
        AI_DECISION_REASON = LEFT(:v_reason, 2000),
        AI_ANALYZED_AT = CURRENT_TIMESTAMP()
    WHERE ALERT_ID = :P_ALERT_ID;

    RETURN ''{"workflow":"INVESTIGATE_ANOMALY","alert_id":'' || :P_ALERT_ID
        || '',"bl_number":"'' || :v_bl_number
        || ''","alert_type":"'' || :v_alert_type
        || ''","cost_per_kg":'' || NVL(TO_VARCHAR(:v_cost_per_kg),''null'')
        || '',"peer_median_cost_per_kg":'' || :v_median_cpk
        || '',"cost_per_kg_multiple_of_median":'' || NVL(TO_VARCHAR(:v_cpk_multiple),''null'')
        || '',"cost_per_kg_band":"'' || :v_cpk_band
        || ''","sanctions_matches":'' || :v_sanction_hits
        || '',"extraction_confidence":'' || NVL(TO_VARCHAR(:v_confidence),''null'')
        || '',"ai_decision":"'' || :v_decision
        || ''","ai_reason":"'' || REPLACE(NVL(:v_reason,''''), ''"'', ''\\"'')
        || ''","attempts":'' || :v_attempts
        || '',"tokens":{"input":'' || :v_in_tok || '',"output":'' || :v_out_tok || '',"total":'' || :v_tot_tok || ''}''
        || '',"ai_assessment":"'' || REPLACE(NVL(:v_assessment,''''), ''"'', ''\\"'') || ''"}'';
END
';

CREATE OR REPLACE PROCEDURE "WORKFLOW_FULL_PIPELINE_V2"("P_MODE" VARCHAR DEFAULT 'AUTO', "P_MAX_ALERTS" NUMBER(38,0) DEFAULT 1)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='End-to-end automation: fraud detection -> AI investigation -> sanctions screening -> AI-decided remediation (BLOCK/ESCALATE/CLEAR) -> SAP posting for cleared shipments. Processes up to P_MAX_ALERTS open alerts per invocation (default 1 for a fast demo, higher to work down a backlog), taking HIGH severity first and then MEDIUM so no severity tier is abandoned in the queue. The remediation action is taken from the AI decision, never hardcoded, and every step records its real duration in WORKFLOW_AUDIT_LOG.EXECUTION_TIME_MS.'
EXECUTE AS CALLER
AS '
DECLARE
    v_start_time TIMESTAMP;
    v_step_start TIMESTAMP;
    v_step_ms NUMBER;
    v_alert_id NUMBER;
    v_severity VARCHAR;
    v_prev_alert_id NUMBER DEFAULT NULL;
    v_shipper VARCHAR;
    v_sap_bl_id NUMBER;
    v_sap_result VARCHAR;
    v_elapsed_ms NUMBER;
    v_ai_action VARCHAR;
    v_ai_reason VARCHAR;
    v_processed NUMBER DEFAULT 0;
    v_blocked NUMBER DEFAULT 0;
    v_escalated NUMBER DEFAULT 0;
    v_cleared NUMBER DEFAULT 0;
    v_sap_posted NUMBER DEFAULT 0;
    v_first_decision VARCHAR DEFAULT NULL;
    v_first_reason VARCHAR DEFAULT NULL;
    v_first_shipper VARCHAR DEFAULT NULL;
    v_first_sap VARCHAR DEFAULT NULL;
    v_alert_ids VARCHAR DEFAULT '''';
    v_max NUMBER;
BEGIN
    v_start_time := CURRENT_TIMESTAMP();
    v_max := GREATEST(NVL(:P_MAX_ALERTS, 1), 1);

    v_step_start := CURRENT_TIMESTAMP();
    CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT();
    v_step_ms := DATEDIFF(''millisecond'', :v_step_start, CURRENT_TIMESTAMP());
    INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
    VALUES (''FULL_PIPELINE_V2'', ''DETECT_ANOMALIES'', 1, :P_MODE || '',max_alerts='' || :v_max, ''Scan completed'', :v_step_ms, ''SUCCESS'');

    LOOP
        IF (:v_processed >= :v_max) THEN
            BREAK;
        END IF;

        v_alert_id := NULL;
        -- HIGH severity is investigated first; MEDIUM is still processed rather than
        -- left to accumulate forever, which is what caused the untouched backlog.
        SELECT ALERT_ID, SEVERITY INTO :v_alert_id, :v_severity
        FROM MENDIX_APP.AGENTS.FRAUD_ALERT
        WHERE STATUS = ''OPEN'' AND SEVERITY IN (''HIGH'', ''MEDIUM'') AND BL_ID IS NOT NULL
        ORDER BY CASE SEVERITY WHEN ''HIGH'' THEN 1 ELSE 2 END, CREATED_AT DESC
        LIMIT 1;

        IF (:v_alert_id IS NULL) THEN
            BREAK;
        END IF;

        IF (:v_prev_alert_id IS NOT NULL AND :v_alert_id = :v_prev_alert_id) THEN
            INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
            VALUES (''FULL_PIPELINE_V2'', ''BATCH_GUARD'', 99, ''alert_id='' || :v_alert_id,
                    ''Stopped: alert did not leave OPEN after remediation'', 0, ''SKIPPED'');
            BREAK;
        END IF;
        v_prev_alert_id := :v_alert_id;

        v_step_start := CURRENT_TIMESTAMP();
        CALL MENDIX_APP.AGENTS.WORKFLOW_INVESTIGATE_ANOMALY(:v_alert_id);
        v_step_ms := DATEDIFF(''millisecond'', :v_step_start, CURRENT_TIMESTAMP());

        SELECT NVL(AI_RECOMMENDED_ACTION, ''ESCALATE''), NVL(AI_DECISION_REASON, ''No AI reason recorded'')
        INTO :v_ai_action, :v_ai_reason
        FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id;

        INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
        VALUES (''FULL_PIPELINE_V2'', ''AI_INVESTIGATE'', 2, ''alert_id='' || :v_alert_id || '',severity='' || :v_severity,
                ''AI decision='' || :v_ai_action || '' | reason='' || :v_ai_reason, :v_step_ms, ''SUCCESS'');

        SELECT SHIPPER_NAME INTO :v_shipper FROM MENDIX_APP.AGENTS.BILL_OF_LADING
        WHERE BL_ID = (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id);

        v_step_start := CURRENT_TIMESTAMP();
        CALL MENDIX_APP.AGENTS.WORKFLOW_SANCTIONS_SCREEN(:v_shipper);
        v_step_ms := DATEDIFF(''millisecond'', :v_step_start, CURRENT_TIMESTAMP());
        INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
        VALUES (''FULL_PIPELINE_V2'', ''SANCTIONS_SCREEN'', 3, :v_shipper, ''Marketplace screening completed'', :v_step_ms, ''SUCCESS'');

        v_step_start := CURRENT_TIMESTAMP();
        CALL MENDIX_APP.AGENTS.WORKFLOW_AUTO_REMEDIATE(:v_alert_id, :v_ai_action);
        v_step_ms := DATEDIFF(''millisecond'', :v_step_start, CURRENT_TIMESTAMP());
        INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
        VALUES (''FULL_PIPELINE_V2'', ''AUTO_REMEDIATE'', 4,
                ''alert_id='' || :v_alert_id || '',action='' || :v_ai_action || '' (decided by AI)'',
                ''Action executed: '' || :v_ai_action || '' | reason='' || :v_ai_reason, :v_step_ms, ''SUCCESS'');

        v_sap_result := ''{"status":"SKIPPED","reason":"SAP posting only runs after a CLEAR decision"}'';
        IF (:v_ai_action = ''CLEAR'') THEN
            SELECT BL_ID INTO :v_sap_bl_id FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id;
            IF (:v_sap_bl_id IS NOT NULL) THEN
                v_step_start := CURRENT_TIMESTAMP();
                CALL MENDIX_APP.AGENTS.SAP_POST_FI_DOCUMENT(:v_sap_bl_id) INTO :v_sap_result;
                v_step_ms := DATEDIFF(''millisecond'', :v_step_start, CURRENT_TIMESTAMP());
                v_sap_posted := :v_sap_posted + 1;
                INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
                VALUES (''FULL_PIPELINE_V2'', ''SAP_POST'', 5, ''bl_id='' || :v_sap_bl_id, :v_sap_result, :v_step_ms, ''SUCCESS'');
            END IF;
        ELSE
            INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
            VALUES (''FULL_PIPELINE_V2'', ''SAP_POST'', 5, ''alert_id='' || :v_alert_id, :v_sap_result, 0, ''SKIPPED'');
        END IF;

        v_processed := :v_processed + 1;
        v_alert_ids := IFF(:v_alert_ids = '''', TO_VARCHAR(:v_alert_id), :v_alert_ids || '','' || :v_alert_id);
        IF (:v_ai_action = ''BLOCK'') THEN
            v_blocked := :v_blocked + 1;
        ELSEIF (:v_ai_action = ''CLEAR'') THEN
            v_cleared := :v_cleared + 1;
        ELSE
            v_escalated := :v_escalated + 1;
        END IF;

        IF (:v_first_decision IS NULL) THEN
            v_first_decision := :v_ai_action;
            v_first_reason := :v_ai_reason;
            v_first_shipper := :v_shipper;
            v_first_sap := :v_sap_result;
        END IF;
    END LOOP;

    IF (:v_processed = 0) THEN
        INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
        VALUES (''FULL_PIPELINE_V2'', ''AI_INVESTIGATE'', 2, ''no_open_alert'',
                ''SKIPPED: no open HIGH or MEDIUM alert to investigate'', 0, ''SKIPPED'');
        v_first_decision := ''NONE'';
        v_first_reason := ''No open alert required a decision in this run.'';
        v_first_shipper := ''n/a'';
        v_first_sap := ''{"status":"SKIPPED","reason":"nothing to process"}'';
    END IF;

    v_elapsed_ms := DATEDIFF(''millisecond'', :v_start_time, CURRENT_TIMESTAMP());

    RETURN ''{"workflow":"FULL_PIPELINE_V2","status":"COMPLETED"''
        || '',"alerts_processed":'' || :v_processed
        || '',"max_alerts":'' || :v_max
        || '',"alert_ids":"'' || :v_alert_ids
        || ''","decisions":{"blocked":'' || :v_blocked || '',"escalated":'' || :v_escalated || '',"cleared":'' || :v_cleared || ''}''
        || '',"sap_documents_posted":'' || :v_sap_posted
        || '',"ai_decision":"'' || :v_first_decision
        || ''","ai_reason":"'' || REPLACE(NVL(:v_first_reason,''''), ''"'', ''\\"'')
        || ''","shipper_screened":"'' || NVL(:v_first_shipper, ''n/a'')
        || ''","sap_posting":'' || :v_first_sap
        || '',"execution_time_ms":'' || :v_elapsed_ms
        || '',"audit_trail":"WORKFLOW_AUDIT_LOG"}'';
END
';

CREATE OR REPLACE PROCEDURE "WORKFLOW_INGEST_AND_DECIDE"()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='Single end-to-end entry point used identically by the CLI (after a batch PUT of PDFs), by the Mendix chat panel, and by Python/Snowpark: extracts every new PDF on the stage, promotes the documents into the operational table, then runs the full fraud/compliance pipeline so the AI reaches a BLOCK/ESCALATE/CLEAR decision on what was just uploaded. Every step records its real wall-clock duration in WORKFLOW_AUDIT_LOG.EXECUTION_TIME_MS.'
EXECUTE AS CALLER
AS '
DECLARE
    v_extract VARCHAR;
    v_sync VARCHAR;
    v_pipeline VARCHAR;
    v_start TIMESTAMP;
    v_step_start TIMESTAMP;
    v_elapsed NUMBER;
    v_step_ms NUMBER;
BEGIN
    v_start := CURRENT_TIMESTAMP();

    v_step_start := CURRENT_TIMESTAMP();
    CALL MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS() INTO :v_extract;
    v_step_ms := DATEDIFF(''millisecond'', :v_step_start, CURRENT_TIMESTAMP());
    INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
    VALUES (''INGEST_AND_DECIDE'', ''EXTRACT_DOCUMENTS'', 1, ''@LOGISTICS_STAGE'', :v_extract, :v_step_ms, ''SUCCESS'');

    v_step_start := CURRENT_TIMESTAMP();
    CALL MENDIX_APP.AGENTS.SYNC_EXTRACTED_TO_BILL_OF_LADING() INTO :v_sync;
    v_step_ms := DATEDIFF(''millisecond'', :v_step_start, CURRENT_TIMESTAMP());
    INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
    VALUES (''INGEST_AND_DECIDE'', ''PROMOTE_TO_OPERATIONAL'', 2, ''BILL_OF_LADING_EXTRACTED'', :v_sync, :v_step_ms, ''SUCCESS'');

    v_step_start := CURRENT_TIMESTAMP();
    CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2(''AUTO'') INTO :v_pipeline;
    v_step_ms := DATEDIFF(''millisecond'', :v_step_start, CURRENT_TIMESTAMP());
    INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
    VALUES (''INGEST_AND_DECIDE'', ''FRAUD_PIPELINE'', 3, ''AUTO'', :v_pipeline, :v_step_ms, ''SUCCESS'');

    v_elapsed := DATEDIFF(''millisecond'', :v_start, CURRENT_TIMESTAMP());

    RETURN ''{"workflow":"INGEST_AND_DECIDE","status":"COMPLETED"''
        || '',"extraction":"'' || REPLACE(:v_extract, ''"'', ''\\"'') || ''"''
        || '',"promotion":'' || :v_sync
        || '',"pipeline":'' || :v_pipeline
        || '',"total_execution_time_ms":'' || :v_elapsed || ''}'';
END
';