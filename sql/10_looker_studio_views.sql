-- =============================================================================
-- Layer 10 - reporting views for Looker Studio
-- =============================================================================
-- The marts are shaped for correctness; three of them are WIDE where a Looker
-- Studio chart needs LONG. Looker Studio cannot unpivot, so the reshape belongs
-- in SQL rather than in a chart configuration nobody can review.
--
-- These views add no logic. If a number here disagrees with the mart it came
-- from, this file is wrong.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 10.1 Cohort funnel  (wide -> long)
-- -----------------------------------------------------------------------------
-- mart_q1_cohort_summary is one row per definition with each stage as a column.
-- A funnel-shaped bar chart needs one row per stage.
CREATE OR REPLACE VIEW sahseh_churn.v_ls_cohort_funnel AS
SELECT
  c.definition_name,
  s.stage_order,
  s.stage_group,
  s.stage,
  s.users,
  ROUND(SAFE_DIVIDE(s.users, c.q1_cohort_users), 4) AS share_of_cohort
FROM sahseh_churn.mart_q1_cohort_summary c,
UNNEST([
  STRUCT(1 AS stage_order, 'Q1 cohort'   AS stage_group, 'Active in Q1'        AS stage, c.q1_cohort_users        AS users),
  STRUCT(2 AS stage_order, 'Q2 outcome'  AS stage_group, 'Retained in Q2'      AS stage, c.retained_in_q2         AS users),
  STRUCT(3 AS stage_order, 'Q2 outcome'  AS stage_group, 'Lapsed in Q2'        AS stage, c.lapsed_in_q2           AS users),
  STRUCT(4 AS stage_order, 'Q3 outcome'  AS stage_group, 'Reactivated in Q3'   AS stage, c.reactivated_in_q3_users AS users),
  STRUCT(5 AS stage_order, 'Q3 outcome'  AS stage_group, 'Confirmed churn'     AS stage, c.confirmed_churn_users  AS users)
]) AS s;

-- -----------------------------------------------------------------------------
-- 10.2 Approval maturity curve  (wide -> long)
-- -----------------------------------------------------------------------------
-- decided_within_30d/45d/60d/90d are four columns; a curve needs four points on
-- one axis. Horizon is emitted as INT64 so it sorts numerically, not as text.
CREATE OR REPLACE VIEW sahseh_churn.v_ls_maturity_curve AS
SELECT
  m.source,
  p.horizon_days,
  p.decided_share,
  m.eventual_approval_rate,
  m.decided_transactions
FROM sahseh_churn.mart_cashback_approval_maturity m,
UNNEST([
  STRUCT(30 AS horizon_days, m.decided_within_30d AS decided_share),
  STRUCT(45 AS horizon_days, m.decided_within_45d AS decided_share),
  STRUCT(60 AS horizon_days, m.decided_within_60d AS decided_share),
  STRUCT(90 AS horizon_days, m.decided_within_90d AS decided_share)
]) AS p;

-- -----------------------------------------------------------------------------
-- 10.3 Active base by reporting vintage
-- -----------------------------------------------------------------------------
-- Each quarter measured at its own close (T+0) and again at T+30 / T+45 / T+90,
-- so "the latest quarter is provisional" becomes a line that visibly moves.
--
-- This is the chart the pending-exposure page needs. mart_churn_vintage_comparison
-- measures the same effect on the Q2->Q3 CHURN RATE, and on this extract that
-- rate does not move at all - the late-decided transactions happen to belong to
-- users who were not in the Q2 base. The restatement is real but it lands on the
-- ACTIVE BASE, which is what this view exposes.
CREATE OR REPLACE VIEW sahseh_churn.v_ls_vintage_active_base AS
WITH vintages AS (
  SELECT '2025Q1' AS measured_quarter, 'T+0'  AS vintage_label, * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-03-31')
  UNION ALL SELECT '2025Q1', 'T+30', * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-04-30')
  UNION ALL SELECT '2025Q1', 'T+45', * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-05-15')
  UNION ALL SELECT '2025Q1', 'T+90', * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-06-29')
  UNION ALL SELECT '2025Q2', 'T+0',  * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-06-30')
  UNION ALL SELECT '2025Q2', 'T+30', * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-07-30')
  UNION ALL SELECT '2025Q2', 'T+45', * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-08-14')
  UNION ALL SELECT '2025Q2', 'T+90', * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-09-28')
  UNION ALL SELECT '2025Q3', 'T+0',  * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-09-30')
  UNION ALL SELECT '2025Q3', 'T+30', * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-10-30')
  UNION ALL SELECT '2025Q3', 'T+45', * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-11-14')
  UNION ALL SELECT '2025Q3', 'T+90', * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-12-29')
  UNION ALL SELECT '2025Q4', 'T+0',  * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-12-31')
  UNION ALL SELECT '2025Q4', 'T+30', * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2026-01-30')
  UNION ALL SELECT '2025Q4', 'T+45', * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2026-02-14')
  UNION ALL SELECT '2025Q4', 'T+90', * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2026-03-31')
)
SELECT
  measured_quarter,
  vintage_label,
  CAST(REPLACE(vintage_label, 'T+', '') AS INT64) AS vintage_days,
  as_of_date,
  definition_name,
  COUNT(DISTINCT unified_user_id) AS active_users
FROM vintages
CROSS JOIN UNNEST(['baseline', 'approved_only']) AS definition_name
WHERE quarter_label = measured_quarter
  AND IF(definition_name = 'baseline', is_active_baseline, is_active_approved_only)
GROUP BY measured_quarter, vintage_label, vintage_days, as_of_date, definition_name;

