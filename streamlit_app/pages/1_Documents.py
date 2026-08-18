import streamlit as st
from snowflake.snowpark.context import get_active_session
from i18n import init_language, rename_columns
import ui

st.set_page_config(page_title="Documents", page_icon="📄", layout="wide")
session = get_active_session()
t = init_language()
lang = st.session_state.lang

ui.page_header(
    t["bl_explorer_title"],
    "Cortex AI extraction → deterministic validation → review → SAP posting"
    if lang == "EN" else
    "Trích xuất Cortex AI → kiểm tra tất định → duyệt → gửi SAP"
    if lang == "VN" else
    "Cortex AI抽出 → 検証 → レビュー → SAP転記"
)

# --- Document Processing Section (replaces Mendix portal) ---
st.subheader("📤 Document Processing" if lang == "EN" else "📤 Xử lý Chứng từ" if lang == "VN" else "📤 書類処理")

st.info(
    "**To upload new PDFs:** In Snowsight left menu → **Ingestion** → **Load files into a Stage** → "
    "select `MENDIX_APP.AGENTS.LOGISTICS_STAGE` → path `bill_of_lading/` → drag & drop PDFs. "
    "Then click **Process** below."
    if lang == "EN" else
    "**Để upload PDF mới:** Menu trái Snowsight → **Ingestion** → **Load files into a Stage** → "
    "chọn `MENDIX_APP.AGENTS.LOGISTICS_STAGE` → path `bill_of_lading/` → kéo thả PDF. "
    "Sau đó bấm **Xử lý** bên dưới."
)

proc_col1, proc_col2 = st.columns(2)

with proc_col1:
    if st.button(
        "🔄 Process New PDFs on Stage" if lang == "EN" else "🔄 Xử lý PDF mới trên Stage" if lang == "VN" else "🔄 新規PDF処理",
        use_container_width=True
    ):
        with st.spinner("AI extracting fields from PDFs..." if lang == "EN" else "AI đang trích xuất..."):
            try:
                result = session.sql("CALL MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS()").collect()[0][0]
                st.success(result)
            except Exception as e:
                st.error(f"Error: {str(e)[:200]}")

with proc_col2:
    if st.button(
        "⚡ Ingest & Decide (Full Pipeline)" if lang == "EN" else "⚡ Nhập & Quyết định (Pipeline đầy đủ)" if lang == "VN" else "⚡ 取込＆判定",
        type="primary",
        use_container_width=True
    ):
        with st.spinner("Extract → Promote → Detect → Investigate → Screen → Decide..."):
            try:
                result = session.sql("CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE()").collect()[0][0]
                st.success("Pipeline completed!" if lang == "EN" else "Hoàn tất pipeline!")
                import json
                try:
                    parsed = json.loads(result)
                    c1, c2 = st.columns(2)
                    c1.metric("AI Decision", parsed.get("pipeline", {}).get("ai_decision", "N/A") if isinstance(parsed.get("pipeline"), dict) else "Done")
                    c2.metric("Time (ms)", parsed.get("total_ms", "N/A"))
                except Exception:
                    st.code(result, language="json")
            except Exception as e:
                st.error(f"Error: {str(e)[:200]}")

# Stage file count
try:
    stage_files = session.sql("""
        SELECT COUNT(*) as CNT FROM DIRECTORY(@MENDIX_APP.AGENTS.LOGISTICS_STAGE)
        WHERE RELATIVE_PATH ILIKE '%.pdf'
    """).collect()[0]["CNT"]
    extracted_count = session.sql("SELECT COUNT(*) as CNT FROM BILL_OF_LADING_EXTRACTED").collect()[0]["CNT"]
    m1, m2 = st.columns(2)
    m1.metric("PDFs on Stage" if lang == "EN" else "PDF trên Stage", stage_files)
    m2.metric("Extracted Documents" if lang == "EN" else "Đã trích xuất", extracted_count)
except Exception:
    pass

st.divider()

