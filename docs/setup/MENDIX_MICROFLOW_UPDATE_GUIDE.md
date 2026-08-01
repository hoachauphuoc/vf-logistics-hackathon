# Guide: Update Microflow ACT_AnalyzeBillOfLading (FINAL — tested and working)

> ⚠️ This version fully replaces the old approach (a single Java Action that connected to JDBC itself +
> `BUILD_SCOPED_FILE_URL`). After extensive debugging, the final architecture does **NOT** have the Java
> Action connect to Snowflake for the upload itself — instead it reuses the already-stable connection
> from the Database Connector (also used for AI_COMPLETE).

## 📋 Overview
Update the microflow to:
1. Upload the PDF file to a Snowflake stage (via the Database Connector, not via a separate JDBC connection in Java)
2. Extract data with AI using a dynamic filename (not hardcoded)
3. Display the results in the UI

---

## 🧠 Why the architecture changed (read before you start)

Two fundamental limitations of the Snowflake JDBC driver force the flow to be split into several small steps:

1. **PUT does not accept bind parameters.** The JDBC driver extracts the local file path for the
   `PUT`/`GET` command using a regex over the **raw SQL text**, BEFORE bind parameters are substituted.
   Because of this, you cannot use `?`/`{n}` for the file path in PUT — the path must be concatenated
   directly as a literal into the SQL text.
   → You must use **"Execute Query"** (Sql = Expression, string concatenation) instead of
   **"Execute Parameterized Query"** for the PUT step.
2. **PUT does not rename the file on upload.** PUT always keeps the local file's basename and only
   uploads it into the specified prefix (folder). If the target path includes a filename, Snowflake
   interprets the whole string as a folder and appends the local basename to it → producing an
   incorrectly nested path (`bill_of_lading/name.pdf/name.pdf`).
   → The PUT target should only be a **folder** (`.../bill_of_lading/`), and the staged filename must
   be derived FROM the actual basename of the temp file (not generated independently).

---

## 🔧 Step 1: Create/verify the 3 Java Actions

All 3 must be created through the **Studio Pro UI** (App Explorer → right-click `actions` → Add other →
Java action). Simply copying the `.java` file into `javasource/` is **NOT** enough for it to appear as a
valid Java Action in the model.

