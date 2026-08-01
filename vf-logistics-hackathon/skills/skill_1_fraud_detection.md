# Skill 1: Fraud Detection & Scoring

## Metadata
| Field | Value |
|-------|-------|
| **Skill Name** | `fraud_detection_and_scoring` |
| **Category** | Anomaly Detection |
| **Snowflake Objects** | `WORKFLOW_DETECT_AND_ACT()`, `FRAUD_ALERT` table, `BILL_OF_LADING` table |
| **Trigger Phrases** | "Scan for fraud", "Run fraud detection", "Check for anomalies in recent shipments" |
| **CLI Entry Point** | `CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT();` |

## Purpose
Autonomously scans recent Bill of Lading (BL) shipments (last 7 days) against 3 fraud detection rules and flags high-risk shipments for review — no human intervention required for detection phase.

## Detection Rules (Decision Branches)

| Rule | Condition | Severity | Action |
|------|-----------|----------|--------|
| HIGH_VALUE_ANOMALY | `TOTAL_CHARGES > $50,000` | HIGH | Auto-flag `Pending_Review` |
| WEIGHT_ANOMALY | `GROSS_WEIGHT_KGS > 30,000 kg` | MEDIUM | Log alert, no auto-hold |
| SUSPICIOUS_PARTY | Shipper/Consignee name matches known shell-company patterns | HIGH | Auto-flag `Pending_Review` |

## Input / Output Contract

**Input**: None (scans `BILL_OF_LADING` internally for `CREATED_AT > NOW() - 7 days`)

**Output** (JSON):
```json
{
  "workflow": "DETECT_AND_ACT",
  "status": "COMPLETED",
  "new_alerts": 3,
  "high_severity_open": 2,
  "shipments_flagged": 2
}
```

## Error Handling
- Deduplicates alerts (`BL_ID NOT IN (SELECT BL_ID FROM FRAUD_ALERT ...)`) to prevent duplicate alerts per shipment
- Logs run summary to `NOTIFICATION_LOG` regardless of outcome (0 alerts is a valid, logged outcome)

## Example (Live Test Result)
```sql
CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT();
-- {"workflow":"DETECT_AND_ACT","status":"COMPLETED","new_alerts":0,"high_severity_open":1,"shipments_flagged":0}
```

## Downstream Skill
Alerts with `SEVERITY='HIGH'` feed into **Skill 3: AI Investigation & Remediation**.
