
-- ============================================================================
-- SECTION 13 - The two limitations the E2E test reported, now root-caused
--
-- docs/E2E_PIPELINE_TEST.md closed with two honest limitations: the fraud path
-- was throttled rather than exercised, and AI_CALL_LOG recorded one row for a
-- run that made at least 20 Cortex calls. Both were real defects, not test
-- artefacts, and both are fixed here.
--
-- Every statement below was executed against MENDIX_APP.AGENTS and verified.
-- The two procedure patches transform the procedure's own GET_DDL rather than
-- retyping several hundred lines; each anchor must match exactly once or the
-- block aborts without touching anything, which is what prevents a silent
-- partial edit. '~' stands in for a single quote so the replacement text needs
-- no four-deep quote nesting.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 13a - AI_CALL_LOG.CALL_ID / LOG_ID were duplicated 69 and 66 times
--
-- Found while adding the extraction logging in 13b: the ledger could not take
-- new rows safely. Both id columns were "autoincrement start 1 ... noorder"
-- while seeded data already used ids up to 703 (CALL_ID) and 1102 (LOG_ID) --
-- the identical unenforced-primary-key trap that broke FRAUD_ALERT.ALERT_ID in
-- section 2. Snowflake does not enforce PRIMARY KEY, so nothing objected.
--
-- Burning the counter forward, which is what section 3 did for ALERT_ID, does
-- NOT work here and should not be trusted there either: 'noorder' allocates
-- ids from per-writer cached ranges that are not monotonic across statements.
-- Measured directly -- two consecutive single-row inserts received CALL_ID 313
-- and then 651. A burn of 150 rows left the next id at 312, below the max.
--
-- The dependable fix is to stop relying on the identity column at all and back
-- both columns with sequence defaults, which also fixes all 11 procedures that
-- insert into this table without naming CALL_ID, without editing any of them.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TABLE MENDIX_APP.AGENTS.AI_CALL_LOG_BAK_IDFIX
    CLONE MENDIX_APP.AGENTS.AI_CALL_LOG;

CREATE SEQUENCE IF NOT EXISTS MENDIX_APP.AGENTS.AI_CALL_LOG_CALL_SEQ
    START = 100000 INCREMENT = 1 ORDER
    COMMENT = 'Backs AI_CALL_LOG.CALL_ID. Starts far above every historical id and above anything the old noorder identity cache could still hand out.';

CREATE SEQUENCE IF NOT EXISTS MENDIX_APP.AGENTS.AI_CALL_LOG_LOG_SEQ
    START = 100000 INCREMENT = 1 ORDER
    COMMENT = 'Backs AI_CALL_LOG.LOG_ID for the same reason (66 duplicates).';

CREATE OR REPLACE TABLE MENDIX_APP.AGENTS.AI_CALL_LOG (
    CALL_ID        NUMBER(38,0) NOT NULL DEFAULT MENDIX_APP.AGENTS.AI_CALL_LOG_CALL_SEQ.NEXTVAL,
    MODEL_NAME     VARCHAR(50),
    PROMPT         VARCHAR(5000),
    RESPONSE       VARCHAR(10000),
    TOTAL_TOKENS   NUMBER(10,0),
    CALL_STATUS    VARCHAR(20),
    ERROR_MESSAGE  VARCHAR(1000),
    CALL_TIMESTAMP TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP(),
    CONTEXT        VARCHAR(100),
    PROCEDURE_NAME VARCHAR(100),
    INPUT_TOKENS   NUMBER(10,0),
    OUTPUT_TOKENS  NUMBER(10,0),
    LATENCY_MS     NUMBER(10,0),
    STATUS         VARCHAR(20),
    LOG_ID         NUMBER(38,0) DEFAULT MENDIX_APP.AGENTS.AI_CALL_LOG_LOG_SEQ.NEXTVAL,
    PRIMARY KEY (CALL_ID)
)
COMMENT = 'Cortex call ledger. CALL_ID/LOG_ID are sequence-backed, not autoincrement: the previous "autoincrement start 1 ... noorder" definition allocated ids from non-monotonic cached ranges well below the seeded max (703), so 69 CALL_IDs and 66 LOG_IDs were duplicated and any SELECT ... INTO keyed on CALL_ID would raise "expects exactly 1 returned row". Snowflake does not enforce the PRIMARY KEY, so the sequence is the only thing keeping these unique.';

