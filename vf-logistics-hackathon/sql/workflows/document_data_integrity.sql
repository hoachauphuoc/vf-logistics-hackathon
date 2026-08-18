-- ============================================================================
-- document_data_integrity.sql
-- ============================================================================
-- Fixes three classes of data-integrity defect found in BILL_OF_LADING_EXTRACTED
-- on 2026-08-18, and removes the design flaw that allowed the first one to exist.
--
-- WHAT WAS WRONG
--
-- 1. Self-contradicting rows. PROCESS_BL_DOCUMENTS computed CONFIDENCE_SCORE
--    deterministically from four field checks, but produced ALERT from a SECOND,
--    INDEPENDENT SNOWFLAKE.CORTEX.COMPLETE call that was asked to apply the same
--    four rules in prose. Two separate judges of identical facts will eventually
--    disagree, and they did: DOC 402 carried
--        ALERT = 'ContainerNumber; VesselName; GrossWeightKg'
--    while also carrying CONFIDENCE_SCORE = 100 and STATUS = 'Synced_To_SAP'.
--    A document whose container number is the placeholder 'XXXX0000000' was
--    presented to reviewers as perfectly extracted and already posted to SAP.
--
--    Fix: the rules become ONE deterministic SQL function, BL_DOC_ALERT. The
--    confidence score is derived FROM that same function, so the score and the
--    alert are mathematically incapable of disagreeing. The LLM is still used,
--    but only for ALERT_RESPONSE -- the human-readable narrative -- which is
--    presentation, not a control decision. Never let a generative call decide
--    whether a document passes validation.
--
-- 2. Status not backed by data. Five rows claimed STATUS = 'Synced_To_SAP' but
--    joining SAP_FI_DOCUMENT on BL_ID returned zero SAP_DOCUMENT_NUMBER for all
--    five, and every corresponding BILL_OF_LADING row was still 'Pending_Review'.
--    The status was decorative text.
--
--    Fix: STATUS is recomputed from observable state -- 'Synced_To_SAP' requires
--    a real SAP_FI_DOCUMENT row to exist. Documents that can be posted honestly
--    (clean, and carrying a non-NULL TOTAL_CHARGES) are posted for real through
--    SAP_POST_FI_DOCUMENT rather than being relabelled. No amounts are invented.
--
-- 3. Unit error. DOC 101/201/301 stored GROSS_WEIGHT_KG = 24.5 where comparable
--    rows store 24500 -- tonnes written into a kilogram column, wrong by 1000x.
--    The old weight rule only rejected <= 0, so 24.5 kg for a full container
--    passed validation.
--
--    Fix: the three rows are converted to kilograms, and the weight rule now
--    requires >= 100 kg so a future tonnes/kg mix-up is flagged instead of
--    silently accepted.
--
-- ALSO CLOSED: the carrier-consistency gap. DOC 1 held an MSC bill of lading
-- number (MSCU2026012) against a Maersk container (MSKU7891234) and the Maersk
-- vessel MAERSK SENTOSA, yet was reported as 'No anomalies detected'. Prefix
-- ownership is now cross-checked.
--
-- NOT A DEFECT -- LEAVE ALONE: DOC 3 ('MSK@#$%789'), DOC 4 ('XXXX0000000',
-- weight 0) and DOC 8 (weight 0) are deliberate bad-data fixtures whose files
-- are named *_ERROR.pdf. They are correctly scored low and held in
-- Pending_Review. They are the anomaly-detection demo working as intended.
--
-- Safe to re-run: every statement is CREATE OR REPLACE or an idempotent UPDATE.
-- ============================================================================

USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;


