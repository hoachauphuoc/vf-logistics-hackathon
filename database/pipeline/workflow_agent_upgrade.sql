-- ============================================================
-- VF LOGISTICS - CoCo CLI WORKFLOW AUTOMATION
-- Hackathon: Snowflake CoCo CLI Hackathon 2026
-- Team: SORA | Track: Intelligent Workflow Automation Agent
-- ============================================================

-- PROCEDURE 1: DETECT AND ACT
-- Scans recent shipments for fraud, creates alerts, auto-flags high-severity
CREATE OR REPLACE PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
DECLARE
    v_new_alerts NUMBER DEFAULT 0;
    v_high_severity NUMBER DEFAULT 0;
    v_actions_taken NUMBER DEFAULT 0;
BEGIN
    -- Rule 1: High-value anomaly
    INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_TYPE, SEVERITY, DESCRIPTION, BL_ID, STATUS, CREATED_AT, DETECTED_AT)
    SELECT 'HIGH_VALUE_ANOMALY', 'HIGH',
        'Workflow: ' || BL_NUMBER || ' charges $' || TOTAL_CHARGES || ' exceed $50K',
        BL_ID, 'OPEN', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING
    WHERE TOTAL_CHARGES > 50000
      AND CREATED_AT > DATEADD('day', -7, CURRENT_TIMESTAMP())
      AND BL_ID NOT IN (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE BL_ID IS NOT NULL);
    v_new_alerts := SQLROWCOUNT;

    -- Rule 2: Weight anomaly
    INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_TYPE, SEVERITY, DESCRIPTION, BL_ID, STATUS, CREATED_AT, DETECTED_AT)
    SELECT 'WEIGHT_ANOMALY', 'MEDIUM',
        'Workflow: ' || BL_NUMBER || ' weight ' || GROSS_WEIGHT_KGS || 'kg exceeds 30T',
        BL_ID, 'OPEN', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING
    WHERE GROSS_WEIGHT_KGS > 30000
      AND CREATED_AT > DATEADD('day', -7, CURRENT_TIMESTAMP())
      AND BL_ID NOT IN (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE BL_ID IS NOT NULL);
    v_new_alerts := :v_new_alerts + SQLROWCOUNT;

    -- Rule 3: Suspicious parties
    INSERT INTO MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_TYPE, SEVERITY, DESCRIPTION, BL_ID, STATUS, CREATED_AT, DETECTED_AT)
    SELECT 'SUSPICIOUS_PARTY', 'HIGH',
        'Workflow: ' || BL_NUMBER || ' suspicious party: ' || SHIPPER_NAME,
        BL_ID, 'OPEN', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING
    WHERE (UPPER(SHIPPER_NAME) LIKE '%SUSPICIOUS%' OR UPPER(CONSIGNEE_NAME) LIKE '%SHELL CORP%')
      AND BL_ID NOT IN (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE BL_ID IS NOT NULL);
    v_new_alerts := :v_new_alerts + SQLROWCOUNT;

    -- Count high-severity
    SELECT COUNT(*) INTO :v_high_severity FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE SEVERITY = 'HIGH' AND STATUS = 'OPEN';

    -- Auto-flag
    UPDATE MENDIX_APP.AGENTS.BILL_OF_LADING 
    SET STATUS = 'Pending_Review', FRAUD_CHECK_PASSED = FALSE
    WHERE BL_ID IN (SELECT BL_ID FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE SEVERITY = 'HIGH' AND STATUS = 'OPEN' AND BL_ID IS NOT NULL)
      AND STATUS NOT IN ('Pending_Review', 'BLOCKED');
    v_actions_taken := SQLROWCOUNT;

    -- Log
    INSERT INTO MENDIX_APP.AGENTS.NOTIFICATION_LOG (NOTIFICATION_TYPE, RECIPIENT, SUBJECT, BODY, STATUS)
    VALUES ('WORKFLOW_RUN', 'system', 'Fraud Scan Complete', 'New alerts: ' || :v_new_alerts || ', High: ' || :v_high_severity || ', Flagged: ' || :v_actions_taken, 'SENT');

    RETURN '{"workflow":"DETECT_AND_ACT","status":"COMPLETED","new_alerts":' || :v_new_alerts || ',"high_severity_open":' || :v_high_severity || ',"shipments_flagged":' || :v_actions_taken || '}';
