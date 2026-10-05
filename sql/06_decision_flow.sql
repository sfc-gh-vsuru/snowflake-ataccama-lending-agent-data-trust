/* ============================================================================
   06_decision_flow.sql
   ----------------------------------------------------------------------------
   Where the trust signal actually changes the outcome.

   Blog 1's third question was the sharp one: does the trust signal reach the
   agent IN THE FLOW OF THE DECISION, or does it live in a dashboard nobody
   opens until after something has gone wrong?

   This script makes it structural rather than optional. The decision
   procedure cannot reach a credit verdict without first obtaining a trust
   verdict, because the trust check runs before the policy logic and can
   short-circuit it.

   OBJECTS CREATED
   ---------------
     DECISION_AUDIT             append-only record of every decision
     CHECK_APPLICANT_TRUST()    applicant-scoped trust verdict, returns OBJECT
     ASSESS_CREDIT_APPLICATION()  the decision procedure, trust-gated

   WHY APPLICANT-SCOPED AND NOT TABLE-SCOPED
   -----------------------------------------
   A table-level or even feed-level signal tells you the state of a dataset.
   It does not tell you whether THIS applicant's figures are safe to act on.
   APP-10042 draws 97% of their exposure from the stalled feed; another
   applicant on the same table may draw none of it. Fitness for use is a
   property of the decision, not only of the table -- so CHECK_APPLICANT_TRUST
   evaluates the records that this specific decision depends on.
   ============================================================================ */

USE DATABASE ATACCAMA_TRUST_DEMO;
USE SCHEMA GOVERNANCE;

/* ============================================================================
   1. Decision audit
   ----------------------------------------------------------------------------
   Everything an examiner needs to reconstruct a decision: the figures acted
   on, the policy applied, the trust verdict at that moment, and the exact
   source records behind the numbers.
   ============================================================================ */
CREATE OR REPLACE TABLE DECISION_AUDIT (
    DECISION_ID            VARCHAR(60)   NOT NULL COMMENT 'Unique decision identifier',
    APPLICANT_ID           VARCHAR(20)            COMMENT 'Applicant assessed',
    APPLICATION_ID         VARCHAR(20)            COMMENT 'Application assessed',
    DECIDED_AT             TIMESTAMP_LTZ NOT NULL COMMENT 'Moment of decision',
    DECIDED_BY             VARCHAR(80)            COMMENT 'Agent or user that made the call',

    /* ---- the figures the decision was based on ---------------------- */
    GROSS_ANNUAL_INCOME    NUMBER(12,2)           COMMENT 'Income figure used',
    OUTSTANDING_EXPOSURE   NUMBER(12,2)           COMMENT 'Exposure figure used',
    MONTHLY_OBLIGATIONS    NUMBER(12,2)           COMMENT 'Monthly obligations figure used',
    DTI_PCT                NUMBER(7,2)            COMMENT 'Debt-to-income ratio used',
    RISK_TIER              VARCHAR(30)            COMMENT 'Risk tier assigned',
    MISSED_PAYMENTS_12M    NUMBER(4,0)            COMMENT 'Delinquency input used',

    /* ---- the trust verdict at that moment --------------------------- */
    TRUST_VERDICT          VARCHAR(20)            COMMENT 'TRUSTED | NOT_TRUSTED at decision time',
    TRUST_DETAIL           VARIANT                COMMENT 'Full trust evaluation object, retained verbatim',
    WORST_STALENESS_DAYS   NUMBER(10,0)           COMMENT 'Oldest contributing record age at decision time',
    PCT_EXPOSURE_STALE     NUMBER(7,2)            COMMENT 'Share of exposure from stale feeds at decision time',

    /* ---- outcome ---------------------------------------------------- */
    DECISION               VARCHAR(30)            COMMENT 'APPROVE | DECLINE | REFER_TO_HUMAN',
    DECISION_REASON        VARCHAR(1000)          COMMENT 'Why, in terms a reviewer can follow',
    POLICY_VERSION         VARCHAR(20)            COMMENT 'Version of the credit policy applied',

    /* ---- provenance ------------------------------------------------- */
    SOURCE_RECORD_IDS      VARIANT                COMMENT 'Exact source record identifiers behind the figures',
    SOURCE_FEEDS_USED      VARIANT                COMMENT 'Feeds that contributed to the figures',

    CONSTRAINT PK_DECISION_AUDIT PRIMARY KEY (DECISION_ID)
)
COMMENT = 'Append-only credit decision audit. Each row carries the figures used, the trust verdict at that moment, and the source records behind both.';

