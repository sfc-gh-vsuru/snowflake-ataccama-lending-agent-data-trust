/* ============================================================================
   05_trust_signals.sql
   ----------------------------------------------------------------------------
   The trust layer: whether the numbers can be USED.

   Blog 1 ended on three questions. This script builds the Snowflake-native
   answer to questions 2 and 3 -- a measurable, current trust signal that
   reaches the agent in the flow of the decision rather than sitting in a
   dashboard nobody opens.

   WHAT THIS SCRIPT CREATES
   ------------------------
     Custom DMFs            LAGGING_RECORD_COUNT, INVALID_EMPLOYMENT_STATUS_COUNT
     DMF attachments        six checks bound to the three source tables
     TRUST_THRESHOLDS       governed limits, owned by data governance not by code
     V_FEED_TRUST_SIGNALS   live per-feed trust evaluation
     ATACCAMA_TRUST_SIGNALS *** PLACEHOLDER *** -- the Ataccama hand-off contract
     V_UNIFIED_TRUST_SIGNALS  single surface the agent reads
     TRUST_SIGNAL_SNAPSHOT  append-only record of trust state at decision time

   ============================================================================
   A VERIFIED FINDING THAT SHAPES THIS DESIGN
   ============================================================================
   Two things we proved on the demo account, both of which constrain what
   native DMFs alone can do:

   1. TABLE-LEVEL FRESHNESS CAN BE GREEN WHILE A FEED IS STALE.
         SNOWFLAKE.CORE.FRESHNESS on LIABILITIES.LOADED_AT  ->   66 seconds
         GOVERNANCE.LAGGING_RECORD_COUNT on the same column  ->   53 records
      MAX(LOADED_AT) is driven by the still-current BUREAU_EQ feed, so the
      stalled BUREAU_TU feed is invisible to the built-in check. Same table,
      same column, two DMFs: one green, one red.

   2. A CUSTOM DMF CANNOT MEASURE "HOW OLD IS THIS, RIGHT NOW".
      DMF bodies must be deterministic; CURRENT_TIMESTAMP is rejected:
         "Data metric function body cannot refer to the non-deterministic
          function 'CURRENT_TIMESTAMP'."
      So LAGGING_RECORD_COUNT measures staleness RELATIVE to the table's own
      newest load (deterministic, and sufficient to expose a stalled feed),
      while absolute wall-clock staleness is computed in the views below.

   Together these are the honest technical case for a dedicated trust layer:
   native DMFs give you scheduled, governed, in-database checks, but the
   grain and time-awareness of a real trust signal has to be built on top.
   ============================================================================ */

USE DATABASE ATACCAMA_TRUST_DEMO;
USE SCHEMA GOVERNANCE;

/* ============================================================================
   1. Custom Data Metric Functions
   ============================================================================ */

-- Detects a stalled feed that table-level FRESHNESS masks.
-- Deterministic by design: compares each record against the table's own
-- newest load rather than against wall-clock time.
CREATE OR REPLACE DATA METRIC FUNCTION LAGGING_RECORD_COUNT(
    arg_t TABLE(loaded_at TIMESTAMP_LTZ)
)
RETURNS NUMBER
COMMENT = 'Count of records whose load time lags the tables newest load by more than 7 days. Deterministic (no CURRENT_TIMESTAMP), so valid in a DMF body, and it detects a stalled feed that table-level FRESHNESS masks.'
AS
$$
    SELECT COUNT(*)
    FROM arg_t
    WHERE loaded_at < DATEADD(day, -7, (SELECT MAX(loaded_at) FROM arg_t))
$$;

