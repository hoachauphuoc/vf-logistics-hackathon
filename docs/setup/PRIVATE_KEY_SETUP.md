# Snowflake Private Key Setup Guide

## 📍 Private Key Location

**File is located at:** `resources/snowflake_key.p8`

### Why the resources folder?
- ✅ Portable: Deployed together with the Mendix app
- ✅ Secure: No hardcoded absolute path
- ✅ Maintainable: Easy to manage within the project

---

## 🔧 Configuration Updates

> ⚠️ **Code location updated**: the account/user/private-key path configuration below now lives in
> `GetSnowflakeJdbcUrl.java` (shared by both the PUT step and AI_COMPLETE), **NOT**
> in `UploadFileToSnowflake.java` anymore (that file now only writes a temp file and no longer
> connects to Snowflake directly). The path/setup content is still accurate — only the file that
> holds the code has changed.

### 1. GetSnowflakeJdbcUrl.java (previously in UploadFileToSnowflake.java)
**Location:** `javasource/vf_logistics_portal/actions/GetSnowflakeJdbcUrl.java`

**Updated code (lines 91-100):**
```java
// === SNOWFLAKE CONFIG ===
String account = "YGVORDH-IA82097";
String user = "HOACHAU";
String database = "MENDIX_APP";
String schema = "AGENTS";
String warehouse = "COMPUTE_WH";

// Get private key from Mendix resources folder
String projectPath = System.getProperty("user.dir");
String privateKeyPath = projectPath + "/resources/snowflake_key.p8";
```

**What changed:**
- ❌ **Before:** `String privateKeyPath = "C:/Users/phuochoa/.snowflake/keys/snowflake_key.p8";`
- ✅ **After:** Dynamic path using `System.getProperty("user.dir")` + `/resources/snowflake_key.p8`

---

## 🔐 Security Best Practices

### Current Setup
- The private key is stored in the `resources/` folder
- The file is **NOT** committed to Git (already in `.gitignore`)

### For Production Deployment
There are 3 safer options:

#### Option 1: Snowflake Secret (Recommended)
```sql
-- Store private key as secret
CREATE SECRET snowflake_jwt_key
  TYPE = PASSWORD
  USERNAME = 'HOACHAU'
  PASSWORD = '<private_key_content>';
```

#### Option 2: Environment Variable
```java
String privateKeyPath = System.getenv("SNOWFLAKE_PRIVATE_KEY_PATH");
if (privateKeyPath == null) {
    privateKeyPath = projectPath + "/resources/snowflake_key.p8"; // fallback
}
```

#### Option 3: Mendix Constants
1. Create a constant in Mendix: `MyFirstModule.SnowflakePrivateKeyPath`
2. Set a different value for each environment (Dev/Test/Prod)
3. Read it in Java:
```java
String privateKeyPath = Core.getConfiguration().getConstantValue("MyFirstModule.SnowflakePrivateKeyPath").toString();
```

---

## ✅ Verification Steps

### 1. Check the file exists
```powershell
Test-Path "C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\resources\snowflake_key.p8"
# Should return: True
```

### 2. Test in Mendix
1. Deploy the app
2. Upload a PDF file
3. Click "Analyze"
4. If it succeeds → the private key path is correct ✅

### 3. Debug the path at runtime
Add a log to check the path:
```java
String projectPath = System.getProperty("user.dir");
String privateKeyPath = projectPath + "/resources/snowflake_key.p8";
System.out.println("DEBUG: Private key path: " + privateKeyPath);
System.out.println("DEBUG: File exists: " + new File(privateKeyPath).exists());
```

---

## 🚨 Troubleshooting

### Error: "private_key_file not found"
**Cause:** The Mendix runtime cannot find the file

**Solutions:**
1. Verify the file exists: `Test-Path "...\resources\snowflake_key.p8"`
2. Check file permissions (should be readable)
3. Try a temporary absolute path to test:
   ```java
   String privateKeyPath = "C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/resources/snowflake_key.p8";
   ```

### Error: "Invalid private key format"
**Cause:** The file is corrupted or in the wrong format

**Solution:**
1. Re-copy from the original:
   ```powershell
   Copy-Item "C:/Users/phuochoa/.snowflake/keys/snowflake_key.p8" `
             "C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\resources\snowflake_key.p8" -Force
   ```
2. Verify the format:
   ```powershell
   Get-Content "C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\resources\snowflake_key.p8" | Select-Object -First 1
   # Should see: -----BEGIN PRIVATE KEY-----
   ```

### Error: "JDBC driver authentication failed"
**Possible causes:**
1. The private key doesn't match the public key registered in Snowflake
2. User HOACHAU doesn't have the HAS_KEYPAIR flag set
3. Wrong account identifier

**Verify:**
```sql
-- Check keypair status
DESC USER HOACHAU;
-- Should see: HAS_KEYPAIR = true

-- Check public key fingerprint
SELECT RSA_PUBLIC_KEY_FP FROM USERS WHERE NAME = 'HOACHAU';
-- Should see: SHA256:lMohvE0waROAqUmZObjMB/7tFMXi70qE0ujwmohJUXo=
```

---

## 📋 Files Modified

| File | Change | Status |
|------|--------|--------|
| `resources/snowflake_key.p8` | Added (copied from ~/.snowflake/keys/) | ✅ |
| `javasource/vf_logistics_portal/actions/UploadFileToSnowflake.java` | Updated privateKeyPath to use resources/ | ✅ |

---

## 🔄 Next Steps

1. ✅ Private key copied into resources/
2. ✅ Java action updated to use the relative path
3. ⬜ Test the upload-file workflow in Mendix
4. ⬜ (Optional) Consider the production security options above

---

**Last Updated:** 2026-07-24  
**Environment:** Mendix Studio Pro + Snowflake Trial Account