-- ----------------------------------------------------------------------------
-- 1. Carrier identification helpers
-- ----------------------------------------------------------------------------
-- Maps a bill-of-lading prefix or an ISO 6346 container owner code to a carrier.
-- Both share the same 4-character namespace, which is what makes the
-- cross-check in BL_DOC_ALERT possible.
CREATE OR REPLACE FUNCTION CARRIER_FROM_CODE(P_CODE VARCHAR)
RETURNS VARCHAR
COMMENT = 'Carrier for a BL prefix or ISO 6346 container owner code; NULL when unknown.'
AS
$$
    CASE UPPER(LEFT(COALESCE(P_CODE, ''), 4))
        WHEN 'MAEU' THEN 'MAERSK'
        WHEN 'MSKU' THEN 'MAERSK'
        WHEN 'MRKU' THEN 'MAERSK'
        WHEN 'MSCU' THEN 'MSC'
        WHEN 'MEDU' THEN 'MSC'
        WHEN 'COSU' THEN 'COSCO'
        WHEN 'CCLU' THEN 'COSCO'
        WHEN 'CBHU' THEN 'COSCO'
        WHEN 'HLCU' THEN 'HAPAG_LLOYD'
        WHEN 'HLXU' THEN 'HAPAG_LLOYD'
        WHEN 'ONEY' THEN 'ONE'
        WHEN 'ONEU' THEN 'ONE'
        WHEN 'EGLV' THEN 'EVERGREEN'
        WHEN 'EISU' THEN 'EVERGREEN'
        WHEN 'CMAU' THEN 'CMA_CGM'
        WHEN 'OOLU' THEN 'OOCL'
        WHEN 'APLU' THEN 'APL'
        WHEN 'YMLU' THEN 'YANG_MING'
        ELSE NULL
    END
$$;


-- Vessel names are free text, so only an unambiguous carrier keyword counts.
-- Anything unrecognised returns NULL, which suppresses the cross-check rather
-- than producing a false anomaly: 'BERLIN EXPRESS' is a genuine Hapag-Lloyd
-- vessel whose name contains no carrier token, and it must not be flagged.
CREATE OR REPLACE FUNCTION CARRIER_FROM_VESSEL(P_VESSEL VARCHAR)
RETURNS VARCHAR
COMMENT = 'Carrier inferred from a vessel name keyword; NULL when not inferable.'
AS
$$
    CASE
        WHEN UPPER(COALESCE(P_VESSEL, '')) LIKE '%MAERSK%'    THEN 'MAERSK'
        WHEN UPPER(COALESCE(P_VESSEL, '')) LIKE '%COSCO%'     THEN 'COSCO'
        WHEN UPPER(COALESCE(P_VESSEL, '')) LIKE '%EVERGREEN%' THEN 'EVERGREEN'
        WHEN UPPER(COALESCE(P_VESSEL, '')) LIKE '%HAPAG%'     THEN 'HAPAG_LLOYD'
        WHEN UPPER(COALESCE(P_VESSEL, '')) LIKE '%CMA %'      THEN 'CMA_CGM'
        WHEN UPPER(COALESCE(P_VESSEL, '')) LIKE '%OOCL%'      THEN 'OOCL'
        WHEN UPPER(COALESCE(P_VESSEL, '')) LIKE '%YANG MING%' THEN 'YANG_MING'
        -- 'MSC' and 'ONE' are checked last and with word boundaries because they
        -- are short enough to appear inside unrelated words.
        WHEN UPPER(COALESCE(P_VESSEL, '')) RLIKE '(^|.* )MSC( .*|$)' THEN 'MSC'
        WHEN UPPER(COALESCE(P_VESSEL, '')) RLIKE '(^|.* )ONE( .*|$)' THEN 'ONE'
        ELSE NULL
    END
$$;