# --- Extracted Documents Review ---
st.subheader("📋 Extracted Documents" if lang == "EN" else "📋 Chứng từ Đã Trích Xuất" if lang == "VN" else "📋 抽出書類")
try:
    # Missing values are rendered as an em dash by ui.display_df rather than being
    # COALESCEd per column here. Streamlit prints a Python None as the literal text
    # "None", which in a shipping table reads like an extracted value instead of
    # absent data, and this app now has one shared mechanism for that everywhere.
    #
    # "Date of issue" is DATE_OF_ISSUE, the date the bill of lading was issued. It
    # was previously labelled "Arrival date", which is a different and unrelated
    # milestone and would mislead anyone reading the table.
    extracted_df = session.sql("""
        SELECT DOC_ID,
               CONTAINER_NUMBER   as "Container number",
               VESSEL_NAME        as "Vessel name",
               DATE_OF_ISSUE      as "Date of issue",
               GROSS_WEIGHT_KG    as "Gross weight",
               CONFIDENCE_SCORE   as "AI Confidence score",
               STATUS             as "Status",
               BL_NUMBER          as "BL Number",
               SHIPPER_NAME       as "Shipper",
               ALERT              as "Alert"
        FROM BILL_OF_LADING_EXTRACTED
        ORDER BY PROCESSED_AT DESC NULLS LAST
        LIMIT 20
    """).to_pandas()
    if not extracted_df.empty:
        ui.show_table(extracted_df)
    else:
        ui.empty_state("No extracted documents yet." if lang == "EN" else "Chưa có chứng từ trích xuất.")
except Exception as e:
    ui.load_error("Extracted documents", e)

# --- Review / Edit Document (replaces Mendix edit action) ---
st.subheader("✏️ Review Document" if lang == "EN" else "✏️ Duyệt Chứng từ" if lang == "VN" else "✏️ 書類レビュー")

# Document selector
try:
    doc_ids = session.sql("""
        SELECT DOC_ID, CONTAINER_NUMBER || ' - ' || COALESCE(VESSEL_NAME,'?') || ' (' || STATUS || ')' as LABEL
        FROM BILL_OF_LADING_EXTRACTED ORDER BY DOC_ID DESC LIMIT 50
    """).to_pandas()
    doc_options = dict(zip(doc_ids["DOC_ID"].tolist(), doc_ids["LABEL"].tolist()))
except Exception:
    doc_options = {}

