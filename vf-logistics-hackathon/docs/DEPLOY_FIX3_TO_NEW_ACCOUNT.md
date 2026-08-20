# Deploy Fix 3 (chat persistence) + the Streamlit app to a target account

A runbook, not prose. Work top to bottom. Paste every `sql` block into a Snowsight
worksheet; run every `powershell` block in a terminal.

**Context:** this procedure was authored while the solution lived on an earlier account
and is intended to be run against the **target account** — the one that will be used for
judging. The current deployment target is `SIKIWEQ-LP92053`.

---

## 0. Things you must know before starting

| Fact | Consequence |
|---|---|
| **`PUT` does not work inside a Snowsight worksheet** | Streamlit files must reach the stage via the `snow` CLI, via an IDE, or via `Ingestion → Load files into a Stage`. Do not spend an hour rediscovering this |
| `chat_persistence.sql` contains `create or replace TABLE CHAT_SESSION` | A second run **will destroy** saved conversations. Step 1 checks for this before you run anything |
| `CREATE OR REPLACE PROCEDURE` wipes every `GRANT USAGE` | The file already carries 7 `GRANT` statements at the end. Do not run half the file and stop |
| `HACKATHON_JUDGE_ROLE` must exist **before** you run | If it does not, the `GRANT` statements at the end of the file will fail |
| The new Compliance page reads the `status` / `issues` keys | If `CHECK_COMPLIANCE` on the target account is the old version (returning `compliant` / `violations`), **every result will render as FAILED**. See Step 5 |

---

## 1. Pre-flight — run this first and read the result before doing anything else

```sql
USE DATABASE MENDIX_APP;
USE SCHEMA AGENTS;

SELECT
  (SELECT COUNT(*) FROM MENDIX_APP.INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA='AGENTS' AND TABLE_NAME='CHAT_MESSAGE')      AS HAS_CHAT_MESSAGE,
  (SELECT COUNT(*) FROM MENDIX_APP.INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA='AGENTS' AND TABLE_NAME='CHAT_SESSION')      AS HAS_CHAT_SESSION,
  (SELECT COUNT(*) FROM MENDIX_APP.INFORMATION_SCHEMA.PROCEDURES
     WHERE PROCEDURE_SCHEMA='AGENTS' AND PROCEDURE_NAME LIKE 'CHAT_%') AS CHAT_PROCS,
  (SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
     WHERE NAME='HACKATHON_JUDGE_ROLE' AND DELETED_ON IS NULL)       AS HAS_JUDGE_ROLE;
```

**How to read the result:**

| Result | Meaning | Action |
|---|---|---|
| `HAS_CHAT_MESSAGE = 0` | Fix 3 is not deployed | Continue to Step 2 |
| `HAS_CHAT_MESSAGE = 1` and it holds data | Fix 3 **is already** deployed | **STOP.** Re-running destroys saved conversations. Only proceed if losing them is acceptable |
| `CHAT_PROCS < 6` | Procedures are missing | Continue to Step 2 |
| `HAS_JUDGE_ROLE = 0` | The judge role does not exist | Create the role first, otherwise the 7 `GRANT` statements at the end of the file will fail |

If `HAS_CHAT_SESSION = 1`, check which table it actually is — the old analytics table or
the Fix 3 table:

```sql
SELECT COLUMN_NAME FROM MENDIX_APP.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA='AGENTS' AND TABLE_NAME='CHAT_SESSION'
ORDER BY ORDINAL_POSITION;
```

A `TITLE` column means it is the Fix 3 table. `TOKENS_USED` / `MESSAGE_COUNT` without
`TITLE` means it is the old analytics table and is safe to overwrite — this was verified
on the source account: no view or procedure depended on it.

---

## 2. Run chat_persistence.sql

Open the file and run it **in full**; do not run it piecemeal:

```
vf-logistics-hackathon/sql/workflows/chat_persistence.sql
```

It creates `CHAT_SESSION`, `CHAT_SESSION_SEQ`, `CHAT_MESSAGE`, and 6 procedures —
`CHAT_SESSION_NEW` · `CHAT_MESSAGE_SAVE` · `CHAT_SESSION_LIST` · `CHAT_SESSION_LOAD` ·
`CHAT_SESSION_DELETE` · `CHAT_SESSION_RENAME` — plus 7 `GRANT` statements.

If the worksheet refuses to run multiple statements at once, use the CLI:

```powershell
$r = 'C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\snowflake-backend'
snow sql -f "$r\vf-logistics-hackathon\sql\workflows\chat_persistence.sql" -c <connection_name>
```

---

## 3. Verify the SQL landed correctly