-- ----------------------------------------------------------------------------
-- 2. THE single source of truth for document validation
-- ----------------------------------------------------------------------------
-- Returns a '; '-separated list of failed rule names, or NULL when the document
-- is clean. Both the alert text and the confidence score are derived from this
-- one function, which is the whole point: the previous design computed them
-- separately and they drifted apart.
CREATE OR REPLACE FUNCTION BL_DOC_ALERT(
    P_BL        VARCHAR,
    P_CONTAINER VARCHAR,
    P_VESSEL    VARCHAR,
    P_WEIGHT    FLOAT,
    P_DATE      DATE
)
RETURNS VARCHAR
COMMENT = 'Deterministic validation of an extracted BL. NULL means no anomalies.'
AS
$$
    NULLIF(
        RTRIM(
            -- Rule 1: a bill of lading must carry a BL number.
            IFF(P_BL IS NULL OR LENGTH(TRIM(P_BL)) = 0,
                'BlNumber; ', '')
            -- Rule 2: ISO 6346 container numbers are 11 alphanumeric characters.
            -- 'XXXX...' is the extractor's placeholder for "could not read".
            || IFF(P_CONTAINER IS NULL
                   OR LENGTH(TRIM(P_CONTAINER)) < 8
                   OR UPPER(P_CONTAINER) RLIKE '.*[^A-Z0-9].*'
                   OR UPPER(P_CONTAINER) LIKE 'XXXX%',
                'ContainerNumber; ', '')
            -- Rule 3: vessel name present and not a stub.
            || IFF(P_VESSEL IS NULL OR LENGTH(TRIM(P_VESSEL)) <= 2,
                'VesselName; ', '')
            -- Rule 4: plausible container gross weight in KILOGRAMS. The >= 100
            -- floor is what catches a tonnes value written into a kg column.
            || IFF(P_WEIGHT IS NULL OR P_WEIGHT < 100 OR P_WEIGHT >= 100000,
                'GrossWeightKg; ', '')
            -- Rule 5: issue date present and not implausibly historic.
            || IFF(P_DATE IS NULL OR P_DATE < '2025-01-01'::DATE,
                'DateOfIssue; ', '')
            -- Rule 6: the BL prefix, the container owner code and the vessel
            -- must belong to the same carrier. Each half is only compared when
            -- both sides resolve, so unknown codes never fabricate an anomaly.
            || IFF((CARRIER_FROM_CODE(P_BL) IS NOT NULL
                    AND CARRIER_FROM_CODE(P_CONTAINER) IS NOT NULL
                    AND CARRIER_FROM_CODE(P_BL) <> CARRIER_FROM_CODE(P_CONTAINER))
                   OR (CARRIER_FROM_CODE(P_BL) IS NOT NULL
                    AND CARRIER_FROM_VESSEL(P_VESSEL) IS NOT NULL
                    AND CARRIER_FROM_CODE(P_BL) <> CARRIER_FROM_VESSEL(P_VESSEL)),
                'CarrierMismatch; ', ''),
            '; '
        ),
        ''
    )
$$;


-- Confidence is a pure function of the alert: 6 rules, each worth ~16.7 points.
-- A clean document scores 100; every failed rule costs one sixth. Because this
-- reads BL_DOC_ALERT rather than re-implementing the checks, a score of 100 can
-- no longer coexist with a non-empty alert.
CREATE OR REPLACE FUNCTION BL_DOC_CONFIDENCE(
    P_BL        VARCHAR,
    P_CONTAINER VARCHAR,
    P_VESSEL    VARCHAR,
    P_WEIGHT    FLOAT,
    P_DATE      DATE
)
RETURNS FLOAT
COMMENT = 'Extraction confidence 0-100 derived from BL_DOC_ALERT failure count.'
AS
$$
    ROUND(
        100.0 * (
            6 - COALESCE(
                    ARRAY_SIZE(
                        SPLIT(BL_DOC_ALERT(P_BL, P_CONTAINER, P_VESSEL, P_WEIGHT, P_DATE), '; ')
                    ),
                    0
                )
        ) / 6.0,
        0
    )
$$;


-- ----------------------------------------------------------------------------
-- 3. Defect 3 -- correct the tonnes/kilograms unit error
-- ----------------------------------------------------------------------------
-- Bounded deliberately: only values that are implausible as kilograms for a
-- loaded container yet plausible as tonnes are converted. A blanket
-- "multiply small weights by 1000" would corrupt genuine light shipments.
UPDATE BILL_OF_LADING_EXTRACTED
   SET GROSS_WEIGHT_KG = GROSS_WEIGHT_KG * 1000,
       REVIEW_NOTES    = COALESCE(REVIEW_NOTES || ' | ', '')
                      || 'Unit correction 2026-08-18: value was recorded in tonnes, converted to kg.'
 WHERE GROSS_WEIGHT_KG > 0
   AND GROSS_WEIGHT_KG < 100;

-- NET_WEIGHT_KG is corrected on the same rows only, to keep the two consistent.
UPDATE BILL_OF_LADING_EXTRACTED
   SET NET_WEIGHT_KG = NET_WEIGHT_KG * 1000
 WHERE NET_WEIGHT_KG > 0
   AND NET_WEIGHT_KG < 100
   AND REVIEW_NOTES ILIKE '%Unit correction 2026-08-18%';


