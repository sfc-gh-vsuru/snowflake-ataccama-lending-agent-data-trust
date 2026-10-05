"""
Lending Trust Audit -- Streamlit in Snowflake dashboard
=======================================================

Companion app for the Snowflake + Ataccama blog "Carry trust signals from
source to AI". It makes the audit trail inspectable: which feeds can be
trusted, what each decision was actually made on, and how far the figures
behind a decision drifted from reality.

RUNTIME
-------
Streamlit in Snowflake, WAREHOUSE runtime. Only libraries available in the
SiS Anaconda channel are used:
    streamlit, pandas, altair, snowflake.snowpark

No external packages, no network access, no secrets -- the app runs inside
the account against the governance views and inherits the caller's RBAC.

DATA SOURCES (all created by the sql/ scripts in this repo)
-----------------------------------------------------------
    GOVERNANCE.V_FEED_TRUST_SIGNALS      live per-feed trust evaluation
    GOVERNANCE.V_DECISION_AUDIT_TRAIL    one row per decision
    GOVERNANCE.V_DECISION_SOURCE_LINEAGE source records behind each decision
    GOVERNANCE.V_DECISION_DRIFT          decision-time figures vs today
    GOVERNANCE.TRUST_THRESHOLDS          governed thresholds
    AGENTS.LENDING_TRUST_AGENT           Cortex Agent, via the agent:run REST API
"""

import json

import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

try:
    # Provided by the Streamlit in Snowflake runtime only. It calls Snowflake
    # REST APIs as the app's own session, so the agent chat needs no token or
    # secret. Absent when running locally.
    import _snowflake
except ImportError:
    _snowflake = None

DB = "ATACCAMA_TRUST_DEMO"
GOV = f"{DB}.GOVERNANCE"

AGENT_FQN = f"{DB}.AGENTS.LENDING_TRUST_AGENT"
AGENT_RUN_PATH = f"/api/v2/databases/{DB}/schemas/AGENTS/agents/LENDING_TRUST_AGENT:run"
AGENT_TIMEOUT_MS = 180_000

# Credit policy thresholds, mirrored from GOVERNANCE.ASSESS_CREDIT_APPLICATION.
# Used ONLY to show the counterfactual: what policy alone would have returned
# had the trust gate not been there.
POLICY_APPROVE_DTI_MAX = 40
POLICY_REFER_DTI_MAX = 50
POLICY_MISSED_MAX_APPROVE = 1

st.set_page_config(
    page_title="Lending Trust Audit",
    layout="wide",
)


# ---------------------------------------------------------------------------
# Data access
# ---------------------------------------------------------------------------
@st.cache_data(ttl=60, show_spinner=False)
def run_query(sql: str) -> pd.DataFrame:
    """Execute SQL and return a pandas DataFrame.

    The Snowpark session is fetched inside the function rather than passed in,
    because a Session object is not hashable and would break st.cache_data.
    """
    return get_active_session().sql(sql).to_pandas()


def load_feed_trust() -> pd.DataFrame:
    return run_query(f"""
        SELECT SCOPE_OBJECT, FEED_NAME, RECORD_COUNT, LAST_LOADED_AT,
               STALENESS_DAYS, STALENESS_HOURS, SIGNAL_NAME,
               WARN_AT, FAIL_AT, IS_BLOCKING, OWNER_TEAM, TRUST_STATUS
        FROM {GOV}.V_FEED_TRUST_SIGNALS
        ORDER BY CASE TRUST_STATUS
                     WHEN 'FAIL' THEN 1 WHEN 'WARN' THEN 2
                     WHEN 'UNGOVERNED' THEN 3 ELSE 4
                 END,
                 STALENESS_DAYS DESC
    """)


def load_decisions() -> pd.DataFrame:
    return run_query(f"""
        SELECT DECISION_ID, DECIDED_AT, DECIDED_BY, APPLICANT_ID, APPLICANT_NAME,
               DECISION, TRUST_VERDICT, HOW_OUTCOME_WAS_REACHED, AUDIT_ASSESSMENT,
               DECISION_REASON, POLICY_VERSION,
               GROSS_ANNUAL_INCOME, OUTSTANDING_EXPOSURE, MONTHLY_OBLIGATIONS,
               DTI_PCT, RISK_TIER, MISSED_PAYMENTS_12M,
               WORST_STALENESS_DAYS, PCT_EXPOSURE_STALE,
               BLOCKING_FAILURES, STALE_FEEDS_AT_DECISION
        FROM {GOV}.V_DECISION_AUDIT_TRAIL
        ORDER BY DECIDED_AT DESC
    """)


