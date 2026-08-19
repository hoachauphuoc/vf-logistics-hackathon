"""Split a GET_DDL('SCHEMA', ...) dump into chunks that can be restored in order.

Why the splitting is character-scanned and not regex-matched
-----------------------------------------------------------
Two earlier attempts were wrong and it is worth recording why.

Splitting on ";" shreds procedure bodies, which are full of semicolons.

Splitting on /^create or replace/ in MULTILINE mode looks safer and is not: two of
the 52 procedures (DETECT_DUPLICATES, BATCH_CHECK_COMPLIANCE) create temporary
tables *inside their own bodies*:

    CREATE OR REPLACE TEMPORARY TABLE TEMP_DUPLICATES ...
    CREATE OR REPLACE TEMPORARY TABLE TMP_COMPLIANCE_B ...

Those lines match the pattern, so the splitter cut two procedures in half and would
have emitted both fragments as if they were top-level statements. The restore would
have failed with a syntax error somewhere in the middle of a 70 KB chunk.

So this walks the text one character at a time and only treats ";" as a terminator
when it is not inside a single-quoted literal, a $$-quoted block, or a comment.
GET_DDL emits procedure bodies as '...' with doubled quotes, which the scanner
handles as an escaped quote rather than as the end of the literal.

Deliberate exclusions
---------------------
* AI_CALL_LOG_BAK_IDFIX — a repair artefact from the duplicate-id fix, not schema.
  Carrying it over would put a stray *_BAK_ table in front of an evaluator.
* CREATE OR REPLACE SCHEMA — replaying it mid-restore drops everything created so
  far, and re-running any later chunk would wipe the schema. Created once during
  bootstrap with CREATE SCHEMA IF NOT EXISTS instead.

Stages are not in the dump at all (GET_DDL cannot produce them) — see
ddl/00_stages.sql, which must run first because a stream reads the stage directory.
"""

import re
import sys
from collections import Counter
from pathlib import Path

DDL = Path(r"C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\snowflake-backend"
           r"\backup_2026-08-19\ddl\01_schema_ddl.sql")
OUT = DDL.parent / "chunks"

SKIP_OBJECTS = ("AI_CALL_LOG_BAK_IDFIX",)

# Restore order. Tags come first because table DDL can carry WITH TAG references.
# Functions precede views because views call UDFs such as CARRIER_FROM_CODE.
ORDER = [
    ("05_tags",                  ["TAG"]),
    ("10_sequences_and_formats", ["SEQUENCE", "FILE FORMAT"]),
    ("20_tables",                ["TABLE"]),
    ("30_functions",             ["FUNCTION"]),
    ("40_views",                 ["VIEW"]),
    ("50_dynamic_tables",        ["DYNAMIC TABLE"]),
    ("60_procedures",            ["PROCEDURE"]),
    ("70_search_service",        ["CORTEX SEARCH SERVICE"]),
    ("80_streams",               ["STREAM"]),
    ("90_tasks",                 ["TASK"]),
    ("95_streamlit",             ["STREAMLIT"]),
]

# 52 procedures in one file is ~70 KB; the 2026-07-23 restore hit a statement-size
# limit doing exactly that.
PROC_CHUNK = 14

KIND_RE = re.compile(
    r"create\s+or\s+replace\s+(?:(?:TRANSIENT|TEMPORARY|SECURE|LOCAL|GLOBAL)\s+)*"
    r"(DYNAMIC\s+TABLE|CORTEX\s+SEARCH\s+SERVICE|FILE\s+FORMAT|TABLE|VIEW|"
    r"PROCEDURE|FUNCTION|STREAM|TASK|STREAMLIT|SEQUENCE|SCHEMA|TAG)\b",
    re.I)


