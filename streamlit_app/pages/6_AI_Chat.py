import streamlit as st
import time
import json
import datetime
import pandas as pd
from snowflake.snowpark.context import get_active_session
from i18n import init_language
import ui

st.set_page_config(page_title="AI Chat", page_icon="💬", layout="wide")
session = get_active_session()

# init_language() renders the sidebar language selector, the same control every
# other page shows. This page previously only read st.session_state.lang, so
# landing here directly left no way to change language until you visited another
# page and came back. The page keeps its own TITLES/CAPTIONS dictionaries; only
# the selector is shared.
t = init_language()
lang = st.session_state.lang

# The title and caption used to be local dicts here, and their Vietnamese had no
# diacritics ("Tro ly AI", "Hoi ve lo hang") while correctly accented values sat
# unused in TRANSLATIONS. They now resolve through i18n like every other string.

# --- Styling: professional chat bubbles ---
# Only the chat-specific rules are injected here. The shared theme arrives via
# ui.page_header() below, which calls apply_theme() itself; calling it here as
# well injected the same stylesheet twice, and each st.markdown leaves a
# container in the DOM that still takes vertical margin even when its only
# content is a <style> tag, so the duplicate showed up as stray gaps.
st.markdown("""
<style>
.chat-meta {
    display: flex; align-items: center; gap: 8px;
    font-size: 0.78rem; color: #9aa4b2; margin: 0 0 2px 0;
}
.chat-badge {
    display: inline-flex; align-items: center; justify-content: center;
    width: 22px; height: 22px; border-radius: 50%;
    font-size: 0.72rem; font-weight: 700; color: #fff; flex: 0 0 22px;
}
.badge-user { background: #2f6feb; }
.badge-ai   { background: #1f9d6b; }
.chat-name  { font-weight: 600; color: #c9d1d9; }
.chat-time  { color: #6e7681; }
.chat-pill {
    background: #21262d; color: #9aa4b2; border: 1px solid #30363d;
    border-radius: 10px; padding: 0 6px; font-size: 0.7rem;
}
.chat-row { border-left: 2px solid #30363d; padding: 2px 0 2px 12px; margin-bottom: 4px; }
.chat-row-user { border-left-color: #2f6feb; }
.chat-row-ai   { border-left-color: #1f9d6b; }
</style>
""", unsafe_allow_html=True)

ui.page_header(t["ai_chat_title"], t["ai_chat_caption"])

try:
    ai_model = session.sql(
        "SELECT CONFIG_VALUE FROM APP_CONFIG WHERE CONFIG_KEY = 'AI_MODEL'"
    ).collect()[0]["CONFIG_VALUE"]
except Exception:
    ai_model = "mistral-large2"

# Session state
if "chat_messages" not in st.session_state:
    st.session_state.chat_messages = []
if "input_key" not in st.session_state:
    st.session_state.input_key = 0
if "session_id" not in st.session_state:
    st.session_state.session_id = None
if "persist_error" not in st.session_state:
    st.session_state.persist_error = None
if "sessions_cache" not in st.session_state:
    st.session_state.sessions_cache = None


def safe_rerun():
    if hasattr(st, "rerun"):
        st.rerun()
    elif hasattr(st, "experimental_rerun"):
        st.experimental_rerun()


def now_hm():
    return datetime.datetime.now().strftime("%H:%M:%S")


# ---------- Conversation persistence ----------
# Every write goes through an EXECUTE AS OWNER procedure, so read-only roles
# (e.g. HACKATHON_JUDGE_ROLE) need no INSERT grant on CHAT_MESSAGE.
# Any failure here degrades to in-memory-only chat rather than breaking the tab.
MAX_PERSISTED_ROWS = 20


def _call(proc, args):
    """CALL a procedure, passing NULL as a literal instead of a bound None.

    The connector bundled with the SiS runtime converts a bound Python None into
    the *string* 'None'. On a NUMBER parameter that raises
    "Numeric value 'None' is not recognized"; on a VARCHAR parameter it is
    accepted silently and stores the text 'None', which is worse. So None is
    emitted as a SQL NULL literal and only real values are bound, which keeps
    quote/backslash escaping safe for the text and JSON arguments.
    """
    slots, params = [], []
    for a in args:
        if a is None:
            slots.append("NULL")
        else:
            slots.append("?")
            params.append(a)
    sql = f"CALL {proc}({', '.join(slots)})"
    if params:
        return session.sql(sql, params=params).collect()
    return session.sql(sql).collect()


