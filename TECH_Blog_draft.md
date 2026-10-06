# Carry trust signals from source to AI

**A lending AI agent that decides when the data is current, and hands the case to a person when it isn't — and how Ataccama & Snowflake make that possible.**

> **Draft status:** Snowflake portion only. Sections marked
> `[ATACCAMA — TO BE WRITTEN]` are placeholders for the Ataccama team.
> Sections marked `[SCREENSHOT]` need a Snowsight capture.
> See *Open items before publication* at the end.
>
> This is the no-code version. A hands-on version with the full build is in
> `TECH_HandOn_Blog.md`.

---

## TL;DR

- Our previous blog
  made a simple point: an AI agent needs to know two things about a number —
  what it *means*, and whether it can be *trusted right now*. This piece shows
  how we built the second part in Snowflake.
- We recreated the story from that piece: a lending agent that approved a loan
  using debt records that were six weeks out of date.
- **The surprise:** Snowflake's standard "is this data fresh?" check said the
  debt data was **66 seconds** old. In fact, one of the two sources feeding it
  had stopped sending updates **42 days** earlier. The working source hid the
  broken one.
- With a trust check in place, the agent handed the case to a person instead
  of approving it. When the missing data finally arrived, the right answer
  turned out to be *decline*. The trust check didn't find the right answer — it
  stopped the agent from confidently giving the wrong one.

