-- 70_search_service.sql: the Cortex Search Service, written by hand
--
-- Not produced by tools/split_ddl.py, and the reason is worth recording. A crude
-- grep of the schema dump finds the string "CREATE OR REPLACE CORTEX SEARCH
-- SERVICE" once, which looks like the definition is present. It is not: that
-- occurrence sits inside a procedure body, i.e. inside a quoted literal, so the
-- depth-aware splitter correctly skips it and emits no search-service chunk. The
-- real definition was taken from
--   GET_DDL('CORTEX SEARCH SERVICE','MENDIX_APP.AGENTS.BL_SEARCH_SERVICE')
-- on the source account.
--
-- RUN THIS AFTER THE DATA LOAD. The service indexes BL_SEARCH_CORPUS, which is
-- regenerated from BILL_OF_LADING during the restore; creating it against an empty
-- corpus produces an empty index and the semantic B/L search on the Documents page
-- silently returns nothing.
--
-- Then SUSPEND it. An ACTIVE service keeps a serving layer warm and bills for it.
-- Search accounted for only 0.01 credits/day on the old account, so this is tidiness
-- rather than the leak, but there is no reason to pay for it between demos. Resume
-- before the SME session and before judging:
--   ALTER CORTEX SEARCH SERVICE MENDIX_APP.AGENTS.BL_SEARCH_SERVICE RESUME;

USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;

CREATE OR REPLACE CORTEX SEARCH SERVICE BL_SEARCH_SERVICE
    ON SEARCH_TEXT
    WAREHOUSE = 'COMPUTE_WH'
    TARGET_LAG = '1 hour'
    REFRESH_MODE = INCREMENTAL
    AS (
        SELECT SEARCH_TEXT, STATUS, CARRIER_NAME, PORT_OF_LOADING_LOCODE,
               PORT_OF_DISCHARGE_LOCODE, BL_NUMBER, BL_ID, TOTAL_CHARGES
        FROM MENDIX_APP.AGENTS.BL_SEARCH_CORPUS
    );

-- Expect source_data_num_rows = 10017 and indexing_state = ACTIVE before suspending.
-- The embedding model is chosen by Snowflake, not specified above; the source
-- account used snowflake-arctic-embed-m-v1.5.
SHOW CORTEX SEARCH SERVICES IN SCHEMA MENDIX_APP.AGENTS;
