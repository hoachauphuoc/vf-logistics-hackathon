import io, os, re

PAT = re.compile(
    r"['\"](mistral-large2|mistral-large|llama3\.1-\d+b|llama3\.2-\d+b|"
    r"mistral-7b|mixtral-8x7b|snowflake-arctic|reka-\w+|gemma-7b|"
    r"claude-[a-z0-9.\-]+)['\"]"
)

SKIP_DIRS = (".git", "backup_", "node_modules", "__pycache__", ".venv")

rows = []
for root, dirs, files in os.walk("."):
    dirs[:] = [d for d in dirs if not any(s in d for s in SKIP_DIRS)]
    if any(s in root for s in SKIP_DIRS):
        continue
    for fn in files:
        if not fn.endswith((".sql", ".py")):
            continue
        path = os.path.join(root, fn)
        try:
            text = io.open(path, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        counts = {}
        for m in PAT.finditer(text):
            counts[m.group(1)] = counts.get(m.group(1), 0) + 1
        if counts:
            rows.append((path, counts))

if not rows:
    print("no model references found")
else:
    width = max(len(p) for p, _ in rows)
    for path, counts in sorted(rows):
        detail = ", ".join(f"{k}={v}" for k, v in sorted(counts.items()))
        print(f"{path:<{width}}  {detail}")
    print()
    total = {}
    for _, c in rows:
        for k, v in c.items():
            total[k] = total.get(k, 0) + v
    print("TOTAL:", ", ".join(f"{k}={v}" for k, v in sorted(total.items())))
