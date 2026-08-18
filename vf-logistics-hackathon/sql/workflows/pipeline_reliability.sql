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
-- Known residual issues, recorded rather than hidden
-- ============================================================================
-- * BL_CHANGE_STREAM now has no consumer. It is harmless but pointless, and
--   will eventually go stale past its retention window. Either drop it or give
--   it a consumer; it is left in place because other documentation refers to it.
-- * FRAUD_ALERT contains one alert (id 508) whose BL_ID 14100 does not exist in
--   BILL_OF_LADING. It is STATUS = 'ESCALATED', so the pipeline's
--   `WHERE STATUS = 'OPEN'` filter never selects it, and section 4 makes the
--   shipper lookup NULL-safe regardless. It was left as-is rather than pointing
--   it at an arbitrary real B/L, which would have invented a business fact.
-- * ALERT_TYPE holds both 'DUPLICATE_BL' (4 rows) and 'DUPLICATE_BL_NUMBER'
--   (4 rows) for the same condition - a pre-existing enum split, unrelated to
--   these fixes, not consolidated here to keep this change reviewable.
-- ============================================================================
