import io, os, sys, types

if "streamlit" not in sys.modules:
    st = types.ModuleType("streamlit")
    st.session_state = {}
    st.cache_data = lambda *a, **k: (lambda f: f)
    st.cache_resource = lambda *a, **k: (lambda f: f)
    sys.modules["streamlit"] = st

p = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "streamlit_app", "i18n.py"))
ns = {}
exec(compile(io.open(p, encoding="utf-8").read(), p, "exec"), ns)
T = ns["TRANSLATIONS"]

def has_cjk(s):
    return any(
        "\u3040" <= c <= "\u30ff" or "\u4e00" <= c <= "\u9fff"
        for c in s
    )

ja, vn, en = T["JA"], T["VN"], T["EN"]

same_as_vn = [k for k in ja if ja[k] == vn.get(k)]
same_as_en = [k for k in ja if ja[k] == en.get(k)]
no_cjk = [k for k in ja if isinstance(ja[k], str) and not has_cjk(ja[k])]

print("JA keys:", len(ja))
print("JA identical to VN:", len(same_as_vn))
print("JA identical to EN:", len(same_as_en))
print("JA values with no Japanese script:", len(no_cjk))
if no_cjk:
    for k in no_cjk[:10]:
        print("   ", k, "=>", repr(ja[k])[:70])
print()
for k in list(ja)[:5]:
    print("  %-28s EN=%-26s JA=%s" % (k, repr(en.get(k))[:26], repr(ja[k])[:34]))