def db_new_session():
    try:
        sid = _call("CHAT_SESSION_NEW", [lang])[0][0]
        st.session_state.persist_error = None
        return int(sid)
    except Exception as e:
        st.session_state.persist_error = str(e)[:600]
        return None


def db_save(role, content=None, sql_text=None, df=None, rows=None, latency_ms=None):
    sid = st.session_state.get("session_id")
    if not sid:
        return
    result_json = None
    if df is not None:
        try:
            result_json = df.head(MAX_PERSISTED_ROWS).to_json(
                orient="records", date_format="iso"
            )
        except Exception:
            result_json = None
    try:
        _call("CHAT_MESSAGE_SAVE", [
            int(sid), role, content, sql_text, result_json,
            None if rows is None else int(rows),
            None if latency_ms is None else int(latency_ms),
        ])
    except Exception as e:
        st.session_state.persist_error = str(e)[:600]


def db_list_sessions():
    """Cached in session_state so we do not re-query on every Streamlit rerun."""
    if st.session_state.sessions_cache is not None:
        return st.session_state.sessions_cache
    try:
        rows = _call("CHAT_SESSION_LIST", [])
        st.session_state.sessions_cache = [r.as_dict() for r in rows]
    except Exception as e:
        st.session_state.persist_error = str(e)[:600]
        st.session_state.sessions_cache = []
    return st.session_state.sessions_cache


def invalidate_sessions():
    st.session_state.sessions_cache = None


def db_load_session(sid):
    try:
        rows = _call("CHAT_SESSION_LOAD", [int(sid)])
    except Exception as e:
        st.session_state.persist_error = str(e)[:600]
        return None
    msgs = []
    for r in rows:
        d = r.as_dict()
        df = None
        if d.get("RESULT_JSON"):
            try:
                df = pd.DataFrame(json.loads(d["RESULT_JSON"]))
            except Exception:
                df = None
        created = d.get("CREATED_AT")
        msgs.append({
            "role": d.get("ROLE"),
            "content": d.get("CONTENT"),
            "sql": d.get("SQL_TEXT"),
            "df": df,
            "rows": d.get("ROW_COUNT"),
            "ts": created.strftime("%H:%M:%S") if created else "",
            "latency_ms": d.get("LATENCY_MS"),
        })
    return msgs


def db_delete_session(sid):
    try:
        _call("CHAT_SESSION_DELETE", [int(sid)])
    except Exception as e:
        st.session_state.persist_error = str(e)[:600]


def ensure_session():
    if not st.session_state.get("session_id"):
        st.session_state.session_id = db_new_session()
        invalidate_sessions()


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


# Read-only tables/views the assistant may query
ALLOWED_OBJECTS = {
    "BILL_OF_LADING", "BILL_OF_LADING_EXTRACTED", "FRAUD_ALERT",
    "SAP_FI_DOCUMENT", "COMPLIANCE_CHECK_RESULT", "PORT_MASTER",
    "VESSEL_REGISTRY", "HS_CODE_REFERENCE", "WORKFLOW_AUDIT_LOG",
    "V_AI_DECISIONS", "V_EXCHANGE_RATES", "V_EXPORT_RESTRICTED_ENTITIES",
    "V_AI_DAILY_COST", "V_AI_USAGE_SUMMARY",
}

