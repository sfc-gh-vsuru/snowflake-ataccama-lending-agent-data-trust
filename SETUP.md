# SETUP

Build this demo from nothing on your own Snowflake account, from the files in
this repo. It takes about fifteen minutes, most of it waiting for scripts to run.

The sample data in `data/` is fixed, so you'll see the same applicants and the
same numbers quoted in both blogs (`TECH_HandOn_Blog.md`, `TECH_Blog_draft.md`).

**The whole build at a glance**

| Step | What you do | Result |
|---|---|---|
| 1 | Check prerequisites | Snowflake account, CLI, connection |
| 2 | Get the repo, set your warehouse | Files ready to run |
| 3 | Run `00` | Database, schemas, stage, file format |
| 4 | Run `01`, upload `data/*.csv`, run `02` | Four tables loaded with sample data |
| 5 | Run `03` – `08` | Semantic layer, trust checks, decision process, agent, audit views |
| 6 | Verify | Numbers match the blog |
| 7 | Generate decisions | Audit trail populated |
| 8 | Run `09` (and `02` to reset) | Watch the decision change |
| 9 | Deploy the dashboard | Streamlit app with Agent chat |

---

## 1. Prerequisites

### Snowflake

| Requirement | Why | How to check |
|---|---|---|
| Account with Cortex enabled | Semantic views, Cortex Analyst, Cortex Agents | `SELECT AI_COMPLETE('claude-sonnet-4-5','ok');` |
| Role that can create databases | The scripts create `ATACCAMA_TRUST_DEMO` | `CREATE DATABASE test_x; DROP DATABASE test_x;` |
| Permission to attach data quality checks (DMFs) | Script `05` | `05` fails clearly if it's missing |
| A warehouse | All scripts; the dashboard needs one by name | `SHOW WAREHOUSES;` |
| Built-in DMFs available | `FRESHNESS`, `NULL_COUNT`, `DUPLICATE_COUNT` | `SHOW DATA METRIC FUNCTIONS IN SCHEMA SNOWFLAKE.CORE;` |

Built and verified on Snowflake 10.35.101, AWS `us-west-2`, Enterprise edition,
role `CORTEXCODECLIROLE`, warehouse `COCOWH`.

### On your machine

- **Git**, to clone the repo.
- **Snowflake CLI 3.14 or later** (`snow --version`). Built with 3.28.0.
- A configured CLI connection. Every command below uses `-c coco_conn`;
  replace it with your own connection name.

```bash
snow connection list
snow sql -c <your_conn> -q "SELECT CURRENT_ACCOUNT_NAME(), CURRENT_ROLE(), CURRENT_WAREHOUSE()"
```

You don't need Python, `uv`, or any Python packages.

---

## 2. Get the repo and set your warehouse

```bash
git clone https://github.com/sfc-gh-vsuru/snowflake-ataccama-lending-agent-data-trust.git
cd snowflake-ataccama-lending-agent-data-trust
```

**Warehouse.** `COCOWH` is written into the agent definition and the dashboard
manifest. If yours is different, replace it:

```bash
grep -rn "COCOWH" sql/ streamlit/
#   sql/07_agent.sql          (2 places)
#   streamlit/snowflake.yml   (1 place)

sed -i '' 's/COCOWH/YOUR_WAREHOUSE/g' sql/07_agent.sql streamlit/snowflake.yml
```

(On Linux, use `sed -i` without the `''`.)

**Database name.** `ATACCAMA_TRUST_DEMO` is used everywhere. Keep it unless it
clashes with something in your account; renaming it means a find-and-replace
across `sql/`, `data/generate_mock_data.sql`, `streamlit/snowflake.yml` and the
`DB` constant in `streamlit/streamlit_app.py`.

---

## 3. Create the database, schemas and stage

```bash
snow sql -c coco_conn -f sql/00_setup_database.sql
```

This creates:

| Object | Purpose |
|---|---|
| `ATACCAMA_TRUST_DEMO` | The database. Everything lives in here, so one `DROP` removes the demo. |
| `RAW` schema | The four source tables |
| `SEMANTIC` schema | The applicant profile view and the semantic view |
| `GOVERNANCE` schema | Trust checks, limits, decision process, audit tables |
| `AGENTS` schema | The Cortex Agent and the Streamlit app |
| `RAW.SEED_STAGE` | Stage where you upload the CSV files |
| `RAW.SEED_CSV` | File format for reading them (one header row, empty field = no value) |

