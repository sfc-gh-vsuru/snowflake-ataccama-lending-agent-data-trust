# Carry trust signals from source to AI

**How to build a lending AI agent that decides when the data is current — and hands the case to a person when it isn't. On Snowflake.**

> **Draft status:** Snowflake portion only. Sections marked
> `[ATACCAMA — TO BE WRITTEN]` are placeholders for the Ataccama team.
> Sections marked `[SCREENSHOT]` need a Snowsight capture.
> See *Open items before publication* at the end.

---

## TL;DR

- Our [previous piece](https://docs.google.com/document/d/13k-CvMbGVXnnb3Ne_syBoLmQyHt9osNAGz-sIg8VCl0/edit?usp=sharing)
  made a simple point: an AI agent needs to know two things about a number —
  what it *means*, and whether it can be *trusted right now*. This piece builds
  the second part in Snowflake, with code you can run.
- We recreate the story from that piece: a lending agent that approved a loan
  using debt records that were six weeks out of date.
- **The surprise:** Snowflake's standard "is this data fresh?" check said the
  debt data was **66 seconds** old. In fact, one of the two sources feeding it
  had stopped sending updates **42 days** earlier. The working source hid the
  broken one.
- With a trust check in place, the agent handed the case to a person instead
  of approving it. When the missing data finally arrived, the right answer
  turned out to be *decline*. The trust check didn't find the right answer —
  it stopped the agent from confidently giving the wrong one.

---

*New to lending or data terms? Short definitions are in the
[appendix](#appendix-key-terms) at the end. The code is included for people who
want to build this — you can skip every code block and still follow the story.*

---

## Where this picks up

The previous piece ended with three questions every bank should be able to
answer before letting an AI agent make lending decisions:

1. **Can you trace it?** If a decision is questioned, can you point to the
   exact records it was based on?
2. **Can you measure it?** Is there a current, measurable signal that says the
   data is trustworthy — not just an assumption that someone checked it once?
3. **Does the agent see it?** Does that signal reach the agent *while it's
   deciding*, or does it sit in a report nobody reads until something goes
   wrong?

This piece answers all three with working Snowflake objects. Every number
below comes from a real run, and every script is in the companion repo.

Two things didn't work the way I expected, and both changed the design. I've
kept them in, because if you build this yourself you'll run into them too.

---

## The scenario

A bank's lending decision draws on four systems:

| System | What it provides | Records |
|---|---|---|
| Core banking | Who is applying, and for how much | 60 applicants |
| Payroll check | The applicant's verified income | 60 |
| Two credit bureaus | Everything the applicant already owes | 166 debts |
| Loan servicing | Whether they've paid past loans on time | 60 |

The important detail: debt records come from **two** credit bureaus. One sends
updates every day. The other **stopped sending updates 42 days ago** — and
nobody noticed, because the table that holds the debt records never looked
empty or broken. It was still full of data. Some of it was just six weeks old.

Our applicant is **Marcus Webb (APP-10042)**. He wants a 45,000 loan to combine
some existing debts. His verified income is 128,000 a year and he has never
missed a payment. Exactly the kind of case an AI agent should be able to handle
on its own.

---

## Step 1 — Define what the numbers mean

First, the semantic layer — the shared dictionary. In Snowflake this is a
**semantic view**. Ours defines "total owed", "monthly debt payments" and
"verified income" once, so every tool and agent calculates them the same way.

We also did one thing that's worth copying: alongside the business numbers, we
defined two **trust numbers** in the same place.

- **Oldest record age** — how many days old the oldest debt record is.
- **Stale amount owed** — how much of the total owed comes from records more
  than a week old.

```sql
CREATE OR REPLACE SEMANTIC VIEW LENDING_DECISION_SV
  TABLES (
    applicants  AS RAW.APPLICANTS   PRIMARY KEY (APPLICANT_ID),
    liabilities AS RAW.LIABILITIES  PRIMARY KEY (LIABILITY_ID)
    -- income and repayment tables omitted for brevity
  )
  RELATIONSHIPS (
    liabilities_to_applicant AS liabilities (APPLICANT_ID) REFERENCES applicants
  )
  FACTS (
    liabilities.balance        AS OUTSTANDING_BALANCE,
    liabilities.staleness_days AS DATEDIFF(day, LOADED_AT, CURRENT_TIMESTAMP())
  )
  METRICS (
    -- business number
    liabilities.outstanding_exposure AS SUM(liabilities.balance)
      COMMENT = 'Total owed across all debts.',

    -- trust numbers, defined in the same place
    liabilities.worst_staleness_days AS MAX(liabilities.staleness_days)
      COMMENT = 'Age in days of the oldest debt record.',
    liabilities.stale_exposure AS SUM(
      CASE WHEN liabilities.staleness_days > 7 THEN liabilities.balance ELSE 0 END)
      COMMENT = 'Amount owed that comes from records over a week old.'
  );
```

Why this matters: when the agent asks "how much does Marcus owe?", it gets the
answer **and** how old the data behind it is — in one step, from one place.
There's no separate system it has to remember to check.

Here's what it returns for Marcus:

| Applicant | Total owed | Monthly debt payments | Oldest record age | Stale amount owed |
|---|---|---|---|---|
| APP-10042 | 421,500 | 3,410 | **42 days** | **410,000** |

The number and its warning arrive together: 410,000 of the 421,500 he owes —
97% — is based on a record six weeks old.

You can also ask in plain English. Snowflake's **Cortex Analyst** turns a
question into a database query using the same definitions:

> *"What is the total outstanding exposure and the worst record staleness in
> days for applicant APP-10042?"*

`[SCREENSHOT: Snowsight — Cortex Analyst answering the above against
LENDING_DECISION_SV, showing generated SQL and both metrics]`

---

## Step 2 — Measure whether the numbers can be trusted

Snowflake has built-in data quality checks called **Data Metric Functions**.
You attach them to a table, they run on a schedule, and Snowflake keeps the
results. We attached six — for example, "is this data fresh?", "are any values
missing?" and "are there duplicates?".

```sql
ALTER TABLE RAW.LIABILITIES
  SET DATA_METRIC_SCHEDULE = 'USING CRON 0 * * * * UTC';   -- run hourly

ALTER TABLE RAW.LIABILITIES
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS       ON (LOADED_AT);
ALTER TABLE RAW.LIABILITIES
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (LIABILITY_ID);
ALTER TABLE RAW.INCOME_VERIFICATION
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT      ON (GROSS_ANNUAL_INCOME);
```

### Surprise #1: the freshness check said everything was fine

We ran the built-in freshness check on the debt table:

```sql
SELECT SNOWFLAKE.CORE.FRESHNESS(
         SELECT LOADED_AT FROM RAW.LIABILITIES
       ) AS table_freshness_seconds;
```

**66 seconds.** By that measure, the debt table was almost perfectly up to
date. Any dashboard built on it would show green.

It was misleading. The check looks at the **newest** record in the table. The
healthy bureau had just sent records, so the newest record was seconds old. The
53 records from the broken bureau, six weeks old, simply didn't affect the
answer. **The working source hid the broken one.**

So we wrote our own check that counts records falling more than a week behind
the newest one:

```sql
CREATE OR REPLACE DATA METRIC FUNCTION LAGGING_RECORD_COUNT(
    arg_t TABLE(loaded_at TIMESTAMP_LTZ)
)
RETURNS NUMBER
AS
$$
    SELECT COUNT(*)
    FROM arg_t
    WHERE loaded_at < DATEADD(day, -7, (SELECT MAX(loaded_at) FROM arg_t))
$$;
```

Two checks, same table, run seconds apart:

| Check | Result | Verdict |
|---|---|---|
| Built-in freshness check | 66 seconds old | **Looks fine** |
| Our record-by-record check | 53 records over a week behind | **Problem** |

If you take one thing from this article, take that table. Having data quality
checks isn't enough. They have to look closely enough to catch the way your
data actually breaks — here, one source out of two going quiet.

### Surprise #2: a custom check can't look at the clock

Next we tried a custom check that simply says "this data is N days old". It was
rejected:

```
Data metric function body cannot refer to the non-deterministic
function 'CURRENT_TIMESTAMP'.
```

In plain terms: Snowflake requires these checks to give the same answer every
time they run on the same data, so they aren't allowed to look at today's date.
That's sensible for a scheduled, audited check — but it means a custom check
can't tell you how old data is *right now*. (Our check above gets around this by
comparing records with each other rather than with the clock.)

So we calculated "days since last update" in a regular view instead, one row
per source, and graded each against a limit:

```sql
CREATE OR REPLACE VIEW V_FEED_TRUST_SIGNALS AS
WITH feed_loads AS (
    SELECT 'RAW.LIABILITIES' AS scope_object, SOURCE_SYSTEM AS feed_name,
           COUNT(*) AS record_count, MAX(LOADED_AT) AS last_loaded_at
    FROM RAW.LIABILITIES GROUP BY SOURCE_SYSTEM
    -- the other source tables are added the same way
)
SELECT f.feed_name, f.record_count,
       DATEDIFF(day, f.last_loaded_at, CURRENT_TIMESTAMP()) AS staleness_days,
       CASE
           WHEN t.SIGNAL_NAME IS NULL THEN 'UNGOVERNED'   -- no limit set
           WHEN DATEDIFF(day, f.last_loaded_at, CURRENT_TIMESTAMP()) >= t.FAIL_AT THEN 'FAIL'
           WHEN DATEDIFF(day, f.last_loaded_at, CURRENT_TIMESTAMP()) >= t.WARN_AT THEN 'WARN'
           ELSE 'PASS'
       END AS trust_status
FROM feed_loads f
LEFT JOIN TRUST_THRESHOLDS t
       ON t.SCOPE_OBJECT = f.scope_object AND t.SIGNAL_DIMENSION = 'TIMELINESS';
```

The result, one row per source:

| Source | Records | Days since last update | Status | Stops automatic decisions? |
|---|---|---|---|---|
| **Credit bureau TU** | 53 | **42** | **FAIL** | Yes |
| Credit bureau EQ | 113 | 0 | PASS | Yes |
| Payroll check | 60 | 0 | PASS | Yes |
| Core banking | 60 | 0 | PASS | No |
| Loan servicing | 60 | 0 | PASS | Yes |

Two design choices here are worth borrowing:

**The limits live in a table, not in code.** Each limit records when to warn,
when to fail, whether a failure should stop automatic decisions, which team
owns it, and why it's set where it is. The people responsible for data rules can
change a limit without anyone touching code.

**A source with no limit shows "UNGOVERNED", not "PASS".** This started as a
mistake. In my first version, any source without a limit showed as passing — so
three of five sources looked green simply because nobody had set a rule for
them. Not checked is not the same as fine. Make sure your own setup can tell
the difference.

### Labelling the data in the catalog

Snowflake's catalog (**Horizon**) lets you tag tables so anyone browsing can see
whether data is safe to use before they build on it. We tagged the debt table
**PROVISIONAL** — usable, but with a known problem:

```sql
CREATE OR REPLACE TAG TRUST_TIER
  ALLOWED_VALUES 'CERTIFIED', 'PROVISIONAL', 'UNCERTIFIED';

ALTER TABLE RAW.LIABILITIES SET TAG
  TRUST_TIER = 'PROVISIONAL', DECISION_CRITICAL = 'TRUE';
```

The catalog label and the live check now tell the same story. When they
disagree, that's a problem in its own right.

`[SCREENSHOT: Snowsight — RAW.LIABILITIES showing TRUST_TIER = PROVISIONAL
alongside the attached DMFs]`

---

## Step 3 — Make the agent check trust before it decides

An agent that *can* see a warning isn't the same as an agent that *has to*. This
step answers the third question: does the signal reach the agent while it's
deciding?

### Check trust for this applicant, not just the table

A source-level warning says something about the data in general. It doesn't say
whether *this applicant's* numbers are safe. 97% of what Marcus owes comes from
the broken bureau; another applicant might not use that bureau at all. So the
trust check looks only at the records behind the decision being made.

`CHECK_APPLICANT_TRUST` does that and returns a verdict:

```sql
SELECT GOVERNANCE.CHECK_APPLICANT_TRUST('APP-10042');
```

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

Three applicants side by side:

| Applicant | Verdict | Why |
|---|---|---|
| APP-10042 | Not trusted | 97% of what he owes comes from records 42 days old |
| APP-10023 | Not trusted | No verified income, so debt-to-income can't be calculated |
| APP-10002 | Trusted | All records are current |

### The trust gate

The decision procedure, `ASSESS_CREDIT_APPLICATION`, runs in a fixed order:

1. Get the applicant's numbers from the semantic layer.
2. Check whether those numbers can be trusted.
3. **If not, hand the case to a person and stop.** The lending rules never run.
4. Only if trust passes, apply the lending rules (approve, refer or decline).

```sql
-- 2. check trust before anything else
v_trust   := GOVERNANCE.CHECK_APPLICANT_TRUST(:P_APPLICANT_ID);
v_verdict := GET(:v_trust, 'verdict')::VARCHAR;

-- 3. the gate: untrusted data goes to a person, lending rules are skipped
IF (v_verdict = 'NOT_TRUSTED') THEN
    v_decision := 'REFER_TO_HUMAN';

-- 4. lending rules, reached only when trust passes
ELSEIF (v_dti < 40 AND COALESCE(v_missed, 0) <= 1) THEN
    v_decision := 'APPROVE';
...
```

Because step 3 comes before step 4, a decision can never be made on data that
failed the trust check.

Running it for Marcus:

```sql
CALL GOVERNANCE.ASSESS_CREDIT_APPLICATION('APP-10042', 'LENDING_AGENT_V1');
```

| Decision | Trust | Debt-to-income | Risk rating | Oldest record |
|---|---|---|---|---|
| **Refer to a person** | Not trusted | 31.97% | Moderate | 42 days |

The recorded reason says the case was referred *without* applying the lending
rules, because the debt data had failed its freshness check.

Look at what the numbers say on their own: debt-to-income of 32%, well under the
40% limit, a moderate risk rating, and a perfect payment record. Every
definition worked exactly as designed. The case was still referred — because
97% of the debt figure was six weeks old, and the system was built to notice.

### Two safeguards, on purpose

The agent has exactly two tools:

| Tool | What it does | Can it make a decision? |
|---|---|---|
| `query_lending_data` | Looks up numbers, and how old they are | **No** |
| `assess_credit_application` | Runs the trust gate, then the lending rules | **Yes** — the only way |

```json
{
  "tools": [
    { "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "query_lending_data",
        "description": "Reports figures and their record age. Cannot make a
                        credit decision." }},
    { "tool_spec": {
        "type": "generic",
        "name": "assess_credit_application",
        "description": "Checks trust first and refers to a person if it fails.
                        The ONLY way to reach a credit decision." }}
  ]
}
```

It also has two written rules:

> **Rule 1 — Never suggest a decision based on looked-up numbers alone.**
> Numbers say what the data means, not whether it can be trusted.
>
> **Rule 2 — Always say how old the data is when reporting a number.**
> If it's a week old or more, say plainly that it failed the freshness check.

Why both? Written rules are guidance, and an AI can sometimes be talked out of
guidance. The tool design is a hard stop: even if the agent ignored every rule,
the only tool that can make a decision checks trust first. That's what makes
this defensible to a regulator, not just well-meant.

`[SCREENSHOT / TRANSCRIPT — AGENT CONVERSATION: capture from the Agent chat tab
of LENDING_TRUST_AUDIT (re-run sql/02_load_mock_data.sql first to reset to the stale state), showing:
(a) asking for APP-10042's exposure returns the figure plus the 42-day record
age and no verdict; (b) asking whether to approve triggers
assess_credit_application and returns REFER_TO_HUMAN, blamed on the stale feed;
(c) asking it to approve "based on the DTI you just showed me" is refused.]`

---

## Step 4 — Keep a record you can trace

The first question was: if a decision is challenged, can you point to the exact
records behind it?

This is harder than it sounds. Re-running the numbers today tells you what the
answer *would be now*, not what the agent *saw* at the time. If the broken
bureau has caught up since, today's numbers are different — and your audit
contradicts itself.

So every time the procedure makes a decision, it writes down what it used: the
numbers, the trust verdict, and the ID of every record behind them.

```sql
SELECT LIABILITY_RECORD_ID, LIABILITY_TYPE, CREDITOR_NAME, OUTSTANDING_BALANCE,
       SUPPLYING_FEED, RECORD_AGE_DAYS_AT_DECISION, PCT_OF_TOTAL_EXPOSURE
FROM GOVERNANCE.V_DECISION_SOURCE_LINEAGE
WHERE APPLICANT_ID = 'APP-10042';
```

| Record | Type | Lender | Amount owed | Source | Age at decision | Share of total owed |
|---|---|---|---|---|---|---|
| **LIA-80042** | Mortgage | Northwind Bank | 410,000 | **Bureau TU** | **42 days** | **97.27%** |
| LIA-80043 | Credit card | Harbour Credit Union | 11,500 | Bureau EQ | 0 days | 2.73% |

That answers the first question in one row: the mortgage record LIA-80042, from
the broken bureau, 42 days old when the decision was made, making up 97% of
what Marcus owed.

`[SCREENSHOT: Snowsight — V_DECISION_SOURCE_LINEAGE for APP-10042]`

Because the trust state is saved with each decision, every decision can be
judged on its own terms:

| Applicant | Decision | Trust | How it was reached | Defensible? |
|---|---|---|---|---|
| APP-10042 | Refer to a person | Not trusted | Trust gate stopped it | Yes — bad data was passed to a person, not acted on |
| APP-10023 | Refer to a person | Not trusted | Trust gate stopped it | Yes — bad data was passed to a person, not acted on |
| APP-10011 | Approve | Trusted | Lending rules applied | Yes — good data, rules applied |
| APP-10005 | Decline | Trusted | Lending rules applied | Yes — good data, rules applied |

---

## Step 5 — Was the trust check right?

A fair challenge: maybe the old data was fine and the check was just being
overly cautious. Sending cases to people costs time and money. Was it worth it?

To find out, we loaded the six weeks of updates the broken bureau had missed,
and ran Marcus through the same procedure again. During those six weeks he had
taken out two new loans his file knew nothing about:

- a **car loan** — 34,500, paying 725 a month
- a **personal loan** — 41,000, paying 1,215 a month

These weren't wrong numbers. They were *missing* numbers — which no "is this
value valid?" check can catch, because there's nothing there to check.

| | Using old data | Using complete data | Change |
|---|---|---|---|
| Total owed | 421,500 | 493,800 | **+72,300** |
| Monthly debt payments | 3,410 | 5,350 | +1,940 |
| **Debt-to-income** | **31.97%** | **50.16%** | **+18 points** |
| Risk rating | Moderate | High | two levels worse |
| Trust | Not trusted | Trusted | — |
| **Decision** | **Refer to a person** | **Decline** | — |

The three possible outcomes side by side:

| Agent | Decision | Result |
|---|---|---|
| Trusting the old data | **Approve** | Wrong, and can't be defended |
| With the trust check | **Refer to a person** | Correct, and defensible |
| Once the data was complete | **Decline** | Correct |

The gap between the first and last rows is the cost of knowing what data
*means* without knowing whether it's *true*: a 45,000 loan approved for someone
who really spends half their income on debt — with every definition working
exactly as designed.

The middle row is what the trust check buys. It didn't find the right answer —
it couldn't, because the right data hadn't arrived yet. What it did was refuse
to give a confident wrong answer, and write down why.

`[SCREENSHOT: Streamlit in Snowflake — "Three outcomes" tab of
LENDING_TRUST_AUDIT showing APPROVE / REFER_TO_HUMAN / DECLINE side by side]`

One more case is worth mentioning, because it complicates the simple story.
Another applicant, APP-10030, was also referred. Their debt-to-income was 73%,
so they would almost certainly have been declined anyway. The trust check didn't
save them from a wrong approval — it stopped the bank making a *decline* it
couldn't back up either. Bad data doesn't only cause bad approvals. It weakens
every automatic decision, including the ones that happen to turn out right.

---

## The dashboard

Everything above is also available in a dashboard built with **Streamlit in
Snowflake**, a way to build simple web apps that run inside Snowflake. It needs
no extra software or passwords, and people only see the data they're already
allowed to see.

- **Three outcomes** — the comparison above
- **Feed trust monitor** — each data source, its status, its limit and its owner
- **Decision audit trail** — every decision and whether it was defensible
- **Source records** — from a decision down to the individual records behind it
- **Drift** — the numbers at decision time compared with today's
- **Agent chat** — talk to the lending agent and see each tool it uses

`[SCREENSHOT: Streamlit in Snowflake — LENDING_TRUST_AUDIT overview with KPI
row: feeds failing trust, worst staleness, decisions blocked, records on
failing feeds]`

`[SCREENSHOT: Streamlit in Snowflake — Feed trust monitor tab]`

---

## Where Ataccama fits

Everything above uses only Snowflake's built-in features, and it has limits. Our
checks answer simple questions: *How old is this? Is it missing? Is it
duplicated? Is it a valid value?* They don't spot a number that has quietly
drifted away from its usual range, compare records against an outside system,
or combine everything into one overall trust score.

That is what Ataccama adds. The two connect through a single table that
Ataccama fills in:

```sql
CREATE OR REPLACE TABLE GOVERNANCE.ATACCAMA_TRUST_SIGNALS (
    SIGNAL_ID          VARCHAR(60) NOT NULL,
    SCOPE_OBJECT       VARCHAR(200),   -- which table, e.g. RAW.LIABILITIES
    FEED_NAME          VARCHAR(80),    -- which source
    RECORD_IDENTIFIER  VARCHAR(200),   -- which exact record
    SIGNAL_NAME        VARCHAR(80),    -- which Ataccama rule
    SIGNAL_DIMENSION   VARCHAR(40),    -- what kind of check
    MEASURED_VALUE     NUMBER(14,4),
    DATA_TRUST_INDEX   NUMBER(5,2),    -- overall score, 0-100
    TRUST_STATUS       VARCHAR(20),    -- PASS | WARN | FAIL
    IS_BLOCKING        BOOLEAN,        -- should it stop automatic decisions?
    EVALUATED_AT       TIMESTAMP_LTZ,
    DETAIL             VARCHAR(1000)
);
```

The table starts empty, and the Snowflake side works without it. Once Ataccama
starts writing to it, their results flow straight into the agent's trust check
— **with no changes to the agent, the semantic view or the decision procedure.**

### `[ATACCAMA — TO BE WRITTEN]`

Topics for the Ataccama team:

1. **Rules as Snowflake checks** — Ataccama rules running as Snowflake Data
   Metric Functions, so their results sit alongside the ones above.
2. **The Data Trust Index** — what goes into the overall score, and what score
   should stop an automatic lending decision.
3. **Record-level tracing** — pointing to the exact record that failed, so a
   challenged decision can be traced precisely.
4. **Drift and unusual values** — the checks Snowflake's built-in ones don't
   cover.
5. **Direct connection to agents (MCP)** — MCP is a standard way for AI agents
   to connect to outside tools; it's an alternative to the shared table above.

Open questions for that team:

- The exact field names and types they publish, so the table above can be
  finalised.
- Is the Data Trust Index given per table, per source, per record, or all three?
- Do results arrive as Snowflake checks, direct table writes or MCP calls — and
  when should each be used?
- What index score should stop an automatic credit decision?

---

## What to take from this

1. **Check closely enough to catch real failures.** A table-wide freshness
   check said 66 seconds while one source inside it was 42 days behind.
   Table-wide checks are useful, but not enough on their own.
2. **Put trust numbers next to business numbers.** If the warning lives in a
   different system, someone has to remember to look. Put it beside the number
   and it arrives with the number.
3. **Make the trust check a hard stop, not a suggestion.** Telling an agent to
   check trust is good. Building it so it *can't* decide without checking is
   better.
4. **Record what was used, not just what was decided.** Without that, an audit
   just re-runs today's numbers and calls it history.
5. **Check trust for each decision.** A score for the whole dataset can't tell
   you whether *this* applicant's numbers are safe.
6. **"Not checked" isn't "fine".** Show unchecked sources clearly so the gap
   stays visible.

The semantic layer was never the problem. It worked perfectly the whole time —
every number meant exactly what it should — and that's exactly why the original
failure was so hard to see. What was missing was a live signal, right next to
each number, confirming it could still be trusted before the agent used it.

You can build that today, in Snowflake, with the pieces above.

---

## Run it yourself

The companion repo has everything: `SETUP.md` to build it on your own Snowflake
account step by step, `README.md` to explain how the pieces fit, the sample data
as CSV files, ten SQL scripts in run order, and the dashboard.

```
data/*.csv                        the sample data: applicants, income, debts,
                                  repayments, and the late batch
sql/00_setup_database.sql         database, schemas, and a stage for the files
sql/01_raw_source_systems.sql     four mock source systems
sql/02_load_mock_data.sql         load the CSVs (re-run it to reset the demo)
sql/03_semantic_layer.sql         one profile per applicant, with data ages
sql/04_semantic_view.sql          semantic view with trust numbers
sql/05_trust_signals.sql          checks, limits, tags, Ataccama table
sql/06_decision_flow.sql          decision procedure with the trust gate
sql/07_agent.sql                  the AI agent
sql/08_audit_trail.sql            decision log, record tracing, then-vs-now
sql/09_late_arriving_truth.sql    load the missing data, see the decision change
streamlit/streamlit_app.py        dashboard
```

---

## Open items before publication

| # | Item | Owner |
|---|---|---|
| 1 | **Agent conversation transcript** — the Agent chat tab is working; capture the three exchanges described in the placeholder above. | Snowflake |
| 2 | **Screenshots** — seven `[SCREENSHOT]` placeholders. | Snowflake |
| 3 | **Ataccama sections** — the five topics and four open questions above. | Ataccama |
| 4 | **Apache Ossie framing** — piece one positions Semantic Views as the reference implementation for Apache Ossie and mentions Semantic View Autopilot. I couldn't independently verify the current status or naming of either, so both are left out of the technical steps. Someone should confirm the right wording before publication. | Snowflake PMM |
| 5 | **Title and intro** — check they line up with the published piece one. | Both |

---

## Appendix: Key terms

You don't need a finance or data background to follow this blog. These are the
only terms you need:

| Term | What it means |
|---|---|
| **Liability** | Money a person owes: a mortgage, a car loan, a credit card balance. |
| **Credit bureau** | A company that collects records of what people owe and shares them with lenders. |
| **Debt-to-income (DTI)** | The share of someone's yearly income that goes on debt payments. Lower is safer. Many lenders won't approve above about 40%. |
| **Data feed** | A regular delivery of records from one system into another. |
| **Stale data** | Data that hasn't been updated for a while, so it may no longer be true. |
| **Semantic layer** | A shared dictionary that defines each business number once — for example, "total owed" — so every tool calculates it the same way. |
| **Trust signal** | A measurement that says whether data is safe to use right now, such as how old it is. |
| **AI agent** | An AI assistant that can look things up and take actions, using tools it has been given. |
