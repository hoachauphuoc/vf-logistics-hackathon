
-- ---------------------------------------------------------------------------
-- 13d - the gate still blinded HIGH detection; now it does not
--
-- 13c removed the permanent latch but left a second problem: the gate wrapped
-- all five detection rules in its ELSE branch, so whenever it tripped it
-- suppressed every severity. A 7-day window can itself fill, and when it does a
-- backlog of MEDIUM alerts would still hide a HIGH-severity fraud. Backpressure
-- is meant to defer low-value work, not to stop looking for the serious cases.
--
-- The gate is now advisory rather than structural. It sets v_throttled and each
-- rule decides for itself whether it may still fire:
--
--   * SUSPICIOUS_PARTY is unconditionally HIGH  -> always runs, no guard added.
--   * COST_PER_KG_ANOMALY, HIGH_VALUE_ANOMALY and DOCUMENT_QUALITY choose their
--     severity with a CASE expression -> when saturated they are narrowed to
--     exactly the rows that CASE would have marked HIGH. Each guard is copied
--     from the CASE in its own INSERT so the two cannot drift apart.
--   * WEIGHT_ANOMALY is unconditionally MEDIUM -> suppressed whole.
--
-- The IF is kept as a deliberately-always-false branch. That is not laziness:
-- rewriting the IF/ELSE around five INSERT statements means matching multi-line
-- whitespace inside GET_DDL output, and the first attempt at that failed
-- (the anchor matched 0 times) because the result grid renders newlines as
-- spaces. Every anchor below stays inside a single line, which is verifiable.
--
-- The return value gained "medium_suppressed" because throttled=true no longer
-- implies nothing was detected. It is an additive key; existing readers of
-- throttled and new_alerts are unaffected.
-- ---------------------------------------------------------------------------

EXECUTE IMMEDIATE $$
DECLARE
    ddl VARCHAR;  q VARCHAR;  n NUMBER;  i NUMBER;
    a ARRAY;  r ARRAY;  lbl ARRAY;
BEGIN
    USE DATABASE MENDIX_APP;
    USE SCHEMA AGENTS;
    q := CHR(39);

    ddl := (SELECT GET_DDL('PROCEDURE', 'MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT(NUMBER)'));
    IF (ddl LIKE '%medium_suppressed%') THEN
        RETURN 'ALREADY PATCHED - no change';
    END IF;

    lbl := ARRAY_CONSTRUCT('gate', 'rule1-cost-per-kg', 'rule2-high-value',
                           'rule3-weight', 'rule5-doc-quality', 'return-json');

    a := ARRAY_CONSTRUCT(
        'IF (:v_queue_open >= :P_QUEUE_LIMIT) THEN v_throttled := TRUE;',
        'AND TOTAL_CHARGES / GROSS_WEIGHT_KGS > 5 * :v_median_cpk',
        'WHERE TOTAL_CHARGES > :v_p99_charges',
        'WHERE GROSS_WEIGHT_KGS > :v_p99_weight',
        'WHERE AI_CONFIDENCE_SCORE IS NOT NULL AND AI_CONFIDENCE_SCORE < 85',
        REPLACE('|| ~~,"new_alerts":~~', '~', :q)
    );

    r := ARRAY_CONSTRUCT(
        'v_throttled := (:v_queue_open >= :P_QUEUE_LIMIT); /* This gate used to wrap every detection rule in its ELSE branch, so a saturated queue skipped all of them and a backlog of MEDIUM alerts could hide a HIGH-severity fraud. It now only records that the queue is saturated; each rule below carries its own severity guard. The IF is kept as a deliberately-always-false branch so the existing ELSE / END IF structure stays valid without restructuring five INSERT statements. */ IF (FALSE) THEN v_throttled := :v_throttled;',
        'AND TOTAL_CHARGES / GROSS_WEIGHT_KGS > 5 * :v_median_cpk AND (:v_throttled = FALSE OR TOTAL_CHARGES / GROSS_WEIGHT_KGS > 10 * :v_median_cpk)',
        'WHERE TOTAL_CHARGES > :v_p99_charges AND (:v_throttled = FALSE OR (GROSS_WEIGHT_KGS > 0 AND TOTAL_CHARGES / GROSS_WEIGHT_KGS > 10 * :v_median_cpk))',
        'WHERE GROSS_WEIGHT_KGS > :v_p99_weight AND :v_throttled = FALSE',
        'WHERE AI_CONFIDENCE_SCORE IS NOT NULL AND AI_CONFIDENCE_SCORE < 85 AND (:v_throttled = FALSE OR AI_CONFIDENCE_SCORE <= 50)',
        REPLACE('|| ~~,"medium_suppressed":~~ || IFF(:v_throttled, ~~true~~, ~~false~~) || ~~,"new_alerts":~~', '~', :q)
    );

    FOR i IN 0 TO 5 DO
        n := (LENGTH(:ddl) - LENGTH(REPLACE(:ddl, GET(:a, :i)::VARCHAR, ''))) / LENGTH(GET(:a, :i)::VARCHAR);
        IF (:n <> 1) THEN
            RETURN 'ABORT - anchor ' || GET(:lbl, :i)::VARCHAR || ' matched ' || :n || ' times, expected exactly 1';
        END IF;
    END FOR;

    FOR i IN 0 TO 5 DO
        ddl := REPLACE(:ddl, GET(:a, :i)::VARCHAR, GET(:r, :i)::VARCHAR);
    END FOR;

    EXECUTE IMMEDIATE :ddl;
    GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT(NUMBER) TO ROLE HACKATHON_JUDGE_ROLE;
    GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT(NUMBER) TO ROLE VF_APP_ROLE;
    RETURN 'PATCHED - 6 edits applied, HIGH-severity detection now bypasses the gate';