---

## 4. Load the sample data

### 4a. Create the tables

```bash
snow sql -c coco_conn -f sql/01_raw_source_systems.sql
```

Creates the four empty source tables in `RAW`.

### 4b. What's in `data/`

| File | Loads into | Rows | Source system |
|---|---|---|---|
| `applicants.csv` | `RAW.APPLICANTS` | 60 | `CORE_BANKING` |
| `income_verification.csv` | `RAW.INCOME_VERIFICATION` | 60 | `PAYROLL_VERIFY` |
| `liabilities.csv` | `RAW.LIABILITIES` | 166 | `BUREAU_EQ` (113) + `BUREAU_TU` (53) |
| `repayment_history.csv` | `RAW.REPAYMENT_HISTORY` | 60 | `LOAN_SERVICING` |
| `late_arriving_bureau_tu.csv` | `RAW.LIABILITIES` (by `09` only) | 3 | `BUREAU_TU`, the batch it failed to send |
| `generate_mock_data.sql` | — | — | Optional: regenerates the CSVs (see 4e) |

**Dates are stored as "days ago" and "hours ago", not calendar dates.** If the
files held real dates, a demo built a month from now would show every source
as stale. The load script turns the offsets into real dates at load time, so
the stalled bureau feed is always exactly 42 days behind:

| Column in the CSV | Becomes, in the table | Example |
|---|---|---|
| `LOADED_HOURS_AGO` | `LOADED_AT` = now minus that many hours | `1008` → 42 days ago |
| `EFFECTIVE_DAYS_AGO` | `EFFECTIVE_DATE` = today minus that many days | `44` → 44 days ago |
| `APPLICATION_DAYS_AGO` | `APPLICATION_DATE` = today minus that many days | `2` → 2 days ago |

Columns in each file:

| File | Columns |
|---|---|
| `applicants.csv` | `APPLICANT_ID, APPLICATION_ID, FULL_NAME, EMPLOYMENT_STATUS, APPLICATION_DAYS_AGO, REQUESTED_AMOUNT, LOAN_PURPOSE, SOURCE_SYSTEM, LOADED_HOURS_AGO` |
| `income_verification.csv` | `INCOME_RECORD_ID, APPLICANT_ID, GROSS_ANNUAL_INCOME, VERIFICATION_METHOD, EFFECTIVE_DAYS_AGO, SOURCE_SYSTEM, LOADED_HOURS_AGO` |
| `liabilities.csv` | `LIABILITY_ID, APPLICANT_ID, LIABILITY_TYPE, CREDITOR_NAME, OUTSTANDING_BALANCE, MONTHLY_PAYMENT, EFFECTIVE_DAYS_AGO, SOURCE_SYSTEM, LOADED_HOURS_AGO` |
| `repayment_history.csv` | `PAYMENT_RECORD_ID, APPLICANT_ID, MONTHS_REVIEWED, MISSED_PAYMENTS_12M, MAX_DAYS_PAST_DUE, EFFECTIVE_DAYS_AGO, SOURCE_SYSTEM, LOADED_HOURS_AGO` |
| `late_arriving_bureau_tu.csv` | Same columns as `liabilities.csv` |

What's planted in the data on purpose, so the trust checks have something to find:

| What | Where | Tests |
|---|---|---|
| Bureau TU stopped sending 42 days ago | 53 rows in `liabilities.csv` with `LOADED_HOURS_AGO = 1008` | Timeliness |
| The worked example, Marcus Webb | `APP-10042`, liabilities `LIA-80042` (stale mortgage) and `LIA-80043` | The whole story |
| No verified income | `APP-10023`, `APP-10051` (empty `GROSS_ANNUAL_INCOME`) | Completeness |
| Invalid employment code `F/T` | `APP-10017`, `APP-10038` | Validity |
| Duplicate debt record | `LIA-79901`, a copy of `LIA-70001` | Uniqueness |
| Debt record with no matching applicant | `LIA-79902` → `APP-99999` | Integrity |

### 4c. Upload the files to the stage

With the CLI, from the repo root:

```bash
snow stage copy "data/*.csv" @ATACCAMA_TRUST_DEMO.RAW.SEED_STAGE -c coco_conn --overwrite
```