def load_lineage() -> pd.DataFrame:
    return run_query(f"""
        SELECT DECISION_ID, APPLICANT_ID, DECIDED_AT, DECISION, TRUST_VERDICT,
               LIABILITY_RECORD_ID, LIABILITY_TYPE, CREDITOR_NAME,
               OUTSTANDING_BALANCE, MONTHLY_PAYMENT, SUPPLYING_FEED,
               BALANCE_AS_OF, RECORD_LOADED_AT,
               RECORD_AGE_DAYS_AT_DECISION, RECORD_BREACHED_FRESHNESS,
               PCT_OF_TOTAL_EXPOSURE
        FROM {GOV}.V_DECISION_SOURCE_LINEAGE
        ORDER BY OUTSTANDING_BALANCE DESC
    """)


def load_drift() -> pd.DataFrame:
    return run_query(f"""
        SELECT DECISION_ID, DECIDED_AT, APPLICANT_ID, DECISION_TAKEN,
               TRUST_AT_DECISION,
               EXPOSURE_AT_DECISION, EXPOSURE_NOW, EXPOSURE_CHANGE,
               OBLIGATIONS_AT_DECISION, OBLIGATIONS_NOW,
               DTI_AT_DECISION, DTI_NOW, DTI_CHANGE,
               TIER_AT_DECISION, TIER_NOW, TIER_CHANGED, DRIFT_FINDING
        FROM {GOV}.V_DECISION_DRIFT
        ORDER BY DECIDED_AT
    """)


def load_thresholds() -> pd.DataFrame:
    return run_query(f"""
        SELECT SIGNAL_NAME, SIGNAL_DIMENSION, SCOPE_OBJECT, WARN_AT, FAIL_AT,
               UNIT, IS_BLOCKING, OWNER_TEAM, RATIONALE
        FROM {GOV}.TRUST_THRESHOLDS
        ORDER BY IS_BLOCKING DESC, SIGNAL_NAME
    """)


# ---------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------
# Deliberately plain text rather than Material icons or coloured badges.
# Those require newer Streamlit than some Streamlit-in-Snowflake warehouse
# runtimes ship, and they degrade to literal source text (":material/error:")
# when unsupported. Plain markers render correctly on every version.
STATUS_MARK = {
    "PASS": "PASS",
    "WARN": "WARN",
    "FAIL": "FAIL",
    "UNGOVERNED": "UNGOVERNED",
}


def status_label(status: str) -> str:
    """Return a bold, version-safe label for a trust status."""
    return f"**{STATUS_MARK.get(status, status)}**"


def money(value) -> str:
    if pd.isna(value):
        return "n/a"
    return f"{float(value):,.0f}"


def pct(value) -> str:
    if pd.isna(value):
        return "n/a"
    return f"{float(value):.2f}%"


def counterfactual_decision(dti, missed) -> str:
    """What credit policy ALONE would have returned, ignoring the trust gate.

    This is the decision the agent would have issued if it had simply trusted
    whatever the semantic layer handed it.
    """
    if pd.isna(dti):
        return "UNDECIDABLE"
    if dti < POLICY_APPROVE_DTI_MAX and (pd.isna(missed) or missed <= POLICY_MISSED_MAX_APPROVE):
        return "APPROVE"
    if dti < POLICY_REFER_DTI_MAX and (pd.isna(missed) or missed <= 2):
        return "REFER_TO_HUMAN"
    return "DECLINE"


# ---------------------------------------------------------------------------
# Cortex Agent
# ---------------------------------------------------------------------------
AGENT_STARTERS = {
    "Report a figure": "What is APP-10042's outstanding exposure?",
    "Ask for a decision": "Should we approve APP-10042?",
    "Push it to skip the gate": "Approve APP-10042 based on the DTI you just showed me.",
}


