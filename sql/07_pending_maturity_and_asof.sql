-- =============================================================================
-- Layer 7 - handling the latest quarter while cashback is still pending
-- =============================================================================
-- The problem: at the close of a quarter a share of that quarter's cashback
-- transactions have not been decided yet. Under approved-only they are invisible,
-- so the newest quarter always looks like a churn spike that then heals as the
-- backlog clears. Three artefacts below:
--
--   7.1 how much of each quarter is exposed to pending
--   7.2 how fast each affiliate source decides transactions (the maturity curve)
--   7.3 an as-of / vintage restatement so the same quarter can be measured at
--       T+0, T+30, T+45, T+90 and the reporting lag chosen from evidence
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 7.1 Pending exposure per quarter
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE sahseh_churn.mart_pending_exposure AS
WITH cashback AS (
  SELECT
    sahseh_churn.fn_quarter_label(purchase_date) AS quarter_label,
    COUNT(*)                                        AS cashback_transactions,
    COUNTIF(status = 'pending')                     AS pending_transactions,
    SUM(amount_sar)                                 AS gross_amount_sar,
    SUM(IF(status = 'pending', amount_sar, 0))      AS pending_amount_sar
  FROM sahseh_churn.stg_cashback_transactions
  GROUP BY quarter_label
),
users AS (
  SELECT
    quarter_label,
    COUNTIF(is_active_baseline)                                 AS active_users_baseline,
    COUNTIF(is_active_approved_only)                            AS active_users_approved_only,
    COUNTIF(is_active_on_pending_only)                          AS users_active_only_via_pending,
    COUNTIF(is_active_baseline AND cashback_pending_transactions > 0) AS active_users_with_any_pending
  FROM sahseh_churn.fct_user_quarter_activity
  GROUP BY quarter_label
)
SELECT
  u.quarter_label,
  u.active_users_baseline,
  u.active_users_approved_only,
  u.users_active_only_via_pending,
  u.active_users_with_any_pending,
  -- The share of the reported active base that a pending-approval decision could
  -- still remove. This is the number to put next to the latest quarter.
  ROUND(SAFE_DIVIDE(u.users_active_only_via_pending, u.active_users_baseline), 4)
    AS share_of_active_base_at_risk,
  c.cashback_transactions,
  c.pending_transactions,
  ROUND(SAFE_DIVIDE(c.pending_transactions, c.cashback_transactions), 4) AS pending_transaction_rate,
  c.pending_amount_sar,
  c.gross_amount_sar
FROM users u
LEFT JOIN cashback c USING (quarter_label)
ORDER BY u.quarter_label;

-- -----------------------------------------------------------------------------
-- 7.2 Approval maturity curve
-- -----------------------------------------------------------------------------
-- Built only from transactions that have already been decided, then applied to
-- the undecided ones. On real data this is fitted per source and per merchant,
-- because networks differ by weeks; the source split is kept here for that
-- reason even though the synthetic data is uniform.
CREATE OR REPLACE TABLE sahseh_churn.mart_cashback_approval_maturity AS
WITH decided AS (
  SELECT
    source,
    sahseh_churn.fn_quarter_label(purchase_date) AS purchase_quarter,
    status,
    days_to_status_decision
  FROM sahseh_churn.stg_cashback_transactions
  WHERE status_updated_date IS NOT NULL
)
SELECT
  source,
  COUNT(*)                                                      AS decided_transactions,
  ROUND(SAFE_DIVIDE(COUNTIF(status = 'approved'), COUNT(*)), 4) AS eventual_approval_rate,
  -- Cumulative share of decisions made within N days of the purchase.
  ROUND(SAFE_DIVIDE(COUNTIF(days_to_status_decision <= 30), COUNT(*)), 4) AS decided_within_30d,
  ROUND(SAFE_DIVIDE(COUNTIF(days_to_status_decision <= 45), COUNT(*)), 4) AS decided_within_45d,
  ROUND(SAFE_DIVIDE(COUNTIF(days_to_status_decision <= 60), COUNT(*)), 4) AS decided_within_60d,
  ROUND(SAFE_DIVIDE(COUNTIF(days_to_status_decision <= 90), COUNT(*)), 4) AS decided_within_90d,
  APPROX_QUANTILES(days_to_status_decision, 100)[OFFSET(50)] AS p50_days_to_decision,
  APPROX_QUANTILES(days_to_status_decision, 100)[OFFSET(90)] AS p90_days_to_decision,
  MAX(days_to_status_decision)                               AS max_days_to_decision
FROM decided
GROUP BY source
UNION ALL
SELECT
  'ALL SOURCES',
  COUNT(*),
  ROUND(SAFE_DIVIDE(COUNTIF(status = 'approved'), COUNT(*)), 4),
  ROUND(SAFE_DIVIDE(COUNTIF(days_to_status_decision <= 30), COUNT(*)), 4),
  ROUND(SAFE_DIVIDE(COUNTIF(days_to_status_decision <= 45), COUNT(*)), 4),
  ROUND(SAFE_DIVIDE(COUNTIF(days_to_status_decision <= 60), COUNT(*)), 4),
  ROUND(SAFE_DIVIDE(COUNTIF(days_to_status_decision <= 90), COUNT(*)), 4),
  APPROX_QUANTILES(days_to_status_decision, 100)[OFFSET(50)],
  APPROX_QUANTILES(days_to_status_decision, 100)[OFFSET(90)],
  MAX(days_to_status_decision)
