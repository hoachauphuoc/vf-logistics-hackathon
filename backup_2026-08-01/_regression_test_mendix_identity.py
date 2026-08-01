"""
VF Logistics -- Production-identity regression smoke test
===========================================================

Purpose:
    Every other regression check in this backup (05_regression_tests_admin.sql)
    runs as ACCOUNTADMIN, which owns every object and therefore CANNOT detect a
    missing grant. The 2026-08-01 incident (missing INSERT on FRAUD_ALERT,
    WORKFLOW_AUDIT_LOG, NOTIFICATION_LOG, BILL_OF_LADING) was invisible to any
    admin-run check and only appeared when Mendix -- authenticating AS
    MENDIX_SERVICE_USER via key-pair, using VF_APP_ROLE -- actually called the
    workflow.

    This script reproduces EXACTLY that identity and connection method (same
    user, same role, same key-pair auth Mendix's Java actions use) and calls
    the same procedures the Mendix chat panel and Data Grids call. If this
    script passes, the live demo will not hit a privilege or auth error.

Run this AFTER 05_regression_tests_admin.sql reports zero failures, and again
as the final check before walking into a judging session.

Usage:
    python _regression_test_mendix_identity.py \\
        --account AYUGBCE-JX50275 \\
        --user MENDIX_SERVICE_USER \\
        --private-key "C:\\Users\\phuochoa\\Mendix\\VF_Logistics_Portal-main_2\\resources\\snowflake_key.p8"

    All flags default to the values used by the current Mendix build, so on
    this workstation `python _regression_test_mendix_identity.py` with no
    arguments is normally enough.

Requires: snowflake-connector-python (already installed in this environment)
"""

import argparse
import json
import sys

import snowflake.connector
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

DEFAULT_ACCOUNT = "AYUGBCE-JX50275"
DEFAULT_USER = "MENDIX_SERVICE_USER"
DEFAULT_ROLE = "VF_APP_ROLE"
DEFAULT_WAREHOUSE = "COMPUTE_WH"
DEFAULT_DATABASE = "MENDIX_APP"
DEFAULT_SCHEMA = "AGENTS"
DEFAULT_PRIVATE_KEY = (
    r"C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\resources\snowflake_key.p8"
)

results = []


def record(test_no, name, passed, detail):
    results.append((test_no, name, "PASS" if passed else "FAIL", detail))
    flag = "PASS" if passed else "FAIL"
    print(f"[{flag}] #{test_no} {name} -- {detail}")


def load_private_key(path: str) -> bytes:
    with open(path, "rb") as f:
        p_key = serialization.load_pem_private_key(
            f.read(), password=None, backend=default_backend()
        )
    return p_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def connect(args):
    pkb = load_private_key(args.private_key)
    return snowflake.connector.connect(
        account=args.account,
        user=args.user,
        private_key=pkb,
        role=args.role,
        warehouse=args.warehouse,
        database=args.database,
        schema=args.schema,
    )


def run_call(cur, test_no, name, sql, expect_substr=None):
    try:
        cur.execute(sql)
        row = cur.fetchone()
        value = row[0] if row else None
        text = value if isinstance(value, str) else json.dumps(value, default=str)
        ok = expect_substr is None or (text is not None and expect_substr in text)
        record(test_no, name, ok, text[:300] if text else "(no rows returned)")
        return value
    except Exception as exc:
        record(test_no, name, False, f"SQL ERROR: {exc}")
        return None


