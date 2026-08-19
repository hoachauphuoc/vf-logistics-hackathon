import csv
from pathlib import Path
from collections import Counter

DATA = Path(r"C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2"
            r"\snowflake-backend\backup_2026-08-19\data")

CHECKS = {
    "NOTIFICATION_LOG": "NOTIFICATION_ID",
    "SAP_FI_DOCUMENT": "FI_DOC_ID",
    "WORKFLOW_AUDIT_LOG": "AUDIT_ID",
}

for table, col in CHECKS.items():
    path = DATA / f"{table}.csv"
    with path.open(encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh)
        ids = [row[col] for row in reader]
    counts = Counter(ids)
    dups = {k: v for k, v in counts.items() if v > 1}
    print(f"{table}.{col}: {len(ids)} rows, {len(dups)} duplicated ids, "
          f"{sum(dups.values())} rows affected")
    for k in sorted(dups, key=lambda x: -dups[x])[:5]:
        print(f"    id={k} appears {dups[k]}x")
