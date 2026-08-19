# Backup 2026-08-19 — pre-migration snapshot (third migration)

Taken from `DPYXIQZ-FN71223` (org `DPYXIQZ`, account `FN71223`, locator `UR30335`) immediately
before cutting over to `SIKIWEQ-LP92053`. Unlike the 8/17 snapshot, this one **is** intended
to be restored, and immediately.

## Why not `backup_2026-08-17/`

That snapshot is stale. It predates the 18–19/8 work, and not by a little:
its `compliance_check_result.csv` is **0.3 KB against 10,028 live rows**, because the
compliance backfill happened on 18/8. Restoring from it would silently revert the compliance
rewrite, the event-driven task conversion, the 348-key i18n work, the `AI_CALL_LOG` sequence
repair, the severity-aware fraud gate and the `ALERT_RESPONSE` fix.

## Why the account is being replaced

Free balance ran `$398.01 → $172.57 → $47.82` across 17–19/8. The cause was **not** the
application:

| Source | 18/8 | 19/8 |
|---|---|---|
| `SNOWFLAKE_COCO_DESKTOP` (the IDE's own model usage) | 83.46 | 55.33 |
| `WAREHOUSE_METERING` (the whole app) | 15.82 | 4.86 |
| `AI_FUNCTIONS` | 0.05 | 0.06 |
| `CORTEX_SEARCH` | 0.01 | 0.00 |

About 87% was development tooling, not the system being judged. Worth remembering when sizing
the next account: having this app *judged* costs roughly 5 credits/day. Note also that
`WAREHOUSE_METERING_HISTORY` alone reports only ~21 credits and is therefore misleading —
it excludes serverless and COCO metering. Use `METERING_DAILY_HISTORY`.

## Contents

- `ddl/00_stages.sql` — **hand-written, and required first.** `GET_DDL('SCHEMA', …, TRUE)`
  omits stages completely and `GET_DDL('STAGE', …)` is rejected with
  `Invalid object type: 'STAGE'`, so the two stages cannot be dumped at all. `NEW_PDF_STREAM`
  is a stream on the `LOGISTICS_STAGE` directory table, so the stage must exist before the
  schema dump reaches its `CREATE STREAM` statements. Read the encryption note in the file:
  these stages are `SNOWFLAKE_SSE`, not the default `SNOWFLAKE_FULL`, and getting that wrong
  silently breaks `PARSE_DOCUMENT` and every presigned PDF URL.
- `ddl/01_schema_ddl.sql` — 141 KB `GET_DDL('SCHEMA','MENDIX_APP.AGENTS', TRUE)`. Contains
  31 tables, 11 views, 3 dynamic tables, 52 procedures, 10 functions, 7 tasks, the streams,
  the `BL_SEARCH_SERVICE` Cortex Search Service and the Streamlit object. Too large for one
  statement — split when restoring.
- `ddl/grants_judge.sql` — 104 replayable `GRANT` statements for `HACKATHON_JUDGE_ROLE`.
- `ddl/grants_app.sql` — 146 for `VF_APP_ROLE`.
  Both were generated from `SHOW GRANTS` via `RESULT_SCAN`, with `DEFAULT ` stripped out of
  procedure signatures: `SHOW GRANTS` prints `FOO(NUMBER, DEFAULT VARCHAR)`, which is not
  valid in a `GRANT` statement.
- `ddl/baseline_hashes.tsv` — row count and `HASH_AGG(*)` per table. Cross-account hash
  comparison is impossible after cutover, so this is the only way to prove the restore
  moved the data intact.
- `data/*.csv` — 16 tables, 23,304 rows, verified by `tools/verify_export.py`.

Not included, deliberately: `AI_CALL_LOG_BAK_IDFIX` (a repair artefact from the id fix — do
not carry it over), `BL_SEARCH_CORPUS` (regenerated from `BILL_OF_LADING`), the three `DT_*`
dynamic tables (they re-derive), and the 13 genuinely empty tables, whose structure is in
`01_schema_ddl.sql` and which start empty by design.

## The stage PDFs are now in git, finally

`sample_documents/pdf/stage_restore/` holds all 15 PDFs pulled off `LOGISTICS_STAGE`.
**Five of them existed nowhere else** — `BATCH_A_VALID.pdf`, `BATCH_B_ERROR.pdf` and three
`mendix_upload_*.pdf`. `BILL_OF_LADING_EXTRACTED.FILE_NAME` references all five, so losing
the old account would have broken the *View PDF* button on those rows permanently, and the
15 extracted rows could never have been reproduced. Two previous migrations left them
unversioned; this one does not.

## Counts differ from the README, and were not "corrected"

The documented demo baseline was 496 alerts / 423 `AI_CALL_LOG` rows / 219 notifications.
This snapshot holds **504 / 425 / 220**, and `AI_ANOMALY_REPORT` is 3 rather than 2.

That drift is the system working. The seven tasks were still `started`, my verification runs
had left their streams armed, and `TASK_FRAUD_SCAN` consequently ran `WORKFLOW_DETECT_AND_ACT`
and detected 8 real cost-per-kg anomalies, while `TASK_AI_EXPLAIN_ANOMALY` produced one
anomaly report. `WORKFLOW_AUDIT_LOG` grew by 6 for the same reason.

These rows were **not deleted to match the documentation**. Deleting genuine detections and
audit-log entries to make a number agree with a document is falsifying evidence, and an audit
log that only ever holds a fixed number of rows is not an audit log. The documentation is
being corrected to the data instead. All seven tasks were then suspended, so the snapshot and
the exported CSVs are a consistent point-in-time state.

## Restore order

1. `ddl/00_stages.sql` — stages before anything that references them
2. `ddl/01_schema_ddl.sql` — in chunks
3. `PUT data/*.csv` to `@MENDIX_APP.AGENTS.LOGISTICS_STAGE/restore/`, then `COPY INTO`
4. **Convert all 10 data-bearing identity columns to sequence-backed defaults** before
   running any procedure — see the plan; this bug has broken all three migrations
5. Regenerate `BL_SEARCH_CORPUS`, re-upload the 15 PDFs, redeploy the Streamlit app
6. `ddl/grants_judge.sql`, `ddl/grants_app.sql`, then a new judge password
7. Create the streams and tasks last, and only resume them after the parity check

## Restore completed

Restored to `SIKIWEQ-LP92053` the same day. Full write-up of what the restore actually
found (two functions dropped by a batched CREATE, `CREATE OR REPLACE SEQUENCE` breaking
a table default, three tables with pre-existing duplicate ids, the DDL splitter needing
two rewrites): `vf-logistics-hackathon/docs/ACCOUNT_MIGRATION_2026-08-19.md`. All 16
tables verified `HASH_AGG(*)`-identical to this snapshot after restore.

Full plan: `.snowflake/cortex/plans/migrate-to-sikiweq-account.plan.md`