### 1.1 `UploadFileToSnowflake`
- **Parameters**: `FileDocument` (type FileDocument)
- **Return type**: `String`
- **Purpose**: Writes the FileDocument's contents to a local temp file (`File.createTempFile`), returns
  the absolute path (normalized `\` → `/`). Does **NOT** connect to Snowflake itself.

### 1.2 `ComputeStagedPath`
- **Parameters**: `TempPath` (type **String**, NOT FileDocument)
- **Return type**: `String`
- **Purpose**: Extracts the basename from `TempPath` (the part after the last `/`), returns
  `"bill_of_lading/" + basename`. This ensures the path always matches the file that PUT will actually
  create on the stage.

### 1.3 `DeleteTempFile`
- **Parameters**: `TempPath` (String)
- **Return type**: `Boolean`
- **Purpose**: Deletes the temp file after it has been PUT to the stage.

After creating the 3 Java Actions through the UI, the actual code (BEGIN/END USER CODE) already lives in
the corresponding `.java` file under `javasource/vf_logistics_portal/actions/`.

---

## 🎯 Step 2: Final Microflow structure

```
Start
  → Has File?
    → (true)
        → Call UploadFileToSnowflake($BillOfLading_Doc)          → $TempPath (String)
        → Call ComputeStagedPath($TempPath)                       → $StagedPath (String)
        → Create object 'PutFileResult' (Commit = No)             → $NewPutFileResult
        → Execute Query (PUT command, NOT Parameterized)
             Result object: $NewPutFileResult
             Return type:  List of PutFileResult                  → $Variable_2 (not used further)
        → Call DeleteTempFile($TempPath)
        → Execute Parameterized Query (AI_COMPLETE, uses $StagedPath)
             Result object type: ShipmentRecord                   → $Variable_3 (List)
        → Head($Variable_3) → $FirstShipmentRecord
        → Change 'FirstShipmentRecord' (set Status, etc.)
        → ...
    → (false) Show Error
  → End
```

---

## 📝 Step 3: Configure each activity

### 3.1 `Call UploadFileToSnowflake`
- Input: `$BillOfLading_Doc`
- Output variable: `TempPath` (String)

### 3.2 `Call ComputeStagedPath`
- Input: `$TempPath`
- Output variable: `StagedPath` (String)

### 3.3 `Create object 'PutFileResult'`
- Entity: `PutFileResult`
- Commit: **No** (only needed as an instance to pass the generic type to Execute Query)
- Output variable: `NewPutFileResult`

### 3.4 `Execute Query` (PUT command) — **IMPORTANT: this is the "Execute Query" action, NOT "Execute Parameterized Query"**

The Database Connector module's Toolbox has 2 different actions:
| Action | Sql field | Bind parameters? |
|---|---|---|
| Execute Parameterized Query | Template + Parameters list (`{n}`) | Yes (uses PreparedStatement `?`) |
| **Execute Query** | 1 Expression returning the full SQL string | No — the SQL text is a literal |

Configuration:
- **Jdbc url**: `vf_logistics_portal.GetSnowflakeJdbcUrl()`
- **User name**: `'HOACHAU'`
- **Password**: (leave empty)
- **Sql** (Expression — note: escape single-quotes by **doubling them `''`**, not with `\'`):
  ```
  'PUT ''file://' + $TempPath + ''' @MENDIX_APP.AGENTS.LOGISTICS_STAGE/bill_of_lading/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE'
  ```
- **Result object**: `$NewPutFileResult` (must be a real OBJECT INSTANCE, not a type selector —
  because "Execute Query" infers the Java generic type from the argument's value, not from an entity
  dropdown like Parameterized Query does)
- **Return type**: List of `PutFileResult`

### 3.5 `Call DeleteTempFile`
- Input: `$TempPath`
- (Output not needed, just used to clean up the temp file)

### 3.6 `Execute Parameterized Query` (AI_COMPLETE) — **kept unchanged from the previous configuration**

This is the ONLY action that still uses Parameterized Query, since `PROMPT()`/`TO_FILE()` don't have the
same bind-parameter restriction as `PUT`. Paste the SQL from `SQL_AnalyzeBillOfLading_WithParameter.sql`:

```sql
WITH ai_result AS (
  SELECT REGEXP_REPLACE(
    AI_COMPLETE(
      'claude-sonnet-4-5',
      PROMPT(
        CONCAT(
          'Extract from this Bill of Lading: ContainerNumber, VesselName, ArrivalDate in YYYY-MM-DD, ',
          'GrossWeight in tons, AI_ConfidenceScore 0-100. ',
          'Score AI_ConfidenceScore based on extraction quality: start at 100 and deduct points for ',
          'each issue found - deduct 30 if any required field (ContainerNumber, VesselName, ArrivalDate, ',
          'GrossWeight) is missing/null, deduct 20 if text is blurry/unreadable or OCR quality is poor, ',
          'deduct 15 if a numeric field looks invalid (e.g. GrossWeight = 0) or a field contains garbled ',
          '/unexpected characters (e.g. ContainerNumber with symbols like @#$%), deduct 10 if dates are ',
          'inconsistent or implausible. Minimum score is 0. ',
          'Return ONLY raw JSON object, no markdown, no backticks. Document: ', CHR(123), '0', CHR(125)
        ),
        TO_FILE('@MENDIX_APP.AGENTS.LOGISTICS_STAGE', {1})
      )
    ),
    '^```json\\s*|\\s*```$', ''
  ) AS raw_text
)
SELECT
  PARSE_JSON(raw_text):"ContainerNumber"::STRING AS "ContainerNumber",
  PARSE_JSON(raw_text):"VesselName"::STRING AS "VesselName",
  TO_TIMESTAMP_NTZ(PARSE_JSON(raw_text):"ArrivalDate"::STRING, 'YYYY-MM-DD') AS "ArrivalDate",
  PARSE_JSON(raw_text):"GrossWeight"::FLOAT AS "GrossWeight",
  PARSE_JSON(raw_text):"AI_ConfidenceScore"::INTEGER AS "AI_ConfidenceScore",
  raw_text AS "RawAIResponse"
FROM ai_result;
```

**Note on `CHR(123)`**: Mendix's placeholder parser scans the ENTIRE SQL template text looking for any
`{n}` pattern, including inside string literals meant for `PROMPT()`. A literal `{0}` triggers the error
`CE0716: Place holder indices start at one (1)`. Solution: build the `{0}` string dynamically with
`CHR(123) || '0' || CHR(125)` so Mendix's parser doesn't see a literal `{0}` in the raw text.

- **Parameter `{1}`**: Any name, Type = String, Value = `$StagedPath`
- **Result object type**: `ShipmentRecord`

---

## 🗂️ Domain Model — Entity `PutFileResult` (non-persistable)

Columns returned by PUT when the JDBC connection uses `JDBC_QUERY_RESULT_FORMAT=JSON` (exactly as
configured in `GetSnowflakeJdbcUrl.java`): all lowercase, snake_case for compound names.

| Attribute (Mendix) | Type | Note |
|---|---|---|
| Source | String (unlimited) | |
| Target | String (unlimited) | |
| source_size | Long | **must be all lowercase**, not `SourceSize` |
| target_size | Long | **must be all lowercase** |
| source_compression | String | lowercase |
| target_compression | String | lowercase |
| Status | String (unlimited) | |
| Message | String (unlimited) | |
| encryption | String (unlimited) | lowercase |

---

## ✅ Step 4: Save & Test

1. **Ctrl+S** to save, verify no errors remain in the Errors panel
2. **Fully stop the app and Run again** (F5) — Java source (`.java`) changes are only picked up when the
   JVM is fully restarted; refreshing the browser (F5 in the browser) is NOT enough.
3. Test: Browse → select a PDF → Analyze
4. Expected results:
   - The actual file is uploaded to `@LOGISTICS_STAGE/bill_of_lading/<original basename of the temp file>`
   - AI correctly extracts data from the file just uploaded (not an old hardcoded file)
   - Data displays in the datagrid: Container Number, Vessel Name, Arrival Date, Gross Weight, AI
     Confidence Score

---

## 🐛 Troubleshooting

### `CE0117`/`CE7128` when configuring `Execute Query`
- **"The return type cannot be determined from the arguments... resultObject"**: the
  **Result object** field is empty or is an expression that doesn't return an instance. You must add a
  **Create object** step (entity=PutFileResult, Commit=No) beforehand and pass `$NewPutFileResult` in.

### `Database attribute 'X' is not in the entity 'PutFileResult'` / `does not contain the primitive 'X'`
- Wrong casing. Match EXACTLY the attribute table above (note `source_size`, `target_size`,
  `source_compression`, `target_compression`, `encryption` must all be lowercase).

### `Remote file '...' was not found` (after PUT reports SUCCESS)
- Check whether `ComputeStagedPath` is generating its own filename (a different timestamp) that doesn't
  match the actual basename of `$TempPath` — it must be fixed to derive the basename FROM `$TempPath`.
- Check that the PUT target path is only a **folder** (`.../bill_of_lading/`), without a filename appended.
- Use `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` to see the actual SQL text Mendix sent — if you see `?`
  not substituted in the file path, it means "Execute Parameterized Query" is being used for PUT (wrong)
  — switch it to "Execute Query" with Sql as a concatenated Expression.

### The exact same error persists after "fixing" it
- Studio Pro may not have reloaded the new Java class — you must **fully Stop and Run again** (not just
  refresh the browser with F5). Verify with `QUERY_HISTORY` that the new SQL was actually sent.

### `CE0716: Place holder indices start at one (1)`
- The AI_COMPLETE SQL template contains a literal `{0}` — build it dynamically with
  `CHR(123) || '0' || CHR(125)`.

---

## 📊 Verify the uploaded file on Snowflake

```sql
LIST @MENDIX_APP.AGENTS.LOGISTICS_STAGE/bill_of_lading/;

SELECT *
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())  -- or SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_TEXT ILIKE 'PUT %'
ORDER BY START_TIME DESC
LIMIT 10;
```

---

## 🎉 Confirmed working (real test)

Successful test result: upload a new file → AI extract →
`ContainerNumber=MSKU8731462, VesselName=MAERSK EMERALD, ArrivalDate=2025-01-28, GrossWeight=24.5,
AI_ConfidenceScore=100, Status=AI_Processed`.

**Ready for hackathon demo!** 🚀
