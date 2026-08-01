import streamlit as st
from snowflake.snowpark.context import get_active_session
from i18n import init_language, rename_columns

st.set_page_config(page_title="AI Analytics", page_icon="🤖", layout="wide")
session = get_active_session()
t = init_language()

st.title(t["ai_title"])
st.caption(t["ai_subtitle"])

# Cached config + today stats
@st.cache_data(ttl=120)
def get_finops_data():
    cost_threshold = session.sql("SELECT CONFIG_VALUE FROM APP_CONFIG WHERE CONFIG_KEY = 'DAILY_COST_ALERT_USD'").collect()
    threshold_usd = float(cost_threshold[0]["CONFIG_VALUE"]) if cost_threshold else 0.005
    
    today_row = session.sql("""
        SELECT COALESCE(SUM(ESTIMATED_COST_USD), 0) as TODAY_COST,
               COALESCE(SUM(TOTAL_CALLS), 0) as TODAY_CALLS
        FROM V_AI_DAILY_COST WHERE DAY = CURRENT_DATE()
    """).collect()[0]
    
    top_proc = session.sql("""
        SELECT PROCEDURE_NAME, COUNT(*) as CALLS, COALESCE(SUM(TOTAL_TOKENS), 0) as TOKENS
        FROM AI_CALL_LOG WHERE CALL_TIMESTAMP >= CURRENT_DATE()
        GROUP BY PROCEDURE_NAME ORDER BY TOKENS DESC LIMIT 1
    """).collect()
    
    return threshold_usd, float(today_row["TODAY_COST"]), int(today_row["TODAY_CALLS"]), top_proc

@st.cache_data(ttl=300)
def get_cost_trend():
    return session.sql("""
        SELECT DAY, TOTAL_CALLS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS,
               AVG_LATENCY_MS, ESTIMATED_COST_USD, ERRORS
        FROM V_AI_DAILY_COST ORDER BY DAY DESC LIMIT 30
    """).to_pandas()

@st.cache_data(ttl=300)
def get_usage_summary():
    return session.sql("""
        SELECT PROCEDURE_NAME, CALL_COUNT, TOTAL_TOKENS, AVG_LATENCY_MS,
               SUCCESS_COUNT, ERROR_COUNT, ERROR_RATE_PCT
        FROM V_AI_USAGE_SUMMARY ORDER BY CALL_COUNT DESC
    """).to_pandas()

@st.cache_data(ttl=300)
def get_global_metrics():
    row = session.sql("""
        SELECT COUNT(*) as TOTAL_CALLS, 
               ROUND(AVG(LATENCY_MS), 0) as AVG_LATENCY,
               COALESCE(SUM(TOTAL_TOKENS), 0) as TOTAL_TOKENS,
               ROUND(SUM(CASE WHEN STATUS = 'SUCCESS' THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(*), 0), 1) as SUCCESS_RATE
        FROM AI_CALL_LOG
    """).collect()[0]
    return row

# FinOps Alert
st.subheader(t["finops_alerts"])
try:
    threshold_usd, today_cost, today_calls, top_proc = get_finops_data()
    
    if today_cost > threshold_usd:
        st.error(f"🚨 {t['cost_exceeded'].format(cost=today_cost, threshold=threshold_usd, calls=today_calls)}")
    elif today_cost > threshold_usd * 0.8:
        st.warning(f"⚠️ {t['cost_warning'].format(cost=today_cost, threshold=threshold_usd)}")
    else:
        st.success(f"✅ {t['cost_ok'].format(cost=today_cost, threshold=threshold_usd, calls=today_calls)}")
    
    if top_proc and top_proc[0]["CALLS"] > 0:
        st.caption(f"{t['top_consumer']}: **{top_proc[0]['PROCEDURE_NAME']}** ({top_proc[0]['CALLS']} calls, {top_proc[0]['TOKENS']:,} tokens)")
except Exception as e:
    st.error(f"⚠️ FinOps data unavailable: {str(e)[:100]}")
    threshold_usd = 0.005

st.divider()

# Daily cost trend
st.subheader(t["daily_cost"])
try:
    cost_df = get_cost_trend()
    if len(cost_df) > 0:
        st.line_chart(cost_df.set_index("DAY")["ESTIMATED_COST_USD"])
        st.dataframe(rename_columns(cost_df.set_index("DAY"), st.session_state.lang), use_container_width=True)
    else:
        st.info(t["no_data"])
except Exception as e:
    st.warning(f"⚠️ {str(e)[:100]}")

st.divider()

# Usage by procedure
st.subheader(t["usage_by_proc"])
try:
    usage_df = get_usage_summary()
    if len(usage_df) > 0:
        col1, col2 = st.columns(2)
        with col1:
            st.bar_chart(usage_df.set_index("PROCEDURE_NAME")["CALL_COUNT"])
        with col2:
            st.dataframe(rename_columns(usage_df.set_index("PROCEDURE_NAME"), st.session_state.lang), use_container_width=True)
    else:
        st.info(t["no_data"])
except Exception as e:
    st.warning(f"⚠️ {str(e)[:100]}")