-- Validity: accepted-value domain encoded in the rule.
-- (SNOWFLAKE.CORE.ACCEPTED_VALUES returns -1 until an expectation set is
--  configured, so a custom rule is clearer for the demo.)
CREATE OR REPLACE DATA METRIC FUNCTION INVALID_EMPLOYMENT_STATUS_COUNT(
    arg_t TABLE(employment_status VARCHAR)
)
RETURNS NUMBER
COMMENT = 'Count of employment status values outside the approved domain. Validity check with the accepted set encoded in the rule.'
AS
$$
    SELECT COUNT(*)
    FROM arg_t
    WHERE employment_status IS NULL
       OR employment_status NOT IN ('FULL_TIME', 'PART_TIME', 'SELF_EMPLOYED', 'CONTRACT')
$$;

/* ============================================================================
   2. Attach the checks to the source tables
   ----------------------------------------------------------------------------
   Hourly schedule. In production this would be tuned per feed SLA, or set to
   TRIGGER_ON_CHANGES for tables that load irregularly.
   ============================================================================ */
ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.LIABILITIES
  SET DATA_METRIC_SCHEDULE = 'USING CRON 0 * * * * UTC';
ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.LIABILITIES
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (LOADED_AT);
ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.LIABILITIES
  ADD DATA METRIC FUNCTION LAGGING_RECORD_COUNT ON (LOADED_AT);
ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.LIABILITIES
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (LIABILITY_ID);

ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION
  SET DATA_METRIC_SCHEDULE = 'USING CRON 0 * * * * UTC';
ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (GROSS_ANNUAL_INCOME);
ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (LOADED_AT);

ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.APPLICANTS
  SET DATA_METRIC_SCHEDULE = 'USING CRON 0 * * * * UTC';
ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.APPLICANTS
  ADD DATA METRIC FUNCTION INVALID_EMPLOYMENT_STATUS_COUNT ON (EMPLOYMENT_STATUS);

/* ============================================================================
   3. Governed thresholds
   ----------------------------------------------------------------------------
   Thresholds live in a table, not in application code, so governance can
   change the bar without a release. IS_BLOCKING marks the signals that must
   stop an automated decision rather than merely annotate it.
   ============================================================================ */
CREATE OR REPLACE TABLE TRUST_THRESHOLDS (
    SIGNAL_NAME       VARCHAR(80)   NOT NULL COMMENT 'Trust signal identifier',
    SIGNAL_DIMENSION  VARCHAR(40)   NOT NULL COMMENT 'TIMELINESS | COMPLETENESS | VALIDITY | UNIQUENESS | INTEGRITY',
    SCOPE_OBJECT      VARCHAR(200)           COMMENT 'Object the signal applies to',
    WARN_AT           NUMBER(12,2)           COMMENT 'Value at or above which the signal warns',
    FAIL_AT           NUMBER(12,2)           COMMENT 'Value at or above which the signal fails',
    UNIT              VARCHAR(40)            COMMENT 'Unit of the measured value',
    IS_BLOCKING       BOOLEAN       NOT NULL COMMENT 'TRUE = a failure must stop automated decisioning',
    OWNER_TEAM        VARCHAR(80)            COMMENT 'Accountable team',
    RATIONALE         VARCHAR(400)           COMMENT 'Why this threshold is set where it is',
    CONSTRAINT PK_TRUST_THRESHOLDS PRIMARY KEY (SIGNAL_NAME)
)
COMMENT = 'Governed trust thresholds. Owned by data governance, read by the decision flow at runtime.';

INSERT INTO TRUST_THRESHOLDS
    (SIGNAL_NAME, SIGNAL_DIMENSION, SCOPE_OBJECT, WARN_AT, FAIL_AT, UNIT, IS_BLOCKING, OWNER_TEAM, RATIONALE)
SELECT 'LIABILITY_FEED_STALENESS', 'TIMELINESS', 'RAW.LIABILITIES', 3, 7, 'days', TRUE,
       'Credit Risk Data', 'Bureau feeds contract to a daily refresh. Past seven days a material new liability could be missing entirely, which understates exposure.'