-- Reload the 423 historical rows with dense ids. The ORDER BY only has to be
-- deterministic; the exact order of ties is irrelevant because all that matters
-- is that ROW_NUMBER is unique.
INSERT INTO MENDIX_APP.AGENTS.AI_CALL_LOG
  (CALL_ID, MODEL_NAME, PROMPT, RESPONSE, TOTAL_TOKENS, CALL_STATUS, ERROR_MESSAGE,
   CALL_TIMESTAMP, CONTEXT, PROCEDURE_NAME, INPUT_TOKENS, OUTPUT_TOKENS, LATENCY_MS,
   STATUS, LOG_ID)
WITH n AS (
  SELECT *, ROW_NUMBER() OVER (
      ORDER BY CALL_TIMESTAMP NULLS LAST, CALL_ID, LOG_ID, MODEL_NAME, CONTEXT) AS RN
  FROM MENDIX_APP.AGENTS.AI_CALL_LOG_BAK_IDFIX
)
SELECT RN, MODEL_NAME, PROMPT, RESPONSE, TOTAL_TOKENS, CALL_STATUS, ERROR_MESSAGE,
       CALL_TIMESTAMP, CONTEXT, PROCEDURE_NAME, INPUT_TOKENS, OUTPUT_TOKENS, LATENCY_MS,
       STATUS, 399 + RN
FROM n;

-- CREATE OR REPLACE TABLE drops every grant on the table.
GRANT SELECT, INSERT         ON TABLE MENDIX_APP.AGENTS.AI_CALL_LOG TO ROLE HACKATHON_JUDGE_ROLE;
GRANT SELECT, INSERT, UPDATE ON TABLE MENDIX_APP.AGENTS.AI_CALL_LOG TO ROLE VF_APP_ROLE;
GRANT USAGE ON SEQUENCE MENDIX_APP.AGENTS.AI_CALL_LOG_CALL_SEQ TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON SEQUENCE MENDIX_APP.AGENTS.AI_CALL_LOG_LOG_SEQ  TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON SEQUENCE MENDIX_APP.AGENTS.AI_CALL_LOG_CALL_SEQ TO ROLE VF_APP_ROLE;
GRANT USAGE ON SEQUENCE MENDIX_APP.AGENTS.AI_CALL_LOG_LOG_SEQ  TO ROLE VF_APP_ROLE;

-- Assertion: ids unique, payload untouched. HASH_AGG deliberately excludes the
-- id columns, since those are exactly what changed; row counts alone would not
-- have caught a payload difference.
SELECT
  (SELECT COUNT(*) FROM (SELECT CALL_ID FROM MENDIX_APP.AGENTS.AI_CALL_LOG
                         GROUP BY CALL_ID HAVING COUNT(*) > 1)) AS DUP_CALL_IDS,   -- expect 0
  (SELECT COUNT(*) FROM (SELECT LOG_ID  FROM MENDIX_APP.AGENTS.AI_CALL_LOG
                         GROUP BY LOG_ID  HAVING COUNT(*) > 1)) AS DUP_LOG_IDS,    -- expect 0
  (SELECT HASH_AGG(MODEL_NAME, PROMPT, RESPONSE, TOTAL_TOKENS, CALL_STATUS,
                   ERROR_MESSAGE, CALL_TIMESTAMP, CONTEXT, PROCEDURE_NAME,
                   INPUT_TOKENS, OUTPUT_TOKENS, LATENCY_MS, STATUS)
     FROM MENDIX_APP.AGENTS.AI_CALL_LOG) AS H_NEW,
  (SELECT HASH_AGG(MODEL_NAME, PROMPT, RESPONSE, TOTAL_TOKENS, CALL_STATUS,
                   ERROR_MESSAGE, CALL_TIMESTAMP, CONTEXT, PROCEDURE_NAME,
                   INPUT_TOKENS, OUTPUT_TOKENS, LATENCY_MS, STATUS)
     FROM MENDIX_APP.AGENTS.AI_CALL_LOG_BAK_IDFIX) AS H_OLD;                       -- expect H_NEW = H_OLD

-- ---------------------------------------------------------------------------
-- 13b - log the two Cortex calls PROCESS_BL_DOCUMENTS makes per document
--
-- PARSE_DOCUMENT (OCR) and COMPLETE (field extraction) both ran without writing
-- to the ledger, which is why 10 documents produced one AI_CALL_LOG row and the
-- FinOps page reported a fraction of real spend.
--
-- COUNT_TOKENS is metadata-only and costs nothing to call, so the COMPLETE row
-- carries real input/output token counts rather than a row-count proxy.
-- PARSE_DOCUMENT is billed per page, not per token, so its token columns are
-- left NULL instead of being filled with a number that would be wrong.
-- ---------------------------------------------------------------------------

