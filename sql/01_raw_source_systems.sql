/* ============================================================================
   01_raw_source_systems.sql
   ----------------------------------------------------------------------------
   Mock lending source systems for the "Carry trust signals from source to AI"
   demo (Snowflake + Ataccama, blog 2).

   Four source systems feed the lending decision, exactly as described in blog 1:
     CORE_BANKING   -> applicants + loan applications
     PAYROLL_VERIFY -> verified income
     BUREAU_EQ /    -> outstanding liabilities (TWO bureau feeds)
     BUREAU_TU
     LOAN_SERVICING -> repayment history

   THE PLANTED FAILURE
   -------------------
   The BUREAU_TU feed stopped loading 42 days (six weeks) ago, while BUREAU_EQ
   keeps loading daily. This matters:

     - A table-level freshness check on RAW.LIABILITIES looks GREEN, because
       MAX(LOADED_AT) is driven by the still-current BUREAU_EQ rows.
     - The applicant at the centre of the story (APP-10042) has their largest
       liability sourced from BUREAU_TU, so the number the agent reasons over
       is six weeks stale.

   That gap -- a green table-level metric hiding a stale feed -- is the whole
   reason trust signals have to be carried at feed/record grain, not just
   table grain.

   Run order: 00 -> 01 -> upload data/*.csv -> 02 -> 03 -> ... (see SETUP.md)

   This script creates the tables only. 02_load_mock_data.sql fills them from
   the CSV files in data/.

   WARNING: re-running this script recreates the tables, which removes their
   data AND the data quality checks and tags attached by 05. Re-run 02 and 05
   afterwards. To reset only the data, re-run 02 on its own.
   ============================================================================ */

USE DATABASE ATACCAMA_TRUST_DEMO;
USE SCHEMA RAW;

/* ----------------------------------------------------------------------------
   Demo clock
   ----------------------------------------------------------------------------
   The CSVs store dates as offsets ("hours ago", "days ago"). 02 turns them
   into LOADED_AT / EFFECTIVE_DATE values relative to CURRENT_TIMESTAMP(), so
   the demo stays "six weeks stale" whenever it is built. Nothing is tied to a
   calendar date.
   ---------------------------------------------------------------------------- */

-- ============================================================================
-- 1. CORE_BANKING: applicants and their loan applications
-- ============================================================================
CREATE OR REPLACE TABLE APPLICANTS (
    APPLICANT_ID        VARCHAR(20)     NOT NULL COMMENT 'Natural key from core banking',
    APPLICATION_ID      VARCHAR(20)     NOT NULL COMMENT 'Loan application under assessment',
    FULL_NAME           VARCHAR(120)             COMMENT 'Applicant legal name',
    EMPLOYMENT_STATUS   VARCHAR(40)              COMMENT 'FULL_TIME | PART_TIME | SELF_EMPLOYED | CONTRACT',
    APPLICATION_DATE    DATE                     COMMENT 'Date the application was submitted',
    REQUESTED_AMOUNT    NUMBER(12,2)             COMMENT 'Loan amount requested, in account currency',
    LOAN_PURPOSE        VARCHAR(40)              COMMENT 'MORTGAGE | REFINANCE | PERSONAL | AUTO',
    SOURCE_SYSTEM       VARCHAR(40)     NOT NULL COMMENT 'Originating system of record',
    LOADED_AT           TIMESTAMP_LTZ   NOT NULL COMMENT 'When this record last landed in Snowflake',
    CONSTRAINT PK_APPLICANTS PRIMARY KEY (APPLICANT_ID)
)
COMMENT = 'Source: CORE_BANKING. Applicant master and the application being decided.';

