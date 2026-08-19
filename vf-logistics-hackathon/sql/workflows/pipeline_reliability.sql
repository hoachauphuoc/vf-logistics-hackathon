-- ============================================================================
-- pipeline_reliability.sql
--
-- Makes the scheduled automation actually survive being switched on.
--
-- All 7 tasks had been left suspended, so nothing ran unless a human pressed a
-- button. Resuming them exposed two real defects that manual demos had never
-- reached, plus one task whose stored body contradicted the project's own
-- documentation. This script is the reproducible record of all three fixes.
--
-- ---------------------------------------------------------------------------
-- DEFECT 1 - TASK_PROCESS_NEW_BL failed on every run
-- ---------------------------------------------------------------------------
-- Symptom, from TASK_HISTORY:
--     Uncaught exception of type 'STATEMENT_ERROR' ... :
--     A SELECT INTO statement expects exactly 1 returned row
--   raised inside WORKFLOW_FULL_PIPELINE_V2.
--
-- The message reads like a zero-row problem. It is not. Verified by test:
--
--     SELECT c INTO :v FROM t WHERE 1=0;   -- does NOT raise; :v is left NULL
--
-- so "expects exactly 1 returned row" means the query returned MORE than one.
-- Do not add zero-row guards; look for a duplicate key.
--
-- Root cause: FRAUD_ALERT.ALERT_ID held 20 duplicated ids across 40 rows. The
-- column is declared
--
--     ALERT_ID NUMBER(38,0) NOT NULL autoincrement start 800 increment 1,
--     primary key (ALERT_ID)
--
-- but Snowflake does NOT enforce PRIMARY KEY or UNIQUE - the constraint is
-- metadata only. Seed rows had already been inserted with explicit ids in the
-- 800..1223 range, so as soon as the autoincrement counter reached 800 it began
-- issuing ids that already existed. Every `WHERE ALERT_ID = :v_alert_id` lookup
-- in the pipeline then matched two rows and aborted the task.
--
-- ---------------------------------------------------------------------------
-- DEFECT 2 - "no anomalies" was stored as an English sentence
-- ---------------------------------------------------------------------------
-- PROCESS_BL_DOCUMENTS wrapped the deterministic validator in
--     COALESCE(BL_DOC_ALERT(...), 'No anomalies detected')
-- turning a clean NULL into prose. That one choice cost three things:
--   * SYNC_EXTRACTED_TO_BILL_OF_LADING had to NULLIF the sentence back out;
--   * the Documents page had to compare against an English magic string;
--   * `ALERT IS NOT NULL` counted 7 clean documents as alerted.
-- It also meant Japanese and Vietnamese users read English. "No finding" is
-- NULL; the reassuring message belongs in the UI layer where it is translated.
--
-- ---------------------------------------------------------------------------
-- DEFECT 3 - TASK_FRAUD_SCAN contradicted the README
-- ---------------------------------------------------------------------------
-- Its body was an inline INSERT carrying the hardcoded thresholds
-- TOTAL_CHARGES > 50000, GROSS_WEIGHT_KGS > 100000 and cost/kg > 10 - exactly
-- the magic numbers the README states were replaced by percentile calibration.
-- It also bypassed the queue-backpressure logic and emitted ALERT_TYPE
-- 'NEW_PARTY_CHECK', an undocumented eighth enum value which, being the ELSE
-- branch, would have become the most common one. Resuming it as written would
-- have refilled the table with uncalibrated alerts.
--
-- Run order matters: sections 1-3 fix data and code, section 4 resumes tasks.
-- ============================================================================

USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;


-- ============================================================================
-- 1. Prove the diagnosis before changing anything
-- ============================================================================

-- 1a. SELECT INTO tolerates zero rows but not two. Expect:
--     'zero rows -> NULL (no error) | two rows -> RAISES: ...'
DECLARE
  v_zero NUMBER;
  v_msg  VARCHAR;
BEGIN
  SELECT ALERT_ID INTO :v_zero FROM FRAUD_ALERT WHERE 1 = 0;
  v_msg := 'zero rows -> ' || IFF(:v_zero IS NULL, 'NULL (no error)', 'unexpected');
  BEGIN
    LET v_two NUMBER;
    SELECT ALERT_ID INTO :v_two FROM FRAUD_ALERT LIMIT 2;
    v_msg := :v_msg || ' | two rows -> no error (unexpected)';
  EXCEPTION
    WHEN OTHER THEN
      v_msg := :v_msg || ' | two rows -> RAISES: ' || LEFT(SQLERRM, 60);
  END;
  RETURN :v_msg;
END;

-- 1b. The duplicate keys. Expect 20 keys over 40 rows before the fix.
SELECT COUNT(*) AS DUP_KEYS, SUM(N) AS DUP_ROWS
FROM (SELECT ALERT_ID, COUNT(*) AS N FROM FRAUD_ALERT GROUP BY ALERT_ID HAVING COUNT(*) > 1);


-- ============================================================================
-- 2. Fix the duplicate ALERT_ID values
-- ============================================================================
-- The colliding rows are genuinely DIFFERENT alerts that happen to share an id
-- (e.g. a DUPLICATE_BL_NUMBER alert from August 1 and a COST_PER_KG_ANOMALY
-- from August 17 both holding id 800), so they must be renumbered, not deleted.
--
-- (ALERT_ID, CREATED_AT) is verified unique below, which makes it a safe key
-- for the remap. The EARLIER row in each group keeps its id, because older
-- alerts are the ones referenced from AI_ANOMALY_REPORT and WORKFLOW_AUDIT_LOG.

-- 2a. Guard: this must return 0, otherwise the remap key is not unique.
SELECT COUNT(*) AS NONUNIQUE_PAIRS
FROM (SELECT ALERT_ID, CREATED_AT FROM FRAUD_ALERT
      GROUP BY ALERT_ID, CREATED_AT HAVING COUNT(*) > 1);

-- 2b. Build the remap, allocating fresh ids above the current maximum.
CREATE OR REPLACE TEMPORARY TABLE TMP_ALERT_REMAP AS
WITH dups AS (
    SELECT ALERT_ID FROM FRAUD_ALERT GROUP BY ALERT_ID HAVING COUNT(*) > 1),
ranked AS (
    SELECT a.ALERT_ID, a.CREATED_AT,
           ROW_NUMBER() OVER (PARTITION BY a.ALERT_ID ORDER BY a.CREATED_AT) AS RN
    FROM FRAUD_ALERT a JOIN dups d ON d.ALERT_ID = a.ALERT_ID)
SELECT ALERT_ID AS OLD_ID, CREATED_AT,
       (SELECT MAX(ALERT_ID) FROM FRAUD_ALERT)
         + ROW_NUMBER() OVER (ORDER BY ALERT_ID, CREATED_AT) AS NEW_ID
FROM ranked
WHERE RN > 1;

-- 2c. Guard: no new id may collide with an existing one. Expect 0.
SELECT SUM(CASE WHEN NEW_ID IN (SELECT ALERT_ID FROM FRAUD_ALERT) THEN 1 ELSE 0 END)
         AS COLLIDES_WITH_EXISTING