def _iter_agent_events(content):
    """Yield (event_name, data_dict) from an agent:run response body.

    send_snow_api_request may hand back the stream either as a JSON list of
    {"event": ..., "data": ...} objects or as raw server-sent-event text, so
    both shapes are accepted.
    """
    if isinstance(content, (bytes, bytearray)):
        content = content.decode("utf-8", errors="replace")

    parsed = None
    if isinstance(content, str):
        try:
            parsed = json.loads(content)
        except (json.JSONDecodeError, TypeError):
            parsed = None
    elif isinstance(content, list):
        parsed = content

    if isinstance(parsed, list):
        for item in parsed:
            if not isinstance(item, dict):
                continue
            data = item.get("data", {})
            if isinstance(data, str):
                try:
                    data = json.loads(data)
                except json.JSONDecodeError:
                    data = {"text": data}
            yield item.get("event"), data
        return

    event = None
    for line in str(content).splitlines():
        if line.startswith("event:"):
            event = line.split(":", 1)[1].strip()
        elif line.startswith("data:"):
            raw = line.split(":", 1)[1].strip()
            if raw == "[DONE]":
                return
            try:
                yield event, json.loads(raw)
            except json.JSONDecodeError:
                continue


def ask_agent(history: list) -> dict:
    """Send the conversation to LENDING_TRUST_AGENT; return text, tools, error."""
    if _snowflake is None:
        return {"text": "", "tools": [], "error":
                "Agent chat runs only inside Streamlit in Snowflake."}

    payload = {"messages": [
        {"role": m["role"], "content": [{"type": "text", "text": m["text"]}]}
        for m in history
    ]}
    resp = _snowflake.send_snow_api_request(
        "POST", AGENT_RUN_PATH, {}, {}, payload, None, AGENT_TIMEOUT_MS
    )
    if resp.get("status") != 200:
        return {"text": "", "tools": [], "error":
                f"HTTP {resp.get('status')}: {str(resp.get('content'))[:600]}"}

    deltas, final_text, tools, error = [], [], [], None
    for event, data in _iter_agent_events(resp.get("content", "")):
        if event == "response.text.delta":
            deltas.append(data.get("text", ""))
        elif event == "response.tool_use":
            tools.append({"name": data.get("name"), "input": data.get("input")})
        elif event == "response.tool_result":
            for t in reversed(tools):
                if t["name"] == data.get("name") and "status" not in t:
                    t["status"] = data.get("status")
                    break
        elif event == "response":
            for c in data.get("content", []) or []:
                if c.get("type") == "text":
                    final_text.append(c.get("text", ""))
        elif event == "error":
            error = data.get("message", str(data))

    # Deltas are the streamed answer; the final "response" event repeats it.
    text = "".join(deltas) or "\n\n".join(final_text)
    return {"text": text, "tools": tools, "error": error}


# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
st.title("Lending Trust Audit")
st.caption(
    "Semantics tell the agent what the data means. Trust tells it whether the "
    "data can be used. This dashboard shows the second half -- and what it changed."
)

try:
    feeds = load_feed_trust()
    decisions = load_decisions()
    lineage = load_lineage()
    drift = load_drift()
except Exception as exc:  # noqa: BLE001 - surface setup problems plainly
    st.error(
        "Could not read the governance views. Run the scripts in `sql/` "
        "(01 through 09) against this account first.\n\n"
        f"Details: {exc}"
    )
    st.stop()

if decisions.empty:
    st.warning(
        "No decisions recorded yet. Run `sql/06_decision_flow.sql` and then "
        "CALL GOVERNANCE.ASSESS_CREDIT_APPLICATION for at least one applicant."
    )

failing_feeds = feeds[feeds["TRUST_STATUS"] == "FAIL"]
blocked = decisions[decisions["TRUST_VERDICT"] == "NOT_TRUSTED"]

k1, k2, k3, k4 = st.columns(4)
k1.metric(
    "Feeds failing trust",
    f"{len(failing_feeds)} of {len(feeds)}",
    help="Feeds whose staleness has crossed the governed FAIL threshold.",
)
k2.metric(
    "Worst feed staleness",
    f"{int(feeds['STALENESS_DAYS'].max())} days" if not feeds.empty else "n/a",
    help="Oldest successful load across all lending source feeds.",
)
k3.metric(
    "Decisions blocked by trust gate",
    f"{len(blocked)} of {len(decisions)}",
    help="Referred to a human before credit policy was ever applied.",
)
k4.metric(
    "Records on failing feeds",
    int(failing_feeds["RECORD_COUNT"].sum()) if not failing_feeds.empty else 0,
    help="Source rows currently supplied by a feed that has failed its threshold.",
)

