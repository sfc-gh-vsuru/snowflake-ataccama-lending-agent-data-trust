/* ============================================================================
   data/generate_mock_data.sql
   ----------------------------------------------------------------------------
   OPTIONAL. Regenerates the CSV files in this folder.

   You do not need this to run the demo -- the CSVs are already in data/.
   It is here so the sample data is reproducible and can be changed: edit the
   formulas, run this script, download the files, and commit them.

   HOW TO USE
     1. Run sql/00_setup_database.sql (creates the stage this writes to).
     2. Run this script:
          snow sql -c <conn> -f data/generate_mock_data.sql
     3. Download the files into data/:
          snow stage copy @ATACCAMA_TRUST_DEMO.RAW.SEED_STAGE/export/ data/ -c <conn>

   WHY OFFSETS INSTEAD OF DATES
     Every date is written as "days ago" or "hours ago". If the files held
     calendar dates, a demo built a month later would show every source as
     stale. sql/02_load_mock_data.sql turns the offsets into real dates at load
     time, so the stalled bureau feed is always exactly 42 days behind.

   DETERMINISTIC
     Values come from SEQ4() arithmetic, not RANDOM(), so re-running this
     produces identical files.

   WHAT IS PLANTED ON PURPOSE
     - BUREAU_TU feed last loaded 42 days ago (1,008 hours); BUREAU_EQ is current
     - Hero applicant APP-10042 (Marcus Webb): DTI 31.97% on the stale picture
     - NULL income for APP-10023 and APP-10051            (completeness)
     - invalid employment status 'F/T' for APP-10017/38   (validity)
     - duplicate liability LIA-79901 (copy of LIA-70001)  (uniqueness)
     - orphan liability LIA-79902 -> APP-99999            (integrity)
   ============================================================================ */

USE DATABASE ATACCAMA_TRUST_DEMO;
USE SCHEMA RAW;

/* ============================================================================
   1. applicants.csv -- CORE_BANKING
   ============================================================================ */
COPY INTO @SEED_STAGE/export/applicants.csv
FROM (
    WITH seq AS (SELECT SEQ4() + 1 AS i FROM TABLE(GENERATOR(ROWCOUNT => 60))),
    rows_ AS (
        SELECT
            'APP-' || TO_VARCHAR(10000 + i)                                  AS APPLICANT_ID,
            'LN-'  || TO_VARCHAR(90000 + i)                                  AS APPLICATION_ID,
            ARRAY_CONSTRUCT('Alice','Brian','Chloe','Daniel','Elena','Farid','Grace',
                            'Hiro','Imani','Jonas','Katya','Liam')[MOD(i * 7, 12)]::VARCHAR
              || ' ' ||
            ARRAY_CONSTRUCT('Abara','Bennett','Costa','Duarte','Ellis','Fontaine',
                            'Grant','Haddad','Iqbal','Jensen')[MOD(i * 3, 10)]::VARCHAR
                                                                             AS FULL_NAME,
            CASE WHEN i IN (17, 38) THEN 'F/T'
                 ELSE ARRAY_CONSTRUCT('FULL_TIME','PART_TIME','SELF_EMPLOYED','CONTRACT')
                          [MOD(i * 5, 4)]::VARCHAR
            END                                                              AS EMPLOYMENT_STATUS,
            MOD(i, 14)                                                       AS APPLICATION_DAYS_AGO,
            (15000 + MOD(i * 7919, 86) * 1000)::NUMBER(12,2)                 AS REQUESTED_AMOUNT,
            ARRAY_CONSTRUCT('MORTGAGE','REFINANCE','PERSONAL','AUTO')[MOD(i * 11, 4)]::VARCHAR
                                                                             AS LOAN_PURPOSE,
            'CORE_BANKING'                                                   AS SOURCE_SYSTEM,
            MOD(i, 6)                                                        AS LOADED_HOURS_AGO
        FROM seq
        WHERE i <> 42
        UNION ALL
        -- Hero applicant
        SELECT 'APP-10042', 'LN-90042', 'Marcus Webb', 'FULL_TIME',
               2, 45000.00, 'PERSONAL', 'CORE_BANKING', 3
    )
    SELECT * FROM rows_ ORDER BY APPLICANT_ID
)
FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('') COMPRESSION = NONE)
HEADER = TRUE SINGLE = TRUE OVERWRITE = TRUE MAX_FILE_SIZE = 50000000;

/* ============================================================================
   2. income_verification.csv -- PAYROLL_VERIFY
   ============================================================================ */