FROM TMP_ALERT_REMAP;

-- 2d. Apply.
UPDATE FRAUD_ALERT a
SET ALERT_ID = r.NEW_ID
FROM TMP_ALERT_REMAP r
WHERE a.ALERT_ID = r.OLD_ID AND a.CREATED_AT = r.CREATED_AT;

DROP TABLE IF EXISTS TMP_ALERT_REMAP;


-- ============================================================================
-- 3. Stop the generator producing further collisions
-- ============================================================================
-- The counter was at 1008 while the maximum id was 1243, so roughly 235 more
-- collisions were already queued.
--
-- Snowflake offers no way to reseed an identity column. Attaching a sequence
-- instead fails outright:
--     ALTER TABLE FRAUD_ALERT
--       ALTER COLUMN ALERT_ID SET DEFAULT SEQ_FRAUD_ALERT_ID.NEXTVAL;
--     -- Unsupported feature 'Alter Column Set Default'
-- and rebuilding the table would silently drop all 101 judge grants. So the
-- counter is burned forward with a throwaway bulk insert, which is crude but
-- reversible and leaves schema and grants untouched.

-- 3a. Probe where the counter currently sits.
INSERT INTO FRAUD_ALERT (ALERT_TYPE, SEVERITY, STATUS, DESCRIPTION, CREATED_AT)
SELECT '__SEQ_BURN__', 'LOW', 'DISMISSED', 'sequence reseed probe', CURRENT_TIMESTAMP();

SELECT ALERT_ID AS COUNTER_NOW FROM FRAUD_ALERT WHERE ALERT_TYPE = '__SEQ_BURN__';

-- 3b. Burn past the maximum real id. STATUS is DISMISSED so that even while
--     these rows exist they cannot enter an OPEN alert queue.
INSERT INTO FRAUD_ALERT (ALERT_TYPE, SEVERITY, STATUS, DESCRIPTION, CREATED_AT)
SELECT '__SEQ_BURN__', 'LOW', 'DISMISSED', 'sequence reseed burn', CURRENT_TIMESTAMP()
FROM TABLE(GENERATOR(ROWCOUNT => 250));

-- 3c. Confirm the counter cleared the real maximum, then remove the markers.
SELECT MAX(CASE WHEN ALERT_TYPE = '__SEQ_BURN__' THEN ALERT_ID END) AS BURN_MAX,
       MAX(CASE WHEN ALERT_TYPE <> '__SEQ_BURN__' THEN ALERT_ID END) AS REAL_MAX
FROM FRAUD_ALERT;

DELETE FROM FRAUD_ALERT WHERE ALERT_TYPE = '__SEQ_BURN__';


-- ============================================================================
-- 4. Harden the id lookups so a future collision degrades instead of stopping
-- ============================================================================
-- Patched by transforming the procedure's own GET_DDL rather than retyping a
-- multi-KB body: everything not explicitly named stays byte-identical. Each
-- target's replacement count is asserted to be exactly 1 first.
--
-- Two shapes of fix:
--   * where a NULL result is meaningful (the loop's "no more alerts" case, and
--     the shipper lookup), a scalar subquery replaces SELECT ... INTO, so the
--     existing `IF ... IS NULL THEN BREAK` guard does the work;
--   * where exactly one row is expected, LIMIT 1 makes a duplicate harmless.

-- 4a. Assert each target appears exactly once. All five must return 1.
WITH d AS (SELECT GET_DDL('PROCEDURE',
                          'MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2(VARCHAR,NUMBER)') AS DDL)
SELECT
 (LENGTH(DDL)-LENGTH(REPLACE(DDL,$$SELECT ALERT_ID, SEVERITY INTO :v_alert_id, :v_severity FROM MENDIX_APP.AGENTS.FRAUD_ALERT$$)))
   /LENGTH($$SELECT ALERT_ID, SEVERITY INTO :v_alert_id, :v_severity FROM MENDIX_APP.AGENTS.FRAUD_ALERT$$) AS T1,
 (LENGTH(DDL)-LENGTH(REPLACE(DDL,$$ORDER BY CASE SEVERITY WHEN ''HIGH'' THEN 1 ELSE 2 END, CREATED_AT DESC LIMIT 1;$$)))
   /LENGTH($$ORDER BY CASE SEVERITY WHEN ''HIGH'' THEN 1 ELSE 2 END, CREATED_AT DESC LIMIT 1;$$) AS T2,
 (LENGTH(DDL)-LENGTH(REPLACE(DDL,$$SELECT SHIPPER_NAME INTO :v_shipper FROM MENDIX_APP.AGENTS.BILL_OF_LADING$$)))
   /LENGTH($$SELECT SHIPPER_NAME INTO :v_shipper FROM MENDIX_APP.AGENTS.BILL_OF_LADING$$) AS T3,
 (LENGTH(DDL)-LENGTH(REPLACE(DDL,$$INTO :v_ai_action, :v_ai_reason FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id;$$)))
   /LENGTH($$INTO :v_ai_action, :v_ai_reason FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id;$$) AS T4,
 (LENGTH(DDL)-LENGTH(REPLACE(DDL,$$SELECT BL_ID INTO :v_sap_bl_id FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id;$$)))
   /LENGTH($$SELECT BL_ID INTO :v_sap_bl_id FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id;$$) AS T5
FROM d;

-- 4b. Build the patched DDL. Note v_severity was assigned but never read, so it
--     is dropped from the projection.
CREATE OR REPLACE TEMPORARY TABLE TMP_PROC_PATCH AS
SELECT REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
   GET_DDL('PROCEDURE','MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2(VARCHAR,NUMBER)'),
   $$SELECT ALERT_ID, SEVERITY INTO :v_alert_id, :v_severity FROM MENDIX_APP.AGENTS.FRAUD_ALERT$$,
   $$v_alert_id := (SELECT ALERT_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT$$),
   $$ORDER BY CASE SEVERITY WHEN ''HIGH'' THEN 1 ELSE 2 END, CREATED_AT DESC LIMIT 1;$$,
   $$ORDER BY CASE SEVERITY WHEN ''HIGH'' THEN 1 ELSE 2 END, CREATED_AT DESC LIMIT 1);$$),
   $$SELECT SHIPPER_NAME INTO :v_shipper FROM MENDIX_APP.AGENTS.BILL_OF_LADING$$,
   $$v_shipper := (SELECT SHIPPER_NAME FROM MENDIX_APP.AGENTS.BILL_OF_LADING$$),
   $$WHERE BL_ID = (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id);$$,
   $$WHERE BL_ID = (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id LIMIT 1));$$),
   $$INTO :v_ai_action, :v_ai_reason FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id;$$,
   $$INTO :v_ai_action, :v_ai_reason FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id LIMIT 1;$$),
   $$SELECT BL_ID INTO :v_sap_bl_id FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id;$$,
   $$SELECT BL_ID INTO :v_sap_bl_id FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :v_alert_id LIMIT 1;$$
) AS DDL;

