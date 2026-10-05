/* ============================================================================
   02_load_mock_data.sql
   ----------------------------------------------------------------------------
   Loads the sample data from the data/ folder into the four RAW tables.

   BEFORE RUNNING
     1. sql/00_setup_database.sql   (creates RAW.SEED_STAGE and RAW.SEED_CSV)
     2. sql/01_raw_source_systems.sql (creates the four RAW tables)
     3. Upload the CSVs to the stage:
          snow stage copy "data/*.csv" @ATACCAMA_TRUST_DEMO.RAW.SEED_STAGE -c <conn>
        or in Snowsight: Data > Databases > ATACCAMA_TRUST_DEMO > RAW >
        Stages > SEED_STAGE > + Files.

   WHAT IT DOES
     data/applicants.csv           -> RAW.APPLICANTS            60 rows
     data/income_verification.csv  -> RAW.INCOME_VERIFICATION   60 rows
     data/liabilities.csv          -> RAW.LIABILITIES          166 rows
     data/repayment_history.csv    -> RAW.REPAYMENT_HISTORY     60 rows

     Each file is copied into a holding table (RAW.SEED_*), then inserted into
     the real table with the date offsets turned into real dates:
         LOADED_HOURS_AGO   1008  ->  LOADED_AT       = now minus 42 days
         EFFECTIVE_DAYS_AGO   44  ->  EFFECTIVE_DATE  = today minus 44 days
     This is why the stalled bureau feed is always exactly 42 days behind,
     whenever the demo is built.

   SAFE TO RE-RUN
     The RAW tables are emptied first, so re-running restores the original
     sample data. Unlike re-running 01, it keeps the data quality checks and
     tags attached in 05, and the decision history in GOVERNANCE.

   data/late_arriving_bureau_tu.csv is NOT loaded here -- 09 loads it.
   ============================================================================ */

USE DATABASE ATACCAMA_TRUST_DEMO;
USE SCHEMA RAW;

/* ============================================================================
   1. Holding tables -- one per file, columns exactly as in the CSV
   ============================================================================ */
CREATE OR REPLACE TRANSIENT TABLE SEED_APPLICANTS (
    APPLICANT_ID          VARCHAR(20),
    APPLICATION_ID        VARCHAR(20),
    FULL_NAME             VARCHAR(120),
    EMPLOYMENT_STATUS     VARCHAR(40),
    APPLICATION_DAYS_AGO  NUMBER(5,0),
    REQUESTED_AMOUNT      NUMBER(12,2),
    LOAN_PURPOSE          VARCHAR(40),
    SOURCE_SYSTEM         VARCHAR(40),
    LOADED_HOURS_AGO      NUMBER(6,0)
);

CREATE OR REPLACE TRANSIENT TABLE SEED_INCOME_VERIFICATION (
    INCOME_RECORD_ID     VARCHAR(20),
    APPLICANT_ID         VARCHAR(20),
    GROSS_ANNUAL_INCOME  NUMBER(12,2),
    VERIFICATION_METHOD  VARCHAR(40),
    EFFECTIVE_DAYS_AGO   NUMBER(5,0),
    SOURCE_SYSTEM        VARCHAR(40),
    LOADED_HOURS_AGO     NUMBER(6,0)
);

CREATE OR REPLACE TRANSIENT TABLE SEED_LIABILITIES (
    LIABILITY_ID         VARCHAR(20),
    APPLICANT_ID         VARCHAR(20),
    LIABILITY_TYPE       VARCHAR(40),
    CREDITOR_NAME        VARCHAR(120),
    OUTSTANDING_BALANCE  NUMBER(12,2),
    MONTHLY_PAYMENT      NUMBER(12,2),
    EFFECTIVE_DAYS_AGO   NUMBER(5,0),
    SOURCE_SYSTEM        VARCHAR(40),
    LOADED_HOURS_AGO     NUMBER(6,0)
);

CREATE OR REPLACE TRANSIENT TABLE SEED_REPAYMENT_HISTORY (
    PAYMENT_RECORD_ID    VARCHAR(20),
    APPLICANT_ID         VARCHAR(20),
    MONTHS_REVIEWED      NUMBER(4,0),
    MISSED_PAYMENTS_12M  NUMBER(4,0),
    MAX_DAYS_PAST_DUE    NUMBER(5,0),
    EFFECTIVE_DAYS_AGO   NUMBER(5,0),
    SOURCE_SYSTEM        VARCHAR(40),
    LOADED_HOURS_AGO     NUMBER(6,0)
);

/* ============================================================================
   2. Copy each file from the stage into its holding table
   ============================================================================ */
COPY INTO SEED_APPLICANTS
  FROM @SEED_STAGE/applicants.csv
  FILE_FORMAT = (FORMAT_NAME = 'SEED_CSV')
  ON_ERROR = ABORT_STATEMENT FORCE = TRUE;

COPY INTO SEED_INCOME_VERIFICATION
  FROM @SEED_STAGE/income_verification.csv
  FILE_FORMAT = (FORMAT_NAME = 'SEED_CSV')
  ON_ERROR = ABORT_STATEMENT FORCE = TRUE;

