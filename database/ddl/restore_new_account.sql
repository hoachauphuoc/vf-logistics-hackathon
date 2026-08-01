-- ============================================================================
-- VF LOGISTICS PORTAL - RESTORE SCRIPT FOR A NEW SNOWFLAKE ACCOUNT
-- ============================================================================
-- Team SORA | CoCo CLI Hackathon 2026
-- 
-- INSTRUCTIONS: Run each STEP in order, in CoCo Desktop or Snowsight.
-- Estimated time: 5-10 minutes (excluding AI processing time)
-- Estimated credit usage: ~1-2 credits (mostly warehouse + AI functions)
-- ============================================================================

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 0: PRE-FLIGHT CHECKS                                                 ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
-- Make sure you are using the ACCOUNTADMIN role and have a warehouse

USE ROLE ACCOUNTADMIN;

-- Create the warehouse if it doesn't exist
CREATE WAREHOUSE IF NOT EXISTS COMPUTE_WH
    WAREHOUSE_SIZE = 'X-SMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = FALSE;

USE WAREHOUSE COMPUTE_WH;

-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 1: RUN THE DDL (CREATE DATABASE + ALL OBJECTS)                       ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
-- Open sql/full_database_ddl.sql and run its entire contents.
-- This file creates:
--   - Database MENDIX_APP, Schema AGENTS
--   - 30 tables (BILL_OF_LADING, BILL_OF_LADING_EXTRACTED, FRAUD_ALERT, etc.)
--   - 40 stored procedures (PROCESS_BL_DOCUMENTS, REVIEW_DOCUMENT, GET_PDF_URL, SEND_FRAUD_NOTIFICATION, etc.)
--   - 8 Views (V_AI_DAILY_COST, V_EXCHANGE_RATES, V_BL_SEARCH, V_EXTRACTION_METRICS, etc.)
--   - Dynamic Tables (DT_SHIPMENT_KPI, DT_CARRIER_PERFORMANCE, etc.)
--   - 6 Functions (CALCULATE_DISTANCE, etc.)
--
-- In CoCo Desktop, run:
--   !source C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/sql/full_database_ddl.sql
--
-- Or copy-paste the file contents into a Snowsight worksheet and Execute All.


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 2: CREATE STAGES                                                      ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;

-- Stage for the Streamlit app
CREATE STAGE IF NOT EXISTS STREAMLIT_STAGE
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- Stage for documents (PDFs)
CREATE STAGE IF NOT EXISTS LOGISTICS_STAGE
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

ALTER STAGE LOGISTICS_STAGE REFRESH;


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 3: UPLOAD FILES TO STAGES                                             ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
-- Run the PUT commands below in CoCo Desktop (or SnowSQL):

-- 3a. Upload Streamlit app files
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/streamlit_app/app.py' @STREAMLIT_STAGE/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/streamlit_app/environment.yml' @STREAMLIT_STAGE/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/streamlit_app/i18n.py' @STREAMLIT_STAGE/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/streamlit_app/vf_logistics_semantic_model.yaml' @STREAMLIT_STAGE/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/streamlit_app/pages/1_Documents.py' @STREAMLIT_STAGE/pages/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/streamlit_app/pages/2_Compliance.py' @STREAMLIT_STAGE/pages/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/streamlit_app/pages/3_Fraud_Detection.py' @STREAMLIT_STAGE/pages/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/streamlit_app/pages/4_AI_FinOps.py' @STREAMLIT_STAGE/pages/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/streamlit_app/pages/5_Settings.py' @STREAMLIT_STAGE/pages/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/streamlit_app/pages/6_AI_Chat.py' @STREAMLIT_STAGE/pages/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- 3b. Upload sample PDF documents
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/sample_documents/pdf/BL_*.pdf' @LOGISTICS_STAGE/bill_of_lading/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- 3c. Upload data backup CSVs
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/data_backup/bill_of_lading_data.csv' @LOGISTICS_STAGE/backup/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/data_backup/hs_code_reference.csv' @LOGISTICS_STAGE/backup/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/data_backup/fraud_alert.csv' @LOGISTICS_STAGE/backup/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file://C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/snowflake-backend/data_backup/app_config.csv' @LOGISTICS_STAGE/backup/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- Refresh directories
ALTER STAGE STREAMLIT_STAGE REFRESH;
ALTER STAGE LOGISTICS_STAGE REFRESH;


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 4: LOAD DATA FROM CSV                                                 ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