UNION ALL
SELECT 'INCOME_COMPLETENESS', 'COMPLETENESS', 'RAW.INCOME_VERIFICATION', 1, 1, 'null records', TRUE,
       'Credit Risk Data', 'DTI is undefined without verified income. A single missing value invalidates the ratio for that applicant.'
UNION ALL
SELECT 'LIABILITY_UNIQUENESS', 'UNIQUENESS', 'RAW.LIABILITIES', 1, 1, 'duplicate records', TRUE,
       'Credit Risk Data', 'A duplicated liability double-counts exposure and overstates DTI, producing a wrongly declined applicant.'
UNION ALL
SELECT 'EMPLOYMENT_STATUS_VALIDITY', 'VALIDITY', 'RAW.APPLICANTS', 1, 3, 'invalid values', FALSE,
       'Onboarding Data', 'Affects segmentation and reporting but does not enter the DTI calculation, so it annotates rather than blocks.'
UNION ALL
SELECT 'LIABILITY_REFERENTIAL_INTEGRITY', 'INTEGRITY', 'RAW.LIABILITIES', 1, 1, 'orphan records', FALSE,
       'Credit Risk Data', 'An orphan liability cannot be attributed to an applicant, so it distorts portfolio totals without affecting a named decision.'
UNION ALL
-- Timeliness thresholds for the remaining feeds. A feed with no row here is
-- reported as UNGOVERNED rather than PASS -- see the view below.
SELECT 'INCOME_FEED_STALENESS', 'TIMELINESS', 'RAW.INCOME_VERIFICATION', 7, 14, 'days', TRUE,
       'Credit Risk Data', 'Payroll verification refreshes weekly. Beyond fourteen days an income figure may predate a job change.'
UNION ALL
SELECT 'APPLICANT_FEED_STALENESS', 'TIMELINESS', 'RAW.APPLICANTS', 2, 5, 'days', FALSE,
       'Onboarding Data', 'Application records are written at submission and rarely change, so staleness here is informational.'
UNION ALL
SELECT 'REPAYMENT_FEED_STALENESS', 'TIMELINESS', 'RAW.REPAYMENT_HISTORY', 7, 14, 'days', TRUE,
       'Credit Risk Data', 'Servicing data drives the delinquency inputs to risk tier, so a stale window can hide a recent missed payment.';

/* ============================================================================
   4. Live trust evaluation, at feed grain
   ----------------------------------------------------------------------------
   This is where absolute, wall-clock staleness is computed -- the thing a DMF
   body is not allowed to do. One row per source feed per table.
   ============================================================================ */
CREATE OR REPLACE VIEW V_FEED_TRUST_SIGNALS
COMMENT = 'Live per-feed trust evaluation for the lending source systems. Computes absolute staleness and grades it against the governed thresholds.'
AS
WITH feed_loads AS (
    SELECT 'RAW.LIABILITIES'         AS scope_object, SOURCE_SYSTEM AS feed_name,
           COUNT(*) AS record_count, MAX(LOADED_AT) AS last_loaded_at
    FROM ATACCAMA_TRUST_DEMO.RAW.LIABILITIES          GROUP BY SOURCE_SYSTEM
    UNION ALL
    SELECT 'RAW.INCOME_VERIFICATION', SOURCE_SYSTEM, COUNT(*), MAX(LOADED_AT)
    FROM ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION  GROUP BY SOURCE_SYSTEM
    UNION ALL
    SELECT 'RAW.APPLICANTS', SOURCE_SYSTEM, COUNT(*), MAX(LOADED_AT)
    FROM ATACCAMA_TRUST_DEMO.RAW.APPLICANTS           GROUP BY SOURCE_SYSTEM
    UNION ALL
    SELECT 'RAW.REPAYMENT_HISTORY', SOURCE_SYSTEM, COUNT(*), MAX(LOADED_AT)
    FROM ATACCAMA_TRUST_DEMO.RAW.REPAYMENT_HISTORY    GROUP BY SOURCE_SYSTEM
)
SELECT
    f.scope_object,
    f.feed_name,
    f.record_count,
    f.last_loaded_at,
    DATEDIFF(day,  f.last_loaded_at, CURRENT_TIMESTAMP()) AS staleness_days,
    DATEDIFF(hour, f.last_loaded_at, CURRENT_TIMESTAMP()) AS staleness_hours,
    t.SIGNAL_NAME,
    t.WARN_AT,
    t.FAIL_AT,
    t.IS_BLOCKING,
    t.OWNER_TEAM,
    -- A feed with no governed threshold is NOT passing -- it is unassessed.
    -- Reporting that honestly keeps a governance gap visible instead of
    -- letting a missing threshold read as a green light.
    CASE
        WHEN t.SIGNAL_NAME IS NULL                                            THEN 'UNGOVERNED'
        WHEN DATEDIFF(day, f.last_loaded_at, CURRENT_TIMESTAMP()) >= t.FAIL_AT THEN 'FAIL'
        WHEN DATEDIFF(day, f.last_loaded_at, CURRENT_TIMESTAMP()) >= t.WARN_AT THEN 'WARN'
        ELSE 'PASS'
    END                                                   AS trust_status,
    'SNOWFLAKE_NATIVE'                                    AS signal_source
