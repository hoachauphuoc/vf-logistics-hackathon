import gzip, os, sys

base = r"C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\snowflake-backend\backup_2026-08-01\data"

expected = {
    "AI_ANOMALY_REPORT": 1, "AI_CALL_LOG": 10, "APP_CONFIG": 13,
    "BILL_OF_LADING": 10025, "BILL_OF_LADING_EXTRACTED": 15,
    "BL_SEARCH_CORPUS": 10005, "CHAT_SESSION": 2,
    "COMPLIANCE_CHECK_RESULT": 3, "DT_CARRIER_PERFORMANCE": 10,
    "DT_ROUTE_ANALYTICS": 400, "DT_SHIPMENT_KPI": 1, "FRAUD_ALERT": 213,
    "HS_CODE_REFERENCE": 30, "NOTIFICATION_LOG": 54, "PORT_MASTER": 23,
    "SAP_FI_DOCUMENT": 19, "SAP_MM_GOODS_RECEIPT": 1,
    "VESSEL_REGISTRY": 21, "WORKFLOW_AUDIT_LOG": 117,
}

bad = 0
for table in sorted(expected):
    folder = os.path.join(base, table)
    rows = 0
    headers = 0
    for name in sorted(os.listdir(folder)):
        with gzip.open(os.path.join(folder, name), "rt", encoding="utf-8", errors="replace") as fh:
            content = fh.read()
        # a data row is a physical line minus the header; quoted newlines inflate
        # a naive line count, so count them the same way csv would
        import csv, io
        reader = csv.reader(io.StringIO(content))
        n = sum(1 for _ in reader)
        rows += n - 1
        headers += 1
    exp = expected[table]
    ok = "OK" if rows == exp else "MISMATCH"
    if rows != exp:
        bad += 1
    print(f"{table:<26} {rows:>6} / {exp:<6} headers={headers}  {ok}")

print("----")
print(f"tables with mismatched row counts: {bad}")
print(f"total data rows verified: {sum(expected.values())}")
sys.exit(1 if bad else 0)