-- ----------------------------------------------------------------------------
-- 4. Defect 2 -- post SAP documents for real instead of relabelling
-- ----------------------------------------------------------------------------
-- Only documents that are clean under BL_DOC_ALERT and whose bill of lading
-- carries a real TOTAL_CHARGES are posted. Posting a financial document with a
-- NULL amount would trade one false status for another, so those are left to be
-- posted through the UI or the pipeline once charges exist.
DECLARE
    C_ELIGIBLE CURSOR FOR
        SELECT e.BL_ID
          FROM BILL_OF_LADING_EXTRACTED e
          JOIN BILL_OF_LADING b       ON b.BL_ID = e.BL_ID
         WHERE e.BL_ID IS NOT NULL
           AND b.TOTAL_CHARGES IS NOT NULL
           AND b.TOTAL_CHARGES > 0
           AND BL_DOC_ALERT(e.BL_NUMBER, e.CONTAINER_NUMBER, e.VESSEL_NAME,
                            e.GROSS_WEIGHT_KG, e.DATE_OF_ISSUE) IS NULL
           AND NOT EXISTS (SELECT 1 FROM SAP_FI_DOCUMENT s WHERE s.BL_ID = e.BL_ID);
    V_POSTED NUMBER := 0;
BEGIN
    FOR r IN C_ELIGIBLE DO
        CALL SAP_POST_FI_DOCUMENT(r.BL_ID);
        V_POSTED := V_POSTED + 1;
    END FOR;
    RETURN 'SAP documents posted: ' || V_POSTED;
END;


-- ----------------------------------------------------------------------------
-- 5. Defects 1 and 2 -- recompute ALERT, CONFIDENCE_SCORE and STATUS
-- ----------------------------------------------------------------------------
-- STATUS is now a statement about observable reality:
--   Pending_Review  -- at least one rule failed
--   Synced_To_SAP   -- clean AND a SAP_FI_DOCUMENT actually exists
--   AI_Processed    -- clean, but nothing has been posted to SAP yet
UPDATE BILL_OF_LADING_EXTRACTED e
   SET ALERT = COALESCE(
                   BL_DOC_ALERT(e.BL_NUMBER, e.CONTAINER_NUMBER, e.VESSEL_NAME,
                                e.GROSS_WEIGHT_KG, e.DATE_OF_ISSUE),
                   'No anomalies detected'
               ),
       CONFIDENCE_SCORE = BL_DOC_CONFIDENCE(e.BL_NUMBER, e.CONTAINER_NUMBER,
                                            e.VESSEL_NAME, e.GROSS_WEIGHT_KG,
                                            e.DATE_OF_ISSUE),
       STATUS = CASE
                    WHEN BL_DOC_ALERT(e.BL_NUMBER, e.CONTAINER_NUMBER, e.VESSEL_NAME,
                                      e.GROSS_WEIGHT_KG, e.DATE_OF_ISSUE) IS NOT NULL
                        THEN 'Pending_Review'
                    WHEN EXISTS (SELECT 1 FROM SAP_FI_DOCUMENT s WHERE s.BL_ID = e.BL_ID)
                        THEN 'Synced_To_SAP'
                    ELSE 'AI_Processed'
                END;


-- ----------------------------------------------------------------------------
-- 6. Verification -- every row must be internally consistent
-- ----------------------------------------------------------------------------
-- Each query below must return ZERO rows. They encode the three defects as
-- assertions, so re-running this file also proves the defects have not returned.

-- 6a. No document may carry an alert and a perfect score at the same time.
--     This is the DOC 402 defect.
SELECT 'FAIL 6a: alert with perfect confidence' AS CHECK_NAME, DOC_ID, ALERT, CONFIDENCE_SCORE
  FROM BILL_OF_LADING_EXTRACTED
 WHERE ALERT <> 'No anomalies detected'
   AND CONFIDENCE_SCORE >= 100;

-- 6b. No alerted document may be presented as processed or posted.
SELECT 'FAIL 6b: alerted document not held for review' AS CHECK_NAME, DOC_ID, ALERT, STATUS
  FROM BILL_OF_LADING_EXTRACTED
 WHERE ALERT <> 'No anomalies detected'
   AND STATUS <> 'Pending_Review';

-- 6c. Synced_To_SAP must be backed by an actual SAP document.
SELECT 'FAIL 6c: Synced_To_SAP without SAP document' AS CHECK_NAME, e.DOC_ID, e.BL_ID
  FROM BILL_OF_LADING_EXTRACTED e
 WHERE e.STATUS = 'Synced_To_SAP'
   AND NOT EXISTS (SELECT 1 FROM SAP_FI_DOCUMENT s WHERE s.BL_ID = e.BL_ID);