FROM feed_loads f
LEFT JOIN TRUST_THRESHOLDS t
       ON t.SCOPE_OBJECT     = f.scope_object
      AND t.SIGNAL_DIMENSION = 'TIMELINESS';

/* ============================================================================
   5. *** ATACCAMA HAND-OFF -- PLACEHOLDER ***
   ============================================================================
   This table is the CONTRACT between the two halves of the demo. Snowflake
   populates nothing here; Ataccama's team owns everything that lands in it.

   The table is intentionally created EMPTY. Every downstream object below
   LEFT JOINs to it, so the Snowflake side runs end to end on native signals
   alone -- and the moment Ataccama starts writing rows, their signals appear
   in the agent's decision with no change to the agent, the semantic view, or
   the decision procedure.

   WHAT ATACCAMA IS EXPECTED TO SUPPLY
   -----------------------------------
     DATA_TRUST_INDEX      the composite 0-100 score referenced in blog 1
     RULE_NAME / RESULT    individual DQ rule outcomes (their rules can execute
                           as Snowflake DMFs, so results can land natively)
     RECORD_IDENTIFIER     record-level traceability -- which row failed, so a
                           challenged decision traces to an exact source record
     DRIFT / ANOMALY flags profiling signals Snowflake-native checks do not cover
     EVALUATED_AT          when the assessment was made, for point-in-time audit

   OPEN QUESTIONS FOR THE ATACCAMA TEAM (to confirm before publication)
     - Exact field names and types in their published output
     - Whether the Data Trust Index is delivered per table, per feed, per
       record, or all three
     - Whether signals arrive by DMF result, direct table write, or MCP call
     - Their recommended blocking threshold on the index for credit decisions
   ============================================================================ */
CREATE OR REPLACE TABLE ATACCAMA_TRUST_SIGNALS (
    SIGNAL_ID          VARCHAR(60)   NOT NULL COMMENT 'Unique identifier for this assessment',
    SCOPE_OBJECT       VARCHAR(200)           COMMENT 'Object assessed, e.g. RAW.LIABILITIES',
    FEED_NAME          VARCHAR(80)            COMMENT 'Source feed assessed, where applicable',
    RECORD_IDENTIFIER  VARCHAR(200)           COMMENT 'Record-level traceability: the specific row assessed',
    SIGNAL_NAME        VARCHAR(80)            COMMENT 'Ataccama rule or signal name',
    SIGNAL_DIMENSION   VARCHAR(40)            COMMENT 'TIMELINESS | COMPLETENESS | ACCURACY | CONSISTENCY | DRIFT',
    MEASURED_VALUE     NUMBER(14,4)           COMMENT 'Measured value for the rule',
    DATA_TRUST_INDEX   NUMBER(5,2)            COMMENT 'Composite Ataccama Data Trust Index, 0-100',
    TRUST_STATUS       VARCHAR(20)            COMMENT 'PASS | WARN | FAIL as graded by Ataccama',
    IS_BLOCKING        BOOLEAN                COMMENT 'TRUE = must stop automated decisioning',
    EVALUATED_AT       TIMESTAMP_LTZ          COMMENT 'When Ataccama made this assessment',
    DETAIL             VARCHAR(1000)          COMMENT 'Human-readable explanation for the audit trail',
    CONSTRAINT PK_ATACCAMA_TRUST_SIGNALS PRIMARY KEY (SIGNAL_ID)
)
COMMENT = 'PLACEHOLDER / HAND-OFF: schema for Ataccama-published trust signals. Created empty and owned by the Ataccama team. Downstream views LEFT JOIN so the Snowflake side works standalone.';

