# ✅ Completed: Dynamic PDF Upload & AI Extraction (FINAL architecture)

> ⚠️ This version replaces the earlier design description (a single Java Action doing JDBC-PUT itself +
> `BUILD_SCOPED_FILE_URL` + `SNOWFLAKE.CORTEX.COMPLETE`). The actual working architecture ended up
> different from the initial design, because the Snowflake JDBC driver has 2 unforeseen limitations:
> PUT does not accept bind parameters, and PUT does not rename the file on upload. See the detailed
> reasoning in `MENDIX_MICROFLOW_UPDATE_GUIDE.md`.

## 🎯 Problem Solved

**Before:**
- SQL **hardcoded** the filename: `BL_MAERSK_MAEU2026001_VALID.pdf`
- No file upload from the UI
- Always extracted the same file → not dynamic

**After:**
- User uploads a PDF via the UI
- The file is uploaded to a Snowflake stage (via the Database Connector's "Execute Query", not via a
  separate JDBC connection in the Java Action)
- AI extracts data from **the file the user just selected** (dynamic) using `AI_COMPLETE` + `PROMPT()` +
  `TO_FILE()` (multimodal document input, model `claude-sonnet-4-5`)
- Real-time data from the PDF → displayed in the UI

---

## 📦 Final architecture (tested end-to-end successfully)

```
Has File? --true--> UploadFileToSnowflake($BillOfLading_Doc)   -> $TempPath (String)
                  --> ComputeStagedPath($TempPath)               -> $StagedPath (String)
                  --> Create object 'PutFileResult'               -> $NewPutFileResult
                  --> Execute Query (PUT, Sql = concatenated Expression, NOT parameterized)
                        Result object: $NewPutFileResult
                  --> DeleteTempFile($TempPath)
                  --> Execute Parameterized Query (AI_COMPLETE, {1}=$StagedPath)
                        Result object type: ShipmentRecord
                  --> Head(...) -> FirstShipmentRecord -> ...
```

### 1. Java Action: `UploadFileToSnowflake.java`
**Location**: `javasource/vf_logistics_portal/actions/UploadFileToSnowflake.java`

- Input: `FileDocument` (FileDocument)
- Output: `String` — the absolute path of the local temp file (NOT the path on the stage)
- Logic: only reads the `FileDocument` content and writes it to `File.createTempFile(...)`. **No
  longer connects to Snowflake / JDBC itself** — the actual upload is done by the "Execute Query" (PUT)
  step in the microflow, reusing the already-proven-working connection used for AI_COMPLETE.

### 2. Java Action: `ComputeStagedPath.java`
**Location**: `javasource/vf_logistics_portal/actions/ComputeStagedPath.java`

- Input: `TempPath` (String — path to the temp file, NOT a FileDocument)
- Output: `String` — `"bill_of_lading/" + basename(TempPath)`
- Reason: PUT does not rename the file, it always keeps the local file's original basename when
  uploading to the stage. So the staged path must be COMPUTED FROM the actual basename, not generated
  with a separate timestamp (a mismatched, independently-generated name would cause a "Remote file not
  found" error).

### 3. Java Action: `DeleteTempFile.java`
**Location**: `javasource/vf_logistics_portal/actions/DeleteTempFile.java`

- Input: `TempPath` (String)
- Output: `Boolean`
- Logic: deletes the temp file after it has been successfully PUT to the stage, avoiding leftover
  files on the machine running the Mendix runtime.

### 4. Database Connector step "Execute Query" (PUT command)
- **DOES NOT** use "Execute Parameterized Query" — the Snowflake JDBC driver extracts the local file
  path for PUT using a regex over the raw SQL text, BEFORE bind parameter substitution, so `?`/`{n}`
  don't work for the file path in PUT.
- The Sql field is a concatenated **Expression**:
  ```
  'PUT ''file://' + $TempPath + ''' @MENDIX_APP.AGENTS.LOGISTICS_STAGE/bill_of_lading/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE'
  ```
- The target path is only a **folder** (`bill_of_lading/`), with no filename, since PUT appends the
  basename itself.
- The Jdbc url reuses `vf_logistics_portal.GetSnowflakeJdbcUrl()` (an existing Java Action, JWT auth).
- The Result object must be a real instance (`Create object 'PutFileResult'` beforehand) because
  "Execute Query" infers the Java generic type from the argument's value, unlike Parameterized Query
  which has a type selector.

### 5. Entity `PutFileResult` (non-persistable, newly created)
Columns returned by PUT when JDBC uses `JDBC_QUERY_RESULT_FORMAT=JSON`: all lowercase, snake_case for
compound names — `source`, `target`, `source_size`, `target_size`, `source_compression`,
`target_compression`, `status`, `message`, `encryption`.

### 6. SQL Query With Parameter: `SQL_AnalyzeBillOfLading_WithParameter.sql` (usage unchanged, just
needs the existing template to be correct)
**Location**: `snowflake-backend/SQL_AnalyzeBillOfLading_WithParameter.sql`

- Uses `AI_COMPLETE('claude-sonnet-4-5', PROMPT(..., TO_FILE(@stage, {1})))` — proper multimodal
  document input, replacing `CORTEX.COMPLETE` + `BUILD_SCOPED_FILE_URL` (the old approach).
- Parameter `{1}` = `$StagedPath` (from `ComputeStagedPath`).
- Note the `CHR(123) || '0' || CHR(125)` trick to prevent the Mendix parser from mistaking a literal
  `{0}` inside the Snowflake prompt text for its own placeholder syntax (`CE0716`).
- Output: `ContainerNumber`, `VesselName`, `ArrivalDate`, `GrossWeight`, `AI_ConfidenceScore`,
  `RawAIResponse` — mapped into the `ShipmentRecord` entity.

---

## ✅ Tested successfully (end-to-end)

Uploaded a new PDF file via the UI → PUT to stage → AI extraction → real result:
`ContainerNumber=MSKU8731462, VesselName=MAERSK EMERALD, ArrivalDate=2025-01-28, GrossWeight=24.5,
AI_ConfidenceScore=100, Status=AI_Processed` — displayed correctly in the `ShipmentRecord` overview.

---

## 🔧 If you need to set this up again from scratch

See the detailed step-by-step guide (with troubleshooting) in:
```
snowflake-backend/MENDIX_MICROFLOW_UPDATE_GUIDE.md
```

---

## 📝 Notes

- The `GetSnowflakeJdbcUrl` Java action builds the JDBC URL with JWT auth, shared by both the PUT step
  and the AI_COMPLETE step — a single source of configuration
  (`JDBC_QUERY_RESULT_FORMAT=JSON` in the URL).
- Private key file: `<mendix project>/resources/snowflake_key.p8` (relative path, no hardcoded absolute
  path — see `DYNAMIC_JDBC_URL_GUIDE.md`).
- Stage: `@MENDIX_APP.AGENTS.LOGISTICS_STAGE` (user `HOACHAU` has WRITE privilege).
- Current account: `YGVORDH-IA82097` (changed from the older account `cu84637.ap-southeast-7.aws`).

**Ready for hackathon demo!** 🚀
