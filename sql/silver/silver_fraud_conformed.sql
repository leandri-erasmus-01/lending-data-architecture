-- =============================================================================
-- SILVER: Fraud Conformed
-- =============================================================================
-- Parses bronze.fraud's raw JSON payload into typed columns and validates the
-- returned phone/email against the internal profile for the same internal_uuid
-- (deterministic cross-validation — see Architecture Doc §4.2).
-- =============================================================================

CREATE TABLE silver.fraud_conformed (
    application_id                STRING,
    internal_uuid                 STRING,
    bronze_id                     STRING      COMMENT 'Lineage pointer back to the raw Bronze record',
    phone_normalized              STRING      COMMENT 'E.164 format, parsed from raw_payload',
    email_normalized              STRING      COMMENT 'Lowercased and trimmed, parsed from raw_payload',
    fraud_score                   INT,
    risk_band                     STRING      COMMENT 'e.g. LOW / MEDIUM / HIGH',
    device_reputation             STRING,
    velocity_24h                  INT,
    email_age_days                INT,
    fraud_scored_at               TIMESTAMP   COMMENT 'source_generated_at from Bronze',
    identity_validation_status    STRING      COMMENT 'MATCH | MISMATCH — phone+email vs. internal profile',
    conformed_at                  TIMESTAMP,
    batch_date                    DATE        COMMENT 'Partition column — the Silver run date'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/silver/fraud_conformed/';

-- Identity validation note:
--   identity_validation_status = 'MISMATCH' indicates the phone/email returned
--   by the fraud provider resolves to a DIFFERENT internal_uuid than the one
--   that initiated the request — a cross-UUID collision. This is treated as a
--   potential data integrity or fraud signal and routed to match_exceptions
--   (see silver_match_audit.sql and data_quality/must_pass_rules.py), never
--   auto-resolved.
