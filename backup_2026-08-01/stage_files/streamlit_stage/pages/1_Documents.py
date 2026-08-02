import streamlit as st
from snowflake.snowpark.context import get_active_session
from i18n import init_language, rename_columns

st.set_page_config(page_title="Documents", page_icon="📄", layout="wide")
session = get_active_session()
t = init_language()
lang = st.session_state.lang

st.title(t["bl_explorer_title"])

# Filters
with st.expander(t["filters"], expanded=True):
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
        # Size the grid to fit all rows on the page so no internal scroll is needed
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

# Bulk actions
st.divider()
st.subheader(t["quick_actions"])
st.caption(t["readonly_notice"])
if st.button(t["refresh_index"], use_container_width=True):
    st.info(t["refresh_index_info"])