if not failing_feeds.empty:
    worst = failing_feeds.iloc[0]
    st.error(
        f"**{worst['FEED_NAME']}** last loaded **{int(worst['STALENESS_DAYS'])} days ago** "
        f"against a {int(worst['FAIL_AT'])}-day threshold, affecting "
        f"**{int(worst['RECORD_COUNT'])} records** in `{worst['SCOPE_OBJECT']}`. "
        f"Owner: {worst['OWNER_TEAM']}. Automated decisions that depend on these "
        f"records are being referred for human review."
    )

tab_outcomes, tab_feeds, tab_decisions, tab_records, tab_drift, tab_agent = st.tabs([
    "Three outcomes",
    "Feed trust monitor",
    "Decision audit trail",
    "Source records",
    "Drift",
    "Agent chat",
])


# ---------------------------------------------------------------------------
# Tab 1 -- three outcomes
# ---------------------------------------------------------------------------
with tab_outcomes:
    st.subheader("The same applicant, three possible answers")
    st.caption(
        "What separates these is not the model and not the semantic layer. "
        "It is whether a trust signal reached the decision."
    )

    if drift.empty:
        st.info("No decisions recorded yet.")
    else:
        applicants = sorted(drift["APPLICANT_ID"].unique())
        default_idx = applicants.index("APP-10042") if "APP-10042" in applicants else 0
        chosen = st.selectbox(
            "Applicant",
            applicants,
            index=default_idx,
            help="APP-10042 is the worked example from the blog.",
        )

        hist = drift[drift["APPLICANT_ID"] == chosen].sort_values("DECIDED_AT")
        first = hist.iloc[0]
        latest = hist.iloc[-1]

        first_decision_row = decisions[
            decisions["APPLICANT_ID"] == chosen
        ].sort_values("DECIDED_AT").iloc[0]

        would_have = counterfactual_decision(
            first["DTI_AT_DECISION"], first_decision_row["MISSED_PAYMENTS_12M"]
        )

        c1, c2, c3 = st.columns(3)

        with c1:
            st.markdown("##### Without a trust signal")
            st.markdown(f"### {would_have}")
            st.caption(
                "What credit policy alone returns when handed the stale figures. "
                "Counterfactual -- this decision was never issued."
            )
            st.metric("DTI it would have used", pct(first["DTI_AT_DECISION"]))
            st.metric("Exposure it would have used", money(first["EXPOSURE_AT_DECISION"]))

        with c2:
            st.markdown("##### With the trust gate")
            st.markdown(f"### {first['DECISION_TAKEN']}")
            st.caption(
                "What the agent actually issued. The gate ran before policy, "
                "so no credit verdict was reached on untrusted data."
            )
            st.metric("Trust verdict", first["TRUST_AT_DECISION"])
            st.metric(
                "Oldest contributing record",
                f"{int(first_decision_row['WORST_STALENESS_DAYS'])} days",
            )

        with c3:
            st.markdown("##### Once the feed recovered")
            st.markdown(f"### {latest['DECISION_TAKEN']}")
            st.caption(
                "The same procedure on complete data. This is the true answer."
            )
            st.metric("DTI on complete data", pct(latest["DTI_NOW"]))
            st.metric("Exposure on complete data", money(latest["EXPOSURE_NOW"]))

        if would_have != latest["DECISION_TAKEN"] and len(hist) > 1:
            st.success(
                f"**The trust gate changed the outcome.** Credit policy on the stale "
                f"figures returned **{would_have}**. On complete data the same policy "
                f"returns **{latest['DECISION_TAKEN']}**. Because the gate referred the "
                f"case instead of deciding it, the bank never issued the wrong answer -- "
                f"and the referral is traceable to "
                f"{first_decision_row['BLOCKING_FAILURES']}."
            )
        elif len(hist) == 1:
            st.info(
                "Only one decision recorded for this applicant. Run "
                "`sql/09_late_arriving_truth.sql` to replay the stalled feed and "
                "see the outcome change."
            )