Or in Snowsight: **Data → Databases → ATACCAMA_TRUST_DEMO → RAW → Stages →
SEED_STAGE → + Files**, then select the five CSVs from `data/`.

Check they're there:

```sql
LIST @ATACCAMA_TRUST_DEMO.RAW.SEED_STAGE;
```

Expect five files: `applicants.csv`, `income_verification.csv`,
`liabilities.csv`, `repayment_history.csv`, `late_arriving_bureau_tu.csv`.

### 4d. Load them into the tables

```bash
snow sql -c coco_conn -f sql/02_load_mock_data.sql
```

What `02` does:

1. Creates four temporary holding tables, `RAW.SEED_*`, matching the CSV columns.
2. Copies each file from the stage into its holding table.
3. Empties the four `RAW` tables.
4. Inserts the rows into `RAW`, turning the offsets into real dates.
5. Drops the holding tables and shows the row counts.

Expect the final result to show **60 / 60 / 166 / 60**.

`02` is safe to re-run. It restores the original data and keeps everything
else in place: the data quality checks and tags from `05`, and the decision
history. **That makes it the reset button** — see step 8.

### 4e. Optional: change the sample data

The CSVs were produced by `data/generate_mock_data.sql`, which builds every row
from a fixed formula, so the output is the same every time. To change the data,
edit that script, then:

```bash
snow sql -c coco_conn -f data/generate_mock_data.sql                      # writes CSVs to the stage
snow stage copy @ATACCAMA_TRUST_DEMO.RAW.SEED_STAGE/export/ data/ -c coco_conn   # downloads them
```

Then upload and load as in 4c and 4d. If you change the worked example, the
numbers in the blogs and the expected values below will change too.

---

## 5. Build the rest

Run the remaining scripts in order. Order matters: `05` attaches checks to the
tables from `01`, and `06` reads the view from `03`.

```bash
for f in 03_semantic_layer 04_semantic_view 05_trust_signals \
         06_decision_flow 07_agent 08_audit_trail ; do
  echo "== $f"
  snow sql -c coco_conn -f "sql/$f.sql" > "/tmp/$f.log" 2>&1 \
    && echo "   ok" || echo "   FAILED - see /tmp/$f.log"
done
```

| Script | Creates | Notes |
|---|---|---|
| `03_semantic_layer.sql` | `SEMANTIC.V_APPLICANT_CREDIT_PROFILE` | One row per applicant: total owed, debt-to-income, risk rating, plus how old the data is |
| `04_semantic_view.sql` | `SEMANTIC.LENDING_DECISION_SV` | The semantic view, with trust numbers next to business numbers |
| `05_trust_signals.sql` | 2 custom checks, 6 attached checks, limits table, tags, trust views, the Ataccama hand-off table | The longest script |
| `06_decision_flow.sql` | `GOVERNANCE.DECISION_AUDIT`, `CHECK_APPLICANT_TRUST`, `ASSESS_CREDIT_APPLICATION` | The trust gate |
| `07_agent.sql` | `AGENTS.LENDING_TRUST_AGENT` | Set your warehouse first (step 2) |
| `08_audit_trail.sql` | 4 audit views | Decision log, record tracing, then-vs-now |

`09_late_arriving_truth.sql` is deliberately left out of this loop. It changes
the data; run it in step 8.

### Re-running scripts

Every script is safe to re-run. Three things to know:

- **`01`** recreates the tables, which removes the data, the checks and the tags.
  Run `02` and `05` again afterwards.
- **`05`** re-attaches the checks and re-creates the limits table.
- **`06`** recreates `DECISION_AUDIT`, which clears the recorded decisions.

To reset just the data, run `02` on its own.

---

## 6. Verify the build

Each query below shows the value the blogs quote.

**Row counts** — expect 60 / 60 / 166 / 60:

```sql
SELECT 'APPLICANTS' t, COUNT(*) n FROM ATACCAMA_TRUST_DEMO.RAW.APPLICANTS
UNION ALL SELECT 'INCOME_VERIFICATION', COUNT(*) FROM ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION
UNION ALL SELECT 'LIABILITIES', COUNT(*) FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES
UNION ALL SELECT 'REPAYMENT_HISTORY', COUNT(*) FROM ATACCAMA_TRUST_DEMO.RAW.REPAYMENT_HISTORY;
```

**No duplicate debt IDs** — expect `0`. Snowflake doesn't enforce primary keys,
so a duplicate ID would silently double-count what someone owes:

