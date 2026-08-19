"""Shared UI layer for the VF Logistics Streamlit-in-Snowflake app.

Every page imported its own styling, or none at all, which is why the home page
looked like a product and the five sub-pages looked like SQL output. This module
is the single place that decides how the app looks, so a change lands everywhere
at once.

Constraints this module is written against (SiS warehouse runtime, Streamlit 1.22):
  - No st.chat_message / st.chat_input / st.file_uploader / st.data_editor.
  - CSS must be injected with unsafe_allow_html=True; there is no theme API.
  - plotly IS available (declared in the app's user_packages), and is preferred
    over st.bar_chart / st.line_chart because those render with a light default
    palette on this dark background and truncate long category labels.
"""

import streamlit as st

# ---------------------------------------------------------------------------
# Design tokens
# ---------------------------------------------------------------------------
# One accent ramp, reused by CSS and by every chart, so the app reads as one
# product rather than six pages that happen to share a database.
BRAND_CYAN = "#00d2ff"
BRAND_BLUE = "#3a7bd5"
INK_MUTED = "#8b949e"
INK_BODY = "#c9d1d9"

# Semantic colours. These are deliberately NOT reused for decoration: a red
# element in this app means a blocked or destructive outcome and nothing else.
SEV_BLOCK = "#f85149"
SEV_WARN = "#d29922"
SEV_OK = "#3fb950"

EM_DASH = "—"


def accent_ramp(n):
    """n shades of the brand blue, lightest last.

    Used instead of a categorical palette for single-series bar charts: the bars
    encode one variable, so varying hue would imply a distinction that is not
    in the data. Varying opacity keeps the ordering readable instead.
    """
    if n <= 0:
        return []
    return [f"rgba(58,123,213,{0.35 + 0.65 * i / max(n - 1, 1)})" for i in range(n)]


# ---------------------------------------------------------------------------
# Page chrome
# ---------------------------------------------------------------------------
_THEME_CSS = f"""
<style>
/* Streamlit's default main-container padding reserves a large band of empty
   space above and below the content. Inside Snowsight the app already sits in an
   iframe that has its own scrollbar, so that dead space pushed the page past the
   viewport and produced a second, inner scrollbar even on pages whose content
   comfortably fitted - two scrollbars side by side on every page.
   Trimming the padding removes the spurious one. The outer Snowsight scrollbar is
   part of the host page and cannot be removed from inside the app.
   Several selectors are listed because the class names differ between Streamlit
   versions; the ones that do not match are simply ignored. */
.block-container,
section.main > div.block-container,
div[data-testid="stAppViewContainer"] > section > div.block-container {{
    padding-top: 2.2rem !important;
    padding-bottom: 2.5rem !important;
}}

/* The default footer is an empty band at the bottom of every page that only adds
   height. Hiding it shortens each page by roughly its own height. */
footer {{ visibility: hidden; height: 0; padding: 0; margin: 0; }}
div[data-testid="stDecoration"] {{ display: none; }}

/* Headline treatment, previously only on the home page. */
.vf-title {{
    font-size: 2.1rem;
    font-weight: 700;
    background: linear-gradient(90deg, {BRAND_CYAN}, {BRAND_BLUE});
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    margin: 0 0 2px 0;
    line-height: 1.25;
}}
.vf-subtitle {{
    font-size: 0.95rem;
    color: {INK_MUTED};
    margin: 0 0 18px 0;
}}

/* Metric cards. Applied globally so a KPI looks the same on every page. */
div[data-testid="stMetric"] {{
    background: rgba(58,123,213,0.06);
    border: 1px solid rgba(58,123,213,0.18);
    border-radius: 10px;
    padding: 12px 16px;
}}
div[data-testid="stMetricValue"] {{ font-size: 1.7rem; font-weight: 700; }}
div[data-testid="stMetricLabel"] {{ color: {INK_MUTED}; }}

/* Streamlit renders type="primary" as a warm red in this dark theme, which
   reads as "destructive". The primary action on a page is not destructive, so
   it is re-coloured to the brand accent. Red is reserved for .vf-danger. */
button[kind="primary"] {{
    background: linear-gradient(90deg, {BRAND_BLUE}, {BRAND_CYAN}) !important;
    border: 0 !important;
    color: #06121f !important;
    font-weight: 600 !important;
}}
button[kind="primary"]:hover {{ filter: brightness(1.08); }}

/* Section rule that is quieter than st.divider(), for grouping inside a page. */
.vf-rule {{
    border: 0;
    border-top: 1px solid rgba(139,148,158,0.18);
    margin: 22px 0 18px 0;
}}

/* Small inline status chips, for scope/provenance notes next to a heading. */
.vf-chip {{
    display: inline-block;
    padding: 2px 9px;
    border-radius: 999px;
    font-size: 0.72rem;
    font-weight: 600;
    letter-spacing: 0.02em;
    border: 1px solid rgba(139,148,158,0.35);
    color: {INK_MUTED};
    margin-left: 8px;
    vertical-align: middle;
}}
.vf-chip-ok {{ color: {SEV_OK}; border-color: rgba(63,185,80,0.45); }}
.vf-chip-warn {{ color: {SEV_WARN}; border-color: rgba(210,153,34,0.45); }}
.vf-chip-block {{ color: {SEV_BLOCK}; border-color: rgba(248,81,73,0.45); }}

/* Read-only field, used where a value is derived by the backend and must not
   look like something the reviewer can edit. */
.vf-readonly {{
    background: rgba(139,148,158,0.08);
    border: 1px solid rgba(139,148,158,0.22);
    border-radius: 8px;
    padding: 10px 12px;
    color: {INK_BODY};
    font-size: 0.9rem;
}}
.vf-readonly-label {{
    color: {INK_MUTED};
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    margin-bottom: 4px;
}}
</style>
"""


