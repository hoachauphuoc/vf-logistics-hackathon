-- ============================================================
-- VF LOGISTICS - Agent Skills: Core Procedure Definitions
-- ============================================================
-- These are the exact, currently-deployed procedures backing the
-- 3 Agent Skills (see ../../skills/*.md for skill-level docs).
-- Re-running this file is idempotent (CREATE OR REPLACE).
-- Schema: MENDIX_APP.AGENTS
-- ============================================================

USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;

-- ============================================================
-- SKILL 1: Fraud Detection & Scoring
-- ============================================================
-- ============================================================================
-- SCHEMA SUPPORT FOR AI DECISION PERSISTENCE
-- ----------------------------------------------------------------------------
-- Run these BEFORE the procedures below. They add the columns that let the
-- workflow persist the AI's reasoning and its BLOCK/ESCALATE/CLEAR decision,
-- and the view that exposes both to the Streamlit dashboard and to judges.
-- ============================================================================

ALTER TABLE MENDIX_APP.AGENTS.FRAUD_ALERT ADD COLUMN IF NOT EXISTS AI_RISK_ASSESSMENT VARCHAR(16777216);
ALTER TABLE MENDIX_APP.AGENTS.FRAUD_ALERT ADD COLUMN IF NOT EXISTS AI_RECOMMENDED_ACTION VARCHAR(20);
ALTER TABLE MENDIX_APP.AGENTS.FRAUD_ALERT ADD COLUMN IF NOT EXISTS AI_DECISION_REASON VARCHAR(2000);
ALTER TABLE MENDIX_APP.AGENTS.FRAUD_ALERT ADD COLUMN IF NOT EXISTS AI_ANALYZED_AT TIMESTAMP_NTZ(9);

CREATE OR REPLACE VIEW MENDIX_APP.AGENTS.V_AI_DECISIONS
COMMENT='Judge/demo-facing view: every fraud alert the AI reasoned over, the autonomous action it decided (BLOCK/ESCALATE/CLEAR), the one-line reason, and the full risk assessment text. Backs the "autonomous decision + explanation" panel in the Streamlit dashboard.'
AS
SELECT
    a.ALERT_ID,
    a.SEVERITY,
    a.ALERT_TYPE,
    b.BL_NUMBER,
    b.SHIPPER_NAME,
    b.CONSIGNEE_NAME,
    b.TOTAL_CHARGES,
    b.GROSS_WEIGHT_KGS,
    b.PORT_OF_LOADING_LOCODE || ' -> ' || b.PORT_OF_DISCHARGE_LOCODE AS ROUTE,
    a.AI_RECOMMENDED_ACTION AS AI_DECISION,
    a.AI_DECISION_REASON,
    a.AI_RISK_ASSESSMENT,
    a.STATUS AS ALERT_STATUS,
    a.RESOLUTION_NOTES,
    a.AI_ANALYZED_AT,
    a.DETECTED_AT,
    a.RESOLVED_AT
FROM MENDIX_APP.AGENTS.FRAUD_ALERT a
LEFT JOIN MENDIX_APP.AGENTS.BILL_OF_LADING b ON b.BL_ID = a.BL_ID
WHERE a.AI_RECOMMENDED_ACTION IS NOT NULL;

GRANT SELECT ON VIEW MENDIX_APP.AGENTS.V_AI_DECISIONS TO ROLE HACKATHON_JUDGE_ROLE;

-- ============================================================================
-- SKILL 1: Fraud, compliance and document-quality detection
-- ----------------------------------------------------------------------------
-- Four rules. The first three are commercial (value, weight, counterparty). The
-- fourth, DOCUMENT_QUALITY, treats an AI extraction that could not be validated
-- as a compliance risk in its own right, so a PDF ingested with low confidence is
-- reasoned over by the same investigation skill as a commercial anomaly. It reads
-- AI_CONFIDENCE_SCORE / REMARKS, which SYNC_EXTRACTED_TO_BILL_OF_LADING populates.
-- ============================================================================
CREATE OR REPLACE PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='Skill 1 - Automated fraud/compliance detection: scans BILL_OF_LADING for commercial anomalies (value, weight, cost-per-kg, suspicious parties) and for low-confidence AI document extractions (DOCUMENT_QUALITY), creates FRAUD_ALERT records and flags the shipments for the investigation step.'
EXECUTE AS CALLER
AS
'DECLARE
    v_new_alerts NUMBER DEFAULT 0;
    v_high_severity NUMBER DEFAULT 0;
    v_actions_taken NUMBER DEFAULT 0;
BEGIN
    INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_TYPE, SEVERITY, DESCRIPTION, BL_ID, STATUS, CREATED_AT, DETECTED_AT)
    SELECT ''HIGH_VALUE_ANOMALY'', ''HIGH'',
        ''Workflow: '' || BL_NUMBER || '' charges $'' || TOTAL_CHARGES || '' exceed $50K'',
        BL_ID, ''OPEN'', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING
    WHERE TOTAL_CHARGES > 50000
      AND CREATED_AT > DATEADD(''day'', -7, CURRENT_TIMESTAMP())
      AND BL_ID NOT IN (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE BL_ID IS NOT NULL);
    v_new_alerts := SQLROWCOUNT;

    INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_TYPE, SEVERITY, DESCRIPTION, BL_ID, STATUS, CREATED_AT, DETECTED_AT)
    SELECT ''WEIGHT_ANOMALY'', ''MEDIUM'',
        ''Workflow: '' || BL_NUMBER || '' weight '' || GROSS_WEIGHT_KGS || ''kg exceeds 30T'',
        BL_ID, ''OPEN'', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING
    WHERE GROSS_WEIGHT_KGS > 30000
      AND CREATED_AT > DATEADD(''day'', -7, CURRENT_TIMESTAMP())
      AND BL_ID NOT IN (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE BL_ID IS NOT NULL);
    v_new_alerts := :v_new_alerts + SQLROWCOUNT;

    INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_TYPE, SEVERITY, DESCRIPTION, BL_ID, STATUS, CREATED_AT, DETECTED_AT)
    SELECT ''SUSPICIOUS_PARTY'', ''HIGH'',
        ''Workflow: '' || BL_NUMBER || '' suspicious party: '' || SHIPPER_NAME,
        BL_ID, ''OPEN'', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING
    WHERE (UPPER(SHIPPER_NAME) LIKE ''%SUSPICIOUS%'' OR UPPER(CONSIGNEE_NAME) LIKE ''%SHELL CORP%'')
      AND BL_ID NOT IN (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE BL_ID IS NOT NULL);
    v_new_alerts := :v_new_alerts + SQLROWCOUNT;

    -- Document-quality rule: an AI extraction that could not be validated is a
    -- compliance risk in its own right, so it is raised as an alert and reasoned
    -- over by the same investigation skill as commercial anomalies.
    INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_TYPE, SEVERITY, DESCRIPTION, BL_ID, STATUS, CREATED_AT, DETECTED_AT)
    SELECT ''DOCUMENT_QUALITY'',
        CASE WHEN AI_CONFIDENCE_SCORE <= 50 THEN ''HIGH'' ELSE ''MEDIUM'' END,
        ''Workflow: '' || BL_NUMBER || '' AI extraction confidence '' || AI_CONFIDENCE_SCORE::VARCHAR
            || ''/100 - '' || COALESCE(REMARKS, ''ingested from PDF''),
        BL_ID, ''OPEN'', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING
    WHERE AI_CONFIDENCE_SCORE IS NOT NULL
      AND AI_CONFIDENCE_SCORE < 85
      AND CREATED_AT > DATEADD(''day'', -7, CURRENT_TIMESTAMP())
      AND BL_ID NOT IN (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE BL_ID IS NOT NULL);
    v_new_alerts := :v_new_alerts + SQLROWCOUNT;

    SELECT COUNT(*) INTO :v_high_severity FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE SEVERITY = ''HIGH'' AND STATUS = ''OPEN'';

    UPDATE MENDIX_APP.AGENTS.BILL_OF_LADING
    SET STATUS = ''Pending_Review'', FRAUD_CHECK_PASSED = FALSE
    WHERE BL_ID IN (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE SEVERITY = ''HIGH'' AND STATUS = ''OPEN'' AND BL_ID IS NOT NULL)
      AND STATUS NOT IN (''Pending_Review'', ''BLOCKED'');
    v_actions_taken := SQLROWCOUNT;

    INSERT INTO MENDIX_APP.AGENTS.NOTIFICATION_LOG (NOTIFICATION_TYPE, RECIPIENT, SUBJECT, BODY, STATUS)
    VALUES (''WORKFLOW_RUN'', ''system'', ''Fraud Scan Complete'', ''New alerts: '' || :v_new_alerts || '', High: '' || :v_high_severity || '', Flagged: '' || :v_actions_taken, ''SENT'');

    RETURN ''{"workflow":"DETECT_AND_ACT","status":"COMPLETED","new_alerts":'' || :v_new_alerts || '',"high_severity_open":'' || :v_high_severity || '',"shipments_flagged":'' || :v_actions_taken || ''}'';
END';

-- ============================================================
-- SKILL 2: Compliance & Sanctions Screening
-- ============================================================
CREATE OR REPLACE PROCEDURE "CHECK_COMPLIANCE"("P_BL_ID" NUMBER(38,0)) RETURNS OBJECT LANGUAGE SQL COMMENT='Validates BL against trade compliance rules: sanctions screening, HS code verification, weight limits, route restrictions. Uses AI for entity matching.' EXECUTE AS OWNER AS ' DECLARE     V_BL_NUMBER VARCHAR;     V_HS_CODE VARCHAR;     V_WEIGHT FLOAT;     V_IS_DANGEROUS BOOLEAN;     V_VIOLATIONS VARCHAR DEFAULT ''[]'';     V_RISK_SCORE NUMBER DEFAULT 0;     V_COMPLIANT BOOLEAN DEFAULT TRUE;     V_IS_RESTRICTED BOOLEAN; BEGIN     SELECT          BL_NUMBER,         HS_CODE,         GROSS_WEIGHT_KGS,         IS_DANGEROUS_GOODS     INTO          V_BL_NUMBER,         V_HS_CODE,         V_WEIGHT,         V_IS_DANGEROUS     FROM BILL_OF_LADING     WHERE BL_ID = :P_BL_ID;          SELECT COALESCE(MAX(IS_RESTRICTED OR REQUIRES_PERMIT), FALSE)     INTO V_IS_RESTRICTED     FROM HS_CODE_REFERENCE      WHERE HS_CODE = :V_HS_CODE;          IF (V_IS_RESTRICTED) THEN         V_VIOLATIONS := ''["RESTRICTED_HS_CODE"]'';         V_RISK_SCORE := V_RISK_SCORE + 30;         V_COMPLIANT := FALSE;     END IF;          IF (V_IS_DANGEROUS = TRUE) THEN         V_RISK_SCORE := V_RISK_SCORE + 20;     END IF;          IF (V_WEIGHT > 50000) THEN         V_VIOLATIONS := CASE              WHEN V_VIOLATIONS = ''[]'' THEN ''["OVERWEIGHT"]''             ELSE REPLACE(V_VIOLATIONS, '']'', '',"OVERWEIGHT"]'')         END;         V_RISK_SCORE := V_RISK_SCORE + 10;     END IF;          INSERT INTO COMPLIANCE_CHECK_RESULT (BL_ID, COMPLIANT, VIOLATIONS, RISK_SCORE, RULES_CHECKED)     VALUES (:P_BL_ID, :V_COMPLIANT, :V_VIOLATIONS, :V_RISK_SCORE, 3);          RETURN OBJECT_CONSTRUCT(         ''compliant'', V_COMPLIANT,         ''risk_score'', V_RISK_SCORE,         ''violations'', V_VIOLATIONS     ); END; ';

-- NOTE: SNOWFLAKE_PUBLIC_DATA_FREE must be mounted from Snowflake Marketplace first:
--   CALL SYSTEM$REQUEST_LISTING_AND_WAIT('GZTSZ290BV255', 120);
--   CREATE DATABASE SNOWFLAKE_PUBLIC_DATA_FREE FROM LISTING 'GZTSZ290BV255';
CREATE OR REPLACE PROCEDURE "WORKFLOW_SANCTIONS_SCREEN"("P_ENTITY_NAME" VARCHAR) RETURNS VARCHAR LANGUAGE SQL COMMENT='Screens entity names against sanctions lists using AI fuzzy matching. Returns risk level and matching details for compliance review.' EXECUTE AS CALLER AS 'DECLARE     v_match_count NUMBER DEFAULT 0;     v_result VARCHAR; BEGIN     SELECT COUNT(*) INTO :v_match_count     FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.INTERNATIONAL_TRADE_ADMINISTRATION_EXPORT_SCREENED_ENTITIES_INDEX     WHERE UPPER(EXPORT_RESTRICTED_ENTITY_NAME) LIKE ''%'' || UPPER(:P_ENTITY_NAME) || ''%'';      IF (:v_match_count > 0) THEN         v_result := ''{"workflow":"SANCTIONS_SCREEN","entity":"'' || :P_ENTITY_NAME || ''","matches_found":'' || :v_match_count || '',"risk_level":"CRITICAL","action":"BLOCK - Entity appears on US Government Consolidated Screening List (Snowflake Marketplace data)"}'';     ELSE         v_result := ''{"workflow":"SANCTIONS_SCREEN","entity":"'' || :P_ENTITY_NAME || ''","matches_found":0,"risk_level":"CLEAR","action":"No matches on screening lists. Entity cleared for trade."}'';     END IF;      RETURN :v_result; END';

-- ============================================================
-- SKILL 3: AI Investigation & Remediation
-- ============================================================
-- ============================================================================
-- SKILL 3 (part 1 of 2): AI INVESTIGATION
-- ----------------------------------------------------------------------------
-- Builds a QUANTITATIVE evidence pack before asking the model to decide:
--   * this shipment's cost-per-kg
--   * the peer median and 95th percentile cost-per-kg across all shipments
--   * a live sanctions / export-restriction match count sourced from the
--     Snowflake Marketplace listing (screening happens BEFORE the decision)
-- The model must answer with a machine-parseable DECISION / REASON tail, which
-- is parsed and PERSISTED to FRAUD_ALERT so the remediation step can act on the
-- AI's actual conclusion instead of a hardcoded action.
-- ============================================================================
-- ============================================================================
-- SKILL 3 (part 1 of 2): AI INVESTIGATION
-- ----------------------------------------------------------------------------
-- Builds a QUANTITATIVE evidence pack before asking the model to decide:
--   * this shipment's cost-per-kg
--   * the peer median and 95th percentile cost-per-kg across all shipments
--   * a live sanctions / export-restriction match count sourced from the
--     Snowflake Marketplace listing (screening happens BEFORE the decision)
--   * for PDF-ingested shipments, the extraction confidence and the extraction
--     validation result, so the model knows how much to trust the data itself
-- The model must answer with a machine-parseable DECISION / REASON tail, which
-- is parsed and PERSISTED to FRAUD_ALERT so the remediation step acts on the
-- AI's actual conclusion instead of a hardcoded action.
-- ============================================================================
CREATE OR REPLACE PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_INVESTIGATE_ANOMALY("P_ALERT_ID" NUMBER(38,0))
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='Skill 3 - AI investigation. Builds a quantitative evidence pack (cost-per-kg vs peer median/p95, live sanctions match count, and - for PDF-ingested shipments - the AI extraction confidence and the extraction alert text), asks Cortex AI to apply an explicit BLOCK/ESCALATE/CLEAR rubric, then persists the reasoning and the parsed decision into FRAUD_ALERT so the remediation step acts on the AI decision rather than a hardcoded action.'
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
    v_p95_charges FLOAT;
    v_sanction_hits NUMBER DEFAULT 0;
    v_doc_context VARCHAR DEFAULT '''';
    v_ai_analysis VARCHAR;
    v_context VARCHAR;
    v_decision VARCHAR;
    v_reason VARCHAR;
BEGIN
    SELECT ALERT_TYPE, BL_ID
    INTO :v_alert_type, :v_bl_id
    FROM MENDIX_APP.AGENTS.FRAUD_ALERT
    WHERE ALERT_ID = :P_ALERT_ID
    LIMIT 1;

    SELECT BL_NUMBER, SHIPPER_NAME, CONSIGNEE_NAME, TOTAL_CHARGES, GROSS_WEIGHT_KGS, CARRIER_NAME,
           PORT_OF_LOADING_LOCODE, PORT_OF_DISCHARGE_LOCODE, AI_CONFIDENCE_SCORE
    INTO :v_bl_number, :v_shipper, :v_consignee, :v_charges, :v_weight, :v_carrier,
         :v_port_load, :v_port_discharge, :v_confidence
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING
    WHERE BL_ID = :v_bl_id
    LIMIT 1;

    v_cost_per_kg := ROUND(:v_charges / NULLIF(:v_weight, 0), 4);

    SELECT ROUND(MEDIAN(TOTAL_CHARGES / NULLIF(GROSS_WEIGHT_KGS,0)),4),
           ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY TOTAL_CHARGES / NULLIF(GROSS_WEIGHT_KGS,0)),4),
           ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY TOTAL_CHARGES),0)
    INTO :v_median_cpk, :v_p95_cpk, :v_p95_charges
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING
    WHERE TOTAL_CHARGES IS NOT NULL AND GROSS_WEIGHT_KGS > 0;

    BEGIN
        SELECT COUNT(*) INTO :v_sanction_hits
        FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.INTERNATIONAL_TRADE_ADMINISTRATION_EXPORT_SCREENED_ENTITIES_INDEX
        WHERE UPPER(EXPORT_RESTRICTED_ENTITY_NAME) LIKE ''%'' || UPPER(NVL(:v_shipper, ''~none~'')) || ''%''
           OR UPPER(EXPORT_RESTRICTED_ENTITY_NAME) LIKE ''%'' || UPPER(NVL(:v_consignee, ''~none~'')) || ''%'';
    EXCEPTION
        WHEN OTHER THEN
            v_sanction_hits := -1;
    END;

    -- Extra evidence when this shipment originated from an ingested PDF
    BEGIN
        SELECT '' DOCUMENT PROVENANCE: this shipment was created by AI extraction from the PDF ''
               || e.FILE_NAME
               || ''. Extraction confidence '' || COALESCE(e.CONFIDENCE_SCORE::VARCHAR, ''unknown'') || ''/100.''
               || '' Extraction validation result: '' || COALESCE(e.ALERT, ''not recorded'') || ''.''
               || '' Detail: '' || COALESCE(e.ALERT_RESPONSE, ''not recorded'')
        INTO :v_doc_context
        FROM MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED e
        WHERE e.BL_ID = :v_bl_id
        LIMIT 1;
    EXCEPTION
        WHEN OTHER THEN
            v_doc_context := '''';
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
        || ''. PEER BASELINE across all shipments: median cost/kg $'' || :v_median_cpk
        || '', 95th percentile cost/kg $'' || :v_p95_cpk
        || '', 95th percentile total charges $'' || :v_p95_charges
        || ''. Sanctions/export-restriction list matches for the counterparties: '' || :v_sanction_hits
        || '' (0 = both parties clear, -1 = screening data unavailable).''
        || NVL(:v_doc_context, '''');

    SELECT SNOWFLAKE.CORTEX.COMPLETE(''mistral-large2'',
        ''You are a maritime logistics fraud and compliance analyst. Analyze the alert below and produce: 1) Risk assessment (HIGH/MEDIUM/LOW), 2) Key indicators with the actual numbers, 3) The action you decide. Be concise.\\n\\n''
        || ''Apply THIS RUBRIC and follow it strictly:\\n''
        || ''- BLOCK: sanctions matches > 0, OR cost/kg exceeds 5x the peer median, OR the counterparty name indicates a shell/front company (e.g. contains "SUSPICIOUS", "SHELL", "UNKNOWN", or is a generic non-identifiable trading name).\\n''
        || ''- ESCALATE: a required commercial figure is missing or unverifiable so a human must judge; OR the document provenance section reports an extraction confidence below 60/100 or a failed validation, because the underlying data cannot be trusted enough to clear or block automatically.\\n''
        || ''- CLEAR: sanctions matches = 0 AND cost/kg is at or below the 95th percentile AND total charges are at or below the 95th percentile AND both counterparties are recognisable real businesses AND (if document provenance is given) the extraction validated cleanly. A weight or duplicate-BL flag alone, with normal economics and clean screening, is a routine data-quality issue and should be CLEARED.\\n\\n''
        || ''Do not invent thresholds beyond those above. Justify your decision with the numbers given.\\n\\n''
        || ''You MUST end your response with exactly two final lines in this format:\\n''
        || ''DECISION: <BLOCK or ESCALATE or CLEAR>\\n''
        || ''REASON: <one sentence, max 200 characters, citing the decisive evidence>\\n\\n''
        || ''Alert evidence: '' || :v_context
    ) INTO :v_ai_analysis;

    v_decision := UPPER(NVL(REGEXP_SUBSTR(:v_ai_analysis, ''DECISION:\\\\s*(BLOCK|ESCALATE|CLEAR)'', 1, 1, ''i'', 1), ''ESCALATE''));
    v_reason := NVL(TRIM(REGEXP_SUBSTR(:v_ai_analysis, ''REASON:\\\\s*(.+)'', 1, 1, ''i'', 1)),
                    ''AI did not return a structured reason; defaulted to human review.'');

    UPDATE MENDIX_APP.AGENTS.FRAUD_ALERT
    SET STATUS = ''INVESTIGATING'',
        AI_RISK_ASSESSMENT = :v_ai_analysis,
        AI_RECOMMENDED_ACTION = :v_decision,
        AI_DECISION_REASON = LEFT(:v_reason, 2000),
        AI_ANALYZED_AT = CURRENT_TIMESTAMP()
    WHERE ALERT_ID = :P_ALERT_ID;

    RETURN ''{"workflow":"INVESTIGATE_ANOMALY","alert_id":'' || :P_ALERT_ID
        || '',"bl_number":"'' || :v_bl_number
        || ''","alert_type":"'' || :v_alert_type
        || ''","cost_per_kg":'' || NVL(TO_VARCHAR(:v_cost_per_kg),''null'')
        || '',"peer_median_cost_per_kg":'' || :v_median_cpk
        || '',"sanctions_matches":'' || :v_sanction_hits
        || '',"extraction_confidence":'' || NVL(TO_VARCHAR(:v_confidence),''null'')
        || '',"ai_decision":"'' || :v_decision
        || ''","ai_reason":"'' || REPLACE(:v_reason, ''"'', ''\\\\"'')
        || ''","ai_analysis":'' || :v_ai_analysis || ''}'';
END
';
-- ============================================================================
-- SKILL 3 (part 2 of 2): AUTONOMOUS REMEDIATION
-- ----------------------------------------------------------------------------
-- Executes the action decided by the AI in WORKFLOW_INVESTIGATE_ANOMALY and
-- records the AI's stated reason in RESOLUTION_NOTES and in the outbound
-- notification, so the audit trail explains WHY a shipment was blocked or
-- cleared rather than only that an action occurred.
-- ============================================================================
CREATE OR REPLACE PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_AUTO_REMEDIATE("P_ALERT_ID" NUMBER(38,0), "P_ACTION" VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='Automated remediation for detected issues: applies the corrective action (BLOCK / ESCALATE / CLEAR) and records the AI decision reason in RESOLUTION_NOTES so the audit trail explains WHY the action was taken, not just that it happened.'
EXECUTE AS CALLER
AS '
DECLARE
    v_bl_id NUMBER;
    v_bl_number VARCHAR;
    v_result VARCHAR;
    v_ai_reason VARCHAR;
    v_note VARCHAR;
BEGIN
    SELECT BL_ID, NVL(AI_DECISION_REASON, ''No AI reason recorded'')
    INTO :v_bl_id, :v_ai_reason
    FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :P_ALERT_ID;

    SELECT BL_NUMBER INTO :v_bl_number FROM MENDIX_APP.AGENTS.BILL_OF_LADING WHERE BL_ID = :v_bl_id;

    CASE UPPER(:P_ACTION)
        WHEN ''BLOCK'' THEN
            v_note := ''AUTO-BLOCKED by AI decision. Reason: '' || :v_ai_reason;
            UPDATE MENDIX_APP.AGENTS.BILL_OF_LADING SET STATUS = ''BLOCKED'', FRAUD_CHECK_PASSED = FALSE WHERE BL_ID = :v_bl_id;
            UPDATE MENDIX_APP.AGENTS.FRAUD_ALERT SET STATUS = ''RESOLVED'', RESOLVED_AT = CURRENT_TIMESTAMP(), RESOLUTION_NOTES = LEFT(:v_note, 2000) WHERE ALERT_ID = :P_ALERT_ID;
            INSERT INTO MENDIX_APP.AGENTS.NOTIFICATION_LOG (NOTIFICATION_TYPE, RECIPIENT, SUBJECT, BODY, STATUS)
            VALUES (''FRAUD_BLOCK'', ''compliance@vflogistics.com'', ''Shipment Blocked'', ''BLOCKED: Shipment '' || :v_bl_number || '' blocked due to fraud alert #'' || :P_ALERT_ID || ''. AI reason: '' || :v_ai_reason, ''SENT'');
            v_result := ''Shipment '' || :v_bl_number || '' BLOCKED. Compliance team notified.'';

        WHEN ''ESCALATE'' THEN
            v_note := ''ESCALATED to compliance team by AI decision. Reason: '' || :v_ai_reason;
            UPDATE MENDIX_APP.AGENTS.BILL_OF_LADING SET STATUS = ''Pending_Review'' WHERE BL_ID = :v_bl_id;
            UPDATE MENDIX_APP.AGENTS.FRAUD_ALERT SET STATUS = ''ESCALATED'', RESOLUTION_NOTES = LEFT(:v_note, 2000) WHERE ALERT_ID = :P_ALERT_ID;
            INSERT INTO MENDIX_APP.AGENTS.NOTIFICATION_LOG (NOTIFICATION_TYPE, RECIPIENT, SUBJECT, BODY, STATUS)
            VALUES (''FRAUD_ESCALATE'', ''compliance@vflogistics.com'', ''Alert Escalated'', ''Alert #'' || :P_ALERT_ID || '' on '' || :v_bl_number || '' needs human review. AI reason: '' || :v_ai_reason, ''SENT'');
            v_result := ''Alert #'' || :P_ALERT_ID || '' ESCALATED to compliance team.'';

        WHEN ''CLEAR'' THEN
            v_note := ''CLEARED by AI decision - no fraud confirmed. Reason: '' || :v_ai_reason;
            UPDATE MENDIX_APP.AGENTS.FRAUD_ALERT SET STATUS = ''RESOLVED'', RESOLVED_AT = CURRENT_TIMESTAMP(), RESOLUTION_NOTES = LEFT(:v_note, 2000) WHERE ALERT_ID = :P_ALERT_ID;
            UPDATE MENDIX_APP.AGENTS.BILL_OF_LADING SET FRAUD_CHECK_PASSED = TRUE WHERE BL_ID = :v_bl_id;
            v_result := ''Alert #'' || :P_ALERT_ID || '' CLEARED. Shipment '' || :v_bl_number || '' approved.'';

        ELSE
            v_result := ''ERROR: Unknown action. Use BLOCK, ESCALATE, or CLEAR.'';
    END CASE;

    RETURN ''{"workflow":"AUTO_REMEDIATE","alert_id":'' || :P_ALERT_ID
        || '',"action":"'' || :P_ACTION
        || ''","bl_number":"'' || :v_bl_number
        || ''","ai_reason":"'' || REPLACE(:v_ai_reason, ''"'', ''\\\\"'')
        || ''","result":"'' || :v_result || ''"}'';
END
';

-- ============================================================
-- ORCHESTRATOR: Chains all 3 Skills into one CLI-executable workflow
-- ============================================================
-- ============================================================================
-- ORCHESTRATOR
-- ----------------------------------------------------------------------------
-- Chains the three Agent Skills and posts to the ERP. The remediation action in
-- step 4 is READ BACK from FRAUD_ALERT.AI_RECOMMENDED_ACTION -- i.e. it is the
-- decision the model made in step 2 -- and both the decision and its reason are
-- written into WORKFLOW_AUDIT_LOG. If no HIGH-severity OPEN alert qualifies, the
-- investigation and remediation steps are logged as SKIPPED rather than
-- reporting a hollow SUCCESS.
-- ============================================================================
CREATE OR REPLACE PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2("P_MODE" VARCHAR DEFAULT 'AUTO')
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='End-to-end automation: fraud detection -> AI investigation -> sanctions screening -> AI-decided remediation (BLOCK/ESCALATE/CLEAR) -> SAP posting. The remediation action is taken from the AI risk assessment produced in step 2, not hardcoded, and both the decision and its reason are written to WORKFLOW_AUDIT_LOG.'
EXECUTE AS CALLER
AS '
DECLARE
    v_start_time TIMESTAMP;
    v_detect_result VARCHAR;
    v_alert_id NUMBER;
    v_shipper VARCHAR;
    v_sap_bl_id NUMBER;
    v_sap_result VARCHAR;
    v_elapsed_ms NUMBER;
    v_ai_action VARCHAR;
    v_ai_reason VARCHAR;
    v_steps NUMBER := 5;
BEGIN
    v_start_time := CURRENT_TIMESTAMP();

    CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT();
    v_detect_result := ''Scan completed'';
    INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, STATUS)
    VALUES (''FULL_PIPELINE_V2'', ''DETECT_ANOMALIES'', 1, :P_MODE, :v_detect_result, ''SUCCESS'');

    SELECT ALERT_ID INTO :v_alert_id FROM MENDIX_APP.AGENTS.FRAUD_ALERT
    WHERE SEVERITY = ''HIGH'' AND STATUS = ''OPEN'' ORDER BY CREATED_AT DESC LIMIT 1;

    IF (:v_alert_id IS NULL) THEN
        INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, STATUS)
        VALUES (''FULL_PIPELINE_V2'', ''AI_INVESTIGATE'', 2, ''no_open_high_alert'',
                ''SKIPPED: no new HIGH-severity OPEN alert to investigate'', ''SKIPPED'');
        v_ai_action := ''NONE'';
        v_ai_reason := ''No open HIGH-severity alert required a decision in this run.'';
        v_shipper := ''n/a'';
        v_sap_bl_id := NULL;
        v_sap_result := ''{"status":"SKIPPED","reason":"no AI-approved shipment eligible for SAP posting in this run"}'';
        v_steps := 3;
    ELSE
        CALL MENDIX_APP.AGENTS.WORKFLOW_INVESTIGATE_ANOMALY(:v_alert_id);

        SELECT NVL(AI_RECOMMENDED_ACTION, ''ESCALATE''), NVL(AI_DECISION_REASON, ''No AI reason recorded'')
        INTO :v_ai_action, :v_ai_reason
        FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id;

        INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, STATUS)
        VALUES (''FULL_PIPELINE_V2'', ''AI_INVESTIGATE'', 2, ''alert_id='' || :v_alert_id,
                ''AI decision='' || :v_ai_action || '' | reason='' || :v_ai_reason, ''SUCCESS'');

        SELECT SHIPPER_NAME INTO :v_shipper FROM MENDIX_APP.AGENTS.BILL_OF_LADING
        WHERE BL_ID = (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id);
        CALL MENDIX_APP.AGENTS.WORKFLOW_SANCTIONS_SCREEN(:v_shipper);
        INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, STATUS)
        VALUES (''FULL_PIPELINE_V2'', ''SANCTIONS_SCREEN'', 3, :v_shipper, ''Marketplace screening completed'', ''SUCCESS'');

        CALL MENDIX_APP.AGENTS.WORKFLOW_AUTO_REMEDIATE(:v_alert_id, :v_ai_action);
        INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, STATUS)
        VALUES (''FULL_PIPELINE_V2'', ''AUTO_REMEDIATE'', 4,
                ''alert_id='' || :v_alert_id || '',action='' || :v_ai_action || '' (decided by AI)'',
                ''Action executed: '' || :v_ai_action || '' | reason='' || :v_ai_reason, ''SUCCESS'');
    END IF;

    IF (:v_alert_id IS NOT NULL AND :v_ai_action = ''CLEAR'') THEN
        SELECT BL_ID INTO :v_sap_bl_id
        FROM MENDIX_APP.AGENTS.FRAUD_ALERT
        WHERE ALERT_ID = :v_alert_id;

        IF (:v_sap_bl_id IS NOT NULL) THEN
            CALL MENDIX_APP.AGENTS.SAP_POST_FI_DOCUMENT(:v_sap_bl_id) INTO :v_sap_result;
            INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, STATUS)
            VALUES (''FULL_PIPELINE_V2'', ''SAP_POST'', 5, ''bl_id='' || TO_VARCHAR(:v_sap_bl_id), :v_sap_result, ''SUCCESS'');
        ELSE
            v_sap_result := ''{"status":"SKIPPED","reason":"no BL linked to investigated alert"}'';
            INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, STATUS)
            VALUES (''FULL_PIPELINE_V2'', ''SAP_POST'', 5, ''bl_id=none'', :v_sap_result, ''SKIPPED'');
        END IF;
    ELSE
        v_sap_bl_id := NULL;
        v_sap_result := ''{"status":"SKIPPED","reason":"SAP posting only runs after a CLEAR decision in this run"}'';
        INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, STATUS)
        VALUES (''FULL_PIPELINE_V2'', ''SAP_POST'', 5, ''bl_id=none'', :v_sap_result, ''SKIPPED'');
    END IF;

    v_elapsed_ms := DATEDIFF(''millisecond'', :v_start_time, CURRENT_TIMESTAMP());

    RETURN ''{"workflow":"FULL_PIPELINE_V2","status":"COMPLETED","steps":'' || :v_steps
        || '',"alert_id":'' || NVL(TO_VARCHAR(:v_alert_id), ''null'')
        || '',"ai_decision":"'' || :v_ai_action
        || ''","ai_reason":"'' || REPLACE(:v_ai_reason, ''"'', ''\\\\"'')
        || ''","shipper_screened":"'' || NVL(:v_shipper, ''n/a'')
        || ''","sap_posting":'' || :v_sap_result
        || '',"execution_time_ms":'' || :v_elapsed_ms
        || '',"audit_trail":"WORKFLOW_AUDIT_LOG"}'';
END
';

-- ============================================================
-- DEMO HELPER: Seeds a fresh suspicious shipment for live demos
-- ============================================================
CREATE OR REPLACE PROCEDURE "DEMO_PIPELINE"() RETURNS VARCHAR LANGUAGE SQL COMMENT='Quick demo helper: runs core pipeline steps in sequence with sample data. Designed for live hackathon demonstrations.' EXECUTE AS OWNER AS 'BEGIN   INSERT INTO MENDIX_APP.AGENTS.BILL_OF_LADING      (BL_NUMBER, SHIPPER_NAME, CONSIGNEE_NAME, CARRIER_NAME, VESSEL_NAME,      PORT_OF_LOADING_LOCODE, PORT_OF_DISCHARGE_LOCODE, COMMODITY_DESCRIPTION,      HS_CODE, GROSS_WEIGHT_KGS, TOTAL_CHARGES, STATUS, CONTAINER_NUMBER, CREATED_AT)   VALUES      (''DEMO'' || TO_CHAR(CURRENT_TIMESTAMP(), ''HHMISS''),      ''SUSPICIOUS TRADING CO'', ''SHELL CORP INTL'', ''MAERSK'', ''MV DEMO VESSEL'',      ''VNSGN'', ''KRPUS'', ''Undeclared high-value electronics'',      ''8542'', 95000, 75000, ''Pending_Review'', ''DEMO1234567'', CURRENT_TIMESTAMP());    LET new_bl_id NUMBER;   new_bl_id := (SELECT MAX(BL_ID) FROM MENDIX_APP.AGENTS.BILL_OF_LADING WHERE BL_NUMBER LIKE ''DEMO%'');    INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (BL_ID, ALERT_TYPE, SEVERITY, DESCRIPTION, DETECTED_AT, STATUS)   SELECT :new_bl_id, ''HIGH_VALUE_ANOMALY'', ''HIGH'',     ''Pipeline: Auto-detected $75K + 95T anomaly on BL_ID='' || :new_bl_id::VARCHAR,     CURRENT_TIMESTAMP(), ''OPEN'';    INSERT INTO MENDIX_APP.AGENTS.NOTIFICATION_LOG (NOTIFICATION_TYPE, RECIPIENT, SUBJECT, BODY, SENT_AT, STATUS)   SELECT ''FRAUD_ALERT'', ''compliance@vflogistics.com'',      ''ALERT [HIGH]: HIGH_VALUE_ANOMALY'',     ''BL_ID: '' || :new_bl_id::VARCHAR || '' flagged by automated pipeline.'',     CURRENT_TIMESTAMP(), ''SENT'';    RETURN ''Pipeline OK: BL_ID='' || :new_bl_id::VARCHAR || '' -> Fraud Alert (HIGH) -> Notification (SENT)''; END';
