import streamlit as st
import json
from snowflake.snowpark.context import get_active_session
from i18n import init_language, translate_dynamic, rename_columns

st.set_page_config(page_title="Compliance", page_icon="✅", layout="wide")
session = get_active_session()
t = init_language()

st.title(t["compliance_title"])
st.caption(t["compliance_subtitle"])

# Action buttons
action_col1, action_col2 = st.columns(2)

with action_col1:
    st.markdown(f"**{t['single_check']}**")
    bl_id = st.number_input("B/L ID", min_value=1, max_value=10010, value=1)
    if st.button(t["run_compliance"], type="primary"):
        with st.spinner(t["running_compliance"]):
            try:
                result = session.sql(f"CALL CHECK_COMPLIANCE({bl_id})").collect()[0][0]
                data = json.loads(result) if isinstance(result, str) else result
                
                if isinstance(data, dict):
                    status = data.get("overall_status", data.get("status", "UNKNOWN"))
                    if status in ("PASS", "OK", "COMPLIANT"):
                        st.success(f"✅ B/L #{bl_id}: Compliance PASSED")
                    elif status == "WARNING":
                        st.warning(f"⚠️ B/L #{bl_id}: Compliance WARNING")
                    else:
                        st.error(f"🚨 B/L #{bl_id}: Compliance FAILED")
                    
                    issues = data.get("issues", data.get("checks", []))
                    if issues:
                        st.markdown("**Issues found:**")
                        for issue in (issues if isinstance(issues, list) else [issues]):
                            st.markdown(f"- {issue}")
                    
                    with st.expander("📋 Full Details"):
                        for key, val in data.items():
                            st.markdown(f"**{key}:** {val}")
                else:
                    st.info(str(data))
            except Exception as e:
                st.error(f"⚠️ Compliance check failed: {str(e)[:150]}")

with action_col2:
    st.markdown(f"**{t['bulk_scan']}**")
    st.caption(t["bulk_scan_desc"])
    batch_size = st.number_input(t["batch_size"], min_value=10, max_value=200, value=50, key="compliance_batch")
    if st.button(t["run_bulk_scan"], type="primary"):
        with st.spinner(t["scanning_compliance"]):
            try:
                import json as json_mod
                result = session.sql(f"CALL BATCH_CHECK_COMPLIANCE(24, {batch_size})").collect()[0][0]
                data = json_mod.loads(result) if isinstance(result, str) else result
                passed = data.get("passed", 0) if isinstance(data, dict) else 0
                failed = data.get("failed", 0) if isinstance(data, dict) else 0
                st.success(f"✅ {t['scan_complete'].format(passed=passed, failed=failed)}")
            except Exception as e:
                st.error(f"⚠️ Bulk scan failed: {str(e)[:150]}")

st.divider()

# Sanction Screening
st.subheader(t["sanction_title"])
party_name = st.text_input(t["company_screen"], placeholder="e.g. Nordic Maritime")

if st.button(t["screen_btn"]):
    with st.spinner(t["screening"]):
        try:
            safe_name = party_name.replace("'", "''")
            result = session.sql(f"CALL SCREEN_SANCTIONS('{safe_name}')").collect()[0][0]
            data = json.loads(result) if isinstance(result, str) else result
            
            if isinstance(data, dict):
                matches = data.get("matches_found", data.get("matches", 0))
                screened = data.get("entities_screened", data.get("total", 0))
                
                if matches and int(matches) > 0:
                    st.error(f"🚨 **{matches} match(es) found** against sanctions list!")
                    match_list = data.get("matched_entities", data.get("details", []))
                    if match_list and isinstance(match_list, list):
                        for m in match_list[:5]:
                            st.markdown(f"- ⚠️ {m}")
                else:
                    st.success(f"✅ **'{party_name}'** — No sanctions match (screened {int(screened):,} entities)")
                
                with st.expander("📋 Full Screening Details"):
                    for key, val in data.items():
                        st.markdown(f"**{key}:** {val}")
            else:
                st.info(str(data))
        except Exception as e:
            st.error(f"⚠️ Screening failed: {str(e)[:150]}")

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
        st.dataframe(rename_columns(dg_df.set_index("BL_NUMBER"), st.session_state.lang), use_container_width=True)
    else:
        st.success(t["dg_clear"])
except Exception as e:
    st.warning(f"⚠️ {str(e)[:100]}")

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

if st.button(t["convert"], type="primary"):
    try:
        safe_from = from_cur.replace("'", "''")
        safe_to = to_cur.replace("'", "''")
        result = session.sql(f"CALL GET_EXCHANGE_RATE('{safe_from}', '{safe_to}', {amount})").collect()[0][0]
        data = json.loads(result) if isinstance(result, str) else result
        
        r1, r2, r3 = st.columns(3)
        r1.metric(f"💵 {data.get('from', from_cur)}", f"{data.get('amount', amount):,.2f}")
        r2.metric("📈 Rate", f"{data.get('rate', 0):,.4f}")
        r3.metric(f"💰 {data.get('to', to_cur)}", f"{data.get('converted', 0):,.2f}")
        
        rate_date = data.get('rate_date', 'N/A')
        st.caption(f"{t['rate_date']}: {rate_date}")
        
        from datetime import datetime
        try:
            rd = datetime.strptime(rate_date, "%Y-%m-%d")
            days_old = (datetime.now() - rd).days
            if days_old > 7:
                st.warning(f"⚠️ Rate is {days_old} days old. Marketplace provider has not updated this currency pair recently.")
        except:
            pass
    except Exception as e:
        st.error(f"⚠️ Conversion failed: {str(e)[:150]}")