/* ============================================================================
   2. CHECK_APPLICANT_TRUST -- the trust verdict, as an agent-callable function
   ----------------------------------------------------------------------------
   Returns a structured OBJECT rather than a bare score, so an agent can read
   the verdict, the reason, and the evidence from one call.

   Evaluates, scoped to one applicant:
     TIMELINESS     age of the oldest liability record this applicant depends on
     COMPLETENESS   whether verified income exists for this applicant
     UNIQUENESS     duplicate liability records for this applicant
     ATACCAMA       any Ataccama-published signal for this applicant
                    (placeholder -- contributes nothing until their team writes rows)

   The verdict is NOT_TRUSTED if any BLOCKING signal fails.
   ============================================================================ */
CREATE OR REPLACE FUNCTION CHECK_APPLICANT_TRUST(P_APPLICANT_ID VARCHAR)
RETURNS OBJECT
COMMENT = 'Applicant-scoped trust verdict for automated credit decisioning. Returns verdict, blocking failures, evidence and Ataccama index (when present).'
AS
$$
SELECT OBJECT_CONSTRUCT(
    'applicant_id', P_APPLICANT_ID,
    'evaluated_at', CURRENT_TIMESTAMP()::VARCHAR,

    /* ---- timeliness: oldest record this applicant's exposure rests on ---- */
    'worst_staleness_days', (
        SELECT COALESCE(MAX(DATEDIFF(day, l.LOADED_AT, CURRENT_TIMESTAMP())), 0)
        FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES l
        WHERE l.APPLICANT_ID = P_APPLICANT_ID
    ),
    'stale_feeds', (
        SELECT ARRAY_AGG(DISTINCT l.SOURCE_SYSTEM)
        FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES l
        WHERE l.APPLICANT_ID = P_APPLICANT_ID
          AND DATEDIFF(day, l.LOADED_AT, CURRENT_TIMESTAMP()) >=
              (SELECT FAIL_AT FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.TRUST_THRESHOLDS
               WHERE SIGNAL_NAME = 'LIABILITY_FEED_STALENESS')
    ),
    'pct_exposure_from_stale_feeds', (
        SELECT COALESCE(ROUND(
                 SUM(CASE WHEN DATEDIFF(day, l.LOADED_AT, CURRENT_TIMESTAMP()) >=
                               (SELECT FAIL_AT FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.TRUST_THRESHOLDS
                                WHERE SIGNAL_NAME = 'LIABILITY_FEED_STALENESS')
                          THEN l.OUTSTANDING_BALANCE ELSE 0 END)
                 / NULLIF(SUM(l.OUTSTANDING_BALANCE), 0) * 100, 2), 0)
        FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES l
        WHERE l.APPLICANT_ID = P_APPLICANT_ID
    ),

    /* ---- completeness: is verified income present for this applicant? ---- */
    'income_missing', (
        SELECT COUNT(*) = 0
        FROM ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION i
        WHERE i.APPLICANT_ID = P_APPLICANT_ID
          AND i.GROSS_ANNUAL_INCOME IS NOT NULL
    ),

    /* ---- uniqueness: duplicated liabilities for this applicant ----------- */
    'duplicate_liabilities', (
        SELECT COUNT(*)
        FROM (
            SELECT l.APPLICANT_ID, l.LIABILITY_TYPE, l.OUTSTANDING_BALANCE
            FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES l
            WHERE l.APPLICANT_ID = P_APPLICANT_ID
            GROUP BY 1, 2, 3
            HAVING COUNT(*) > 1
        )
    ),

    /* ---- Ataccama hand-off: null until their team publishes signals ------ */
    'ataccama_trust_index', (
        SELECT MIN(a.DATA_TRUST_INDEX)
        FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.ATACCAMA_TRUST_SIGNALS a
        WHERE a.RECORD_IDENTIFIER = P_APPLICANT_ID
           OR a.SCOPE_OBJECT = 'RAW.LIABILITIES'
    ),
    'ataccama_blocking_failures', (
        SELECT ARRAY_AGG(a.SIGNAL_NAME)
        FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.ATACCAMA_TRUST_SIGNALS a
        WHERE (a.RECORD_IDENTIFIER = P_APPLICANT_ID OR a.SCOPE_OBJECT = 'RAW.LIABILITIES')
          AND a.TRUST_STATUS = 'FAIL'
          AND a.IS_BLOCKING = TRUE
    ),

    /* ---- the verdict ------------------------------------------------------ */
    'blocking_failures', ARRAY_COMPACT(ARRAY_CONSTRUCT(
        CASE WHEN (SELECT COALESCE(MAX(DATEDIFF(day, l.LOADED_AT, CURRENT_TIMESTAMP())), 0)
                   FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES l
                   WHERE l.APPLICANT_ID = P_APPLICANT_ID)
                  >= (SELECT FAIL_AT FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.TRUST_THRESHOLDS
                      WHERE SIGNAL_NAME = 'LIABILITY_FEED_STALENESS')
             THEN 'LIABILITY_FEED_STALENESS' END,
        CASE WHEN (SELECT COUNT(*)
                   FROM ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION i
                   WHERE i.APPLICANT_ID = P_APPLICANT_ID
                     AND i.GROSS_ANNUAL_INCOME IS NOT NULL) = 0
             THEN 'INCOME_COMPLETENESS' END,
        CASE WHEN (SELECT COUNT(*) FROM (
                      SELECT l.LIABILITY_TYPE, l.OUTSTANDING_BALANCE
                      FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES l
                      WHERE l.APPLICANT_ID = P_APPLICANT_ID
                      GROUP BY 1, 2 HAVING COUNT(*) > 1)) > 0
             THEN 'LIABILITY_UNIQUENESS' END
    )),
    'verdict',
        CASE WHEN ARRAY_SIZE(ARRAY_COMPACT(ARRAY_CONSTRUCT(
                CASE WHEN (SELECT COALESCE(MAX(DATEDIFF(day, l.LOADED_AT, CURRENT_TIMESTAMP())), 0)
                           FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES l
                           WHERE l.APPLICANT_ID = P_APPLICANT_ID)
                          >= (SELECT FAIL_AT FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.TRUST_THRESHOLDS
                              WHERE SIGNAL_NAME = 'LIABILITY_FEED_STALENESS')
                     THEN 'X' END,
                CASE WHEN (SELECT COUNT(*)
                           FROM ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION i
                           WHERE i.APPLICANT_ID = P_APPLICANT_ID
                             AND i.GROSS_ANNUAL_INCOME IS NOT NULL) = 0
                     THEN 'X' END,
                CASE WHEN (SELECT COUNT(*) FROM (
                              SELECT l.LIABILITY_TYPE, l.OUTSTANDING_BALANCE
                              FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES l
                              WHERE l.APPLICANT_ID = P_APPLICANT_ID
                              GROUP BY 1, 2 HAVING COUNT(*) > 1)) > 0
                     THEN 'X' END
             ))) > 0
             THEN 'NOT_TRUSTED' ELSE 'TRUSTED'
        END
)
$$;

