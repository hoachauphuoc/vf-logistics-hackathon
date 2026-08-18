import streamlit as st
from snowflake.snowpark.context import get_active_session
from i18n import init_language, rename_columns

st.set_page_config(page_title="Documents", page_icon="📄", layout="wide")
session = get_active_session()
t = init_language()
lang = st.session_state.lang

st.title(t["bl_explorer_title"])

# --- PDF Upload & Process Section (replaces Mendix portal) ---
st.subheader("📤 Upload & Process Documents" if lang == "EN" else "📤 Tải lên & Xử lý Chứng từ" if lang == "VN" else "📤 書類アップロード＆処理")

upload_col, action_col = st.columns([3, 2])

with upload_col:
    uploaded_files = st.file_uploader(
        "Upload Bill of Lading PDFs" if lang == "EN" else "Tải lên PDF Vận đơn" if lang == "VN" else "B/L PDFをアップロード",
        type=["pdf"],
        accept_multiple_files=True,
        key="pdf_uploader"
    )

    if uploaded_files:
        st.info(f"{len(uploaded_files)} file(s) selected" if lang == "EN" else f"{len(uploaded_files)} tệp đã chọn")

with action_col:
    st.markdown("")
    st.markdown("")

    if uploaded_files:
        if st.button(
            "📥 Upload & Run Pipeline" if lang == "EN" else "📥 Tải lên & Chạy Pipeline" if lang == "VN" else "📥 アップロード＆パイプライン実行",
            type="primary", use_container_width=True
        ):
            progress_bar = st.progress(0)
            status_text = st.empty()

            # Step 1: Upload files to stage
            status_text.text("Uploading to stage..." if lang == "EN" else "Đang tải lên stage...")
            upload_count = 0
            for i, f in enumerate(uploaded_files):
                try:
                    session.file.put_stream(
                        f, f"@MENDIX_APP.AGENTS.LOGISTICS_STAGE/{f.name}",
                        auto_compress=False, overwrite=True
                    )
                    upload_count += 1
                except Exception as e:
                    st.warning(f"Upload failed for {f.name}: {str(e)[:80]}")
                progress_bar.progress((i + 1) / (len(uploaded_files) + 2))

            # Step 2: Process documents (OCR + extraction + validation)
            status_text.text("Processing documents with AI..." if lang == "EN" else "Đang xử lý chứng từ bằng AI...")
            progress_bar.progress(len(uploaded_files) / (len(uploaded_files) + 2))
            try:
                result = session.sql("CALL MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS()").collect()[0][0]
                progress_bar.progress(1.0)
                status_text.empty()
                st.success(
                    f"Done! Uploaded {upload_count} files. Result: {result}"
                    if lang == "EN" else
                    f"Hoàn tất! Đã tải {upload_count} tệp. Kết quả: {result}"
                )

                # Show extraction results
                with st.expander("Extraction Results" if lang == "EN" else "Kết quả trích xuất" if lang == "VN" else "抽出結果"):
                    recent = session.sql("""
                        SELECT FILE_NAME, BL_NUMBER, VESSEL_NAME, CONFIDENCE_SCORE, STATUS, ALERT
                        FROM BILL_OF_LADING_EXTRACTED
                        ORDER BY PROCESSED_AT DESC LIMIT 10
                    """).to_pandas()
                    if not recent.empty:
                        st.dataframe(recent, use_container_width=True)
            except Exception as e:
                progress_bar.progress(1.0)
                status_text.empty()
                st.error(f"Processing error: {str(e)[:200]}")

    else:
        if st.button(
            "🔄 Re-process Stage" if lang == "EN" else "🔄 Xử lý lại Stage" if lang == "VN" else "🔄 ステージ再処理",
            use_container_width=True
        ):
            with st.spinner("Processing new files on stage..." if lang == "EN" else "Đang xử lý file mới trên stage..."):
                try:
                    result = session.sql("CALL MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS()").collect()[0][0]
                    st.success(result)
                except Exception as e:
                    st.error(f"Error: {str(e)[:200]}")

    # Ingest & Decide (full pipeline from upload to AI decision)
    if st.button(
        "⚡ Ingest & Decide (Full)" if lang == "EN" else "⚡ Nhập & Quyết định (Đầy đủ)" if lang == "VN" else "⚡ 取込＆判定（全工程）",
        use_container_width=True
    ):
        with st.spinner("Extract → Promote → Detect → Investigate → Screen → Decide..." if lang == "EN" else "Trích xuất → Đưa vào → Phát hiện → Điều tra → Sàng lọc → Quyết định..."):
            try:
                result = session.sql("CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE()").collect()[0][0]
                st.success("Pipeline completed!" if lang == "EN" else "Hoàn tất pipeline!")
                import json
                try:
                    parsed = json.loads(result)
                    c1, c2 = st.columns(2)
                    c1.metric("AI Decision" if lang == "EN" else "Quyết định AI", parsed.get("pipeline", {}).get("ai_decision", "N/A"))
                    c2.metric("Time (ms)", parsed.get("total_ms", "N/A"))
                except Exception:
                    st.code(result, language="json")
            except Exception as e:
                st.error(f"Error: {str(e)[:200]}")

st.divider()

# --- Extracted Documents Review ---
st.subheader("📋 Recently Extracted Documents" if lang == "EN" else "📋 Chứng từ Đã Trích Xuất" if lang == "VN" else "📋 最近の抽出書類")
try:
    extracted_df = session.sql("""
        SELECT DOC_ID, FILE_NAME, BL_NUMBER, VESSEL_NAME, SHIPPER_NAME, 
               CONFIDENCE_SCORE, STATUS, ALERT, PROCESSED_AT
        FROM BILL_OF_LADING_EXTRACTED
        ORDER BY PROCESSED_AT DESC NULLS LAST
        LIMIT 20
    """).to_pandas()
    if not extracted_df.empty:
        st.dataframe(extracted_df, use_container_width=True)
    else:
        st.info("No extracted documents yet. Upload PDFs above to start." if lang == "EN" else "Chưa có chứng từ trích xuất. Hãy tải PDF ở trên.")
except Exception as e:
    st.caption(f"Could not load extracted docs: {str(e)[:80]}")

st.divider()

# --- Bill of Lading Explorer (existing) ---
st.subheader("🔍 Bill of Lading Explorer" if lang == "EN" else "🔍 Tra cứu Vận đơn" if lang == "VN" else "🔍 B/L検索")

# Filters
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

# Build query
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

# Pagination
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

# Data table
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
        st.dataframe(data, use_container_width=True, height=calculated_height)
    else:
        st.info(t["no_records_match"])
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