SCHEMA_HINT = (
    "Available objects in MENDIX_APP.AGENTS (read-only):\n"
    "- BILL_OF_LADING (BL_ID, BL_NUMBER, CARRIER_NAME, VESSEL_NAME, PORT_OF_LOADING_LOCODE, "
    "PORT_OF_DISCHARGE_LOCODE, ETD, ETA, CONTAINER_NUMBER, COMMODITY_DESCRIPTION, "
    "GROSS_WEIGHT_KGS, TOTAL_CHARGES, STATUS, PAYMENT_STATUS, SHIPPER_NAME, CONSIGNEE_NAME, CREATED_AT)\n"
    "- BILL_OF_LADING_EXTRACTED (DOC_ID, FILE_NAME, BL_NUMBER, CONTAINER_NUMBER, VESSEL_NAME, "
    "GROSS_WEIGHT_KG, CONFIDENCE_SCORE, STATUS, FINAL_STATUS, ANOMALY_FLAGS, ALERT, PROCESSED_AT)\n"
    "- FRAUD_ALERT (ALERT_ID, BL_ID, ALERT_TYPE, SEVERITY, DESCRIPTION, STATUS, DETECTED_AT, "
    "CREATED_AT, RESOLVED_AT, AI_RISK_ASSESSMENT, AI_RECOMMENDED_ACTION, AI_DECISION_REASON)\n"
    "- SAP_FI_DOCUMENT (FI_DOC_ID, BL_ID, SAP_DOCUMENT_NUMBER, COMPANY_CODE, FISCAL_YEAR, "
    "POSTING_DATE, DOCUMENT_TYPE, REFERENCE, CURRENCY_CODE, TOTAL_AMOUNT, CREATED_AT)\n"
    "- COMPLIANCE_CHECK_RESULT (CHECK_ID, BL_ID, CHECK_TIMESTAMP, COMPLIANT, VIOLATIONS, "
    "RISK_SCORE, RULES_CHECKED)\n"
    "- PORT_MASTER (PORT_CODE, PORT_NAME, COUNTRY, COUNTRY_CODE, PORT_TYPE, IS_ACTIVE)\n"
    "- VESSEL_REGISTRY (VESSEL_ID, VESSEL_NAME, IMO_NUMBER, FLAG, GROSS_TONNAGE, BUILT_YEAR, "
    "VESSEL_TYPE, OPERATOR_NAME, IS_ACTIVE)\n"
    "- HS_CODE_REFERENCE (HS_CODE, DESCRIPTION, CATEGORY, IS_DANGEROUS_GOODS, IS_RESTRICTED, "
    "REQUIRES_PERMIT, DUTY_RATE_PCT, DG_CLASS)\n"
    "- WORKFLOW_AUDIT_LOG (AUDIT_ID, WORKFLOW_NAME, STEP_NAME, STEP_ORDER, EXECUTION_TIME_MS, "
    "STATUS, EXECUTED_BY, EXECUTED_AT)\n"
    "- V_AI_DECISIONS (ALERT_ID, SEVERITY, ALERT_TYPE, BL_NUMBER, SHIPPER_NAME, CONSIGNEE_NAME, "
    "TOTAL_CHARGES, ROUTE, AI_DECISION, AI_DECISION_REASON, ALERT_STATUS, DETECTED_AT)\n"
    "- V_EXCHANGE_RATES (QUOTE_CURRENCY_ID, EXCHANGE_RATE, RATE_DATE)\n"
    "- V_EXPORT_RESTRICTED_ENTITIES (ENTITY_NAME, COUNTRY, LIST_TYPE, EFFECTIVE_DATE)\n"
    "- V_AI_DAILY_COST (DAY, TOTAL_CALLS, TOTAL_TOKENS, AVG_LATENCY_MS, ESTIMATED_COST_USD, ERRORS)\n"
    "- V_AI_USAGE_SUMMARY (PROCEDURE_NAME, CALL_COUNT, TOTAL_TOKENS, AVG_LATENCY_MS, ERROR_RATE_PCT)\n"
    "Note: BILL_OF_LADING joins FRAUD_ALERT / SAP_FI_DOCUMENT / COMPLIANCE_CHECK_RESULT on BL_ID, "
    "and PORT_MASTER.PORT_CODE = BILL_OF_LADING.PORT_OF_LOADING_LOCODE.\n"
    "\n"
    "IMPORTANT - use these exact literal values, do not invent your own:\n"
    "- BILL_OF_LADING.STATUS: 'In_Transit', 'Delivered', 'APPROVED', 'Pending_Review', "
    "'VALIDATED', 'SAP_POSTED', 'DRAFT', 'BLOCKED'. There is no value 'PENDING'  --  "
    "a question about pending or awaiting-review shipments means STATUS = 'Pending_Review'.\n"
    "- BILL_OF_LADING.PAYMENT_STATUS: 'PAID', 'UNPAID'\n"
    "- BILL_OF_LADING.CARRIER_NAME: 'MAERSK', 'MSC', 'COSCO', 'HAPAG_LLOYD', 'CMA_CGM', "
    "'EVERGREEN', 'ONE', 'OOCL', 'APL', 'YANG_MING'\n"
    "- FRAUD_ALERT.SEVERITY: 'HIGH', 'MEDIUM', 'LOW'\n"
    "- FRAUD_ALERT.STATUS: 'OPEN', 'INVESTIGATING', 'ESCALATED', 'RESOLVED', 'DISMISSED'\n"
    "- FRAUD_ALERT.ALERT_TYPE: 'DUPLICATE_BL_NUMBER', 'COST_PER_KG_ANOMALY', 'ROUTE_DEVIATION', "
    "'WEIGHT_ANOMALY', 'HIGH_VALUE_ANOMALY', 'DOCUMENT_QUALITY'\n"
    "- FRAUD_ALERT.AI_RECOMMENDED_ACTION and V_AI_DECISIONS.AI_DECISION: 'BLOCK', 'CLEAR', 'ESCALATE'\n"
    "- BILL_OF_LADING_EXTRACTED.FINAL_STATUS: 'APPROVED', 'CORRECTED'\n"
    "For case-insensitive matching on free-text columns prefer ILIKE over =.\n"
)


