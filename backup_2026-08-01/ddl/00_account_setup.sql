-- ============================================================================
-- 00_ACCOUNT_SETUP.sql
-- First script to run in a BRAND NEW Snowflake account.
-- Creates the warehouse, cost guardrail, database, schema, roles and users that
-- everything else depends on.
--
-- Run as ACCOUNTADMIN.
-- Exported 2026-08-01 from account YGVORDH-IA82097.
-- ============================================================================

USE ROLE ACCOUNTADMIN;


-- ============================================================================
-- 1. COST GUARDRAIL  (create BEFORE the warehouse so it can be attached)
-- ----------------------------------------------------------------------------
-- The original account ran on a limited trial credit, so the monitor suspends
-- compute rather than letting a runaway task drain the account.
-- ============================================================================

CREATE RESOURCE MONITOR IF NOT EXISTS VF_LOGISTICS_MONITOR
    WITH CREDIT_QUOTA = 50
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 90 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND
        ON 110 PERCENT DO SUSPEND_IMMEDIATE;


-- ============================================================================
-- 2. WAREHOUSE
-- ----------------------------------------------------------------------------
-- X-Small is deliberate: every heavy operation is a Cortex AI call, which is
-- billed per token and not by warehouse size. AUTO_SUSPEND = 60 keeps idle cost
-- near zero between demo runs.
-- ============================================================================

CREATE WAREHOUSE IF NOT EXISTS COMPUTE_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'VF Logistics: serves the Streamlit app, tasks, dynamic tables and Cortex services';

ALTER WAREHOUSE COMPUTE_WH SET RESOURCE_MONITOR = VF_LOGISTICS_MONITOR;


-- ============================================================================
-- 3. DATABASE AND SCHEMA
-- ----------------------------------------------------------------------------
-- Object names are hardcoded as MENDIX_APP.AGENTS in 46 stored procedures, in
-- the Streamlit app and in the Mendix REST calls. Keep these names unless you
-- are prepared to rewrite every reference.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS MENDIX_APP
    COMMENT = 'VF Logistics seaport operations -- Snowflake backend for the Mendix portal';

CREATE SCHEMA IF NOT EXISTS MENDIX_APP.AGENTS
    COMMENT = 'Agentic AI workflows, shipment data and SAP integration surface';

USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;


-- ============================================================================
-- 4. ROLES
-- ============================================================================

CREATE ROLE IF NOT EXISTS VF_APP_ROLE
    COMMENT = 'Least-privilege role for VF Logistics Mendix integration';

CREATE ROLE IF NOT EXISTS HACKATHON_JUDGE_ROLE
    COMMENT = 'Read-only role for H2S hackathon judges to view VF Logistics Streamlit dashboard';

GRANT ROLE VF_APP_ROLE TO ROLE SYSADMIN;
GRANT ROLE HACKATHON_JUDGE_ROLE TO ROLE SYSADMIN;


-- ============================================================================
-- 5. USERS
-- ----------------------------------------------------------------------------
-- !! DO NOT COPY CREDENTIALS FROM THE OLD ACCOUNT !!
-- Generate a fresh RSA key pair for the service user and a fresh password for
-- the judge user. The values below are placeholders that must be replaced.
--
-- Generate a key pair (OpenSSL):
--   openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt
--   openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
-- Then paste the body of rsa_key.pub (without the BEGIN/END lines) below.
-- ============================================================================

-- 5a. Machine account used by Mendix. Key-pair auth, never a password.
CREATE USER IF NOT EXISTS MENDIX_SERVICE_USER
    DEFAULT_ROLE = VF_APP_ROLE
    DEFAULT_WAREHOUSE = COMPUTE_WH
    DEFAULT_NAMESPACE = 'MENDIX_APP.AGENTS'
    TYPE = SERVICE
    COMMENT = 'Service account for the Mendix VF Logistics Portal (key-pair authentication)';

-- ALTER USER MENDIX_SERVICE_USER SET RSA_PUBLIC_KEY = '<paste rsa_key.pub body here>';

GRANT ROLE VF_APP_ROLE TO USER MENDIX_SERVICE_USER;

-- 5b. Read-only reviewer account, so a judge can open the dashboard without
--     needing a Snowflake organisation account of their own.
CREATE USER IF NOT EXISTS HACKATHON_JUDGE
    PASSWORD = '<set-a-new-strong-password>'
    DEFAULT_ROLE = HACKATHON_JUDGE_ROLE
    DEFAULT_WAREHOUSE = COMPUTE_WH
    DEFAULT_NAMESPACE = 'MENDIX_APP.AGENTS'
    MUST_CHANGE_PASSWORD = FALSE
    COMMENT = 'Read-only account for H2S hackathon judges to view VF Logistics Streamlit dashboard (no Snowflake org account required)';

GRANT ROLE HACKATHON_JUDGE_ROLE TO USER HACKATHON_JUDGE;


-- ============================================================================
-- 6. WAREHOUSE ACCESS FOR THE NON-ADMIN ROLES
-- ============================================================================

GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE VF_APP_ROLE;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE HACKATHON_JUDGE_ROLE;

GRANT USAGE ON DATABASE MENDIX_APP TO ROLE VF_APP_ROLE;
GRANT USAGE ON DATABASE MENDIX_APP TO ROLE HACKATHON_JUDGE_ROLE;


-- ============================================================================
-- 7. CORTEX ACCESS
-- ----------------------------------------------------------------------------
-- Required for AI_COMPLETE / AI_EXTRACT / PARSE_DOCUMENT and Cortex Search.
-- In most accounts SNOWFLAKE.CORTEX_USER is already granted to PUBLIC; this is
-- here so the restore does not silently fail if it is not.
-- ============================================================================

GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE VF_APP_ROLE;

-- Cortex must be available in the account region. The original account ran in
-- ap-southeast-1 (Singapore). If your new account is in a region without the
-- required models, enable cross-region inference:
--   ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';


-- ============================================================================
-- NEXT: run 01_schema_ddl.sql
-- BUT FIRST read the "identity counters" warning in README_RESTORE.md -- the
-- autoincrement START values in 01_schema_ddl.sql must be raised above the ids
-- present in the backup data, or reloaded rows will collide with new inserts.
-- ============================================================================
