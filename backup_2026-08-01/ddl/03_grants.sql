-- ============================================================================
-- 03_GRANTS.sql
-- Privileges for the two custom roles.
-- Run AFTER 01_schema_ddl.sql and 02_special_objects.sql, as ACCOUNTADMIN.
--
-- The source account had ~100 individual object grants. They are expressed here
-- as ON ALL + ON FUTURE grants, which reproduce the same effective access and
-- additionally cover objects created later.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;


-- ============================================================================
-- 1. VF_APP_ROLE  -- used by MENDIX_SERVICE_USER from the Mendix portal
-- ----------------------------------------------------------------------------
-- Read everything, write only what the workflows actually need to write, and
-- execute the stored procedures. No DDL, no DROP, no ownership.
-- ============================================================================

GRANT USAGE ON SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;

-- Read access to all data
GRANT SELECT ON ALL TABLES IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT SELECT ON ALL VIEWS IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;

-- Write access, scoped to the tables the EXECUTE AS CALLER workflow procedures
-- actually insert/update into (verified against every WORKFLOW_* and
-- SYNC_EXTRACTED_TO_BILL_OF_LADING procedure body; SAP_POST_*, CHECK_COMPLIANCE,
-- AI_EXPLAIN_ANOMALY and SAFE_AI_CALL run EXECUTE AS OWNER so they do NOT need
-- grants here even though they also write data).
GRANT INSERT, UPDATE ON TABLE MENDIX_APP.AGENTS.BILL_OF_LADING TO ROLE VF_APP_ROLE;
GRANT INSERT, UPDATE ON TABLE MENDIX_APP.AGENTS.FRAUD_ALERT TO ROLE VF_APP_ROLE;
GRANT INSERT, UPDATE ON TABLE MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED TO ROLE VF_APP_ROLE;
GRANT INSERT ON TABLE MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG TO ROLE VF_APP_ROLE;
GRANT INSERT ON TABLE MENDIX_APP.AGENTS.NOTIFICATION_LOG TO ROLE VF_APP_ROLE;

-- Execute the workflow procedures and helper functions
GRANT USAGE ON ALL PROCEDURES IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT USAGE ON ALL FUNCTIONS IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;
GRANT USAGE ON FUTURE FUNCTIONS IN SCHEMA MENDIX_APP.AGENTS TO ROLE VF_APP_ROLE;

-- Stages: READ is enough to list files and fetch presigned URLs.
-- WRITE is required only if Mendix uploads PDFs directly to the stage; the
-- portal does exactly that, so grant WRITE on the document stage.
GRANT READ, WRITE ON STAGE MENDIX_APP.AGENTS.LOGISTICS_STAGE TO ROLE VF_APP_ROLE;
GRANT READ ON STAGE MENDIX_APP.AGENTS.STREAMLIT_STAGE TO ROLE VF_APP_ROLE;

-- Cortex Analyst / Cortex Search surfaces
GRANT SELECT ON SEMANTIC VIEW MENDIX_APP.AGENTS.SV_LOGISTICS TO ROLE VF_APP_ROLE;
GRANT USAGE ON CORTEX SEARCH SERVICE MENDIX_APP.AGENTS.BL_SEARCH_SERVICE TO ROLE VF_APP_ROLE;


-- ============================================================================
-- 2. HACKATHON_JUDGE_ROLE  -- read-only reviewer access
-- ----------------------------------------------------------------------------
-- Judges must be able to see the data and the AI decisions, and open the
-- Streamlit dashboard -- but must not be able to change anything or run up cost
-- by executing AI procedures.
-- ============================================================================

GRANT USAGE ON SCHEMA MENDIX_APP.AGENTS TO ROLE HACKATHON_JUDGE_ROLE;

GRANT SELECT ON ALL TABLES IN SCHEMA MENDIX_APP.AGENTS TO ROLE HACKATHON_JUDGE_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA MENDIX_APP.AGENTS TO ROLE HACKATHON_JUDGE_ROLE;
GRANT SELECT ON ALL VIEWS IN SCHEMA MENDIX_APP.AGENTS TO ROLE HACKATHON_JUDGE_ROLE;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA MENDIX_APP.AGENTS TO ROLE HACKATHON_JUDGE_ROLE;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA MENDIX_APP.AGENTS TO ROLE HACKATHON_JUDGE_ROLE;

-- V_AI_DECISIONS is the view a judge should look at first: one row per alert
-- with the AI decision, the AI's stated reason and the full assessment text.
GRANT SELECT ON VIEW MENDIX_APP.AGENTS.V_AI_DECISIONS TO ROLE HACKATHON_JUDGE_ROLE;

-- The Streamlit app itself
GRANT USAGE ON STREAMLIT MENDIX_APP.AGENTS.VF_LOGISTICS_DASHBOARD TO ROLE HACKATHON_JUDGE_ROLE;
GRANT READ ON STAGE MENDIX_APP.AGENTS.STREAMLIT_STAGE TO ROLE HACKATHON_JUDGE_ROLE;

-- Deliberately NOT granted to the judge role: USAGE on procedures (would allow
-- triggering paid AI calls), any INSERT/UPDATE/DELETE, WRITE on any stage.


-- ============================================================================
-- 3. VERIFY
-- ============================================================================

-- SHOW GRANTS TO ROLE VF_APP_ROLE;
-- SHOW GRANTS TO ROLE HACKATHON_JUDGE_ROLE;

-- Confirm the judge can read the decisions view but cannot execute a workflow:
--   USE ROLE HACKATHON_JUDGE_ROLE;
--   SELECT * FROM MENDIX_APP.AGENTS.V_AI_DECISIONS LIMIT 5;          -- expect rows
--   CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');        -- expect denied