def generate_response(question):
    """Returns (answer_markdown, sql, dataframe_or_None, rowcount_or_None)."""
    try:
        classify_prompt = (
            "Classify this message as DATA_QUERY (needs SQL about shipments/carriers/ports/fraud/"
            "compliance/SAP/costs) or CONVERSATION (greeting, chitchat, help). "
            "Return ONLY one word. Message: " + question
        )
        msg_type = cortex_chat(classify_prompt, "classify_intent").strip().upper()

        if "CONVERSATION" in msg_type or "DATA" not in msg_type:
            chat_prompt = (
                "You are VF Logistics AI Assistant - a maritime shipping intelligence system. "
                "You can help with: shipment tracking, carrier analytics, fraud detection, "
                "compliance screening, SAP postings, FX rates, and AI cost monitoring. "
                "Answer in the SAME LANGUAGE the user uses. Be friendly, concise, and helpful.\n\n"
                f"User: {question}"
            )
            return cortex_chat(chat_prompt, "conversation"), None, None, None

        sql_prompt = (
            "You are a SQL expert for maritime logistics on Snowflake. "
            "Write ONE SELECT query to answer the question.\n"
            + SCHEMA_HINT
            + "Rules: return ONLY the SQL, no explanation, no semicolon. "
            "Add LIMIT 20 for list queries. Use fully qualified names.\n"
            f"Question: {question}"
        )
        sql = cortex_chat(sql_prompt, "text_to_sql").strip()

        if "```" in sql:
            parts = sql.split("```")
            if len(parts) >= 2:
                sql = parts[1]
                if sql.lower().startswith("sql"):
                    sql = sql[3:]
                sql = sql.strip()

        sql_upper = sql.upper().strip()
        if not (sql_upper.startswith("SELECT") or sql_upper.startswith("WITH")):
            fallback = f"Answer this maritime logistics question briefly: {question}"
            return cortex_chat(fallback, "not_select_fallback"), None, None, None

        if ";" in sql.rstrip(";"):
            return "For safety I only run a single SELECT statement.", None, None, None

        import re
        referenced = re.findall(r'\b(?:FROM|JOIN)\s+([A-Z_][A-Z0-9_.]*)', sql_upper)
        names = {t.split(".")[-1] for t in referenced}
        if not names or not names.issubset(ALLOWED_OBJECTS):
            blocked = ", ".join(sorted(names - ALLOWED_OBJECTS)) or "unknown"
            return (
                f"I can only query approved read-only objects. Blocked: `{blocked}`.",
                None, None, None,
            )

        if "LIMIT" not in sql_upper:
            sql = sql.rstrip(";") + " LIMIT 20"

        pdf = session.sql(sql).to_pandas()
        if pdf.empty:
            return "No rows matched that query.", sql, None, 0

        # Single scalar / tiny result -> render as metric-style text
        if pdf.shape[0] == 1 and pdf.shape[1] <= 3:
            row = pdf.iloc[0].to_dict()
            answer = "  ".join(f"**{k}:** {v}" for k, v in row.items())
            return answer, sql, None, 1

        return None, sql, pdf, int(pdf.shape[0])

    except Exception as e:
        err = str(e)
        if "SQL compilation" in err:
            try:
                fallback = f"Answer this maritime logistics question briefly: {question}"
                return cortex_chat(fallback, "sql_error_fallback"), None, None, None
            except Exception as e2:
                return f"Error: {str(e2)[:150]}", None, None, None
        return f"Error: {err[:150]}", None, None, None


