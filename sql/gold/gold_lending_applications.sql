-- =============================================================================
-- GOLD: Fact Credit Decision
-- =============================================================================
-- Reporting-facing join of decision_input and decision_outcomes, restructured
-- for the portfolio mart (see sql/mart/). Grain: one row per COMPLETED
-- decision.
--
-- INNER JOIN is deliberate: an application sitting in decision_input with no
-- matching row in decision_outcomes yet simply hasn't been decided, and
-- should not appear in a dashboard about decision outcomes.
-- =============================================================================

CREATE TABLE gold.lending_applications (
    application_id             STRING,
    internal_uuid              STRING,
    product_type               STRING      COMMENT 'personal_finance | bnpl | credit_card_alternative — partition key',
    application_date           DATE,

    aecb_score                 INT,
    fraud_score                INT,
    aml_status                 STRING,

    decision_outcome           STRING      COMMENT 'APPROVED | DECLINED | REFER',
    decision_reason_code       STRING,
    policy_version             STRING,
    decided_at                 TIMESTAMP,
    decision_date              DATE        COMMENT 'DATE(decided_at) — used for partitioning and vintage cohorting'
)
PARTITIONED BY (product_type, decision_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/gold/fact_credit_decision/'
TBLPROPERTIES ('table_type' = 'ICEBERG');

INSERT INTO gold.lending_applications
SELECT
    di.application_id,
    di.internal_uuid,
    p.product_type,                 -- joined from the application/product context, not shown here
    di.application_date,
    di.aecb_score, di.fraud_score, di.aml_status,
    do.decision_outcome, do.decision_reason_code, do.policy_version, do.decided_at,
    CAST(do.decided_at AS DATE)      AS decision_date
FROM gold.decision_input    di
JOIN gold.decision_outcomes do USING (application_id)
JOIN gold.dim_product        p  USING (application_id)     -- see sql/mart/dim_product.sql
WHERE do.batch_date = CURRENT_DATE();