-- 4c. Apply. The block must set its own database/schema context, or
--     CREATE PROCEDURE fails with "does not have a current database".
DECLARE S VARCHAR;
BEGIN
  USE DATABASE MENDIX_APP;
  USE SCHEMA AGENTS;
  S := (SELECT DDL FROM MENDIX_APP.AGENTS.TMP_PROC_PATCH);
  EXECUTE IMMEDIATE :S;
  RETURN 'WORKFLOW_FULL_PIPELINE_V2 patched';
END;


-- ============================================================================
-- 5. Remove the stored English "no anomalies" sentinel
-- ============================================================================
WITH d AS (SELECT GET_DDL('PROCEDURE','MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS()') AS DDL)
SELECT (LENGTH(DDL)-LENGTH(REPLACE(DDL,
   $$COALESCE(MENDIX_APP.AGENTS.BL_DOC_ALERT(:v_bl, :v_container, :v_vessel, :v_weight, :v_date), ''No anomalies detected'')$$)))
   /LENGTH($$COALESCE(MENDIX_APP.AGENTS.BL_DOC_ALERT(:v_bl, :v_container, :v_vessel, :v_weight, :v_date), ''No anomalies detected'')$$)
   AS MUST_BE_1
FROM d;

CREATE OR REPLACE TEMPORARY TABLE TMP_PROC_PATCH AS
SELECT REPLACE(
   GET_DDL('PROCEDURE','MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS()'),
   $$COALESCE(MENDIX_APP.AGENTS.BL_DOC_ALERT(:v_bl, :v_container, :v_vessel, :v_weight, :v_date), ''No anomalies detected'')$$,
   $$MENDIX_APP.AGENTS.BL_DOC_ALERT(:v_bl, :v_container, :v_vessel, :v_weight, :v_date)$$
) AS DDL;

DECLARE S VARCHAR;
BEGIN
  USE DATABASE MENDIX_APP;
  USE SCHEMA AGENTS;
  S := (SELECT DDL FROM MENDIX_APP.AGENTS.TMP_PROC_PATCH);
  EXECUTE IMMEDIATE :S;
  RETURN 'PROCESS_BL_DOCUMENTS sentinel removed';
END;

DROP TABLE IF EXISTS TMP_PROC_PATCH;

-- Normalise the rows already written with the sentinel.
UPDATE BILL_OF_LADING_EXTRACTED SET ALERT = NULL WHERE ALERT = 'No anomalies detected';


-- ============================================================================
-- 6. Re-grant. CREATE OR REPLACE PROCEDURE silently drops all GRANT USAGE.
-- ============================================================================
GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2(VARCHAR,NUMBER)
  TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS()
  TO ROLE HACKATHON_JUDGE_ROLE;


-- ============================================================================
-- 7. Repoint TASK_FRAUD_SCAN at the calibrated procedure, then resume all tasks
-- ============================================================================
-- REMOVE WHEN is not optional. The old body consumed BL_CHANGE_STREAM, which is
-- what advanced the stream offset and cleared the condition. The new body does
-- not touch that stream, so SYSTEM$STREAM_HAS_DATA would stay true forever and
-- the task would fire every interval indefinitely.
ALTER TASK MENDIX_APP.AGENTS.TASK_FRAUD_SCAN
  MODIFY AS CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT(100);
ALTER TASK MENDIX_APP.AGENTS.TASK_FRAUD_SCAN REMOVE WHEN;
-- A full-table percentile scan every 5 minutes is wasteful and would sit
-- permanently at the per-run alert cap.
ALTER TASK MENDIX_APP.AGENTS.TASK_FRAUD_SCAN SET SCHEDULE = '60 MINUTE';

-- No task has a predecessor, so each resumes independently.
ALTER TASK MENDIX_APP.AGENTS.TASK_FRAUD_SCAN RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_PROCESS_NEW_BL RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_COMPLIANCE_CHECK RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_REFRESH_PDF_URLS RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_AI_EXPLAIN_ANOMALY RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_NOTIFY_HIGH_FRAUD RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_GENERATE_WEEKLY_INSIGHTS RESUME;


-- ============================================================================
-- 8. Assertions. Every check below must hold.
-- ============================================================================

-- 8a. No duplicate alert ids, and the counter is clear of the maximum.
--     Expect DUP_KEYS = 0 and DISTINCT_IDS = TOTAL_ROWS.
SELECT (SELECT COUNT(*) FROM (SELECT ALERT_ID FROM FRAUD_ALERT
          GROUP BY ALERT_ID HAVING COUNT(*) > 1))       AS DUP_KEYS,
       COUNT(*)                                          AS TOTAL_ROWS,
       COUNT(DISTINCT ALERT_ID)                          AS DISTINCT_IDS,
       SUM(CASE WHEN ALERT_TYPE = '__SEQ_BURN__' THEN 1 ELSE 0 END) AS LEFTOVER_MARKERS
FROM FRAUD_ALERT;

-- 8b. Stored ALERT and CONFIDENCE_SCORE agree with the deterministic UDFs on
--     every row, in every status. Both mismatch columns must be 0.
SELECT STATUS, COUNT(*) AS DOCS,
       SUM(CASE WHEN BL_DOC_ALERT(BL_NUMBER, CONTAINER_NUMBER, VESSEL_NAME,
                                  GROSS_WEIGHT_KG, DATE_OF_ISSUE)
                     IS NOT DISTINCT FROM ALERT THEN 0 ELSE 1 END) AS ALERT_MISMATCH,
       SUM(CASE WHEN BL_DOC_CONFIDENCE(BL_NUMBER, CONTAINER_NUMBER, VESSEL_NAME,
                                       GROSS_WEIGHT_KG, DATE_OF_ISSUE)
                     = CONFIDENCE_SCORE THEN 0 ELSE 1 END) AS CONF_MISMATCH
FROM BILL_OF_LADING_EXTRACTED
GROUP BY STATUS ORDER BY STATUS;

-- 8c. No row still stores the English sentinel. Expect 0.
SELECT COUNT(*) AS SENTINELS_REMAINING
FROM BILL_OF_LADING_EXTRACTED WHERE ALERT = 'No anomalies detected';

-- 8d. The task body that used to fail now completes. Expect
--     "status":"COMPLETED" in the returned JSON.
CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE();

-- 8e. All 7 tasks report state = started, and TASK_FRAUD_SCAN shows
--     `CALL ... WORKFLOW_DETECT_AND_ACT(100)` with an empty condition.
SHOW TASKS IN SCHEMA MENDIX_APP.AGENTS;

-- 8f. Grants survived the two CREATE OR REPLACE statements. Expect 101.
SHOW GRANTS TO ROLE HACKATHON_JUDGE_ROLE;


