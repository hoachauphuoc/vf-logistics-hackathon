# VF Logistics — Intelligent Workflow Automation Agent

**Submission for the Snowflake CoCo CLI Hackathon** — Challenge: *Intelligent Workflow Automation Agent*.

An AI-driven agentic system that autonomously detects, investigates, screens, and remediates fraud and compliance risk in maritime logistics (Bill of Lading) shipments on Snowflake.

---

## Start here

**Repository:** https://github.com/hoachauphuoc/vf-logistics-hackathon

> ### **[`vf-logistics-hackathon/README.md`](./vf-logistics-hackathon/README.md) — the full submission document**
>
> Read that file first. It contains the problem statement, architecture, the 3 Agent Skills, how to run the workflow from the CLI, datasets used, and the judging-criteria mapping.

Other entry points for reviewers:

| Document | What it covers |
|---|---|
| [`vf-logistics-hackathon/README.md`](./vf-logistics-hackathon/README.md) | **Main submission** — architecture, skills, how to run |
| [`vf-logistics-hackathon/docs/COCO_CLI_EVIDENCE.md`](./vf-logistics-hackathon/docs/COCO_CLI_EVIDENCE.md) | Reproducible evidence of Cortex Code CLI usage, with SQL a judge can re-run |
| [`vf-logistics-hackathon/COMPLIANCE_CHECKLIST.md`](./vf-logistics-hackathon/COMPLIANCE_CHECKLIST.md) | Terms & Conditions compliance audit |
| [`vf-logistics-hackathon/PRESENTATION_OUTLINE.md`](./vf-logistics-hackathon/PRESENTATION_OUTLINE.md) | Slide-by-slide deck outline |

## Live prototype

- **Primary interface — Streamlit-in-Snowflake dashboard `VF_LOGISTICS_DASHBOARD`:** source in [`streamlit_app/`](./streamlit_app). Runs natively inside Snowflake (account `DPYXIQZ-FN71223`). Covers document processing, AI review/edit/approve, fraud detection, compliance, AI chat, and analytics.
- **Evaluator login** (no anonymous public URL — SiS requires authentication): `https://app.snowflake.com` → account `DPYXIQZ-FN71223`, user `HACKATHON_JUDGE`, password `SnowHack2026!`. Verified end-to-end under that role on 2026-08-18. Full details in Section 0 of [`vf-logistics-hackathon/README.md`](./vf-logistics-hackathon/README.md).
- _(Historical)_ The original submission used a Mendix sandbox UI. Per evaluator feedback, Mendix has been **removed** and all functionality consolidated into the Streamlit app. See Section 11 of [`vf-logistics-hackathon/README.md`](./vf-logistics-hackathon/README.md) for details.

## Run the autonomous workflow

```bash
snow sql -q "CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');" --connection <your-connection>
```

The orchestrator chains five steps — anomaly detection, Cortex AI investigation, live Marketplace sanctions screening, AI-decided remediation (BLOCK / ESCALATE / CLEAR), and ERP posting — and writes every step, including the AI's decision and its stated reason, to `MENDIX_APP.AGENTS.WORKFLOW_AUDIT_LOG`.

To see the decisions the AI has made and why:

```sql
SELECT ALERT_ID, SEVERITY, SHIPPER_NAME, AI_DECISION, AI_DECISION_REASON, ALERT_STATUS
FROM MENDIX_APP.AGENTS.V_AI_DECISIONS
ORDER BY AI_ANALYZED_AT DESC;
```

## Repository layout

```
snowflake-backend/
├── vf-logistics-hackathon/   ★ The submission: docs, agent skills, workflow SQL, Snowpark script
├── streamlit_app/            Streamlit-in-Snowflake dashboard (multi-page) — deployed app source
├── database/                 Schema definitions, table DDL, seed and pipeline scripts
├── python/                   Supporting Python utilities
├── sample_documents/         Sample Bill of Lading PDFs used for AI extraction demos
└── docs/
    ├── ops/                  Operational runbooks
    ├── setup/                Environment and account setup notes
    └── reference/            Test reports and background design documents, including
                              LOGISTICS_DB_4PHASE_DESIGN.md (an earlier, separate
                              exploration — not part of this submission)
```

## Languages and Snowflake features

- **SQL** — core workflow orchestration and all stored procedures
- **Python** — Snowpark risk scoring (`vf-logistics-hackathon/python/snowpark_risk_scoring.py`) and the Streamlit-in-Snowflake dashboard (sole user interface)
- **Java** — _reference only, not deployed_ — historical Mendix JDBC integration (`vf-logistics-hackathon/mendix-integration/`), retained to document the key-pair auth pattern

Snowflake platform features used: Cortex Agent, Cortex AI (`COMPLETE`, `AI_COMPLETE`), Cortex Analyst, Cortex Search, Snowflake Marketplace (live export-screening data), Dynamic Tables, Streams and Tasks, Snowpark, and Streamlit in Snowflake.

---

**Author:** Hoa Chau Phuoc — hoachauphuoc@gmail.com

Every procedure, bug fix, and workflow in this repository was authored, debugged, and validated through **Cortex Code (CoCo) CLI** sessions. See [`COCO_CLI_EVIDENCE.md`](./vf-logistics-hackathon/docs/COCO_CLI_EVIDENCE.md) for verifiable specifics.
