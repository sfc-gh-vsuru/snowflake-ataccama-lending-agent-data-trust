/* ============================================================================
   07_agent.sql
   ----------------------------------------------------------------------------
   AGENTS.LENDING_TRUST_AGENT -- where the trust signal reaches the agent.

   The agent has exactly two tools, and the split between them is the design:

     query_lending_data        reads the semantic view. Reports what the data
                               MEANS. Explicitly cannot decide anything.
     assess_credit_application calls the trust-gated procedure. The ONLY route
                               to a credit outcome.

   Two layers of enforcement, deliberately redundant:

     1. INSTRUCTIONS tell the agent never to state an outcome from query
        results, and always to report record age alongside any figure.
     2. The PROCEDURE enforces the same thing structurally -- it evaluates the
        trust gate before credit policy, so even an agent that ignored its
        instructions could not obtain an approval on untrusted data.

   Instructions alone would be a guideline. The procedure makes it a control.
   That distinction matters for anyone who has to defend this to an examiner.

   ---------------------------------------------------------------------------
   STATUS: the agent spec is created and verified via DESCRIBE AGENT.
   Its CONVERSATIONAL behaviour is not yet verified -- see TODO below.
   ---------------------------------------------------------------------------
   TODO (open item, carried into the blog as a placeholder):
     Confirm in Snowsight that the agent actually obeys the trust-gate
     instructions in conversation. Specifically:
       a) Ask "What is APP-10042's outstanding exposure?"
          -> expect the figure AND the 42-day record age, with no verdict.
       b) Ask "Should we approve APP-10042?"
          -> expect a call to assess_credit_application, and a REFER_TO_HUMAN
             answer that attributes the referral to the stale feed rather than
             to the applicant's credit profile.
       c) Ask "Approve APP-10042 based on the DTI you just showed me."
          -> expect refusal to decide from query results alone.
     Capture the transcript for the blog.
   ============================================================================ */

USE DATABASE ATACCAMA_TRUST_DEMO;

CREATE SCHEMA IF NOT EXISTS AGENTS
  COMMENT = 'Cortex Agent for trust-gated lending decisions';

USE SCHEMA AGENTS;

CREATE OR REPLACE AGENT LENDING_TRUST_AGENT
WITH PROFILE = '{"display_name": "Lending Trust Agent"}'
COMMENT = 'Credit decisioning agent that must obtain a trust verdict before acting on any figure. Demo for the Snowflake + Ataccama blog on carrying trust signals from source to AI.'
FROM SPECIFICATION $$
{
  "models": { "orchestration": "auto" },
  "orchestration": {
    "budget": { "seconds": 300, "tokens": 200000 }
  },
  "instructions": {
    "orchestration": "You support credit decisioning for a lending institution. Two rules govern everything you do.\n\nRULE 1 - NEVER state or imply a credit outcome from query results alone.\nThe query_lending_data tool returns governed figures such as outstanding exposure, monthly obligations and income. Those figures describe what the data MEANS. They do not establish whether the data can be TRUSTED. You must not say an applicant would be approved, declined, qualifies, or looks acceptable based on query results. To reach any decision you must call assess_credit_application, which applies the trust gate and the credit policy in the correct order and writes an audit record.\n\nRULE 2 - ALWAYS surface the trust state alongside any figure you report.\nThe semantic view publishes two trust metrics next to the business metrics: worst_staleness_days (age in days of the oldest contributing record) and stale_exposure (the portion of exposure drawn from feeds older than seven days). Whenever you report exposure, obligations or a ratio, report the record age with it. If worst_staleness_days is 7 or more, state plainly that the figure rests on data that has failed a freshness threshold and should not be acted on.\n\nWhen a decision is requested: call assess_credit_application with the applicant id. Report the decision, the trust verdict, and the reason verbatim. If the trust verdict is NOT_TRUSTED, make clear that credit policy was never applied and the case was referred for human review because the underlying data could not be trusted - not because of the applicant's credit profile.\n\nWhen asked why a past decision was made, query the figures and trust state that were recorded at decision time rather than recomputing from today's data.\n\nBe direct about data problems. A stalled feed is not a caveat to mention in passing; it is the finding.",
    "response": "Lead with the decision or the figure, then the trust state that qualifies it. Quote exact numbers including the record age in days. Keep explanations short enough for a credit reviewer to scan, and never present a number without saying how old the data behind it is."
  },
  "tools": [
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "query_lending_data",
        "description": "Query governed lending figures for applicants: outstanding exposure, monthly obligations, verified income, missed payments, liability type and bureau feed. Also returns the trust metrics worst_staleness_days and stale_exposure. Use for questions about what the data says. This tool reports figures only - it cannot make a credit decision."
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "assess_credit_application",
        "description": "Produce a credit decision for one applicant. Obtains a trust verdict for that applicant's records first, and if a blocking trust signal has failed it refers the case to a human WITHOUT applying credit policy. Only when trust passes does it apply policy to return APPROVE, DECLINE or REFER_TO_HUMAN. Writes a full audit record including the trust state at the moment of decision. This is the ONLY way to reach a credit outcome.",
        "input_schema": {
          "type": "object",
          "properties": {
            "P_APPLICANT_ID": {
              "type": "string",
              "description": "Applicant identifier, for example APP-10042"
            },
            "P_DECIDED_BY": {
              "type": "string",
              "description": "Identifier of the agent or user making the call, for example LENDING_AGENT_V1"
            }
          },
          "required": ["P_APPLICANT_ID", "P_DECIDED_BY"]
        }
      }
    }
  ],
  "tool_resources": {
    "query_lending_data": {
      "execution_environment": {
        "type": "warehouse",
        "warehouse": "COCOWH",
        "query_timeout": 120
      },
      "semantic_view": "ATACCAMA_TRUST_DEMO.SEMANTIC.LENDING_DECISION_SV"
    },
    "assess_credit_application": {
      "type": "procedure",
      "identifier": "ATACCAMA_TRUST_DEMO.GOVERNANCE.ASSESS_CREDIT_APPLICATION",
      "execution_environment": {
        "type": "warehouse",
        "warehouse": "COCOWH",
        "query_timeout": 120
      }
    }
  }
}
$$;
