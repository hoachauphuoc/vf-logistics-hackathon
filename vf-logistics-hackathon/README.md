# VF Logistics — Intelligent Workflow Automation Agent

**Snowflake CoCo CLI Hackathon submission** — an AI-driven agentic system that autonomously detects, investigates, screens, and remediates fraud/compliance risk in maritime logistics (Bill of Lading) shipments.

> Built end-to-end using **Cortex Code (CoCo) CLI** — every procedure, bug fix, and workflow in this repo was authored, debugged, and validated through CoCo CLI sessions. **Concrete, reproducible evidence: [`docs/COCO_CLI_EVIDENCE.md`](docs/COCO_CLI_EVIDENCE.md)**

---

## 0. Live Prototype — Snowflake Streamlit (Unified Interface)

**Primary interface:** Snowflake Streamlit-in-Snowflake application `VF_LOGISTICS_DASHBOARD`

> The entire application runs natively inside Snowflake — no external dependencies. The Streamlit app is the **single unified interface** for document upload, AI processing, fraud detection, compliance monitoring, and conversational AI chat.

**Key capabilities (all inside Streamlit):**
- **Document Upload & AI Processing** — Upload Bill of Lading PDFs directly via the Documents page; Cortex AI extracts fields, validates, and promotes to the operational table
- **AI Chat with Session Persistence** — Natural language queries over logistics data, with conversation history maintained throughout the session
- **Autonomous Pipeline Execution** — Run the full detect → investigate → screen → remediate → SAP post workflow from the UI
- **Real-time Analytics** — Carrier revenue, shipment status, weekly trends, FX rates, sanctions screening, AI usage/cost monitoring

Important notes for judges:
- The **entry point** is the Streamlit dashboard running inside Snowflake (account `DPYXIQZ-FN71223`)
- The **autonomous workflow execution** (Fraud Detection → AI Investigation → Sanctions Screening → Remediation) can be triggered from the Fraud Detection page or the AI Chat sidebar
- Every detection, AI decision, audit log entry, and ERP post is made inside Snowflake — no external runtime
- **Reviewer access**: a read-only role `HACKATHON_JUDGE_ROLE` is available; contact the team for credentials

> **Note on Mendix**: The original submission included a Mendix sandbox as the operator UI. Per evaluator feedback ("Merge External Sandbox Portal with Native Streamlit Application"), all functionality has been consolidated into the native Streamlit app. The Mendix integration code is retained in `mendix-integration/` as reference for the JDBC key-pair auth pattern, but it is no longer the primary interface.

## 1. Problem & Business Impact

Maritime freight fraud (undervalued/overvalued cargo, shell-company shippers, sanctioned entities) costs the logistics industry **$40B+ annually**. Manual review of every Bill of Lading is too slow to scale. VF Logistics needs a system that:

- Continuously scans incoming shipments for anomalies
- Reasons over context (not just static rules) to assess real risk
- Screens counterparties against real US government export-restriction data sourced from Snowflake Marketplace
- Takes autonomous action (block/escalate/clear) — with full audit trail for compliance

**Measurable impact**: full detect → investigate → screen → remediate cycle completes in **~6-10 seconds** per shipment, vs. hours/days for manual compliance review. Every step records its own wall-clock duration, so this is verifiable rather than asserted — measured breakdown per alert: AI investigation ~4.4s, anomaly detection ~2.0s, remediation ~1.2s, sanctions screening ~0.2s. Reproduce it with:

```sql
SELECT STEP_NAME, COUNT(*) AS RUNS, ROUND(AVG(EXECUTION_TIME_MS)) AS AVG_MS
FROM MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
WHERE WORKFLOW_NAME = 'FULL_PIPELINE_V2' AND EXECUTION_TIME_MS IS NOT NULL
GROUP BY STEP_NAME ORDER BY AVG_MS DESC;
```