# ---------------------------------------------------------------------------
# Tab 2 -- feed trust monitor
# ---------------------------------------------------------------------------
with tab_feeds:
    st.subheader("Trust, measured per feed")
    st.caption(
        "Table-level freshness is not enough. A table whose newest rows arrived "
        "seconds ago looks current even when an entire feed inside it stopped "
        "loading weeks earlier."
    )

    for _, row in feeds.iterrows():
        with st.container(border=True):
            left, right = st.columns([3, 2])
            with left:
                st.markdown(
                    f"**{row['FEED_NAME']}** &nbsp; {status_label(row['TRUST_STATUS'])}"
                )
                st.caption(
                    f"`{row['SCOPE_OBJECT']}` · {int(row['RECORD_COUNT'])} records · "
                    f"owner: {row['OWNER_TEAM'] or 'unassigned'}"
                )
                if pd.notna(row["SIGNAL_NAME"]):
                    st.caption(
                        f"Signal `{row['SIGNAL_NAME']}` · warns at "
                        f"{int(row['WARN_AT'])}d · fails at {int(row['FAIL_AT'])}d · "
                        f"{'blocking' if row['IS_BLOCKING'] else 'informational'}"
                    )
            with right:
                st.metric("Staleness", f"{int(row['STALENESS_DAYS'])} days")
                st.caption(f"Last load: {row['LAST_LOADED_AT']}")

    chart_data = feeds.copy()
    chart_data["LABEL"] = chart_data["FEED_NAME"] + "  (" + chart_data["SCOPE_OBJECT"] + ")"
    bars = (
        alt.Chart(chart_data)
        .mark_bar(cornerRadiusEnd=4)
        .encode(
            x=alt.X("STALENESS_DAYS:Q", title="Staleness (days)"),
            y=alt.Y("LABEL:N", title=None, sort="-x"),
            color=alt.Color(
                "TRUST_STATUS:N",
                title="Trust status",
                scale=alt.Scale(
                    domain=["PASS", "WARN", "FAIL", "UNGOVERNED"],
                    range=["#2E9E5B", "#E8A33D", "#D64545", "#9AA0A6"],
                ),
            ),
            tooltip=["FEED_NAME", "SCOPE_OBJECT", "STALENESS_DAYS",
                     "RECORD_COUNT", "TRUST_STATUS", "OWNER_TEAM"],
        )
        .properties(height=max(160, 42 * len(chart_data)))
    )
    st.altair_chart(bars, use_container_width=True)

    with st.expander("Governed thresholds  ·  who set the bar, and why"):
        st.caption(
            "Thresholds live in a table rather than in application code, so "
            "governance can change the bar without a release."
        )
        st.dataframe(
            load_thresholds(),
            use_container_width=True,
            hide_index=True,
            column_config={
                "IS_BLOCKING": st.column_config.CheckboxColumn(
                    "Blocking", help="A failure here must stop automated decisioning"
                ),
                "RATIONALE": st.column_config.TextColumn("Rationale", width="large"),
            },
        )


