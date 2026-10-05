/* ============================================================================
   04_semantic_view.sql
   ----------------------------------------------------------------------------
   SEMANTIC.LENDING_DECISION_SV -- the governed semantic layer that Cortex
   Analyst and Cortex Agents read.

   WHY THIS MATTERS FOR THE DEMO
   -----------------------------
   The semantic view is where "outstanding exposure", "monthly obligations" and
   "verified income" are defined ONCE, so every tool and agent resolves them
   identically. That is the blog 1 argument: semantics tell the agent what the
   data means.

   The addition here is that two of the metrics are not credit measures at all:

       liabilities.worst_staleness_days
       liabilities.stale_exposure

   They are TRUST signals, published in the same governed object as the business
   metrics. An agent asking "what is this applicant's exposure?" can ask, in the
   same breath and through the same interface, "and how old is the data behind
   it?" -- no second system, no separate dashboard.

   VERIFIED BEHAVIOUR (run against the demo account)
   -------------------------------------------------
   Direct SEMANTIC_VIEW() query for APP-10042 returns:
       outstanding_exposure     421,500.00
       monthly_obligations        3,410.00
       worst_staleness_days              42
       stale_exposure           410,000.00
       verified_annual_income   128,000.00
       missed_payments                    0

   Cortex Analyst resolves the natural-language question
       "What is the total outstanding exposure and the worst record staleness
        in days for applicant APP-10042?"
   into correct SQL against these definitions.
   ============================================================================ */

USE DATABASE ATACCAMA_TRUST_DEMO;
USE SCHEMA SEMANTIC;

CREATE OR REPLACE SEMANTIC VIEW LENDING_DECISION_SV
  TABLES (
    applicants AS ATACCAMA_TRUST_DEMO.RAW.APPLICANTS
      PRIMARY KEY (APPLICANT_ID)
      WITH SYNONYMS = ('borrowers', 'loan applicants', 'customers')
      COMMENT = 'Loan applicants and the application under assessment',
    income AS ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION
      PRIMARY KEY (INCOME_RECORD_ID)
      WITH SYNONYMS = ('verified income', 'earnings')
      COMMENT = 'Verified income per applicant',
    liabilities AS ATACCAMA_TRUST_DEMO.RAW.LIABILITIES
      PRIMARY KEY (LIABILITY_ID)
      WITH SYNONYMS = ('debts', 'obligations', 'credit commitments')
      COMMENT = 'Outstanding liabilities reported by credit bureau feeds',
    repayment AS ATACCAMA_TRUST_DEMO.RAW.REPAYMENT_HISTORY
      PRIMARY KEY (PAYMENT_RECORD_ID)
      WITH SYNONYMS = ('payment history', 'delinquency history')
      COMMENT = 'Repayment behaviour summary per applicant'
  )
  RELATIONSHIPS (
    income_to_applicant      AS income      (APPLICANT_ID) REFERENCES applicants,
    liabilities_to_applicant AS liabilities (APPLICANT_ID) REFERENCES applicants,
    repayment_to_applicant   AS repayment   (APPLICANT_ID) REFERENCES applicants
  )
  FACTS (
    liabilities.balance AS OUTSTANDING_BALANCE
      COMMENT = 'Balance still owed on a single liability',
    liabilities.payment AS MONTHLY_PAYMENT
      COMMENT = 'Contractual monthly payment on a single liability',
    -- Record age is modelled as a fact so it can be aggregated like any other
    liabilities.staleness_days AS DATEDIFF(day, LOADED_AT, CURRENT_TIMESTAMP())
      COMMENT = 'Age in days of this liability record since it last loaded',
    income.annual_income AS GROSS_ANNUAL_INCOME
      COMMENT = 'Verified gross annual income',
    repayment.missed AS MISSED_PAYMENTS_12M
      COMMENT = 'Missed payments in the trailing 12 months'
  )
  DIMENSIONS (
    applicants.applicant_id AS APPLICANT_ID
      WITH SYNONYMS = ('customer id', 'borrower id')
      COMMENT = 'Unique applicant identifier',
    applicants.applicant_name AS FULL_NAME
      COMMENT = 'Applicant legal name',
    applicants.employment_status AS EMPLOYMENT_STATUS
      COMMENT = 'Employment classification: FULL_TIME, PART_TIME, SELF_EMPLOYED, CONTRACT',
    applicants.loan_purpose AS LOAN_PURPOSE
      COMMENT = 'Stated purpose of the loan',
    applicants.application_date AS APPLICATION_DATE
      COMMENT = 'Date the application was submitted',
    liabilities.liability_type AS LIABILITY_TYPE
      WITH SYNONYMS = ('debt type')
      COMMENT = 'Category of liability: MORTGAGE, CREDIT_CARD, AUTO_LOAN, PERSONAL_LOAN, STUDENT_LOAN',
    liabilities.source_feed AS SOURCE_SYSTEM
      WITH SYNONYMS = ('bureau feed', 'data source')
      COMMENT = 'Credit bureau feed that supplied this record: BUREAU_EQ or BUREAU_TU'
  )
  METRICS (
    /* ---- business meaning ------------------------------------------------ */
    liabilities.outstanding_exposure AS SUM(liabilities.balance)
      WITH SYNONYMS = ('total exposure', 'total debt', 'total balance owed')
      COMMENT = 'Total balance owed across all liabilities. The bank-wide definition of outstanding exposure.',
    liabilities.monthly_obligations AS SUM(liabilities.payment)
      WITH SYNONYMS = ('monthly debt payments')
      COMMENT = 'Total contractual monthly payments across all liabilities',
    income.verified_annual_income AS MAX(income.annual_income)
      WITH SYNONYMS = ('income', 'salary')
      COMMENT = 'Verified gross annual income for the applicant',
    repayment.missed_payments AS MAX(repayment.missed)
      COMMENT = 'Missed payments in the trailing 12 months',

    /* ---- trust signals, published alongside the meaning ------------------ */
    liabilities.worst_staleness_days AS MAX(liabilities.staleness_days)
      WITH SYNONYMS = ('data age', 'oldest record age')
      COMMENT = 'Age in days of the oldest liability record contributing to this result. A trust signal, not a credit measure.',
    liabilities.stale_exposure AS SUM(CASE WHEN liabilities.staleness_days > 7 THEN liabilities.balance ELSE 0 END)
      COMMENT = 'Portion of outstanding exposure sourced from feeds older than 7 days'
  )
  COMMENT = 'Governed semantic layer for automated credit decisioning. Defines outstanding exposure, monthly obligations and income once, and carries record-age trust signals alongside them.';

/* ----------------------------------------------------------------------------
   Verification query -- the agent's view of the hero applicant
   ---------------------------------------------------------------------------- */
SELECT * FROM SEMANTIC_VIEW(
    LENDING_DECISION_SV
    DIMENSIONS applicants.applicant_id, applicants.applicant_name
    METRICS liabilities.outstanding_exposure,
            liabilities.monthly_obligations,
            liabilities.worst_staleness_days,
            liabilities.stale_exposure,
            income.verified_annual_income,
            repayment.missed_payments
)
WHERE applicant_id = 'APP-10042';
