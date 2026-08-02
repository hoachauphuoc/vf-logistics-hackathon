import streamlit as st
from snowflake.snowpark.context import get_active_session
from i18n import init_language

st.set_page_config(page_title="AI Chat", page_icon="💬", layout="wide")
session = get_active_session()
t = init_language()
lang = st.session_state.lang

st.title(t["ai_chat_title"])
st.caption(t["ai_chat_caption"])

# Read AI model
try:
    ai_model = session.sql("SELECT CONFIG_VALUE FROM APP_CONFIG WHERE CONFIG_KEY = 'AI_MODEL'").collect()[0]["CONFIG_VALUE"]
except Exception:
    ai_model = "mistral-large2"

# Initialize chat history
if "messages" not in st.session_state:
    st.session_state.messages = []


def safe_rerun():
    # st.rerun() was added in Streamlit 1.27; the Streamlit-in-Snowflake warehouse
    # runtime conda environment can pin an older version that only has the
    # deprecated st.experimental_rerun().
    if hasattr(st, "rerun"):
        st.rerun()
    elif hasattr(st, "experimental_rerun"):
        st.experimental_rerun()


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

        # Safety: this app runs with owner's-rights execution (Streamlit-in-Snowflake
        # warehouse runtime always executes as the app owner, not the viewer -- see
        # docs.snowflake.com/en/developer-guide/streamlit/object-management/owners-rights).
        # A DML keyword blocklist is not a real security boundary against a model-generated
        # query running with the owner's full privileges, so instead of blocklisting we
        # allowlist: reject anything but a single simple SELECT, and reject any statement
        # that references a table outside the two this feature was designed for.
        if ";" in sql.rstrip(";"):
            return "I can only run a single SELECT statement for safety.", None

        # Only inspect identifiers that follow FROM/JOIN -- checking every identifier
        # in the query would also catch ordinary column names and break real questions.
        allowed_tables = {"BILL_OF_LADING", "FRAUD_ALERT"}
        import re
        referenced_tables = re.findall(r'\b(?:FROM|JOIN)\s+([A-Z_][A-Z0-9_.]*)', sql_upper)
        table_names = {t2.split(".")[-1] for t2 in referenced_tables}
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
    st.subheader(t["quick_questions"])
    questions_list = [t["q_pending"], t["q_top_carriers"], t["q_high_severity"], t["q_avg_charges"], t["q_total_weight"]]
    for q in questions_list:
        if st.button(q, key=f"q_{hash(q)}"):
            st.session_state.pending_question = q

    st.divider()
    if st.button(t["clear_chat"]):
        st.session_state.messages = []
        if "pending_question" in st.session_state:
            del st.session_state.pending_question
        safe_rerun()
    st.caption(t["model_label"].format(model=ai_model))

# Display existing messages
for msg in st.session_state.messages:
    if msg["role"] == "user":
        st.markdown(t["you_label"].format(v=msg['content']))
    else:
        st.markdown(t["assistant_label"].format(v=msg['content']))
        if msg.get("sql"):
            with st.expander(t["sql_generated"]):
                st.code(msg["sql"], language="sql")
    st.divider()

# Chat input using text_input + button
st.markdown("---")
col1, col2 = st.columns([5, 1])
with col1:
    user_input = st.text_input(
        t["ask_question"],
        placeholder=t["ask_question_placeholder"],
        key="chat_input",
        value=st.session_state.get("pending_question", ""),
        label_visibility="collapsed"
    )
with col2:
    send_clicked = st.button(t["send"], type="primary", use_container_width=True)

# Process input
if send_clicked and user_input:
    st.session_state.messages.append({"role": "user", "content": user_input})

    with st.spinner(t["thinking"]):
        answer, sql = generate_response(user_input)

    st.session_state.messages.append({"role": "assistant", "content": answer, "sql": sql})

    # Log session
    try:
        msg_count = len([m for m in st.session_state.messages if m["role"] == "user"])
        session.sql("""
            INSERT INTO CHAT_SESSION (USER_ID, SESSION_START, MESSAGE_COUNT, LANGUAGE)
            SELECT CURRENT_USER(), CURRENT_TIMESTAMP(), ?, ?
        """, params=[msg_count, lang]).collect()
    except Exception:
        pass

    # Clear pending question
    if "pending_question" in st.session_state:
        del st.session_state.pending_question

    safe_rerun()

# Welcome message if no history
if not st.session_state.messages:
    st.markdown("---")
    c1, c2, c3 = st.columns(3)
    with c1:
        st.info(t["welcome_shipments"])
    with c2:
        st.info(t["welcome_fraud"])
    with c3:
        st.info(t["welcome_analytics"])
