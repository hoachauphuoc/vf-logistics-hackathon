-- ============================================
-- SQL Query for ACT_AnalyzeBillOfLading Microflow
-- ============================================
-- PURPOSE: Extract data from uploaded PDF using Cortex AI
-- INPUT PARAMETER: {FileName} - staged file path (e.g., "bill_of_lading/uploaded_1721741234567_invoice.pdf")
-- OUTPUT: 5 columns matching ShipmentRecord entity
-- ============================================

WITH ai_result AS (
  SELECT REGEXP_REPLACE(
    SNOWFLAKE.CORTEX.COMPLETE(
      'claude-sonnet-4-5',
      CONCAT(
        'Extract from this Bill of Lading: ContainerNumber, VesselName, ArrivalDate in YYYY-MM-DD, ',
        'GrossWeight in tons, AI_ConfidenceScore 0-100. ',
        'Return ONLY raw JSON object, no markdown, no backticks.',
        BUILD_SCOPED_FILE_URL(@MENDIX_APP.AGENTS.LOGISTICS_STAGE, {FileName})
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
  PARSE_JSON(raw_text):"AI_ConfidenceScore"::INTEGER AS "AI_ConfidenceScore"
FROM ai_result;

-- ============================================
-- MENDIX CONFIGURATION
-- ============================================
-- 1. Parameter Name: FileName
-- 2. Parameter Type: String
-- 3. Parameter Value: $StagedFilename (from UploadFileToSnowflake action)
-- 4. Return Type: List of VF_Logistics_Portal.ShipmentRecord
-- ============================================
