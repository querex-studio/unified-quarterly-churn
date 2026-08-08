-- =============================================================================
-- Layer 3 - THE unified user-quarter activity table  (the core deliverable)
-- =============================================================================
-- Grain: exactly one row per unified_user_id x analysis quarter. 66 users x 4
-- quarters = 264 rows, whether or not the person did anything. A person who used
-- both coupons and cashback in the same quarter is still one row: counted once.
--
-- Quarters come from the spine, users from the identity map, so "inactive" is a
-- materialised fact rather than a missing row that downstream code has to guess.
-- =============================================================================

CREATE OR REPLACE TABLE sahseh_churn.fct_user_quarter_activity
CLUSTER BY unified_user_id, quarter_label
AS
WITH user_spine AS (
  SELECT DISTINCT unified_user_id
  FROM sahseh_churn.stg_identity_map
  WHERE NOT has_ambiguous_mapping
),
spine AS (
  SELECT u.unified_user_id, q.quarter_label, q.quarter_start_date, q.quarter_end_date, q.quarter_index
  FROM user_spine u
  CROSS JOIN sahseh_churn.dim_quarter q
),
events AS (
  SELECT *
  FROM sahseh_churn.int_unified_activity_events
  WHERE is_in_scope
),
aggregated AS (
  SELECT
    unified_user_id,
    quarter_label,

    -- Volume, kept for sanity checks and for the walkthrough trace
    COUNTIF(channel = 'coupon'   AND counts_as_activity_baseline)  AS eligible_coupon_events,
    COUNTIF(channel = 'cashback')                                  AS cashback_transactions_total,
    COUNTIF(channel = 'cashback' AND event_or_status = 'approved') AS cashback_approved_transactions,
    COUNTIF(channel = 'cashback' AND event_or_status = 'pending')  AS cashback_pending_transactions,
    COUNTIF(channel = 'cashback' AND event_or_status IN ('rejected', 'cancelled'))
                                                                   AS cashback_excluded_transactions,
    COUNT(DISTINCT IF(channel = 'cashback' AND counts_as_activity_baseline, source_feed, NULL))
                                                                   AS distinct_affiliate_sources,
    SUM(IF(channel = 'cashback' AND event_or_status = 'approved', amount_sar, 0)) AS approved_amount_sar,
    SUM(IF(channel = 'cashback' AND event_or_status = 'pending',  amount_sar, 0)) AS pending_amount_sar,

    -- Activity flags, one per churn definition
    LOGICAL_OR(counts_as_activity_baseline)      AS is_active_baseline,
    LOGICAL_OR(counts_as_activity_approved_only) AS is_active_approved_only,

    -- Which side of the business the person touched (baseline definition)
    LOGICAL_OR(channel = 'coupon'   AND counts_as_activity_baseline) AS is_active_coupon,
    LOGICAL_OR(channel = 'cashback' AND counts_as_activity_baseline) AS is_active_cashback,

    MIN(IF(counts_as_activity_baseline, activity_date, NULL)) AS first_activity_date,
    MAX(IF(counts_as_activity_baseline, activity_date, NULL)) AS last_activity_date
  FROM events
  GROUP BY unified_user_id, quarter_label
)
SELECT
  s.unified_user_id,
  s.quarter_label,
  s.quarter_start_date,
  s.quarter_end_date,
  s.quarter_index,

  COALESCE(a.eligible_coupon_events,          0) AS eligible_coupon_events,
  COALESCE(a.cashback_transactions_total,     0) AS cashback_transactions_total,
  COALESCE(a.cashback_approved_transactions,  0) AS cashback_approved_transactions,
  COALESCE(a.cashback_pending_transactions,   0) AS cashback_pending_transactions,
  COALESCE(a.cashback_excluded_transactions,  0) AS cashback_excluded_transactions,
  COALESCE(a.distinct_affiliate_sources,      0) AS distinct_affiliate_sources,
  COALESCE(a.approved_amount_sar,             0) AS approved_amount_sar,
  COALESCE(a.pending_amount_sar,              0) AS pending_amount_sar,

  COALESCE(a.is_active_baseline,      FALSE) AS is_active_baseline,
  COALESCE(a.is_active_approved_only, FALSE) AS is_active_approved_only,
  COALESCE(a.is_active_coupon,        FALSE) AS is_active_coupon,
  COALESCE(a.is_active_cashback,      FALSE) AS is_active_cashback,

  -- One person, one row, but we still record how they showed up.
  CASE
    WHEN COALESCE(a.is_active_coupon, FALSE) AND COALESCE(a.is_active_cashback, FALSE) THEN 'both'
    WHEN COALESCE(a.is_active_coupon, FALSE)   THEN 'coupon_only'
    WHEN COALESCE(a.is_active_cashback, FALSE) THEN 'cashback_only'
    ELSE 'inactive'
  END AS activity_mix,

  -- TRUE when the person is active only because a pending transaction is being
  -- counted. This single column is the entire exposure of the baseline
  -- definition to cashback approval risk.
  COALESCE(a.is_active_baseline, FALSE) AND NOT COALESCE(a.is_active_approved_only, FALSE)
    AS is_active_on_pending_only,

  a.first_activity_date,
  a.last_activity_date
FROM spine s
LEFT JOIN aggregated a
  ON  a.unified_user_id = s.unified_user_id
  AND a.quarter_label   = s.quarter_label;

-- -----------------------------------------------------------------------------
-- 3.1 Long view: one row per definition x user x quarter
-- -----------------------------------------------------------------------------
-- Everything downstream reads this view, so "what changes if only approved
-- transactions count" is answered by a GROUP BY definition_name instead of a
-- forked pipeline that can drift.

CREATE OR REPLACE VIEW sahseh_churn.v_user_quarter_active AS
SELECT
  definition_name,
  f.unified_user_id,
  f.quarter_label,
  f.quarter_start_date,
  f.quarter_index,
  IF(definition_name = 'baseline', f.is_active_baseline, f.is_active_approved_only) AS is_active,
  f.activity_mix,
  f.is_active_on_pending_only
FROM sahseh_churn.fct_user_quarter_activity f
CROSS JOIN UNNEST(['baseline', 'approved_only']) AS definition_name;