-- ============================================================================
-- 2. PAYROLL_VERIFY: verified income
-- ============================================================================
CREATE OR REPLACE TABLE INCOME_VERIFICATION (
    INCOME_RECORD_ID     VARCHAR(20)    NOT NULL COMMENT 'Surrogate key for the income record',
    APPLICANT_ID         VARCHAR(20)    NOT NULL COMMENT 'FK -> APPLICANTS.APPLICANT_ID',
    GROSS_ANNUAL_INCOME  NUMBER(12,2)            COMMENT 'Verified gross annual income',
    VERIFICATION_METHOD  VARCHAR(40)             COMMENT 'PAYROLL_FEED | TAX_RETURN | BANK_STATEMENT',
    EFFECTIVE_DATE       DATE                    COMMENT 'Date the income figure was verified as of',
    SOURCE_SYSTEM        VARCHAR(40)    NOT NULL COMMENT 'Originating system of record',
    LOADED_AT            TIMESTAMP_LTZ  NOT NULL COMMENT 'When this record last landed in Snowflake',
    CONSTRAINT PK_INCOME PRIMARY KEY (INCOME_RECORD_ID)
)
COMMENT = 'Source: PAYROLL_VERIFY. Verified income, one current record per applicant.';

-- ============================================================================
-- 3. BUREAU_EQ / BUREAU_TU: outstanding liabilities
--    This is the table that carries the planted staleness.
-- ============================================================================
CREATE OR REPLACE TABLE LIABILITIES (
    LIABILITY_ID         VARCHAR(20)    NOT NULL COMMENT 'Surrogate key for the liability record',
    APPLICANT_ID         VARCHAR(20)    NOT NULL COMMENT 'FK -> APPLICANTS.APPLICANT_ID',
    LIABILITY_TYPE       VARCHAR(40)             COMMENT 'MORTGAGE | CREDIT_CARD | AUTO_LOAN | PERSONAL_LOAN | STUDENT_LOAN',
    CREDITOR_NAME        VARCHAR(120)            COMMENT 'Institution holding the liability',
    OUTSTANDING_BALANCE  NUMBER(12,2)            COMMENT 'Balance still owed -- feeds "outstanding exposure"',
    MONTHLY_PAYMENT      NUMBER(12,2)            COMMENT 'Contractual monthly payment -- feeds DTI',
    EFFECTIVE_DATE       DATE                    COMMENT 'Date the balance was reported as of',
    SOURCE_SYSTEM        VARCHAR(40)    NOT NULL COMMENT 'BUREAU_EQ (daily) or BUREAU_TU (stalled 42 days ago)',
    LOADED_AT            TIMESTAMP_LTZ  NOT NULL COMMENT 'When this record last landed in Snowflake',
    CONSTRAINT PK_LIABILITIES PRIMARY KEY (LIABILITY_ID)
)
COMMENT = 'Source: BUREAU_EQ + BUREAU_TU. Liabilities behind outstanding exposure. BUREAU_TU is deliberately 42 days stale.';

-- ============================================================================
-- 4. LOAN_SERVICING: repayment history
-- ============================================================================
CREATE OR REPLACE TABLE REPAYMENT_HISTORY (
    PAYMENT_RECORD_ID    VARCHAR(20)    NOT NULL COMMENT 'Surrogate key for the repayment summary',
    APPLICANT_ID         VARCHAR(20)    NOT NULL COMMENT 'FK -> APPLICANTS.APPLICANT_ID',
    MONTHS_REVIEWED      NUMBER(4,0)             COMMENT 'Observation window in months',
    MISSED_PAYMENTS_12M  NUMBER(4,0)             COMMENT 'Count of missed payments in the last 12 months',
    MAX_DAYS_PAST_DUE    NUMBER(5,0)             COMMENT 'Worst delinquency in the window, in days',
    EFFECTIVE_DATE       DATE                    COMMENT 'Date the history was summarised as of',
    SOURCE_SYSTEM        VARCHAR(40)    NOT NULL COMMENT 'Originating system of record',
    LOADED_AT            TIMESTAMP_LTZ  NOT NULL COMMENT 'When this record last landed in Snowflake',
    CONSTRAINT PK_REPAYMENT PRIMARY KEY (PAYMENT_RECORD_ID)
)
COMMENT = 'Source: LOAN_SERVICING. Repayment behaviour summary per applicant.';
