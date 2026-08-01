import streamlit as st
from snowflake.snowpark.context import get_active_session
from i18n import rename_columns

st.set_page_config(page_title="Fraud Detection", page_icon="🛡️", layout="wide")
session = get_active_session()

if "lang" not in st.session_state:
    st.session_state.lang = "EN"
with st.sidebar:
    lang = st.selectbox("🌐 Language", ["EN", "VN", "JA"], index=["EN","VN","JA"].index(st.session_state.lang), key="lang_fraud")
    if lang != st.session_state.lang:
        st.session_state.lang = lang
        st.rerun()
lang = st.session_state.lang

st.title("🛡️ Fraud Detection Center" if lang == "EN" else "🛡️ Trung tâm phát hiện gian lận" if lang == "VN" else "🛡️ 不正検知センター")

# KPIs
try:
    fraud_kpis = session.sql("""
        SELECT 
            COUNT(*) as TOTAL_ALERTS,
            SUM(CASE WHEN SEVERITY = 'HIGH' THEN 1 ELSE 0 END) as HIGH_SEV,
            SUM(CASE WHEN SEVERITY = 'MEDIUM' THEN 1 ELSE 0 END) as MED_SEV,
            SUM(CASE WHEN STATUS = 'OPEN' THEN 1 ELSE 0 END) as OPEN_ALERTS
        FROM FRAUD_ALERT
    """).collect()[0]
    
    k1, k2, k3, k4 = st.columns(4)
    with k1:
        st.metric("🚨 Total Alerts", fraud_kpis["TOTAL_ALERTS"])
    with k2:
        st.metric("🔴 High Severity", fraud_kpis["HIGH_SEV"])
    with k3:
        st.metric("🟡 Medium", fraud_kpis["MED_SEV"])
    with k4:
        st.metric("📂 Open", fraud_kpis["OPEN_ALERTS"])
except Exception as e:
    st.warning(f"Could not load fraud KPIs: {str(e)[:80]}")

st.divider()

# Actions
col1, col2, col3 = st.columns(3)

with col1:
    st.subheader("🔍 Run Fraud Scan")
    if st.button("🚀 Scan for Duplicates", use_container_width=True):
        with st.spinner("Scanning..."):
            try:
                result = session.sql("CALL DETECT_DUPLICATES(NULL)").collect()[0][0]
                st.success(f"Scan complete: {result}")
            except Exception as e:
                st.error(f"Scan error: {str(e)[:100]}")

with col2:
    st.subheader("📄 Ingest & Decide")
    st.caption("Processes every new PDF on the stage, promotes it, then decides.")
    if st.button("📥 Document → Decision", use_container_width=True):
        with st.spinner("Extract → promote → detect → investigate → screen → decide..."):
            try:
                import json
                raw = session.sql("CALL WORKFLOW_INGEST_AND_DECIDE()").collect()[0][0]
                st.success("Ingest and decide completed")
                try:
                    parsed = json.loads(raw)
                    st.caption(f"Extraction: {parsed.get('extraction', 'n/a')}")
                    promo = parsed.get("promotion", {})
                    if isinstance(promo, dict):
                        st.caption(f"Documents promoted: {promo.get('documents_promoted', '?')}")
                    pipe = parsed.get("pipeline", {})
                    if isinstance(pipe, dict):
                        st.metric("🤖 AI decision", pipe.get("ai_decision", "n/a"))
                        if pipe.get("ai_reason"):
                            st.caption(f"Reason: {pipe['ai_reason']}")
                    st.caption(f"Total time: {parsed.get('total_execution_time_ms', '?')} ms")
                except Exception:
                    st.code(raw, language="json")
            except Exception as e:
                st.error(f"Ingest error: {str(e)[:150]}")

with col3:
    st.subheader("⚡ Pipeline Demo")
    if st.button("🔗 Run Full Pipeline", type="primary", use_container_width=True):
        with st.spinner("Detect → AI Investigate → Sanctions Screen → AI-decided Remediation → SAP Post..."):
            try:
                import json
                raw = session.sql("CALL WORKFLOW_FULL_PIPELINE_V2('AUTO')").collect()[0][0]
                st.success("Pipeline completed")
                try:
                    parsed = json.loads(raw)
                    decision = parsed.get("ai_decision", "n/a")
                    reason = parsed.get("ai_reason", "")
                    st.metric("🤖 Autonomous AI decision", decision)
                    if reason:
                        st.caption(f"Reason: {reason}")
                    st.caption(f"Execution time: {parsed.get('execution_time_ms', '?')} ms — audit trail: WORKFLOW_AUDIT_LOG")
                except Exception:
                    st.code(raw, language="json")
            except Exception as e:
                st.error(f"Pipeline error: {str(e)[:150]}")

