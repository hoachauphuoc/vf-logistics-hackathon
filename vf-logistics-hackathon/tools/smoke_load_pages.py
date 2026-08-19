"""Smoke-load every Streamlit page outside Snowflake.

pyflakes proves no name is *unbound*; this proves the module-level code actually
runs to completion. It is deliberately crude: the point is to surface NameError /
AttributeError / TypeError raised while the page body executes, not to reproduce
Streamlit's rendering.

Anything the page wraps in try/except is absorbed here exactly as it would be in
the app, so a clean run is not proof the page is functionally correct - only that
loading it does not crash.
"""
from __future__ import annotations

import io
import os
import sys
import traceback
import types

APP_DIR = r"C:\Users\phuochoa\Mendix\VF_Logistics_Portal-main_2\snowflake-backend\streamlit_app"


class Any:
    """Absorbs every access, call, and context-manager use."""

    def __init__(self, name="any"):
        self._name = name

    def __getattr__(self, item):
        return Any(f"{self._name}.{item}")

    def __call__(self, *a, **k):
        return Any(self._name)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def __getitem__(self, k):
        return 0

    def __iter__(self):
        return iter([])

    def __len__(self):
        return 0

    def __bool__(self):
        return False

    def __format__(self, spec):
        return "0" if spec else ""

    def __str__(self):
        return "0"


class State(dict):
    """session_state: both attribute and item access, auto-creating."""

    def __getattr__(self, k):
        if k not in self:
            self[k] = "EN" if k == "lang" else 0
        return self[k]

    def __setattr__(self, k, v):
        self[k] = v

    def get(self, k, default=None):
        return dict.get(self, k, default)


class Row(dict):
    def __getitem__(self, k):
        return dict.get(self, k, 0)


class Result:
    def collect(self):
        return [Row()]

    def to_pandas(self):
        import pandas as pd
        return pd.DataFrame()


class FakeSession:
    def sql(self, *a, **k):
        return Result()


def make_streamlit():
    st = types.ModuleType("streamlit")
    st.session_state = State()

    def columns(spec, **k):
        n = spec if isinstance(spec, int) else len(spec)
        return [Any(f"col{i}") for i in range(n)]

    def cache_data(*a, **k):
        # Support both @st.cache_data and @st.cache_data(ttl=600)
        if a and callable(a[0]):
            return a[0]
        return lambda fn: fn

    st.columns = columns
    st.cache_data = cache_data
    st.cache_resource = cache_data
    st.sidebar = Any("sidebar")
    st.sidebar.selectbox = lambda *a, **k: "EN"
    st.button = lambda *a, **k: False
    st.text_input = lambda *a, **k: ""
    st.number_input = lambda *a, **k: 1
    st.multiselect = lambda *a, **k: []
    st.selectbox = lambda *a, **k: (k.get("options") or (a[1] if len(a) > 1 else [None]))[0]
    st.set_page_config = lambda *a, **k: None

    for name in ("markdown", "caption", "subheader", "header", "title", "write",
                 "divider", "info", "success", "warning", "error", "metric",
                 "dataframe", "table", "code", "json", "plotly_chart", "image",
                 "download_button", "rerun", "experimental_rerun", "stop",
                 "radio", "checkbox", "slider", "text_area", "toast", "empty",
                 "progress", "balloons"):
        setattr(st, name, Any(name))

    st.spinner = lambda *a, **k: Any("spinner")
    st.expander = lambda *a, **k: Any("expander")
    st.container = lambda *a, **k: Any("container")
    st.form = lambda *a, **k: Any("form")
    st.tabs = lambda labels, **k: [Any("tab") for _ in labels]
    return st


def main() -> int:
    sys.path.insert(0, APP_DIR)

    ctx = types.ModuleType("snowflake.snowpark.context")
    ctx.get_active_session = lambda: FakeSession()
    sys.modules["snowflake.snowpark.context"] = ctx

    pages = [os.path.join(APP_DIR, "app.py")]
    pages += [os.path.join(APP_DIR, "pages", n)
              for n in sorted(os.listdir(os.path.join(APP_DIR, "pages")))
              if n.endswith(".py")]

    failed = 0
    for path in pages:
        name = os.path.basename(path)
        sys.modules["streamlit"] = make_streamlit()
        for cached in ("i18n", "ui"):
            sys.modules.pop(cached, None)
        src = io.open(path, encoding="utf-8").read()
        module = types.ModuleType("page_under_test")
        module.__file__ = path
        try:
            exec(compile(src, path, "exec"), module.__dict__)
            print(f"  OK    {name}")
        except Exception as exc:
            failed += 1
            tb = traceback.format_exc().strip().splitlines()
            print(f"  FAIL  {name}: {type(exc).__name__}: {exc}")
            for line in tb[-4:]:
                print(f"          {line.strip()[:130]}")
    print()
    if failed:
        print(f"{failed} page(s) failed to load")
        return 1
    print(f"all {len(pages)} pages loaded without raising")
    return 0


if __name__ == "__main__":
    sys.exit(main())
