# 🔧 Fix UploadFileToSnowflake Java Action Configuration

> ⚠️ **OUTDATED (debug history from 2026-07-24)**: This file documents how to configure the Parameters/Return type
> via the Studio Pro UI (that part of the process is still accurate), BUT **the "Backup Code" section below contains
> the old JDBC code that has since been completely removed** — `UploadFileToSnowflake` no longer connects to
> Snowflake/PUT directly, it only writes a temp file. See the current code + architecture in `IMPLEMENTATION_SUMMARY.md`
> and `MENDIX_MICROFLOW_UPDATE_GUIDE.md`. **Do NOT copy the "Backup Code" below into the project.**

## ❌ Current Problem

Mendix Studio Pro regenerated the file and lost the configuration:
- ❌ Return type: `Void` (wrong, needs to be `String`)  
- ❌ Parameters: none (wrong, needs `FileDocument`)
- ❌ Cannot compile: 9 errors

---

## ✅ Solution: Reconfigure in Mendix Studio Pro

### Step 1: Open the Java Action in Mendix Studio Pro

1. In the **Project Explorer**, navigate to:
   ```
   VF_Logistics_Portal
   └── Java actions
       └── UploadFileToSnowflake
   ```

2. **Double-click** `UploadFileToSnowflake` to open its settings

---

### Step 2: Configure Parameters (tab "Parameters")

Click the **"Parameters"** tab and add a parameter:

| Setting | Value |
|---------|-------|
| **Name** | `FileDocument` |
| **Type** | **Object** |
| **Entity** | `VF_Logistics_Portal.BillOfLading_Doc` (or `System.FileDocument`) |
| **Category** | Input parameter |

**Screenshot reference:**
```
┌─────────────────────────────────────┐
│ Parameters                          │
├─────────────────────────────────────┤
│ Name: FileDocument                  │
│ Type: Object ▼                      │
│ Entity: BillOfLading_Doc ▼          │
│ Category: ● Input  ○ Output         │
└─────────────────────────────────────┘
```

---

### Step 3: Configure Return Type (tab "Return type")

Click the **"Return type"** tab and set:

| Setting | Value |
|---------|-------|
| **Return type** | **String** |

**Screenshot reference:**
```
┌─────────────────────────────────────┐
│ Return type                         │
├─────────────────────────────────────┤
│ ● String                            │
│ ○ Boolean                           │
│ ○ Integer/Long                      │
│ ○ Decimal                           │
│ ○ Date and time                     │
│ ○ Object                            │
│ ○ List                              │
│ ○ Nothing                           │
└─────────────────────────────────────┘
```

---

### Step 4: Save and Regenerate

1. Click **OK** to save changes
2. Mendix will **automatically regenerate** the Java file
3. The new file will have the correct structure:
   ```java
   public class UploadFileToSnowflake extends CustomJavaAction<java.lang.String>
   {
       private final IMendixObject FileDocument;  // ← Parameter added
       
       public UploadFileToSnowflake(
           IContext context,
           IMendixObject _fileDocument  // ← Parameter in constructor
       )
       {
           super(context);
           this.FileDocument = _fileDocument;
       }
       
       @java.lang.Override
       public java.lang.String executeAction() throws Exception  // ← Returns String
       {
           // BEGIN USER CODE
           // Your code will be preserved here!
           // END USER CODE
       }
   }
   ```

---

### Step 5: Verify Code Preserved

**IMPORTANT:** After Mendix regenerates the file, check whether the code inside `BEGIN USER CODE` is still intact.

If it was lost → copy it back from the backup below.

---

## 📋 Backup Code (between BEGIN USER CODE / END USER CODE)

**Copy this snippet between `BEGIN USER CODE` and `END USER CODE` if it was lost:**

