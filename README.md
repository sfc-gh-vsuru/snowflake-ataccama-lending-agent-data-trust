# Carry trust signals from source to AI

Companion repo for the Snowflake + Ataccama technical blog on carrying data
trust signals from source systems through a semantic layer and into an AI
agent's decision.

Everything here runs on the Snowflake AI Data Cloud. Every figure quoted in the
blog and in this README came from an actual run against a live account.

---

## The problem

A lending agent approves a loan. Months later an examiner asks the bank to
reconstruct the case, and compliance finds that the liability record behind the
decision was **six weeks out of date** at the moment the agent acted.

Nothing was mislabelled. The semantic layer did its job perfectly — every field
meant exactly what it was supposed to mean. That is what made the failure so
hard to see.

> **A semantic layer tells an agent what a number means.
> A trust layer tells it whether the number can be used.**

The [first piece](https://docs.google.com/document/d/13k-CvMbGVXnnb3Ne_syBoLmQyHt9osNAGz-sIg8VCl0/edit?usp=sharing)
in this series made that argument for a business audience. This repo builds the
second half for practitioners.

### The three questions this repo answers

| # | Question from piece one | Answered by |
|---|---|---|
| 1 | Can compliance trace a challenged recommendation to the **exact source record**? | `V_DECISION_SOURCE_LINEAGE` |
| 2 | Is there a **measurable, current** trust signal on the data the agent reasons over? | `V_FEED_TRUST_SIGNALS`, DMFs |
| 3 | Does that signal reach the agent **in the flow of the decision**? | `ASSESS_CREDIT_APPLICATION` |

---

## The headline finding

Two data quality checks, same table, same column, run seconds apart:

| Check | Result | Reads as |
|---|---|---|
| `SNOWFLAKE.CORE.FRESHNESS` | 66 seconds | **PASS** |
| `GOVERNANCE.LAGGING_RECORD_COUNT` | 53 records | **FAIL** |

The liability table is fed by two credit bureaus. `BUREAU_EQ` loads daily;
`BUREAU_TU` stopped 42 days ago. Because built-in `FRESHNESS` reports against
`MAX(LOADED_AT)`, the healthy feed masks the dead one entirely.

**One working feed hides a dead one, and the coarser your check, the more
reliably it will.**

---

## What the demo proves

One applicant — **APP-10042, Marcus Webb** — requesting 45,000 against a
verified income of 128,000, with a clean repayment record.

| Agent | Decision | DTI used | Verdict |
|---|---|---|---|
| Trusting the stale data | `APPROVE` | 31.97% | Wrong, indefensible |
| With the trust gate | `REFER_TO_HUMAN` | not applied | Correct, defensible |
| Once the feed recovered | `DECLINE` | 50.16% | Correct, final |

During the 42-day outage the applicant had taken on two liabilities their file
knew nothing about — not wrong values, **absent** ones, which no value-level
validation can catch. Exposure was understated by 72,300, DTI by 18.19 points,
and the risk tier was wrong by two levels.

The trust layer did not produce a better answer. It produced a refusal to give
a confident wrong one, plus a written record of why.

---

## Repo layout

```
.
├── TECH_HandOn_Blog.md              the blog, hands-on version with code
├── TECH_Blog_draft.md               the blog, readable version without code
├── SETUP.md                         build it on your own account, step by step
├── README.md                        this file
│
├── data/                            sample data, loaded by sql/02 and sql/09
│   ├── applicants.csv               60 rows   -> RAW.APPLICANTS
│   ├── income_verification.csv      60 rows   -> RAW.INCOME_VERIFICATION
│   ├── liabilities.csv              166 rows  -> RAW.LIABILITIES
│   ├── repayment_history.csv        60 rows   -> RAW.REPAYMENT_HISTORY
│   ├── late_arriving_bureau_tu.csv  3 rows    -> RAW.LIABILITIES (by 09 only)
│   └── generate_mock_data.sql       optional: regenerates the CSVs
│
├── sql/
│   ├── 00_setup_database.sql        database, schemas, stage, file format
│   ├── 01_raw_source_systems.sql    four source system tables
│   ├── 02_load_mock_data.sql        load data/*.csv into the tables (also the reset)
│   ├── 03_semantic_layer.sql        curated credit profile with provenance
│   ├── 04_semantic_view.sql         semantic view + trust metrics
│   ├── 05_trust_signals.sql         DMFs, thresholds, tags, Ataccama contract
│   ├── 06_decision_flow.sql         trust-gated decision procedure
│   ├── 07_agent.sql                 Cortex Agent
│   ├── 08_audit_trail.sql           audit, lineage and drift views
│   └── 09_late_arriving_truth.sql   load the late batch, flip the decision
│
└── streamlit/
    ├── streamlit_app.py             dashboard (SiS, warehouse runtime), 6 tabs
    ├── snowflake.yml                deployment manifest
    └── environment.yml              Anaconda packages
```

### The sample data

The CSVs in `data/` store dates as offsets — `LOADED_HOURS_AGO`,
`EFFECTIVE_DAYS_AGO` — rather than calendar dates. `02` converts them to real
timestamps when it loads, so the stalled bureau feed is always exactly 42 days
behind whenever the demo is built. Fixed dates would make every source look
stale a month after publishing.

The files were produced by `data/generate_mock_data.sql`, which builds every
row from a fixed formula, so regenerating them gives the same output. Column
lists and the planted defects are documented in `SETUP.md`, step 4.

### Schemas

| Schema | Purpose | Key objects |
|---|---|---|
| `RAW` | Mock source systems | 4 tables |
| `SEMANTIC` | What the numbers **mean** | `V_APPLICANT_CREDIT_PROFILE`, `LENDING_DECISION_SV` |
| `GOVERNANCE` | Whether they can be **used** | DMFs, thresholds, trust views, audit, decision procedure |
| `AGENTS` | Consumers | `LENDING_TRUST_AGENT`, `LENDING_TRUST_AUDIT` |

The `SEMANTIC` / `GOVERNANCE` split is the architecture in miniature: meaning
and trust are separate concerns that must arrive together at the point of
decision.

---

## How it fits together

```
RAW source systems                    four feeds, one of them stalled
  │
  │  CORE_BANKING · PAYROLL_VERIFY · BUREAU_EQ · BUREAU_TU(stalled) · LOAN_SERVICING
  │
  ├─────────────────────────────────┬──────────────────────────────────────┐
  │                                 │                                      │
  ▼ MEANING                         ▼ TRUST                                ▼ CATALOG
SEMANTIC.V_APPLICANT_             DMFs on source tables                Horizon tags
  CREDIT_PROFILE                  (FRESHNESS, NULL_COUNT,              TRUST_TIER
  exposure · DTI · risk tier       DUPLICATE_COUNT,                    DATA_DOMAIN
  + provenance columns             LAGGING_RECORD_COUNT)               DECISION_CRITICAL
  │                                 │
  ▼                                 ▼
SEMANTIC.LENDING_DECISION_SV      GOVERNANCE.V_FEED_TRUST_SIGNALS
  business metrics                  absolute staleness vs
  + worst_staleness_days            TRUST_THRESHOLDS
  + stale_exposure                  │
  │                                 ├──◄── GOVERNANCE.ATACCAMA_TRUST_SIGNALS
  │                                 │         [PLACEHOLDER — Ataccama owns]
  │                                 ▼
  │                               GOVERNANCE.V_UNIFIED_TRUST_SIGNALS
  │                                 │
  │                                 ▼
  │                               GOVERNANCE.CHECK_APPLICANT_TRUST()
  │                                 applicant-scoped verdict
  │                                 │
  └────────────┬────────────────────┘
               ▼
    GOVERNANCE.ASSESS_CREDIT_APPLICATION()
      1. read governed figures
      2. obtain trust verdict
      3. GATE — refer if blocking failure, policy never runs
      4. credit policy, only if trust passed
      5. write DECISION_AUDIT + TRUST_SIGNAL_SNAPSHOT
               │
      ┌────────┴────────┬──────────────────────┐
      ▼                 ▼                      ▼
AGENTS.LENDING_   GOVERNANCE audit views   AGENTS.LENDING_
  TRUST_AGENT       V_DECISION_AUDIT_TRAIL   TRUST_AUDIT
  2 tools           V_DECISION_SOURCE_       Streamlit, 6 tabs
                      LINEAGE
                    V_TRUST_AT_DECISION
                    V_DECISION_DRIFT
```

---

## Object reference

### `RAW` — mock source systems

| Table | Rows | Notes |
|---|---|---|
| `APPLICANTS` | 60 | 2 rows carry invalid `EMPLOYMENT_STATUS` (`'F/T'`) |
| `INCOME_VERIFICATION` | 60 | 2 rows have `NULL` income |
| `LIABILITIES` | 166 | **53 from the stalled `BUREAU_TU` feed** + 1 duplicate + 1 orphan |
| `REPAYMENT_HISTORY` | 60 | Clean |

Every table carries `SOURCE_SYSTEM` and `LOADED_AT` (`TIMESTAMP_LTZ` — the
built-in `FRESHNESS` DMF rejects `NTZ`).

Defects are planted on purpose so the trust signals have something real to
report: a stalled feed (timeliness), missing income (completeness), an invalid
code (validity), a duplicate (uniqueness) and an orphan (integrity).

### `SEMANTIC` — meaning

**`V_APPLICANT_CREDIT_PROFILE`** — one governed row per applicant. Resolves
four source systems into a single profile and applies written lending policy.

Business columns: `outstanding_exposure`, `monthly_obligations`, `dti_pct`,
`risk_tier`, `missed_payments_12m`.

Provenance columns carried alongside: `liability_feeds_used`,
`max_liability_staleness_days`, `exposure_from_stale_feeds`,
`pct_exposure_from_stale_feeds`, `worst_staleness_days_any_source`.

Risk tier policy:

| Tier | Condition |
|---|---|
| `TIER_1_LOW` | DTI < 30 and no missed payments |
| `TIER_2_MODERATE` | DTI < 40 and ≤ 1 missed |
| `TIER_3_ELEVATED` | DTI < 50 and ≤ 2 missed |
| `TIER_4_HIGH` | otherwise |
| `TIER_UNKNOWN` | income or obligations unavailable |

**`LENDING_DECISION_SV`** — the semantic view Cortex Analyst and the agent
read. Four tables, three relationships, five facts, seven dimensions, six
metrics.

The design point: two of the six metrics are not credit measures.

```sql
liabilities.worst_staleness_days AS MAX(liabilities.staleness_days)
liabilities.stale_exposure       AS SUM(CASE WHEN staleness_days > 7 ...)
```

They are trust signals published in the same governed object as the business
metrics, so an agent gets the number and its age through one interface.

### `GOVERNANCE` — trust

| Object | Type | Purpose |
|---|---|---|
| `LAGGING_RECORD_COUNT` | DMF | Records lagging the table's newest load by > 7 days. Catches a stalled feed that `FRESHNESS` masks. |
| `INVALID_EMPLOYMENT_STATUS_COUNT` | DMF | Validity, with the accepted domain in the rule body |
| `TRUST_THRESHOLDS` | table | Governed warn/fail levels, blocking flag, owning team, rationale |
| `V_FEED_TRUST_SIGNALS` | view | Absolute per-feed staleness graded against thresholds |
| `ATACCAMA_TRUST_SIGNALS` | table | **PLACEHOLDER** — the Ataccama hand-off contract. Ships empty. |
| `V_UNIFIED_TRUST_SIGNALS` | view | Native + Ataccama signals in one shape |
| `CHECK_APPLICANT_TRUST` | function | Applicant-scoped verdict, returns `OBJECT` |
| `ASSESS_CREDIT_APPLICATION` | procedure | The trust gate |
| `DECISION_AUDIT` | table | Append-only decision record |
| `TRUST_SIGNAL_SNAPSHOT` | table | Trust state frozen at decision time |
| `V_DECISION_AUDIT_TRAIL` | view | Reviewer entry point + defensibility assessment |
| `V_DECISION_SOURCE_LINEAGE` | view | Decision down to individual source records |
| `V_TRUST_AT_DECISION` | view | Signals as they stood at decision time |
| `V_DECISION_DRIFT` | view | Decision-time figures vs today |

Six DMFs are attached on an hourly schedule:

| Table | DMFs |
|---|---|
| `LIABILITIES` | `FRESHNESS`, `DUPLICATE_COUNT`, `LAGGING_RECORD_COUNT` |
| `INCOME_VERIFICATION` | `FRESHNESS`, `NULL_COUNT` |
| `APPLICANTS` | `INVALID_EMPLOYMENT_STATUS_COUNT` |

Three Horizon tags (`DATA_DOMAIN`, `TRUST_TIER`, `DECISION_CRITICAL`) make
fitness-for-use discoverable in the catalog. `RAW.LIABILITIES` is tagged
`PROVISIONAL`, not `CERTIFIED`, because of the stalled feed — the catalog label
and the live signal agree.

#### `CHECK_APPLICANT_TRUST(applicant_id)`

Returns a structured verdict rather than a bare score:

```json
{
  "applicant_id": "APP-10042",
  "verdict": "NOT_TRUSTED",
  "blocking_failures": ["LIABILITY_FEED_STALENESS"],
  "worst_staleness_days": 42,
  "stale_feeds": ["BUREAU_TU"],
  "pct_exposure_from_stale_feeds": 97.27,
  "income_missing": false,
  "duplicate_liabilities": 0,
  "ataccama_trust_index": null
}
```

**Why applicant-scoped.** A feed-level signal describes a dataset; it cannot
tell you whether *this* decision is safe. APP-10042 draws 97.27% of exposure
from the stalled feed; other applicants on the same table draw none. Fitness
for use is a property of the decision, not only of the table.

#### `ASSESS_CREDIT_APPLICATION(applicant_id, decided_by)`

```
1. read governed figures from the semantic layer
2. obtain a trust verdict for this applicant
3. GATE: blocking failure → REFER_TO_HUMAN, stop
4. credit policy, reached only if trust passed
5. write DECISION_AUDIT + TRUST_SIGNAL_SNAPSHOT
```

Credit policy v1.0, applied **only** after trust passes:

| Outcome | Condition |
|---|---|
| `APPROVE` | DTI < 40 and ≤ 1 missed payment |
| `REFER_TO_HUMAN` | DTI < 50 and ≤ 2 missed payments |
| `DECLINE` | otherwise |

Step 3 precedes step 4 by design: the policy branch is never evaluated on data
that failed a blocking check.

### `AGENTS` — consumers

**`LENDING_TRUST_AGENT`** — two tools, and the split is the design:

| Tool | Type | Can it decide? |
|---|---|---|
| `query_lending_data` | `cortex_analyst_text_to_sql` over the semantic view | **No** — reports figures only |
| `assess_credit_application` | `generic` → the procedure | **Yes** — the only route to an outcome |

Orchestration instructions add two rules: never state an outcome from query
results alone, and always surface record age alongside any figure.

**Instructions are a guideline; the procedure is a control.** A model can be
talked out of an instruction. It cannot be talked out of the fact that the only
tool returning a decision checks trust first. That redundancy is what makes the
design defensible rather than merely well-intentioned.

**`LENDING_TRUST_AUDIT`** — Streamlit in Snowflake, warehouse runtime,
Anaconda packages only (`streamlit`, `pandas`, `altair`). Six tabs: three
outcomes, feed trust monitor, decision audit trail, source records, drift, and
**agent chat**.

The agent chat tab calls `LENDING_TRUST_AGENT` through the `agent:run` REST
endpoint using `_snowflake.send_snow_api_request`, which runs as the app's own
session, so the app holds no token or secret. Starter buttons run the three
checks from the blog, and each answer can be expanded to show which tool the
agent called and with what input. When the agent makes a decision, it lands in
the audit tabs on the next refresh.

---

## The Ataccama boundary

This repo is deliberately bounded. Snowflake-native signals answer:

- **How old is this?** (feed-level timeliness)
- **Is it present?** (completeness)
- **Is it duplicated?** (uniqueness)
- **Is it a valid value?** (validity, accepted domain)

They do **not** profile distributions, detect drift against historical ranges,
reconcile to an external system of record, or produce a composite trust score.
That is the Ataccama layer.

The integration point is one table, `GOVERNANCE.ATACCAMA_TRUST_SIGNALS`, which
ships empty. Both `V_UNIFIED_TRUST_SIGNALS` and `CHECK_APPLICANT_TRUST` read it
with outer joins, so:

- the Snowflake side runs end to end on native signals alone, and
- when Ataccama writes rows, their signals appear in the agent's decision with
  **no change** to the agent, the semantic view, or the decision procedure.

Expected from Ataccama: `DATA_TRUST_INDEX` (composite 0–100), per-rule results,
`RECORD_IDENTIFIER` for record-level traceability, drift and anomaly flags, and
`EVALUATED_AT` for point-in-time audit.

Open questions are listed at the end of both blog drafts.

---

## Engineering notes

Five constraints discovered while building this. All five shaped the design.

**1. `FRESHNESS` rejects `TIMESTAMP_NTZ`.** Supports `DATE`, `TIMESTAMP_LTZ`,
`TIMESTAMP_TZ` only. All `LOADED_AT` columns are `LTZ`.

**2. A DMF body cannot call `CURRENT_TIMESTAMP`.** Bodies must be
deterministic, so a custom DMF cannot measure absolute staleness.
`LAGGING_RECORD_COUNT` compares each record to the table's own newest load
instead; absolute staleness is computed in `V_FEED_TRUST_SIGNALS`. This is the
clearest technical argument for a trust layer above native DMFs.

**3. `ACCEPTED_VALUES` returns `-1`** until an expectation set is configured.
A custom DMF with the domain in the rule body is clearer for a demo.

**4. Primary keys are not enforced.** An early version of `02` reused
`LIA-70042` for a hero record, colliding with the generated range. The join
silently double-counted and exposure exceeded 100% — no error. Hero records now
use `LIA-80xxx`, and `SETUP.md` includes a collision check.

**5. A feed with no threshold must not report `PASS`.** The first version of
`V_FEED_TRUST_SIGNALS` left-joined to the threshold table and let unmatched
feeds fall through to `PASS` — three of five feeds green because nobody had
written a rule. They now report `UNGOVERNED`. An unassessed feed is not a
passing feed.

---

## Getting started

See **`SETUP.md`** for the full walkthrough: prerequisites, loading the data,
verification queries with expected values, and teardown. Short version:

```bash
# 1. database, schemas, stage; then the empty tables
snow sql -c <your_conn> -f sql/00_setup_database.sql
snow sql -c <your_conn> -f sql/01_raw_source_systems.sql

# 2. upload the sample data and load it
snow stage copy "data/*.csv" @ATACCAMA_TRUST_DEMO.RAW.SEED_STAGE -c <your_conn> --overwrite
snow sql -c <your_conn> -f sql/02_load_mock_data.sql

# 3. everything else, in order
for f in 03_semantic_layer 04_semantic_view 05_trust_signals \
         06_decision_flow 07_agent 08_audit_trail ; do
  snow sql -c <your_conn> -f "sql/$f.sql"
done

# 4. record a decision, then flip it with the late batch (re-run 02 to reset)
snow sql -c <your_conn> -q "CALL ATACCAMA_TRUST_DEMO.GOVERNANCE.ASSESS_CREDIT_APPLICATION('APP-10042','LENDING_AGENT_V1')"
snow sql -c <your_conn> -f sql/09_late_arriving_truth.sql

# 5. deploy the dashboard
cd streamlit && snow streamlit deploy --replace --prune -c <your_conn>
```

Change `COCOWH` to your warehouse in `sql/07_agent.sql` and
`streamlit/snowflake.yml` first.

---

## Status

| Component | State |
|---|---|
| Sample data | 5 CSVs in `data/`; file-based load verified to reproduce every number in the blogs |
| SQL scripts 00–09 | Built and verified on a live account |
| Semantic view + Cortex Analyst | Verified, including natural-language resolution |
| DMFs and trust signals | Verified, 6 attached |
| Trust-gated decision procedure | Verified across 6 applicants, all paths |
| Audit, lineage and drift views | Verified |
| Cortex Agent | Created and working — confirmed through the Agent chat tab |
| Streamlit app | Deployed on warehouse runtime; all six tabs working, including Agent chat |
| Blogs | Hands-on and no-code versions complete, 7 screenshot placeholders each |
| Ataccama sections | Placeholders with open questions |
