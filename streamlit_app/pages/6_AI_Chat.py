import streamlit as st
import time
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="AI Chat", page_icon="💬", layout="wide")
session = get_active_session()

# Language support
if "lang" not in st.session_state:
    st.session_state.lang = "EN"
lang = st.session_state.lang

TITLES = {"EN": "💬 VF Logistics AI Assistant", "VN": "💬 Trợ lý AI VF Logistics", "JA": "💬 VF Logistics AIアシスタント"}
CAPTIONS = {"EN": "Ask about shipments, compliance, fraud — powered by Cortex AI", "VN": "Hỏi về lô hàng, tuân thủ, gian lận — Cortex AI", "JA": "出荷・コンプライアンス・不正について質問 — Cortex AI"}
THINKING = {"EN": "Thinking...", "VN": "Đang suy nghĩ...", "JA": "考えています..."}
WELCOME = {
    "EN": "Hello! I'm VF Logistics AI Assistant. I can help you with:\n- Shipment tracking and analytics\n- Fraud detection and compliance\n- Revenue analysis and KPIs\n\nAsk me anything about your logistics data!",
    "VN": "Xin chào! Tôi là Trợ lý AI VF Logistics. Tôi có thể giúp bạn:\n- Theo dõi và phân tích lô hàng\n- Phát hiện gian lận và tuân thủ\n- Phân tích doanh thu và KPI\n\nHãy hỏi tôi bất cứ điều gì về dữ liệu logistics!",
    "JA": "こんにちは！VF Logistics AIアシスタントです。以下のことをお手伝いします：\n- 出荷追跡と分析\n- 不正検出とコンプライアンス\n- 収益分析とKPI\n\n物流データについて何でもお聞きください！"
}

st.title(TITLES[lang])
st.caption(CAPTIONS[lang])

# Read AI model from config
try:
    ai_model = session.sql("SELECT CONFIG_VALUE FROM APP_CONFIG WHERE CONFIG_KEY = 'AI_MODEL'").collect()[0]["CONFIG_VALUE"]
except Exception:
    ai_model = "mistral-large2"

# Initialize chat history in session state (persists during session)
if "chat_messages" not in st.session_state:
    st.session_state.chat_messages = []

if "chat_session_id" not in st.session_state:
    st.session_state.chat_session_id = int(time.time())


