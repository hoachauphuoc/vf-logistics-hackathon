-- ============================================================================
-- 05_REGRESSION_TESTS_ADMIN.sql
--
-- Structural regression suite -- run as ACCOUNTADMIN immediately after any
-- restore (00-04 + 02_special_objects.sql + 03_grants.sql), and again as a
-- final sanity pass before going live in front of judges.
--
-- IMPORTANT LIMITATION: everything in this file runs as ACCOUNTADMIN, which
-- holds OWNERSHIP on every object -- so it can confirm a grant EXISTS, but it
-- CANNOT prove the app actually works, because ACCOUNTADMIN never hits a
-- privilege error even when VF_APP_ROLE would. The 2026-08-01 incident
-- (missing INSERT on FRAUD_ALERT/WORKFLOW_AUDIT_LOG/NOTIFICATION_LOG/
-- BILL_OF_LADING) was invisible to any ACCOUNTADMIN-run check and only
-- surfaced when Mendix, running AS MENDIX_SERVICE_USER, called the workflow.
--
-- This file catches structural drift (missing objects, missing grant rows,
-- missing data, wrong auth setup). It does NOT replace
-- `_regression_test_mendix_identity.py`, which connects AS MENDIX_SERVICE_USER
-- with the real key-pair and is the only check that reproduces production.
-- Run BOTH before declaring "safe to demo".
--
-- Usage:
--   snow sql -f 05_regression_tests_admin.sql
--   (or paste into a Snowsight worksheet, run top to bottom)
-- Then read the final SELECT: zero FAIL rows = structurally sound.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;
USE WAREHOUSE COMPUTE_WH;

CREATE OR REPLACE TEMPORARY TABLE REGRESSION_RESULTS (
    TEST_NO    NUMBER,
    CATEGORY   VARCHAR,
    TEST_NAME  VARCHAR,
    EXPECTED   VARCHAR,
    ACTUAL     VARCHAR,
    STATUS     VARCHAR
);

-- ============================================================================
-- CATEGORY A -- Object inventory
-- (expected counts per README_RESTORE.md; adjust here if the schema grows)
-- ============================================================================

INSERT INTO REGRESSION_RESULTS
SELECT 1, 'INVENTORY', 'Base table count', '30', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) = 30, 'PASS', 'FAIL')
FROM MENDIX_APP.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'AGENTS' AND TABLE_TYPE = 'BASE TABLE';

INSERT INTO REGRESSION_RESULTS
SELECT 2, 'INVENTORY', 'View count', '9', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) = 9, 'PASS', 'FAIL')
FROM MENDIX_APP.INFORMATION_SCHEMA.VIEWS
WHERE TABLE_SCHEMA = 'AGENTS';

-- SHOW PROCEDURES also lists Snowflake's account-wide SYSTEM$ built-ins
-- (SYSTEM$SEND_EMAIL etc.) -- exclude those, they are noise, not ours.
-- Threshold is >= (floor), not =, because adding a new procedure is normal
-- and must not fail this check; only a REGRESSION (fewer than expected) should.
SHOW PROCEDURES IN SCHEMA MENDIX_APP.AGENTS;
INSERT INTO REGRESSION_RESULTS
SELECT 3, 'INVENTORY', 'Custom procedure count (excl. SYSTEM$)', '>= 46', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 46, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE "name" NOT LIKE 'SYSTEM$%';

SHOW USER FUNCTIONS IN SCHEMA MENDIX_APP.AGENTS;
INSERT INTO REGRESSION_RESULTS
SELECT 4, 'INVENTORY', 'Function count', '6', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) = 6, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW DYNAMIC TABLES IN SCHEMA MENDIX_APP.AGENTS;
INSERT INTO REGRESSION_RESULTS
SELECT 5, 'INVENTORY', 'Dynamic table count', '3', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) = 3, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW STREAMS IN SCHEMA MENDIX_APP.AGENTS;
INSERT INTO REGRESSION_RESULTS
SELECT 6, 'INVENTORY', 'Stream count', '>= 2', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 2, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW TASKS IN SCHEMA MENDIX_APP.AGENTS;
INSERT INTO REGRESSION_RESULTS
SELECT 7, 'INVENTORY', 'Task count', '7', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) = 7, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW STAGES IN SCHEMA MENDIX_APP.AGENTS;
INSERT INTO REGRESSION_RESULTS
SELECT 8, 'INVENTORY', 'Stage count', '2', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) = 2, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW SEMANTIC VIEWS IN SCHEMA MENDIX_APP.AGENTS;
INSERT INTO REGRESSION_RESULTS
SELECT 9, 'INVENTORY', 'Semantic view count', '1', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) = 1, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- ============================================================================
-- CATEGORY B -- Data integrity
-- ============================================================================

