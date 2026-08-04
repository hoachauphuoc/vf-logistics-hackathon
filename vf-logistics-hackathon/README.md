# VF Logistics — Intelligent Workflow Automation Agent

**Snowflake CoCo CLI Hackathon submission** — an AI-driven agentic system that autonomously detects, investigates, screens, and remediates fraud/compliance risk in maritime logistics (Bill of Lading) shipments.

> Built end-to-end using **Cortex Code (CoCo) CLI** — every procedure, bug fix, and workflow in this repo was authored, debugged, and validated through CoCo CLI sessions. **Concrete, reproducible evidence: [`docs/COCO_CLI_EVIDENCE.md`](docs/COCO_CLI_EVIDENCE.md)**

---

## 0. Live Prototype (Public MVP)

**Publicly accessible Mendix prototype (MVP link):** https://vflogisticsportal-sandbox.mxapps.io/p/HomeWeb?profile=Responsive

> This is hosted on a Mendix Free App tier, which sleeps after a period of inactivity. If the link has not been opened in a while, it may show a **"Resuming app"** screen for roughly 30-60 seconds — wait for it, then refresh the page once to load the homepage.

This Mendix app is the operational UI that a compliance team would use to view shipments and investigation statuses (e.g., `Pending_Review` → `AI_Processed`).

Important notes for judges:
- The **public prototype entry point** is the Mendix sandbox because it has the lowest reviewer friction: no Snowflake login is required.
- The **autonomous workflow execution** (Fraud Detection → AI Investigation → Sanctions Screening → Remediation) is demonstrated in the submission video and is executed from **Cortex Code / SQL CLI** (see Section 4).
- The Mendix sandbox is intentionally the **operator UI prototype**, not the technical proof surface. Every detection, AI decision, audit log entry, and ERP post is made inside Snowflake.
- The **Snowflake Streamlit dashboard** is the analytics and monitoring surface used in the demo, with verified charts for carrier revenue, shipment status, weekly shipment volume, top routes, FX rates, sanctions counts, and AI usage.
- **Optional reviewer access**: a read-only Snowflake account can be provided for the Streamlit dashboard if a judge wants to inspect the backend UI directly, but it is not required to evaluate the submission and should be treated as bonus access rather than the primary prototype link.

## 1. Problem & Business Impact

Maritime freight fraud (undervalued/overvalued cargo, shell-company shippers, sanctioned entities) costs the logistics industry **$40B+ annually**. Manual review of every Bill of Lading is too slow to scale. VF Logistics needs a system that:

- Continuously scans incoming shipments for anomalies
- Reasons over context (not just static rules) to assess real risk
- Screens counterparties against live government sanctions data
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

**Snowflake features used**: Cortex Agent, Cortex AI (`COMPLETE` — mistral-large2), Cortex Analyst (text-to-SQL), Cortex Search (semantic BL search), Snowflake Marketplace (live sanctions data + FX rates), Dynamic Tables, Streams + Tasks, Streamlit.

**Languages used**: SQL (core workflow logic), **Python** (Snowpark risk scoring + Streamlit dashboard), **Java** (Mendix front-end integration).

---

## 3. The 3 Agent Skills

| Skill | File | Purpose |
|-------|------|---------|
| 1. Fraud Detection & Scoring | [`skills/skill_1_fraud_detection.md`](skills/skill_1_fraud_detection.md) | Scans shipments against 3 anomaly rules (value, weight, suspicious party) |
| 2. Compliance & Sanctions Screening | [`skills/skill_2_compliance_sanctions.md`](skills/skill_2_compliance_sanctions.md) | Rule-based compliance scoring + live Marketplace sanctions screening |
| 3. AI Investigation & Remediation | [`skills/skill_3_ai_investigation.md`](skills/skill_3_ai_investigation.md) | Cortex AI risk analysis + autonomous BLOCK/ESCALATE/CLEAR decision |

---

## 4. Run the Workflow — Executed Through the CLI

### Option A — Document to decision, from raw PDFs (the full story, one command)

Upload as many Bills of Lading as you like in a single command, then take them all the way to an autonomous decision with one more:

```bash
snow sql -q "PUT file://bl_pdfs/*.pdf @MENDIX_APP.AGENTS.LOGISTICS_STAGE/bill_of_lading AUTO_COMPRESS=FALSE OVERWRITE=TRUE;" --connection ayugbce-jx50275
snow sql -q "CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE();" --connection ayugbce-jx50275
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
snow sql -q "CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');" --connection ayugbce-jx50275
```

One alert per call keeps the demo fast. To work down a backlog instead, pass a batch size — the orchestrator loops through that many open HIGH-severity alerts in a single invocation, logging every step of every alert:
```sql
CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO', 10);   -- process up to 10 alerts
```

### Option C — Full demo script (seed data + run + show audit trail)
```bash
snow sql -f sql/workflows/run_full_workflow_demo.sql --connection ayugbce-jx50275
```

