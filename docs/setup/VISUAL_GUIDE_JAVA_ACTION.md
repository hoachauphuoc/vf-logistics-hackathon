# 📸 Visual Guide: Configure UploadFileToSnowflake Java Action

> ⚠️ **OUTDATED (debug history from 2026-07-24)**: The mechanics of opening the Parameters/Return type
> dialog/tabs in Studio Pro are still accurate, but the specific code example in this file (JDBC PUT in Java)
> has since been removed. The current code for `UploadFileToSnowflake` only writes a temp file (the returned
> String is `TempPath`, not a staged path). See the current architecture in `MENDIX_MICROFLOW_UPDATE_GUIDE.md`.

## 🎯 Goal
Fix 9 compile errors by correctly configuring the Java Action in Mendix Studio Pro

---

## 📋 Quick Checklist

```
□ Step 1: Find the Java Action in Project Explorer
□ Step 2: Double-click to open the settings dialog
□ Step 3: Add Parameter "FileDocument" 
□ Step 4: Set Return Type "String"
□ Step 5: Save → Mendix auto-regenerates
□ Step 6: Rebuild (F4)
□ Step 7: Verify no errors ✅
```

---

## 🖼️ Step 1: Find the Java Action

**Location in Project Explorer:**

```
📁 VF_Logistics_Portal
├── 📁 Domain model
├── 📁 Microflows
├── 📁 Pages
├── ⚡ Java actions                     ← Click here
│   ├── CallCortexAgent
│   ├── ExecuteSQL
│   ├── GetAgentResponse
│   └── ⚠️ UploadFileToSnowflake       ← Double-click this!
└── 📁 Resources
```

**Action:** Double-click `UploadFileToSnowflake`

---

## 🖼️ Step 2: The Settings Dialog Opens

The dialog has 3 tabs:
```
┌──────────────────────────────────────────────────┐
│ Edit Java Action 'UploadFileToSnowflake'        │
├──────────────────────────────────────────────────┤
│ [General] [Parameters] [Return type]            │  ← these 3 tabs
│                                                  │
│  ... content here ...                           │
│                                                  │
│                          [OK] [Cancel] [Help]   │
└──────────────────────────────────────────────────┘
```

---

## 🖼️ Step 3: "Parameters" Tab

Click the **[Parameters]** tab → click **[New]** to add a parameter

### Settings to fill in:

```
┌──────────────────────────────────────────────────┐
│ Parameter Properties                             │
├──────────────────────────────────────────────────┤
│                                                  │
│  Name:     [FileDocument________________]        │  ← Name: FileDocument
│                                                  │
│  Type:     [Object          ▼]                  │  ← Select: Object
│                                                  │
│  Entity:   [BillOfLading_Doc  ▼]                │  ← Select entity
│            (or System.FileDocument)              │
│                                                  │
│  Category:                                       │
│   ⦿ Input                                        │  ← Select: Input
│   ○ Output                                       │
│                                                  │
│                          [OK] [Cancel]           │
└──────────────────────────────────────────────────┘
```

**After adding, you'll see:**
```
┌──────────────────────────────────────────────────┐
│ Parameters                                       │
├────────────┬──────────┬─────────────┬───────────┤
│ Name       │ Type     │ Entity      │ Category  │
├────────────┼──────────┼─────────────┼───────────┤
│ FileDoc... │ Object   │ BillOfLa... │ Input     │  ← Correct!
└────────────┴──────────┴─────────────┴───────────┘

         [New] [Edit] [Delete]    [▲] [▼]
```

---

## 🖼️ Step 4: "Return type" Tab

Click the **[Return type]** tab → select **String**

```
┌──────────────────────────────────────────────────┐
│ Return type                                      │
├──────────────────────────────────────────────────┤
│                                                  │
│  Select the return type:                        │
│                                                  │
│   ○ Boolean                                      │
│   ⦿ String                                       │  ← SELECT THIS!
│   ○ Integer/Long                                 │
│   ○ Decimal                                      │
│   ○ Date and time                                │
│   ○ Object                                       │
│   ○ List                                         │
│   ○ Nothing                                      │
│                                                  │
└──────────────────────────────────────────────────┘
```

**IMPORTANT:** 
- ❌ **Do NOT select "Nothing"** (this produces a `Void` return type)
- ✅ **Must select "String"** (to return the staged filename)

---

## 🖼️ Step 5: Save & Auto-Regenerate

1. Click **[OK]** to save

2. Mendix will show a message:
   ```
   ┌────────────────────────────────────────────┐
   │ Mendix Studio Pro                          │
   ├────────────────────────────────────────────┤
   │ Java action will be regenerated.           │
   │ Changes outside USER CODE will be lost.    │
   │                                             │
   │ Continue?                                   │
   │                           [Yes]    [No]     │
   └────────────────────────────────────────────┘
   ```
   
