import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="AI Chat", page_icon="💬", layout="wide")
session = get_active_session()

lang = st.session_state.get("lang", "EN")

st.title("💬 VF Logistics AI Assistant" if lang == "EN" else "💬 Trợ lý AI VF Logistics" if lang == "VN" else "💬 VF Logistics AIアシスタント")
st.caption("Ask about shipments, compliance, fraud — powered by Cortex AI" if lang == "EN" else "Hỏi về lô hàng, tuân thủ, gian lận — Cortex AI" if lang == "VN" else "出荷・コンプライアンス・不正について質問")

# Read AI model
try:
    ai_model = session.sql("SELECT CONFIG_VALUE FROM APP_CONFIG WHERE CONFIG_KEY = 'AI_MODEL'").collect()[0]["CONFIG_VALUE"]
except:
    ai_model = "mistral-large2"

# Initialize chat history
if "messages" not in st.session_state:
    st.session_state.messages = []

def generate_response(question):
    try:
        # Step 1: Determine if this is a data question or conversational
        classify_prompt = f"Classify this user message as either DATA_QUERY (needs SQL to answer from a database about shipments, carriers, ports, freight, fraud alerts) or CONVERSATION (greeting, chitchat, general question, help request). Return ONLY one word: DATA_QUERY or CONVERSATION. Message: {question}"
        msg_type = session.sql("SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)", params=[ai_model, classify_prompt]).collect()[0][0]
        msg_type = str(msg_type).strip().upper()
        
        # Step 2: If conversational, respond directly
        if "CONVERSATION" in msg_type or "DATA" not in msg_type:
            chat_prompt = f"""You are VF Logistics AI Assistant - a maritime shipping intelligence system.
You can help with: shipment tracking, carrier analytics, fraud detection, compliance checks, exchange rates.
Answer in the SAME LANGUAGE the user uses (Vietnamese, English, Japanese).
Be friendly, concise, and helpful. If the user asks what you can do, list your capabilities.

User: {question}"""
            answer = session.sql("SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)", params=[ai_model, chat_prompt]).collect()[0][0]
            return str(answer), None
        
        # Step 3: For data questions, generate SQL
        prompt = f"""You are a SQL expert for maritime logistics on Snowflake.
Write a SELECT query to answer this question. Available tables:
- MENDIX_APP.AGENTS.BILL_OF_LADING (BL_ID, BL_NUMBER, CARRIER_NAME, VESSEL_NAME, PORT_OF_LOADING_LOCODE, PORT_OF_DISCHARGE_LOCODE, ETD, ETA, CONTAINER_NUMBER, COMMODITY_DESCRIPTION, GROSS_WEIGHT_KGS, TOTAL_CHARGES, STATUS, PAYMENT_STATUS, SHIPPER_NAME, CONSIGNEE_NAME, CREATED_AT)
- MENDIX_APP.AGENTS.FRAUD_ALERT (ALERT_ID, BL_ID, ALERT_TYPE, SEVERITY, DESCRIPTION, STATUS, DETECTED_AT)
Return ONLY the SQL query, no explanation. Add LIMIT 20 for list queries.
Question: {question}"""

        sql_result = session.sql("SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)", params=[ai_model, prompt]).collect()[0][0]

        sql = str(sql_result).strip()
        if "```" in sql:
            parts = sql.split("```")
            if len(parts) >= 2:
                sql = parts[1]
                if sql.startswith("sql"):
                    sql = sql[3:]
                sql = sql.strip()

        sql_upper = sql.upper().strip()
        if not sql_upper.startswith("SELECT"):
            chat_prompt = f"You are VF Logistics AI assistant. Answer in the same language as the user. Question: {question}"
            answer = session.sql("SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)", params=[ai_model, chat_prompt]).collect()[0][0]
            return str(answer), None

        # Safety: only block if DML keywords appear as statement starters (not inside strings/comments)
        # Split by semicolons to check each statement
        statements = sql_upper.replace('\n', ' ').split(';')
        dangerous = ["DROP ", "DELETE ", "INSERT ", "UPDATE ", "ALTER ", "CREATE ", "TRUNCATE ", "MERGE "]
        for stmt in statements:
            stmt_trimmed = stmt.strip()
            for kw in dangerous:
                if stmt_trimmed.startswith(kw):
                    return "I can only run SELECT queries for safety.", None

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
                vals = [str(v)[:25] if v is not None else "-" for v in row.as_dict().values()]
                answer += "| " + " | ".join(vals) + " |\n"

        return answer, sql

    except Exception as e:
        err = str(e)
        if "SQL compilation" in err:
            try:
                fallback = f"Answer this maritime logistics question briefly: {question}"
                ans = session.sql("SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)", params=[ai_model, fallback]).collect()[0][0]
                return str(ans), None
            except Exception as e2:
                return f"Error: {str(e2)[:150]}", None
        return f"Error: {err[:150]}", None

