# VF Logistics — Intelligent Workflow Automation Agent

**Snowflake CoCo CLI Hackathon submission** — an AI-driven agentic system that autonomously detects, investigates, screens, and remediates fraud/compliance risk in maritime logistics (Bill of Lading) shipments.

> Built end-to-end using **Cortex Code (CoCo) CLI** — every procedure, bug fix, and workflow in this repo was authored, debugged, and validated through CoCo CLI sessions. **Concrete, reproducible evidence: [`docs/COCO_CLI_EVIDENCE.md`](docs/COCO_CLI_EVIDENCE.md)**

---

## 0. Live Prototype — Snowflake Streamlit (Unified Interface)

**Primary interface:** Snowflake Streamlit-in-Snowflake application `VF_LOGISTICS_DASHBOARD`

> The entire application runs natively inside Snowflake — no external dependencies. The Streamlit app is the **single unified interface** for document upload, AI processing, fraud detection, compliance monitoring, and conversational AI chat.

**Key capabilities (all inside Streamlit):**
- **AI Document Processing** — One-click `Process New PDFs on Stage` triggers Cortex AI field extraction, validation, and promotion to the operational table (PDFs are staged via Snowsight — see *Known Limitations*)
- **Human-in-the-loop Review & Edit** — Select any extracted document to inspect AI output side-by-side with editable fields (container, vessel, arrival date, gross weight), then Approve / Reject / Sync to SAP. Edits are persisted through `REVIEW_DOCUMENT` with a full audit trail
- **AI Chat with Session Persistence** — Natural language queries over logistics data, with conversation history maintained throughout the session
- **Autonomous Pipeline Execution** — Run the full detect → investigate → screen → remediate → SAP post workflow from the UI
- **Real-time Analytics** — Carrier revenue, shipment status, weekly trends, FX rates, sanctions screening, AI usage/cost monitoring

Important notes for judges:
- The **entry point** is the Streamlit dashboard running inside Snowflake (account `DPYXIQZ-FN71223`)
- The **autonomous workflow execution** (Fraud Detection → AI Investigation → Sanctions Screening → Remediation) can be triggered from the Fraud Detection page or the AI Chat sidebar
- Every detection, AI decision, audit log entry, and ERP post is made inside Snowflake — no external runtime

### Reviewer access

Unlike the removed Mendix sandbox, a Streamlit-in-Snowflake app requires a Snowflake login — there is no anonymous public URL. A dedicated evaluator account is provisioned:

| Field | Value |
|---|---|
| Login URL | https://app.snowflake.com |
| Account | `DPYXIQZ-FN71223` |
| User | `HACKATHON_JUDGE` |
| Password | `SnowHack2026!` |
| Role | `HACKATHON_JUDGE_ROLE` (applied automatically) |
| App | Projects → Streamlit → **VF Logistics Dashboard** |

Direct app link (after login): `https://app.snowflake.com/dpyxiqz-fn71223/#/streamlit-apps/MENDIX_APP.AGENTS.VF_LOGISTICS_DASHBOARD`

This account was **verified under true least privilege** on 2026-08-18 (`USE SECONDARY ROLES NONE`, so no ACCOUNTADMIN privileges could leak into the test): it can read all 32 tables and 11 views it is granted, call `CORTEX.COMPLETE`, run `REVIEW_DOCUMENT` and `GET_PDF_URL`, execute the full pipeline, save and reload chat conversations, and write chat cost telemetry to `AI_CALL_LOG`. It is correctly **denied** direct access to `CHAT_MESSAGE`, reaching it only through owner-rights procedures. All workflow procedures are `EXECUTE AS OWNER`, so the evaluator can exercise the whole system while holding only read privileges on the underlying tables.