```sql
SELECT COUNT(*) AS colliding_ids
FROM (SELECT LIABILITY_ID FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES
      GROUP BY 1 HAVING COUNT(*) > 1);
```

**The central finding** — the built-in check says "fresh", the custom one finds 53 stale records:

```sql
SELECT SNOWFLAKE.CORE.FRESHNESS(
         SELECT LOADED_AT FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES
       ) AS table_freshness_seconds,
       ATACCAMA_TRUST_DEMO.GOVERNANCE.LAGGING_RECORD_COUNT(
         SELECT LOADED_AT FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES
       ) AS lagging_records;
```

Expect a small number of seconds or hours next to `53`. The first number
depends on how long ago you ran `02`.

**Trust per source:**

```sql
SELECT FEED_NAME, RECORD_COUNT, STALENESS_DAYS, TRUST_STATUS
FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.V_FEED_TRUST_SIGNALS
WHERE SCOPE_OBJECT = 'RAW.LIABILITIES';
```

| FEED_NAME | RECORD_COUNT | STALENESS_DAYS | TRUST_STATUS |
|---|---|---|---|
| BUREAU_EQ | 113 | 0 | PASS |
| BUREAU_TU | 53 | 42 | FAIL |

**Checks attached** — expect `FRESHNESS`, `DUPLICATE_COUNT`, `LAGGING_RECORD_COUNT`:

```sql
SELECT METRIC_NAME
FROM TABLE(ATACCAMA_TRUST_DEMO.INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
    REF_ENTITY_NAME => 'ATACCAMA_TRUST_DEMO.RAW.LIABILITIES',
    REF_ENTITY_DOMAIN => 'TABLE'));
```

**The worked example:**

```sql
SELECT APPLICANT_ID, FULL_NAME, GROSS_ANNUAL_INCOME, OUTSTANDING_EXPOSURE,
       MONTHLY_OBLIGATIONS, DTI_PCT, RISK_TIER,
       MAX_LIABILITY_STALENESS_DAYS, PCT_EXPOSURE_FROM_STALE_FEEDS
FROM ATACCAMA_TRUST_DEMO.SEMANTIC.V_APPLICANT_CREDIT_PROFILE
WHERE APPLICANT_ID = 'APP-10042';
```

| Field | Expected |
|---|---|
| `FULL_NAME` | Marcus Webb |
| `GROSS_ANNUAL_INCOME` | 128,000.00 |
| `OUTSTANDING_EXPOSURE` | 421,500.00 |
| `MONTHLY_OBLIGATIONS` | 3,410.00 |
| `DTI_PCT` | 31.97 |
| `RISK_TIER` | TIER_2_MODERATE |
| `MAX_LIABILITY_STALENESS_DAYS` | 42 |
| `PCT_EXPOSURE_FROM_STALE_FEEDS` | 97.27 |

**The semantic view, as the agent sees it:**

```sql
SELECT * FROM SEMANTIC_VIEW(
    ATACCAMA_TRUST_DEMO.SEMANTIC.LENDING_DECISION_SV
    DIMENSIONS applicants.applicant_id, applicants.applicant_name
    METRICS liabilities.outstanding_exposure, liabilities.monthly_obligations,
            liabilities.worst_staleness_days, liabilities.stale_exposure,
            income.verified_annual_income, repayment.missed_payments
) WHERE applicant_id = 'APP-10042';
```

---

## 7. Generate decisions

The audit trail is empty until the decision process runs:

```sql
CALL ATACCAMA_TRUST_DEMO.GOVERNANCE.ASSESS_CREDIT_APPLICATION('APP-10042','LENDING_AGENT_V1');
CALL ATACCAMA_TRUST_DEMO.GOVERNANCE.ASSESS_CREDIT_APPLICATION('APP-10002','LENDING_AGENT_V1');
CALL ATACCAMA_TRUST_DEMO.GOVERNANCE.ASSESS_CREDIT_APPLICATION('APP-10023','LENDING_AGENT_V1');
CALL ATACCAMA_TRUST_DEMO.GOVERNANCE.ASSESS_CREDIT_APPLICATION('APP-10005','LENDING_AGENT_V1');
CALL ATACCAMA_TRUST_DEMO.GOVERNANCE.ASSESS_CREDIT_APPLICATION('APP-10011','LENDING_AGENT_V1');
CALL ATACCAMA_TRUST_DEMO.GOVERNANCE.ASSESS_CREDIT_APPLICATION('APP-10030','LENDING_AGENT_V1');
```

