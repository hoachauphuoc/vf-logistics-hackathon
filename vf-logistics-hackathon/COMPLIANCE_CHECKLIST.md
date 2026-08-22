# ✅ Compliance Checklist — Snowflake CoCo CLI Hackathon

Cross-reference of VF Logistics solution against the hackathon's Terms & Conditions (Official Rules) and Problem Statement "Intelligent Workflow Automation Agent".

---

## 1. Section 4.1 — Entry Content

| Requirement | Status | Notes |
|-------------|--------|-------|
| (a) Complete profile (name, email, phone, country) | ✅ Completed | Registered on Contest Site |
| (b) The Idea | ✅ Yes | Intelligent Workflow Automation Agent for logistics fraud detection |
| (c) The Prototype | ✅ Yes | VF Logistics Dashboard — a Streamlit-in-Snowflake application (`MENDIX_APP.AGENTS.VF_LOGISTICS_DASHBOARD`) that is the **sole** user interface, running natively inside the Snowflake account it operates on. There is no separate front-end tier and no external hosting |
| (d) Presentation materials + source code link | ✅ Yes | Source code: https://github.com/hoachauphuoc/vf-logistics-hackathon — README, presentation outline, CoCo CLI evidence and test report all included; recording scripts are intentionally kept local because judges do not need them |

## 2. Section 4.2 — Language

| Requirement | Status |
|-------------|--------|
| All Entry content (including oral presentation) must be in English | ✅ Compliant — every document, code comment, presentation outline, and narration script in this repository is written in English |

**One deliberate exception, disclosed for transparency:** `architecture/vf_logistics_semantic_view.yaml` contains Vietnamese terms inside `synonyms` lists. These are **not documentation** — they are functional natural-language query aliases consumed by Cortex Analyst, allowing a Vietnam-based logistics operator to ask a question in their own language and receive the same generated SQL. Bilingual end-user querying is an intentional product feature of the prototype; all descriptions, identifiers, and explanatory text in that file remain in English (see the language note at the top of the file).

## 3. Section 4.3-4.4 — Data & Third-party APIs

| Requirement | Status | Notes |
|-------------|--------|-------|
| List datasets used | ✅ Documented | See table below |
| License compliance for non-Snowflake datasets | ✅ Compliant | Only using Snowflake Marketplace free listing |

**Datasets used:**

| Dataset | Source | License | Notes |
|---------|--------|---------|-------|
| BILL_OF_LADING (~10,000 rows, live count) | Self-generated synthetic data | N/A (self-created) | Maritime logistics simulation data |
| Snowflake Public Data (Free) — `INTERNATIONAL_TRADE_ADMINISTRATION_EXPORT_SCREENED_ENTITIES_INDEX` and `..._INDEX_PIT`, read via `V_SANCTIONS_SCREENING_SOURCE` | Snowflake Marketplace (free listing `GZTSZ290BV255`) | Free, Snowflake-provided | Used for export-restriction screening — meets "Marketplace" criterion in Section 9. Provider's current table is empty and its point-in-time data ends 2024-04-10, so the effective list is a real government historical snapshot (see Section 5.1) |
| `V_EXCHANGE_RATES` | Snowflake-hosted reference data in account | Snowflake-provided | Used in the Streamlit monitoring panel |
| HS_CODE_REFERENCE | Self-generated (based on public HS Code standard) | Public reference data | |

## 4. Section 4.5 — Final Presentation & Demo Requirements

