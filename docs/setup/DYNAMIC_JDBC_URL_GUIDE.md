# Dynamic JDBC URL with Relative Path

> **DEPRECATED (2026-08-19):** Mendix integration was removed from the architecture.
> Account references below (`AYUGBCE-JX50275`) are historical. Current account: `SIKIWEQ-LP92053`.

## 🎯 Problem
We don't want to hardcode an absolute path in the JDBC URL:
```
❌ BAD: private_key_file=C:/Users/phuochoa/Mendix/.../snowflake_key.p8
✅ GOOD: private_key_file=<project_path>/resources/snowflake_key.p8
```

---

## ✅ Solution: Java Action `GetSnowflakeJdbcUrl`

File created: `javasource/vf_logistics_portal/actions/GetSnowflakeJdbcUrl.java`

### How it works:
```java
String projectPath = System.getProperty("user.dir");  // Dynamic!
String privateKeyPath = projectPath + "/resources/snowflake_key.p8";
return "jdbc:snowflake://AYUGBCE-JX50275.snowflakecomputing.com/..." + privateKeyPath;
```

---

## 📝 How to use it in Mendix

### Step 1: Import the Java Action

1. Open Mendix Studio Pro
2. **Synchronize App Directory** (F4 or Project menu)
3. The `GetSnowflakeJdbcUrl` Java action will appear in the Project Explorer

---

### Step 2: Update the Microflow

In microflow **ACT_AnalyzeBillOfLading**:

#### Option A: Call GetSnowflakeJdbcUrl before Execute Query

```
┌──────────────────────────────────────────────────────┐
│ Microflow: ACT_AnalyzeBillOfLading                   │
├──────────────────────────────────────────────────────┤
│                                                      │
│  [Start]                                             │
│     ↓                                                │
│  [Has File?] ──no──> [Show error]                   │
│     ↓ yes                                            │
│  [Call GetSnowflakeJdbcUrl]  ← ADD THIS!            │
│     ↓                                                │
│     Variable: $JdbcUrl (String)                      │
│     ↓                                                │
│  [Execute Parameterized Query]                       │
│     Input:                                           │
│       jdbcUrl = $JdbcUrl  ← USE VARIABLE!           │
│       userName = 'HOACHAU'                           │
│       ...                                            │
│     ↓                                                │
│  [Show results]                                      │
│     ↓                                                │
│  [End]                                               │
│                                                      │
└──────────────────────────────────────────────────────┘
```

#### Option B: Inline expression (if the Database Connector supports it)

In the field **"Argument for parameter 'jdbcUrl'"**, instead of a string literal:

```
$JdbcUrl
```

Where `$JdbcUrl` is set from a previous Java Action call.

---

## 🖥️ Step-by-step in Mendix Studio Pro

### Step 1: Open the Microflow
```
Project Explorer → Microflows → ACT_AnalyzeBillOfLading
Double-click to open
```

### Step 2: Add a Java Action Call

1. From the Toolbox, drag **"Java action call"** into the microflow
2. Place it **right after the "Has File?" decision** (true path)
3. Double-click the newly added activity

### Step 3: Configure the Java Action Call

```
┌────────────────────────────────────────────┐
│ Edit Java Action Call                      │
├────────────────────────────────────────────┤
│                                            │
│ Java action:                               │
│   [GetSnowflakeJdbcUrl          ▼]        │  ← Select this
│                                            │
│ Return value:                              │
│   Variable name: [JdbcUrl_________]        │  ← Name: JdbcUrl
│                                            │
│                    [OK]    [Cancel]        │
└────────────────────────────────────────────┘
```

### Step 4: Update the Execute Query Activity

Double-click the **"Execute Parameterized Query"** activity

In the field **"Argument for parameter 'jdbcUrl' (String)"**:

```
OLD: 'jdbc:snowflake://...'  (long hardcoded string)

NEW: $JdbcUrl                (variable from Java action)
```

