import streamlit as st
from snowflake.snowpark.context import get_active_session
import plotly.express as px
import plotly.graph_objects as go
from i18n import init_language
import ui

st.set_page_config(page_title="VF Logistics", page_icon="🚢", layout="wide")
session = get_active_session()

# The language selector lives in the sidebar via init_language(), the same call
# every other page makes. This page previously rendered its own st.selectbox in a
# header column instead, which meant the control moved position when you
# navigated from the home page to any sub-page, and the sidebar selector was
# missing here entirely. One control, one place.
t = init_language()

# Header. The title/subtitle dicts that used to live here already covered all
# three languages; they now live in TRANSLATIONS so every string has one home.
ui.page_header(t["home_title"], t["home_subtitle"])

# KPI Section with loading
with st.spinner(t["loading_kpis"]):
    try:
        kpis = session.sql("""
            SELECT COUNT(*) as TOTAL, SUM(TOTAL_CHARGES) as REVENUE,
                AVG(TOTAL_CHARGES) as AVG_CHG,
                SUM(CASE WHEN STATUS='Pending_Review' THEN 1 ELSE 0 END) as PENDING,
                SUM(CASE WHEN STATUS='APPROVED' THEN 1 ELSE 0 END) as APPROVED,
                SUM(CASE WHEN STATUS='In_Transit' THEN 1 ELSE 0 END) as TRANSIT,
                COUNT(DISTINCT CARRIER_NAME) as CARRIERS,
                SUM(GROSS_WEIGHT_KGS) as WEIGHT
            FROM BILL_OF_LADING
        """).collect()[0]

        c1, c2, c3, c4 = st.columns(4)
        c1.metric(t["m_shipments"], f"{kpis['TOTAL']:,}")
        c2.metric(t["m_revenue"], f"${kpis['REVENUE']:,.0f}")
        c3.metric(t["m_pending"], f"{kpis['PENDING']:,}")
        c4.metric(t["m_carriers"], f"{kpis['CARRIERS']}")

        c5, c6, c7, c8 = st.columns(4)
        c5.metric(t["m_approved"], f"{kpis['APPROVED']:,}")
        c6.metric(t["m_in_transit"], f"{kpis['TRANSIT']:,}")
        c7.metric(t["m_avg_charge"], f"${kpis['AVG_CHG']:,.0f}")
        c8.metric(t["m_weight"], f"{kpis['WEIGHT']/1e6:.1f}M kg")
    except Exception as e:
        st.error(t["home_kpi_error"].format(err=str(e)[:80]))

st.divider()

# Interactive Charts with Plotly
chart_col1, chart_col2 = st.columns(2)

with chart_col1:
    st.subheader(t["chart_revenue_by_carrier"])
    try:
        carrier_df = session.sql("""
            SELECT CARRIER_NAME, SUM(TOTAL_CHARGES) as REVENUE, COUNT(*) as SHIPMENTS
            FROM BILL_OF_LADING GROUP BY CARRIER_NAME ORDER BY REVENUE DESC
        """).to_pandas()
        carrier_names = carrier_df["CARRIER_NAME"].tolist()
        carrier_revenue = carrier_df["REVENUE"].astype(float).tolist()
        carrier_shipments = carrier_df["SHIPMENTS"].astype(int).tolist()
        n = len(carrier_names)
        fig = go.Figure(go.Bar(
            x=carrier_names, y=carrier_revenue, marker_color=ui.accent_ramp(n),
            customdata=carrier_shipments,
            hovertemplate=(f"{t['ax_carrier']}: %{{x}}<br>{t['ax_revenue']}: $%{{y:,.0f}}"
                           f"<br>{t['ax_shipments']}: %{{customdata}}<extra></extra>")
        ))
        fig.update_layout(**ui.chart_layout(height=350, xaxis_title=t["ax_carrier"],
                                            yaxis_title=t["ax_revenue_usd"]))
        fig.update_xaxes(tickangle=45, categoryorder="array", categoryarray=carrier_names)
        st.plotly_chart(fig, use_container_width=True)
    except Exception as e:
        ui.load_error("Revenue by carrier", e)

with chart_col2:
    st.subheader(t["chart_status_dist"])
    try:
        status_df = session.sql("""
            SELECT STATUS, COUNT(*) as COUNT FROM BILL_OF_LADING GROUP BY STATUS ORDER BY COUNT DESC
        """).to_pandas()
        status_df["COUNT"] = status_df["COUNT"].astype(int)
        status_labels = status_df["STATUS"].tolist()
        status_values = status_df["COUNT"].tolist()
        fig = go.Figure(go.Pie(
            labels=status_labels, values=status_values, hole=0.4,
            marker=dict(colors=px.colors.sequential.Blues_r[:len(status_labels)]),
            hovertemplate="%{label}: %{value} (%{percent})<extra></extra>"
        ))
        fig.update_layout(**ui.chart_layout(height=350, showlegend=True))
        fig.update_traces(textposition='inside', textinfo='percent+label')
        st.plotly_chart(fig, use_container_width=True)
    except Exception as e:
        ui.load_error("Status distribution", e)

st.divider()

# Second row
chart_col3, chart_col4 = st.columns(2)

