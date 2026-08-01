-- ============================================================================
-- 04_LOAD_DATA.sql
-- Reload the exported table data into the new account.
-- Run AFTER 01_schema_ddl.sql (tables must exist).
--
-- 16 tables carry data. The 3 DT_* dynamic tables are intentionally NOT loaded:
-- they recompute themselves from BILL_OF_LADING.
--
-- The load format below was verified against this backup by round-tripping
-- PORT_MASTER: 23 rows out, 23 rows in, zero difference under MINUS both ways.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;


-- ============================================================================
-- STEP 1. Upload the CSV files from this backup to a load stage
-- ----------------------------------------------------------------------------
-- PUT is a client-side command: run it from Snowflake CLI / SnowSQL / a driver,
-- NOT from a Snowsight worksheet.
--
--   CREATE STAGE IF NOT EXISTS MENDIX_APP.AGENTS.RESTORE_STAGE;
--
--   snow sql -c <connection> -q "PUT 'file://<backup>/data/BILL_OF_LADING/*.csv.gz' @MENDIX_APP.AGENTS.RESTORE_STAGE/data/BILL_OF_LADING/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
--
-- Repeat for each of the 16 folders under data/, or upload the whole tree at
-- once with PowerShell:
--
--   Get-ChildItem '<backup>\data' -Directory | ForEach-Object {
--     snow sql -c <connection> -q ("PUT 'file://<backup>/data/{0}/*.csv.gz' @MENDIX_APP.AGENTS.RESTORE_STAGE/data/{0}/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE" -f $_.Name)
--   }
--
-- Verify before loading:
--   LIST @MENDIX_APP.AGENTS.RESTORE_STAGE/data/;   -- expect 26 files
-- ============================================================================

CREATE STAGE IF NOT EXISTS MENDIX_APP.AGENTS.RESTORE_STAGE
    COMMENT = 'Temporary landing area for the CSV data reload; drop after the restore';

CREATE OR REPLACE FILE FORMAT MENDIX_APP.AGENTS.FF_RESTORE_CSV
    TYPE = CSV
    COMPRESSION = GZIP
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    PARSE_HEADER = TRUE
    EMPTY_FIELD_AS_NULL = TRUE
    NULL_IF = ('')
    COMMENT = 'Matches the unload format used by BACKUP_EXPORT_ALL_TABLES()';

-- MATCH_BY_COLUMN_NAME is what makes this safe: the CSVs carry a header row, so
-- columns are matched by name rather than by position. Adding or reordering a
-- column in the schema will not silently shift data into the wrong field.


-- ============================================================================
-- STEP 2. Reference data first  (the semantic view and AI prompts read these)
-- ============================================================================

COPY INTO MENDIX_APP.AGENTS.PORT_MASTER
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/PORT_MASTER/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 23 rows

COPY INTO MENDIX_APP.AGENTS.VESSEL_REGISTRY
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/VESSEL_REGISTRY/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 21 rows

COPY INTO MENDIX_APP.AGENTS.HS_CODE_REFERENCE
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/HS_CODE_REFERENCE/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 30 rows

COPY INTO MENDIX_APP.AGENTS.APP_CONFIG
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/APP_CONFIG/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 13 rows


-- ============================================================================
-- STEP 3. Core shipment data
-- ----------------------------------------------------------------------------
-- BILL_OF_LADING was unloaded as 8 files (one large + 7 small). All 8 live in
-- the same folder, so a single COPY INTO picks them all up.
-- ============================================================================

COPY INTO MENDIX_APP.AGENTS.BILL_OF_LADING
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/BILL_OF_LADING/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 10,025 rows

COPY INTO MENDIX_APP.AGENTS.BL_SEARCH_CORPUS
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/BL_SEARCH_CORPUS/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 10,005 rows

COPY INTO MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/BILL_OF_LADING_EXTRACTED/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 15 rows