```java
// === VALIDATION ===
if (FileDocument == null) {
	return "ERROR: No file provided";
}

Boolean hasContents = (Boolean) FileDocument.getValue(getContext(), "HasContents");
if (hasContents == null || !hasContents) {
	return "ERROR: File has no contents";
}

// === GET FILE INFO ===
String originalName = (String) FileDocument.getValue(getContext(), "Name");
if (originalName == null || originalName.isEmpty()) {
	originalName = "document.pdf";
}

// Generate unique filename: uploaded_<timestamp>_<originalname>
long timestamp = System.currentTimeMillis();
String uniqueFilename = "uploaded_" + timestamp + "_" + originalName;
String stagedPath = "bill_of_lading/" + uniqueFilename;

// === WRITE FILE TO TEMP ===
File tempFile = null;
FileOutputStream fos = null;
try {
	// Create temp file
	tempFile = File.createTempFile("mendix_upload_", ".pdf");
	tempFile.deleteOnExit();

	// Get file stream from Mendix FileDocument
	InputStream fileStream = Core.getFileDocumentContent(getContext(), FileDocument);
	fos = new FileOutputStream(tempFile);

	// Copy stream to temp file
	byte[] buffer = new byte[8192];
	int bytesRead;
	while ((bytesRead = fileStream.read(buffer)) != -1) {
		fos.write(buffer, 0, bytesRead);
	}
	fos.flush();
	fos.close();
	fileStream.close();

} catch (Exception e) {
	return "ERROR: Failed to write temp file: " + e.getMessage();
}

// === SNOWFLAKE CONFIG ===
String account = "AYUGBCE-JX50275";
String user = "HOACHAU";
String database = "MENDIX_APP";
String schema = "AGENTS";
String warehouse = "COMPUTE_WH";

// Get private key from Mendix resources folder
String projectPath = System.getProperty("user.dir");
String privateKeyPath = projectPath + "/resources/snowflake_key.p8";

// === JDBC URL WITH JWT AUTH ===
String jdbcUrl = String.format(
	"jdbc:snowflake://%s.snowflakecomputing.com/?authenticator=SNOWFLAKE_JWT&private_key_file=%s&JDBC_QUERY_RESULT_FORMAT=JSON",
	account,
	privateKeyPath
);

Properties props = new Properties();
props.put("user", user);
props.put("db", database);
props.put("schema", schema);
props.put("warehouse", warehouse);
props.put("role", "ACCOUNTADMIN");

Connection conn = null;
Statement stmt = null;

try {
	// === CONNECT TO SNOWFLAKE ===
	Class.forName("net.snowflake.client.jdbc.SnowflakeDriver");
	conn = DriverManager.getConnection(jdbcUrl, props);
	stmt = conn.createStatement();

	// === UPLOAD FILE WITH PUT COMMAND ===
	String putCommand = String.format(
		"PUT 'file://%s' @MENDIX_APP.AGENTS.LOGISTICS_STAGE/%s AUTO_COMPRESS=FALSE OVERWRITE=TRUE",
		tempFile.getAbsolutePath().replace("\\", "/"),
		stagedPath
	);

	stmt.execute(putCommand);

	// === SUCCESS ===
	return stagedPath;

} catch (Exception e) {
	return "ERROR: Snowflake upload failed: " + e.getMessage();
} finally {
	// Cleanup
	if (stmt != null) try { stmt.close(); } catch (Exception e) {}
	if (conn != null) try { conn.close(); } catch (Exception e) {}
	if (tempFile != null && tempFile.exists()) {
		tempFile.delete();
	}
}
```

---

## 🔍 Verification

After configuration is complete:

### 1. Check the Java file structure
The file must have:
```java
public class UploadFileToSnowflake extends CustomJavaAction<java.lang.String>  // ← String, not Void
{
    private final IMendixObject FileDocument;  // ← Parameter exists
```

### 2. Try rebuilding
```
Right-click project → Clean deployment directory
F4 (Run locally)
```

If there are no errors → ✅ Success!

---

## 🚨 Common Issues

### Issue 1: "UserAction<Void>" instead of "CustomJavaAction<String>"
**Cause:** You selected the wrong class type in Mendix

**Fix:** 
1. Delete the Java action in Mendix
2. Recreate it with the correct settings
3. Copy the code into the BEGIN USER CODE section

### Issue 2: Code lost after saving
**Cause:** Code was placed outside the BEGIN USER CODE section

**Fix:** 
- Only edit code inside `BEGIN USER CODE` and `END USER CODE`
- Anything outside will be lost when Mendix regenerates the file

### Issue 3: Cannot find BillOfLading_Doc entity
**Cause:** The entity doesn't exist or the name is wrong

**Fix:**
- Use `System.FileDocument` instead of `BillOfLading_Doc`
- Or check the entity name in the Domain Model

---

## 📱 Alternative: Manually Edit File (Advanced)

If you don't want to use the Mendix Studio Pro UI, you can edit manually:

**⚠️ WARNING:** Only do this if you fully understand Mendix code generation!

Replace lines 20-25 with:
```java
public class UploadFileToSnowflake extends com.mendix.webui.CustomJavaAction<java.lang.String>
{
	private final IMendixObject FileDocument;

	public UploadFileToSnowflake(
		IContext context,
		IMendixObject _fileDocument
	)
	{
		super(context);
		this.FileDocument = _fileDocument;
	}
```

But this is **not recommended** since Mendix will overwrite it again!

---

## ✅ Summary

| Step | Action | Status |
|------|--------|--------|
| 1 | Open Java Action settings | ⬜ |
| 2 | Add parameter `FileDocument` (Object type) | ⬜ |
| 3 | Set return type to `String` | ⬜ |
| 4 | Save → Mendix regenerates the file | ⬜ |
| 5 | Verify code preserved in BEGIN USER CODE | ⬜ |
| 6 | Build project (F4) | ⬜ |
| 7 | No errors → ✅ Success! | ⬜ |

---

**Last Updated:** 2026-07-24  
**Issue:** Build errors after Mendix regeneration  
**Solution:** Reconfigure Java Action parameters and return type in Mendix Studio Pro