-- Floors are the row counts verified immediately after the 2026-08-01 restore
-- (NOT the backup's MAX(id), which is always higher than COUNT(*) because
-- identity values are not contiguous). These tables only grow from here as
-- the pipeline runs, so >= is safe and will not false-fail after demo runs.
INSERT INTO REGRESSION_RESULTS
SELECT 10, 'DATA', 'BILL_OF_LADING row count', '>= 10025', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 10025, 'PASS', 'FAIL') FROM BILL_OF_LADING;

INSERT INTO REGRESSION_RESULTS
SELECT 11, 'DATA', 'FRAUD_ALERT row count', '>= 213', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 213, 'PASS', 'FAIL') FROM FRAUD_ALERT;

INSERT INTO REGRESSION_RESULTS
SELECT 12, 'DATA', 'WORKFLOW_AUDIT_LOG row count', '>= 100', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 100, 'PASS', 'FAIL') FROM WORKFLOW_AUDIT_LOG;

INSERT INTO REGRESSION_RESULTS
SELECT 13, 'DATA', 'AI decisions present on FRAUD_ALERT',
       '>= 1 row with AI_RECOMMENDED_ACTION', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 1, 'PASS', 'FAIL')
FROM FRAUD_ALERT WHERE AI_RECOMMENDED_ACTION IS NOT NULL;

INSERT INTO REGRESSION_RESULTS
SELECT 14, 'DATA', 'V_AI_DECISIONS judge view returns rows', '>= 1', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 1, 'PASS', 'FAIL') FROM V_AI_DECISIONS;

-- ============================================================================
-- CATEGORY C -- VF_APP_ROLE grants
-- This is the exact class of bug that broke /run_pipeline on 2026-08-01.
-- Re-run SHOW GRANTS before every single check: RESULT_SCAN(LAST_QUERY_ID())
-- only sees the immediately preceding statement.
-- ============================================================================

SHOW GRANTS TO ROLE VF_APP_ROLE;
INSERT INTO REGRESSION_RESULTS
SELECT 20, 'GRANTS', 'INSERT on FRAUD_ALERT', '>= 1 row', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 1, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" = 'INSERT' AND "name" = 'MENDIX_APP.AGENTS.FRAUD_ALERT';

SHOW GRANTS TO ROLE VF_APP_ROLE;
INSERT INTO REGRESSION_RESULTS
SELECT 21, 'GRANTS', 'UPDATE on FRAUD_ALERT', '>= 1 row', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 1, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" = 'UPDATE' AND "name" = 'MENDIX_APP.AGENTS.FRAUD_ALERT';

SHOW GRANTS TO ROLE VF_APP_ROLE;
INSERT INTO REGRESSION_RESULTS
SELECT 22, 'GRANTS', 'INSERT on WORKFLOW_AUDIT_LOG', '>= 1 row', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 1, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" = 'INSERT' AND "name" = 'MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG';

SHOW GRANTS TO ROLE VF_APP_ROLE;
INSERT INTO REGRESSION_RESULTS
SELECT 23, 'GRANTS', 'INSERT on NOTIFICATION_LOG', '>= 1 row', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 1, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" = 'INSERT' AND "name" = 'MENDIX_APP.AGENTS.NOTIFICATION_LOG';

SHOW GRANTS TO ROLE VF_APP_ROLE;
INSERT INTO REGRESSION_RESULTS
SELECT 24, 'GRANTS', 'INSERT on BILL_OF_LADING', '>= 1 row', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 1, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" = 'INSERT' AND "name" = 'MENDIX_APP.AGENTS.BILL_OF_LADING';