-- 4a. Load Bill of Lading (10,005 records)
-- NOTE: TRUNCATE first if the DDL already created sample data
TRUNCATE TABLE IF EXISTS BILL_OF_LADING;

COPY INTO BILL_OF_LADING
FROM @LOGISTICS_STAGE/backup/bill_of_lading_data.csv
FILE_FORMAT = (TYPE='CSV' FIELD_OPTIONALLY_ENCLOSED_BY='"' SKIP_HEADER=0)
ON_ERROR = 'CONTINUE';

-- 4b. Load HS Code Reference (30 records)
TRUNCATE TABLE IF EXISTS HS_CODE_REFERENCE;

COPY INTO HS_CODE_REFERENCE
FROM @LOGISTICS_STAGE/backup/hs_code_reference.csv
FILE_FORMAT = (TYPE='CSV' FIELD_OPTIONALLY_ENCLOSED_BY='"' SKIP_HEADER=0)
ON_ERROR = 'CONTINUE';

-- 4c. Load Fraud Alerts (37 records)
TRUNCATE TABLE IF EXISTS FRAUD_ALERT;

COPY INTO FRAUD_ALERT
FROM @LOGISTICS_STAGE/backup/fraud_alert.csv
FILE_FORMAT = (TYPE='CSV' FIELD_OPTIONALLY_ENCLOSED_BY='"' SKIP_HEADER=0)
ON_ERROR = 'CONTINUE';

-- 4d. Load App Config (13 records)
TRUNCATE TABLE IF EXISTS APP_CONFIG;

COPY INTO APP_CONFIG
FROM @LOGISTICS_STAGE/backup/app_config.csv
FILE_FORMAT = (TYPE='CSV' FIELD_OPTIONALLY_ENCLOSED_BY='"' SKIP_HEADER=0)
ON_ERROR = 'CONTINUE';

-- 4e. Verify data loaded
SELECT 'BILL_OF_LADING' as TBL, COUNT(*) as ROWS FROM BILL_OF_LADING
UNION ALL SELECT 'HS_CODE_REFERENCE', COUNT(*) FROM HS_CODE_REFERENCE
UNION ALL SELECT 'FRAUD_ALERT', COUNT(*) FROM FRAUD_ALERT
UNION ALL SELECT 'APP_CONFIG', COUNT(*) FROM APP_CONFIG;
-- Expected: 10005, 30, 37, 13


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 5: POPULATE BL_SEARCH_CORPUS (for Cortex Search)                      ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

TRUNCATE TABLE IF EXISTS BL_SEARCH_CORPUS;

INSERT INTO BL_SEARCH_CORPUS
SELECT
    BL_ID, BL_NUMBER,
    COALESCE(BL_NUMBER,'') || ' ' || COALESCE(CARRIER_NAME,'') || ' ' ||
    COALESCE(SHIPPER_NAME,'') || ' ' || COALESCE(CONSIGNEE_NAME,'') || ' ' ||
    COALESCE(COMMODITY_DESCRIPTION,'') || ' ' || COALESCE(VESSEL_NAME,'') || ' ' ||
    COALESCE(PORT_OF_LOADING_LOCODE,'') || ' ' || COALESCE(PORT_OF_DISCHARGE_LOCODE,'') || ' ' ||
    COALESCE(CONTAINER_NUMBER,'') || ' ' || COALESCE(STATUS,'')
    AS SEARCH_TEXT,
    STATUS, CARRIER_NAME, TOTAL_CHARGES,
    PORT_OF_LOADING_LOCODE, PORT_OF_DISCHARGE_LOCODE,
    CREATED_AT
FROM BILL_OF_LADING;


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 6: CREATE THE STREAMLIT APP                                           ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

CREATE OR REPLACE STREAMLIT MENDIX_APP.AGENTS.VF_LOGISTICS_DASHBOARD
    ROOT_LOCATION = '@MENDIX_APP.AGENTS.STREAMLIT_STAGE'
    MAIN_FILE = 'app.py'
    QUERY_WAREHOUSE = COMPUTE_WH
    TITLE = 'VF Logistics Dashboard';


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 7: CREATE THE CORTEX SEARCH SERVICE (OPTIONAL - ongoing credit cost) ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
-- Only create this if you need to demo the AI Semantic Search feature.
-- The service auto-refreshes every 1 hour → costs credits. Suspend right after creating it.