| Requirement | Status | Action |
|-------------|--------|--------|
| (a) Presentation deck (PPT) | ✅ Final | `VF_Logistics_Presentation.pptx` finalized (16 slides); excluded from git by `.gitignore`, uploaded directly to the contest portal |
| (b) Source code on GitHub | ✅ Published | https://github.com/hoachauphuoc/vf-logistics-hackathon — public repository, includes the submission docs, agent-skill SQL, Streamlit app source, and Snowpark script. An early Java/Mendix integration was retired from the architecture on 2026-08-19 and is kept only under `mendix-integration/` as a historical reference — it is not deployed and is not required to run the solution |
| (c) Live demo (if reaching Finals) | ✅ Ready | `CALL WORKFLOW_FULL_PIPELINE_V2('AUTO')` runs successfully via Cortex Code / SQL CLI, typically ~4-8s depending on warm state |
| (d) Technical readiness | ✅ | The Streamlit-in-Snowflake application and CLI-driven backend were revalidated after the account migrations, grants fix, and regression-test hardening. The former Mendix front end was fully retired, not just "also working" |
| (e) Demo video | ✅ Recorded | Full CoCo CLI + Snowsight + Streamlit walkthrough recorded (~4:40, 1280x676 source captured at 4K then reviewed at 720p); reviewed for accidental secret exposure — none found |

## 5. Section 5 — Entry Warranties (⚠️ CRITICAL)

| Requirement | Status | Action needed |
|-------------|--------|---------------|
| (a) No offensive content | ✅ Compliant | |
| (b) Original content | ✅ Compliant | All code written via CoCo CLI |
| (c) No third-party IP violation | ✅ Compliant | |
| (d) No confidential/proprietary info | ✅ **FIXED** | Hardcoded password removed, then superseded entirely by key-pair (JWT) authentication — no secret of any kind in the source |
| (e) No privacy/publicity right violation | ✅ Compliant | Data is synthetic, PII_FLAG exists but uses fictitious company names |
| (h) No malicious code | ✅ Compliant | |
| (i) Not misleading, accurate | ✅ Compliant | Re-audited 2026-08-17: wording about the Marketplace screening dataset was corrected from "live" to "real government data, historical snapshot to 2024-04-10", after verifying the provider's feed had stopped updating (see Section 5.1) |

### ✅ Security fix completed — and then the entire component was retired

> **Historical record only.** The Java/Mendix integration described below was **removed
> from the architecture on 2026-08-19**. It is not deployed, has no running credentials,
> and is not part of the solution a judge will see or use. It is documented here strictly
> because Warranty (d) requires disclosure of any credential-handling defect that ever
> existed, and it shows the actual remediation path rather than omitting the finding.

The original defect was a literal password compiled into the (now-retired) Mendix Java
action. It was first moved to an environment variable, and the credential itself was
subsequently **replaced with key-pair (JWT) authentication** before the component was
retired outright:

```java
// BEFORE (insecure — a literal password was compiled into the Java action;
// the value is redacted here and has since been rotated in Snowflake):
props.put("password", "<REDACTED — was a hardcoded literal>");

// INTERIM (better — no secret in source, but still a shared password):
String password = System.getenv("SNOWFLAKE_MENDIX_PASSWORD");
props.put("password", password);

// FINAL, BEFORE RETIREMENT (key-pair / JWT — no password existed for this user):
props.put("authenticator", "SNOWFLAKE_JWT");
props.put("private_key_file", privateKeyPath);   // .p8, git-ignored
```

The service user this Java code once authenticated as has since been dropped along with
the rest of the integration. There is no credential in the current architecture that
traces back to this defect.

## 5.1 Accuracy re-audit of the Marketplace dependency (2026-08-17)

During the Refinement Phase the screening dependency was re-verified against the live
account, and two problems were found and fixed — recorded here because Warranty (i)
requires the Entry not to be misleading:

1. **Functional defect:** `WORKFLOW_SANCTIONS_SCREEN`, `WORKFLOW_INVESTIGATE_ANOMALY` and
   `V_AI_DECISION_EVAL` all queried the provider's *current* table
   (`..._EXPORT_SCREENED_ENTITIES_INDEX`), which had silently become **empty**. Every
   screen therefore returned `matches_found: 0` regardless of the entity name, making the
   sanctions-driven BLOCK branch unreachable. All three objects were repointed to a new
   view, `V_SANCTIONS_SCREENING_SOURCE`, which prefers the provider's current table and
   falls back to its point-in-time table. Screening now correctly returns
   `risk_level: CRITICAL` for a listed entity (verified against `Jsc Element`) and `CLEAR`
   for an unlisted one.