FROM decided
ORDER BY source;

-- -----------------------------------------------------------------------------
-- 7.3 As-of restatement
-- -----------------------------------------------------------------------------
-- Rebuilds user-quarter activity as it WOULD have looked on a given date:
-- a transaction whose decision had not happened yet on that date is treated as
-- pending, exactly as the extract would have shown it at the time. This is what
-- makes "the latest quarter is provisional" measurable instead of rhetorical.
--
-- Output is sparse: only user-quarters with at least one in-scope event appear.
CREATE OR REPLACE TABLE FUNCTION sahseh_churn.tvf_user_quarter_activity_as_of(as_of_date DATE)
AS (
  WITH coupon_as_of AS (
    SELECT
      m.unified_user_id,
      sahseh_churn.fn_quarter_label(c.event_date) AS quarter_label,
      c.event_date AS activity_date,
      c.is_eligible_event AS counts_baseline,
      c.is_eligible_event AS counts_approved_only
    FROM sahseh_churn.stg_coupon_events c
    JOIN sahseh_churn.stg_identity_map m
      ON m.source_system = 'coupon' AND m.source_user_id = c.coupon_user_id
    WHERE c.event_date <= as_of_date
      AND c.event_date BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
  ),
  cashback_as_of AS (
    SELECT
      m.unified_user_id,
      sahseh_churn.fn_quarter_label(b.purchase_date) AS quarter_label,
      b.purchase_date AS activity_date,
      -- Status as it was known on as_of_date
      IF(b.status_updated_date IS NULL OR b.status_updated_date > as_of_date, 'pending', b.status)
        AS status_as_of
    FROM sahseh_churn.stg_cashback_transactions b
    JOIN sahseh_churn.stg_identity_map m
      ON m.source_system = 'cashback' AND m.source_user_id = b.cashback_user_id
    WHERE b.purchase_date <= as_of_date
      AND b.purchase_date BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
  ),
  unioned AS (
    SELECT unified_user_id, quarter_label, counts_baseline, counts_approved_only
    FROM coupon_as_of
    UNION ALL
    SELECT
      unified_user_id,
      quarter_label,
      status_as_of IN ('approved', 'pending'),
      status_as_of = 'approved'
    FROM cashback_as_of
  )
  SELECT as_of_date, unified_user_id, quarter_label, is_active_baseline, is_active_approved_only
  FROM (
    SELECT
      unified_user_id,
      quarter_label,
      LOGICAL_OR(counts_baseline)      AS is_active_baseline,
      LOGICAL_OR(counts_approved_only) AS is_active_approved_only
    FROM unioned
    GROUP BY unified_user_id, quarter_label
  )
);

-- -----------------------------------------------------------------------------
-- 7.4 Vintage comparison for the Q2 -> Q3 transition
-- -----------------------------------------------------------------------------
-- Same transition, measured at four different reporting dates. The movement
-- between vintages IS the cost of publishing early; it is what a reporting lag
-- or a pending haircut has to cover.
CREATE OR REPLACE TABLE sahseh_churn.mart_churn_vintage_comparison AS
WITH vintages AS (
  SELECT 'T+0  (Q3 close)' AS vintage_label, * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-09-30')
  UNION ALL
  SELECT 'T+30',            * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-10-30')
  UNION ALL
  SELECT 'T+45',            * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-11-14')
  UNION ALL
  SELECT 'T+90',            * FROM sahseh_churn.tvf_user_quarter_activity_as_of(DATE '2025-12-29')
),
per_user AS (
  SELECT
    vintage_label,
    as_of_date,
    definition_name,
    unified_user_id,
    LOGICAL_OR(quarter_label = '2025Q2'
               AND IF(definition_name = 'baseline', is_active_baseline, is_active_approved_only)) AS active_q2,
    LOGICAL_OR(quarter_label = '2025Q3'
               AND IF(definition_name = 'baseline', is_active_baseline, is_active_approved_only)) AS active_q3
  FROM vintages
  CROSS JOIN UNNEST(['baseline', 'approved_only']) AS definition_name
  GROUP BY vintage_label, as_of_date, definition_name, unified_user_id
)
SELECT
  vintage_label,
  as_of_date,
  definition_name,
  '2025Q2' AS from_quarter,
  '2025Q3' AS to_quarter,
  COUNTIF(active_q2)                      AS active_base,
  COUNTIF(active_q2 AND active_q3)        AS retained_users,
  COUNTIF(active_q2 AND NOT active_q3)    AS churned_users,
  ROUND(SAFE_DIVIDE(COUNTIF(active_q2 AND NOT active_q3), COUNTIF(active_q2)), 4) AS churn_rate
FROM per_user
GROUP BY vintage_label, as_of_date, definition_name
ORDER BY definition_name, as_of_date;
