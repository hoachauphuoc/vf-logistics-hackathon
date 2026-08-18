-- ============================================================================
-- VF LOGISTICS - Chat conversation persistence
-- Exported live from MENDIX_APP.AGENTS on 2026-08-18
-- This file is generated from GET_DDL so the repository matches what is deployed.
--
-- Purpose: back the AI Chat tab with durable, per-user conversation history.
--   * CHAT_SESSION  - one row per conversation (pre-existing table, TITLE added)
--   * CHAT_MESSAGE  - one row per turn, including the generated SQL and a
--                     capped JSON snapshot of the result table
--
-- Design notes:
--   1. All access goes through EXECUTE AS OWNER procedures. A read-only
--      evaluator role (HACKATHON_JUDGE_ROLE) therefore needs USAGE on these
--      procedures and NO grants at all on CHAT_MESSAGE.
--   2. Ownership is enforced inside every procedure against CURRENT_USER().
--      Owner-rights procedures swap CURRENT_ROLE() to the owner but leave
--      CURRENT_USER() as the caller, which is what makes per-user scoping work.
--   3. SESSION_ID is generated solely by CHAT_SESSION_SEQ. The column
--      originally carried an autoincrement default; it was removed with
--      ALTER COLUMN SESSION_ID DROP DEFAULT because Snowflake identity
--      allocates in blocks and is NOT monotonic, so a procedure that inserted
--      without an explicit id and then read it back with MAX(SESSION_ID) could
--      return a different, pre-existing session and append turns to the wrong
--      conversation. Keep exactly one generator: do not re-add the identity.
--   4. Result tables are replayed from the stored RESULT_JSON snapshot rather
--      than by re-running SQL_TEXT, so reopening a conversation costs no
--      warehouse compute and cannot show different rows than were first shown.
--   5. CLIENT NOTE for anyone calling these procedures from Streamlit-in-
--      Snowflake: do NOT bind a Python None as a parameter. The connector
--      bundled with the SiS runtime sends it as the string 'None', which raises
--      "Numeric value 'None' is not recognized" on a NUMBER parameter and, worse,
--      is accepted silently on a VARCHAR parameter and stores the text 'None'.
--      Emit SQL NULL as a literal for absent arguments and bind only real
--      values. See the _call() helper in streamlit_app/pages/6_AI_Chat.py.
--      Note this does not reproduce on a current local Snowpark install, so it
--      cannot be caught by local testing alone.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Tables
--
-- WARNING: these are CREATE OR REPLACE statements, exported from GET_DDL to
-- match the deployed schema. Running this section against a live account
-- DESTROYS all stored conversations. For a first-time deploy, or to reset,
-- run as-is. To deploy onto an account that already has chat history, run only
-- the Procedures and Grants sections below.
-- ---------------------------------------------------------------------------

create or replace TABLE CHAT_SESSION (
        SESSION_ID NUMBER(38,0) NOT NULL,
        USER_ID VARCHAR(100),
        BL_ID NUMBER(38,0),
        SESSION_START TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP(),
        SESSION_END TIMESTAMP_NTZ(9),
        MESSAGE_COUNT NUMBER(10,0) DEFAULT 0,
        LANGUAGE VARCHAR(5) DEFAULT 'EN',
        TOKENS_USED NUMBER(10,0) DEFAULT 0,
        CREATED_AT TIMESTAMP_NTZ(9),
        TITLE VARCHAR(200),
        primary key (SESSION_ID)
);

-- Sole generator for CHAT_SESSION.SESSION_ID. Starts at 1000 to stay clear of
-- ids already issued by the identity default that this replaced.
create or replace sequence CHAT_SESSION_SEQ start with 1000 increment by 1 noorder;