COPY INTO SEED_LIABILITIES
  FROM @SEED_STAGE/liabilities.csv
  FILE_FORMAT = (FORMAT_NAME = 'SEED_CSV')
  ON_ERROR = ABORT_STATEMENT FORCE = TRUE;

COPY INTO SEED_REPAYMENT_HISTORY
  FROM @SEED_STAGE/repayment_history.csv
  FILE_FORMAT = (FORMAT_NAME = 'SEED_CSV')
  ON_ERROR = ABORT_STATEMENT FORCE = TRUE;

/* ============================================================================
   3. Empty the RAW tables, then load them with real dates
   ============================================================================ */
TRUNCATE TABLE APPLICANTS;
TRUNCATE TABLE INCOME_VERIFICATION;
TRUNCATE TABLE LIABILITIES;
TRUNCATE TABLE REPAYMENT_HISTORY;

INSERT INTO APPLICANTS
    (APPLICANT_ID, APPLICATION_ID, FULL_NAME, EMPLOYMENT_STATUS,
     APPLICATION_DATE, REQUESTED_AMOUNT, LOAN_PURPOSE, SOURCE_SYSTEM, LOADED_AT)
SELECT APPLICANT_ID, APPLICATION_ID, FULL_NAME, EMPLOYMENT_STATUS,
       DATEADD(day, -APPLICATION_DAYS_AGO, CURRENT_DATE()),
       REQUESTED_AMOUNT, LOAN_PURPOSE, SOURCE_SYSTEM,
       DATEADD(hour, -LOADED_HOURS_AGO, CURRENT_TIMESTAMP())::TIMESTAMP_LTZ
FROM SEED_APPLICANTS;

INSERT INTO INCOME_VERIFICATION
    (INCOME_RECORD_ID, APPLICANT_ID, GROSS_ANNUAL_INCOME, VERIFICATION_METHOD,
     EFFECTIVE_DATE, SOURCE_SYSTEM, LOADED_AT)
SELECT INCOME_RECORD_ID, APPLICANT_ID, GROSS_ANNUAL_INCOME, VERIFICATION_METHOD,
       DATEADD(day, -EFFECTIVE_DAYS_AGO, CURRENT_DATE()),
       SOURCE_SYSTEM,
       DATEADD(hour, -LOADED_HOURS_AGO, CURRENT_TIMESTAMP())::TIMESTAMP_LTZ
FROM SEED_INCOME_VERIFICATION;

INSERT INTO LIABILITIES
    (LIABILITY_ID, APPLICANT_ID, LIABILITY_TYPE, CREDITOR_NAME,
     OUTSTANDING_BALANCE, MONTHLY_PAYMENT, EFFECTIVE_DATE, SOURCE_SYSTEM, LOADED_AT)
SELECT LIABILITY_ID, APPLICANT_ID, LIABILITY_TYPE, CREDITOR_NAME,
       OUTSTANDING_BALANCE, MONTHLY_PAYMENT,
       DATEADD(day, -EFFECTIVE_DAYS_AGO, CURRENT_DATE()),
       SOURCE_SYSTEM,
       DATEADD(hour, -LOADED_HOURS_AGO, CURRENT_TIMESTAMP())::TIMESTAMP_LTZ
FROM SEED_LIABILITIES;

INSERT INTO REPAYMENT_HISTORY
    (PAYMENT_RECORD_ID, APPLICANT_ID, MONTHS_REVIEWED, MISSED_PAYMENTS_12M,
     MAX_DAYS_PAST_DUE, EFFECTIVE_DATE, SOURCE_SYSTEM, LOADED_AT)
SELECT PAYMENT_RECORD_ID, APPLICANT_ID, MONTHS_REVIEWED, MISSED_PAYMENTS_12M,
       MAX_DAYS_PAST_DUE,
       DATEADD(day, -EFFECTIVE_DAYS_AGO, CURRENT_DATE()),
       SOURCE_SYSTEM,
       DATEADD(hour, -LOADED_HOURS_AGO, CURRENT_TIMESTAMP())::TIMESTAMP_LTZ
FROM SEED_REPAYMENT_HISTORY;

/* ============================================================================
   4. Clean up the holding tables and check the result
   ============================================================================ */
DROP TABLE IF EXISTS SEED_APPLICANTS;
DROP TABLE IF EXISTS SEED_INCOME_VERIFICATION;
DROP TABLE IF EXISTS SEED_LIABILITIES;
DROP TABLE IF EXISTS SEED_REPAYMENT_HISTORY;

-- Expect 60 / 60 / 166 / 60
SELECT 'APPLICANTS' AS table_name, COUNT(*) AS row_count FROM APPLICANTS
UNION ALL SELECT 'INCOME_VERIFICATION', COUNT(*) FROM INCOME_VERIFICATION
UNION ALL SELECT 'LIABILITIES',         COUNT(*) FROM LIABILITIES
UNION ALL SELECT 'REPAYMENT_HISTORY',   COUNT(*) FROM REPAYMENT_HISTORY;