/* ============================================================================
   3. ASSESS_CREDIT_APPLICATION -- the trust-gated decision procedure
   ----------------------------------------------------------------------------
   Order of operations is the whole point:

     1. read the governed figures from the semantic layer
     2. obtain a trust verdict for THIS applicant
     3. if a blocking trust signal failed -> REFER_TO_HUMAN and stop
     4. only then apply credit policy
     5. record the decision, the figures, the trust verdict and the exact
        source records -- before returning

   Step 3 sits ahead of step 4 deliberately. The agent cannot reach a credit
   verdict on data that failed a blocking trust check, because the policy
   logic is never evaluated in that case.

   CREDIT POLICY v1.0 (applied only once trust passes)
     APPROVE          dti < 40  and missed_payments <= 1
     REFER_TO_HUMAN   dti < 50  and missed_payments <= 2
     DECLINE          otherwise
   ============================================================================ */
CREATE OR REPLACE PROCEDURE ASSESS_CREDIT_APPLICATION(P_APPLICANT_ID VARCHAR, P_DECIDED_BY VARCHAR)
RETURNS OBJECT
LANGUAGE SQL
COMMENT = 'Trust-gated credit assessment. Obtains a trust verdict before applying credit policy, and writes a full audit record including trust state at decision time.'
AS
$$
DECLARE
    v_decision_id      VARCHAR;
    v_trust            OBJECT;
    v_verdict          VARCHAR;
    v_decision         VARCHAR;
    v_reason           VARCHAR;
    v_income           NUMBER(12,2);
    v_exposure         NUMBER(12,2);
    v_monthly          NUMBER(12,2);
    v_dti              NUMBER(7,2);
    v_tier             VARCHAR;
    v_missed           NUMBER(4,0);
    v_stale_days       NUMBER(10,0);
    v_pct_stale        NUMBER(7,2);
    v_result           OBJECT;
