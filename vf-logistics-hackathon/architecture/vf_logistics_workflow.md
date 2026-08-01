# VF Logistics Intelligent Workflow Automation

## Overview
This skill enables CoCo CLI to orchestrate autonomous multi-step fraud detection and remediation workflows for VF Logistics maritime supply chain operations.

## Agent
- **Name:** VF_LOGISTICS_AGENT
- **Location:** MENDIX_APP.AGENTS.VF_LOGISTICS_AGENT
- **Capabilities:** Query data, search documents, run fraud scans, investigate anomalies, take remediation actions

## Workflows

### 1. Full Autonomous Workflow (Detect → Investigate → Act)

**Trigger:** "Scan for fraud and handle any issues" or "Run the full workflow"

**Steps executed autonomously:**
1. `run_fraud_scan` — Scans all recent shipments against 5 fraud rules
2. For each HIGH severity alert: `investigate_alert` — AI analyzes context and recommends action
3. Based on AI recommendation: `take_action` — Executes BLOCK/ESCALATE/CLEAR
4. Returns full audit trail with reasoning

**Example prompts:**
- "Check for fraud in today's shipments and handle any critical issues"
- "Run anomaly detection and automatically remediate high-risk shipments"
- "Execute the full fraud workflow - detect, investigate, and act"

### 2. Detection Only

**Trigger:** "Scan for anomalies" or "Run fraud detection"

**Procedure:** `CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT()`

**What it does:**
- Rule 1: High-value anomaly (charges > $50,000)
- Rule 2: Weight anomaly (> 30,000 kg)
- Rule 3: Suspicious party names (known shell companies)
- Auto-flags HIGH severity shipments as Pending_Review
- Returns JSON: new_alerts count, high_severity count, shipments_flagged

### 3. Investigation

**Trigger:** "Investigate alert #X" or "Why was this shipment flagged?"

**Procedure:** `CALL MENDIX_APP.AGENTS.WORKFLOW_INVESTIGATE_ANOMALY(<alert_id>)`

**What it does:**
- Pulls alert + full shipment context (shipper, consignee, route, charges, weight)
- Sends to Cortex AI (mistral-large2) for risk analysis
- Returns: risk level, suspicious indicators, recommended action

### 4. Remediation

**Trigger:** "Block shipment" or "Escalate to compliance" or "Clear the alert"

**Procedure:** `CALL MENDIX_APP.AGENTS.WORKFLOW_AUTO_REMEDIATE(<alert_id>, '<ACTION>')`

**Actions:**
| Action | Effect |
|--------|--------|
| BLOCK | Sets BL status=BLOCKED, resolves alert, notifies compliance |
| ESCALATE | Sets BL status=Pending_Review, marks alert as ESCALATED, queues for human review |
| CLEAR | Marks alert RESOLVED, sets fraud_check_passed=TRUE, approves for processing |

## Demo Script

### Scenario: "Document to Decision in 10 Seconds"

```
User: "A new batch of shipments just arrived. Scan for fraud and handle everything autonomously."

Agent Response:
━━━ STEP 1: FRAUD DETECTION ━━━
Scanned 247 shipments against 5 rules.
Found: 3 new alerts (2 HIGH, 1 MEDIUM)

━━━ STEP 2: INVESTIGATION ━━━
Alert #101 (HIGH_VALUE_ANOMALY):
  BL: DEMO032020 | Shipper: SUSPICIOUS TRADING CO | Charges: $75,000
  AI Assessment: HIGH RISK - Shell company + excessive charges
  Recommendation: BLOCK

Alert #102 (SUSPICIOUS_PARTY):
  BL: DEMO222337 | Shipper: SUSPICIOUS TRADING CO → SHELL CORP INTL
  AI Assessment: HIGH RISK - Known fraudulent entity pattern
  Recommendation: BLOCK

Alert #103 (WEIGHT_ANOMALY):
  BL: DEMO051220 | Weight: 35,000kg in standard container
  AI Assessment: MEDIUM RISK - Possible misdeclaration
  Recommendation: ESCALATE

━━━ STEP 3: ACTIONS TAKEN ━━━
✓ Alert #101: BLOCKED - Compliance notified
✓ Alert #102: BLOCKED - Compliance notified  
✓ Alert #103: ESCALATED - Queued for human review

━━━ SUMMARY ━━━
Workflow completed in 8.2 seconds
2 shipments blocked, 1 escalated for review
Full audit trail logged to NOTIFICATION_LOG
```

## Architecture

```
CoCo CLI (natural language prompt)
    │
    ▼
Cortex Agent (VF_LOGISTICS_AGENT)
    │
    ├─ Tool: query_logistics (Cortex Analyst - text-to-SQL)
    ├─ Tool: search_shipments (Cortex Search - semantic)
    ├─ Tool: run_fraud_scan (SQL Exec → WORKFLOW_DETECT_AND_ACT)
    ├─ Tool: investigate_alert (SQL Exec → WORKFLOW_INVESTIGATE_ANOMALY)
    └─ Tool: take_action (SQL Exec → WORKFLOW_AUTO_REMEDIATE)
    │
    ▼
Snowflake (Cortex AI + Stored Procedures + Streams + Tasks)
```

## Snowflake Features Used

| Feature | Purpose |
|---------|---------|
| **Cortex Agent** | Orchestrates multi-step workflow autonomously |
| **Cortex AI (COMPLETE)** | Risk analysis, anomaly explanation, decision reasoning |
| **Cortex Analyst** | Natural language to SQL for data queries |
| **Cortex Search** | Semantic document search across 10K+ B/L records |
| **Stored Procedures** | Workflow logic (detect, investigate, remediate) |
| **Streams + Tasks** | Real-time CDC pipeline across 4 phases |
| **Dynamic Tables** | Auto-refreshing KPIs and analytics |
| **Snowflake Marketplace** | Exchange rates, port weather, sanctions data |

## Key Differentiators for Hackathon

1. **Autonomous multi-step reasoning** — Agent chains detect→investigate→act without human intervention
2. **CoCo CLI as orchestrator** — Natural language triggers complex workflows
3. **Real-world supply chain** — Maritime logistics fraud is a $40B+ problem
4. **Full audit trail** — Every decision logged with AI reasoning for compliance
5. **10-second end-to-end** — From document arrival to SAP posting
