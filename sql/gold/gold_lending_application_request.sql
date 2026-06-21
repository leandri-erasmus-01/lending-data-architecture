-- =============================================================================
-- GOLD: Lending Application Request
-- =============================================================================
-- One row per application, assembling AECB / fraud / AML / internal-profile
-- inputs for a resolved customer, gated by must-pass data quality rules.
-- This table describes INPUTS ONLY — it cannot and does not contain a decision
-- outcome, because the outcome does not exist yet when this table is built.
--
-- Consumed by:
--   1. The online decision service, via a near-real-time sync into a feature
--      store (DynamoDB) — NOT by querying this table directly, since Gold
--      runs on a 24-hour batch cadence and the live decision cannot wait a day.
--   2. gold.fact_credit_decision, once decision_outcomes exists (see below).
-- =============================================================================

CREATE TABLE gold.lending_application_request (
    application_id           STRING,
    internal_uuid            STRING,
    application_date         DATE,

    aecb_score               INT,
    aecb_band                STRING,

    fraud_score              INT,
    risk_band                STRING,

    aml_status               STRING,
    pep_flag                 BOOLEAN,
    match_score              DECIMAL(4,3),

    pending_sources          ARRAY<STRING>,
    assembled_at             TIMESTAMP,
    batch_date               DATE        COMMENT 'Partition column — the Gold run date'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/gold/decision_input/'
TBLPROPERTIES ('table_type' = 'ICEBERG');  -- Iceberg for ACID + time-travel ("as of" queries)

-- Build statement: only records that pass every must-pass rule are eligible.
-- See data_quality/must_pass_rules.py for the rule definitions.
INSERT INTO gold.lending_application_request
SELECT
    application_id, internal_uuid, application_date,
    aecb_score, aecb_band, 
    fraud_score, risk_band,
    aml_status, pep_flag, match_score,
    pending_sources,
    CURRENT_TIMESTAMP()      AS assembled_at,
    CURRENT_DATE()           AS batch_date
FROM silver.lending_application_request
WHERE batch_date = CURRENT_DATE()
  AND SIZE(pending_sources) = 0                 -- all three sources have responded
  AND aml_match_decision != 'NO_MATCH'           -- must-pass rule: no unresolved AML signal
  AND aecb_identity_status = 'MATCH'            -- must-pass rule: no identity mismatch
  AND fraud_identity_status = 'MATCH';          -- must-pass rule: no identity mismatch