The current demo dataset holds **just over 10,000 shipments** and **roughly $53M USD** in represented cargo charges — these numbers are live, not a fixed snapshot: the pipeline autonomously updates shipment status and charges as it runs, so re-running the query in Section 10 minutes apart can show a slightly different figure. That drift is expected behavior, not a data error.

---

## 2. Architecture

```
                    ┌─────────────────────────────┐
   CoCo CLI /        │   Cortex Agent               │
   Natural Language ─▶  VF_LOGISTICS_AGENT           │
   or Direct SQL/CLI │  (5 tools: query, search,    │
   or Python/Snowpark│   fraud_scan, investigate,   │
                      │   take_action)               │
                      └───────────────┬──────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        ▼                             ▼                             ▼
┌───────────────────┐      ┌───────────────────────┐      ┌──────────────────────┐
│ SKILL 1            │      │ SKILL 2                │      │ SKILL 3               │
│ Fraud Detection     │─────▶│ Compliance &           │─────▶│ AI Investigation &    │
│ & Scoring           │      │ Sanctions Screening    │      │ Remediation           │
│                     │      │                        │      │                       │
│ WORKFLOW_DETECT_    │      │ CHECK_COMPLIANCE        │      │ WORKFLOW_INVESTIGATE_ │
│ AND_ACT             │      │ WORKFLOW_SANCTIONS_    │      │ ANOMALY (Cortex AI)   │
│                     │      │ SCREEN (Marketplace)   │      │ WORKFLOW_AUTO_        │
│                     │      │                        │      │ REMEDIATE             │
└───────────────────┘      └───────────────────────┘      └──────────────────────┘
        │                             │                             │
        └─────────────────────────────┴─────────────────────────────┘
                                      ▼
                    WORKFLOW_FULL_PIPELINE_V2 (orchestrator)
                    → WORKFLOW_AUDIT_LOG (full audit trail)
```

**Snowflake features used**: Cortex Agent, Cortex AI (`COMPLETE` — mistral-large2), Cortex Analyst (text-to-SQL), Cortex Search (semantic BL search), Snowflake Marketplace (real US government export-screening data + FX rates), Dynamic Tables, Streams + Tasks, Streamlit.

**Languages used**: SQL (core workflow logic), **Python** (Snowpark risk scoring + Streamlit dashboard), **Java** (Mendix integration — reference only, not primary interface).

---

## 3. The 3 Agent Skills

| Skill | File | Purpose |
|-------|------|---------|
| 1. Fraud Detection & Scoring | [`skills/skill_1_fraud_detection.md`](skills/skill_1_fraud_detection.md) | Scans shipments against 3 anomaly rules (value, weight, suspicious party) |
| 2. Compliance & Sanctions Screening | [`skills/skill_2_compliance_sanctions.md`](skills/skill_2_compliance_sanctions.md) | Rule-based compliance scoring + Marketplace-sourced export-restriction screening |
| 3. AI Investigation & Remediation | [`skills/skill_3_ai_investigation.md`](skills/skill_3_ai_investigation.md) | Cortex AI risk analysis + autonomous BLOCK/ESCALATE/CLEAR decision |

---

## 4. Run the Workflow — Executed Through the CLI

### Option A — Document to decision, from raw PDFs (the full story, one command)

Upload as many Bills of Lading as you like in a single command, then take them all the way to an autonomous decision with one more:

```bash
snow sql -q "PUT file://bl_pdfs/*.pdf @MENDIX_APP.AGENTS.LOGISTICS_STAGE/bill_of_lading AUTO_COMPRESS=FALSE OVERWRITE=TRUE;" --connection dpyxiqz-fn71223
snow sql -q "CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE();" --connection dpyxiqz-fn71223
```

If you are reproducing this on the author's workstation, note that the local `snow` CLI OAuth path is unreliable there; the same commands were therefore executed through **Cortex Code's SQL runner** during validation and in the final demo script.

