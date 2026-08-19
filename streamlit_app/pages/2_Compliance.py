import streamlit as st
import json
from snowflake.snowpark.context import get_active_session
from i18n import init_language, rename_columns
import ui

st.set_page_config(page_title="Compliance", page_icon="✅", layout="wide")
session = get_active_session()
t = init_language()

ui.page_header(t["compliance_title"], t["compliance_subtitle"])

# Action buttons
action_col1, action_col2 = st.columns(2)

with action_col1:
    st.markdown(f"**{t['single_check']}**")
    # The upper bound is read from the data. It was hardcoded to 10010, but BL_ID
    # runs to 14315 (10,017 rows over a non-contiguous range), so every B/L above
    # 10010 was unreachable from this control.
    @st.cache_data(ttl=600)
    def get_bl_id_bounds():
        row = session.sql("SELECT MIN(BL_ID) AS LO, MAX(BL_ID) AS HI FROM BILL_OF_LADING").collect()[0]
        return int(row["LO"]), int(row["HI"])
    try:
        bl_lo, bl_hi = get_bl_id_bounds()
    except Exception:
        bl_lo, bl_hi = 1, 14315
    bl_id = st.number_input(t["f_bl_id"], min_value=bl_lo, max_value=bl_hi, value=bl_lo)
    if st.button(t["run_compliance"], type="primary"):
        with st.spinner(t["running_compliance"]):
            try:
                result = session.sql("CALL CHECK_COMPLIANCE(?)", params=[bl_id]).collect()[0][0]
                data = json.loads(result) if isinstance(result, str) else result
                
                if isinstance(data, dict):
                    status = data.get("overall_status", data.get("status", "UNKNOWN"))
                    if status in ("PASS", "OK", "COMPLIANT"):
                        st.success(t["compliance_passed"].format(id=bl_id))
                    elif status == "WARNING":
                        st.warning(t["compliance_warning"].format(id=bl_id))
                    else:
                        st.error(t["compliance_failed"].format(id=bl_id))
                    
                    issues = data.get("issues", data.get("checks", []))
                    if issues:
                        st.markdown(t["issues_found"])
                        for issue in (issues if isinstance(issues, list) else [issues]):
                            st.markdown(f"- {issue}")
                    
                    with st.expander(t["full_details"]):
                        for key, val in data.items():
                            st.markdown(f"**{key}:** {val}")
                else:
                    st.info(str(data))
            except Exception as e:
                st.error(t["compliance_error"].format(err=str(e)[:150]))

with action_col2:
    st.markdown(f"**{t['bulk_scan']}**")
    st.caption(t["bulk_scan_desc"])
    batch_size = st.number_input(t["batch_size"], min_value=10, max_value=200, value=50, key="compliance_batch")
    # Not type="primary": the page's primary action is the single check on the left.
    # Marking every button primary removes the hierarchy that makes one of them
    # primary in the first place.
    if st.button(t["run_bulk_scan"]):
        with st.spinner(t["scanning_compliance"]):
            try:
                import json as json_mod
                # Hours = 0 means all time. The page used to pass 24, and no row
                # has a CREATED_AT inside the last day, so Bulk Scan silently
                # examined nothing and reported "0 passed, 0 failed".
                result = session.sql("CALL BATCH_CHECK_COMPLIANCE(0, ?)", params=[batch_size]).collect()[0][0]
                data = json_mod.loads(result) if isinstance(result, str) else result
                passed = data.get("passed", 0) if isinstance(data, dict) else 0
                failed = data.get("failed", 0) if isinstance(data, dict) else 0
                remaining = data.get("not_checked_remaining") if isinstance(data, dict) else None
                st.success(f"✅ {t['scan_complete'].format(passed=passed, failed=failed)}")
                if remaining is not None:
                    st.caption(t["scan_remaining"].format(n=f"{int(remaining):,}"))
            except Exception as e:
                st.error(t["bulk_scan_error"].format(err=str(e)[:150]))

