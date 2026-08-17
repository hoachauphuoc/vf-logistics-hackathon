# Skill 2: Compliance & Sanctions Screening

## Metadata
| Field | Value |
|-------|-------|
| **Skill Name** | `compliance_and_sanctions_screening` |
| **Category** | Regulatory Compliance |
| **Snowflake Objects** | `CHECK_COMPLIANCE(BL_ID)`, `WORKFLOW_SANCTIONS_SCREEN(entity_name)`, `BATCH_CHECK_COMPLIANCE()`, `HS_CODE_REFERENCE` table, `V_SANCTIONS_SCREENING_SOURCE` view over **Snowflake Marketplace** listing `GZTSZ290BV255` (`SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.INTERNATIONAL_TRADE_ADMINISTRATION_EXPORT_SCREENED_ENTITIES_INDEX` / `..._INDEX_PIT`) |
| **Trigger Phrases** | "Check compliance for BL #X", "Screen shipper against sanctions list", "Is this shipment restricted?" |
| **CLI Entry Point** | `CALL MENDIX_APP.AGENTS.CHECK_COMPLIANCE(<bl_id>);` / `CALL MENDIX_APP.AGENTS.WORKFLOW_SANCTIONS_SCREEN('<entity_name>');` |

## Purpose
Validates shipments against trade compliance rules (restricted HS codes, dangerous goods, overweight) AND screens shipper/consignee names against a **real US Government export-restricted-entities dataset obtained from Snowflake Marketplace** — genuine third-party data, not a static/mocked list bundled with the project.

> **Data freshness, stated honestly:** the query is live against the Marketplace share, but the provider's *content* is not currently being refreshed — its current table is empty and its point-in-time table ends `2024-04-10`. `V_SANCTIONS_SCREENING_SOURCE` therefore prefers the current table and falls back to the point-in-time snapshot, and every screen result includes a `data_basis` field naming which one was used. Before 2026-08-17 the procedures queried the empty current table directly, which made every screen return `CLEAR`; that defect is described in `docs/COCO_CLI_EVIDENCE.md` §2.9.

## Decision Branches

### CHECK_COMPLIANCE (rule-based scoring)
| Rule | Risk Score | Compliant? |
|------|-----------|-----------|
| HS Code is restricted/requires permit | +30 | ❌ FALSE |
| Dangerous goods flag = TRUE | +20 | (score only) |
| Weight > 50,000 kg | +10 | (score only) |

### WORKFLOW_SANCTIONS_SCREEN (Marketplace-backed fuzzy match)
| Condition | Risk Level | Action |
|-----------|-----------|--------|
| Entity name matches Consolidated Screening List | CRITICAL | BLOCK |
| No match | CLEAR | Approve for trade |

## Input / Output Contract

**Input**: `BL_ID` (NUMBER) or entity name (VARCHAR)

**Output** (Compliance check):
```json
{"compliant": false, "risk_score": 30, "violations": ["RESTRICTED_HS_CODE"]}
```

**Output** (Sanctions screen):
```json
{"workflow":"SANCTIONS_SCREEN","entity":"Jsc Element","matches_found":1,"risk_level":"CRITICAL","data_basis":"HISTORICAL_SNAPSHOT_TO_2024_04_10","action":"BLOCK - Entity appears on US Government Consolidated Screening List (Snowflake Marketplace listing GZTSZ290BV255)"}
```

## Snowflake Marketplace Integration (Key Differentiator)
This Skill queries `SNOWFLAKE_PUBLIC_DATA_FREE` — a **Snowflake Marketplace share** (listing `GZTSZ290BV255`), not a static CSV shipped with the project. This satisfies the hackathon's bonus judging criterion for Marketplace usage (Section 9, item 4) with a genuine real-world compliance use case (OFAC/BIS-style export screening). The share is queried live; see the freshness note under *Purpose* for the state of the provider's data.

## Error Handling
- Handles missing HS code reference (`COALESCE(..., FALSE)` defaults to non-restricted)
- `SAFE_CHECK_COMPLIANCE` wrapper procedure available for budget-safe batch runs

## Downstream Skill
Feeds risk signals into **Skill 3: AI Investigation & Remediation** for final action decision.