COPY INTO @SEED_STAGE/export/income_verification.csv
FROM (
    WITH seq AS (SELECT SEQ4() + 1 AS i FROM TABLE(GENERATOR(ROWCOUNT => 60))),
    rows_ AS (
        SELECT
            'INC-' || TO_VARCHAR(50000 + i)                  AS INCOME_RECORD_ID,
            'APP-' || TO_VARCHAR(10000 + i)                  AS APPLICANT_ID,
            CASE WHEN i IN (23, 51) THEN NULL
                 ELSE (52000 + MOD(i * 6421, 120) * 1000)::NUMBER(12,2)
            END                                              AS GROSS_ANNUAL_INCOME,
            ARRAY_CONSTRUCT('PAYROLL_FEED','TAX_RETURN','BANK_STATEMENT')
                [MOD(i * 5, 3)]::VARCHAR                     AS VERIFICATION_METHOD,
            MOD(i, 21)                                       AS EFFECTIVE_DAYS_AGO,
            'PAYROLL_VERIFY'                                 AS SOURCE_SYSTEM,
            MOD(i, 9)                                        AS LOADED_HOURS_AGO
        FROM seq
        WHERE i <> 42
        UNION ALL
        -- Hero income: 128,000 verified against a payroll feed
        SELECT 'INC-50042', 'APP-10042', 128000.00, 'PAYROLL_FEED', 4, 'PAYROLL_VERIFY', 5
    )
    SELECT * FROM rows_ ORDER BY INCOME_RECORD_ID
)
FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('') COMPRESSION = NONE)
HEADER = TRUE SINGLE = TRUE OVERWRITE = TRUE MAX_FILE_SIZE = 50000000;

/* ============================================================================
   3. liabilities.csv -- BUREAU_EQ (current) + BUREAU_TU (stalled 42 days)
   ----------------------------------------------------------------------------
   Generated rows use LIA-70001..70180. Hero rows use LIA-80xxx so they cannot
   collide -- Snowflake does not enforce primary keys, and a collision would
   silently double-count exposure.
   ============================================================================ */
COPY INTO @SEED_STAGE/export/liabilities.csv
FROM (
    WITH grid AS (
        SELECT MOD(SEQ4(), 60) + 1 AS applicant_idx,
               FLOOR(SEQ4() / 60)  AS slot,
               SEQ4() + 1          AS i
        FROM TABLE(GENERATOR(ROWCOUNT => 180))
    ),
    typed AS (
        SELECT applicant_idx, slot, i,
               ARRAY_CONSTRUCT('MORTGAGE','CREDIT_CARD','AUTO_LOAN',
                               'PERSONAL_LOAN','STUDENT_LOAN')[MOD(i * 13, 5)]::VARCHAR AS liability_type,
               -- every third row comes from the stalled TU feed
               CASE WHEN MOD(i, 3) = 0 THEN 'BUREAU_TU' ELSE 'BUREAU_EQ' END            AS source_system
        FROM grid
        WHERE applicant_idx <> 42
          AND NOT (slot = 2 AND MOD(applicant_idx, 4) = 0)   -- 2 or 3 debts per applicant
    ),
    generated AS (
        SELECT
            'LIA-' || TO_VARCHAR(70000 + i)              AS LIABILITY_ID,
            'APP-' || TO_VARCHAR(10000 + applicant_idx)  AS APPLICANT_ID,
            liability_type                               AS LIABILITY_TYPE,
            ARRAY_CONSTRUCT('Northwind Bank','Harbour Credit Union','Meridian Finance',
                            'Calder Trust','Ardent Lending')[MOD(i * 7, 5)]::VARCHAR AS CREDITOR_NAME,
            balance                                      AS OUTSTANDING_BALANCE,
            ROUND(balance * CASE liability_type
                                WHEN 'MORTGAGE'      THEN 0.0062
                                WHEN 'CREDIT_CARD'   THEN 0.0350
                                WHEN 'AUTO_LOAN'     THEN 0.0210
                                WHEN 'PERSONAL_LOAN' THEN 0.0280
                                ELSE                      0.0110
                            END, 2)                      AS MONTHLY_PAYMENT,
            CASE WHEN source_system = 'BUREAU_TU' THEN 42 + MOD(i, 5)
                 ELSE MOD(i, 7) END                      AS EFFECTIVE_DAYS_AGO,
            source_system                                AS SOURCE_SYSTEM,
            CASE WHEN source_system = 'BUREAU_TU' THEN 42 * 24     -- stalled
                 ELSE MOD(i, 20) END                     AS LOADED_HOURS_AGO
        FROM (
            SELECT t.*,
                   (CASE liability_type
                        WHEN 'MORTGAGE'      THEN 180000 + MOD(i * 4523, 340) * 1000
                        WHEN 'CREDIT_CARD'   THEN    500 + MOD(i * 2711,  18) * 1000
                        WHEN 'AUTO_LOAN'     THEN   6000 + MOD(i * 3137,  42) * 1000
                        WHEN 'PERSONAL_LOAN' THEN   2000 + MOD(i * 1949,  33) * 1000
                        ELSE                        5000 + MOD(i * 5281,  85) * 1000
                    END)::NUMBER(12,2) AS balance
            FROM typed t
        )
    ),
    rows_ AS (
        SELECT * FROM generated
        UNION ALL
        -- Hero: mortgage from the stalled TU feed, card from the current EQ feed.
        -- 2,950 + 460 = 3,410 / month -> 3,410 x 12 / 128,000 = 31.97% DTI
        SELECT 'LIA-80042', 'APP-10042', 'MORTGAGE', 'Northwind Bank',
               410000.00, 2950.00, 44, 'BUREAU_TU', 42 * 24
        UNION ALL
        SELECT 'LIA-80043', 'APP-10042', 'CREDIT_CARD', 'Harbour Credit Union',
               11500.00, 460.00, 1, 'BUREAU_EQ', 6
        UNION ALL
        -- Duplicate: same content as LIA-70001 under a new ID (uniqueness defect)
        SELECT 'LIA-79901', APPLICANT_ID, LIABILITY_TYPE, CREDITOR_NAME,
               OUTSTANDING_BALANCE, MONTHLY_PAYMENT, EFFECTIVE_DAYS_AGO,
               SOURCE_SYSTEM, LOADED_HOURS_AGO
        FROM generated WHERE LIABILITY_ID = 'LIA-70001'
        UNION ALL
        -- Orphan: points at an applicant that does not exist (integrity defect)
        SELECT 'LIA-79902', 'APP-99999', 'PERSONAL_LOAN', 'Ardent Lending',
               18000.00, 504.00, 3, 'BUREAU_EQ', 8
    )
    SELECT * FROM rows_ ORDER BY LIABILITY_ID
)
FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('') COMPRESSION = NONE)
HEADER = TRUE SINGLE = TRUE OVERWRITE = TRUE MAX_FILE_SIZE = 50000000;

