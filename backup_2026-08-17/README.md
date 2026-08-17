# Backup 2026-08-17 — pre-migration snapshot

Taken during the Refinement Phase (deadline 23/8 23:59 IST), while the account is still
on `AYUGBCE-JX50275`. This backup is intentionally NOT restored anywhere yet — per
explicit instruction, the current account's remaining credit should be used up first;
only cut over to the new account (`DPYXIQZ-FN71223`) when that account is actually needed.

## Why a new backup instead of reusing `backup_2026-08-01/`

The 8/1 backup predates several procedures/procedure updates created later that same
night and the next morning: `WORKFLOW_INGEST_AND_DECIDE`, the current
`WORKFLOW_FULL_PIPELINE_V2`, `EVALUATE_AI_DECISIONS`, `AI_GENERATE_INSIGHTS`, and the
current `GET_PDF_URL`. Restoring from 8/1 would silently regress the account to a
pre-refinement state.

## Contents

- `ddl/01_schema_ddl_fresh.sql` — full `GET_DDL('SCHEMA', 'MENDIX_APP.AGENTS', TRUE)` dump:
  all 31 tables, 3 dynamic tables, 10 views, tasks, the Streamlit app object, and the
  Cortex Search Service definition. Captured 2026-08-17.
- `ddl/02_semantic_view.sql` — `SV_LOGISTICS` semantic view DDL (not covered by the
  schema-level dump above; semantic views need their own `GET_DDL` call).
- `ddl/03_account_objects.sql` — everything outside the schema: warehouse, resource
  monitor, Marketplace listing re-request, notification integration, `VF_APP_ROLE` /
  `HACKATHON_JUDGE_ROLE` grants (curated, not a blind replay of all 484 grants on the
  live role), and the `MENDIX_SERVICE_USER` service account. **Read the key-pair auth
  note in this file before restoring** — the current auth method is RSA key-pair (JWT),
  not password, and a NEW key pair must be generated for the new account.
- `ddl/04_load_data.sql` — `COPY INTO` statements to load `data/*.csv` into the new
  account, with expected row counts and the autoincrement-sequence gotcha from the
  2026-07-23 migration (see project memory `account-migration.md`) called out explicitly.
- `data/*.csv` — 13 CSVs unloaded directly from the live tables on 2026-08-17 (see exact
  row counts in `04_load_data.sql`). Tables with 0 rows at backup time (SAP_SD_DELIVERY,
  SAP_MM_GOODS_RECEIPT, SAP_FI_LINE_ITEM, SAP_CO_COST_ALLOCATION,
  CONTAINER_PHOTO_VERIFICATION, DOCUMENT_DISCREPANCY, PARSED_DOCUMENTS,
  AI_CLASSIFICATION_CACHE, ANALYTICS_*) are NOT included — their structure is already in
  `01_schema_ddl_fresh.sql` and they start empty on restore, same as the original design.
  `BL_SEARCH_CORPUS` is also excluded — it's cheap to regenerate from `BILL_OF_LADING`
  (see the INSERT at the bottom of `04_load_data.sql`).

## Restore order

1. `03_account_objects.sql` (warehouse + Marketplace listing must exist first)
2. `01_schema_ddl_fresh.sql`
3. Upload `data/*.csv` to `@MENDIX_APP.AGENTS.LOGISTICS_STAGE/restore/`, then run
   `04_load_data.sql`
4. `02_semantic_view.sql`
5. Generate a new RSA key pair, set it on `MENDIX_SERVICE_USER`, upload the new `.p8`
   private key into the Mendix Cloud sandbox resources, update the hardcoded account
   identifier in `CallCortexAgent.java`, republish via Mendix Studio Pro (see
   `03_account_objects.sql` step 7 for exact commands)
6. Re-run `CALL MENDIX_APP.AGENTS.EVALUATE_AI_DECISIONS();` and
   `CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');` to confirm parity with
   the old account before decommissioning it.

Full narrative plan: `.snowflake/cortex/plans/migrate-to-new-snowflake-account.plan.md`
(paused after this backup step, per explicit instruction to delay cutover).
