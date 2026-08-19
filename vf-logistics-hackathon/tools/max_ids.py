import csv
from pathlib import Path

DATA = Path(r"C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2"
            r"\snowflake-backend\backup_2026-08-19\data")

TABLES = {
    "AI_ANOMALY_REPORT": "REPORT_ID",
    "BILL_OF_LADING": "BL_ID",
    "BILL_OF_LADING_EXTRACTED": "DOC_ID",
    "CHAT_MESSAGE": "MESSAGE_ID",
    "COMPLIANCE_CHECK_RESULT": "CHECK_ID",
    "FRAUD_ALERT": "ALERT_ID",
    "NOTIFICATION_LOG": "NOTIFICATION_ID",
    "SAP_FI_DOCUMENT": "FI_DOC_ID",
    "VESSEL_REGISTRY": "VESSEL_ID",
    "WORKFLOW_AUDIT_LOG": "AUDIT_ID",
}

for table, col in TABLES.items():
    path = DATA / f"{table}.csv"
    with path.open(encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh)
        idx = reader.fieldnames.index(col) if col in reader.fieldnames else None
        ids = [int(row[col]) for row in reader if row[col]]
    print(f"{table:<26} {col:<18} max={max(ids):<8} n={len(ids)}")
