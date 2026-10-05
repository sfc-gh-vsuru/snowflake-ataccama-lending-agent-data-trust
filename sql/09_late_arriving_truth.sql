/* ============================================================================
   09_late_arriving_truth.sql
   ----------------------------------------------------------------------------
   The stalled feed catches up.

   Everything up to this point shows the trust gate WITHHOLDING a decision.
   That is defensible, but on its own it leaves a fair objection open: maybe
   the stale data was fine, and the gate was just being cautious.

   This script loads the batch the BUREAU_TU feed failed to send --
   data/late_arriving_bureau_tu.csv -- and re-runs the same applicant through
   the same procedure.

   BEFORE RUNNING
     The CSV must be on the stage. If you uploaded data/*.csv in SETUP step 4
     it already is; otherwise:
       snow stage copy data/late_arriving_bureau_tu.csv @ATACCAMA_TRUST_DEMO.RAW.SEED_STAGE -c <conn>

   WHAT THE FEED HAD BEEN HIDING
     In the six weeks the feed was down, APP-10042 took on two new loans:
         AUTO_LOAN       34,500 @   725 / month
         PERSONAL_LOAN   41,000 @ 1,215 / month
     and the mortgage balance fell slightly to 406,800.

     Monthly payments:  3,410 -> 5,350
     Debt-to-income:   31.97% -> 50.16%
     Risk tier:        TIER_2_MODERATE -> TIER_4_HIGH
     Decision:         REFER_TO_HUMAN -> DECLINE

   THE THREE OUTCOMES
       Agent trusting stale data     APPROVE          wrong, and indefensible
       Agent with the trust gate     REFER_TO_HUMAN   correct, and defensible
       Agent once the feed recovers  DECLINE          correct, and final

   SAFE TO RE-RUN. To return to the stale state, re-run 02_load_mock_data.sql.
   ============================================================================ */

USE DATABASE ATACCAMA_TRUST_DEMO;
USE SCHEMA RAW;

/* ============================================================================
   1. The delayed batch finally lands
   ----------------------------------------------------------------------------
   Two things happen when a stalled feed recovers, and both matter:
     a) records it already supplied are refreshed
     b) records it had never supplied appear for the first time
   (b) is the dangerous one. The missing loans were not wrong in the data --
   they were absent from it, which no value-level check can catch.
   ============================================================================ */
CREATE OR REPLACE TRANSIENT TABLE SEED_LATE_ARRIVING (
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

COPY INTO SEED_LATE_ARRIVING
  FROM @SEED_STAGE/late_arriving_bureau_tu.csv
  FILE_FORMAT = (FORMAT_NAME = 'SEED_CSV')
  ON_ERROR = ABORT_STATEMENT FORCE = TRUE;

-- Refresh records the feed already had (a), add the ones it never sent (b)
MERGE INTO LIABILITIES t
USING SEED_LATE_ARRIVING s
   ON t.LIABILITY_ID = s.LIABILITY_ID
WHEN MATCHED THEN UPDATE SET
    OUTSTANDING_BALANCE = s.OUTSTANDING_BALANCE,
    MONTHLY_PAYMENT     = s.MONTHLY_PAYMENT,
    EFFECTIVE_DATE      = DATEADD(day, -s.EFFECTIVE_DAYS_AGO, CURRENT_DATE()),
    LOADED_AT           = DATEADD(hour, -s.LOADED_HOURS_AGO, CURRENT_TIMESTAMP())::TIMESTAMP_LTZ
WHEN NOT MATCHED THEN INSERT
    (LIABILITY_ID, APPLICANT_ID, LIABILITY_TYPE, CREDITOR_NAME,
     OUTSTANDING_BALANCE, MONTHLY_PAYMENT, EFFECTIVE_DATE, SOURCE_SYSTEM, LOADED_AT)
VALUES
    (s.LIABILITY_ID, s.APPLICANT_ID, s.LIABILITY_TYPE, s.CREDITOR_NAME,
     s.OUTSTANDING_BALANCE, s.MONTHLY_PAYMENT,
     DATEADD(day, -s.EFFECTIVE_DAYS_AGO, CURRENT_DATE()),
     s.SOURCE_SYSTEM,
     DATEADD(hour, -s.LOADED_HOURS_AGO, CURRENT_TIMESTAMP())::TIMESTAMP_LTZ);

DROP TABLE IF EXISTS SEED_LATE_ARRIVING;

/* ----------------------------------------------------------------------------
   The rest of the BUREAU_TU feed catches up too, so the feed-level trust
   signal clears and the decision turns on lending policy, not data quality.
   ---------------------------------------------------------------------------- */
UPDATE LIABILITIES
   SET LOADED_AT = DATEADD(hour, -2, CURRENT_TIMESTAMP())::TIMESTAMP_LTZ
 WHERE SOURCE_SYSTEM = 'BUREAU_TU'
   AND DATEDIFF(day, LOADED_AT, CURRENT_TIMESTAMP()) > 7;

/* ============================================================================
   2. Re-run the same applicant through the same procedure
   ============================================================================ */
CALL ATACCAMA_TRUST_DEMO.GOVERNANCE.ASSESS_CREDIT_APPLICATION('APP-10042', 'LENDING_AGENT_V1');

/* ============================================================================
   3. What changed
   ============================================================================ */

-- BUREAU_TU should now read PASS
SELECT FEED_NAME, RECORD_COUNT, STALENESS_DAYS, TRUST_STATUS
FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.V_FEED_TRUST_SIGNALS
WHERE SCOPE_OBJECT = 'RAW.LIABILITIES'
ORDER BY FEED_NAME;

-- Every decision for this applicant, oldest first
SELECT DECIDED_AT, DECISION, TRUST_VERDICT, DTI_PCT, RISK_TIER,
       OUTSTANDING_EXPOSURE, WORST_STALENESS_DAYS, AUDIT_ASSESSMENT
FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.V_DECISION_AUDIT_TRAIL
WHERE APPLICANT_ID = 'APP-10042'
ORDER BY DECIDED_AT;

-- How far each decision's figures were from the complete picture
SELECT DECIDED_AT, decision_taken, trust_at_decision,
       dti_at_decision, dti_now, dti_change,
       exposure_at_decision, exposure_now, exposure_change,
       tier_at_decision, tier_now, drift_finding
FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.V_DECISION_DRIFT
WHERE APPLICANT_ID = 'APP-10042'
ORDER BY DECIDED_AT;
