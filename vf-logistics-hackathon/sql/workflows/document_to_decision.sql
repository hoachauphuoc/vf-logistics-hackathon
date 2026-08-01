-- ============================================================================
-- DOCUMENT TO DECISION -- bridging document intelligence into the fraud agent
-- ----------------------------------------------------------------------------
-- Run this file after `agent_skills_procedures.sql`.
--
-- WHY THIS EXISTS
-- The prototype originally had two halves that never touched each other:
--
--   (A) document intelligence : PDF -> @LOGISTICS_STAGE -> PROCESS_BL_DOCUMENTS
--                               -> BILL_OF_LADING_EXTRACTED -> Mendix review
--   (B) the fraud agent       : BILL_OF_LADING -> WORKFLOW_DETECT_AND_ACT
--                               -> FRAUD_ALERT -> AI investigation -> decision
--
-- Nothing promoted a document from (A) into (B), so an uploaded PDF could never
-- reach a decision, and the extraction never captured the commercial fields the
-- detection rules need (shipper, consignee, freight charges were always NULL).
--
-- This file closes that gap:
--   1. extra columns on BILL_OF_LADING_EXTRACTED to track promotion
--   2. SYNC_EXTRACTED_TO_BILL_OF_LADING -- the bridge
--   3. WORKFLOW_INGEST_AND_DECIDE       -- one command: extract -> promote -> decide
--   4. TASK_PROCESS_NEW_BL retargeted   -- the same flow, fully autonomous
--
-- The extended PROCESS_BL_DOCUMENTS (which now extracts the commercial fields
-- and refreshes the stage directory) and the DOCUMENT_QUALITY detection rule in
-- WORKFLOW_DETECT_AND_ACT live in their own files/sections.
-- ============================================================================


-- 1. Promotion bookkeeping ---------------------------------------------------
ALTER TABLE MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED ADD COLUMN IF NOT EXISTS CARRIER_NAME VARCHAR(200);
ALTER TABLE MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED ADD COLUMN IF NOT EXISTS SYNCED_TO_BL_AT TIMESTAMP_NTZ(9);
ALTER TABLE MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED ADD COLUMN IF NOT EXISTS BL_ID NUMBER(38,0);


-- 2. The bridge --------------------------------------------------------------
-- Note the two defects this had to handle, both found by running it for real:
--   * free-text ports ("CAT LAI PORT, HO CHI MINH CITY, VIETNAM (VNSGN)") do not
--     fit PORT_OF_*_LOCODE (10 chars), so the UN/LOCODE in parentheses is
--     extracted and every text column is explicitly truncated to its width;
--   * promotion must be idempotent, so SYNCED_TO_BL_AT / BL_ID record the link.
CREATE OR REPLACE PROCEDURE MENDIX_APP.AGENTS.SYNC_EXTRACTED_TO_BILL_OF_LADING()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='Bridge between the two halves of the system: promotes newly extracted PDF documents from BILL_OF_LADING_EXTRACTED into the operational BILL_OF_LADING table, which is what the fraud/compliance skills scan. Normalises free-text ports to a UN/LOCODE, truncates to the operational column widths, and carries the extraction confidence and AI alert text across so the DOCUMENT_QUALITY rule and the AI investigation can use them. Idempotent: each document is promoted once (tracked by SYNCED_TO_BL_AT / BL_ID).'
EXECUTE AS CALLER
AS
'DECLARE
    v_promoted NUMBER := 0;