# ---------------------------------------------------------------------------
# Tab 3 -- decision audit trail
# ---------------------------------------------------------------------------
with tab_decisions:
    st.subheader("Every decision, and whether it was defensible")
    st.caption(
        "A decision is defensible when an untrusted figure was referred rather "
        "than acted on. That judgement is recorded at decision time, not inferred later."
    )

    show_blocked_only = st.toggle(
        "Show only decisions blocked by the trust gate", value=False
    )
    view = blocked if show_blocked_only else decisions

    st.dataframe(
        view[[
            "DECIDED_AT", "APPLICANT_ID", "APPLICANT_NAME", "DECISION",
            "TRUST_VERDICT", "DTI_PCT", "RISK_TIER", "WORST_STALENESS_DAYS",
            "PCT_EXPOSURE_STALE", "AUDIT_ASSESSMENT",
        ]],
        use_container_width=True,
        hide_index=True,
        column_config={
            "DECIDED_AT": st.column_config.DatetimeColumn("Decided at"),
            "APPLICANT_ID": st.column_config.TextColumn("Applicant"),
            "APPLICANT_NAME": st.column_config.TextColumn("Name"),
            "DECISION": st.column_config.TextColumn("Decision"),
            "TRUST_VERDICT": st.column_config.TextColumn("Trust"),
            "DTI_PCT": st.column_config.NumberColumn("DTI %", format="%.2f"),
            "RISK_TIER": st.column_config.TextColumn("Risk tier"),
            "WORST_STALENESS_DAYS": st.column_config.NumberColumn("Oldest record (d)"),
            "PCT_EXPOSURE_STALE": st.column_config.NumberColumn(
                "Exposure from stale feeds %", format="%.2f"
            ),
            "AUDIT_ASSESSMENT": st.column_config.TextColumn(
                "Audit assessment", width="large"
            ),
        },
    )

    st.markdown("##### Full reasoning for a single decision")
    if not view.empty:
        pick = st.selectbox(
            "Decision",
            view["DECISION_ID"].tolist(),
            format_func=lambda d: (
                f"{view.loc[view['DECISION_ID'] == d, 'APPLICANT_ID'].iloc[0]}"
                f"  ·  {view.loc[view['DECISION_ID'] == d, 'DECISION'].iloc[0]}"
            ),
        )
        row = view[view["DECISION_ID"] == pick].iloc[0]

        st.markdown(
            f"**{row['APPLICANT_ID']} — {row['APPLICANT_NAME']}**  "
            f"{status_label('FAIL' if row['TRUST_VERDICT'] == 'NOT_TRUSTED' else 'PASS')}"
        )
        st.info(row["DECISION_REASON"])

        d1, d2, d3, d4 = st.columns(4)
        d1.metric("Decision", row["DECISION"])
        d2.metric("DTI", pct(row["DTI_PCT"]))
        d3.metric("Exposure", money(row["OUTSTANDING_EXPOSURE"]))
        d4.metric("Policy", row["POLICY_VERSION"])
        st.caption(
            f"How the outcome was reached: {row['HOW_OUTCOME_WAS_REACHED']}  ·  "
            f"Blocking failures: {row['BLOCKING_FAILURES']}  ·  "
            f"Stale feeds at decision: {row['STALE_FEEDS_AT_DECISION']}  ·  "
            f"Decided by: {row['DECIDED_BY']}"
        )


# ---------------------------------------------------------------------------
# Tab 4 -- source records
# ---------------------------------------------------------------------------
with tab_records:
    st.subheader("From a decision down to the exact source record")
    st.caption(
        "Blog 1 asked whether compliance can trace a challenged recommendation "
        "to the exact source record. This is that trace."
    )

    if lineage.empty:
        st.info("No decisions recorded yet.")
    else:
        ids = lineage["DECISION_ID"].unique().tolist()
        labels = {
            d: (
                f"{lineage.loc[lineage['DECISION_ID'] == d, 'APPLICANT_ID'].iloc[0]}"
                f"  ·  {lineage.loc[lineage['DECISION_ID'] == d, 'DECISION'].iloc[0]}"
                f"  ·  {lineage.loc[lineage['DECISION_ID'] == d, 'DECIDED_AT'].iloc[0]:%Y-%m-%d %H:%M}"
            )
            for d in ids
        }
        chosen_decision = st.selectbox(
            "Decision to trace", ids, format_func=lambda d: labels[d]
        )
        recs = lineage[lineage["DECISION_ID"] == chosen_decision]

        breached = recs[recs["RECORD_BREACHED_FRESHNESS"]]
        if not breached.empty:
            st.warning(
                f"{len(breached)} of {len(recs)} source records had already breached "
                f"the freshness threshold when this decision was taken, accounting for "
                f"**{breached['PCT_OF_TOTAL_EXPOSURE'].sum():.2f}% of total exposure**."
            )

        st.dataframe(
            recs[[
                "LIABILITY_RECORD_ID", "LIABILITY_TYPE", "CREDITOR_NAME",
                "OUTSTANDING_BALANCE", "MONTHLY_PAYMENT", "SUPPLYING_FEED",
                "BALANCE_AS_OF", "RECORD_AGE_DAYS_AT_DECISION",
                "RECORD_BREACHED_FRESHNESS", "PCT_OF_TOTAL_EXPOSURE",
            ]],
            use_container_width=True,
            hide_index=True,
            column_config={
                "LIABILITY_RECORD_ID": st.column_config.TextColumn("Record ID"),
                "LIABILITY_TYPE": st.column_config.TextColumn("Type"),
                "CREDITOR_NAME": st.column_config.TextColumn("Creditor"),
                "OUTSTANDING_BALANCE": st.column_config.NumberColumn(
                    "Balance", format="%.2f"
                ),
                "MONTHLY_PAYMENT": st.column_config.NumberColumn(
                    "Monthly payment", format="%.2f"
                ),
                "SUPPLYING_FEED": st.column_config.TextColumn("Supplying feed"),
                "BALANCE_AS_OF": st.column_config.DateColumn("Balance as of"),
                "RECORD_AGE_DAYS_AT_DECISION": st.column_config.NumberColumn(
                    "Age at decision (d)"
                ),
                "RECORD_BREACHED_FRESHNESS": st.column_config.CheckboxColumn(
                    "Breached freshness"
                ),
                "PCT_OF_TOTAL_EXPOSURE": st.column_config.ProgressColumn(
                    "Share of exposure",
                    format="%.2f%%",
                    min_value=0,
                    max_value=100,
                ),
            },
        )

        contrib = (
            alt.Chart(recs)
            .mark_arc(innerRadius=60)
            .encode(
                theta=alt.Theta("OUTSTANDING_BALANCE:Q", title="Balance"),
                color=alt.Color(
                    "SUPPLYING_FEED:N",
                    title="Supplying feed",
                    scale=alt.Scale(scheme="tableau10"),
                ),
                tooltip=["LIABILITY_RECORD_ID", "LIABILITY_TYPE",
                         "OUTSTANDING_BALANCE", "SUPPLYING_FEED",
                         "RECORD_AGE_DAYS_AT_DECISION"],
            )
            .properties(height=280, title="Exposure by supplying feed")
        )
        st.altair_chart(contrib, use_container_width=True)