create or replace TABLE CHAT_MESSAGE (
        MESSAGE_ID NUMBER(38,0) autoincrement start 1 increment 1 noorder,
        SESSION_ID NUMBER(38,0) NOT NULL,
        TURN_INDEX NUMBER(38,0),
        ROLE VARCHAR(16),
        CONTENT VARCHAR(16777216),
        SQL_TEXT VARCHAR(16777216),
        RESULT_JSON VARCHAR(16777216),
        ROW_COUNT NUMBER(38,0),
        LATENCY_MS NUMBER(38,0),
        CREATED_AT TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------------
-- Procedures
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE CHAT_SESSION_NEW(P_LANG VARCHAR DEFAULT 'EN')
RETURNS NUMBER
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  V_ID NUMBER;
BEGIN
  -- The identity default was removed from CHAT_SESSION.SESSION_ID so that this
  -- sequence is the single id generator. Do not re-add an autoincrement here:
  -- Snowflake identity allocates in blocks and is not monotonic, so deriving the
  -- new id with MAX(SESSION_ID) could return a different, pre-existing session.
  V_ID := (SELECT MENDIX_APP.AGENTS.CHAT_SESSION_SEQ.NEXTVAL);
  INSERT INTO MENDIX_APP.AGENTS.CHAT_SESSION
    (SESSION_ID, USER_ID, SESSION_START, MESSAGE_COUNT, LANGUAGE, TOKENS_USED, CREATED_AT, TITLE)
  SELECT :V_ID, CURRENT_USER(), CURRENT_TIMESTAMP(), 0, :P_LANG, 0, CURRENT_TIMESTAMP(), NULL;
  RETURN :V_ID;
END;
$$;

CREATE OR REPLACE PROCEDURE CHAT_MESSAGE_SAVE(
  P_SESSION_ID  NUMBER,
  P_ROLE        VARCHAR,
  P_CONTENT     VARCHAR DEFAULT NULL,
  P_SQL         VARCHAR DEFAULT NULL,
  P_RESULT_JSON VARCHAR DEFAULT NULL,
  P_ROWS        NUMBER  DEFAULT NULL,
  P_LATENCY_MS  NUMBER  DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  V_TURN  NUMBER;
  V_OWNER VARCHAR;
BEGIN
  V_OWNER := (SELECT USER_ID FROM MENDIX_APP.AGENTS.CHAT_SESSION WHERE SESSION_ID = :P_SESSION_ID);
  IF (V_OWNER IS NULL) THEN
    RETURN 'ERROR: session not found';
  END IF;
  IF (V_OWNER <> CURRENT_USER()) THEN
    RETURN 'ERROR: not your session';
  END IF;
  V_TURN := (SELECT COALESCE(MAX(TURN_INDEX), -1) + 1 FROM MENDIX_APP.AGENTS.CHAT_MESSAGE WHERE SESSION_ID = :P_SESSION_ID);
  INSERT INTO MENDIX_APP.AGENTS.CHAT_MESSAGE
    (SESSION_ID, TURN_INDEX, ROLE, CONTENT, SQL_TEXT, RESULT_JSON, ROW_COUNT, LATENCY_MS, CREATED_AT)
  SELECT :P_SESSION_ID, :V_TURN, :P_ROLE, :P_CONTENT, :P_SQL, :P_RESULT_JSON, :P_ROWS, :P_LATENCY_MS, CURRENT_TIMESTAMP();
  UPDATE MENDIX_APP.AGENTS.CHAT_SESSION
     SET MESSAGE_COUNT = COALESCE(MESSAGE_COUNT, 0) + 1,
         SESSION_END   = CURRENT_TIMESTAMP(),
         TITLE = CASE WHEN TITLE IS NULL AND :P_ROLE = 'user' THEN LEFT(:P_CONTENT, 120) ELSE TITLE END
   WHERE SESSION_ID = :P_SESSION_ID;
  RETURN 'OK:' || :V_TURN;
END;
$$;

CREATE OR REPLACE PROCEDURE CHAT_SESSION_LIST()
RETURNS TABLE(SESSION_ID NUMBER, TITLE VARCHAR, MESSAGE_COUNT NUMBER, LANGUAGE VARCHAR, SESSION_START TIMESTAMP_NTZ, SESSION_END TIMESTAMP_NTZ)
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  RS RESULTSET;
BEGIN
  RS := (
    SELECT SESSION_ID,
           COALESCE(TITLE, 'Untitled conversation') AS TITLE,
           COALESCE(MESSAGE_COUNT, 0) AS MESSAGE_COUNT,
           LANGUAGE, SESSION_START, SESSION_END
    FROM MENDIX_APP.AGENTS.CHAT_SESSION
    WHERE USER_ID = CURRENT_USER()
      AND COALESCE(MESSAGE_COUNT, 0) > 0
    ORDER BY COALESCE(SESSION_END, SESSION_START) DESC
    LIMIT 20
  );
  RETURN TABLE(RS);
END;
$$;

CREATE OR REPLACE PROCEDURE CHAT_SESSION_LOAD(P_SESSION_ID NUMBER)
RETURNS TABLE(TURN_INDEX NUMBER, ROLE VARCHAR, CONTENT VARCHAR, SQL_TEXT VARCHAR, RESULT_JSON VARCHAR, ROW_COUNT NUMBER, LATENCY_MS NUMBER, CREATED_AT TIMESTAMP_NTZ)
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  RS RESULTSET;
BEGIN
  RS := (
    SELECT m.TURN_INDEX, m.ROLE, m.CONTENT, m.SQL_TEXT, m.RESULT_JSON,
           m.ROW_COUNT, m.LATENCY_MS, m.CREATED_AT
    FROM MENDIX_APP.AGENTS.CHAT_MESSAGE m
    JOIN MENDIX_APP.AGENTS.CHAT_SESSION s ON s.SESSION_ID = m.SESSION_ID
    WHERE m.SESSION_ID = :P_SESSION_ID
      AND s.USER_ID = CURRENT_USER()
    ORDER BY m.TURN_INDEX
  );
  RETURN TABLE(RS);
END;
$$;

CREATE OR REPLACE PROCEDURE CHAT_SESSION_DELETE(P_SESSION_ID NUMBER)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  V_OWNER VARCHAR;
BEGIN
  V_OWNER := (SELECT USER_ID FROM MENDIX_APP.AGENTS.CHAT_SESSION WHERE SESSION_ID = :P_SESSION_ID);
  IF (V_OWNER IS NULL) THEN
    RETURN 'ERROR: session not found';
  END IF;
  IF (V_OWNER <> CURRENT_USER()) THEN
    RETURN 'ERROR: not your session';
  END IF;
  DELETE FROM MENDIX_APP.AGENTS.CHAT_MESSAGE WHERE SESSION_ID = :P_SESSION_ID;
  DELETE FROM MENDIX_APP.AGENTS.CHAT_SESSION WHERE SESSION_ID = :P_SESSION_ID;
  RETURN 'DELETED';
END;
$$;

CREATE OR REPLACE PROCEDURE CHAT_SESSION_RENAME(P_SESSION_ID NUMBER, P_TITLE VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  V_OWNER VARCHAR;
BEGIN
  V_OWNER := (SELECT USER_ID FROM MENDIX_APP.AGENTS.CHAT_SESSION WHERE SESSION_ID = :P_SESSION_ID);
  IF (V_OWNER IS NULL) THEN
    RETURN 'ERROR: session not found';
  END IF;
  IF (V_OWNER <> CURRENT_USER()) THEN
    RETURN 'ERROR: not your session';
  END IF;
  UPDATE MENDIX_APP.AGENTS.CHAT_SESSION SET TITLE = LEFT(:P_TITLE, 120) WHERE SESSION_ID = :P_SESSION_ID;
  RETURN 'RENAMED';
END;
$$;

-- ---------------------------------------------------------------------------
-- Grants for the read-only evaluator role
--
-- NOTE: CREATE OR REPLACE PROCEDURE drops existing grants on that procedure.
-- Re-run this block after redeploying any procedure above.
-- ---------------------------------------------------------------------------

GRANT USAGE ON PROCEDURE CHAT_SESSION_NEW(VARCHAR) TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON PROCEDURE CHAT_MESSAGE_SAVE(NUMBER, VARCHAR, VARCHAR, VARCHAR, VARCHAR, NUMBER, NUMBER) TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON PROCEDURE CHAT_SESSION_LIST() TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON PROCEDURE CHAT_SESSION_LOAD(NUMBER) TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON PROCEDURE CHAT_SESSION_DELETE(NUMBER) TO ROLE HACKATHON_JUDGE_ROLE;
GRANT USAGE ON PROCEDURE CHAT_SESSION_RENAME(NUMBER, VARCHAR) TO ROLE HACKATHON_JUDGE_ROLE;

-- Deliberately NOT granted: SELECT/INSERT on CHAT_MESSAGE. The evaluator role
-- must reach chat history only through the owner-rights procedures above.

-- ---------------------------------------------------------------------------
-- Verification
--
-- IMPORTANT: `USE ROLE HACKATHON_JUDGE_ROLE` alone is NOT a least-privilege
-- test. If the developer account has secondary roles enabled (ACCOUNTADMIN
-- among them), privileges from those roles still apply and a missing grant
-- will go undetected. Disable them first.
-- ---------------------------------------------------------------------------

/*
USE SECONDARY ROLES NONE;
USE ROLE HACKATHON_JUDGE_ROLE;

-- Must fail with "does not exist or not authorized":
SELECT COUNT(*) FROM MENDIX_APP.AGENTS.CHAT_MESSAGE;

-- Must all succeed:
CALL CHAT_SESSION_NEW('EN');                                    -- returns SESSION_ID
CALL CHAT_MESSAGE_SAVE(<id>, 'user', 'test question');          -- returns OK:0
CALL CHAT_SESSION_LIST();                                       -- shows the session, title auto-derived
CALL CHAT_SESSION_LOAD(<id>);                                   -- shows the turn
CALL CHAT_SESSION_DELETE(<id>);                                 -- returns DELETED

-- Cross-user isolation: against a SESSION_ID owned by another user, these must
-- return 'ERROR: not your session' / no rows, never data:
CALL CHAT_MESSAGE_SAVE(<other_users_id>, 'user', 'intrusion');
CALL CHAT_SESSION_DELETE(<other_users_id>);
CALL CHAT_SESSION_LOAD(<other_users_id>);

USE SECONDARY ROLES ALL;
USE ROLE ACCOUNTADMIN;
*/