if doc_options:
    selected_doc = st.selectbox(
        "Select document to review" if lang == "EN" else "Chọn chứng từ",
        options=list(doc_options.keys()),
        format_func=lambda x: f"DOC {x}: {doc_options.get(x, '')}",
        key="doc_selector"
    )

    # Load document detail
    try:
        doc = session.sql(f"""
            SELECT DOC_ID, FILE_NAME, BL_NUMBER, CONTAINER_NUMBER, VESSEL_NAME,
                   DATE_OF_ISSUE, GROSS_WEIGHT_KG, CONFIDENCE_SCORE, STATUS,
                   SHIPPER_NAME, CONSIGNEE_NAME, PORT_OF_LOADING, PORT_OF_DISCHARGE,
                   FREIGHT_CHARGES, ALERT, ALERT_RESPONSE,
                   PDF_PRESIGNED_URL
            FROM BILL_OF_LADING_EXTRACTED WHERE DOC_ID = {selected_doc}
        """).collect()[0]

        # Two-column layout like Mendix
        left_col, right_col = st.columns([1, 1])

        with left_col:
            st.markdown("**📄 Document Details**" if lang == "EN" else "**📄 Chi tiết Chứng từ**")
            st.markdown(f"**File:** `{doc['FILE_NAME']}`")
            st.markdown(f"**BL Number:** {doc['BL_NUMBER'] or 'N/A'}")
            st.markdown(f"**Shipper:** {doc['SHIPPER_NAME'] or 'N/A'}")
            st.markdown(f"**Consignee:** {doc['CONSIGNEE_NAME'] or 'N/A'}")
            st.markdown(f"**Route:** {doc['PORT_OF_LOADING'] or '?'} → {doc['PORT_OF_DISCHARGE'] or '?'}")
            st.markdown(f"**Freight:** ${doc['FREIGHT_CHARGES'] or 0:,.2f}")

            # PDF preview link - always generate fresh URL (presigned URLs expire after 1 hour)
            if st.button("📎 View PDF", key="gen_pdf_link"):
                try:
                    url = session.sql(f"CALL GET_PDF_URL({selected_doc})").collect()[0][0]
                    if url and str(url).startswith("http"):
                        st.markdown(
                            f'<a href="{url}" target="_blank" style="background:#1f77b4;color:white;'
                            f'padding:8px 16px;border-radius:4px;text-decoration:none;">'
                            f'⬇️ Download PDF — {doc["FILE_NAME"].split("/")[-1]}</a>'
                            f'<br><small style="color:#888;">PDF opens after download (SiS security limitation)</small>',
                            unsafe_allow_html=True
                        )
                    else:
                        st.caption(f"PDF issue: {str(url)[:100]}")
                except Exception as e:
                    st.caption(f"Could not generate link: {str(e)[:100]}")

            # Alert info
            if doc['ALERT'] and doc['ALERT'] != 'No anomalies detected':
                st.warning(f"**Alert:** {doc['ALERT']}")
                if doc['ALERT_RESPONSE']:
                    st.caption(doc['ALERT_RESPONSE'])
            else:
                st.success("No anomalies detected")

        with right_col:
            st.markdown("**✏️ Edit & Review**" if lang == "EN" else "**✏️ Chỉnh sửa & Duyệt**")

            # Editable fields
            edit_container = st.text_input("Container number", value=doc['CONTAINER_NUMBER'] or '', key="ed_container")
            edit_vessel = st.text_input("Vessel name", value=doc['VESSEL_NAME'] or '', key="ed_vessel")
            edit_date = st.text_input("Date of issue", value=str(doc['DATE_OF_ISSUE'] or ''), key="ed_date")
            edit_weight = st.text_input("Gross weight (kg)", value=str(doc['GROSS_WEIGHT_KG'] or ''), key="ed_weight")

            st.metric("AI Confidence", f"{doc['CONFIDENCE_SCORE'] or 0}/100")

            # STATUS is derived by the backend from the validation result and from
            # whether a SAP document actually exists, so it is shown read-only.
            # This used to be an st.radio, which was misleading twice over: the
            # selected value was never passed to REVIEW_DOCUMENT, so the control
            # did nothing at all, and it implied a reviewer could mark a flagged
            # document as Synced_To_SAP by hand.
            ui.readonly_field(
                "Status",
                doc['STATUS'] or ui.EM_DASH,
                "Derived from validation state: a document with anomalies stays in "
                "Pending_Review, and Synced_To_SAP requires a real SAP_FI_DOCUMENT."
                if lang == "EN" else
                "Suy ra từ kết quả kiểm tra: chứng từ có bất thường luôn ở "
                "Pending_Review, và Synced_To_SAP bắt buộc phải có SAP_FI_DOCUMENT thật."
            )

            st.markdown("---")

            # Action buttons
            btn_col1, btn_col2, btn_col3 = st.columns(3)
            with btn_col1:
                if st.button("✅ Approve", key="btn_approve", type="primary", use_container_width=True):
                    try:
                        import json
                        corrections = {}
                        if edit_container != (doc['CONTAINER_NUMBER'] or ''):
                            corrections["container_number"] = edit_container
                        if edit_vessel != (doc['VESSEL_NAME'] or ''):
                            corrections["vessel_name"] = edit_vessel
                        if edit_weight != str(doc['GROSS_WEIGHT_KG'] or ''):
                            try:
                                corrections["gross_weight_kg"] = float(edit_weight)
                            except ValueError:
                                pass
                        if edit_date != str(doc['DATE_OF_ISSUE'] or ''):
                            # The JSON key stays "arrival_date" because that is the
                            # key REVIEW_DOCUMENT parses; only the on-screen label was
                            # corrected to "Date of issue". Renaming the key here
                            # would silently stop date corrections being applied.
                            corrections["arrival_date"] = edit_date

                        if corrections:
                            cor_str = json.dumps(corrections).replace("'", "''")
                            result = session.sql(
                                f"CALL REVIEW_DOCUMENT({int(selected_doc)}, 'CORRECT', NULL, 'Approved with corrections', '{cor_str}')"
                            ).collect()[0][0]
                        else:
                            result = session.sql(
                                f"CALL REVIEW_DOCUMENT({int(selected_doc)}, 'APPROVE', NULL, 'Approved via Streamlit', NULL)"
                            ).collect()[0][0]
                        st.success(f"Approved! {result}")
                    except Exception as e:
                        st.error(str(e)[:150])

            with btn_col2:
                if st.button("❌ Reject", key="btn_reject", use_container_width=True):
                    try:
                        result = session.sql(
                            f"CALL REVIEW_DOCUMENT({int(selected_doc)}, 'REJECT', NULL, 'Rejected via Streamlit', NULL)"
                        ).collect()[0][0]
                        st.warning(f"Rejected. {result}")
                    except Exception as e:
                        st.error(str(e)[:150])

            with btn_col3:
                if st.button("🔄 Sync to SAP", key="btn_sap", use_container_width=True):
                    try:
                        # A document with unresolved anomalies must not reach SAP. This is
                        # the same rule the data-integrity fix enforces server-side; the
                        # check is repeated here so the reviewer gets told why, instead of
                        # the click silently producing a posted-but-invalid document.
                        blocking_alert = session.sql(f"""
                            SELECT BL_DOC_ALERT(BL_NUMBER, CONTAINER_NUMBER, VESSEL_NAME,
                                                GROSS_WEIGHT_KG, DATE_OF_ISSUE) AS A
                            FROM BILL_OF_LADING_EXTRACTED WHERE DOC_ID = {int(selected_doc)}
                        """).collect()[0]["A"]
                    except Exception as e:
                        blocking_alert = None
                        st.caption(f"Validation check unavailable: {str(e)[:80]}")

                    if blocking_alert:
                        st.error(
                            f"Cannot sync to SAP — unresolved anomalies: {blocking_alert}. "
                            "Correct the fields and approve first."
                            if lang == "EN" else
                            f"Không thể đồng bộ SAP — còn bất thường: {blocking_alert}. "
                            "Hãy sửa dữ liệu và duyệt trước."
                        )
                    else:
                        try:
                            # First approve, then sync
                            session.sql(
                                f"CALL REVIEW_DOCUMENT({int(selected_doc)}, 'APPROVE', NULL, 'Approved & synced', NULL)"
                            ).collect()
                            # Get associated BL_ID and post to SAP
                            bl_id_row = session.sql(f"SELECT BL_ID FROM BILL_OF_LADING_EXTRACTED WHERE DOC_ID = {selected_doc}").collect()
                            if bl_id_row and bl_id_row[0]['BL_ID']:
                                sap_result = session.sql(f"CALL SAP_POST_FI_DOCUMENT({bl_id_row[0]['BL_ID']})").collect()[0][0]
                                st.success(f"Synced to SAP! {sap_result}")
                            else:
                                st.success("Approved (no BL_ID linked yet for SAP)")
                        except Exception as e:
                            st.error(str(e)[:150])

    except Exception as e:
        st.error(f"Could not load document: {str(e)[:150]}")