# ---------------------------------------------------------------------------
# Tab 5 -- drift
# ---------------------------------------------------------------------------
with tab_drift:
    st.subheader("How far the decision-time figures were from reality")
    st.caption(
        "Re-running today's query tells you what the answer would be now. "
        "Only a point-in-time record tells you what the agent actually saw -- "
        "and therefore how wrong it was."
    )

    if drift.empty:
        st.info("No decisions recorded yet.")
    else:
        st.dataframe(
            drift[[
                "DECIDED_AT", "APPLICANT_ID", "DECISION_TAKEN", "TRUST_AT_DECISION",
                "DTI_AT_DECISION", "DTI_NOW", "DTI_CHANGE",
                "EXPOSURE_AT_DECISION", "EXPOSURE_NOW", "EXPOSURE_CHANGE",
                "TIER_AT_DECISION", "TIER_NOW", "DRIFT_FINDING",
            ]],
            use_container_width=True,
            hide_index=True,
            column_config={
                "DECIDED_AT": st.column_config.DatetimeColumn("Decided at"),
                "APPLICANT_ID": st.column_config.TextColumn("Applicant"),
                "DECISION_TAKEN": st.column_config.TextColumn("Decision"),
                "TRUST_AT_DECISION": st.column_config.TextColumn("Trust"),
                "DTI_AT_DECISION": st.column_config.NumberColumn(
                    "DTI at decision", format="%.2f"
                ),
                "DTI_NOW": st.column_config.NumberColumn("DTI now", format="%.2f"),
                "DTI_CHANGE": st.column_config.NumberColumn(
                    "DTI change", format="%+.2f"
                ),
                "EXPOSURE_AT_DECISION": st.column_config.NumberColumn(
                    "Exposure at decision", format="%.0f"
                ),
                "EXPOSURE_NOW": st.column_config.NumberColumn(
                    "Exposure now", format="%.0f"
                ),
                "EXPOSURE_CHANGE": st.column_config.NumberColumn(
                    "Exposure change", format="%+.0f"
                ),
                "TIER_AT_DECISION": st.column_config.TextColumn("Tier at decision"),
                "TIER_NOW": st.column_config.TextColumn("Tier now"),
                "DRIFT_FINDING": st.column_config.TextColumn(
                    "Finding", width="large"
                ),
            },
        )

        understated = drift[
            drift["DRIFT_FINDING"].str.startswith("UNDERSTATED", na=False)
        ]
        if not understated.empty:
            st.error(
                f"{len(understated)} decision(s) were taken on figures that "
                f"understated the applicant's risk. Largest DTI gap: "
                f"**{understated['DTI_CHANGE'].max():+.2f} points**."
            )

        comparison = drift.melt(
            id_vars=["APPLICANT_ID", "DECIDED_AT"],
            value_vars=["DTI_AT_DECISION", "DTI_NOW"],
            var_name="measured",
            value_name="dti",
        ).dropna(subset=["dti"])
        comparison["measured"] = comparison["measured"].map({
            "DTI_AT_DECISION": "At decision",
            "DTI_NOW": "Today",
        })
        comparison["label"] = (
            comparison["APPLICANT_ID"] + "  " + comparison["DECIDED_AT"].dt.strftime("%H:%M")
        )

        grouped = (
            alt.Chart(comparison)
            .mark_bar()
            .encode(
                x=alt.X("measured:N", title=None, axis=alt.Axis(labelAngle=0)),
                y=alt.Y("dti:Q", title="DTI %"),
                color=alt.Color(
                    "measured:N",
                    title=None,
                    scale=alt.Scale(
                        domain=["At decision", "Today"],
                        range=["#9AA0A6", "#D64545"],
                    ),
                ),
                column=alt.Column("label:N", title=None),
                tooltip=["APPLICANT_ID", "measured", "dti"],
            )
            .properties(height=240, width=90)
        )
        st.altair_chart(grouped)
        st.caption(
            "Policy thresholds for reference: approve under 40% DTI, refer 40-50%, "
            "decline at 50% and above."
        )