```sql
SELECT PROCEDURE_NAME, ARGUMENT_SIGNATURE
FROM MENDIX_APP.INFORMATION_SCHEMA.PROCEDURES
WHERE PROCEDURE_SCHEMA='AGENTS' AND PROCEDURE_NAME LIKE 'CHAT_SESSION%'
   OR (PROCEDURE_SCHEMA='AGENTS' AND PROCEDURE_NAME='CHAT_MESSAGE_SAVE')
ORDER BY 1;
```
This must return **6 rows**.

```sql
-- Real lifecycle: create a session -> save one turn -> read it back -> delete
CALL MENDIX_APP.AGENTS.CHAT_SESSION_NEW('EN');
```
Note the `SESSION_ID` it returns and substitute it for `<SID>` below:

```sql
CALL MENDIX_APP.AGENTS.CHAT_MESSAGE_SAVE(<SID>, 'user', 'deploy smoke test');
CALL MENDIX_APP.AGENTS.CHAT_SESSION_LIST();
CALL MENDIX_APP.AGENTS.CHAT_SESSION_LOAD(<SID>);
CALL MENDIX_APP.AGENTS.CHAT_SESSION_DELETE(<SID>);
```

| Step | Expected |
|---|---|
| `CHAT_SESSION_NEW` | Returns a numeric `SESSION_ID` |
| `CHAT_MESSAGE_SAVE` | Succeeds with no error |
| `CHAT_SESSION_LIST` | The session you just created appears in the list |
| `CHAT_SESSION_LOAD` | Returns the `'deploy smoke test'` turn verbatim |
| `CHAT_SESSION_DELETE` | Deletes cleanly; `CHAT_SESSION_LIST` no longer shows it |

**Do not skip this step.** Creating the tables does not prove the procedures run — all 6
are `EXECUTE AS OWNER` and perform an internal permission check against `CURRENT_USER()`.

---

## 4. Get the Streamlit files onto the stage

`PUT` does **not** work in a worksheet. Three options; pick one:

**Option A — snow CLI (fastest):**
```powershell
$r = 'C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\snowflake-backend\streamlit_app'
$c = '<connection_name>'
snow stage copy "$r\app.py"          "@MENDIX_APP.AGENTS.STREAMLIT_STAGE"       --overwrite -c $c
snow stage copy "$r\ui.py"           "@MENDIX_APP.AGENTS.STREAMLIT_STAGE"       --overwrite -c $c
snow stage copy "$r\i18n.py"         "@MENDIX_APP.AGENTS.STREAMLIT_STAGE"       --overwrite -c $c
snow stage copy "$r\environment.yml" "@MENDIX_APP.AGENTS.STREAMLIT_STAGE"       --overwrite -c $c
snow stage copy "$r\pages"           "@MENDIX_APP.AGENTS.STREAMLIT_STAGE/pages" --overwrite -c $c
```

**Option B — Snowsight:** `Ingestion → Load files into a Stage → STREAMLIT_STAGE`.
Remember that the 6 page files must land under the `pages/` path.

**Option C — ask the IDE** to run `PUT` (the IDE has a client; the worksheet does not).

### Reconciliation table — 10 files; size and MD5 must match exactly

| File | Bytes | MD5 |
|---|---|---|
| `app.py` | 9,471 | `344d5cfb90ef44d319b0016c0536efbd` |
| `ui.py` | 12,315 | `7892821ae4bd42a95a57fb9bab36c09b` |
| `i18n.py` | 84,731 | `2124032bda6e081e71094b90ab3dc75e` |
| `environment.yml` | 67 | `30937defe8f9052f2eff787fc0e7ffa5` |
| `pages/1_Documents.py` | 21,188 | `fa2d74361a0b6fcb04f1904d217d9e14` |
| `pages/2_Compliance.py` | 7,747 | `bee0ca7783046f9ceed6bec1f4a85731` |
| `pages/3_Fraud_Detection.py` | 9,302 | `59466af0d830e459880fa3ba6661bd04` |
| `pages/4_AI_FinOps.py` | 10,714 | `23fa6e9ea1d150b9cf109dfdcd882b4a` |
| `pages/5_Settings.py` | 1,590 | `569f74a218c16591ae7e7569b9a62f6c` |
| `pages/6_AI_Chat.py` | 23,056 | `37c00474e57934ade558fddd4d7dc1a3` |

Verify after uploading:

```sql
ALTER STAGE MENDIX_APP.AGENTS.STREAMLIT_STAGE REFRESH;
SELECT RELATIVE_PATH, SIZE, MD5
FROM DIRECTORY(@MENDIX_APP.AGENTS.STREAMLIT_STAGE)
ORDER BY RELATIVE_PATH;
```

