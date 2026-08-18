import streamlit as st
from snowflake.snowpark.context import get_active_session
from i18n import init_language, rename_columns
import ui

st.set_page_config(page_title="Fraud Detection", page_icon="🛡️", layout="wide")
session = get_active_session()
t = init_language()
lang = st.session_state.lang

ui.page_header(t["fraud_center_title"], t["fraud_pipeline_subtitle"])

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
        st.metric(t["fraud_alerts"], fraud_kpis["TOTAL_ALERTS"])
    with k2:
        st.metric(t["high_severity"], fraud_kpis["HIGH_SEV"])
    with k3:
        st.metric(t["medium_severity"], fraud_kpis["MED_SEV"])
    with k4:
        st.metric(t["total_open"], fraud_kpis["OPEN_ALERTS"])
    ui.caption_scope(t["scope_all_alerts"])
except Exception as e:
    ui.load_error("Fraud KPIs", e)

st.divider()

# Actions
col1, col2, col3 = st.columns(3)

with col1:
    st.subheader(t["run_fraud_scan"])
    if st.button(t["scan_for_duplicates"], use_container_width=True):
        with st.spinner(t["scanning"]):
            try:
                result = session.sql("CALL DETECT_DUPLICATES(NULL)").collect()[0][0]
                st.success(t["scan_complete_msg"].format(result=result))
            except Exception as e:
                st.error(t["scan_error_msg"].format(err=str(e)[:100]))

with col2:
    st.subheader(t["ingest_decide"])
    st.caption(t["ingest_decide_caption"])
    if st.button(t["doc_to_decision"], use_container_width=True):
        with st.spinner(t["ingest_spinner"]):
            try:
                import json
                raw = session.sql("CALL WORKFLOW_INGEST_AND_DECIDE()").collect()[0][0]
                st.success(t["ingest_success"])
                try:
                    parsed = json.loads(raw)
                    st.caption(t["extraction_label"].format(v=parsed.get('extraction', 'n/a')))
                    promo = parsed.get("promotion", {})
                    if isinstance(promo, dict):
                        st.caption(t["docs_promoted_label"].format(v=promo.get('documents_promoted', '?')))
                    pipe = parsed.get("pipeline", {})
                    if isinstance(pipe, dict):
                        st.metric(t["ai_decision_metric"], pipe.get("ai_decision", "n/a"))
                        if pipe.get("ai_reason"):
                            st.caption(t["reason_label"].format(v=pipe['ai_reason']))
                    st.caption(t["total_time_label"].format(v=parsed.get('total_execution_time_ms', '?')))
                except Exception:
                    st.code(raw, language="json")
            except Exception as e:
                st.error(t["ingest_error"].format(err=str(e)[:150]))

with col3:
    st.subheader(t["pipeline_demo"])
    if st.button(t["run_full_pipeline"], type="primary", use_container_width=True):
        with st.spinner(t["pipeline_spinner"]):
            try:
                import json
                raw = session.sql("CALL WORKFLOW_FULL_PIPELINE_V2('AUTO')").collect()[0][0]
                try:
                    parsed = json.loads(raw)
                    decision = parsed.get("ai_decision", "n/a")
                    reason = parsed.get("ai_reason", "")
                    if decision == "NONE":
                        st.warning(reason or "Pipeline ran, but there was no eligible HIGH-severity alert to investigate.")
                    else:
                        st.success(t["pipeline_success"])
                    st.metric(t["autonomous_decision_metric"], decision)
                    if reason:
                        st.caption(t["reason_label"].format(v=reason))
                    sap_posting = parsed.get("sap_posting")
                    if isinstance(sap_posting, dict) and sap_posting.get("status") == "SUCCESS":
                        st.caption(t["sap_posting_label"].format(v=sap_posting.get('sap_document', t["not_available"])))
                    st.caption(t["execution_time_label"].format(ms=parsed.get('execution_time_ms', '?')))
                except Exception:
                    st.success(t["pipeline_success"])
                    st.code(raw, language="json")
            except Exception as e:
                st.error(t["pipeline_error"].format(err=str(e)[:150]))

st.divider()

# Autonomous AI decisions with explanations
st.subheader(t["ai_decisions_header"])
st.caption(t["ai_decisions_caption"])
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
        ui.empty_state(t["no_ai_decisions"])
    else:
        d1, d2, d3 = st.columns(3)
        with d1:
            st.metric(t["blocked_metric"], int((decisions["AI_DECISION"] == "BLOCK").sum()))
        with d2:
            st.metric(t["escalated_metric"], int((decisions["AI_DECISION"] == "ESCALATE").sum()))
        with d3:
            st.metric(t["cleared_metric"], int((decisions["AI_DECISION"] == "CLEAR").sum()))
        # These three counts come from the LIMIT 50 query above, not from the whole
        # table. Without saying so they sit directly beneath the all-time KPIs and
        # read as a contradiction ("460 alerts" above, "50 decisions" below).
        ui.caption_scope(t["scope_recent_decisions"].format(n=len(decisions)))

        ui.show_table(decisions, height=320)

        st.markdown(t["full_assessment_label"])
        selected = st.selectbox(
            t["select_alert_label"],
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
                st.info(t["decision_prefix"].format(decision=row['AI_DECISION'], reason=row['AI_DECISION_REASON']))
                st.text(row["AI_RISK_ASSESSMENT"] or "No assessment text stored.")
                st.caption(t["applied_action_label"].format(v=row['RESOLUTION_NOTES']))
except Exception as e:
    ui.load_error("AI decisions", e)

st.divider()

# Alert History
st.subheader(t["alert_history_header"])
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
        ui.show_table(rename_columns(alerts, lang), height=400)
    else:
        ui.empty_state(t["no_alerts_yet"])
except Exception as e:
    ui.load_error("Alert history", e)

# Alert Distribution Chart
st.divider()
chart_col1, chart_col2 = st.columns(2)
with chart_col1:
    st.subheader(t["alerts_by_type"])
    try:
        type_data = session.sql("""
            SELECT ALERT_TYPE, COUNT(*) as COUNT 
            FROM FRAUD_ALERT GROUP BY ALERT_TYPE ORDER BY COUNT DESC
        """).to_pandas()
        if not type_data.empty:
            # Horizontal bars: these categories are long identifiers such as
            # COST_PER_KG_ANOMALY and DOCUMENT_QUALITY. st.bar_chart put them on the
            # x-axis where they were rotated and truncated to an unreadable stub.
            st.plotly_chart(
                ui.hbar(type_data["ALERT_TYPE"], type_data["COUNT"].astype(int),
                        value_name="Alerts"),
                use_container_width=True)
        else:
            ui.empty_state(t["no_data"])
    except Exception as e:
        ui.load_error("Alerts by type", e)

with chart_col2:
    st.subheader(t["alerts_by_severity"])
    try:
        sev_data = session.sql("""
            SELECT SEVERITY, COUNT(*) as COUNT 
            FROM FRAUD_ALERT GROUP BY SEVERITY ORDER BY COUNT DESC
        """).to_pandas()
        if not sev_data.empty:
            st.plotly_chart(
                ui.hbar(sev_data["SEVERITY"], sev_data["COUNT"].astype(int),
                        value_name="Alerts"),
                use_container_width=True)
        else:
            ui.empty_state(t["no_data"])
    except Exception as e:
        ui.load_error("Alerts by severity", e)