BEGIN
    LET doc_cursor CURSOR FOR (
        SELECT DOC_ID
        FROM MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED
        WHERE SYNCED_TO_BL_AT IS NULL
        ORDER BY DOC_ID
    );

    FOR d IN doc_cursor DO
        LET v_doc_id NUMBER := d.DOC_ID;
        LET v_bl_id NUMBER;

        INSERT INTO MENDIX_APP.AGENTS.BILL_OF_LADING (
            BL_NUMBER, SHIPPER_NAME, CONSIGNEE_NAME, NOTIFY_PARTY,
            PORT_OF_LOADING_LOCODE, PORT_OF_DISCHARGE_LOCODE,
            PLACE_OF_RECEIPT, PLACE_OF_DELIVERY,
            VESSEL_NAME, VOYAGE_NUMBER, CONTAINER_NUMBER,
            HS_CODE, COMMODITY_DESCRIPTION, PACKAGE_COUNT, PACKAGE_TYPE,
            GROSS_WEIGHT_KGS, FREIGHT_AMOUNT, CURRENCY_CODE, TOTAL_CHARGES,
            CARRIER_NAME, BL_DATE, CREATED_AT, STATUS, SYNCED_TO_ERP,
            AI_CONFIDENCE_SCORE, PROCESSED_AT, REMARKS
        )
        SELECT
            LEFT(COALESCE(NULLIF(TRIM(e.BL_NUMBER), ''''), ''DOC-'' || e.DOC_ID::VARCHAR), 50),
            LEFT(e.SHIPPER_NAME, 200), LEFT(e.CONSIGNEE_NAME, 200), LEFT(e.NOTIFY_PARTY, 200),
            LEFT(COALESCE(REGEXP_SUBSTR(e.PORT_OF_LOADING, ''\\\\(([A-Z]{5})\\\\)'', 1, 1, ''e'', 1), e.PORT_OF_LOADING), 10),
            LEFT(COALESCE(REGEXP_SUBSTR(e.PORT_OF_DISCHARGE, ''\\\\(([A-Z]{5})\\\\)'', 1, 1, ''e'', 1), e.PORT_OF_DISCHARGE), 10),
            LEFT(e.PORT_OF_LOADING, 100), LEFT(e.PORT_OF_DISCHARGE, 100),
            LEFT(e.VESSEL_NAME, 100), LEFT(e.VOYAGE_NUMBER, 50), LEFT(e.CONTAINER_NUMBER, 15),
            LEFT(e.HS_CODE, 10), LEFT(e.COMMODITY_DESC, 1000), e.PACKAGE_COUNT, LEFT(e.PACKAGE_TYPE, 50),
            e.GROSS_WEIGHT_KG, e.FREIGHT_CHARGES, LEFT(NVL(e.FREIGHT_CURRENCY, ''USD''), 5), e.FREIGHT_CHARGES,
            LEFT(e.CARRIER_NAME, 100), e.DATE_OF_ISSUE, CURRENT_TIMESTAMP(),
            CASE WHEN e.STATUS IN (''AI_Processed'', ''Synced_To_SAP'') THEN ''APPROVED'' ELSE ''Pending_Review'' END,
            (e.STATUS = ''Synced_To_SAP''),
            e.CONFIDENCE_SCORE, e.PROCESSED_AT,
            LEFT(''Ingested from PDF '' || e.FILE_NAME
                || COALESCE('' | AI extraction alert: '' || NULLIF(e.ALERT, ''No anomalies detected''), ''''), 2000)
        FROM MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED e
        WHERE e.DOC_ID = :v_doc_id;

        SELECT MAX(BL_ID) INTO :v_bl_id FROM MENDIX_APP.AGENTS.BILL_OF_LADING;

        UPDATE MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED
        SET SYNCED_TO_BL_AT = CURRENT_TIMESTAMP(), BL_ID = :v_bl_id
        WHERE DOC_ID = :v_doc_id;

        v_promoted := :v_promoted + 1;
    END FOR;

    RETURN ''{"procedure":"SYNC_EXTRACTED_TO_BILL_OF_LADING","documents_promoted":'' || :v_promoted
        || '',"target":"MENDIX_APP.AGENTS.BILL_OF_LADING"}'';
END';


-- 3. One command for every interface -----------------------------------------
-- The CLI (after a batch PUT), the Mendix chat panel and Python/Snowpark all
-- call exactly this, so all three surfaces execute identical logic.
CREATE OR REPLACE PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='Single end-to-end entry point used identically by the CLI (after a batch PUT of PDFs), by the Mendix chat panel, and by Python/Snowpark: extracts every new PDF on the stage, promotes the documents into the operational table, then runs the full fraud/compliance pipeline so the AI reaches a BLOCK/ESCALATE/CLEAR decision on what was just uploaded.'
EXECUTE AS CALLER
AS
'DECLARE
    v_extract VARCHAR;
    v_sync VARCHAR;
    v_pipeline VARCHAR;
    v_start TIMESTAMP;
    v_elapsed NUMBER;
BEGIN
    v_start := CURRENT_TIMESTAMP();

    CALL MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS() INTO :v_extract;
    INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, STATUS)
    VALUES (''INGEST_AND_DECIDE'', ''EXTRACT_DOCUMENTS'', 1, ''@LOGISTICS_STAGE'', :v_extract, ''SUCCESS'');

    CALL MENDIX_APP.AGENTS.SYNC_EXTRACTED_TO_BILL_OF_LADING() INTO :v_sync;
    INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, STATUS)
    VALUES (''INGEST_AND_DECIDE'', ''PROMOTE_TO_OPERATIONAL'', 2, ''BILL_OF_LADING_EXTRACTED'', :v_sync, ''SUCCESS'');

    CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2(''AUTO'') INTO :v_pipeline;
    INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, STATUS)
    VALUES (''INGEST_AND_DECIDE'', ''FRAUD_PIPELINE'', 3, ''AUTO'', :v_pipeline, ''SUCCESS'');

    v_elapsed := DATEDIFF(''millisecond'', :v_start, CURRENT_TIMESTAMP());

    RETURN ''{"workflow":"INGEST_AND_DECIDE","status":"COMPLETED"''
        || '',"extraction":"'' || REPLACE(:v_extract, ''"'', ''\\\\"'') || ''"''
        || '',"promotion":'' || :v_sync
        || '',"pipeline":'' || :v_pipeline
        || '',"total_execution_time_ms":'' || :v_elapsed || ''}'';