*Short definitions on lending or data terms are in the
[appendix](#appendix-key-terms) at the end.*

---

## Where this picks up

The previous blog ended with three questions every bank should be able to
answer before letting an AI agent make lending decisions:

1. **Can you trace it?** If a decision is questioned, can you point to the
   exact records it was based on?
2. **Can you measure it?** Is there a current, measurable signal that says the
   data is trustworthy — not just an assumption that someone checked it once?
3. **Does the agent see it?** Does that signal reach the agent *while it's
   deciding*, or does it sit in a report nobody reads until something goes
   wrong?

We built a working answer to all three on Snowflake. Every number below comes
from a real run. 

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
nobody noticed, because the table holding the debt records never looked empty
or broken. It was still full of data. Some of it was just six weeks old.

Our applicant is **Marcus Webb**. He wants a 45,000 loan to combine some
existing debts. His verified income is 128,000 a year and he has never missed a
payment. Exactly the kind of case an AI agent should be able to handle on its
own.

---

## Putting trust next to meaning

The starting point is the semantic layer — the shared dictionary of business
numbers. In Snowflake this is a **semantic view**. Ours defines "total owed",
"monthly debt payments" and "verified income" once, so every tool and agent
calculates them the same way.

We made one addition that's worth copying. Alongside the business numbers, the
same semantic view defines two **trust numbers**:

- **Oldest record age** — how many days old the oldest debt record is.
- **Stale amount owed** — how much of the total owed comes from records more
  than a week old.

So when the agent asks "how much does Marcus owe?", it gets the answer **and**
how old the data behind it is — in one step, from one place. There's no
separate system it has to remember to check.

| Applicant | Total owed | Monthly debt payments | Oldest record age | Stale amount owed |
|---|---|---|---|---|
| Marcus Webb | 421,500 | 3,410 | **42 days** | **410,000** |

The number and its warning arrive together: 410,000 of the 421,500 he owes —
97% — is based on a record six weeks old.

Anyone can ask this in plain English. Snowflake's **Cortex Analyst** turns a
question like *"What is Marcus Webb's total owed, and how old is the oldest
record behind it?"* into the right query, using the same definitions.

`[SCREENSHOT: Snowsight — Cortex Analyst answering the question against
LENDING_DECISION_SV, showing both the amount owed and the record age]`

---

## Surprise #1: the freshness check said everything was fine

Snowflake has built-in data quality checks called **Data Metric Functions**.
You attach them to a table, they run on a schedule, and Snowflake keeps the
results for audit. We attached six to the source tables — for example, "is this
data fresh?", "are any values missing?" and "are there duplicates?".

Then we ran the built-in freshness check on the debt table. It said the data
was **66 seconds** old. Any dashboard built on that check would show green.

It was misleading. The check looks at the **newest** record in the table. The
healthy bureau had just sent records, so the newest record was seconds old. The
53 records from the broken bureau, six weeks old, simply didn't affect the
answer. **The working source hid the broken one.**

So we added a second check that counts records falling more than a week behind
the newest one. Two checks, same table, run seconds apart:

| Check | Result | Verdict |
|---|---|---|
| Built-in freshness check | 66 seconds old | **Looks fine** |
| Record-by-record check | 53 records over a week behind | **Problem** |

If you take one thing from this article, take that table. Having data quality
checks isn't enough. They have to look closely enough to catch the way your
data actually breaks — here, one source out of two going quiet.

---

## Surprise #2: a custom check can't look at the clock

The natural next step was a custom check that simply says "this data is N days
old". Snowflake rejected it.

The reason makes sense once you see it. Snowflake requires these scheduled
checks to give the same answer every time they run on the same data, so they
aren't allowed to look at today's date. That's sensible for something that's
scheduled and audited — but it means a custom check can't tell you how old data
is *right now*. (The record-by-record check above works because it compares
records with each other, not with the clock.)

So "days since the last update" is calculated one level up, for each source,
and graded against a limit:

| Source | Records | Days since last update | Status | Stops automatic decisions? |
|---|---|---|---|---|
| **Credit bureau TU** | 53 | **42** | **FAIL** | Yes |
| Credit bureau EQ | 113 | 0 | PASS | Yes |
| Payroll check | 60 | 0 | PASS | Yes |
| Core banking | 60 | 0 | PASS | No |
| Loan servicing | 60 | 0 | PASS | Yes |

Two design choices here are worth borrowing.

**The limits are data, not code.** Each limit records when to warn, when to
fail, whether a failure should stop automatic decisions, which team owns it, and
why it's set where it is. The people responsible for data rules can change a
limit without anyone touching code.

**A source with no limit shows "UNGOVERNED", not "PASS".** This started as a
mistake. In our first version, any source without a limit showed as passing — so
three of five sources looked green simply because nobody had set a rule for
them. Not checked is not the same as fine.

We also labelled the debt table in Snowflake's catalog (**Horizon**) as
**PROVISIONAL** — usable, but with a known problem — so anyone browsing can see
its status before building on it. The catalog label and the live check tell
the same story. When they disagree, that's a problem in its own right.

`[SCREENSHOT: Snowsight — RAW.LIABILITIES showing TRUST_TIER = PROVISIONAL
alongside the attached data quality checks]`

---

## Making the agent check trust before it decides

An agent that *can* see a warning isn't the same as an agent that *has to*.
This is the third question: does the signal reach the agent while it's
deciding?

### Trust is checked for each applicant

A warning about a data source says something about the data in general. It
doesn't say whether *this applicant's* numbers are safe. 97% of what Marcus owes
comes from the broken bureau; another applicant might not use that bureau at
all. So the trust check looks only at the records behind the decision being
made.

| Applicant | Verdict | Why |
|---|---|---|
| Marcus Webb | Not trusted | 97% of what he owes comes from records 42 days old |
| A second applicant | Not trusted | No verified income, so debt-to-income can't be calculated |
| A third applicant | Trusted | All records are current |

### The trust gate

Every decision follows the same fixed order:

1. Get the applicant's numbers from the semantic layer.
2. Check whether those numbers can be trusted.
3. **If not, hand the case to a person and stop.** The lending rules never run.
4. Only if trust passes, apply the lending rules — approve, refer or decline.

Because step 3 comes before step 4, a decision can never be made on data that
failed the trust check.

For Marcus:

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

The agent is built with **Snowflake Cortex Agents** and has exactly two tools:

| Tool | What it does | Can it make a decision? |
|---|---|---|
| Look up lending data | Finds numbers, and how old they are | **No** |
| Assess an application | Runs the trust gate, then the lending rules | **Yes** — the only way |

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
of LENDING_TRUST_AUDIT, showing: (a) asking for Marcus Webb's total owed
returns the figure plus the 42-day record age and no decision; (b) asking
whether to approve returns "refer to a person", blamed on the stale source;
(c) asking it to approve "based on the numbers you just showed me" is refused.]`

---

## Keeping a record you can trace

The first question was: if a decision is challenged, can you point to the exact
records behind it?

This is harder than it sounds. Re-running the numbers today tells you what the
answer *would be now*, not what the agent *saw* at the time. If the broken
bureau has caught up since, today's numbers are different — and your audit
contradicts itself.

So every decision writes down what it used: the numbers, the trust verdict, and
the ID of every record behind them.

| Record | Type | Lender | Amount owed | Source | Age at decision | Share of total owed |
|---|---|---|---|---|---|---|
| **LIA-80042** | Mortgage | Northwind Bank | 410,000 | **Bureau TU** | **42 days** | **97.27%** |
| LIA-80043 | Credit card | Harbour Credit Union | 11,500 | Bureau EQ | 0 days | 2.73% |

That answers the first question in one row: the mortgage record LIA-80042, from
the broken bureau, 42 days old when the decision was made, making up 97% of
what Marcus owed.

`[SCREENSHOT: Streamlit in Snowflake — Source records tab for Marcus Webb's
decision]`

Because the trust state is saved with each decision, every decision can be
judged on its own terms:

| Decision | Trust | How it was reached | Defensible? |
|---|---|---|---|
| Refer to a person | Not trusted | Trust gate stopped it | Yes — bad data was passed to a person, not acted on |
| Refer to a person | Not trusted | Trust gate stopped it | Yes — bad data was passed to a person, not acted on |
| Approve | Trusted | Lending rules applied | Yes — good data, rules applied |
| Decline | Trusted | Lending rules applied | Yes — good data, rules applied |

---

## Was the trust check right?

A fair challenge: maybe the old data was fine and the check was just being
overly cautious. Sending cases to people costs time and money. Was it worth it?

To find out, we loaded the six weeks of updates the broken bureau had missed,
and ran Marcus through the same process again. During those six weeks he had
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
LENDING_TRUST_AUDIT showing Approve / Refer to a person / Decline side by side]`