st.divider()

# Autonomous AI decisions with explanations
st.subheader("🧠 Autonomous AI Decisions — BLOCK / ESCALATE / CLEAR with reasoning")
st.caption(
    "Each row is an alert the AI reasoned over using a quantitative evidence pack "
    "(shipment cost-per-kg vs. the peer median across 10,000+ shipments, plus a live "
    "sanctions-list match count from Snowflake Marketplace data). The action shown was "
    "chosen by the model and then executed automatically — it is not a hardcoded outcome."
)
try:
    decisions = session.sql("""
        SELECT ALERT_ID, SEVERITY, ALERT_TYPE, BL_NUMBER, SHIPPER_NAME,
               TOTAL_CHARGES,
               ROUND(TOTAL_CHARGES / NULLIF(GROSS_WEIGHT_KGS, 0), 4) AS COST_PER_KG,
               ROUTE, AI_DECISION, AI_DECISION_REASON, ALERT_STATUS, AI_ANALYZED_AT
        FROM V_AI_DECISIONS
        ORDER BY AI_ANALYZED_AT DESC
        LIMIT 50
    """).to_pandas()

    if decisions.empty:
        st.info("No AI decisions recorded yet. Click 'Run Full Pipeline' above to generate one.")
    else:
        d1, d2, d3 = st.columns(3)
        with d1:
            st.metric("🛑 Blocked", int((decisions["AI_DECISION"] == "BLOCK").sum()))
        with d2:
            st.metric("⬆️ Escalated", int((decisions["AI_DECISION"] == "ESCALATE").sum()))
        with d3:
            st.metric("✅ Cleared", int((decisions["AI_DECISION"] == "CLEAR").sum()))

        st.dataframe(decisions, use_container_width=True, height=320)

        st.markdown("**Full AI risk assessment**")
        selected = st.selectbox(
            "Select an alert to read the complete reasoning the model produced",
            decisions["ALERT_ID"].tolist(),
            format_func=lambda a: f"Alert #{a} — {decisions.loc[decisions['ALERT_ID'] == a, 'AI_DECISION'].iloc[0]}",
        )
        if selected is not None:
            detail = session.sql(
                "SELECT AI_DECISION, AI_DECISION_REASON, AI_RISK_ASSESSMENT, RESOLUTION_NOTES "
                f"FROM V_AI_DECISIONS WHERE ALERT_ID = {int(selected)}"
            ).collect()
            if detail:
                row = detail[0]
                st.info(f"**Decision: {row['AI_DECISION']}** — {row['AI_DECISION_REASON']}")
                st.text(row["AI_RISK_ASSESSMENT"] or "No assessment text stored.")
                st.caption(f"Applied action recorded in the alert: {row['RESOLUTION_NOTES']}")
except Exception as e:
    st.warning(f"Could not load AI decisions: {str(e)[:120]}")

st.divider()

# Alert History
st.subheader("📋 Fraud Alert History")
try:
    alerts = session.sql("""
        SELECT ALERT_ID, ALERT_TYPE, SEVERITY, STATUS, 
               LEFT(DESCRIPTION, 100) as DESCRIPTION,
               COALESCE(DETECTED_AT, CREATED_AT) as DETECTED
        FROM FRAUD_ALERT 
        ORDER BY COALESCE(DETECTED_AT, CREATED_AT) DESC NULLS LAST
        LIMIT 50
    """).to_pandas()
    
    if not alerts.empty:
        st.dataframe(rename_columns(alerts, lang), use_container_width=True, height=400)
    else:
        st.info("No fraud alerts yet. Run a scan or pipeline demo to generate alerts.")
except Exception as e:
    st.warning(f"Could not load alerts: {str(e)[:80]}")

# Alert Distribution Chart
st.divider()
chart_col1, chart_col2 = st.columns(2)
with chart_col1:
    st.subheader("📊 Alerts by Type")
    try:
        type_data = session.sql("""
            SELECT ALERT_TYPE, COUNT(*) as COUNT 
            FROM FRAUD_ALERT GROUP BY ALERT_TYPE ORDER BY COUNT DESC
        """).to_pandas()
        if not type_data.empty:
            st.bar_chart(type_data.set_index("ALERT_TYPE")["COUNT"])
    except:
        st.info("No data for chart")

with chart_col2:
    st.subheader("📊 Alerts by Severity")
    try:
        sev_data = session.sql("""
            SELECT SEVERITY, COUNT(*) as COUNT 
            FROM FRAUD_ALERT GROUP BY SEVERITY ORDER BY COUNT DESC
        """).to_pandas()
        if not sev_data.empty:
            st.bar_chart(sev_data.set_index("SEVERITY")["COUNT"])
    except:
        st.info("No data for chart")
