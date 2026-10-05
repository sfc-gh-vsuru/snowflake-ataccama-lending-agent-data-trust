/* ============================================================================
   08_audit_trail.sql
   ----------------------------------------------------------------------------
   Reconstructing a decision, not re-deriving it.

   Blog 1's first question: "If an agent's recommendation is challenged, can
   compliance trace it back to the exact source record today, and not only
   reconstruct it after the fact?"

   The distinction matters. Re-running today's query tells you what the answer
   WOULD BE NOW. It does not tell you what the agent SAW. If the stalled feed
   has since caught up, today's query returns a different number than the one
   the decision was made on -- and the audit silently disagrees with itself.

   These views read what was RECORDED at decision time:
     V_DECISION_AUDIT_TRAIL    one row per decision, reviewer-readable
     V_DECISION_SOURCE_LINEAGE one row per source record behind each decision
     V_TRUST_AT_DECISION       the trust signals as frozen at decision time
     V_DECISION_DRIFT          where today's figures now differ from the
                               figures the decision was actually made on
   ============================================================================ */

USE DATABASE ATACCAMA_TRUST_DEMO;
USE SCHEMA GOVERNANCE;

/* ============================================================================
   1. Decision audit trail -- the reviewer's starting point
   ============================================================================ */
CREATE OR REPLACE VIEW V_DECISION_AUDIT_TRAIL
COMMENT = 'One row per credit decision with the figures used, the trust verdict at that moment, and why the outcome was reached. The reviewer entry point.'
AS
SELECT
    d.DECISION_ID,
    d.DECIDED_AT,
    d.DECIDED_BY,
    d.APPLICANT_ID,
    d.APPLICATION_ID,
    a.FULL_NAME                                   AS applicant_name,

    /* ---- outcome ----------------------------------------------------- */
    d.DECISION,
    d.TRUST_VERDICT,
    CASE WHEN d.TRUST_VERDICT = 'NOT_TRUSTED'
         THEN 'Trust gate stopped the assessment -- credit policy never ran'
         ELSE 'Credit policy applied to trusted data'
    END                                           AS how_outcome_was_reached,
    d.DECISION_REASON,
    d.POLICY_VERSION,

    /* ---- the figures acted on, as recorded --------------------------- */
    d.GROSS_ANNUAL_INCOME,
    d.OUTSTANDING_EXPOSURE,
    d.MONTHLY_OBLIGATIONS,
    d.DTI_PCT,
    d.RISK_TIER,
    d.MISSED_PAYMENTS_12M,

    /* ---- the trust state at that moment ------------------------------ */
    d.WORST_STALENESS_DAYS,
    d.PCT_EXPOSURE_STALE,
    d.TRUST_DETAIL:blocking_failures::VARCHAR     AS blocking_failures,
    d.TRUST_DETAIL:stale_feeds::VARCHAR           AS stale_feeds_at_decision,

    /* ---- provenance -------------------------------------------------- */
    d.SOURCE_FEEDS_USED,
    d.SOURCE_RECORD_IDS,

    /* ---- the examiner's question: was this defensible? --------------- */
    CASE
        WHEN d.TRUST_VERDICT = 'NOT_TRUSTED' AND d.DECISION = 'REFER_TO_HUMAN'
            THEN 'DEFENSIBLE -- untrusted data was referred, not acted on'
        WHEN d.TRUST_VERDICT = 'NOT_TRUSTED' AND d.DECISION <> 'REFER_TO_HUMAN'
            THEN 'NOT DEFENSIBLE -- an automated outcome was issued on untrusted data'
        WHEN d.WORST_STALENESS_DAYS >= 7
            THEN 'REVIEW -- trust passed but contributing records were older than the freshness threshold'
        ELSE 'DEFENSIBLE -- trusted data, policy applied'
    END                                           AS audit_assessment

FROM DECISION_AUDIT d
LEFT JOIN ATACCAMA_TRUST_DEMO.RAW.APPLICANTS a
       ON a.APPLICANT_ID = d.APPLICANT_ID;

/* ============================================================================
   2. Source lineage -- decision down to the individual record
   ----------------------------------------------------------------------------
   Flattens the recorded liability record IDs and joins back to the source
   rows, so a challenged figure resolves to named records with the feed that
   supplied them. This is the literal answer to "trace it to the exact source
   record".
   ============================================================================ */
