import io, os, re, sys, types

# stub streamlit so i18n.py imports cleanly outside SiS
if "streamlit" not in sys.modules:
    st = types.ModuleType("streamlit")
    st.session_state = {}
    st.cache_data = lambda *a, **k: (lambda f: f)
    st.cache_resource = lambda *a, **k: (lambda f: f)
    sys.modules["streamlit"] = st

p = os.path.join(os.path.dirname(__file__), "..", "..", "streamlit_app", "i18n.py")
p = os.path.abspath(p)
src = io.open(p, encoding="utf-8").read()
print("local file:", p)
print("local bytes:", len(src.encode("utf-8")))

ns = {}
exec(compile(src, p, "exec"), ns)

# find the dict-of-dicts holding translations
best = None
for name, val in ns.items():
    if isinstance(val, dict) and val:
        inner = [v for v in val.values() if isinstance(v, dict)]
        if len(inner) >= 2:
            if best is None or len(inner) > len(best[1]):
                best = (name, inner, val)

if not best:
    print("no translation dict found")
    sys.exit(1)

name, inner, val = best
print("translation dict:", name)
for lang, d in val.items():
    if isinstance(d, dict):
        print("  %-4s keys=%d" % (lang, len(d)))

langs = [k for k, v in val.items() if isinstance(v, dict)]
if len(langs) >= 2:
    base = set(val[langs[0]])
    for l in langs[1:]:
        missing = base - set(val[l])
        extra = set(val[l]) - base
        print("  %s vs %s: missing=%d extra=%d" % (langs[0], l, len(missing), len(extra)))
        if missing:
            print("    missing sample:", sorted(missing)[:5])

# check JA values that are identical to VI (fall-through symptom)
if "ja" in val and "vi" in val:
    same = [k for k in val["ja"] if k in val["vi"] and val["ja"][k] == val["vi"][k]]
    print("  ja values identical to vi:", len(same))