SHOW GRANTS TO ROLE VF_APP_ROLE;
INSERT INTO REGRESSION_RESULTS
SELECT 25, 'GRANTS', 'UPDATE on BILL_OF_LADING', '>= 1 row', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 1, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" = 'UPDATE' AND "name" = 'MENDIX_APP.AGENTS.BILL_OF_LADING';

SHOW GRANTS TO ROLE VF_APP_ROLE;
INSERT INTO REGRESSION_RESULTS
SELECT 26, 'GRANTS', 'INSERT+UPDATE on BILL_OF_LADING_EXTRACTED', '>= 2 rows', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 2, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" IN ('INSERT', 'UPDATE') AND "name" = 'MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED';

SHOW GRANTS TO ROLE VF_APP_ROLE;
INSERT INTO REGRESSION_RESULTS
SELECT 27, 'GRANTS', 'USAGE on WORKFLOW_INGEST_AND_DECIDE', '>= 1 row', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 1, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" = 'USAGE' AND "name" LIKE 'MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE%';

SHOW GRANTS TO ROLE VF_APP_ROLE;
INSERT INTO REGRESSION_RESULTS
SELECT 28, 'GRANTS', 'READ+WRITE on LOGISTICS_STAGE', '>= 2 rows', TO_VARCHAR(COUNT(*)),
       IFF(COUNT(*) >= 2, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" IN ('READ', 'WRITE') AND "name" = 'MENDIX_APP.AGENTS.LOGISTICS_STAGE';

-- ============================================================================
-- CATEGORY D -- Auth setup (the TYPE=SERVICE / key-pair incident)
-- ============================================================================

DESCRIBE USER MENDIX_SERVICE_USER;
INSERT INTO REGRESSION_RESULTS
SELECT 30, 'AUTH', 'MENDIX_SERVICE_USER has key-pair registered', 'true', "value",
       IFF("value" = 'true', 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE "property" = 'HAS_RSA_PUBLIC_KEY';

DESCRIBE USER MENDIX_SERVICE_USER;
INSERT INTO REGRESSION_RESULTS
SELECT 31, 'AUTH', 'MENDIX_SERVICE_USER default role', 'VF_APP_ROLE', "value",
       IFF("value" = 'VF_APP_ROLE', 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE "property" = 'DEFAULT_ROLE';

DESCRIBE USER MENDIX_SERVICE_USER;
INSERT INTO REGRESSION_RESULTS
SELECT 32, 'AUTH', 'MENDIX_SERVICE_USER default namespace', 'MENDIX_APP.AGENTS', "value",
       IFF("value" = 'MENDIX_APP.AGENTS', 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE "property" = 'DEFAULT_NAMESPACE';

-- ============================================================================
-- CATEGORY E -- Suspend/resume state (the "search service doesn't auto-resume"
-- and "stage directory doesn't see new PUTs" incidents from README_RESTORE.md)
-- ============================================================================

SHOW CORTEX SEARCH SERVICES IN SCHEMA MENDIX_APP.AGENTS;
INSERT INTO REGRESSION_RESULTS
SELECT 40, 'STATE', 'BL_SEARCH_SERVICE has indexed rows', '> 0', TO_VARCHAR(MAX("source_data_num_rows")),
       IFF(MAX("source_data_num_rows") > 0, 'PASS', 'FAIL')
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- ============================================================================
-- FINAL REPORT
-- ============================================================================

SELECT '=== FAILURES (must fix before demo) ===' AS REPORT;
SELECT * FROM REGRESSION_RESULTS WHERE STATUS = 'FAIL' ORDER BY TEST_NO;

SELECT '=== FULL RESULTS ===' AS REPORT;
SELECT * FROM REGRESSION_RESULTS ORDER BY TEST_NO;

SELECT
    COUNT(*) AS TOTAL_TESTS,
    SUM(IFF(STATUS = 'PASS', 1, 0)) AS PASSED,
    SUM(IFF(STATUS = 'FAIL', 1, 0)) AS FAILED,
    IFF(SUM(IFF(STATUS = 'FAIL', 1, 0)) = 0,
        'STRUCTURALLY SOUND -- now run _regression_test_mendix_identity.py before demo',
        'FIX FAILURES ABOVE BEFORE PROCEEDING') AS VERDICT
FROM REGRESSION_RESULTS;