CREATE OR REPLACE VIEW V_DECISION_SOURCE_LINEAGE
COMMENT = 'One row per source liability record behind each decision, with the feed that supplied it and how old it was when the decision was made.'
AS
-- The flatten is isolated in a CTE: a LATERAL view cannot sit on the left
-- side of a LEFT JOIN, so it has to be materialised before joining to source.
WITH decision_records AS (
    SELECT
        d.DECISION_ID,
        d.DECIDED_AT,
        d.APPLICANT_ID,
        d.DECISION,
        d.TRUST_VERDICT,
        d.OUTSTANDING_EXPOSURE,
        f.value::VARCHAR AS liability_record_id
    FROM DECISION_AUDIT d,
         LATERAL FLATTEN(input => d.SOURCE_RECORD_IDS:liability_records) f
)
SELECT
    dr.DECISION_ID,
    dr.DECIDED_AT,
    dr.APPLICANT_ID,
    dr.DECISION,
    dr.TRUST_VERDICT,
    dr.liability_record_id,
    l.LIABILITY_TYPE,
    l.CREDITOR_NAME,
    l.OUTSTANDING_BALANCE,
    l.MONTHLY_PAYMENT,
    l.SOURCE_SYSTEM                               AS supplying_feed,
    l.EFFECTIVE_DATE                              AS balance_as_of,
    l.LOADED_AT                                   AS record_loaded_at,
    -- Age of this record at the moment the decision was taken
    DATEDIFF(day, l.LOADED_AT, dr.DECIDED_AT)     AS record_age_days_at_decision,
    -- Did this specific record contribute to the trust failure?
    CASE WHEN DATEDIFF(day, l.LOADED_AT, dr.DECIDED_AT) >= 7
         THEN TRUE ELSE FALSE
    END                                           AS record_breached_freshness,
    ROUND(l.OUTSTANDING_BALANCE
          / NULLIF(dr.OUTSTANDING_EXPOSURE, 0) * 100, 2) AS pct_of_total_exposure

FROM decision_records dr
LEFT JOIN ATACCAMA_TRUST_DEMO.RAW.LIABILITIES l
       ON l.LIABILITY_ID = dr.liability_record_id;

/* ============================================================================
   3. Trust state as frozen at decision time
   ============================================================================ */
CREATE OR REPLACE VIEW V_TRUST_AT_DECISION
COMMENT = 'Trust signals exactly as they stood when each decision was taken, read from the snapshot rather than recomputed from current data.'
AS
SELECT
    s.DECISION_ID,
    s.APPLICANT_ID,
    s.CAPTURED_AT,
    s.SIGNAL_SOURCE,
    s.SCOPE_OBJECT,
    s.FEED_NAME,
    s.SIGNAL_NAME,
    s.MEASURED_VALUE,
    s.TRUST_STATUS,
    s.IS_BLOCKING,
    s.DETAIL,
    d.DECISION,
    d.TRUST_VERDICT
FROM TRUST_SIGNAL_SNAPSHOT s
LEFT JOIN DECISION_AUDIT d
       ON d.DECISION_ID = s.DECISION_ID;

/* ============================================================================
   4. Drift -- where today's answer no longer matches the decision
   ----------------------------------------------------------------------------
   The single most useful view for an examiner, and the one that is impossible
   to build without a point-in-time record. It contrasts the figures the
   decision was MADE on against the figures the same query returns TODAY.

   After the stalled feed catches up (script 09), this view shows the hero
   applicant's exposure and DTI moving, which is the proof that the original
   stale picture was not merely old -- it was wrong.
   ============================================================================ */
CREATE OR REPLACE VIEW V_DECISION_DRIFT
COMMENT = 'Contrasts the figures each decision was made on against the figures the same applicant returns today. Quantifies how wrong a decision made on stale data actually was.'
AS
SELECT
    d.DECISION_ID,
    d.DECIDED_AT,
    d.APPLICANT_ID,
    d.DECISION                                    AS decision_taken,
    d.TRUST_VERDICT                               AS trust_at_decision,

    /* ---- as decided -------------------------------------------------- */
    d.OUTSTANDING_EXPOSURE                        AS exposure_at_decision,
    d.MONTHLY_OBLIGATIONS                         AS obligations_at_decision,
    d.DTI_PCT                                     AS dti_at_decision,
    d.RISK_TIER                                   AS tier_at_decision,

    /* ---- as it stands now -------------------------------------------- */
    p.OUTSTANDING_EXPOSURE                        AS exposure_now,
    p.MONTHLY_OBLIGATIONS                         AS obligations_now,
    p.DTI_PCT                                     AS dti_now,
    p.RISK_TIER                                   AS tier_now,

    /* ---- the gap ----------------------------------------------------- */
    ROUND(p.OUTSTANDING_EXPOSURE - d.OUTSTANDING_EXPOSURE, 2) AS exposure_change,
    ROUND(p.DTI_PCT - d.DTI_PCT, 2)                           AS dti_change,
    CASE WHEN p.RISK_TIER <> d.RISK_TIER THEN TRUE ELSE FALSE END AS tier_changed,
    CASE
        WHEN p.DTI_PCT IS NULL OR d.DTI_PCT IS NULL THEN 'INCOMPARABLE'
        WHEN ABS(p.DTI_PCT - d.DTI_PCT) < 0.01      THEN 'STABLE -- figures unchanged since the decision'
        WHEN p.DTI_PCT > d.DTI_PCT                  THEN 'UNDERSTATED AT DECISION -- the applicant was riskier than the data showed'
        ELSE 'OVERSTATED AT DECISION -- the applicant was safer than the data showed'
    END                                           AS drift_finding

FROM DECISION_AUDIT d
LEFT JOIN ATACCAMA_TRUST_DEMO.SEMANTIC.V_APPLICANT_CREDIT_PROFILE p
       ON p.APPLICANT_ID = d.APPLICANT_ID;