-- ============================================================================
-- 9. Make every task event-driven: run only when data actually changed
-- ============================================================================
-- Resuming the tasks revealed a second class of waste, separate from the
-- failures above. TASK_PROCESS_NEW_BL was already gated on
-- SYSTEM$STREAM_HAS_DATA('NEW_PDF_STREAM'), yet it SUCCEEDED every 5 minutes
-- while reporting "processed": 0. The reason:
--
--     SELECT SYSTEM$STREAM_HAS_DATA('NEW_PDF_STREAM'),
--            (SELECT COUNT(*) FROM NEW_PDF_STREAM);
--     -- TRUE, 28
--
--     SELECT PROCEDURE_NAME FROM INFORMATION_SCHEMA.PROCEDURES
--     WHERE PROCEDURE_DEFINITION ILIKE '%NEW_PDF_STREAM%';
--     -- no rows
--
-- Nothing in the codebase ever read the stream. A stream's offset only advances
-- when a DML statement consumes it, so the condition stayed true permanently and
-- the task started a warehouse every 5 minutes to do nothing. The same was true
-- of BL_CHANGE_STREAM. A stream-gated task whose body does not consume its
-- stream is not event-driven; it is a poll with extra steps.
--
-- Three rules follow, and this section applies all of them:
--
--   1. Every task consumes its own stream. A stream can only be read once, so
--      two tasks sharing one stream would race and one would never fire. Hence
--      one dedicated stream per task, five of them created here.
--   2. Every task body performs consuming DML even when there is no work. The
--      consumer is an aggregate SELECT, which returns exactly one row even over
--      an empty stream, so the offset always advances and the condition always
--      clears.
--   3. Every task guards the expensive call behind a real row count. This is not
--      redundant: SYSTEM$STREAM_HAS_DATA can return TRUE while the stream holds
--      zero rows, and it did - the first run of the rewritten TASK_FRAUD_SCAN
--      logged 'changed_rows=0' and correctly skipped a full-table percentile
--      scan that the WHEN condition alone would have authorised.
--
-- Result: a skipped run reports "Conditional expression for task evaluated to
-- false" and starts no warehouse.

-- 9a. One stream per consumer.
CREATE OR REPLACE STREAM MENDIX_APP.AGENTS.BL_COMPLIANCE_STREAM
  ON TABLE MENDIX_APP.AGENTS.BILL_OF_LADING
  COMMENT = 'Feeds TASK_COMPLIANCE_CHECK.';
CREATE OR REPLACE STREAM MENDIX_APP.AGENTS.BL_INSIGHTS_STREAM
  ON TABLE MENDIX_APP.AGENTS.BILL_OF_LADING
  COMMENT = 'Feeds TASK_GENERATE_WEEKLY_INSIGHTS. A weekly executive report over unchanged data is not worth the Cortex spend.';
CREATE OR REPLACE STREAM MENDIX_APP.AGENTS.FRAUD_EXPLAIN_STREAM
  ON TABLE MENDIX_APP.AGENTS.FRAUD_ALERT
  COMMENT = 'Feeds TASK_AI_EXPLAIN_ANOMALY.';
CREATE OR REPLACE STREAM MENDIX_APP.AGENTS.FRAUD_NOTIFY_STREAM
  ON TABLE MENDIX_APP.AGENTS.FRAUD_ALERT
  COMMENT = 'Feeds TASK_NOTIFY_HIGH_FRAUD. Separate offset from FRAUD_EXPLAIN_STREAM so the two tasks do not race.';
CREATE OR REPLACE STREAM MENDIX_APP.AGENTS.EXTRACTED_DOCS_STREAM
  ON TABLE MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED
  COMMENT = 'Feeds TASK_REFRESH_PDF_URLS. The app calls GET_PDF_URL on demand, so only newly extracted documents need a stored URL refreshed.';

-- 9b. A work list for compliance. This exists because of a specific trap.
--
-- CHECK_COMPLIANCE writes to BILL_OF_LADING, which is the table
-- BL_COMPLIANCE_STREAM watches - so the task re-arms its own condition and would
-- re-check the row it just checked, forever. Filtering the stream to
-- METADATA$ACTION = 'INSERT' breaks that cycle.
--
-- It also matters WHICH rows the task selects. The original body picked any row
-- with COMPLIANCE_CHECK_PASSED IS NULL, and all 10,017 rows are unchecked: at one
-- row per 30 minutes that is a 209-day backfill driven by the task's own writes,
-- not by new data, on an account that expires in weeks. Draining history is a
-- bulk operation (Compliance page -> Bulk Scan), not an event-driven task, so the
-- task now only ever processes B/Ls that genuinely arrived.
--
-- The queue is needed because the stream can only be read once: without it, any
-- arrivals beyond a single run's limit would be consumed and silently lost.
CREATE TABLE IF NOT EXISTS MENDIX_APP.AGENTS.COMPLIANCE_QUEUE (
    BL_ID      NUMBER(38,0) NOT NULL,
    QUEUED_AT  TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP(),
    CHECKED_AT TIMESTAMP_NTZ(9)
)
COMMENT = 'Work list for TASK_COMPLIANCE_CHECK. Deliberately does NOT contain the pre-existing unchecked rows.';

-- 9c. Tasks must be suspended before their body or condition can be altered,
--     otherwise: "Unable to update graph with root task ... since that root task
--     is not suspended."
ALTER TASK MENDIX_APP.AGENTS.TASK_PROCESS_NEW_BL SUSPEND;
ALTER TASK MENDIX_APP.AGENTS.TASK_FRAUD_SCAN SUSPEND;
ALTER TASK MENDIX_APP.AGENTS.TASK_COMPLIANCE_CHECK SUSPEND;
ALTER TASK MENDIX_APP.AGENTS.TASK_REFRESH_PDF_URLS SUSPEND;
ALTER TASK MENDIX_APP.AGENTS.TASK_AI_EXPLAIN_ANOMALY SUSPEND;
ALTER TASK MENDIX_APP.AGENTS.TASK_NOTIFY_HIGH_FRAUD SUSPEND;
ALTER TASK MENDIX_APP.AGENTS.TASK_GENERATE_WEEKLY_INSIGHTS SUSPEND;

-- 9d. Bodies. Each measures the real row count first (a plain SELECT does not
--     consume a stream), then consumes, then guards the expensive call.
ALTER TASK MENDIX_APP.AGENTS.TASK_PROCESS_NEW_BL MODIFY AS
DECLARE
  v_changed NUMBER;