EXECUTE IMMEDIATE $$
DECLARE
    ddl VARCHAR;  q VARCHAR;  log_cols VARCHAR;
    a_parse VARCHAR;  r_parse VARCHAR;
    a_cmpl  VARCHAR;  r_cmpl  VARCHAR;
    n_parse NUMBER;   n_cmpl  NUMBER;
BEGIN
    USE DATABASE MENDIX_APP;
    USE SCHEMA AGENTS;
    q := CHR(39);

    ddl := (SELECT GET_DDL('PROCEDURE', 'MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS()'));
    IF (ddl LIKE '%AI_CALL_LOG%') THEN
        RETURN 'ALREADY PATCHED - no change';
    END IF;

    log_cols := ' (MODEL_NAME, CONTEXT, PROCEDURE_NAME, CALL_STATUS, STATUS, LATENCY_MS, PROMPT, RESPONSE, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_TOKENS) ';

    a_parse := REPLACE('parsed_text := (SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT(~~@MENDIX_APP.AGENTS.LOGISTICS_STAGE~~, :rel_path, {~~mode~~: ~~OCR~~}):content::VARCHAR);', '~', :q);
    r_parse := REPLACE('LET t_parse0 TIMESTAMP_NTZ := CURRENT_TIMESTAMP(); ', '~', :q)
        || :a_parse
        || REPLACE(' LET t_parse_ms NUMBER := TIMESTAMPDIFF(~~MILLISECOND~~, :t_parse0, CURRENT_TIMESTAMP()); INSERT INTO MENDIX_APP.AGENTS.AI_CALL_LOG', '~', :q)
        || :log_cols
        || REPLACE('SELECT ~~parse_document-ocr~~, ~~BL_EXTRACTION_OCR~~, ~~PROCESS_BL_DOCUMENTS~~, ~~SUCCESS~~, ~~SUCCESS~~, :t_parse_ms, LEFT(:rel_path, 500), LEFT(:parsed_text, 1000), NULL, NULL, NULL;', '~', :q);

    a_cmpl := REPLACE('extracted_json := (SELECT SNOWFLAKE.CORTEX.COMPLETE(~~mistral-large2~~, :prompt));', '~', :q);
    r_cmpl := REPLACE('LET t_cmpl0 TIMESTAMP_NTZ := CURRENT_TIMESTAMP(); ', '~', :q)
        || :a_cmpl
        || REPLACE(' LET t_cmpl_ms NUMBER := TIMESTAMPDIFF(~~MILLISECOND~~, :t_cmpl0, CURRENT_TIMESTAMP()); LET tok_in NUMBER := (SELECT SNOWFLAKE.CORTEX.COUNT_TOKENS(~~mistral-large2~~, :prompt)); LET tok_out NUMBER := (SELECT SNOWFLAKE.CORTEX.COUNT_TOKENS(~~mistral-large2~~, :extracted_json)); INSERT INTO MENDIX_APP.AGENTS.AI_CALL_LOG', '~', :q)
        || :log_cols
        || REPLACE('SELECT ~~mistral-large2~~, ~~BL_EXTRACTION_JSON~~, ~~PROCESS_BL_DOCUMENTS~~, ~~SUCCESS~~, ~~SUCCESS~~, :t_cmpl_ms, LEFT(:prompt, 500), LEFT(:extracted_json, 1000), :tok_in, :tok_out, :tok_in + :tok_out;', '~', :q);

    n_parse := (LENGTH(:ddl) - LENGTH(REPLACE(:ddl, :a_parse, ''))) / LENGTH(:a_parse);
    n_cmpl  := (LENGTH(:ddl) - LENGTH(REPLACE(:ddl, :a_cmpl,  ''))) / LENGTH(:a_cmpl);
    IF (:n_parse <> 1 OR :n_cmpl <> 1) THEN
        RETURN 'ABORT - anchors matched parse=' || :n_parse || ' complete=' || :n_cmpl;
    END IF;

    ddl := REPLACE(:ddl, :a_parse, :r_parse);
    ddl := REPLACE(:ddl, :a_cmpl,  :r_cmpl);
    EXECUTE IMMEDIATE :ddl;

    -- CREATE OR REPLACE PROCEDURE silently drops all GRANT USAGE.
    GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS() TO ROLE HACKATHON_JUDGE_ROLE;
    GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS() TO ROLE VF_APP_ROLE;
    RETURN 'PATCHED - both Cortex calls now logged, USAGE re-granted';
END;
$$;

