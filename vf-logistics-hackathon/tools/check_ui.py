#!/usr/bin/env python3
"""Pre-deploy gate for the Streamlit app.

Exists because a real defect reached the deployed app: every language ternary in
6_AI_Chat.py was replaced with a t["key"] lookup, but that file called
init_language() without assigning its result, so `t` was never bound. The page
died with NameError on load. Neither `py_compile` (which only parses) nor the
key-existence check (which only looked at the strings inside t[...]) could catch
it, because each check was written ad hoc for one concern.

Run this before every PUT to the stage:

    python vf-logistics-hackathon/tools/check_ui.py

Exit status is non-zero if any check fails, so it can gate a deploy script.
"""
from __future__ import annotations

import ast
import glob
import io
import os
import re
import sys
import types

# Keys whose value is legitimately identical in all three languages. Anything
# else appearing in all three unchanged is almost certainly an untranslated
# copy-paste rather than a deliberate choice.
IDENTICAL_ALLOWED = {"f_bl_id"}

APP_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "streamlit_app",
)

failures: list[str] = []
notes: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)


def page_files() -> list[str]:
    return ["app.py"] + sorted(
        p.replace("\\", "/") for p in glob.glob(os.path.join(APP_DIR, "pages", "*.py"))
    )


def rel(path: str) -> str:
    return os.path.relpath(path, APP_DIR).replace("\\", "/")


def load_translations() -> dict:
    """Import i18n with a stub streamlit so it works outside the SiS runtime."""
    stub = types.ModuleType("streamlit")
    stub.session_state = {}
    stub.sidebar = types.SimpleNamespace(selectbox=lambda *a, **k: "EN")
    sys.modules["streamlit"] = stub
    sys.path.insert(0, APP_DIR)
    import i18n  # noqa: E402  (import is deliberately late)

    return i18n.TRANSLATIONS


# --- 1. Everything parses -----------------------------------------------------
targets = [os.path.join(APP_DIR, n) for n in ("app.py", "i18n.py", "ui.py")]
targets += sorted(glob.glob(os.path.join(APP_DIR, "pages", "*.py")))

for path in targets:
    src = io.open(path, encoding="utf-8").read()
    try:
        ast.parse(src, filename=path)
    except SyntaxError as exc:
        fail(f"{rel(path)}: syntax error line {exc.lineno}: {exc.msg}")

# --- 2. No undefined names ----------------------------------------------------
# This is the check that would have caught the NameError. pyflakes is optional so
# a reviewer without it still gets every other check.
try:
    from pyflakes.api import check as pyflakes_check
    from pyflakes.reporter import Reporter

    out, err = io.StringIO(), io.StringIO()
    reporter = Reporter(out, err)
    for path in targets:
        pyflakes_check(io.open(path, encoding="utf-8").read(), rel(path), reporter)
    for line in (out.getvalue() + err.getvalue()).splitlines():
        # Unused imports are untidy but harmless; undefined names are fatal.
        if "undefined name" in line:
            fail(f"pyflakes: {line}")
        elif line.strip():
            notes.append(f"pyflakes: {line}")
except ImportError:
    notes.append("pyflakes not installed - undefined-name check SKIPPED "
                 "(pip install pyflakes)")

# --- 3. Translation table is coherent -----------------------------------------
T = load_translations()
langs = ("EN", "VN", "JA")
keysets = {lang: set(T.get(lang, {})) for lang in langs}

for lang in langs[1:]:
    missing = sorted(keysets["EN"] - keysets[lang])
    extra = sorted(keysets[lang] - keysets["EN"])
    if missing:
        fail(f"i18n: {lang} missing {len(missing)} keys: {missing[:8]}")
    if extra:
        fail(f"i18n: {lang} has {len(extra)} keys absent from EN: {extra[:8]}")

placeholders = lambda s: set(re.findall(r"\{(\w+)\}", s))
for key in sorted(keysets["EN"]):
    sets = [placeholders(T[lang][key]) for lang in langs if key in T[lang]]
    if len({frozenset(s) for s in sets}) > 1:
        # A placeholder present in EN but absent in JA raises KeyError at render
        # time, only for users who switched language.
        fail(f"i18n: '{key}' has mismatched {{placeholders}} across languages")

identical = {
    key for key in keysets["EN"]
    if len({T[lang][key] for lang in langs if key in T[lang]}) == 1
} - IDENTICAL_ALLOWED
if identical:
    fail(f"i18n: {len(identical)} keys identical in all three languages "
         f"(likely untranslated): {sorted(identical)[:8]}")

# --- 4. Pages use i18n correctly ----------------------------------------------
for path in page_files():
    full = path if os.path.isabs(path) else os.path.join(APP_DIR, path)
    src = io.open(full, encoding="utf-8").read()
    name = rel(full)

    used = set(re.findall(r"""t\[["']([A-Za-z0-9_]+)["']\]""", src))
    if used and not re.search(r"^\s*t\s*=", src, re.M):
        fail(f"{name}: uses t[...] {len(used)} times but never assigns t "
             f"(did you call init_language() without capturing its return?)")

    unknown = sorted(used - keysets["EN"])
    if unknown:
        fail(f"{name}: references undefined translation keys: {unknown}")

    conditionals = re.findall(r"lang\s*==\s*[\"'](?:EN|VN|JA)[\"']", src)
    if conditionals:
        fail(f"{name}: {len(conditionals)} inline language conditional(s) remain "
             f"- move the strings into TRANSLATIONS")

    if re.search(r"(?<![A-Za-z0-9_.\"'])lang(?![A-Za-z0-9_\"'])", src) and \
            not re.search(r"^\s*lang\s*=", src, re.M):
        fail(f"{name}: uses `lang` but never assigns it")

# --- Report -------------------------------------------------------------------
print(f"checked {len(targets)} files, {len(keysets['EN'])} translation keys "
      f"x {len(langs)} languages")
for note in notes:
    print(f"  note: {note}")

if failures:
    print(f"\nFAILED ({len(failures)}):")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)

print("\nOK - safe to PUT to the stage")
