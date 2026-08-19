-- ============================================================================
-- 00_stages.sql — internal stages, written by hand
--
-- These are NOT in 01_schema_ddl.sql. GET_DDL('SCHEMA', ..., TRUE) omits stages
-- entirely, and GET_DDL('STAGE', ...) is rejected outright with
-- "Invalid object type: 'STAGE'", so there is no way to dump them. They must be
-- recreated from the SHOW STAGES output, which is what this file encodes.
--
-- RUN THIS BEFORE 01_schema_ddl.sql. NEW_PDF_STREAM is a stream on the
-- LOGISTICS_STAGE directory table, so the stage has to exist before the schema
-- dump reaches its CREATE STREAM statements.
--
-- ENCRYPTION matters and is easy to get wrong. SHOW STAGES reported both stages
-- as type "INTERNAL NO CSE" — server-side encryption only. The default for a new
-- internal stage is SNOWFLAKE_FULL, which adds client-side encryption, and under
-- client-side encryption Snowflake cannot read the file server-side: directory
-- tables, GET_PRESIGNED_URL and CORTEX.PARSE_DOCUMENT all stop working. Getting
-- this wrong breaks PDF extraction and every "View PDF" button in the app, with
-- no error at stage-creation time.
--
-- DIRECTORY = (ENABLE = TRUE) is likewise required: DIRECTORY(@stage) is what
-- both PROCESS_BL_DOCUMENTS and the Documents page count PDFs with.
-- ============================================================================

CREATE STAGE IF NOT EXISTS MENDIX_APP.AGENTS.LOGISTICS_STAGE
    DIRECTORY  = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT    = 'Bill of lading PDFs under bill_of_lading/. Server-side encryption is mandatory: CORTEX.PARSE_DOCUMENT and GET_PRESIGNED_URL cannot read client-side-encrypted files.';

CREATE STAGE IF NOT EXISTS MENDIX_APP.AGENTS.STREAMLIT_STAGE
    DIRECTORY  = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT    = 'Source root for the VF_LOGISTICS_DASHBOARD Streamlit app: app.py, environment.yml, i18n.py, ui.py and pages/1..6.';

-- Verify before continuing. Both must report type = 'INTERNAL NO CSE' and
-- directory_enabled = 'Y'. Anything else and PDF handling will fail later in a
-- way that looks unrelated.
SHOW STAGES IN SCHEMA MENDIX_APP.AGENTS;
