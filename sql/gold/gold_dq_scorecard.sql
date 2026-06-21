-- =============================================================================
-- GOLD: Data Quality Scorecard
-- =============================================================================
-- Stores the per-source, per-batch outcome of every must-pass and warning-tier
-- data quality rule, plus a weighted 0-100 composite score. CloudWatch alarms
-- watch this table for threshold breaches (see Architecture Doc §6,
-- data_quality/must_pass_rules.py, data_quality/warning_rules.py).
-- =============================================================================

CREATE TABLE gold.dq_scorecard (
    source_system         STRING      COMMENT 'aecb | fraud | aml | internal',
    batch_date            DATE,
    rule_name             STRING,
    rule_tier             STRING      COMMENT 'MUST_PASS | WARNING',
    pass_rate             DECIMAL(5,4),
    records_evaluated     INT,
    records_failed        INT,
    score                 INT          COMMENT '0-100 weighted composite for the batch/rule',
    evaluated_at          TIMESTAMP
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/gold/dq_scorecard/';

-- Example: composite score per source per batch
-- CREATE VIEW gold.dq_scorecard_summary AS
-- SELECT
--     source_system,
--     batch_date,
--     SUM(CASE WHEN rule_tier = 'MUST_PASS' THEN score * 2 ELSE score END)
--       / SUM(CASE WHEN rule_tier = 'MUST_PASS' THEN 2 ELSE 1 END) AS composite_score
-- FROM gold.dq_scorecard
-- GROUP BY source_system, batch_date;