st.divider()

# Sanction Screening
st.subheader(t["sanction_title"])
party_name = st.text_input(t["company_screen"], placeholder=t["screen_placeholder"])

if st.button(t["screen_btn"]):
    with st.spinner(t["screening"]):
        try:
            result = session.sql("CALL SCREEN_SANCTIONS(?)", params=[party_name]).collect()[0][0]
            data = json.loads(result) if isinstance(result, str) else result
            
            if isinstance(data, dict):
                matches = data.get("matches_found", data.get("matches", 0))
                screened = data.get("entities_screened", data.get("total", 0))
                
                if matches and int(matches) > 0:
                    st.error(t["sanctions_match"].format(n=matches))
                    match_list = data.get("matched_entities", data.get("details", []))
                    if match_list and isinstance(match_list, list):
                        for m in match_list[:5]:
                            st.markdown(f"- ⚠️ {m}")
                else:
                    st.success(t["sanctions_clear"].format(name=party_name, n=f"{int(screened):,}"))
                
                with st.expander(t["full_screening_details"]):
                    for key, val in data.items():
                        st.markdown(f"**{key}:** {val}")
            else:
                st.info(str(data))
        except Exception as e:
            st.error(t["screening_error"].format(err=str(e)[:150]))

st.divider()

# DG Cargo
st.subheader(t["dg_title"])

@st.cache_data(ttl=600)
def get_dg_cargo():
    return session.sql("""
        SELECT b.BL_NUMBER, b.HS_CODE, h.DESCRIPTION, h.DG_CLASS,
               b.CARRIER_NAME, b.PORT_OF_DISCHARGE_LOCODE as DESTINATION
        FROM BILL_OF_LADING b
        JOIN HS_CODE_REFERENCE h ON b.HS_CODE LIKE h.HS_CODE || '%'
        WHERE h.IS_DANGEROUS_GOODS = TRUE LIMIT 20
    """).to_pandas()

try:
    dg_df = get_dg_cargo()
    if len(dg_df) > 0:
        st.warning(t["dg_found"].format(n=len(dg_df)))
        ui.show_table(rename_columns(dg_df.set_index("BL_NUMBER"), st.session_state.lang))
    else:
        st.success(t["dg_clear"])
except Exception as e:
    ui.load_error("Dangerous goods", e)

# Currency Conversion
st.divider()
st.subheader(t["currency_title"])
cx_col1, cx_col2, cx_col3 = st.columns(3)
with cx_col1:
    amount = st.number_input(t["amount"], value=1850.0)
with cx_col2:
    from_cur = st.selectbox(t["from"], ["USD", "VND", "JPY", "EUR", "CNY"])
with cx_col3:
    to_cur = st.selectbox(t["to"], ["VND", "JPY", "EUR", "CNY", "USD", "KRW", "SGD"])

if st.button(t["convert"]):
    try:
        result = session.sql("CALL GET_EXCHANGE_RATE(?, ?, ?)", params=[from_cur, to_cur, amount]).collect()[0][0]
        data = json.loads(result) if isinstance(result, str) else result
        
        r1, r2, r3 = st.columns(3)
        r1.metric(f"💵 {data.get('from', from_cur)}", f"{data.get('amount', amount):,.2f}")
        r2.metric(t["m_rate"], f"{data.get('rate', 0):,.4f}")
        r3.metric(f"💰 {data.get('to', to_cur)}", f"{data.get('converted', 0):,.2f}")
        
        rate_date = data.get('rate_date', t["not_available"])
        st.caption(f"{t['rate_date']}: {rate_date}")
        
        from datetime import datetime
        try:
            rd = datetime.strptime(rate_date, "%Y-%m-%d")
            days_old = (datetime.now() - rd).days
            if days_old > 7:
                st.warning(t["rate_stale"].format(n=days_old))
        except:
            pass
    except Exception as e:
        st.error(t["conversion_error"].format(err=str(e)[:150]))