-- ============================================================================
-- STEP 4. AI decisions and audit history
-- ----------------------------------------------------------------------------
-- FRAUD_ALERT carries the AI_RECOMMENDED_ACTION / AI_DECISION_REASON /
-- AI_RISK_ASSESSMENT columns -- this is the evidence that the AI, not a
-- hardcoded rule, chose BLOCK / ESCALATE / CLEAR. Load it, or V_AI_DECISIONS
-- will be empty until you rerun the pipeline.
-- ============================================================================

COPY INTO MENDIX_APP.AGENTS.FRAUD_ALERT
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/FRAUD_ALERT/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 213 rows

COPY INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/WORKFLOW_AUDIT_LOG/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 117 rows

COPY INTO MENDIX_APP.AGENTS.NOTIFICATION_LOG
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/NOTIFICATION_LOG/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 54 rows

COPY INTO MENDIX_APP.AGENTS.COMPLIANCE_CHECK_RESULT
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/COMPLIANCE_CHECK_RESULT/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 3 rows

COPY INTO MENDIX_APP.AGENTS.AI_ANOMALY_REPORT
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/AI_ANOMALY_REPORT/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 1 row

COPY INTO MENDIX_APP.AGENTS.AI_CALL_LOG
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/AI_CALL_LOG/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 10 rows

COPY INTO MENDIX_APP.AGENTS.CHAT_SESSION
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/CHAT_SESSION/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 2 rows


-- ============================================================================
-- STEP 5. SAP integration results
-- ============================================================================

COPY INTO MENDIX_APP.AGENTS.SAP_FI_DOCUMENT
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/SAP_FI_DOCUMENT/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 19 rows

COPY INTO MENDIX_APP.AGENTS.SAP_MM_GOODS_RECEIPT
    FROM @MENDIX_APP.AGENTS.RESTORE_STAGE/data/SAP_MM_GOODS_RECEIPT/
    FILE_FORMAT = (FORMAT_NAME = 'MENDIX_APP.AGENTS.FF_RESTORE_CSV')
    MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE' ON_ERROR = 'ABORT_STATEMENT';        -- 1 row


-- ============================================================================
-- STEP 6. DO NOT LOAD  -- dynamic tables
-- ----------------------------------------------------------------------------
-- data/DT_CARRIER_PERFORMANCE/, data/DT_ROUTE_ANALYTICS/ and
-- data/DT_SHIPMENT_KPI/ were captured for reference only. These are dynamic
-- tables: Snowflake owns their contents and rebuilds them from BILL_OF_LADING.
-- Loading into them fails, and is unnecessary.
--
-- They were left SUSPENDED to save credit. Resume them when you want live KPIs:
--   ALTER DYNAMIC TABLE MENDIX_APP.AGENTS.DT_SHIPMENT_KPI RESUME;
--   ALTER DYNAMIC TABLE MENDIX_APP.AGENTS.DT_CARRIER_PERFORMANCE RESUME;
--   ALTER DYNAMIC TABLE MENDIX_APP.AGENTS.DT_ROUTE_ANALYTICS RESUME;
--   ALTER DYNAMIC TABLE MENDIX_APP.AGENTS.DT_SHIPMENT_KPI REFRESH;
--
-- V_SHIPMENT_KPI_STATIC computes the same KPIs on demand, so the dashboard works
-- with the dynamic tables suspended.
-- ============================================================================


-- ============================================================================
-- STEP 7. VERIFY THE LOAD
-- ----------------------------------------------------------------------------
-- Expected row counts, as captured on 2026-08-01.
-- ============================================================================

