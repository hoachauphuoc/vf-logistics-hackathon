# Displaying PDFs from a Snowflake Stage in Mendix (using the TOFDocumentViewer widget)

## Already done (Snowflake + Java)

1. **Snowflake procedure** `MENDIX_APP.AGENTS.GET_PRESIGNED_URL_FOR_FILE(P_FILE_PATH VARCHAR)` — returns a presigned URL (1hr) for a file on `@MENDIX_APP.AGENTS.LOGISTICS_STAGE`. Tested OK.

2. **Java Action**: `javasource/vf_logistics_portal/actions/GetPdfBase64FromSnowflake.java`
   - Input: `FilePath` (String) — e.g. `bill_of_lading/uploaded_123_abc.pdf`
   - Internal logic: calls the procedure to get a presigned URL → HTTP GET to download the file → Base64 encode
   - Output: `String` (Base64 content of the PDF, or `ERROR: ...` on failure)
   - The `TOFDocumentViewer` widget only accepts `file` (FileDocument) or `base64File` (String Base64) — **it does not accept a URL directly**, hence this download + encode step is needed.

## What you need to do in Mendix Studio Pro

### Step 1 — Register the `GetPdfBase64FromSnowflake` Java Action
1. App Explorer → `VF_Logistics_Portal` → `actions` → right-click → **Add Java action**
2. Name: `GetPdfBase64FromSnowflake`
3. Tab **Parameters**: Add → Name = `FilePath`, Type = `String`
4. Tab **Return type**: `String`
5. Save. If Studio Pro overwrites the implementation code (leaving only `throw new MendixRuntimeException(...)`), let me know and I'll paste it back in.

### Step 2 — Add 2 attributes to the `BillOfLading_Doc` entity
| Attribute | Type | Purpose |
|---|---|---|
| `SnowflakeFilePath` | String (300) | Stores the file's path on the stage (from `ComputeStagedPath`, variable `$StagedPath`) |
| `PdfBase64Content` | String (unlimited) | Stores the Base64 PDF content for the widget to display |

> ⚠️ Update: the current microflow (after moving the PUT architecture to the Database Connector — see
> `MENDIX_MICROFLOW_UPDATE_GUIDE.md`) uses the variable `$StagedPath` (from the `ComputeStagedPath` Java
> Action), NOT `$StagedFilename` as in the old version.

### Step 3 — Merge everything into the "Analyze" microflow (no separate microflow/button needed)
Open the microflow that runs when the **Analyze** button is clicked. After the `ComputeStagedPath` step (result `$StagedPath`) and after the step that creates a new `BillOfLading_Doc`/`ShipmentRecord` from the AI analysis, add:

1. **Change object** on the just-created `BillOfLading_Doc`: `SnowflakeFilePath := $StagedPath`
2. **Java Action** `GetPdfBase64FromSnowflake`:
   - Input: `$StagedPath`
   - Output: `$Base64Result` (String)
3. **Change object** (same object): `PdfBase64Content := $Base64Result`
4. **Commit** (Yes)
5. Keep the existing list-refresh step as-is

→ No need to create a separate `ACT_LoadPdfPreview` microflow, and no need to add a "View original PDF" button on the `ShipmentRecord_NewEdit` page — because `PdfBase64Content` is already populated as soon as the record is created, before the user even has a chance to click through to view it.

### Step 4 — Place the TOFDocumentViewer widget on the page
Drag the **TOF PDF Document Viewer** widget onto the `ShipmentRecord_NewEdit` page, on the left side (per the layout you described: left = PDF, right = extracted information):

| Property | Value |
|---|---|
| **Base64 of document** | `PdfBase64Content` (attribute of `BillOfLading_Doc`) |
| Enable Zoom | true (optional) |
| Show toolbar | true |
| Width of document | 0 (dynamic width) or leave default |

No need to set the `File` property (skip it — we're using Base64, not a local FileDocument).

## Resulting workflow (already merged, no separate step needed)
1. **Click Analyze**: `UploadFileToSnowflake` (writes temp file) → `ComputeStagedPath` → `Execute Query` PUTs the file to the stage → `DeleteTempFile` → AI analysis (`SQL_AnalyzeBillOfLading_WithParameter`) → creates a new record → **within the same microflow**: `GetPdfBase64FromSnowflake` runs, getting the presigned URL + downloading + Base64 encoding → saves `SnowflakeFilePath` + `PdfBase64Content` on that record → Commit → refresh the list (the new record appears, e.g. row `TCLU3456789`)
2. **Click the pencil icon** on that record → navigates to `ShipmentRecord_NewEdit` → `PdfBase64Content` is already available from step 1 → the `TOFDocumentViewer` widget (left side) displays the PDF immediately, and the AI-extracted fields (right side) display at the same time — no waiting or extra clicks needed.

## Notes
- The demo PDF file (~4KB) is very small, so the download + Base64-encode step happens almost instantly and doesn't noticeably slow down the "Analyze" button. If a real file is much larger (several MB+), the Analyze button will take proportionally longer to finish (since it now does 3 things: upload, AI analyze, download-back + encode).
- This applies to files **newly uploaded through the current flow**. For the old 10k mock records (`BILL_OF_LADING`) that have no real file and never went through this "Analyze" flow, `PdfBase64Content` will be empty — the widget will simply show nothing (no error, just blank) — this is expected behavior, not a bug.