def apply_theme():
    """Inject the shared stylesheet. Safe to call once per page run."""
    st.markdown(_THEME_CSS, unsafe_allow_html=True)


def page_header(title, subtitle=None):
    """Render the gradient title used across the app.

    Pages previously used st.title(), which produces a plain heading that does
    not match the home page. Using st.markdown with the shared class keeps all
    seven pages identical.
    """
    apply_theme()
    st.markdown(f'<div class="vf-title">{title}</div>', unsafe_allow_html=True)
    if subtitle:
        st.markdown(f'<div class="vf-subtitle">{subtitle}</div>', unsafe_allow_html=True)


def rule():
    """A quieter horizontal rule than st.divider()."""
    st.markdown('<hr class="vf-rule"/>', unsafe_allow_html=True)


def chip(text, kind=None):
    """Return HTML for a small inline chip. Caller decides where to place it.

    kind: None | 'ok' | 'warn' | 'block'
    """
    cls = "vf-chip" + (f" vf-chip-{kind}" if kind else "")
    return f'<span class="{cls}">{text}</span>'


def caption_scope(text):
    """State the scope of the numbers directly beneath a heading.

    Exists because metrics computed over a LIMITed sample were sitting next to
    metrics computed over a whole table, which reads as a contradiction.
    """
    st.markdown(
        f'<div style="color:{INK_MUTED};font-size:0.82rem;margin:-6px 0 10px 0;">{text}</div>',
        unsafe_allow_html=True,
    )


def readonly_field(label, value, help_text=None):
    """Show a backend-derived value that must not look editable."""
    st.markdown(
        f'<div class="vf-readonly-label">{label}</div>'
        f'<div class="vf-readonly">{value}</div>',
        unsafe_allow_html=True,
    )
    if help_text:
        st.caption(help_text)


