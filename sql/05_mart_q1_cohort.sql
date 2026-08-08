-- =============================================================================
-- Layer 5 - Q1 cohort: confirmed churn and Q3 reactivation
-- =============================================================================
--   Q1 cohort          users active in 2025Q1
--   lapsed in Q2       Q1 cohort, inactive in Q2
--   confirmed churn    Q1 cohort, inactive in Q2 AND inactive in Q3
--   reactivated in Q3  Q1 cohort, inactive in Q2 AND active in Q3
--   reactivation rate  reactivated / lapsed in Q2
--
-- Identity: confirmed_churn + reactivated_in_q3 = lapsed_in_q2, always. It is
-- asserted in 06 so a silent regression cannot reach the financial model.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5.1 User-level cohort classification (the audit trail)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE sahseh_churn.mart_q1_cohort_users AS
WITH pivoted AS (
  SELECT
    definition_name,
    unified_user_id,
    LOGICAL_OR(is_active AND quarter_label = '2025Q1') AS active_q1,
    LOGICAL_OR(is_active AND quarter_label = '2025Q2') AS active_q2,
    LOGICAL_OR(is_active AND quarter_label = '2025Q3') AS active_q3,
    LOGICAL_OR(is_active AND quarter_label = '2025Q4') AS active_q4
  FROM sahseh_churn.v_user_quarter_active
  GROUP BY definition_name, unified_user_id
)
SELECT
  definition_name,
  unified_user_id,
  active_q1, active_q2, active_q3, active_q4,
  CONCAT(IF(active_q1,'1','0'), IF(active_q2,'1','0'), IF(active_q3,'1','0'), IF(active_q4,'1','0'))
    AS activity_pattern,
  CASE
    WHEN NOT active_q1                              THEN 'not_in_q1_cohort'
    WHEN active_q2                                  THEN 'retained_in_q2'
    WHEN NOT active_q2 AND active_q3                THEN 'lapsed_q2_reactivated_q3'
    WHEN NOT active_q2 AND NOT active_q3            THEN 'confirmed_churn'
  END AS q1_cohort_status
FROM pivoted;

-- -----------------------------------------------------------------------------
-- 5.2 Cohort summary
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE sahseh_churn.mart_q1_cohort_summary AS
SELECT
  definition_name,
  COUNTIF(active_q1)                                          AS q1_cohort_users,
  COUNTIF(active_q1 AND active_q2)                            AS retained_in_q2,
  COUNTIF(active_q1 AND NOT active_q2)                        AS lapsed_in_q2,

  -- Confirmed churn: silent in BOTH Q2 and Q3
  COUNTIF(active_q1 AND NOT active_q2 AND NOT active_q3)      AS confirmed_churn_users,
  ROUND(SAFE_DIVIDE(COUNTIF(active_q1 AND NOT active_q2 AND NOT active_q3),
                    COUNTIF(active_q1)), 4)                   AS confirmed_churn_rate_of_cohort,

  -- Reactivation: silent in Q2, back in Q3
  COUNTIF(active_q1 AND NOT active_q2 AND active_q3)          AS reactivated_in_q3_users,
  ROUND(SAFE_DIVIDE(COUNTIF(active_q1 AND NOT active_q2 AND active_q3),
                    COUNTIF(active_q1 AND NOT active_q2)), 4) AS reactivation_rate_of_lapsed_q2,
  ROUND(SAFE_DIVIDE(COUNTIF(active_q1 AND NOT active_q2 AND active_q3),
                    COUNTIF(active_q1)), 4)                   AS reactivated_share_of_cohort,

  -- The gap between single-quarter churn and confirmed churn is exactly the
  -- reactivation population: the cost of calling churn one quarter early.
  ROUND(SAFE_DIVIDE(COUNTIF(active_q1 AND NOT active_q2), COUNTIF(active_q1)), 4)
    AS single_quarter_churn_rate_q1_q2
FROM sahseh_churn.mart_q1_cohort_users
GROUP BY definition_name
ORDER BY definition_name;