2. **Wording correction:** the dataset was previously described as "live" / "real-time"
   sanctions data. The data is genuinely real US government export-screening data from
   Marketplace, but the provider's feed stops at **2024-04-10**, so the documentation now
   describes it as a real historical snapshot and the screening output reports its
   `data_basis` explicitly.

## 6. Section 9 — Judging Criteria

| # | Criteria | Status | Evidence |
|---|----------|--------|----------|
| 1 | Idea + Prototype using **Cortex Code CLI** | ✅ Compliant | All development, debugging (fixed AUTOINCREMENT bug, mounted Marketplace listing, fixed the hardcoded-remediation flaw), and migration performed via CoCo CLI — **verifiable evidence with reproducible SQL in `docs/COCO_CLI_EVIDENCE.md`** |
| 2 | Uses Python, Java, and/or Scala | ✅ Compliant | Python — Streamlit-in-Snowflake app + Snowpark script. The requirement is "and/or"; Python alone satisfies it |
| 3 | Uses Snowflake's platform | ✅ Strong compliance | Cortex Agent, Cortex Search, Cortex AI (COMPLETE), Dynamic Tables, Tasks, Streams |
| 4 | Preference: Snowpark, Worksheets, Streamlit, Marketplace | ✅ Compliant | Streamlit ✅, Marketplace ✅ (Public Data Free), Snowpark ✅ |

## 7. Problem Statement Judging Focus

| Focus | Status |
|-------|--------|
| Real-World Relevance: clear business problem, measurable impact | ✅ Fraud detection, compliance screening — measured by alerts count/execution time |
| Technical Execution: multi-step orchestration | ✅ `WORKFLOW_INGEST_AND_DECIDE` chains 3 stages wrapping `WORKFLOW_FULL_PIPELINE_V2`'s 5 steps, all logged |
| Technical Execution: **end-to-end, document to decision** | ✅ **Fixed 2026-08-01, tightened 2026-08-22** — the two halves of the system were previously unconnected (0 row overlap between the extracted and operational tables), so an uploaded PDF could never reach a decision. `SYNC_EXTRACTED_TO_BILL_OF_LADING` now bridges them and a `DOCUMENT_QUALITY` rule makes low-confidence extractions reasonable-over. A further gap found while rehearsing the demo: the bridge never triggered a compliance check on the shipment it had just created, so `COMPLIANCE_CHECK_PASSED` stayed `NULL` for every new PDF until someone ran a batch job by hand. `SYNC_EXTRACTED_TO_BILL_OF_LADING` now calls `CHECK_COMPLIANCE` in the same step, so "document to decision" now includes compliance, not only fraud. Verified: 2 PDFs uploaded in one command → one clean document approved silently, one unreliable document escalated with its reason, both compliance-checked with no manual step |
| Technical Execution: **reasoning that drives the action** | ✅ **Fixed 2026-08-01** — the AI's BLOCK/ESCALATE/CLEAR decision is parsed, persisted to `FRAUD_ALERT` and executed by the remediation step. Previously the orchestrator hardcoded `ESCALATE`. Verified differentiated outcomes: 1 BLOCK vs 6 CLEAR — see `V_AI_DECISIONS` |
| Technical Execution: error handling + decision branches | ✅ severity tiers, defensive `LIMIT 1`, retry wrapper, safe default to human review when the model output cannot be parsed, graceful SKIPPED path when no alert qualifies, sanctions-lookup exception fallback |
| Technical Execution: CoCo CLI + Agent Skills + tools | ✅ 3 Skills packaged and documented; verifiable CLI evidence in `docs/COCO_CLI_EVIDENCE.md` (8 sessions with reproducible SQL) |
| Solution Completeness: end-to-end | ✅ PDF ingestion → AI extraction → promotion → detection → AI reasoning → autonomous action → notification → ERP posting |
| Solution Completeness: minimal manual intervention | ✅ `TASK_PROCESS_NEW_BL` calls the full flow on a stage stream — one `RESUME` gives hands-off operation; shipped suspended to protect the trial credit |
| Explainability for reviewers | ✅ Every decision carries a one-line reason plus the full model assessment, in `V_AI_DECISIONS`, in `WORKFLOW_AUDIT_LOG`, and in the Streamlit *Autonomous AI Decisions* panel |

