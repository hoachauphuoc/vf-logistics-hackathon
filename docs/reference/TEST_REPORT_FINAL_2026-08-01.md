# Final Validation Report — VF Logistics Intelligent Workflow Automation Agent

**Test date:** 2026-08-01
**Account:** AYUGBCE-JX50275 · **Database/schema:** `MENDIX_APP.AGENTS`
**Executed through:** Cortex Code (CoCo) CLI against the live account

This report supersedes [`TEST_REPORT_SOLUTION.md`](TEST_REPORT_SOLUTION.md) (2026-07-27), which was written before the document-ingestion bridge existed and contains one incorrect claim (see *Corrections* at the end).

---

## 1. What was verified

| # | Capability | Result |
|---|---|---|
| 1 | Batch upload of PDFs in a single command | ✅ 2 files uploaded with one `PUT` |
| 2 | AI extraction of every new PDF | ✅ commercial + counterparty fields now populated |
| 3 | Promotion of documents into the operational table | ✅ 15 documents promoted (13 historical + 2 new) |
| 4 | Detection over promoted documents | ✅ `DOCUMENT_QUALITY` alert raised for the unreliable one only |
| 5 | AI decision persisted and executed | ✅ decision + reason stored, remediation acted on it |
| 6 | Audit trail with decision and reason | ✅ 3 wrapper steps + 5 pipeline steps logged |
| 7 | Sanctions screening against Marketplace data | ✅ ran on the shipper name extracted from the PDF |
| 8 | ERP posting | ✅ SAP document generated |
| 9 | Differentiated AI decisions (not a uniform fallback) | ✅ 1 BLOCK vs 6 CLEAR on the commercial dataset |
| 10 | Judge read-only access | ✅ `HACKATHON_JUDGE_ROLE` has SELECT on all referenced objects |

---

## 2. End-to-end: PDF to decision in one command

```sql
PUT file://bl_pdfs/*.pdf @MENDIX_APP.AGENTS.LOGISTICS_STAGE/bill_of_lading
  AUTO_COMPRESS=FALSE OVERWRITE=TRUE;      -- 2 files, one command

CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE();
```

Observed result:

```json
{"workflow":"INGEST_AND_DECIDE","status":"COMPLETED",
 "extraction":"Complete. Processed: 2 | Errors: 0",
 "promotion":{"documents_promoted":2,"target":"MENDIX_APP.AGENTS.BILL_OF_LADING"},
 "pipeline":{"workflow":"FULL_PIPELINE_V2","status":"COMPLETED","steps":5,
             "alert_id":711,"ai_decision":"ESCALATE",
             "ai_reason":"Extraction confidence below 60/100 and failed validation, underlying data cannot be trusted.",
             "shipper_screened":"LONG AN GARMENT FACTORY CO., LTD",
             "sap_posting":{"status":"SUCCESS","sap_document":"5000000107"},
             "execution_time_ms":11259},
 "total_execution_time_ms":14470}
```

**Traceability check** — one join proves the whole chain:

| PDF | Extraction confidence | Extraction validation | Promoted BL | Alert | AI decision |
|---|---|---|---|---|---|
| `BATCH_A_VALID.pdf` | 100/100 | No anomalies detected | `MAEU2026001`, APPROVED | none | — (nothing to decide) |
| `BATCH_B_ERROR.pdf` | 25/100 | ContainerNumber; VesselName; GrossWeightKg | `EGLV2026015`, Pending_Review | `DOCUMENT_QUALITY` / HIGH | **ESCALATE** |

A clean document is approved silently; an unreliable one is escalated with a reason a compliance reviewer can read.

---

## 3. The AI genuinely differentiates its decisions

Run over seven commercial alerts with the same rubric:

| Shipper | Cost/kg | Decision | Reason recorded |
|---|---|---|---|
| SUSPICIOUS TRADING CO | $0.7895 (3.1x peer median $0.256) | **BLOCK** | shell/front company naming plus cost per kg over 3x peer median |
| Panasonic Vietnam | $0.2662 | CLEAR | within normal ranges, 0 sanctions matches |
| Trung Nguyen Coffee | $0.2066 | CLEAR | below peer median, recognisable counterparties |
| Hoa Sen Group | $0.1983 | CLEAR | below peer median, clean screening |
| Vinamilk Co Ltd | $0.3959 | CLEAR | normal economics, duplicate-BL flag only |
| Foxconn Vietnam | $0.2044 | CLEAR | below all thresholds |
| Honda Vietnam | $1.0027 | CLEAR | still below the 95th percentile |