def run_query(cur, test_no, name, sql, check):
    try:
        cur.execute(sql)
        rows = cur.fetchall()
        ok, detail = check(rows)
        record(test_no, name, ok, detail)
        return rows
    except Exception as exc:
        record(test_no, name, False, f"SQL ERROR: {exc}")
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--account", default=DEFAULT_ACCOUNT)
    parser.add_argument("--user", default=DEFAULT_USER)
    parser.add_argument("--role", default=DEFAULT_ROLE)
    parser.add_argument("--warehouse", default=DEFAULT_WAREHOUSE)
    parser.add_argument("--database", default=DEFAULT_DATABASE)
    parser.add_argument("--schema", default=DEFAULT_SCHEMA)
    parser.add_argument("--private-key", default=DEFAULT_PRIVATE_KEY)
    parser.add_argument(
        "--skip-mutations",
        action="store_true",
        help="Skip calls that write data (WORKFLOW_INGEST_AND_DECIDE, "
        "WORKFLOW_FULL_PIPELINE_V2). Use this to re-run safely right before "
        "judges arrive without generating extra demo data.",
    )
    args = parser.parse_args()

    print(f"Connecting as {args.user} / role {args.role} via key-pair auth ...")
    try:
        conn = connect(args)
    except Exception as exc:
        record(0, "Key-pair connection as MENDIX_SERVICE_USER", False, str(exc))
        print_summary()
        sys.exit(1)

    record(0, "Key-pair connection as MENDIX_SERVICE_USER", True, "connected")
    cur = conn.cursor()

    # 1. Identity sanity -- prove we are really running as the production role
    run_query(
        cur, 1, "CURRENT_ROLE() is VF_APP_ROLE",
        "SELECT CURRENT_ROLE(), CURRENT_USER()",
        lambda rows: (
            rows[0][0] == args.role,
            f"role={rows[0][0]}, user={rows[0][1]}",
        ),
    )

    # 2. Read paths every Mendix Data Grid depends on
    run_query(
        cur, 2, "SELECT on BILL_OF_LADING (Data Grid read path)",
        "SELECT COUNT(*) FROM BILL_OF_LADING",
        lambda rows: (rows[0][0] > 0, f"{rows[0][0]} rows"),
    )
    run_query(
        cur, 3, "SELECT on V_AI_DECISIONS (judge dashboard)",
        "SELECT COUNT(*) FROM V_AI_DECISIONS",
        lambda rows: (rows[0][0] > 0, f"{rows[0][0]} rows"),
    )

    # 3. Cortex Search -- the exact "suspended service does not auto-resume"
    # trap from README_RESTORE.md
    run_query(
        cur, 4, "SEARCH_BILL_OF_LADING returns results",
        "CALL SEARCH_BILL_OF_LADING('dangerous goods Singapore', 5)",
        lambda rows: (len(rows) > 0, f"{len(rows)} row(s) returned"),
    )

    # 4. Semantic view / Cortex Analyst surface
    run_query(
        cur, 5, "SV_LOGISTICS semantic view is queryable",
        """
        SELECT * FROM SEMANTIC_VIEW(
            SV_LOGISTICS
            DIMENSIONS carrier_name
            METRICS total_revenue
        ) LIMIT 3
        """,
        lambda rows: (len(rows) > 0, f"{len(rows)} row(s) returned"),
    )

    if not args.skip_mutations:
        # 5. The actual write path that broke on 2026-08-01. This is the
        # single most important check in this whole file.
        run_call(
            cur, 6, "WORKFLOW_FULL_PIPELINE_V2('AUTO') completes end to end",
            "CALL WORKFLOW_FULL_PIPELINE_V2('AUTO')",
            expect_substr='"status":"COMPLETED"',
        )

        # 6. The Mendix chat panel's single entry point (PDF ingest -> decide)
        run_call(
            cur, 7, "WORKFLOW_INGEST_AND_DECIDE() completes end to end",
            "CALL WORKFLOW_INGEST_AND_DECIDE()",
            expect_substr='"status":"COMPLETED"',
        )
    else:
        record(6, "WORKFLOW_FULL_PIPELINE_V2('AUTO')", True, "skipped (--skip-mutations)")
        record(7, "WORKFLOW_INGEST_AND_DECIDE()", True, "skipped (--skip-mutations)")

    cur.close()
    conn.close()
    print_summary()


def print_summary():
    print("\n" + "=" * 70)
    failed = [r for r in results if r[2] == "FAIL"]
    for r in results:
        print(f"  [{r[2]}] #{r[0]} {r[1]}")
    print("=" * 70)
    if failed:
        print(f"RESULT: {len(failed)} FAILURE(S) -- DO NOT GO LIVE until fixed:")
        for r in failed:
            print(f"  - #{r[0]} {r[1]}: {r[3]}")
        sys.exit(1)
    else:
        print(f"RESULT: ALL {len(results)} CHECKS PASSED -- safe to demo as MENDIX_SERVICE_USER.")


if __name__ == "__main__":
    main()