def split_statements(text: str):
    """Yield top-level statements by locating each CREATE OR REPLACE at depth 0.

    Terminating on ";" does not work here: GET_DDL emits TASK bodies as bare
    Snowflake Scripting blocks with no delimiter at all --

        create or replace task T ... as DECLARE ... BEGIN ...; ...; END;

    -- so a ";" scan cuts every task into a dozen fragments, and tracking
    BEGIN/END nesting means also matching END IF, END FOR and END CASE.

    Instead each statement runs from the start of its own CREATE OR REPLACE to the
    start of the next one. The scan skips single-quoted literals, $$ blocks and
    comments, which is what makes it correct where a plain regex was not: the two
    CREATE OR REPLACE TEMPORARY TABLE statements inside DETECT_DUPLICATES and
    BATCH_CHECK_COMPLIANCE live inside the procedures' quoted bodies and are
    therefore never seen. Task bodies contain no CREATE OR REPLACE, so they stay
    whole.
    """
    marker = re.compile(r"create\s+or\s+replace\s", re.I)
    starts = []
    i, n = 0, len(text)

    while i < n:
        if text[i] == "'":
            i += 1
            while i < n:
                if text[i] == "'":
                    if i + 1 < n and text[i + 1] == "'":   # escaped quote
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue

        if text.startswith("$$", i):
            end = text.find("$$", i + 2)
            i = n if end == -1 else end + 2
            continue

        if text.startswith("--", i):
            end = text.find("\n", i)
            i = n if end == -1 else end
            continue

        if text.startswith("/*", i):
            end = text.find("*/", i)
            i = n if end == -1 else end + 2
            continue

        m = marker.match(text, i)
        if m:
            starts.append(i)
            i = m.end()
            continue

        i += 1

    bounds = starts + [n]
    out = []
    for k in range(len(starts)):
        stmt = text[bounds[k]:bounds[k + 1]].strip().rstrip(";").strip()
        if stmt:
            out.append(stmt)
    return out


def main() -> int:
    if not DDL.exists():
        print(f"FAIL: {DDL} not found")
        return 1

    statements = split_statements(DDL.read_text(encoding="utf-8"))

    by_kind, skipped, unknown = {}, [], []
    for stmt in statements:
        m = KIND_RE.match(stmt)
        if not m:
            unknown.append(stmt[:90].replace("\n", " "))
            continue
        kind = re.sub(r"\s+", " ", m.group(1).upper())

        if kind == "SCHEMA" or any(o in stmt[:300].upper() for o in SKIP_OBJECTS):
            skipped.append(stmt[:70].replace("\n", " "))
            continue
        by_kind.setdefault(kind, []).append(stmt)

    if unknown:
        print(f"FAIL: {len(unknown)} unclassified statement(s):")
        for u in unknown[:10]:
            print(f"  {u!r}")
        return 1

    OUT.mkdir(exist_ok=True)
    for stale in OUT.glob("*.sql"):
        stale.unlink()

    written = []
    for name, kinds in ORDER:
        stmts = [s for k in kinds for s in by_kind.get(k, [])]
        if not stmts:
            continue
        groups = ([stmts] if name != "60_procedures"
                  else [stmts[i:i + PROC_CHUNK]
                        for i in range(0, len(stmts), PROC_CHUNK)])

        for idx, group in enumerate(groups, start=1):
            suffix = f"_{idx}" if len(groups) > 1 else ""
            path = OUT / f"{name}{suffix}.sql"
            body = (f"-- {path.stem}: {', '.join(kinds)} "
                    f"({len(group)} statement(s))\n"
                    f"-- Generated by tools/split_ddl.py. Run chunks in filename order.\n\n"
                    "USE DATABASE MENDIX_APP;\nUSE SCHEMA AGENTS;\n\n")
            body += ";\n\n".join(group) + ";\n"
            path.write_text(body, encoding="utf-8")
            written.append((path.name, len(group), len(body)))

    print(f"{len(statements)} statements parsed, {len(skipped)} skipped")
    for s in skipped:
        print(f"  skipped: {s}")
    print(f"\n{dict(sorted(Counter({k: len(v) for k, v in by_kind.items()}).items()))}\n")
    for fname, cnt, size in written:
        print(f"  {fname:<30} {cnt:>3} stmt  {size/1024:6.1f} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