`WORKFLOW_INGEST_AND_DECIDE` chains three stages and logs each one:
`PROCESS_BL_DOCUMENTS` (OCR + AI extraction of every new PDF) → `SYNC_EXTRACTED_TO_BILL_OF_LADING` (promote the documents into the operational table) → `WORKFLOW_FULL_PIPELINE_V2` (detect → investigate → screen → AI-decided remediation → ERP posting).

The **Mendix chat panel and Python/Snowpark call this same procedure**, so every interface executes identical logic.

Fully hands-off operation is one statement away — a stream on the stage already feeds a task:
```sql
ALTER TASK MENDIX_APP.AGENTS.TASK_PROCESS_NEW_BL RESUME;   -- fires on new files, every 5 min
```
It ships **suspended** so an idle trial account is not billed.

### Option B — Fraud pipeline only (fastest live demo, no upload needed)
```bash
snow sql -q "CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');" --connection dpyxiqz-fn71223
```

One alert per call keeps the demo fast. To work down a backlog instead, pass a batch size — the orchestrator loops through that many open HIGH-severity alerts in a single invocation, logging every step of every alert:
```sql
CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO', 10);   -- process up to 10 alerts
```

### Option C — Full demo script (seed data + run + show audit trail)
```bash
snow sql -f sql/workflows/run_full_workflow_demo.sql --connection dpyxiqz-fn71223
```

The home-dashboard "Run Pipeline" demo shortcut was deliberately removed from the Streamlit UI because it called a scripted `DEMO_PIPELINE()` helper rather than the real orchestrator, and that helper procedure has since been **dropped from the database entirely** — there is no scripted demo path left in this account. The only pipeline button in the UI runs the real backend flow.

### Option D — Natural language via Cortex Agent (CoCo CLI / Snowflake Intelligence)
> "Scan for fraud and handle any issues autonomously"

### Option E — From Python/Snowpark
```bash
python python/snowpark_risk_scoring.py --connection dpyxiqz-fn71223 --run-workflow
```

**Expected output** (~6-15s execution):
```json
{"workflow":"FULL_PIPELINE_V2","status":"COMPLETED","steps":5,
 "alert_id":310,"ai_decision":"BLOCK",
 "ai_reason":"Shipper and consignee names indicate shell/front companies, and cost per kg exceeds peer median by over 3x.",
 "shipper_screened":"SUSPICIOUS TRADING CO",
 "execution_time_ms":13392,"audit_trail":"WORKFLOW_AUDIT_LOG"}
```

### Option F — From the Mendix UI itself (no CLI access needed)

A judge who only has the public Mendix link (Section 0) can still trigger the exact same CLI-executed workflow, with no Snowflake login: open the **AI Assistant** chat panel (bottom-right of the Mendix homepage) and type `/run_pipeline`. Behind the scenes the panel shells out to the identical command as Option B — `snow sql -q "CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');"` — and streams back the same step-by-step result (`STEP 1/5 DETECT_ANOMALIES` … `STEP 5/5 SAP_POST`, then the raw JSON output and the alert/decision it produced). This is the same orchestrator and the same audit trail as every other option on this page; the Mendix chat is just one more caller of it, not a separate code path.

Trace a single PDF from file to decision:
```sql
SELECT e.FILE_NAME, e.CONFIDENCE_SCORE, e.ALERT,
       b.BL_NUMBER, b.STATUS,
       a.ALERT_TYPE, a.AI_RECOMMENDED_ACTION, a.AI_DECISION_REASON
FROM MENDIX_APP.AGENTS.BILL_OF_LADING_EXTRACTED e
JOIN MENDIX_APP.AGENTS.BILL_OF_LADING b ON b.BL_ID = e.BL_ID
LEFT JOIN MENDIX_APP.AGENTS.FRAUD_ALERT a ON a.BL_ID = b.BL_ID
ORDER BY e.DOC_ID DESC;
```
A clean document is promoted and approved with no alert; a document whose extraction could not be validated raises a `DOCUMENT_QUALITY` alert that the AI then reasons over and escalates.


The `ai_decision` field is produced by the model in step 2 and is what step 4 executes. To inspect every decision the AI has made, with its reasoning:

