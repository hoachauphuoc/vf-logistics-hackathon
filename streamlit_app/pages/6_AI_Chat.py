import streamlit as st
import time
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="AI Chat", page_icon="💬", layout="wide")
session = get_active_session()

if "lang" not in st.session_state:
    st.session_state.lang = "EN"
lang = st.session_state.lang

TITLES = {"EN": "💬 VF Logistics AI Assistant", "VN": "💬 Tro ly AI VF Logistics", "JA": "💬 VF Logistics AIアシスタント"}
CAPTIONS = {"EN": "Ask about shipments, compliance, fraud — powered by Cortex AI", "VN": "Hoi ve lo hang, tuan thu, gian lan — Cortex AI", "JA": "出荷・コンプライアンス・不正について質問 — Cortex AI"}
THINKING = {"EN": "Thinking...", "VN": "Dang suy nghi...", "JA": "考えています..."}

st.title(TITLES[lang])
st.caption(CAPTIONS[lang])

try:
    ai_model = session.sql("SELECT CONFIG_VALUE FROM APP_CONFIG WHERE CONFIG_KEY = 'AI_MODEL'").collect()[0]["CONFIG_VALUE"]
except Exception:
    ai_model = "mistral-large2"

# Session state for chat persistence
if "chat_messages" not in st.session_state:
    st.session_state.chat_messages = []


def safe_rerun():
    if hasattr(st, "rerun"):
        st.rerun()
    elif hasattr(st, "experimental_rerun"):
        st.experimental_rerun()


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
        table_names = {t2.split(".")[-1] for t2 in referenced}
        if not table_names or not table_names.issubset(allowed_tables):
            return "I can only query BILL_OF_LADING and FRAUD_ALERT for safety.", None

        if "LIMIT" not in sql_upper:
            sql = sql.rstrip(";") + " LIMIT 20"

        data = session.sql(sql).collect()
        if not data:
            return "No results found.", sql

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


# --- Sidebar ---
with st.sidebar:
    st.markdown(f"**Model:** `{ai_model}`")
    st.markdown(f"**Messages:** {len(st.session_state.chat_messages)}")
    st.markdown("---")

    st.markdown("**Quick Questions**" if lang == "EN" else "**Cau hoi nhanh**")
    quick_qs = {
        "EN": ["How many shipments are pending?", "Top 5 carriers by revenue", "Show high severity alerts", "Total weight this month"],
        "VN": ["Bao nhieu lo hang dang cho?", "Top 5 hang tau theo doanh thu", "Hien canh bao muc cao", "Tong trong luong thang nay"],
        "JA": ["承認待ちの出荷数は？", "収益トップ5船社", "重大アラートを表示", "今月の総重量"]
    }
    for q in quick_qs.get(lang, quick_qs["EN"]):
        if st.button(q, key=f"qq_{hash(q)}", use_container_width=True):
            st.session_state.chat_messages.append({"role": "user", "content": q})
            with st.spinner(THINKING[lang]):
                answer, sql = generate_response(q)
            st.session_state.chat_messages.append({"role": "assistant", "content": answer, "sql": sql})
            safe_rerun()

    st.markdown("---")
    st.markdown("**Pipeline**")
    if st.button("Run Full Pipeline", key="sidebar_pipeline", use_container_width=True):
        with st.spinner("Running pipeline..."):
            try:
                result = session.sql("CALL WORKFLOW_FULL_PIPELINE_V2('AUTO')").collect()[0][0]
                st.session_state.chat_messages.append({
                    "role": "assistant",
                    "content": f"Pipeline completed:\n```\n{result}\n```",
                    "sql": None
                })
            except Exception as e:
                st.session_state.chat_messages.append({
                    "role": "assistant",
                    "content": f"Pipeline error: {str(e)[:200]}",
                    "sql": None
                })
        safe_rerun()

    if st.button("Clear Chat" if lang == "EN" else "Xoa hoi thoai", key="clear_chat", use_container_width=True):
        st.session_state.chat_messages = []
        safe_rerun()

# --- Chat Display (compatible with Streamlit 1.22) ---
for msg in st.session_state.chat_messages:
    if msg["role"] == "user":
        st.markdown(f"**🧑 You:** {msg['content']}")
    else:
        st.markdown(f"**🤖 Assistant:** {msg['content']}")
        if msg.get("sql"):
            with st.expander("SQL Generated"):
                st.code(msg["sql"], language="sql")
    st.markdown("---")

# Welcome message
if not st.session_state.chat_messages:
    st.info(
        "Ask me anything about your logistics data! Try the quick questions in the sidebar, or type below."
        if lang == "EN" else
        "Hoi toi bat cu dieu gi ve du lieu logistics! Thu cac cau hoi nhanh o sidebar, hoac nhap ben duoi."
    )

# --- Chat Input (text_input + button for Streamlit 1.22 compatibility) ---
st.markdown("---")
col1, col2 = st.columns([5, 1])
with col1:
    user_input = st.text_input(
        "Ask a question" if lang == "EN" else "Dat cau hoi",
        placeholder="e.g. How many shipments are pending?" if lang == "EN" else "VD: Bao nhieu lo hang dang cho?",
        key="chat_input",
        label_visibility="collapsed"
    )
with col2:
    send_clicked = st.button("Send 📨" if lang == "EN" else "Gui 📨", use_container_width=True)

if send_clicked and user_input:
    st.session_state.chat_messages.append({"role": "user", "content": user_input})
    with st.spinner(THINKING[lang]):
        answer, sql = generate_response(user_input)
    st.session_state.chat_messages.append({"role": "assistant", "content": answer, "sql": sql})
    safe_rerun()