---

## Summary: submission readiness (2026-08-02 submitted · re-verified 2026-08-17 for the Refinement Phase)

| # | Item | Status |
|---|---|---|
| 1 | **Security** — no hardcoded credentials | ✅ Password moved to an environment variable, then superseded by key-pair (JWT) auth; the entire Java/Mendix component this defect lived in was later retired from the architecture. No credential in the current solution traces back to it |
| 2 | **Language** — English only (§4.2) | ✅ all docs, deck and code comments; one disclosed exception (bilingual Cortex Analyst synonyms, Section 2) |
| 3 | **Python** (§9.2) | ✅ Streamlit-in-Snowflake app + Snowpark script — satisfies the Python/Java/Scala requirement on its own |
| 4 | **Agent Skills** | ✅ 3 skills documented, with the DOCUMENT_QUALITY rule added to Skill 1 |
| 5 | **CoCo CLI evidence** (§9.1) | ✅ `docs/COCO_CLI_EVIDENCE.md` — 8 engineering sessions, each with SQL a judge can re-run |
| 6 | **Decision integrity** | ✅ AI decision drives remediation; decision + reason persisted and surfaced |
| 7 | **End-to-end flow** | ✅ `WORKFLOW_INGEST_AND_DECIDE` — batch PDF upload to AI decision in one command |
| 8 | **GitHub source code** (§4.5b) | ✅ https://github.com/hoachauphuoc/vf-logistics-hackathon (public) |
| 9 | **Presentation deck** (§4.5a) | ✅ `VF_Logistics_Presentation.pptx` — 16 slides, finalized; upload directly to the portal (excluded from git by `.gitignore`) |
| 9b | **Demo video** | ✅ Recorded and reviewed (CLI + Snowsight + Streamlit walkthrough); no secrets or credentials found on screen |
| 10 | **Prototype access** | ✅ Streamlit-in-Snowflake app `MENDIX_APP.AGENTS.VF_LOGISTICS_DASHBOARD`, opened from Snowsight → Streamlit. This is the **only** front end; there is no separate public URL because the application runs natively inside Snowflake and requires a Snowflake session, not anonymous web access |
| 11 | **Registration** (§4.1a) | ✅ team "Sora", 2 members, confirmed on the contest portal |
| 12 | **Validation report** | ✅ `../docs/reference/TEST_REPORT_FINAL_2026-08-01.md` |
| 13 | **Judge read-only access** | ✅ `HACKATHON_JUDGE` account (read-only role) is the **primary** — and only — way for a judge to open the prototype, since it is Streamlit-in-Snowflake rather than a public website. Credentials are shared via the submission form, never in the repository |
| 14 | **Submit through the portal Submissions tab** | ✅ Completed | Submission uploaded through portal |

**Deadline note:** the Terms & Conditions state the Submission Period closed **2026-08-02 23:59 IST**, and that submission was completed. The entry was subsequently **shortlisted**, opening a **Refinement Phase with a hard deadline of 2026-08-23 23:59 IST** for final refinement and optimisation. All items above refer to the original submission; refinement work carried out after shortlisting is recorded in Section 9 of [`../docs/reference/TEST_REPORT_FINAL_2026-08-01.md`](../docs/reference/TEST_REPORT_FINAL_2026-08-01.md).
