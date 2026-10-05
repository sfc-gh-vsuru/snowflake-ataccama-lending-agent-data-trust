/* ============================================================================
   00_setup_database.sql
   ----------------------------------------------------------------------------
   Creates the database, schemas, and the stage + file format used to load the
   sample data from the data/ folder.

   Run this first. It is safe to re-run: every statement is IF NOT EXISTS or
   OR REPLACE on objects that hold no data.

   After this script, upload the CSVs (see SETUP.md, step 4):
       snow stage copy "data/*.csv" @ATACCAMA_TRUST_DEMO.RAW.SEED_STAGE -c <conn>
   ============================================================================ */

CREATE DATABASE IF NOT EXISTS ATACCAMA_TRUST_DEMO
  COMMENT = 'Demo: carrying trust signals from source to AI (Snowflake + Ataccama)';

USE DATABASE ATACCAMA_TRUST_DEMO;

CREATE SCHEMA IF NOT EXISTS RAW
  COMMENT = 'Mock lending source systems: applicants, income, liabilities, repayment history';
CREATE SCHEMA IF NOT EXISTS SEMANTIC
  COMMENT = 'Semantic layer: governed definitions of outstanding exposure, DTI, risk tier';
CREATE SCHEMA IF NOT EXISTS GOVERNANCE
  COMMENT = 'Trust signals, thresholds, decision audit trail';
CREATE SCHEMA IF NOT EXISTS AGENTS
  COMMENT = 'Cortex Agent and Streamlit app';

/* ----------------------------------------------------------------------------
   Stage and file format for the sample data
   ----------------------------------------------------------------------------
   The CSVs in data/ store dates as offsets ("days ago", "hours ago") rather
   than calendar dates. 02_load_mock_data.sql converts them to real dates at
   load time, so the stalled feed is always exactly 42 days old no matter when
   the demo is built.
   ---------------------------------------------------------------------------- */
CREATE STAGE IF NOT EXISTS RAW.SEED_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Sample data CSVs uploaded from the data/ folder';

CREATE OR REPLACE FILE FORMAT RAW.SEED_CSV
  TYPE = CSV
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  EMPTY_FIELD_AS_NULL = TRUE
  NULL_IF = ('')
  COMMENT = 'Sample data CSVs: comma-separated, one header row, empty field = NULL';