```sql
SELECT ALERT_ID, SEVERITY, SHIPPER_NAME, AI_DECISION, AI_DECISION_REASON, ALERT_STATUS
FROM MENDIX_APP.AGENTS.V_AI_DECISIONS
ORDER BY AI_ANALYZED_AT DESC;
```

Full step-by-step audit trail is queryable in `MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG`.

---

## 5. Repository Structure

```
vf-logistics-hackathon/
├── README.md                       (this file)
├── COMPLIANCE_CHECKLIST.md         Terms & Conditions compliance audit
├── PRESENTATION_OUTLINE.md         Slide-by-slide deck outline
├── docs/
│   └── COCO_CLI_EVIDENCE.md         Verifiable record of Cortex Code CLI usage (§9 criterion 1)
├── architecture/
│   ├── vf_logistics_workflow.md    Detailed workflow + demo script
│   ├── ARCHITECTURE_DIAGRAM.txt    Full system architecture
│   └── vf_logistics_semantic_view.yaml
├── skills/                         3 Agent Skill definitions
├── sql/
│   ├── workflows/
│   │   ├── agent_skills_procedures.sql   Self-contained procedure DDLs
│   │   └── run_full_workflow_demo.sql    CLI demo script
│   └── monitoring/
│       └── CREDIT_MONITORING_GUIDE.md
├── python/
│   └── snowpark_risk_scoring.py    Python/Snowpark risk scoring + orchestration
├── mendix-integration/
│   └── CallCortexAgent.java        Mendix Java action (JDBC → Snowflake)
└── ../docs/reference/
    ├── TEST_REPORT_FINAL_2026-08-01.md   Final end-to-end validation (current)
    └── TEST_REPORT_SOLUTION.md          Earlier validation run (2026-07-27, superseded)
```

---

## 6. Setup / Deployment Notes

- **Mendix integration**: `CallCortexAgent.java` authenticates to Snowflake with **key-pair (JWT) authentication** — `authenticator=SNOWFLAKE_JWT` plus a private key file (`snowflake_key.p8`) read from the Mendix runtime resources directory at request time. No password or key material is present in the source or in this repository (`*.p8` and `*.pem` are git-ignored); only the public key is registered on the Snowflake service user. This replaced an earlier password-based approach — see `COMPLIANCE_CHECKLIST.md` Section 5 for that history.
- **Snowflake Marketplace dependency**: `WORKFLOW_SANCTIONS_SCREEN` requires the free "Snowflake Public Data (Free)" listing mounted as `SNOWFLAKE_PUBLIC_DATA_FREE`:
  ```sql
  CALL SYSTEM$REQUEST_LISTING_AND_WAIT('GZTSZ290BV255', 120);
  CREATE DATABASE SNOWFLAKE_PUBLIC_DATA_FREE FROM LISTING 'GZTSZ290BV255';
  ```
- **Python/Snowpark script**: for live demos, run inside a **Snowflake Notebook** (uses `get_active_session()`, avoids interactive SSO auth) rather than a local terminal.

---

## 7. Datasets Used

| Dataset | Source | License |
|---------|--------|---------|
| BILL_OF_LADING (~10,000 rows, live count) | Self-generated synthetic data | N/A |
| Export-restricted entities list | Snowflake Marketplace — "Snowflake Public Data (Free)" (listing `GZTSZ290BV255`) | Free, Snowflake-provided |
| FX exchange rates (`V_EXCHANGE_RATES`) | Snowflake Marketplace-backed reference data in account | Snowflake-provided |
| HS_CODE_REFERENCE | Self-generated (based on public HS Code standard) | Public reference |

---

## 7.1 Data Provenance, Calibration & Known Limitations

Stated up front rather than left for a reviewer to discover:

