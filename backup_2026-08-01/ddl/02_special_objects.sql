-- ============================================================================
-- 02_SPECIAL_OBJECTS.sql
-- Objects that GET_DDL('SCHEMA', ...) does NOT emit, so they must be recreated
-- by hand. Run this AFTER 01_schema_ddl.sql.
--
-- Exported 2026-08-01 from account YGVORDH-IA82097 (MENDIX_APP.AGENTS)
-- ============================================================================

USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;


-- ============================================================================
-- 1. STAGES
-- ----------------------------------------------------------------------------
-- Both are internal stages with a directory table enabled. The directory table
-- matters: PROCESS_BL_DOCUMENTS reads DIRECTORY(@LOGISTICS_STAGE), and it also
-- issues ALTER STAGE ... REFRESH because a directory table does not see files
-- added by PUT until refreshed.
-- ============================================================================

CREATE STAGE IF NOT EXISTS MENDIX_APP.AGENTS.LOGISTICS_STAGE
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT = 'Bill of Lading PDFs awaiting AI extraction (bill_of_lading/ prefix)';

CREATE STAGE IF NOT EXISTS MENDIX_APP.AGENTS.STREAMLIT_STAGE
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT = 'Source files for the VF_LOGISTICS_DASHBOARD Streamlit app';

-- Re-upload the staged files from this backup (run from a shell, not a worksheet):
--   PUT file://<backup>/stage_files/logistics_stage/*.pdf
--       @MENDIX_APP.AGENTS.LOGISTICS_STAGE/bill_of_lading
--       AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
--   PUT file://<backup>/stage_files/streamlit_stage/*
--       @MENDIX_APP.AGENTS.STREAMLIT_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
--   PUT file://<backup>/stage_files/streamlit_stage/pages/*
--       @MENDIX_APP.AGENTS.STREAMLIT_STAGE/pages AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
-- Then refresh the directory tables:
ALTER STAGE MENDIX_APP.AGENTS.LOGISTICS_STAGE REFRESH;
ALTER STAGE MENDIX_APP.AGENTS.STREAMLIT_STAGE REFRESH;


-- ============================================================================
-- 2. SEMANTIC VIEW (Cortex Analyst)
-- ----------------------------------------------------------------------------
-- Depends on BILL_OF_LADING, PORT_MASTER, VESSEL_REGISTRY, HS_CODE_REFERENCE,
-- so create it after the tables exist AND after the reference data is loaded.
-- ============================================================================