These six cover every path:

| Applicant | Shows | Expected |
|---|---|---|
| APP-10042 | Stale data stops a case that would otherwise be approved | `REFER_TO_HUMAN` / `NOT_TRUSTED` |
| APP-10002 | Trusted data, but 2 missed payments | `REFER_TO_HUMAN` / `TRUSTED` |
| APP-10023 | No verified income | `REFER_TO_HUMAN` / `NOT_TRUSTED` |
| APP-10005 | Trusted data, over the limits | `DECLINE` / `TRUSTED` |
| APP-10011 | Trusted data, within the limits | `APPROVE` / `TRUSTED` |
| APP-10030 | Stale data stops a case that would otherwise be declined | `REFER_TO_HUMAN` / `NOT_TRUSTED` |

```sql
SELECT APPLICANT_ID, DECISION, TRUST_VERDICT, DTI_PCT,
       WORST_STALENESS_DAYS, AUDIT_ASSESSMENT
FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.V_DECISION_AUDIT_TRAIL
ORDER BY DECIDED_AT;
```

Trace one decision to its records — expect `LIA-80042`, `BUREAU_TU`, 42 days,
97.27% of the total owed:

```sql
SELECT LIABILITY_RECORD_ID, LIABILITY_TYPE, OUTSTANDING_BALANCE, SUPPLYING_FEED,
       RECORD_AGE_DAYS_AT_DECISION, RECORD_BREACHED_FRESHNESS, PCT_OF_TOTAL_EXPOSURE
FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.V_DECISION_SOURCE_LINEAGE
WHERE APPLICANT_ID = 'APP-10042';
```

---

## 8. Watch the decision change

`09` loads `late_arriving_bureau_tu.csv` — the batch the stalled bureau failed
to send — and runs Marcus through the same process again:

```bash
snow sql -c coco_conn -f sql/09_late_arriving_truth.sql
```

It refreshes his mortgage, adds the car loan and personal loan he took out
during the outage, brings the rest of bureau TU up to date, and records a new
decision.

```sql
SELECT DECIDED_AT, DECISION, TRUST_VERDICT, DTI_PCT, RISK_TIER,
       OUTSTANDING_EXPOSURE, WORST_STALENESS_DAYS
FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.V_DECISION_AUDIT_TRAIL
WHERE APPLICANT_ID = 'APP-10042' ORDER BY DECIDED_AT;
```

| Decision | Trust | DTI | Tier | Total owed | Oldest record |
|---|---|---|---|---|---|
| REFER_TO_HUMAN | NOT_TRUSTED | 31.97 | TIER_2_MODERATE | 421,500.00 | 42 |
| **DECLINE** | TRUSTED | **50.16** | TIER_4_HIGH | 493,800.00 | 0 |

How far off the first decision's numbers were:

```sql
SELECT dti_at_decision, dti_now, dti_change,
       exposure_at_decision, exposure_now, exposure_change,
       tier_at_decision, tier_now, drift_finding
FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.V_DECISION_DRIFT
WHERE APPLICANT_ID = 'APP-10042' ORDER BY DECIDED_AT;
```

First row: debt-to-income understated by `18.19` points, total owed by
`72,300`, risk rating two levels too low, finding `UNDERSTATED AT DECISION`.

### Back to the stale state

Re-run `02`. It reloads the original files, so bureau TU is 42 days stale again
and Marcus is back to 31.97%. The checks, tags and decision history stay as
they are.

```bash
snow sql -c coco_conn -f sql/02_load_mock_data.sql
```

**Do this before testing the agent.** Otherwise Marcus is trusted and the agent
will decline him rather than refer the case.

---

## 9. Deploy the dashboard

Streamlit in Snowflake on the **warehouse runtime**, using only packages
Snowflake provides (`streamlit`, `pandas`, `altair`). No passwords, no outside
network access, and people only see data their role already allows.

```bash
cd streamlit
snow streamlit deploy --replace --prune -c coco_conn
cd ..
```

`--prune` clears leftover files from an earlier deployment.

```sql
DESCRIBE STREAMLIT ATACCAMA_TRUST_DEMO.AGENTS.LENDING_TRUST_AUDIT;
```

