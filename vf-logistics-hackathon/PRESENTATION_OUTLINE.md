# Presentation Deck Outline — VF Logistics: Intelligent Workflow Automation Agent

Slide-by-slide structure for the hackathon submission deck (PPT).

This is a **PowerPoint-ready outline**: suggested on-slide text, speaker notes, and what to show on screen.

---

## Slide 1: Title

**On-slide (title):**
- **VF Logistics — Intelligent Workflow Automation Agent**

**On-slide (subtitle):**
- Snowflake CoCo CLI Hackathon
- Participant: Hoa Chau Phuoc (HOACHAU)

**On-slide (hook):**
- *"From document and shipment data to autonomous action in under 10 seconds — executed through the CLI."*

**Speaker notes:**
- "This demo shows an autonomous compliance workflow for maritime logistics: detect anomalies, investigate with AI, screen sanctions using live Marketplace data, then take action with a full audit trail."

---

## Slide 2: Problem & Business Impact

**On-slide (bullets):**
- Maritime freight fraud costs **$40B+/year** (undervalued cargo, shell-company shippers, sanctioned entities)
- Manual Bill of Lading review doesn’t scale; compliance teams become the bottleneck
- Goal: reduce **detect → decide → act** from hours/days to **seconds**

**Speaker notes:**
- "The pain is not just detection. It’s turning detections into decisions and actions fast enough to matter, with auditability."

---

## Slide 3: Solution Overview

**On-slide (bullets):**
- An agentic system that **reasons over enterprise data**, not just queries it
- 3 modular skills chained into one autonomous workflow
- One workflow, multiple interfaces: **CLI**, natural language (Cortex Agent), Python/Snowpark

**Speaker notes:**
- "For this hackathon, the centerpiece is CLI execution: one command triggers the full workflow end-to-end."

---

## Slide 4: Architecture

**On-slide (diagram bullets):**
- CoCo CLI / Direct SQL / Python → `WORKFLOW_FULL_PIPELINE_V2` (orchestrator)
- Skill 1: Fraud detection & scoring
- Skill 2: Compliance & sanctions screening (Marketplace)
- Skill 3: AI investigation + remediation (Cortex AI)
- Outputs: `WORKFLOW_AUDIT_LOG` + `FRAUD_ALERT`

**Speaker notes:**
- "This pattern is built for compliance: every step is logged with inputs/outputs, status, and timing."

**Visual cue:**
- Use the ASCII diagram from `README.md` or `architecture/ARCHITECTURE_DIAGRAM.txt`.

---

## Slide 5: Agent Skills Deep-Dive

**On-slide (table):**

| Skill | What it does | Snowflake feature |
|------|--------------|------------------|
| 1. Fraud Detection & Scoring | 3 anomaly rules over shipment data | SQL, Streams |
| 2. Compliance & Sanctions Screening | Rule scoring + live sanctions match | Snowflake Marketplace |
| 3. AI Investigation & Remediation | Risk reasoning + autonomous action | Cortex AI (`COMPLETE`) |

**Speaker notes:**
- "Skill 2 is a key differentiator: sanctions screening uses a live Marketplace dataset, not a static file."

---

## Slide 6: Live Demo Script

**On-slide (title):**
- **"Document to Decision in ~10 Seconds"**

**On-slide (command):**
```bash
snow sql -q "CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');" --connection ygvordh-ia82097
```

**On-slide (what happens):**
- Step 1: Fraud detection → alert created
- Step 2: AI investigation → Cortex AI reasoning summary
- Step 3: Sanctions screen → Marketplace dataset match check
- Step 4: Autonomous action → block / escalate / clear

**Optional demo insert (5-10s):**
- Show the Streamlit dashboard first with the verified KPIs: `10,009 shipments`, `$53.0M revenue`, `2,394 screened entities`, `5 AI calls (24h)`

**Speaker notes (tight narration):**
- "This single CLI call runs the entire pipeline. Next we’ll validate multi-step orchestration using the audit log."

**On-screen cues:**
- Keep terminal font large.
- Show the JSON result returned by the procedure.
- Do not spend time in Mendix here (Mendix is the MVP link, not the execution surface).

---

## Slide 7: Proof — Audit Trail

**On-slide (query):**
```sql
SELECT AUDIT_ID, STEP_ORDER, STEP_NAME, STATUS, EXECUTED_AT
FROM MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG
WHERE WORKFLOW_NAME = 'FULL_PIPELINE_V2'
ORDER BY AUDIT_ID DESC
LIMIT 5;
```

**On-slide (bullets):**
- Per-step logging: inputs, outputs, status, timings
- Built for compliance review and incident investigation

**Speaker notes:**
- "This proves it’s not a single black-box query. Each stage is executed and logged independently."

---

## Slide 8: Business Outcome

**On-slide (query):**
```sql
SELECT ALERT_ID, ALERT_TYPE, SEVERITY, STATUS, RESOLUTION_NOTES, CREATED_AT, RESOLVED_AT
FROM MENDIX_APP.AGENTS.FRAUD_ALERT
ORDER BY ALERT_ID DESC
LIMIT 5;
```

**On-slide (bullets):**
- Produces actionable records (alerts) not just analytics
- Severity tiers + resolution notes for downstream operations

**Speaker notes:**
- "This is what operations teams use day-to-day: alert severity, status, and remediation notes."

---

## Slide 9: Technical Execution Highlights

**On-slide (bullets):**
- **Orchestration**: `WORKFLOW_FULL_PIPELINE_V2` chains skills with audit logging
- **Decision branches**: severity tiers → BLOCK / ESCALATE / CLEAR
- **Reliability**: defensive lookups + retry wrapper for transient AI failures
- **CLI-native build process**: authored, debugged, validated in CoCo CLI
- **Demo polish**: Streamlit dashboard charts were live-verified and corrected before recording

**Speaker notes:**
- "We kept the implementation production-shaped: predictable contracts, defensive SQL, and end-to-end traceability."

---

## Slide 10: Judging Criteria Mapping

**On-slide (table):**

| Criteria (Section 9) | Evidence |
|----------------------|----------|
| Cortex Code CLI usage | Built/debugged via CoCo CLI sessions; demo executed via `snow sql` |
| Python / Java / Scala | Python (Snowpark), Java (Mendix integration), SQL (core workflows) |
| Snowflake platform | Cortex AI, Cortex Agent, Marketplace, Streams/Tasks, Dynamic Tables |
| Snowpark / Streamlit / Marketplace | Demonstrated integrations (Marketplace + Snowpark; Streamlit screenshots optional) |

**Speaker notes:**
- "We intentionally cover multiple scoring surfaces: CLI execution, Marketplace integration, Cortex AI reasoning, and Snowpark." 

---

## Slide 11: Roadmap / Next Steps

**On-slide (bullets):**
- Add more Marketplace context (FX rates, port congestion, weather)
- Add feedback loop from outcomes to improve prompts and thresholds
- Extend Snowpark layer toward trained risk models (Snowpark ML)

**Speaker notes:**
- "This submission proves the workflow pattern. Next steps are enrichment, tuning, and broader data coverage."

---

## Slide 12: Thank You / Links

**On-slide:**
- GitHub repo: add final repository URL before export
- Public MVP (Mendix): https://vflogisticsportal-sandbox.mxapps.io/p/HomeWeb?profile=Responsive
- Contact: `hoachauphuoc@gmail.com`

**Speaker notes:**
- "Thank you. Happy to answer questions about workflow orchestration, auditability, or Marketplace integration."
