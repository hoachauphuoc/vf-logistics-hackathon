# ⚡ Quick Fix Card: UploadFileToSnowflake Build Errors

> ⚠️ **OUTDATED (debug history from 2026-07-24)**. For the current architecture, see
> `MENDIX_MICROFLOW_UPDATE_GUIDE.md` (FINAL version, tested and working).

## 🚨 Current Error
```
error: cannot find symbol: variable FileDocument
error: incompatible types: String cannot be converted to Void
9 errors total
```

## ✅ Solution (5 minutes)

### 1️⃣ Open Java Action Settings
```
Project Explorer → Java actions → UploadFileToSnowflake
Double-click to open
```

### 2️⃣ Add Parameter
Tab **[Parameters]** → **[New]**
```
Name:     FileDocument
Type:     Object
Entity:   BillOfLading_Doc (or System.FileDocument)
Category: Input
```

### 3️⃣ Set Return Type
Tab **[Return type]**
```
Select: ⦿ String
(NOT "Nothing"!)
```

### 4️⃣ Save & Build
```
Click [OK]
Press F4 (Run)
```

## 📁 Files Created for Help
1. `FIX_JAVA_ACTION_CONFIG.md` - Detailed fix guide
2. `VISUAL_GUIDE_JAVA_ACTION.md` - Visual step-by-step with mock screenshots
3. `PRIVATE_KEY_SETUP.md` - Private key configuration

## 🆘 Need More Help?
See the detailed files:
- `snowflake-backend/FIX_JAVA_ACTION_CONFIG.md`
- `snowflake-backend/VISUAL_GUIDE_JAVA_ACTION.md`