The home-dashboard "Run Pipeline" demo shortcut was deliberately removed from the Streamlit UI because it called a scripted `DEMO_PIPELINE()` helper rather than the real orchestrator, and that helper procedure has since been **dropped from the database entirely** — there is no scripted demo path left in this account. The only pipeline button in the UI runs the real backend flow.

### Option D — Natural language via Cortex Agent (CoCo CLI / Snowflake Intelligence)
> "Scan for fraud and handle any issues autonomously"

### Option E — From Python/Snowpark
```bash
python python/snowpark_risk_scoring.py --connection ayugbce-jx50275 --run-workflow
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

- **Mendix integration**: `CallCortexAgent.java` reads the Snowflake service-account password from the `SNOWFLAKE_MENDIX_PASSWORD` environment variable (never hardcoded — see `COMPLIANCE_CHECKLIST.md` Section 5 for rationale).
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

For criterion 1 specifically (**use of Cortex Code CLI**), see [`docs/COCO_CLI_EVIDENCE.md`](docs/COCO_CLI_EVIDENCE.md) — it documents eight engineering sessions with the exact SQL a judge can re-run to verify each outcome.

---

## 9. Key Differentiators

1. **The AI actually decides, the decision is auditable, and the decision quality is measured** — `WORKFLOW_INVESTIGATE_ANOMALY` builds a quantitative evidence pack (cost-per-kg vs. the peer median across 10,000+ shipments, plus a live sanctions-list match count from Marketplace data), applies an explicit BLOCK / ESCALATE / CLEAR rubric via Cortex AI, and **persists both the decision and its one-line reason** to `FRAUD_ALERT`. The orchestrator executes *that* decision — the action is not hardcoded. Measured outcome across **336 decisions**: `BLOCK 42 / ESCALATE 42 / CLEAR 256` — genuinely differentiated, not a uniform fallback. Verify with `CALL MENDIX_APP.AGENTS.EVALUATE_AI_DECISIONS();`
2. **Decision quality is measured, not asserted** — `V_AI_DECISION_EVAL` recomputes, in SQL, the decision the documented rubric mandates for the same evidence and compares it to what the model actually decided. Current result: **95.8% policy adherence with 0 critical false negatives** (nothing that should have been blocked was cleared). This also captured a measurable engineering win: moving the numeric threshold comparison out of the prompt and into SQL raised adherence from **78.5% to 100%** on the decisions taken after the change, because language models are unreliable at threshold arithmetic while being good at contextual judgement.
3. **Calibrated detection instead of magic numbers** — thresholds are derived from the live data distribution (99th percentile of charges and weight, multiples of the peer median cost-per-kg). The previous hardcoded `> $50,000` rule matched only 15 of 10,025 shipments while a `> 30,000 kg` rule matched 24.5% of them; both are now percentile-based and graded by severity. Detection also applies **backpressure** — it stops creating alerts when the open triage queue is saturated rather than piling on work nobody can process.
4. **Autonomous multi-step reasoning** — Detect → Investigate (Cortex AI) → Screen (live Marketplace data) → Remediate → ERP post, chained without human intervention, and **batched**: one call can work through many alerts (`CALL WORKFLOW_FULL_PIPELINE_V2('AUTO', 10)`), across both HIGH and MEDIUM severity so no tier is abandoned in the queue.
5. **CLI-native execution** — the exact same workflow runs identically via SQL CLI, CoCo CLI (natural language), and Python/Snowpark
6. **Real third-party data integration** — sanctions screening against a live Snowflake Marketplace dataset, not a mocked list
5. **Full audit trail with explanations** — every step is logged to `WORKFLOW_AUDIT_LOG` with the AI decision and reason recorded inline, so a compliance reviewer can see *why* a shipment was blocked or cleared, not just that something happened
6. **Production-shaped**: defensive error handling (`LIMIT 1` on SELECT INTO, AI retry wrapper, graceful skip when no alert qualifies, sanctions-lookup fallback), built on a real Mendix front-end with JDBC integration
7. **Demo-ready analytics UI**: the Streamlit dashboard was browser-verified and includes a dedicated *Autonomous AI Decisions* panel exposing every decision, its reason, and the full model risk assessment

---

## 10. Demo-Ready Status (2026-07-27)

- Main Streamlit dashboard verified live in Snowflake after final UI/chart fixes
- KPI totals **at last validation (2026-08-02)**: approximately **10,017 shipments**, **$52.9M revenue**, **~1,197 pending**, **12 carriers**, **~1,740 approved**, **~2,884 in transit**. These are point-in-time figures from a live, autonomous system — status and charges change as the pipeline runs, so the dashboard may show different numbers by the time a judge looks. To see the current live values, run:
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
- Live Data & Pipeline section was cleaned up so FX rates, sanctions count (**2,394 entities**), AI usage, and pipeline context display correctly during the demo
- Write-capable controls were removed from Streamlit pages that run under Snowflake owner's-rights execution, so reviewer access cannot accidentally mutate shared config or shipment state through the UI
- Full system validation report is captured in [`../docs/reference/TEST_REPORT_FINAL_2026-08-01.md`](../docs/reference/TEST_REPORT_FINAL_2026-08-01.md)
