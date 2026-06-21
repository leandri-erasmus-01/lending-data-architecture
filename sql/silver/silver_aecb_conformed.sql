-- =============================================================================
-- SILVER: AECB Conformed
-- =============================================================================
-- Parses bronze.aecb's raw XML payload into typed columns and validates the
-- returned Emirates ID against the internal profile for the same internal_uuid
-- (deterministic cross-validation — see Architecture Doc §4.2).
-- Cadence: 24-hour batch, processes newly landed Bronze records since the
-- previous run, appends to this table (does not rewrite history).
-- =============================================================================

CREATE TABLE silver.aecb_conformed (
    application_id               STRING,
    internal_uuid                STRING,
    bronze_id                    STRING      COMMENT 'Lineage pointer back to the raw Bronze record',
    emirates_id                  STRING      COMMENT 'Parsed from raw_payload, validated against internal profile',
    full_name                    STRING      COMMENT 'Parsed from raw_payload',
    dob                          DATE,
    aecb_score                   INT,
    aecb_band                    STRING      COMMENT 'e.g. EXCELLENT / GOOD / FAIR / POOR',
    total_outstanding            DECIMAL(18,2),
    defaults_count               INT,
    inquiries_last_6_months      INT,
    aecb_report_date             TIMESTAMP   COMMENT 'source_generated_at from Bronze',
    aecb_received_at             TIMESTAMP   COMMENT 'received_at from Bronze',
    identity_validation_status   STRING      COMMENT 'MATCH | MISMATCH — result of cross-validating emirates_id against internal profile',
    conformed_at                 TIMESTAMP   COMMENT 'When this Silver row was produced',
    batch_date                   DATE        COMMENT 'Partition column — the Silver run date'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/silver/aecb_conformed/';

-- Example transform (see etl/silver_transforms/entity_resolution.py for the
-- full deterministic validation logic):
--
-- INSERT INTO silver.aecb_conformed
-- SELECT
--     b.application_id,
--     b.internal_uuid,
--     b.bronze_id,
--     get_json_object(b.raw_payload, '$.Subject.EmiratesId')          AS emirates_id,
--     get_json_object(b.raw_payload, '$.Subject.FullName')             AS full_name,
--     CAST(get_json_object(b.raw_payload, '$.Subject.DateOfBirth') AS DATE) AS dob,
--     CAST(get_json_object(b.raw_payload, '$.Score.value') AS INT)     AS aecb_score,
--     get_json_object(b.raw_payload, '$.Score.band')                    AS aecb_band,
--     CAST(get_json_object(b.raw_payload, '$.Accounts.totalOutstanding') AS DECIMAL(18,2)) AS total_outstanding,
--     CAST(get_json_object(b.raw_payload, '$.Defaults.count') AS INT)  AS defaults_count,
--     CAST(get_json_object(b.raw_payload, '$.Inquiries.last6Months') AS INT) AS inquiries_last_6_months,
--     b.source_generated_at,
--     b.received_at,
--     CASE WHEN get_json_object(b.raw_payload, '$.Subject.EmiratesId') = ip.emirates_id
--          THEN 'MATCH' ELSE 'MISMATCH' END                              AS identity_validation_status,
--     CURRENT_TIMESTAMP(),
--     CURRENT_DATE()
-- FROM bronze.aecb b
-- JOIN silver.internal_profile_current ip ON ip.internal_uuid = b.internal_uuid
-- WHERE b.ingest_date >= CURRENT_DATE() - INTERVAL 1 DAY;