create or replace semantic view SV_LOGISTICS
	tables (
		BOL as MENDIX_APP.AGENTS.BILL_OF_LADING primary key (BL_ID) with synonyms=('bill of lading','shipments','BL') comment='Core shipment / Bill of Lading fact table',
		PORT_LOAD as MENDIX_APP.AGENTS.PORT_MASTER primary key (PORT_CODE) with synonyms=('loading port','origin port','seaport') comment='Seaport reference data (used here as port of loading)',
		PORT_DISCHARGE as MENDIX_APP.AGENTS.PORT_MASTER primary key (PORT_CODE) with synonyms=('discharge port','destination port') comment='Seaport reference data (used here as port of discharge)',
		VESSEL as MENDIX_APP.AGENTS.VESSEL_REGISTRY primary key (VESSEL_NAME) with synonyms=('ship','vessel') comment='Vessel registry reference',
		HS as MENDIX_APP.AGENTS.HS_CODE_REFERENCE primary key (HS_CODE) with synonyms=('commodity code','HS code') comment='HS code / commodity classification reference'
	)
	relationships (
		BOL_TO_HS as BOL(HS_CODE) references HS(HS_CODE),
		BOL_TO_PORT_DISCHARGE as BOL(PORT_OF_DISCHARGE_LOCODE) references PORT_DISCHARGE(PORT_CODE),
		BOL_TO_PORT_LOAD as BOL(PORT_OF_LOADING_LOCODE) references PORT_LOAD(PORT_CODE),
		BOL_TO_VESSEL as BOL(VESSEL_NAME) references VESSEL(VESSEL_NAME)
	)
	facts (
		BOL.GROSS_WEIGHT_KGS as GROSS_WEIGHT_KGS,
		BOL.TOTAL_CHARGES as TOTAL_CHARGES,
		BOL.FREIGHT_AMOUNT as FREIGHT_AMOUNT,
		BOL.PACKAGE_COUNT as PACKAGE_COUNT,
		BOL.VOLUME_CBM as VOLUME_CBM
	)
	dimensions (
		BOL.BL_NUMBER as BL_NUMBER,
		BOL.CARRIER_NAME as CARRIER_NAME with synonyms=('shipping line','carrier'),
		BOL.STATUS as STATUS,
		BOL.SHIPPER_NAME as SHIPPER_NAME,
		BOL.CONSIGNEE_NAME as CONSIGNEE_NAME,
		BOL.BL_DATE as BL_DATE,
		BOL.ETD as ETD,
		BOL.ETA as ETA,
		BOL.IS_DANGEROUS_GOODS as IS_DANGEROUS_GOODS,
		BOL.COMPLIANCE_CHECK_PASSED as COMPLIANCE_CHECK_PASSED,
		BOL.FRAUD_CHECK_PASSED as FRAUD_CHECK_PASSED,
		PORT_LOAD.LOADING_PORT_NAME as PORT_NAME with synonyms=('origin port name','port of loading name'),
		PORT_LOAD.LOADING_COUNTRY as COUNTRY with synonyms=('origin country'),
		PORT_DISCHARGE.DISCHARGE_PORT_NAME as PORT_NAME with synonyms=('destination port name','port of discharge name'),
		PORT_DISCHARGE.DISCHARGE_COUNTRY as COUNTRY with synonyms=('destination country'),
		VESSEL.VESSEL_TYPE as VESSEL_TYPE,
		VESSEL.OPERATOR_NAME as OPERATOR_NAME,
		VESSEL.FLAG as FLAG,
		HS.COMMODITY_DESCRIPTION as DESCRIPTION,
		HS.COMMODITY_CATEGORY as CATEGORY,
		HS.HS_IS_DANGEROUS_GOODS as IS_DANGEROUS_GOODS
	)
	metrics (
		BOL.TOTAL_SHIPMENTS as COUNT(BOL.BL_ID) comment='Total number of shipments / Bills of Lading',
		BOL.TOTAL_REVENUE as SUM(BOL.TOTAL_CHARGES) comment='Total revenue from charges',
		BOL.AVG_GROSS_WEIGHT as AVG(BOL.GROSS_WEIGHT_KGS) comment='Average gross weight in kg',
		PORT_LOAD.TOTAL_PORTS as COUNT(PORT_LOAD.PORT_CODE) comment='Total number of seaports in reference data (query PORT_LOAD alone, filtered by country, to count seaports)',
		VESSEL.TOTAL_VESSELS as COUNT(VESSEL.VESSEL_NAME) comment='Total number of vessels in registry'
	)
	comment='Semantic view for VF Logistics Bill of Lading shipments, seaports, vessels and commodity (HS) codes';


-- ============================================================================
-- 3. CORTEX SEARCH SERVICE
-- ----------------------------------------------------------------------------
-- Depends on BL_SEARCH_CORPUS, so create it after that table is loaded.
-- IMPORTANT: a suspended Cortex Search Service does NOT auto-resume on query --
-- it raises error_code 399131. Resume it explicitly before any semantic search.
-- ============================================================================

CREATE OR REPLACE CORTEX SEARCH SERVICE MENDIX_APP.AGENTS.BL_SEARCH_SERVICE
    ON SEARCH_TEXT
    WAREHOUSE = COMPUTE_WH
    TARGET_LAG = '1 hour'
    EMBEDDING_MODEL = 'snowflake-arctic-embed-m-v1.5'
    AS (
        SELECT SEARCH_TEXT, STATUS, CARRIER_NAME, PORT_OF_LOADING_LOCODE,
               PORT_OF_DISCHARGE_LOCODE, BL_NUMBER, BL_ID, TOTAL_CHARGES
        FROM MENDIX_APP.AGENTS.BL_SEARCH_CORPUS
    );