def cortex_chat(prompt, context="chat"):
    start = time.time()
    answer = ""
    status = "SUCCESS"
    try:
        result = session.sql(
            "SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)", params=[ai_model, prompt]
        ).collect()[0][0]
        answer = str(result)
        return answer
    except Exception as e:
        status = "ERROR"
        return f"Error: {str(e)[:200]}"
    finally:
        elapsed_ms = int((time.time() - start) * 1000)
        in_tokens = max(1, len(prompt) // 4)
        out_tokens = max(1, len(answer) // 4) if status == "SUCCESS" else 0
        try:
            session.sql("""
                INSERT INTO AI_CALL_LOG
                    (CALL_TIMESTAMP, MODEL_NAME, PROCEDURE_NAME, CONTEXT, CALL_STATUS, STATUS,
                     LATENCY_MS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_TOKENS, PROMPT, RESPONSE)
                SELECT CURRENT_TIMESTAMP(), ?, 'AI_CHAT', ?, ?, ?, ?, ?, ?, ?, ?, ?
            """, params=[ai_model, context, status, status, elapsed_ms, in_tokens, out_tokens,
                         in_tokens + out_tokens, prompt[:5000], answer[:10000]]).collect()
        except Exception:
            pass


def generate_response(question):
    try:
        classify_prompt = (
            "Classify this message as DATA_QUERY (needs SQL about shipments/carriers/ports/fraud) "
            "or CONVERSATION (greeting, chitchat, help). Return ONLY one word. Message: " + question
        )
        msg_type = cortex_chat(classify_prompt, "classify_intent").strip().upper()

        if "CONVERSATION" in msg_type or "DATA" not in msg_type:
            chat_prompt = (
                "You are VF Logistics AI Assistant - a maritime shipping intelligence system. "
                "You can help with: shipment tracking, carrier analytics, fraud detection, compliance, exchange rates. "
                "Answer in the SAME LANGUAGE the user uses. Be friendly, concise, and helpful.\n\n"
                f"User: {question}"
            )
            return cortex_chat(chat_prompt, "conversation"), None

        sql_prompt = (
            "You are a SQL expert for maritime logistics on Snowflake. "
            "Write a SELECT query to answer this question. Available tables:\n"
            "- MENDIX_APP.AGENTS.BILL_OF_LADING (BL_ID, BL_NUMBER, CARRIER_NAME, VESSEL_NAME, "
            "PORT_OF_LOADING_LOCODE, PORT_OF_DISCHARGE_LOCODE, ETD, ETA, CONTAINER_NUMBER, "
            "COMMODITY_DESCRIPTION, GROSS_WEIGHT_KGS, TOTAL_CHARGES, STATUS, PAYMENT_STATUS, "
            "SHIPPER_NAME, CONSIGNEE_NAME, CREATED_AT)\n"
            "- MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_ID, BL_ID, ALERT_TYPE, SEVERITY, DESCRIPTION, STATUS, DETECTED_AT)\n"
            "Return ONLY the SQL query, no explanation. Add LIMIT 20 for list queries.\n"
            f"Question: {question}"
        )
        sql_result = cortex_chat(sql_prompt, "text_to_sql")
        sql = sql_result.strip()
        if "```" in sql:
            parts = sql.split("```")
            if len(parts) >= 2:
                sql = parts[1]
                if sql.startswith("sql"):
                    sql = sql[3:]
                sql = sql.strip()

        sql_upper = sql.upper().strip()
        if not sql_upper.startswith("SELECT") and not sql_upper.startswith("WITH"):
            fallback = f"Answer this maritime logistics question briefly: {question}"
            return cortex_chat(fallback, "not_select_fallback"), None

        if ";" in sql.rstrip(";"):
            return "I can only run a single SELECT statement for safety.", None

        import re
        allowed_tables = {"BILL_OF_LADING", "FRAUD_ALERT"}
        referenced = re.findall(r'\b(?:FROM|JOIN)\s+([A-Z_][A-Z0-9_.]*)', sql_upper)
        table_names = {t.split(".")[-1] for t in referenced}
        if not table_names or not table_names.issubset(allowed_tables):
            return "I can only query BILL_OF_LADING and FRAUD_ALERT for safety.", None

        if "LIMIT" not in sql_upper:
            sql = sql.rstrip(";") + " LIMIT 20"

        data = session.sql(sql).collect()
        if not data:
            return "No results found for your query.", sql

        if len(data) == 1 and len(data[0].as_dict()) <= 3:
            row = data[0].as_dict()
            answer = " | ".join(f"**{k}**: {v}" for k, v in row.items())
        else:
            cols = list(data[0].as_dict().keys())
            answer = f"Found **{len(data)}** result(s):\n\n"
            answer += "| " + " | ".join(cols) + " |\n"
            answer += "| " + " | ".join(["---"] * len(cols)) + " |\n"
            for row in data[:10]:
                vals = [str(v)[:30] if v is not None else "-" for v in row.as_dict().values()]
                answer += "| " + " | ".join(vals) + " |\n"
            if len(data) > 10:
                answer += f"\n*...and {len(data) - 10} more rows*"

        return answer, sql

    except Exception as e:
        err = str(e)
        if "SQL compilation" in err:
            try:
                fallback = f"Answer this maritime logistics question briefly: {question}"
                return cortex_chat(fallback, "sql_error_fallback"), None
            except Exception as e2:
                return f"Error: {str(e2)[:150]}", None
        return f"Error: {err[:150]}", None


# Sidebar
with st.sidebar:
    st.markdown(f"**Model:** `{ai_model}`")
    st.markdown(f"**Messages:** {len(st.session_state.chat_messages)}")
    st.divider()

    st.markdown("**Quick Questions**" if lang == "EN" else "**Câu hỏi nhanh**" if lang == "VN" else "**クイック質問**")
    quick_qs = {
        "EN": ["How many shipments are pending?", "Top 5 carriers by revenue", "Show high severity alerts", "Total weight this month"],
        "VN": ["Bao nhiêu lô hàng đang chờ?", "Top 5 hãng tàu theo doanh thu", "Hiện cảnh báo mức cao", "Tổng trọng lượng tháng này"],
        "JA": ["承認待ちの出荷数は？", "収益トップ5船社", "重大アラートを表示", "今月の総重量"]
    }
    for q in quick_qs[lang]:
        if st.button(q, key=f"qq_{hash(q)}", use_container_width=True):
            st.session_state.chat_messages.append({"role": "user", "content": q})
            with st.spinner(THINKING[lang]):
                answer, sql = generate_response(q)
            st.session_state.chat_messages.append({"role": "assistant", "content": answer, "sql": sql})
            st.rerun()

    st.divider()

    # Pipeline button in sidebar (merging external portal functionality)
    st.markdown("**Pipeline**" if lang == "EN" else "**Quy trình**" if lang == "VN" else "**パイプライン**")
    if st.button("Run Full Pipeline", key="sidebar_pipeline", use_container_width=True):
        with st.spinner("Running pipeline..."):
            try:
                result = session.sql("CALL WORKFLOW_FULL_PIPELINE_V2('AUTO')").collect()[0][0]
                st.session_state.chat_messages.append({
                    "role": "assistant",
                    "content": f"Pipeline completed:\n```json\n{result}\n```",
                    "sql": None
                })
            except Exception as e:
                st.session_state.chat_messages.append({
                    "role": "assistant",
                    "content": f"Pipeline error: {str(e)[:200]}",
                    "sql": None
                })
        st.rerun()

    if st.button("Clear Chat" if lang == "EN" else "Xoa hoi thoai" if lang == "VN" else "クリア", key="clear_chat", use_container_width=True):
        st.session_state.chat_messages = []
        st.session_state.chat_session_id = int(time.time())
        st.rerun()

# Display chat history using st.chat_message
if not st.session_state.chat_messages:
    with st.chat_message("assistant"):
        st.markdown(WELCOME[lang])

for msg in st.session_state.chat_messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])
        if msg.get("sql"):
            with st.expander("SQL Generated"):
                st.code(msg["sql"], language="sql")

# Chat input using st.chat_input (native chat UX)
if user_input := st.chat_input(
    "Ask about shipments, fraud, compliance..."
    if lang == "EN" else
    "Hoi ve lo hang, gian lan, tuan thu..."
    if lang == "VN" else
    "出荷・不正・コンプライアンスについて質問..."
):
    st.session_state.chat_messages.append({"role": "user", "content": user_input})
    with st.chat_message("user"):
        st.markdown(user_input)

    with st.chat_message("assistant"):
        with st.spinner(THINKING[lang]):
            answer, sql = generate_response(user_input)
        st.markdown(answer)
        if sql:
            with st.expander("SQL Generated"):
                st.code(sql, language="sql")

    st.session_state.chat_messages.append({"role": "assistant", "content": answer, "sql": sql})