# ---------------------------------------------------------------------------
# DataFrame presentation
# ---------------------------------------------------------------------------
def display_df(df, dash=EM_DASH):
    """Return a copy of df with missing values rendered as an em dash.

    Streamlit renders a Python None / NaN as the literal text "None", which in a
    logistics table reads like an extracted value rather than absent data. Every
    read-only table in this app goes through here.

    Two deliberate choices:

    1. Missing numbers become the dash too, not 0. A NULL token count means "not
       recorded", and printing 0 would assert something the data does not say.

    2. Only columns that actually contain a missing value are converted to
       object dtype. Columns that are fully populated keep their numeric dtype,
       so Streamlit still right-aligns them and applies thousands separators.
       Converting everything unconditionally would flatten all formatting.
    """
    if df is None or len(df) == 0:
        return df
    out = df.copy()
    for col in out.columns:
        na = out[col].isna()
        if na.any():
            out[col] = out[col].astype(object).where(~na, dash)
    return out


def show_table(df, dash=EM_DASH, **kwargs):
    """display_df + st.dataframe, with full width as the default."""
    kwargs.setdefault("use_container_width", True)
    st.dataframe(display_df(df, dash=dash), **kwargs)


def empty_state(message):
    """Consistent empty state. Absence of data is information, not a warning."""
    st.info(message)


def load_error(context, err, limit=140):
    """Consistent failure surface.

    Pages previously printed raw strings like "Chart error: ..." inconsistently
    as st.warning, st.error or st.caption. A failed panel is surfaced as a
    warning with the panel named, so a reviewer can tell which panel is degraded
    without reading the traceback.
    """
    st.warning(f"{context} unavailable — {str(err)[:limit]}")


# ---------------------------------------------------------------------------
# Charts
# ---------------------------------------------------------------------------
def chart_layout(height=340, **overrides):
    """Shared plotly layout: transparent background, muted text, tight margins.

    Returned as a dict so callers can splat it into update_layout and override
    individual keys.
    """
    layout = dict(
        height=height,
        margin=dict(t=10, b=10, l=10, r=10),
        paper_bgcolor="rgba(0,0,0,0)",
        plot_bgcolor="rgba(0,0,0,0)",
        font_color=INK_BODY,
        showlegend=False,
        xaxis=dict(gridcolor="rgba(139,148,158,0.12)"),
        yaxis=dict(gridcolor="rgba(139,148,158,0.12)"),
    )
    layout.update(overrides)
    return layout


def hbar(labels, values, value_name="Count", height=340, hovertemplate=None):
    """Horizontal bar chart, returned as a plotly figure.

    Horizontal because these categories are long identifiers such as
    COST_PER_KG_ANOMALY and DOCUMENT_QUALITY. On a vertical axis Streamlit
    rotates and truncates them to the point of being unreadable; on a horizontal
    axis they are simply legible.
    """
    import plotly.graph_objects as go

    labels = list(labels)
    values = list(values)
    fig = go.Figure(
        go.Bar(
            x=values,
            y=labels,
            orientation="h",
            marker_color=accent_ramp(len(labels)),
            hovertemplate=hovertemplate or (f"%{{y}}<br>{value_name}: %{{x:,}}<extra></extra>"),
        )
    )
    fig.update_layout(**chart_layout(height=height, xaxis_title=value_name))
    # Largest at the top reads as a ranking; plotly's default puts the first
    # category at the bottom.
    fig.update_yaxes(categoryorder="array", categoryarray=labels[::-1])
    return fig


def line(x, y, y_name="Value", height=320, hovertemplate=None):
    """Single-series line chart on the shared dark layout."""
    import plotly.graph_objects as go

    fig = go.Figure(
        go.Scatter(
            x=list(x),
            y=list(y),
            mode="lines+markers",
            line=dict(color=BRAND_CYAN, width=2.5),
            marker=dict(size=6, color=BRAND_CYAN),
            hovertemplate=hovertemplate or (f"%{{x}}<br>{y_name}: %{{y}}<extra></extra>"),
        )
    )
    fig.update_layout(**chart_layout(height=height, yaxis_title=y_name))
    return fig