The blocked shipment's `BILL_OF_LADING` row moved to `STATUS = BLOCKED`, `FRAUD_CHECK_PASSED = FALSE`; the cleared ones to `FRAUD_CHECK_PASSED = TRUE`.

Verify with:
```sql
SELECT ALERT_ID, SEVERITY, SHIPPER_NAME, AI_DECISION, AI_DECISION_REASON, ALERT_STATUS
FROM MENDIX_APP.AGENTS.V_AI_DECISIONS ORDER BY AI_ANALYZED_AT DESC;
```

---

## 4. Audit trail

```sql
SELECT WORKFLOW_NAME, STEP_ORDER, STEP_NAME, OUTPUT_RESULT, STATUS
FROM MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
ORDER BY EXECUTED_AT DESC LIMIT 8;
```

Observed sequence for a single run:

| Workflow | Step | Output |
|---|---|---|
| INGEST_AND_DECIDE | 1 EXTRACT_DOCUMENTS | `Complete. Processed: 2 | Errors: 0` |
| INGEST_AND_DECIDE | 2 PROMOTE_TO_OPERATIONAL | `documents_promoted: 2` |
| FULL_PIPELINE_V2 | 1 DETECT_ANOMALIES | Scan completed |
| FULL_PIPELINE_V2 | 2 AI_INVESTIGATE | `AI decision=ESCALATE | reason=...` |
| FULL_PIPELINE_V2 | 3 SANCTIONS_SCREEN | Marketplace screening completed |
| FULL_PIPELINE_V2 | 4 AUTO_REMEDIATE | `action=ESCALATE (decided by AI)` |
| FULL_PIPELINE_V2 | 5 SAP_POST | SAP document 5000000107 |
| INGEST_AND_DECIDE | 3 FRAUD_PIPELINE | full pipeline JSON |

Both the decision and the reason for it appear in the log — a reviewer never has to guess why an action was taken.

---

## 5. Objects confirmed present

**Procedures:** `PROCESS_BL_DOCUMENTS`, `SYNC_EXTRACTED_TO_BILL_OF_LADING`, `WORKFLOW_INGEST_AND_DECIDE`, `WORKFLOW_DETECT_AND_ACT`, `WORKFLOW_INVESTIGATE_ANOMALY`, `WORKFLOW_SANCTIONS_SCREEN`, `WORKFLOW_AUTO_REMEDIATE`, `WORKFLOW_FULL_PIPELINE_V2`, `CHECK_COMPLIANCE`, `SEARCH_BILL_OF_LADING`, `SAP_POST_FI_DOCUMENT`

**Views:** `V_AI_DECISIONS` (new), `V_EXCHANGE_RATES`, plus the analytics views used by the dashboard

**Streams:** `NEW_PDF_STREAM` (on the stage), `BL_CHANGE_STREAM` (on `BILL_OF_LADING`)

**Marketplace dependency:** `SNOWFLAKE_PUBLIC_DATA_FREE` mounted from listing `GZTSZ290BV255`

---

## 6. Judge access

`HACKATHON_JUDGE_ROLE` holds: `USAGE` on `MENDIX_APP`, `MENDIX_APP.AGENTS`, `COMPUTE_WH` and the Streamlit app, plus `SELECT` on every table and view referenced in this repository — including `BILL_OF_LADING`, `BILL_OF_LADING_EXTRACTED`, `FRAUD_ALERT`, `WORKFLOW_AUDIT_LOG` and `V_AI_DECISIONS`.

The role is deliberately read-only: it cannot `CALL` the workflow procedures, so a reviewer can inspect every result without being able to mutate the demo state.

---

## 7. Cost posture at time of submission

| Component | State | Note |
|---|---|---|
| `COMPUTE_WH` | Suspended, `AUTO_SUSPEND=60s`, `AUTO_RESUME=true` | resumes in seconds on the first query |
| All 7 tasks | Suspended | `TASK_PROCESS_NEW_BL` now calls `WORKFLOW_INGEST_AND_DECIDE`; `RESUME` it for hands-off operation |
| `BL_SEARCH_SERVICE` (Cortex Search) | Suspended at submission time | **must be resumed manually before using semantic search** — it does *not* auto-resume. Re-checked 2026-08-17: the service is now `ACTIVE` and serving, so no resume step is needed today (see Section 9) |
| Resource monitor | `VF_LOGISTICS_MONITOR` attached to `COMPUTE_WH` | guards the trial credit |

