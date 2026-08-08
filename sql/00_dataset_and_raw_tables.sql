-- =============================================================================
-- Sahseh unified quarterly churn  |  Layer 0 - dataset + raw landing contract
-- =============================================================================
-- Run first. Creates the dataset, the raw landing tables and two shared UDFs.
-- Raw tables are loaded by scripts/load_to_bigquery.ps1 (bq load, --replace).
--
-- Naming convention used across the pipeline:
--   raw_*  landing, byte-for-byte as extracted, no cleaning
--   stg_*  typed, trimmed, de-duplicated, one row per business key
--   int_*  intermediate, identity-resolved event stream
--   fct_*  analysis grain (unified_user_id x quarter)
--   mart_* reporting outputs that go into the financial model
--   dq_*   data-quality assertion outputs
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS sahseh_churn
OPTIONS (
  location = 'EU',
  description = 'Sahseh unified coupon + cashback quarterly churn (synthetic test data)'
);

-- -----------------------------------------------------------------------------
-- Raw landing tables
-- -----------------------------------------------------------------------------
-- Every column lands as it arrives. Dates are the only typed columns because the
-- extract is already ISO-formatted; anything ambiguous stays STRING and is cast
-- in the staging layer where a failed cast is visible as a DQ failure rather
-- than a silently dropped row.

-- Columns are deliberately nullable: `bq load --replace` recreates the table
-- from the load schema, and a NOT NULL that only exists in this file is a lie.
-- Missing keys are caught by the assertions in 06 instead.
CREATE TABLE IF NOT EXISTS sahseh_churn.raw_identity_map (
  source_system    STRING OPTIONS (description = 'coupon | cashback'),
  source_user_id   STRING OPTIONS (description = 'User id as used inside the source system'),
  unified_user_id  STRING OPTIONS (description = 'One person = one unified_user_id')
)
OPTIONS (description = 'Raw identity map extract. Grain: source_system + source_user_id.');

CREATE TABLE IF NOT EXISTS sahseh_churn.raw_coupon_activity (
  coupon_event_id  STRING OPTIONS (description = 'Event id. May repeat in the raw extract.'),
  coupon_user_id   STRING OPTIONS (description = 'Source id, resolve via identity map'),
  event_date       DATE   OPTIONS (description = 'ACTIVITY DATE for coupons'),
  merchant_id      STRING,
  event_type       STRING OPTIONS (description = 'Only coupon_copy is eligible activity')
)
OPTIONS (description = 'Raw coupon copy events. Grain: coupon_event_id (duplicates expected).');

CREATE TABLE IF NOT EXISTS sahseh_churn.raw_cashback_transactions (
  transaction_id       STRING  OPTIONS (description = 'Transaction id. May repeat in the raw extract.'),
  cashback_user_id     STRING  OPTIONS (description = 'Source id, resolve via identity map'),
  purchase_date        DATE    OPTIONS (description = 'ACTIVITY DATE for cashback'),
  merchant_id          STRING,
  source               STRING  OPTIONS (description = 'Affiliate network the transaction was fed from'),
  status               STRING  OPTIONS (description = 'approved | pending | rejected | cancelled'),
  status_updated_date  DATE    OPTIONS (description = 'WORKFLOW timing only. Never use to date activity.'),
  amount_sar           NUMERIC
)
OPTIONS (description = 'Raw cashback transactions, all six affiliate sources combined. Grain: transaction_id (duplicates expected).');

-- -----------------------------------------------------------------------------
-- Alternative ingestion: read the workbook directly from Google Sheets
-- -----------------------------------------------------------------------------
-- Useful while the source of truth is still a spreadsheet. The header row in the
-- supplied workbook is row 4, hence skip_leading_rows = 4 and the explicit range.
--
-- CREATE OR REPLACE EXTERNAL TABLE sahseh_churn.raw_cashback_transactions_sheet
-- OPTIONS (
--   format = 'GOOGLE_SHEETS',
--   uris = ['https://docs.google.com/spreadsheets/d/<SPREADSHEET_ID>'],
--   sheet_range = 'Cashback Transactions!A4:H',
--   skip_leading_rows = 1
-- );

-- -----------------------------------------------------------------------------
-- Shared UDFs
-- -----------------------------------------------------------------------------
-- One definition of "which quarter is this date in" used by every layer, so the
-- coupon side and the cashback side can never drift apart.

CREATE OR REPLACE FUNCTION sahseh_churn.fn_quarter_start(activity_date DATE)
RETURNS DATE
AS (DATE_TRUNC(activity_date, QUARTER));

CREATE OR REPLACE FUNCTION sahseh_churn.fn_quarter_label(activity_date DATE)
RETURNS STRING
AS (FORMAT('%dQ%d', EXTRACT(YEAR FROM activity_date), EXTRACT(QUARTER FROM activity_date)));

-- -----------------------------------------------------------------------------
-- Analysis-period spine
-- -----------------------------------------------------------------------------
-- Materialised so that a user with zero activity in a quarter still gets a row
-- downstream. Churn is about absence; absence needs a spine to be visible.

CREATE OR REPLACE TABLE sahseh_churn.dim_quarter AS
SELECT
  sahseh_churn.fn_quarter_label(quarter_start_date) AS quarter_label,
  quarter_start_date,
  DATE_SUB(DATE_ADD(quarter_start_date, INTERVAL 1 QUARTER), INTERVAL 1 DAY) AS quarter_end_date,
  ROW_NUMBER() OVER (ORDER BY quarter_start_date) AS quarter_index
FROM UNNEST(GENERATE_DATE_ARRAY(DATE '2025-01-01', DATE '2025-10-01', INTERVAL 1 QUARTER)) AS quarter_start_date;
