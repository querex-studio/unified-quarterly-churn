-- =============================================================================
-- Layer 9 - the single summary block that goes into the workbook / model
-- =============================================================================
-- One long, tidy table: section | definition | period | metric | value.
-- Export it once and pivot it in the sheet, so the workbook never contains a
-- number that was typed by hand.
--   bq query --use_legacy_sql=false --format=csv "SELECT * FROM sahseh_churn.mart_report_summary ORDER BY section_order, definition_name, period, metric" > summary.csv
-- =============================================================================

CREATE OR REPLACE TABLE sahseh_churn.mart_report_summary AS

-- 1. Active base per quarter
SELECT
  1 AS section_order,
  'Active base' AS section,
  b.definition_name,
  b.quarter_label AS period,
  m.metric,
  m.value
FROM sahseh_churn.mart_quarterly_active_base b,
UNNEST([
  STRUCT('active_users'          AS metric, CAST(b.active_users           AS NUMERIC) AS value),
  STRUCT('active_coupon_only'    AS metric, CAST(b.active_coupon_only     AS NUMERIC) AS value),
  STRUCT('active_cashback_only'  AS metric, CAST(b.active_cashback_only   AS NUMERIC) AS value),
  STRUCT('active_both_channels'  AS metric, CAST(b.active_both_channels   AS NUMERIC) AS value),
  STRUCT('active_on_pending_only' AS metric, CAST(b.active_on_pending_only AS NUMERIC) AS value)
]) AS m

UNION ALL

-- 2. Quarter-to-quarter churn
SELECT
  2,
  'Quarter transitions',
  t.definition_name,
  CONCAT(t.from_quarter, ' -> ', t.to_quarter),
  m.metric,
  m.value
FROM sahseh_churn.mart_quarter_transitions t,
UNNEST([
  STRUCT('active_base'                AS metric, CAST(t.active_base                 AS NUMERIC) AS value),
  STRUCT('retained_users'             AS metric, CAST(t.retained_users              AS NUMERIC) AS value),
  STRUCT('churned_users'              AS metric, CAST(t.churned_users               AS NUMERIC) AS value),
  STRUCT('next_quarter_churn_rate'    AS metric, CAST(t.next_quarter_churn_rate     AS NUMERIC) AS value),
  STRUCT('next_quarter_retention_rate' AS metric, CAST(t.next_quarter_retention_rate AS NUMERIC) AS value)
]) AS m

UNION ALL

-- 3. Q1 cohort: confirmed churn and reactivation
SELECT
  3,
  'Q1 cohort',
  c.definition_name,
  '2025Q1 cohort',
  m.metric,
  m.value
FROM sahseh_churn.mart_q1_cohort_summary c,
UNNEST([
  STRUCT('q1_cohort_users'                AS metric, CAST(c.q1_cohort_users                 AS NUMERIC) AS value),
  STRUCT('retained_in_q2'                 AS metric, CAST(c.retained_in_q2                  AS NUMERIC) AS value),
  STRUCT('lapsed_in_q2'                   AS metric, CAST(c.lapsed_in_q2                    AS NUMERIC) AS value),
  STRUCT('confirmed_churn_users'          AS metric, CAST(c.confirmed_churn_users           AS NUMERIC) AS value),
  STRUCT('confirmed_churn_rate_of_cohort' AS metric, CAST(c.confirmed_churn_rate_of_cohort  AS NUMERIC) AS value),
  STRUCT('reactivated_in_q3_users'        AS metric, CAST(c.reactivated_in_q3_users         AS NUMERIC) AS value),
  STRUCT('reactivation_rate_of_lapsed_q2' AS metric, CAST(c.reactivation_rate_of_lapsed_q2  AS NUMERIC) AS value)
]) AS m

UNION ALL

-- 4. Pending exposure, the caveat that travels with the latest quarter
SELECT
  4,
  'Pending exposure',
  'baseline',
  p.quarter_label,
  m.metric,
  m.value
FROM sahseh_churn.mart_pending_exposure p,
UNNEST([
  STRUCT('pending_transactions'         AS metric, CAST(p.pending_transactions         AS NUMERIC) AS value),
  STRUCT('pending_transaction_rate'     AS metric, CAST(p.pending_transaction_rate     AS NUMERIC) AS value),
  STRUCT('users_active_only_via_pending' AS metric, CAST(p.users_active_only_via_pending AS NUMERIC) AS value),
  STRUCT('share_of_active_base_at_risk' AS metric, CAST(p.share_of_active_base_at_risk AS NUMERIC) AS value),
  STRUCT('pending_amount_sar'           AS metric, CAST(p.pending_amount_sar           AS NUMERIC) AS value)
]) AS m;

-- -----------------------------------------------------------------------------
-- Headline view: the numbers the financial model actually consumes
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW sahseh_churn.v_headline_churn AS
SELECT
  t.from_quarter,
  t.to_quarter,
  t.active_base,
  t.retained_users,
  t.churned_users,
  t.next_quarter_churn_rate           AS churn_rate_baseline,
  s.approved_only_churn_rate          AS churn_rate_approved_only,
  s.churn_rate_delta_pp,
  e.share_of_active_base_at_risk      AS from_quarter_pending_risk
FROM sahseh_churn.mart_quarter_transitions t
JOIN sahseh_churn.mart_definition_sensitivity s
  ON s.from_quarter = t.from_quarter
LEFT JOIN sahseh_churn.mart_pending_exposure e
  ON e.quarter_label = t.from_quarter
WHERE t.definition_name = 'baseline';
