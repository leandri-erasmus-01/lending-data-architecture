-- =============================================================================
-- SILVER: AML Conformed
-- =============================================================================
-- Parses bronze.aml's raw JSON payload into typed columns and computes the
-- probabilistic match_score against the internal profile's name + DOB
-- (fuzzy matching — see Architecture Doc §4.3 and entity_resolution.py).
-- =============================================================================

CREATE TABLE silver.aml_conformed (
    application_id           STRING,
    internal_uuid            STRING,
    bronze_id                STRING      COMMENT 'Lineage pointer back to the raw Bronze record',
    returned_name            STRING      COMMENT 'Name as returned by the AML provider (may be a transliteration variant)',
    returned_dob             DATE,
    aml_status               STRING      COMMENT 'CLEAR | FLAGGED, as reported by the provider',
    pep_flag                 BOOLEAN,
    sanctions_hit            BOOLEAN,
    match_score              DECIMAL(4,3)  COMMENT 'Computed Jaro-Winkler + DOB composite score, 0.000-1.000',
    match_decision           STRING      COMMENT 'AUTO_MATCH | MANUAL_REVIEW | NO_MATCH',
    aml_screened_at          TIMESTAMP   COMMENT 'source_generated_at from Bronze',
    conformed_at             TIMESTAMP,
    batch_date               DATE        COMMENT 'Partition column — the Silver run date'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/silver/aml_conformed/';

-- Note: unlike AECB and Fraud, this is NOT a deterministic equality check.
-- AML/PEP screening returns whichever watchlist entries resemble the submitted
-- name (often transliterated, e.g. Mohammed / Mohamed / Muhammad), so a
-- similarity score is computed rather than a binary match. See
-- etl/silver_transforms/entity_resolution.py for the scoring function and
-- data_quality/must_pass_rules.py for the rule that blocks NO_MATCH records
-- from reaching Gold.