3. Click **[Yes]**

4. Mendix regenerates the file → check the **Output** window:
   ```
   Generating Java code...
   Java action 'UploadFileToSnowflake' has been regenerated.
   ```

---

## 🖼️ Step 6: Verify the Generated Code

Open `UploadFileToSnowflake.java` and check:

### ✅ Correct Structure:
```java
public class UploadFileToSnowflake extends CustomJavaAction<java.lang.String>  // ← String!
{
    private final IMendixObject FileDocument;  // ← Parameter exists!

    public UploadFileToSnowflake(
        IContext context,
        IMendixObject _fileDocument  // ← Constructor has parameter!
    )
    {
        super(context);
        this.FileDocument = _fileDocument;  // ← Assigned!
    }

    @java.lang.Override
    public java.lang.String executeAction() throws Exception  // ← Returns String!
    {
        // BEGIN USER CODE
        // ... your code here ...
        // END USER CODE
    }
}
```

### ❌ Wrong Structure (current):
```java
public class UploadFileToSnowflake extends UserAction<java.lang.Void>  // ← WRONG: Void!
{
    public UploadFileToSnowflake(IContext context)  // ← WRONG: No parameter!
    {
        super(context);
    }

    @java.lang.Override
    public java.lang.Void executeAction() throws Exception  // ← WRONG: Void!
    {
        // BEGIN USER CODE
        // ... code references FileDocument but it doesn't exist! ...
        // END USER CODE
    }
}
```

---

## 🖼️ Step 7: Build the Project

**Method 1: Keyboard Shortcut**
```
Press F4 (or F5)
```

**Method 2: Menu**
```
Run → Run Locally (F4)
```

**Expected Output:**
```
Compiling Java...
Starting application...
Build successful! ✅
```

**If errors still exist:**
```
Compiling Java...
❌ Error: cannot find symbol: FileDocument
❌ Error: incompatible types: String cannot be converted to Void
...
BUILD FAILED
```
→ Go back to Step 3 and check the configuration again!

---

## 🎬 Complete Workflow Animation

```
1. Double-click the Java Action
   ↓
2. Tab [Parameters] → [New]
   ↓
3. Add "FileDocument" (Object, Input)
   ↓
4. Tab [Return type] → Select "String"
   ↓
5. Click [OK] → Auto-regenerate
   ↓
6. Press F4 to build
   ↓
7. ✅ Success! (or go back to step 2)
```

---

## 🔍 Troubleshooting Visual Cues

### ❌ Problem: Cannot find the entity selector

**What you see:**
```
┌──────────────────────────────────────┐
│ Entity:  [_____________ ▼]           │  ← Empty dropdown!
└──────────────────────────────────────┘
```

**Solution:**
1. Type `System.FileDocument` manually
2. Or check if `BillOfLading_Doc` exists in the Domain Model

---

### ❌ Problem: Return type shows "Nothing" selected

**What you see:**
```
Return type:
  ○ String
  ○ Boolean
  ⦿ Nothing  ← THIS IS SELECTED!
```

**This causes:**
```java
public class UploadFileToSnowflake extends UserAction<java.lang.Void>
                                                              ^^^^
                                                          Problem here!
```

**Solution:**
- Select the **String** radio button
- Save again

---

## 📊 Before vs After Comparison

### BEFORE (Wrong - Current State)
```java
// Wrong signature
public class ... extends UserAction<Void>

// No parameter
public UploadFileToSnowflake(IContext context)

// Returns void
public Void executeAction() throws Exception

// Errors in code
if (FileDocument == null) {          // ← ERROR: FileDocument undefined
    return "ERROR: ...";             // ← ERROR: String → Void
}
```

### AFTER (Correct - After Configuration)
```java
// Correct signature
public class ... extends CustomJavaAction<String>

// Has parameter
public UploadFileToSnowflake(IContext context, IMendixObject _fileDocument)

// Returns String
public String executeAction() throws Exception

// No errors
if (FileDocument == null) {          // ✅ FileDocument exists
    return "ERROR: ...";             // ✅ String → String
}
```

---

## ✅ Final Verification Checklist

After following all steps, verify:

```
✓ Java file has: extends CustomJavaAction<java.lang.String>
✓ Java file has: private final IMendixObject FileDocument;
✓ Constructor has: IMendixObject _fileDocument parameter
✓ Method returns: java.lang.String (not Void)
✓ Build succeeds: No compilation errors
✓ Code preserved: Everything in BEGIN USER CODE still there
```

If all checked → **🎉 Success! Ready to test!**

---

**Next Step:** Follow `MENDIX_MICROFLOW_UPDATE_GUIDE.md` to integrate this Java Action into the microflow!