-- 6d. No weight may still be sitting in tonnes.
SELECT 'FAIL 6d: weight implausible as kg' AS CHECK_NAME, DOC_ID, GROSS_WEIGHT_KG
  FROM BILL_OF_LADING_EXTRACTED
 WHERE GROSS_WEIGHT_KG > 0 AND GROSS_WEIGHT_KG < 100;

-- 6e. The stored score must equal what the function computes -- proves score and
--     alert cannot have drifted apart.
SELECT 'FAIL 6e: stored score disagrees with rules' AS CHECK_NAME, DOC_ID,
       CONFIDENCE_SCORE AS STORED,
       BL_DOC_CONFIDENCE(BL_NUMBER, CONTAINER_NUMBER, VESSEL_NAME,
                         GROSS_WEIGHT_KG, DATE_OF_ISSUE) AS EXPECTED
  FROM BILL_OF_LADING_EXTRACTED
 WHERE CONFIDENCE_SCORE <> BL_DOC_CONFIDENCE(BL_NUMBER, CONTAINER_NUMBER, VESSEL_NAME,
                                             GROSS_WEIGHT_KG, DATE_OF_ISSUE);

-- 6f. The known carrier mismatch must now be caught (expects DOC 1 and DOC 402).
SELECT DOC_ID, BL_NUMBER, CONTAINER_NUMBER, VESSEL_NAME, ALERT
  FROM BILL_OF_LADING_EXTRACTED
 WHERE ALERT ILIKE '%CarrierMismatch%'
 ORDER BY DOC_ID;