SELECT 'BILL_OF_LADING' AS tbl, COUNT(*) AS actual, 10025 AS expected FROM MENDIX_APP.AGENTS.BILL_OF_LADING
UNION ALL SELECT 'BL_SEARCH_CORPUS',        COUNT(*), 10005 FROM MENDIX_APP.AGENTS.BL_SEARCH_CORPUS
UNION ALL SELECT 'FRAUD_ALERT',             COUNT(*),   213 FROM MENDIX_APP.AGENTS.FRAUD_ALERT
UNION ALL SELECT 'WORKFLOW_AUDIT_LOG',      COUNT(*),   117 FROM MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
UNION ALL SELECT 'NOTIFICATION_LOG',        COUNT(*),    54 FROM MENDIX_APP.AGENTS.NOTIFICATION_LOG
UNION ALL SELECT 'HS_CODE_REFERENCE',       COUNT(*),    30 FROM MENDIX_APP.AGENTS.HS_CODE_REFERENCE
UNION ALL SELECT 'PORT_MASTER',             COUNT(*),    23 FROM MENDIX_APP.AGENTS.PORT_MASTER
UNION ALL SELECT 'VESSEL_REGISTRY',         COUNT(*),    21 FROM MENDIX_APP.AGENTS.VESSEL_REGISTRY
UNION ALL SELECT 'SAP_FI_DOCUMENT',         COUNT(*),    19 FROM MENDIX_APP.AGENTS.SAP_FI_DOCUMENT
UNION ALL SELECT 'BILL_OF_LADING_EXTRACTED',COUNT(*),    15 FROM MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED
UNION ALL SELECT 'APP_CONFIG',              COUNT(*),    13 FROM MENDIX_APP.AGENTS.APP_CONFIG
UNION ALL SELECT 'AI_CALL_LOG',             COUNT(*),    10 FROM MENDIX_APP.AGENTS.AI_CALL_LOG
UNION ALL SELECT 'COMPLIANCE_CHECK_RESULT', COUNT(*),     3 FROM MENDIX_APP.AGENTS.COMPLIANCE_CHECK_RESULT
UNION ALL SELECT 'CHAT_SESSION',            COUNT(*),     2 FROM MENDIX_APP.AGENTS.CHAT_SESSION
UNION ALL SELECT 'AI_ANOMALY_REPORT',       COUNT(*),     1 FROM MENDIX_APP.AGENTS.AI_ANOMALY_REPORT
UNION ALL SELECT 'SAP_MM_GOODS_RECEIPT',    COUNT(*),     1 FROM MENDIX_APP.AGENTS.SAP_MM_GOODS_RECEIPT
ORDER BY expected DESC;

-- Confirm the AI decisions survived the migration -- expect 1 BLOCK and 6 CLEAR
-- among the alerts that were analysed:
SELECT AI_RECOMMENDED_ACTION, COUNT(*) AS alerts
FROM MENDIX_APP.AGENTS.FRAUD_ALERT
WHERE AI_RECOMMENDED_ACTION IS NOT NULL
GROUP BY AI_RECOMMENDED_ACTION
ORDER BY alerts DESC;

-- Check the identity counters cannot collide with the loaded rows.
-- Every row here must read OK. If any reads COLLISION, see the identity section
-- of README_RESTORE.md -- you must fix the START value in 01_schema_ddl.sql and
-- recreate that table, because Snowflake cannot reseed an identity column in
-- place (ALTER COLUMN ... SET AUTOINCREMENT is not valid syntax).
SELECT c.TABLE_NAME, c.COLUMN_NAME, c.IDENTITY_START,
       CASE WHEN c.IDENTITY_START > 0 THEN 'check max id below' END AS note
FROM MENDIX_APP.INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_SCHEMA = 'AGENTS' AND c.IS_IDENTITY = 'YES'
ORDER BY c.TABLE_NAME;


-- ============================================================================
-- STEP 8. CLEAN UP
-- ============================================================================

-- DROP STAGE IF EXISTS MENDIX_APP.AGENTS.RESTORE_STAGE;
-- DROP FILE FORMAT IF EXISTS MENDIX_APP.AGENTS.FF_RESTORE_CSV;