- **The shipment data is synthetic.** `BILL_OF_LADING` is self-generated maritime simulation data, not a real carrier feed. The sanctions/export-restriction data it is screened against **is real** (Snowflake Marketplace, listing `GZTSZ290BV255`).
- **That screening list is real but not currently refreshed, and the code now says so.** The Marketplace provider's *current* screened-entities table is empty and its point-in-time table ends **2024-04-10**, so the effective screening list is a real US government historical snapshot rather than a live feed. This was found during the Refinement Phase, and it had a functional consequence worth stating plainly: because all three consumers queried the empty current table, **every sanctions screen was returning zero matches** and the sanctions-driven BLOCK branch was unreachable. They now read `V_SANCTIONS_SCREENING_SOURCE`, which prefers the provider's current table, falls back to the point-in-time snapshot, and returns a `data_basis` / `RECORD_BASIS` value so the freshness is reported instead of assumed. Verification SQL is in [`docs/COCO_CLI_EVIDENCE.md`](docs/COCO_CLI_EVIDENCE.md) §2.9.
- **Detection thresholds are calibrated to that distribution, not invented.** They are recomputed on every run from percentiles of the live data. Inspect the values actually used:
  ```sql
  CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT();   -- returns the thresholds it used
  ```
- **AI decision "ground truth" is rule-derived, not human-labelled.** `V_AI_DECISION_EVAL` measures whether the model faithfully applies the *written* rubric (policy adherence), which is the property that matters for an auditable compliance system. It does not claim to measure real-world fraud detection accuracy — that would require labelled fraud outcomes, which this synthetic dataset cannot provide.
- **AI cost figures are estimates; token counts are real.** Token usage comes from Cortex's own `usage` payload per call. Cost multiplies those tokens by a reference credit rate held in `AI_MODEL_RATE`. Authoritative billed consumption remains `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY`.
- **The triage queue is intentionally not empty.** Detection applies backpressure at a queue limit instead of draining to zero, so there is always live work for a reviewer to run the pipeline against. Roughly 83% of alerts raised so far have been AI-investigated; the remainder is the working queue.
- **Two rows are deliberate adversarial test fixtures, and they are named as such.** `TESTFIXTURE-SHELLCO-01/02` carry shell-company counterparty names so the `SUSPICIOUS_PARTY` detection rule and the name-based BLOCK branch of the rubric are actually exercised. They are labelled in `REMARKS` rather than disguised as organic shipments. A previous scripted helper that seeded such rows on demand (`DEMO_PIPELINE()`) has been dropped from the database.
- **Scheduled tasks ship suspended** to protect trial credits; the pipeline is triggered on demand. One `ALTER TASK ... RESUME` makes it fully hands-off.
- **Mendix contributes no business logic.** It authenticates as a least-privilege service user, calls one procedure, and renders the result. Every decision is made inside Snowflake.

---

## 8. Judging Criteria Mapping

See [`COMPLIANCE_CHECKLIST.md`](COMPLIANCE_CHECKLIST.md) for the full Terms & Conditions compliance audit, including:
- Section 9 Judging Criteria mapping (CoCo CLI, Python/Java, Snowflake platform, Marketplace/Streamlit)
- Entry Requirements checklist (Section 4)
- Entry Warranties compliance (Section 5)

For criterion 1 specifically (**use of Cortex Code CLI**), see [`docs/COCO_CLI_EVIDENCE.md`](docs/COCO_CLI_EVIDENCE.md) — it documents nine engineering sessions with the exact SQL a judge can re-run to verify each outcome, including the Refinement Phase session that found a silently dead third-party dependency.

---

## 9. Key Differentiators

