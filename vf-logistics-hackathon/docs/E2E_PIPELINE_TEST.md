# End-to-End Pipeline Test — 10 Bills of Lading

Run 2026-08-18. Reproduce with:

```bash
python vf-logistics-hackathon/tools/make_test_bills.py    # writes the 10 PDFs
# then PUT them to @LOGISTICS_STAGE/bill_of_lading/ and CALL WORKFLOW_INGEST_AND_DECIDE()
```

## Why the expectations are trustworthy

The expected verdict for each document was **not written by hand**. Each scenario's
five validated fields were run through `BL_DOC_ALERT` and `BL_DOC_CONFIDENCE`
first, and the PDF generator then read those rows to build the documents. So the
expectations come from the rules themselves, and the PDFs cannot drift out of step
with the assertions. What the test measures is therefore the part that could
actually be wrong: OCR, LLM extraction, and the wiring between them and the
validator.

## Coverage

All six branches of `BL_DOC_ALERT` plus the clean path:

| Rule | Exercised by |
|---|---|
| `BlNumber` | T02, T10 |
| `ContainerNumber` | T03 (XXXX placeholder), T04 (truncated), T10 |
| `VesselName` | T05, T10 |
| `GrossWeightKg` | T06 (tonnes in a kg field), T07 (implausible), T10 |
| `DateOfIssue` | T08, T10 |
| `CarrierMismatch` | T09 |
| no finding | T01 |

Two cases are specifically false-positive guards: `BERLIN EXPRESS` (T07) and
`EVER GIVEN` (T09) are real vessels whose names contain no carrier token, and
`CARRIER_FROM_VESSEL` correctly returns NULL for both, so neither is wrongly
flagged as a carrier mismatch.

## Result: 10 / 10 pass

| Case | Scenario | Expected alert | Actual | Conf | Status |
|---|---|---|---|---|---|
| T01 | all fields valid, carrier consistent | *(none)* | *(none)* | 100 = 100 | `AI_Processed` |
| T02 | B/L number absent from the document | `BlNumber` | `BlNumber` | 83 = 83 | `Pending_Review` |
| T03 | container is the `XXXX` OCR placeholder | `ContainerNumber` | `ContainerNumber` | 83 = 83 | `Pending_Review` |
| T04 | container truncated below 8 chars | `ContainerNumber` | `ContainerNumber` | 83 = 83 | `Pending_Review` |
| T05 | vessel name collapsed to `MV` | `VesselName` | `VesselName` | 83 = 83 | `Pending_Review` |
| T06 | `24.5` left in a kilogram field | `GrossWeightKg` | `GrossWeightKg` | 83 = 83 | `Pending_Review` |
| T07 | weight `250000` exceeds any real payload | `GrossWeightKg` | `GrossWeightKg` | 83 = 83 | `Pending_Review` |
| T08 | issue date `2019-06-14` | `DateOfIssue` | `DateOfIssue` | 83 = 83 | `Pending_Review` |
| T09 | Evergreen B/L, Maersk container | `CarrierMismatch` | `CarrierMismatch` | 83 = 83 | `Pending_Review` |
| T10 | five rules at once | `BlNumber; ContainerNumber; VesselName; GrossWeightKg; DateOfIssue` | identical | 17 = 17 | `Pending_Review` |

**Extraction was exact on all 50 field comparisons** (10 documents x 5 validated
fields), including every awkward case: a missing label returning NULL rather than
a hallucinated number, `24.5` not rounded to `25`, `250000` not truncated,
`MSCU12` not "corrected" to a plausible 11-character container, and
`XXXX0000000` preserved rather than silently repaired.

Pipeline summary: `{"processed":10,"errors":0,"synced":true}`, then
`FULL_PIPELINE_V2` completed with one alert escalated. Total 272s, dominated by
Cortex extraction of 10 two-page documents.

## Two defects the test found

**1. `ALERT_RESPONSE` was never populated.** All 10 new documents had a NULL
narrative while all 15 pre-existing ones had it — so this was a regression
introduced when the alert prompt was rewritten during the deterministic-validation
fix, not a pre-existing gap. Cause, confirmed by calling the model directly rather
than by reading the code: it returns

```
 ```json { "Alert": "...", "AlertResponse": "..." } ```
```

with a leading space *before* the fence, so the existing `'^```json\s*|\s*```$'`
strip could not match at position 0 and `TRY_PARSE_JSON` returned NULL. Fixed by
trimming to the first `{` and last `}` — the same idiom the procedure already uses
for the extraction JSON. Verified by deleting one test row, reprocessing that file,
and confirming the narrative appeared while the verdict stayed identical.

The narrative also holds the invariant the submission claims: for T07 it reads
*"The GrossWeightKg value of 250000 exceeds the maximum allowed value of 100000"* —
explaining the deterministic verdict rather than re-deciding it.

**2. `TASK_COMPLIANCE_CHECK` had queued the entire table.** The baseline snapshot
showed `COMPLIANCE_QUEUE` holding 10,017 rows spanning every B/L, where it should
have held only genuinely new arrivals. A stream renders an UPDATE as a DELETE row
plus an INSERT row, both flagged `METADATA$ISUPDATE = TRUE`, so the filter
`METADATA$ACTION = 'INSERT'` also matched the insert half of every update — and
`CHECK_COMPLIANCE` writes back to `BILL_OF_LADING`, so the compliance backfill's
10,017 updates all leaked through. Proven with an isolated two-row stream rather
than assumed. Fixed by adding `AND METADATA$ISUPDATE = FALSE`, emptying the queue,
and removing the 25 rows five runaway task runs had added.

## Two limitations of this test — both since fixed