CREATE OR REPLACE CORTEX SEARCH SERVICE MENDIX_APP.AGENTS.BL_SEARCH_SERVICE
    ON SEARCH_TEXT
    WAREHOUSE = COMPUTE_WH
    TARGET_LAG = '1 hour'
AS (
    SELECT SEARCH_TEXT, STATUS, CARRIER_NAME, PORT_OF_LOADING_LOCODE,
           PORT_OF_DISCHARGE_LOCODE, BL_NUMBER, BL_ID, TOTAL_CHARGES
    FROM MENDIX_APP.AGENTS.BL_SEARCH_CORPUS
);

-- Suspend immediately to save credits (resume when demoing)
ALTER CORTEX SEARCH SERVICE MENDIX_APP.AGENTS.BL_SEARCH_SERVICE SUSPEND;


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 8: CREATE STREAMS (event-driven automation)                          ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

CREATE OR REPLACE STREAM MENDIX_APP.AGENTS.BL_CHANGE_STREAM
    ON TABLE MENDIX_APP.AGENTS.BILL_OF_LADING
    APPEND_ONLY = TRUE
    COMMENT = 'Captures new Bill of Lading inserts for fraud detection pipeline';

CREATE OR REPLACE STREAM MENDIX_APP.AGENTS.NEW_PDF_STREAM
    ON STAGE MENDIX_APP.AGENTS.LOGISTICS_STAGE;


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 9: CREATE TASKS (all suspended by default)                           ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

-- Task 1: Process new PDFs (every 5 minutes, when the stream has data)
CREATE OR REPLACE TASK MENDIX_APP.AGENTS.TASK_PROCESS_NEW_BL
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '5 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.NEW_PDF_STREAM')
AS
    CALL MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS();

-- Task 2: Fraud scan (every 5 minutes, when there's a new B/L)
CREATE OR REPLACE TASK MENDIX_APP.AGENTS.TASK_FRAUD_SCAN
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '5 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.BL_CHANGE_STREAM')
AS
    INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (BL_ID, ALERT_TYPE, SEVERITY, DESCRIPTION, DETECTED_AT)
    SELECT 
        s.BL_ID,
        CASE 
            WHEN s.TOTAL_CHARGES > 50000 THEN 'HIGH_VALUE_ANOMALY'
            WHEN s.GROSS_WEIGHT_KGS > 100000 THEN 'WEIGHT_ANOMALY'
            WHEN s.TOTAL_CHARGES / NULLIF(s.GROSS_WEIGHT_KGS, 0) > 10 THEN 'COST_PER_KG_ANOMALY'
            ELSE 'NEW_PARTY_CHECK'
        END,
        CASE 
            WHEN s.TOTAL_CHARGES > 50000 OR s.GROSS_WEIGHT_KGS > 100000 THEN 'HIGH'
            WHEN s.TOTAL_CHARGES / NULLIF(s.GROSS_WEIGHT_KGS, 0) > 10 THEN 'MEDIUM'
            ELSE 'LOW'
        END,
        'Auto-detected: ' || s.BL_NUMBER || ' | $' || s.TOTAL_CHARGES::VARCHAR || ' | ' || s.GROSS_WEIGHT_KGS::VARCHAR || 'kg',
        CURRENT_TIMESTAMP()
    FROM MENDIX_APP.AGENTS.BL_CHANGE_STREAM s
    WHERE s.TOTAL_CHARGES > 20000
        OR s.GROSS_WEIGHT_KGS > 80000
        OR s.TOTAL_CHARGES / NULLIF(s.GROSS_WEIGHT_KGS, 0) > 8;

-- All tasks stay SUSPENDED (default). Resume when needed for a demo:
-- ALTER TASK TASK_PROCESS_NEW_BL RESUME;
-- ALTER TASK TASK_FRAUD_SCAN RESUME;


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 10: CREATE RESOURCE MONITOR (cost control)                           ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

CREATE OR REPLACE RESOURCE MONITOR VF_LOGISTICS_MONITOR
    WITH CREDIT_QUOTA = 10
    FREQUENCY = DAILY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 80 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE COMPUTE_WH SET RESOURCE_MONITOR = VF_LOGISTICS_MONITOR;


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 11: CREATE APP ROLE + MENDIX SERVICE USER (least-privilege)          ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

-- 11a. Create a dedicated role for the application (not using ACCOUNTADMIN)
CREATE ROLE IF NOT EXISTS VF_APP_ROLE
    COMMENT = 'Least-privilege role for VF Logistics Mendix integration';

GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE VF_APP_ROLE;
GRANT USAGE ON DATABASE MENDIX_APP TO ROLE VF_APP_ROLE;
GRANT USAGE ON SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT INSERT, UPDATE ON TABLE MENDIX_APP.AGENTS.BILL_OF_LADING TO ROLE VF_APP_ROLE;
GRANT INSERT, UPDATE ON TABLE MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED TO ROLE VF_APP_ROLE;
GRANT INSERT, UPDATE ON TABLE MENDIX_APP.AGENTS.FRAUD_ALERT TO ROLE VF_APP_ROLE;
GRANT INSERT ON TABLE MENDIX_APP.AGENTS.NOTIFICATION_LOG TO ROLE VF_APP_ROLE;
GRANT INSERT ON TABLE MENDIX_APP.AGENTS.AI_USAGE_LOG TO ROLE VF_APP_ROLE;
GRANT INSERT ON TABLE MENDIX_APP.AGENTS.AI_ANOMALY_REPORT TO ROLE VF_APP_ROLE;
GRANT USAGE ON ALL PROCEDURES IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT READ ON STAGE MENDIX_APP.AGENTS.LOGISTICS_STAGE TO ROLE VF_APP_ROLE;
GRANT READ ON STAGE MENDIX_APP.AGENTS.STREAMLIT_STAGE TO ROLE VF_APP_ROLE;
GRANT SELECT ON ALL VIEWS IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT ROLE VF_APP_ROLE TO ROLE ACCOUNTADMIN;

-- 11b. Create the service user with the least-privilege role
-- SECURITY: never commit a real password here. Set it via a session variable
-- before running this script, e.g.:
--   SET svc_password = '<generate a new strong password>';
-- then replace the literal below with :svc_password, or rotate the password
-- immediately after running with ALTER USER ... SET PASSWORD = '<new value>'.
CREATE USER IF NOT EXISTS MENDIX_SERVICE_USER
    PASSWORD = '<REPLACE_WITH_NEW_ROTATED_PASSWORD>'
    DEFAULT_WAREHOUSE = COMPUTE_WH
    DEFAULT_NAMESPACE = MENDIX_APP.AGENTS
    DEFAULT_ROLE = VF_APP_ROLE
    MUST_CHANGE_PASSWORD = FALSE;

GRANT ROLE VF_APP_ROLE TO USER MENDIX_SERVICE_USER;


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 12: EMAIL NOTIFICATION + DATA GOVERNANCE TAGS                         ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

-- 12a. Email notification integration (free, built-in)
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS VF_EMAIL_NOTIFICATION
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = ('cuongnguyencntt03@gmail.com')
    COMMENT = 'Email notifications for fraud alerts and pipeline failures';

-- 12b. Data governance tags
CREATE TAG IF NOT EXISTS MENDIX_APP.AGENTS.DATA_DOMAIN COMMENT = 'Business domain classification';
CREATE TAG IF NOT EXISTS MENDIX_APP.AGENTS.DATA_SENSITIVITY COMMENT = 'Data sensitivity level: PUBLIC, INTERNAL, CONFIDENTIAL, RESTRICTED';
CREATE TAG IF NOT EXISTS MENDIX_APP.AGENTS.DATA_OWNER COMMENT = 'Team or person responsible for data quality';
CREATE TAG IF NOT EXISTS MENDIX_APP.AGENTS.PII_FLAG COMMENT = 'Contains Personally Identifiable Information: YES/NO';

ALTER TABLE BILL_OF_LADING SET TAG DATA_DOMAIN='LOGISTICS', DATA_SENSITIVITY='CONFIDENTIAL', DATA_OWNER='Operations Team', PII_FLAG='YES';
ALTER TABLE BILL_OF_LADING_EXTRACTED SET TAG DATA_DOMAIN='AI_PROCESSING', DATA_SENSITIVITY='CONFIDENTIAL', DATA_OWNER='AI Team', PII_FLAG='NO';
ALTER TABLE FRAUD_ALERT SET TAG DATA_DOMAIN='COMPLIANCE', DATA_SENSITIVITY='RESTRICTED', DATA_OWNER='Compliance Team', PII_FLAG='NO';
ALTER TABLE HS_CODE_REFERENCE SET TAG DATA_DOMAIN='REFERENCE', DATA_SENSITIVITY='PUBLIC', DATA_OWNER='Operations Team', PII_FLAG='NO';