-- Assertion: exactly two ledger inserts, and token counting present.
SELECT PROCEDURE_DEFINITION ILIKE '%COUNT_TOKENS%' AS COUNTS_TOKENS,               -- expect TRUE
       REGEXP_COUNT(PROCEDURE_DEFINITION, 'INSERT INTO MENDIX_APP.AGENTS.AI_CALL_LOG') AS LOG_INSERTS  -- expect 2
FROM MENDIX_APP.INFORMATION_SCHEMA.PROCEDURES
WHERE PROCEDURE_SCHEMA = 'AGENTS' AND PROCEDURE_NAME = 'PROCESS_BL_DOCUMENTS';

-- Verified live rather than by reading the code: one PDF was staged, processed,
-- and produced exactly two rows -- BL_EXTRACTION_OCR at 1,315 ms with NULL
-- tokens, and BL_EXTRACTION_JSON at 15,445 ms with 1,082 input + 413 output =
-- 1,495 tokens -- carrying sequence ids 100002 and 100003. The document, its
-- bill of lading, its log rows and its stage file were then removed.

-- ---------------------------------------------------------------------------
-- 13c - the fraud throttle was a one-way latch, not backpressure
--
-- WORKFLOW_DETECT_AND_ACT sized its queue as every OPEN HIGH/MEDIUM alert ever
-- raised, with no time bound. That count only grows, so the first time the
-- lifetime backlog crossed P_QUEUE_LIMIT the detector switched itself off for
-- good: at 106 open alerts against a limit of 100, every subsequent run
-- returned throttled=true and added nothing, and no detection rule would ever
-- execute again. The E2E test read this as "backpressure working correctly",
-- which is why it recorded detection as untested.
--
-- Backpressure should measure the queue a human could still plausibly be
-- working, so it is now a 7-day rolling window. The same 106 alerts are 47
-- inside that window, below the limit, and the gate can recover on its own.
-- ---------------------------------------------------------------------------

EXECUTE IMMEDIATE $$
DECLARE
    ddl VARCHAR;  q VARCHAR;  anch VARCHAR;  repl VARCHAR;  n NUMBER;
BEGIN
    USE DATABASE MENDIX_APP;
    USE SCHEMA AGENTS;
    q := CHR(39);

    ddl := (SELECT GET_DDL('PROCEDURE', 'MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT(NUMBER)'));
    IF (ddl LIKE '%QUEUE_WINDOW_DAYS%') THEN
        RETURN 'ALREADY PATCHED - no change';
    END IF;

    anch := REPLACE('WHERE STATUS = ~~OPEN~~ AND SEVERITY IN (~~HIGH~~, ~~MEDIUM~~) AND BL_ID IS NOT NULL;', '~', :q);
    repl := REPLACE('WHERE STATUS = ~~OPEN~~ AND SEVERITY IN (~~HIGH~~, ~~MEDIUM~~) AND BL_ID IS NOT NULL AND DETECTED_AT >= DATEADD(day, -7, CURRENT_TIMESTAMP()) /* QUEUE_WINDOW_DAYS = 7 */;', '~', :q);

    n := (LENGTH(:ddl) - LENGTH(REPLACE(:ddl, :anch, ''))) / LENGTH(:anch);
    IF (:n <> 1) THEN
        RETURN 'ABORT - anchor matched ' || :n || ' times, expected exactly 1';
    END IF;

    ddl := REPLACE(:ddl, :anch, :repl);
    EXECUTE IMMEDIATE :ddl;

    GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT(NUMBER) TO ROLE HACKATHON_JUDGE_ROLE;
    GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT(NUMBER) TO ROLE VF_APP_ROLE;
    RETURN 'PATCHED - throttle queue is now a 7-day rolling window';
END;
$$;

-- Assertion: the lifetime backlog still exceeds the limit while the windowed
-- queue does not. If these were equal the fix would be doing nothing.
SELECT COUNT(*) AS LIFETIME_QUEUE,                                                 -- observed 106
       SUM(IFF(DETECTED_AT >= DATEADD(day, -7, CURRENT_TIMESTAMP()), 1, 0)) AS WINDOWED_QUEUE  -- observed 47
FROM MENDIX_APP.AGENTS.FRAUD_ALERT
WHERE STATUS = 'OPEN' AND SEVERITY IN ('HIGH', 'MEDIUM') AND BL_ID IS NOT NULL;

-- Verified live: WORKFLOW_DETECT_AND_ACT() returned
--   {"throttled":false,"new_alerts":8,"high_severity_open":4,"shipments_flagged":0}
-- where before the patch it returned throttled=true with new_alerts=0 on every
-- invocation. The 8 verification alerts (ALERT_ID 1500-1507) were then deleted
-- and FRAUD_ALERT is back to its 496-row demo baseline.