---

## 8. Defects found and fixed during this validation

| Defect | Impact | Fix |
|---|---|---|
| Document intelligence and the fraud agent shared no data (0 row overlap) | An uploaded PDF could never reach a decision | `SYNC_EXTRACTED_TO_BILL_OF_LADING` bridge |
| Extraction never captured shipper, consignee or freight charges | All three commercial detection rules were unreachable from PDF data | extended extraction prompt |
| A stage directory table does not see files added by `PUT` | Upload-then-process silently reported `Processed: 0` | `ALTER STAGE ... REFRESH` inside the procedure |
| Free-text ports overflow `PORT_OF_*_LOCODE` (10 chars) | Promotion aborted with a truncation error | extract the UN/LOCODE, truncate every text column |
| Orchestrator hard-coded `ESCALATE` and discarded the AI's recommendation | The workflow only *looked* autonomous | decision parsed, persisted and executed |
| `RESOLUTION_NOTES` held generic template text | No explanation of why an action was taken | AI reason written into the notes and notification |

---

## 9. Re-validation for the Refinement Phase (2026-08-17)

The system was idle (no pipeline calls) between 2026-08-02 and 2026-08-16 while a keep-alive ping (homepage-only) held the Mendix Free App awake. On 2026-08-17 the full pipeline was re-run cold, after 15 days of no workflow activity, to confirm nothing had degraded:

```sql
CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');
```

```json
{"workflow":"FULL_PIPELINE_V2","status":"COMPLETED","alerts_processed":1,
 "decisions":{"blocked":0,"escalated":0,"cleared":1},
 "sap_documents_posted":1,"ai_decision":"CLEAR",
 "ai_reason":"Sanctions matches = 0, cost-per-kg band is NORMAL_AT_OR_BELOW_5X_MEDIAN, and both counterparties are recognisable real businesses.",
 "shipper_screened":"Viettel Electronics","execution_time_ms":13192}
```

Updated AI decision-quality metric (`CALL EVALUATE_AI_DECISIONS();`), now over 341 decisions (up from 336 at submission time):

| Metric | 2026-08-02 (submission) | 2026-08-17 (refinement) |
|---|---|---|
| Decisions evaluated | 336 | 341 |
| Policy adherence | 95.8% | 95.9% |
| Critical false negatives (should-BLOCK cleared) | 0 | 0 |

Current live KPI snapshot: **10,017 shipments**, **$52.87M revenue**, **12 carriers**, 1,195 pending, 1,740 approved, 2,882 in transit — consistent with the submission-time figures, confirming the dataset has not drifted or corrupted during the idle period.

**Conclusion:** the pipeline, AI decision logic, and audit trail all remain fully functional after an extended idle period with only homepage keep-alive traffic — no regression found.

### Defect found and fixed during this re-validation

| Defect | Impact | Fix |
|---|---|---|
| `BL_SEARCH_CORPUS` had drifted out of sync with `BILL_OF_LADING` — 27 shipments missing from the corpus and 15 orphaned corpus rows pointing at shipments deleted during the 2026-08-02 demo-data cleanup | Cortex Search could not find the most recently ingested shipments, including the PDF-ingested ones that the document-to-decision story depends on; semantic search silently returned nothing for them | Rebuilt the corpus with `INSERT OVERWRITE ... SELECT FROM BILL_OF_LADING`. Verified afterwards: 10,017 corpus rows = 10,017 shipment rows, **0 missing, 0 orphans** |

Root cause: `BL_SEARCH_CORPUS` is populated by an explicit `INSERT`, not by a Dynamic Table or Stream, so it does not track inserts/deletes on `BILL_OF_LADING` automatically. Re-run the rebuild statement (it is included at the bottom of `backup_2026-08-17/ddl/04_load_data.sql`) after any bulk change to the shipment table.

---

## Corrections to the 2026-07-27 report

- That report states the Cortex Search Service is *"SUSPENDED (will auto-resume on query)"*. **This is incorrect.** A suspended Cortex Search Service raises `error_code 399131 — Service suspended`; it must be resumed explicitly:
  ```sql
  ALTER CORTEX SEARCH SERVICE MENDIX_APP.AGENTS.BL_SEARCH_SERVICE RESUME;
  ```
- Its architecture description predates the ingestion bridge and the AI-decided remediation, so treat Section 2 of this report as the current description of the workflow.
