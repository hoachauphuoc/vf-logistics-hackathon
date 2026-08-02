import streamlit as st
from snowflake.snowpark.context import get_active_session
from i18n import rename_columns

st.set_page_config(page_title="Documents", page_icon="📄", layout="wide")
session = get_active_session()

# Language selector (synced across pages)
if "lang" not in st.session_state:
    st.session_state.lang = "EN"
with st.sidebar:
    lang = st.selectbox("🌐 Language", ["EN", "VN", "JA"], index=["EN","VN","JA"].index(st.session_state.lang), key="lang_docs")
    if lang != st.session_state.lang:
        st.session_state.lang = lang
        st.rerun()
lang = st.session_state.lang

st.title("📄 Bill of Lading Explorer" if lang == "EN" else "📄 Quản lý Vận đơn" if lang == "VN" else "📄 B/L管理")

# Filters
filter_label = {"EN": "🔍 Filters", "VN": "🔍 Bộ lọc", "JA": "🔍 フィルター"}[lang]
with st.expander(filter_label, expanded=True):
    fc1, fc2, fc3, fc4 = st.columns(4)
    with fc1:
        try:
            statuses = session.sql("SELECT DISTINCT STATUS FROM BILL_OF_LADING WHERE STATUS IS NOT NULL ORDER BY STATUS").to_pandas()["STATUS"].tolist()
            sel_status = st.multiselect({"EN":"Status","VN":"Trạng thái","JA":"ステータス"}[lang], statuses, default=[])
        except:
            sel_status = []
    with fc2:
        try:
            carriers = session.sql("SELECT DISTINCT CARRIER_NAME FROM BILL_OF_LADING ORDER BY CARRIER_NAME").to_pandas()["CARRIER_NAME"].tolist()
            sel_carrier = st.multiselect({"EN":"Carrier","VN":"Hãng tàu","JA":"キャリア"}[lang], carriers, default=[])
        except:
            sel_carrier = []
    with fc3:
        try:
            ports = session.sql("SELECT DISTINCT PORT_OF_LOADING_LOCODE FROM BILL_OF_LADING WHERE PORT_OF_LOADING_LOCODE IS NOT NULL ORDER BY 1").to_pandas()["PORT_OF_LOADING_LOCODE"].tolist()
            sel_port = st.multiselect({"EN":"Origin Port","VN":"Cảng xuất","JA":"積港"}[lang], ports, default=[])
        except:
            sel_port = []
    with fc4:
        search_text = st.text_input({"EN":"🔎 Search BL/Container","VN":"🔎 Tìm BL/Container","JA":"🔎 B/L検索"}[lang], "")

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
except:
    total_count = 0

PAGE_SIZE = 25
total_pages = max(1, (total_count + PAGE_SIZE - 1) // PAGE_SIZE)

pg_col1, pg_col2, pg_col3 = st.columns([2, 1, 2])
with pg_col2:
    page = st.number_input("Page", 1, total_pages, 1, label_visibility="collapsed")

st.caption(f"Showing page {page} of {total_pages} ({total_count:,} records)")

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
        # Size the grid to fit all rows on the page so no internal scroll is needed
        row_height = 35
        header_height = 38
        calculated_height = header_height + row_height * len(data) + 3
        st.dataframe(data, use_container_width=True, height=calculated_height)
    else:
        st.info("No records match the selected filters.")
except Exception as e:
    st.error(f"Query error: {str(e)[:150]}")

# Cortex Search
st.divider()
st.subheader("🧠 AI Semantic Search" if lang == "EN" else "🧠 Tìm kiếm AI")
search_col1, search_col2 = st.columns([4, 1])
with search_col1:
    semantic_query = st.text_input("Search by meaning...", placeholder="e.g. dangerous chemicals to Singapore")
with search_col2:
    do_search = st.button("🔍 Search", use_container_width=True)

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
            st.success(f"Found {len(parsed['results'])} relevant results")
            for r in parsed["results"]:
                st.markdown(f"**{r.get('BL_NUMBER','')}** | {r.get('STATUS','')} | {r.get('CARRIER_NAME','')} | ${r.get('TOTAL_CHARGES','')}")
        else:
            st.info("No results found")
    except Exception as e:
        st.warning(f"Search error: {str(e)[:100]}")

# Bulk actions
st.divider()
st.subheader("⚡ Quick Actions")
act_col1, act_col2, act_col3 = st.columns(3)
with act_col1:
    if st.button("✅ Approve All Pending (demo)", use_container_width=True):
        try:
            session.sql("UPDATE BILL_OF_LADING SET STATUS = 'APPROVED' WHERE STATUS = 'Pending_Review' AND BL_ID IN (SELECT BL_ID FROM BILL_OF_LADING WHERE STATUS = 'Pending_Review' LIMIT 10)").collect()
            st.success("Approved 10 pending shipments")
        except Exception as e:
            if "insufficient privileges" in str(e).lower():
                st.info("Read-only demo access — write actions are disabled for reviewers.")
            else:
                st.error(str(e)[:100])
with act_col2:
    if st.button("🤖 Classify Commodities (AI)", use_container_width=True):
        try:
            result = session.sql("CALL CLASSIFY_BATCH(5)").collect()[0][0]
            st.success(result)
        except Exception as e:
            if "insufficient privileges" in str(e).lower():
                st.info("Read-only demo access — write actions are disabled for reviewers.")
            else:
                st.error(str(e)[:100])
with act_col3:
    if st.button("🔄 Refresh Search Index", use_container_width=True):
        st.info("Search index refreshes automatically every hour")
