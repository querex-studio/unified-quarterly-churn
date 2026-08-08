-- =============================================================================
-- Layer 2 - identity resolution and one unified activity event stream
-- =============================================================================
-- Coupon and cashback events become rows in a single table with one shared
-- grammar: who (unified_user_id), when (activity_date -> quarter), and whether
-- the row counts as activity under each churn definition.
--
-- Two definitions travel together through the whole pipeline so the sensitivity
-- analysis is a GROUP BY, not a second copy of the pipeline:
--   baseline       coupon_copy OR cashback status IN (approved, pending)
--   approved_only  coupon_copy OR cashback status = approved
-- =============================================================================

CREATE OR REPLACE TABLE sahseh_churn.int_unified_activity_events
PARTITION BY DATE_TRUNC(activity_date, MONTH)
CLUSTER BY unified_user_id, channel
AS
WITH coupon_events AS (
  SELECT
    'coupon'                      AS channel,
    c.coupon_event_id             AS source_event_id,
    c.coupon_user_id              AS source_user_id,
    'coupon_copy_event'           AS source_feed,
    c.event_date                  AS activity_date,   -- coupons are dated by event_date
    c.merchant_id,
    c.event_type                  AS event_or_status,
    CAST(NULL AS NUMERIC)         AS amount_sar,
    c.is_eligible_event           AS counts_as_activity_baseline,
    c.is_eligible_event           AS counts_as_activity_approved_only,
    c.was_duplicated_in_raw,
    c.has_conflicting_duplicate
  FROM sahseh_churn.stg_coupon_events c
),
cashback_events AS (
  SELECT
    'cashback'                    AS channel,
    b.transaction_id              AS source_event_id,
    b.cashback_user_id            AS source_user_id,
    b.source                      AS source_feed,     -- the affiliate network
    b.purchase_date               AS activity_date,   -- cashback is dated by purchase_date
    b.merchant_id,
    b.status                      AS event_or_status,
    b.amount_sar,
    -- Rejected and cancelled never count. Pending counts only in the baseline.
    b.status IN ('approved', 'pending') AS counts_as_activity_baseline,
    b.status = 'approved'               AS counts_as_activity_approved_only,
    b.was_duplicated_in_raw,
    b.has_conflicting_duplicate
  FROM sahseh_churn.stg_cashback_transactions b
),
all_events AS (
  SELECT * FROM coupon_events
  UNION ALL
  SELECT * FROM cashback_events
)
SELECT
  e.channel,
  e.source_feed,
  e.source_event_id,
  e.source_user_id,
  m.unified_user_id,
  e.activity_date,
  sahseh_churn.fn_quarter_start(e.activity_date) AS quarter_start_date,
  sahseh_churn.fn_quarter_label(e.activity_date) AS quarter_label,
  e.merchant_id,
  e.event_or_status,
  e.amount_sar,
  e.counts_as_activity_baseline,
  e.counts_as_activity_approved_only,
  e.was_duplicated_in_raw,
  e.has_conflicting_duplicate,
  -- Exclusion reasons are carried, not applied. The fact layer filters on
  -- is_in_scope; every other layer can still see why a row was dropped.
  m.unified_user_id IS NULL AS is_unmapped_user,
  COALESCE(m.has_ambiguous_mapping, FALSE) AS has_ambiguous_mapping,
  e.activity_date BETWEEN DATE '2025-01-01' AND DATE '2025-12-31' AS is_in_analysis_period,
  (
    m.unified_user_id IS NOT NULL
    AND NOT COALESCE(m.has_ambiguous_mapping, FALSE)
    AND e.activity_date BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
  ) AS is_in_scope
FROM all_events e
LEFT JOIN sahseh_churn.stg_identity_map m
  ON  m.source_system  = e.channel
  AND m.source_user_id = e.source_user_id;