# Sidebar quick questions
with st.sidebar:
    st.subheader("⚡ Quick Questions")
    questions_list = [
        "How many shipments are pending review?",
        "Top 5 carriers by total charges",
        "Show high severity fraud alerts",
        "Average charges by status",
        "Total weight shipped this month"
    ]
    for q in questions_list:
        if st.button(q, key=f"q_{hash(q)}"):
            st.session_state.pending_question = q

    st.divider()
    if st.button("🗑️ Clear Chat"):
        st.session_state.messages = []
        if "pending_question" in st.session_state:
            del st.session_state.pending_question
        st.rerun()
    st.caption(f"Model: {ai_model}")

# Display existing messages
for msg in st.session_state.messages:
    if msg["role"] == "user":
        st.markdown(f"**🧑 You:** {msg['content']}")
    else:
        st.markdown(f"**🤖 Assistant:** {msg['content']}")
        if msg.get("sql"):
            with st.expander("🔍 SQL Generated"):
                st.code(msg["sql"], language="sql")
    st.divider()

# Chat input using text_input + button
st.markdown("---")
col1, col2 = st.columns([5, 1])
with col1:
    user_input = st.text_input(
        "Ask a question" if lang == "EN" else "Đặt câu hỏi",
        placeholder="e.g. How many shipments are pending?" if lang == "EN" else "VD: Bao nhiêu lô hàng đang chờ?",
        key="chat_input",
        value=st.session_state.get("pending_question", ""),
        label_visibility="collapsed"
    )
with col2:
    send_clicked = st.button("Send 📨", type="primary", use_container_width=True)

# Process input
if send_clicked and user_input:
    st.session_state.messages.append({"role": "user", "content": user_input})

    with st.spinner("🤖 Thinking..."):
        answer, sql = generate_response(user_input)

    st.session_state.messages.append({"role": "assistant", "content": answer, "sql": sql})

    # Log session
    try:
        msg_count = len([m for m in st.session_state.messages if m["role"] == "user"])
        session.sql("""
            INSERT INTO CHAT_SESSION (USER_ID, SESSION_START, MESSAGE_COUNT, LANGUAGE)
            SELECT CURRENT_USER(), CURRENT_TIMESTAMP(), ?, ?
        """, params=[msg_count, lang]).collect()
    except:
        pass

    # Clear pending question
    if "pending_question" in st.session_state:
        del st.session_state.pending_question

    st.rerun()

# Welcome message if no history
if not st.session_state.messages:
    st.markdown("---")
    c1, c2, c3 = st.columns(3)
    with c1:
        st.info("📦 **Shipments**\n\nStatus, carriers, ports, weight, charges")
    with c2:
        st.info("🛡️ **Fraud & Compliance**\n\nAlerts, sanctions, anomalies")
    with c3:
        st.info("📊 **Analytics**\n\nRevenue, KPIs, trends")