**Screenshot guide:**
```
┌────────────────────────────────────────────────────┐
│ Edit Execute Parameterized Query                   │
├────────────────────────────────────────────────────┤
│ Input                                              │
│                                                    │
│ Jdbc url:    [$JdbcUrl              ▼]  [Edit]    │  ← Use variable!
│                                                    │
│ User name:   [Expression: 'HOACHAU'   ]           │
│                                                    │
│ Password:    [empty                    ]           │
│                                                    │
│ Sql:         [FROM ai_result          ]           │
│                                                    │
└────────────────────────────────────────────────────┘
```

---

## 🎬 Complete Workflow

```
1. User uploads PDF
   ↓
2. Decision: Has File? (Yes)
   ↓
3. Java Action: GetSnowflakeJdbcUrl()
   → Returns: "jdbc:snowflake://...private_key_file=/path/to/project/resources/snowflake_key.p8"
   → Store in: $JdbcUrl
   ↓
4. Execute Parameterized Query
   → jdbcUrl = $JdbcUrl (dynamic!)
   → userName = 'HOACHAU'
   → password = empty
   → sql = FROM ai_result
   ↓
5. Display results
```

---

## ✅ Benefits

| Aspect | Hardcoded Path | Dynamic Path (GetSnowflakeJdbcUrl) |
|--------|----------------|-------------------------------------|
| **Portability** | ❌ Breaks on different machines | ✅ Works everywhere |
| **Deployment** | ❌ Need to edit before deploy | ✅ Just copy the resources/ folder |
| **Maintenance** | ❌ Need to update if path changes | ✅ Automatic |
| **Team work** | ❌ Each dev has a different path | ✅ Same code for everyone |

---

## 🧪 Testing

### Verify the Java Action returns the correct path

Create a test microflow:

```
1. Call GetSnowflakeJdbcUrl → $TestUrl
2. Show message: $TestUrl
```

Expected output:
```
jdbc:snowflake://AYUGBCE-JX50275.snowflakecomputing.com/?authenticator=SNOWFLAKE_JWT&private_key_file=C:/Users/phuochoa/Mendix/VF_Logistics_Portal-main_2/resources/snowflake_key.p8&JDBC_QUERY_RESULT_FORMAT=JSON
```

---

## 🔄 Alternative: Combine with UploadFileToSnowflake

If you want a **single source of truth** for Snowflake config:

### Create a `SnowflakeConfig` Java class (Advanced)

```java
public class SnowflakeConfig {
    public static String getAccount() { return "AYUGBCE-JX50275"; }
    public static String getUser() { return "HOACHAU"; }
    public static String getDatabase() { return "MENDIX_APP"; }
    public static String getSchema() { return "AGENTS"; }
    public static String getWarehouse() { return "COMPUTE_WH"; }
    
    public static String getPrivateKeyPath() {
        String projectPath = System.getProperty("user.dir");
        return projectPath + "/resources/snowflake_key.p8";
    }
    
    public static String getJdbcUrl() {
        return String.format(
            "jdbc:snowflake://%s.snowflakecomputing.com/?authenticator=SNOWFLAKE_JWT&private_key_file=%s&JDBC_QUERY_RESULT_FORMAT=JSON",
            getAccount(),
            getPrivateKeyPath()
        );
    }
}
```

Then update both `UploadFileToSnowflake` and `GetSnowflakeJdbcUrl` to use this class.

**Benefit:** Change config in one place, apply to all!

---

## 📋 Summary

| Step | Action | Status |
|------|--------|--------|
| 1 | File `GetSnowflakeJdbcUrl.java` created | ✅ |
| 2 | Synchronize App Directory in Mendix | ⬜ |
| 3 | Add Java Action call in microflow | ⬜ |
| 4 | Store return value → $JdbcUrl | ⬜ |
| 5 | Update Execute Query → use $JdbcUrl | ⬜ |
| 6 | Test workflow | ⬜ |

---

**Next:** Synchronize App Directory and follow the steps above to integrate the Java Action into the microflow! 🚀