> **Note on Mendix**: The original submission used a Mendix sandbox as the operator UI. Per evaluator feedback ("Merge External Sandbox Portal with Native Streamlit Application"), Mendix has been **removed from the architecture** — it is not deployed and is not required to run the solution. Every operator function it provided (document processing, field editing, approve/reject, SAP sync, chat) now lives in the Streamlit app. The `mendix-integration/` folder is retained purely as reference for the JDBC key-pair auth pattern. See *Known Limitations* in Section 11 for the two UX trade-offs this consolidation introduced.

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
  ENTRY POINTS (all inside Snowflake — no external runtime)
  ┌────────────────────────────────────────────────────────────┐
  │ Streamlit-in-Snowflake   VF_LOGISTICS_DASHBOARD            │
  │  Dashboard │ Documents (review/edit/approve) │ Compliance  │
  │  Fraud Detection │ AI FinOps │ AI Chat (session history)   │
  └────────────────────────────────────────────────────────────┘
    CoCo CLI / Natural Language │ Direct SQL │ Python/Snowpark
                                      │
                                      ▼
                      ┌──────────────────────────────┐
                      │   Cortex Agent               │
                      │   VF_LOGISTICS_AGENT         │
                      │   (5 tools: query, search,   │
                      │   fraud_scan, investigate,   │
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

**Languages used**: SQL (core workflow logic), **Python** (Snowpark risk scoring + Streamlit-in-Snowflake app — the sole user interface), **Java** (`mendix-integration/`, reference only — not deployed, not required to run the solution).

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

The **Streamlit UI (Documents page and AI Chat sidebar), the Cortex Agent, and Python/Snowpark all call this same procedure**, so every interface executes identical logic.

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

### Option F — From the Streamlit UI itself (no CLI access needed)

A judge with only Snowsight access can trigger the exact same workflow with no CLI: open the `VF_LOGISTICS_DASHBOARD` Streamlit app and use either the **Documents** page (**Ingest & Decide** runs `WORKFLOW_INGEST_AND_DECIDE()`), the **Fraud Detection** page (runs `WORKFLOW_FULL_PIPELINE_V2('AUTO')`), or the **AI Chat** sidebar (**Run Full Pipeline**). All three call the identical orchestrator as Option B and write to the same `WORKFLOW_AUDIT_LOG` — the UI is one more caller of the backend, not a separate code path. The AI Chat page additionally accepts free-form questions and answers them by generating and executing SQL against the same tables.

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
│   │   ├── document_to_decision.sql      Ingest → extract → decide chain
│   │   ├── hardened_objects.sql          Hardened tables/views, exported from GET_DDL
│   │   ├── chat_persistence.sql          Chat history tables + 6 owner-rights procedures
│   │   ├── document_data_integrity.sql   Deterministic BL validation + integrity assertions
│   │   └── run_full_workflow_demo.sql    CLI demo script
│   └── monitoring/
│       └── CREDIT_MONITORING_GUIDE.md
├── python/
│   └── snowpark_risk_scoring.py    Python/Snowpark risk scoring + orchestration
├── mendix-integration/              Reference only — not deployed
│   └── CallCortexAgent.java        Historical Mendix Java action (JDBC → Snowflake)
├── ../streamlit_app/                ** The application (deployed to SiS) **
│   ├── app.py                      Main dashboard (KPIs, carrier revenue, trends, FX)
│   ├── environment.yml             Declares the plotly dependency for SiS
│   ├── i18n.py                     EN / VN / JA translations
│   ├── ui.py                       Shared theme, table/chart helpers, NULL rendering
│   └── pages/
│       ├── 1_Documents.py          AI processing + human-in-the-loop review & edit
│       ├── 2_Compliance.py         Compliance checks
│       ├── 3_Fraud_Detection.py    Alerts + pipeline execution
│       ├── 4_AI_FinOps.py          AI usage & cost monitoring
│       ├── 5_Settings.py           Language / model settings
│       └── 6_AI_Chat.py            Conversational AI with session history
└── ../docs/reference/
    ├── TEST_REPORT_FINAL_2026-08-01.md   Final end-to-end validation (current)
    └── TEST_REPORT_SOLUTION.md          Earlier validation run (2026-07-27, superseded)
```

---

## 6. Setup / Deployment Notes

- **Streamlit deployment**: the app is deployed as `MENDIX_APP.AGENTS.VF_LOGISTICS_DASHBOARD` from `@MENDIX_APP.AGENTS.STREAMLIT_STAGE`. `environment.yml` must sit in the **stage root** (not in `pages/`) for SiS to install `plotly`; if it is missing the dashboard fails with `ModuleNotFoundError: No module named 'plotly'`. Redeploy after changing it so the environment is rebuilt.
- **Mendix integration (reference only)**: `CallCortexAgent.java` authenticates to Snowflake with **key-pair (JWT) authentication** — `authenticator=SNOWFLAKE_JWT` plus a private key file (`snowflake_key.p8`) read from the Mendix runtime resources directory at request time. No password or key material is present in the source or in this repository (`*.p8` and `*.pem` are git-ignored); only the public key is registered on the Snowflake service user. This code is **not deployed and not needed to run the solution** — it is kept because the key-pair auth pattern is reusable for any external caller. This replaced an earlier password-based approach — see `COMPLIANCE_CHECKLIST.md` Section 5 for that history.
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
- **The seven pages now share one UI layer (`ui.py`) instead of each styling itself.** Only the home page had the gradient header and styled metric cards; the five sub-pages used a plain `st.title`, so the app looked like a product on one screen and like raw SQL output on the next. `ui.py` now owns the theme, the header, table rendering, and chart layout, so a change lands on every page at once. Four concrete correctness fixes came out of the same pass, each verified against the code rather than inferred from a screenshot:
  - **Missing values no longer read as data.** Streamlit prints a Python `None` as the literal text `None`, which in a shipping table looks like an extracted value. Every read-only table now goes through `ui.display_df`, which renders absence as an em dash. It deliberately does **not** substitute `0` — a NULL token count means "not recorded", and printing `0` would assert something the data does not say — and it only converts columns that actually contain a missing value, so fully-populated numeric columns keep their dtype, alignment and thousands separators.
  - **`DATE_OF_ISSUE` was labelled "Arrival date"** on the Documents page. Those are different milestones. The label is corrected; the correction JSON key stays `arrival_date` because that is the key `REVIEW_DOCUMENT` actually parses, and this is now commented in place so it is not "tidied up" into a silent breakage.
  - **A dead control was removed.** The Review panel had a `Status` radio whose value was never passed to `REVIEW_DOCUMENT`, so it did nothing — while implying a reviewer could hand-set a flagged document to `Synced_To_SAP`. Status is now a read-only field that states it is derived from validation state.
  - **Sample-scoped metrics are labelled as such.** The Fraud page showed BLOCK/ESCALATE/CLEAR counts computed over a `LIMIT 50` query directly beneath all-time KPIs, which reads as a contradiction. The scope is now stated under the metrics.
- **A privacy leak introduced by this project's own chat-history feature was found and closed.** `HACKATHON_JUDGE_ROLE` is intentionally granted `SELECT` on `CHAT_SESSION` but **not** on `CHAT_MESSAGE`, so one user cannot read another's conversation text. Adding the `TITLE` column broke that boundary without anyone touching the grants: `TITLE` is auto-derived from the first user message, so the FinOps "Chat Sessions" panel was exposing the opening line of every user's conversation through a table the judge can legitimately read. That panel is now scoped with `WHERE USER_ID = CURRENT_USER()`. A Streamlit-in-Snowflake app runs with the owner's privileges but `CURRENT_USER()` remains the viewer, so this scopes rows per viewer without needing a procedure. The same panel also had a real aggregation bug: it ran `COUNT(*) ... GROUP BY SESSION_ID` against `CHAT_SESSION`, which holds exactly one row per session, so the message count was structurally always `1` regardless of conversation length. It now reads `MESSAGE_COUNT`, the counter `CHAT_MESSAGE_SAVE` maintains — which is also the only option that does not require a `CHAT_MESSAGE` grant.
- **Document validation is deterministic SQL, not a generative decision — and it was not always.** During the Refinement Phase the extracted-documents table was audited and found to contain self-contradicting rows. `PROCESS_BL_DOCUMENTS` computed `CONFIDENCE_SCORE` from four deterministic field checks but produced `ALERT` from a **second, independent** `CORTEX.COMPLETE` call asked to apply the same four rules in prose. Two separate judges of identical facts eventually disagreed, and they did: `DOC 402` carried `ALERT = 'ContainerNumber; VesselName; GrossWeightKg'` while simultaneously carrying `CONFIDENCE_SCORE = 100` and `STATUS = 'Synced_To_SAP'` — a document whose container number was the placeholder `XXXX0000000` was presented to reviewers as perfectly extracted and already posted to SAP. Worse, the LLM's verdict was itself wrong: two of its three flags were hallucinated (`MAERSK SENTOSA` and `24500 kg` are both valid) while the real defect — an Evergreen bill of lading on a Maersk vessel — went unreported. The rules are now a single deterministic function, `BL_DOC_ALERT`, and the confidence score is *derived from it*, so the score and the alert are mathematically incapable of disagreeing. Cortex still writes `ALERT_RESPONSE`, the human-readable explanation, but it is told the authoritative verdict and instructed not to re-decide it. **A generative call may narrate a validation outcome; it must not determine one.** Two further defects were fixed in the same pass: five rows claimed `Synced_To_SAP` with no `SAP_FI_DOCUMENT` behind them (`STATUS` is now derived from whether that row actually exists, and one document was genuinely posted rather than relabelled — no financial amounts were invented for the rest), and three rows stored a tonnes value in the kilogram column (`24.5` where peers held `24500`), which the old rule accepted because it only rejected `<= 0`. Reproducible in [`sql/workflows/document_data_integrity.sql`](sql/workflows/document_data_integrity.sql), which ends in five assertions that must each return zero rows.
- **Two rows are deliberate adversarial test fixtures, and they are named as such.** `TESTFIXTURE-SHELLCO-01/02` carry shell-company counterparty names so the `SUSPICIOUS_PARTY` detection rule and the name-based BLOCK branch of the rubric are actually exercised. They are labelled in `REMARKS` rather than disguised as organic shipments. A previous scripted helper that seeded such rows on demand (`DEMO_PIPELINE()`) has been dropped from the database.
- **The bad-data PDFs are intentional fixtures too.** Files named `*_ERROR.pdf` (`XXXX0000000` container numbers, `MSK@#$%789`, zero weights) exist so the extraction-confidence and anomaly paths are genuinely exercised rather than demonstrated on clean input. They are correctly scored below 100 and held in `Pending_Review`; they are the validation working, not defects. `BL_COSCO_COSU2026013_ERROR.pdf` is the one exception worth naming — every extracted field on it passes all six rules, so it scores 100. Its filename promises an error that the extracted data does not contain.
- **Scheduled tasks ship suspended** to protect trial credits; the pipeline is triggered on demand. One `ALTER TASK ... RESUME` makes it fully hands-off.
- **The UI contributes no business logic.** The Streamlit app calls procedures and renders results; every decision is made inside Snowflake. This was equally true of the removed Mendix portal, which is why consolidating into Streamlit changed no backend behaviour.

---

## 8. Judging Criteria Mapping

See [`COMPLIANCE_CHECKLIST.md`](COMPLIANCE_CHECKLIST.md) for the full Terms & Conditions compliance audit, including:
- Section 9 Judging Criteria mapping (CoCo CLI, Python/Java, Snowflake platform, Marketplace/Streamlit)
- Entry Requirements checklist (Section 4)
- Entry Warranties compliance (Section 5)

For criterion 1 specifically (**use of Cortex Code CLI**), see [`docs/COCO_CLI_EVIDENCE.md`](docs/COCO_CLI_EVIDENCE.md) — it documents nine engineering sessions with the exact SQL a judge can re-run to verify each outcome, including the Refinement Phase session that found a silently dead third-party dependency.

---

## 9. Key Differentiators

1. **The AI actually decides, the decision is auditable, and the decision quality is measured** — `WORKFLOW_INVESTIGATE_ANOMALY` builds a quantitative evidence pack (cost-per-kg vs. the peer median across 10,000+ shipments, plus a sanctions-list match count queried from Marketplace data), applies an explicit BLOCK / ESCALATE / CLEAR rubric via Cortex AI, and **persists both the decision and its one-line reason** to `FRAUD_ALERT`. The orchestrator executes *that* decision — the action is not hardcoded. Measured outcome across **348 decisions** (as of 2026-08-18): `BLOCK 43 / ESCALATE 42 / CLEAR 263` — genuinely differentiated, not a uniform fallback. Verify with `CALL MENDIX_APP.AGENTS.EVALUATE_AI_DECISIONS();`
2. **Decision quality is measured, not asserted** — `V_AI_DECISION_EVAL` recomputes, in SQL, the decision the documented rubric mandates for the same evidence and compares it to what the model actually decided. Current result: **95.9% policy adherence with 0 critical false negatives** (nothing that should have been blocked was cleared) over the **341** decisions the evaluator can score. That is 4 fewer than the 345 above, and the reason is stated rather than hidden: the evaluator joins each alert back to its shipment row to recompute cost-per-kg, and 4 historical alerts point at shipment rows that were removed during a demo-data cleanup, so they have no evidence pack left to re-score. This measurement also captured a concrete engineering win: moving the numeric threshold comparison out of the prompt and into SQL raised adherence from **78.5% to 100%** on the decisions taken after the change, because language models are unreliable at threshold arithmetic while being good at contextual judgement.
3. **Calibrated detection instead of magic numbers** — thresholds are derived from the live data distribution (99th percentile of charges and weight, multiples of the peer median cost-per-kg). The previous hardcoded `> $50,000` rule matched only 15 of 10,025 shipments while a `> 30,000 kg` rule matched 24.5% of them; both are now percentile-based and graded by severity. Detection also applies **backpressure** — it stops creating alerts when the open triage queue is saturated rather than piling on work nobody can process.
4. **Autonomous multi-step reasoning** — Detect → Investigate (Cortex AI) → Screen (Marketplace-sourced screening data) → Remediate → ERP post, chained without human intervention, and **batched**: one call can work through many alerts (`CALL WORKFLOW_FULL_PIPELINE_V2('AUTO', 10)`), across both HIGH and MEDIUM severity so no tier is abandoned in the queue.
5. **CLI-native execution** — the exact same workflow runs identically via SQL CLI, CoCo CLI (natural language), and Python/Snowpark
6. **Real third-party data integration** — screening runs against a real US government export-screened-entities dataset obtained from Snowflake Marketplace (listing `GZTSZ290BV255`), not a mocked list. The data is genuinely third-party, but it is **not continuously refreshed**: the provider's current table is empty and its point-in-time table stops at 2024-04-10, so the screening list is a real historical government snapshot rather than a live feed. `V_SANCTIONS_SCREENING_SOURCE` reports which basis each match came from (`RECORD_BASIS`) and automatically prefers the provider's current table if it is ever repopulated — so the freshness of this dependency is visible instead of assumed.
7. **Full audit trail with explanations** — every step is logged to `WORKFLOW_AUDIT_LOG` with the AI decision and reason recorded inline, so a compliance reviewer can see *why* a shipment was blocked or cleared, not just that something happened
8. **Production-shaped**: defensive error handling (`LIMIT 1` on SELECT INTO, AI retry wrapper, graceful skip when no alert qualifies, sanctions-lookup fallback), surfaced through a native Streamlit-in-Snowflake front-end with human-in-the-loop review and approval
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
- **Mendix removed as the interface** — all operator functionality consolidated into Streamlit-in-Snowflake
- Added **Process New PDFs on Stage** button: `CALL PROCESS_BL_DOCUMENTS()` runs Cortex extraction + auto-sync from the UI
- Added **Ingest & Decide** button: triggers full `WORKFLOW_INGEST_AND_DECIDE()` from the UI
- Added a **Review & Edit panel** that replicates the former Mendix edit screen: two-column layout with AI-extracted document details on the left and editable fields (container number, vessel name, arrival date, gross weight) on the right, plus AI-confidence display, anomaly alert, and **Approve / Reject / Sync to SAP** actions wired to `REVIEW_DOCUMENT` and `SAP_POST_FI_DOCUMENT`
- Corrections are diffed against the AI output, so pressing Approve after editing automatically submits a `CORRECT` action carrying only the changed fields
- Pipeline can also be triggered from the AI Chat sidebar

### Fix 3: Redesigned Chat Interface with Session History Persistence
- Rebuilt `6_AI_Chat.py` as a true conversational interface: full transcript re-rendered on every turn, with user and assistant turns visually distinguished by avatar badge, name, timestamp, response latency, and result row count
- **Conversations are persisted in Snowflake**, not just in memory: every turn is written to `CHAT_MESSAGE` and indexed by `CHAT_SESSION`, so a transcript survives a page reload, a browser restart, and an app restart
- Sidebar **Conversations** panel with `➕ New chat` and a **History** list of the last 20 conversations; clicking one reloads its full transcript, including the result tables, which are restored from a stored JSON snapshot rather than by re-running the SQL (so no extra warehouse cost and no risk of showing different rows than were originally returned)
- Conversations are **scoped per user** via `CURRENT_USER()` and guarded inside the procedures — one evaluator cannot read, append to, or delete another's conversations. Verified by test.
- All persistence flows through six `EXECUTE AS OWNER` procedures (`CHAT_SESSION_NEW`, `CHAT_MESSAGE_SAVE`, `CHAT_SESSION_LIST`, `CHAT_SESSION_LOAD`, `CHAT_SESSION_DELETE`, `CHAT_SESSION_RENAME`), so a read-only evaluator role needs **no INSERT grant** and no direct access to the chat tables
- Persistence degrades safely: if any chat-history call fails, the tab falls back to in-memory conversation and shows a one-line notice instead of erroring
- Conversation titles are derived automatically from the first question asked
- Intent classification routes each message either to a conversational answer or to generated SQL executed against the warehouse
- Generated SQL is restricted to an allowlist of 14 read-only tables and views, single-statement `SELECT`/`WITH` only, with an enforced `LIMIT`; a blocked query names the offending object
- Tabular answers render via `st.dataframe`; every result exposes the generated SQL in an expander
- Sidebar also includes quick-question buttons, a **Run Full Pipeline** button, **Export transcript**, and **Delete this conversation**
- Every Cortex call is logged to `AI_CALL_LOG` for cost/usage attribution
- Implemented with `st.text_input` + `st.markdown` rather than `st.chat_message`/`st.chat_input`, because the SiS runtime is Streamlit 1.22 (see *Known Limitations*)

### Known Limitations (Streamlit-in-Snowflake runtime 1.22)
These are platform constraints of the SiS runtime, not defects in the solution. They are documented here rather than hidden, since two of them are visible trade-offs versus the removed Mendix UI:

| Constraint | Impact | Workaround in this build |
|---|---|---|
| `st.file_uploader` unavailable (added in Streamlit 1.26) | Cannot upload a PDF from inside the app | PDFs are staged via Snowsight → **Ingestion → Load files into a Stage** → `LOGISTICS_STAGE` / `bill_of_lading/`, then processed with one click in the app |
| SiS executes server-side, so `PUT file://<local path>` cannot reach the client filesystem | No path-based upload button | Same as above |
| Sandbox blocks `<embed>`/`<iframe>` of external URLs | PDF cannot be previewed inline as it was in Mendix | `GET_PDF_URL` issues a fresh 1-hour presigned S3 URL as a download link |
| Snowflake internal stages do not serve `Content-Type: application/pdf` | Browser downloads the PDF instead of rendering it in a tab | Accepted; link is labelled as a download |
| `st.chat_message` / `st.chat_input` unavailable | Cannot use native chat widgets | Equivalent UX built from `st.text_input` + `st.markdown`, with conversation history persisted in Snowflake rather than only in session state |
| The connector bundled with SiS sends a bound Python `None` as the string `'None'` | Errors on `NUMBER` parameters, and silently stores the text `'None'` in `VARCHAR` parameters | `_call()` in `6_AI_Chat.py` emits SQL `NULL` as a literal for absent arguments and binds only real values. Note this does **not** reproduce on a current local Snowpark install, so local testing alone cannot catch it |

Upload ergonomics are the one area where the native app is a step back from the removed Mendix portal. The trade-off was accepted deliberately: the whole system now runs inside Snowflake with no external runtime, server, Java action, or API credential to maintain. When the SiS runtime advances to 1.26+, in-app upload becomes a `st.file_uploader` call plus a `PUT` to the existing stage — no architectural change.

### Verification (2026-08-18 audit)
Full solution audit run against `DPYXIQZ-FN71223`:

| Check | Result |
|---|---|
| Tables / views | 32 / 11 — all 11 views queried successfully |
| Procedures / functions | 52 / 10 |
| `BILL_OF_LADING` rows | 10,017 |
| Cortex Search `BL_SEARCH_SERVICE` | ACTIVE (indexing + serving), 10,017 rows |
| `PROCESS_BL_DOCUMENTS()` | Returns `{"processed":0,"errors":0,"synced":true}` — no unprocessed files, auto-sync confirmed |
| `REVIEW_DOCUMENT(...,'CORRECT',...)` | Returns success; corrections persisted and status advanced |
| `WORKFLOW_FULL_PIPELINE_V2('AUTO')` | Completed, 1 alert processed, AI decision `CLEAR`, SAP posted, 15.1s |
| `CHAT_WITH_DATA(...)` | Returns natural-language answer |
| `GET_PDF_URL(402)` | Returns valid presigned URL |
| Chat persistence round-trip | Session created, turns saved, listed, reloaded, deleted — verified under `HACKATHON_JUDGE_ROLE` with secondary roles disabled |
| Document integrity assertions | All 5 return zero rows: no alert with 100 confidence, no alerted doc outside `Pending_Review`, no `Synced_To_SAP` without a `SAP_FI_DOCUMENT`, no weight implausible as kg, no stored score disagreeing with `BL_DOC_CONFIDENCE` |
| Deterministic validation vs. old LLM verdict | On `DOC 402` the rules correctly report `ContainerNumber; CarrierMismatch`; the previous generative alert reported two hallucinated flags and missed the carrier mismatch |
| `BL_DOC_ALERT` false-positive check | Every `*_VALID.pdf` document still scores 100 with no anomalies; `BERLIN EXPRESS` (a genuine Hapag-Lloyd vessel with no carrier token in its name) is not flagged |
| `BL_DOC_ALERT` / `BL_DOC_CONFIDENCE` callable by judge | Verified under `USE SECONDARY ROLES NONE`; computed values match stored `ALERT` and `CONFIDENCE_SCORE` on every row |
| Every UI panel readable by judge | All six changed panels (chat sessions, extracted documents, alerts by type, usage by procedure, cost trend, app config) return rows under `USE SECONDARY ROLES NONE` |
| Chat-session privacy scoping | `CHAT_SESSION` rows owned by `CPHOA` return 0 when filtered to `HACKATHON_JUDGE`, so `TITLE` no longer leaks another user's first message |
| `ui.display_df` NULL handling | Unit-tested: `None`/`NaN`/`NaT` all render as an em dash, fully-populated columns keep their original dtype, and the input DataFrame is not mutated |
| Chat cross-user isolation | Writing to, deleting, or loading another user's conversation all correctly refused |
| Chat payload escaping | Result JSON containing single quotes and backslashes round-trips as valid JSON and rebuilds into a DataFrame |
| Chat NULL handling | User turns and tabular answers store real SQL `NULL` for absent fields, verified no column contains the string `'None'` |
| Chat session ids | Generated by `CHAT_SESSION_SEQ` only; the identity default was removed from `SESSION_ID` because Snowflake identity is not monotonic and `MAX(SESSION_ID)` could resolve to the wrong conversation |
| Stage PDFs | 15 files restored to `@LOGISTICS_STAGE/bill_of_lading/` and registered |

Two issues were found and fixed during this audit:
- **Stage PDFs were missing after account migration** — only CSV data had been restored, so `GET_PDF_URL` returned working URLs that resolved to S3 `NoSuchKey`. All 15 PDFs were re-uploaded and `ALTER STAGE ... REFRESH` was run.
- **Stale presigned URLs were being served from cache** — `PDF_PRESIGNED_URL` held expired links from the previous account. The cache was cleared and the Documents page now always requests a fresh URL via `GET_PDF_URL`.

A third issue was found while adding chat persistence and is recorded here because it invalidated an earlier verification claim:
- **Least-privilege tests were silently backed by ACCOUNTADMIN.** The developer account has `CURRENT_SECONDARY_ROLES() = ALL`, which includes `ACCOUNTADMIN`. `USE ROLE HACKATHON_JUDGE_ROLE` alone therefore does **not** produce a least-privilege session — privileges from secondary roles still apply, so a permission gap would go undetected. All judge-role verification was re-run with `USE SECONDARY ROLES NONE`. Under that stricter test the judge role behaved as intended, and the missing-grant case it exposed (`CHAT_MESSAGE` not directly readable) is the designed behaviour.

**Note:** all 7 scheduled tasks are currently `suspended` (deliberate, to conserve trial credits). Resume them with:
```sql
ALTER TASK MENDIX_APP.AGENTS.TASK_FRAUD_SCAN RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_PROCESS_NEW_BL RESUME;
-- etc. for TASK_COMPLIANCE_CHECK, TASK_AI_EXPLAIN_ANOMALY,
--        TASK_NOTIFY_HIGH_FRAUD, TASK_GENERATE_WEEKLY_INSIGHTS, TASK_REFRESH_PDF_URLS
```

### Infrastructure
- Migrated to new Snowflake trial account (`DPYXIQZ-FN71223`, expires 2026-09-04) with full schema, data, and all 52 procedures
- Added `environment.yml` to the Streamlit stage root to declare the `plotly` dependency (fixes `ModuleNotFoundError` on the dashboard)
- Generated new RSA key pair for `MENDIX_SERVICE_USER` key-pair JWT authentication
- Mendix integration code retained in `mendix-integration/` as **reference only** — it is not deployed, not the entry point, and not required to run the solution. It documents the JDBC key-pair auth pattern for reviewers who want to see how the original external portal authenticated.
