-- =============================================================================
-- MART: Fact Loan Performance
-- =============================================================================
-- The PRIMARY portfolio monitoring table. Grain: one row per loan, per
-- reporting period (monthly snapshot). Fed from the loan servicing system —
-- NOT from AECB, fraud, AML, or the internal profile, none of which describe
-- post-origination loan behaviour. See Architecture Doc §8 and §2 (assumptions).
--
-- Distinct from gold.fact_credit_decision (origination-moment grain): this
-- table tracks the live, evolving back book — balances, repayments,
-- delinquency — which changes every reporting period long after origination.
-- =============================================================================

CREATE TABLE mart.fact_loan_performance (
    loan_id                     STRING,
    application_id              STRING      COMMENT 'Links back to the originating decision in gold.fact_credit_decision',
    internal_uuid               STRING,
    product_type                STRING      COMMENT 'personal_finance | bnpl | credit_card_alternative — partition key',
    status                      STRING      COMMENT 'ACTIVE | CLOSED | WRITTEN_OFF | DEFAULTED',
    creation_date               DATE        COMMENT 'Date the loan/credit line was originated',
    closure_date                DATE        COMMENT 'Date the loan was closed/settled — NULL while active',
    loan_amount                 DECIMAL(18,2)  COMMENT 'Original approved principal',
    outstanding_amount          DECIMAL(18,2)  COMMENT 'Current outstanding balance as of snapshot_date',
    days_past_due               INT,
    delinquency_bucket          STRING      COMMENT 'CURRENT | 1-30 | 31-60 | 61-90 | 90+ — derived from days_past_due',
    repayment_amount_mtd        DECIMAL(18,2)  COMMENT 'Repayments received this month-to-date',
    is_default                  BOOLEAN,
    months_on_book              INT          COMMENT 'Months since creation_date — required for vintage analysis',
    snapshot_date               DATE        COMMENT 'The reporting period this row represents (month-end) — partition key',
    decision_date               DATE        COMMENT 'Date the originating decision was made; joins to gold.fact_credit_decision for vintage cohorting'
)
PARTITIONED BY (product_type, snapshot_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/mart/fact_loan_performance/'
TBLPROPERTIES ('table_type' = 'ICEBERG');

-- delinquency_bucket derivation (applied by the loan-servicing ETL feeding this table):
--   CASE
--       WHEN days_past_due = 0               THEN 'CURRENT'
--       WHEN days_past_due BETWEEN 1  AND 30  THEN '1-30'
--       WHEN days_past_due BETWEEN 31 AND 60  THEN '31-60'
--       WHEN days_past_due BETWEEN 61 AND 90  THEN '61-90'
--       ELSE                                       '90+'
--   END