END;

-- PROCEDURE 2: INVESTIGATE ANOMALY
-- AI-powered deep-dive on a specific fraud alert
CREATE OR REPLACE PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_INVESTIGATE_ANOMALY(P_ALERT_ID NUMBER)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
DECLARE
    v_alert_type VARCHAR;
    v_bl_id NUMBER;
    v_description VARCHAR;
    v_bl_number VARCHAR;
    v_shipper VARCHAR;
    v_consignee VARCHAR;
    v_charges NUMBER;
    v_weight NUMBER;
    v_carrier VARCHAR;
    v_port_load VARCHAR;
    v_port_discharge VARCHAR;
    v_ai_analysis VARCHAR;
    v_context VARCHAR;
BEGIN
    -- Step 1: Get alert details
    SELECT ALERT_TYPE, BL_ID, DESCRIPTION 
    INTO :v_alert_type, :v_bl_id, :v_description
    FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :P_ALERT_ID;

    -- Step 2: Get shipment context
    SELECT BL_NUMBER, SHIPPER_NAME, CONSIGNEE_NAME, TOTAL_CHARGES, GROSS_WEIGHT_KGS, CARRIER_NAME, PORT_OF_LOADING_LOCODE, PORT_OF_DISCHARGE_LOCODE
    INTO :v_bl_number, :v_shipper, :v_consignee, :v_charges, :v_weight, :v_carrier, :v_port_load, :v_port_discharge
    FROM MENDIX_APP.AGENTS.BILL_OF_LADING WHERE BL_ID = :v_bl_id;

    -- Step 3: Build context for AI
    v_context := 'Alert: ' || :v_alert_type || '. BL: ' || :v_bl_number || '. Shipper: ' || :v_shipper || '. Consignee: ' || :v_consignee || '. Charges: $' || NVL(TO_VARCHAR(:v_charges),'N/A') || '. Weight: ' || NVL(TO_VARCHAR(:v_weight),'N/A') || 'kg. Carrier: ' || :v_carrier || '. Route: ' || :v_port_load || ' -> ' || :v_port_discharge;

    -- Step 4: AI analysis using Cortex
    SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-large2', 
        'You are a maritime logistics fraud analyst. Analyze this alert and provide: 1) Risk assessment (HIGH/MEDIUM/LOW), 2) Key suspicious indicators, 3) Recommended action (BLOCK/ESCALATE/CLEAR). Be concise.\n\nAlert context: ' || :v_context
    ) INTO :v_ai_analysis;

    -- Step 5: Update alert status
    UPDATE MENDIX_APP.AGENTS.FRAUD_ALERT SET STATUS = 'INVESTIGATING' WHERE ALERT_ID = :P_ALERT_ID;

    RETURN '{"workflow":"INVESTIGATE_ANOMALY","alert_id":' || :P_ALERT_ID || ',"bl_number":"' || :v_bl_number || '","alert_type":"' || :v_alert_type || '","context":"' || REPLACE(:v_context, '"', '\\"') || '","ai_analysis":' || :v_ai_analysis || '}';
END;

