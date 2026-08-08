-- =============================================================================
-- Layer 8 - trace one user from raw rows to final classification
-- =============================================================================
-- Run as a script. Change target_user to walk any person through the pipeline.
--
-- U055 is the recommended walkthrough case: their Q2 activity is a single
-- PENDING cashback transaction, so the person is retained under the baseline
-- definition and churned-then-reactivated under approved-only. One user, one
-- rule change, two different answers - which is exactly the decision the
-- financial model has to make.
-- =============================================================================

DECLARE target_user STRING DEFAULT 'U055';

-- ---- step 1: which source ids belong to this person --------------------------
SELECT 'step 1 - identity' AS step, source_system, source_user_id, unified_user_id
FROM sahseh_churn.stg_identity_map
WHERE unified_user_id = target_user
ORDER BY source_system;

-- ---- step 2: raw rows for those source ids -----------------------------------
SELECT
  'step 2 - raw coupon' AS step,
  r.coupon_event_id AS record_id,
  r.event_date      AS activity_date,
  r.event_type      AS event_or_status,
  CAST(NULL AS STRING) AS source_feed,
  CAST(NULL AS NUMERIC) AS amount_sar
FROM sahseh_churn.raw_coupon_activity r
JOIN sahseh_churn.stg_identity_map m
  ON m.source_system = 'coupon' AND m.source_user_id = r.coupon_user_id
WHERE m.unified_user_id = target_user
UNION ALL
SELECT
  'step 2 - raw cashback',
  r.transaction_id,
  r.purchase_date,
  r.status,
  r.source,
  r.amount_sar
FROM sahseh_churn.raw_cashback_transactions r
JOIN sahseh_churn.stg_identity_map m
  ON m.source_system = 'cashback' AND m.source_user_id = r.cashback_user_id
WHERE m.unified_user_id = target_user
ORDER BY step, activity_date;

-- ---- step 3: after de-duplication, identity resolution and quarter assignment -
SELECT
  'step 3 - unified events' AS step,
  channel,
  source_feed,
  source_event_id,
  activity_date,
  quarter_label,
  event_or_status,
  counts_as_activity_baseline,
  counts_as_activity_approved_only,
  is_in_scope
FROM sahseh_churn.int_unified_activity_events
WHERE unified_user_id = target_user
ORDER BY activity_date, channel;

-- ---- step 4: the user-quarter row that the whole model rests on --------------
SELECT
  'step 4 - user x quarter' AS step,
  quarter_label,
  eligible_coupon_events,
  cashback_approved_transactions,
  cashback_pending_transactions,
  cashback_excluded_transactions,
  activity_mix,
  is_active_baseline,
  is_active_approved_only,
  is_active_on_pending_only
FROM sahseh_churn.fct_user_quarter_activity
WHERE unified_user_id = target_user
ORDER BY quarter_index;

-- ---- step 5: final classification under both definitions ---------------------
SELECT
  'step 5 - classification' AS step,
  definition_name,
  activity_pattern,
  q1_cohort_status,
  active_q1, active_q2, active_q3, active_q4
FROM sahseh_churn.mart_q1_cohort_users
WHERE unified_user_id = target_user
ORDER BY definition_name;

-- ---- step 6: the transition this user contributes to --------------------------
SELECT
  'step 6 - contribution' AS step,
  definition_name,
  quarter_label      AS from_quarter,
  is_active          AS active_in_from_quarter,
  LEAD(is_active) OVER (PARTITION BY definition_name ORDER BY quarter_index)
                     AS active_in_next_quarter,
  CASE
    WHEN LEAD(is_active) OVER (PARTITION BY definition_name ORDER BY quarter_index) IS NULL
      THEN 'no next quarter in scope'
    WHEN NOT is_active THEN 'not in base'
    WHEN LEAD(is_active) OVER (PARTITION BY definition_name ORDER BY quarter_index) THEN 'retained'
    ELSE 'churned'
  END AS contributes_as
FROM sahseh_churn.v_user_quarter_active
WHERE unified_user_id = target_user
ORDER BY definition_name, quarter_label;