/* ============================================================================
   6. Unified trust surface
   ----------------------------------------------------------------------------
   The agent reads THIS and nothing else. Native signals and Ataccama signals
   arrive in one shape, so adding the Ataccama half changes no consumer.
   ============================================================================ */
CREATE OR REPLACE VIEW V_UNIFIED_TRUST_SIGNALS
COMMENT = 'Single trust surface consumed by the lending agent. Unions Snowflake-native feed signals with Ataccama-published signals so either side can evolve independently.'
AS
SELECT
    SIGNAL_SOURCE                                AS signal_source,
    SCOPE_OBJECT                                 AS scope_object,
    FEED_NAME                                    AS feed_name,
    NULL                                         AS record_identifier,
    COALESCE(SIGNAL_NAME, 'LIABILITY_FEED_STALENESS') AS signal_name,
    'TIMELINESS'                                 AS signal_dimension,
    STALENESS_DAYS::NUMBER(14,4)                 AS measured_value,
    'days'                                       AS unit,
    NULL                                         AS data_trust_index,
    TRUST_STATUS                                 AS trust_status,
    COALESCE(IS_BLOCKING, FALSE)                 AS is_blocking,
    LAST_LOADED_AT                               AS evaluated_at,
    'Feed last loaded ' || STALENESS_DAYS || ' days ago; '
        || RECORD_COUNT || ' records affected.'  AS detail
FROM V_FEED_TRUST_SIGNALS

UNION ALL

SELECT
    'ATACCAMA',
    SCOPE_OBJECT,
    FEED_NAME,
    RECORD_IDENTIFIER,
    SIGNAL_NAME,
    SIGNAL_DIMENSION,
    MEASURED_VALUE,
    NULL,
    DATA_TRUST_INDEX,
    TRUST_STATUS,
    COALESCE(IS_BLOCKING, FALSE),
    EVALUATED_AT,
    DETAIL
FROM ATACCAMA_TRUST_SIGNALS;

/* ============================================================================
   7. Point-in-time trust record
   ----------------------------------------------------------------------------
   Answers blog 1's question 1: reconstructing a decision after the fact.
   Appended to by the decision procedure in script 06, so the trust state is
   captured AS IT WAS when the agent acted -- not as it looks today.
   ============================================================================ */