st.divider()

# AI Call Log with pagination + GLOBAL metrics (not page-scoped)
st.subheader(t["recent_log"])

try:
    global_metrics = get_global_metrics()
    total_logs = int(global_metrics["TOTAL_CALLS"])
    
    m1, m2, m3, m4 = st.columns(4)
    m1.metric(t["total_calls"], f"{total_logs:,}")
    m2.metric(t["avg_latency"], f"{int(global_metrics['AVG_LATENCY'] or 0)}ms")
    m3.metric(t["total_tokens_page"], f"{int(global_metrics['TOTAL_TOKENS']):,}")
    m4.metric(t["success_rate"], f"{float(global_metrics['SUCCESS_RATE'] or 0):.1f}%")
except Exception as e:
    st.warning(f"⚠️ {str(e)[:100]}")
    total_logs = 0

if total_logs > 0:
    page_size = st.selectbox(t["records_per_page"], [10, 20, 50, 100], index=1, key="log_page_size")
    total_pages = max(1, (total_logs + page_size - 1) // page_size)
    page_num = st.number_input(t["page"], min_value=1, max_value=total_pages, value=1, key="log_page")
    offset = (page_num - 1) * page_size

    st.caption(f"{t['page']} {page_num} {t['of']} {total_pages}")

    try:
        log_df = session.sql(f"""
            SELECT PROCEDURE_NAME, MODEL_NAME, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_TOKENS,
                   LATENCY_MS, STATUS, CALL_TIMESTAMP
            FROM AI_CALL_LOG ORDER BY LOG_ID DESC
            LIMIT {page_size} OFFSET {offset}
        """).to_pandas()
        log_df.index = range(offset + 1, offset + 1 + len(log_df))
        log_df.index.name = "#"
        st.dataframe(rename_columns(log_df, st.session_state.lang), use_container_width=True)
        try:
            st.download_button("📥 Export AI Log CSV", log_df.to_csv(index=False), "ai_call_log.csv", "text/csv", key="log_csv")
        except:
            pass
    except Exception as e:
        st.error(f"⚠️ {str(e)[:150]}")

st.divider()

# Chat sessions
st.subheader(t["chat_sessions"])
try:
    chat_df = session.sql("""
        SELECT SESSION_ID, COUNT(*) as MESSAGES, SUM(TOKENS_USED) as TOTAL_TOKENS,
               MIN(CREATED_AT) as STARTED, MAX(CREATED_AT) as LAST_MESSAGE
        FROM CHAT_SESSION GROUP BY SESSION_ID ORDER BY LAST_MESSAGE DESC LIMIT 10
    """).to_pandas()
    if len(chat_df) > 0:
        st.dataframe(rename_columns(chat_df.set_index("SESSION_ID"), st.session_state.lang), use_container_width=True)
    else:
        st.info(t["no_chat"])
except Exception as e:
    st.info(t["no_chat"])

st.divider()

# AI Proactive Insights
st.subheader("🧠 AI Proactive Insights")
st.caption("AI analyzes 10K+ records and generates executive-level insights: risks, opportunities, trends, anomalies.")

lang = st.session_state.get("lang", "EN")
if st.button("🧠 Generate AI Insights" if lang == "EN" else "🧠 Tạo Insights AI" if lang == "VN" else "🧠 AIインサイト生成"):
    with st.spinner("AI analyzing 10,010 records for patterns..."):
        try:
            import json
            result = session.sql(f"CALL AI_GENERATE_INSIGHTS('{lang}')").collect()[0][0]
            data = json.loads(result) if isinstance(result, str) else result
            if isinstance(data, dict) and data.get("status") == "SUCCESS":
                insights_raw = data.get("insights", "[]")
                insights = json.loads(insights_raw) if isinstance(insights_raw, str) else insights_raw
                if isinstance(insights, list):
                    for item in insights:
                        cat = item.get("category", "INFO")
                        icon = {"RISK": "🔴", "OPPORTUNITY": "🟢", "TREND": "📈", "ANOMALY": "⚠️", "RECOMMENDATION": "💡"}.get(cat, "📌")
                        priority = item.get("priority", "MEDIUM")
                        with st.expander(f"{icon} [{priority}] {item.get('title', cat)}", expanded=(priority == 'HIGH')):
                            st.markdown(item.get("insight", ""))
                else:
                    st.markdown(str(insights_raw)[:500])
                st.caption(f"📊 Data: {data.get('data_summary', '')[:200]}")
            else:
                st.warning(f"⚠️ {data.get('error', 'Unknown error')[:150]}")
        except Exception as e:
            st.error(f"⚠️ Insights generation failed: {str(e)[:150]}")

st.divider()
try:
    model_name = session.sql("SELECT CONFIG_VALUE FROM APP_CONFIG WHERE CONFIG_KEY = 'AI_MODEL'").collect()[0]['CONFIG_VALUE']
except:
    model_name = "llama3-8b"
st.caption(f"Active Model: {model_name} | Cost Alert: ${threshold_usd:.3f}/day | ⚙️ Settings")
