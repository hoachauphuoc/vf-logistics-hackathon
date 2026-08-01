# VF Logistics — Snowflake backup and restore guide

Complete point-in-time backup of the `MENDIX_APP.AGENTS` backend, taken **2026-08-01**
from account `YGVORDH-IA82097` (org `ygvordh`, region `ap-southeast-1`).

Everything needed to rebuild the backend in a **new Snowflake account** is in this
folder, with three exceptions that cannot be scripted — they are listed under
[Manual steps](#manual-steps) and each has explicit instructions.

---

## What is in this backup

| Path | Contents |
|---|---|
| `ddl/00_account_setup.sql` | Warehouse, resource monitor, database, schema, roles, users |
| `ddl/01_schema_ddl.sql` | 125 KB — 27 tables, 9 views, 46 procedures, 6 functions, 3 dynamic tables, 3 streams, 7 tasks |
| `ddl/02_special_objects.sql` | Stages, semantic view, Cortex Search Service, Streamlit app, Marketplace share, agent notes |
| `ddl/03_grants.sql` | Privileges for `VF_APP_ROLE` and `HACKATHON_JUDGE_ROLE` |
| `ddl/04_load_data.sql` | `COPY INTO` for all 16 data-bearing tables, with expected row counts |
| `data/` | 26 gzipped CSV files across 19 tables, one folder per table — **20,963 rows, verified** |
| `_verify_backup.py` | Decompresses every CSV and checks the row count against the source |
| `stage_files/logistics_stage/` | 20 files — 16 Bill of Lading PDFs plus earlier CSV backups |
| `stage_files/streamlit_stage/` | 10 files — the full Streamlit app (`app.py`, `i18n.py`, 6 pages, `environment.yml`, semantic model YAML) |

`01_schema_ddl.sql` was produced by `GET_DDL('SCHEMA', 'MENDIX_APP.AGENTS', TRUE)`,
so it contains the live definition of every procedure as of the export — including
the ones fixed on 2026-08-01 (`WORKFLOW_FULL_PIPELINE_V2` reading the AI decision,
`SYNC_EXTRACTED_TO_BILL_OF_LADING`, `WORKFLOW_INGEST_AND_DECIDE`).

---

## Restore order

Run as `ACCOUNTADMIN` in the new account. Steps 1–6 are scripted; do not reorder
them, because the semantic view and the search service depend on tables that must
already hold data.

```
1.  ddl/00_account_setup.sql      warehouse, monitor, database, schema, roles, users
2.  READ "Identity counters" below, then edit ddl/01_schema_ddl.sql
3.  ddl/01_schema_ddl.sql         tables, views, procedures, functions, streams, tasks
4.  PUT the data/ CSVs, then ddl/04_load_data.sql
5.  PUT the stage_files/, then ddl/02_special_objects.sql
6.  ddl/03_grants.sql             privileges
7.  Manual steps (agent, credentials, Marketplace)
8.  Verification checklist
```

Steps 4 and 5 both begin with `PUT`, which is a **client-side** command — run it
from Snowflake CLI, SnowSQL or a driver, not from a Snowsight worksheet. Each
script has the exact commands in its header.

---

## Identity counters — read before step 3

This is the one thing that will silently corrupt the restore if skipped.

Twelve tables use `IDENTITY` columns. The backup contains rows whose ids are far
**above** the `START` value recorded in the DDL, because the counters advanced over
the project's lifetime. Reload the rows without fixing `START` and the next insert
will reuse an id that already exists.

Snowflake **cannot** reseed an identity column in place — `ALTER TABLE ... ALTER
COLUMN ... SET AUTOINCREMENT` is a syntax error, verified on this account. The fix
must be applied to the DDL *before* the tables are created.

Edit each `autoincrement start` value in `ddl/01_schema_ddl.sql` to at least the
value below (each is the maximum id in the backup, rounded up to leave headroom):

| Table | Column | START in DDL | Max id in backup | Set START to |
|---|---|---|---|---|
| `BILL_OF_LADING` | `BL_ID` | 14000 | 14315 | **15000** |
| `FRAUD_ALERT` | `ALERT_ID` | 308 | 711 | **800** |
| `WORKFLOW_AUDIT_LOG` | `AUDIT_ID` | 1 | 705 | **800** |
| `NOTIFICATION_LOG` | `NOTIFICATION_ID` | 1 | 702 | **800** |
| `SAP_FI_DOCUMENT` | `FI_DOC_ID` | 1 | 501 | **600** |
| `BILL_OF_LADING_EXTRACTED` | `DOC_ID` | 1 | 402 | **500** |
| `AI_CALL_LOG` | `LOG_ID` | 1 | 302 | **400** |
| `COMPLIANCE_CHECK_RESULT` | `CHECK_ID` | 1 | 201 | **300** |
| `VESSEL_REGISTRY` | `VESSEL_ID` | 1 | 21 | **100** |
| `CHAT_SESSION` | `SESSION_ID` | 1 | 2 | **100** |
| `AI_ANOMALY_REPORT` | `REPORT_ID` | 1 | 1 | **100** |
| `SAP_MM_GOODS_RECEIPT` | `GR_ID` | 1 | 1 | **100** |

The remaining identity tables are empty in this backup, so their `START` values can
stay as they are.

---

## Manual steps

### 1. Credentials — never copy them across accounts

`00_account_setup.sql` creates `MENDIX_SERVICE_USER` and `HACKATHON_JUDGE` with
placeholder credentials. Generate new ones:

```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
```

```sql
ALTER USER MENDIX_SERVICE_USER SET RSA_PUBLIC_KEY = '<body of rsa_key.pub>';
ALTER USER HACKATHON_JUDGE SET PASSWORD = '<new strong password>';
```

Then update the Mendix constants (`SF_ACCOUNT`, `SF_USER`, `SF_PRIVATE_KEY`) so the
portal points at the new account identifier.

### 2. Cortex Agent — must be rebuilt in Snowsight

`VF_LOGISTICS_AGENT` could not be exported. Snowflake offers no
`GET_DDL('AGENT', ...)`, `DESCRIBE AGENT` returns an empty `agent_spec`, and
`SHOW VERSIONS IN AGENT` exposes only the spec path. Section 6 of
`ddl/02_special_objects.sql` lists the five tools to re-attach.

This does not block a demo: every capability the agent surfaces is also callable
from SQL, and the two entry points below cover the full flow.

```sql
CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE();     -- PDF -> extraction -> decision
CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO'); -- detect -> investigate -> act
```

### 3. Marketplace share

`WORKFLOW_SANCTIONS_SCREEN` reads the live US export-screening list from the free
"Snowflake Public Data" listing `GZTSZ290BV255`. Section 5 of
`ddl/02_special_objects.sql` requests and mounts it. Both procedures that use it
wrap the lookup in an exception handler, so the workflow still completes if the
share is unavailable — the sanctions match count is then reported as `-1`.

---

## Verification checklist

After the restore, work down this list. Each item has a command and an expected
result, so a failure is unambiguous.

| # | Check | Command | Expected |
|---|---|---|---|
| 1 | Object counts | `SELECT COUNT(*) FROM MENDIX_APP.INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='AGENTS'` | 30 |
| 2 | Procedures | `SHOW PROCEDURES IN SCHEMA MENDIX_APP.AGENTS` | 46 |
| 3 | Row counts | the verification query at the end of `04_load_data.sql` | actual = expected on all 16 rows |
| 4 | AI decisions survived | `SELECT AI_RECOMMENDED_ACTION, COUNT(*) FROM MENDIX_APP.AGENTS.FRAUD_ALERT WHERE AI_RECOMMENDED_ACTION IS NOT NULL GROUP BY 1` | 1 `BLOCK`, 6 `CLEAR` |
| 5 | Judge-facing view | `SELECT * FROM MENDIX_APP.AGENTS.V_AI_DECISIONS LIMIT 5` | rows with decision + reason |
| 6 | Stage files | `LIST @MENDIX_APP.AGENTS.LOGISTICS_STAGE/bill_of_lading/` | 16 PDFs |
| 7 | Cortex Analyst | ask the semantic view a question via Cortex Analyst | answers with SQL |
| 8 | Cortex Search | `CALL MENDIX_APP.AGENTS.SEARCH_BILL_OF_LADING('dangerous goods Singapore', 5)` | 5 results |
| 9 | End-to-end AI | `CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE()` | JSON with 3 completed steps |
| 10 | Streamlit | open `VF_LOGISTICS_DASHBOARD` in Snowsight | 6 pages load |

**Before check 8**, resume the search service — a suspended Cortex Search Service
does **not** auto-resume on query, it raises `error_code 399131`:

```sql
ALTER CORTEX SEARCH SERVICE MENDIX_APP.AGENTS.BL_SEARCH_SERVICE RESUME;
```

**Before check 9**, refresh the stage directory table — a directory table does not
see files added by `PUT` until refreshed, which otherwise produces a misleading
`extraction: Processed 0`:

```sql
ALTER STAGE MENDIX_APP.AGENTS.LOGISTICS_STAGE REFRESH;
```

`PROCESS_BL_DOCUMENTS` now issues this refresh itself, but run it manually if you
load documents by any other route.

---

## Cost posture after restore

Everything is exported in a **suspended** state, which is how the source account
was left. Nothing accrues credit until you resume it.

| Object | State in backup | Resume when |
|---|---|---|
| `COMPUTE_WH` | suspended, `AUTO_RESUME = TRUE` | resumes itself on first query |
| 7 tasks | all suspended | you want unattended pipeline runs |
| 3 dynamic tables | all suspended | you want live KPI tiles |
| `BL_SEARCH_SERVICE` | suspended | before any semantic search |

To resume the scheduled pipeline:

```sql
ALTER TASK MENDIX_APP.AGENTS.TASK_PROCESS_NEW_BL RESUME;
ALTER TASK MENDIX_APP.AGENTS.TASK_FRAUD_SCAN RESUME;
```

To suspend everything again, the source account used this order: tasks, then
dynamic tables, then the search service, then the warehouse.

---

## Known gaps

Stated plainly so nobody discovers them mid-restore.

1. **The agent is not in this backup.** Snowflake provides no export path. Rebuild
   it from section 6 of `02_special_objects.sql`, or demo via SQL.
2. **Identity counters need a manual DDL edit** before step 3. See above.
3. **`NULL` vs empty string.** The unload wrote SQL `NULL` as an empty field; the
   reload maps unquoted empty fields back to `NULL`. A column that genuinely held
   an empty string will come back as `NULL`. No such column is known in this
   schema, and the round-trip was verified exactly on `PORT_MASTER` (23 rows out,
   23 in, zero difference under `MINUS` in both directions) — but the asymmetry is
   inherent to CSV and worth knowing.
4. **Cortex model availability is region-dependent.** The procedures call
   `mistral-large2` and `claude-sonnet-4-5`. If the new account's region lacks
   them, enable cross-region inference:
   `ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';`
5. **`database/ddl/` in the repo root is older.** `full_database_ddl.sql`
   (2026-07-22) and `restore_new_account.sql` (2026-07-28) predate the 2026-08-01
   procedure fixes. Use *this* folder, not those files.

---

## How this backup was produced

Reproducible in the source account. The `snow` CLI was unavailable on the
workstation (`CredWrite` error), so `PUT`/`GET` ran through the SQL interface.

```sql
-- 1. Staging area
CREATE STAGE MENDIX_APP.AGENTS.BACKUP_STAGE DIRECTORY = (ENABLE = TRUE);

-- 2. Schema DDL as a single file
COPY INTO @MENDIX_APP.AGENTS.BACKUP_STAGE/ddl/01_schema_ddl.sql
FROM (SELECT GET_DDL('SCHEMA', 'MENDIX_APP.AGENTS', TRUE))
FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = NONE
               ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE RECORD_DELIMITER = NONE)
OVERWRITE = TRUE SINGLE = TRUE MAX_FILE_SIZE = 536870912;

-- 3. Every non-empty table, in one call
CALL MENDIX_APP.AGENTS.BACKUP_EXPORT_ALL_TABLES();
-- {"exported":19,"skipped_empty":11,"errors":0}

-- 4. Download -- one GET per table prefix, NOT one GET for all of data/
GET @MENDIX_APP.AGENTS.BACKUP_STAGE/ddl/ 'file://.../backup_2026-08-01/ddl/';
GET @MENDIX_APP.AGENTS.BACKUP_STAGE/data/BILL_OF_LADING/
    'file://.../backup_2026-08-01/data/BILL_OF_LADING/';
-- ... repeat for each of the 19 table prefixes
GET @MENDIX_APP.AGENTS.LOGISTICS_STAGE/ 'file://.../stage_files/logistics_stage/';
GET @MENDIX_APP.AGENTS.STREAMLIT_STAGE/ 'file://.../stage_files/streamlit_stage/';
```

### `GET` flattens directories — this will destroy a backup silently

`GET` does **not** recreate the stage's folder structure locally. It writes every
matched file into the single target directory, so files that share a name overwrite
each other without any warning.

Every table was unloaded to a file called `data_0_0_0.csv.gz`, so a single
`GET @BACKUP_STAGE/data/` produced **8 local files instead of 26** — 18 tables were
overwritten and lost. The fix is one `GET` per table prefix, into its own local
folder, and the target folder must already exist or `GET` fails with `ENOENT`.

The same flattening affected the staged app files: `pages/3_Fraud_Detection.py`
landed as `3_Fraud_Detection.py` next to `app.py`. Streamlit requires the `pages/`
subfolder, so the layout under `stage_files/` in this backup was rebuilt by hand and
now mirrors the stage exactly — upload it as-is and the prefixes will be correct.

Verify any re-run of this backup with the bundled checker, which decompresses every
CSV and compares the real row count against the source:

```bash
python _verify_backup.py
# 19 tables, 20,963 rows, 0 mismatches
```

The helpers exist only for migration and can be removed from the source account:

```sql
DROP PROCEDURE IF EXISTS MENDIX_APP.AGENTS.BACKUP_EXPORT_ALL_TABLES();
DROP STAGE IF EXISTS MENDIX_APP.AGENTS.BACKUP_STAGE;
```