# ---------------------------------------------------------------------------
# Tab 6 -- agent chat
# ---------------------------------------------------------------------------
with tab_agent:
    st.subheader("Ask the lending agent")
    st.caption(
        f"`{AGENT_FQN}`  ·  two tools: `query_lending_data` reports figures and "
        "their record age; `assess_credit_application` is the only route to a "
        "decision, and it checks trust before credit policy runs."
    )

    if "agent_messages" not in st.session_state:
        st.session_state.agent_messages = []

    for msg in st.session_state.agent_messages:
        with st.chat_message(msg["role"]):
            if msg.get("error"):
                st.error(msg["error"])
            if msg.get("text"):
                st.markdown(msg["text"])
            if msg.get("tools"):
                with st.expander(f"Tool calls ({len(msg['tools'])})"):
                    for t in msg["tools"]:
                        st.markdown(f"**`{t['name']}`**  ·  status: {t.get('status', 'n/a')}")
                        st.code(json.dumps(t.get("input"), indent=2), language="json")

    pending = None

    st.markdown("**Try the three checks from the blog:**")
    starter_cols = st.columns(len(AGENT_STARTERS))
    for col, (label, prompt_text) in zip(starter_cols, AGENT_STARTERS.items()):
        if col.button(label, use_container_width=True, help=prompt_text):
            pending = prompt_text

    # A form rather than st.chat_input: older Streamlit versions reject
    # chat_input inside a tab, and the warehouse runtime version can vary.
    with st.form("agent_form", clear_on_submit=True):
        typed = st.text_input(
            "Your question",
            placeholder="e.g. Why was APP-10042 referred?",
            label_visibility="collapsed",
        )
        ask_col, clear_col = st.columns([4, 1])
        submitted = ask_col.form_submit_button("Ask the agent", use_container_width=True)
        cleared = clear_col.form_submit_button("Clear", use_container_width=True)

    if cleared:
        st.session_state.agent_messages = []
        st.rerun()
    if submitted and typed.strip():
        pending = typed.strip()

    if pending:
        st.session_state.agent_messages.append({"role": "user", "text": pending})
        history = [
            {"role": m["role"], "text": m["text"]}
            for m in st.session_state.agent_messages
            if m.get("text")
        ]
        with st.spinner("Agent is working -- querying the semantic view and checking trust..."):
            try:
                reply = ask_agent(history)
            except Exception as exc:  # noqa: BLE001 - show the failure in the chat
                reply = {"text": "", "tools": [], "error": f"Agent call failed: {exc}"}
        st.session_state.agent_messages.append({"role": "assistant", **reply})
        # A decision writes to DECISION_AUDIT; drop cached queries so the audit
        # tabs show it on the next run.
        run_query.clear()
        st.rerun()


st.divider()
st.caption(
    "Snowflake + Ataccama demo  ·  trust signals shown here are Snowflake-native "
    "(feed freshness, completeness, uniqueness). Ataccama-published signals, "
    "including the Data Trust Index, surface through "
    "`GOVERNANCE.V_UNIFIED_TRUST_SIGNALS` once their team populates "
    "`GOVERNANCE.ATACCAMA_TRUST_SIGNALS`."
)