/* ============================================================================
   4. repayment_history.csv -- LOAN_SERVICING
   ============================================================================ */
COPY INTO @SEED_STAGE/export/repayment_history.csv
FROM (
    WITH seq AS (SELECT SEQ4() + 1 AS i FROM TABLE(GENERATOR(ROWCOUNT => 60))),
    rows_ AS (
        SELECT
            'PAY-' || TO_VARCHAR(30000 + i)  AS PAYMENT_RECORD_ID,
            'APP-' || TO_VARCHAR(10000 + i)  AS APPLICANT_ID,
            24                               AS MONTHS_REVIEWED,
            MOD(i * 3, 4)                    AS MISSED_PAYMENTS_12M,
            MOD(i * 17, 5) * 15              AS MAX_DAYS_PAST_DUE,
            MOD(i, 10)                       AS EFFECTIVE_DAYS_AGO,
            'LOAN_SERVICING'                 AS SOURCE_SYSTEM,
            MOD(i, 12)                       AS LOADED_HOURS_AGO
        FROM seq
        WHERE i <> 42
        UNION ALL
        -- Hero: a clean record, which is what makes the case tempting
        SELECT 'PAY-30042', 'APP-10042', 24, 0, 0, 2, 'LOAN_SERVICING', 7
    )
    SELECT * FROM rows_ ORDER BY PAYMENT_RECORD_ID
)
FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('') COMPRESSION = NONE)
HEADER = TRUE SINGLE = TRUE OVERWRITE = TRUE MAX_FILE_SIZE = 50000000;

/* ============================================================================
   5. late_arriving_bureau_tu.csv -- the batch the stalled feed failed to send
   ----------------------------------------------------------------------------
   Loaded only by sql/09_late_arriving_truth.sql. Contains the refreshed hero
   mortgage plus the two loans taken out during the outage:
       2,950 + 460 + 725 + 1,215 = 5,350 / month -> 50.16% DTI
   ============================================================================ */
COPY INTO @SEED_STAGE/export/late_arriving_bureau_tu.csv
FROM (
    SELECT * FROM (
        SELECT 'LIA-80042' AS LIABILITY_ID, 'APP-10042' AS APPLICANT_ID,
               'MORTGAGE' AS LIABILITY_TYPE, 'Northwind Bank' AS CREDITOR_NAME,
               406800.00::NUMBER(12,2) AS OUTSTANDING_BALANCE,
               2950.00::NUMBER(12,2)   AS MONTHLY_PAYMENT,
               1 AS EFFECTIVE_DAYS_AGO, 'BUREAU_TU' AS SOURCE_SYSTEM, 2 AS LOADED_HOURS_AGO
        UNION ALL
        SELECT 'LIA-80044', 'APP-10042', 'AUTO_LOAN', 'Meridian Finance',
               34500.00, 725.00, 1, 'BUREAU_TU', 2
        UNION ALL
        SELECT 'LIA-80045', 'APP-10042', 'PERSONAL_LOAN', 'Ardent Lending',
               41000.00, 1215.00, 1, 'BUREAU_TU', 2
    ) ORDER BY LIABILITY_ID
)
FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('') COMPRESSION = NONE)
HEADER = TRUE SINGLE = TRUE OVERWRITE = TRUE MAX_FILE_SIZE = 50000000;

LIST @SEED_STAGE/export/;
