-- =============================================================================
-- Layer 6 - affiliate source profiling + data-quality assertions
-- =============================================================================
-- The six affiliate feeds are combined before any user-quarter aggregation, so
-- a single bad feed silently changes the churn number. These are the checks that
-- make that visible. On real data they run per load, before the marts refresh.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6.1 Source x quarter profile
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE sahseh_churn.mart_cashback_source_profile AS
WITH per_source AS (
  SELECT
    b.source,
    sahseh_churn.fn_quarter_label(b.purchase_date) AS quarter_label,
    COUNT(*)                                                     AS transactions,
    COUNT(DISTINCT b.cashback_user_id)                           AS distinct_source_users,
    COUNTIF(b.was_duplicated_in_raw)                             AS rows_duplicated_in_raw,
    COUNTIF(b.has_conflicting_duplicate)                         AS rows_with_conflicting_duplicate,
    COUNTIF(m.unified_user_id IS NULL)                           AS rows_with_unmapped_user,
    COUNTIF(b.status = 'approved')                               AS approved_txns,
    COUNTIF(b.status = 'pending')                                AS pending_txns,
    COUNTIF(b.status = 'rejected')                               AS rejected_txns,
    COUNTIF(b.status = 'cancelled')                              AS cancelled_txns,
    COUNTIF(b.status_class = 'unknown')                          AS unknown_status_txns,
    SUM(b.amount_sar)                                            AS gross_amount_sar,
    SUM(IF(b.status = 'approved', b.amount_sar, 0))              AS approved_amount_sar,
    SUM(IF(b.status = 'pending',  b.amount_sar, 0))              AS pending_amount_sar,
    -- Workflow latency: how long this network takes to decide a transaction.
    APPROX_QUANTILES(b.days_to_status_decision, 100)[OFFSET(50)] AS median_days_to_decision,
    MAX(b.days_to_status_decision)                               AS max_days_to_decision,
    -- Decisions that land in a later quarter than the purchase. These are the
    -- transactions that would move between quarters if anyone ever dated
    -- activity by status_updated_date instead of purchase_date.
    COUNTIF(b.status_updated_date IS NOT NULL
            AND DATE_TRUNC(b.status_updated_date, QUARTER) > DATE_TRUNC(b.purchase_date, QUARTER))
                                                                 AS decisions_landing_in_later_quarter
  FROM sahseh_churn.stg_cashback_transactions b
  LEFT JOIN sahseh_churn.stg_identity_map m
    ON m.source_system = 'cashback' AND m.source_user_id = b.cashback_user_id
  GROUP BY b.source, quarter_label
)
SELECT
  *,
  ROUND(SAFE_DIVIDE(approved_txns, transactions), 4)            AS approval_rate,
  ROUND(SAFE_DIVIDE(pending_txns, transactions), 4)             AS pending_rate,
  ROUND(SAFE_DIVIDE(rejected_txns + cancelled_txns, transactions), 4) AS failed_rate,
  ROUND(SAFE_DIVIDE(rows_with_unmapped_user, transactions), 4)  AS unmapped_rate,
  -- Volume continuity: a feed that quietly stops delivering looks exactly like
  -- a wave of churn, so it must be checked before the churn number is believed.
  LAG(transactions) OVER (PARTITION BY source ORDER BY quarter_label) AS prior_quarter_transactions,
  ROUND(SAFE_DIVIDE(transactions - LAG(transactions) OVER (PARTITION BY source ORDER BY quarter_label),
                    LAG(transactions) OVER (PARTITION BY source ORDER BY quarter_label)), 4)
    AS transactions_qoq_change
FROM per_source
ORDER BY source, quarter_label;

-- -----------------------------------------------------------------------------
-- 6.2 Cross-source duplicate suspects
-- -----------------------------------------------------------------------------
-- Same person, same merchant, same day, same amount, reported by two different
-- networks. Transaction ids differ so id-level de-duplication cannot catch it.
-- It inflates transaction counts; it does NOT inflate the churn number (a user
-- is counted once per quarter), which is one more reason to build churn on a
-- user-quarter grain rather than on transaction volumes.
CREATE OR REPLACE TABLE sahseh_churn.dq_cross_source_duplicate_suspects AS
SELECT
  cashback_user_id,
  purchase_date,
  merchant_id,
  amount_sar,
  COUNT(*)                          AS transaction_count,
  COUNT(DISTINCT source)            AS distinct_sources,
  ARRAY_AGG(source ORDER BY source) AS sources,
  ARRAY_AGG(transaction_id ORDER BY transaction_id) AS transaction_ids
