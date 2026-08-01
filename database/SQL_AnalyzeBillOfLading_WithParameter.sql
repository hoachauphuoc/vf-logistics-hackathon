-- ============================================
-- SQL Query for ACT_AnalyzeBillOfLading Microflow
-- ============================================
-- PURPOSE: Extract data from uploaded PDF using Cortex AI (multimodal - reads REAL PDF content)
-- INPUT PARAMETER: Positional parameter {1} - staged file path (e.g., "bill_of_lading/uploaded_1721741234567_invoice.pdf")
-- OUTPUT: 6 columns matching ShipmentRecord entity
-- ============================================
-- IMPORTANT: Uses AI_COMPLETE + TO_FILE (multimodal document input), NOT the old
-- SNOWFLAKE.CORTEX.COMPLETE + BUILD_SCOPED_FILE_URL text-concat pattern. The old pattern
-- only passes a URL STRING in the prompt text - the model never actually reads the file
-- content and hallucinates plausible-looking data instead.
-- ============================================
-- NOTE: PROMPT() requires a literal "{0}" placeholder in its template text to refer to
-- the TO_FILE() argument. But Mendix's Execute Parameterized Query ALSO scans the SQL
-- text for "{n}" placeholders and requires them to start at index 1 - so a literal "{0}"
-- in the text breaks Mendix with error "CE0716: Place holder indices start at one (1)".
-- FIX: build the "{0}" string at Snowflake runtime via CHR(123)||'0'||CHR(125) instead of
-- writing it as literal text, so Mendix's parser never sees "{0}" in the raw template.
-- ============================================

WITH ai_result AS (
  SELECT REGEXP_REPLACE(
    AI_COMPLETE(
      'claude-sonnet-4-5',
      PROMPT(
        CONCAT(
          'Extract from this Bill of Lading: ContainerNumber, VesselName, ArrivalDate in YYYY-MM-DD, ',
          'GrossWeight in tons, AI_ConfidenceScore 0-100. ',
          'Score AI_ConfidenceScore based on extraction quality: start at 100 and deduct points for ',
          'each issue found - deduct 30 if any required field (ContainerNumber, VesselName, ArrivalDate, ',
          'GrossWeight) is missing/null, deduct 20 if text is blurry/unreadable or OCR quality is poor, ',
          'deduct 15 if a numeric field looks invalid (e.g. GrossWeight = 0) or a field contains garbled ',
          '/unexpected characters (e.g. ContainerNumber with symbols like @#$%), deduct 10 if dates are ',
          'inconsistent or implausible. Minimum score is 0. ',
          'Return ONLY raw JSON object, no markdown, no backticks. Document: ', CHR(123), '0', CHR(125)
        ),
        TO_FILE('@MENDIX_APP.AGENTS.LOGISTICS_STAGE', {1})
      )
    ),
    '^```json\\s*|\\s*```$', ''
  ) AS raw_text
)
SELECT 
  PARSE_JSON(raw_text):"ContainerNumber"::STRING AS "ContainerNumber",
  PARSE_JSON(raw_text):"VesselName"::STRING AS "VesselName",
  TO_TIMESTAMP_NTZ(PARSE_JSON(raw_text):"ArrivalDate"::STRING, 'YYYY-MM-DD') AS "ArrivalDate",
  PARSE_JSON(raw_text):"GrossWeight"::FLOAT AS "GrossWeight",
  PARSE_JSON(raw_text):"AI_ConfidenceScore"::INTEGER AS "AI_ConfidenceScore",
  raw_text AS "RawAIResponse"
FROM ai_result;

-- ============================================
-- MENDIX CONFIGURATION
-- ============================================
-- 1. In the "Parameters" table of the Execute Parameterized Query dialog, click New:
--    - Index: 1
--    - Type: String
--    - Value: $StagedFilename (from UploadFileToSnowflake action's output variable)
-- 2. Return Type: List of VF_Logistics_Portal.ShipmentRecord (6 columns mapped, including RawAIResponse)
-- ============================================