else:
    st.info("No extracted documents to review." if lang == "EN" else "Không có chứng từ để duyệt.")

st.divider()

# --- Bill of Lading Explorer ---
st.subheader("🔍 Bill of Lading Explorer" if lang == "EN" else "🔍 Tra cuu Van don" if lang == "VN" else "🔍 B/L検索")

with st.expander(t["filters"], expanded=False):
    fc1, fc2, fc3, fc4 = st.columns(4)
    with fc1:
        try:
            statuses = session.sql("SELECT DISTINCT STATUS FROM BILL_OF_LADING WHERE STATUS IS NOT NULL ORDER BY STATUS").to_pandas()["STATUS"].tolist()
            sel_status = st.multiselect(t["status"], statuses, default=[])
        except Exception:
            sel_status = []
    with fc2:
        try:
            carriers = session.sql("SELECT DISTINCT CARRIER_NAME FROM BILL_OF_LADING ORDER BY CARRIER_NAME").to_pandas()["CARRIER_NAME"].tolist()
            sel_carrier = st.multiselect(t["carrier"], carriers, default=[])
        except Exception:
            sel_carrier = []
    with fc3:
        try:
            ports = session.sql("SELECT DISTINCT PORT_OF_LOADING_LOCODE FROM BILL_OF_LADING WHERE PORT_OF_LOADING_LOCODE IS NOT NULL ORDER BY 1").to_pandas()["PORT_OF_LOADING_LOCODE"].tolist()
            sel_port = st.multiselect(t["origin_port"], ports, default=[])
        except Exception:
            sel_port = []
    with fc4:
        search_text = st.text_input(t["search_bl_container"], "")

