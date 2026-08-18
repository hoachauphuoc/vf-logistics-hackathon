/*
============================================================
VF LOGISTICS - Intelligent Workflow Automation Agent
CLI-Executed End-to-End Workflow Demo
============================================================

PURPOSE:
  Demonstrates the full autonomous agentic workflow "executed
  through the CLI" as required by the hackathon problem statement.

  This single script triggers all 3 Agent Skills in sequence:
    Skill 1: Fraud Detection & Scoring      (WORKFLOW_DETECT_AND_ACT)
    Skill 3: AI Investigation               (WORKFLOW_INVESTIGATE_ANOMALY)
    Skill 2: Compliance & Sanctions Screen  (WORKFLOW_SANCTIONS_SCREEN)
    Skill 3: Autonomous Remediation         (WORKFLOW_AUTO_REMEDIATE)

HOW TO RUN VIA CLI:

  Option A - Snowflake CLI (snow sql):
    snow sql -f run_full_workflow_demo.sql --connection dpyxiqz-fn71223

  Option B - CoCo CLI (natural language, via Cortex Agent):
    "Scan for fraud and handle any issues autonomously"
    -> Cortex Agent VF_LOGISTICS_AGENT invokes the same procedures below

  Option C - Direct single command (fastest live demo):
    snow sql -q "CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');" --connection dpyxiqz-fn71223

EXPECTED RESULT (~6-8 seconds execution):
  {"workflow":"FULL_PIPELINE_V2","status":"COMPLETED","steps":5,
   "alert_id":<id>,"shipper_screened":"<name>",
   "execution_time_ms":<ms>,"audit_trail":"WORKFLOW_AUDIT_LOG"}
============================================================
*/

USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;

-- STEP 0: Seed fresh demo data (optional - creates a new suspicious shipment + HIGH alert)
CALL DEMO_PIPELINE();

-- STEP 1-4: Run the full autonomous workflow (Detect -> Investigate -> Screen -> Remediate)
CALL WORKFLOW_FULL_PIPELINE_V2('AUTO');

-- VERIFY: Show the full audit trail for this run (proof of multi-step orchestration)
SELECT
    AUDIT_ID,
    STEP_ORDER,
    STEP_NAME,
    INPUT_PARAMS,
    OUTPUT_RESULT,
    STATUS,
    EXECUTED_AT
FROM WORKFLOW_AUDIT_LOG
WHERE WORKFLOW_NAME = 'FULL_PIPELINE_V2'
ORDER BY AUDIT_ID DESC
LIMIT 4;

-- VERIFY: Show the resulting fraud alert + AI decision
SELECT
    ALERT_ID,
    ALERT_TYPE,
    SEVERITY,
    STATUS,
    RESOLUTION_NOTES,
    CREATED_AT,
    RESOLVED_AT
FROM FRAUD_ALERT
ORDER BY ALERT_ID DESC
LIMIT 5;