END';


-- 4. Fully autonomous option -------------------------------------------------
-- The stream on the stage already existed; pointing the task at the new wrapper
-- means "drop PDFs on the stage and decisions happen by themselves".
-- Left SUSPENDED by default so a trial account is not billed while idle.
ALTER TASK MENDIX_APP.AGENTS.TASK_PROCESS_NEW_BL
  MODIFY AS CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE();

-- To enable hands-off operation:
--   ALTER TASK MENDIX_APP.AGENTS.TASK_PROCESS_NEW_BL RESUME;
-- The task fires on SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.NEW_PDF_STREAM')
-- and is scheduled every 5 minutes.


-- ============================================================================
-- HOW TO RUN THE WHOLE THING FROM THE CLI
-- ============================================================================
-- 1) upload as many Bills of Lading as you like in ONE command:
--      PUT file://bl_pdfs/*.pdf @MENDIX_APP.AGENTS.LOGISTICS_STAGE/bill_of_lading
--        AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
--
-- 2) one command takes them all the way to an AI decision:
--      CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE();
--
-- 3) inspect what the AI decided and why:
--      SELECT ALERT_ID, ALERT_TYPE, SEVERITY, SHIPPER_NAME,
--             AI_DECISION, AI_DECISION_REASON, ALERT_STATUS
--      FROM MENDIX_APP.AGENTS.V_AI_DECISIONS
--      ORDER BY AI_ANALYZED_AT DESC;
--
-- 4) trace a single PDF from file to decision:
--      SELECT e.FILE_NAME, e.CONFIDENCE_SCORE, e.ALERT,
--             b.BL_NUMBER, b.STATUS,
--             a.ALERT_TYPE, a.AI_RECOMMENDED_ACTION, a.AI_DECISION_REASON
--      FROM MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED e
--      JOIN MENDIX_APP.AGENTS.BILL_OF_LADING b ON b.BL_ID = e.BL_ID
--      LEFT JOIN MENDIX_APP.AGENTS.FRAUD_ALERT a ON a.BL_ID = b.BL_ID
--      ORDER BY e.DOC_ID DESC;
-- ============================================================================