BEGIN
    v_decision_id := 'DEC-' || REPLACE(UUID_STRING(), '-', '');

    -- 1. Governed figures from the semantic layer
    SELECT GROSS_ANNUAL_INCOME, OUTSTANDING_EXPOSURE, MONTHLY_OBLIGATIONS,
           DTI_PCT, RISK_TIER, MISSED_PAYMENTS_12M
      INTO v_income, v_exposure, v_monthly, v_dti, v_tier, v_missed
      FROM ATACCAMA_TRUST_DEMO.SEMANTIC.V_APPLICANT_CREDIT_PROFILE
     WHERE APPLICANT_ID = :P_APPLICANT_ID;

    -- 2. Trust verdict for this applicant, before any policy is applied
    v_trust      := ATACCAMA_TRUST_DEMO.GOVERNANCE.CHECK_APPLICANT_TRUST(:P_APPLICANT_ID);
    v_verdict    := GET(:v_trust, 'verdict')::VARCHAR;
    v_stale_days := GET(:v_trust, 'worst_staleness_days')::NUMBER;
    v_pct_stale  := GET(:v_trust, 'pct_exposure_from_stale_feeds')::NUMBER;

    -- 3. Trust gate -- short-circuits before credit policy is evaluated
    IF (v_verdict = 'NOT_TRUSTED') THEN
        v_decision := 'REFER_TO_HUMAN';
        v_reason   := 'Referred without a credit assessment: blocking trust signal(s) '
                   || GET(:v_trust, 'blocking_failures')::VARCHAR
                   || '. Oldest contributing record is ' || :v_stale_days
                   || ' days old and ' || :v_pct_stale
                   || '% of outstanding exposure comes from a failed feed. '
                   || 'Credit policy was not applied.';
    -- 4. Credit policy, reached only when trust passes
    ELSEIF (v_dti < 40 AND COALESCE(v_missed, 0) <= 1) THEN
        v_decision := 'APPROVE';
        v_reason   := 'Approved under policy v1.0: DTI ' || :v_dti
                   || '% below the 40% limit with ' || COALESCE(:v_missed, 0)
                   || ' missed payments. Trust checks passed; oldest contributing record '
                   || :v_stale_days || ' days old.';
    ELSEIF (v_dti < 50 AND COALESCE(v_missed, 0) <= 2) THEN
        v_decision := 'REFER_TO_HUMAN';
        v_reason   := 'Referred under policy v1.0: DTI ' || :v_dti
                   || '% sits in the 40-50% review band. Trust checks passed.';
    ELSE
        v_decision := 'DECLINE';
        v_reason   := 'Declined under policy v1.0: DTI ' || COALESCE(:v_dti, 0)
                   || '% with ' || COALESCE(:v_missed, 0)
                   || ' missed payments exceeds policy limits. Trust checks passed.';
    END IF;

    -- 5a. Audit record, including provenance of every figure used
    INSERT INTO ATACCAMA_TRUST_DEMO.GOVERNANCE.DECISION_AUDIT
        (DECISION_ID, APPLICANT_ID, APPLICATION_ID, DECIDED_AT, DECIDED_BY,
         GROSS_ANNUAL_INCOME, OUTSTANDING_EXPOSURE, MONTHLY_OBLIGATIONS,
         DTI_PCT, RISK_TIER, MISSED_PAYMENTS_12M,
         TRUST_VERDICT, TRUST_DETAIL, WORST_STALENESS_DAYS, PCT_EXPOSURE_STALE,
         DECISION, DECISION_REASON, POLICY_VERSION,
         SOURCE_RECORD_IDS, SOURCE_FEEDS_USED)
    SELECT
        :v_decision_id, :P_APPLICANT_ID, a.APPLICATION_ID,
        CURRENT_TIMESTAMP(), :P_DECIDED_BY,
        :v_income, :v_exposure, :v_monthly, :v_dti, :v_tier, :v_missed,
        :v_verdict, TO_VARIANT(:v_trust), :v_stale_days, :v_pct_stale,
        :v_decision, :v_reason, 'v1.0',
        OBJECT_CONSTRUCT(
            'applicant_record',  a.APPLICANT_ID,
            'income_record',     (SELECT MAX(i.INCOME_RECORD_ID)
                                    FROM ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION i
                                   WHERE i.APPLICANT_ID = :P_APPLICANT_ID),
            'liability_records', (SELECT ARRAY_AGG(l.LIABILITY_ID)
                                    FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES l
                                   WHERE l.APPLICANT_ID = :P_APPLICANT_ID),
            'repayment_record',  (SELECT MAX(r.PAYMENT_RECORD_ID)
                                    FROM ATACCAMA_TRUST_DEMO.RAW.REPAYMENT_HISTORY r
                                   WHERE r.APPLICANT_ID = :P_APPLICANT_ID)
        ),
        (SELECT ARRAY_AGG(DISTINCT l.SOURCE_SYSTEM)
           FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES l
          WHERE l.APPLICANT_ID = :P_APPLICANT_ID)
    FROM ATACCAMA_TRUST_DEMO.RAW.APPLICANTS a
    WHERE a.APPLICANT_ID = :P_APPLICANT_ID;

    -- 5b. Freeze the trust state as it stood at this decision, so the case can
    --     be reconstructed later rather than merely re-derived from today's data
    INSERT INTO ATACCAMA_TRUST_DEMO.GOVERNANCE.TRUST_SIGNAL_SNAPSHOT
        (SNAPSHOT_ID, DECISION_ID, APPLICANT_ID, CAPTURED_AT, SIGNAL_SOURCE,
         SCOPE_OBJECT, FEED_NAME, SIGNAL_NAME, MEASURED_VALUE, TRUST_STATUS,
         IS_BLOCKING, DETAIL)
    SELECT
        'SNAP-' || REPLACE(UUID_STRING(), '-', ''),
        :v_decision_id, :P_APPLICANT_ID, CURRENT_TIMESTAMP(),
        f.SIGNAL_SOURCE, f.SCOPE_OBJECT, f.FEED_NAME, f.SIGNAL_NAME,
        f.MEASURED_VALUE, f.TRUST_STATUS, COALESCE(f.IS_BLOCKING, FALSE), f.DETAIL
    FROM ATACCAMA_TRUST_DEMO.GOVERNANCE.V_UNIFIED_TRUST_SIGNALS f;

    v_result := OBJECT_CONSTRUCT(
        'decision_id',          :v_decision_id,
        'applicant_id',         :P_APPLICANT_ID,
        'decision',             :v_decision,
        'reason',               :v_reason,
        'trust_verdict',        :v_verdict,
        'dti_pct',              :v_dti,
        'risk_tier',            :v_tier,
        'outstanding_exposure', :v_exposure,
        'worst_staleness_days', :v_stale_days,
        'policy_version',       'v1.0'
    );

    RETURN v_result;
END;
$$;