BEGIN
  v_changed := (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.NEW_PDF_STREAM);
  INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
      (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
  SELECT 'TASK_PROCESS_NEW_BL', 'CONSUME_NEW_PDF_STREAM', 0,
         'new_files=' || COUNT(*), 'stream offset advanced', 0, 'SUCCESS'
  FROM MENDIX_APP.AGENTS.NEW_PDF_STREAM;
  IF (:v_changed > 0) THEN
    CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE();
    RETURN 'ingested, new_files=' || :v_changed;
  END IF;
  RETURN 'skipped: stream flagged but held no rows';
END;

ALTER TASK MENDIX_APP.AGENTS.TASK_FRAUD_SCAN MODIFY AS
DECLARE
  v_changed NUMBER;
BEGIN
  v_changed := (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.BL_CHANGE_STREAM);
  INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
      (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
  SELECT 'TASK_FRAUD_SCAN', 'CONSUME_BL_CHANGE_STREAM', 0,
         'changed_rows=' || COUNT(*), 'stream offset advanced', 0, 'SUCCESS'
  FROM MENDIX_APP.AGENTS.BL_CHANGE_STREAM;
  IF (:v_changed > 0) THEN
    CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT(100);
    RETURN 'scanned, changed_rows=' || :v_changed;
  END IF;
  RETURN 'skipped: stream flagged but held no rows';
END;

ALTER TASK MENDIX_APP.AGENTS.TASK_COMPLIANCE_CHECK MODIFY AS
DECLARE
  v_new  NUMBER DEFAULT 0;
  v_done NUMBER DEFAULT 0;
  v_bl   NUMBER;
BEGIN
  INSERT INTO MENDIX_APP.AGENTS.COMPLIANCE_QUEUE (BL_ID)
  SELECT DISTINCT s.BL_ID
  FROM MENDIX_APP.AGENTS.BL_COMPLIANCE_STREAM s
  WHERE s.METADATA$ACTION = 'INSERT'
    AND s.BL_ID IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM MENDIX_APP.AGENTS.COMPLIANCE_QUEUE q WHERE q.BL_ID = s.BL_ID);
  v_new := SQLROWCOUNT;
  FOR i IN 1 TO 5 DO
    v_bl := (SELECT BL_ID FROM MENDIX_APP.AGENTS.COMPLIANCE_QUEUE
             WHERE CHECKED_AT IS NULL ORDER BY QUEUED_AT LIMIT 1);
    IF (v_bl IS NULL) THEN
      BREAK;
    END IF;
    CALL MENDIX_APP.AGENTS.CHECK_COMPLIANCE(:v_bl);
    UPDATE MENDIX_APP.AGENTS.COMPLIANCE_QUEUE
       SET CHECKED_AT = CURRENT_TIMESTAMP() WHERE BL_ID = :v_bl;
    v_done := :v_done + 1;
  END FOR;
  INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
      (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
  VALUES ('TASK_COMPLIANCE_CHECK', 'CONSUME_BL_COMPLIANCE_STREAM', 0,
          'queued=' || :v_new, 'checked=' || :v_done, 0, 'SUCCESS');
  RETURN 'queued=' || :v_new || ', checked=' || :v_done;
END;

ALTER TASK MENDIX_APP.AGENTS.TASK_AI_EXPLAIN_ANOMALY MODIFY AS
DECLARE
  v_changed NUMBER;
  v_alert_id NUMBER;
BEGIN
  v_changed := (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.FRAUD_EXPLAIN_STREAM);
  INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
      (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
  SELECT 'TASK_AI_EXPLAIN_ANOMALY', 'CONSUME_FRAUD_EXPLAIN_STREAM', 0,
         'changed_alerts=' || COUNT(*), 'stream offset advanced', 0, 'SUCCESS'
  FROM MENDIX_APP.AGENTS.FRAUD_EXPLAIN_STREAM;
  IF (:v_changed = 0) THEN
    RETURN 'skipped: stream flagged but held no rows';
  END IF;
  v_alert_id := (SELECT ALERT_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT
                 WHERE SEVERITY = 'HIGH' AND STATUS = 'OPEN'
                   AND NOT EXISTS (SELECT 1 FROM MENDIX_APP.AGENTS.AI_ANOMALY_REPORT
                                   WHERE BL_IDS LIKE '%' || ALERT_ID || '%')
                 LIMIT 1);
  IF (:v_alert_id IS NULL) THEN
    RETURN 'skipped: no unexplained HIGH/OPEN alert';
  END IF;
  CALL MENDIX_APP.AGENTS.AI_EXPLAIN_ANOMALY(:v_alert_id, 'EN');
  RETURN 'explained ALERT_ID=' || :v_alert_id;
END;

ALTER TASK MENDIX_APP.AGENTS.TASK_NOTIFY_HIGH_FRAUD MODIFY AS
DECLARE
  v_changed NUMBER;
BEGIN
  v_changed := (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.FRAUD_NOTIFY_STREAM);
  INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
      (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
  SELECT 'TASK_NOTIFY_HIGH_FRAUD', 'CONSUME_FRAUD_NOTIFY_STREAM', 0,
         'changed_alerts=' || COUNT(*), 'stream offset advanced', 0, 'SUCCESS'
  FROM MENDIX_APP.AGENTS.FRAUD_NOTIFY_STREAM;
  IF (:v_changed > 0) THEN
    CALL MENDIX_APP.AGENTS.NOTIFY_HIGH_FRAUD_ALERTS();
    RETURN 'notified, changed_alerts=' || :v_changed;
  END IF;
  RETURN 'skipped: stream flagged but held no rows';
END;

ALTER TASK MENDIX_APP.AGENTS.TASK_REFRESH_PDF_URLS MODIFY AS
DECLARE
  v_changed NUMBER;
BEGIN
  v_changed := (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.EXTRACTED_DOCS_STREAM);
  INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
      (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
  SELECT 'TASK_REFRESH_PDF_URLS', 'CONSUME_EXTRACTED_DOCS_STREAM', 0,
         'changed_docs=' || COUNT(*), 'stream offset advanced', 0, 'SUCCESS'
  FROM MENDIX_APP.AGENTS.EXTRACTED_DOCS_STREAM;
  IF (:v_changed > 0) THEN
    CALL MENDIX_APP.AGENTS.REFRESH_PDF_PRESIGNED_URLS();
    RETURN 'refreshed, changed_docs=' || :v_changed;
  END IF;
  RETURN 'skipped: stream flagged but held no rows';
END;

ALTER TASK MENDIX_APP.AGENTS.TASK_GENERATE_WEEKLY_INSIGHTS MODIFY AS
DECLARE
  v_changed NUMBER;
BEGIN
  v_changed := (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.BL_INSIGHTS_STREAM);
  INSERT INTO MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
      (WORKFLOW_NAME, STEP_NAME, STEP_ORDER, INPUT_PARAMS, OUTPUT_RESULT, EXECUTION_TIME_MS, STATUS)
  SELECT 'TASK_GENERATE_WEEKLY_INSIGHTS', 'CONSUME_BL_INSIGHTS_STREAM', 0,
         'changed_rows=' || COUNT(*), 'stream offset advanced', 0, 'SUCCESS'
  FROM MENDIX_APP.AGENTS.BL_INSIGHTS_STREAM;
  IF (:v_changed > 0) THEN
    CALL MENDIX_APP.AGENTS.AI_GENERATE_INSIGHTS();
    RETURN 'insights generated, changed_rows=' || :v_changed;
  END IF;
  RETURN 'skipped: no shipment activity this period';
END;

-- 9e. Conditions. One stream per task, matching the bodies above.
ALTER TASK MENDIX_APP.AGENTS.TASK_PROCESS_NEW_BL
  MODIFY WHEN SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.NEW_PDF_STREAM');
ALTER TASK MENDIX_APP.AGENTS.TASK_FRAUD_SCAN
  MODIFY WHEN SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.BL_CHANGE_STREAM');
ALTER TASK MENDIX_APP.AGENTS.TASK_COMPLIANCE_CHECK
  MODIFY WHEN SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.BL_COMPLIANCE_STREAM');
ALTER TASK MENDIX_APP.AGENTS.TASK_REFRESH_PDF_URLS
  MODIFY WHEN SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.EXTRACTED_DOCS_STREAM');
ALTER TASK MENDIX_APP.AGENTS.TASK_AI_EXPLAIN_ANOMALY
  MODIFY WHEN SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.FRAUD_EXPLAIN_STREAM');
ALTER TASK MENDIX_APP.AGENTS.TASK_NOTIFY_HIGH_FRAUD
  MODIFY WHEN SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.FRAUD_NOTIFY_STREAM');
ALTER TASK MENDIX_APP.AGENTS.TASK_GENERATE_WEEKLY_INSIGHTS
  MODIFY WHEN SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.BL_INSIGHTS_STREAM');

ALTER TASK MENDIX_APP.AGENTS.TASK_PROCESS_NEW_BL RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_FRAUD_SCAN RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_COMPLIANCE_CHECK RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_REFRESH_PDF_URLS RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_AI_EXPLAIN_ANOMALY RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_NOTIFY_HIGH_FRAUD RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_GENERATE_WEEKLY_INSIGHTS RESUME;


-- ============================================================================
-- 10. Assertions for the event-driven behaviour
-- ============================================================================

-- 10a. Every task started, every task carries a distinct stream condition.
--      Expect 7 rows, all state = started, all condition non-empty.
SHOW TASKS IN SCHEMA MENDIX_APP.AGENTS;

-- 10b. Once the backlog has drained, streams disarm. A FALSE here is what makes
--      the corresponding task skip for free.
SELECT 'NEW_PDF' AS STREAM, SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.NEW_PDF_STREAM') AS ARMED
UNION ALL SELECT 'BL_CHANGE',      SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.BL_CHANGE_STREAM')
UNION ALL SELECT 'BL_COMPLIANCE',  SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.BL_COMPLIANCE_STREAM')
UNION ALL SELECT 'BL_INSIGHTS',    SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.BL_INSIGHTS_STREAM')
UNION ALL SELECT 'FRAUD_EXPLAIN',  SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.FRAUD_EXPLAIN_STREAM')
UNION ALL SELECT 'FRAUD_NOTIFY',   SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.FRAUD_NOTIFY_STREAM')
UNION ALL SELECT 'EXTRACTED_DOCS', SYSTEM$STREAM_HAS_DATA('MENDIX_APP.AGENTS.EXTRACTED_DOCS_STREAM')
ORDER BY 1;

-- 10c. The decisive evidence. With nothing new on the stage, TASK_PROCESS_NEW_BL
--      must appear as SKIPPED with
--      "Conditional expression for task evaluated to false."
--      Before this change the same task logged 10 consecutive SUCCEEDED runs
--      that each extracted 0 documents.
SELECT NAME, STATE, SCHEDULED_TIME, LEFT(COALESCE(ERROR_MESSAGE, 'ok'), 80) AS DETAIL
FROM TABLE(MENDIX_APP.INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP())))
WHERE NAME LIKE 'TASK_%' AND STATE <> 'SCHEDULED'
ORDER BY SCHEDULED_TIME DESC;

-- 10d. What each triggered run actually did, and why it did or did not proceed.
SELECT WORKFLOW_NAME, STEP_NAME, INPUT_PARAMS, OUTPUT_RESULT, EXECUTED_AT
FROM MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
WHERE STEP_NAME LIKE 'CONSUME_%'
ORDER BY EXECUTED_AT DESC LIMIT 20;

-- 10e. The compliance task must not have started backfilling history. Expect
--      QUEUE_TOTAL to be small (only genuinely new arrivals) while
--      UNCHECKED_BLS stays in the thousands.
SELECT (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.COMPLIANCE_QUEUE) AS QUEUE_TOTAL,
       (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.COMPLIANCE_QUEUE WHERE CHECKED_AT IS NULL) AS QUEUE_PENDING,
       (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.BILL_OF_LADING
          WHERE COMPLIANCE_CHECK_PASSED IS NULL) AS UNCHECKED_BLS;


-- ============================================================================
-- 11. Compliance checks that never actually checked anything
-- ============================================================================
-- Asking "how many credits would it cost to compliance-check the 10,017
-- historical B/Ls?" turned up something worse than a cost. The answer to the
-- cost question, measured rather than estimated:
--
--   * CHECK_COMPLIANCE contains no Cortex call at all - it is pure SQL, so the
--     Cortex cost is zero. (An earlier note in this project claiming a large
--     Cortex bill for this backfill was simply wrong.)
--   * Row by row: 1,300 ms per B/L measured over 8 real calls, so 10,017 rows is
--     ~3.6 hours on an X-Small warehouse = ~3.6 credits.
--   * Set based, the same three rules in one statement: 314 ms measured for all
--     10,017 rows = 0.000087 credits. About 41,000x cheaper.
--
-- But spending either amount would have bought nothing, because:
--
--   1. CHECK_COMPLIANCE only INSERTed into COMPLIANCE_CHECK_RESULT. Nothing in
--      the entire schema ever set BILL_OF_LADING.COMPLIANCE_CHECK_PASSED, so the
--      "10,017 unchecked" figure was unaffected by running it, and the task that
--      selects `WHERE COMPLIANCE_CHECK_PASSED IS NULL` would pick the same B/L
--      forever. Already visible before the fix: 8 result rows covering only 4
--      distinct B/Ls.
--   2. BATCH_CHECK_COMPLIANCE evaluated no rules whatsoever. It aggregated the
--      existing flag and counted NULL as passed:
--          SUM(CASE WHEN COMPLIANCE_CHECK_PASSED = TRUE
--                     OR COMPLIANCE_CHECK_PASSED IS NULL THEN 1 ELSE 0 END)
--      so it returned {"failed":0,"passed":10017,"total":10017} - a clean bill of
--      health for 10,017 shipments that had never been examined. Running the
--      rules for real shows 1,351 of them (13.5%) fail. For a compliance
--      submission this is the most serious class of defect available: a false
--      assurance, not a missing feature.
--   3. Its P_BATCH_SIZE was inert (`LIMIT` on an aggregate query returning one
--      row), and with the page's 24-hour window no row qualified at all, so the
--      Bulk Scan button returned {} and the UI showed "0 passed, 0 failed".
--   4. The procedure returned `compliant` and `violations`, but the Streamlit
--      page reads `status` and `issues`. Every single-B/L check therefore fell
--      through to the page's else branch and displayed as FAILED regardless of
--      the real result, and the violation list never rendered.
--
-- Section 11 rewrites both procedures, backfills, and asserts the outcome.

-- 11a. COMPLIANCE_CHECK_RESULT carries the same unenforced-primary-key trap as
--      FRAUD_ALERT: CHECK_ID is `autoincrement start 300` while seeded rows
--      already reached 402. One duplicate id existed before this fix, and
--      inserting 10,017 rows would have produced a hundred more. Renumber the
--      duplicate, then confirm the counter sits above the real maximum.
UPDATE MENDIX_APP.AGENTS.COMPLIANCE_CHECK_RESULT t
SET CHECK_ID = r.NEW_ID
FROM (
  SELECT CHECK_ID AS OLD_ID, CHECK_TIMESTAMP,
         (SELECT MAX(CHECK_ID) FROM MENDIX_APP.AGENTS.COMPLIANCE_CHECK_RESULT)
           + ROW_NUMBER() OVER (ORDER BY CHECK_TIMESTAMP) AS NEW_ID
  FROM (
    SELECT c.CHECK_ID, c.CHECK_TIMESTAMP,
           ROW_NUMBER() OVER (PARTITION BY c.CHECK_ID ORDER BY c.CHECK_TIMESTAMP) AS RN
    FROM MENDIX_APP.AGENTS.COMPLIANCE_CHECK_RESULT c
    JOIN (SELECT CHECK_ID FROM MENDIX_APP.AGENTS.COMPLIANCE_CHECK_RESULT
          GROUP BY CHECK_ID HAVING COUNT(*) > 1) d ON d.CHECK_ID = c.CHECK_ID)
  WHERE RN > 1) r
WHERE t.CHECK_ID = r.OLD_ID AND t.CHECK_TIMESTAMP = r.CHECK_TIMESTAMP;

-- Probe the counter, then remove the probe. If COUNTER_NOW is not already above
-- the real maximum, burn it forward as in section 3 before continuing.
INSERT INTO MENDIX_APP.AGENTS.COMPLIANCE_CHECK_RESULT
    (BL_ID, COMPLIANT, VIOLATIONS, RISK_SCORE, RULES_CHECKED)
SELECT -1, FALSE, '["__SEQ_BURN__"]', 0, 0;

SELECT MAX(CASE WHEN BL_ID = -1 THEN CHECK_ID END)  AS COUNTER_NOW,
       MAX(CASE WHEN BL_ID <> -1 THEN CHECK_ID END) AS REAL_MAX
FROM MENDIX_APP.AGENTS.COMPLIANCE_CHECK_RESULT;

DELETE FROM MENDIX_APP.AGENTS.COMPLIANCE_CHECK_RESULT WHERE BL_ID = -1;

-- 11b. Single-B/L check: same three rules, but it now persists the flag and
--      returns the keys the UI actually reads.
CREATE OR REPLACE PROCEDURE MENDIX_APP.AGENTS.CHECK_COMPLIANCE(P_BL_ID NUMBER)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Rule-based compliance scoring for one B/L. Writes COMPLIANCE_CHECK_RESULT and, unlike the previous version, also persists BILL_OF_LADING.COMPLIANCE_CHECK_PASSED so the check is observable afterwards.'
EXECUTE AS OWNER
AS
$$
DECLARE
  v_bl_number  VARCHAR;
  v_restricted BOOLEAN;
  v_dangerous  BOOLEAN;
  v_weight     FLOAT;
  v_issues     ARRAY;
  v_risk       NUMBER;
  v_compliant  BOOLEAN;
BEGIN
  SELECT b.BL_NUMBER,
         COALESCE(r.RESTRICTED, FALSE),
         COALESCE(b.IS_DANGEROUS_GOODS, FALSE),
         b.GROSS_WEIGHT_KGS
    INTO :v_bl_number, :v_restricted, :v_dangerous, :v_weight
  FROM MENDIX_APP.AGENTS.BILL_OF_LADING b
  LEFT JOIN (SELECT HS_CODE, MAX(IS_RESTRICTED OR REQUIRES_PERMIT) AS RESTRICTED
             FROM MENDIX_APP.AGENTS.HS_CODE_REFERENCE GROUP BY HS_CODE) r
         ON r.HS_CODE = b.HS_CODE
  WHERE b.BL_ID = :P_BL_ID;

  -- A SELECT ... INTO over zero rows leaves the variables NULL rather than
  -- raising, so this guard is reachable and is the only signal that the id
  -- does not exist.
  IF (v_bl_number IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('status', 'NOT_FOUND', 'bl_id', :P_BL_ID);
  END IF;

  v_issues := ARRAY_CONSTRUCT_COMPACT(
      IFF(:v_restricted, 'RESTRICTED_HS_CODE', NULL),
      IFF(:v_weight > 50000, 'OVERWEIGHT', NULL),
      IFF(:v_dangerous, 'DANGEROUS_GOODS', NULL));

  v_risk := IFF(:v_restricted, 30, 0)
          + IFF(:v_dangerous, 20, 0)
          + IFF(:v_weight > 50000, 10, 0);

  -- Dangerous goods raise the risk score but are lawful to ship when declared,
  -- so they are reported as an issue without failing the check. A restricted
  -- HS code is the only hard failure.
  v_compliant := NOT :v_restricted;

  INSERT INTO MENDIX_APP.AGENTS.COMPLIANCE_CHECK_RESULT
      (BL_ID, COMPLIANT, VIOLATIONS, RISK_SCORE, RULES_CHECKED)
  SELECT :P_BL_ID, :v_compliant, TO_JSON(:v_issues), :v_risk, 3;

  UPDATE MENDIX_APP.AGENTS.BILL_OF_LADING
     SET COMPLIANCE_CHECK_PASSED = :v_compliant
   WHERE BL_ID = :P_BL_ID;

  RETURN OBJECT_CONSTRUCT(
      'status',     IFF(:v_compliant, 'PASS', 'FAIL'),
      'bl_number',  :v_bl_number,
      'compliant',  :v_compliant,
      'risk_score', :v_risk,
      'issues',     :v_issues,
      'violations', :v_issues,
      'rules_checked', 3);
END;
$$;

-- 11c. Batch check: evaluates the rules set-based over still-unchecked rows.
--      P_HOURS <= 0 or NULL means all time, which is what makes the Bulk Scan
--      button usable on a dataset whose rows are older than a day.
CREATE OR REPLACE PROCEDURE MENDIX_APP.AGENTS.BATCH_CHECK_COMPLIANCE(P_HOURS NUMBER DEFAULT 24, P_BATCH_SIZE NUMBER DEFAULT 50)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Set-based compliance scoring for up to P_BATCH_SIZE still-unchecked B/Ls. P_HOURS <= 0 or NULL means all time. The previous version evaluated nothing: it counted existing flags and treated NULL as passed, so it reported 10,017 passed for shipments that had never been checked.'
EXECUTE AS OWNER
AS
$$
DECLARE
  v_checked   NUMBER DEFAULT 0;
  v_passed    NUMBER DEFAULT 0;
  v_failed    NUMBER DEFAULT 0;
  v_remaining NUMBER DEFAULT 0;
BEGIN
  CREATE OR REPLACE TEMPORARY TABLE TMP_COMPLIANCE_BATCH AS
  SELECT b.BL_ID,
         NOT COALESCE(r.RESTRICTED, FALSE) AS COMPLIANT,
         TO_JSON(ARRAY_CONSTRUCT_COMPACT(
             IFF(COALESCE(r.RESTRICTED, FALSE), 'RESTRICTED_HS_CODE', NULL),
             IFF(b.GROSS_WEIGHT_KGS > 50000, 'OVERWEIGHT', NULL),
             IFF(COALESCE(b.IS_DANGEROUS_GOODS, FALSE), 'DANGEROUS_GOODS', NULL))) AS VIOLATIONS,
         IFF(COALESCE(r.RESTRICTED, FALSE), 30, 0)
           + IFF(COALESCE(b.IS_DANGEROUS_GOODS, FALSE), 20, 0)
           + IFF(b.GROSS_WEIGHT_KGS > 50000, 10, 0) AS RISK_SCORE
  FROM MENDIX_APP.AGENTS.BILL_OF_LADING b
  LEFT JOIN (SELECT HS_CODE, MAX(IS_RESTRICTED OR REQUIRES_PERMIT) AS RESTRICTED
             FROM MENDIX_APP.AGENTS.HS_CODE_REFERENCE GROUP BY HS_CODE) r
         ON r.HS_CODE = b.HS_CODE
  WHERE b.COMPLIANCE_CHECK_PASSED IS NULL
    AND (:P_HOURS IS NULL OR :P_HOURS <= 0
         OR b.CREATED_AT >= DATEADD('hour', -1 * :P_HOURS, CURRENT_TIMESTAMP()))
  ORDER BY b.CREATED_AT DESC NULLS LAST
  LIMIT :P_BATCH_SIZE;

  INSERT INTO MENDIX_APP.AGENTS.COMPLIANCE_CHECK_RESULT
      (BL_ID, COMPLIANT, VIOLATIONS, RISK_SCORE, RULES_CHECKED)
  SELECT BL_ID, COMPLIANT, VIOLATIONS, RISK_SCORE, 3 FROM TMP_COMPLIANCE_BATCH;
  v_checked := SQLROWCOUNT;

  UPDATE MENDIX_APP.AGENTS.BILL_OF_LADING b
     SET COMPLIANCE_CHECK_PASSED = t.COMPLIANT
    FROM TMP_COMPLIANCE_BATCH t
   WHERE b.BL_ID = t.BL_ID;

  SELECT NVL(SUM(IFF(COMPLIANT, 1, 0)), 0), NVL(SUM(IFF(COMPLIANT, 0, 1)), 0)
    INTO :v_passed, :v_failed
  FROM TMP_COMPLIANCE_BATCH;

  v_remaining := (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.BILL_OF_LADING
                  WHERE COMPLIANCE_CHECK_PASSED IS NULL);

  RETURN OBJECT_CONSTRUCT('passed', :v_passed, 'failed', :v_failed,
                          'total', :v_checked, 'not_checked_remaining', :v_remaining);
END;
$$;

-- 11d. Backfill everything. Measured at well under a second for 10,017 rows.
CALL MENDIX_APP.AGENTS.BATCH_CHECK_COMPLIANCE(0, 20000);

-- 11e. CREATE OR REPLACE PROCEDURE dropped the grants again.
GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.CHECK_COMPLIANCE(NUMBER)
  TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.BATCH_CHECK_COMPLIANCE(NUMBER,NUMBER)
  TO ROLE HACKATHON_JUDGE_ROLE;

-- 11f. Assertions.
--      Expect STILL_UNCHECKED = 0, FLAG_PASSED = 8666, FLAG_FAILED = 1351,
--      and DUP_CHECK_IDS = 0.
SELECT (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.BILL_OF_LADING
          WHERE COMPLIANCE_CHECK_PASSED IS NULL)  AS STILL_UNCHECKED,
       (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.BILL_OF_LADING
          WHERE COMPLIANCE_CHECK_PASSED = TRUE)   AS FLAG_PASSED,
       (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.BILL_OF_LADING
          WHERE COMPLIANCE_CHECK_PASSED = FALSE)  AS FLAG_FAILED,
       (SELECT COUNT(*) FROM (SELECT CHECK_ID FROM MENDIX_APP.AGENTS.COMPLIANCE_CHECK_RESULT
          GROUP BY CHECK_ID HAVING COUNT(*) > 1)) AS DUP_CHECK_IDS;

-- The stored flag must agree with a fresh evaluation of the rules on every row.
-- Expect 0.
SELECT COUNT(*) AS FLAG_DISAGREES_WITH_RULES
FROM MENDIX_APP.AGENTS.BILL_OF_LADING b
LEFT JOIN (SELECT HS_CODE, MAX(IS_RESTRICTED OR REQUIRES_PERMIT) AS RESTRICTED
           FROM MENDIX_APP.AGENTS.HS_CODE_REFERENCE GROUP BY HS_CODE) r
       ON r.HS_CODE = b.HS_CODE
WHERE b.COMPLIANCE_CHECK_PASSED IS DISTINCT FROM (NOT COALESCE(r.RESTRICTED, FALSE));

-- The UI contract: 'status' must be PASS or FAIL, never absent, and a missing id
-- must say NOT_FOUND rather than silently reading as compliant.
CALL MENDIX_APP.AGENTS.CHECK_COMPLIANCE(999999);


-- ============================================================================
-- Known residual issues, recorded rather than hidden
-- ============================================================================
-- * BL_CHANGE_STREAM now has a consumer again (section 9 gave TASK_FRAUD_SCAN a
--   body that reads it), so the earlier concern about it going stale is resolved.
-- * The 10,017 pre-existing rows with COMPLIANCE_CHECK_PASSED IS NULL are not
--   drained by the scheduled task ON PURPOSE - having a 30-minute task grind
--   through them one at a time, driven by its own writes rather than by new data,
--   would run for roughly 209 days. Section 11 backfills them in a single
--   set-based pass instead, which is what a backfill should be.
-- * SYSTEM$STREAM_HAS_DATA can report TRUE while the stream contains zero rows.
--   Each task therefore still starts a warehouse for that one cheap run (a COUNT
--   plus a single-row INSERT) before disarming itself. The guard keeps it cheap;
--   it does not make it free.
-- * FRAUD_ALERT contains one alert (id 508) whose BL_ID 14100 does not exist in
--   BILL_OF_LADING. It is STATUS = 'ESCALATED', so the pipeline's
--   `WHERE STATUS = 'OPEN'` filter never selects it, and section 4 makes the
--   shipper lookup NULL-safe regardless. It was left as-is rather than pointing
--   it at an arbitrary real B/L, which would have invented a business fact.
-- * ALERT_TYPE holds both 'DUPLICATE_BL' (4 rows) and 'DUPLICATE_BL_NUMBER'
--   (4 rows) for the same condition - a pre-existing enum split, unrelated to
--   these fixes, not consolidated here to keep this change reviewable.
-- ============================================================================
