import streamlit as st
from snowflake.snowpark.context import get_active_session
from i18n import init_language, rename_columns
import ui

st.set_page_config(page_title="Documents", page_icon="📄", layout="wide")
session = get_active_session()
t = init_language()
# Still needed for rename_columns(), which maps DataFrame column names per language.
lang = st.session_state.lang

ui.page_header(t["bl_explorer_title"], t["doc_pipeline_subtitle"])

# --- Document Processing Section (replaces Mendix portal) ---
st.subheader(t["doc_processing"])

st.info(t["upload_instructions"])

proc_col1, proc_col2 = st.columns(2)

with proc_col1:
    if st.button(t["process_new_pdfs"], use_container_width=True):
        with st.spinner(t["extract_spinner"]):
            try:
                result = session.sql("CALL MENDIX_APP.AGENTS.PROCESS_BL_DOCUMENTS()").collect()[0][0]
                st.success(result)
            except Exception as e:
                st.error(t["generic_error"].format(err=str(e)[:200]))

with proc_col2:
    if st.button(t["ingest_decide"], type="primary", use_container_width=True):
        with st.spinner(t["ingest_spinner"]):
            try:
                result = session.sql("CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE()").collect()[0][0]
                st.success(t["ingest_success"])
                import json
                try:
                    parsed = json.loads(result)
                    pipeline = parsed.get("pipeline")
                    c1, c2 = st.columns(2)
                    c1.metric(
                        t["ai_decision_metric"],
                        pipeline.get("ai_decision", t["not_available"])
                        if isinstance(pipeline, dict) else t["not_available"],
                    )
                    c2.metric(t["m_time_ms"], parsed.get("total_ms", t["not_available"]))
                except Exception:
                    st.code(result, language="json")
            except Exception as e:
                st.error(t["ingest_error"].format(err=str(e)[:200]))

# Stage file count
try:
    stage_files = session.sql("""
        SELECT COUNT(*) as CNT FROM DIRECTORY(@MENDIX_APP.AGENTS.LOGISTICS_STAGE)
        WHERE RELATIVE_PATH ILIKE '%.pdf'
    """).collect()[0]["CNT"]
    extracted_count = session.sql("SELECT COUNT(*) as CNT FROM BILL_OF_LADING_EXTRACTED").collect()[0]["CNT"]
    m1, m2 = st.columns(2)
    m1.metric(t["m_pdfs_on_stage"], stage_files)
    m2.metric(t["m_extracted_docs"], extracted_count)
except Exception:
    pass

st.divider()

# --- Extracted Documents Review ---
st.subheader(t["extracted_docs_header"])
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
        ui.empty_state(t["no_extracted_docs"])
except Exception as e:
    ui.load_error("Extracted documents", e)