-- ----------------------------------------------------------------------------
-- 7. Stop the defect recurring -- patch PROCESS_BL_DOCUMENTS
-- ----------------------------------------------------------------------------
-- Sections 3-5 repaired the existing rows. This section repairs the code that
-- produced them, otherwise the next PDF processed would reintroduce the same
-- divergence.
--
-- The procedure is patched by rewriting its OWN DDL through REPLACE rather than
-- being retyped. The body is ~7.5 KB and contains a long Cortex prompt literal
-- with nested quote escaping; retyping it risks silently corrupting a fragment
-- that has nothing to do with this fix. Transforming GET_DDL output guarantees
-- every byte not named below stays identical.
--
-- Four changes:
--   a) confidence  -- was :key_ok * 25.0 (a second, parallel implementation of
--                     the rules) and is now read from BL_DOC_CONFIDENCE.
--   b) doc_status  -- threshold raised from >= 85 to >= 100, so a document with
--                     ANY failed rule can never be labelled AI_Processed. Under
--                     the old 6-rule scale a single failure scores 83, which
--                     would still have passed an 85 threshold.
--   c) v_alert     -- was taken from the LLM's "Alert" field and is now taken
--                     from BL_DOC_ALERT. This is the actual fix: validation is
--                     no longer a generative decision.
--   d) the prompt  -- the LLM is now told the authoritative verdict and asked
--                     only to narrate it into ALERT_RESPONSE. It is explicitly
--                     instructed not to re-decide. Keeping the natural-language
--                     explanation is worthwhile; letting it vote is not.
--
-- Evidence this mattered: DOC 402's LLM-produced alert claimed VesselName and
-- GrossWeightKg were invalid when both were fine ('MAERSK SENTOSA', 24500 kg),
-- and simultaneously missed that an Evergreen BL was on a Maersk vessel. Two of
-- three flags were hallucinated and the real defect went unreported.
CREATE OR REPLACE TABLE TMP_PROC_PATCH AS
SELECT REPLACE(
         REPLACE(
           REPLACE(
             REPLACE(
               GET_DDL('PROCEDURE','MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS()'),
               $$:key_ok * 25.0$$,
               $$(SELECT MENDIX_APP.AGENTS.BL_DOC_CONFIDENCE(:v_bl, :v_container, :v_vessel, :v_weight, :v_date))$$
             ),
             $$IFF(:confidence >= 85$$,
             $$IFF(:confidence >= 100$$
           ),
           $$LET v_alert VARCHAR := :alert_parsed:"Alert"::VARCHAR;$$,
           $$LET v_alert VARCHAR := (SELECT COALESCE(MENDIX_APP.AGENTS.BL_DOC_ALERT(:v_bl, :v_container, :v_vessel, :v_weight, :v_date), ''No anomalies detected''));$$
         ),
         $$Evaluate this Bill of Lading record against EXACTLY these 4 rules.$$,
         $$You are given the authoritative, deterministic validation result for a Bill of Lading. Write ONLY a short human-readable explanation of that result for a reviewer. Do NOT override or re-decide the verdict. Authoritative failed rules: '' || COALESCE((SELECT MENDIX_APP.AGENTS.BL_DOC_ALERT(:v_bl, :v_container, :v_vessel, :v_weight, :v_date)), ''none'') || ''. For reference, the rules are:$$
       ) AS DDL;

-- A scripting block is required because EXECUTE IMMEDIATE takes a string
-- expression, not a subquery. USE DATABASE is set inside the block: the block
-- runs in its own session context and CREATE PROCEDURE fails without it.
DECLARE
    S VARCHAR;
BEGIN
    USE DATABASE MENDIX_APP;
    USE SCHEMA AGENTS;
    S := (SELECT DDL FROM MENDIX_APP.AGENTS.TMP_PROC_PATCH);
    EXECUTE IMMEDIATE :S;
    RETURN 'PROCESS_BL_DOCUMENTS patched';
END;

DROP TABLE IF EXISTS TMP_PROC_PATCH;

-- Confirm all four edits are present in the deployed procedure. Expect 1,1,1,1
-- and zero occurrences of the two replaced fragments.
SELECT REGEXP_COUNT(T, 'BL_DOC_CONFIDENCE')      AS HAS_CONF_FN,
       REGEXP_COUNT(T, 'IFF\\(:confidence >= 100') AS HAS_STRICT_THRESHOLD,
       REGEXP_COUNT(T, 'BL_DOC_ALERT')            AS HAS_ALERT_FN,
       REGEXP_COUNT(T, 'authoritative')           AS HAS_NARRATE_ONLY_PROMPT,
       REGEXP_COUNT(T, ':key_ok \\* 25\\.0')        AS OLD_CONF_REMAINING,
       REGEXP_COUNT(T, ':alert_parsed:"Alert"')   AS OLD_ALERT_REMAINING
  FROM (SELECT GET_DDL('PROCEDURE','MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS()') AS T);


-- ----------------------------------------------------------------------------
-- 8. Grants
-- ----------------------------------------------------------------------------
-- CREATE OR REPLACE drops existing GRANT USAGE on both functions and procedures,
-- so the judge role must be re-granted every time this file runs. Section 7
-- replaces PROCESS_BL_DOCUMENTS, which is why it is re-granted here too.
GRANT USAGE ON FUNCTION CARRIER_FROM_CODE(VARCHAR)    TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON FUNCTION CARRIER_FROM_VESSEL(VARCHAR)  TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON FUNCTION BL_DOC_ALERT(VARCHAR, VARCHAR, VARCHAR, FLOAT, DATE)      TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON FUNCTION BL_DOC_CONFIDENCE(VARCHAR, VARCHAR, VARCHAR, FLOAT, DATE) TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON PROCEDURE PROCESS_BL_DOCUMENTS()       TO ROLE HACKATHON_JUDGE_ROLE;

-- Verify under TRUE least privilege. USE ROLE alone is not enough: if
-- CURRENT_SECONDARY_ROLES() is ALL then ACCOUNTADMIN privileges still apply and
-- a missing grant goes undetected. Both statements are required.
--   USE ROLE HACKATHON_JUDGE_ROLE;
--   USE SECONDARY ROLES NONE;
--   SELECT DOC_ID,
--          BL_DOC_ALERT(BL_NUMBER, CONTAINER_NUMBER, VESSEL_NAME,
--                       GROSS_WEIGHT_KG, DATE_OF_ISSUE) AS COMPUTED,
--          ALERT, CONFIDENCE_SCORE, STATUS
--     FROM MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED
--    WHERE DOC_ID IN (1, 401, 402) ORDER BY DOC_ID;
-- Verified 2026-08-18: functions callable, and COMPUTED matches the stored
-- ALERT and CONFIDENCE_SCORE on every row.

