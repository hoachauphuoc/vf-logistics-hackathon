# Account Migration 2026-08-19: `DPYXIQZ-FN71223` → `SIKIWEQ-LP92053`

Third migration this project has needed. Executed same-day, ~24h before the SME session, per an explicit accepted-risk decision (see plan in `.snowflake/cortex/plans/migrate-to-sikiweq-account.plan.md`).

## Why

Free trial balance dropped `$398.01 → $172.57 → $47.82` across 17–19/8. Breaking down `SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY` by `SERVICE_TYPE`:

| Source | 18/8 | 19/8 |
|---|---|---|
| `SNOWFLAKE_COCO_DESKTOP` (IDE's own model usage) | 83.46 | 55.33 |
| `WAREHOUSE_METERING` (the whole application) | 15.82 | 4.86 |
| `AI_FUNCTIONS` | 0.05 | 0.06 |
| `CORTEX_SEARCH` | 0.01 | 0.00 |

~87% of spend was development tooling, not the system being judged. `WAREHOUSE_METERING_HISTORY` alone under-reports total spend by excluding serverless and COCO metering — checking only that view during a credit investigation will miss the real leak.

## What was rescued before cutover

The old account's remaining ~22 credits were spent entirely on export, not exploration, because two things existed **only** on that account:

- **5 of 15 stage PDFs** (`BATCH_A_VALID.pdf`, `BATCH_B_ERROR.pdf`, `mendix_upload_11628477475283606545.pdf`, `mendix_upload_18137617165238521596.pdf`, `mendix_upload_2938069892618352183.pdf`) — referenced by `BILL_OF_LADING_EXTRACTED.FILE_NAME` but never previously committed to git across two prior migrations.
- **The 18–19/8 fixes themselves** — the compliance rewrite, event-driven task conversion, 348-key i18n, `AI_CALL_LOG` sequence repair, severity-aware fraud gate. The most recent backup (`backup_2026-08-17/`) predated all of it; its `compliance_check_result.csv` was 0.3 KB against 10,028 live rows.

All 16 data-bearing tables were exported to CSV with row counts and `HASH_AGG(*)` recorded as the restore's proof target. Full detail: `backup_2026-08-19/README.md`.

## `GET_DDL` blind spots

`GET_DDL('SCHEMA', 'MENDIX_APP.AGENTS', TRUE)` does not include:
- **Stages.** `GET_DDL('STAGE', ...)` is rejected outright with `Invalid object type: 'STAGE'`. Both stages were hand-written from `SHOW STAGES` output, including encryption type (`SNOWFLAKE_SSE`, not the default `SNOWFLAKE_FULL` — getting this wrong would have silently broken `PARSE_DOCUMENT` and every presigned URL with no error at creation time).
- **The Cortex Search Service.** A crude grep of the dump finds the string `CREATE OR REPLACE CORTEX SEARCH SERVICE` once, which looks present — it isn't; that occurrence sits inside a procedure body (a quoted literal). The real definition was pulled with a separate `GET_DDL('CORTEX SEARCH SERVICE', ...)` call.

## The DDL splitter had to be rewritten twice

Splitting the 141 KB dump into dependency-ordered chunks (stages → tags → sequences → tables → functions → views → dynamic tables → procedures → search service → streams → tasks → streamlit):

1. **Split on `;`** — shreds every procedure body, which is full of semicolons.
2. **Split on `/^create or replace/` in multiline mode** — looks safe, is not: two procedures (`DETECT_DUPLICATES`, `BATCH_CHECK_COMPLIANCE`) create `TEMPORARY TABLE`s *inside their own quoted bodies*, and those inner `CREATE OR REPLACE TEMPORARY TABLE` lines matched the same pattern, cutting both procedures in half.
3. **Working version**: a character-by-character scanner that tracks single-quoted literals, `$$` blocks, and comments, and only recognises `create or replace` as a statement boundary when it is not inside any of those. Verified: 131 statements parsed, 30 tables / 52 procedures / 11 views / 10 functions / 7 streams / 7 tasks / 3 dynamic tables / 4 tags / 3 sequences, matching the source inventory exactly, with the two temp-table lines correctly staying inside their parent procedures.

Tool: `tools/split_ddl.py`. Task bodies also needed special handling: `GET_DDL` emits them as bare Snowflake Scripting blocks (`DECLARE ... BEGIN ... END`) with no delimiter, so a naive `;`-based split would fragment every task; the character scanner sidesteps this because task bodies contain no `create or replace` at all.

## Ten identity columns converted to sequences, pre-emptively

Every previous migration (23/7, and again this week) hit the same bug: Snowflake `autoincrement` does not adjust its counter when a table is loaded with explicit ids, does not enforce the primary key it's declared under, and (for `noorder` columns specifically) allocates from non-monotonic cached ranges — measured this week as two consecutive single-row inserts receiving id 313 then 651.

Rather than wait for each table to break in turn, all 10 data-bearing identity columns were converted to `DEFAULT <table>_<col>_SEQ.NEXTVAL` before any data was loaded: `AI_ANOMALY_REPORT.REPORT_ID`, `BILL_OF_LADING.BL_ID`, `BILL_OF_LADING_EXTRACTED.DOC_ID`, `CHAT_MESSAGE.MESSAGE_ID`, `COMPLIANCE_CHECK_RESULT.CHECK_ID`, `FRAUD_ALERT.ALERT_ID`, `NOTIFICATION_LOG.NOTIFICATION_ID`, `SAP_FI_DOCUMENT.FI_DOC_ID`, `VESSEL_REGISTRY.VESSEL_ID`, `WORKFLOW_AUDIT_LOG.AUDIT_ID`. Sequences start at 100,000 — every historical id is under 15,000. `AI_CALL_LOG.CALL_ID`/`LOG_ID` were already sequence-backed from an earlier fix and needed no change. Tool: `tools/patch_identity_columns.py`, which edits per-table blocks rather than doing a global text replace, because `DOC_ID` exists on both `BILL_OF_LADING_EXTRACTED` (start 500) and the empty `PARSED_DOCUMENTS` (start 1) and a blind replace would have collided the two.

### A new instance of the same bug, found in the data itself

Once loaded, three tables the migration hadn't touched showed duplicate ids **already present in the exported CSV**: `NOTIFICATION_LOG` (32 duplicated ids, 64 rows), `SAP_FI_DOCUMENT` (2 duplicated, 4 rows), `WORKFLOW_AUDIT_LOG` (78 duplicated, 156 rows). This is not something the migration introduced — it pre-existed on the old account and had never been detected. Checked whether any procedure does a `SELECT ... INTO` point lookup keyed on `NOTIFICATION_ID`, `AUDIT_ID`, or `FI_DOC_ID` (`grep`), found none — these are insert-only logs read by aggregate, not by key — so the historical duplicates were left as-is rather than renumbering history, while new inserts are safe because the fresh sequences start at 100,000.

### `CREATE OR REPLACE SEQUENCE` breaks the table default that references it

During the end-to-end verification, `AI_CALL_LOG_CALL_SEQ` needed to be burned forward (the loaded historical data — itself carried over from earlier same-day work on the old account — already contained ids up to 100005, one call away from colliding with the sequence's next value). `ALTER SEQUENCE ... SET START` doesn't exist (`invalid property 'SEQUENCE_START'`), so the sequence was recreated with `CREATE OR REPLACE SEQUENCE ... START WITH 200000`.

That broke `AI_CALL_LOG`: the very next insert failed with `Sequence used as a default value in table 'AI_CALL_LOG' column 'CALL_ID' was not found or could not be accessed`. A table's `DEFAULT <seq>.NEXTVAL` binds to the sequence's internal object id, not its name — replacing the sequence creates a new object under the same name, and the old binding dangles. Fixed with `ALTER TABLE AI_CALL_LOG ALTER COLUMN CALL_ID SET DEFAULT MENDIX_APP.AGENTS.AI_CALL_LOG_CALL_SEQ.NEXTVAL` (a plain default, unlike an identity default, is alterable). Verified with a probe insert landing at `CALL_ID = 200000`.

**Takeaway for any future sequence rename/recreate:** re-run `ALTER TABLE ... SET DEFAULT` immediately afterward for every column that references it, or the table will look fine until the next insert.

## Batched `CREATE FUNCTION` silently dropped two functions

After the DDL restore reported success, `INFORMATION_SCHEMA.FUNCTIONS` showed 8 rows, not 10. Missing: `BL_DOC_ALERT` and `BL_DOC_CONFIDENCE` — the two functions the whole validation pipeline depends on. The batch's last-statement-only success report (`Function VALIDATE_CONTAINER_NUMBER successfully created`) gave no indication anything earlier had failed. Recreated both individually — both succeeded standalone — and reverified with a clean case (`BL_DOC_CONFIDENCE(...)` → 100, `BL_DOC_ALERT(...)` → `NULL`) and a 5-rule-failure case (→ 17, i.e. `(6-5)/6*100` rounded).

**Takeaway:** after any multi-statement batch, verify the *count* of resulting objects, not just that the tool call returned no error — a tool reporting the last statement's result is not proof the earlier ones ran.

## Marketplace listing was already present

`SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE` — the database backing `V_EXCHANGE_RATES`, `V_EXPORT_RESTRICTED_ENTITIES`, `V_SANCTIONS_SCREENING_SOURCE`, and `V_PORT_WEATHER_FORECAST` — was auto-provisioned on the new account before this migration started (imported 2026-08-19 02:50, roughly two hours before Phase 2). Verified with row counts (655,417 FX rows, 2,394 point-in-time sanctions rows, 43,320 NOAA weather rows for the six port stations) rather than assumed present. No listing re-request was needed.

One view-creation ordering issue: `V_AI_DECISION_EVAL` references `V_SANCTIONS_SCREENING_SOURCE`, but `GET_DDL`'s alphabetical dump order puts `V_AI_DECISION_EVAL` first. `CREATE VIEW` requires referenced objects to exist already (no forward references), so `V_SANCTIONS_SCREENING_SOURCE` was created out of order, ahead of the rest of the batch.

## End-to-end proof, then rollback, twice

One test PDF through `PROCESS_BL_DOCUMENTS()` produced `{"processed":1,"errors":0,"synced":true}` — and then kept going on its own: `TASK_PROCESS_NEW_BL` picked up the same stage change from its stream and auto-triggered `WORKFLOW_INGEST_AND_DECIDE` → `SYNC_EXTRACTED_TO_BILL_OF_LADING` → `WORKFLOW_FULL_PIPELINE_V2` → `WORKFLOW_DETECT_AND_ACT` (8 real cost-per-kg anomalies detected in the 10,017-row base) → `WORKFLOW_INVESTIGATE_ANOMALY` → `WORKFLOW_SANCTIONS_SCREEN` → `WORKFLOW_AUTO_REMEDIATE`, entirely unattended. This is the intended architecture working, not a bug — but it meant the rollback had two waves, not one: my own `REMOVE`+`ALTER STAGE REFRESH` after the first rollback generated a stage-directory delete event, which the still-armed `NEW_PDF_STREAM` picked up and the task fired on **again**, producing a second round of alerts and audit rows before I suspended all 7 tasks.

Full rollback required, in order:
1. Delete the test `BILL_OF_LADING` / `BILL_OF_LADING_EXTRACTED` / `AI_CALL_LOG` / `FRAUD_ALERT` / `WORKFLOW_AUDIT_LOG` / `NOTIFICATION_LOG` rows from **both** waves.
2. Re-add two `AI_CALL_LOG` rows that a `WHERE CALL_ID >= 100000` cleanup filter had swept up along with the test rows — those two (ids 100004/100005) were genuine historical data from real background activity on the old account, not test artefacts, recovered verbatim from the CSV backup.
3. Diff every live `BILL_OF_LADING` row against the CSV backup directly (loaded into a temp table) rather than trusting the alert trail, because the first rollback wave's alert rows had already been deleted before the second wave was discovered — this found exactly one row (`BL_ID 7921`) whose `STATUS` the real fraud workflow had changed from `Delivered` to `Pending_Review`, restored from the backup value.
4. Suspend all 7 tasks and drain the 6 streams that still had residual data (`SYSTEM$STREAM_HAS_DATA` confirmed `TRUE` on all 6) with a harmless consuming query, **before** resuming tasks — resuming into armed streams would have triggered a third wave.

Final state, verified by `HASH_AGG(*)` against the pre-migration snapshot for all 16 tables: byte-identical.

## Verification summary

| Check | Result |
|---|---|
| `check_ui.py` / `smoke_load_pages.py` | Both pass: 348 keys × 3 languages, all 7 pages load |
| Compliance state | 8,666 pass / 1,351 fail / 0 unchecked, 0 disagreements with a fresh rule evaluation |
| All 16 data tables | `HASH_AGG(*)` identical to pre-migration snapshot |
| Stage PDFs | 15/15, MD5-verified |
| Streamlit files | 11/11, MD5-verified against local |
| Judge grants | 115 (104 base + 11 new sequences), verified functional under `USE SECONDARY ROLES NONE` |
| Tasks | All 7 `started`, all 7 streams drained (`SYSTEM$STREAM_HAS_DATA = FALSE`) |

## Deliberately not carried over

`AI_CALL_LOG_BAK_IDFIX` (a repair artefact from the id fix, not schema), the stale `backup_2026-08-17/` CSVs, `BL_SEARCH_CORPUS` (regenerated from `BILL_OF_LADING`, 10,017 rows), the 13 genuinely empty tables' (lack of) contents, and — per explicit decision — all Mendix integration objects (`MENDIX_SERVICE_USER`, RSA key-pair auth, the JDBC connection).