# --- Review / Edit Document (replaces Mendix edit action) ---
st.subheader(t["review_doc_header"])

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
        t["select_doc_review"],
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
            st.markdown(f"**{t['doc_detail']}**")
            st.markdown(f"**{t['f_file']}:** `{doc['FILE_NAME']}`")
            st.markdown(f"**{t['bl_number']}:** {doc['BL_NUMBER'] or ui.EM_DASH}")
            st.markdown(f"**{t['f_shipper']}:** {doc['SHIPPER_NAME'] or ui.EM_DASH}")
            st.markdown(f"**{t['f_consignee']}:** {doc['CONSIGNEE_NAME'] or ui.EM_DASH}")
            st.markdown(
                f"**{t['f_route']}:** {doc['PORT_OF_LOADING'] or ui.EM_DASH}"
                f" → {doc['PORT_OF_DISCHARGE'] or ui.EM_DASH}"
            )
            # Freight was printed as $0.00 when FREIGHT_CHARGES was NULL, which
            # asserts a zero charge the data never recorded. Absent stays absent.
            st.markdown(
                f"**{t['f_freight']}:** "
                + (f"${doc['FREIGHT_CHARGES']:,.2f}"
                   if doc['FREIGHT_CHARGES'] is not None else ui.EM_DASH)
            )

            # PDF preview link - always generate fresh URL (presigned URLs expire after 1 hour)
            if st.button(t["view_pdf"], key="gen_pdf_link"):
                try:
                    url = session.sql(f"CALL GET_PDF_URL({selected_doc})").collect()[0][0]
                    if url and str(url).startswith("http"):
                        label = t["download_pdf"].format(name=doc["FILE_NAME"].split("/")[-1])
                        st.markdown(
                            f'<a href="{url}" target="_blank" style="background:#1f77b4;color:white;'
                            f'padding:8px 16px;border-radius:4px;text-decoration:none;">'
                            f'{label}</a>'
                            f'<br><small style="color:#888;">{t["pdf_download_note"]}</small>',
                            unsafe_allow_html=True
                        )
                    else:
                        st.caption(t["pdf_issue"].format(err=str(url)[:100]))
                except Exception as e:
                    st.caption(t["pdf_link_error"].format(err=str(e)[:100]))

            # ALERT is NULL when the deterministic validator finds nothing. It used
            # to be stored as the English sentence "No anomalies detected", which
            # forced this branch to compare against an English magic string and
            # showed that sentence to Japanese and Vietnamese users. The sentinel is
            # now removed at source, so absence of an alert is simply NULL and the
            # reassuring message is a translated UI string.
            if doc['ALERT']:
                st.warning(t["alert_label"].format(v=doc['ALERT']))
                if doc['ALERT_RESPONSE']:
                    st.caption(doc['ALERT_RESPONSE'])
            else:
                st.success(t["no_anomalies"])

        with right_col:
            st.markdown(t["edit_review"])

            # Editable fields
            edit_container = st.text_input(t["f_container"], value=doc['CONTAINER_NUMBER'] or '', key="ed_container")
            edit_vessel = st.text_input(t["f_vessel"], value=doc['VESSEL_NAME'] or '', key="ed_vessel")
            edit_date = st.text_input(t["f_date_issue"], value=str(doc['DATE_OF_ISSUE'] or ''), key="ed_date")
            edit_weight = st.text_input(t["f_gross_weight"], value=str(doc['GROSS_WEIGHT_KG'] or ''), key="ed_weight")

            st.metric(t["ai_confidence"], f"{doc['CONFIDENCE_SCORE'] or 0}/100")

            # STATUS is derived by the backend from the validation result and from
            # whether a SAP document actually exists, so it is shown read-only.
            # This used to be an st.radio, which was misleading twice over: the
            # selected value was never passed to REVIEW_DOCUMENT, so the control
            # did nothing at all, and it implied a reviewer could mark a flagged
            # document as Synced_To_SAP by hand.
            ui.readonly_field(
                t["f_status"],
                doc['STATUS'] or ui.EM_DASH,
                t["status_derived_help"],
            )

            st.markdown("---")

            # Action buttons
            btn_col1, btn_col2, btn_col3 = st.columns(3)
            with btn_col1:
                if st.button(t["btn_approve"], key="btn_approve", type="primary", use_container_width=True):
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
                        st.success(t["approved_msg"].format(v=result))
                    except Exception as e:
                        st.error(str(e)[:150])

            with btn_col2:
                if st.button(t["btn_reject"], key="btn_reject", use_container_width=True):
                    try:
                        result = session.sql(
                            f"CALL REVIEW_DOCUMENT({int(selected_doc)}, 'REJECT', NULL, 'Rejected via Streamlit', NULL)"
                        ).collect()[0][0]
                        st.warning(t["rejected_msg"].format(v=result))
                    except Exception as e:
                        st.error(str(e)[:150])

            with btn_col3:
                if st.button(t["btn_sync_sap"], key="btn_sap", use_container_width=True):
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
                        st.caption(t["validation_unavailable"].format(err=str(e)[:80]))

                    if blocking_alert:
                        st.error(t["cannot_sync"].format(v=blocking_alert))
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
                                st.success(t["synced_sap_msg"].format(v=sap_result))
                            else:
                                st.success(t["approved_no_bl"])
                        except Exception as e:
                            st.error(str(e)[:150])

    except Exception as e:
        st.error(t["doc_load_error"].format(err=str(e)[:150]))
else:
    st.info(t["no_docs_to_review"])

st.divider()

# --- Bill of Lading Explorer ---
st.subheader(t["bl_search_header"])

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
        # No explicit height. This table used to set
        #     height = 38 + 35 * len(data) + 3
        # to force all 25 rows to be visible at once, but 35px was a guess at
        # Streamlit's row height. Whenever a cell wrapped, the content exceeded
        # the container and the grid grew its own scrollbar nested inside the
        # page's - so the wheel scrolled the table until it bottomed out and only
        # then scrolled the page. It also made this one panel ~900px tall while
        # every other table in the app used the default, so the pages scrolled
        # inconsistently. Letting Streamlit size the grid keeps one scroll
        # behaviour everywhere.
        ui.show_table(data)
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
