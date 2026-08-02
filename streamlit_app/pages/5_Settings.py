import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Settings", page_icon="⚙️", layout="wide")
session = get_active_session()
lang = st.session_state.get("lang", "EN")

st.title("⚙️ System Settings" if lang == "EN" else "⚙️ Cài đặt hệ thống")
st.caption(
    "View-only. This Streamlit app always runs with the app owner's privileges "
    "regardless of who is viewing it (Streamlit-in-Snowflake owner's-rights execution), "
    "so a save button here would let any visitor change shared config for everyone. "
    "Change these values from the CLI or a worksheet instead."
)

try:
    configs = session.sql("SELECT CONFIG_KEY, CONFIG_VALUE FROM APP_CONFIG").collect()
    config_dict = {row["CONFIG_KEY"]: row["CONFIG_VALUE"] for row in configs}
except Exception:
    config_dict = {}

st.subheader("🤖 AI Configuration")
col1, col2 = st.columns(2)
with col1:
    st.metric("AI Model", config_dict.get("AI_MODEL", "mistral-large2"))
with col2:
    st.metric("Fraud Confidence Threshold", f"{config_dict.get('FRAUD_CONFIDENCE_THRESHOLD', '70')}%")

st.divider()
st.subheader("💰 FinOps Settings")
col3, col4 = st.columns(2)
with col3:
    st.metric("Cost Alert (USD/day)", f"${config_dict.get('AI_COST_ALERT_THRESHOLD', '5.0')}")
with col4:
    st.metric("Cache TTL (seconds)", config_dict.get("CACHE_TTL_SECONDS", "600"))

st.divider()
st.subheader("📊 Current Config")
try:
    config_df = session.sql("SELECT CONFIG_KEY, CONFIG_VALUE FROM APP_CONFIG ORDER BY CONFIG_KEY").to_pandas()
    st.dataframe(config_df, use_container_width=True)
except Exception:
    st.info("Config unavailable")
