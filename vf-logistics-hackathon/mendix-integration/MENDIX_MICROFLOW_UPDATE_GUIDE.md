# Guide: Updating the ACT_AnalyzeBillOfLading Microflow

## 📋 Overview
Update the microflow to:
1. Upload the PDF file to a Snowflake stage
2. Extract data using AI with a dynamic filename (no hardcoding)
3. Display the results in the UI

---

## 🔧 Step 1: Import the Java Action into Mendix

### 1.1 Copy the Java file into the Mendix project
```bash
# Copy UploadFileToSnowflake.java into:
C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\javasource\vf_logistics_portal\actions\
```

### 1.2 Refresh Mendix Studio Pro
1. Open **Mendix Studio Pro**
2. Click menu **App** → **Synchronize App Directory**
3. The Java action `UploadFileToSnowflake` will appear under **App Explorer** → **Java Actions**

---

## 🎯 Step 2: Update the Microflow Structure

### 2.1 Current Workflow (Old)
```
Start 
  → Has File? 
    → (true) Execute Query 
    → (false) Show Error
  → End
```

### 2.2 New Workflow
```
Start 
  → Has File? 
    → (true) 
      → [NEW] Call UploadFileToSnowflake
      → [UPDATE] Execute Query with Parameter
    → (false) Show Error
  → End
```

---

## 📝 Step 3: Add the Upload Activity

### 3.1 Open the Microflow
1. Double-click **ACT_AnalyzeBillOfLading** in **App Explorer**
2. The microflow editor will open

### 3.2 Add the Java Action Call
1. Drag **UploadFileToSnowflake** from the **Toolbox** → **Java Actions**
2. Place it **BETWEEN** the "Has File?" decision and the "Execute parameterized query" activity

### 3.3 Configure the Upload Action
**Double-click the UploadFileToSnowflake activity:**

**Tab "Action":**
- **FileDocument**: `$BillOfLading_Doc`

**Tab "Output":**
- **Variable name**: `StagedFilename`
- **Type**: `String`

**Note**: `$StagedFilename` will contain the file path on the stage, for example:
```
bill_of_lading/uploaded_1721741234567_invoice.pdf
```

---

## 🔗 Step 4: Update the Execute Query Activity

### 4.1 Double-click "Execute parameterized query"

### 4.2 Update the SQL Query
**Tab "Database Connection" → Section "SQL query template":**

**Delete the old SQL** and paste the new one from `SQL_AnalyzeBillOfLading_WithParameter.sql`:

```sql
WITH ai_result AS (
  SELECT REGEXP_REPLACE(
    SNOWFLAKE.CORTEX.COMPLETE(
      'claude-sonnet-4-5',
      CONCAT(
        'Extract from this Bill of Lading: ContainerNumber, VesselName, ArrivalDate in YYYY-MM-DD, ',
        'GrossWeight in tons, AI_ConfidenceScore 0-100. ',
        'Return ONLY raw JSON object, no markdown, no backticks.',
        BUILD_SCOPED_FILE_URL(@MENDIX_APP.AGENTS.LOGISTICS_STAGE, {FileName})
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
  PARSE_JSON(raw_text):"AI_ConfidenceScore"::INTEGER AS "AI_ConfidenceScore"
FROM ai_result
```

**Important**: Note this line:
```sql
BUILD_SCOPED_FILE_URL(@MENDIX_APP.AGENTS.LOGISTICS_STAGE, {FileName})
                                                          ^^^^^^^^^^
                                                          Parameter!
```

### 4.3 Add the SQL Parameter
**After pasting the SQL, click the "Add parameter" button:**

**Parameter configuration:**
- **Name**: `FileName` (must EXACTLY match `{FileName}` in the SQL)
- **Type**: `String`
- **Value**: `$StagedFilename` (variable from UploadFileToSnowflake)

---

## ✅ Step 5: Save & Test

### 5.1 Save the Microflow
- Press **Ctrl+S** to save
- Check there are no errors in the **Errors** panel

### 5.2 Run Locally
1. Click **Run Locally** (F5)
2. Wait for the app to start
3. Open a browser at: `http://localhost:8080`

### 5.3 Test the Workflow
1. Click **Browse...** → select a PDF file
2. Click the **Analyze** button
3. **Expected result**:
   - File is uploaded to `@LOGISTICS_STAGE/bill_of_lading/uploaded_xxx.pdf`
   - AI extracts data from the PDF
   - Data is displayed in the datagrid:
     - Container Number
     - Vessel Name
     - Arrival Date
     - Gross Weight
     - AI Confidence Score

---

## 🐛 Troubleshooting

### Error: "Java action not found"
**Solution**: 
1. Check that `UploadFileToSnowflake.java` is in the correct folder `javasource\vf_logistics_portal\actions\`
2. Synchronize App Directory again
3. Rebuild the project (F7)

### Error: "Parameter 'FileName' not found"
**Solution**:
1. Check the parameter name in the SQL query: `{FileName}` (case-sensitive!)
2. Check the parameter configuration: Name = `FileName`, Value = `$StagedFilename`

### Error: "JDBC driver error: missing user name"
**Solution**:
- The Java action is already configured with user = `HOACHAU`; no change needed

### Error: "File upload failed"
**Solution**:
1. Verify the private key file exists: `C:\Users\phuochoa\.snowflake\keys\snowflake_key.p8`
2. Verify the JDBC driver has been added to the Mendix project (userlib folder)
3. Check the Snowflake connection: does user HOACHAU have WRITE permission on the stage?

### File uploaded but AI extraction failed
**Solution**:
1. Verify the file on the stage:
   ```sql
   LIST @MENDIX_APP.AGENTS.LOGISTICS_STAGE/bill_of_lading/ PATTERN='uploaded_.*';
   ```
2. Test AI extraction manually in Snowflake:
   ```sql
   SELECT BUILD_SCOPED_FILE_URL(@MENDIX_APP.AGENTS.LOGISTICS_STAGE, 'bill_of_lading/uploaded_xxx.pdf');
   ```

---

## 📊 Checking Uploaded Files

After a successful test, check in Snowflake:

```sql
-- List all uploaded files
LIST @MENDIX_APP.AGENTS.LOGISTICS_STAGE/bill_of_lading/ 
PATTERN='uploaded_.*';

-- Count uploaded files
SELECT COUNT(*) 
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" LIKE '%uploaded_%';

-- Clean up test files (optional)
REMOVE @MENDIX_APP.AGENTS.LOGISTICS_STAGE/bill_of_lading/uploaded_*;
```

---

## 🎉 Done!

New workflow:
1. ✅ User uploads a PDF via the UI
2. ✅ File is uploaded to the Snowflake stage with a unique name
3. ✅ AI extracts data from the file the user selected (no hardcoding)
4. ✅ Data is displayed in the UI in real time

**Ready for hackathon demo!** 🚀