def ask(question):
    ensure_session()
    st.session_state.chat_messages.append(
        {"role": "user", "content": question, "ts": now_hm()}
    )
    db_save("user", content=question)
    t0 = time.time()
    with st.spinner(t["chat_analyzing"]):
        answer, sql, pdf, rows = generate_response(question)
    latency = int((time.time() - t0) * 1000)
    st.session_state.chat_messages.append({
        "role": "assistant",
        "content": answer,
        "sql": sql,
        "df": pdf,
        "rows": rows,
        "ts": now_hm(),
        "latency_ms": latency,
    })
    db_save("assistant", content=answer, sql_text=sql, df=pdf,
            rows=rows, latency_ms=latency)
    invalidate_sessions()   # message count / title may have changed


# --- Sidebar ---
with st.sidebar:
    turns = sum(1 for m in st.session_state.chat_messages if m["role"] == "user")
    lat = [m["latency_ms"] for m in st.session_state.chat_messages
           if m["role"] == "assistant" and m.get("latency_ms")]
    avg_lat = int(sum(lat) / len(lat)) if lat else 0

    st.markdown(t["sb_session"])
    m1, m2 = st.columns(2)
    m1.metric(t["m_turns"], turns)
    m2.metric(t["m_avg"], f"{avg_lat/1000:.1f}s" if avg_lat else ui.EM_DASH)
    st.caption(t["model_label"].format(model=f"`{ai_model}`"))
    st.markdown("---")

    # --- Conversations (persisted in Snowflake) ---
    st.markdown(t["sb_conversations"])
    if st.button(t["sb_new_chat"],
                 key="new_chat", use_container_width=True):
        st.session_state.chat_messages = []
        st.session_state.session_id = None   # created lazily on first message
        st.session_state.input_key += 1
        invalidate_sessions()
        safe_rerun()

    past = db_list_sessions()
    if past:
        label = t["sb_history"].format(n=len(past))
        with st.expander(label, expanded=False):
            for s in past:
                sid = int(s["SESSION_ID"])
                title = str(s.get("TITLE") or t["untitled"])[:36]
                mark = "  *" if sid == st.session_state.get("session_id") else ""
                if st.button(f"{title}{mark}", key=f"sess_{sid}", use_container_width=True):
                    loaded = db_load_session(sid)
                    if loaded is not None:
                        st.session_state.chat_messages = loaded
                        st.session_state.session_id = sid
                        st.session_state.input_key += 1
                        safe_rerun()
                started = s.get("SESSION_START")
                when = started.strftime("%d %b %H:%M") if started else ""
                st.caption(t["sb_msgs"].format(n=int(s.get('MESSAGE_COUNT') or 0), when=when))

    if st.session_state.get("persist_error"):
        st.caption(t["sb_history_unavailable"])
        with st.expander(t["sb_why"]):
            st.code(str(st.session_state.persist_error), language="text")

    st.markdown("---")

    st.markdown(f"**{t['quick_questions']}**")
    # The five prompts are looked up per language. They were previously written
    # inline, and the Vietnamese variants had no diacritics at all ("Bao nhieu
    # lo hang dang cho?"), which reads as broken Vietnamese rather than a
    # translation.
    quick_qs = [
        t["q_pending"], t["q_top_carriers"], t["q_high_severity"],
        t["q_recent_sap"], t["q_ai_decisions"],
    ]
    for i, q in enumerate(quick_qs):
        if st.button(q, key=f"qq_{i}", use_container_width=True):
            ask(q)
            safe_rerun()

    st.markdown("---")
    st.markdown(t["sb_pipeline"])
    if st.button(t["run_full_pipeline"], key="sidebar_pipeline", use_container_width=True):
        ensure_session()
        t0 = time.time()
        with st.spinner("Detect â†’ Investigate â†’ Screen â†’ Remediate â†’ SAP post..."):
            try:
                result = session.sql("CALL WORKFLOW_FULL_PIPELINE_V2('AUTO')").collect()[0][0]
                content = t["pipeline_done"] + f"\n```json\n{result}\n```"
            except Exception as e:
                content = t["pipeline_failed"].format(err=str(e)[:200])
        latency = int((time.time() - t0) * 1000)
        st.session_state.chat_messages.append({
            "role": "assistant", "content": content, "sql": None, "df": None,
            "rows": None, "ts": now_hm(), "latency_ms": latency,
        })
        db_save("assistant", content=content, latency_ms=latency)
        invalidate_sessions()
        safe_rerun()

    st.markdown("---")
    if st.session_state.chat_messages:
        transcript = "\n\n".join(
            f"[{m.get('ts','')}] {'USER' if m['role']=='user' else 'ASSISTANT'}: "
            f"{m.get('content') or ('<' + str(m.get('rows',0)) + ' rows>')}"
            + (f"\nSQL: {m['sql']}" if m.get("sql") else "")
            for m in st.session_state.chat_messages
        )
        st.download_button(
            t["export_transcript"],
            data=transcript,
            file_name=f"vf_chat_{datetime.datetime.now().strftime('%Y%m%d_%H%M')}.txt",
            mime="text/plain",
            use_container_width=True,
        )

    if st.button(t["sb_delete_conversation"],
                 key="delete_chat", use_container_width=True):
        sid = st.session_state.get("session_id")
        if sid:
            db_delete_session(sid)
        st.session_state.chat_messages = []
        st.session_state.session_id = None
        st.session_state.input_key += 1
        invalidate_sessions()
        safe_rerun()