Both were reported as limitations of the run above and have since been root-caused and
repaired. They are kept here because the fix is only meaningful next to the symptom.

- **The fraud path was throttled, not exercised.** `FRAUD_ALERT` gained zero rows
  because the open queue already sat at `P_QUEUE_LIMIT = 100`, so
  `WORKFLOW_DETECT_AND_ACT` correctly declined to add more.

  **Root cause:** the gate counted *every* `OPEN` `HIGH`/`MEDIUM` alert ever raised,
  with no time bound. That number only grows, so once the lifetime backlog crossed the
  limit the detector switched itself off permanently — a one-way latch, not
  backpressure. 106 open alerts against a limit of 100 meant every future run would
  return `throttled: true` and add nothing, and no detection rule would ever run again.

  **Fix:** the queue is now a 7-day rolling window — the alerts a human could still
  plausibly be working. The same 106 alerts are 47 inside that window. Verified:
  `WORKFLOW_DETECT_AND_ACT()` returned
  `{"throttled":false,"new_alerts":8,"high_severity_open":4}`, where it had previously
  returned `throttled: true` with zero alerts on every invocation. The 8 verification
  alerts were then deleted and `FRAUD_ALERT` is back to 496 rows.

- **`AI_CALL_LOG` gained only 1 row** for a run that made at least 20 Cortex calls
  (two per document). Extraction calls were not logged, so the FinOps page's cost
  attribution understated real usage.

  **Root cause:** `PROCESS_BL_DOCUMENTS` made both of its Cortex calls —
  `PARSE_DOCUMENT` for OCR and `COMPLETE` for field extraction — without writing to
  the ledger at all.

  Fixing that surfaced a second defect underneath it. `AI_CALL_LOG.CALL_ID` was
  `autoincrement start 1 ... noorder`, while seeded data already used ids up to 703, so
  **69 `CALL_ID`s and 66 `LOG_ID`s were duplicated** — the same unenforced-primary-key
  trap that broke `FRAUD_ALERT.ALERT_ID`. `noorder` allocates ids from non-monotonic
  cached ranges, which is why burning the counter forward does not work: two
  consecutive single-row inserts were observed to receive 313 and then 651. The table
  was rebuilt with both id columns defaulting to dedicated `SEQUENCE` objects starting
  at 100000, and the 423 historical rows reloaded with dense ids. `HASH_AGG` over all
  non-id columns is byte-identical to the pre-fix clone, so only ids changed.

  **Fix verified live:** one PDF was processed end to end and produced exactly two log
  rows — `BL_EXTRACTION_OCR` (1,315 ms) and `BL_EXTRACTION_JSON` (15,445 ms, 1,082
  input + 413 output = 1,495 tokens via `COUNT_TOKENS`) — with ids 100002 and 100003.
  The test document, its bill of lading, its log rows and its stage file were then
  removed, restoring 423 / 15 / 15 / 10,017.

  `PARSE_DOCUMENT` is billed per page rather than per token, so its token columns are
  left `NULL` rather than filled with a guess.

### Residual, not fixed

A full 7-day window could itself reach the limit, and the gate still suppresses
**all** severities when it trips — a saturated queue of `MEDIUM` alerts can therefore
still delay `HIGH`-severity detection. Making the `HIGH` rules bypass the gate means
restructuring the `IF`/`ELSE` around five separate `INSERT` statements, which is not a
change worth making unverified this close to the deadline. The window fix removes the
permanent latch, which was the actual defect.

A third, smaller observation: deleting a row from `BILL_OF_LADING_EXTRACTED` and
reprocessing the file produced a **second** `BILL_OF_LADING` row for the same
document, because `SYNC_EXTRACTED_TO_BILL_OF_LADING` does not deduplicate. The
normal pipeline never deletes, so this is a robustness gap rather than a live bug.

## Restoration

The system was returned to its pre-test state and the restoration was **proven,
not assumed**:

| Check | Result |
|---|---|
| Row counts across all 33 tables | 33 / 33 match the pre-test baseline |
| Content hashes (`HASH_AGG`) across all 33 tables | 32 identical; only `DT_SHIPMENT_KPI` differs |
| `DT_SHIPMENT_KPI` difference | Its definition contains `CURRENT_TIMESTAMP() AS REFRESHED_AT`, so its hash is time-dependent by design (hence `refresh_mode = FULL`). Every business column matches |
| Stage inventory | back to 15 PDFs, 0 `TEST_` files |
| Streams | all 7 disarmed, so no task fires unprompted during a demo recording |
| Tasks | all 7 `started` |
| Judge grants | 102, all procedures re-granted after `CREATE OR REPLACE` |
| Extracted-document state | 8 `Pending_Review` / 6 `AI_Processed` / 1 `Synced_To_SAP`, 0 alert or confidence mismatches against the UDFs |

Method: a zero-copy `CREATE SCHEMA ... CLONE` snapshot taken before the test, then
`INSERT OVERWRITE ... SELECT * FROM <clone>` per changed table. `INSERT OVERWRITE`
rather than `CREATE OR REPLACE TABLE` because the latter would have silently
dropped every grant. The three `DT_` dynamic tables were **not** overwritten — they
are derived, so removing the source rows and forcing `ALTER DYNAMIC TABLE ...
REFRESH` re-derived them correctly.

Row counts alone would have declared success prematurely: `FRAUD_ALERT` had the
same 496 rows before and after, but a different content hash, because the pipeline
had updated alert 1409 in place from `OPEN` to `ESCALATED`. Only the checksum
caught it.

The 10 PDFs remain in `sample_documents/pdf/test_cases/` and in git, so the test
can be re-run at any time.