1. **The AI actually decides, the decision is auditable, and the decision quality is measured** — `WORKFLOW_INVESTIGATE_ANOMALY` builds a quantitative evidence pack (cost-per-kg vs. the peer median across 10,000+ shipments, plus a sanctions-list match count queried from Marketplace data), applies an explicit BLOCK / ESCALATE / CLEAR rubric via Cortex AI, and **persists both the decision and its one-line reason** to `FRAUD_ALERT`. The orchestrator executes *that* decision — the action is not hardcoded. Measured outcome across **345 decisions** (as of 2026-08-17): `BLOCK 43 / ESCALATE 42 / CLEAR 260` — genuinely differentiated, not a uniform fallback. Verify with `CALL MENDIX_APP.AGENTS.EVALUATE_AI_DECISIONS();`
2. **Decision quality is measured, not asserted** — `V_AI_DECISION_EVAL` recomputes, in SQL, the decision the documented rubric mandates for the same evidence and compares it to what the model actually decided. Current result: **95.9% policy adherence with 0 critical false negatives** (nothing that should have been blocked was cleared) over the **341** decisions the evaluator can score. That is 4 fewer than the 345 above, and the reason is stated rather than hidden: the evaluator joins each alert back to its shipment row to recompute cost-per-kg, and 4 historical alerts point at shipment rows that were removed during a demo-data cleanup, so they have no evidence pack left to re-score. This measurement also captured a concrete engineering win: moving the numeric threshold comparison out of the prompt and into SQL raised adherence from **78.5% to 100%** on the decisions taken after the change, because language models are unreliable at threshold arithmetic while being good at contextual judgement.
3. **Calibrated detection instead of magic numbers** — thresholds are derived from the live data distribution (99th percentile of charges and weight, multiples of the peer median cost-per-kg). The previous hardcoded `> $50,000` rule matched only 15 of 10,025 shipments while a `> 30,000 kg` rule matched 24.5% of them; both are now percentile-based and graded by severity. Detection also applies **backpressure** — it stops creating alerts when the open triage queue is saturated rather than piling on work nobody can process.
4. **Autonomous multi-step reasoning** — Detect → Investigate (Cortex AI) → Screen (Marketplace-sourced screening data) → Remediate → ERP post, chained without human intervention, and **batched**: one call can work through many alerts (`CALL WORKFLOW_FULL_PIPELINE_V2('AUTO', 10)`), across both HIGH and MEDIUM severity so no tier is abandoned in the queue.
5. **CLI-native execution** — the exact same workflow runs identically via SQL CLI, CoCo CLI (natural language), and Python/Snowpark
6. **Real third-party data integration** — screening runs against a real US government export-screened-entities dataset obtained from Snowflake Marketplace (listing `GZTSZ290BV255`), not a mocked list. The data is genuinely third-party, but it is **not continuously refreshed**: the provider's current table is empty and its point-in-time table stops at 2024-04-10, so the screening list is a real historical government snapshot rather than a live feed. `V_SANCTIONS_SCREENING_SOURCE` reports which basis each match came from (`RECORD_BASIS`) and automatically prefers the provider's current table if it is ever repopulated — so the freshness of this dependency is visible instead of assumed.
7. **Full audit trail with explanations** — every step is logged to `WORKFLOW_AUDIT_LOG` with the AI decision and reason recorded inline, so a compliance reviewer can see *why* a shipment was blocked or cleared, not just that something happened
8. **Production-shaped**: defensive error handling (`LIMIT 1` on SELECT INTO, AI retry wrapper, graceful skip when no alert qualifies, sanctions-lookup fallback), built on a real Mendix front-end with JDBC integration
9. **Demo-ready analytics UI**: the Streamlit dashboard was browser-verified and includes a dedicated *Autonomous AI Decisions* panel exposing every decision, its reason, and the full model risk assessment

---

## 10. Demo-Ready Status (last re-validated 2026-08-17)