`ALTER STAGE ... REFRESH` is mandatory — without it `DIRECTORY()` returns stale results.

**`ui.py` is the file people forget.** All 6 new pages `import ui`; without it the whole
app renders blank with `ModuleNotFoundError`.

Then force the app to reload the new files:

```sql
ALTER STREAMLIT MENDIX_APP.AGENTS.VF_LOGISTICS_DASHBOARD SET MAIN_FILE = 'app.py';
```

---

## 5. The trap: skip this step and the Compliance page renders FAILED for everything

The new `2_Compliance.py` reads the `status` and `issues` keys. The old version of
`CHECK_COMPLIANCE` returns `compliant` and `violations`, so **every result will render as
FAILED** regardless of whether it passed. Check:

```sql
CALL MENDIX_APP.AGENTS.CHECK_COMPLIANCE(
  (SELECT MIN(BL_ID) FROM MENDIX_APP.AGENTS.BILL_OF_LADING));
```

| Returned payload | Meaning | Action |
|---|---|---|
| Contains `status` and `issues` | Fixed version | Done, nothing to do |
| Contains `compliant` / `violations` | **Old version** | Redeploy the 2 procedures from the backup, below |

The fixed versions of `CHECK_COMPLIANCE` and `BATCH_CHECK_COMPLIANCE` live in:

```
backup_2026-08-19/ddl/chunks/60_procedures_1.sql .. 60_procedures_4.sql
```

Locate those two statements, run them, then backfill:

```sql
CALL MENDIX_APP.AGENTS.BATCH_CHECK_COMPLIANCE(0, 20000);

SELECT COUNT(*) AS TOTAL,
       SUM(IFF(COMPLIANCE_CHECK_PASSED, 1, 0))         AS PASSED,
       SUM(IFF(NOT COMPLIANCE_CHECK_PASSED, 1, 0))     AS FAILED,
       SUM(IFF(COMPLIANCE_CHECK_PASSED IS NULL, 1, 0)) AS NEVER_CHECKED
FROM MENDIX_APP.AGENTS.BILL_OF_LADING;
```
Expected: `NEVER_CHECKED = 0` and a failure rate of roughly **13.5%**.

After any `CREATE OR REPLACE PROCEDURE`, **re-grant**:

```sql
GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.CHECK_COMPLIANCE(NUMBER)
  TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON PROCEDURE MENDIX_APP.AGENTS.BATCH_CHECK_COMPLIANCE(NUMBER, NUMBER)
  TO ROLE HACKATHON_JUDGE_ROLE;
```

---

## 6. Final verification through the app itself

| # | Task | Expected |
|---|---|---|
| 1 | Open the app and click through all 7 pages | No page errors. A blank page means `ui.py` is missing |
| 2 | On the AI Chat page, ask `Top 5 carriers by revenue` | A result table plus a **View generated SQL** expander |
| 3 | **Press F5 to reload the whole page**, then reopen the conversation from the sidebar | **The transcript is intact, result tables included.** This is the only evidence that proves Fix 3 works |
| 4 | Switch language EN → 日本語 → Vietnamese | The UI actually changes; selecting Japanese does not fall back to Vietnamese |
| 5 | On the Compliance page, run a single B/L | A genuine `PASS`/`FAIL`, not FAILED for everything |

Step 3 matters most. Without a reload there is no way to distinguish chat persisted in
Snowflake from chat held in `st.session_state`.

---

## 7. Before you run: the local gate

```powershell
$r = 'C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\snowflake-backend\vf-logistics-hackathon'
$env:PYTHONIOENCODING = 'utf-8'
python "$r\tools\check_ui.py"
python "$r\tools\smoke_load_pages.py"
```

Expected: `checked 9 files, 348 translation keys x 3 languages` / `OK - safe to PUT` and
`all 7 pages loaded without raising`. Do not upload if either one fails.

---

## 8. Rollback

| What to revert | How |
|---|---|
| Chat SQL | `DROP TABLE CHAT_MESSAGE; DROP TABLE CHAT_SESSION; DROP SEQUENCE CHAT_SESSION_SEQ;` then drop the 6 procedures. Nothing else depends on them |
| Streamlit files | Re-upload the previous versions, or run `ALTER STREAMLIT ... SET MAIN_FILE = 'app.py'` after restoring the files |
| Compliance | `UPDATE BILL_OF_LADING SET COMPLIANCE_CHECK_PASSED = NULL;` to return to the unchecked state |

No rollback is needed if Step 1 reported `HAS_CHAT_MESSAGE = 0`: everything here is
additive, except `CHAT_SESSION` when the old analytics table exists.