END;
$$;

-- Assertion on the shape of the result.
SELECT REGEXP_COUNT(PROCEDURE_DEFINITION, ':v_throttled = FALSE') AS SEVERITY_GUARDS,  -- expect 4
       PROCEDURE_DEFINITION LIKE '%medium_suppressed%' AS REPORTS_SUPPRESSION           -- expect TRUE
FROM MENDIX_APP.INFORMATION_SCHEMA.PROCEDURES
WHERE PROCEDURE_SCHEMA = 'AGENTS' AND PROCEDURE_NAME = 'WORKFLOW_DETECT_AND_ACT';

-- ---------------------------------------------------------------------------
-- 13e - proving 13d, because the obvious test proves nothing
--
-- Running WORKFLOW_DETECT_AND_ACT(1) to force saturation returned
--   {"throttled":true,"medium_suppressed":true,"new_alerts":0,...}
-- which looks like a pass and is not one. Counting the HIGH-eligible candidates
-- for all four HIGH-capable rules showed 0 for every rule, so zero new alerts
-- was the correct answer for a reason unrelated to the fix -- exactly the shape
-- of result that would also appear if the guards suppressed everything.
--
-- The behaviour therefore has to be tested against injected data: one row that
-- can only produce a HIGH alert and one that can only produce a MEDIUM alert.
-- ---------------------------------------------------------------------------

INSERT INTO MENDIX_APP.AGENTS.BILL_OF_LADING
  (BL_ID, BL_NUMBER, SHIPPER_NAME, CONSIGNEE_NAME, GROSS_WEIGHT_KGS, TOTAL_CHARGES, STATUS)
SELECT 999001, 'TEST-HIGH-BYPASS', 'SUSPICIOUS TRADING LLC', 'ACME IMPORTS', 5000, 5000, 'Active'
UNION ALL
-- Twice the p99 weight, with ordinary charges, so it trips WEIGHT_ANOMALY
-- (always MEDIUM) and nothing else. The charges are deliberately unremarkable
-- so it cannot also trip a cost-per-kg or high-value rule.
SELECT 999002, 'TEST-MEDIUM-ONLY', 'NORMAL SHIPPER CO', 'ACME IMPORTS',
       (SELECT PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY GROSS_WEIGHT_KGS) * 2
        FROM MENDIX_APP.AGENTS.BILL_OF_LADING
        WHERE TOTAL_CHARGES IS NOT NULL AND GROSS_WEIGHT_KGS > 0
          AND STATUS NOT IN ('Pending_Review','DRAFT')), 5000, 'Active';

-- Saturated. Observed: {"throttled":true,"medium_suppressed":true,"new_alerts":1,
--                       "high_severity_open":5,"shipments_flagged":1}
CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT(1);

-- Observed, which is the whole point of the change:
--   999001 TEST-HIGH-BYPASS -> HIGH / SUSPICIOUS_PARTY
--   999002 TEST-MEDIUM-ONLY -> NO ALERT
-- Before 13d both rows would have been missed.
SELECT b.BL_ID, b.BL_NUMBER,
       IFF(a.ALERT_ID IS NULL, 'NO ALERT', a.SEVERITY || ' / ' || a.ALERT_TYPE) AS OUTCOME
FROM MENDIX_APP.AGENTS.BILL_OF_LADING b
LEFT JOIN MENDIX_APP.AGENTS.FRAUD_ALERT a ON a.BL_ID = b.BL_ID
WHERE b.BL_ID IN (999001, 999002) ORDER BY b.BL_ID;

-- Unsaturated, to show the MEDIUM row is deferred rather than discarded.
-- Observed: {"throttled":false,"medium_suppressed":false,"new_alerts":9,...}
-- and 999002 -> MEDIUM / WEIGHT_ANOMALY.
CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT();

-- Rollback. ALERT_ID 1415 was the maximum at the verified demo baseline, so
-- everything above it is test residue. The two synthetic B/Ls go with it.
--
-- The workflow's UPDATE sets STATUS='Pending_Review' on B/Ls carrying an open
-- HIGH alert, so that was checked rather than assumed: the only two other rows
-- in that state (13202, 13203) have no alerts at all and therefore could not
-- have been touched by these runs.
DELETE FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID > 1415;
DELETE FROM MENDIX_APP.AGENTS.BILL_OF_LADING WHERE BL_ID IN (999001, 999002);
DELETE FROM MENDIX_APP.AGENTS.NOTIFICATION_LOG
 WHERE NOTIFICATION_TYPE = 'WORKFLOW_RUN' AND SENT_AT >= DATEADD(hour, -3, CURRENT_TIMESTAMP());

-- Baseline confirmed after rollback: 496 alerts, 10,017 B/Ls, 219 notifications,
-- 423 AI call log rows, 15 extracted documents, empty compliance queue.
SELECT (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.FRAUD_ALERT)            AS ALERTS,
       (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.BILL_OF_LADING)         AS BILLS,
       (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.NOTIFICATION_LOG)       AS NOTIF,
       (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.AI_CALL_LOG)            AS AI_LOG,
       (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED) AS DOCS,
       (SELECT COUNT(*) FROM MENDIX_APP.AGENTS.COMPLIANCE_QUEUE)       AS QUEUE;
