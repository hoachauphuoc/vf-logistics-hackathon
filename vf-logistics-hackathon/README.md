# VF Logistics — Intelligent Workflow Automation Agent

**Snowflake CoCo CLI Hackathon submission** — an AI-driven agentic system that autonomously detects, investigates, screens, and remediates fraud/compliance risk in maritime logistics (Bill of Lading) shipments.

> Built end-to-end using **Cortex Code (CoCo) CLI** — every procedure, bug fix, and workflow in this repo was authored, debugged, and validated through CoCo CLI sessions. **Concrete, reproducible evidence: [`docs/COCO_CLI_EVIDENCE.md`](docs/COCO_CLI_EVIDENCE.md)**

---

## 0. Live Prototype (Public MVP)

**Publicly accessible Mendix prototype (MVP link):** https://vflogisticsportal-sandbox.mxapps.io/p/HomeWeb?profile=Responsive

This Mendix app is the operational UI that a compliance team would use to view shipments and investigation statuses (e.g., `Pending_Review` → `AI_Processed`).

Important notes for judges:
- The **autonomous workflow execution** (Fraud Detection → AI Investigation → Sanctions Screening → Remediation) is demonstrated in the submission video and can be triggered via CLI (see Section 4).
- The Mendix sandbox is intended as a **public UI prototype**; interactive workflow execution typically requires authenticated Snowflake access.
- The **Snowflake Streamlit dashboard** is the analytics and monitoring surface used in the demo, with verified charts for carrier revenue, shipment status, weekly shipment volume, top routes, FX rates, sanctions counts, and AI usage.

## 1. Problem & Business Impact

Maritime freight fraud (undervalued/overvalued cargo, shell-company shippers, sanctioned entities) costs the logistics industry **$40B+ annually**. Manual review of every Bill of Lading is too slow to scale. VF Logistics needs a system that:

- Continuously scans incoming shipments for anomalies
- Reasons over context (not just static rules) to assess real risk
- Screens counterparties against live government sanctions data
- Takes autonomous action (block/escalate/clear) — with full audit trail for compliance

**Measurable impact**: full detect → investigate → screen → remediate cycle completes in **~6-10 seconds** per shipment (see live execution time in `WORKFLOW_AUDIT_LOG`), vs. hours/days for manual compliance review. The current demo dataset includes **10,009 shipments** and **53M+ USD** in represented cargo charges.

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

### Option A — Single command (fastest live demo)
```bash
snow sql -q "CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');" --connection ygvordh-ia82097
```

### Option B — Full demo script (seed data + run + show audit trail)
```bash
snow sql -f sql/workflows/run_full_workflow_demo.sql --connection ygvordh-ia82097
```

### Option C — Natural language via Cortex Agent (CoCo CLI / Snowflake Intelligence)
> "Scan for fraud and handle any issues autonomously"

### Option D — From Python/Snowpark
```bash
python python/snowpark_risk_scoring.py --connection ygvordh-ia82097 --run-workflow
```

**Expected output** (~6-15s execution):
```json
{"workflow":"FULL_PIPELINE_V2","status":"COMPLETED","steps":5,
 "alert_id":310,"ai_decision":"BLOCK",
 "ai_reason":"Shipper and consignee names indicate shell/front companies, and cost per kg exceeds peer median by over 3x.",
 "shipper_screened":"SUSPICIOUS TRADING CO",
 "execution_time_ms":13392,"audit_trail":"WORKFLOW_AUDIT_LOG"}
```

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
├── VOICEOVER_SCRIPT_4MIN.md        Final 4-minute narration script
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
└── ../TEST_REPORT_SOLUTION.md      End-to-end validation report (2026-07-27)
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
| BILL_OF_LADING (10,009 rows) | Self-generated synthetic data | N/A |
| Export-restricted entities list | Snowflake Marketplace — "Snowflake Public Data (Free)" (listing `GZTSZ290BV255`) | Free, Snowflake-provided |
| FX exchange rates (`V_EXCHANGE_RATES`) | Snowflake Marketplace-backed reference data in account | Snowflake-provided |
| HS_CODE_REFERENCE | Self-generated (based on public HS Code standard) | Public reference |

---

## 8. Judging Criteria Mapping

See [`COMPLIANCE_CHECKLIST.md`](COMPLIANCE_CHECKLIST.md) for the full Terms & Conditions compliance audit, including:
- Section 9 Judging Criteria mapping (CoCo CLI, Python/Java, Snowflake platform, Marketplace/Streamlit)
- Entry Requirements checklist (Section 4)
- Entry Warranties compliance (Section 5)

For criterion 1 specifically (**use of Cortex Code CLI**), see [`docs/COCO_CLI_EVIDENCE.md`](docs/COCO_CLI_EVIDENCE.md) — it documents six engineering sessions with the exact SQL a judge can re-run to verify each outcome.

---

## 9. Key Differentiators

1. **The AI actually decides, and the decision is auditable** — `WORKFLOW_INVESTIGATE_ANOMALY` builds a quantitative evidence pack (shipment cost-per-kg vs. the peer median and 95th percentile across 10,000+ shipments, plus a live sanctions-list match count from Marketplace data), applies an explicit BLOCK / ESCALATE / CLEAR rubric via Cortex AI, and **persists both the decision and its one-line reason** to `FRAUD_ALERT`. The orchestrator then executes *that* decision — the action is not hardcoded. Observed behaviour on the demo dataset: a shell-company shipment at 3x the peer median cost-per-kg was **BLOCKED**, while six flagged shipments from recognisable manufacturers with normal economics and clean screening were **CLEARED** — demonstrating differentiated reasoning rather than a uniform fallback.
2. **Autonomous multi-step reasoning** — Detect → Investigate (Cortex AI) → Screen (live Marketplace data) → Remediate, chained without human intervention
3. **CLI-native execution** — the exact same workflow runs identically via SQL CLI, CoCo CLI (natural language), and Python/Snowpark
4. **Real third-party data integration** — sanctions screening against a live Snowflake Marketplace dataset, not a mocked list
5. **Full audit trail with explanations** — every step is logged to `WORKFLOW_AUDIT_LOG` with the AI decision and reason recorded inline, so a compliance reviewer can see *why* a shipment was blocked or cleared, not just that something happened
6. **Production-shaped**: defensive error handling (`LIMIT 1` on SELECT INTO, AI retry wrapper, graceful skip when no alert qualifies, sanctions-lookup fallback), built on a real Mendix front-end with JDBC integration
7. **Demo-ready analytics UI**: the Streamlit dashboard was browser-verified and includes a dedicated *Autonomous AI Decisions* panel exposing every decision, its reason, and the full model risk assessment

---

## 10. Demo-Ready Status (2026-07-27)

- Main Streamlit dashboard verified live in Snowflake after final UI/chart fixes
- KPI totals confirmed: **10,009 shipments**, **$53,042,546 revenue**, **1,200 pending**, **10 carriers**, **1,809 approved**, **3,000 in transit**
- Carrier, route, status, and weekly trend charts were corrected to avoid Plotly rendering distortions in Streamlit-in-Snowflake
- Live Data & Pipeline section was cleaned up so FX rates, sanctions count (**2,394 entities**), AI usage, and pipeline controls display correctly during the demo
- Full system validation report is captured in `../TEST_REPORT_SOLUTION.md`
