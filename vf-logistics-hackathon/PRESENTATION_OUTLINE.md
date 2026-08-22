# Presentation Deck Outline — VF Logistics: Intelligent Workflow Automation Agent

> ⚠️ **SUPERSEDED.** This is the original 13-slide draft outline, written before the
> Refinement Phase. The actual submitted deck, `VF_Logistics_Presentation.pptx`, has 22
> slides, was hand-edited directly (see `tools/update_pptx.py` and its history), and
> tells a different story on every point where this file mentions Mendix: Mendix was
> retired from the architecture on 2026-08-19, there is no public prototype link, and
> Streamlit-in-Snowflake is the sole interface. Extraction runs on `llama3.1-70b`, not
> `mistral-large2`. **Do not regenerate slides from this file or copy text out of it** —
> open the `.pptx` directly, or `python tools/dump_pptx.py` to read its actual content.
> Kept for history rather than corrected in place, since almost every section below
> would need rewriting to match the current deck's slide count and narrative.

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
- *"From scanned document and shipment data to autonomous action in under 10 seconds — executed inside Snowflake and triggered from the CLI."*

**Speaker notes:**
- "This demo shows an autonomous compliance workflow for maritime logistics: detect anomalies, investigate with AI, screen counterparties against real government export-screening data from Snowflake Marketplace, then take action with a full audit trail."

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
- One workflow, multiple interfaces: **CLI / Cortex Code**, natural language (Cortex Agent), Python/Snowpark, Mendix operator UI

**Speaker notes:**
- "For this hackathon, the centerpiece is CLI execution: one command triggers the full workflow end-to-end. Mendix is the public operator UI, not where the intelligence lives."

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
| 2. Compliance & Sanctions Screening | Rule scoring + Marketplace-sourced export-restriction match | Snowflake Marketplace |
| 3. AI Investigation & Remediation | Risk reasoning + autonomous action | Cortex AI (`COMPLETE`) |

**Speaker notes:**
- "Skill 2 is a key differentiator: screening runs against a real US government export-screening dataset obtained from Snowflake Marketplace, not a static file we shipped ourselves. We also report which data basis each match came from, because the provider's feed currently stops at April 2024 — real third-party data, stated accurately rather than claimed to be live."

---

## Slide 6: Live Demo Script

**On-slide (title):**
- **"Document to Decision in ~10 Seconds"**

**On-slide (command):**
```sql
CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');
```

**On-slide (what happens):**
- Step 1: Fraud detection → alert created
- Step 2: AI investigation → Cortex AI reasoning summary
- Step 3: Sanctions screen → Marketplace dataset match check
- Step 4: Autonomous action → block / escalate / clear

**Optional demo insert (5-10s):**
- Show the Streamlit dashboard first with the live KPIs \u2014 at last check: `~10,000 shipments`, `~$53M revenue`, `2,394 screened entities`, `5 AI calls (24h)`. These drift slightly run to run because the pipeline is a live autonomous system, not a static screenshot \u2014 do not worry if the exact number on screen differs from this outline.

**Speaker notes (tight narration):**
- "This single CLI call runs the entire pipeline. The public prototype link is Mendix for zero-friction access, but the technical proof happens here in Snowflake. Next we’ll validate multi-step orchestration using the audit log."

**On-screen cues:**
- Keep terminal font large.
- Show the JSON result returned by the procedure.
- Do not spend time in Mendix here (Mendix is the MVP link, not the execution surface).
- If using the author's workstation, run this from Cortex Code's SQL runner rather than `snow sql` because the local OAuth path is unreliable there.

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
SELECT ALERT_ID, ALERT_TYPE, SEVERITY, STATUS, AI_RECOMMENDED_ACTION, RESOLUTION_NOTES
FROM MENDIX_APP.AGENTS.FRAUD_ALERT
ORDER BY ALERT_ID DESC
LIMIT 5;
```

**On-slide (bullets):**
- Produces actionable records (alerts) not just analytics
- Severity tiers + AI-recommended actions + resolution notes for downstream operations

**Speaker notes:**
- "This is what operations teams use day-to-day: alert severity, status, and remediation notes."

---

## Slide 9: Technical Execution Highlights

**On-slide (bullets):**
- **Orchestration**: `WORKFLOW_FULL_PIPELINE_V2` chains skills with audit logging
- **Decision branches**: AI decision drives BLOCK / ESCALATE / CLEAR
- **Reliability**: defensive lookups + retry wrapper for transient AI failures
- **CLI-native build process**: authored, debugged, validated in CoCo CLI / Cortex Code
- **Governance hardening**: owner-rights Streamlit write actions removed or made view-only to prevent reviewer-side mutations
- **Demo polish**: Streamlit dashboard charts were live-verified and corrected before recording

**Speaker notes:**
- "We kept the implementation production-shaped: predictable contracts, defensive SQL, and end-to-end traceability."

---

## Slide 10: Judging Criteria Mapping

**On-slide (table):**

| Criteria (Section 9) | Evidence |
|----------------------|----------|
| Cortex Code CLI usage | Built/debugged via CoCo CLI sessions; demo executed from Cortex Code / SQL CLI |
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
- Evolve Streamlit into a deeper operator console while keeping Mendix as the zero-friction public prototype

**Speaker notes:**
- "This submission proves the workflow pattern. Next steps are enrichment, tuning, and broader data coverage."

---

## Slide 12: Thank You / Links

**On-slide:**
- GitHub repo: https://github.com/hoachauphuoc/vf-logistics-hackathon
- Public prototype (Mendix): https://vflogisticsportal-sandbox.mxapps.io/p/HomeWeb?profile=Responsive
- Optional read-only Streamlit access available on request
- Contact: `hoachauphuoc@gmail.com`

**Speaker notes:**
- "Thank you. Happy to answer questions about workflow orchestration, auditability, or Marketplace integration."
