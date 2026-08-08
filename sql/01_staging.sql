-- =============================================================================
-- Layer 1 - staging: type, trim, de-duplicate, classify
-- =============================================================================
-- Rules applied here (and nowhere else, so they are auditable in one place):
--   * one row per business key   -> repeated event / transaction ids collapsed
--   * whitespace + case normalised on every join key and every status value
--   * cashback status mapped to a status_class that drives activity eligibility
--   * NOTHING is filtered out. Rows that fail a rule are kept and flagged so the
--     DQ layer can count them; the fact layer decides what to exclude.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1 Identity map
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE sahseh_churn.stg_identity_map
CLUSTER BY source_system, source_user_id
AS
WITH normalised AS (
  SELECT
    LOWER(TRIM(source_system))  AS source_system,
    TRIM(source_user_id)        AS source_user_id,
    TRIM(unified_user_id)       AS unified_user_id
  FROM sahseh_churn.raw_identity_map
),
conflicts AS (
  -- A source id that resolves to more than one person is unusable: it would
  -- either double-count or mis-merge. Flag it, do not silently pick one.
  SELECT source_system, source_user_id, COUNT(DISTINCT unified_user_id) AS distinct_unified_ids
  FROM normalised
  GROUP BY source_system, source_user_id
)
SELECT
  n.source_system,
  n.source_user_id,
  n.unified_user_id,
  c.distinct_unified_ids > 1 AS has_ambiguous_mapping
FROM normalised n
JOIN conflicts c USING (source_system, source_user_id)
-- WHERE TRUE: BigQuery requires QUALIFY to follow a WHERE/GROUP BY/HAVING.
-- Nothing is filtered here on purpose - bad rows are flagged, not dropped.
WHERE TRUE
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY n.source_system, n.source_user_id
          ORDER BY n.unified_user_id
        ) = 1;

-- -----------------------------------------------------------------------------
-- 1.2 Coupon events
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE sahseh_churn.stg_coupon_events
PARTITION BY DATE_TRUNC(event_date, MONTH)
CLUSTER BY coupon_user_id
AS
WITH normalised AS (
  SELECT
    TRIM(coupon_event_id)   AS coupon_event_id,
    TRIM(coupon_user_id)    AS coupon_user_id,
    event_date,
    TRIM(merchant_id)       AS merchant_id,
    LOWER(TRIM(event_type)) AS event_type
  FROM sahseh_churn.raw_coupon_activity
),
duplicate_profile AS (
  SELECT
    coupon_event_id,
    COUNT(*) AS raw_row_count,
    -- Same id, different payload = a real integration bug, not a harmless replay.
    COUNT(DISTINCT TO_JSON_STRING(STRUCT(coupon_user_id, event_date, merchant_id, event_type))) AS distinct_payloads
  FROM normalised
  GROUP BY coupon_event_id
)
SELECT
  n.coupon_event_id,
  n.coupon_user_id,
  n.event_date,
  n.merchant_id,
  n.event_type,
  d.raw_row_count,
  d.raw_row_count > 1        AS was_duplicated_in_raw,
  d.distinct_payloads > 1    AS has_conflicting_duplicate,
  -- Eligibility for churn activity. Only coupon_copy counts; the flag is kept as
  -- a column so a rule change is a one-line edit, not a rewritten WHERE clause.
  n.event_type = 'coupon_copy' AS is_eligible_event
FROM normalised n
JOIN duplicate_profile d USING (coupon_event_id)
-- De-duplicate: keep exactly one row per coupon_event_id, deterministically.
-- (WHERE TRUE is required by BigQuery before QUALIFY; it filters nothing.)
WHERE TRUE
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY n.coupon_event_id
          ORDER BY n.event_date, n.coupon_user_id, n.merchant_id, n.event_type
        ) = 1;

-- -----------------------------------------------------------------------------
-- 1.3 Cashback transactions - all six affiliate sources combined
-- -----------------------------------------------------------------------------
-- In this workbook the six affiliate networks already arrive in one extract with
-- a `source` column. In production each network is its own feed with its own
-- column names, status vocabulary and timezone, so the union belongs here -
-- BEFORE any user-quarter aggregation - and looks like this:
--
--   WITH combined AS (
--     SELECT 'NovaLink Affiliates' AS source, txn_ref        AS transaction_id,
--            member_id AS cashback_user_id, DATE(sale_ts, 'Asia/Riyadh') AS purchase_date,
--            CASE LOWER(state) WHEN 'validated' THEN 'approved'
--                              WHEN 'declined'  THEN 'rejected' ELSE LOWER(state) END AS status, ...
--     FROM raw_novalink
--     UNION ALL
--     SELECT 'RewardBridge', id, user_ref, purchase_day,
--            CASE LOWER(status) WHEN 'paid' THEN 'approved' ELSE LOWER(status) END, ...
--     FROM raw_rewardbridge
--     UNION ALL ... four more ...
--   )
--
-- The union must be done on a *normalised* status vocabulary, otherwise one
-- network's "validated" quietly stops counting as activity. Source-level checks
-- that guard this are implemented in 06_mart_source_and_dq_checks.sql.

CREATE OR REPLACE TABLE sahseh_churn.stg_cashback_transactions
PARTITION BY DATE_TRUNC(purchase_date, MONTH)
CLUSTER BY cashback_user_id, source
AS
WITH combined AS (
  SELECT
    TRIM(transaction_id)   AS transaction_id,
    TRIM(cashback_user_id) AS cashback_user_id,
    purchase_date,
    TRIM(merchant_id)      AS merchant_id,
    TRIM(source)           AS source,
    LOWER(TRIM(status))    AS status,
    status_updated_date,
    amount_sar
  FROM sahseh_churn.raw_cashback_transactions
),
duplicate_profile AS (
  SELECT
    transaction_id,
    COUNT(*) AS raw_row_count,
    COUNT(DISTINCT TO_JSON_STRING(STRUCT(
      cashback_user_id, purchase_date, merchant_id, source, status, status_updated_date, amount_sar
    ))) AS distinct_payloads
  FROM combined
  GROUP BY transaction_id
)
SELECT
  c.transaction_id,
  c.cashback_user_id,
  c.purchase_date,
  c.merchant_id,
  c.source,
  c.status,
  c.status_updated_date,
  c.amount_sar,
  d.raw_row_count,
  d.raw_row_count > 1     AS was_duplicated_in_raw,
  d.distinct_payloads > 1 AS has_conflicting_duplicate,
  -- Single place where cashback status vocabulary is interpreted.
  CASE c.status
    WHEN 'approved'  THEN 'settled'
    WHEN 'pending'   THEN 'in_flight'
    WHEN 'rejected'  THEN 'failed'
    WHEN 'cancelled' THEN 'failed'
    ELSE 'unknown'
  END AS status_class,
  -- Days from the purchase to the workflow decision. Used for the pending-
  -- maturity model in 07, never for dating activity.
  DATE_DIFF(c.status_updated_date, c.purchase_date, DAY) AS days_to_status_decision
FROM combined c
JOIN duplicate_profile d USING (transaction_id)
WHERE TRUE
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY c.transaction_id
          ORDER BY c.purchase_date, c.status_updated_date, c.status, c.amount_sar
        ) = 1;