where_clauses = []
if sel_status:
    status_list = ",".join([f"'{s}'" for s in sel_status])
    where_clauses.append(f"STATUS IN ({status_list})")
if sel_carrier:
    carrier_list = ",".join([f"'{c}'" for c in sel_carrier])
    where_clauses.append(f"CARRIER_NAME IN ({carrier_list})")
if sel_port:
    port_list = ",".join([f"'{p}'" for p in sel_port])
    where_clauses.append(f"PORT_OF_LOADING_LOCODE IN ({port_list})")
if search_text:
    safe_search = search_text.replace("'", "''")
    where_clauses.append(f"(BL_NUMBER ILIKE '%{safe_search}%' OR CONTAINER_NUMBER ILIKE '%{safe_search}%' OR SHIPPER_NAME ILIKE '%{safe_search}%')")

where_sql = " WHERE " + " AND ".join(where_clauses) if where_clauses else ""

try:
    total_count = session.sql(f"SELECT COUNT(*) as C FROM BILL_OF_LADING{where_sql}").collect()[0]["C"]
except Exception:
    total_count = 0

PAGE_SIZE = 25
total_pages = max(1, (total_count + PAGE_SIZE - 1) // PAGE_SIZE)

pg_col1, pg_col2, pg_col3 = st.columns([2, 1, 2])
with pg_col2:
    page = st.number_input(t["page"], 1, total_pages, 1, label_visibility="collapsed")

st.caption(t["showing_page"].format(page=page, total_pages=total_pages, count=f"{total_count:,}"))

try:
    offset = (page - 1) * PAGE_SIZE
    data = session.sql(f"""
        SELECT BL_NUMBER, STATUS, CARRIER_NAME, VESSEL_NAME, 
               PORT_OF_LOADING_LOCODE as ORIGIN, PORT_OF_DISCHARGE_LOCODE as DEST,
               COMMODITY_DESCRIPTION as COMMODITY, TOTAL_CHARGES as CHARGES,
               GROSS_WEIGHT_KGS as WEIGHT_KG, CREATED_AT
        FROM BILL_OF_LADING{where_sql}
        ORDER BY CREATED_AT DESC NULLS LAST
        LIMIT {PAGE_SIZE} OFFSET {offset}
    """).to_pandas()

    if not data.empty:
        data = rename_columns(data, lang)
        row_height = 35
        header_height = 38
        calculated_height = header_height + row_height * len(data) + 3
        ui.show_table(data, height=calculated_height)
    else:
        ui.empty_state(t["no_records_match"])
except Exception as e:
    st.error(t["query_error"].format(err=str(e)[:150]))

# Cortex Search
st.divider()
st.subheader(t["semantic_search_title"])
search_col1, search_col2 = st.columns([4, 1])
with search_col1:
    semantic_query = st.text_input(t["search_by_meaning"], placeholder=t["search_placeholder"])
with search_col2:
    do_search = st.button(t["search_button"], use_container_width=True)

if do_search and semantic_query:
    try:
        safe_q = semantic_query.replace('"', '\\"')
        results = session.sql(f"""
            SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                'MENDIX_APP.AGENTS.BL_SEARCH_SERVICE',
                '{{"query": "{safe_q}", "columns": ["BL_NUMBER","STATUS","CARRIER_NAME","TOTAL_CHARGES"], "limit": 10}}'
            )) as R
        """).collect()[0]["R"]

        import json
        parsed = json.loads(str(results)) if isinstance(results, str) else results
        if "results" in parsed:
            st.success(t["found_results"].format(n=len(parsed["results"])))
            for r in parsed["results"]:
                st.markdown(f"**{r.get('BL_NUMBER','')}** | {r.get('STATUS','')} | {r.get('CARRIER_NAME','')} | ${r.get('TOTAL_CHARGES','')}")
        else:
            st.info(t["no_results_found"])
    except Exception as e:
        st.warning(t["search_error"].format(err=str(e)[:100]))