-- -----------------------------------------------------------------------------
-- 10.4 Pipeline row counts and freshness  (monitoring)
-- -----------------------------------------------------------------------------
-- Feeds the Data Quality page: what was built, how big it is, when it last ran,
-- and whether the row count still matches what the model says it should be.
-- __TABLES__ covers tables only; views have no stored row count by definition.
CREATE OR REPLACE VIEW sahseh_churn.v_ls_pipeline_row_counts AS
WITH built AS (
  SELECT
    table_id AS object_name,
    row_count,
    size_bytes,
    TIMESTAMP_MILLIS(last_modified_time) AS last_built_at
  FROM sahseh_churn.__TABLES__
),
expected AS (
  -- Expected counts are the model's own arithmetic, written down. A drift here
  -- is either a data change or a broken build, and either way someone should
  -- look before the numbers are published.
  SELECT * FROM UNNEST([
    STRUCT('raw_identity_map'              AS object_name, 132 AS expected_rows),
    STRUCT('raw_coupon_activity',           88),
    STRUCT('raw_cashback_transactions',     99),
    STRUCT('stg_identity_map',             132),
    STRUCT('stg_coupon_events',             87),
    STRUCT('stg_cashback_transactions',     98),
    STRUCT('dim_quarter',                    4),
    STRUCT('int_unified_activity_events',  185),
    STRUCT('fct_user_quarter_activity',    264),
    STRUCT('mart_quarterly_active_base',     8),
    STRUCT('mart_quarter_transitions',       6),
    STRUCT('mart_definition_sensitivity',    3),
    STRUCT('mart_definition_disagreements',  5),
    STRUCT('mart_q1_cohort_users',         132),
    STRUCT('mart_q1_cohort_summary',         2),
    STRUCT('mart_cashback_source_profile',  24),
    STRUCT('mart_pending_exposure',          4),
    STRUCT('mart_cashback_approval_maturity', 7),
    STRUCT('mart_churn_vintage_comparison',  8),
    STRUCT('mart_report_summary',          104),
    STRUCT('dq_check_results',              21)
  ])
)
SELECT
  CASE
    WHEN STARTS_WITH(b.object_name, 'raw_')  THEN 'L0 raw'
    WHEN STARTS_WITH(b.object_name, 'stg_')  THEN 'L1 staging'
    WHEN STARTS_WITH(b.object_name, 'int_')  THEN 'L2 unified'
    WHEN STARTS_WITH(b.object_name, 'fct_')  THEN 'L3 fact'
    WHEN STARTS_WITH(b.object_name, 'dim_')  THEN 'L4 dimension'
    WHEN STARTS_WITH(b.object_name, 'mart_') THEN 'L4 mart'
    WHEN STARTS_WITH(b.object_name, 'dq_')   THEN 'Quality'
    ELSE 'other'
  END AS layer,
  b.object_name,
  b.row_count,
  e.expected_rows,
  b.row_count - e.expected_rows AS row_count_drift,
  CASE
    WHEN e.expected_rows IS NULL             THEN 'NOT TRACKED'
    WHEN b.row_count = e.expected_rows       THEN 'OK'
    ELSE 'DRIFT'
  END AS row_count_status,
  b.last_built_at,
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), b.last_built_at, HOUR) AS hours_since_build,
  b.size_bytes
FROM built b
LEFT JOIN expected e USING (object_name);

-- -----------------------------------------------------------------------------
-- 10.5 Cardinality ledger  (row-level lineage for the monitoring page)
-- -----------------------------------------------------------------------------
-- Every row that enters the pipeline and where it goes, computed live rather
-- than transcribed - so the ledger on the report can never go stale.
CREATE OR REPLACE VIEW sahseh_churn.v_ls_cardinality_ledger AS
SELECT step_order, step, rows_in, rows_out, rows_out - rows_in AS row_delta, explanation
FROM UNNEST([
  STRUCT(1 AS step_order, 'Coupon: raw -> staging' AS step,
         (SELECT COUNT(*) FROM sahseh_churn.raw_coupon_activity) AS rows_in,
         (SELECT COUNT(*) FROM sahseh_churn.stg_coupon_events) AS rows_out,
         'Duplicate coupon_event_id rows collapsed' AS explanation),
  STRUCT(2, 'Cashback: raw -> staging',
         (SELECT COUNT(*) FROM sahseh_churn.raw_cashback_transactions),
         (SELECT COUNT(*) FROM sahseh_churn.stg_cashback_transactions),
         'Duplicate transaction_id rows collapsed'),
  STRUCT(3, 'Identity map: raw -> staging',
         (SELECT COUNT(*) FROM sahseh_churn.raw_identity_map),
         (SELECT COUNT(*) FROM sahseh_churn.stg_identity_map),
         'One row per source_system + source_user_id'),
  STRUCT(4, 'Staging -> unified events',
         (SELECT COUNT(*) FROM sahseh_churn.stg_coupon_events) +
         (SELECT COUNT(*) FROM sahseh_churn.stg_cashback_transactions),
         (SELECT COUNT(*) FROM sahseh_churn.int_unified_activity_events),
         'Union of both channels; adds and loses nothing'),
  STRUCT(5, 'Unified -> in scope',
         (SELECT COUNT(*) FROM sahseh_churn.int_unified_activity_events),
         (SELECT COUNTIF(is_in_scope) FROM sahseh_churn.int_unified_activity_events),
         'Unmapped, ambiguous or out-of-period events excluded'),
  STRUCT(6, 'In scope -> fact',
         (SELECT COUNTIF(is_in_scope) FROM sahseh_churn.int_unified_activity_events),
         (SELECT COUNT(*) FROM sahseh_churn.fct_user_quarter_activity),
         'Densification, not a filter: people x quarters')
]);
