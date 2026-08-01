# Cortex Agent configuration — `VF_LOGISTICS_AGENT`

**This is the only part of the backend that could not be exported programmatically.**
Snowflake provides no supported export path for agents:

| Attempt | Result |
|---|---|
| `GET_DDL('AGENT', 'MENDIX_APP.AGENTS.VF_LOGISTICS_AGENT')` | `Invalid object type: 'AGENT'` |
| `DESCRIBE AGENT MENDIX_APP.AGENTS.VF_LOGISTICS_AGENT` | returns a row, but `agent_spec` is empty |
| `SHOW VERSIONS IN AGENT ...` | only the path `snow://agent/MENDIX_APP.AGENTS.VF_LOGISTICS_AGENT/versions/version$1/` |

So this file has to be filled in by reading the agent in Snowsight while the source
account is still alive:

> Snowsight → **AI & ML** → **Agents** → `VF_LOGISTICS_AGENT` → **Edit**

Metadata captured from `SHOW AGENTS` on 2026-08-01:

| Property | Value |
|---|---|
| Fully qualified name | `MENDIX_APP.AGENTS.VF_LOGISTICS_AGENT` |
| Created | 2026-07-23 01:41:46 -0700 |
| Owner | `ACCOUNTADMIN` |
| Default version | `LAST` → `VERSION$1` |
| Aliases | `DEFAULT`, `FIRST`, `LAST` all → `VERSION$1` |
| Comment | *(empty)* |
| Profile | *(empty)* |

---

## 1. Orchestration

| Setting | Value |
|---|---|
| Model | _paste from Snowsight (e.g. `auto`, `claude-sonnet-4-5`)_ |
| Orchestration instructions | _paste_ |

## 2. Instructions

### Response instructions
```
_paste the response instructions verbatim_
```

### Planning instructions
```
_paste the planning instructions verbatim_
```

### Sample questions
```
_paste any sample/starter questions_
```

## 3. Tools

Five tools are expected, based on the workflow procedures the agent was built
around. Confirm the real list and parameter wiring in Snowsight.

| # | Type | Target | Notes |
|---|---|---|---|
| 1 | Cortex Analyst | `MENDIX_APP.AGENTS.SV_LOGISTICS` | semantic view, natural-language analytics |
| 2 | Cortex Search | `MENDIX_APP.AGENTS.BL_SEARCH_SERVICE` | must be RESUMED before use |
| 3 | Custom / SQL | `CALL MENDIX_APP.AGENTS.WORKFLOW_DETECT_AND_ACT()` | rule-based alert detection |
| 4 | Custom / SQL | `CALL MENDIX_APP.AGENTS.WORKFLOW_INVESTIGATE_ANOMALY(:alert_id)` | AI decides BLOCK / ESCALATE / CLEAR |
| 5 | Custom / SQL | `CALL MENDIX_APP.AGENTS.WORKFLOW_AUTO_REMEDIATE(:alert_id, :action)` | executes the decision |

For each tool also record: display name, description shown to the model,
parameter names and types, and whether confirmation is required before execution.

## 4. Access

| Setting | Value |
|---|---|
| Warehouse | _paste_ |
| Roles granted USAGE | _paste_ |

---

## If this file stays unfilled

The prototype is still fully demonstrable without the agent — it is a convenience
surface, not the engine. Every capability it exposes is reachable from SQL, and the
two entry points below cover the entire flow end to end:

```sql
-- PDF on the stage -> AI extraction -> promotion -> alert -> AI decision -> action
CALL MENDIX_APP.AGENTS.WORKFLOW_INGEST_AND_DECIDE();

-- detect -> investigate -> act, over existing shipments
CALL MENDIX_APP.AGENTS.WORKFLOW_FULL_PIPELINE_V2('AUTO');

-- what the AI decided, and why
SELECT * FROM MENDIX_APP.AGENTS.V_AI_DECISIONS;
```

Rebuilding the agent from the tool table above takes a few minutes in Snowsight;
only the hand-written instruction text is genuinely lost.
