import streamlit as st
from snowflake.snowpark.context import get_active_session
from i18n import init_language

st.set_page_config(page_title="Settings", page_icon="⚙️", layout="wide")
session = get_active_session()
t = init_language()

st.title(t["settings_title"])
st.caption(t["settings_view_only_notice"])

try:
    configs = session.sql("SELECT CONFIG_KEY, CONFIG_VALUE FROM APP_CONFIG").collect()
    config_dict = {row["CONFIG_KEY"]: row["CONFIG_VALUE"] for row in configs}
except Exception:
    config_dict = {}

st.subheader(t["model_config"])
col1, col2 = st.columns(2)
with col1:
    st.metric(t["active_model"], config_dict.get("AI_MODEL", "mistral-large2"))
with col2:
    st.metric(t["threshold_label"], f"{config_dict.get('FRAUD_CONFIDENCE_THRESHOLD', '70')}%")

st.divider()
st.subheader(t["finops_config"])
col3, col4 = st.columns(2)
with col3:
    st.metric(t["cost_alert_metric"], f"${config_dict.get('AI_COST_ALERT_THRESHOLD', '5.0')}")
with col4:
    st.metric(t["cache_ttl_metric"], config_dict.get("CACHE_TTL_SECONDS", "600"))

st.divider()
st.subheader(t["all_config"])
try:
    config_df = session.sql("SELECT CONFIG_KEY, CONFIG_VALUE FROM APP_CONFIG ORDER BY CONFIG_KEY").to_pandas()
    st.dataframe(config_df, use_container_width=True)
except Exception:
    st.info(t["config_unavailable"])
