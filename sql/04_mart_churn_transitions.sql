-- =============================================================================
-- Layer 4 - quarter-to-quarter churn: Q1->Q2, Q2->Q3, Q3->Q4
-- =============================================================================
-- Definitions used, stated plainly because the financial model depends on them:
--   active base     users active in the FROM quarter
--   retained        active in the FROM quarter AND active in the TO quarter
--   churned         active in the FROM quarter AND NOT active in the TO quarter
--   churn rate      churned / active base          (retained + churned = base)
--
-- This is single-quarter (lapse) churn: one silent quarter is enough to be
-- called churned. It is deliberately the most pessimistic of the definitions
-- produced here; 05 adds the confirmed-churn variant that waits two quarters.
-- =============================================================================

CREATE OR REPLACE TABLE sahseh_churn.mart_quarterly_active_base AS
SELECT
  definition_name,
  quarter_label,
  quarter_index,
  COUNTIF(is_active)                                       AS active_users,
  COUNTIF(is_active AND activity_mix = 'coupon_only')      AS active_coupon_only,
  COUNTIF(is_active AND activity_mix = 'cashback_only')    AS active_cashback_only,
  COUNTIF(is_active AND activity_mix = 'both')             AS active_both_channels,
  COUNTIF(is_active AND is_active_on_pending_only)         AS active_on_pending_only,
  COUNT(*)                                                 AS users_in_universe
FROM sahseh_churn.v_user_quarter_active
GROUP BY definition_name, quarter_label, quarter_index
ORDER BY definition_name, quarter_index;

-- -----------------------------------------------------------------------------
-- 4.1 Transition table
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE sahseh_churn.mart_quarter_transitions AS
WITH sequenced AS (
  SELECT
    definition_name,
    unified_user_id,
    quarter_label,
    quarter_index,
    is_active,
    LEAD(is_active)     OVER user_timeline AS is_active_next_quarter,
    LEAD(quarter_label) OVER user_timeline AS next_quarter_label
  FROM sahseh_churn.v_user_quarter_active
  WINDOW user_timeline AS (PARTITION BY definition_name, unified_user_id ORDER BY quarter_index)
)
SELECT
  definition_name,
  quarter_label      AS from_quarter,
  next_quarter_label AS to_quarter,
  COUNTIF(is_active)                                AS active_base,
  COUNTIF(is_active AND is_active_next_quarter)     AS retained_users,
  COUNTIF(is_active AND NOT is_active_next_quarter) AS churned_users,
  ROUND(SAFE_DIVIDE(COUNTIF(is_active AND NOT is_active_next_quarter),
                    COUNTIF(is_active)), 4)         AS next_quarter_churn_rate,
  ROUND(SAFE_DIVIDE(COUNTIF(is_active AND is_active_next_quarter),
                    COUNTIF(is_active)), 4)         AS next_quarter_retention_rate,
  -- Not asked for, but the financial model always asks next: who came back or
  -- arrived in the TO quarter without being in the base.
  COUNTIF(NOT is_active AND is_active_next_quarter) AS new_or_returning_users
FROM sequenced
WHERE next_quarter_label IS NOT NULL
GROUP BY definition_name, from_quarter, to_quarter
ORDER BY definition_name, from_quarter;

-- -----------------------------------------------------------------------------
-- 4.2 Side-by-side sensitivity: baseline vs approved-only
-- -----------------------------------------------------------------------------
-- "Show how results change if only approved cashback transactions count."
CREATE OR REPLACE TABLE sahseh_churn.mart_definition_sensitivity AS
SELECT
  b.from_quarter,
  b.to_quarter,
  b.active_base             AS baseline_active_base,
  a.active_base             AS approved_only_active_base,
  a.active_base - b.active_base            AS active_base_delta,
  b.churned_users           AS baseline_churned,
  a.churned_users           AS approved_only_churned,
  a.churned_users - b.churned_users        AS churned_delta,
  b.next_quarter_churn_rate AS baseline_churn_rate,
  a.next_quarter_churn_rate AS approved_only_churn_rate,
  ROUND(a.next_quarter_churn_rate - b.next_quarter_churn_rate, 4) AS churn_rate_delta_pp
FROM sahseh_churn.mart_quarter_transitions b
JOIN sahseh_churn.mart_quarter_transitions a
  ON  a.from_quarter = b.from_quarter
  AND a.definition_name = 'approved_only'
WHERE b.definition_name = 'baseline'
ORDER BY b.from_quarter;

-- -----------------------------------------------------------------------------
-- 4.3 Which individual users the pending rule moves
-- -----------------------------------------------------------------------------
-- The audit trail behind 4.2: every user-quarter where the two definitions
-- disagree, so any number in the sensitivity table can be traced to a person.
CREATE OR REPLACE TABLE sahseh_churn.mart_definition_disagreements AS
SELECT
  unified_user_id,
  quarter_label,
  quarter_index,
  cashback_pending_transactions,
  pending_amount_sar,
  'active under baseline, inactive under approved_only' AS disagreement
FROM sahseh_churn.fct_user_quarter_activity
WHERE is_active_on_pending_only
ORDER BY quarter_index, unified_user_id;
