/* ============================================================================
   03_semantic_layer.sql
   ----------------------------------------------------------------------------
   The semantic layer: what the numbers MEAN.

   Two objects:

   1. SEMANTIC.V_APPLICANT_CREDIT_PROFILE
      One governed row per applicant. Resolves four source systems into a
      single applicant profile and applies written lending policy to produce
      outstanding exposure, DTI and risk tier.

      Crucially, it also carries PROVENANCE columns next to those business
      figures -- which feeds were used, and how stale the oldest one is. This
      is the "carry the trust signal alongside the definition" idea made
      concrete: an agent reading this view cannot see the DTI without also
      being able to see how old the data behind it is.

   2. SEMANTIC.LENDING_DECISION_SV
      A Snowflake Semantic View over the profile and the underlying detail,
      so Cortex Analyst and Cortex Agents resolve "outstanding exposure" or
      "risk tier" the same way every time they are asked.

   POLICY DEFINITIONS USED BELOW (the bank's written rules, encoded once)
   ---------------------------------------------------------------------
   outstanding_exposure = SUM of outstanding balances across all liabilities
   monthly_obligations  = SUM of contractual monthly payments
   dti_pct              = monthly_obligations * 12 / gross_annual_income * 100

   risk_tier   TIER_1_LOW        dti < 30  and missed_payments_12m = 0
               TIER_2_MODERATE   dti < 40  and missed_payments_12m <= 1
               TIER_3_ELEVATED   dti < 50  and missed_payments_12m <= 2
               TIER_4_HIGH       otherwise

   NOTE ON SCOPE
   -------------
   Everything here is Snowflake-native. The provenance columns answer "how old
   is this?" from load metadata. They do NOT assess accuracy, drift, or
   conformance to business rules -- that is the Ataccama trust layer, wired in
   at script 05.
   ============================================================================ */

USE DATABASE ATACCAMA_TRUST_DEMO;
USE SCHEMA SEMANTIC;

/* ============================================================================
   1. Curated applicant credit profile
   ============================================================================ */
CREATE OR REPLACE VIEW V_APPLICANT_CREDIT_PROFILE
COMMENT = 'Governed one-row-per-applicant credit profile. Business meaning (exposure, DTI, risk tier) carried together with data provenance (which feeds, how stale).'
AS
WITH liability_rollup AS (
    SELECT
        APPLICANT_ID,
        SUM(OUTSTANDING_BALANCE)                                  AS outstanding_exposure,
        SUM(MONTHLY_PAYMENT)                                      AS monthly_obligations,
        COUNT(*)                                                  AS liability_count,
        -- Provenance: which feeds contributed, and how current are they
        ARRAY_AGG(DISTINCT SOURCE_SYSTEM)                         AS liability_feeds_used,
        MIN(LOADED_AT)                                            AS oldest_liability_loaded_at,
        MAX(LOADED_AT)                                            AS newest_liability_loaded_at,
        DATEDIFF(day, MIN(LOADED_AT), CURRENT_TIMESTAMP())        AS max_liability_staleness_days,
        -- Exposure that is specifically sourced from a stale feed (>7 days old)
        SUM(CASE WHEN DATEDIFF(day, LOADED_AT, CURRENT_TIMESTAMP()) > 7
                 THEN OUTSTANDING_BALANCE ELSE 0 END)             AS exposure_from_stale_feeds
    FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES
    GROUP BY APPLICANT_ID
)
SELECT
    /* ---- identity ---------------------------------------------------- */
    a.APPLICANT_ID,
    a.APPLICATION_ID,
    a.FULL_NAME,
    a.EMPLOYMENT_STATUS,
    a.APPLICATION_DATE,
    a.REQUESTED_AMOUNT,
    a.LOAN_PURPOSE,

    /* ---- business meaning: the figures a lending agent reasons over --- */
    i.GROSS_ANNUAL_INCOME                                         AS gross_annual_income,
    lr.outstanding_exposure,
    lr.monthly_obligations,
    lr.liability_count,
    CASE WHEN i.GROSS_ANNUAL_INCOME > 0
         THEN ROUND(lr.monthly_obligations * 12
                    / i.GROSS_ANNUAL_INCOME * 100, 2)
    END                                                           AS dti_pct,
    r.MISSED_PAYMENTS_12M                                         AS missed_payments_12m,
    r.MAX_DAYS_PAST_DUE                                           AS max_days_past_due,

    /* ---- risk tier: bank policy, encoded once ------------------------- */
    CASE
        WHEN i.GROSS_ANNUAL_INCOME IS NULL
          OR lr.monthly_obligations IS NULL THEN 'TIER_UNKNOWN'
        WHEN ROUND(lr.monthly_obligations * 12 / i.GROSS_ANNUAL_INCOME * 100, 2) < 30
             AND COALESCE(r.MISSED_PAYMENTS_12M, 0) = 0           THEN 'TIER_1_LOW'
        WHEN ROUND(lr.monthly_obligations * 12 / i.GROSS_ANNUAL_INCOME * 100, 2) < 40
             AND COALESCE(r.MISSED_PAYMENTS_12M, 0) <= 1          THEN 'TIER_2_MODERATE'
        WHEN ROUND(lr.monthly_obligations * 12 / i.GROSS_ANNUAL_INCOME * 100, 2) < 50
             AND COALESCE(r.MISSED_PAYMENTS_12M, 0) <= 2          THEN 'TIER_3_ELEVATED'
        ELSE 'TIER_4_HIGH'
    END                                                           AS risk_tier,

    /* ---- provenance: carried alongside the meaning -------------------- */
    lr.liability_feeds_used,
    lr.oldest_liability_loaded_at,
    lr.newest_liability_loaded_at,
    lr.max_liability_staleness_days,
    lr.exposure_from_stale_feeds,
    CASE WHEN lr.outstanding_exposure > 0
         THEN ROUND(lr.exposure_from_stale_feeds
                    / lr.outstanding_exposure * 100, 2)
         ELSE 0
    END                                                           AS pct_exposure_from_stale_feeds,
    GREATEST(
        DATEDIFF(day, a.LOADED_AT, CURRENT_TIMESTAMP()),
        DATEDIFF(day, COALESCE(i.LOADED_AT, a.LOADED_AT), CURRENT_TIMESTAMP()),
        DATEDIFF(day, COALESCE(lr.oldest_liability_loaded_at, a.LOADED_AT), CURRENT_TIMESTAMP()),
        DATEDIFF(day, COALESCE(r.LOADED_AT, a.LOADED_AT), CURRENT_TIMESTAMP())
    )                                                             AS worst_staleness_days_any_source

FROM            ATACCAMA_TRUST_DEMO.RAW.APPLICANTS          a
LEFT JOIN       ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION i  ON i.APPLICANT_ID  = a.APPLICANT_ID
LEFT JOIN       liability_rollup                            lr ON lr.APPLICANT_ID = a.APPLICANT_ID
LEFT JOIN       ATACCAMA_TRUST_DEMO.RAW.REPAYMENT_HISTORY   r  ON r.APPLICANT_ID  = a.APPLICANT_ID;