-- PII column-level tags
ALTER TABLE BILL_OF_LADING ALTER COLUMN SHIPPER_NAME SET TAG PII_FLAG = 'YES';
ALTER TABLE BILL_OF_LADING ALTER COLUMN CONSIGNEE_NAME SET TAG PII_FLAG = 'YES';
ALTER TABLE BILL_OF_LADING ALTER COLUMN NOTIFY_PARTY SET TAG PII_FLAG = 'YES';


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 13: QUICK TESTS                                                       ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

-- Test 1: Verify data
SELECT COUNT(*) as TOTAL_BL FROM BILL_OF_LADING;
-- Expected: 10005

-- Test 2: Verify carrier distribution
SELECT CARRIER_NAME, COUNT(*) as CNT FROM BILL_OF_LADING GROUP BY CARRIER_NAME ORDER BY CNT DESC LIMIT 5;
-- Expected: MAERSK ~2501, MSC ~1801, COSCO ~1400

-- Test 3: Test AI Chat
CALL CHAT_WITH_DATA('How many shipments does MAERSK have?');
-- Expected: natural language answer mentioning 2,501 shipments, 25% market share

-- Test 4: Process sample PDFs (costs ~0.5 credit for 10-file AI extraction)
CALL PROCESS_BL_DOCUMENTS();
-- Expected: "Complete. Processed: 10 | Errors: 0"

-- Test 5: Verify extraction results
SELECT FILE_NAME, CONTAINER_NUMBER, VESSEL_NAME, CONFIDENCE_SCORE, STATUS
FROM BILL_OF_LADING_EXTRACTED
WHERE FILE_NAME LIKE 'bill_of_lading/BL_%'
ORDER BY STATUS, CONFIDENCE_SCORE;
-- Expected: 5 files AI_Processed (100), 4 files Pending_Review (25-75)

-- Test 6: Test PDF URL generation
CALL GET_PDF_URL((SELECT MAX(DOC_ID) FROM BILL_OF_LADING_EXTRACTED));
-- Expected: presigned S3 URL (valid for 1 hour)

-- Test 7: Test Review/Correct document
CALL REVIEW_DOCUMENT(
    (SELECT DOC_ID FROM BILL_OF_LADING_EXTRACTED WHERE STATUS = 'Pending_Review' LIMIT 1),
    'CORRECT',
    'demo_user',
    'Fixed during demo',
    '{"container_number":"MSKU7891234","vessel_name":"MAERSK SENTOSA","gross_weight_kg":24500,"arrival_date":"2026-07-28"}'
);
-- Expected: {"status":"success","action":"CORRECT","doc_id":...}


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║ STEP 14: SUSPEND WAREHOUSE (save credits once setup is done)              ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

ALTER WAREHOUSE COMPUTE_WH SUSPEND;

-- ============================================================================
-- RESTORE COMPLETE!
-- ============================================================================
--
-- Summary of objects created:
--   Database: MENDIX_APP
--   Schema: AGENTS
--   Tables: 30
--   Procedures: 40
--   Views: 8
--   Dynamic Tables: 3
--   Functions: 6
--   Stages: 2 (STREAMLIT_STAGE, LOGISTICS_STAGE)
--   Streams: 2 (BL_CHANGE_STREAM, NEW_PDF_STREAM)
--   Tasks: 2 (TASK_PROCESS_NEW_BL, TASK_FRAUD_SCAN) - suspended
--   Cortex Search: BL_SEARCH_SERVICE - suspended
--   Streamlit: VF_LOGISTICS_DASHBOARD
--   Resource Monitor: VF_LOGISTICS_MONITOR (10 credits/day)
--   Role: VF_APP_ROLE (least-privilege, not ACCOUNTADMIN)
--   User: MENDIX_SERVICE_USER
--
-- When you need to demo:
--   ALTER WAREHOUSE COMPUTE_WH RESUME;
--   ALTER CORTEX SEARCH SERVICE BL_SEARCH_SERVICE RESUME;  -- if search is needed
--
-- Mendix JDBC connection string:
--   Account: <NEW_ACCOUNT_LOCATOR>.ap-southeast-7.aws
--   User: MENDIX_SERVICE_USER
--   Password: <use the rotated password set in STEP 11b — never hardcode it here>
--   Database: MENDIX_APP
--   Schema: AGENTS
--   Warehouse: COMPUTE_WH
--   JDBC_QUERY_RESULT_FORMAT: JSON
-- ============================================================================
