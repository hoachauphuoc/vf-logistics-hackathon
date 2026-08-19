"""Verify the 2026-08-19 pre-migration CSV export.

Counts rows with the csv module rather than counting newlines: several columns hold
free text with embedded newlines (procedure output, AI narratives, OCR snippets), so a
line count would understate every one of them and a "mismatch" would be an artefact of
the check rather than a real export problem.
"""

import csv
import sys
from pathlib import Path

DATA = Path(r"C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2"
            r"\snowflake-backend\backup_2026-08-19\data")

# Row counts as reported by the source account at export time, taken from
# ddl/baseline_hashes.tsv rather than retyped from memory.
BASELINE = DATA.parent / "ddl" / "baseline_hashes.tsv"


def expected_counts():
    counts = {}
    with BASELINE.open(encoding="utf-8") as fh:
        reader = csv.reader(fh, delimiter="\t")
        next(reader)                      # header: T, N, H
        for table, n, _hash in reader:
            counts[table] = int(n)
    return counts


def main() -> int:
    expected = expected_counts()
    if not expected:
        print("FAIL: could not read baseline_hashes.tsv")
        return 1

    problems = 0
    total = 0
    for table in sorted(expected):
        path = DATA / f"{table}.csv"
        if not path.exists():
            print(f"  MISSING   {table}")
            problems += 1
            continue

        # newline="" is required, otherwise the csv module and the file disagree
        # about embedded line breaks and rows get split.
        with path.open(encoding="utf-8", newline="") as fh:
            reader = csv.reader(fh)
            header = next(reader, None)
            rows = sum(1 for _ in reader)

        want = expected[table]
        ok = rows == want
        total += rows
        problems += 0 if ok else 1
        print(f"  {'OK ' if ok else 'BAD'}  {table:<26} rows={rows:<6} "
              f"expected={want:<6} cols={len(header) if header else 0}")

    print(f"\n{len(expected)} tables, {total} rows, {problems} problem(s)")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