- Main Streamlit dashboard verified live in Snowflake after final UI/chart fixes
- KPI totals **at last validation (2026-08-17)**: approximately **10,017 shipments**, **$52.87M revenue**, **~1,195 pending**, **12 carriers**, **~1,740 approved**, **~2,882 in transit**. These are point-in-time figures from a live, autonomous system — status and charges change as the pipeline runs, so the dashboard may show different numbers by the time a judge looks. To see the current live values, run:
  ```sql
  -- note: STATUS values are mixed-case in the source data ('APPROVED' but 'In_Transit')
  SELECT COUNT(*) AS SHIPMENTS, SUM(TOTAL_CHARGES) AS REVENUE,
         COUNT(DISTINCT CARRIER_NAME) AS CARRIERS,
         SUM(CASE WHEN UPPER(STATUS)='PENDING_REVIEW' THEN 1 ELSE 0 END) AS PENDING,
         SUM(CASE WHEN UPPER(STATUS)='APPROVED' THEN 1 ELSE 0 END) AS APPROVED,
         SUM(CASE WHEN UPPER(STATUS)='IN_TRANSIT' THEN 1 ELSE 0 END) AS IN_TRANSIT
  FROM MENDIX_APP.AGENTS.BILL_OF_LADING;
  ```
- Carrier, route, status, and weekly trend charts were corrected to avoid Plotly rendering distortions in Streamlit-in-Snowflake
- Live Data & Pipeline section was cleaned up so FX rates, sanctions count (**2,394 entities**, re-verified 2026-08-17), AI usage, and pipeline context display correctly during the demo
- Write-capable controls were removed from Streamlit pages that run under Snowflake owner's-rights execution, so reviewer access cannot accidentally mutate shared config or shipment state through the UI
- `BL_SEARCH_SERVICE` (Cortex Search) is currently **live and serving** (`indexing_state = ACTIVE`), so semantic search works immediately with no manual resume step. Note that a *suspended* Cortex Search Service does **not** auto-resume on query — it raises `error_code 399131`; if it is ever suspended to save credits, resume it explicitly with `ALTER CORTEX SEARCH SERVICE MENDIX_APP.AGENTS.BL_SEARCH_SERVICE RESUME;`
- Full system validation report is captured in [`../docs/reference/TEST_REPORT_FINAL_2026-08-01.md`](../docs/reference/TEST_REPORT_FINAL_2026-08-01.md), including a **2026-08-17 re-validation** section confirming the pipeline still runs correctly after an extended idle period

---

## 11. Refinement Phase (2026-08-18)

After being shortlisted, 3 evaluator feedback items were addressed:

### Fix 1: File Ingestion & System Administrator Errors
- Root cause: `PROCESS_BL_DOCUMENTS` ran as `EXECUTE AS CALLER`, causing permission failures when called from the Mendix service user via JDBC
- Fix: Changed to `EXECUTE AS OWNER` with a per-file exception handler that logs errors to `ERROR_LOG` and continues processing remaining files, returning a JSON status summary instead of throwing
- Auto-sync merged: `SYNC_EXTRACTED_TO_BILL_OF_LADING()` is now called automatically at the end of `PROCESS_BL_DOCUMENTS`, eliminating the need for a separate sync step

### Fix 2: Merge External Sandbox Portal with Native Streamlit
- **Mendix removed as primary interface** — all functionality consolidated into Streamlit-in-Snowflake
- Added **PDF Upload** to Documents page: `st.file_uploader` → PUT to `@LOGISTICS_STAGE` → `CALL PROCESS_BL_DOCUMENTS()`
- Added **Ingest & Decide** button: triggers full `WORKFLOW_INGEST_AND_DECIDE()` from the UI
- Added **Extracted Documents Review** panel showing recent AI extraction results with confidence scores
- Pipeline can also be triggered from the AI Chat sidebar

### Fix 3: Redesigned Chat Interface with Session History Persistence
- Redesigned `6_AI_Chat.py` using native `st.chat_message` / `st.chat_input` components for proper conversational UX
- Chat history persists in `st.session_state.chat_messages` throughout the session
- Sidebar includes quick-question buttons and a "Run Full Pipeline" button
- Pipeline results are displayed inline in the chat conversation

### Infrastructure
- Migrated to new Snowflake trial account (`DPYXIQZ-FN71223`, expires 2026-09-04) with full schema, data, and all 46 procedures
- Generated new RSA key pair for `MENDIX_SERVICE_USER` key-pair JWT authentication
- Mendix integration code retained in `mendix-integration/` as reference only (not the active entry point)
