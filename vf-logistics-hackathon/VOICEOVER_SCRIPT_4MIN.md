# Voice-Over Script (4 Minutes) — VF Logistics Intelligent Workflow Automation Agent

This script is designed for a ~4-minute hackathon demo video.

**Core rule:** Mendix is the *public MVP link* (10–15s). The *main demo* is CLI execution of the autonomous workflow.

---

## Shot List (Recommended)

1) Mendix Prototype (10–15s)
2) Architecture Slide (20–25s)
3) Terminal: Run Workflow via CLI (45–60s)
4) Terminal: Audit Trail Proof (30–40s)
5) Terminal: Business Outcome (Fraud Alert) (25–35s)
6) Snowflake Notebook: Snowpark Proof (20–30s)
7) Closing Slide (15–20s)

---

## Script

### Shot 1 — Mendix Prototype (0:00–0:15)
**On screen:** Mendix sandbox page showing Bill of Lading grid and Status badges.

**Voice-over:**
"This is VF Logistics' operational prototype built in Mendix. Compliance teams see shipments and their investigation status at a glance, like Pending Review or AI Processed. In production, the goal is to move from manual review to autonomous action in seconds."

**On-screen cue (optional, no click needed):** highlight a row with `Pending_Review`.

### Shot 2 — Architecture (0:15–0:40)
**On screen:** Slide with architecture diagram (3 skills + orchestrator + audit log).

**Voice-over:**
"The solution is a Snowflake-native intelligent workflow automation agent, built and debugged end-to-end using Cortex Code CLI. It chains three modular Agent Skills: first fraud detection and scoring, then compliance and sanctions screening using live Marketplace data, and finally AI investigation and remediation using Cortex AI. Everything is orchestrated by one procedure with a full audit trail for compliance."

### Shot 2.5 — Streamlit Monitoring Snapshot (0:40–0:55)
**On screen:** Snowflake Streamlit dashboard landing page.

**Voice-over:**
"Before running the workflow, here is the live operational dashboard inside Snowflake. It summarizes 10,009 shipments, over 53 million dollars in cargo charges, weekly shipment trends, carrier revenue distribution, sanctions screening coverage, FX rates, and recent AI usage."

**On-screen cue:** keep the view on the cleaned main dashboard only; do not open extra pages.

### Shot 3 — CLI Run (0:55–1:45)
**On screen:** Terminal.

**Voice-over:**
"Now I'll run the full autonomous workflow through the CLI, which is a core requirement of this hackathon. This single command triggers the entire pipeline." 

**On screen (type/paste):**
```bash
snow sql -q "CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');" --connection ygvordh-ia82097
```

**Voice-over (while it runs):**
"Step one detects anomalies in bill of lading data and creates a fraud alert. Step two uses Cortex AI to investigate the risk context and generate a reasoning summary. Step three performs a sanctions screen against a live Snowflake Marketplace dataset. And step four takes an autonomous action such as escalate, block, or clear."

**On screen:** show the JSON result.

**Voice-over:**
"The workflow completes in seconds and returns a structured result with the alert ID, screened shipper, and execution time."

### Shot 4 — Audit Trail Proof (1:45–2:25)
**On screen:** Terminal query against audit log.

**Voice-over:**
"To prove this is truly multi-step orchestration, every stage is logged to an audit table with status and timing." 

**On screen:**
```sql
SELECT AUDIT_ID, STEP_ORDER, STEP_NAME, STATUS, EXECUTED_AT
FROM MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
WHERE WORKFLOW_NAME = 'FULL_PIPELINE_V2'
ORDER BY AUDIT_ID DESC
LIMIT 5;
```

**Voice-over:**
"Here you can see each step executed independently: detection, AI investigation, sanctions screening, and remediation. This provides governance-grade traceability for compliance teams."

### Shot 5 — Business Outcome (2:25–3:00)
**On screen:** Terminal query of fraud alert record.

**Voice-over:**
"The system doesn't stop at analytics. It produces a business outcome: a fraud alert with severity, status, and resolution notes."

**On screen:**
```sql
SELECT ALERT_ID, ALERT_TYPE, SEVERITY, STATUS, RESOLUTION_NOTES, CREATED_AT, RESOLVED_AT
FROM MENDIX_APP.AGENTS.FRAUD_ALERT
ORDER BY ALERT_ID DESC
LIMIT 5;
```

**Voice-over:**
"This is the exact data operations teams can review, export, and audit."

### Shot 6 — Snowflake Notebook / Snowpark Proof (3:00–3:30)
**On screen:** Snowflake Notebook cell showing `get_active_session()` and a simple call.

**Voice-over:**
"We also provide a Snowpark Python layer for risk scoring and programmatic invocation. Running inside a Snowflake Notebook avoids local SSO prompts and keeps the demo reliable." 

**On screen:** show a cell that calls the stored procedure or shows risk scoring output.

### Shot 7 — Close (3:30–4:00)
**On screen:** Closing slide: differentiators + links.

**Voice-over:**
"In summary, VF Logistics demonstrates an autonomous, audited workflow that runs through the CLI, reasons with Cortex AI, screens against real Marketplace data, and exposes a polished Streamlit monitoring layer for operators. The Mendix prototype provides a publicly accessible operational UI, while the Snowflake backend delivers the end-to-end intelligent automation. Thank you."

---

## Recording Notes (Keep It Clean)

- Do not click Mendix "Analyze" during the video; keep Mendix as the MVP UI context.
- Make terminal text large (125% zoom) and use a dark theme for readability.
- Prefer Option A (single CLI command) for the live run to reduce risk.
- Keep the Streamlit app sidebar collapsed so the dashboard cards and FX table are not squeezed during recording.