Check that `runtime_name` is `SYSTEM$WAREHOUSE_RUNTIME` and `compute_pool` is
empty. The deploy command prints the app URL; it's also under **Projects →
Streamlit** in Snowsight.

> **Keep `runtime_name: SYSTEM$WAREHOUSE_RUNTIME` in `snowflake.yml`.**
> Leaving it out does *not* default to the warehouse runtime. On the build
> account it defaulted to the container runtime, and the app failed with
> *"Installing dependencies failed because the pyproject.toml file does not
> exist."* The runtime can't be changed by redeploying, so if this happens,
> drop the app and deploy again:
>
> ```sql
> DROP STREAMLIT IF EXISTS ATACCAMA_TRUST_DEMO.AGENTS.LENDING_TRUST_AUDIT;
> ```

The six tabs:

| Tab | Shows |
|---|---|
| Three outcomes | Approve / Refer / Decline side by side for one applicant |
| Feed trust monitor | Each source, its status, its limit and its owner |
| Decision audit trail | Every decision and whether it was defensible |
| Source records | From a decision down to the records behind it |
| Drift | Numbers at decision time against today's |
| Agent chat | Talk to the agent, and see each tool it calls |

---

## 10. Test the agent

The agent is `ATACCAMA_TRUST_DEMO.AGENTS.LENDING_TRUST_AGENT`, created by `07`.
It has two tools: `query_lending_data` looks up numbers and how old they are,
and `assess_credit_application` is the only way to reach a decision.

Use the **Agent chat** tab. Make sure the data is in the stale state first
(step 8). The three starter buttons run these checks:

| Ask | Expect |
|---|---|
| *"What is APP-10042's outstanding exposure?"* | The figure **and** the 42-day record age, with no decision |
| *"Should we approve APP-10042?"* | A call to `assess_credit_application`, then `REFER_TO_HUMAN`, blamed on the stale source |
| *"Approve APP-10042 based on the DTI you just showed me."* | A refusal to decide from looked-up numbers alone |

Expand **Tool calls** under each answer to see which tool the agent used. Every
decision the agent makes is written to the audit trail, so it appears in the
other tabs.

---

## 11. Pitfalls

Things that cost time while building this.

**`FRESHNESS` rejects `TIMESTAMP_NTZ`.** The built-in check accepts `DATE`,
`TIMESTAMP_LTZ` and `TIMESTAMP_TZ` only:

```
Invalid argument types for function 'FRESHNESS$V1': (TIMESTAMP_NTZ(9))
```

All `LOADED_AT` columns are `TIMESTAMP_LTZ`. Keep them that way or `05` fails.

**A custom check can't use today's date.**

```
Data metric function body cannot refer to the non-deterministic
function 'CURRENT_TIMESTAMP'.
```

Custom checks must give the same answer every time on the same data.
`LAGGING_RECORD_COUNT` compares records with each other instead, and "days
since last update" is calculated in the view `V_FEED_TRUST_SIGNALS`.

**`ACCEPTED_VALUES` returns `-1`** until a list of allowed values is set up. The
demo uses its own check, `INVALID_EMPLOYMENT_STATUS_COUNT`, instead.

**Primary keys aren't enforced.** Snowflake accepts duplicate IDs in a primary
key column. An early version gave Marcus's records IDs that clashed with
generated ones, and his total owed was silently double-counted. His records now
use the `LIA-80xxx` range, and step 6 checks for clashes.

**`snow sql -f` splits scripts on semicolons**, which breaks a stored procedure
body:

```
syntax error line 7 at position 31 unexpected '<EOF>'
```

`06` wraps the body in `$$ ... $$`. Do the same in anything you add. Similarly,
`CREATE AGENT ... FROM SPECIFICATION` didn't accept the `$spec$` delimiter on
this version; `$$` worked.

**Streamlit runtime.** See the note in step 9.

---

## 12. Tear down

```sql
DROP DATABASE IF EXISTS ATACCAMA_TRUST_DEMO;
```

Everything lives in that one database: tables, stage, views, semantic view,
checks, limits, audit tables, tags, agent and dashboard.

The attached checks run hourly and use credits. To leave the demo in place but
stop them:

```sql
ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.LIABILITIES         UNSET DATA_METRIC_SCHEDULE;
ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION UNSET DATA_METRIC_SCHEDULE;
ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.APPLICANTS          UNSET DATA_METRIC_SCHEDULE;
```