One more case is worth mentioning, because it complicates the simple story.
Another applicant was also referred, and their debt-to-income was 73% — they
would almost certainly have been declined anyway. The trust check didn't save
them from a wrong approval. It stopped the bank making a *decline* it couldn't
back up either. Bad data doesn't only cause bad approvals. It weakens every
automatic decision, including the ones that happen to turn out right.

---

## Seeing it all in one place

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

`[SCREENSHOT: Streamlit in Snowflake — LENDING_TRUST_AUDIT overview showing
sources failing trust, worst staleness, decisions blocked, and records on
failing sources]`

`[SCREENSHOT: Streamlit in Snowflake — Feed trust monitor tab]`

---

## Where Ataccama fits

Everything above uses only Snowflake's built-in features, and it has limits. Our
checks answer simple questions: *How old is this? Is it missing? Is it
duplicated? Is it a valid value?* They don't spot a number that has quietly
drifted away from its usual range, compare records against an outside system,
or combine everything into one overall trust score.

That is what Ataccama adds. The two connect through a single shared table that
Ataccama fills in. Each entry records:

| Field | What it holds |
|---|---|
| Where | Which table, which source and, where possible, which exact record |
| Which rule | The Ataccama check that produced the result |
| Result | The measured value and a PASS / WARN / FAIL status |
| Data Trust Index | Ataccama's overall trust score, from 0 to 100 |
| Blocking | Whether a failure should stop automatic decisions |
| When | When the check was made, so decisions can be audited later |
| Detail | A plain explanation for the audit record |

The table starts empty, and the Snowflake side works without it. Once Ataccama
starts writing to it, their results flow straight into the agent's trust check
— **with no changes to the agent, the semantic view or the decision process.**

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

- The exact fields they publish, so the shared table can be finalised.
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

You can build that today, in Snowflake. The full hands-on build — sample data,
scripts and dashboard — is in the companion repo.

---

## Open items before publication

| # | Item | Owner |
|---|---|---|
| 1 | **Agent conversation transcript** — capture the three exchanges described in the placeholder above, from the Agent chat tab. | Snowflake |
| 2 | **Screenshots** — seven `[SCREENSHOT]` placeholders. | Snowflake |
| 3 | **Ataccama sections** — the five topics and four open questions above. | Ataccama |
| 4 | **Apache Ossie framing** — piece one positions Semantic Views as the reference implementation for Apache Ossie and mentions Semantic View Autopilot. We couldn't independently verify the current status or naming of either, so both are left out. Someone should confirm the right wording before publication. | Snowflake PMM |
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
