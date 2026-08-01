# Skill 3: AI Investigation & Remediation

## Metadata
| Field | Value |
|-------|-------|
| **Skill Name** | `ai_investigation_and_remediation` |
| **Category** | Autonomous Decision-Making (Cortex AI) |
| **Snowflake Objects** | `WORKFLOW_INVESTIGATE_ANOMALY(alert_id)`, `WORKFLOW_AUTO_REMEDIATE(alert_id, action)`, `AI_EXPLAIN_ANOMALY()`, `SNOWFLAKE.CORTEX.COMPLETE` (mistral-large2) |
| **Trigger Phrases** | "Investigate alert #X", "Why was this shipment flagged?", "Block/Escalate/Clear this alert" |
| **CLI Entry Point** | `CALL MENDIX_APP.AGENTS.WORKFLOW_INVESTIGATE_ANOMALY(<alert_id>);` then `CALL MENDIX_APP.AGENTS.WORKFLOW_AUTO_REMEDIATE(<alert_id>, '<ACTION>');` |

## Purpose
This is the **reasoning core** of the agentic workflow: uses Cortex AI (`mistral-large2`) to analyze full shipment context (shipper, consignee, route, charges, weight) and generate a natural-language risk assessment, then autonomously executes a remediation action — closing the loop from *detection* to *decision* to *action* without human intervention.

## Step 1: AI Investigation

**Input**: `alert_id` (NUMBER)

**Process**:
1. Pull alert + BL context (shipper, consignee, charges, weight, route, carrier)
2. Build context string
3. Call `SNOWFLAKE.CORTEX.COMPLETE('mistral-large2', <prompt>)` with instruction: *"Analyze this alert and provide: 1) Risk assessment (HIGH/MEDIUM/LOW), 2) Key suspicious indicators, 3) Recommended action (BLOCK/ESCALATE/CLEAR)"*
4. Update alert `STATUS = 'INVESTIGATING'`

**Output**:
```json
{"workflow":"INVESTIGATE_ANOMALY","alert_id":301,"bl_number":"DEMO063120","alert_type":"HIGH_VALUE_ANOMALY","context":"...","ai_analysis":"Risk: HIGH. Indicators: shell-company shipper, excessive charges. Recommended: BLOCK"}
```

## Step 2: Autonomous Remediation (Decision Branches)

| AI Recommendation | Action Taken | Downstream Effect |
|-------------------|--------------|--------------------|
| BLOCK | `BILL_OF_LADING.STATUS='BLOCKED'`, alert `RESOLVED` | Compliance team notified via `NOTIFICATION_LOG` |
| ESCALATE | `BILL_OF_LADING.STATUS='Pending_Review'`, alert `ESCALATED` | Queued for human review |
| CLEAR | Alert `RESOLVED`, `FRAUD_CHECK_PASSED=TRUE` | Shipment approved for processing |

## Error Handling
- Defensive `LIMIT 1` on both `SELECT INTO` queries (prevents "expects exactly 1 row" errors from data anomalies — **fixed bug from AUTOINCREMENT collision after account restore**)
- `AI_COMPLETE_WITH_RETRY` wrapper available for transient Cortex model failures
- `CHECK_AI_BUDGET()` / `SAFE_AI_CALL()` prevent runaway AI costs

## Full Chain Example (Live Test)
```sql
CALL MENDIX_APP.AGENTS.WORKFLOW_INVESTIGATE_ANOMALY(301);
-- Returns AI risk analysis
CALL MENDIX_APP.AGENTS.WORKFLOW_AUTO_REMEDIATE(301, 'ESCALATE');
-- {"workflow":"AUTO_REMEDIATE","alert_id":301,"action":"ESCALATE","bl_number":"DEMO063120","result":"Alert #301 ESCALATED to compliance team."}
```

## Orchestration — All 3 Skills Chained
This Skill is the final step in `WORKFLOW_FULL_PIPELINE_V2()`, which chains **all 3 Skills** into one CLI-executable command (see `sql/workflows/run_full_workflow_demo.sql`):

```
Skill 1 (Detect) → Skill 3 (Investigate) → Skill 2 (Sanctions Screen) → Skill 3 (Remediate)
```

Full audit trail logged to `WORKFLOW_AUDIT_LOG` for every step (input, output, status, timestamp).