-- Suspend between demos to protect the trial credit; resume before using search:
--   ALTER CORTEX SEARCH SERVICE MENDIX_APP.AGENTS.BL_SEARCH_SERVICE SUSPEND;
--   ALTER CORTEX SEARCH SERVICE MENDIX_APP.AGENTS.BL_SEARCH_SERVICE RESUME;


-- ============================================================================
-- 4. STREAMLIT APP
-- ----------------------------------------------------------------------------
-- Upload the app files to STREAMLIT_STAGE first (see section 1).
-- ============================================================================

CREATE OR REPLACE STREAMLIT MENDIX_APP.AGENTS.VF_LOGISTICS_DASHBOARD
    ROOT_LOCATION = '@MENDIX_APP.AGENTS.STREAMLIT_STAGE'
    MAIN_FILE = 'app.py'
    QUERY_WAREHOUSE = COMPUTE_WH
    TITLE = 'VF Logistics Dashboard';

-- Packages used by the app (declared in streamlit_stage/environment.yml):
--   snowflake-snowpark-python, plotly


-- ============================================================================
-- 5. MARKETPLACE DEPENDENCY  (must exist before WORKFLOW_SANCTIONS_SCREEN runs)
-- ----------------------------------------------------------------------------
-- WORKFLOW_SANCTIONS_SCREEN and WORKFLOW_INVESTIGATE_ANOMALY read the live US
-- export-screening list from the free "Snowflake Public Data (Free)" listing.
-- Both wrap the lookup in an exception handler, so the workflow still runs if the
-- share is missing -- the sanctions match count is simply reported as -1.
-- ============================================================================

CALL SYSTEM$REQUEST_LISTING_AND_WAIT('GZTSZ290BV255', 120);
CREATE DATABASE IF NOT EXISTS SNOWFLAKE_PUBLIC_DATA_FREE FROM LISTING 'GZTSZ290BV255';

-- Sanity check:
--   SELECT COUNT(*) FROM SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE
--     .INTERNATIONAL_TRADE_ADMINISTRATION_EXPORT_SCREENED_ENTITIES_INDEX;


-- ============================================================================
-- 6. CORTEX AGENT  (MANUAL STEP -- cannot be scripted)
-- ----------------------------------------------------------------------------
-- MENDIX_APP.AGENTS.VF_LOGISTICS_AGENT could not be exported: Snowflake does not
-- support GET_DDL('AGENT', ...), DESCRIBE AGENT returns an empty agent_spec, and
-- SHOW VERSIONS IN AGENT only exposes the spec path
-- (snow://agent/MENDIX_APP.AGENTS.VF_LOGISTICS_AGENT/versions/version$1/).
--
-- Recreate it in Snowsight (AI & ML -> Agents -> Create agent) with:
--   Name             VF_LOGISTICS_AGENT  in MENDIX_APP.AGENTS
--   Orchestration    model = auto
--   Tool 1  Cortex Analyst  -> semantic view MENDIX_APP.AGENTS.SV_LOGISTICS
--   Tool 2  Cortex Search   -> service MENDIX_APP.AGENTS.BL_SEARCH_SERVICE
--   Tool 3  Custom (SQL)    -> CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT()
--   Tool 4  Custom (SQL)    -> CALL MENDIX_APP.AGENTS.WORKFLOW_INVESTIGATE_ANOMALY(:alert_id)
--   Tool 5  Custom (SQL)    -> CALL MENDIX_APP.AGENTS.WORKFLOW_AUTO_REMEDIATE(:alert_id, :action)
--
-- The agent is a convenience surface only. Every capability it exposes is also
-- reachable from SQL, so the prototype is fully demonstrable without it:
--   CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE();
--   CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');


-- ============================================================================
-- 7. CLEAN UP THE MIGRATION HELPERS
-- ----------------------------------------------------------------------------
-- These exist only to move data between accounts.
-- ============================================================================

-- DROP PROCEDURE IF EXISTS MENDIX_APP.AGENTS.BACKUP_EXPORT_ALL_TABLES();
-- DROP STAGE IF EXISTS MENDIX_APP.AGENTS.BACKUP_STAGE;