# --- Chat transcript ---
if not st.session_state.chat_messages:
    st.info(t["chat_welcome"])

for msg in st.session_state.chat_messages:
    is_user = msg["role"] == "user"
    badge = "U" if is_user else "AI"
    badge_cls = "badge-user" if is_user else "badge-ai"
    row_cls = "chat-row-user" if is_user else "chat-row-ai"
    name = t["chat_you"] if is_user else t["chat_ai"]

    pills = ""
    if not is_user:
        if msg.get("latency_ms"):
            pills += f"<span class='chat-pill'>{msg['latency_ms']/1000:.1f}s</span>"
        if msg.get("rows") is not None:
            pills += f"<span class='chat-pill'>{t['chat_rows'].format(n=msg['rows'])}</span>"

    st.markdown(
        f"<div class='chat-row {row_cls}'>"
        f"<div class='chat-meta'>"
        f"<span class='chat-badge {badge_cls}'>{badge}</span>"
        f"<span class='chat-name'>{name}</span>"
        f"<span class='chat-time'>{msg.get('ts','')}</span>{pills}"
        f"</div></div>",
        unsafe_allow_html=True,
    )

    # Content rendered outside the HTML block so markdown tables/code still work
    if msg.get("content"):
        st.markdown(msg["content"])
    if msg.get("df") is not None:
        ui.show_table(msg["df"])
    if msg.get("sql"):
        with st.expander(t["view_generated_sql"]):
            st.code(msg["sql"], language="sql")

    st.markdown("<div style='height:6px'></div>", unsafe_allow_html=True)


# --- Input ---
st.markdown("---")
col1, col2 = st.columns([6, 1])
with col1:
    user_input = st.text_input(
        t["ask_question"],
        placeholder=t["ask_question_placeholder"],
        key=f"chat_input_{st.session_state.input_key}",
        label_visibility="collapsed",
    )
with col2:
    send_clicked = st.button(t["send"], use_container_width=True)

if send_clicked and user_input:
    ask(user_input)
    st.session_state.input_key += 1   # fresh widget -> input clears
    safe_rerun()