CREATE OR REPLACE TABLE TRUST_SIGNAL_SNAPSHOT (
    SNAPSHOT_ID        VARCHAR(60)   NOT NULL COMMENT 'Unique snapshot identifier',
    DECISION_ID        VARCHAR(60)            COMMENT 'FK -> DECISION_AUDIT.DECISION_ID',
    APPLICANT_ID       VARCHAR(20)            COMMENT 'Applicant the decision concerned',
    CAPTURED_AT        TIMESTAMP_LTZ NOT NULL COMMENT 'Moment of capture -- the decision moment',
    SIGNAL_SOURCE      VARCHAR(40)            COMMENT 'SNOWFLAKE_NATIVE | ATACCAMA',
    SCOPE_OBJECT       VARCHAR(200)           COMMENT 'Object the signal applied to',
    FEED_NAME          VARCHAR(80)            COMMENT 'Feed the signal applied to',
    SIGNAL_NAME        VARCHAR(80)            COMMENT 'Signal identifier',
    MEASURED_VALUE     NUMBER(14,4)           COMMENT 'Value measured at decision time',
    TRUST_STATUS       VARCHAR(20)            COMMENT 'PASS | WARN | FAIL at decision time',
    IS_BLOCKING        BOOLEAN                COMMENT 'Whether this signal could block the decision',
    DETAIL             VARCHAR(1000)          COMMENT 'Explanation retained for examiners',
    CONSTRAINT PK_TRUST_SNAPSHOT PRIMARY KEY (SNAPSHOT_ID)
)
COMMENT = 'Append-only trust state as it stood at each decision. Makes a decision reconstructable rather than merely re-derivable.';

/* ============================================================================
   8. Horizon Catalog tags -- making fitness-for-use discoverable
   ----------------------------------------------------------------------------
   The views above answer "is this data trustworthy?" when something asks.
   Tags answer it in the catalog, for anyone browsing before they build.

   TRUST_TIER is the fitness-for-use classification:
       CERTIFIED    cleared for automated decisioning
       PROVISIONAL  usable with review -- a known trust issue is open
       UNCERTIFIED  not cleared for automated decisioning

   RAW.LIABILITIES is deliberately PROVISIONAL, not CERTIFIED, because of the
   stalled BUREAU_TU feed. The catalog label and the live trust signal agree,
   which is the point: governance metadata and runtime measurement should not
   tell two different stories.

   Tags set on a table are inherited by its columns, so a single statement
   classifies the whole object.
   ============================================================================ */
CREATE OR REPLACE TAG DATA_DOMAIN
  ALLOWED_VALUES 'CREDIT_RISK', 'CUSTOMER', 'SERVICING'
  COMMENT = 'Business domain that owns the object';

CREATE OR REPLACE TAG TRUST_TIER
  ALLOWED_VALUES 'CERTIFIED', 'PROVISIONAL', 'UNCERTIFIED'
  COMMENT = 'Fitness-for-use classification. CERTIFIED means cleared for automated decisioning.';

CREATE OR REPLACE TAG DECISION_CRITICAL
  ALLOWED_VALUES 'TRUE', 'FALSE'
  COMMENT = 'Whether this object feeds an automated credit decision';

-- PROVISIONAL: the BUREAU_TU feed is stalled, so this table is not cleared
-- for unattended decisioning until the feed recovers.
ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.LIABILITIES SET TAG
  DATA_DOMAIN = 'CREDIT_RISK',
  TRUST_TIER = 'PROVISIONAL',
  DECISION_CRITICAL = 'TRUE';

ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.INCOME_VERIFICATION SET TAG
  DATA_DOMAIN = 'CREDIT_RISK',
  TRUST_TIER = 'CERTIFIED',
  DECISION_CRITICAL = 'TRUE';

ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.APPLICANTS SET TAG
  DATA_DOMAIN = 'CUSTOMER',
  TRUST_TIER = 'CERTIFIED',
  DECISION_CRITICAL = 'TRUE';

ALTER TABLE ATACCAMA_TRUST_DEMO.RAW.REPAYMENT_HISTORY SET TAG
  DATA_DOMAIN = 'SERVICING',
  TRUST_TIER = 'CERTIFIED',
  DECISION_CRITICAL = 'TRUE';

-- The curated profile inherits the weakest tier of its inputs.
ALTER VIEW ATACCAMA_TRUST_DEMO.SEMANTIC.V_APPLICANT_CREDIT_PROFILE SET TAG
  DATA_DOMAIN = 'CREDIT_RISK',
  TRUST_TIER = 'PROVISIONAL',
  DECISION_CRITICAL = 'TRUE';
