"""Compute deck figures from the 2026-08-19 backup CSVs.

The presentation must quote the state the judges will actually see, which is a restore
of this backup -- not the pre-refinement state still sitting on AYUGBCE-JX50275. So
every number that goes on a slide is derived here from the exported data rather than
retyped from an older deck or from memory.
"""

import csv
from collections import Counter
from pathlib import Path

DATA = Path(r"C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2"
            r"\snowflake-backend\backup_2026-08-19\data")


def rows(name):
    with (DATA / f"{name}.csv").open(encoding="utf-8", newline="") as fh:
        yield from csv.DictReader(fh)


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def main():
    bl = list(rows("BILL_OF_LADING"))
    print(f"BILL_OF_LADING rows            : {len(bl)}")

    charges = [num(r["TOTAL_CHARGES"]) for r in bl]
    charges = [c for c in charges if c is not None]
    print(f"  SUM(TOTAL_CHARGES)           : ${sum(charges):,.0f}  "
          f"(n={len(charges)})")

    # COMPLIANCE_CHECK_PASSED is what the backfill wrote. TRUE/FALSE/empty.
    comp = Counter((r.get("COMPLIANCE_CHECK_PASSED") or "").strip().upper()
                   for r in bl)
    print(f"  COMPLIANCE_CHECK_PASSED      : {dict(comp)}")
    passed = comp.get("TRUE", 0)
    failed = comp.get("FALSE", 0)
    unchecked = len(bl) - passed - failed
    if len(bl):
        print(f"    pass={passed}  fail={failed} "
              f"({failed / len(bl) * 100:.1f}%)  unchecked={unchecked}")

    status = Counter((r.get("STATUS") or "").strip() for r in bl)
    print(f"  STATUS                       : {dict(status)}")

    carriers = {(r.get("CARRIER_NAME") or "").strip() for r in bl}
    carriers.discard("")
    print(f"  distinct carriers            : {len(carriers)}")

    ex = list(rows("BILL_OF_LADING_EXTRACTED"))
    print(f"\nBILL_OF_LADING_EXTRACTED rows  : {len(ex)}")
    print(f"  STATUS                       : "
          f"{dict(Counter((r.get('STATUS') or '').strip() for r in ex))}")
    conf = [num(r.get("CONFIDENCE_SCORE")) for r in ex]
    conf = [c for c in conf if c is not None]
    if conf:
        print(f"  CONFIDENCE_SCORE avg/min/max : "
              f"{sum(conf)/len(conf):.1f} / {min(conf):.0f} / {max(conf):.0f}")

    fa = list(rows("FRAUD_ALERT"))
    print(f"\nFRAUD_ALERT rows               : {len(fa)}")
    print(f"  SEVERITY                     : "
          f"{dict(Counter((r.get('SEVERITY') or '').strip() for r in fa))}")
    print(f"  STATUS                       : "
          f"{dict(Counter((r.get('STATUS') or '').strip() for r in fa))}")
    dec = Counter((r.get("AI_DECISION") or "").strip() for r in fa)
    print(f"  AI_DECISION                  : {dict(dec)}")

    for t in ("COMPLIANCE_CHECK_RESULT", "AI_CALL_LOG", "WORKFLOW_AUDIT_LOG",
              "SAP_FI_DOCUMENT", "NOTIFICATION_LOG", "CHAT_MESSAGE",
              "AI_ANOMALY_REPORT"):
        print(f"{t:<31}: {sum(1 for _ in rows(t))}")


if __name__ == "__main__":
    main()
