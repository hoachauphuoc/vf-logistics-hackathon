import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Settings", page_icon="⚙️", layout="wide")
session = get_active_session()
lang = st.session_state.get("lang", "EN")

st.title("⚙️ System Settings" if lang == "EN" else "⚙️ Cài đặt hệ thống")

try:
    configs = session.sql("SELECT CONFIG_KEY, CONFIG_VALUE FROM APP_CONFIG").collect()
    config_dict = {row["CONFIG_KEY"]: row["CONFIG_VALUE"] for row in configs}
except:
    config_dict = {}

st.subheader("🤖 AI Configuration")
col1, col2 = st.columns(2)
with col1:
    current_model = config_dict.get("AI_MODEL", "mistral-large2")
    model_options = ["mistral-large2", "llama3-8b", "llama3.1-70b"]
    model_idx = model_options.index(current_model) if current_model in model_options else 0
    new_model = st.selectbox("AI Model", model_options, index=model_idx)
    if new_model != current_model:
        if st.button("Save Model"):
            session.sql("UPDATE APP_CONFIG SET CONFIG_VALUE = ? WHERE CONFIG_KEY = 'AI_MODEL'", params=[new_model]).collect()
            st.success(f"Updated to {new_model}")

with col2:
    current_threshold = int(float(config_dict.get("FRAUD_CONFIDENCE_THRESHOLD", "70")))
    new_threshold = st.slider("Fraud Confidence Threshold (%)", 0, 100, current_threshold, 5)
    if new_threshold != current_threshold:
        if st.button("Save Threshold"):
            session.sql("UPDATE APP_CONFIG SET CONFIG_VALUE = ? WHERE CONFIG_KEY = 'FRAUD_CONFIDENCE_THRESHOLD'", params=[str(new_threshold)]).collect()
            st.success(f"Updated to {new_threshold}%")

st.divider()
st.subheader("💰 FinOps Settings")
col3, col4 = st.columns(2)
with col3:
    current_cost = float(config_dict.get("AI_COST_ALERT_THRESHOLD", "5.0"))
    new_cost = st.number_input("Cost Alert (USD/day)", min_value=0.1, max_value=100.0, value=current_cost, step=0.5)
    if new_cost != current_cost:
        if st.button("Save Cost Alert"):
            session.sql("UPDATE APP_CONFIG SET CONFIG_VALUE = ? WHERE CONFIG_KEY = 'AI_COST_ALERT_THRESHOLD'", params=[str(new_cost)]).collect()
            st.success(f"Set to ${new_cost}")

with col4:
    current_cache = int(config_dict.get("CACHE_TTL_SECONDS", "600"))
    new_cache = st.number_input("Cache TTL (seconds)", min_value=60, max_value=3600, value=current_cache, step=60)
    if new_cache != current_cache:
        if st.button("Save Cache"):
            session.sql("UPDATE APP_CONFIG SET CONFIG_VALUE = ? WHERE CONFIG_KEY = 'CACHE_TTL_SECONDS'", params=[str(new_cache)]).collect()
            st.success(f"Set to {new_cache}s")

st.divider()
st.subheader("📊 Current Config")
try:
    config_df = session.sql("SELECT CONFIG_KEY, CONFIG_VALUE FROM APP_CONFIG ORDER BY CONFIG_KEY").to_pandas()
    st.dataframe(config_df, use_container_width=True)
except:
    st.info("Config unavailable")