-- PROCEDURE 3: AUTO-REMEDIATE
-- Execute action on a fraud alert (BLOCK / ESCALATE / CLEAR)
CREATE OR REPLACE PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_AUTO_REMEDIATE(P_ALERT_ID NUMBER, P_ACTION VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
DECLARE
    v_bl_id NUMBER;
    v_bl_number VARCHAR;
    v_result VARCHAR;
BEGIN
    SELECT BL_ID INTO :v_bl_id FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE ALERT_ID = :P_ALERT_ID;
    SELECT BL_NUMBER INTO :v_bl_number FROM MENDIX_APP.AGENTS.BILL_OF_LADING WHERE BL_ID = :v_bl_id;

    CASE UPPER(:P_ACTION)
        WHEN 'BLOCK' THEN
            UPDATE MENDIX_APP.AGENTS.BILL_OF_LADING SET STATUS = 'BLOCKED', FRAUD_CHECK_PASSED = FALSE WHERE BL_ID = :v_bl_id;
            UPDATE MENDIX_APP.AGENTS.FRAUD_ALERT SET STATUS = 'RESOLVED', RESOLVED_AT = CURRENT_TIMESTAMP(), RESOLUTION_NOTES = 'Auto-blocked by workflow' WHERE ALERT_ID = :P_ALERT_ID;
            INSERT INTO MENDIX_APP.AGENTS.NOTIFICATION_LOG (NOTIFICATION_TYPE, RECIPIENT, SUBJECT, BODY, STATUS)
            VALUES ('FRAUD_BLOCK', 'compliance@vflogistics.com', 'Shipment Blocked', 'BLOCKED: Shipment ' || :v_bl_number || ' blocked due to fraud alert #' || :P_ALERT_ID, 'SENT');
            v_result := 'Shipment ' || :v_bl_number || ' BLOCKED. Compliance team notified.';

        WHEN 'ESCALATE' THEN
            UPDATE MENDIX_APP.AGENTS.BILL_OF_LADING SET STATUS = 'Pending_Review' WHERE BL_ID = :v_bl_id;
            UPDATE MENDIX_APP.AGENTS.FRAUD_ALERT SET STATUS = 'ESCALATED', RESOLUTION_NOTES = 'Escalated to compliance team' WHERE ALERT_ID = :P_ALERT_ID;
            INSERT INTO MENDIX_APP.AGENTS.NOTIFICATION_LOG (NOTIFICATION_TYPE, RECIPIENT, SUBJECT, BODY, STATUS)
            VALUES ('FRAUD_ESCALATE', 'compliance@vflogistics.com', 'Alert Escalated', 'Alert #' || :P_ALERT_ID || ' on ' || :v_bl_number || ' needs human review', 'SENT');
            v_result := 'Alert #' || :P_ALERT_ID || ' ESCALATED to compliance team.';

        WHEN 'CLEAR' THEN
            UPDATE MENDIX_APP.AGENTS.FRAUD_ALERT SET STATUS = 'RESOLVED', RESOLVED_AT = CURRENT_TIMESTAMP(), RESOLUTION_NOTES = 'Cleared - no fraud confirmed' WHERE ALERT_ID = :P_ALERT_ID;
            UPDATE MENDIX_APP.AGENTS.BILL_OF_LADING SET FRAUD_CHECK_PASSED = TRUE WHERE BL_ID = :v_bl_id;
            v_result := 'Alert #' || :P_ALERT_ID || ' CLEARED. Shipment ' || :v_bl_number || ' approved.';

        ELSE
            v_result := 'ERROR: Unknown action. Use BLOCK, ESCALATE, or CLEAR.';
    END CASE;

    RETURN '{"workflow":"AUTO_REMEDIATE","alert_id":' || :P_ALERT_ID || ',"action":"' || :P_ACTION || '","bl_number":"' || :v_bl_number || '","result":"' || :v_result || '"}';
END;

-- PROCEDURE 4: FULL PIPELINE (Demo - chains all 3 steps)
CREATE OR REPLACE PROCEDURE MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
DECLARE
    v_scan_result VARCHAR;
    v_investigate_result VARCHAR;
    v_action_result VARCHAR;
    v_alert_id NUMBER;
BEGIN
    -- STEP 1: Detect
    CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT();

    -- STEP 2: Pick top unresolved HIGH alert
    SELECT ALERT_ID INTO :v_alert_id 
    FROM MENDIX_APP.AGENTS.FRAUD_ALERT 
    WHERE SEVERITY = 'HIGH' AND STATUS = 'OPEN' 
    ORDER BY CREATED_AT DESC LIMIT 1;

    -- STEP 3: Investigate
    CALL MENDIX_APP.AGENTS.WORKFLOW_INVESTIGATE_ANOMALY(:v_alert_id);

    -- STEP 4: Remediate
    CALL MENDIX_APP.AGENTS.WORKFLOW_AUTO_REMEDIATE(:v_alert_id, 'ESCALATE');

    RETURN '{"workflow":"FULL_PIPELINE","status":"COMPLETED","steps":["DETECT","INVESTIGATE","REMEDIATE"],"alert_investigated":' || :v_alert_id || ',"action_taken":"ESCALATE"}';
END;

-- CORTEX AGENT (upgraded with workflow tools)
CREATE OR REPLACE AGENT MENDIX_APP.AGENTS.VF_LOGISTICS_AGENT
SPEC = $$
{
  "models": {"orchestration": "auto"},
  "orchestration": {"budget": {"seconds": 180, "tokens": 150000}},
  "instructions": {
    "orchestration": "You are VF Logistics Intelligent Workflow Agent for a seaport logistics platform managing 10,000+ Bills of Lading. You can: 1) Query shipment data and analytics, 2) Search documents semantically, 3) Run fraud detection workflows, 4) Investigate anomalies with AI reasoning, 5) Take automated actions (block/escalate/clear). When asked to handle fraud or anomalies, autonomously chain: detect -> investigate -> recommend action -> execute. Always respond in the same language the user uses (English, Vietnamese, or Japanese). Be concise and action-oriented.",
    "response": "Format responses with clear sections. Use tables for data. For workflow results, show each step taken and its outcome. Include alert IDs and BL numbers for traceability."
  },
  "tools": [
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "query_logistics",
        "description": "Query Bill of Lading shipment data including carriers, ports, charges, status, weight, commodities, dates, fraud alerts, and analytics."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_search",
        "name": "search_shipments",
        "description": "Semantic search across shipment documents. Find Bills of Lading by shipper, consignee, commodity, carrier, vessel, or port."
      }
    },
    {
      "tool_spec": {
        "type": "sql_exec",
        "name": "run_fraud_scan",
        "description": "Execute fraud detection workflow. Scans shipments for anomalies (high-value, overweight, suspicious parties), creates alerts, auto-flags high-severity. Returns JSON summary."
      }
    },
    {
      "tool_spec": {
        "type": "sql_exec",
        "name": "investigate_alert",
        "description": "AI investigation of a fraud alert. Gathers context, analyzes patterns, gives risk assessment and recommended action (BLOCK/ESCALATE/CLEAR). Requires alert_id parameter."
      }
    },
    {
      "tool_spec": {
        "type": "sql_exec",
        "name": "take_action",
        "description": "Execute remediation on a fraud alert. BLOCK=stop shipment, ESCALATE=human review, CLEAR=approve. Requires alert_id and action parameters. Logs to audit trail."
      }
    }
  ],
  "tool_resources": {
    "query_logistics": {
      "execution_environment": {"query_timeout": 60, "type": "warehouse", "warehouse": "COMPUTE_WH"},
      "semantic_model_file": "@MENDIX_APP.AGENTS.STREAMLIT_STAGE/vf_logistics_semantic_model.yaml"
    },
    "search_shipments": {
      "cortex_search_service": "MENDIX_APP.AGENTS.BL_SEARCH_SERVICE"
    },
    "run_fraud_scan": {
      "execution_environment": {"type": "warehouse", "warehouse": "COMPUTE_WH"},
      "sql": "CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT()"
    },
    "investigate_alert": {
      "execution_environment": {"type": "warehouse", "warehouse": "COMPUTE_WH"},
      "sql": "CALL MENDIX_APP.AGENTS.WORKFLOW_INVESTIGATE_ANOMALY({{alert_id}})"
    },
    "take_action": {
      "execution_environment": {"type": "warehouse", "warehouse": "COMPUTE_WH"},
      "sql": "CALL MENDIX_APP.AGENTS.WORKFLOW_AUTO_REMEDIATE({{alert_id}}, '{{action}}')"
    }
  }
}
$$;
