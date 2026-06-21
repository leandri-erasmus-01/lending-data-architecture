-- =============================================================================
-- MART: Example Analytical Queries
-- =============================================================================
-- A handful of representative queries proving the mart is actually usable by
-- the risk team, not just diagrammed. Maps to the "Tracked metrics for risk
-- dashboards" list in Architecture Doc §8.3.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Approval / decline / refer rate by product, by month
--    (Underwriting performance — from fact_credit_decision)
-- -----------------------------------------------------------------------------
SELECT
    product_type,
    DATE_TRUNC('month', decision_date)                                   AS decision_month,
    decision_outcome,
    COUNT(*)                                                                AS decision_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (
        PARTITION BY product_type, DATE_TRUNC('month', decision_date)
    ), 2)                                                                       AS pct_of_month
FROM gold.fact_credit_decision
WHERE decision_date >= DATE_ADD('month', -6, CURRENT_DATE())
GROUP BY product_type, DATE_TRUNC('month', decision_date), decision_outcome
ORDER BY decision_month, product_type, decision_outcome;


-- -----------------------------------------------------------------------------
-- 2. Portfolio health — outstanding balance and active loan count by product
--    (Portfolio health — from fact_loan_performance)
-- -----------------------------------------------------------------------------
SELECT
    product_type,
    snapshot_date,
    status,
    COUNT(*)                       AS loan_count,
    SUM(outstanding_amount)             AS total_outstanding,
    AVG(outstanding_amount)                  AS avg_outstanding
FROM mart.fact_loan_performance
WHERE snapshot_date = DATE_TRUNC('month', CURRENT_DATE()) - INTERVAL 1 DAY  -- most recent month-end
GROUP BY product_type, snapshot_date, status
ORDER BY product_type, status;


-- -----------------------------------------------------------------------------
-- 3. Delinquency distribution by product
--    (Delinquency — from fact_loan_performance)
-- -----------------------------------------------------------------------------
SELECT
    product_type,
    delinquency_bucket,
    COUNT(*)                                                      AS loan_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY product_type), 2) AS pct_of_product
FROM mart.fact_loan_performance
WHERE snapshot_date = DATE_TRUNC('month', CURRENT_DATE()) - INTERVAL 1 DAY
  AND status = 'ACTIVE'
GROUP BY product_type, delinquency_bucket
ORDER BY product_type,
         CASE delinquency_bucket
             WHEN 'CURRENT' THEN 0 WHEN '1-30' THEN 1 WHEN '31-60' THEN 2
             WHEN '61-90' THEN 3 ELSE 4
         END;


-- -----------------------------------------------------------------------------
-- 4. Vintage analysis — delinquency by months-on-book, grouped by origination
--    cohort (joins fact_loan_performance to fact_credit_decision)
-- -----------------------------------------------------------------------------
SELECT
    DATE_TRUNC('month', lp.decision_date)   AS origination_cohort,
    lp.months_on_book,
    lp.delinquency_bucket,
    COUNT(*)                                       AS loan_count,
    SUM(lp.outstanding_amount)                          AS cohort_outstanding
FROM mart.fact_loan_performance lp
JOIN gold.fact_credit_decision   fcd  ON fcd.application_id = lp.application_id
WHERE lp.snapshot_date = DATE_TRUNC('month', CURRENT_DATE()) - INTERVAL 1 DAY
GROUP BY DATE_TRUNC('month', lp.decision_date), lp.months_on_book, lp.delinquency_bucket
ORDER BY origination_cohort, lp.months_on_book;


-- -----------------------------------------------------------------------------
-- 5. Volume vs. capacity — daily decision count vs. the 10K -> 100K/day target
-- -----------------------------------------------------------------------------
SELECT
    decision_date,
    COUNT(*)                                              AS decisions_made,
    10000                                                         AS launch_capacity_target,
    ROUND(100.0 * COUNT(*) / 10000, 1)                                 AS pct_of_launch_capacity
FROM gold.fact_credit_decision
WHERE decision_date >= CURRENT_DATE() - INTERVAL 30 DAY
GROUP BY decision_date
ORDER BY decision_date;


-- -----------------------------------------------------------------------------
-- 6. Data quality trend by source
-- -----------------------------------------------------------------------------
SELECT
    source_system,
    batch_date,
    AVG(score)               AS avg_dq_score
FROM gold.dq_scorecard
WHERE batch_date >= CURRENT_DATE() - INTERVAL 30 DAY
GROUP BY source_system, batch_date
ORDER BY source_system, batch_date;
