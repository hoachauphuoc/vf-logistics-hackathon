# Skill 2: Compliance & Sanctions Screening

## Metadata
| Field | Value |
|-------|-------|
| **Skill Name** | `compliance_and_sanctions_screening` |
| **Category** | Regulatory Compliance |
| **Snowflake Objects** | `CHECK_COMPLIANCE(BL_ID)`, `WORKFLOW_SANCTIONS_SCREEN(entity_name)`, `BATCH_CHECK_COMPLIANCE()`, `HS_CODE_REFERENCE` table, **Snowflake Marketplace**: `SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE.INTERNATIONAL_TRADE_ADMINISTRATION_EXPORT_SCREENED_ENTITIES_INDEX` |
| **Trigger Phrases** | "Check compliance for BL #X", "Screen shipper against sanctions list", "Is this shipment restricted?" |
| **CLI Entry Point** | `CALL MENDIX_APP.AGENTS.CHECK_COMPLIANCE(<bl_id>);` / `CALL MENDIX_APP.AGENTS.WORKFLOW_SANCTIONS_SCREEN('<entity_name>');` |

## Purpose
Validates shipments against trade compliance rules (restricted HS codes, dangerous goods, overweight) AND screens shipper/consignee names against a **real-time Snowflake Marketplace dataset** of US Government export-restricted entities — demonstrating live third-party data integration, not static/mocked data.

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
{"workflow":"SANCTIONS_SCREEN","entity":"SUSPICIOUS TRADING CO","matches_found":0,"risk_level":"CLEAR","action":"No matches on screening lists. Entity cleared for trade."}
```

## Snowflake Marketplace Integration (Key Differentiator)
This Skill queries `SNOWFLAKE_PUBLIC_DATA_FREE` — a **live Snowflake Marketplace share** (listing `GZTSZ290BV255`), not a static CSV. This satisfies the hackathon's bonus judging criterion for Marketplace usage (Section 9, item 4) with a genuine real-world compliance use case (OFAC/BIS-style export screening).

## Error Handling
- Handles missing HS code reference (`COALESCE(..., FALSE)` defaults to non-restricted)
- `SAFE_CHECK_COMPLIANCE` wrapper procedure available for budget-safe batch runs

## Downstream Skill
Feeds risk signals into **Skill 3: AI Investigation & Remediation** for final action decision.