FROM sahseh_churn.stg_cashback_transactions
GROUP BY cashback_user_id, purchase_date, merchant_id, amount_sar
HAVING COUNT(DISTINCT source) > 1;

-- -----------------------------------------------------------------------------
-- 6.3 Data-quality assertions
-- -----------------------------------------------------------------------------
-- Every check returns a count of failing records. 0 = PASS. Checks are graded:
--   error   pipeline must not publish
--   warn    publish, but the number needs a footnote
CREATE OR REPLACE TABLE sahseh_churn.dq_check_results AS
WITH checks AS (

  -- ---- duplicates ----------------------------------------------------------
  SELECT 'raw_duplicate_coupon_event_ids' AS check_name, 'warn' AS severity,
         (SELECT COUNT(*) FROM sahseh_churn.raw_coupon_activity) -
         (SELECT COUNT(*) FROM sahseh_churn.stg_coupon_events) AS failing_records,
         'Repeated coupon_event_id rows removed by staging' AS check_description
  UNION ALL
  SELECT 'raw_duplicate_transaction_ids', 'warn',
         (SELECT COUNT(*) FROM sahseh_churn.raw_cashback_transactions) -
         (SELECT COUNT(*) FROM sahseh_churn.stg_cashback_transactions),
         'Repeated transaction_id rows removed by staging'
  UNION ALL
  SELECT 'duplicate_ids_with_conflicting_payload', 'error',
         (SELECT COUNTIF(has_conflicting_duplicate) FROM sahseh_churn.stg_coupon_events) +
         (SELECT COUNTIF(has_conflicting_duplicate) FROM sahseh_churn.stg_cashback_transactions),
         'Same id seen twice with different content - integration bug, not a replay'

  -- ---- identity ------------------------------------------------------------
  UNION ALL
  SELECT 'identity_map_ambiguous_source_id', 'error',
         (SELECT COUNTIF(has_ambiguous_mapping) FROM sahseh_churn.stg_identity_map),
         'One source id resolving to more than one unified_user_id'
  UNION ALL
  SELECT 'identity_map_null_keys', 'error',
         (SELECT COUNTIF(source_system IS NULL OR source_user_id IS NULL OR unified_user_id IS NULL)
          FROM sahseh_churn.stg_identity_map),
         'Identity map row with a missing key column'
  UNION ALL
  SELECT 'identity_map_unknown_source_system', 'error',
         (SELECT COUNTIF(source_system NOT IN ('coupon', 'cashback'))
          FROM sahseh_churn.stg_identity_map),
         'source_system outside coupon/cashback would never join to an event'
  UNION ALL
  SELECT 'unmapped_coupon_user_ids', 'error',
         (SELECT COUNT(DISTINCT source_user_id) FROM sahseh_churn.int_unified_activity_events
          WHERE channel = 'coupon' AND is_unmapped_user),
         'Coupon source ids absent from the identity map - activity is dropped'
  UNION ALL
  SELECT 'unmapped_cashback_user_ids', 'error',
         (SELECT COUNT(DISTINCT source_user_id) FROM sahseh_churn.int_unified_activity_events
          WHERE channel = 'cashback' AND is_unmapped_user),
         'Cashback source ids absent from the identity map - activity is dropped'

  -- ---- vocabularies --------------------------------------------------------
  UNION ALL
  SELECT 'unexpected_coupon_event_type', 'warn',
         (SELECT COUNTIF(event_type != 'coupon_copy') FROM sahseh_churn.stg_coupon_events),
         'Coupon events that are not coupon_copy and therefore not activity'
  UNION ALL
  SELECT 'unexpected_cashback_status', 'error',
         (SELECT COUNTIF(status_class = 'unknown') FROM sahseh_churn.stg_cashback_transactions),
         'Status value outside approved/pending/rejected/cancelled - eligibility undefined'

  -- ---- dates ---------------------------------------------------------------
  UNION ALL
  SELECT 'activity_outside_analysis_period', 'warn',
         (SELECT COUNTIF(NOT is_in_analysis_period) FROM sahseh_churn.int_unified_activity_events),
         'Events dated outside 2025-01-01..2025-12-31'
  UNION ALL
  SELECT 'null_activity_date', 'error',
         (SELECT COUNTIF(activity_date IS NULL) FROM sahseh_churn.int_unified_activity_events),
         'Event with no usable activity date'
  UNION ALL
  SELECT 'status_decided_before_purchase', 'error',
         (SELECT COUNTIF(days_to_status_decision < 0) FROM sahseh_churn.stg_cashback_transactions),
         'status_updated_date earlier than purchase_date - impossible workflow order'
  UNION ALL
  SELECT 'settled_txn_missing_decision_date', 'warn',
         (SELECT COUNTIF(status_class IN ('settled', 'failed') AND status_updated_date IS NULL)
          FROM sahseh_churn.stg_cashback_transactions),
         'Decided transaction with no decision date - breaks the maturity model'
  UNION ALL
  SELECT 'pending_txn_with_decision_date', 'warn',
         (SELECT COUNTIF(status = 'pending' AND status_updated_date IS NOT NULL)
          FROM sahseh_churn.stg_cashback_transactions),
         'Pending transaction that already has a decision date'

  -- ---- grain and internal consistency --------------------------------------
  UNION ALL
  SELECT 'fct_grain_not_unique', 'error',
         (SELECT COUNT(*) FROM (
            SELECT unified_user_id, quarter_label
            FROM sahseh_churn.fct_user_quarter_activity
            GROUP BY unified_user_id, quarter_label HAVING COUNT(*) > 1)),
         'fct_user_quarter_activity must be one row per user per quarter'
  UNION ALL
  SELECT 'fct_row_count_mismatch', 'error',
         ABS((SELECT COUNT(*) FROM sahseh_churn.fct_user_quarter_activity) -
             (SELECT COUNT(DISTINCT unified_user_id) FROM sahseh_churn.stg_identity_map WHERE NOT has_ambiguous_mapping) *
             (SELECT COUNT(*) FROM sahseh_churn.dim_quarter)),
         'Spine must be complete: users x quarters'
  UNION ALL
  SELECT 'approved_only_active_exceeds_baseline', 'error',
         (SELECT COUNTIF(is_active_approved_only AND NOT is_active_baseline)
          FROM sahseh_churn.fct_user_quarter_activity),
         'approved_only actives must be a strict subset of baseline actives'
  UNION ALL
  SELECT 'transitions_do_not_reconcile', 'error',
         (SELECT COUNTIF(retained_users + churned_users != active_base)
          FROM sahseh_churn.mart_quarter_transitions),
         'retained + churned must equal the active base'
  UNION ALL
  SELECT 'q1_cohort_does_not_reconcile', 'error',
         (SELECT COUNTIF(confirmed_churn_users + reactivated_in_q3_users != lapsed_in_q2)
          FROM sahseh_churn.mart_q1_cohort_summary),
         'confirmed churn + reactivated must equal the users who lapsed in Q2'
  UNION ALL
  SELECT 'active_base_disagrees_with_event_recount', 'error',
         (SELECT COUNT(*) FROM (
            SELECT m.quarter_label
            FROM sahseh_churn.mart_quarterly_active_base m
            JOIN (
              SELECT quarter_label, COUNT(DISTINCT unified_user_id) AS n
              FROM sahseh_churn.int_unified_activity_events
              WHERE is_in_scope AND counts_as_activity_baseline
              GROUP BY quarter_label
            ) e USING (quarter_label)
            WHERE m.definition_name = 'baseline' AND m.active_users != e.n)),
         'Fact-table active base recounted independently from the event stream'
)
SELECT
  check_name,
  severity,
  check_description,
  failing_records,
  tolerance,
  IF(failing_records <= tolerance, 'PASS', 'FAIL') AS check_status,
  CURRENT_TIMESTAMP() AS checked_at
FROM (
  -- Tolerance is 0 for every check today. It exists as an explicit column so
  -- that accepting a known defect later is a recorded decision with a number
  -- attached, rather than a check someone quietly deleted.
  SELECT *, 0 AS tolerance FROM checks
)
ORDER BY IF(failing_records <= tolerance, 1, 0), severity, check_name;

-- -----------------------------------------------------------------------------
-- 6.4 Detail rows behind any failing check
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW sahseh_churn.dq_excluded_events AS
SELECT
  channel,
  source_feed,
  source_event_id,
  source_user_id,
  activity_date,
  quarter_label,
  event_or_status,
  amount_sar,
  CASE
    WHEN is_unmapped_user        THEN 'source id not in identity map'
    WHEN has_ambiguous_mapping   THEN 'source id maps to multiple unified users'
    WHEN NOT is_in_analysis_period THEN 'activity date outside 2025'
  END AS exclusion_reason
FROM sahseh_churn.int_unified_activity_events
WHERE NOT is_in_scope;