with chart_col3:
    st.subheader(t["chart_weekly"])
    try:
        weekly_df = session.sql("""
            SELECT DATE_TRUNC('WEEK', CREATED_AT)::DATE as WEEK,
                COUNT(*) as SHIPMENTS, SUM(TOTAL_CHARGES) as REVENUE
            FROM BILL_OF_LADING WHERE CREATED_AT IS NOT NULL
            GROUP BY WEEK ORDER BY WEEK
        """).to_pandas()
        if not weekly_df.empty:
            weeks = weekly_df["WEEK"].astype(str).tolist()
            shipments = weekly_df["SHIPMENTS"].astype(int).tolist()
            revenue = weekly_df["REVENUE"].astype(float).tolist()
            fig = go.Figure()
            fig.add_trace(go.Bar(x=weeks, y=shipments,
                                name=t["ax_shipments"], marker_color=ui.BRAND_BLUE, opacity=0.75,
                                hovertemplate=(f"{t['ax_week']}: %{{x}}<br>"
                                               f"{t['ax_shipments']}: %{{y}}<extra></extra>")))
            # Revenue is plotted on its own axis at its true magnitude. It was
            # previously divided by 100 and the axis was labelled "Revenue/100",
            # which leaked a plotting workaround into the UI and forced the
            # reader to do arithmetic. A secondary axis with a compact tick
            # format shows the real number.
            fig.add_trace(go.Scatter(x=weeks, y=revenue,
                                    name=t["ax_revenue"], line=dict(color=ui.BRAND_CYAN, width=3),
                                    yaxis="y2",
                                    hovertemplate=(f"{t['ax_week']}: %{{x}}<br>"
                                                   f"{t['ax_revenue']}: $%{{y:,.0f}}<extra></extra>")))
            fig.update_layout(**ui.chart_layout(
                height=350, showlegend=True,
                legend=dict(orientation="h", y=1.12, x=0),
                yaxis=dict(title=t["ax_shipments"], gridcolor="rgba(139,148,158,0.12)"),
                yaxis2=dict(title=t["ax_revenue_usd"], overlaying='y', side='right',
                            showgrid=False, tickformat="$~s")))
            st.plotly_chart(fig, use_container_width=True)
    except Exception as e:
        ui.load_error("Weekly volume", e)

with chart_col4:
    st.subheader(t["chart_top_routes"])
    try:
        route_df = session.sql("""
            SELECT PORT_OF_LOADING_LOCODE || ' → ' || PORT_OF_DISCHARGE_LOCODE as ROUTE,
                COUNT(*) as SHIPMENTS, SUM(TOTAL_CHARGES) as REVENUE
            FROM BILL_OF_LADING GROUP BY ROUTE ORDER BY SHIPMENTS DESC LIMIT 8
        """).to_pandas()
        if not route_df.empty:
            route_df["SHIPMENTS"] = route_df["SHIPMENTS"].astype(int)
            route_df["REVENUE"] = route_df["REVENUE"].astype(float)
            routes = route_df["ROUTE"].tolist()
            shipments = route_df["SHIPMENTS"].tolist()
            revenue = route_df["REVENUE"].tolist()
            fig = go.Figure(go.Bar(
                x=shipments, y=routes, orientation='h', marker_color=ui.accent_ramp(len(routes)),
                customdata=revenue,
                hovertemplate=(f"{t['ax_route']}: %{{y}}<br>{t['ax_shipments']}: %{{x}}"
                               f"<br>{t['ax_revenue']}: $%{{customdata:,.0f}}<extra></extra>")
            ))
            fig.update_layout(**ui.chart_layout(height=350, xaxis_title=t["ax_shipments"]))
            fig.update_yaxes(categoryorder="array", categoryarray=routes[::-1])
            st.plotly_chart(fig, use_container_width=True)
    except Exception as e:
        ui.load_error("Top routes", e)

st.divider()

# Marketplace + Pipeline Section
st.subheader(t["live_data_pipeline"])
mk1, mk2, mk3, mk4 = st.columns(4)

with mk1:
    st.markdown(f"**{t['exchange_rates']}**")
    try:
        fx = session.sql("SELECT QUOTE_CURRENCY_ID as CCY, EXCHANGE_RATE as RATE FROM V_EXCHANGE_RATES ORDER BY 1").to_pandas()
        if not fx.empty:
            ui.show_table(fx.set_index("CCY"), height=200)
    except:
        st.info(t["fx_unavailable"])

with mk2:
    st.markdown(f"**{t['sanctions_db']}**")
    try:
        sc = session.sql("SELECT COUNT(*) as C FROM V_EXPORT_RESTRICTED_ENTITIES").collect()[0]["C"]
        st.metric(t["entities"], f"{sc:,}")
        st.caption(t["sanctions_source"])
    except:
        st.info(t["not_available"])

with mk3:
    st.markdown(f"**{t['ai_usage_24h']}**")
    try:
        ai = session.sql("SELECT COUNT(*) as CALLS FROM AI_CALL_LOG WHERE CALL_TIMESTAMP > DATEADD('DAY',-1,CURRENT_TIMESTAMP())").collect()[0]["CALLS"]
        st.metric(t["ai_calls"], f"{ai}")
    except:
        st.metric(t["ai_calls"], t["not_available"])

with mk4:
    st.markdown(f"**{t['pipeline_demo']}**")
    st.caption(t["pipeline_demo_desc"])

# Footer. Brand name, version and event are proper nouns, so only the
# descriptive part is translated.
st.divider()
st.caption("VF Logistics v2.1 • Snowflake Cortex AI • Team SORA • CoCo CLI Hackathon 2026")
